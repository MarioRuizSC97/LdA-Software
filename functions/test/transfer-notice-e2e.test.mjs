/**
 * EI-03 — safety and lifecycle tests for the isolated destination-notice E2E
 * harness (writer B surfaces only).
 *
 * Nothing here starts emulators, spawns Chrome, imports the real Admin SDK or
 * touches the developer's demo runtime: every child process, listener probe,
 * proxy module, browser page, filesystem write and clock is an injected double.
 * These tests pin the fail-closed lifecycle, the frozen isolation contract and
 * the `--help`/`--dry-run`/`--run` CLI semantics; they deliberately prove
 * nothing about real browser or emulator behaviour (the parent owns the first
 * real execution after the seam check).
 */
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

import {
  DEFAULT_CHROME_PATH,
  BROWSER_TIMEOUTS,
  BrowserError,
  CdpConnection,
  createPage,
  buildChromeArgs,
  openPage,
  parseDevToolsActivePort,
  SEMANTIC_SNAPSHOT_JS,
  SEMANTICS_ACTIVE_JS,
  SEMANTICS_PLACEHOLDER_CLICK_JS,
  startIsolatedBrowser,
} from '../scripts/transfer-notice-e2e-browser.mjs';
import {
  APP_PORT,
  BROWSER_ROUTES,
  FIRESTORE_WEBSOCKET_PORT,
  ISOLATED_AUTH_PORT,
  ISOLATED_FIRESTORE_PORT,
  ISOLATED_FUNCTIONS_PORT,
  ISOLATED_HUB_PORT,
  NOTICE_FIXTURE,
  OWNED_PORTS,
  PROJECT_ID,
  PROVISION_OUTPUT_PREFIX,
  RUN_MARKER,
  USAGE,
  assertRulesEnforced,
  assertRunEnvironment,
  assertWebBuild,
  assertFunctionsDeployed,
  buildDryRunPlan,
  buildFirebaseArgs,
  buildFirebaseConfig,
  buildRunEnvironment,
  buildSeedEnvironment,
  buildSeedRecords,
  catalogBlockingNotice,
  createCrashHandler,
  functionsLoadFailure,
  generateProvisionScript,
  loadedFunctionNames,
  parseArgs,
  renderHelp,
  resolveWebBuildPath,
  runIsolatedNoticeE2E,
  startOwnedWebServer,
  transferIdFromCardLabel,
  transferOutcome,
} from '../scripts/transfer-notice-e2e.mjs';
import { RESERVED_PORTS as DEMO_RESERVED_PORTS, pinnedNodePath } from '../scripts/test-transfers-isolated.mjs';

const HOME = '/fake/home';
const PINNED_NODE = pinnedNodePath({ home: HOME });
const RUN_ID = '9e3a7c1b-4d6e-4a5f-8b7c-1d2e3f4a5b6c';
const CLI_PID = 8100;
const FIRESTORE_PID = 8101;
const PROXY_PORT = 40001;
const SAFE_ENV = Object.freeze({ HOME, PATH: '/usr/bin:/bin' });
const WEB_BUILD = '/fake/repo/.dart_tool/notice-e2e-build/build-1/web';
const MANIFEST = JSON.stringify({
  dartDefines: { LDA_LOCAL_EMULATORS: 'true' },
  buildExitCode: 0,
  mode: 'release',
  webResourcesCdn: false,
  sourceTreeSha256: 'abc',
});

// ---------------------------------------------------------------------------
// CLI surface
// ---------------------------------------------------------------------------

test('parseArgs accepts the three documented modes', () => {
  assert.deepEqual(parseArgs(['--help']), { mode: 'help', webBuild: null });
  assert.deepEqual(parseArgs(['--dry-run']), { mode: 'dry-run', webBuild: null });
  assert.deepEqual(parseArgs(['--run', '--web-build', 'x']), { mode: 'run', webBuild: 'x' });
  assert.deepEqual(parseArgs(['--run', '--web-build=x']), { mode: 'run', webBuild: 'x' });
});

test('parseArgs refuses ambiguity and omission', () => {
  assert.throws(() => parseArgs([]), /choose an explicit mode/);
  assert.throws(() => parseArgs(['--dry-run', '--run']), /choose exactly one mode/);
  assert.throws(() => parseArgs(['--run']), /--run requires --web-build/);
  assert.throws(() => parseArgs(['--frobnicate']), /unknown argument/);
  assert.throws(() => parseArgs(['--web-build']), /--web-build requires/);
  assert.throws(() => parseArgs(['--web-build', '--run']), /--web-build requires/);
});

test('renderHelp documents the frozen contract without needing services', () => {
  const help = renderHelp();
  for (const fragment of ['--help', '--dry-run', '--run', '--web-build', '9099->8299', '8080->8280', '5001->5201', '7358->7358', 'Demo ports']) {
    assert.ok(help.includes(fragment), `help must mention ${fragment}`);
  }
  assert.equal(USAGE, renderHelp());
});

test('resolveWebBuildPath stays repo-contained and rejects the stale default build', () => {
  const repo = '/fake/repo';
  assert.equal(
    resolveWebBuildPath('.dart_tool/notice-e2e-build/x/web', { repoRoot: repo }),
    `${repo}/.dart_tool/notice-e2e-build/x/web`,
  );
  assert.equal(
    resolveWebBuildPath(`${repo}/.dart_tool/notice-e2e-build/x/web`, { repoRoot: repo }),
    `${repo}/.dart_tool/notice-e2e-build/x/web`,
  );
  assert.throws(() => resolveWebBuildPath('../outside', { repoRoot: repo }), /must stay inside the repository/);
  assert.throws(() => resolveWebBuildPath('/etc/passwd', { repoRoot: repo }), /must stay inside the repository/);
  assert.throws(() => resolveWebBuildPath('build/web', { repoRoot: repo }), /default build\/web/);
  assert.throws(() => resolveWebBuildPath('', { repoRoot: repo }), /--web-build requires/);
});

function webBuildDeps(overrides = {}) {
  const statPath = (path) => {
    if (path === WEB_BUILD || path.startsWith(`${WEB_BUILD}/`)) return { isDirectory: () => path === WEB_BUILD, isFile: () => path !== WEB_BUILD };
    if (path === '/fake/repo/.dart_tool/notice-e2e-build/build-1/build-manifest.json') return { isFile: () => true };
    return null;
  };
  return { statPath, readFile: () => MANIFEST, ...overrides };
}

test('assertWebBuild requires the manifest, the define and a clean build', () => {
  const resolved = assertWebBuild(WEB_BUILD, webBuildDeps());
  assert.equal(resolved.dartDefines.LDA_LOCAL_EMULATORS, 'true');
  assert.equal(resolved.buildExitCode, 0);
  assert.equal(resolved.webResourcesCdn, false);
  assert.throws(() => assertWebBuild(WEB_BUILD, webBuildDeps({ readFile: () => '{"dartDefines":{"LDA_LOCAL_EMULATORS":"false"}}' })), /LDA_LOCAL_EMULATORS/);
  assert.throws(() => assertWebBuild(WEB_BUILD, webBuildDeps({ readFile: () => '{"dartDefines":{"LDA_LOCAL_EMULATORS":"true"},"buildExitCode":1}' })), /buildExitCode/);
  assert.throws(() => assertWebBuild(WEB_BUILD, webBuildDeps({ readFile: () => 'not json' })), /build-manifest\.json is unreadable/);
  assert.throws(() => assertWebBuild(WEB_BUILD, webBuildDeps({ statPath: () => null })), /missing/);
});

// ---------------------------------------------------------------------------
// Environment guards
// ---------------------------------------------------------------------------

