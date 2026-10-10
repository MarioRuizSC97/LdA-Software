// SP-05: live HTTP transport acceptance for setSellerProfile, the sellerProfiles rules and the
// administrator movements query. Offline tests never initialize an SDK or open a socket; the
// live root is skipped unless every approval below is present with the pinned local emulators.
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { EventEmitter } from 'node:events';
import { lstatSync, realpathSync } from 'node:fs';
import test from 'node:test';
import { approvedRequire, SDK_ROOT, canonical } from './sales-emulator-support.mjs';
import {
  OWNED_ROLES, createOwnedAuthManifest, registerPlannedIdentities,
  provisionOwnedIdentities, cleanupOwnedIdentities,
} from './owned-auth-manifest.mjs';
// Offline rehearsal only: the real services run against an in-memory store.
import { SellerProfileError, createSellerProfileService } from '../src/sellerProfiles.js';
import { InventoryError, createStockIntakeService } from '../src/inventory.js';

const NODE = '/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node';
const RUN = '12345678-1234-4234-8234-123456789abc';
const PROJECT = 'demo-lda-inventory';
const PINNED = {
  GCLOUD_PROJECT: PROJECT, FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
  FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080', FUNCTIONS_EMULATOR: 'true',
};
const LIVE = {
  LDA_SELLER_PROFILES_HTTP_ACCEPTANCE: '1',
  LDA_SALES_FIXTURE_BASELINE_APPROVAL: 'demo-seed-eight-documents-two-identities',
  LDA_SALES_RUNTIME_REVALIDATED: 'explicit-local-source-project-routes-reviewed',
};
const SERVICE_ENVIRONMENT = Object.freeze({ ...PINNED });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const BASE = `http://127.0.0.1:5001/${PROJECT}/us-south1`;
const REST = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const RUN_QUERY = `${REST}:runQuery`;
const LOGIN = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only';
const DOCUMENT_NAME = `projects/${PROJECT}/databases/(default)/documents`;
const FUNCTIONS = ['setSellerProfile', 'stockIntake'];
const QUERY_COLLECTIONS = ['inventoryMovements', 'sellerProfiles'];
const DENIAL = {
  unauthenticated: 'authentication is required',
  administrator: 'administrator role is required',
  notSeller: 'target user is not a seller',
};
const SUCCESS_ORDER = ['set', 'rename', 'intake'];
const UNCERTAIN = /acceptance\/operation-uncertain/;
const OBSERVATION = /acceptance\/observation-uncertain/;
const RETAINED = /acceptance\/firestore-retained-or-delete-unknown/;
const TIMESTAMP = /acceptance\/timestamp-type/;
const copy = (value) => structuredClone(value);
const same = (a, b) => canonical(a) === canonical(b);
const requireSame = (a, b) => { if (!same(a, b)) throw new Error('acceptance/content-mismatch'); };

// Every path is owned by the run id: one branch, one product, one stock intake, and a profile
// slot per owned identity so any profile written by a denial is caught before teardown.
function fixture(runId) {
  const uid = (role) => `acceptance-${runId}-${role}`;
  const branch = `branch-${runId}`;
  const productId = `SP-${runId.toUpperCase()}`;
  const key = `sp-${runId}-intake`;
  const spec = { unit: 'piece', precision: 0 };
  const profile = (role) => `sellerProfiles/${uid(role)}`;
  const seeds = new Map([
    // Owned acceptance code never reuses the demo NTE/SUR codes.
    [`branches/${branch}`, { name: `Seller profiles ${runId}`, code: 'SPA', acceptanceRunId: runId }],
    [`products/${productId}`, { internalCode: productId, name: `Acceptance ${productId}`, quantitySpec: copy(spec) }],
  ]);
  const operations = {
    set: { uid: uid('seller'), displayName: 'Vendedora Aceptación' },
    rename: { uid: uid('seller'), displayName: 'Vendedora Renombrada' },
    intake: { idempotencyKey: key, branchId: branch, productId, quantity: '5', unitCostMxn: '12.34' },
  };
  const paths = [...seeds.keys(), ...OWNED_ROLES.map(profile), `stockIntakeEntries/${key}`,
    `inventoryMovements/${key}`, `branches/${branch}/stock/${productId}`, `costs/${productId}`,
    `stockIntakeReceipts/${key}`];
  return { uid, branch, productId, key, spec, profile, seeds, operations, paths };
}

