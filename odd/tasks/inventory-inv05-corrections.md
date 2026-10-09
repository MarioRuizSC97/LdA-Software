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
12. Before confirming a return or an exchange, the seller sees the exact refund or difference from a new read-only server preview callable. It mirrors `quoteSale` and computes with the same code as the correction services. The same backend work adds structured `details.reason` to correction rejections the UI must distinguish, starting with an ambiguous folio. The other open findings (the `SaleDraftStore` revision reset in sales) wait until after it. (user, 2026-10-09)

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

- Work on branch `feat/inventory-mvp-sales-corrections`, created from `166bee0`. CORR-07 and CORR-08 continue on `feat/inventory-mvp-sale-corrections-ui`, created from `fc186da` (the completed seller sale UI, `odd/tasks/inventory-seller-sale-ui.md`). Local work-unit commits only; push and PRs stay the user's decision.
- Delivery strategy: feature-branch chain, the cached INV-05 choice. The forecast is well above 400 authored lines, so each task is its own reviewable work unit.
- Use test-first with the pinned Node `/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node`. Emulator and live runs only against the already running local emulators, with owned data and teardown. No product-unrelated edits.

## Tasks

- [x] CORR-01 — Pure correction calculation: remaining returnable quantity per line, proportional refund at the snapshot (half-up per line, IVA charged), exchange difference against the current price, and the 15-day window check. Route: one delegated writer (new module plus tests). Native review `review-b1ec6ebade67d20b` approved; commit `c62ae960a3f9debd593c30e12d75c496245fa3da`, tree exactly the approved candidate `9600eb40`.
- [x] CORR-02 — Sale lookup for sellers: by receipt number, and the branch's recent-sales list (15 days), both server-side with branch and window enforcement. Route: delegated writer. Native review `review-6c7160b3affa3530` approved; commit `a15d1c98e115a9fd0bd708c428d8a8034c6eb4d0`, tree exactly the approved candidate `2f56597d`.
- [x] CORR-03 — Return service: partial and repeated returns, `good`/`factory-defect` conditions, refund by the original method, reason and note, invoiced flag, return ledger, compensating movements, idempotent replay. Route: delegated writer; emulator tests. Native review `review-a18603c466e9c6c0` approved; commit recorded in Evidence.
- [x] CORR-04 — Factory-defect replacement: same product, no charge, requires sellable stock, linked movements. Route: delegated writer. Native review `review-689e0a106f145040` approved; commit recorded in Evidence.
- [x] CORR-05 — Exchange for a different product: return at the snapshot price, new product at the current price, settlement of the difference. Route: delegated writer. Native review `review-fe7aec16af968495` approved; commit recorded in Evidence.
- [x] CORR-06A — Callables and rules: export callables for lookup, list, return, replacement and exchange in `functions/src/index.js` with the existing guard and error-mapping pattern; add explicit deny-all rules for every new correction collection; callable unit tests. Route: delegated writer. (Split from CORR-06 on 2026-10-08 because the repository has no rules unit-test harness; rules are accepted over real HTTP, as in FUNC-03.)
- [x] CORR-06B — HTTP transport acceptance for corrections against the running emulators: real Auth tokens and callables, the seller REST denials on the new collections, the seller read of the new movement types, and owned teardown. It folds in the CORR-05 test follow-ups. Route: delegated writer, then a live run with user approval.
- [ ] CORR-07 — Seller Flutter screens: lookup and list, return, replacement and exchange. Split on resume (2026-10-09) into reviewable work units, each its own commit:
  - [x] CORR-07A — Flutter correction domain and gateway: strict parsers for lookup/list/return/replacement/exchange responses, request builders with BigInt quantities at product precision, one idempotency key per correction draft, a gateway for the five callables following the sale gateway pattern (session re-check, stale generation, code whitelist, uncertain handling, structured reasons), bootstrap wiring, unit tests. No UI. Route: delegated writer.
  - [x] CORR-07B — Seller entry and lookup: an app-bar action on the seller catalog opens corrections; folio search plus the recent-sales list (15 days); a sale detail with per-line sold, returned and remaining quantities. Neutral Spanish copy. Widget tests. Route: delegated writer.
  - [ ] CORR-07P — Backend correction preview (decision 12): read-only, seller-only callable(s) for return and exchange that run the same window, branch, ledger, stock and pricing checks and the same calculation as `submitSaleReturn`/`submitSaleExchange`, without writing anything; the exchange preview returns the exact `customerPaysCentavos`/`refundCentavos`. Add structured `details.reason` for an ambiguous folio and an exchange difference-payment mismatch. Unit, emulator and callable tests, plus the HTTP transport harness, with one live run only with user approval. Route: delegated writer.
  - [ ] CORR-07C — Return form: per-line quantity and condition (`good`/`factory-defect`), reason and note, server-computed refund, confirmation and correction receipt, uncertain-retry lock. Widget tests. Route: delegated writer.
  - [ ] CORR-07D — Replacement and exchange forms: factory-defect replacement of the same product; exchange for a different priced product with the settlement difference; receipts. Widget tests. Route: delegated writer.
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

