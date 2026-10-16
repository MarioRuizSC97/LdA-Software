import assert from 'node:assert/strict';
import test from 'node:test';

import { assertLocalCatalogEmulator } from '../src/catalog.js';
import { assertLocalInventoryEmulator } from '../src/inventory.js';
import { assertLocalPricingEmulator } from '../src/pricing.js';
import { DEPLOYED_PROJECT_ID, isDeployedProjectRuntime } from '../src/runtime-project.js';
import { assertLocalSalesEmulator } from '../src/sales.js';
import { assertLocalSellerProfilesEmulator } from '../src/sellerProfiles.js';

const DEPLOYED = Object.freeze({
  GCLOUD_PROJECT: 'lda-inventory-dev-mx',
  GOOGLE_CLOUD_PROJECT: 'lda-inventory-dev-mx',
  FIREBASE_CONFIG: JSON.stringify({ projectId: 'lda-inventory-dev-mx' }),
});

const GUARDS = Object.freeze({
  catalog: assertLocalCatalogEmulator,
  inventory: assertLocalInventoryEmulator,
  pricing: assertLocalPricingEmulator,
  sales: assertLocalSalesEmulator,
  sellerProfiles: assertLocalSellerProfilesEmulator,
});

const UNTRUSTED = Object.freeze({
  'another project': { ...DEPLOYED, GCLOUD_PROJECT: 'someone-else', GOOGLE_CLOUD_PROJECT: 'someone-else' },
  'no project': {},
  'emulator flag on the deployed project': { ...DEPLOYED, FUNCTIONS_EMULATOR: 'true' },
  'Firestore emulator host on the deployed project': { ...DEPLOYED, FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' },
  'Auth emulator host on the deployed project': { ...DEPLOYED, FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099' },
  'Storage emulator host on the deployed project': { ...DEPLOYED, FIREBASE_STORAGE_EMULATOR_HOST: '127.0.0.1:9199' },
  'disagreeing GOOGLE_CLOUD_PROJECT': { ...DEPLOYED, GOOGLE_CLOUD_PROJECT: 'someone-else' },
  'disagreeing FIREBASE_CONFIG': { ...DEPLOYED, FIREBASE_CONFIG: JSON.stringify({ projectId: 'someone-else' }) },
  'FIREBASE_CONFIG as a file path': { ...DEPLOYED, FIREBASE_CONFIG: '/tmp/firebase-config.json' },
  'FIREBASE_CONFIG that is not an object': { ...DEPLOYED, FIREBASE_CONFIG: '["lda-inventory-dev-mx"]' },
});

test('the deployed project is lda-inventory-dev-mx', () => {
  assert.equal(DEPLOYED_PROJECT_ID, 'lda-inventory-dev-mx');
});

test('the deployed runtime is recognized only with agreeing, emulator-free markers', () => {
  assert.equal(isDeployedProjectRuntime(DEPLOYED), true);
  assert.equal(isDeployedProjectRuntime({ GCLOUD_PROJECT: 'lda-inventory-dev-mx' }), true);
  for (const [name, environment] of Object.entries(UNTRUSTED)) {
    assert.equal(isDeployedProjectRuntime(environment), false, name);
  }
});

for (const [area, guard] of Object.entries(GUARDS)) {
  test(`${area} guard accepts the deployed project`, () => {
    assert.doesNotThrow(() => guard(DEPLOYED));
  });

  test(`${area} guard still refuses every untrusted runtime`, () => {
    for (const [name, environment] of Object.entries(UNTRUSTED)) {
      assert.throws(() => guard(environment), undefined, name);
    }
  });
}
