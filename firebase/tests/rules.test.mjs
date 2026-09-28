import { after, before, beforeEach, describe, test } from 'node:test';
import { readFile } from 'node:fs/promises';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
} from 'firebase/firestore';
import {
  deleteObject,
  getBytes,
  ref,
  uploadBytes,
} from 'firebase/storage';

const projectId = 'demo-lda-inventory';
const branchNorth = 'branch-north';
const branchSouth = 'branch-south';
const productId = 'product-coffee';

let testEnvironment;

function firestoreFor(userId, claims = {}) {
  return testEnvironment.authenticatedContext(userId, claims).firestore();
}

function storageFor(userId, claims = {}) {
  return testEnvironment.authenticatedContext(userId, claims).storage();
}

async function seedFirestore() {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();

    await setDoc(doc(firestore, 'products', productId), {
      name: 'Coffee',
      salePrice: 125,
    });
    await setDoc(
      doc(firestore, 'branches', branchNorth, 'stock', productId),
      { available: 8 },
    );
    await setDoc(
      doc(firestore, 'branches', branchSouth, 'stock', productId),
      { available: 3 },
    );
    await setDoc(doc(firestore, 'costs', productId), {
      latestUnitCostCentavos: 7100,
      currency: 'MXN',
    });
    await setDoc(doc(firestore, 'stockIntakeEntries', 'intake-north'), {
      branchId: branchNorth,
      productId,
      unitCostCentavos: 7100,
      lineTotalCentavos: 56800,
    });
    await setDoc(doc(firestore, 'stockIntakeReceipts', 'intake-north'), {
      fingerprint: 'cost-bearing-request',
    });
    await setDoc(doc(firestore, 'inventoryMovements', 'movement-north'), {
      branchId: branchNorth,
      productId,
      delta: 8,
    });
    await setDoc(doc(firestore, 'inventoryMovements', 'movement-south'), {
      branchId: branchSouth,
      productId,
      delta: 3,
    });
    await setDoc(doc(firestore, 'unmodeledRecords', 'private-record'), {
      secret: true,
    });
  });
}

async function seedStorage() {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const storage = context.storage();

    await uploadBytes(
      ref(storage, `branches/${branchNorth}/products/${productId}/photo.jpg`),
      new Uint8Array([1, 2, 3]),
    );
    await uploadBytes(
      ref(storage, `branches/${branchSouth}/products/${productId}/photo.jpg`),
      new Uint8Array([4, 5, 6]),
    );
    await uploadBytes(
      ref(storage, 'unmodeled/private-file.txt'),
      new Uint8Array([7, 8, 9]),
    );
  });
}

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: await readFile(new URL('../../firestore.rules', import.meta.url), 'utf8'),
    },
    storage: {
      rules: await readFile(new URL('../../storage.rules', import.meta.url), 'utf8'),
    },
  });
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();
  await testEnvironment.clearStorage();
  await seedFirestore();
  await seedStorage();
});

after(async () => {
  await testEnvironment?.cleanup();
});

describe('unauthenticated access', () => {
  test('cannot read catalog or branch files', async () => {
    const anonymousFirestore = testEnvironment.unauthenticatedContext().firestore();
    const anonymousStorage = testEnvironment.unauthenticatedContext().storage();

    await assertFails(getDoc(doc(anonymousFirestore, 'products', productId)));
    await assertFails(
      getBytes(
        ref(
          anonymousStorage,
          `branches/${branchNorth}/products/${productId}/photo.jpg`,
        ),
      ),
    );
  });
});

describe('seller branch boundary', () => {
  test('reads stock and files only for the assigned branch', async () => {
    const claims = { role: 'seller', branchId: branchNorth };
    const firestore = firestoreFor('seller-north', claims);
    const storage = storageFor('seller-north', claims);

    await assertSucceeds(getDoc(doc(firestore, 'products', productId)));
    await assertSucceeds(
      getDoc(doc(firestore, 'branches', branchNorth, 'stock', productId)),
    );
    await assertFails(
      getDoc(doc(firestore, 'branches', branchSouth, 'stock', productId)),
    );
    await assertSucceeds(
      getDoc(doc(firestore, 'inventoryMovements', 'movement-north')),
    );
    await assertFails(
      getDoc(doc(firestore, 'inventoryMovements', 'movement-south')),
    );
    await assertSucceeds(
      getBytes(
        ref(
          storage,
          `branches/${branchNorth}/products/${productId}/photo.jpg`,
        ),
      ),
    );
    await assertFails(
      getBytes(
        ref(
          storage,
          `branches/${branchSouth}/products/${productId}/photo.jpg`,
        ),
      ),
    );
  });
});

