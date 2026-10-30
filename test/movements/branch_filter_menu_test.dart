import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/movements_view.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [400.0, 601.0, 1200.0]) {
      testWidgets('legible branch menu ${brightness.name} at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = brightness == Brightness.light
            ? buildInventoryTheme()
            : buildDarkInventoryTheme();
        final loads = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
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
                  CatalogBranchChoice(branchId: 'north', branchName: 'Norte'),
                  CatalogBranchChoice(
                    branchId: 'south',
                    branchName: 'Sucursal del Sur',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final filter = find.byKey(const ValueKey('movements-branch-filter'));
        final field = find.ancestor(
          of: filter,
          matching: find.byType(InputDecorator),
        );
        final fieldRect = tester.getRect(field);
        await tester.tap(filter);
        await tester.pumpAndSettle();

        Future<void> checkMenu(String selected) async {
          final rows = find.byElementPredicate(
            (element) =>
                (element.widget is PopupMenuItem ||
                    element.widget is DropdownMenuItem<String?>) &&
                element
                        .findAncestorWidgetOfExactType<
                          DropdownButton<String?>
                        >() ==
                    null,
          );
          expect(rows, findsNWidgets(3));
          for (final row in rows.evaluate()) {
            final finder = find.byElementPredicate(
              (element) => identical(element, row),
            );
            final rect = tester.getRect(finder);
            expect(rect.width, greaterThanOrEqualTo(fieldRect.width));
            expect(rect.height, greaterThanOrEqualTo(44));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(rect.top, greaterThanOrEqualTo(fieldRect.bottom));
            expect(rect.bottom, lessThanOrEqualTo(900));
          }
          final marker = find.byIcon(Icons.check);
          expect(marker, findsOneWidget);
          final selectedRow = find.ancestor(of: marker, matching: rows);
          expect(
            find.descendant(of: selectedRow, matching: find.text(selected)),
            findsOneWidget,
          );
          for (final label in ['Todas', 'Norte', 'Sucursal del Sur']) {
            final text = find.descendant(of: rows, matching: find.text(label));
            expect(text, findsOneWidget);
            final context = tester.element(text);
            expect(
              DefaultTextStyle.of(context).style.color,
              theme.colorScheme.onSurface,
            );
          }
          final material = tester.widget<Material>(
            find
                .ancestor(of: rows.first, matching: find.byType(Material))
                .first,
          );
          expect(material.color, theme.colorScheme.surfaceContainer);
          expect(tester.takeException(), isNull);
        }

        await checkMenu('Todas');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.text('Norte').last));
        await tester.pumpAndSettle();
        await checkMenu('Todas');
        final press = await tester.startGesture(
          tester.getCenter(find.text('Norte').last),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await checkMenu('Todas');
        await press.up();
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(loads, [null, 'north']);
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await checkMenu('Norte');
        await tester.tap(find.text('Todas').last);
        await tester.pumpAndSettle();
        expect(loads, [null, 'north', null]);
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(8, 880));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.check), findsNothing);
        expect(loads, [
          null,
          'north',
          null,
        ], reason: 'Dismissing must not re-filter.');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
