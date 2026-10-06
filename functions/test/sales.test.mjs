import assert from 'node:assert/strict';
import test from 'node:test';
import * as sales from '../src/sales.js';

const environment = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const auth = { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } };
const timestamp = new Date('2026-06-01T12:00:00Z');
const pricing = {
  currency: 'MXN', listedPriceCentavos: 100, priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600,
};
const spec = { unit: 'piece', precision: 0 };
const clone = (value) => structuredClone(value);

// Serial in-memory transactions only: buffered writes, create preconditions,
// abandoned callback retries, and commit failures. No sockets or Admin SDK.
class FakeFirestore {
  constructor() {
    this.records = new Map([
      ['branches/north', { name: 'North' }],
      ['branches/south', { name: 'South' }],
      ['products/p1', { quantitySpec: spec, pricing }],
      ['products/p2', { quantitySpec: spec, pricing }],
      ['branches/north/stock/p1', { ...spec, quantityScaled: 10 }],
      ['branches/north/stock/p2', { ...spec, quantityScaled: 10 }],
    ].map(([key, value]) => [key, clone(value)]));
    this.traces = [];
    this.attemptWrites = [];
    this.retry = false;
    this.failCommit = false;
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+(?:\/[^/]+\/[^/]+)?$/);
    assert.ok(!path.startsWith('costs/'), 'sales must never read costs');
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
          this.onRead?.(path);
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
      this.attemptWrites.push(clone(writes));
      return { writes, result };
    };
    if (this.retry) {
      this.retry = false;
      await execute(); // Abandon all writes from this callback invocation.
    }
    const { writes, result } = await execute();
    if (this.failCommit) throw new Error('injected commit failure');
    const next = new Map(this.records);
    for (const { kind, path, data } of writes) {
      if (kind === 'create' && next.has(path)) {
        throw new Error('create-only conflict');
      }
      next.set(path, data);
    }
    this.records = next;
    return result;
  }
}

function request(overrides = {}) {
  return {
    auth: clone(auth),
    data: {
      idempotencyKey: 'key-one', invoiceRequested: true,
      lines: [{ productId: 'p1', quantity: '2' }],
      payment: { method: 'cash', amountCentavos: 232 },
      ...overrides,
    },
  };
}

function fixture(options = {}) {
  const firestore = new FakeFirestore();
  const service = sales.createSaleService({
    firestore, environment, now: () => new Date(timestamp), ...options,
  });
  return { firestore, service };
}

async function rejectsUnchanged(firestore, service, input, code) {
  const before = clone([...firestore.records]);
  await assert.rejects(service(input), (error) => {
    assert.equal(error.name, 'SaleError');
    assert.equal(error.code, code);
    return true;
  });
  assert.deepEqual([...firestore.records], before, 'failure leaves no artifacts');
}

function stock(firestore, productId = 'p1') {
  return firestore.records.get(`branches/north/stock/${productId}`).quantityScaled;
}

function privateReplay(firestore) {
  return firestore.records.get('saleSubmissionReceipts/key-one');
}

test('transaction API is available without SDK initialization', () => {
  assert.equal(typeof sales.createSaleService, 'function');
  assert.equal(typeof sales.assertLocalSalesEmulator, 'function');
  assert.equal(typeof sales.SaleError, 'function');
});

test('factory validates injected dependencies', () => {
  assert.throws(() => sales.createSaleService(), TypeError);
  assert.throws(() => fixture({ now: 1 }), TypeError);
});

test('local demo guard runs on each invocation before Firestore access', async () => {
  for (const env of [
    {}, { ...environment, GCLOUD_PROJECT: 'cloud-project' },
    { ...environment, FUNCTIONS_EMULATOR: 'false' },
    { ...environment, FIRESTORE_EMULATOR_HOST: '' },
  ]) {
    const { firestore, service } = fixture({ environment: env });
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
    assert.equal(firestore.traces.length, 0);
  }
  const mutable = { ...environment };
  const { firestore, service } = fixture({ environment: mutable });
  mutable.GCLOUD_PROJECT = 'other';
  await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
});

