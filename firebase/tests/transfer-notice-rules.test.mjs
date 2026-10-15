/**
 * DN-01 — public-service Firestore rules proof for destination transfer notice
 * markers.
 *
 * ISOLATION GUARD (read before anything else): this suite mutates emulator
 * data, so it refuses to start unless the caller EXPLICITLY supplies the
 * dedicated isolated emulator address. Both `FIRESTORE_EMULATOR_HOST` and the
 * opt-in variable below must name `127.0.0.1:8280` exactly — never the
 * developer's main runtime on port 8080 and never a live project. Without the
 * opt-in the file exits without importing any Firebase module and without
 * touching any data, so an accidental `node --test firebase/tests` run can
 * never probe the current runtime.
 *
 * Authorization for a run belongs to the parent orchestrator: start the
 * isolated Firestore emulator on 127.0.0.1:8280, then run
 *   LDA_TRANSFER_NOTICE_RULES_EMULATOR=127.0.0.1:8280 \
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8280 \
 *   node --test firebase/tests/transfer-notice-rules.test.mjs
 */

const ISOLATED_ADDRESS = '127.0.0.1:8280';
const OPT_IN_VARIABLE = 'LDA_TRANSFER_NOTICE_RULES_EMULATOR';
const optIn = process.env[OPT_IN_VARIABLE];
const emulatorAddress = process.env.FIRESTORE_EMULATOR_HOST;

if (optIn !== ISOLATED_ADDRESS || emulatorAddress !== ISOLATED_ADDRESS) {
  console.error(
    `[transfer-notice-rules] NOT RUN: this suite requires the explicitly supplied isolated emulator `
    + `(${OPT_IN_VARIABLE}=${ISOLATED_ADDRESS} and FIRESTORE_EMULATOR_HOST=${ISOLATED_ADDRESS}). `
    + `No data was read or mutated and no Firebase module was imported.`,
  );
  process.exit(0);
}

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = await import('@firebase/rules-unit-testing');
const {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
} = await import('firebase/firestore');
const { readFile } = await import('node:fs/promises');
const { after, before, beforeEach, describe, test } = await import('node:test');

const projectId = 'demo-lda-inventory';
const branchNorth = 'branch-north';
const branchSouth = 'branch-south';
const transferId = 'tr-001';
const ownerUid = 'seller-south';
const ownerMarkerPath = `transferNoticeReads/${ownerUid}/branches/${branchSouth}/transfers/${transferId}`;
const otherSellerMarkerPath = `transferNoticeReads/seller-north/branches/${branchSouth}/transfers/${transferId}`;
const otherBranchMarkerPath = `transferNoticeReads/${ownerUid}/branches/${branchNorth}/transfers/${transferId}`;
const markerData = {
  userId: ownerUid,
  branchId: branchSouth,
  transferId,
  readAt: new Date(1_700_000_500_000),
};
const transferAuditData = {
  transferId,
  sourceBranchId: branchNorth,
  destinationBranchId: branchSouth,
  productIds: ['DEMO-COFFEE'],
  lineCount: 1,
  lines: [{ productId: 'DEMO-COFFEE', quantity: '2', quantityScaled: 2, unit: 'piece', precision: 0 }],
  actorId: 'admin-one',
  createdAt: new Date(1_700_000_400_000),
};

let testEnvironment;

function firestoreFor(userId, claims = {}) {
  return testEnvironment.authenticatedContext(userId, claims).firestore();
}

const ownerSeller = () => firestoreFor(ownerUid, { role: 'seller', branchId: branchSouth });
const otherSeller = () => firestoreFor('seller-north', { role: 'seller', branchId: branchSouth });
const administrator = () => firestoreFor('admin', { role: 'administrator' });
const anonymous = () => testEnvironment.unauthenticatedContext().firestore();

async function seedFirestore() {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    await setDoc(doc(firestore, 'transfers', transferId), transferAuditData);
    await setDoc(doc(firestore, ownerMarkerPath), markerData);
    await setDoc(doc(firestore, otherSellerMarkerPath), {
      ...markerData,
      userId: 'seller-north',
    });
    await setDoc(doc(firestore, otherBranchMarkerPath), {
      ...markerData,
      branchId: branchNorth,
    });
    await setDoc(doc(firestore, 'unmodeledRecords', 'private-record'), { secret: true });
  });
}

