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
- [x] IOS-EMU-02 — Run on the iPhone 18 Pro iOS 27.0 simulator with `LDA_LOCAL_EMULATORS=true`; confirm the login screen renders without a Firebase error. The user then signs in. Route: delegated verifier, then user acceptance.
- [x] IOS-EMU-03 — Fix iOS native init crash (apiKey format), simulator-only guard and review advisories. Route: delegated writer (source, new conditional-import files and tests). Committed as `6a639cf`.
- [x] IOS-EMU-04 — Detect the iOS simulator from the app executable path instead of `Platform.environment`. Route: delegated writer (source plus new test file, simulator validation). Committed as `b88b5d8` (assessed medium, under the review budget; no review due).
- [x] IOS-EMU-05 — Optional review follow-ups: rename `DemoEmulatorBootstrap.options` to `sharedOptions`, a `currentPlatform` wiring test through the simulator probe, per-field trust-gate mutation tests, and a sanitized console diagnostic for the swallowed session gateway bootstrap error. Route: delegated writer (source, new helper and test files). Committed as `bd5131d` (ancestor of the current branch head).

## Acceptance criteria
- iOS resolves to `127.0.0.1`; Android and web behavior is unchanged; other platforms still fail closed.
- `flutter analyze` clean and `flutter test` passing.
- The simulator shows the emulator login screen; the user can sign in and see the catalog.

## Progress and evidence
- IOS-EMU-01 (route: delegated writer; trigger: preparation reading plus source and test files). Committed as `4db6346`. Native review lineage `review-3440a5cf71b3b25c` approved (4 lenses, advisory findings only) and acknowledged.
  - RED 1: new tests in `test/firebase/emulator_bootstrap_test.dart` failed to compile (`Member not found: 'ios'`).
  - RED 2: with only the enum member added (host still unmapped), 3 tests failed (iOS `start`, iOS `startProductCreation`, iOS `currentPlatform` mapping); 24 passed, including the Android/web shared-options guard.
  - GREEN: `ios` added; `currentPlatform` maps `TargetPlatform.iOS` to `ios`; `_hostFor(ios)` is `127.0.0.1`; the unsupported error names Android, iOS and web. Web Auth preparation stays web-only.
  - Finding: native iOS FirebaseCore (`FIRApp.m`, `validateAppIDFormat`) raises "Configuration fails ... invalid GOOGLE_APP_ID" unless a v1 appId is `1:<number>:ios:<hex>`. The shared demo appId is web format, so iOS now uses `emulatorDemoIosOptions` (same demo project, key and sender; appId `1:1234567890:ios:0dda0dda0dda0dda`) via `DemoEmulatorBootstrap.optionsFor(platform)`. `_initializeTrustedApp` now checks against the platform's trusted options. Android and web options are unchanged.
  - Checks: `flutter test test/firebase/` 123 passed; `flutter test` 712 passed; `flutter analyze` no issues; `git diff --check` clean.

- IOS-EMU-02 first attempt: blocked. The simulator app aborted at native init with `[FirebaseInstallations][I-FIS008000] ... FirebaseOptions.APIKey doesn't match the expected format: API Key length must be 39 characters, API Key must start with A.`
- IOS-EMU-03 (route: delegated writer; trigger: source plus two new conditional-import files and tests).
  - Finding: `FIRInstallations.m` `validateAppOptions` requires non-empty app name, APIKey, googleAppID and projectID, then `validateAPIKey` requires exactly 39 characters, a leading `A`, and only alphanumeric, `-` or `_`. No GCMSenderID check there; the iOS appId format is already enforced by FirebaseCore (IOS-EMU-01).
  - RED 1: new tests failed to compile (`Member not found: 'DemoEmulatorBootstrap.platformFor'` and `'DemoEmulatorBootstrap.verifyTrustedApp'`).
  - RED 2: with the seams added and the old key, `iOS demo apiKey satisfies the native Installations format` failed (`Expected: <39> Actual: <12>`); 32 passed.
  - GREEN: `emulatorDemoIosOptions.apiKey` is the format-valid, obviously fake `A-demo-lda-inventory-emulator-only-0000` (project stays `demo-lda-inventory`; Android/web options unchanged). `currentPlatform` delegates to `platformFor(isWeb, target, isIosSimulator)`; iOS maps to `ios` only when `SIMULATOR_DEVICE_NAME` is set (`emulator_platform_io.dart`, conditionally imported; web uses `emulator_platform_stub.dart`), so a physical device is `unsupported` and fails before init (review R3-002/R4). The trust check is extracted into `verifyTrustedApp`, tested for iOS and Android match/mismatch and a wrong app name (review R3-001). `DemoEmulatorBootstrap.options` is documented as the shared Android/web set (R2; no rename, kept API compatible).
  - Checks: `flutter test test/firebase/` 129 passed; `flutter test` 718 passed; `flutter analyze` no issues; `git diff --check` clean.
  - Review R3-003 (plist missing in a clean checkout) refuted: `ios/Runner/GoogleService-Info.plist` is tracked since `29d0ebb`. Review R3-004 (settleAll error order) remains unscheduled.

  - Committed as `6a639cf`. Native review `review-5514ae0d5127c8f5` approved with 3 SUGGESTIONs (iOS options naming, no test of the `currentPlatform` to probe wiring, per-field trust-gate mutations) and acknowledged.
