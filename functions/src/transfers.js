import { addStockMovement, createQuantitySpec, parseQuantity } from './quantity.js';
import { InventoryError, assertLocalInventoryEmulator } from './inventory.js';
import { canonicalQuantity, denseArray, exactFields } from './correction-support.js';

/**
 * Administrator-only immediate stock transfer between two branches.
 *
 * One operation moves one bounded set of distinct products along one explicit
 * source/destination pair. Conservation is the whole contract: every unit that
 * leaves the source enters the destination inside a single transaction, so the
 * sum across the pair never changes and no partial transfer is observable.
 *
 * Quantities reuse the product's immutable quantity specification (unit plus
 * precision) and the shared scaled safe-integer primitives; nothing is rounded
 * or repriced here, and no cost field is ever read or written. A destination
 * that has never held a product is a valid zero projection and receives the
 * written stock shape, while an absent or malformed existing projection is a
 * failed precondition.
 *
 * `inventoryMovements` stays the seller-readable ledger, so each leg carries
 * only the fields that reader already requires plus `transferId`: the opposite
 * branch never appears there. The full pair belongs to the immutable
 * `transfers/{key}` record, and `transferSubmissionReceipts/{key}` makes the
 * operation idempotent for the same actor and payload.
 */

const KEY_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const BRANCH_ID_PATTERN = /^branch-[a-z0-9]+(?:-[a-z0-9]+)*$/;
const PRODUCT_ID_PATTERN = /^[A-Z][A-Z0-9-]{7,63}$/;
const REQUEST_FIELDS = ['idempotencyKey', 'sourceBranchId', 'destinationBranchId', 'lines'];
const LINE_FIELDS = ['productId', 'quantity'];
const RECEIPT_FIELDS = ['actorId', 'fingerprint', 'result', 'completedAt'];
const RESULT_FIELDS = ['transferId', 'sourceBranchId', 'destinationBranchId', 'occurredAt', 'lines'];
const RESULT_LINE_FIELDS = [
  'productId', 'quantity', 'quantityScaled', 'unit', 'precision',
  'sourceQuantityScaled', 'destinationQuantityScaled',
];
// Budget for the derived leg identifiers below: `transfer-{key}-{index}-out`
// stays inside Firestore's 128-character document id even at the line limit.
const TRANSFER_ID_MAX_LENGTH = 112;

// Bounds the untrusted array before any document is read.
export const TRANSFER_LINE_LIMIT = 50;

