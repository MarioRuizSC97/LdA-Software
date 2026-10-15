/**
 * EI-02 — strict owned-loopback browser proxy unit tests.
 *
 * Every rule is exercised through the exported public interface against real
 * owned 127.0.0.1 servers on ephemeral ports. No protected demo port is ever
 * bound or dialed: protected-port safety is asserted through option
 * validation (rejection before listen) and dial/hit counters that must stay
 * at zero. No external network request is made: the CONNECT dial seam is
 * injected with owned local sockets, never the real CDN.
 */
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import test from 'node:test';

import { startIsolatedBrowserProxy } from '../scripts/isolated-browser-proxy.mjs';

// Browser-visible source authorities (frozen contract, log L11).
const AUTH_SOURCE = 9099;
const FIRESTORE_SOURCE = 8080;
const CONNECT_AUTHORITY = 'www.gstatic.com:443';
const PROTECTED_DEMO_PORTS = [9099, 8080, 5001, 4000, 4400, 4500, 9199];

function listen(server) {
  server.listen(0, '127.0.0.1');
  return once(server, 'listening').then(() => server.address().port);
}

async function startUpstream(handler) {
  const server = http.createServer(handler);
  const port = await listen(server);
  return { server, port };
}

function closeServer(server) {
  return new Promise(resolve => server.close(() => resolve()));
}

// Bounded waiter: fails instead of hanging if the wrapped promise never
// settles. The losing timer is unref'd so it never keeps the process alive.
function bounded(promise, label = 'timed out waiting for test event', ms = 5000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label)), ms);
      timer.unref();
    }),
  ]).finally(() => clearTimeout(timer));
}

function nextChunk(stream, ms = 5000) {
  return bounded(
    once(stream, 'data').then(([chunk]) => chunk),
    `timed out waiting for data from ${stream.constructor.name}`,
    ms,
  );
}

function requestViaProxy(proxyPort, target, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      { host: '127.0.0.1', port: proxyPort, method, path: target, headers },
      response => {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString(),
        }));
        response.on('aborted', () => reject(new Error('response aborted')));
        response.on('error', reject);
      },
    );
    request.on('error', reject);
    request.end(body);
  });
}

function connectTunnel(proxyPort, authority) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: '127.0.0.1', port: proxyPort });
    let head = Buffer.alloc(0);
    let settled = false;
    const finish = result => {
      if (settled) return;
      settled = true;
      resolve({ socket, ...result });
    };
    socket.on('data', chunk => {
      if (settled) return;
      head = Buffer.concat([head, chunk]);
      const index = head.indexOf('\r\n\r\n');
      if (index === -1) return;
      const status = Number(/^HTTP\/1\.[01] (\d{3})/.exec(head.toString('latin1'))?.[1]);
      const rest = head.subarray(index + 4);
      if (status === 200) finish({ status, rest });
      else { socket.destroy(); finish({ status, rest: Buffer.alloc(0) }); }
    });
    socket.on('error', error => { if (!settled) { settled = true; reject(error); } });
    socket.on('close', () => finish({ status: 0, rest: Buffer.alloc(0) }));
    socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n\r\n`);
  });
}

function installDialCounter(t, dialTargetPort) {
  let dialCount = 0;
  startIsolatedBrowserProxy._setConnectDialForTests(() => {
    dialCount++;
    return net.connect({ host: '127.0.0.1', port: dialTargetPort });
  });
  t.after(() => startIsolatedBrowserProxy._setConnectDialForTests(null));
  return () => dialCount;
}

test('EI-02 R10: a reset on a denied CONNECT tunnel does not crash the process', async t => {
  const uncaught = [];
  const onUncaught = (error) => uncaught.push(error);
  process.on('uncaughtException', onUncaught);
  const upstream = await startUpstream((_request, response) => response.end('unused'));
  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });
  t.after(async () => {
    process.removeListener('uncaughtException', onUncaught);
    await proxy.close();
    upstream.server.closeAllConnections();
    await closeServer(upstream.server);
  });
  // Chrome opens telemetry tunnels the proxy refuses; the denied path returns a
  // 403 and the browser then resets that socket.
  const socket = net.connect({ host: '127.0.0.1', port: proxy.port });
  await once(socket, 'connect');
  socket.write('CONNECT accounts.google.com:443 HTTP/1.1\r\nHost: accounts.google.com:443\r\n\r\n');
  await once(socket, 'data');
  if (typeof socket.resetAndDestroy === 'function') socket.resetAndDestroy();
  else socket.destroy();
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.deepEqual(uncaught, [], 'a client reset on a denied tunnel must not become an uncaught exception');
});

test('EI-02 R8: keepalive socket reuse does not accumulate close listeners', async t => {
  const remotePorts = new Set();
  const warnings = [];
  const captureWarning = warning => {
    // Any listener type, not just 'close': an 'error' listener added before the
    // ownership guard silently re-introduced the same leak.
    if (warning.name === 'MaxListenersExceededWarning') warnings.push(warning);
  };
  process.on('warning', captureWarning);
  const upstream = await startUpstream((request, response) => {
    remotePorts.add(request.socket.remotePort);
    response.end('keepalive-ok');
  });
  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });
  t.after(async () => {
    await proxy.close();
    upstream.server.closeAllConnections();
    await closeServer(upstream.server);
    process.removeListener('warning', captureWarning);
  });
  for (let i = 0; i < 12; i++) {
    const response = await requestViaProxy(proxy.port, `http://127.0.0.1:${AUTH_SOURCE}/keepalive`);
    assert.equal(response.status, 200);
    assert.equal(response.body, 'keepalive-ok');
  }
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(remotePorts.size, 1, 'the upstream socket must actually be reused');
  assert.equal(warnings.length, 0, 'reusing one socket must not add duplicate close listeners');
});

