import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';

import { HttpsError } from 'firebase-functions/v2/https';

import { InventoryError } from '../src/inventory.js';
import { TRANSFER_LINE_LIMIT, createTransferService } from '../src/transfers.js';

const DEMO_ENVIRONMENT = Object.freeze({
  GCLOUD_PROJECT: 'demo-lda-inventory',
  FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const CLOUD_ENVIRONMENT = Object.freeze({
  GCLOUD_PROJECT: 'production',
  FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const NOW_MS = Date.parse('2026-09-24T12:00:00.000Z');
const ADMIN = { uid: 'admin-one', token: { role: 'administrator' } };
const SELLER = { uid: 'seller-one', token: { role: 'seller', branchId: 'branch-north' } };
const piece = Object.freeze({ unit: 'piece', precision: 0 });
const kg = Object.freeze({ unit: 'kg', precision: 2 });
const clone = (value) => structuredClone(value);

// Deterministic doubles are the widest concurrency claim this file makes; real
// Firestore transaction conflicts are covered by the deferred emulator suite.
class MemoryFirestore {
  #documents = new Map();
  #queue = Promise.resolve();

  attempts = 0;
  traces = [];
  retry = false;
  onAbandon = null;

  constructor(records = []) {
    for (const [path, data] of records) this.#documents.set(path, clone(data));
  }

  doc(path) {
    assert.match(path, /^[^/]+\/[^/]+(?:\/[^/]+\/[^/]+)?$/, `unsafe document path: ${path}`);
    assert.ok(!/cost/i.test(path), `cost data is never part of a transfer: ${path}`);
    return { path };
  }

  seed(path, data) {
    this.#documents.set(path, clone(data));
  }

  read(path) {
    const data = this.#documents.get(path);
    return data === undefined ? undefined : clone(data);
  }

  paths() {
    return [...this.#documents.keys()].sort();
  }

  async runTransaction(callback) {
    const previous = this.#queue;
    let release;
    this.#queue = new Promise((resolve) => {
      release = resolve;
    });
    await previous;

    try {
      const execute = async () => {
        this.attempts += 1;
        const trace = [];
        const staged = new Map();
        let writes = 0;
        this.traces.push(trace);
        const transaction = {
          get: async ({ path }) => {
            assert.equal(writes, 0, 'all reads precede every write');
            trace.push(['get', path]);
            const data = this.#documents.get(path);
            return { exists: this.#documents.has(path), data: () => clone(data) };
          },
          create: ({ path }, data) => {
            assert.ok(!this.#documents.has(path), `document already exists: ${path}`);
            assert.ok(!staged.has(path), `duplicate create for ${path}`);
            trace.push(['create', path]);
            writes += 1;
            staged.set(path, clone(data));
          },
          set: ({ path }, data) => {
            trace.push(['set', path]);
            writes += 1;
            staged.set(path, clone(data));
          },
        };
        return { result: await callback(transaction), staged };
      };

      if (this.retry) {
        this.retry = false;
        await execute(); // Abandoned attempt: its staged writes are discarded.
        if (this.onAbandon) await this.onAbandon(this);
      }

      const { result, staged } = await execute();
      for (const [path, data] of staged) this.#documents.set(path, data);
      return result;
    } finally {
      release();
    }
  }
}

// DEMO-RIBBON has never been held by branch-south: its stock document is absent.
function baseRecords() {
  return [
    ['branches/branch-north', { name: 'North', code: 'NTE' }],
    ['branches/branch-south', { name: 'South', code: 'SUR' }],
    ['branches/branch-east', { name: 'East', code: 'EAS' }],
    ['products/DEMO-COFFEE', { internalCode: 'DEMO-COFFEE', name: 'Coffee', quantitySpec: piece }],
    ['products/DEMO-RIBBON', { internalCode: 'DEMO-RIBBON', name: 'Ribbon', quantitySpec: kg }],
    ['branches/branch-north/stock/DEMO-COFFEE', { ...piece, quantityScaled: 12 }],
    ['branches/branch-north/stock/DEMO-RIBBON', { ...kg, quantityScaled: 500 }],
    ['branches/branch-south/stock/DEMO-COFFEE', { ...piece, quantityScaled: 3 }],
  ];
}

function recordsWith(overrides, removals = []) {
  const records = new Map(baseRecords());
  for (const [path, data] of overrides) records.set(path, data);
  for (const path of removals) records.delete(path);
  return [...records];
}

function fixture({ records = baseRecords(), now = () => new Date(NOW_MS), environment = DEMO_ENVIRONMENT } = {}) {
  const firestore = new MemoryFirestore(records);
  const transfer = createTransferService({ firestore, now, environment });
  return { firestore, transfer };
}

function request(data = {}, auth = ADMIN) {
  return {
    auth,
    data: {
      idempotencyKey: 'tr-001',
      sourceBranchId: 'branch-north',
      destinationBranchId: 'branch-south',
      lines: [{ productId: 'DEMO-COFFEE', quantity: '2' }],
      ...data,
    },
  };
}

function rejectsCode(operation, code) {
  return assert.rejects(operation, (error) => {
    assert.ok(error instanceof InventoryError, `expected InventoryError, got ${error}`);
    assert.equal(error.code, code);
    return true;
  });
}

function assertNoTransferWrites(firestore) {
  assert.equal(firestore.read('transfers/tr-001'), undefined);
  assert.equal(firestore.read('transferSubmissionReceipts/tr-001'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-001-0-out'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-001-0-in'), undefined);
  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE'), { ...piece, quantityScaled: 12 });
  assert.deepEqual(firestore.read('branches/branch-south/stock/DEMO-COFFEE'), { ...piece, quantityScaled: 3 });
  assert.equal(firestore.read('branches/branch-south/stock/DEMO-RIBBON'), undefined);
}

async function withEnvironment(values, operation) {
  const previous = Object.fromEntries(Object.keys(values).map((key) => [key, process.env[key]]));
  Object.assign(process.env, values);
  try {
    return await operation();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

async function preflightOrigins(callable, origins) {
  const server = createServer(callable);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    return await Promise.all(origins.map(async (origin) => {
      const response = await fetch(`http://127.0.0.1:${port}`, {
        method: 'OPTIONS',
        headers: { origin, 'access-control-request-method': 'POST' },
      });
      return response.headers.get('access-control-allow-origin');
    }));
  } finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  }
}

test('refuses to run outside the dedicated local demo emulator', async () => {
  for (const environment of [
    CLOUD_ENVIRONMENT,
    { GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
    {},
  ]) {
    const { firestore, transfer } = fixture({ environment });
    await rejectsCode(() => transfer(request()), 'failed-precondition');
    assert.equal(firestore.attempts, 0, 'the guard runs before any transaction');
  }
});

test('requires an authenticated administrator before touching stock', async () => {
  const { firestore, transfer } = fixture();

  await rejectsCode(() => transfer({ ...request(), auth: null }), 'unauthenticated');
  await rejectsCode(() => transfer({ ...request(), auth: { token: { role: 'administrator' } } }), 'unauthenticated');
  await rejectsCode(() => transfer({ ...request(), auth: SELLER }), 'permission-denied');
  await rejectsCode(() => transfer({ ...request(), auth: { uid: 'auditor-1', token: { role: 'auditor' } } }), 'permission-denied');
  await rejectsCode(() => transfer({ ...request(), auth: { uid: 'admin-one' } }), 'permission-denied');
  assert.equal(firestore.attempts, 0);
  assertNoTransferWrites(firestore);
});

test('validates the injected Firestore and clock collaborators', () => {
  assert.throws(() => createTransferService(), TypeError);
  assert.throws(() => createTransferService({ firestore: {} }), TypeError);
  assert.throws(() => createTransferService({ firestore: new MemoryFirestore(), now: 'later' }), TypeError);
});

test('moves stock once and writes the immutable pair, two legs and the receipt', async () => {
  const { firestore, transfer } = fixture();

  const result = await transfer(request());

  assert.deepEqual(result, {
    transferId: 'tr-001',
    sourceBranchId: 'branch-north',
    destinationBranchId: 'branch-south',
    occurredAt: NOW_MS,
    lines: [{
      productId: 'DEMO-COFFEE',
      quantity: '2',
      quantityScaled: 2,
      unit: 'piece',
      precision: 0,
      sourceQuantityScaled: 10,
      destinationQuantityScaled: 5,
    }],
    replayed: false,
  });
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.lines) && Object.isFrozen(result.lines[0]));
  assert.deepEqual(firestore.read('transfers/tr-001'), {
    transferId: 'tr-001',
    sourceBranchId: 'branch-north',
    destinationBranchId: 'branch-south',
    productIds: ['DEMO-COFFEE'],
    lineCount: 1,
    lines: [{ productId: 'DEMO-COFFEE', quantity: '2', quantityScaled: 2, unit: 'piece', precision: 0 }],
    actorId: 'admin-one',
    createdAt: new Date(NOW_MS),
  });
  assert.deepEqual(firestore.read('inventoryMovements/transfer-tr-001-0-out'), {
    type: 'transfer-out',
    transferId: 'tr-001',
    branchId: 'branch-north',
    productId: 'DEMO-COFFEE',
    quantityScaled: -2,
    unit: 'piece',
    precision: 0,
    actorId: 'admin-one',
    occurredAt: new Date(NOW_MS),
  });
  assert.deepEqual(firestore.read('inventoryMovements/transfer-tr-001-0-in'), {
    type: 'transfer-in',
    transferId: 'tr-001',
    branchId: 'branch-south',
    productId: 'DEMO-COFFEE',
    quantityScaled: 2,
    unit: 'piece',
    precision: 0,
    actorId: 'admin-one',
    occurredAt: new Date(NOW_MS),
  });
  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE'), {
    quantityScaled: 10,
    ...piece,
    updatedAt: new Date(NOW_MS),
    lastMovementId: 'transfer-tr-001-0-out',
  });
  assert.deepEqual(firestore.read('transferSubmissionReceipts/tr-001').actorId, 'admin-one');
});

test('a product the destination never held gets a valid zero-based projection', async () => {
  const { firestore, transfer } = fixture();

  const result = await transfer(request({
    lines: [{ productId: 'DEMO-RIBBON', quantity: '1.25' }],
  }));

  assert.deepEqual(result.lines[0], {
    productId: 'DEMO-RIBBON',
    quantity: '1.25',
    quantityScaled: 125,
    unit: 'kg',
    precision: 2,
    sourceQuantityScaled: 375,
    destinationQuantityScaled: 125,
  });
  assert.deepEqual(firestore.read('branches/branch-south/stock/DEMO-RIBBON'), {
    quantityScaled: 125,
    ...kg,
    updatedAt: new Date(NOW_MS),
    lastMovementId: 'transfer-tr-001-0-in',
  });
});

test('conserves quantity across several products and writes one matching leg pair each', async () => {
  const { firestore, transfer } = fixture();

  const result = await transfer(request({
    lines: [
      { productId: 'DEMO-COFFEE', quantity: '5' },
      { productId: 'DEMO-RIBBON', quantity: '2.50' },
    ],
  }));

  assert.equal(result.lines.length, 2);
  const before = { coffee: 12 + 3, ribbon: 500 + 0 };
  const after = {
    coffee: firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled
      + firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled,
    ribbon: firestore.read('branches/branch-north/stock/DEMO-RIBBON').quantityScaled
      + firestore.read('branches/branch-south/stock/DEMO-RIBBON').quantityScaled,
  };
  assert.deepEqual(after, before, 'total stock across the pair is unchanged');

  const legs = ['0-out', '0-in', '1-out', '1-in'].map((suffix) => firestore.read(`inventoryMovements/transfer-tr-001-${suffix}`));
  assert.deepEqual(legs.map((leg) => leg.type), ['transfer-out', 'transfer-in', 'transfer-out', 'transfer-in']);
  assert.deepEqual(legs.map((leg) => leg.quantityScaled), [-5, 5, -250, 250]);
  assert.deepEqual(legs.map((leg) => leg.branchId), ['branch-north', 'branch-south', 'branch-north', 'branch-south']);
  assert.deepEqual(legs.map((leg) => leg.unit), ['piece', 'piece', 'kg', 'kg']);
  for (const leg of legs) {
    assert.equal(leg.transferId, 'tr-001');
    assert.equal(leg.actorId, 'admin-one');
    assert.deepEqual(leg.occurredAt, new Date(NOW_MS));
  }
});

test('no transfer record, movement or returned line ever carries cost', async () => {
  const { firestore, transfer } = fixture();
  firestore.seed('products/DEMO-COFFEE', {
    internalCode: 'DEMO-COFFEE',
    name: 'Coffee',
    quantitySpec: piece,
    pricing: { listedPriceCentavos: 12_500, currency: 'MXN' },
  });

  const result = await transfer(request());

  const serialized = JSON.stringify({
    result,
    transfer: firestore.read('transfers/tr-001'),
    out: firestore.read('inventoryMovements/transfer-tr-001-0-out'),
    in: firestore.read('inventoryMovements/transfer-tr-001-0-in'),
    receipt: firestore.read('transferSubmissionReceipts/tr-001'),
  });
  assert.doesNotMatch(serialized, /cost|centavos|price|pricing/i);
  assert.deepEqual(Object.keys(firestore.read('transfers/tr-001').lines[0]), ['productId', 'quantity', 'quantityScaled', 'unit', 'precision']);
});

test('reads every branch, product, stock and collision document before writing', async () => {
  const { firestore, transfer } = fixture();

  await transfer(request({
    lines: [{ productId: 'DEMO-COFFEE', quantity: '5' }, { productId: 'DEMO-RIBBON', quantity: '1' }],
  }));

  const trace = firestore.traces.at(-1);
  const firstWrite = trace.findIndex(([kind]) => kind !== 'get');
  assert.ok(firstWrite > 0, 'the transaction starts with reads');
  assert.ok(trace.slice(0, firstWrite).every(([kind]) => kind === 'get'));
  const reads = trace.slice(0, firstWrite).map(([, path]) => path);
  assert.deepEqual(reads, [
    'transferSubmissionReceipts/tr-001',
    'branches/branch-north',
    'branches/branch-south',
    'products/DEMO-COFFEE',
    'branches/branch-north/stock/DEMO-COFFEE',
    'branches/branch-south/stock/DEMO-COFFEE',
    'products/DEMO-RIBBON',
    'branches/branch-north/stock/DEMO-RIBBON',
    'branches/branch-south/stock/DEMO-RIBBON',
    'transfers/tr-001',
    'inventoryMovements/transfer-tr-001-0-out',
    'inventoryMovements/transfer-tr-001-0-in',
    'inventoryMovements/transfer-tr-001-1-out',
    'inventoryMovements/transfer-tr-001-1-in',
  ]);
});

test('rejects one identical branch pair and a missing source or destination branch', async () => {
  const same = fixture();
  await rejectsCode(
    () => same.transfer(request({ destinationBranchId: 'branch-north' })),
    'invalid-argument',
  );
  assertNoTransferWrites(same.firestore);

  const missingSource = fixture({ records: recordsWith([], ['branches/branch-north', 'branches/branch-north/stock/DEMO-COFFEE', 'branches/branch-north/stock/DEMO-RIBBON']) });
  await rejectsCode(() => missingSource.transfer(request()), 'not-found');

  const missingDestination = fixture({ records: recordsWith([], ['branches/branch-south', 'branches/branch-south/stock/DEMO-COFFEE']) });
  await rejectsCode(() => missingDestination.transfer(request()), 'not-found');
  assert.equal(missingSource.firestore.attempts, 1);
});

test('a branch without a stock projection transfers nothing, and a malformed one fails closed', async () => {
  const absentSource = fixture({ records: recordsWith([], ['branches/branch-north/stock/DEMO-COFFEE']) });
  await rejectsCode(() => absentSource.transfer(request()), 'failed-precondition');
  assert.equal(absentSource.firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled, 3);

  for (const broken of [
    { ...piece, quantityScaled: -1 },
    { ...piece, quantityScaled: 1.5 },
    { ...piece, quantityScaled: '4' },
    { unit: 'kg', precision: 2, quantityScaled: 4 },
    { quantityScaled: 4 },
  ]) {
    const { firestore, transfer } = fixture({ records: recordsWith([['branches/branch-north/stock/DEMO-COFFEE', broken]]) });
    await rejectsCode(() => transfer(request()), 'failed-precondition');
    assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE'), broken);
  }
});

test('rejects a missing product or an invalid stored quantity specification without writes', async () => {
  const missing = fixture({ records: recordsWith([], ['products/DEMO-COFFEE']) });
  await rejectsCode(() => missing.transfer(request()), 'not-found');
  assertNoTransferWrites(missing.firestore);

  for (const spec of [{ unit: 'Piece', precision: 0 }, { unit: 'piece', precision: 7 }, { unit: 'piece' }, null]) {
    const { transfer } = fixture({ records: recordsWith([['products/DEMO-COFFEE', { quantitySpec: spec }]]) });
    await rejectsCode(() => transfer(request()), 'failed-precondition');
  }
});

test('accepts only canonical positive quantities representable by the product specification', async () => {
  const { firestore, transfer } = fixture();

  for (const quantity of ['0', '-2', '0.00', '1.001', '2.', '.5', '+2', '002', '0x2', '1e2', '2 ', '', '٢', '٢']) {
    await rejectsCode(() => transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity }] })), 'invalid-argument');
  }
  await rejectsCode(() => transfer(request({ lines: [{ productId: 'DEMO-RIBBON', quantity: '1'.repeat(19) }] })), 'invalid-argument');
  await rejectsCode(() => transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: 2 }] })), 'invalid-argument');
  assertNoTransferWrites(firestore);
});

