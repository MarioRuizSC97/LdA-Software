import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

import '../support/viewport.dart';
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
  CatalogBranchChoice(
    branchId: 'branch-south',
    branchName: 'South Demo Branch',
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

CatalogHolding _sellerHolding(CatalogProduct product) =>
    CatalogHolding(branchId: 'branch-north', quantityScaled: 100);

CatalogSnapshot _sellerSnapshot(List<CatalogProduct> products) =>
    CatalogSnapshot(<CatalogItem>[
      for (final CatalogProduct product in products)
        CatalogItem(
          product: product,
          holdings: <CatalogHolding>[_sellerHolding(product)],
        ),
    ]);

CatalogSnapshot _administratorSnapshot(List<CatalogProduct> products) =>
    CatalogSnapshot(
      <CatalogItem>[
        for (final CatalogProduct product in products)
          CatalogItem(
            product: product,
            holdings: const <CatalogHolding>[
              CatalogHolding(
                branchId: 'branch-north',
                branchName: 'North Demo Branch',
                quantityScaled: 100,
              ),
            ],
          ),
      ],
      branchChoices: _branches,
      costsAvailable: true,
      costs: <String, CatalogProductCost>{
        'PRD-COFFEE-001': CatalogProductCost.fromFirestore(
          'costs/PRD-COFFEE-001',
          <String, Object?>{
            'latestUnitCostCentavos': 345,
            'currency': 'MXN',
            'sourceEntryId': 'entry-1',
            'updatedAt': Timestamp(0, 0),
          },
        ),
      },
    );

Widget _app(EmulatorSession session, CatalogSnapshot snapshot) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: (_) async => snapshot,
    onLogout: () async {},
    saleCheckout: session.role == InventoryRole.seller
        ? FakeSaleCheckout().checkout
        : null,
    // The administrator's sheet actions need the seams to be wired; the
    // submit callbacks themselves are never called in these tests.
    setProductPrice: session.role == InventoryRole.administrator
        ? (_) => throw UnimplementedError()
        : null,
    submitStockIntake: session.role == InventoryRole.administrator
        ? (_) => throw UnimplementedError()
        : null,
  ),
);

Finder _card(String code) => find.byKey(ValueKey<String>('product-card-$code'));

Finder _details(String code) =>
    find.byKey(ValueKey<String>('product-details-$code'));

Finder _sheet(String code) =>
    find.byKey(ValueKey<String>('product-sheet-$code'));

Future<void> _openSheet(WidgetTester tester, String code) async {
  final Finder details = _details(code);
  await tester.ensureVisible(details);
  await tester.pumpAndSettle();
  await tester.tap(details, warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(_sheet(code), findsOneWidget);
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('product-sheet-close')));
  await tester.pumpAndSettle();
}

/// Overrides the target platform for the current test and resets it later.
void _usePlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

