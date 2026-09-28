import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

import {
  CALCULATION_POLICY_VERSION,
  InventoryError,
  createStockIntakeService,
} from '../src/inventory.js';

const PROJECT_ID = 'demo-lda-inventory';
const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
const projectId = process.env.GCLOUD_PROJECT;

if (typeof emulatorHost !== 'string' || emulatorHost.length === 0) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required for inventory emulator tests');
}
if (projectId !== PROJECT_ID) {
  throw new Error(`inventory emulator tests require GCLOUD_PROJECT=${PROJECT_ID}`);
}

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
const emulatorCredential = cert({
  projectId,
  clientEmail: 'firestore-emulator@example.invalid',
  privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
});
const app = initializeApp(
  { projectId, credential: emulatorCredential },
  `inventory-emulator-${randomUUID()}`,
);
const firestore = getFirestore(app);
const scope = `inventory-${randomUUID()}`;
const branchId = `${scope}-branch`;
const secondBranchId = `${scope}-branch-two`;
const productId = `${scope}-product`;
const missingBranchId = `${scope}-missing`;
const createdPaths = new Set();

function reference(path) {
  createdPaths.add(path);
  return firestore.doc(path);
}

function intakeRequest(idempotencyKey, overrides = {}) {
  return {
    auth: { uid: `${scope}-admin`, token: { role: 'administrator' } },
    data: {
      idempotencyKey,
      branchId,
      productId,
      quantity: '2',
      unitCostMxn: '71.25',
      ...overrides,
    },
  };
}

async function rejectsCode(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof InventoryError);
    assert.equal(error.code, code);
    return true;
  });
}

