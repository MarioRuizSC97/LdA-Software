/**
 * EA-02 — safety unit tests for the isolated transfers acceptance runner.
 *
 * Nothing here starts the cached Firestore jar, touches a live service or writes
 * to disk: every child process, network probe, filesystem operation, clock and
 * signal registration is an injected double. These tests pin the runner's
 * fail-closed lifecycle behaviour; they deliberately prove nothing about real
 * Firestore transfer semantics (that is `transfers.emulator.test.mjs`).
 */
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { isAbsolute } from 'node:path';
import test from 'node:test';

import {
  ISOLATED_ADDRESS,
  ISOLATED_PORT,
  PROJECT_ID,
  RESERVED_PORTS,
  RUNTIME_ROOT,
  RUN_MARKER,
  RunnerError,
  TEST_TARGET,
  assertPinnedNode,
  assertSafeEnvironment,
  buildEmulatorCommand,
  parseListeners,
  portFingerprint,
  resolveEmulatorJar,
  resolveNodeInfo,
  resolveRunPaths,
  runIsolatedAcceptance,
  stopOwnedChild,
  trackChild,
} from '../scripts/test-transfers-isolated.mjs';

const HOME = '/fake/home';
const PINNED_NODE = '/fake/home/.local/share/lda-node24/runtime/bin/node';
const JAVA = '/usr/bin/java';
const RUN_ID = '3f2a9c1b-4d6e-4a5f-8b7c-1d2e3f4a5b6c';
const EMULATOR_PID = 4100;
const SUITE_PID = 4200;
const SAFE_ENV = Object.freeze({ HOME, PATH: '/usr/bin:/bin' });
const HARNESS_TIMEOUTS = Object.freeze({
  readyMs: 8, testsMs: 8, pollMs: 1, termMs: 4, killMs: 4,
});

function mainListeners() {
  return [
    { pid: 50834, address: '127.0.0.1', port: 4400, command: 'node' },
    { pid: 50834, address: '[::1]', port: 4400, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 5001, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 9099, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 4500, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 4000, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 9299, command: 'node' },
    { pid: 50834, address: '127.0.0.1', port: 9499, command: 'node' },
    { pid: 50905, address: '127.0.0.1', port: 8080, command: 'java' },
    { pid: 50905, address: '127.0.0.1', port: 9150, command: 'java' },
  ];
}

function bind(state, pid, address, port) {
  state.listeners.push({ pid, address, port, command: 'java' });
}

function fakeChild({ pid, command }) {
  const child = Object.assign(new EventEmitter(), {
    pid,
    command,
    signals: [],
    resists: false,
    exitCode: null,
    signalCode: null,
    stdout: new EventEmitter(),
    stderr: new EventEmitter(),
    kill(signal = 'SIGTERM') {
      child.signals.push(signal);
      if (child.resists && signal !== 'SIGKILL') return false;
      child.signalCode = signal;
      child.emit('exit', null, signal);
      child.emit('close', null, signal);
      return true;
    },
    finish(code) {
      child.exitCode = code;
      child.emit('exit', code, null);
      child.emit('close', code, null);
    },
  });
  return child;
}

