# T9B — Detalles del producto compactos (S1, S6–S8)

Unit: details worktree (`feat/v1-0-ui-t9-details`), parallel to the cards unit.
Scope: presentation only, per `odd/tasks/v1-0-ui-t9.md` L2.

## What changed

### Content-sized detail peek (S1)

The sheet previously wrapped its content in `SafeArea > Center`, so the
`Flexible` inside the peek card expanded to the capped height and short seller
details left a large blank area (observed baseline L3 at 1184x1182 and
390x844). The sheet now lays out without the expanding `Center`:

- Short seller detail hugs its content (measured < 709 px at 1184x1182,
  < 633 px at 390x844; previously filled the ~0.88×viewport cap).
- Tall administrator detail or large text still caps at the peek height and
  scrolls; `SingleChildScrollView` remains the scroll surface and swipe-down
  from the top still dismisses.
- `showProductPeek` keeps its API, 560 width cap, 260 ms easeOut fade/zoom,
  reduced-motion behavior, backdrop blur/tap, close button, back/Escape and
  swipe dismissal (all existing `product_peek_test.dart` cases pass unchanged).

### Keyboard avoidance moved up a level (S1 sizing)

`showProductPeek` now adds `MediaQuery.viewInsetsOf(context).bottom` to its
bottom padding and caps `maxHeight` at the remaining space, so the centered
card rises above the keyboard instead of the sheet growing (the old
sheet-level inset padding pushed the content off the top edge when the card
was tall). The sheet no longer handles viewInsets itself.

### Name/price hierarchy and separate QR surface (S1)

Inside `_ProductSheet` only:

- `Detalles del producto` becomes a quieter section label
  (`titleMedium` on `onSurfaceVariant`); the product name is now the semantic
  header with `headlineSmall` w600.
- `Precio de lista: …` is the strongest price treatment: `titleLarge`,
  `colorScheme.primary`, w700. Attribute lines (modo de precio, IVA, unidad,
  costo) use `bodyMedium` on `onSurfaceVariant`.
- The QR sits on its own rounded surface
  (`product-sheet-qr-<code>`, `colorScheme.surfaceContainerHighest`) instead
  of floating at the end of the column.

All visible strings, widget keys, role gating (`fullDetails` logic,
`_holdingLines`), and the admin pop-then-open pricing/intake callbacks are
unchanged. Colors come exclusively from `Theme.of(context)` so the shared
theme unit's neutral gray/white/blue scheme applies without local overrides.

### Animations (S6)

Panel opening already animates via the preserved 260 ms fade/zoom with
reduced-motion opt-out; no additional panel transition was added. The
Agregar-selector and quantity transitions named in S6 belong to the cards
unit (T9A).

### Platform intent (S7, S8)

Shared Flutter presentation, no platform branch and no new dependency. Layout
verified by widget tests at 1184x1182, 390x844 and 360 px @ text scale 2 for
both roles; native simulator proof is left to parent integration (T9C), which
also owns commits and the feature tracker.

## Tests

`test/catalog/product_detail_polish_test.dart` (new):

1. Seller peek content-sized on 1184x1182 (< 0.6 × height).
2. Seller peek content-sized on 390x844 (< 0.75 × height).
3. Name/price/attribute hierarchy (font sizes, price in primary color,
   scoped to the peek).
4. QR on its own keyed surface.
5. Admin detail capped and scrollable at 1184x1182 with text scale 2.
6. Keyboard inset (240 px) keeps the peek fully on screen and above the
   keyboard.

RED was observed before implementation: seller heights measured 1040.16 px
(1184x1182) and 742.72 px (390x844), no `product-sheet-qr-…` key, no style
hierarchy, and the keyboard case pushed the card bottom to 793.36 px vs the
604 px keyboard line. All existing detail-role/dismissal cases
(`test/catalog/product_peek_test.dart`) pass identically against base
`4ec5f5f` and this unit with the same inputs.
