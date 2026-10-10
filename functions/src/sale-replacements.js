import {
  assertCreateTargetsAbsent, assertReplayOwner, canonicalQuantity, correctableSale, correctionSeller,
  denseArray, exactFields, invocationTime, optionalNote, plainObject, sameDecimal, stockProjection,
  storedProductSpec, storedReplayResult, storedReturnLedger, validId,
} from './correction-support.js';
import { calculateRemainingReturnable } from './corrections-calculation.js';
import { addStockMovement, formatQuantity, parseQuantity } from './quantity.js';
import { assertLocalSalesEmulator, SALE_ERROR_REASONS, SaleError } from './sales.js';

const REQUEST_FIELDS = ['idempotencyKey', 'saleId', 'lines'];
const LINE_FIELDS = ['lineIndex', 'quantity'];
const RECEIPT_FIELDS = [
  'version', 'replacementId', 'saleId', 'branchId', 'reason', 'lines', 'chargeCentavos',
];
const RECEIPT_LINE_FIELDS = ['lineIndex', 'productId', 'quantity'];
// A replacement is always a factory-defect correction (decision 10).
export const REPLACEMENT_REASON = 'factory-defect';

/**
 * Injected Admin-Firestore-compatible factory-defect replacement service, not
 * a callable registration. Request.data is exactly { idempotencyKey, saleId,
 * note?, lines: [{ lineIndex, quantity }] }; only trusted auth.token
 * { role: 'seller', branchId } assigns the branch.
 *
 * The customer keeps what was bought (decision 11): a replacement swaps the
 * defective units for the same product at no charge and never consumes
 * returnable quantity. It still reads saleReturnLedgers/{saleId} inside the
 * transaction, so a concurrent return conflicts, and caps each line at the
 * remaining returnable quantity. Sellable stock must cover the aggregated
 * quantity per product.
 *
 * One transaction reads the saleReplacementSubmissionReceipts replay guard,
 * the sale (missing and foreign are the same not-found), the ledger, product
 * specs and stock, and every create target. It creates saleReplacements,
 * saleReplacementAudits (the only place the note lives), the movements
 * inventoryMovements/replacement-{key}-{i}-in (the defective units, no stock
 * change) and -out (the replacement units, stock decreases), and the
 * submission receipt, and sets only the affected stock projections. The sale
 * and the ledger are never written; no cost or price field is read or written.
 *
 * Returns { receipt, replayed } with a detached deeply frozen v1 receipt
 * { version, replacementId, saleId, branchId, reason, lines, chargeCentavos }.
 */
