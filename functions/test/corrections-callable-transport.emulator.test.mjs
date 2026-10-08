// CORR-06B: live HTTP transport acceptance for sale corrections. Offline tests never
// initialize an SDK or use HTTP; the live root is skipped unless explicitly approved.
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { EventEmitter } from 'node:events';
import { lstatSync, realpathSync } from 'node:fs';
import test from 'node:test';
import { approvedRequire, SDK_ROOT, canonical } from './sales-emulator-support.mjs';
import {
  createOwnedAuthManifest, registerPlannedIdentities,
  provisionOwnedIdentities, cleanupOwnedIdentities,
} from './owned-auth-manifest.mjs';
// Offline rehearsal only: the real services run against an in-memory store, so the
// independent projections below are checked against the implementation before any live run.
import { calculateSale, createSaleService, SaleError } from '../src/sales.js';
import { calculateReturnRefund } from '../src/corrections-calculation.js';
import { createSaleLookupService } from '../src/sale-lookup.js';
import { createSaleReturnService } from '../src/sale-returns.js';
import { createSaleReplacementService } from '../src/sale-replacements.js';
import { createSaleExchangeService } from '../src/sale-exchanges.js';

const NODE = '/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node';
const RUN = '12345678-1234-4234-8234-123456789abc';
const FOREIGN_RUN = '87654321-4321-4321-8321-cba987654321';
const PROJECT = 'demo-lda-inventory';
const PINNED = {
  GCLOUD_PROJECT: PROJECT, FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080', FUNCTIONS_EMULATOR: 'true',
};
const LIVE = {
  LDA_CORRECTIONS_HTTP_ACCEPTANCE: '1',
  LDA_SALES_FIXTURE_BASELINE_APPROVAL: 'demo-seed-eight-documents-two-identities',
  LDA_SALES_RUNTIME_REVALIDATED: 'explicit-local-source-project-routes-reviewed',
};
const SERVICE_ENVIRONMENT = Object.freeze({
  GCLOUD_PROJECT: PROJECT, FUNCTIONS_EMULATOR: 'true', FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
});
const copy = (value) => structuredClone(value);
const UNCERTAIN = /acceptance\/operation-uncertain/;
const ORDER = /acceptance\/operation-order/;
const RETAINED = /acceptance\/firestore-retained-or-delete-unknown/;
const TIMESTAMP = /acceptance\/timestamp-type/;
const OBSERVATION = /acceptance\/observation-uncertain/;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FUNCTIONS = ['submitSale', 'findCorrectableSale', 'listRecentCorrectableSales', 'submitSaleReturn',
  'submitSaleReplacement', 'submitSaleExchange'];
const CALLABLE = { sale: 'submitSale', return: 'submitSaleReturn', replacement: 'submitSaleReplacement',
  exchange: 'submitSaleExchange' };
const BASE = `http://127.0.0.1:5001/${PROJECT}/us-south1`;
const REST = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const LOGIN = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only';
const same = (a, b) => canonical(a) === canonical(b);
const requireSame = (a, b) => { if (!same(a, b)) throw new Error('acceptance/content-mismatch'); };
const POLICY = { version: 1, rounding: 'half-up', roundingScope: 'per-line',
  additionalIvaBase: 'rounded-line-base', includedIvaExtraction: 'not-calculated' };
const half = (numerator, denominator) => (2n * numerator + denominator) / (2n * denominator);

// Server messages that identify which rule produced a denial.
const DENIAL = {
  unauthenticated: 'authentication is required',
  seller: 'an assigned seller is required',
  notFound: 'sale was not found in this branch',
  overReturn: 'return exceeds the remaining sold quantity',
  stock: 'insufficient stock',
  payment: 'difference payment must equal the amount the customer owes',
  sameProduct: 'exchange new items must differ from the returned products',
};

// The ten correction collections, including the return ledger: deny-all to every client.
const CORRECTION_COLLECTIONS = ['saleExchangeAudits', 'saleExchangeSubmissionReceipts', 'saleExchanges',
  'saleReplacementAudits', 'saleReplacementSubmissionReceipts', 'saleReplacements', 'saleReturnAudits',
  'saleReturnLedgers', 'saleReturnSubmissionReceipts', 'saleReturns'];

// Movement types and their sellable-stock effect (decision 4: defects never restock).
const STOCK_EFFECT = { sale: true, 'sale-return': true, 'sale-return-defect': false, 'replacement-defect-in': false,
  'replacement-out': true, 'exchange-return': true, 'exchange-return-defect': false, 'exchange-out': true };

function decimal(value, precision) {
  const [whole, fraction = ''] = value.split('.');
  if (fraction.length > precision) throw new Error('acceptance/decimal');
  return Number(BigInt(whole) * 10n ** BigInt(precision) + BigInt(fraction.padEnd(precision, '0')));
}

function formatScaled(scaled, precision) {
  if (precision === 0) return String(scaled);
  const text = String(scaled).padStart(precision + 1, '0');
  return `${text.slice(0, -precision)}.${text.slice(-precision)}`;
}

// Independent mirror of the published v1 sale calculation (half-up per line, IVA on invoice).
function saleCalculation(invoiceRequested, lines) {
  const projected = lines.map(({ quantity, spec, pricing }) => {
    const scaled = decimal(quantity, spec.precision);
    const base = half(BigInt(scaled) * BigInt(pricing.listedPriceCentavos), 10n ** BigInt(spec.precision));
    const iva = invoiceRequested && pricing.priceMode === 'iva-additional-on-invoice' && pricing.ivaTreatment === 'taxable'
      ? half(base * BigInt(pricing.ivaRateBasisPoints), 10000n) : 0n;
    return { quantity: { version: 1, spec: copy(spec), scaled, decimal: quantity }, pricing: { version: 1, ...copy(pricing) },
      baseCentavos: Number(base), additionalIvaCentavos: Number(iva), includedIvaCentavos: null,
      totalCentavos: Number(base + iva) };
  });
  const sum = (field) => projected.reduce((total, line) => total + line[field], 0);
  return { version: 1, currency: 'MXN', invoiceRequested, calculationPolicy: POLICY, lines: projected,
    baseCentavos: sum('baseCentavos'), additionalIvaCentavos: sum('additionalIvaCentavos'), totalCentavos: sum('totalCentavos') };
}

// Independent cumulative refund at the frozen snapshot: each component is the rounded
// cumulative share minus the rounded share already refunded.
function refundProjection(sale, returned, lines) {
  const projected = lines.map(({ lineIndex, quantity }) => {
    const sold = sale.calculation.lines[lineIndex];
    if (!sold) throw new Error('acceptance/return-line');
    const { scaled: soldScaled, spec } = sold.quantity;
    const scaled = decimal(quantity, spec.precision);
    const prior = returned[lineIndex] ?? 0;
    if (prior + scaled > soldScaled) throw new Error('acceptance/over-return');
    const share = (amount) => Number(half(BigInt(amount) * BigInt(prior + scaled), BigInt(soldScaled))
      - half(BigInt(amount) * BigInt(prior), BigInt(soldScaled)));
    const baseCentavos = share(sold.baseCentavos);
    const additionalIvaCentavos = share(sold.additionalIvaCentavos);
    return { lineIndex, productId: sale.productIds[lineIndex], quantity: formatScaled(scaled, spec.precision), scaled,
      baseCentavos, additionalIvaCentavos, totalCentavos: baseCentavos + additionalIvaCentavos };
  });
  const sum = (field) => projected.reduce((total, line) => total + line[field], 0);
  return { invoiced: sale.calculation.invoiceRequested, method: sale.payment.method, lines: projected,
    baseCentavos: sum('baseCentavos'), additionalIvaCentavos: sum('additionalIvaCentavos'), totalCentavos: sum('totalCentavos') };
}

function stockFromMovements(seed, movements, productId, branchId) {
  let quantity = seed;
  for (const movement of movements) {
    if (!Object.hasOwn(STOCK_EFFECT, movement?.type)) throw new Error('acceptance/movement-type');
    if (movement.productId !== productId || movement.branchId !== branchId || !STOCK_EFFECT[movement.type]) continue;
    quantity += movement.quantityScaled;
    if (quantity < 0) throw new Error('acceptance/stock-negative');
  }
  return quantity;
}

