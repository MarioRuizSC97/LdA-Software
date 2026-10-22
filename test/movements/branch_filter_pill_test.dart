import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/movements_view.dart';

void main() {
  for (final brightness in Brightness.values) {
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
