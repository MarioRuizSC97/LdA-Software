import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

import {
  CatalogError,
  createProductCreationService,
} from '../src/catalog.js';

const PROJECT_ID = 'demo-lda-inventory';
const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;

if (typeof emulatorHost !== 'string' || emulatorHost.length === 0) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required for catalog emulator tests');
}
if (projectId !== PROJECT_ID) {
  throw new Error(`catalog emulator tests require GCLOUD_PROJECT=${PROJECT_ID}`);
}

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const emulatorCredential = cert({
  projectId,
  clientEmail: 'firestore-emulator@example.invalid',
  privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
});
const app = initializeApp(
  { projectId, credential: emulatorCredential },
  `catalog-emulator-${randomUUID()}`,
);
const firestore = getFirestore(app);
const scope = `catalog-${randomUUID()}`;
const createdPaths = new Set();

function reference(path) {
  createdPaths.add(path);
  return firestore.doc(path);
}

function request(idempotencyKey, overrides = {}) {
  return {
    auth: { uid: `${scope}-admin`, token: { role: 'administrator' } },
    data: {
      idempotencyKey,
      name: 'Integration coffee',
      quantitySpec: { unit: 'kg', precision: 3 },
      ...overrides,
    },
  };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof CatalogError);
    assert.equal(error.code, code);
    return true;
  });
}

test('Admin Firestore creates one stable product under retries and code collisions', async (t) => {
  const collisionCode = `${scope}-collision`.toUpperCase();
  const uniqueCode = `${scope}-unique`.toUpperCase();
  const concurrentCodes = [
    `${scope}-concurrent-a`.toUpperCase(),
    `${scope}-concurrent-b`.toUpperCase(),
  ];
  const collisionReference = reference(`products/${collisionCode}`);
  const uniqueReference = reference(`products/${uniqueCode}`);
  const collisionReceipt = reference(
    `productCreationReceipts/${scope}-collision-request`,
  );
  const concurrentReceipt = reference(
    `productCreationReceipts/${scope}-concurrent-request`,
  );
  for (const code of concurrentCodes) {
    reference(`products/${code}`);
  }

  t.after(async () => {
    const batch = firestore.batch();
    for (const path of createdPaths) {
      batch.delete(firestore.doc(path));
    }
    await batch.commit();
    await deleteApp(app);
  });

  await collisionReference.create({
    internalCode: collisionCode,
    name: 'Existing product',
    quantitySpec: { unit: 'piece', precision: 0 },
  });

  let collisionIndex = 0;
  const createAfterCollision = createProductCreationService({
    firestore,
    generateInternalCode: () => [collisionCode, uniqueCode][collisionIndex++],
  });
  const created = await createAfterCollision(
    request(`${scope}-collision-request`),
  );

  assert.equal(created.productId, uniqueCode);
  assert.equal((await collisionReference.get()).data().name, 'Existing product');
  const uniqueProduct = (await uniqueReference.get()).data();
  assert.deepEqual(uniqueProduct.quantitySpec, {
    unit: 'kg',
    precision: 3,
  });
  assert.equal(uniqueProduct.salePrice, undefined);
  assert.equal('createdBy' in uniqueProduct, false);
  const creationReceipt = (await collisionReceipt.get()).data();
  assert.equal(creationReceipt.result.productId, uniqueCode);
  assert.equal(creationReceipt.actorId, `${scope}-admin`);

  let concurrentIndex = 0;
  const createConcurrent = createProductCreationService({
    firestore,
    generateInternalCode: () => concurrentCodes[concurrentIndex++],
  });
  const sameRequest = request(`${scope}-concurrent-request`, {
    name: 'Concurrent product',
  });
  const results = await Promise.all([
    createConcurrent(sameRequest),
    createConcurrent(sameRequest),
  ]);

  assert.equal(results[0].productId, results[1].productId);
  assert.deepEqual(
    results.map(({ replayed }) => replayed).sort(),
    [false, true],
  );
  const concurrentReceiptData = (await concurrentReceipt.get()).data();
  assert.equal(concurrentReceiptData.result.productId, results[0].productId);
  assert.equal(concurrentReceiptData.actorId, `${scope}-admin`);

  await rejectsCode(
    () => createConcurrent({
      ...sameRequest,
      auth: { uid: `${scope}-second-admin`, token: { role: 'administrator' } },
    }),
    'already-exists',
  );
  assert.equal((await concurrentReceipt.get()).data().actorId, `${scope}-admin`);

  await rejectsCode(
    () => createConcurrent(request(`${scope}-concurrent-request`, {
      name: 'Conflicting product',
    })),
    'already-exists',
  );
});
