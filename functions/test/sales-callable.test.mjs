import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import test from 'node:test';
import * as sales from '../src/sales.js';

const demo = {
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
};
let environment, events, apps, failure, forwarded, useRealService;
const firestore = {
  doc: (path) => ({ path }),
  runTransaction: async (callback) => callback({
    get: async ({ path }) => ({
      exists: !path.startsWith('saleSubmissionReceipts/'),
      data: () => {
        if (/^branches\/[^/]+$/.test(path)) return { name: 'North', code: 'NTE' };
        return path.startsWith('products/') ? {
          quantitySpec: { unit: 'piece', precision: 0 },
          pricing: { currency: 'MXN', listedPriceCentavos: 100,
            priceMode: 'iva-included', ivaTreatment: 'taxable', ivaRateBasisPoints: 1600 },
        } : { unit: 'piece', precision: 0, quantityScaled: 10 };
      },
    }),
    create: () => {}, set: () => {},
  }),
};
class HttpsError extends Error {
  constructor(code, message, details) { super(message); this.code = code; this.details = details; }
}
const safeResult = Object.freeze({ receipt: { saleId: 'key-one' }, replayed: true });
const safeQuote = Object.freeze({ calculation: {}, totalCentavos: 0, lines: [] });
const seams = {
  HttpsError,
  onCall: (options, handler) => ({ options, handler }),
  getApps: () => { events.push('apps'); return apps; },
  initializeApp: () => { events.push('initialize'); if (failure?.at === 'initialize') throw failure.error; },
  getFirestore: () => { events.push('firestore'); if (failure?.at === 'firestore') throw failure.error; return firestore; },
  SaleError: sales.SaleError,
  assertLocalSalesEmulator: () => { events.push('guard'); sales.assertLocalSalesEmulator(environment); },
  createSaleService: (options) => {
    events.push('service');
    assert.equal(options.firestore, firestore);
    if (failure?.at === 'factory') throw failure.error;
    return async (request) => {
      forwarded = request;
      if (failure?.at === 'submit') throw failure.error;
      return useRealService
        ? sales.createSaleService({ ...options, environment })(request) : safeResult;
    };
  },
  createSaleQuoteService: (options) => {
    events.push('quote-service');
    assert.equal(options.firestore, firestore);
    assert.deepEqual(Object.keys(options), ['firestore']);
    if (failure?.at === 'factory') throw failure.error;
    return async (request) => {
      events.push('quote');
      forwarded = request;
      if (failure?.at === 'submit') throw failure.error;
      return useRealService
        ? sales.createSaleQuoteService({ ...options, environment })(request) : safeQuote;
    };
  },
};
// Load the real entrypoint with virtual dependency modules. No SDK is imported;
// the real pure sale module above supplies guard, error and authorization logic.
const key = Symbol.for('lda.sales-callable.test');
globalThis[key] = seams;
const replacements = new Map([
  ['firebase-admin/app', ['getApps', 'initializeApp']],
  ['firebase-admin/firestore', ['getFirestore']],
  ['firebase-functions/v2/https', ['HttpsError', 'onCall']],
  ['./sales.js', ['SaleError', 'assertLocalSalesEmulator', 'createSaleService', 'createSaleQuoteService']],
]);
const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (replacements.has(specifier)
      && (specifier !== './sales.js' || context.parentURL === new URL('../src/index.js', import.meta.url).href)) {
      return { url: `test-seam:${specifier}`, shortCircuit: true };
    }
    assert.ok(!specifier.startsWith('firebase-'), 'unexpected SDK import must not initialize Firebase');
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (!url.startsWith('test-seam:')) return nextLoad(url, context);
    const names = replacements.get(url.slice('test-seam:'.length));
    return { format: 'module', shortCircuit: true,
      source: `export const { ${names.join(', ')} } = globalThis[Symbol.for('lda.sales-callable.test')];` };
  },
});
let entry;
try { entry = await import('../src/index.js'); }
finally { hooks.deregister(); delete globalThis[key]; }

