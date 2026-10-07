/**
 * FUNC-01 deterministic offline unit tests for the pure owned-Auth lifecycle
 * companion. The injected Auth is always a fake: no Firebase SDK, no network,
 * no env, no emulators. Run with the pinned Node 24:
 *   /Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node \
 *     --test functions/test/owned-auth-manifest.test.mjs
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import {
  createOwnedAuthManifest,
  registerPlannedIdentities,
  provisionOwnedIdentities,
  cleanupOwnedIdentities,
} from './owned-auth-manifest.mjs';

const utc = (ms) => new Date(ms).toISOString();

function fakeClock() {
  let now = 1_700_000_000_000;
  return { now: () => now };
}

/** Fake Auth-like object. All knobs are read at call time for test re-wiring. */
function fakeAuth(knobs = {}, clock = fakeClock()) {
  const users = new Map();
  const calls = { createUser: [], setCustomUserClaims: [], getUser: [], deleteUser: [] };
  const notFound = () => Object.assign(new Error('user not found'), { code: 'auth/user-not-found' });
  return {
    users, calls, clock,
    async createUser(req) {
      calls.createUser.push(req.uid);
      if (knobs.hangCreate?.(req.uid)) return new Promise(() => {});
      const err = knobs.createUserError?.(req.uid);
      if (err) throw err;
      if (users.has(req.uid)) throw Object.assign(new Error('uid-already-exists'), { code: 'auth/uid-already-exists' });
      const creationTime = utc(clock.now());
      const override = knobs.createUserReceipt?.(req.uid);
      if (override) return override; // mismatched / uncorroborated receipt paths
      users.set(req.uid, { uid: req.uid, metadata: { creationTime }, customClaims: {} });
      return { uid: req.uid, metadata: { creationTime } };
    },
    async setCustomUserClaims(uid, claims) {
      calls.setCustomUserClaims.push({ uid, claims });
      const err = knobs.failSetClaims?.(uid);
      if (err) throw err;
      users.get(uid).customClaims = { ...claims };
    },
    async getUser(uid) {
      calls.getUser.push(uid);
      const err = knobs.failGetUser?.(uid);
      if (err) throw err;
      const u = users.get(uid);
      if (!u) throw notFound();
      // SDK-faithful: UserRecord.customClaims is undefined when no claims were ever set.
      return { uid: u.uid, metadata: { creationTime: u.metadata.creationTime }, customClaims: Object.keys(u.customClaims).length ? { ...u.customClaims } : undefined };
    },
    async deleteUser(uid) {
      calls.deleteUser.push(uid);
      const err = knobs.failDeleteUser?.(uid);
      if (err) throw err;
      users.delete(uid);
    },
  };
}

function createParamsFor(manifest) {
  return Object.fromEntries([...manifest.entries.keys()].map((role) => [
    role, { email: `acceptance-${manifest.runId}-${role}@example.invalid`, password: `secret-${manifest.runId}-${role}` },
  ]));
}

async function provisionAll(auth, runId, overrides = {}) {
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  registerPlannedIdentities(manifest);
  const provision = await provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest), ...overrides });
  return { manifest, provision };
}

const byRole = (result) => Object.fromEntries(result.map((e) => [e.role, e]));

test('happy path: planned create, claims recorded only after success, verified cleanup removes owned users', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const { manifest, provision } = await provisionAll(auth, runId);
  const roles = byRole(provision.provisioned);
  for (const role of ['administrator', 'seller', 'unassigned', 'client']) {
    assert.equal(roles[role].uid, `acceptance-${runId}-${role}`);
    assert.equal(roles[role].outcome, 'owned');
    assert.equal(roles[role].claimsStage.kind, 'recorded-after-success');
    assert.ok(roles[role].receipt.creationTime);
  }
  assert.deepEqual(roles.administrator.claimsStage.claims, { acceptanceRunId: runId, role: 'administrator' });
  assert.deepEqual(roles.seller.claimsStage.claims, { acceptanceRunId: runId, role: 'seller', branchId: `branch-${runId}` });
  assert.deepEqual(roles.unassigned.claimsStage.claims, { acceptanceRunId: runId, role: 'unassigned' });
  assert.deepEqual(roles.client.claimsStage.claims, { acceptanceRunId: runId, role: 'client' });
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.ok(cleanup.cleanup.every((e) => e.outcome === 'removed'));
  assert.equal(auth.users.size, 0);
  assert.deepEqual(auth.calls.deleteUser.slice().sort(),
    [`acceptance-${runId}-administrator`, `acceptance-${runId}-client`, `acceptance-${runId}-seller`, `acceptance-${runId}-unassigned`].sort());
});

