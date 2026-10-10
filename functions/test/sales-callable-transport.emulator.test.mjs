// FUNC-02A/B preparation: offline discovery must never initialize an SDK or use HTTP.
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { EventEmitter } from 'node:events';
import { lstatSync, realpathSync } from 'node:fs';
import { approvedRequire, SDK_ROOT, canonical } from './sales-emulator-support.mjs';
import test from 'node:test';
import {
  createOwnedAuthManifest, registerPlannedIdentities,
  provisionOwnedIdentities, cleanupOwnedIdentities,
} from './owned-auth-manifest.mjs';

const NODE = '/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node';
const RUN = '12345678-1234-4234-8234-123456789abc';
const PROJECT = 'demo-lda-inventory';
const PINNED = {
  GCLOUD_PROJECT: PROJECT, FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080', FUNCTIONS_EMULATOR: 'true',
};
const copy = (value) => structuredClone(value);
const UNCERTAIN = /acceptance\/operation-uncertain/;
const ORDER = /acceptance\/operation-order/;
const RETAINED = /acceptance\/firestore-retained-or-delete-unknown/;
const TIMESTAMP = /acceptance\/timestamp-type/;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const CALLABLE = { create: 'createProduct', price: 'setProductPrice', reprice: 'setProductPrice',
  intake: 'stockIntake', sale: 'submitSale', resale: 'submitSale', quote: 'quoteSale' };
const FUNCTIONS = [...new Set(Object.values(CALLABLE))];
const SALE_KINDS = ['sale', 'resale'];
// Each operation requires its predecessor; repricing happens between two seller sales.
const AFTER = { price: 'create', intake: 'price', sale: 'intake', reprice: 'sale', resale: 'reprice' };
const BASE = `http://127.0.0.1:5001/${PROJECT}/us-south1`;
const REST = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const LOGIN = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only';
const same = (a, b) => canonical(a) === canonical(b);
const requireSame = (a, b) => { if (!same(a, b)) throw new Error('acceptance/content-mismatch'); };
function decimal(value, precision) {
  const [whole, fraction = ''] = value.split('.');
  return Number(BigInt(whole) * 10n ** BigInt(precision) + BigInt(fraction.padEnd(precision, '0')));
}

// Independent mirror of the published v1 single-line sale calculation (half-up per line).
function saleCalculation({ invoiceRequested, lines: [{ quantity }] }, spec, pricing) {
  const half = (numerator, denominator) => (2n * numerator + denominator) / (2n * denominator);
  const scaled = decimal(quantity, spec.precision);
  const base = half(BigInt(scaled) * BigInt(pricing.listedPriceCentavos), 10n ** BigInt(spec.precision));
  const iva = invoiceRequested && pricing.priceMode === 'iva-additional-on-invoice' && pricing.ivaTreatment === 'taxable'
    ? half(base * BigInt(pricing.ivaRateBasisPoints), 10000n) : 0n;
  const totals = { baseCentavos: Number(base), additionalIvaCentavos: Number(iva), totalCentavos: Number(base + iva) };
  return { version: 1, currency: 'MXN', invoiceRequested, calculationPolicy: { version: 1, rounding: 'half-up',
    roundingScope: 'per-line', additionalIvaBase: 'rounded-line-base', includedIvaExtraction: 'not-calculated' },
  lines: [{ quantity: { version: 1, spec: copy(spec), scaled, decimal: quantity }, pricing: { version: 1, ...pricing },
    ...totals, includedIvaCentavos: null }], ...totals };
}

// Exact full payment for uninvoiced denial lines at the first published price, so a business
// denial can never be explained by a payment mismatch instead of its targeted rule.
function denialPayment(manifest, quantities) {
  const spec = manifest.request('create').quantitySpec;
  const price = manifest.request('price');
  const pricing = { listedPriceCentavos: decimal(price.listedPriceMxn, 2), priceMode: price.priceMode,
    ivaTreatment: price.ivaTreatment };
  const amountCentavos = quantities.reduce((total, quantity) => total
    + saleCalculation({ invoiceRequested: false, lines: [{ quantity }] }, spec, pricing).totalCentavos, 0);
  return { method: 'cash', amountCentavos };
}

// Server messages that identify which sales rule produced a denial.
const SALE_DENIAL = {
  fields: 'sale request contains missing, invalid or unsupported fields',
  quantity: 'quantity is not representable by the product specification',
  payment: 'full payment must equal the authoritative total',
  stock: 'insufficient stock',
  product: 'product does not exist',
  unauthenticated: 'authentication is required',
  seller: 'an assigned seller is required',
  quote: 'quote request contains missing, invalid or unsupported fields',
};

// Sellers may read their own branch's sale movements by published rule; the movement must carry
// only the seller actorId as identity and an exact cost-free field set.
const SELLER_MOVEMENT_FIELDS = ['actorId', 'branchId', 'occurredAt', 'precision', 'productId', 'quantityScaled',
  'saleId', 'type', 'unit'];
function sellerMovementView(outcome, { saleKey, actorId, branchId }) {
  const fields = outcome.body?.fields;
  if (outcome.status !== 200 || typeof outcome.body?.name !== 'string'
    || !outcome.body.name.endsWith(`/documents/inventoryMovements/sale-${saleKey}-0`)
    || !fields || !same(Object.keys(fields).sort(), SELLER_MOVEMENT_FIELDS)
    || fields.type?.stringValue !== 'sale' || fields.saleId?.stringValue !== saleKey
    || fields.branchId?.stringValue !== branchId || fields.actorId?.stringValue !== actorId) {
    throw new Error('acceptance/seller-movement-view');
  }
}

// Cross-collection agreement for confirmed sales; exact projections are validated separately.
function ledger(records, { branch, other, productId, intake, sales }) {
  const at = (path) => records.get(path) ?? null;
  const fail = () => { throw new Error('acceptance/ledger-inconsistent'); };
  const movements = [intake, ...sales.map((key) => `inventoryMovements/sale-${key}-0`)];
  let total = 0;
  for (const path of movements) {
    if (at(path)?.branchId !== branch || at(path).productId !== productId) fail();
    total += at(path).quantityScaled;
  }
  const stock = at(`branches/${branch}/stock/${productId}`);
  if (at(`branches/${other}/stock/${productId}`) !== null || stock?.quantityScaled !== total || total < 0
    || `inventoryMovements/${stock.lastMovementId}` !== movements.at(-1)
    || stock.updatedAt !== at(movements.at(-1)).occurredAt) fail();
  for (const key of sales) {
    const receipt = at(`saleSubmissionReceipts/${key}`);
    const audit = at(`saleAudits/${key}`);
    const movement = at(`inventoryMovements/sale-${key}-0`);
    const sale = at(`sales/${key}`);
    const lines = receipt?.result?.calculation?.lines;
    if (!sale || !audit || !receipt || !movement || !same(sale.receipt, receipt.result) || receipt.result.saleId !== key
      || receipt.branchId !== branch || receipt.result.branchId !== branch || !same(receipt.result.productIds, [productId])
      || audit.saleId !== key || audit.branchId !== branch || audit.actorId !== receipt.actorId
      || movement.saleId !== key || movement.actorId !== receipt.actorId || lines?.length !== 1
      || -movement.quantityScaled !== lines[0].quantity.scaled
      || receipt.result.payment.amountCentavos !== receipt.result.calculation.totalCentavos
      || ![sale.createdAt, audit.createdAt, movement.occurredAt].every((time) => time === receipt.completedAt)
      || at(`inventoryMovements/sale-${key}-1`) !== null) fail();
  }
}

