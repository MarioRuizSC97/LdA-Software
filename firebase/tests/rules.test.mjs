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
  Timestamp,
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
const productId = 'DEMO-COFFEE';
const zeroStockProductId = 'DEMO-RIBBON';
const unheldProductId = 'DEMO-UNHELD';
const southOnlyProductId = 'DEMO-SOUTH-ONLY';
const sensitiveProductIds = {
  createdBy: 'product-created-by',
  pricingUpdatedBy: 'product-pricing-updated-by',
  unitCost: 'product-unit-cost',
  embeddedCost: 'product-embedded-cost',
  nestedSecret: 'product-nested-secret',
};
const malformedPublicProductIds = {
  nestedUnitActor: 'MALFORMED-UNIT-ACTOR',
  nestedPricingActor: 'MALFORMED-PRICING-ACTOR',
  invalidNameType: 'MALFORMED-NAME-TYPE',
  invalidCreatedAt: 'MALFORMED-CREATED-AT',
  invalidPricingBounds: 'MALFORMED-PRICING-BOUNDS',
};

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
      internalCode: productId,
      name: 'Coffee',
      quantitySpec: { unit: 'piece', precision: 0 },
      createdAt: Timestamp.fromMillis(1_700_000_000_000),
      pricing: {
        listedPriceCentavos: 99950,
        currency: 'MXN',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRateBasisPoints: 1600,
      },
      pricingUpdatedAt: Timestamp.fromMillis(1_700_000_100_000),
      lastPricingAuditId: 'price-coffee-001',
    });
    await setDoc(doc(firestore, 'products', zeroStockProductId), {
      internalCode: zeroStockProductId,
      name: 'Ribbon',
      quantitySpec: { unit: 'piece', precision: 0 },
      createdAt: null,
      pricingUpdatedAt: null,
      lastPricingAuditId: null,
    });
    await setDoc(doc(firestore, 'products', unheldProductId), {
      internalCode: unheldProductId,
      name: 'Unheld product',
      quantitySpec: { unit: 'piece', precision: 0 },
    });
    await setDoc(doc(firestore, 'products', southOnlyProductId), {
      internalCode: southOnlyProductId,
      name: 'South-only product',
      quantitySpec: { unit: 'piece', precision: 0 },
    });
    const baseSensitiveProduct = {
      name: 'Sensitive legacy product',
      quantitySpec: { unit: 'piece', precision: 0 },
    };
    await setDoc(doc(firestore, 'products', sensitiveProductIds.createdBy), {
      ...baseSensitiveProduct,
      internalCode: sensitiveProductIds.createdBy,
      createdBy: 'legacy-admin-uid',
    });
    await setDoc(doc(firestore, 'products', sensitiveProductIds.pricingUpdatedBy), {
      ...baseSensitiveProduct,
      internalCode: sensitiveProductIds.pricingUpdatedBy,
      pricingUpdatedBy: 'legacy-admin-uid',
    });
    await setDoc(doc(firestore, 'products', sensitiveProductIds.unitCost), {
      ...baseSensitiveProduct,
      internalCode: sensitiveProductIds.unitCost,
      unitCostCentavos: 7100,
    });
    await setDoc(doc(firestore, 'products', sensitiveProductIds.embeddedCost), {
      ...baseSensitiveProduct,
      internalCode: sensitiveProductIds.embeddedCost,
      acquisition: { unitCostCentavos: 7100 },
    });
    await setDoc(doc(firestore, 'products', sensitiveProductIds.nestedSecret), {
      ...baseSensitiveProduct,
      internalCode: sensitiveProductIds.nestedSecret,
      quantitySpec: { unit: 'piece', precision: 0, secret: 'private' },
    });
    await setDoc(doc(firestore, 'products', malformedPublicProductIds.nestedUnitActor), {
      internalCode: malformedPublicProductIds.nestedUnitActor,
      name: 'Nested unit actor',
      quantitySpec: {
        unit: { value: 'piece', actorUid: 'administrator-secret-uid' },
        precision: 0,
      },
    });
    await setDoc(doc(firestore, 'products', malformedPublicProductIds.nestedPricingActor), {
      internalCode: malformedPublicProductIds.nestedPricingActor,
      name: 'Nested pricing actor',
      quantitySpec: { unit: 'piece', precision: 0 },
      pricing: {
        listedPriceCentavos: 100,
        currency: 'MXN',
        priceMode: 'iva-included',
        ivaTreatment: { value: 'taxable', actorUid: 'administrator-secret-uid' },
        ivaRateBasisPoints: 1600,
      },
    });
    await setDoc(doc(firestore, 'products', malformedPublicProductIds.invalidNameType), {
      internalCode: malformedPublicProductIds.invalidNameType,
      name: { value: 'Nested name', actorUid: 'administrator-secret-uid' },
      quantitySpec: { unit: 'piece', precision: 0 },
    });
    await setDoc(doc(firestore, 'products', malformedPublicProductIds.invalidCreatedAt), {
      internalCode: malformedPublicProductIds.invalidCreatedAt,
      name: 'Invalid timestamp',
      quantitySpec: { unit: 'piece', precision: 0 },
      createdAt: { actorUid: 'administrator-secret-uid' },
    });
    await setDoc(doc(firestore, 'products', malformedPublicProductIds.invalidPricingBounds), {
      internalCode: malformedPublicProductIds.invalidPricingBounds,
      name: 'Invalid pricing bounds',
      quantitySpec: { unit: 'piece', precision: 0 },
      pricing: {
        listedPriceCentavos: 9007199254740992,
        currency: 'MXN',
        priceMode: 'iva-additional-on-invoice',
        ivaTreatment: 'taxable',
        ivaRateBasisPoints: 10001,
      },
    });
    await setDoc(doc(firestore, 'branches', branchNorth), {
      name: 'North branch',
    });
    await setDoc(doc(firestore, 'branches', branchSouth), {
      name: 'South branch',
    });
    await setDoc(
      doc(firestore, 'branches', branchNorth, 'stock', productId),
      { available: 8 },
    );
    await setDoc(
      doc(firestore, 'branches', branchSouth, 'stock', productId),
      { available: 3 },
    );
    await setDoc(
      doc(firestore, 'branches', branchNorth, 'stock', zeroStockProductId),
      { available: 0 },
    );
    await setDoc(
      doc(firestore, 'branches', branchSouth, 'stock', southOnlyProductId),
      { available: 5 },
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
    await setDoc(doc(firestore, 'productCreationReceipts', 'create-coffee'), {
      fingerprint: 'catalog-request',
      result: { productId },
    });
    await setDoc(doc(firestore, 'productPriceAudits', 'price-coffee'), {
      productId,
      previousAuditId: null,
      oldPricing: null,
      newPricing: { listedPriceCentavos: 99950, currency: 'MXN' },
      actorId: 'admin',
    });
    await setDoc(doc(firestore, 'productPriceUpdateReceipts', 'price-coffee'), {
      fingerprint: 'pricing-request',
      result: { productId, auditId: 'price-coffee' },
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
      getDoc(doc(anonymousFirestore, 'branches', branchNorth)),
    );
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

    const product = await assertSucceeds(
      getDoc(doc(firestore, 'products', productId)),
    );
    if (product.data().pricing.listedPriceCentavos !== 99950) {
      throw new Error('seller-readable product must expose the shared listed price');
    }
    if ('pricingUpdatedBy' in product.data()) {
      throw new Error('seller-readable product must not expose pricing actor identity');
    }
    if ('unitCostCentavos' in product.data() || 'latestUnitCostCentavos' in product.data()) {
      throw new Error('seller-readable product must not expose acquisition cost');
    }
    for (const sensitiveProductId of [
      ...Object.values(sensitiveProductIds),
      ...Object.values(malformedPublicProductIds),
    ]) {
      await assertFails(
        getDoc(doc(firestore, 'products', sensitiveProductId)),
      );
    }
    await assertFails(getDoc(doc(firestore, 'costs', productId)));
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
      await assertFails(getDoc(doc(firestore, 'products', productId)));
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

  test('an arbitrary role cannot get a seller-safe product', async () => {
    const firestore = firestoreFor('unknown-role', {
      role: 'auditor',
      branchId: branchNorth,
    });

    await assertFails(getDoc(doc(firestore, 'products', productId)));
  });
});

