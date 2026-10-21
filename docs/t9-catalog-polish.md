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

## T9D: panel transitions and scroll fade (S9, S10)

Same page, still presentation only: inventory, sales, cart logic, role
visibility, panel priority, navigation rules, keys and Spanish copy are
unchanged.

- **S9 – Panel cross-fade** (`lib/app/panel_transition.dart`, used by
  `_AuthenticatedCatalogPageState`): the body chain now yields each panel
  together with a stable identity — `catalog`, `corrections`, `movements`,
  `transfer`, `notices`, `receipt`, `cart`, `creation`, `pricing`, `intake` —
  and `PanelTransition` fades the panel being left underneath the one
  arriving: 220 ms, `easeOutCubic`, a 12 px vertical settle, no bounce.
  - Every layer has the same shape whether it is arriving or leaving, only
    properties change, so a panel keeps one element across the transition:
    rebuilding inside a panel never re-animates it and never throws away its
    state or scroll offset.
  - The fading panel is silenced from the first frame of the swap:
    `IgnorePointer` (a fast second tap cannot act on the panel already left),
    `ExcludeSemantics` (assistive technology reads one panel, not two) and
    `ExcludeFocus` (no stale focus in a panel on its way out).
  - `MediaQuery.disableAnimations` swaps instantly.
  - Bodies that are not panels — the first load, a failed load, an empty
    catalog — are presented outside the transition, so an initial load never
    animates and the transition always mounts on its first panel still.
  - Success banners, toolbars, the cart bar and Volver/Inicio stay outside the
    transition, and navigation stays blocked exactly while a request is in
    flight.
- **S10 – Scroll fade edges** (`lib/catalog/catalog_scroll_fade.dart`, used by
  `_CatalogListState`): static gradients over the product list toward the page
  background (`Theme.scaffoldBackgroundColor`, so the soft gray and not pure
  white) — a 48 px bottom edge while more products lie below, a slimmer 24 px
  top edge once scrolled down, and no edge at all over a list that fits.
  - Driven by scroll notifications (offset updates and dimension changes), so
    the edges track filtering and resizing without any motion of their own.
  - `IgnorePointer` plus decoration-only paint: card taps, the search field
    and the cart bar are untouched, and `StackFit.passthrough` gives the list
    the same constraints, scroll extent, keys and semantics as before.
  - Holds at the native two-column rule and at web breakpoints, and at 360 px
    with text scale 2 (pinned by tests).

### T9D tests

- `test/catalog/panel_transition_test.dart` — swap cross-fades and settles,
  the fading panel takes no taps, is out of the semantics tree and keeps no
  focus, in-panel rebuilds do not re-animate, panel state is never recreated,
  reduced motion and the first loaded body are instant, and the real page
  cross-fades into the cart and back through Volver.
- `test/catalog/catalog_scroll_fade_test.dart` — bottom edge while content
  lies below and none at the end or over a list that fits, top edge only after
  scrolling, edges fade to the page background instead of white, taps and long
  presses still reach cards under both edges, list layout and scroll travel
  unchanged, and the catalog page at 390 px native and at 360 px / text scale 2.

### Tests that look up a label shared by two panels

While the 220 ms cross-fade runs, both panels are in the tree, so a finder for a
label that both panels carry (for example `Cerrar`) matches twice. Tests that
tap such a label right after a panel change wait for the fade first; the
`chained creation-to-pricing` close loop in `test/catalog/catalog_page_test.dart`
uses a bounded `pump(300 ms)` because a catalog refresh is still pending there.

## T9E: softer Agregar (S11)

`Agregar` stays the card's primary action but uses `FilledButton.tonalIcon`
(the soft secondary container) instead of solid blue, so it does not clash with
the white card. Key, label, semantics and the add-one behavior are unchanged
(`test/sales/sale_add_tone_test.dart`).