test('assertRunEnvironment refuses cloud credentials, emulator routing and proxy overrides', () => {
  assert.deepEqual(assertRunEnvironment(SAFE_ENV), { home: HOME });
  for (const [key, value] of [
    ['FIREBASE_TOKEN', 'ya29.secret'],
    ['GOOGLE_APPLICATION_CREDENTIALS', '/keys/sa.json'],
    ['FIRESTORE_EMULATOR_HOST', '127.0.0.1:8080'],
    ['FIREBASE_AUTH_EMULATOR_HOST', '127.0.0.1:9099'],
    ['FIREBASE_EMULATORS_PATH', '/somewhere'],
    ['START_LOGGING_EMULATOR', 'true'],
    ['HTTP_PROXY', 'http://corp:8080'],
    ['JAVA_TOOL_OPTIONS', '-Xmx1g'],
    [RUN_MARKER, 'stale'],
  ]) {
    assert.throws(() => assertRunEnvironment({ ...SAFE_ENV, [key]: value }), new RegExp(`refusing to run with the inherited ${key}`), key);
  }
  assert.throws(() => assertRunEnvironment({ PATH: '/usr/bin' }), /HOME is required/);
});

test('buildRunEnvironment redirects identity/cache state into the run folder', () => {
  const runDir = '/fake/repo/.dart_tool/notice-e2e/x';
  const { env } = buildRunEnvironment(
    { ...SAFE_ENV, MY_FLAG: 'keep', FIREBASE_TRACE: 'drop', GOOGLE_HINT: 'drop', CLOUDSDK_HINT: 'drop' },
    { runId: RUN_ID, runDir },
  );
  assert.equal(env.HOME, `${runDir}/home`);
  assert.equal(env.XDG_CONFIG_HOME, `${runDir}/home/.config`);
  assert.equal(env.CLOUDSDK_CONFIG, `${runDir}/home/.config/gcloud`);
  assert.equal(env.FIREBASE_EMULATORS_PATH, `${runDir}/emulator-cache`);
  assert.equal(env.GCLOUD_PROJECT, PROJECT_ID);
  assert.equal(env.CI, 'true');
  assert.equal(env.NO_UPDATE_NOTIFIER, '1');
  assert.equal(env[RUN_MARKER], RUN_ID);
  assert.equal(env.MY_FLAG, 'keep');
  assert.equal(env.FIREBASE_TRACE, undefined, 'any inherited FIREBASE_* routing must be dropped');
  assert.equal(env.GOOGLE_HINT, undefined);
  assert.equal(env.CLOUDSDK_HINT, undefined);
});

test('buildSeedEnvironment points a fresh Admin child at the isolated addresses only', () => {
  const env = buildSeedEnvironment(SAFE_ENV, { runId: RUN_ID, runDir: '/run' });
  assert.equal(env.FIRESTORE_EMULATOR_HOST, `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`);
  assert.equal(env.FIREBASE_AUTH_EMULATOR_HOST, `127.0.0.1:${ISOLATED_AUTH_PORT}`);
  assert.equal(env.GCLOUD_PROJECT, PROJECT_ID);
  assert.equal(env.GOOGLE_APPLICATION_CREDENTIALS, undefined);
});

// ---------------------------------------------------------------------------
// Frozen ports and generated config
// ---------------------------------------------------------------------------

test('the frozen route map targets only owned isolated ports', () => {
  assert.deepEqual({ ...BROWSER_ROUTES }, { 9099: 8299, 8080: 8280, 5001: 5201, 7358: 7358 });
  for (const [source, target] of Object.entries(BROWSER_ROUTES)) {
    assert.ok(!DEMO_RESERVED_PORTS.includes(Number(target)), `target ${target} must not be a protected demo port`);
  }
  for (const port of OWNED_PORTS) {
    assert.ok(!DEMO_RESERVED_PORTS.includes(port), `owned port ${port} must not collide with demo ports`);
  }
  assert.deepEqual([...OWNED_PORTS].sort((a, b) => a - b), [5201, 7358, 7440, 7460, 8280, 8299]);
});

test('buildFirebaseConfig freezes the isolated emulator topology with the UI disabled', () => {
  const config = buildFirebaseConfig({
    functionsSource: 'functions',
    firestoreRules: 'firestore.rules',
    firestoreIndexes: 'firestore.indexes.json',
  });
  assert.deepEqual(config.emulators.auth, { host: '127.0.0.1', port: ISOLATED_AUTH_PORT });
  assert.deepEqual(config.emulators.firestore, { host: '127.0.0.1', port: ISOLATED_FIRESTORE_PORT, websocketPort: FIRESTORE_WEBSOCKET_PORT });
  assert.deepEqual(config.emulators.functions, { host: '127.0.0.1', port: ISOLATED_FUNCTIONS_PORT });
  assert.deepEqual(config.emulators.hub, { host: '127.0.0.1', port: ISOLATED_HUB_PORT });
  assert.deepEqual(config.emulators.ui, { enabled: false });
  assert.deepEqual(config.functions, { source: 'functions', runtime: 'nodejs24' });
  assert.throws(
    () => buildFirebaseConfig({ functionsSource: 'functions' }),
    /project directory/,
  );
});

test('the generated firebase config keeps every source inside the project directory', () => {
  const config = buildFirebaseConfig({
    functionsSource: 'functions',
    firestoreRules: 'firestore.rules',
    firestoreIndexes: 'firestore.indexes.json',
  });
  assert.equal(config.functions.source, 'functions');
  assert.equal(config.firestore.rules, 'firestore.rules');
  assert.equal(config.firestore.indexes, 'firestore.indexes.json');
  // firebase-tools joins absolute sources instead of honouring them (the
  // functions emulator watched "<configDir>/Users/..." and loaded nothing) and
  // aborts the CLI for an escaping relative one, so both must be refused here.
  for (const value of ['/abs/functions', '../functions', 'a/../../functions', '']) {
    assert.throws(
      () => buildFirebaseConfig({
        functionsSource: value,
        firestoreRules: 'firestore.rules',
        firestoreIndexes: 'firestore.indexes.json',
      }),
      /project directory/,
    );
  }
});

test('buildFirebaseArgs starts exactly auth/firestore/functions for the demo project', () => {
  const args = buildFirebaseArgs('/run/firebase.json');
  assert.deepEqual([...args], ['emulators:start', '--only', 'auth,firestore,functions', '--project', PROJECT_ID, '--config', '/run/firebase.json']);
  assert.ok(!args.includes('--ui'), 'the emulator UI must never be requested');
});

// ---------------------------------------------------------------------------
// Disposable fixture purity
// ---------------------------------------------------------------------------

test('the seed fixture has one administrator and two same-branch north sellers with south stock', () => {
  const roles = NOTICE_FIXTURE.accounts.map((account) => account.claims);
  assert.deepEqual(roles[0], { role: 'administrator' });
  assert.deepEqual(roles[1], { role: 'seller', branchId: 'branch-north' });
  assert.deepEqual(roles[2], { role: 'seller', branchId: 'branch-north' });
  const records = buildSeedRecords();
  const stock = records.filter((record) => record.path.includes('/stock/'));
  assert.deepEqual(
    stock.map((record) => [record.path, record.data.quantityScaled]),
    [['branches/branch-north/stock/DEMO-COFFEE', 0], ['branches/branch-south/stock/DEMO-COFFEE', 3]],
  );
  assert.equal(records.filter((record) => record.path.startsWith('products/')).length, 1);
});

test('buildSeedRecords refuses any transfer-audit or read-marker path', () => {
  // The guard is structural: even a poisoned fixture can never emit an audit
  // or marker path, so a seeded marker can never substitute for the real UI
  // transfer.
  const guarded = buildSeedRecords({
    ...structuredClone(JSON.parse(JSON.stringify(NOTICE_FIXTURE))),
    branches: [{ id: 'transfers/evil', name: 'n', code: 'ABC' }],
    products: [{ id: 'DEMO-COFFEE', data: { internalCode: 'DEMO-COFFEE', name: 'n', quantitySpec: { unit: 'piece', precision: 0 } }, stock: { 'transfers/evil': 1 } }],
  });
  for (const record of guarded) {
    assert.ok(!record.path.startsWith('transfers/') && !record.path.startsWith('transferNoticeReads/'), record.path);
  }
  assert.throws(
    () => buildSeedRecords({ ...structuredClone(JSON.parse(JSON.stringify(NOTICE_FIXTURE))), products: [{ id: 'DEMO-COFFEE', data: { internalCode: 'DEMO-COFFEE', name: 'n', quantitySpec: { unit: 'piece', precision: 0 } }, stock: {} }] }),
    /missing/,
  );
});

