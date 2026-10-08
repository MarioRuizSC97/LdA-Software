import {
  assertCreateTargetsAbsent, assertReplayOwner, canonicalQuantity, correctableSale, correctionSeller,
  denseArray, exactFields, invocationTime, optionalNote, plainObject, sameDecimal, stockProjection,
  storedProductSpec, storedReplayResult, storedReturnLedger, validId,
} from './correction-support.js';
import {
  calculateExchangeSettlement, calculateReturnRefund, CorrectionError,
} from './corrections-calculation.js';
import { addStockMovement, parseQuantity } from './quantity.js';
import { RETURN_CONDITIONS, RETURN_REASONS } from './sale-returns.js';
import { assertLocalSalesEmulator, calculateSale, SaleError } from './sales.js';

const PAYMENT_METHODS = ['cash', 'card', 'transfer'];
const REQUEST_FIELDS = ['idempotencyKey', 'saleId', 'reason', 'returnLines', 'newLines'];
const RETURN_LINE_FIELDS = ['lineIndex', 'quantity', 'condition'];
const NEW_LINE_FIELDS = ['productId', 'quantity'];
const PAYMENT_FIELDS = ['method', 'amountCentavos'];
const PRICING_FIELDS = [
  'currency', 'ivaRateBasisPoints', 'ivaTreatment', 'listedPriceCentavos', 'priceMode',
];
const RECEIPT_FIELDS = [
  'version', 'exchangeId', 'saleId', 'branchId', 'reason', 'returned', 'newItems', 'settlement',
  'invoiced',
];
const RECEIPT_LINE_FIELDS = [
  'lineIndex', 'productId', 'quantity', 'condition',
  'baseCentavos', 'additionalIvaCentavos', 'totalCentavos',
];
const AMOUNT_FIELDS = ['baseCentavos', 'additionalIvaCentavos', 'totalCentavos'];
const SETTLEMENT_FIELDS = [
  'returnedCentavos', 'newItemCentavos', 'customerPaysCentavos', 'refundCentavos', 'refundMethod',
  'differencePayment',
];
// Returned units follow decision 4: only good units re-enter sellable stock.
const RETURN_MOVEMENT_TYPES = Object.freeze({
  good: 'exchange-return', 'factory-defect': 'exchange-return-defect',
});

/**
 * Injected Admin-Firestore-compatible exchange service, not a callable
 * registration. Request.data is exactly { idempotencyKey, saleId, reason,
 * note?, returnLines: [{ lineIndex, quantity, condition }], newLines:
 * [{ productId, quantity }], differencePayment?: { method, amountCentavos } };
 * only trusted auth.token { role: 'seller', branchId } assigns the branch.
 *
 * The returned part is a return (decision 7): it consumes the
 * saleReturnLedgers/{saleId} ledger with cumulative refunds at the sale
 * snapshot. New items are priced at CURRENT product pricing with the original
 * invoice intent and need sellable stock; a new item may never be a returned
 * product, because a same-product swap is a replacement. A positive difference
 * must be paid exactly by differencePayment; otherwise it must be absent and
 * any refund goes to the original payment method (decision 6).
 *
 * One transaction reads the saleExchangeSubmissionReceipts replay guard, the
 * sale (missing and foreign are the same not-found), the ledger, products and
 * stock, and every create target. It creates saleExchanges, saleExchangeAudits
 * (the only place the note lives), inventoryMovements/exchange-{key}-in-{i}
 * and -out-{j} and the submission receipt, and sets only the ledger and the
 * affected stock projections. The sale is never written; no cost is read.
 *
 * Returns { receipt, replayed } with a detached deeply frozen v1 receipt
 * { version, exchangeId, saleId, branchId, reason, returned, newItems,
 * settlement, invoiced }.
 */
