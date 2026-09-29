import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEMO_ACCOUNTS,
  buildDemoSeed,
  formatProvisioningReport,
  loadEmulatorAdmin,
  provisionDemo,
  provisionDemoWithServices,
  validateEmulatorEnvironment,
} from '../scripts/provision-demo-identities.mjs';

const VALID_ENV = {
  GCLOUD_PROJECT: 'demo-lda-inventory',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  FIREBASE_AUTH_EMULATOR_HOST: 'localhost:9099',
};

function missingUserError() {
  return Object.assign(new Error('missing user'), { code: 'auth/user-not-found' });
}

class MemoryAuth {
  constructor(users = [], { failClaimsOnce = false } = {}) {
    this.usersByUid = new Map(users.map((user) => [user.uid, structuredClone(user)]));
    this.createCalls = [];
    this.claimCalls = [];
    this.updateCalls = [];
    this.deleteCalls = [];
    this.failClaimsOnce = failClaimsOnce;
  }

  async getUser(uid) {
    const user = this.usersByUid.get(uid);
    if (!user) throw missingUserError();
    return structuredClone(user);
  }

  async getUserByEmail(email) {
    const user = [...this.usersByUid.values()].find((candidate) => candidate.email === email);
    if (!user) throw missingUserError();
    return structuredClone(user);
  }

  async createUser(input) {
    if (this.usersByUid.has(input.uid)) {
      throw Object.assign(new Error('uid exists'), { code: 'auth/uid-already-exists' });
    }
    if ([...this.usersByUid.values()].some((user) => user.email === input.email)) {
      throw Object.assign(new Error('email exists'), { code: 'auth/email-already-exists' });
    }
    this.createCalls.push(structuredClone(input));
    const user = { ...input, customClaims: {} };
    this.usersByUid.set(input.uid, user);
    return structuredClone(user);
  }

  async setCustomUserClaims(uid, claims) {
    this.claimCalls.push({ uid, claims: structuredClone(claims) });
    if (this.failClaimsOnce) {
      this.failClaimsOnce = false;
      throw new Error('injected claims failure');
    }
    this.usersByUid.get(uid).customClaims = structuredClone(claims);
  }

  async updateUser(uid, input) {
    this.updateCalls.push({ uid, input: structuredClone(input) });
    Object.assign(this.usersByUid.get(uid), input);
    return structuredClone(this.usersByUid.get(uid));
  }

  async deleteUser(uid) {
    this.deleteCalls.push(uid);
    this.usersByUid.delete(uid);
  }
}

class MemoryFirestore {
  constructor(records = {}) {
    this.records = new Map(
      Object.entries(records).map(([path, value]) => [path, structuredClone(value)]),
    );
    this.createCalls = [];
  }

  doc(path) {
    return { path };
  }

  async getAll(...references) {
    return references.map(({ path }) => ({
      exists: this.records.has(path),
      data: () => structuredClone(this.records.get(path)),
      ref: { path },
    }));
  }

  batch() {
    const creates = [];
    return {
      create: (reference, value) => creates.push([reference.path, structuredClone(value)]),
      commit: async () => {
        for (const [path] of creates) {
          if (this.records.has(path)) throw new Error(`already exists: ${path}`);
        }
        for (const [path, value] of creates) {
          this.createCalls.push(path);
          this.records.set(path, value);
        }
      },
    };
  }
}

function expectedUsers() {
  return DEMO_ACCOUNTS.map(({ password, claims, ...identity }) => ({
    ...identity,
    password,
    customClaims: structuredClone(claims),
  }));
}