test('rejects safe-integer overflow in either stock projection', async () => {
  const destination = fixture({
    records: recordsWith([['branches/branch-south/stock/DEMO-COFFEE', { ...piece, quantityScaled: Number.MAX_SAFE_INTEGER }]]),
  });
  await rejectsCode(() => destination.transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: '1' }] })), 'out-of-range');

  const huge = fixture();
  await rejectsCode(() => huge.transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: '9007199254740991' }] })), 'failed-precondition');
  assertNoTransferWrites(huge.firestore);
});

test('rejects duplicate products instead of silently merging them', async () => {
  const { firestore, transfer } = fixture();

  await rejectsCode(() => transfer(request({
    lines: [
      { productId: 'DEMO-COFFEE', quantity: '1' },
      { productId: 'DEMO-COFFEE', quantity: '2' },
    ],
  })), 'invalid-argument');
  assertNoTransferWrites(firestore);
});

test('rejects an insufficient line after valid ones with zero partial writes', async () => {
  const { firestore, transfer } = fixture();

  await rejectsCode(() => transfer(request({
    lines: [
      { productId: 'DEMO-COFFEE', quantity: '5' },
      { productId: 'DEMO-RIBBON', quantity: '999.99' },
    ],
  })), 'failed-precondition');

  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE'), { ...piece, quantityScaled: 12 });
  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-RIBBON'), { ...kg, quantityScaled: 500 });
  assert.equal(firestore.read('transfers/tr-001'), undefined);
  assert.equal(firestore.read('transferSubmissionReceipts/tr-001'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-001-0-out'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-001-0-in'), undefined);
});

