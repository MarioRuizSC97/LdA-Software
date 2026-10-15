/**
 * EI-02 — strict owned-loopback browser proxy for isolated E2E runs.
 *
 * Public contract (frozen, task log L11/L12): the only export is
 * `startIsolatedBrowserProxy({routes, allowStaticCdn = false, onRequest = () => {}})`,
 * which resolves to `{port, close}` after binding an ephemeral 127.0.0.1 port.
 *
 * Security posture:
 * - `routes` maps allowed browser-visible source ports (9099/8080/5001/7358)
 *   to caller-owned integer target ports. Invalid options reject before any
 *   listen or network activity; protected demo ports (9099/8080/5001/4000/
 *   4400/4500/9199) are never valid targets.
 * - Absolute-form HTTP request targets are forwarded only when the authority
 *   is exactly `127.0.0.1:<registered source port>` with the http scheme and
 *   no credentials. Everything else is rejected before forwarding.
 * - CONNECT is tunneled (no TLS MITM) only to the exact authority
 *   `www.gstatic.com:443` and only when `allowStaticCdn` is true; any other
 *   CONNECT is denied before dialing.
 * - Request and response bodies stream end to end without buffering;
 *   hop-by-hop headers are removed while the browser-visible Host authority
 *   is preserved.
 * - `close()` destroys every owned socket, is idempotent, and is safe to call
 *   during in-flight errors or aborts.
 * - `onRequest` receives metadata only ({kind, authority, targetPort?, method?});
 *   never credentials, tokens, bodies, or query strings.
 *
 * Test seam (not part of the public contract): `_setConnectDialForTests`
 * replaces the CONNECT dial so tests never touch the real CDN.
 */
import http from 'node:http';
import net from 'node:net';

