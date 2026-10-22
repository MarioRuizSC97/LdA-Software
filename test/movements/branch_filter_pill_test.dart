import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('branch filter coherent open surface in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = brightness == Brightness.light
          ? buildInventoryTheme()
          : buildDarkInventoryTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: MovementsView(
              movements: AdministratorMovements(
                load: (_) async => const [UnreadableMovement('sample')],
                readProfile: (_) async => throw UnimplementedError(),
                setSellerName: (_, _) async => throw UnimplementedError(),
              ),
              productNames: const {},
              branchChoices: const [
                CatalogBranchChoice(branchId: 'north', branchName: 'Norte'),
              ],
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byKey(
        const ValueKey<String>('movements-branch-filter'),
      );
      final decorator = find.ancestor(
        of: filter,
        matching: find.byType(InputDecorator),
      );
      // Read the animated border actually painted, not just decoration.border
      // (whose side Flutter can replace with its state-dependent defaults).
      dynamic paintedDecoration() => tester
          .widgetList<CustomPaint>(
            find.descendant(of: decorator, matching: find.byType(CustomPaint)),
          )
          .singleWhere(
            (paint) =>
                paint.foregroundPainter.runtimeType.toString() ==
                '_InputBorderPainter',
          )
          .foregroundPainter;
      OutlineInputBorder paintedBorder() {
        final dynamic painter = paintedDecoration();
        return painter.border.evaluate(painter.borderAnimation)
            as OutlineInputBorder;
      }

      final restingBorder = paintedBorder();
      final Color restingFill = paintedDecoration().blendedColor as Color;
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(find.text('Norte').last, findsOneWidget);
      final openBorder = paintedBorder();
      expect(openBorder.borderSide, restingBorder.borderSide);
      expect(openBorder.borderRadius, restingBorder.borderRadius);
      expect(
        openBorder.borderRadius,
        (theme.inputDecorationTheme.border! as OutlineInputBorder).borderRadius,
      );
      expect(paintedDecoration().blendedColor, restingFill);

      final ink = tester.widget<InkWell>(
        find.descendant(of: filter, matching: find.byType(InkWell)),
      );
      expect(
        ink.focusColor?.a,
        0,
        reason:
            'Opening the menu must not leave a rectangular focus tint '
            'inside the pill.',
      );
      final card = tester.widget<Card>(
        find.byKey(const ValueKey<String>('movement-sample')),
      );
      final cardSide =
          ((card.shape ?? theme.cardTheme.shape)! as OutlinedBorder).side;
      expect(openBorder.borderSide.color, cardSide.color);
      expect(openBorder.borderSide.width, cardSide.width);
      expect(restingFill, card.color ?? theme.cardTheme.color);
      final material = tester.widget<Material>(
        find.ancestor(of: decorator, matching: find.byType(Material)).first,
      );
      expect(material.elevation, card.elevation ?? theme.cardTheme.elevation);
      expect(material.surfaceTintColor?.a ?? 0, 0);
      await tester.tap(find.text('Norte').last);
      await tester.pumpAndSettle();
      expect(paintedBorder().borderSide, restingBorder.borderSide);
      expect(paintedDecoration().blendedColor, restingFill);
      expect(find.text('Filtro: Norte'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    for (final width in [400.0, 1200.0]) {
      testWidgets('branch filter pill in ${brightness.name} at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final loads = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? buildInventoryTheme()
                : buildDarkInventoryTheme(),
            home: Scaffold(
              body: MovementsView(
                movements: AdministratorMovements(
                  load: (branch) async {
                    loads.add(branch);
                    return [];
                  },
                  readProfile: (_) async => throw UnimplementedError(),
                  setSellerName: (_, _) async => throw UnimplementedError(),
                ),
                productNames: const {},
                branchChoices: const [
                  CatalogBranchChoice(
                    branchId: 'branch-north',
                    branchName: 'Norte',
                  ),
                ],
                onClose: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final filter = find.byKey(
          const ValueKey<String>('movements-branch-filter'),
        );
        final decorator = find.ancestor(
          of: filter,
          matching: find.byType(InputDecorator),
        );
        expect(
          decorator,
          findsOneWidget,
          reason: 'The rendered filter needs a themed input border, not a dropdown underline.',
        );
        final border = tester
            .widget<InputDecorator>(decorator)
            .decoration
            .border;
        expect(border, isA<OutlineInputBorder>());
        final radius = (border! as OutlineInputBorder).borderRadius;
        expect(radius.topLeft.x, greaterThanOrEqualTo(24));
        expect(radius, BorderRadius.circular(radius.topLeft.x));
        expect(
          find.ancestor(
            of: filter,
            matching: find.byType(DropdownButtonHideUnderline),
          ),
          findsOneWidget,
        );
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Norte').last);
        await tester.pumpAndSettle();
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Todas').last);
        await tester.pumpAndSettle();
        expect(loads, [null, 'branch-north', null]);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