- CORR-06A closure: native review `review-7b57f6bd08ec58da` approved; commit tree exactly the approved candidate `b17209c0`. Findings:
  - `R3-001` (WARNING): the test fakes might not match the real service factory shapes.
  - `R3-002` (SUGGESTION): the lookup methods are detached and called unbound.
  - Both resolved by parent evidence: instantiating the real modules shows that the return, replacement and exchange factories return functions, and that the lookup factory returns `{findSale, listRecentSales}` without `this`. This matches the wiring at `index.js:196-216`. End-to-end proof is pending CORR-06B.

- CORR-06B writer (delegated; route trigger: large test harness plus multi-file test follow-ups):
  - **New file:** `functions/test/corrections-callable-transport.emulator.test.mjs` (1,348 lines). It is gated by `LDA_CORRECTIONS_HTTP_ACCEPTANCE=1` together with the existing baseline and runtime approvals, the node pin, ambient-override rejection, the URL allowlist and the cert credential.
  - **Owned setup:** a main and a foreign UUID branch; owned products `CORR-<RUN>-A..D`; two owned-auth manifests covering five Auth identities; about 120 paths planned before any write. Sales U (uninvoiced, cash) and I (invoiced, card) are created through the real `submitSale`.
  - **Live cases:**
    - lookup and list with the foreign seller and role denials;
    - returns (partial good and defect, original method, invoiced IVA, replay, over-return);
    - replacement, including insufficient stock;
    - exchanges (exact difference payment and a wrong amount, refund, same product);
    - seller 403 on the 10 correction collections, and seller reads of own-branch correction movements with the exact field set and no costs, while the foreign seller gets 403;
    - final stock consistency, and the sale documents unchanged.
  - **Teardown:** reads every planned document before deleting; products are deleted before branches; uncertainty retains everything.
  - **Offline rehearsal:** the same `runScenario` runs against the real services on an in-memory store. Author-reported RED 0/12, then GREEN 12 with 1 skipped; four service mutation probes were detected.
  - **CORR-05 follow-ups:** `R3-001` adds a deterministic `inOrder` exchange-versus-return race in both orders; `R3-002` and `R3-003` add unit tests for same-product merging, spec disagreement and descending mixed-condition pairing; `R3-004` makes the return-first replacement subtest independent. The exchange and replacement emulator tests ran once: 13/13, no leftovers.
  - **Size:** about 1,570 authored lines against a 900–1,300 forecast, because of the full independent projections and the offline rehearsal.
- CORR-06B parent spot check:
  - Transport offline: 12 pass, 1 skipped.
  - Correction suites: 96/96.
  - Sales transport offline: 23 pass, 1 skipped.
  - No source files changed; the hashes of all four files match the writer report.
- Live-run risks, from the writer: the emulators must have loaded the new exports and rules (exports confirmed by OPTIONS 204); the newest-first order could fail on an equal millisecond; a failed projection retains everything; the list query relies on the emulator not enforcing indexes; Auth cleanup is verify-then-delete; 5 Auth users are created.

- CORR-06B closure (offline part): native review `review-d9fbbb425a9a215c` approved; commit tree exactly the approved candidate `f1a5b3d9`. Finding `R3-001` (WARNING): one offline fake-HTTP assertion expects `live-approval-required`, but on a non-pinned Node, `gate` throws `node-pin` first, so the check is not portable. It passes on the pinned Node 24.21.0 used here. Fix later by passing an explicit pinned runtime.

