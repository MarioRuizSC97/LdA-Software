/**
 * EA-02 — reproducible isolated Firestore emulator acceptance runner.
 *
 * Starts the already-cached standalone Firestore 1.22.0 jar on a dedicated
 * loopback port, waits until the bound socket is provably owned by the child it
 * spawned, runs `test/transfers.emulator.test.mjs` against that child only, and
 * stops just that retained handle. It never uses the Firebase CLI hub, never
 * downloads an emulator, never reads or writes the current runtime's ports or
 * data, and writes only under
 * `odd/runtime/inventory-transfers-emulator/<run-id>/`.
 *
 * Ownership is proven from `lsof` listener rows (pid + address + port), not from
 * a successful connect: a bound 8280 owned by another pid is a hard failure, and
 * reserved main ports plus loopback-only listening are audited for the owned pid.
 * Main-port fingerprints are snapshotted before startup and re-checked after
 * teardown, so a run that disturbed the current runtime cannot report success.
 *
 * Every external effect is injectable through `deps`, which is how
 * `test/transfers-isolated-runner.test.mjs` proves the fail-closed lifecycle with
 * controlled fake children. Importing this module has no side effects.
 */
import { execFile, spawn as nodeSpawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const MODULE_PATH = fileURLToPath(import.meta.url);
export const FUNCTIONS_ROOT = resolve(dirname(MODULE_PATH), '..');
export const REPO_ROOT = resolve(FUNCTIONS_ROOT, '..');
export const RUNTIME_ROOT = join(REPO_ROOT, 'odd', 'runtime', 'inventory-transfers-emulator');
export const TEST_TARGET = join(FUNCTIONS_ROOT, 'test', 'transfers.emulator.test.mjs');

export const PROJECT_ID = 'demo-lda-inventory';
export const ISOLATED_HOST = '127.0.0.1';
export const ISOLATED_PORT = 8280;
export const ISOLATED_ADDRESS = `${ISOLATED_HOST}:${ISOLATED_PORT}`;
export const RUN_MARKER = 'LDA_TRANSFERS_EMULATOR_RUN_ID';
export const EMULATOR_JAR = 'cloud-firestore-emulator-v1.22.0.jar';
export const PINNED_NODE_RELATIVE = join('.local', 'share', 'lda-node24', 'runtime', 'bin', 'node');
export const PINNED_NODE_MAJOR = 'v24.';

// Ports owned by the developer's current emulator runtime. This run must never
// bind one of them and must leave its listener fingerprint unchanged.
export const RESERVED_PORTS = Object.freeze([8080, 9099, 5001, 4400, 4500, 4000, 9299, 9499, 9150, 7357]);
const LOOPBACK_ADDRESSES = Object.freeze(['127.0.0.1', '[::1]', '::1', 'localhost']);
const RUN_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Any of these would silently re-route the suite away from the isolated emulator
// or hand it a real cloud identity, so their presence is a refusal, not a warning.
const FORBIDDEN_ENV_KEYS = Object.freeze([
  'FIREBASE_AUTH_EMULATOR_HOST',
  'FIREBASE_FIRESTORE_EMULATOR_ADDRESS',
  'FIRESTORE_PREFER_REST',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'GOOGLE_CLOUD_PROJECT',
  'CLOUDSDK_CORE_PROJECT',
  'GCLOUD_UNIVERSE_DOMAIN',
  'GOOGLE_CLOUD_UNIVERSE_DOMAIN',
  'GOOGLE_API_USE_MTLS_ENDPOINT',
  'GOOGLE_API_USE_CLIENT_CERTIFICATE',
  'JAVA_TOOL_OPTIONS',
  'JDK_JAVA_OPTIONS',
  '_JAVA_OPTIONS',
  'HTTP_PROXY', 'HTTPS_PROXY', 'GRPC_PROXY',
  'http_proxy', 'https_proxy', 'grpc_proxy',
]);

export const TIMEOUTS = Object.freeze({
  readyMs: 180_000,
  testsMs: 900_000,
  pollMs: 250,
  termMs: 10_000,
  killMs: 5_000,
});

export class RunnerError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RunnerError';
  }
}

