# Catalog Branch Code Compatibility

## Objective and authorization
User approved strict optional branch-code parser/tests/frontend-only refresh (2026-10-12). Accept `/^[A-Z]{2,4}$/` when present; preserve legacy absent-code branches, unknown-field denial, guards/names/reads. No data/rules/backend/dependency/emulator changes or commit/push/PR/merge. Preserve prior diagnostics/CLAUDE.md. Branch `feat/inventory-mvp-seller-profiles-v2`, HEAD `32df94cd397ec58b013d41802de0396ec44874dd`.

## Tasks
- [x] BC-01 — Parser/regression tests. Writer `mv5o2sw8-b-u8w4`; parent spot read passed. Source committed as `fd2f757` (ancestor of the current branch head).
- [x] BC-02 — Verification/review/runtime and user acceptance. Independent verifier `mv5oe956-c-rl0o`, native approval acknowledged, frontend served fix; user confirms catalog and Movimientos load. User also reports loading was possible before correction; do not attribute all runtime recovery solely to this fix.

## Verified evidence
- Actual read-only demo2branches contain legitimate code rejected by old allowlist; no values printed or records changed.
- Meaningful RED2realistic code-bearing loads fail old parser; GREEN49focused/full708Flutter/analyzer clean. Independent49/analyzer/format/diffcheck all exit0; full708 not independently rerun.
- Optionalcode validated/discarded, no UI field; invalid/null/types/case/length/control denied; absentlegacy/unknownfield/name/sessionguards preserved. Additional~194diff vs50–150forecast largely tests, same bounded scope.
- Native medium `review-b2f6a04fada51179` approved/acknowledged; burned revision `sha256:b6d1438b9d4dbd1f4dc956d0d794daf26da4f13ad1bc2d35e8e4a1bc8d99b311`, target `sha256:9e8c59e1291243980a9afa1ea0e7619ff8d0ed6f82de6e10c6e1bff64bbbe779`, tree `c32a3b24fbbae04733554b45cfeb059c99d4adaa`. Then-uncommitted diagnostics/trackers were included at review time; CLAUDE/runtime logs excluded. Classification-escape WARNING/dedup-const-key SUGGESTION informational, no correction/reopening.
- Verified frontend74323 gracefulTERM and relaunch81662 (launcher81660/compiler81699), same project/UID/no-pub/emulatordefine. Served repository JS confirms optionalcode/regex. Emulatorsnode50834/Java50905 unchanged on9099/5001/4400/8080; no data/SDK/protected requests by runtime worker. New log `odd/runtime/catalog-branch-code-compatibility/frontend-refresh-20261012.log`.
- Human confirmation: catalog loads and Movimientos opens. This validates current availability, not every screen behavior or sole historical failure cause.

## Incident and residuals
Runtime worker created unauthorized `/tmp/lda_root.html` and `/tmp/hdr.txt`; preserved/notdeleted. Separateverifier confirmed owner-matching regular single-link1531/379byte staticHTML/HTTPheaders, no credential-header/token indicators. EncodedFirestore reference inETag originunknown; not proof of leak/securitydefect. Scope deviation remains recorded. No native/mobile checks or full Movimientos form/filter acceptance newly performed. Prior diagnostic getter/dedup advisories remain separate follow-up. No commit/push.

## Next step
Continue original read-only visual Movimientos validation: rows/names/branch filter, no profile save or other data mutation without explicit scope. Do not infer that branchcode fix alone caused all observed recovery.
