import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale, SaleError } from '../src/sales.js';
import { CORRECTION_WINDOW_MS } from '../src/corrections-calculation.js';
import { createSaleReturnService } from '../src/sale-returns.js';
import * as replacements from '../src/sale-replacements.js';

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

// Line 0: 3 pieces of p1. Line 1: 1.250 kg of p2. productIds may repeat.
function saleRecord(saleId, branchId, createdAtMs, {
  productIds = ['p1', 'p2'], specs = [piece, kg], quantities = ['3', '1.250'],
} = {}) {
  const calculation = clone(calculateSale({ invoiceRequested: true, lines: specs.map((spec, index) => (
    { quantity: quantities[index], quantitySpec: spec, pricing: pricing(1000) })) }));
  return {
    receipt: {
      version: 1, saleId, branchId, productIds, calculation,
      payment: { method: 'card', amountCentavos: calculation.totalCentavos },
    },
    createdAt: new Date(createdAtMs),
  };
}

function baseRecords() {
  return [
    ['sales/s1', saleRecord('s1', 'north', NOW - DAY)],
    ['sales/dup', saleRecord('dup', 'north', NOW - DAY,
      { productIds: ['p1', 'p1'], specs: [piece, piece], quantities: ['3', '2'] })],
    ['sales/foreign', saleRecord('foreign', 'south', NOW - DAY)],
    ['sales/expired', saleRecord('expired', 'north', NOW - CORRECTION_WINDOW_MS)],
    ['sales/future', saleRecord('future', 'north', NOW + 1)],
    ['products/p1', { quantitySpec: piece, pricing: pricing(1000) }],
    ['products/p2', { quantitySpec: kg, pricing: pricing(1000) }],
    ['branches/north/stock/p1', { ...piece, quantityScaled: 5 }],
    ['branches/north/stock/p2', { ...kg, quantityScaled: 2000 }],
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
  const service = replacements.createSaleReplacementService({
    firestore, environment, ...clock, ...options,
  });
  const submitReturn = createSaleReturnService({ firestore, environment, ...clock });
  return { firestore, service, submitReturn };
}

function withRecords(overrides, removals = []) {
  const records = new Map(baseRecords());
  for (const [path, value] of overrides) records.set(path, value);
  for (const path of removals) records.delete(path);
  return [...records];
}

function request(data = {}, actor = auth) {
  return {
    auth: clone(actor),
    data: { idempotencyKey: 'x1', saleId: 's1', lines: [{ lineIndex: 0, quantity: '1' }], ...data },
  };
}

function returnRequest(key, lineIndex, quantity, condition = 'good') {
  return {
    auth: clone(auth),
    data: { idempotencyKey: key, saleId: 's1', reason: 'factory-defect',
      lines: [{ lineIndex, quantity, condition }] },
  };
}

async function rejectsUnchanged(firestore, promise, code, message) {
  const before = clone([...firestore.records]);
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof SaleError, `unexpected ${error}`);
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
  assert.deepEqual([...firestore.records], before, 'failure leaves no artifacts');
}

const stock = (firestore, product) => firestore.records.get(`branches/north/stock/${product}`);
const deepFrozen = (value) => value === null || typeof value !== 'object'
  || (Object.isFrozen(value) && Object.values(value).every(deepFrozen));

