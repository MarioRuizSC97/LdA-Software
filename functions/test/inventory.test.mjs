import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CALCULATION_POLICY_VERSION,
  InventoryError,
  assertLocalInventoryEmulator,
  createStockIntakeService,
} from '../src/inventory.js';

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
      set: ({ path }, data) => {
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
      idempotencyKey: 'intake-001',
      branchId: 'branch-north',
      productId: 'product-coffee',
      quantity: '2',
      unitCostMxn: '71.25',
      ...overrides,
    },
  };
}

function setup({
  precision = 0,
  unit = 'piece',
  stock = 3,
  branchExists = true,
} = {}) {
  const firestore = new MemoryFirestore();
  firestore.seed('products/product-coffee', {
    name: 'Coffee',
    quantitySpec: { unit, precision },
  });
  if (branchExists) {
    firestore.seed('branches/branch-north', { name: 'North' });
    firestore.seed('branches/branch-north/stock/product-coffee', {
      quantityScaled: stock,
      unit,
      precision,
    });
  }

  return {
    firestore,
    intake: createStockIntakeService({
      firestore,
      now: () => FIXED_TIME,
    }),
  };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof InventoryError);
    assert.equal(error.code, code);
    return true;
  });
}

test('requires an authenticated administrator before starting a transaction', async () => {
  const { intake } = setup();

  await rejectsCode(() => intake({ ...request(), auth: null }), 'unauthenticated');
  await rejectsCode(
    () => intake({ ...request(), auth: { uid: 'seller-1', token: { role: 'seller' } } }),
    'permission-denied',
  );
});

test('writes one immutable intake, movement, stock projection, and protected latest cost', async () => {
  const { firestore, intake } = setup();

  const result = await intake(request());

  assert.deepEqual(result, {
    entryId: 'intake-001',
    movementId: 'intake-001',
    quantityScaled: 2,
    stockQuantityScaled: 5,
    unitCostCentavos: 7_125,
    lineTotalCentavos: 14_250,
    replayed: false,
  });
  assert.deepEqual(firestore.read('stockIntakeEntries/intake-001'), {
    branchId: 'branch-north',
    productId: 'product-coffee',
    quantityScaled: 2,
    unit: 'piece',
    precision: 0,
    unitCostCentavos: 7_125,
    lineTotalCentavos: 14_250,
    currency: 'MXN',
    calculationPolicyVersion: CALCULATION_POLICY_VERSION,
    createdAt: FIXED_TIME,
    createdBy: 'admin-1',
  });
  assert.deepEqual(firestore.read('inventoryMovements/intake-001'), {
    type: 'stock-intake',
    branchId: 'branch-north',
    productId: 'product-coffee',
    quantityScaled: 2,
    unit: 'piece',
    precision: 0,
    entryId: 'intake-001',
    occurredAt: FIXED_TIME,
    actorId: 'admin-1',
  });
  assert.deepEqual(firestore.read('branches/branch-north/stock/product-coffee'), {
    quantityScaled: 5,
    unit: 'piece',
    precision: 0,
    updatedAt: FIXED_TIME,
    lastMovementId: 'intake-001',
  });
  assert.deepEqual(firestore.read('costs/product-coffee'), {
    latestUnitCostCentavos: 7_125,
    currency: 'MXN',
    sourceEntryId: 'intake-001',
    updatedAt: FIXED_TIME,
  });
});

test('rejects a nonexistent branch without creating orphan inventory records', async () => {
  const { firestore, intake } = setup({ branchExists: false });

  await rejectsCode(() => intake(request()), 'not-found');

  assert.equal(firestore.read('branches/branch-north/stock/product-coffee'), undefined);
  assert.equal(firestore.read('stockIntakeEntries/intake-001'), undefined);
  assert.equal(firestore.read('inventoryMovements/intake-001'), undefined);
  assert.equal(firestore.read('costs/product-coffee'), undefined);
  assert.equal(firestore.read('stockIntakeReceipts/intake-001'), undefined);
});

