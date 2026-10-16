import { createQuantitySpec, formatQuantity, parseQuantity } from './quantity.js';
import { addStockMovement } from './quantity.js';
import { isDeployedProjectRuntime } from './runtime-project.js';

const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
const PRICING_FIELDS = [
  'currency', 'ivaRateBasisPoints', 'ivaTreatment', 'listedPriceCentavos', 'priceMode',
];
const CALCULATION_POLICY = Object.freeze({
  version: 1,
  rounding: 'half-up',
  roundingScope: 'per-line',
  additionalIvaBase: 'rounded-line-base',
  includedIvaExtraction: 'not-calculated',
});

/**
 * Pure authoritative calculation, not authorization or a catalog lookup.
 * Callers supply trusted published pricing and stable quantity specifications.
 * Input: { invoiceRequested: Boolean, lines: [{ quantity: decimal string,
 * quantitySpec: { unit, precision }, pricing: the published pricing schema }] }.
 *
 * Every result is a detached, deeply frozen, JSON-compatible v1 snapshot.
 * baseCentavos is the rounded listed charge (gross in included mode), NOT a
 * fiscal net base. additionalIvaCentavos is always the actual extra charge.
 * includedIvaCentavos remains null: no included component is calculated here,
 * even for exempt/zero-rated policies. It must never be interpreted as zero.
 * No product identity, costs, actor metadata, payment or SDK state is accepted.
 */
export function calculateSale(input) {
  exactFields(input, ['invoiceRequested', 'lines'], 'sale');
  if (typeof input.invoiceRequested !== 'boolean') {
    throw new TypeError('invoiceRequested must be an explicit Boolean');
  }
  if (!Array.isArray(input.lines) || input.lines.length === 0) {
    throw new TypeError('sale lines must be a nonempty array');
  }

  const lines = [];
  let base = 0n;
  let additionalIva = 0n;
  let total = 0n;
  // Iteration deliberately visits sparse entries so they fail validation.
  for (const inputLine of input.lines) {
    const line = calculateLine(inputLine, input.invoiceRequested);
    base += BigInt(line.baseCentavos);
    additionalIva += BigInt(line.additionalIvaCentavos);
    total += BigInt(line.totalCentavos);
    safeNumber(total, 'sale total');
    lines.push(line);
  }

  return Object.freeze({
    version: 1,
    currency: 'MXN',
    invoiceRequested: input.invoiceRequested,
    calculationPolicy: CALCULATION_POLICY,
    lines: Object.freeze(lines),
    baseCentavos: safeNumber(base, 'sale base'),
    additionalIvaCentavos: safeNumber(additionalIva, 'sale additional IVA'),
    totalCentavos: safeNumber(total, 'sale total'),
  });
}

function calculateLine(input, invoiceRequested) {
  exactFields(input, ['pricing', 'quantity', 'quantitySpec'], 'line');
  exactFields(input.quantitySpec, ['precision', 'unit'], 'quantity specification');
  const spec = createQuantitySpec(input.quantitySpec);
  const scaled = parseQuantity(input.quantity, spec);
  if (scaled <= 0) throw new RangeError('sale quantity must be positive');
  const pricing = snapshotPricing(input.pricing);
  const scale = 10n ** BigInt(spec.precision);
  const base = halfUp(BigInt(scaled) * BigInt(pricing.listedPriceCentavos), scale);
  const baseCentavos = safeNumber(base, 'line base');

  const chargeIva = invoiceRequested
    && pricing.priceMode === 'iva-additional-on-invoice'
    && pricing.ivaTreatment === 'taxable';
  const additionalIva = chargeIva
    ? halfUp(base * BigInt(pricing.ivaRateBasisPoints), 10_000n)
    : 0n;

  return Object.freeze({
    quantity: Object.freeze({
      version: 1,
      spec,
      scaled,
      decimal: formatQuantity(scaled, spec),
    }),
    pricing,
    baseCentavos,
    additionalIvaCentavos: safeNumber(additionalIva, 'line additional IVA'),
    includedIvaCentavos: null,
    totalCentavos: safeNumber(base + additionalIva, 'line total'),
  });
}

