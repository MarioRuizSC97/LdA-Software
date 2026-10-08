import {
  assertCreateTargetsAbsent, assertReplayOwner, canonicalQuantity, correctableSale, correctionSeller,
  CORRECTION_NOTE_MAX_LENGTH, denseArray, exactFields, invocationTime, optionalNote, plainObject,
  sameDecimal, stockProjection, storedProductSpec, storedReplayResult, storedReturnLedger, validId,
} from './correction-support.js';
import { calculateReturnRefund, CorrectionError } from './corrections-calculation.js';
import { addStockMovement } from './quantity.js';
import { assertLocalSalesEmulator, SaleError } from './sales.js';

const PAYMENT_METHODS = ['cash', 'card', 'transfer'];
const REQUEST_FIELDS = ['idempotencyKey', 'saleId', 'reason', 'lines'];
const LINE_FIELDS = ['lineIndex', 'quantity', 'condition'];
const RECEIPT_FIELDS = [
  'version', 'returnId', 'saleId', 'branchId', 'reason', 'lines', 'refund', 'invoiced',
];
const RECEIPT_LINE_FIELDS = [
  'lineIndex', 'productId', 'quantity', 'condition',
  'baseCentavos', 'additionalIvaCentavos', 'totalCentavos',
];
const AMOUNT_FIELDS = ['baseCentavos', 'additionalIvaCentavos', 'totalCentavos'];
export const RETURN_REASONS = Object.freeze(['change-of-mind', 'wrong-product', 'factory-defect', 'other']);
export const RETURN_CONDITIONS = Object.freeze(['good', 'factory-defect']);
export const RETURN_NOTE_MAX_LENGTH = CORRECTION_NOTE_MAX_LENGTH;
// Only good units re-enter sellable stock (decision 4); defects are recorded only.
const MOVEMENT_TYPES = Object.freeze({ good: 'sale-return', 'factory-defect': 'sale-return-defect' });

/**
 * Injected Admin-Firestore-compatible refund-return service, not a callable
 * registration. Request.data is exactly { idempotencyKey, saleId, reason,
 * note?, lines: [{ lineIndex, quantity, condition }] }; only trusted
 * auth.token { role: 'seller', branchId } assigns the branch.
 *
 * One transaction reads, in order, the saleReturnSubmissionReceipts replay
 * guard, the sale (strictly validated like lookups; missing and foreign are the
 * same not-found), the saleReturnLedgers/{saleId} ledger, then product specs and
 * branch stock for good lines. The ledger read serializes concurrent returns.
 * It creates saleReturns, saleReturnAudits (the only place the note lives),
 * inventoryMovements/return-{key}-{i} and the submission receipt, and sets only
 * the ledger and the affected stock projections. The sale is never written and
 * no cost field is read or written.
 *
 * Returns { receipt, replayed } with a detached deeply frozen v1 receipt
 * { version, returnId, saleId, branchId, reason, lines, refund, invoiced }.
 * Replacement (CORR-04) and exchange (CORR-05) are separate operations.
 */
