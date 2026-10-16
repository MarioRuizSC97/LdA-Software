#!/usr/bin/env node
/**
 * EI-03 — isolated destination-notice E2E harness (owned processes only).
 *
 * One clean run proves, through the public Flutter web UI in the authorized
 * project-local Chrome for Testing, that: an administrator transfer from the
 * south branch reaches an already-open north seller as a live unread notice,
 * an explicit in-UI mark-as-read persists across a fresh browser session with
 * history retained, and a second seller of the same destination branch stays
 * independently unread. Everything runs on frozen isolated ports and never
 * touches the developer's running demo runtime:
 *
 *   browser-visible -> owned isolated
 *   Auth      9099  -> 8299      (frozen)
 *   Firestore 8080  -> 8280      (frozen)
 *   Functions 5001  -> 5201      (frozen)
 *   App web   7358  -> 7358      (frozen, owned static server)
 *   CLI hub   7440, Firestore websocket 7460 (owned, UI disabled)
 *   proxy + CDP ports               (ephemeral)
 *
 * No listeners or requests are ever made to the protected demo ports
 * (9099/8080/5001/4400/4500/4000/9299/9499/9150/7357): reserved listener
 * fingerprints are snapshotted before and re-checked after the run without
 * querying demo data. The Firebase CLI uses a generated `--config` file, a
 * redirected HOME/XDG_CONFIG_HOME, and a run-folder emulator cache containing
 * a symlink to the already-cached Firestore 1.22.0 jar, so it can never
 * download emulators, read a global profile, or pick up real credentials.
 *
 * Modes:
 *   --help      print usage and exit; no services.
 *   --dry-run   report the intended run plan read-only; no SDK/service ops.
 *   --run       execute the full E2E; requires --web-build and the pinned
 *               Node 24 runtime. No retries: any failure tears everything
 *               down and exits non-zero with stage evidence.
 */
import {
  execFile as nodeExecFile, spawn as nodeSpawn,
} from 'node:child_process';
import { randomUUID } from 'node:crypto';
import {
  createWriteStream, mkdirSync, readFileSync, statSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { readFile, writeFile as writeFileAsync } from 'node:fs/promises';
import { createServer as nodeCreateServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

import {
  REPO_ROOT,
  RunnerError,
  RESERVED_PORTS as DEMO_RESERVED_PORTS,
  parseListeners,
  pinnedNodePath,
  portFingerprint,
  resolveEmulatorJar,
  resolveNodeInfo,
  stopOwnedChild,
  trackChild,
} from './test-transfers-isolated.mjs';
import {
  DEFAULT_CHROME_PATH,
  BrowserError,
  openPage,
  startIsolatedBrowser,
} from './transfer-notice-e2e-browser.mjs';

const MODULE_PATH = fileURLToPath(import.meta.url);
export const FUNCTIONS_ROOT = resolve(dirname(MODULE_PATH), '..');
export const REPOSITORY_ROOT = REPO_ROOT;
export const NOTICE_RUN_ROOT = join(REPOSITORY_ROOT, '.dart_tool', 'notice-e2e');

export const PROJECT_ID = 'demo-lda-inventory';
export const FIRESTORE_JAR_VERSION = '1.22.0';
export const ISOLATED_AUTH_PORT = 8299;
export const ISOLATED_FIRESTORE_PORT = 8280;
export const ISOLATED_FUNCTIONS_PORT = 5201;
export const ISOLATED_HUB_PORT = 7440;
export const FIRESTORE_WEBSOCKET_PORT = 7460;
export const APP_PORT = 7358;
// Frozen L11 contract: browser-visible source ports -> owned isolated targets.
export const BROWSER_ROUTES = Object.freeze({
  9099: ISOLATED_AUTH_PORT,
  8080: ISOLATED_FIRESTORE_PORT,
  5001: ISOLATED_FUNCTIONS_PORT,
  7358: APP_PORT,
});
export const OWNED_PORTS = Object.freeze([
  ISOLATED_AUTH_PORT, ISOLATED_FIRESTORE_PORT, ISOLATED_FUNCTIONS_PORT,
  ISOLATED_HUB_PORT, FIRESTORE_WEBSOCKET_PORT, APP_PORT,
]);
export const RUN_MARKER = 'LDA_NOTICE_E2E_RUN_ID';
export const FIREBASE_CLI_RELATIVE = join(
  '.local', 'share', 'lda-firebase-tools', 'node_modules', 'firebase-tools', 'lib', 'bin', 'firebase.js',
);
export const PROXY_MODULE_RELATIVE = 'isolated-browser-proxy.mjs';
export const PROVISION_OUTPUT_PREFIX = '__NOTICE_E2E_PROVISION__';

export const TIMEOUTS = Object.freeze({
  cliReadyMs: 240_000,
  seedMs: 120_000,
  stageMs: 240_000,
  semanticStepMs: 20_000,
  totalMs: 1_200_000,
  pollMs: 250,
  termMs: 10_000,
  killMs: 5_000,
  portReleaseMs: 20_000,
});

// Any of these would hand the run a real cloud identity, re-route it to the
// developer's demo runtime, or leak a proxy/Java override into owned children.
const FORBIDDEN_ENV_KEYS = Object.freeze([
  'FIREBASE_TOKEN',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'GOOGLE_CLOUD_PROJECT',
  'GOOGLE_CLOUD_UNIVERSE_DOMAIN',
  'GCLOUD_UNIVERSE_DOMAIN',
  'CLOUDSDK_CORE_PROJECT',
  'GOOGLE_API_USE_MTLS_ENDPOINT',
  'GOOGLE_API_USE_CLIENT_CERTIFICATE',
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIREBASE_FIRESTORE_EMULATOR_ADDRESS',
  'FIRESTORE_EMULATOR_HOST',
  'FIREBASE_DATABASE_EMULATOR_HOST',
  'FIRESTORE_PREFER_REST',
  'START_LOGGING_EMULATOR',
  'FIREBASE_EMULATORS_PATH',
  'FIRESTORE_EMULATOR_VERSION',
  'JAVA_TOOL_OPTIONS',
  'JDK_JAVA_OPTIONS',
  '_JAVA_OPTIONS',
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'GRPC_PROXY', 'NO_PROXY',
  'http_proxy', 'https_proxy', 'all_proxy', 'grpc_proxy', 'no_proxy',
]);

export const USAGE = `Isolated destination-notice E2E (owned processes only).

Usage:
  node scripts/transfer-notice-e2e.mjs --help
  node scripts/transfer-notice-e2e.mjs --dry-run [--web-build <repo-contained web build directory>]
  node scripts/transfer-notice-e2e.mjs --run --web-build <repo-contained web build directory>

Modes (exactly one):
  --help      Print this help and exit. No services, no processes.
  --dry-run   Read-only plan report (no SDK/service operations, no spawning).
  --run       Execute the full isolated E2E. Requires --web-build and the
              pinned Node 24 runtime. Parent-authorized executions only.

Options:
  --web-build <path>   Repo-contained path to the isolated Flutter web build
                       (the folder produced with LDA_LOCAL_EMULATORS=true and
                       its sibling build-manifest.json). The default build/web
                       is never accepted.

Frozen isolation contract:
  Auth 9099->8299, Firestore 8080->8280, Functions 5001->5201,
  app web 7358->7358, hub 7440, Firestore websocket 7460; proxy/CDP ephemeral.
  Demo ports are never bound or contacted. Chrome for Testing is spawned only
  from .dart_tool/e2e-browser with mandatory proxy flags and a disposable
  profile. Runs write only under .dart_tool/notice-e2e/<run-id>/.
`;

// ---------------------------------------------------------------------------
// Disposable fixture (clean isolated emulator only; never the current demo).
// ---------------------------------------------------------------------------

export const NOTICE_FIXTURE = Object.freeze({
  accounts: Object.freeze([
    Object.freeze({
      uid: 'notice-e2e-administrator',
      email: 'administrator@notice-e2e.invalid',
      password: 'Notice-E2E-Administrator-2026!',
      claims: Object.freeze({ role: 'administrator' }),
    }),
    Object.freeze({
      uid: 'notice-e2e-seller-north-1',
      email: 'seller1@notice-e2e.invalid',
      password: 'Notice-E2E-Seller1-2026!',
      claims: Object.freeze({ role: 'seller', branchId: 'branch-north' }),
    }),
    Object.freeze({
      uid: 'notice-e2e-seller-north-2',
      email: 'seller2@notice-e2e.invalid',
      password: 'Notice-E2E-Seller2-2026!',
      claims: Object.freeze({ role: 'seller', branchId: 'branch-north' }),
    }),
  ]),
  branches: Object.freeze([
    Object.freeze({ id: 'branch-north', name: 'North Demo Branch', code: 'NTE' }),
    Object.freeze({ id: 'branch-south', name: 'South Demo Branch', code: 'SUR' }),
  ]),
  products: Object.freeze([
    Object.freeze({
      id: 'DEMO-COFFEE',
      data: Object.freeze({
        internalCode: 'DEMO-COFFEE',
        name: 'Demo Coffee',
        quantitySpec: Object.freeze({ unit: 'piece', precision: 0 }),
        pricing: Object.freeze({
          listedPriceCentavos: 12500,
          currency: 'MXN',
          priceMode: 'iva-included',
          ivaTreatment: 'taxable',
          ivaRateBasisPoints: 1600,
        }),
      }),
      stock: Object.freeze({ 'branch-north': 0, 'branch-south': 3 }),
    }),
  ]),
  transfer: Object.freeze({ sourceBranchId: 'branch-south', destinationBranchId: 'branch-north', productId: 'DEMO-COFFEE', quantity: '1' }),
});

// Pure seed spec. The guard makes "no seeded transfer audit as a substitute
// for the actual UI transfer" a structural refusal, not a hope.
export function buildSeedRecords(fixture = NOTICE_FIXTURE) {
  const records = [];
  for (const branch of fixture.branches) {
    records.push({
      path: `branches/${branch.id}`,
      data: { name: branch.name, code: branch.code },
    });
  }
  for (const product of fixture.products) {
    records.push({ path: `products/${product.id}`, data: structuredClone(product.data) });
    for (const branch of fixture.branches) {
      if (product.stock[branch.id] === undefined) {
        throw new RunnerError(`fixture stock is missing for ${branch.id}/${product.id}`);
      }
      records.push({
        path: `branches/${branch.id}/stock/${product.id}`,
        data: { quantityScaled: product.stock[branch.id], ...structuredClone(product.data.quantitySpec) },
      });
    }
  }
  for (const record of records) {
    if (record.path.startsWith('transfers/') || record.path.startsWith('transferNoticeReads/')) {
      throw new RunnerError(`refusing to seed the business audit path ${record.path}`);
    }
  }
  return Object.freeze(records.map((record) => Object.freeze(record)));
}

// Generates the provisioning child source. The child is executed with
// `node --input-type=module --eval` from the functions directory so the real
// firebase-admin resolves from functions/node_modules, and only ever after the
// parent env has been rewritten to the isolated 8299/8280 addresses.
export function generateProvisionScript({ fixture = NOTICE_FIXTURE, authAddress, firestoreAddress, projectId = PROJECT_ID } = {}) {
  if (!/^\d+\.\d+\.\d+\.\d+:\d+$/.test(String(authAddress))) throw new RunnerError('authAddress must be a loopback host:port');
  if (!/^\d+\.\d+\.\d+\.\d+:\d+$/.test(String(firestoreAddress))) throw new RunnerError('firestoreAddress must be a loopback host:port');
  const records = buildSeedRecords(fixture);
  const header = `// Generated by transfer-notice-e2e.mjs for run-scoped disposable fixtures only.
// Executed via --eval with cwd <repo>/functions; never against a real project.
import { generateKeyPairSync } from 'node:crypto';
import { initializeApp, cert } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

const PROJECT_ID = ${JSON.stringify(projectId)};
const AUTH_ADDRESS = ${JSON.stringify(authAddress)};
const FIRESTORE_ADDRESS = ${JSON.stringify(firestoreAddress)};
const ACCOUNTS = ${JSON.stringify(fixture.accounts, null, 2)};
const RECORDS = ${JSON.stringify(records.map(({ path, data }) => ({ path, data })), null, 2)};

function assertEnvironment() {
  const env = process.env;
  const refusals = [];
  if (env.GCLOUD_PROJECT !== PROJECT_ID) refusals.push('GCLOUD_PROJECT must be exactly ' + PROJECT_ID);
  if (env.FIREBASE_AUTH_EMULATOR_HOST !== AUTH_ADDRESS) refusals.push('FIREBASE_AUTH_EMULATOR_HOST must be ' + AUTH_ADDRESS);
  if (env.FIRESTORE_EMULATOR_HOST !== FIRESTORE_ADDRESS) refusals.push('FIRESTORE_EMULATOR_HOST must be ' + FIRESTORE_ADDRESS);
  if (env.GOOGLE_APPLICATION_CREDENTIALS) refusals.push('GOOGLE_APPLICATION_CREDENTIALS must be absent');
  if (env.FIREBASE_TOKEN) refusals.push('FIREBASE_TOKEN must be absent');
  if (refusals.length > 0) throw new Error('Refusing to provision disposable fixtures: ' + refusals.join('; '));
}
`;
  const body = `
assertEnvironment();
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const app = initializeApp({
  projectId: PROJECT_ID,
  credential: cert({
    projectId: PROJECT_ID,
    clientEmail: 'notice-e2e-provision@demo-lda-inventory.invalid',
    privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
  }),
}, 'notice-e2e-provision');
const auth = getAuth(app);
const firestore = getFirestore(app);

try {
  for (const account of ACCOUNTS) {
    await auth.createUser({
      uid: account.uid,
      email: account.email,
      password: account.password,
      emailVerified: false,
      disabled: true,
    });
    await auth.setCustomUserClaims(account.uid, account.claims);
    await auth.updateUser(account.uid, { disabled: false });
  }
  const batch = firestore.batch();
  for (const record of RECORDS) batch.create(firestore.doc(record.path), record.data);
  await batch.commit();
  console.log(${JSON.stringify(PROVISION_OUTPUT_PREFIX)} + JSON.stringify({
    accounts: ACCOUNTS.map((account) => ({ uid: account.uid, email: account.email })),
    recordsCreated: RECORDS.length,
  }));
} finally {
  await app.delete().catch(() => {});
}
`;
  return header + body;
}

// ---------------------------------------------------------------------------
// CLI surface
// ---------------------------------------------------------------------------

export function renderHelp() {
  return USAGE;
}

export function parseArgs(argv = []) {
  let mode = null;
  let webBuild = null;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help') {
      mode = 'help';
    } else if (arg === '--dry-run') {
      if (mode === 'run') throw new RunnerError(`choose exactly one mode: --help, --dry-run or --run\n\n${USAGE}`);
      mode = 'dry-run';
    } else if (arg === '--run') {
      if (mode === 'dry-run') throw new RunnerError(`choose exactly one mode: --help, --dry-run or --run\n\n${USAGE}`);
      mode = 'run';
    } else if (arg === '--web-build') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) {
        throw new RunnerError('--web-build requires a repo-contained directory path\n\n' + USAGE);
      }
      webBuild = value;
      index += 1;
    } else if (arg.startsWith('--web-build=')) {
      webBuild = arg.slice('--web-build='.length);
      if (!webBuild) throw new RunnerError('--web-build requires a repo-contained directory path\n\n' + USAGE);
    } else {
      throw new RunnerError(`unknown argument ${JSON.stringify(arg)}\n\n` + USAGE);
    }
  }
  if (mode === null) {
    throw new RunnerError(`choose an explicit mode: --help, --dry-run or --run\n\n${USAGE}`);
  }
  if (mode === 'run' && webBuild === null) {
    throw new RunnerError(`--run requires --web-build <repo-contained isolated web build>\n\n${USAGE}`);
  }
  return Object.freeze({ mode, webBuild });
}