// pricing.js keeps its stored-policy validator private. Mirror that published
// schema here without importing its service factory or relaxing its policies.
function snapshotPricing(value) {
  exactFields(value, PRICING_FIELDS, 'pricing');
  const { currency, listedPriceCentavos, priceMode, ivaTreatment, ivaRateBasisPoints } = value;
  if (currency !== 'MXN') throw new TypeError('pricing currency must be MXN');
  if (!Number.isSafeInteger(listedPriceCentavos) || listedPriceCentavos < 0) {
    throw new RangeError('listed price must be a nonnegative safe integer');
  }
  if (!['iva-included', 'iva-additional-on-invoice'].includes(priceMode)) {
    throw new TypeError('unsupported price mode');
  }
  if (!['taxable', 'zero-rated', 'exempt'].includes(ivaTreatment)) {
    throw new TypeError('unsupported IVA treatment');
  }
  if (
    (ivaTreatment === 'exempt' && ivaRateBasisPoints !== null)
    || (ivaTreatment === 'zero-rated' && ivaRateBasisPoints !== 0)
    || (ivaTreatment === 'taxable' && (
      !Number.isInteger(ivaRateBasisPoints)
      || ivaRateBasisPoints < 1 || ivaRateBasisPoints > 10_000
    ))
  ) {
    throw new RangeError('IVA rate must match its treatment and published bounds');
  }
  return Object.freeze({
    version: 1, currency, listedPriceCentavos, priceMode, ivaTreatment, ivaRateBasisPoints,
  });
}

function exactFields(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const fields = Reflect.ownKeys(value);
  if (fields.length !== expected.length || fields.some((field) => !expected.includes(field))) {
    throw new TypeError(`${label} contains missing or unsupported fields`);
  }
}

// All operands are nonnegative integers; double the numerator to implement
// nearest-integer rounding with exact half ties up, without floating point.
function halfUp(numerator, denominator) {
  return (2n * numerator + denominator) / (2n * denominator);
}

function safeNumber(value, label) {
  if (value < 0n || value > MAX_SAFE) {
    throw new RangeError(`${label} must fit in a nonnegative safe integer`);
  }
  return Number(value);
}

const SALE_ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
// Branch codes are 2-4 uppercase ASCII letters. Their uniqueness across
// branches is a seeding invariant (provision-demo-identities rejects
// duplicates); sales cannot cheaply prove it, so folio lookups must always be
// scoped by branchId and must treat several matches as ambiguous.
const BRANCH_CODE_PATTERN = /^[A-Z]{2,4}$/;
const RECEIPT_V1_FIELDS = ['version', 'saleId', 'branchId', 'productIds', 'calculation', 'payment'];
const RECEIPT_V2_FIELDS = [...RECEIPT_V1_FIELDS, 'branchCode', 'folio'];

export function isValidBranchCode(value) {
  return typeof value === 'string' && BRANCH_CODE_PATTERN.test(value);
}

/**
 * Short receipt number: <branch code>-<XXXX>-<XXXX> from the first eight
 * alphanumeric characters of the sale key, uppercased. For the UUID keys the
 * app sends this is exactly the first eight hex digits (NTE-3F2A-9C1B). It is
 * a human-friendly label, not an identity: collisions are possible and the
 * saleId stays the only unique key. Throws TypeError for an invalid code or a
 * key with fewer than eight alphanumeric characters.
 */
export function saleFolio(branchCode, saleId) {
  if (!isValidBranchCode(branchCode)) throw new TypeError('branch code is invalid');
  const head = folioHead(saleId);
  return `${branchCode}-${head.slice(0, 4)}-${head.slice(4)}`;
}

function folioHead(saleId) {
  const characters = typeof saleId === 'string' ? saleId.replace(/[^a-zA-Z0-9]/g, '') : '';
  if (characters.length < 8) throw new TypeError('sale key has fewer than eight alphanumeric characters');
  return characters.slice(0, 8).toUpperCase();
}

const SALE_REASON_PATTERN = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/;

