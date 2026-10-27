import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';

import '../catalog/cost_pin_test_helper.dart';

const _code = 'PRD-AUDIT-001';
const _admin = EmulatorSession(
  userId: 'audit-admin',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const _product = CatalogProduct(
  internalCode: _code,
  name: 'Café molido de tueste artesanal para cafeterías y restaurantes',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 800,
  ),
);

CatalogSnapshot _snapshot({bool unavailable = false}) => CatalogSnapshot(
  [CatalogItem(product: _product, holdings: const [
    CatalogHolding(
      branchId: 'branch-north',
      branchName: 'Sucursal Norte',
      quantityScaled: 1234,
    ),
  ])],
  branchChoices: const [
    CatalogBranchChoice(branchId: 'branch-north', branchName: 'Sucursal Norte'),
    CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sucursal Sur'),
  ],
  costsAvailable: !unavailable,
  costs: {
    if (!unavailable)
      _code: CatalogProductCost.fromFirestore('costs/$_code', {
        'latestUnitCostCentavos': 98765,
        'currency': 'MXN',
        'sourceEntryId': 'private-entry-id',
        'updatedAt': Timestamp(0, 0),
      }),
  },
);

Finder _key(String key) => find.byKey(ValueKey(key));
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Harness {
  int creations = 0;
  int prices = 0;
  int intakes = 0;
  ProductCreationSubmit? create;
  ProductPricingSubmit? price;
  StockIntakeSubmit? intake;
  CatalogSnapshotLoader? loader;
  final session = ValueNotifier<EmulatorSession?>(_admin);

  Widget app({Brightness brightness = Brightness.light, VoidCallback? logout}) =>
      MaterialApp(
        theme: brightness == Brightness.light
            ? buildInventoryTheme()
            : buildDarkInventoryTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.3),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: ValueListenableBuilder<EmulatorSession?>(
          valueListenable: session,
          builder: (context, value, child) => value == null
              ? const Scaffold(body: Text('Sesión cerrada'))
              : AuthenticatedCatalogPage(
          session: value,
          catalogLoader: loader ?? (_) async => _snapshot(),
          onLogout: () async {
            session.value = null;
            logout?.call();
          },
          createDraftId: () => 'audit-creation-key',
          createPricingId: () => 'audit-pricing-key',
          createIntakeId: () => 'audit-intake-key',
          createProduct: (draft) async {
            creations++;
            if (create != null) return create!(draft);
            return const ProductCreationResult(
              productId: _code, internalCode: _code, replayed: false,
            );
          },
          setProductPrice: (draft) async {
            prices++;
            if (price != null) return price!(draft);
            return ProductPricingResult.fromCallable({
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': {
                'listedPriceCentavos': draft.listedPriceCentavos,
                'currency': 'MXN',
                'priceMode': draft.priceMode,
                'ivaTreatment': draft.ivaTreatment,
                'ivaRateBasisPoints': draft.ivaRateBasisPoints,
              },
              'replayed': false,
            }, request: draft);
          },
          submitStockIntake: (draft) async {
            intakes++;
            if (intake != null) return intake!(draft);
            return StockIntakeResult.fromCallable({
              'entryId': draft.idempotencyKey,
              'movementId': draft.idempotencyKey,
              'quantityScaled': draft.quantityScaled,
              'stockQuantityScaled': draft.quantityScaled,
              'unitCostCentavos': draft.unitCostCentavos,
              'lineTotalCentavos': draft.lineTotalCentavos,
              'replayed': false,
            }, request: draft);
          },
        ),
        ),
      );

  Future<void> mount(WidgetTester tester, {
    double width = 1200,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(brightness: brightness));
    await tester.pumpAndSettle();
  }
}