test('EI-02 R1: streams POST body and response chunks without buffering (WebChannel-style)', async t => {
  let hits = 0;
  let sawRequestEnd = false;
  const requestBodyChunks = [];
  let seeFirstRequestChunk;
  const firstRequestChunk = new Promise(resolve => { seeFirstRequestChunk = resolve; });
  let releaseResponse;
  const responseReleased = new Promise(resolve => { releaseResponse = resolve; });

  const upstream = await startUpstream((request, response) => {
    hits++;
    assert.equal(request.method, 'POST');
    assert.equal(request.url, '/stream');
    request.on('data', chunk => {
      requestBodyChunks.push(chunk);
      seeFirstRequestChunk();
    });
    request.on('end', () => { sawRequestEnd = true; releaseResponse(); });
    response.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
    response.write('first');
    responseReleased.then(() => { response.end('second'); });
  });
  t.after(() => closeServer(upstream.server));

  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });
  t.after(() => proxy.close());

  // Writing before awaiting the response both flushes the request headers and
  // streams the first body chunk while the client request is still open.
  const clientRequest = http.request({
    host: '127.0.0.1',
    port: proxy.port,
    method: 'POST',
    path: `http://127.0.0.1:${AUTH_SOURCE}/stream`,
    headers: { 'content-type': 'text/plain' },
  });
  clientRequest.write('part1');
  const [response] = await once(clientRequest, 'response');

  const firstChunk = await nextChunk(response);
  assert.equal(firstChunk.toString(), 'first', 'first response chunk must stream before upstream ends');

  // The first body chunk reached the owned upstream while the client request
  // was still open: the proxy must not buffer request bodies.
  await firstRequestChunk;
  assert.equal(sawRequestEnd, false, 'upstream must not have seen the request end yet');

  clientRequest.write('part2');
  clientRequest.end();

  const restChunks = [];
  response.on('data', chunk => restChunks.push(chunk));
  await once(response, 'end');
  assert.equal(Buffer.concat(restChunks).toString(), 'second');
  assert.equal(Buffer.concat(requestBodyChunks).toString(), 'part1part2');
  assert.equal(sawRequestEnd, true);
  assert.equal(hits, 1);
});

test('EI-02 R2: rejects non-allowlisted authorities before forwarding, upstream untouched', async t => {
  let hits = 0;
  const upstream = await startUpstream((request, response) => {
    hits++;
    response.writeHead(200);
    response.end('upstream');
  });
  t.after(() => closeServer(upstream.server));

  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });
  t.after(() => proxy.close());

  const rejected = [
    [`http://localhost:${AUTH_SOURCE}/`, 'localhost alias'],
    [`http://127.0.0.2:${AUTH_SOURCE}/`, 'other loopback ip'],
    [`http://127.0.0.1:${FIRESTORE_SOURCE}/`, 'unregistered source authority'],
    [`http://user:pass@127.0.0.1:${AUTH_SOURCE}/`, 'credentials in authority'],
    [`https://127.0.0.1:${AUTH_SOURCE}/`, 'https scheme'],
    ['http://example.com:80/', 'external host'],
    ['http://127.0.0.1:4000/', 'protected demo authority'],
  ];
  for (const [target, label] of rejected) {
    const response = await requestViaProxy(proxy.port, target);
    assert.equal(response.status, 403, label);
    assert.equal(response.body, 'not-allowlisted', label);
  }

  const originForm = await requestViaProxy(proxy.port, '/origin-form');
  assert.equal(originForm.status, 400, 'origin-form target is not an absolute proxy URL');

  assert.equal(hits, 0, 'upstream counter must be unchanged for rejected input');
});