test('rejects malformed requests, unknown fields, client timestamps and oversized line sets', async () => {
  const { firestore, transfer } = fixture();
  const validLine = { productId: 'DEMO-COFFEE', quantity: '1' };

  const oversized = { lines: Array.from({ length: TRANSFER_LINE_LIMIT + 1 }, (_, index) => ({ ...validLine, productId: `PRODUCT-${index}` })) };
  const rejections = [
    [{ occurredAt: 1 }, /client timestamp/],
    [{ note: 'please' }, /unknown/],
    [{ sourceBranchId: undefined }, /missing/],
    [{ lines: [] }, /empty/],
    [{ lines: validLine }, /array/],
    [{ lines: [validLine, undefined] }, /sparse/],
    [{ lines: [{ productId: 'DEMO-COFFEE', quantity: '1', costMxn: '1.00' }] }, /unknown line field/],
    [{ lines: [{ quantity: '1' }] }, /missing line field/],
    [{ idempotencyKey: 'branch/../x' }, /identifier/],
    [{ idempotencyKey: '' }, /identifier/],
    [{ idempotencyKey: 'a'.repeat(129) }, /identifier/],
    [{ idempotencyKey: 'a'.repeat(113) }, /identifier/],
    [{ sourceBranchId: 'north' }, /branch/],
    [{ sourceBranchId: 'branch-north/../east' }, /branch/],
    [{ destinationBranchId: 'branch-north' }, /distinct/],
    [{ destinationBranchId: 'branch-Notth' }, /branch/],
    [{ lines: [{ productId: 'demo-coffee', quantity: '1' }] }, /product identifier/],
    [oversized, /bounded/],
  ];

  for (const [data] of rejections) {
    await rejectsCode(() => transfer(request(data)), 'invalid-argument');
  }

  // Whole-payload shapes cannot be merged into a valid default request.
  for (const data of [undefined, null, {}, [], 'not-an-object', 42]) {
    await rejectsCode(() => transfer({ auth: ADMIN, data }), 'invalid-argument');
  }

  const sparse = request();
  sparse.data.lines = [validLine];
  sparse.data.lines.extra = true;
  await rejectsCode(() => transfer(sparse), 'invalid-argument');
  const holes = request();
  holes.data.lines = [validLine];
  delete holes.data.lines[0];
  await rejectsCode(() => transfer(holes), 'invalid-argument');

  assertNoTransferWrites(firestore);
  assert.equal(firestore.attempts, 0, 'payload validation happens before the transaction opens');
});

