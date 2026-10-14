/**
 * EA-02 — real Firestore acceptance for stock transfers on the isolated emulator.
 *
 * Run it through `scripts/test-transfers-isolated.mjs`, which starts the cached
 * standalone Firestore 1.22.0 jar on 127.0.0.1:8280, proves that bound socket is
 * owned by the child it spawned, exports the marker below, and stops only that
 * child. Running `node --test test/transfers.emulator.test.mjs` directly against
 * a hand-made environment is not the supported entry point.
 *
 * Socket truthfulness: omitting the jar's websocket/web-channel flags does not
 * mean the emulator opens no other socket. The reviewed 1.22.0 jar starts its own
 * WebSocket server on an ephemeral loopback port (observed
 * `Started WebSocket server on ws://127.0.0.1:63189` in run
 * cef6da76-6e32-4acd-a64f-a6ffd1f4d91a). The runner's isolation audit therefore
 * allows owned, non-reserved loopback listeners and refuses a reserved main port
 * or any non-loopback bind. This file speaks gRPC to 127.0.0.1:8280 only and
 * never connects to that websocket.
 *
 * Proven here, against real Firestore transactions and real transaction
 * contention: quantity conservation with exact before/after balances, paired leg
 * signs, written projection shape, atomic multi-product transfer, an untouched
 * third product, an absent destination projection, sequential and concurrent
 * replay with exactly one transfer record, one receipt and one movement pair per
 * line, payload-collision refusal with no writes, insufficient-source rollback
 * with no stock, audit or receipt, an unknown-branch refusal, and competing
 * distinct keys where only one submission can succeed without underflow.
 *
 * Isolation: every scenario owns freshly seeded branches, products and balances
 * derived from the run uuid, so no case can consume another case's stock and no
 * expectation depends on execution order. Quantities are read back through
 * helpers that reject undefined/NaN, and absence must be asserted explicitly, so
 * a mistyped fixture key fails the run instead of passing conservation. Every
 * document path a submission can create is registered before the first write and
 * deleted by this file, followed by an explicit absent-verification pass. There
 * is no clearFirestore, import, export, Auth emulator, token request or external
 * network call, and direct service invocation with in-memory admin auth fixtures
 * does not prove real onCall transport, tokens, HTTP, CORS, browser or mobile
 * behaviour.
 */
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

const PROJECT_ID = 'demo-lda-inventory';
const ISOLATED_ADDRESS = '127.0.0.1:8280';
const RUN_MARKER = 'LDA_TRANSFERS_EMULATOR_RUN_ID';
const RUN_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMBIENT_OVERRIDES = Object.freeze([
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIREBASE_FIRESTORE_EMULATOR_ADDRESS',
  'FIRESTORE_PREFER_REST',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'GOOGLE_CLOUD_PROJECT',
  'GCLOUD_UNIVERSE_DOMAIN',
  'GOOGLE_API_USE_MTLS_ENDPOINT',
  'GOOGLE_API_USE_CLIENT_CERTIFICATE',
  'HTTP_PROXY', 'HTTPS_PROXY', 'GRPC_PROXY',
  'http_proxy', 'https_proxy', 'grpc_proxy',
]);
const GATE_KEYS = [RUN_MARKER, 'GCLOUD_PROJECT', 'FIRESTORE_EMULATOR_HOST', 'FUNCTIONS_EMULATOR'];
const PIECE_SPEC = Object.freeze({ unit: 'piece', precision: 0 });
const METER_SPEC = Object.freeze({ unit: 'meter', precision: 2 });
const KG_SPEC = Object.freeze({ unit: 'kilogram', precision: 3 });

// An entirely unconfigured environment is a normal unit run and skips. Anything
// partial or unsafe fails closed, before firebase-admin is even imported, so it
// can never fall through to application default credentials or the main emulator.
const configured = GATE_KEYS.some((key) => process.env[key] !== undefined);
if (!configured) {
  test('transfers isolated emulator acceptance', { skip: `${RUN_MARKER} and the isolated emulator environment are not configured` }, () => {});
}

