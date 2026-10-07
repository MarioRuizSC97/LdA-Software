/**
 * FUNC-01 — Pure, dependency-injected owned-Auth lifecycle companion.
 *
 * This module performs ZERO imports. The caller injects an Auth-like object
 * `{ createUser, getUser, setCustomUserClaims, deleteUser }` and a clock
 * `() => epoch ms`. It never touches the Firebase SDK, fetch, network, env
 * vars, ADC, or cloud services, so its unit tests are deterministic offline.
 *
 * Ownership contract:
 *   - The caller supplies a fresh lowercase UUID `runId` (crypto.randomUUID()).
 *   - Planned identities are registered BEFORE any create; the plan is sealed
 *     before the first write and accepts no late registrations.
 *   - UIDs are namespaced `acceptance-<runId>-<role>` (administrator/seller/
 *     unassigned/client); the seller carries `branchId: branch-<runId>`. No demo/shared surface.
 *   - Creates are one-time, no retries; `createUser` is create-only: a collision
 *     or failure never mutates claims of, or deletes, an existing user.
 *
 * Immutability contract: the authoritative ownership baseline (run context,
 * expected claims, receipt, recorded claim stage) lives deep-frozen in
 * module-private state; the public runId/clock accessors are read-only
 * diagnostics over it. `manifest.entries`, provision results, and cleanup results
 * are COPIED read-only views; mutating or reassigning them can never change
 * what cleanup verifies or deletes (views are snapshots, not live authority).
 *
 * Time policy: `metadata.creationTime` from Auth is UTC (second precision in
 * the real SDK). A receipt is accepted only when its parsed instant falls in
 * [beforeMs − SKEW, afterMs + SKEW] sampled around the create; a timestamp
 * alone, or a UID substring, never proves ownership.
 *
 * Deadline policy: timeouts arm a standard referenced timer that clears
 * itself when the operation settles, so pending operations reliably resolve
 * to their safe retained outcome and fast runs leave no dangling handles. A
 * timeout does NOT cancel the underlying SDK RPC: a late server completion
 * never converts an ambiguous outcome into ownership (no UUID-name adoption).
 *
 * Claims uncertainty policy: `setCustomUserClaims` has no receipt, so ANY
 * failure (timeout, network, or unknown SDK error) is uncertain: the entry
 * is permanently retained and reported with a sanitized stable error code
 * until a human decides. Inputs are internally constructed frozen values, so no
 * pre-request local validation failure path exists. `setClaims: false`
 * provisions runs that deliberately never set claims; only that initial empty
 * stage is cleanup-eligible, after readback verification.
 *
 * Concurrency limitation (truthful): the Auth SDK has no transactional
 * compare-and-swap, so cleanup is verify-then-delete; a concurrent writer
 * could change claims between verification and deleteUser. Any disagreement
 * retains the user, and only corroborated-receipt identities are eligible.
 *
 * Secrets policy: emails/passwords live only in the caller's in-memory
 * `createParams`, passed straight to the injected `createUser`; they are
 * never stored on the manifest, results, reasons, or any output.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const OWNED_ROLES = Object.freeze(['administrator', 'seller', 'unassigned', 'client']);
export const OPERATION_WINDOW_SKEW_MS = 5 * 60 * 1000;
const TIMEOUT_CODE = 'owned-manifest/timeout';

// Authoritative per-manifest state; unreachable through the public manifest.
const INTERNAL = new WeakMap();

const isPlainObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
const timeoutError = () => Object.assign(new Error('owned-manifest operation timed out'), { code: TIMEOUT_CODE });

function deepFreeze(value) {
  if (value !== null && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const key of Object.keys(value)) deepFreeze(value[key]);
    Object.freeze(value);
  }
  return value;
}

/**
 * Standard-builtin deadline: one referenced timer, self-cleared when the
 * operation settles; an injected `sleep` (offline test contract) replaces the
 * real timer. Timing out rejects this await only, never the RPC.
 */
