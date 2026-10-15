# Responsive UI and accessibility (INV-06 remainder)
Objective: close the "responsive UI/accessibility" part of INV-06 (odd/tasks/inventory-mvp.md:27) without visual redesign (colors, transitions, styling are out of scope until the user asks).
Branch: feat/inventory-mvp-seller-profiles-v2. Delivery: ask-on-risk; work-unit commits authorized, push/PR are the user's decision. Tests: `flutter test` (widget tests, Ahem font; overflow pixel counts are relative only).

## Specs
- S1. "empieza con lo que me mencionas del UI" — responsive UI: every user-facing screen renders without layout overflow at 320px width and at text scale 2.0, and forms/lists do not stretch unbounded at 1200px+.
- S2. Accessibility: interactive controls meet Flutter's `androidTapTargetGuideline` and `labeledTapTargetGuideline`; controls whose meaning depends on non-text state (badge count, dropdown purpose) expose it to screen readers.
- S3. "si veo la necesidad de hacer cambios en el aspecto, en transiciones o colorimetría y demás te lo notifico" — no unrequested visual redesign; structural changes only where S1/S2 require them.
- S4. Existing behavior (keys, labels, flows, tests) is preserved unless a spec requires changing it; any changed text is called out.
- Assumption (open product decision, not in scope until the user decides): unifying the mixed English/Spanish UI copy.

## Tasks
- [x] RA-01 | S1,S4 | inline | Shell AppBar: collapse secondary actions into an overflow menu below a width breakpoint; assert zero overflow for admin and seller at 320px and text scale 2.0. RED 4/5 (overflow 158/96px at 320, 376/300px at 2.0x) -> GREEN 6/6; suite 948/948. Commit: see L3.
- [ ] RA-02 | S1,S2,S4 | inline | Movements view: width cap, labeled branch filter, merged row semantics; 320px / 2.0x / 1200px tests.
- [ ] RA-03 | S1,S4 | inline | Corrections sweep (lookup, return, exchange, receipts) at 320px / 2.0x / 1200px.
- [ ] RA-04 | S2,S4 | inline | Guideline smoke tests (tap target, labeled tap target) over key screens; fix failures (e.g. notices badge count in semantics).

## Log
- L1 (2026-10-15, user): "Dale papurri empieza con lo que me mencionas del UI creo recordar que habia añadido algunas Skills de Flutter que probablemente te pueden servir para trabajar con el UI responsive y accesibilidad pero igual checalo por cualquier cosa, y ya posterior a eso si veo la necesidad de hacer cambios en el aspecto, en transiciones o colorimetría y demás te lo notifico papurri :)"
- L2. Skills used: .agents/skills/flutter-build-responsive-layout/SKILL.md, ~/.pi/agent/skills/flutter-development/SKILL.md. Read-only audit found: no navigation breakpoint (all sections in AppBar.actions, catalog_page.dart:801-846; admin overflows at 320px and transfer tests only compare against a baseline, catalog_page_transfer_test.dart:677-768); movements view has no width cap and an unlabeled branch DropdownButton (movements_view.dart:160-270); no meetsGuideline usage in test/; text scale tested only at 1.3. Every IconButton has a tooltip; QR images have semantic labels.
- L3. RA-01 done. Shell AppBar: below 600 logical px scaled by the text scale factor (`_compactShellWidth`, lib/catalog/catalog_page.dart), Correcciones, Movimientos and Log out move into a `PopupMenuButton` (key `shell-more`, items keep keys `corrections-open`/`movements-open`); notices and refresh icons stay inline. New test/catalog/catalog_page_responsive_test.dart (seller and admin at 320px x 1.0/2.0, 700px at 2.0, 1000px inline). Transfer narrow tests now also require an empty overflow baseline; the 320px test reaches Log out through the menu (behavior change: Log out is no longer visible directly in the narrow bar). Pre-existing format drift in test/transfers/transfer_notice_controller_test.dart left untouched.
