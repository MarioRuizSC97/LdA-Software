const DEMO_PROJECT_ID = 'demo-lda-inventory';
const FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080';
const AUTH_EMULATOR_HOST = '127.0.0.1:9099';
const ADMINISTRATOR_ROLE = 'administrator';
const SELLER_ROLE = 'seller';
const UID_MAX_LENGTH = 128;
const DISPLAY_NAME_MAX_LENGTH = 120;
const REQUEST_FIELDS = ['displayName', 'uid'];
const PROFILE_FIELDS = ['branchId', 'displayName'];
const BRANCH_CLAIM_PATTERN = /^branch-[a-z0-9]+(?:-[a-z0-9]+)*$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F]/;
const RESERVED_DOCUMENT_ID_PATTERN = /^__.*__$/;
const REASON_PATTERN = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/;

/**
 * Public error with a callable code and an optional kebab-case machine
 * `reason`. A reason exists only where one public code covers cases the
 * client must tell apart (every reason today is a `failed-precondition`).
 */
export class SellerProfileError extends Error {
  constructor(code, message, reason) {
    super(message);
    this.name = 'SellerProfileError';
    this.code = code;
    if (reason !== undefined) {
      if (typeof reason !== 'string' || !REASON_PATTERN.test(reason)) {
        throw new TypeError('seller profile error reason must be kebab-case');
      }
      this.reason = reason;
    }
  }
}

/**
 * Pure guard shared by the service and the callable before any SDK work,
 * modeled on assertLocalSalesEmulator: the pinned demo project, the emulator
 * flag and the exact Firestore host, plus the exact Auth emulator host because
 * this service reads trusted identities. Environment values are never echoed.
 */
export function assertLocalSellerProfilesEmulator(environment = process.env) {
  let valid = environment?.GCLOUD_PROJECT === DEMO_PROJECT_ID
    && environment?.FUNCTIONS_EMULATOR === 'true'
    && environment?.FIRESTORE_EMULATOR_HOST === FIRESTORE_EMULATOR_HOST
    && environment?.FIREBASE_AUTH_EMULATOR_HOST === AUTH_EMULATOR_HOST;
  // Optional Admin project sources must agree, never override the pinned ID.
  if (environment?.GOOGLE_CLOUD_PROJECT !== undefined) {
    valid &&= environment.GOOGLE_CLOUD_PROJECT === DEMO_PROJECT_ID;
  }
  if (environment?.FIREBASE_CONFIG !== undefined) {
    try {
      // Accept inline JSON only: a config path must never trigger a file read.
      const config = typeof environment.FIREBASE_CONFIG === 'string'
        ? JSON.parse(environment.FIREBASE_CONFIG) : null;
      valid &&= config !== null && typeof config === 'object'
        && !Array.isArray(config) && config.projectId === DEMO_PROJECT_ID;
    } catch {
      valid = false;
    }
  }
  if (!valid) {
    throw new SellerProfileError(
      'failed-precondition',
      'seller profiles require the dedicated local demo emulator',
    );
  }
}

/**
 * Build the administrator-only seller-profile mutation service around an
 * injected Admin Firestore instance and a trusted Admin Auth boundary. Only
 * `sellerProfiles/{uid}` with exactly `displayName` and `branchId` is written;
 * the target branch always comes from the resolved Auth claims, never the
 * request. No user provisioning, reactivation, claim change or deletion.
 *
 * Concurrency limits are deliberate and unfixable here:
 * - The Auth identity read and the Firestore transaction are not one atomic
 *   operation. A concurrent claim change or user deletion after the single
 *   identity read can leave the stored branchId stale (TOCTOU). A second Auth
 *   read would not close that window, so this service reads identity once.
 * - `replayed: true` is content idempotence only, not a key-bound retry
 *   receipt: concurrent writers with equal content may disagree on the flag.
 * - Last transaction writer wins; there is no optimistic versioning.
 */
export function createSellerProfileService({ firestore, auth, environment = process.env } = {}) {
  if (
    !firestore
    || typeof firestore.doc !== 'function'
    || typeof firestore.runTransaction !== 'function'
  ) {
    throw new TypeError('an Admin Firestore-compatible instance is required');
  }
  if (!auth || typeof auth.getUser !== 'function') {
    throw new TypeError('a trusted Admin Auth boundary is required');
  }

  return async function setSellerProfile(request = {}) {
    assertLocalSellerProfilesEmulator(environment);
    authorizeAdministrator(request?.auth);
    const input = validateRequest(request?.data);
    const profileReference = firestore.doc(`sellerProfiles/${input.uid}`);

    // Exactly one trusted identity read, after the caller gate and request
    // validation, so neither can leak identity lookups to unauthorized callers.
    let user;
    try {
      user = await auth.getUser(input.uid);
    } catch (error) {
      throw mapIdentityFailure(error);
    }
    const branchId = trustedBranchId(user, input.uid);

    return firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(profileReference);
      if (snapshot.exists) {
        const stored = validStoredProfile(snapshot.data());
        if (stored.displayName === input.displayName && stored.branchId === branchId) {
          return { uid: input.uid, replayed: true };
        }
      }
      // Full-document set of the closed two-field schema: no merge, no uid,
      // timestamps or private fields inside the public profile document.
      transaction.set(profileReference, { displayName: input.displayName, branchId });
      return { uid: input.uid, replayed: false };
    });
  };
}