test('preexisting collision: never claims or deletes the existing user; other owned users proceed', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  registerPlannedIdentities(manifest);
  const sellerUid = `acceptance-${runId}-seller`;
  auth.users.set(sellerUid, { uid: sellerUid, metadata: { creationTime: utc(auth.clock.now() - 86_400_000) }, customClaims: { role: 'legacy' } });
  const provision = await provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest) });
  const seller = provision.provisioned.find((e) => e.role === 'seller');
  assert.equal(seller.outcome, 'not-owned');
  assert.ok(seller.reasons[0].includes('auth/uid-already-exists'));
  assert.ok(!auth.calls.setCustomUserClaims.some((c) => c.uid === sellerUid));
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(cleanup.cleanup.find((e) => e.role === 'seller').outcome, 'not-owned');
  assert.ok(auth.users.has(sellerUid));
  assert.deepEqual(auth.users.get(sellerUid).customClaims, { role: 'legacy' });
  assert.ok(!auth.calls.deleteUser.includes(sellerUid));
  assert.equal(cleanup.cleanup.find((e) => e.role === 'administrator').outcome, 'removed');
});

test('runId and manifest validation: lowercase UUID required, clock must be injected', () => {
  assert.throws(() => createOwnedAuthManifest({ runId: 'not-a-uuid' }), TypeError);
  assert.throws(() => createOwnedAuthManifest({ runId: randomUUID().toUpperCase() }), TypeError);
  assert.throws(() => createOwnedAuthManifest({ runId: randomUUID(), clock: 'nope' }), TypeError);
});

test('planning validation: duplicate role, unknown role, sealed plan, one-time provision', async () => {
  const runId = randomUUID();
  const manifest = createOwnedAuthManifest({ runId });
  registerPlannedIdentities(manifest);
  assert.throws(() => registerPlannedIdentities(manifest), /duplicate planned role: administrator/);
  const other = createOwnedAuthManifest({ runId });
  assert.throws(() => registerPlannedIdentities(other, ['admin']), /unknown owned role/);
  assert.throws(() => registerPlannedIdentities(other, []), TypeError);
  const auth = fakeAuth();
  await provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest) });
  assert.throws(() => registerPlannedIdentities(manifest), /sealed before the first write/);
  await assert.rejects(() => provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest) }), /one-time/);
});

test('createParams validation: missing planned role creates nothing; unknown role rejected before any write', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  registerPlannedIdentities(manifest);
  const params = createParamsFor(manifest);
  delete params.unassigned;
  await assert.rejects(() => provisionOwnedIdentities({ auth, manifest, createParams: { ...params, intruder: { email: 'x@y.z', password: 'p' } } }), /outside the planned roles/);
  const provision = await provisionOwnedIdentities({ auth, manifest, createParams: params });
  const unassigned = provision.provisioned.find((e) => e.role === 'unassigned');
  assert.equal(unassigned.outcome, 'not-owned');
  assert.ok(!auth.calls.createUser.includes(unassigned.uid));
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(cleanup.cleanup.find((e) => e.role === 'unassigned').outcome, 'not-owned');
  assert.ok(!auth.calls.deleteUser.includes(unassigned.uid));
});

test('receipt uid mismatch: no claims, no cleanup for that entry', async () => {
  const runId = randomUUID();
  const clock = fakeClock();
  const auth = fakeAuth({ createUserReceipt: (uid) => ({ uid: `${uid}-tampered`, metadata: { creationTime: utc(clock.now()) } }) }, clock);
  const { manifest, provision } = await provisionAll(auth, runId);
  assert.ok(provision.provisioned.every((e) => e.outcome === 'not-owned'));
  assert.equal(auth.calls.setCustomUserClaims.length, 0);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.ok(cleanup.cleanup.every((e) => e.outcome === 'not-owned'));
  assert.equal(auth.calls.deleteUser.length, 0);
});

