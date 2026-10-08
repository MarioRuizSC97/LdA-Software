import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import {
  CORRECTION_WINDOW_MS,
  CorrectionError,
  assertCorrectionWindow,
  calculateExchangeSettlement,
  calculateRemainingReturnable,
  calculateReturnRefund,
} from '../src/corrections-calculation.js';

const DAY = 24 * 60 * 60 * 1000;

function line(quantity, price, pricing = {}, precision = 3) {
  return {
    quantity,
    quantitySpec: { unit: 'kg', precision },
    pricing: {
      currency: 'MXN', listedPriceCentavos: price,
      priceMode: 'iva-additional-on-invoice',
      ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
      ...pricing,
    },
  };
}

function receipt(lines, invoiceRequested = false, method = 'cash') {
  const calculation = calculateSale({ lines, invoiceRequested });
  return {
    version: 1,
    saleId: 'sale-1',
    branchId: 'branch-1',
    productIds: lines.map((_, index) => `product-${index}`),
    calculation,
    payment: { method, amountCentavos: calculation.totalCentavos },
  };
}

function refund(sale, lines, returned = {}) {
  return calculateReturnRefund({ receipt: sale, returned, lines });
}

function rejects(fn, code) {
  assert.throws(fn, (error) => error instanceof CorrectionError && error.code === code);
}

test('the window accepts until 15 days minus 1 ms and rejects the edge and the future', () => {
  const createdAt = 1_760_000_000_000;
  assert.equal(CORRECTION_WINDOW_MS, 15 * DAY);
  assert.doesNotThrow(() => assertCorrectionWindow(createdAt, createdAt));
  assert.doesNotThrow(() => assertCorrectionWindow(createdAt, createdAt + 15 * DAY - 1));
  rejects(() => assertCorrectionWindow(createdAt, createdAt + 15 * DAY), 'failed-precondition');
  rejects(() => assertCorrectionWindow(createdAt + 1, createdAt), 'failed-precondition');
  for (const bad of [1.5, NaN, Infinity, -1, '1', null, Number.MAX_SAFE_INTEGER + 1]) {
    rejects(() => assertCorrectionWindow(bad, createdAt), 'invalid-argument');
    rejects(() => assertCorrectionWindow(createdAt, bad), 'invalid-argument');
  }
});

test('remaining returnable quantity is sold minus already returned per line', () => {
  const sale = receipt([line('2.500', 100), line('3', 50, {}, 0)]);
  const remaining = calculateRemainingReturnable({
    lines: sale.calculation.lines, returned: { 0: 1000 },
  });
  assert.deepEqual(remaining, [
    { lineIndex: 0, soldScaled: 2500, returnedScaled: 1000, remainingScaled: 1500 },
    { lineIndex: 1, soldScaled: 3, returnedScaled: 0, remainingScaled: 3 },
  ]);
  assert.ok(Object.isFrozen(remaining) && Object.isFrozen(remaining[0]));
  const { lines } = sale.calculation;
  rejects(() => calculateRemainingReturnable({ lines, returned: { 2: 1 } }), 'invalid-argument');
  rejects(() => calculateRemainingReturnable({ lines, returned: { 0: -1 } }), 'invalid-argument');
  rejects(() => calculateRemainingReturnable({ lines, returned: { 0: 0.5 } }), 'invalid-argument');
  rejects(() => calculateRemainingReturnable({ lines, returned: [0, 0] }), 'invalid-argument');
  rejects(() => calculateRemainingReturnable({ lines, returned: { 1: 4 } }), 'failed-precondition');
});

test('a full return in one step refunds exactly the line base, IVA and total', () => {
  const sale = receipt([line('2.500', 1999)], true, 'card');
  const original = sale.calculation.lines[0];
  const result = refund(sale, [{ lineIndex: 0, quantity: '2.500' }]);
  assert.deepEqual(result.lines, [{
    lineIndex: 0,
    productId: 'product-0',
    quantity: { scaled: 2500, decimal: '2.500' },
    baseCentavos: original.baseCentavos,
    additionalIvaCentavos: original.additionalIvaCentavos,
    totalCentavos: original.totalCentavos,
  }]);
  assert.equal(result.totalCentavos, sale.calculation.totalCentavos);
  assert.equal(result.refundMethod, 'card');
  assert.equal(result.invoiced, true);
  assert.equal(result.version, 1);
  assert.equal(result.calculationPolicy.rounding, 'half-up');
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.lines[0].quantity));
});

test('three uneven partial returns sum exactly to the line totals by cumulative rounding', () => {
  const sale = receipt([line('1.000', 1001)], true);
  const original = sale.calculation.lines[0];
  assert.equal(original.baseCentavos, 1001);
  assert.equal(original.additionalIvaCentavos, 160);
  let returned = {};
  const steps = [];
  for (const quantity of ['0.333', '0.334', '0.333']) {
    const result = refund(sale, [{ lineIndex: 0, quantity }], returned);
    steps.push(result.lines[0]);
    returned = { 0: (returned[0] ?? 0) + result.lines[0].quantity.scaled };
  }
  // Naive per-step rounding would give 333 + 334 + 333 = 1000 for the base.
  assert.deepEqual(steps.map((step) => step.baseCentavos), [333, 335, 333]);
  assert.deepEqual(steps.map((step) => step.additionalIvaCentavos), [53, 54, 53]);
  const sum = (field) => steps.reduce((total, step) => total + step[field], 0);
  assert.equal(sum('baseCentavos'), original.baseCentavos);
  assert.equal(sum('additionalIvaCentavos'), original.additionalIvaCentavos);
  assert.equal(sum('totalCentavos'), original.totalCentavos);
  steps.forEach((step) => {
    assert.equal(step.totalCentavos, step.baseCentavos + step.additionalIvaCentavos);
  });
});