export function createSaleReplacementService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function submitReplacement(request = {}) {
    assertLocalSalesEmulator(environment);
    const { actorId, branchId } = correctionSeller(request?.auth);
    // Copy every scalar before awaiting: caller mutation cannot change the
    // transaction or its actor/branch/request-bound fingerprint mid-flight.
    const input = replacementInput(request?.data);
    const fingerprint = JSON.stringify({ actorId, branchId, ...input });
    const replayReference = firestore.doc(`saleReplacementSubmissionReceipts/${input.idempotencyKey}`);
    // Captured once, outside retryable callbacks; replay never depends on it.
    const clock = invocationTime(now, 'replacement clock is invalid');

    return firestore.runTransaction(async (transaction) => {
      const replay = await transaction.get(replayReference);
      if (replay.exists) {
        return Object.freeze({
          receipt: validatedReplay(replay.data(), input, actorId, branchId, fingerprint),
          replayed: true,
        });
      }
      if (clock.error) throw clock.error;

      const sale = await correctableSale(transaction, firestore, input.saleId, branchId, clock.ms);
      // Read for serialization only: a concurrent return conflicts with this one.
      const returned = storedReturnLedger(
        await transaction.get(firestore.doc(`saleReturnLedgers/${input.saleId}`)), sale);
      const lines = replacementLines(sale, returned, input.lines);
      const plan = stockPlan(lines);
      const key = input.idempotencyKey;
      const stockReads = await Promise.all([...plan.values()].map(async (entry) => {
        const [product, stock] = await Promise.all([
          transaction.get(firestore.doc(`products/${entry.productId}`)),
          transaction.get(firestore.doc(`branches/${branchId}/stock/${entry.productId}`)),
        ]);
        return { entry, product, stock };
      }));
      await assertCreateTargetsAbsent(transaction, [
        firestore.doc(`saleReplacements/${key}`), firestore.doc(`saleReplacementAudits/${key}`),
        ...lines.flatMap((line, index) => ['in', 'out'].map((direction) =>
          firestore.doc(`inventoryMovements/${movementId(key, index, direction)}`))),
      ]);
      // All reads, including the replay ownership guard, finish before writes.
      const stockWrites = stockReads.map(({ entry, product, stock }) => {
        const productSpec = storedProductSpec(product);
        if (productSpec.unit !== entry.spec.unit || productSpec.precision !== entry.spec.precision) {
          throw new SaleError('failed-precondition', 'product specification differs from the sale');
        }
        const current = stockProjection(stock, productSpec);
        let next;
        try {
          next = addStockMovement(current, -entry.scaled, productSpec, entry.spec);
        } catch {
          throw new SaleError('failed-precondition', 'insufficient stock', SALE_ERROR_REASONS.insufficientStock);
        }
        return { entry, productSpec, next };
      });

      const { timestamp } = clock;
      const receipt = replacementReceipt(input, branchId, lines);
      transaction.create(firestore.doc(`saleReplacements/${key}`), { receipt, createdAt: timestamp });
      transaction.create(firestore.doc(`saleReplacementAudits/${key}`), {
        replacementId: key, saleId: input.saleId, branchId, actorId, reason: REPLACEMENT_REASON,
        note: input.note, createdAt: timestamp,
      });
      lines.forEach((line, index) => {
        const movement = {
          replacementId: key, saleId: input.saleId, lineIndex: line.lineIndex, branchId,
          productId: line.productId, unit: line.spec.unit, precision: line.spec.precision,
          actorId, occurredAt: timestamp,
        };
        transaction.create(firestore.doc(`inventoryMovements/${movementId(key, index, 'in')}`), {
          type: 'replacement-defect-in', quantityScaled: line.scaled, ...movement,
        });
        transaction.create(firestore.doc(`inventoryMovements/${movementId(key, index, 'out')}`), {
          type: 'replacement-out', quantityScaled: -line.scaled, ...movement,
        });
      });
      for (const { entry, productSpec, next } of stockWrites) {
        transaction.set(firestore.doc(`branches/${branchId}/stock/${entry.productId}`), {
          quantityScaled: next, ...productSpec, updatedAt: timestamp,
          lastMovementId: movementId(key, entry.lastIndex, 'out'),
        });
      }
      // Create, never set: key ownership conflicts roll back every buffered write.
      transaction.create(replayReference, {
        actorId, branchId, fingerprint, result: receipt, completedAt: timestamp,
      });
      return Object.freeze({ receipt, replayed: false });
    });
  };
}

function movementId(key, index, direction) {
  return `replacement-${key}-${index}-${direction}`;
}

function replacementInput(data) {
  try {
    const withNote = plainObject(data) && Object.hasOwn(data, 'note');
    exactFields(data, withNote ? [...REQUEST_FIELDS, 'note'] : REQUEST_FIELDS);
    if (!validId(data.idempotencyKey) || !validId(data.saleId)) {
      throw new TypeError('key and sale are required');
    }
    const note = optionalNote(data);
    denseArray(data.lines);
    if (data.lines.length === 0) throw new TypeError('lines are required');
    const seen = new Set();
    const lines = data.lines.map((line) => {
      exactFields(line, LINE_FIELDS);
      if (!Number.isSafeInteger(line.lineIndex) || line.lineIndex < 0 || seen.has(line.lineIndex)) {
        throw new TypeError('line index must be unique and valid');
      }
      seen.add(line.lineIndex);
      if (!canonicalQuantity(line.quantity)) throw new TypeError('quantity is required');
      return { lineIndex: line.lineIndex, quantity: line.quantity };
    });
    return { idempotencyKey: data.idempotencyKey, saleId: data.saleId, note, lines };
  } catch {
    throw new SaleError('invalid-argument',
      'replacement request contains missing, invalid or unsupported fields');
  }
}