// Independent projection: the profile branch comes only from the seller's claims, and the
// intake (5 pieces at 12.34 MXN) is computed here, never adopted from the response.
function project(label, fx, timestamp) {
  const data = fx.operations[label];
  if (label !== 'intake') {
    return { response: { uid: data.uid, replayed: false },
      documents: new Map([[fx.profile('seller'), { displayName: data.displayName, branchId: fx.branch }]]) };
  }
  const { key, branch: branchId, productId, spec } = fx;
  const actorId = fx.uid('administrator');
  const result = { entryId: key, movementId: key, quantityScaled: 5, stockQuantityScaled: 5,
    unitCostCentavos: 1234, lineTotalCentavos: 6170 };
  return { response: { ...result, replayed: false }, documents: new Map([
    [`stockIntakeEntries/${key}`, { branchId, productId, quantityScaled: 5, ...spec, unitCostCentavos: 1234,
      lineTotalCentavos: 6170, currency: 'MXN', calculationPolicyVersion: 'mxn-unit-cost-truncate-v1',
      createdAt: timestamp, createdBy: actorId }],
    [`inventoryMovements/${key}`, { type: 'stock-intake', branchId, productId, quantityScaled: 5, ...spec,
      entryId: key, occurredAt: timestamp, actorId }],
    [`branches/${branchId}/stock/${productId}`, { quantityScaled: 5, ...spec, updatedAt: timestamp, lastMovementId: key }],
    [`costs/${productId}`, { latestUnitCostCentavos: 1234, currency: 'MXN', sourceEntryId: key, updatedAt: timestamp }],
    [`stockIntakeReceipts/${key}`, { fingerprint: JSON.stringify({ branchId, productId, quantity: '5', unitCostCentavos: 1234 }),
      result, completedAt: timestamp, actorId }],
  ]) };
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

// Private closure authority: requests, plan and expectations live only here. Responses and
// server records are never adopted; only a success whose every planned document matches the
// independent projection advances the state. Any doubt retains every document.
function createManifest(context, adapter) {
  const { runId, clock = Date.now } = context ?? {};
  if (!UUID.test(runId ?? '') || typeof clock !== 'function') throw new Error('acceptance/context');
  const store = Object.fromEntries(['read', 'create', 'transaction'].map((name) => [name, adapter[name].bind(adapter)]));
  const fx = fixture(runId);
  const entries = new Map(fx.paths.map((path) => [path, null]));
  if (entries.size !== fx.paths.length) throw new Error('acceptance/duplicate-plan');
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
    for (const [path, expected] of entries) requireSame(records.get(path), expected);
  };
  const stamp = (value, before, after) => {
    if (after < before || !Number.isSafeInteger(value) || value < before - 5000 || value > after + 5000) {
      throw new Error('acceptance/timestamp-window');
    }
    return value;
  };
  return Object.freeze({
    ids: () => ({ runId, branch: fx.branch, productId: fx.productId, key: fx.key,
      uids: Object.fromEntries(OWNED_ROLES.map((role) => [role, fx.uid(role)])) }),
    paths: () => [...entries.keys()],
    request: (label) => {
      if (!SUCCESS_ORDER.includes(label)) throw new Error('acceptance/unknown-operation');
      return copy(fx.operations[label]);
    },
    expected: (path) => {
      if (!entries.has(path)) throw new Error('acceptance/unplanned');
      return copy(entries.get(path));
    },
    view: () => ({ runId, uncertain, completed: [...completed],
      entries: [...entries].map(([path, expected]) => ({ path, expected: copy(expected) })) }),
    async seed() {
      if (seeded || cleanupStarted) throw new Error('acceptance/seed-once');
      seeded = true;
      try {
        validate(await read());
        uncertain = true;
        for (const [path, value] of fx.seeds) {
          await deadline(() => store.create(path, copy(value)));
          requireSame((await read()).get(path), value);
          entries.set(path, copy(value));
        }
        uncertain = false;
      } catch { uncertain = true; throw new Error('acceptance/seed-uncertain'); }
    },
    async execute(label, transport, timeoutMs = 10000) {
      if (!seeded || uncertain || active || cleanupStarted || SUCCESS_ORDER[completed.length] !== label) {
        throw new Error('acceptance/operation-order');
      }
      active = true;
      try { validate(await read()); }
      catch { active = false; uncertain = true; throw new Error('acceptance/preflight-mismatch'); }
      uncertain = true; // BEFORE issuing any request; a timeout never cancels its side effects.
      const before = clock();
      try {
        const result = await deadline(() => transport(copy(fx.operations[label])), timeoutMs);
        const after = clock();
        const records = await read();
        const timestamp = label === 'intake'
          ? stamp(records.get(`stockIntakeReceipts/${fx.key}`)?.completedAt, before, after) : undefined;
        const projection = project(label, fx, timestamp);
        requireSame(result, projection.response);
        for (const [path, expected] of entries) {
          requireSame(records.get(path), projection.documents.has(path) ? projection.documents.get(path) : expected);
        }
        for (const [path, value] of projection.documents) entries.set(path, copy(value));
        completed.push(label);
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

// --- Firestore REST wire format: only the value types the planned documents use. ---
const TIMESTAMP_TEXT = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$/;
function restValue(value) {
  const keys = value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value) : [];
  if (keys.length === 1) {
    const [type] = keys;
    const raw = value[type];
    if (type === 'stringValue' && typeof raw === 'string') return raw;
    if (type === 'integerValue' && typeof raw === 'string' && /^-?(?:0|[1-9]\d*)$/.test(raw)
      && Number.isSafeInteger(Number(raw))) return Number(raw);
    const match = type === 'timestampValue' && typeof raw === 'string' ? TIMESTAMP_TEXT.exec(raw) : null;
    const seconds = match ? Date.parse(`${match[1]}Z`) : NaN;
    // Floor to milliseconds, the same precision the Admin Timestamp normalization uses.
    if (Number.isSafeInteger(seconds)) return seconds + Math.floor(Number((match[2] ?? '').padEnd(9, '0')) / 1e6);
  }
  throw new Error('acceptance/rest-value');
}

function restDocument(document, path) {
  if (!document || typeof document !== 'object' || !same(Object.keys(document).sort(),
    ['createTime', 'fields', 'name', 'updateTime']) || document.name !== `${DOCUMENT_NAME}/${path}`
    || !document.fields || typeof document.fields !== 'object' || Array.isArray(document.fields)) {
    throw new Error('acceptance/rest-document');
  }
  return Object.fromEntries(Object.entries(document.fields).map(([key, value]) => [key, restValue(value)]));
}

// A runQuery body is an array of { document?, readTime, done? } rows; anything else fails closed.
function queryDocuments(outcome) {
  if (outcome.status !== 200 || !Array.isArray(outcome.body)) throw new Error('acceptance/query-shape');
  const documents = [];
  for (const row of outcome.body) {
    const keys = row && typeof row === 'object' ? Object.keys(row) : ['invalid'];
    if (!keys.includes('readTime') || keys.some((key) => !['document', 'readTime', 'done'].includes(key))) {
      throw new Error('acceptance/query-shape');
    }
    if (row.document) documents.push(row.document);
  }
  return documents;
}

function movementsQuery(branchId) {
  return { structuredQuery: {
    from: [{ collectionId: 'inventoryMovements' }],
    ...(branchId === undefined ? {} : { where: { fieldFilter: { field: { fieldPath: 'branchId' }, op: 'EQUAL',
      value: { stringValue: branchId } } } }),
    orderBy: [{ field: { fieldPath: 'occurredAt' }, direction: 'DESCENDING' }],
    limit: 50,
  } };
}

// URL authority is local and exact; no external host, redirects or caller options. Only owned
// profile paths accept the (expected-denied) client writes; runQuery names one known collection.
function makeHttp(environment, documentPaths, transport = httpRequest, approve = liveApproval) {
  const allowed = new Map([[LOGIN, ['POST']], [RUN_QUERY, ['POST']], [`${REST}/sellerProfiles`, ['GET']],
    ...FUNCTIONS.map((name) => [`${BASE}/${name}`, ['POST']])]);
  for (const path of documentPaths) {
    allowed.set(`${REST}/${path.split('/').map(encodeURIComponent).join('/')}`,
      path.startsWith('sellerProfiles/') ? ['GET', 'PATCH', 'DELETE'] : ['GET']);
  }
  return async (url, method = 'GET', body, token) => {
    approve(environment);
    approve(process.env);
    if (!allowed.get(url)?.includes(method)) throw new Error('acceptance/url-refused');
    const from = body?.structuredQuery?.from;
    if (url === RUN_QUERY && (!Array.isArray(from) || from.length !== 1 || !same(Object.keys(from[0]), ['collectionId'])
      || !QUERY_COLLECTIONS.includes(from[0].collectionId))) throw new Error('acceptance/url-refused');
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
    const { seconds, nanoseconds } = value;
    const milliseconds = value.toMillis();
    if (!Number.isSafeInteger(seconds) || !Number.isInteger(nanoseconds) || nanoseconds < 0 || nanoseconds > 999999999
      || !Number.isSafeInteger(milliseconds) || milliseconds !== seconds * 1000 + Math.floor(nanoseconds / 1e6)) {
      throw new Error('acceptance/timestamp-type');
    }
    return milliseconds;
  }
  if (Array.isArray(value)) return value.map(normalizeRecord);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, field]) => {
    if (['createdAt', 'completedAt', 'occurredAt', 'updatedAt'].includes(key) && typeof field?.toMillis !== 'function') {
      throw new Error('acceptance/timestamp-type');
    }
    return [key, normalizeRecord(field)];
  }));
  return value;
}

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