export function resolveWebBuildPath(value, { repoRoot = REPOSITORY_ROOT } = {}) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new RunnerError('--web-build requires a repo-contained directory path');
  }
  const absolute = isAbsolute(value) ? resolve(value) : resolve(repoRoot, value);
  if (!absolute.startsWith(`${repoRoot}${sep}`)) {
    throw new RunnerError(`--web-build must stay inside the repository: ${absolute}`);
  }
  if (absolute === join(repoRoot, 'build', 'web')) {
    throw new RunnerError(
      'refusing the default build/web output: pass the isolated build directory '
      + 'compiled with LDA_LOCAL_EMULATORS=true (see build-manifest.json)',
    );
  }
  return absolute;
}

export function assertWebBuild(webBuild, { statPath = defaultStatPath, readFile = defaultReadFile } = {}) {
  const stat = statPath(webBuild);
  if (!stat || !stat.isDirectory()) {
    throw new RunnerError(`the isolated web build directory is missing at ${webBuild}`);
  }
  for (const file of ['index.html', 'main.dart.js', 'flutter_bootstrap.js']) {
    const fileStat = statPath(join(webBuild, file));
    if (!fileStat || !fileStat.isFile()) {
      throw new RunnerError(`the isolated web build is incomplete: ${join(webBuild, file)} is missing`);
    }
  }
  const manifestPath = join(dirname(webBuild), 'build-manifest.json');
  let manifest;
  try {
    manifest = JSON.parse(readFile(manifestPath, 'utf8'));
  } catch (error) {
    throw new RunnerError(`the sibling build-manifest.json is unreadable at ${manifestPath}: ${error?.message ?? error}`);
  }
  if (manifest.dartDefines?.LDA_LOCAL_EMULATORS !== 'true') {
    throw new RunnerError(
      `the web build was not compiled with LDA_LOCAL_EMULATORS=true (manifest says `
      + `${JSON.stringify(manifest.dartDefines ?? null)}); refusing to run against an unknown build`,
    );
  }
  if (manifest.buildExitCode !== 0) {
    throw new RunnerError(`the web build manifest records buildExitCode=${JSON.stringify(manifest.buildExitCode)}`);
  }
  return Object.freeze({
    path: webBuild,
    manifestPath,
    mode: manifest.mode ?? null,
    dartDefines: Object.freeze({ ...(manifest.dartDefines ?? {}) }),
    webResourcesCdn: Boolean(manifest.webResourcesCdn),
    buildExitCode: manifest.buildExitCode,
    sourceTreeSha256: manifest.sourceTreeSha256 ?? null,
    webMainSha256: manifest.webMainSha256 ?? null,
  });
}