- CORR-06B live run 1 (user-approved, exactly once, HEAD `387e1e5`, verifier):
  - **Runtime revalidated:** Auth 9099, Firestore 8080, Functions 5001 and hub 4400 listening; OPTIONS 204 for all six routes; project `demo-lda-inventory`.
  - **Result:** exit 0; 44 tests, 44 pass, 0 fail, 0 skipped (~2.6 s), including the live root covering lookup, list, returns, replacements, exchanges, seller rules and final consistency.
  - **Fixtures and residue:** all 10 baseline fixtures unchanged, with hashes matching FUNC-03 run 3. Firestore stayed at 104 documents with a byte-identical UUID listing; 0 `acceptance-*` Auth users before and after. No retention.
  - **Offline re-run:** 12 pass, 1 skipped. Parent readback of the log confirmed 44/44, an identical baseline and residue diff, and no failures.
  - **Limitation:** the explicit deny rules are semantically identical to the catch-all deny they precede, so neither the 403 probe nor the passing rules subtest proves whether the emulator hot-reloaded the new `firestore.rules`. Client-observable behavior is the same either way.

- CORR-07 exploration (read-only): the Flutter app has no seller sale UI and no client for `submitSale` or the correction callables. Every write flow is an admin-gated inline form in `catalog_page.dart` (about 2,390 lines), with no router or dialogs. The receipt number is the client-generated `saleId` UUID, 36 characters long. Proposed split: domain plus gateway, lookup and list screen, then forms.
- Decision (user, 2026-10-08): build the seller sale UI first, as a separate feature that defines the receipt and its number. CORR-07 is paused until it exists; CORR-07 and CORR-08 resume afterwards.
- CORR-07A writer (delegated, Flutter domain and gateway, no UI):
  - **New files:**
    - `lib/corrections/correction_sale.dart`, `correction_draft.dart` and `correction_receipt.dart`;
    - `lib/firebase/emulator_correction_gateway.dart`.
  - **Bootstrap:** `initializeCorrectionGateway` plus a `createCorrectionGateway` seam that binds the 5 callable names. It reuses the sale helpers and outcome types.
  - **Shapes:**
    - The lookup returns per-line `soldScaled`, `returnedScaled` and `remainingScaled`, plus folio, `createdAt` and receipt; there are no product names (the UI resolves them from the catalog).
    - The correction receipts have no server time.
    - The correction services set no `details.reason`.
  - **Payment and preview:** only `submitSaleExchange` takes a client amount. `differencePayment.amountCentavos` must equal the server `customerPaysCentavos` exactly, and must be absent when nothing is owed. No callable previews a refund or a difference.
  - **Submit handling:** a malformed submit response is Uncertain (same-key retry), matching the sale gateway; a malformed lookup or list response is Protocol.
  - **Evidence (author-reported):** RED from compile failures, then GREEN 61/61 targeted. 12 mutation probes: 11 killed; 1 equivalent mutant was removed and a new test added.
  - **Size:** about 3,510 lines (about 1,860 in `lib`), mostly strict parsers and forgery tests.
- CORR-07A parent spot check: corrections and firebase tests 126/126. The writer reported `flutter analyze` clean and the full suite 477/477.
- CORR-07A closure: native review `review-de5042722e54d2a1` (medium, one lens) approved and acknowledged; commit tree exactly the approved candidate `88f11977`; commit `862120b`. Follow-ups, folded into CORR-07B:
  - `R3-001` (WARNING): only `CorrectionProtocolException` becomes Uncertain after a submit returns. Any other parse error, such as a `SaleValidationException` from the exchange calculation or a cast error, escapes raw, so the UI could drop a possibly committed draft. Catch all post-submit parse failures.
  - `R3-002` (SUGGESTION): `CorrectionDraftStore` lacks tests for seller and branch isolation, `isCurrent` after resolve, and a stale attempt clearing a newer draft.
- CORR-07B writer (delegated, Flutter entry, lookup and detail):
  - **Screens:** a "Correcciones" app-bar action for sellers only. `CorrectionLookupView` has folio search (format checked before calling) and the 15-day recent list with loading, empty, error and retry states. `CorrectionSaleDetail` shows per-line sold, returned and remaining quantities, with names from the catalog snapshot. Return, replace and exchange are disabled ("Próximamente").
  - **Shell:** `correctionGatewayLoader`, cached per `userId|branchId`, dropped after a failed initialization, with the exact seller checked before and after each read.
  - **Navigation:** the view replaces the page body, like the receipt view, so it is disposed on a session change; Android back does not navigate back.
  - **Review follow-ups:** `R3-001` fixed (any post-submit parse failure becomes Uncertain). `R3-002` tests found a real bug: draft revisions restarted after a resolve, so a stale attempt could match a newly begun equal draft. Fixed with a counter that never resets.
  - **Evidence (author-reported):** RED, then GREEN; 14 mutation probes, all killed.
