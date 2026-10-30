import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import test, { after } from 'node:test';

import * as sellerProfiles from '../src/sellerProfiles.js';

const GUARD_MESSAGE = 'seller profiles are restricted to the local demo emulator';
const UNAVAILABLE = 'seller profile update is temporarily unavailable';
const PROFILE_PATH = 'sellerProfiles/seller-1';
const SELLER_UID = 'seller-1';
const ADMIN = Object.freeze({ uid: 'admin-1', token: { role: 'administrator' } });
const SELLER_CLAIMS = Object.freeze({ role: 'seller', branchId: 'branch-north' });
const DEMO_ENV = Object.freeze({
  FUNCTIONS_EMULATOR: 'true',
  GCLOUD_PROJECT: 'demo-lda-inventory',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
});

let environment, events, io, apps, authUsers, documents, failure;
let forwarded, useRealService, transactionFailure;

let authModuleLoads = 0;

class HttpsError extends Error {
  constructor(code, message, details) { super(message); this.code = code; this.details = details; }
}

const safeResult = Object.freeze({ uid: SELLER_UID, replayed: false });

// Admin-shaped doubles. The fake factory proves wiring only; the real pure
// profile module above supplies guard, error and authorization truth.
const firestore = {
  doc: (path) => ({ path }),
  runTransaction: async (callback) => {
    if (transactionFailure !== null) throw transactionFailure;
    return callback({
      get: async ({ path }) => {
        io.push(`get:${path}`);
        const data = documents.get(path);
        return { exists: data !== undefined, data: () => data };
      },
      set: ({ path }, data) => {
        io.push(`set:${path}`);
        documents.set(path, structuredClone(data));
      },
    });
  },
};
const auth = {
  getUser: async (uid) => {
    io.push(`getUser:${uid}`);
    const user = authUsers.get(uid);
    if (user === undefined) {
      const error = new Error(`no such identity for ${uid}`);
      error.code = 'auth/user-not-found';
      throw error;
    }
    if (user instanceof Error) throw user;
    return user;
  },
};

const seams = {
  HttpsError,
  onAuthModuleLoad: () => { authModuleLoads += 1; },
  onCall: (options, handler) => ({ options, handler }),
  getApps: () => { events.push('apps'); return apps; },
  initializeApp: () => { events.push('initialize'); if (failure?.at === 'initialize') throw failure.error; },
  getFirestore: () => { events.push('firestore'); if (failure?.at === 'firestore') throw failure.error; return firestore; },
  getAuth: () => { events.push('auth'); if (failure?.at === 'auth') throw failure.error; return auth; },
  SellerProfileError: sellerProfiles.SellerProfileError,
  assertLocalSellerProfilesEmulator: () => {
    events.push('guard');
    sellerProfiles.assertLocalSellerProfilesEmulator(environment);
  },
  createSellerProfileService: (options) => {
    events.push('factory');
    assert.equal(options.firestore, firestore, 'callable must inject Admin Firestore');
    assert.equal(options.auth, auth, 'callable must inject Admin Auth');
    assert.deepEqual(Object.keys(options).sort(), ['auth', 'firestore']);
    if (failure?.at === 'factory') throw failure.error;
    return async (request) => {
      events.push('setter');
      forwarded = request;
      if (failure?.at === 'setter') throw failure.error;
      return useRealService
        ? sellerProfiles.createSellerProfileService({ ...options, environment })(request)
        : safeResult;
    };
  },
};