// A denial carries exactly status and message, plus details { reason } only when the callable
// publishes a structured reason; anything else in the error body fails closed.
function callableDenied(outcome, code, message, reason) {
  const error = outcome.body?.error;
  if (outcome.status === 200 || !same(Object.keys(outcome.body ?? {}), ['error']) || error?.status !== code
    || error.message !== message
    || !same(Object.keys(error).sort(), reason === undefined ? ['message', 'status'] : ['details', 'message', 'status'])
    || (reason !== undefined && !same(error.details, { reason }))) {
    throw new Error('acceptance/callable-denial');
  }
}

const restStatus = async (outcome, status) => {
  if ((await outcome).status !== status) throw new Error(`acceptance/rest-status-${status}`);
};

// The scenario is transport-agnostic: live it runs over HTTP; offline it runs against the real
// services and a fake REST rules model, which rehearses projections and parsing, not transport.
async function runScenario({ manifest, call, rest, step }) {
  const ids = manifest.ids();
  const seller = `sellerProfiles/${ids.uids.seller}`;
  const absent = `sellerProfiles/${ids.uids.client}`;
  const movement = `inventoryMovements/${ids.key}`;
  const deny = (name, data, role, code, message, reason) => step(`setSellerProfile denial: ${name}`,
    () => manifest.unchanged(async () => callableDenied(await call('setSellerProfile', data, role), code, message, reason)));

  for (const target of ['client', 'administrator']) {
    await deny(`a ${target} target is not a seller`, { uid: ids.uids[target], displayName: 'No Vendedor' },
      'administrator', 'FAILED_PRECONDITION', DENIAL.notSeller, 'not-a-seller');
  }
  await step('setSellerProfile: administrator names the owned seller', () => manifest.execute('set',
    async (data) => callableSuccess(await call('setSellerProfile', data, 'administrator'))));
  await step('setSellerProfile: identical retry is a no-write replay', () => manifest.unchanged(async () => {
    requireSame(callableSuccess(await call('setSellerProfile', manifest.request('set'), 'administrator')),
      { uid: ids.uids.seller, replayed: true });
  }));
  await step('setSellerProfile: administrator renames the seller', () => manifest.execute('rename',
    async (data) => callableSuccess(await call('setSellerProfile', data, 'administrator'))));
  // After the profile exists, so a wrongful overwrite would also be caught.
  for (const role of ['anonymous', 'unassigned', 'client', 'seller']) {
    await deny(`${role} caller`, { uid: ids.uids.seller, displayName: `Intruso ${role}` }, role,
      ...(role === 'anonymous' ? ['UNAUTHENTICATED', DENIAL.unauthenticated] : ['PERMISSION_DENIED', DENIAL.administrator]));
  }
  await step('stockIntake: administrator creates the owned movement', () => manifest.execute('intake',
    async (data) => callableSuccess(await call('stockIntake', data, 'administrator'))));

  await step('sellerProfiles REST: administrator GET is the exact two-field profile', () => manifest.unchanged(async () => {
    const outcome = await rest(`/${seller}`, 'GET', undefined, 'administrator');
    if (outcome.status !== 200) throw new Error('acceptance/rest-status-200');
    requireSame(restDocument(outcome.body, seller), { displayName: 'Vendedora Renombrada', branchId: ids.branch });
    requireSame(manifest.expected(seller), { displayName: 'Vendedora Renombrada', branchId: ids.branch });
    await restStatus(rest(`/${absent}`, 'GET', undefined, 'administrator'), 404);
  }));
  await step('sellerProfiles REST: every non-administrator GET is denied', () => manifest.unchanged(async () => {
    for (const role of ['seller', 'client', 'unassigned', 'anonymous']) {
      await restStatus(rest(`/${seller}`, 'GET', undefined, role), 403);
    }
    await restStatus(rest(`/${absent}`, 'GET', undefined, 'seller'), 403); // A foreign profile.
  }));
  await step('sellerProfiles REST: administrator LIST is denied', () => manifest.unchanged(async () => {
    await restStatus(rest(':runQuery', 'POST', { structuredQuery: { from: [{ collectionId: 'sellerProfiles' }] } },
      'administrator'), 403);
    await restStatus(rest('/sellerProfiles', 'GET', undefined, 'administrator'), 403);
  }));
  await step('sellerProfiles REST: client create, patch and delete are denied', () => manifest.unchanged(async () => {
    const fields = { displayName: { stringValue: 'Forjado' }, branchId: { stringValue: ids.branch } };
    for (const role of ['administrator', 'seller']) {
      // PATCH of an absent document is evaluated as a create; of the existing one as an update.
      await restStatus(rest(`/${absent}`, 'PATCH', { fields }, role), 403);
      await restStatus(rest(`/${seller}`, 'PATCH', { fields }, role), 403);
      await restStatus(rest(`/${seller}`, 'DELETE', undefined, role), 403);
    }
  }));

  const occurredAt = (document) => restValue(document?.fields?.occurredAt);
  const movements = (outcome, exact) => {
    const documents = queryDocuments(outcome);
    if (documents.length > 50 || documents.some((document, index) => index > 0
      && occurredAt(documents[index - 1]) < occurredAt(document))) throw new Error('acceptance/query-order');
    const own = documents.filter((document) => document?.name === `${DOCUMENT_NAME}/${movement}`);
    if (own.length !== 1 || (exact && documents.length !== 1)) throw new Error('acceptance/query-rows');
    requireSame(restDocument(own[0], movement), manifest.expected(movement));
  };
  await step('movements REST: administrator newest-first query, unfiltered and by owned branch', () => manifest.unchanged(async () => {
    movements(await rest(':runQuery', 'POST', movementsQuery(), 'administrator'), false);
    movements(await rest(':runQuery', 'POST', movementsQuery(ids.branch), 'administrator'), true);
  }));
  await step('movements REST: seller only with its own branch filter', () => manifest.unchanged(async () => {
    await restStatus(rest(':runQuery', 'POST', movementsQuery(), 'seller'), 403);
    movements(await rest(':runQuery', 'POST', movementsQuery(ids.branch), 'seller'), true);
  }));
}

