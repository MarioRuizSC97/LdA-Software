# T9 catalog visual polish (cards unit)

Worker unit for `odd/tasks/v1-0-ui-t9.md` T9A covering S2–S6. Scope is
presentation only: inventory, sales, role visibility, navigation, cart
controller logic, validations and every user-visible string are unchanged.
The parallel details worker owns `_ProductSheet`/`_openDetails` (S1); this
unit never touches them.

## What changed

- **S2 – Price prominence** (`_ProductCard`): the price line is now the
  card's strongest text (`titleLarge`, bold); stock lines render as
  secondary information (small, muted `onSurfaceVariant`) through a
  `DefaultTextStyle.merge`, so the shared `_holdingLines` helper stays
  untouched. Exact amounts and copy are unchanged.
- **S3 – Action hierarchy** (`_ProductCard`, `SaleAddControl`):
  "Agregar" (and "Agotado") is now the primary `FilledButton.icon`;
  "Detalles" became a discreet `TextButton.icon`. Keys, icons, labels,
  semantics labels, ordering of handlers and the long-press sheet path are
  unchanged; "Agregar" moved before "Detalles" so the primary action reads
  first.
- **S4 – Theme contrast** (`lib/app/inventory_theme.dart`, `main.dart`):
  one shared `buildInventoryTheme()` — neutral very light gray scaffold
  (`#F6F7F9`), white card surfaces with elevation 0 and a subtle hairline
  border, blue `ColorScheme.fromSeed` kept for primary actions. All three
  `MaterialApp` entries in `main.dart` use it.
- **S5 – Complete final rows** (`_CatalogListState`): incomplete final rows
  render inert `Expanded(SizedBox.shrink())` slots, so the last card keeps
  the same width as every other card. Column rules (native 2 columns, web
  breakpoints) are unchanged.
- **S6 – Brief, useful motion** (`sale_cart_panel.dart`): a private
  `_ControlSwap` (AnimatedSwitcher-based) cross-fades the "Agregar" ↔
  stepper swap and the stepper quantity number update in 150 ms; the cart
  panel eases in with a short fade + 12 px settle. Guarantees:
  - No animation on first appearance (initial load) — AnimatedSwitcher is
    mounted without animating its first child, and quantity-entry opening
    never animates (it receives focus immediately).
  - `MediaQuery.disableAnimationsOf` (reduced motion) makes every
    transition instant.
  - Outgoing controls stop receiving pointers while fading
    (`IgnorePointer` on the reverse-direction transition), so a fast
    second tap can never re-trigger "Agregar" or duplicate a cart action.
- **S7 – Platform intent**: the same Flutter presentation runs on Android
  and iOS; widget tests validate the layouts with Android/iOS platform
  overrides (2-column rule intact) and at 360 px / text scale 2 via the
  existing responsive suites. No simulator run was performed in this unit
  (see risks).

## Untouched contracts

`SaleCartController`, `saveEntry`, quote/stock validation, idempotency
keys, `SaleQuantityEntry`, `SaleLineStepper` behavior, cart panel
business state, `_ProductSheet`, `_openDetails`, dialog transitions, and
all Spanish labels/semantics.

## Tests

- `test/app/inventory_theme_test.dart` — theme rules (S4).
- `test/catalog/catalog_visual_polish_test.dart` — price/stock hierarchy,
  action hierarchy, equal final-row widths, theme wiring guard (S2/S3/S5).
- `test/sales/sale_visual_motion_test.dart` — swap cross-fades, quantity
  number fade, panel entrance, no initial-load animation, reduced motion,
  rapid-double-tap safety, add-one/stock-disabled/unknown-branch pins
  (S6 + prior behavior).
