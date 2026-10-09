import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import * as returns from '../src/sale-returns.js';
import * as exchanges from '../src/sale-exchanges.js';

// CORR-07P: the read-only previews must give exactly what the real submit
// would produce right now, through the same checks, and never write.
const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const DAY = 24 * 60 * 60 * 1000;
const piece = { unit: 'piece', precision: 0 };
const kg = { unit: 'kg', precision: 3 };
const pricing = (listedPriceCentavos) => ({
  currency: 'MXN', listedPriceCentavos, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
});
const clone = (value) => structuredClone(value);
const RETURN_PREVIEW_INVALID = 'return preview request contains missing, invalid or unsupported fields';
const EXCHANGE_PREVIEW_INVALID = 'exchange preview request contains missing, invalid or unsupported fields';

// Line 0: 3 pieces of p1 at 10.00. Line 1: 1.250 kg of p2 at 9.99/kg.
function saleRecord(saleId, branchId, createdAtMs, { invoiceRequested = false, method = 'cash' } = {}) {
  const calculation = clone(calculateSale({ invoiceRequested, lines: [
    { quantity: '3', quantitySpec: piece, pricing: pricing(1000) },
    { quantity: '1.250', quantitySpec: kg, pricing: pricing(999) },
  ] }));
  return {
    receipt: {
      version: 1, saleId, branchId, productIds: ['p1', 'p2'], calculation,
      payment: { method, amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(createdAtMs),
  };
}

// Products carry a private cost beside the published policy: it must never
// reach a preview. p3 (15.00) and p5 (10.00) are pieces, p4 is by the kg.
function baseRecords() {
  return [
    ['sales/s1', saleRecord('s1', 'north', NOW - DAY)],
    ['sales/inv', saleRecord('inv', 'north', NOW - DAY, { invoiceRequested: true, method: 'card' })],
    ['sales/foreign', saleRecord('foreign', 'south', NOW - DAY)],
    ['sales/expired', saleRecord('expired', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/future', saleRecord('future', 'north', NOW + 1)],
    ['products/p1', { quantitySpec: piece, pricing: pricing(1000), unitCostCentavos: 400 }],
    ['products/p2', { quantitySpec: kg, pricing: pricing(999), unitCostCentavos: 400 }],
    ['products/p3', { quantitySpec: piece, pricing: pricing(1500), unitCostCentavos: 700 }],
    ['products/p4', { quantitySpec: kg, pricing: pricing(800), unitCostCentavos: 300 }],
    ['products/p5', { quantitySpec: piece, pricing: pricing(1000), unitCostCentavos: 500 }],
    ['branches/north/stock/p1', { ...piece, quantityScaled: 5 }],
    ['branches/north/stock/p2', { ...kg, quantityScaled: 2000 }],
    ['branches/north/stock/p3', { ...piece, quantityScaled: 4 }],
    ['branches/north/stock/p4', { ...kg, quantityScaled: 3000 }],
    ['branches/north/stock/p5', { ...piece, quantityScaled: 10 }],
  ];
}

// Serial in-memory transactions with buffered writes; records every
// transaction's options and operations so read-only previews are observable.
class FakeFirestore {
  constructor(records = baseRecords()) {
    this.records = new Map(records.map(([path, value]) => [path, clone(value)]));
    this.transactions = [];
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+(?:\/[^/]+\/[^/]+)?$/);
    assert.ok(!/cost/i.test(path), `forbidden read: ${path}`);
    return { path };
  }

  async runTransaction(callback, options) {
    const writes = [];
    const trace = { options, reads: [], writes };
    this.transactions.push(trace);
    const result = await callback({
      get: async ({ path }) => {
        assert.equal(writes.length, 0, 'all reads precede every write');
        trace.reads.push(path);
        return { exists: this.records.has(path), data: () => clone(this.records.get(path)) };
      },
      create: ({ path }, data) => { writes.push({ kind: 'create', path, data: clone(data) }); },
      set: ({ path }, data) => { writes.push({ kind: 'set', path, data: clone(data) }); },
    });
    const next = new Map(this.records);
    for (const { kind, path, data } of writes) {
      if (kind === 'create' && next.has(path)) throw new Error('create-only conflict');
      next.set(path, data);
    }
    this.records = next;
    return result;
  }
}

function withRecords(overrides = [], removals = []) {
  const records = new Map(baseRecords());
  for (const [path, value] of overrides) records.set(path, value);
  for (const path of removals) records.delete(path);
  return [...records];
}

function fixture(records = undefined, options = {}) {
  const firestore = new FakeFirestore(records);
  const shared = { firestore, environment, now: () => new Date(NOW), ...options };
  return {
    firestore,
    previewReturn: returns.createSaleReturnPreviewService(shared),
    submitReturn: returns.createSaleReturnService(shared),
    previewExchange: exchanges.createSaleExchangePreviewService(shared),
    submitExchange: exchanges.createSaleExchangeService(shared),
  };
}

const returnData = (data = {}) => ({
  saleId: 's1', reason: 'change-of-mind',
  lines: [{ lineIndex: 0, quantity: '1', condition: 'good' }], ...data,
});
// Default: return one good p1 (10.00) for one p3 (15.00); the customer owes 5.00.
const exchangeData = (data = {}) => ({
  saleId: 's1', reason: 'wrong-product',
  returnLines: [{ lineIndex: 0, quantity: '1', condition: 'good' }],
  newLines: [{ productId: 'p3', quantity: '1' }], ...data,
});
const asRequest = (data, actor = auth) => ({ auth: clone(actor), data: clone(data) });

async function outcome(promise) {
  try {
    return { value: await promise };
  } catch (error) {
    assert.ok(error instanceof SaleError, `unexpected ${error?.stack ?? error}`);
    return { error: { code: error.code, message: error.message, reason: error.reason } };
  }
}

// The preview leaves the store exactly as it was, inside read-only transactions.
// `start` is a thunk: the transaction is opened synchronously when it is called.
async function previewUnchanged(firestore, start) {
  const before = clone([...firestore.records]);
  const count = firestore.transactions.length;
  const result = await outcome(start());
  assert.ok(firestore.transactions.length > count || result.error, 'a successful preview reads in a transaction');
  assert.deepEqual([...firestore.records], before, 'a preview writes nothing');
  for (const trace of firestore.transactions.slice(count)) {
    assert.deepEqual(trace.options, { readOnly: true });
    assert.deepEqual(trace.writes, []);
  }
  return result;
}

const returnPart = ({ saleId, lines, refund, invoiced }) => ({ saleId, lines, refund, invoiced });
const exchangePart = ({ saleId, returned, newItems, settlement, invoiced }) => {
  const { differencePayment, ...amounts } = settlement;
  return { saleId, returned, newItems, settlement: amounts, invoiced };
};
const deepFrozen = (value) => value === null || typeof value !== 'object'
  || (Object.isFrozen(value) && Object.values(value).every(deepFrozen));

test('preview factories validate injected dependencies', () => {
  for (const create of [returns.createSaleReturnPreviewService, exchanges.createSaleExchangePreviewService]) {
    assert.throws(() => create(), TypeError);
    assert.throws(() => create({ firestore: { doc() {} } }), TypeError);
    assert.throws(() => create({ firestore: new FakeFirestore(), now: 'today' }), TypeError);
  }
});

test('previews run the emulator guard and seller authorization before any read', async () => {
  const kinds = [['previewReturn', returnData()], ['previewExchange', exchangeData()]];
  for (const [name, data] of kinds) {
    const denied = fixture(undefined, { environment: { ...environment, GCLOUD_PROJECT: 'production' } });
    assert.deepEqual((await outcome(denied[name](asRequest(data)))).error.code, 'failed-precondition');
    assert.equal(denied.firestore.transactions.length, 0);
    for (const [actor, code] of [
      [undefined, 'unauthenticated'], [{ uid: '', token: { role: 'seller', branchId: 'north' } }, 'unauthenticated'],
      [{ uid: 'a', token: { role: 'administrator' } }, 'permission-denied'],
      [{ uid: 'a', token: { role: 'client', branchId: 'north' } }, 'permission-denied'],
      [{ uid: 'a', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
    ]) {
      const service = fixture();
      const result = await outcome(service[name]({ auth: actor, data: clone(data) }));
      assert.equal(result.error.code, code);
      assert.equal(service.firestore.transactions.length, 0);
    }
  }
});

test('preview requests are the submit requests without write-only fields', async () => {
  const returnCases = [
    returnData({ idempotencyKey: 'r1' }), returnData({ note: 'Changed mind' }), { ...returnData(), extra: 1 },
    returnData({ reason: 'customer-damage' }), returnData({ saleId: '../s1' }),
    returnData({ lines: [] }), returnData({ lines: [{ lineIndex: 0, quantity: '1', condition: 'customer-damage' }] }),
    returnData({ lines: [{ lineIndex: 0, quantity: '01', condition: 'good' }] }),
    returnData({ lines: [{ lineIndex: 0, quantity: '1', condition: 'good' },
      { lineIndex: 0, quantity: '1', condition: 'good' }] }),
    null, [],
  ];
  for (const data of returnCases) {
    const { firestore, previewReturn } = fixture();
    const result = await previewUnchanged(firestore, () => previewReturn({ auth: clone(auth), data: clone(data) }));
    assert.deepEqual(result.error, { code: 'invalid-argument', message: RETURN_PREVIEW_INVALID, reason: undefined });
    assert.equal(firestore.transactions.length, 0);
  }
  const exchangeCases = [
    exchangeData({ idempotencyKey: 'x1' }), exchangeData({ note: 'Other model' }),
    exchangeData({ differencePayment: { method: 'card', amountCentavos: 500 } }),
    exchangeData({ reason: 'customer-damage' }), exchangeData({ newLines: [] }),
    exchangeData({ newLines: [{ productId: 'p3', quantity: '1' }, { productId: 'p3', quantity: '2' }] }),
    exchangeData({ returnLines: [{ lineIndex: -1, quantity: '1', condition: 'good' }] }),
  ];
  for (const data of exchangeCases) {
    const { firestore, previewExchange } = fixture();
    const result = await previewUnchanged(firestore, () => previewExchange(asRequest(data)));
    assert.deepEqual(result.error, { code: 'invalid-argument', message: EXCHANGE_PREVIEW_INVALID, reason: undefined });
    assert.equal(firestore.transactions.length, 0);
  }
});

test('a return preview equals the later submit for plain and invoiced sales, mixed conditions', async () => {
  const requests = [
    returnData(),
    returnData({ lines: [{ lineIndex: 1, quantity: '0.417', condition: 'factory-defect' },
      { lineIndex: 0, quantity: '2', condition: 'good' }] }),
    returnData({ saleId: 'inv', reason: 'other', lines: [{ lineIndex: 0, quantity: '3', condition: 'good' },
      { lineIndex: 1, quantity: '1.250', condition: 'good' }] }),
  ];
  for (const data of requests) {
    const { firestore, previewReturn, submitReturn } = fixture();
    const preview = await previewUnchanged(firestore, () => previewReturn(asRequest(data)));
    assert.ok(deepFrozen(preview.value));
    assert.ok(!JSON.stringify(preview.value).toLowerCase().includes('cost'));
    const { receipt } = await submitReturn(asRequest({ idempotencyKey: 'r1', ...data }));
    assert.deepEqual(preview.value, returnPart(receipt));
  }
  // Independent: the whole invoiced sale refunds 30.00 + 4.80 and 12.49 + 2.00 by card.
  const { previewReturn } = fixture();
  const { value } = await outcome(previewReturn(asRequest(requests[2])));
  assert.deepEqual(value.refund, { method: 'card', baseCentavos: 4249, additionalIvaCentavos: 680, totalCentavos: 4929 });
  assert.equal(value.invoiced, true);
});

test('after partial returns the preview applies cumulative rounding exactly like the submit', async () => {
  const { firestore, previewReturn, submitReturn } = fixture();
  const parts = ['0.417', '0.416', '0.417'];
  let refunded = 0;
  for (const [index, quantity] of parts.entries()) {
    const data = returnData({ saleId: 'inv', lines: [{ lineIndex: 1, quantity, condition: 'good' }] });
    const preview = await previewUnchanged(firestore, () => previewReturn(asRequest(data)));
    const { receipt } = await submitReturn(asRequest({ idempotencyKey: `r${index}`, ...data }));
    assert.deepEqual(preview.value, returnPart(receipt));
    refunded += receipt.refund.totalCentavos;
  }
  // The three cumulative refunds add up exactly to the line total (12.49 + 2.00).
  assert.equal(refunded, 1449);
  const over = await previewUnchanged(firestore, () => previewReturn(asRequest(returnData({
    saleId: 'inv', lines: [{ lineIndex: 1, quantity: '0.001', condition: 'good' }] }))));
  assert.deepEqual(over.error,
    { code: 'out-of-range', message: 'return exceeds the remaining sold quantity', reason: undefined });
});

// Every rejection the submit gives for these states, the preview gives too.
const returnFailures = [
  ['foreign', [], [], returnData({ saleId: 'foreign' })],
  ['missing', [], [], returnData({ saleId: 'nope' })],
  ['expired', [], [], returnData({ saleId: 'expired' })],
  ['future', [], [], returnData({ saleId: 'future' })],
  ['over-return', [], [], returnData({ lines: [{ lineIndex: 0, quantity: '4', condition: 'good' }] })],
  ['unknown line', [], [], returnData({ lines: [{ lineIndex: 2, quantity: '1', condition: 'good' }] })],
  ['precision', [], [], returnData({ lines: [{ lineIndex: 0, quantity: '0.5', condition: 'good' }] })],
  ['ledger', [['saleReturnLedgers/s1', { returned: { 0: 4 }, lastReturnId: 'x', updatedAt: new Date(NOW) }]], [],
    returnData()],
  ['product spec', [['products/p1', { quantitySpec: kg, pricing: pricing(1000) }]], [], returnData()],
  ['missing product', [], ['products/p1'], returnData()],
  ['stock shape', [['branches/north/stock/p1', { ...piece, quantityScaled: 5, extra: true }]], [], returnData()],
  ['stock bound', [['branches/north/stock/p1', { ...piece, quantityScaled: Number.MAX_SAFE_INTEGER }]], [],
    returnData()],
  ['tampered sale', [['sales/s1', (() => {
    const record = saleRecord('s1', 'north', NOW - DAY);
    record.receipt.calculation.lines[0].totalCentavos += 1;
    return record;
  })()]], [], returnData()],
];

test('a return preview rejects exactly as the submit does', async () => {
  for (const [label, overrides, removals, data] of returnFailures) {
    const submitted = fixture(withRecords(overrides, removals));
    const expected = await outcome(submitted.submitReturn(asRequest({ idempotencyKey: 'r1', ...data })));
    assert.ok(expected.error, `${label}: the submit must reject`);
    const previewed = fixture(withRecords(overrides, removals));
    const actual = await previewUnchanged(previewed.firestore, () => previewed.previewReturn(asRequest(data)));
    assert.deepEqual(actual, expected, label);
  }
  // A defect line never reads stock, in the preview as in the submit.
  const { firestore, previewReturn } = fixture(withRecords([['branches/north/stock/p1', { bad: true }]]));
  const defect = await previewUnchanged(firestore, () => previewReturn(asRequest(returnData({
    lines: [{ lineIndex: 0, quantity: '1', condition: 'factory-defect' }] }))));
  assert.equal(defect.value.refund.totalCentavos, 1000);
});

test('an invalid clock fails a preview like a new submit', async () => {
  for (const now of [() => new Date(Number.NaN), () => { throw new Error('clock'); }, () => NOW]) {
    const submitted = fixture(undefined, { now });
    const previewed = fixture(undefined, { now });
    const expected = await outcome(submitted.submitReturn(asRequest({ idempotencyKey: 'r1', ...returnData() })));
    assert.deepEqual(await outcome(previewed.previewReturn(asRequest(returnData()))), expected);
    const exchangeExpected = await outcome(submitted.submitExchange(asRequest({ idempotencyKey: 'x1',
      ...exchangeData(), differencePayment: { method: 'card', amountCentavos: 500 } })));
    assert.deepEqual(await outcome(previewed.previewExchange(asRequest(exchangeData()))), exchangeExpected);
  }
});

test('submit error precedence is unchanged: replay, then sale, ledger, lines, collisions, then stock', async () => {
  const badStock = ['branches/north/stock/p1', { ...piece, quantityScaled: -1 }];
  const badLedger = ['saleReturnLedgers/s1', { returned: { 0: 9 }, lastReturnId: 'x', updatedAt: new Date(NOW) }];
  const cases = [
    ['collision before stock', [badStock, ['saleReturns/r1', { stray: true }]], returnData(),
      { code: 'already-exists', message: 'idempotency key collides with existing correction records' }],
    ['window before ledger', [badLedger, ['saleReturnLedgers/expired', badLedger[1]]],
      returnData({ saleId: 'expired' }),
      { code: 'failed-precondition', message: 'sale is outside the correction window' }],
    ['ledger before over-return', [badLedger], returnData({ lines: [{ lineIndex: 0, quantity: '4', condition: 'good' }] }),
      { code: 'failed-precondition', message: 'persisted sale return ledger is invalid' }],
    ['over-return before stock', [badStock], returnData({ lines: [{ lineIndex: 0, quantity: '4', condition: 'good' }] }),
      { code: 'out-of-range', message: 'return exceeds the remaining sold quantity' }],
    ['stock last', [badStock], returnData(),
      { code: 'failed-precondition', message: 'stock projection is invalid' }],
  ];
  for (const [label, overrides, data, error] of cases) {
    const { submitReturn } = fixture(withRecords(overrides));
    assert.deepEqual(await outcome(submitReturn(asRequest({ idempotencyKey: 'r1', ...data }))),
      { error: { ...error, reason: undefined } }, label);
  }
  const exchangeCases = [
    ['collision before restock and new stock', [badStock, ['branches/north/stock/p3', { bad: true }],
      ['saleExchangeAudits/x1', { stray: true }]],
    { code: 'already-exists', message: 'idempotency key collides with existing correction records' }],
    ['restock before new items', [badStock, ['products/p3', { quantitySpec: piece, pricing: { bad: true } }]],
      { code: 'failed-precondition', message: 'stock projection is invalid' }],
    ['new line order decides', [['products/p3', { quantitySpec: piece, pricing: { bad: true } }],
      ['branches/north/stock/p4', { ...kg, quantityScaled: 0 }]],
    { code: 'failed-precondition', message: 'product pricing is invalid' }],
    ['stock before a later line', [['branches/north/stock/p3', { ...piece, quantityScaled: 0 }],
      ['products/p4', { quantitySpec: kg, pricing: { bad: true } }]],
    { code: 'failed-precondition', message: 'insufficient stock' }],
  ];
  const twoNew = exchangeData({ newLines: [{ productId: 'p3', quantity: '1' }, { productId: 'p4', quantity: '0.5' }] });
  for (const [label, overrides, error] of exchangeCases) {
    const { submitExchange } = fixture(withRecords(overrides));
    assert.deepEqual(await outcome(submitExchange(asRequest({ idempotencyKey: 'x1', ...twoNew,
      differencePayment: { method: 'card', amountCentavos: 900 } }))), { error: { ...error, reason: undefined } }, label);
  }
});

test('an exchange preview equals the later submit, and the previewed amount is accepted', async () => {
  const cases = [
    // Customer owes 5.00 on a plain cash sale.
    [exchangeData(), 500, 0],
    // Invoiced card sale: two p1 (23.20) for one p5 (11.60) refunds 11.60 by card.
    [exchangeData({ saleId: 'inv', returnLines: [{ lineIndex: 0, quantity: '2', condition: 'factory-defect' }],
      newLines: [{ productId: 'p5', quantity: '1' }] }), 0, 1160],
    // A kilogram return and a kilogram purchase with per-line rounding.
    [exchangeData({ returnLines: [{ lineIndex: 1, quantity: '0.333', condition: 'good' }],
      newLines: [{ productId: 'p4', quantity: '0.777' }, { productId: 'p5', quantity: '1' }] }), null, null],
  ];
  for (const [data, pays, refund] of cases) {
    const { firestore, previewExchange, submitExchange } = fixture();
    const preview = await previewUnchanged(firestore, () => previewExchange(asRequest(data)));
    assert.ok(preview.value, JSON.stringify(preview.error));
    assert.ok(deepFrozen(preview.value));
    assert.ok(!JSON.stringify(preview.value).toLowerCase().includes('cost'));
    if (pays !== null) assert.equal(preview.value.settlement.customerPaysCentavos, pays);
    if (refund !== null) assert.equal(preview.value.settlement.refundCentavos, refund);
    assert.deepEqual(preview.value.newLines,
      data.newLines.map(({ productId }) => ({ productId, available: true })));
    const owed = preview.value.settlement.customerPaysCentavos;
    const { receipt } = await submitExchange(asRequest({ idempotencyKey: 'x1', ...data,
      ...(owed > 0 ? { differencePayment: { method: 'transfer', amountCentavos: owed } } : {}) }));
    const { newLines, ...amounts } = preview.value;
    assert.deepEqual(amounts, exchangePart(receipt));
  }
});

test('an exchange preview after a partial return applies the ledger like the submit', async () => {
  const { firestore, previewExchange, submitExchange, submitReturn } = fixture();
  await submitReturn(asRequest({ idempotencyKey: 'r1', ...returnData({ saleId: 'inv',
    lines: [{ lineIndex: 1, quantity: '0.417', condition: 'good' }] }) }));
  const data = exchangeData({ saleId: 'inv', returnLines: [{ lineIndex: 1, quantity: '0.833', condition: 'good' }],
    newLines: [{ productId: 'p5', quantity: '1' }] });
  const preview = await previewUnchanged(firestore, () => previewExchange(asRequest(data)));
  // The first 0.417 kg refunded 4.17 + 0.67 (cumulative per component), so the
  // rest returns 14.49 - 4.84 = 9.65 against 11.60: the customer owes 1.95.
  assert.equal(preview.value.settlement.customerPaysCentavos, 195);
  const { receipt } = await submitExchange(asRequest({ idempotencyKey: 'x1', ...data,
    differencePayment: { method: 'cash', amountCentavos: preview.value.settlement.customerPaysCentavos } }));
  const { newLines, ...amounts } = preview.value;
  assert.deepEqual(amounts, exchangePart(receipt));
  // The rest of the line plus the first return is exactly the line total.
  assert.equal(firestore.records.get('saleReturns/r1').receipt.refund.totalCentavos
    + preview.value.returned.totalCentavos, 1449);
});

test('short stock is reported per new line without throwing; the submit still refuses it', async () => {
  const records = withRecords([['branches/north/stock/p3', { ...piece, quantityScaled: 0 }]], ['branches/north/stock/p5']);
  const data = exchangeData({ newLines: [{ productId: 'p3', quantity: '1' }, { productId: 'p4', quantity: '1' },
    { productId: 'p5', quantity: '1' }] });
  const { firestore, previewExchange, submitExchange } = fixture(records);
  const preview = await previewUnchanged(firestore, () => previewExchange(asRequest(data)));
  assert.deepEqual(preview.value.newLines, [
    { productId: 'p3', available: false }, { productId: 'p4', available: true }, { productId: 'p5', available: false },
  ]);
  assert.equal(preview.value.settlement.newItemCentavos, 1500 + 800 + 1000);
  assert.equal(preview.value.settlement.customerPaysCentavos, 3300 - 1000);
  assert.deepEqual(await outcome(submitExchange(asRequest({ idempotencyKey: 'x1', ...data,
    differencePayment: { method: 'cash', amountCentavos: 2300 } }))),
  { error: { code: 'failed-precondition', message: 'insufficient stock', reason: undefined } });
});

const exchangeFailures = [
  ['foreign', [], [], exchangeData({ saleId: 'foreign' })],
  ['expired', [], [], exchangeData({ saleId: 'expired' })],
  ['over-return', [], [], exchangeData({ returnLines: [{ lineIndex: 0, quantity: '4', condition: 'good' }] })],
  ['same product', [], [], exchangeData({ newLines: [{ productId: 'p1', quantity: '1' }] })],
  ['same defect product', [], [], exchangeData({ returnLines: [{ lineIndex: 0, quantity: '1', condition: 'factory-defect' }],
    newLines: [{ productId: 'p1', quantity: '1' }] })],
  ['unknown line', [], [], exchangeData({ returnLines: [{ lineIndex: 5, quantity: '1', condition: 'good' }] })],
  ['missing new product', [], [], exchangeData({ newLines: [{ productId: 'p9', quantity: '1' }] })],
  ['new precision', [], [], exchangeData({ newLines: [{ productId: 'p3', quantity: '1.5' }] })],
  ['new pricing', [['products/p3', { quantitySpec: piece, pricing: { ...pricing(1500), ivaRateBasisPoints: 0 } }]], [],
    exchangeData()],
  ['new pricing currency', [['products/p3', { quantitySpec: piece, pricing: { ...pricing(1500), currency: 'USD' } }]], [],
    exchangeData()],
  ['new stock shape', [['branches/north/stock/p3', { ...piece, quantityScaled: 4, cost: 1 }]], [], exchangeData()],
  ['restock shape', [['branches/north/stock/p1', { ...kg, quantityScaled: 4 }]], [], exchangeData()],
  ['ledger', [['saleReturnLedgers/s1', { returned: [], lastReturnId: 'x', updatedAt: new Date(NOW) }]], [],
    exchangeData()],
  ['overflow', [['products/p3', { quantitySpec: piece, pricing: pricing(Number.MAX_SAFE_INTEGER) }],
    ['branches/north/stock/p3', { ...piece, quantityScaled: 9 }]], [],
  exchangeData({ newLines: [{ productId: 'p3', quantity: '9' }] })],
];

test('an exchange preview rejects exactly as the submit does', async () => {
  for (const [label, overrides, removals, data] of exchangeFailures) {
    const submitted = fixture(withRecords(overrides, removals));
    const expected = await outcome(submitted.submitExchange(asRequest({ idempotencyKey: 'x1', ...data,
      differencePayment: { method: 'card', amountCentavos: 500 } })));
    assert.ok(expected.error, `${label}: the submit must reject`);
    assert.notEqual(expected.error.reason, 'payment-mismatch', label);
    const previewed = fixture(withRecords(overrides, removals));
    const actual = await previewUnchanged(previewed.firestore, () => previewed.previewExchange(asRequest(data)));
    assert.deepEqual(actual, expected, label);
  }
});

test('every difference-payment rejection carries payment-mismatch with unchanged codes and messages', async () => {
  const owes = 'difference payment must equal the amount the customer owes';
  const none = 'difference payment is only accepted when the customer owes money';
  const refundData = exchangeData({ saleId: 'inv', returnLines: [{ lineIndex: 0, quantity: '2', condition: 'good' }],
    newLines: [{ productId: 'p5', quantity: '1' }] });
  for (const [data, payment, message] of [
    [exchangeData(), { method: 'card', amountCentavos: 499 }, owes],
    [exchangeData(), { method: 'card', amountCentavos: 501 }, owes],
    [exchangeData(), undefined, owes],
    [refundData, { method: 'card', amountCentavos: 0 }, none],
    [refundData, { method: 'cash', amountCentavos: 1160 }, none],
  ]) {
    const { firestore, submitExchange } = fixture();
    const before = clone([...firestore.records]);
    const result = await outcome(submitExchange(asRequest({ idempotencyKey: 'x1', ...data,
      ...(payment ? { differencePayment: payment } : {}) })));
    assert.deepEqual(result.error, { code: 'invalid-argument', message, reason: 'payment-mismatch' });
    assert.deepEqual([...firestore.records], before);
  }
});