test('replays the identical request deterministically and never moves stock twice', async () => {
  const { firestore, transfer } = fixture();

  const first = await transfer(request());
  const second = await transfer(request());

  assert.equal(second.replayed, true);
  assert.deepEqual({ ...second, replayed: false }, first);
  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 10);
  assert.deepEqual(firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled, 5);
  assert.equal(firestore.read('transfers/tr-001').createdAt.getTime(), NOW_MS);
  const documents = firestore.paths().filter((path) => path.startsWith('inventoryMovements/'));
  assert.deepEqual(documents, ['inventoryMovements/transfer-tr-001-0-in', 'inventoryMovements/transfer-tr-001-0-out']);

  // A broken clock must not change a historical replay.
  const broken = createTransferService({ firestore, now: () => { throw new Error('clock unavailable'); }, environment: DEMO_ENVIRONMENT });
  assert.deepEqual({ ...await broken(request()), replayed: false }, first);
});

test('a different actor or payload on the same key conflicts without moving stock', async () => {
  const { firestore, transfer } = fixture();
  await transfer(request());

  await rejectsCode(() => transfer(request({}, { uid: 'admin-two', token: { role: 'administrator' } })), 'already-exists');
  await rejectsCode(() => transfer(request({ destinationBranchId: 'branch-east' })), 'already-exists');
  await rejectsCode(() => transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: '3' }] })), 'already-exists');

  assert.equal(firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 10);
  assert.equal(firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled, 5);
  assert.equal(firestore.read('transfers/tr-001').actorId, 'admin-one');
});