// The whole run is derived from the two validated run ids only: owned branches, products,
// stock, the exact requests, and every path any of them may create.
function fixture(runId, foreignRunId) {
  const branch = `branch-${runId}`;
  const foreign = `branch-${foreignRunId}`;
  const key = (label) => `corr-${runId}-${label}`;
  const productIds = Object.fromEntries(['A', 'B', 'C', 'D'].map((suffix) => [suffix, `CORR-${runId.toUpperCase()}-${suffix}`]));
  const { A, B, C, D } = productIds;
  const piece = { unit: 'piece', precision: 0 };
  const priced = (listedPriceCentavos) => ({ listedPriceCentavos, currency: 'MXN',
    priceMode: 'iva-additional-on-invoice', ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 });
  // A sells per piece at 10.00, B per kilogram at 20.00; C (15.00) and D (5.00) are exchange items.
  const products = {
    [A]: { spec: piece, pricing: priced(1000), stock: 10 },
    [B]: { spec: { unit: 'kg', precision: 2 }, pricing: priced(2000), stock: 150 },
    [C]: { spec: piece, pricing: priced(1500), stock: 5 },
    [D]: { spec: piece, pricing: priced(500), stock: 5 },
  };
  const saleU = key('sale-u');
  const saleI = key('sale-i');
  const good = (lineIndex, quantity) => ({ lineIndex, quantity, condition: 'good' });
  const operations = {
    // Uninvoiced cash sale: 3 A (30.00) and 1.50 kg B (30.00).
    'sale-u': { kind: 'sale', data: { idempotencyKey: saleU, invoiceRequested: false,
      lines: [{ productId: A, quantity: '3' }, { productId: B, quantity: '1.50' }],
      payment: { method: 'cash', amountCentavos: 6000 } } },
    // Invoiced card sale: 2 A, 20.00 plus 3.20 additional IVA.
    'sale-i': { kind: 'sale', data: { idempotencyKey: saleI, invoiceRequested: true,
      lines: [{ productId: A, quantity: '2' }], payment: { method: 'card', amountCentavos: 2320 } } },
    'return-good': { kind: 'return', sale: 'sale-u', data: { idempotencyKey: key('return-good'), saleId: saleU,
      reason: 'change-of-mind', note: 'Customer changed their mind',
      lines: [good(0, '1'), { lineIndex: 1, quantity: '0.50', condition: 'factory-defect' }] } },
    'return-invoiced': { kind: 'return', sale: 'sale-i', data: { idempotencyKey: key('return-invoiced'), saleId: saleI,
      reason: 'other', lines: [good(0, '1')] } },
    'replace-ok': { kind: 'replacement', sale: 'sale-u', data: { idempotencyKey: key('replace-ok'), saleId: saleU,
      lines: [{ lineIndex: 0, quantity: '1' }] } },
    'exchange-pay': { kind: 'exchange', sale: 'sale-u', data: { idempotencyKey: key('exchange-pay'), saleId: saleU,
      reason: 'wrong-product', returnLines: [good(0, '1')], newLines: [{ productId: C, quantity: '1' }],
      differencePayment: { method: 'transfer', amountCentavos: 500 } } },
    'exchange-refund': { kind: 'exchange', sale: 'sale-i', data: { idempotencyKey: key('exchange-refund'), saleId: saleI,
      reason: 'change-of-mind', returnLines: [good(0, '1')], newLines: [{ productId: D, quantity: '1' }] } },
    // Denials: each has its own key and planned slots, so any late write is caught.
    'return-over': { kind: 'return', denial: true, data: { idempotencyKey: key('return-over'), saleId: saleU,
      reason: 'change-of-mind', lines: [good(0, '3')] } },
    'return-foreign': { kind: 'return', denial: true, data: { idempotencyKey: key('return-foreign'), saleId: saleU,
      reason: 'change-of-mind', lines: [good(0, '1')] } },
    'replace-stock': { kind: 'replacement', denial: true, data: { idempotencyKey: key('replace-stock'), saleId: saleU,
      lines: [{ lineIndex: 1, quantity: '0.50' }] } },
    'exchange-wrong-pay': { kind: 'exchange', denial: true, data: { idempotencyKey: key('exchange-wrong-pay'), saleId: saleU,
      reason: 'wrong-product', returnLines: [good(0, '1')], newLines: [{ productId: C, quantity: '1' }],
      differencePayment: { method: 'transfer', amountCentavos: 499 } } },
    'exchange-same': { kind: 'exchange', denial: true, data: { idempotencyKey: key('exchange-same'), saleId: saleU,
      reason: 'wrong-product', returnLines: [good(0, '1')], newLines: [{ productId: A, quantity: '1' }] } },
  };
  const slots = {
    sale: (k) => [`sales/${k}`, `saleAudits/${k}`, `saleSubmissionReceipts/${k}`,
      ...[0, 1, 2].map((index) => `inventoryMovements/sale-${k}-${index}`)],
    return: (k) => [`saleReturns/${k}`, `saleReturnAudits/${k}`, `saleReturnSubmissionReceipts/${k}`,
      ...[0, 1, 2].map((index) => `inventoryMovements/return-${k}-${index}`)],
    replacement: (k) => [`saleReplacements/${k}`, `saleReplacementAudits/${k}`, `saleReplacementSubmissionReceipts/${k}`,
      ...[0, 1].flatMap((index) => ['in', 'out'].map((direction) => `inventoryMovements/replacement-${k}-${index}-${direction}`))],
    exchange: (k) => [`saleExchanges/${k}`, `saleExchangeAudits/${k}`, `saleExchangeSubmissionReceipts/${k}`,
      ...['in', 'out'].flatMap((direction) => [0, 1].map((index) => `inventoryMovements/exchange-${k}-${direction}-${index}`))],
  };
  const stock = (branchId, productId) => `branches/${branchId}/stock/${productId}`;
  const seeds = new Map([
    // Owned acceptance codes never reuse the demo NTE/SUR codes.
    [`branches/${branch}`, { name: `Corrections ${runId}`, code: 'CRA', acceptanceRunId: runId }],
    [`branches/${foreign}`, { name: `Corrections foreign ${foreignRunId}`, code: 'CRF', acceptanceRunId: foreignRunId }],
    ...Object.entries(products).map(([id, product]) => [`products/${id}`, { internalCode: id, name: `Acceptance ${id}`,
      quantitySpec: copy(product.spec), pricing: copy(product.pricing) }]),
    ...Object.entries(products).map(([id, product]) => [stock(branch, id), { quantityScaled: product.stock, ...product.spec }]),
  ]);
  const paths = [
    ...seeds.keys(),
    ...Object.keys(products).map((id) => stock(foreign, id)),
    `sales/${key('missing')}`, ...[saleU, saleI, key('missing')].map((id) => `saleReturnLedgers/${id}`),
    ...Object.values(operations).flatMap((operation) => slots[operation.kind](operation.data.idempotencyKey)),
  ];
  return { branch, foreign, key, productIds, products, operations, seeds, paths, stock, missing: key('missing') };
}

// Seed plus every stock-moving movement of the scenario: A 10-3-2+1+1-1+1+1, B 150-150
// (the returned kilograms were defective), C 5-1, D 5-1.
const FINAL_STOCK = Object.freeze({ A: 8, B: 0, C: 4, D: 4 });
const SUCCESS_ORDER = ['sale-u', 'sale-i', 'return-good', 'return-invoiced', 'replace-ok', 'exchange-pay', 'exchange-refund'];
const RECEIPT_COLLECTION = { sale: 'saleSubmissionReceipts', return: 'saleReturnSubmissionReceipts',
  replacement: 'saleReplacementSubmissionReceipts', exchange: 'saleExchangeSubmissionReceipts' };