export function resolveEmulatorJar({ home = process.env.HOME } = {}) {
  if (typeof home !== 'string' || home.length === 0) {
    throw new RunnerError('HOME is required to locate the cached Firestore emulator jar');
  }
  return join(home, '.cache', 'firebase', 'emulators', EMULATOR_JAR);
}

export function pinnedNodePath({ home = process.env.HOME } = {}) {
  if (typeof home !== 'string' || home.length === 0) {
    throw new RunnerError('HOME is required to locate the pinned node runtime');
  }
  return join(home, PINNED_NODE_RELATIVE);
}

// Tokenized flags, exactly the reviewed standalone invocation: no websocket or
// web-channel flag, and no Firebase CLI hub anywhere in the chain.
export function buildEmulatorCommand({ javaPath = 'java', jarPath = resolveEmulatorJar() } = {}) {
  if (typeof javaPath !== 'string' || javaPath.length === 0) {
    throw new RunnerError('a locally installed java executable is required');
  }
  if (typeof jarPath !== 'string' || !isAbsolute(jarPath)) {
    throw new RunnerError('the cached emulator jar must be an absolute path');
  }
  return Object.freeze([
    javaPath,
    '-Duser.language=en',
    '-jar', jarPath,
    '--host', ISOLATED_HOST,
    '--port', String(ISOLATED_PORT),
    '--project_id', PROJECT_ID,
    '--single_project_mode',
    '--single_project_mode_error',
  ]);
}

export function assertSafeEnvironment(env = process.env) {
  if (!env || typeof env !== 'object') throw new RunnerError('a process environment object is required');
  for (const key of FORBIDDEN_ENV_KEYS) {
    if (env[key] !== undefined) throw new RunnerError(`refusing the inherited ${key} override`);
  }
  if (env[RUN_MARKER] !== undefined) {
    throw new RunnerError(`refusing the caller-supplied ${RUN_MARKER} run marker; every run mints a fresh id`);
  }
  if (env.FIRESTORE_EMULATOR_HOST !== undefined && env.FIRESTORE_EMULATOR_HOST !== ISOLATED_ADDRESS) {
    throw new RunnerError(
      `refusing FIRESTORE_EMULATOR_HOST=${env.FIRESTORE_EMULATOR_HOST}; this run uses ${ISOLATED_ADDRESS} only`,
    );
  }
  if (env.GCLOUD_PROJECT !== undefined && env.GCLOUD_PROJECT !== PROJECT_ID) {
    throw new RunnerError(`refusing GCLOUD_PROJECT=${env.GCLOUD_PROJECT}; the isolated demo project is ${PROJECT_ID}`);
  }
  if (env.FUNCTIONS_EMULATOR !== undefined && env.FUNCTIONS_EMULATOR !== 'true') {
    throw new RunnerError(`refusing FUNCTIONS_EMULATOR=${env.FUNCTIONS_EMULATOR}`);
  }
  if (typeof env.HOME !== 'string' || env.HOME.length === 0) {
    throw new RunnerError('HOME is required to locate the cached emulator jar and pinned node runtime');
  }
  return Object.freeze({
    projectId: PROJECT_ID,
    host: ISOLATED_HOST,
    port: ISOLATED_PORT,
    address: ISOLATED_ADDRESS,
    home: env.HOME,
  });
}

export function resolveNodeInfo() {
  return Object.freeze({ execPath: process.execPath, version: process.version });
}

