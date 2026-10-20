# Product rename backend (T8 / S7)

Status: **implemented, not deployed**. The `renameProduct` callable is a
candidate addition; the deployed set is still the 15 callables recorded in
`iam/README.md`. Catalog UI integration remains in the main session;
deployment requires the owner's separate approval.

## What it does

`renameProduct` (administrator-only) changes exactly one field of one product:
`products/{productId}.name`. Everything else stays untouched:

- `internalCode`, `quantitySpec`, `createdAt`, `pricing`, `pricingUpdatedAt`
  and `lastPricingAuditId` are never modified.
- No actor field, timestamp or other metadata is added to the product, so the
  strict public-product shape enforced by `firestore.rules` (`isPublicProduct`)
  still holds for seller reads.
- Historical sales keep the name they were sold with: the service never writes
  to `sales/**`.

## Request and response contract

Request `data` (exact fields, nothing more):

| Field | Validation |
| --- | --- |
| `idempotencyKey` | `/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/` |
| `productId` | same identifier pattern as pricing requests |
| `name` | canonical text of 1..120 JS string chars, no surrounding whitespace, no control characters — identical to `createProduct` name validation |

Success response:

```json
{ "productId": "PRD-…", "oldName": "before", "newName": "after", "replayed": false }
```

An identical retry returns the stored `result` with `"replayed": true`.

Error translation follows the existing catalog/pricing callables:
`unauthenticated` (no auth), `permission-denied` (non-administrator role),
`invalid-argument` (shape, identifiers, name), `not-found` (unknown product),
`already-exists` (idempotency key reuse with a different actor/product/name),
`failed-precondition` (outside the trusted runtime, or an invalid stored
receipt), `internal` (masked unexpected failure).

## Idempotency and atomicity

One Firestore transaction per request:

1. Reads the private receipt `productNameUpdateReceipts/{idempotencyKey}` and
   replays it when the fingerprint matches.
2. Reads the product and fails `not-found` without any write otherwise.
3. Updates only `{ name }` on the product and creates the receipt in the same
   transaction, so a rename is either fully applied or not at all.

The fingerprint binds `actorId`, `productId` and the new `name`, so the same
key reused by another administrator or for a different rename fails with
`already-exists` and no writes.

The private receipt stores `fingerprint`, `result` (`productId`, `oldName`,
`newName`), `completedAt` and `actorId`. It lives in
`productNameUpdateReceipts`, which no client rule allows. Unlike sibling
administrator-readable receipt collections, these receipts are denied to all
client SDKs by the catch-all rule in `firestore.rules`; the callable accesses
them through the Admin SDK. No rules or schema expansion was needed.

## Runtime identity and guard

- `src/runtime-identity.js` maps `renameProduct` to the existing
  `lda-functions-writer` service account, region `us-south1`, with the shared
  `LOCAL_WEB_ORIGINS` CORS list. It needs no new role: the writer candidate
  already grants create/update (no delete).
- The callable reuses the catalog guard (`assertLocalCatalogEmulator`): it runs
  only in the `demo-lda-inventory` local emulator or the deployed production
  project (`lda-inventory-dev-mx`), and refuses every other runtime before the
  Admin SDK is initialized.

## Testing

```sh
node --test functions/test/product-names.test.mjs   # unit, fake Firestore
npm --prefix functions test                          # includes the unit file
npm --prefix functions run test:emulator:product-names  # real Firestore emulator
npm --prefix functions run test:runtime-identity     # callable identity/regression
```

The emulator suite is a separate explicit lane (the shared default emulator
lane is pinned by `package-scripts.test.mjs`) and must be run against an
isolated emulator, not shared default ports.

## Pending work (main session)

- Catalog UI: administrator edit field in the same interface as the price,
  calling `renameProduct` (S7 UI integration; S5 detail sheet surface).
- Deployment approval and the IAM rollout gates in `iam/README.md` before the
  callable goes live.
