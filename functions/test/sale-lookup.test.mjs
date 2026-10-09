import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import * as lookup from '../src/sale-lookup.js';

const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const NOW = new Date('2026-06-16T12:00:00Z').getTime();
const DAY = 24 * 60 * 60 * 1000;
const pricing = {
  currency: 'MXN', listedPriceCentavos: 1000, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const clone = (value) => structuredClone(value);

function saleRecord(saleId, branchId, createdAtMs, invoiceRequested = true) {
  // Detached mutable copy, as Firestore returns it, so tests can corrupt fields.
  const calculation = clone(calculateSale({ invoiceRequested, lines: [
    { quantity: '3', quantitySpec: { unit: 'piece', precision: 0 }, pricing },
    { quantity: '1.250', quantitySpec: { unit: 'kg', precision: 3 }, pricing },
  ] }));
  return {
    receipt: {
      version: 1, saleId, branchId, productIds: ['p1', 'p2'], calculation,
      payment: { method: 'card', amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(createdAtMs),
  };
}

// Serial in-memory read-only transactions with the query subset the service
// uses. Writes are recorded so tests can prove lookups never mutate anything.
class FakeFirestore {
  constructor(records = []) {
    this.records = new Map(records.map(([path, value]) => [path, clone(value)]));
    this.events = [];
    this.queries = [];
    this.writes = [];
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+$/);
    assert.ok(!/cost|audit|submission/i.test(path), `forbidden read: ${path}`);
    return { path };
  }

  collection(name) {
    assert.equal(name, 'sales');
    const query = (filters, order, limit) => ({
      kind: 'query', filters, order, limitValue: limit,
      where: (field, op, value) => query([...filters, [field, op, value]], order, limit),
      orderBy: (field, direction) => query(filters, [field, direction], limit),
      limit: (value) => query(filters, order, value),
    });
    return query([], null, null);
  }

  async runTransaction(callback, options) {
    this.events.push(['transaction', options]);
    const read = (path) => {
      const data = this.records.get(path);
      return { id: path.split('/')[1], exists: this.records.has(path), data: () => clone(data) };
    };
    const transaction = {
      get: async (target) => {
        if (target.kind !== 'query') {
          this.events.push(['get', target.path]);
          return read(target.path);
        }
        this.queries.push(target);
        let docs = [...this.records.keys()].filter((path) => path.startsWith('sales/')).map(read);
        for (const [field, op, value] of target.filters) {
          docs = docs.filter((doc) => {
            const actual = field.split('.').reduce((node, key) => node?.[key], doc.data());
            const compare = actual instanceof Date ? actual.getTime() : actual;
            const expected = value instanceof Date ? value.getTime() : value;
            return { '==': compare === expected, '>': compare > expected, '<=': compare <= expected }[op];
          });
        }
        assert.deepEqual(target.order, ['createdAt', 'desc']);
        docs.sort((a, b) => b.data().createdAt.getTime() - a.data().createdAt.getTime());
        return { docs: docs.slice(0, target.limitValue) };
      },
      create: (ref) => this.writes.push(ref.path),
      set: (ref) => this.writes.push(ref.path),
      update: (ref) => this.writes.push(ref.path),
      delete: (ref) => this.writes.push(ref.path),
    };
    return callback(transaction);
  }
}

function fixture(records = [], options = {}) {
  const firestore = new FakeFirestore(records);
  const service = lookup.createSaleLookupService({
    firestore, environment, now: () => new Date(NOW), ...options,
  });
  return { firestore, service };
}

async function rejectsWith(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof SaleError, `unexpected ${error}`);
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    // Only the ambiguous folio publishes a structured reason.
    assert.equal(error.reason, undefined);
    return true;
  });
}

test('factory validates injected dependencies', () => {
  assert.throws(() => lookup.createSaleLookupService(), TypeError);
  assert.throws(() => lookup.createSaleLookupService({
    firestore: { doc() {}, runTransaction() {} }, environment,
  }), TypeError);
  assert.throws(() => fixture([], { now: 1 }), TypeError);
  const { service } = fixture();
  assert.equal(typeof service.findSale, 'function');
  assert.equal(typeof service.listRecentSales, 'function');
  assert.ok(Object.isFrozen(service));
});