export function assertPinnedNode({ execPath, version, home = process.env.HOME } = {}) {
  const expected = pinnedNodePath({ home });
  if (typeof execPath !== 'string' || execPath !== expected) {
    throw new RunnerError(`the isolated runner must be launched with the pinned node runtime at ${expected}`);
  }
  if (typeof version !== 'string' || !version.startsWith(PINNED_NODE_MAJOR)) {
    throw new RunnerError(`the isolated runner requires the pinned Node 24 runtime, received ${version}`);
  }
  return Object.freeze({ execPath, version });
}

export function assertRunId(runId) {
  if (typeof runId !== 'string' || !RUN_ID_PATTERN.test(runId)) {
    throw new RunnerError(`run id must be a fresh lowercase uuid, received ${JSON.stringify(runId)}`);
  }
  return runId;
}

export function resolveRunPaths(runId) {
  const validated = assertRunId(runId);
  const directory = join(RUNTIME_ROOT, validated);
  if (!directory.startsWith(`${RUNTIME_ROOT}/`)) {
    throw new RunnerError(`run id must be a fresh lowercase uuid, received ${validated}`);
  }
  return Object.freeze({
    runId: validated,
    directory,
    emulatorLog: join(directory, 'emulator.log'),
    testsLog: join(directory, 'tests.log'),
  });
}

// Read-only listener table. Rows become `pid@address` per port so a replacement,
// restart or port steal shows up as a diff instead of a passing run.
export function parseListeners(text = '') {
  const rows = [];
  for (const line of String(text).split('\n')) {
    const columns = line.trim().split(/\s+/);
    // Real row: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME, where NAME is
    // `TCP <address>:<port> (LISTEN)` and spans the final three columns.
    if (columns.length < 9 || columns[0] === 'COMMAND') continue;
    if (columns.at(-1) !== '(LISTEN)' || columns.at(-3) !== 'TCP') continue;
    const socket = /^(.+):(\d+)$/.exec(columns.at(-2));
    const pid = Number(columns[1]);
    if (!socket || !Number.isSafeInteger(pid) || pid <= 0) continue;
    rows.push(Object.freeze({ command: columns[0], pid, address: socket[1], port: Number(socket[2]) }));
  }
  return rows;
}

export function portFingerprint(listeners, ports = RESERVED_PORTS) {
  const fingerprint = {};
  for (const port of ports) {
    fingerprint[port] = listeners
      .filter((entry) => entry.port === port)
      .map((entry) => `${entry.pid}@${entry.address}`)
      .sort();
  }
  return Object.freeze(fingerprint);
}

function isolatedListeners(listeners) {
  return listeners.filter((entry) => entry.port === ISOLATED_PORT);
}

function assertChildIsolation(listeners, pid, stage) {
  const owned = listeners.filter((entry) => entry.pid === pid);
  const reserved = owned.find((entry) => RESERVED_PORTS.includes(entry.port));
  if (reserved) {
    throw new RunnerError(
      `the owned emulator pid ${pid} listens on reserved main emulator port ${reserved.port} (${stage})`,
    );
  }
  const external = owned.find((entry) => !LOOPBACK_ADDRESSES.includes(entry.address));
  if (external) {
    throw new RunnerError(
      `the owned emulator pid ${pid} listens on ${external.address}:${external.port}, `
      + `outside the loopback interface (${stage})`,
    );
  }
}

// A child can exit before a listener is attached, so both recorded events and the
// live exitCode/signalCode fields describe "already dead".
export function trackChild(child) {
  const tracked = { exited: false, code: null, signal: null, error: null, promise: null };
  let resolveExit = () => {};
  tracked.promise = new Promise((resolvePromise) => { resolveExit = resolvePromise; });

  const settle = (code, signal) => {
    if (tracked.exited) return;
    tracked.exited = true;
    tracked.code = code ?? null;
    tracked.signal = signal ?? null;
    resolveExit({ code: tracked.code, signal: tracked.signal });
  };

  child.once('exit', (code, signal) => settle(code, signal));
  // close can arrive before a waiter is installed, or without any exit event.
  child.once('close', (code, signal) => settle(code ?? tracked.code, signal ?? tracked.signal));
  child.once('error', (error) => { tracked.error = error; settle(null, null); });

  if (child.exitCode !== null && child.exitCode !== undefined) settle(child.exitCode, null);
  else if (child.signalCode !== null && child.signalCode !== undefined) settle(null, child.signalCode);
  return tracked;
}

