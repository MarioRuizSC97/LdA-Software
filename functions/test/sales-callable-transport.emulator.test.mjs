// FUNC-02A preparation: offline discovery must never initialize an SDK or use HTTP.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FUNCTIONS = ['createProduct', 'setProductPrice', 'stockIntake'];
const BASE = `http://127.0.0.1:5001/${PROJECT}/us-south1`;
const REST = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const LOGIN = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only';
const same = (a, b) => canonical(a) === canonical(b);
const requireSame = (a, b) => { if (!same(a, b)) throw new Error('acceptance/content-mismatch'); };
function decimal(value, precision) {
  const [whole, fraction = ''] = value.split('.');
  return Number(BigInt(whole) * 10n ** BigInt(precision) + BigInt(fraction.padEnd(precision, '0')));
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
  const branch = `branch-${runId}`;
  const other = `${branch}-other`;
  const key = (label) => `http-${runId}-${label}`;
  const paths = {
    branches: [`branches/${branch}`, `branches/${other}`],
    createReceipt: `productCreationReceipts/${key('create')}`,
    priceAudit: `productPriceAudits/${key('price')}`,
    priceReceipt: `productPriceUpdateReceipts/${key('price')}`,
    entry: `stockIntakeEntries/${key('intake')}`,
    movement: `inventoryMovements/${key('intake')}`,
    intakeReceipt: `stockIntakeReceipts/${key('intake')}`,
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
  };
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
    const input = copy(requests[kind]);
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
      const timestamp = stamp(records.get(kind === 'price' ? paths.priceReceipt : paths.intakeReceipt)?.completedAt, before, after);
      if (kind === 'price') {
        const pricing = { listedPriceCentavos: decimal(input.listedPriceMxn, 2), currency: 'MXN', priceMode: input.priceMode,
          ivaTreatment: input.ivaTreatment, ivaRateBasisPoints: decimal(input.ivaRatePercent, 2) };
        const bareResult = { auditId: input.idempotencyKey, productId, pricing };
        requireSame(result, { ...bareResult, replayed: false });
        expected.set(`products/${productId}`, { ...entries.get(`products/${productId}`).expected,
          pricing, pricingUpdatedAt: timestamp, lastPricingAuditId: input.idempotencyKey });
        expected.set(paths.priceAudit, { productId, previousAuditId: null, oldPricing: null,
          newPricing: pricing, changedAt: timestamp, actorId });
        expected.set(paths.priceReceipt, { fingerprint: JSON.stringify({ actorId, productId, pricing }),
          result: bareResult, completedAt: timestamp, actorId });
      } else {
        const spec = requests.create.quantitySpec;
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
        expected.set(`branches/${branch}/stock/${productId}`, { quantityScaled, ...spec,
          updatedAt: timestamp, lastMovementId: input.idempotencyKey });
        expected.set(`costs/${productId}`, { latestUnitCostCentavos: unitCostCentavos, currency: 'MXN',
          sourceEntryId: input.idempotencyKey, updatedAt: timestamp });
        expected.set(paths.intakeReceipt, { fingerprint: JSON.stringify({ branchId: branch, productId,
          quantity: input.quantity, unitCostCentavos }), result: bareResult, completedAt: timestamp, actorId });
      }
      for (const [path, entry] of entries) requireSame(records.get(path), expected.has(path) ? expected.get(path) : entry.expected);
    }
    for (const [path, value] of expected) entries.set(path, { expected: copy(value), state: 'confirmed' });
    completed.add(kind);
  };
  const request = (kind) => {
    if (!Object.hasOwn(requests, kind)) throw new Error('acceptance/unknown-operation');
    return copy({ ...requests[kind], ...(kind === 'create' ? {} : { productId }) });
  };
  return Object.freeze({
    paths: () => copy(paths), request,
    view: () => ({ runId, productId, uncertain, dynamicSlots: ['product', 'cost', 'ownStock', 'foreignStock'],
      entries: [...entries].map(([path, entry]) => ({ path, ...copy(entry) })) }),
    denialKey(label) { if (!denialLabels.includes(label)) throw new Error('acceptance/denial-plan'); return key(label); },
    async seedBranches() {
      if (seeded || cleanupStarted) throw new Error('acceptance/seed-once');
      seeded = true;
      try {
        validate(await read());
        uncertain = true;
        for (const path of paths.branches) {
          const expected = { name: path.slice(9), acceptanceRunId: runId };
          await deadline(() => store.create(path, copy(expected)));
          const actual = (await read()).get(path);
          requireSame(actual, expected);
          entries.set(path, { state: 'confirmed', expected });
        }
        uncertain = false;
      } catch { uncertain = true; throw new Error('acceptance/seed-uncertain'); }
    },
    async execute(kind, transport, timeoutMs = 10000) {
      if (!seeded || uncertain || active || cleanupStarted || completed.has(kind)
        || (kind !== 'create' && !productId) || (kind === 'intake' && !completed.has('price'))) {
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
    assert.throws(() => gate({ ...PINNED, [key]: 'wrong' }, { executable: NODE, version: 'v24.21.0' }));
  }
  for (const key of ['GOOGLE_APPLICATION_CREDENTIALS', 'FIREBASE_CONFIG', 'HTTPS_PROXY', 'NODE_OPTIONS']) {
    assert.throws(() => gate({ ...PINNED, [key]: 'override' }, { executable: NODE, version: 'v24.21.0' }));
  }
  assert.throws(() => gate(PINNED, { executable: NODE, version: 'v24.20.0' }));
  assert.throws(() => gate(PINNED, { executable: '/usr/bin/node', version: 'v24.21.0' }));
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
    }));
    await assert.rejects(sample.manifest.cleanup());
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
  await assert.rejects(sample.manifest.execute('create', () => pending, 2));
  const proof = creation(sample.manifest);
  sample.store.documents.set(`products/${proof.result.productId}`, proof.product);
  sample.store.documents.set(sample.manifest.paths().createReceipt, proof.receipt);
  finish(proof.result);
  await Promise.resolve();
  assert.equal(sample.manifest.view().productId, null);
  await assert.rejects(sample.manifest.execute('create', () => proof.result));
  await assert.rejects(sample.manifest.cleanup());
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
  await assert.rejects(sample.manifest.execute('create', () => proof.result));
  await sample.manifest.cleanup();
  const deletes = sample.store.events.filter(([event]) => event === 'delete').map(([, path]) => path);
  assert.deepEqual(deletes.slice(-3), [`products/${proof.result.productId}`, ...sample.manifest.paths().branches]);
  await assert.rejects(sample.manifest.cleanup());
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
    }));
    await assert.rejects(sample.manifest.cleanup());
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
  assert.throws(() => liveApproval({ ...PINNED, LDA_SALES_HTTP_ACCEPTANCE: '0' }));
  assert.throws(() => liveApproval({ ...PINNED, LDA_SALES_HTTP_ACCEPTANCE: '1' }));
  assert.throws(() => normalizeRecord({ toMillis: () => 1000, nanoseconds: 1 }));
  assert.throws(() => normalizeRecord({ createdAt: 1000 }));
  assert.equal(normalizeRecord({ toMillis: () => 1000, nanoseconds: 0 }), 1000);
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
    if (forged) { await assert.rejects(invoke()); await assert.rejects(sample.manifest.cleanup()); }
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
  await assert.rejects(makeHttp(PINNED, [], fakeRequest)(LOGIN));
});