export function createTransferService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function transferInventory(request = {}) {
    assertTransferEnvironment(environment);
    const actorId = authorizeAdministrator(request?.auth);
    // Copy every scalar before awaiting: caller mutation cannot change the
    // transaction, its audit fields or its actor/payload fingerprint mid-flight.
    const input = transferInput(request?.data);
    const fingerprint = JSON.stringify({ actorId, ...input });
    const receiptReference = firestore.doc(`transferSubmissionReceipts/${input.idempotencyKey}`);
    // Capture and validate the clock once, outside retryable callbacks: a
    // historical replay must never depend on today's clock.
    const clock = transferClock(now);

    return firestore.runTransaction(async (transaction) => {
      const receipt = await transaction.get(receiptReference);
      if (receipt.exists) return transferReplay(receipt.data(), input, actorId, fingerprint);
      if (clock.error) throw clock.error;

      const branches = await Promise.all([
        transaction.get(firestore.doc(`branches/${input.sourceBranchId}`)),
        transaction.get(firestore.doc(`branches/${input.destinationBranchId}`)),
      ]);
      if (!branches[0].exists) throw new InventoryError('not-found', 'source branch does not exist');
      if (!branches[1].exists) throw new InventoryError('not-found', 'destination branch does not exist');

      const reads = await Promise.all(input.lines.map(async (line) => {
        const references = {
          product: firestore.doc(`products/${line.productId}`),
          sourceStock: firestore.doc(`branches/${input.sourceBranchId}/stock/${line.productId}`),
          destinationStock: firestore.doc(`branches/${input.destinationBranchId}/stock/${line.productId}`),
        };
        const [product, sourceStock, destinationStock] = await Promise.all([
          transaction.get(references.product),
          transaction.get(references.sourceStock),
          transaction.get(references.destinationStock),
        ]);
        return { line, product, sourceStock, destinationStock, references };
      }));

      // Every create target is read first: without a receipt an existing target
      // is an orphaned collision, refused before any write is buffered.
      const ids = movementIds(input.idempotencyKey, input.lines.length);
      await assertCreateTargetsAbsent(transaction, [
        firestore.doc(`transfers/${input.idempotencyKey}`),
        ...ids.flatMap(({ out, in: movementIn }) => [
          firestore.doc(`inventoryMovements/${out}`),
          firestore.doc(`inventoryMovements/${movementIn}`),
        ]),
      ]);

      // All reads, including the replay and collision guards, finish before the
      // first write, and every line is validated before any stock moves.
      const prepared = reads.map((read) => prepareTransferLine(read));
      const { timestamp, ms } = clock;
      const result = transferResult(input, prepared, ms);

      transaction.create(firestore.doc(`transfers/${input.idempotencyKey}`), {
        transferId: input.idempotencyKey,
        sourceBranchId: input.sourceBranchId,
        destinationBranchId: input.destinationBranchId,
        productIds: input.lines.map((line) => line.productId),
        lineCount: prepared.length,
        lines: prepared.map(({ line, spec, scaled }) => ({
          productId: line.productId, quantity: line.quantity, quantityScaled: scaled, ...spec,
        })),
        actorId,
        createdAt: timestamp,
      });
      prepared.forEach(({ line, spec, scaled }, index) => {
        const { out, in: inLeg } = ids[index];
        const source = leg('transfer-out', input, line, spec, -scaled, input.sourceBranchId, actorId, timestamp);
        const destination = leg('transfer-in', input, line, spec, scaled, input.destinationBranchId, actorId, timestamp);
        transaction.create(firestore.doc(`inventoryMovements/${out}`), source);
        transaction.create(firestore.doc(`inventoryMovements/${inLeg}`), destination);
      });
      for (const [index, { references, spec, sourceNext, destinationNext }] of prepared.entries()) {
        transaction.set(references.sourceStock, projection(sourceNext, spec, timestamp, ids[index].out));
        transaction.set(references.destinationStock, projection(destinationNext, spec, timestamp, ids[index].in));
      }
      // Create, never set: key ownership conflicts roll back every buffered write.
      transaction.create(receiptReference, { actorId, fingerprint, result, completedAt: timestamp });

      return deepFreeze({ ...result, replayed: false });
    });
  };
}

function assertTransferEnvironment(environment) {
  try {
    assertLocalInventoryEmulator(environment);
  } catch {
    throw new InventoryError('failed-precondition', 'transfers require the dedicated local demo emulator');
  }
}

// Mirrors inventory.js authorizeAdministrator: sellers, auditors and anonymous
// callers are refused. Stored role claims are the only authorization signal,
// so revocation is only as current as the token minted for this invocation.
function authorizeAdministrator(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new InventoryError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'administrator') {
    throw new InventoryError('permission-denied', 'administrator role is required');
  }
  return auth.uid;
}

function transferInput(data) {
  try {
    exactFields(data, REQUEST_FIELDS);
    const idempotencyKey = validKey(data.idempotencyKey);
    const sourceBranchId = validBranchId(data.sourceBranchId);
    const destinationBranchId = validBranchId(data.destinationBranchId);
    if (sourceBranchId === destinationBranchId) {
      throw new TypeError('source and destination must be distinct');
    }
    denseArray(data.lines);
    if (data.lines.length === 0 || data.lines.length > TRANSFER_LINE_LIMIT) {
      throw new TypeError('lines must be a bounded nonempty list');
    }

    const seen = new Set();
    const lines = data.lines.map((line) => {
      exactFields(line, LINE_FIELDS);
      if (!PRODUCT_ID_PATTERN.test(line.productId)) throw new TypeError('product identifier is invalid');
      if (seen.has(line.productId)) throw new TypeError('each product may appear only once');
      seen.add(line.productId);
      // Precision and safe scaled bounds need the authoritative spec read later.
      if (!canonicalQuantity(line.quantity)) {
        throw new TypeError('quantity must be a canonical positive decimal string');
      }
      return { productId: line.productId, quantity: line.quantity };
    });

    return Object.freeze({ idempotencyKey, sourceBranchId, destinationBranchId, lines: Object.freeze(lines) });
  } catch {
    throw new InventoryError('invalid-argument', 'transfer request contains missing, invalid or unsupported fields');
  }
}

