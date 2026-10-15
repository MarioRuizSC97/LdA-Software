import { InventoryError, assertLocalInventoryEmulator } from './inventory.js';
import { denseArray, exactFields } from './correction-support.js';

/**
 * Destination transfer notice acknowledgement (DN-01).
 *
 * A seller confirms they have read one destination notice. The trusted callable
 * receives exactly `{ transferId }`; uid and branch always come from the
 * verified token claims, never from the payload or the client clock. Before any
 * marker is written, the private `transfers/{transferId}` audit is read
 * server-side and its destination branch must equal the caller's token branch:
 * a missing or foreign transfer shares one `not-found` answer, so audit
 * existence and content never leak to a seller.
 *
 * The marker lives at
 * `transferNoticeReads/{uid}/branches/{branchId}/transfers/{transferId}` and
 * carries exactly `userId`, `branchId`, `transferId` and `readAt` (server
 * Date). Replay is idempotent: an existing well-formed marker returns the same
 * acknowledgement without rewriting it, and the original `readAt` is preserved
 * even when today's clock is broken. A damaged or conflicting marker fails
 * closed instead of being overwritten. Firestore rules keep every client SDK
 * write denied and restrict reads to the owner's own current-branch leaf
 * collection.
 *
 * This module only reads the private audit and writes markers; transfer
 * transactions, stock projections and the submission receipts in
 * `transfers.js` are never touched.
 */

// Mirrors the transfer identifiers written by transfers.js: the same key shape
// and the same 112-character bound that keeps derived leg ids inside Firestore
// document id limits.
const KEY_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const TRANSFER_ID_MAX_LENGTH = 112;
// Path safety: uid and branchId become path segments of the marker document,
// so a hostile identity claim can never traverse outside its own subtree. The
// uid contract mirrors the existing client reader
// (lib/movements/inventory_movement.dart isPathSafeUid) and the server
// validTargetUid precedent (sellerProfiles.js): 1..128 path-safe characters,
// no slash or backslash, no control characters, never '.' or '..', and never a
// reserved '__...__' id — deliberately without trimming, case folding or
// Unicode normalization, so the validated string is the exact path segment.
const UID_MAX_LENGTH = 128;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F]/;
const RESERVED_DOCUMENT_ID_PATTERN = /^__.*__$/;
const BRANCH_ID_PATTERN = /^branch-[a-z0-9]+(?:-[a-z0-9]+)*$/;
// The audit shape written by transfers.js; anything else is corrupt state.
const TRANSFER_FIELDS = [
  'transferId', 'sourceBranchId', 'destinationBranchId',
  'productIds', 'lineCount', 'lines', 'actorId', 'createdAt',
];
const MARKER_FIELDS = ['userId', 'branchId', 'transferId', 'readAt'];

export function createTransferNoticeReadService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function markTransferNoticeRead(request = {}) {
    assertNoticeEnvironment(environment);
    const seller = authorizeSeller(request?.auth);
    const transferId = noticeInput(request?.data);
    // Capture and validate the clock once: a historical replay must never
    // depend on today's clock, and a fresh marker needs one stable instant.
    const clock = noticeClock(now);

    return firestore.runTransaction(async (transaction) => {
      const transferSnapshot = await transaction.get(firestore.doc(`transfers/${transferId}`));
      const transfer = storedTransfer(transferSnapshot, transferId);
      if (!transfer || transfer.destinationBranchId !== seller.branchId) {
        throw new InventoryError('not-found', 'transfer was not found in this branch');
      }

      const markerReference = firestore.doc(
        `transferNoticeReads/${seller.uid}/branches/${seller.branchId}/transfers/${transferId}`,
      );
      const markerSnapshot = await transaction.get(markerReference);
      if (markerSnapshot.exists) return replayMarker(markerSnapshot.data(), seller, transferId);
      if (clock.error) throw clock.error;

      transaction.create(markerReference, {
        userId: seller.uid,
        branchId: seller.branchId,
        transferId,
        readAt: clock.timestamp,
      });
      return Object.freeze({ transferId, branchId: seller.branchId, read: true });
    });
  };
}