function withTimeout(promise, ms, sleep) {
  if (typeof sleep === 'function') {
    return Promise.race([Promise.resolve(promise), sleep(ms).then(() => { throw timeoutError(); })]);
  }
  if (!Number.isFinite(ms)) return Promise.resolve(promise);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(timeoutError()), ms);
    Promise.resolve(promise).then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); },
    );
  });
}

function assertRunId(runId) {
  if (typeof runId !== 'string' || !UUID_RE.test(runId)) {
    throw new TypeError('runId must be a fresh lowercase UUID (crypto.randomUUID())');
  }
}

function assertAuthShape(auth, methods) {
  if (!isPlainObject(auth)) throw new TypeError('auth must be an injected Auth-like object; this module imports no SDK');
  for (const m of methods) {
    if (typeof auth[m] !== 'function') throw new TypeError(`injected auth.${m} must be a function`);
  }
}

/**
 * Normalizes readback claims. The SDK leaves `customClaims` undefined when
 * no claims were ever set, so undefined is the known empty stage ({}). Null
 * or non-string values are wrong types: null (retain), never guessed.
 */function normalizeClaims(value) {
  if (value === undefined) return {};
  if (!isPlainObject(value) || !Object.values(value).every((v) => typeof v === 'string')) return null;
  return Object.fromEntries(Object.keys(value).sort().map((k) => [k, value[k]]));
}

const claimsEqual = (a, b) => {
  const ka = Object.keys(a);
  return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k]);
};

function expectedClaimsFor(runId, role) {
  const claims = { acceptanceRunId: runId, role };
  if (role === 'seller') claims.branchId = `branch-${runId}`;
  return deepFreeze(claims);
}

