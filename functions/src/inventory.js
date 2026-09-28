import {
  addStockMovement,
  createQuantitySpec,
  parseQuantity,
} from './quantity.js';

export const CALCULATION_POLICY_VERSION = 'mxn-unit-cost-truncate-v1';

const DEMO_PROJECT_ID = 'demo-lda-inventory';
const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const MONEY_PATTERN = /^(?:0|[1-9]\d*)(?:\.(\d{1,2}))?$/;
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);

export class InventoryError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'InventoryError';
    this.code = code;
  }
}

/**
 * Fail closed unless the callable is running against the dedicated local demo
 * project. This is intentionally checked at invocation time so module loading
 * cannot accidentally connect Admin Firestore to a cloud project.
 */
export function assertLocalInventoryEmulator(environment = process.env) {
  if (
    environment.GCLOUD_PROJECT !== DEMO_PROJECT_ID
    || environment.FUNCTIONS_EMULATOR !== 'true'
    || typeof environment.FIRESTORE_EMULATOR_HOST !== 'string'
    || environment.FIRESTORE_EMULATOR_HOST.length === 0
  ) {
    throw new Error(
      'stock intake is available only in the demo-lda-inventory local emulator',
    );
  }
}

/**
 * Build the transaction service around an Admin Firestore-compatible object.
 * Injection keeps the complete business contract runnable on host Node 26,
 * which is newer than the currently supported Cloud Functions Node runtimes.
 */
export function createStockIntakeService({ firestore, now = () => new Date() } = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') {
    throw new TypeError('now must be a function');
  }

  return async function stockIntake(request = {}) {
    const actorId = authorizeAdministrator(request.auth);
    const input = validateRequest(request.data);
    const receiptReference = firestore.doc(`stockIntakeReceipts/${input.idempotencyKey}`);

    return firestore.runTransaction(async (transaction) => {
      const receiptSnapshot = await transaction.get(receiptReference);
      if (receiptSnapshot.exists) {
        return replayReceipt(receiptSnapshot.data(), input.fingerprint);
      }

      const branchReference = firestore.doc(`branches/${input.branchId}`);
      const productReference = firestore.doc(`products/${input.productId}`);
      const stockReference = firestore.doc(
        `branches/${input.branchId}/stock/${input.productId}`,
      );
      const [branchSnapshot, productSnapshot, stockSnapshot] = await Promise.all([
        transaction.get(branchReference),
        transaction.get(productReference),
        transaction.get(stockReference),
      ]);

      if (!branchSnapshot.exists) {
        throw new InventoryError('not-found', 'branch does not exist');
      }
      if (!productSnapshot.exists) {
        throw new InventoryError('not-found', 'product does not exist');
      }

      const spec = productQuantitySpec(productSnapshot.data());
      const quantityScaled = intakeQuantity(input.quantity, spec);
      const currentStock = currentStockQuantity(stockSnapshot, spec);
      const stockQuantityScaled = projectedStock(currentStock, quantityScaled, spec);
      const lineTotalCentavos = calculateLineTotal(
        quantityScaled,
        input.unitCostCentavos,
        spec.precision,
      );
      const timestamp = now();
      const result = {
        entryId: input.idempotencyKey,
        movementId: input.idempotencyKey,
        quantityScaled,
        stockQuantityScaled,
        unitCostCentavos: input.unitCostCentavos,
        lineTotalCentavos,
      };

      transaction.create(
        firestore.doc(`stockIntakeEntries/${input.idempotencyKey}`),
        {
          branchId: input.branchId,
          productId: input.productId,
          quantityScaled,
          ...spec,
          unitCostCentavos: input.unitCostCentavos,
          lineTotalCentavos,
          currency: 'MXN',
          calculationPolicyVersion: CALCULATION_POLICY_VERSION,
          createdAt: timestamp,
          createdBy: actorId,
        },
      );
      transaction.create(
        firestore.doc(`inventoryMovements/${input.idempotencyKey}`),
        {
          type: 'stock-intake',
          branchId: input.branchId,
          productId: input.productId,
          quantityScaled,
          ...spec,
          entryId: input.idempotencyKey,
          occurredAt: timestamp,
          actorId,
        },
      );
      transaction.set(stockReference, {
        quantityScaled: stockQuantityScaled,
        ...spec,
        updatedAt: timestamp,
        lastMovementId: input.idempotencyKey,
      });
      transaction.set(firestore.doc(`costs/${input.productId}`), {
        latestUnitCostCentavos: input.unitCostCentavos,
        currency: 'MXN',
        sourceEntryId: input.idempotencyKey,
        updatedAt: timestamp,
      });
      transaction.create(receiptReference, {
        fingerprint: input.fingerprint,
        result,
        completedAt: timestamp,
        actorId,
      });

      return { ...result, replayed: false };
    });
  };
}

