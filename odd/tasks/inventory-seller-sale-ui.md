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
- [x] SALE-02 — Read-only `quoteSale` callable: seller-only, branch from claims, current pricing, exact `calculateSale` total. Report insufficient stock without writing anything. Route: delegated writer.
- [x] SALE-03 — Folio lookup for corrections: `findCorrectableSale` accepts a folio, scoped to branch and window, with ambiguity handling. Route: delegated writer.
- [x] SALE-04 — Flutter sale domain and gateway: cart model with `BigInt` validation, quote and submit callable adapters following the stock-intake gateway pattern (session re-check, stale generation, code whitelist, uncertain handling, idempotency key per draft), bootstrap wiring, unit tests. Route: delegated writer.
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

- SALE-02/03 writer (delegated, one backend work unit):
  - **`quoteSale`** (new callable): request exactly `{invoiceRequested, lines:[{productId, quantity}]}`, seller-only; response `{calculation, totalCentavos, lines:[{productId, available}]}`. Short stock is reported per line, never thrown. It is read-only and exposes no costs, branch or code.
  - **Shared quote code:** `createSaleQuoteService` lives in `sales.js`. `submitSale` was refactored onto shared helpers (`saleLinesInput`, `readSaleLines`, `prepareSaleLine`, `authoritativeCalculation`) that the quote reuses, so there is no duplicated pricing validator. `submitSale` error precedence is unchanged and locked by a test. The CORR-05 exchange copy of the validator is untouched; that drift risk still stands.
  - **`findCorrectableSale` folio lookup:** accepts exactly one of `{saleId}` or `{folio}`. The folio is trimmed and uppercased, then matched against `^[A-Z]{2,4}-[A-Z0-9]{4}-[A-Z0-9]{4}$`. The query filters on the branch, the folio and the window, newest first, `limit(3)`, using the SALE-01 index.
    - 0 matches → `not-found`, also for foreign or expired folios. Unlike the `saleId` path, an expired own sale by folio is `not-found`.
    - 2 or more matches → `failed-precondition` "folio is ambiguous".
  - **Lookup and list responses** now include `folio` (null for v1).
  - **index.js:** the shared `localSaleCallable` helper serves `quoteSale` and the corrections.
  - **Evidence (author-reported):** RED then GREEN for quote 9/9, lookup 23/23 and callables 39/39; 15 mutation probes, all killed. The quote and lookup emulator tests ran once: 14/14, owned branches with codes, no residue.
  - **Size:** about 940 lines against a 500–800 forecast, mostly parity and consistency tests.
- SALE-02/03 parent spot check: all offline unit tests run from the repository root pass 297/297; transport offline 35 pass, 2 skipped; the source hashes match the writer report.

- SALE-02/03 closure: native review `review-c14c45cd358064fa` approved; commit tree exactly the approved candidate `e38fba6f`. Finding `R3-folio-unicode-casefold` (SUGGESTION): Unicode uppercasing before the ASCII check lets a few non-ASCII characters (the long s, the dotless i) normalize into a valid folio. This is harmless for authorization; reject non-ASCII input before uppercasing later.

- SALE-04 writer (delegated, Flutter domain and gateway, no UI):
  - **Domain (`lib/sales/`):**
    - `sale_cart.dart`: `SaleCart`, `SaleCartLine` with BigInt validation at the product precision, and `SalePaymentMethod`. Duplicate products are rejected, not merged, because merging could change per-line rounding.
    - `sale_quote.dart`: a strict `SaleCalculation`/`SaleQuote` parser bound to the cart, with `allAvailable` and `unavailableProductIds`.
    - `sale_draft.dart`: `SaleDraft.fromQuote` generates the key once (lowercase UUID v4), with the amount equal to the quoted total; `saleFolio` mirrors the server.
    - `SaleReceipt.fromCallable` validates a strict v2 receipt bound to the draft. It checks the folio equals `saleFolio(code, key)` and that payment, draft amount and calculation total are equal. v1 receipts are rejected.
    - `SaleDraftStore` keeps one unresolved draft per seller and branch.
  - **Gateway:** `lib/firebase/emulator_sale_gateway.dart`.
    - It provides `quote` and `submit`, with an exact seller session check before and after, and separate stale counters.
    - The whitelist is `invalid-argument`, `not-found`, `failed-precondition`, `out-of-range`, `permission-denied`, `unauthenticated` and `already-exists`, mapped to Rejected with the server message. `internal` maps to Uncertain.
    - The request is built before the session check, so local validation errors are never reported as uncertain.
  - **Bootstrap:** `initializeSaleGateway` (`quoteSale`, `submitSale`), sharing a private live-functions helper with stock intake; a loader in `main.dart`. It is not wired into the shell yet.
  - **Receipt time:** `submitSale` returns only `{receipt, replayed}`, so `confirmedAt` is the client clock at acceptance; for a replay it is the confirmation time, not the original sale time. Follow-up candidate: return `createdAt` from the server.
  - **Evidence (author-reported):** RED (missing files, missing bootstrap member), then GREEN; sales 19/19, gateway 9/9.
  - **Size:** about 2,050 lines against a 600–900 forecast, because of the strict-parser forgery matrices and doc comments.
