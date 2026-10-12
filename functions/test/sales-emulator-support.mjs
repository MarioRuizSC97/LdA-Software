import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { assertLocalSalesEmulator } from '../src/sales.js';

export const SDK_ROOT = '/Users/luismarioruiz/LdA-Software/functions/node_modules';
export const PROJECT = 'demo-lda-inventory';
export const HOST = '127.0.0.1:8080';

export function validateTarget(environment, root = SDK_ROOT) {
  assertLocalSalesEmulator(environment); // Production pure guard precedes all SDK work.
  assert.equal(root, SDK_ROOT, 'only the approved installed SDK is allowed');
  for (const key of [
    'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_CLOUD_QUOTA_PROJECT',
    'GOOGLE_CLOUD_UNIVERSE_DOMAIN', 'GCLOUD_UNIVERSE_DOMAIN',
    'FIRESTORE_PREFER_REST', 'FIREBASE_FIRESTORE_EMULATOR_ADDRESS',
    'GOOGLE_API_USE_CLIENT_CERTIFICATE', 'GOOGLE_API_USE_MTLS_ENDPOINT',
    'grpc_proxy', 'https_proxy', 'http_proxy', 'GRPC_PROXY', 'HTTPS_PROXY', 'HTTP_PROXY',
    'GRPC_TRACE', 'FIRESTORE_LOGGING', 'GOOGLE_SDK_NODE_LOGGING',
  ]) assert.equal(environment[key], undefined, `ambient override forbidden: ${key}`);
  return Object.freeze({
    GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', FIRESTORE_EMULATOR_HOST: HOST,
  });
}

export function approvedRequire(root = SDK_ROOT) {
  return inspectSdkChain(root, { lstatSync, realpathSync, readFileSync, createRequire });
}

// Pure inspection seam: the real runner always supplies native read-only operations.
export function inspectSdkChain(root, { lstatSync, realpathSync, readFileSync, createRequire }) {
  assert.equal(root, SDK_ROOT);
  assert.ok(lstatSync(root).isDirectory() && !lstatSync(root).isSymbolicLink());
  assert.equal(realpathSync(root), root, 'SDK root ancestors must not redirect');
  const require = createRequire(`${root}/inv05-resolution.cjs`);
  const api = '@google-cloud/firestore-api';
  const nestedGax = `${api}/node_modules/google-gax`;
  const nestedAuth = `${api}/node_modules/google-auth-library`;
  // Reviewed routing-sensitive chain only, not a transitive integrity guarantee.
  // Legitimate root and API-local versions are deliberately distinct.
  const packages = [
    ['firebase-admin', '14.5.0', 'lib/index.js'],
    ['@google-cloud/firestore', '9.2.0', 'build/src/index.js'],
    [api, '0.2.0', 'build/src/index.js'],
    ['google-gax', '6.9.0', 'build/src/index.js'],
    ['google-auth-library', '11.1.0', 'build/src/index.js'],
    [nestedGax, '5.0.8', 'build/src/index.js'],
    [nestedAuth, '10.5.0', 'build/src/index.js'],
    ['@grpc/grpc-js', '1.14.5', 'build/src/index.js'],
  ];
  const entries = new Map();
  const exactPath = (path) => {
    assert.equal(realpathSync(path), path, `redirected SDK path: ${path}`);
    return path;
  };
  for (const [packagePath, version, entry] of packages) {
    const directory = `${root}/${packagePath}`;
    assert.ok(lstatSync(directory).isDirectory() && !lstatSync(directory).isSymbolicLink());
    exactPath(directory);
    const metadata = exactPath(`${directory}/package.json`);
    assert.equal(JSON.parse(readFileSync(metadata, 'utf8')).version, version, packagePath);
    entries.set(packagePath, exactPath(`${directory}/${entry}`));
  }
  const checkEdge = (caller, dependency, expected) => {
    const resolved = createRequire(caller).resolve(dependency);
    assert.equal(resolved, expected, `unapproved SDK edge: ${caller} -> ${dependency}`);
    exactPath(resolved);
  };
  for (const module of ['app', 'firestore']) {
    checkEdge(`${root}/inv05-resolution.cjs`, `firebase-admin/${module}`,
      `${root}/firebase-admin/lib/${module}/index.js`);
  }
  for (const [caller, dependency, target] of [
    ['firebase-admin/lib/app/credential-internal.js', 'google-auth-library', 'google-auth-library'],
    ['@google-cloud/firestore/build/src/watch.js', 'google-gax', 'google-gax'],
    ['firebase-admin/lib/firestore/firestore-internal.js', '@google-cloud/firestore', '@google-cloud/firestore'],
    ['@google-cloud/firestore/build/src/index.js', 'google-gax', 'google-gax'],
    ['@google-cloud/firestore/build/src/index.js', api, api],
    ...['v1', 'v1beta1'].map((v) => [`${api}/build/src/${v}/firestore_client.js`, 'google-gax', nestedGax]),
    ...['google-gax', nestedGax].flatMap((gax) => [
      ...['index.js', 'grpc.js'].map((file) => [`${gax}/build/src/${file}`, 'google-auth-library',
        gax === 'google-gax' ? 'google-auth-library' : nestedAuth]),
      ...['index.js', 'grpc.js'].map((file) => [`${gax}/build/src/${file}`, '@grpc/grpc-js', '@grpc/grpc-js']),
    ]),
  ]) checkEdge(exactPath(`${root}/${caller}`), dependency, entries.get(target));
  return require;
}