// Every external effect of the runner is replaced here. The fake listener table
// loses a pid's sockets when that child exits, exactly as a released bind would,
// so teardown assertions describe the owned child only. Sleep actions are keyed
// by the global sleep index: 0 is the first readiness poll, 1 the first suite
// poll, which keeps every scenario deterministic without wall-clock waits.
function harness({
  env = SAFE_ENV,
  listeners,
  sleepActions = {},
  statFile = () => true,
  which = () => JAVA,
  deps = {},
} = {}) {
  const state = {
    listeners: listeners ? listeners.slice() : mainListeners(),
    spawned: [],
    logs: new Map(),
    terminators: [],
    unsubscribed: 0,
    madeDirectories: [],
    clock: 0,
    sleeps: 0,
    probeFails: false,
    releasesSockets: true,
    javaChild: null,
    suiteChild: null,
  };

  const actions = {
    0: (current) => bind(current, EMULATOR_PID, '127.0.0.1', ISOLATED_PORT),
    1: (current) => current.suiteChild?.finish(0),
    ...sleepActions,
  };

  const spawn = (command, args, options) => {
    const child = fakeChild({ pid: command === JAVA ? EMULATOR_PID : SUITE_PID, command });
    child.on('exit', () => {
      if (!state.releasesSockets) return;
      state.listeners = state.listeners.filter((entry) => entry.pid !== child.pid);
    });
    state.spawned.push({ command, args, options, child });
    if (command === JAVA) state.javaChild = child;
    else state.suiteChild = child;
    return child;
  };

  const readListeners = async () => {
    if (state.probeFails) throw new Error('ownership probe refused');
    return state.listeners.map((entry) => ({ ...entry }));
  };

  const injected = {
    spawn,
    readListeners,
    statFile,
    which,
    mkdir: (directory) => state.madeDirectories.push(directory),
    openLog: (path) => {
      const sink = {
        path,
        chunks: [],
        closed: false,
        write(text) { sink.chunks.push(String(text)); },
        close() { sink.closed = true; },
      };
      state.logs.set(path, sink);
      return sink;
    },
    sleep: async () => {
      const step = state.sleeps;
      state.sleeps += 1;
      state.clock += 1;
      const action = actions[step];
      if (action) await action(state);
    },
    now: () => state.clock,
    runId: RUN_ID,
    argv: [PINNED_NODE, 'scripts/test-transfers-isolated.mjs'],
    node: { execPath: PINNED_NODE, version: 'v24.21.0' },
    timeouts: HARNESS_TIMEOUTS,
    registerTerminate: (handler) => {
      state.terminators.push(handler);
      return () => { state.unsubscribed += 1; };
    },
    ...deps,
  };

  return { state, options: { env, deps: injected } };
}

test('pins the cached standalone Firestore 1.22.0 jar command', () => {
  const jarPath = resolveEmulatorJar({ home: HOME });
  assert.equal(jarPath, '/fake/home/.cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar');

  const command = buildEmulatorCommand({ javaPath: JAVA, jarPath });
  assert.deepEqual(command, [
    JAVA,
    '-Duser.language=en',
    '-jar',
    jarPath,
    '--host', '127.0.0.1',
    '--port', '8280',
    '--project_id', 'demo-lda-inventory',
    '--single_project_mode',
    '--single_project_mode_error',
  ]);
  assert.equal(Object.isFrozen(command), true);
  const joined = command.join(' ');
  assert.equal(joined.includes('websocket'), false);
  assert.equal(joined.includes('webchannel'), false);
  assert.equal(joined.includes('8080'), false);
});