- SALE-04 parent spot check:
  - `flutter analyze`: no issues.
  - Full `flutter test`: 387/387.
  - The 315 baseline was stale; HEAD had 358.

- SALE-04 closure: native review `review-08f71b3fcf672526` approved; commit tree exactly the approved candidate `7f121024`. Follow-ups:
  - `R3-sale-bootstrap-wiring-unproved` (WARNING): the bootstrap is untested for callable binding. The parent verified `quoteInvoke` is bound to `'quoteSale'` and `submitInvoke` to `'submitSale'`, correctly spelled and not swapped; a test is still missing.
  - `R3-sale-callable-mapping-untested` (WARNING): there is no test for the translation from `FirebaseFunctionsException` to `SaleCallableException`.
  - `R3-stale-not-applied-to-failures` (SUGGESTION): a superseded call that fails surfaces as Rejected or Uncertain instead of Stale.

  Fold all three into SALE-05.

- SALE-05 writer (delegated, Flutter cart UI):
  - **New files:**
    - `lib/sales/sale_cart_controller.dart`: `SaleCheckout`, plus `SaleCartController` (a `ChangeNotifier` holding quote status, generation, pending, locked draft and receipt).
    - `lib/sales/sale_cart_panel.dart`: add control, quantity entry, cart button, completed notice and panel.
    - `lib/sales/sale_format.dart`: the formatters, moved verbatim from the catalog page.
  - **Catalog page (+79/−31):** optional `saleCheckout` and `onSaleCompleted` parameters. The controller exists only for sellers with a checkout. The cart button sits in `bottomNavigationBar`. "Agregar" appears only on priced products.
  - **Shell:** `saleGatewayLoader` plus a shell-level `SaleDraftStore`, and one cached gateway per exact seller and branch. Begin, submit and resolve stay inside the shell, following the intake pattern; the page sees only `unresolvedDraft()`. Administrators get no checkout.
  - **Spanish UI copy:** for example "Agregar", "Carrito", "Factura", "Método de pago", "Efectivo/Tarjeta/Transferencia", "Cobrar", "Sin existencias suficientes", "No se pudo calcular el total", "Reintentar", "Venta registrada · Folio …".
  - **Outcome handling:**
    - Stale results (success or failure) are ignored.
    - A payment mismatch re-quotes, and the next charge uses a new key.
    - Uncertain locks the cart, and "Reintentar" resubmits the identical draft.
    - A session error locks the draft or shows a re-login message.
  - **SALE-04 follow-ups resolved:**
    - a `createSaleGateway` seam proves the `quoteSale` and `submitSale` binding;
    - `saleCallableFromInvoker` tests the code and null-message mapping;
    - `_staleAware` makes superseded failures stale.
  - **Evidence (author-reported):** compile and behavior RED, then GREEN; 20 mutation probes, all killed.
  - **Incident during probing:** an early probe loop ran `git checkout --`, which reverted the writer's own two uncommitted Task B lib edits. The writer re-applied them identically and switched to backup-and-restore. The parent confirmed the follow-up edits are present and HEAD is unchanged at `973c270`.
  - **Size:** about 2,520 lines against a 900–1,400 forecast, mostly tests and fixtures.
- SALE-05 parent spot check:
  - `flutter analyze`: no issues.
  - Full `flutter test`: 418/418.
  - The follow-up symbols (`saleCallableFromInvoker`, `_staleAware`, `createSaleGateway`) are present.

## Next step

Review and commit SALE-05, then SALE-06 (receipt screen, with the server returning `createdAt` proposed).
