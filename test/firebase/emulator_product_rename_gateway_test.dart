import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/product_rename.dart';
import 'package:lda_inventory/firebase/emulator_product_rename_gateway.dart';

/// A local SDK double: constructing the exception needs no Firebase init.
class _FunctionsException extends FirebaseFunctionsException {
  _FunctionsException({required super.code}) : super(message: 'server detail');
}

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
const ProductRenameDraft _draft = ProductRenameDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  productId: 'PRD-COFFEE-001',
  name: 'Café de especialidad 1 kg',
);

Map<String, Object?> _success({bool replayed = false}) => <String, Object?>{
  'productId': _draft.productId,
  'oldName': 'Café molido',
  'newName': _draft.name,
  'replayed': replayed,
};

void main() {
  test('validates, guards session before and after the callable, and passes '
      'the exact request', () async {
    final List<String> events = <String>[];
    final EmulatorProductRenameGateway gateway = EmulatorProductRenameGateway(
      expectedSession: _administrator,
      sessionChecker: () async {
        events.add('session');
        return _administrator;
      },
      invoke: (Map<String, Object?> request) async {
        events.add('call');
        expect(request, _draft.toRequest());
        return _success();
      },
    );

    final ProductRenameResult result = await gateway.renameProduct(_draft);
    expect(result.newName, _draft.name);
    expect(result.replayed, isFalse);
    expect(events, <String>['session', 'call', 'session']);
  });

  test(
    'rejects invalid drafts before any session check or network call',
    () async {
      var checked = false;
      var invoked = false;
      final EmulatorProductRenameGateway gateway = EmulatorProductRenameGateway(
        expectedSession: _administrator,
        sessionChecker: () async {
          checked = true;
          return _administrator;
        },
        invoke: (_) async {
          invoked = true;
          return _success();
        },
      );

      await expectLater(
        gateway.renameProduct(_draft.copyWith(name: ' padding')),
        throwsA(isA<ProductRenameValidationException>()),
      );
      expect(checked, isFalse);
      expect(invoked, isFalse);
    },
  );

  test(
    'fails before network for null, seller, branch admin, or changed uid',
    () async {
      for (final EmulatorSession? current in <EmulatorSession?>[
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
      ]) {
        var invoked = false;
        final EmulatorProductRenameGateway gateway =
            EmulatorProductRenameGateway(
              expectedSession: _administrator,
              sessionChecker: () async => current,
              invoke: (_) async {
                invoked = true;
                return _success();
              },
            );
        await expectLater(
          gateway.renameProduct(_draft),
          throwsA(isA<ProductRenameSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test(
    'post-await session failure makes even a valid result uncertain',
    () async {
      var checks = 0;
      final EmulatorProductRenameGateway gateway = EmulatorProductRenameGateway(
        expectedSession: _administrator,
        sessionChecker: () async => checks++ == 0 ? _administrator : null,
        invoke: (_) async => _success(),
      );

      await expectLater(
        gateway.renameProduct(_draft),
        throwsA(isA<ProductRenameUncertainException>()),
      );
    },
  );

  test(
    'classifies only verified prewrite server paths as deterministic',
    () async {
      for (final String code in <String>[
        'invalid-argument',
        'unauthenticated',
        'permission-denied',
        'not-found',
        'already-exists',
      ]) {
        final EmulatorProductRenameGateway gateway =
            EmulatorProductRenameGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw ProductRenameCallableException(code: code),
            );
        await expectLater(
          gateway.renameProduct(_draft),
          throwsA(
            isA<ProductRenameRejectedException>().having(
              (ProductRenameRejectedException error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
    },
  );

  test(
    'failed-precondition and transport/protocol failures stay uncertain',
    () async {
      for (final Object failure in <Object>[
        const ProductRenameCallableException(code: 'failed-precondition'),
        const ProductRenameCallableException(code: 'cancelled'),
        const ProductRenameCallableException(code: 'deadline-exceeded'),
        const ProductRenameCallableException(code: 'internal'),
        const ProductRenameCallableException(code: 'unavailable'),
        const ProductRenameCallableException(code: 'unknown'),
        StateError('non-SDK transport detail'),
      ]) {
        final EmulatorProductRenameGateway gateway =
            EmulatorProductRenameGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw failure,
            );
        await expectLater(
          gateway.renameProduct(_draft),
          throwsA(isA<ProductRenameUncertainException>()),
        );
      }

      final EmulatorProductRenameGateway unbound = EmulatorProductRenameGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (_) async => <String, Object?>{
          ..._success(),
          'newName': 'Otro nombre',
        },
      );
      await expectLater(
        unbound.renameProduct(_draft),
        throwsA(isA<ProductRenameUncertainException>()),
      );
    },
  );

  test('newer attempt invalidates late old success', () async {
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorProductRenameGateway gateway = EmulatorProductRenameGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) {
        calls += 1;
        return calls == 1 ? first.future : Future<Object?>.value(_success());
      },
    );

    final Future<ProductRenameResult> old = gateway.renameProduct(_draft);
    final ProductRenameResult current = await gateway.renameProduct(_draft);
    first.complete(_success());

    expect(current.productId, _draft.productId);
    await expectLater(old, throwsA(isA<ProductRenameStaleException>()));
  });

  test(
    'a retry with the same draft reuses the same idempotency key request',
    () async {
      final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
      var calls = 0;
      final EmulatorProductRenameGateway gateway = EmulatorProductRenameGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (Map<String, Object?> request) async {
          requests.add(Map<String, Object?>.of(request));
          calls += 1;
          return _success(replayed: calls > 1);
        },
      );

      final ProductRenameResult firstAttempt = await gateway.renameProduct(
        _draft,
      );
      final ProductRenameResult retry = await gateway.renameProduct(_draft);

      expect(requests, <Map<String, Object?>>[
        _draft.toRequest(),
        _draft.toRequest(),
      ]);
      expect(requests.first, requests.last);
      expect(firstAttempt.replayed, isFalse);
      expect(retry.replayed, isTrue);
      expect(retry.newName, _draft.name);
    },
  );

  test('maps FirebaseFunctionsException codes without parsing messages', () {
    final ProductRenameCallable callable = productRenameCallableFromInvoker(
      (Map<String, Object?> request) async =>
          throw _FunctionsException(code: 'permission-denied'),
    );

    expect(
      callable(_draft.toRequest()),
      throwsA(
        isA<ProductRenameCallableException>().having(
          (ProductRenameCallableException error) => error.code,
          'code',
          'permission-denied',
        ),
      ),
    );
  });

  test('propagates non-SDK failures untouched', () async {
    final ProductRenameCallable callable = productRenameCallableFromInvoker(
      (Map<String, Object?> request) async => throw StateError('boom'),
    );

    await expectLater(callable(_draft.toRequest()), throwsStateError);
  });

  test('passes successful raw payloads through untouched', () async {
    final ProductRenameCallable callable = productRenameCallableFromInvoker(
      (Map<String, Object?> request) async => _success(),
    );

    expect(await callable(_draft.toRequest()), _success());
  });
}
