# INV-05 — Sales Corrections

## Objective

Let branch sellers correct completed sales: partial and repeated returns, cancellation (a full return), factory-defect refunds or replacements, and exchanges for a different product. Every correction must be online, trusted, transactional, idempotent, auditable and non-negative, as the MVP requires (`odd/tasks/inventory-mvp.md:4`).

## Problem and why

Today a sale (`functions/src/sales.js`) is final. `inventory-mvp.md:6` puts partial returns, exchanges and warranty states in MVP scope, but nothing defines or implements them. Sellers need to serve returning customers without administrator intervention, while stock, money and audit stay consistent.

## Product decisions (user, 2026-10-07/08)

1. Any seller of the branch where the sale was made may correct it.
2. A fixed global window of 15 days, measured as exactly 15×24h from the sale's server `createdAt`. Per-product windows come in a later version.
3. Partial and repeated returns are allowed at the product's quantity precision, until each line's sold quantity is fully returned. Over-return is impossible.
4. Each returned line has a condition. `good` goes back to the branch's sellable stock. `factory-defect` does not go back to sellable stock; it is recorded with its movement and audit and is visible to the administrator. Customer-caused damage is not a return and has no state.
5. For a factory defect the seller chooses a refund, or a replacement with the same product at no charge. A replacement requires sellable stock. Repair tracking is deferred.
6. A refund uses the same payment method as the original sale, is recorded internally only, and is proportional to the returned quantity at the sale's frozen price snapshot.
7. An exchange for a different product is one operation linked to the sale. The returned line is valued at the snapshot price and the new product at the current price. The customer pays the full difference, or the difference is refunded through the original method.
8. Sellers find a sale both by receipt number (server-side, same branch, within the window) and through a list of the branch's recent sales from the last 15 days.
9. Returns from invoiced sales refund the IVA actually charged, proportionally. The correction is flagged as an invoiced sale so the administrator can handle the credit note or CFDI outside the app; CFDI emission stays out of scope.
10. Every correction requires a reason from a fixed list (`change-of-mind`, `wrong-product`, `factory-defect`, `other`) plus an optional free-text note.
11. A factory-defect replacement does not consume returnable quantity. The customer still holds what was bought, so a replaced unit can later be replaced again or refunded, within the original sale's 15-day window. A replacement is capped at the line's remaining returnable quantity. (user, 2026-10-08)

## Technical defaults

- Sales stay immutable. Each correction is its own document with an internal receipt, an audit entry and compensating `inventoryMovements` linked to `saleId` and the line index.
- A per-sale return ledger, read inside the transaction, tracks the returned quantity per line so concurrent corrections can never over-return.
- Follow the existing service pattern: a pure calculation module; a service factory with an emulator guard; idempotency through submission receipts with a fingerprint and exact replay; `create`-only writes except stock; technical artifacts in English.
- Repeated partial refunds use cumulative rounding: each refund is the rounded cumulative amount minus the rounded amount already refunded. A full return then always adds up exactly to the line total.
- New collections stay deny-all to clients in `firestore.rules`; reads go through callables.

## Scope

In scope: backend calculation, services, callables, rules and tests (unit, emulator and HTTP transport), plus the seller Flutter screens for lookup, list, return, replacement and exchange.

Out of scope: repair tracking, per-product windows, CFDI or credit-note emission, bank or refund reconciliation, administrator reporting screens, and transfers (INV-06).

## Constraints

- Work on branch `feat/inventory-mvp-sales-corrections`, created from `166bee0`. Local work-unit commits only; push and PRs stay the user's decision.
- Delivery strategy: feature-branch chain, the cached INV-05 choice. The forecast is well above 400 authored lines, so each task is its own reviewable work unit.
- Use test-first with the pinned Node `/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node`. Emulator and live runs only against the already running local emulators, with owned data and teardown. No product-unrelated edits.

## Tasks

