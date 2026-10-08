import { createQuantitySpec, formatQuantity, parseQuantity } from './quantity.js';

/** Fixed global correction window: exactly 15×24h from the sale's createdAt. */
export const CORRECTION_WINDOW_MS = 15 * 24 * 60 * 60 * 1000;

const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
const PAYMENT_METHODS = ['cash', 'card', 'transfer'];
const REFUND_POLICY = Object.freeze({
  version: 1,
  rounding: 'half-up',
  roundingScope: 'cumulative-per-line-component',
  refundBasis: 'sale-snapshot',
  refundMethod: 'original-payment-method',
});

export class CorrectionError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'CorrectionError';
    this.code = code;
  }
}

/**
 * Pure window guard. Both arguments are epoch milliseconds as safe integers.
 * Accepts only 0 <= now - createdAt < CORRECTION_WINDOW_MS; a future sale
 * timestamp is rejected rather than treated as fresh.
 */
export function assertCorrectionWindow(createdAtMs, nowMs) {
  if (!isNonNegativeSafe(createdAtMs) || !isNonNegativeSafe(nowMs)) {
    throw new CorrectionError('invalid-argument', 'timestamps must be nonnegative safe integers');
  }
  const elapsed = nowMs - createdAtMs;
  if (elapsed < 0 || elapsed >= CORRECTION_WINDOW_MS) {
    throw new CorrectionError('failed-precondition', 'sale is outside the correction window');
  }
}

/**
 * Remaining returnable scaled quantity per sale line.
 * Input: { lines: receipt.calculation.lines, returned: { [lineIndex]: scaled } }.
 * Missing ledger entries mean nothing was returned for that line yet.
 */
export function calculateRemainingReturnable({ lines, returned } = {}) {
  const sold = soldLines(lines);
  const previous = returnedLedger(returned, sold);
  return Object.freeze(sold.map(({ scaled }, lineIndex) => Object.freeze({
    lineIndex,
    soldScaled: scaled,
    returnedScaled: previous[lineIndex],
    remainingScaled: scaled - previous[lineIndex],
  })));
}

/**
 * Proportional refund at the sale's frozen snapshot, never at current prices.
 * Input: { receipt: the frozen v1 sale receipt, returned: the ledger accepted
 * by calculateRemainingReturnable, lines: [{ lineIndex, quantity }] } where
 * quantity is a canonical decimal string at the product precision.
 *
 * Each component uses cumulative rounding: the refund is the rounded amount for
 * the cumulative returned quantity minus the rounded amount already refunded,
 * so any sequence of partial returns sums exactly to the original line.
 */
export function calculateReturnRefund({ receipt, returned, lines: request } = {}) {
  const sale = saleSnapshot(receipt);
  const previous = returnedLedger(returned, sale.lines);
  if (!Array.isArray(request) || request.length === 0) {
    throw new CorrectionError('invalid-argument', 'return lines must be a nonempty array');
  }
  const seen = new Set();
  const lines = [];
  let base = 0n;
  let additionalIva = 0n;
  for (let position = 0; position < request.length; position += 1) {
    const entry = request[position];
    exactFields(entry, ['lineIndex', 'quantity'], 'return line');
    const { lineIndex } = entry;
    if (!Number.isSafeInteger(lineIndex) || lineIndex < 0 || lineIndex >= sale.lines.length) {
      throw new CorrectionError('invalid-argument', 'return line index is unknown');
    }
    if (seen.has(lineIndex)) {
      throw new CorrectionError('invalid-argument', 'return line indexes must be unique');
    }
    seen.add(lineIndex);
    const sold = sale.lines[lineIndex];
    const scaled = returnQuantity(entry.quantity, sold.spec);
    const prior = BigInt(previous[lineIndex]);
    const cumulative = prior + BigInt(scaled);
    if (cumulative > BigInt(sold.scaled)) {
      throw new CorrectionError('out-of-range', 'return exceeds the remaining sold quantity');
    }
    const lineBase = cumulativeShare(sold.baseCentavos, prior, cumulative, sold.scaled);
    const lineIva = cumulativeShare(sold.additionalIvaCentavos, prior, cumulative, sold.scaled);
    base += lineBase;
    additionalIva += lineIva;
    lines.push(Object.freeze({
      lineIndex,
      productId: sale.productIds[lineIndex],
      quantity: Object.freeze({ scaled, decimal: formatQuantity(scaled, sold.spec) }),
      baseCentavos: safeNumber(lineBase, 'refund base'),
      additionalIvaCentavos: safeNumber(lineIva, 'refund additional IVA'),
      totalCentavos: safeNumber(lineBase + lineIva, 'refund line total'),
    }));
  }
  return Object.freeze({
    version: 1,
    currency: 'MXN',
    calculationPolicy: REFUND_POLICY,
    invoiced: sale.invoiceRequested,
    refundMethod: sale.method,
    lines: Object.freeze(lines),
    baseCentavos: safeNumber(base, 'refund base'),
    additionalIvaCentavos: safeNumber(additionalIva, 'refund additional IVA'),
    totalCentavos: safeNumber(base + additionalIva, 'refund total'),
  });
}

