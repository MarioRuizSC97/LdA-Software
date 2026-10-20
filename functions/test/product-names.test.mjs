import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';

import { HttpsError } from 'firebase-functions/v2/https';

import { CatalogError, createProductRenameService } from '../src/product-names.js';

const ADMIN = { uid: 'admin-1', token: { role: 'administrator' } };
const FIXED_TIME = '2026-10-20T19:00:00.000Z';
const OLD_NAME = 'Café de olla';
const NEW_NAME = 'Café de olla 500 g';

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

  remove(path) {
    this.#documents.delete(path);
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
        const data = pending.has(path) ? pending.get(path) : this.#documents.get(path);
        return { exists: data !== undefined, data: () => structuredClone(data) };
      },
      create: ({ path }, data) => {
        if (this.#documents.has(path) || pending.has(path)) {
          throw new Error(`document already exists: ${path}`);
        }
        pending.set(path, structuredClone(data));
      },
      update: ({ path }, data) => {
        const current = pending.has(path) ? pending.get(path) : this.#documents.get(path);
        if (current === undefined) throw new Error(`document does not exist: ${path}`);
        pending.set(path, { ...structuredClone(current), ...structuredClone(data) });
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

function seededProduct() {
  return {
    internalCode: 'PRD-COFFEE-001',
    name: OLD_NAME,
    quantitySpec: { unit: 'pieza', precision: 0 },
    createdAt: '2026-01-15T10:00:00.000Z',
    pricing: {
      listedPriceCentavos: 9_500,
      currency: 'MXN',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRateBasisPoints: 1_600,
    },
    pricingUpdatedAt: '2026-09-01T08:00:00.000Z',
    lastPricingAuditId: 'price-coffee-001',
  };
}

function seededHistoricalSale() {
  return {
    totalCentavos: 9_500,
    items: [{
      productId: 'PRD-COFFEE-001',
      productName: OLD_NAME,
      quantity: 2,
      unitPriceCentavos: 4_750,
    }],
  };
}

function request(overrides = {}) {
  return {
    auth: ADMIN,
    data: {
      idempotencyKey: 'rename-coffee-001',
      productId: 'PRD-COFFEE-001',
      name: NEW_NAME,
      ...overrides,
    },
  };
}

function setup(product = seededProduct()) {
  const firestore = new MemoryFirestore();
  firestore.seed('products/PRD-COFFEE-001', product);
  firestore.seed('sales/sale-2026-001', seededHistoricalSale());
  return {
    firestore,
    renameProduct: createProductRenameService({ firestore, now: () => FIXED_TIME }),
  };
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
        headers: { origin, 'access-control-request-method': 'POST' },
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

test('exposes the rename service through its public module namespace', async () => {
  const productNames = await import('../src/product-names.js');
  assert.equal(typeof productNames.createProductRenameService, 'function');
  assert.equal(typeof productNames.CatalogError, 'function');
});

test('requires an authenticated administrator before touching Firestore', async () => {
  const { firestore, renameProduct } = setup();

  await rejectsCode(() => renameProduct({ ...request(), auth: null }), 'unauthenticated');
  await rejectsCode(
    () => renameProduct({
      ...request(),
      auth: { uid: 'seller-1', token: { role: 'seller' } },
    }),
    'permission-denied',
  );

  assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), seededProduct());
  assert.equal(firestore.read('productNameUpdateReceipts/rename-coffee-001'), undefined);
});

test('renames only the name and preserves every other field plus the historical sale', async () => {
  const { firestore, renameProduct } = setup();

  const result = await renameProduct(request());

  assert.deepEqual(result, {
    productId: 'PRD-COFFEE-001',
    oldName: OLD_NAME,
    newName: NEW_NAME,
    replayed: false,
  });
  assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), {
    ...seededProduct(),
    name: NEW_NAME,
  });
  assert.deepEqual(firestore.read('sales/sale-2026-001'), seededHistoricalSale());
  assert.deepEqual(firestore.read('productNameUpdateReceipts/rename-coffee-001'), {
    fingerprint: JSON.stringify({
      actorId: 'admin-1',
      productId: 'PRD-COFFEE-001',
      name: NEW_NAME,
    }),
    result: {
      productId: 'PRD-COFFEE-001',
      oldName: OLD_NAME,
      newName: NEW_NAME,
    },
    completedAt: FIXED_TIME,
    actorId: 'admin-1',
  });
});

test('accepts canonical names at the 1 and 120 character boundaries', async () => {
  for (const name of ['A', 'x'.repeat(120)]) {
    const { renameProduct } = setup();
    const result = await renameProduct(request({ name }));
    assert.deepEqual(result, {
      productId: 'PRD-COFFEE-001',
      oldName: OLD_NAME,
      newName: name,
      replayed: false,
    });
  }
});

