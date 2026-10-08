import assert from 'node:assert/strict';
import test from 'node:test';
import * as sales from '../src/sales.js';

const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const additional = {
  currency: 'MXN', listedPriceCentavos: 100, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const included = { ...additional, listedPriceCentavos: 101, priceMode: 'iva-included' };
const piece = { unit: 'piece', precision: 0 };
const kg = { unit: 'kg', precision: 3 };
const clone = (value) => structuredClone(value);

// Serial in-memory transactions: records every read, the transaction options
// and every buffered write, so tests can prove a quote never mutates anything.
class FakeFirestore {
  constructor() {
    this.records = new Map([
      ['branches/north', { name: 'North', code: 'NTE' }],
      // Stored acquisition costs must never reach a quote response.
      ['products/p1', { quantitySpec: piece, pricing: additional, unitCostCentavos: 40 }],
      ['products/p2', { quantitySpec: kg, pricing: included, averageCostCentavos: 55 }],
      ['branches/north/stock/p1', { ...piece, quantityScaled: 10 }],
      ['branches/north/stock/p2', { ...kg, quantityScaled: 1000 }],
    ].map(([path, value]) => [path, clone(value)]));
    this.reads = [];
    this.options = [];
    this.writes = [];
  }

  doc(path) {
    return { path };
  }

  async runTransaction(callback, options) {
    this.options.push(options);
    const buffered = [];
    const transaction = {
      get: async ({ path }) => {
        // A sale reads its own replay guard; nothing reads costs or audits.
        assert.ok(!/cost|audit/i.test(path), `forbidden read: ${path}`);
        this.reads.push(path);
        const data = this.records.get(path);
        return { exists: this.records.has(path), data: () => clone(data) };
      },
      create: ({ path }, data) => buffered.push(['create', path, clone(data)]),
      set: ({ path }, data) => buffered.push(['set', path, clone(data)]),
      update: ({ path }, data) => buffered.push(['update', path, clone(data)]),
      delete: ({ path }) => buffered.push(['delete', path]),
    };
    const result = await callback(transaction);
    for (const [kind, path, data] of buffered) {
      if (kind === 'create' && this.records.has(path)) throw new Error('create-only conflict');
      this.records.set(path, data);
      this.writes.push(path);
    }
    return result;
  }
}

function fixture(options = {}) {
  const firestore = new FakeFirestore();
  const quote = sales.createSaleQuoteService({ firestore, environment, ...options });
  const submit = sales.createSaleService({
    firestore, environment, now: () => new Date('2026-06-01T12:00:00Z'),
  });
  return { firestore, quote, submit };
}

const twoLines = [{ productId: 'p1', quantity: '2' }, { productId: 'p2', quantity: '0.125' }];
const quoteRequest = (data = {}) => ({
  auth: clone(auth), data: { invoiceRequested: true, lines: clone(twoLines), ...data },
});

async function rejectsWith(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof sales.SaleError, `unexpected ${error}`);
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
}

test('factory validates injected dependencies and returns the quote operation', () => {
  assert.throws(() => sales.createSaleQuoteService(), TypeError);
  assert.throws(() => sales.createSaleQuoteService({ firestore: { doc() {} }, environment }), TypeError);
  assert.equal(typeof fixture().quote, 'function');
});