// Pure projection of one confirmed success: the exact response and every document it
// writes, from the request, the private confirmed state and the server timestamp only.
function project(operation, context, timestamp) {
  const { fx, actorId } = context;
  const branchId = fx.branch;
  const { data } = operation;
  const key = data.idempotencyKey;
  const documents = new Map();
  const shift = (productId, delta, lastMovementId) => {
    const path = fx.stock(branchId, productId);
    const previous = documents.get(path) ?? context.stock(path);
    const { unit, precision } = fx.products[productId].spec;
    const quantityScaled = (previous?.quantityScaled ?? 0) + delta;
    if (quantityScaled < 0) throw new Error('acceptance/stock-negative');
    documents.set(path, { quantityScaled, unit, precision, updatedAt: timestamp, lastMovementId });
  };
  const replay = (input, result) => documents.set(`${RECEIPT_COLLECTION[operation.kind]}/${key}`, {
    actorId, branchId, fingerprint: JSON.stringify({ actorId, branchId, ...input }), result, completedAt: timestamp });
  const note = Object.hasOwn(data, 'note') ? data.note : null;
  if (operation.kind === 'sale') {
    const calculation = saleCalculation(data.invoiceRequested, data.lines.map(({ productId, quantity }) => ({
      quantity, spec: fx.products[productId].spec, pricing: fx.products[productId].pricing })));
    const payment = { method: data.payment.method, amountCentavos: data.payment.amountCentavos };
    if (payment.amountCentavos !== calculation.totalCentavos) throw new Error('acceptance/projection-payment');
    // Folio: the seeded branch code and the first eight alphanumerics of the key.
    const branchCode = fx.seeds.get(`branches/${branchId}`).code;
    const head = key.replace(/[^a-zA-Z0-9]/g, '').slice(0, 8).toUpperCase();
    const receipt = { version: 2, saleId: key, branchId, branchCode, folio: `${branchCode}-${head.slice(0, 4)}-${head.slice(4)}`,
      productIds: data.lines.map((line) => line.productId), calculation, payment };
    documents.set(`sales/${key}`, { receipt, createdAt: timestamp });
    documents.set(`saleAudits/${key}`, { saleId: key, branchId, actorId, createdAt: timestamp });
    data.lines.forEach(({ productId }, index) => {
      const { scaled, spec } = calculation.lines[index].quantity;
      documents.set(`inventoryMovements/sale-${key}-${index}`, { type: 'sale', saleId: key, branchId, productId,
        quantityScaled: -scaled, ...spec, actorId, occurredAt: timestamp });
      shift(productId, -scaled, `sale-${key}-${index}`);
    });
    replay({ idempotencyKey: key, invoiceRequested: data.invoiceRequested,
      lines: data.lines.map(({ productId, quantity }) => ({ productId, quantity })), payment }, receipt);
    return { response: { receipt, replayed: false }, documents, sale: { receipt, createdAt: timestamp } };
  }
  const sale = context.sale(operation.sale);
  const returned = context.ledger(data.saleId);
  const specOf = (lineIndex) => sale.calculation.lines[lineIndex].quantity.spec;
  const ledgerAfter = (refund) => {
    const next = { ...returned };
    for (const line of refund.lines) next[line.lineIndex] = (next[line.lineIndex] ?? 0) + line.scaled;
    documents.set(`saleReturnLedgers/${data.saleId}`, { returned: next, lastReturnId: key, updatedAt: timestamp });
  };
  const amounts = ({ baseCentavos, additionalIvaCentavos, totalCentavos }) => ({ baseCentavos, additionalIvaCentavos, totalCentavos });
  const receiptLines = (refund, conditions) => refund.lines.map((line, index) => ({ lineIndex: line.lineIndex,
    productId: line.productId, quantity: line.quantity, condition: conditions[index].condition, ...amounts(line) }));
  if (operation.kind === 'return') {
    const refund = refundProjection(sale, returned, data.lines);
    const receipt = { version: 1, returnId: key, saleId: data.saleId, branchId, reason: data.reason,
      lines: receiptLines(refund, data.lines), refund: { method: refund.method, ...amounts(refund) }, invoiced: refund.invoiced };
    documents.set(`saleReturns/${key}`, { receipt, createdAt: timestamp });
    documents.set(`saleReturnAudits/${key}`, { returnId: key, saleId: data.saleId, branchId, actorId, reason: data.reason,
      note, createdAt: timestamp });
    refund.lines.forEach((line, index) => {
      const { condition } = data.lines[index];
      documents.set(`inventoryMovements/return-${key}-${index}`, { type: condition === 'good' ? 'sale-return' : 'sale-return-defect',
        returnId: key, saleId: data.saleId, lineIndex: line.lineIndex, branchId, productId: line.productId,
        quantityScaled: line.scaled, ...specOf(line.lineIndex), actorId, occurredAt: timestamp });
      if (condition === 'good') shift(line.productId, line.scaled, `return-${key}-${index}`);
    });
    ledgerAfter(refund);
    replay({ idempotencyKey: key, saleId: data.saleId, reason: data.reason, note,
      lines: data.lines.map(({ lineIndex, quantity, condition }) => ({ lineIndex, quantity, condition })) }, receipt);
    return { response: { receipt, replayed: false }, documents };
  }
  if (operation.kind === 'replacement') {
    // Decision 11: capped at the remaining quantity, which it never consumes.
    const lines = data.lines.map(({ lineIndex, quantity }) => {
      const { scaled: sold, spec } = sale.calculation.lines[lineIndex].quantity;
      const scaled = decimal(quantity, spec.precision);
      if (scaled > sold - (returned[lineIndex] ?? 0)) throw new Error('acceptance/over-return');
      return { lineIndex, productId: sale.productIds[lineIndex], scaled, quantity: formatScaled(scaled, spec.precision), spec };
    });
    const receipt = { version: 1, replacementId: key, saleId: data.saleId, branchId, reason: 'factory-defect',
      lines: lines.map(({ lineIndex, productId, quantity }) => ({ lineIndex, productId, quantity })), chargeCentavos: 0 };
    documents.set(`saleReplacements/${key}`, { receipt, createdAt: timestamp });
    documents.set(`saleReplacementAudits/${key}`, { replacementId: key, saleId: data.saleId, branchId, actorId,
      reason: 'factory-defect', note, createdAt: timestamp });
    lines.forEach((line, index) => {
      const movement = { replacementId: key, saleId: data.saleId, lineIndex: line.lineIndex, branchId,
        productId: line.productId, ...line.spec, actorId, occurredAt: timestamp };
      documents.set(`inventoryMovements/replacement-${key}-${index}-in`, { type: 'replacement-defect-in',
        quantityScaled: line.scaled, ...movement });
      documents.set(`inventoryMovements/replacement-${key}-${index}-out`, { type: 'replacement-out',
        quantityScaled: -line.scaled, ...movement });
      shift(line.productId, -line.scaled, `replacement-${key}-${index}-out`);
    });
    replay({ idempotencyKey: key, saleId: data.saleId, note,
      lines: data.lines.map(({ lineIndex, quantity }) => ({ lineIndex, quantity })) }, receipt);
    return { response: { receipt, replayed: false }, documents };
  }
  // Exchange: the returned part is a return at the snapshot; new items use current pricing.
  const refund = refundProjection(sale, returned, data.returnLines);
  const calculation = saleCalculation(sale.calculation.invoiceRequested, data.newLines.map(({ productId, quantity }) => ({
    quantity, spec: fx.products[productId].spec, pricing: fx.products[productId].pricing })));
  const difference = calculation.totalCentavos - refund.totalCentavos;
  const differencePayment = Object.hasOwn(data, 'differencePayment') ? copy(data.differencePayment) : null;
  if ((difference > 0) !== (differencePayment !== null)
    || (differencePayment && differencePayment.amountCentavos !== difference)) throw new Error('acceptance/projection-payment');
  const receipt = { version: 1, exchangeId: key, saleId: data.saleId, branchId, reason: data.reason,
    returned: { lines: receiptLines(refund, data.returnLines), ...amounts(refund) },
    newItems: { productIds: data.newLines.map((line) => line.productId), calculation },
    settlement: { returnedCentavos: refund.totalCentavos, newItemCentavos: calculation.totalCentavos,
      customerPaysCentavos: Math.max(difference, 0), refundCentavos: Math.max(-difference, 0),
      refundMethod: refund.method, differencePayment },
    invoiced: refund.invoiced };
  documents.set(`saleExchanges/${key}`, { receipt, createdAt: timestamp });
  documents.set(`saleExchangeAudits/${key}`, { exchangeId: key, saleId: data.saleId, branchId, actorId,
    reason: data.reason, note, createdAt: timestamp });
  const movement = { exchangeId: key, saleId: data.saleId, branchId, actorId, occurredAt: timestamp };
  refund.lines.forEach((line, index) => {
    const { condition } = data.returnLines[index];
    documents.set(`inventoryMovements/exchange-${key}-in-${index}`, { type: condition === 'good' ? 'exchange-return'
      : 'exchange-return-defect', ...movement, lineIndex: line.lineIndex, productId: line.productId,
    quantityScaled: line.scaled, ...specOf(line.lineIndex) });
    if (condition === 'good') shift(line.productId, line.scaled, `exchange-${key}-in-${index}`);
  });
  data.newLines.forEach(({ productId }, index) => {
    const { scaled, spec } = calculation.lines[index].quantity;
    documents.set(`inventoryMovements/exchange-${key}-out-${index}`, { type: 'exchange-out', ...movement,
      newLineIndex: index, productId, quantityScaled: -scaled, ...spec });
    shift(productId, -scaled, `exchange-${key}-out-${index}`);
  });
  ledgerAfter(refund);
  replay({ idempotencyKey: key, saleId: data.saleId, reason: data.reason, note,
    returnLines: data.returnLines.map(({ lineIndex, quantity, condition }) => ({ lineIndex, quantity, condition })),
    newLines: data.newLines.map(({ productId, quantity }) => ({ productId, quantity })), differencePayment }, receipt);
  return { response: { receipt, replayed: false }, documents };
}

function gate(environment, runtime = { executable: process.execPath, version: process.version }) {
  if (runtime.executable !== NODE || runtime.version !== 'v24.21.0') throw new Error('acceptance/node-pin');
  for (const [key, value] of Object.entries(PINNED)) {
    if (environment[key] !== value) throw new Error('acceptance/target-pin');
  }
  for (const key of Object.keys(environment)) {
    if (Object.hasOwn(PINNED, key)) continue;
    if (/^(GOOGLE_|GCLOUD_|GCP_|FIREBASE_|FIRESTORE_|FUNCTIONS_|CLOUDSDK_|GRPC_|grpc_|NODE_OPTIONS$|NODE_PATH$|NODE_EXTRA_CA_CERTS$|NODE_TLS_REJECT_UNAUTHORIZED$)/.test(key)
      || /proxy/i.test(key)) throw new Error('acceptance/ambient-override');
  }
}

// The root runs only when every approval is present; liveApproval then re-checks the pins.
function liveRequested(environment) {
  return Object.entries(LIVE).every(([key, value]) => environment[key] === value);
}

function liveApproval(environment, runtime) {
  gate(environment, runtime); // undefined keeps the actual process runtime.
  if (!liveRequested(environment)) throw new Error('acceptance/live-approval-required');
}

async function deadline(work, milliseconds = 10000) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(work),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('acceptance/deadline-unknown')), milliseconds);
      }),
    ]);
  } finally { clearTimeout(timer); }
}

async function teardown(stages) {
  let failed = false;
  for (const stage of stages) {
    try { await deadline(stage); } catch { failed = true; }
  }
  if (failed) throw new Error('acceptance/teardown-incomplete');
}