- IOS-EMU-02 second attempt: no native crash, but the login screen showed "Local Auth emulator unavailable". Root cause (observed via VM service): on the iOS simulator Dart `Platform.environment` is empty, so `isIosSimulator()` (`SIMULATOR_DEVICE_NAME` check) was always false, `platformFor` mapped iOS to `unsupported`, and the host lookup threw, swallowed by `lib/auth/emulator_login.dart` `catch (_)`.
- IOS-EMU-04 (route: delegated writer; trigger: source plus new test file and simulator validation).
  - Fix: `emulator_platform_io.dart` adds pure `isIosSimulatorExecutable(path)` (true only when the path contains `/Library/Developer/CoreSimulator/Devices/`); `isIosSimulator()` is `Platform.isIOS && isIosSimulatorExecutable(Platform.resolvedExecutable)`. Physical devices run from `/private/var/containers/Bundle/Application/...` and still fail closed. Web stub unchanged.
  - RED: new `test/firebase/emulator_platform_io_test.dart` failed to load (missing `isIosSimulatorExecutable`). GREEN: 3 tests pass (CoreSimulator path true, physical device path false, empty false).
  - Simulator: `flutter build ios --simulator --debug --dart-define=LDA_LOCAL_EMULATORS=true`, installed and launched on `9BF59A32-569D-465E-88F7-C1B065C7ED36`; after 12 s the screenshot shows the "Local emulator sign in" form (Email, Password, Sign in) with no bootstrap error.
  - Checks: `flutter test test/firebase/` 132 passed; `flutter test` 721 passed; `flutter analyze` no issues; `git diff --check` clean.

## User acceptance
- IOS-EMU-02 accepted by the user on 2026-10-12: signed in on the iPhone 18 Pro iOS 27.0 simulator (`LDA_LOCAL_EMULATORS=true`, built from `b88b5d8`) and confirmed the catalog and the other screens look right. First real run of Auth, Firestore and Functions on iOS. The simulator UI in Xcode 27 is `DeviceHub.app`; `open -a Simulator` does not exist.
- Not covered: physical iOS devices (fail closed by design), release builds, data-changing flows on iOS beyond what the user tried.

- IOS-EMU-05 (route: delegated writer; trigger: 2+ non-trivial files plus preparation reading).
  - Rename: `DemoEmulatorBootstrap.options` -> `sharedOptions`; the only callers were `lib/firebase/emulator_bootstrap.dart` and `test/firebase/emulator_bootstrap_test.dart`. Checked by analyze and tests.
  - Wiring: new `@visibleForTesting` `DemoEmulatorBootstrap.iosSimulatorProbe` (defaults to the conditional-import `isIosSimulator`). RED: the new tests failed to compile (`Setter not found: 'iosSimulatorProbe'`). GREEN: `currentPlatform` with an iOS target override returns `ios` when the probe is true and `unsupported` when false; a second test proves the default probe is the real one and is false on the test host.
  - Trust gate: per-field mutations (projectId, appId, apiKey) of `appOptions` for iOS and Android, explicit options kept trusted. Coverage-only GREEN: the existing gate already compared each field, so no RED was possible without breaking the code.
  - Diagnostic: new `lib/auth/emulator_bootstrap_diagnostics.dart` mirrors the catalog diagnostics pattern and prints `[emulator-bootstrap] stage=gateway category=<unsupported-platform|firebase|state|other> code=<allowlisted|other|none>`; `lib/auth/emulator_login.dart` reports before setting `_SessionFailure.bootstrap`. RED: the new test file failed to compile (missing helper); with the helper but the call removed, the widget test `reports one sanitized diagnostic` failed. GREEN with the call in place; a throwing reporter keeps the same failure view.

## Next step
Feature complete. The IOS-EMU-05 follow-ups described below were implemented and verified in the working tree, then committed as `bd5131d`. No native review receipt for IOS-EMU-05 is recorded; the historical checks below were observed at the time they were run and were not re-executed since.
