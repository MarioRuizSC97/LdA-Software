# Seller Profiles and Admin Movements (v2)

## Objective

Let administrators see who made each stock movement and sale by name. Sellers get a server-written profile (`displayName`, `branchId`). Administrators get a movements screen that resolves each movement's `actorId` to the seller's name only, and can assign or edit a seller's name from there.

## Problem and why

Movements, sales and audits store only the seller's `actorId` (the decision recorded in `odd/tasks/inventory-functional-acceptance.md:79`). There is no way to tell who a seller is, and the app has no administrator view of movements at all. An earlier attempt (worktree `LdA-Software-seller-profiles`, branch `feat/inventory-mvp-seller-profiles`, based on `166bee0`) became a custom GAPIC/gRPC single-attempt Firestore adapter with new dependencies. Its no-retry gate was self-imposed, not a product need, and the profile write is an idempotent two-field set that is safe under `runTransaction` retries.

## Product decisions

Earlier decisions, carried over from the old `odd/tasks/seller-profiles-backend.md`, still apply:

1. `sellerProfiles/{uid}` stores exactly `displayName` and `branchId`.
2. Only trusted server code writes profiles, through an administrator callable. The request is exactly `{uid, displayName}`; the branch comes from the target's Auth claims (role `seller` with a valid branch claim). Identical content is a no-write replay.
3. Only administrators may GET a profile by UID. No LIST. Sellers and anonymous callers cannot read profiles, and every client write is denied.
4. Movements, sales, receipts and audits keep only `actorId`. No names or profile snapshots are added to them.
5. Administrators may maintain the profile of a disabled seller. Claims are never changed. User provisioning, role assignment, bulk backfill and profile deletion are out of scope.

New decision (user, 2026-10-10):

6. Redo the feature simply on the current chain, reusing the sound parts of the old attempt (the SPI-01 service and its tests). Scope: profiles, plus an administrator movements screen that shows the seller's name (only the name), with assign and edit name from that screen.

## Defaults (parent; revisit if the user objects)

- **Movements screen:** administrator-only, showing the most recent movements newest first, with an optional branch filter. Each row shows type, product, quantity, branch, date and the seller's name.
  - The client reads `inventoryMovements` directly; rules already allow administrator reads.
  - Names are resolved with administrator GETs of `sellerProfiles/{actorId}`, cached per screen.
  - An actor without a profile shows "Vendedor sin nombre" plus a short id, and offers "Asignar nombre". Rows written by an administrator show "Administrador".
- **Demo fixtures are not seeded with profiles.** The demo seed stays unchanged; names are assigned from the screen.

## Reusable pieces from the old attempt

- Keep and adapt:
  - `functions/src/sellerProfiles.js`: replace its isolated-port guard with a main-style emulator guard that also checks the Auth emulator host, and inject `environment`;
  - `functions/test/sellerProfiles.test.mjs`;
  - `functions/test/sellerProfiles-callable.test.mjs` (from old commit `567276a`).
- Discard the GAPIC adapter, the lifecycle, factory and binding modules, the isolated emulator config, the 820-line transport test, and the new dependencies. The old branch stays untouched as a reference.

## Constraints

- Branch `feat/inventory-mvp-seller-profiles-v2`, created from `6a2b82c` (the top of the chain). Local work-unit commits only; push and PRs are the user's decision.
- Test first, with the pinned Node and Flutter commands. No new dependencies.
- Keep each work unit well under the native review budget (about 3,000 lines).
- A live HTTP run happens only with user approval. Never start or stop emulators, and never touch demo fixtures.
- Administrator UI copy is in neutral Spanish; code is in English.

## Tasks

