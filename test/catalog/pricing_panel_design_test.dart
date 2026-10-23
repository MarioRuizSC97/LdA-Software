import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';

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

Future<void> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
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
        catalogLoader: (_) async => CatalogSnapshot(<CatalogItem>[
          CatalogItem(product: _product, holdings: <CatalogHolding>[]),
        ]),
        createPricingId: () => 'private-audit-id',
        setProductPrice: (draft) async =>
            ProductPricingResult.fromCallable(<String, Object?>{
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': <String, Object?>{
                'listedPriceCentavos': draft.listedPriceCentavos,
                'currency': 'MXN',
                'priceMode': draft.priceMode,
                'ivaTreatment': draft.ivaTreatment,
                'ivaRateBasisPoints': draft.ivaRateBasisPoints,
              },
              'replayed': false,
            }, request: draft),
        renameProduct: (_) async => throw StateError('not submitted'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('product-details-PRD-TEST-001')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('configure-price-PRD-TEST-001')));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, {bool reducedMotion = false}) async {
  await _open(tester, reducedMotion: reducedMotion);
  final save = find.widgetWithText(FilledButton, 'Guardar precio / IVA');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pump();
  await tester.pump();
}

void _pill(InputBorder? border) {
  expect(border, isA<OutlineInputBorder>());
  expect(
    (border! as OutlineInputBorder).borderRadius.topLeft.x,
    greaterThanOrEqualTo(24),
  );
}

void main() {
  testWidgets(
    'price success says only Precio guardado, including live semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _save(tester);
      expect(find.text('Precio guardado'), findsOneWidget);
      expect(find.textContaining('private-audit-id'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('private-audit-id')), findsNothing);
      final notice = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.text('Precio guardado'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(notice.properties.liveRegion, isTrue);
      expect(notice.properties.label, 'Precio guardado');
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );

  testWidgets(
    'price expires at ten seconds with the creation 220ms fade/collapse',
    (tester) async {
      await _save(tester);
      final banner = find.textContaining('Precio guardado');
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

  testWidgets('reduced motion removes price notice at ten seconds', (
    tester,
  ) async {
    await _save(tester, reducedMotion: true);
    await tester.pump(const Duration(seconds: 9));
    expect(find.textContaining('Precio guardado'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Precio guardado'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final width in <double>[400, 1200]) {
      testWidgets(
        'editor pills, tone and unchanged fields: $brightness / $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await _open(tester, brightness: brightness);
          final close = find.widgetWithText(FilledButton, 'Cerrar');
          expect(close, findsOneWidget);
          final button = tester.widget<FilledButton>(close);
          final context = tester.element(close);
          final background = (button.style ?? button.defaultStyleOf(context))
              .backgroundColor!
              .resolve(<WidgetState>{});
          expect(background, Theme.of(context).colorScheme.secondaryContainer);
          final fields = <String, String>{
            'pricing-listed-price': 'Precio de lista (MXN)',
            'pricing-mode': 'Modo de precio',
            'pricing-treatment': 'Tratamiento de IVA',
            'pricing-iva-rate': 'Tasa de IVA (%)',
            'rename-name-PRD-TEST-001': 'Nombre del producto',
          };
          for (final entry in fields.entries) {
            final field = find.byKey(ValueKey(entry.key));
            expect(field, findsOneWidget);
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            final decorator = tester.widget<InputDecorator>(
              find.descendant(of: field, matching: find.byType(InputDecorator)),
            );
            expect(decorator.decoration.labelText, entry.value);
            _pill(decorator.decoration.border);
            expect(tester.takeException(), isNull);
          }
          final price = find.byKey(const ValueKey('pricing-listed-price'));
          await tester.ensureVisible(price);
          await tester.enterText(price, '');
          final save = find.widgetWithText(
            FilledButton,
            'Guardar precio / IVA',
          );
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          final error = tester
              .widget<InputDecorator>(
                find.descendant(
                  of: price,
                  matching: find.byType(InputDecorator),
                ),
              )
              .decoration;
          expect(error.errorText, 'El precio de lista es obligatorio.');
          _pill(error.errorBorder);
          _pill(error.focusedErrorBorder);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