Future<void> _details(WidgetTester tester) async {
  await _tap(tester, _key('product-details-$_code'));
  expect(_key('product-sheet-$_code'), findsOneWidget);
}
Future<void> _open(WidgetTester tester, String panel) async {
  if (panel == 'grid') return;
  if (panel == 'search') {
    await tester.enterText(_key('catalog-search'), 'Café');
    await tester.pumpAndSettle();
    expect(_key('catalog-search-results'), findsOneWidget);
    return;
  }
  if (panel == 'creation') {
    await _tap(tester, find.text('Crear producto'));
    return;
  }
  await _details(tester);
  if (panel == 'details') return;
  if (panel == 'pin') {
    await _tap(tester, find.text('Ver costo'));
    return;
  }
  await _tap(tester, _key('${panel == 'pricing' ? 'configure-price' : 'intake'}-$_code'));
  if (panel != 'pricing') await unlockCostPin(tester);
  if (panel == 'confirmation') {
    await _fillIntake(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Registrar entrada'));
    expect(_key('intake-confirm-dialog'), findsOneWidget);
  }
}

Future<void> _choose(WidgetTester tester, String key, String text) async {
  await _tap(tester, _key(key));
  await _tap(tester, find.text(text).last);
}
Future<void> _fillIntake(WidgetTester tester) async {
  await _choose(tester, 'intake-branch', 'Sucursal Norte');
  await tester.enterText(_key('intake-quantity'), '1.23');
  await tester.enterText(_key('intake-unit-cost'), '2.01');
  await tester.pumpAndSettle();
}
Future<void> _fillCreation(WidgetTester tester) async {
  await tester.enterText(_key('create-product-name'), 'Nuevo café');
  await tester.enterText(_key('create-product-unit'), 'kg');
  await _choose(tester, 'create-product-precision', '2');
}
String _value(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(_key(key)).controller!.text;

void _noCost() {
  expect(find.textContaining('987.65'), findsNothing);
  expect(find.bySemanticsLabel(RegExp('987[.,]65|private-entry-id')), findsNothing);
}

void main() {
  setUpCostPin();

  // T22 D2: each surface is isolated, so one overflow cannot hide another.
  for (final panel in ['grid', 'search', 'details', 'creation', 'pricing', 'intake', 'confirmation', 'pin']) {
    for (final brightness in Brightness.values) {
      for (final width in [320.0, 400.0, 600.0, 1200.0]) {
        testWidgets('$panel fits $width $brightness at text scale 1.3', (tester) async {
          final semantics = tester.ensureSemantics();
          try {
          await _Harness().mount(tester, width: width, brightness: brightness);
          await _open(tester, panel);
          expect(tester.takeException(), isNull);
          if (panel == 'creation' || panel == 'pricing' || panel == 'intake') {
            final save = find.widgetWithText(FilledButton, switch (panel) {
              'creation' => 'Crear',
              'pricing' => 'Guardar precio / IVA',
              _ => 'Registrar entrada',
            });
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (panel == 'pricing') {
              await tester.enterText(_key('pricing-listed-price'), '');
              await tester.ensureVisible(save);
              await tester.pumpAndSettle();
            }
            await tester.tap(save);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          for (final button in find.byType(IconButton).hitTestable().evaluate()) {
            final data = tester.getSemantics(find.byWidget(button.widget)).getSemanticsData();
            expect('${data.label}${data.tooltip}'.trim(), isNotEmpty,
              reason: 'T22 D2: visible icon-only controls need an accessible name: ${button.widget}.');
          }
          // Flush transient routes and timers without authorizing mutations.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  for (final panel in ['creation', 'pricing', 'intake']) {
    testWidgets('$panel header Volver returns to catalog and locks costs', (tester) async {
      final semantics = tester.ensureSemantics();
      await _Harness().mount(tester);
      await _open(tester, panel);
      expect(find.byTooltip('Volver'), findsOneWidget);
      await _tap(tester, _key('panel-back'));
      expect(_key('panel-back'), findsNothing);
      expect(_key('product-details-$_code'), findsOneWidget);
      _noCost();
      if (panel == 'intake') {
        await _details(tester);
        await _tap(tester, _key('intake-$_code'));
        expect(_key('cost-pin-dialog'), findsOneWidget);
        expect(_key('intake-unit-cost'), findsNothing);
      }
      semantics.dispose();
    });
  }

  testWidgets('locked details wrong PIN cancel and reopen never expose cost semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await _Harness().mount(tester);
    await _details(tester);
    _noCost();
    expect(find.byTooltip('Cerrar detalles'), findsOneWidget);
    await _tap(tester, find.text('Ver costo'));
    await tester.enterText(_key('cost-pin'), '0000');
    await _tap(tester, find.text('Continuar'));
    expect(find.text('PIN incorrecto.'), findsOneWidget);
    _noCost();
    await _tap(tester, find.text('Cancelar'));
    _noCost();
    await revealCost(tester);
    expect(find.text('Último costo unitario: 987.65 MXN'), findsOneWidget);
    await _tap(tester, _key('product-sheet-close'));
    await _details(tester);
    _noCost();
    semantics.dispose();
  });

  for (final panel in ['details', 'intake', 'confirmation']) {
    for (final replacement in ['logout', 'seller']) {
      testWidgets('$panel removes cost text and semantics on $replacement', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final harness = _Harness();
          await harness.mount(tester);
          await _open(tester, panel);
          if (panel == 'details') await revealCost(tester);
          if (replacement == 'logout') {
            await tester.widget<AuthenticatedCatalogPage>(find.byType(AuthenticatedCatalogPage)).onLogout();
          } else {
            harness.session.value = const EmulatorSession(
              userId: 'audit-admin', email: 'admin@demo.invalid',
              role: InventoryRole.seller, branchId: 'branch-north',
            );
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('987.65', skipOffstage: false), findsNothing);
          expect(find.textContaining('Costo unitario: 2.01 MXN', skipOffstage: false), findsNothing,
            reason: 'T20 D4/D5: leaving the session must revoke every cost presentation, including confirmation.');
          expect(find.bySemanticsLabel(RegExp('987[.,]65|Costo unitario: 2[.,]01')), findsNothing);
          expect(_key('intake-confirm-dialog'), findsNothing);
          expect(_key('product-sheet-$_code'), findsNothing);
          expect(_key('intake-unit-cost'), findsNothing);
          expect(harness.intakes, 0);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('double tap Ver costo opens only one PIN challenge', (tester) async {
    await _Harness().mount(tester);
    await _details(tester);
    final reveal = find.text('Ver costo');
    final point = tester.getCenter(reveal);
    await tester.tapAt(point);
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(_key('cost-pin-dialog'), findsOneWidget);
    await _tap(tester, find.text('Cancelar'));
    expect(_key('cost-pin-dialog'), findsNothing);
    expect(find.text('Ver costo'), findsOneWidget);
  });

  testWidgets('creation double tap has exactly one pending gateway call', (tester) async {
    final pending = Completer<ProductCreationResult>();
    final harness = _Harness()..create = (_) => pending.future;
    await harness.mount(tester);
    await _open(tester, 'creation');
    await _fillCreation(tester);
    final button = find.widgetWithText(FilledButton, 'Crear');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(harness.creations, 1);
    expect(tester.widget<TextFormField>(_key('create-product-name')).enabled, isFalse);
    pending.complete(const ProductCreationResult(productId: _code, internalCode: _code, replayed: false));
    await tester.pumpAndSettle();
    expect(harness.creations, 1);
  });

  testWidgets('pricing double tap has exactly one pending gateway call', (tester) async {
    final pending = Completer<ProductPricingResult>();
    ProductPricingDraft? submitted;
    final harness = _Harness()..price = (draft) { submitted = draft; return pending.future; };
    await harness.mount(tester);
    await _open(tester, 'pricing');
    final button = find.widgetWithText(FilledButton, 'Guardar precio / IVA');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(harness.prices, 1);
    pending.complete(ProductPricingResult.fromCallable({
      'auditId': submitted!.idempotencyKey,
      'productId': _code,
      'pricing': {'listedPriceCentavos': 12900, 'currency': 'MXN', 'priceMode': 'iva-included', 'ivaTreatment': 'taxable', 'ivaRateBasisPoints': 800},
      'replayed': false,
    }, request: submitted!));
    await tester.pumpAndSettle();
    expect(harness.prices, 1);
  });

  testWidgets('intake correction retains exact draft then duplicate confirm submits once', (tester) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _open(tester, 'confirmation');
    expect(harness.intakes, 0);
    await _tap(tester, find.text('Corregir'));
    expect(_value(tester, 'intake-quantity'), '1.23');
    expect(_value(tester, 'intake-unit-cost'), '2.01');
    await _tap(tester, find.widgetWithText(FilledButton, 'Registrar entrada'));
    final button = find.widgetWithText(FilledButton, 'Confirmar');
    final point = tester.getCenter(button);
    await tester.tapAt(point);
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(harness.intakes, 1);
    expect(find.text('Entrada registrada.'), findsOneWidget);
    expect(find.textContaining('audit-intake-key'), findsNothing);
  });

  for (final panel in ['creation', 'pricing']) {
    testWidgets('$panel rejection is Spanish without raw gateway codes', (tester) async {
      final harness = _Harness();
      harness.create = (_) async => throw const ProductCreationRejectedException(code: 'permission-denied');
      harness.price = (_) async => throw const ProductPricingRejectedException(code: 'failed-precondition');
      await harness.mount(tester);
      await _open(tester, panel);
      if (panel == 'creation') await _fillCreation(tester);
      await _tap(tester, find.widgetWithText(FilledButton, panel == 'creation' ? 'Crear' : 'Guardar precio / IVA'));
      expect(panel == 'creation' ? harness.creations : harness.prices, 1);
      expect(find.textContaining(panel == 'creation' ? 'permission-denied' : 'failed-precondition'), findsNothing,
        reason: 'T22 D2 and T18 D3 require honest Spanish copy, not raw backend codes.');
    });
  }

  testWidgets('Gravado preserves stored rate and defaults to editable 16 after Exento', (tester) async {
    await _Harness().mount(tester);
    await _open(tester, 'pricing');
    expect(_value(tester, 'pricing-iva-rate'), '8');
    await _choose(tester, 'pricing-treatment', 'Exento');
    expect(_key('pricing-iva-rate'), findsNothing);
    await _choose(tester, 'pricing-treatment', 'Gravado');
    expect(_value(tester, 'pricing-iva-rate'), '16');
    await tester.enterText(_key('pricing-iva-rate'), '10');
    await tester.pumpAndSettle();
    expect(_value(tester, 'pricing-iva-rate'), '10');
    expect(find.text('Tasa de IVA ingresada: 10%'), findsOneWidget);
  });

  testWidgets('unavailable cost is not fabricated as zero in details or intake rail', (tester) async {
    final harness = _Harness()..loader = (_) async => _snapshot(unavailable: true);
    await harness.mount(tester);
    await _details(tester);
    await revealCost(tester);
    expect(find.text('Costo no disponible'), findsOneWidget);
    expect(find.textContaining('0.00 MXN'), findsNothing);
    await _tap(tester, _key('intake-$_code'));
    await unlockCostPin(tester);
    expect(_key('intake-context'), findsOneWidget);
    expect(find.text('Costo no disponible'), findsOneWidget);
    expect(find.textContaining('0.00 MXN'), findsNothing);
    expect(find.text(_code), findsNothing);
  });

  testWidgets('catalog loading error retry and empty never fabricate inventory or leak exception', (tester) async {
    final pending = Completer<CatalogSnapshot>();
    var loads = 0;
    final harness = _Harness()..loader = (_) {
      loads++;
      return loads == 1 ? pending.future : Future.value(CatalogSnapshot(const []));
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.app());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('0'), findsNothing);
    pending.completeError(StateError('private Firestore permission-denied'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Firestore'), findsNothing);
    expect(find.textContaining('permission-denied'), findsNothing);
    expect(find.text('0'), findsNothing);
    await _tap(tester, find.text('Reintentar'));
    expect(loads, 2);
    expect(find.text('0'), findsNothing);
    expect(_key('product-card-$_code'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused no-match search is honest and system back preserves the query', (tester) async {
    await _Harness().mount(tester, width: 320);
    await tester.enterText(_key('catalog-search'), 'producto inexistente');
    await tester.pumpAndSettle();
    expect(_key('product-card-$_code'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('Sin resultados'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('catalog-search-results'), findsNothing);
    expect(tester.widget<TextField>(_key('catalog-search')).controller!.text, 'producto inexistente');
    expect(tester.takeException(), isNull);
  });
}
