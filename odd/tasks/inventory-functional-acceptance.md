# Inventory Functional Acceptance in A

## Objective and authorization

Verify real local HTTP/Auth functionality in A: authentication, branch-scoped catalog access, product creation/pricing/intake, seller sales, permission failures, replay, and stock effects. The user approved temporary owned data, three isolated test files, and local work-unit commits. No product-code changes, installs/downloads, production/cloud/ADC, emulator start/restart, fixture resets, browser-tool installation, or publication.

## Verified baseline

A is `/Users/luismarioruiz/LdA-Software`, branch `feat/inventory-mvp-admin-stock-intake`, HEAD `6e096cc12898b542069dbc43d70ee429c7e6b494`; only empty untracked `CLAUDE.md`. B remains unchanged. Prior 540 offline tests passed, but they are not real HTTP/Auth acceptance.

Existing services: Auth `127.0.0.1:9099`, Firestore `127.0.0.1:8080`, Functions `127.0.0.1:5001`, explicit project `demo-lda-inventory`, region `us-south1`. Hub/UI are active; Storage is not. Callable routing includes `createProduct`, `setProductPrice`, `stockIntake`, and `submitSale`. Routing/cwd evidence supports readiness but is not exact loaded-byte attestation. Revalidate these gates before any data write.

Browser automation is unavailable. API/rules assertions are in scope; visual/browser sign-in, CORS acceptance, Storage, and builds must remain explicitly unverified. Do not substitute widget tests or injected sale services for transport evidence.

## Isolation and teardown

Use fresh UUID Auth users and a pattern-valid `branch-<uuid>` branch; never touch demo users, shared branches, existing products, or claims. Seed only the owned branch and identities via explicit emulator-only Admin SDK; exercise product creation/pricing/intake/sales through real callable HTTP envelopes and fresh emulator tokens.

Prepare cleanup manifests before writes. Create-only users/documents, capture creation receipts/timestamps, bind dynamically generated PRD product IDs to owned creation keys/names/results, and enumerate every exact derived artifact. Auth deletion requires uid, creation timestamp, and expected current claims/marker agreement. Firestore cleanup requires matching linkage and ownership, not a UUID substring alone. Retain ambiguous resources and report them. No bulk/global clearing or unsafe shared-fixture test runners.

Keep credentials/tokens in memory; never print or persist them. Explicit project/hosts must be pinned before SDK initialization, with no redirects/proxy/ADC/default-project fallback. The five consumed B diagnostic grants do not authorize any sandbox retry.

## Tasks and routes

- [ ] FUNC-01 — Implement the pure owned-Auth lifecycle/cleanup helper and deterministic safeguards. Route: one bounded writer over `functions/test/owned-auth-manifest.mjs` and `functions/test/owned-auth-manifest.test.mjs`. Observe applicable RED/GREEN/refactor; no live emulator calls. Independent verification follows native assessment as required; close a local work-unit commit.
- [ ] FUNC-02 — Add `functions/test/sales-callable-transport.emulator.test.mjs` for the actual HTTP/Auth acceptance flow. Route: bounded writer, reuse proven Firestore support only where its ownership contract covers all new artifact shapes; never edit the proven support module. Verify parsing, gates, teardown-first behavior, and the exact fixture/path plan before launching. No data writes during preparation; close a local work-unit commit.
- [ ] FUNC-03 — Execute authenticated local API/rules acceptance against existing services. Route: delegated verifier after source/project/endpoint/ownership gates pass. Cover administrator product/price/intake, seller catalog and sale, anonymous/unassigned/wrong-role denials, validation failures, replay, stock/movement/audit consistency, and owned cleanup. Protect baseline fixtures; no live run until teardown is prepared.
- [ ] FUNC-04 — Reconcile evidence and local commits; report failed/skipped/pending checks and manual visual follow-up. Route: parent tracking/review/delivery with independent readback. No overall INV-05 closure or native approval claim without actual evidence.

## Acceptance and review

Real HTTP responses and actual emulator Auth identities must drive cases; Admin reads may verify only owned artifacts. Emulated token acceptance does not prove production cryptographic token verification. Cleanup and preserved fixtures are acceptance criteria, not optional housekeeping.