test('generateProvisionScript targets the isolated addresses and never seeds audit paths', () => {
  const script = generateProvisionScript({
    authAddress: `127.0.0.1:${ISOLATED_AUTH_PORT}`,
    firestoreAddress: `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`,
  });
  assert.ok(script.includes('env.FIREBASE_AUTH_EMULATOR_HOST !== AUTH_ADDRESS'));
  assert.ok(script.includes('env.FIRESTORE_EMULATOR_HOST !== FIRESTORE_ADDRESS'));
  assert.ok(script.includes(JSON.stringify(`127.0.0.1:${ISOLATED_AUTH_PORT}`)));
  assert.ok(script.includes(JSON.stringify(`127.0.0.1:${ISOLATED_FIRESTORE_PORT}`)));
  assert.ok(script.includes("env.GOOGLE_APPLICATION_CREDENTIALS) refusals.push"));
  assert.ok(script.includes('from \'firebase-admin/app\''));
  assert.ok(script.includes(PROVISION_OUTPUT_PREFIX));
  assert.ok(!script.includes('https://'), 'the provisioning child must never call out to the network');
  assert.ok(!script.includes('/transfers/'), 'no transfer audit may be seeded');
  assert.ok(!script.includes('transferNoticeReads'), 'no read marker may be seeded');
  assert.ok(script.includes('accounts: ACCOUNTS.map((account) => ({ uid: account.uid, email: account.email }))'), 'the report must stay free of passwords');
  assert.ok(script.includes('createUser'));
  assert.throws(() => generateProvisionScript({ authAddress: 'example.com:1', firestoreAddress: '127.0.0.1:1' }), /authAddress/);
});

// ---------------------------------------------------------------------------
// Owned static web server
// ---------------------------------------------------------------------------

