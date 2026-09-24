# Inventory MVP — implementation tasks

## Objective
Build the first reviewable foundation for a single-company, multi-branch inventory app on Android, iOS, and internal web. Maintain branch-scoped stock, trusted online mutations, immutable movement history, and admin-only purchase costs.

## Accepted scope and constraints
- Flutter project: `lda_inventory`; organization: `com.ldasoftware`.
- Firebase Auth, Firestore, Functions, Storage, Hosting, Security Rules, and emulators are the proposed stack; project/environment/region and billing remain unselected. Never touch a production Firebase project without separate authorization.
- Initial product sale price is global and administrator-editable with an audit trail; sales preserve their actual price. Branch overrides are future work.
- Current acquisition-cost reference is the latest entry cost; each entry retains its actual historical cost. Weighted average, margins, and profit reports are future work.
- Sellers have branch-limited access and cannot read acquisition costs. Inventory writes are online, transactional, idempotent, and cannot make available stock negative.
- MVP includes catalog and QR identity, stock intake, sales and internal receipts, partial returns, exchanges, warranty states, immediate branch transfers, and destination in-app notices. Excludes offline writes, suppliers, credit, fiscal integration, refund reconciliation, and public commerce.

## Delivery and verification
- Route: ODD, not SDD. One writer at a time; delegate multi-file implementation and command-running verification.
- Delivery strategy: ask-on-risk. Forecast: substantially above 400 authored changed lines for the whole MVP; use reviewable work units and decide chain strategy before crossing the delivery threshold. Generated scaffold files are excluded from authored-line estimate.
- Git: unborn `main`, no baseline commit, `.gitignore` untracked. Do not treat this as damaged review authority; RDD is globally on. A feature branch and initial baseline commit are prerequisites to ordinary commit-based RDD review. No commit has been authorized explicitly yet.
- TDD mode: unresolved (no project/session configuration found); runner: unavailable until Flutter SDK and scaffold exist. Do not infer TDD from test presence. Planned Flutter checks: `flutter analyze` and `flutter test`; Firebase rules/Functions checks require selection of runtime and emulators.
- Environment (read-only preflight, 2026-09-24): no Flutter/Dart or Firebase CLI installed; Android Studio and Android SDK are present, but Android SDK command-line tools are missing. Full Xcode is absent (Command Line Tools present), so iOS builds cannot yet run. Node 26 and Android Studio JDK 21 are installed; compatibility needs validation before Firebase/Gradle work. Homebrew is available. Prefer an official user-local Flutter SDK and install other tools only after explicit authorization. Installation scope and Firebase project are not yet approved.

## Tasks
- [ ] **INV-01 — Establish local development baseline.** Route: delegated verification/environment mapping (tooling and Git preflight); bounded writer if multiple files change. Confirm SDK installation approach, install only with authorization, establish a feature branch and root baseline commit only after explicit commit approval. Acceptance: `flutter doctor -v` and CLI versions recorded, suitable SDK available, Git HEAD valid. Checks: environment diagnostics and `git status`/`git log`. Status: pending; blocked on tool installation and commit authorization.
- [ ] **INV-02 — Scaffold Flutter platforms and basic quality gate.** Route: delegated writer (multi-file generated scaffold). Generate Android/iOS/web with the confirmed identifiers using installed SDK; add minimal meaningful app smoke test and document commands. Acceptance: project boots and `flutter analyze`/`flutter test` pass; record platforms actually built. Status: pending.
- [ ] **INV-03 — Establish local Firebase boundary and identity.** Route: delegated writer. Confirm project ownership, local/staging/production strategy, region, billing, and enabled products before configuring; use official CLI generation and local emulators; add least-privilege rules plus emulator-backed tests for access boundaries. Acceptance: local setup and permission tests pass without deploy. Status: pending; requires Firebase decisions.
- [ ] **INV-04 — Implement the first catalog and stock-entry vertical slice.** Route: delegated writer. Admin-managed products and global sale price with audit, protected cost/entry records and stock projections backed by immutable movements; tests cover role isolation, transaction concurrency, idempotency, and insufficient stock. Acceptance: tested local slice with server-owned writes; no seller cost exposure. Status: pending.
- [ ] **INV-05 — Add sales and corrections.** Route: delegated writer. Branch-scoped sale with snapshot price/payment/internal receipt; cancellation, partial returns, exchanges, and warranty status transitions with reasons and immutable compensating movements. Acceptance: emulator-backed end-to-end flows and failed-permission cases. Status: pending.
- [ ] **INV-06 — Add transfers and MVP validation.** Route: delegated writer plus independent verification as applicable. Immediate atomic transfer and next-open destination notice; cross-platform UI, accessibility, and comprehensive emulator tests. Acceptance: negative stock/concurrency/role controls demonstrated, actual platform coverage reported. Status: pending.

## Progress and evidence
- 2026-09-24: User approved beginning implementation and confirmed identifiers. Read-only preflight found an unborn Git repository, missing Flutter/Dart/Firebase CLI, Android Studio with SDK but no command-line tools, and no full Xcode. No app code or configuration changed.
- Commits: none. Reviewed boundaries: none. Authored changed-line running count: 0. RDD candidate: none.
- Next: request approval for user-local Flutter SDK setup and for creating a branch/root baseline commit; defer Xcode/Firebase setup to their applicable tasks. Do not present any pending task as complete.