- [x] CORR-01 — Pure correction calculation: remaining returnable quantity per line, proportional refund at the snapshot (half-up per line, IVA charged), exchange difference against the current price, and the 15-day window check. Route: one delegated writer (new module plus tests). Native review `review-b1ec6ebade67d20b` approved; commit `c62ae960a3f9debd593c30e12d75c496245fa3da`, tree exactly the approved candidate `9600eb40`.
- [x] CORR-02 — Sale lookup for sellers: by receipt number, and the branch's recent-sales list (15 days), both server-side with branch and window enforcement. Route: delegated writer. Native review `review-6c7160b3affa3530` approved; commit `a15d1c98e115a9fd0bd708c428d8a8034c6eb4d0`, tree exactly the approved candidate `2f56597d`.
- [x] CORR-03 — Return service: partial and repeated returns, `good`/`factory-defect` conditions, refund by the original method, reason and note, invoiced flag, return ledger, compensating movements, idempotent replay. Route: delegated writer; emulator tests. Native review `review-a18603c466e9c6c0` approved; commit recorded in Evidence.
- [x] CORR-04 — Factory-defect replacement: same product, no charge, requires sellable stock, linked movements. Route: delegated writer. Native review `review-689e0a106f145040` approved; commit recorded in Evidence.
- [x] CORR-05 — Exchange for a different product: return at the snapshot price, new product at the current price, settlement of the difference. Route: delegated writer. Native review `review-fe7aec16af968495` approved; commit recorded in Evidence.
- [ ] CORR-06A — Callables and rules: export callables for lookup, list, return, replacement and exchange in `functions/src/index.js` with the existing guard and error-mapping pattern; add explicit deny-all rules for every new correction collection; callable unit tests. Route: delegated writer. (Split from CORR-06 on 2026-10-08 because the repository has no rules unit-test harness; rules are accepted over real HTTP, as in FUNC-03.)
- [ ] CORR-06B — HTTP transport acceptance for corrections against the running emulators: real Auth tokens and callables, the seller REST denials on the new collections, the seller read of the new movement types, and owned teardown. It folds in the CORR-05 test follow-ups. Route: delegated writer, then a live run with user approval.
- [ ] CORR-07 — Seller Flutter screens: lookup and list, return, replacement and exchange. Route: delegated writer.
- [ ] CORR-08 — Reconcile evidence and commits; report failed, skipped and pending checks. Route: parent.

## Acceptance criteria

- No correction can over-return a line, exceed the window, cross branches, or leave stock negative.
- Refund and exchange amounts match an independent calculation from the sale snapshot and the current price.
- Every correction is idempotent, audited and linked to its sale. The original sale is unchanged.
- Sellers cannot read correction documents directly, and never see acquisition costs.

## Evidence and progress

- Exploration map (read-only, 2026-10-07): no correction code exists. Sales write `sales`, `saleAudits`, `saleSubmissionReceipts`, `inventoryMovements/sale-<key>-<i>` and the stock `set`; the receipt is frozen v1; sellers only; `sales*` collections are deny-all.

- CORR-01 writer (delegated; route trigger: new module plus tests): `functions/src/corrections-calculation.js` (266 lines) and `functions/test/corrections-calculation.test.mjs` (209 lines). Exports `CORRECTION_WINDOW_MS`, `CorrectionError`, `assertCorrectionWindow`, `calculateRemainingReturnable`, `calculateReturnRefund` and `calculateExchangeSettlement`. Author-reported RED: the module was missing (0 pass, 1 fail); GREEN 10/10. `halfUp`, `safeNumber` and `exactFields` are private in `sales.js`, so the module carries minimal local copies; it imports the `quantity.js` helpers. The returned ledger is an object map keyed by line index; CORR-03 must store it in that shape. Exchange settlement nets totals, IVA included.
- CORR-01 parent spot check: corrections 10/10, sales calculation 11/11, whitespace check clean on both new files, hashes `b14cde67…` and `374f8af0…` match the writer report.

- CORR-01 review follow-ups (non-blocking, resolved in CORR-02): `R3-001` (WARNING) — malformed sale lines can raise a raw TypeError instead of `CorrectionError('invalid-argument')`; fix before CORR-03 relies on persisted receipts. `R3-002`/`R3-003` (SUGGESTION) — add tests for the exchange-settlement input guards, currency, and the receipt-snapshot rejections.

