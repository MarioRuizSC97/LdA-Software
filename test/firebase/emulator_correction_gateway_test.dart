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
  SaleCallable? previewReturnInvoke,
  SaleCallable? previewExchangeInvoke,
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
  previewReturnInvoke: previewReturnInvoke ?? (_) async => returnPreviewJson(),
  previewExchangeInvoke:
      previewExchangeInvoke ?? (_) async => exchangePreviewJson(),
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

  group('previewReturn', () {
    test('checks the seller around one exact preview request', () async {
      final List<String> events = <String>[];
      final EmulatorCorrectionGateway gateway = _gateway(
        sessionChecker: () async {
          events.add('session');
          return _seller;
        },
        previewReturnInvoke: (Map<String, Object?> request) async {
          events.add('preview');
          expect(request, returnPreviewRequest().toRequest());
          return returnPreviewJson();
        },
      );
      final SaleReturnPreview preview = await gateway.previewReturn(
        returnPreviewRequest(),
      );
      expect(preview.totalCentavos, 1410);
      expect(events, <String>['session', 'preview', 'session']);
    });

    test('a malformed preview is a protocol error, never uncertain', () async {
      final List<Object?> responses = <Object?>[
        null,
        <String, Object?>{'receipt': returnReceiptJson(), 'replayed': false},
        Map<String, Object?>.of(returnPreviewJson())..['saleId'] = otherSaleId,
        // A wrong-type field read through a typed view: a cast error.
        returnPreviewJson().cast<String, int>(),
      ];
      for (int index = 0; index < responses.length; index++) {
        await expectLater(
          _gateway(previewReturnInvoke: (_) async => responses[index])
              .previewReturn(returnPreviewRequest()),
          throwsA(isA<CorrectionProtocolException>()),
          reason: 'response $index',
        );
      }
    });

    test('rejections keep code, message and the known reasons', () async {
      Future<SaleRejectedException> rejection(
        SaleCallableException error,
      ) async {
        try {
          await _gateway(previewReturnInvoke: _throwing(error))
              .previewReturn(returnPreviewRequest());
        } on SaleRejectedException catch (rejected) {
          return rejected;
        }
        fail('expected a rejection');
      }

      final SaleRejectedException over = await rejection(
        const SaleCallableException(
          code: 'out-of-range',
          message: 'return exceeds the remaining sold quantity',
          reason: 'over-return',
        ),
      );
      expect(over.isOverReturn, isTrue);
      expect(over.isOutsideCorrectionWindow, isFalse);

      final SaleRejectedException window = await rejection(
        const SaleCallableException(
          code: 'failed-precondition',
          message: 'sale is outside the correction window',
          reason: 'correction-window-closed',
        ),
      );
      expect(window.isOutsideCorrectionWindow, isTrue);
      expect(window.isOverReturn, isFalse);
      expect(window.isFolioAmbiguous, isFalse);

      final SaleRejectedException other = await rejection(
        const SaleCallableException(
          code: 'failed-precondition',
          message: 'stock projection cannot accept the return',
        ),
      );
      expect(other.isOutsideCorrectionWindow, isFalse);

      await expectLater(
        _gateway(previewReturnInvoke: _throwing(StateError('offline')))
            .previewReturn(returnPreviewRequest()),
        throwsA(isA<SaleUncertainException>()),
      );
    });

    test('only the folio-ambiguous reason is ambiguous', () async {
      Future<SaleRejectedException> rejection(String? reason) async {
        try {
          await _gateway(
            findInvoke: _throwing(
              SaleCallableException(
                code: 'failed-precondition',
                message: 'folio is ambiguous',
                reason: reason,
              ),
            ),
          ).find(SaleLookupQuery.byFolio('NTE-3F2A-9C1B'));
        } on SaleRejectedException catch (rejected) {
          return rejected;
        }
        fail('expected a rejection');
      }

      expect(correctionFolioAmbiguousReason, 'folio-ambiguous');
      expect((await rejection('folio-ambiguous')).isFolioAmbiguous, isTrue);
      expect((await rejection(null)).isFolioAmbiguous, isFalse);
      expect((await rejection('payment-mismatch')).isFolioAmbiguous, isFalse);
    });

    test('a superseded preview is stale whatever its outcome', () async {
      final List<Completer<Object?>> pending = <Completer<Object?>>[];
      final EmulatorCorrectionGateway gateway = _gateway(
        previewReturnInvoke: (_) {
          final Completer<Object?> completer = Completer<Object?>();
          pending.add(completer);
          return completer.future;
        },
      );
      final Future<SaleReturnPreview> first = gateway.previewReturn(
        returnPreviewRequest(),
      );
      final Future<SaleReturnPreview> second = gateway.previewReturn(
        returnPreviewRequest(),
      );
      final Future<SaleReturnPreview> third = gateway.previewReturn(
        returnPreviewRequest(),
      );
      await pumpEventQueue();
      pending[0].complete(returnPreviewJson());
      pending[1].completeError(
        const SaleCallableException(code: 'out-of-range', message: 'over'),
      );
      pending[2].complete(returnPreviewJson());
      await expectLater(first, throwsA(isA<SaleStaleException>()));
      await expectLater(second, throwsA(isA<SaleStaleException>()));
      expect((await third).totalCentavos, 1410);
    });
  });

  group('previewExchange', () {
    test('checks the seller around one exact preview request', () async {
      final List<String> events = <String>[];
      final EmulatorCorrectionGateway gateway = _gateway(
        sessionChecker: () async {
          events.add('session');
          return _seller;
        },
        previewExchangeInvoke: (Map<String, Object?> request) async {
          events.add('preview');
          expect(request, <String, Object?>{
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
          return exchangePreviewJson();
        },
      );
      final SaleExchangePreview preview = await gateway.previewExchange(
        exchangePreviewRequest(),
      );
      expect(preview.customerPaysCentavos, 2070);
      expect(events, <String>['session', 'preview', 'session']);
    });

    test('a different seller before the call never invokes', () async {
      int calls = 0;
      await expectLater(
        _gateway(
          sessionChecker: () async => _otherSeller,
          previewExchangeInvoke: (_) async {
            calls += 1;
            return exchangePreviewJson();
          },
        ).previewExchange(exchangePreviewRequest()),
        throwsA(isA<SaleSessionException>()),
      );
      expect(calls, 0);
    });

    test('a malformed preview is a protocol error, never uncertain', () async {
      final List<Object?> responses = <Object?>[
        null,
        exchangeResponse(),
        Map<String, Object?>.of(exchangePreviewJson())
          ..['saleId'] = otherSaleId,
        Map<String, Object?>.of(exchangePreviewJson())..['newLines'] = 'none',
        // A wrong-type field read through a typed view: a cast error.
        exchangePreviewJson().cast<String, int>(),
      ];
      for (int index = 0; index < responses.length; index++) {
        await expectLater(
          _gateway(previewExchangeInvoke: (_) async => responses[index])
              .previewExchange(exchangePreviewRequest()),
          throwsA(isA<CorrectionProtocolException>()),
          reason: 'response $index',
        );
      }
    });

    test(
      'rejections keep code, message and reason; others are uncertain',
      () async {
        try {
          await _gateway(
            previewExchangeInvoke: _throwing(
              const SaleCallableException(
                code: 'invalid-argument',
                message:
                    'exchange new items must differ from the returned products',
              ),
            ),
          ).previewExchange(exchangePreviewRequest());
          fail('expected a rejection');
        } on SaleRejectedException catch (rejected) {
          expect(rejected.code, 'invalid-argument');
          expect(
            rejected.message,
            'exchange new items must differ from the returned products',
          );
        }
        await expectLater(
          _gateway(
            previewExchangeInvoke: _throwing(
              const SaleCallableException(code: 'internal', message: 'boom'),
            ),
          ).previewExchange(exchangePreviewRequest()),
          throwsA(isA<SaleUncertainException>()),
        );
      },
    );

    test('a superseded preview is stale whatever its outcome', () async {
      final List<Completer<Object?>> pending = <Completer<Object?>>[];
      final EmulatorCorrectionGateway gateway = _gateway(
        previewExchangeInvoke: (_) {
          final Completer<Object?> completer = Completer<Object?>();
          pending.add(completer);
          return completer.future;
        },
      );
      final Future<SaleExchangePreview> first = gateway.previewExchange(
        exchangePreviewRequest(),
      );
      final Future<SaleExchangePreview> second = gateway.previewExchange(
        exchangePreviewRequest(),
      );
      // A return preview counts separately and never makes it stale.
      final Future<SaleReturnPreview> other = gateway.previewReturn(
        returnPreviewRequest(),
      );
      final Future<SaleExchangePreview> third = gateway.previewExchange(
        exchangePreviewRequest(),
      );
      await pumpEventQueue();
      pending[0].complete(exchangePreviewJson());
      pending[1].completeError(
        const SaleCallableException(code: 'out-of-range', message: 'over'),
      );
      pending[2].complete(exchangePreviewJson());
      await expectLater(first, throwsA(isA<SaleStaleException>()));
      await expectLater(second, throwsA(isA<SaleStaleException>()));
      expect((await third).customerPaysCentavos, 2070);
      expect((await other).totalCentavos, 1410);
    });
  });

  test('correction rejections are recognized by server reason only', () {
    SaleRejectedException rejected(
      String code,
      String message, [
      String? reason,
    ]) => SaleRejectedException(code: code, message: message, reason: reason);
    const String window = 'sale is outside the correction window';
    const String over = 'return exceeds the remaining sold quantity';

    final List<(SaleRejectedException, bool, bool, bool)> cases = [
      (
        rejected(
          'failed-precondition',
          'insufficient stock',
          'insufficient-stock',
        ),
        true,
        false,
        false,
      ),
      (
        rejected('failed-precondition', window, 'correction-window-closed'),
        false,
        true,
        false,
      ),
      (rejected('out-of-range', over, 'over-return'), false, false, true),
      // The English message alone no longer identifies the rule.
      (
        rejected('failed-precondition', 'insufficient stock'),
        false,
        false,
        false,
      ),
      (rejected('failed-precondition', window), false, false, false),
      (rejected('out-of-range', over), false, false, false),
      (
        rejected('out-of-range', 'exchange calculation exceeds safe bounds'),
        false,
        false,
        false,
      ),
      // A reason under another code is not that rule either.
      (
        rejected(
          'invalid-argument',
          'insufficient stock',
          'insufficient-stock',
        ),
        false,
        false,
        false,
      ),
      (
        rejected('not-found', window, 'correction-window-closed'),
        false,
        false,
        false,
      ),
      (
        rejected('failed-precondition', over, 'over-return'),
        false,
        false,
        false,
      ),
    ];
    for (final (
          SaleRejectedException error,
          bool stock,
          bool closed,
          bool overReturn,
        )
        in cases) {
      expect(
        error.isOutOfStock,
        stock,
        reason: '${error.code} ${error.reason}',
      );
      expect(
        error.isOutsideCorrectionWindow,
        closed,
        reason: '${error.code} ${error.reason}',
      );
      expect(
        error.isOverReturn,
        overReturn,
        reason: '${error.code} ${error.reason}',
      );
      expect(error.isFolioAmbiguous, isFalse);
    }
  });

  test('a malformed submit keeps its original error as the cause', () async {
    final EmulatorCorrectionGateway gateway = _gateway(
      returnInvoke: (_) async => <String, Object?>{
        'receipt': returnReceiptJson(),
        'replayed': 'no',
      }.cast<String, bool>(),
    );
    try {
      await gateway.submitReturn(returnDraft());
      fail('expected an uncertain result');
    } on CorrectionUncertainException catch (error) {
      expect(error, isA<SaleUncertainException>());
      expect(error.cause, isA<TypeError>());
      expect(error.stackTrace.toString(), isNotEmpty);
    }
    try {
      await _gateway(
        returnInvoke: (_) async => <String, Object?>{'receipt': null},
      ).submitReturn(returnDraft());
      fail('expected an uncertain result');
    } on CorrectionUncertainException catch (error) {
      expect(error.cause, isA<CorrectionProtocolException>());
    }
  });
}