/**
 * Exchange difference: the returned value at the snapshot (a calculateReturnRefund
 * result) against new items priced by calculateSale with CURRENT pricing and the
 * original sale's invoice intent. Exactly one side is positive, or both are zero.
 */
export function calculateExchangeSettlement({ refund, newItems } = {}) {
  if (refund === null || typeof refund !== 'object' || refund.version !== 1
    || typeof refund.invoiced !== 'boolean' || !PAYMENT_METHODS.includes(refund.refundMethod)) {
    throw new CorrectionError('invalid-argument', 'a return refund calculation is required');
  }
  if (newItems === null || typeof newItems !== 'object' || newItems.version !== 1
    || newItems.currency !== 'MXN') {
    throw new CorrectionError('invalid-argument', 'a new-item MXN sale calculation is required');
  }
  if (newItems.invoiceRequested !== refund.invoiced) {
    throw new CorrectionError('invalid-argument', 'new items must keep the original invoice intent');
  }
  const returnedCentavos = centavos(refund.totalCentavos, 'returned total');
  const newItemCentavos = centavos(newItems.totalCentavos, 'new item total');
  const difference = newItemCentavos - returnedCentavos;
  return Object.freeze({
    version: 1,
    returnedCentavos,
    newItemCentavos,
    customerPaysCentavos: Math.max(difference, 0),
    refundCentavos: Math.max(-difference, 0),
    refundMethod: refund.refundMethod,
  });
}

function saleSnapshot(receipt) {
  if (receipt === null || typeof receipt !== 'object' || receipt.version !== 1) {
    throw new CorrectionError('invalid-argument', 'a v1 sale receipt is required');
  }
  const { calculation, payment, productIds } = receipt;
  if (calculation === null || typeof calculation !== 'object' || calculation.version !== 1
    || typeof calculation.invoiceRequested !== 'boolean') {
    throw new CorrectionError('invalid-argument', 'the receipt calculation is invalid');
  }
  const lines = soldLines(calculation.lines);
  if (!Array.isArray(productIds) || productIds.length !== lines.length
    || productIds.some((id) => typeof id !== 'string' || id.length === 0)) {
    throw new CorrectionError('invalid-argument', 'receipt product identities are invalid');
  }
  if (payment === null || typeof payment !== 'object' || !PAYMENT_METHODS.includes(payment.method)) {
    throw new CorrectionError('invalid-argument', 'receipt payment method is unsupported');
  }
  return {
    lines, productIds, invoiceRequested: calculation.invoiceRequested, method: payment.method,
  };
}

function soldLines(lines) {
  if (!Array.isArray(lines) || lines.length === 0) {
    throw new CorrectionError('invalid-argument', 'sale lines must be a nonempty array');
  }
  const result = [];
  for (let index = 0; index < lines.length; index += 1) {
    result.push(soldLine(lines[index]));
  }
  return result;
}

