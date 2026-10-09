import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import test from 'node:test';
import { CorrectionError } from '../src/corrections-calculation.js';
import * as sales from '../src/sales.js';

const demo = {
  GCLOUD_PROJECT: 'demo-lda-inventory', FUNCTIONS_EMULATOR: 'true',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
};
const GUARD_MESSAGE = 'sale corrections are restricted to the local demo emulator';
const CALLABLES = [
  { name: 'findCorrectableSale', factory: 'createSaleLookupService', operation: 'findSale',
    unavailable: 'sale lookup is temporarily unavailable' },
  { name: 'listRecentCorrectableSales', factory: 'createSaleLookupService', operation: 'listRecentSales',
    unavailable: 'recent sales lookup is temporarily unavailable' },
  { name: 'submitSaleReturn', factory: 'createSaleReturnService', operation: 'submitReturn',
    unavailable: 'sale return is temporarily unavailable' },
  { name: 'submitSaleReplacement', factory: 'createSaleReplacementService', operation: 'submitReplacement',
    unavailable: 'sale replacement is temporarily unavailable' },
  { name: 'submitSaleExchange', factory: 'createSaleExchangeService', operation: 'submitExchange',
    unavailable: 'sale exchange is temporarily unavailable' },
  { name: 'previewSaleReturn', factory: 'createSaleReturnPreviewService', operation: 'previewReturn',
    unavailable: 'sale return preview is temporarily unavailable' },
  { name: 'previewSaleExchange', factory: 'createSaleExchangePreviewService', operation: 'previewExchange',
    unavailable: 'sale exchange preview is temporarily unavailable' },
];
let environment, events, apps, failure, forwarded;
const firestore = Object.freeze({ seam: 'admin-firestore' });
class HttpsError extends Error {
  constructor(code, message, details) { super(message); this.code = code; this.details = details; }
}
const safeResult = Object.freeze({ receipt: { saleId: 'sale-one' }, replayed: false });

// Each fake operation records the factory and operation actually reached, so a
// callable wired to the wrong service fails its own test.
function operation(factory, name) {
  return async (request) => {
    events.push(`${factory}.${name}`);
    forwarded = request;
    if (failure?.at === 'operation') throw failure.error;
    return safeResult;
  };
}
function factory(name, build) {
  return (options) => {
    events.push('service');
    assert.equal(options.firestore, firestore);
    assert.deepEqual(Object.keys(options), ['firestore']);
    if (failure?.at === 'factory') throw failure.error;
    return build(name);
  };
}
const seams = {
  HttpsError,
  onCall: (options, handler) => ({ options, handler }),
  getApps: () => { events.push('apps'); return apps; },
  initializeApp: () => { events.push('initialize'); if (failure?.at === 'initialize') throw failure.error; },
  getFirestore: () => { events.push('firestore'); if (failure?.at === 'firestore') throw failure.error; return firestore; },
  SaleError: sales.SaleError,
  assertLocalSalesEmulator: () => { events.push('guard'); sales.assertLocalSalesEmulator(environment); },
  createSaleService: () => { throw new Error('sale service must not be used by corrections'); },
  createSaleQuoteService: () => { throw new Error('quote service must not be used by corrections'); },
  createSaleLookupService: factory('createSaleLookupService', (name) => Object.freeze({
    findSale: operation(name, 'findSale'), listRecentSales: operation(name, 'listRecentSales'),
  })),
  createSaleReturnService: factory('createSaleReturnService', (name) => operation(name, 'submitReturn')),
  createSaleReplacementService: factory('createSaleReplacementService',
    (name) => operation(name, 'submitReplacement')),
  createSaleExchangeService: factory('createSaleExchangeService', (name) => operation(name, 'submitExchange')),
  createSaleReturnPreviewService: factory('createSaleReturnPreviewService', (name) => operation(name, 'previewReturn')),
  createSaleExchangePreviewService: factory('createSaleExchangePreviewService',
    (name) => operation(name, 'previewExchange')),
};
// Load the real entrypoint with virtual dependency modules. No SDK is imported;
// the real pure sale module supplies the guard and the SaleError class.
const key = Symbol.for('lda.corrections-callable.test');
globalThis[key] = seams;
const indexUrl = new URL('../src/index.js', import.meta.url).href;
const replacements = new Map([
  ['firebase-admin/app', ['getApps', 'initializeApp']],
  ['firebase-admin/firestore', ['getFirestore']],
  ['firebase-functions/v2/https', ['HttpsError', 'onCall']],
  ['./sales.js', ['SaleError', 'assertLocalSalesEmulator', 'createSaleService', 'createSaleQuoteService']],
  ['./sale-lookup.js', ['createSaleLookupService']],
  ['./sale-returns.js', ['createSaleReturnService', 'createSaleReturnPreviewService']],
  ['./sale-replacements.js', ['createSaleReplacementService']],
  ['./sale-exchanges.js', ['createSaleExchangeService', 'createSaleExchangePreviewService']],
]);
const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (replacements.has(specifier)
      && (!specifier.startsWith('./') || context.parentURL === indexUrl)) {
      return { url: `test-seam:${specifier}`, shortCircuit: true };
    }
    assert.ok(!specifier.startsWith('firebase-'), 'unexpected SDK import must not initialize Firebase');
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (!url.startsWith('test-seam:')) return nextLoad(url, context);
    const names = replacements.get(url.slice('test-seam:'.length));
    return { format: 'module', shortCircuit: true,
      source: `export const { ${names.join(', ')} } = globalThis[Symbol.for('lda.corrections-callable.test')];` };
  },
});
let entry;
try { entry = await import('../src/index.js'); }
finally { hooks.deregister(); delete globalThis[key]; }