function authorizeAdministrator(auth) {
  if (!auth || typeof auth.uid !== 'string' || auth.uid.length === 0) {
    throw new SellerProfileError('unauthenticated', 'authentication is required');
  }
  // A valid current token is the trusted callable boundary; it is not proof
  // against revocation latency, which stays outside this feature.
  if (auth.token?.role !== ADMINISTRATOR_ROLE) {
    throw new SellerProfileError('permission-denied', 'administrator role is required');
  }
  return auth.uid;
}

function validateRequest(data) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw new SellerProfileError('invalid-argument', 'request data is required');
  }
  assertExactFields(data, REQUEST_FIELDS, 'request');

  // Every field is read exactly once and frozen into a detached snapshot:
  // later mutation of the caller request object cannot change the target,
  // the authority or the stored content while the Auth lookup is pending.
  const uid = validTargetUid(data.uid);
  const displayName = validDisplayName(data.displayName);
  return Object.freeze({ uid, displayName });
}

function validTargetUid(value) {
  if (
    typeof value !== 'string'
    || value.length === 0
    || value.length > UID_MAX_LENGTH
    || CONTROL_CHARACTER_PATTERN.test(value)
    || value.includes('/')
    || value.includes('\\')
    || value === '.'
    || value === '..'
    || RESERVED_DOCUMENT_ID_PATTERN.test(value)
  ) {
    throw new SellerProfileError(
      'invalid-argument',
      `uid must be an exact path-safe identifier of 1 to ${UID_MAX_LENGTH} characters`,
    );
  }
  // Deliberately no trim, case fold or Unicode normalization: the validated
  // string is the exact document id used for both the Auth lookup and path.
  return value;
}

function validDisplayName(value) {
  if (typeof value !== 'string') {
    throw new SellerProfileError('invalid-argument', 'displayName must be a text string');
  }
  const trimmed = value.trim();
  if (
    trimmed.length === 0
    || trimmed.length > DISPLAY_NAME_MAX_LENGTH
    || CONTROL_CHARACTER_PATTERN.test(trimmed)
  ) {
    throw new SellerProfileError(
      'invalid-argument',
      `displayName must hold 1 to ${DISPLAY_NAME_MAX_LENGTH} characters after trimming, without control characters`,
    );
  }
  return trimmed;
}

function mapIdentityFailure(error) {
  if (error?.code === 'auth/user-not-found' || error?.code === 'auth/uid-not-found') {
    return new SellerProfileError('not-found', 'seller identity does not exist');
  }
  // Never propagate raw SDK messages: they can carry transport or account data.
  return new SellerProfileError('internal', 'seller identity lookup failed');
}

function trustedBranchId(user, targetUid) {
  if (user === null || typeof user !== 'object') {
    throw new SellerProfileError('not-found', 'seller identity does not exist');
  }
  if (user.uid !== targetUid) {
    throw new SellerProfileError('internal', 'seller identity lookup failed');
  }
  // A disabled seller is explicitly maintainable by administrators for stable
  // historical names: no reactivation, claim change or deletion happens here.
  if (user.customClaims?.role !== SELLER_ROLE) {
    throw new SellerProfileError('failed-precondition', 'target user is not a seller', 'not-a-seller');
  }
  const branchId = user.customClaims.branchId;
  if (typeof branchId !== 'string' || !BRANCH_CLAIM_PATTERN.test(branchId)) {
    throw new SellerProfileError(
      'failed-precondition',
      'seller branch claim is invalid',
      'invalid-branch-claim',
    );
  }
  return branchId;
}

function validStoredProfile(data) {
  const fields = data === null || typeof data !== 'object' || Array.isArray(data)
    ? null
    : Object.keys(data).sort();
  if (
    fields === null
    || fields.length !== PROFILE_FIELDS.length
    || fields.some((field, index) => field !== PROFILE_FIELDS[index])
    || typeof data.displayName !== 'string'
    || data.displayName.length === 0
    || data.displayName.length > DISPLAY_NAME_MAX_LENGTH
    || data.displayName !== data.displayName.trim()
    || CONTROL_CHARACTER_PATTERN.test(data.displayName)
    || typeof data.branchId !== 'string'
    || !BRANCH_CLAIM_PATTERN.test(data.branchId)
  ) {
    // Fail closed: an extended or malformed stored profile is neither merged
    // over nor silently rewritten; unknown persisted data stays untouched.
    throw new SellerProfileError(
      'failed-precondition',
      'existing seller profile is invalid',
      'invalid-stored-profile',
    );
  }
  return { displayName: data.displayName, branchId: data.branchId };
}

function assertExactFields(value, expected, label) {
  const actual = Object.keys(value).sort();
  if (
    actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])
  ) {
    throw new SellerProfileError(
      'invalid-argument',
      `${label} contains missing or unsupported fields`,
    );
  }
}
