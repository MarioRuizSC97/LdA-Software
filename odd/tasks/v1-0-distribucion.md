# v1.0 distribution: minimum-version gate and privacy notice

Prepare LDA Inventory v1.0 for distribution outside the developer's Mac: a minimum-version gate that must ship in the
first distributed build, and the privacy notice (aviso de privacidad) the stores and the public web URL require.
Web camera scanning is evaluated only after the Hosting URL works.

## Specs

- S1. Minimum-version gate (user request: "Si por fa papurri añade el control y todo lo que involucre"). Agreed design
  (assistant proposal accepted by the user): "En Firestore guardas un dato, por ejemplo `versión mínima = 1.0.0`. Al
  arrancar, la app compara su versión con ese dato. Si está por debajo, se bloquea con un mensaje como «Hay una versión
  nueva, actualiza para continuar» y un enlace a la tienda o una recarga en web. Cuando publicas algo incompatible,
  subes ese número y todas las copias viejas se detienen solas."
- S2. "todo lo que involucre": the gate includes its Firestore rules, tests, the operator procedure to raise the
  minimum, and docs.
- S3. Privacy notice: "para ver si me puedes ayudar tambien a hacer el aviso de privacidad tambien que de eso no tengo
  ni idea con eso de que es la primera web que publico no sé que debería incluir dicho aviso".
- S5. Web URL (user, verbatim): "Dale papurri empecemos con la URL :)" — publish the web app on Firebase Hosting
  (`https://lda-inventory-dev-mx.web.app`) so it works outside the developer's Mac.
- S4. Web camera: "y ya una vez teniendo la URL en funcionamiento vemos si se puede habilitar el uso de camara desde la
  web obvio usando un celular" — evaluate after Hosting works; not part of this batch.

## Decisions

- D1. The gate must ship in the first distributed build: an installed copy without it can never be forced to update.
- D2. Publishing (Hosting, rules deploy, callables redeploy) stays a separate, explicitly approved step.
- D3. The privacy notice is a draft for the owner; it is not legal advice and needs the owner's identity data.
- D4. Gate data: Firestore document `appConfig/client` with `minimumVersion` (string `MAJOR.MINOR.PATCH`) and
  optional `androidUpdateUrl`, `iosUpdateUrl`. The URL fields ship now because builds already installed can never
  learn a new field later; while a URL is absent the screen shows text only. A missing document means no minimum.
- D5. Rules: `appConfig/client` allows anonymous single-document `get` only (the gate runs before login); `list` and
  every client write stay denied; every other `appConfig` path stays denied. Operators edit it in the Firebase console.
- D6. Failure policy is fail-open: missing document, malformed version, read error or a read slower than a bounded
  timeout let the app continue. The gate is a delivery nudge, not a security boundary, and a config outage must not
  stop the stores from selling. The app's own version comes from `lib/app/app_info.dart` (pinned to pubspec).
- D7. Blocking screen copy (Spanish): title «Actualización necesaria», body «Hay una versión nueva de LDA Inventory.
  Actualiza la app para continuar.» Web action «Recargar» reloads the page; mobile action «Abrir la tienda» opens the
  platform URL when present. The screen also shows the installed and the required version.
- D9. Hosting step: serve `index.html`, `flutter_bootstrap.js`, `main.dart.js` and the other app files with
  `Cache-Control: no-cache`, so «Recargar» always revalidates against the published build instead of a browser copy
  (Firebase Hosting otherwise lets browsers cache up to an hour). The generated `flutter_service_worker.js` only
  unregisters itself, so it caches nothing.
- D10. Callable CORS allows exactly `https://lda-inventory-dev-mx.web.app` and
  `https://lda-inventory-dev-mx.firebaseapp.com` (exact strings, https only) in addition to the existing localhost
  patterns; every other origin stays rejected. Firebase Auth already authorizes both domains and the browser key has no
  referrer restriction (checked 2026-10-30). Deployed functions match main (last functions change 9ae695c was deployed
  2026-10-20), so redeploying only adds the origins.
- D8. The gate sits in front of the session gate in the connected modes (production and emulator), so both a restored
  session and the login screen are blocked; demo and offline modes are untouched.

## Tasks

- V1 · S1, S2, D4–D8 · version gate (client + rules + tests + docs) · branch `feat/v1-0-version-gate` · commits c578fee (rules), 54175fe (client), 6a400ae (docs) · DONE
- V2 · S3 · privacy notice draft (Markdown + web page) · pending — waits for the owner's data
- V3 · S4 · web camera evaluation · deferred until the Hosting URL works
- V4 · S5, D9, D10 · web publish: callable CORS for the Hosting origins, `hosting` in firebase.json, deploy callables
  then Hosting, verify the URL · branch `feat/v1-0-web-hosting` · commits a2573c5 (CORS), a8450a2 (hosting) · deployed, user check pending

## Log