function reset() {
  environment = { ...demo }; events = []; apps = []; failure = null; forwarded = null;
}
function invoke(name, request = {}) {
  assert.equal(typeof entry[name]?.handler, 'function', `${name} must be registered`);
  return entry[name].handler(request);
}
const rejects = (promise, code, message) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof HttpsError);
  assert.equal(error.code, code);
  assert.equal(error.message, message);
  assert.equal(error.details, undefined);
  return true;
});

test('correction registrations use the existing region and local-only origins', () => {
  for (const { name } of CALLABLES) {
    assert.ok(entry[name], `${name} must be registered`);
    assert.equal(entry[name].options.region, 'us-south1');
    assert.equal(entry[name].options.cors, entry.LOCAL_WEB_ORIGINS);
  }
});

test('every demo guard failure is a fixed precondition before SDK or service access', async () => {
  for (const { name } of CALLABLES) {
    for (const patch of [
      { GCLOUD_PROJECT: 'production' }, { FUNCTIONS_EMULATOR: 'false' },
      { FIRESTORE_EMULATOR_HOST: '' }, { FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' },
      { GOOGLE_CLOUD_PROJECT: 'production' }, { FIREBASE_CONFIG: '{"projectId":"production"}' },
    ]) {
      for (const existing of [[], [{}]]) {
        reset(); apps = existing; environment = { ...demo, ...patch };
        await rejects(invoke(name), 'failed-precondition', GUARD_MESSAGE);
        assert.deepEqual(events, ['guard']);
      }
    }
  }
});

test('trusted auth reaches the matching service and its result passes through', async () => {
  for (const { name, factory: service, operation: method } of CALLABLES) {
    for (const existing of [[], [{}]]) {
      reset(); apps = existing;
      const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'branch-north' } },
        data: { saleId: 'sale-one' } };
      assert.equal(await invoke(name, request), safeResult);
      assert.equal(forwarded, request);
      assert.equal(forwarded.auth, request.auth);
      assert.deepEqual(events, [
        'guard', 'apps', ...(existing.length ? [] : ['initialize']), 'firestore', 'service',
        `${service}.${method}`,
      ]);
    }
  }
});

