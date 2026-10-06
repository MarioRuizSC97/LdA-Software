import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';

const MAX = Number.MAX_SAFE_INTEGER;
function line(quantity = '1', price = 100, pricing = {}, precision = 3) {
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
function sale(lines, invoiceRequested = false) {
  return calculateSale({ lines, invoiceRequested });
}
function only(input, invoice = false) {
  return sale([input], invoice).lines[0];
}

test('exact base rounds below, at and above the half-cent tie', () => {
  for (const [quantity, expected] of [['0.499', 0], ['0.500', 1], ['0.501', 1]]) {
    assert.equal(only(line(quantity, 1)).baseCentavos, expected);
  }
  assert.equal(only(line('0.333', 1001)).baseCentavos, 333);
});

test('additional IVA rounds the already rounded base, not the exact product', () => {
  const result = only(line('0.005', 100), true);
  assert.equal(result.baseCentavos, 1);
  assert.equal(result.additionalIvaCentavos, 0);
  // 0.499 * 7 = 3.493; at 16%, exact-base IVA would round to 1.
  const distinguishing = only(line('0.499', 7), true);
  assert.equal(distinguishing.baseCentavos, 3);
  assert.equal(distinguishing.additionalIvaCentavos, 0);
  assert.equal(distinguishing.totalCentavos, 3);
});

test('explicit invoice intent controls additional IVA at the configured rate', () => {
  const input = line('1', 10, { ivaRateBasisPoints: 500 });
  assert.equal(only(input, true).additionalIvaCentavos, 1);
  assert.equal(only(input, false).additionalIvaCentavos, 0);
  assert.equal(only(input, true).totalCentavos, 11);
  for (const [rate, expected] of [[499, 0], [500, 1], [501, 1]]) {
    assert.equal(only(line('1', 10, { ivaRateBasisPoints: rate }), true).additionalIvaCentavos, expected);
  }
  assert.equal(only(line('1', 100, { ivaRateBasisPoints: 825 }), true).totalCentavos, 108);
  for (const invoiceRequested of [undefined, null, 0, 1, 'true']) {
    assert.throws(() => calculateSale({ lines: [input], invoiceRequested }));
  }
});

test('included prices preserve gross with an unknown, never fabricated, component', () => {
  const input = line('0.333', 1001, { priceMode: 'iva-included' });
  for (const invoice of [true, false]) {
    const result = only(input, invoice);
    assert.equal(result.totalCentavos, 333);
    assert.equal(result.additionalIvaCentavos, 0);
    assert.equal(result.includedIvaCentavos, null);
    assert.equal(result.baseCentavos, 333);
  }
  assert.equal(only(line()).includedIvaCentavos, null);
});

test('exempt null rate and zero-rated zero rate never add tax', () => {
  for (const policy of [
    { ivaTreatment: 'exempt', ivaRateBasisPoints: null },
    { ivaTreatment: 'zero-rated', ivaRateBasisPoints: 0 },
  ]) {
    for (const priceMode of ['iva-included', 'iva-additional-on-invoice']) {
      assert.equal(only(line('1', 101, { ...policy, priceMode }), true).totalCentavos, 101);
      assert.equal(only(line('1', 101, { ...policy, priceMode }), true).additionalIvaCentavos, 0);
    }
  }
});

test('sums rounded lines, not aggregate base or aggregate IVA', () => {
  assert.equal(sale([line('0.5', 1), line('0.5', 1)]).totalCentavos, 2);
  const result = sale([line('1', 3), line('1', 3)], true);
  assert.equal(result.baseCentavos, 6);
  assert.equal(result.additionalIvaCentavos, 0);
  assert.equal(result.totalCentavos, 6);
});

test('rejects malformed quantities and specifications without rounding', () => {
  for (const quantity of [0.5, null, '', '.5', '01', '1e2', '-0', '-1', '0', '1.0000', '9007199254740992']) {
    assert.throws(() => only(line(quantity)));
  }
  for (const quantitySpec of [null, [], {}, { unit: 'KG', precision: 3 },
    { unit: 'kg', precision: 7 }, { unit: 'kg', precision: 1.5 },
    { unit: 'kg', precision: 3, cost: 100 }]) {
    assert.throws(() => only({ ...line(), quantitySpec }));
  }
  assert.equal(only(line('2', 3, {}, 0)).quantity.scaled, 2);
  assert.equal(only(line('0.000001', 1, {}, 6)).quantity.scaled, 1);
});

test('rejects malformed published pricing and inconsistent tax policies', () => {
  for (const patch of [
    { currency: 'USD' }, { listedPriceCentavos: -1 }, { listedPriceCentavos: 1.5 },
    { listedPriceCentavos: '100' }, { listedPriceCentavos: MAX + 1 },
    { listedPriceCentavos: NaN }, { priceMode: 'other' }, { ivaTreatment: 'other' },
    { ivaRateBasisPoints: null }, { ivaRateBasisPoints: 0 },
    { ivaRateBasisPoints: 10001 }, { ivaRateBasisPoints: 1.5 },
    { ivaRateBasisPoints: '1600' }, { cost: 10 },
    { ivaTreatment: 'exempt', ivaRateBasisPoints: 0 },
    { ivaTreatment: 'zero-rated', ivaRateBasisPoints: null },
    { ivaTreatment: 'zero-rated', ivaRateBasisPoints: 1 },
  ]) assert.throws(() => only(line('1', 100, patch)));
  for (const pricing of [null, [], {}, { ...line().pricing, currency: undefined }]) {
    assert.throws(() => only({ ...line(), pricing }));
  }
  assert.equal(only(line('1', 0), true).totalCentavos, 0);
  assert.equal(only(line('1', 1, { ivaRateBasisPoints: 10000 }), true).totalCentavos, 2);
});

test('rejects malformed calculation envelopes and empty sales', () => {
  for (const input of [null, [], {}, { lines: [], invoiceRequested: false },
    { lines: {}, invoiceRequested: false },
    { lines: [null], invoiceRequested: false },
    { lines: [line()], invoiceRequested: false, privateActor: 'x' },
    { lines: [{ ...line(), cost: 10 }], invoiceRequested: false }]) {
    assert.throws(() => calculateSale(input));
  }
  const sparse = new Array(1);
  assert.throws(() => sale(sparse));
});

test('safe boundaries use exact intermediates and reject line and sum overflow', () => {
  assert.equal(only(line('1', MAX)).totalCentavos, MAX);
  assert.equal(only(line(String(MAX), 1, {}, 0)).totalCentavos, MAX);
  assert.equal(only(line('0.5', MAX)).totalCentavos, 4503599627370496);
  assert.throws(() => only(line('2', MAX)), /safe integer/);
  assert.throws(() => only(line('1', MAX), true), /safe integer/);
  assert.throws(() => sale([line('1', MAX), line('1', 1)]), /safe integer/);
  assert.throws(() => only(line('9007199254.740992', 1, {}, 6)), /safe integer/);
});

test('snapshots are detached, versioned, deeply frozen and JSON compatible', () => {
  const input = line('0.333', 1001);
  const result = sale([input], true);
  const original = JSON.stringify(result);
  assert.equal(result.version, 1);
  assert.equal(result.lines[0].quantity.version, 1);
  assert.equal(result.lines[0].pricing.version, 1);
  assert.equal(result.calculationPolicy.version, 1);
  assert.equal(result.calculationPolicy.rounding, 'half-up');
  assert.equal(result.calculationPolicy.additionalIvaBase, 'rounded-line-base');
  assert.equal(result.lines[0].quantity.decimal, '0.333');
  input.pricing.listedPriceCentavos = 999;
  input.quantitySpec.precision = 0;
  input.quantity = '2';
  assert.equal(JSON.stringify(result), original);
  function checkFrozen(value) {
    if (value === null || typeof value !== 'object') return;
    assert.ok(Object.isFrozen(value));
    for (const child of Object.values(value)) checkFrozen(child);
  }
  checkFrozen(result);
  assert.throws(() => { result.lines[0].pricing.listedPriceCentavos = 2; }, TypeError);
  assert.throws(() => { result.lines.push({}); }, TypeError);
  assert.deepEqual(JSON.parse(original).lines[0].quantity.spec, { unit: 'kg', precision: 3 });
  assert.ok(!original.includes('cost'));
});