const BASELINE_AUTH = ['demo-local-administrator', 'demo-local-seller-north'];
const BASELINE_DOCS = [
  'branches/branch-north', 'branches/branch-south', 'products/DEMO-COFFEE', 'products/DEMO-RIBBON',
  'branches/branch-north/stock/DEMO-COFFEE', 'branches/branch-north/stock/DEMO-RIBBON',
  'branches/branch-south/stock/DEMO-COFFEE', 'branches/branch-south/stock/DEMO-RIBBON',
];

// ---------------------------------------------------------------------------
// Offline tests: an in-memory store, the real (pure) services and a fake REST rules model.
// ---------------------------------------------------------------------------

const BASE_TIME = Date.parse('2026-10-10T12:00:00Z');

function fakeStore() {
  const documents = new Map();
  const plain = (value) => {
    if (value instanceof Date) return value.getTime();
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([key, field]) => [key, plain(field)]));
    }
    return value;
  };
  return {
    documents,
    async read(paths) { return paths.map((path) => (documents.has(path) ? plain(copy(documents.get(path))) : null)); },
    async create(path, data) {
      if (documents.has(path)) throw new Error('collision');
      documents.set(path, copy(data));
    },
    async transaction(callback) {
      const pending = [];
      await callback({
        async get(path) {
          assert.equal(pending.length, 0, 'all reads before deletion');
          return documents.has(path) ? plain(copy(documents.get(path))) : null;
        },
        delete(path) { pending.push(path); },
      });
      for (const path of pending) documents.delete(path);
    },
    serviceFirestore() {
      return {
        doc: (path) => ({ path }),
        async runTransaction(callback) {
          const writes = [];
          const result = await callback({
            async get({ path }) {
              const exists = documents.has(path);
              return { exists, data: () => (exists ? copy(documents.get(path)) : undefined) };
            },
            create(reference, data) { writes.push(['create', reference.path, copy(data)]); },
            set(reference, data) { writes.push(['set', reference.path, copy(data)]); },
          });
          for (const [kind, path] of writes) if (kind === 'create' && documents.has(path)) throw new Error('create-only');
          for (const [, path, data] of writes) documents.set(path, data);
          return result;
        },
      };
    },
  };
}

