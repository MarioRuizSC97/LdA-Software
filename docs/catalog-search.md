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
- `catalogSearchLabel` — `Buscar por nombre o código`, the visible label and the
  announced semantics label.

## Out of scope

Camera QR scanning for the same search is tracked as T7 of
`odd/tasks/v1-0-ui.md` (new dependency plus camera permissions). Advanced
filters (price, stock, branch) are a future release.
