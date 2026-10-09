import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'seller-2',
  email: 'other@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

EmulatorCorrectionGateway _gateway({
  EmulatorSession expected = _seller,
  SaleSessionChecker? sessionChecker,
  SaleCallable? findInvoke,
  SaleCallable? listInvoke,
  SaleCallable? returnInvoke,
  SaleCallable? replacementInvoke,
  SaleCallable? exchangeInvoke,
}) => EmulatorCorrectionGateway(
  expectedSession: expected,
  sessionChecker: sessionChecker ?? () async => _seller,
  findInvoke: findInvoke ?? (_) async => findResponse(),
  listInvoke:
      listInvoke ??
      (_) async => <String, Object?>{
        'sales': <Object?>[lookupSaleJson()],
      },
  returnInvoke: returnInvoke ?? (_) async => returnResponse(),
  replacementInvoke: replacementInvoke ?? (_) async => replacementResponse(),
  exchangeInvoke: exchangeInvoke ?? (_) async => exchangeResponse(),
);

SaleCallable _throwing(Object error) =>
    (_) async => throw error;

void main() {
  test('find checks the seller around one exact folio request', () async {
    final List<String> events = <String>[];
    final EmulatorCorrectionGateway gateway = _gateway(
      sessionChecker: () async {
        events.add('session');
        return _seller;
      },
      findInvoke: (Map<String, Object?> request) async {
        events.add('find');
        expect(request, <String, Object?>{'folio': 'NTE-3F2A-9C1B'});
        return findResponse();
      },
    );
    final CorrectableSale sale = await gateway.find(
      SaleLookupQuery.byFolio('nte-3f2a-9c1b'),
    );
    expect(sale.saleId, saleKey);
    expect(events, <String>['session', 'find', 'session']);
  });

  test('listRecent sends the exact limit and parses the list', () async {
    final EmulatorCorrectionGateway gateway = _gateway(
      listInvoke: (Map<String, Object?> request) async {
        expect(request, <String, Object?>{'limit': 5});
        return <String, Object?>{
          'sales': <Object?>[lookupSaleJson()],
        };
      },
    );
    final RecentCorrectableSales recent = await gateway.listRecent(
      RecentSalesQuery(limit: 5),
    );
    expect(recent.sales.single.folio, 'NTE-3F2A-9C1B');
    final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
    await _gateway(
      listInvoke: (Map<String, Object?> request) async {
        requests.add(request);
        return <String, Object?>{'sales': <Object?>[]};
      },
    ).listRecent();
    expect(requests, <Object?>[<String, Object?>{}]);
  });

  test('each submission sends its exact draft request', () async {
    final List<String> calls = <String>[];
    final EmulatorCorrectionGateway gateway = _gateway(
      returnInvoke: (Map<String, Object?> request) async {
        calls.add('return');
        expect(request, returnDraft().toRequest());
        return returnResponse();
      },
      replacementInvoke: (Map<String, Object?> request) async {
        calls.add('replacement');
        expect(request, replacementDraft().toRequest());
        return replacementResponse();
      },
      exchangeInvoke: (Map<String, Object?> request) async {
        calls.add('exchange');
        expect(request, exchangeDraft().toRequest());
        return exchangeResponse();
      },
    );
    final SaleReturnReceipt returned = await gateway.submitReturn(
      returnDraft(),
    );
    final SaleReplacementReceipt replaced = await gateway.submitReplacement(
      replacementDraft(),
    );
    final SaleExchangeReceipt exchanged = await gateway.submitExchange(
      exchangeDraft(),
    );
    expect(returned.totalCentavos, 1410);
    expect(replaced.lines.single.quantityScaled, 2);
    expect(exchanged.settlement.customerPaysCentavos, 2070);
    expect(calls, <String>['return', 'replacement', 'exchange']);
  });

  test('whitelisted codes become rejections with message and reason', () async {
    for (final String code in <String>[
      'invalid-argument',
      'not-found',
      'failed-precondition',
      'out-of-range',
      'permission-denied',
      'unauthenticated',
      'already-exists',
    ]) {
      final EmulatorCorrectionGateway gateway = _gateway(
        returnInvoke: _throwing(
          SaleCallableException(
            code: code,
            message: 'server says $code',
            reason: 'some-reason',
          ),
        ),
        findInvoke: _throwing(
          SaleCallableException(code: code, message: 'lookup $code'),
        ),
      );
      await expectLater(
        gateway.submitReturn(returnDraft()),
        throwsA(
          isA<SaleRejectedException>()
              .having((SaleRejectedException e) => e.code, 'code', code)
              .having(
                (SaleRejectedException e) => e.message,
                'message',
                'server says $code',
              )
              .having(
                (SaleRejectedException e) => e.reason,
                'reason',
                'some-reason',
              ),
        ),
      );
      await expectLater(
        gateway.find(SaleLookupQuery.bySaleId(saleKey)),
        throwsA(
          isA<SaleRejectedException>().having(
            (SaleRejectedException e) => e.reason,
            'reason',
            isNull,
          ),
        ),
      );
    }
  });

  test('internal, other codes and transport errors are uncertain', () async {
    for (final Object error in <Object>[
      const SaleCallableException(code: 'internal', message: 'unavailable'),
      const SaleCallableException(code: 'unavailable', message: ''),
      const SaleCallableException(code: 'deadline-exceeded', message: ''),
      StateError('socket closed'),
    ]) {
      final EmulatorCorrectionGateway gateway = _gateway(
        exchangeInvoke: _throwing(error),
        listInvoke: _throwing(error),
      );
      await expectLater(
        gateway.submitExchange(exchangeDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.listRecent(),
        throwsA(isA<SaleUncertainException>()),
      );
    }
  });

  test(
    'malformed reads are protocol errors, malformed submits uncertain',
    () async {
      final EmulatorCorrectionGateway gateway = _gateway(
        findInvoke: (_) async => <String, Object?>{'sale': null},
        listInvoke: (_) async => <String, Object?>{'sales': 1},
        returnInvoke: (_) async => <String, Object?>{'receipt': null},
        replacementInvoke: (_) async => null,
        exchangeInvoke: (_) async => returnResponse(),
      );
      await expectLater(
        gateway.find(SaleLookupQuery.bySaleId(saleKey)),
        throwsA(isA<CorrectionProtocolException>()),
      );
      await expectLater(
        gateway.listRecent(),
        throwsA(isA<CorrectionProtocolException>()),
      );
      await expectLater(
        gateway.submitReturn(returnDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.submitReplacement(replacementDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.submitExchange(exchangeDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
    },
  );

  test(
    'any parse failure after a submit returned is uncertain, not raw',
    () async {
      // A malformed new-items calculation: the right shape, but one value
      // read through a mistyped view fails with a cast error, which the
      // strict parsers never anticipated.
      final Map<String, Object?> calculationResponse = exchangeResponse();
      final Map<String, Object?> receipt = Map<String, Object?>.of(
        calculationResponse['receipt']! as Map<String, Object?>,
      );
      final Map<String, Object?> newItems = Map<String, Object?>.of(
        receipt['newItems']! as Map<String, Object?>,
      );
      newItems['calculation'] = tapeCalculation().cast<String, String>();
      receipt['newItems'] = newItems;
      calculationResponse['receipt'] = receipt;

      // A wrong-type field read through a typed view of the response.
      final Map<String, Object?> wrongType = Map<String, Object?>.of(
        returnResponse(),
      )..['receipt'] = returnReceiptJson().cast<String, int>();

      final EmulatorCorrectionGateway gateway = _gateway(
        exchangeInvoke: (_) async => calculationResponse,
        returnInvoke: (_) async => wrongType,
        replacementInvoke: (_) async => <String, Object?>{
          'receipt': replacementReceiptJson(),
          'replayed': 'no',
        }.cast<String, bool>(),
      );
      await expectLater(
        gateway.submitExchange(exchangeDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.submitReturn(returnDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
      await expectLater(
        gateway.submitReplacement(replacementDraft()),
        throwsA(isA<SaleUncertainException>()),
      );
    },
  );

  test('a different or missing seller before the call never invokes', () async {
    int invoked = 0;
    Future<Object?> count(Map<String, Object?> _) async {
      invoked++;
      return returnResponse();
    }

    for (final EmulatorSession? current in <EmulatorSession?>[
      null,
      _otherSeller,
      _administrator,
    ]) {
      await expectLater(
        _gateway(
          sessionChecker: () async => current,
          returnInvoke: count,
        ).submitReturn(returnDraft()),
        throwsA(isA<SaleSessionException>()),
      );
    }
    await expectLater(
      _gateway(
        expected: _administrator,
        sessionChecker: () async => _administrator,
        returnInvoke: count,
      ).submitReturn(returnDraft()),
      throwsA(isA<SaleSessionException>()),
    );
    expect(invoked, 0);
  });

  test('a draft for another branch is refused before calling', () async {
    int invoked = 0;
    final SaleReturnDraft foreign = SaleReturnDraft.create(
      sale: lookupSale(),
      branchId: 'branch-south',
      reason: CorrectionReason.other,
      lines: const <ReturnLineInput>[
        ReturnLineInput(
          lineIndex: 1,
          quantity: '1',
          condition: ReturnCondition.good,
        ),
      ],
      createKey: () => returnKey,
    );
    await expectLater(
      _gateway(
        returnInvoke: (_) async {
          invoked++;
          return returnResponse();
        },
      ).submitReturn(foreign),
      throwsA(isA<SaleSessionException>()),
    );
    expect(invoked, 0);
  });

  test('a session change during a submit makes it uncertain', () async {
    int checks = 0;
    final EmulatorCorrectionGateway gateway = _gateway(
      sessionChecker: () async => ++checks == 1 ? _seller : _otherSeller,
    );
    await expectLater(
      gateway.submitReplacement(replacementDraft()),
      throwsA(isA<SaleUncertainException>()),
    );
  });

  test('superseded calls are stale whatever their outcome', () async {
    final List<Completer<Object?>> pending = <Completer<Object?>>[];
    final EmulatorCorrectionGateway gateway = _gateway(
      findInvoke: (_) {
        final Completer<Object?> completer = Completer<Object?>();
        pending.add(completer);
        return completer.future;
      },
      returnInvoke: (_) async => returnResponse(),
    );
    final Future<CorrectableSale> first = gateway.find(
      SaleLookupQuery.bySaleId(saleKey),
    );
    final Future<CorrectableSale> second = gateway.find(
      SaleLookupQuery.bySaleId(saleKey),
    );
    // Another operation does not supersede a lookup.
    await gateway.submitReturn(returnDraft());
    await pumpEventQueue();
    pending[0].completeError(
      const SaleCallableException(code: 'not-found', message: 'missing'),
    );
    pending[1].complete(findResponse());
    await expectLater(first, throwsA(isA<SaleStaleException>()));
    expect((await second).saleId, saleKey);

    final List<Completer<Object?>> submits = <Completer<Object?>>[];
    final EmulatorCorrectionGateway submitting = _gateway(
      exchangeInvoke: (_) {
        final Completer<Object?> completer = Completer<Object?>();
        submits.add(completer);
        return completer.future;
      },
    );
    final Future<SaleExchangeReceipt> older = submitting.submitExchange(
      exchangeDraft(),
    );
    final Future<SaleExchangeReceipt> newer = submitting.submitExchange(
      exchangeDraft(),
    );
    await pumpEventQueue();
    submits[0].complete(exchangeResponse());
    submits[1].completeError(StateError('offline'));
    await expectLater(older, throwsA(isA<SaleStaleException>()));
    await expectLater(newer, throwsA(isA<SaleUncertainException>()));
  });
}