test('environment guard rejects any non-demo project or missing/non-loopback emulator host before Admin loads', async () => {
  const invalidEnvironments = [
    { ...VALID_ENV, GCLOUD_PROJECT: 'real-project' },
    { ...VALID_ENV, FIRESTORE_EMULATOR_HOST: undefined },
    { ...VALID_ENV, FIREBASE_AUTH_EMULATOR_HOST: '' },
    { ...VALID_ENV, FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' },
    { ...VALID_ENV, FIREBASE_AUTH_EMULATOR_HOST: 'http://127.0.0.1:9099' },
    { ...VALID_ENV, FIRESTORE_EMULATOR_HOST: '127.0.0.1:70000' },
  ];

  for (const env of invalidEnvironments) {
    let adminLoaded = false;
    await assert.rejects(
      () => provisionDemo({
        env,
        loadAdmin: async () => {
          adminLoaded = true;
          throw new Error('must not load');
        },
      }),
      /refusing to provision/i,
    );
    assert.equal(adminLoaded, false);
  }

  assert.deepEqual(validateEmulatorEnvironment(VALID_ENV), {
    projectId: 'demo-lda-inventory',
    firestoreHost: '127.0.0.1:8080',
    authHost: 'localhost:9099',
  });
});

test('Admin boundary rejects injected configuration that differs from validated process environment', async () => {
  let modulesLoaded = false;
  await assert.rejects(
    () => loadEmulatorAdmin(
      validateEmulatorEnvironment(VALID_ENV),
      {
        env: { ...VALID_ENV, FIRESTORE_EMULATOR_HOST: 'localhost:8081' },
        loadModules: async () => {
          modulesLoaded = true;
          throw new Error('must not load Admin modules');
        },
      },
    ),
    /refusing to provision.*configuration/i,
  );
  assert.equal(modulesLoaded, false);
});

test('Admin boundary fails closed when the real process environment drifts while modules load', async () => {
  const names = [
    'GCLOUD_PROJECT',
    'FIRESTORE_EMULATOR_HOST',
    'FIREBASE_AUTH_EMULATOR_HOST',
  ];
  const original = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  Object.assign(process.env, VALID_ENV);
  let initialized = false;

  try {
    await assert.rejects(
      () => loadEmulatorAdmin(
        validateEmulatorEnvironment(process.env),
        {
          loadModules: async () => {
            await Promise.resolve();
            process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8081';
            return [
              {
                cert: () => ({}),
                initializeApp: () => {
                  initialized = true;
                  return {};
                },
                deleteApp: async () => {},
              },
              { getAuth: () => ({}) },
              { getFirestore: () => ({}) },
            ];
          },
        },
      ),
      /refusing to provision.*environment.*changed/i,
    );
    assert.equal(initialized, false);
  } finally {
    for (const name of names) {
      if (original[name] === undefined) delete process.env[name];
      else process.env[name] = original[name];
    }
  }
});

test('seed manifest is deterministic, seller-safe, and includes assigned-branch zero stock', () => {
  const first = buildDemoSeed();
  const second = buildDemoSeed();
  assert.deepEqual(first, second);

  const productEntries = first.filter(({ path }) => path.startsWith('products/'));
  const northStock = first.filter(({ path }) => path.startsWith('branches/branch-north/stock/'));
  assert.equal(productEntries.length, 2);
  assert.equal(northStock.length, productEntries.length);
  assert.ok(northStock.some(({ data }) => data.quantityScaled === 0));

  for (const { data } of productEntries) {
    const serialized = JSON.stringify(data);
    assert.doesNotMatch(serialized, /cost|createdBy|pricingUpdatedBy/i);
    assert.equal(data.pricing.currency, 'MXN');
  }
  assert.ok(first.some(({ path }) => path === 'branches/branch-north'));
  assert.ok(first.some(({ path }) => path === 'branches/branch-south'));
});

test('provisioning creates deterministic local identities and records once without touching unrelated state', async () => {
  const auth = new MemoryAuth();
  const firestore = new MemoryFirestore({
    'unrelated/keep': { owner: 'user', value: 42 },
  });

  const first = await provisionDemoWithServices({ auth, firestore });
  assert.equal(first.accountsCreated, 2);
  assert.equal(first.recordsCreated, buildDemoSeed().length);
  assert.equal(firestore.records.get('unrelated/keep').value, 42);
  assert.deepEqual(
    [...auth.usersByUid.values()].map(({ password, ...user }) => user),
    expectedUsers().map(({ password, ...user }) => user),
  );
  assert.ok(auth.createCalls.every(({ email }) => email.endsWith('.invalid')));

  const second = await provisionDemoWithServices({ auth, firestore });
  assert.equal(second.accountsCreated, 0);
  assert.equal(second.recordsCreated, 0);
  assert.ok(second.accountResults.every(({ status }) => status === 'reused'));
  assert.equal(auth.createCalls.length, 2);
  assert.equal(firestore.createCalls.length, buildDemoSeed().length);
});

test('report exposes fake credentials only for newly created identities', async () => {
  const created = await provisionDemoWithServices({
    auth: new MemoryAuth(),
    firestore: new MemoryFirestore(),
  });
  const createdReport = formatProvisioningReport(created);
  for (const account of DEMO_ACCOUNTS) {
    assert.match(createdReport, new RegExp(account.password.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  const reused = await provisionDemoWithServices({
    auth: new MemoryAuth(expectedUsers()),
    firestore: new MemoryFirestore(Object.fromEntries(
      buildDemoSeed().map(({ path, data }) => [path, data]),
    )),
  });
  const reusedReport = formatProvisioningReport(reused);
  for (const account of DEMO_ACCOUNTS) {
    assert.doesNotMatch(reusedReport, new RegExp(account.password.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(reusedReport, /password not verified; manual sign-in verification required/i);
  assert.doesNotMatch(reusedReport, /role|claims/i);
});

test('concurrent seed attempts converge without taking over either deterministic identity', async () => {
  const auth = new MemoryAuth();
  const firestore = new MemoryFirestore();

  const results = await Promise.all([
    provisionDemoWithServices({ auth, firestore }),
    provisionDemoWithServices({ auth, firestore }),
  ]);

  assert.equal(results.reduce((sum, result) => sum + result.accountsCreated, 0), 2);
  assert.equal(
    results.reduce((sum, result) => sum + result.recordsCreated, 0),
    buildDemoSeed().length,
  );
  assert.deepEqual(
    [...auth.usersByUid.values()].map(({ password, ...user }) => user),
    expectedUsers().map(({ password, ...user }) => user),
  );
});

test('a claims failure removes only the identity created by that attempt so retry is safe', async () => {
  const auth = new MemoryAuth([], { failClaimsOnce: true });
  const firestore = new MemoryFirestore();

  await assert.rejects(
    () => provisionDemoWithServices({ auth, firestore }),
    /injected claims failure/,
  );
  assert.deepEqual(auth.deleteCalls, [DEMO_ACCOUNTS[0].uid]);
  assert.equal(auth.usersByUid.has(DEMO_ACCOUNTS[0].uid), false);
  assert.equal(firestore.createCalls.length, 0);

  const retry = await provisionDemoWithServices({ auth, firestore });
  assert.equal(retry.accountsCreated, DEMO_ACCOUNTS.length);
  assert.equal(retry.recordsCreated, buildDemoSeed().length);
  assert.ok(retry.accountResults.every(({ status }) => status === 'created'));
});

test('conflicting email, uid, claims, or Firestore shape fails closed before any write', async () => {
  const exactRecords = Object.fromEntries(
    buildDemoSeed().map(({ path, data }) => [path, data]),
  );
  const conflictCases = [
    new MemoryAuth([{
      uid: DEMO_ACCOUNTS[0].uid,
      email: 'someone-else@example.invalid',
      emailVerified: false,
      disabled: false,
      customClaims: DEMO_ACCOUNTS[0].claims,
    }]),
    new MemoryAuth([{
      uid: 'different-uid',
      email: DEMO_ACCOUNTS[0].email,
      emailVerified: false,
      disabled: false,
      customClaims: DEMO_ACCOUNTS[0].claims,
    }]),
    new MemoryAuth(expectedUsers().map((user, index) => index === 1
      ? { ...user, customClaims: { role: 'administrator' } }
      : user)),
    new MemoryAuth([{
      ...expectedUsers()[0],
      customClaims: {},
    }]),
  ];

  for (const auth of conflictCases) {
    const firestore = new MemoryFirestore(exactRecords);
    await assert.rejects(
      () => provisionDemoWithServices({ auth, firestore }),
      /conflict|unexpected/i,
    );
    assert.equal(auth.createCalls.length, 0);
    assert.equal(auth.claimCalls.length, 0);
    assert.equal(auth.deleteCalls.length, 0);
    assert.equal(firestore.createCalls.length, 0);
  }

  const auth = new MemoryAuth(expectedUsers());
  const firestore = new MemoryFirestore({
    ...exactRecords,
    'products/DEMO-COFFEE': {
      ...exactRecords['products/DEMO-COFFEE'],
      unexpected: true,
    },
  });
  await assert.rejects(
    () => provisionDemoWithServices({ auth, firestore }),
    /unexpected/i,
  );
  assert.equal(auth.createCalls.length, 0);
  assert.equal(auth.claimCalls.length, 0);
  assert.equal(firestore.createCalls.length, 0);
});