const CLAIMS = {
  administrator: { role: 'administrator' }, seller: { role: 'seller', branchId: `branch-${RUN}` },
  unassigned: { role: 'unassigned' }, client: { role: 'client' },
};

function encodeDocument(path, data) {
  const value = (field) => {
    if (typeof field === 'string') return { stringValue: field };
    if (Number.isSafeInteger(field)) return { integerValue: String(field) };
    if (field instanceof Date) return { timestampValue: field.toISOString() };
    throw new Error('offline/encode');
  };
  return { name: `${DOCUMENT_NAME}/${path}`, fields: Object.fromEntries(Object.entries(data)
    .map(([key, field]) => [key, value(field)])), createTime: 'x', updateTime: 'x' };
}

// Fake REST mirroring the published rules for these two collections only.
function fakeRest(store) {
  const denied = { status: 403, body: { error: { code: 403, status: 'PERMISSION_DENIED' } } };
  return async (suffix, method, body, role) => {
    const auth = CLAIMS[role];
    const administrator = auth?.role === 'administrator';
    const sellerFor = (branchId) => auth?.role === 'seller' && auth.branchId === branchId;
    if (suffix === ':runQuery') {
      const query = body.structuredQuery;
      const filter = query.where?.fieldFilter?.value?.stringValue;
      if (query.from[0].collectionId !== 'inventoryMovements' || !(administrator || sellerFor(filter))) return denied;
      const rows = [...store.documents].filter(([path, data]) => /^inventoryMovements\/[^/]+$/.test(path)
        && (filter === undefined || data.branchId === filter))
        .sort(([, a], [, b]) => b.occurredAt - a.occurredAt).slice(0, query.limit);
      return { status: 200, body: rows.length === 0 ? [{ readTime: 'x' }]
        : rows.map(([path, data]) => ({ document: encodeDocument(path, data), readTime: 'x' })) };
    }
    const path = suffix.slice(1);
    const data = store.documents.get(path);
    const allowed = method === 'GET' && (path.startsWith('sellerProfiles/') ? administrator
      : path.startsWith('inventoryMovements/') && (administrator || sellerFor(data?.branchId)));
    if (!allowed || path.split('/').length !== 2) return denied;
    return data === undefined ? { status: 404, body: { error: { code: 404 } } } : { status: 200, body: encodeDocument(path, data) };
  };
}

function rehearsal(options = {}) {
  const store = fakeStore();
  const time = { now: BASE_TIME };
  const manifest = createManifest({ runId: RUN, clock: () => time.now }, store);
  const firestore = store.serviceFirestore();
  const auth = {
    async getUser(uid) {
      const role = Object.keys(CLAIMS).find((name) => uid === `acceptance-${RUN}-${name}`);
      if (!role) throw Object.assign(new Error('missing'), { code: 'auth/user-not-found' });
      return { uid, customClaims: copy(CLAIMS[role]) };
    },
  };
  const real = {
    setSellerProfile: createSellerProfileService({ firestore, auth, environment: SERVICE_ENVIRONMENT }),
    stockIntake: createStockIntakeService({ firestore, now: () => new Date((time.now += 1000)) }),
  };
  const services = Object.fromEntries(Object.entries(real).map(([name, service]) => [name,
    options.wrap?.(name, service, store) ?? service]));
  const call = async (name, data, role) => {
    try {
      const request = { data: copy(data), ...(CLAIMS[role] ? { auth: { uid: `acceptance-${RUN}-${role}`, token: copy(CLAIMS[role]) } } : {}) };
      const result = await services[name](request);
      return { status: 200, body: { result: JSON.parse(JSON.stringify(result)) } };
    } catch (error) {
      if (!(error instanceof SellerProfileError || error instanceof InventoryError)) throw error;
      // Mirrors reasonedHttpsError: details { reason } only when the error carries one.
      return { status: 400, body: { error: { status: error.code.toUpperCase().replaceAll('-', '_'), message: error.message,
        ...(error.reason === undefined ? {} : { details: { reason: error.reason } }) } } };
    }
  };
  const realRest = fakeRest(store);
  const rest = options.rest ? (...args) => options.rest(realRest, ...args) : realRest;
  return { store, manifest, call, rest };
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
  for (const key of Object.keys(LIVE)) {
    assert.throws(() => liveApproval({ ...approved, [key]: undefined }, runtime), /acceptance\/live-approval-required/);
    assert.equal(liveRequested({ ...approved, [key]: undefined }), false, `${key} alone keeps the root skipped`);
  }
  // Neither the sales nor the corrections switch opens this root.
  for (const other of ['LDA_SALES_HTTP_ACCEPTANCE', 'LDA_CORRECTIONS_HTTP_ACCEPTANCE']) {
    assert.equal(liveRequested({ ...approved, LDA_SELLER_PROFILES_HTTP_ACCEPTANCE: undefined, [other]: '1' }), false);
  }
  assert.throws(() => liveApproval({ ...approved, HTTPS_PROXY: 'x' }, runtime), /acceptance\/ambient-override/);
});

