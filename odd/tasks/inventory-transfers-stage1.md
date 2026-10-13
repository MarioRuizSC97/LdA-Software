# Inventory Transfers — Stage 1

## Outcome and authorization
Stage1 implemented and verified in deterministic/local checks: administrator-only immediate atomic multi-product transfer backend plus readable existing Movimientos rows. At original delivery commits were not authorized. User subsequently authorized bounded local transfer commits/tests/docs, not publication/current demo data changes/dependencies/runtime restart. Preserve prior catalog/iOS work, CLAUDE.md and odd/runtime. Requests/notices/grants remain excluded; administrator form was implemented separately.

## Tasks
- [x] TR1-01 — Backend checks. Worker mv5sb267-i-5xys, independent mv5ub5hz-k-1tmr, cleanup mv5udqzf-l-207k:48/48 plus syntax checks. No commit permission; real emulator integration deferred.
- [x] TR1-02 — Strict transfer parser/admin label. Worker mv5ugsxo-m-7cww: RED32/5fail, GREEN32/32 plus7repository/session regressions, analyzer/format clean. Parent spotread reference/sign block. No commit permission.
- [x] TR1-03 — Independent regression/build and native review acknowledged. Verifier mv5usrtl-n-a9a8:48backend,32focused,737full Flutter, syntax/analyzer/webbuild/format/diffcheck and explicit untracked whitespace checks exit0. Seven source/test fingerprints and HEADbd5131d stable. Medium native review approved and burned; no correction opened.

## Scope and contract
One distinct valid source/destination pair,1..50distinct products, canonical positive quantities, unit/precision/safe bounds. All reads before writes, all-or-nothing stock conservation, absent destination stock initialized. Immutable transfers audit and actor/payload-bound transferSubmissionReceipts; deterministic replay and collision denial. Callable transferInventory guarded before SDK with admin claim. Two signed per-product transfer-out/in legs, transferId, no costs/counterpart metadata; rules unchanged.

Dart per-type reference allowlists preserve legacy strictness; transferId1..112chars mandatory, out<0/in>0. isAdministratorOnly drives label and profile skip; no transfers-doc reads or name actions for admin rows. Source surfaces3functions+4movement/test files.1556authoredlines (1186backend+370Flutterdiff), mostly tests; original750–1150estimate exceeded with same scope. Original delivery_strategy=ask-on-risk with no commit permission then. Subsequent human authorization permits local review slices, not publication. RS01 backend commit5872590ff257fd476f56fdcfa4478f0c60521f91 independently passed27backend tests/syntax/importclosure and native review-f29d4f923163dac8 approved/acknowledged/burned. RS02 movement commit pending; evidence is never inferred from approval.

## Review evidence
Lineage review-4cca9cb6b6c7f910; frozen7code/testpaths only, mutable untracked tracker/CLAUDE/runtime excluded. Candidate tree cb9938c3557a55269abf6611e99c566069a04094; target sha256:bf4b01e2ada81108ab9807b91b4ad7edf5730224fcf3221527c858e56005b066. Exact approved acknowledgement returned authority burned at revision sha256:e16d7e4f40c609aa42a9cf395b24e4f809c12f67d237342039a92ba72624299c. Informational R3-001 WARNING and R3-002/003 SUGGESTION are separate follow-ups, do not reopen approved review. First consent expired with no lineage; fresh START succeeded. Earlier ASSESS unassessable used independent high-risk fallback, not a risk downgrade.

## Baseline, incident and limits
Initial4db6346; verified HEADbd5131db5e90aef71ae5182689800d131bceecc7 on feat/inventory-mvp-seller-profiles-v2. Other actor iOS/auth/docs commits preserved, no functions/movement overlap; user reports other work finished except reviews. At original stage1 delivery no commits/staging. Later RS01 local backend commit recorded above; RS02 packages unchanged movement code, no source rewrite.

/tmp/none unauthorized worker redirect: regular4275B/currentuid501/0644/singlelink, not empty as claimed. Never read/deleted, confidentiality unknown/no leakage assertion. Separate /dev/null redirection compliance lapse retained; tests do not retroactively authorize either. Scout stale reflog concern resolved by authoritative Git.

No failed final checks. Web build informational Wasm/tree-shake notes only; full737pass/exit observed despite tool log truncation. Doubles do NOT prove real Firestore retry/callable persistence. Emulator/rules deferred (existing harness clears demo fixtures; never target live8080). No browser transfer form, mobile/platform acceptance or frontend refresh. No actual transfer against current demo data.

## Next step
Isolated real Firestore acceptance subsequently passed9 tests with cleanup/runtime preservation and its own burned approval (inventory-transfers-emulator-acceptance.md). Administrator form independently passed852Flutter/fullanalyzer/webbuild; native review now proceeds by local committed slices (inventory-transfers-review-slices.md). These proofs do not establish actual demo callable/Auth/HTTP/browser/mobile behavior. Request/grant/notice stages remain future. Keep one writer; parent owns task files/full mirrors/todo. No further STATUS on any burned lineage.