describe('administrator reads', () => {
  test('lists and gets branch metadata and reads stock across branches', async () => {
    const firestore = firestoreFor('admin', { role: 'administrator' });

    await assertSucceeds(getDoc(doc(firestore, 'branches', branchNorth)));
    await assertSucceeds(getDocs(collection(firestore, 'branches')));
    const stock = await assertSucceeds(
      getDocs(collectionGroup(firestore, 'stock')),
    );
    if (stock.size !== 4) {
      throw new Error('administrator stock query must include every branch');
    }
  });

  test('reads every modeled branch and its product files', async () => {
    const claims = { role: 'administrator' };
    const firestore = firestoreFor('admin', claims);
    const storage = storageFor('admin', claims);

    for (const sensitiveProductId of [
      ...Object.values(sensitiveProductIds),
      ...Object.values(malformedPublicProductIds),
    ]) {
      await assertSucceeds(
        getDoc(doc(firestore, 'products', sensitiveProductId)),
      );
    }
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
  test('denies seller catalog lists for mixed and all-public collections', async () => {
    const seller = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });
    const administrator = firestoreFor('admin', { role: 'administrator' });

    await assertFails(getDocs(collection(seller, 'products')));
    await assertSucceeds(getDocs(collection(administrator, 'products')));

    await testEnvironment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      for (const sensitiveProductId of [
        ...Object.values(sensitiveProductIds),
        ...Object.values(malformedPublicProductIds),
      ]) {
        await deleteDoc(doc(firestore, 'products', sensitiveProductId));
      }
    });

    await assertFails(getDocs(collection(seller, 'products')));
    await assertSucceeds(getDocs(collection(administrator, 'products')));
  });

  test('allows only the seller assigned-stock query and product get', async () => {
    const firestore = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });

    await assertSucceeds(getDoc(doc(firestore, 'products', productId)));
    await assertSucceeds(getDoc(doc(firestore, 'products', zeroStockProductId)));
    await assertFails(getDoc(doc(firestore, 'products', unheldProductId)));
    await assertFails(getDoc(doc(firestore, 'products', southOnlyProductId)));
    const assignedStock = await assertSucceeds(
      getDocs(collection(firestore, 'branches', branchNorth, 'stock')),
    );
    if (assignedStock.docs.find((stock) => stock.id === zeroStockProductId)?.data().available !== 0) {
      throw new Error('seller assigned-stock query must retain zero quantity');
    }
    await assertFails(
      getDocs(collection(firestore, 'branches', branchSouth, 'stock')),
    );
    await assertFails(getDocs(collectionGroup(firestore, 'stock')));
  });

  test('retains administrator product reads regardless of branch holdings', async () => {
    const firestore = firestoreFor('admin', { role: 'administrator' });

    await assertSucceeds(getDoc(doc(firestore, 'products', unheldProductId)));
    await assertSucceeds(getDoc(doc(firestore, 'products', southOnlyProductId)));
    await assertSucceeds(getDoc(doc(firestore, 'products', zeroStockProductId)));
  });

  test('denies seller branch metadata gets and lists', async () => {
    const firestore = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });

    await assertFails(getDoc(doc(firestore, 'branches', branchNorth)));
    await assertFails(getDocs(collection(firestore, 'branches')));
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

