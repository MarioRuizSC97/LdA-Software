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

// Strict commit order between two Firestore Timestamps.
const committedBefore = (left, right) => left.seconds < right.seconds
  || (left.seconds === right.seconds && left.nanoseconds < right.nanoseconds);

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
  const raceSale = await sale('race-sale', a, p2);
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
  for (const id of [saleId, raceSale, foreign, expired]) run.plan(`saleReturnLedgers/${id}`);

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

  await t.test('a replacement racing a return never over-commits the returnable quantity', async () => {
    // Remaining 2 after this return: a replacement of 2 and a return of 1 cannot both
    // fit unless the replacement serializes first (it consumes nothing, decision 11).
    const prior = run.ns.key('prior');
    planReturn(prior);
    await giveBack(giveBackRequest(prior, '2', raceSale));
    const replaceKey = run.ns.key('race-swap');
    const returnKey = run.ns.key('race-return');
    planReplacement(replaceKey);
    planReturn(returnKey);
    const racers = rendezvous(2);
    const [swap, back] = await Promise.allSettled([
      Promise.resolve().then(() => racers.replace(replacement(replaceKey, '2', raceSale))),
      Promise.resolve().then(() => racers.giveBack(giveBackRequest(returnKey, '1', raceSale))),
    ]);
    assert.equal(back.status, 'fulfilled', `the return always fits: ${back.reason}`);
    const ledgerPath = `saleReturnLedgers/${raceSale}`;
    const ledger = await runtime.firestore.doc(ledgerPath).get();
    assert.equal(canonical(ledger.data()),
      canonical({ returned: { 0: 3 }, lastReturnId: returnKey, updatedAt: AT }));
    await run.confirm(ledgerPath, { returned: { 0: 3 }, lastReturnId: returnKey, updatedAt: AT });
    for (const [key, quantity] of [[prior, 2], [returnKey, 1]]) {
      const returnReceipt = plain((await runtime.firestore.doc(`saleReturns/${key}`).get()).data());
      await run.confirm(`saleReturns/${key}`, returnReceipt);
      assert.equal(returnReceipt.receipt.lines[0].quantity, String(quantity));
      for (const path of planReturn(key).slice(1)) {
        await run.confirm(path, plain((await runtime.firestore.doc(path).get()).data()));
      }
    }
    if (swap.status === 'fulfilled') {
      const created = await runtime.firestore.doc(`saleReplacements/${replaceKey}`).get();
      assert.ok(committedBefore(created.createTime, ledger.updateTime),
        'a committed replacement must serialize before the return it would exceed');
      await confirmReplacement(replaceKey, '2', raceSale, p2);
      await run.confirm(stockPath(p2), {
        ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: `replacement-${replaceKey}-0-out`,
      });
    } else {
      assert.equal(swap.reason?.code, 'out-of-range');
      for (const path of planReplacement(replaceKey)) await run.absent(path);
      await run.confirm(stockPath(p2), { ...piece, quantityScaled: 5 });
    }
    t.diagnostic(`replacement/return race outcome: replacement ${swap.status}`);
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
    for (const id of [saleId, raceSale, foreign, expired]) {
      const snapshot = await runtime.firestore.doc(`sales/${id}`).get();
      assert.equal(canonical(snapshot.data()), canonical(run.entries.get(`sales/${id}`).expected));
    }
  });
});