function parseUtcEpochMs(value) {
  if (typeof value !== 'string') return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

export function createOwnedAuthManifest({ runId, clock = () => Date.now() } = {}) {
  assertRunId(runId);
  if (typeof clock !== 'function') throw new TypeError('clock must be an injected () => epoch-ms function');
  const internal = { runId, clock, entries: new Map(), sealed: false, provisioned: false };
  const manifest = Object.freeze({
    get runId() { return internal.runId; },
    get clock() { return internal.clock; },
    // Copied frozen snapshots for reporting; mutation cannot touch authority.
    get entries() {
      return new Map([...internal.entries.values()].map((entry) => [entry.role, publicEntry(entry)]));
    },
    get sealed() { return internal.sealed; },
  });
  INTERNAL.set(manifest, internal);
  return manifest;
}

export function registerPlannedIdentities(manifest, roles = [...OWNED_ROLES]) {
  const internal = INTERNAL.get(manifest);
  if (!internal) throw new TypeError('manifest must come from createOwnedAuthManifest');
  if (internal.sealed || internal.provisioned) {
    throw new Error('plan is sealed before the first write; register planned identities before provisioning');
  }
  if (!Array.isArray(roles) || roles.length === 0) throw new TypeError('roles must be a non-empty array');
  for (const role of roles) {
    if (!OWNED_ROLES.includes(role)) throw new TypeError(`unknown owned role: ${String(role)}`);
    if (internal.entries.has(role)) throw new Error(`duplicate planned role: ${role}`);
    internal.entries.set(role, {
      uid: `acceptance-${internal.runId}-${role}`,
      role,
      expectedClaims: expectedClaimsFor(internal.runId, role),
      receipt: null,
      claimsStage: null, // { kind: 'initial-empty' | 'recorded-after-success', claims }
      claimsUncertain: false,
      cleanupRetryable: false,
      outcome: 'planned',
      reasons: [],
    });
  }
  const seen = new Set();
  for (const entry of internal.entries.values()) {
    if (seen.has(entry.uid)) throw new Error(`duplicate planned uid: ${entry.uid}`);
    seen.add(entry.uid);
  }
}

/** Fresh deep copy, no aliases into internal state; never contains secrets. */
function publicEntry(entry) {
  return deepFreeze({
    uid: entry.uid,
    role: entry.role,
    outcome: entry.outcome,
    reasons: [...entry.reasons],
    receipt: entry.receipt ? { ...entry.receipt } : null,
    claimsStage: entry.claimsStage ? { kind: entry.claimsStage.kind, claims: { ...entry.claimsStage.claims } } : null,
  });
}

function log(entry, reason) {
  if (entry.reasons[entry.reasons.length - 1] !== reason) entry.reasons.push(reason);
}

function retain(entry, reason) {
  entry.outcome = 'retained';
  log(entry, reason);
}

const sanitizedCode = (err) => (err && typeof err.code === 'string' ? ` (${err.code})` : '');

export async function provisionOwnedIdentities({ auth, manifest, createParams, setClaims = true, createTimeoutMs = 10000, claimsTimeoutMs = 10000, sleep } = {}) {
  assertAuthShape(auth, ['createUser', 'setCustomUserClaims']);
  const internal = INTERNAL.get(manifest);
  if (!internal) throw new TypeError('manifest must come from createOwnedAuthManifest');
  if (internal.provisioned) throw new Error('manifest already provisioned; creates are one-time with no retries');
  if (!isPlainObject(createParams)) throw new TypeError('createParams must map planned roles to { email, password } held only in memory');
  const unknown = Object.keys(createParams).filter((r) => !internal.entries.has(r));
  if (unknown.length > 0) throw new TypeError(`createParams has entries outside the planned roles: ${unknown.sort().join(', ')}`);
  internal.sealed = true; // plan sealed before the first write
  internal.provisioned = true;
  const provisioned = [];
  for (const entry of [...internal.entries.values()]) {
    await provisionEntry({ auth, clock: internal.clock, entry, createParams, setClaims, createTimeoutMs, claimsTimeoutMs, sleep });
    provisioned.push(publicEntry(entry));
  }
  return { runId: internal.runId, provisioned };
}

async function provisionEntry({ auth, clock, entry, createParams, setClaims, createTimeoutMs, claimsTimeoutMs, sleep }) {
  const params = createParams[entry.role];
  if (!isPlainObject(params) || typeof params.email !== 'string' || params.email.length === 0
    || typeof params.password !== 'string' || params.password.length === 0) {
    entry.outcome = 'not-owned';
    entry.reasons.push('missing create params for planned role; nothing created');
    return;
  }
  const beforeMs = clock();
  let receipt;
  try {
    receipt = await withTimeout(auth.createUser({ uid: entry.uid, email: params.email, password: params.password }), createTimeoutMs, sleep);
  } catch (err) {
    entry.outcome = 'not-owned';
    entry.reasons.push(err?.code === TIMEOUT_CODE
      ? 'createUser timed out ambiguously; no owned receipt; never adopted from a UUID name alone'
      : `createUser failed${sanitizedCode(err)}; create-only collision leaves any existing user untouched`);
    return;
  }
  const afterMs = clock();
  if (!isPlainObject(receipt) || receipt.uid !== entry.uid) {
    entry.outcome = 'not-owned';
    entry.reasons.push('createUser receipt does not match the planned uid; no claims and no cleanup');
    return;
  }
  const creationMs = parseUtcEpochMs(receipt.metadata?.creationTime);
  if (creationMs === null || creationMs < beforeMs - OPERATION_WINDOW_SKEW_MS || creationMs > afterMs + OPERATION_WINDOW_SKEW_MS) {
    retain(entry, 'creation timestamp missing or outside the corroborated operation window; claims must not change on an unproven create');
    return;
  }
  // Minimal receipt captured BEFORE any claims call, deep-frozen; no secrets retained.
  entry.receipt = deepFreeze({ uid: entry.uid, creationTime: receipt.metadata.creationTime });
  entry.claimsStage = { kind: 'initial-empty', claims: deepFreeze({}) };
  entry.outcome = 'owned';
  if (!setClaims) {
    log(entry, 'claims intentionally not set for this run; expected stage is the initial empty claims');
    return;
  }
  try {
    await withTimeout(auth.setCustomUserClaims(entry.uid, entry.expectedClaims), claimsTimeoutMs, sleep);
    entry.claimsStage = { kind: 'recorded-after-success', claims: entry.expectedClaims };
  } catch (err) {
    // setCustomUserClaims has no receipt: every failure is an uncertain outcome.
    // Retain permanently; a late server completion must never be adopted.
    entry.claimsUncertain = true;
    retain(entry, err?.code === TIMEOUT_CODE
      ? 'setCustomUserClaims timed out; outcome unknown; retained, never blind-deleted'
      : `setCustomUserClaims failed${sanitizedCode(err)}; outcome uncertain; retained until manual decision`);
  }
}

export async function cleanupOwnedIdentities({ auth, manifest, readTimeoutMs = 10000, deleteTimeoutMs = 10000, sleep } = {}) {
  assertAuthShape(auth, ['getUser', 'deleteUser']);
  const internal = INTERNAL.get(manifest);
  if (!internal) throw new TypeError('manifest must come from createOwnedAuthManifest');
  const results = [];
  for (const entry of [...internal.entries.values()]) {
    // Idempotent: terminal outcomes are only reported, never re-deleted.
    if (entry.outcome === 'removed' || entry.outcome === 'absent') { results.push(publicEntry(entry)); continue; }
    const eligible = entry.outcome === 'owned' || (entry.outcome === 'retained' && entry.cleanupRetryable);
    // Planned/unproven/collision/tampered/uncertain entries are never deleted:
    // no arbitrary delete API exists on this manifest.
    if (!eligible || entry.claimsUncertain) { results.push(publicEntry(entry)); continue; }
    let user;
    try {
      user = await withTimeout(auth.getUser(entry.uid), readTimeoutMs, sleep);
    } catch (err) {
      if (err?.code === 'auth/user-not-found') {
        entry.outcome = 'absent';
        entry.cleanupRetryable = false;
        log(entry, 'already-owned user absent; reported without any delete');
      } else {
        entry.cleanupRetryable = true; // transient read failure: a later run may re-verify
        retain(entry, 'transient read failure; retained for a later verified retry');
      }
      results.push(publicEntry(entry));
      continue;
    }
    let mismatch = null;
    if (!isPlainObject(user) || user.uid !== entry.uid) mismatch = 'readback uid changed or unexpected; retained';
    else if (user.metadata?.creationTime !== entry.receipt.creationTime) mismatch = 'creation timestamp changed or disagrees with the recorded receipt; retained';
    else {
      const claims = normalizeClaims(user.customClaims);
      if (claims === null || !claimsEqual(claims, entry.claimsStage.claims)) mismatch = 'current claims disagree with the recorded expected stage; retained';
    }
    if (mismatch) {
      entry.cleanupRetryable = false; // deep disagreement: never retried or deleted
      retain(entry, mismatch);
      results.push(publicEntry(entry));
      continue;
    }
    try {
      await withTimeout(auth.deleteUser(entry.uid), deleteTimeoutMs, sleep);
      entry.outcome = 'removed';
      entry.cleanupRetryable = false;
      log(entry, entry.claimsStage.kind === 'initial-empty'
        ? 'verified uid + creationTime + unchanged initial empty claim state (no claims requested); deleted'
        : 'verified uid + creationTime + full expected claims agreement; deleted');
    } catch (err) {
      entry.cleanupRetryable = true; // delete outcome unknown/failed: next run re-verifies before any retry
      retain(entry, err?.code === TIMEOUT_CODE
        ? 'deleteUser timed out; outcome unknown; a later run verifies absence before any retry'
        : 'deleteUser failed; retained for a later verified retry');
    }
    results.push(publicEntry(entry));
  }
  return { runId: internal.runId, cleanup: results };
}