- CORR-07B parent spot check: full `flutter test` 499/499.
- CORR-07B closure: high-risk four-lens native review `review-ba46d4b60125453a` approved and acknowledged; commit tree exactly the approved candidate `3f8f97af`; commit `28a5715`. Follow-ups, folded into CORR-07C:
  - `R4-uncertain-catch-all-drops-cause` (WARNING): log or attach the original parse error before mapping it to Uncertain.
  - `R2-stale-comment-misleading` and `R3-stale-search-silently-dropped` (WARNING): a stale rejection from `find` with a matching generation clears the spinner and shows nothing; show an error or retry, add a test and fix the comment.
  - `R3-post-read-session-check-untested` (SUGGESTION): add a test for a session change during a pending correction read.
  - `R2-unexplained-15-day-window` and `R2-unused-branchId` (SUGGESTION): name the window constant; remove or use `SaleCorrections.branchId`.
- Open findings deferred by the user until after CORR-07P:
  - `SaleDraftStore` in `lib/sales/sale_draft.dart` has the same revision-reset bug.
  - The folio lookup's `failed-precondition` also covers non-ambiguous cases; CORR-07P addresses it with a reason.
- CORR-07P writer (delegated, backend):
  - **Callables:** one per kind, seller-only, exported through `saleCorrectionCallable`.
    - `previewSaleReturn`: request exactly `{saleId, reason, lines}`; the response has exactly the return receipt fields `{saleId, lines, refund, invoiced}`.
    - `previewSaleExchange`: request exactly `{saleId, reason, returnLines, newLines}`; the response is `{saleId, returned, newItems, settlement:{returnedCentavos, newItemCentavos, customerPaysCentavos, refundCentavos, refundMethod}, newLines:[{productId, available}], invoiced}`. Short stock shows as `available:false` per line, while the submit still rejects it.
    - Both reject `idempotencyKey`, `note` and `differencePayment`. No costs appear.
  - **Shared code:**
    - the previews and submits share reads (`readReturnPlan`, `readExchangePlan`), checks and receipt builders;
    - the previews run a read-only transaction;
    - submit error precedence is locked by a test, and a side-by-side script showed submit responses and stores byte-identical apart from the new reasons.
  - **Drift fixed:** `sale-exchanges.js` now uses `saleStoredPricing` and `saleQuantity` exported from `sales.js`; its private validator copies are gone.
  - **Reasons:**
    - `folio-ambiguous` on the ambiguous folio lookup;
    - `payment-mismatch` on all three exchange difference-payment rejections (one reason, because the client recovers the same way; the messages differ).
    - The exchange submit's insufficient stock still has no reason; the preview's `available` covers the UI.
  - **Transport harness:** preview equals submit for return-good, return-invoiced, exchange-pay and exchange-refund; the wrong payment and the ambiguous folio carry their reasons; non-sellers and a foreign seller are denied.
  - **Evidence (author-reported):**
    - RED: preview 12/13, lookup 1 and callable 8/9 failing; then GREEN.
    - 13 mutation probes, all killed.
    - Emulator suites run once each: `sale-returns` 6/6, `sale-exchanges` 6/6 and `sale-lookup` 10/10, with no residue.
    - Transport offline: 39 pass, 2 skipped.
  - **Size:** about 1,010 authored lines.
- CORR-07P parent spot check: every non-emulator `functions/test/*.test.mjs` from the repository root, 318/318 pass. The writer reported 355 under a different counting command; neither run had a failure.
- CORR-07P closure: native review `review-8110b1410ad6e01c` (medium, one lens) approved with no findings and acknowledged; commit tree exactly the approved candidate `6aa37de7`; commit `4863da9`.
- CORR-07P pending: the one live HTTP transport run, which needs user approval. First confirm OPTIONS 204 for the 8 correction routes, including the two previews.

## Next step

CORR-07P live run (needs user approval), then CORR-07C (return form with preview, folding in the CORR-07B follow-ups).
