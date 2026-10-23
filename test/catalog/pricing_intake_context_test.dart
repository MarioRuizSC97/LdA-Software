import 'dart:ui' show ImageFilter;

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';

const _code = 'PRD-CONTEXT-001';
const _product = CatalogProduct(
  internalCode: _code,
  name: 'Café de prueba',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 800,
  ),
);

class _Harness {
  int calls = 0;
  int keys = 0;
  StockIntakeDraft? sent;
  bool created = false;
  bool creationFlow = false;
  bool hasCost = false;

  Future<void> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.light
            ? buildInventoryTheme()
            : buildDarkInventoryTheme(),
        home: AuthenticatedCatalogPage(
          session: const EmulatorSession(
            userId: 'admin',
            email: 'admin@demo.invalid',
            role: InventoryRole.administrator,
          ),
          onLogout: () async {},
          catalogLoader: (_) async => CatalogSnapshot(
            [
              CatalogItem(
                product: creationFlow && created
                    ? const CatalogProduct(
                        internalCode: _code,
                        name: 'Nuevo café',
                        quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
                      )
                    : _product,
                holdings: const [
                  CatalogHolding(
                    branchId: 'branch-north',
                    branchName: 'Norte',
                    quantityScaled: 1234,
                  ),
                ],
              ),
            ],
            costsAvailable: true,
            costs: {
              if (hasCost)
                _code: CatalogProductCost.fromFirestore('costs/$_code', {
                  'latestUnitCostCentavos': 1233,
                  'currency': 'MXN',
                  'sourceEntryId': 'last-entry',
                  'updatedAt': Timestamp(0, 0),
                }),
            },
            branchChoices: const [
              CatalogBranchChoice(
                branchId: 'branch-north',
                branchName: 'Norte',
              ),
              CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
            ],
          ),
          setProductPrice: (_) async => throw StateError('not submitted'),
          createProduct: (_) async {
            created = true;
            return const ProductCreationResult(
              productId: _code,
              internalCode: _code,
              replayed: false,
            );
          },
          createDraftId: () => 'creation-key',
          createIntakeId: () => 'intake-${++keys}',
          submitStockIntake: (draft) async {
            calls++;
            sent = draft;
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
    await tester.pumpAndSettle();
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));
String _text(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(_key(key)).controller!.text;
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String panel) async {
  await _tap(tester, _key('product-details-$_code'));
  expect(find.text(_code), findsOneWidget);
  await _tap(tester, _key('$panel-$_code'));
}

Future<void> _choose(WidgetTester tester, String key, String label) async {
  await _tap(tester, _key(key));
  await _tap(tester, find.text(label).last);
}

Future<void> _fill(WidgetTester tester) async {
  await _choose(tester, 'intake-branch', 'Norte');
  await tester.enterText(_key('intake-quantity'), '1.23');
  await tester.enterText(_key('intake-unit-cost'), '2.01');
  await tester.pumpAndSettle();
}

void _size(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final panel in ['configure-price', 'intake']) {
      testWidgets('$panel primary tone $brightness', (tester) async {
        _size(tester, 1200);
        await _Harness().mount(tester, brightness: brightness);
        await _open(tester, panel);
        if (panel == 'intake') await _fill(tester);
        final button = find.widgetWithText(
          FilledButton,
          panel == 'intake' ? 'Registrar entrada' : 'Guardar precio / IVA',
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        final colors = Theme.of(tester.element(button)).colorScheme;
        final fill = tester
            .widget<Material>(
              find
                  .descendant(of: button, matching: find.byType(Material))
                  .first,
            )
            .color;
        expect(
          fill,
          brightness == Brightness.light
              ? colors.primaryContainer
              : colors.primary,
        );
        expect(fill, isNot(colors.secondaryContainer));
      });
    }
    for (final width in [400.0, 1200.0]) {
      for (final panel in ['configure-price', 'intake']) {
        testWidgets('$panel context, code and overflow $brightness $width', (
          tester,
        ) async {
          _size(tester, width);
          await _Harness().mount(tester, brightness: brightness);
          await _open(tester, panel);
          final rail = _key(
            panel == 'intake' ? 'intake-context' : 'pricing-context',
          );
          expect(rail, width == 1200 ? findsOneWidget : findsNothing);
          expect(find.text(_code), findsNothing);
          if (width == 1200) {
            if (panel == 'intake') {
              expect(
                find.descendant(
                  of: rail,
                  matching: find.text('Norte: 12.34 kg'),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(
                  of: rail,
                  matching: find.text('Sur: Agotado · Sin entrada registrada'),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(
                  of: rail,
                  matching: find.text('Sin costo registrado'),
                ),
                findsOneWidget,
              );
              await _fill(tester);
              expect(
                find.descendant(
                  of: rail,
                  matching: find.text('Total de la línea (truncado): 2.47 MXN'),
                ),
                findsOneWidget,
              );
            } else {
              expect(find.text('Precio actual'), findsOneWidget);
              expect(
                find.text('Precio de lista: 129.00 MXN'),
                findsNWidgets(2),
              );
              expect(find.text('Tasa de IVA: 8%'), findsOneWidget);
              await tester.enterText(_key('pricing-listed-price'), '42.50');
              await tester.pumpAndSettle();
              expect(
                find.descendant(
                  of: rail,
                  matching: find.text('Precio de lista: 42.50 MXN'),
                ),
                findsOneWidget,
              );
            }
            expect(
              find.descendant(of: rail, matching: find.text('0')),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
      testWidgets('confirmation summary and correction $brightness $width', (
        tester,
      ) async {
        _size(tester, width);
        final harness = _Harness();
        await harness.mount(tester, brightness: brightness);
        await _open(tester, 'intake');
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Registrar entrada'),
        );
        expect(_key('intake-confirm-dialog'), findsNothing);
        expect(harness.keys, 0);
        await _fill(tester);
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Registrar entrada'),
        );
        expect(_key('intake-confirm-dialog'), findsOneWidget);
        for (final text in [
          'Confirmar entrada de inventario',
          'Producto: Café de prueba',
          'Sucursal: Norte',
          'Cantidad: 1.23 kg',
          'Costo unitario: 2.01 MXN',
          'Total de la línea (truncado): 2.47 MXN',
        ]) {
          expect(
            find.descendant(
              of: _key('intake-confirm-dialog'),
              matching: find.text(text),
            ),
            findsOneWidget,
          );
        }
        expect(
          tester
              .widget<BackdropFilter>(find.byType(BackdropFilter).last)
              .filter,
          ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        );
        expect(harness.calls, 0);
        expect(harness.keys, 0);
        await _tap(tester, find.text('Corregir'));
        expect(_text(tester, 'intake-quantity'), '1.23');
        expect(_text(tester, 'intake-unit-cost'), '2.01');
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(_key('intake-branch'))
              .initialValue,
          'branch-north',
        );
        expect(harness.calls, 0);
        expect(harness.keys, 0);
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Registrar entrada'),
        );
        await _tap(tester, find.text('Confirmar'));
        expect(harness.calls, 1);
        expect(harness.keys, 1);
        expect(harness.sent!.quantity, '1.23');
        expect(harness.sent!.unitCostMxn, '2.01');
        expect(harness.sent!.lineTotalCentavos, 247);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('nonempty invalid intake stays inline before confirmation', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _open(tester, 'intake');
    await _fill(tester);
    await tester.enterText(_key('intake-quantity'), '0.001');
    await _tap(tester, find.widgetWithText(FilledButton, 'Registrar entrada'));
    expect(_key('intake-confirm-dialog'), findsNothing);
    expect(harness.calls, 0);
    expect(harness.keys, 0);
    expect(
      find.bySemanticsLabel('Error en la entrada de inventario'),
      findsOneWidget,
    );
  });
  testWidgets('intake context reuses last recorded unit cost', (tester) async {
    _size(tester, 1200);
    await (_Harness()..hasCost = true).mount(tester);
    await _open(tester, 'intake');
    expect(find.text('Último costo unitario: 12.33 MXN'), findsOneWidget);
  });
  testWidgets('confirmation cannot double-submit or allocate another key', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _open(tester, 'intake');
    await _fill(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Registrar entrada'));
    final confirm = find.widgetWithText(FilledButton, 'Confirmar');
    await tester.tap(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(harness.calls, 1);
    expect(harness.keys, 1);
  });
  testWidgets('disposed confirmation cannot allocate or submit', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    await _open(tester, 'intake');
    await _fill(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Registrar entrada'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(harness.calls, 0);
    expect(harness.keys, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'creation hands off to unselected pricing; Gravado defaults to 16',
    (tester) async {
      _size(tester, 1200);
      final harness = _Harness()..creationFlow = true;
      await harness.mount(tester);
      await _tap(tester, find.text('Crear producto'));
      await tester.enterText(_key('create-product-name'), 'Nuevo café');
      await tester.enterText(_key('create-product-unit'), 'kg');
      await _tap(tester, _key('create-product-precision'));
      await _tap(tester, find.text('2').last);
      await _tap(tester, find.widgetWithText(FilledButton, 'Crear'));
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('pricing-treatment'))
            .initialValue,
        isNull,
      );
      expect(_text(tester, 'pricing-iva-rate'), '');
      await _choose(tester, 'pricing-treatment', 'Gravado');
      expect(_text(tester, 'pricing-iva-rate'), '16');
    },
  );
  testWidgets('stored rate wins; treatment changes keep editable defaults', (
    tester,
  ) async {
    _size(tester, 1200);
    await _Harness().mount(tester);
    await _open(tester, 'configure-price');
    expect(_text(tester, 'pricing-iva-rate'), '8');
    await _choose(tester, 'pricing-treatment', 'Tasa 0%');
    expect(_text(tester, 'pricing-iva-rate'), '0');
    expect(
      tester.widget<TextFormField>(_key('pricing-iva-rate')).enabled,
      isFalse,
    );
    await _choose(tester, 'pricing-treatment', 'Gravado');
    expect(_text(tester, 'pricing-iva-rate'), '16');
    expect(
      tester.widget<TextFormField>(_key('pricing-iva-rate')).enabled,
      isTrue,
    );
    await tester.enterText(_key('pricing-iva-rate'), '10');
    await tester.pumpAndSettle();
    expect(find.text('Tasa de IVA ingresada: 10%'), findsOneWidget);
    final rateController = tester
        .widget<TextFormField>(_key('pricing-iva-rate'))
        .controller!;
    await _choose(tester, 'pricing-treatment', 'Exento');
    expect(_key('pricing-iva-rate'), findsNothing);
    expect(rateController.text, isEmpty);
    await _choose(tester, 'pricing-mode', 'IVA adicional en factura');
    expect(
      find.descendant(
        of: _key('pricing-context'),
        matching: find.text('Modo de precio: IVA adicional en factura'),
      ),
      findsOneWidget,
    );
    await _choose(tester, 'pricing-treatment', 'Gravado');
    expect(_text(tester, 'pricing-iva-rate'), '16');
  });
}
