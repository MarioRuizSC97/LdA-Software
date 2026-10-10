import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  SellerProfileError,
  assertLocalSellerProfilesEmulator,
  createSellerProfileService,
} from '../src/sellerProfiles.js';

const ADMIN = { uid: 'admin-1', token: { role: 'administrator' } };
const SELLER_UID = 'seller-1';
const SELLER_NAME = 'Ada Ruiz';
const PROFILE_PATH = `sellerProfiles/${SELLER_UID}`;
const DEMO_ENV = Object.freeze({
  FUNCTIONS_EMULATOR: 'true',
  GCLOUD_PROJECT: 'demo-lda-inventory',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
});

/** In-memory Firestore double that stages transaction writes and spies on I/O. */
class MemoryFirestore {
  #documents = new Map();
  #queue = Promise.resolve();

  calls = { doc: [], runTransaction: 0, get: [], set: [] };
  setFailure = null;
  transactionFailure = null;

  doc(path) {
    this.calls.doc.push(path);
    return { path };
  }

  seed(path, data) {
    this.#documents.set(path, structuredClone(data));
  }

  read(path) {
    const data = this.#documents.get(path);
    return data === undefined ? undefined : structuredClone(data);
  }

  async runTransaction(callback) {
    this.calls.runTransaction += 1;
    if (this.transactionFailure !== null) {
      throw this.transactionFailure;
    }

    const previous = this.#queue;
    let release;
    this.#queue = new Promise((resolve) => {
      release = resolve;
    });
    await previous;

    const pending = new Map();
    // Only get and set are provided: an accidental create/update is a hard
    // TypeError, proving the service writes through one exact set path.
    const transaction = {
      get: async ({ path }) => {
        this.calls.get.push(path);
        const data = pending.has(path) ? pending.get(path) : this.#documents.get(path);
        return { exists: data !== undefined, data: () => structuredClone(data) };
      },
      set: ({ path }, data) => {
        if (this.setFailure !== null) {
          throw this.setFailure;
        }
        this.calls.set.push({ path, data: structuredClone(data) });
        pending.set(path, structuredClone(data));
      },
    };

    try {
      const result = await callback(transaction);
      for (const [path, data] of pending) this.#documents.set(path, data);
      return result;
    } finally {
      release();
    }
  }
}

function authError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

/** Trusted Admin Auth double. Every mutator is armed to fail the test. */
class TrustedAuthStub {
  #users;

  calls = { getUser: [], mutators: [] };
  beforeGetUser = null;

  constructor(users = []) {
    this.#users = new Map(users);
  }

  async getUser(uid) {
    this.calls.getUser.push(uid);
    if (this.beforeGetUser !== null) {
      await this.beforeGetUser(uid);
    }
    const entry = this.#users.get(uid);
    if (entry === undefined) {
      throw authError('auth/user-not-found', `no such identity for ${uid}`);
    }
    if (entry instanceof Error) {
      throw entry;
    }
    return entry;
  }

  createUser(plan) {
    this.calls.mutators.push(`createUser:${JSON.stringify(plan ?? null)}`);
    throw new Error('seller profiles must never create Auth users');
  }

  updateUser(plan) {
    this.calls.mutators.push(`updateUser:${JSON.stringify(plan ?? null)}`);
    throw new Error('seller profiles must never update Auth users');
  }

  setUserDisabled(uid, disabled) {
    this.calls.mutators.push(`setUserDisabled:${String(uid)}=${String(disabled)}`);
    throw new Error('seller profiles must never re-enable or disable Auth users');
  }

  deleteUser(uid) {
    this.calls.mutators.push(`deleteUser:${String(uid)}`);
    throw new Error('seller profiles must never delete Auth users');
  }

  setCustomClaims(uid, claims) {
    this.calls.mutators.push(`setCustomClaims:${String(uid)}`);
    throw new Error('seller profiles must never change Auth claims');
  }
}

function sellerClaims(overrides = {}) {
  return { role: 'seller', branchId: 'branch-north', ...overrides };
}

function request({ data, auth = ADMIN } = {}) {
  return {
    auth,
    data: data === undefined ? { uid: SELLER_UID, displayName: SELLER_NAME } : data,
  };
}