test('the emulator guard and seller authorization run before any read', async () => {
  for (const env of [{}, { ...environment, FIRESTORE_EMULATOR_HOST: 'localhost:8080' }]) {
    const { firestore, service } = fixture([], { environment: env });
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
    await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition');
    assert.deepEqual(firestore.events, []);
  }
  for (const [candidate, code] of [
    [undefined, 'unauthenticated'], [{ uid: '' }, 'unauthenticated'],
    [{ uid: 'x', token: { role: 'administrator', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'auditor', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
  ]) {
    const { firestore, service } = fixture([['sales/s1', saleRecord('s1', 'north', NOW - DAY)]]);
    await rejectsWith(service.findSale({ auth: candidate, data: { saleId: 's1' } }), code);
    await rejectsWith(service.listRecentSales({ auth: candidate, data: {} }), code);
    assert.deepEqual(firestore.events, []);
  }
});

test('requests accept only their exact fields and bounded values', async () => {
  const { firestore, service } = fixture();
  for (const data of [
    undefined, null, [], {}, { saleId: '' }, { saleId: '../s1' }, { saleId: 7 },
    { saleId: 's'.repeat(129) }, { saleId: 's1', branchId: 'north' }, { saleId: 's1', folio: 'NTE-3F2A-9C1B' },
    { folio: '' }, { folio: 7 }, { folio: null }, { folio: 'NTE-3F2A' }, { folio: 'N-3F2A-9C1B' },
    { folio: 'NORTE-3F2A-9C1B' }, { folio: 'NTE_3F2A_9C1B' }, { folio: 'NTE-3F2A-9C1B-0' }, { folio: 'NTE-3F2A-9C1' },
    { folio: 'NTE-3F2A-9C1B', limit: 1 }, { folio: 'N1E-3F2A-9C1B' }, { folio: 'NTE-3F2A-9C\u00c9B' },
    { folio: `${' '.repeat(40)}NTE-3F2A-9C1B` },
  ]) await rejectsWith(service.findSale({ auth, data }), 'invalid-argument');
  for (const data of [
    undefined, null, [], { limit: 0 }, { limit: 101 }, { limit: 1.5 }, { limit: '5' },
    { limit: null }, { branchId: 'south' }, { limit: 5, since: 0 },
  ]) await rejectsWith(service.listRecentSales({ auth, data }), 'invalid-argument');
  assert.deepEqual(firestore.events, []);
});

test('lookup by receipt number returns only correction-relevant fields with remaining quantities', async () => {
  const createdAt = NOW - 3 * DAY;
  const { firestore, service } = fixture([
    ['sales/s1', saleRecord('s1', 'north', createdAt)],
    ['saleReturnLedgers/s1', { returned: { 1: 250 } }],
  ]);
  const result = await service.findSale({ auth, data: { saleId: 's1' } });
  assert.deepEqual(Object.keys(result), ['sale']);
  const { sale } = result;
  const stored = firestore.records.get('sales/s1').receipt;
  assert.deepEqual(Object.keys(sale).sort(), ['createdAt', 'folio', 'lines', 'receipt', 'saleId']);
  assert.equal(sale.saleId, 's1');
  assert.equal(sale.folio, null, 'legacy sales have no folio');
  assert.equal(sale.createdAt, createdAt);
  assert.deepEqual(Object.keys(sale.receipt).sort(),
    ['calculation', 'invoiceRequested', 'payment', 'productIds']);
  assert.deepEqual(sale.receipt.calculation, stored.calculation);
  assert.deepEqual(sale.receipt.payment, stored.payment);
  assert.deepEqual(sale.receipt.productIds, ['p1', 'p2']);
  assert.equal(sale.receipt.invoiceRequested, true);
  assert.deepEqual(sale.lines, [
    { lineIndex: 0, soldScaled: 3, returnedScaled: 0, remainingScaled: 3 },
    { lineIndex: 1, soldScaled: 1250, returnedScaled: 250, remainingScaled: 1000 },
  ]);
  assert.ok(Object.isFrozen(result) && Object.isFrozen(sale.receipt.calculation.lines[0].pricing));
  assert.ok(Object.isFrozen(sale.lines[1]) && Object.isFrozen(sale.receipt.payment));
  const text = JSON.stringify(result);
  for (const field of ['actorId', 'fingerprint', 'cost', 'branchId', 'uid']) {
    assert.ok(!text.includes(field), `private field leaked: ${field}`);
  }
  assert.deepEqual(firestore.events, [
    ['transaction', { readOnly: true }], ['get', 'sales/s1'], ['get', 'saleReturnLedgers/s1'],
  ]);
  assert.deepEqual(firestore.writes, []);
});

test('missing and foreign sales are indistinguishable; expired and future own sales fail the window', async () => {
  const { service } = fixture([
    ['sales/foreign', saleRecord('foreign', 'south', NOW - DAY)],
    ['sales/expired', saleRecord('expired', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/future', saleRecord('future', 'north', NOW + 1)],
    ['sales/edge', saleRecord('edge', 'north', NOW - CORRECTION_WINDOW_MS + 1)],
  ]);
  const notFound = 'sale was not found in this branch';
  await rejectsWith(service.findSale({ auth, data: { saleId: 'missing' } }), 'not-found', notFound);
  await rejectsWith(service.findSale({ auth, data: { saleId: 'foreign' } }), 'not-found', notFound);
  await rejectsWith(service.findSale({ auth, data: { saleId: 'expired' } }), 'failed-precondition');
  await rejectsWith(service.findSale({ auth, data: { saleId: 'future' } }), 'failed-precondition');
  const { sale } = await service.findSale({ auth, data: { saleId: 'edge' } });
  assert.equal(sale.createdAt, NOW - CORRECTION_WINDOW_MS + 1);
  const south = { uid: 'seller-two', token: { role: 'seller', branchId: 'south' } };
  assert.equal((await service.findSale({ auth: south, data: { saleId: 'foreign' } })).sale.saleId, 'foreign');
});

test('a foreign sale is not-found even when its record is malformed', async () => {
  const foreign = saleRecord('bad', 'south', NOW - DAY);
  foreign.receipt.calculation.lines[0].pricing.unitCostCentavos = 1;
  const { service } = fixture([['sales/bad', foreign]]);
  await rejectsWith(service.findSale({ auth, data: { saleId: 'bad' } }), 'not-found');
});

test('malformed persisted sales and ledgers fail closed without leaking extra fields', async () => {
  const cases = [];
  const withCost = saleRecord('s1', 'north', NOW - DAY);
  withCost.receipt.calculation.lines[0].pricing.unitCostCentavos = 400;
  cases.push([withCost]);
  const extraField = saleRecord('s1', 'north', NOW - DAY);
  extraField.actorId = 'seller-one';
  cases.push([extraField]);
  const otherId = saleRecord('other', 'north', NOW - DAY);
  cases.push([otherId]);
  const badTime = saleRecord('s1', 'north', NOW - DAY);
  badTime.createdAt = '2026-06-15';
  cases.push([badTime]);
  const badLines = saleRecord('s1', 'north', NOW - DAY);
  badLines.receipt.calculation.lines[0] = null;
  cases.push([badLines]);
  const badMethod = saleRecord('s1', 'north', NOW - DAY);
  badMethod.receipt.payment.method = 'gift';
  cases.push([badMethod]);
  const valid = saleRecord('s1', 'north', NOW - DAY);
  for (const ledger of [{}, { returned: [] }, { returned: { 0: 4 } }, { returned: { 5: 1 } },
    { returned: { 0: -1 } }]) cases.push([valid, ledger]);
  for (const [record, ledger] of cases) {
    const records = [['sales/s1', record]];
    if (ledger) records.push(['saleReturnLedgers/s1', ledger]);
    const { service } = fixture(records);
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
  }
});

test('an invalid clock fails the lookup with a domain error', async () => {
  for (const clock of [() => new Date(NaN), () => 'now', () => { throw new Error('clock'); }]) {
    const { service } = fixture([['sales/s1', saleRecord('s1', 'north', NOW - DAY)]], { now: clock });
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
    await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition');
  }
});

test('recent sales list only the seller branch inside the window, newest first', async () => {
  const records = [
    ['sales/old', saleRecord('old', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/a', saleRecord('a', 'north', NOW - 10 * DAY, false)],
    ['sales/b', saleRecord('b', 'north', NOW - DAY)],
    ['sales/c', saleRecord('c', 'north', NOW - 5 * DAY)],
    ['sales/south', saleRecord('south', 'south', NOW - DAY)],
    ['sales/future', saleRecord('future', 'north', NOW + DAY)],
    ['saleReturnLedgers/c', { returned: { 0: 3 } }],
  ];
  const { firestore, service } = fixture(records);
  const result = await service.listRecentSales({ auth, data: {} });
  assert.deepEqual(Object.keys(result), ['sales']);
  assert.deepEqual(result.sales.map((sale) => sale.saleId), ['b', 'c', 'a']);
  assert.deepEqual(result.sales.map((sale) => sale.createdAt), [NOW - DAY, NOW - 5 * DAY, NOW - 10 * DAY]);
  assert.equal(result.sales[1].lines[0].remainingScaled, 0);
  assert.equal(result.sales[2].receipt.invoiceRequested, false);
  assert.ok(Object.isFrozen(result.sales) && Object.isFrozen(result.sales[0]));
  const [query] = firestore.queries;
  assert.deepEqual(query.filters.map(([field, op, value]) => [field, op,
    value instanceof Date ? value.getTime() : value]), [
    ['receipt.branchId', '==', 'north'],
    ['createdAt', '>', NOW - CORRECTION_WINDOW_MS],
    ['createdAt', '<=', NOW],
  ]);
  assert.equal(query.limitValue, 50);
  assert.deepEqual(firestore.events[0], ['transaction', { readOnly: true }]);
  assert.deepEqual(firestore.writes, []);
  assert.ok(!JSON.stringify(result).includes('south'));
});

test('recent sales honor an explicit limit and return an empty list for a quiet branch', async () => {
  const records = Array.from({ length: 5 }, (_, index) => [
    `sales/s${index}`, saleRecord(`s${index}`, 'north', NOW - (index + 1) * DAY),
  ]);
  const { firestore, service } = fixture(records);
  const limited = await service.listRecentSales({ auth, data: { limit: 2 } });
  assert.deepEqual(limited.sales.map((sale) => sale.saleId), ['s0', 's1']);
  await service.listRecentSales({ auth, data: { limit: 100 } });
  assert.deepEqual(firestore.queries.map((query) => query.limitValue), [2, 100]);
  const south = { uid: 'seller-two', token: { role: 'seller', branchId: 'south' } };
  assert.deepEqual((await service.listRecentSales({ auth: south, data: {} })).sales, []);
});

test('one malformed sale in the branch list fails the whole list closed', async () => {
  const broken = saleRecord('b', 'north', NOW - DAY);
  broken.receipt.productIds = ['p1'];
  const { service } = fixture([
    ['sales/a', saleRecord('a', 'north', NOW - 2 * DAY)], ['sales/b', broken],
  ]);
  await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition');
});

test('tampered stored amounts with untouched pricing fail findSale closed', async () => {
  const lineAmount = saleRecord('s1', 'north', NOW - DAY);
  lineAmount.receipt.calculation.lines[0].baseCentavos += 1;
  lineAmount.receipt.calculation.lines[0].totalCentavos += 1;
  lineAmount.receipt.calculation.baseCentavos += 1;
  lineAmount.receipt.calculation.totalCentavos += 1;
  lineAmount.receipt.payment.amountCentavos += 1;
  const lineTotal = saleRecord('s1', 'north', NOW - DAY);
  lineTotal.receipt.calculation.lines[1].totalCentavos -= 1;
  const saleTotal = saleRecord('s1', 'north', NOW - DAY);
  saleTotal.receipt.calculation.totalCentavos += 1;
  saleTotal.receipt.payment.amountCentavos += 1;
  for (const record of [lineAmount, lineTotal, saleTotal]) {
    const { service } = fixture([['sales/s1', record]]);
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
  }
});

test('a productIds length mismatch fails findSale closed', async () => {
  for (const productIds of [['p1'], ['p1', 'p2', 'p3']]) {
    const record = saleRecord('s1', 'north', NOW - DAY);
    record.receipt.productIds = productIds;
    const { service } = fixture([['sales/s1', record]]);
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
  }
});

test('a payment amount that differs from the recomputed total fails closed', async () => {
  for (const delta of [-1, 1]) {
    const record = saleRecord('s1', 'north', NOW - DAY);
    record.receipt.payment.amountCentavos += delta;
    const { service } = fixture([['sales/s1', record]]);
    await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
    await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition');
  }
});

test('one malformed ledger in the branch list fails the whole list closed', async () => {
  for (const ledger of [{ returned: { 0: 4 } }, { returned: [] }, {}]) {
    const { firestore, service } = fixture([
      ['sales/a', saleRecord('a', 'north', NOW - 2 * DAY)],
      ['sales/b', saleRecord('b', 'north', NOW - DAY)],
      ['saleReturnLedgers/a', ledger],
    ]);
    await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition',
      'persisted sale return ledger is invalid');
    assert.deepEqual(firestore.writes, []);
  }
});

const FOLIO_KEY = '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab';
function folioSaleRecord(saleId = FOLIO_KEY, branchId = 'north', createdAtMs = NOW - DAY) {
  const record = saleRecord(saleId, branchId, createdAtMs);
  // Field order mirrors nothing in particular: Firestore maps are unordered.
  record.receipt = { ...record.receipt, version: 2, branchCode: 'NTE', folio: 'NTE-3F2A-9C1B' };
  return record;
}

test('folio sales validate exactly and expose their folio in the shared response shape', async () => {
  const { service } = fixture([
    [`sales/${FOLIO_KEY}`, folioSaleRecord()], ['sales/s1', saleRecord('s1', 'north', NOW - 2 * DAY)],
  ]);
  const { sale } = await service.findSale({ auth, data: { saleId: FOLIO_KEY } });
  assert.equal(sale.saleId, FOLIO_KEY);
  assert.deepEqual(Object.keys(sale).sort(), ['createdAt', 'folio', 'lines', 'receipt', 'saleId']);
  assert.deepEqual(Object.keys(sale.receipt).sort(),
    ['calculation', 'invoiceRequested', 'payment', 'productIds']);
  const { sales } = await service.listRecentSales({ auth, data: {} });
  assert.deepEqual(sales.map((item) => item.saleId), [FOLIO_KEY, 's1']);
  assert.equal(sale.folio, 'NTE-3F2A-9C1B');
  assert.deepEqual(sales.map((item) => item.folio), ['NTE-3F2A-9C1B', null]);
  assert.ok(!JSON.stringify(sales).includes('branchCode'));
});

test('forged, inconsistent or cost-carrying folio sales fail closed', async () => {
  const mutations = [
    (r) => { r.receipt.folio = 'NTE-3F2A-9C1C'; },
    (r) => { r.receipt.folio = 'nte-3f2a-9c1b'; },
    (r) => { delete r.receipt.folio; },
    (r) => { delete r.receipt.branchCode; },
    (r) => { r.receipt.branchCode = 'SUR'; },
    (r) => { r.receipt.branchCode = 'nte'; r.receipt.folio = 'nte-3F2A-9C1B'; },
    (r) => { r.receipt.branchCode = 'NORTE'; r.receipt.folio = 'NORTE-3F2A-9C1B'; },
    (r) => { r.receipt.version = 1; },
    (r) => { r.receipt.version = 3; },
    (r) => { r.receipt.unitCostCentavos = 1; },
    (r) => { r.receipt.calculation.lines[0].pricing.unitCostCentavos = 1; },
    (r) => { r.folio = r.receipt.folio; },
  ];
  for (const mutate of mutations) {
    const record = folioSaleRecord();
    mutate(record);
    const { service } = fixture([[`sales/${FOLIO_KEY}`, record]]);
    await rejectsWith(service.findSale({ auth, data: { saleId: FOLIO_KEY } }), 'failed-precondition',
      'persisted sale is invalid');
    await rejectsWith(service.listRecentSales({ auth, data: {} }), 'failed-precondition');
  }
  // A legacy receipt never gains folio fields piecemeal.
  const legacy = saleRecord('s1', 'north', NOW - DAY);
  legacy.receipt.folio = 'NTE-S1S1-S1S1';
  const { service } = fixture([['sales/s1', legacy]]);
  await rejectsWith(service.findSale({ auth, data: { saleId: 's1' } }), 'failed-precondition');
});

test('the validated projection carries the folio for legacy-aware correction callers', () => {
  const folio = lookup.validateStoredSale(FOLIO_KEY, folioSaleRecord());
  assert.equal(folio.folio, 'NTE-3F2A-9C1B');
  assert.equal(folio.branchCode, 'NTE');
  const legacy = lookup.validateStoredSale('s1', saleRecord('s1', 'north', NOW - DAY));
  assert.equal(legacy.folio, null);
  assert.equal(legacy.branchCode, null);
});

const TWIN_KEY = '3f2a9c1b-0000-4000-8000-00000000000b';
const folioFilters = (query) => query.filters.map(([field, op, value]) => [field, op,
  value instanceof Date ? value.getTime() : value]);

test('a folio resolves the one matching sale of the seller branch exactly like its saleId', async () => {
  const records = [
    [`sales/${FOLIO_KEY}`, folioSaleRecord(FOLIO_KEY, 'north', NOW - 2 * DAY)],
    [`saleReturnLedgers/${FOLIO_KEY}`, { returned: { 0: 1 } }],
    ['sales/s1', saleRecord('s1', 'north', NOW - DAY)],
    // The same folio in another branch, or outside the window, never matches.
    [`sales/${TWIN_KEY}`, folioSaleRecord(TWIN_KEY, 'south', NOW - DAY)],
    ['sales/3f2a9c1b-old', folioSaleRecord('3f2a9c1b-old', 'north', NOW - CORRECTION_WINDOW_MS)],
  ];
  const { firestore, service } = fixture(records);
  const bySaleId = await service.findSale({ auth, data: { saleId: FOLIO_KEY } });
  firestore.events.length = 0;
  // Normalized before validation: surrounding spaces and lowercase are accepted.
  for (const folio of ['NTE-3F2A-9C1B', ' nte-3f2a-9c1b\n', 'Nte-3F2a-9c1B']) {
    const byFolio = await service.findSale({ auth, data: { folio } });
    assert.deepEqual(byFolio, bySaleId);
    assert.equal(byFolio.sale.folio, 'NTE-3F2A-9C1B');
    assert.equal(byFolio.sale.lines[0].remainingScaled, 2);
    assert.ok(Object.isFrozen(byFolio) && Object.isFrozen(byFolio.sale));
  }
  assert.equal(firestore.queries.length, 3);
  for (const query of firestore.queries) {
    assert.deepEqual(folioFilters(query), [
      ['receipt.branchId', '==', 'north'],
      ['receipt.folio', '==', 'NTE-3F2A-9C1B'],
      ['createdAt', '>', NOW - CORRECTION_WINDOW_MS],
      ['createdAt', '<=', NOW],
    ]);
    assert.deepEqual(query.order, ['createdAt', 'desc']);
    assert.equal(query.limitValue, 3);
  }
  assert.deepEqual(firestore.events.slice(0, 2), [
    ['transaction', { readOnly: true }], ['get', `saleReturnLedgers/${FOLIO_KEY}`],
  ]);
  assert.deepEqual(firestore.writes, []);
  const south = { uid: 'seller-two', token: { role: 'seller', branchId: 'south' } };
  const foreign = await service.findSale({ auth: south, data: { folio: 'NTE-3F2A-9C1B' } });
  assert.equal(foreign.sale.saleId, TWIN_KEY);
});

test('an unknown, foreign or expired folio is the same not-found as a missing saleId', async () => {
  const notFound = 'sale was not found in this branch';
  const { firestore, service } = fixture([
    [`sales/${TWIN_KEY}`, folioSaleRecord(TWIN_KEY, 'south', NOW - DAY)],
    [`sales/${FOLIO_KEY}`, folioSaleRecord(FOLIO_KEY, 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/3f2a9c1b-future', folioSaleRecord('3f2a9c1b-future', 'north', NOW + 1)],
  ]);
  for (const folio of ['NTE-3F2A-9C1B', 'NTE-0000-0000', 'SUR-3F2A-9C1B']) {
    await rejectsWith(service.findSale({ auth, data: { folio } }), 'not-found', notFound);
  }
  assert.deepEqual(firestore.writes, []);
});

test('two or more in-window folio matches are ambiguous and reveal no sale', async () => {
  for (const count of [2, 3, 4]) {
    const keys = [FOLIO_KEY, TWIN_KEY, '3f2a9c1b-third', '3f2a9c1b-fourth'].slice(0, count);
    const { firestore, service } = fixture(keys.map((key, index) => [
      `sales/${key}`, folioSaleRecord(key, 'north', NOW - (index + 1) * DAY),
    ]));
    await assert.rejects(service.findSale({ auth, data: { folio: 'nte-3f2a-9c1b' } }), (error) => {
      assert.ok(error instanceof SaleError);
      assert.equal(error.code, 'failed-precondition');
      assert.equal(error.message, 'folio is ambiguous; use the full receipt id or the recent list');
      // CORR-07P: the structured signal the client branches on, never the message.
      assert.equal(error.reason, 'folio-ambiguous');
      return true;
    });
    assert.ok(!firestore.events.some(([kind, path]) => kind === 'get' && path.startsWith('saleReturnLedgers/')));
    assert.deepEqual(firestore.writes, []);
  }
});

test('the single folio match is validated as strictly as a saleId lookup', async () => {
  const mutations = [
    (r) => { r.receipt.calculation.lines[0].pricing.unitCostCentavos = 1; },
    (r) => { r.receipt.payment.amountCentavos += 1; },
    (r) => { r.actorId = 'seller-one'; },
    (r) => { r.receipt.saleId = TWIN_KEY; },
  ];
  for (const mutate of mutations) {
    const record = folioSaleRecord();
    mutate(record);
    const { service } = fixture([[`sales/${FOLIO_KEY}`, record]]);
    await rejectsWith(service.findSale({ auth, data: { folio: 'NTE-3F2A-9C1B' } }), 'failed-precondition',
      'persisted sale is invalid');
  }
  const { service } = fixture([
    [`sales/${FOLIO_KEY}`, folioSaleRecord()], [`saleReturnLedgers/${FOLIO_KEY}`, { returned: { 0: 9 } }],
  ]);
  await rejectsWith(service.findSale({ auth, data: { folio: 'NTE-3F2A-9C1B' } }), 'failed-precondition',
    'persisted sale return ledger is invalid');
});

test('a folio lookup runs the guard, seller check and clock check before any read', async () => {
  const { firestore, service } = fixture([[`sales/${FOLIO_KEY}`, folioSaleRecord()]], { environment: {} });
  await rejectsWith(service.findSale({ auth, data: { folio: 'NTE-3F2A-9C1B' } }), 'failed-precondition');
  const denied = fixture([[`sales/${FOLIO_KEY}`, folioSaleRecord()]]);
  await rejectsWith(denied.service.findSale({ auth: { uid: 'x', token: { role: 'administrator', branchId: 'north' } },
    data: { folio: 'NTE-3F2A-9C1B' } }), 'permission-denied');
  const clock = fixture([[`sales/${FOLIO_KEY}`, folioSaleRecord()]], { now: () => new Date(NaN) });
  await rejectsWith(clock.service.findSale({ auth, data: { folio: 'NTE-3F2A-9C1B' } }), 'failed-precondition',
    'lookup clock is invalid');
  for (const db of [firestore, denied.firestore, clock.firestore]) assert.deepEqual(db.events, []);
});