// Persisted receipts are untrusted input: any malformed shape, including a
// hostile accessor, surfaces as invalid-argument rather than a raw TypeError.
function soldLine(line) {
  let fields;
  try {
    const quantity = line?.quantity;
    if (line === null || typeof line !== 'object' || Array.isArray(line)
      || quantity === null || typeof quantity !== 'object' || Array.isArray(quantity)) {
      throw new TypeError('sale line shape');
    }
    fields = {
      spec: quantity.spec,
      scaled: quantity.scaled,
      baseCentavos: line.baseCentavos,
      additionalIvaCentavos: line.additionalIvaCentavos,
      totalCentavos: line.totalCentavos,
    };
  } catch {
    throw new CorrectionError('invalid-argument', 'sale line must be an object with a quantity');
  }
  let spec;
  try {
    spec = createQuantitySpec(fields.spec ?? {});
  } catch {
    throw new CorrectionError('invalid-argument', 'sale line quantity specification is invalid');
  }
  const { scaled, baseCentavos, additionalIvaCentavos, totalCentavos } = fields;
  if (!isNonNegativeSafe(scaled) || scaled === 0
    || !isNonNegativeSafe(baseCentavos) || !isNonNegativeSafe(additionalIvaCentavos)
    || totalCentavos !== baseCentavos + additionalIvaCentavos) {
    throw new CorrectionError('invalid-argument', 'sale line amounts are invalid');
  }
  return { spec, scaled, baseCentavos, additionalIvaCentavos };
}

function returnedLedger(returned, lines) {
  if (returned === null || typeof returned !== 'object' || Array.isArray(returned)) {
    throw new CorrectionError('invalid-argument', 'returned ledger must be an object');
  }
  const ledger = lines.map(() => 0);
  for (const key of Reflect.ownKeys(returned)) {
    const index = typeof key === 'string' && /^(?:0|[1-9]\d*)$/.test(key) ? Number(key) : -1;
    if (index < 0 || index >= lines.length) {
      throw new CorrectionError('invalid-argument', 'returned ledger has an unknown line index');
    }
    const value = returned[key];
    if (!isNonNegativeSafe(value)) {
      throw new CorrectionError('invalid-argument', 'returned quantities must be nonnegative safe integers');
    }
    if (value > lines[index].scaled) {
      throw new CorrectionError('failed-precondition', 'returned quantity exceeds the sold quantity');
    }
    ledger[index] = value;
  }
  return ledger;
}

function returnQuantity(quantity, spec) {
  let scaled;
  try {
    scaled = parseQuantity(quantity, spec);
  } catch {
    throw new CorrectionError('invalid-argument', 'return quantity must match the product precision');
  }
  if (scaled <= 0) throw new CorrectionError('invalid-argument', 'return quantity must be positive');
  return scaled;
}

function cumulativeShare(amount, prior, cumulative, sold) {
  const total = BigInt(amount);
  const denominator = BigInt(sold);
  return halfUp(cumulative * total, denominator) - halfUp(prior * total, denominator);
}

// sales.js keeps halfUp, safeNumber and exactFields private; these are minimal
// local equivalents so the sales module stays untouched.
function halfUp(numerator, denominator) {
  return (2n * numerator + denominator) / (2n * denominator);
}

function safeNumber(value, label) {
  if (value < 0n || value > MAX_SAFE) {
    throw new CorrectionError('out-of-range', `${label} must fit in a nonnegative safe integer`);
  }
  return Number(value);
}

function centavos(value, label) {
  if (!isNonNegativeSafe(value)) {
    throw new CorrectionError('invalid-argument', `${label} must be a nonnegative safe integer`);
  }
  return value;
}

function exactFields(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new CorrectionError('invalid-argument', `${label} must be an object`);
  }
  const fields = Reflect.ownKeys(value);
  if (fields.length !== expected.length || fields.some((field) => !expected.includes(field))) {
    throw new CorrectionError('invalid-argument', `${label} contains missing or unsupported fields`);
  }
}

function isNonNegativeSafe(value) {
  return Number.isSafeInteger(value) && value >= 0;
}