// Private closure authority: requests, plan and expectations live only here. Context,
// public views, responses and server records are never adopted; only a success whose
// every planned document matches the independent projection advances the state.
function createManifest(context, adapter) {
  const { runId, foreignRunId, clock = Date.now } = context ?? {};
  if (!UUID.test(runId ?? '') || !UUID.test(foreignRunId ?? '') || runId === foreignRunId
    || typeof clock !== 'function') throw new Error('acceptance/context');
  const store = Object.fromEntries(['read', 'create', 'transaction'].map((name) => [name, adapter[name].bind(adapter)]));
  const fx = fixture(runId, foreignRunId);
  const actorId = `acceptance-${runId}-seller`;
  const entries = new Map();
  for (const path of fx.paths) {
    if (entries.has(path)) throw new Error('acceptance/duplicate-plan');
    entries.set(path, { expected: null, state: 'planned' });
  }
  const sales = new Map();
  const ledgers = new Map();
  const completed = [];
  let seeded = false;
  let uncertain = false;
  let active = false;
  let cleanupStarted = false;
  const read = async () => {
    const names = [...entries.keys()];
    const values = await deadline(() => store.read(names));
    if (!Array.isArray(values) || values.length !== names.length) throw new Error('acceptance/read-shape');
    return new Map(names.map((path, index) => [path, copy(values[index])]));
  };
  const validate = (records) => {
    for (const [path, entry] of entries) requireSame(records.get(path), entry.expected);
  };
  const stamp = (value, before, after) => {
    if (after < before || !Number.isSafeInteger(value) || value < before - 5000 || value > after + 5000) {
      throw new Error('acceptance/timestamp-window');
    }
    return value;
  };
  const request = (label) => {
    if (!Object.hasOwn(fx.operations, label)) throw new Error('acceptance/unknown-operation');
    return copy(fx.operations[label].data);
  };
  const projectionContext = {
    fx, actorId,
    stock: (path) => entries.get(path).expected,
    sale: (label) => sales.get(label).receipt,
    ledger: (saleId) => ({ ...(ledgers.get(saleId) ?? {}) }),
  };
  const confirm = async (label, result, before, after) => {
    const operation = fx.operations[label];
    const records = await read();
    const key = operation.data.idempotencyKey;
    const timestamp = stamp(records.get(`${RECEIPT_COLLECTION[operation.kind]}/${key}`)?.completedAt, before, after);
    const projection = project(operation, projectionContext, timestamp);
    requireSame(result, projection.response);
    for (const [path, entry] of entries) {
      requireSame(records.get(path), projection.documents.has(path) ? projection.documents.get(path) : entry.expected);
    }
    for (const path of projection.documents.keys()) if (!entries.has(path)) throw new Error('acceptance/unplanned');
    for (const [path, value] of projection.documents) entries.set(path, { expected: copy(value), state: 'confirmed' });
    if (projection.sale) sales.set(label, copy(projection.sale));
    const ledger = projection.documents.get(`saleReturnLedgers/${operation.data.saleId}`);
    if (ledger) ledgers.set(operation.data.saleId, copy(ledger.returned));
    completed.push(label);
  };
  const lookup = (label) => {
    const { receipt, createdAt } = sales.get(label);
    const returned = ledgers.get(receipt.saleId) ?? {};
    return { saleId: receipt.saleId, folio: receipt.folio ?? null, createdAt,
      receipt: { calculation: receipt.calculation, payment: receipt.payment, productIds: receipt.productIds,
        invoiceRequested: receipt.calculation.invoiceRequested },
      lines: receipt.calculation.lines.map((line, lineIndex) => ({ lineIndex, soldScaled: line.quantity.scaled,
        returnedScaled: returned[lineIndex] ?? 0, remainingScaled: line.quantity.scaled - (returned[lineIndex] ?? 0) })) };
  };
  const ready = (label) => {
    if (!sales.has(label)) throw new Error('acceptance/operation-order');
    return label;
  };
  return Object.freeze({
    request,
    key: (label) => fx.key(label),
    ids: () => ({ branch: fx.branch, foreign: fx.foreign, missing: fx.missing, products: copy(fx.productIds) }),
    paths: () => [...entries.keys()],
    view: () => ({ runId, foreignRunId, uncertain, completed: [...completed],
      entries: [...entries].map(([path, entry]) => ({ path, ...copy(entry) })) }),
    receipt(label) { // Copy of a confirmed private receipt, for replay comparison only.
      if (!completed.includes(label) || fx.operations[label].kind === 'sale') throw new Error('acceptance/operation-order');
      const kind = fx.operations[label].kind;
      const collection = { return: 'saleReturns', replacement: 'saleReplacements', exchange: 'saleExchanges' }[kind];
      return copy(entries.get(`${collection}/${fx.operations[label].data.idempotencyKey}`).expected.receipt);
    },
    lookup: (label) => copy({ sale: lookup(ready(label)) }),
    recent: () => copy({ sales: [...sales.keys()].map(lookup).sort((a, b) => b.createdAt - a.createdAt) }),
    // Every created correction record and ledger: all must stay private to sellers.
    privateDocuments: () => [...entries].filter(([path, entry]) => entry.expected !== null
      && /^(saleReturn|saleReplacement|saleExchange)/.test(path)).map(([path]) => path),
    correctionMovements: () => [...entries].filter(([path, entry]) => entry.expected !== null
      && /^inventoryMovements\/(return|replacement|exchange)-/.test(path)).map(([path, entry]) => ({ path, expected: copy(entry.expected) })),
    async seed() {
      if (seeded || cleanupStarted) throw new Error('acceptance/seed-once');
      seeded = true;
      try {
        validate(await read());
        uncertain = true;
        for (const [path, value] of fx.seeds) {
          await deadline(() => store.create(path, copy(value)));
          requireSame((await read()).get(path), value);
          entries.set(path, { expected: copy(value), state: 'confirmed' });
        }
        uncertain = false;
      } catch { uncertain = true; throw new Error('acceptance/seed-uncertain'); }
    },
    async execute(label, transport, timeoutMs = 10000) {
      const index = SUCCESS_ORDER.indexOf(label);
      if (!seeded || uncertain || active || cleanupStarted || index < 0 || completed.length !== index) {
        throw new Error('acceptance/operation-order');
      }
      const input = request(label);
      active = true;
      try { validate(await read()); }
      catch { active = false; uncertain = true; throw new Error('acceptance/preflight-mismatch'); }
      uncertain = true; // BEFORE issuing any request; a timeout never cancels its side effects.
      const before = clock();
      try {
        const result = await deadline(() => transport(copy(input)), timeoutMs);
        const after = clock();
        await confirm(label, copy(result), before, after);
        uncertain = false;
        return copy(result);
      } catch { throw new Error('acceptance/operation-uncertain'); }
      finally { active = false; }
    },
    async unchanged(transport) {
      if (!seeded || uncertain || active || cleanupStarted) throw new Error('acceptance/unsafe-observation');
      active = true;
      let before;
      try { before = await read(); validate(before); }
      catch { active = false; uncertain = true; throw new Error('acceptance/preflight-mismatch'); }
      uncertain = true;
      try {
        const result = await deadline(transport);
        const after = await read();
        requireSame([...after], [...before]);
        validate(after);
        uncertain = false;
        return result;
      } catch { throw new Error('acceptance/observation-uncertain'); }
      finally { active = false; }
    },
    // Final stock equals the seed plus every stock-moving movement; sales stay as created.
    async consistency(finals) {
      if (completed.length !== SUCCESS_ORDER.length) throw new Error('acceptance/operation-order');
      await this.unchanged(async () => {
        const records = await read();
        const movements = [...records].filter(([path, value]) => path.startsWith('inventoryMovements/') && value !== null)
          .map(([, value]) => value);
        for (const [suffix, productId] of Object.entries(fx.productIds)) {
          const actual = records.get(fx.stock(fx.branch, productId))?.quantityScaled;
          if (actual !== stockFromMovements(fx.products[productId].stock, movements, productId, fx.branch)
            || actual !== finals[suffix] || records.get(fx.stock(fx.foreign, productId)) !== null) {
            throw new Error('acceptance/stock-inconsistent');
          }
        }
        for (const [label, sale] of sales) {
          requireSame(records.get(`sales/${fx.operations[label].data.idempotencyKey}`), sale);
        }
      });
    },
    async cleanup() {
      if (cleanupStarted) throw new Error('acceptance/cleanup-not-retryable');
      cleanupStarted = true;
      let residual = [];
      try {
        await deadline(() => store.transaction(async (transaction) => {
          const records = new Map();
          for (const path of entries.keys()) records.set(path, await transaction.get(path));
          residual = [...records].filter(([, value]) => value !== null).map(([path]) => path).sort();
          if (uncertain || active) throw new Error('acceptance/uncertain-run');
          validate(records);
          const rank = (path) => (path.startsWith('products/') ? 2 : /^branches\/[^/]+$/.test(path) ? 3 : 1);
          for (const path of [...entries.keys()].sort((a, b) => rank(a) - rank(b))) {
            if (records.get(path) !== null) transaction.delete(path);
          }
        }));
      } catch {
        uncertain = true;
        // Reported for a separately authorized exact-path cleanup; never retried here.
        throw new Error(`acceptance/firestore-retained-or-delete-unknown ${JSON.stringify(residual)}`);
      }
    },
  });
}

// Sellers may read their own branch's correction movements by published rule. The view
// must be exactly the planned document: no cost or price field, the seller's own branch and uid.
function sellerMovementView(outcome, path, expected, { branchId, actorId }) {
  const fields = outcome?.body?.fields;
  const fail = () => { throw new Error('acceptance/seller-movement-view'); };
  if (outcome?.status !== 200 || typeof outcome.body?.name !== 'string' || !outcome.body.name.endsWith(`/documents/${path}`)
    || !fields || !same(Object.keys(fields).sort(), Object.keys(expected).sort())
    || Object.keys(expected).some((key) => /cost|price/i.test(key))
    || expected.branchId !== branchId || expected.actorId !== actorId) fail();
  for (const [key, value] of Object.entries(expected)) {
    const field = fields[key];
    const matches = key === 'occurredAt' ? typeof field?.timestampValue === 'string'
      : typeof value === 'number' ? field?.integerValue === String(value) : field?.stringValue === value;
    if (!matches || Object.keys(field).length !== 1) fail();
  }
}

// URL authority is local and exact; no external host, redirects or caller options.
function makeHttp(environment, documentPaths, transport = httpRequest, approve = liveApproval) {
  const allowed = new Set([LOGIN, ...FUNCTIONS.map((name) => `${BASE}/${name}`)]);
  for (const path of documentPaths) allowed.add(`${REST}/${path.split('/').map(encodeURIComponent).join('/')}`);
  return async (url, method = 'GET', body, token) => {
    approve(environment);
    approve(process.env);
    if (!allowed.has(url) || !['GET', 'POST'].includes(method)) throw new Error('acceptance/url-refused');
    const payload = body === undefined ? undefined : JSON.stringify(body);
    if (payload && Buffer.byteLength(payload) > 16384) throw new Error('acceptance/request-size');
    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = () => {
        if (!settled) { settled = true; clearTimeout(timer); reject(new Error('acceptance/http-unknown')); }
        request.destroy();
      };
      const request = transport(url, { method, agent: false, headers: {
        'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}),
      } }, (response) => {
        const chunks = [];
        let bytes = 0;
        if (response.statusCode >= 300 && response.statusCode < 400) return fail();
        response.on('data', (chunk) => {
          bytes += chunk.length;
          if (bytes > 262144) fail(); else chunks.push(chunk);
        });
        response.on('error', fail);
        response.on('end', () => {
          if (settled) return;
          try {
            const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            settled = true;
            clearTimeout(timer);
            resolve({ status: response.statusCode, body: parsed });
          } catch { fail(); }
        });
      });
      const timer = setTimeout(fail, 10000);
      request.on('error', fail);
      request.end(payload);
    });
  };
}

function normalizeRecord(value) {
  if (value && typeof value.toMillis === 'function') {
    // Emulator Timestamps may carry sub-millisecond nanoseconds; require a coherent
    // seconds/nanoseconds pair and compare at Timestamp.toMillis (floor) precision.
    const { seconds, nanoseconds } = value;
    const milliseconds = value.toMillis();
    if (!Number.isSafeInteger(seconds) || !Number.isInteger(nanoseconds) || nanoseconds < 0 || nanoseconds > 999999999
      || !Number.isSafeInteger(milliseconds) || milliseconds !== seconds * 1000 + Math.floor(nanoseconds / 1e6)) {
      throw new Error('acceptance/timestamp-type');
    }
    return milliseconds;
  }
  if (Array.isArray(value)) return value.map(normalizeRecord);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, field]) => {
      if (['createdAt', 'completedAt', 'occurredAt', 'updatedAt'].includes(key)
        && typeof field?.toMillis !== 'function') throw new Error('acceptance/timestamp-type');
      return [key, normalizeRecord(field)];
    }));
  return value;
}

// Admin Firestore requires a certificate credential even against the emulator; a fresh local
// RSA key satisfies it without ADC, discovery or token refresh (ssl=false uses insecure gRPC).
function ownedCredential(cert, keyPair = generateKeyPairSync) {
  const { privateKey } = keyPair('rsa', { modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } });
  return cert({ projectId: PROJECT, clientEmail: `acceptance-local@${PROJECT}.iam.gserviceaccount.com`, privateKey });
}