// Load the real entrypoint with virtual dependency modules. No SDK is imported;
// the real pure profile module above supplies guard, error and auth logic.
// The entrypoint imports firebase-admin/auth lazily, after the guard, so the
// hooks stay registered until every test has run.
const key = Symbol.for('lda.seller-profiles-callable.test');
globalThis[key] = seams;
const replacements = new Map([
  ['firebase-admin/app', ['getApps', 'initializeApp']],
  ['firebase-admin/firestore', ['getFirestore']],
  ['firebase-admin/auth', ['getAuth']],
  ['firebase-functions/v2/https', ['HttpsError', 'onCall']],
  ['./sellerProfiles.js', ['SellerProfileError', 'assertLocalSellerProfilesEmulator',
    'createSellerProfileService']],
]);
const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (replacements.has(specifier)
      && (specifier !== './sellerProfiles.js'
        || context.parentURL === new URL('../src/index.js', import.meta.url).href)) {
      return { url: `test-seam:${specifier}`, shortCircuit: true };
    }
    assert.ok(!specifier.startsWith('firebase-'), 'unexpected SDK import must not initialize Firebase');
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (!url.startsWith('test-seam:')) return nextLoad(url, context);
    const specifier = url.slice('test-seam:'.length);
    const names = replacements.get(specifier);
    const seam = "globalThis[Symbol.for('lda.seller-profiles-callable.test')]";
    const onLoad = specifier === 'firebase-admin/auth' ? `${seam}.onAuthModuleLoad();\n` : '';
    return { format: 'module', shortCircuit: true,
      source: `${onLoad}export const { ${names.join(', ')} } = ${seam};` };
  },
});
after(() => { hooks.deregister(); delete globalThis[key]; });
const entry = await import('../src/index.js');

function reset() {
  environment = { ...DEMO_ENV };
  events = [];
  io = [];
  apps = [];
  authUsers = new Map([[SELLER_UID, { uid: SELLER_UID, customClaims: SELLER_CLAIMS }]]);
  documents = new Map();
  failure = null;
  forwarded = null;
  useRealService = false;
  transactionFailure = null;
}
function invoke(request = {}) {
  assert.equal(typeof entry.setSellerProfile?.handler, 'function', 'setSellerProfile must be registered');
  return entry.setSellerProfile.handler(request);
}
const rejects = (promise, code, message) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof HttpsError);
  assert.equal(error.code, code);
  assert.equal(error.message, message);
  assert.equal(error.details, undefined);
  return true;
});
const request = (data = { uid: SELLER_UID, displayName: 'Ada Ruiz' }, authContext = ADMIN) => ({
  auth: authContext,
  data,
});

test('profile registration uses the existing region and local-only origins', () => {
  assert.ok(entry.setSellerProfile, 'setSellerProfile must be registered');
  assert.equal(entry.setSellerProfile.options.region, 'us-south1');
  assert.equal(entry.setSellerProfile.options.cors, entry.WEB_ORIGINS);
  for (const origin of ['http://localhost:5173', 'https://127.0.0.1:443']) {
    assert.ok(entry.setSellerProfile.options.cors.some((pattern) => pattern.test(origin)));
  }
  assert.ok(!entry.setSellerProfile.options.cors.some((pattern) => pattern.test('https://example.com')));
  assert.equal(entry.getSellerName, undefined, 'no name-lookup callable may be exported');
});

test('importing the entrypoint never loads the Admin Auth module', () => {
  assert.equal(authModuleLoads, 0);
});

test('every demo guard condition fails before SDK or service access', async () => {
  for (const [field, value] of [
    ['GCLOUD_PROJECT', 'production'], ['GCLOUD_PROJECT', undefined],
    ['FUNCTIONS_EMULATOR', 'false'], ['FUNCTIONS_EMULATOR', undefined],
    ['FIRESTORE_EMULATOR_HOST', ''], ['FIRESTORE_EMULATOR_HOST', undefined],
    ['FIREBASE_AUTH_EMULATOR_HOST', ''], ['FIREBASE_AUTH_EMULATOR_HOST', undefined],
  ]) {
    reset(); environment[field] = value;
    await rejects(invoke(), 'failed-precondition', GUARD_MESSAGE);
    assert.deepEqual(events, ['guard']);
    assert.deepEqual(io, []);
  }
  assert.equal(authModuleLoads, 0, 'a guard failure must not load the Admin Auth module');
});

