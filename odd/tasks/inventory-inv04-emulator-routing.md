# INV-04 emulator routing and intake bootstrap closure

## Goal and continuity
Close this isolated, already accepted INV-04 unit before INV-05. Overall tracker: original `odd/tasks/inventory-mvp.md`; final functional/human acceptance is complete, formal closure remains open. This record does not replace that tracker or its historical Engram mirror.
- A `/Users/luismarioruiz/LdA-Software`: accepted read-only source; HEAD `f11af7ae7ec9bc166cabcbf945e9eac588a2e66b`.
- B `/Users/luismarioruiz/LdA-Software-review-intake`: starting/current HEAD `3911c8c206c06d63f7a7acf4d810e456a23afb41`. Skills/domain/gateway/branch-choice predecessors already approved; do not replay them as candidates.
- Current-session Engram read/write communication verified; previous ended-session blocker resolved.

## Authority, scope and constraints
Human selected `authorize_routing_bootstrap_1420`: nine exact accepted A files, 1,420 source/test diff lines, all coverage retained, local verification/native review and local commit only after approval. Existing feature-branch chain; size exception only for this unit. Native context capacity is independent: stop on admission/authority failure, never trim tests or bypass review.
Human subsequently selected `authorize_existing_sdk_dependency_copy`: prepare only existing ignored A `firebase/tests/node_modules` in B, verify existing bytes, no installs/downloads/version/configuration changes; complete pending checks.
Human explicitly selected exceptional local acceptance after the same SDK-type premise blocked the reopened review again. For this unit only, that decision supersedes the original native-approval-before-commit condition: complete independent verification, preserve valid source and tests, make a local work-unit commit without claiming native approval, and restore the user-owned review switch afterward. The native findings remain deferred, not resolved. No push, publication or module-wide acceptance is authorized.
The human disabled RDD at clone scope; read-only mode status confirmed global `on`, clone-local/effective `off`, revision `sha256:d98d3ca4573797cf086109abce32e3cd4fb88869696abf75b67a27b5f0af958b`. This is a clone-wide policy exception, not a reviewer verdict or candidate-specific receipt. The parent must observe restoration before subsequent implementation.
Single delegated writer; preserve A (including user-owned CLAUDE.md), B predecessors, live frontend/emulators and data. No reconstructed intermediate or formatting/source repairs. Exclude shell/main/widget/catalog UI, creation/pricing/cost/notices, dependencies manifests/config/backend/rules, browser/service operations, cloud/push/publication. Only the nine paths below plus the expressly authorized ignored dependency copy are writable by the worker; parent owns this record, review and delivery.

## Frozen accepted source
| Path | SHA-256 |
| --- | --- |
| `lib/firebase/emulator_auth_routing.dart` | `970da61db002b18cfb2b0c0c1595016c13c7809e538d6df6d7209acf5c0c2218` |
| `lib/firebase/emulator_auth_routing_platform.dart` | `e60f625fea2812269c38df07825b674973cc61675d48a9fa6a122ba69a149425` |
| `lib/firebase/emulator_auth_routing_preinit.dart` | `0510b0e8d874e4d9798d5d2407c5b921df5a5042ed8bd6a527ebc12b42ec151b` |
| `lib/firebase/emulator_auth_routing_stub.dart` | `72b086bffa85f863435c558d552a94d4667d7edcde0fd20ba86d7ff79957c7bb` |
| `lib/firebase/emulator_auth_routing_web.dart` | `5d9088bac2a08ba63a1bd42580ff9700195df953e652a3839a2a35a5ec3fef9a` |
| `lib/firebase/emulator_bootstrap.dart` | `5482acb7800cffde9a2373cdc7c83f35b8c0105ac1aff872e26beafc40677cde` |
| `test/firebase/emulator_auth_routing_test.dart` | `4977305f6f8d82c43265ef8cd7b64249a6a9d642d178d01337cad3085fa6c7bc` |
| `test/firebase/emulator_bootstrap_test.dart` | `15067997c72abdfb066b0a939abbf9b8dd5ef8f38724fb4357388a410c15c892` |
| `firebase/tests/auth-web-routing.test.mjs` | `b0f85d0b2eea2d02fde882f7de7b0ca4a6d51ff7cedc66cf9c3981d7d636e50c` |

## Task and route
- [ ] **INV-04-ROUTING-CLOSE-01 — Materialize, verify and close this unit.** In progress. Initial materialization delegated to `gentle-ai-worker` (multi-file trigger); final technical verification delegated to `gentle-ai-verify` (high-risk verification), parent owns the local commit and this record. Current closure uses the explicit human exception, not native approval. Do not mark complete without observed checks, local commit identity and review-mode restoration. Native review follow-up remains deferred separately.