test('offline: fake HTTP enforces exact URLs, methods, query collections, redirects and bounds', async () => {
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
  const owned = `sellerProfiles/acceptance-${RUN}-seller`;
  const http = makeHttp({ ...PINNED, ...LIVE }, [owned, 'inventoryMovements/x'], fakeRequest, () => {});
  const query = (collectionId) => ({ structuredQuery: { from: [{ collectionId }] } });
  for (const [url, method, body] of [
    ['http://example.invalid', 'GET'], [`${REST}/sellerProfiles/other`, 'GET'], [`${REST}/sellerProfiles/x/y`, 'GET'],
    [`${BASE}/submitSale`, 'POST', {}], [`${BASE}/setSellerProfile`, 'GET'], [LOGIN, 'DELETE'],
    [`${REST}/inventoryMovements/x`, 'PATCH', {}], [`${REST}/inventoryMovements/x`, 'DELETE'],
    [`${REST}/sellerProfiles`, 'POST', {}], [RUN_QUERY, 'POST', query('sales')], [RUN_QUERY, 'POST', {}],
    [RUN_QUERY, 'POST', { structuredQuery: { from: [{ collectionId: 'sellerProfiles', allDescendants: true }] } }],
    [`${REST}/sellerProfiles/acceptance-${RUN}-seller?currentDocument.exists=false`, 'PATCH', {}],
  ]) await assert.rejects(http(url, method, body), /acceptance\/url-refused/, `${method} ${url}`);
  await assert.rejects(http(LOGIN, 'POST', { text: 'x'.repeat(16385) }), /acceptance\/request-size/);
  assert.equal(calls, 0);
  for (const name of FUNCTIONS) assert.equal((await http(`${BASE}/${name}`, 'POST', {})).status, 200);
  for (const method of ['GET', 'PATCH', 'DELETE']) assert.equal((await http(`${REST}/${owned}`, method)).status, 200);
  for (const collection of QUERY_COLLECTIONS) assert.equal((await http(RUN_QUERY, 'POST', query(collection))).status, 200);
  assert.equal((await http(`${REST}/sellerProfiles`)).status, 200);
  for (mode of ['redirect', 'large']) await assert.rejects(http(LOGIN, 'POST', {}), /acceptance\/http-unknown/);
  await assert.rejects(makeHttp(PINNED, [], fakeRequest)(LOGIN), /acceptance\/live-approval-required/);
});

test('offline: callable envelopes and REST documents and query rows are exact', () => {
  const denied = { status: 400, body: { error: { status: 'FAILED_PRECONDITION', message: DENIAL.notSeller,
    details: { reason: 'not-a-seller' } } } };
  assert.doesNotThrow(() => callableDenied(denied, 'FAILED_PRECONDITION', DENIAL.notSeller, 'not-a-seller'));
  for (const [error, reason] of [
    [denied.body.error, undefined], [denied.body.error, 'invalid-branch-claim'],
    [{ ...denied.body.error, details: { reason: 'not-a-seller', extra: 1 } }, 'not-a-seller'],
    [{ ...denied.body.error, stack: 'private' }, 'not-a-seller'],
    [{ ...denied.body.error, message: 'other' }, 'not-a-seller'],
  ]) {
    assert.throws(() => callableDenied({ status: 400, body: { error } }, 'FAILED_PRECONDITION', DENIAL.notSeller, reason),
      /acceptance\/callable-denial/);
  }
  assert.throws(() => callableDenied({ status: 200, body: { result: {} } }, 'PERMISSION_DENIED', DENIAL.administrator),
    /acceptance\/callable-denial/);
  assert.deepEqual(callableSuccess({ status: 200, body: { result: { a: 1 } } }), { a: 1 });
  assert.throws(() => callableSuccess({ status: 200, body: { result: {}, extra: 1 } }), /acceptance\/callable-result/);

  const path = 'inventoryMovements/m';
  const document = encodeDocument(path, { type: 'stock-intake', quantityScaled: 5, occurredAt: new Date(BASE_TIME) });
  assert.deepEqual(restDocument(document, path), { type: 'stock-intake', quantityScaled: 5, occurredAt: BASE_TIME });
  assert.equal(restValue({ timestampValue: '2026-10-10T12:00:00.123456789Z' }), BASE_TIME + 123);
  assert.equal(restValue({ integerValue: '-7' }), -7);
  for (const forged of [{ booleanValue: true }, { integerValue: 5 }, { integerValue: '9007199254740993' },
    { integerValue: '05' }, { timestampValue: '2026-10-10 12:00:00Z' }, { timestampValue: '2026-10-10T12:00:00+01:00' },
    { stringValue: 'a', integerValue: '1' }, { nullValue: null }, { mapValue: { fields: {} } }, null, ['x']]) {
    assert.throws(() => restValue(forged), /acceptance\/rest-value/);
  }
  assert.throws(() => restDocument(document, 'inventoryMovements/other'), /acceptance\/rest-document/);
  assert.throws(() => restDocument({ ...document, extra: 1 }, path), /acceptance\/rest-document/);
  const { createTime, ...missing } = document;
  assert.throws(() => restDocument(missing, path), /acceptance\/rest-document/);

  assert.deepEqual(queryDocuments({ status: 200, body: [{ readTime: 'x' }] }), []);
  assert.deepEqual(queryDocuments({ status: 200, body: [{ document, readTime: 'x' }, { readTime: 'x', done: true }] }), [document]);
  for (const outcome of [{ status: 403, body: [] }, { status: 200, body: {} }, { status: 200, body: [{ document }] },
    { status: 200, body: [{ document, readTime: 'x', skippedResults: 1 }] }, { status: 200, body: [null] }]) {
    assert.throws(() => queryDocuments(outcome), /acceptance\/query-shape/);
  }
});