function gate(environment, runtime = { executable: process.execPath, version: process.version }) {
  if (runtime.executable !== NODE || runtime.version !== 'v24.21.0') throw new Error('acceptance/node-pin');
  for (const [key, value] of Object.entries(PINNED)) {
    if (environment[key] !== value) throw new Error('acceptance/target-pin');
  }
  for (const key of Object.keys(environment)) {
    if (Object.hasOwn(PINNED, key) || key === 'LDA_SALES_HTTP_ACCEPTANCE') continue;
    if (/^(GOOGLE_|GCLOUD_|GCP_|FIREBASE_|FIRESTORE_|FUNCTIONS_|CLOUDSDK_|GRPC_|grpc_|NODE_OPTIONS$|NODE_PATH$|NODE_EXTRA_CA_CERTS$|NODE_TLS_REJECT_UNAUTHORIZED$)/.test(key)
      || /proxy/i.test(key)) throw new Error('acceptance/ambient-override');
  }
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

// Private closure authority: neither context, public views nor server records
// are adopted as expected business data. Only corroborated operations advance it.
function createManifest(context, adapter) {
  const { runId, actorId, clock = Date.now } = context;
  if (!UUID.test(runId) || actorId !== `acceptance-${runId}-administrator` || typeof clock !== 'function') {
    throw new Error('acceptance/context');
  }
  const store = Object.fromEntries(['read', 'create', 'transaction'].map((name) => [name, adapter[name].bind(adapter)]));
  const seller = `acceptance-${runId}-seller`; // Derived from the validated runId only.
  const branch = `branch-${runId}`;
  const other = `${branch}-other`;
  const key = (label) => `http-${runId}-${label}`;
  const saleSlots = (saleKey) => [`sales/${saleKey}`, `saleAudits/${saleKey}`, `saleSubmissionReceipts/${saleKey}`,
    `inventoryMovements/sale-${saleKey}-0`, `inventoryMovements/sale-${saleKey}-1`];
  const paths = {
    branches: [`branches/${branch}`, `branches/${other}`],
    createReceipt: `productCreationReceipts/${key('create')}`,
    priceAudit: `productPriceAudits/${key('price')}`,
    priceReceipt: `productPriceUpdateReceipts/${key('price')}`,
    entry: `stockIntakeEntries/${key('intake')}`,
    movement: `inventoryMovements/${key('intake')}`,
    intakeReceipt: `stockIntakeReceipts/${key('intake')}`,
    repriceAudit: `productPriceAudits/${key('reprice')}`,
    repriceReceipt: `productPriceUpdateReceipts/${key('reprice')}`,
  };
  const entries = new Map();
  const plan = (path) => {
    if (entries.has(path)) throw new Error('acceptance/duplicate-plan');
    entries.set(path, { expected: null, state: 'planned' });
  };
  for (const path of [...paths.branches, ...Object.values(paths).filter((value) => typeof value === 'string')]) plan(path);
  const denialLabels = ['anonymous', 'unassigned', 'client', 'seller'];
  for (const label of denialLabels) {
    for (const collection of ['productCreationReceipts', 'productPriceAudits', 'productPriceUpdateReceipts',
      'stockIntakeEntries', 'inventoryMovements', 'stockIntakeReceipts']) plan(`${collection}/${key(label)}`);
  }
  // Sale slots are exact and planned before any write: successes and every denial key.
  const saleDenials = ['anonymous', 'unassigned', 'client', 'administrator', 'insufficient', 'branch', 'duplicate',
    'zero', 'precision', 'method', 'payment', 'missing', 'stale'].map((label) => `sale-${label}`);
  for (const label of [...SALE_KINDS, ...saleDenials]) saleSlots(key(label)).forEach(plan);
  let productId = null;
  let seeded = false;
  let uncertain = false;
  let active = false;
  let cleanupStarted = false;
  const completed = new Set();
  const requests = {
    create: { idempotencyKey: key('create'), name: `Acceptance ${runId}`, quantitySpec: { unit: 'kg', precision: 2 } },
    price: { idempotencyKey: key('price'), listedPriceMxn: '12.34', priceMode: 'iva-included',
      ivaTreatment: 'taxable', ivaRatePercent: '16.00' },
    intake: { idempotencyKey: key('intake'), branchId: branch, quantity: '2.50', unitCostMxn: '3.21' },
    sale: { idempotencyKey: key('sale'), invoiceRequested: false, lines: [{ quantity: '1.00' }],
      payment: { method: 'cash', amountCentavos: 1234 } },
    reprice: { idempotencyKey: key('reprice'), listedPriceMxn: '15.00', priceMode: 'iva-additional-on-invoice',
      ivaTreatment: 'taxable', ivaRatePercent: '16.00' },
    resale: { idempotencyKey: key('resale'), invoiceRequested: true, lines: [{ quantity: '0.50' }],
      payment: { method: 'card', amountCentavos: 870 } },
  };
  const scope = () => ({ branch, other, productId, intake: paths.movement,
    sales: SALE_KINDS.filter((kind) => completed.has(kind)).map(key) });
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
  const confirm = async (kind, result, before, after) => {
    let expected = new Map();
    const input = SALE_KINDS.includes(kind) ? request(kind) : copy(requests[kind]);
    const records = await read();
    if (kind === 'create') {
      if (!same(Object.keys(result).sort(), ['internalCode', 'productId', 'replayed'])
        || result.replayed !== false || result.productId !== result.internalCode
        || !/^PRD-[A-F0-9]{16,32}$/.test(result.productId)) throw new Error('acceptance/create-result');
      const id = result.productId;
      // Bind planned dynamic slots only from the successful response, never a query.
      for (const path of [`products/${id}`, `costs/${id}`, `branches/${branch}/stock/${id}`, `branches/${other}/stock/${id}`]) plan(path);
      const dynamic = await read();
      const receipt = dynamic.get(paths.createReceipt);
      const timestamp = stamp(receipt?.completedAt, before, after);
      const bareResult = { productId: id, internalCode: id };
      expected.set(`products/${id}`, { internalCode: id, name: input.name, quantitySpec: input.quantitySpec, createdAt: timestamp });
      expected.set(paths.createReceipt, { fingerprint: JSON.stringify({ actorId, name: input.name,
        quantitySpec: input.quantitySpec }), result: bareResult, completedAt: timestamp, actorId });
      for (const [path, entry] of entries) requireSame(dynamic.get(path), expected.has(path) ? expected.get(path) : entry.expected);
      productId = id;
    } else {
      const receiptPath = { price: paths.priceReceipt, reprice: paths.repriceReceipt, intake: paths.intakeReceipt }[kind]
        ?? `saleSubmissionReceipts/${input.idempotencyKey}`;
      const timestamp = stamp(records.get(receiptPath)?.completedAt, before, after);
      const spec = requests.create.quantitySpec;
      const stockPath = `branches/${branch}/stock/${productId}`;
      if (kind === 'price' || kind === 'reprice') {
        const pricing = { listedPriceCentavos: decimal(input.listedPriceMxn, 2), currency: 'MXN', priceMode: input.priceMode,
          ivaTreatment: input.ivaTreatment, ivaRateBasisPoints: decimal(input.ivaRatePercent, 2) };
        const bareResult = { auditId: input.idempotencyKey, productId, pricing };
        requireSame(result, { ...bareResult, replayed: false });
        const prior = entries.get(`products/${productId}`).expected;
        expected.set(`products/${productId}`, { ...prior,
          pricing, pricingUpdatedAt: timestamp, lastPricingAuditId: input.idempotencyKey });
        expected.set(kind === 'price' ? paths.priceAudit : paths.repriceAudit, { productId,
          previousAuditId: prior.lastPricingAuditId ?? null, oldPricing: prior.pricing ?? null,
          newPricing: pricing, changedAt: timestamp, actorId });
        expected.set(receiptPath, { fingerprint: JSON.stringify({ actorId, productId, pricing }),
          result: bareResult, completedAt: timestamp, actorId });
      } else if (SALE_KINDS.includes(kind)) {
        // Sales price from the private catalog projection at submission time, never the response.
        const saleKey = input.idempotencyKey;
        const calculation = saleCalculation(input, spec, entries.get(`products/${productId}`).expected.pricing);
        const branchCode = entries.get(`branches/${branch}`).expected.code;
        const head = saleKey.replace(/[^a-zA-Z0-9]/g, '').slice(0, 8).toUpperCase();
        const receipt = { version: 2, saleId: saleKey, branchId: branch, branchCode,
          folio: `${branchCode}-${head.slice(0, 4)}-${head.slice(4)}`, productIds: [productId],
          calculation, payment: input.payment };
        requireSame(result, { receipt, replayed: false, createdAt: timestamp });
        const scaled = calculation.lines[0].quantity.scaled;
        const movementId = `sale-${saleKey}-0`;
        expected.set(`sales/${saleKey}`, { receipt, createdAt: timestamp });
        expected.set(`saleAudits/${saleKey}`, { saleId: saleKey, branchId: branch, actorId: seller, createdAt: timestamp });
        expected.set(`inventoryMovements/${movementId}`, { type: 'sale', saleId: saleKey, branchId: branch, productId,
          quantityScaled: -scaled, ...spec, actorId: seller, occurredAt: timestamp });
        expected.set(stockPath, { quantityScaled: entries.get(stockPath).expected.quantityScaled - scaled, ...spec,
          updatedAt: timestamp, lastMovementId: movementId });
        expected.set(receiptPath, { actorId: seller, branchId: branch, completedAt: timestamp, result: receipt,
          fingerprint: JSON.stringify({ actorId: seller, branchId: branch, ...input }) });
      } else {
        const quantityScaled = decimal(input.quantity, spec.precision);
        const unitCostCentavos = decimal(input.unitCostMxn, 2);
        const lineTotalCentavos = Number(BigInt(quantityScaled) * BigInt(unitCostCentavos) / 10n ** BigInt(spec.precision));
        const bareResult = { entryId: input.idempotencyKey, movementId: input.idempotencyKey,
          quantityScaled, stockQuantityScaled: quantityScaled, unitCostCentavos, lineTotalCentavos };
        requireSame(result, { ...bareResult, replayed: false });
        expected.set(paths.entry, { branchId: branch, productId, quantityScaled, ...spec,
          unitCostCentavos, lineTotalCentavos, currency: 'MXN',
          calculationPolicyVersion: 'mxn-unit-cost-truncate-v1', createdAt: timestamp, createdBy: actorId });
        expected.set(paths.movement, { type: 'stock-intake', branchId: branch, productId, quantityScaled,
          ...spec, entryId: input.idempotencyKey, occurredAt: timestamp, actorId });
        expected.set(stockPath, { quantityScaled, ...spec,
          updatedAt: timestamp, lastMovementId: input.idempotencyKey });
        expected.set(`costs/${productId}`, { latestUnitCostCentavos: unitCostCentavos, currency: 'MXN',
          sourceEntryId: input.idempotencyKey, updatedAt: timestamp });
        expected.set(paths.intakeReceipt, { fingerprint: JSON.stringify({ branchId: branch, productId,
          quantity: input.quantity, unitCostCentavos }), result: bareResult, completedAt: timestamp, actorId });
      }
      for (const [path, entry] of entries) requireSame(records.get(path), expected.has(path) ? expected.get(path) : entry.expected);
      if (SALE_KINDS.includes(kind)) ledger(records, { ...scope(), sales: [...scope().sales, input.idempotencyKey] });
    }
    for (const [path, value] of expected) entries.set(path, { expected: copy(value), state: 'confirmed' });
    completed.add(kind);
  };
  const request = (kind) => {
    if (!Object.hasOwn(requests, kind)) throw new Error('acceptance/unknown-operation');
    if (kind === 'create') return copy(requests.create);
    if (!SALE_KINDS.includes(kind)) return copy({ ...requests[kind], productId });
    // Field order matches the server fingerprint: key, invoice intent, lines, payment.
    const { idempotencyKey, invoiceRequested, lines, payment } = copy(requests[kind]);
    return { idempotencyKey, invoiceRequested, lines: lines.map(({ quantity }) => ({ productId, quantity })), payment };
  };
  return Object.freeze({
    paths: () => copy(paths), request,
    view: () => ({ runId, productId, uncertain, dynamicSlots: ['product', 'cost', 'ownStock', 'foreignStock'],
      entries: [...entries].map(([path, entry]) => ({ path, ...copy(entry) })) }),
    denialKey(label) {
      if (!denialLabels.includes(label) && !saleDenials.includes(label)) throw new Error('acceptance/denial-plan');
      return key(label);
    },
    receipt(kind) { // Copy of a confirmed private sale receipt, for replay comparison only.
      if (!SALE_KINDS.includes(kind) || !completed.has(kind)) throw new Error('acceptance/operation-order');
      return copy(entries.get(`sales/${key(kind)}`).expected.receipt);
    },
    // The exact read-only quote of a sale's cart at the current private pricing and own-branch
    // stock: the same independent calculation the confirmed sale must charge.
    quote(kind, quantity) {
      if (!SALE_KINDS.includes(kind) || !completed.has('intake')) throw new Error('acceptance/operation-order');
      const { invoiceRequested, lines } = request(kind);
      if (quantity !== undefined) lines[0].quantity = quantity;
      const calculation = saleCalculation({ invoiceRequested, lines }, requests.create.quantitySpec,
        entries.get(`products/${productId}`).expected.pricing);
      const stock = entries.get(`branches/${branch}/stock/${productId}`).expected;
      const available = stock.quantityScaled >= calculation.lines[0].quantity.scaled;
      return copy({ request: { invoiceRequested, lines },
        expected: { calculation, totalCentavos: calculation.totalCentavos, lines: [{ productId, available }] } });
    },
    saleReplay(kind) { // The exact replay response: the stored receipt and the original sale time.
      if (!SALE_KINDS.includes(kind) || !completed.has(kind)) throw new Error('acceptance/operation-order');
      const { receipt, createdAt } = entries.get(`sales/${key(kind)}`).expected;
      return copy({ receipt, replayed: true, createdAt });
    },
    async seedBranches() {
      if (seeded || cleanupStarted) throw new Error('acceptance/seed-once');
      seeded = true;
      try {
        validate(await read());
        uncertain = true;
        for (const path of paths.branches) {
          // Owned acceptance codes never reuse the demo NTE/SUR codes.
          const code = path === paths.branches[0] ? 'HTS' : 'HTO';
          const expected = { name: path.slice(9), code, acceptanceRunId: runId };
          await deadline(() => store.create(path, copy(expected)));
          const actual = (await read()).get(path);
          requireSame(actual, expected);
          entries.set(path, { state: 'confirmed', expected });
        }
        uncertain = false;
      } catch { uncertain = true; throw new Error('acceptance/seed-uncertain'); }
    },
    async execute(kind, transport, timeoutMs = 10000) {
      if (!seeded || uncertain || active || cleanupStarted || completed.has(kind) || !Object.hasOwn(requests, kind)
        || (kind !== 'create' && (!productId || !completed.has(AFTER[kind])))) {
        throw new Error('acceptance/operation-order');
      }
      const input = request(kind);
      active = true;
      try { validate(await read()); }
      catch { active = false; uncertain = true; throw new Error('acceptance/preflight-mismatch'); }
      if (cleanupStarted) { active = false; throw new Error('acceptance/cleanup-started'); }
      uncertain = true; // BEFORE issuing any request; timeout never cancels its side effects.
      const before = clock();
      try {
        const result = await deadline(() => transport(copy(input)), timeoutMs);
        const after = clock();
        await confirm(kind, copy(result), before, after);
        uncertain = false;
        return copy(result);
      } catch { throw new Error('acceptance/operation-uncertain'); }
      finally { active = false; }
    },
    async unchanged(transport) {
      if (uncertain || active || cleanupStarted) throw new Error('acceptance/unsafe-observation');
      active = true;
      let before;
      try { before = await read(); validate(before); }
      catch { active = false; uncertain = true; throw new Error('acceptance/preflight-mismatch'); }
      if (cleanupStarted) { active = false; throw new Error('acceptance/cleanup-started'); }
      uncertain = true;
      try {
        const result = await deadline(transport);
        const after = await read();
        requireSame([...after], [...before]);
        validate(after);
        if (completed.has('sale')) ledger(after, scope());
        uncertain = false;
        return result;
      } catch { throw new Error('acceptance/observation-uncertain'); }
      finally { active = false; }
    },
    async cleanup() {
      if (cleanupStarted) throw new Error('acceptance/cleanup-not-retryable');
      cleanupStarted = true;
      try {
        await deadline(() => store.transaction(async (transaction) => {
          const records = new Map();
          for (const path of entries.keys()) records.set(path, await transaction.get(path));
          if (uncertain || active) throw new Error('acceptance/uncertain-run');
          validate(records);
          const rank = (path) => path.startsWith('products/') ? 2 : paths.branches.includes(path) ? 3 : 1;
          for (const path of [...entries.keys()].sort((a, b) => rank(a) - rank(b))) {
            if (records.get(path) !== null) transaction.delete(path);
          }
        }));
      } catch { uncertain = true; throw new Error('acceptance/firestore-retained-or-delete-unknown'); }
    },
  });
}

function fakeStore() {
  const documents = new Map();
  const events = [];
  return {
    documents, events,
    async read(paths) { return paths.map((path) => copy(documents.get(path) ?? null)); },
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
          return copy(documents.get(path) ?? null);
        },
        delete(path) { deleting = true; events.push(['delete', path]); pending.push(path); },
      });
      for (const path of pending) documents.delete(path);
    },
  };
}