function childHasExited(child, tracked) {
  if (tracked?.exited) return true;
  return Boolean(
    (child?.exitCode !== null && child?.exitCode !== undefined)
    || (child?.signalCode !== null && child?.signalCode !== undefined),
  );
}

function killOwned(child, signal) {
  try {
    child.kill(signal);
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

// Bounded escalation addressed only to the retained handle: this runner never
// signals a pid it did not spawn.
export async function stopOwnedChild(child, {
  tracked,
  sleep = defaultSleep,
  now = defaultNow,
  termMs = TIMEOUTS.termMs,
  killMs = TIMEOUTS.killMs,
  pollMs = TIMEOUTS.pollMs,
  note = () => {},
} = {}) {
  if (childHasExited(child, tracked)) return Object.freeze({ stopped: false, escalated: false });

  note(`stopping owned pid ${child.pid} with SIGTERM`);
  let escalated = false;
  killOwned(child, 'SIGTERM');

  const termDeadline = now() + termMs;
  while (!childHasExited(child, tracked)) {
    if (now() >= termDeadline) {
      escalated = true;
      note(`owned pid ${child.pid} ignored SIGTERM; escalating to SIGKILL`);
      killOwned(child, 'SIGKILL');
      break;
    }
    await sleep(pollMs);
  }

  const killDeadline = now() + killMs;
  while (!childHasExited(child, tracked)) {
    if (now() >= killDeadline) {
      throw new RunnerError(`owned pid ${child.pid} survived SIGKILL; refusing to report a clean teardown`);
    }
    await sleep(pollMs);
  }
  return Object.freeze({ stopped: true, escalated });
}

export async function runIsolatedAcceptance({ env = process.env, deps = {} } = {}) {
  const d = withDefaults(deps);
  const config = assertSafeEnvironment(env);
  if (!Array.isArray(d.argv) || d.argv.length !== 2) {
    throw new RunnerError('the isolated runner accepts no command-line overrides');
  }
  const node = assertPinnedNode({ execPath: d.node.execPath, version: d.node.version, home: config.home });
  const paths = resolveRunPaths(d.runId);
  if (!d.statFile(node.execPath)) {
    throw new RunnerError(`the pinned node runtime is missing at ${node.execPath}`);
  }
  const jarPath = resolveEmulatorJar({ home: config.home });
  if (!d.statFile(jarPath)) {
    throw new RunnerError(
      `the cached Firestore 1.22.0 emulator jar is missing at ${jarPath}; this runner never downloads emulators`,
    );
  }
  const javaPath = d.which('java', env);
  if (!javaPath) {
    throw new RunnerError('no locally installed java executable was found; this runner never downloads emulators');
  }

  d.mkdir(paths.directory);
  const logs = { emulator: d.openLog(paths.emulatorLog), tests: d.openLog(paths.testsLog) };
  const note = (message) => logs.emulator.write(`[runner] ${message}\n`);
  const latch = createTerminateLatch(d.registerTerminate);

  let failure = null;
  let summary = null;
  let fingerprint = null;
  let emulator = null;
  let emulatorState = null;
  let tests = null;
  let testsState = null;

  try {
    const before = await probe(d);
    fingerprint = portFingerprint(before, RESERVED_PORTS);
    const occupied = isolatedListeners(before);
    if (occupied.length > 0) {
      throw new RunnerError(
        `port ${ISOLATED_PORT} is already occupied by pid ${occupied.map((entry) => entry.pid).join(', ')}; `
        + 'the isolated acceptance run refuses to start',
      );
    }
    note(`run ${paths.runId} preflight passed; starting the cached emulator jar`);

    const command = buildEmulatorCommand({ javaPath, jarPath });
    emulator = d.spawn(command[0], command.slice(1), {
      env: { ...env },
      cwd: FUNCTIONS_ROOT,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    emulatorState = trackChild(emulator);
    pipeOutput(emulator, logs.emulator);
    await waitForReadiness({ child: emulator, tracked: emulatorState, latch, d, note });

    assertChildIsolation(await probe(d), emulator.pid, 'after readiness');
    tests = d.spawn(node.execPath, ['--test', TEST_TARGET], {
      env: buildTestEnvironment(env, { runId: paths.runId }),
      cwd: FUNCTIONS_ROOT,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    testsState = trackChild(tests);
    pipeOutput(tests, logs.tests);
    note(`suite child ${tests.pid} started for run ${paths.runId}`);

    const outcome = await waitForExit({ tracked: testsState, latch, d, ms: d.timeouts.testsMs });
    if (outcome.signalled) throw new RunnerError(`the isolated run was terminated by ${latch.reason}`);
    if (outcome.timedOut) {
      throw new RunnerError(`the transfers emulator suite exceeded ${d.timeouts.testsMs}ms and was stopped`);
    }
    if (testsState.error) {
      throw new RunnerError(`the transfers emulator suite could not be started: ${testsState.error.message}`);
    }
    if (outcome.signal !== null) {
      throw new RunnerError(`the transfers emulator suite died from signal ${outcome.signal} before completing`);
    }
    note(`suite child exited with code ${outcome.code}`);
    summary = {
      ok: outcome.code === 0,
      runId: paths.runId,
      testsExitCode: outcome.code,
      terminated: null,
      logDirectory: paths.directory,
      emulatorPid: emulator.pid,
      suitePid: tests.pid,
    };
  } catch (error) {
    failure = error instanceof RunnerError ? error : new RunnerError(error?.message ?? String(error));
  } finally {
    const cleanup = [];
    const owned = [[tests, testsState, 'suite'], [emulator, emulatorState, 'emulator']];
    for (const [child, state, label] of owned) {
      if (!child) continue;
      try {
        await stopOwnedChild(child, {
          tracked: state,
          sleep: d.sleep,
          now: d.now,
          termMs: d.timeouts.termMs,
          killMs: d.timeouts.killMs,
          pollMs: d.timeouts.pollMs,
          note,
        });
      } catch (error) {
        cleanup.push(error);
        note(`teardown could not stop the owned ${label} pid ${child.pid}`);
      }
    }

    let reported = failure;
    if (fingerprint) {
      try {
        const after = await probe(d);
        const stale = isolatedListeners(after);
        if (stale.length > 0) {
          throw new RunnerError(
            `port ${ISOLATED_PORT} is still bound by pid ${stale.map((entry) => entry.pid).join(', ')} `
            + 'after owned teardown',
          );
        }
        if (JSON.stringify(portFingerprint(after, RESERVED_PORTS)) !== JSON.stringify(fingerprint)) {
          throw new RunnerError(
            'main emulator listener fingerprints changed; the isolated run cannot prove the current runtime '
            + 'is preserved',
          );
        }
      } catch (error) {
        reported ??= error instanceof RunnerError ? error : new RunnerError(error?.message ?? String(error));
      }
    }

    for (const sink of Object.values(logs)) await sink.close?.();
    latch.unsubscribe();
    if (reported) throw reported;
    if (cleanup.length > 0) throw cleanup[0];
  }

  return summary;
}

async function waitForReadiness({ child, tracked, latch, d, note }) {
  const limit = d.now() + d.timeouts.readyMs;
  for (;;) {
    if (childHasExited(child, tracked)) {
      throw new RunnerError(
        `the cached emulator exited before readiness (code=${tracked.code ?? child.exitCode}, `
        + `signal=${tracked.signal ?? child.signalCode})`,
      );
    }
    if (latch.signalled) throw new RunnerError(`the isolated run was terminated by ${latch.reason} before readiness`);
    const owners = isolatedListeners(await probe(d));
    if (owners.length > 0) {
      if (owners.length === 1 && owners[0].pid === child.pid) {
        note(`owned pid ${child.pid} is listening on ${ISOLATED_ADDRESS}`);
        return;
      }
      throw new RunnerError(
        `port ${ISOLATED_PORT} is bound by pid ${owners.map((entry) => entry.pid).join(', ')} `
        + `instead of the owned emulator pid ${child.pid}; refusing to write through an unowned socket`,
      );
    }
    if (d.now() >= limit) {
      throw new RunnerError(`the cached emulator did not bind ${ISOLATED_ADDRESS} within ${d.timeouts.readyMs}ms`);
    }
    await d.sleep(d.timeouts.pollMs);
  }
}

async function waitForExit({ tracked, latch, d, ms }) {
  const limit = d.now() + ms;
  for (;;) {
    if (tracked.exited) return { code: tracked.code, signal: tracked.signal };
    if (latch.signalled) return { signalled: true };
    if (d.now() >= limit) return { timedOut: true };
    await d.sleep(d.timeouts.pollMs);
  }
}

async function probe(d) {
  try {
    return await d.readListeners();
  } catch (error) {
    throw new RunnerError(`the socket ownership probe (lsof) failed: ${error?.message ?? String(error)}`);
  }
}

// The suite inherits the real process environment; only the four isolation values
// are written, so the Admin SDK cannot fall through to application default
// credentials or the developer's main emulator.
function buildTestEnvironment(env, { runId }) {
  return {
    ...env,
    GCLOUD_PROJECT: PROJECT_ID,
    FUNCTIONS_EMULATOR: 'true',
    FIRESTORE_EMULATOR_HOST: ISOLATED_ADDRESS,
    [RUN_MARKER]: runId,
  };
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

function defaultStatFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function defaultWhich(name, env = process.env) {
  for (const directory of String(env.PATH ?? '').split(':')) {
    if (!directory) continue;
    const candidate = join(directory, name);
    if (defaultStatFile(candidate)) return candidate;
  }
  return null;
}

async function defaultReadListeners() {
  const lsof = existsSync('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  const { stdout } = await execFileAsync(lsof, ['-nP', '-iTCP', '-sTCP:LISTEN'], {
    timeout: 10_000,
    maxBuffer: 8 * 1024 * 1024,
  });
  return parseListeners(stdout);
}

function defaultOpenLog(path) {
  const stream = createWriteStream(path, { flags: 'a', mode: 0o600 });
  return {
    path,
    write: (text) => stream.write(text),
    close: () => new Promise((resolvePromise) => stream.end(resolvePromise)),
  };
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
    statFile: defaultStatFile,
    which: defaultWhich,
    mkdir: (directory) => mkdirSync(directory, { recursive: true, mode: 0o700 }),
    openLog: defaultOpenLog,
    sleep: defaultSleep,
    now: defaultNow,
    runId: randomUUID(),
    argv: process.argv,
    registerTerminate: defaultRegisterTerminate,
    ...deps,
  };
  return {
    ...merged,
    node: { ...resolveNodeInfo(), ...(deps.node ?? {}) },
    timeouts: { ...TIMEOUTS, ...(deps.timeouts ?? {}) },
  };
}

async function main() {
  const summary = await runIsolatedAcceptance({ env: process.env });
  console.log(
    `[transfers-isolated] run=${summary.runId} ok=${summary.ok} suiteExit=${summary.testsExitCode} `
    + `logs=${summary.logDirectory}`,
  );
  if (!summary.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[transfers-isolated] ${error?.message ?? error}`);
    process.exitCode = 1;
  });
}
