import { isDeployedProjectRuntime } from './runtime-project.js';

const DEMO_PROJECT_ID = 'demo-lda-inventory';
const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const MONEY_PATTERN = /^(?:0|[1-9]\d*)(?:\.(\d{1,2}))?$/;
const RATE_PATTERN = /^(?:0|[1-9]\d?)(?:\.(\d{1,2}))?$|^100(?:\.0{1,2})?$/;
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const REQUEST_FIELDS = [
  'idempotencyKey',
  'ivaRatePercent',
  'ivaTreatment',
  'listedPriceMxn',
  'priceMode',
  'productId',
];
const PRICE_MODES = new Set(['iva-included', 'iva-additional-on-invoice']);
const IVA_TREATMENTS = new Set(['taxable', 'zero-rated', 'exempt']);
const PRICING_FIELDS = [
  'currency',
  'ivaRateBasisPoints',
  'ivaTreatment',
  'listedPriceCentavos',
  'priceMode',
];

export class PricingError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'PricingError';
    this.code = code;
  }
}

/** Fail closed before Admin SDK initialization outside the dedicated emulator. */
export function assertLocalPricingEmulator(environment = process.env) {
  // The deployed production project is trusted as-is; see runtime-project.js.
  if (isDeployedProjectRuntime(environment)) return;
  if (
    environment.GCLOUD_PROJECT !== DEMO_PROJECT_ID
    || environment.FUNCTIONS_EMULATOR !== 'true'
    || typeof environment.FIRESTORE_EMULATOR_HOST !== 'string'
    || environment.FIRESTORE_EMULATOR_HOST.length === 0
  ) {
    throw new Error(
      'product pricing is available only in the demo-lda-inventory local emulator',
    );
  }
}

/**
 * Build the atomic product-pricing service around an Admin Firestore instance.
 * This stores policy only; it intentionally performs no tax or sale calculation.
 */
