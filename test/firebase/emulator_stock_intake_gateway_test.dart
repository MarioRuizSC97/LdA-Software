import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';
import 'package:lda_inventory/firebase/emulator_stock_intake_gateway.dart';

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
const StockIntakeDraft _draft = StockIntakeDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  branchId: 'branch-north',
  productId: 'DEMO-RIBBON',
  quantity: '2.50',
  unitCostMxn: '12.30',
  quantitySpec: StockIntakeQuantitySpec(unit: 'meter', precision: 2),
);

Map<String, Object?> _success({bool replayed = false}) => <String, Object?>{
  'entryId': _draft.idempotencyKey,
  'movementId': _draft.idempotencyKey,
  'quantityScaled': 250,
  'stockQuantityScaled': 250,
  'unitCostCentavos': 1230,
  'lineTotalCentavos': 3075,
  'replayed': replayed,
};

void main() {
  test(
    'forces exact administrator checks before and after callable await',
    () async {
      final List<String> events = <String>[];
      final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
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

      final StockIntakeResult result = await gateway.submitIntake(_draft);
      expect(result.entryId, _draft.idempotencyKey);
      expect(result.movementId, _draft.idempotencyKey);
      expect(result.quantityScaled, 250);
      expect(result.stockQuantityScaled, 250);
      expect(result.unitCostCentavos, 1230);
      expect(result.lineTotalCentavos, 3075);
      expect(result.replayed, isFalse);
      expect(events, <String>['session', 'call', 'session']);
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
        final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
          expectedSession: _administrator,
          sessionChecker: () async => current,
          invoke: (_) async {
            invoked = true;
            return _success();
          },
        );
        await expectLater(
          gateway.submitIntake(_draft),
          throwsA(isA<StockIntakeSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test(
    'post-await session failure makes even a valid result uncertain',
    () async {
      var checks = 0;
      final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
        expectedSession: _administrator,
        sessionChecker: () async => checks++ == 0 ? _administrator : null,
        invoke: (_) async => _success(),
      );

      await expectLater(
        gateway.submitIntake(_draft),
        throwsA(isA<StockIntakeUncertainException>()),
      );
    },
  );

  test(
    'classifies only verified deterministic callable codes as rejections',
    () async {
      for (final String code in <String>[
        'unauthenticated',
        'permission-denied',
        'invalid-argument',
        'not-found',
        'out-of-range',
        'already-exists',
      ]) {
        final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
          expectedSession: _administrator,
          sessionChecker: () async => _administrator,
          invoke: (_) => throw StockIntakeCallableException(code: code),
        );
        await expectLater(
          gateway.submitIntake(_draft),
          throwsA(
            isA<StockIntakeRejectedException>().having(
              (StockIntakeRejectedException error) => error.code,
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
        const StockIntakeCallableException(code: 'failed-precondition'),
        const StockIntakeCallableException(code: 'cancelled'),
        const StockIntakeCallableException(code: 'deadline-exceeded'),
        const StockIntakeCallableException(code: 'internal'),
        const StockIntakeCallableException(code: 'unavailable'),
        const StockIntakeCallableException(code: 'unknown'),
        StateError('non-SDK transport detail'),
      ]) {
        final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
          expectedSession: _administrator,
          sessionChecker: () async => _administrator,
          invoke: (_) => throw failure,
        );
        await expectLater(
          gateway.submitIntake(_draft),
          throwsA(isA<StockIntakeUncertainException>()),
        );
      }

      final EmulatorStockIntakeGateway malformed = EmulatorStockIntakeGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (_) async => <String, Object?>{
          ..._success(),
          'entryId': 'wrong',
        },
      );
      await expectLater(
        malformed.submitIntake(_draft),
        throwsA(isA<StockIntakeUncertainException>()),
      );

      final EmulatorStockIntakeGateway replayed = EmulatorStockIntakeGateway(
        expectedSession: _administrator,
        sessionChecker: () async => _administrator,
        invoke: (_) async => _success(replayed: true),
      );
      expect((await replayed.submitIntake(_draft)).replayed, isTrue);
    },
  );

  test('newer attempt invalidates late old success', () async {
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorStockIntakeGateway gateway = EmulatorStockIntakeGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) {
        calls += 1;
        return calls == 1 ? first.future : Future<Object?>.value(_success());
      },
    );

    final Future<StockIntakeResult> old = gateway.submitIntake(_draft);
    final StockIntakeResult current = await gateway.submitIntake(_draft);
    first.complete(_success());

    expect(current.entryId, _draft.idempotencyKey);
    await expectLater(old, throwsA(isA<StockIntakeStaleException>()));
  });
}