export function createSaleReturnService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function submitReturn(request = {}) {
    assertLocalSalesEmulator(environment);
    const { actorId, branchId } = correctionSeller(request?.auth);
    // Copy every scalar before awaiting: caller mutation cannot change the
    // transaction or its actor/branch/request-bound fingerprint mid-flight.
    const input = returnInput(request?.data);
    const fingerprint = JSON.stringify({ actorId, branchId, ...input });
    const replayReference = firestore.doc(`saleReturnSubmissionReceipts/${input.idempotencyKey}`);
    // Captured once, outside retryable callbacks; replay never depends on it.
    const clock = invocationTime(now, 'return clock is invalid');

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
      const ledgerReference = firestore.doc(`saleReturnLedgers/${input.saleId}`);
      const previous = storedReturnLedger(await transaction.get(ledgerReference), sale);
      const refund = returnRefund(sale, previous, input.lines);
      const restock = restockPlan(sale, refund, input.lines);
      const stockReads = await Promise.all([...restock.values()].map(async (entry) => {
        const [product, stock] = await Promise.all([
          transaction.get(firestore.doc(`products/${entry.productId}`)),
          transaction.get(firestore.doc(`branches/${branchId}/stock/${entry.productId}`)),
        ]);
        return { entry, product, stock };
      }));
      const key = input.idempotencyKey;
      await assertCreateTargetsAbsent(transaction, [
        firestore.doc(`saleReturns/${key}`), firestore.doc(`saleReturnAudits/${key}`),
        ...refund.lines.map((line, index) => firestore.doc(`inventoryMovements/${movementId(key, index)}`)),
      ]);
      // All reads, including the replay ownership guard, finish before writes.
      const stockWrites = stockReads.map(({ entry, product, stock }) => {
        const productSpec = storedProductSpec(product);
        const current = stockProjection(stock, productSpec);
        let next;
        try {
          next = addStockMovement(current, entry.scaled, productSpec, entry.spec);
        } catch {
          throw new SaleError('failed-precondition', 'stock projection cannot accept the return');
        }
        return { entry, productSpec, next };
      });

      const { timestamp } = clock;
      const receipt = returnReceipt(input, branchId, refund);
      transaction.create(firestore.doc(`saleReturns/${key}`), { receipt, createdAt: timestamp });
      transaction.create(firestore.doc(`saleReturnAudits/${key}`), {
        returnId: key, saleId: input.saleId, branchId, actorId, reason: input.reason,
        note: input.note, createdAt: timestamp,
      });
      refund.lines.forEach((line, index) => {
        const { spec } = sale.calculation.lines[line.lineIndex].quantity;
        transaction.create(firestore.doc(`inventoryMovements/${movementId(key, index)}`), {
          type: MOVEMENT_TYPES[input.lines[index].condition], returnId: key, saleId: input.saleId,
          lineIndex: line.lineIndex, branchId, productId: line.productId,
          quantityScaled: line.quantity.scaled, unit: spec.unit, precision: spec.precision,
          actorId, occurredAt: timestamp,
        });
      });
      for (const { entry, productSpec, next } of stockWrites) {
        transaction.set(firestore.doc(`branches/${branchId}/stock/${entry.productId}`), {
          quantityScaled: next, ...productSpec, updatedAt: timestamp,
          lastMovementId: movementId(key, entry.lastIndex),
        });
      }
      const returned = { ...previous };
      for (const line of refund.lines) {
        returned[line.lineIndex] = (returned[line.lineIndex] ?? 0) + line.quantity.scaled;
      }
      transaction.set(ledgerReference, { returned, lastReturnId: key, updatedAt: timestamp });
      // Create, never set: key ownership conflicts roll back every buffered write.
      transaction.create(replayReference, {
        actorId, branchId, fingerprint, result: receipt, completedAt: timestamp,
      });
      return Object.freeze({ receipt, replayed: false });
    });
  };
}

function movementId(key, index) {
  return `return-${key}-${index}`;
}

function returnInput(data) {
  try {
    const withNote = plainObject(data) && Object.hasOwn(data, 'note');
    exactFields(data, withNote ? [...REQUEST_FIELDS, 'note'] : REQUEST_FIELDS);
    if (!validId(data.idempotencyKey) || !validId(data.saleId)
      || !RETURN_REASONS.includes(data.reason)) {
      throw new TypeError('key, sale and reason are required');
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
      if (!canonicalQuantity(line.quantity) || !RETURN_CONDITIONS.includes(line.condition)) {
        throw new TypeError('quantity and condition are required');
      }
      return { lineIndex: line.lineIndex, quantity: line.quantity, condition: line.condition };
    });
    return {
      idempotencyKey: data.idempotencyKey, saleId: data.saleId, reason: data.reason,
      note, lines,
    };
  } catch {
    throw new SaleError('invalid-argument', 'return request contains missing, invalid or unsupported fields');
  }
}

function returnRefund(sale, returned, lines) {
  try {
    return calculateReturnRefund({
      receipt: {
        version: 1, calculation: sale.calculation, payment: sale.payment, productIds: sale.productIds,
      },
      returned,
      lines: lines.map(({ lineIndex, quantity }) => ({ lineIndex, quantity })),
    });
  } catch (error) {
    // Unknown lines and precision mismatches are request errors; an over-return
    // is out-of-range. The stored snapshot was validated, so anything else is
    // an inconsistent persisted state.
    if (error instanceof CorrectionError && ['invalid-argument', 'out-of-range'].includes(error.code)) {
      throw new SaleError(error.code, error.code === 'out-of-range'
        ? 'return exceeds the remaining sold quantity'
        : 'return lines do not match the sale');
    }
    throw new SaleError('failed-precondition', 'return cannot be calculated from the stored sale');
  }
}

