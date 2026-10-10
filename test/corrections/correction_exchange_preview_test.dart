import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

Matcher _invalid(CorrectionValidationReason reason) => throwsA(
  isA<CorrectionValidationException>().having(
    (CorrectionValidationException error) => error.reason,
    'reason',
    reason,
  ),
);

const ReturnLineInput _pin = ReturnLineInput(
  lineIndex: 1,
  quantity: '1',
  condition: ReturnCondition.good,
);

SaleExchangePreview _parse(Object? value) =>
    SaleExchangePreview.fromCallable(value, request: exchangePreviewRequest());

/// A deep, mutable copy of the default preview.
Map<String, Object?> _preview() => _copy(exchangePreviewJson())!;

Map<String, Object?>? _copy(Object? value) =>
    (_deep(value) as Map<Object?, Object?>?)?.cast<String, Object?>();

Object? _deep(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final MapEntry<Object?, Object?> entry in map.entries)
      entry.key! as String: _deep(entry.value),
  },
  final List<Object?> list => <Object?>[for (final Object? e in list) _deep(e)],
  _ => value,
};

Map<String, Object?> _at(Map<String, Object?> map, String key) =>
    map[key]! as Map<String, Object?>;

void main() {
  group('SaleExchangePreviewRequest', () {
    test('sends exactly saleId, reason, returnLines and newLines', () {
      expect(exchangePreviewRequest().toRequest(), <String, Object?>{
        'saleId': saleKey,
        'reason': 'wrong-product',
        'returnLines': <Object?>[
          <String, Object?>{
            'lineIndex': 1,
            'quantity': '1',
            'condition': 'good',
          },
        ],
        'newLines': <Object?>[
          <String, Object?>{'productId': 'DEMO-TAPE', 'quantity': '2'},
        ],
      });
      // New items always keep the sale's invoice intent.
      expect(exchangePreviewRequest().newItems.invoiceRequested, isTrue);
    });

    test('validates like the exchange draft', () {
      SaleExchangePreviewRequest create({
        List<ReturnLineInput> lines = const <ReturnLineInput>[_pin],
        SaleCart? newItems,
      }) => SaleExchangePreviewRequest.create(
        sale: lookupSale(),
        reason: CorrectionReason.other,
        returnLines: lines,
        newItems: newItems ?? SaleCart.empty().add(tapeLine),
      );

      expect(
        () => create(newItems: SaleCart.empty()),
        _invalid(CorrectionValidationReason.noNewItems),
      );
      expect(
        () => create(
          newItems: SaleCart.empty().add(
            SaleCartLine(
              productId: 'DEMO-PIN',
              name: 'Pin',
              quantitySpec: pinLine.quantitySpec,
              quantity: '1',
            ),
          ),
        ),
        _invalid(CorrectionValidationReason.newItemIsReturned),
      );
      expect(
        () => create(
          lines: const <ReturnLineInput>[
            ReturnLineInput(
              lineIndex: 1,
              quantity: '4',
              condition: ReturnCondition.good,
            ),
          ],
        ),
        _invalid(CorrectionValidationReason.exceedsRemaining),
      );
      expect(
        () => create(lines: const <ReturnLineInput>[]),
        _invalid(CorrectionValidationReason.noLines),
      );
    });

    test('a draft matches only the preview of its exact exchange', () {
      expect(exchangeDraft().previewRequest, exchangePreviewRequest());
      expect(
        exchangeDraft(payment: null).previewRequest,
        exchangePreviewRequest(),
      );
      final SaleExchangePreviewRequest more = SaleExchangePreviewRequest.create(
        sale: lookupSale(),
        reason: CorrectionReason.wrongProduct,
        returnLines: const <ReturnLineInput>[_pin],
        newItems: SaleCart.empty().add(tapeLine.withQuantity('3')),
      );
      expect(exchangeDraft().previewRequest, isNot(more));
      final SaleExchangePreviewRequest otherReason =
          SaleExchangePreviewRequest.create(
            sale: lookupSale(),
            reason: CorrectionReason.other,
            returnLines: const <ReturnLineInput>[_pin],
            newItems: SaleCart.empty().add(tapeLine),
          );
      expect(exchangeDraft().previewRequest, isNot(otherReason));
    });
  });

  group('SaleExchangePreview.fromCallable', () {
    test('parses the returned value, new items and settlement', () {
      final SaleExchangePreview preview = _parse(exchangePreviewJson());
      expect(preview.request, exchangePreviewRequest());
      expect(preview.returnedLines.single.productId, 'DEMO-PIN');
      expect(preview.returnedLines.single.condition, ReturnCondition.good);
      expect(preview.returnedTotalCentavos, 250);
      expect(preview.newItems.totalCentavos, 2320);
      expect(preview.newItems.additionalIvaCentavos, 320);
      expect(preview.customerPaysCentavos, 2070);
      expect(preview.refundCentavos, 0);
      expect(preview.refundMethod, SalePaymentMethod.card);
      expect(preview.invoiced, isTrue);
      expect(preview.allAvailable, isTrue);
    });

    test('reports new lines the branch stock cannot cover', () {
      final SaleExchangePreview preview = _parse(
        exchangePreviewJson(tapeAvailable: false),
      );
      expect(preview.allAvailable, isFalse);
      expect(preview.unavailableProductIds, <String>{'DEMO-TAPE'});
    });

    test('parses a refund settlement', () {
      final Map<String, Object?> json = _preview();
      // Returning more than the new items cost: a refund by card.
      _at(json, 'settlement')
        ..['returnedCentavos'] = 250
        ..['newItemCentavos'] = 250
        ..['customerPaysCentavos'] = 0;
      final Map<String, Object?> calculation = _at(
        _at(json, 'newItems'),
        'calculation',
      );
      final Map<String, Object?> line =
          (calculation['lines']! as List<Object?>).single!
              as Map<String, Object?>;
      line
        ..['baseCentavos'] = 200
        ..['additionalIvaCentavos'] = 50
        ..['totalCentavos'] = 250;
      calculation
        ..['baseCentavos'] = 200
        ..['additionalIvaCentavos'] = 50
        ..['totalCentavos'] = 250;
      expect(_parse(json).customerPaysCentavos, 0);
      expect(_parse(json).refundCentavos, 0);

      line
        ..['baseCentavos'] = 100
        ..['additionalIvaCentavos'] = 16
        ..['totalCentavos'] = 116;
      calculation
        ..['baseCentavos'] = 100
        ..['additionalIvaCentavos'] = 16
        ..['totalCentavos'] = 116;
      _at(json, 'settlement')
        ..['newItemCentavos'] = 116
        ..['refundCentavos'] = 134;
      final SaleExchangePreview refund = _parse(json);
      expect(refund.refundCentavos, 134);
      expect(refund.customerPaysCentavos, 0);
      expect(refund.refundMethod, SalePaymentMethod.card);
    });

    test('refuses any response not bound to the request', () {
      final List<(String, void Function(Map<String, Object?>))>
      mutations = <(String, void Function(Map<String, Object?>))>[
        ('extra key', (Map<String, Object?> json) => json['note'] = null),
        ('missing key', (Map<String, Object?> json) => json.remove('newLines')),
        ('sale', (Map<String, Object?> json) => json['saleId'] = otherSaleId),
        ('invoiced', (Map<String, Object?> json) => json['invoiced'] = false),
        (
          'difference payment',
          (Map<String, Object?> json) =>
              _at(json, 'settlement')['differencePayment'] = null,
        ),
        (
          'customer pays',
          (Map<String, Object?> json) =>
              _at(json, 'settlement')['customerPaysCentavos'] = 2069,
        ),
        (
          'refund',
          (Map<String, Object?> json) =>
              _at(json, 'settlement')['refundCentavos'] = 1,
        ),
        (
          'refund method',
          (Map<String, Object?> json) =>
              _at(json, 'settlement')['refundMethod'] = 'cash',
        ),
        (
          'returned centavos',
          (Map<String, Object?> json) =>
              _at(json, 'settlement')['returnedCentavos'] = 251,
        ),
        (
          'returned total',
          (Map<String, Object?> json) =>
              _at(json, 'returned')['totalCentavos'] = 251,
        ),
        (
          'returned line',
          (Map<String, Object?> json) =>
              ((_at(json, 'returned')['lines']! as List<Object?>).single!
                      as Map<String, Object?>)['condition'] =
                  'factory-defect',
        ),
        (
          'product ids',
          (Map<String, Object?> json) =>
              _at(json, 'newItems')['productIds'] = <Object?>['DEMO-RIBBON'],
        ),
        (
          'calculation',
          (Map<String, Object?> json) =>
              _at(_at(json, 'newItems'), 'calculation')['invoiceRequested'] =
                  false,
        ),
        (
          'new line count',
          (Map<String, Object?> json) => json['newLines'] = <Object?>[],
        ),
        (
          'new line product',
          (Map<String, Object?> json) => json['newLines'] = <Object?>[
            <String, Object?>{'productId': 'DEMO-RIBBON', 'available': true},
          ],
        ),
        (
          'new line available',
          (Map<String, Object?> json) => json['newLines'] = <Object?>[
            <String, Object?>{'productId': 'DEMO-TAPE', 'available': 'yes'},
          ],
        ),
        (
          'new line extra key',
          (Map<String, Object?> json) => json['newLines'] = <Object?>[
            <String, Object?>{
              'productId': 'DEMO-TAPE',
              'available': true,
              'stock': 1,
            },
          ],
        ),
      ];
      expect(() => _parse(_preview()), returnsNormally);
      for (final (String name, void Function(Map<String, Object?>) mutate)
          in mutations) {
        final Map<String, Object?> json = _preview();
        mutate(json);
        expect(
          () => _parse(json),
          throwsA(isA<CorrectionProtocolException>()),
          reason: name,
        );
      }
      expect(
        () => _parse(exchangeResponse()),
        throwsA(isA<CorrectionProtocolException>()),
      );
      expect(() => _parse(null), throwsA(isA<CorrectionProtocolException>()));
    });
  });
}