function authorizeAdministrator(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new InventoryError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'administrator') {
    throw new InventoryError('permission-denied', 'administrator role is required');
  }
  return auth.uid;
}

function validateRequest(data) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw new InventoryError('invalid-argument', 'request data is required');
  }

  const idempotencyKey = validId(data.idempotencyKey, 'idempotency key');
  const branchId = validId(data.branchId, 'branch ID');
  const productId = validId(data.productId, 'product ID');
  if (typeof data.quantity !== 'string') {
    throw new InventoryError('invalid-argument', 'quantity must be a decimal string');
  }
  const unitCostCentavos = parseMxn(data.unitCostMxn);
  const fingerprint = JSON.stringify({
    branchId,
    productId,
    quantity: data.quantity,
    unitCostCentavos,
  });

  return {
    idempotencyKey,
    branchId,
    productId,
    quantity: data.quantity,
    unitCostCentavos,
    fingerprint,
  };
}

function validId(value, label) {
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new InventoryError(
      'invalid-argument',
      `${label} must be a valid identifier of 1 to 128 characters`,
    );
  }
  return value;
}

function parseMxn(value) {
  if (typeof value !== 'string' || value.length > 17 || !MONEY_PATTERN.test(value)) {
    throw new InventoryError(
      'invalid-argument',
      'unit cost must be nonnegative MXN with at most two decimal places',
    );
  }

  const [whole, fraction = ''] = value.split('.');
  const centavos = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
  return safeNumber(centavos, 'unit cost');
}

function productQuantitySpec(product) {
  try {
    return createQuantitySpec(product?.quantitySpec);
  } catch {
    throw new InventoryError(
      'failed-precondition',
      'product has an invalid quantity specification',
    );
  }
}

function intakeQuantity(quantity, spec) {
  try {
    const scaled = parseQuantity(quantity, spec);
    if (scaled <= 0) {
      throw new Error('not positive');
    }
    return scaled;
  } catch {
    throw new InventoryError(
      'invalid-argument',
      'quantity must be positive and representable by the product specification',
    );
  }
}

function currentStockQuantity(snapshot, spec) {
  if (!snapshot.exists) {
    return 0;
  }

  const stock = snapshot.data();
  if (
    stock?.unit !== spec.unit
    || stock?.precision !== spec.precision
    || !Number.isSafeInteger(stock?.quantityScaled)
    || stock.quantityScaled < 0
  ) {
    throw new InventoryError('failed-precondition', 'stock projection is invalid');
  }
  return stock.quantityScaled;
}

function projectedStock(current, quantity, spec) {
  try {
    return addStockMovement(current, quantity, spec, spec);
  } catch {
    throw new InventoryError('out-of-range', 'stock projection exceeds safe bounds');
  }
}

function calculateLineTotal(quantityScaled, unitCostCentavos, precision) {
  const scale = 10n ** BigInt(precision);
  const total = (BigInt(quantityScaled) * BigInt(unitCostCentavos)) / scale;
  return safeNumber(total, 'line total');
}

function safeNumber(value, label) {
  if (value < 0n || value > MAX_SAFE_BIGINT) {
    throw new InventoryError('out-of-range', `${label} exceeds safe integer bounds`);
  }
  return Number(value);
}

function replayReceipt(receipt, fingerprint) {
  if (receipt?.fingerprint !== fingerprint) {
    throw new InventoryError(
      'already-exists',
      'idempotency key was already used for a different request',
    );
  }
  if (receipt.result === null || typeof receipt.result !== 'object') {
    throw new InventoryError('failed-precondition', 'idempotency receipt is invalid');
  }
  return { ...receipt.result, replayed: true };
}
