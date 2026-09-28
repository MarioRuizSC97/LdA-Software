import assert from 'node:assert/strict';
import test from 'node:test';

import {
  MAX_DECIMAL_PRECISION,
  MAX_QUANTITY_INPUT_LENGTH,
  addStockMovement,
  createQuantitySpec,
  formatQuantity,
  parseQuantity,
} from '../src/quantity.js';

test('whole-piece products accept only representable whole quantities', () => {
  const pieces = createQuantitySpec({ unit: 'piece', precision: 0 });

  assert.equal(parseQuantity('12', pieces), 12);
  assert.equal(formatQuantity(12, pieces), '12');
  assert.throws(() => parseQuantity('1.5', pieces), /precision/);
});

test('fractional products convert exact decimal strings to scaled integers and back', () => {
  const kilograms = createQuantitySpec({ unit: 'kg', precision: 3 });

  assert.equal(parseQuantity('12.345', kilograms), 12_345);
  assert.equal(parseQuantity('0.5', kilograms), 500);
  assert.equal(formatQuantity(12_345, kilograms), '12.345');
  assert.equal(formatQuantity(500, kilograms), '0.500');
  assert.equal(formatQuantity(-5, kilograms), '-0.005');
  assert.equal(parseQuantity(formatQuantity(-5, kilograms), kilograms), -5);
});

test('unrepresentable fractional quantities are rejected instead of rounded', () => {
  const liters = createQuantitySpec({ unit: 'liter', precision: 2 });

  assert.throws(() => parseQuantity('1.001', liters), /precision/);
  assert.throws(() => parseQuantity('1.000', liters), /precision/);
  assert.throws(() => parseQuantity('1e-2', liters), /decimal string/);
  assert.throws(() => parseQuantity(0.1, liters), /string/);
});

test('quantity encodings must be canonical finite decimal strings', () => {
  const units = createQuantitySpec({ unit: 'piece', precision: 2 });

  for (const invalid of ['', ' 1', '1 ', '+1', '01', '.5', '1.', '-0', '-0.00', 'NaN', 'Infinity']) {
    assert.throws(() => parseQuantity(invalid, units), /quantity/);
  }
});

test('precision is bounded and unit identifiers are explicit', () => {
  assert.equal(MAX_DECIMAL_PRECISION, 6);
  assert.throws(() => createQuantitySpec({ unit: 'kg', precision: -1 }), /precision/);
  assert.throws(() => createQuantitySpec({ unit: 'kg', precision: 7 }), /precision/);
  assert.throws(() => createQuantitySpec({ unit: '', precision: 0 }), /unit/);
  assert.throws(() => createQuantitySpec({ unit: 'Kilograms', precision: 3 }), /unit/);
});

test('quantity input length is bounded before decimal parsing', () => {
  const pieces = createQuantitySpec({ unit: 'piece', precision: 0 });
  const micros = createQuantitySpec({ unit: 'liter', precision: 6 });

  assert.equal(MAX_QUANTITY_INPUT_LENGTH, 18);
  assert.equal(parseQuantity('-9007199254.740991', micros), Number.MIN_SAFE_INTEGER);
  assert.throws(
    () => parseQuantity('9'.repeat(100_000), pieces),
    /at most 18 characters/,
  );
  assert.throws(() => parseQuantity('999999999999999999', pieces), /safe integer/);
});

test('unsafe scaled quantities and arithmetic overflow are rejected', () => {
  const micros = createQuantitySpec({ unit: 'liter', precision: 6 });
  const pieces = createQuantitySpec({ unit: 'piece', precision: 0 });

  assert.throws(() => parseQuantity('9007199254.740992', micros), /safe integer/);
  assert.throws(() => formatQuantity(Number.MAX_SAFE_INTEGER + 1, pieces), /safe integer/);
  assert.throws(
    () => addStockMovement(Number.MAX_SAFE_INTEGER, 1, pieces, pieces),
    /safe integer/,
  );
});

test('stock movements cannot produce negative stock', () => {
  const pieces = createQuantitySpec({ unit: 'piece', precision: 0 });

  assert.equal(addStockMovement(10, -4, pieces, pieces), 6);
  assert.equal(addStockMovement(0, 0, pieces, pieces), 0);
  assert.throws(() => addStockMovement(3, -4, pieces, pieces), /negative stock/);
  assert.throws(() => addStockMovement(-1, 1, pieces, pieces), /current stock/);
});

test('future movements must preserve the product unit and precision', () => {
  const productSpec = createQuantitySpec({ unit: 'kg', precision: 3 });

  assert.equal(
    addStockMovement(1_000, 250, productSpec, createQuantitySpec({ unit: 'kg', precision: 3 })),
    1_250,
  );
  assert.throws(
    () => addStockMovement(1_000, 250, productSpec, createQuantitySpec({ unit: 'kg', precision: 2 })),
    /precision.*stable/,
  );
  assert.throws(
    () => addStockMovement(1_000, 250, productSpec, createQuantitySpec({ unit: 'liter', precision: 3 })),
    /unit.*stable/,
  );
});