test('the emulator guard and seller authorization run before any read', async () => {
  for (const env of [{}, { ...environment, FIRESTORE_EMULATOR_HOST: 'localhost:8080' }]) {
    const { firestore, quote } = fixture({ environment: env });
    await rejectsWith(quote(quoteRequest()), 'failed-precondition');
    assert.deepEqual(firestore.reads, []);
  }
  for (const [candidate, code] of [
    [undefined, 'unauthenticated'], [{ uid: '' }, 'unauthenticated'],
    [{ uid: 'x', token: { role: 'administrator', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
  ]) {
    const { firestore, quote } = fixture();
    await rejectsWith(quote({ ...quoteRequest(), auth: candidate }), code);
    assert.deepEqual(firestore.reads, []);
  }
});

test('the request is exactly invoice intent and lines, validated like a sale', async () => {
  const line = (quantity, productId = 'p1') => ({ lines: [{ productId, quantity }] });
  for (const data of [
    undefined, null, [], {}, { invoiceRequested: true }, { lines: twoLines },
    { invoiceRequested: 1, lines: twoLines }, { invoiceRequested: true, lines: [] },
    { invoiceRequested: true, lines: [undefined] }, { invoiceRequested: true, lines: new Array(1) },
    { invoiceRequested: true, lines: twoLines, branchId: 'south' },
    { invoiceRequested: true, lines: twoLines, idempotencyKey: '3f2a9c1b-7d4e' },
    { invoiceRequested: true, lines: twoLines, payment: { method: 'cash', amountCentavos: 1 } },
    ...['0', '-1', '01', ' 2', '2.', '.5', '1e2', 2, '1'.repeat(19)].map((quantity) => ({
      invoiceRequested: true, ...line(quantity),
    })),
    { invoiceRequested: true, ...line('2', '../p1') },
    { invoiceRequested: true, lines: [{ productId: 'p1', quantity: '2', pricing: additional }] },
    { invoiceRequested: true, lines: [{ productId: 'p1', quantity: '1' }, { productId: 'p1', quantity: '1' }] },
  ]) {
    const { firestore, quote } = fixture();
    await rejectsWith(quote({ auth: clone(auth), data }), 'invalid-argument',
      'quote request contains missing, invalid or unsupported fields');
    assert.deepEqual(firestore.reads, []);
  }
});

test('a quote is the exact sale calculation from current pricing, read-only and cost-free', async () => {
  const { firestore, quote } = fixture();
  const result = await quote(quoteRequest());
  const expected = sales.calculateSale({ invoiceRequested: true, lines: [
    { quantity: '2', quantitySpec: piece, pricing: additional },
    { quantity: '0.125', quantitySpec: kg, pricing: included },
  ] });
  assert.deepEqual(Object.keys(result).sort(), ['calculation', 'lines', 'totalCentavos']);
  assert.deepEqual(result.calculation, expected);
  assert.equal(result.totalCentavos, expected.totalCentavos);
  assert.equal(result.totalCentavos, 245);
  assert.deepEqual(result.lines, [
    { productId: 'p1', available: true }, { productId: 'p2', available: true },
  ]);
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.lines) && Object.isFrozen(result.lines[0]));
  assert.ok(Object.isFrozen(result.calculation.lines[1].pricing));
  assert.ok(!/cost|NTE|north|seller/i.test(JSON.stringify(result)), 'no private or branch data');
  assert.deepEqual(firestore.options, [{ readOnly: true }]);
  assert.deepEqual(firestore.reads.sort(), [
    'branches/north', 'branches/north/stock/p1', 'branches/north/stock/p2', 'products/p1', 'products/p2',
  ]);
  assert.deepEqual(firestore.writes, []);
});

test('insufficient or absent stock is reported per line instead of thrown', async () => {
  const { firestore, quote } = fixture();
  firestore.records.get('branches/north/stock/p1').quantityScaled = 1;
  firestore.records.delete('branches/north/stock/p2');
  const result = await quote(quoteRequest({ invoiceRequested: false }));
  assert.deepEqual(result.lines, [
    { productId: 'p1', available: false }, { productId: 'p2', available: false },
  ]);
  assert.equal(result.totalCentavos, 213);
  firestore.records.get('branches/north/stock/p1').quantityScaled = 2;
  const exact = await quote(quoteRequest({ lines: [{ productId: 'p1', quantity: '2' }] }));
  assert.deepEqual(exact.lines, [{ productId: 'p1', available: true }]);
  assert.deepEqual(firestore.writes, []);
});

test('branch, product, pricing, specification and stock faults fail exactly like a sale', async () => {
  const amount = 245;
  const cases = [
    ['not-found', (db) => db.records.delete('branches/north')],
    ['failed-precondition', (db) => { delete db.records.get('branches/north').code; }],
    ['failed-precondition', (db) => { db.records.get('branches/north').code = 'nte'; }],
    ['not-found', (db) => db.records.delete('products/p2')],
    ['failed-precondition', (db) => { delete db.records.get('products/p1').pricing; }],
    ['failed-precondition', (db) => { db.records.get('products/p1').pricing.cost = 1; }],
    ['failed-precondition', (db) => { db.records.get('products/p1').pricing.ivaRateBasisPoints = 0; }],
    ['failed-precondition', (db) => { db.records.get('products/p2').quantitySpec.precision = 7; }],
    ['failed-precondition', (db) => { db.records.get('branches/north/stock/p1').precision = 1; }],
    ['failed-precondition', (db) => { db.records.get('branches/north/stock/p2').quantityScaled = -1; }],
    ['invalid-argument', (db) => { db.records.get('products/p1').quantitySpec = kg; }, '0.0001'],
    ['out-of-range', (db) => {
      db.records.get('products/p1').pricing.listedPriceCentavos = Number.MAX_SAFE_INTEGER;
    }],
  ];
  for (const [code, mutate, p1Quantity = '2'] of cases) {
    const lines = [{ productId: 'p1', quantity: p1Quantity }, twoLines[1]];
    const quoted = fixture();
    mutate(quoted.firestore);
    await rejectsWith(quoted.quote(quoteRequest({ lines })), code);
    assert.deepEqual(quoted.firestore.writes, []);
    const sold = fixture();
    mutate(sold.firestore);
    await rejectsWith(sold.submit({ auth: clone(auth), data: {
      idempotencyKey: '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab', invoiceRequested: true, lines,
      payment: { method: 'cash', amountCentavos: amount },
    } }), code);
  }
});

test('the quoted total is exactly the amount submitSale accepts for the same pricing', async () => {
  for (const invoiceRequested of [true, false]) {
    for (const lines of [twoLines, [twoLines[1]], [{ productId: 'p1', quantity: '7' }]]) {
      const { firestore, quote, submit } = fixture();
      const quoted = await quote(quoteRequest({ invoiceRequested, lines }));
      const sale = (amountCentavos, idempotencyKey) => submit({ auth: clone(auth), data: {
        idempotencyKey, invoiceRequested, lines: clone(lines),
        payment: { method: 'card', amountCentavos },
      } });
      for (const delta of [-1, 1]) {
        await rejectsWith(sale(quoted.totalCentavos + delta, '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab'),
          'invalid-argument', 'full payment must equal the authoritative total');
      }
      const { receipt } = await sale(quoted.totalCentavos, '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab');
      assert.equal(receipt.payment.amountCentavos, quoted.totalCentavos);
      assert.deepEqual(receipt.calculation, quoted.calculation);
      assert.ok(firestore.writes.length > 0, 'the sale itself committed');
    }
  }
});

test('a repriced product is quoted at its current published price', async () => {
  const { firestore, quote } = fixture();
  const before = await quote(quoteRequest({ lines: [{ productId: 'p1', quantity: '1' }] }));
  firestore.records.get('products/p1').pricing.listedPriceCentavos = 250;
  const after = await quote(quoteRequest({ lines: [{ productId: 'p1', quantity: '1' }] }));
  assert.deepEqual([before.totalCentavos, after.totalCentavos], [116, 290]);
});

test('shared line preparation keeps the sale error order: an earlier short line fails first', async () => {
  const { firestore, quote, submit } = fixture();
  firestore.records.get('branches/north/stock/p1').quantityScaled = 1;
  firestore.records.delete('products/p2');
  await rejectsWith(submit({ auth: clone(auth), data: {
    idempotencyKey: '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab', invoiceRequested: true, lines: clone(twoLines),
    payment: { method: 'cash', amountCentavos: 245 },
  } }), 'failed-precondition', 'insufficient stock');
  // A quote reports shortage instead of failing, so the later fault decides.
  await rejectsWith(quote(quoteRequest()), 'not-found', 'product does not exist');
  assert.deepEqual(firestore.writes, []);
});