test('Admin Firestore preserves stock-intake transaction and idempotency semantics', async (t) => {
  const branchReference = reference(`branches/${branchId}`);
  const productReference = reference(`products/${productId}`);
  const stockReference = reference(`branches/${branchId}/stock/${productId}`);
  const secondBranchReference = reference(`branches/${secondBranchId}`);
  const secondStockReference = reference(
    `branches/${secondBranchId}/stock/${productId}`,
  );
  const costReference = reference(`costs/${productId}`);

  const intakeIds = [
    `${scope}-initial`,
    `${scope}-concurrent-a`,
    `${scope}-concurrent-b`,
    `${scope}-second-branch`,
  ];
  const missingIntakeId = `${scope}-missing-branch`;
  const identicalConcurrentId = `${scope}-same-key`;
  const conflictingConcurrentId = `${scope}-conflicting-key`;

  for (const intakeId of [
    ...intakeIds,
    missingIntakeId,
    identicalConcurrentId,
    conflictingConcurrentId,
  ]) {
    reference(`stockIntakeEntries/${intakeId}`);
    reference(`inventoryMovements/${intakeId}`);
    reference(`stockIntakeReceipts/${intakeId}`);
  }

  t.after(async () => {
    const paths = [...createdPaths].sort(
      (left, right) => right.split('/').length - left.split('/').length,
    );
    for (let index = 0; index < paths.length; index += 400) {
      const batch = firestore.batch();
      for (const path of paths.slice(index, index + 400)) {
        batch.delete(firestore.doc(path));
      }
      await batch.commit();
    }
    await deleteApp(app);
  });

  const seed = firestore.batch();
  seed.create(branchReference, { name: 'Integration branch', testScope: scope });
  seed.create(secondBranchReference, {
    name: 'Second integration branch',
    testScope: scope,
  });
  seed.create(productReference, {
    name: 'Integration product',
    quantitySpec: { unit: 'piece', precision: 0 },
    testScope: scope,
  });
  seed.create(stockReference, {
    quantityScaled: 3,
    unit: 'piece',
    precision: 0,
    testScope: scope,
  });
  await seed.commit();

  const intake = createStockIntakeService({ firestore });
  const initialRequest = intakeRequest(intakeIds[0]);
  const initial = await intake(initialRequest);

  assert.deepEqual(initial, {
    entryId: intakeIds[0],
    movementId: intakeIds[0],
    quantityScaled: 2,
    stockQuantityScaled: 5,
    unitCostCentavos: 7_125,
    lineTotalCentavos: 14_250,
    replayed: false,
  });

  const [entrySnapshot, movementSnapshot, stockSnapshot, receiptSnapshot] = await Promise.all([
    firestore.doc(`stockIntakeEntries/${intakeIds[0]}`).get(),
    firestore.doc(`inventoryMovements/${intakeIds[0]}`).get(),
    stockReference.get(),
    firestore.doc(`stockIntakeReceipts/${intakeIds[0]}`).get(),
  ]);
  assert.equal(entrySnapshot.data().calculationPolicyVersion, CALCULATION_POLICY_VERSION);
  assert.equal(movementSnapshot.data().entryId, intakeIds[0]);
  assert.equal(stockSnapshot.data().quantityScaled, 5);
  assert.equal(receiptSnapshot.data().result.stockQuantityScaled, 5);

  const replay = await intake(initialRequest);
  assert.equal(replay.replayed, true);
  assert.equal(replay.stockQuantityScaled, 5);
  await rejectsCode(
    () => intake(intakeRequest(intakeIds[0], { quantity: '3' })),
    'already-exists',
  );
  assert.equal((await stockReference.get()).data().quantityScaled, 5);

  await rejectsCode(
    () => intake(intakeRequest(missingIntakeId, { branchId: missingBranchId })),
    'not-found',
  );
  for (const path of [
    `branches/${missingBranchId}/stock/${productId}`,
    `stockIntakeEntries/${missingIntakeId}`,
    `inventoryMovements/${missingIntakeId}`,
    `stockIntakeReceipts/${missingIntakeId}`,
  ]) {
    assert.equal((await firestore.doc(path).get()).exists, false, `${path} must not exist`);
  }

  await Promise.all([
    intake(intakeRequest(intakeIds[1], { quantity: '4', unitCostMxn: '80.00' })),
    intake(intakeRequest(intakeIds[2], { quantity: '7', unitCostMxn: '90.00' })),
  ]);

  assert.equal((await stockReference.get()).data().quantityScaled, 16);
  const latestCost = (await costReference.get()).data();
  const expectedCosts = new Map([
    [intakeIds[1], 8_000],
    [intakeIds[2], 9_000],
  ]);
  assert.equal(
    latestCost.latestUnitCostCentavos,
    expectedCosts.get(latestCost.sourceEntryId),
    'latest cost and source entry must come from the same committed intake',
  );

  await intake(intakeRequest(intakeIds[3], {
    branchId: secondBranchId,
    quantity: '1',
    unitCostMxn: '95.50',
  }));
  assert.equal((await secondStockReference.get()).data().quantityScaled, 1);
  const latestCrossBranchCost = (await costReference.get()).data();
  assert.equal(latestCrossBranchCost.latestUnitCostCentavos, 9_550);
  assert.equal(latestCrossBranchCost.sourceEntryId, intakeIds[3]);

  await t.test('simultaneous identical keys commit once and replay once', async () => {
    const identicalRequest = intakeRequest(identicalConcurrentId, { quantity: '3' });
    const results = await Promise.all([
      intake(identicalRequest),
      intake(identicalRequest),
    ]);

    assert.deepEqual(
      results.map(({ replayed }) => replayed).sort(),
      [false, true],
    );
    assert.equal((await stockReference.get()).data().quantityScaled, 19);

    const [entry, movement, receipt] = await Promise.all([
      firestore.doc(`stockIntakeEntries/${identicalConcurrentId}`).get(),
      firestore.doc(`inventoryMovements/${identicalConcurrentId}`).get(),
      firestore.doc(`stockIntakeReceipts/${identicalConcurrentId}`).get(),
    ]);
    assert.equal(entry.exists, true);
    assert.equal(movement.exists, true);
    assert.equal(receipt.exists, true);
    assert.equal(entry.data().quantityScaled, 3);
    assert.equal(receipt.data().result.stockQuantityScaled, 19);
  });

  await t.test('simultaneous conflicting keys accept one payload only', async () => {
    const outcomes = await Promise.allSettled([
      intake(intakeRequest(conflictingConcurrentId, { quantity: '5' })),
      intake(intakeRequest(conflictingConcurrentId, { quantity: '6' })),
    ]);
    const fulfilled = outcomes.filter(({ status }) => status === 'fulfilled');
    const rejected = outcomes.filter(({ status }) => status === 'rejected');

    assert.equal(fulfilled.length, 1);
    assert.equal(rejected.length, 1);
    assert.ok(rejected[0].reason instanceof InventoryError);
    assert.equal(rejected[0].reason.code, 'already-exists');

    const committedQuantity = fulfilled[0].value.quantityScaled;
    assert.ok(committedQuantity === 5 || committedQuantity === 6);
    assert.equal(
      (await stockReference.get()).data().quantityScaled,
      19 + committedQuantity,
    );

    const [entry, movement, receipt] = await Promise.all([
      firestore.doc(`stockIntakeEntries/${conflictingConcurrentId}`).get(),
      firestore.doc(`inventoryMovements/${conflictingConcurrentId}`).get(),
      firestore.doc(`stockIntakeReceipts/${conflictingConcurrentId}`).get(),
    ]);
    assert.equal(entry.data().quantityScaled, committedQuantity);
    assert.equal(movement.data().quantityScaled, committedQuantity);
    assert.equal(receipt.data().result.quantityScaled, committedQuantity);
  });
});
