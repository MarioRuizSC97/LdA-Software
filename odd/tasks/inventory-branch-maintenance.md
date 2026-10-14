# Inventory Branch Maintenance

## Intent and authorization
Improve the already-closed branch without expanding product functionality: safely register transfer tests, correct signed quantity formatting, reconcile stale documentation, and format one pre-existing test file.
User selected `branch-followups-maintenance`, then explicitly authorized inclusion of the three existing transfer acceptance JavaScript files and local maintenance commits (`maintenance-package-transfer-tests-local-commits`). No push, PR, merge or deployment is authorized.
Branch: `feat/inventory-mvp-seller-profiles-v2`. Starting HEAD: `3b38df8c3a60fb0888930c9c56076f2c753e11c9`. Preflight: canonical root/branch/HEAD verified; no tracked changes or staged paths; default hooks and zero active hooks. New maintenance tracker and formatter test did not exist.

## Boundaries
- Single bounded writer at a time; parent owns this ledger, its full Engram mirror, task projection and commits.
- Preserve `CLAUDE.md`, runtime logs and the untracked acceptance tracker. Only the three expressly authorized JavaScript acceptance files may be included; no sweeping staging.
- Keep the existing isolated runner and its two existing tests byte-identical when packaging them. Do not add emulator suites to the shared default emulator lane.
- No demo calls, runtime launches/restarts/refreshes, browser/device launches, dependency resolution/downloads, backend business logic/rules changes, tooling updates or publication.
- Seller-profile emulator suites require a different Auth/Firestore isolation design; this is a disclosed follow-up, not part of this maintenance unit.
- Destination notices, requests/grants/retention and broader refactoring remain deferred. General INV-06 stays open.
- Never reopen burned reviews or infer old native review approval from task closure. Follow current native continuations only when applicable to the new work-unit candidate.

## Workload and delivery
Forecast: roughly 2,000–2,250 added/deleted lines, predominantly the approximately 1,875 existing acceptance lines newly versioned. This is not a new 1,875-line implementation.
Keep three cohesive local work units; do not minify, remove tests, or split the existing runner from the tests it needs. The packaging unit naturally exceeds the advisory 400-line heuristic; its three-file scope and approximate size were explicitly presented and approved.
Delivery strategy: `ask-on-risk`, resolved by the user's selection `chain_strategy=feature-branch-chain`. Future review slices: MB-01 formatter, MB-02 isolated test packaging, MB-03 documentation/format closure, in that order. The packaging slice remains cohesive despite its size. No extra branch, tracker PR, push, PR creation or merge is authorized now; verify the default branch before any future branch/PR construction.
Running committed authored lines: 0. Maintenance commits: none yet.

## Tasks and routes
- [ ] MB-01 — Correct `formatScaledQuantity` negative formatting with a dedicated regression test. Status: implementation and independent checks passed; local commit and applicable candidate review pending. Route: delegated writer; two non-trivial Dart surfaces trigger delegation. Surfaces: `lib/sales/sale_format.dart`, new `test/sales/sale_format_test.dart`. Observe deterministic RED before the fix, then GREEN; preserve positive/zero/precision-zero behavior and `formatCentavos`/`formatMoney`. Commit and candidate checks pending.
- [ ] MB-02 — Register safe isolated transfer tests as a coherent package. Status: pending. Route: delegated writer for registry/test changes; parent explicitly stages existing preserved acceptance files. Surfaces: `functions/package.json`, new `functions/test/package-scripts.test.mjs`; package unchanged `functions/scripts/test-transfers-isolated.mjs`, `functions/test/transfers-isolated-runner.test.mjs`, `functions/test/transfers.emulator.test.mjs`. Registry regression must fail before the package edit; mocked runner/unit tests must not launch services. Actual emulator acceptance will not run in this pass.
- [ ] MB-03 — Reconcile historical source-commit notes, retain the open/deferred MVP boundary, and format the catalog test. Status: pending. Route: delegated writer; multiple documentation surfaces. Surfaces: `odd/tasks/ios-emulator-support.md`, `odd/tasks/catalog-load-diagnostics.md`, `odd/tasks/catalog-branch-code-compatibility.md`, `odd/tasks/inventory-mvp.md`, `test/catalog/catalog_product_test.dart`. Preserve historical findings, scope and native receipt identifiers. Passive documentation/format has no meaningful behavioral RED; run structural and catalog regression checks instead. Run the applicable cached full Flutter suite/analyzer and backend unit tests at final closure, without launching emulators.

## Verification contract
Use cached Flutter `/Users/luismarioruiz/develop/flutter/bin/flutter` with `FLUTTER_SUPPRESS_ANALYTICS=true`, `--no-version-check`, `--no-pub`; cached Dart `/Users/luismarioruiz/develop/flutter/bin/cache/dart-sdk/bin/dart`. No `pub get` or installs. Node mocked/unit checks must be read from the package scripts and run without emulator execution; runtime pin availability must be verified without dumping environment/identity values.
Before mutations verify fresh root/branch/HEAD/index and scoped blobs; unexpected drift stops work without cleanup. Capture bounded command results, counts, original and final scoped hashes and explicit failed/skipped checks. Meaningful behavior changes use test-first; packaging existing files does not fabricate a new RED for old code.
After a delegated writer returns, parent follows the native read-only assessment plan for the exact candidate and applicable independent verification. Source-mutating units use the user-owned RDD setting and the offered native preflight/continuation; no model-authored authority.

## Progress and remaining checks
Parent created and mirrored this ledger before the first source write. MB-01 writer `mv8lxfei-2c-noaf` changed only the formatter (+7/-2) and added a 46-line, five-test regression file. RED on original source: three passed/two failed, with `-5@1` expected `-0.5`, actual `0.5`. GREEN: all five passed, including after formatting. All 63 sales tests (six files, including the five new tests) passed; analyzer two items clean; format two files unchanged; whitespace clean.
Native ASSESS returned unassessable (undeclared untracked files), RDD on/outcome unknown; high-risk fallback required independent verification. Verifier `mv8m3ql2-2d-8jpu` independently observed 63 sales tests passing, analyzer two items clean, format two unchanged, whitespace clean, and 14 scoped hashes/status stable. RED is writer-recorded, not reconstructed by reverting. No service launch or dependency resolution occurred.
Verification deviation: the verifier invoked `git write-tree`, which is not a read-only command. Its result matched an existing HEAD tree, but prior index-byte evidence is unavailable; no historical index-byte identity is claimed. Separate parent read-only inspection confirmed expected HEAD/branch, no staged paths, and only the authorized tracked formatter change. No cleanup or repeat invocation was performed.
MB-01 remains in progress until its local work-unit commit and applicable candidate checks complete. MB-02/03 are not started. Local commit IDs and native outcomes will be recorded after execution.
Actual isolated emulator acceptance, real Chrome, real Android/iOS disk/power-loss survival, multi-tab behavior and production Auth/CORS/deployment checks remain unexecuted and outside this pass.
Feature mirror: `odd/inventory-branch-maintenance/tasks` in project `lda-software`.
