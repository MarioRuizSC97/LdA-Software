# Functions runtime identities

**Provisioned in `lda-inventory-dev-mx` on 2026-10-19; not deployed yet.** The
deployed callables still run as the default compute account until this tree is
deployed. Roll out with an owner-approved pilot first (gates below). These files
do not create accounts, roles, bindings, keys, or credentials.

## Provisioned state

| Custom role ID | Source file | Bound to |
| --- | --- | --- |
| `functionsFirestoreReader` | `firestore-reader.json` | `lda-functions-reader` |
| `functionsFirestoreWriter` | `firestore-writer.json` | `lda-functions-writer`, `lda-functions-profiles` |
| `functionsAuthLookup` | `auth-lookup.json` | `lda-functions-profiles` |

Roles are project-level custom roles (`projects/lda-inventory-dev-mx/roles/<id>`),
bound at project scope without conditions. The deploying user holds
`roles/iam.serviceAccountUser` on each of the three accounts only. No JSON keys
exist. The default compute account and its roles were not changed.

After editing a role file, apply it with
`gcloud iam roles update <id> --project=lda-inventory-dev-mx --file=<file>`.
Deleted custom role IDs cannot be reused for 37 days; update instead.

## Target and mapping

Target: `lda-inventory-dev-mx`, Gen2 Functions, region `us-south1`.
Account IDs below use `@lda-inventory-dev-mx.iam.gserviceaccount.com`.

| Account ID | Functions | Candidate role files |
| --- | --- | --- |
| `lda-functions-reader` | `quoteSale`, `findCorrectableSale`, `listRecentCorrectableSales`, `previewSaleReturn`, `previewSaleExchange` | `firestore-reader.json` |
| `lda-functions-writer` | `createProduct`, `setProductPrice`, `stockIntake`, `transferInventory`, `submitSale`, `submitSaleReturn`, `submitSaleReplacement`, `submitSaleExchange`, `markTransferNoticeRead` | `firestore-writer.json` |
| `lda-functions-profiles` | `setSellerProfile` | `firestore-writer.json` **and** `auth-lookup.json` |

`src/runtime-identity.js` supplies explicit `serviceAccount` options to all 15
callables, including shared sale wrappers. Unknown function names are rejected;
there is no default-account fallback. Region, CORS, request authorization,
project/emulator guards, and business handlers are unchanged. Importing the
configuration only builds SDK descriptors; it does not impersonate an account.
Local emulators do **not** enforce these IAM roles.

The JSON files are the **source of the custom-role definitions** listed above.
GCP accepted all permissions on creation, but effective access (including
denials) is only proven by the pilot in gate 3. `stage: GA` is role-definition
metadata, not proof of approval or successful validation. The source mapping
does not itself grant any of these permissions.

## Why these permissions

- Firestore transactions need `datastore.databases.get`; document reads need
  `datastore.entities.get`; the two sale lookup queries also need
  `datastore.entities.list`.
- Existing writer transactions create and update documents, without deleting
  them. The writer candidate intentionally excludes queries and deletion.
- Only `setSellerProfile` calls Admin Auth, with `getUser`; it needs
  `firebaseauth.users.get`, not user creation, update, deletion, custom claims,
  token signing, or Firebase Auth Admin.
- Provisioning/cleanup scripts are separate operator tools. Their permissions
  must not be copied to the runtime accounts.
- No runtime use of Storage, Secret Manager, Pub/Sub or the Logging API was
  found. The Functions logger writes to stdout/stderr, collected by Cloud Run;
  it does not justify adding `roles/logging.logWriter` by itself.
- Firestore IAM does not enforce seller, branch or document-level business
  isolation. Keep the backend authorization checks: Admin SDK bypasses client
  Firestore Security Rules.

## Local checks (Node 24+)

From the repository root:

```sh
npm --prefix functions run test:runtime-identity
```

This dedicated lane imports callable descriptors, tests all mappings and exact
role permission lists, and invokes handlers only with an untrusted project to
prove rejection before Admin initialization. It does not run Firestore/Auth
requests, start emulators, or create users. It is separate from the existing
`npm test` lane; do not use the default backend suite as a substitute here.

These checks prove configuration wiring and regression behavior, **not** actual
cloud IAM enforcement or equivalence to the currently deployed source.

## Owner-approved rollout gates — not executed

1. Record the actual deployed source/configuration, runtime account and rollback
   version for each function. Local Git HEAD alone is not deployed-source
   attestation. Inventory other consumers of the old shared account, especially
   Cloud Build. Confirm a safe test environment and disposable fixtures.
2. Obtain explicit permission before creating accounts/custom roles, changing
   bindings, enabling any additional API, reading test users/data or deploying.
   Validate custom-role support and binding scope first. Use managed identities
   and ADC; do not generate service-account JSON keys. The deployer may need
   `iam.serviceAccounts.actAs` on the new accounts; that is not a blanket runtime
   permission. Preserve service-agent permissions and existing callable access.
3. With separately authorized fixtures, test effective IAM using the new
   identities: readers can query but cannot write; writers can read/create/update
   but cannot delete or access Auth; the profiles account can look up users but
   cannot mutate Auth. Confirm transactions, callable authorization and logging.
   Emulators and these static permission-list tests cannot prove those denials.
   If safe cloud verification is unavailable, stop rather than migrate blindly.
4. Deploy an approved pilot, verify it, then migrate the remaining functions in
   bounded batches. Do not change CORS, data, client rules, public callable
   invocation policy, or provisioning flows as part of this identity migration.
5. On failure, stop the rollout and restore the recorded, verified prior source
   and account configuration. Keep the old account and bindings available for
   this rollback. Removing Editor from the old shared account is a **separate**
   decision, only after checking all other consumers; do not break build or
   platform service accounts to harden the Functions runtime.

## References

- [Firestore IAM method permissions](https://cloud.google.com/firestore/native/docs/security/iam)
- [Firebase runtime service accounts](https://firebase.google.com/docs/functions/manage-functions#service_account)
- [Firebase Auth permissions](https://cloud.google.com/iam/docs/roles-permissions/firebaseauth)
- [Cloud Run service identity and deployer permissions](https://cloud.google.com/run/docs/configuring/services/service-identity)
- [Cloud Run container logging](https://cloud.google.com/run/docs/logging#write-container-logs)