- [x] SP-01 — Port the profile service and its unit tests: the main-style guard (demo project, Firestore 8080, Auth 9099), an injected environment, and a `SaleError`-style reason where useful. Route: delegated writer.
- [x] SP-02 — The `setSellerProfile` administrator callable in `functions/src/index.js`, with callable unit tests and an emulator test. Route: delegated writer.
- [x] SP-03 — Rules: `sellerProfiles` gets administrator GET only, with no list and no client writes. Confirm the administrator read and list rule on `inventoryMovements` and add the index the movements query needs. Add rules regression tests if a harness exists; otherwise accept over HTTP in SP-05. Route: delegated writer.
- [x] SP-04 — Flutter administrator movements screen with name resolution and an assign/edit name form through a `setSellerProfile` gateway (session re-check, stale and uncertain handling as in the other gateways). Widget and gateway tests. Route: delegated writer.
- [x] SP-04b — Fix the SP-04 review warnings: a stale profile read overwriting a saved name, unobservable load failures, administrator-predicate drift, and the duplicated branch pattern; plus the review suggestions. Route: delegated writer.
- [x] SP-05 — HTTP transport acceptance for `setSellerProfile`, the `sellerProfiles` rules and the administrator movements query, with one live run on user approval. Route: delegated writer plus verifier.
- [x] SP-06 — Reconcile and report. Route: parent.

## Acceptance criteria

- Only an administrator can set a seller's name. The branch always comes from the seller's claims.
- Only an administrator can read a profile. Sellers and anonymous callers are denied, and LIST is denied for everyone.
- The movements screen shows names for profiled sellers, and "Vendedor sin nombre" plus "Asignar nombre" otherwise. No other seller data is shown.
- Movements and sales are unchanged; they still store only `actorId`.

## Evidence and progress

- Exploration (read-only, 2026-10-10): the old contract and reuse map; main touchpoints at `functions/src/index.js:41-99` (the administrator callable pattern), `firestore.rules:186-189` (`inventoryMovements` reads) and `:237-240` (catch-all deny). No Flutter administrator view of movements exists.
- Delivery forecast: about 2,500–3,500 authored lines across 5 work units. Strategy: feature-branch chain (cached), one reviewed commit per task.
- SP-01 and SP-02 writer (delegated, one backend work unit):
  - **Port:** the old SPI-01 contract is ported unchanged. The isolated-c guard is replaced by `assertLocalSellerProfilesEmulator`, which requires the exact demo project, Firestore `127.0.0.1:8080` and Auth `127.0.0.1:9099`, and runs before authorization.
  - **Errors:** `SellerProfileError` carries the reasons `not-a-seller`, `invalid-branch-claim` and `invalid-stored-profile`. `saleHttpsError` is renamed `reasonedHttpsError` and shared.
  - **Lazy Auth import:** `setSellerProfile` imports `firebase-admin/auth` lazily after the guard. A static import would break the fail-closed loaders in the sales and corrections callable tests.
  - **Evidence (author-reported):**
    - RED, then GREEN; 7 mutation probes, all killed.
    - The emulator test ran once, 1/1, with owned `sp-*` users and a `branch-<uuid>` branch. Afterwards 0 profiles and 0 `sp-*` users remained, and no demo fixtures were touched.
  - **Not done:** the emulator test is not in `package.json` `test:emulator`, which was outside the edit surface.
- SP-01 and SP-02 parent spot check: backend non-emulator 388/388.
- SP-01 and SP-02 closure: native review `review-2fa427f257bb3e7e` (medium, one lens) approved with no findings and acknowledged; commit tree exactly the approved candidate `4dc33528`; commit `46e2170`.
- SP-03 writer (delegated):
  - **`sellerProfiles` rule:** an administrator may GET; LIST and every write are denied.
  - **Movements:** every movement type writes `occurredAt` from the transaction timestamp, plus `type`, `branchId`, `productId`, a signed `quantityScaled`, `unit`, `precision` and `actorId`. The SP-04 query is `inventoryMovements`, with an optional `where(branchId ==)`, then `orderBy(occurredAt desc)` and `limit(50)`. The existing rule lets an administrator list with or without the filter. A seller can list only with their own branch filter.
  - **Index:** `branchId` ASC plus `occurredAt` DESC.
  - **Rules tests:** `firebase/tests/rules.test.mjs` adds describes for "seller profiles" and "administrator movements query".
  - **Rules tests not run (exception):** the harness uses project `demo-lda-inventory` and calls `clearFirestore()` in `beforeEach`, so running it against the live demo emulator would destroy the fixtures. Checks run instead: syntax OK, index JSON OK, backend 388/388. Rules behavior is accepted over HTTP in SP-05.