/**
 * Stable machine reasons a SaleError may carry, shared by sales and corrections:
 * - paymentMismatch: a full payment differs from the authoritative total, or an
 *   exchange difference payment differs from what the customer owes;
 * - insufficientStock: branch stock cannot cover a sale line, a replacement or
 *   a new exchange item;
 * - folioAmbiguous: a correction folio lookup matched more than one sale;
 * - correctionWindowClosed: the sale is outside the correction window;
 * - overReturn: a return, replacement or exchange exceeds the remaining
 *   returnable quantity of a sale line.
 */
export const SALE_ERROR_REASONS = Object.freeze({
  paymentMismatch: 'payment-mismatch',
  insufficientStock: 'insufficient-stock',
  folioAmbiguous: 'folio-ambiguous',
  correctionWindowClosed: 'correction-window-closed',
  overReturn: 'over-return',
});

/**
 * Domain refusal with a public code and message. The optional `reason` is a
 * stable kebab-case machine signal (see SALE_ERROR_REASONS) the callable
 * forwards as HttpsError details { reason }, so clients never match English
 * messages.
 */
export class SaleError extends Error {
  constructor(code, message, reason) {
    super(message);
    this.name = 'SaleError';
    this.code = code;
    if (reason !== undefined) {
      if (typeof reason !== 'string' || !SALE_REASON_PATTERN.test(reason)) {
        throw new TypeError('sale error reason must be kebab-case');
      }
      this.reason = reason;
    }
  }
}

/** Sale-only, pure guard shared by service and callable before any SDK work. */
export function assertLocalSalesEmulator(environment = process.env) {
  // The deployed production project is trusted as-is; see runtime-project.js.
  if (isDeployedProjectRuntime(environment)) return;
  const projectId = 'demo-lda-inventory';
  let valid = environment?.GCLOUD_PROJECT === projectId
    && environment?.FUNCTIONS_EMULATOR === 'true'
    && environment?.FIRESTORE_EMULATOR_HOST === '127.0.0.1:8080';
  // Optional Admin project sources must agree, never override the pinned ID.
  if (environment?.GOOGLE_CLOUD_PROJECT !== undefined) {
    valid &&= environment.GOOGLE_CLOUD_PROJECT === projectId;
  }
  if (environment?.FIREBASE_CONFIG !== undefined) {
    try {
      // Accept inline JSON only: a config path must never trigger a file read.
      const config = typeof environment.FIREBASE_CONFIG === 'string'
        ? JSON.parse(environment.FIREBASE_CONFIG) : null;
      valid &&= config !== null && typeof config === 'object'
        && !Array.isArray(config) && config.projectId === projectId;
    } catch {
      valid = false;
    }
  }
  if (!valid) {
    throw new SaleError('failed-precondition', 'sales require the dedicated local demo emulator');
  }
}

/**
 * Injected Admin-Firestore-compatible service, not a callable registration.
 * Request.data has exactly { idempotencyKey, invoiceRequested, lines:
 * [{ productId, quantity }], payment: { method, amountCentavos } }.
 * Only trusted auth.token { role: 'seller', branchId } assigns the branch.
 * Duplicate products are rejected: merging could change per-line rounding.
 *
 * Returns { receipt, replayed, createdAt }; createdAt is the stored sale
 * timestamp in epoch milliseconds (a replay returns the original one, read
 * from the submission receipt's completedAt, which is written with the same
 * timestamp as sales.createdAt). receipt is a detached deeply frozen v2
 * { version: 2, saleId, branchId, branchCode, folio, productIds, calculation,
 * payment } snapshot. branchCode is read from branches/{branchId}.code at
 * sale time (a missing or invalid code fails closed) and folio is
 * saleFolio(branchCode, saleId); new sale keys therefore need at least eight
 * alphanumeric characters. Replays return the stored snapshot exactly,
 * including legacy v1 receipts written before folios existed, and never
 * depend on the current branch code.
 * sales stores { receipt, createdAt } (query receipt.branchId + receipt.folio
 * for folio lookups); saleAudits and saleSubmissionReceipts
 * hold private provenance. None of these collections grants client access.
 * Identifiers derive from the validated key/index, never callback randomness.
 */
