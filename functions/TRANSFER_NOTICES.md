# Destination transfer notice acknowledgements (DN-01, backend)

Trusted read acknowledgement for seller destination transfer notices. The
existing administrator transfer operation (`transferInventory`), its private
audit and stock semantics are unchanged: this module only reads the private
audit and writes per-seller read markers.

## Callable contract: `markTransferNoticeRead`

- Emulator-only v2 callable (`us-south1`, localhost web origins only). The
  inventory environment guard runs before Admin SDK initialization, so a
  copied or deployed function can never reach cloud Firestore.
- Input: exactly `{ transferId }`. Anything else (extra fields, missing field,
  non-string, wrong shape, identifiers outside
  `/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/` or longer than 112 characters) is an
  `invalid-argument` refusal before any document is read.
- Identity: `request.auth` must be a signed-in seller; `uid` and `branchId`
  always come from the verified token claims. The client can never supply a
  uid, branch or timestamp. The uid contract mirrors the existing client
  reader (`isPathSafeUid` in `lib/movements/inventory_movement.dart`) and the
  server `validTargetUid` precedent (`sellerProfiles.js`): a nonempty string of
  at most 128 characters with no `/` or `\`, no control characters
  (`\u0000-\u001F\u007F`), never `.` or `..`, and never a reserved `__...__`
  id — without trimming, case folding or Unicode normalization, so the
  validated string is the exact marker path segment. The branch must match
  `/^branch-[a-z0-9]+(?:-[a-z0-9]+)*$/`. A uid or branch outside the contract
  is refused as `unauthenticated`/`permission-denied` before any read.
- Authorization: the private `transfers/{transferId}` audit is read
  server-side and its `destinationBranchId` must equal the token branch. A
  missing audit, a foreign destination branch and a corrupt audit share
  fail-closed answers (`not-found` with one neutral message, or
  `failed-precondition` for corruption) so audit existence and content never
  leak to a seller.
- Success: transactionally creates
  `transferNoticeReads/{uid}/branches/{branchId}/transfers/{transferId}`
  containing exactly `userId`, `branchId`, `transferId`, `readAt` (server
  `Date`), and returns exactly `{ transferId, branchId, read: true }`.
- Replay: an existing well-formed marker returns the same acknowledgement
  without writing; the original `readAt` is preserved even when the current
  clock is broken. A damaged or conflicting stored marker (wrong
  userId/branchId/transferId, non-timestamp `readAt`, extra or missing fields)
  fails closed with `failed-precondition` and is never overwritten.

## Firestore rules

- `transferNoticeReads/{uid}/branches/{branchId}/transfers/{transferId}`:
  `get`/`list` only for the seller whose token role is `seller`, whose token
  branch equals the path `branchId`, and whose auth uid equals the path `uid`.
  Every client write, including owner and administrator, is denied.
- `transfers/{transferId}` (the private pair audit) stays closed to every
  client SDK read and write; the destination/source branches never reach a
  client outside trusted server code.
- All other paths remain closed by the pre-existing catch-all rule.

## Tests

- `functions/test/transfer-notices.test.mjs` — pure unit regressions on an
  in-memory Firestore double (environment guard, identity and path-safe uid
  gates, exact marker shape, replay/readAt preservation, conflicting markers,
  invalid inputs). The callable portion mirrors
  `sellerProfiles-callable.test.mjs`: `src/index.js` is loaded through
  `registerHooks` seam modules so no `firebase-admin` module is ever resolved
  or initialized, and every callable Firestore operation lands in the injected
  in-memory double. A dedicated isolation regression asserts that no real
  Admin SDK module is ever resolved — the earlier version of this suite called
  the real callable under an emulator-pointed environment, which attempted a
  real credential/metadata fetch and could have written a marker into a
  running demo emulator; that exposure is now impossible by construction.
  Rides the default `npm test` lane.
- `firebase/tests/transfer-notice-rules.test.mjs` — public-service rules proof
  for the marker paths. It mutates emulator data, so it refuses to run unless
  the isolated emulator address is supplied twice (opt-in and
  `FIRESTORE_EMULATOR_HOST`, both `127.0.0.1:8280`); it never targets the
  developer's main runtime on port 8080 and never a live project. Requires
  fresh parent authorization to start the isolated emulator:

  ```sh
  LDA_TRANSFER_NOTICE_RULES_EMULATOR=127.0.0.1:8280 \
  FIRESTORE_EMULATOR_HOST=127.0.0.1:8280 \
  node --test firebase/tests/transfer-notice-rules.test.mjs
  ```

Existing transfer behaviour is pinned by `functions/test/transfers.test.mjs`;
run both together with
`cd functions && node --test test/transfers.test.mjs test/transfer-notices.test.mjs`.

## Isolated destination-notice E2E harness (EI-03, infrastructure only)

This section documents test infrastructure only. The callable contract,
Firestore rules and marker semantics above are unchanged; no application,
authentication or business surface is touched by anything below.

### What the harness proves (one clean run, owned processes only)

A real Chrome for Testing browser (project-local, S6) drives the public Flutter
web UI of an isolated build (`LDA_LOCAL_EMULATORS=true`, explicit
`--web-build`, never the default `build/web`) against isolated Auth/Firestore
Functions emulators, proving through public UI assertions only:

1. Seller 1 (north) signs in first and its inbox is provably empty.
2. While seller 1's session stays open, the administrator performs an actual
   UI transfer of 1 Demo Coffee from the south branch to the north branch
   (south stock 3 is seeded as disposable fixture data).
3. Seller 1 sees the unread notice live, without a reload, and explicitly
   marks it read in the UI.
4. The browser context is disposed and recreated; seller 1 logs in again and
   the notice stays read with history retained.
5. Seller 2 (same north branch, fresh session) is still independently unread.

### Frozen isolation contract (task log L10/L11)

- Browser-visible authorities route through the frozen writer-A proxy
  (`functions/scripts/isolated-browser-proxy.mjs`,
  `startIsolatedBrowserProxy({routes, allowStaticCdn, onRequest})`):
  Auth `9099->8299`, Firestore `8080->8280`, Functions `5001->5201`, app web
  `7358->7358`. Proxy and CDP ports are ephemeral; `allowStaticCdn` covers
  `www.gstatic.com` only (S8).
- The run binds only owned ports: 8299, 8280, 5201, 7358, hub 7440 and the
  Firestore websocket 7460. It never binds or contacts the protected demo
  ports (9099/8080/5001/4400/4500/4000/9299/9499/9150/7357); their listener
  fingerprints are snapshotted before and re-checked after teardown without
  querying demo data. Busy owned ports are refused before anything spawns.
- The Firebase CLI runs with a generated `--config` (UI disabled, hub 7440,
  websocket 7460), `--only auth,firestore,functions`,
  `--project demo-lda-inventory`, a redirected HOME/XDG_CONFIG_HOME/CLOUDSDK
  inside the run folder, `FIREBASE_EMULATORS_PATH` pointing at a run-folder
  cache that contains a symlink to the already-cached
  `cloud-firestore-emulator-v1.22.0.jar` — so the CLI can never auto-download
  an emulator or read a global profile. Cloud credentials (`FIREBASE_TOKEN`,
  `GOOGLE_APPLICATION_CREDENTIALS`) and conflicting emulator/proxy/Java env
  are refused or scrubbed; the disposable fixture child is a fresh process
  that imports the real Admin SDK only after its env points at 8299/8280.
- Fixtures are disposable (`notice-e2e-*` accounts, two sellers of
  `branch-north`, south stock 3). Seeding is structurally forbidden from
  writing `transfers/` audits or `transferNoticeReads/` markers: the notice
  flow must be produced by the actual UI transfer, never by setup.
- The browser is spawned only from `.dart_tool/e2e-browser/...Google Chrome
  for Testing`, headless, with a disposable per-session profile and mandatory
  `--proxy-server=http://127.0.0.1:<port>` plus
  `--proxy-bypass-list=<-loopback>`; no DIRECT fallback, no sandbox-disabling
  flags, no personal profiles. CDP is loopback-only over Node 24's built-in
  WebSocket; input is dispatched at bounds taken from the live Flutter
  semantics tree (enabled through the engine's own accessibility placeholder),
  never at fixed coordinates and never via SDK/RPC injection.
- Teardown is bounded (SIGTERM then SIGKILL, addressed only to process groups
  this run spawned), then the runner verifies every owned port is released and
  the demo fingerprints are unchanged. Any failure is a non-zero exit with
  stage evidence (screenshots, semantics snapshot, console log) under
  `.dart_tool/notice-e2e/<run-id>/`; there are no retries.

### Running it

Writer/CI-safe checks only (no services, no browser, no emulators):

```sh
cd functions
~/.local/share/lda-node24/runtime/bin/node scripts/transfer-notice-e2e.mjs --help
~/.local/share/lda-node24/runtime/bin/node scripts/transfer-notice-e2e.mjs \
  --dry-run --web-build .dart_tool/notice-e2e-build/<id>/web
~/.local/share/lda-node24/runtime/bin/node --test test/transfer-notice-e2e.test.mjs
```

The real E2E is parent-authorized only and requires an isolated web build
(sibling `build-manifest.json` with `LDA_LOCAL_EMULATORS=true`):

```sh
cd functions
~/.local/share/lda-node24/runtime/bin/node scripts/transfer-notice-e2e.mjs \
  --run --web-build .dart_tool/notice-e2e-build/<id>/web
```

The app build command that produced it (parent-owned, no downloads):

```sh
flutter build web --release --no-pub --no-web-resources-cdn --no-wasm-dry-run \
  --output .dart_tool/notice-e2e-build/<id>/web \
  --dart-define=LDA_LOCAL_EMULATORS=true
```

### Safety tests

`functions/test/transfer-notice-e2e.test.mjs` pins the fail-closed lifecycle
with injected doubles only: CLI surface semantics, environment scrubbing,
frozen ports/routes, fixture purity (no audit/marker seeding), generated
provisioning script constraints, owned web-server behaviour, Chrome flag
contract, CDP plumbing over a fake WebSocket, busy-port/pinned-node refusals
before spawning, teardown on seed failure, and a full fake-doubles pass over
the five public-UI stages with clean teardown verification.