function reset() {
  environment = { ...demo }; events = []; apps = []; failure = null;
  forwarded = null; useRealService = false;
}
function invoke(request = {}) {
  assert.equal(typeof entry.submitSale?.handler, 'function', 'submitSale must be registered');
  return entry.submitSale.handler(request);
}
const rejects = (promise, code, message) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof HttpsError);
  assert.equal(error.code, code);
  assert.equal(error.message, message);
  assert.equal(error.details, undefined);
  return true;
});

test('sale registration uses the existing region and local-only origins', () => {
  assert.ok(entry.submitSale, 'submitSale must be registered');
  assert.equal(entry.submitSale.options.region, 'us-south1');
  assert.equal(entry.submitSale.options.cors, entry.LOCAL_WEB_ORIGINS);
  for (const origin of ['http://localhost:5173', 'https://127.0.0.1:443']) {
    assert.ok(entry.submitSale.options.cors.some((pattern) => pattern.test(origin)));
  }
  assert.ok(!entry.submitSale.options.cors.some((pattern) => pattern.test('https://example.com')));
});

test('every demo guard condition fails before SDK or service access', async () => {
  for (const [field, value] of [
    ['GCLOUD_PROJECT', 'production'], ['FUNCTIONS_EMULATOR', 'false'],
    ['FIRESTORE_EMULATOR_HOST', ''], ['FIRESTORE_EMULATOR_HOST', undefined],
  ]) {
    reset(); environment[field] = value;
    await rejects(invoke(), 'failed-precondition', 'sales are restricted to the local demo emulator');
    assert.deepEqual(events, ['guard']);
  }
});

test('strict sale configuration fails before even getApps for new or existing apps', async (t) => {
  const patches = [
    { FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' },
    { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8081' },
    { FIRESTORE_EMULATOR_HOST: 'http://127.0.0.1:8080' },
    { FIRESTORE_EMULATOR_HOST: 'localhost:8080' },
    { FIRESTORE_EMULATOR_HOST: ' 127.0.0.1:8080' },
    { GCLOUD_PROJECT: 'demo-lda-inventory ' },
    { GCLOUD_PROJECT: undefined },
    { FUNCTIONS_EMULATOR: undefined },
    { GOOGLE_CLOUD_PROJECT: 'production' },
    { GOOGLE_CLOUD_PROJECT: '' },
    { FIREBASE_CONFIG: '{"projectId":"production"}' },
    { FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory "}' },
    { FIREBASE_CONFIG: '{' },
    { FIREBASE_CONFIG: '/unread/config.json' },
    { FIREBASE_CONFIG: '[]' },
    { FIREBASE_CONFIG: 'null' },
    { FIREBASE_CONFIG: '{}' },
    { FIREBASE_CONFIG: '' },
    { FIREBASE_CONFIG: { projectId: 'demo-lda-inventory' } },
    { FIREBASE_CONFIG: '{"projectId":123}' },
  ];
  for (const patch of patches) {
    const label = Object.entries(patch).map(([field, value]) => `${field}=${JSON.stringify(value)}`).join(', ');
    await t.test(label, async () => {
      for (const existing of [[], [{}]]) {
        reset(); apps = existing; environment = { ...demo, ...patch };
        await rejects(invoke(), 'failed-precondition', 'sales are restricted to the local demo emulator');
        assert.deepEqual(events, ['guard']);
      }
    });
  }
});

test('matching optional project sources preserve callable receipt forwarding', async () => {
  reset(); environment = { ...demo, GOOGLE_CLOUD_PROJECT: 'demo-lda-inventory',
    FIREBASE_CONFIG: '{"projectId":"demo-lda-inventory"}' };
  assert.equal(await invoke(), safeResult);
  assert.deepEqual(events, ['guard', 'apps', 'initialize', 'firestore', 'service']);
});

test('trusted request and seller-safe result pass through, with lazy Admin initialization', async () => {
  for (const existing of [[], [{}]]) {
    reset(); apps = existing;
    const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'north' } }, data: {} };
    assert.equal(await invoke(request), safeResult);
    assert.equal(forwarded, request);
    assert.deepEqual(events, existing.length
      ? ['guard', 'apps', 'firestore', 'service'] : ['guard', 'apps', 'initialize', 'firestore', 'service']);
  }
});

