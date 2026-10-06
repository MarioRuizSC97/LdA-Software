import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateSale } from '../src/sales.js';
import {
  validateTarget, namespace, assertOwnedPath, OwnedRun, canonical,
  openRuntime, initializeRuntime, observeTransactions, inspectSdkChain,
} from './sales-emulator-support.mjs';

const root = '/Users/luismarioruiz/LdA-Software/functions/node_modules';
const environment = {
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
};

test('rejects unsafe/partial config and unapproved SDK roots before resolution', async () => {
  for (const config of [
    {}, { ...environment, GCLOUD_PROJECT: 'production' },
    { ...environment, FIRESTORE_EMULATOR_HOST: 'localhost:8080' },
    { ...environment, FIRESTORE_EMULATOR_HOST: '127.0.0.1:8081' },
    { ...environment, FUNCTIONS_EMULATOR: 'false' },
    { ...environment, GOOGLE_CLOUD_PROJECT: 'other' },
    { ...environment, FIREBASE_CONFIG: '/config.json' },
    { ...environment, GOOGLE_APPLICATION_CREDENTIALS: '/never-read.json' },
    { ...environment, FIRESTORE_PREFER_REST: 'true' },
    { ...environment, GOOGLE_API_USE_CLIENT_CERTIFICATE: 'true' },
    { ...environment, grpc_proxy: 'http://unsafe' },
  ]) {
    assert.throws(() => validateTarget(config, root));
    // Must reject at guard even without B node_modules. No resolver/init is invoked.
    await assert.rejects(openRuntime(config, root), (error) => error.code === 'failed-precondition'
      || error.code === 'ERR_ASSERTION');
  }
  for (const path of ['/tmp/node_modules', root + '/', root + '/../node_modules']) {
    assert.throws(() => validateTarget(environment, path));
  }
  assert.deepEqual(validateTarget(environment, root), environment);
  assert.doesNotThrow(() => validateTarget({ ...environment,
    FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory"}' }, root));
});

// Exact installed layout, modeled entirely in memory; no SDK code is evaluated.
const sdkPackages = [
  ['firebase-admin', '14.5.0', 'lib/index.js'],
  ['@google-cloud/firestore', '9.2.0', 'build/src/index.js'],
  ['@google-cloud/firestore-api', '0.2.0', 'build/src/index.js'],
  ['google-gax', '6.9.0', 'build/src/index.js'],
  ['google-auth-library', '11.1.0', 'build/src/index.js'],
  ['@google-cloud/firestore-api/node_modules/google-gax', '5.0.8', 'build/src/index.js'],
  ['@google-cloud/firestore-api/node_modules/google-auth-library', '10.5.0', 'build/src/index.js'],
  ['@grpc/grpc-js', '1.14.5', 'build/src/index.js'],
];
const sdkEdges = [
  ['firebase-admin/lib/app/credential-internal.js', 'google-auth-library', 'google-auth-library'],
  ['@google-cloud/firestore/build/src/watch.js', 'google-gax', 'google-gax'],
  ['firebase-admin/lib/firestore/firestore-internal.js', '@google-cloud/firestore', '@google-cloud/firestore'],
  ['@google-cloud/firestore/build/src/index.js', 'google-gax', 'google-gax'],
  ['@google-cloud/firestore/build/src/index.js', '@google-cloud/firestore-api', '@google-cloud/firestore-api'],
  ...['v1', 'v1beta1'].map((v) => [`@google-cloud/firestore-api/build/src/${v}/firestore_client.js`,
    'google-gax', '@google-cloud/firestore-api/node_modules/google-gax']),
  ...['google-gax', '@google-cloud/firestore-api/node_modules/google-gax'].flatMap((gax) => [
    ...['index.js', 'grpc.js'].map((file) => [`${gax}/build/src/${file}`, 'google-auth-library',
      gax === 'google-gax' ? 'google-auth-library' : '@google-cloud/firestore-api/node_modules/google-auth-library']),
    ...['index.js', 'grpc.js'].map((file) => [`${gax}/build/src/${file}`, '@grpc/grpc-js', '@grpc/grpc-js']),
  ]),
];
function sdkInspectionFixture() {
  const versions = new Map(sdkPackages.map(([p, v]) => [`${root}/${p}/package.json`, v]));
  const entries = new Map(sdkPackages.map(([p, , entry]) => [p, `${root}/${p}/${entry}`]));
  const resolutions = new Map(sdkEdges.map(([caller, dep, target]) => [`${root}/${caller}:${dep}`, entries.get(target)]));
  for (const [p, entry] of entries) resolutions.set(`${root}/inv05-resolution.cjs:${p}`, entry);
  for (const entry of ['app', 'firestore']) resolutions.set(`${root}/inv05-resolution.cjs:firebase-admin/${entry}`,
    `${root}/firebase-admin/lib/${entry}/index.js`);
  const redirects = new Map();
  const io = {
    lstatSync: () => ({ isDirectory: () => true, isSymbolicLink: () => false }),
    realpathSync: (path) => redirects.get(path) ?? path,
    readFileSync: (path) => { assert.ok(versions.has(path), path); return JSON.stringify({ version: versions.get(path) }); },
    createRequire: (caller) => {
      const require = () => { assert.fail('SDK execution forbidden'); };
      require.resolve = (dep) => { const key = `${caller}:${dep}`; assert.ok(resolutions.has(key), key); return resolutions.get(key); };
      return require;
    },
  };
  return { io, versions, resolutions, redirects };
}

test('accepts genuine distinct root/nested SDK versions without executing modules', () => {
  assert.equal(typeof inspectSdkChain(root, sdkInspectionFixture().io), 'function');
});
for (const [caller, dep, target] of sdkEdges) {
  test(`rejects executable edge redirection: ${caller} -> ${dep}`, () => {
    for (const replacement of [`${root}/unexpected/build/src/index.js`,
      `${root}/${target}/build/src/alternate.js`, '/outside/sdk/index.js']) {
      const fixture = sdkInspectionFixture();
      fixture.resolutions.set(`${root}/${caller}:${dep}`, replacement);
      assert.throws(() => inspectSdkChain(root, fixture.io));
    }
  });
}
for (const [directory] of sdkPackages) {
  test(`rejects SDK version or realpath change: ${directory}`, () => {
    const changed = sdkInspectionFixture();
    changed.versions.set(`${root}/${directory}/package.json`, '0.0.0');
    assert.throws(() => inspectSdkChain(root, changed.io));
    const redirected = sdkInspectionFixture();
    redirected.redirects.set(`${root}/${directory}`, '/outside/sdk');
    assert.throws(() => inspectSdkChain(root, redirected.io));
  });
}

class MemoryFirestore {
  constructor() { this.records = new Map(); this.trace = []; this.failCreate = false; }
  doc(path) {
    return { path, create: async (data) => {
      if (this.records.has(path)) throw new Error('preexisting collision');
      this.records.set(path, structuredClone(data));
      if (this.failCreate) throw new Error('unknown commit outcome');
    } };
  }
  async runTransaction(callback) {
    const writes = [];
    const value = await callback({
      get: async ({ path }) => {
        assert.equal(writes.length, 0, 'reads must precede writes');
        this.trace.push(['read', path]);
        return { exists: this.records.has(path), data: () => structuredClone(this.records.get(path)) };
      },
      delete: ({ path }) => { this.trace.push(['delete', path]); writes.push(() => this.records.delete(path)); },
      set: ({ path }, data) => { writes.push(() => this.records.set(path, structuredClone(data))); },
    });
    writes.forEach((write) => write());
    return value;
  }
}
const fixture = () => {
  const db = new MemoryFirestore();
  const run = new OwnedRun(db);
  const branch = `branches/${run.ns.branches[0]}`;
  return { db, run, branch };
};

test('namespace paths exclude escapes, alternate runs, malformed keys and unmanifested references', () => {
  const { run, branch } = fixture();
  assert.match(run.ns.products[0], /^INV05-[A-F0-9-]+-P1$/);
  assertOwnedPath(run.ns, branch);
  for (const path of [branch + '/stock/../p', 'branches/preexisting',
    `sales/${run.ns.key('case')}/child`, `sales/${run.ns.key('case')}/..`,
    `sales/inv05-${run.ns.id}-`, `inventoryMovements/sale-${run.ns.key('case')}-2`,
    `products/${run.ns.products[0].toLowerCase()}`,
  ]) assert.throws(() => run.plan(path));
  assert.throws(() => run.doc(branch), /manifest/);
  assert.throws(() => namespace('../escape'));
});

test('create-only confirmed creations are deleted after all reads and children before parents', async () => {
  const { db, run, branch } = fixture();
  const stock = `${branch}/stock/${run.ns.products[0]}`;
  await run.seed(branch, { name: 'owned' });
  await run.seed(`products/${run.ns.products[0]}`, { internalCode: run.ns.products[0] });
  await run.seed(stock, { unit: 'kg', precision: 2, quantityScaled: 10 });
  await assert.rejects(run.seed(branch, { name: 'upsert' }));
  await run.cleanup();
  assert.equal(db.records.size, 0);
  const firstDelete = db.trace.findIndex(([kind]) => kind === 'delete');
  assert.equal(firstDelete, 3);
  const deleted = db.trace.slice(firstDelete).map(([, path]) => path);
  assert.ok(deleted.indexOf(stock) < deleted.indexOf(branch));
});

test('preexisting collision and ambiguous successful commit never grant deletion authority', async () => {
  for (const uncertain of [false, true]) {
    const { db, run, branch } = fixture();
    if (uncertain) db.failCreate = true;
    else db.records.set(branch, { name: 'foreign' });
    await assert.rejects(run.seed(branch, { name: 'owned' }));
    assert.equal(run.entries.get(branch).state, 'unknown');
    await assert.rejects(run.cleanup(), (error) => error.message.includes(branch));
    assert.ok(db.records.has(branch));
    assert.equal(db.trace.filter(([kind]) => kind === 'delete').length, 0);
  }
});

test('mismatch or missing anchor conservatively retains the exact run manifest', async () => {
  const { db, run, branch } = fixture();
  await run.seed(branch, { name: 'owned' });
  const product = `products/${run.ns.products[0]}`;
  await run.seed(product, { internalCode: run.ns.products[0] });
  db.records.set(product, { internalCode: 'foreign' });
  await assert.rejects(run.cleanup(), (error) => error.message.includes(branch) && error.message.includes(product));
  assert.equal(db.records.size, 2);
  assert.ok(!db.trace.some(([kind]) => kind === 'delete'));
  db.records.delete(branch);
  await assert.rejects(run.cleanup());
  assert.ok(db.records.has(product));
});

test('ownership fingerprints must detach from caller mutation', async () => {
  const { db, run, branch } = fixture();
  const data = { name: 'original', nested: { identity: 'original' } };
  await run.seed(branch, data);
  data.nested.identity = 'tampered';
  db.records.get(branch).nested.identity = 'tampered';
  await assert.rejects(run.cleanup(), /safe residual IDs/);
  assert.ok(db.records.has(branch), 'tampered data must not be deleted');
});

// Pure lifecycle mocks: no SDK, resolver, RSA generation, env mutation or sockets.
async function mockRuntime(callback, failSettings = false, failTerminate = false) {
  const trace = [];
  const app = {};
  const firestore = {
    projectId: environment.GCLOUD_PROJECT,
    settings(settings) { trace.push(['settings', settings]); if (failSettings) throw new Error('settings failure'); },
    async terminate() { trace.push(['terminate']); if (failTerminate) throw new Error('terminate failure'); },
  };
  const sdk = {
    getFirestore: () => firestore,
    cert(value) { assert.equal(value.projectId, environment.GCLOUD_PROJECT); return 'mock-certificate'; },
    initializeApp(options, name) {
      assert.match(name, /^inv05-/);
      assert.equal(options.credential, 'mock-certificate');
      trace.push(['initialize', name]); return app;
    },
    async deleteApp(value) { assert.equal(value, app); trace.push(['deleteApp']); },
  };
  const open = () => initializeRuntime(sdk, environment,
    () => ({ privateKey: 'mock-only-not-a-certificate' }));
  await callback(open, trace);
}

test('runtime pins explicit settings, disposes named app and Firestore even on error', async () => {
  await mockRuntime(async (open, trace) => {
    const runtime = await open();
    const settings = trace.find(([kind]) => kind === 'settings')[1];
    assert.equal(settings.host, '127.0.0.1:8080');
    assert.equal(settings.ssl, false);
    assert.equal(settings.preferRest, false);
    assert.equal(settings.universeDomain, 'googleapis.com');
    assert.equal(settings.grpcOptions['grpc.enable_http_proxy'], 0);
    await runtime.dispose();
    assert.deepEqual(trace.slice(-2).map(([kind]) => kind), ['terminate', 'deleteApp']);
  });
  await mockRuntime(async (open, trace) => {
    await assert.rejects(open(), /settings failure/);
    assert.deepEqual(trace.slice(-2).map(([kind]) => kind), ['terminate', 'deleteApp']);
  }, true);
  await mockRuntime(async (open, trace) => {
    const runtime = await open();
    await assert.rejects(runtime.dispose(), /disposal failed/);
    assert.equal(trace.at(-1)[0], 'deleteApp');
  }, false, true);
});

test('pre-acquisition rendezvous overlaps real callback entries and records only observed attempts', async () => {
  const observer = observeTransactions(2, 100);
  const trace = [];
  const first = observer.wrap(async () => { trace.push('first'); });
  const second = observer.wrap(async () => { trace.push('second'); });
  const launched = first({});
  await Promise.resolve();
  assert.deepEqual(trace, []);
  await Promise.all([launched, second({})]);
  assert.deepEqual(observer.attempts.map((record) => record.attempts), [1, 1]);
  await first({});
  assert.deepEqual(observer.attempts.map((record) => record.attempts), [2, 1]);
});

test('rendezvous timeout rejects launched transactions without acquiring a lock', async () => {
  const observer = observeTransactions(2, 10);
  let called = false;
  await assert.rejects(observer.wrap(async () => { called = true; })({}), /timeout/);
  assert.equal(called, false);
});

test('successful sale linkage anchors replaced stock metadata; forged relationships prevent deletion', async () => {
  for (const corrupt of ['none', 'fingerprint', 'actor', 'movement', 'stock', 'branch', 'product']) {
    const { db, run, branch } = fixture();
    const productId = run.ns.products[0];
    const productPath = `products/${productId}`;
    const stockPath = `${branch}/stock/${productId}`;
    const quantitySpec = { unit: 'kg', precision: 2 };
    const pricing = { currency: 'MXN', listedPriceCentavos: 100, priceMode: 'iva-included',
      ivaTreatment: 'exempt', ivaRateBasisPoints: null };
    const timestamp = new Date('2026-01-01T00:00:00Z');
    await run.seed(branch, { name: branch, createdAt: timestamp });
    await run.seed(productPath, { internalCode: productId, name: productId, quantitySpec, pricing, createdAt: timestamp });
    await run.seed(stockPath, { ...quantitySpec, quantityScaled: 100, updatedAt: timestamp });
    const key = run.ns.key('success');
    const input = { auth: { uid: run.ns.actor, token: { role: 'seller', branchId: run.ns.branches[0] } },
      data: { idempotencyKey: key, invoiceRequested: false, lines: [{ productId, quantity: '0.5' }],
        payment: { method: 'cash', amountCentavos: 50 } } };
    const receipt = { version: 1, saleId: key, branchId: run.ns.branches[0], productIds: [productId],
      calculation: calculateSale({ invoiceRequested: false,
        lines: [{ quantity: '0.5', quantitySpec, pricing }] }), payment: input.data.payment };
    run.register(input);
    run.confirm(input, { receipt, replayed: false }, timestamp);
    for (const [path, entry] of run.entries) db.records.set(path, structuredClone(entry.expected));
    db.records.set(stockPath, { ...quantitySpec, quantityScaled: 50, updatedAt: timestamp,
      lastMovementId: `sale-${key}-0` }); // No seed marker survives the service's set.
    if (corrupt === 'fingerprint') db.records.get(`saleSubmissionReceipts/${key}`).fingerprint = 'foreign';
    if (corrupt === 'actor') db.records.get(`saleAudits/${key}`).actorId = 'foreign';
    if (corrupt === 'movement') db.records.get(`inventoryMovements/sale-${key}-0`).productId = run.ns.products[1];
    if (corrupt === 'stock') db.records.get(stockPath).lastMovementId = 'foreign';
    if (corrupt === 'branch') db.records.get(branch).name = 'foreign';
    if (corrupt === 'product') db.records.get(productPath).quantitySpec.precision = 1;
    if (corrupt === 'none') { await run.cleanup(); assert.equal(db.records.size, 0); }
    else {
      const before = canonical([...db.records]);
      await assert.rejects(run.cleanup(), /safe residual IDs/);
      assert.equal(canonical([...db.records]), before);
      assert.ok(!db.trace.some(([kind]) => kind === 'delete'));
    }
  }
});

test('planned unknown sale artifacts and ownership read errors never authorize deletion', async () => {
  const { db, run, branch } = fixture();
  await run.seed(branch, { name: 'owned' });
  const unknown = run.plan(`sales/${run.ns.key('unknown')}`);
  db.records.set(unknown, { receipt: 'unconfirmed success or collision' });
  await assert.rejects(run.cleanup(), (error) => error.message.includes(unknown));
  assert.equal(db.records.size, 2);
  db.runTransaction = async () => { throw new Error('read/commit unknown'); };
  await assert.rejects(run.cleanup(), (error) => error.message.includes(branch) && error.message.includes(unknown));
  assert.equal(db.records.size, 2);
});

test('owned repricing preserves immutable product identity and refuses concurrent mismatches', async () => {
  const { db, run } = fixture();
  const path = `products/${run.ns.products[0]}`;
  const original = { internalCode: run.ns.products[0], name: 'owned', pricing: { listedPriceCentavos: 100 } };
  await run.seed(path, original);
  await assert.rejects(run.changeSeed(path, { ...original, name: 'foreign' }), /immutable/);
  const repriced = { ...original, pricing: { listedPriceCentavos: 200 } };
  await run.changeSeed(path, repriced);
  repriced.pricing.listedPriceCentavos = 300;
  assert.equal(run.entries.get(path).expected.pricing.listedPriceCentavos, 200);
  db.records.get(path).name = 'foreign';
  await assert.rejects(run.changeSeed(path, original), /identity mismatch/);
  await assert.rejects(run.cleanup(), /safe residual IDs/);
});

test('canonical ownership equality tolerates Firestore map order and Timestamp roundtrip', () => {
  const date = new Date('2026-01-01T00:00:00Z');
  assert.equal(canonical({ b: 1, a: date }), canonical({ a: { toDate: () => date }, b: 1 }));
});
