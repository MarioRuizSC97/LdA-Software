/**
 * DN-01 — backend acknowledgement regression for destination transfer notices.
 *
 * Everything runs on an in-memory Firestore double: no emulator, no socket and
 * no live project. These tests pin the `markTransferNoticeRead` service and
 * callable contract from the destination-notices implementation contract
 * (odd/tasks/inventory-transfer-destination-notices.md L4): exactly one
 * `{transferId}` input, trusted seller identity from token claims only, a
 * server-side destination check against the private transfer audit, a leaf
 * marker document with exactly `userId`/`branchId`/`transferId`/`readAt`, and
 * replays that preserve the original `readAt`. Existing transfer semantics are
 * pinned separately in `transfers.test.mjs` and are never touched here.
 */
import assert from 'node:assert/strict';
import test, { after } from 'node:test';
import { registerHooks } from 'node:module';

import { InventoryError } from '../src/inventory.js';
import { createTransferNoticeReadService } from '../src/transfer-notices.js';

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
const LATER_MS = Date.parse('2026-09-25T09:30:00.000Z');
const MARKER_PATH = 'transferNoticeReads/seller-one/branches/branch-south/transfers/tr-001';
const TRANSFER_ID = 'tr-001';
const SELLER = Object.freeze({
  uid: 'seller-one',
  token: { role: 'seller', branchId: 'branch-south' },
});
const ADMIN = Object.freeze({ uid: 'admin-one', token: { role: 'administrator' } });
const NOT_FOUND_MESSAGE = 'transfer was not found in this branch';

function transferRecord(overrides = {}) {
  return {
    transferId: TRANSFER_ID,
    sourceBranchId: 'branch-north',
    destinationBranchId: 'branch-south',
    productIds: ['DEMO-COFFEE'],
    lineCount: 1,
    lines: [{ productId: 'DEMO-COFFEE', quantity: '2', quantityScaled: 2, unit: 'piece', precision: 0 }],
    actorId: 'admin-one',
    createdAt: new Date(NOW_MS),
    ...overrides,
  };
}

function markerRecord(overrides = {}) {
  return {
    userId: 'seller-one',
    branchId: 'branch-south',
    transferId: TRANSFER_ID,
    readAt: new Date(NOW_MS),
    ...overrides,
  };
}

function baseRecords() {
  return [
    ['branches/branch-north', { name: 'North', code: 'NTE' }],
    ['branches/branch-south', { name: 'South', code: 'SUR' }],
    ['products/DEMO-COFFEE', { internalCode: 'DEMO-COFFEE', name: 'Coffee' }],
    [`transfers/${TRANSFER_ID}`, transferRecord()],
  ];
}

class MemoryFirestore {
  #documents = new Map();
  #queue = Promise.resolve();

  attempts = 0;
  traces = [];

  constructor(records = []) {
    for (const [path, data] of records) this.#documents.set(path, structuredClone(data));
  }

  doc(path) {
    assert.match(path, /^(?:[^/]+\/){1,7}[^/]+$/, `unsafe document path: ${path}`);
    return { path };
  }

  seed(path, data) {
    this.#documents.set(path, structuredClone(data));
  }

  read(path) {
    const data = this.#documents.get(path);
    return data === undefined ? undefined : structuredClone(data);
  }