function setup({ users, profile, beforeGetUser, environment = DEMO_ENV } = {}) {
  const firestore = new MemoryFirestore();
  if (profile !== undefined) {
    firestore.seed(PROFILE_PATH, profile);
  }
  const auth = new TrustedAuthStub(
    users ?? [[SELLER_UID, { uid: SELLER_UID, customClaims: sellerClaims() }]],
  );
  if (beforeGetUser !== undefined) {
    auth.beforeGetUser = beforeGetUser;
  }
  return {
    auth,
    firestore,
    setProfile: createSellerProfileService({ firestore, auth, environment }),
  };
}

async function rejectsCode(operation, code, reason) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof SellerProfileError);
    assert.equal(error.code, code);
    assert.equal(error.reason, reason);
    return true;
  });
}

test('rejects unauthenticated and non-administrative callers before any dependency I/O', async () => {
  const { auth, firestore, setProfile } = setup();

  await rejectsCode(() => setProfile({ auth: null, data: {} }), 'unauthenticated');
  await rejectsCode(
    () => setProfile({ auth: { token: { role: 'administrator' } }, data: {} }),
    'unauthenticated',
  );
  await rejectsCode(
    () => setProfile({ auth: { uid: '', token: { role: 'administrator' } }, data: {} }),
    'unauthenticated',
  );
  await rejectsCode(
    () => setProfile({ auth: { uid: 'seller-1', token: { role: 'seller' } }, data: {} }),
    'permission-denied',
  );
  await rejectsCode(
    () => setProfile({ auth: { uid: 'admin-1', token: {} }, data: {} }),
    'permission-denied',
  );

  assert.deepEqual(auth.calls.getUser, []);
  assert.deepEqual(firestore.calls.doc, []);
  assert.equal(firestore.calls.runTransaction, 0);
});

test('accepts exactly the uid and displayName request fields', async () => {
  const { auth, firestore, setProfile } = setup();
  const base = { uid: SELLER_UID, displayName: SELLER_NAME };
  const rejected = [
    null,
    undefined,
    [],
    'seller-1',
    42,
    {},
    { uid: SELLER_UID },
    { displayName: SELLER_NAME },
    { ...base, branchId: 'branch-north' },
    { ...base, role: 'seller' },
    { ...base, idempotencyKey: 'k-1' },
    { ...base, enabled: false },
  ];

  for (const data of rejected) {
    await rejectsCode(() => setProfile({ auth: ADMIN, data }), 'invalid-argument');
  }

  assert.deepEqual(auth.calls.getUser, []);
  assert.equal(firestore.calls.runTransaction, 0);
});

test('validates the target uid as an exact path-safe identifier without trimming', async () => {
  const accepted = ['a', '123', '_private_key', 'dash-name', 'übör-lambδα-1', 'u'.repeat(128)];
  const rejected = [
    '',
    'u'.repeat(129),
    'a/b',
    'a\\b',
    '.',
    '..',
    '__proto__',
    '__reserved__',
    'a\u0000b',
    'a\u001Fb',
    'a\u007Fb',
    42,
    null,
    undefined,
  ];
  const { auth, firestore, setProfile } = setup();

  for (const uid of accepted) {
    // Validation passes, so the flow reaches the trusted Auth lookup,
    // which reports the missing demo identity instead of a client error.
    await rejectsCode(
      () => setProfile({ auth: ADMIN, data: { uid, displayName: SELLER_NAME } }),
      'not-found',
    );
  }
  assert.deepEqual(auth.calls.getUser, accepted);

  for (const uid of rejected) {
    await rejectsCode(
      () => setProfile({ auth: ADMIN, data: { uid, displayName: SELLER_NAME } }),
      'invalid-argument',
    );
  }
  assert.equal(auth.calls.getUser.length, accepted.length);
  assert.equal(firestore.calls.runTransaction, 0);
});

test('rejects malformed display names before any dependency I/O', async () => {
  const { auth, firestore, setProfile } = setup();
  const rejected = [
    '',
    '   ',
    '\u0000',
    'Ada \u0000Ruiz',
    'Ada \u007FRuiz',
    'x'.repeat(121),
    `  ${'x'.repeat(123)}  `,
    42,
    null,
    true,
    { name: SELLER_NAME },
  ];

  for (const displayName of rejected) {
    await rejectsCode(
      () => setProfile({ auth: ADMIN, data: { uid: SELLER_UID, displayName } }),
      'invalid-argument',
    );
  }

  assert.deepEqual(auth.calls.getUser, []);
  assert.equal(firestore.calls.runTransaction, 0);
});

