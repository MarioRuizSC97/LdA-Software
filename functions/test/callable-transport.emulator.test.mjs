import assert from 'node:assert/strict';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { test } from 'node:test';

const PROJECT_ID = 'demo-lda-inventory';
const AUTH_HOST = '127.0.0.1:9099';
const FIRESTORE_HOST = '127.0.0.1:8080';
const FUNCTIONS_BASE =
  'http://127.0.0.1:5001/demo-lda-inventory/us-south1';
const FUNCTION_NAMES = new Set(['createProduct', 'setProductPrice', 'stockIntake']);
const REQUEST_TIMEOUT_MS = 10_000;

const DEMO_IDENTITIES = Object.freeze({
  administrator: Object.freeze({
    email: 'administrator@demo-lda-inventory.invalid',
    password: 'Demo-Only-Administrator-2026!',
  }),
  seller: Object.freeze({
    email: 'seller.north@demo-lda-inventory.invalid',
    password: 'Demo-Only-Seller-2026!',
  }),
});

function assertIsolatedRuntime(env = process.env, version = process.version) {
  const major = Number(version.match(/^v(\d+)\./)?.[1]);
  assert.equal(major, 24, `callable transport tests require Node 24, received ${version}`);
  assert.equal(env.GCLOUD_PROJECT, PROJECT_ID);
  assert.equal(env.FIREBASE_AUTH_EMULATOR_HOST, AUTH_HOST);
  assert.equal(env.FIRESTORE_EMULATOR_HOST, FIRESTORE_HOST);
}

const emulatorEnvironmentKeys = [
  'GCLOUD_PROJECT',
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIRESTORE_EMULATOR_HOST',
];
const hasEmulatorConfiguration = emulatorEnvironmentKeys.some(
  (key) => process.env[key] !== undefined,
);

// A normal broad unit run has no live-emulator environment and skips safely.
// Any partial or incorrect live configuration still fails before Firebase import
// or network access instead of silently bypassing integration assertions.
if (hasEmulatorConfiguration) {
  assertIsolatedRuntime();
  console.log(
    `callable transport runtime: ${process.version}; project=${process.env.GCLOUD_PROJECT}; auth=${process.env.FIREBASE_AUTH_EMULATOR_HOST}; firestore=${process.env.FIRESTORE_EMULATOR_HOST}; functions=${FUNCTIONS_BASE}`,
  );
}

function callableUrl(name) {
  assert.ok(FUNCTION_NAMES.has(name), `unknown callable name: ${name}`);
  return `${FUNCTIONS_BASE}/${name}`;
}

async function boundedFetch(url, options = {}) {
  assertIsolatedRuntime();
  return fetch(url, {
    ...options,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
}

async function readJson(response) {
  const text = await response.text();
  assert.notEqual(text, '', `expected JSON response from ${response.url}`);
  return JSON.parse(text);
}

async function signIn(identity) {
  const response = await boundedFetch(
    `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-only`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        email: identity.email,
        password: identity.password,
        returnSecureToken: true,
      }),
    },
  );
  const body = await readJson(response);
  assert.equal(response.status, 200, `Auth emulator sign-in failed: ${body.error?.message}`);
  assert.equal(typeof body.idToken, 'string');
  assert.ok(body.idToken.length > 20);
  return body.idToken;
}

