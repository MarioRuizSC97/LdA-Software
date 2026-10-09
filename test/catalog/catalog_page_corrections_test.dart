import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'seller-2',
  email: 'other@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

final SaleCorrections _corrections = SaleCorrections(
  branchId: saleBranchId,
  find: (SaleLookupQuery query) async => lookupSale(),
  listRecent: () async => RecentCorrectableSales.fromCallable(<String, Object?>{
    'sales': <Object?>[lookupSaleJson()],
  }, query: RecentSalesQuery()),
  previewReturn: (_) async => throw UnimplementedError(),
  submitReturn: (_) async => throw UnimplementedError(),
  unresolvedDraft: () => null,
);

Widget _page(
  EmulatorSession session, {
  SaleCorrections? corrections,
  bool withCheckout = true,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: (EmulatorSession session) async =>
        session.role == InventoryRole.seller
        ? sellerSaleSnapshot(branchId: saleBranchId)
        : CatalogSnapshot(const <CatalogItem>[]),
    onLogout: () async {},
    saleCheckout: withCheckout ? FakeSaleCheckout().checkout : null,
    saleCorrections: corrections,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

void main() {
  testWidgets('administrators never get the entry, even if handed one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _page(_administrator, corrections: _corrections, withCheckout: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Correcciones'), findsNothing);
  });

  testWidgets('sellers open corrections in place of the catalog and cart', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(_seller, corrections: _corrections));
    await tester.pumpAndSettle();
    expect(_key('sale-cart-button'), findsOneWidget);

    await tester.tap(_key('corrections-open'));
    await tester.pumpAndSettle();
    expect(_key('correction-folio'), findsOneWidget);
    expect(_key('sale-cart-button'), findsNothing);
    expect(
      tester.widget<TextButton>(_key('corrections-open')).onPressed,
      isNull,
    );

    await tester.tap(_key('corrections-close'));
    await tester.pumpAndSettle();
    expect(_key('correction-folio'), findsNothing);
    expect(_key('sale-cart-button'), findsOneWidget);
  });

  testWidgets('a session change or a withdrawn entry closes corrections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(_seller, corrections: _corrections));
    await tester.pumpAndSettle();
    await tester.tap(_key('corrections-open'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_page(_otherSeller, corrections: _corrections));
    await tester.pumpAndSettle();
    expect(_key('correction-folio'), findsNothing);

    await tester.tap(_key('corrections-open'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_page(_otherSeller));
    await tester.pumpAndSettle();
    expect(_key('correction-folio'), findsNothing);
    expect(find.text('Correcciones'), findsNothing);
  });
}