  paths() {
    return [...this.#documents.keys()].sort();
  }

  async runTransaction(callback) {
    const previous = this.#queue;
    let release;
    this.#queue = new Promise((resolve) => { release = resolve; });
    await previous;

    try {
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
          return { exists: this.#documents.has(path), data: () => structuredClone(data) };
        },
        create: ({ path }, data) => {
          assert.ok(!this.#documents.has(path), `document already exists: ${path}`);
          assert.ok(!staged.has(path), `duplicate create for ${path}`);
          trace.push(['create', path]);
          writes += 1;
          staged.set(path, structuredClone(data));
        },
        set: ({ path }, data) => {
          trace.push(['set', path]);
          writes += 1;
          staged.set(path, structuredClone(data));
        },
      };
      const result = await callback(transaction);
      for (const [path, data] of staged) this.#documents.set(path, data);
      return result;
    } finally {
      release();
    }
  }
}

function fixture({
  records = baseRecords(),
  now = () => new Date(NOW_MS),
  environment = DEMO_ENVIRONMENT,
} = {}) {
  const firestore = new MemoryFirestore(records);
  const markRead = createTransferNoticeReadService({ firestore, now, environment });
  return { firestore, markRead };
}

function request(data = {}, auth = SELLER) {
  return { auth, data: { transferId: TRANSFER_ID, ...data } };
}

function rejectsCode(operation, code) {
  return assert.rejects(operation, (error) => {
    assert.ok(error instanceof InventoryError, `expected InventoryError, got ${error}`);
    assert.equal(error.code, code);
    return true;
  });
}

function assertNoMarkerWrites(firestore, records = baseRecords()) {
  assert.equal(firestore.read(MARKER_PATH), undefined);
  assert.deepEqual(firestore.paths(), records.map(([path]) => path).sort());
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

test('refuses to run outside the dedicated local demo emulator', async () => {
  for (const environment of [
    CLOUD_ENVIRONMENT,
    { GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
    {},
  ]) {
    const { firestore, markRead } = fixture({ environment });
    await rejectsCode(() => markRead(request()), 'failed-precondition');
    assert.equal(firestore.attempts, 0, 'the guard runs before any transaction');
  }
});

test('requires an authenticated assigned seller before any read', async () => {
  const { firestore, markRead } = fixture();

  const identities = [
    null,
    {},
    { token: { role: 'seller', branchId: 'branch-south' } },
    { uid: 'seller/one', token: { role: 'seller', branchId: 'branch-south' } },
    { uid: '', token: { role: 'seller', branchId: 'branch-south' } },
    { uid: 'seller-one' },
    { uid: 'seller-one', token: null },
    { uid: 'seller-one', token: { role: 'administrator' } },
    { uid: 'auditor-one', token: { role: 'auditor', branchId: 'branch-south' } },
    { uid: 'seller-one', token: { role: 'seller' } },
    { uid: 'seller-one', token: { role: 'seller', branchId: 'north' } },
    { uid: 'seller-one', token: { role: 'seller', branchId: 'branch-north/../south' } },
    { uid: 'seller-one', token: { role: 'seller', branchId: 42 } },
  ];
  for (const auth of identities) {
    await assert.rejects(() => markRead(request({}, auth)), (error) => {
      assert.ok(error instanceof InventoryError);
      assert.ok(['unauthenticated', 'permission-denied'].includes(error.code), `unexpected code ${error.code}`);
      return true;
    });
  }
  // A seller is never refused for being a seller, only for identity problems.
  await rejectsCode(() => markRead(request({}, ADMIN)), 'permission-denied');
  assert.equal(firestore.attempts, 0, 'identity checks run before the transaction');
  assertNoMarkerWrites(firestore);
});

// The exact path-safe uid contract shared with the client reader
// (lib/movements/inventory_movement.dart isPathSafeUid) and the server
// validTargetUid precedent (sellerProfiles.js).
const PATH_SAFE_UIDS = Object.freeze([
  'seller-1',
  'seller.one',
  'user+tag@gmail.com',
  'uid with spaces',
  'identidad-ñ',
  '🔥fire-seller',
  '_',
  '__x',
  'x__',
  'a'.repeat(128),
]);
const UNSAFE_UIDS = Object.freeze([
  'seller/one',
  'seller\\one',
  '.',
  '..',
  '__forbidden__',
  '____',
  'a\tb',
  'a\nb',
  '\u0000',
  'x\u007F',
  '',
  'a'.repeat(129),
]);

test('accepts every path-safe uid the existing client contract allows', async () => {
  for (const uid of PATH_SAFE_UIDS) {
    const { firestore, markRead } = fixture();
    const result = await markRead(request({}, { uid, token: { role: 'seller', branchId: 'branch-south' } }));
    assert.deepEqual(result, { transferId: TRANSFER_ID, branchId: 'branch-south', read: true });
    const markerPath = `transferNoticeReads/${uid}/branches/branch-south/transfers/${TRANSFER_ID}`;
    assert.deepEqual(firestore.read(markerPath), {
      userId: uid,
      branchId: 'branch-south',
      transferId: TRANSFER_ID,
      readAt: new Date(NOW_MS),
    });
    assert.deepEqual(firestore.paths(), baseRecords().map(([path]) => path).concat(markerPath).sort());
  }
});

test('rejects slash, backslash, control, reserved and oversized uids before any read', async () => {
  const { firestore, markRead } = fixture();
  for (const uid of [...UNSAFE_UIDS, 42, undefined]) {
    await rejectsCode(
      () => markRead(request({}, { uid, token: { role: 'seller', branchId: 'branch-south' } })),
      'unauthenticated',
    );
  }
  assert.equal(firestore.attempts, 0, 'an unusable identity must never open a transaction');
  assertNoMarkerWrites(firestore);
});

test('validates the injected Firestore and clock collaborators', () => {
  assert.throws(() => createTransferNoticeReadService(), TypeError);
  assert.throws(() => createTransferNoticeReadService({ firestore: {} }), TypeError);
  assert.throws(
    () => createTransferNoticeReadService({ firestore: new MemoryFirestore(), now: 'later' }),
    TypeError,
  );
});

test('acknowledges a destination transfer and writes exactly the marker fields', async () => {
  const { firestore, markRead } = fixture();

  const result = await markRead(request());

  assert.deepEqual(result, { transferId: TRANSFER_ID, branchId: 'branch-south', read: true });
  assert.ok(Object.isFrozen(result), 'the acknowledgement result must be frozen');
  const marker = firestore.read(MARKER_PATH);
  assert.deepEqual(marker, {
    userId: 'seller-one',
    branchId: 'branch-south',
    transferId: TRANSFER_ID,
    readAt: new Date(NOW_MS),
  });
  assert.deepEqual(
    Object.keys(marker),
    ['userId', 'branchId', 'transferId', 'readAt'],
    'the marker carries exactly the contract fields',
  );
  assert.ok(marker.readAt instanceof Date, 'readAt is a server-provided Date, never client input');

  const trace = firestore.traces.at(-1);
  assert.deepEqual(trace.slice(0, 2), [
    ['get', `transfers/${TRANSFER_ID}`],
    ['get', MARKER_PATH],
  ], 'the private audit and the marker are both read before any write');
  assert.deepEqual(trace[2], ['create', MARKER_PATH]);
  assert.deepEqual(trace.slice(3), [], 'no other document is touched');
});

test('keeps foreign and missing transfers equally invisible to the destination seller', async () => {
  const foreign = fixture({
    records: baseRecords().map(([path, data]) => (
      path === `transfers/${TRANSFER_ID}` ? [path, transferRecord({ destinationBranchId: 'branch-north' })] : [path, data]
    )),
  });
  await rejectsCode(() => foreign.markRead(request()), 'not-found');
  assertNoMarkerWrites(foreign.firestore);

  const missing = fixture({ records: baseRecords().filter(([path]) => path !== `transfers/${TRANSFER_ID}`) });
  const missingError = await assert.rejects(
    () => missing.markRead(request()),
    (error) => {
      assert.ok(error instanceof InventoryError);
      assert.equal(error.code, 'not-found');
      assert.equal(error.message, NOT_FOUND_MESSAGE);
      return true;
    },
  ) ?? true;
  assert.equal(missingError, true);
  assertNoMarkerWrites(missing.firestore, baseRecords().filter(([path]) => path !== `transfers/${TRANSFER_ID}`));

  // Both refusals share one code and message, so existence never leaks.
  const foreignError = await assert.rejects(
    () => foreign.markRead(request()),
    (error) => {
      assert.equal(error.code, 'not-found');
      assert.equal(error.message, NOT_FOUND_MESSAGE);
      assert.doesNotMatch(error.message, /branch-north|branch-south|source|destination|lines|actor/i);
      return true;
    },
  ) ?? true;
  assert.equal(foreignError, true);
});

test('a malformed private transfer audit fails closed without writing', async () => {
  for (const damage of [
    transferRecord({ unexpected: 1 }),
    transferRecord({ transferId: 'other-key' }),
    transferRecord({ destinationBranchId: 'not-a-branch' }),
    transferRecord({ destinationBranchId: 42 }),
    (({ transferId, ...rest }) => rest)(transferRecord()),
    null,
  ]) {
    const { firestore, markRead } = fixture({
      records: baseRecords().map(([path, data]) => (
        path === `transfers/${TRANSFER_ID}` ? [path, structuredClone(damage)] : [path, data]
      )),
    });
    await rejectsCode(() => markRead(request()), 'failed-precondition');
    assertNoMarkerWrites(firestore);
  }
});

test('replays an existing marker and preserves the original readAt', async () => {
  const originalReadAt = new Date(Date.parse('2026-09-20T08:15:00.000Z'));
  const { firestore, markRead } = fixture({
    records: [...baseRecords(), [MARKER_PATH, markerRecord({ readAt: originalReadAt })]],
    now: () => new Date(LATER_MS),
  });

  const result = await markRead(request());

  assert.deepEqual(result, { transferId: TRANSFER_ID, branchId: 'branch-south', read: true });
  assert.deepEqual(firestore.read(MARKER_PATH), markerRecord({ readAt: originalReadAt }));
  const trace = firestore.traces.at(-1);
  assert.deepEqual(
    trace.filter(([kind]) => kind !== 'get'),
    [],
    'a replay never writes',
  );
  assert.equal(firestore.read(MARKER_PATH).readAt.getTime(), originalReadAt.getTime());
});

test('a new invocation after navigation replays without a second write', async () => {
  const originalReadAt = new Date(Date.parse('2026-09-20T08:15:00.000Z'));
  const { firestore, markRead } = fixture({
    records: [...baseRecords(), [MARKER_PATH, markerRecord({ readAt: originalReadAt })]],
    now: () => new Date(LATER_MS),
  });

  const first = await markRead(request());
  const second = await markRead(request());

  assert.deepEqual(first, second);
  assert.equal(firestore.attempts, 2, 'each invocation opens its own transaction');
  assert.equal(firestore.read(MARKER_PATH).readAt.getTime(), originalReadAt.getTime());
  const writes = firestore.traces.flat().filter(([kind]) => kind !== 'get');
  assert.deepEqual(writes, [], 'repeated acknowledgement stays idempotent');
});

test('a conflicting or damaged stored marker fails closed without writes', async () => {
  for (const damage of [
    markerRecord({ userId: 'seller-two' }),
    markerRecord({ branchId: 'branch-north' }),
    markerRecord({ transferId: 'tr-002' }),
    markerRecord({ readAt: '2026-09-24T12:00:00.000Z' }),
    markerRecord({ readAt: 1 }),
    markerRecord({ extra: true }),
    (({ readAt, ...rest }) => rest)(markerRecord()),
  ]) {
    const { firestore, markRead } = fixture({
      records: [...baseRecords(), [MARKER_PATH, structuredClone(damage)]],
    });
    await rejectsCode(() => markRead(request()), 'failed-precondition');
    assert.deepEqual(firestore.read(MARKER_PATH), structuredClone(damage), 'the stored marker is never overwritten');
  }
});

test('rejects malformed requests, unknown fields and client-supplied identity', async () => {
  const { firestore, markRead } = fixture();

  const rejections = [
    [{ transferId: TRANSFER_ID, branchId: 'branch-east' }, /missing or unsupported/],
    [{ transferId: TRANSFER_ID, readAt: NOW_MS }, /missing or unsupported/],
    [{ transferId: TRANSFER_ID, userId: 'seller-one' }, /missing or unsupported/],
    [{ transferId: 42 }, /identifier/],
    [{ transferId: '' }, /identifier/],
    [{ transferId: '../etc' }, /identifier/],
    [{ transferId: 'tr 001' }, /identifier/],
    [{ transferId: 'a'.repeat(129) }, /identifier/],
    [{ transferId: 'a'.repeat(113) }, /identifier/],
  ];
  for (const [data] of rejections) {
    await rejectsCode(() => markRead(request(data)), 'invalid-argument');
  }
  const oversizedAcceptedBoundary = request({ transferId: 'a'.repeat(112) });
  await rejectsCode(() => markRead(oversizedAcceptedBoundary), 'not-found');

  for (const data of [null, undefined, {}, [], 'tr-001', 42]) {
    await rejectsCode(() => markRead({ auth: SELLER, data }), 'invalid-argument');
  }

  assertNoMarkerWrites(firestore);
  assert.equal(firestore.attempts, 1, 'only the boundary-length probe ever reached the audit read');
});

test('a failing clock refuses a fresh marker but never blocks a replay', async () => {
  const throwingClock = fixture({ now: () => { throw new Error('clock unavailable'); } });
  await rejectsCode(() => throwingClock.markRead(request()), 'failed-precondition');
  assertNoMarkerWrites(throwingClock.firestore);

  const invalidClock = fixture({ now: () => 'not-a-date' });
  await rejectsCode(() => invalidClock.markRead(request()), 'failed-precondition');
  assertNoMarkerWrites(invalidClock.firestore);

  const originalReadAt = new Date(Date.parse('2026-09-20T08:15:00.000Z'));
  const replay = fixture({
    records: [...baseRecords(), [MARKER_PATH, markerRecord({ readAt: originalReadAt })]],
    now: () => { throw new Error('clock unavailable'); },
  });
  const result = await replay.markRead(request());
  assert.deepEqual(result, { transferId: TRANSFER_ID, branchId: 'branch-south', read: true });
  assert.equal(replay.firestore.read(MARKER_PATH).readAt.getTime(), originalReadAt.getTime());
});
// --- Isolated callable harness ------------------------------------------------
// Mirrors sellerProfiles-callable.test.mjs: the entrypoint is loaded with
// virtual seam modules so no firebase-admin module is ever resolved, imported
// or initialized. Every callable Firestore operation lands in the in-memory
// fake below, so no test can reach any socket, runtime port or credential
// provider — the MetadataLookupWarning regression class is impossible here.
const SEAM_KEY = Symbol.for('lda.transfer-notices-callable.test');
const replacements = new Map([
  ['firebase-admin/app', ['getApps', 'initializeApp']],
  ['firebase-admin/firestore', ['getFirestore']],
  ['firebase-functions/v2/https', ['HttpsError', 'onCall']],
]);
let unauthorizedSdkImports = [];
let seamEvents = [];
let seamApps = [];
let seamFirestore = null;

class CallableHttpsError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'HttpsError';
    this.code = code;
    this.details = details;
  }
}

globalThis[SEAM_KEY] = {
  HttpsError: CallableHttpsError,
  onCall: (options, handler) => {
    seamEvents.push('register');
    return { options, handler };
  },
  getApps: () => {
    seamEvents.push('apps');
    return seamApps;
  },
  initializeApp: () => {
    seamEvents.push('initialize');
    const app = { name: `stubbed-admin-${seamApps.length}` };
    seamApps.push(app);
    return app;
  },
  getFirestore: () => {
    seamEvents.push('firestore');
    return seamFirestore;
  },
};
const sdkHooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (replacements.has(specifier)) return { url: `test-seam:${specifier}`, shortCircuit: true };
    if (specifier.startsWith('firebase-')) unauthorizedSdkImports.push(specifier);
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (!url.startsWith('test-seam:')) return nextLoad(url, context);
    const names = replacements.get(url.slice('test-seam:'.length)).join(', ');
    return {
      format: 'module',
      shortCircuit: true,
      source: `export const { ${names} } = globalThis[Symbol.for('lda.transfer-notices-callable.test')];`,
    };
  },
});
after(() => {
  sdkHooks.deregister();
  delete globalThis[SEAM_KEY];
});
const entry = await import('../src/index.js');