test('creation timestamp outside the corroborated window: retained, claims never set, never deleted', async () => {
  const runId = randomUUID();
  const clock = fakeClock();
  const auth = fakeAuth({ createUserReceipt: (uid) => ({ uid, metadata: { creationTime: utc(clock.now() - 10 * 60_000) } }) }, clock);
  const { manifest, provision } = await provisionAll(auth, runId);
  assert.ok(provision.provisioned.every((e) => e.outcome === 'retained'));
  assert.equal(auth.calls.setCustomUserClaims.length, 0);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.ok(cleanup.cleanup.every((e) => e.outcome === 'retained'));
  assert.equal(auth.calls.getUser.length, 0);
  assert.equal(auth.calls.deleteUser.length, 0);
});

test('ambiguous create timeout: no receipt, never adopted from a UUID name, never deleted', async () => {
  const runId = randomUUID();
  const auth = fakeAuth({ hangCreate: (uid) => uid.endsWith('-administrator') });
  const { manifest, provision } = await provisionAll(auth, runId, { createTimeoutMs: 5, sleep: async () => {} });
  const admin = provision.provisioned.find((e) => e.role === 'administrator');
  assert.equal(admin.outcome, 'not-owned');
  assert.ok(admin.reasons[0].includes('timed out ambiguously'));
  assert.ok(!auth.calls.setCustomUserClaims.some((c) => c.uid.endsWith('-administrator')));
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(auth.calls.deleteUser.length, 3);
  assert.equal(cleanup.cleanup.find((e) => e.role === 'administrator').outcome, 'not-owned');
});

test('setCustomUserClaims SDK failure: outcome uncertain, permanently retained until manual decision', async () => {
  const runId = randomUUID();
  const auth = fakeAuth({ failSetClaims: (uid) => (uid.endsWith('-seller') ? Object.assign(new Error('backend down'), { code: 'auth/network-request-failed' }) : null) });
  const { manifest, provision } = await provisionAll(auth, runId);
  const seller = provision.provisioned.find((e) => e.role === 'seller');
  assert.equal(seller.outcome, 'retained');
  assert.equal(seller.claimsStage.kind, 'initial-empty');
  assert.ok(seller.reasons.at(-1).includes('uncertain'));
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  const seller2 = cleanup.cleanup.find((e) => e.role === 'seller');
  assert.equal(seller2.outcome, 'retained');
  assert.ok(seller2.reasons.at(-1).includes('uncertain'));
  assert.ok(!seller2.reasons.at(-1).includes('certainly'));
  assert.ok(!auth.calls.deleteUser.some((u) => u.endsWith('-seller')));
  assert.ok(auth.users.has(`acceptance-${runId}-seller`));
  const second = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(second.cleanup.find((e) => e.role === 'seller').outcome, 'retained');
  assert.equal(auth.calls.deleteUser.filter((u) => u.endsWith('-seller')).length, 0);
});

test('setCustomUserClaims unknown outcome: retained, never blind-deleted, stable across reruns', async () => {
  const runId = randomUUID();
  const auth = fakeAuth({ failSetClaims: (uid) => (uid.endsWith('-client') ? Object.assign(new Error('ambiguous'), { code: 'owned-manifest/timeout' }) : null) });
  const { manifest } = await provisionAll(auth, runId);
  const first = await cleanupOwnedIdentities({ auth, manifest });
  const client = first.cleanup.find((e) => e.role === 'client');
  assert.equal(client.outcome, 'retained');
  assert.ok(client.reasons.at(-1).includes('unknown'));
  assert.ok(!auth.calls.deleteUser.some((u) => u.endsWith('-client')));
  const second = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(second.cleanup.find((e) => e.role === 'client').outcome, 'retained');
  assert.equal(auth.calls.deleteUser.filter((u) => u.endsWith('-client')).length, 0);
});