function validKey(value) {
  if (typeof value !== 'string' || !KEY_PATTERN.test(value) || value.length > TRANSFER_ID_MAX_LENGTH) {
    throw new TypeError('idempotency key must be a valid identifier');
  }
  return value;
}

// The movements reader owns this branch identifier shape, so a transfer never
// writes a leg that its own ledger would report as unreadable.
function validBranchId(value) {
  if (typeof value !== 'string' || value.length > 128 || !BRANCH_ID_PATTERN.test(value)) {
    throw new TypeError('branch identifier is invalid');
  }
  return value;
}

// Deterministic leg ids derived from the validated key and line index, never
// from callback randomness, so a retry cannot fork a second pair of legs.
function movementIds(key, count) {
  return Array.from({ length: count }, (_, index) => {
    const out = `transfer-${key}-${index}-out`;
    const inPair = `transfer-${key}-${index}-in`;
    if (!KEY_PATTERN.test(out) || !KEY_PATTERN.test(inPair) || out.length > 128 || inPair.length > 128) {
      throw new InventoryError('invalid-argument', 'transfer key is too long to derive movement identifiers');
    }
    return { out, in: inPair };
  });
}

function leg(type, input, line, spec, signedScaled, branchId, actorId, timestamp) {
  return {
    type,
    transferId: input.idempotencyKey,
    branchId,
    productId: line.productId,
    quantityScaled: signedScaled,
    ...spec,
    actorId,
    occurredAt: timestamp,
  };
}

function projection(quantityScaled, spec, timestamp, lastMovementId) {
  return { quantityScaled, ...spec, updatedAt: timestamp, lastMovementId };
}

function prepareTransferLine({ line, product, sourceStock, destinationStock, references }) {
  if (!product.exists) throw new InventoryError('not-found', 'product does not exist');
  const spec = storedQuantitySpec(product.data()?.quantitySpec);
  const scaled = transferQuantity(line.quantity, spec);

  const sourceCurrent = storedStock(sourceStock, spec);
  const destinationCurrent = storedStock(destinationStock, spec);
  let sourceNext;
  try {
    sourceNext = addStockMovement(sourceCurrent, -scaled, spec, spec);
  } catch {
    throw new InventoryError('failed-precondition', 'source branch does not hold enough stock');
  }
  let destinationNext;
  try {
    destinationNext = addStockMovement(destinationCurrent, scaled, spec, spec);
  } catch {
    throw new InventoryError('out-of-range', 'destination stock projection exceeds safe bounds');
  }

  return { line, spec, scaled, references, sourceNext, destinationNext };
}

function storedQuantitySpec(value) {
  try {
    exactFields(value, ['unit', 'precision']);
    return createQuantitySpec(value);
  } catch {
    throw new InventoryError('failed-precondition', 'product quantity specification is invalid');
  }
}

function transferQuantity(quantity, spec) {
  try {
    const scaled = parseQuantity(quantity, spec);
    if (scaled <= 0) throw new RangeError('quantity must be positive');
    return scaled;
  } catch {
    throw new InventoryError(
      'invalid-argument',
      'quantity must be positive and representable by the product specification',
    );
  }
}

