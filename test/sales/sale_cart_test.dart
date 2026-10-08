import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import 'sale_fixtures.dart';

SaleCartLine _line(String quantity, {int precision = 2, String id = 'P-1'}) =>
    SaleCartLine(
      productId: id,
      name: 'Product',
      quantitySpec: QuantitySpec(unit: 'meter', precision: precision),
      quantity: quantity,
    );

void main() {
  group('SaleCartLine', () {
    test('scales canonical decimals exactly with the product precision', () {
      expect(_line('2.5').quantityScaled, 250);
      expect(_line('2.50').quantityScaled, 250);
      expect(_line('0.01').quantityScaled, 1);
      expect(_line('12', precision: 0).quantityScaled, 12);
      expect(
        _line('9007199254.740991', precision: 6).quantityScaled,
        9007199254740991,
      );
    });

    test(
      'rejects non-canonical, zero, over-precise, and unsafe quantities',
      () {
        for (final String quantity in <String>[
          '',
          '0',
          '0.00',
          '-1',
          '+1',
          '01',
          '1.',
          '.5',
          '1e2',
          '1,5',
          ' 1',
          '1.234',
          '1.000',
          '1234567890123456789',
        ]) {
          expect(
            () => _line(quantity),
            throwsA(isA<SaleValidationException>()),
            reason: quantity,
          );
        }
        expect(
          () => _line('1.5', precision: 0),
          throwsA(isA<SaleValidationException>()),
        );
        expect(
          () => _line('9007199254.740992', precision: 6),
          throwsA(isA<SaleValidationException>()),
        );
      },
    );

    test('rejects invalid product ids, units, and precisions', () {
      expect(
        () => _line('1', id: 'bad id'),
        throwsA(isA<SaleValidationException>()),
      );
      expect(
        () => _line('1', precision: 7),
        throwsA(isA<SaleValidationException>()),
      );
      expect(
        () => SaleCartLine(
          productId: 'P-1',
          name: 'Product',
          quantitySpec: const QuantitySpec(unit: 'Meter', precision: 0),
          quantity: '1',
        ),
        throwsA(isA<SaleValidationException>()),
      );
    });
  });

  group('SaleCart', () {
    test('adds, edits, removes lines immutably and keeps order', () {
      final SaleCart empty = SaleCart.empty();
      final SaleCart cart = empty.add(ribbonLine).add(pinLine);

      expect(empty.isEmpty, isTrue);
      expect(cart.lineCount, 2);
      expect(cart.lines.map((SaleCartLine line) => line.productId), <String>[
        'DEMO-RIBBON',
        'DEMO-PIN',
      ]);
      expect(() => cart.lines.add(ribbonLine), throwsUnsupportedError);

      final SaleCart edited = cart.updateQuantity('DEMO-RIBBON', '4.25');
      expect(edited.lines.first.quantity, '4.25');
      expect(edited.lines.first.quantityScaled, 425);
      expect(cart.lines.first.quantity, '2.5');

      final SaleCart removed = edited.remove('DEMO-RIBBON');
      expect(removed.lines.single.productId, 'DEMO-PIN');
      expect(
        () => removed.remove('DEMO-RIBBON'),
        throwsA(isA<SaleValidationException>()),
      );
      expect(
        () => removed.updateQuantity('DEMO-RIBBON', '1'),
        throwsA(isA<SaleValidationException>()),
      );
      expect(
        () => cart.updateQuantity('DEMO-PIN', '1.5'),
        throwsA(isA<SaleValidationException>()),
      );
    });

    test('rejects a duplicate product instead of merging lines', () {
      final SaleCart cart = SaleCart.empty().add(ribbonLine);
      expect(
        () => cart.add(
          SaleCartLine(
            productId: 'DEMO-RIBBON',
            name: 'Ribbon',
            quantitySpec: const QuantitySpec(unit: 'meter', precision: 2),
            quantity: '1',
          ),
        ),
        throwsA(isA<SaleDuplicateProductException>()),
      );
    });

    test('builds the exact quote request and tracks the invoice option', () {
      final SaleCart cart = invoicedCart();
      expect(cart.invoiceRequested, isTrue);
      expect(cart.toQuoteRequest(), <String, Object?>{
        'invoiceRequested': true,
        'lines': <Object?>[
          <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.5'},
          <String, Object?>{'productId': 'DEMO-PIN', 'quantity': '3'},
        ],
      });
      expect(cart.withInvoiceRequested(false).invoiceRequested, isFalse);
      expect(
        () => SaleCart.empty().toQuoteRequest(),
        throwsA(isA<SaleValidationException>()),
      );
    });

    test('has value equality over lines and invoice option', () {
      expect(invoicedCart(), invoicedCart());
      expect(invoicedCart().hashCode, invoicedCart().hashCode);
      expect(
        invoicedCart() == invoicedCart().withInvoiceRequested(false),
        isFalse,
      );
      expect(
        invoicedCart() == invoicedCart().updateQuantity('DEMO-RIBBON', '2.50'),
        isFalse,
      );
    });
  });

  test('payment methods map to the exact server wire values', () {
    expect(
      SalePaymentMethod.values.map((SalePaymentMethod m) => m.wireValue),
      <String>['cash', 'card', 'transfer'],
    );
    expect(SalePaymentMethod.fromWire('transfer'), SalePaymentMethod.transfer);
    expect(SalePaymentMethod.fromWire('Cash'), isNull);
  });
}