test('offline: the full scenario rehearsed against the real services matches every projection and cleans up', async () => {
  const { store, manifest, call, rest } = rehearsal();
  await manifest.seed();
  const steps = [];
  await runScenario({ manifest, call, rest, step: (name, work) => { steps.push(name); return work(); } });
  assert.equal(steps.length, 16);
  assert.deepEqual(manifest.view().completed, SUCCESS_ORDER);
  assert.deepEqual(store.documents.get(`sellerProfiles/acceptance-${RUN}-seller`),
    { displayName: 'Vendedora Renombrada', branchId: `branch-${RUN}` });
  await manifest.cleanup();
  assert.equal(store.documents.size, 0);
  await assert.rejects(manifest.cleanup(), /acceptance\/cleanup-not-retryable/);
});

test('offline: forged success responses and documents make the run uncertain and retain everything', async () => {
  const forgeries = {
    'request branch adopted': (name, service, store) => name === 'setSellerProfile' && (async (request) => {
      const result = await service(request);
      store.documents.set(`sellerProfiles/${request.data.uid}`, { displayName: request.data.displayName, branchId: 'branch-north' });
      return result;
    }),
    'self-blessed replay': (name, service) => name === 'setSellerProfile'
      && (async (request) => ({ ...(await service(request)), replayed: true })),
    'name snapshot in the movement': (name, service, store) => name === 'stockIntake' && (async (request) => {
      const result = await service(request);
      const path = `inventoryMovements/${request.data.idempotencyKey}`;
      store.documents.set(path, { ...store.documents.get(path), displayName: 'Vendedora' });
      return result;
    }),
    'extra response field': (name, service) => name === 'stockIntake'
      && (async (request) => ({ ...(await service(request)), actorName: 'x' })),
  };
  for (const [label, wrap] of Object.entries(forgeries)) {
    const { store, manifest, call, rest } = rehearsal({ wrap: (...args) => wrap(...args) || undefined });
    await manifest.seed();
    await assert.rejects(runScenario({ manifest, call, rest, step: direct }), UNCERTAIN, label);
    await assert.rejects(manifest.cleanup(), RETAINED, label);
    assert.ok(store.documents.size >= 2, `${label}: nothing deleted`);
  }
});

test('offline: a denial that writes or a REST rule drift fails the observation and retains everything', async () => {
  const leak = rehearsal({ wrap: (name, service, store) => name === 'setSellerProfile' && (async (request) => {
    if (request.auth?.token?.role !== 'administrator') {
      store.documents.set(`sellerProfiles/acceptance-${RUN}-seller`, { displayName: 'Intruso', branchId: `branch-${RUN}` });
    }
    return service(request);
  }) || undefined });
  const drifts = [
    // The seller may read its own profile, a LIST succeeds, or a client delete is accepted.
    (real, suffix, method, body, role) => (role === 'seller' && method === 'GET' && suffix.includes('sellerProfiles/')
      ? { status: 200, body: {} } : real(suffix, method, body, role)),
    (real, suffix, method, body, role) => (suffix === '/sellerProfiles' ? { status: 200, body: {} } : real(suffix, method, body, role)),
    (real, suffix, method, body, role) => (method === 'DELETE' ? { status: 200, body: {} } : real(suffix, method, body, role)),
    // A seller's unfiltered query is allowed, or the owned movement drops out of the filtered result.
    (real, suffix, method, body, role) => (role === 'seller' && suffix === ':runQuery' && !body.structuredQuery.where
      ? { status: 200, body: [{ readTime: 'x' }] } : real(suffix, method, body, role)),
    async (real, suffix, method, body, role) => (suffix === ':runQuery' && body.structuredQuery.where
      ? { status: 200, body: [{ readTime: 'x' }] } : real(suffix, method, body, role)),
    // A filtered result leaks a movement of another branch next to the owned one.
    async (real, suffix, method, body, role) => {
      const outcome = await real(suffix, method, body, role);
      if (suffix !== ':runQuery' || !body.structuredQuery.where || outcome.status !== 200) return outcome;
      const [row] = outcome.body;
      return { ...outcome, body: [row, { ...row, document: { ...row.document, name: `${DOCUMENT_NAME}/inventoryMovements/other` } }] };
    },
  ];
  for (const sample of [leak, ...drifts.map((drift) => rehearsal({ rest: drift }))]) {
    await sample.manifest.seed();
    await assert.rejects(runScenario({ ...sample, step: direct }), OBSERVATION);
    await assert.rejects(sample.manifest.cleanup(), RETAINED);
    assert.ok(sample.store.documents.size >= 2);
  }
});