function specimen() {
  const store = fakeStore();
  const context = { runId: RUN, actorId: `acceptance-${RUN}-administrator`, clock: () => 1000 };
  const manifest = createManifest(context, store);
  return { store, manifest, context };
}

function creation(manifest, id = 'PRD-0123456789ABCDEF') {
  const request = manifest.request('create');
  const result = { productId: id, internalCode: id, replayed: false };
  const product = { internalCode: id, name: request.name, quantitySpec: request.quantitySpec, createdAt: 1000 };
  const receipt = {
    fingerprint: JSON.stringify({ actorId: `acceptance-${RUN}-administrator`, name: request.name,
      quantitySpec: request.quantitySpec }),
    result: { productId: id, internalCode: id }, completedAt: 1000,
    actorId: `acceptance-${RUN}-administrator`,
  };
  return { result, product, receipt };
}

async function ownProduct(sample) {
  await sample.manifest.seedBranches();
  const proof = creation(sample.manifest);
  await sample.manifest.execute('create', async () => {
    sample.store.documents.set(`products/${proof.result.productId}`, copy(proof.product));
    sample.store.documents.set(sample.manifest.paths().createReceipt, copy(proof.receipt));
    return proof.result;
  });
  return proof;
}

test('offline: gates pin executable, exact version, hosts and ambient routing', () => {
  assert.doesNotThrow(() => gate(PINNED, { executable: NODE, version: 'v24.21.0' }));
  for (const key of Object.keys(PINNED)) {
    assert.throws(() => gate({ ...PINNED, [key]: 'wrong' }, { executable: NODE, version: 'v24.21.0' }), /acceptance\/target-pin/);
  }
  for (const key of ['GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_CONFIG', 'HTTPS_PROXY', 'NODE_OPTIONS']) {
    assert.throws(() => gate({ ...PINNED, [key]: 'override' }, { executable: NODE, version: 'v24.21.0' }), /acceptance\/ambient-override/);
  }
  assert.throws(() => gate(PINNED, { executable: NODE, version: 'v24.20.0' }), /acceptance\/node-pin/);
  assert.throws(() => gate(PINNED, { executable: '/usr/bin/node', version: 'v24.21.0' }), /acceptance\/node-pin/);
});

test('offline: copied plans and context cannot poison private authority', async () => {
  const sample = specimen();
  const input = sample.manifest.request('create');
  input.name = 'foreign';
  input.quantitySpec.precision = 6;
  sample.context.runId = randomUUID();
  sample.context.actorId = 'foreign';
  sample.context.clock = () => 999999;
  const view = sample.manifest.view();
  view.entries.length = 0;
  await ownProduct(sample);
  await sample.manifest.cleanup();
  assert.equal(sample.store.documents.size, 0);
});

test('offline: exact receipt and schema required, never actor/name-only adoption', async () => {
  for (const mutate of [
    (proof) => { proof.receipt.fingerprint = 'forged'; },
    (proof) => { proof.product.foreign = true; },
    (proof) => { proof.product.createdAt = -999999; },
    (proof) => { proof.receipt.actorId = 'foreign'; },
    (proof) => { proof.result.productId = 'DEMO-COFFEE'; },
  ]) {
    const sample = specimen();
    await sample.manifest.seedBranches();
    const proof = creation(sample.manifest);
    mutate(proof);
    await assert.rejects(sample.manifest.execute('create', async () => {
      sample.store.documents.set(`products/${proof.result.productId}`, proof.product);
      sample.store.documents.set(sample.manifest.paths().createReceipt, proof.receipt);
      return proof.result;
    }), UNCERTAIN);
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
  }
});

test('offline: mismatch retains the entire unit after reading every exact document', async () => {
  const sample = specimen();
  await ownProduct(sample);
  const paths = sample.manifest.view().entries.map((entry) => entry.path);
  sample.store.documents.get(paths[0]).foreign = true;
  sample.store.events.length = 0;
  await assert.rejects(sample.manifest.cleanup());
  assert.deepEqual(sample.store.events.filter(([event]) => event === 'read').map(([, path]) => path), paths);
  assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
});

test('offline: registered teardown attempts every stage despite exceptions', async () => {
  const events = [];
  await assert.rejects(teardown([
    async () => { events.push('firestore'); throw new Error('private raw error'); },
    async () => { events.push('auth'); throw new Error('private raw error'); },
    async () => { events.push('dispose'); },
  ]));
  assert.deepEqual(events, ['firestore', 'auth', 'dispose']);
});

test('offline: preexisting planned paths and partial seed failure never authorize deletion', async () => {
  for (const mode of ['collision', 'partial']) {
    const store = fakeStore();
    if (mode === 'collision') store.documents.set(`branches/branch-${RUN}`, { foreign: true });
    else {
      const create = store.create.bind(store);
      store.create = async (path, data) => {
        await create(path, data);
        if (path.endsWith('-other')) throw new Error('lost response');
      };
    }
    const manifest = createManifest({ runId: RUN, actorId: `acceptance-${RUN}-administrator` }, store);
    await assert.rejects(manifest.seedBranches());
    await assert.rejects(manifest.cleanup());
    assert.equal(store.events.some(([event]) => event === 'delete'), false);
  }
  assert.throws(() => createManifest({ runId: RUN, actorId: 'foreign' }, fakeStore()));
});

