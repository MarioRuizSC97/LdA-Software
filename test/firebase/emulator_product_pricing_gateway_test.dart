import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/firebase/emulator_product_pricing_gateway.dart';

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
const ProductPricingDraft _draft = ProductPricingDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  productId: 'PRD-COFFEE-001',
  listedPriceMxn: '129.00',
  priceMode: 'iva-included',
  ivaTreatment: 'taxable',
  ivaRatePercent: '16',
);

Map<String, Object?> _success({bool replayed = false}) => <String, Object?>{
  'auditId': _draft.idempotencyKey,
  'productId': _draft.productId,
  'pricing': <String, Object?>{
    'listedPriceCentavos': 12900,
    'currency': 'MXN',
    'priceMode': 'iva-included',
    'ivaTreatment': 'taxable',
    'ivaRateBasisPoints': 1600,
  },
  'replayed': replayed,
};

void main() {
  test(
    'forces exact administrator checks before and after callable await',
    () async {
      final List<String> events = <String>[];
      final EmulatorProductPricingGateway gateway =
          EmulatorProductPricingGateway(
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

      expect((await gateway.setPrice(_draft)).auditId, _draft.idempotencyKey);
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
        final EmulatorProductPricingGateway gateway =
            EmulatorProductPricingGateway(
              expectedSession: _administrator,
              sessionChecker: () async => current,
              invoke: (_) async {
                invoked = true;
                return _success();
              },
            );
        await expectLater(
          gateway.setPrice(_draft),
          throwsA(isA<ProductPricingSessionException>()),
        );
        expect(invoked, isFalse);
      }
    },
  );

  test(
    'post-await session failure makes even a valid result uncertain',
    () async {
      var checks = 0;
      final EmulatorProductPricingGateway gateway =
          EmulatorProductPricingGateway(
            expectedSession: _administrator,
            sessionChecker: () async => checks++ == 0 ? _administrator : null,
            invoke: (_) async => _success(),
          );

      await expectLater(
        gateway.setPrice(_draft),
        throwsA(isA<ProductPricingUncertainException>()),
      );
    },
  );

  test(
    'classifies only verified prewrite server paths as deterministic',
    () async {
      for (final String code in <String>[
        'invalid-argument',
        'out-of-range',
        'unauthenticated',
        'permission-denied',
        'not-found',
        'already-exists',
      ]) {
        final EmulatorProductPricingGateway gateway =
            EmulatorProductPricingGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw ProductPricingCallableException(code: code),
            );
        await expectLater(
          gateway.setPrice(_draft),
          throwsA(
            isA<ProductPricingRejectedException>().having(
              (ProductPricingRejectedException error) => error.code,
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
        const ProductPricingCallableException(code: 'failed-precondition'),
        const ProductPricingCallableException(code: 'cancelled'),
        const ProductPricingCallableException(code: 'deadline-exceeded'),
        const ProductPricingCallableException(code: 'internal'),
        const ProductPricingCallableException(code: 'unavailable'),
        const ProductPricingCallableException(code: 'unknown'),
        StateError('non-SDK transport detail'),
      ]) {
        final EmulatorProductPricingGateway gateway =
            EmulatorProductPricingGateway(
              expectedSession: _administrator,
              sessionChecker: () async => _administrator,
              invoke: (_) => throw failure,
            );
        await expectLater(
          gateway.setPrice(_draft),
          throwsA(isA<ProductPricingUncertainException>()),
        );
      }

      final EmulatorProductPricingGateway malformed =
          EmulatorProductPricingGateway(
            expectedSession: _administrator,
            sessionChecker: () async => _administrator,
            invoke: (_) async => <String, Object?>{
              ..._success(),
              'auditId': 'wrong',
            },
          );
      await expectLater(
        malformed.setPrice(_draft),
        throwsA(isA<ProductPricingUncertainException>()),
      );
    },
  );

  test('newer attempt invalidates late old success', () async {
    final Completer<Object?> first = Completer<Object?>();
    var calls = 0;
    final EmulatorProductPricingGateway gateway = EmulatorProductPricingGateway(
      expectedSession: _administrator,
      sessionChecker: () async => _administrator,
      invoke: (_) {
        calls += 1;
        return calls == 1 ? first.future : Future<Object?>.value(_success());
      },
    );

    final Future<ProductPricingResult> old = gateway.setPrice(_draft);
    final ProductPricingResult current = await gateway.setPrice(_draft);
    first.complete(_success());

    expect(current.productId, _draft.productId);
    await expectLater(old, throwsA(isA<ProductPricingStaleException>()));
  });
}