The initial forecast was around 400 authored lines for the feature. FUNC-01 alone contains 574 source/test lines (259 helper + 315 tests), plus this document; the writer exceeded its 200–300-line target and stop-before-expansion instruction. One honest read-only slicing pass found both a cohesive unit and serial plan/provision versus cleanup units feasible. The user explicitly selected the corrected cohesive unit, accepting an estimated 650–750 source/test lines before its local commit. The first correction produced 749 lines (325 helper + 424 tests). The residual-context correction is independently verified at 746 lines (326 helper + 420 tests); shared child-test scaffolding was consolidated without dropping either deadline scenario. This document is additional tracking evidence. This is not blanket size approval for the unwritten HTTP harness. Stop before exceeding that correction estimate or adding files/areas. Keep all safeguards; no line-golf or file-type splitting. Delivery remains local only; no PR/push or generic repository size-label authority. Native review runs only under the existing RDD switch; assessment/preflight failures use the returned verification fallback, not repeated repair or switch changes.

## Evidence and progress

- Read-only preflight: `muycvob9-10-32yt`; active demo routing/services, Storage absent, browser tooling unavailable.
- One read-only premise challenge: `muyd2a9g-11-w1mz`; fresh UUID branches/users are supported, no UID whitelist, no demo provisioning required. Existing OwnedRun has no Auth lifecycle; existing transport tests omit submitSale and use shared fixtures, so do not run them blindly.
- User selected `authorize_owned_http_auth_tests_and_local_commits`.
- FUNC-01 writer: `muydha55-12-wbvx`; two new files only. Reports behavior-stub RED 0/16 pass. Independent audit `muye21pk-13-b7zi` reproduced GREEN 16/16 and syntax checks, but could not reproduce historical RED.
- Native ASSESS: unassessable (untracked declaration required), RDD on, outcome unknown; high-risk plan requires an independent verifier. No lineage, approval, staging, or commit claimed.
- Initial overall audit verdict: BLOCKED. Exposed claims aliases could poison cleanup ownership; unreferenced deadlines could exit unsettled; optional SDK claims and ambiguous claim errors needed explicit regression coverage. RPC timeout does not cancel late server mutations.
- User selected `approve_corrected_cohesive_auth_unit_size`; correct and verify one cohesive unit, not a code-only/test-only split.
- Correcting writer: `muyegx14-14-ln1h`; reports new regression RED 16/20 pass against the old implementation, then GREEN 20/20 and syntax checks. Reports private WeakMap authority/frozen baselines/copied views, referenced self-clearing deadlines, undefined-only empty claims normalization, and permanent retention on all SDK claim-setting failures. Deliberate `setClaims:false` is the only initial-empty cleanup path; no late RPC adoption or CAS guarantee.
- Independent corrected-candidate audit: `muyewcyx-15-05oz`; GREEN 20/20 and both syntax checks independently passed, 749 lines and A/B preservation confirmed. Claims alias, deadlines, absent claims, and unknown-error handling are resolved, but the overall verdict remains BLOCKED: public writable `runId`/`clock` are still read as authority. One view-freezing assertion is vacuous because the tested property is not exposed. Fresh ASSESS still requires the high-risk independent-verifier fallback.
- Residual correcting writer: `muyf347h-16-qbrz`; reports actual regression RED 19/20 pass, then GREEN/refactor 20/20 and syntax checks. Validated runId/original clock now live in INTERNAL, with no public context authority reads; the facade is frozen. The replacement regression attempts writes/redefinitions before register and proves original namespace/clock use. No signatures or allowed files changed.
- Final targeted independent audit: `muygil5h-17-3wvq`; OVERALL PASS, GREEN 20/20, syntax checks 2/2. Frozen facade/private validated context reject writes, redefinitions, and deletion; no public context authority reads remain. Claims/receipt/view poisoning and fabricated entries cannot change cleanup authority. Both actual default-timer child cases passed: pending 128.2ms, fast 33.9ms with 10s configured guards; reaped within 2s.
- Verified hashes: helper `f6f7ef240c9daf1403423e8b5918e9ff160b38b404f17ff104cf26421d750035`; tests `4f0062ca9b5888918b2bb8d777bd5e6a8d355452dc3c7a5f2ebb6474a36739a7`. A/B HEADs and expected untracked sets unchanged. Historical RED counts are author-reported; final GREEN is independently observed.
- Current: FUNC-01 checks PASS; native preflight and authorized local work-unit commit still pending, so the task remains open. No temporary users/documents created. This is pure helper verification, not live HTTP/Auth acceptance.

## Next step

Inspect native review authority over this normalized three-path work-unit candidate (helper, tests, this document), excluding empty unrelated CLAUDE.md. Follow only the offered native route, record unavailable/declined review honestly if applicable, then close the authorized local commit under ordinary policy. No live SDK/data calls or HTTP harness yet; RPC non-cancellation and verify-then-delete race remain documented limitations.
