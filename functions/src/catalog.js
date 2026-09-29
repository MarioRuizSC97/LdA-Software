import { randomUUID } from 'node:crypto';

import { createQuantitySpec } from './quantity.js';

const DEMO_PROJECT_ID = 'demo-lda-inventory';
const INTERNAL_CODE_PATTERN = /^[A-Z][A-Z0-9-]{7,63}$/;
const IDEMPOTENCY_KEY_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const MAX_PRODUCT_NAME_LENGTH = 120;
const DEFAULT_CODE_ATTEMPTS = 5;
const REQUEST_FIELDS = ['idempotencyKey', 'name', 'quantitySpec'];
const QUANTITY_SPEC_FIELDS = ['precision', 'unit'];

export class CatalogError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'CatalogError';
    this.code = code;
  }
}

/** Fail closed before Admin SDK initialization outside the dedicated emulator. */
export function assertLocalCatalogEmulator(environment = process.env) {
  if (
    environment.GCLOUD_PROJECT !== DEMO_PROJECT_ID
    || environment.FUNCTIONS_EMULATOR !== 'true'
    || typeof environment.FIRESTORE_EMULATOR_HOST !== 'string'
    || environment.FIRESTORE_EMULATOR_HOST.length === 0
  ) {
    throw new Error(
      'product creation is available only in the demo-lda-inventory local emulator',
    );
  }
}

/**
 * Build an Admin Firestore product-creation service.
 *
 * The generated internal code is both the immutable product ID and the future QR
 * payload identity. No QR image or scanner is created by this service.
 */
export function createProductCreationService({
  firestore,
  now = () => new Date(),
  generateInternalCode = defaultInternalCode,
  maxCodeAttempts = DEFAULT_CODE_ATTEMPTS,
} = {}) {
  if (
    !firestore
    || typeof firestore.doc !== 'function'
    || typeof firestore.runTransaction !== 'function'
  ) {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function' || typeof generateInternalCode !== 'function') {
    throw new TypeError('time and internal-code generators must be functions');
  }
  if (!Number.isInteger(maxCodeAttempts) || maxCodeAttempts < 1 || maxCodeAttempts > 20) {
    throw new RangeError('maxCodeAttempts must be an integer from 1 through 20');
  }

  return async function createProduct(request = {}) {
    const actorId = authorizeAdministrator(request.auth);
    const input = validateRequest(request.data, actorId);
    const receiptReference = firestore.doc(
      `productCreationReceipts/${input.idempotencyKey}`,
    );
    const replay = await firestore.runTransaction(async (transaction) => {
      const receiptSnapshot = await transaction.get(receiptReference);
      return receiptSnapshot.exists
        ? replayReceipt(receiptSnapshot.data(), input.fingerprint)
        : null;
    });
    if (replay !== null) {
      return replay;
    }

    for (let attempt = 0; attempt < maxCodeAttempts; attempt += 1) {
      const internalCode = generatedCode(generateInternalCode());
      const productReference = firestore.doc(`products/${internalCode}`);
      const outcome = await firestore.runTransaction(async (transaction) => {
        const [receiptSnapshot, productSnapshot] = await Promise.all([
          transaction.get(receiptReference),
          transaction.get(productReference),
        ]);

        if (receiptSnapshot.exists) {
          return replayReceipt(receiptSnapshot.data(), input.fingerprint);
        }
        if (productSnapshot.exists) {
          return { collision: true };
        }

        const timestamp = now();
        const result = { productId: internalCode, internalCode };
        transaction.create(productReference, {
          internalCode,
          name: input.name,
          quantitySpec: input.quantitySpec,
          createdAt: timestamp,
        });
        transaction.create(receiptReference, {
          fingerprint: input.fingerprint,
          result,
          completedAt: timestamp,
          actorId,
        });
        return { ...result, replayed: false };
      });

      if (!outcome.collision) {
        return outcome;
      }
    }

    throw new CatalogError(
      'resource-exhausted',
      'could not allocate a unique internal product code',
    );
  };
}

function authorizeAdministrator(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new CatalogError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'administrator') {
    throw new CatalogError('permission-denied', 'administrator role is required');
  }
  return auth.uid;
}

function validateRequest(data, actorId) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw new CatalogError('invalid-argument', 'request data is required');
  }
  assertExactFields(data, REQUEST_FIELDS, 'request');

  const idempotencyKey = validIdempotencyKey(data.idempotencyKey);
  const name = validProductName(data.name);
  const quantitySpec = validQuantitySpec(data.quantitySpec);
  const fingerprint = JSON.stringify({ actorId, name, quantitySpec });

  return { idempotencyKey, name, quantitySpec, fingerprint };
}

function validIdempotencyKey(value) {
  if (typeof value !== 'string' || !IDEMPOTENCY_KEY_PATTERN.test(value)) {
    throw new CatalogError(
      'invalid-argument',
      'idempotency key must be a valid identifier of 1 to 128 characters',
    );
  }
  return value;
}

function validProductName(value) {
  if (
    typeof value !== 'string'
    || value.length === 0
    || value.length > MAX_PRODUCT_NAME_LENGTH
    || value.trim() !== value
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new CatalogError(
      'invalid-argument',
      `name must be canonical text of 1 to ${MAX_PRODUCT_NAME_LENGTH} characters`,
    );
  }
  return value;
}

function validQuantitySpec(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new CatalogError('invalid-argument', 'quantity specification is required');
  }
  assertExactFields(value, QUANTITY_SPEC_FIELDS, 'quantity specification');

  try {
    return createQuantitySpec({ unit: value.unit, precision: value.precision });
  } catch {
    throw new CatalogError(
      'invalid-argument',
      'quantity specification must contain a valid unit and precision',
    );
  }
}

function assertExactFields(value, expected, label) {
  const actual = Object.keys(value).sort();
  if (
    actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])
  ) {
    throw new CatalogError(
      'invalid-argument',
      `${label} contains missing or unsupported fields`,
    );
  }
}

function generatedCode(value) {
  if (typeof value !== 'string' || !INTERNAL_CODE_PATTERN.test(value)) {
    throw new CatalogError('internal', 'internal product code generation failed');
  }
  return value;
}

function defaultInternalCode() {
  return `PRD-${randomUUID().replaceAll('-', '').toUpperCase()}`;
}

function replayReceipt(receipt, fingerprint) {
  if (receipt?.fingerprint !== fingerprint) {
    throw new CatalogError(
      'already-exists',
      'idempotency key was already used for a different request',
    );
  }
  if (
    receipt.result === null
    || typeof receipt.result !== 'object'
    || receipt.result.productId !== receipt.result.internalCode
    || !INTERNAL_CODE_PATTERN.test(receipt.result.internalCode)
  ) {
    throw new CatalogError('failed-precondition', 'idempotency receipt is invalid');
  }
  return { ...receipt.result, replayed: true };
}
