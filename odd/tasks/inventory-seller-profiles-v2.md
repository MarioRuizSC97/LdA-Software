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

- [ ] SP-01 — Port the profile service and its unit tests: the main-style guard (demo project, Firestore 8080, Auth 9099), an injected environment, and a `SaleError`-style reason where useful. Route: delegated writer.
- [ ] SP-02 — The `setSellerProfile` administrator callable in `functions/src/index.js`, with callable unit tests and an emulator test. Route: delegated writer.
- [ ] SP-03 — Rules: `sellerProfiles` gets administrator GET only, with no list and no client writes. Confirm the administrator read and list rule on `inventoryMovements` and add the index the movements query needs. Add rules regression tests if a harness exists; otherwise accept over HTTP in SP-05. Route: delegated writer.
- [ ] SP-04 — Flutter administrator movements screen with name resolution and an assign/edit name form through a `setSellerProfile` gateway (session re-check, stale and uncertain handling as in the other gateways). Widget and gateway tests. Route: delegated writer.
- [ ] SP-05 — HTTP transport acceptance for `setSellerProfile`, the `sellerProfiles` rules and the administrator movements query, with one live run on user approval. Route: delegated writer plus verifier.
- [ ] SP-06 — Reconcile and report. Route: parent.

## Acceptance criteria

- Only an administrator can set a seller's name. The branch always comes from the seller's claims.
- Only an administrator can read a profile. Sellers and anonymous callers are denied, and LIST is denied for everyone.
- The movements screen shows names for profiled sellers, and "Vendedor sin nombre" plus "Asignar nombre" otherwise. No other seller data is shown.
- Movements and sales are unchanged; they still store only `actorId`.

## Evidence and progress

- Exploration (read-only, 2026-10-10): the old contract and reuse map; main touchpoints at `functions/src/index.js:41-99` (the administrator callable pattern), `firestore.rules:186-189` (`inventoryMovements` reads) and `:237-240` (catch-all deny). No Flutter administrator view of movements exists.
- Delivery forecast: about 2,500–3,500 authored lines across 5 work units. Strategy: feature-branch chain (cached), one reviewed commit per task.

## Next step

SP-01: port the profile service (delegated writer).