// No SDK import/init happens at module evaluation. Call ONLY after fresh safety review.
export async function openRuntime(environment = process.env, root = SDK_ROOT) {
  const pinned = validateTarget(environment, root);
  // SDK reads ambient process.env, so an injected safe environment cannot mask it.
  validateTarget(process.env, root);
  const require = approvedRequire(root);
  return initializeRuntime({
    ...require('firebase-admin/app'), ...require('firebase-admin/firestore'),
  }, pinned);
}

// Lifecycle seam for pure mock tests, not an SDK-resolution option in the real runner.
export async function initializeRuntime({ initializeApp, cert, deleteApp, getFirestore },
  pinned, keyPair = generateKeyPairSync) {
  let app;
  let firestore;
  const dispose = async () => {
    const errors = [];
    try { if (firestore) await firestore.terminate(); } catch (error) { errors.push(error); }
    try { if (app) await deleteApp(app); } catch (error) { errors.push(error); }
    if (errors.length) throw new AggregateError(errors, 'INV05 handle disposal failed');
  };
  try {
    const { privateKey } = keyPair('rsa', {
      modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    app = initializeApp({ projectId: PROJECT, credential: cert({
      projectId: PROJECT, clientEmail: `inv05-local@${PROJECT}.iam.gserviceaccount.com`,
      privateKey,
    }) }, `inv05-${randomUUID()}`);
    firestore = getFirestore(app);
    firestore.settings({
      projectId: PROJECT, host: HOST, ssl: false, preferRest: false,
      ignoreUndefinedProperties: false, universeDomain: 'googleapis.com',
      grpcOptions: { 'grpc.enable_http_proxy': 0 },
    });
    // Installed Firestore index.js supplies createInsecure() when ssl=false;
    // installed google-gax grpc.js _getCredentials returns sslCreds before auth.
    // Explicit projectId avoids discovery; no certificate token refresh is used.
    assert.equal(firestore.projectId, PROJECT);
    return { firestore, environment: pinned, dispose };
  } catch (error) {
    try { await dispose(); } catch (disposal) {
      throw new AggregateError([error, disposal], 'INV05 initialization/disposal failed');
    }
    throw error;
  }
}

// Promise.all-shaped, but a failure surfaces only after every other read settles,
// so no in-flight read outlives the caller (e.g. a teardown or a transaction).
export async function settleAll(values) {
  const outcomes = await Promise.allSettled(values);
  const failure = outcomes.find((outcome) => outcome.status === 'rejected');
  if (failure) throw failure.reason;
  return outcomes.map((outcome) => outcome.value);
}

export function canonical(value) {
  if (value instanceof Date) return JSON.stringify(value.toISOString());
  if (typeof value?.toDate === 'function') return canonical(value.toDate());
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort()
    .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

export function namespace(id = randomUUID()) {
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  return Object.freeze({
    id, branches: Object.freeze(['a', 'b'].map((suffix) => `branch-inv05-${id}-${suffix}`)),
    products: Object.freeze([1, 2].map((index) => `INV05-${id.toUpperCase()}-P${index}`)),
    actor: `inv05-${id}-seller`,
    key(label) {
      assert.match(label, /^[a-z][a-z0-9-]{0,39}$/);
      return `inv05-${id}-${label}`;
    },
  });
}

export function assertOwnedPath(ns, path) {
  const parts = path.split('/');
  const [collection, id, child, product] = parts;
  const caseKey = `inv05-${ns.id}-`;
  const validKey = (key) => key?.startsWith(caseKey)
    && /^[a-z][a-z0-9-]{0,39}$/.test(key.slice(caseKey.length));
  assert.ok(
    (parts.length === 2 && collection === 'branches' && ns.branches.includes(id))
    || (parts.length === 2 && collection === 'products' && ns.products.includes(id))
    || (parts.length === 4 && collection === 'branches' && ns.branches.includes(id)
      && child === 'stock' && ns.products.includes(product))
    || (parts.length === 2 && ['sales', 'saleAudits', 'saleSubmissionReceipts'].includes(collection)
      && validKey(id))
    || (parts.length === 2 && collection === 'inventoryMovements'
      && /^sale-.*-[01]$/.test(id) && validKey(id.slice(5, -2))),
    `unowned path refused: ${path}`,
  );
  return path;
}

// One exact manifest. Missing/uncertain commits never become deletion authority.
export class OwnedRun {
  constructor(firestore, ns = namespace()) {
    this.firestore = firestore;
    this.ns = ns;
    this.entries = new Map();
    this.successes = new Map();
  }
  plan(path) {
    assertOwnedPath(this.ns, path);
    if (!this.entries.has(path)) this.entries.set(path, { state: 'planned' });
    return path;
  }
  doc(path) {
    assertOwnedPath(this.ns, path);
    assert.ok(this.entries.has(path), `path not in exact manifest: ${path}`);
    return this.firestore.doc(path);
  }
  async seed(path, data) {
    this.plan(path);
    const entry = this.entries.get(path);
    assert.equal(entry.state, 'planned', 'seed must be create-only, once');
    const detached = structuredClone(data);
    entry.state = 'unknown';
    await this.doc(path).create(detached); // Failed/ambiguous response stays unknown.
    entry.state = 'confirmed';
    entry.expected = structuredClone(detached);
    entry.seed = structuredClone(detached);
  }
  async changeSeed(path, next) {
    const entry = this.entries.get(path);
    assert.equal(entry?.state, 'confirmed');
    const previous = entry.expected;
    next = structuredClone(next);
    assert.ok(path.startsWith('products/'), 'only owned repricing is supported');
    const identity = ({ pricing, ...fields }) => fields;
    assert.equal(canonical(identity(next)), canonical(identity(entry.seed)), 'immutable product identity');
    await this.firestore.runTransaction(async (tx) => {
      const snapshot = await tx.get(this.doc(path));
      assert.equal(canonical(snapshot.data()), canonical(previous), 'seed identity mismatch');
      tx.set(this.doc(path), next);
    });
    entry.expected = next;
  }
  register(request) {
    const { idempotencyKey: key, lines } = request.data;
    for (const collection of ['sales', 'saleAudits', 'saleSubmissionReceipts']) {
      this.plan(`${collection}/${key}`);
    }
    lines.forEach((_, index) => this.plan(`inventoryMovements/sale-${key}-${index}`));
    // A malicious branch in a denial case must still be an owned branch.
    assert.ok(this.ns.branches.includes(request.auth?.token?.branchId));
    assert.ok(lines.every((line) => this.ns.products.includes(line.productId)));
  }
  confirm(request, result, timestamp) {
    const key = request.data.idempotencyKey;
    if (result.replayed) {
      assert.ok(this.successes.has(key), 'replay without confirmed run-owned creation');
      assert.equal(canonical(result.receipt), canonical(this.successes.get(key).receipt));
      return;
    }
    assert.ok(!this.successes.has(key));
    const { uid: actorId, token: { branchId } } = request.auth;
    const receipt = result.receipt;
    assert.equal(receipt.saleId, key);
    assert.equal(receipt.branchId, branchId);
    assert.deepEqual(receipt.productIds, request.data.lines.map((line) => line.productId));
    const records = [
      [`sales/${key}`, { receipt, createdAt: timestamp }],
      [`saleAudits/${key}`, { saleId: key, branchId, actorId, createdAt: timestamp }],
      [`saleSubmissionReceipts/${key}`, {
        actorId, branchId, fingerprint: JSON.stringify({ actorId, branchId, ...request.data }),
        result: receipt, completedAt: timestamp,
      }],
      ...request.data.lines.map((line, index) => [
        `inventoryMovements/sale-${key}-${index}`, {
          type: 'sale', saleId: key, branchId, productId: line.productId,
          quantityScaled: -receipt.calculation.lines[index].quantity.scaled,
          ...receipt.calculation.lines[index].quantity.spec, actorId, occurredAt: timestamp,
        },
      ]),
    ];
    for (const [path, expected] of records) {
      const entry = this.entries.get(path);
      assert.equal(entry?.state, 'planned', 'artifact collision is not ownership');
      entry.state = 'confirmed';
      entry.expected = structuredClone(expected);
    }
    this.successes.set(key, structuredClone({ receipt, branchId, timestamp }));
  }
  scopedFirestore(observe = (callback) => callback) {
    return {
      doc: (path) => this.doc(path),
      runTransaction: (callback) => this.firestore.runTransaction(observe(callback)),
    };
  }
  stockExpected(path, actual) {
    const entry = this.entries.get(path);
    if (!entry.seed) return false;
    const [, branchId, , productId] = path.split('/');
    const branch = this.entries.get(`branches/${branchId}`);
    const product = this.entries.get(`products/${productId}`);
    if (branch?.state !== 'confirmed' || product?.state !== 'confirmed') return false;
    let quantityScaled = entry.seed.quantityScaled;
    const endings = [];
    for (const [key, sale] of this.successes) {
      const index = sale.receipt.productIds.indexOf(productId);
      if (sale.branchId !== branchId || index < 0) continue;
      quantityScaled -= sale.receipt.calculation.lines[index].quantity.scaled;
      endings.push({
        quantityScaled: 0, unit: entry.seed.unit, precision: entry.seed.precision,
        updatedAt: sale.timestamp, lastMovementId: `sale-${key}-${index}`,
      });
    }
    if (!endings.length) return canonical(actual) === canonical(entry.expected);
    return quantityScaled >= 0 && endings.some((ending) => canonical(actual)
      === canonical({ ...ending, quantityScaled }));
  }
  async cleanup() {
    const paths = [...this.entries.keys()];
    let residuals = [];
    try {
      await this.firestore.runTransaction(async (tx) => {
        // All ownership reads finish before ANY delete, including parent anchors.
        const snapshots = await settleAll(paths.map((path) => tx.get(this.doc(path))));
        const present = paths.filter((_, index) => snapshots[index].exists);
        const suspicious = paths.filter((path, index) => {
          const entry = this.entries.get(path);
          if (!snapshots[index].exists) return entry.state === 'confirmed';
          if (entry.state !== 'confirmed') return true;
          const data = snapshots[index].data();
          return path.includes('/stock/') ? !this.stockExpected(path, data)
            : canonical(data) !== canonical(entry.expected);
        });
        // Conservative whole-run retention: no dangling evidence or parent deletion.
        if (suspicious.length) {
          residuals = [...new Set([...present, ...suspicious])].sort();
          return;
        }
        present.sort((a, b) => Number(a.startsWith('branches/') && !a.includes('/stock/'))
          - Number(b.startsWith('branches/') && !b.includes('/stock/')));
        for (const path of present) tx.delete(this.doc(path));
        residuals = [];
      });
    } catch {
      // Unknown cleanup commit outcome: do not retry deletes outside ownership checks.
      residuals = paths.sort();
    }
    assert.deepEqual(residuals, [], `INV05 safe residual IDs: ${residuals.join(', ')}`);
  }
}

// Rendezvous ONLY before the first read/lock acquisition. Never pause a held lock.
export function observeTransactions(participants = 1, timeoutMs = 5000, onAttempt = () => {}) {
  const attempts = [];
  let arrived = 0;
  let release;
  let timer;
  const gate = new Promise((resolve, reject) => {
    release = resolve;
    if (participants > 1) timer = setTimeout(() => reject(new Error('INV05 rendezvous timeout')), timeoutMs);
    else resolve();
  });
  // Prevent unhandled rejection before a callback arrives; callbacks still see failure.
  gate.catch(() => {});
  return {
    attempts,
    wrap(callback) {
      const invocation = attempts.length;
      const record = { invocation, attempts: 0 };
      attempts.push(record);
      return async (tx) => {
        record.attempts++;
        onAttempt(record);
        if (record.attempts === 1) {
          if (++arrived === participants) { clearTimeout(timer); release(); }
          await gate;
        }
        return callback(tx);
      };
    },
  };
}
