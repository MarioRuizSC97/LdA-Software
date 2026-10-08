import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

import '../sales/sale_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
final DateTime _now = DateTime.utc(2026, 10, 8, 18, 30);

SaleDraft _draft({String branchId = saleBranchId}) => SaleDraft.fromQuote(
  quote: SaleQuote.fromCallable(quoteResponse(), cart: invoicedCart()),
  branchId: branchId,
  paymentMethod: SalePaymentMethod.card,
  createKey: () => saleKey,
);

EmulatorSaleGateway _gateway({
  EmulatorSession expected = _seller,
  SaleSessionChecker? sessionChecker,
  SaleCallable? quoteInvoke,
  SaleCallable? submitInvoke,
}) => EmulatorSaleGateway(
  expectedSession: expected,
  sessionChecker: sessionChecker ?? () async => _seller,
  quoteInvoke: quoteInvoke ?? (_) async => quoteResponse(),
  submitInvoke: submitInvoke ?? (_) async => submitResponse(),
  clock: () => _now,
);

void main() {
  test('quote checks the seller before and after an exact request', () async {
    final List<String> events = <String>[];
    final EmulatorSaleGateway gateway = _gateway(
      sessionChecker: () async {
        events.add('session');
        return _seller;
      },
      quoteInvoke: (Map<String, Object?> request) async {
        events.add('quote');
        expect(request, <String, Object?>{
          'invoiceRequested': true,
          'lines': <Object?>[
            <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.5'},
            <String, Object?>{'productId': 'DEMO-PIN', 'quantity': '3'},
          ],
        });
        return quoteResponse();
      },
    );

    final SaleQuote quote = await gateway.quote(invoicedCart());
    expect(quote.totalCentavos, 3650);
    expect(events, <String>['session', 'quote', 'session']);
  });

  test(
    'submit sends the exact frozen request and stamps client time',
    () async {
      final List<String> events = <String>[];
      final EmulatorSaleGateway gateway = _gateway(
        sessionChecker: () async {
          events.add('session');
          return _seller;
        },
        submitInvoke: (Map<String, Object?> request) async {
          events.add('submit');
          expect(request, <String, Object?>{
            'idempotencyKey': saleKey,
            'invoiceRequested': true,
            'lines': <Object?>[
              <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.5'},
              <String, Object?>{'productId': 'DEMO-PIN', 'quantity': '3'},
            ],
            'payment': <String, Object?>{
              'method': 'card',
              'amountCentavos': 3650,
            },
          });
          return submitResponse();
        },
      );

      final SaleReceipt receipt = await gateway.submit(_draft());
      expect(receipt.folio, 'NTE-3F2A-9C1B');
      expect(receipt.replayed, isFalse);
      expect(receipt.confirmedAt, _now);
      expect(events, <String>['session', 'submit', 'session']);
    },
  );

  test('fails before network without the exact assigned seller', () async {
    for (final EmulatorSession? current in <EmulatorSession?>[
      null,
      _administrator,
      const EmulatorSession(
        userId: 'seller-2',
        email: 'other@demo.invalid',
        role: InventoryRole.seller,
        branchId: saleBranchId,
      ),
      const EmulatorSession(
        userId: 'seller-1',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-south',
      ),
    ]) {
      var invoked = false;
      final EmulatorSaleGateway gateway = _gateway(
        sessionChecker: () async => current,
        quoteInvoke: (_) async {
          invoked = true;
          return quoteResponse();
        },
        submitInvoke: (_) async {
          invoked = true;
          return submitResponse();
        },
      );
      await expectLater(
        gateway.quote(invoicedCart()),
        throwsA(isA<SaleSessionException>()),
      );
      await expectLater(
        gateway.submit(_draft()),
        throwsA(isA<SaleSessionException>()),
      );
      expect(invoked, isFalse);
    }

    var invoked = false;
    final EmulatorSaleGateway administrator = _gateway(
      expected: _administrator,
      sessionChecker: () async => _administrator,
      quoteInvoke: (_) async {
        invoked = true;
        return quoteResponse();
      },
    );
    await expectLater(
      administrator.quote(invoicedCart()),
      throwsA(isA<SaleSessionException>()),
    );

    final EmulatorSaleGateway seller = _gateway(
      submitInvoke: (_) async {
        invoked = true;
        return submitResponse();
      },
    );
    await expectLater(
      seller.submit(_draft(branchId: 'branch-south')),
      throwsA(isA<SaleSessionException>()),
    );
    expect(invoked, isFalse);
  });

  test('post-await session failure makes a valid result uncertain', () async {
    var checks = 0;
    final EmulatorSaleGateway gateway = _gateway(
      sessionChecker: () async => (checks++).isEven ? _seller : null,
    );
    await expectLater(
      gateway.quote(invoicedCart()),
      throwsA(isA<SaleUncertainException>()),
    );
    await expectLater(
      gateway.submit(_draft()),
      throwsA(isA<SaleUncertainException>()),
    );
  });

  test(
    'whitelisted callable codes become rejections with the server message',
    () async {
      for (final String code in <String>[
        'invalid-argument',
        'not-found',
        'failed-precondition',
        'out-of-range',
        'permission-denied',
        'unauthenticated',
        'already-exists',
      ]) {
        final SaleCallableException failure = SaleCallableException(
          code: code,
          message: 'full payment must equal the authoritative total',
        );
        final EmulatorSaleGateway gateway = _gateway(
          quoteInvoke: (_) => throw failure,
          submitInvoke: (_) => throw failure,
        );
        final Matcher rejected = throwsA(
          isA<SaleRejectedException>()
              .having((SaleRejectedException e) => e.code, 'code', code)
              .having(
                (SaleRejectedException e) => e.message,
                'message',
                'full payment must equal the authoritative total',
              ),
        );
        await expectLater(gateway.quote(invoicedCart()), rejected);
        await expectLater(gateway.submit(_draft()), rejected);
      }
    },
  );

  test('internal, transport, and malformed responses stay uncertain', () async {
    for (final Object failure in <Object>[
      const SaleCallableException(code: 'internal', message: 'unavailable'),
      const SaleCallableException(code: 'unavailable', message: ''),
      const SaleCallableException(code: 'deadline-exceeded', message: ''),
      const SaleCallableException(code: 'cancelled', message: ''),
      const SaleCallableException(code: 'unknown', message: ''),
      StateError('non-SDK transport detail'),
    ]) {
      final EmulatorSaleGateway gateway = _gateway(
        quoteInvoke: (_) => throw failure,
        submitInvoke: (_) => throw failure,
      );
      await expectLater(
        gateway.quote(invoicedCart()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.submit(_draft()),
        throwsA(isA<SaleUncertainException>()),
      );
    }

    final EmulatorSaleGateway malformed = _gateway(
      quoteInvoke: (_) async => <String, Object?>{
        ...quoteResponse(),
        'totalCentavos': 1,
      },
      submitInvoke: (_) async => <String, Object?>{
        ...submitResponse(),
        'replayed': null,
      },
    );
    await expectLater(
      malformed.quote(invoicedCart()),
      throwsA(isA<SaleUncertainException>()),
    );
    await expectLater(
      malformed.submit(_draft()),
      throwsA(isA<SaleUncertainException>()),
    );

    final EmulatorSaleGateway replayed = _gateway(
      submitInvoke: (_) async => submitResponse(replayed: true),
    );
    expect((await replayed.submit(_draft())).replayed, isTrue);
  });

  test('an invalid cart fails locally before any session or network', () async {
    var touched = false;
    final EmulatorSaleGateway gateway = _gateway(
      sessionChecker: () async {
        touched = true;
        return _seller;
      },
    );
    await expectLater(
      gateway.quote(SaleCart.empty()),
      throwsA(isA<SaleValidationException>()),
    );
    expect(touched, isFalse);
  });

  test('a newer quote invalidates a late older quote', () async {
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorSaleGateway gateway = _gateway(
      quoteInvoke: (_) {
        calls += 1;
        return calls == 1
            ? first.future
            : Future<Object?>.value(quoteResponse());
      },
    );

    final Future<SaleQuote> old = gateway.quote(invoicedCart());
    final SaleQuote current = await gateway.quote(invoicedCart());
    first.complete(quoteResponse());

    expect(current.totalCentavos, 3650);
    await expectLater(old, throwsA(isA<SaleStaleException>()));
  });

  test('a newer submit invalidates a late older submit', () async {
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorSaleGateway gateway = _gateway(
      submitInvoke: (_) {
        calls += 1;
        return calls == 1
            ? first.future
            : Future<Object?>.value(submitResponse(replayed: true));
      },
    );

    final Future<SaleReceipt> old = gateway.submit(_draft());
    final SaleReceipt current = await gateway.submit(_draft());
    first.complete(submitResponse());

    expect(current.replayed, isTrue);
    await expectLater(old, throwsA(isA<SaleStaleException>()));
  });
}