test('known SaleError codes and public messages are mapped without private details', async () => {
  for (const { name } of CALLABLES) {
    for (const code of ['unauthenticated', 'permission-denied', 'invalid-argument',
      'not-found', 'failed-precondition', 'out-of-range', 'already-exists']) {
      reset();
      const error = new sales.SaleError(code, `public ${code} correction failure`);
      error.details = 'private provenance';
      failure = { at: 'operation', error };
      await rejects(invoke(name), code, `public ${code} correction failure`);
    }
  }
});

test('a SaleError reason reaches correction callers only as details.reason', async () => {
  for (const { name } of CALLABLES) {
    reset();
    failure = { at: 'operation', error: new sales.SaleError('failed-precondition', 'insufficient stock', 'insufficient-stock') };
    await assert.rejects(invoke(name), (error) => {
      assert.ok(error instanceof HttpsError);
      assert.equal(error.code, 'failed-precondition');
      assert.equal(error.message, 'insufficient stock');
      assert.deepEqual(error.details, { reason: 'insufficient-stock' });
      return true;
    });
  }
});

test('unknown initialization, Firestore, factory and operation errors are sanitized', async () => {
  for (const { name, unavailable } of CALLABLES) {
    for (const at of ['initialize', 'firestore', 'factory', 'operation']) {
      reset(); failure = { at, error: new Error('private infrastructure diagnostic') };
      await rejects(invoke(name), 'internal', unavailable);
    }
    // Services translate calculation errors; one escaping is an internal fault.
    reset();
    failure = { at: 'operation', error: new CorrectionError('invalid-argument', 'private calculation') };
    await rejects(invoke(name), 'internal', unavailable);
    reset();
    failure = { at: 'operation', error: { code: 'permission-denied', message: 'private diagnostic' } };
    await rejects(invoke(name), 'internal', unavailable);
  }
});

test('findCorrectableSale forwards a folio request unchanged to the lookup service', async () => {
  reset();
  const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'branch-north' } },
    data: { folio: 'nte-3f2a-9c1b' } };
  assert.equal(await invoke('findCorrectableSale', request), safeResult);
  assert.equal(forwarded, request);
  assert.deepEqual(forwarded.data, { folio: 'nte-3f2a-9c1b' });
  assert.equal(events.at(-1), 'createSaleLookupService.findSale');
});

test('a correction reason such as folio-ambiguous or payment-mismatch passes through every callable', async () => {
  for (const { name } of CALLABLES) {
    for (const [code, message, reason] of [
      ['failed-precondition', 'folio is ambiguous; use the full receipt id or the recent list', 'folio-ambiguous'],
      ['invalid-argument', 'difference payment must equal the amount the customer owes', 'payment-mismatch'],
    ]) {
      reset();
      failure = { at: 'operation', error: new sales.SaleError(code, message, reason) };
      await assert.rejects(invoke(name), (error) => {
        assert.ok(error instanceof HttpsError);
        assert.deepEqual([error.code, error.message, error.details], [code, message, { reason }]);
        return true;
      });
    }
  }
});

test('the preview callables forward requests unchanged to their own read-only services', async () => {
  for (const [name, method, data] of [
    ['previewSaleReturn', 'createSaleReturnPreviewService.previewReturn',
      { saleId: 'sale-one', reason: 'other', lines: [{ lineIndex: 0, quantity: '1', condition: 'good' }] }],
    ['previewSaleExchange', 'createSaleExchangePreviewService.previewExchange',
      { saleId: 'sale-one', reason: 'other', returnLines: [], newLines: [] }],
  ]) {
    reset();
    const request = { auth: { uid: 'seller', token: { role: 'seller', branchId: 'branch-north' } }, data };
    assert.equal(await invoke(name, request), safeResult);
    assert.equal(forwarded, request);
    assert.equal(events.at(-1), method);
    assert.ok(!events.some((event) => /\.submit/.test(event)), 'a preview never reaches a submit service');
  }
});