test('offline: deadline does not cancel or adopt a late product write', async () => {
  const sample = specimen();
  await sample.manifest.seedBranches();
  let finish;
  const pending = new Promise((resolve) => { finish = resolve; });
  await assert.rejects(sample.manifest.execute('create', () => pending, 2), UNCERTAIN);
  const proof = creation(sample.manifest);
  sample.store.documents.set(`products/${proof.result.productId}`, proof.product);
  sample.store.documents.set(sample.manifest.paths().createReceipt, proof.receipt);
  finish(proof.result);
  await Promise.resolve();
  assert.equal(sample.manifest.view().productId, null);
  await assert.rejects(sample.manifest.execute('create', () => proof.result), ORDER);
  await assert.rejects(sample.manifest.cleanup(), RETAINED);
  assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
});

test('offline: immutable projections, exact absent slots and deletion order', async () => {
  const sample = specimen();
  const proof = await ownProduct(sample);
  const view = sample.manifest.view();
  view.entries.find((entry) => entry.path.startsWith('products/')).expected.name = 'poison';
  view.productId = 'DEMO-COFFEE';
  const request = sample.manifest.request('price');
  request.productId = 'DEMO-COFFEE';
  await assert.rejects(sample.manifest.execute('create', () => proof.result), ORDER);
  await sample.manifest.cleanup();
  const deletes = sample.store.events.filter(([event]) => event === 'delete').map(([, path]) => path);
  assert.deepEqual(deletes.slice(-3), [`products/${proof.result.productId}`, ...sample.manifest.paths().branches]);
  await assert.rejects(sample.manifest.cleanup(), /acceptance\/cleanup-not-retryable/);
});

test('offline: forged cost/stock slots, response additions and missing proof fail closed', async () => {
  for (const mode of ['cost', 'stock', 'response', 'receipt']) {
    const sample = specimen();
    await sample.manifest.seedBranches();
    const proof = creation(sample.manifest);
    await assert.rejects(sample.manifest.execute('create', async () => {
      sample.store.documents.set(`products/${proof.result.productId}`, proof.product);
      if (mode !== 'receipt') sample.store.documents.set(sample.manifest.paths().createReceipt, proof.receipt);
      if (mode === 'cost') sample.store.documents.set(`costs/${proof.result.productId}`, { foreign: true });
      if (mode === 'stock') sample.store.documents.set(`branches/branch-${RUN}/stock/${proof.result.productId}`, { foreign: true });
      if (mode === 'response') proof.result.unknown = true;
      return proof.result;
    }), UNCERTAIN);
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
  }
});

test('offline: deletion commit uncertainty stays failed and cannot be blindly retried', async () => {
  const store = fakeStore();
  const transact = store.transaction.bind(store);
  store.transaction = async (callback) => { await transact(callback); throw new Error('commit response lost'); };
  const manifest = createManifest({ runId: RUN, actorId: `acceptance-${RUN}-administrator`, clock: () => 1000 }, store);
  await manifest.seedBranches();
  await assert.rejects(manifest.cleanup());
  assert.equal(manifest.view().uncertain, true);
  assert.equal(store.documents.size, 0, 'fake commit completed despite lost response');
  await assert.rejects(manifest.cleanup());
});

test('offline: replay or denied response cannot self-bless a late mutation', async () => {
  const sample = specimen();
  await ownProduct(sample);
  await sample.manifest.unchanged(async () => ({ replayed: true }));
  await assert.rejects(sample.manifest.unchanged(async () => {
    sample.store.documents.get(sample.manifest.paths().createReceipt).completedAt += 1;
    return { replayed: true };
  }));
  await assert.rejects(sample.manifest.cleanup());
  assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
});

test('offline: cleanup of missing anchors reads everything and retains all remaining documents', async () => {
  const sample = specimen();
  await ownProduct(sample);
  sample.store.documents.delete(sample.manifest.paths().branches[0]);
  await assert.rejects(sample.manifest.cleanup());
  assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
});

test('offline: live approval is mandatory even with correct target pins', () => {
  const runtime = { executable: NODE, version: 'v24.21.0' };
  const approved = { ...PINNED, LDA_SALES_HTTP_ACCEPTANCE: '1',
    LDA_SALES_FIXTURE_BASELINE_APPROVAL: 'demo-seed-eight-documents-two-identities',
    LDA_SALES_RUNTIME_REVALIDATED: 'explicit-local-source-project-routes-reviewed' };
  // Positive gate case uses an injected runtime; it never opens SDKs or HTTP.
  assert.doesNotThrow(() => liveApproval(approved, runtime));
  const required = /acceptance\/live-approval-required/;
  assert.throws(() => liveApproval({ ...approved, LDA_SALES_HTTP_ACCEPTANCE: '0' }, runtime), required);
  for (const key of ['LDA_SALES_FIXTURE_BASELINE_APPROVAL', 'LDA_SALES_RUNTIME_REVALIDATED']) {
    assert.throws(() => liveApproval({ ...approved, [key]: undefined }, runtime), required);
  }
  assert.throws(() => liveApproval(approved, { ...runtime, version: 'v24.20.0' }), /acceptance\/node-pin/);
  assert.throws(() => liveApproval({ ...approved, HTTPS_PROXY: 'x' }, runtime), /acceptance\/ambient-override/);
  assert.throws(() => normalizeRecord({ toMillis: () => 1000, nanoseconds: 1 }), TIMESTAMP);
  assert.throws(() => normalizeRecord({ createdAt: 1000 }), TIMESTAMP);
  assert.equal(normalizeRecord({ seconds: 1, nanoseconds: 0, toMillis: () => 1000 }), 1000);
});

test('offline: independent price and intake projections reject forged business totals', async () => {
  for (const forged of [false, true]) {
    const sample = specimen();
    const creationProof = await ownProduct(sample);
    const id = creationProof.result.productId;
    const actorId = `acceptance-${RUN}-administrator`;
    const paths = sample.manifest.paths();
    const price = sample.manifest.request('price');
    const pricing = { listedPriceCentavos: 1234, currency: 'MXN', priceMode: 'iva-included',
      ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 };
    const priceResult = { auditId: price.idempotencyKey, productId: id, pricing };
    const priceOutcome = await sample.manifest.execute('price', async () => {
      Object.assign(sample.store.documents.get(`products/${id}`), {
        pricing, pricingUpdatedAt: 1000, lastPricingAuditId: price.idempotencyKey });
      sample.store.documents.set(paths.priceAudit, { productId: id, previousAuditId: null, oldPricing: null,
        newPricing: pricing, changedAt: 1000, actorId });
      sample.store.documents.set(paths.priceReceipt, { actorId, completedAt: 1000, result: priceResult,
        fingerprint: JSON.stringify({ actorId, productId: id, pricing }) });
      return { ...priceResult, replayed: false };
    });
    priceOutcome.pricing.listedPriceCentavos = 9999; // Returned aliases cannot advance private projections.
    const intake = sample.manifest.request('intake');
    const result = { entryId: intake.idempotencyKey, movementId: intake.idempotencyKey,
      quantityScaled: 250, stockQuantityScaled: 250, unitCostCentavos: 321, lineTotalCentavos: forged ? 803 : 802 };
    const invoke = () => sample.manifest.execute('intake', async () => {
      sample.store.documents.set(paths.entry, { branchId: intake.branchId, productId: id, quantityScaled: 250,
        unit: 'kg', precision: 2, unitCostCentavos: 321, lineTotalCentavos: result.lineTotalCentavos,
        currency: 'MXN', calculationPolicyVersion: 'mxn-unit-cost-truncate-v1', createdAt: 1000, createdBy: actorId });
      sample.store.documents.set(paths.movement, { type: 'stock-intake', branchId: intake.branchId, productId: id,
        quantityScaled: 250, unit: 'kg', precision: 2, entryId: intake.idempotencyKey, occurredAt: 1000, actorId });
      sample.store.documents.set(`branches/${intake.branchId}/stock/${id}`, { quantityScaled: 250, unit: 'kg',
        precision: 2, updatedAt: 1000, lastMovementId: intake.idempotencyKey });
      sample.store.documents.set(`costs/${id}`, { latestUnitCostCentavos: 321, currency: 'MXN',
        sourceEntryId: intake.idempotencyKey, updatedAt: 1000 });
      sample.store.documents.set(paths.intakeReceipt, { actorId, completedAt: 1000, result,
        fingerprint: JSON.stringify({ branchId: intake.branchId, productId: id, quantity: '2.50', unitCostCentavos: 321 }) });
      return { ...result, replayed: false };
    });
    if (forged) { await assert.rejects(invoke(), UNCERTAIN); await assert.rejects(sample.manifest.cleanup(), RETAINED); }
    else { await invoke(); await sample.manifest.cleanup(); assert.equal(sample.store.documents.size, 0); }
  }
});

test('offline: fake HTTP enforces exact URLs, redirects and response/request bounds', async () => {
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
  const http = makeHttp(PINNED, [], fakeRequest, () => {});
  await assert.rejects(http('http://example.invalid'));
  await assert.rejects(http(LOGIN, 'POST', { text: 'x'.repeat(16385) }));
  assert.equal(calls, 0);
  assert.equal((await http(LOGIN, 'POST', {})).status, 200);
  for (mode of ['redirect', 'large']) await assert.rejects(http(LOGIN, 'POST', {}));
  mode = 'valid';
  assert.equal((await http(`${BASE}/quoteSale`, 'POST', { data: {} })).status, 200);
  // Correction callables belong to their own harness and are refused here.
  await assert.rejects(http(`${BASE}/findCorrectableSale`, 'POST', { data: {} }), /acceptance\/url-refused/);
  await assert.rejects(makeHttp(PINNED, [], fakeRequest)(LOGIN));
});

const ADMIN = `acceptance-${RUN}-administrator`;
const SELLER = `acceptance-${RUN}-seller`;
const OWN = `branch-${RUN}`;
const POLICY = { version: 1, rounding: 'half-up', roundingScope: 'per-line',
  additionalIvaBase: 'rounded-line-base', includedIvaExtraction: 'not-calculated' };