test('replays an identical idempotency key and rejects a mismatched request', async () => {
  const { firestore, intake } = setup();

  await intake(request());
  const replay = await intake(request());

  assert.equal(replay.replayed, true);
  assert.equal(replay.stockQuantityScaled, 5);
  assert.equal(firestore.read('branches/branch-north/stock/product-coffee').quantityScaled, 5);

  await rejectsCode(
    () => intake(request({ quantity: '3' })),
    'already-exists',
  );
});

test('uses exact fractional arithmetic and truncates line totals toward zero', async () => {
  const { firestore, intake } = setup({ precision: 3, unit: 'kg', stock: 500 });

  const result = await intake(request({ quantity: '0.333', unitCostMxn: '10.01' }));

  assert.equal(result.quantityScaled, 333);
  assert.equal(result.unitCostCentavos, 1_001);
  assert.equal(result.lineTotalCentavos, 333);
  assert.equal(
    firestore.read('stockIntakeEntries/intake-001').calculationPolicyVersion,
    CALCULATION_POLICY_VERSION,
  );
});

test('serializes concurrent intake transactions without losing stock', async () => {
  const { firestore, intake } = setup();

  await Promise.all([
    intake(request({ idempotencyKey: 'intake-a', quantity: '4' })),
    intake(request({ idempotencyKey: 'intake-b', quantity: '7' })),
  ]);

  assert.equal(firestore.read('branches/branch-north/stock/product-coffee').quantityScaled, 14);
});

test('validates product quantity specifications and positive representable quantities', async () => {
  const malformed = setup();
  malformed.firestore.seed('products/product-coffee', {
    quantitySpec: { unit: 'Kg', precision: 7 },
  });

  await rejectsCode(() => malformed.intake(request()), 'failed-precondition');

  const { intake } = setup({ precision: 2, unit: 'kg' });
  await rejectsCode(() => intake(request({ quantity: '0' })), 'invalid-argument');
  await rejectsCode(() => intake(request({ quantity: '-1' })), 'invalid-argument');
  await rejectsCode(() => intake(request({ quantity: '1.001' })), 'invalid-argument');
});

test('accepts only nonnegative MXN input with at most two decimal places', async () => {
  const { intake } = setup();

  await rejectsCode(() => intake(request({ unitCostMxn: '-0.01' })), 'invalid-argument');
  await rejectsCode(() => intake(request({ unitCostMxn: '1.001' })), 'invalid-argument');
  await rejectsCode(() => intake(request({ unitCostMxn: 1.25 })), 'invalid-argument');
});

test('rejects safe-integer overflow in line totals and stock projections', async () => {
  const lineTotal = setup({ precision: 0, stock: 0 });
  await rejectsCode(
    () => lineTotal.intake(request({ quantity: '9007199254740991', unitCostMxn: '0.02' })),
    'out-of-range',
  );

  const stock = setup({ precision: 0, stock: Number.MAX_SAFE_INTEGER });
  await rejectsCode(
    () => stock.intake(request({ quantity: '1', unitCostMxn: '0.00' })),
    'out-of-range',
  );
});

test('local executable exports the guarded callable without initializing Admin Firestore', async () => {
  const { stockIntake } = await import('../src/index.js');
  assert.equal(typeof stockIntake, 'function');
});

test('local execution guard requires the demo project and both emulator markers', () => {
  assert.doesNotThrow(() => assertLocalInventoryEmulator({
    GCLOUD_PROJECT: 'demo-lda-inventory',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FUNCTIONS_EMULATOR: 'true',
  }));

  for (const environment of [
    { GCLOUD_PROJECT: 'production', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true' },
    { GCLOUD_PROJECT: 'demo-lda-inventory', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
  ]) {
    assert.throws(() => assertLocalInventoryEmulator(environment), /local emulator/);
  }
});
