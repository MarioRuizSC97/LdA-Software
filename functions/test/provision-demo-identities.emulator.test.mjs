import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

import {
  DEMO_ACCOUNTS,
  buildDemoSeed,
  provisionDemo,
  provisionDemoWithServices,
  validateEmulatorEnvironment,
} from '../scripts/provision-demo-identities.mjs';

const configuration = validateEmulatorEnvironment(process.env);

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const app = initializeApp({
  projectId: configuration.projectId,
  credential: cert({
    projectId: configuration.projectId,
    clientEmail: 'provision-test@demo-lda-inventory.invalid',
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  }),
}, `provision-test-${randomUUID()}`);
const auth = getAuth(app);
const firestore = getFirestore(app);

test('real Auth and Firestore emulators provision once, preserve unrelated data, and fail closed on drift', async (t) => {
  t.after(() => deleteApp(app));

  const unrelatedReference = firestore.doc('unrelated/provision-test-owned');
  await unrelatedReference.create({ owner: 'integration-test', keep: true });

  let failClaimsOnce = true;
  const failingAuth = {
    getUser: (uid) => auth.getUser(uid),
    getUserByEmail: (email) => auth.getUserByEmail(email),
    createUser: (input) => auth.createUser(input),
    updateUser: (uid, input) => auth.updateUser(uid, input),
    deleteUser: (uid) => auth.deleteUser(uid),
    setCustomUserClaims: (uid, claims) => {
      if (failClaimsOnce) {
        failClaimsOnce = false;
        throw new Error('injected claims failure');
      }
      return auth.setCustomUserClaims(uid, claims);
    },
  };
  await assert.rejects(
    () => provisionDemoWithServices({ auth: failingAuth, firestore }),
    /injected claims failure/,
  );
  await assert.rejects(
    () => auth.getUser(DEMO_ACCOUNTS[0].uid),
    (error) => error.code === 'auth/user-not-found',
  );
  assert.equal((await unrelatedReference.get()).data().keep, true);

  const concurrent = await Promise.all([provisionDemo(), provisionDemo()]);
  assert.equal(
    concurrent.reduce((sum, result) => sum + result.accountsCreated, 0),
    DEMO_ACCOUNTS.length,
  );
  assert.equal(
    concurrent.reduce((sum, result) => sum + result.recordsCreated, 0),
    buildDemoSeed().length,
  );

  for (const account of DEMO_ACCOUNTS) {
    const user = await auth.getUser(account.uid);
    assert.equal(user.email, account.email);
    assert.equal(user.emailVerified, false);
    assert.equal(user.disabled, false);
    assert.deepEqual(user.customClaims, account.claims);
  }

  for (const { path, data } of buildDemoSeed()) {
    const snapshot = await firestore.doc(path).get();
    assert.equal(snapshot.exists, true, path);
    assert.deepEqual(snapshot.data(), data, path);
  }
  assert.deepEqual((await unrelatedReference.get()).data(), {
    owner: 'integration-test',
    keep: true,
  });

  const second = await provisionDemo();
  assert.equal(second.accountsCreated, 0);
  assert.equal(second.recordsCreated, 0);
  assert.ok(second.accountResults.every(({ status }) => status === 'reused'));

  const zeroStock = await firestore.doc(
    'branches/branch-north/stock/DEMO-RIBBON',
  ).get();
  assert.equal(zeroStock.data().quantityScaled, 0);

  const productReference = firestore.doc('products/DEMO-COFFEE');
  const driftedProduct = {
    ...(await productReference.get()).data(),
    unexpected: true,
  };
  await productReference.update({ unexpected: true });
  await assert.rejects(() => provisionDemo(), /unexpected shape/i);
  assert.deepEqual((await productReference.get()).data(), driftedProduct);
  assert.deepEqual((await unrelatedReference.get()).data(), {
    owner: 'integration-test',
    keep: true,
  });
});
