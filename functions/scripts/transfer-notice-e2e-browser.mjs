/**
 * EI-03 — owned-browser CDP runner for the isolated destination-notice E2E.
 *
 * This module never talks to the demo emulator ports and never touches a
 * personal browser profile. It starts the project-local Chrome for Testing
 * binary (S6) with mandatory loopback proxy flags and an ephemeral CDP port,
 * speaks the DevTools protocol over Node 24's built-in WebSocket, and exposes
 * small page helpers that drive the public Flutter web UI through the
 * accessibility (semantics) tree plus real CDP input events.
 *
 * There is no DIRECT network fallback, no sandbox-disabling flag, and no
 * fixed-coordinate clicking (bounds always come from live semantic elements).
 * Business outcomes are only ever asserted through what a real user would see.
 *
 * Every external effect is injectable through `deps`, which is how
 * `test/transfer-notice-e2e.test.mjs` proves the CDP plumbing with a fake
 * WebSocket and fake child. Importing this module has no side effects.
 */
import { spawn as nodeSpawn } from 'node:child_process';
import { mkdirSync, statSync } from 'node:fs';
import { writeFile as nodeWriteFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';

const MODULE_PATH = fileURLToPath(import.meta.url);
export const FUNCTIONS_ROOT = resolve(dirname(MODULE_PATH), '..');
export const REPO_ROOT = resolve(FUNCTIONS_ROOT, '..');
export const DEFAULT_CHROME_PATH = join(
  REPO_ROOT, '.dart_tool', 'e2e-browser', 'chrome-mac-arm64',
  'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing',
);

export const BROWSER_TIMEOUTS = Object.freeze({
  openMs: 30_000,
  stepMs: 20_000,
  pollMs: 250,
  termMs: 10_000,
  killMs: 5_000,
  // Pacing between keystrokes of one field. Measured locally against the real
  // Flutter bundle: per-character key events without this pause dropped
  // characters (25/19/22 of 30), while 25ms delivered the exact text in every
  // trial. It is a typing cadence, not a settling sleep.
  keyDelayMs: 25,
});

// One dropped keystroke is re-sent at most this many extra times before the
// harness refuses to continue: a wrong value would otherwise fail later and
// silently, which is worse than stopping loudly here.
const KEYSTROKE_RESEND_LIMIT = 2;

// Flags that would silently weaken the isolation contract. The runner never
// emits any of them; buildChromeArgs refuses them defensively too.
const FORBIDDEN_CHROME_FLAGS = Object.freeze([
  '--no-sandbox', '--disable-web-security', '--allow-running-insecure-content',
  '--proxy-bypass-list=*', '--proxy-server=direct://', '--no-proxy-server',
]);

export class BrowserError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BrowserError';
  }
}

export function assertChromeBinary(chromePath, { statFile = defaultStatFile } = {}) {
  if (typeof chromePath !== 'string' || !isAbsolute(chromePath)) {
    throw new BrowserError(`the Chrome for Testing path must be absolute, received ${JSON.stringify(chromePath)}`);
  }
  if (!statFile(chromePath)) {
    throw new BrowserError(
      `the authorized project-local Chrome for Testing binary is missing at ${chromePath}; `
      + 'this runner never downloads a browser',
    );
  }
  return chromePath;
}