// Keeps only a well-formed error code (never the message) so failures stay diagnosable without leaking details.
function initializationError(error) {
  const source = typeof error?.code === 'string' ? error.code : error?.message;
  const code = typeof source === 'string' && /^[a-z][a-z0-9-]*\/[a-z0-9-]+$/.test(source) ? source : 'acceptance/unknown';
  return Object.assign(new Error('acceptance/runtime-initialization'), { code });
}

function callableSuccess(outcome) {
  if (outcome.status !== 200 || !same(Object.keys(outcome.body), ['result'])) throw new Error('acceptance/callable-result');
  return outcome.body.result;
}

function callableDenied(outcome, code, message) {
  if (outcome.status === 200 || !same(Object.keys(outcome.body), ['error']) || outcome.body.error?.status !== code
    || (message !== undefined && outcome.body.error.message !== message)) {
    throw new Error('acceptance/callable-denial');
  }
}

// The callable scenario shared by the offline rehearsal and the live root. `call(name,
// data, role)` returns an HTTP-shaped outcome; `step(name, work)` names each case.
async function runScenario({ manifest, call, step }) {
  const ids = manifest.ids();
  const succeed = (label, kind) => step(`${kind} success: ${label}`, () => manifest.execute(label,
    async (data) => callableSuccess(await call(CALLABLE[kind], data, 'seller'))));
  const deny = (name, fn, data, role, code, message) => step(`denial: ${name}`, () => manifest.unchanged(async () => {
    callableDenied(await call(fn, data, role), code, message);
  }));
  const observe = (name, fn, data, role, expected) => step(name, () => manifest.unchanged(async () => {
    requireSame(callableSuccess(await call(fn, data, role)), expected());
  }));
  const saleU = manifest.key('sale-u');
  const remaining = (expected) => step(`remaining quantities of sale-u are ${expected.join(', ')}`,
    () => manifest.unchanged(async () => {
      const { sale } = callableSuccess(await call('findCorrectableSale', { saleId: saleU }, 'seller'));
      requireSame(sale.lines.map((line) => line.remainingScaled), expected);
      requireSame({ sale }, manifest.lookup('sale-u'));
    }));

  await succeed('sale-u', 'sale');
  await succeed('sale-i', 'sale');
  // 1. findCorrectableSale: own branch only; missing and foreign share one answer.
  await observe('find: own-branch sale with full remaining quantities', 'findCorrectableSale', { saleId: saleU }, 'seller',
    () => manifest.lookup('sale-u'));
  await deny('find: foreign seller gets not-found', 'findCorrectableSale', { saleId: saleU }, 'foreign', 'NOT_FOUND', DENIAL.notFound);
  await deny('find: missing sale gets the same not-found', 'findCorrectableSale', { saleId: ids.missing }, 'seller',
    'NOT_FOUND', DENIAL.notFound);
  for (const role of ['client', 'unassigned', 'administrator']) {
    await deny(`find: ${role} is not a seller`, 'findCorrectableSale', { saleId: saleU }, role, 'PERMISSION_DENIED', DENIAL.seller);
  }
  await deny('find: anonymous', 'findCorrectableSale', { saleId: saleU }, 'anonymous', 'UNAUTHENTICATED', DENIAL.unauthenticated);
  // 2. listRecentCorrectableSales: newest first, branch-scoped.
  await observe('list: own branch newest first', 'listRecentCorrectableSales', {}, 'seller', () => manifest.recent());
  await step('list: the sale order is newest first', async () => {
    requireSame(manifest.recent().sales.map((sale) => sale.saleId), [manifest.key('sale-i'), saleU]);
  });
  await observe('list: the foreign seller sees none of them', 'listRecentCorrectableSales', {}, 'foreign', () => ({ sales: [] }));
  // 3. submitSaleReturn: partial good restock, defect recorded only, original method, replay, over-return.
  await succeed('return-good', 'return');
  await observe('return: exact replay', 'submitSaleReturn', manifest.request('return-good'), 'seller',
    () => ({ receipt: manifest.receipt('return-good'), replayed: true }));
  await deny('return: over-return', 'submitSaleReturn', manifest.request('return-over'), 'seller', 'OUT_OF_RANGE', DENIAL.overReturn);
  await deny('return: foreign seller', 'submitSaleReturn', manifest.request('return-foreign'), 'foreign', 'NOT_FOUND', DENIAL.notFound);
  await succeed('return-invoiced', 'return');
  await step('return: refunds use the original method and the IVA charged', async () => {
    requireSame(manifest.receipt('return-good').refund,
      { method: 'cash', baseCentavos: 2000, additionalIvaCentavos: 0, totalCentavos: 2000 });
    requireSame(manifest.receipt('return-invoiced').refund,
      { method: 'card', baseCentavos: 1000, additionalIvaCentavos: 160, totalCentavos: 1160 });
    if (manifest.receipt('return-invoiced').invoiced !== true) throw new Error('acceptance/invoiced-flag');
  });
  await remaining([2, 100]);
  await observe('find: the invoiced sale shows its ledger', 'findCorrectableSale', { saleId: manifest.key('sale-i') }, 'seller',
    () => manifest.lookup('sale-i'));
  // 4. submitSaleReplacement: stock out, remaining unchanged; insufficient stock denied.
  await succeed('replace-ok', 'replacement');
  await remaining([2, 100]);
  await deny('replacement: insufficient stock', 'submitSaleReplacement', manifest.request('replace-stock'), 'seller',
    'FAILED_PRECONDITION', DENIAL.stock);
  // 5. submitSaleExchange: exact difference paid, refund, same product refused.
  await deny('exchange: a wrong difference payment', 'submitSaleExchange', manifest.request('exchange-wrong-pay'), 'seller',
    'INVALID_ARGUMENT', DENIAL.payment);
  await succeed('exchange-pay', 'exchange');
  await deny('exchange: same product', 'submitSaleExchange', manifest.request('exchange-same'), 'seller',
    'INVALID_ARGUMENT', DENIAL.sameProduct);
  await succeed('exchange-refund', 'exchange');
  await step('exchange: settlements', async () => {
    const pay = manifest.receipt('exchange-pay').settlement;
    const back = manifest.receipt('exchange-refund').settlement;
    requireSame([pay.customerPaysCentavos, pay.refundCentavos, pay.differencePayment],
      [500, 0, { method: 'transfer', amountCentavos: 500 }]);
    requireSame([back.returnedCentavos, back.newItemCentavos, back.customerPaysCentavos, back.refundCentavos, back.refundMethod,
      back.differencePayment], [1160, 580, 0, 580, 'card', null]);
  });
  await remaining([1, 100]);
}

// Exact source-derived demo preservation proposal, NOT evidence of current contents.
const BASELINE_AUTH = ['demo-local-administrator', 'demo-local-seller-north'];
const BASELINE_DOCS = [
  'branches/branch-north', 'branches/branch-south', 'products/DEMO-COFFEE', 'products/DEMO-RIBBON',
  'branches/branch-north/stock/DEMO-COFFEE', 'branches/branch-north/stock/DEMO-RIBBON',
  'branches/branch-south/stock/DEMO-COFFEE', 'branches/branch-south/stock/DEMO-RIBBON',
];

// ---------------------------------------------------------------------------
// Offline tests. They use an in-memory store and the real (pure) services only.
// ---------------------------------------------------------------------------

const BASE_TIME = Date.parse('2026-10-08T12:00:00Z');

function fakeStore() {
  const documents = new Map();
  const events = [];
  const plainRecord = (value) => {
    if (value instanceof Date) return value.getTime();
    if (Array.isArray(value)) return value.map(plainRecord);
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([key, field]) => [key, plainRecord(field)]));
    }
    return value;
  };
  const query = (collection, filters = [], order = null, max = Infinity) => ({
    where: (field, op, value) => query(collection, [...filters, [field, op, value]], order, max),
    orderBy: (field, direction) => query(collection, filters, [field, direction], max),
    limit: (count) => query(collection, filters, order, count),
    run() {
      const scalar = (value) => (value instanceof Date ? value.getTime() : value);
      const field = (data, path) => scalar(path.split('.').reduce((value, key) => value?.[key], data));
      const compare = { '==': (a, b) => a === b, '>': (a, b) => a > b, '<=': (a, b) => a <= b };
      let rows = [...documents].filter(([path]) => path.split('/').length === 2 && path.startsWith(`${collection}/`))
        .filter(([, data]) => filters.every(([path, op, value]) => compare[op](field(data, path), scalar(value))));
      if (order) {
        rows = rows.sort(([, a], [, b]) => (field(a, order[0]) - field(b, order[0])) * (order[1] === 'desc' ? -1 : 1));
      }
      return rows.slice(0, max).map(([path, data]) => ({ id: path.split('/')[1], data: () => copy(data) }));
    },
  });
  return {
    documents, events,
    async read(paths) { return paths.map((path) => (documents.has(path) ? plainRecord(copy(documents.get(path))) : null)); },
    async create(path, data) {
      events.push(['create', path]);
      if (documents.has(path)) throw new Error('collision');
      documents.set(path, copy(data));
    },
    async transaction(callback) {
      const pending = [];
      let deleting = false;
      await callback({
        async get(path) {
          assert.equal(deleting, false, 'all reads before deletion');
          events.push(['read', path]);
          return documents.has(path) ? plainRecord(copy(documents.get(path))) : null;
        },
        delete(path) { deleting = true; events.push(['delete', path]); pending.push(path); },
      });
      for (const path of pending) documents.delete(path);
    },
    // Admin-Firestore-compatible view for the real services.
    serviceFirestore() {
      return {
        doc: (path) => ({ path }),
        collection: (name) => query(name),
        async runTransaction(callback) {
          const writes = [];
          const result = await callback({
            async get(target) {
              if (typeof target.run === 'function') return { docs: target.run() };
              const exists = documents.has(target.path);
              return { exists, data: () => (exists ? copy(documents.get(target.path)) : undefined) };
            },
            create(reference, data) { writes.push(['create', reference.path, copy(data)]); },
            set(reference, data) { writes.push(['set', reference.path, copy(data)]); },
          });
          for (const [kind, path] of writes) {
            if (kind === 'create' && documents.has(path)) throw new Error('create-only conflict');
          }
          for (const [, path, data] of writes) documents.set(path, data);
          return result;
        },
      };
    },
  };
}

