import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

const PROJECT_ID = 'demo-lda-inventory';
const SEED_VERSION = 1;
const LOOPBACK_HOST = /^(?:localhost|127\.0\.0\.1|\[::1\]):([1-9]\d{0,4})$/;

// These credentials are intentionally fake and valid only in the local Auth emulator.
export const DEMO_ACCOUNTS = Object.freeze([
  Object.freeze({
    uid: 'demo-local-administrator',
    email: 'administrator@demo-lda-inventory.invalid',
    password: 'Demo-Only-Administrator-2026!',
    emailVerified: false,
    disabled: false,
    claims: Object.freeze({ role: 'administrator' }),
  }),
  Object.freeze({
    uid: 'demo-local-seller-north',
    email: 'seller.north@demo-lda-inventory.invalid',
    password: 'Demo-Only-Seller-2026!',
    emailVerified: false,
    disabled: false,
    claims: Object.freeze({ role: 'seller', branchId: 'branch-north' }),
  }),
]);

const BRANCHES = [
  ['branch-north', 'North Demo Branch'],
  ['branch-south', 'South Demo Branch'],
];

const PRODUCTS = [
  {
    id: 'DEMO-COFFEE',
    data: {
      internalCode: 'DEMO-COFFEE',
      name: 'Demo Coffee',
      quantitySpec: { unit: 'piece', precision: 0 },
      pricing: {
        listedPriceCentavos: 12500,
        currency: 'MXN',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRateBasisPoints: 1600,
      },
    },
    stock: { 'branch-north': 12, 'branch-south': 3 },
  },
  {
    id: 'DEMO-RIBBON',
    data: {
      internalCode: 'DEMO-RIBBON',
      name: 'Demo Ribbon',
      quantitySpec: { unit: 'meter', precision: 2 },
      pricing: {
        listedPriceCentavos: 4500,
        currency: 'MXN',
        priceMode: 'iva-additional-on-invoice',
        ivaTreatment: 'taxable',
        ivaRateBasisPoints: 1600,
      },
    },
    stock: { 'branch-north': 0, 'branch-south': 425 },
  },
];

export function validateEmulatorEnvironment(env = process.env) {
  if (env.GCLOUD_PROJECT !== PROJECT_ID) {
    throw refusal(`GCLOUD_PROJECT must be exactly ${PROJECT_ID}`);
  }

  const firestoreHost = validateLoopbackHost(
    env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST',
  );
  const authHost = validateLoopbackHost(
    env.FIREBASE_AUTH_EMULATOR_HOST,
    'FIREBASE_AUTH_EMULATOR_HOST',
  );

  return { projectId: PROJECT_ID, firestoreHost, authHost };
}

export function buildDemoSeed() {
  const records = BRANCHES.map(([branchId, name]) => ({
    path: `branches/${branchId}`,
    data: { name, demoSeedVersion: SEED_VERSION },
  }));

  for (const product of PRODUCTS) {
    records.push({ path: `products/${product.id}`, data: structuredClone(product.data) });
    for (const [branchId] of BRANCHES) {
      records.push({
        path: `branches/${branchId}/stock/${product.id}`,
        data: {
          quantityScaled: product.stock[branchId],
          ...structuredClone(product.data.quantitySpec),
          demoSeedVersion: SEED_VERSION,
        },
      });
    }
  }

  return records;
}

export async function provisionDemo({
  env = process.env,
  loadAdmin = loadEmulatorAdmin,
} = {}) {
  const configuration = validateEmulatorEnvironment(env);
  const services = await loadAdmin(configuration);
  try {
    return await provisionDemoWithServices(services);
  } finally {
    await services.close?.();
  }
}

export async function provisionDemoWithServices({ auth, firestore } = {}) {
  requireServices(auth, firestore);

  const accountPlans = await Promise.all(
    DEMO_ACCOUNTS.map((account) => inspectAccount(auth, account)),
  );
  const records = buildDemoSeed();
  const references = records.map(({ path }) => firestore.doc(path));
  const snapshots = await firestore.getAll(...references);
  const recordsToCreate = [];

  for (let index = 0; index < records.length; index += 1) {
    const expected = records[index];
    const snapshot = snapshots[index];
    if (!snapshot.exists) {
      recordsToCreate.push(expected);
      continue;
    }
    if (!isDeepStrictEqual(snapshot.data(), expected.data)) {
      throw new Error(`Existing demo record has unexpected shape: ${expected.path}`);
    }
  }

  const accountResults = [];
  let accountsCreated = 0;
  for (const { account, create } of accountPlans) {
    const created = create && await createOwnedAccount(auth, account);
    if (created) accountsCreated += 1;
    accountResults.push({ uid: account.uid, status: created ? 'created' : 'reused' });
  }

  const recordsCreated = await createMissingRecords(
    firestore,
    records,
    recordsToCreate,
  );

  return { accountsCreated, recordsCreated, accountResults };
}