// An absent projection is a product this branch never held: zero, which lets a
// destination accept its first units while a source simply cannot cover them.
function storedStock(snapshot, spec) {
  if (!snapshot.exists) return 0;
  const value = snapshot.data();
  if (value?.unit !== spec.unit || value?.precision !== spec.precision
    || !Number.isSafeInteger(value?.quantityScaled) || value.quantityScaled < 0) {
    throw new InventoryError('failed-precondition', 'stock projection is invalid');
  }
  return value.quantityScaled;
}

function transferResult(input, prepared, ms) {
  return deepFreeze({
    transferId: input.idempotencyKey,
    sourceBranchId: input.sourceBranchId,
    destinationBranchId: input.destinationBranchId,
    occurredAt: ms,
    lines: Object.freeze(prepared.map(({ line, spec, scaled, sourceNext, destinationNext }) => Object.freeze({
      productId: line.productId,
      quantity: line.quantity,
      quantityScaled: scaled,
      unit: spec.unit,
      precision: spec.precision,
      sourceQuantityScaled: sourceNext,
      destinationQuantityScaled: destinationNext,
    }))),
  });
}

function transferClock(now) {
  try {
    const value = now();
    const date = value instanceof Date
      ? value
      : typeof value?.toDate === 'function' ? value.toDate() : null;
    const ms = date instanceof Date ? date.getTime() : NaN;
    if (!Number.isSafeInteger(ms) || ms < 0) throw new RangeError('clock is invalid');
    return { timestamp: new Date(ms), ms };
  } catch {
    return { error: new InventoryError('failed-precondition', 'transfer timestamp is unavailable') };
  }
}

async function assertCreateTargetsAbsent(transaction, references) {
  const snapshots = await Promise.all(references.map((reference) => transaction.get(reference)));
  if (snapshots.some((snapshot) => snapshot.exists)) {
    throw new InventoryError('already-exists', 'transfer identifier collides with existing transfer records');
  }
}

// Ownership fails closed before any stored field is read, so a collision never
// reveals another administrator's result or moves stock a second time.
function transferReplay(record, input, actorId, fingerprint) {
  if (record?.actorId !== actorId || record?.fingerprint !== fingerprint) {
    throw new InventoryError('already-exists', 'transfer key is already owned by a different submission');
  }
  try {
    exactFields(record, RECEIPT_FIELDS);
    const result = record.result;
    exactFields(result, RESULT_FIELDS);
    if (result.transferId !== input.idempotencyKey
      || result.sourceBranchId !== input.sourceBranchId
      || result.destinationBranchId !== input.destinationBranchId) {
      throw new TypeError('result identity');
    }
    validCompletedAt(record.completedAt, result.occurredAt);
    denseArray(result.lines);
    if (result.lines.length !== input.lines.length) throw new TypeError('line count');
    result.lines.forEach((line, index) => {
      exactFields(line, RESULT_LINE_FIELDS);
      const expected = input.lines[index];
      if (line.productId !== expected.productId || line.quantity !== expected.quantity) {
        throw new TypeError('line payload');
      }
      if (!Number.isSafeInteger(line.quantityScaled) || line.quantityScaled <= 0
        || !Number.isSafeInteger(line.sourceQuantityScaled) || line.sourceQuantityScaled < 0
        || !Number.isSafeInteger(line.destinationQuantityScaled) || line.destinationQuantityScaled < 0) {
        throw new TypeError('line quantities');
      }
      createQuantitySpec({ unit: line.unit, precision: line.precision });
    });
    return deepFreeze({ ...result, replayed: true });
  } catch {
    throw new InventoryError('failed-precondition', 'persisted transfer replay is invalid');
  }
}

function validCompletedAt(value, occurredAt) {
  const date = value instanceof Date
    ? value
    : typeof value?.toDate === 'function' ? value.toDate() : null;
  if (!(date instanceof Date) || !Number.isSafeInteger(date.getTime())
    || date.getTime() !== occurredAt || !Number.isSafeInteger(occurredAt) || occurredAt < 0) {
    throw new TypeError('completedAt');
  }
}

function deepFreeze(value) {
  if (value !== null && typeof value === 'object') {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}