test('rejects non-canonical names without any write', async () => {
  for (const name of [
    '',
    ' Coffee ',
    'x'.repeat(121),
    '\u0007Bell',
    'Line\nbreak',
    42,
    null,
  ]) {
    const { firestore, renameProduct } = setup();
    await rejectsCode(() => renameProduct(request({ name })), 'invalid-argument');
    assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), seededProduct());
    assert.equal(firestore.read('productNameUpdateReceipts/rename-coffee-001'), undefined);
  }
});

test('rejects missing products without creating a receipt', async () => {
  const { firestore, renameProduct } = setup();
  firestore.remove('products/PRD-COFFEE-001');

  await rejectsCode(() => renameProduct(request()), 'not-found');
  assert.equal(firestore.read('productNameUpdateReceipts/rename-coffee-001'), undefined);
});

test('validates identifiers and exact request fields', async () => {
  for (const data of [
    { productId: 42 },
    { productId: 'PRD COFFEE 001' },
    { productId: '' },
    { idempotencyKey: 'not a key!' },
    { unexpected: true },
  ]) {
    const { firestore, renameProduct } = setup();
    await rejectsCode(() => renameProduct(request(data)), 'invalid-argument');
    assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), seededProduct());
    assert.equal(firestore.read('productNameUpdateReceipts/rename-coffee-001'), undefined);
  }

  const { renameProduct } = setup();
  for (const field of ['idempotencyKey', 'productId', 'name']) {
    const partial = { ...request().data };
    delete partial[field];
    await rejectsCode(() => renameProduct({ auth: ADMIN, data: partial }), 'invalid-argument');
  }
});

test('replays identical retries and rejects conflicting reuse without new writes', async () => {
  const { firestore, renameProduct } = setup();

  const first = await renameProduct(request());
  const replay = await renameProduct(request());

  assert.equal(first.replayed, false);
  assert.deepEqual(replay, {
    productId: 'PRD-COFFEE-001',
    oldName: OLD_NAME,
    newName: NEW_NAME,
    replayed: true,
  });
  assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), {
    ...seededProduct(),
    name: NEW_NAME,
  });

  await rejectsCode(
    () => renameProduct(request({ name: 'A different coffee' })),
    'already-exists',
  );
  assert.deepEqual(firestore.read('products/PRD-COFFEE-001'), {
    ...seededProduct(),
    name: NEW_NAME,
  });
  assert.deepEqual(firestore.read('productNameUpdateReceipts/rename-coffee-001'), {
    fingerprint: JSON.stringify({
      actorId: 'admin-1',
      productId: 'PRD-COFFEE-001',
      name: NEW_NAME,
    }),
    result: {
      productId: 'PRD-COFFEE-001',
      oldName: OLD_NAME,
      newName: NEW_NAME,
    },
    completedAt: FIXED_TIME,
    actorId: 'admin-1',
  });
});

test('binds an idempotency key to the administrator who created the receipt', async () => {
  const { firestore, renameProduct } = setup();

  await renameProduct(request());
  await rejectsCode(
    () => renameProduct({
      ...request(),
      auth: { uid: 'admin-2', token: { role: 'administrator' } },
    }),
    'already-exists',
  );
  assert.equal(
    firestore.read('productNameUpdateReceipts/rename-coffee-001').actorId,
    'admin-1',
  );
});

test('local callable permits only localhost web origins', async () => {
  const { renameProduct } = await import('../src/index.js');
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

  assert.deepEqual(await preflightOrigins(renameProduct, allowed), allowed);
  assert.deepEqual(await preflightOrigins(renameProduct, denied), [null, null, null]);
});

test('local callable distinguishes its guard from unexpected infrastructure failures', async () => {
  const { renameProduct } = await import('../src/index.js');

  await withEnvironment({
    GCLOUD_PROJECT: 'production',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }, async () => {
    await assert.rejects(() => renameProduct.run(request()), (error) => {
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
      () => renameProduct.run({ ...request(), auth: null }),
      (error) => error instanceof HttpsError && error.code === 'unauthenticated',
    );
    await assert.rejects(
      () => renameProduct.run({
        auth: ADMIN,
        get data() {
          throw new Error('private infrastructure detail');
        },
      }),
      (error) => {
        assert.ok(error instanceof HttpsError);
        assert.equal(error.code, 'internal');
        assert.equal(error.message, 'product rename is temporarily unavailable');
        assert.doesNotMatch(error.message, /private infrastructure detail/);
        return true;
      },
    );
  });
});