export function createSaleService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  return async function submitSale(request = {}) {
    assertLocalSalesEmulator(environment);
    const { actorId, branchId } = saleSeller(request?.auth);
    // Copy every supported scalar before awaiting: caller mutation cannot change
    // the transaction or its actor/branch/request-bound fingerprint mid-flight.
    const input = saleInput(request?.data);
    const fingerprint = JSON.stringify({ actorId, branchId, ...input });
    const replayReference = firestore.doc(`saleSubmissionReceipts/${input.idempotencyKey}`);
    // Capture and validate invocation time once, outside retryable callbacks.
    // Defer clock errors until a new sale passes business validation: historical
    // replay and existing validation errors must not depend on today's clock.
    let invocationTime;
    try {
      const timestamp = now();
      saleTimestamp(timestamp);
      invocationTime = { timestamp };
    } catch (error) {
      invocationTime = { error };
    }

    return firestore.runTransaction(async (transaction) => {
      const replay = await transaction.get(replayReference);
      if (replay.exists) {
        return { ...validatedSaleReplay(replay.data(), input, actorId, branchId, fingerprint), replayed: true };
      }

      // A legacy key may replay above, but a new sale must yield a folio.
      try {
        folioHead(input.idempotencyKey);
      } catch {
        throw new SaleError('invalid-argument', 'sale key must contain at least eight alphanumeric characters');
      }
      const { branchCode, inputs } = await readSaleLines(firestore, transaction, branchId, input.lines);
      // All reads, including the replay ownership guard, finish before writes.
      // Line by line, so the first failing line decides the error, as before.
      const prepared = inputs.map((read) => {
        const line = prepareSaleLine(read);
        if (line.next === null) {
          throw new SaleError('failed-precondition', 'insufficient stock', SALE_ERROR_REASONS.insufficientStock);
        }
        return line;
      });
      const calculation = authoritativeCalculation(input.invoiceRequested, prepared);
      if (input.payment.amountCentavos !== calculation.totalCentavos) {
        throw new SaleError('invalid-argument', 'full payment must equal the authoritative total',
          SALE_ERROR_REASONS.paymentMismatch);
      }
      if (Object.hasOwn(invocationTime, 'error')) throw invocationTime.error;
      const { timestamp } = invocationTime;
      const receipt = saleReceipt(input, branchId, branchCode, calculation);
      transaction.create(firestore.doc(`sales/${input.idempotencyKey}`), {
        receipt, createdAt: timestamp,
      });
      transaction.create(firestore.doc(`saleAudits/${input.idempotencyKey}`), {
        saleId: input.idempotencyKey, branchId, actorId, createdAt: timestamp,
      });
      prepared.forEach(({ line, quantitySpec, scaled, next, stockReference }, index) => {
        const movementId = `sale-${input.idempotencyKey}-${index}`;
        transaction.create(firestore.doc(`inventoryMovements/${movementId}`), {
          type: 'sale', saleId: input.idempotencyKey, branchId,
          productId: line.productId, quantityScaled: -scaled, ...quantitySpec,
          actorId, occurredAt: timestamp,
        });
        transaction.set(stockReference, {
          quantityScaled: next, ...quantitySpec, updatedAt: timestamp, lastMovementId: movementId,
        });
      });
      // Create, never set/update: global key ownership conflicts roll back every
      // buffered write. Firestore transaction retries re-read this guard first.
      transaction.create(replayReference, {
        actorId, branchId, fingerprint, result: receipt, completedAt: timestamp,
      });
      return { receipt, replayed: false, createdAt: timestamp.getTime() };
    });
  };
}

/**
 * Injected Admin-Firestore-compatible read service, not a callable registration.
 * Request.data has exactly { invoiceRequested, lines: [{ productId, quantity }] },
 * validated with the same line rules as submitSale. Only trusted auth.token
 * { role: 'seller', branchId } assigns the branch.
 *
 * In one read-only transaction it reads the branch (whose code must be valid,
 * as for a sale), each product and its branch stock through the same helpers
 * submitSale uses, so `calculation` is exactly what a sale would charge now.
 * Returns a deeply frozen { calculation, totalCentavos, lines: [{ productId,
 * available }] }: insufficient or absent stock is reported per line instead of
 * thrown. It never writes, and never reads or returns costs or the branch.
 */