test('real guard enforces the exact local host policy before any SDK call', async () => {
  for (const [field, value] of [
    ['FIRESTORE_EMULATOR_HOST', 'firestore.googleapis.com:443'],
    ['FIRESTORE_EMULATOR_HOST', 'localhost:8080'],
    ['FIRESTORE_EMULATOR_HOST', '[::1]:8080'],
    ['FIRESTORE_EMULATOR_HOST', '127.0.0.1:8081'],
    ['FIRESTORE_EMULATOR_HOST', 'http://127.0.0.1:8080'],
    ['FIRESTORE_EMULATOR_HOST', ' 127.0.0.1:8080'],
    ['FIRESTORE_EMULATOR_HOST', '0.0.0.0:8080'],
    ['FIREBASE_AUTH_EMULATOR_HOST', 'evil.example.com:9099'],
    ['FIREBASE_AUTH_EMULATOR_HOST', 'localhost:9099'],
    ['FIREBASE_AUTH_EMULATOR_HOST', '127.0.0.1:9098'],
    ['FIREBASE_AUTH_EMULATOR_HOST', 'http://127.0.0.1:9099'],
    ['GOOGLE_CLOUD_PROJECT', 'production'],
    ['FIREBASE_CONFIG', '{"projectId":"production"}'],
    ['FIREBASE_CONFIG', '/unread/config.json'],
  ]) {
    reset(); environment = { ...DEMO_ENV, [field]: value };
    await rejects(invoke(), 'failed-precondition', GUARD_MESSAGE);
    assert.deepEqual(events, ['guard']);
  }

  reset(); environment = { ...DEMO_ENV, GCLOUD_PROJECT: 'lda-software-production' };
  await rejects(invoke(), 'failed-precondition', GUARD_MESSAGE);
  assert.ok(!events.includes('apps'), 'guard must run before getApps');

  reset();
  environment = { ...DEMO_ENV, GOOGLE_CLOUD_PROJECT: 'demo-lda-inventory',
    FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory"}' };
  assert.equal(await invoke(), safeResult);
  assert.equal(events.at(-1), 'setter');
});

test('trusted request and replay-safe result pass through with lazy initialization', async () => {
  for (const existing of [[], [{}]]) {
    reset(); apps = existing;
    const call = request();
    assert.equal(await invoke(call), safeResult);
    assert.equal(forwarded, call, 'the callable must forward the request unchanged');
    assert.deepEqual(events, existing.length
      ? ['guard', 'apps', 'firestore', 'auth', 'factory', 'setter']
      : ['guard', 'apps', 'initialize', 'firestore', 'auth', 'factory', 'setter']);
    assert.equal(io.length, 0, 'the fake factory must not perform dependency I/O');
  }
});

test('authorized real service writes the profile from trusted claims only', async () => {
  reset(); useRealService = true;
  const result = await invoke(request({ uid: SELLER_UID, displayName: '  Ada Ruiz  ' }));
  assert.deepEqual(result, { uid: SELLER_UID, replayed: false });
  assert.deepEqual(documents.get(PROFILE_PATH), { displayName: 'Ada Ruiz', branchId: 'branch-north' });
  assert.deepEqual(io, [`getUser:${SELLER_UID}`, `get:${PROFILE_PATH}`, `set:${PROFILE_PATH}`]);

  reset(); useRealService = true;
  documents.set(PROFILE_PATH, { displayName: 'Ada Ruiz', branchId: 'branch-north' });
  assert.deepEqual(await invoke(request({ uid: SELLER_UID, displayName: 'Ada Ruiz' })),
    { uid: SELLER_UID, replayed: true });
  assert.deepEqual(io, [`getUser:${SELLER_UID}`, `get:${PROFILE_PATH}`], 'replay must not write');
});

test('real service gates anonymous and non-administrative callers without identity I/O', async () => {
  for (const [code, authContext] of [
    ['unauthenticated', null],
    ['unauthenticated', { token: { role: 'administrator' } }],
    ['unauthenticated', { uid: '', token: { role: 'administrator' } }],
    ['permission-denied', { uid: SELLER_UID, token: { role: 'seller' } }],
    ['permission-denied', { uid: 'admin-1', token: {} }],
  ]) {
    reset(); useRealService = true;
    await rejects(invoke(request({ uid: SELLER_UID, displayName: 'Ada Ruiz' }, authContext)),
      code, code === 'unauthenticated' ? 'authentication is required' : 'administrator role is required');
    assert.deepEqual(io, [], 'the caller gate must run before any Auth or Firestore I/O');
  }
});

test('real service rejects client authority and unknown targets before identity I/O', async () => {
  reset(); useRealService = true;
  await rejects(invoke(request({ uid: SELLER_UID, displayName: 'Ada Ruiz', branchId: 'branch-south' })),
    'invalid-argument', 'request contains missing or unsupported fields');
  assert.deepEqual(io, []);

  reset(); useRealService = true;
  authUsers = new Map();
  await rejects(invoke(request()), 'not-found', 'seller identity does not exist');
  assert.deepEqual(io, [`getUser:${SELLER_UID}`], 'a missing identity must not be written');
});

const rejectsWithReason = (promise, code, message, reason) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof HttpsError);
  assert.equal(error.code, code);
  assert.equal(error.message, message);
  assert.deepEqual(error.details, { reason });
  assert.deepEqual(Object.keys(error.details), ['reason']);
  return true;
});

