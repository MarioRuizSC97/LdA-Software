# INV-05 — Trusted branch sales (initial backend slice)

## Objective
Record seller-only branch sales atomically using authoritative price snapshots, exact quantities, non-negative stock and actor-bound idempotency. Return a seller-safe internal receipt and validate full payment against the server total. First deliver pure calculation, then transaction, then local-only callable registration; no Flutter integration yet.

## Authorization and boundaries
Work only in B `/Users/luismarioruiz/LdA-Software-review-intake`, existing branch `feat/inventory-mvp-review-intake`. Initial boundary: `9801b5b434bf73d3b0cabfc40dec0817d3648963`; documentation-only advancement from INV-04 closure was independently reconciled. A remains untouched, including source/index, CLAUDE.md, services and data.
Human authorized backend source/tests, deterministic local tests using existing Node runtime, and seller-only scope. No installs/downloads, dependency/config/rules changes, network/cloud/emulator calls, listeners, service operations, additional worktrees, push/PR/merge or deployment. Workers do not stage or commit. Parent owns task records, mirrors, native authority and delivery; commits require explicit human request per current safety policy.
INV-04 routing review remains deferred; session approval is scoped; six shell/UI files were human-exception delivered, NOT reviewed or receipted. Those exceptions do not apply to INV-05.

## Accepted business decisions
- Seller role only; branch derived from trusted assignment, never authorized by client input. Administrator sales and branch selection deferred.
- Exact decimal-string quantities and per-product unit/precision, using existing quantity helpers; no binary-float monetary multiplication or silent quantity rounding.
- Published unit prices are MXN integer centavos. First round each quantity × price line to nearest centavo, half-cent ties up; then calculate applicable additional IVA on that rounded base, nearest centavo half-up per line. Sum recorded line amounts, with safe-integer/overflow checks.
- Invoice intent is an explicit required Boolean. Additional IVA follows actual product treatment/rate and invoice intent, never an assumed 16% or price threshold.
- Included-mode prices preserve gross charge. Inclusive tax extraction is deferred; never label an uncalculated component as zero or fabricate a fiscal breakdown.
- Snapshot immutable quantity/pricing/tax/calculation policy and version. Historical sales never change after catalog repricing.
- Full payment only: cash, card or transfer; recorded amount must match server total. No credit, partial/split payments, tender/change or external charge processing.
- Safe internal receipt returned on submission/replay, excluding costs and private actor metadata. Persisted sale/replay records remain client deny-all under existing rules. Receipt browsing and cross-actor access deferred.
- Corrections, cancellation, returns, exchanges, warranties, late IVA collection and fiscal issuance are out of this slice.

## Delivery and routing
Selected `chain_strategy=feature-branch-chain`, `delivery_strategy=auto-chain`; future ordered slices calculation → atomic transaction → guarded callable, with tests/docs alongside behavior. No publication authorized. Forecast 910–1350 authored changed lines; transaction alone estimated 550–800 and cannot be artificially split or stripped of safety coverage. One honest slicing pass; report actual overages. Verify repository default branch before creating new branches/PRs. Current work stays local on existing feature branch.
Mandatory route: one delegated writer per task (multi-file/preparation triggers). Applicable deterministic behavior uses observed RED → GREEN → refactor; report each command and exit, never fabricate TDD. Parent follows native assessment/verification plan and user-owned RDD switch at work-unit boundary. No inherited review exceptions or attempted-ID reuse. Current authored committed count: 0; current native boundary: `9801b5b434bf73d3b0cabfc40dec0817d3648963`.

## Tasks
- [ ] **INV-05-CALC-01 — Exact sale calculation and immutable snapshots.** IN PROGRESS. Allowed: new `functions/src/sales.js`, new `functions/test/sales-calculation.test.mjs`. Pure module, no Admin initialization. Estimated 270–400 lines. RED cases: fractional base below/at/above tie, rounding order, additional IVA with/without invoice, included invariance, exempt/null and zero rate, per-line rounding, malformed values, unsafe totals and immutable snapshots. Commit/review evidence pending.
- [ ] **INV-05-TXN-02 — Atomic seller sale and replay.** PENDING. Allowed: extend `functions/src/sales.js`, new `functions/test/sales.test.mjs`. Validate auth/branch/product/pricing/payment; read all inputs before writes; create immutable sale, negative movement, projections and actor/request-bound replay together. Estimated 550–800 lines. Tests: unauthorized/cross-branch, malformed/missing inputs, underflow, payment mismatch, rollback, exact replay, key/actor/payload collision, malformed stored replay, repricing snapshot preservation. Memory concurrency proves serialized fake behavior only. Commit/review evidence pending.
- [ ] **INV-05-CALL-03 — Guarded local callable.** PENDING. Allowed: `functions/src/index.js` registration only; new `functions/test/sales-callable.test.mjs`. Existing local demo/region/origin guards, sanitized errors; no SDK initialization in pure tests or listeners. Estimated 90–150 lines. Real transport remains unverified. Commit/review evidence pending.

## Verification plan
Existing Node: `/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node`.
Task 1: `node --test functions/test/sales-calculation.test.mjs`; `node --test functions/test/quantity.test.mjs`; `node --check functions/src/sales.js`; `git diff --check`.
Tasks 2/3: explicitly select new tests and applicable earlier service-free deterministic suites; syntax-check sales/index. Do not use broad npm/glob suites: existing intake tests open loopback listeners. Resolve additional runners before each writer launch.
Pending/unverified: real Firestore contention/rollback, callable HTTP transport, sale-specific rules acceptance, browser/native behavior. These require separately authorized operations and are NOT proved by fake transaction tests. No emulator-test artifact needed now.

## Progress and next step
Exploration and product decisions complete. Unexpected HEAD resolved as docs-only; no repair performed. No source written or tests run yet. Launch bounded calculation writer after durable record/mirror and visible projection are synchronized. Parent record is not a delegated edit surface.