test('factory validates injected dependencies', () => {
  assert.throws(() => replacements.createSaleReplacementService(), TypeError);
  assert.throws(() => replacements.createSaleReplacementService({ firestore: { doc() {} } }), TypeError);
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

test('requests accept only exact fields, notes and canonical quantities', async () => {
  const { firestore, service } = fixture();
  const line = { lineIndex: 0, quantity: '1' };
  for (const data of [
    { idempotencyKey: '' }, { idempotencyKey: '../x1' }, { idempotencyKey: 'x'.repeat(129) },
    { saleId: '' }, { saleId: 's/1' }, { saleId: 7 },
    { reason: 'factory-defect' }, { chargeCentavos: 0 }, { branchId: 'north' },
    { note: '' }, { note: '   ' }, { note: ' padded' }, { note: 'padded ' }, { note: 'x'.repeat(501) },
    { note: null }, { note: 5 },
    { lines: [] }, { lines: 'all' }, { lines: [line, { ...line }] },
    { lines: [{ ...line, condition: 'factory-defect' }] }, { lines: [{ ...line, productId: 'p1' }] },
    { lines: [{ ...line, lineIndex: -1 }] }, { lines: [{ ...line, lineIndex: 1.5 }] },
    { lines: [{ ...line, lineIndex: '0' }] }, { lines: [{ lineIndex: 0 }] },
    { lines: [{ ...line, quantity: '0' }] }, { lines: [{ ...line, quantity: '01' }] },
    { lines: [{ ...line, quantity: '1.' }] }, { lines: [{ ...line, quantity: 1 }] },
    { lines: [{ ...line, quantity: '-1' }] },
  ]) {
    await rejectsUnchanged(firestore, service(request(data)), 'invalid-argument');
  }
  const sparse = [];
  sparse.length = 1;
  await rejectsUnchanged(firestore, service(request({ lines: sparse })), 'invalid-argument');
  for (const data of [undefined, null, []]) {
    await rejectsUnchanged(firestore, service({ auth, data }), 'invalid-argument');
  }
  assert.deepEqual(firestore.traces, []);
  const accepted = await service(request({ note: 'x'.repeat(500) }));
  assert.equal(accepted.replayed, false);
});

test('a replacement swaps defective units for sellable stock at no charge', async () => {
  const { firestore, service } = fixture();
  const sale = clone(firestore.records.get('sales/s1'));
  const result = await service(request({ note: 'Cracked casing', lines: [
    { lineIndex: 1, quantity: '0.5' }, { lineIndex: 0, quantity: '2' },
  ] }));
  const expected = {
    version: 1, replacementId: 'x1', saleId: 's1', branchId: 'north', reason: 'factory-defect',
    lines: [{ lineIndex: 1, productId: 'p2', quantity: '0.500' },
      { lineIndex: 0, productId: 'p1', quantity: '2' }],
    chargeCentavos: 0,
  };
  assert.deepEqual(result, { receipt: expected, replayed: false });
  assert.ok(Object.isFrozen(result) && deepFrozen(result.receipt));

  assert.deepEqual(firestore.records.get('saleReplacements/x1'), { receipt: expected, createdAt: AT });
  assert.deepEqual(firestore.records.get('saleReplacementAudits/x1'), {
    replacementId: 'x1', saleId: 's1', branchId: 'north', actorId: 'seller-one',
    reason: 'factory-defect', note: 'Cracked casing', createdAt: AT,
  });
  const movement = (lineIndex, productId, spec) => ({
    replacementId: 'x1', saleId: 's1', lineIndex, branchId: 'north', productId,
    ...spec, actorId: 'seller-one', occurredAt: AT,
  });
  assert.deepEqual(firestore.records.get('inventoryMovements/replacement-x1-0-in'),
    { type: 'replacement-defect-in', quantityScaled: 500, ...movement(1, 'p2', kg) });
  assert.deepEqual(firestore.records.get('inventoryMovements/replacement-x1-0-out'),
    { type: 'replacement-out', quantityScaled: -500, ...movement(1, 'p2', kg) });
  assert.deepEqual(firestore.records.get('inventoryMovements/replacement-x1-1-in'),
    { type: 'replacement-defect-in', quantityScaled: 2, ...movement(0, 'p1', piece) });
  assert.deepEqual(firestore.records.get('inventoryMovements/replacement-x1-1-out'),
    { type: 'replacement-out', quantityScaled: -2, ...movement(0, 'p1', piece) });
  assert.deepEqual(stock(firestore, 'p1'),
    { ...piece, quantityScaled: 3, updatedAt: AT, lastMovementId: 'replacement-x1-1-out' });
  assert.deepEqual(stock(firestore, 'p2'),
    { ...kg, quantityScaled: 1500, updatedAt: AT, lastMovementId: 'replacement-x1-0-out' });
  const replay = firestore.records.get('saleReplacementSubmissionReceipts/x1');
  assert.deepEqual(Object.keys(replay).sort(),
    ['actorId', 'branchId', 'completedAt', 'fingerprint', 'result']);
  assert.deepEqual(replay.result, expected);
  assert.equal(replay.completedAt.getTime(), NOW);
  assert.ok(!JSON.stringify(firestore.records.get('saleReplacements/x1')).includes('Cracked'));

  // The ledger is read for serialization but never written; the sale is immutable.
  const operations = firestore.traces.flat();
  assert.ok(operations.some(([kind, path]) => kind === 'get' && path === 'saleReturnLedgers/s1'));
  assert.equal(firestore.records.has('saleReturnLedgers/s1'), false);
  assert.deepEqual(firestore.records.get('sales/s1'), sale);
  assert.deepEqual(operations.filter(([kind]) => kind === 'set').map(([, path]) => path).sort(),
    ['branches/north/stock/p1', 'branches/north/stock/p2']);
  assert.ok(operations.every(([kind, path]) => kind === 'get' || !path.startsWith('sales')));
});

test('insufficient sellable stock is refused, aggregating lines of one product', async () => {
  const low = fixture({}, withRecords([['branches/north/stock/p1', { ...piece, quantityScaled: 1 }]]));
  await rejectsUnchanged(low.firestore, low.service(request({ lines: [{ lineIndex: 0, quantity: '2' }] })),
    'failed-precondition', 'insufficient stock');
  const none = fixture({}, withRecords([], ['branches/north/stock/p1']));
  await rejectsUnchanged(none.firestore, none.service(request()), 'failed-precondition',
    'insufficient stock');
  // Each line alone fits four units of stock, together they need five.
  const lines = [{ lineIndex: 0, quantity: '3' }, { lineIndex: 1, quantity: '2' }];
  const four = fixture({}, withRecords([['branches/north/stock/p1', { ...piece, quantityScaled: 4 }]]));
  await rejectsUnchanged(four.firestore, four.service(request({ saleId: 'dup', lines })),
    'failed-precondition', 'insufficient stock');
  const five = fixture();
  await five.service(request({ saleId: 'dup', lines }));
  assert.deepEqual(stock(five.firestore, 'p1'),
    { ...piece, quantityScaled: 0, updatedAt: AT, lastMovementId: 'replacement-x1-1-out' });
  const sets = five.firestore.traces.flat().filter(([kind]) => kind === 'set');
  assert.deepEqual(sets, [['set', 'branches/north/stock/p1']]);
});

test('lines of one product with different specifications fail closed', async () => {
  const mixed = saleRecord('mixed', 'north', NOW - DAY,
    { productIds: ['p1', 'p1'], specs: [piece, kg], quantities: ['3', '1.500'] });
  const { firestore, service } = fixture({}, withRecords([['sales/mixed', mixed]]));
  await rejectsUnchanged(firestore, service(request({ saleId: 'mixed', lines: [
    { lineIndex: 0, quantity: '1' }, { lineIndex: 1, quantity: '1' },
  ] })), 'failed-precondition', 'sale lines disagree on a product specification');
  // A product whose current specification differs from the sale also fails closed.
  const changed = fixture({}, withRecords([['products/p1', { quantitySpec: kg, pricing: pricing(1) }]]));
  await rejectsUnchanged(changed.firestore, changed.service(request()), 'failed-precondition');
});

test('a replacement is capped at the remaining returnable quantity after a return', async () => {
  const { firestore, service, submitReturn } = fixture();
  await submitReturn(returnRequest('r1', 0, '2'));
  await rejectsUnchanged(firestore, service(request({ lines: [{ lineIndex: 0, quantity: '2' }] })),
    'out-of-range', 'replacement exceeds the remaining returnable quantity');
  const { receipt } = await service(request({ lines: [{ lineIndex: 0, quantity: '1' }] }));
  assert.deepEqual(receipt.lines, [{ lineIndex: 0, productId: 'p1', quantity: '1' }]);
  // Never more than sold, even without any return.
  const fresh = fixture();
  await rejectsUnchanged(fresh.firestore, fresh.service(request({
    lines: [{ lineIndex: 1, quantity: '1.251' }],
  })), 'out-of-range');
});

test('a replaced unit stays returnable and replaceable again (decision 11)', async () => {
  const { firestore, service, submitReturn } = fixture();
  await service(request({ lines: [{ lineIndex: 0, quantity: '3' }] }));
  await service(request({ idempotencyKey: 'x2', lines: [{ lineIndex: 0, quantity: '2' }] }));
  assert.equal(stock(firestore, 'p1').quantityScaled, 0);
  const { receipt } = await submitReturn(returnRequest('r1', 0, '3', 'factory-defect'));
  assert.equal(receipt.refund.totalCentavos, 3480);
  assert.deepEqual(firestore.records.get('saleReturnLedgers/s1').returned, { 0: 3 });
  await rejectsUnchanged(firestore, service(request({ idempotencyKey: 'x3' })), 'out-of-range');
});

test('replay is exact and duplicates no write, even after an abandoned attempt', async () => {
  const { firestore, service } = fixture();
  firestore.retry = true;
  const first = await service(request({ note: 'once', lines: [{ lineIndex: 1, quantity: '0.25' }] }));
  assert.equal(stock(firestore, 'p2').quantityScaled, 1750);
  const before = clone([...firestore.records]);
  const traces = firestore.traces.length;
  const second = await service(request({ note: 'once', lines: [{ lineIndex: 1, quantity: '0.25' }] }));
  assert.deepEqual(second, { receipt: first.receipt, replayed: true });
  assert.ok(Object.isFrozen(second) && deepFrozen(second.receipt));
  assert.deepEqual([...firestore.records], before);
  assert.deepEqual(firestore.traces.slice(traces),
    [[['get', 'saleReplacementSubmissionReceipts/x1']]]);
});

test('a reused key with a different payload, actor or branch is already-exists', async () => {
  const { firestore, service } = fixture();
  await service(request());
  const other = { uid: 'seller-two', token: { role: 'seller', branchId: 'north' } };
  const south = { uid: 'seller-one', token: { role: 'seller', branchId: 'south' } };
  for (const input of [
    request({ lines: [{ lineIndex: 0, quantity: '2' }] }), request({ note: 'late note' }),
    request({ lines: [{ lineIndex: 1, quantity: '1' }] }),
    request({}, other), request({ saleId: 'foreign' }, south),
  ]) {
    await rejectsUnchanged(firestore, service(input), 'already-exists',
      'idempotency key is already owned by a different submission');
  }
});

test('replacement keys share no namespace with returns; orphans are a stable collision', async () => {
  const { service } = fixture({}, withRecords([['saleReturnSubmissionReceipts/x1', { actorId: 'z' }]]));
  assert.equal((await service(request())).replayed, false);
  for (const path of ['saleReplacements/x1', 'saleReplacementAudits/x1',
    'inventoryMovements/replacement-x1-0-in', 'inventoryMovements/replacement-x1-0-out']) {
    const orphan = fixture({}, withRecords([[path, { orphan: true }]]));
    await rejectsUnchanged(orphan.firestore, orphan.service(request()), 'already-exists',
      'idempotency key collides with existing correction records');
  }
});

test('foreign and missing sales are the same not-found; expired and future sales are refused', async () => {
  const { firestore, service } = fixture();
  const message = 'sale was not found in this branch';
  await rejectsUnchanged(firestore, service(request({ saleId: 'foreign' })), 'not-found', message);
  await rejectsUnchanged(firestore, service(request({ saleId: 'missing' })), 'not-found', message);
  await rejectsUnchanged(firestore, service(request({ saleId: 'expired' })), 'failed-precondition',
    'sale is outside the correction window');
  await rejectsUnchanged(firestore, service(request({ saleId: 'future' })), 'failed-precondition');
});

test('an unknown line or a precision mismatch is invalid-argument', async () => {
  const { firestore, service } = fixture();
  for (const line of [{ lineIndex: 2, quantity: '1' }, { lineIndex: 0, quantity: '0.5' },
    { lineIndex: 1, quantity: '0.0001' }]) {
    await rejectsUnchanged(firestore, service(request({ lines: [line] })), 'invalid-argument');
  }
});

test('malformed persisted sale, ledger, product, stock or replay fails closed', async () => {
  const cost = saleRecord('s1', 'north', NOW - DAY);
  cost.receipt.calculation.lines[0].pricing.unitCostCentavos = 400;
  for (const overrides of [
    [['sales/s1', cost]],
    [['saleReturnLedgers/s1', { returned: { 0: 4 }, lastReturnId: 'r', updatedAt: AT }]],
    [['saleReturnLedgers/s1', { returned: { 0: 1 }, lastReturnId: 'r', updatedAt: AT, extra: 1 }]],
    [['products/p1', { pricing: pricing(1000) }]],
    [['branches/north/stock/p1', { ...piece, quantityScaled: 5, reserved: 1 }]],
    [['branches/north/stock/p1', { ...piece, quantityScaled: -1 }]],
  ]) {
    const { firestore, service } = fixture({}, withRecords(overrides));
    await rejectsUnchanged(firestore, service(request()), 'failed-precondition');
  }
  const { firestore, service } = fixture({}, withRecords([], ['products/p1']));
  await rejectsUnchanged(firestore, service(request()), 'failed-precondition');

  for (const tamper of [
    (result) => { result.lines[0].quantity = '2'; },
    (result) => { result.lines[0].lineIndex = 1; },
    (result) => { result.chargeCentavos = 1; },
    (result) => { result.reason = 'other'; },
    (result) => { result.lines[0].unitCostCentavos = 1; },
    (result) => { result.note = 'leaked'; },
  ]) {
    const probe = fixture();
    await probe.service(request());
    tamper(probe.firestore.records.get('saleReplacementSubmissionReceipts/x1').result);
    await rejectsUnchanged(probe.firestore, probe.service(request()), 'failed-precondition',
      'persisted replacement replay is invalid');
  }
});

test('an invalid clock fails new replacements but never historical replay', async () => {
  const { firestore, service } = fixture();
  await service(request());
  for (const clock of [() => new Date(NaN), () => 'now', () => { throw new Error('clock'); }]) {
    const broken = replacements.createSaleReplacementService({ firestore, environment, now: clock });
    assert.equal((await broken(request())).replayed, true);
    await rejectsUnchanged(firestore, broken(request({ idempotencyKey: 'x2' })), 'failed-precondition',
      'replacement clock is invalid');
  }
});

test('no written document carries cost fields and caller mutation cannot alter the submission', async () => {
  const { firestore, service } = fixture();
  const input = request();
  const pending = service(input);
  input.data.lines[0].quantity = '3';
  input.data.saleId = 'foreign';
  const { receipt } = await pending;
  assert.deepEqual(receipt.lines, [{ lineIndex: 0, productId: 'p1', quantity: '1' }]);
  for (const [path, value] of firestore.records) {
    if (path.startsWith('products/') || path.startsWith('sales/')) continue;
    // The zero charge is the only money field a replacement ever writes.
    assert.ok(!/cost|price|centavos/i.test(JSON.stringify(value).replaceAll('"chargeCentavos":0', '')),
      `cost or price field written at ${path}`);
  }
});