test('startOwnedWebServer serves the isolated build read-only over loopback', async () => {
  const root = mkdtempSync(join(tmpdir(), 'notice-e2e-webserver-'));
  try {
    mkdirSync(join(root, 'assets'));
    writeFileSync(join(root, 'index.html'), '<html>ok</html>');
    writeFileSync(join(root, 'assets', 'app.js'), 'console.log(1);');
    const server = await startOwnedWebServer({ webBuild: root, port: 0 });
    assert.equal(server.host, '127.0.0.1');
    const base = `http://127.0.0.1:${server.port}`;
    const index = await fetch(base);
    assert.equal(index.status, 200);
    assert.match(index.headers.get('content-type'), /text\/html/);
    assert.equal(await index.text(), '<html>ok</html>');
    const asset = await fetch(`${base}/assets/app.js`);
    assert.equal(asset.status, 200);
    assert.match(asset.headers.get('content-type'), /text\/javascript/);
    const missing = await fetch(`${base}/nope.js`);
    assert.equal(missing.status, 404);
    const traversal = await fetch(`${base}/..%2f..%2fpackage.json`);
    assert.ok([403, 404].includes(traversal.status));
    const posted = await fetch(base, { method: 'POST', body: 'x' });
    assert.equal(posted.status, 405);
    await server.close();
    await assert.rejects(() => fetch(base), Error);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('startOwnedWebServer refuses a missing build directory', async () => {
  await assert.rejects(
    () => startOwnedWebServer({ webBuild: '/nonexistent/build', port: 0 }),
    /missing/,
  );
});

// ---------------------------------------------------------------------------
// Browser module (pure parts + fake CDP)
// ---------------------------------------------------------------------------

test('buildChromeArgs enforces the mandatory proxy transport and disposable profile', () => {
  const args = buildChromeArgs({ profileDir: '/run/profiles/a', proxyPort: PROXY_PORT });
  assert.ok(args.includes(`--proxy-server=http://127.0.0.1:${PROXY_PORT}`));
  assert.ok(args.includes('--proxy-bypass-list=<-loopback>'));
  assert.ok(args.includes('--remote-debugging-port=0'));
  assert.ok(args.includes('--headless'));
  assert.ok(args.includes('--user-data-dir=/run/profiles/a'));
  assert.equal(args.at(-1), 'about:blank');
  for (const forbidden of ['--no-sandbox', '--proxy-server=direct://', '--no-proxy-server']) {
    assert.ok(!args.includes(forbidden), forbidden);
  }
  assert.throws(() => buildChromeArgs({ profileDir: 'relative', proxyPort: PROXY_PORT }), /absolute/);
  assert.throws(() => buildChromeArgs({ profileDir: '/run/p', proxyPort: 0 }), /proxyPort/);
  assert.throws(() => buildChromeArgs({ profileDir: '/run/p', proxyPort: 70_000 }), /proxyPort/);
});

test('parseDevToolsActivePort reads the ephemeral CDP endpoint', () => {
  assert.deepEqual(parseDevToolsActivePort('9223\n/devtools/browser/abc\n'), { port: 9223, path: '/devtools/browser/abc' });
  assert.throws(() => parseDevToolsActivePort('not-a-port\n/devtools/browser/abc\n'), /CDP port/);
  assert.throws(() => parseDevToolsActivePort('9223\n'), /browser target path/);
});

test('the semantics snippets drive the documented accessibility placeholder path', () => {
  assert.ok(SEMANTICS_PLACEHOLDER_CLICK_JS.includes("querySelector('flt-semantics-placeholder')"));
  assert.ok(SEMANTICS_PLACEHOLDER_CLICK_JS.includes('.click()'));
  assert.ok(SEMANTICS_ACTIVE_JS.includes("querySelectorAll('flt-semantics')"));
  assert.ok(SEMANTIC_SNAPSHOT_JS.includes('getBoundingClientRect'));
  assert.ok(SEMANTIC_SNAPSHOT_JS.includes('aria-label'));
});

function snapshotElement({ tag = 'FLT-SEMANTICS', attrs = {}, text = '', nested = false, parentLabel = null } = {}) {
  return {
    tagName: tag,
    textContent: text,
    getAttribute: name => attrs[name] ?? null,
    closest: () => parentLabel === null ? null : { getAttribute: () => parentLabel },
    querySelector: () => nested ? {} : null,
    getBoundingClientRect: () => ({ x: 10, y: 20, width: 100, height: 30 }),
  };
}

function snapshotRows(elements) {
  return JSON.parse(JSON.stringify(runInNewContext(SEMANTIC_SNAPSHOT_JS, {
    document: { querySelectorAll: () => elements },
  })));
}

test('semantic snapshot includes the captured Sign in button DOM-text label', () => {
  assert.deepEqual(snapshotRows([
    snapshotElement({ attrs: { role: 'button' }, text: '  Sign in  ' }),
  ]), [{
    tag: 'flt-semantics', role: 'button', label: 'Sign in', disabled: false, focused: false,
    x: 10, y: 20, w: 100, h: 30,
  }]);
});

test('semantic snapshot preserves aria labels and does not aggregate container text', () => {
  assert.deepEqual(snapshotRows([
    snapshotElement({ tag: 'INPUT', attrs: { 'aria-label': 'Email' } }),
    snapshotElement({ tag: 'INPUT', parentLabel: 'Password' }),
    snapshotElement({ attrs: { 'aria-label': 'Page' }, text: 'Sign in', nested: true }),
    snapshotElement({ text: 'Email Password Sign in', nested: true }),
  ]), [
    { tag: 'input', role: 'input', label: 'Email', disabled: false, focused: false, x: 10, y: 20, w: 100, h: 30 },
    { tag: 'input', role: 'input', label: 'Password', disabled: false, focused: false, x: 10, y: 20, w: 100, h: 30 },
    { tag: 'flt-semantics', role: 'flt-semantics', label: 'Page', disabled: false, focused: false, x: 10, y: 20, w: 100, h: 30 },
  ]);
});

class FakeWebSocket extends EventEmitter {
  constructor(url, responder = () => ({})) {
    super();
    this.url = url;
    this.readyState = 0;
    this._responder = responder;
    queueMicrotask(() => {
      this.readyState = 1;
      this.emit('open');
      this.dispatchEvent({ type: 'open' });
    });
  }
  addEventListener(type, handler) {
    this.on(type, (event) => handler(event));
  }
  removeEventListener(type, handler) {
    this.off(type, handler);
  }
  dispatchEvent(event) {
    this.emit(event.type, event);
  }
  send(text) {
    const message = JSON.parse(text);
    const result = this._responder(message);
    queueMicrotask(() => {
      this.dispatchEvent({
        type: 'message',
        data: JSON.stringify({ id: message.id, ...(result.error ? { error: result.error } : { result }) }),
      });
      for (const event of result.__events ?? []) {
        this.dispatchEvent({
          type: 'message',
          data: JSON.stringify({ method: event.method, params: event.params ?? {}, sessionId: event.sessionId ?? null }),
        });
      }
    });
  }
  close() {
    this.readyState = 3;
    this.dispatchEvent({ type: 'close' });
  }
}

function fakeChromeChild(pid) {
  const child = Object.assign(new EventEmitter(), {
    pid,
    exitCode: null,
    signalCode: null,
    stdout: new EventEmitter(),
    stderr: new EventEmitter(),
    signals: [],
    kill(signal = 'SIGTERM') {
      child.signals.push(signal);
      child.signalCode = signal;
      child.emit('exit', null, signal);
      child.emit('close', null, signal);
      return true;
    },
    once() {
      EventEmitter.prototype.once.apply(child, arguments);
    },
  });
  return child;
}

function browserTestDeps({ responder, spawnCalls = [] } = {}) {
  const WebSocketImpl = responder
    ? class ResponderWebSocket extends FakeWebSocket {
        constructor(url) {
          super(url, responder);
        }
      }
    : FakeWebSocket;
  return {
    spawn: (path, args, options) => {
      spawnCalls.push({ path, args, options });
      return fakeChromeChild(9500);
    },
    statFile: () => true,
    mkdir: () => {},
    sleep: () => Promise.resolve(),
    now: () => Date.now(),
    readDevToolsPort: async () => 9223,
    fetchImpl: async () => ({ ok: true, json: async () => ({ webSocketDebuggerUrl: 'ws://127.0.0.1:9223/devtools/browser/abc' }) }),
    WebSocketImpl,
  };
}

test('startIsolatedBrowser refuses a missing binary before spawning', async () => {
  const spawnCalls = [];
  const deps = browserTestDeps({ spawnCalls });
  deps.statFile = () => false;
  await assert.rejects(
    () => startIsolatedBrowser({ profileDir: '/run/profiles/a', proxyPort: PROXY_PORT, deps }),
    /never downloads a browser/,
  );
  assert.equal(spawnCalls.length, 0);
});

test('openPage drives semantics and real CDP input through a fake connection', async () => {
  const dispatched = [];
  const inserted = [];
  const keyed = [];
  const written = [];
  const evaluate = (expression) => {
    if (expression === SEMANTICS_PLACEHOLDER_CLICK_JS) return { present: true, clicked: true };
    if (expression === SEMANTICS_ACTIVE_JS) return { nodes: 4, placeholder: 0 };
    if (expression === SEMANTIC_SNAPSHOT_JS) {
      return [
        { tag: 'input', role: 'input', label: 'Email', disabled: false, x: 10, y: 20, w: 100, h: 30 },
        { tag: 'flt-semantics', role: 'button', label: 'Sign in', disabled: false, x: 0, y: 0, w: 40, h: 20 },
      ];
    }
    return null;
  };
  const responder = (message) => {
    const { method, params } = message;
    if (method === 'Target.createTarget') return { targetId: 't1' };
    if (method === 'Target.attachToTarget') return { sessionId: 's1' };
    if (method === 'Runtime.evaluate') {
      try {
        return { result: { type: 'object', value: evaluate(params.expression) } };
      } catch (error) {
        return { result: { type: 'object', value: null }, exceptionDetails: { text: String(error) } };
      }
    }
    if (method === 'Input.dispatchMouseEvent') {
      dispatched.push({ ...params });
      return {};
    }
    if (method === 'Input.insertText') {
      inserted.push(params.text);
      return {};
    }
    if (method === 'Input.dispatchKeyEvent' && params.type === 'keyDown') {
      keyed.push(params.text);
      return {};
    }
    if (method === 'Page.captureScreenshot') return { data: Buffer.from('png').toString('base64') };
    if (method === 'Page.navigate') {
      return { __events: [{ method: 'Page.loadEventFired', sessionId: message.sessionId }] };
    }
    return {};
  };
  const deps = browserTestDeps({ responder });
  const browser = await startIsolatedBrowser({ profileDir: '/run/profiles/a', proxyPort: PROXY_PORT, deps });
  assert.equal(browser.pid, 9500);
  assert.equal(browser.cdpPort, 9223);
  const page = await openPage(browser, {
    deps: { ...deps, stepMs: 50, pollMs: 1, sleep: () => Promise.resolve(), writeFile: async (path, data) => { written.push({ path, bytes: data.length }); } },
  });
  await page.navigate('http://127.0.0.1:7358/');
  await page.enableSemantics();
  const button = await page.findSemantics({ label: 'Sign in' }, { timeoutMs: 50 });
  assert.equal(button.role, 'button');
  const clicked = await page.clickSemantic({ label: 'Sign in' });
  assert.deepEqual([clicked.x, clicked.y], [20, 10]);
  assert.equal(dispatched.filter((event) => event.type === 'mousePressed').length, 1);
  assert.equal(dispatched.filter((event) => event.type === 'mouseReleased').length, 1);
  await page.typeText('seller1@notice-e2e.invalid');
  assert.deepEqual(inserted, [], 'typing must not rely on one bulk insertText');
  assert.equal(keyed.join(''), 'seller1@notice-e2e.invalid');
  await page.screenshot('/run/evidence/shot.png');
  assert.equal(written.length, 1);
  await page.close();
  await browser.close();
  assert.ok(browser.child.signals.includes('SIGTERM'));
});

test('editable click waits for DOM focus before any keystroke', async () => {
  let focused = false;
  let tick = 0;
  let prematureKeystrokes = 0;
  let bulkInserts = 0;
  let typed = '';
  const connection = {
    on: () => () => {},
    send: async (method, params) => {
      if (method === 'Runtime.evaluate') return { result: { value: [{
        tag: 'input', role: 'input', label: 'Password', disabled: false, focused,
        x: 0, y: 0, w: 100, h: 30,
      }] } };
      if (method === 'Input.insertText') bulkInserts++;
      if (method === 'Input.dispatchKeyEvent' && params.type === 'keyDown') {
        if (!focused) prematureKeystrokes++;
        else typed += params.text;
      }
      return {};
    },
  };
  const page = createPage({ connection, sessionId: 's', targetId: 't', deps: {
    now: () => tick, sleep: async ms => { tick += ms; focused = true; }, stepMs: 10, pollMs: 1,
  } });
  try {
    await page.clickSemantic({ role: 'input', label: 'Password' });
    await page.typeText('probe-only');
    assert.equal(prematureKeystrokes, 0);
    assert.equal(bulkInserts, 0);
    assert.equal(typed, 'probe-only');
    assert.equal(focused, true);
  } finally { await page.close(); }
});

test('typing sends real per-character key events with a keystroke cadence', async () => {
  const keyEvents = [];
  const insertedTexts = [];
  const slept = [];
  const connection = {
    on: () => () => {},
    send: async (method, params) => {
      if (method === 'Input.dispatchKeyEvent') keyEvents.push(params);
      if (method === 'Input.insertText') insertedTexts.push(params.text);
      return {};
    },
  };
  const page = createPage({connection, sessionId: 's', targetId: 't', deps: {
    sleep: async (ms) => { slept.push(ms); }, now: () => 0, stepMs: 10, pollMs: 1, keyDelayMs: 7,
  }});
  try {
    await page.typeText('Ab-1');
    assert.deepEqual(insertedTexts, [], 'a bulk insertText is exactly what the app missed; it must not be used');
    assert.deepEqual(
      keyEvents.map((event) => `${event.type}:${event.text ?? event.key}`),
      ['keyDown:A', 'keyUp:A', 'keyDown:b', 'keyUp:b', 'keyDown:-', 'keyUp:-', 'keyDown:1', 'keyUp:1'],
      'every character needs its own keydown/keyup pair in order',
    );
    assert.deepEqual(slept, [7, 7, 7, 7], 'one cadence pause per character keeps the characters intact');
  } finally { await page.close(); }
});

test('typing verifies each character and re-sends one the field dropped', async () => {
  let field = '';
  let droppedOnce = false;
  const keyDowns = [];
  const connection = {
    on: () => () => {},
    send: async (method, params) => {
      if (method === 'Runtime.evaluate') return {result: {value: field}};
      if (method === 'Input.dispatchKeyEvent' && params.type === 'keyDown') {
        keyDowns.push(params.text);
        if (params.text === 'b' && !droppedOnce) { droppedOnce = true; return {}; }
        field += params.text;
      }
      return {};
    },
  };
  const page = createPage({connection, sessionId: 's', targetId: 't', deps: {
    sleep: async () => {}, now: () => 0, stepMs: 10, pollMs: 1, keyDelayMs: 0,
  }});
  try {
    await page.typeText('ab');
    assert.equal(field, 'ab', 'a dropped character must be re-sent until the field holds the exact text');
    assert.deepEqual(keyDowns, ['a', 'b', 'b']);
  } finally { await page.close(); }
});

test('typing refuses to keep going when the field never accepts a character', async () => {
  const connection = {
    on: () => () => {},
    send: async (method) => {
      if (method === 'Runtime.evaluate') return {result: {value: ''}};
      return {};
    },
  };
  const page = createPage({connection, sessionId: 's', targetId: 't', deps: {
    sleep: async () => {}, now: () => 0, stepMs: 10, pollMs: 1, keyDelayMs: 0, keystrokeResendLimit: 2,
  }});
  try {
    await assert.rejects(
      () => page.typeText('x'),
      /did not accept/,
      'an unaccepted character must fail loudly instead of submitting a wrong value',
    );
  } finally { await page.close(); }
});

test('CdpConnection surfaces CDP errors and closes idempotently', async () => {
  const ws = new FakeWebSocket('ws://127.0.0.1:1', () => ({ error: { message: 'nope' } }));
  const connection = new CdpConnection(ws);
  await assert.rejects(() => connection.send('Bad.method'), /Bad\.method failed: nope/);
  connection.close();
  await assert.rejects(() => connection.send('After.close'), /closed/);
});

// ---------------------------------------------------------------------------
// Lifecycle (fake children, fake listeners, fake browser/proxy doubles)
// ---------------------------------------------------------------------------

function mainDemoListeners() {
  return [
    { pid: 500, address: '127.0.0.1', port: 4400, command: 'node' },
    { pid: 500, address: '127.0.0.1', port: 4500, command: 'node' },
    { pid: 500, address: '127.0.0.1', port: 4000, command: 'node' },
    { pid: 500, address: '127.0.0.1', port: 9099, command: 'node' },
    { pid: 501, address: '127.0.0.1', port: 5001, command: 'node' },
    { pid: 502, address: '127.0.0.1', port: 8080, command: 'java' },
    { pid: 502, address: '127.0.0.1', port: 9150, command: 'java' },
    { pid: 500, address: '127.0.0.1', port: 9299, command: 'node' },
    { pid: 500, address: '127.0.0.1', port: 9499, command: 'node' },
  ];
}

function fakeChild(pid) {
  const child = Object.assign(new EventEmitter(), {
    pid,
    exitCode: null,
    signalCode: null,
    stdout: new EventEmitter(),
    stderr: new EventEmitter(),
    signals: [],
    kill(signal = 'SIGTERM') {
      child.signals.push(signal);
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

function lifecycleHarness({
  seedSucceeds = true,
  busyPort = null,
  node = { execPath: PINNED_NODE, version: 'v24.21.0' },
  webBuildDeps: buildDeps = {},
  openPageImpl,
} = {}) {
  const state = {
    spawnCalls: [],
    writtenFiles: new Map(),
    madeDirectories: [],
    cli: null,
    seed: null,
    proxyClosed: 0,
    proxyConfig: null,
    webServerClosed: 0,
    browserCloses: [],
    openPages: 0,
  };
  const listeners = () => {
    const rows = mainDemoListeners().slice();
    if (busyPort) rows.push({ pid: 999, address: '127.0.0.1', port: busyPort, command: 'java' });
    if (state.cli && !state.cli.signalCode && state.cli.exitCode === null) {
      rows.push({ pid: CLI_PID, address: '127.0.0.1', port: ISOLATED_HUB_PORT, command: 'node' });
      rows.push({ pid: CLI_PID, address: '127.0.0.1', port: ISOLATED_FUNCTIONS_PORT, command: 'node' });
      rows.push({ pid: FIRESTORE_PID, address: '127.0.0.1', port: ISOLATED_FIRESTORE_PORT, command: 'java' });
      rows.push({ pid: CLI_PID, address: '127.0.0.1', port: FIRESTORE_WEBSOCKET_PORT, command: 'node' });
      rows.push({ pid: CLI_PID, address: '127.0.0.1', port: ISOLATED_AUTH_PORT, command: 'node' });
    }
    return rows;
  };
  const spawn = (path, args, options) => {
    state.spawnCalls.push({ path, args, options });
    if (state.cli === null) {
      state.cli = fakeChild(CLI_PID);
      queueMicrotask(() => {
        // The real CLI prints this once per successful load; the runner must read
        // it back instead of trusting a bound port.
        state.cli.stdout.emit('data', '✔  functions: Loaded functions definitions from source: createProduct, markTransferNoticeRead, transferInventory.\n');
      });
      return state.cli;
    }
    state.seed = fakeChild(8200);
    queueMicrotask(() => {
      if (seedSucceeds) {
        state.seed.stdout.emit('data', `${PROVISION_OUTPUT_PREFIX}${JSON.stringify({
          accounts: NOTICE_FIXTURE.accounts.map((account) => ({ uid: account.uid, email: account.email })),
          recordsCreated: 5,
        })}\n`);
        state.seed.finish(0);
      } else {
        state.seed.stderr.emit('data', 'boom: refused\n');
        state.seed.finish(3);
      }
    });
    return state.seed;
  };
  // Fake pages in the exact order the run opens them: seller1-live (kept open
  // across the transfer), administrator, seller1-fresh, seller2. Each page
  // exposes only what the public semantics tree would show for its session.
  function makeFakePage(kind) {
    const marked = kind === 'seller-fresh-read';
    const pageState = { marked };
    const baseNodes = () => [
      { tag: 'input', role: 'input', label: 'Email', disabled: false, x: 0, y: 0, w: 10, h: 10 },
      { tag: 'input', role: 'input', label: 'Password', disabled: false, x: 0, y: 0, w: 10, h: 10 },
      { tag: 'flt-semantics', role: 'button', label: 'Sign in', disabled: false, x: 0, y: 0, w: 10, h: 10 },
      { tag: 'flt-semantics', role: 'button', label: 'Log out', disabled: false, x: 0, y: 0, w: 10, h: 10 },
      { tag: 'flt-semantics', role: 'button', label: 'Avisos de traslados', disabled: false, x: 0, y: 0, w: 10, h: 10 },
      { tag: 'flt-semantics', role: 'button', label: 'Cerrar bandeja de avisos', disabled: false, x: 0, y: 0, w: 10, h: 10 },
    ];
    const nodes = () => {
      switch (kind) {
        case 'seller-live': {
          const rows = [
            ...baseNodes(),
            { tag: 'flt-semantics', role: 'text', label: 'Sin avisos de traslados', disabled: false, x: 0, y: 0, w: 10, h: 10 },
          ];
          if (pageState.marked) {
            rows.push({ tag: 'flt-semantics', role: 'text', label: 'Traslado t-1, leído', disabled: false, x: 0, y: 0, w: 10, h: 10 });
          } else {
            rows.push(
              { tag: 'flt-semantics', role: 'text', label: 'Traslado t-1, sin leer', disabled: false, x: 0, y: 0, w: 10, h: 10 },
              { tag: 'flt-semantics', role: 'text', label: 'Demo Coffee', disabled: false, x: 0, y: 0, w: 10, h: 10 },
              { tag: 'flt-semantics', role: 'button', label: 'Marcar como leído', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            );
          }
          return rows;
        }
        case 'admin':
          return [
            ...baseNodes(),
            { tag: 'flt-semantics', role: 'button', label: 'Traslados', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Sucursal de origen', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Selecciona una sucursal', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'South Demo Branch', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'North Demo Branch', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Agregar producto', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Selecciona un producto', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Demo Coffee', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'input', role: 'input', label: 'Cantidad', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Registrar traslado', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Confirmar traslado', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Confirmar y enviar', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'text', label: 'Resultado del traslado', disabled: false, x: 0, y: 0, w: 10, h: 10 },
          ];
        case 'seller-fresh-read':
          return [
            ...baseNodes(),
            { tag: 'flt-semantics', role: 'text', label: 'Traslado t-1, leído', disabled: false, x: 0, y: 0, w: 10, h: 10 },
          ];
        case 'seller2':
          return [
            ...baseNodes(),
            { tag: 'flt-semantics', role: 'text', label: 'Traslado t-1, sin leer', disabled: false, x: 0, y: 0, w: 10, h: 10 },
            { tag: 'flt-semantics', role: 'button', label: 'Marcar como leído', disabled: false, x: 0, y: 0, w: 10, h: 10 },
          ];
        default:
          return baseNodes();
      }
    };
    const page = {
      evalJson: async () => null,
      snapshotSemantics: async () => nodes(),
      findSemantics: async (matcher, options = {}) => {
        const found = nodes().filter((node) => {
          if (matcher.role !== undefined && node.role !== matcher.role) return false;
          if (matcher.label !== undefined && node.label !== matcher.label) return false;
          if (matcher.labelIncludes !== undefined && !node.label.includes(matcher.labelIncludes)) return false;
          if (matcher.labelRegex !== undefined && !matcher.labelRegex.test(node.label)) return false;
          if (!matcher.allowDisabled && node.disabled) return false;
          return true;
        });
        if (found.length === 0) {
          throw new BrowserError(`no matching semantic element for ${JSON.stringify(matcher)} (timeout ${options.timeoutMs ?? 0}ms)`);
        }
        return found[0];
      },
      clickSemantic: async (matcher) => {
        const node = await page.findSemantics(matcher, {});
        if (node.label === 'Marcar como leído') pageState.marked = true;
        return { node, x: 1, y: 1 };
      },
      typeText: async () => {},
      navigate: async () => {},
      enableSemantics: async () => ({ nodes: 5, placeholder: 0 }),
      screenshot: async (path) => { state.writtenFiles.set(path, 'png'); return path; },
      consoleLog: () => [],
      close: async () => {},
    };
    return page;
  }
  const deps = {
    spawn,
    readListeners: async () => listeners(),
    readProcessTree: async () => ({ [FIRESTORE_PID]: CLI_PID }),
    statFile: () => true,
    statPath: (path) => {
      if (path === WEB_BUILD) return { isDirectory: () => true, isFile: () => false };
      if (path.startsWith(`${WEB_BUILD}/`)) return { isDirectory: () => false, isFile: () => true };
      if (path.endsWith('build-manifest.json')) return { isDirectory: () => false, isFile: () => true };
      return { isDirectory: () => false, isFile: () => true };
    },
    readFile: () => MANIFEST,
    writeFile: (path, contents) => { state.writtenFiles.set(String(path), String(contents).slice(0, 80)); },
    symlink: () => {},
    mkdir: (directory) => { state.madeDirectories.push(String(directory)); },
    openLog: () => ({ write: () => {}, close: async () => {} }),
    // A client with no credentials must be refused by the isolated rules.
    fetchImpl: async () => ({ status: 403, text: async () => '{"error":{"status":"PERMISSION_DENIED"}}' }),
    sleep: () => Promise.resolve(),
    now: () => Date.now(),
    runId: RUN_ID,
    registerTerminate: () => () => {},
    loadProxyModule: async () => ({
      startIsolatedBrowserProxy: async ({ routes, allowStaticCdn, onRequest }) => {
        state.proxyConfig = { routes: { ...routes }, allowStaticCdn };
        state.onRequest = onRequest;
        return {
          port: PROXY_PORT,
          close: async () => { state.proxyClosed += 1; },
        };
      },
    }),
    startWebServer: async () => ({
      port: APP_PORT,
      host: '127.0.0.1',
      close: async () => { state.webServerClosed += 1; },
    }),
    startBrowser: async () => {
      const browser = {
        pid: 9600 + state.browserCloses.length,
        connection: { send: async () => ({}), on: () => () => {}, waitEvent: async () => ({}) },
        child: { signals: [] },
        close: async () => { state.browserCloses.push(browser.pid); },
      };
      return browser;
    },
    openPage: openPageImpl ?? (async () => {
      const kinds = ['seller-live', 'admin', 'seller-fresh-read', 'seller2'];
      const kind = kinds[state.openPages];
      state.openPages += 1;
      return makeFakePage(kind);
    }),
    browser: {},
    repoRoot: '/fake/repo',
    node,
    timeouts: { ...{ cliReadyMs: 50, seedMs: 50, stageMs: 50, semanticStepMs: 20, totalMs: 500, pollMs: 1, termMs: 5, killMs: 5, portReleaseMs: 5 } },
    ...buildDeps,
  };
  return { state, deps };
}

const RUN_ARGV = Object.freeze(['--run', '--web-build', WEB_BUILD]);

test('runIsolatedNoticeE2E refuses busy owned ports before spawning anything', async () => {
  const { state, deps } = lifecycleHarness({ busyPort: ISOLATED_FIRESTORE_PORT });
  await assert.rejects(() => runIsolatedNoticeE2E({ argv: RUN_ARGV, env: SAFE_ENV, deps }), /already bound/);
  assert.equal(state.spawnCalls.length, 0);
});

test('runIsolatedNoticeE2E refuses an unpinned node runtime before spawning anything', async () => {
  const { state, deps } = lifecycleHarness({ node: { execPath: '/usr/local/bin/node', version: 'v24.21.0' } });
  await assert.rejects(() => runIsolatedNoticeE2E({ argv: RUN_ARGV, env: SAFE_ENV, deps }), /pinned node runtime/);
  assert.equal(state.spawnCalls.length, 0);
});

test('runIsolatedNoticeE2E tears the CLI down when disposable seeding fails', async () => {
  const { state, deps } = lifecycleHarness({ seedSucceeds: false });
  await assert.rejects(() => runIsolatedNoticeE2E({ argv: RUN_ARGV, env: SAFE_ENV, deps }), /provisioning failed/);
  assert.equal(state.spawnCalls.length, 2);
  assert.ok(state.cli.signals.includes('SIGTERM'), 'the owned CLI must be stopped');
  assert.equal(state.proxyClosed, 0, 'the proxy must never start when seeding fails');
  assert.equal(state.webServerClosed, 0);
  assert.deepEqual(state.browserCloses, []);
  const result = [...state.writtenFiles.entries()].find(([path]) => path.endsWith('result.json'));
  assert.ok(result, 'a result.json must record the failure');
  assert.match(result[1], /failure/);
});

test('the crash handler tears down owned processes and only then exits non-zero', async () => {
  const calls = [];
  let release;
  const teardown = new Promise((resolve) => { release = resolve; });
  const handle = createCrashHandler({
    note: (message) => calls.push(`note:${message}`),
    recordFailure: (error) => calls.push(`failure:${error.message}`),
    teardown: () => { calls.push('teardown'); return teardown; },
    exit: (code) => calls.push(`exit:${code}`),
  });
  handle(new Error('read ECONNRESET'));
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls.slice(0, 2), [
    'failure:read ECONNRESET',
    'note:uncaught exception: read ECONNRESET; tearing down owned processes',
  ]);
  assert.ok(calls.includes('teardown'), 'the teardown must start');
  assert.ok(!calls.includes('exit:1'), 'the exit must wait for the teardown to finish');
  release();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(calls.includes('exit:1'), 'a crash must end in a non-zero exit');
  handle(new Error('second crash'));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.filter((entry) => entry === 'teardown').length, 1, 'teardown runs once');
});

test('a running harness installs its crash handler and removes it afterwards', async () => {
  // Simulating the crash by emitting the process event is not an option: the test
  // runner listens to it too and would fail the test. Instead, prove the wiring:
  // the handlers exist exactly while the run is in flight.
  const uncaughtBefore = process.listenerCount('uncaughtException');
  const rejectionBefore = process.listenerCount('unhandledRejection');
  const { deps } = lifecycleHarness({});
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let parked = false;
  const runPromise = runIsolatedNoticeE2E({
    argv: RUN_ARGV,
    env: SAFE_ENV,
    deps: {
      ...deps,
      openPage: async (browser, options) => {
        parked = true;
        await gate;
        return deps.openPage(browser, options);
      },
    },
  });
  while (!parked) await new Promise((resolve) => setImmediate(resolve));
  assert.ok(
    process.listenerCount('uncaughtException') > uncaughtBefore,
    'a crash mid-run must tear down owned processes instead of leaking them',
  );
  assert.ok(
    process.listenerCount('unhandledRejection') > rejectionBefore,
    'unhandled rejections must tear down owned processes too',
  );
  release();
  await runPromise.catch(() => {});
  assert.equal(process.listenerCount('uncaughtException'), uncaughtBefore, 'the handler must not outlive the run');
  assert.equal(process.listenerCount('unhandledRejection'), rejectionBefore);
});

test('runIsolatedNoticeE2E drives the full public-UI flow over fake doubles and tears down cleanly', async () => {
  const { state, deps } = lifecycleHarness({});
  const summary = await runIsolatedNoticeE2E({ argv: RUN_ARGV, env: SAFE_ENV, deps });
  assert.equal(summary.ok, true);
  assert.deepEqual(state.proxyConfig, { routes: { 9099: 8299, 8080: 8280, 5001: 5201, 7358: 7358 }, allowStaticCdn: true });
  assert.equal(state.proxyClosed, 1);
  assert.equal(state.webServerClosed, 1);
  assert.equal(state.browserCloses.length, 4, 'four disposable browser sessions must be opened and closed');
  assert.equal(state.openPages, 4);
  assert.ok(
    state.madeDirectories.some((dir) => dir.endsWith('emulator-cache')),
    'the run-local emulator cache must exist before the jar symlink',
  );
  assert.ok(
    state.madeDirectories.some((dir) => dir.endsWith('evidence')),
    'the evidence directory must exist before the browser stages write screenshots',
  );
  assert.ok(state.cli.signals.includes('SIGTERM'));
  assert.equal(state.spawnCalls.length, 2);
  const cliSpawn = state.spawnCalls[0];
  assert.ok(cliSpawn.args.some((arg) => String(arg).endsWith('firebase.js')));
  assert.ok(cliSpawn.args.includes('--project'));
  assert.deepEqual(cliSpawn.args[cliSpawn.args.indexOf('--only') + 1].split(','), ['auth', 'firestore', 'functions']);
  assert.equal(cliSpawn.options.env.FIRESTORE_EMULATOR_HOST, undefined, 'the CLI child routes emulators via its config, not seed variables');
  assert.equal(cliSpawn.options.env.GCLOUD_PROJECT, PROJECT_ID);
  const seedSpawn = state.spawnCalls[1];
  assert.deepEqual(seedSpawn.args.slice(0, 2), ['--input-type=module', '--eval']);
  assert.equal(seedSpawn.options.cwd.endsWith('/functions'), true);
  assert.equal(seedSpawn.options.env.FIRESTORE_EMULATOR_HOST, `127.0.0.1:${ISOLATED_FIRESTORE_PORT}`);
  assert.equal(seedSpawn.options.env.FIREBASE_AUTH_EMULATOR_HOST, `127.0.0.1:${ISOLATED_AUTH_PORT}`);
  const result = [...state.writtenFiles.entries()].find(([path]) => path.endsWith('result.json'));
  assert.match(result[1], /success/);
  const stageNames = summary.stages.map((stage) => stage.name);
  for (const expected of ['preflight', 'emulators', 'seed', 'proxy', 'app-web-server', 'seller1-before', 'admin-transfer', 'seller1-live-read', 'seller1-fresh-session', 'seller2-independent']) {
    assert.ok(stageNames.includes(expected), expected);
  }
});

test('the seed child env never carries cloud credentials even when the parent leaks them', () => {
  assert.throws(
    () => buildSeedEnvironment({ ...SAFE_ENV, GOOGLE_APPLICATION_CREDENTIALS: '/x' }, { runId: RUN_ID, runDir: '/run' }),
    /GOOGLE_APPLICATION_CREDENTIALS/,
  );
});

test('a transfer is only accepted from the confirmed outcome region', () => {
  // The success banner hides its own text, and the uncertain region's label
  // contains the accepted one, so an uncertain outcome must never read as done.
  assert.equal(transferOutcome(['Resultado del traslado']), 'accepted');
  assert.equal(
    transferOutcome(['Resultado del traslado', 'Resultado del traslado sin confirmar']),
    'uncertain',
  );
  assert.equal(transferOutcome(['Resultado del traslado', 'Error del traslado']), 'error');
  assert.equal(transferOutcome(['Traslados', 'Registrar traslado']), 'pending');
});

test('the notice product is matched inside the card label, not as its own node', async () => {
  // Captured from the real UI (run 18ea4e8d): the product line lives inside the
  // card's own group label, so an exact "Demo Coffee" node never exists and an
  // exact-label lookup would stall a live stage for the whole timeout.
  const captured = [
    { tag: 'flt-semantics', role: 'group', label: 'Traslado dc4fae0e-8ada-4558-9cf0-fdb3a011b182, sin leer', disabled: false, focused: false, x: 0, y: 0, w: 10, h: 10 },
    { tag: 'flt-semantics', role: 'group', label: 'Traslado dc4fae0e-8ada-4558-9cf0-fdb3a011b182\nDemo Coffee: +1 piece', disabled: false, focused: false, x: 0, y: 0, w: 10, h: 10 },
    { tag: 'flt-semantics', role: 'button', label: 'Marcar como leído', disabled: false, focused: false, x: 0, y: 0, w: 10, h: 10 },
  ];
  const connection = {
    on: () => () => {},
    send: async (method) => (method === 'Runtime.evaluate' ? { result: { value: captured } } : {}),
  };
  let tick = 0;
  const page = createPage({ connection, sessionId: 's', targetId: 't', deps: {
    // the clock must advance with each poll, or a lookup that never matches would
    // spin forever instead of reaching its deadline
    now: () => tick, sleep: async (ms) => { tick += ms; }, stepMs: 10, pollMs: 1,
  } });
  try {
    const found = await page.findSemantics(
      { labelIncludes: NOTICE_FIXTURE.products[0].data.name },
      { timeoutMs: 10 },
    );
    assert.match(found.label, /Demo Coffee: \+1 piece/);
    await assert.rejects(
      () => page.findSemantics({ label: NOTICE_FIXTURE.products[0].data.name }, { timeoutMs: 10 }),
      /no matching semantic element/,
    );
  } finally { await page.close(); }
});

test('a transfer screen is only driven once the local catalog has loaded', () => {
  // Captured from two real runs: job-21 showed the app with no branches and no
  // products (the driver then stalled looking for a branch name), while job-19
  // showed the loaded catalog.
  const blockedCatalog = [
    'Movimientos',
    'Log out',
    'Authenticated locally administrator@notice-e2e.invalid Role: administrator',
    'Traslados',
    'Se necesitan al menos dos sucursales para registrar un traslado.',
    'No hay productos disponibles para trasladar.',
    'Sucursal de origen Selecciona una sucursal',
    'Sucursal de destino Selecciona una sucursal',
    'Producto Selecciona un producto',
    'Agregar producto',
    'Registrar traslado',
  ];
  const loadedCatalog = [
    'Movimientos',
    'Log out',
    'Sucursal de origen South Demo Branch',
    'Sucursal de destino North Demo Branch',
    'Producto Demo Coffee',
    'Productos: 1 de 50',
    'Registrar traslado',
  ];
  assert.equal(catalogBlockingNotice(loadedCatalog), null, 'a loaded catalog must not block the flow');
  assert.equal(
    catalogBlockingNotice(blockedCatalog),
    'Se necesitan al menos dos sucursales para registrar un traslado.',
    'the first notice in the constant order wins, so the message is deterministic',
  );
  assert.equal(
    catalogBlockingNotice(['No hay productos disponibles para trasladar.']),
    'No hay productos disponibles para trasladar.',
  );
});

test('the deployed callables are verified from the CLI log, not from bound ports', () => {
  // Real fragments: the failure that left four runs with zero callables, and the
  // success line that names every deployed callable.
  const failureLog = '⬢  functions: Failed to load function definition from source: FirebaseError: could not deploy functions because the "Users/luismarioruiz/LdA-Software/functions" directory was not found.\n';
  const successLog = '✔  functions: Loaded functions definitions from source: createProduct, markTransferNoticeRead, transferInventory.\n';
  assert.match(functionsLoadFailure(failureLog), /Failed to load function definition/);
  assert.equal(functionsLoadFailure(successLog), null);
  assert.deepEqual(loadedFunctionNames(successLog), ['createProduct', 'markTransferNoticeRead', 'transferInventory']);
  assert.deepEqual(loadedFunctionNames(failureLog), []);
  assert.deepEqual(assertFunctionsDeployed(successLog), ['createProduct', 'markTransferNoticeRead', 'transferInventory']);
  assert.throws(() => assertFunctionsDeployed(failureLog), /did not load the callables/);
  assert.throws(
    () => assertFunctionsDeployed('✔  functions: Loaded functions definitions from source: createProduct.\n'),
    /transferInventory/,
  );
  assert.throws(() => assertFunctionsDeployed('all emulators ready, no functions line\n'), /never reported/);
});

test('the isolated Firestore is proven to enforce the repository rules', async () => {
  const denied = async () => ({ status: 403, text: async () => '{"error":{"status":"PERMISSION_DENIED"}}' });
  const allowed = async () => ({ status: 200, text: async () => '{"name":"projects/demo/databases/(default)/documents/products/probe"}' });
  const missing = async () => ({ status: 404, text: async () => 'not found' });

  assert.deepEqual(
    await assertRulesEnforced({ firestoreHost: '127.0.0.1:8280', projectId: 'demo-x', fetchImpl: denied }),
    { write: 'denied', read: 'denied' },
  );
  // With no rules loaded the emulator accepts everything: a 200 is the defect.
  await assert.rejects(
    () => assertRulesEnforced({ firestoreHost: '127.0.0.1:8280', projectId: 'demo-x', fetchImpl: allowed }),
    /rules are not in force/,
  );
  await assert.rejects(
    () => assertRulesEnforced({ firestoreHost: '127.0.0.1:8280', projectId: 'demo-x', fetchImpl: missing }),
    /inconclusive/,
  );
  await assert.rejects(
    () => assertRulesEnforced({
      firestoreHost: '127.0.0.1:8280',
      projectId: 'demo-x',
      fetchImpl: async () => { throw new Error('connect ECONNREFUSED 127.0.0.1:8280'); },
    }),
    /ECONNREFUSED/,
  );
  await assert.rejects(
    () => assertRulesEnforced({ firestoreHost: '127.0.0.1:8280', projectId: 'demo-x', fetchImpl: null }),
    /fetch implementation/,
  );
});

test('the environment guide documents the frozen topology and commands', () => {
  const guide = readFileSync(new URL('../ISOLATED_E2E_ENVIRONMENT.md', import.meta.url), 'utf8');
  const ports = [
    ISOLATED_AUTH_PORT,
    ISOLATED_FIRESTORE_PORT,
    ISOLATED_FUNCTIONS_PORT,
    ISOLATED_HUB_PORT,
    FIRESTORE_WEBSOCKET_PORT,
    APP_PORT,
    ...Object.keys(BROWSER_ROUTES).map(Number),
    ...Object.values(BROWSER_ROUTES),
  ];
  for (const port of ports) {
    assert.ok(guide.includes(String(port)), `the guide must document port ${port}`);
  }
  for (const needle of [
    '--web-build',
    '--dry-run',
    'LDA_LOCAL_EMULATORS=true',
    'notice-e2e-build',
    'build-manifest.json',
    'build-isolated-web-bundle.mjs',
    'demo-lda-inventory',
    'functions/test/transfer-notice-e2e.test.mjs',
  ]) {
    assert.ok(guide.includes(needle), `the guide must document ${needle}`);
  }
});

test('transferIdFromCardLabel parses the public card label only', () => {
  assert.equal(transferIdFromCardLabel('Traslado 3f2a-9c1b, sin leer'), '3f2a-9c1b');
  assert.equal(transferIdFromCardLabel('nope'), null);
  assert.equal(transferIdFromCardLabel(null), null);
});

test('buildDryRunPlan reports the intended run without services or secrets', async () => {
  const plan = await buildDryRunPlan({
    argv: ['--dry-run', '--web-build', WEB_BUILD],
    env: SAFE_ENV,
    deps: {
      statFile: (path) => path === DEFAULT_CHROME_PATH || path.endsWith('firebase.js') || path.endsWith('isolated-browser-proxy.mjs'),
      readFile: () => MANIFEST,
      statPath: (path) => (path === WEB_BUILD ? { isDirectory: () => true, isFile: () => false } : { isDirectory: () => false, isFile: () => true }),
      node: { execPath: PINNED_NODE, version: 'v24.21.0' },
      repoRoot: '/fake/repo',
    },
  });
  assert.equal(plan.label, 'no-app-e2e-dry-run');
  assert.equal(plan.servicesStarted, false);
  assert.equal(plan.webBuild.dartDefines.LDA_LOCAL_EMULATORS, 'true');
  assert.equal(plan.node.matchesPinned, true);
  assert.equal(plan.chrome.present, true);
  assert.equal(plan.firebaseCli.present, true);
  assert.equal(plan.emulatorJar.version, '1.22.0');
  assert.equal(plan.proxy.expectedExport, 'startIsolatedBrowserProxy');
  const serialized = JSON.stringify(plan);
  for (const account of NOTICE_FIXTURE.accounts) {
    assert.ok(!serialized.includes(account.password), 'no disposable password may appear in a dry-run plan');
  }
});

test('buildDryRunPlan reports a bad web build instead of starting anything', async () => {
  const plan = await buildDryRunPlan({
    argv: ['--dry-run', '--web-build', WEB_BUILD],
    env: SAFE_ENV,
    deps: {
      statFile: () => false,
      readFile: () => MANIFEST,
      statPath: () => null,
      node: { execPath: PINNED_NODE, version: 'v24.21.0' },
      repoRoot: '/fake/repo',
    },
  });
  assert.equal(plan.servicesStarted, false);
  assert.match(plan.webBuild.error, /missing/);
});
