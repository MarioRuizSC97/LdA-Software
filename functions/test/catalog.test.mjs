import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';

import { HttpsError } from 'firebase-functions/v2/https';

import {
  CatalogError,
  assertLocalCatalogEmulator,
  createProductCreationService,
} from '../src/catalog.js';

const ADMIN = { uid: 'admin-1', token: { role: 'administrator' } };
const FIXED_TIME = '2026-09-24T12:00:00.000Z';

class MemoryFirestore {
  #documents = new Map();
  #queue = Promise.resolve();

  doc(path) {
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
    const previous = this.#queue;
    let release;
    this.#queue = new Promise((resolve) => {
      release = resolve;
    });
    await previous;

    const pending = new Map();
    const transaction = {
      get: async ({ path }) => {
        const data = this.#documents.get(path);
        return {
          exists: data !== undefined,
          data: () => structuredClone(data),
        };
      },
      create: ({ path }, data) => {
        if (this.#documents.has(path) || pending.has(path)) {
          throw new Error(`document already exists: ${path}`);
        }
        pending.set(path, structuredClone(data));
      },
    };

    try {
      const result = await callback(transaction);
      for (const [path, data] of pending) {
        this.#documents.set(path, data);
      }
      return result;
    } finally {
      release();
    }
  }
}

function request(overrides = {}) {
  return {
    auth: ADMIN,
    data: {
      idempotencyKey: 'create-coffee-001',
      name: 'Coffee',
      quantitySpec: { unit: 'piece', precision: 0 },
      ...overrides,
    },
  };
}

function setup(codes = ['PRD-COFFEE-001']) {
  const firestore = new MemoryFirestore();
  let index = 0;
  const createProduct = createProductCreationService({
    firestore,
    now: () => FIXED_TIME,
    generateInternalCode: () => codes[index++],
  });
  return { firestore, createProduct };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof CatalogError);
    assert.equal(error.code, code);
    return true;
  });
}

async function withEnvironment(values, operation) {
  const previous = Object.fromEntries(
    Object.keys(values).map((key) => [key, process.env[key]]),
  );
  Object.assign(process.env, values);
  try {
    return await operation();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
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
        headers: {
          origin,
          'access-control-request-method': 'POST',
        },
      });
      return response.headers.get('access-control-allow-origin');
    }));
  } finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => {
      if (error) reject(error);
      else resolve();
    }));
  }
}

test('requires a verified administrator before opening a transaction', async () => {
  const { createProduct } = setup();

  await rejectsCode(
    () => createProduct({ ...request(), auth: null }),
    'unauthenticated',
  );
  await rejectsCode(
    () => createProduct({
      ...request(),
      auth: { uid: 'seller-1', token: { role: 'seller' } },
    }),
    'permission-denied',
  );
});

test('creates a seller-readable product without price or acquisition cost', async () => {
  const { firestore, createProduct } = setup();

  const result = await createProduct(request());

  assert.deepEqual(result, {
    productId: 'PRD-COFFEE-001',
    internalCode: 'PRD-COFFEE-001',
    replayed: false,
  });
  assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), {
    internalCode: 'PRD-COFFEE-001',
    name: 'Coffee',
    quantitySpec: { unit: 'piece', precision: 0 },
    createdAt: FIXED_TIME,
  });
  assert.equal(
    firestore.read('productCreationReceipts/create-coffee-001').actorId,
    'admin-1',
  );
  assert.equal(firestore.read('costs/PRD-COFFEE-001'), undefined);
  assert.equal('salePrice' in firestore.read('products/PRD-COFFEE-001'), false);
});

test('replays the original stable identity and rejects key reuse with new input', async () => {
  const { firestore, createProduct } = setup([
    'PRD-FIRST-001',
    'PRD-SHOULD-NOT-BE-USED',
  ]);

  const first = await createProduct(request());
  const replay = await createProduct(request());

  assert.equal(first.productId, 'PRD-FIRST-001');
  assert.deepEqual(replay, {
    productId: 'PRD-FIRST-001',
    internalCode: 'PRD-FIRST-001',
    replayed: true,
  });
  assert.equal(firestore.read('products/PRD-SHOULD-NOT-BE-USED'), undefined);

  await rejectsCode(
    () => createProduct(request({ name: 'Different coffee' })),
    'already-exists',
  );
});

test('binds an idempotency key to the administrator who created the receipt', async () => {
  const { firestore, createProduct } = setup();

  await createProduct(request());
  await rejectsCode(
    () => createProduct({
      ...request(),
      auth: { uid: 'admin-2', token: { role: 'administrator' } },
    }),
    'already-exists',
  );

  assert.equal(
    firestore.read('productCreationReceipts/create-coffee-001').actorId,
    'admin-1',
  );
});