- L1 (2026-10-30, user, verbatim): "Si por fa papurri añade el control y todo lo que involucre, para ver si me puedes
  ayudar tambien a hacer el aviso de privacidad tambien que de eso no tengo ni idea con eso de que es la primera web que
  publico no sé que debería incluir dicho aviso y ya una vez teniendo la URL en funcionamiento vemos si se puede
  habilitar el uso de camara desde la web obvio usando un celular :)"
- L2 (2026-10-30, parent): read-only exploration launched (gentle-ai-explore mvva5fqg-a-lw0i) for gate entry points and
  the personal-data inventory.
- L3 (2026-10-30, explore result): seam = connected MaterialApp `home` (`lib/main.dart:201-245`) wrapping
  `EmulatorLoginShell`; production app `lda-production` (`lib/firebase/production_bootstrap.dart:28-96`); emulator
  Firestore is connected only in `initializeCatalogRepository` (`lib/firebase/emulator_bootstrap.dart:346-392`); read
  pattern `CatalogReadSource` (`lib/catalog/firestore_catalog_repository.dart:15-39`); no anonymous rule exists today,
  unknown paths denied (`firestore.rules:276-279`); rules tests `firebase/tests/rules.test.mjs`. Privacy inventory: Auth
  email/password, claims role/branchId, `sellerProfiles` displayName, actor UIDs on sales/corrections/transfers/intake
  audits, notice readAt, free-text correction notes (only customer-data risk), no structured customer fields, local
  theme + PIN salt/hash + transfer journal (owner UID), camera QR not stored, no analytics/crash SDKs, region us-south1.
- L4 (2026-10-30, parent): V1 implemented inline (the worker could not bootstrap: "Writer bootstrap requires the original
  safe project root"). Test-first, RED observed for each part: pure logic (16 tests), gate widget (8), bootstrap wiring
  incl. blocked login and blocked restored session (4), rules (5; RED = the 2 read tests). Full suite 1957 passed + 1
  skipped (was 1929), `flutter analyze` clean, rules 27/27. Rules ran on an isolated emulator (firestore 8281, auth
  9699, storage 9399) because the user's own emulator holds 8080/9099/9299 and the suite clears Firestore. Emulator
  mode reads through the shared `_initializeLiveFirebase` registry, so Firestore is still connected once; the check
  waits for the session start first to avoid racing app initialization. New dependency `url_launcher` ^6.3.3.
  Slice boundary: 1101 authored lines in 4 commits (client commit 894 lines, about 500 of them tests); delivered as one
  PR because the rules, client and docs form one behavior. Risk: item 2 (anonymous read rule) and item 5 (new
  dependency).
- L5 (2026-10-30, independent verify mvvanoqm-b-hqu5): analyze clean, targeted tests 44/44, isolated rules 27/27,
  git status clean. Its only flag was the emulator's debug logs (firestore/firebase/storage-debug.log); they are
  gitignored, so no defect. url_launcher 6.3.3 points to the official flutter/packages repository (cached manifest).
  Native assess: medium, reviewDue false (under budget), so no native review.
- L6 (2026-10-30, manual check on the local emulator `demo-lda-inventory`, production untouched): with
  `appConfig/client` = minimumVersion 9.0.0 + androidUpdateUrl, a debug APK on the Huawei HBP-LX9 showed the block
  (screenshot: title, 1.0.0 → 9.0.0, «Abrir la tienda») and the web build in Brave showed «Recargar». User, verbatim:
  "Si papurri hace exactamente lo que mencionas en ambos casos". Cleanup: test document deleted (anonymous get 404),
  adb reverse removed, test web stopped, production APK (main a2842c7, sha256 74d2d171…) reinstalled and opened.
  User asked how «Recargar» reaches the newest build → D9.
- L7 (2026-10-30, parent): rules deployed to production after comparing (deployed == main a2842c7; ruleset
  d1df9e32 → f7c349c1 == repo; live anonymous get appConfig/client 404, products 403, list appConfig 403). Production
  web and APK rebuilt from main caaa0cb with the gate; the Huawei opens normally (no appConfig/client yet).
- L8 (2026-10-30, user, verbatim): "Dale papurri empecemos con la URL :)" → S5, V4, D10.
- L9 (2026-10-30, parent): CORS RED with main's index.js (3 fail) → GREEN; functions `npm test` 170/170 (was 169),
  runtime-identity 55/55. Pre-existing, not caused here: sales/corrections/sellerProfiles-callable tests fail on main
  too (not in `npm test`). Deployed from a8450a2: 16 callables (live preflight: web.app, firebaseapp.com, localhost
  allowed; …web.app.evil.com, http://…web.app, example.com rejected) and Hosting (both domains 200; `/`,
  `main.dart.js`, `flutter_bootstrap.js` and any path send `Cache-Control: no-cache`; the app boots to «Conectando con
  el servidor»). A conditional request with the ETag still returned 200 in curl, so the 304 saving is unobserved;
  correctness (always the published build) holds. Hosted build = production build of main caaa0cb (no lib/ change).