export function assertRunEnvironment(env = process.env) {
  if (!env || typeof env !== 'object') throw new RunnerError('a process environment object is required');
  for (const key of FORBIDDEN_ENV_KEYS) {
    if (env[key] !== undefined) {
      throw new RunnerError(`refusing to run with the inherited ${key} override; unset it and retry cleanly`);
    }
  }
  if (typeof env.HOME !== 'string' || env.HOME.length === 0) {
    throw new RunnerError('HOME is required to locate the pinned runtimes and cached emulator');
  }
  if (env[RUN_MARKER] !== undefined) {
    throw new RunnerError(`refusing to run with the inherited ${RUN_MARKER} override; every run mints a fresh id`);
  }
  return Object.freeze({ home: env.HOME });
}

function firebaseCliPath({ home }) {
  return join(home, FIREBASE_CLI_RELATIVE);
}

// Child environment for the CLI and every spawned helper: cloud credentials
// and conflicting emulator routing scrubbed, HOME/XDG/CLOUDSDK redirected into
// the run folder, emulator cache pointed at the run-local jar symlink.
export function buildRunEnvironment(env, { runId, runDir } = {}) {
  const base = assertRunEnvironment(env);
  const child = { PATH: env.PATH ?? '/usr/bin:/bin', SHELL: '/bin/false' };
  for (const [key, value] of Object.entries(env)) {
    if (FORBIDDEN_ENV_KEYS.includes(key)) continue;
    if (key.startsWith('FIREBASE_') || key.startsWith('GOOGLE_') || key.startsWith('CLOUDSDK_')) continue;
    if (key === 'PWD' || key === 'OLDPWD' || key === 'NODE_OPTIONS' || key === 'NODE_PATH') continue;
    child[key] = value;
  }
  child.HOME = join(runDir, 'home');
  child.XDG_CONFIG_HOME = join(runDir, 'home', '.config');
  child.CLOUDSDK_CONFIG = join(runDir, 'home', '.config', 'gcloud');
  child.FIREBASE_EMULATORS_PATH = join(runDir, 'emulator-cache');
  child.GCLOUD_PROJECT = PROJECT_ID;
  child.CI = 'true';
  child.NO_UPDATE_NOTIFIER = '1';
  child[RUN_MARKER] = runId;
  Object.freeze(child);
  return { env: child, home: base.home };
}

export function buildSeedEnvironment(env, options = {}) {
  const { env: child } = buildRunEnvironment(env, options);
  return Object.freeze({
    ...child,
    GCLOUD_PROJECT: PROJECT_ID,
    FIRESTORE_EMULATOR_HOST: `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`,
    FIREBASE_AUTH_EMULATOR_HOST: `127.0.0.1:${ISOLATED_AUTH_PORT}`,
  });
}

// firebase-tools prints exactly one of these two lines per run. A bound port
// proves nothing about the deployment: four runs looked "ready" with a Functions
// emulator that had zero callables. The runner therefore reads its own CLI output
// and refuses to continue without the callables the flow actually needs.
const FUNCTIONS_LOAD_FAILURE_PATTERN = /Failed to load function definition[^\n]*/i;
const FUNCTIONS_LOADED_PATTERN = /Loaded functions definitions from source:\s*([^\n]+)/i;
const CLI_TAIL_CHARS = 64_000;

export const REQUIRED_CALLABLES = Object.freeze(['transferInventory', 'markTransferNoticeRead']);

export function functionsLoadFailure(cliLogText) {
  const match = FUNCTIONS_LOAD_FAILURE_PATTERN.exec(String(cliLogText ?? ''));
  return match ? match[0].trim() : null;
}

export function loadedFunctionNames(cliLogText) {
  const match = FUNCTIONS_LOADED_PATTERN.exec(String(cliLogText ?? ''));
  if (!match) return [];
  // The CLI line ends with a period; strip it so callable names compare exactly.
  return match[1].split(',').map((name) => name.trim().replace(/\.+$/, '')).filter(Boolean);
}

export function assertFunctionsDeployed(cliLogText, { required = REQUIRED_CALLABLES } = {}) {
  const failure = functionsLoadFailure(cliLogText);
  if (failure) {
    throw new RunnerError(`the Functions emulator did not load the callables: ${failure}`);
  }
  const loaded = loadedFunctionNames(cliLogText);
  if (loaded.length === 0) {
    throw new RunnerError('the owned CLI never reported "Loaded functions definitions"; the Functions emulator has no callables');
  }
  const missing = required.filter((name) => !loaded.includes(name));
  if (missing.length > 0) {
    throw new RunnerError(`the Functions emulator did not load ${missing.join(', ')}`);
  }
  return loaded;
}

async function waitForDeployedFunctions({ output, d }) {
  const deadline = d.now() + d.timeouts.cliReadyMs;
  for (;;) {
    const text = output();
    if (functionsLoadFailure(text) || loadedFunctionNames(text).length > 0) {
      return assertFunctionsDeployed(text);
    }
    if (d.now() >= deadline) {
      throw new RunnerError('the owned CLI never reported loaded functions; the Functions emulator would have none');
    }
    await d.sleep(d.timeouts.pollMs);
  }
}

// With no rules loaded the Firestore emulator accepts everything, so refusing a
// client with no credentials is the proof that the repository rules are really in
// force inside the run (neither the CLI nor the Firestore log prints a rules
// line, which is why this went unnoticed for every earlier run).
export const RULES_PROBE_DOCUMENT = 'notice-e2e-rules-probe';

async function readProbeBody(response) {
  try {
    return String((await response?.text?.()) ?? '');
  } catch {
    return '';
  }
}