async function callFunction(name, data, token, extra = {}) {
  const headers = {
    'content-type': 'application/json',
    origin: 'http://127.0.0.1:7357',
    ...extra.headers,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const response = await boundedFetch(callableUrl(name), {
    method: 'POST',
    ...extra,
    headers,
    body: JSON.stringify({ data }),
  });
  const body = await readJson(response);
  return { response, body };
}

function assertCallableResult(outcome) {
  assert.equal(outcome.response.status, 200);
  assert.deepEqual(Object.keys(outcome.body), ['result']);
  return outcome.body.result;
}

function assertCallableError(outcome, expectedStatus) {
  assert.notEqual(outcome.response.status, 200);
  assert.deepEqual(Object.keys(outcome.body), ['error']);
  assert.equal(outcome.body.error.status, expectedStatus);
  assert.equal(typeof outcome.body.error.message, 'string');
  assert.equal('result' in outcome.body, false);
}

function firestoreDocumentUrl(path) {
  const encoded = path.split('/').map(encodeURIComponent).join('/');
  return `http://${FIRESTORE_HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents/${encoded}`;
}

async function firestoreGet(path, token) {
  const response = await boundedFetch(firestoreDocumentUrl(path), {
    headers: { authorization: `Bearer ${token}` },
  });
  const body = await readJson(response);
  return { response, body };
}

function decodeValue(value) {
  if ('nullValue' in value) return null;
  if ('booleanValue' in value) return value.booleanValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('stringValue' in value) return value.stringValue;
  if ('mapValue' in value) return decodeFields(value.mapValue.fields ?? {});
  if ('arrayValue' in value) return (value.arrayValue.values ?? []).map(decodeValue);
  throw new Error(`unsupported Firestore REST value: ${Object.keys(value).join(',')}`);
}

function decodeFields(fields) {
  return Object.fromEntries(
    Object.entries(fields).map(([key, value]) => [key, decodeValue(value)]),
  );
}

async function expectAllowedRead(path, token) {
  const outcome = await firestoreGet(path, token);
  assert.equal(outcome.response.status, 200, `${path} should be readable`);
  return decodeFields(outcome.body.fields ?? {});
}

async function expectDeniedRead(path, token) {
  const outcome = await firestoreGet(path, token);
  assert.equal(outcome.response.status, 403, `${path} should be denied`);
  assert.equal(outcome.body.error?.status, 'PERMISSION_DENIED');
}

async function initializeAdmin() {
  assertIsolatedRuntime();
  const [appModule, firestoreModule] = await Promise.all([
    import('firebase-admin/app'),
    import('firebase-admin/firestore'),
  ]);
  assertIsolatedRuntime();

  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
  const credential = appModule.cert({
    projectId: PROJECT_ID,
    clientEmail: 'callable-transport@demo-lda-inventory.invalid',
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  });
  assertIsolatedRuntime();
  const app = appModule.initializeApp(
    { projectId: PROJECT_ID, credential },
    `callable-transport-${randomUUID()}`,
  );
  assertIsolatedRuntime();
  return {
    app,
    firestore: firestoreModule.getFirestore(app),
    deleteApp: appModule.deleteApp,
  };
}

async function cleanupOwnedRecords(firestore, ownership) {
  if (!ownership.productId) return;

  const productReference = firestore.doc(`products/${ownership.productId}`);
  const creationReceiptReference = firestore.doc(
    `productCreationReceipts/${ownership.createKey}`,
  );
  const [product, creationReceipt] = await Promise.all([
    productReference.get(),
    creationReceiptReference.get(),
  ]);
  const ownsProduct = product.exists
    && product.data().name === ownership.productName
    && creationReceipt.exists
    && creationReceipt.data().result?.productId === ownership.productId;
  assert.equal(ownsProduct, true, 'cleanup refused because product ownership is unverified');

  const paths = [
    `branches/branch-north/stock/${ownership.productId}`,
    `costs/${ownership.productId}`,
    `stockIntakeEntries/${ownership.intakeKey}`,
    `inventoryMovements/${ownership.intakeKey}`,
    `stockIntakeReceipts/${ownership.intakeKey}`,
    `productPriceAudits/${ownership.priceKey}`,
    `productPriceUpdateReceipts/${ownership.priceKey}`,
    `productCreationReceipts/${ownership.createKey}`,
    `products/${ownership.productId}`,
  ];
  for (let offset = 0; offset < paths.length; offset += 400) {
    const batch = firestore.batch();
    for (const path of paths.slice(offset, offset + 400)) {
      batch.delete(firestore.doc(path));
    }
    await batch.commit();
  }
}

async function countExactOwnedRecords(firestore, ownership) {
  const expected = {
    product: [`products/${ownership.productId}`],
    audit: [`productPriceAudits/${ownership.priceKey}`],
    entry: [`stockIntakeEntries/${ownership.intakeKey}`],
    movement: [`inventoryMovements/${ownership.intakeKey}`],
    receipt: [
      `productCreationReceipts/${ownership.createKey}`,
      `productPriceUpdateReceipts/${ownership.priceKey}`,
      `stockIntakeReceipts/${ownership.intakeKey}`,
    ],
    projection: [`branches/branch-north/stock/${ownership.productId}`],
  };
  const counts = {};
  for (const [kind, paths] of Object.entries(expected)) {
    const snapshots = await firestore.getAll(
      ...paths.map((path) => firestore.doc(path)),
    );
    counts[kind] = snapshots.filter(({ exists }) => exists).length;
  }
  assert.deepEqual(counts, {
    product: 1,
    audit: 1,
    entry: 1,
    movement: 1,
    receipt: 3,
    projection: 1,
  });
}

test(
  'Node 24 transports all inventory callables and enforces client boundaries',
  {
    skip: hasEmulatorConfiguration
      ? false
      : 'requires the exact isolated Node 24 Auth/Firestore/Functions emulator environment',
  },
  async (t) => {
  const runId = randomUUID();
  const ownership = {
    createKey: randomUUID(),
    priceKey: randomUUID(),
    intakeKey: randomUUID(),
    productName: `Callable transport ${runId}`,
    productId: null,
  };
  const sellerKeys = {
    create: randomUUID(),
    price: randomUUID(),
    intake: randomUUID(),
  };
  let admin;

  t.after(async () => {
    if (!admin) return;
    try {
      await cleanupOwnedRecords(admin.firestore, ownership);
    } finally {
      await admin.deleteApp(admin.app);
    }
  });

  await t.test('configured CORS policy is strict while emulator behavior is explicit', async () => {
    assertIsolatedRuntime();
    const { LOCAL_WEB_ORIGINS } = await import('../src/index.js');
    assert.deepEqual(
      LOCAL_WEB_ORIGINS.map(({ source }) => source),
      [
        '^https?:\\/\\/localhost(?::\\d{1,5})?$',
        '^https?:\\/\\/127\\.0\\.0\\.1(?::\\d{1,5})?$',
      ],
    );
    for (const origin of [
      'http://localhost',
      'https://localhost:7357',
      'http://127.0.0.1',
      'https://127.0.0.1:5001',
    ]) {
      assert.equal(
        LOCAL_WEB_ORIGINS.some((allowed) => allowed.test(origin)),
        true,
        `${origin} should match the configured local policy`,
      );
    }
    const foreignOrigin = 'https://inventory.example.invalid';
    assert.equal(
      LOCAL_WEB_ORIGINS.some((allowed) => allowed.test(foreignOrigin)),
      false,
      'the configured application policy must reject foreign origins',
    );

    const accepted = await boundedFetch(callableUrl('createProduct'), {
      method: 'OPTIONS',
      headers: {
        origin: 'http://localhost:7357',
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'authorization,content-type',
      },
    });
    assert.ok(accepted.status === 204 || accepted.status === 200);
    assert.equal(
      accepted.headers.get('access-control-allow-origin'),
      'http://localhost:7357',
    );

    const foreign = await boundedFetch(callableUrl('createProduct'), {
      method: 'OPTIONS',
      headers: {
        origin: foreignOrigin,
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'authorization,content-type',
      },
    });
    const emulatorAllowOrigin = foreign.headers.get('access-control-allow-origin');
    if (emulatorAllowOrigin === null) {
      console.log('Functions emulator enforced the stricter configured CORS policy.');
    } else {
      assert.equal(emulatorAllowOrigin, foreignOrigin);
      console.log(
        'Functions emulator reflected a foreign OPTIONS origin because its debug CORS mode does not enforce the exported application allowlist.',
      );
    }
  });

  const [administratorToken, sellerToken] = await Promise.all([
    signIn(DEMO_IDENTITIES.administrator),
    signIn(DEMO_IDENTITIES.seller),
  ]);

  await t.test('callable protocol rejects malformed envelopes and missing auth', async () => {
    const malformedResponse = await boundedFetch(callableUrl('createProduct'), {
      method: 'POST',
      headers: {
        authorization: `Bearer ${administratorToken}`,
        'content-type': 'application/json',
        origin: 'http://localhost:7357',
      },
      body: JSON.stringify({ payload: {} }),
    });
    const malformed = { response: malformedResponse, body: await readJson(malformedResponse) };
    assertCallableError(malformed, 'INVALID_ARGUMENT');

    const unauthenticated = await callFunction('createProduct', {
      idempotencyKey: randomUUID(),
      name: `Unauthenticated ${runId}`,
      quantitySpec: { unit: 'piece', precision: 0 },
    });
    assertCallableError(unauthenticated, 'UNAUTHENTICATED');
  });

  const createData = {
    idempotencyKey: ownership.createKey,
    name: ownership.productName,
    quantitySpec: { unit: 'piece', precision: 0 },
  };
  const created = assertCallableResult(
    await callFunction('createProduct', createData, administratorToken),
  );
  ownership.productId = created.productId;
  assert.match(created.internalCode, /^[A-Z][A-Z0-9-]{7,63}$/);
  assert.equal(created.productId, created.internalCode);
  assert.equal(created.replayed, false);

  const createReplay = assertCallableResult(
    await callFunction('createProduct', createData, administratorToken),
  );
  assert.deepEqual(createReplay, { ...created, replayed: true });

  const priceResult = assertCallableResult(
    await callFunction('setProductPrice', {
      idempotencyKey: ownership.priceKey,
      productId: ownership.productId,
      listedPriceMxn: '999.50',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRatePercent: '16',
    }, administratorToken),
  );
  assert.equal(priceResult.auditId, ownership.priceKey);
  assert.deepEqual(priceResult.pricing, {
    listedPriceCentavos: 99_950,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1_600,
  });
  assert.equal(priceResult.replayed, false);

  const intakeData = {
    idempotencyKey: ownership.intakeKey,
    branchId: 'branch-north',
    productId: ownership.productId,
    quantity: '2',
    unitCostMxn: '71.25',
  };
  const intake = assertCallableResult(
    await callFunction('stockIntake', intakeData, administratorToken),
  );
  assert.deepEqual(intake, {
    entryId: ownership.intakeKey,
    movementId: ownership.intakeKey,
    quantityScaled: 2,
    stockQuantityScaled: 2,
    unitCostCentavos: 7_125,
    lineTotalCentavos: 14_250,
    replayed: false,
  });
  const intakeReplay = assertCallableResult(
    await callFunction('stockIntake', intakeData, administratorToken),
  );
  assert.deepEqual(intakeReplay, { ...intake, replayed: true });

  await t.test('seller callable attempts are denied without owned artifacts', async () => {
    const attempts = [
      ['createProduct', {
        idempotencyKey: sellerKeys.create,
        name: `Seller attempt ${runId}`,
        quantitySpec: { unit: 'piece', precision: 0 },
      }],
      ['setProductPrice', {
        idempotencyKey: sellerKeys.price,
        productId: ownership.productId,
        listedPriceMxn: '1.00',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRatePercent: '16',
      }],
      ['stockIntake', {
        idempotencyKey: sellerKeys.intake,
        branchId: 'branch-north',
        productId: ownership.productId,
        quantity: '1',
        unitCostMxn: '1.00',
      }],
    ];
    for (const [name, data] of attempts) {
      assertCallableError(await callFunction(name, data, sellerToken), 'PERMISSION_DENIED');
    }
  });

  const sellerProduct = await expectAllowedRead(
    `products/${ownership.productId}`,
    sellerToken,
  );
  assert.equal(sellerProduct.internalCode, ownership.productId);
  assert.equal('createdBy' in sellerProduct, false);
  assert.equal('pricingUpdatedBy' in sellerProduct, false);
  assert.equal('unitCostCentavos' in sellerProduct, false);
  assert.equal('latestUnitCostCentavos' in sellerProduct, false);
  const sellerStock = await expectAllowedRead(
    `branches/branch-north/stock/${ownership.productId}`,
    sellerToken,
  );
  assert.equal(sellerStock.quantityScaled, 2);
  assert.equal(sellerStock.unit, 'piece');
  assert.equal(sellerStock.precision, 0);

  const protectedPaths = [
    `costs/${ownership.productId}`,
    `stockIntakeEntries/${ownership.intakeKey}`,
    `stockIntakeReceipts/${ownership.intakeKey}`,
    `productCreationReceipts/${ownership.createKey}`,
    `productPriceAudits/${ownership.priceKey}`,
    `productPriceUpdateReceipts/${ownership.priceKey}`,
  ];
  for (const path of protectedPaths) {
    await expectDeniedRead(path, sellerToken);
    await expectAllowedRead(path, administratorToken);
  }

  admin = await initializeAdmin();
  const stockAfterReplay = await admin.firestore
    .doc(`branches/branch-north/stock/${ownership.productId}`)
    .get();
  assert.equal(stockAfterReplay.data().quantityScaled, 2);

  const [audit, entry] = await Promise.all([
    admin.firestore.doc(`productPriceAudits/${ownership.priceKey}`).get(),
    admin.firestore.doc(`stockIntakeEntries/${ownership.intakeKey}`).get(),
  ]);
  assert.deepEqual(audit.data().newPricing, priceResult.pricing);
  assert.equal(audit.data().actorId, 'demo-local-administrator');
  assert.equal(entry.data().unitCostCentavos, 7_125);
  assert.equal(entry.data().lineTotalCentavos, 14_250);
  assert.equal(entry.data().calculationPolicyVersion, 'mxn-unit-cost-truncate-v1');

  const sellerArtifactPaths = [
    `productCreationReceipts/${sellerKeys.create}`,
    `productPriceAudits/${sellerKeys.price}`,
    `productPriceUpdateReceipts/${sellerKeys.price}`,
    `stockIntakeEntries/${sellerKeys.intake}`,
    `inventoryMovements/${sellerKeys.intake}`,
    `stockIntakeReceipts/${sellerKeys.intake}`,
  ];
  const sellerArtifacts = await admin.firestore.getAll(
    ...sellerArtifactPaths.map((path) => admin.firestore.doc(path)),
  );
  assert.equal(sellerArtifacts.filter(({ exists }) => exists).length, 0);
  const sellerProducts = await admin.firestore
    .collection('products')
    .where('name', '==', `Seller attempt ${runId}`)
    .get();
  assert.equal(sellerProducts.size, 0);

  await countExactOwnedRecords(admin.firestore, ownership);
});