export function createSaleExchangeService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function submitExchange(request = {}) {
    assertLocalSalesEmulator(environment);
    const { actorId, branchId } = correctionSeller(request?.auth);
    // Copy every scalar before awaiting: caller mutation cannot change the
    // transaction or its actor/branch/request-bound fingerprint mid-flight.
    const input = exchangeInput(request?.data);
    const fingerprint = JSON.stringify({ actorId, branchId, ...input });
    const replayReference = firestore.doc(`saleExchangeSubmissionReceipts/${input.idempotencyKey}`);
    // Captured once, outside retryable callbacks; replay never depends on it.
    const clock = invocationTime(now, 'exchange clock is invalid');

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
      const refund = exchangeRefund(sale, previous, input.returnLines);
      const returnedProducts = new Set(refund.lines.map((line) => line.productId));
      if (input.newLines.some((line) => returnedProducts.has(line.productId))) {
        throw new SaleError('invalid-argument', 'exchange new items must differ from the returned products');
      }
      const restock = restockPlan(sale, refund, input.returnLines);
      const key = input.idempotencyKey;
      const [restockReads, newReads] = await Promise.all([
        Promise.all([...restock.values()].map(async (entry) => ({
          entry, ...await productAndStock(transaction, firestore, branchId, entry.productId),
        }))),
        Promise.all(input.newLines.map(async (line) => ({
          line, ...await productAndStock(transaction, firestore, branchId, line.productId),
        }))),
      ]);
      await assertCreateTargetsAbsent(transaction, [
        firestore.doc(`saleExchanges/${key}`), firestore.doc(`saleExchangeAudits/${key}`),
        ...refund.lines.map((line, index) => firestore.doc(`inventoryMovements/${movementId(key, 'in', index)}`)),
        ...input.newLines.map((line, index) => firestore.doc(`inventoryMovements/${movementId(key, 'out', index)}`)),
      ]);
      // All reads, including the replay ownership guard, finish before writes.
      const restockWrites = restockReads.map(({ entry, product, stock }) => {
        const productSpec = storedProductSpec(product);
        const current = stockProjection(stock, productSpec);
        let next;
        try {
          next = addStockMovement(current, entry.scaled, productSpec, entry.spec);
        } catch {
          throw new SaleError('failed-precondition', 'stock projection cannot accept the return');
        }
        return { productId: entry.productId, productSpec, next, lastMovementId: movementId(key, 'in', entry.lastIndex) };
      });
      const prepared = newReads.map(({ line, product, stock }) => {
        if (!product.exists) throw new SaleError('not-found', 'product does not exist');
        const productSpec = storedProductSpec(product);
        const productPricing = storedPricing(product.data()?.pricing);
        const scaled = newQuantity(line.quantity, productSpec);
        const current = stockProjection(stock, productSpec);
        let next;
        try {
          next = addStockMovement(current, -scaled, productSpec, productSpec);
        } catch {
          throw new SaleError('failed-precondition', 'insufficient stock');
        }
        return { line, productSpec, productPricing, scaled, next };
      });
      const calculation = newItemCalculation(sale.calculation.invoiceRequested, prepared);
      const settlement = exchangeSettlement(refund, calculation);
      const differencePayment = settledPayment(settlement, input.differencePayment);

      const { timestamp } = clock;
      const receipt = exchangeReceipt(input, branchId, refund, calculation, settlement, differencePayment);
      transaction.create(firestore.doc(`saleExchanges/${key}`), { receipt, createdAt: timestamp });
      transaction.create(firestore.doc(`saleExchangeAudits/${key}`), {
        exchangeId: key, saleId: input.saleId, branchId, actorId, reason: input.reason,
        note: input.note, createdAt: timestamp,
      });
      const movement = { exchangeId: key, saleId: input.saleId, branchId, actorId, occurredAt: timestamp };
      refund.lines.forEach((line, index) => {
        const { spec } = sale.calculation.lines[line.lineIndex].quantity;
        transaction.create(firestore.doc(`inventoryMovements/${movementId(key, 'in', index)}`), {
          type: RETURN_MOVEMENT_TYPES[input.returnLines[index].condition], ...movement,
          lineIndex: line.lineIndex, productId: line.productId, quantityScaled: line.quantity.scaled,
          unit: spec.unit, precision: spec.precision,
        });
      });
      prepared.forEach(({ line, productSpec, scaled }, index) => {
        transaction.create(firestore.doc(`inventoryMovements/${movementId(key, 'out', index)}`), {
          type: 'exchange-out', ...movement, newLineIndex: index, productId: line.productId,
          quantityScaled: -scaled, unit: productSpec.unit, precision: productSpec.precision,
        });
      });
      // Returned and new products are disjoint, so each stock document is set once.
      const stockWrites = [
        ...restockWrites,
        ...prepared.map(({ line, productSpec, next }, index) => ({
          productId: line.productId, productSpec, next, lastMovementId: movementId(key, 'out', index),
        })),
      ];
      for (const { productId, productSpec, next, lastMovementId } of stockWrites) {
        transaction.set(firestore.doc(`branches/${branchId}/stock/${productId}`), {
          quantityScaled: next, ...productSpec, updatedAt: timestamp, lastMovementId,
        });
      }
      const returned = { ...previous };
      for (const line of refund.lines) {
        returned[line.lineIndex] = (returned[line.lineIndex] ?? 0) + line.quantity.scaled;
      }
      // The strict ledger shape has one provenance slot: it names this exchange.
      transaction.set(ledgerReference, { returned, lastReturnId: key, updatedAt: timestamp });
      // Create, never set: key ownership conflicts roll back every buffered write.
      transaction.create(replayReference, {
        actorId, branchId, fingerprint, result: receipt, completedAt: timestamp,
      });
      return Object.freeze({ receipt, replayed: false });
    });
  };
}