- CORR-02 writer (delegated; route trigger: multi-file implementation): `functions/src/sale-lookup.js` (256 lines) with `createSaleLookupService` → `findSale({saleId})` and `listRecentSales({limit?})`, seller-only with branch from claims. Missing and foreign sales both return the same `not-found`; an own-branch expired or future sale returns `failed-precondition`. Reads are read-only transactions. Stored sales must be exactly `{receipt, createdAt}`, and the calculation is recomputed with `calculateSale` and must match exactly, so injected fields are refused. Items carry per-line remaining quantities from `saleReturnLedgers/{saleId}` (`{returned:{[lineIndex]:scaled}}`; missing means none returned). One malformed sale fails the list closed. Added a composite index on `sales` (`receipt.branchId` ASC, `createdAt` DESC); the emulator does not enforce it. Tests: unit 11 and emulator 5 (own `OwnedLookupRun`, because the support helper refuses ledger paths). CORR-01 follow-ups `R3-001`–`R3-003` resolved with 4 additional calculation tests (14 total). Author-reported RED/GREEN: calculation 12/14 → 14/14; lookup module missing → 11/11. The emulator test ran once against the running emulator with owned ids and exact-content cleanup, 5/5, no leftovers. About 870 authored lines, above the 350–500 forecast, because of strict record validation and denial-path tests.
- CORR-02 parent spot check: lookup and calculation 25/25, sales and sales calculation 64/64, hashes of all six files match the writer report.

- CORR-02 review follow-ups (non-blocking, SUGGESTION): `R3-001` — add direct tests for tampered stored line amounts or totals, a `productIds` length mismatch on lookup, and a mismatched `payment.amountCentavos`. `R3-002` — one malformed sale or ledger fails the whole branch list closed; add a list-path ledger test. Fail-closed is kept, because sale records are server-written only.

- CORR-03 writer (delegated; route trigger: multi-file transactional implementation): `functions/src/sale-returns.js` (419 lines) with `createSaleReturnService` → `submitReturn({ idempotencyKey, saleId, reason, note?, lines: [{ lineIndex, quantity, condition }] })`, seller-only. One transaction with all reads before writes:
  - **Reads:** the submission receipt (exact replay; `already-exists` on ownership mismatch); the sale through the exported sale-lookup validators (missing and foreign sales get the same `not-found`; outside the window gets `failed-precondition`); the ledger (strict `{returned, lastReturnId, updatedAt}`); products and stock for `good` lines.
  - **Writes:** `saleReturns/{key}` (v1 receipt without the note), `saleReturnAudits/{key}` (note or null), `inventoryMovements/return-{key}-{i}` (`sale-return`, which raises stock, or `sale-return-defect`, which leaves stock unchanged; no costs), the stock `set` for `good` lines, the ledger `set`, and `saleReturnSubmissionReceipts/{key}`.
  - **Behavior:** the sale is never written. Replay validates shape and request binding instead of recomputing, because cumulative rounding depends on the ledger at submission time. Concurrency is serialized by the ledger read: the emulator case of two returns of 2 against 3 remaining gave exactly one commit. The note must be pre-trimmed; reason and condition are not coupled.
  - **sale-lookup.js:** gains a one-line export of `isOwnBranchSale` and `validateStoredSale`, with no behavior change. The 4 CORR-02 follow-up tests were added; there was no natural RED, so the writer substituted mutation probes on a temporary copy, each detected.
  - **Evidence:** author-reported RED (module missing), then GREEN 17/17; lookup 15/15; emulator 5/5 run once with owned ids and zero leftovers.
  - **Size:** about 1,180 authored lines against a 600–900 forecast, because of strict replay and denial-path tests.
- CORR-03 parent spot check: returns, lookup and calculation 46/46; sales and sales calculation 64/64; hashes of all five files match the writer report; the sale-lookup diff is only the export.
- Notes for later tasks: CORR-04/05 must use their own movement prefixes and submission collections, and write the ledger in the same strict shape. CORR-06 needs deny-all rules for `saleReturns`, `saleReturnAudits`, `saleReturnSubmissionReceipts` and `saleReturnLedgers`.