- SP-03 closure: native review `review-bc843d4f439b60fa` (medium, one lens) approved and acknowledged; commit tree exactly the approved candidate `17f5186e`; commit `40c2970`.
  - Suggestion `R3-001`: no filtered-order case with two north movements. The emulator does not enforce composite indexes, so the index is proven only on deploy.
- SP-04 writer (delegated, Flutter):
  - **New files:**
    - `lib/movements/inventory_movement.dart` (strict parse; malformed documents show as "Movimiento ilegible" rows, so they are never silently skipped);
    - `lib/movements/seller_profiles.dart`;
    - `lib/movements/administrator_movements.dart` (a fakeable Firestore source with session re-checks);
    - `lib/movements/movements_view.dart`;
    - `lib/firebase/emulator_seller_profile_gateway.dart`.
  - **Wiring:** the administrator-only "Movimientos" app-bar action and the shell `administratorMovementsLoader`.
  - **Branch filter:** "Todas" plus the catalog's `branchChoices`.
  - **Actor labels:** stock intake shows "Administrador"; a seller with a profile shows only the name; without one, "Vendedor sin nombre (…)"; if the lookup is unavailable, "Nombre no disponible (…)".
  - **Name dialog:** assign or edit, with an uncertain same-name retry and Spanish messages for each reason.
  - **Finding:** the existing `formatScaledQuantity` in `lib/sales/sale_format.dart` misformats negative values with a nonzero remainder. SP-04 uses its own signed BigInt formatter; the existing helper is unchanged because current callers pass only non-negative values.
  - **Evidence (author-reported):** compile-level RED, then GREEN; 13 mutation probes, with 11 killed and 2 equivalent.
- SP-04 parent spot check: `flutter test` 669/669.
- SP-04 closure: high-risk four-lens native review `review-f6c634e50600c04d` approved and acknowledged; commit tree exactly the approved candidate `724c68ca`; commit `f6c4a6b`. Its warnings and suggestions go into SP-04b.
- SP-04b writer (delegated):
  - **Fixes:**
    - a per-uid save counter stops a late profile read from overwriting a saved name, and a background failure never downgrades a confirmed name (real RED observed);
    - `MovementsUnavailable` keeps its cause, which is logged as `lda.movements`. Firestore `failed-precondition` (missing index) and `permission-denied` get specific Spanish messages;
    - a shared `isSameExactAdministrator` in `lib/movements/administrator_session.dart` replaces the old check. The repository had accepted an expected session with a branch (real RED);
    - a shared `isBranchId`;
    - `isSellerUid` is renamed `isPathSafeUid`;
    - shell tests for loader retry and a fresh backend per administrator;
    - catalog tests for closing the view on a session change or removal.
  - **Evidence (author-reported):** 12 mutation probes, all killed.
- SP-04b parent spot check: `flutter test` 685/685.
- SP-04b closure: high-risk four-lens native review `review-4833e384e4afc5ae` approved and acknowledged; commit tree exactly the approved candidate `98e6c412`; commit `87f1c8e`.
  - Suggestions:
    - comment the magic `loaderFailures = 2`;
    - add a widget test for losing the session while a load is pending.
  - Out-of-scope copies remain: the branch regex in `emulator_session.dart` and `firestore_catalog_repository.dart`, and the per-gateway administrator checks in stock intake and product creation.