test('stores the trimmed international display name', async () => {
  const { firestore, setProfile } = setup();
  const trimmed = 'José Ñu 检查 ✓';

  const result = await setProfile({
    auth: ADMIN,
    data: { uid: SELLER_UID, displayName: `  ${trimmed}  ` },
  });

  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(firestore.read(PROFILE_PATH), {
    displayName: trimmed,
    branchId: 'branch-north',
  });
});

test('captures request and authority before the deferred Auth lookup', async () => {
  const data = { uid: SELLER_UID, displayName: SELLER_NAME };
  const callerAuth = { uid: 'admin-1', token: { role: 'administrator' } };
  const { auth, firestore, setProfile } = setup({
    beforeGetUser: async () => {
      data.uid = 'victim-2';
      data.displayName = 'Hijacked';
      data.branchId = 'branch-evil';
      callerAuth.uid = 'anonymous';
      callerAuth.token = { role: 'seller', branchId: 'branch-evil' };
    },
  });

  const result = await setProfile({ auth: callerAuth, data });

  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(auth.calls.getUser, [SELLER_UID]);
  assert.deepEqual(firestore.calls.doc, [PROFILE_PATH]);
  assert.deepEqual(firestore.read(PROFILE_PATH), {
    displayName: SELLER_NAME,
    branchId: 'branch-north',
  });
});

test('fails before any Firestore write when the trusted identity boundary rejects', async () => {
  const cases = [
    ['not-found', []],
    ['not-found', [[SELLER_UID, null]]],
    ['internal', [[SELLER_UID, { uid: 'other-uid', customClaims: sellerClaims() }]]],
    ['failed-precondition', [
      [SELLER_UID, { uid: SELLER_UID, customClaims: { role: 'administrator' } }],
    ], 'not-a-seller'],
    ['failed-precondition', [[SELLER_UID, { uid: SELLER_UID }]], 'not-a-seller'],
    ['failed-precondition', [[SELLER_UID, { uid: SELLER_UID, customClaims: { role: 'seller' } }]],
      'invalid-branch-claim'],
  ];

  for (const [code, users, reason] of cases) {
    const { firestore, setProfile } = setup({ users });
    await rejectsCode(() => setProfile(request()), code, reason);
    assert.equal(firestore.calls.runTransaction, 0);
  }

  const badBranches = ['branch-', 'branch-NORTH', 'branch-a_b', 'branch-a--b', 'branch-a-',
    'north-1', ' branch-a', 'branch-north ', 5, null];
  for (const branchId of badBranches) {
    const { firestore, setProfile } = setup({
      users: [[SELLER_UID, { uid: SELLER_UID, customClaims: sellerClaims({ branchId }) }]],
    });
    await rejectsCode(() => setProfile(request()), 'failed-precondition', 'invalid-branch-claim');
    assert.equal(firestore.calls.runTransaction, 0);
  }
});

test('maps Auth backend failures to a generic internal error without leaking SDK details', async () => {
  const { firestore, setProfile } = setup({
    users: [[SELLER_UID, authError('auth/internal-error', 'transport token=secret-value')]],
  });

  await rejectsCode(() => setProfile(request()), 'internal');
  await assert.rejects(() => setProfile(request()), (error) => {
    assert.ok(!error.message.includes('token=secret-value'));
    assert.ok(!error.message.includes('auth/internal-error'));
    return true;
  });
  assert.equal(firestore.calls.runTransaction, 0);
});

test('accepts a disabled seller without touching Auth mutators', async () => {
  const { auth, firestore, setProfile } = setup({
    users: [[SELLER_UID, { uid: SELLER_UID, disabled: true, customClaims: sellerClaims() }]],
  });

  const result = await setProfile(request());

  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(auth.calls.mutators, []);
  assert.deepEqual(auth.calls.getUser, [SELLER_UID]);
  assert.deepEqual(firestore.read(PROFILE_PATH), {
    displayName: SELLER_NAME,
    branchId: 'branch-north',
  });
});

