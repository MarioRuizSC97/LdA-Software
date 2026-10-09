import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

Matcher _protocol() => throwsA(isA<CorrectionProtocolException>());

typedef _Mutation = void Function(Map<String, Object?> receipt);

void _expectAllRejected(
  List<_Mutation> mutations,
  Map<String, Object?> Function() receipt,
  void Function(Object? response) parse,
) {
  for (int index = 0; index < mutations.length; index++) {
    final Map<String, Object?> value = receipt();
    mutations[index](value);
    expect(
      () => parse(<String, Object?>{'receipt': value, 'replayed': false}),
      _protocol(),
      reason: 'mutation $index',
    );
  }
}

Map<String, Object?> _at(Object? list, int index) =>
    (list! as List<Object?>)[index]! as Map<String, Object?>;

void main() {
  group('SaleReturnReceipt', () {
    test('parses the refund bound to the draft', () {
      final SaleReturnReceipt receipt = SaleReturnReceipt.fromCallable(
        returnResponse(replayed: true),
        draft: returnDraft(),
      );
      expect(receipt.returnId, returnKey);
      expect(receipt.saleId, saleKey);
      expect(receipt.reason, CorrectionReason.changeOfMind);
      expect(receipt.replayed, isTrue);
      expect(receipt.invoiced, isTrue);
      expect(receipt.refundMethod, SalePaymentMethod.card);
      expect(receipt.baseCentavos, 1250);
      expect(receipt.additionalIvaCentavos, 160);
      expect(receipt.totalCentavos, 1410);
      expect(receipt.lines.first.quantityDecimal, '1.00');
      expect(receipt.lines.first.condition, ReturnCondition.good);
      expect(receipt.lines.last.condition, ReturnCondition.factoryDefect);
      expect(receipt.lines.last.totalCentavos, 250);
    });

    test('fails closed on any mismatch with the draft or sale', () {
      _expectAllRejected(
        <_Mutation>[
          (Map<String, Object?> r) => r['version'] = 2,
          (Map<String, Object?> r) => r['returnId'] = replacementKey,
          (Map<String, Object?> r) => r['saleId'] = otherSaleId,
          (Map<String, Object?> r) => r['branchId'] = 'branch-south',
          (Map<String, Object?> r) => r['reason'] = 'other',
          (Map<String, Object?> r) => r['invoiced'] = false,
          (Map<String, Object?> r) => r['note'] = 'leaked',
          (Map<String, Object?> r) =>
              (r['lines']! as List<Object?>).removeAt(1),
          (Map<String, Object?> r) => _at(r['lines'], 0)['lineIndex'] = 1,
          (Map<String, Object?> r) =>
              _at(r['lines'], 0)['productId'] = 'DEMO-PIN',
          (Map<String, Object?> r) => _at(r['lines'], 0)['quantity'] = '1.50',
          (Map<String, Object?> r) => _at(r['lines'], 0)['quantity'] = '1.0001',
          (Map<String, Object?> r) =>
              _at(r['lines'], 0)['condition'] = 'factory-defect',
          (Map<String, Object?> r) =>
              _at(r['lines'], 0)['totalCentavos'] = 1161,
          (Map<String, Object?> r) {
            _at(r['lines'], 0)['baseCentavos'] = 3000;
            _at(r['lines'], 0)['totalCentavos'] = 3160;
          },
          (Map<String, Object?> r) {
            // Sums stay consistent, but the pin line exceeds its sold 750.
            _at(r['lines'], 1)
              ..['baseCentavos'] = 800
              ..['totalCentavos'] = 800;
            (r['refund']! as Map<String, Object?>)
              ..['baseCentavos'] = 1800
              ..['totalCentavos'] = 1960;
          },
          (Map<String, Object?> r) =>
              _at(r['lines'], 1)['acquisitionCostCentavos'] = 1,
          (Map<String, Object?> r) =>
              (r['refund']! as Map<String, Object?>)['method'] = 'cash',
          (Map<String, Object?> r) =>
              (r['refund']! as Map<String, Object?>)['totalCentavos'] = 1411,
          (Map<String, Object?> r) =>
              (r['refund']! as Map<String, Object?>)['baseCentavos'] = 1251,
        ],
        returnReceiptJson,
        (Object? response) =>
            SaleReturnReceipt.fromCallable(response, draft: returnDraft()),
      );
      expect(
        () => SaleReturnReceipt.fromCallable(<String, Object?>{
          'receipt': returnReceiptJson(),
          'replayed': 'no',
        }, draft: returnDraft()),
        _protocol(),
      );
      expect(
        () => SaleReturnReceipt.fromCallable(<String, Object?>{
          'receipt': returnReceiptJson(),
          'replayed': false,
          'createdAt': 1,
        }, draft: returnDraft()),
        _protocol(),
      );
    });
  });

  group('SaleReplacementReceipt', () {
    test('parses a no-charge replacement bound to the draft', () {
      final SaleReplacementReceipt receipt =
          SaleReplacementReceipt.fromCallable(
            replacementResponse(),
            draft: replacementDraft(),
          );
      expect(receipt.replacementId, replacementKey);
      expect(receipt.replayed, isFalse);
      expect(receipt.lines.single.productId, 'DEMO-PIN');
      expect(receipt.lines.single.quantityDecimal, '2');
      expect(receipt.lines.single.quantityScaled, 2);
    });

    test('fails closed on any mismatch', () {
      _expectAllRejected(
        <_Mutation>[
          (Map<String, Object?> r) => r['chargeCentavos'] = 1,
          (Map<String, Object?> r) => r['reason'] = 'other',
          (Map<String, Object?> r) => r['replacementId'] = returnKey,
          (Map<String, Object?> r) => r['branchId'] = 'branch-south',
          (Map<String, Object?> r) => _at(r['lines'], 0)['quantity'] = '3',
          (Map<String, Object?> r) =>
              _at(r['lines'], 0)['productId'] = 'DEMO-RIBBON',
          (Map<String, Object?> r) => r.remove('lines'),
        ],
        replacementReceiptJson,
        (Object? response) => SaleReplacementReceipt.fromCallable(
          response,
          draft: replacementDraft(),
        ),
      );
    });
  });

  group('SaleExchangeReceipt', () {
    test('parses returned value, new items and settlement', () {
      final SaleExchangeReceipt receipt = SaleExchangeReceipt.fromCallable(
        exchangeResponse(),
        draft: exchangeDraft(),
      );
      expect(receipt.exchangeId, exchangeKey);
      expect(receipt.reason, CorrectionReason.wrongProduct);
      expect(receipt.returnedLines.single.productId, 'DEMO-PIN');
      expect(receipt.returnedTotalCentavos, 250);
      expect(receipt.newItems.totalCentavos, 2320);
      expect(receipt.newItems.lines.single.productId, 'DEMO-TAPE');
      expect(receipt.settlement.returnedCentavos, 250);
      expect(receipt.settlement.newItemCentavos, 2320);
      expect(receipt.settlement.customerPaysCentavos, 2070);
      expect(receipt.settlement.refundCentavos, 0);
      expect(receipt.settlement.refundMethod, SalePaymentMethod.card);
      expect(
        receipt.settlement.differencePayment?.method,
        SalePaymentMethod.cash,
      );
      expect(receipt.invoiced, isTrue);
    });

    test('accepts a refund settlement without difference payment', () {
      final SaleExchangeDraft draft = SaleExchangeDraft.create(
        sale: lookupSale(),
        branchId: saleBranchId,
        reason: CorrectionReason.wrongProduct,
        returnLines: const <ReturnLineInput>[
          ReturnLineInput(
            lineIndex: 0,
            quantity: '2',
            condition: ReturnCondition.good,
          ),
        ],
        newItems: SaleCart.empty().add(tapeLine.withQuantity('1')),
        createKey: () => exchangeKey,
      );
      final Map<String, Object?> calculation = tapeCalculation();
      final Map<String, Object?> line = _at(calculation['lines'], 0);
      (line['quantity']! as Map<String, Object?>)
        ..['scaled'] = 1
        ..['decimal'] = '1';
      line
        ..['baseCentavos'] = 1000
        ..['additionalIvaCentavos'] = 160
        ..['totalCentavos'] = 1160;
      calculation
        ..['baseCentavos'] = 1000
        ..['additionalIvaCentavos'] = 160
        ..['totalCentavos'] = 1160;
      final Map<String, Object?> receipt = exchangeReceiptJson()
        ..['returned'] = <String, Object?>{
          'lines': <Object?>[
            <String, Object?>{
              'lineIndex': 0,
              'productId': 'DEMO-RIBBON',
              'quantity': '2.00',
              'condition': 'good',
              'baseCentavos': 2000,
              'additionalIvaCentavos': 320,
              'totalCentavos': 2320,
            },
          ],
          'baseCentavos': 2000,
          'additionalIvaCentavos': 320,
          'totalCentavos': 2320,
        }
        ..['newItems'] = <String, Object?>{
          'productIds': <Object?>['DEMO-TAPE'],
          'calculation': calculation,
        }
        ..['settlement'] = <String, Object?>{
          'returnedCentavos': 2320,
          'newItemCentavos': 1160,
          'customerPaysCentavos': 0,
          'refundCentavos': 1160,
          'refundMethod': 'card',
          'differencePayment': null,
        };
      final SaleExchangeReceipt parsed = SaleExchangeReceipt.fromCallable(
        <String, Object?>{'receipt': receipt, 'replayed': false},
        draft: draft,
      );
      expect(parsed.settlement.refundCentavos, 1160);
      expect(parsed.settlement.differencePayment, isNull);
    });

    test('fails closed on any mismatch', () {
      Map<String, Object?> settlement(Map<String, Object?> r) =>
          r['settlement']! as Map<String, Object?>;
      _expectAllRejected(
        <_Mutation>[
          (Map<String, Object?> r) => r['exchangeId'] = returnKey,
          (Map<String, Object?> r) => r['reason'] = 'other',
          (Map<String, Object?> r) => r['invoiced'] = false,
          (Map<String, Object?> r) =>
              (r['returned']! as Map<String, Object?>)['totalCentavos'] = 251,
          (Map<String, Object?> r) => _at(
            (r['returned']! as Map<String, Object?>)['lines'],
            0,
          )['condition'] = 'factory-defect',
          (Map<String, Object?> r) =>
              (r['newItems']! as Map<String, Object?>)['productIds'] =
                  <Object?>['DEMO-PIN'],
          (Map<String, Object?> r) =>
              ((r['newItems']! as Map<String, Object?>)['calculation']!
                      as Map<String, Object?>)['invoiceRequested'] =
                  false,
          (Map<String, Object?> r) => settlement(r)['returnedCentavos'] = 0,
          (Map<String, Object?> r) => settlement(r)['newItemCentavos'] = 2321,
          (Map<String, Object?> r) =>
              settlement(r)['customerPaysCentavos'] = 2069,
          (Map<String, Object?> r) => settlement(r)['refundCentavos'] = 1,
          (Map<String, Object?> r) => settlement(r)['refundMethod'] = 'cash',
          (Map<String, Object?> r) => settlement(r)['differencePayment'] = null,
          (Map<String, Object?> r) =>
              (settlement(r)['differencePayment']!
                      as Map<String, Object?>)['method'] =
                  'card',
          (Map<String, Object?> r) => settlement(r)['extra'] = 0,
        ],
        exchangeReceiptJson,
        (Object? response) =>
            SaleExchangeReceipt.fromCallable(response, draft: exchangeDraft()),
      );
    });
  });
}
