import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
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

SaleReturnDraft _return({
  List<ReturnLineInput> lines = const <ReturnLineInput>[
    ReturnLineInput(
      lineIndex: 0,
      quantity: '1',
      condition: ReturnCondition.good,
    ),
  ],
  String? note,
  String branchId = saleBranchId,
  String Function()? createKey,
}) => SaleReturnDraft.create(
  sale: lookupSale(),
  branchId: branchId,
  reason: CorrectionReason.other,
  note: note,
  lines: lines,
  createKey: createKey ?? () => returnKey,
);

void main() {
  test('reasons and conditions expose exactly the server wire values', () {
    expect(
      CorrectionReason.values.map((CorrectionReason r) => r.wireValue),
      <String>['change-of-mind', 'wrong-product', 'factory-defect', 'other'],
    );
    expect(
      ReturnCondition.values.map((ReturnCondition c) => c.wireValue),
      <String>['good', 'factory-defect'],
    );
    expect(CorrectionReason.fromWire('other'), CorrectionReason.other);
    expect(CorrectionReason.fromWire('damaged'), isNull);
  });

  group('SaleReturnDraft', () {
    test('builds the exact request with a trimmed note', () {
      expect(
        returnDraft(note: '  Customer changed mind ').toRequest(),
        <String, Object?>{
          'idempotencyKey': returnKey,
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
          'note': 'Customer changed mind',
        },
      );
    });

    test('omits a missing or blank note', () {
      expect(returnDraft(note: null).toRequest().containsKey('note'), isFalse);
      expect(returnDraft(note: '   ').toRequest().containsKey('note'), isFalse);
      expect(
        () => _return(note: 'x' * 501),
        _invalid(CorrectionValidationReason.noteTooLong),
      );
      expect(_return(note: 'x' * 500).note, hasLength(500));
    });

    test('generates the key once and keeps it for equal retries', () {
      int calls = 0;
      final SaleReturnDraft draft = _return(
        createKey: () {
          calls++;
          return returnKey;
        },
      );
      expect(calls, 1);
      expect(draft.idempotencyKey, returnKey);
      expect(draft.toRequest(), draft.toRequest());
      expect(calls, 1);
      expect(draft, _return());
      expect(draft.hashCode, _return().hashCode);
      expect(draft == _return(note: 'changed'), isFalse);
    });

    test('generated keys are lowercase UUID v4 and unique per draft', () {
      final SaleReturnDraft first = SaleReturnDraft.create(
        sale: lookupSale(),
        branchId: saleBranchId,
        reason: CorrectionReason.other,
        lines: const <ReturnLineInput>[
          ReturnLineInput(
            lineIndex: 1,
            quantity: '1',
            condition: ReturnCondition.good,
          ),
        ],
      );
      final SaleReturnDraft second = SaleReturnDraft.create(
        sale: lookupSale(),
        branchId: saleBranchId,
        reason: CorrectionReason.other,
        lines: const <ReturnLineInput>[
          ReturnLineInput(
            lineIndex: 1,
            quantity: '1',
            condition: ReturnCondition.good,
          ),
        ],
      );
      expect(
        first.idempotencyKey,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab]')),
      );
      expect(first.idempotencyKey, isNot(second.idempotencyKey));
    });

    test('validates quantities with BigInt at the line precision', () {
      expect(
        _return(
          lines: const <ReturnLineInput>[
            ReturnLineInput(
              lineIndex: 0,
              quantity: '0.25',
              condition: ReturnCondition.good,
            ),
          ],
        ).lines.single.quantityScaled,
        25,
      );
      final Map<String, CorrectionValidationReason> cases =
          <String, CorrectionValidationReason>{
            '0.125': CorrectionValidationReason.tooPrecise,
            '1e2': CorrectionValidationReason.malformedQuantity,
            '01': CorrectionValidationReason.malformedQuantity,
            '-1': CorrectionValidationReason.malformedQuantity,
            '0': CorrectionValidationReason.notPositive,
            '0.00': CorrectionValidationReason.notPositive,
            '2.01': CorrectionValidationReason.exceedsRemaining,
            '99999999999999999': CorrectionValidationReason.tooLarge,
          };
      cases.forEach((String quantity, CorrectionValidationReason reason) {
        expect(
          () => _return(
            lines: <ReturnLineInput>[
              ReturnLineInput(
                lineIndex: 0,
                quantity: quantity,
                condition: ReturnCondition.good,
              ),
            ],
          ),
          _invalid(reason),
          reason: quantity,
        );
      });
      expect(
        _return(
          lines: const <ReturnLineInput>[
            ReturnLineInput(
              lineIndex: 0,
              quantity: '2.00',
              condition: ReturnCondition.good,
            ),
          ],
        ).toRequest()['lines'],
        <Object?>[
          <String, Object?>{
            'lineIndex': 0,
            'quantity': '2.00',
            'condition': 'good',
          },
        ],
      );
    });

    test('rejects empty, unknown, duplicate lines and bad keys or branch', () {
      expect(
        () => _return(lines: const <ReturnLineInput>[]),
        _invalid(CorrectionValidationReason.noLines),
      );
      expect(
        () => _return(
          lines: const <ReturnLineInput>[
            ReturnLineInput(
              lineIndex: 2,
              quantity: '1',
              condition: ReturnCondition.good,
            ),
          ],
        ),
        _invalid(CorrectionValidationReason.unknownLine),
      );
      expect(
        () => _return(
          lines: const <ReturnLineInput>[
            ReturnLineInput(
              lineIndex: 1,
              quantity: '1',
              condition: ReturnCondition.good,
            ),
            ReturnLineInput(
              lineIndex: 1,
              quantity: '1',
              condition: ReturnCondition.factoryDefect,
            ),
          ],
        ),
        _invalid(CorrectionValidationReason.duplicateLine),
      );
      expect(
        () => _return(createKey: () => exchangeKey.toUpperCase()),
        _invalid(CorrectionValidationReason.invalidDraft),
      );
      expect(
        () => _return(branchId: ''),
        _invalid(CorrectionValidationReason.invalidDraft),
      );
    });
  });

  group('SaleReplacementDraft', () {
    test('builds the exact request without a reason', () {
      expect(replacementDraft().toRequest(), <String, Object?>{
        'idempotencyKey': replacementKey,
        'saleId': saleKey,
        'lines': <Object?>[
          <String, Object?>{'lineIndex': 1, 'quantity': '2'},
        ],
      });
    });

    test('caps each line at the remaining returnable quantity', () {
      expect(
        () => SaleReplacementDraft.create(
          sale: lookupSale(),
          branchId: saleBranchId,
          lines: const <ReplacementLineInput>[
            ReplacementLineInput(lineIndex: 0, quantity: '2.5'),
          ],
          note: 'Torn',
          createKey: () => replacementKey,
        ),
        _invalid(CorrectionValidationReason.exceedsRemaining),
      );
      expect(
        SaleReplacementDraft.create(
          sale: lookupSale(),
          branchId: saleBranchId,
          lines: const <ReplacementLineInput>[
            ReplacementLineInput(lineIndex: 0, quantity: '2'),
          ],
          note: 'Torn',
          createKey: () => replacementKey,
        ).toRequest()['note'],
        'Torn',
      );
    });
  });

  group('SaleExchangeDraft', () {
    test('builds the exact request with the difference payment', () {
      expect(exchangeDraft().toRequest(), <String, Object?>{
        'idempotencyKey': exchangeKey,
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
        'differencePayment': <String, Object?>{
          'method': 'cash',
          'amountCentavos': 2070,
        },
      });
      expect(
        exchangeDraft(payment: null)
            .toRequest()
            .containsKey('differencePayment'),
        isFalse,
      );
    });

    test('new items keep the original invoice intent', () {
      expect(exchangeDraft().newItems.invoiceRequested, isTrue);
    });

    test('refuses returned products, empty sides and bad payments', () {
      SaleExchangeDraft build({
        List<ReturnLineInput> returnLines = const <ReturnLineInput>[
          ReturnLineInput(
            lineIndex: 1,
            quantity: '1',
            condition: ReturnCondition.good,
          ),
        ],
        SaleCart? newItems,
        int amount = 2070,
      }) => SaleExchangeDraft.create(
        sale: lookupSale(),
        branchId: saleBranchId,
        reason: CorrectionReason.wrongProduct,
        returnLines: returnLines,
        newItems: newItems ?? SaleCart.empty().add(tapeLine),
        differencePayment: SaleExchangePayment(
          method: SalePaymentMethod.cash,
          amountCentavos: amount,
        ),
        createKey: () => exchangeKey,
      );

      expect(
        () => build(newItems: SaleCart.empty().add(pinLine)),
        _invalid(CorrectionValidationReason.newItemIsReturned),
      );
      expect(
        () => build(newItems: SaleCart.empty()),
        _invalid(CorrectionValidationReason.noNewItems),
      );
      expect(
        () => build(returnLines: const <ReturnLineInput>[]),
        _invalid(CorrectionValidationReason.noLines),
      );
      expect(
        () => build(amount: 0),
        _invalid(CorrectionValidationReason.invalidPayment),
      );
      expect(
        () => build(amount: maxSafeSaleInteger + 1),
        _invalid(CorrectionValidationReason.invalidPayment),
      );
    });
  });

  group('CorrectionDraftStore', () {
    test('keeps one unresolved draft per seller and branch', () {
      final CorrectionDraftStore store = CorrectionDraftStore();
      final SaleReturnDraft draft = returnDraft();
      final CorrectionAttempt first = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      expect(store.unresolvedFor('seller-1', saleBranchId), same(draft));
      expect(
        () => store.begin(ownerUserId: 'seller-1', draft: replacementDraft()),
        throwsA(isA<CorrectionUnresolvedException>()),
      );
      final CorrectionAttempt retry = store.begin(
        ownerUserId: 'seller-1',
        draft: returnDraft(),
      );
      expect(store.isCurrent(first), isFalse);
      expect(store.resolve(first), isFalse);
      expect(store.resolve(retry), isTrue);
      expect(store.unresolvedFor('seller-1', saleBranchId), isNull);
      expect(
        () => store.begin(ownerUserId: '', draft: draft),
        throwsA(isA<SaleSessionException>()),
      );
    });

    test('isolates drafts between sellers and between branches', () {
      final CorrectionDraftStore store = CorrectionDraftStore();
      final SaleReturnDraft north = returnDraft();
      final SaleReturnDraft south = _return(branchId: 'branch-south');
      final CorrectionAttempt sellerNorth = store.begin(
        ownerUserId: 'seller-1',
        draft: north,
      );
      // Neither another seller on the same branch nor the same seller on
      // another branch is blocked by seller-1's unresolved north draft.
      final CorrectionAttempt otherSeller = store.begin(
        ownerUserId: 'seller-2',
        draft: replacementDraft(),
      );
      final CorrectionAttempt sellerSouth = store.begin(
        ownerUserId: 'seller-1',
        draft: south,
      );
      expect(store.unresolvedFor('seller-1', saleBranchId), same(north));
      expect(
        store.unresolvedFor('seller-2', saleBranchId),
        isA<SaleReplacementDraft>(),
      );
      expect(store.unresolvedFor('seller-1', 'branch-south'), same(south));
      expect(store.unresolvedFor('seller-2', 'branch-south'), isNull);

      expect(store.resolve(sellerNorth), isTrue);
      expect(store.unresolvedFor('seller-1', saleBranchId), isNull);
      expect(store.isCurrent(otherSeller), isTrue);
      expect(store.isCurrent(sellerSouth), isTrue);
      expect(store.unresolvedFor('seller-1', 'branch-south'), same(south));
    });

    test('an attempt is no longer current once resolved', () {
      final CorrectionDraftStore store = CorrectionDraftStore();
      final CorrectionAttempt attempt = store.begin(
        ownerUserId: 'seller-1',
        draft: returnDraft(),
      );
      expect(store.isCurrent(attempt), isTrue);
      expect(store.resolve(attempt), isTrue);
      expect(store.isCurrent(attempt), isFalse);
      expect(store.resolve(attempt), isFalse);
    });

    test('a stale attempt never clears a newer draft', () {
      final CorrectionDraftStore store = CorrectionDraftStore();
      final SaleReturnDraft draft = returnDraft();
      final CorrectionAttempt stale = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      final CorrectionAttempt retry = store.begin(
        ownerUserId: 'seller-1',
        draft: returnDraft(),
      );
      expect(store.resolve(stale), isFalse);
      expect(store.unresolvedFor('seller-1', saleBranchId), equals(draft));
      expect(store.resolve(retry), isTrue);

      // The same draft begun again after resolution is a newer attempt: the
      // first-generation attempt must not resolve it.
      final CorrectionAttempt again = store.begin(
        ownerUserId: 'seller-1',
        draft: returnDraft(),
      );
      expect(store.isCurrent(stale), isFalse);
      expect(store.resolve(stale), isFalse);
      expect(store.isCurrent(retry), isFalse);
      expect(store.resolve(retry), isFalse);
      expect(store.unresolvedFor('seller-1', saleBranchId), isNotNull);
      expect(store.resolve(again), isTrue);
    });
  });
}