// Offline callable stand-in: the real services behind an HTTP-shaped envelope.
function rehearsal(options = {}) {
  const store = fakeStore();
  const time = { now: BASE_TIME };
  const manifest = createManifest({ runId: RUN, foreignRunId: FOREIGN_RUN, clock: () => time.now }, store);
  const firestore = store.serviceFirestore();
  const now = () => new Date((time.now += 1000));
  const shared = { firestore, environment: SERVICE_ENVIRONMENT, now };
  const lookup = createSaleLookupService(shared);
  const services = {
    submitSale: createSaleService(shared),
    findCorrectableSale: lookup.findSale,
    listRecentCorrectableSales: lookup.listRecentSales,
    submitSaleReturn: createSaleReturnService(shared),
    submitSaleReplacement: createSaleReplacementService(shared),
    submitSaleExchange: createSaleExchangeService(shared),
  };
  const auth = {
    administrator: { uid: `acceptance-${RUN}-administrator`, token: { role: 'administrator' } },
    seller: { uid: `acceptance-${RUN}-seller`, token: { role: 'seller', branchId: `branch-${RUN}` } },
    unassigned: { uid: `acceptance-${RUN}-unassigned`, token: { role: 'unassigned' } },
    client: { uid: `acceptance-${RUN}-client`, token: { role: 'client' } },
    foreign: { uid: `acceptance-${FOREIGN_RUN}-seller`, token: { role: 'seller', branchId: `branch-${FOREIGN_RUN}` } },
    anonymous: undefined,
  };
  const calls = [];
  const call = async (name, data, role) => {
    calls.push([name, role]);
    try {
      const result = await services[name]({ auth: copy(auth[role]), data: copy(data) });
      await options.afterCall?.(name, data, store);
      return { status: 200, body: { result: JSON.parse(JSON.stringify(result)) } };
    } catch (error) {
      if (!(error instanceof SaleError)) throw error;
      return { status: 400, body: { error: { status: error.code.toUpperCase().replaceAll('-', '_'), message: error.message } } };
    }
  };
  return { store, manifest, call, calls, time };
}

const direct = (_name, work) => work();

test('offline: gates pin executable, version, hosts, ambient routing and the three live approvals', () => {
  const runtime = { executable: NODE, version: 'v24.21.0' };
  assert.doesNotThrow(() => gate(PINNED, runtime));
  for (const key of Object.keys(PINNED)) {
    assert.throws(() => gate({ ...PINNED, [key]: 'wrong' }, runtime), /acceptance\/target-pin/);
  }
  for (const key of ['GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_CONFIG', 'HTTPS_PROXY', 'NODE_OPTIONS']) {
    assert.throws(() => gate({ ...PINNED, [key]: 'override' }, runtime), /acceptance\/ambient-override/);
  }
  assert.throws(() => gate(PINNED, { ...runtime, version: 'v24.20.0' }), /acceptance\/node-pin/);
  assert.throws(() => gate(PINNED, { ...runtime, executable: '/usr/bin/node' }), /acceptance\/node-pin/);
  const approved = { ...PINNED, ...LIVE };
  assert.doesNotThrow(() => liveApproval(approved, runtime));
  assert.equal(liveRequested(approved), true);
  for (const key of Object.keys(LIVE)) {
    assert.throws(() => liveApproval({ ...approved, [key]: undefined }, runtime), /acceptance\/live-approval-required/);
    assert.equal(liveRequested({ ...approved, [key]: undefined }), false, `${key} alone keeps the root skipped`);
  }
  // The sales switch never opens the corrections root.
  assert.equal(liveRequested({ ...approved, LDA_CORRECTIONS_HTTP_ACCEPTANCE: undefined, LDA_SALES_HTTP_ACCEPTANCE: '1' }), false);
  assert.throws(() => liveApproval({ ...approved, HTTPS_PROXY: 'x' }, runtime), /acceptance\/ambient-override/);
});

test('offline: independent sale and cumulative refund projections agree with the published calculations', () => {
  const fixtureSpec = fixture(RUN, FOREIGN_RUN);
  const { A, B } = fixtureSpec.productIds;
  for (const invoiceRequested of [false, true]) {
    const lines = [{ quantity: '3', ...fixtureSpec.products[A] }, { quantity: '1.37', ...fixtureSpec.products[B] }];
    const ours = saleCalculation(invoiceRequested, lines);
    const published = calculateSale({ invoiceRequested, lines: lines.map(({ quantity, spec, pricing }) => ({
      quantity, quantitySpec: spec, pricing })) });
    assert.equal(canonical(ours), canonical(published));
    const sale = { calculation: ours, productIds: [A, B], payment: { method: 'card', amountCentavos: ours.totalCentavos } };
    let returned = {};
    // Thirds and odd kilogram fractions exercise cumulative half-up rounding.
    for (const request of [[{ lineIndex: 0, quantity: '1' }, { lineIndex: 1, quantity: '0.33' }],
      [{ lineIndex: 1, quantity: '0.71' }], [{ lineIndex: 0, quantity: '2' }, { lineIndex: 1, quantity: '0.33' }]]) {
      const projected = refundProjection(sale, returned, request);
      const expected = calculateReturnRefund({ receipt: { version: 1, ...sale }, returned, lines: request });
      assert.deepEqual(projected.lines.map(({ scaled, ...line }) => line), expected.lines.map((line) => ({
        lineIndex: line.lineIndex, productId: line.productId, quantity: line.quantity.decimal,
        baseCentavos: line.baseCentavos, additionalIvaCentavos: line.additionalIvaCentavos, totalCentavos: line.totalCentavos })));
      assert.deepEqual([projected.baseCentavos, projected.additionalIvaCentavos, projected.totalCentavos, projected.method,
        projected.invoiced], [expected.baseCentavos, expected.additionalIvaCentavos, expected.totalCentavos,
        expected.refundMethod, expected.invoiced]);
      returned = { ...returned };
      for (const line of projected.lines) returned[line.lineIndex] = (returned[line.lineIndex] ?? 0) + line.scaled;
    }
    assert.deepEqual(returned, { 0: 3, 1: 137 });
    assert.throws(() => refundProjection(sale, returned, [{ lineIndex: 0, quantity: '1' }]), /acceptance\/over-return/);
  }
  assert.equal(formatScaled(50, 2), '0.50');
  assert.equal(formatScaled(1205, 3), '1.205');
  assert.equal(formatScaled(7, 0), '7');
  assert.throws(() => decimal('1.001', 2), /acceptance\/decimal/);
});

test('offline: the full scenario rehearsed against the real services matches every projection and cleans up', async () => {
  const sample = rehearsal();
  await sample.manifest.seed();
  await runScenario({ manifest: sample.manifest, call: sample.call, step: direct });
  await sample.manifest.consistency(FINAL_STOCK);
  await assert.rejects(sample.manifest.consistency({ ...FINAL_STOCK, A: 7 }), OBSERVATION);
  const view = sample.manifest.view();
  assert.equal(view.uncertain, true, 'a failed consistency observation makes the run uncertain');
  assert.deepEqual(view.completed, SUCCESS_ORDER);
  // Every role and denial actually reached a service.
  for (const role of ['anonymous', 'unassigned', 'client', 'administrator', 'foreign']) {
    assert.ok(sample.calls.some(([, caller]) => caller === role), role);
  }
  // The live REST step covers all ten private collections and all three movement families.
  assert.deepEqual([...new Set(sample.manifest.privateDocuments().map((path) => path.split('/')[0]))].sort(),
    CORRECTION_COLLECTIONS);
  assert.deepEqual([...new Set(sample.manifest.correctionMovements().map(({ expected }) => expected.type))].sort(),
    ['exchange-out', 'exchange-return', 'replacement-defect-in', 'replacement-out', 'sale-return', 'sale-return-defect']);
  const created = view.entries.filter((entry) => entry.expected !== null).map((entry) => entry.path);
  assert.deepEqual([...sample.store.documents.keys()].sort(), created.sort(), 'no unplanned document exists');
  // Literal business totals, independent of both the projections and the services.
  assert.deepEqual(sample.manifest.receipt('return-invoiced').refund,
    { method: 'card', baseCentavos: 1000, additionalIvaCentavos: 160, totalCentavos: 1160 });
  await assert.rejects(sample.manifest.cleanup(), RETAINED);
  assert.equal(sample.store.documents.size, created.length, 'an uncertain run retains everything');
  // The same rehearsal with a passing consistency check deletes everything it planned.
  const clean = rehearsal();
  await clean.manifest.seed();
  await runScenario({ manifest: clean.manifest, call: clean.call, step: direct });
  await clean.manifest.consistency(FINAL_STOCK);
  assert.equal(clean.manifest.view().uncertain, false);
  clean.store.events.length = 0;
  await clean.manifest.cleanup();
  assert.equal(clean.store.documents.size, 0);
  const kinds = clean.store.events.map(([kind]) => kind);
  assert.ok(kinds.lastIndexOf('read') < kinds.indexOf('delete'), 'every planned read precedes any delete');
  const deletes = clean.store.events.filter(([kind]) => kind === 'delete').map(([, path]) => path);
  assert.deepEqual(deletes.slice(-2), [`branches/branch-${RUN}`, `branches/branch-${FOREIGN_RUN}`]);
  await assert.rejects(clean.manifest.cleanup(), /acceptance\/cleanup-not-retryable/);
});

