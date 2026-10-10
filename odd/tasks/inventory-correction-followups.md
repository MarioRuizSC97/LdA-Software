# Correction and Sale Follow-ups

## Objective

Close the open findings left by the seller sale UI (`odd/tasks/inventory-seller-sale-ui.md`) and INV-05 (`odd/tasks/inventory-inv05-corrections.md`, final report): two sale-flow retry-safety bugs, missing structured server reasons in corrections, and the non-blocking review suggestions.

## Problem and why

- `SaleDraftStore` restarts revisions after a resolve, so a stale attempt can match a newly begun equal draft. `CorrectionDraftStore` had the same bug and was fixed in CORR-07B.
- A sale that commits after `SaleCartController` is disposed loses its receipt, because the shell resolves the draft. The seller could charge again unaware. The corrections flow was fixed in CORR-07C1 with complete/acknowledge.
- The correction services send no `details.reason` for an expired window or insufficient stock, so the Flutter client matches English server messages.
- Several non-blocking review suggestions remain open.

## Decision (user, 2026-10-10)

Do follow-ups 1–3 from the INV-05 final report, plus 4 (the non-blocking suggestions), as one small feature.

## Scope

In scope:
- the sale draft store and sale receipt recovery (Flutter);
- structured correction reasons (backend, plus the Flutter client switching to them);
- the listed review suggestions.

Out of scope:
- changing the app-wide money format ("20.70 MXN"); this is a product copy decision, not a defect;
- ticket printing;
- new correction features.

## Constraints

- Branch `feat/inventory-mvp-correction-followups`, created from `22d2b3f`. Local work-unit commits only; push and PRs are the user's decision.
- Test first. Use the pinned Node and Flutter commands from the previous features.
- Codes and messages of existing server errors stay unchanged; reasons are only added.
- A live HTTP transport run happens only with user approval.

## Tasks

- [x] FIX-01 — Sale flow retry safety (Flutter): `SaleDraftStore` uses a revision counter that never resets. Sale success keeps the committed receipt until it is acknowledged (mirroring `CorrectionDraftStore.complete`/`acknowledge`), so a receipt that lands after the cart is disposed shows on the next catalog view, and no new sale can start unaware. Tests: the stale-attempt case, dispose during submit followed by success/failure/rejection, and the seller switch. Route: delegated writer.
- [ ] FIX-02 — Correction server reasons (backend plus Flutter client): add `details.reason` `correction-window-closed`, `insufficient-stock` and `over-return` (or the existing equivalents, if already defined) to returns, replacements, exchanges, previews and lookup where they apply, with codes and messages unchanged. Update the unit, callable and transport harness tests. Switch the Flutter `CorrectionRejection` helpers to reasons, keeping a message fallback only if justified. Route: delegated writer; one live run with user approval.
- [ ] FIX-03 — Review suggestions (Flutter tests and small fixes):
  - untested replacement failure branches (unresolved, stale with an explanation message, session with a stored draft);
  - the exchange blocked message not refreshing while the form is open;
  - exchange new-line controllers disposed before the field unmounts;
  - the hard-coded 16% IVA in `catalogCalculationFor` in the test fixtures;
  - the SALE-07 `R3-forged-folio-baseline` assertion;
  - the FIX-01 review follow-ups: comment or test that `SaleDraftStore.complete`'s receipt check is redundant with `SaleReceipt.fromCallable` (or resolve on mismatch); rename `showPendingReceipt` to say it reconciles; a shared cart-reset helper; a dedicated pending-receipt notice instead of the general message; and the duplicated shell test helper.
  - the FIX-02 review suggestions:
    - reword the "none is the default" test-helper comments;
    - use an options object instead of a positional `undefined` message in the correction test helpers;
    - named fields in the gateway reason table test;
    - put the expected reason in each preview failure-table row;
    - document that the client and server reasons ship together (`R4-reason-only-skew`, `R3-reason-only-client-coupling`).
  Route: delegated writer.
- [ ] FIX-04 — Reconcile and report. Route: parent.

