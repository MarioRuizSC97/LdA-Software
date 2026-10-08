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
- [ ] CORR-02 — Sale lookup for sellers: by receipt number, and the branch's recent-sales list (15 days), both server-side with branch and window enforcement. Route: delegated writer.
- [ ] CORR-03 — Return service: partial and repeated returns, `good`/`factory-defect` conditions, refund by the original method, reason and note, invoiced flag, return ledger, compensating movements, idempotent replay. Route: delegated writer; emulator tests.
- [ ] CORR-04 — Factory-defect replacement: same product, no charge, requires sellable stock, linked movements. Route: delegated writer.
- [ ] CORR-05 — Exchange for a different product: return at the snapshot price, new product at the current price, settlement of the difference. Route: delegated writer.
- [ ] CORR-06 — Callables, rules and HTTP transport acceptance for all corrections. Route: delegated writer; live run with user approval.
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

- CORR-01 review follow-ups (non-blocking): `R3-001` (WARNING) — malformed sale lines can raise a raw TypeError instead of `CorrectionError('invalid-argument')`; fix before CORR-03 relies on persisted receipts. `R3-002`/`R3-003` (SUGGESTION) — add tests for the exchange-settlement input guards, currency, and the receipt-snapshot rejections.

## Next step

CORR-02 (sale lookup), which also resolves CORR-01 follow-ups `R3-001` to `R3-003` in the calculation module.
