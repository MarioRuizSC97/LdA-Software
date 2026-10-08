import assert from 'node:assert/strict';
import test from 'node:test';
import { SaleError } from '../src/sales.js';
import {
  assertCreateTargetsAbsent, optionalNote, sameDecimal, stockProjection,
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