const ALLOWED_SOURCE_PORTS = new Set([9099, 8080, 5001, 7358]);
const PROTECTED_DEMO_PORTS = new Set([9099, 8080, 5001, 4000, 4400, 4500, 9199]);
const CONNECT_AUTHORITY = 'www.gstatic.com:443';
const REJECT_BODY = 'not-allowlisted';
const HOP_BY_HOP = new Set([
  'connection',
  'proxy-connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);

const defaultConnectDial = () => net.connect({ host: 'www.gstatic.com', port: 443 });
let connectDial = defaultConnectDial;

function resolveRoutes(routes) {
  if (routes === null || typeof routes !== 'object' || Array.isArray(routes)) {
    throw new TypeError('routes must be a plain object mapping allowed source ports to owned target ports');
  }
  const entries = Object.entries(routes);
  if (entries.length === 0) {
    throw new TypeError('routes must map at least one allowed source port to an owned target port');
  }
  const routeBySource = new Map();
  for (const [rawSource, rawTarget] of entries) {
    const source = Number(rawSource);
    if (!Number.isInteger(source) || String(source) !== String(rawSource) || !ALLOWED_SOURCE_PORTS.has(source)) {
      throw new TypeError(
        `routes key ${JSON.stringify(rawSource)} is not an allowed source port ` +
        `(${[...ALLOWED_SOURCE_PORTS].join('/')})`,
      );
    }
    if (routeBySource.has(source)) {
      throw new TypeError(`duplicate route for source port ${source}`);
    }
    if (!Number.isInteger(rawTarget) || rawTarget < 1 || rawTarget > 65535) {
      throw new TypeError(`routes[${source}] must be an integer target port in 1..65535`);
    }
    if (PROTECTED_DEMO_PORTS.has(rawTarget)) {
      throw new TypeError(`routes[${source}] target ${rawTarget} is a protected demo port and must never be dialed`);
    }
    routeBySource.set(source, rawTarget);
  }
  return routeBySource;
}

function isAllowedHttpAuthority(url, routeBySource) {
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1') return false;
  if (url.username !== '' || url.password !== '') return false;
  if (url.port === '') return false;
  return routeBySource.has(Number(url.port));
}

function stripHopByHop(headers) {
  const connectionTokens = String(headers.connection || '')
    .split(',')
    .map(token => token.trim().toLowerCase())
    .filter(Boolean);
  const filtered = {};
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase();
    if (HOP_BY_HOP.has(lower) || connectionTokens.includes(lower)) continue;
    filtered[name] = value;
  }
  return filtered;
}

function forwardHeaders(sourceHeaders, host) {
  const filtered = stripHopByHop(sourceHeaders);
  delete filtered.host;
  filtered.host = host;
  return filtered;
}

async function startListening({ routeBySource, allowStaticCdn, onRequest }) {
  const owned = new Set();
  const track = socket => {
    // The ownership guard comes first: a reused keep-alive socket is tracked
    // again on every request, and adding listeners before the guard re-introduces
    // the MaxListenersExceededWarning (observed in a real run).
    if (owned.has(socket)) return;
    owned.add(socket);
    // An 'error' listener is mandatory on every socket the proxy owns: without
    // one, a reset (ECONNRESET) becomes an uncaught exception that kills the
    // whole run and skips its cleanup — observed on a real E2E run. Failures are
    // still reported through the request and response paths; this listener only
    // stops the process from dying.
    socket.on('error', () => {});
    socket.once('close', () => owned.delete(socket));
  };

  function handleRequest(req, res) {
    let url;
    try {
      url = new URL(req.url);
    } catch {
      onRequest({ kind: 'http-denied', authority: null, method: req.method });
      res.writeHead(400, { 'content-type': 'text/plain', connection: 'close' });
      res.end('invalid request target');
      return;
    }
    if (!isAllowedHttpAuthority(url, routeBySource)) {
      onRequest({ kind: 'http-denied', authority: url.host || null, method: req.method });
      res.writeHead(403, { 'content-type': 'text/plain', connection: 'close' });
      res.end(REJECT_BODY);
      return;
    }

    const targetPort = routeBySource.get(Number(url.port));
    onRequest({ kind: 'http', authority: url.host, targetPort, method: req.method });

    const forward = http.request({
      host: '127.0.0.1',
      port: targetPort,
      method: req.method,
      path: `${url.pathname}${url.search}`,
      headers: forwardHeaders(req.headers, url.host),
    });
    forward.on('socket', track);
    let responseDone = false;
    forward.on('response', upstreamResponse => {
      res.writeHead(upstreamResponse.statusCode, stripHopByHop(upstreamResponse.headers));
      upstreamResponse.on('end', () => { responseDone = true; });
      upstreamResponse.on('error', () => res.destroy());
      upstreamResponse.pipe(res);
    });
    forward.on('error', () => {
      if (res.headersSent || res.writableEnded) {
        res.destroy();
      } else if (!res.destroyed) {
        res.writeHead(502, { 'content-type': 'text/plain', connection: 'close' });
        res.end('upstream connection failed');
      }
    });
    req.on('error', () => forward.destroy());
    req.on('aborted', () => forward.destroy());
    res.on('close', () => { if (!responseDone) forward.destroy(); });
    req.pipe(forward);
  }

  function handleConnect(req, clientSocket, head) {
    track(clientSocket);
    const authority = typeof req.url === 'string' ? req.url : '';
    if (!allowStaticCdn || authority !== CONNECT_AUTHORITY) {
      onRequest({ kind: 'connect-denied', authority });
      clientSocket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }

    let upstream;
    try {
      upstream = connectDial();
    } catch {
      clientSocket.destroy();
      return;
    }
    track(upstream);
    onRequest({ kind: 'connect', authority });

    let established = false;
    const teardown = () => {
      clientSocket.destroy();
      upstream.destroy();
    };
    upstream.once('connect', () => {
      established = true;
      if (clientSocket.destroyed) {
        upstream.destroy();
        return;
      }
      clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head && head.length > 0) upstream.write(head);
      clientSocket.pipe(upstream);
      upstream.pipe(clientSocket);
    });
    upstream.once('error', () => {
      if (!established && clientSocket.writable && !clientSocket.destroyed) {
        clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');
      }
      teardown();
    });
    clientSocket.once('error', teardown);
    clientSocket.once('close', () => upstream.destroy());
    upstream.once('close', () => {
      if (!clientSocket.destroyed) clientSocket.destroy();
    });
  }

  const server = http.createServer(handleRequest);
  server.on('connection', track);
  server.on('connect', handleConnect);
  server.on('clientError', (error, socket) => {
    if (socket.writable && !socket.destroyed) {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    } else {
      socket.destroy();
    }
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });

  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    for (const socket of owned) socket.destroy();
    owned.clear();
    server.closeAllConnections();
    await new Promise(resolve => server.close(() => resolve()));
  }

  return { port: server.address().port, close };
}

export async function startIsolatedBrowserProxy({ routes, allowStaticCdn = false, onRequest = () => {} } = {}) {
  const routeBySource = resolveRoutes(routes);
  if (typeof allowStaticCdn !== 'boolean') {
    throw new TypeError('allowStaticCdn must be a boolean');
  }
  if (typeof onRequest !== 'function') {
    throw new TypeError('onRequest must be a function');
  }
  return startListening({ routeBySource, allowStaticCdn, onRequest });
}

Object.defineProperty(startIsolatedBrowserProxy, '_setConnectDialForTests', {
  value(dial) {
    connectDial = typeof dial === 'function' ? dial : defaultConnectDial;
  },
  enumerable: false,
  writable: false,
});