// Each line is capped at sold minus returned; replacements never reduce it.
function replacementLines(sale, returned, requested) {
  const remaining = calculateRemainingReturnable({ lines: sale.calculation.lines, returned });
  return requested.map(({ lineIndex, quantity }) => {
    const saleLine = Object.hasOwn(sale.calculation.lines, lineIndex)
      ? sale.calculation.lines[lineIndex] : undefined;
    let scaled;
    try {
      if (!saleLine) throw new RangeError('unknown line');
      scaled = parseQuantity(quantity, saleLine.quantity.spec);
    } catch {
      throw new SaleError('invalid-argument', 'replacement lines do not match the sale');
    }
    if (scaled > remaining[lineIndex].remainingScaled) {
      throw new SaleError('out-of-range', 'replacement exceeds the remaining returnable quantity',
        SALE_ERROR_REASONS.overReturn);
    }
    const { spec } = saleLine.quantity;
    return {
      lineIndex, productId: sale.productIds[lineIndex], spec, scaled,
      decimal: formatQuantity(scaled, spec),
    };
  });
}

// Aggregates lines per product so a stock document is checked and written once.
function stockPlan(lines) {
  const plan = new Map();
  lines.forEach((line, index) => {
    const entry = plan.get(line.productId)
      ?? { productId: line.productId, spec: line.spec, scaled: 0, lastIndex: index };
    if (entry.spec.unit !== line.spec.unit || entry.spec.precision !== line.spec.precision) {
      throw new SaleError('failed-precondition', 'sale lines disagree on a product specification');
    }
    entry.scaled += line.scaled;
    entry.lastIndex = index;
    plan.set(line.productId, entry);
  });
  return plan;
}

function replacementReceipt(input, branchId, lines) {
  return Object.freeze({
    version: 1,
    replacementId: input.idempotencyKey,
    saleId: input.saleId,
    branchId,
    reason: REPLACEMENT_REASON,
    lines: Object.freeze(lines.map((line) => Object.freeze({
      lineIndex: line.lineIndex, productId: line.productId, quantity: line.decimal,
    }))),
    chargeCentavos: 0,
  });
}

function validatedReplay(record, input, actorId, branchId, fingerprint) {
  assertReplayOwner(record, actorId, branchId, fingerprint);
  try {
    return replayReceipt(storedReplayResult(record), input, branchId);
  } catch {
    throw new SaleError('failed-precondition', 'persisted replacement replay is invalid');
  }
}

// Every stored field must be exactly shaped and bound to the request.
function replayReceipt(receipt, input, branchId) {
  exactFields(receipt, RECEIPT_FIELDS);
  if (receipt.version !== 1 || receipt.replacementId !== input.idempotencyKey
    || receipt.saleId !== input.saleId || receipt.branchId !== branchId
    || receipt.reason !== REPLACEMENT_REASON || receipt.chargeCentavos !== 0) {
    throw new TypeError('receipt identity');
  }
  denseArray(receipt.lines);
  if (receipt.lines.length !== input.lines.length) throw new TypeError('line count');
  const lines = receipt.lines.map((line, index) => {
    exactFields(line, RECEIPT_LINE_FIELDS);
    const requested = input.lines[index];
    if (line.lineIndex !== requested.lineIndex || !validId(line.productId)
      || !sameDecimal(line.quantity, requested.quantity)) {
      throw new TypeError('receipt line identity');
    }
    return Object.freeze({ lineIndex: line.lineIndex, productId: line.productId, quantity: line.quantity });
  });
  return Object.freeze({
    version: 1, replacementId: receipt.replacementId, saleId: receipt.saleId, branchId,
    reason: REPLACEMENT_REASON, lines: Object.freeze(lines), chargeCentavos: 0,
  });
}