export function createSaleQuoteService({ firestore, environment = process.env } = {}) {
  if (!firestore || typeof firestore.doc !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }

  return async function quoteSale(request = {}) {
    assertLocalSalesEmulator(environment);
    const { branchId } = saleSeller(request?.auth);
    const input = quoteInput(request?.data);
    return firestore.runTransaction(async (transaction) => {
      const { inputs } = await readSaleLines(firestore, transaction, branchId, input.lines);
      const prepared = inputs.map(prepareSaleLine);
      const calculation = authoritativeCalculation(input.invoiceRequested, prepared);
      return Object.freeze({
        calculation,
        totalCentavos: calculation.totalCentavos,
        lines: Object.freeze(prepared.map(({ line, next }) => Object.freeze({
          productId: line.productId, available: next !== null,
        }))),
      });
    }, { readOnly: true });
  };
}

function quoteInput(data) {
  try {
    exactFields(data, ['invoiceRequested', 'lines'], 'request');
    if (typeof data.invoiceRequested !== 'boolean') throw new TypeError('invoice intent is required');
    return { invoiceRequested: data.invoiceRequested, lines: saleLinesInput(data.lines) };
  } catch {
    throw new SaleError('invalid-argument', 'quote request contains missing, invalid or unsupported fields');
  }
}

// Shared sale and quote reads: the branch and its code first, then every
// product with its branch stock.
async function readSaleLines(firestore, transaction, branchId, lines) {
  const branch = await transaction.get(firestore.doc(`branches/${branchId}`));
  if (!branch.exists) throw new SaleError('not-found', 'branch does not exist');
  const branchCode = branch.data()?.code;
  if (!isValidBranchCode(branchCode)) {
    throw new SaleError('failed-precondition', 'branch code is missing or invalid');
  }
  const inputs = await Promise.all(lines.map(async (line) => {
    const stockReference = firestore.doc(`branches/${branchId}/stock/${line.productId}`);
    const [product, stock] = await Promise.all([
      transaction.get(firestore.doc(`products/${line.productId}`)),
      transaction.get(stockReference),
    ]);
    return { line, product, stock, stockReference };
  }));
  return { branchCode, inputs };
}

// Validates one read line with the stored product policies. `next` is the
// stock after selling the line, or null when the stock cannot cover it.
function prepareSaleLine({ line, product, stock, stockReference }) {
  if (!product.exists) throw new SaleError('not-found', 'product does not exist');
  const data = product.data();
  const quantitySpec = saleStoredSpec(data?.quantitySpec);
  const scaled = saleQuantity(line.quantity, quantitySpec);
  const pricing = saleStoredPricing(data?.pricing);
  const current = saleCurrentStock(stock, quantitySpec);
  let next = null;
  try {
    next = addStockMovement(current, -scaled, quantitySpec, quantitySpec);
  } catch {
    // Reported by the caller: a sale fails, a quote marks the line unavailable.
  }
  return { line, quantitySpec, pricing, scaled, next, stockReference };
}

function authoritativeCalculation(invoiceRequested, prepared) {
  try {
    return calculateSale({
      invoiceRequested,
      lines: prepared.map(({ line, quantitySpec, pricing }) => ({
        quantity: line.quantity, quantitySpec, pricing,
      })),
    });
  } catch {
    // Quantity and stored policies were validated separately above; the
    // remaining calculation failure is an unsafe monetary result.
    throw new SaleError('out-of-range', 'sale calculation exceeds safe bounds');
  }
}

function saleSeller(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new SaleError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'seller' || !saleValidId(auth.token?.branchId)) {
    throw new SaleError('permission-denied', 'an assigned seller is required');
  }
  return { actorId: auth.uid, branchId: auth.token.branchId };
}

function saleValidId(value) {
  return typeof value === 'string' && SALE_ID_PATTERN.test(value);
}