function gateProblems(env) {
  const problems = [];
  if (!RUN_ID_PATTERN.test(env[RUN_MARKER] ?? '')) problems.push(`${RUN_MARKER} must be a fresh lowercase uuid`);
  if (env.FIRESTORE_EMULATOR_HOST !== ISOLATED_ADDRESS) problems.push(`FIRESTORE_EMULATOR_HOST must be ${ISOLATED_ADDRESS}`);
  if (env.GCLOUD_PROJECT !== PROJECT_ID) problems.push(`GCLOUD_PROJECT must be ${PROJECT_ID}`);
  if (env.FUNCTIONS_EMULATOR !== 'true') problems.push('FUNCTIONS_EMULATOR must be true');
  for (const key of AMBIENT_OVERRIDES) {
    if (env[key] !== undefined) problems.push(`${key} must be unset: this suite never leaves the isolated emulator`);
  }
  return problems;
}

async function createContext() {
  const { cert, deleteApp, initializeApp } = await import('firebase-admin/app');
  const { getFirestore } = await import('firebase-admin/firestore');
  const { InventoryError } = await import('../src/inventory.js');
  const { createTransferService } = await import('../src/transfers.js');

  const runId = process.env[RUN_MARKER];
  // A throwaway RSA key only signs the local emulator as "admin"; the private
  // key never leaves this closure and is never persisted or printed.
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
  const app = initializeApp({
    projectId: PROJECT_ID,
    credential: cert({
      projectId: PROJECT_ID,
      clientEmail: 'firestore-emulator@example.invalid',
      privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
    }),
  }, `transfers-isolated-${randomUUID()}`);
  assert.equal(app.options.projectId, PROJECT_ID);

  const firestore = getFirestore(app);
  // Explicit emulator routing, identical to the guard's host, and legal only
  // because no request has been issued on this client yet.
  firestore.settings({ host: ISOLATED_ADDRESS, ssl: false });

  return {
    app,
    firestore,
    runId,
    InventoryError,
    transfer: createTransferService({ firestore, environment: process.env }),
    deleteApp,
  };
}

let context = null;
if (configured) {
  // Fails closed before firebase-admin is imported, so a half-configured shell
  // can never fall through to application default credentials or the main port.
  const problems = gateProblems(process.env);
  if (problems.length > 0) throw new Error(`refusing the isolated transfers suite: ${problems.join('; ')}`);
  context = await createContext();
}

if (context) defineTransfersAcceptance(context);

