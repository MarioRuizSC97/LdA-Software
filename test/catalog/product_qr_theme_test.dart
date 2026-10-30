import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/product_qr.dart';
import 'package:qr_flutter/qr_flutter.dart';

const CatalogProduct _product = CatalogProduct(
  internalCode: 'QR-THEME',
  name: 'Producto QR',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('QR has a light plate and black modules in $brightness', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: ProductQrView(product: _product)),
        ),
      );

      final Finder qr = find.byKey(
        const ValueKey<String>('product-qr-QR-THEME'),
      );
      expect(qr, findsOneWidget);
      final Finder plate = find.descendant(
        of: find.byType(ProductQrView),
        matching: find.byType(DecoratedBox),
      );
      expect(plate, findsOneWidget);
      final BoxDecoration decoration =
          tester.widget<DecoratedBox>(plate).decoration as BoxDecoration;
      expect(decoration.color, Colors.white);
      expect(decoration.borderRadius, isNotNull);
      expect(tester.getSize(qr), const Size(136, 136));
      final QrImageView image = tester.widget<QrImageView>(qr);
      expect(image.dataModuleStyle.color, Colors.black);
      expect(image.eyeStyle.color, Colors.black);
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics &&
              widget.properties.label ==
                  'Código QR de Producto QR. Código QR-THEME',
        ),
        findsOneWidget,
      );
    });
  }
}
