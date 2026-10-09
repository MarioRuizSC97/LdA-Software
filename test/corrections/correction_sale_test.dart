import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

Matcher _protocol() => throwsA(isA<CorrectionProtocolException>());

Matcher _invalid(CorrectionValidationReason reason) => throwsA(
  isA<CorrectionValidationException>().having(
    (CorrectionValidationException error) => error.reason,
    'reason',
    reason,
  ),
);

void main() {
  group('lookup queries', () {
    test('saleId and folio build the exact single-key requests', () {
      expect(SaleLookupQuery.bySaleId(saleKey).toRequest(), <String, Object?>{
        'saleId': saleKey,
      });
      expect(
        SaleLookupQuery.byFolio('  nte-3f2a-9c1b ').toRequest(),
        <String, Object?>{'folio': 'NTE-3F2A-9C1B'},
      );
    });

    test('invalid sale ids and folios are refused locally', () {
      expect(
        () => SaleLookupQuery.bySaleId('../sales'),
        _invalid(CorrectionValidationReason.invalidSaleId),
      );
      for (final String folio in <String>[
        '',
        'NTE-3F2A',
        'N-3F2A-9C1B',
        'NTE-3F2A-9C1B-X',
        '${' ' * 30}NTE-3F2A-9C1B',
      ]) {
        expect(
          () => SaleLookupQuery.byFolio(folio),
          _invalid(CorrectionValidationReason.invalidFolio),
          reason: folio,
        );
      }
    });

    test('recent query sends {} by default or an exact bounded limit', () {
      expect(RecentSalesQuery().toRequest(), <String, Object?>{});
      expect(RecentSalesQuery(limit: 100).toRequest(), <String, Object?>{
        'limit': 100,
      });
      for (final int limit in <int>[0, 101, -1]) {
        expect(
          () => RecentSalesQuery(limit: limit),
          _invalid(CorrectionValidationReason.invalidLimit),
        );
      }
    });
  });

  group('CorrectableSale.fromLookup', () {
    test('parses lines, quantities, payment, folio and window', () {
      final CorrectableSale sale = lookupSale();
      expect(sale.saleId, saleKey);
      expect(sale.folio, 'NTE-3F2A-9C1B');
      expect(
        sale.createdAt,
        DateTime.fromMillisecondsSinceEpoch(saleCreatedAtMillis, isUtc: true),
      );
      expect(
        sale.correctionWindowEndsAt.difference(sale.createdAt),
        const Duration(days: 15),
      );
      expect(sale.paymentMethod, SalePaymentMethod.card);
      expect(sale.amountCentavos, 3650);
      expect(sale.invoiced, isTrue);
      expect(sale.totalCentavos, 3650);
      expect(sale.hasReturnableQuantity, isTrue);
      final CorrectableSaleLine ribbon = sale.lines[0];
      expect(ribbon.productId, 'DEMO-RIBBON');
      expect(ribbon.quantitySpec.unit, 'meter');
      expect(ribbon.soldScaled, 250);
      expect(ribbon.returnedScaled, 50);
      expect(ribbon.remainingScaled, 200);
      expect(ribbon.soldDecimal, '2.50');
      expect(ribbon.returnedDecimal, '0.50');
      expect(ribbon.remainingDecimal, '2.00');
      expect(ribbon.totalCentavos, 2900);
      expect(sale.lines[1].remainingDecimal, '3');
    });

    test('accepts a legacy sale without folio for a saleId lookup', () {
      final CorrectableSale sale = CorrectableSale.fromLookup(<String, Object?>{
        'sale': lookupSaleJson(folio: null),
      }, query: SaleLookupQuery.bySaleId(saleKey));
      expect(sale.folio, isNull);
    });

    test('binds the result to the folio that was searched', () {
      expect(
        CorrectableSale.fromLookup(
          findResponse(),
          query: SaleLookupQuery.byFolio('nte-3f2a-9c1b'),
        ).saleId,
        saleKey,
      );
      expect(
        () => CorrectableSale.fromLookup(
          findResponse(),
          query: SaleLookupQuery.byFolio('NTE-AAAA-BBBB'),
        ),
        _protocol(),
      );
      expect(
        () => CorrectableSale.fromLookup(<String, Object?>{
          'sale': lookupSaleJson(folio: null),
        }, query: SaleLookupQuery.byFolio('NTE-3F2A-9C1B')),
        _protocol(),
      );
    });

    test('fails closed on every tampered or unexpected field', () {
      final List<void Function(Map<String, Object?>)> mutations =
          <void Function(Map<String, Object?>)>[
            (Map<String, Object?> sale) => sale['saleId'] = otherSaleId,
            (Map<String, Object?> sale) => sale['folio'] = 'NTE-AAAA-9C1B',
            (Map<String, Object?> sale) => sale['folio'] = 7,
            (Map<String, Object?> sale) => sale['createdAt'] = -1,
            (Map<String, Object?> sale) => sale['createdAt'] = '1',
            (Map<String, Object?> sale) => sale['branchId'] = 'branch-north',
            (Map<String, Object?> sale) => sale.remove('lines'),
            (Map<String, Object?> sale) => _receipt(sale)['cost'] = 1,
            (Map<String, Object?> sale) =>
                _receipt(sale)['invoiceRequested'] = false,
            (Map<String, Object?> sale) =>
                _receipt(sale)['productIds'] = <Object?>['DEMO-RIBBON'],
            (Map<String, Object?> sale) => _payment(sale)['method'] = 'cheque',
            (Map<String, Object?> sale) =>
                _payment(sale)['amountCentavos'] = 3651,
            (Map<String, Object?> sale) =>
                _calculation(sale)['totalCentavos'] = 3651,
            (Map<String, Object?> sale) =>
                _calcLine(sale, 0)['totalCentavos'] = 2901,
            (Map<String, Object?> sale) =>
                _calcQuantity(sale, 0)['decimal'] = '2.5',
            (Map<String, Object?> sale) => _calcQuantity(sale, 0)['scaled'] = 0,
            (Map<String, Object?> sale) =>
                _calcLine(sale, 0)['acquisitionCostCentavos'] = 1,
            (Map<String, Object?> sale) => _line(sale, 0)['lineIndex'] = 1,
            (Map<String, Object?> sale) => _line(sale, 0)['soldScaled'] = 251,
            (Map<String, Object?> sale) =>
                _line(sale, 0)['returnedScaled'] = 300,
            (Map<String, Object?> sale) =>
                _line(sale, 0)['remainingScaled'] = 199,
            (Map<String, Object?> sale) => _line(sale, 1)['extra'] = true,
            (Map<String, Object?> sale) =>
                (sale['lines']! as List<Object?>).removeLast(),
          ];
      for (int index = 0; index < mutations.length; index++) {
        final Map<String, Object?> sale = lookupSaleJson();
        mutations[index](sale);
        expect(
          () => CorrectableSale.fromLookup(<String, Object?>{
            'sale': sale,
          }, query: SaleLookupQuery.bySaleId(saleKey)),
          _protocol(),
          reason: 'mutation $index',
        );
      }
      expect(
        () => CorrectableSale.fromLookup(<String, Object?>{
          'sale': lookupSaleJson(),
          'replayed': false,
        }, query: SaleLookupQuery.bySaleId(saleKey)),
        _protocol(),
      );
      expect(
        () => CorrectableSale.fromLookup(
          null,
          query: SaleLookupQuery.bySaleId(saleKey),
        ),
        _protocol(),
      );
    });
  });

  group('RecentCorrectableSales.fromCallable', () {
    test('parses newest-first sales within the limit', () {
      final RecentCorrectableSales recent = RecentCorrectableSales.fromCallable(
        <String, Object?>{
          'sales': <Object?>[
            lookupSaleJson(),
            lookupSaleJson(
              saleId: otherSaleId,
              folio: 'NTE-4B5C-6D7E',
              createdAt: saleCreatedAtMillis - 1000,
              ribbonReturned: 250,
            ),
          ],
        },
        query: RecentSalesQuery(limit: 2),
      );
      expect(recent.sales.map((CorrectableSale sale) => sale.saleId), <String>[
        saleKey,
        otherSaleId,
      ]);
      expect(recent.sales[1].lines[0].remainingScaled, 0);
      expect(
        RecentCorrectableSales.fromCallable(<String, Object?>{
          'sales': <Object?>[],
        }, query: RecentSalesQuery()).sales,
        isEmpty,
      );
    });

    test('rejects over-limit, unordered, duplicate or malformed lists', () {
      final Map<String, Object?> older = lookupSaleJson(
        saleId: otherSaleId,
        folio: 'NTE-4B5C-6D7E',
        createdAt: saleCreatedAtMillis - 1000,
      );
      final List<Object?> cases = <Object?>[
        <String, Object?>{
          'sales': <Object?>[lookupSaleJson(), older],
        },
        <String, Object?>{
          'sales': <Object?>[older, lookupSaleJson()],
        },
        <String, Object?>{
          'sales': <Object?>[lookupSaleJson(), lookupSaleJson()],
        },
        <String, Object?>{
          'sales': <Object?>[
            <String, Object?>{...lookupSaleJson(), 'extra': 1},
          ],
        },
        <String, Object?>{'sales': 'none'},
        <String, Object?>{'sales': <Object?>[], 'next': null},
      ];
      final List<RecentSalesQuery> queries = <RecentSalesQuery>[
        RecentSalesQuery(limit: 1),
        RecentSalesQuery(),
        RecentSalesQuery(),
        RecentSalesQuery(),
        RecentSalesQuery(),
        RecentSalesQuery(),
      ];
      for (int index = 0; index < cases.length; index++) {
        expect(
          () => RecentCorrectableSales.fromCallable(
            cases[index],
            query: queries[index],
          ),
          _protocol(),
          reason: 'case $index',
        );
      }
    });
  });
}

Map<String, Object?> _receipt(Map<String, Object?> sale) =>
    sale['receipt']! as Map<String, Object?>;
Map<String, Object?> _payment(Map<String, Object?> sale) =>
    _receipt(sale)['payment']! as Map<String, Object?>;
Map<String, Object?> _calculation(Map<String, Object?> sale) =>
    _receipt(sale)['calculation']! as Map<String, Object?>;
Map<String, Object?> _calcLine(Map<String, Object?> sale, int index) =>
    (_calculation(sale)['lines']! as List<Object?>)[index]!
        as Map<String, Object?>;
Map<String, Object?> _calcQuantity(Map<String, Object?> sale, int index) =>
    _calcLine(sale, index)['quantity']! as Map<String, Object?>;
Map<String, Object?> _line(Map<String, Object?> sale, int index) =>
    (sale['lines']! as List<Object?>)[index]! as Map<String, Object?>;
