import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart';

const EmulatorSession _administrator = EmulatorSession(
  userId: 'admin-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);

const String _creationIntro =
    'El servidor asigna el código interno permanente y la identidad QR.';

CatalogSnapshot _adminSnapshot() => CatalogSnapshot(
  <CatalogItem>[
    CatalogItem(
      product: const CatalogProduct(
        internalCode: 'PRD-COFFEE-001',
        name: 'Café',
        quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
      ),
      holdings: const <CatalogHolding>[
        CatalogHolding(
          branchId: 'branch-north',
          branchName: 'Norte',
          quantityScaled: 5000,
        ),
      ],
    ),
  ],
  branchChoices: const <CatalogBranchChoice>[
    CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
    CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
  ],
);

Widget _adminPage({required ProductCreationSubmit createProduct}) =>
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: _administrator,
        catalogLoader: (_) async => _adminSnapshot(),
        onLogout: () async {},
        createProduct: createProduct,
        createDraftId: () => 'draft-1',
        submitTransfer: (TransferDraft draft) =>
            Completer<TransferResult>().future,
        unresolvedTransferDraft: () => null,
      ),
    );

final SaleCorrections _corrections = SaleCorrections(
  branchId: saleBranchId,
  find: (SaleLookupQuery query) async => lookupSale(),
  listRecent: () async => RecentCorrectableSales.fromCallable(<String, Object?>{
    'sales': <Object?>[lookupSaleJson()],
  }, query: RecentSalesQuery()),
  previewReturn: (_) async => throw UnimplementedError(),
  submitReturn: (_) async => throw UnimplementedError(),
  previewExchange: (_) async => throw UnimplementedError(),
  submitReplacement: (_) async => throw UnimplementedError(),
  submitExchange: (_) async => throw UnimplementedError(),
  unresolvedDraft: () => null,
  unacknowledged: () => null,
  acknowledge: (_) {},
);

Widget _sellerPage() => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => sellerSaleSnapshot(branchId: saleBranchId),
    onLogout: () async {},
    saleCheckout: FakeSaleCheckout().checkout,
    saleCorrections: _corrections,
  ),
);

Finder get _home => find.byKey(const ValueKey<String>('shell-home'));
Finder get _back => find.byKey(const ValueKey<String>('panel-back'));

bool _enabled(WidgetTester tester, Finder button) =>
    tester.widget<IconButton>(button).onPressed != null;

Future<ProductCreationResult> _neverCreates(ProductCreationDraft draft) =>
    Completer<ProductCreationResult>().future;

void main() {
  testWidgets('at home Inicio is hidden and Volver is hidden', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_adminPage(createProduct: _neverCreates));
    await tester.pumpAndSettle();

    expect(_home, findsNothing);
    expect(_back, findsNothing);
    // 'Inicio' is hidden at the main panel on every platform (S9, T10); it
    // appears next to Volver only while a panel is open.
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Volver closes the top panel and reveals the one below it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_adminPage(createProduct: _neverCreates));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
    await tester.pumpAndSettle();
    expect(find.byType(AdministratorTransferForm), findsOneWidget);

    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(find.byType(AdministratorTransferForm), findsNothing);
    expect(find.text(_creationIntro), findsOneWidget);

    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(find.text(_creationIntro), findsNothing);
    expect(_back, findsNothing);
    expect(_home, findsNothing);
    // 'Inicio' disappears with the last panel on every platform (S9, T10).
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Inicio closes every open panel at once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_adminPage(createProduct: _neverCreates));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
    await tester.pumpAndSettle();

    await tester.tap(_home);
    await tester.pumpAndSettle();
    expect(find.byType(AdministratorTransferForm), findsNothing);
    expect(find.text(_creationIntro), findsNothing);
    expect(find.text('Café'), findsOneWidget);
  });

  testWidgets('a request in flight disables Inicio and Volver', (
    WidgetTester tester,
  ) async {
    final List<ProductCreationDraft> sent = <ProductCreationDraft>[];
    await tester.pumpWidget(
      _adminPage(
        createProduct: (ProductCreationDraft draft) {
          sent.add(draft);
          return Completer<ProductCreationResult>().future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Cinta',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    final Finder precision = find.byKey(
      const ValueKey<String>('create-product-precision'),
    );
    await tester.ensureVisible(precision);
    await tester.pumpAndSettle();
    await tester.tap(precision);
    await tester.pumpAndSettle();
    await tester.tap(find.text('0').last);
    await tester.pumpAndSettle();
    final Finder create = find.widgetWithText(FilledButton, 'Crear');
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pump();

    expect(sent, hasLength(1));
    expect(_enabled(tester, _home), isFalse);
    expect(_enabled(tester, _back), isFalse);
    await tester.tap(_back, warnIfMissed: false);
    await tester.pump();
    expect(find.text(_creationIntro), findsOneWidget);
  });

  testWidgets('a seller returns home from Correcciones', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerPage());
    await tester.pumpAndSettle();
    expect(_home, findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('corrections-open')));
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionLookupView), findsOneWidget);
    expect(_enabled(tester, _home), isTrue);

    await tester.tap(_home);
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionLookupView), findsNothing);
    expect(_back, findsNothing);
    expect(_home, findsNothing);
    // 'Inicio' is hidden at the main panel on every platform (S9, T10).
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