## Acceptance criteria

- No committed sale or correction can lose its receipt without the seller seeing it on the next view.
- A stale attempt can never resolve or complete a newer draft.
- The client distinguishes correction rejections by `details.reason`, not by English text.
- All existing tests stay green; server codes and messages are unchanged.

## Evidence and progress

- Delivery forecast: roughly 1,500–2,500 authored lines, mostly tests. Strategy: feature-branch chain (cached), one reviewed commit per task.
- FIX-01 writer (delegated, Flutter):
  - **Store:** `SaleDraftStore` uses a store-wide revision counter that never resets, plus `complete`/`completedFor`/`acknowledge` by identity. `begin` refuses a different draft while a receipt is held.
  - **Shell:** `_submitSale` completes instead of resolving. `SaleCheckout.unacknowledgedReceipt` and `acknowledge` are checked against the exact seller.
  - **Controller and page:** a held receipt shows first on the next cart view or action, with the new notice "Hay una venta registrada que aún no revisas…". "Nueva venta" acknowledges it.
  - **Evidence (author-reported):**
    - Store: the stale-attempt RED was real.
    - Shell: 4 of 5 new tests were RED before the change.
    - 12 mutation probes, all killed.
- FIX-01 parent spot check: full `flutter test` 626/626.
- FIX-01 closure: high-risk four-lens native review `review-a0a7103a98ca727d` approved and acknowledged; commit tree exactly the approved candidate `d83059ea`; commit `3c426d8`.
  - The `R4`/`R3-complete-argumenterror-wedge` warning (a mismatch throw after commit would wedge the seller) is not reachable in practice. The parent verified that `SaleReceipt.fromCallable` already binds the branch, method and amount to the draft (`lib/sales/sale_draft.dart:167-185`). A clarifying comment or test is folded into FIX-03.
  - The other R2 suggestions are folded into FIX-03.
- FIX-02 writer (delegated, backend plus Flutter client):
  - **Shared reasons:** a new frozen `SALE_ERROR_REASONS` in `sales.js` covers `paymentMismatch`, `insufficientStock`, `folioAmbiguous`, `correctionWindowClosed` and `overReturn`. Every reason throw site uses it.
  - **Where they are thrown:**
    - `correction-window-closed`: `correction-support.js:78-79` (shared by every service and preview) and `sale-lookup.js:87-88`;
    - `insufficient-stock`: `sale-replacements.js:103` and `sale-exchanges.js:113`;
    - `over-return`: `sale-returns.js:264`, `sale-exchanges.js:372` and `sale-replacements.js:188-189`.
    - Codes and messages are unchanged; other rejections are asserted to carry no reason.
  - **Client:** the `CorrectionRejection` helpers match code plus reason; the English-message matching is removed with no fallback, because the client and server ship together.
  - **Evidence (author-reported):**
    - backend 19 RED, then GREEN;
    - 12 mutation probes, all killed;
    - emulator suites run once each: returns 6/6, replacements 7/7, exchanges 6/6, lookup 10/10.
  - **Accidental emulator start:** the writer once launched the emulator test files without their environment, and they stopped at the emulator guard within milliseconds, before any data access.
  - **Parent fix:** the writer stopped `partial` because `test/auth/emulator_login_corrections_test.dart` was outside its edit surface, a parent brief omission. The parent read and applied the writer's 2-line fixture patch (adding `reason` to two fixtures).
- FIX-02 parent checks: backend unit 320/320 from the root; `flutter test` 626/626.
- FIX-02 closure: high-risk four-lens native review `review-a6251fc25a03f411` approved and acknowledged; commit tree exactly the approved candidate `a66577e1`; commit `3fc3fc0`. The suggestions are folded into FIX-03.
- FIX-02 pending: one live HTTP transport run, which needs user approval. The harness now expects the reasons on the return over-return, the preview over-return and the replacement stock denials; it has no expired-window or exchange-stock denial.

## Next step

FIX-02 live run (needs user approval), then FIX-03.
