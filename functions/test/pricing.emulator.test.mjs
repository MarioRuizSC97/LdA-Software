import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

import {
  PricingError,
  createProductPricingService,
} from '../src/pricing.js';

const PROJECT_ID = 'demo-lda-inventory';
const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;

if (typeof emulatorHost !== 'string' || emulatorHost.length === 0) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required for pricing emulator tests');
}
if (projectId !== PROJECT_ID) {
  throw new Error(`pricing emulator tests require GCLOUD_PROJECT=${PROJECT_ID}`);
}

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const emulatorCredential = cert({
  projectId,
  clientEmail: 'firestore-emulator@example.invalid',
  privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
});
const app = initializeApp(
  { projectId, credential: emulatorCredential },
  `pricing-emulator-${randomUUID()}`,
);
const firestore = getFirestore(app);
const scope = `pricing-${randomUUID()}`;
const productId = `${scope}-product`;
const createdPaths = new Set();

function reference(path) {
  createdPaths.add(path);
  return firestore.doc(path);
}

function pricingRequest(idempotencyKey, overrides = {}) {
  return {
    auth: { uid: `${scope}-admin`, token: { role: 'administrator' } },
    data: {
      idempotencyKey,
      productId,
      listedPriceMxn: '999.50',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRatePercent: '16',
      ...overrides,
    },
  };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof PricingError);
    assert.equal(error.code, code);
    return true;
  });
}

test('Admin Firestore atomically serializes price updates and immutable audits', async (t) => {
  const productReference = reference(`products/${productId}`);
  const keys = {
    initial: `${scope}-initial`,
    same: `${scope}-same-key`,
    first: `${scope}-concurrent-a`,
    second: `${scope}-concurrent-b`,
    conflicting: `${scope}-conflicting-key`,
  };
  for (const key of Object.values(keys)) {
    reference(`productPriceAudits/${key}`);
    reference(`productPriceUpdateReceipts/${key}`);
  }

  t.after(async () => {
    const batch = firestore.batch();
    for (const path of createdPaths) batch.delete(firestore.doc(path));
    await batch.commit();
    await deleteApp(app);
  });

  await productReference.create({
    internalCode: productId,
    name: 'Integration product',
    quantitySpec: { unit: 'piece', precision: 0 },
    pricingUpdatedBy: `${scope}-legacy-admin`,
    testScope: scope,
  });

  const setPrice = createProductPricingService({ firestore });
  const initial = await setPrice(pricingRequest(keys.initial));
  assert.equal(initial.pricing.listedPriceCentavos, 99_950);
  const initialProduct = (await productReference.get()).data();
  assert.equal(initialProduct.pricing.currency, 'MXN');
  assert.equal('pricingUpdatedBy' in initialProduct, false);
  const initialAudit = (
    await reference(`productPriceAudits/${keys.initial}`).get()
  ).data();
  assert.equal(initialAudit.oldPricing, null);
  assert.equal(initialAudit.previousAuditId, null);
  assert.equal(initialAudit.actorId, `${scope}-admin`);

  const immutableInitialAudit = (
    await firestore.doc(`productPriceAudits/${keys.initial}`).get()
  ).data();
  const sameRequest = pricingRequest(keys.same, {
    listedPriceMxn: '1000.00',
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'zero-rated',
    ivaRatePercent: '0',
  });
  const sameResults = await Promise.all([setPrice(sameRequest), setPrice(sameRequest)]);
  assert.deepEqual(sameResults.map(({ replayed }) => replayed).sort(), [false, true]);
  assert.deepEqual(
    (await firestore.doc(`productPriceAudits/${keys.initial}`).get()).data(),
    immutableInitialAudit,
    'later updates must not rewrite a prior audit document',
  );
  assert.equal(
    (await firestore.doc(`productPriceAudits/${keys.same}`).get()).data()
      .previousAuditId,
    keys.initial,
  );

  const beforeConcurrent = (await productReference.get()).data();
  const concurrentRequests = [
    pricingRequest(keys.first, { listedPriceMxn: '800.00' }),
    pricingRequest(keys.second, { listedPriceMxn: '800.00' }),
  ];
  await Promise.all(concurrentRequests.map(setPrice));

  const audits = await Promise.all([
    firestore.doc(`productPriceAudits/${keys.first}`).get(),
    firestore.doc(`productPriceAudits/${keys.second}`).get(),
  ]);
  const firstLink = audits.find(
    (snapshot) => snapshot.data().previousAuditId === beforeConcurrent.lastPricingAuditId,
  );
  const secondLink = audits.find(
    (snapshot) => snapshot.data().previousAuditId !== beforeConcurrent.lastPricingAuditId,
  );
  assert.ok(firstLink);
  assert.ok(secondLink);
  assert.equal(secondLink.data().previousAuditId, firstLink.id);
  assert.deepEqual(firstLink.data().newPricing, secondLink.data().newPricing);
  const finalProduct = (await productReference.get()).data();
  assert.equal(finalProduct.lastPricingAuditId, secondLink.id);
  assert.equal('pricingUpdatedBy' in finalProduct, false);

  const outcomes = await Promise.allSettled([
    setPrice(pricingRequest(keys.conflicting, { listedPriceMxn: '700.00' })),
    setPrice(pricingRequest(keys.conflicting, { listedPriceMxn: '701.00' })),
  ]);
  assert.equal(outcomes.filter(({ status }) => status === 'fulfilled').length, 1);
  const rejected = outcomes.find(({ status }) => status === 'rejected');
  assert.ok(rejected.reason instanceof PricingError);
  assert.equal(rejected.reason.code, 'already-exists');

  const committed = outcomes.find(({ status }) => status === 'fulfilled').value;
  const conflictingAudit = (
    await firestore.doc(`productPriceAudits/${keys.conflicting}`).get()
  ).data();
  assert.equal(
    conflictingAudit.newPricing.listedPriceCentavos,
    committed.pricing.listedPriceCentavos,
  );
  await rejectsCode(
    () => setPrice(pricingRequest(keys.conflicting, { listedPriceMxn: '702.00' })),
    'already-exists',
  );
});