test('EI-02 R3: denies CONNECT before dialing unless exact gstatic authority with flag', async t => {
  let hits = 0;
  const upstream = await startUpstream((request, response) => {
    hits++;
    response.writeHead(200);
    response.end();
  });
  t.after(() => closeServer(upstream.server));
  const dialCount = installDialCounter(t, upstream.port);

  const withoutFlag = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });
  t.after(() => withoutFlag.close());
  const gstaticWithoutFlag = await connectTunnel(withoutFlag.port, CONNECT_AUTHORITY);
  assert.equal(gstaticWithoutFlag.status, 403);
  gstaticWithoutFlag.socket.destroy();

  const withFlag = await startIsolatedBrowserProxy({
    routes: { [AUTH_SOURCE]: upstream.port },
    allowStaticCdn: true,
  });
  t.after(() => withFlag.close());
  for (const authority of ['evil.example.com:443', '127.0.0.1:443', 'www.gstatic.com:80']) {
    const denied = await connectTunnel(withFlag.port, authority);
    assert.equal(denied.status, 403, authority);
    denied.socket.destroy();
  }

  assert.equal(dialCount(), 0, 'denied CONNECT must never dial');
  assert.equal(hits, 0, 'HTTP upstream must never be dialed for CONNECT denials');
});

test('EI-02 R4: tunnels exact www.gstatic.com:443 when allowStaticCdn is true (injected dial seam)', async t => {
  const standin = net.createServer(socket => {
    socket.write('hello-from-owned-standin');
    socket.on('data', chunk => socket.write(Buffer.from(chunk).toString().toUpperCase()));
  });
  const standinPort = await listen(standin);
  t.after(() => closeServer(standin));

  const dialCount = installDialCounter(t, standinPort);

  const proxy = await startIsolatedBrowserProxy({
    routes: { [AUTH_SOURCE]: standinPort },
    allowStaticCdn: true,
  });
  t.after(() => proxy.close());

  const tunnel = await connectTunnel(proxy.port, CONNECT_AUTHORITY);
  assert.equal(tunnel.status, 200);
  assert.equal(dialCount(), 1, 'exactly one dial through the injected seam');

  // The standin greeting may ride in the head buffer or arrive as its own
  // chunk; collect until it is seen.
  let received = tunnel.rest.toString();
  while (!received.startsWith('hello-from-owned-standin')) {
    const chunk = await nextChunk(tunnel.socket);
    received += chunk.toString();
  }

  tunnel.socket.write('ping');
  let reply = '';
  while (!reply.includes('PING')) {
    reply += (await nextChunk(tunnel.socket)).toString();
  }
  assert.ok(reply.includes('PING'), 'tunnel must relay bytes in both directions');
  tunnel.socket.destroy();
});

test('EI-02 R5: invalid options fail with TypeError before any listen or dial', async t => {
  const dialCount = installDialCounter(t, 1);

  const invalid = [
    [{}, 'missing routes'],
    [{ routes: null }, 'null routes'],
    [{ routes: [] }, 'array routes'],
    [{ routes: {} }, 'empty routes'],
    [{ routes: { 9999: 5201 } }, 'unregistered source port'],
    [{ routes: { 9099: '5201' } }, 'non-integer target'],
    [{ routes: { 9099: 0 } }, 'zero target'],
    [{ routes: { 9099: 70000 } }, 'out-of-range target'],
    ...PROTECTED_DEMO_PORTS.map(port => [{ routes: { [AUTH_SOURCE]: port } }, `protected demo target ${port}`]),
    [{ routes: { [AUTH_SOURCE]: 5201 }, allowStaticCdn: 'yes' }, 'non-boolean flag'],
    [{ routes: { [AUTH_SOURCE]: 5201 }, onRequest: 'log' }, 'non-function onRequest'],
  ];
  for (const [options, label] of invalid) {
    await assert.rejects(
      startIsolatedBrowserProxy(options),
      error => { assert.ok(error instanceof TypeError, label); return true; },
      label,
    );
  }
  assert.equal(dialCount(), 0, 'invalid options must never dial');
});