export function createProductPricingService({ firestore, now = () => new Date() } = {}) {
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

  return async function setProductPrice(request = {}) {
    const actorId = authorizeAdministrator(request.auth);
    const input = validateRequest(request.data, actorId);
    const productReference = firestore.doc(`products/${input.productId}`);
    const auditReference = firestore.doc(`productPriceAudits/${input.idempotencyKey}`);
    const receiptReference = firestore.doc(
      `productPriceUpdateReceipts/${input.idempotencyKey}`,
    );

    return firestore.runTransaction(async (transaction) => {
      const receiptSnapshot = await transaction.get(receiptReference);
      if (receiptSnapshot.exists) {
        return replayReceipt(receiptSnapshot.data(), input.fingerprint);
      }

      const productSnapshot = await transaction.get(productReference);
      if (!productSnapshot.exists) {
        throw new PricingError('not-found', 'product does not exist');
      }

      const product = productSnapshot.data();
      if (
        Object.hasOwn(product, 'createdBy')
        || Object.hasOwn(product, 'pricingUpdatedBy')
      ) {
        throw new PricingError(
          'failed-precondition',
          'product contains legacy actor provenance',
        );
      }
      const oldPricing = product.pricing === undefined
        ? null
        : validStoredPricing(product.pricing);
      const previousAuditId = validPreviousAuditId(product.lastPricingAuditId);
      const timestamp = now();
      const result = {
        auditId: input.idempotencyKey,
        productId: input.productId,
        pricing: input.pricing,
      };

      transaction.update(productReference, {
        pricing: input.pricing,
        pricingUpdatedAt: timestamp,
        lastPricingAuditId: input.idempotencyKey,
      });
      transaction.create(auditReference, {
        productId: input.productId,
        previousAuditId,
        oldPricing,
        newPricing: input.pricing,
        changedAt: timestamp,
        actorId,
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
    throw new PricingError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'administrator') {
    throw new PricingError('permission-denied', 'administrator role is required');
  }
  return auth.uid;
}

function validateRequest(data, actorId) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw new PricingError('invalid-argument', 'request data is required');
  }
  assertExactFields(data, REQUEST_FIELDS, 'request');

  const idempotencyKey = validId(data.idempotencyKey, 'idempotency key');
  const productId = validId(data.productId, 'product ID');
  const pricing = {
    listedPriceCentavos: parseMxn(data.listedPriceMxn),
    currency: 'MXN',
    priceMode: validEnum(data.priceMode, PRICE_MODES, 'price mode'),
    ivaTreatment: validEnum(data.ivaTreatment, IVA_TREATMENTS, 'IVA treatment'),
    ivaRateBasisPoints: parseIvaRate(data.ivaTreatment, data.ivaRatePercent),
  };
  const fingerprint = JSON.stringify({ actorId, productId, pricing });

  return { idempotencyKey, productId, pricing, fingerprint };
}

function validId(value, label) {
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new PricingError(
      'invalid-argument',
      `${label} must be a valid identifier of 1 to 128 characters`,
    );
  }
  return value;
}

function validEnum(value, allowed, label) {
  if (typeof value !== 'string' || !allowed.has(value)) {
    throw new PricingError('invalid-argument', `${label} is unsupported`);
  }
  return value;
}

function parseMxn(value) {
  if (typeof value !== 'string' || value.length > 17 || !MONEY_PATTERN.test(value)) {
    throw new PricingError(
      'invalid-argument',
      'listed price must be nonnegative MXN with at most two decimal places',
    );
  }

  const [whole, fraction = ''] = value.split('.');
  const centavos = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
  if (centavos > MAX_SAFE_BIGINT) {
    throw new PricingError('out-of-range', 'listed price exceeds safe integer bounds');
  }
  return Number(centavos);
}

function parseIvaRate(treatment, value) {
  if (treatment === 'exempt') {
    if (value !== null) {
      throw new PricingError(
        'invalid-argument',
        'exempt IVA treatment must use a null rate',
      );
    }
    return null;
  }
  if (typeof value !== 'string' || !RATE_PATTERN.test(value)) {
    throw new PricingError(
      'invalid-argument',
      'IVA rate must be a percent string with at most two decimal places',
    );
  }

  const [whole, fraction = ''] = value.split('.');
  const basisPoints = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  if (treatment === 'zero-rated' && basisPoints !== 0) {
    throw new PricingError('invalid-argument', 'zero-rated IVA must use a zero rate');
  }
  if (treatment === 'taxable' && basisPoints === 0) {
    throw new PricingError('invalid-argument', 'taxable IVA must use a positive rate');
  }
  return basisPoints;
}

function validPreviousAuditId(value) {
  if (value === undefined) return null;
  if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
    throw new PricingError(
      'failed-precondition',
      'existing product pricing audit pointer is invalid',
    );
  }
  return value;
}

function validStoredPricing(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new PricingError('failed-precondition', 'existing product pricing is invalid');
  }
  const fields = Object.keys(value).sort();
  if (
    fields.length !== PRICING_FIELDS.length
    || fields.some((field, index) => field !== PRICING_FIELDS[index])
    || value.currency !== 'MXN'
    || !Number.isSafeInteger(value.listedPriceCentavos)
    || value.listedPriceCentavos < 0
    || !PRICE_MODES.has(value.priceMode)
    || !IVA_TREATMENTS.has(value.ivaTreatment)
    || (value.ivaTreatment === 'exempt' && value.ivaRateBasisPoints !== null)
    || (value.ivaTreatment === 'zero-rated' && value.ivaRateBasisPoints !== 0)
    || (
      value.ivaTreatment === 'taxable'
      && (!Number.isInteger(value.ivaRateBasisPoints)
        || value.ivaRateBasisPoints < 1
        || value.ivaRateBasisPoints > 10_000)
    )
  ) {
    throw new PricingError('failed-precondition', 'existing product pricing is invalid');
  }
  return { ...value };
}

function assertExactFields(value, expected, label) {
  const actual = Object.keys(value).sort();
  if (
    actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])
  ) {
    throw new PricingError(
      'invalid-argument',
      `${label} contains missing or unsupported fields`,
    );
  }
}

function replayReceipt(receipt, fingerprint) {
  if (receipt?.fingerprint !== fingerprint) {
    throw new PricingError(
      'already-exists',
      'idempotency key was already used for a different request',
    );
  }
  if (
    receipt.result === null
    || typeof receipt.result !== 'object'
    || typeof receipt.result.auditId !== 'string'
    || typeof receipt.result.productId !== 'string'
  ) {
    throw new PricingError('failed-precondition', 'idempotency receipt is invalid');
  }
  return { ...receipt.result, replayed: true };
}