test('a receipt bound to another request conflicts before its result is read', async () => {
  const { firestore, transfer } = fixture();
  await transfer(request());
  const receipt = firestore.read('transferSubmissionReceipts/tr-001');

  // Ownership fails closed first: a collision never touches the stored result.
  firestore.seed('transferSubmissionReceipts/tr-001', { ...receipt, result: 'not-an-object' });
  await rejectsCode(() => transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: '4' }] })), 'already-exists');
  assert.equal(firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 10);
});

test('a damaged or extended stored replay result fails closed instead of replaying', async () => {
  for (const damage of [
    (receipt) => ({ ...receipt, result: undefined }),
    (receipt) => ({ ...receipt, result: { ...receipt.result, lines: [] } }),
    (receipt) => ({ ...receipt, result: { ...receipt.result, unexpected: 1 } }),
    (receipt) => ({ ...receipt, completedAt: '2026-09-24T12:00:00.000Z' }),
  ]) {
    const { firestore, transfer } = fixture();
    await transfer(request());
    firestore.seed('transferSubmissionReceipts/tr-001', damage(firestore.read('transferSubmissionReceipts/tr-001')));
    await rejectsCode(() => transfer(request()), 'failed-precondition');
    assert.equal(firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 10);
  }
});

test('an existing transfer record without a receipt is an orphaned collision', async () => {
  const { firestore, transfer } = fixture();
  firestore.seed('transfers/tr-001', { transferId: 'tr-001' });

  await rejectsCode(() => transfer(request()), 'already-exists');
  assert.equal(firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 12);
  assert.equal(firestore.read('transferSubmissionReceipts/tr-001'), undefined);
});

