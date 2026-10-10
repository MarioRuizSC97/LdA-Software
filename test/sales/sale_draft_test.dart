import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

import 'sale_fixtures.dart';

SaleQuote _quote({bool pinAvailable = true}) => SaleQuote.fromCallable(
  quoteResponse(pinAvailable: pinAvailable),
  cart: invoicedCart(),
);

SaleDraft _draft({SalePaymentMethod method = SalePaymentMethod.card}) =>
    SaleDraft.fromQuote(
      quote: _quote(),
      branchId: saleBranchId,
      paymentMethod: method,
      createKey: () => saleKey,
    );

void main() {
  group('saleFolio', () {
    test('derives the branch-prefixed folio from the key head', () {
      expect(saleFolio('NTE', saleKey), 'NTE-3F2A-9C1B');
      expect(saleFolio('SU', 'abcdef01-0000'), 'SU-ABCD-EF01');
      expect(
        () => saleFolio('nte', saleKey),
        throwsA(isA<SaleValidationException>()),
      );
      expect(
        () => saleFolio('NTE', 'abc-1234'),
        throwsA(isA<SaleValidationException>()),
      );
    });
  });

  group('SaleDraft', () {
    test('freezes one generated key, the cart, and the quoted amount', () {
      var generated = 0;
      final SaleDraft draft = SaleDraft.fromQuote(
        quote: _quote(),
        branchId: saleBranchId,
        paymentMethod: SalePaymentMethod.cash,
        createKey: () {
          generated += 1;
          return saleKey;
        },
      );

      expect(generated, 1);
      expect(draft.idempotencyKey, saleKey);
      expect(draft.toRequest(), draft.toRequest());
      expect(generated, 1);
      expect(draft.amountCentavos, 3650);
      expect(draft.cart, invoicedCart());
      expect(draft.toRequest(), <String, Object?>{
        'idempotencyKey': saleKey,
        'invoiceRequested': true,
        'lines': <Object?>[
          <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.5'},
          <String, Object?>{'productId': 'DEMO-PIN', 'quantity': '3'},
        ],
        'payment': <String, Object?>{'method': 'cash', 'amountCentavos': 3650},
      });
    });

    test('default keys are distinct UUID v4 values', () {
      final SaleDraft first = SaleDraft.fromQuote(
        quote: _quote(),
        branchId: saleBranchId,
        paymentMethod: SalePaymentMethod.cash,
      );
      final SaleDraft second = SaleDraft.fromQuote(
        quote: _quote(),
        branchId: saleBranchId,
        paymentMethod: SalePaymentMethod.cash,
      );
      final RegExp uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidV4.hasMatch(first.idempotencyKey), isTrue);
      expect(first.idempotencyKey, isNot(second.idempotencyKey));
    });

    test('refuses short stock, bad keys, and bad branches', () {
      expect(
        () => SaleDraft.fromQuote(
          quote: _quote(pinAvailable: false),
          branchId: saleBranchId,
          paymentMethod: SalePaymentMethod.cash,
          createKey: () => saleKey,
        ),
        throwsA(isA<SaleValidationException>()),
      );
      for (final String key in <String>[
        'not-a-uuid',
        '3F2A9C1B-E89B-42D3-A456-426614174000',
        '3f2a9c1b-e89b-12d3-a456-426614174000',
      ]) {
        expect(
          () => SaleDraft.fromQuote(
            quote: _quote(),
            branchId: saleBranchId,
            paymentMethod: SalePaymentMethod.cash,
            createKey: () => key,
          ),
          throwsA(isA<SaleValidationException>()),
          reason: key,
        );
      }
      expect(
        () => SaleDraft.fromQuote(
          quote: _quote(),
          branchId: 'bad branch',
          paymentMethod: SalePaymentMethod.cash,
          createKey: () => saleKey,
        ),
        throwsA(isA<SaleValidationException>()),
      );
    });
  });

  group('SaleReceipt', () {
    test('parses a v2 receipt bound to the draft', () {
      final SaleReceipt receipt = SaleReceipt.fromCallable(
        submitResponse(replayed: true),
        draft: _draft(),
      );
      expect(receipt.saleId, saleKey);
      expect(receipt.branchId, saleBranchId);
      expect(receipt.branchCode, 'NTE');
      expect(receipt.folio, 'NTE-3F2A-9C1B');
      expect(receipt.invoiceRequested, isTrue);
      expect(receipt.paymentMethod, SalePaymentMethod.card);
      expect(receipt.amountCentavos, 3650);
      expect(receipt.totalCentavos, 3650);
      expect(receipt.baseCentavos, 3250);
      expect(receipt.additionalIvaCentavos, 400);
      expect(
        receipt.lines.map((SalePricedLine line) => line.totalCentavos),
        <int>[2900, 750],
      );
      expect(receipt.lines.first.name, 'Ribbon');
      expect(receipt.replayed, isTrue);
      expect(receipt.createdAt, DateTime.utc(2026, 10, 9, 1, 42));
      expect(receipt.createdAt.isUtc, isTrue);
      expect(receipt.createdAt.millisecondsSinceEpoch, saleCreatedAtMillis);
    });

    test('accepts the safe createdAt bounds and rejects anything else', () {
      for (final int millis in <int>[0, 8640000000000000]) {
        expect(
          SaleReceipt.fromCallable(
            submitResponse(createdAt: millis),
            draft: _draft(),
          ).createdAt.millisecondsSinceEpoch,
          millis,
        );
      }
      for (final Object? createdAt in <Object?>[
        null,
        -1,
        1.5,
        1791510120000.0,
        '1791510120000',
        8640000000000001,
        9007199254740992,
        <String, Object?>{'seconds': 1},
      ]) {
        expect(
          () => SaleReceipt.fromCallable(
            submitResponse(createdAt: createdAt),
            draft: _draft(),
          ),
          throwsA(isA<SaleProtocolException>()),
          reason: '$createdAt',
        );
      }
      final Map<String, Object?> missing = submitResponse()
        ..remove('createdAt');
      expect(
        () => SaleReceipt.fromCallable(missing, draft: _draft()),
        throwsA(isA<SaleProtocolException>()),
      );
    });

    test('rejects forged or malformed receipts', () {
      Map<String, Object?> withReceipt(
        void Function(Map<String, Object?> receipt) change,
      ) {
        final Map<String, Object?> response = submitResponse();
        change(response['receipt']! as Map<String, Object?>);
        return response;
      }

      final List<Object?> forgeries = <Object?>[
        null,
        <String, Object?>{'receipt': receiptV2()},
        <String, Object?>{...submitResponse(), 'extra': 1},
        <String, Object?>{...submitResponse(), 'replayed': 'no'},
        withReceipt((Map<String, Object?> r) => r['version'] = 1),
        withReceipt((Map<String, Object?> r) => r.remove('folio')),
        withReceipt((Map<String, Object?> r) => r['createdAt'] = 'now'),
        withReceipt(
          (Map<String, Object?> r) =>
              r['saleId'] = '3f2a9c1b-e89b-42d3-a456-426614174001',
        ),
        withReceipt((Map<String, Object?> r) => r['branchId'] = 'branch-south'),
        withReceipt((Map<String, Object?> r) => r['branchCode'] = 'nte'),
        withReceipt((Map<String, Object?> r) => r['folio'] = 'NTE-3F2A-9C1C'),
        withReceipt((Map<String, Object?> r) => r['folio'] = 'SUR-3F2A-9C1B'),
        withReceipt(
          (Map<String, Object?> r) =>
              r['productIds'] = <Object?>['DEMO-PIN', 'DEMO-RIBBON'],
        ),
        withReceipt(
          (Map<String, Object?> r) => r['payment'] = <String, Object?>{
            'method': 'cash',
            'amountCentavos': 3650,
          },
        ),
        withReceipt(
          (Map<String, Object?> r) => r['payment'] = <String, Object?>{
            'method': 'card',
            'amountCentavos': 3651,
          },
        ),
        withReceipt(
          (Map<String, Object?> r) => r['payment'] = <String, Object?>{
            'method': 'card',
            'amountCentavos': 3650,
            'change': 0,
          },
        ),
        withReceipt(
          (Map<String, Object?> r) =>
              (r['calculation']! as Map<String, Object?>)['totalCentavos'] =
                  3651,
        ),
      ];
      for (int index = 0; index < forgeries.length; index++) {
        expect(
          () => SaleReceipt.fromCallable(forgeries[index], draft: _draft()),
          throwsA(isA<SaleProtocolException>()),
          reason: 'forgery $index',
        );
      }
    });

    test('a payment equal to a forged calculation total is still rejected', () {
      final Map<String, Object?> response = submitResponse();
      final Map<String, Object?> receipt =
          response['receipt']! as Map<String, Object?>;
      final Map<String, Object?> calculation =
          receipt['calculation']! as Map<String, Object?>;
      calculation['totalCentavos'] = 100;
      receipt['payment'] = <String, Object?>{
        'method': 'card',
        'amountCentavos': 100,
      };
      expect(
        () => SaleReceipt.fromCallable(response, draft: _draft()),
        throwsA(isA<SaleProtocolException>()),
      );
    });
  });

  group('SaleDraftStore', () {
    test(
      'keeps one frozen draft per seller and branch for uncertain retries',
      () {
        final SaleDraftStore store = SaleDraftStore();
        final SaleDraft draft = _draft();

        final SaleAttempt first = store.begin(
          ownerUserId: 'seller-1',
          draft: draft,
        );
        expect(store.unresolvedFor('seller-1', saleBranchId), same(draft));
        expect(store.unresolvedFor('seller-2', saleBranchId), isNull);

        final SaleAttempt retry = store.begin(
          ownerUserId: 'seller-1',
          draft: draft,
        );
        expect(store.isCurrent(first), isFalse);
        expect(store.isCurrent(retry), isTrue);
        expect(store.resolve(first), isFalse);

        expect(
          () => store.begin(
            ownerUserId: 'seller-1',
            draft: _draft(method: SalePaymentMethod.cash),
          ),
          throwsA(isA<SaleUnresolvedException>()),
        );
        expect(
          () => store.begin(ownerUserId: '', draft: draft),
          throwsA(isA<SaleSessionException>()),
        );

        expect(store.resolve(retry), isTrue);
        expect(store.unresolvedFor('seller-1', saleBranchId), isNull);
        final SaleAttempt next = store.begin(
          ownerUserId: 'seller-1',
          draft: _draft(method: SalePaymentMethod.cash),
        );
        expect(store.isCurrent(next), isTrue);
      },
    );

    test('a stale attempt never settles an equal draft begun again', () {
      final SaleDraftStore store = SaleDraftStore();
      final SaleDraft draft = _draft();
      final SaleAttempt old = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      expect(store.resolve(old), isTrue);

      final SaleAttempt again = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      expect(store.isCurrent(old), isFalse);
      expect(store.resolve(old), isFalse);
      expect(store.complete(old, _receipt()), isFalse);
      expect(store.unresolvedFor('seller-1', saleBranchId), same(draft));
      expect(store.completedFor('seller-1', saleBranchId), isNull);
      expect(store.isCurrent(again), isTrue);

      // Revisions are store-wide: another seller's attempt never collides.
      final SaleAttempt other = store.begin(
        ownerUserId: 'seller-2',
        draft: draft,
      );
      expect(store.isCurrent(other), isTrue);
      expect(store.isCurrent(again), isTrue);
    });

    test('a committed sale keeps its receipt until it is acknowledged', () {
      final SaleDraftStore store = SaleDraftStore();
      final SaleDraft draft = _draft();
      final SaleReceipt receipt = _receipt();
      final SaleAttempt attempt = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );

      expect(store.complete(attempt, receipt), isTrue);
      expect(store.unresolvedFor('seller-1', saleBranchId), isNull);
      expect(store.completedFor('seller-1', saleBranchId), same(receipt));
      expect(store.completedFor('seller-2', saleBranchId), isNull);
      expect(store.completedFor('seller-1', 'branch-other'), isNull);
      expect(store.isCurrent(attempt), isTrue);
      expect(store.complete(attempt, receipt), isTrue);

      // No other sale may begin unaware of the committed one.
      expect(
        () => store.begin(
          ownerUserId: 'seller-1',
          draft: _draft(method: SalePaymentMethod.cash),
        ),
        throwsA(isA<SaleUnresolvedException>()),
      );

      // Only that exact receipt, for that exact seller and branch, clears it.
      expect(store.acknowledge('seller-2', saleBranchId, receipt), isFalse);
      expect(store.acknowledge('seller-1', saleBranchId, _receipt()), isFalse);
      expect(store.completedFor('seller-1', saleBranchId), same(receipt));
      expect(store.acknowledge('seller-1', saleBranchId, receipt), isTrue);
      expect(store.completedFor('seller-1', saleBranchId), isNull);
      expect(store.isCurrent(attempt), isFalse);
      expect(store.acknowledge('seller-1', saleBranchId, receipt), isFalse);

      final SaleAttempt next = store.begin(
        ownerUserId: 'seller-1',
        draft: _draft(method: SalePaymentMethod.cash),
      );
      expect(store.isCurrent(next), isTrue);
    });

    test('an unresolved draft is never acknowledged and a foreign receipt '
        'never completes an attempt', () {
      final SaleDraftStore store = SaleDraftStore();
      final SaleReceipt receipt = _receipt();
      final SaleAttempt cash = store.begin(
        ownerUserId: 'seller-1',
        draft: _draft(method: SalePaymentMethod.cash),
      );
      expect(store.acknowledge('seller-1', saleBranchId, receipt), isFalse);
      expect(store.unresolvedFor('seller-1', saleBranchId), isNotNull);
      expect(() => store.complete(cash, receipt), throwsArgumentError);
      expect(store.completedFor('seller-1', saleBranchId), isNull);
    });

    test('an equal completed draft may be sent again for a replay', () {
      final SaleDraftStore store = SaleDraftStore();
      final SaleDraft draft = _draft();
      final SaleAttempt first = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      expect(store.complete(first, _receipt()), isTrue);

      final SaleAttempt replay = store.begin(
        ownerUserId: 'seller-1',
        draft: draft,
      );
      expect(store.isCurrent(first), isFalse);
      final SaleReceipt replayed = _receipt(replayed: true);
      expect(store.complete(first, replayed), isFalse);
      expect(store.complete(replay, replayed), isTrue);
      expect(store.completedFor('seller-1', saleBranchId), same(replayed));
    });
  });
}

SaleReceipt _receipt({bool replayed = false}) => SaleReceipt.fromCallable(
  submitResponse(replayed: replayed),
  draft: _draft(),
);
