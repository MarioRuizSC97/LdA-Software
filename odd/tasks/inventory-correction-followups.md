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

- [ ] FIX-01 — Sale flow retry safety (Flutter): `SaleDraftStore` uses a revision counter that never resets. Sale success keeps the committed receipt until it is acknowledged (mirroring `CorrectionDraftStore.complete`/`acknowledge`), so a receipt that lands after the cart is disposed shows on the next catalog view, and no new sale can start unaware. Tests: the stale-attempt case, dispose during submit followed by success/failure/rejection, and the seller switch. Route: delegated writer.
- [ ] FIX-02 — Correction server reasons (backend plus Flutter client): add `details.reason` `correction-window-closed`, `insufficient-stock` and `over-return` (or the existing equivalents, if already defined) to returns, replacements, exchanges, previews and lookup where they apply, with codes and messages unchanged. Update the unit, callable and transport harness tests. Switch the Flutter `CorrectionRejection` helpers to reasons, keeping a message fallback only if justified. Route: delegated writer; one live run with user approval.
- [ ] FIX-03 — Review suggestions (Flutter tests and small fixes):
  - untested replacement failure branches (unresolved, stale with an explanation message, session with a stored draft);
  - the exchange blocked message not refreshing while the form is open;
  - exchange new-line controllers disposed before the field unmounts;
  - the hard-coded 16% IVA in `catalogCalculationFor` in the test fixtures;
  - the SALE-07 `R3-forged-folio-baseline` assertion.
  Route: delegated writer.
- [ ] FIX-04 — Reconcile and report. Route: parent.

## Acceptance criteria

- No committed sale or correction can lose its receipt without the seller seeing it on the next view.
- A stale attempt can never resolve or complete a newer draft.
- The client distinguishes correction rejections by `details.reason`, not by English text.
- All existing tests stay green; server codes and messages are unchanged.

## Evidence and progress

- Delivery forecast: roughly 1,500–2,500 authored lines, mostly tests. Strategy: feature-branch chain (cached), one reviewed commit per task.

## Next step

FIX-01: sale flow retry safety (delegated writer).
