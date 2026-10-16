# Isolated emulator E2E environment

This document describes how to stand up and run the **isolated** emulator
environment used to prove browser flows end to end, completely apart from the
developer's demo. It is written so the same environment can be reused for other
browser tests later, not only for transfer notices.

Nothing here touches the running demo: the demo keeps its own ports
(`9099`, `8080`, `5001`) and its own `build/web`, and the isolated run refuses to
bind or serve either.

---

## 1. Frozen topology

| Purpose | Browser-visible | Owned isolated |
| --- | --- | --- |
| Auth | `9099` | `8299` |
| Firestore | `8080` | `8280` |
| Functions (callables) | `5001` | `5201` |
| App web server | `7358` | `7358` |
| Emulator hub | – | `7440` |
| Firestore websocket | – | `7460` |
| Browser proxy + CDP | – | ephemeral |

* Project id: `demo-lda-inventory` (a demo project, so the CLI never reaches a
  real Firebase project).
* Owned ports are `8299`, `8280`, `5201`, `7440`, `7460`, `7358`. Every one of
  them must be free before a run starts; the runner refuses to start otherwise.
* The browser only ever sees the left column. The owned proxy forwards
  `9099 -> 8299`, `8080 -> 8280`, `5001 -> 5201` and `7358 -> 7358`, so the
  application keeps its default endpoints and its guards intact.

## 2. Authorized local runtimes

These are the only runtimes a run may use. Everything is read-only and nothing is
ever installed or downloaded; changing any path needs a new operator
authorization.

| Runtime | Authorized path |
| --- | --- |
| Pinned Node (v24.21.0) | `/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node` |
| firebase-tools CLI | `/Users/luismarioruiz/.local/share/lda-firebase-tools/` |
| Cached Firestore jar (1.22.0) | `/Users/luismarioruiz/.cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar` |
| Java | `/usr/bin/java` |
| Flutter SDK | `/Users/luismarioruiz/develop/flutter/` |
| Chrome for Testing 155.0.8059.79 | `.dart_tool/e2e-browser/` (project-local, disposable profiles) |

Network egress is limited to `www.gstatic.com:443` (static Flutter/Firebase
assets) through the owned proxy. Every other external destination is denied, and
there is no DIRECT fallback: the browser is started with
`--proxy-server=http://127.0.0.1:<port>` and `--proxy-bypass-list=<-loopback>`.

## 3. Build the isolated web bundle

The runner refuses to start without a *provenance* manifest, because a bundle
compiled with the wrong defines — or a stale one — would silently test something
other than the isolated routing. Build it with the generator:

```sh
node functions/scripts/build-isolated-web-bundle.mjs \
  --flutter /Users/luismarioruiz/develop/flutter/bin/flutter
```

It writes a fresh pair, never `build/web`:

```
.dart_tool/notice-e2e-build/<UTC stamp>-<pid>/web/                 Flutter output
.dart_tool/notice-e2e-build/<UTC stamp>-<pid>/build-manifest.json  provenance
```

The generator runs exactly these frozen arguments:

```sh
flutter build web --release --no-pub --no-web-resources-cdn \
  --no-wasm-dry-run --dart-define=LDA_LOCAL_EMULATORS=true --output <out>/web
```

`--dart-define=LDA_LOCAL_EMULATORS=true` is what makes the application talk to
the emulator endpoints. The manifest records `dartDefines`, `buildExitCode`,
per-file source hashes, `sourceTreeSha256` and `webMainSha256`; the runner
(`assertWebBuild`) accepts the bundle only when `build-manifest.json` exists,
declares `LDA_LOCAL_EMULATORS=true` and records `buildExitCode: 0`.

## 4. Run the isolated flow

```sh
node functions/scripts/transfer-notice-e2e.mjs --run \
  --web-build .dart_tool/notice-e2e-build/<UTC stamp>-<pid>/web
```

Other modes: `--help` prints the frozen contract, `--dry-run` plans a run
without starting anything. A run refuses to start when cloud credentials or
conflicting emulator overrides are present in the environment, when Node is not
the pinned runtime, or when any owned port is already bound.

## 5. Stages and where the evidence lands

Stages: `preflight`, `emulators`, `functions`, `isolated-rules`, `seed`,
`proxy`, `app-web-server`, `seller1-before`, `admin-transfer`,
`seller1-live-read`, `seller1-fresh-session`, `seller2-independent`, plus one
teardown stage per owned browser.

Everything is written under `.dart_tool/notice-e2e/<runId>/`:

