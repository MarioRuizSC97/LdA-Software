import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';

import { HttpsError } from 'firebase-functions/v2/https';

import {
  PricingError,
  assertLocalPricingEmulator,
  createProductPricingService,
} from '../src/pricing.js';

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
      set: ({ path }, data) => {
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

function request(overrides = {}) {
  return {
    auth: ADMIN,
    data: {
      idempotencyKey: 'price-coffee-001',
      productId: 'product-coffee',
      listedPriceMxn: '999.50',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRatePercent: '16',
      ...overrides,
    },
  };
}

function setup(product = {}) {
  const firestore = new MemoryFirestore();
  firestore.seed('products/product-coffee', {
    internalCode: 'product-coffee',
    name: 'Coffee',
    quantitySpec: { unit: 'piece', precision: 0 },
    ...product,
  });
  return {
    firestore,
    setPrice: createProductPricingService({ firestore, now: () => FIXED_TIME }),
  };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof PricingError);
    assert.equal(error.code, code);
    return true;
  });
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

test('requires an authenticated administrator before opening a transaction', async () => {
  const { setPrice } = setup();

  await rejectsCode(() => setPrice({ ...request(), auth: null }), 'unauthenticated');
  await rejectsCode(
    () => setPrice({ ...request(), auth: { uid: 'seller-1', token: { role: 'seller' } } }),
    'permission-denied',
  );
});

test('sets seller-safe pricing while keeping actor identity in protected records', async () => {
  const { firestore, setPrice } = setup({ pricingUpdatedBy: 'legacy-admin' });

  const result = await setPrice(request());

  assert.deepEqual(result, {
    auditId: 'price-coffee-001',
    productId: 'product-coffee',
    pricing: {
      listedPriceCentavos: 99_950,
      currency: 'MXN',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRateBasisPoints: 1_600,
    },
    replayed: false,
  });
  const product = firestore.read('products/product-coffee');
  assert.deepEqual(product.pricing, result.pricing);
  assert.equal('pricingUpdatedBy' in product, false);
  assert.equal(product.lastPricingAuditId, 'price-coffee-001');
  assert.equal('unitCostCentavos' in product, false);
  assert.deepEqual(firestore.read('productPriceAudits/price-coffee-001'), {
    productId: 'product-coffee',
    previousAuditId: null,
    oldPricing: null,
    newPricing: result.pricing,
    changedAt: FIXED_TIME,
    actorId: 'admin-1',
  });
});

test('distinguishes additional-on-invoice, zero-rated, and exempt policies', async () => {
  const zero = setup();
  await zero.setPrice(request({
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'zero-rated',
    ivaRatePercent: '0',
  }));
  assert.deepEqual(zero.firestore.read('products/product-coffee').pricing, {
    listedPriceCentavos: 99_950,
    currency: 'MXN',
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'zero-rated',
    ivaRateBasisPoints: 0,
  });

  const exempt = setup();
  await exempt.setPrice(request({ ivaTreatment: 'exempt', ivaRatePercent: null }));
  assert.equal(
    exempt.firestore.read('products/product-coffee').pricing.ivaRateBasisPoints,
    null,
  );
});

test('accepts exact MXN centavos only and validates treatment-rate combinations', async () => {
  const { setPrice } = setup();

  for (const overrides of [
    { listedPriceMxn: 100 },
    { listedPriceMxn: '-1.00' },
    { listedPriceMxn: '1.001' },
    { listedPriceMxn: '01.00' },
    { priceMode: 'threshold-selected' },
    { ivaTreatment: 'taxable', ivaRatePercent: '0' },
    { ivaTreatment: 'taxable', ivaRatePercent: '16.001' },
    { ivaTreatment: 'zero-rated', ivaRatePercent: '16' },
    { ivaTreatment: 'exempt', ivaRatePercent: '0' },
  ]) {
    await rejectsCode(() => setPrice(request(overrides)), 'invalid-argument');
  }
});

test('updates existing pricing with immutable old and new audit snapshots', async () => {
  const oldPricing = {
    listedPriceCentavos: 80_000,
    currency: 'MXN',
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 800,
  };
  const { firestore, setPrice } = setup({ pricing: oldPricing });

  await setPrice(request());

  const audit = firestore.read('productPriceAudits/price-coffee-001');
  assert.deepEqual(audit.oldPricing, oldPricing);
  assert.equal(audit.newPricing.listedPriceCentavos, 99_950);
  oldPricing.listedPriceCentavos = 1;
  assert.equal(audit.oldPricing.listedPriceCentavos, 80_000);
});

test('replays identical retries and rejects conflicting idempotency reuse', async () => {
  const { firestore, setPrice } = setup();

  await setPrice(request());
  const replay = await setPrice(request());

  assert.equal(replay.replayed, true);
  assert.equal(firestore.read('productPriceAudits/price-coffee-001').actorId, 'admin-1');
  await rejectsCode(
    () => setPrice(request({ listedPriceMxn: '1000.00' })),
    'already-exists',
  );
});

test('serializes identical concurrent updates into an explicit audit chain', async () => {
  const { firestore, setPrice } = setup();

  await Promise.all([
    setPrice(request({ idempotencyKey: 'price-a', listedPriceMxn: '800.00' })),
    setPrice(request({ idempotencyKey: 'price-b', listedPriceMxn: '800.00' })),
  ]);

  const audits = new Map([
    ['price-a', firestore.read('productPriceAudits/price-a')],
    ['price-b', firestore.read('productPriceAudits/price-b')],
  ]);
  const first = [...audits].find(([, audit]) => audit.previousAuditId === null);
  const second = [...audits].find(([, audit]) => audit.previousAuditId !== null);
  assert.ok(first);
  assert.ok(second);
  assert.equal(second[1].previousAuditId, first[0]);
  assert.equal(
    firestore.read('products/product-coffee').lastPricingAuditId,
    second[0],
  );
  assert.deepEqual(first[1].newPricing, second[1].newPricing);
});

test('rejects missing products and malformed existing pricing', async () => {
  const emptyFirestore = new MemoryFirestore();
  const missingService = createProductPricingService({ firestore: emptyFirestore });
  await rejectsCode(() => missingService(request()), 'not-found');

  const malformed = setup({ pricing: { listedPriceCentavos: 100 } });
  await rejectsCode(() => malformed.setPrice(request()), 'failed-precondition');

  const invalidPointer = setup({ lastPricingAuditId: 42 });
  await rejectsCode(() => invalidPointer.setPrice(request()), 'failed-precondition');
});

test('local guard and callable remain restricted to the demo emulator', async () => {
  assert.doesNotThrow(() => assertLocalPricingEmulator({
    GCLOUD_PROJECT: 'demo-lda-inventory',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }));
  assert.throws(() => assertLocalPricingEmulator({
    GCLOUD_PROJECT: 'production',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }), /local emulator/);

  const { setProductPrice } = await import('../src/index.js');
  assert.deepEqual(
    await preflightOrigins(setProductPrice, ['http://localhost:5000', 'https://example.com']),
    ['http://localhost:5000', null],
  );
  await assert.rejects(() => setProductPrice.run(request()), (error) => {
    assert.ok(error instanceof HttpsError);
    assert.equal(error.code, 'failed-precondition');
    return true;
  });
});
