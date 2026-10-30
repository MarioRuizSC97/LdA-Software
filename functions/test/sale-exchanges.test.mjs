import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import { createSaleReturnService } from '../src/sale-returns.js';
import * as exchanges from '../src/sale-exchanges.js';

const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const AT = new Date(NOW);
const DAY = 24 * 60 * 60 * 1000;
const piece = { unit: 'piece', precision: 0 };
const kg = { unit: 'kg', precision: 3 };
const pricing = (listedPriceCentavos) => ({
  currency: 'MXN', listedPriceCentavos, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
});
const clone = (value) => structuredClone(value);

// Line 0: 3 pieces of p1 at 10.00. Line 1: 1.250 kg of p2 at 10.00/kg.
function saleRecord(saleId, branchId, createdAtMs, { invoiceRequested = false, method = 'cash' } = {}) {
  const calculation = clone(calculateSale({ invoiceRequested, lines: [
    { quantity: '3', quantitySpec: piece, pricing: pricing(1000) },
    { quantity: '1.250', quantitySpec: kg, pricing: pricing(1000) },
  ] }));
  return {
    receipt: {
      version: 1, saleId, branchId, productIds: ['p1', 'p2'], calculation,
      payment: { method, amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(createdAtMs),
  };
}

// p3 (15.00) and p5 (10.00) are pieces; p4 is sold by the kilogram (8.00/kg).
function baseRecords() {
  return [
    ['sales/s1', saleRecord('s1', 'north', NOW - DAY)],
    ['sales/inv', saleRecord('inv', 'north', NOW - DAY, { invoiceRequested: true, method: 'card' })],
    ['sales/foreign', saleRecord('foreign', 'south', NOW - DAY)],
    ['sales/expired', saleRecord('expired', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['products/p1', { quantitySpec: piece, pricing: pricing(1000) }],
    ['products/p2', { quantitySpec: kg, pricing: pricing(1000) }],
    ['products/p3', { quantitySpec: piece, pricing: pricing(1500) }],
    ['products/p4', { quantitySpec: kg, pricing: pricing(800) }],
    ['products/p5', { quantitySpec: piece, pricing: pricing(1000) }],
    ['branches/north/stock/p1', { ...piece, quantityScaled: 5 }],
    ['branches/north/stock/p2', { ...kg, quantityScaled: 2000 }],
    ['branches/north/stock/p3', { ...piece, quantityScaled: 4 }],
    ['branches/north/stock/p4', { ...kg, quantityScaled: 3000 }],
    ['branches/north/stock/p5', { ...piece, quantityScaled: 10 }],
  ];
}

// Serial in-memory transactions: buffered writes, create preconditions,
// all-reads-before-writes, and an optional abandoned first callback attempt.
class FakeFirestore {
  constructor(records = baseRecords()) {
    this.records = new Map(records.map(([path, value]) => [path, clone(value)]));
    this.traces = [];
    this.retry = false;
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+(?:\/[^/]+\/[^/]+)?$/);
    assert.ok(!/cost/i.test(path), `forbidden read: ${path}`);
    return { path };
  }

  async runTransaction(callback) {
    const execute = async () => {
      const writes = [];
      const trace = [];
      this.traces.push(trace);
      const transaction = {
        get: async ({ path }) => {
          assert.equal(writes.length, 0, 'all reads precede every write');
          trace.push(['get', path]);
          const data = this.records.get(path);
          return { exists: this.records.has(path), data: () => clone(data) };
        },
        create: ({ path }, data) => {
          trace.push(['create', path]);
          writes.push({ kind: 'create', path, data: clone(data) });
        },
        set: ({ path }, data) => {
          trace.push(['set', path]);
          writes.push({ kind: 'set', path, data: clone(data) });
        },
      };
      const result = await callback(transaction);
      return { writes, result };
    };
    if (this.retry) {
      this.retry = false;
      await execute(); // Abandon every write from this callback invocation.
    }
    const { writes, result } = await execute();
    const next = new Map(this.records);
    for (const { kind, path, data } of writes) {
      if (kind === 'create' && next.has(path)) throw new Error('create-only conflict');
      next.set(path, data);
    }
    this.records = next;
    return result;
  }
}

function fixture(options = {}, records = undefined) {
  const firestore = new FakeFirestore(records);
  const clock = { now: () => new Date(NOW) };
  const service = exchanges.createSaleExchangeService({ firestore, environment, ...clock, ...options });
  const submitReturn = createSaleReturnService({ firestore, environment, ...clock });
  return { firestore, service, submitReturn };
}

function withRecords(overrides, removals = []) {
  const records = new Map(baseRecords());
  for (const [path, value] of overrides) records.set(path, value);
  for (const path of removals) records.delete(path);
  return [...records];
}

// Default: return one good p1 (10.00) for one p3 (15.00); the customer pays 5.00.
function request(data = {}, actor = auth) {
  return {
    auth: clone(actor),
    data: {
      idempotencyKey: 'x1', saleId: 's1', reason: 'wrong-product',
      returnLines: [{ lineIndex: 0, quantity: '1', condition: 'good' }],
      newLines: [{ productId: 'p3', quantity: '1' }],
      differencePayment: { method: 'card', amountCentavos: 500 },
      ...data,
    },
  };
}

// An even exchange: one p1 (10.00) for one p5 (10.00), nothing to settle.
function evenRequest(data = {}) {
  const input = request({ newLines: [{ productId: 'p5', quantity: '1' }], ...data });
  if (!Object.hasOwn(data, 'differencePayment')) delete input.data.differencePayment;
  return input;
}

function returnRequest(key, lineIndex, quantity, saleId = 's1') {
  return {
    auth: clone(auth),
    data: { idempotencyKey: key, saleId, reason: 'change-of-mind',
      lines: [{ lineIndex, quantity, condition: 'good' }] },
  };
}

// Asserts the code, the message when given, and the machine reason exactly:
// a refusal asserted without a reason must carry none.
async function rejectsUnchanged(firestore, promise, code, { message, reason } = {}) {
  const before = clone([...firestore.records]);
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof SaleError, `unexpected ${error}`);
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    assert.equal(error.reason, reason);
    return true;
  });
  assert.deepEqual([...firestore.records], before, 'failure leaves no artifacts');
}

