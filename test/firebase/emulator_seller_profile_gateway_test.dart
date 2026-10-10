import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/firebase/emulator_seller_profile_gateway.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../movements/movement_fixtures.dart';

void main() {
  late List<String> events;
  late EmulatorSession? current;

  EmulatorSellerProfileGateway gateway(SaleCallable invoke) {
    return EmulatorSellerProfileGateway(
      expectedSession: movementsAdministrator,
      sessionChecker: () async {
        events.add('session');
        return current;
      },
      invoke: invoke,
    );
  }

  setUp(() {
    events = <String>[];
    current = movementsAdministrator;
  });

  test(
    'sends exactly {uid, displayName} between administrator checks',
    () async {
      final SellerProfileResult result = await gateway((
        Map<String, Object?> request,
      ) async {
        events.add('call');
        expect(request, <String, Object?>{'uid': 'u-1', 'displayName': 'Ana'});
        return <String, Object?>{'uid': 'u-1', 'replayed': true};
      }).setSellerProfile(uid: 'u-1', displayName: 'Ana');
      expect(result.uid, 'u-1');
      expect(result.replayed, isTrue);
      expect(events, <String>['session', 'call', 'session']);
    },
  );

  test(
    'refuses before calling when the session is not the administrator',
    () async {
      current = movementsSeller;
      await expectLater(
        gateway((_) async {
          events.add('call');
          return null;
        }).setSellerProfile(uid: 'u-1', displayName: 'Ana'),
        throwsA(isA<SellerProfileSessionException>()),
      );
      expect(events, <String>['session']);
    },
  );

  test('a session lost during the call is uncertain', () async {
    await expectLater(
      gateway((_) async {
        current = null;
        return <String, Object?>{'uid': 'u-1', 'replayed': false};
      }).setSellerProfile(uid: 'u-1', displayName: 'Ana'),
      throwsA(isA<SellerProfileUncertainException>()),
    );
  });

  test('maps whitelisted codes and reasons to rejections', () async {
    Future<Object> failure(String code, [String? reason]) async {
      try {
        await gateway((_) async {
          throw SaleCallableException(code: code, message: 'm', reason: reason);
        }).setSellerProfile(uid: 'u-1', displayName: 'Ana');
      } catch (error) {
        return error;
      }
      fail('expected a failure');
    }

    for (final String reason in <String>[
      'not-a-seller',
      'invalid-branch-claim',
      'invalid-stored-profile',
    ]) {
      final Object error = await failure('failed-precondition', reason);
      expect(error, isA<SellerProfileRejectedException>());
      expect((error as SellerProfileRejectedException).reason, reason);
    }
    final Object unknownReason = await failure('failed-precondition', 'other');
    expect((unknownReason as SellerProfileRejectedException).reason, isNull);
    for (final String code in <String>[
      'invalid-argument',
      'unauthenticated',
      'permission-denied',
      'not-found',
    ]) {
      final Object error = await failure(code);
      expect(error, isA<SellerProfileRejectedException>());
      expect((error as SellerProfileRejectedException).code, code);
    }
    expect(await failure('internal'), isA<SellerProfileUncertainException>());
    expect(
      await failure('unavailable'),
      isA<SellerProfileUncertainException>(),
    );
  });

  test('transport failures and malformed responses are uncertain', () async {
    await expectLater(
      gateway((_) async => throw StateError('socket'))
          .setSellerProfile(uid: 'u-1', displayName: 'Ana'),
      throwsA(isA<SellerProfileUncertainException>()),
    );
    for (final Object? response in <Object?>[
      null,
      <String, Object?>{'uid': 'other', 'replayed': false},
      <String, Object?>{'uid': 'u-1', 'replayed': 'no'},
      <String, Object?>{'uid': 'u-1', 'replayed': false, 'branchId': 'x'},
    ]) {
      await expectLater(
        gateway((_) async => response)
            .setSellerProfile(uid: 'u-1', displayName: 'Ana'),
        throwsA(isA<SellerProfileUncertainException>()),
        reason: '$response',
      );
    }
  });

  test('a superseded call is stale', () async {
    final Completer<Object?> first = Completer<Object?>();
    int calls = 0;
    final EmulatorSellerProfileGateway shared = gateway((_) {
      calls += 1;
      return calls == 1
          ? first.future
          : Future<Object?>.value(<String, Object?>{
              'uid': 'u-1',
              'replayed': false,
            });
    });
    final Future<SellerProfileResult> older = shared.setSellerProfile(
      uid: 'u-1',
      displayName: 'Ana',
    );
    await pumpEventQueue();
    await shared.setSellerProfile(uid: 'u-1', displayName: 'Bea');
    first.complete(<String, Object?>{'uid': 'u-1', 'replayed': false});
    await expectLater(older, throwsA(isA<SellerProfileStaleException>()));
  });

  test('rejects invalid names locally without calling', () async {
    await expectLater(
      gateway((_) async {
        events.add('call');
        return null;
      }).setSellerProfile(uid: 'u-1', displayName: '  '),
      throwsA(isA<SellerProfileRejectedException>()),
    );
    expect(events, isNot(contains('call')));
  });
}