// Mandatory transport shape: loopback proxy always on, loopback never bypassed
// (so 127.0.0.1 app/CDP traffic still traverses the owned proxy), and an
// ephemeral CDP port. A disposable profile directory is required.
export function buildChromeArgs({ profileDir, proxyPort, headless = true } = {}) {
  if (typeof profileDir !== 'string' || !isAbsolute(profileDir)) {
    throw new BrowserError('profileDir must be an absolute disposable directory inside the run folder');
  }
  if (!Number.isInteger(proxyPort) || proxyPort < 1 || proxyPort > 65_535) {
    throw new BrowserError(`proxyPort must be an integer in [1, 65535], received ${JSON.stringify(proxyPort)}`);
  }
  const args = [
    ...(headless ? ['--headless'] : []),
    `--user-data-dir=${profileDir}`,
    `--proxy-server=http://127.0.0.1:${proxyPort}`,
    '--proxy-bypass-list=<-loopback>',
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--window-size=1280,900',
    'about:blank',
  ];
  for (const flag of args) {
    for (const forbidden of FORBIDDEN_CHROME_FLAGS) {
      if (flag === forbidden || flag.startsWith(`${forbidden}=`)) {
        throw new BrowserError(`refusing the forbidden Chrome flag ${forbidden}`);
      }
    }
    if (flag.startsWith('--user-data-dir=') && !flag.startsWith(`--user-data-dir=${profileDir}`)) {
      throw new BrowserError('the browser must use the disposable profile passed by the run');
    }
  }
  return Object.freeze(args);
}

// DevToolsActivePort: first line is the ephemeral CDP port, second is the
// browser target path.
export function parseDevToolsActivePort(text) {
  const lines = String(text ?? '').split('\n').map((line) => line.trim()).filter(Boolean);
  const port = Number(lines[0]);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new BrowserError(`DevToolsActivePort has no usable CDP port: ${JSON.stringify(lines[0] ?? '')}`);
  }
  const path = lines[1];
  if (typeof path !== 'string' || !path.startsWith('/devtools/')) {
    throw new BrowserError(`DevToolsActivePort has no browser target path: ${JSON.stringify(path ?? '')}`);
  }
  return Object.freeze({ port, path });
}

export class CdpConnection {
  constructor(ws, { onError = () => {} } = {}) {
    if (!ws || typeof ws.send !== 'function' || typeof ws.addEventListener !== 'function') {
      throw new BrowserError('a browser-grade WebSocket implementation is required for the CDP connection');
    }
    this._ws = ws;
    this._nextId = 1;
    this._pending = new Map();
    this._listeners = new Map();
    this._onError = onError;
    this.closed = false;
    ws.addEventListener('message', (event) => this._onMessage(event.data));
    ws.addEventListener('error', () => this._failAll(new BrowserError('the CDP WebSocket errored')));
    ws.addEventListener('close', () => {
      this.closed = true;
      this._failAll(new BrowserError('the CDP WebSocket closed'));
    });
  }

  _onMessage(data) {
    let message;
    try {
      message = JSON.parse(typeof data === 'string' ? data : String(data));
    } catch {
      return;
    }
    if (message.id !== undefined) {
      const pending = this._pending.get(message.id);
      if (!pending) return;
      this._pending.delete(message.id);
      if (message.error) {
        pending.reject(new BrowserError(`CDP ${pending.method} failed: ${message.error.message ?? JSON.stringify(message.error)}`));
      } else {
        pending.resolve(message.result ?? {});
      }
      return;
    }
    for (const handler of this._listeners.get(message.method) ?? []) {
      try {
        handler(message.params ?? {}, message.sessionId ?? null);
      } catch (error) {
        this._onError(error);
      }
    }
  }

  _failAll(error) {
    for (const pending of this._pending.values()) pending.reject(error);
    this._pending.clear();
  }

  on(method, handler) {
    const list = this._listeners.get(method) ?? new Set();
    list.add(handler);
    this._listeners.set(method, list);
    return () => list.delete(handler);
  }

  async waitEvent(method, predicate = () => true, { timeoutMs = BROWSER_TIMEOUTS.stepMs, sleep = defaultSleep, now = defaultNow } = {}) {
    const deadline = now() + timeoutMs;
    return await new Promise((resolvePromise, rejectPromise) => {
      const unsubscribe = this.on(method, (params, sessionId) => {
        if (!predicate(params, sessionId)) return;
        clearTimeout(timer);
        unsubscribe();
        resolvePromise({ params, sessionId });
      });
      const timer = setTimeout(() => {
        unsubscribe();
        rejectPromise(new BrowserError(`timed out after ${timeoutMs}ms waiting for CDP event ${method}`));
      }, Math.max(1, deadline - now()));
    });
  }