test('cleanup retains on altered role, marker, or timestamp; untouched sibling still cleaned', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const { manifest } = await provisionAll(auth, runId);
  auth.users.get(`acceptance-${runId}-administrator`).customClaims = { acceptanceRunId: runId, role: 'seller', branchId: `branch-${runId}` };
  auth.users.get(`acceptance-${runId}-seller`).customClaims = { acceptanceRunId: 'other-run', role: 'seller', branchId: `branch-${runId}` };
  auth.users.get(`acceptance-${runId}-client`).metadata.creationTime = utc(auth.clock.now() + 3_600_000);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  const roles = byRole(cleanup.cleanup);
  assert.equal(roles.administrator.outcome, 'retained');
  assert.equal(roles.seller.outcome, 'retained');
  assert.equal(roles.client.outcome, 'retained');
  assert.equal(roles.unassigned.outcome, 'removed');
  assert.equal(auth.calls.deleteUser.length, 1);
});

test('transient read failure: retained for a later verified retry; remaining users still cleaned', async () => {
  const runId = randomUUID();
  const knobs = { failGetUser: (uid) => (uid.endsWith('-unassigned') ? Object.assign(new Error('backend'), { code: 'auth/internal-error' }) : null) };
  const auth = fakeAuth(knobs);
  const { manifest } = await provisionAll(auth, runId);
  const first = await cleanupOwnedIdentities({ auth, manifest });
  const unassigned = first.cleanup.find((e) => e.role === 'unassigned');
  assert.equal(unassigned.outcome, 'retained');
  assert.ok(unassigned.reasons.at(-1).includes('transient read failure'));
  assert.equal(first.cleanup.filter((e) => e.outcome === 'removed').length, 3);
  knobs.failGetUser = () => null;
  const retry = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(retry.cleanup.find((e) => e.role === 'unassigned').outcome, 'removed');
});

test('absence is reported without any delete, and terminal outcomes are never re-deleted', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const { manifest } = await provisionAll(auth, runId);
  auth.users.delete(`acceptance-${runId}-administrator`);
  const first = await cleanupOwnedIdentities({ auth, manifest });
  const admin = first.cleanup.find((e) => e.role === 'administrator');
  assert.equal(admin.outcome, 'absent');
  assert.ok(admin.reasons.at(-1).includes('reported without any delete'));
  assert.equal(first.cleanup.filter((e) => e.outcome === 'removed').length, 3);
  assert.equal(auth.calls.deleteUser.length, 3);
  const second = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(auth.calls.deleteUser.length, 3);
  assert.equal(second.cleanup.filter((e) => e.outcome === 'absent').length, 1);
  assert.ok(second.cleanup.every((e) => ['removed', 'absent'].includes(e.outcome)));
});

test('deleteUser failure: retained, then a verified retry removes, further runs make no delete calls', async () => {
  const runId = randomUUID();
  const knobs = { failDeleteUser: (uid) => (uid.endsWith('-seller') ? Object.assign(new Error('busy'), { code: 'auth/internal-error' }) : null) };
  const auth = fakeAuth(knobs);
  const { manifest } = await provisionAll(auth, runId);
  const first = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(first.cleanup.find((e) => e.role === 'seller').outcome, 'retained');
  assert.equal(first.cleanup.filter((e) => e.outcome === 'removed').length, 3);
  knobs.failDeleteUser = () => null;
  const second = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(second.cleanup.find((e) => e.role === 'seller').outcome, 'removed');
  const deletesAfterRetry = auth.calls.deleteUser.filter((u) => u.endsWith('-seller')).length;
  const third = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(third.cleanup.find((e) => e.role === 'seller').outcome, 'removed');
  assert.equal(auth.calls.deleteUser.filter((u) => u.endsWith('-seller')).length, deletesAfterRetry);
});

test('cleanup never touches planned-only entries: no arbitrary delete surface', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  registerPlannedIdentities(manifest);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.ok(cleanup.cleanup.every((e) => e.outcome === 'planned'));
  assert.equal(auth.calls.getUser.length, 0);
  assert.equal(auth.calls.deleteUser.length, 0);
});