test('an invoiced sale refunds the additional IVA actually charged, proportionally', () => {
  const sale = receipt([line('4', 2500, {}, 0), line('1', 700, {}, 0)], true, 'transfer');
  const result = refund(sale, [{ lineIndex: 1, quantity: '1' }, { lineIndex: 0, quantity: '1' }]);
  assert.deepEqual(result.lines.map((entry) => [entry.lineIndex, entry.productId]), [
    [1, 'product-1'], [0, 'product-0'],
  ]);
  assert.equal(result.lines[1].baseCentavos, 2500);
  assert.equal(result.lines[1].additionalIvaCentavos, 400);
  assert.equal(result.lines[0].additionalIvaCentavos, 112);
  assert.equal(result.baseCentavos, 3200);
  assert.equal(result.additionalIvaCentavos, 512);
  assert.equal(result.totalCentavos, 3712);
  assert.equal(result.invoiced, true);
  assert.equal(result.refundMethod, 'transfer');
});

test('an iva-included sale refunds the gross price without additional IVA', () => {
  const sale = receipt([line('3', 1160, { priceMode: 'iva-included' }, 0)], true);
  const result = refund(sale, [{ lineIndex: 0, quantity: '2' }]);
  assert.equal(result.lines[0].baseCentavos, 2320);
  assert.equal(result.lines[0].additionalIvaCentavos, 0);
  assert.equal(result.totalCentavos, 2320);
  assert.equal(result.invoiced, true);
  const uninvoiced = receipt([line('1', 1160, { priceMode: 'iva-included' }, 0)]);
  assert.equal(refund(uninvoiced, [{ lineIndex: 0, quantity: '1' }]).invoiced, false);
});

test('over-return, zero, precision, unknown and duplicate line requests are rejected', () => {
  const sale = receipt([line('2.000', 100), line('1.000', 100)]);
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '2.001' }]), 'out-of-range');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '1.001' }], { 0: 1000 }), 'out-of-range');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '0.001' }], { 0: 2000 }), 'out-of-range');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '0' }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '0.000' }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '0.0001' }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: 1 }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '-1' }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 2, quantity: '1' }]), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: '0', quantity: '1' }]), 'invalid-argument');
  rejects(() => refund(sale, []), 'invalid-argument');
  rejects(() => refund(sale, [{ lineIndex: 0, quantity: '1', extra: true }]), 'invalid-argument');
  rejects(() => refund(sale, [
    { lineIndex: 1, quantity: '0.500' }, { lineIndex: 1, quantity: '0.500' },
  ]), 'invalid-argument');
  rejects(() => refund({ ...sale, payment: { method: 'gift', amountCentavos: 0 } }, [
    { lineIndex: 0, quantity: '1' },
  ]), 'invalid-argument');
});

test('exchange settlement charges the customer when the new item costs more', () => {
  const sale = receipt([line('1', 1000, {}, 0)], true);
  const returned = refund(sale, [{ lineIndex: 0, quantity: '1' }]);
  const newItems = calculateSale({ invoiceRequested: true, lines: [line('1', 1500, {}, 0)] });
  const settlement = calculateExchangeSettlement({ refund: returned, newItems });
  assert.deepEqual({ ...settlement }, {
    version: 1,
    returnedCentavos: 1160,
    newItemCentavos: 1740,
    customerPaysCentavos: 580,
    refundCentavos: 0,
    refundMethod: 'cash',
  });
  assert.ok(Object.isFrozen(settlement));
});

test('exchange settlement refunds by the original method when the new item costs less', () => {
  const sale = receipt([line('2', 1000, {}, 0)], false, 'card');
  const returned = refund(sale, [{ lineIndex: 0, quantity: '2' }]);
  const newItems = calculateSale({ invoiceRequested: false, lines: [line('1', 1250, {}, 0)] });
  const settlement = calculateExchangeSettlement({ refund: returned, newItems });
  assert.equal(settlement.returnedCentavos, 2000);
  assert.equal(settlement.newItemCentavos, 1250);
  assert.equal(settlement.customerPaysCentavos, 0);
  assert.equal(settlement.refundCentavos, 750);
  assert.equal(settlement.refundMethod, 'card');
});

test('exchange settlement is zero both ways for an equal amount and enforces invoice intent', () => {
  const sale = receipt([line('1', 1000, {}, 0)]);
  const returned = refund(sale, [{ lineIndex: 0, quantity: '1' }]);
  const newItems = calculateSale({ invoiceRequested: false, lines: [line('2', 500, {}, 0)] });
  const settlement = calculateExchangeSettlement({ refund: returned, newItems });
  assert.equal(settlement.customerPaysCentavos, 0);
  assert.equal(settlement.refundCentavos, 0);
  const invoiced = calculateSale({ invoiceRequested: true, lines: [line('2', 500, {}, 0)] });
  rejects(() => calculateExchangeSettlement({ refund: returned, newItems: invoiced }), 'invalid-argument');
});