test('offline: preexisting planned paths and order violations never authorize writes or deletion', async () => {
  const sample = rehearsal();
  const foreign = { displayName: 'Previo', branchId: 'branch-north' };
  sample.store.documents.set(`sellerProfiles/acceptance-${RUN}-seller`, foreign);
  await assert.rejects(sample.manifest.seed(), /acceptance\/seed-uncertain/);
  assert.equal(sample.store.documents.size, 1, 'no seed after a failed preflight');
  await assert.rejects(sample.manifest.execute('set', async () => ({})), /acceptance\/operation-order/);
  await assert.rejects(sample.manifest.cleanup(), RETAINED);
  assert.deepEqual(sample.store.documents.get(`sellerProfiles/acceptance-${RUN}-seller`), foreign);

  const ordered = rehearsal();
  await assert.rejects(ordered.manifest.execute('set', async () => ({})), /acceptance\/operation-order/);
  await ordered.manifest.seed();
  await assert.rejects(ordered.manifest.execute('intake', async () => ({})), /acceptance\/operation-order/);
  await assert.rejects(ordered.manifest.seed(), /acceptance\/seed-once/);
  assert.throws(() => ordered.manifest.request('delete'), /acceptance\/unknown-operation/);
  assert.throws(() => ordered.manifest.expected('sellerProfiles/demo-local-seller-north'), /acceptance\/unplanned/);
  assert.throws(() => createManifest({ runId: 'not-a-uuid' }, ordered.store), /acceptance\/context/);
  // A late write after a deadline is never adopted: the run stays uncertain.
  await assert.rejects(ordered.manifest.execute('set', () => new Promise(() => {}), 5), UNCERTAIN);
  await assert.rejects(ordered.manifest.cleanup(), RETAINED);
  assert.equal(ordered.store.documents.size, 2);
});

test('offline: Timestamps, the local certificate credential and initialization errors stay strict', () => {
  const stamp = (seconds, nanoseconds) => ({ seconds, nanoseconds,
    toMillis: () => seconds * 1000 + Math.floor(nanoseconds / 1e6) });
  assert.equal(normalizeRecord(stamp(1, 123456789)), 1123);
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

// Called ONLY inside the validated, explicitly opted-in live test. Disposal and every cleanup
// are registered before initialization and before any data write.
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
    app = initializeApp({ projectId: PROJECT, credential: ownedCredential(cert) }, `owned-seller-profiles-${runId}`);
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
    manifest = createManifest({ runId }, store);
    return { runId, authManifest, auth, manifest, registerPreservation(check) { preserve = check; } };
  } catch (error) { throw initializationError(error); }
}

// No live acceptance RED can be established before authorized emulator execution. The offline
// rehearsal above runs the same scenario against the real services, which is not transport proof.
test('live SP-05 setSellerProfile, sellerProfiles rules and administrator movements query over HTTP (pending authorization)',
  { skip: !liveRequested(process.env) }, async (t) => {
    liveApproval(process.env); // Fail closed BEFORE SDK imports, handles or writes.
    const runtime = await openLive(t, process.env);
    const { runId, authManifest, auth, manifest } = runtime;
    const identities = Object.fromEntries([...authManifest.entries.keys()].map((role) => [role, {
      email: `${role}-${randomUUID()}@demo-lda-inventory.invalid`, password: randomUUID() + randomUUID(),
    }]));
    const provisioned = await provisionOwnedIdentities({ auth, manifest: authManifest, createParams: identities });
    if (provisioned.provisioned.some((entry) => entry.outcome !== 'owned')) throw new Error('acceptance/auth-provision');
    const http = makeHttp(process.env, [...BASELINE_DOCS, ...manifest.paths()]);
    const tokens = { anonymous: undefined };
    for (const [role, identity] of Object.entries(identities)) {
      const outcome = await http(LOGIN, 'POST', { ...identity, returnSecureToken: true });
      const planned = authManifest.entries.get(role);
      if (outcome.status !== 200 || outcome.body.localId !== planned.uid
        || typeof outcome.body.idToken !== 'string' || outcome.body.idToken.length < 20) {
        throw new Error('acceptance/login');
      }
      tokens[role] = outcome.body.idToken; // Never assert, log or persist token material.
      requireSame((await auth.getUser(planned.uid)).customClaims, { acceptanceRunId: runId, role,
        ...(role === 'seller' ? { branchId: `branch-${runId}` } : {}) });
    }
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
    const rest = (suffix, method, body, role) => http(`${REST}${suffix}`, method, body, tokens[role]);
    await runScenario({ manifest, call, rest, step: (name, work) => t.test(name, work) });
    // Teardown verifies Firestore exact contents transactionally, Auth privately, and
    // baseline preservation. Auth's nontransactional verify-delete race remains.
  });