## Acceptance and observed evidence
Exact accepted-source materialization has no meaningful new RED; test-first policy is not disabled, and original RED is not reenacted. Run proportional checks on B. No web/native build or live browser transport claim; installed-SDK tests use mocked transport, not browser integration.
Worker `musu47tj-4-nxe4` copied all nine files byte-identically, frozen SHA256s matched before/after; +1408/-12 = 1,420 lines. A HEAD/index/status and 8,610-source-file fingerprint unchanged; B changes limited to nine targets and this record, nothing staged.
- Focused Flutter bootstrap/auth-routing/gateway/domain (`--no-pub`): PASS 81.
- Full B Flutter suite (`--no-pub`): PASS 220.
- Flutter analyze (`--no-pub`): PASS, no issues.
- Initial Node 24.21.0 installed-SDK test FAILED `ERR_MODULE_NOT_FOUND` (0 passed/1 failed); format/diff checks were initially skipped after prerequisite stop. No source defect was established.
- Authorized preparation `musuc9ls-5-j2po` copied existing ignored dependencies only: 9,448 files, 3,367 directories, one internal symlink; A-before/A-after/B manifests matched SHA256 `0a10611c36e35ca3cf808885cb7adf026f882d52f7c8f1933b90d5e218a23768`; SDK 12.19.0. No installs/downloads/configuration changes.
- Independent verifier `musuf316-6-3h9s`: PASS 81 focused, 220 full Flutter, clean analysis, 3 Node SDK tests (zero failures/skips), nonwriting format 8 files/0 changes, tracked and untracked whitespace checks clean. Previous missing-prerequisite failure is resolved.
- Independent pre/post nine hashes, HEAD/index/status and 147 nonignored entries per checkout unchanged (CLAUDE.md excluded); dependency file/tree/symlink comparison identical. Earlier worker 8,610-file fingerprint and dependency-manifest digest were not independently reproduced. Visible B scope is two tracked modifications, seven new source/test paths and this document; nothing staged.
- Read-only native assessment was unassessable because intended untracked scope had not yet been declared; treated as high and independent verification completed. RDD is on globally; switch unchanged.
- Native review `review-3a47f713490e8795` froze candidate tree `1e0861db74a4fc4a19ab9e931d39509f171df810`, target `sha256:9d964cb75d18b1ad3fdf5c5cf86d3148d9ab045d0c96b42cfebcf38f8afa0921`, high tier and 200 logical-correction budget. The human applied same-lineage reopening for resilience/readability/reliability while retaining risk. Three fresh reviewers and the native refuter again ended at `correction_required`, last observed revision `sha256:5e19ca654fd61f3bbebdbc136696a74eb5c707b7e0910131772faaa5cec0b9cf`. Latest findings: `R2-001`, `R3-001`, `R4-web-startup`, asserting that SDK persistence/debug/resolver exports are objects. No correction, approval, acknowledgement, consumption, reset or abandonment occurred.
- Final independent verifier `muvnp99s-8-1l03`: PASS 81 focused Flutter tests, 220 full Flutter tests, clean analysis, 3 SDK tests with zero failures/skips, nonwriting Dart format 8 files/0 changes, and tracked/untracked whitespace checks. All nine frozen source hashes, B HEAD, index entries, visible scope and task document stayed unchanged. No failed or skipped requested check. A and the ignored dependency tree were not independently fingerprinted again in this run.
- That verifier imported the exact installed browser entry used by the SDK tests (`@firebase/auth/dist/esm/index.js`): Node 24.21.0, Firebase 12.19.0, `@firebase/auth` 1.13.6. All seven queried exports were functions: `initializeAuth`, `connectAuthEmulator`, `debugErrorMap`, `indexedDBLocalPersistence`, `browserLocalPersistence`, `browserSessionPersistence`, `browserPopupRedirectResolver`. This directly contradicts the disputed export-type premise but is technical evidence, not an admitted native verdict. Transport/persistence remain mocked; no browser E2E, live emulator, native build or new web build is claimed.
- Exception-path ASSESS remained unassessable because intended-untracked declaration was required; treated as high, with independent verification completed. The parent-required SDK spot check `muvns768-9-z33z` passed 3/3 tests again and independently confirmed 9/9 frozen source hashes. This passive record update does not alter any of the nine accepted source/test bytes and is not a native correction candidate.
- Local commit and review-mode restoration: pending. Ordinary delivery follows explicit human authorization, not a native receipt.

## Deferred native review follow-up
Keep the original lineage/findings and contradictory installed-SDK evidence discoverable. Revisit through a supported native maintenance/review route if available, or when a reproducible functionality conflict or relevant SDK change provides a new bounded work unit. Do not reset/reopen an unchanged review blindly, fabricate an approval, replace valid function checks with object checks, or claim this deferred native review is closed. Future fixes require their own reproduction, scoped tests and authorization; do not assume every failure has this cause.

## Next step
Final checks and the one-command SDK spot check are complete. Commit exactly the nine accepted source/test paths plus this record locally, then ask the human to restore RDD for the clone and verify effective `on`. Record the work-unit commit identity after it exists. Only then close this local unit under the human exception. The overall INV-04 tracker and remaining shell/UI closures are still open; map them separately before INV-05. Payment/receipt/correction details for INV-05 remain bounded product decisions; no assumed defaults.
