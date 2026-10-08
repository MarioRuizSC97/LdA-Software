// Injected createSaleReplacementService against the already running local
// Firestore emulator only; never callable/Auth transport or demo fixtures.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import { createSaleReplacementService } from '../src/sale-replacements.js';
import { createSaleReturnService } from '../src/sale-returns.js';
import {
  canonical, namespace, observeTransactions, openRuntime,
} from './sales-emulator-support.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const AT = new Date(NOW);
const piece = { unit: 'piece', precision: 0 };
const pricing = {
  currency: 'MXN', listedPriceCentavos: 250, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const CORRECTION_COLLECTIONS = [
  'sales', 'saleReplacements', 'saleReplacementAudits', 'saleReplacementSubmissionReceipts',
  'saleReturns', 'saleReturnAudits', 'saleReturnSubmissionReceipts', 'saleReturnLedgers',
];

// Exact manifest of run-owned ids. Every path is registered before the write
// that may create it; only confirmed entries whose content still matches
// exactly are deleted, so uncertain or foreign state is reported, never erased.
// Duplicated from the return test on purpose: importing a test file would run it.
class OwnedCorrectionRun {
  constructor(firestore, ns = namespace()) {
    this.firestore = firestore;
    this.ns = ns;
    this.entries = new Map();
  }
  owned(path) {
    const parts = path.split('/');
    const prefix = `inv05-${this.ns.id}-`;
    const [collection, id, child, product] = parts;
    const movement = /^(?:return-(.+)-\d+|replacement-(.+)-\d+-(?:in|out))$/.exec(id ?? '');
    assert.ok(
      (parts.length === 2 && collection === 'products' && this.ns.products.includes(id))
      || (parts.length === 4 && collection === 'branches' && this.ns.branches.includes(id)
        && child === 'stock' && this.ns.products.includes(product))
      || (parts.length === 2 && CORRECTION_COLLECTIONS.includes(collection) && id.startsWith(prefix))
      || (parts.length === 2 && collection === 'inventoryMovements' && movement
        && (movement[1] ?? movement[2]).startsWith(prefix)),
      `unowned path refused: ${path}`,
    );
    return path;
  }
  plan(path) {
    this.owned(path);
    if (!this.entries.has(path)) this.entries.set(path, { state: 'unknown', expected: null });
    return path;
  }
  async seed(path, data) {
    this.plan(path);
    assert.equal(this.entries.get(path).state, 'unknown', 'seed once');
    await this.firestore.doc(path).create(structuredClone(data));
    this.entries.set(path, { state: 'confirmed', expected: structuredClone(data) });
  }
  // Asserts the stored content, then makes exactly that content deletable.
  async confirm(path, expected) {
    this.plan(path);
    const snapshot = await this.firestore.doc(path).get();
    assert.ok(snapshot.exists, `expected document missing: ${path}`);
    assert.equal(canonical(snapshot.data()), canonical(expected), path);
    this.entries.set(path, { state: 'confirmed', expected: structuredClone(expected) });
  }
  async absent(path) {
    this.plan(path);
    assert.equal((await this.firestore.doc(path).get()).exists, false, `unexpected write: ${path}`);
    this.entries.set(path, { state: 'absent', expected: null });
  }
  async cleanup() {
    const paths = [...this.entries.keys()].sort();
    let residuals = paths;
    try {
      await this.firestore.runTransaction(async (tx) => {
        const snapshots = await Promise.all(paths.map((path) => tx.get(this.firestore.doc(path))));
        const suspicious = paths.filter((path, index) => snapshots[index].exists
          && (this.entries.get(path).state !== 'confirmed'
            || canonical(snapshots[index].data()) !== canonical(this.entries.get(path).expected)));
        if (suspicious.length) { residuals = suspicious; return; }
        paths.forEach((path, index) => {
          if (snapshots[index].exists) tx.delete(this.firestore.doc(path));
        });
        residuals = [];
      });
    } catch {
      residuals = paths;
    }
    assert.deepEqual(residuals, [], `INV05 correction residual IDs: ${residuals.join(', ')}`);
  }
}

// Read-back Timestamps become Dates so manifest copies stay comparable.
const plain = (value) => {
  if (typeof value?.toDate === 'function') return value.toDate();
  if (Array.isArray(value)) return value.map(plain);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, plain(item)]));
  }
  return value;
};