test('unchanged sale service derives branch from auth and rejects client authority or admins', async () => {
  reset(); useRealService = true;
  const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'north' } },
    data: { idempotencyKey: '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab', invoiceRequested: false,
      lines: [{ productId: 'p1', quantity: '1' }], payment: { method: 'cash', amountCentavos: 100 } } };
  const result = await invoke(request);
  const { receipt, replayed } = result;
  assert.equal(receipt.branchId, 'north'); assert.equal(replayed, false);
  assert.deepEqual(Object.keys(result).sort(), ['createdAt', 'receipt', 'replayed']);
  assert.ok(Number.isSafeInteger(result.createdAt) && result.createdAt > 0);
  assert.deepEqual(Object.keys(receipt).sort(),
    ['branchCode', 'branchId', 'calculation', 'folio', 'payment', 'productIds', 'saleId', 'version']);
  assert.equal(receipt.folio, 'NTE-3F2A-9C1B');
  assert.equal(receipt.calculation.totalCentavos, 100);
  await rejects(invoke({ ...request, data: { ...request.data, branchId: 'south' } }),
    'invalid-argument', 'sale request contains missing, invalid or unsupported fields');
  await rejects(invoke({ ...request, auth: { uid: 'admin', token: { role: 'admin', branchId: 'north' } } }),
    'permission-denied', 'an assigned seller is required');
  await rejects(invoke({ ...request, auth: { uid: 'seller', token: { role: 'seller' } } }),
    'permission-denied', 'an assigned seller is required');
  await rejects(invoke({ ...request, auth: null }), 'unauthenticated', 'authentication is required');
});

test('known SaleError codes and public messages are mapped without private details', async () => {
  for (const code of ['unauthenticated', 'permission-denied', 'invalid-argument',
    'not-found', 'failed-precondition', 'out-of-range', 'already-exists']) {
    reset();
    const error = new sales.SaleError(code, 'public sale failure');
    error.details = 'private provenance';
    failure = { at: 'submit', error };
    await rejects(invoke(), code, 'public sale failure');
  }
});

const rejectsWithReason = (promise, code, message, reason) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof HttpsError);
  assert.equal(error.code, code);
  assert.equal(error.message, message);
  assert.deepEqual(error.details, { reason });
  assert.deepEqual(Object.keys(error.details), ['reason']);
  return true;
});

test('the real service maps payment mismatch and insufficient stock to details.reason', async () => {
  reset(); useRealService = true;
  const request = (quantity, amountCentavos) => ({
    auth: { uid: 'seller', token: { role: 'seller', branchId: 'north' } },
    data: { idempotencyKey: '3f2a9c1b-7d4e-4a10-8b6c-0123456789ab', invoiceRequested: false,
      lines: [{ productId: 'p1', quantity }], payment: { method: 'cash', amountCentavos } },
  });
  await rejectsWithReason(invoke(request('1', 99)), 'invalid-argument',
    'full payment must equal the authoritative total', 'payment-mismatch');
  await rejectsWithReason(invoke(request('11', 1100)), 'failed-precondition',
    'insufficient stock', 'insufficient-stock');
});

test('a SaleError reason is forwarded alone; private fields never reach details', async () => {
  reset();
  const error = new sales.SaleError('invalid-argument', 'public sale failure', 'payment-mismatch');
  error.details = 'private provenance';
  failure = { at: 'submit', error };
  await rejectsWithReason(invoke(), 'invalid-argument', 'public sale failure', 'payment-mismatch');
  reset();
  failure = { at: 'submit', error: new sales.SaleError('failed-precondition', 'public quote failure', 'insufficient-stock') };
  await rejectsWithReason(invokeQuote(), 'failed-precondition', 'public quote failure', 'insufficient-stock');
});