test('the real service maps seller, branch and stored-profile preconditions to details.reason', async () => {
  for (const [claims, message, reason] of [
    [{ role: 'administrator' }, 'target user is not a seller', 'not-a-seller'],
    [undefined, 'target user is not a seller', 'not-a-seller'],
    [{ role: 'seller', branchId: 'north' }, 'seller branch claim is invalid', 'invalid-branch-claim'],
  ]) {
    reset(); useRealService = true;
    authUsers = new Map([[SELLER_UID, { uid: SELLER_UID, customClaims: claims }]]);
    await rejectsWithReason(invoke(request()), 'failed-precondition', message, reason);
    assert.deepEqual(io, [`getUser:${SELLER_UID}`], 'a rejected identity must not be written');
  }

  reset(); useRealService = true;
  const stored = { displayName: 'Ada Ruiz', branchId: 'branch-north', uid: SELLER_UID };
  documents.set(PROFILE_PATH, stored);
  await rejectsWithReason(invoke(request()), 'failed-precondition',
    'existing seller profile is invalid', 'invalid-stored-profile');
  assert.deepEqual(io, [`getUser:${SELLER_UID}`, `get:${PROFILE_PATH}`]);
  assert.equal(documents.get(PROFILE_PATH), stored, 'a malformed profile is never rewritten');
});

test('a SellerProfileError reason is forwarded alone; private fields never reach details', async () => {
  reset();
  const error = new sellerProfiles.SellerProfileError('failed-precondition', 'public', 'not-a-seller');
  error.details = 'private provenance';
  error.uid = 'private-uid';
  failure = { at: 'setter', error };
  await rejectsWithReason(invoke(), 'failed-precondition', 'public', 'not-a-seller');
});

test('known SellerProfileError codes and public messages are mapped without details', async () => {
  for (const code of ['unauthenticated', 'permission-denied', 'invalid-argument', 'not-found',
    'failed-precondition', 'internal']) {
    reset();
    const error = new sellerProfiles.SellerProfileError(code, 'public profile failure');
    error.details = 'private provenance';
    failure = { at: 'setter', error };
    await rejects(invoke(), code, 'public profile failure');
  }
});

test('unknown initialization, dependency, factory and setter errors are sanitized', async () => {
  for (const at of ['initialize', 'firestore', 'auth', 'factory', 'setter']) {
    reset(); failure = { at, error: new Error('private infrastructure diagnostic') };
    await rejects(invoke(), 'internal', UNAVAILABLE);
  }

  reset();
  failure = { at: 'setter', error: { code: 'permission-denied', message: 'private diagnostic' } };
  await rejects(invoke(), 'internal', UNAVAILABLE);

  reset(); useRealService = true;
  transactionFailure = new Error('transaction aborted with credential secret=private');
  await rejects(invoke(request()), 'internal', UNAVAILABLE);

  reset(); useRealService = true;
  authUsers = new Map([[SELLER_UID, Object.assign(
    new Error('transport token=secret-value'), { code: 'auth/internal-error' })]]);
  await rejects(invoke(request()), 'internal', 'seller identity lookup failed');
  await assert.rejects(invoke(request()), (error) => {
    assert.ok(!error.message.includes('token=secret-value'));
    assert.ok(!error.message.includes('auth/internal-error'));
    return true;
  });
});