- SP-05 writer (delegated): `functions/test/sellerProfiles-callable-transport.emulator.test.mjs` (989 lines). It is gated by `LDA_SELLER_PROFILES_HTTP_ACCEPTANCE=1` plus the fixture baseline and runtime approvals.
  - **16 live steps:**
    - `setSellerProfile`: refusal of a non-seller with `not-a-seller`, create, replay, rename, and denials for anonymous, unassigned, client and seller;
    - an owned stock intake that creates a movement;
    - profile rules over REST: an administrator GET is allowed; seller, client, unassigned, anonymous and foreign GETs are denied; LIST and client writes are denied;
    - the administrator movements `runQuery`, unfiltered and branch-filtered;
    - a seller's unfiltered query is denied, and a seller's own-branch query is allowed.
  - **Owned data:** a branch, a product, 4 profile slots and the intake documents, with exact teardown.
  - **Offline:** 9 rehearsal and forgery tests; 6 mutation probes, all killed.
- SP-05 parent spot check: transport file offline 9 pass, 1 live skipped.
- SP-05 test closure: native review `review-349d11e9711bd24c` (medium, one lens) approved and acknowledged; commit tree exactly `f1e3a4eb`; commit `e1ff2aa`.
  - Warning `R3-live-step-failure-does-not-abort`: a failed live step does not stop the scenario. It stays safe, because the manifest marks the run uncertain and refuses later requests, but secondary failures cascade.
- SP-05 live run (user-approved, exactly once, HEAD `ff200c6`, verifier):
  - OPTIONS 204 for `setSellerProfile` and `stockIntake`.
  - 26/26 pass, with all 16 live steps green.
  - The administrator GET returned the exact profile, so the emulator had loaded the new `sellerProfiles` rule.
  - Fixtures unchanged: combined hash `5ddfb8b8…`, 104 documents with an identical listing, and 2 Auth users. No residue.

## Final report (SP-06, 2026-10-10, parent, HEAD at closure)

- **Outcome:** seller profiles v2 is complete.
  - Administrators set a seller's name through `setSellerProfile`; the branch always comes from the seller's claims.
  - Profiles are readable only by administrators: no LIST and no client writes.
  - The administrator "Movimientos" screen shows recent movements, optionally per branch, with each seller shown only by name, and an assign or edit action.
  - Movements and sales still store only `actorId`.
- **Commits:**
  - `46e2170` (SP-01/02)
  - `40c2970` (SP-03)
  - `f6c4a6b` (SP-04)
  - `87f1c8e` (SP-04b)
  - `e1ff2aa` (SP-05)
  - Each one went through native review, was approved, and has a tree equal to its approved candidate. Every commit is an ancestor of HEAD. Nothing is pushed.
- **Final checks (parent, observed):**
  - backend non-emulator tests 388/388;
  - `flutter analyze` clean;
  - `flutter test` 685/685;
  - SP-05 live 26/26 (log re-checked by the parent).
- **Not covered:**
  - The rules unit harness was never run; it would clear the shared demo project. Rules are accepted over HTTP instead.
  - The composite index (`branchId` + `occurredAt`) is not enforced by the emulator, so it is proven only on deploy.
  - There was no device or integration run of the Flutter screen.
- **Open suggestions (optional):**
  - live step failures cascade (`R3-live-step-failure-does-not-abort`);
  - the magic `loaderFailures = 2` comment;
  - a widget test for a session lost while a load is pending;
  - add the new emulator tests to `package.json` `test:emulator`;
  - unify the remaining branch-regex and administrator-check copies in `emulator_session.dart`, `firestore_catalog_repository.dart` and the stock intake and product creation gateways;
  - `formatScaledQuantity` misformats negative values (no current negative callers).
- **Old attempt:** the branch `feat/inventory-mvp-seller-profiles` (worktree `LdA-Software-seller-profiles`) is superseded and kept untouched, with its uncommitted work, as a reference. Deleting or archiving it is the user's decision.
- **Branch chain:**
  1. `feat/inventory-mvp-sales-corrections`
  2. `feat/inventory-mvp-seller-sale-ui`
  3. `feat/inventory-mvp-sale-corrections-ui`
  4. `feat/inventory-mvp-correction-followups`
  5. `feat/inventory-mvp-seller-profiles-v2`

## Next step

Feature complete. Waiting for the user's next priority (push and PR strategy for the branch chain, the optional suggestions, the old seller-profiles branch, or ticket printing when the user asks).