const taxable = (cents, priceMode) => ({ listedPriceCentavos: cents, currency: 'MXN', priceMode,
  ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 });

// Fake server writes use literal business values, never the manifest's projection code.
async function fakePrice(sample, kind, pricing) {
  const input = sample.manifest.request(kind);
  const id = input.productId;
  const result = { auditId: input.idempotencyKey, productId: id, pricing };
  return sample.manifest.execute(kind, async () => {
    const product = sample.store.documents.get(`products/${id}`);
    sample.store.documents.set(`productPriceAudits/${input.idempotencyKey}`, { productId: id,
      previousAuditId: product.lastPricingAuditId ?? null, oldPricing: product.pricing ?? null,
      newPricing: pricing, changedAt: 1000, actorId: ADMIN });
    Object.assign(product, { pricing, pricingUpdatedAt: 1000, lastPricingAuditId: input.idempotencyKey });
    sample.store.documents.set(`productPriceUpdateReceipts/${input.idempotencyKey}`, { actorId: ADMIN,
      completedAt: 1000, result, fingerprint: JSON.stringify({ actorId: ADMIN, productId: id, pricing }) });
    return { ...result, replayed: false };
  });
}

async function fakeIntake(sample) {
  const input = sample.manifest.request('intake');
  const id = input.productId;
  const key = input.idempotencyKey;
  const result = { entryId: key, movementId: key, quantityScaled: 250, stockQuantityScaled: 250,
    unitCostCentavos: 321, lineTotalCentavos: 802 };
  return sample.manifest.execute('intake', async () => {
    sample.store.documents.set(`stockIntakeEntries/${key}`, { branchId: OWN, productId: id, quantityScaled: 250,
      unit: 'kg', precision: 2, unitCostCentavos: 321, lineTotalCentavos: 802, currency: 'MXN',
      calculationPolicyVersion: 'mxn-unit-cost-truncate-v1', createdAt: 1000, createdBy: ADMIN });
    sample.store.documents.set(`inventoryMovements/${key}`, { type: 'stock-intake', branchId: OWN, productId: id,
      quantityScaled: 250, unit: 'kg', precision: 2, entryId: key, occurredAt: 1000, actorId: ADMIN });
    sample.store.documents.set(`branches/${OWN}/stock/${id}`, { quantityScaled: 250, unit: 'kg', precision: 2,
      updatedAt: 1000, lastMovementId: key });
    sample.store.documents.set(`costs/${id}`, { latestUnitCostCentavos: 321, currency: 'MXN',
      sourceEntryId: key, updatedAt: 1000 });
    sample.store.documents.set(`stockIntakeReceipts/${key}`, { actorId: ADMIN, completedAt: 1000, result,
      fingerprint: JSON.stringify({ branchId: OWN, productId: id, quantity: '2.50', unitCostCentavos: 321 }) });
    return { ...result, replayed: false };
  });
}

// Mirrors the sales.js write set: sale, audit, movement, stock and replay receipt.
async function fakeSale(sample, kind, { scaled, base, iva, stock, pricing }, forge = () => {}) {
  const input = sample.manifest.request(kind);
  const key = input.idempotencyKey;
  const id = input.lines[0].productId;
  const movementId = `sale-${key}-0`;
  const line = { quantity: { version: 1, spec: { unit: 'kg', precision: 2 }, scaled, decimal: input.lines[0].quantity },
    pricing: { version: 1, ...pricing }, baseCentavos: base, additionalIvaCentavos: iva,
    includedIvaCentavos: null, totalCentavos: base + iva };
  const receipt = { version: 2, saleId: key, branchId: OWN, branchCode: 'HTS',
    folio: `HTS-HTTP-${RUN.slice(0, 4)}`, productIds: [id], payment: input.payment,
    calculation: { version: 1, currency: 'MXN', invoiceRequested: input.invoiceRequested, calculationPolicy: POLICY,
      lines: [line], baseCentavos: base, additionalIvaCentavos: iva, totalCentavos: base + iva } };
  const docs = new Map([
    [`sales/${key}`, { receipt: copy(receipt), createdAt: 1000 }],
    [`saleAudits/${key}`, { saleId: key, branchId: OWN, actorId: SELLER, createdAt: 1000 }],
    [`inventoryMovements/${movementId}`, { type: 'sale', saleId: key, branchId: OWN, productId: id,
      quantityScaled: -scaled, unit: 'kg', precision: 2, actorId: SELLER, occurredAt: 1000 }],
    [`branches/${OWN}/stock/${id}`, { quantityScaled: stock, unit: 'kg', precision: 2, updatedAt: 1000,
      lastMovementId: movementId }],
    [`saleSubmissionReceipts/${key}`, { actorId: SELLER, branchId: OWN, result: copy(receipt), completedAt: 1000,
      fingerprint: JSON.stringify({ actorId: SELLER, branchId: OWN, ...input }) }],
  ]);
  const response = { receipt: copy(receipt), replayed: false, createdAt: 1000 };
  forge(docs, response, key);
  return sample.manifest.execute(kind, async () => {
    for (const [path, value] of docs) sample.store.documents.set(path, copy(value));
    return response;
  });
}

const FIRST_SALE = { scaled: 100, base: 1234, iva: 0, stock: 150, pricing: taxable(1234, 'iva-included') };
async function stockedProduct(sample) {
  const proof = await ownProduct(sample);
  await fakePrice(sample, 'price', taxable(1234, 'iva-included'));
  await fakeIntake(sample);
  return proof;
}

test('offline: seller sale, replay and repricing follow independent sales projections', async () => {
  const sample = specimen();
  await stockedProduct(sample);
  assert.deepEqual(sample.manifest.request('sale').payment, { method: 'cash', amountCentavos: 1234 });
  const first = await fakeSale(sample, 'sale', FIRST_SALE);
  assert.equal(first.receipt.calculation.totalCentavos, 1234);
  const replay = sample.manifest.receipt('sale');
  assert.deepEqual(replay, first.receipt);
  replay.payment.amountCentavos = 1; // Copies cannot poison the private projection.
  first.receipt.saleId = 'foreign';
  // The replay response carries the original stored sale time, not a new one.
  assert.deepEqual(sample.manifest.saleReplay('sale'),
    { receipt: sample.manifest.receipt('sale'), replayed: true, createdAt: 1000 });
  await sample.manifest.unchanged(async () => sample.manifest.saleReplay('sale'));
  await fakePrice(sample, 'reprice', taxable(1500, 'iva-additional-on-invoice'));
  const repriced = sample.store.documents.get(`productPriceAudits/${sample.manifest.request('reprice').idempotencyKey}`);
  assert.equal(repriced.previousAuditId, sample.manifest.request('price').idempotencyKey);
  // 0.50 kg at 15.00 MXN: base 750, half-up additional IVA 120.5 -> 120 on invoice.
  const second = await fakeSale(sample, 'resale', { scaled: 50, base: 750, iva: 120, stock: 100,
    pricing: taxable(1500, 'iva-additional-on-invoice') });
  assert.equal(second.receipt.calculation.totalCentavos, 870);
  // A replay after repricing keeps the original immutable snapshot.
  assert.equal(sample.manifest.receipt('sale').calculation.totalCentavos, 1234);
  await sample.manifest.unchanged(async () => sample.manifest.saleReplay('sale'));
  await sample.manifest.cleanup();
  assert.equal(sample.store.documents.size, 0);
});

test('offline: forged sale artifacts and foreign actors are retained, never adopted', async () => {
  const receiptOf = (docs, key) => docs.get(`saleSubmissionReceipts/${key}`);
  for (const forge of [
    (docs, _response, key) => { receiptOf(docs, key).actorId = `acceptance-${RUN}-seller-foreign`; },
    (docs, _response, key) => { receiptOf(docs, key).fingerprint = 'forged'; },
    (docs, _response, key) => { docs.get(`saleAudits/${key}`).actorId = ADMIN; },
    (docs, _response, key) => { docs.get(`saleAudits/${key}`).createdAt = 999999999; },
    (docs, _response, key) => { docs.get(`inventoryMovements/sale-${key}-0`).quantityScaled = -99; },
    (docs) => { docs.get(`branches/${OWN}/stock/PRD-0123456789ABCDEF`).quantityScaled = 250; },
    (docs, _response, key) => { docs.get(`sales/${key}`).receipt.payment.amountCentavos = 1; },
    (_docs, response) => { response.receipt.calculation.totalCentavos = 1; },
    (docs, _response, key) => { docs.set(`inventoryMovements/sale-${key}-1`, { saleId: key }); },
    (docs) => { docs.set(`sales/http-${RUN}-sale-insufficient`, { receipt: null, createdAt: 1000 }); },
  ]) {
    const sample = specimen();
    await stockedProduct(sample);
    await assert.rejects(fakeSale(sample, 'sale', FIRST_SALE, forge), UNCERTAIN);
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
  }
});

test('offline: denial payments follow the priced product and denials match the exact rule', () => {
  const { manifest } = specimen();
  const total = (quantities) => denialPayment(manifest, quantities).amountCentavos;
  assert.equal(total(['9.00']), 11106);
  assert.equal(total(['1.00', '1.00']), 2468);
  assert.equal(total(['0.00']), 0);
  assert.equal(total(['0.33']), 407); // 407.22 rounds half-up per line, never fractional centavos.
  assert.equal(total(['0.45']), 555); // 555.30 rounds half-up per line.
  const denied = (message) => ({ status: 400, body: { error: { status: 'INVALID_ARGUMENT', message } } });
  assert.doesNotThrow(() => callableDenied(denied(SALE_DENIAL.fields), 'INVALID_ARGUMENT', SALE_DENIAL.fields));
  assert.throws(() => callableDenied(denied(SALE_DENIAL.payment), 'INVALID_ARGUMENT', SALE_DENIAL.fields),
    /acceptance\/callable-denial/);
  assert.doesNotThrow(() => callableDenied(denied(SALE_DENIAL.payment), 'INVALID_ARGUMENT'));
});