test('EI-02 R6: close() aborts pending work, refuses new connections, and is idempotent', async t => {
  const upstream = await startUpstream((request, response) => {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.write('held'); // never ends: forces an in-flight streamed response
  });
  t.after(() => closeServer(upstream.server));

  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port } });

  let settle;
  const outcome = new Promise(resolve => { settle = resolve; });
  let firstChunkResolve;
  const firstChunkPromise = new Promise(resolve => { firstChunkResolve = resolve; });
  const chunks = [];
  const request = http.request({
    host: '127.0.0.1', port: proxy.port, method: 'GET',
    path: `http://127.0.0.1:${AUTH_SOURCE}/held`,
  }, response => {
    response.on('data', chunk => {
      chunks.push(chunk);
      firstChunkResolve(chunk);
    });
    response.on('aborted', () => settle({ aborted: true, via: 'response aborted', chunks }));
    response.on('error', error => settle({ aborted: true, via: 'response error', code: error.code, chunks }));
    response.on('end', () => settle({ aborted: false, via: 'response end', chunks }));
  });
  request.on('error', error => settle({ aborted: true, via: 'request error', code: error.code, chunks: [] }));
  request.end();

  const firstChunk = await bounded(firstChunkPromise);
  assert.equal(firstChunk.toString(), 'held');

  await proxy.close();
  const abort = await bounded(outcome);
  assert.equal(abort.aborted, true, `in-flight response must be aborted on close (${abort.via})`);
  assert.ok(
    Buffer.concat(abort.chunks).toString().startsWith('held'),
    'aborted response must have streamed its first chunk before close',
  );

  const refused = net.connect({ host: '127.0.0.1', port: proxy.port });
  const [refusalError] = await once(refused, 'error');
  assert.equal(refusalError.code, 'ECONNREFUSED', 'closed proxy must refuse new connections');

  await proxy.close(); // idempotent
  await closeServer(upstream.server); // completes only when no orphan connection remains
});

test('EI-02 R7: onRequest receives exact metadata only (no body, query, or credentials)', async t => {
  const events = [];
  const onRequest = event => events.push(event);

  let hits = 0;
  const upstream = await startUpstream((request, response) => {
    hits++;
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.end('canary');
  });
  t.after(() => closeServer(upstream.server));

  const standin = net.createServer(socket => {
    socket.on('data', chunk => socket.write(Buffer.from(chunk).toString().toUpperCase()));
  });
  const standinPort = await listen(standin);
  t.after(() => closeServer(standin));
  const dialCount = installDialCounter(t, standinPort);

  const proxy = await startIsolatedBrowserProxy({ routes: { [AUTH_SOURCE]: upstream.port }, onRequest });
  t.after(() => proxy.close());

  const forwarded = await requestViaProxy(proxy.port, `http://127.0.0.1:${AUTH_SOURCE}/canary?token=secret-token`);
  assert.equal(forwarded.status, 200);
  assert.deepEqual(events.at(-1), {
    kind: 'http',
    authority: `127.0.0.1:${AUTH_SOURCE}`,
    targetPort: upstream.port,
    method: 'GET',
  });

  await requestViaProxy(proxy.port, `http://localhost:${AUTH_SOURCE}/`);
  assert.deepEqual(events.at(-1), { kind: 'http-denied', authority: `localhost:${AUTH_SOURCE}`, method: 'GET' });

  const denied = await connectTunnel(proxy.port, CONNECT_AUTHORITY);
  assert.equal(denied.status, 403);
  denied.socket.destroy();
  assert.deepEqual(events.at(-1), { kind: 'connect-denied', authority: CONNECT_AUTHORITY });

  const withFlag = await startIsolatedBrowserProxy({
    routes: { [AUTH_SOURCE]: upstream.port },
    allowStaticCdn: true,
    onRequest,
  });
  t.after(() => withFlag.close());
  const tunnel = await connectTunnel(withFlag.port, CONNECT_AUTHORITY);
  assert.equal(tunnel.status, 200);
  tunnel.socket.destroy();
  assert.deepEqual(events.at(-1), { kind: 'connect', authority: CONNECT_AUTHORITY });

  assert.equal(hits, 1);
  assert.equal(dialCount(), 1, 'only the allowlisted CONNECT dialed through the seam');
  assert.ok(!JSON.stringify(events).includes('secret-token'), 'metadata must never carry query or credentials');
  for (const event of events) {
    assert.ok(
      Object.keys(event).every(key => ['kind', 'authority', 'targetPort', 'method'].includes(key)),
      `unexpected metadata keys: ${JSON.stringify(event)}`,
    );
    assert.ok('kind' in event && 'authority' in event, `metadata must carry kind and authority: ${JSON.stringify(event)}`);
  }
});