export function formatProvisioningReport({
  accountsCreated,
  recordsCreated,
  accountResults,
}) {
  const lines = [
    `Provisioned local demo only: ${accountsCreated} account(s), ${recordsCreated} record(s) created.`,
  ];

  for (const result of accountResults) {
    const account = DEMO_ACCOUNTS.find(({ uid }) => uid === result.uid);
    if (!account) throw new Error(`Unknown demo account result: ${result.uid}`);
    if (result.status === 'created') {
      lines.push(`Created fake local credential: ${account.email} / ${account.password}`);
      continue;
    }
    if (result.status === 'reused') {
      lines.push(
        `Reused existing local identity: ${account.email} (password not verified; manual sign-in verification required).`,
      );
      continue;
    }
    throw new Error(`Unknown demo account status: ${result.status}`);
  }

  return lines.join('\n');
}

function validateLoopbackHost(value, name) {
  if (typeof value !== 'string') {
    throw refusal(`${name} is required`);
  }
  const match = LOOPBACK_HOST.exec(value);
  const port = match ? Number(match[1]) : 0;
  if (!match || port > 65_535) {
    throw refusal(`${name} must be an explicit loopback host and valid port`);
  }
  return value;
}

function refusal(reason) {
  return new Error(`Refusing to provision demo data: ${reason}`);
}

function requireServices(auth, firestore) {
  if (
    !auth
    || typeof auth.getUser !== 'function'
    || typeof auth.getUserByEmail !== 'function'
    || typeof auth.createUser !== 'function'
    || typeof auth.setCustomUserClaims !== 'function'
    || typeof auth.updateUser !== 'function'
    || typeof auth.deleteUser !== 'function'
  ) {
    throw new TypeError('an Admin Auth-compatible service is required');
  }
  if (
    !firestore
    || typeof firestore.doc !== 'function'
    || typeof firestore.getAll !== 'function'
    || typeof firestore.batch !== 'function'
  ) {
    throw new TypeError('an Admin Firestore-compatible service is required');
  }
}

