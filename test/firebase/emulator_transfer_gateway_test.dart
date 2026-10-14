import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/firebase/emulator_transfer_gateway.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

TransferDraft _draft() => TransferDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  sourceBranchId: 'branch-north',
  destinationBranchId: 'branch-south',
  lines: <TransferLine>[
    TransferLine(
      productId: 'DEMO-RIBBON',
      quantity: '2.50',
      quantitySpec: QuantitySpec(unit: 'meter', precision: 2),
    ),
  ],
);

Map<String, Object?> _result(TransferDraft request, {bool replayed = false}) =>
    <String, Object?>{
      'transferId': request.idempotencyKey,
      'sourceBranchId': request.sourceBranchId,
      'destinationBranchId': request.destinationBranchId,
      'occurredAt': 1767225600000,
      'lines': <Object?>[
        <String, Object?>{
          'productId': 'DEMO-RIBBON',
          'quantity': '2.50',
          'quantityScaled': 250,
          'unit': 'meter',
          'precision': 2,
          'sourceQuantityScaled': 500,
          'destinationQuantityScaled': 750,
        },
      ],
      'replayed': replayed,
    };

void main() {
  test(
    'checks exact administrator twice around the await and sends exact payload',
    () async {
      final List<String> events = <String>[];
      final TransferDraft draft = _draft();
      final EmulatorTransferGateway gateway = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async {
          events.add('session');
          return _administrator;
        },
        invoke: (Map<String, Object?> request) async {
          events.add('call');
          expect(request, draft.toRequest());
          return _result(draft);
        },
      );

      final TransferResult result = await gateway.submitTransfer(draft);
      expect(events, <String>['session', 'call', 'session']);
      expect(result.transferId, draft.idempotencyKey);
      expect(result.sourceBranchId, 'branch-north');
      expect(result.destinationBranchId, 'branch-south');
      expect(result.occurredAt, 1767225600000);
      expect(result.replayed, isFalse);
      expect(result.lines.single.quantityScaled, 250);
      expect(result.lines.single.sourceQuantityScaled, 500);
      expect(result.lines.single.destinationQuantityScaled, 750);
    },
  );

  test('accepts a deterministic replay of the same payload', () async {
    final TransferDraft draft = _draft();
    final EmulatorTransferGateway gateway = EmulatorTransferGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) async => _result(draft, replayed: true),
    );

    expect((await gateway.submitTransfer(draft)).replayed, isTrue);
  });

  test(
    'sends nothing for null, seller, branch admin, or changed uid',
    () async {
      final TransferDraft draft = _draft();
      final List<EmulatorSession?> currents = <EmulatorSession?>[
        null,
        _seller,
        const EmulatorSession(
          userId: 'administrator-1',
          email: 'admin@demo.invalid',
          role: InventoryRole.administrator,
          branchId: 'branch-north',
        ),
        const EmulatorSession(
          userId: 'administrator-2',
          email: 'other@demo.invalid',
          role: InventoryRole.administrator,
        ),
      ];

      for (final EmulatorSession? current in currents) {
        var invoked = false;
        final EmulatorTransferGateway gateway = EmulatorTransferGateway(
          expectedSession: _administrator,
          sessionChecker: () async => current,
          invoke: (_) async {
            invoked = true;
            return _result(draft);
          },
        );
        await expectLater(
          gateway.submitTransfer(draft),
          throwsA(isA<TransferSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test(
    'refuses expected sessions that are not branch-less administrators',
    () async {
      final TransferDraft draft = _draft();
      final List<EmulatorSession> expected = <EmulatorSession>[
        _seller,
        const EmulatorSession(
          userId: 'administrator-1',
          email: 'admin@demo.invalid',
          role: InventoryRole.administrator,
          branchId: 'branch-north',
        ),
      ];

      for (final EmulatorSession session in expected) {
        var invoked = false;
        final EmulatorTransferGateway gateway = EmulatorTransferGateway(
          expectedSession: session,
          sessionChecker: () async => _administrator,
          invoke: (_) async {
            invoked = true;
            return _result(draft);
          },
        );
        await expectLater(
          gateway.submitTransfer(draft),
          throwsA(isA<TransferSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test(
    'rechecks role and null branch after await, never reports success',
    () async {
      final TransferDraft draft = _draft();
      var checks = 0;
      final EmulatorTransferGateway roleChanged = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async {
          checks += 1;
          return checks == 1
              ? _administrator
              : const EmulatorSession(
                  userId: 'administrator-1',
                  email: 'admin@demo.invalid',
                  role: InventoryRole.seller,
                  branchId: 'branch-north',
                );
        },
        invoke: (_) async => _result(draft),
      );

      await expectLater(
        roleChanged.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );

      var branchChecks = 0;
      final EmulatorTransferGateway branchAdded = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async {
          branchChecks += 1;
          return branchChecks == 1
              ? _administrator
              : const EmulatorSession(
                  userId: 'administrator-1',
                  email: 'admin@demo.invalid',
                  role: InventoryRole.administrator,
                  branchId: 'branch-north',
                );
        },
        invoke: (_) async => _result(draft),
      );
      await expectLater(
        branchAdded.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );
      expect(branchChecks, 2);

      var secondChecks = 0;
      final EmulatorTransferGateway signedOut = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async {
          secondChecks += 1;
          return secondChecks == 1 ? _administrator : null;
        },
        invoke: (_) async => _result(draft),
      );
      await expectLater(
        signedOut.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );
      expect(secondChecks, 2);
    },
  );

  test(
    'maps only pre-write domain codes to deterministic rejections',
    () async {
      final TransferDraft draft = _draft();
      for (final String code in <String>[
        'unauthenticated',
        'permission-denied',
        'invalid-argument',
        'not-found',
        'failed-precondition',
        'out-of-range',
        'already-exists',
      ]) {
        final EmulatorTransferGateway gateway = EmulatorTransferGateway(
          expectedSession: _administrator,
          sessionChecker: () async => _administrator,
          invoke: (_) => throw TransferCallableException(code: code),
        );
        await expectLater(
          gateway.submitTransfer(draft),
          throwsA(
            isA<TransferRejectedException>().having(
              (TransferRejectedException error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
    },
  );

  test('keeps transport, internal, and malformed outcomes uncertain', () async {
    final TransferDraft draft = _draft();
    final List<Object> failures = <Object>[
      const TransferCallableException(code: 'internal'),
      const TransferCallableException(code: 'unavailable'),
      const TransferCallableException(code: 'unknown'),
      const TransferCallableException(code: 'data-loss'),
      const TransferCallableException(code: 'resource-exhausted'),
      const TransferCallableException(code: 'cancelled'),
      const TransferCallableException(code: 'deadline-exceeded'),
      StateError('non-SDK transport detail'),
    ];

    for (final Object failure in failures) {
      final EmulatorTransferGateway gateway = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (_) => throw failure,
      );
      await expectLater(
        gateway.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );
    }

    for (final Object? payload in <Object?>[
      null,
      'transferred',
      <String, Object?>{},
      <String, Object?>{..._result(draft), 'transferId': 'other-key'},
      <String, Object?>{..._result(draft), 'lines': <Object?>[]},
    ]) {
      final EmulatorTransferGateway gateway = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (_) async => payload,
      );
      await expectLater(
        gateway.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );
    }
  });

  test('newer submission makes late old results and errors stale', () async {
    final TransferDraft draft = _draft();
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorTransferGateway success = EmulatorTransferGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) {
        calls += 1;
        return calls == 1
            ? first.future
            : Future<Object?>.value(_result(draft));
      },
    );

    final Future<TransferResult> old = success.submitTransfer(draft);
    final TransferResult current = await success.submitTransfer(draft);
    first.complete(_result(draft));

    expect(current.transferId, draft.idempotencyKey);
    await expectLater(old, throwsA(isA<TransferStaleException>()));

    final Completer<Object?> rejected = Completer<Object?>();
    var rejectedCalls = 0;
    final EmulatorTransferGateway failure = EmulatorTransferGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) {
        rejectedCalls += 1;
        return rejectedCalls == 1
            ? rejected.future
            : Future<Object?>.value(_result(draft));
      },
    );

    final Future<TransferResult> oldFailure = failure.submitTransfer(draft);
    await failure.submitTransfer(draft);
    rejected.completeError(TransferCallableException(code: 'invalid-argument'));
    await expectLater(oldFailure, throwsA(isA<TransferStaleException>()));
  });

  test('unresolved retry keeps the frozen payload and the same key', () async {
    final TransferDraft draft = _draft();
    final TransferDraftStore store = TransferDraftStore();
    final TransferAttempt attempt = await store.begin(
      ownerUserId: _administrator.userId,
      draft: draft,
    );

    final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
    final EmulatorTransferGateway gateway = EmulatorTransferGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (Map<String, Object?> request) async {
        sent.add(request);
        if (sent.length == 1) throw StateError('connection reset');
        return _result(draft, replayed: true);
      },
    );

    // Mirrors the lifecycle AF-02 must follow: uncertain retains, settled clears.
    Future<TransferResult> submit(TransferAttempt target) async {
      try {
        final TransferResult result = await gateway.submitTransfer(
          target.draft,
        );
        await store.resolve(target);
        return result;
      } on TransferRejectedException {
        await store.resolve(target);
        rethrow;
      } on TransferUncertainException {
        store.retain(target);
        rethrow;
      }
    }

    await expectLater(
      submit(attempt),
      throwsA(isA<TransferUncertainException>()),
    );
    expect(
      store.unresolvedFor(_administrator.userId, draft.idempotencyKey),
      draft,
    );

    // Navigation away and back resolves the same frozen payload under the same
    // key, so the retry can never fork a second transfer.
    final TransferAttempt retry = await store.begin(
      ownerUserId: _administrator.userId,
      draft: store.unresolvedFor(_administrator.userId, draft.idempotencyKey)!,
    );
    final TransferResult replayed = await submit(retry);

    expect(replayed.replayed, isTrue);
    expect(sent, hasLength(2));
    expect(sent.first, sent.last);
    expect(
      store.unresolvedFor(_administrator.userId, draft.idempotencyKey),
      isNull,
    );
    expect(store.unresolvedByOwner(_administrator.userId), isEmpty);
  });

  test('deterministic rejection clears the stored payload', () async {
    final TransferDraft draft = _draft();
    final TransferDraftStore store = TransferDraftStore();
    final TransferAttempt attempt = await store.begin(
      ownerUserId: _administrator.userId,
      draft: draft,
    );
    final EmulatorTransferGateway gateway = EmulatorTransferGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) =>
          throw const TransferCallableException(code: 'invalid-argument'),
    );

    await expectLater(
      gateway.submitTransfer(attempt.draft),
      throwsA(isA<TransferRejectedException>()),
    );
    expect(await store.resolve(attempt), isTrue);
    expect(store.unresolvedByOwner(_administrator.userId), isEmpty);
  });

  group('transferCallableFromInvoker', () {
    test(
      'returns the callable data unchanged and forwards the payload',
      () async {
        final Object data = <String, Object?>{
          'transferId': _draft().idempotencyKey,
        };
        Map<String, Object?>? seen;
        final TransferCallable callable = transferCallableFromInvoker((
          Map<String, Object?> request,
        ) async {
          seen = request;
          return data;
        });

        expect(
          await callable(<String, Object?>{'idempotencyKey': 'k'}),
          same(data),
        );
        expect(seen, <String, Object?>{'idempotencyKey': 'k'});
      },
    );

    test(
      'maps SDK failures on the exact code and passes others through',
      () async {
        for (final String code in <String>[
          'failed-precondition',
          'permission-denied',
          'unauthenticated',
          'invalid-argument',
          'not-found',
          'out-of-range',
          'already-exists',
          'internal',
          'unavailable',
          'unknown',
        ]) {
          final TransferCallable callable = transferCallableFromInvoker(
            (_) =>
                throw _FunctionsException(code: code, message: 'server text'),
          );
          await expectLater(
            callable(<String, Object?>{}),
            throwsA(
              isA<TransferCallableException>().having(
                (TransferCallableException error) => error.code,
                'code',
                code,
              ),
            ),
            reason: 'code $code must survive the adapter',
          );
        }

        final StateError failure = StateError('transport');
        final TransferCallable passthrough = transferCallableFromInvoker(
          (_) => throw failure,
        );
        await expectLater(
          passthrough(<String, Object?>{}),
          throwsA(same(failure)),
        );
      },
    );

    test('null server message still maps to the exact code', () async {
      final TransferCallable callable = transferCallableFromInvoker(
        (_) => throw _FunctionsException(code: 'unavailable', message: null),
      );
      await expectLater(
        callable(<String, Object?>{}),
        throwsA(
          isA<TransferCallableException>().having(
            (TransferCallableException error) => error.code,
            'code',
            'unavailable',
          ),
        ),
      );
    });

    test('adapter keeps the gateway classification end to end', () async {
      final TransferDraft draft = _draft();

      final EmulatorTransferGateway rejected = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: transferCallableFromInvoker(
          (_) => throw _FunctionsException(
            code: 'failed-precondition',
            message: 'source branch does not hold enough stock',
          ),
        ),
      );
      await expectLater(
        rejected.submitTransfer(draft),
        throwsA(
          isA<TransferRejectedException>().having(
            (TransferRejectedException error) => error.code,
            'code',
            'failed-precondition',
          ),
        ),
      );

      final EmulatorTransferGateway uncertain = EmulatorTransferGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: transferCallableFromInvoker(
          (_) => throw _FunctionsException(code: 'internal', message: null),
        ),
      );
      await expectLater(
        uncertain.submitTransfer(draft),
        throwsA(isA<TransferUncertainException>()),
      );
    });
  });
}

class _FunctionsException extends FirebaseFunctionsException {
  _FunctionsException({required super.code, required String? message})
    : _message = message,
      super(message: message ?? '');

  final String? _message;

  @override
  String? get message => _message;
}