// Shared by sales and quotes: a dense, nonempty list of unique products with
// canonical positive decimal quantities. Throws TypeError; callers map it.
function saleLinesInput(value) {
  saleDenseArray(value);
  if (value.length === 0) throw new TypeError('lines are required');
  const seen = new Set();
  return value.map((line) => {
    exactFields(line, ['productId', 'quantity'], 'request line');
    if (!saleValidId(line.productId) || seen.has(line.productId)) {
      throw new TypeError('product must be unique and valid');
    }
    seen.add(line.productId);
    // Precision and safe scaled bounds require the authoritative spec later.
    if (typeof line.quantity !== 'string' || line.quantity.length > 18
      || !/^(?:0|[1-9]\d*)(?:\.\d+)?$/.test(line.quantity)
      || !/[1-9]/.test(line.quantity)) {
      throw new TypeError('quantity must be a canonical positive decimal string');
    }
    return { productId: line.productId, quantity: line.quantity };
  });
}

function saleInput(data) {
  try {
    exactFields(data, ['idempotencyKey', 'invoiceRequested', 'lines', 'payment'], 'request');
    if (!saleValidId(data.idempotencyKey) || typeof data.invoiceRequested !== 'boolean') {
      throw new TypeError('key and invoice intent are required');
    }
    const lines = saleLinesInput(data.lines);
    exactFields(data.payment, ['method', 'amountCentavos'], 'payment');
    if (!['cash', 'card', 'transfer'].includes(data.payment.method)
      || !Number.isSafeInteger(data.payment.amountCentavos) || data.payment.amountCentavos < 0) {
      throw new TypeError('payment must be a supported method and safe centavo amount');
    }
    return {
      idempotencyKey: data.idempotencyKey, invoiceRequested: data.invoiceRequested, lines,
      payment: { method: data.payment.method, amountCentavos: data.payment.amountCentavos },
    };
  } catch {
    throw new SaleError('invalid-argument', 'sale request contains missing, invalid or unsupported fields');
  }
}

function saleStoredSpec(value) {
  try {
    exactFields(value, ['unit', 'precision'], 'quantity specification');
    return createQuantitySpec(value);
  } catch {
    throw new SaleError('failed-precondition', 'product quantity specification is invalid');
  }
}

// Exported so the exchange service validates new items with this exact rule
// instead of a drifting copy (CORR-07P).
export function saleStoredPricing(value) {
  try {
    const snapshot = snapshotPricing(value);
    // calculateSale accepts the published policy, not its output version field.
    return Object.fromEntries(PRICING_FIELDS.map((key) => [key, snapshot[key]]));
  } catch {
    throw new SaleError('failed-precondition', 'product pricing is invalid');
  }
}

export function saleQuantity(value, spec) {
  try {
    const scaled = parseQuantity(value, spec);
    if (scaled <= 0) throw new RangeError('not positive');
    return scaled;
  } catch {
    throw new SaleError('invalid-argument', 'quantity is not representable by the product specification');
  }
}

function saleCurrentStock(snapshot, spec) {
  if (!snapshot.exists) return 0;
  const value = snapshot.data();
  if (value?.unit !== spec.unit || value?.precision !== spec.precision
    || !Number.isSafeInteger(value?.quantityScaled) || value.quantityScaled < 0) {
    throw new SaleError('failed-precondition', 'stock projection is invalid');
  }
  return value.quantityScaled;
}

// Returns the epoch milliseconds of a valid persisted or captured timestamp.
function saleTimestamp(value) {
  // Admin reads Date writes back as Timestamp; support both without importing
  // or initializing the SDK. Reject strings and sentinel/nonfinite values.
  try {
    const date = value instanceof Date
      ? value
      : typeof value?.toDate === 'function' ? value.toDate() : null;
    const milliseconds = date instanceof Date ? date.getTime() : NaN;
    if (Number.isSafeInteger(milliseconds) && milliseconds >= 0) return milliseconds;
  } catch {
    // A malformed persisted Timestamp adapter also fails with the domain error.
  }
  throw new SaleError('failed-precondition', 'sale timestamp is invalid');
}

