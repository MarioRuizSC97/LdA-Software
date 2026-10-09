// Injected createSaleReturnService against the already running local
// Firestore emulator only; never callable/Auth transport or demo fixtures.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import { createSaleReturnPreviewService, createSaleReturnService } from '../src/sale-returns.js';
import { canonical, namespace, openRuntime } from './sales-emulator-support.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const AT = new Date(NOW);
const piece = { unit: 'piece', precision: 0 };
const pricing = {
  currency: 'MXN', listedPriceCentavos: 250, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const RETURN_COLLECTIONS = [
  'sales', 'saleReturns', 'saleReturnAudits', 'saleReturnSubmissionReceipts', 'saleReturnLedgers',
];

// Exact manifest of run-owned ids. Every path is registered before the write
// that may create it; only confirmed entries whose content still matches
// exactly are deleted, so uncertain or foreign state is reported, never erased.
class OwnedReturnRun {
  constructor(firestore, ns = namespace()) {
    this.firestore = firestore;
    this.ns = ns;
    this.entries = new Map();
  }
  owned(path) {
    const parts = path.split('/');
    const prefix = `inv05-${this.ns.id}-`;
    const [collection, id, child, product] = parts;
    assert.ok(
      (parts.length === 2 && collection === 'products' && this.ns.products.includes(id))
      || (parts.length === 4 && collection === 'branches' && this.ns.branches.includes(id)
        && child === 'stock' && this.ns.products.includes(product))
      || (parts.length === 2 && RETURN_COLLECTIONS.includes(collection) && id.startsWith(prefix))
      || (parts.length === 2 && collection === 'inventoryMovements'
        && /^return-.+-\d$/.test(id) && id.slice(7).startsWith(prefix)),
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
    assert.deepEqual(residuals, [], `INV05 return residual IDs: ${residuals.join(', ')}`);
  }
}

test('INV05 real Firestore seller returns (CORR-03)', async (t) => {
  const runtime = await openRuntime();
  const run = new OwnedReturnRun(runtime.firestore);
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const [productId] = run.ns.products;
  const stockPath = `branches/${a}/stock/${productId}`;
  const sale = async (label, branchId) => {
    const saleId = run.ns.key(label);
    const calculation = calculateSale({ invoiceRequested: true, lines: [
      { quantity: '4', quantitySpec: piece, pricing },
    ] });
    await run.seed(`sales/${saleId}`, {
      receipt: {
        version: 1, saleId, branchId, productIds: [productId], calculation,
        payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
      },
      createdAt: new Date(NOW - DAY),
    });
    return saleId;
  };
  await run.seed(`products/${productId}`, { quantitySpec: piece, pricing });
  await run.seed(stockPath, { ...piece, quantityScaled: 1 });
  const saleId = await sale('sale', a);
  const foreign = await sale('foreign', b);
  const saleBefore = run.entries.get(`sales/${saleId}`).expected;

  const submit = createSaleReturnService({
    firestore: runtime.firestore, environment: runtime.environment, now: () => new Date(NOW),
  });
  const preview = createSaleReturnPreviewService({
    firestore: runtime.firestore, environment: runtime.environment, now: () => new Date(NOW),
  });
  const auth = { uid: run.ns.actor, token: { role: 'seller', branchId: a } };
  const request = (key, quantity, condition, extra = {}) => ({
    auth,
    data: {
      idempotencyKey: key, saleId, reason: 'change-of-mind',
      lines: [{ lineIndex: 0, quantity, condition }], ...extra,
    },
  });
  const planReturn = (key) => ['saleReturns', 'saleReturnAudits', 'saleReturnSubmissionReceipts']
    .map((collection) => run.plan(`${collection}/${key}`))
    .concat(run.plan(`inventoryMovements/return-${key}-0`));
  const confirmReturn = async (key, receipt, audit, movement) => {
    await run.confirm(`saleReturns/${key}`, { receipt, createdAt: AT });
    await run.confirm(`saleReturnAudits/${key}`, {
      returnId: key, saleId, branchId: a, actorId: run.ns.actor, createdAt: AT, ...audit,
    });
    await run.confirm(`inventoryMovements/return-${key}-0`, {
      returnId: key, saleId, lineIndex: 0, branchId: a, productId, ...piece,
      actorId: run.ns.actor, occurredAt: AT, ...movement,
    });
    const replayPath = `saleReturnSubmissionReceipts/${key}`;
    const replay = (await runtime.firestore.doc(replayPath).get()).data();
    assert.equal(typeof replay?.fingerprint, 'string');
    await run.confirm(replayPath, {
      actorId: run.ns.actor, branchId: a, fingerprint: replay.fingerprint,
      result: receipt, completedAt: AT,
    });
  };
  const receiptFor = (key, quantity, condition, reason, base, iva) => ({
    version: 1, returnId: key, saleId, branchId: a, reason,
    lines: [{ lineIndex: 0, productId, quantity, condition,
      baseCentavos: base, additionalIvaCentavos: iva, totalCentavos: base + iva }],
    refund: { method: 'cash', baseCentavos: base, additionalIvaCentavos: iva, totalCentavos: base + iva },
    invoiced: true,
  });
  run.plan(`saleReturnLedgers/${saleId}`);

  await t.test('a factory-defect return refunds, records and leaves sellable stock unchanged', async () => {
    const key = run.ns.key('defect');
    planReturn(key);
    // CORR-07P: the read-only preview equals the later submit and writes nothing.
    const { idempotencyKey, note, ...previewData } = request(key, '1', 'factory-defect',
      { reason: 'factory-defect', note: 'Broken seal' }).data;
    const previewed = await preview({ auth, data: previewData });
    for (const path of planReturn(key)) await run.absent(path);
    await run.absent(`saleReturnLedgers/${saleId}`);
    const { receipt, replayed } = await submit(request(key, '1', 'factory-defect',
      { reason: 'factory-defect', note: 'Broken seal' }));
    assert.equal(replayed, false);
    const expected = receiptFor(key, '1', 'factory-defect', 'factory-defect', 250, 40);
    assert.deepEqual(receipt, expected);
    assert.equal(canonical(previewed), canonical({ saleId, lines: expected.lines, refund: expected.refund,
      invoiced: true }));
    await confirmReturn(key, expected, { reason: 'factory-defect', note: 'Broken seal' },
      { type: 'sale-return-defect', quantityScaled: 1 });
    await run.confirm(stockPath, { ...piece, quantityScaled: 1 });
    await run.confirm(`saleReturnLedgers/${saleId}`, {
      returned: { 0: 1 }, lastReturnId: key, updatedAt: AT,
    });
    const again = await submit(request(key, '1', 'factory-defect',
      { reason: 'factory-defect', note: 'Broken seal' }));
    assert.equal(again.replayed, true);
    assert.deepEqual(again.receipt, expected);
  });

  await t.test('two concurrent returns exceeding the remainder: exactly one commits', async () => {
    const keys = [run.ns.key('race-a'), run.ns.key('race-b')];
    keys.forEach(planReturn);
    const results = await Promise.allSettled(keys.map((key) => submit(request(key, '2', 'good'))));
    const winners = results.flatMap((result, index) => result.status === 'fulfilled' ? [index] : []);
    assert.equal(winners.length, 1, 'exactly one concurrent return commits');
    const loser = results[1 - winners[0]];
    assert.equal(loser.reason?.code, 'out-of-range');
    const key = keys[winners[0]];
    const expected = receiptFor(key, '2', 'good', 'change-of-mind', 500, 80);
    assert.deepEqual(results[winners[0]].value.receipt, expected);
    await confirmReturn(key, expected, { reason: 'change-of-mind', note: null },
      { type: 'sale-return', quantityScaled: 2 });
    await run.confirm(stockPath, {
      ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: `return-${key}-0`,
    });
    await run.confirm(`saleReturnLedgers/${saleId}`, {
      returned: { 0: 3 }, lastReturnId: key, updatedAt: AT,
    });
    for (const path of planReturn(keys[1 - winners[0]])) await run.absent(path);
  });

  await t.test('after partial returns the preview gives the cumulative remainder and refuses as the submit', async () => {
    const data = (quantity, target = saleId) => ({ saleId: target, reason: 'other',
      lines: [{ lineIndex: 0, quantity, condition: 'good' }] });
    assert.equal(canonical(await preview({ auth, data: data('1') })), canonical({ saleId,
      lines: [{ lineIndex: 0, productId, quantity: '1', condition: 'good',
        baseCentavos: 250, additionalIvaCentavos: 40, totalCentavos: 290 }],
      refund: { method: 'cash', baseCentavos: 250, additionalIvaCentavos: 40, totalCentavos: 290 },
      invoiced: true }));
    await assert.rejects(preview({ auth, data: data('2') }), (error) => error.code === 'out-of-range'
      && error.message === 'return exceeds the remaining sold quantity');
    await assert.rejects(preview({ auth, data: data('1', foreign) }), (error) => error.code === 'not-found'
      && error.message === 'sale was not found in this branch');
    await assert.rejects(preview({ auth: { uid: run.ns.actor, token: { role: 'administrator' } }, data: data('1') }),
      (error) => error.code === 'permission-denied');
    // Nothing moved: the stock and ledger confirmed by the race are unchanged.
    for (const path of [stockPath, `saleReturnLedgers/${saleId}`]) {
      await run.confirm(path, run.entries.get(path).expected);
    }
    await run.absent(`saleReturnLedgers/${foreign}`);
  });

  await t.test('over-return and foreign sales are refused without writes', async () => {
    const over = run.ns.key('over');
    const stray = run.ns.key('stray');
    await assert.rejects(submit(request(over, '2', 'good')), (error) => error.code === 'out-of-range');
    await assert.rejects(submit({ ...request(stray, '1', 'good'), data: {
      ...request(stray, '1', 'good').data, saleId: foreign,
    } }), (error) => error.code === 'not-found' && error.message === 'sale was not found in this branch');
    for (const path of [...planReturn(over), ...planReturn(stray)]) await run.absent(path);
    await run.absent(`saleReturnLedgers/${foreign}`);
  });

  await t.test('the original sale documents are unchanged', async () => {
    for (const id of [saleId, foreign]) {
      const snapshot = await runtime.firestore.doc(`sales/${id}`).get();
      assert.equal(canonical(snapshot.data()), canonical(run.entries.get(`sales/${id}`).expected));
    }
    assert.equal(canonical(run.entries.get(`sales/${saleId}`).expected), canonical(saleBefore));
  });
});