test('offline: forged correction artifacts after a success are retained, never adopted', async () => {
  const key = (label) => `corr-${RUN}-${label}`;
  const forgeries = [
    (documents) => { documents.get(`saleReturnAudits/${key('return-good')}`).actorId = 'foreign'; },
    (documents) => { documents.get(`branches/branch-${RUN}/stock/CORR-${RUN.toUpperCase()}-A`).quantityScaled += 1; },
    (documents) => { documents.get(`saleReturnLedgers/${key('sale-u')}`).returned[0] = 3; },
    (documents) => { documents.get(`inventoryMovements/return-${key('return-good')}-1`).type = 'sale-return'; },
    (documents) => { documents.set(`inventoryMovements/sale-${key('sale-u')}-2`, { forged: true }); },
    (documents) => { documents.get(`sales/${key('sale-u')}`).receipt.payment.amountCentavos = 1; },
  ];
  for (const forge of forgeries) {
    const sample = rehearsal({
      afterCall: (name, data, store) => {
        if (name === 'submitSaleReturn' && data.idempotencyKey === key('return-good')) forge(store.documents);
      },
    });
    await sample.manifest.seed();
    await assert.rejects(runScenario({ manifest: sample.manifest, call: sample.call, step: direct }), UNCERTAIN);
    assert.equal(sample.manifest.view().uncertain, true);
    await assert.rejects(sample.manifest.execute('return-invoiced', async () => ({})), ORDER);
    sample.store.events.length = 0;
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.equal(sample.store.events.some(([kind]) => kind === 'delete'), false);
  }
});

test('offline: a denial or lookup that writes anything makes the run uncertain', async () => {
  const sample = rehearsal();
  await sample.manifest.seed();
  await sample.manifest.execute('sale-u', async (data) => callableSuccess(await sample.call('submitSale', data, 'seller')));
  const path = `saleReturns/corr-${RUN}-return-over`;
  await assert.rejects(sample.manifest.unchanged(async () => {
    sample.store.documents.set(path, { late: true });
  }), OBSERVATION);
  await assert.rejects(sample.manifest.unchanged(async () => {}), /acceptance\/unsafe-observation/);
  await assert.rejects(sample.manifest.cleanup(), RETAINED);
  assert.equal(sample.store.events.some(([kind]) => kind === 'delete'), false);
});

test('offline: preexisting planned paths, partial seeds and context poisoning never authorize deletion', async () => {
  for (const mode of ['collision', 'partial']) {
    const store = fakeStore();
    if (mode === 'collision') store.documents.set(`saleReturnLedgers/corr-${RUN}-sale-u`, { foreign: true });
    else {
      const create = store.create.bind(store);
      store.create = async (path, data) => {
        await create(path, data);
        if (path.includes('/stock/')) throw new Error('lost response');
      };
    }
    const manifest = createManifest({ runId: RUN, foreignRunId: FOREIGN_RUN }, store);
    await assert.rejects(manifest.seed(), /acceptance\/seed-uncertain/);
    await assert.rejects(manifest.cleanup(), RETAINED);
    assert.equal(store.events.some(([kind]) => kind === 'delete'), false);
  }
  assert.throws(() => createManifest({ runId: RUN, foreignRunId: RUN }, fakeStore()), /acceptance\/context/);
  assert.throws(() => createManifest({ runId: 'branch-north', foreignRunId: FOREIGN_RUN }, fakeStore()), /acceptance\/context/);
  const sample = rehearsal();
  const request = sample.manifest.request('return-good');
  request.saleId = 'DEMO-COFFEE';
  const view = sample.manifest.view();
  view.entries.length = 0;
  assert.equal(sample.manifest.request('return-good').saleId, `corr-${RUN}-sale-u`);
  // No demo fixture path is ever planned.
  for (const entry of sample.manifest.view().entries) {
    assert.ok(!/branch-north|branch-south|DEMO-|demo-local/.test(entry.path), entry.path);
    assert.ok(entry.path.includes(RUN.toUpperCase()) || entry.path.includes(RUN) || entry.path.includes(FOREIGN_RUN), entry.path);
  }
  assert.throws(() => sample.manifest.request('unknown'), /acceptance\/unknown-operation/);
});

test('offline: deadline does not adopt a late success and cleanup uncertainty cannot be retried', async () => {
  const sample = rehearsal();
  await sample.manifest.seed();
  let finish;
  const pending = new Promise((resolve) => { finish = resolve; });
  await assert.rejects(sample.manifest.execute('sale-u', () => pending, 2), UNCERTAIN);
  finish(await sample.call('submitSale', sample.manifest.request('sale-u'), 'seller'));
  await assert.rejects(sample.manifest.execute('sale-u', async () => ({})), ORDER);
  await assert.rejects(sample.manifest.cleanup(), RETAINED);

  const store = fakeStore();
  const transact = store.transaction.bind(store);
  store.transaction = async (callback) => { await transact(callback); throw new Error('commit response lost'); };
  const manifest = createManifest({ runId: RUN, foreignRunId: FOREIGN_RUN }, store);
  await manifest.seed();
  await assert.rejects(manifest.cleanup(), RETAINED);
  assert.equal(manifest.view().uncertain, true);
  await assert.rejects(manifest.cleanup(), /acceptance\/cleanup-not-retryable/);
});

test('offline: stock consistency follows every stock-moving movement and rejects drift', () => {
  const productId = 'P';
  const branchId = 'b';
  const movement = (type, quantityScaled, product = productId, branch = branchId) => ({ type, quantityScaled, productId: product, branchId: branch });
  const movements = [movement('sale', -3), movement('sale-return', 1), movement('sale-return-defect', 1),
    movement('replacement-defect-in', 1), movement('replacement-out', -1), movement('exchange-return', 1),
    movement('exchange-return-defect', 2), movement('exchange-out', -2, 'Q'), movement('sale', -4, productId, 'other')];
  assert.equal(stockFromMovements(10, movements, productId, branchId), 8);
  assert.throws(() => stockFromMovements(1, [movement('sale', -2)], productId, branchId), /acceptance\/stock-negative/);
  assert.throws(() => stockFromMovements(1, [movement('mystery', 1)], productId, branchId), /acceptance\/movement-type/);
});

test('offline: the seller correction movement view is exact, cost-free and branch-scoped', () => {
  const path = `inventoryMovements/return-corr-${RUN}-return-good-0`;
  const expected = { type: 'sale-return', returnId: `corr-${RUN}-return-good`, saleId: `corr-${RUN}-sale-u`,
    lineIndex: 0, branchId: `branch-${RUN}`, productId: 'P', quantityScaled: 1, unit: 'piece', precision: 0,
    actorId: `acceptance-${RUN}-seller`, occurredAt: 1000 };
  const scope = { branchId: `branch-${RUN}`, actorId: `acceptance-${RUN}-seller` };
  const restFields = (value) => Object.fromEntries(Object.entries(value).map(([key, field]) => [key,
    key === 'occurredAt' ? { timestampValue: '2026-10-08T12:00:00Z' }
      : typeof field === 'number' ? { integerValue: String(field) } : { stringValue: field }]));
  const outcome = (fields, name = `projects/${PROJECT}/databases/(default)/documents/${path}`) => ({
    status: 200, body: { name, fields, createTime: 'x', updateTime: 'x' } });
  assert.doesNotThrow(() => sellerMovementView(outcome(restFields(expected)), path, expected, scope));
  for (const forged of [
    { ...restFields(expected), unitCostCentavos: { integerValue: '321' } },
    { ...restFields(expected), branchId: { stringValue: `branch-${FOREIGN_RUN}` } },
    { ...restFields(expected), actorId: { stringValue: 'someone' } },
    { ...restFields(expected), quantityScaled: { integerValue: '2' } },
    { ...restFields(expected), type: { stringValue: 'sale' } },
    Object.fromEntries(Object.entries(restFields(expected)).filter(([key]) => key !== 'lineIndex')),
  ]) assert.throws(() => sellerMovementView(outcome(forged), path, expected, scope), /acceptance\/seller-movement-view/);
  assert.throws(() => sellerMovementView({ status: 403, body: {} }, path, expected, scope), /acceptance\/seller-movement-view/);
  assert.throws(() => sellerMovementView(outcome(restFields(expected), 'x'), path, expected, scope), /acceptance\/seller-movement-view/);
  assert.throws(() => sellerMovementView(outcome(restFields(expected)), path, { ...expected, unitCostCentavos: 1 }, scope),
    /acceptance\/seller-movement-view/);
});

test('offline: fake HTTP enforces exact URLs, redirects and bounds; callable envelopes are exact', async () => {
  let calls = 0;
  let mode = 'valid';
  const fakeRequest = (_url, _options, callback) => {
    calls++;
    const request = new EventEmitter();
    request.destroy = () => {};
    request.end = () => queueMicrotask(() => {
      const response = new EventEmitter();
      response.statusCode = mode === 'redirect' ? 302 : 200;
      callback(response);
      response.emit('data', Buffer.from(mode === 'large' ? 'x'.repeat(262145) : '{"result":{}}'));
      response.emit('end');
    });
    return request;
  };
  const http = makeHttp({ ...PINNED, ...LIVE }, ['saleReturns/x'], fakeRequest, () => {});
  await assert.rejects(http('http://example.invalid'), /acceptance\/url-refused/);
  await assert.rejects(http(`${REST}/saleReturns/y`), /acceptance\/url-refused/);
  await assert.rejects(http(`${BASE}/deleteEverything`, 'POST', {}), /acceptance\/url-refused/);
  await assert.rejects(http(LOGIN, 'DELETE'), /acceptance\/url-refused/);
  await assert.rejects(http(LOGIN, 'POST', { text: 'x'.repeat(16385) }), /acceptance\/request-size/);
  assert.equal(calls, 0);
  for (const name of FUNCTIONS) assert.equal((await http(`${BASE}/${name}`, 'POST', {})).status, 200);
  assert.equal((await http(`${REST}/saleReturns/x`)).status, 200);
  for (mode of ['redirect', 'large']) await assert.rejects(http(LOGIN, 'POST', {}), /acceptance\/http-unknown/);
  await assert.rejects(makeHttp(PINNED, [], fakeRequest)(LOGIN), /acceptance\/live-approval-required/);
  const denied = { status: 400, body: { error: { status: 'OUT_OF_RANGE', message: DENIAL.overReturn } } };
  assert.doesNotThrow(() => callableDenied(denied, 'OUT_OF_RANGE', DENIAL.overReturn));
  assert.throws(() => callableDenied(denied, 'OUT_OF_RANGE', DENIAL.notFound), /acceptance\/callable-denial/);
  assert.throws(() => callableDenied({ status: 200, body: { result: {} } }, 'OUT_OF_RANGE'), /acceptance\/callable-denial/);
  assert.deepEqual(callableSuccess({ status: 200, body: { result: { a: 1 } } }), { a: 1 });
  assert.throws(() => callableSuccess({ status: 200, body: { result: {}, extra: 1 } }), /acceptance\/callable-result/);
});

