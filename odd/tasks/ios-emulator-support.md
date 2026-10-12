# iOS Local Emulator Support

## Objective and authorization
Let the iOS simulator build run in local emulator mode (`--dart-define=LDA_LOCAL_EMULATORS=true`) so the user can sign in and see live emulator data, as on web and Android. User-authorized on 2026-10-12. Local only: no cloud calls, no changes to the Firebase emulators or their data, no push.

## Problem and why
`EmulatorClientPlatform` only knows `android` and `web`. On iOS `currentPlatform` returns `unsupported` and `_hostFor` throws `Local Firebase emulators are supported only on Android and web.` (`lib/firebase/emulator_bootstrap.dart`). The iOS simulator shares the host network, so the emulators are reachable at `127.0.0.1`.

## Constraints
- Keep every existing safety guard: demo project only, exact loopback host and ports, fail closed on anything else.
- Do not widen support to macOS, Windows, Linux or physical iOS devices (a device cannot reach the Mac at `127.0.0.1`).
- Strict RED -> GREEN for the platform and host mapping.

## Tasks
- [x] IOS-EMU-01 — Add `ios` to `EmulatorClientPlatform`, map it to `127.0.0.1`, and add tests. Route: delegated writer (preparation reading plus source and test files).
- [ ] IOS-EMU-02 — Run on the iPhone 18 Pro iOS 27.0 simulator with `LDA_LOCAL_EMULATORS=true`; confirm the login screen renders without a Firebase error. The user then signs in. Route: delegated verifier, then user acceptance.

## Acceptance criteria
- iOS resolves to `127.0.0.1`; Android and web behavior is unchanged; other platforms still fail closed.
- `flutter analyze` clean and `flutter test` passing.
- The simulator shows the emulator login screen; the user can sign in and see the catalog.

## Progress and evidence
- IOS-EMU-01 (route: delegated writer; trigger: preparation reading plus source and test files). Done, uncommitted.
  - RED 1: new tests in `test/firebase/emulator_bootstrap_test.dart` failed to compile (`Member not found: 'ios'`).
  - RED 2: with only the enum member added (host still unmapped), 3 tests failed (iOS `start`, iOS `startProductCreation`, iOS `currentPlatform` mapping); 24 passed, including the Android/web shared-options guard.
  - GREEN: `ios` added; `currentPlatform` maps `TargetPlatform.iOS` to `ios`; `_hostFor(ios)` is `127.0.0.1`; the unsupported error names Android, iOS and web. Web Auth preparation stays web-only.
  - Finding: native iOS FirebaseCore (`FIRApp.m`, `validateAppIDFormat`) raises "Configuration fails ... invalid GOOGLE_APP_ID" unless a v1 appId is `1:<number>:ios:<hex>`. The shared demo appId is web format, so iOS now uses `emulatorDemoIosOptions` (same demo project, key and sender; appId `1:1234567890:ios:0dda0dda0dda0dda`) via `DemoEmulatorBootstrap.optionsFor(platform)`. `_initializeTrustedApp` now checks against the platform's trusted options. Android and web options are unchanged.
  - Checks: `flutter test test/firebase/` 123 passed; `flutter test` 712 passed; `flutter analyze` no issues; `git diff --check` clean.

## Next step
Commit IOS-EMU-01, then IOS-EMU-02.