// Mirrors assertTransferEnvironment: fail closed before any Admin SDK work so a
// copied or deployed function can never reach cloud Firestore.
function assertNoticeEnvironment(environment) {
  try {
    assertLocalInventoryEmulator(environment);
  } catch {
    throw new InventoryError('failed-precondition', 'transfer notices require the dedicated local demo emulator');
  }
}

// Mirrors the seller gate in sales.js: administrators and every other role are
// denied. Claims are the only identity signal, so revocation is only as
// current as the token minted for this invocation.
function authorizeSeller(auth) {
  if (!auth || !validUid(auth.uid)) {
    throw new InventoryError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'seller' || !validBranchId(auth.token?.branchId)) {
    throw new InventoryError('permission-denied', 'an assigned seller is required');
  }
  return Object.freeze({ uid: auth.uid, branchId: auth.token.branchId });
}

// Exactly one untrusted field; branch, uid and time are always server-derived.
function noticeInput(data) {
  try {
    exactFields(data, ['transferId']);
    if (typeof data.transferId !== 'string'
      || !KEY_PATTERN.test(data.transferId)
      || data.transferId.length > TRANSFER_ID_MAX_LENGTH) {
      throw new TypeError('transfer identifier is invalid');
    }
    return data.transferId;
  } catch {
    throw new InventoryError('invalid-argument', 'transfer notice request contains missing, invalid or unsupported fields');
  }
}

function storedTransfer(snapshot, transferId) {
  if (!snapshot.exists) return null;
  try {
    const record = snapshot.data();
    exactFields(record, TRANSFER_FIELDS);
    if (record.transferId !== transferId) throw new TypeError('audit identity');
    if (!validBranchId(record.sourceBranchId) || !validBranchId(record.destinationBranchId)) {
      throw new TypeError('audit branches');
    }
    denseArray(record.lines);
    return record;
  } catch {
    throw new InventoryError('failed-precondition', 'persisted transfer audit is invalid');
  }
}

// A stored marker is never repaired or replaced: anything but the exact shape
// this service writes fails closed, so a forged or damaged marker cannot
// change read state.
function replayMarker(record, seller, transferId) {
  try {
    exactFields(record, MARKER_FIELDS);
    if (record.userId !== seller.uid
      || record.branchId !== seller.branchId
      || record.transferId !== transferId
      || !validTimestamp(record.readAt)) {
      throw new TypeError('marker identity');
    }
    return Object.freeze({ transferId, branchId: seller.branchId, read: true });
  } catch {
    throw new InventoryError('failed-precondition', 'persisted transfer notice marker is invalid');
  }
}

function validBranchId(value) {
  return typeof value === 'string' && value.length <= 128 && BRANCH_ID_PATTERN.test(value);
}

function validUid(value) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= UID_MAX_LENGTH
    && !value.includes('/')
    && !value.includes('\\')
    && value !== '.'
    && value !== '..'
    && !RESERVED_DOCUMENT_ID_PATTERN.test(value)
    && !CONTROL_CHARACTER_PATTERN.test(value);
}

function validTimestamp(value) {
  // Admin reads Date writes back as Timestamp; accept both without the SDK.
  try {
    const date = value instanceof Date
      ? value
      : typeof value?.toDate === 'function' ? value.toDate() : null;
    return date instanceof Date && Number.isSafeInteger(date.getTime());
  } catch {
    return false;
  }
}

function noticeClock(now) {
  try {
    const value = now();
    const date = value instanceof Date
      ? value
      : typeof value?.toDate === 'function' ? value.toDate() : null;
    const ms = date instanceof Date ? date.getTime() : NaN;
    if (!Number.isSafeInteger(ms) || ms < 0) throw new RangeError('clock is invalid');
    return { timestamp: new Date(ms) };
  } catch {
    return { error: new InventoryError('failed-precondition', 'transfer notice timestamp is unavailable') };
  }
}