function resetCallableHarness(firestore = new MemoryFirestore(baseRecords())) {
  unauthorizedSdkImports = [];
  seamEvents = [];
  seamApps = [];
  seamFirestore = firestore;
  return firestore;
}

async function callableInvoke(callableRequest) {
  assert.equal(
    typeof entry.markTransferNoticeRead?.handler,
    'function',
    'markTransferNoticeRead must be registered',
  );
  return entry.markTransferNoticeRead.handler(callableRequest);
}

function rejectsCallable(promise, code, message) {
  return assert.rejects(promise, (error) => {
    assert.ok(error instanceof CallableHttpsError, `expected HttpsError, got ${error}`);
    assert.equal(error.code, code);
    if (message !== undefined) assert.equal(error.message, message);
    return true;
  });
}

test('the markTransferNoticeRead registration pins region and local-only origins', () => {
  assert.ok(entry.markTransferNoticeRead, 'markTransferNoticeRead must be registered');
  assert.equal(entry.markTransferNoticeRead.options.region, 'us-south1');
  assert.equal(entry.markTransferNoticeRead.options.cors, entry.LOCAL_WEB_ORIGINS);
  for (const origin of ['http://localhost', 'http://localhost:5000', 'https://127.0.0.1:7357']) {
    assert.ok(entry.LOCAL_WEB_ORIGINS.some((pattern) => pattern.test(origin)), `must allow ${origin}`);
  }
  for (const origin of ['https://example.com', 'http://localhost.example.com', 'http://127.0.0.2:5000']) {
    assert.ok(!entry.LOCAL_WEB_ORIGINS.some((pattern) => pattern.test(origin)), `must deny ${origin}`);
  }
});

