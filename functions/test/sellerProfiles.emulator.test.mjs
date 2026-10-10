import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

import {
  SellerProfileError,
  createSellerProfileService,
} from '../src/sellerProfiles.js';

const PROJECT_ID = 'demo-lda-inventory';
const FIRESTORE_HOST = '127.0.0.1:8080';
const AUTH_HOST = '127.0.0.1:9099';

// Explicit opt-in: this file runs only against the pinned local emulators.
if (process.env.GCLOUD_PROJECT !== PROJECT_ID) {
  throw new Error(`seller profile emulator tests require GCLOUD_PROJECT=${PROJECT_ID}`);
}
if (process.env.FIRESTORE_EMULATOR_HOST !== FIRESTORE_HOST) {
  throw new Error(`seller profile emulator tests require FIRESTORE_EMULATOR_HOST=${FIRESTORE_HOST}`);
}
if (process.env.FIREBASE_AUTH_EMULATOR_HOST !== AUTH_HOST) {
  throw new Error(`seller profile emulator tests require FIREBASE_AUTH_EMULATOR_HOST=${AUTH_HOST}`);
}

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const app = initializeApp({
  projectId: PROJECT_ID,
  credential: cert({
    projectId: PROJECT_ID,
    clientEmail: 'seller-profiles-emulator@example.invalid',
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  }),
}, `seller-profiles-emulator-${randomUUID()}`);
const auth = getAuth(app);
const firestore = getFirestore(app);

// Every identity and document is owned by this run: namespaced UIDs, created
// here, deleted in teardown. Demo fixtures are never read or written.
const runId = randomUUID();
const scope = `sp-${runId}`;
const branchId = `branch-${runId}`;
const uids = {
  seller: `${scope}-seller`,
  disabled: `${scope}-disabled`,
  administrator: `${scope}-administrator`,
  badBranch: `${scope}-bad-branch`,
  corrupt: `${scope}-corrupt`,
  missing: `${scope}-missing`,
};
const createdUids = new Set();
const ADMIN = { uid: `${scope}-caller`, token: { role: 'administrator' } };
const environment = Object.freeze({
  FUNCTIONS_EMULATOR: 'true',
  GCLOUD_PROJECT: PROJECT_ID,
  FIRESTORE_EMULATOR_HOST: FIRESTORE_HOST,
  FIREBASE_AUTH_EMULATOR_HOST: AUTH_HOST,
});

async function ownedUser(uid, claims, { disabled = false } = {}) {
  await auth.createUser({ uid, disabled });
  createdUids.add(uid);
  await auth.setCustomUserClaims(uid, claims);
}

const profile = (uid) => firestore.doc(`sellerProfiles/${uid}`);
const call = (uid, displayName) => ({ auth: ADMIN, data: { uid, displayName } });

async function rejectsWith(operation, code, reason) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof SellerProfileError);
    assert.equal(error.code, code);
    assert.equal(error.reason, reason);
    return true;
  });
}

test('real Auth and Firestore emulators: claim-derived profiles, replay and fail-closed cases', async (t) => {
  t.after(async () => {
    try {
      const batch = firestore.batch();
      for (const uid of Object.values(uids)) batch.delete(profile(uid));
      await batch.commit();
      for (const uid of createdUids) await auth.deleteUser(uid);

      // Residue check: no owned identity or profile document survives the run.
      for (const uid of Object.values(uids)) {
        assert.equal((await profile(uid).get()).exists, false, `profile residue for ${uid}`);
        await assert.rejects(() => auth.getUser(uid), (error) => error.code === 'auth/user-not-found');
      }
    } finally {
      await deleteApp(app);
    }
  });

  const sellerClaims = { role: 'seller', branchId };
  await ownedUser(uids.seller, sellerClaims);
  await ownedUser(uids.disabled, sellerClaims, { disabled: true });
  await ownedUser(uids.administrator, { role: 'administrator' });
  await ownedUser(uids.badBranch, { role: 'seller', branchId: 'north' });
  await ownedUser(uids.corrupt, sellerClaims);

  const setProfile = createSellerProfileService({ firestore, auth, environment });

  // Create: exactly the two closed fields, branch from trusted claims only.
  assert.deepEqual(await setProfile(call(uids.seller, '  Ada Ruiz  ')),
    { uid: uids.seller, replayed: false });
  const created = await profile(uids.seller).get();
  assert.deepEqual(created.data(), { displayName: 'Ada Ruiz', branchId });

  // Identical content is a no-write replay: the stored update time is unchanged.
  assert.deepEqual(await setProfile(call(uids.seller, 'Ada Ruiz')),
    { uid: uids.seller, replayed: true });
  const replayed = await profile(uids.seller).get();
  assert.ok(replayed.updateTime.isEqual(created.updateTime), 'replay must not write');

  // Rename writes, and concurrent identical renames converge on one state.
  assert.deepEqual(await setProfile(call(uids.seller, 'Ada R.')),
    { uid: uids.seller, replayed: false });
  const concurrent = await Promise.all([
    setProfile(call(uids.seller, 'Ada Ruiz López')),
    setProfile(call(uids.seller, 'Ada Ruiz López')),
  ]);
  for (const result of concurrent) assert.equal(result.uid, uids.seller);
  assert.deepEqual((await profile(uids.seller).get()).data(),
    { displayName: 'Ada Ruiz López', branchId });

  // A disabled seller stays maintainable; Auth state and claims never change.
  assert.deepEqual(await setProfile(call(uids.disabled, 'Bea Soto')),
    { uid: uids.disabled, replayed: false });
  const disabledUser = await auth.getUser(uids.disabled);
  assert.equal(disabledUser.disabled, true);
  assert.deepEqual(disabledUser.customClaims, sellerClaims);
  assert.deepEqual((await auth.getUser(uids.seller)).customClaims, sellerClaims);

  // Fail closed before any write.
  await rejectsWith(() => setProfile(call(uids.missing, 'Nadie')), 'not-found');
  await rejectsWith(() => setProfile(call(uids.administrator, 'Admin')),
    'failed-precondition', 'not-a-seller');
  await rejectsWith(() => setProfile(call(uids.badBranch, 'Sin Sucursal')),
    'failed-precondition', 'invalid-branch-claim');
  for (const uid of [uids.missing, uids.administrator, uids.badBranch]) {
    assert.equal((await profile(uid).get()).exists, false, `no profile for ${uid}`);
  }

  // A malformed stored profile is neither merged over nor rewritten.
  const corrupt = { displayName: 'Old', branchId, extra: true };
  await profile(uids.corrupt).set(corrupt);
  await rejectsWith(() => setProfile(call(uids.corrupt, 'New')),
    'failed-precondition', 'invalid-stored-profile');
  assert.deepEqual((await profile(uids.corrupt).get()).data(), corrupt);

  // Non-administrators never reach Auth or Firestore.
  await rejectsWith(() => setProfile({
    auth: { uid: uids.seller, token: sellerClaims },
    data: { uid: uids.seller, displayName: 'Self Named' },
  }), 'permission-denied');
  assert.equal((await profile(uids.seller).get()).data().displayName, 'Ada Ruiz López');
});