test('immutability: runId/clock poisoning, mutating returned claims/views, or reassigning entries cannot change cleanup authority', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  const attempt = (fn) => { try { fn(); return 'applied'; } catch { return 'rejected'; } };
  const poisons = [
    () => { manifest.runId = 'pwned-run-id'; },
    () => { manifest.clock = () => 0; },
    () => Object.defineProperty(manifest, 'runId', { value: 'pwned-run-id' }),
    () => Object.defineProperty(manifest, 'clock', { get: () => () => 0 }),
  ];
  assert.ok(poisons.every((poison) => attempt(poison) === 'rejected') && manifest.runId === runId);
  registerPlannedIdentities(manifest);
  const provision = await provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest) });
  const sellerUid = `acceptance-${runId}-seller`;
  const victimUid = `acceptance-${runId}-intruder`;
  assert.ok(provision.provisioned.every((e) => e.outcome === 'owned' && e.uid === `acceptance-${runId}-${e.role}`));
  auth.users.set(victimUid, { uid: victimUid, metadata: { creationTime: utc(auth.clock.now()) }, customClaims: { role: 'victim' } });
  // Attempt 1: mutate the returned sanitized claims object (frozen: rejected).
  assert.equal(attempt(() => { provision.provisioned.find((e) => e.role === 'seller').claimsStage.claims.role = 'attacker'; }), 'rejected');
  // Attempt 2: mutate and reassign the public manifest entry view (frozen: rejected).
  assert.equal(attempt(() => { manifest.entries.get('seller').claimsStage.claims.role = 'attacker'; }), 'rejected');
  assert.equal(attempt(() => { manifest.entries.get('seller').claimsStage = { kind: 'recorded-after-success', claims: { acceptanceRunId: runId, role: 'attacker' } }; }), 'rejected');
  assert.equal(attempt(() => { manifest.entries.get('seller').receipt = { uid: victimUid, creationTime: '2001-01-01T00:00:00Z' }; }), 'rejected');
  // Attempt 3: set a fabricated entry into the returned view Map (applied, view-only).
  assert.equal(attempt(() => manifest.entries.set('seller', { uid: victimUid, role: 'seller', outcome: 'owned', reasons: [], receipt: { uid: victimUid, creationTime: '2001-01-01T00:00:00Z' }, claimsStage: { kind: 'recorded-after-success', claims: {} }, claimsUncertain: false, cleanupRetryable: false })), 'applied');
  // The live fake user now carries the attacker claims the caller tried to bless.
  auth.users.get(sellerUid).customClaims = { acceptanceRunId: runId, role: 'attacker', branchId: `branch-${runId}` };
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(cleanup.cleanup.find((e) => e.role === 'seller').outcome, 'retained');
  assert.ok(!auth.calls.deleteUser.includes(sellerUid));
  assert.ok(!auth.calls.deleteUser.includes(victimUid));
  assert.ok(auth.users.has(victimUid));
});

const PINNED_NODE = '/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node';

// Pinned-child scenario: mode 'pending' proves the timeout settles safely; mode 'fast' proves prompt exit despite 10s timeouts.
const CHILD = `\nconst { pathToFileURL } = require('node:url'); const { randomUUID } = require('node:crypto');
(async () => {
  const fast = process.argv[1] === 'fast';
  const m = await import(pathToFileURL(process.cwd() + '/functions/test/owned-auth-manifest.mjs'));
  const manifest = m.createOwnedAuthManifest({ runId: randomUUID(), clock: () => 1700000000000 });
  m.registerPlannedIdentities(manifest, ['client']);
  const users = new Map();
  const auth = fast ? {
    createUser: async (req) => { const ct = new Date(1700000000000).toISOString(); users.set(req.uid, { uid: req.uid, metadata: { creationTime: ct }, customClaims: {} }); return { uid: req.uid, metadata: { creationTime: ct } }; },
    setCustomUserClaims: async (uid, claims) => { users.get(uid).customClaims = { ...claims }; },
    getUser: async (uid) => { const u = users.get(uid); return { uid: u.uid, metadata: { creationTime: u.metadata.creationTime }, customClaims: { ...u.customClaims } }; },
    deleteUser: async (uid) => { users.delete(uid); },
  } : { createUser: () => new Promise(() => {}), setCustomUserClaims: async () => {}, getUser: async () => {}, deleteUser: async () => {} };
  const provision = await m.provisionOwnedIdentities({ auth, manifest, createParams: { client: { email: 'e@x.invalid', password: 'p' } }, createTimeoutMs: fast ? 10_000 : 100 });
  console.log('SETTLED:' + (fast ? (await m.cleanupOwnedIdentities({ auth, manifest })).cleanup[0].outcome : provision.provisioned[0].outcome));
})().catch((error) => { console.error(error); process.exit(1); });
`;

