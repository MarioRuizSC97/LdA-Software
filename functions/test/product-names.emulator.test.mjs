import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

import {
  CatalogError,
  createProductRenameService,
} from '../src/product-names.js';

// Run only against an isolated local emulator with FIRESTORE_EMULATOR_HOST
// and GCLOUD_PROJECT=demo-lda-inventory, like the other emulator suites.

const PROJECT_ID = 'demo-lda-inventory';
const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;

if (typeof emulatorHost !== 'string' || emulatorHost.length === 0) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required for product-names emulator tests');
}
if (projectId !== PROJECT_ID) {
  throw new Error(`product-names emulator tests require GCLOUD_PROJECT=${PROJECT_ID}`);
}

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const emulatorCredential = cert({
  projectId,
  clientEmail: 'firestore-emulator@example.invalid',
  privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
});
const app = initializeApp(
  { projectId, credential: emulatorCredential },
  `product-names-emulator-${randomUUID()}`,
);
const firestore = getFirestore(app);
const scope = `rename-${randomUUID()}`;
const createdPaths = new Set();

function reference(path) {
  createdPaths.add(path);
  return firestore.doc(path);
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof CatalogError);
    assert.equal(error.code, code);
    return true;
  });
}

test('Admin Firestore renames only the product name and keeps the historical sale', async (t) => {
  const productCode = `${scope}-product`.toUpperCase();
  const productReference = reference(`products/${productCode}`);
  const saleReference = reference(`sales/${scope}-sale`);
  const receiptReference = reference(`productNameUpdateReceipts/${scope}-request`);
  const oldName = 'Café de olla';
  const newName = 'Café de olla 500 g';
  const product = {
    internalCode: productCode,
    name: oldName,
    quantitySpec: { unit: 'pieza', precision: 0 },
    pricing: {
      listedPriceCentavos: 9_500,
      currency: 'MXN',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRateBasisPoints: 1_600,
    },
  };
  const sale = {
    items: [{ productId: productCode, productName: oldName, quantity: 2 }],
  };

  t.after(async () => {
    const batch = firestore.batch();
    for (const path of createdPaths) {
      batch.delete(firestore.doc(path));
    }
    await batch.commit();
    await deleteApp(app);
  });

  await productReference.create(product);
  await saleReference.create(sale);

  const renameProduct = createProductRenameService({ firestore });
  const rename = {
    auth: { uid: `${scope}-admin`, token: { role: 'administrator' } },
    data: { idempotencyKey: `${scope}-request`, productId: productCode, name: newName },
  };

  const result = await renameProduct(rename);

  assert.deepEqual(result, {
    productId: productCode,
    oldName,
    newName,
    replayed: false,
  });
  const renamed = (await productReference.get()).data();
  assert.equal(renamed.name, newName);
  assert.deepEqual(renamed.quantitySpec, product.quantitySpec);
  assert.deepEqual(renamed.pricing, product.pricing);
  assert.equal(renamed.nameUpdatedAt, undefined);
  assert.deepEqual((await saleReference.get()).data(), sale);

  const receipt = (await receiptReference.get()).data();
  assert.equal(receipt.actorId, `${scope}-admin`);
  assert.deepEqual(receipt.result, {
    productId: productCode,
    oldName,
    newName,
  });

  const replay = await renameProduct(rename);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay, { ...receipt.result, replayed: true });

  await rejectsCode(
    () => renameProduct({
      ...rename,
      data: { ...rename.data, name: 'A conflicting rename' },
    }),
    'already-exists',
  );
  assert.equal((await productReference.get()).data().name, newName);

  await rejectsCode(
    () => renameProduct({
      ...rename,
      auth: { uid: `${scope}-seller`, token: { role: 'seller' } },
    }),
    'permission-denied',
  );
  await rejectsCode(
    () => renameProduct({
      ...rename,
      data: {
        ...rename.data,
        idempotencyKey: `${scope}-missing-request`,
        productId: `${scope}-missing`.toUpperCase(),
      },
    }),
    'not-found',
  );
});