// Exact source-derived demo preservation proposal, NOT evidence of current contents.
const BASELINE_AUTH = ['demo-local-administrator', 'demo-local-seller-north'];
const BASELINE_DOCS = [
  'branches/branch-north', 'branches/branch-south', 'products/DEMO-COFFEE', 'products/DEMO-RIBBON',
  'branches/branch-north/stock/DEMO-COFFEE', 'branches/branch-north/stock/DEMO-RIBBON',
  'branches/branch-south/stock/DEMO-COFFEE', 'branches/branch-south/stock/DEMO-RIBBON',
];

function liveApproval(environment) {
  gate(environment);
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
    const milliseconds = value.toMillis();
    if (!Number.isSafeInteger(milliseconds) || value.nanoseconds % 1000000 !== 0) {
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
async function openLive(t, environment) {
  liveApproval(environment);
  liveApproval(process.env);
  const require = approvedRequire();
  const authEntry = `${SDK_ROOT}/firebase-admin/lib/auth/index.js`;
  if (require.resolve('firebase-admin/auth') !== authEntry || realpathSync(authEntry) !== authEntry
    || !lstatSync(authEntry).isFile()) throw new Error('acceptance/auth-sdk-resolution');
  const { initializeApp, deleteApp } = require('firebase-admin/app');
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
    // Emulator-local in-memory token provider; no cert, ADC, default app or discovery.
    app = initializeApp({ projectId: PROJECT, credential: {
      getAccessToken: async () => ({ access_token: 'owner', expires_in: 3600 }),
    } }, `owned-http-${runId}`);
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
  } catch { throw new Error('acceptance/runtime-initialization'); }
}

function callableSuccess(outcome) {
  if (outcome.status !== 200 || !same(Object.keys(outcome.body), ['result'])) throw new Error('acceptance/callable-result');
  return outcome.body.result;
}
function callableDenied(outcome, code) {
  if (outcome.status === 200 || !same(Object.keys(outcome.body), ['error']) || outcome.body.error?.status !== code) {
    throw new Error('acceptance/callable-denial');
  }
}

// No live acceptance RED can be established before authorized emulator execution.
// The skipped root contains future real transport cases, not injected service proof.
test('live FUNC-02A HTTP/Auth/catalog/pricing/intake/client boundaries (pending authorization)',
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
    const call = (kind, input, token) => http(`${BASE}/${FUNCTIONS[['create', 'price', 'intake'].indexOf(kind)]}`,
      'POST', { data: input }, token);
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
    // Teardown verifies Firestore exact contents transactionally, Auth privately,
    // and baseline preservation. Auth's nontransactional verify-delete race remains.
  });
