import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/firebase/emulator_product_creation_gateway.dart';

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
const ProductCreationDraft _draft = ProductCreationDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  name: 'Coffee',
  unit: 'kg',
  precision: 2,
);

void main() {
  test(
    'refreshes and validates the exact administrator before and after await',
    () async {
      final List<String> events = <String>[];
      final EmulatorProductCreationGateway gateway =
          EmulatorProductCreationGateway(
            expectedSession: _administrator,
            sessionChecker: () async {
              events.add('session');
              return _administrator;
            },
            invoke: (Map<String, Object?> request) async {
              events.add('call');
              expect(request, _draft.toRequest());
              return <String, Object?>{
                'productId': 'PRD-COFFEE-001',
                'internalCode': 'PRD-COFFEE-001',
                'replayed': false,
              };
            },
          );

      final ProductCreationResult result = await gateway.create(_draft);

      expect(result.internalCode, 'PRD-COFFEE-001');
      expect(events, <String>['session', 'call', 'session']);
    },
  );

  test(
    'fails closed before invocation for null, seller, branch, or changed uid',
    () async {
      for (final EmulatorSession? refreshed in <EmulatorSession?>[
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
        final EmulatorProductCreationGateway gateway =
            EmulatorProductCreationGateway(
              expectedSession: _administrator,
              sessionChecker: () async => refreshed,
              invoke: (_) async {
                invoked = true;
                return <String, Object?>{};
              },
            );

        await expectLater(
          gateway.create(_draft),
          throwsA(isA<ProductCreationSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test('suppresses callable success after logout or role change', () async {
    for (final EmulatorSession? after in <EmulatorSession?>[null, _seller]) {
      var checks = 0;
      final EmulatorProductCreationGateway gateway =
          EmulatorProductCreationGateway(
            expectedSession: _administrator,
            sessionChecker: () async => checks++ == 0 ? _administrator : after,
            invoke: (_) async => <String, Object?>{
              'productId': 'PRD-COFFEE-001',
              'internalCode': 'PRD-COFFEE-001',
              'replayed': false,
            },
          );

      await expectLater(
        gateway.create(_draft),
        throwsA(isA<ProductCreationSessionException>()),
      );
    }
  });

  test(
    'keeps verified pre-write and receipt-conflict rejections deterministic',
    () async {
      for (final String code in <String>[
        'invalid-argument',
        'unauthenticated',
        'permission-denied',
        'already-exists',
      ]) {
        final EmulatorProductCreationGateway gateway =
            EmulatorProductCreationGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw ProductCreationCallableException(code: code),
            );
        await expectLater(
          gateway.create(_draft),
          throwsA(
            isA<ProductCreationRejectedException>().having(
              (ProductCreationRejectedException error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }

      for (final String code in <String>[
        'cancelled',
        'deadline-exceeded',
        'failed-precondition',
        'internal',
        'unavailable',
        'unknown',
      ]) {
        final EmulatorProductCreationGateway gateway =
            EmulatorProductCreationGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw ProductCreationCallableException(code: code),
            );
        await expectLater(
          gateway.create(_draft),
          throwsA(isA<ProductCreationUncertainException>()),
        );
      }
    },
  );

  test('treats malformed success and non-SDK failures as uncertain', () async {
    for (final Future<Object?> Function(Map<String, Object?>) invoke
        in <Future<Object?> Function(Map<String, Object?>)>[
          (_) async => <String, Object?>{'unexpected': true},
          (_) => throw StateError('transport detail'),
        ]) {
      final EmulatorProductCreationGateway gateway =
          EmulatorProductCreationGateway(
            expectedSession: _administrator,
            sessionChecker: () async => _administrator,
            invoke: invoke,
          );
      await expectLater(
        gateway.create(_draft),
        throwsA(isA<ProductCreationUncertainException>()),
      );
    }
  });

  test(
    'a newer attempt invalidates a late completion from the old attempt',
    () async {
      final Completer<Object?> first = Completer<Object?>();
      var calls = 0;
      final EmulatorProductCreationGateway gateway =
          EmulatorProductCreationGateway(
            expectedSession: _administrator,
            sessionChecker: () async => _administrator,
            invoke: (_) {
              calls += 1;
              if (calls == 1) return first.future;
              return Future<Object?>.value(<String, Object?>{
                'productId': 'PRD-TEA-002',
                'internalCode': 'PRD-TEA-002',
                'replayed': false,
              });
            },
          );

      final Future<ProductCreationResult> stale = gateway.create(_draft);
      final ProductCreationResult current = await gateway.create(
        const ProductCreationDraft(
          idempotencyKey: 'second-key',
          name: 'Tea',
          unit: 'piece',
          precision: 0,
        ),
      );
      first.complete(<String, Object?>{
        'productId': 'PRD-COFFEE-001',
        'internalCode': 'PRD-COFFEE-001',
        'replayed': false,
      });

      expect(current.internalCode, 'PRD-TEA-002');
      await expectLater(stale, throwsA(isA<ProductCreationStaleException>()));
    },
  );
}
