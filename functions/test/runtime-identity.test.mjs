import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { getApps } from 'firebase-admin/app';
import * as callables from '../src/index.js';

const PROJECT = 'lda-inventory-dev-mx';
const GROUPS = {
  reader: ['quoteSale', 'findCorrectableSale', 'listRecentCorrectableSales',
    'previewSaleReturn', 'previewSaleExchange'],
  writer: ['createProduct', 'setProductPrice', 'stockIntake', 'transferInventory',
    'submitSale', 'submitSaleReturn', 'submitSaleReplacement', 'submitSaleExchange',
    'markTransferNoticeRead'],
  profiles: ['setSellerProfile'],
};
const GUARD_MESSAGES = {
  createProduct: 'product creation is restricted to the local demo emulator',
  setProductPrice: 'product pricing is restricted to the local demo emulator',
  stockIntake: 'stock intake is restricted to the local demo emulator',
  transferInventory: 'transfers are restricted to the local demo emulator',
  markTransferNoticeRead: 'transfer notices are restricted to the local demo emulator',
  submitSale: 'sales are restricted to the local demo emulator',
  quoteSale: 'sales are restricted to the local demo emulator',
  setSellerProfile: 'seller profiles are restricted to the local demo emulator',
};
const json = (relative) => JSON.parse(readFileSync(new URL(relative, import.meta.url), 'utf8'));
const exportedNames = () => Object.keys(callables).filter((name) => callables[name]?.__endpoint).sort();

for (const [group, names] of Object.entries(GROUPS)) {
  for (const name of names) {
    test(`${name} declares its ${group} identity and retains its Gen2 region`, () => {
      const endpoint = callables[name].__endpoint;
      assert.equal(endpoint.serviceAccountEmail,
        `lda-functions-${group}@${PROJECT}.iam.gserviceaccount.com`);
      assert.equal(endpoint.platform, 'gcfv2');
      assert.deepEqual(endpoint.region, ['us-south1']);
      assert.deepEqual(endpoint.callableTrigger, {});
    });

    test(`${name} still rejects an untrusted project before Admin initialization`, async () => {
      const previous = process.env.GCLOUD_PROJECT;
      const appsBefore = getApps().map((app) => app.name);
      process.env.GCLOUD_PROJECT = 'untrusted-runtime-identity-test';
      try {
        await assert.rejects(callables[name].run({ data: {}, auth: null }), {
          code: 'failed-precondition',
          message: GUARD_MESSAGES[name] ?? 'sale corrections are restricted to the local demo emulator',
        });
        assert.deepEqual(getApps().map((app) => app.name), appsBefore);
      } finally {
        if (previous === undefined) delete process.env.GCLOUD_PROJECT;
        else process.env.GCLOUD_PROJECT = previous;
      }
    });
  }
}

test('all fifteen callable exports are assigned exactly once', () => {
  const names = Object.values(GROUPS).flat();
  assert.equal(names.length, 15);
  assert.equal(new Set(names).size, 15);
  assert.deepEqual(exportedNames(), names.sort());
});

test('identity options preserve the existing CORS rules and refuse unknown names', async () => {
  const { callableRuntimeOptions } = await import('../src/runtime-identity.js');
  for (const [group, names] of Object.entries(GROUPS)) {
    for (const name of names) {
      assert.deepEqual(callableRuntimeOptions(name, callables.LOCAL_WEB_ORIGINS), {
        region: 'us-south1',
        cors: callables.LOCAL_WEB_ORIGINS,
        serviceAccount: `lda-functions-${group}@${PROJECT}.iam.gserviceaccount.com`,
      });
    }
  }
  for (const name of ['unknown', '__proto__', 'toString', undefined]) {
    assert.throws(() => callableRuntimeOptions(name, []), {
      name: 'TypeError', message: 'unknown callable runtime identity',
    });
  }
  for (const origin of ['http://localhost:7358', 'https://localhost', 'http://127.0.0.1:7358']) {
    assert.equal(callables.LOCAL_WEB_ORIGINS.some((pattern) => pattern.test(origin)), true);
  }
  for (const origin of ['https://example.com', 'https://localhost.example.com', 'file://localhost']) {
    assert.equal(callables.LOCAL_WEB_ORIGINS.some((pattern) => pattern.test(origin)), false);
  }
});

const PERMISSIONS = {
  'firestore-reader': ['datastore.databases.get', 'datastore.entities.get', 'datastore.entities.list'],
  'firestore-writer': ['datastore.databases.get', 'datastore.entities.get',
    'datastore.entities.create', 'datastore.entities.update'],
  'auth-lookup': ['firebaseauth.users.get'],
};
for (const [role, permissions] of Object.entries(PERMISSIONS)) {
  test(`${role} candidate role contains exactly the justified permissions`, () => {
    const definition = json(`../iam/${role}.json`);
    assert.equal(typeof definition.title, 'string');
    assert.equal(typeof definition.description, 'string');
    assert.equal(definition.stage, 'GA');
    assert.deepEqual([...definition.includedPermissions].sort(), [...permissions].sort());
    assert.equal(new Set(definition.includedPermissions).size, permissions.length);
  });
}

test('the dedicated npm test lane remains local and explicit', () => {
  assert.equal(json('../package.json').scripts['test:runtime-identity'],
    'node --test test/runtime-identity.test.mjs test/runtime-project.test.mjs');
});
