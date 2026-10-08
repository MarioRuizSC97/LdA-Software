// Injected createSaleExchangeService against the already running local
// Firestore emulator only; never callable/Auth transport or demo fixtures.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import { createSaleExchangeService } from '../src/sale-exchanges.js';
import { createSaleReturnService } from '../src/sale-returns.js';
import {
  canonical, namespace, openRuntime,
} from './sales-emulator-support.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const AT = new Date(NOW);
const piece = { unit: 'piece', precision: 0 };
const pricing = (listedPriceCentavos) => ({
  currency: 'MXN', listedPriceCentavos, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
});
const CORRECTION_COLLECTIONS = [
  'sales', 'saleExchanges', 'saleExchangeAudits', 'saleExchangeSubmissionReceipts',
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
    const movement = /^(?:return-(.+)-\d+|exchange-(.+)-(?:in|out)-\d+)$/.exec(id ?? '');
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

test('INV05 real Firestore exchanges for a different product (CORR-05)', async (t) => {
  const runtime = await openRuntime();
  const run = new OwnedCorrectionRun(runtime.firestore);
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const [p1, p2] = run.ns.products;
  const stockPath = (productId) => `branches/${a}/stock/${productId}`;
  // Invoiced sales of 4 p1 at 2.50 + 16% IVA, paid in cash.
  const sale = async (label, branchId, createdAtMs = NOW - DAY) => {
    const saleId = run.ns.key(label);
    const calculation = calculateSale({ invoiceRequested: true, lines: [
      { quantity: '4', quantitySpec: piece, pricing: pricing(250) },
    ] });
    await run.seed(`sales/${saleId}`, {
      receipt: {
        version: 1, saleId, branchId, productIds: [p1], calculation,
        payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
      },
      createdAt: new Date(createdAtMs),
    });
    return saleId;
  };
  await run.seed(`products/${p1}`, { quantitySpec: piece, pricing: pricing(250) });
  await run.seed(`products/${p2}`, { quantitySpec: piece, pricing: pricing(400) });
  await run.seed(stockPath(p1), { ...piece, quantityScaled: 10 });
  await run.seed(stockPath(p2), { ...piece, quantityScaled: 10 });
  const saleId = await sale('sale', a);
  const exchangeFirstSale = await sale('race-exchange-first', a);
  const returnFirstSale = await sale('race-return-first', a);
  const foreign = await sale('foreign', b);
  const expired = await sale('expired', a, NOW - CORRECTION_WINDOW_MS);
  for (const id of [saleId, exchangeFirstSale, returnFirstSale, foreign, expired]) run.plan(`saleReturnLedgers/${id}`);

  const auth = { uid: run.ns.actor, token: { role: 'seller', branchId: a } };
  const services = (firestore) => ({
    exchange: createSaleExchangeService({
      firestore, environment: runtime.environment, now: () => new Date(NOW),
    }),
    giveBack: createSaleReturnService({
      firestore, environment: runtime.environment, now: () => new Date(NOW),
    }),
  });
  const { exchange } = services(runtime.firestore);
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
  const exchangeRequest = (key, returned, target, extra = {}) => ({
    auth,
    data: {
      idempotencyKey: key, saleId: target, reason: 'wrong-product',
      returnLines: [{ lineIndex: 0, quantity: returned, condition: 'good' }],
      newLines: [{ productId: p2, quantity: '1' }], ...extra,
    },
  });
  const returnRequest = (key, quantity, target) => ({
    auth,
    data: { idempotencyKey: key, saleId: target, reason: 'change-of-mind',
      lines: [{ lineIndex: 0, quantity, condition: 'good' }] },
  });
  const planExchange = (key) => [
    ...['saleExchanges', 'saleExchangeAudits', 'saleExchangeSubmissionReceipts']
      .map((collection) => run.plan(`${collection}/${key}`)),
    run.plan(`inventoryMovements/exchange-${key}-in-0`),
    run.plan(`inventoryMovements/exchange-${key}-out-0`),
  ];
  const planReturn = (key) => [
    ...['saleReturns', 'saleReturnAudits', 'saleReturnSubmissionReceipts']
      .map((collection) => run.plan(`${collection}/${key}`)),
    run.plan(`inventoryMovements/return-${key}-0`),
  ];
  // Independent expectation: returned units at 2.90 each, one new p2 at 4.64.
  const receiptFor = (key, returned, target, differencePayment) => {
    const units = Number(returned);
    const returnedCentavos = units * 290;
    return {
      version: 1, exchangeId: key, saleId: target, branchId: a, reason: 'wrong-product',
      returned: {
        lines: [{ lineIndex: 0, productId: p1, quantity: returned, condition: 'good',
          baseCentavos: units * 250, additionalIvaCentavos: units * 40, totalCentavos: returnedCentavos }],
        baseCentavos: units * 250, additionalIvaCentavos: units * 40, totalCentavos: returnedCentavos,
      },
      newItems: {
        productIds: [p2],
        calculation: calculateSale({ invoiceRequested: true, lines: [
          { quantity: '1', quantitySpec: piece, pricing: pricing(400) },
        ] }),
      },
      settlement: {
        returnedCentavos, newItemCentavos: 464,
        customerPaysCentavos: Math.max(464 - returnedCentavos, 0),
        refundCentavos: Math.max(returnedCentavos - 464, 0),
        refundMethod: 'cash', differencePayment,
      },
      invoiced: true,
    };
  };
  const confirmExchange = async (key, returned, target, differencePayment, note = null) => {
    const receipt = receiptFor(key, returned, target, differencePayment);
    assert.equal(receipt.newItems.calculation.totalCentavos, 464);
    await run.confirm(`saleExchanges/${key}`, { receipt, createdAt: AT });
    await run.confirm(`saleExchangeAudits/${key}`, {
      exchangeId: key, saleId: target, branchId: a, actorId: run.ns.actor,
      reason: 'wrong-product', note, createdAt: AT,
    });
    const movement = {
      exchangeId: key, saleId: target, branchId: a, ...piece, actorId: run.ns.actor, occurredAt: AT,
    };
    await run.confirm(`inventoryMovements/exchange-${key}-in-0`, {
      type: 'exchange-return', lineIndex: 0, productId: p1, quantityScaled: Number(returned), ...movement,
    });
    await run.confirm(`inventoryMovements/exchange-${key}-out-0`, {
      type: 'exchange-out', newLineIndex: 0, productId: p2, quantityScaled: -1, ...movement,
    });
    const replayPath = `saleExchangeSubmissionReceipts/${key}`;
    const replay = (await runtime.firestore.doc(replayPath).get()).data();
    assert.equal(typeof replay?.fingerprint, 'string');
    await run.confirm(replayPath, {
      actorId: run.ns.actor, branchId: a, fingerprint: replay.fingerprint,
      result: receipt, completedAt: AT,
    });
    return receipt;
  };

  await t.test('an exchange restocks the return, sells the new item and replays exactly', async () => {
    const key = run.ns.key('swap');
    planExchange(key);
    const payment = { method: 'card', amountCentavos: 174 };
    const input = exchangeRequest(key, '1', saleId, { note: 'Wanted the other model',
      differencePayment: payment });
    const { receipt, replayed } = await exchange(input);
    assert.equal(replayed, false);
    assert.equal(canonical(receipt),
      canonical(await confirmExchange(key, '1', saleId, payment, 'Wanted the other model')));
    await run.confirm(stockPath(p1), {
      ...piece, quantityScaled: 11, updatedAt: AT, lastMovementId: `exchange-${key}-in-0`,
    });
    await run.confirm(stockPath(p2), {
      ...piece, quantityScaled: 9, updatedAt: AT, lastMovementId: `exchange-${key}-out-0`,
    });
    await run.confirm(`saleReturnLedgers/${saleId}`,
      { returned: { 0: 1 }, lastReturnId: key, updatedAt: AT });
    const again = await exchange(input);
    assert.equal(again.replayed, true);
    assert.equal(canonical(again.receipt), canonical(receipt));
  });

  // Four sold: an exchange of 3 and a return of 2 cannot both fit. Each
  // serialization order is forced, then its exact outcome is asserted. Stock
  // expectations are relative to the manifest's last confirmed state, so
  // neither order depends on which subtests ran before it.
  const restocked = async (productId, delta, lastMovementId) => {
    const previous = run.entries.get(stockPath(productId)).expected;
    await run.confirm(stockPath(productId), {
      ...piece, quantityScaled: previous.quantityScaled + delta, updatedAt: AT, lastMovementId,
    });
  };

  await t.test('an exchange serialized before a racing return: the return is out-of-range', async () => {
    const exchangeKey = run.ns.key('ef-swap');
    const returnKey = run.ns.key('ef-return');
    planExchange(exchangeKey);
    planReturn(returnKey);
    const [swap, back] = await inOrder(
      ({ exchange: first }) => first(exchangeRequest(exchangeKey, '3', exchangeFirstSale)),
      ({ giveBack: second }) => second(returnRequest(returnKey, '2', exchangeFirstSale)),
    );
    assert.equal(swap.status, 'fulfilled', `the exchange fits first: ${swap.reason}`);
    assert.equal(back.status, 'rejected');
    assert.equal(back.reason?.code, 'out-of-range');
    assert.equal(back.reason?.message, 'return exceeds the remaining sold quantity');
    for (const path of planReturn(returnKey)) await run.absent(path);
    assert.equal(canonical(swap.value.receipt), canonical(await confirmExchange(
      exchangeKey, '3', exchangeFirstSale, null)));
    assert.equal(swap.value.receipt.settlement.refundCentavos, 406);
    await run.confirm(`saleReturnLedgers/${exchangeFirstSale}`,
      { returned: { 0: 3 }, lastReturnId: exchangeKey, updatedAt: AT });
    await restocked(p1, 3, `exchange-${exchangeKey}-in-0`);
    await restocked(p2, -1, `exchange-${exchangeKey}-out-0`);
  });

  await t.test('a return serialized before a racing exchange: the exchange is out-of-range', async () => {
    const exchangeKey = run.ns.key('rf-swap');
    const returnKey = run.ns.key('rf-return');
    planExchange(exchangeKey);
    planReturn(returnKey);
    const unchangedP2 = run.entries.get(stockPath(p2)).expected;
    await run.confirm(stockPath(p2), unchangedP2);
    const [back, swap] = await inOrder(
      ({ giveBack: first }) => first(returnRequest(returnKey, '2', returnFirstSale)),
      ({ exchange: second }) => second(exchangeRequest(exchangeKey, '3', returnFirstSale)),
    );
    assert.equal(back.status, 'fulfilled', `the return fits first: ${back.reason}`);
    assert.equal(swap.status, 'rejected');
    assert.equal(swap.reason?.code, 'out-of-range');
    assert.equal(swap.reason?.message, 'exchange exceeds the remaining sold quantity');
    for (const path of planExchange(exchangeKey)) await run.absent(path);
    await run.confirm(`saleReturnLedgers/${returnFirstSale}`,
      { returned: { 0: 2 }, lastReturnId: returnKey, updatedAt: AT });
    assert.equal(back.value.receipt.refund.totalCentavos, 580);
    const returnReceipt = {
      version: 1, returnId: returnKey, saleId: returnFirstSale, branchId: a, reason: 'change-of-mind',
      lines: [{ lineIndex: 0, productId: p1, quantity: '2', condition: 'good',
        baseCentavos: 500, additionalIvaCentavos: 80, totalCentavos: 580 }],
      refund: { method: 'cash', baseCentavos: 500, additionalIvaCentavos: 80, totalCentavos: 580 },
      invoiced: true,
    };
    assert.equal(canonical(back.value.receipt), canonical(returnReceipt));
    await run.confirm(`saleReturns/${returnKey}`, { receipt: returnReceipt, createdAt: AT });
    for (const path of planReturn(returnKey).slice(1)) {
      await run.confirm(path, plain((await runtime.firestore.doc(path).get()).data()));
    }
    await restocked(p1, 2, `return-${returnKey}-0`);
    // The rejected exchange never sold its new item.
    await run.confirm(stockPath(p2), unchangedP2);
  });

  await t.test('foreign, expired, over-cap and same-product exchanges are refused without writes', async () => {
    const cases = [
      ['stray', exchangeRequest(run.ns.key('stray'), '1', foreign), 'not-found'],
      ['late', exchangeRequest(run.ns.key('late'), '1', expired), 'failed-precondition'],
      ['over', exchangeRequest(run.ns.key('over'), '4', saleId), 'out-of-range'],
      ['same', exchangeRequest(run.ns.key('same'), '1', saleId, {
        newLines: [{ productId: p1, quantity: '1' }] }), 'invalid-argument'],
    ];
    for (const [label, input, code] of cases) {
      await assert.rejects(exchange(input), (error) => error.code === code, label);
      for (const path of planExchange(run.ns.key(label))) await run.absent(path);
    }
    for (const id of [foreign, expired]) await run.absent(`saleReturnLedgers/${id}`);
  });

  await t.test('the original sale documents are unchanged', async () => {
    for (const id of [saleId, exchangeFirstSale, returnFirstSale, foreign, expired]) {
      const snapshot = await runtime.firestore.doc(`sales/${id}`).get();
      assert.equal(canonical(snapshot.data()), canonical(run.entries.get(`sales/${id}`).expected));
    }
  });
});