test('offline: denials require exact error fields and only the expected structured reason', () => {
  const denied = (error) => ({ status: 400, body: { error } });
  const payment = { status: 'INVALID_ARGUMENT', message: SALE_DENIAL.payment };
  const reasoned = { ...payment, details: { reason: 'payment-mismatch' } };
  assert.doesNotThrow(() => callableDenied(denied(reasoned), 'INVALID_ARGUMENT', SALE_DENIAL.payment, 'payment-mismatch'));
  assert.doesNotThrow(() => callableDenied(denied({ status: 'FAILED_PRECONDITION', message: SALE_DENIAL.stock,
    details: { reason: 'insufficient-stock' } }), 'FAILED_PRECONDITION', SALE_DENIAL.stock, 'insufficient-stock'));
  for (const [error, reason] of [
    [payment, 'payment-mismatch'], // The reason is missing from the HTTP body.
    [reasoned, undefined], // A reason the rule does not publish.
    [reasoned, 'insufficient-stock'],
    [{ ...payment, details: { reason: 'payment-mismatch', extra: true } }, 'payment-mismatch'],
    [{ ...payment, details: 'payment-mismatch' }, 'payment-mismatch'],
    [{ ...payment, details: null }, undefined],
    [{ ...payment, stack: 'private' }, undefined],
  ]) {
    assert.throws(() => callableDenied(denied(error), 'INVALID_ARGUMENT', SALE_DENIAL.payment, reason),
      /acceptance\/callable-denial/);
  }
});

test('offline: quote projections follow private pricing and stock and equal the later charge', async () => {
  const sample = specimen();
  await ownProduct(sample);
  assert.throws(() => sample.manifest.quote('sale'), ORDER);
  await fakePrice(sample, 'price', taxable(1234, 'iva-included'));
  assert.throws(() => sample.manifest.quote('sale'), ORDER);
  await fakeIntake(sample);
  assert.throws(() => sample.manifest.quote('reprice'), ORDER);
  const id = sample.manifest.view().productId;
  const quoted = sample.manifest.quote('sale');
  // The request is exactly the cart: no key, payment or branch.
  assert.deepEqual(quoted.request, { invoiceRequested: false, lines: [{ productId: id, quantity: '1.00' }] });
  assert.deepEqual(Object.keys(quoted.expected).sort(), ['calculation', 'lines', 'totalCentavos']);
  assert.deepEqual(quoted.expected.lines, [{ productId: id, available: true }]);
  assert.equal(quoted.expected.totalCentavos, 1234);
  assert.equal(quoted.expected.totalCentavos, sample.manifest.request('sale').payment.amountCentavos);
  assert.equal(/cost/i.test(JSON.stringify(quoted)), false, 'no cost field reaches the quote');
  // 9.00 kg exceeds the 2.50 kg stocked: reported per line, priced all the same.
  const short = sample.manifest.quote('sale', '9.00');
  assert.deepEqual(short.expected.lines, [{ productId: id, available: false }]);
  assert.equal(short.expected.totalCentavos, 11106);
  assert.equal(sample.manifest.quote('sale', '2.50').expected.lines[0].available, true);
  quoted.expected.calculation.totalCentavos = 1; // Copies cannot poison the private projection.
  quoted.request.lines[0].quantity = '9.00';
  const first = await fakeSale(sample, 'sale', FIRST_SALE);
  assert.deepEqual(first.receipt.calculation, sample.manifest.quote('sale').expected.calculation);
  assert.equal(sample.manifest.quote('sale', '1.50').expected.lines[0].available, true);
  assert.equal(sample.manifest.quote('sale', '1.51').expected.lines[0].available, false);
  await fakePrice(sample, 'reprice', taxable(1500, 'iva-additional-on-invoice'));
  const repriced = sample.manifest.quote('resale');
  assert.equal(repriced.expected.totalCentavos, 870);
  assert.equal(repriced.expected.calculation.additionalIvaCentavos, 120);
  const second = await fakeSale(sample, 'resale', { scaled: 50, base: 750, iva: 120, stock: 100,
    pricing: taxable(1500, 'iva-additional-on-invoice') });
  assert.deepEqual(second.receipt.calculation, repriced.expected.calculation);
  assert.throws(() => sample.manifest.quote('create'), ORDER);
  await sample.manifest.cleanup();
  assert.equal(sample.store.documents.size, 0);
});

test('offline: forged v2 receipt identity, folio and sale time are retained, never adopted', async () => {
  const key = `http-${RUN}-sale`;
  // The genuine folio is the seeded code plus the first eight alphanumerics of the key: HTS-HTTP-1234.
  // Pin that baseline first, so every forgery below is a near miss of exactly this folio.
  const genuine = specimen();
  await stockedProduct(genuine);
  const accepted = await fakeSale(genuine, 'sale', FIRST_SALE);
  assert.equal(accepted.receipt.saleId, key);
  assert.equal(accepted.receipt.branchCode, 'HTS');
  assert.equal(accepted.receipt.folio, 'HTS-HTTP-1234');
  await genuine.manifest.cleanup();
  assert.equal(genuine.store.documents.size, 0);
  for (const forge of [
    (_docs, response) => { response.receipt.folio = 'HTS-HTTP-1235'; },
    (_docs, response) => { response.receipt.folio = 'hts-http-1234'; },
    (_docs, response) => { response.receipt.branchCode = 'HTO'; },
    (_docs, response) => { response.receipt.version = 1; },
    (_docs, response) => { delete response.receipt.folio; delete response.receipt.branchCode; },
    (_docs, response) => { delete response.createdAt; },
    (_docs, response) => { response.createdAt = 1001; },
    (_docs, response) => { response.createdAt = new Date(1000).toISOString(); },
    (docs) => { docs.get(`sales/${key}`).receipt.folio = 'HTO-HTTP-1234'; },
    (docs) => { docs.get(`saleSubmissionReceipts/${key}`).result.branchCode = 'HTO'; },
  ]) {
    const sample = specimen();
    await stockedProduct(sample);
    await assert.rejects(fakeSale(sample, 'sale', FIRST_SALE, forge), UNCERTAIN);
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
  }
});

test('offline: live SDK credential is a local certificate and initialization errors stay diagnosable', () => {
  const calls = [];
  const credential = ownedCredential((options) => { calls.push(options); return { kind: 'cert' }; },
    (type, options) => { calls.push({ type, modulusLength: options.modulusLength }); return { privateKey: 'PEM' }; });
  assert.deepEqual(credential, { kind: 'cert' });
  assert.deepEqual(calls, [{ type: 'rsa', modulusLength: 2048 },
    { projectId: PROJECT, clientEmail: `acceptance-local@${PROJECT}.iam.gserviceaccount.com`, privateKey: 'PEM' }]);
  const wrapped = initializationError(Object.assign(new Error('secret detail'), { code: 'firestore/invalid-credential' }));
  assert.equal(wrapped.message, 'acceptance/runtime-initialization');
  assert.equal(wrapped.code, 'firestore/invalid-credential');
  assert.equal(initializationError(new Error('acceptance/project')).code, 'acceptance/project');
  assert.equal(initializationError('opaque').code, 'acceptance/unknown');
  assert.equal(initializationError(Object.assign(new Error('x'), { code: 42 })).code, 'acceptance/unknown');
});

test('offline: seller sale movement view exposes only the seller actorId and no cost', () => {
  const scope = { saleKey: 'http-key-sale', actorId: SELLER, branchId: OWN };
  const document = (fields) => ({ status: 200, body: { name: `projects/${PROJECT}/databases/(default)/documents/`
    + `inventoryMovements/sale-${scope.saleKey}-0`, fields, createTime: 'x', updateTime: 'x' } });
  const fields = {
    type: { stringValue: 'sale' }, saleId: { stringValue: scope.saleKey }, branchId: { stringValue: OWN },
    productId: { stringValue: 'PRD-0123456789ABCDEF' }, quantityScaled: { integerValue: '-100' },
    unit: { stringValue: 'kg' }, precision: { integerValue: '2' }, actorId: { stringValue: SELLER },
    occurredAt: { timestampValue: '2026-10-07T00:00:00Z' },
  };
  assert.doesNotThrow(() => sellerMovementView(document(fields), scope));
  for (const forged of [
    { ...fields, unitCostCentavos: { integerValue: '321' } },
    { ...fields, actorId: { stringValue: ADMIN } },
    { ...fields, saleId: { stringValue: 'other' } },
    { ...fields, branchId: { stringValue: `${OWN}-other` } },
    { ...fields, type: { stringValue: 'intake' } },
  ]) assert.throws(() => sellerMovementView(document(forged), scope), /acceptance\/seller-movement-view/);
  assert.throws(() => sellerMovementView({ status: 403, body: {} }, scope), /acceptance\/seller-movement-view/);
  assert.throws(() => sellerMovementView({ ...document(fields), body: { ...document(fields).body, name: 'x' } }, scope),
    /acceptance\/seller-movement-view/);
});

test('offline: ledger requires stock, movements, audits and receipts to agree', async () => {
  const sample = specimen();
  const { result } = await stockedProduct(sample);
  await fakeSale(sample, 'sale', FIRST_SALE);
  const key = sample.manifest.request('sale').idempotencyKey;
  const scope = { branch: OWN, other: `${OWN}-other`, productId: result.productId,
    intake: `inventoryMovements/${sample.manifest.request('intake').idempotencyKey}`, sales: [key] };
  const snapshot = () => new Map([...sample.store.documents].map(([path, value]) => [path, copy(value)]));
  assert.doesNotThrow(() => ledger(snapshot(), scope));
  for (const mutate of [
    (records) => { records.get(`branches/${OWN}/stock/${result.productId}`).quantityScaled = 149; },
    (records) => { records.get(`branches/${OWN}/stock/${result.productId}`).lastMovementId = scope.intake.slice(19); },
    (records) => { records.get(`inventoryMovements/sale-${key}-0`).occurredAt = 1001; },
    (records) => { records.get(`saleAudits/${key}`).actorId = ADMIN; },
    (records) => { records.get(`sales/${key}`).receipt.payment.amountCentavos = 1; },
    (records) => { records.set(`branches/${OWN}-other/stock/${result.productId}`, { quantityScaled: 0 }); },
    (records) => { records.delete(`saleSubmissionReceipts/${key}`); },
    (records) => { records.delete(`inventoryMovements/sale-${key}-0`); },
  ]) {
    const records = snapshot();
    mutate(records);
    assert.throws(() => ledger(records, scope), /acceptance\/ledger-inconsistent/);
  }
});