test('INV05 real Firestore factory-defect replacements (CORR-04)', async (t) => {
  const runtime = await openRuntime();
  const run = new OwnedCorrectionRun(runtime.firestore);
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const [p1, p2] = run.ns.products;
  const stockPath = (productId) => `branches/${a}/stock/${productId}`;
  const sale = async (label, branchId, productId, createdAtMs = NOW - DAY) => {
    const saleId = run.ns.key(label);
    const calculation = calculateSale({ invoiceRequested: true, lines: [
      { quantity: '4', quantitySpec: piece, pricing },
    ] });
    await run.seed(`sales/${saleId}`, {
      receipt: {
        version: 1, saleId, branchId, productIds: [productId], calculation,
        payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
      },
      createdAt: new Date(createdAtMs),
    });
    return saleId;
  };
  for (const productId of [p1, p2]) {
    await run.seed(`products/${productId}`, { quantitySpec: piece, pricing });
  }
  await run.seed(stockPath(p1), { ...piece, quantityScaled: 3 });
  await run.seed(stockPath(p2), { ...piece, quantityScaled: 5 });
  const saleId = await sale('sale', a, p1);
  const replaceFirstSale = await sale('race-replace-first', a, p2);
  const returnFirstSale = await sale('race-return-first', a, p2);
  const foreign = await sale('foreign', b, p1);
  const expired = await sale('expired', a, p1, NOW - CORRECTION_WINDOW_MS);

  const auth = { uid: run.ns.actor, token: { role: 'seller', branchId: a } };
  const services = (firestore) => ({
    replace: createSaleReplacementService({
      firestore, environment: runtime.environment, now: () => new Date(NOW),
    }),
    giveBack: createSaleReturnService({
      firestore, environment: runtime.environment, now: () => new Date(NOW),
    }),
  });
  const { replace, giveBack } = services(runtime.firestore);
  // Every launched callback waits until all participants arrived, before any read.
  const rendezvous = (participants) => {
    const observer = observeTransactions(participants);
    return services({
      doc: (path) => runtime.firestore.doc(path),
      runTransaction: (callback, options) => runtime.firestore.runTransaction(
        observer.wrap(callback), options),
    });
  };
  // Forces a serialization order: both submissions start together, but the
  // second one waits inside its transaction, before its first read (so it holds
  // no lock), until the first one has committed or failed.
  const inOrder = async (first, second) => {
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const held = services({
      doc: (path) => runtime.firestore.doc(path),
      runTransaction: (callback, options) => runtime.firestore.runTransaction(async (tx) => {
        await gate;
        return callback(tx);
      }, options),
    });
    const late = Promise.resolve().then(() => second(held));
    const [early] = await Promise.allSettled([Promise.resolve().then(() => first(services(runtime.firestore)))]);
    release();
    const [settled] = await Promise.allSettled([late]);
    return [early, settled];
  };
  const replacement = (key, quantity, target = saleId) => ({
    auth, data: { idempotencyKey: key, saleId: target, lines: [{ lineIndex: 0, quantity }] },
  });
  const giveBackRequest = (key, quantity, target) => ({
    auth,
    data: { idempotencyKey: key, saleId: target, reason: 'factory-defect',
      lines: [{ lineIndex: 0, quantity, condition: 'factory-defect' }] },
  });
  const planReplacement = (key) => [
    ...['saleReplacements', 'saleReplacementAudits', 'saleReplacementSubmissionReceipts']
      .map((collection) => run.plan(`${collection}/${key}`)),
    run.plan(`inventoryMovements/replacement-${key}-0-in`),
    run.plan(`inventoryMovements/replacement-${key}-0-out`),
  ];
  const planReturn = (key) => [
    ...['saleReturns', 'saleReturnAudits', 'saleReturnSubmissionReceipts']
      .map((collection) => run.plan(`${collection}/${key}`)),
    run.plan(`inventoryMovements/return-${key}-0`),
  ];
  const receiptFor = (key, quantity, target, productId) => ({
    version: 1, replacementId: key, saleId: target, branchId: a, reason: 'factory-defect',
    lines: [{ lineIndex: 0, productId, quantity }], chargeCentavos: 0,
  });
  const confirmReplacement = async (key, quantity, target, productId, note = null) => {
    const receipt = receiptFor(key, quantity, target, productId);
    await run.confirm(`saleReplacements/${key}`, { receipt, createdAt: AT });
    await run.confirm(`saleReplacementAudits/${key}`, {
      replacementId: key, saleId: target, branchId: a, actorId: run.ns.actor,
      reason: 'factory-defect', note, createdAt: AT,
    });
    const movement = {
      replacementId: key, saleId: target, lineIndex: 0, branchId: a, productId, ...piece,
      actorId: run.ns.actor, occurredAt: AT,
    };
    await run.confirm(`inventoryMovements/replacement-${key}-0-in`,
      { type: 'replacement-defect-in', quantityScaled: Number(quantity), ...movement });
    await run.confirm(`inventoryMovements/replacement-${key}-0-out`,
      { type: 'replacement-out', quantityScaled: -Number(quantity), ...movement });
    const replayPath = `saleReplacementSubmissionReceipts/${key}`;
    const replay = (await runtime.firestore.doc(replayPath).get()).data();
    assert.equal(typeof replay?.fingerprint, 'string');
    await run.confirm(replayPath, {
      actorId: run.ns.actor, branchId: a, fingerprint: replay.fingerprint,
      result: receipt, completedAt: AT,
    });
    return receipt;
  };
  for (const id of [saleId, replaceFirstSale, returnFirstSale, foreign, expired]) run.plan(`saleReturnLedgers/${id}`);

  await t.test('a replacement moves sellable stock out at no charge and replays exactly', async () => {
    const key = run.ns.key('swap');
    planReplacement(key);
    const input = replacement(key, '1');
    input.data.note = 'Dead on arrival';
    const { receipt, replayed } = await replace(input);
    assert.equal(replayed, false);
    assert.deepEqual(receipt, await confirmReplacement(key, '1', saleId, p1, 'Dead on arrival'));
    await run.confirm(stockPath(p1), {
      ...piece, quantityScaled: 2, updatedAt: AT, lastMovementId: `replacement-${key}-0-out`,
    });
    await run.absent(`saleReturnLedgers/${saleId}`);
    const again = await replace(input);
    assert.equal(again.replayed, true);
    assert.deepEqual(again.receipt, receipt);
  });

  // Remaining 2 after a prior return: a replacement of 2 and a return of 1 both
  // fit only when the replacement serializes first (it consumes nothing,
  // decision 11). Each order is forced, then its outcome asserted exactly.
  const raceSetup = async (target, label) => {
    const prior = run.ns.key(`${label}-prior`);
    planReturn(prior);
    await giveBack(giveBackRequest(prior, '2', target));
    const replaceKey = run.ns.key(`${label}-swap`);
    const returnKey = run.ns.key(`${label}-return`);
    planReplacement(replaceKey);
    planReturn(returnKey);
    return { prior, replaceKey, returnKey };
  };
  const confirmRaceReturns = async (target, prior, returnKey) => {
    const ledgerPath = `saleReturnLedgers/${target}`;
    await run.confirm(ledgerPath, { returned: { 0: 3 }, lastReturnId: returnKey, updatedAt: AT });
    for (const [key, quantity] of [[prior, '2'], [returnKey, '1']]) {
      const returnReceipt = plain((await runtime.firestore.doc(`saleReturns/${key}`).get()).data());
      assert.equal(returnReceipt.receipt.lines[0].quantity, quantity);
      await run.confirm(`saleReturns/${key}`, returnReceipt);
      for (const path of planReturn(key).slice(1)) {
        await run.confirm(path, plain((await runtime.firestore.doc(path).get()).data()));
      }
    }
  };

  await t.test('a replacement serialized before a racing return: both commit', async () => {
    const { prior, replaceKey, returnKey } = await raceSetup(replaceFirstSale, 'rf');
    const [swap, back] = await inOrder(
      ({ replace: first }) => first(replacement(replaceKey, '2', replaceFirstSale)),
      ({ giveBack: second }) => second(giveBackRequest(returnKey, '1', replaceFirstSale)),
    );
    assert.equal(swap.status, 'fulfilled', `the replacement fits first: ${swap.reason}`);
    assert.equal(back.status, 'fulfilled', `the return still fits: ${back.reason}`);
    assert.deepEqual(swap.value.receipt, await confirmReplacement(replaceKey, '2', replaceFirstSale, p2));
    await confirmRaceReturns(replaceFirstSale, prior, returnKey);
    await run.confirm(stockPath(p2), {
      ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: `replacement-${replaceKey}-0-out`,
    });
  });

  await t.test('a return serialized before a racing replacement: the replacement is out-of-range', async () => {
    const { prior, replaceKey, returnKey } = await raceSetup(returnFirstSale, 'tf');
    const [back, swap] = await inOrder(
      ({ giveBack: first }) => first(giveBackRequest(returnKey, '1', returnFirstSale)),
      ({ replace: second }) => second(replacement(replaceKey, '2', returnFirstSale)),
    );
    assert.equal(back.status, 'fulfilled', `the return fits first: ${back.reason}`);
    assert.equal(swap.status, 'rejected');
    assert.equal(swap.reason?.code, 'out-of-range');
    assert.equal(swap.reason?.message, 'replacement exceeds the remaining returnable quantity');
    for (const path of planReplacement(replaceKey)) await run.absent(path);
    await confirmRaceReturns(returnFirstSale, prior, returnKey);
    // Unchanged since the replacement that committed in the previous order.
    const previous = run.ns.key('rf-swap');
    await run.confirm(stockPath(p2), {
      ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: `replacement-${previous}-0-out`,
    });
  });

  await t.test('two replacements racing for the last stock: exactly one commits', async () => {
    const keys = [run.ns.key('stock-a'), run.ns.key('stock-b')];
    keys.forEach(planReplacement);
    const racers = rendezvous(2);
    const results = await Promise.allSettled(keys.map((key) =>
      Promise.resolve().then(() => racers.replace(replacement(key, '2')))));
    const winners = results.flatMap((result, index) => result.status === 'fulfilled' ? [index] : []);
    assert.equal(winners.length, 1, 'exactly one replacement commits');
    const loser = results[1 - winners[0]];
    assert.equal(loser.reason?.code, 'failed-precondition');
    assert.equal(loser.reason?.message, 'insufficient stock');
    const key = keys[winners[0]];
    assert.deepEqual(results[winners[0]].value.receipt, await confirmReplacement(key, '2', saleId, p1));
    await run.confirm(stockPath(p1), {
      ...piece, quantityScaled: 0, updatedAt: AT, lastMovementId: `replacement-${key}-0-out`,
    });
    for (const path of planReplacement(keys[1 - winners[0]])) await run.absent(path);
  });

  await t.test('foreign, expired and over-cap replacements are refused without writes', async () => {
    const stray = run.ns.key('stray');
    const late = run.ns.key('late');
    const over = run.ns.key('over');
    await assert.rejects(replace(replacement(stray, '1', foreign)),
      (error) => error.code === 'not-found' && error.message === 'sale was not found in this branch');
    await assert.rejects(replace(replacement(late, '1', expired)),
      (error) => error.code === 'failed-precondition');
    await assert.rejects(replace(replacement(over, '5')), (error) => error.code === 'out-of-range');
    for (const path of [...planReplacement(stray), ...planReplacement(late), ...planReplacement(over)]) {
      await run.absent(path);
    }
    for (const id of [saleId, foreign, expired]) await run.absent(`saleReturnLedgers/${id}`);
  });

  await t.test('the original sale documents are unchanged', async () => {
    for (const id of [saleId, replaceFirstSale, returnFirstSale, foreign, expired]) {
      const snapshot = await runtime.firestore.doc(`sales/${id}`).get();
      assert.equal(canonical(snapshot.data()), canonical(run.entries.get(`sales/${id}`).expected));
    }
  });
});