function movementId(key, direction, index) {
  return `exchange-${key}-${direction}-${index}`;
}

async function productAndStock(transaction, firestore, branchId, productId) {
  const [product, stock] = await Promise.all([
    transaction.get(firestore.doc(`products/${productId}`)),
    transaction.get(firestore.doc(`branches/${branchId}/stock/${productId}`)),
  ]);
  return { product, stock };
}

function exchangeInput(data) {
  try {
    const fields = [...REQUEST_FIELDS];
    if (plainObject(data) && Object.hasOwn(data, 'note')) fields.push('note');
    if (plainObject(data) && Object.hasOwn(data, 'differencePayment')) fields.push('differencePayment');
    exactFields(data, fields);
    if (!validId(data.idempotencyKey) || !validId(data.saleId)
      || !RETURN_REASONS.includes(data.reason)) {
      throw new TypeError('key, sale and reason are required');
    }
    const note = optionalNote(data);
    denseArray(data.returnLines);
    denseArray(data.newLines);
    if (data.returnLines.length === 0 || data.newLines.length === 0) {
      throw new TypeError('return and new lines are required');
    }
    const seenLines = new Set();
    const returnLines = data.returnLines.map((line) => {
      exactFields(line, RETURN_LINE_FIELDS);
      if (!Number.isSafeInteger(line.lineIndex) || line.lineIndex < 0 || seenLines.has(line.lineIndex)) {
        throw new TypeError('line index must be unique and valid');
      }
      seenLines.add(line.lineIndex);
      if (!canonicalQuantity(line.quantity) || !RETURN_CONDITIONS.includes(line.condition)) {
        throw new TypeError('quantity and condition are required');
      }
      return { lineIndex: line.lineIndex, quantity: line.quantity, condition: line.condition };
    });
    const seenProducts = new Set();
    const newLines = data.newLines.map((line) => {
      exactFields(line, NEW_LINE_FIELDS);
      if (!validId(line.productId) || seenProducts.has(line.productId)) {
        throw new TypeError('product must be unique and valid');
      }
      seenProducts.add(line.productId);
      if (!canonicalQuantity(line.quantity)) throw new TypeError('quantity is required');
      return { productId: line.productId, quantity: line.quantity };
    });
    let differencePayment = null;
    if (Object.hasOwn(data, 'differencePayment')) {
      const payment = data.differencePayment;
      exactFields(payment, PAYMENT_FIELDS);
      if (!PAYMENT_METHODS.includes(payment.method)
        || !Number.isSafeInteger(payment.amountCentavos) || payment.amountCentavos < 0) {
        throw new TypeError('payment must be a supported method and safe centavo amount');
      }
      differencePayment = { method: payment.method, amountCentavos: payment.amountCentavos };
    }
    return {
      idempotencyKey: data.idempotencyKey, saleId: data.saleId, reason: data.reason, note,
      returnLines, newLines, differencePayment,
    };
  } catch {
    throw new SaleError('invalid-argument', 'exchange request contains missing, invalid or unsupported fields');
  }
}