export async function assertRulesEnforced({ firestoreHost, projectId, fetchImpl } = {}) {
  if (typeof fetchImpl !== 'function') {
    throw new RunnerError('a fetch implementation is required to probe the isolated Firestore rules');
  }
  if (typeof firestoreHost !== 'string' || firestoreHost.length === 0
    || typeof projectId !== 'string' || projectId.length === 0) {
    throw new RunnerError('the rules probe needs the isolated Firestore host and project id');
  }
  const base = `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;
  const probes = [
    {
      name: 'write',
      url: `${base}/products?documentId=${RULES_PROBE_DOCUMENT}`,
      init: {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ fields: {} }),
      },
    },
    { name: 'read', url: `${base}/branches/${RULES_PROBE_DOCUMENT}`, init: { method: 'GET' } },
  ];
  const outcomes = {};
  for (const probe of probes) {
    const response = await fetchImpl(probe.url, probe.init);
    const status = Number(response?.status);
    if (status === 401 || status === 403) {
      outcomes[probe.name] = 'denied';
      continue;
    }
    const body = await readProbeBody(response);
    if (status === 200 || status === 201) {
      throw new RunnerError(
        `the isolated Firestore answered ${status} to an unauthenticated ${probe.name}, `
        + `so the repository rules are not in force: ${body.slice(0, 120)}`,
      );
    }
    throw new RunnerError(
      `the rules probe was inconclusive: the ${probe.name} probe answered ${status} ${body.slice(0, 120)}`,
    );
  }
  return Object.freeze(outcomes);
}

// A crash must never leak owned processes. The runner installs this handler for
// uncaught exceptions and unhandled rejections, tears down exactly what it owns
// and only then exits non-zero: job-20 died on an unhandled socket error, the
// finally never ran, and the isolated emulator plus a browser stayed alive.
export function createCrashHandler({
  note = () => {},
  recordFailure = () => {},
  teardown = async () => {},
  exit = () => {},
} = {}) {
  let handling = false;
  return (error) => {
    if (handling) return;
    handling = true;
    recordFailure(error);
    note(`uncaught exception: ${error?.message ?? error}; tearing down owned processes`);
    Promise.resolve()
      .then(() => teardown())
      .catch(() => {})
      .finally(() => exit(1));
  };
}

export function buildFirebaseConfig({ functionsSource, firestoreRules, firestoreIndexes } = {}) {
  for (const [name, value] of [
    ['functionsSource', functionsSource],
    ['firestoreRules', firestoreRules],
    ['firestoreIndexes', firestoreIndexes],
  ]) {
    const escapes = typeof value === 'string' && value.split(sep).includes('..');
    if (typeof value !== 'string' || value.length === 0 || isAbsolute(value) || escapes) {
      throw new RunnerError(
        `${name} must stay inside the project directory: firebase-tools refuses a source outside it`,
      );
    }
  }
  // firebase-tools resolves every source against the config file's own directory
  // AND refuses sources outside it. Absolute paths are joined instead of
  // honoured (so the functions emulator watched "<configDir>/Users/..." and
  // loaded zero functions in four runs), and escaping relative paths abort the
  // CLI with "outside of project directory". The runner therefore links the
  // repository sources into the run directory and names them plainly here.
  return Object.freeze({
    functions: Object.freeze({ source: functionsSource, runtime: 'nodejs24' }),
    firestore: Object.freeze({ rules: firestoreRules, indexes: firestoreIndexes }),
    emulators: Object.freeze({
      auth: Object.freeze({ host: '127.0.0.1', port: ISOLATED_AUTH_PORT }),
      firestore: Object.freeze({ host: '127.0.0.1', port: ISOLATED_FIRESTORE_PORT, websocketPort: FIRESTORE_WEBSOCKET_PORT }),
      functions: Object.freeze({ host: '127.0.0.1', port: ISOLATED_FUNCTIONS_PORT }),
      hub: Object.freeze({ host: '127.0.0.1', port: ISOLATED_HUB_PORT }),
      ui: Object.freeze({ enabled: false }),
    }),
  });
}

export function buildFirebaseArgs(configPath) {
  if (typeof configPath !== 'string' || !isAbsolute(configPath)) {
    throw new RunnerError('the generated firebase.json path must be absolute');
  }
  return Object.freeze([
    'emulators:start',
    '--only', 'auth,firestore,functions',
    '--project', PROJECT_ID,
    '--config', configPath,
  ]);
}

// ---------------------------------------------------------------------------
// Owned static web server for the app on 7358
// ---------------------------------------------------------------------------

const CONTENT_TYPES = Object.freeze({
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
  '.bin': 'application/octet-stream',
});

export async function startOwnedWebServer({ webBuild, port = APP_PORT, host = '127.0.0.1', deps = {} } = {}) {
  const d = { createServer: nodeCreateServer, now: defaultNow, listenMs: 15_000, ...deps };
  if (typeof webBuild !== 'string' || !isAbsolute(webBuild)) {
    throw new RunnerError('the web build directory must be an absolute repo-contained path');
  }
  if (!defaultStatPath(webBuild)?.isDirectory()) {
    throw new RunnerError(`the web build directory is missing at ${webBuild}`);
  }
  const root = resolve(webBuild);
  const server = d.createServer((request, response) => {
    // Chrome aborts static requests constantly and the proxy forwards those
    // aborts; an 'error' listener on both sides keeps a peer reset from becoming
    // an uncaught exception in the harness process.
    request.on('error', () => {});
    response.on('error', () => {});
    const fail = (code, message) => {
      response.statusCode = code;
      response.end(message);
    };
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      fail(405, 'method not allowed');
      return;
    }
    let pathname;
    try {
      pathname = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
    } catch {
      fail(400, 'bad request');
      return;
    }
    const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
    const candidate = resolve(root, relative);
    if (candidate !== root && !candidate.startsWith(`${root}${sep}`)) {
      fail(403, 'forbidden');
      return;
    }
    let stat;
    try {
      stat = statSync(candidate);
    } catch {
      fail(404, 'not found');
      return;
    }
    if (!stat.isFile()) {
      fail(404, 'not found');
      return;
    }
    const type = CONTENT_TYPES[candidate.slice(candidate.lastIndexOf('.'))] ?? 'application/octet-stream';
    response.statusCode = 200;
    response.setHeader('Content-Type', type);
    response.setHeader('Content-Length', stat.size);
    response.setHeader('Cache-Control', 'no-store');
    if (request.method === 'HEAD') {
      response.end();
      return;
    }
    const stream = createReadStream(candidate);
    stream.on('error', () => fail(500, 'read error'));
    stream.pipe(response);
  });
  await new Promise((resolvePromise, rejectPromise) => {
    const deadline = d.now() + d.listenMs;
    const onError = (error) => rejectPromise(new RunnerError(`cannot bind ${host}:${port}: ${error?.message ?? error}`));
    server.once('error', onError);
    server.listen(port, host, () => {
      server.removeListener('error', onError);
      resolvePromise(server.address()?.port ?? port);
    });
    const poll = setInterval(() => {
      if (d.now() >= deadline) {
        clearInterval(poll);
        rejectPromise(new RunnerError(`the owned app web server did not bind ${host}:${port} in time`));
      }
    }, 50);
    server.once('close', () => clearInterval(poll));
    server.once('listening', () => clearInterval(poll));
  });
  let closed = false;
  const boundPort = server.address()?.port ?? port;
  return Object.freeze({
    port: boundPort,
    host,
    close: () => new Promise((resolvePromise) => {
      if (closed) {
        resolvePromise();
        return;
      }
      closed = true;
      // Owned teardown must never wait on keep-alive client sockets.
      server.closeAllConnections?.();
      server.close(() => resolvePromise());
    }),
  });
}

// ---------------------------------------------------------------------------
// Dry-run plan (no services, no SDK operations)
// ---------------------------------------------------------------------------

export async function buildDryRunPlan({ argv, env = process.env, deps = {} } = {}) {
  const d = {
    statFile: defaultStatFile,
    readFile: defaultReadFile,
    node: resolveNodeInfo(),
    runId: randomUUID(),
    ...deps,
  };
  const args = parseArgs(argv);
  const plan = {
    label: 'no-app-e2e-dry-run',
    mode: 'dry-run',
    servicesStarted: false,
    runId: d.runId,
    runDirectory: join(NOTICE_RUN_ROOT, d.runId),
    project: PROJECT_ID,
    routes: BROWSER_ROUTES,
    ownedPorts: OWNED_PORTS,
    node: { version: d.node.version, matchesPinned: false, pinnedPath: pinnedNodePath({ home: env.HOME }) },
    webBuild: null,
    chrome: null,
    firebaseCli: null,
    emulatorJar: null,
    proxy: null,
    fixture: { accounts: NOTICE_FIXTURE.accounts.map((a) => a.uid), records: buildSeedRecords().length },
    steps: [
      'preflight fingerprints + busy-port refusal',
      'generate firebase.json and spawn the CLI on isolated ports (UI disabled, hub 7440, ws 7460)',
      'seed disposable accounts/stock via fresh Admin SDK child on 8299/8280',
      'start isolated browser proxy (A API) and owned app web server on 7358',
      'drive the public UI: admin transfer south->north, seller1 live notice, explicit read, '
        + 'fresh-session persistence, seller2 independent unread',
      'teardown everything owned and verify freed ports + unchanged demo fingerprints',
    ],
  };
  try {
    assertRunEnvironment(env);
    plan.environment = 'clean';
  } catch (error) {
    plan.environment = `refused: ${error.message}`;
  }
  if (env.HOME) {
    const pinned = pinnedNodePath({ home: env.HOME });
    plan.node.matchesPinned = d.node.execPath === pinned && d.node.version.startsWith('v24.');
  }
  if (args.webBuild) {
    try {
      const resolved = resolveWebBuildPath(args.webBuild, { repoRoot: d.repoRoot });
      plan.webBuild = { requested: args.webBuild, ...assertWebBuild(resolved, d) };
    } catch (error) {
      plan.webBuild = { requested: args.webBuild, error: error.message };
    }
  } else {
    plan.webBuild = { requested: null, note: 'pass --web-build for --run; dry-run only reports the intended path' };
  }  plan.chrome = { path: DEFAULT_CHROME_PATH, present: d.statFile(DEFAULT_CHROME_PATH) };
  if (env.HOME) {
    const cli = firebaseCliPath({ home: env.HOME });
    plan.firebaseCli = { path: cli, present: d.statFile(cli) };
    let jar = null;
    try {
      jar = resolveEmulatorJar({ home: env.HOME });
    } catch {
      jar = null;
    }
    plan.emulatorJar = jar
      ? { path: jar, version: FIRESTORE_JAR_VERSION, present: d.statFile(jar) }
      : { path: null, present: false };
  }
  const proxyModulePath = join(FUNCTIONS_ROOT, 'scripts', PROXY_MODULE_RELATIVE);
  plan.proxy = {
    modulePath: proxyModulePath,
    present: d.statFile(proxyModulePath),
    expectedExport: 'startIsolatedBrowserProxy',
    staticCdn: 'www.gstatic.com only',
  };
  return Object.freeze(plan);
}

// ---------------------------------------------------------------------------
// Owned run lifecycle
// ---------------------------------------------------------------------------

export async function runIsolatedNoticeE2E({ argv, env = process.env, deps = {} } = {}) {
  const d = withDefaults(deps);
  const args = parseArgs(argv);
  if (args.mode !== 'run') throw new RunnerError('runIsolatedNoticeE2E requires --run');
  const config = assertRunEnvironment(env);
  const node = assertPinnedNode({ execPath: d.node.execPath, version: d.node.version, home: config.home });
  const webBuildPath = resolveWebBuildPath(args.webBuild, { repoRoot: d.repoRoot });
  const webBuild = assertWebBuild(webBuildPath, d);  const chromePath = d.chromePath ?? DEFAULT_CHROME_PATH;
  assertChromeBinaryForRun(chromePath, d);
  const cliPath = firebaseCliPath({ home: config.home });
  if (!d.statFile(cliPath)) {
    throw new RunnerError(`the authorized firebase-tools CLI is missing at ${cliPath}; this run never installs anything`);
  }
  const jarPath = resolveEmulatorJar({ home: config.home });
  if (!d.statFile(jarPath)) {
    throw new RunnerError(
      `the cached Firestore ${FIRESTORE_JAR_VERSION} emulator jar is missing at ${jarPath}; this run never downloads emulators`,
    );
  }
  const proxyModulePath = join(FUNCTIONS_ROOT, 'scripts', PROXY_MODULE_RELATIVE);
  if (!d.statFile(proxyModulePath)) {
    throw new RunnerError(`the frozen proxy module is missing at ${proxyModulePath}; writer A owns that surface`);
  }
  const proxyModule = await d.loadProxyModule();
  if (typeof proxyModule.startIsolatedBrowserProxy !== 'function') {
    throw new RunnerError(`${PROXY_MODULE_RELATIVE} must export startIsolatedBrowserProxy`);
  }

  const paths = resolveRunPaths(d.runId);
  const before = await snapshotListeners(d);
  const busy = OWNED_PORTS.filter((port) => before.rows.some((row) => row.port === port));
  if (busy.length > 0) {
    throw new RunnerError(
      `refusing to start: owned port(s) ${busy.join(', ')} already bound; every owned port must be free before spawning`,
    );
  }
  d.mkdir(paths.runDir);
  const logs = {
    stages: d.openLog(join(paths.runDir, 'stages.log')),
    cli: d.openLog(join(paths.cliLog)),
    audit: d.openLog(join(paths.runDir, 'proxy-audit.log')),
  };
  const note = (message) => logs.stages.write(`[${new Date().toISOString()}] ${message}\n`);
  const latch = createTerminateLatch(d.registerTerminate);
  const stages = [];
  const recordStage = (name, status, detail = null) => {
    stages.push(Object.freeze({ name, status, detail }));
    note(`stage ${name}: ${status}${detail ? ` — ${detail}` : ''}`);
  };

  const runDeadline = d.now() + d.timeouts.totalMs;
  const assertDeadline = (stage) => {
    if (latch.signalled) throw new RunnerError(`the isolated run was terminated by ${latch.reason} during ${stage}`);
    if (d.now() >= runDeadline) throw new RunnerError(`the isolated run exceeded its ${d.timeouts.totalMs}ms deadline during ${stage}`);
  };

  let failure = null;
  let cli = null;
  let cliTracked = null;
  let proxy = null;
  let webServer = null;
  const browsers = [];
  let summary = null;
  let transferId = null;

  const stopBrowser = async (browser, stage) => {
    if (!browser) return;
    try {
      await browser.close();
      const index = browsers.indexOf(browser);
      if (index >= 0) browsers.splice(index, 1);
      recordStage(stage, 'closed');
    } catch (error) {
      recordStage(stage, 'close-failed', error.message);
    }
  };

  // Every owned side effect is torn down through this single idempotent step, so
  // the crash handler below can reuse it without closing anything twice.
  let teardownPromise = null;
  const teardownOwned = () => {
    teardownPromise ??= (async () => {
      for (const browser of browsers.splice(0)) {
        try {
          await browser.close();
        } catch {
          // Best-effort double-close during failure teardown.
        }
      }
      try {
        await proxy?.close?.();
      } catch { /* reported via stage log */ }
      try {
        await webServer?.close?.();
      } catch { /* reported via stage log */ }
      const owned = cli;
      cli = null;
      if (owned) {
        try {
          await stopOwnedChild(owned, {
            tracked: cliTracked,
            sleep: d.sleep, now: d.now,
            termMs: d.timeouts.termMs, killMs: d.timeouts.killMs, pollMs: d.timeouts.pollMs,
            note,
          });
        } catch (error) {
          failure ??= error instanceof RunnerError ? error : new RunnerError(error.message);
        }
      }
    })();
    return teardownPromise;
  };

  const onUncaught = createCrashHandler({
    note,
    recordFailure: (error) => {
      failure ??= error instanceof RunnerError ? error : new RunnerError(`uncaught ${error?.message ?? error}`);
    },
    teardown: teardownOwned,
    exit: (code) => {
      if (typeof d.exitImpl === 'function') d.exitImpl(code);
      else process.exit(code);
    },
  });
  process.on('uncaughtException', onUncaught);
  process.on('unhandledRejection', onUncaught);

  try {
    recordStage('preflight', 'passed', `node ${node.version}, run ${paths.runId}`);
    // firebase-tools only accepts config sources inside the config file's own
    // directory, so link the repository sources into the run directory instead of
    // copying them (the cached emulator jar is linked the same way).
    d.symlink(join(FUNCTIONS_ROOT), join(paths.runDir, 'functions'));
    d.symlink(join(REPOSITORY_ROOT, 'firestore.rules'), join(paths.runDir, 'firestore.rules'));
    d.symlink(join(REPOSITORY_ROOT, 'firestore.indexes.json'), join(paths.runDir, 'firestore.indexes.json'));
    d.writeFile(join(paths.runDir, 'firebase.json'), `${JSON.stringify(buildFirebaseConfig({
      functionsSource: 'functions',
      firestoreRules: 'firestore.rules',
      firestoreIndexes: 'firestore.indexes.json',
    }), null, 2)}\n`, { mode: 0o600 });

    // Symlink (never copy, never download) the cached jar into the run-local
    // emulator cache so the CLI's downloadIfNecessary finds it and stops.
    const cacheJar = join(paths.runDir, 'emulator-cache', `cloud-firestore-emulator-v${FIRESTORE_JAR_VERSION}.jar`);
    d.mkdir(join(paths.runDir, 'emulator-cache'));
    d.symlink(jarPath, cacheJar);
    const { env: cliEnv } = buildRunEnvironment(env, { runId: paths.runId, runDir: paths.runDir });
    const cliArgs = buildFirebaseArgs(join(paths.runDir, 'firebase.json'));
    note(`spawning firebase CLI: ${cliArgs.join(' ')}`);
    cli = d.spawn(node.execPath, [cliPath, ...cliArgs], {
      cwd: paths.runDir,
      env: cliEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    cliTracked = trackChild(cli);
    pipeOutput(cli, logs.cli);
    // The runner's own bounded copy of the CLI output is the evidence of what the
    // emulator actually deployed (see assertFunctionsDeployed).
    let cliTail = '';
    const rememberCliOutput = (chunk) => { cliTail = `${cliTail}${String(chunk)}`.slice(-CLI_TAIL_CHARS); };
    cli.stdout?.on?.('data', rememberCliOutput);
    cli.stderr?.on?.('data', rememberCliOutput);

    await waitForCliReadiness({ child: cli, tracked: cliTracked, latch, d, note, rootPid: cli.pid });
    assertChildIsolation((await snapshotListeners(d)).rows, cli.pid, 'after CLI readiness');
    const deployedCallables = await waitForDeployedFunctions({ output: () => cliTail, d });
    recordStage('emulators', 'ready', `hub ${ISOLATED_HUB_PORT}, auth ${ISOLATED_AUTH_PORT}, firestore ${ISOLATED_FIRESTORE_PORT}, functions ${ISOLATED_FUNCTIONS_PORT}`);
    recordStage('functions', 'deployed', `${deployedCallables.length} callables from the linked source`);
    const rulesOutcome = await assertRulesEnforced({
      firestoreHost: `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`,
      projectId: PROJECT_ID,
      fetchImpl: d.fetchImpl,
    });
    recordStage('isolated-rules', 'enforced', `unauthenticated ${rulesOutcome.write} write and ${rulesOutcome.read} read`);
    assertDeadline('seed');

    const seedScript = generateProvisionScript({
      authAddress: `127.0.0.1:${ISOLATED_AUTH_PORT}`,
      firestoreAddress: `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`,
    });
    d.writeFile(join(paths.runDir, 'provision-notice-e2e.mjs'), seedScript, { mode: 0o600 });
    const seedReport = await runSeedChild({ d, env, runId: paths.runId, script: seedScript, node, note });
    recordStage('seed', 'created', `${seedReport.accounts.length} disposable identities, ${seedReport.recordsCreated} records`);
    assertDeadline('proxy');

    proxy = await proxyModule.startIsolatedBrowserProxy({
      routes: BROWSER_ROUTES,
      allowStaticCdn: true,
      onRequest: (meta) => logs.audit.write(`${JSON.stringify({
        kind: meta?.kind ?? null,
        authority: meta?.authority ?? null,
        targetPort: meta?.targetPort ?? null,
        method: meta?.method ?? null,
      })}\n`),
    });
    if (!proxy || !Number.isInteger(proxy.port) || typeof proxy.close !== 'function') {
      throw new RunnerError('startIsolatedBrowserProxy returned an unusable handle');
    }
    recordStage('proxy', 'listening', `ephemeral port ${proxy.port}`);
    webServer = await d.startWebServer({ webBuild: webBuildPath, port: APP_PORT });
    recordStage('app-web-server', 'listening', `127.0.0.1:${webServer.port} serving ${webBuildPath}`);
    assertDeadline('browser-stages');

    const appUrl = `http://127.0.0.1:${APP_PORT}/`;
    const evidenceDir = join(paths.runDir, 'evidence');
    d.mkdir(evidenceDir);
    const browserDeps = d.browser;

    // Seller 1 is signed in and waiting BEFORE the transfer so the notice
    // arrival is genuinely live, with no reload.
    const seller1 = await d.startBrowser({
      chromePath, profileDir: join(paths.runDir, 'profiles', 'seller1-live'), proxyPort: proxy.port, deps: browserDeps,
    });
    browsers.push(seller1);
    const seller1Page = await d.openPage(seller1, { url: appUrl, deps: browserDeps });
    await driveSellerBeforeTransfer(seller1Page, NOTICE_FIXTURE.accounts[1], { d, evidenceDir, stage: 'seller1-before' });
    recordStage('seller1-before', 'ready', 'seller1 signed in, inbox provably empty before the transfer');

    const admin = await d.startBrowser({
      chromePath, profileDir: join(paths.runDir, 'profiles', 'administrator'), proxyPort: proxy.port, deps: browserDeps,
    });
    browsers.push(admin);
    const adminPage = await d.openPage(admin, { url: appUrl, deps: browserDeps });
    transferId = await driveAdminTransfer(adminPage, NOTICE_FIXTURE, { d, evidenceDir, stage: 'admin-transfer' });
    recordStage('admin-transfer', 'accepted', `public UI reported a completed south->north transfer${transferId ? ` (${transferId})` : ''}`);
    await stopBrowser(admin, 'admin-browser-teardown');

    const readOutcome = await driveSellerMarkRead(seller1Page, { d, evidenceDir, stage: 'seller1-live-read' });
    recordStage('seller1-live-read', 'read', `live unread notice marked read in the already-open session${readOutcome.transferId ? ` (${readOutcome.transferId})` : ''}`);
    await stopBrowser(seller1, 'seller1-browser-teardown');
    assertDeadline('fresh-session-stages');

    const seller1Fresh = await d.startBrowser({
      chromePath, profileDir: join(paths.runDir, 'profiles', 'seller1-fresh'), proxyPort: proxy.port, deps: browserDeps,
    });
    browsers.push(seller1Fresh);
    const seller1FreshPage = await d.openPage(seller1Fresh, { url: appUrl, deps: browserDeps });
    await driveSellerFreshSessionRead(seller1FreshPage, NOTICE_FIXTURE.accounts[1], { d, evidenceDir, stage: 'seller1-fresh' });
    recordStage('seller1-fresh-session', 'retained', 'after dispose/recreate and re-login the notice stays read with history retained');
    await stopBrowser(seller1Fresh, 'seller1-fresh-browser-teardown');

    const seller2 = await d.startBrowser({
      chromePath, profileDir: join(paths.runDir, 'profiles', 'seller2'), proxyPort: proxy.port, deps: browserDeps,
    });
    browsers.push(seller2);
    const seller2Page = await d.openPage(seller2, { url: appUrl, deps: browserDeps });
    await driveSellerTwoIndependentUnread(seller2Page, NOTICE_FIXTURE.accounts[2], { d, evidenceDir, stage: 'seller2-unread' });
    recordStage('seller2-independent', 'unread', 'seller2 of the same destination branch is still independently unread');
    await stopBrowser(seller2, 'seller2-browser-teardown');

    summary = {
      label: 'notice-e2e-run',
      ok: true,
      runId: paths.runId,
      logDirectory: paths.runDir,
      transferId,
      stages,
    };
  } catch (error) {
    failure = error instanceof RunnerError ? error : new RunnerError(error?.message ?? String(error));
  } finally {
    await teardownOwned();
    process.removeListener('uncaughtException', onUncaught);
    process.removeListener('unhandledRejection', onUncaught);
    // Finalization faults must not replace the run's first failure or prevent
    // the remaining resources from getting their own cleanup attempt.
    const recordFinalizationFailure = (error) => {
      failure ??= error instanceof RunnerError ? error : new RunnerError(error?.message ?? String(error));
    };
    try {
      failure ??= await assertPortsReleased(d, { note });
      failure ??= assertFingerprintsUnchanged(d, before);
    } catch (error) {
      recordFinalizationFailure(error);
    }
    for (const sink of Object.values(logs)) {
      try {
        await sink.close?.();
      } catch (error) {
        recordFinalizationFailure(error);
      }
    }
    try {
      latch.unsubscribe();
    } catch (error) {
      recordFinalizationFailure(error);
    }
    try {
      d.writeFile(join(paths.runDir, 'result.json'), `${JSON.stringify({
        label: failure ? 'notice-e2e-run-failed' : 'notice-e2e-run',
        exit: failure ? 'failure' : 'success',
        runId: paths.runId,
        webBuild: { path: webBuildPath, sha256: webBuild.sourceTreeSha256 },
        transferId,
        stages,
        error: failure ? failure.message : null,
      }, null, 2)}\n`, { mode: 0o600 });
    } catch (error) {
      recordFinalizationFailure(error);
    }
    if (failure) throw failure;
  }
  return Object.freeze(summary);
}

