import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

class _Repository implements CatalogRepository {
  _Repository(this.result);

  final Future<List<CatalogProduct>> result;

  @override
  Future<List<CatalogProduct>> fetchProducts() => result;
}

const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Coffee',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

Widget _app(CatalogRepository repository) =>
    MaterialApp(home: CatalogPage(repository: repository));

void main() {
  testWidgets('shows an accessible loading state', (WidgetTester tester) async {
    final Completer<List<CatalogProduct>> completer =
        Completer<List<CatalogProduct>>();

    await tester.pumpWidget(_app(_Repository(completer.future)));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);
  });

  testWidgets('shows an empty catalog state', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('No products yet'), findsOneWidget);
    expect(
      find.text('Products will appear here when available.'),
      findsOneWidget,
    );
  });

  testWidgets('shows an error without leaking technical details', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Repository(
          Future<List<CatalogProduct>>.delayed(
            Duration.zero,
            () => throw 'secret-stack-value',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.textContaining('secret-stack-value'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('renders the exact internal code as the QR data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[_coffee]))),
    );
    await tester.pumpAndSettle();

    final ProductQrView qr = tester.widget<ProductQrView>(
      find.byType(ProductQrView),
    );
    expect(ProductQr.payloadFor(qr.product), 'PRD-COFFEE-001');
    expect(
      find.byKey(const ValueKey<String>('product-qr-PRD-COFFEE-001')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('QR code for Coffee. Code PRD-COFFEE-001'),
      findsOneWidget,
    );
    expect(find.text('Listed price: 129.00 MXN'), findsOneWidget);
    expect(find.text('IVA treatment: taxable'), findsOneWidget);
    expect(find.textContaining('acquisition'), findsNothing);
    expect(find.textContaining('admin'), findsNothing);
  });

  testWidgets('fits narrow and wide layouts without overflow', (
    WidgetTester tester,
  ) async {
    for (final Size size in <Size>[
      const Size(320, 700),
      const Size(1200, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        _app(_Repository(Future.value(<CatalogProduct>[_coffee]))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });
}
