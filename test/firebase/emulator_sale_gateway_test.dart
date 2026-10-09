import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
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
    'submit sends the exact frozen request and keeps the server time',
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
      expect(receipt.createdAt, DateTime.utc(2026, 10, 9, 1, 42));
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

  test('the server reason reaches the rejection and classifies it', () async {
    Future<SaleRejectedException> rejection(String code, String? reason) async {
      final EmulatorSaleGateway gateway = _gateway(
        submitInvoke: (_) => throw SaleCallableException(
          code: code,
          message: 'server text',
          reason: reason,
        ),
      );
      try {
        await gateway.submit(_draft());
      } on SaleRejectedException catch (error) {
        return error;
      }
      fail('expected a rejection');
    }

    final SaleRejectedException mismatch = await rejection(
      'invalid-argument',
      'payment-mismatch',
    );
    expect(mismatch.reason, 'payment-mismatch');
    expect(mismatch.message, 'server text');
    expect(mismatch.isPaymentMismatch, isTrue);
    expect(mismatch.isInsufficientStock, isFalse);

    final SaleRejectedException stock = await rejection(
      'failed-precondition',
      'insufficient-stock',
    );
    expect(stock.reason, 'insufficient-stock');
    expect(stock.isInsufficientStock, isTrue);
    expect(stock.isPaymentMismatch, isFalse);

    for (final (String code, String? reason) in <(String, String?)>[
      ('invalid-argument', null),
      ('invalid-argument', 'Payment-Mismatch'),
      ('invalid-argument', 'payment-mismatch '),
      ('failed-precondition', 'payment-mismatch'),
      ('invalid-argument', 'insufficient-stock'),
    ]) {
      final SaleRejectedException other = await rejection(code, reason);
      expect(other.isPaymentMismatch, isFalse, reason: '$code $reason');
      expect(other.isInsufficientStock, isFalse, reason: '$code $reason');
    }
  });

  test('the English mismatch message alone no longer means re-quote', () {
    const SaleRejectedException legacy = SaleRejectedException(
      code: 'invalid-argument',
      message: 'full payment must equal the authoritative total',
    );
    expect(legacy.reason, isNull);
    expect(legacy.isPaymentMismatch, isFalse);
  });

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

  test('a superseded quote or submit that fails is stale', () async {
    for (final Object failure in <Object>[
      const SaleCallableException(code: 'invalid-argument', message: 'bad'),
      const SaleCallableException(code: 'internal', message: ''),
      StateError('transport'),
    ]) {
      final Completer<Object?> firstQuote = Completer<Object?>();
      final Completer<Object?> firstSubmit = Completer<Object?>();
      var quoteCalls = 0;
      var submitCalls = 0;
      final EmulatorSaleGateway gateway = _gateway(
        quoteInvoke: (_) {
          quoteCalls += 1;
          return quoteCalls == 1
              ? firstQuote.future
              : Future<Object?>.value(quoteResponse());
        },
        submitInvoke: (_) {
          submitCalls += 1;
          return submitCalls == 1
              ? firstSubmit.future
              : Future<Object?>.value(submitResponse());
        },
      );

      final Future<SaleQuote> oldQuote = gateway.quote(invoicedCart());
      final Future<SaleReceipt> oldSubmit = gateway.submit(_draft());
      await gateway.quote(invoicedCart());
      await gateway.submit(_draft());
      firstQuote.completeError(failure);
      firstSubmit.completeError(failure);

      await expectLater(oldQuote, throwsA(isA<SaleStaleException>()));
      await expectLater(oldSubmit, throwsA(isA<SaleStaleException>()));
    }
  });

  test('a current failure is still rejected or uncertain', () async {
    final EmulatorSaleGateway gateway = _gateway(
      quoteInvoke: (_) => throw const SaleCallableException(
        code: 'failed-precondition',
        message: 'stock',
      ),
    );
    await expectLater(
      gateway.quote(invoicedCart()),
      throwsA(
        isA<SaleRejectedException>().having(
          (SaleRejectedException error) => error.message,
          'message',
          'stock',
        ),
      ),
    );
  });

  group('saleCallableFromInvoker', () {
    test('returns the callable data unchanged', () async {
      final Object data = <String, Object?>{'ok': true};
      Map<String, Object?>? seen;
      final SaleCallable callable = saleCallableFromInvoker((
        Map<String, Object?> request,
      ) async {
        seen = request;
        return data;
      });
      expect(await callable(<String, Object?>{'a': 1}), same(data));
      expect(seen, <String, Object?>{'a': 1});
    });

    test('maps FirebaseFunctionsException keeping the code', () async {
      final SaleCallable callable = saleCallableFromInvoker(
        (_) => throw _FunctionsException(
          code: 'failed-precondition',
          message: 'full payment must equal the authoritative total',
        ),
      );
      await expectLater(
        callable(<String, Object?>{}),
        throwsA(
          isA<SaleCallableException>()
              .having(
                (SaleCallableException e) => e.code,
                'code',
                'failed-precondition',
              )
              .having(
                (SaleCallableException e) => e.message,
                'message',
                'full payment must equal the authoritative total',
              ),
        ),
      );
    });

    test(
      'carries an exact string details.reason and tolerates others',
      () async {
        Future<SaleCallableException> mapped(Object? details) async {
          final SaleCallable callable = saleCallableFromInvoker(
            (_) => throw _FunctionsException(
              code: 'invalid-argument',
              message: 'server text',
              details: details,
            ),
          );
          try {
            await callable(<String, Object?>{});
          } on SaleCallableException catch (error) {
            return error;
          }
          fail('expected a callable exception');
        }

        expect(
          (await mapped(<String, Object?>{'reason': 'payment-mismatch'}))
              .reason,
          'payment-mismatch',
        );
        expect(
          (await mapped(<Object?, Object?>{'reason': 'insufficient-stock'}))
              .reason,
          'insufficient-stock',
        );
        for (final Object? details in <Object?>[
          null,
          'payment-mismatch',
          <Object?>['payment-mismatch'],
          <String, Object?>{},
          <String, Object?>{'reason': 7},
          <String, Object?>{'reason': null},
          <String, Object?>{'code': 'payment-mismatch'},
        ]) {
          final SaleCallableException error = await mapped(details);
          expect(error.reason, isNull, reason: '$details');
          expect(error.code, 'invalid-argument');
          expect(error.message, 'server text');
        }
      },
    );

    test('a null message becomes empty', () async {
      final SaleCallable callable = saleCallableFromInvoker(
        (_) => throw _FunctionsException(code: 'internal', message: null),
      );
      await expectLater(
        callable(<String, Object?>{}),
        throwsA(
          isA<SaleCallableException>()
              .having((SaleCallableException e) => e.code, 'code', 'internal')
              .having((SaleCallableException e) => e.message, 'message', ''),
        ),
      );
    });

    test('other errors pass through unchanged', () async {
      final StateError failure = StateError('transport');
      final SaleCallable callable = saleCallableFromInvoker(
        (_) => throw failure,
      );
      await expectLater(callable(<String, Object?>{}), throwsA(same(failure)));
    });
  });
}

class _FunctionsException extends FirebaseFunctionsException {
  _FunctionsException({
    required super.code,
    required String? message,
    super.details,
  }) : _message = message,
       super(message: message ?? '');

  final String? _message;

  @override
  String? get message => _message;
}
