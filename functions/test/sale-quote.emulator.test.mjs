// Injected createSaleQuoteService (and createSaleService for the consistency
// check) against the already running local Firestore emulator only; never
// callable/Auth transport or demo fixtures. Every document is run-owned.
import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, createSaleQuoteService, createSaleService } from '../src/sales.js';
import { OwnedRun, canonical, openRuntime } from './sales-emulator-support.mjs';

const seedTime = new Date('2026-06-01T12:00:00Z');
const kg = { unit: 'kg', precision: 2 };
const piece = { unit: 'piece', precision: 0 };
const additional = {
  currency: 'MXN', listedPriceCentavos: 1999, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const included = { ...additional, listedPriceCentavos: 350, priceMode: 'iva-included' };

async function snapshot(run) {
  const records = await Promise.all([...run.entries.keys()].map(async (path) => {
    const doc = await run.doc(path).get();
    return [path, doc.exists ? canonical(doc.data()) : null];
  }));
  return Object.fromEntries(records);
}

test('INV05 real Firestore read-only sale quote (SALE-02)', async (t) => {
  const runtime = await openRuntime();
  const run = new OwnedRun(runtime.firestore);
  t.after(async () => {
    try { await run.cleanup(); }
    finally { await runtime.dispose(); }
  });
  const [a, b] = run.ns.branches;
  const [p1, p2] = run.ns.products;
  // Branch b deliberately has no code: a quote there must fail like a sale.
  await run.seed(`branches/${a}`, { name: a, code: 'INVQ', createdAt: seedTime });
  await run.seed(`branches/${b}`, { name: b, createdAt: seedTime });
  for (const [productId, quantitySpec, pricing] of [[p1, kg, additional], [p2, piece, included]]) {
    await run.seed(`products/${productId}`, {
      internalCode: productId, name: productId, quantitySpec, pricing, createdAt: seedTime,
    });
  }
  await run.seed(`branches/${a}/stock/${p1}`, { ...kg, quantityScaled: 500, updatedAt: seedTime });
  await run.seed(`branches/${a}/stock/${p2}`, { ...piece, quantityScaled: 2, updatedAt: seedTime });

  const quote = createSaleQuoteService({ firestore: runtime.firestore, environment: runtime.environment });
  const seller = (branchId) => ({ uid: run.ns.actor, token: { role: 'seller', branchId } });

  await t.test('the quote is the exact calculation, reports short stock and writes nothing', async () => {
    const before = await snapshot(run);
    const lines = [{ productId: p1, quantity: '1.25' }, { productId: p2, quantity: '3' }];
    const result = await quote({ auth: seller(a), data: { invoiceRequested: true, lines } });
    const expected = calculateSale({ invoiceRequested: true, lines: [
      { quantity: '1.25', quantitySpec: kg, pricing: additional },
      { quantity: '3', quantitySpec: piece, pricing: included },
    ] });
    assert.equal(canonical(result.calculation), canonical(expected));
    assert.equal(result.totalCentavos, expected.totalCentavos);
    assert.deepEqual(result.lines, [
      { productId: p1, available: true }, { productId: p2, available: false },
    ]);
    assert.ok(!/cost|INVQ|branch-inv05/i.test(JSON.stringify(result)));
    assert.deepEqual(await snapshot(run), before, 'a quote never writes');
  });

  await t.test('a branch without a valid code fails exactly like a sale', async () => {
    await assert.rejects(quote({ auth: seller(b), data: {
      invoiceRequested: false, lines: [{ productId: p1, quantity: '1' }],
    } }), (error) => error.code === 'failed-precondition'
      && error.message === 'branch code is missing or invalid');
  });

  await t.test('the quoted total is the amount the real submitSale accepts', async () => {
    const lines = [{ productId: p1, quantity: '2.5' }, { productId: p2, quantity: '2' }];
    const quoted = await quote({ auth: seller(a), data: { invoiceRequested: true, lines } });
    assert.deepEqual(quoted.lines.map((line) => line.available), [true, true]);
    const request = {
      auth: seller(a),
      data: { idempotencyKey: run.ns.key('quoted'), invoiceRequested: true, lines,
        payment: { method: 'card', amountCentavos: quoted.totalCentavos } },
    };
    run.register(request);
    const timestamp = new Date(seedTime.getTime() + 60_000);
    const submit = createSaleService({
      firestore: run.scopedFirestore(), environment: runtime.environment, now: () => timestamp,
    });
    const { receipt, replayed } = await submit(request);
    run.confirm(request, { receipt, replayed }, timestamp);
    assert.equal(replayed, false);
    assert.equal(receipt.payment.amountCentavos, quoted.totalCentavos);
    assert.equal(canonical(receipt.calculation), canonical(quoted.calculation));
    // The sale consumed the stock; a re-quote now reports it.
    const after = await quote({ auth: seller(a), data: { invoiceRequested: true, lines } });
    assert.deepEqual(after.lines.map((line) => line.available), [true, false]);
    assert.equal(after.totalCentavos, quoted.totalCentavos);
  });
});