test('refuses an unsafe or inherited emulator configuration instead of honoring 8080', () => {
  const config = assertSafeEnvironment(SAFE_ENV);
  assert.deepEqual(config, {
    projectId: PROJECT_ID,
    host: '127.0.0.1',
    port: ISOLATED_PORT,
    address: ISOLATED_ADDRESS,
    home: HOME,
  });
  assert.equal(Object.isFrozen(config), true);

  const refusals = [
    ['the main Firestore port', { ...SAFE_ENV, FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' }],
    ['a non-loopback host', { ...SAFE_ENV, FIRESTORE_EMULATOR_HOST: '0.0.0.0:8280' }],
    ['another project', { ...SAFE_ENV, GCLOUD_PROJECT: 'production-lda' }],
    ['a non-emulator functions flag', { ...SAFE_ENV, FUNCTIONS_EMULATOR: '1' }],
    ['a caller-supplied run marker', { ...SAFE_ENV, [RUN_MARKER]: RUN_ID }],
    ['ambient ADC', { ...SAFE_ENV, GOOGLE_APPLICATION_CREDENTIALS: '/keys/prod.json' }],
    ['the Auth emulator', { ...SAFE_ENV, FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099' }],
    ['an SDK address override', { ...SAFE_ENV, FIREBASE_FIRESTORE_EMULATOR_ADDRESS: '127.0.0.1:8080' }],
    ['a JVM option injection', { ...SAFE_ENV, JAVA_TOOL_OPTIONS: '-Dsomething' }],
    ['an outbound proxy', { ...SAFE_ENV, HTTPS_PROXY: 'http://127.0.0.1:8888' }],
    ['no home directory', { PATH: '/usr/bin' }],
  ];
  for (const [reason, env] of refusals) {
    assert.throws(() => assertSafeEnvironment(env), { name: 'RunnerError' }, `must refuse ${reason}`);
  }

  // The exact isolated address is the only tolerated inheritance.
  assert.equal(
    assertSafeEnvironment({ ...SAFE_ENV, FIRESTORE_EMULATOR_HOST: ISOLATED_ADDRESS }).address,
    ISOLATED_ADDRESS,
  );
});

test('requires the pinned node runtime and a fresh run marker', async () => {
  assert.deepEqual(resolveNodeInfo(), { execPath: process.execPath, version: process.version });
  assert.deepEqual(
    assertPinnedNode({ execPath: PINNED_NODE, version: 'v24.21.0', home: HOME }),
    { execPath: PINNED_NODE, version: 'v24.21.0' },
  );
  assert.throws(
    () => assertPinnedNode({ execPath: '/opt/homebrew/bin/node', version: 'v24.21.0', home: HOME }),
    { name: 'RunnerError', message: /pinned node runtime/ },
  );
  assert.throws(
    () => assertPinnedNode({ execPath: PINNED_NODE, version: 'v26.1.0', home: HOME }),
    { name: 'RunnerError', message: /Node 24/ },
  );

  await assertRejectsFrom(harness({ env: { ...SAFE_ENV, [RUN_MARKER]: RUN_ID } }), /run marker/);
  await assertRejectsFrom(harness({ deps: { runId: 'not-a-uuid' } }), /run id/);
  await assertRejectsFrom(
    harness({ deps: { argv: [PINNED_NODE, 'scripts/test-transfers-isolated.mjs', '--port', '8080'] } }),
    /overrides/,
  );
});

test('keeps runtime artifacts under the approved isolated root only', () => {
  assert.equal(isAbsolute(RUNTIME_ROOT), true);
  assert.equal(RUNTIME_ROOT.endsWith('odd/runtime/inventory-transfers-emulator'), true);
  assert.equal(isAbsolute(TEST_TARGET), true);
  assert.equal(TEST_TARGET.endsWith('test/transfers.emulator.test.mjs'), true);

  const paths = resolveRunPaths(RUN_ID);
  assert.equal(paths.runId, RUN_ID);
  assert.equal(paths.directory, `${RUNTIME_ROOT}/${RUN_ID}`);
  assert.equal(paths.emulatorLog, `${RUNTIME_ROOT}/${RUN_ID}/emulator.log`);
  assert.equal(paths.testsLog, `${RUNTIME_ROOT}/${RUN_ID}/tests.log`);

  for (const forged of ['../../evil', RUN_ID.toUpperCase(), `${RUN_ID}/extra`, '']) {
    assert.throws(() => resolveRunPaths(forged), { name: 'RunnerError', message: /run id/ }, `must refuse ${forged}`);
  }
});

async function assertRejectsFrom(scenario, message) {
  await assert.rejects(() => runIsolatedAcceptance(scenario.options), { name: 'RunnerError', message });
}

test('reads listener ownership from the lsof table without touching endpoints', () => {
  const table = [
    'COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME',
    'node    50834 user   23u  IPv4 0xfc77      0t0  TCP 127.0.0.1:5001 (LISTEN)',
    'java    50905 user  168u  IPv6 0x4451      0t0  TCP 127.0.0.1:8080 (LISTEN)',
    'node    50834 user   21u  IPv6 0xeb9e      0t0  TCP [::1]:4000 (LISTEN)',
    'rapportd 954 user   11u  IPv4 0xb65d      0t0  TCP *:58946 (LISTEN)',
    'node    50834 user   24u  IPv4 0x1111      0t0  TCP 127.0.0.1:5001',
    'bad      abc user    1u  IPv4 0x2222      0t0  TCP 127.0.0.1:1 (LISTEN)',
  ].join('\n');

  assert.deepEqual(parseListeners(table), [
    { command: 'node', pid: 50834, address: '127.0.0.1', port: 5001 },
    { command: 'java', pid: 50905, address: '127.0.0.1', port: 8080 },
    { command: 'node', pid: 50834, address: '[::1]', port: 4000 },
    { command: 'rapportd', pid: 954, address: '*', port: 58946 },
  ]);

  assert.deepEqual(portFingerprint(parseListeners(table), [8080, 5001, 4000, 9099]), {
    4000: ['50834@[::1]'],
    5001: ['50834@127.0.0.1'],
    8080: ['50905@127.0.0.1'],
    9099: [],
  });
  assert.equal(RESERVED_PORTS.includes(ISOLATED_PORT), false);
});

test('refuses to start while the isolated port is already occupied', async () => {
  const occupied = harness({
    listeners: [...mainListeners(), { pid: 9999, address: '127.0.0.1', port: ISOLATED_PORT, command: 'java' }],
  });

  await assert.rejects(
    () => runIsolatedAcceptance(occupied.options),
    { name: 'RunnerError', message: /port 8280 is already occupied by pid 9999/ },
  );
  assert.deepEqual(occupied.state.spawned, []);
  assert.equal(occupied.state.unsubscribed, 1);
});

test('fails closed when the cached jar or java is missing and never downloads', async () => {
  const noJar = harness({ statFile: (path) => !path.endsWith('.jar') });
  await assert.rejects(
    () => runIsolatedAcceptance(noJar.options),
    { name: 'RunnerError', message: /cached Firestore 1\.22\.0 emulator jar is missing/ },
  );
  assert.deepEqual(noJar.state.spawned, []);
  assert.deepEqual(noJar.state.madeDirectories, []);

  const noJava = harness({ which: () => null });
  await assert.rejects(
    () => runIsolatedAcceptance(noJava.options),
    { name: 'RunnerError', message: /java executable[\s\S]*never downloads/i },
  );
  assert.deepEqual(noJava.state.spawned, []);
});

test('refuses a bound isolated port that the owned child does not own', async () => {
  const raced = harness({
    sleepActions: { 0: (state) => bind(state, 7777, '127.0.0.1', ISOLATED_PORT), 1: () => {} },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(raced.options),
    { name: 'RunnerError', message: /pid 7777 instead of the owned emulator pid/ },
  );
  assert.deepEqual(raced.state.javaChild.signals, ['SIGTERM']);
  assert.equal(raced.state.suiteChild, null);
  assert.equal(raced.state.spawned.length, 1);
  assert.equal(raced.state.listeners.some((entry) => entry.pid === EMULATOR_PID), false);
  assert.equal(raced.state.listeners.some((entry) => entry.pid === 7777), true);
});

test('reports an early emulator exit instead of hanging', async () => {
  const dead = harness();
  const originalSpawn = dead.options.deps.spawn;
  let exitedChild = null;
  dead.options.deps.spawn = (command, args, options) => {
    const child = originalSpawn(command, args, options);
    if (command === JAVA) { child.finish(3); exitedChild = child; }
    return child;
  };

  await assert.rejects(
    () => runIsolatedAcceptance(dead.options),
    { name: 'RunnerError', message: /emulator exited before readiness \(code=3/ },
  );
  assert.deepEqual(exitedChild.signals, []);
  assert.equal(dead.state.suiteChild, null);
});

test('bounds readiness and stops the owned child when the emulator never binds', async () => {
  const never = harness({ sleepActions: { 0: () => {}, 1: () => {} } });

  await assert.rejects(
    () => runIsolatedAcceptance(never.options),
    { name: 'RunnerError', message: /did not bind 127\.0\.0\.1:8280 within 8ms/ },
  );
  assert.deepEqual(never.state.javaChild.signals, ['SIGTERM']);
  assert.equal(never.state.suiteChild, null);
});

test('refuses an owned child that takes a reserved main port', async () => {
  const reserved = harness({
    sleepActions: {
      0: (state) => {
        bind(state, EMULATOR_PID, '127.0.0.1', ISOLATED_PORT);
        bind(state, EMULATOR_PID, '127.0.0.1', 4400);
      },
      1: () => {},
    },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(reserved.options),
    { name: 'RunnerError', message: /reserved main emulator port 4400/ },
  );
  assert.deepEqual(reserved.state.javaChild.signals, ['SIGTERM']);
  assert.equal(reserved.state.suiteChild, null);
});

test('refuses an owned child that listens beyond loopback', async () => {
  const wildcard = harness({
    sleepActions: { 0: (state) => bind(state, EMULATOR_PID, '*', ISOLATED_PORT), 1: () => {} },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(wildcard.options),
    { name: 'RunnerError', message: /outside the loopback interface/ },
  );
  assert.deepEqual(wildcard.state.javaChild.signals, ['SIGTERM']);
});

test('escalates SIGTERM to SIGKILL only while the owned child is alive', async () => {
  let clock = 0;
  const timing = {
    sleep: async () => { clock += 1; },
    now: () => clock,
    termMs: 3,
    killMs: 3,
    pollMs: 1,
  };

  const stubborn = fakeChild({ pid: 4300, command: JAVA });
  stubborn.resists = true;
  const escalated = await stopOwnedChild(stubborn, { tracked: trackChild(stubborn), ...timing });
  assert.deepEqual(stubborn.signals, ['SIGTERM', 'SIGKILL']);
  assert.deepEqual(escalated, { stopped: true, escalated: true });

  const alreadyGone = fakeChild({ pid: 4301, command: JAVA });
  alreadyGone.finish(0);
  const raced = await stopOwnedChild(alreadyGone, {
    tracked: trackChild(alreadyGone),
    ...timing,
    termMs: 0,
    killMs: 0,
  });
  assert.deepEqual(alreadyGone.signals, []);
  assert.deepEqual(raced, { stopped: false, escalated: false });
});

test('stops escalating when the owned child cannot be killed and reports it', async () => {
  let clock = 0;
  const ghost = fakeChild({ pid: 4302, command: JAVA });
  ghost.kill = (signal) => { ghost.signals.push(signal); return false; };
  ghost.resists = true;

  await assert.rejects(
    () => stopOwnedChild(ghost, {
      tracked: trackChild(ghost),
      sleep: async () => { clock += 1; },
      now: () => clock,
      termMs: 2,
      killMs: 2,
      pollMs: 1,
    }),
    { name: 'RunnerError', message: /survived SIGKILL/ },
  );
  assert.deepEqual(ghost.signals, ['SIGTERM', 'SIGKILL']);
});

test('runs the suite isolated and stops only the owned child on success', async () => {
  const good = harness({
    sleepActions: {
      0: (state) => {
        bind(state, EMULATOR_PID, '127.0.0.1', ISOLATED_PORT);
        bind(state, EMULATOR_PID, '127.0.0.1', 51053);
        state.javaChild.stdout.emit('data', 'Dev Server listening on port 8280\n');
      },
    },
  });

  const summary = await runIsolatedAcceptance(good.options);
  const [emulator, suite] = good.state.spawned;

  assert.equal(summary.ok, true);
  assert.equal(summary.runId, RUN_ID);
  assert.equal(summary.testsExitCode, 0);
  assert.equal(summary.terminated, null);
  assert.equal(summary.logDirectory, resolveRunPaths(RUN_ID).directory);

  assert.equal(good.state.madeDirectories.length, 1);
  assert.equal(good.state.madeDirectories[0], resolveRunPaths(RUN_ID).directory);
  assert.equal(emulator.command, JAVA);
  assert.deepEqual(emulator.args, buildEmulatorCommand({ javaPath: JAVA, jarPath: resolveEmulatorJar({ home: HOME }) }).slice(1));
  assert.equal(emulator.options.env.FIRESTORE_EMULATOR_HOST, undefined);
  assert.equal(emulator.options.env.GCLOUD_PROJECT, undefined);

  assert.equal(suite.command, PINNED_NODE);
  assert.deepEqual(suite.args, ['--test', TEST_TARGET]);
  assert.equal(suite.options.env.GCLOUD_PROJECT, PROJECT_ID);
  assert.equal(suite.options.env.FUNCTIONS_EMULATOR, 'true');
  assert.equal(suite.options.env.FIRESTORE_EMULATOR_HOST, ISOLATED_ADDRESS);
  assert.equal(suite.options.env[RUN_MARKER], RUN_ID);
  assert.equal(suite.options.env.HOME, HOME);
  assert.equal(suite.options.env.FIREBASE_AUTH_EMULATOR_HOST, undefined);
  assert.deepEqual(suite.options.stdio, ['ignore', 'pipe', 'pipe']);

  assert.deepEqual(emulator.child.signals, ['SIGTERM']);
  assert.deepEqual(suite.child.signals, []);
  assert.equal(good.state.listeners.some((entry) => entry.port === ISOLATED_PORT), false);
  assert.deepEqual(
    portFingerprint(good.state.listeners, RESERVED_PORTS),
    portFingerprint(mainListeners(), RESERVED_PORTS),
  );
  assert.equal(good.state.unsubscribed, 1);

  const emulatorLog = good.state.logs.get(resolveRunPaths(RUN_ID).emulatorLog);
  assert.equal(emulatorLog.closed, true);
  assert.equal(emulatorLog.chunks.join('').includes('Dev Server listening on port 8280'), true);
  assert.equal(emulatorLog.chunks.join('').includes(HOME), false);
  assert.equal(good.state.logs.get(resolveRunPaths(RUN_ID).testsLog).closed, true);
});

test('reports a failing suite but still tears the owned child down', async () => {
  const failing = harness({ sleepActions: { 1: (state) => state.suiteChild.finish(1) } });

  const summary = await runIsolatedAcceptance(failing.options);
  assert.equal(summary.ok, false);
  assert.equal(summary.testsExitCode, 1);
  assert.deepEqual(failing.state.javaChild.signals, ['SIGTERM']);
  assert.equal(failing.state.listeners.some((entry) => entry.port === ISOLATED_PORT), false);
});

test('bounds the suite child with an owned timeout and still stops the emulator', async () => {
  const stalled = harness({ sleepActions: { 1: () => {} } });

  await assert.rejects(
    () => runIsolatedAcceptance(stalled.options),
    { name: 'RunnerError', message: /suite exceeded 8ms and was stopped/ },
  );
  assert.deepEqual(stalled.state.suiteChild.signals, ['SIGTERM']);
  assert.deepEqual(stalled.state.javaChild.signals, ['SIGTERM']);
  assert.equal(stalled.state.listeners.some((entry) => entry.port === ISOLATED_PORT), false);
});

test('stops the owned children when a termination signal arrives', async () => {
  const signalled = harness({
    sleepActions: { 1: (state) => state.terminators[0]('SIGINT') },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(signalled.options),
    { name: 'RunnerError', message: /terminated by SIGINT/ },
  );
  assert.deepEqual(signalled.state.suiteChild.signals, ['SIGTERM']);
  assert.deepEqual(signalled.state.javaChild.signals, ['SIGTERM']);
  assert.equal(signalled.state.unsubscribed, 1);
});

test('fails teardown when main listener fingerprints are not preserved', async () => {
  const shifted = harness({
    sleepActions: {
      1: (state) => {
        state.suiteChild.finish(0);
        state.listeners = state.listeners.filter((entry) => entry.pid !== 50834);
      },
    },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(shifted.options),
    { name: 'RunnerError', message: /main emulator listener fingerprints changed/ },
  );
  assert.deepEqual(shifted.state.javaChild.signals, ['SIGTERM']);
});

test('reports an isolated port that stays bound after owned teardown', async () => {
  const stillBound = harness({
    sleepActions: {
      1: (state) => {
        state.releasesSockets = false;
        state.suiteChild.finish(0);
      },
    },
  });

  await assert.rejects(
    () => runIsolatedAcceptance(stillBound.options),
    { name: 'RunnerError', message: /port 8280 is still bound by pid 4100 after owned teardown/ },
  );
  assert.deepEqual(stillBound.state.javaChild.signals, ['SIGTERM']);
});

test('treats an unusable ownership probe as a hard failure', async () => {
  const probeFails = harness();
  probeFails.state.probeFails = true;

  await assert.rejects(
    () => runIsolatedAcceptance(probeFails.options),
    { name: 'RunnerError', message: /ownership probe .* failed/ },
  );
  assert.deepEqual(probeFails.state.spawned, []);
});