function defineTransfersAcceptance({ app, firestore, runId, transfer, InventoryError, deleteApp }) {
  const upperRun = runId.toUpperCase();
  const administrator = `${runId}-administrator`;
  const ownedPaths = new Set();
  const own = (path) => {
    ownedPaths.add(path);
    return firestore.doc(path);
  };

  // ------------------------------------------------------------- assertions --
  // A stored quantity is either a real safe integer or an explicit absence.
  // Requiring that here is what keeps conservation from passing on undefined.
  function requireScaled(label, value) {
    assert.notEqual(value, undefined, `${label} is undefined: the fixture key or product is missing`);
    assert.notEqual(value, null, `${label} is null: the projection does not exist`);
    assert.equal(typeof value, 'number', `${label} must be a number, received ${typeof value}`);
    assert.ok(Number.isSafeInteger(value), `${label} must be a safe integer, received ${value}`);
    return value;
  }
  function requireNonNegative(label, value) {
    requireScaled(label, value);
    assert.ok(value >= 0, `${label} must never be negative, received ${value}`);
    return value;
  }
  function absentAsZero(label, value) {
    assert.equal(value, null, `${label} must be absent in this scenario, received ${value}`);
    return 0;
  }

  const legPath = (idempotencyKey, index, leg) => `inventoryMovements/transfer-${idempotencyKey}-${index}-${leg}`;

  // A transfer's movement ids derive only from its key and line index, so the
  // complete id space of one submission is enumerable: index 0..lineCount on both
  // legs. Enumerating the extra index proves no third leg and no second execution
  // exists, without depending on collection-group index behaviour the isolated
  // jar does not configure.
  async function executedLegs(idempotencyKey, lineCount) {
    const indexes = Array.from({ length: lineCount + 1 }, (_, index) => index);
    const candidates = indexes.flatMap((index) => [
      legPath(idempotencyKey, index, 'out'),
      legPath(idempotencyKey, index, 'in'),
    ]);
    for (const path of candidates) ownedPaths.add(path);
    const states = await existsFor(candidates);
    return candidates.filter((path) => states[path]);
  }

  async function read(path) {
    return firestore.doc(path).get();
  }
  async function existsFor(paths) {
    const unique = [...new Set(paths)];
    const snapshots = await Promise.all(unique.map((path) => read(path)));
    return Object.fromEntries(snapshots.map((snapshot, index) => [unique[index], snapshot.exists]));
  }
  // Timestamps and nested values are normalized so a before/after comparison of
  // the same stored bytes is what the rollback assertions actually check.
  function plain(value) {
    if (value === null || value === undefined) return value;
    if (typeof value?.toMillis === 'function') return `timestamp:${value.toMillis()}`;
    if (value instanceof Date) return `timestamp:${value.getTime()}`;
    if (Array.isArray(value)) return value.map(plain);
    if (typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([field, nested]) => [field, plain(nested)]));
    }
    return value;
  }
  async function projection(paths) {
    const unique = [...new Set(paths)];
    const snapshots = await Promise.all(unique.map((path) => read(path)));
    return Object.fromEntries(snapshots.map((snapshot, index) => [
      unique[index],
      snapshot.exists ? plain(snapshot.data()) : null,
    ]));
  }
  async function rejectsCode(operation, code) {
    await assert.rejects(operation, (error) => {
      assert.ok(error instanceof InventoryError, `expected an InventoryError, received ${error}`);
      assert.equal(error.code, code);
      return true;
    });
  }

  /**
   * One scenario, one independent world. Branches, products and balances are
   * derived from the scenario name plus the run uuid, every path it can ever
   * create is registered before the first write, and the seed is committed in a
   * single batch so no case inherits another case's stock or ordering.
   */
  async function createScenario(name, { specs, source, destination, key = name }) {
    const ids = Object.fromEntries(Object.keys(specs).map((logical) => [
      logical, `XFER-${upperRun}-${name.toUpperCase()}-${logical.toUpperCase()}`,
    ]));
    const branches = {
      source: `branch-${runId}-${name}-src`,
      destination: `branch-${runId}-${name}-dst`,
      absent: `branch-${runId}-${name}-ghost`,
    };
    const idempotencyKey = `${runId}-${key}`;
    const stockPath = (branch, logical) => `branches/${branches[branch]}/stock/${ids[logical]}`;

    for (const path of [
      `branches/${branches.source}`,
      `branches/${branches.destination}`,
      `branches/${branches.absent}`,
      ...Object.values(ids).map((productId) => `products/${productId}`),
      ...Object.keys(specs).flatMap((logical) => [stockPath('source', logical), stockPath('destination', logical)]),
    ]) ownedPaths.add(path);

    function registerSubmission(submissionKey, lines) {
      const created = [
        `transfers/${submissionKey}`,
        `transferSubmissionReceipts/${submissionKey}`,
        ...lines.map((_, index) => legPath(submissionKey, index, 'out')),
        ...lines.map((_, index) => legPath(submissionKey, index, 'in')),
        ...lines.map(({ logical }) => stockPath('source', logical)),
        ...lines.map(({ logical }) => stockPath('destination', logical)),
      ];
      for (const path of created) ownedPaths.add(path);
      return created;
    }

    const batch = firestore.batch();
    batch.create(own(`branches/${branches.source}`), { name: `${name} source`, testRun: runId });
    batch.create(own(`branches/${branches.destination}`), { name: `${name} destination`, testRun: runId });
    for (const [logical, spec] of Object.entries(specs)) {
      batch.create(own(`products/${ids[logical]}`), { name: ids[logical], quantitySpec: spec, testRun: runId });
    }
    for (const [branch, balances] of [['source', source], ['destination', destination]]) {
      for (const [logical, quantityScaled] of Object.entries(balances ?? {})) {
        requireScaled(`${name} ${branch} ${logical} seed`, quantityScaled);
        assert.ok(quantityScaled >= 0, `${name} ${branch} ${logical} seed must not be negative`);
        batch.create(own(stockPath(branch, logical)), {
          quantityScaled, ...specs[logical], testRun: runId,
        });
      }
    }
    await batch.commit();

    async function units(branch, logical) {
      const snapshot = await read(stockPath(branch, logical));
      if (!snapshot.exists) return null;
      return requireScaled(`${name} ${branch} ${logical}`, snapshot.data().quantityScaled);
    }
    async function balances(logicals = Object.keys(specs)) {
      const reads = logicals.flatMap((logical) => [
        units('source', logical).then((value) => [`source.${logical}`, value]),
        units('destination', logical).then((value) => [`destination.${logical}`, value]),
      ]);
      return Object.fromEntries(await Promise.all(reads));
    }
    function request(lines, overrides = {}, submissionKey = idempotencyKey) {
      return {
        auth: { uid: administrator, token: { role: 'administrator' } },
        data: {
          idempotencyKey: submissionKey,
          sourceBranchId: branches.source,
          destinationBranchId: branches.destination,
          lines: lines.map(({ logical, quantity }) => ({ productId: ids[logical], quantity })),
          ...overrides,
        },
      };
    }

    return {
      name, ids, specs, branches, idempotencyKey, stockPath, request, units, balances, registerSubmission,
      submission: (lines, overrides, submissionKey) => transfer(request(lines, overrides, submissionKey)),
    };
  }

  // ------------------------------------------------------------------ cases --
  test('real Firestore keeps every transfer scenario conserved, replayed and atomic', async (t) => {
    t.after(async () => {
      const paths = [...ownedPaths].sort((a, b) => b.split('/').length - a.split('/').length);
      for (let index = 0; index < paths.length; index += 400) {
        const batch = firestore.batch();
        for (const path of paths.slice(index, index + 400)) batch.delete(firestore.doc(path));
        await batch.commit();
      }
      const leftovers = await Promise.all(paths.map((path) => read(path)));
      assert.deepEqual(
        leftovers.filter((snapshot) => snapshot.exists).map((snapshot) => snapshot.ref.path),
        [],
        'every owned fixture path must be gone after cleanup',
      );
      await deleteApp(app);
    });

    await t.test('an atomic multi-product transfer conserves both pairs and spares a third product', async () => {
      const s = await createScenario('multi', {
        specs: { piece: PIECE_SPEC, meter: METER_SPEC, kg: KG_SPEC },
        source: { piece: 12, meter: 500, kg: 2_000 },
        destination: { piece: 3 },
      });
      const lines = [{ logical: 'piece', quantity: '2' }, { logical: 'meter', quantity: '1.50' }];
      s.registerSubmission(s.idempotencyKey, lines);

      const pieceBefore = { source: await s.units('source', 'piece'), destination: await s.units('destination', 'piece') };
      const meterBefore = { source: await s.units('source', 'meter'), destination: await s.units('destination', 'meter') };
      const kgBefore = await s.balances(['kg']);
      assert.equal(pieceBefore.source, 12);
      assert.equal(pieceBefore.destination, 3);
      assert.equal(meterBefore.source, 500);
      assert.equal(meterBefore.destination, null, 'this destination has never held meters');
      assert.equal(kgBefore['source.kg'], 2_000);
      assert.equal(kgBefore['destination.kg'], null, 'the third product is unheld at the destination');

      const result = await s.submission(lines);
      assert.equal(result.replayed, false);
      assert.equal(result.transferId, s.idempotencyKey);
      assert.equal(result.sourceBranchId, s.branches.source);
      assert.equal(result.destinationBranchId, s.branches.destination);
      assert.deepEqual(result.lines.map(({ productId, quantityScaled, sourceQuantityScaled, destinationQuantityScaled }) => [
        productId === s.ids.piece, quantityScaled, sourceQuantityScaled, destinationQuantityScaled,
      ]), [
        [true, 2, 10, 5],
        [false, 150, 350, 150],
      ], 'each line reports its own scaled movement and resulting balances');

      const pieceAfter = { source: await s.units('source', 'piece'), destination: await s.units('destination', 'piece') };
      const meterAfter = { source: await s.units('source', 'meter'), destination: await s.units('destination', 'meter') };
      const kgAfter = await s.balances(['kg']);

      for (const [logical, pair] of [['piece', pieceAfter], ['meter', meterAfter]]) {
        requireNonNegative(`multi ${logical} source after`, pair.source);
        requireNonNegative(`multi ${logical} destination after`, pair.destination);
      }
      const pieceTotalBefore = pieceBefore.source + pieceBefore.destination;
      const pieceTotalAfter = pieceAfter.source + pieceAfter.destination;
      assert.equal(pieceAfter.source, 10);
      assert.equal(pieceAfter.destination, 5);
      assert.equal(pieceTotalAfter, pieceTotalBefore, 'pieces are conserved across the pair');
      assert.ok(pieceTotalAfter > 0, 'the piece pair total stays positive');

      const meterTotalBefore = meterBefore.source + absentAsZero('multi meter destination before', meterBefore.destination);
      const meterTotalAfter = meterAfter.source + meterAfter.destination;
      assert.equal(meterAfter.source, 350);
      assert.equal(meterAfter.destination, 150, 'an absent destination accepts its first units');
      assert.equal(meterTotalAfter, meterTotalBefore, 'meters are conserved across the pair');
      assert.ok(meterTotalAfter > 0, 'the meter pair total stays positive');

      assert.deepEqual(kgAfter, kgBefore, 'an untouched product is unchanged on both sides');
      assert.deepEqual(await executedLegs(s.idempotencyKey, 2), [
        legPath(s.idempotencyKey, 0, 'out'), legPath(s.idempotencyKey, 0, 'in'),
        legPath(s.idempotencyKey, 1, 'out'), legPath(s.idempotencyKey, 1, 'in'),
      ], 'exactly two legs per line, no third line and no second execution');

      const record = await read(`transfers/${s.idempotencyKey}`);
      assert.equal(record.exists, true);
      assert.equal(record.data().transferId, s.idempotencyKey);
      assert.equal(record.data().actorId, administrator);
      assert.deepEqual(record.data().productIds, [s.ids.piece, s.ids.meter]);
      assert.equal(record.data().lineCount, 2);
      assert.deepEqual(Object.keys(record.data()).filter((field) => /cost/i.test(field)), [], 'transfers never touch cost');

      for (const [index, [logical, scaledUnits]] of [[0, ['piece', 2]], [1, ['meter', 150]]]) {
        const out = await read(legPath(s.idempotencyKey, index, 'out'));
        const inLeg = await read(legPath(s.idempotencyKey, index, 'in'));
        assert.equal(out.exists, true);
        assert.equal(inLeg.exists, true);
        assert.equal(out.data().type, 'transfer-out');
        assert.equal(inLeg.data().type, 'transfer-in');
        assert.equal(out.data().quantityScaled, -scaledUnits, 'the source leg is negative');
        assert.equal(inLeg.data().quantityScaled, scaledUnits, 'legs carry exactly paired signs');
        assert.equal(out.data().quantityScaled + inLeg.data().quantityScaled, 0, 'a leg pair sums to zero');
        assert.equal(out.data().branchId, s.branches.source);
        assert.equal(inLeg.data().branchId, s.branches.destination);
        assert.equal(out.data().transferId, s.idempotencyKey);
        assert.equal(inLeg.data().productId, s.ids[logical]);
        assert.equal(out.data().precision, s.specs[logical].precision);
      }

      const written = (await read(s.stockPath('destination', 'meter'))).data();
      assert.equal(written.quantityScaled, 150);
      assert.equal(written.unit, 'meter');
      assert.equal(written.precision, 2);
      assert.equal(written.lastMovementId, legPath(s.idempotencyKey, 1, 'in').split('/').pop());
      assert.equal(typeof written.updatedAt?.toMillis, 'function', 'the written projection carries a timestamp');
      assert.ok(written.updatedAt.toMillis() > 0);
    });

    await t.test('a sequential replay returns the receipt and adds no movement', async () => {
      const s = await createScenario('replay', {
        specs: { piece: PIECE_SPEC },
        source: { piece: 10 },
        destination: { piece: 4 },
      });
      const lines = [{ logical: 'piece', quantity: '3' }];
      const guarded = s.registerSubmission(s.idempotencyKey, lines);

      const first = await s.submission(lines);
      assert.equal(first.replayed, false);
      const afterFirst = await s.balances(['piece']);
      assert.deepEqual([afterFirst['source.piece'], afterFirst['destination.piece']], [7, 7]);

      const replay = await s.submission(lines);
      assert.equal(replay.replayed, true);
      assert.equal(replay.transferId, s.idempotencyKey);
      assert.deepEqual(replay.lines, first.lines, 'the replay returns the persisted result unchanged');
      assert.deepEqual(await s.balances(['piece']), afterFirst, 'a replay moves no stock');
      assert.deepEqual(await executedLegs(s.idempotencyKey, 1), [
        legPath(s.idempotencyKey, 0, 'out'), legPath(s.idempotencyKey, 0, 'in'),
      ], 'exactly one record, one receipt, one leg pair and two projections');
      assert.equal(
        Object.values(await projection(guarded)).filter((entry) => entry !== null).length,
        6,
        'one record, one receipt, one leg pair and two projections exist',
      );
      const recordCount = await Promise.all([
        read(`transfers/${s.idempotencyKey}`),
        read(`transferSubmissionReceipts/${s.idempotencyKey}`),
      ]);
      assert.deepEqual(recordCount.map((snapshot) => snapshot.exists), [true, true], 'one transfer record and one receipt');
    });

    await t.test('a different payload on a committed key is refused with no writes', async () => {
      const s = await createScenario('collide', {
        specs: { piece: PIECE_SPEC },
        source: { piece: 10 },
        destination: { piece: 0 },
      });
      const accepted = [{ logical: 'piece', quantity: '1' }];
      const rejected = [{ logical: 'piece', quantity: '5' }];
      const guarded = s.registerSubmission(s.idempotencyKey, accepted);

      const committed = await s.submission(accepted);
      assert.equal(committed.replayed, false);
      assert.equal(committed.lines[0].quantityScaled, 1);
      const before = await projection(guarded);
      const balancesBefore = await s.balances(['piece']);
      assert.deepEqual([balancesBefore['source.piece'], balancesBefore['destination.piece']], [9, 1]);
      const legsBefore = await executedLegs(s.idempotencyKey, 1);

      await rejectsCode(() => s.submission(rejected), 'already-exists');

      assert.deepEqual(await projection(guarded), before, 'record, receipt, legs and stock are unchanged');
      assert.deepEqual(await s.balances(['piece']), balancesBefore, 'a refused payload moves nothing');
      assert.deepEqual(await executedLegs(s.idempotencyKey, 1), legsBefore, 'a refused payload writes no audit leg');
      assert.equal((await read(`transferSubmissionReceipts/${s.idempotencyKey}`)).data().result.lines[0].quantityScaled, 1,
        'the stored receipt still describes the accepted payload only');
    });

    await t.test('simultaneous identical keys execute once and replay once', async () => {
      const s = await createScenario('conc', {
        specs: { kg: KG_SPEC },
        source: { kg: 2_000 },
        destination: {},
      });
      const lines = [{ logical: 'kg', quantity: '0.500' }];
      s.registerSubmission(s.idempotencyKey, lines);
      const before = await s.balances(['kg']);
      assert.equal(before['source.kg'], 2_000);
      assert.equal(before['destination.kg'], null, 'this fixture starts with no destination balance');

      const results = await Promise.all([s.submission(lines), s.submission(lines)]);
      assert.deepEqual(results.map(({ replayed }) => replayed).sort(), [false, true], 'one execution, one replay');
      assert.deepEqual(results.map(({ transferId }) => transferId), [s.idempotencyKey, s.idempotencyKey]);
      assert.deepEqual(results.map(({ lines: echoed }) => echoed.map(({ quantityScaled }) => quantityScaled)), [[500], [500]]);

      const after = await s.balances(['kg']);
      requireNonNegative('conc source after', after['source.kg']);
      requireNonNegative('conc destination after', after['destination.kg']);
      assert.equal(after['source.kg'], 1_500, 'the units left the source exactly once');
      assert.equal(after['destination.kg'], 500, 'the units entered the destination exactly once');
      assert.equal(after['source.kg'] + after['destination.kg'], before['source.kg'], 'the pair is conserved');
      assert.ok(after['source.kg'] + after['destination.kg'] > 0, 'the pair total stays positive');
      assert.deepEqual(await executedLegs(s.idempotencyKey, 1), [
        legPath(s.idempotencyKey, 0, 'out'), legPath(s.idempotencyKey, 0, 'in'),
      ], 'contention produced one leg pair only');

      const record = await read(`transfers/${s.idempotencyKey}`);
      const receipt = await read(`transferSubmissionReceipts/${s.idempotencyKey}`);
      assert.equal(record.exists, true);
      assert.equal(receipt.exists, true);
      assert.equal(receipt.data().actorId, administrator);
      assert.equal(receipt.data().result.lines[0].sourceQuantityScaled, 1_500);
    });

    await t.test('an absent destination projection receives the written shape', async () => {
      const s = await createScenario('absent', {
        specs: { kg: KG_SPEC },
        source: { kg: 1_000 },
        destination: {},
      });
      const lines = [{ logical: 'kg', quantity: '1.000' }];
      s.registerSubmission(s.idempotencyKey, lines);
      assert.equal(await s.units('destination', 'kg'), null, 'the destination never held this product');

      const result = await s.submission(lines);
      assert.equal(result.replayed, false);
      assert.equal(result.lines[0].destinationQuantityScaled, 1_000);
      assert.equal(await s.units('source', 'kg'), 0, 'the source is emptied exactly');
      assert.equal(await s.units('destination', 'kg'), 1_000);

      const written = (await read(s.stockPath('destination', 'kg'))).data();
      assert.equal(written.quantityScaled, 1_000);
      assert.equal(written.unit, 'kilogram');
      assert.equal(written.precision, 3);
      assert.equal(written.lastMovementId, legPath(s.idempotencyKey, 0, 'in').split('/').pop());
      assert.equal(typeof written.updatedAt?.toMillis, 'function');
      assert.ok(written.updatedAt.toMillis() > 0);
      assert.deepEqual(await executedLegs(s.idempotencyKey, 1), [
        legPath(s.idempotencyKey, 0, 'out'), legPath(s.idempotencyKey, 0, 'in'),
      ], 'the created projection is backed by exactly one leg pair');
    });

    await t.test('insufficiency on a later line rolls back every write', async () => {
      const s = await createScenario('rollback', {
        specs: { piece: PIECE_SPEC, meter: METER_SPEC },
        source: { piece: 9, meter: 350 },
        destination: { piece: 1 },
      });
      const lines = [{ logical: 'piece', quantity: '1' }, { logical: 'meter', quantity: '9999.00' }];
      const guarded = s.registerSubmission(s.idempotencyKey, lines);
      const before = await projection(guarded);
      const balancesBefore = await s.balances(['piece', 'meter']);
      assert.deepEqual([
        balancesBefore['source.piece'], balancesBefore['destination.piece'],
        balancesBefore['source.meter'], balancesBefore['destination.meter'],
      ], [9, 1, 350, null]);

      await rejectsCode(() => s.submission(lines), 'failed-precondition');

      assert.deepEqual(await projection(guarded), before, 'a rejected transfer writes nothing at all');
      assert.deepEqual(await s.balances(['piece', 'meter']), balancesBefore, 'both projections are unchanged');
      assert.deepEqual(await existsFor(guarded), Object.fromEntries(
        [...new Set(guarded)].map((path) => [path, before[path] !== null]),
      ), 'only the seeded documents still exist');
      assert.deepEqual(await executedLegs(s.idempotencyKey, 2), [], 'a rolled-back transfer leaves no audit leg at all');
      requireNonNegative('rollback source piece after', (await s.units('source', 'piece')));
      requireNonNegative('rollback source meter after', (await s.units('source', 'meter')));
    });

    await t.test('a transfer to an unknown destination branch is refused', async () => {
      const s = await createScenario('ghost', {
        specs: { piece: PIECE_SPEC },
        source: { piece: 5 },
        destination: { piece: 5 },
      });
      const lines = [{ logical: 'piece', quantity: '1' }];
      const guarded = s.registerSubmission(s.idempotencyKey, lines);
      // Registered so the owned manifest also proves the unknown branch gained
      // no projection, even though the refusal must prevent every write.
      ownedPaths.add(`branches/${s.branches.absent}/stock/${s.ids.piece}`);
      const before = await projection(guarded);

      await rejectsCode(() => s.submission(lines, { destinationBranchId: s.branches.absent }), 'not-found');

      assert.deepEqual(await projection(guarded), before, 'a refusal against an unknown branch moves nothing');
      assert.deepEqual(await existsFor(guarded), {
        [`transfers/${s.idempotencyKey}`]: false,
        [`transferSubmissionReceipts/${s.idempotencyKey}`]: false,
        [legPath(s.idempotencyKey, 0, 'out')]: false,
        [legPath(s.idempotencyKey, 0, 'in')]: false,
        [s.stockPath('source', 'piece')]: true,
        [s.stockPath('destination', 'piece')]: true,
      });
      assert.equal((await read(`branches/${s.branches.absent}`)).exists, false, 'the ghost branch was never created');
      assert.equal(
        (await read(`branches/${s.branches.absent}/stock/${s.ids.piece}`)).exists,
        false,
        'no projection was created under the unknown branch',
      );
      assert.deepEqual(await executedLegs(s.idempotencyKey, 1), [], 'a refused branch audits nothing');
      assert.deepEqual(await s.balances(['piece']), { 'source.piece': 5, 'destination.piece': 5 });
    });

    await t.test('competing different keys commit once and never underflow', async () => {
      const s = await createScenario('race', {
        specs: { kg: KG_SPEC },
        source: { kg: 500 },
        destination: { kg: 100 },
        key: 'race-a',
      });
      const rivalKey = `${runId}-race-b`;
      const racing = [s.idempotencyKey, rivalKey];
      const lines = [{ logical: 'kg', quantity: '0.500' }];
      const guarded = [
        ...s.registerSubmission(s.idempotencyKey, lines),
        ...s.registerSubmission(rivalKey, lines),
      ];
      const before = await s.balances(['kg']);
      assert.equal(before['source.kg'], 500, 'both submissions compete for the whole source balance');
      assert.equal(before['destination.kg'], 100);

      const outcomes = await Promise.allSettled(racing.map((idempotencyKey) => s.submission(lines, {}, idempotencyKey)));
      const fulfilled = outcomes.filter(({ status }) => status === 'fulfilled');
      const rejected = outcomes.filter(({ status }) => status === 'rejected');
      assert.equal(fulfilled.length, 1, 'exactly one competing submission may succeed');
      assert.equal(rejected.length, 1);
      assert.ok(rejected[0].reason instanceof InventoryError, `unexpected rejection: ${rejected[0].reason}`);
      assert.equal(rejected[0].reason.code, 'failed-precondition');

      const after = await s.balances(['kg']);
      requireNonNegative('race source after', after['source.kg']);
      requireNonNegative('race destination after', after['destination.kg']);
      assert.equal(after['source.kg'], 0, 'the source never goes negative');
      assert.equal(after['destination.kg'], 600, 'the destination gained the moved units once');
      assert.equal(after['source.kg'] + after['destination.kg'], before['source.kg'] + before['destination.kg'], 'conserved');
      assert.ok(after['source.kg'] + after['destination.kg'] > 0, 'the pair total stays positive');

      const winner = fulfilled[0].value.transferId;
      const loser = racing.find((idempotencyKey) => idempotencyKey !== winner);
      assert.ok(racing.includes(winner) && racing.includes(loser) && winner !== loser);
      assert.deepEqual(await existsFor(guarded.filter((path) => path.includes(loser))), {
        [`transfers/${loser}`]: false,
        [`transferSubmissionReceipts/${loser}`]: false,
        [legPath(loser, 0, 'out')]: false,
        [legPath(loser, 0, 'in')]: false,
      }, 'the loser owns no record, receipt or leg');
      assert.deepEqual(await existsFor(guarded.filter((path) => path.includes(winner) && !path.includes('stock/'))), {
        [`transfers/${winner}`]: true,
        [`transferSubmissionReceipts/${winner}`]: true,
        [legPath(winner, 0, 'out')]: true,
        [legPath(winner, 0, 'in')]: true,
      }, 'the winner owns exactly one record, receipt and leg pair');
      assert.deepEqual(await executedLegs(winner, 1), [
        legPath(winner, 0, 'out'), legPath(winner, 0, 'in'),
      ], 'the winner audited exactly one leg pair');
      assert.deepEqual(await executedLegs(loser, 1), [], 'the loser audited nothing');
      assert.equal(
        (await executedLegs(s.idempotencyKey, 1)).length + (await executedLegs(rivalKey, 1)).length,
        2,
        'two competing keys produce exactly one leg pair in total',
      );
    });
  });
}
