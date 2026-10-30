# v1.0 security hardening

Apply the low-effort fixes from the 2026-10-30 external-attacker review (Engram `odd/v1-0/security-review`): close
public sign-up, bound correction and sale line arrays, patch the functions dependencies and add Hosting security
headers. Budget alerts, App Check, password policy and MFA are reviewed with the user afterwards.

## Specs

- S1. User request, verbatim: "Dale papurri empieza con las que mencionas cuando termines vemos las demás faltantes y
  me dices en donde podría configurarlas yo o si se puede que sea en conjunto (tu y yo) mejor :)". "Las que
  mencionas" are the review's items 1, 3, 4 and 5:
  - S1.1 (item 1) "Desactivar el registro desde Auth; tú seguirás creando las cuentas desde la consola."
  - S1.3 (item 3) "Poner un máximo de líneas en ventas, cotizaciones y correcciones, con pruebas."
  - S1.4 (item 4) "`npm audit fix`, pruebas y volver a desplegar."
  - S1.5 (item 5) "Añadir `X-Frame-Options`, `nosniff` y `Referrer-Policy` en `firebase.json`."
- S2. Afterwards, show where the user configures the remaining items (2 budget, 6 App Check, 7 passwords/MFA), doing
  them together where possible.

## Decisions

- D1. Line limit 50, the same as transfers (`TRANSFER_LINE_LIMIT`), exported once as `SALE_LINE_LIMIT` and applied
  before any document read to sale/quote lines, return lines, replacement lines and exchange return/new lines. A
  51-line request is `invalid-argument` with the caller's existing message; 50 still validates.
- D2. Sign-up is closed in the production Auth config (`client.permissions.disabledUserSignup`). Admin SDK
  provisioning and console-created accounts keep working. Verified live by a refused sign-up that creates nothing.
- D3. Hosting headers on every path: `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`. No script-source CSP: the
  Flutter web build loads CanvasKit from Google's CDN, and a wrong CSP would blank the app.
- D4. When reading the Auth config, never print `signIn.hashConfig` (lesson from the review).

## Tasks

- H1 · S1.3, D1 · line limits with tests · inline · pending
- H2 · S1.4 · `npm audit fix` in functions, tests · inline · pending
- H3 · S1.5, D3 · Hosting headers · inline · pending
- H4 · S1.1, D2 · close public sign-up (production config) · inline · pending
- H5 · deploy functions + Hosting, live checks, PR · pending
- H6 · S2 · walk the user through items 2, 6, 7 · pending

## Log

- L1 (2026-10-30, user, verbatim): see S1.
- L2 (2026-10-30, parent): baseline on main b76fc34: sales 63, sale-quote 9, sale-exchanges 25, sale-returns 23,
  sale-replacements 16, correction-support 5 pass; sales-callable, corrections-callable, sellerProfiles-callable fail on
  main already (not in `npm test`).
