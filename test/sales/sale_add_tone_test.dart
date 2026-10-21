// T9/S11: the card's 'Agregar' stays the primary action but uses the soft
// tonal fill instead of solid blue, so it no longer clashes with the white
// product card. Its key, label and add-one behavior are unchanged.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';

import 'sale_ui_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Finder _add() =>
    find.byKey(ValueKey<String>('sale-add-${pinProduct.internalCode}'));

Future<void> _pump(WidgetTester tester, FakeSaleCheckout sales) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildInventoryTheme(),
      home: AuthenticatedCatalogPage(
        session: _seller,
        catalogLoader: (_) async => sellerSaleSnapshot(),
        onLogout: () async {},
        saleCheckout: sales.checkout,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? _fill(WidgetTester tester) => tester
    .widget<Material>(
      find.descendant(of: _add(), matching: find.byType(Material)).first,
    )
    .color;

void main() {
  testWidgets('Agregar uses the soft tonal fill, not solid primary', (
    WidgetTester tester,
  ) async {
    await _pump(tester, FakeSaleCheckout());
    final ColorScheme colors = buildInventoryTheme().colorScheme;

    expect(_add(), findsOneWidget);
    expect(_fill(tester), colors.secondaryContainer);
    expect(_fill(tester), isNot(colors.primary));
    expect(
      find.descendant(of: _add(), matching: find.text('Agregar')),
      findsOneWidget,
    );
  });

  testWidgets('Agregar still adds one unit and shows the stepper', (
    WidgetTester tester,
  ) async {
    await _pump(tester, FakeSaleCheckout());
    await tester.tap(_add());
    await tester.pumpAndSettle();

    expect(_add(), findsNothing);
    expect(
      find.byKey(ValueKey<String>('sale-line-edit-${pinProduct.internalCode}')),
      findsOneWidget,
    );
  });
}
