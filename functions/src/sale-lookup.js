import {
  CORRECTION_WINDOW_MS, assertCorrectionWindow, calculateRemainingReturnable,
} from './corrections-calculation.js';
import {
  SALE_ERROR_REASONS, SaleError, assertLocalSalesEmulator, calculateSale, isValidBranchCode, saleFolio,
} from './sales.js';

const SALE_ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
// The receipt folio as sales.js saleFolio builds it. Input is trimmed and
// uppercased before this check; raw input is capped so trimming stays bounded.
const FOLIO_PATTERN = /^[A-Z]{2,4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/;
const FOLIO_INPUT_MAX_LENGTH = 32;
// More than one match is already ambiguous; read one extra as evidence only.
const FOLIO_MATCH_LIMIT = 3;
const PAYMENT_METHODS = ['cash', 'card', 'transfer'];
const RECEIPT_V1_FIELDS = ['version', 'saleId', 'branchId', 'productIds', 'calculation', 'payment'];
const RECEIPT_V2_FIELDS = [...RECEIPT_V1_FIELDS, 'branchCode', 'folio'];
const PRICING_FIELDS = [
  'currency', 'ivaRateBasisPoints', 'ivaTreatment', 'listedPriceCentavos', 'priceMode',
];
export const RECENT_SALES_DEFAULT_LIMIT = 50;
export const RECENT_SALES_MAX_LIMIT = 100;

/**
 * Injected Admin-Firestore-compatible read service, not a callable registration.
 * Only an authenticated seller (trusted auth.token { role: 'seller', branchId })
 * may look up sales, and only those of the token's branch inside the 15-day
 * correction window. Reads run in one read-only transaction and never write.
 *
 * findSale: request.data is exactly { saleId } or exactly { folio }. A missing
 * sale and another branch's sale both fail with the same not-found error; an
 * own-branch sale outside the window fails with failed-precondition. A folio
 * (for example NTE-3F2A-9C1B) is trimmed and uppercased, then matched by one
 * query on the seller's branch inside the window, newest first: no match is
 * that same not-found (so a foreign or expired folio reveals nothing), two or
 * more matches fail with failed-precondition as ambiguous, and the single
 * match is validated and returned exactly like a saleId lookup.
 * listRecentSales: request.data is {} or { limit } (1..100, default 50); the
 * branch's in-window sales, newest first.
 *
 * Each sale is a detached, deeply frozen { saleId, folio (null for legacy v1
 * receipts), createdAt (epoch ms), receipt: { calculation, payment, productIds, invoiceRequested }, lines }
 * where lines are calculateRemainingReturnable results against the optional
 * saleReturnLedgers/{saleId} { returned: { [lineIndex]: scaled } } document.
 * The calculation is recomputed from its stored policy and must match exactly,
 * so audits, actors, provenance and acquisition costs can never be exposed.
 * Stored receipts are v1 (legacy, no folio) or v2 (with branchCode and the
 * folio derived from it); both stay readable and each must match its exact
 * shape; only the folio is exposed, never the stored branch code or branch.
 */
export function createSaleLookupService({
  firestore, now = () => new Date(), environment = process.env,
} = {}) {
  if (!firestore || typeof firestore.doc !== 'function'
    || typeof firestore.collection !== 'function' || typeof firestore.runTransaction !== 'function') {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (typeof now !== 'function') throw new TypeError('now must be a function');

  async function findSale(request = {}) {
    assertLocalSalesEmulator(environment);
    const { branchId } = lookupSeller(request?.auth);
    const { saleId, folio } = findInput(request?.data);
    const nowMs = invocationMs(now);
    return firestore.runTransaction(async (transaction) => {
      if (saleId !== undefined) {
        const snapshot = await transaction.get(firestore.doc(`sales/${saleId}`));
        return correctableSale(transaction, saleId, snapshot.exists ? snapshot.data() : undefined);
      }
      const { docs } = await transaction.get(
        branchWindowQuery(branchId, nowMs, folio).limit(FOLIO_MATCH_LIMIT));
      if (docs.length === 0) throw notFound();
      if (docs.length > 1) {
        throw new SaleError('failed-precondition',
          'folio is ambiguous; use the full receipt id or the recent list', SALE_ERROR_REASONS.folioAmbiguous);
      }
      return correctableSale(transaction, docs[0].id, docs[0].data());
    }, { readOnly: true });

    async function correctableSale(transaction, id, record) {
      // Missing and foreign sales share one answer: existence never leaks.
      if (!ownBranch(record, branchId)) throw notFound();
      const sale = storedSale(id, record);
      try {
        assertCorrectionWindow(sale.createdAt, nowMs);
      } catch {
        throw new SaleError('failed-precondition', 'sale is outside the correction window',
          SALE_ERROR_REASONS.correctionWindowClosed);
      }
      const ledger = await transaction.get(firestore.doc(`saleReturnLedgers/${id}`));
      return Object.freeze({ sale: lookupResult(sale, ledger) });
    }
  }

  // The seller's branch inside the correction window, newest first, optionally
  // narrowed to one folio. Each filter set matches a declared composite index.
  function branchWindowQuery(branchId, nowMs, folio) {
    let query = firestore.collection('sales').where('receipt.branchId', '==', branchId);
    if (folio !== undefined) query = query.where('receipt.folio', '==', folio);
    return query
      .where('createdAt', '>', new Date(nowMs - CORRECTION_WINDOW_MS))
      .where('createdAt', '<=', new Date(nowMs))
      .orderBy('createdAt', 'desc');
  }

  async function listRecentSales(request = {}) {
    assertLocalSalesEmulator(environment);
    const { branchId } = lookupSeller(request?.auth);
    const limit = listInput(request?.data);
    const nowMs = invocationMs(now);
    const query = branchWindowQuery(branchId, nowMs).limit(limit);
    return firestore.runTransaction(async (transaction) => {
      const { docs } = await transaction.get(query);
      const sales = docs.map((doc) => {
        const record = doc.data();
        if (!ownBranch(record, branchId)) {
          throw new SaleError('failed-precondition', 'persisted sale is invalid');
        }
        const sale = storedSale(doc.id, record);
        try {
          assertCorrectionWindow(sale.createdAt, nowMs);
        } catch {
          throw new SaleError('failed-precondition', 'persisted sale is invalid');
        }
        return sale;
      });
      const ledgers = await Promise.all(sales.map((sale) =>
        transaction.get(firestore.doc(`saleReturnLedgers/${sale.saleId}`))));
      return Object.freeze({
        sales: Object.freeze(sales.map((sale, index) => lookupResult(sale, ledgers[index]))),
      });
    }, { readOnly: true });
  }

  return Object.freeze({ findSale, listRecentSales });
}

// Mirrors sales.js saleSeller: administrators and every other role are denied.
function lookupSeller(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new SaleError('unauthenticated', 'authentication is required');
  }
  if (auth.token?.role !== 'seller' || !validId(auth.token?.branchId)) {
    throw new SaleError('permission-denied', 'an assigned seller is required');
  }
  return { branchId: auth.token.branchId };
}

// Exactly one of { saleId } (verbatim) or { folio } (trimmed and uppercased,
// so a dictated 'nte-3f2a-9c1b' works). Both together are rejected.
function findInput(data) {
  if (plainObject(data)) {
    if (sameFields(data, ['saleId']) && validId(data.saleId)) return { saleId: data.saleId };
    if (sameFields(data, ['folio']) && typeof data.folio === 'string'
      && data.folio.length <= FOLIO_INPUT_MAX_LENGTH) {
      const folio = data.folio.trim().toUpperCase();
      if (FOLIO_PATTERN.test(folio)) return { folio };
    }
  }
  throw new SaleError('invalid-argument', 'sale lookup requires exactly one valid saleId or folio');
}

function notFound() {
  return new SaleError('not-found', 'sale was not found in this branch');
}

function listInput(data) {
  if (!plainObject(data)) {
    throw new SaleError('invalid-argument', 'recent sales request must be an object');
  }
  if (sameFields(data, [])) return RECENT_SALES_DEFAULT_LIMIT;
  if (!sameFields(data, ['limit']) || !Number.isSafeInteger(data.limit)
    || data.limit < 1 || data.limit > RECENT_SALES_MAX_LIMIT) {
    throw new SaleError('invalid-argument',
      `recent sales accept only a limit from 1 through ${RECENT_SALES_MAX_LIMIT}`);
  }
  return data.limit;
}

function invocationMs(now) {
  try {
    const value = now();
    if (value instanceof Date && Number.isSafeInteger(value.getTime()) && value.getTime() >= 0) {
      return value.getTime();
    }
  } catch {
    // A failing clock surfaces as the same domain error as an invalid one.
  }
  throw new SaleError('failed-precondition', 'lookup clock is invalid');
}

function ownBranch(record, branchId) {
  return plainObject(record) && plainObject(record.receipt) && record.receipt.branchId === branchId;
}

// Strict, fail-closed projection of a persisted sales/{saleId} record.
function storedSale(saleId, record) {
  try {
    exactFields(record, ['receipt', 'createdAt']);
    const { receipt } = record;
    const legacy = receipt?.version === 1;
    exactFields(receipt, legacy ? RECEIPT_V1_FIELDS : RECEIPT_V2_FIELDS);
    exactFields(receipt.payment, ['method', 'amountCentavos']);
    const { calculation, payment, productIds } = receipt;
    // saleFolio rejects an invalid code; the stored folio must equal the
    // derivation from the stored code and this document's own saleId.
    if (!legacy && (receipt.version !== 2 || !isValidBranchCode(receipt.branchCode)
      || receipt.folio !== saleFolio(receipt.branchCode, saleId))) {
      throw new TypeError('receipt folio');
    }
    if (receipt.saleId !== saleId
      || !PAYMENT_METHODS.includes(payment.method)
      || !Array.isArray(productIds) || productIds.some((id) => !validId(id))) {
      throw new TypeError('receipt identity');
    }
    // Recompute only from immutable stored policy; any extra or altered field
    // (for example a cost) makes the snapshot differ and the record is refused.
    const expected = calculateSale({
      invoiceRequested: calculation.invoiceRequested,
      lines: calculation.lines.map((line) => {
        exactFields(line.pricing, [...PRICING_FIELDS, 'version']);
        if (line.pricing.version !== 1) throw new TypeError('pricing version');
        return {
          quantity: line.quantity.decimal, quantitySpec: line.quantity.spec,
          pricing: Object.fromEntries(PRICING_FIELDS.map((key) => [key, line.pricing[key]])),
        };
      }),
    });
    if (canonical(calculation) !== canonical(expected) || productIds.length !== expected.lines.length
      || payment.amountCentavos !== expected.totalCentavos) {
      throw new TypeError('receipt snapshot differs');
    }
    return {
      saleId,
      folio: legacy ? null : receipt.folio,
      branchCode: legacy ? null : receipt.branchCode,
      createdAt: timestampMs(record.createdAt),
      calculation: expected,
      payment: Object.freeze({ method: payment.method, amountCentavos: payment.amountCentavos }),
      productIds: Object.freeze([...productIds]),
    };
  } catch {
    throw new SaleError('failed-precondition', 'persisted sale is invalid');
  }
}

function lookupResult(sale, ledger) {
  let lines;
  try {
    const returned = ledger.exists ? ledger.data()?.returned : {};
    lines = calculateRemainingReturnable({ lines: sale.calculation.lines, returned });
  } catch {
    throw new SaleError('failed-precondition', 'persisted sale return ledger is invalid');
  }
  return Object.freeze({
    saleId: sale.saleId,
    folio: sale.folio,
    createdAt: sale.createdAt,
    receipt: Object.freeze({
      calculation: sale.calculation,
      payment: sale.payment,
      productIds: sale.productIds,
      invoiceRequested: sale.calculation.invoiceRequested,
    }),
    lines,
  });
}

function timestampMs(value) {
  // Admin reads Date writes back as Timestamp; accept both without the SDK.
  const date = value instanceof Date
    ? value
    : typeof value?.toDate === 'function' ? value.toDate() : null;
  if (!(date instanceof Date) || !Number.isSafeInteger(date.getTime()) || date.getTime() < 0) {
    throw new TypeError('sale timestamp is invalid');
  }
  return date.getTime();
}

function validId(value) {
  return typeof value === 'string' && SALE_ID_PATTERN.test(value);
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function sameFields(value, expected) {
  const fields = Reflect.ownKeys(value);
  return fields.length === expected.length && fields.every((field) => expected.includes(field));
}

function exactFields(value, expected) {
  if (!plainObject(value) || !sameFields(value, expected)) {
    throw new TypeError('missing or unsupported fields');
  }
}

// Firestore map ordering is not guaranteed; compare every own key sorted.
function canonical(value) {
  if (Array.isArray(value)) {
    if (Reflect.ownKeys(value).length !== value.length + 1) throw new TypeError('array fields');
    return `[${Array.from(value, canonical).join(',')}]`;
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

// Shared with the return service so corrections validate stored sales exactly
// as lookups do: ownership first (missing and foreign stay indistinguishable),
// then the strict recomputed projection.
export { ownBranch as isOwnBranchSale, storedSale as validateStoredSale };
