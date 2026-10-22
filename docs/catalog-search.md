# Catalog search (v1.0 UI, T6)

The inventory list has a typed search input above the products, for every
platform and for both roles. It is the store-facing way to find a product
without scrolling the whole catalog.

## What a query matches

A query is matched against the product **name** and the product **internal
code**. The internal code is also the QR payload
(`lib/catalog/product_qr.dart`, `ProductQr.payloadFor`), so a code read from a
printed label can be typed directly and behaves like any other query.

Matching rules (`lib/catalog/catalog_search.dart`):

| Rule | Example |
| --- | --- |
| Case-insensitive | `cafe` and `CAFE` both find `Café Grano Selecto` |
| Spanish accents folded | `cafe` finds `Café`, `te` finds `Té` |
| Surrounding and repeated whitespace collapsed | `"  CAFÉ  "` behaves as `cafe` |
| Substring, not prefix | `select` finds `Café Grano Selecto` |
| Every term must match the **same** product, in its name or its code | `agua 002` narrows to one product, `grano 002` finds nothing |
| Term order is irrelevant | `002 agua` behaves as `agua 002` |
| Empty or whitespace-only query | the full list, in its original order |

Only the characters a Spanish catalog uses are folded (`á à ä â ã`, `é è ë ê`,
`í ì ï î`, `ó ò ö ô õ`, `ú ù ü û`, `ñ`, `ç`). A query with no matching product
shows a "Sin resultados" panel with a clear action instead of an empty list.

## Focus mode (T9F / S12)

Focusing the field dims the whole screen, including the app bar and cart bar,
with a 200 ms
`easeOutCubic` scrim and lifts the original field above it. The entire scrim
has sigma-5 backdrop blur from the moment focus begins, even before typing.
The field scales to 104% around its center over 200 ms (`easeOutCubic`), without
changing layout or replacing the editable field; its clear cutout follows the
painted scale. A non-empty trimmed query opens a scrollable results card below
the field with rounded 24 px corners and theme colors. Its width and both edges
match the field's **resting** bounds exactly, including on desktop. Neither the
field nor the results are blurred. Its height is bounded
by the screen and the keyboard's visible area.

Results reuse the **full catalog cards** and the same `filterCatalogItems`
matcher: name, stock, price, tonal Agregar / quantity stepper, Detalles and
long-press details. No match keeps the existing Sin resultados and Limpiar
búsqueda action. Clearing or whitespace-only input closes results, not focus
mode. Desktop mouse actions belong to the field's tap region, so selling does
not accidentally dismiss results. If web blurs its hidden text input during a
results press, focus mode stays active until the gesture ends: the overlay,
blur, zoom and silenced chrome survive so Agregar/stepper taps can land.
Releasing restores field focus; cancellation does not. If the field cannot
regain focus, the normal dismissal path restores the surrounding chrome.

Tap the scrim, press Escape or use system back to unfocus **without clearing**
the query, even when tapping over the app bar or cart bar. Those taps never
activate the covered controls. The grid remains filtered afterward. Reduced motion
(`MediaQuery.disableAnimations`) makes the scrim show/hide instantly and
keeps the field at scale 1 (no zoom). The
underlying grid, app bar and cart bar are excluded from pointers, live semantics
and keyboard focus during focus mode; only the field and results can be used
or announced. The original
search field stays mounted in its original scroll view, never duplicated.

`test/catalog/catalog_search_focus_test.dart` covers focus/dismissal, results,
selling and details, live semantics, reduced motion, and Android/iOS layouts
at 360 px / text scale 2 with a keyboard inset. Widget platform overrides and
desktop mouse tests are not device or browser visual proof.

## Behaviour on reload

Reloading the catalog keeps the list already on screen while the new snapshot
is fetched, so the typed query and its filtered results survive the reload.
A failed load still shows the "Catálogo no disponible" retry panel, and the
first load still shows the loading panel.

## Test anchors

`test/catalog/catalog_search_test.dart` covers the matcher rules and the list
behaviour through the public widgets (`CatalogPage`, `AuthenticatedCatalogPage`)
using these keys, declared in `lib/catalog/catalog_search.dart`:

- `catalogSearchFieldKey` — `catalog-search`
- `catalogSearchClearKey` — `catalog-search-clear`

The pill-shaped search field has no visible or announced label. Its hint,
`Nombre o código`, provides its accessible name. The dense layout, search icon
and theme colors are unchanged. `test/catalog/catalog_search_shape_test.dart`
covers the rounded outline and hint semantics in light and dark themes.

## Scanning the product QR with the camera

On Android and iOS the search field offers a camera entry point
(`catalog-search-scan`). One scan is enough: the camera closes, the payload is
typed into the search field and the existing matcher filters the list, so a
scanned code and a typed code behave identically. Web and desktop show the
typed search only.

A product QR carries the internal code (`lib/catalog/product_qr.dart`,
`ProductQr.payloadFor`), which is exactly what the search matches. The scanner
decodes QR codes only (`BarcodeFormat.qrCode`), so a barcode printed on
packaging is reported as "El código leído no es un QR de producto" and the
camera stays open instead of silently filtering the list.

Permission and hardware problems are explained in Spanish and always leave a
way out:

| Situation | Message |
| --- | --- |
| Camera starting | `Encendiendo la cámara…` |
| Permission denied | `No se permitió el acceso a la cámara. Actívalo en Ajustes para poder escanear códigos QR.` |
| No camera on the device | `Este dispositivo no tiene una cámara disponible.` |
| Code read is not a QR | `El código leído no es un QR de producto.` (the camera stays open) |

Platform setup:

- **iOS**: `NSCameraUsageDescription` in `ios/Runner/Info.plist`.
- **Android**: the `mobile_scanner` plugin merges `CAMERA` and
  `<uses-feature android:name="android.hardware.camera" android:required="false"/>`;
  nothing to declare in the app manifest. The **bundled** ML Kit barcode model
  is used (no `dev.steenbakker.mobile_scanner.useUnbundled` flag), so scanning
  works offline and on devices without Google Play Services, at the cost of a
  larger APK.
- Cancelling, or a scan that yields nothing, leaves the search untouched.

## Out of scope

Advanced filters (price, stock, branch) are a future release. Scanning from a
photo in the gallery is not offered. Real camera behaviour on a device is
verified manually; the automated tests drive the sheet through a fake camera so
no test needs a lens.