function runPinnedChild(script, mode) {
  // Bounded child: pinned Node only, no shell, no files, hard 2s deadline, always reaped.
  return spawnSync(PINNED_NODE, ['-e', script, mode], { timeout: 2000, encoding: 'utf8' });
}

test('deadline: a pending createUser timeout settles to a safe retained outcome in a fresh child with no extra ref handles', () => {
  const child = runPinnedChild(CHILD, 'pending');
  assert.equal(child.status, 0, 'child status: ' + child.status + ' stderr: ' + child.stderr);
  assert.ok(child.stdout.includes('SETTLED:not-owned'), 'unsettled child stdout: ' + JSON.stringify(child.stdout));
});

test('deadline: fast operations exit promptly despite 10s configured timeouts (no dangling ref timers)', () => {
  const child = runPinnedChild(CHILD, 'fast');
  assert.equal(child.status, 0, 'child status: ' + child.status + ' stderr: ' + child.stderr);
  assert.ok(child.stdout.includes('SETTLED:removed'), 'child stdout: ' + JSON.stringify(child.stdout));
});

test('absent customClaims: undefined normalizes to empty for a corroborated user with known initial empty claims; null retains', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const manifest = createOwnedAuthManifest({ runId, clock: auth.clock.now });
  registerPlannedIdentities(manifest, ['client']);
  const provision = await provisionOwnedIdentities({ auth, manifest, createParams: createParamsFor(manifest), setClaims: false });
  assert.equal(auth.calls.setCustomUserClaims.length, 0);
  assert.equal(provision.provisioned[0].claimsStage.kind, 'initial-empty');
  // The getUser boundary is SDK-faithful: customClaims is undefined when nothing was ever set.
  assert.equal((await auth.getUser(`acceptance-${runId}-client`)).customClaims, undefined);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  assert.equal(cleanup.cleanup[0].outcome, 'removed');
  // A null claims blob is a wrong type, not a known empty stage: retain.
  const runId2 = randomUUID();
  const auth2 = fakeAuth();
  const manifest2 = createOwnedAuthManifest({ runId: runId2, clock: auth2.clock.now });
  registerPlannedIdentities(manifest2, ['client']);
  await provisionOwnedIdentities({ auth: auth2, manifest: manifest2, createParams: createParamsFor(manifest2), setClaims: false });
  auth2.users.get(`acceptance-${runId2}-client`).customClaims = null;
  const cleanup2 = await cleanupOwnedIdentities({ auth: auth2, manifest: manifest2 });
  assert.equal(cleanup2.cleanup[0].outcome, 'retained');
  assert.ok(!auth2.calls.deleteUser.includes(`acceptance-${runId2}-client`));
});

test('results, reasons, and manifest serialization never contain secrets', async () => {
  const runId = randomUUID();
  const auth = fakeAuth();
  const { manifest, provision } = await provisionAll(auth, runId);
  const cleanup = await cleanupOwnedIdentities({ auth, manifest });
  const serialized = JSON.stringify({ manifest, entries: [...manifest.entries.values()], provision, cleanup });
  assert.ok(!serialized.includes(`secret-${runId}`));
  assert.ok(!serialized.includes('@example.invalid'));
  assert.ok(!serialized.includes('password'));
  assert.ok(serialized.includes(`acceptance-${runId}-seller`));
  assert.ok(serialized.includes(`branch-${runId}`));
});