describe('protected server record boundary', () => {
  test('allows administrators and denies sellers for protected server records', async () => {
    const administrator = firestoreFor('admin', { role: 'administrator' });
    const seller = firestoreFor('seller-north', {
      role: 'seller',
      branchId: branchNorth,
    });
    const protectedPaths = [
      ['costs', productId],
      ['stockIntakeEntries', 'intake-north'],
      ['stockIntakeReceipts', 'intake-north'],
      ['productCreationReceipts', 'create-coffee'],
      ['productPriceAudits', 'price-coffee'],
      ['productPriceUpdateReceipts', 'price-coffee'],
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
      setDoc(doc(administrator, 'branches', 'branch-client'), {
        name: 'Client-created branch',
      }),
    );
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
    await assertFails(
      setDoc(doc(administrator, 'productCreationReceipts', 'client-receipt'), {
        fingerprint: 'forged-catalog-request',
      }),
    );
    await assertFails(
      updateDoc(doc(administrator, 'products', productId), {
        'pricing.listedPriceCentavos': 1,
      }),
    );
    await assertFails(
      setDoc(doc(administrator, 'productPriceAudits', 'client-audit'), {
        productId,
        actorId: 'admin',
      }),
    );
    await assertFails(
      updateDoc(doc(administrator, 'productPriceAudits', 'price-coffee'), {
        actorId: 'rewritten-admin',
      }),
    );
    await assertFails(
      deleteDoc(doc(administrator, 'productPriceAudits', 'price-coffee')),
    );
    await assertFails(
      setDoc(doc(administrator, 'productPriceUpdateReceipts', 'client-receipt'), {
        fingerprint: 'forged-pricing-request',
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