// ---------------------------------------------------------------------------
// UI stage drivers (public semantics + CDP input only)
// ---------------------------------------------------------------------------

const CARD_UNREAD_PATTERN = /Traslado \S+, sin leer/;
const CARD_READ_PATTERN = /Traslado \S+, leído(?! )/;

async function stageGuard(page, stage, evidenceDir, work) {
  try {
    return await work();
  } catch (error) {
    const detail = error instanceof BrowserError ? error.message : String(error?.message ?? error);
    try {
      await page.screenshot(join(evidenceDir, `${stage}-failure.png`));
      await writeFileAsync(join(evidenceDir, `${stage}-failure.json`), `${JSON.stringify({
        stage,
        error: detail,
        console: page.consoleLog().slice(-100),
        semantics: await page.snapshotSemantics().catch(() => null),
      }, null, 2)}\n`, { mode: 0o600 });
    } catch {
      // Evidence is best-effort; the original failure still wins.
    }
    throw new RunnerError(`stage ${stage} failed: ${detail}`);
  }
}

async function loginThroughUi(page, account, d) {
  await page.enableSemantics({ timeoutMs: d.timeouts.semanticStepMs });
  await page.findSemantics({ role: 'input', label: 'Correo electrónico' }, { timeoutMs: d.timeouts.semanticStepMs });
  await page.clickSemantic({ role: 'input', label: 'Correo electrónico' });
  await page.typeText(account.email);
  await page.clickSemantic({ role: 'input', label: 'Contraseña' });
  await page.typeText(account.password);
  await page.clickSemantic({ label: 'Iniciar sesión' }, { timeoutMs: d.timeouts.semanticStepMs });
  await page.findSemantics({ labelIncludes: 'Cerrar sesión' }, { timeoutMs: d.timeouts.semanticStepMs });
}