// Aggregates good lines per product so a stock document is written once.
function restockPlan(sale, refund, lines) {
  const plan = new Map();
  refund.lines.forEach((line, index) => {
    if (lines[index].condition !== 'good') return;
    const { spec } = sale.calculation.lines[line.lineIndex].quantity;
    const entry = plan.get(line.productId)
      ?? { productId: line.productId, spec, scaled: 0, lastIndex: index };
    if (entry.spec.unit !== spec.unit || entry.spec.precision !== spec.precision) {
      throw new SaleError('failed-precondition', 'sale lines disagree on a product specification');
    }
    entry.scaled += line.quantity.scaled;
    entry.lastIndex = index;
    plan.set(line.productId, entry);
  });
  return plan;
}

function returnReceipt(input, branchId, refund) {
  return Object.freeze({
    version: 1,
    returnId: input.idempotencyKey,
    saleId: input.saleId,
    branchId,
    reason: input.reason,
    lines: Object.freeze(refund.lines.map((line, index) => Object.freeze({
      lineIndex: line.lineIndex,
      productId: line.productId,
      quantity: line.quantity.decimal,
      condition: input.lines[index].condition,
      baseCentavos: line.baseCentavos,
      additionalIvaCentavos: line.additionalIvaCentavos,
      totalCentavos: line.totalCentavos,
    }))),
    refund: Object.freeze({
      method: refund.refundMethod,
      baseCentavos: refund.baseCentavos,
      additionalIvaCentavos: refund.additionalIvaCentavos,
      totalCentavos: refund.totalCentavos,
    }),
    invoiced: refund.invoiced,
  });
}

function validatedReplay(record, input, actorId, branchId, fingerprint) {
  assertReplayOwner(record, actorId, branchId, fingerprint);
  try {
    return replayReceipt(storedReplayResult(record), input, branchId);
  } catch {
    throw new SaleError('failed-precondition', 'persisted return replay is invalid');
  }
}

// The ledger state at submission time is gone, so amounts cannot be recomputed;
// instead every field must be exactly shaped, bound to the request and summed.
function replayReceipt(receipt, input, branchId) {
  exactFields(receipt, RECEIPT_FIELDS);
  if (receipt.version !== 1 || receipt.returnId !== input.idempotencyKey
    || receipt.saleId !== input.saleId || receipt.branchId !== branchId
    || receipt.reason !== input.reason || typeof receipt.invoiced !== 'boolean') {
    throw new TypeError('receipt identity');
  }
  denseArray(receipt.lines);
  if (receipt.lines.length !== input.lines.length) throw new TypeError('line count');
  const sums = { baseCentavos: 0, additionalIvaCentavos: 0, totalCentavos: 0 };
  const lines = receipt.lines.map((line, index) => {
    exactFields(line, RECEIPT_LINE_FIELDS);
    const requested = input.lines[index];
    if (line.lineIndex !== requested.lineIndex || line.condition !== requested.condition
      || !validId(line.productId) || !sameDecimal(line.quantity, requested.quantity)) {
      throw new TypeError('receipt line identity');
    }
    const amounts = replayAmounts(line, receipt.invoiced);
    for (const field of AMOUNT_FIELDS) sums[field] += amounts[field];
    return Object.freeze({
      lineIndex: line.lineIndex, productId: line.productId, quantity: line.quantity,
      condition: line.condition, ...amounts,
    });
  });
  exactFields(receipt.refund, ['method', ...AMOUNT_FIELDS]);
  if (!PAYMENT_METHODS.includes(receipt.refund.method)) throw new TypeError('refund method');
  const refund = replayAmounts(receipt.refund, receipt.invoiced);
  if (AMOUNT_FIELDS.some((field) => refund[field] !== sums[field])) throw new TypeError('refund sums');
  return Object.freeze({
    version: 1, returnId: receipt.returnId, saleId: receipt.saleId, branchId,
    reason: receipt.reason, lines: Object.freeze(lines),
    refund: Object.freeze({ method: receipt.refund.method, ...refund }),
    invoiced: receipt.invoiced,
  });
}

function replayAmounts(value, invoiced) {
  const { baseCentavos, additionalIvaCentavos, totalCentavos } = value;
  if (![baseCentavos, additionalIvaCentavos, totalCentavos]
    .every((amount) => Number.isSafeInteger(amount) && amount >= 0)
    || totalCentavos !== baseCentavos + additionalIvaCentavos
    || (!invoiced && additionalIvaCentavos !== 0)) {
    throw new TypeError('receipt amounts');
  }
  return { baseCentavos, additionalIvaCentavos, totalCentavos };
}
