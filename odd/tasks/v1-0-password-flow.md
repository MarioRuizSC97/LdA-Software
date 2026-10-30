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

- P1 · S4, D3 · error mapping for the Auth policy codes in the session layer · pending
- P2 · S2, D2 · change-password screen and its wiring · pending
- P3 · S3, D4 · reset action on the login screen · pending
- P4 · S5 · tests for P1-P3 · pending
- P5 · verification (analyze, suite), PR · pending

## Log

- L1 (2026-10-30, user, verbatim): see S1.
- L2 (2026-10-30, parent): why this is the prerequisite. The 10-character policy is enforced for new or changed
  passwords only (`forceUpgradeOnSignin` off) because the app has no change or reset path and maps unknown Auth errors
  to «No se pudo iniciar sesión. Revisa los datos» (`lib/auth/emulator_session.dart:170-178`,
  `lib/auth/emulator_login.dart:1128`). MFA stays off for the same reason (no `multiFactor` support in `lib/`).
