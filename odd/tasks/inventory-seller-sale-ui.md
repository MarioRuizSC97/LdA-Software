# Seller Sale UI

## Objective

Let branch sellers sell from the Flutter app: build a cart from their branch catalog, see the exact server-computed total, pay, and receive an on-screen receipt with a short folio and a QR. This unblocks the sale-corrections screens (INV-05 CORR-07), which need real sales and a usable receipt number.

## Problem and why

The backend `submitSale` callable exists and was accepted live (FUNC-03), but the app has no sale UI and no sale client. The only receipt identifier is the client-generated 36-character `saleId` UUID, which a customer cannot dictate or type. The corrections backend (INV-05 CORR-01..06B) is complete, but it is unusable from the app until sales exist there.

## Product decisions (user, 2026-10-08)

1. The receipt number is a folio made of the branch code and the first 8 characters of the `saleId` UUID, for example `NTE-3F2A-9C1B`. The receipt also carries a QR with the full `saleId` for a future scanner. Folio lookup is scoped to the seller's branch and the 15-day correction window, and must handle ambiguity.
2. Each branch has a new short, unique `code` field: 2–4 uppercase letters, validated server-side.
3. For now the codes are assigned in the demo seed and provisioning script (`NTE` for `branch-north`, `SUR` for `branch-south`). The server rejects a sale in a branch without a valid code. Admin branch management is a later feature.
4. Sales are built as a cart from the seller's branch catalog: add a product with a quantity at its precision, edit or remove lines, choose the payment method and the invoice option, then confirm. A sale can have multiple lines.
5. The cart total comes from the server, through a new read-only quote callable that uses exactly the sale calculation. The cart is re-quoted whenever it or the invoice option changes.
6. After confirming, the seller sees an on-screen receipt: the folio in large type, the QR, the lines, the total, the payment method, the invoiced flag, and the date and time, plus a "New sale" action. Ticket printing is deferred and must not start until the user explicitly asks for it.
7. The existing seller catalog page is the point of sale. Each card has an "Add" action, and a fixed cart button shows the line count and total. The flow goes from cart to receipt. Bottom-tab navigation is a saved future idea.
8. The seller sale screens show user-visible text in neutral, professional Spanish, as plain strings with no i18n framework yet. Code, identifiers, comments, tests and commits stay in English.

## Scope

In scope:
- the branch `code` field and its seed;
- the folio on stored sales;
- folio-based lookup for corrections;
- the quote callable;
- the Flutter sale domain, gateway, cart UI and receipt screen;
- unit, widget, emulator and HTTP transport tests.

Out of scope:
- ticket printing;
- QR scanning;
- admin branch management;
- bottom-tab navigation;
- the correction screens (CORR-07, which resumes after this feature);
- translating the rest of the app.

## Constraints

- Branch `feat/inventory-mvp-seller-sale-ui`, created from `028a4a8` (corrections branch, which already holds the corrections backend). Local work-unit commits only; push and PRs are the user's decision.
- Delivery strategy: feature-branch chain (cached INV-05 choice). Each task is a reviewable work unit.
- Test-first, with the pinned Node `/Users/luismarioruiz/.local/share/lda-node24/runtime/bin/node` and Flutter `FLUTTER_SUPPRESS_ANALYTICS=true $HOME/develop/flutter/bin/flutter test --no-pub` / `flutter analyze --no-pub`.
- Live runs only against the already running local emulators, with owned data, teardown and user approval.
- Money stays integer centavos and quantities stay canonical decimal strings with `BigInt`; never `double`.
- No acquisition costs ever reach sellers.

## Tasks

- [x] SALE-01 — Backend folio and branch code. Sales read the branch `code` (reject a missing or invalid code), derive the folio and store it on the sale. Keep replay exact. Update the strict stored-sale validation in sale lookup and corrections, the demo seed (`NTE`, `SUR`), and every test that seeds branches. Route: delegated writer.
- [ ] SALE-02 — Read-only `quoteSale` callable: seller-only, branch from claims, current pricing, exact `calculateSale` total. Report insufficient stock without writing anything. Route: delegated writer.
- [ ] SALE-03 — Folio lookup for corrections: `findCorrectableSale` accepts a folio, scoped to branch and window, with ambiguity handling. Route: delegated writer.
- [ ] SALE-04 — Flutter sale domain and gateway: cart model with `BigInt` validation, quote and submit callable adapters following the stock-intake gateway pattern (session re-check, stale generation, code whitelist, uncertain handling, idempotency key per draft), bootstrap wiring, unit tests. Route: delegated writer.
- [ ] SALE-05 — Flutter cart UI on the seller catalog: "Agregar" per card, the cart button and panel, re-quote, payment method and invoice, confirm, uncertain-retry lock, and Spanish copy. Widget tests. Route: delegated writer.
- [ ] SALE-06 — Flutter receipt screen: folio, QR (`qr_flutter`, already a dependency), lines, totals, payment, invoiced flag, date and time, "Nueva venta". Widget tests. Route: delegated writer.
- [ ] SALE-07 — HTTP transport acceptance for the quote, folio and folio lookup, live with user approval; then reconcile evidence and commits, and report pending checks. Route: delegated writer plus verifier, then the parent.