| File | Content |
| --- | --- |
| `result.json` | final label (`notice-e2e-run` / `notice-e2e-run-failed`), stages, error |
| `stages.log` | timestamped stage log and spawn notes |
| `evidence/` | screenshots and semantics dumps per stage, including the failing one |
| `emulator-cli.log` | CLI output: which callables loaded, port bindings, shutdown |
| `firestore-debug.log`, `proxy-audit.log` | Firestore activity and proxy metadata (no bodies, no tokens) |
| `firebase.json`, `functions/`, `firestore.rules`, `firestore.indexes.json` | the run-local config and the links to the repository sources |
| `profiles/` | disposable browser profiles |

`functions` and `isolated-rules` exist because bound ports prove nothing: the
runner reads back the CLI log to confirm the callables really deployed, and
probes the isolated Firestore with a client that has no credentials to confirm
the repository rules are in force (a `200` would mean they are not).

## 6. Isolation guarantees

* **Fresh child environment:** `HOME`, `XDG_*` and `CLOUDSDK_*` are redirected
  into the run folder; cloud credentials are refused outright.
* **Sources are linked, never copied:** `firebase-tools` resolves config sources
  against the config file's own directory *and refuses anything outside it*, so
  the run contains links to `functions/`, `firestore.rules` and
  `firestore.indexes.json` and names them plainly in `firebase.json`.
* **No downloads:** the cached Firestore jar is linked into the run cache, so the
  CLI's download path never fires. The web bundle is built ahead of time.
* **Browser:** project-local Chrome for Testing, disposable profile, mandatory
  proxy, no personal profile, no sandbox-disabling flags.
* **Proxy:** exact loopback authorities only; `CONNECT` only for
  `www.gstatic.com:443`; logs carry kind/authority/target port/method only.
* **Data:** disposable identities and records created by the run itself. No demo
  data is read or written, and the demo build is never served or overwritten.

### CONNECT establishment deadline

The proxy bounds only the initial connection to the allowed static CDN:
`startIsolatedBrowserProxy({ routes, allowStaticCdn, connectTimeoutMs })` defaults
to `connectTimeoutMs: 10000`. Overrides must be integer milliseconds in
`1..120000`; invalid values are rejected before listening or dialing.
A pending connection that expires returns HTTP `504 Gateway Timeout` and destroys
the upstream socket without retrying. The deadline is cleared on connection,
error or closure. Established tunnels and streamed HTTP/Firestore responses do
not acquire an overall or idle deadline from this option.

## 7. Cleanup, and cleanup after a crash

A run tears down every browser, the proxy, the web server and the CLI, then
verifies that the owned ports are released and that the demo fingerprints are
unchanged. If the process dies on an uncaught exception or an unhandled
rejection, a crash handler runs the same teardown (once) and exits non-zero, so a
crash cannot leave an emulator or a browser behind.

A failed post-teardown port or fingerprint probe fails the run without skipping
log closure, termination unsubscription or the result write. It never counts as
proof that the owned ports were released or that the demo listeners are unchanged.
Finalization attempts to close every owned log and remove the termination
subscription even if another finalization step fails. The first run failure is
preserved; if the run otherwise succeeded, a log-close or subscription-removal
failure makes the run fail instead. `result.json` is written after these attempts
so it includes that outcome when the write succeeds. If writing the result fails,
the runner still rejects with the first failure, but cannot guarantee the artifact.

## 8. Reusing the environment for other browser tests

* The fixture is disposable data only: extend `NOTICE_FIXTURE` / the seed script
  builder in `functions/scripts/transfer-notice-e2e.mjs` rather than seeding
  business outcomes you intend to prove.
* New stages belong inside `stageGuard(...)`, which captures a screenshot, the
  console and the semantics dump when a stage fails — that is what made every
  real failure in this environment diagnosable.
* Drive only the public UI. A flow that injects SDK calls, RPCs or controller
  state proves nothing about the application.
* Plumbing helpers live in `functions/scripts/transfer-notice-e2e-browser.mjs`
  (semantics tree, CDP input, typing) and
  `functions/scripts/isolated-browser-proxy.mjs` (proxy).
* Bundle production lives in `functions/scripts/build-isolated-web-bundle.mjs`.

## 9. Verifying the environment itself

```sh
node --test functions/test/transfer-notice-e2e.test.mjs \
            functions/test/isolated-browser-proxy.test.mjs \
            functions/test/build-isolated-web-bundle.test.mjs
```

These suites never start an emulator or a browser: every child, listener, proxy,
page, filesystem write and clock is an injected double. A real acceptance run
ended with `exit: success` in `.dart_tool/notice-e2e/d5b0e38b-a0cc-4af8-8fbc-31cd5e054e51/result.json`
(administrator transfer, live seller notice, explicit read, fresh-session
persistence and a second independently unread seller).