test('offline: Timestamps, the local certificate credential and initialization errors stay strict', () => {
  const stamp = (seconds, nanoseconds) => ({ seconds, nanoseconds,
    toMillis: () => seconds * 1000 + Math.floor(nanoseconds / 1e6) });
  assert.equal(normalizeRecord(stamp(1, 123456789)), 1123);
  assert.deepEqual(normalizeRecord({ updatedAt: stamp(1, 999), returned: { 0: 1 } }), { updatedAt: 1000, returned: { 0: 1 } });
  for (const forged of [stamp(1, 1.5), stamp(1, -1), stamp(1, 1e9), { ...stamp(1, 0), toMillis: () => 2000 }]) {
    assert.throws(() => normalizeRecord(forged), TIMESTAMP);
  }
  assert.throws(() => normalizeRecord({ occurredAt: 1000 }), TIMESTAMP);
  const calls = [];
  const credential = ownedCredential((options) => { calls.push(options); return { kind: 'cert' }; },
    (type, options) => { calls.push({ type, modulusLength: options.modulusLength }); return { privateKey: 'PEM' }; });
  assert.deepEqual(credential, { kind: 'cert' });
  assert.deepEqual(calls, [{ type: 'rsa', modulusLength: 2048 },
    { projectId: PROJECT, clientEmail: `acceptance-local@${PROJECT}.iam.gserviceaccount.com`, privateKey: 'PEM' }]);
  const wrapped = initializationError(Object.assign(new Error('secret detail'), { code: 'firestore/invalid-credential' }));
  assert.equal(wrapped.message, 'acceptance/runtime-initialization');
  assert.equal(wrapped.code, 'firestore/invalid-credential');
  assert.equal(initializationError('opaque').code, 'acceptance/unknown');
});

test('offline: registered teardown attempts every stage despite exceptions', async () => {
  const events = [];
  await assert.rejects(teardown([
    async () => { events.push('firestore'); throw new Error('private raw error'); },
    async () => { events.push('auth'); throw new Error('private raw error'); },
    async () => { events.push('dispose'); },
  ]), /acceptance\/teardown-incomplete/);
  assert.deepEqual(events, ['firestore', 'auth', 'dispose']);
});

async function openLive(t, environment) {
  liveApproval(environment);
  liveApproval(process.env);
  const require = approvedRequire();
  const authEntry = `${SDK_ROOT}/firebase-admin/lib/auth/index.js`;
  if (require.resolve('firebase-admin/auth') !== authEntry || realpathSync(authEntry) !== authEntry
    || !lstatSync(authEntry).isFile()) throw new Error('acceptance/auth-sdk-resolution');
  const { initializeApp, deleteApp, cert } = require('firebase-admin/app');
  const { getFirestore } = require('firebase-admin/firestore');
  const { getAuth } = require('firebase-admin/auth');
  const runId = randomUUID();
  const foreignRunId = randomUUID();
  // Two owned Auth manifests: the full role set, and one seller of the owned foreign branch.
  const authManifests = { main: createOwnedAuthManifest({ runId }), foreign: createOwnedAuthManifest({ runId: foreignRunId }) };
  registerPlannedIdentities(authManifests.main);
  registerPlannedIdentities(authManifests.foreign, ['seller']);
  let app, firestore, auth, manifest;
  let preserve = async () => {};
  t.after(() => teardown([
    async () => { if (manifest) await manifest.cleanup(); },
    async () => { await preserve(); },
    async () => {
      if (!auth) return;
      let retained = false;
      for (const owned of Object.values(authManifests)) {
        const result = await cleanupOwnedIdentities({ auth, manifest: owned });
        retained ||= result.cleanup.some((entry) => !['removed', 'absent', 'planned'].includes(entry.outcome));
      }
      if (retained) throw new Error('acceptance/auth-retained');
    },
    async () => {
      await teardown([
        async () => { if (firestore) await firestore.terminate(); },
        async () => { if (app) await deleteApp(app); },
      ]);
    },
  ]));
  try {
    // Emulator-local certificate from a fresh in-memory key; no ADC, default app or discovery.
    app = initializeApp({ projectId: PROJECT, credential: ownedCredential(cert) }, `owned-corrections-${runId}`);
    firestore = getFirestore(app);
    firestore.settings({ projectId: PROJECT, host: PINNED.FIRESTORE_EMULATOR_HOST,
      ssl: false, preferRest: false, ignoreUndefinedProperties: false,
      universeDomain: 'googleapis.com', grpcOptions: { 'grpc.enable_http_proxy': 0 } });
    if (firestore.projectId !== PROJECT) throw new Error('acceptance/project');
    const sdkAuth = getAuth(app);
    auth = Object.fromEntries(['createUser', 'getUser', 'setCustomUserClaims', 'deleteUser'].map((method) => [method,
      async (...args) => {
        try { return await sdkAuth[method](...args); }
        catch (error) {
          throw Object.assign(new Error('acceptance/auth-operation'), {
            code: error?.code === 'auth/user-not-found' ? 'auth/user-not-found' : 'acceptance/auth-unknown',
          });
        }
      }]));
    const decode = (snapshot) => snapshot.exists ? normalizeRecord(snapshot.data()) : null;
    const store = {
      read: (paths) => Promise.all(paths.map(async (path) => decode(await firestore.doc(path).get()))),
      create: (path, data) => firestore.doc(path).create(data),
      transaction: (callback) => firestore.runTransaction((transaction) => callback({
        get: async (path) => decode(await transaction.get(firestore.doc(path))),
        delete: (path) => transaction.delete(firestore.doc(path)),
      })),
    };
    manifest = createManifest({ runId, foreignRunId }, store);
    return { runId, foreignRunId, authManifests, auth, manifest, registerPreservation(check) { preserve = check; } };
  } catch (error) { throw initializationError(error); }
}

// No live acceptance RED can be established before authorized emulator execution. The
// skipped root holds future real transport cases; the offline rehearsal above runs the
// same scenario against the real services, which is not transport proof.
test('live CORR-06B correction callables, Auth and seller rules over HTTP (pending authorization)',
  { skip: !liveRequested(process.env) }, async (t) => {
    liveApproval(process.env); // Fail closed BEFORE SDK imports, handles or writes.
    const runtime = await openLive(t, process.env);
    const { runId, foreignRunId, authManifests, auth, manifest } = runtime;
    const secret = (role) => ({ email: `${role}-${randomUUID()}@demo-lda-inventory.invalid`,
      password: randomUUID() + randomUUID() });
    const identities = {
      main: Object.fromEntries([...authManifests.main.entries.keys()].map((role) => [role, secret(role)])),
      foreign: { seller: secret('foreign') },
    };
    for (const [name, owned] of Object.entries(authManifests)) {
      const provisioned = await provisionOwnedIdentities({ auth, manifest: owned, createParams: identities[name] });
      if (provisioned.provisioned.some((entry) => entry.outcome !== 'owned')) throw new Error('acceptance/auth-provision');
    }
    const http = makeHttp(process.env, [...BASELINE_DOCS, ...manifest.paths()]);
    const tokens = { anonymous: undefined };
    const login = async (role, owned, plannedRole, identity, ownerRunId) => {
      const outcome = await http(LOGIN, 'POST', { ...identity, returnSecureToken: true });
      const planned = owned.entries.get(plannedRole);
      if (outcome.status !== 200 || outcome.body.localId !== planned.uid
        || typeof outcome.body.idToken !== 'string' || outcome.body.idToken.length < 20) {
        throw new Error('acceptance/login');
      }
      tokens[role] = outcome.body.idToken; // Never assert, log or persist token material.
      requireSame((await auth.getUser(planned.uid)).customClaims, { acceptanceRunId: ownerRunId, role: plannedRole,
        ...(plannedRole === 'seller' ? { branchId: `branch-${ownerRunId}` } : {}) });
    };
    for (const [role, identity] of Object.entries(identities.main)) {
      await login(role, authManifests.main, role, identity, runId);
    }
    await login('foreign', authManifests.foreign, 'seller', identities.foreign.seller, foreignRunId);
    const baseline = async () => ({
      auth: await Promise.all(BASELINE_AUTH.map(async (uid) => {
        const user = await auth.getUser(uid);
        return { uid: user.uid, created: user.metadata.creationTime, claims: user.customClaims };
      })),
      firestore: await Promise.all(BASELINE_DOCS.map(async (path) => {
        const outcome = await http(`${REST}/${path}`, 'GET', undefined, tokens.administrator);
        if (outcome.status !== 200) throw new Error('acceptance/baseline-unavailable');
        return outcome.body;
      })),
    });
    const before = await baseline();
    runtime.registerPreservation(async () => { requireSame(await baseline(), before); });
    await manifest.seed();
    const call = (name, data, role) => http(`${BASE}/${name}`, 'POST', { data }, tokens[role]);
    await runScenario({ manifest, call, step: (name, work) => t.test(name, work) });
    await t.test('seller REST rules: correction records are private; own-branch correction movements are readable',
      () => manifest.unchanged(async () => {
        const get = async (path, role) => (await http(`${REST}/${path}`, 'GET', undefined, tokens[role]));
        const privateDocuments = manifest.privateDocuments();
        requireSame([...new Set(privateDocuments.map((path) => path.split('/')[0]))].sort(), CORRECTION_COLLECTIONS);
        for (const path of privateDocuments) {
          if ((await get(path, 'seller')).status !== 403) throw new Error('acceptance/private-read');
        }
        const movements = manifest.correctionMovements();
        requireSame([...new Set(movements.map(({ path }) => path.split('/')[1].split('-')[0]))].sort(),
          ['exchange', 'replacement', 'return']);
        const scope = { branchId: `branch-${runId}`, actorId: `acceptance-${runId}-seller` };
        for (const { path, expected } of movements) {
          sellerMovementView(await get(path, 'seller'), path, expected, scope);
          if ((await get(path, 'foreign')).status !== 403) throw new Error('acceptance/foreign-movement-read');
        }
      }));
    await t.test('consistency: final stock equals the seed plus every movement; sales are unchanged',
      () => manifest.consistency(FINAL_STOCK));
    // Teardown verifies Firestore exact contents transactionally, Auth privately, and
    // baseline preservation. Auth's nontransactional verify-delete race remains.
  });
