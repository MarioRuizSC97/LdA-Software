# v1.0 password flow: change and reset

Give the app a way to change a password and to recover a forgotten one. Today neither exists, which is why the
10-character minimum cannot be enforced on existing passwords and why MFA cannot be turned on: a user who has to
change a password has no path except asking an administrator.

## Specs

- S1 (user, verbatim): "despues empecemo lo de la opcion de cambiar contraseña y olvide mi contraseña papurri".
- S2. Change password for a signed-in user: a screen reachable from the ☰ menu that asks for the current password and
  the new one twice, validates the new one against the server policy (at least 10 characters), reauthenticates with the
  current password, updates it, and confirms with a Spanish message. Wrong current password shows its own message, not a
  connection error.
- S3. Forgot password from the login screen: an action «¿Olvidaste tu contraseña?» that sends Firebase's reset email to
  the typed address and always answers the same way, so it never reveals whether an address has an account.
- S4. Honest messages: the server policy rejection (`password-login-requires-password-change`) and the weak-password
  rejection must be explained in Spanish instead of falling into the generic connection error.
- S5. Tests for every rule above, with a fake auth gateway; no test sends real email.

## Decisions

- D1. Email-only: no SMS recovery, no support phone numbers.
- D2. The reset action lives on the login screen; the change action lives in the side panel, next to the theme selector.
- D3. Reauthentication is required before a password change (Firebase requires it for sessions older than a few minutes
  and it is the honest check that the person knows the current password).
- D4. Same answer for known and unknown addresses on reset (anti-enumeration), matching the project's existing
  `enableImprovedEmailPrivacy`.
- D5. No new dependency: `firebase_auth` already exposes `sendPasswordResetEmail`, `updatePassword` and
  `reauthenticateWithCredential`.

## Tasks

- P1 · S4, D3 · error mapping for the Auth policy codes · 75ab592 · done
- P2 · S2, D2 · change-password screen and its wiring · done (ChangePasswordView + side-panel entry)
- P3 · S3, D4 · reset action on the login screen · done («¿Olvidaste tu contraseña?»)
- P4 · S5 · tests for P1-P3 · done (37 tests)
- P5 · verification (analyze, suite), PR · suite 1986 passed + 1 skipped, analyze clean · PR pending
- P6 · S2 · reachable from the wide bar, not only the side panel · 9795b33 · done (user report)
- P7 · S2 · two-column layout with a suggestions card on wide screens, like the login · done (user report)
- P8 · S3 · wider reset dialog with a blurred, dimmed background · done (user report)

## Log

- L1 (2026-10-30, user, verbatim): see S1.
- L2 (2026-10-30, parent): why this is the prerequisite. The 10-character policy is enforced for new or changed
  passwords only (`forceUpgradeOnSignin` off) because the app has no change or reset path and maps unknown Auth errors
  to «No se pudo iniciar sesión. Revisa los datos» (`lib/auth/emulator_session.dart:170-178`,
  `lib/auth/emulator_login.dart:1128`). MFA stays off for the same reason (no `multiFactor` support in `lib/`).
- L3 (2026-10-30, parent): implementation notes. Engine errors are classified by `classifyLoginFailure` (login) and
  `classifyPasswordChangeFailure` (change); the gateway only converts the codes that have a remedy, so every other
  failure keeps today's behaviour. The side-panel entry appears only when the session gateway also implements
  `AccountPasswordGateway`; the real Firebase gateway does, fakes do not, so existing tests are untouched. The reset
  action answers the same notice for success, unknown address and failure (anti-enumeration).
  Suite 1986 passed + 1 skipped (was 1957 + 1); analyze clean.
- L4 (2026-10-30, user report): "el cambio de contraseña en web solo funciona mediante el menu ☰ pero no
  debería aparecerme tambien de alguna forma en el header". Cause: the wide web/desktop bar has no side menu
  (`menuActions = mobilePlatform || compactBar`), so a panel-only entry is unreachable there. Fix: the bar shows a
  password icon beside the theme control; the panel keeps its entry. Test covers the wide bar, the compact panel and
  the absence of both without a gateway. Native tests report Android by default, so the wide case sets
  `debugDefaultTargetPlatformOverride` and resets it inside the test body (the framework checks it before tear-downs).
  Suite 1989 passed + 1 skipped, analyze clean.
- L5 (2026-10-30, user, with a screenshot of the login): "que aparezcan estas notas como sugerencias ... que salga o
  se presente en 2 columnas como habiamos quedado". The pattern is the wide-screen context rail (`PanelLayout` +
  context card, T15). The password screen now uses it with the login's card style (`Card.filled`, heading
  «Sugerencias», four notes); compact screens show the form alone because `PanelLayout` never mounts the rail there.
  Also verified: two different new passwords are refused without calling the gateway (UI test). Suite 1992 passed
  + 1 skipped, analyze clean.
- L6 (2026-10-30, user): "más ancho por defecto el cuadro de texto ... de olvidaste tu contraseña ... el difuminar el
  fondo manteniendo el hecho de que se oscurece". The reset dialog now reuses the cost PIN / intake confirmation framing
  (showGeneralDialog, blur 6, scrim at 0.32, 150 ms or none with reduced motion, tap outside cancels) and a 420 field.
  Tests: width >= 400, one BackdropFilter with a 0.32 scrim (RED before), tapping outside sends nothing. Suite 1994
  passed + 1 skipped, analyze clean.
