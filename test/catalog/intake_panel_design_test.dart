import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';
import 'package:lda_inventory/firebase/emulator_stock_intake_gateway.dart';

const _product = CatalogProduct(
  internalCode: 'PRD-TEST-001',
  name: 'Producto de prueba',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);
final _back = find.byKey(const ValueKey('panel-back'));

Future<void> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
  String panel = 'intake',
  bool reject = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.light
          ? buildInventoryTheme()
          : buildDarkInventoryTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: const EmulatorSession(
          userId: 'admin',
          email: 'admin@demo.invalid',
          role: InventoryRole.administrator,
        ),
        onLogout: () async {},
        catalogLoader: (_) async => CatalogSnapshot(
          [CatalogItem(product: _product, holdings: const [])],
          branchChoices: const [
            CatalogBranchChoice(
              branchId: 'branch-north',
              branchName: 'Sucursal Norte',
            ),
          ],
        ),
        createProduct: (_) async => const ProductCreationResult(
          productId: 'unused',
          internalCode: 'unused',
          replayed: false,
        ),
        setProductPrice: (_) async => throw StateError('not submitted'),
        createIntakeId: () => 'private-folio',
        submitStockIntake: (draft) async {
          if (reject) {
            throw const StockIntakeRejectedException(code: 'private-code');
          }
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
  if (panel == 'creation') {
    await tester.tap(find.text('Crear producto'));
  } else {
    await tester.tap(
      find.byKey(const ValueKey('product-details-PRD-TEST-001')),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(
      ValueKey(
        '${panel == 'intake' ? 'intake' : 'configure-price'}-PRD-TEST-001',
      ),
    );
    await tester.ensureVisible(action);
    await tester.tap(action);
  }
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('intake-branch')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sucursal Norte').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('intake-quantity')), '2');
  await tester.enterText(
    find.byKey(const ValueKey('intake-unit-cost')),
    '12.50',
  );
  final save = find.widgetWithText(FilledButton, 'Registrar entrada');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('intake-confirm-dialog')), findsOneWidget);
  await tester.tap(find.text('Confirmar'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 151));
}

void _pill(InputBorder? border) {
  expect(border, isA<OutlineInputBorder>());
  expect(
    (border! as OutlineInputBorder).borderRadius.topLeft.x,
    greaterThanOrEqualTo(24),
  );
}

void main() {
  for (final panel in ['creation', 'pricing', 'intake']) {
    testWidgets('$panel has only header exit and returns to catalog', (
      tester,
    ) async {
      await _open(tester, panel: panel);
      expect(find.text('Cerrar'), findsNothing);
      expect(_back, findsOneWidget);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(_back, findsNothing);
      expect(
        find.byKey(const ValueKey('product-details-PRD-TEST-001')),
        findsOneWidget,
      );
    });
  }
  for (final brightness in Brightness.values) {
    for (final width in <double>[400, 1200]) {
      testWidgets(
        'intake theme pills, labels and validation $brightness / $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await _open(tester, brightness: brightness);
          for (final entry in {
            'intake-branch': 'Sucursal',
            'intake-quantity': 'Cantidad (kg)',
            'intake-unit-cost': 'Costo unitario (MXN)',
          }.entries) {
            final field = find.byKey(ValueKey(entry.key));
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            final decoration = tester
                .widget<InputDecorator>(
                  find.descendant(
                    of: field,
                    matching: find.byType(InputDecorator),
                  ),
                )
                .decoration;
            expect(decoration.labelText, entry.value);
            _pill(decoration.border);
            expect(tester.takeException(), isNull);
          }
          final save = find.widgetWithText(FilledButton, 'Registrar entrada');
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          for (final message in [
            'La sucursal es obligatoria.',
            'La cantidad es obligatoria.',
            'El costo unitario es obligatorio.',
          ]) {
            expect(find.text(message), findsOneWidget);
          }
          for (final key in [
            'intake-branch',
            'intake-quantity',
            'intake-unit-cost',
          ]) {
            final field = find.byKey(ValueKey(key));
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            final decoration = tester
                .widget<InputDecorator>(
                  find.descendant(
                    of: field,
                    matching: find.byType(InputDecorator),
                  ),
                )
                .decoration;
            _pill(decoration.errorBorder);
            _pill(decoration.focusedErrorBorder);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'intake success keeps wording without visible or semantic folio',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester);
      await _submit(tester);
      expect(find.text('Entrada registrada.'), findsOneWidget);
      expect(find.textContaining('private-folio'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('private-folio|Folio')),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel('Entrada de inventario registrada'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );
  testWidgets(
    'intake matches price ten-second deadline and 220ms fade/collapse',
    (tester) async {
      await _open(tester);
      await _submit(tester);
      final banner = find.textContaining('Entrada registrada');
      await tester.pump(const Duration(seconds: 9));
      expect(banner, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 110));
      expect(banner, findsOneWidget);
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: banner, matching: find.byType(FadeTransition)).first,
      );
      final collapse = tester.widget<SizeTransition>(
        find.ancestor(of: banner, matching: find.byType(SizeTransition)).first,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      expect(collapse.sizeFactor.value, inExclusiveRange(0, 1));
      expect(collapse.alignment, Alignment.topCenter);
      await tester.pump(const Duration(milliseconds: 111));
      expect(banner, findsNothing);
    },
  );
  testWidgets('reduced motion removes intake at ten seconds', (tester) async {
    await _open(tester, reducedMotion: true);
    await _submit(tester);
    await tester.pump(const Duration(seconds: 9));
    expect(find.textContaining('Entrada registrada'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Entrada registrada'), findsNothing);
  });
  testWidgets('rejected intake uses themed honest error without raw code', (
    tester,
  ) async {
    await _open(tester, reject: true);
    await _submit(tester);
    expect(find.textContaining('private-code'), findsNothing);
    final error = find.text('Se rechazó la entrada de inventario.');
    expect(error, findsOneWidget);
    final surface = tester.widget<Container>(
      find.ancestor(of: error, matching: find.byType(Container)).first,
    );
    expect(
      (surface.decoration! as BoxDecoration).color,
      Theme.of(tester.element(error)).colorScheme.errorContainer,
    );
  });
}