  send(method, params = {}, sessionId = null) {
    if (this.closed || this._ws.readyState === 3) {
      return Promise.reject(new BrowserError(`the CDP connection is closed; cannot send ${method}`));
    }
    const id = this._nextId;
    this._nextId += 1;
    return new Promise((resolvePromise, rejectPromise) => {
      this._pending.set(id, { method, resolve: resolvePromise, reject: rejectPromise });
      this._ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  close() {
    this.closed = true;
    this._failAll(new BrowserError('the CDP connection was closed'));
    try {
      this._ws.close();
    } catch {
      // Closing an already-dead socket is not an error.
    }
  }
}

// Starts the owned Chrome for Testing child, waits for its ephemeral loopback
// CDP endpoint, verifies it answers on 127.0.0.1 only, and returns a small
// client. `close()` stops exactly this run's browser process group.
export async function startIsolatedBrowser({
  chromePath = DEFAULT_CHROME_PATH,
  profileDir,
  proxyPort,
  deps = {},
} = {}) {
  const d = withDefaults(deps);
  assertChromeBinary(chromePath, d);
  if (typeof profileDir !== 'string' || !isAbsolute(profileDir)) {
    throw new BrowserError('profileDir must be an absolute disposable directory inside the run folder');
  }
  if (!Number.isInteger(proxyPort) || proxyPort < 1 || proxyPort > 65_535) {
    throw new BrowserError(`proxyPort must be an integer in [1, 65535], received ${JSON.stringify(proxyPort)}`);
  }
  const args = buildChromeArgs({ profileDir, proxyPort });
  d.mkdir(profileDir);
  const child = d.spawn(chromePath, args, { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  const tracked = trackChild(child);
  const stop = () => stopOwnedBrowser(child, tracked, d);

  const openMs = d.timeouts.openMs;
  const deadline = d.now() + openMs;
  let cdpPort = null;
  let version = null;
  while (d.now() < deadline) {
    if (tracked.exited) {
      throw new BrowserError(
        `the owned browser exited before CDP readiness (code=${tracked.code}, signal=${tracked.signal})`,
      );
    }
    const port = await d.readDevToolsPort(profileDir).catch(() => null);
    if (port) {
      const probed = await probeVersion(d, port, deadline).catch(() => null);
      if (probed) {
        cdpPort = port;
        version = probed;
        break;
      }
    }
    await d.sleep(d.pollMs);
  }
  if (!cdpPort) {
    await stop();
    throw new BrowserError(`the owned browser did not expose a CDP endpoint within ${openMs}ms`);
  }
  const wsUrl = version?.webSocketDebuggerUrl;
  if (typeof wsUrl !== 'string' || !/^ws:\/\/127\.0\.0\.1:/.test(wsUrl)) {
    await stop();
    throw new BrowserError(`refusing a non-loopback CDP endpoint: ${JSON.stringify(wsUrl ?? null)}`);
  }
  let ws;
  try {
    ws = new d.WebSocketImpl(wsUrl);
  } catch (error) {
    try {
      await stop();
    } catch {
      // A teardown failure must not replace the original setup error.
    }
    throw error;
  }
  try {
    await waitWebSocketOpen(ws, deadline, d.sleep, d.now);
  } catch (error) {
    await stop();
    throw error instanceof BrowserError ? error : new BrowserError(String(error?.message ?? error));
  }
  const connection = new CdpConnection(ws, { onError: (error) => d.noteError(error) });
  return Object.freeze({
    pid: child.pid,
    cdpPort,
    connection,
    child,
    tracked,
    stdout: child.stdout,
    stderr: child.stderr,
    close: async () => {
      connection.close();
      return await stop();
    },
  });
}

function waitWebSocketOpen(ws, deadline, sleep, now) {
  return new Promise((resolvePromise, rejectPromise) => {
    const onOpen = () => { cleanup(); resolvePromise(); };
    const onError = () => { cleanup(); rejectPromise(new BrowserError('the CDP WebSocket could not connect')); };
    const cleanup = () => {
      ws.removeEventListener('open', onOpen);
      ws.removeEventListener('error', onError);
      clearInterval(poll);
    };
    ws.addEventListener('open', onOpen);
    ws.addEventListener('error', onError);
    const poll = setInterval(() => {
      if (now() >= deadline) {
        cleanup();
        rejectPromise(new BrowserError('the CDP WebSocket did not open in time'));
      }
    }, 50);
    if (ws.readyState === 1) {
      cleanup();
      resolvePromise();
    }
  });
}

async function probeVersion(d, port, deadline) {
  if (typeof d.fetchImpl !== 'function') return null;
  const controller = new AbortController();
  let timer;
  const expired = new Promise((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new BrowserError('the CDP version probe exceeded the browser readiness deadline'));
    }, Math.max(1, deadline - d.now()));
  });
  try {
    return await Promise.race([
      (async () => {
        const response = await d.fetchImpl(`http://127.0.0.1:${port}/json/version`, { signal: controller.signal });
        if (!response?.ok) return null;
        return await response.json();
      })(),
      expired,
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// Opens one page (tab) in the owned browser and returns the helper object.
export async function openPage(browser, { url = 'about:blank', deps = {} } = {}) {
  const connection = browser.connection;
  const { targetId } = await connection.send('Target.createTarget', { url });
  try {
    const { sessionId } = await connection.send('Target.attachToTarget', { targetId, flatten: true });
    await connection.send('Page.enable', {}, sessionId);
    await connection.send('Runtime.enable', {}, sessionId);
    return createPage({ connection, sessionId, targetId, deps });
  } catch (error) {
    // The page helper does not exist yet, so it cannot own failed setup cleanup.
    // Keep the setup error even if the connection also refuses target closure.
    try {
      await connection.send('Target.closeTarget', { targetId });
    } catch {
      // Browser-level teardown remains the fallback when CDP is unavailable.
    }
    throw error;
  }
}

// Reads the value the browser holds for the focused field, or null when the
// focused element is not a text field (or a fake CDP double answers).
export const ACTIVE_FIELD_VALUE_JS = `(() => {
  const el = document.activeElement;
  return el && typeof el.value === 'string' ? el.value : null;
})()`;

export function createPage({ connection, sessionId, targetId, deps = {} } = {}) {
  if (!connection || !sessionId || !targetId) {
    throw new BrowserError('a CDP connection, session id and target id are required');
  }
  const d = {
    sleep: defaultSleep,
    now: defaultNow,
    writeFile: nodeWriteFile,
    stepMs: BROWSER_TIMEOUTS.stepMs,
    pollMs: BROWSER_TIMEOUTS.pollMs,
    keyDelayMs: BROWSER_TIMEOUTS.keyDelayMs,
    keystrokeResendLimit: KEYSTROKE_RESEND_LIMIT,
    ...deps,
  };
  const send = (method, params = {}) => connection.send(method, params, sessionId);
  const consoleEntries = [];
  const unsubscribeConsole = connection.on('Runtime.consoleAPICalled', (params, eventSession) => {
    if (eventSession !== sessionId) return;
    consoleEntries.push({
      at: new Date().toISOString(),
      type: params.type,
      text: (params.args ?? []).map((arg) => arg.value ?? arg.description ?? arg.type).join(' '),
    });
  });
  const unsubscribeExceptions = connection.on('Runtime.exceptionThrown', (params, eventSession) => {
    if (eventSession !== sessionId) return;
    consoleEntries.push({
      at: new Date().toISOString(),
      type: 'exception',
      text: params.exceptionDetails?.exception?.description ?? params.exceptionDetails?.text ?? 'unknown exception',
    });
  });

  async function evalJson(expression) {
    const result = await send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: false,
    });
    if (result.exceptionDetails) {
      throw new BrowserError(
        `page evaluation failed: ${result.exceptionDetails.exception?.description ?? result.exceptionDetails.text}`,
      );
    }
    return result.result?.value;
  }

  async function snapshotSemantics() {
    const value = await evalJson(SEMANTIC_SNAPSHOT_JS);
    return Array.isArray(value) ? value : [];
  }

  function matches(node, matcher) {
    if (typeof matcher === 'function') return matcher(node);
    if (matcher.role !== undefined && node.role !== matcher.role) return false;
    if (matcher.label !== undefined && node.label !== matcher.label) return false;
    if (matcher.labelIncludes !== undefined && !String(node.label ?? '').includes(matcher.labelIncludes)) return false;
    if (matcher.labelRegex !== undefined && !matcher.labelRegex.test(String(node.label ?? ''))) return false;
    if (matcher.tag !== undefined && node.tag !== matcher.tag) return false;
    if (!matcher.allowDisabled && node.disabled) return false;
    return true;
  }

  async function findSemantics(matcher, { timeoutMs = d.stepMs, pollMs = d.pollMs, all = false } = {}) {
    const deadline = d.now() + timeoutMs;
    for (;;) {
      const nodes = (await snapshotSemantics()).filter((node) => matches(node, matcher));
      if (all && nodes.length > 0) return nodes;
      if (!all && nodes.length > 0) return nodes[0];
      if (d.now() >= deadline) {
        throw new BrowserError(
          `no matching semantic element within ${timeoutMs}ms for ${describeMatcher(matcher)}; `
          + `visible nodes: ${JSON.stringify((await snapshotSemantics()).slice(0, 40))}`,
        );
      }
      await d.sleep(pollMs);
    }
  }

  async function clickSemantic(matcher, options = {}) {
    const node = await findSemantics(matcher, options);
    if (node.disabled) throw new BrowserError(`refusing to click a disabled element: ${JSON.stringify(node)}`);
    const x = Math.round((node.x + node.w / 2) * 100) / 100;
    const y = Math.round((node.y + node.h / 2) * 100) / 100;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
    if (node.tag === 'input' || node.tag === 'textarea') {
      // A CDP mouse acknowledgment does not guarantee Flutter settled focus.
      await findSemantics(candidate => matches(candidate, matcher) && candidate.focused === true, options);
    }
    return { node, x, y };
  }

  return {
    sessionId,
    targetId,
    evalJson,
    snapshotSemantics,
    findSemantics,
    clickSemantic,
    // Real keystrokes, one character at a time, each one verified against the
    // focused field. A single Input.insertText reaches the DOM element but
    // Flutter's own field state intermittently misses it, so the app sees empty
    // fields and stops before Auth (measured on the real bundle: 0/3 reached the
    // app versus 3/3 with these key events). Key events can still drop a
    // character now and then (measured: a 32-character address arrived as 31 in
    // one of three trials), so the same character is re-sent until the field
    // holds it, or the harness fails loudly instead of submitting a wrong value.
    typeText: async (text, { keyDelayMs = d.keyDelayMs, resendLimit = d.keystrokeResendLimit } = {}) => {
      const initial = await evalJson(ACTIVE_FIELD_VALUE_JS).catch(() => null);
      const base = typeof initial === 'string' ? initial : '';
      for (let index = 0; index < text.length; index += 1) {
        const expected = base + text.slice(0, index + 1);
        for (let resends = 0; ; resends += 1) {
          await send('Input.dispatchKeyEvent', {
            type: 'keyDown', text: text[index], unmodifiedText: text[index], key: text[index],
          });
          await send('Input.dispatchKeyEvent', { type: 'keyUp', key: text[index] });
          if (keyDelayMs > 0) await d.sleep(keyDelayMs);
          const value = await evalJson(ACTIVE_FIELD_VALUE_JS).catch(() => null);
          // A fake CDP double, or a page without a readable focused field, cannot
          // be verified: the keystroke was sent, so keep typing.
          if (typeof value !== 'string' || value === expected) break;
          if (value.length > expected.length) {
            throw new BrowserError(`the focused field holds more text than was typed: ${JSON.stringify(value)}`);
          }
          if (resends >= resendLimit) {
            throw new BrowserError(
              `the focused field did not accept ${JSON.stringify(text[index])} after ${resends + 1} attempts; `
              + 'refusing to submit a value the app never received',
            );
          }
        }
      }
    },
    navigate: async (target, { timeoutMs = d.stepMs } = {}) => {
      const load = connection.waitEvent(
        'Page.loadEventFired',
        (_params, eventSession) => eventSession === sessionId,
        { timeoutMs, sleep: d.sleep, now: d.now },
      );
      const navigated = await send('Page.navigate', { url: target });
      if (navigated.errorText) throw new BrowserError(`navigation failed: ${navigated.errorText}`);
      await load;
    },
    enableSemantics: async ({ timeoutMs = d.stepMs, pollMs = d.pollMs } = {}) => {
      // Flutter web keeps the semantics tree off until its accessibility
      // placeholder is activated; clicking it is the engine's own documented
      // enablement path (no internal controller injection involved).
      const deadline = d.now() + timeoutMs;
      for (;;) {
        const clicked = await evalJson(SEMANTICS_PLACEHOLDER_CLICK_JS).catch(() => null);
        if (clicked?.clicked) break;
        if (d.now() >= deadline) {
          throw new BrowserError(
            `the Flutter accessibility placeholder did not appear within ${timeoutMs}ms; `
            + 'the public semantic UI cannot be driven without it',
          );
        }
        await d.sleep(pollMs);
      }
      for (;;) {
        const state = await evalJson(SEMANTICS_ACTIVE_JS).catch(() => null);
        if (state?.nodes > 0) return state;
        if (d.now() >= deadline) {
          throw new BrowserError(`the Flutter semantics tree did not activate within ${timeoutMs}ms`);
        }
        await d.sleep(pollMs);
      }
    },
    screenshot: async (filePath) => {
      const captured = await send('Page.captureScreenshot', { format: 'png' });
      if (!captured.data) throw new BrowserError('the browser returned no screenshot data');
      await d.writeFile(filePath, Buffer.from(captured.data, 'base64'), { mode: 0o600 });
      return filePath;
    },
    consoleLog: () => consoleEntries.slice(),
    close: async () => {
      unsubscribeConsole();
      unsubscribeExceptions();
      await connection.send('Target.closeTarget', { targetId }).catch(() => {});
    },
  };
}

// Snapshot of the live accessibility tree: one row per visible semantic node
// (and text inputs), with viewport-relative bounds for CDP input dispatch.
export const SEMANTIC_SNAPSHOT_JS = `(() => {
  const rows = [];
  for (const el of document.querySelectorAll('flt-semantics, input, textarea')) {
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    const tag = el.tagName.toLowerCase();
    const isField = tag === 'input' || tag === 'textarea';
    // Flutter buttons expose DOM text; do not aggregate descendant controls.
    const textLabel = !isField && el.querySelector('flt-semantics') === null
      ? (el.textContent ?? '').replace(/\\s+/g, ' ').trim()
      : '';
    const label = el.getAttribute('aria-label')
      ?? (isField ? el.closest('flt-semantics')?.getAttribute('aria-label') ?? '' : textLabel)
      ?? el.getAttribute('placeholder') ?? '';
    if (!label && !isField) continue;
    rows.push({
      tag,
      role: el.getAttribute('role') ?? (isField ? 'input' : tag),
      label,
      disabled: el.getAttribute('aria-disabled') === 'true',
      focused: isField && el === document.activeElement,
      x: rect.x, y: rect.y, w: rect.width, h: rect.height,
    });
  }
  return rows;
})()`;

export const SEMANTICS_PLACEHOLDER_CLICK_JS = `(() => {
  const placeholder = document.querySelector('flt-semantics-placeholder');
  if (!placeholder) return { present: false, clicked: false };
  placeholder.click();
  return { present: true, clicked: true };
})()`;

export const SEMANTICS_ACTIVE_JS = `(() => ({
  nodes: document.querySelectorAll('flt-semantics').length,
  placeholder: document.querySelectorAll('flt-semantics-placeholder').length,
}))()`;

function describeMatcher(matcher) {
  if (typeof matcher === 'function') return 'custom predicate';
  return Object.entries(matcher)
    .map(([key, value]) => `${key}=${value instanceof RegExp ? value.source : JSON.stringify(value)}`)
    .join(' ');
}

// Bounded escalation addressed only to the browser process group this run
// spawned; never to a pid this run did not create.
async function stopOwnedBrowser(child, tracked, d) {
  const hasExited = () => tracked.exited
    || (child.exitCode !== null && child.exitCode !== undefined)
    || (child.signalCode !== null && child.signalCode !== undefined);
  if (hasExited()) return Object.freeze({ stopped: false, escalated: false });
  signalOwnedGroup(child, 'SIGTERM');
  const termMs = d.timeouts?.termMs ?? BROWSER_TIMEOUTS.termMs;
  const killMs = d.timeouts?.killMs ?? BROWSER_TIMEOUTS.killMs;
  const termDeadline = d.now() + termMs;
  while (!hasExited()) {
    if (d.now() >= termDeadline) {
      signalOwnedGroup(child, 'SIGKILL');
      const killDeadline = d.now() + killMs;
      while (!hasExited()) {
        if (d.now() >= killDeadline) {
          throw new BrowserError(`owned browser pid ${child.pid} survived SIGKILL; refusing to report a clean teardown`);
        }
        await d.sleep(BROWSER_TIMEOUTS.pollMs);
      }
      return Object.freeze({ stopped: true, escalated: true });
    }
    await d.sleep(BROWSER_TIMEOUTS.pollMs);
  }
  return Object.freeze({ stopped: true, escalated: false });
}

function signalOwnedGroup(child, signal) {
  try {
    process.kill(-child.pid, signal);
    return;
  } catch (error) {
    if (error?.code !== 'ESRCH') {
      try {
        child.kill(signal);
      } catch (inner) {
        if (inner?.code !== 'ESRCH') throw inner;
      }
      return;
    }
  }
  try {
    child.kill(signal);
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

function trackChild(child) {
  const tracked = { exited: false, code: null, signal: null };
  const settle = (code, signal) => {
    if (tracked.exited) return;
    tracked.exited = true;
    tracked.code = code ?? null;
    tracked.signal = signal ?? null;
  };
  child.once?.('exit', (code, signal) => settle(code, signal));
  child.once?.('close', (code, signal) => settle(code ?? tracked.code, signal ?? tracked.signal));
  child.once?.('error', () => settle(null, null));
  if (child.exitCode !== null && child.exitCode !== undefined) settle(child.exitCode, null);
  else if (child.signalCode !== null && child.signalCode !== undefined) settle(null, child.signalCode);
  return tracked;
}

async function defaultReadDevToolsPort(profileDir) {
  const text = await readFile(join(profileDir, 'DevToolsActivePort'), 'utf8');
  return parseDevToolsActivePort(text).port;
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

function withDefaults(deps) {
  const merged = {
    spawn: nodeSpawn,
    statFile: defaultStatFile,
    mkdir: (directory) => mkdirSync(directory, { recursive: true, mode: 0o700 }),
    sleep: defaultSleep,
    now: defaultNow,
    readDevToolsPort: defaultReadDevToolsPort,
    fetchImpl: typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : null,
    WebSocketImpl: globalThis.WebSocket,
    noteError: () => {},
    ...deps,
  };
  return { ...merged, timeouts: { ...BROWSER_TIMEOUTS, ...(deps.timeouts ?? {}) } };
}