test('unsafe sale environments fail before documents, clock, transaction or auth', async (t) => {
  const cases = [
    ['remote host', { FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' }],
    ['alternate port', { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8081' }],
    ['scheme', { FIRESTORE_EMULATOR_HOST: 'http://127.0.0.1:8080' }],
    ['hostname alias', { FIRESTORE_EMULATOR_HOST: 'localhost:8080' }],
    ['host whitespace', { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080 ' }],
    ['project whitespace', { GCLOUD_PROJECT: 'demo-lda-inventory ' }],
    ['missing project', { GCLOUD_PROJECT: undefined }],
    ['missing functions flag', { FUNCTIONS_EMULATOR: undefined }],
    ['flag whitespace', { FUNCTIONS_EMULATOR: 'true ' }],
    ['missing host', { FIRESTORE_EMULATOR_HOST: undefined }],
    ['conflicting Google project', { GOOGLE_CLOUD_PROJECT: 'production' }],
    ['empty Google project', { GOOGLE_CLOUD_PROJECT: '' }],
    ['conflicting Firebase project', { FIREBASE_CONFIG: '{"projectId":"production"}' }],
    ['Firebase project whitespace', { FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory "}' }],
    ['malformed Firebase config', { FIREBASE_CONFIG: '{' }],
    ['Firebase config path', { FIREBASE_CONFIG: '/unread/config.json' }],
    ['Firebase config array', { FIREBASE_CONFIG: '[{"projectId":"demo-lda-inventory"}]' }],
    ['Firebase config null', { FIREBASE_CONFIG: 'null' }],
    ['Firebase config lacks project', { FIREBASE_CONFIG: '{}' }],
    ['empty Firebase config', { FIREBASE_CONFIG: '' }],
    ['non-string Firebase config', { FIREBASE_CONFIG: { projectId: 'demo-lda-inventory' } }],
    ['non-string project ID', { FIREBASE_CONFIG: '{"projectId":123}' }],
  ];
  for (const [label, patch] of cases) {
    await t.test(label, async () => {
      const events = [];
      const service = sales.createSaleService({
        environment: { ...environment, ...patch },
        firestore: {
          doc: () => { events.push('doc'); throw new Error('unexpected document access'); },
          runTransaction: () => { events.push('transaction'); throw new Error('unexpected transaction'); },
        },
        now: () => { events.push('clock'); throw new Error('unexpected clock access'); },
      });
      // Reject valid requests before I/O and invalid auth before authorization.
      for (const input of [request(), {}]) {
        await assert.rejects(service(input), (error) => {
          assert.ok(error instanceof sales.SaleError);
          assert.equal(error.code, 'failed-precondition');
          assert.equal(error.message, 'sales require the dedicated local demo emulator');
          return true;
        });
      }
      assert.deepEqual(events, []);
    });
  }
});

test('consistent optional project sources accept the exact local sale configuration', async () => {
  const { service } = fixture({ environment: { ...environment,
    GOOGLE_CLOUD_PROJECT: 'demo-lda-inventory',
    FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory","storageBucket":"demo-lda-inventory.appspot.com"}',
  } });
  const result = await service(request());
  assert.equal(result.receipt.branchId, 'north');
  assert.equal(result.replayed, false);
});

test('only authenticated assigned sellers may submit', async () => {
  for (const [candidate, code] of [
    [undefined, 'unauthenticated'], [{ uid: '' }, 'unauthenticated'],
    [{ uid: 'x', token: { role: 'administrator', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'unknown', branchId: 'north' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller' } }, 'permission-denied'],
    [{ uid: 'x', token: { role: 'seller', branchId: '../north' } }, 'permission-denied'],
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service, { ...request(), auth: candidate }, code);
    assert.equal(firestore.traces.length, 0);
  }
});

test('rejects every client branch and all unsupported authoritative fields', async () => {
  for (const extras of [
    { branchId: 'south' }, { branchId: 'north' }, { totalCentavos: 232 },
    { unitCostCentavos: 1 }, { pricing }, { tax: 16 },
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service, request(extras), 'invalid-argument');
  }
});

test('valid sale persists immutable safe history, private audit and negative movement', async () => {
  const { firestore, service } = fixture();
  const result = await service(request());
  assert.equal(result.replayed, false);
  assert.deepEqual(Object.keys(result).sort(), ['receipt', 'replayed']);
  const receipt = result.receipt;
  assert.deepEqual(Object.keys(receipt).sort(), [
    'branchId', 'calculation', 'payment', 'productIds', 'saleId', 'version',
  ]);
  assert.equal(receipt.saleId, 'key-one');
  assert.equal(receipt.branchId, 'north');
  assert.deepEqual(receipt.productIds, ['p1']);
  assert.equal(receipt.calculation.totalCentavos, 232);
  assert.equal(receipt.calculation.lines[0].quantity.scaled, 2);
  assert.ok(Object.isFrozen(receipt));
  assert.ok(Object.isFrozen(receipt.calculation.lines));
  assert.ok(Object.isFrozen(receipt.payment));
  assert.equal(stock(firestore), 8);
  assert.equal(firestore.records.get('sales/key-one').createdAt.getTime(), timestamp.getTime());
  assert.deepEqual(firestore.records.get('sales/key-one').receipt, receipt);
  assert.equal(firestore.records.get('saleAudits/key-one').actorId, auth.uid);
  assert.equal(privateReplay(firestore).actorId, auth.uid);
  const movement = firestore.records.get('inventoryMovements/sale-key-one-0');
  assert.equal(movement.quantityScaled, -2);
  assert.equal(movement.type, 'sale');
  assert.equal(movement.actorId, auth.uid);
  assert.equal(movement.saleId, 'key-one');
  assert.equal(movement.occurredAt.getTime(), timestamp.getTime());
  assert.equal(firestore.records.size, 10);
  assert.doesNotMatch(JSON.stringify(receipt), /cost|actor|seller-one|createdBy/i);
  assert.doesNotMatch(JSON.stringify(firestore.records.get('sales/key-one')), /actor|seller-one/i);
});

test('missing branch, product, or pricing rejects with zero artifacts', async () => {
  for (const [path, code] of [
    ['branches/north', 'not-found'], ['products/p1', 'not-found'],
    ['pricing', 'failed-precondition'],
  ]) {
    const { firestore, service } = fixture();
    if (path === 'pricing') delete firestore.records.get('products/p1').pricing;
    else firestore.records.delete(path);
    await rejectsUnchanged(firestore, service, request(), code);
  }
});

test('malformed stored quantity specifications, pricing and stock fail closed', async () => {
  for (const mutate of [
    (db) => { db.records.get('products/p1').quantitySpec.precision = 7; },
    (db) => { db.records.get('products/p1').quantitySpec.extra = true; },
    (db) => { db.records.get('products/p1').pricing.listedPriceCentavos = 1.1; },
    (db) => { db.records.get('products/p1').pricing.ivaRateBasisPoints = 0; },
    (db) => { db.records.get('products/p1').pricing.currency = 'USD'; },
    (db) => { db.records.get('products/p1').pricing.cost = 1; },
    (db) => { db.records.get('branches/north/stock/p1').precision = 1; },
    (db) => { db.records.get('branches/north/stock/p1').quantityScaled = -1; },
    (db) => { db.records.get('branches/north/stock/p1').quantityScaled = Number.MAX_SAFE_INTEGER + 1; },
  ]) {
    const { firestore, service } = fixture();
    mutate(firestore);
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
  }
});

test('request requires exact fields, explicit invoice intent and canonical positive quantities', async () => {
  for (const overrides of [
    { invoiceRequested: undefined }, { invoiceRequested: 1 },
    { lines: [] }, { lines: [undefined] }, { lines: new Array(1) },
    { idempotencyKey: '../key' }, { idempotencyKey: '' },
    ...['0', '-1', '01', ' 2', '2.1', '2.0', '1e2', 2].map((quantity) => ({
      lines: [{ productId: 'p1', quantity }],
    })),
    { lines: [{ productId: 'p1', quantity: '2', pricing }] },
    { lines: [{ productId: '../p1', quantity: '2' }] },
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service, request(overrides), 'invalid-argument');
  }
});

test('all full-payment methods are accepted, without tender or external processing', async () => {
  for (const method of ['cash', 'card', 'transfer']) {
    const { service } = fixture();
    const result = await service(request({ payment: { method, amountCentavos: 232 } }));
    assert.deepEqual(result.receipt.payment, { method, amountCentavos: 232 });
  }
  const { service } = fixture();
  const result = await service(request({ invoiceRequested: false, payment: { method: 'cash', amountCentavos: 200 } }));
  assert.equal(result.receipt.calculation.additionalIvaCentavos, 0);
});

test('invalid method, split/tender and nonexact payment amounts leave zero artifacts', async () => {
  for (const payment of [
    { method: 'credit', amountCentavos: 232 },
    { method: 'cash', amountCentavos: 232, tender: 300 },
    { method: 'cash', amountCentavos: 232, change: 0 },
    [{ method: 'cash', amountCentavos: 232 }],
    ...[231, 233, -1, 232.1, '232', NaN, Number.MAX_SAFE_INTEGER + 1]
      .map((amountCentavos) => ({ method: 'cash', amountCentavos })),
  ]) {
    const { firestore, service } = fixture();
    await rejectsUnchanged(firestore, service, request({ payment }), 'invalid-argument');
  }
});

test('insufficient or absent stock leaves zero artifacts', async () => {
  for (const absent of [false, true]) {
    const { firestore, service } = fixture();
    if (absent) firestore.records.delete('branches/north/stock/p1');
    else firestore.records.get('branches/north/stock/p1').quantityScaled = 1;
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
  }
});

test('duplicate-product lines fail closed rather than bypassing aggregate underflow', async () => {
  const { firestore, service } = fixture();
  await rejectsUnchanged(firestore, service, request({
    lines: [{ productId: 'p1', quantity: '6' }, { productId: 'p1', quantity: '6' }],
    payment: { method: 'cash', amountCentavos: 1392 },
  }), 'invalid-argument');
});

test('multiple products commit together and a later-product underflow commits nothing', async () => {
  const input = request({
    lines: [{ productId: 'p1', quantity: '2' }, { productId: 'p2', quantity: '3' }],
    payment: { method: 'transfer', amountCentavos: 580 },
  });
  const { firestore, service } = fixture();
  firestore.records.get('branches/north/stock/p2').quantityScaled = 2;
  await rejectsUnchanged(firestore, service, input, 'failed-precondition');
  firestore.records.get('branches/north/stock/p2').quantityScaled = 10;
  const result = await service(input);
  assert.equal(stock(firestore), 8);
  assert.equal(stock(firestore, 'p2'), 7);
  assert.deepEqual(result.receipt.productIds, ['p1', 'p2']);
  assert.equal(firestore.records.get('inventoryMovements/sale-key-one-1').quantityScaled, -3);
});

test('exact replay returns original frozen snapshot after repricing without decrement', async () => {
  const { firestore, service } = fixture();
  const original = await service(request());
  firestore.records.get('products/p1').pricing.listedPriceCentavos = 999;
  assert.deepEqual((await service(request())).receipt, original.receipt);
  assert.deepEqual(firestore.records.get('sales/key-one').receipt, original.receipt);
  // Replay depends on validated immutable history, not current catalog inputs.
  firestore.records.delete('products/p1');
  const before = clone([...firestore.records]);
  const replay = await service(request());
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.receipt, original.receipt);
  assert.ok(Object.isFrozen(replay.receipt));
  assert.deepEqual([...firestore.records], before);
  assert.equal(stock(firestore), 8);
  assert.equal(firestore.traces.at(-1).some(([op]) => op !== 'get'), false);
});

test('key ownership binds actor, branch and immutable request without leaking receipts', async () => {
  const { firestore, service } = fixture();
  await service(request());
  for (const input of [
    { ...request(), auth: { ...clone(auth), uid: 'seller-two' } },
    { ...request(), auth: { uid: auth.uid, token: { role: 'seller', branchId: 'south' } } },
    request({ invoiceRequested: false }),
    request({ lines: [{ productId: 'p1', quantity: '3' }] }),
    request({ payment: { method: 'card', amountCentavos: 232 } }),
    request({ payment: { method: 'cash', amountCentavos: 231 } }),
  ]) await rejectsUnchanged(firestore, service, input, 'already-exists');
});

test('malformed private replay and snapshot fields fail closed', async () => {
  for (const mutate of [
    (r) => { delete r.result; },
    (r) => { r.result.actorId = 'secret'; },
    (r) => { r.result.saleId = 'wrong'; },
    (r) => { r.result.productIds = ['wrong']; },
    (r) => { r.result.calculation.totalCentavos++; },
    (r) => { r.result.calculation.lines[0].quantity.scaled++; },
    (r) => { r.result.calculation.lines[0].pricing.cost = 10; },
    (r) => { r.result.calculation.calculationPolicy.rounding = 'truncate'; },
    (r) => { r.result.payment.amountCentavos++; },
    (r) => { r.completedAt = 'fake-time'; },
    (r) => { r.extra = 'private'; },
  ]) {
    const { firestore, service } = fixture();
    await service(request());
    mutate(privateReplay(firestore));
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
  }
});

test('buffered transaction rollback and create-only conflicts leave no partial artifacts', async () => {
  for (const conflictPath of [null, 'sales/key-one', 'saleAudits/key-one', 'inventoryMovements/sale-key-one-0']) {
    const { firestore, service } = fixture();
    if (conflictPath) firestore.records.set(conflictPath, { previous: true });
    else firestore.failCommit = true;
    const before = clone([...firestore.records]);
    await assert.rejects(service(request()), /commit failure|create-only conflict/);
    assert.deepEqual([...firestore.records], before);
  }
});

test('callback retries reuse identities and commit exactly once', async () => {
  const { firestore, service } = fixture();
  firestore.retry = true;
  await service(request());
  assert.deepEqual(firestore.traces[0], firestore.traces[1]);
  assert.equal(stock(firestore), 8);
  assert.equal([...firestore.records.keys()].filter((p) => p.startsWith('inventoryMovements/')).length, 1);
});

test('advancing clock is captured once and reused across abandoned and committed attempts', async () => {
  let clockCalls = 0;
  const { firestore, service } = fixture({
    now: () => new Date(timestamp.getTime() + clockCalls++ * 1000),
  });
  firestore.retry = true;
  await service(request());
  assert.equal(firestore.attemptWrites.length, 2);
  assert.deepEqual(firestore.traces[0], firestore.traces[1]);
  const attemptTimes = firestore.attemptWrites.map((writes) => writes.map(({ data }) => (
    data.createdAt ?? data.occurredAt ?? data.updatedAt ?? data.completedAt
  )).map((date) => date.getTime()));
  assert.deepEqual(attemptTimes[1], attemptTimes[0], 'retry timestamps must equal abandoned-attempt timestamps');
  assert.equal(clockCalls, 1, 'one clock read per new sale invocation');
  const paths = [
    'sales/key-one', 'saleAudits/key-one', 'inventoryMovements/sale-key-one-0',
    'branches/north/stock/p1', 'saleSubmissionReceipts/key-one',
  ];
  assert.deepEqual(firestore.attemptWrites[1].map(({ path }) => path), paths);
  assert.deepEqual(attemptTimes[0], paths.map(() => timestamp.getTime()));
  for (const path of paths) {
    const data = firestore.records.get(path);
    const date = data.createdAt ?? data.occurredAt ?? data.updatedAt ?? data.completedAt;
    assert.equal(date.getTime(), timestamp.getTime(), path);
  }
});

test('historical replay and business validation do not depend on a healthy current clock', async () => {
  const { firestore, service } = fixture();
  const original = await service(request());
  for (const now of [() => new Date(NaN), () => { throw new Error('clock unavailable'); }]) {
    const resubmit = sales.createSaleService({ firestore, environment, now });
    assert.deepEqual((await resubmit(request())).receipt, original.receipt);
    await rejectsUnchanged(firestore, resubmit, request({
      idempotencyKey: 'new-key', payment: { method: 'cash', amountCentavos: 1 },
    }), 'invalid-argument');
  }
});

test('fresh requests consume stock sequentially and underflow is never committed', async () => {
  const { firestore, service } = fixture();
  for (let i = 0; i < 5; i++) {
    await service(request({ idempotencyKey: `fresh-${i}` }));
    assert.equal(stock(firestore), 10 - (i + 1) * 2);
  }
  await rejectsUnchanged(firestore, service, request({ idempotencyKey: 'fresh-6' }), 'failed-precondition');
});

test('fractional quantities preserve approved per-line rounding and authoritative spec', async () => {
  const { firestore, service } = fixture();
  firestore.records.get('products/p1').quantitySpec = { unit: 'kg', precision: 3 };
  firestore.records.get('products/p1').pricing.listedPriceCentavos = 101;
  firestore.records.set('branches/north/stock/p1', { unit: 'kg', precision: 3, quantityScaled: 1000 });
  const result = await service(request({
    lines: [{ productId: 'p1', quantity: '0.125' }],
    payment: { method: 'cash', amountCentavos: 15 },
  }));
  assert.equal(result.receipt.calculation.lines[0].baseCentavos, 13);
  assert.equal(stock(firestore), 875);
});

test('unsafe calculation overflow fails without artifacts', async () => {
  const { firestore, service } = fixture();
  firestore.records.get('products/p1').pricing.listedPriceCentavos = Number.MAX_SAFE_INTEGER;
  await rejectsUnchanged(firestore, service, request(), 'out-of-range');
});

test('request is detached before asynchronous reads and caller mutation', async () => {
  const { firestore, service } = fixture();
  const input = request();
  firestore.onRead = () => {
    input.auth.uid = 'changed-actor';
    input.auth.token.branchId = 'south';
    input.data.lines[0].quantity = '9';
    input.data.payment.amountCentavos = 1044;
  };
  const result = await service(input);
  assert.equal(result.receipt.branchId, 'north');
  assert.equal(result.receipt.calculation.totalCentavos, 232);
  assert.equal(stock(firestore), 8);
  assert.equal(privateReplay(firestore).actorId, auth.uid);
  firestore.onRead = undefined;
  assert.equal((await service(request())).replayed, true);
});

test('malformed replay identity, version, quantity and extra fields fail closed', async () => {
  for (const mutate of [
    (r) => { r.result.version = 2; },
    (r) => { r.result.branchId = 'south'; },
    (r) => { r.result.calculation.lines[0].quantity.spec.precision = 7; },
    (r) => { r.result.calculation.lines[0].pricing.version = 2; },
    (r) => { r.result.calculation.lines[0].totalCentavos = Number.MAX_SAFE_INTEGER + 1; },
    (r) => { r.result.productIds.push('p2'); },
    (r) => { r.result.calculation.lines = []; },
  ]) {
    const { firestore, service } = fixture();
    await service(request());
    mutate(privateReplay(firestore));
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
  }
});

test('non-enumerable and symbol request extras are rejected, not silently dropped', async () => {
  for (const extra of ['cost', Symbol('cost')]) {
    const { firestore, service } = fixture();
    const input = request();
    Object.defineProperty(input.data, extra, { value: 1 });
    await rejectsUnchanged(firestore, service, input, 'invalid-argument');
  }
});

test('safe individual lines cannot overflow the sale sum or taxed total', async () => {
  for (const invoiceRequested of [false, true]) {
    const { firestore, service } = fixture();
    for (const id of ['p1', 'p2']) {
      firestore.records.get(`products/${id}`).pricing.listedPriceCentavos = Number.MAX_SAFE_INTEGER;
    }
    await rejectsUnchanged(firestore, service, request({
      invoiceRequested,
      lines: [{ productId: 'p1', quantity: '1' }, { productId: 'p2', quantity: '1' }],
      payment: { method: 'cash', amountCentavos: Number.MAX_SAFE_INTEGER },
    }), 'out-of-range');
  }
});

test('invalid injected timestamp is rejected before writes', async () => {
  for (const now of [() => new Date(NaN), () => '2026-06-01', () => null]) {
    const { firestore, service } = fixture({ now });
    await rejectsUnchanged(firestore, service, request(), 'failed-precondition');
  }
});
