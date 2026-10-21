import {
  CatalogError,
  assertLocalCatalogEmulator,
} from './catalog.js';

const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const MAX_PRODUCT_NAME_LENGTH = 120;
const REQUEST_FIELDS = ['idempotencyKey', 'name', 'productId'];

export { CatalogError, assertLocalCatalogEmulator };

/**
 * Build the atomic product-rename service around an Admin Firestore instance.
 *
 * Administrators may change only the product name. Internal codes, quantity
 * specifications, pricing, stock and historical sales keep the values they
 * already have; the private receipt keeps the old/new names and the actor.
 */
export function createProductRenameService({ firestore, now = () => new Date() } = {}) {
  if (
    !firestore
    || typeof firestore.doc !== 'function'
    || typeof firestore.runTransaction !== 'function'
  ) {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') {
    throw new TypeError('now must be a function');
  }

  return async function renameProduct(request = {}) {
    const actorId = authorizeAdministrator(request.auth);
    const input = validateRequest(request.data, actorId);
    const productReference = firestore.doc(`products/${input.productId}`);
    const receiptReference = firestore.doc(
      `productNameUpdateReceipts/${input.idempotencyKey}`,
    );

    return firestore.runTransaction(async (transaction) => {
      const receiptSnapshot = await transaction.get(receiptReference);
      if (receiptSnapshot.exists) {
        return replayReceipt(receiptSnapshot.data(), input.fingerprint);
      }

      const productSnapshot = await transaction.get(productReference);
      if (!productSnapshot.exists) {
        throw new CatalogError('not-found', 'product does not exist');
      }
      const oldName = productSnapshot.data().name;
      const timestamp = now();
      const result = {
        productId: input.productId,
        oldName,
        newName: input.name,
      };

      transaction.update(productReference, { name: input.name });
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

  const idempotencyKey = validId(data.idempotencyKey, 'idempotency key');
  const productId = validId(data.productId, 'product ID');
  const name = validProductName(data.name);
  const fingerprint = JSON.stringify({ actorId, productId, name });

  return { idempotencyKey, productId, name, fingerprint };
}

function validId(value, label) {
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new CatalogError(
      'invalid-argument',
      `${label} must be a valid identifier of 1 to 128 characters`,
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
    || typeof receipt.result.productId !== 'string'
    || typeof receipt.result.oldName !== 'string'
    || typeof receipt.result.newName !== 'string'
  ) {
    throw new CatalogError('failed-precondition', 'idempotency receipt is invalid');
  }
  return { ...receipt.result, replayed: true };
}