- CORR-03 closure: native review `review-a18603c466e9c6c0` approved; commit tree exactly the approved candidate `c50fdb65`. Non-blocking SUGGESTION follow-ups:
  - `R3-001`: the stock `set` drops unknown fields; fail closed or pin the shape.
  - `R3-002`: replay does not bind the stored line quantity to the request.
  - `R3-003`: no test for two sale lines of one product (spec mismatch guard, aggregation).
  - `R3-004`: an orphaned create collision surfaces a raw SDK error instead of a `SaleError`.

- CORR-04 writer (delegated; route trigger: multi-file transactional implementation):
  - **Replacement service:** `functions/src/sale-replacements.js` (260 lines) with `submitReplacement({ idempotencyKey, saleId, note?, lines: [{ lineIndex, quantity }] })`, seller-only, with the reason fixed to `factory-defect`.
    - One transaction. The ledger is read and strictly validated but never written (decision 11). Each line is capped at sold minus returned (`out-of-range`). Same-product lines are aggregated. Insufficient sellable stock fails with `failed-precondition`.
    - Writes `saleReplacements/{key}` (v1 receipt, `chargeCentavos: 0`) and `saleReplacementAudits/{key}`.
    - Writes movements `replacement-{key}-{i}-in` (`replacement-defect-in`, no stock change) and `-{i}-out` (`replacement-out`, which decreases stock), one stock `set` per product, and `saleReplacementSubmissionReceipts/{key}`. The sale and the ledger are never written.
  - **Shared code:** extracted to `functions/src/correction-support.js` (195 lines); `sale-returns.js` now uses it.
  - **CORR-03 follow-ups, applied to both services:**
    - `R3-001`: stock must match one of three exact shapes — bare, writer, or demo seed with `demoSeedVersion`, which the parent confirmed in `functions/scripts/provision-demo-identities.mjs`. Anything else fails closed.
    - `R3-002`: replay binds each line quantity by value.
    - `R3-003`: tests for same-product lines.
    - `R3-004`: every create target is pre-read, and a collision returns `already-exists` before any write.
  - **Evidence (author-reported):**
    - Returns: RED 19/22, then GREEN 22/22.
    - Replacements: RED (module missing), then GREEN 16/16, with six mutation probes, all detected.
    - Support: 4/4, with five mutation probes, all detected.
    - Emulator replacement and return tests: run once each, 11/11, no leftovers.
  - **Concurrency:** a replacement racing a return can both legitimately commit when the replacement serializes first, since it consumes nothing. The test asserts this invariant through commit timestamps. Two replacements competing for the last stock: exactly one commits.
  - **Size:** about 1,530 authored lines against a 600–900 forecast, because of strict replay, denial paths, race cases and the R3 work.
- CORR-04 parent spot check: correction suites 71/71; sales and sales calculation 64/64; hashes of all seven files match the writer report.
- Notes: CORR-05 should reuse `correction-support.js` and pre-read its create targets. CORR-06 needs deny-all rules for the replacement collections too, and must map `already-exists`.

- CORR-04 closure: native review `review-689e0a106f145040` approved; commit tree exactly the approved candidate `cad763cf`. Findings:
  - `R3-001` (WARNING): the strict stock shapes would reject a seeded document later merged by another writer. Resolved by evidence: the parent verified that both stock writers, `sales.js:294` and `inventory.js:129`, use a full `set` without merge, so the first write replaces the seed shape.
  - `R3-002` (SUGGESTION): the replacement-versus-return race test accepts either order; force both orders deterministically.