void main() {
  testWidgets('android and iOS show two products per row', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      _usePlatform(platform);
      await tester.pumpWidget(
        _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee, _tea, _water])),
      );
      await tester.pumpAndSettle();

      final Offset coffee = tester.getTopLeft(_card(_coffee.internalCode));
      final Offset tea = tester.getTopLeft(_card(_tea.internalCode));
      final Offset water = tester.getTopLeft(_card(_water.internalCode));
      expect(coffee.dy, tea.dy, reason: '$platform: first row holds 2 cards');
      expect(coffee.dx, lessThan(tea.dx));
      expect(
        water.dy,
        greaterThan(coffee.dy),
        reason: '$platform: third card wraps to the next row',
      );
      expect(tester.takeException(), isNull);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide web/desktop shows three products per row', (
    WidgetTester tester,
  ) async {
    _usePlatform(TargetPlatform.macOS);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee, _tea, _water])),
    );
    await tester.pumpAndSettle();

    final Offset coffee = tester.getTopLeft(_card(_coffee.internalCode));
    final Offset tea = tester.getTopLeft(_card(_tea.internalCode));
    final Offset water = tester.getTopLeft(_card(_water.internalCode));
    expect(coffee.dy, tea.dy);
    expect(tea.dy, water.dy);
    expect(coffee.dx, lessThan(tea.dx));
    expect(tea.dx, lessThan(water.dx));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow web/desktop falls back to fewer columns', (
    WidgetTester tester,
  ) async {
    _usePlatform(TargetPlatform.macOS);
    for (final (Size size, int columns) in <(Size, int)>[
      (const Size(700, 900), 2),
      (const Size(480, 900), 1),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee, _tea, _water])),
      );
      await tester.pumpAndSettle();

      final Offset coffee = tester.getTopLeft(_card(_coffee.internalCode));
      final Offset tea = tester.getTopLeft(_card(_tea.internalCode));
      final Offset water = tester.getTopLeft(_card(_water.internalCode));
      if (columns == 2) {
        expect(coffee.dy, tea.dy, reason: '700px: first row holds 2 cards');
        expect(water.dy, greaterThan(coffee.dy));
      } else {
        expect(coffee.dy, isNot(tea.dy), reason: '480px: one card per row');
        expect(tea.dy, isNot(water.dy));
      }
      expect(tester.takeException(), isNull);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('compact seller card shows name, stock and price only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Café de grano'), findsOneWidget);
    expect(find.text('Existencias: 1.00 kg'), findsOneWidget);
    expect(find.text('Precio: 129.00 MXN'), findsOneWidget);
    expect(find.text('Agregar'), findsOneWidget);
    // Hidden from the card (S4): code/UID, unit, price mode, IVA, cost, QR
    // and the administrator actions.
    expect(find.text('PRD-COFFEE-001'), findsNothing);
    expect(find.text('Código interno PRD-COFFEE-001'), findsNothing);
    expect(find.textContaining('Unidad:'), findsNothing);
    expect(find.textContaining('Modo de precio:'), findsNothing);
    expect(find.textContaining('Tratamiento de IVA:'), findsNothing);
    expect(find.textContaining('Tasa de IVA:'), findsNothing);
    expect(find.textContaining('Último costo'), findsNothing);
    expect(find.text('Editar precio / IVA'), findsNothing);
    expect(find.text('Registrar entrada de inventario'), findsNothing);
    expect(find.byType(ProductQrView), findsNothing);
  });

  testWidgets('unpriced product shows Sin precio on the card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_tea])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sin precio'), findsOneWidget);
    expect(find.textContaining('Precio:'), findsNothing);
  });

  testWidgets('long-press on the card opens the detail sheet', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Café de grano'));
    await tester.pumpAndSettle();

    expect(_sheet(_coffee.internalCode), findsOneWidget);
    await _closeSheet(tester);
    expect(_sheet(_coffee.internalCode), findsNothing);
  });

  testWidgets('the Detalles button opens the sheet and names the product', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    // The long-press gesture is never the only path: a visible labelled
    // button opens the same sheet (S5).
    expect(
      find.bySemanticsLabel('Ver detalles de Café de grano'),
      findsOneWidget,
    );
    await _openSheet(tester, _coffee.internalCode);
    expect(_sheet(_coffee.internalCode), findsOneWidget);
    await _closeSheet(tester);
    expect(_sheet(_coffee.internalCode), findsNothing);
    semantics.dispose();
  });

  testWidgets('seller sheet shows price, price mode, stock and QR only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    await _openSheet(tester, _coffee.internalCode);
    // The name shows on both the card behind the sheet and in the sheet.
    expect(find.text('Café de grano'), findsWidgets);
    expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
    expect(find.text('Modo de precio: IVA incluido'), findsOneWidget);
    expect(find.byType(ProductQrView), findsOneWidget);
    // Administrator-only fields never reach the seller sheet (S5).
    expect(find.text('PRD-COFFEE-001'), findsNothing);
    expect(find.textContaining('Unidad:'), findsNothing);
    expect(find.textContaining('Tratamiento de IVA:'), findsNothing);
    expect(find.textContaining('Tasa de IVA:'), findsNothing);
    expect(find.textContaining('Último costo'), findsNothing);
    expect(find.text('Editar precio / IVA'), findsNothing);
    expect(find.text('Registrar entrada de inventario'), findsNothing);
  });

  testWidgets('administrator sheet shows every hidden field and the actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_administrator, _administratorSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    await _openSheet(tester, _coffee.internalCode);
    expect(find.text('PRD-COFFEE-001'), findsOneWidget);
    expect(find.text('Unidad: kg (precisión 2)'), findsOneWidget);
    expect(find.text('Modo de precio: IVA incluido'), findsOneWidget);
    expect(find.text('Tratamiento de IVA: Gravado'), findsOneWidget);
    expect(find.text('Tasa de IVA: 16%'), findsOneWidget);
    expect(find.text('Último costo unitario: 3.45 MXN'), findsOneWidget);
    // Per-branch stock shows on both the card and the sheet.
    expect(find.text('North Demo Branch: 1.00 kg'), findsWidgets);
    expect(
      find.text('South Demo Branch: Agotado · Sin entrada registrada'),
      findsWidgets,
    );
    expect(find.byType(ProductQrView), findsOneWidget);
    expect(find.text('Editar precio / IVA'), findsOneWidget);
    expect(find.text('Registrar entrada de inventario'), findsOneWidget);
  });

  testWidgets('administrator actions in the sheet open their flows', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(_administrator, _administratorSnapshot(<CatalogProduct>[_coffee])),
    );
    await tester.pumpAndSettle();

    // Pricing: the sheet closes first, then the existing flow opens.
    await _openSheet(tester, _coffee.internalCode);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    expect(_sheet(_coffee.internalCode), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('pricing-listed-price')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Cerrar'));
    await tester.pumpAndSettle();

    // Intake: same handoff through the sheet.
    await _openSheet(tester, _coffee.internalCode);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    expect(_sheet(_coffee.internalCode), findsNothing);
    expect(find.byKey(const ValueKey<String>('intake-branch')), findsOneWidget);
  });

  testWidgets('two columns do not overflow at text scale 2 on a 360px phone', (
    WidgetTester tester,
  ) async {
    _usePlatform(TargetPlatform.android);
    useViewport(tester, const Size(360, 800), 2);
    await tester.pumpWidget(
      _app(_seller, _sellerSnapshot(<CatalogProduct>[_coffee, _tea, _water])),
    );
    await tester.pumpAndSettle();

    final Object? error = tester.takeException();
    if (error != null) debugPrint('OVERFLOW DETAILS: $error');
    expect(error, isNull);
    // The sheet is scrollable, so it must also hold at large text.
    await _openSheet(tester, _coffee.internalCode);
    expect(_sheet(_coffee.internalCode), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