test('every demo guard condition fails before any Admin SDK seam is touched', async () => {
  for (const environment of [
    CLOUD_ENVIRONMENT,
    { GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
    {},
  ]) {
    const firestore = resetCallableHarness();
    await withEnvironment(environment, async () => {
      await rejectsCallable(
        callableInvoke(request()),
        'failed-precondition',
        'transfer notices are restricted to the local demo emulator',
      );
    });
    assert.deepEqual(seamEvents, [], 'the guard must run before getApps, initializeApp or getFirestore');
    assert.deepEqual(firestore.traces, [], 'the guard must run before any document I/O');
    assert.deepEqual(unauthorizedSdkImports, []);
  }
});

test('the callable runs the real service against the injected in-memory double only', async () => {
  await withEnvironment(DEMO_ENVIRONMENT, async () => {
    const firestore = resetCallableHarness();

    const result = await callableInvoke(request());

    assert.deepEqual(result, { transferId: TRANSFER_ID, branchId: 'branch-south', read: true });
    const marker = firestore.read(MARKER_PATH);
    assert.deepEqual(
      { ...marker, readAt: undefined },
      { ...markerRecord(), readAt: undefined },
      'the marker fields are exactly the contract shape',
    );
    assert.ok(marker.readAt instanceof Date, 'readAt is a server-provided Date from the real callable clock');
    assert.deepEqual(seamEvents, ['apps', 'initialize', 'firestore']);
    assert.equal(seamApps.length, 1, 'the stubbed app initialization is the only one');
    assert.deepEqual(firestore.traces.at(-1).slice(0, 2), [
      ['get', `transfers/${TRANSFER_ID}`],
      ['get', MARKER_PATH],
    ]);
    assert.deepEqual(unauthorizedSdkImports, [], 'no firebase-admin module may ever be resolved');
  });
});

test('a callable replay preserves the stored marker without writing', async () => {
  await withEnvironment(DEMO_ENVIRONMENT, async () => {
    const originalReadAt = new Date(Date.parse('2026-09-20T08:15:00.000Z'));
    const firestore = resetCallableHarness(
      new MemoryFirestore([...baseRecords(), [MARKER_PATH, markerRecord({ readAt: originalReadAt })]]),
    );

    assert.deepEqual(
      await callableInvoke(request()),
      { transferId: TRANSFER_ID, branchId: 'branch-south', read: true },
    );
    assert.equal(firestore.read(MARKER_PATH).readAt.getTime(), originalReadAt.getTime());
    assert.deepEqual(
      firestore.traces.at(-1).filter(([kind]) => kind !== 'get'),
      [],
      'the replay must not write through the injected double',
    );
    assert.deepEqual(unauthorizedSdkImports, []);
  });
});

test('callable error mapping refuses bad identities and masks internal faults without Admin I/O', async () => {
  await withEnvironment(DEMO_ENVIRONMENT, async () => {
    const firestore = resetCallableHarness();

    await rejectsCallable(
      callableInvoke({ ...request(), auth: null }),
      'unauthenticated',
      'authentication is required',
    );
    assert.deepEqual(firestore.traces, [], 'an identity refusal must not touch any document');

    await rejectsCallable(callableInvoke(request({ transferId: '../escape' })), 'invalid-argument');
    assert.deepEqual(firestore.traces, [], 'a payload refusal must not touch any document');

    await rejectsCallable(callableInvoke({
      auth: SELLER,
      get data() {
        throw new Error('private infrastructure detail');
      },
    }), 'internal', 'transfer notice acknowledgement is temporarily unavailable');
    assert.deepEqual(firestore.traces, [], 'an internal fault must not touch any document');

    assert.deepEqual(unauthorizedSdkImports, []);
  });
});

test('a missing or foreign destination transfer stays a neutral callable not-found', async () => {
  await withEnvironment(DEMO_ENVIRONMENT, async () => {
    const firestore = resetCallableHarness(
      new MemoryFirestore(baseRecords().filter(([path]) => path !== `transfers/${TRANSFER_ID}`)),
    );

    await rejectsCallable(callableInvoke(request()), 'not-found', NOT_FOUND_MESSAGE);
    assert.deepEqual(firestore.traces.at(-1), [['get', `transfers/${TRANSFER_ID}`]]);
    assert.deepEqual(
      firestore.paths(),
      baseRecords().map(([path]) => path).filter((path) => path !== `transfers/${TRANSFER_ID}`).sort(),
    );
    assert.deepEqual(unauthorizedSdkImports, []);
  });
});

test('the callable harness itself proves test isolation through mocks', async () => {
  // Final regression: across every callable invocation above, the resolve hook
  // must never have let a real firebase-admin module through, and every
  // Firestore touch must have landed in the injected in-memory double.
  assert.deepEqual(unauthorizedSdkImports, [], 'a real Admin SDK module was resolved');
  assert.equal(entry.markTransferNoticeRead.options.cors, entry.LOCAL_WEB_ORIGINS);
  assert.ok(seamApps.every((app) => String(app.name).startsWith('stubbed-admin-')));
});
