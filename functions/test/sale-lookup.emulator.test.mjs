// Injected createSaleLookupService against the already running local
// Firestore emulator only; never callable/Auth transport or demo fixtures.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import { createSaleLookupService } from '../src/sale-lookup.js';
import { canonical, namespace, openRuntime } from './sales-emulator-support.mjs';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const pricing = {
  currency: 'MXN', listedPriceCentavos: 250, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};

// Exact create-only manifest of run-owned ids. Cleanup deletes only documents
// that still hold exactly what this run wrote, in one transaction.
class OwnedLookupRun {
  constructor(firestore, ns = namespace()) {
    this.firestore = firestore;
    this.ns = ns;
    this.entries = new Map();
  }
  owned(path) {
    const [collection, id, ...rest] = path.split('/');
    assert.ok(rest.length === 0 && ['sales', 'saleReturnLedgers'].includes(collection)
      && id.startsWith(`inv05-${this.ns.id}-`), `unowned path refused: ${path}`);
    return path;
  }
  async seed(path, data) {
    this.owned(path);
    assert.ok(!this.entries.has(path), 'seed once');
    this.entries.set(path, { state: 'unknown', expected: structuredClone(data) });
    await this.firestore.doc(path).create(structuredClone(data));
    this.entries.get(path).state = 'confirmed';
  }
  async sale(label, branchId, createdAtMs) {
    const saleId = this.ns.key(label);
    const calculation = calculateSale({ invoiceRequested: true, lines: [
      { quantity: '2', quantitySpec: { unit: 'piece', precision: 0 }, pricing },
    ] });
    await this.seed(`sales/${saleId}`, {
      receipt: {
        version: 1, saleId, branchId, productIds: [`INV05-${this.ns.id.toUpperCase()}-P1`],
        calculation, payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
      },
      createdAt: new Date(createdAtMs),
    });
    return saleId;
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
    assert.deepEqual(residuals, [], `INV05 lookup residual IDs: ${residuals.join(', ')}`);
  }
}

test('INV05 real Firestore sale lookup for sellers (CORR-02)', async (t) => {
  const runtime = await openRuntime();
  const run = new OwnedLookupRun(runtime.firestore);
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const recent = await run.sale('recent', a, NOW - DAY);
  const older = await run.sale('older', a, NOW - 7 * DAY);
  const expired = await run.sale('expired', a, NOW - CORRECTION_WINDOW_MS);
  const foreign = await run.sale('foreign', b, NOW - DAY);
  await run.seed(`saleReturnLedgers/${older}`, { returned: { 0: 1 } });

  const service = createSaleLookupService({
    firestore: runtime.firestore, environment: runtime.environment, now: () => new Date(NOW),
  });
  const seller = (branchId) => ({ uid: run.ns.actor, token: { role: 'seller', branchId } });

  await t.test('own in-window sale resolves with Timestamp createdAt and ledger remainders', async () => {
    const { sale } = await service.findSale({ auth: seller(a), data: { saleId: older } });
    assert.equal(sale.saleId, older);
    assert.equal(sale.createdAt, NOW - 7 * DAY);
    assert.deepEqual(sale.lines, [{ lineIndex: 0, soldScaled: 2, returnedScaled: 1, remainingScaled: 1 }]);
    assert.equal(sale.receipt.invoiceRequested, true);
    assert.equal(sale.receipt.payment.amountCentavos, 580);
    assert.ok(!JSON.stringify(sale).includes(a), 'branch identity is not echoed');
  });

  await t.test('missing and foreign sales are not-found; an expired own sale is failed-precondition', async () => {
    for (const saleId of [foreign, run.ns.key('missing')]) {
      await assert.rejects(service.findSale({ auth: seller(a), data: { saleId } }),
        (error) => error.code === 'not-found' && error.message === 'sale was not found in this branch');
    }
    await assert.rejects(service.findSale({ auth: seller(a), data: { saleId: expired } }),
      (error) => error.code === 'failed-precondition');
  });

  await t.test('recent list is branch-scoped, windowed, newest first and limited', async () => {
    const { sales } = await service.listRecentSales({ auth: seller(a), data: {} });
    assert.deepEqual(sales.map((sale) => sale.saleId), [recent, older]);
    assert.equal(sales[1].lines[0].remainingScaled, 1);
    const limited = await service.listRecentSales({ auth: seller(a), data: { limit: 1 } });
    assert.deepEqual(limited.sales.map((sale) => sale.saleId), [recent]);
    const other = await service.listRecentSales({ auth: seller(b), data: {} });
    assert.deepEqual(other.sales.map((sale) => sale.saleId), [foreign]);
  });

  await t.test('lookups never write: seeded documents are unchanged', async () => {
    for (const [path, entry] of run.entries) {
      const snapshot = await runtime.firestore.doc(path).get();
      assert.equal(canonical(snapshot.data()), canonical(entry.expected));
    }
  });
});