// branchCode === null builds the legacy v1 shape, used only to validate and
// return replays persisted before folios existed.
function saleReceipt(input, branchId, branchCode, calculation) {
  const common = {
    saleId: input.idempotencyKey, branchId,
    productIds: Object.freeze(input.lines.map((line) => line.productId)),
    calculation, payment: Object.freeze({ ...input.payment }),
  };
  if (branchCode === null) return Object.freeze({ version: 1, ...common });
  return Object.freeze({
    version: 2, ...common, branchCode, folio: saleFolio(branchCode, input.idempotencyKey),
  });
}

function validatedSaleReplay(record, input, actorId, branchId, fingerprint) {
  // Ownership is checked before touching private result fields; a collision
  // never reveals another seller's historical receipt or decrements stock.
  if (record?.actorId !== actorId || record?.branchId !== branchId || record?.fingerprint !== fingerprint) {
    throw new SaleError('already-exists', 'idempotency key is already owned by a different submission');
  }
  try {
    exactFields(record, ['actorId', 'branchId', 'fingerprint', 'result', 'completedAt'], 'replay');
    // completedAt is written with the same timestamp as sales.createdAt.
    const createdAt = saleTimestamp(record.completedAt);
    const receipt = record.result;
    // Version selects the exact shape; the stored code (not today's branch
    // code) rebuilds the folio, so a valid replay never depends on the branch.
    const legacy = receipt?.version === 1;
    exactFields(receipt, legacy ? RECEIPT_V1_FIELDS : RECEIPT_V2_FIELDS, 'receipt');
    if (!legacy && !isValidBranchCode(receipt.branchCode)) throw new TypeError('branch code');
    saleDenseArray(receipt.calculation.lines);
    if (receipt.calculation.lines.length !== input.lines.length) throw new TypeError('line count');
    // Recompute only from immutable stored policy, never a repriced catalog.
    // Compare the complete v1 snapshot, catching altered totals/scales/policy,
    // unsupported fields, private metadata and malformed precision/overflow.
    const calculation = calculateSale({
      invoiceRequested: input.invoiceRequested,
      lines: input.lines.map((line, index) => {
        const stored = receipt.calculation.lines[index];
        exactFields(stored.pricing, [...PRICING_FIELDS, 'version'], 'snapshot pricing');
        if (stored.pricing.version !== 1) throw new TypeError('pricing version');
        return {
          quantity: line.quantity, quantitySpec: stored.quantity.spec,
          pricing: Object.fromEntries(PRICING_FIELDS.map((key) => [key, stored.pricing[key]])),
        };
      }),
    });
    const expected = saleReceipt(input, branchId, legacy ? null : receipt.branchCode, calculation);
    if (calculation.totalCentavos !== input.payment.amountCentavos
      || saleCanonical(receipt) !== saleCanonical(expected)) {
      throw new TypeError('receipt snapshot differs');
    }
    return { receipt: expected, createdAt };
  } catch {
    throw new SaleError('failed-precondition', 'persisted sale replay is invalid');
  }
}

function saleDenseArray(value) {
  if (!Array.isArray(value) || Reflect.ownKeys(value).length !== value.length + 1) {
    throw new TypeError('a dense array without extra fields is required');
  }
  for (let index = 0; index < value.length; index++) {
    if (!Object.hasOwn(value, index)) throw new TypeError('sparse array');
  }
}

// Map ordering is not guaranteed by Firestore. Compare all own keys without
// JSON.stringify silently ignoring symbols, non-enumerable extras or holes.
function saleCanonical(value) {
  if (Array.isArray(value)) {
    saleDenseArray(value);
    return `[${value.map(saleCanonical).join(',')}]`;
  }
  if (value !== null && typeof value === 'object') {
    const keys = Reflect.ownKeys(value);
    if (keys.some((key) => typeof key !== 'string')) throw new TypeError('symbol field');
    return `{${keys.sort().map((key) => `${JSON.stringify(key)}:${saleCanonical(value[key])}`).join(',')}}`;
  }
  if (value === null || typeof value === 'string' || typeof value === 'boolean'
    || (typeof value === 'number' && Number.isFinite(value))) return JSON.stringify(value);
  throw new TypeError('unsupported snapshot value');
}