test('retries generated-code collisions without overwriting an existing product', async () => {
  const { firestore, createProduct } = setup([
    'PRD-EXISTING-001',
    'PRD-UNIQUE-002',
  ]);
  firestore.seed('products/PRD-EXISTING-001', {
    internalCode: 'PRD-EXISTING-001',
    name: 'Existing product',
    quantitySpec: { unit: 'piece', precision: 0 },
  });

  const result = await createProduct(request());

  assert.equal(result.productId, 'PRD-UNIQUE-002');
  assert.equal(
    firestore.read('products/PRD-EXISTING-001').name,
    'Existing product',
  );
  assert.equal(firestore.read('products/PRD-UNIQUE-002').name, 'Coffee');
});

test('validates canonical names and immutable per-product quantity specifications', async () => {
  const { createProduct } = setup();

  for (const data of [
    { name: '' },
    { name: ' Coffee ' },
    { name: 'x'.repeat(121) },
    { quantitySpec: { unit: 'Kg', precision: 2 } },
    { quantitySpec: { unit: 'kg', precision: 7 } },
  ]) {
    await rejectsCode(() => createProduct(request(data)), 'invalid-argument');
  }
});

test('accepts no client-selected internal code, price, cost, or unknown input', async () => {
  const { createProduct } = setup();

  for (const data of [
    { internalCode: 'CLIENT-CODE' },
    { salePriceMxn: '100.00' },
    { unitCostMxn: '50.00' },
    { unexpected: true },
  ]) {
    await rejectsCode(() => createProduct(request(data)), 'invalid-argument');
  }
});

test('local catalog guard requires the dedicated demo project and emulator markers', () => {
  assert.doesNotThrow(() => assertLocalCatalogEmulator({
    GCLOUD_PROJECT: 'demo-lda-inventory',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }));

  for (const environment of [
    { GCLOUD_PROJECT: 'production', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
  ]) {
    assert.throws(() => assertLocalCatalogEmulator(environment), /local emulator/);
  }
});

test('local callable permits only localhost web origins', async () => {
  const { createProduct } = await import('../src/index.js');
  const allowed = [
    'http://localhost',
    'http://localhost:5000',
    'https://127.0.0.1:7357',
  ];
  const denied = [
    'https://example.com',
    'http://localhost.example.com',
    'http://127.0.0.2:5000',
  ];

  assert.deepEqual(await preflightOrigins(createProduct, allowed), allowed);
  assert.deepEqual(await preflightOrigins(createProduct, denied), [null, null, null]);
});

test('local callable distinguishes its guard from unexpected infrastructure failures', async () => {
  const { createProduct } = await import('../src/index.js');

  await withEnvironment({
    GCLOUD_PROJECT: 'production',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }, async () => {
    await assert.rejects(() => createProduct.run(request()), (error) => {
      assert.ok(error instanceof HttpsError);
      assert.equal(error.code, 'failed-precondition');
      assert.match(error.message, /restricted to the local demo emulator/);
      return true;
    });
  });

  await withEnvironment({
    GCLOUD_PROJECT: 'demo-lda-inventory',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }, async () => {
    await assert.rejects(
      () => createProduct.run({ ...request(), auth: null }),
      (error) => error instanceof HttpsError && error.code === 'unauthenticated',
    );
    await assert.rejects(
      () => createProduct.run({
        auth: ADMIN,
        get data() {
          throw new Error('private infrastructure detail');
        },
      }),
      (error) => {
        assert.ok(error instanceof HttpsError);
        assert.equal(error.code, 'internal');
        assert.equal(error.message, 'product creation is temporarily unavailable');
        assert.doesNotMatch(error.message, /private infrastructure detail/);
        return true;
      },
    );
  });
});

test('an unexpected callable failure is logged without request data and stays generic for the client', async () => {
  const { unexpectedFailure } = await import('../src/index.js');
  const entries = [];
  const log = { error: (message, fields) => entries.push({ message, fields }) };
  const cause = Object.assign(new Error('7 PERMISSION_DENIED: missing permission'), { code: 7 });

  const failure = unexpectedFailure(cause, 'product creation is temporarily unavailable', log);

  assert.ok(failure instanceof HttpsError);
  assert.equal(failure.code, 'internal');
  assert.equal(failure.message, 'product creation is temporarily unavailable');
  assert.deepEqual(entries, [{
    message: 'callable failed unexpectedly',
    fields: { errorName: 'Error', errorCode: 7, errorMessage: '7 PERMISSION_DENIED: missing permission' },
  }]);
});

test('the default Admin app is created even when another named app already exists', async () => {
  const { getApp, getApps, initializeApp, deleteApp } = await import('firebase-admin/app');
  const { ensureDefaultApp } = await import('../src/index.js');
  // firebase-functions creates its own named app to verify ID tokens in a
  // deployed runtime, before any callable body runs.
  const sdkApp = initializeApp({ projectId: 'demo-lda-inventory' }, '__FIREBASE_FUNCTIONS_SDK__');
  try {
    ensureDefaultApp();
    assert.equal(getApp().name, '[DEFAULT]');
    ensureDefaultApp();
    assert.equal(getApps().filter((app) => app.name === '[DEFAULT]').length, 1);
  } finally {
    await deleteApp(sdkApp);
    if (getApps().some((app) => app.name === '[DEFAULT]')) await deleteApp(getApp());
  }
});