async function inspectAccount(auth, account) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const state = await readAccountState(auth, account);
    if (state === 'absent') return { account, create: true };
    if (state === 'exact') return { account, create: false };
    if (state !== 'provisioning-pending') break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Existing demo identity has unexpected shape: ${account.uid}`);
}

async function readAccountState(auth, account) {
  const [byUid, byEmail] = await Promise.all([
    optionalUser(() => auth.getUser(account.uid)),
    optionalUser(() => auth.getUserByEmail(account.email)),
  ]);

  if (!byUid && !byEmail) return 'absent';
  if (!byUid || !byEmail || byUid.uid !== byEmail.uid) return 'conflict';
  if (
    byUid.uid !== account.uid
    || byUid.email !== account.email
    || byUid.emailVerified !== account.emailVerified
  ) {
    return 'conflict';
  }

  const claims = byUid.customClaims ?? {};
  // Admin Auth cannot verify an existing password. Exact existing identities are
  // accepted without resetting their password; operators must not treat it as verified.
  if (byUid.disabled === account.disabled && isDeepStrictEqual(claims, account.claims)) {
    return 'exact';
  }
  if (
    account.disabled === false
    && byUid.disabled === true
    && (isDeepStrictEqual(claims, {}) || isDeepStrictEqual(claims, account.claims))
  ) {
    return 'provisioning-pending';
  }
  return 'conflict';
}

async function createOwnedAccount(auth, account) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await auth.createUser({
        uid: account.uid,
        email: account.email,
        password: account.password,
        emailVerified: account.emailVerified,
        // Keep the identity unusable until its claims are complete.
        disabled: true,
      });
    } catch (error) {
      if (!isCreateConflict(error)) throw error;
      const state = await readAccountState(auth, account);
      if (state === 'exact') return false;
      if (state === 'absent') continue;
      if (state === 'provisioning-pending') {
        await new Promise((resolve) => setTimeout(resolve, 10));
        continue;
      }
      throw new Error(`Demo account conflict for ${account.uid}/${account.email}`);
    }

    try {
      await auth.setCustomUserClaims(account.uid, account.claims);
    } catch (claimsError) {
      if (!await hasOwnedStagedClaims(auth, account)) {
        await deleteOwnedAccount(auth, account.uid, claimsError);
        throw claimsError;
      }
    }

    try {
      await auth.updateUser(account.uid, { disabled: account.disabled });
      return true;
    } catch (activationError) {
      if (await readAccountState(auth, account) === 'exact') return true;
      await deleteOwnedAccount(auth, account.uid, activationError);
      throw activationError;
    }
  }

  throw new Error(`Concurrent demo account creation did not settle: ${account.uid}`);
}

async function hasOwnedStagedClaims(auth, account) {
  const user = await optionalUser(() => auth.getUser(account.uid));
  return user?.uid === account.uid
    && user.email === account.email
    && user.emailVerified === account.emailVerified
    && user.disabled === true
    && isDeepStrictEqual(user.customClaims ?? {}, account.claims);
}

async function deleteOwnedAccount(auth, uid, cause) {
  try {
    await auth.deleteUser(uid);
  } catch (cleanupError) {
    throw new AggregateError(
      [cause, cleanupError],
      `Provisioning failed and owned demo identity cleanup failed: ${uid}`,
    );
  }
}

function isCreateConflict(error) {
  return error?.code === 'auth/uid-already-exists'
    || error?.code === 'auth/email-already-exists';
}

async function createMissingRecords(firestore, records, recordsToCreate) {
  if (recordsToCreate.length === 0) return 0;

  const batch = firestore.batch();
  for (const record of recordsToCreate) {
    batch.create(firestore.doc(record.path), record.data);
  }

  try {
    await batch.commit();
    return recordsToCreate.length;
  } catch (error) {
    const snapshots = await firestore.getAll(
      ...records.map(({ path }) => firestore.doc(path)),
    );
    const converged = records.every((record, index) => (
      snapshots[index].exists
      && isDeepStrictEqual(snapshots[index].data(), record.data)
    ));
    if (converged) return 0;
    throw error;
  }
}

async function optionalUser(operation) {
  try {
    return await operation();
  } catch (error) {
    if (error?.code === 'auth/user-not-found') return null;
    throw error;
  }
}

export async function loadEmulatorAdmin(
  configuration,
  { env = process.env, loadModules = loadAdminModules } = {},
) {
  assertMatchingConfiguration(configuration, env);

  const { projectId } = configuration;
  const [appModule, authModule, firestoreModule] = await loadModules();
  // Admin SDK emulator routing is process-global. Re-read the real environment
  // after the await and at each service boundary so injected validation input
  // cannot mask host or project drift.
  assertMatchingProcessEnvironment(configuration);

  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2_048 });
  const credential = appModule.cert({
    projectId,
    clientEmail: 'local-emulator-admin@demo-lda-inventory.invalid',
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  });
  assertMatchingProcessEnvironment(configuration);
  const app = appModule.initializeApp(
    { projectId, credential },
    `demo-provision-${randomUUID()}`,
  );

  assertMatchingProcessEnvironment(configuration);
  const auth = authModule.getAuth(app);
  assertMatchingProcessEnvironment(configuration);
  const firestore = firestoreModule.getFirestore(app);
  return {
    auth,
    firestore,
    close: () => appModule.deleteApp(app),
  };
}

function assertMatchingConfiguration(configuration, env) {
  const runtimeConfiguration = validateEmulatorEnvironment(env);
  if (!isDeepStrictEqual(runtimeConfiguration, configuration)) {
    throw refusal('validated configuration differs from the Admin SDK environment');
  }
}

function assertMatchingProcessEnvironment(configuration) {
  try {
    assertMatchingConfiguration(configuration, process.env);
  } catch (error) {
    throw refusal(`Admin SDK process environment changed: ${error.message}`);
  }
}

async function loadAdminModules() {
  return Promise.all([
    import('firebase-admin/app'),
    import('firebase-admin/auth'),
    import('firebase-admin/firestore'),
  ]);
}

async function main() {
  if (process.argv.length !== 2) {
    throw refusal('command-line project or host overrides are not accepted');
  }
  const result = await provisionDemo();
  console.log(formatProvisioningReport(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