const stock = (firestore, product) => firestore.records.get(`branches/north/stock/${product}`);
const ledger = (firestore, saleId = 's1') => firestore.records.get(`saleReturnLedgers/${saleId}`);
const deepFrozen = (value) => value === null || typeof value !== 'object'
  || (Object.isFrozen(value) && Object.values(value).every(deepFrozen));
const newItems = (invoiceRequested, lines) => clone(calculateSale({ invoiceRequested, lines }));

test('factory validates injected dependencies', () => {
  assert.throws(() => exchanges.createSaleExchangeService(), TypeError);
  assert.throws(() => exchanges.createSaleExchangeService({ firestore: { doc() {} } }), TypeError);
  assert.throws(() => fixture({ now: 1 }), TypeError);
  assert.equal(typeof fixture().service, 'function');
});

test('the emulator guard and seller authorization run before any read', async () => {
  for (const env of [{}, { ...environment, GCLOUD_PROJECT: 'cloud-project' }]) {
    const { firestore, service } = fixture({ environment: env });
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
    assert.deepEqual(firestore.traces, []);
  }
  for (const [actor, code] of [
    [undefined, 'unauthenticated'], [{ uid: '' }, 'unauthenticated'],
    [{ uid: 'x', token: { role: 'administrator', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'auditor', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service({ ...request(), auth: actor }), code);
    assert.deepEqual(firestore.traces, []);
  }
});

test('requests accept only exact fields, reasons, conditions, products and payments', async () => {
  const { firestore, service } = fixture();
  const line = { lineIndex: 0, quantity: '1', condition: 'good' };
  const item = { productId: 'p3', quantity: '1' };
  const payment = { method: 'card', amountCentavos: 500 };
  for (const data of [
    { idempotencyKey: '' }, { idempotencyKey: '../x1' }, { idempotencyKey: 'x'.repeat(129) },
    { saleId: '' }, { saleId: 's/1' }, { saleId: 7 },
    { reason: 'damaged' }, { reason: undefined }, { reason: 'Other' },
    { note: '' }, { note: '   ' }, { note: ' padded' }, { note: 'padded ' }, { note: 'x'.repeat(501) },
    { note: null }, { note: 5 },
    { returnLines: [] }, { returnLines: 'all' }, { returnLines: [line, { ...line }] },
    { returnLines: [{ ...line, condition: 'customer-damage' }] },
    { returnLines: [{ lineIndex: 0, quantity: '1' }] }, { returnLines: [{ ...line, productId: 'p1' }] },
    { returnLines: [{ ...line, lineIndex: -1 }] }, { returnLines: [{ ...line, lineIndex: '0' }] },
    { returnLines: [{ ...line, quantity: '0' }] }, { returnLines: [{ ...line, quantity: '01' }] },
    { returnLines: [{ ...line, quantity: 1 }] },
    { newLines: [] }, { newLines: 'p3' }, { newLines: [item, { ...item }] },
    { newLines: [{ ...item, productId: '../p3' }] }, { newLines: [{ ...item, productId: '' }] },
    { newLines: [{ productId: 'p3' }] }, { newLines: [{ ...item, price: 1 }] },
    { newLines: [{ ...item, quantity: '0' }] }, { newLines: [{ ...item, quantity: '1.' }] },
    { newLines: [{ ...item, quantity: 1 }] }, { newLines: [{ ...item, quantity: '-1' }] },
    { differencePayment: null }, { differencePayment: 'card' }, { differencePayment: [] },
    { differencePayment: { method: 'cheque', amountCentavos: 500 } },
    { differencePayment: { amountCentavos: 500 } }, { differencePayment: { method: 'card' } },
    { differencePayment: { ...payment, amountCentavos: -1 } },
    { differencePayment: { ...payment, amountCentavos: 5.5 } },
    { differencePayment: { ...payment, amountCentavos: '500' } },
    { differencePayment: { ...payment, change: 0 } },
    { lines: [line] }, { branchId: 'north' }, { refundMethod: 'cash' },
  ]) {
    await rejectsUnchanged(firestore, service(request(data)), 'invalid-argument');
  }
  const sparse = [];
  sparse.length = 1;
  await rejectsUnchanged(firestore, service(request({ returnLines: sparse })), 'invalid-argument');
  await rejectsUnchanged(firestore, service(request({ newLines: sparse })), 'invalid-argument');
  for (const data of [undefined, null, []]) {
    await rejectsUnchanged(firestore, service({ auth, data }), 'invalid-argument');
  }
  assert.deepEqual(firestore.traces, []);
  const accepted = await service(request({ note: 'x'.repeat(500) }));
  assert.equal(accepted.replayed, false);
});

test('the customer pays the difference, which must be exactly paid', async () => {
  for (const [differencePayment, message] of [
    [undefined, 'difference payment must equal the amount the customer owes'],
    [{ method: 'card', amountCentavos: 499 }, 'difference payment must equal the amount the customer owes'],
    [{ method: 'card', amountCentavos: 501 }, 'difference payment must equal the amount the customer owes'],
  ]) {
    const { firestore, service } = fixture();
    const input = request();
    if (differencePayment) input.data.differencePayment = differencePayment;
    else delete input.data.differencePayment;
    await rejectsUnchanged(firestore, service(input), 'invalid-argument', { message, reason: 'payment-mismatch' });
  }

  const { firestore, service } = fixture();
  const sale = clone(firestore.records.get('sales/s1'));
  const result = await service(request({ note: 'Wanted the blue one' }));
  const expected = {
    version: 1, exchangeId: 'x1', saleId: 's1', branchId: 'north', reason: 'wrong-product',
    returned: {
      lines: [{ lineIndex: 0, productId: 'p1', quantity: '1', condition: 'good',
        baseCentavos: 1000, additionalIvaCentavos: 0, totalCentavos: 1000 }],
      baseCentavos: 1000, additionalIvaCentavos: 0, totalCentavos: 1000,
    },
    newItems: {
      productIds: ['p3'],
      calculation: newItems(false, [{ quantity: '1', quantitySpec: piece, pricing: pricing(1500) }]),
    },
    settlement: {
      returnedCentavos: 1000, newItemCentavos: 1500, customerPaysCentavos: 500, refundCentavos: 0,
      refundMethod: 'cash', differencePayment: { method: 'card', amountCentavos: 500 },
    },
    invoiced: false,
  };
  assert.deepEqual(result, { receipt: expected, replayed: false });
  assert.ok(Object.isFrozen(result) && deepFrozen(result.receipt));
  assert.equal(expected.newItems.calculation.lines[0].pricing.listedPriceCentavos, 1500);

  assert.deepEqual(firestore.records.get('saleExchanges/x1'), { receipt: expected, createdAt: AT });
  assert.deepEqual(firestore.records.get('saleExchangeAudits/x1'), {
    exchangeId: 'x1', saleId: 's1', branchId: 'north', actorId: 'seller-one',
    reason: 'wrong-product', note: 'Wanted the blue one', createdAt: AT,
  });
  assert.ok(!JSON.stringify(firestore.records.get('saleExchanges/x1')).includes('blue'));
  const movement = { exchangeId: 'x1', saleId: 's1', branchId: 'north', ...piece,
    actorId: 'seller-one', occurredAt: AT };
  assert.deepEqual(firestore.records.get('inventoryMovements/exchange-x1-in-0'), {
    type: 'exchange-return', lineIndex: 0, productId: 'p1', quantityScaled: 1, ...movement,
  });
  assert.deepEqual(firestore.records.get('inventoryMovements/exchange-x1-out-0'), {
    type: 'exchange-out', newLineIndex: 0, productId: 'p3', quantityScaled: -1, ...movement,
  });
  assert.deepEqual(stock(firestore, 'p1'),
    { ...piece, quantityScaled: 6, updatedAt: AT, lastMovementId: 'exchange-x1-in-0' });
  assert.deepEqual(stock(firestore, 'p3'),
    { ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: 'exchange-x1-out-0' });
  assert.deepEqual(ledger(firestore), { returned: { 0: 1 }, lastReturnId: 'x1', updatedAt: AT });
  const replay = firestore.records.get('saleExchangeSubmissionReceipts/x1');
  assert.deepEqual(Object.keys(replay).sort(),
    ['actorId', 'branchId', 'completedAt', 'fingerprint', 'result']);
  assert.deepEqual(replay.result, expected);
  assert.equal(replay.completedAt.getTime(), NOW);

  // The sale is immutable; only stock and the ledger are ever set.
  assert.deepEqual(firestore.records.get('sales/s1'), sale);
  const operations = firestore.traces.flat();
  assert.deepEqual(operations.filter(([kind]) => kind === 'set').map(([, path]) => path).sort(),
    ['branches/north/stock/p1', 'branches/north/stock/p3', 'saleReturnLedgers/s1']);
  assert.ok(operations.every(([kind, path]) => kind === 'get' || !path.startsWith('sales/')));
});

test('the customer is refunded the difference through the original payment method', async () => {
  const { firestore, service } = fixture();
  const input = evenRequest({ returnLines: [{ lineIndex: 0, quantity: '2', condition: 'good' }] });
  // A payment is never accepted when the customer owes nothing.
  await rejectsUnchanged(firestore, service({ ...input, data: { ...input.data,
    differencePayment: { method: 'cash', amountCentavos: 1000 } } }), 'invalid-argument',
  { message: 'difference payment is only accepted when the customer owes money', reason: 'payment-mismatch' });
  const { receipt } = await service(input);
  assert.deepEqual(receipt.settlement, {
    returnedCentavos: 2000, newItemCentavos: 1000, customerPaysCentavos: 0, refundCentavos: 1000,
    refundMethod: 'cash', differencePayment: null,
  });
  assert.equal(stock(firestore, 'p1').quantityScaled, 7);
  assert.equal(stock(firestore, 'p5').quantityScaled, 9);
});

test('an even exchange takes no payment and refunds nothing', async () => {
  const { firestore, service } = fixture();
  await rejectsUnchanged(firestore, service(evenRequest({
    differencePayment: { method: 'card', amountCentavos: 0 },
  })), 'invalid-argument', {
    message: 'difference payment is only accepted when the customer owes money', reason: 'payment-mismatch',
  });
  const { receipt } = await service(evenRequest());
  assert.deepEqual(receipt.settlement, {
    returnedCentavos: 1000, newItemCentavos: 1000, customerPaysCentavos: 0, refundCentavos: 0,
    refundMethod: 'cash', differencePayment: null,
  });
});

test('an invoiced sale nets the additional IVA on both sides and stays flagged', async () => {
  const { firestore, service } = fixture();
  const { receipt } = await service(request({ saleId: 'inv', newLines: [
    { productId: 'p3', quantity: '1' }, { productId: 'p4', quantity: '0.5' },
  ], differencePayment: { method: 'transfer', amountCentavos: 1044 } }));
  // Returned 10.00 + 1.60 IVA; new 15.00 + 2.40 and 4.00 + 0.64 at current prices.
  assert.deepEqual(receipt.returned.lines[0], { lineIndex: 0, productId: 'p1', quantity: '1',
    condition: 'good', baseCentavos: 1000, additionalIvaCentavos: 160, totalCentavos: 1160 });
  assert.deepEqual(receipt.newItems.calculation, newItems(true, [
    { quantity: '1', quantitySpec: piece, pricing: pricing(1500) },
    { quantity: '0.500', quantitySpec: kg, pricing: pricing(800) },
  ]));
  assert.deepEqual(receipt.newItems.calculation.lines.map((line) => line.additionalIvaCentavos),
    [240, 64]);
  assert.deepEqual(receipt.settlement, {
    returnedCentavos: 1160, newItemCentavos: 2204, customerPaysCentavos: 1044, refundCentavos: 0,
    refundMethod: 'card', differencePayment: { method: 'transfer', amountCentavos: 1044 },
  });
  assert.equal(receipt.invoiced, true);
  assert.deepEqual(stock(firestore, 'p4'),
    { ...kg, quantityScaled: 2500, updatedAt: AT, lastMovementId: 'exchange-x1-out-1' });
});

test('new items use current pricing, never the sale snapshot', async () => {
  const { firestore, service } = fixture({}, withRecords([['products/p2', {
    quantitySpec: kg, pricing: pricing(2000) }]]));
  // p2 sold at 10.00/kg is bought again at its current 20.00/kg.
  const { receipt } = await service(evenRequest({ newLines: [{ productId: 'p2', quantity: '0.5' }] }));
  assert.equal(receipt.newItems.calculation.totalCentavos, 1000);
  assert.equal(receipt.settlement.customerPaysCentavos, 0);
  assert.deepEqual(stock(firestore, 'p2'),
    { ...kg, quantityScaled: 1500, updatedAt: AT, lastMovementId: 'exchange-x1-out-0' });
});

test('a partial exchange leaves the rest returnable with cumulative refunds', async () => {
  const { firestore, service, submitReturn } = fixture();
  const exchanged = await service(evenRequest({
    returnLines: [{ lineIndex: 1, quantity: '0.333', condition: 'good' }],
    newLines: [{ productId: 'p5', quantity: '1' }],
    differencePayment: { method: 'cash', amountCentavos: 667 },
  }));
  assert.equal(exchanged.receipt.returned.totalCentavos, 333);
  assert.deepEqual(ledger(firestore), { returned: { 1: 333 }, lastReturnId: 'x1', updatedAt: AT });
  await rejectsUnchanged(firestore, submitReturn(returnRequest('r1', 1, '0.918')), 'out-of-range',
    { reason: 'over-return' });
  const { receipt } = await submitReturn(returnRequest('r1', 1, '0.917'));
  assert.equal(receipt.refund.totalCentavos, 917);
  assert.equal(exchanged.receipt.returned.totalCentavos + receipt.refund.totalCentavos, 1250);
  assert.deepEqual(ledger(firestore), { returned: { 1: 1250 }, lastReturnId: 'r1', updatedAt: AT });
  await rejectsUnchanged(firestore, service(evenRequest({ idempotencyKey: 'x2',
    returnLines: [{ lineIndex: 1, quantity: '0.001', condition: 'good' }],
    differencePayment: { method: 'cash', amountCentavos: 999 } })), 'out-of-range',
    { reason: 'over-return' });
});

test('an exchange beyond the remaining returnable quantity is out-of-range', async () => {
  const { firestore, service, submitReturn } = fixture();
  await rejectsUnchanged(firestore, service(request({
    returnLines: [{ lineIndex: 0, quantity: '4', condition: 'good' }],
  })), 'out-of-range', { message: 'exchange exceeds the remaining sold quantity', reason: 'over-return' });
  await submitReturn(returnRequest('r1', 0, '2'));
  await rejectsUnchanged(firestore, service(evenRequest({
    returnLines: [{ lineIndex: 0, quantity: '2', condition: 'good' }],
  })), 'out-of-range', { message: 'exchange exceeds the remaining sold quantity', reason: 'over-return' });
  for (const line of [{ lineIndex: 2, quantity: '1' }, { lineIndex: 0, quantity: '0.5' }]) {
    await rejectsUnchanged(firestore, service(evenRequest({
      returnLines: [{ ...line, condition: 'good' }] })), 'invalid-argument');
  }
});

test('buying a product that is being returned is a replacement, not an exchange', async () => {
  const { firestore, service } = fixture();
  for (const newLines of [
    [{ productId: 'p1', quantity: '1' }],
    [{ productId: 'p3', quantity: '1' }, { productId: 'p1', quantity: '1' }],
  ]) {
    await rejectsUnchanged(firestore, service(request({ newLines })), 'invalid-argument',
      { message: 'exchange new items must differ from the returned products' });
  }
  // A factory-defect line is still a returned product.
  await rejectsUnchanged(firestore, service(request({
    returnLines: [{ lineIndex: 0, quantity: '1', condition: 'factory-defect' }],
    newLines: [{ productId: 'p1', quantity: '1' }],
  })), 'invalid-argument', { message: 'exchange new items must differ from the returned products' });
});

test('new items need sellable stock', async () => {
  const low = fixture({}, withRecords([['branches/north/stock/p3', { ...piece, quantityScaled: 0 }]]));
  await rejectsUnchanged(low.firestore, low.service(request()), 'failed-precondition',
    { message: 'insufficient stock', reason: 'insufficient-stock' });
  const none = fixture({}, withRecords([], ['branches/north/stock/p3']));
  await rejectsUnchanged(none.firestore, none.service(request()), 'failed-precondition',
    { message: 'insufficient stock', reason: 'insufficient-stock' });
  const many = fixture();
  await rejectsUnchanged(many.firestore, many.service(request({
    newLines: [{ productId: 'p3', quantity: '5' }],
    differencePayment: { method: 'card', amountCentavos: 6500 },
  })), 'failed-precondition', { message: 'insufficient stock', reason: 'insufficient-stock' });
});

test('a missing new product or one with invalid pricing or specification fails closed', async () => {
  const missing = fixture({}, withRecords([], ['products/p3']));
  await rejectsUnchanged(missing.firestore, missing.service(request()), 'not-found',
    { message: 'product does not exist' });
  for (const [product, message] of [
    [{ quantitySpec: piece }, 'product pricing is invalid'],
    [{ quantitySpec: piece, pricing: { ...pricing(1500), currency: 'USD' } }, 'product pricing is invalid'],
    [{ quantitySpec: piece, pricing: { ...pricing(1500), unitCostCentavos: 1 } },
      'product pricing is invalid'],
    [{ quantitySpec: piece, pricing: { ...pricing(1500), listedPriceCentavos: -1 } },
      'product pricing is invalid'],
    [{ quantitySpec: piece, pricing: { ...pricing(1500), ivaRateBasisPoints: 0 } },
      'product pricing is invalid'],
    [{ quantitySpec: piece, pricing: { ...pricing(1500), version: 1 } }, 'product pricing is invalid'],
    [{ quantitySpec: { ...piece, extra: 1 }, pricing: pricing(1500) },
      'product quantity specification is invalid'],
    [{ pricing: pricing(1500) }, 'product quantity specification is invalid'],
  ]) {
    const { firestore, service } = fixture({}, withRecords([['products/p3', product]]));
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition', { message });
  }
  // A quantity finer than the new product's precision is a request error.
  const { firestore, service } = fixture();
  await rejectsUnchanged(firestore, service(request({ newLines: [{ productId: 'p3', quantity: '0.5' }] })),
    'invalid-argument', { message: 'quantity is not representable by the product specification' });
});

test('a factory-defect returned line is recorded but never restocked', async () => {
  const { firestore, service } = fixture();
  // A defective p1 (10.00) and 0.5 kg of good p2 (5.00) for one p3 (15.00).
  const { receipt } = await service(evenRequest({ reason: 'factory-defect', returnLines: [
    { lineIndex: 0, quantity: '1', condition: 'factory-defect' },
    { lineIndex: 1, quantity: '0.5', condition: 'good' },
  ], newLines: [{ productId: 'p3', quantity: '1' }] }));
  assert.deepEqual(receipt.returned.lines.map((line) => line.condition), ['factory-defect', 'good']);
  assert.equal(receipt.settlement.refundCentavos, 0);
  assert.equal(receipt.settlement.customerPaysCentavos, 0);
  assert.deepEqual(firestore.records.get('inventoryMovements/exchange-x1-in-0'), {
    type: 'exchange-return-defect', exchangeId: 'x1', saleId: 's1', lineIndex: 0, branchId: 'north',
    productId: 'p1', quantityScaled: 1, ...piece, actorId: 'seller-one', occurredAt: AT,
  });
  assert.equal(firestore.records.get('inventoryMovements/exchange-x1-in-1').type, 'exchange-return');
  assert.deepEqual(stock(firestore, 'p1'), { ...piece, quantityScaled: 5 });
  assert.deepEqual(stock(firestore, 'p2'),
    { ...kg, quantityScaled: 2500, updatedAt: AT, lastMovementId: 'exchange-x1-in-1' });
  assert.deepEqual(ledger(firestore).returned, { 0: 1, 1: 500 });
  const sets = firestore.traces.flat().filter(([kind]) => kind === 'set').map(([, path]) => path);
  assert.ok(!sets.includes('branches/north/stock/p1'));
});

test('replay is exact and duplicates no write, even after an abandoned attempt', async () => {
  const { firestore, service } = fixture();
  firestore.retry = true;
  const first = await service(request({ note: 'once' }));
  assert.equal(stock(firestore, 'p3').quantityScaled, 3);
  const before = clone([...firestore.records]);
  const traces = firestore.traces.length;
  const second = await service(request({ note: 'once' }));
  assert.deepEqual(second, { receipt: first.receipt, replayed: true });
  assert.ok(Object.isFrozen(second) && deepFrozen(second.receipt));
  assert.deepEqual([...firestore.records], before);
  assert.deepEqual(firestore.traces.slice(traces), [[['get', 'saleExchangeSubmissionReceipts/x1']]]);
  // A requested '0.5' replays a stored '0.500' by value.
  const kgExchange = fixture();
  const kgInput = evenRequest({ newLines: [{ productId: 'p4', quantity: '0.5' }],
    returnLines: [{ lineIndex: 1, quantity: '0.4', condition: 'good' }] });
  const stored = await kgExchange.service(kgInput);
  assert.deepEqual(await kgExchange.service(kgInput), { receipt: stored.receipt, replayed: true });
});

test('a tampered replay receipt fails closed, including quantity binding', async () => {
  for (const tamper of [
    (result) => { result.returned.lines[0].quantity = '2'; },
    (result) => { result.returned.lines[0].condition = 'factory-defect'; },
    (result) => { result.returned.lines[0].totalCentavos = 1001; },
    (result) => { result.returned.totalCentavos = 999; },
    (result) => { result.newItems.productIds[0] = 'p4'; },
    (result) => { result.newItems.calculation.lines[0].quantity.decimal = '2'; },
    (result) => { result.newItems.calculation.lines[0].quantity.scaled = 2; },
    (result) => { result.newItems.calculation.totalCentavos = 1; },
    (result) => { result.newItems.calculation.lines[0].pricing.unitCostCentavos = 1; },
    (result) => { result.settlement.customerPaysCentavos = 400; },
    (result) => { result.settlement.differencePayment = null; },
    (result) => { result.invoiced = true; },
    (result) => { result.note = 'leaked'; },
  ]) {
    const probe = fixture();
    await probe.service(request());
    tamper(probe.firestore.records.get('saleExchangeSubmissionReceipts/x1').result);
    await rejectsUnchanged(probe.firestore, probe.service(request()), 'failed-precondition',
      { message: 'persisted exchange replay is invalid' });
  }
});

test('a reused key with a different payload, actor or branch is already-exists', async () => {
  const { firestore, service } = fixture();
  await service(request());
  const other = { uid: 'seller-two', token: { role: 'seller', branchId: 'north' } };
  const south = { uid: 'seller-one', token: { role: 'seller', branchId: 'south' } };
  for (const input of [
    request({ returnLines: [{ lineIndex: 0, quantity: '2', condition: 'good' }] }),
    request({ newLines: [{ productId: 'p3', quantity: '2' }] }),
    request({ differencePayment: { method: 'cash', amountCentavos: 500 } }),
    request({ note: 'late note' }), request({ reason: 'other' }),
    request({}, other), request({ saleId: 'foreign' }, south),
  ]) {
    await rejectsUnchanged(firestore, service(input), 'already-exists',
      { message: 'idempotency key is already owned by a different submission' });
  }
});

test('exchange keys share no namespace with returns; orphans are a stable collision', async () => {
  const { service } = fixture({}, withRecords([['saleReturnSubmissionReceipts/x1', { actorId: 'z' }]]));
  assert.equal((await service(request())).replayed, false);
  for (const path of ['saleExchanges/x1', 'saleExchangeAudits/x1',
    'inventoryMovements/exchange-x1-in-0', 'inventoryMovements/exchange-x1-out-0']) {
    const orphan = fixture({}, withRecords([[path, { orphan: true }]]));
    await rejectsUnchanged(orphan.firestore, orphan.service(request()), 'already-exists',
      { message: 'idempotency key collides with existing correction records' });
  }
});

test('foreign and missing sales are the same not-found; expired sales are refused', async () => {
  const { firestore, service } = fixture();
  const message = 'sale was not found in this branch';
  await rejectsUnchanged(firestore, service(request({ saleId: 'foreign' })), 'not-found', { message });
  await rejectsUnchanged(firestore, service(request({ saleId: 'missing' })), 'not-found', { message });
  await rejectsUnchanged(firestore, service(request({ saleId: 'expired' })), 'failed-precondition',
    { message: 'sale is outside the correction window', reason: 'correction-window-closed' });
});

test('malformed persisted ledger or stock fails closed', async () => {
  for (const overrides of [
    [['saleReturnLedgers/s1', { returned: { 0: 4 }, lastReturnId: 'r', updatedAt: AT }]],
    [['saleReturnLedgers/s1', { returned: { 0: 1 }, lastReturnId: 'r', updatedAt: AT, extra: 1 }]],
    [['branches/north/stock/p1', { ...piece, quantityScaled: 5, reserved: 1 }]],
    [['branches/north/stock/p3', { ...piece, quantityScaled: 4, reserved: 1 }]],
  ]) {
    const { firestore, service } = fixture({}, withRecords(overrides));
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
  }
});

test('an invalid clock fails new exchanges but never historical replay', async () => {
  const { firestore, service } = fixture();
  await service(request());
  for (const clock of [() => new Date(NaN), () => 'now', () => { throw new Error('clock'); }]) {
    const broken = exchanges.createSaleExchangeService({ firestore, environment, now: clock });
    assert.equal((await broken(request())).replayed, true);
    await rejectsUnchanged(firestore, broken(request({ idempotencyKey: 'x2' })), 'failed-precondition',
      { message: 'exchange clock is invalid' });
  }
});

test('no written document carries cost fields and caller mutation cannot alter the submission', async () => {
  const { firestore, service } = fixture();
  const sale = clone(firestore.records.get('sales/s1'));
  const input = request();
  const pending = service(input);
  input.data.newLines[0].quantity = '3';
  input.data.returnLines[0].quantity = '3';
  input.data.differencePayment.amountCentavos = 1;
  input.data.saleId = 'foreign';
  const { receipt } = await pending;
  assert.equal(receipt.returned.lines[0].quantity, '1');
  assert.equal(receipt.newItems.calculation.lines[0].quantity.decimal, '1');
  for (const [path, value] of firestore.records) {
    if (path.startsWith('products/') || path.startsWith('sales/')) continue;
    assert.ok(!/cost/i.test(JSON.stringify(value)), `cost field written at ${path}`);
  }
  assert.deepEqual(firestore.records.get('sales/s1'), sale);
});

// A sale whose lines may repeat a product; both lines priced at 10.00 per unit.
function repeatedProductSale(saleId, lines) {
  const calculation = clone(calculateSale({ invoiceRequested: false, lines: lines.map(
    ({ quantity, spec }) => ({ quantity, quantitySpec: spec, pricing: pricing(1000) })) }));
  return {
    receipt: {
      version: 1, saleId, branchId: 'north', productIds: lines.map(() => 'p1'), calculation,
      payment: { method: 'cash', amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(NOW - DAY),
  };
}

test('good returned lines of one product merge into a single restock write', async () => {
  const { firestore, service } = fixture({}, withRecords([['sales/dup', repeatedProductSale('dup', [
    { quantity: '3', spec: piece }, { quantity: '2', spec: piece }])]]));
  // One p1 from line 0 and two from line 1 (30.00) for two p3 (30.00): even.
  const { receipt } = await service(evenRequest({ saleId: 'dup', returnLines: [
    { lineIndex: 0, quantity: '1', condition: 'good' },
    { lineIndex: 1, quantity: '2', condition: 'good' },
  ], newLines: [{ productId: 'p3', quantity: '2' }] }));
  assert.equal(receipt.settlement.returnedCentavos, 3000);
  assert.equal(receipt.settlement.customerPaysCentavos, 0);
  assert.equal(receipt.settlement.refundCentavos, 0);
  assert.deepEqual(stock(firestore, 'p1'),
    { ...piece, quantityScaled: 8, updatedAt: AT, lastMovementId: 'exchange-x1-in-1' });
  const sets = firestore.traces.flat().filter(([kind]) => kind === 'set').map(([, path]) => path);
  assert.equal(sets.filter((path) => path === 'branches/north/stock/p1').length, 1);
  for (const [index, quantityScaled] of [[0, 1], [1, 2]]) {
    const movement = firestore.records.get(`inventoryMovements/exchange-x1-in-${index}`);
    assert.equal(movement.type, 'exchange-return');
    assert.equal(movement.lineIndex, index);
    assert.equal(movement.quantityScaled, quantityScaled);
  }
  assert.deepEqual(ledger(firestore, 'dup').returned, { 0: 1, 1: 2 });
});

test('returned lines of one product with different specifications fail closed', async () => {
  const { firestore, service } = fixture({}, withRecords([['sales/split', repeatedProductSale('split', [
    { quantity: '3', spec: piece }, { quantity: '1.250', spec: kg }])]]));
  // One piece (10.00) and 0.5 kg (5.00) of p1 for one p3 (15.00) would be even.
  await rejectsUnchanged(firestore, service(evenRequest({ saleId: 'split', returnLines: [
    { lineIndex: 0, quantity: '1', condition: 'good' },
    { lineIndex: 1, quantity: '0.5', condition: 'good' },
  ] })), 'failed-precondition', { message: 'sale lines disagree on a product specification' });
});

test('descending line indexes with mixed conditions keep request order and restock only good units', async () => {
  const { firestore, service } = fixture();
  // 0.5 kg of good p2 (5.00) then a defective p1 (10.00), for one p3 (15.00): even.
  const { receipt } = await service(evenRequest({ reason: 'factory-defect', returnLines: [
    { lineIndex: 1, quantity: '0.5', condition: 'good' },
    { lineIndex: 0, quantity: '1', condition: 'factory-defect' },
  ] }));
  assert.deepEqual(receipt.returned.lines, [
    { lineIndex: 1, productId: 'p2', quantity: '0.500', condition: 'good',
      baseCentavos: 500, additionalIvaCentavos: 0, totalCentavos: 500 },
    { lineIndex: 0, productId: 'p1', quantity: '1', condition: 'factory-defect',
      baseCentavos: 1000, additionalIvaCentavos: 0, totalCentavos: 1000 },
  ]);
  assert.equal(receipt.returned.totalCentavos, 1500);
  const movement = { exchangeId: 'x1', saleId: 's1', branchId: 'north', actorId: 'seller-one', occurredAt: AT };
  assert.deepEqual(firestore.records.get('inventoryMovements/exchange-x1-in-0'), {
    type: 'exchange-return', ...movement, lineIndex: 1, productId: 'p2', quantityScaled: 500, ...kg,
  });
  assert.deepEqual(firestore.records.get('inventoryMovements/exchange-x1-in-1'), {
    type: 'exchange-return-defect', ...movement, lineIndex: 0, productId: 'p1', quantityScaled: 1, ...piece,
  });
  assert.deepEqual(stock(firestore, 'p2'),
    { ...kg, quantityScaled: 2500, updatedAt: AT, lastMovementId: 'exchange-x1-in-0' });
  // No factory-defect unit re-enters sellable stock: p1 keeps its seeded projection.
  assert.deepEqual(stock(firestore, 'p1'), { ...piece, quantityScaled: 5 });
  const sets = firestore.traces.flat().filter(([kind]) => kind === 'set').map(([, path]) => path);
  assert.ok(!sets.includes('branches/north/stock/p1'));
  assert.deepEqual(ledger(firestore).returned, { 0: 1, 1: 500 });
});

test('an exchange over the 50-line limit on either side is refused before any document read', async () => {
  const returnLines = (count) => Array.from({ length: count }, (_, lineIndex) => ({
    lineIndex, quantity: '1', condition: 'good',
  }));
  const newLines = (count) => Array.from({ length: count }, (_, i) => ({ productId: `n${i}`, quantity: '1' }));
  for (const data of [{ returnLines: returnLines(51) }, { newLines: newLines(51) }]) {
    const over = fixture();
    await rejectsUnchanged(over.firestore, over.service(request(data)), 'invalid-argument');
    assert.deepEqual(over.firestore.traces, []);
  }
  const at = fixture();
  await assert.rejects(at.service(request({ returnLines: returnLines(50), newLines: newLines(50) })));
  assert.ok(at.firestore.traces.length > 0);
});