test('offline: sale order, denial slots and late denied artifacts fail closed', async () => {
  const sample = specimen();
  await ownProduct(sample);
  await assert.rejects(fakeSale(sample, 'sale', FIRST_SALE), ORDER);
  const key = sample.manifest.denialKey('sale-insufficient');
  const planned = sample.manifest.view().entries.map((entry) => entry.path);
  for (const path of [`sales/${key}`, `saleAudits/${key}`, `saleSubmissionReceipts/${key}`,
    `inventoryMovements/sale-${key}-0`, `inventoryMovements/sale-${key}-1`]) assert.ok(planned.includes(path), path);
  assert.throws(() => sample.manifest.denialKey('sale-foreign'), /acceptance\/denial-plan/);
  await fakePrice(sample, 'price', taxable(1234, 'iva-included'));
  await fakeIntake(sample);
  await assert.rejects(fakePrice(sample, 'reprice', taxable(1500, 'iva-included')), ORDER);
  assert.throws(() => sample.manifest.receipt('sale'), ORDER);
  await assert.rejects(sample.manifest.unchanged(async () => {
    sample.store.documents.set(`saleAudits/${key}`, { saleId: key, branchId: OWN, actorId: SELLER, createdAt: 1000 });
  }), /acceptance\/observation-uncertain/);
  await assert.rejects(sample.manifest.cleanup(), RETAINED);
  assert.equal(sample.store.events.some(([event]) => event === 'delete'), false);
});

test('offline: Timestamps keep sub-millisecond precision without weakening type checks', () => {
  const stamp = (seconds, nanoseconds) => ({ seconds, nanoseconds,
    toMillis: () => seconds * 1000 + Math.floor(nanoseconds / 1e6) });
  assert.equal(normalizeRecord(stamp(1, 123456789)), 1123);
  assert.deepEqual(normalizeRecord({ completedAt: stamp(1, 999) }), { completedAt: 1000 });
  for (const forged of [stamp(1, 1.5), stamp(1, -1), stamp(1, 1e9), stamp(2 ** 53, 0), stamp('1', 0),
    { ...stamp(1, 0), toMillis: () => 2000 }, { nanoseconds: 0, toMillis: () => 1000 }]) {
    assert.throws(() => normalizeRecord(forged), TIMESTAMP);
  }
});

// Exact source-derived demo preservation proposal, NOT evidence of current contents.
const BASELINE_AUTH = ['demo-local-administrator', 'demo-local-seller-north'];
const BASELINE_DOCS = [
  'branches/branch-north', 'branches/branch-south', 'products/DEMO-COFFEE', 'products/DEMO-RIBBON',
  'branches/branch-north/stock/DEMO-COFFEE', 'branches/branch-north/stock/DEMO-RIBBON',
  'branches/branch-south/stock/DEMO-COFFEE', 'branches/branch-south/stock/DEMO-RIBBON',
];

function liveApproval(environment, runtime) {
  gate(environment, runtime); // undefined keeps the actual process runtime.
  if (environment.LDA_SALES_HTTP_ACCEPTANCE !== '1'
    || environment.LDA_SALES_FIXTURE_BASELINE_APPROVAL !== 'demo-seed-eight-documents-two-identities'
    || environment.LDA_SALES_RUNTIME_REVALIDATED !== 'explicit-local-source-project-routes-reviewed') {
    throw new Error('acceptance/live-approval-required');
  }
}

// URL authority is local and exact; no external host, redirects or caller options.
function makeHttp(environment, documentPaths, transport = httpRequest, approve = liveApproval) {
  const allowed = new Set([LOGIN, ...FUNCTIONS.map((name) => `${BASE}/${name}`)]);
  for (const path of documentPaths) {
    allowed.add(`${REST}/${path.split('/').map(encodeURIComponent).join('/')}`);
  }
  for (const branch of documentPaths.filter((path) => /^branches\/[^/]+$/.test(path))) {
    allowed.add(`${REST}/${branch}:runQuery`);
  }
  return async (url, method = 'GET', body, token) => {
    approve(environment);
    approve(process.env);
    if (!allowed.has(url) || !['GET', 'POST', 'PATCH'].includes(method)) throw new Error('acceptance/url-refused');
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
      if (['createdAt', 'completedAt', 'pricingUpdatedAt', 'changedAt', 'occurredAt', 'updatedAt'].includes(key)
        && typeof field?.toMillis !== 'function') throw new Error('acceptance/timestamp-type');
      return [key, normalizeRecord(field)];
    }));
  return value;
}