## Acceptance criteria

- The total shown in the cart always equals the amount charged; the payment is never typed by hand.
- Every new sale has a unique, branch-prefixed folio, and the receipt shows it along with the QR.
- A sale fails closed without a valid branch code. Existing replay, idempotency and seller restrictions are unchanged.
- Sellers can find a correctable sale by folio within their branch and window.
- No cost data reaches sellers. Demo fixtures stay unchanged except for the approved `code` seed field.

## Evidence and progress

- Exploration (read-only, CORR-07 map, 2026-10-08):
  - The seller sees only the catalog of their branch (`lib/catalog/catalog_page.dart`, about 2,390 lines; inline forms; no router or dialogs).
  - The gateway pattern lives in `lib/firebase/emulator_stock_intake_gateway.dart`, and `BigInt` decimals in `lib/catalog/stock_intake.dart`.
  - The shell is `lib/auth/emulator_login.dart`. UI strings are English today.
  - `qr_flutter ^4.1.0` is already in `pubspec.yaml`.

- SALE-01 writer (delegated; route trigger: cross-cutting backend plus many test fixtures). 14 files, +435/−61.
  - **Folio:** `saleFolio(code, saleId)` builds `<CODE>-<XXXX>-<XXXX>` from the first 8 alphanumeric characters of the key, uppercased. Keys are not required to be UUIDs (the existing key contract is kept), but a UUID key yields exactly the specified folio. A new sale whose key has fewer than 8 alphanumeric characters fails with `invalid-argument`; the check runs only after a replay miss.
  - **Branch code:** `^[A-Z]{2,4}$`, read by `submitSale` after the branch-existence check. A missing or invalid code fails with `failed-precondition` and writes nothing.
  - **Receipt:** now v2, `{version: 2, saleId, branchId, branchCode, folio, productIds, calculation, payment}`. A v2 replay rebuilds the folio from the stored `branchCode`. v1 sales still replay and validate unchanged.
  - **Storage:** the sale document stays `{receipt, createdAt}`. A composite index on `sales` (`receipt.branchId`, `receipt.folio`, `createdAt` DESC) supports the future folio query.
  - **Uniqueness:** the seed rejects duplicate codes. The server does not enforce uniqueness per sale, and folios can collide, so folio lookup must filter by branch and treat multiple matches as ambiguous.
  - **Lookup and corrections:** the strict validation accepts exact v1 or v2. For v2 it requires `folio === saleFolio(code, docId)`. `validateStoredSale` now returns `folio` and `branchCode`. The correction services needed no change.
  - **Seed:** branch-north gets `code: 'NTE'` and branch-south `code: 'SUR'`.
  - **Live demo impact (not applied):** the existing live branch documents have no `code`, so re-provisioning stops on the shape check, and a live sale in a demo branch fails with `failed-precondition` until both documents get their `code`. That is the user's decision.
  - **Evidence (author-reported):** RED, then GREEN across `sales`, `sale-lookup`, `correction-support`/`returns`, `provision`, `sales-callable` and the corrections transport rehearsal. The emulator suites (sales, lookup, returns, replacements, exchanges) ran once: 32/32 with owned cleanup. The provision emulator test was not run, because it writes demo data.
- SALE-01 parent spot check: offline unit suite from `functions/`: 277 tests, 275 pass. The 2 failures are the known owned-Auth deadline child tests, which resolve paths from the repository root; from the root they pass 20/20. Transport offline: 35 pass, 2 skipped.

- SALE-01 closure: native review `review-5b58bdfec9ef5de2` approved; commit tree exactly the approved candidate `89bad557`. Findings:
  - `R3-fake-sale-folio-shape` (WARNING): the folio in the sales transport fixture is hand-written. The parent verified it is correct (key `http-12345678…` gives `HTS-HTTP-1234`), but it is brittle; compute it with `saleFolio`-equivalent normalization later.
  - `R3-live-demo-branch-code-gate` (WARNING): the live demo branches lack `code`, so live demo sales are refused until they are migrated. This is a known user decision, still pending.

- Live demo branch-code migration (user-approved 2026-10-08, parent, emulator REST with an update mask on `code` only and `currentDocument.exists`): `branches/branch-north` got `code: 'NTE'` and `branches/branch-south` got `code: 'SUR'`. `name` and `demoSeedVersion` are unchanged, so both now match the seed shape exactly. This resolves `R3-live-demo-branch-code-gate` for the local emulator.
- Routing: SALE-02 and SALE-03 go to one delegated writer as one backend work unit (both small, both server-side, related by lookup and quote reuse). Reviewed and committed together.

## Next step

SALE-02 and SALE-03 (quote callable and folio lookup).