test('creates the profile with exactly the two closed fields', async () => {
  const { auth, firestore, setProfile } = setup();

  const result = await setProfile(request());

  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.equal(firestore.calls.set.length, 1);
  assert.equal(firestore.calls.set[0].path, PROFILE_PATH);
  assert.deepEqual(firestore.calls.set[0].data, {
    displayName: SELLER_NAME,
    branchId: 'branch-north',
  });
  assert.deepEqual(Object.keys(firestore.read(PROFILE_PATH)).sort(), ['branchId', 'displayName']);
  assert.deepEqual(auth.calls.mutators, []);
});

test('updates changed content and refreshes the branch from trusted claims', async () => {
  const { firestore, setProfile } = setup({
    profile: { displayName: 'Old Name', branchId: 'branch-south' },
  });

  const result = await setProfile(request());

  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(firestore.read(PROFILE_PATH), {
    displayName: SELLER_NAME,
    branchId: 'branch-north',
  });

  // Same authorized name with a changed trusted claim still refreshes branchId.
  const branchOnly = setup({ profile: { displayName: SELLER_NAME, branchId: 'branch-south' } });
  const refreshed = await branchOnly.setProfile(request());
  assert.deepEqual(refreshed, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(branchOnly.firestore.read(PROFILE_PATH), {
    displayName: SELLER_NAME,
    branchId: 'branch-north',
  });
});

test('replays identical stored content without any write', async () => {
  const stored = { displayName: SELLER_NAME, branchId: 'branch-north' };
  const { firestore, setProfile } = setup({ profile: stored });

  const result = await setProfile(request());

  assert.deepEqual(result, { uid: SELLER_UID, replayed: true });
  assert.equal(firestore.calls.get.length, 1);
  assert.equal(firestore.calls.get[0], PROFILE_PATH);
  assert.deepEqual(firestore.calls.set, []);
  assert.deepEqual(firestore.read(PROFILE_PATH), stored);
});

test('fails closed on malformed or extended stored profiles without rewriting them', async () => {
  const storedCases = [
    { displayName: SELLER_NAME, branchId: 'branch-north', uid: SELLER_UID },
    { displayName: SELLER_NAME, branchId: 'branch-north', updatedAt: 'now' },
    { displayName: SELLER_NAME },
    { branchId: 'branch-north' },
    { displayName: 42, branchId: 'branch-north' },
    { displayName: '  padded ', branchId: 'branch-north' },
    { displayName: SELLER_NAME, branchId: 'branch-NORTH' },
    'not-an-object',
    null,
  ];

  for (const profile of storedCases) {
    const { firestore, setProfile } = setup({ profile });
    await rejectsCode(() => setProfile(request()), 'failed-precondition', 'invalid-stored-profile');
    assert.deepEqual(firestore.calls.set, []);
    assert.deepEqual(firestore.read(PROFILE_PATH), profile);
  }
});

test('rejects Firestore transaction failures instead of reporting success', async () => {
  const aborted = new Error('transaction aborted by Firestore');
  const { firestore, setProfile } = setup();
  firestore.transactionFailure = aborted;
  await assert.rejects(() => setProfile(request()), (error) => error === aborted);

  const writeFailure = new Error('staged write failed');
  const second = setup();
  second.firestore.setFailure = writeFailure;
  await assert.rejects(() => second.setProfile(request()), (error) => error === writeFailure);
  assert.equal(second.firestore.calls.runTransaction, 1);
  assert.equal(second.firestore.read(PROFILE_PATH), undefined);
});

test('requires capability-compatible injected dependencies', () => {
  assert.throws(() => createSellerProfileService(), TypeError);
  assert.throws(
    () => createSellerProfileService({ firestore: {}, auth: { getUser: () => {} } }),
    TypeError,
  );
  assert.throws(
    () => createSellerProfileService({ firestore: { doc() {}, runTransaction() {} } }),
    TypeError,
  );
  assert.throws(
    () => createSellerProfileService({ firestore: { doc() {}, runTransaction() {} }, auth: {} }),
    TypeError,
  );
});

test('error reasons are kebab-case machine tokens only', () => {
  assert.equal(new SellerProfileError('not-found', 'missing').reason, undefined);
  assert.equal(new SellerProfileError('failed-precondition', 'x', 'not-a-seller').reason, 'not-a-seller');
  for (const reason of ['', 'Not-A-Seller', 'not_a_seller', 'not a seller', '-x', 'x-', 42, null]) {
    assert.throws(() => new SellerProfileError('failed-precondition', 'x', reason), TypeError);
  }
});

function emulatorEnv(overrides = {}) {
  return { ...DEMO_ENV, ...overrides };
}

function isGuardRejection(error) {
  assert.ok(error instanceof SellerProfileError);
  assert.equal(error.code, 'failed-precondition');
  assert.equal(error.reason, undefined);
  // One constant message: no rejected environment value is ever echoed.
  for (const leaked of ['evil.example.com', 'production', '8081', '9098', 'localhost', '/unread']) {
    assert.ok(!error.message.includes(leaked));
  }
  return true;
}

test('accepts only the pinned demo project on exact 127.0.0.1 Firestore and Auth hosts', () => {
  assert.doesNotThrow(() => assertLocalSellerProfilesEmulator(emulatorEnv()));
  // Optional Admin project sources may agree with, never override, the demo ID.
  assert.doesNotThrow(() => assertLocalSellerProfilesEmulator(emulatorEnv({
    GOOGLE_CLOUD_PROJECT: 'demo-lda-inventory',
    FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory"}',
    UNRELATED_VARIABLE: 'whatever',
  })));
});

test('rejects every missing, remote, or misconfigured emulator environment', () => {
  const rejected = [
    {},
    undefined,
    null,
    emulatorEnv({ FUNCTIONS_EMULATOR: undefined }),
    emulatorEnv({ FUNCTIONS_EMULATOR: '1' }),
    emulatorEnv({ FUNCTIONS_EMULATOR: 'false' }),
    emulatorEnv({ GCLOUD_PROJECT: undefined }),
    emulatorEnv({ GCLOUD_PROJECT: 'lda-software-production' }),
    emulatorEnv({ GCLOUD_PROJECT: 'demo-lda-inventory ' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: undefined }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: '' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: 'localhost:8080' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: '[::1]:8080' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: '127.0.0.1:8081' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: 'http://127.0.0.1:8080' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: ' 127.0.0.1:8080' }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: undefined }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: '' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: 'localhost:9099' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: '[::1]:9099' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9098' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: 'http://127.0.0.1:9099' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099 ' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: 'evil.example.com:9099' }),
    emulatorEnv({ GOOGLE_CLOUD_PROJECT: 'production' }),
    emulatorEnv({ GOOGLE_CLOUD_PROJECT: '' }),
    emulatorEnv({ FIREBASE_CONFIG: '{"projectId":"production"}' }),
    emulatorEnv({ FIREBASE_CONFIG: '{' }),
    emulatorEnv({ FIREBASE_CONFIG: '/unread/config.json' }),
    emulatorEnv({ FIREBASE_CONFIG: '[]' }),
    emulatorEnv({ FIREBASE_CONFIG: 'null' }),
    emulatorEnv({ FIREBASE_CONFIG: { projectId: 'demo-lda-inventory' } }),
  ];

  for (const environment of rejected) {
    assert.throws(() => assertLocalSellerProfilesEmulator(environment), isGuardRejection);
  }
});

test('the service runs the injected guard before authorization and any dependency I/O', async () => {
  for (const environment of [
    emulatorEnv({ GCLOUD_PROJECT: 'lda-software-production' }),
    emulatorEnv({ FIREBASE_AUTH_EMULATOR_HOST: undefined }),
    emulatorEnv({ FIRESTORE_EMULATOR_HOST: 'localhost:8080' }),
  ]) {
    const { auth, firestore, setProfile } = setup({ environment });
    await assert.rejects(() => setProfile(request()), isGuardRejection);
    // An anonymous caller still sees the guard, never the role gate.
    await assert.rejects(() => setProfile(request({ auth: null })), isGuardRejection);
    assert.deepEqual(auth.calls.getUser, []);
    assert.deepEqual(firestore.calls.doc, []);
    assert.equal(firestore.calls.runTransaction, 0);
  }
});