async function openInbox(page, d) {
  await page.clickSemantic({ labelIncludes: 'Avisos de traslados' }, { timeoutMs: d.timeouts.semanticStepMs });
  await page.findSemantics({ labelIncludes: 'Cerrar bandeja de avisos' }, { timeoutMs: d.timeouts.semanticStepMs });
}

async function driveSellerBeforeTransfer(page, account, { d, evidenceDir, stage }) {
  await stageGuard(page, stage, evidenceDir, async () => {
    await loginThroughUi(page, account, d);
    await openInbox(page, d);
    await page.findSemantics({ label: 'Sin avisos de traslados' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.screenshot(join(evidenceDir, `${stage}.png`));
    await page.clickSemantic({ labelIncludes: 'Cerrar bandeja de avisos' }, { timeoutMs: d.timeouts.semanticStepMs });
  });
}

// The transfer screen renders its empty-catalog notices until the app's catalog
// arrives from Firestore, so a driver that acts earlier stalls on a lookup that
// can never succeed. Fail loudly with the app's own message instead.
async function waitForLocalCatalog(page, d) {
  const deadline = d.now() + d.timeouts.semanticStepMs;
  for (;;) {
    const blocked = catalogBlockingNotice((await page.snapshotSemantics()).map((node) => node.label));
    if (!blocked) return;
    if (d.now() >= deadline) {
      throw new BrowserError(`the local catalog never loaded: the app still shows ${JSON.stringify(blocked)}`);
    }
    await d.sleep(d.timeouts.pollMs);
  }
}

async function driveAdminTransfer(page, fixture, { d, evidenceDir, stage }) {
  return await stageGuard(page, stage, evidenceDir, async () => {
    await loginThroughUi(page, fixture.accounts[0], d);
    await page.clickSemantic({ labelIncludes: 'Traslados' }, { timeoutMs: d.timeouts.semanticStepMs });
    // The app loads its catalog from Firestore on its own schedule; acting before
    // it arrives leaves the form with no branches and no products at all.
    await waitForLocalCatalog(page, d);
    await page.findSemantics({ labelIncludes: 'Sucursal de origen' }, { timeoutMs: d.timeouts.semanticStepMs });
    // Source branch: the first open dropdown still shows the shared hint.
    await page.clickSemantic({ labelIncludes: 'Selecciona una sucursal' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.clickSemantic({ label: fixture.branches[1].name }, { timeoutMs: d.timeouts.semanticStepMs });
    // Destination: only the destination dropdown still shows the hint.
    await page.clickSemantic({ labelIncludes: 'Selecciona una sucursal' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.clickSemantic({ label: fixture.branches[0].name }, { timeoutMs: d.timeouts.semanticStepMs });
    // The form starts with one product row; its dropdown must be filled BEFORE
    // "Agregar producto", which stays disabled until the current row has a
    // product (administrator_transfer_form.dart).
    await page.clickSemantic({ labelIncludes: 'Selecciona un producto' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.clickSemantic({ label: fixture.products[0].data.name }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.clickSemantic({ role: 'input', labelIncludes: 'Cantidad' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.typeText(fixture.transfer.quantity);
    await page.screenshot(join(evidenceDir, `${stage}-draft.png`));
    await page.clickSemantic({ label: 'Registrar traslado' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.findSemantics({ labelIncludes: 'Confirmar traslado' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.screenshot(join(evidenceDir, `${stage}-confirm.png`));
    await page.clickSemantic({ label: 'Confirmar y enviar' }, { timeoutMs: d.timeouts.semanticStepMs });
    // The success banner hides its own text (ExcludeSemantics) and the uncertain
    // region's label contains the accepted one, so completion is classified from
    // every region the public UI exposes: an unconfirmed or failed transfer must
    // never be recorded as accepted.
    await page.findSemantics({ labelIncludes: 'Resultado del traslado' }, { timeoutMs: d.timeouts.semanticStepMs });
    const outcome = transferOutcome((await page.snapshotSemantics()).map((node) => node.label));
    if (outcome !== 'accepted') {
      throw new BrowserError(`the transfer did not complete: the public UI reports ${outcome}`);
    }
    await page.screenshot(join(evidenceDir, `${stage}-done.png`));
    return null;
  });
}

// The transfer screen renders these notices until the local catalog arrives; a
// driver that acts earlier stalls on a branch or product lookup that can never
// succeed (observed in a real run).
export const CATALOG_BLOCKING_NOTICES = Object.freeze([
  'Se necesitan al menos dos sucursales para registrar un traslado.',
  'No hay productos disponibles para trasladar.',
]);

export function catalogBlockingNotice(labels) {
  const rows = (labels ?? []).map((label) => String(label ?? ''));
  for (const notice of CATALOG_BLOCKING_NOTICES) {
    if (rows.some((label) => label.includes(notice))) return notice;
  }
  return null;
}

export function transferOutcome(labels) {
  const rows = (labels ?? []).map((label) => String(label ?? ''));
  const has = (needle) => rows.some((label) => label.includes(needle));
  if (has('Resultado del traslado sin confirmar')) return 'uncertain';
  if (has('Error del traslado')) return 'error';
  if (has('Resultado del traslado')) return 'accepted';
  return 'pending';
}

export function transferIdFromCardLabel(label) {  const match = /^Traslado (\S+),/.exec(String(label ?? ''));
  return match ? match[1] : null;
}

async function driveSellerMarkRead(page, { d, evidenceDir, stage }) {
  return await stageGuard(page, stage, evidenceDir, async () => {
    await openInbox(page, d);
    const card = await page.findSemantics({ labelRegex: CARD_UNREAD_PATTERN }, { timeoutMs: d.timeouts.semanticStepMs });
    // The card exposes its product line inside the card's own group label
    // ("Traslado <id>\nDemo Coffee: +1 piece"), so the product never appears as a
    // node of its own — measured on the real UI in run 18ea4e8d.
    await page.findSemantics(
      { labelIncludes: NOTICE_FIXTURE.products[0].data.name },
      { timeoutMs: d.timeouts.semanticStepMs },
    );
    await page.screenshot(join(evidenceDir, `${stage}-unread.png`));
    await page.clickSemantic({ label: 'Marcar como leído' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.findSemantics({ labelRegex: CARD_READ_PATTERN }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.findSemantics({ label: 'Sin leer', allowDisabled: true }, { timeoutMs: 1_000 })
      .then(() => { throw new BrowserError('an unread chip is still visible after marking read'); })
      .catch((error) => {
        if (String(error?.message ?? '').includes('unread chip')) throw error;
      });
    await page.screenshot(join(evidenceDir, `${stage}-read.png`));
    return { transferId: transferIdFromCardLabel(card.label) };
  });
}

async function driveSellerFreshSessionRead(page, account, { d, evidenceDir, stage }) {
  await stageGuard(page, stage, evidenceDir, async () => {
    await loginThroughUi(page, account, d);
    await openInbox(page, d);
    await page.findSemantics({ labelRegex: CARD_READ_PATTERN }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.findSemantics({ labelRegex: CARD_UNREAD_PATTERN, allowDisabled: true }, { timeoutMs: 1_000 })
      .then(() => { throw new BrowserError('the fresh session still shows an unread notice'); })
      .catch((error) => {
        if (String(error?.message ?? '').includes('fresh session')) throw error;
      });
    await page.screenshot(join(evidenceDir, `${stage}-retained.png`));
  });
}

async function driveSellerTwoIndependentUnread(page, account, { d, evidenceDir, stage }) {
  await stageGuard(page, stage, evidenceDir, async () => {
    await loginThroughUi(page, account, d);
    await openInbox(page, d);
    await page.findSemantics({ labelRegex: CARD_UNREAD_PATTERN }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.findSemantics({ label: 'Marcar como leído' }, { timeoutMs: d.timeouts.semanticStepMs });
    await page.screenshot(join(evidenceDir, `${stage}.png`));
    // Deliberately left unread: seller2's independent state is the assertion.
  });
}

// ---------------------------------------------------------------------------
// Readiness, teardown and isolation assertions
// ---------------------------------------------------------------------------

async function snapshotListeners(d) {
  let rows;
  try {
    rows = await d.readListeners();
  } catch (error) {
    throw new RunnerError(`the socket ownership probe (lsof) failed: ${error?.message ?? error}`);
  }
  d.lastListeners = rows;
  return Object.freeze({
    rows,
    fingerprint: JSON.stringify(portFingerprint(rows, DEMO_RESERVED_PORTS)),
  });
}

function assertChildIsolation(rows, rootPid, stage) {
  const owned = rows.filter((row) => row.pid === rootPid);
  const reserved = owned.find((row) => DEMO_RESERVED_PORTS.includes(row.port));
  if (reserved) {
    throw new RunnerError(`the owned CLI pid ${rootPid} listens on protected demo port ${reserved.port} (${stage})`);
  }
  const external = owned.find((row) => !['127.0.0.1', '[::1]', '::1', 'localhost'].includes(row.address));
  if (external) {
    throw new RunnerError(`the owned CLI pid ${rootPid} listens outside loopback at ${external.address}:${external.port} (${stage})`);
  }
}

async function waitForCliReadiness({ child, tracked, latch, d, note, rootPid }) {
  const requiredPorts = [ISOLATED_AUTH_PORT, ISOLATED_FIRESTORE_PORT, ISOLATED_FUNCTIONS_PORT, ISOLATED_HUB_PORT, FIRESTORE_WEBSOCKET_PORT];
  const deadline = d.now() + d.timeouts.cliReadyMs;
  for (;;) {
    if (tracked.exited) {
      throw new RunnerError(
        `the owned firebase CLI exited before readiness (code=${tracked.code}, signal=${tracked.signal})`,
      );
    }
    if (latch.signalled) throw new RunnerError(`the isolated run was terminated by ${latch.reason} before emulator readiness`);
    const rows = await snapshotListeners(d);
    const missing = requiredPorts.filter((port) => !rows.rows.some((row) => row.port === port));
    if (missing.length === 0) {
      const tree = await d.readProcessTree();
      const outside = [];
      for (const port of requiredPorts) {
        const pids = rows.rows.filter((row) => row.port === port).map((row) => row.pid);
        if (pids.some((pid) => !isDescendant(tree, rootPid, pid))) outside.push(`${port}(pid ${pids.join(',')})`);
      }
      if (outside.length > 0) {
        throw new RunnerError(`ports ${outside.join(', ')} are not owned by the spawned CLI process tree`);
      }
      note(`owned CLI pid ${rootPid} binds ${requiredPorts.join(', ')}`);
      return;
    }
    if (d.now() >= deadline) {
      throw new RunnerError(`the owned CLI did not bind ${missing.join(', ')} within ${d.timeouts.cliReadyMs}ms`);
    }
    await d.sleep(d.timeouts.pollMs);
  }
}

function isDescendant(tree, rootPid, pid) {
  let current = pid;
  for (let depth = 0; depth < 16 && current; depth += 1) {
    if (current === rootPid) return true;
    current = tree[current];
  }
  return false;
}

async function runSeedChild({ d, env, runId, script, node, note }) {
  const seedEnv = buildSeedEnvironment(env, { runId, runDir: join(NOTICE_RUN_ROOT, runId) });
  const child = d.spawn(node.execPath, ['--input-type=module', '--eval', script], {
    cwd: FUNCTIONS_ROOT,
    env: seedEnv,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const tracked = trackChild(child);
  let stdout = '';
  let stderr = '';
  child.stdout?.on('data', (chunk) => { stdout += String(chunk); });
  child.stderr?.on('data', (chunk) => { stderr += String(chunk); });
  const deadline = d.now() + d.timeouts.seedMs;
  while (!tracked.exited && d.now() < deadline) {
    await d.sleep(d.timeouts.pollMs);
  }
  if (!tracked.exited) {
    throw new RunnerError(`the disposable fixture provisioning child exceeded ${d.timeouts.seedMs}ms`);
  }
  const line = stdout.split('\n').find((candidate) => candidate.startsWith(PROVISION_OUTPUT_PREFIX));
  if (tracked.code !== 0 || !line) {
    note(`provisioning child failed (code=${tracked.code}): ${stderr.slice(-2_000)}`);
    throw new RunnerError(
      `the disposable fixture provisioning failed with exit code ${tracked.code}; see stages.log and the run folder`,
    );
  }
  const report = JSON.parse(line.slice(PROVISION_OUTPUT_PREFIX.length));
  if (!Array.isArray(report.accounts) || report.accounts.length !== 3 || report.recordsCreated <= 0) {
    throw new RunnerError(`unexpected provisioning report: ${JSON.stringify(report)}`);
  }
  return report;
}

async function assertPortsReleased(d, { note }) {
  const deadline = d.now() + d.timeouts.portReleaseMs;
  for (;;) {
    const rows = await snapshotListeners(d);
    const stillBound = OWNED_PORTS.filter((port) => rows.rows.some((row) => row.port === port));
    if (stillBound.length === 0) return null;
    if (d.now() >= deadline) {
      return new RunnerError(`owned port(s) ${stillBound.join(', ')} are still bound after teardown`);
    }
    note(`waiting for owned ports to release: ${stillBound.join(', ')}`);
    await d.sleep(d.timeouts.pollMs);
  }
}

function assertFingerprintsUnchanged(d, before) {
  const rows = d.lastListeners;
  if (!rows) return new RunnerError('no post-teardown listener snapshot was taken');
  const after = JSON.stringify(portFingerprint(rows, DEMO_RESERVED_PORTS));
  if (after !== before.fingerprint) {
    return new RunnerError(
      'protected demo listener fingerprints changed during the run; the isolated run cannot prove the current runtime is preserved',
    );
  }
  return null;
}

function assertChromeBinaryForRun(chromePath, d) {
  if (typeof chromePath !== 'string' || !isAbsolute(chromePath)) {
    throw new RunnerError(`the Chrome for Testing path must be absolute, received ${JSON.stringify(chromePath)}`);
  }
  if (!d.statFile(chromePath)) {
    throw new RunnerError(
      `the authorized project-local Chrome for Testing binary is missing at ${chromePath}; this run never downloads a browser`,
    );
  }
  return chromePath;
}

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

function resolveRunPaths(runId) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(runId)) {
    throw new RunnerError(`run id must be a fresh lowercase uuid, received ${JSON.stringify(runId)}`);
  }
  const runDir = join(NOTICE_RUN_ROOT, runId);
  if (!runDir.startsWith(`${NOTICE_RUN_ROOT}/`)) {
    throw new RunnerError(`run id must be a fresh lowercase uuid, received ${runId}`);
  }
  return Object.freeze({
    runId,
    runDir,
    cliLog: join(runDir, 'emulator-cli.log'),
  });
}

function assertPinnedNode({ execPath, version, home }) {
  const expected = pinnedNodePath({ home });
  if (execPath !== expected) {
    throw new RunnerError(`the isolated runner must be launched with the pinned node runtime at ${expected}`);
  }
  if (typeof version !== 'string' || !version.startsWith('v24.')) {
    throw new RunnerError(`the isolated runner requires the pinned Node 24 runtime, received ${version}`);
  }
  return Object.freeze({ execPath, version });
}

function createTerminateLatch(register) {
  const latch = { signalled: false, reason: null, unsubscribe: () => {} };
  const unsubscribe = register((reason) => {
    if (latch.signalled) return;
    latch.signalled = true;
    latch.reason = reason ?? 'a termination signal';
  });
  if (typeof unsubscribe === 'function') latch.unsubscribe = unsubscribe;
  return latch;
}

function pipeOutput(child, sink) {
  for (const stream of [child?.stdout, child?.stderr]) {
    if (stream && typeof stream.on === 'function') stream.on('data', (chunk) => sink.write(String(chunk)));
  }
}

const defaultNow = () => Date.now();
const defaultSleep = (ms) => new Promise((resolvePromise) => { setTimeout(resolvePromise, ms); });
const defaultReadFile = (path, encoding) => readFileSync(path, encoding);
const execFileAsync = promisify(nodeExecFile);

function defaultStatPath(path) {
  try {
    return statSync(path);
  } catch {
    return null;
  }
}

async function defaultReadListeners() {
  const lsof = defaultStatFile('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  const { stdout } = await execFileAsync(lsof, ['-nP', '-iTCP', '-sTCP:LISTEN'], {
    timeout: 10_000,
    maxBuffer: 8 * 1024 * 1024,
  });
  return parseListeners(stdout);
}

async function defaultReadProcessTree() {
  const { stdout } = await execFileAsync('/bin/ps', ['-axo', 'pid=,ppid='], { timeout: 10_000, maxBuffer: 4 * 1024 * 1024 });
  const tree = {};
  for (const line of stdout.split('\n')) {
    const columns = line.trim().split(/\s+/);
    if (columns.length !== 2) continue;
    const pid = Number(columns[0]);
    const ppid = Number(columns[1]);
    if (Number.isSafeInteger(pid) && Number.isSafeInteger(ppid)) tree[pid] = ppid;
  }
  return tree;
}

function defaultStatFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function defaultRegisterTerminate(handler) {
  const bound = ['SIGINT', 'SIGTERM'].map((signal) => ({ signal, fn: () => handler(signal) }));
  for (const { signal, fn } of bound) process.on(signal, fn);
  return () => {
    for (const { signal, fn } of bound) process.removeListener(signal, fn);
  };
}

function withDefaults(deps) {
  const merged = {
    spawn: nodeSpawn,
    readListeners: defaultReadListeners,
    readProcessTree: defaultReadProcessTree,
    statFile: defaultStatFile,
    readFile: defaultReadFile,
    writeFile: writeFileSync,
    symlink: (target, path) => {
      try {
        symlinkSync(target, path);
      } catch (error) {
        if (error?.code !== 'EEXIST') throw error;
      }
    },
    mkdir: (directory) => mkdirSync(directory, { recursive: true, mode: 0o700 }),
    openLog: defaultOpenLog,
    exitImpl: defaultExit,
    fetchImpl: typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : null,
    sleep: defaultSleep,
    now: defaultNow,
    runId: randomUUID(),
    argv: process.argv,
    registerTerminate: defaultRegisterTerminate,
    loadProxyModule: () => import(`./${PROXY_MODULE_RELATIVE}`),
    startWebServer: startOwnedWebServer,
    startBrowser: ({ chromePath, profileDir, proxyPort, deps: browserDeps }) => startIsolatedBrowser({
      chromePath, profileDir, proxyPort, deps: browserDeps,
    }),
    openPage: (browser, options) => openPage(browser, options),
    chromePath: null,
    browser: {},
    repoRoot: REPOSITORY_ROOT,
    ...deps,
  };
  return {
    ...merged,
    node: { ...resolveNodeInfo(), ...(deps.node ?? {}) },
    timeouts: { ...TIMEOUTS, ...(deps.timeouts ?? {}) },
  };
}

function defaultExit(code) {
  process.exit(code);
}

function defaultOpenLog(path) {
  const stream = createWriteStream(path, { flags: 'a', mode: 0o600 });
  return {
    path,
    write: (text) => stream.write(text),
    close: () => new Promise((resolvePromise) => stream.end(resolvePromise)),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.mode === 'help') {
    console.log(renderHelp());
    return;
  }
  if (args.mode === 'dry-run') {
    const plan = await buildDryRunPlan({ argv: process.argv.slice(2), env: process.env });
    console.log(JSON.stringify(plan, null, 2));
    return;
  }
  const summary = await runIsolatedNoticeE2E({ argv: process.argv.slice(2), env: process.env });
  console.log(JSON.stringify(summary, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[transfer-notice-e2e] ${error?.message ?? error}`);
    process.exitCode = 1;
  });
}
