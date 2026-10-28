# Post-v1.0 ideas (deferred on purpose)

Every item below was explicitly left out of v1.0 during the UI rounds. Each line names where the decision was recorded. Nothing here is scheduled; the user decides order and scope.

## Accounts and access

- Capturista account/role: a separate login that can create products but whose Firestore rules deny cost reads. Replaces the v1.0 PIN privacy curtain with a real server-side boundary. Source: odd/tasks/v1-0-ui-t20.md D2 ("A ahora + B después").
- Google / Apple sign-in, ideally restricted to the company domain (Google Workspace). Must be designed together with the Capturista role because both change how accounts get their role and branch. Apple requires a paid developer account and, on iOS, Apple sign-in must be offered whenever Google sign-in is. Source: odd/tasks/v1-0-ui-t22.md L3.
- PIN attempt limit / lockout for the privacy curtain (no rate limiting today). Becomes unnecessary once the Capturista role exists. Source: T20B verification notes.
- Administrator selling as a seller sub-profile without logging out (server sale callable requires role seller). Source: odd/tasks/v1-0-ui.md L2 item 6.
- Seller name in movements via a server-written sellerProfiles/{uid} (displayName, branchId). Source: odd/tasks/inventory-functional-acceptance.md (product decision 2026-10-07).

## Inventory and catalog

- Seller can request another branch's stock from the product sheet (rules deny it on purpose today). Source: odd/tasks/v1-0-ui-t19.md D6.
- Low-stock reminders/alerts. Source: odd/tasks/v1-0-ui-t17.md D1.
- Source branch in the seller's transfer notice title ('Traslado del 27 oct, 14:05 · desde North'). Source: odd/tasks/v1-0-ui-t22.md D5 (T22G), deferred by the user on 2026-10-28 (L16). Full analysis and plan: Engram topic `odd/backlog/d5-origen-en-avisos`.
  - Verified blocker: `functions/src/transfers.js` `leg()` writes only `type, transferId, branchId (destination), productId, quantityScaled, spec, actorId, occurredAt`; the source branch exists only on `transfers/{idempotencyKey}`, which notices never read. The client model deliberately excludes "source-branch audit fields and costs" (`lib/transfers/transfer_notice.dart`).
  - Proposed route: add `sourceBranchId` to the `transfer-in` leg only, publish it in `InventoryMovement`, carry it on `TransferNotice`, resolve the name with the existing branch map, and justify the boundary change in the model comment (branch name yes, costs never).
  - Also required: a decision for old notices without the field (backfill from `transfers/{id}` or show "origen no registrado", never a raw id), `firestore.rules` check if instead reading `transfers/{id}`, a deploy with explicit approval, and tests (with origin, without origin, accessible semantics without UUID).
- Shared warehouse concept (stock is per branch only). Source: odd/tasks/v1-0-ui.md L2 item 3.
- Product image / richer product profile (needs Firebase Storage). Source: odd/tasks/v1-0-ui.md L2 item 4.
- Editing a product's unit after creation (unit is copied into stock, movements and sales). Source: odd/tasks/v1-0-ui.md L2 item 7.
- Advanced catalog filters (price, stock, branch) and scanning a QR from a gallery photo. Source: docs/catalog-search.md "Out of scope".

## Sales, corrections and fiscal

- Ticket printing. Source: odd/tasks/v1-0-ui.md objective.
- CFDI / invoice and credit-note emission, bank or refund reconciliation, administrator reporting screens. Source: odd/tasks/inventory-inv05-corrections.md "Out of scope".
- Repair tracking and per-product correction windows. Source: same.

## Engineering

- One command that runs both test passes (VM suite + web suite on Brave), so the web-only test can never hide a regression again. Source: odd/tasks/v1-0-ui-t21.md L4 (offered, pending).
- Reviewable history: the v1.0 branch (~20k lines) exceeds the Gentle AI reviewer budget as one candidate; review by slices before merging. Source: repeated lens_context_budget_exceeded on the whole branch.
