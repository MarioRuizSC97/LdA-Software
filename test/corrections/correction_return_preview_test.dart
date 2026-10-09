import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

Map<String, Object?> _copy(Map<String, Object?> value) =>
    Map<String, Object?>.of(value);

List<Object?> _lines() => <Object?>[
  for (final Object? line in returnPreviewJson()['lines']! as List<Object?>)
    Map<String, Object?>.of(line! as Map<String, Object?>),
];

void _forged(String name, Object? value) {
  expect(
    () =>
        SaleReturnPreview.fromCallable(value, request: returnPreviewRequest()),
    throwsA(isA<CorrectionProtocolException>()),
    reason: name,
  );
}

void main() {
  group('SaleReturnPreviewRequest', () {
    test('sends exactly saleId, reason and lines, no key or note', () {
      expect(returnPreviewRequest().toRequest(), <String, Object?>{
        'saleId': saleKey,
        'reason': 'change-of-mind',
        'lines': <Object?>[
          <String, Object?>{
            'lineIndex': 0,
            'quantity': '1',
            'condition': 'good',
          },
          <String, Object?>{
            'lineIndex': 1,
            'quantity': '1',
            'condition': 'factory-defect',
          },
        ],
      });
    });

    test('validates lines like the return draft', () {
      for (final (String quantity, CorrectionValidationReason reason)
          in <(String, CorrectionValidationReason)>[
            ('2.01', CorrectionValidationReason.exceedsRemaining),
            ('0.001', CorrectionValidationReason.tooPrecise),
            ('0', CorrectionValidationReason.notPositive),
            ('abc', CorrectionValidationReason.malformedQuantity),
          ]) {
        expect(
          () => returnPreviewRequest(
            lines: <ReturnLineInput>[
              ReturnLineInput(
                lineIndex: 0,
                quantity: quantity,
                condition: ReturnCondition.good,
              ),
            ],
          ),
          throwsA(
            isA<CorrectionValidationException>().having(
              (CorrectionValidationException error) => error.reason,
              'reason',
              reason,
            ),
          ),
          reason: quantity,
        );
      }
      expect(
        () => returnPreviewRequest(lines: const <ReturnLineInput>[]),
        throwsA(isA<CorrectionValidationException>()),
      );
    });

    test('a draft matches only the preview of its exact lines and reason', () {
      expect(returnDraft().previewRequest, returnPreviewRequest());
      expect(
        returnDraft(note: null).previewRequest,
        returnPreviewRequest(),
        reason: 'the note is not previewed',
      );
      expect(
        returnDraft().previewRequest,
        isNot(returnPreviewRequest(reason: CorrectionReason.other)),
      );
      expect(
        returnDraft().previewRequest,
        isNot(
          returnPreviewRequest(
            lines: const <ReturnLineInput>[
              ReturnLineInput(
                lineIndex: 0,
                quantity: '1',
                condition: ReturnCondition.factoryDefect,
              ),
              ReturnLineInput(
                lineIndex: 1,
                quantity: '1',
                condition: ReturnCondition.factoryDefect,
              ),
            ],
          ),
        ),
      );
    });
  });

  group('SaleReturnPreview.fromCallable', () {
    test('parses the refund per line, the total and the method', () {
      final SaleReturnPreview preview = SaleReturnPreview.fromCallable(
        returnPreviewJson(),
        request: returnPreviewRequest(),
      );
      expect(preview.request, returnPreviewRequest());
      expect(preview.refundMethod, SalePaymentMethod.card);
      expect(preview.invoiced, isTrue);
      expect(preview.baseCentavos, 1250);
      expect(preview.additionalIvaCentavos, 160);
      expect(preview.totalCentavos, 1410);
      expect(
        preview.lines.map((CorrectionRefundLine line) => line.lineIndex),
        <int>[0, 1],
      );
      expect(preview.lines.first.quantityDecimal, '1.00');
      expect(preview.lines.first.totalCentavos, 1160);
      expect(preview.lines.last.condition, ReturnCondition.factoryDefect);
    });

    test('refuses any response not bound to the request', () {
      _forged('null', null);
      _forged('extra key', _copy(returnPreviewJson())..['returnId'] = 'x');
      _forged('missing key', _copy(returnPreviewJson())..remove('invoiced'));
      _forged(
        'other sale',
        _copy(returnPreviewJson())..['saleId'] = otherSaleId,
      );
      _forged('invoice flag', _copy(returnPreviewJson())..['invoiced'] = false);
      _forged(
        'line count',
        _copy(returnPreviewJson())..['lines'] = _lines().sublist(0, 1),
      );
      final List<Object?> condition = _lines();
      (condition[0]! as Map<String, Object?>)['condition'] = 'factory-defect';
      _forged('condition', _copy(returnPreviewJson())..['lines'] = condition);
      final List<Object?> quantity = _lines();
      (quantity[0]! as Map<String, Object?>)['quantity'] = '1.0';
      _forged('quantity', _copy(returnPreviewJson())..['lines'] = quantity);
      final List<Object?> product = _lines();
      (product[1]! as Map<String, Object?>)['productId'] = 'DEMO-RIBBON';
      _forged('product', _copy(returnPreviewJson())..['lines'] = product);
      final List<Object?> amount = _lines();
      (amount[0]! as Map<String, Object?>)['totalCentavos'] = 1161;
      _forged('line sum', _copy(returnPreviewJson())..['lines'] = amount);
      _forged(
        'refund method',
        _copy(returnPreviewJson())
          ..['refund'] = <String, Object?>{
            'method': 'cash',
            'baseCentavos': 1250,
            'additionalIvaCentavos': 160,
            'totalCentavos': 1410,
          },
      );
      _forged(
        'refund sums',
        _copy(returnPreviewJson())
          ..['refund'] = <String, Object?>{
            'method': 'card',
            'baseCentavos': 1250,
            'additionalIvaCentavos': 161,
            'totalCentavos': 1411,
          },
      );
    });
  });
}