// This function is called ONLY inside the validated explicitly opted-in live test.
// Register disposal before initialization and every cleanup before any data write.
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
  const authManifest = createOwnedAuthManifest({ runId });
  registerPlannedIdentities(authManifest);
  let app, firestore, auth, manifest;
  let preserve = async () => {};
  t.after(() => teardown([
    async () => { if (manifest) await manifest.cleanup(); },
    async () => { await preserve(); },
    async () => {
      if (!auth) return;
      const result = await cleanupOwnedIdentities({ auth, manifest: authManifest });
      if (result.cleanup.some((entry) => !['removed', 'absent', 'planned'].includes(entry.outcome))) {
        throw new Error('acceptance/auth-retained');
      }
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
    app = initializeApp({ projectId: PROJECT, credential: ownedCredential(cert) }, `owned-http-${runId}`);
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
    manifest = createManifest({ runId, actorId: `acceptance-${runId}-administrator` }, store);
    return { runId, authManifest, auth, manifest, registerPreservation(check) { preserve = check; } };
  } catch (error) { throw initializationError(error); }
}

function callableSuccess(outcome) {
  if (outcome.status !== 200 || !same(Object.keys(outcome.body), ['result'])) throw new Error('acceptance/callable-result');
  return outcome.body.result;
}
// A denial carries exactly status and message, plus details { reason } only when the rule
// publishes a structured reason; anything else in the error body fails closed.
function callableDenied(outcome, code, message, reason) {
  const error = outcome.body?.error;
  if (outcome.status === 200 || !same(Object.keys(outcome.body), ['error']) || error?.status !== code
    || (message !== undefined && error.message !== message)
    || !same(Object.keys(error).sort(), reason === undefined ? ['message', 'status'] : ['details', 'message', 'status'])
    || (reason !== undefined && !same(error.details, { reason }))) {
    throw new Error('acceptance/callable-denial');
  }
}

// No live acceptance RED can be established before authorized emulator execution.
// The skipped root contains future real transport cases, not injected service proof.
test('live FUNC-02A/B HTTP/Auth/catalog/pricing/intake/sales/client boundaries (pending authorization)',
  { skip: process.env.LDA_SALES_HTTP_ACCEPTANCE !== '1' }, async (t) => {
    liveApproval(process.env); // Fail closed BEFORE SDK imports, handles or writes.
    const runtime = await openLive(t, process.env);
    const { runId, authManifest, auth, manifest } = runtime;
    const identities = Object.fromEntries([...authManifest.entries].map(([role]) => [role, {
      email: `${role}-${randomUUID()}@demo-lda-inventory.invalid`, password: randomUUID() + randomUUID(),
    }]));
    const provisioned = await provisionOwnedIdentities({ auth, manifest: authManifest, createParams: identities });
    if (provisioned.provisioned.some((entry) => entry.outcome !== 'owned')) throw new Error('acceptance/auth-provision');
    const initialHttp = makeHttp(process.env, BASELINE_DOCS);
    const tokens = {};
    for (const [role, identity] of Object.entries(identities)) {
      const outcome = await initialHttp(LOGIN, 'POST', { ...identity, returnSecureToken: true });
      const planned = authManifest.entries.get(role);
      if (outcome.status !== 200 || outcome.body.localId !== planned.uid
        || typeof outcome.body.idToken !== 'string' || outcome.body.idToken.length < 20) {
        throw new Error('acceptance/login');
      }
      tokens[role] = outcome.body.idToken; // Never assert, log or persist token material.
      const user = await auth.getUser(planned.uid);
      requireSame(user.customClaims, { acceptanceRunId: runId, role,
        ...(role === 'seller' ? { branchId: `branch-${runId}` } : {}) });
    }
    const baseline = async () => ({
      auth: await Promise.all(BASELINE_AUTH.map(async (uid) => {
        const user = await auth.getUser(uid);
        return { uid: user.uid, created: user.metadata.creationTime, claims: user.customClaims };
      })),
      firestore: await Promise.all(BASELINE_DOCS.map(async (path) => {
        const outcome = await initialHttp(`${REST}/${path}`, 'GET', undefined, tokens.administrator);
        if (outcome.status !== 200) throw new Error('acceptance/baseline-unavailable');
        return outcome.body;
      })),
    });
    const before = await baseline();
    runtime.registerPreservation(async () => { requireSame(await baseline(), before); });
    await manifest.seedBranches();
    let http = initialHttp;
    const call = (kind, input, token) => http(`${BASE}/${CALLABLE[kind]}`, 'POST', { data: input }, token);
    await t.test('malformed envelope and exact absence', () => manifest.unchanged(async () => {
      callableDenied(await http(`${BASE}/createProduct`, 'POST', { unsupported: true }, tokens.administrator), 'INVALID_ARGUMENT');
    }));
    for (const role of ['anonymous', 'unassigned', 'client', 'seller']) {
      await t.test(`${role} cannot create products`, () => manifest.unchanged(async () => {
        callableDenied(await call('create', { ...manifest.request('create'), idempotencyKey: manifest.denialKey(role) }, tokens[role]),
          role === 'anonymous' ? 'UNAUTHENTICATED' : 'PERMISSION_DENIED');
      }));
    }
    for (const kind of ['create', 'price', 'intake']) {
      await t.test(`${kind} success, replay and conflict`, async () => {
        await manifest.execute(kind, async (input) => {
          return callableSuccess(await call(kind, input, tokens.administrator));
        });
        http = makeHttp(process.env, [...BASELINE_DOCS, ...manifest.view().entries.map((entry) => entry.path)]);
        const expectedResult = kind === 'create'
          ? { productId: manifest.view().productId, internalCode: manifest.view().productId }
          : kind === 'price'
            ? { auditId: manifest.request(kind).idempotencyKey, productId: manifest.view().productId,
              pricing: { listedPriceCentavos: 1234, currency: 'MXN', priceMode: 'iva-included', ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 } }
            : { entryId: manifest.request(kind).idempotencyKey, movementId: manifest.request(kind).idempotencyKey,
              quantityScaled: 250, stockQuantityScaled: 250, unitCostCentavos: 321, lineTotalCentavos: 802 };
        await manifest.unchanged(async () => requireSame(callableSuccess(await call(kind, manifest.request(kind), tokens.administrator)),
          { ...expectedResult, replayed: true }));
        const changed = { ...manifest.request(kind), ...({ create: { name: 'Different' },
          price: { listedPriceMxn: '99.00' }, intake: { quantity: '3.00' } }[kind]) };
        await manifest.unchanged(async () => callableDenied(await call(kind, changed, tokens.administrator), 'ALREADY_EXISTS'));
      });
    }
    for (const role of ['anonymous', 'unassigned', 'client', 'seller']) {
      for (const kind of ['price', 'intake']) await t.test(`${role} cannot ${kind}`, () => manifest.unchanged(async () => {
        callableDenied(await call(kind, { ...manifest.request(kind), idempotencyKey: manifest.denialKey(role) }, tokens[role]),
          role === 'anonymous' ? 'UNAUTHENTICATED' : 'PERMISSION_DENIED');
      }));
    }
    await t.test('seller direct REST rules: scoped stock, exact product, private reads and writes', () => manifest.unchanged(async () => {
      const paths = manifest.paths();
      const productId = manifest.view().productId;
      const stock = `${paths.branches[0]}/stock/${productId}`;
      for (const path of [`products/${productId}`, stock]) {
        if ((await http(`${REST}/${path}`, 'GET', undefined, tokens.seller)).status !== 200) throw new Error('acceptance/allowed-read');
      }
      const query = { structuredQuery: { from: [{ collectionId: 'stock' }] } };
      const ownQuery = await http(`${REST}/${paths.branches[0]}:runQuery`, 'POST', query, tokens.seller);
      if (ownQuery.status !== 200 || !Array.isArray(ownQuery.body)
        || ownQuery.body.filter((row) => row.document).length !== 1) throw new Error('acceptance/stock-query');
      for (const path of [`${paths.branches[1]}/stock/${productId}`, `costs/${productId}`, paths.createReceipt,
        paths.priceReceipt, paths.priceAudit, paths.entry, paths.intakeReceipt, `products/DEMO-COFFEE`]) {
        if ((await http(`${REST}/${path}`, 'GET', undefined, tokens.seller)).status !== 403) throw new Error('acceptance/private-read');
      }
      if ((await http(`${REST}/${paths.branches[1]}:runQuery`, 'POST', query, tokens.seller)).status !== 403) {
        throw new Error('acceptance/foreign-query');
      }
      for (const role of ['administrator', 'seller', 'client', 'unassigned']) {
        for (const path of [`products/${productId}`, stock, `costs/${productId}`]) {
          if ((await http(`${REST}/${path}`, 'PATCH', { fields: {} }, tokens[role])).status !== 403) throw new Error('acceptance/client-write');
        }
      }
      for (const role of ['client', 'unassigned']) {
        if ((await http(`${REST}/products/${productId}`, 'GET', undefined, tokens[role])).status !== 403) throw new Error('acceptance/client-read');
      }
    }));
    // FUNC-02B: seller sales over real HTTP. The seller branch comes only from token claims.
    const line = (quantity, productId = manifest.view().productId) => ({ productId, quantity });
    const paid = (quantities) => denialPayment(manifest, quantities);
    const denySale = (label, overrides, token, code, message, reason) => t.test(`sale denial: ${label}`,
      () => manifest.unchanged(async () => {
        const input = { ...manifest.request('sale'), idempotencyKey: manifest.denialKey(`sale-${label}`), ...overrides };
        callableDenied(await call('sale', input, token), code, message, reason);
      }));
    // SALE-02/06: the read-only quote must be exactly what the following sale charges.
    const quoted = async (kind) => {
      const { request, expected } = manifest.quote(kind);
      await manifest.unchanged(async () => requireSame(callableSuccess(await call('quote', request, tokens.seller)), expected));
      if (expected.totalCentavos !== manifest.request(kind).payment.amountCentavos) throw new Error('acceptance/quote-charge');
      return expected;
    };
    const charged = (kind, expected) => {
      const receipt = manifest.receipt(kind);
      requireSame(receipt.calculation, expected.calculation);
      if (receipt.payment.amountCentavos !== expected.totalCentavos) throw new Error('acceptance/quote-charge');
    };
    for (const role of ['anonymous', 'unassigned', 'client', 'administrator']) {
      await t.test(`quote denial: ${role}`, () => manifest.unchanged(async () => {
        callableDenied(await call('quote', manifest.quote('sale').request, tokens[role]), ...(role === 'anonymous'
          ? ['UNAUTHENTICATED', SALE_DENIAL.unauthenticated] : ['PERMISSION_DENIED', SALE_DENIAL.seller]));
      }));
    }
    await t.test('quote denial: the seller cannot choose a branch', () => manifest.unchanged(async () => {
      const input = { ...manifest.quote('sale').request, branchId: manifest.paths().branches[1].slice(9) };
      callableDenied(await call('quote', input, tokens.seller), 'INVALID_ARGUMENT', SALE_DENIAL.quote);
    }));
    await t.test('seller quote reports insufficient stock per line without writing', () => manifest.unchanged(async () => {
      const { request, expected } = manifest.quote('sale', '9.00');
      if (expected.lines[0].available !== false) throw new Error('acceptance/quote-stock');
      requireSame(callableSuccess(await call('quote', request, tokens.seller)), expected);
    }));
    for (const role of ['anonymous', 'unassigned', 'client', 'administrator']) {
      await denySale(role, {}, tokens[role], ...(role === 'anonymous'
        ? ['UNAUTHENTICATED', SALE_DENIAL.unauthenticated] : ['PERMISSION_DENIED', SALE_DENIAL.seller]));
    }
    for (const [label, overrides, code, message, reason] of [
      ['insufficient', { lines: [line('9.00')], payment: paid(['9.00']) }, 'FAILED_PRECONDITION', SALE_DENIAL.stock,
        'insufficient-stock'],
      ['branch', { branchId: manifest.paths().branches[1].slice(9) }, 'INVALID_ARGUMENT', SALE_DENIAL.fields],
      ['duplicate', { lines: [line('1.00'), line('1.00')], payment: paid(['1.00', '1.00']) }, 'INVALID_ARGUMENT',
        SALE_DENIAL.fields],
      ['zero', { lines: [line('0.00')], payment: paid(['0.00']) }, 'INVALID_ARGUMENT', SALE_DENIAL.fields],
      ['precision', { lines: [line('1.001')] }, 'INVALID_ARGUMENT', SALE_DENIAL.quantity],
      ['method', { payment: { ...paid(['1.00']), method: 'crypto' } }, 'INVALID_ARGUMENT', SALE_DENIAL.fields],
      ['payment', { payment: { method: 'cash', amountCentavos: paid(['1.00']).amountCentavos - 1 } }, 'INVALID_ARGUMENT',
        SALE_DENIAL.payment, 'payment-mismatch'],
      ['missing', { lines: [line('1.00', `missing-${runId}`)] }, 'NOT_FOUND', SALE_DENIAL.product],
    ]) await denySale(label, overrides, tokens.seller, code, message, reason);
    await t.test('seller sale success with its v2 folio receipt and sale time, replay and conflict', async () => {
      const expected = await quoted('sale');
      // The manifest projects version 2, the owned branch code, the folio and createdAt exactly.
      await manifest.execute('sale', async (input) => callableSuccess(await call('sale', input, tokens.seller)));
      charged('sale', expected);
      await manifest.unchanged(async () => requireSame(callableSuccess(await call('sale', manifest.request('sale'), tokens.seller)),
        manifest.saleReplay('sale')));
      await manifest.unchanged(async () => callableDenied(await call('sale',
        { ...manifest.request('sale'), lines: [line('0.50')] }, tokens.seller), 'ALREADY_EXISTS'));
    });
    await t.test('sale records stay private; the own sale movement shows only the seller actorId', () => manifest.unchanged(async () => {
      const saleKey = manifest.request('sale').idempotencyKey;
      for (const path of [`sales/${saleKey}`, `saleAudits/${saleKey}`, `saleSubmissionReceipts/${saleKey}`]) {
        if ((await http(`${REST}/${path}`, 'GET', undefined, tokens.seller)).status !== 403) throw new Error('acceptance/private-read');
      }
      sellerMovementView(await http(`${REST}/inventoryMovements/sale-${saleKey}-0`, 'GET', undefined, tokens.seller),
        { saleKey, actorId: `acceptance-${runId}-seller`, branchId: manifest.paths().branches[0].slice(9) });
    }));
    await t.test('administrator reprices between sales', () => manifest.execute('reprice',
      async (input) => callableSuccess(await call('reprice', input, tokens.administrator))));
    // The pre-repricing payment no longer matches, with the same structured reason.
    await denySale('stale', {}, tokens.seller, 'INVALID_ARGUMENT', SALE_DENIAL.payment, 'payment-mismatch');
    await t.test('repriced sale equals its quote; the replay keeps the snapshot and sale time', async () => {
      const expected = await quoted('resale');
      await manifest.execute('resale', async (input) => callableSuccess(await call('resale', input, tokens.seller)));
      charged('resale', expected);
      await manifest.unchanged(async () => requireSame(callableSuccess(await call('sale', manifest.request('sale'), tokens.seller)),
        manifest.saleReplay('sale')));
    });
    // Teardown verifies Firestore exact contents transactionally, Auth privately,
    // and baseline preservation. Auth's nontransactional verify-delete race remains.
  });
