import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import {
  assertCreateTargetsAbsent, correctableSale, optionalNote, sameDecimal, stockProjection,
} from '../src/correction-support.js';

const piece = { unit: 'piece', precision: 0 };
const snapshot = (value) => ({ exists: value !== undefined, data: () => value });
const invalidStock = (error) => error instanceof SaleError && error.code === 'failed-precondition'
  && error.message === 'stock projection is invalid';

test('canonical decimals compare by value, never by prefix or scale padding', () => {
  for (const [left, right] of [['0.500', '0.5'], ['1', '1.000'], ['10', '10.0'], ['2', '2']]) {
    assert.equal(sameDecimal(left, right), true, `${left} = ${right}`);
  }
  for (const [left, right] of [['10', '1'], ['100', '1'], ['1.05', '1.5'], ['0.5', '5'],
    ['1', 1], ['01', '1'], ['1.', '1'], ['0', '0']]) {
    assert.equal(sameDecimal(left, right), false, `${left} != ${right}`);
  }
});

test('stock projections accept only the written, seeded or bare shapes', () => {
  const at = new Date('2026-06-16T12:00:00Z');
  assert.equal(stockProjection(snapshot(undefined), piece), 0);
  for (const value of [
    { ...piece, quantityScaled: 4 },
    { ...piece, quantityScaled: 4, demoSeedVersion: 1 },
    { ...piece, quantityScaled: 4, updatedAt: at, lastMovementId: 'sale-a-0' },
    { ...piece, quantityScaled: 4, updatedAt: { toDate: () => at }, lastMovementId: 'k' },
  ]) {
    assert.equal(stockProjection(snapshot(value), piece), 4);
  }
  for (const value of [
    null, [], { ...piece }, { ...piece, quantityScaled: 4, extra: true },
    { ...piece, quantityScaled: 4, updatedAt: at, lastMovementId: 'k', extra: true },
    { ...piece, quantityScaled: 4, updatedAt: at },
    { ...piece, quantityScaled: 4, updatedAt: at, lastMovementId: '' },
    { ...piece, quantityScaled: 4, updatedAt: { toDate: () => new Date(NaN) }, lastMovementId: 'k' },
    { ...piece, quantityScaled: 4, demoSeedVersion: 1, updatedAt: at, lastMovementId: 'k' },
    { unit: 'kg', precision: 0, quantityScaled: 4 }, { ...piece, quantityScaled: 1.5 },
  ]) {
    assert.throws(() => stockProjection(snapshot(value), piece), invalidStock);
  }
});

test('notes are optional, trimmed, nonempty and bounded', () => {
  assert.equal(optionalNote({}), null);
  assert.equal(optionalNote({ note: 'ok' }), 'ok');
  assert.equal(optionalNote({ note: 'x'.repeat(500) }).length, 500);
  for (const note of ['', ' x', 'x ', 'x'.repeat(501), null, 3]) {
    assert.throws(() => optionalNote({ note }), TypeError);
  }
});

test('any existing create target is an orphan collision', async () => {
  const transaction = (existing) => ({ get: async ({ path }) => snapshot(existing.includes(path) ? {} : undefined) });
  const references = [{ path: 'a/1' }, { path: 'b/1' }];
  await assertCreateTargetsAbsent(transaction([]), references);
  await assert.rejects(assertCreateTargetsAbsent(transaction(['b/1']), references),
    (error) => error instanceof SaleError && error.code === 'already-exists');
});

test('correctable sales accept exact legacy and folio receipts and refuse forged folios', async () => {
  const NOW = new Date('2026-06-16T12:00:00Z').getTime();
  const key = '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab';
  const pricing = { currency: 'MXN', listedPriceCentavos: 1000, priceMode: 'iva-included',
    ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 };
  const calculation = structuredClone(calculateSale({ invoiceRequested: false,
    lines: [{ quantity: '2', quantitySpec: piece, pricing }] }));
  const record = (receipt) => ({ receipt: { saleId: key, branchId: 'north', productIds: ['p1'], calculation,
    payment: { method: 'cash', amountCentavos: 2000 }, ...receipt }, createdAt: new Date(NOW - 1000) });
  const load = (value) => correctableSale({ get: async () => snapshot(value) },
    { doc: (path) => ({ path }) }, key, 'north', NOW);
  const legacy = await load(record({ version: 1 }));
  assert.equal(legacy.folio, null);
  const folio = await load(record({ version: 2, branchCode: 'NTE', folio: 'NTE-3F2A-9C1B' }));
  assert.equal(folio.folio, 'NTE-3F2A-9C1B');
  assert.deepEqual(folio.calculation, legacy.calculation);
  for (const receipt of [
    { version: 2, branchCode: 'NTE', folio: 'NTE-0000-0000' },
    { version: 2, branchCode: 'NTE' },
    { version: 2, branchCode: 'Nte', folio: 'Nte-3F2A-9C1B' },
    { version: 1, branchCode: 'NTE', folio: 'NTE-3F2A-9C1B' },
    { version: 2, branchCode: 'NTE', folio: 'NTE-3F2A-9C1B', unitCostCentavos: 1 },
  ]) {
    await assert.rejects(load(record(receipt)), (error) => error instanceof SaleError
      && error.code === 'failed-precondition' && error.message === 'persisted sale is invalid');
  }
  await assert.rejects(load(record({ version: 2, branchCode: 'SUR', folio: 'SUR-3F2A-9C1B', branchId: 'south' })),
    (error) => error.code === 'not-found');
});