before(async () => {
  const [host, portText] = emulatorAddress.split(':');
  const port = Number(portText);
  if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`isolated emulator address is unusable: ${emulatorAddress}`);
  }
  testEnvironment = await initializeTestEnvironment({
    projectId,
    host,
    port,
    firestore: {
      rules: await readFile(new URL('../../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();
  await seedFirestore();
});

after(async () => {
  await testEnvironment?.cleanup();
});

describe('owner seller marker reads', () => {
  test('gets and lists only own current-branch markers', async () => {
    const firestore = ownerSeller();

    const marker = await assertSucceeds(getDoc(doc(firestore, ownerMarkerPath)));
    if (marker.data().readAt == null || marker.data().userId !== ownerUid) {
      throw new Error('the owner must read the marker the callable wrote');
    }
    const listed = await assertSucceeds(
      getDocs(collection(firestore, `transferNoticeReads/${ownerUid}/branches/${branchSouth}/transfers`)),
    );
    if (listed.size !== 1 || listed.docs[0].id !== transferId) {
      throw new Error('the owner leaf listing must retain the marker');
    }
  });

  test('denies another seller reading markers inside the owner subtree', async () => {
    await assertFails(getDoc(doc(otherSeller(), ownerMarkerPath)));
    await assertFails(
      getDocs(collection(otherSeller(), `transferNoticeReads/${ownerUid}/branches/${branchSouth}/transfers`)),
    );
  });

  test('denies the owner reading markers under another branch path', async () => {
    await assertFails(getDoc(doc(ownerSeller(), otherBranchMarkerPath)));
    await assertFails(
      getDocs(collection(ownerSeller(), `transferNoticeReads/${ownerUid}/branches/${branchNorth}/transfers`)),
    );
  });

  test('denies administrators and anonymous readers', async () => {
    await assertFails(getDoc(doc(administrator(), ownerMarkerPath)));
    await assertFails(
      getDocs(collection(administrator(), `transferNoticeReads/${ownerUid}/branches/${branchSouth}/transfers`)),
    );
    await assertFails(getDoc(doc(anonymous(), ownerMarkerPath)));
  });
});

describe('marker writes', () => {
  test('are denied for the owner, other sellers, administrators and anonymous clients', async () => {
    for (const firestore of [ownerSeller(), otherSeller(), administrator(), anonymous()]) {
      await assertFails(
        setDoc(doc(firestore, ownerMarkerPath), { ...markerData, readAt: new Date() }),
      );
      await assertFails(
        setDoc(doc(firestore, `transferNoticeReads/${ownerUid}/branches/${branchSouth}/transfers/tr-new`), {
          userId: ownerUid,
          branchId: branchSouth,
          transferId: 'tr-new',
          readAt: new Date(),
        }),
      );
      await assertFails(updateDoc(doc(firestore, ownerMarkerPath), { readAt: new Date() }));
      await assertFails(deleteDoc(doc(firestore, ownerMarkerPath)));
    }
  });
});

describe('private transfer audit boundary', () => {
  test('stays invisible to sellers and administrators', async () => {
    for (const firestore of [ownerSeller(), administrator()]) {
      await assertFails(getDoc(doc(firestore, `transfers/${transferId}`)));
      await assertFails(getDocs(collection(firestore, 'transfers')));
    }
  });

  test('is unreachable through a transfers collection-group query', async () => {
    // A collection-group query on 'transfers' would span the private audit and
    // the marker leaves; no client may prove both ownership constraints.
    for (const firestore of [ownerSeller(), administrator()]) {
      await assertFails(getDocs(collectionGroup(firestore, 'transfers')));
    }
  });
});

describe('unrelated paths', () => {
  test('remain closed by the catch-all rule', async () => {
    await assertFails(getDoc(doc(administrator(), 'unmodeledRecords', 'private-record')));
    await assertFails(
      setDoc(doc(administrator(), 'transferNoticeReads', ownerUid), { forged: true }),
    );
  });
});