describe('claim validation', () => {
  const invalidIdentities = [
    ['missing claims', {}],
    ['missing branch claim', { role: 'seller' }],
    ['malformed role claim', { role: 'Seller', branchId: branchNorth }],
    ['malformed branch claim', { role: 'seller', branchId: 42 }],
  ];

  for (const [name, claims] of invalidIdentities) {
    test(`${name} cannot access role-protected paths`, async () => {
      const firestore = firestoreFor(`invalid-${name}`, claims);
      const storage = storageFor(`invalid-${name}`, claims);

      await assertFails(
        getDoc(doc(firestore, 'branches', branchNorth, 'stock', productId)),
      );
      await assertFails(getDoc(doc(firestore, 'costs', productId)));
      await assertFails(
        getBytes(
          ref(
            storage,
            `branches/${branchNorth}/products/${productId}/photo.jpg`,
          ),
        ),
      );
    });
  }
});

describe('administrator reads', () => {
  test('reads every modeled branch and its product files', async () => {
    const claims = { role: 'administrator' };
    const firestore = firestoreFor('admin', claims);
    const storage = storageFor('admin', claims);

    await assertSucceeds(
      getDoc(doc(firestore, 'branches', branchNorth, 'stock', productId)),
    );
    await assertSucceeds(
      getDoc(doc(firestore, 'branches', branchSouth, 'stock', productId)),
    );
    await assertSucceeds(
      getDoc(doc(firestore, 'inventoryMovements', 'movement-north')),
    );
    await assertSucceeds(
      getBytes(
        ref(
          storage,
          `branches/${branchSouth}/products/${productId}/photo.jpg`,
        ),
      ),
    );
  });
});

describe('collection query boundaries', () => {
  test('rejects seller queries outside the assigned branch', async () => {
    const firestore = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });

    await assertSucceeds(
      getDocs(collection(firestore, 'branches', branchNorth, 'stock')),
    );
    await assertFails(
      getDocs(collection(firestore, 'branches', branchSouth, 'stock')),
    );
    await assertFails(getDocs(collectionGroup(firestore, 'stock')));
  });
});

describe('unknown paths', () => {
  test('remain unreadable even to administrators', async () => {
    const claims = { role: 'administrator' };
    const firestore = firestoreFor('admin', claims);
    const storage = storageFor('admin', claims);

    await assertFails(
      getDoc(doc(firestore, 'unmodeledRecords', 'private-record')),
    );
    await assertFails(
      getBytes(ref(storage, 'unmodeled/private-file.txt')),
    );
  });
});

describe('acquisition cost boundary', () => {
  test('allows administrators and denies sellers for every cost-bearing record', async () => {
    const administrator = firestoreFor('admin', { role: 'administrator' });
    const seller = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });
    const protectedPaths = [
      ['costs', productId],
      ['stockIntakeEntries', 'intake-north'],
      ['stockIntakeReceipts', 'intake-north'],
    ];

    for (const path of protectedPaths) {
      await assertSucceeds(getDoc(doc(administrator, ...path)));
      await assertFails(getDoc(doc(seller, ...path)));
    }
  });
});

describe('server-owned inventory mutations', () => {
  test('denies representative Firestore mutations from every client role', async () => {
    const administrator = firestoreFor('admin', { role: 'administrator' });
    const seller = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });

    await assertFails(
      setDoc(
        doc(administrator, 'branches', branchNorth, 'stock', 'new-product'),
        { available: 1 },
      ),
    );
    await assertFails(
      updateDoc(doc(administrator, 'costs', productId), {
        latestEntryCost: 70,
      }),
    );
    await assertFails(
      setDoc(doc(seller, 'inventoryMovements', 'client-movement'), {
        branchId: branchNorth,
        productId,
        delta: -1,
      }),
    );
    await assertFails(
      setDoc(doc(administrator, 'stockIntakeEntries', 'client-intake'), {
        unitCostCentavos: 1,
      }),
    );
    await assertFails(
      setDoc(doc(administrator, 'stockIntakeReceipts', 'client-receipt'), {
        fingerprint: 'forged',
      }),
    );
    await assertFails(deleteDoc(doc(seller, 'products', productId)));
    await assertFails(
      setDoc(doc(administrator, 'unexpectedInventoryData', 'record'), {
        value: true,
      }),
    );
  });

  test('denies direct Storage uploads and deletes', async () => {
    const administrator = storageFor('admin', { role: 'administrator' });
    const seller = storageFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });

    await assertFails(
      uploadBytes(
        ref(
          administrator,
          `branches/${branchNorth}/products/${productId}/replacement.jpg`,
        ),
        new Uint8Array([7, 8, 9]),
      ),
    );
    await assertFails(
      deleteObject(
        ref(
          seller,
          `branches/${branchNorth}/products/${productId}/photo.jpg`,
        ),
      ),
    );
  });
});
