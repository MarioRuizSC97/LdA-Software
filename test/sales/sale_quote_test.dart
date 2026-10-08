import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

import 'sale_fixtures.dart';

Map<String, Object?> _calculationLine(Map<String, Object?> response, int i) =>
    ((response['calculation']! as Map<String, Object?>)['lines']!
            as List<Object?>)[i]!
        as Map<String, Object?>;

void main() {
  test('parses the server quote into per-line and total centavos', () {
    final SaleCart cart = invoicedCart();
    final SaleQuote quote = SaleQuote.fromCallable(quoteResponse(), cart: cart);

    expect(quote.cart, cart);
    expect(quote.totalCentavos, 3650);
    expect(quote.baseCentavos, 3250);
    expect(quote.additionalIvaCentavos, 400);
    expect(quote.allAvailable, isTrue);
    expect(quote.unavailableProductIds, isEmpty);
    expect(quote.lines.map((SalePricedLine line) => line.productId), <String>[
      'DEMO-RIBBON',
      'DEMO-PIN',
    ]);
    final SalePricedLine ribbon = quote.lines.first;
    expect(ribbon.name, 'Ribbon');
    expect(ribbon.quantityDecimal, '2.50');
    expect(ribbon.unit, 'meter');
    expect(ribbon.baseCentavos, 2500);
    expect(ribbon.additionalIvaCentavos, 400);
    expect(ribbon.totalCentavos, 2900);
    expect(quote.lines.last.totalCentavos, 750);
  });

  test('reports short stock per line without failing', () {
    final SaleQuote quote = SaleQuote.fromCallable(
      quoteResponse(pinAvailable: false),
      cart: invoicedCart(),
    );
    expect(quote.allAvailable, isFalse);
    expect(quote.unavailableProductIds, <String>{'DEMO-PIN'});
  });

  test('rejects forged, inconsistent, or malformed quote shapes', () {
    final List<Map<String, Object?> Function()>
    forgeries = <Map<String, Object?> Function()>[
      () => quoteResponse()..['totalCentavos'] = 3651,
      () => quoteResponse()..['extra'] = true,
      () => quoteResponse()..remove('lines'),
      () => quoteResponse()..['totalCentavos'] = 3650.0,
      () => quoteResponse()..['totalCentavos'] = '3650',
      () {
        final Map<String, Object?> r = quoteResponse();
        (r['calculation']! as Map<String, Object?>)['totalCentavos'] = 3651;
        r['totalCentavos'] = 3651;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        (r['calculation']! as Map<String, Object?>)['invoiceRequested'] = false;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        (r['calculation']! as Map<String, Object?>)['currency'] = 'USD';
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        _calculationLine(r, 0)['totalCentavos'] = 2901;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        _calculationLine(r, 0)['additionalIvaCentavos'] = -1;
        _calculationLine(r, 0)['baseCentavos'] = 2901;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        _calculationLine(r, 0)['includedIvaCentavos'] = 0;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        _calculationLine(r, 0)['unitCostCentavos'] = 1;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        (_calculationLine(r, 0)['quantity']!
                as Map<String, Object?>)['scaled'] =
            251;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        (_calculationLine(r, 0)['quantity']!
                as Map<String, Object?>)['decimal'] =
            '2.5';
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        ((_calculationLine(r, 0)['quantity']! as Map<String, Object?>)['spec']!
                as Map<String, Object?>)['precision'] =
            3;
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        ((r['calculation']! as Map<String, Object?>)['lines']! as List<Object?>)
            .removeLast();
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        ((r['lines']! as List<Object?>)[0]!
                as Map<String, Object?>)['productId'] =
            'DEMO-PIN';
        return r;
      },
      () {
        final Map<String, Object?> r = quoteResponse();
        ((r['lines']! as List<Object?>)[0]!
                as Map<String, Object?>)['available'] =
            'yes';
        return r;
      },
    ];
    for (int index = 0; index < forgeries.length; index++) {
      expect(
        () => SaleQuote.fromCallable(forgeries[index](), cart: invoicedCart()),
        throwsA(isA<SaleProtocolException>()),
        reason: 'forgery $index',
      );
    }
    expect(
      () => SaleQuote.fromCallable(null, cart: invoicedCart()),
      throwsA(isA<SaleProtocolException>()),
    );
    expect(
      () => SaleQuote.fromCallable(
        quoteResponse(),
        cart: invoicedCart().withInvoiceRequested(false),
      ),
      throwsA(isA<SaleProtocolException>()),
    );
  });
}