function exchangeRefund(sale, returned, lines) {
  try {
    return calculateReturnRefund({
      receipt: {
        version: 1, calculation: sale.calculation, payment: sale.payment, productIds: sale.productIds,
      },
      returned,
      lines: lines.map(({ lineIndex, quantity }) => ({ lineIndex, quantity })),
    });
  } catch (error) {
    // Mirrors returns: unknown lines and precision mismatches are request
    // errors; an over-return is out-of-range; anything else is stored state.
    if (error instanceof CorrectionError && ['invalid-argument', 'out-of-range'].includes(error.code)) {
      throw new SaleError(error.code, error.code === 'out-of-range'
        ? 'exchange exceeds the remaining sold quantity'
        : 'exchange return lines do not match the sale');
    }
    throw new SaleError('failed-precondition', 'exchange cannot be calculated from the stored sale');
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

// sales.js keeps its stored-pricing validator private; this mirrors it exactly:
// the published five-field policy, MXN, and an IVA rate matching its treatment.
function storedPricing(value) {
  try {
    exactFields(value, PRICING_FIELDS);
    const { currency, listedPriceCentavos, priceMode, ivaTreatment, ivaRateBasisPoints } = value;
    if (currency !== 'MXN' || !Number.isSafeInteger(listedPriceCentavos) || listedPriceCentavos < 0
      || !['iva-included', 'iva-additional-on-invoice'].includes(priceMode)
      || !['taxable', 'zero-rated', 'exempt'].includes(ivaTreatment)
      || (ivaTreatment === 'exempt' && ivaRateBasisPoints !== null)
      || (ivaTreatment === 'zero-rated' && ivaRateBasisPoints !== 0)
      || (ivaTreatment === 'taxable' && (!Number.isInteger(ivaRateBasisPoints)
        || ivaRateBasisPoints < 1 || ivaRateBasisPoints > 10_000))) {
      throw new TypeError('unsupported pricing policy');
    }
    return Object.fromEntries(PRICING_FIELDS.map((field) => [field, value[field]]));
  } catch {
    throw new SaleError('failed-precondition', 'product pricing is invalid');
  }
}

function newQuantity(value, spec) {
  try {
    const scaled = parseQuantity(value, spec);
    if (scaled <= 0) throw new RangeError('not positive');
    return scaled;
  } catch {
    throw new SaleError('invalid-argument', 'quantity is not representable by the product specification');
  }
}

function newItemCalculation(invoiceRequested, prepared) {
  try {
    return calculateSale({
      invoiceRequested,
      lines: prepared.map(({ line, productSpec, productPricing }) => ({
        quantity: line.quantity,
        quantitySpec: { unit: productSpec.unit, precision: productSpec.precision },
        pricing: productPricing,
      })),
    });
  } catch {
    // Specs, quantities and pricing were validated above; only overflow remains.
    throw new SaleError('out-of-range', 'exchange calculation exceeds safe bounds');
  }
}

function exchangeSettlement(refund, calculation) {
  try {
    return calculateExchangeSettlement({ refund, newItems: calculation });
  } catch {
    throw new SaleError('failed-precondition', 'exchange settlement cannot be calculated');
  }
}

// Mirrors the full-payment rule of sales: what is owed is paid exactly, and a
// payment is never taken when the customer owes nothing.
function settledPayment(settlement, payment) {
  if (settlement.customerPaysCentavos > 0) {
    if (payment === null || payment.amountCentavos !== settlement.customerPaysCentavos) {
      throw new SaleError('invalid-argument', 'difference payment must equal the amount the customer owes');
    }
    return payment;
  }
  if (payment !== null) {
    throw new SaleError('invalid-argument', 'difference payment is only accepted when the customer owes money');
  }
  return null;
}

function exchangeReceipt(input, branchId, refund, calculation, settlement, differencePayment) {
  return Object.freeze({
    version: 1,
    exchangeId: input.idempotencyKey,
    saleId: input.saleId,
    branchId,
    reason: input.reason,
    returned: Object.freeze({
      lines: Object.freeze(refund.lines.map((line, index) => Object.freeze({
        lineIndex: line.lineIndex,
        productId: line.productId,
        quantity: line.quantity.decimal,
        condition: input.returnLines[index].condition,
        baseCentavos: line.baseCentavos,
        additionalIvaCentavos: line.additionalIvaCentavos,
        totalCentavos: line.totalCentavos,
      }))),
      baseCentavos: refund.baseCentavos,
      additionalIvaCentavos: refund.additionalIvaCentavos,
      totalCentavos: refund.totalCentavos,
    }),
    newItems: Object.freeze({
      productIds: Object.freeze(input.newLines.map((line) => line.productId)),
      calculation,
    }),
    settlement: Object.freeze({
      returnedCentavos: settlement.returnedCentavos,
      newItemCentavos: settlement.newItemCentavos,
      customerPaysCentavos: settlement.customerPaysCentavos,
      refundCentavos: settlement.refundCentavos,
      refundMethod: settlement.refundMethod,
      differencePayment: differencePayment === null ? null : Object.freeze({ ...differencePayment }),
    }),
    invoiced: refund.invoiced,
  });
}

function validatedReplay(record, input, actorId, branchId, fingerprint) {
  assertReplayOwner(record, actorId, branchId, fingerprint);
  try {
    return replayReceipt(storedReplayResult(record), input, branchId);
  } catch {
    throw new SaleError('failed-precondition', 'persisted exchange replay is invalid');
  }
}

// The ledger state at submission time is gone, so returned amounts are shape-
// and sum-checked and bound to the request; new items are recomputed from
// their stored pricing snapshot, and the settlement is re-derived from both.
function replayReceipt(receipt, input, branchId) {
  exactFields(receipt, RECEIPT_FIELDS);
  if (receipt.version !== 1 || receipt.exchangeId !== input.idempotencyKey
    || receipt.saleId !== input.saleId || receipt.branchId !== branchId
    || receipt.reason !== input.reason || typeof receipt.invoiced !== 'boolean') {
    throw new TypeError('receipt identity');
  }
  const returned = replayReturned(receipt.returned, input, receipt.invoiced);
  const newItems = replayNewItems(receipt.newItems, input, receipt.invoiced);
  const stored = receipt.settlement;
  exactFields(stored, SETTLEMENT_FIELDS);
  if (!PAYMENT_METHODS.includes(stored.refundMethod)) throw new TypeError('refund method');
  const settlement = calculateExchangeSettlement({
    refund: { version: 1, invoiced: receipt.invoiced, refundMethod: stored.refundMethod,
      totalCentavos: returned.totalCentavos },
    newItems: newItems.calculation,
  });
  if (SETTLEMENT_FIELDS.slice(0, 4).some((field) => stored[field] !== settlement[field])) {
    throw new TypeError('settlement amounts');
  }
  const payment = input.differencePayment;
  if (payment === null ? stored.differencePayment !== null
    : (!plainObject(stored.differencePayment) || canonical(stored.differencePayment) !== canonical(payment))) {
    throw new TypeError('difference payment');
  }
  settledPayment(settlement, payment);
  return Object.freeze({
    version: 1, exchangeId: receipt.exchangeId, saleId: receipt.saleId, branchId,
    reason: receipt.reason, returned, newItems,
    settlement: Object.freeze({
      returnedCentavos: settlement.returnedCentavos, newItemCentavos: settlement.newItemCentavos,
      customerPaysCentavos: settlement.customerPaysCentavos, refundCentavos: settlement.refundCentavos,
      refundMethod: settlement.refundMethod,
      differencePayment: payment === null ? null : Object.freeze({ ...payment }),
    }),
    invoiced: receipt.invoiced,
  });
}

function replayReturned(value, input, invoiced) {
  exactFields(value, ['lines', ...AMOUNT_FIELDS]);
  denseArray(value.lines);
  if (value.lines.length !== input.returnLines.length) throw new TypeError('line count');
  const sums = { baseCentavos: 0, additionalIvaCentavos: 0, totalCentavos: 0 };
  const lines = value.lines.map((line, index) => {
    exactFields(line, RECEIPT_LINE_FIELDS);
    const requested = input.returnLines[index];
    if (line.lineIndex !== requested.lineIndex || line.condition !== requested.condition
      || !validId(line.productId) || !sameDecimal(line.quantity, requested.quantity)) {
      throw new TypeError('receipt line identity');
    }
    const amounts = replayAmounts(line, invoiced);
    for (const field of AMOUNT_FIELDS) sums[field] += amounts[field];
    return Object.freeze({
      lineIndex: line.lineIndex, productId: line.productId, quantity: line.quantity,
      condition: line.condition, ...amounts,
    });
  });
  const totals = replayAmounts(value, invoiced);
  if (AMOUNT_FIELDS.some((field) => totals[field] !== sums[field])) throw new TypeError('returned sums');
  if (lines.some((line) => input.newLines.some((item) => item.productId === line.productId))) {
    throw new TypeError('returned product bought again');
  }
  return Object.freeze({ lines: Object.freeze(lines), ...totals });
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

// Recompute only from the stored pricing snapshot, never a repriced catalog,
// and compare the complete calculation, catching any extra or altered field.
function replayNewItems(value, input, invoiced) {
  exactFields(value, ['productIds', 'calculation']);
  denseArray(value.productIds);
  if (value.productIds.length !== input.newLines.length
    || value.productIds.some((productId, index) => productId !== input.newLines[index].productId)) {
    throw new TypeError('new item identity');
  }
  const stored = value.calculation;
  if (!plainObject(stored)) throw new TypeError('calculation');
  denseArray(stored.lines);
  if (stored.lines.length !== input.newLines.length) throw new TypeError('new line count');
  const calculation = calculateSale({
    invoiceRequested: invoiced,
    lines: input.newLines.map((line, index) => {
      const { pricing, quantity } = stored.lines[index];
      exactFields(pricing, [...PRICING_FIELDS, 'version']);
      if (pricing.version !== 1) throw new TypeError('pricing version');
      exactFields(quantity?.spec, ['unit', 'precision']);
      return {
        quantity: line.quantity,
        quantitySpec: { unit: quantity.spec.unit, precision: quantity.spec.precision },
        pricing: Object.fromEntries(PRICING_FIELDS.map((field) => [field, pricing[field]])),
      };
    }),
  });
  if (canonical(stored) !== canonical(calculation)) throw new TypeError('calculation differs');
  return Object.freeze({ productIds: Object.freeze([...input.newLines.map((line) => line.productId)]), calculation });
}

// Firestore map order is not guaranteed; compare all own keys without
// JSON.stringify silently dropping symbols, non-enumerable extras or holes.
function canonical(value) {
  if (Array.isArray(value)) {
    denseArray(value);
    return `[${value.map(canonical).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    const keys = Reflect.ownKeys(value);
    if (keys.some((key) => typeof key !== 'string')) throw new TypeError('symbol field');
    return `{${keys.sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  if (value === null || typeof value === 'string' || typeof value === 'boolean'
    || (typeof value === 'number' && Number.isFinite(value))) return JSON.stringify(value);
  throw new TypeError('unsupported snapshot value');
}
