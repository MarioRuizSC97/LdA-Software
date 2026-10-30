// T9/S2-S5 catalog polish: price prominence over secondary stock, 'Agregar'
// as the primary action with a discreet 'Detalles', and complete final rows
// that keep every card at the same width.
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;

import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart' show RenderParagraph;

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import '../sales/sale_ui_fixtures.dart' show FakeSaleCheckout;

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

const List<CatalogBranchChoice> _branches = <CatalogBranchChoice>[
  CatalogBranchChoice(
    branchId: 'branch-north',
    branchName: 'North Demo Branch',
  ),
];

const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Café de grano',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

const CatalogProduct _tea = CatalogProduct(
  internalCode: 'PRD-TEA-002',
  name: 'Té verde',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);

const CatalogProduct _water = CatalogProduct(
  internalCode: 'PRD-WATER-003',
  name: 'Agua embotellada',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);

CatalogSnapshot _snapshot(
  List<CatalogProduct> products, {
  bool withBranches = false,
}) => CatalogSnapshot(<CatalogItem>[
  for (final CatalogProduct product in products)
    CatalogItem(
      product: product,
      holdings: <CatalogHolding>[
        if (withBranches)
          const CatalogHolding(
            branchId: 'branch-north',
            branchName: 'North Demo Branch',
            quantityScaled: 100,
          )
        else
          const CatalogHolding(branchId: 'branch-north', quantityScaled: 100),
      ],
    ),
], branchChoices: withBranches ? _branches : const <CatalogBranchChoice>[]);

Widget _sellerApp(List<CatalogProduct> products) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => _snapshot(products),
    onLogout: () async {},
    saleCheckout: FakeSaleCheckout().checkout,
  ),
);

Widget _administratorApp(List<CatalogProduct> products) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _administrator,
    catalogLoader: (_) async => _snapshot(products, withBranches: true),
    onLogout: () async {},
  ),
);

Finder _card(String code) => find.byKey(ValueKey<String>('product-card-$code'));

/// Resolves the effective text style actually painted for the first matching
/// text, including DefaultTextStyle inheritance.
TextStyle _paintedStyle(WidgetTester tester, String data) =>
    tester.renderObject<RenderParagraph>(find.text(data)).text.style!;

void _usePlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

void main() {
  testWidgets('the card price reads stronger than the secondary stock line', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp(<CatalogProduct>[_coffee]));
    await tester.pumpAndSettle();

    final TextStyle price = _paintedStyle(tester, 'Precio: 129.00 MXN');
    final TextStyle stock = _paintedStyle(tester, 'Existencias: 1.00 kg');

    // S2: the price is prominent (large and bold); the stock is secondary
    // (small, lighter ink) without changing the exact amounts or copy.
    expect(price.fontSize, isNotNull);
    expect(price.fontSize!, greaterThanOrEqualTo(20));
    expect(price.fontWeight, isNotNull);
    expect(
      price.fontWeight!.value,
      greaterThanOrEqualTo(FontWeight.w600.value),
    );
    expect(stock.fontSize, isNotNull);
    expect(stock.fontSize!, lessThanOrEqualTo(13));
    expect(
      price.fontSize!,
      greaterThan(stock.fontSize!),
      reason: 'the price clearly outranks the stock line',
    );
    expect(stock.fontWeight?.value ?? 0, lessThan(price.fontWeight!.value));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agregar is the primary action and Detalles stays discreet', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_sellerApp(<CatalogProduct>[_coffee]));
    await tester.pumpAndSettle();

    // S3: 'Agregar' is the primary FilledButton; 'Detalles' is a quiet
    // text action. Keys, labels and semantics are unchanged.
    final FilledButton add = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Agregar'),
    );
    expect(add.key, const ValueKey<String>('sale-add-PRD-COFFEE-001'));
    expect(find.widgetWithText(TextButton, 'Detalles'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Detalles'), findsNothing);
    expect(
      find.bySemanticsLabel('Ver detalles de Café de grano'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Agregar Café de grano al carrito'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('an incomplete final row keeps every card the same width', (
    WidgetTester tester,
  ) async {
    _usePlatform(TargetPlatform.android);
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _sellerApp(<CatalogProduct>[_coffee, _tea, _water]),
    );
    await tester.pumpAndSettle();

    // S5: with two columns and three products, the solitary last card must
    // not stretch across the row.
    final Size coffee = tester.getSize(_card(_coffee.internalCode));
    final Size water = tester.getSize(_card(_water.internalCode));
    expect(water.width, closeTo(coffee.width, 0.5));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the administrator card keeps the same price hierarchy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_administratorApp(<CatalogProduct>[_coffee]));
    await tester.pumpAndSettle();

    final TextStyle price = _paintedStyle(tester, 'Precio: 129.00 MXN');
    final TextStyle stock = _paintedStyle(tester, 'North Demo Branch: 1.00 kg');
    expect(price.fontSize!, greaterThan(stock.fontSize!));
    expect(stock.fontWeight?.value ?? 0, lessThan(price.fontWeight!.value));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the catalog never overrides the shared theme surfaces', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp(<CatalogProduct>[_coffee]));
    await tester.pumpAndSettle();

    // S4 wiring: the page Scaffold inherits the shared theme's background
    // and card theme instead of hardcoding its own colors.
    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, isNull);
    expect(find.byType(SaleAddControl), findsOneWidget);
  });
}