- CORR-05 writer (delegated; route trigger: multi-file transactional implementation): `functions/src/sale-exchanges.js` (546 lines) with `submitExchange({ idempotencyKey, saleId, reason, note?, returnLines, newLines, differencePayment? })`, seller-only, in one transaction.
  - **Returned part:** behaves as a return — it consumes the ledger with cumulative refunds and caps at the remaining quantity (`out-of-range`).
  - **New items:** must differ from the returned products, including `factory-defect` lines (`invalid-argument`). They are priced at current pricing through `calculateSale` with the original `invoiceRequested`, and need sellable stock. A missing product returns `not-found`, as in sales.
  - **Settlement:** through `calculateExchangeSettlement`. `differencePayment` is required, with the exact amount and any of cash, card or transfer, when the customer owes; it must be absent otherwise.
  - **Writes:**
    - `saleExchanges/{key}`: a v1 receipt with returned lines and amounts, the new-item `productIds` and calculation, the settlement and the `invoiced` flag.
    - `saleExchangeAudits/{key}`.
    - Movements `exchange-{key}-in-{i}` (`exchange-return`, which restocks, or `exchange-return-defect`) and `exchange-{key}-out-{j}` (`exchange-out`, carrying `newLineIndex`).
    - Stock `set`s and the ledger `set`; `lastReturnId` now holds the exchange key.
    - `saleExchangeSubmissionReceipts/{key}`.
  - **Replay:** recomputes the new-item calculation and settlement; returned amounts are checked for shape, sums and binding.
  - **Local pricing validator:** it mirrors the private validator in `sales.js`. There is a drift risk if `sales.js` changes.
  - **CORR-04 follow-up `R3-002`:** the replacement-versus-return race is now deterministic in both orders. Replacement first: both commit. Return first: the replacement fails with `out-of-range` and writes nothing.
  - **Evidence (author-reported):** RED (module missing), then GREEN 22/22, with 14 mutation probes all detected. Emulator exchange and replacement tests ran once: 12/12, no leftovers. In the exchange-versus-return race, the return committed and the exchange was rejected.
  - **Size:** about 1,600 authored lines against a 700–1,000 forecast, because of strict replay, the required cases and the race rewrite.
- CORR-05 parent spot check: correction suites 93/93; sales and sales calculation 64/64; hashes of all four files match the writer report.
- Notes for CORR-06: deny-all rules for `saleExchanges`, `saleExchangeAudits` and `saleExchangeSubmissionReceipts`, in addition to the return and replacement collections and `saleReturnLedgers`. Map `invalid-argument`, `out-of-range`, `failed-precondition`, `not-found`, `already-exists`, `permission-denied` and `unauthenticated`.

- CORR-05 closure: native review `review-fe7aec16af968495` approved; commit tree exactly the approved candidate `31837b5d`. Non-blocking SUGGESTION follow-ups:
  - `R3-001`: force both orders in the exchange-versus-return race, as `inOrder` does for replacements.
  - `R3-002`: test same-product restock merging and the spec-disagreement error in exchanges.
  - `R3-003`: test descending `lineIndex` with mixed conditions, to prove refund-line pairing. CORR-01 documents that refund lines keep request order.
  - `R3-004`: the return-first replacement subtest depends on the previous subtest's stock state.

- CORR-06A writer (delegated; route trigger: multi-file wiring plus tests):
  - **`functions/src/index.js` (+64 lines):** a shared `saleCorrectionCallable` helper exports `findCorrectableSale`, `listRecentCorrectableSales`, `submitSaleReturn`, `submitSaleReplacement` and `submitSaleExchange`. It follows the `submitSale` pattern exactly: guard first with a fixed `failed-precondition`, lazy `initializeApp`, `SaleError` mapped to `HttpsError`, and anything else to a fixed per-callable `internal` message.
  - **`CorrectionError` cannot escape the services:** every calculation call is caught and converted to `SaleError`, so it is not mapped. A test pins that an escaped one becomes `internal`.
  - **`firestore.rules` (+46 lines):** explicit deny-all for the 10 correction collections, before the catch-all. `inventoryMovements` and the other rules are unchanged.
  - **Movement audit:** every new movement type carries `branchId` and `actorId` and no cost or price field, so the existing `isSellerFor` rule exposes them to branch sellers, which is intended.
  - **Tests:** `functions/test/corrections-callable.test.mjs` (185 lines), using the `registerHooks` seam from sales-callable. Author-reported RED 0/5, then GREEN.
- CORR-06A parent spot check: corrections and sales callables 33/33 (run from `functions/`); the rules diff adds exactly 10 `if false` rules and removes nothing; the catch-all is still last; hashes match the writer report.
- Note for CORR-06B: confirm that the running Functions emulator has loaded the five new exports and the new rules before the live run, or reload it with the user's approval.

## Next step

Review and commit CORR-06A, then CORR-06B (HTTP transport acceptance).