test('unknown initialization, Firestore, factory and submission errors are sanitized', async () => {
  for (const at of ['initialize', 'firestore', 'factory', 'submit']) {
    reset(); failure = { at, error: new Error('private infrastructure diagnostic') };
    await rejects(invoke(), 'internal', 'sale submission is temporarily unavailable');
  }
  reset();
  failure = { at: 'submit', error: { code: 'permission-denied', message: 'private diagnostic' } };
  await rejects(invoke(), 'internal', 'sale submission is temporarily unavailable');
});

function invokeQuote(request = {}) {
  assert.equal(typeof entry.quoteSale?.handler, 'function', 'quoteSale must be registered');
  return entry.quoteSale.handler(request);
}

test('quote registration uses the existing region and local-only origins', () => {
  assert.equal(entry.quoteSale.options.region, 'us-south1');
  assert.equal(entry.quoteSale.options.cors, entry.LOCAL_WEB_ORIGINS);
});

test('every quote guard failure is the fixed sales precondition before SDK or service access', async () => {
  for (const patch of [
    { GCLOUD_PROJECT: 'production' }, { FUNCTIONS_EMULATOR: 'false' },
    { FIRESTORE_EMULATOR_HOST: '' }, { FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' },
    { GOOGLE_CLOUD_PROJECT: 'production' }, { FIREBASE_CONFIG: '{"projectId":"production"}' },
  ]) {
    for (const existing of [[], [{}]]) {
      reset(); apps = existing; environment = { ...demo, ...patch };
      await rejects(invokeQuote(), 'failed-precondition', 'sales are restricted to the local demo emulator');
      assert.deepEqual(events, ['guard']);
    }
  }
});

test('the quote request reaches only the quote service, with lazy Admin initialization', async () => {
  for (const existing of [[], [{}]]) {
    reset(); apps = existing;
    const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'north' } },
      data: { invoiceRequested: true, lines: [{ productId: 'p1', quantity: '1' }] } };
    assert.equal(await invokeQuote(request), safeQuote);
    assert.equal(forwarded, request);
    assert.deepEqual(events, ['guard', 'apps', ...(existing.length ? [] : ['initialize']), 'firestore',
      'quote-service', 'quote']);
  }
});

test('the real quote service answers through the callable without writing', async () => {
  reset(); useRealService = true;
  const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'north' } },
    data: { invoiceRequested: true, lines: [{ productId: 'p1', quantity: '3' }] } };
  const quote = await invokeQuote(request);
  assert.equal(quote.totalCentavos, 300);
  assert.deepEqual(quote.lines, [{ productId: 'p1', available: true }]);
  await rejects(invokeQuote({ ...request, data: { ...request.data, payment: { method: 'cash', amountCentavos: 300 } } }),
    'invalid-argument', 'quote request contains missing, invalid or unsupported fields');
  await rejects(invokeQuote({ ...request, auth: { uid: 'admin', token: { role: 'admin', branchId: 'north' } } }),
    'permission-denied', 'an assigned seller is required');
  await rejects(invokeQuote({ ...request, auth: null }), 'unauthenticated', 'authentication is required');
});

test('quote SaleErrors keep their public message and unknown faults are sanitized', async () => {
  for (const code of ['unauthenticated', 'permission-denied', 'invalid-argument',
    'not-found', 'failed-precondition', 'out-of-range']) {
    reset();
    const error = new sales.SaleError(code, 'public quote failure');
    error.details = 'private provenance';
    failure = { at: 'submit', error };
    await rejects(invokeQuote(), code, 'public quote failure');
  }
  for (const at of ['initialize', 'firestore', 'factory', 'submit']) {
    reset(); failure = { at, error: new Error('private infrastructure diagnostic') };
    await rejects(invokeQuote(), 'internal', 'sale quote is temporarily unavailable');
  }
  reset();
  failure = { at: 'submit', error: { code: 'permission-denied', message: 'private diagnostic' } };
  await rejects(invokeQuote(), 'internal', 'sale quote is temporarily unavailable');
});
