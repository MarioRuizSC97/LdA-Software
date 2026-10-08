import { assertCorrectionWindow, calculateRemainingReturnable } from './corrections-calculation.js';
import { createQuantitySpec } from './quantity.js';
import { isOwnBranchSale, validateStoredSale } from './sale-lookup.js';
import { SaleError } from './sales.js';

/**
 * Shared trusted-input, persisted-state and replay helpers for the sale
 * correction services (returns, replacements). Pure apart from the passed
 * transaction; every domain failure is a SaleError and nothing is written here.
 */

const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const STOCK_FIELDS = ['quantityScaled', 'unit', 'precision'];
// The sale, return, replacement and intake writers all set exactly this shape.
const WRITTEN_STOCK_FIELDS = [...STOCK_FIELDS, 'updatedAt', 'lastMovementId'];
// provision-demo-identities seeds stock with only a seed-version marker.
const SEEDED_STOCK_FIELDS = [...STOCK_FIELDS, 'demoSeedVersion'];
export const CORRECTION_NOTE_MAX_LENGTH = 500;

// Mirrors sales.js saleSeller: administrators and every other role are denied.
export function correctionSeller(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new SaleError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'seller' || !validId(auth.token?.branchId)) {
    throw new SaleError('permission-denied', 'an assigned seller is required');
  }
  return { actorId: auth.uid, branchId: auth.token.branchId };
}

// The note is optional free text, but never blank, padded or unbounded.
// Throws TypeError so each service maps it into its own invalid-argument.
export function optionalNote(data) {
  if (!Object.hasOwn(data, 'note')) return null;
  const { note } = data;
  if (typeof note !== 'string' || note.length === 0 || note.trim() !== note
    || note.length > CORRECTION_NOTE_MAX_LENGTH) {
    throw new TypeError('note must be trimmed nonempty bounded text');
  }
  return note;
}

// Precision and safe scaled bounds require the stored sale snapshot later.
export function canonicalQuantity(value) {
  return typeof value === 'string' && value.length <= 18
    && /^(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value) && /[1-9]/.test(value);
}

// Canonical decimals compare by value: a stored '0.500' equals a requested '0.5'.
export function sameDecimal(left, right) {
  const normal = (value) => (value.includes('.') ? value.replace(/\.?0+$/, '') : value);
  return canonicalQuantity(left) && canonicalQuantity(right) && normal(left) === normal(right);
}

export function invocationTime(now, message) {
  try {
    const value = now();
    if (value instanceof Date && Number.isSafeInteger(value.getTime()) && value.getTime() >= 0) {
      return { ms: value.getTime(), timestamp: new Date(value.getTime()) };
    }
  } catch {
    // A failing clock surfaces as the same domain error as an invalid one.
  }
  return { error: new SaleError('failed-precondition', message) };
}

// Missing and foreign sales share one answer: existence never leaks.
export async function correctableSale(transaction, firestore, saleId, branchId, nowMs) {
  const snapshot = await transaction.get(firestore.doc(`sales/${saleId}`));
  const record = snapshot.exists ? snapshot.data() : undefined;
  if (!isOwnBranchSale(record, branchId)) {
    throw new SaleError('not-found', 'sale was not found in this branch');
  }
  const sale = validateStoredSale(saleId, record);
  try {
    assertCorrectionWindow(sale.createdAt, nowMs);
  } catch {
    throw new SaleError('failed-precondition', 'sale is outside the correction window');
  }
  return sale;
}

// The ledger is server-written only: anything but the exact shape fails closed.
export function storedReturnLedger(snapshot, sale) {
  if (!snapshot.exists) return {};
  try {
    const value = snapshot.data();
    exactFields(value, ['returned', 'lastReturnId', 'updatedAt']);
    if (!validId(value.lastReturnId) || !validTimestamp(value.updatedAt)) {
      throw new TypeError('ledger provenance');
    }
    calculateRemainingReturnable({ lines: sale.calculation.lines, returned: value.returned });
    return { ...value.returned };
  } catch {
    throw new SaleError('failed-precondition', 'persisted sale return ledger is invalid');
  }
}

export function storedProductSpec(snapshot) {
  try {
    if (!snapshot.exists) throw new TypeError('missing product');
    const value = snapshot.data()?.quantitySpec;
    exactFields(value, ['unit', 'precision']);
    return createQuantitySpec(value);
  } catch {
    throw new SaleError('failed-precondition', 'product quantity specification is invalid');
  }
}

// Reads only a known projection shape, because the correction writers replace
// the whole document: an unknown field fails closed instead of being dropped.
export function stockProjection(snapshot, spec) {
  if (!snapshot.exists) return 0;
  const value = snapshot.data();
  const shapes = [STOCK_FIELDS, WRITTEN_STOCK_FIELDS, SEEDED_STOCK_FIELDS];
  if (!shapes.some((fields) => hasExactFields(value, fields))
    || value.unit !== spec.unit || value.precision !== spec.precision
    || !Number.isSafeInteger(value.quantityScaled) || value.quantityScaled < 0
    || (Object.hasOwn(value, 'updatedAt')
      && (!validTimestamp(value.updatedAt) || typeof value.lastMovementId !== 'string'
        || value.lastMovementId.length === 0))) {
    throw new SaleError('failed-precondition', 'stock projection is invalid');
  }
  return value.quantityScaled;
}

// Every create target is read first: without a submission receipt, an
// existing target is an orphaned collision, refused before any write.
export async function assertCreateTargetsAbsent(transaction, references) {
  const snapshots = await Promise.all(references.map((reference) => transaction.get(reference)));
  if (snapshots.some((snapshot) => snapshot.exists)) {
    throw new SaleError('already-exists', 'idempotency key collides with existing correction records');
  }
}

// Ownership is checked before touching private result fields; a collision
// never reveals another seller's receipt or moves stock again.
export function assertReplayOwner(record, actorId, branchId, fingerprint) {
  if (record?.actorId !== actorId || record?.branchId !== branchId || record?.fingerprint !== fingerprint) {
    throw new SaleError('already-exists', 'idempotency key is already owned by a different submission');
  }
}

// Throws TypeError so each service maps it into its own replay error.
export function storedReplayResult(record) {
  exactFields(record, ['actorId', 'branchId', 'fingerprint', 'result', 'completedAt']);
  if (!validTimestamp(record.completedAt)) throw new TypeError('completedAt');
  return record.result;
}

export function validTimestamp(value) {
  // Admin reads Date writes back as Timestamp; accept both without the SDK.
  try {
    const date = value instanceof Date
      ? value
      : typeof value?.toDate === 'function' ? value.toDate() : null;
    return date instanceof Date && Number.isFinite(date.getTime());
  } catch {
    return false;
  }
}

export function validId(value) {
  return typeof value === 'string' && ID_PATTERN.test(value);
}

export function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasExactFields(value, expected) {
  try {
    exactFields(value, expected);
    return true;
  } catch {
    return false;
  }
}

export function exactFields(value, expected) {
  if (!plainObject(value)) throw new TypeError('an object is required');
  const fields = Reflect.ownKeys(value);
  if (fields.length !== expected.length || fields.some((field) => !expected.includes(field))) {
    throw new TypeError('missing or unsupported fields');
  }
}

export function denseArray(value) {
  if (!Array.isArray(value) || Reflect.ownKeys(value).length !== value.length + 1) {
    throw new TypeError('a dense array without extra fields is required');
  }
  for (let index = 0; index < value.length; index++) {
    if (!Object.hasOwn(value, index)) throw new TypeError('sparse array');
  }
}