test('an existing movement leg without a receipt is refused before any write', async () => {
  const { firestore, transfer } = fixture();
  firestore.seed('inventoryMovements/transfer-tr-001-0-in', { type: 'transfer-in' });

  await rejectsCode(() => transfer(request()), 'already-exists');

  assert.equal(firestore.read('transfers/tr-001'), undefined);
  assert.equal(firestore.read('transferSubmissionReceipts/tr-001'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-001-0-out'), undefined);
  assert.deepEqual(firestore.read('inventoryMovements/transfer-tr-001-0-in'), { type: 'transfer-in' });
  assert.deepEqual(firestore.read('branches/branch-north/stock/DEMO-COFFEE'), { ...piece, quantityScaled: 12 });
  assert.deepEqual(firestore.read('branches/branch-south/stock/DEMO-COFFEE'), { ...piece, quantityScaled: 3 });
});

test('emptying the source and the smallest representable unit are valid transfers', async () => {
  const { firestore, transfer } = fixture();

  const emptied = await transfer(request({ lines: [{ productId: 'DEMO-COFFEE', quantity: '12' }] }));
  assert.equal(emptied.lines[0].sourceQuantityScaled, 0);
  assert.equal(emptied.lines[0].destinationQuantityScaled, 15);

  const smallest = await transfer({
    auth: ADMIN,
    data: {
      idempotencyKey: 'tr-002',
      sourceBranchId: 'branch-north',
      destinationBranchId: 'branch-south',
      lines: [{ productId: 'DEMO-RIBBON', quantity: '0.01' }],
    },
  });
  assert.equal(smallest.lines[0].quantityScaled, 1);
  assert.equal(smallest.lines[0].destinationQuantityScaled, 1);

  await rejectsCode(() => transfer({
    auth: ADMIN,
    data: {
      idempotencyKey: 'tr-003',
      sourceBranchId: 'branch-north',
      destinationBranchId: 'branch-south',
      lines: [{ productId: 'DEMO-RIBBON', quantity: '0.001' }],
    },
  }), 'invalid-argument');

  assert.equal(
    firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled
    + firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled,
    15,
  );
});

test('serializes concurrent transfers and refuses the one that would underflow', async () => {
  const { firestore, transfer } = fixture();

  const results = await Promise.allSettled([
    transfer(request({ idempotencyKey: 'tr-a', lines: [{ productId: 'DEMO-COFFEE', quantity: '8' }] })),
    transfer(request({ idempotencyKey: 'tr-b', lines: [{ productId: 'DEMO-COFFEE', quantity: '8' }] })),
  ]);

  const fulfilled = results.filter((entry) => entry.status === 'fulfilled');
  const rejected = results.filter((entry) => entry.status === 'rejected');
  assert.equal(fulfilled.length, 1);
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason instanceof InventoryError, true);
  assert.equal(rejected[0].reason.code, 'failed-precondition');
  assert.equal(
    firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled,
    12 - fulfilled[0].value.lines[0].quantityScaled,
  );
  assert.equal(
    firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled,
    3 + fulfilled[0].value.lines[0].quantityScaled,
  );
  assert.equal(firestore.read('transfers/tr-b'), undefined);
  assert.equal(firestore.read('inventoryMovements/transfer-tr-b-0-out'), undefined);
});

test('an abandoned attempt leaves no partial writes and its retry re-reads state', async () => {
  const committed = fixture();
  committed.firestore.retry = true;
  const result = await committed.transfer(request());
  assert.equal(committed.firestore.attempts, 2);
  assert.equal(result.replayed, false);
  assert.equal(committed.firestore.read('branches/branch-north/stock/DEMO-COFFEE').quantityScaled, 10);
  assert.equal(committed.firestore.paths().filter((path) => path.startsWith('inventoryMovements/')).length, 2);

  const raced = fixture();
  raced.firestore.retry = true;
  raced.firestore.onAbandon = (db) => db.seed('branches/branch-north/stock/DEMO-COFFEE', { ...piece, quantityScaled: 1 });
  await rejectsCode(() => raced.transfer(request()), 'failed-precondition');
  assert.equal(raced.firestore.read('transfers/tr-001'), undefined);
  assert.equal(raced.firestore.read('branches/branch-south/stock/DEMO-COFFEE').quantityScaled, 3);
});

async function callableTransfer() {
  const { transferInventory } = await import('../src/index.js');
  return transferInventory;
}

test('the transferInventory callable permits only localhost web origins', async () => {
  const transferInventory = await callableTransfer();
  const allowed = ['http://localhost', 'http://localhost:5000', 'https://127.0.0.1:7357'];
  const denied = ['https://example.com', 'http://localhost.example.com', 'http://127.0.0.2:5000'];

  assert.deepEqual(await preflightOrigins(transferInventory, allowed), allowed);
  assert.deepEqual(await preflightOrigins(transferInventory, denied), [null, null, null]);
});

test('the callable guards the environment before Admin SDK use and maps domain errors', async () => {
  const transferInventory = await callableTransfer();

  await withEnvironment(CLOUD_ENVIRONMENT, async () => {
    await assert.rejects(() => transferInventory.run(request()), (error) => {
      assert.ok(error instanceof HttpsError);
      assert.equal(error.code, 'failed-precondition');
      assert.match(error.message, /transfers are restricted to the local demo emulator/);
      return true;
    });
  });

  await withEnvironment(DEMO_ENVIRONMENT, async () => {
    await assert.rejects(
      () => transferInventory.run({ ...request(), auth: null }),
      (error) => error instanceof HttpsError && error.code === 'unauthenticated',
    );
    await assert.rejects(
      () => transferInventory.run(request({ destinationBranchId: 'branch-north' })),
      (error) => error instanceof HttpsError && error.code === 'invalid-argument',
    );
    await assert.rejects(
      () => transferInventory.run({
        auth: ADMIN,
        get data() {
          throw new Error('private infrastructure detail');
        },
      }),
      (error) => {
        assert.ok(error instanceof HttpsError);
        assert.equal(error.code, 'internal');
        assert.equal(error.message, 'inventory transfer is temporarily unavailable');
        assert.doesNotMatch(error.message, /private infrastructure detail/);
        return true;
      },
    );
  });
});
