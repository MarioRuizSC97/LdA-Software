import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

class _HostileError implements Exception {
  @override
  String toString() => throw StateError('must not inspect raw diagnostics');
}

Object _typeError() {
  try {
    final Object value = 'synthetic-private-value';
    return value as int;
  } catch (error) {
    return error;
  }
}

void main() {
  group('guard failure handling', () {
    test(
      'cleanup runs before rethrowing the original failure identity',
      () async {
        final Object original = _typeError();
        var signOutCalls = 0;
        await expectLater(
          EmulatorSessionGuard.validate(
            userId: 'uid',
            email: 'user@example.invalid',
            refreshClaims: () async => throw original,
            signOut: () async => signOutCalls += 1,
          ),
          throwsA(same(original)),
        );
        expect(signOutCalls, 1);
      },
    );

    test('failure handling never inspects hostile error contents', () async {
      // _HostileError.toString throws, so rethrowing the identical instance
      // proves no diagnostic or rendering path ever inspected the error.
      final Object original = _HostileError();
      await expectLater(
        EmulatorSessionGuard.validate(
          userId: 'uid',
          email: 'user@example.invalid',
          refreshClaims: () async => throw original,
          signOut: () async {},
        ),
        throwsA(same(original)),
      );
    });
  });

  group('EmulatorSessionClaims', () {
    test('accepts the exact administrator role without a branch', () {
      final EmulatorSession session = EmulatorSessionClaims.validate(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        claims: <String, Object?>{'role': 'administrator'},
      );

      expect(session.role, InventoryRole.administrator);
      expect(session.branchId, isNull);
    });

    test('accepts a seller only with a valid assigned branch', () {
      final EmulatorSession session = EmulatorSessionClaims.validate(
        userId: 'demo-local-seller-north',
        email: 'seller.north@demo-lda-inventory.invalid',
        claims: <String, Object?>{'role': 'seller', 'branchId': 'branch-north'},
      );

      expect(session.role, InventoryRole.seller);
      expect(session.branchId, 'branch-north');
    });

    test('rejects unknown roles and malformed role claims', () {
      for (final Object? role in <Object?>[null, true, 'owner', 'admin']) {
        expect(
          () => EmulatorSessionClaims.validate(
            userId: 'uid',
            email: 'user@example.invalid',
            claims: <String, Object?>{'role': role},
          ),
          throwsA(isA<UntrustedSessionException>()),
        );
      }
    });

    test('rejects missing seller branch and administrator branch claims', () {
      for (final Map<String, Object?> claims in <Map<String, Object?>>[
        <String, Object?>{'role': 'seller'},
        <String, Object?>{'role': 'seller', 'branchId': ''},
        <String, Object?>{'role': 'seller', 'branchId': 12},
        <String, Object?>{'role': 'administrator', 'branchId': 'branch-north'},
      ]) {
        expect(
          () => EmulatorSessionClaims.validate(
            userId: 'uid',
            email: 'user@example.invalid',
            claims: claims,
          ),
          throwsA(isA<UntrustedSessionException>()),
        );
      }
    });

    test('rejects identities without a usable id or email', () {
      expect(
        () => EmulatorSessionClaims.validate(
          userId: '',
          email: 'user@example.invalid',
          claims: <String, Object?>{'role': 'administrator'},
        ),
        throwsA(isA<UntrustedSessionException>()),
      );
      expect(
        () => EmulatorSessionClaims.validate(
          userId: 'uid',
          email: null,
          claims: <String, Object?>{'role': 'administrator'},
        ),
        throwsA(isA<UntrustedSessionException>()),
      );
    });
  });

  group('EmulatorSessionGuard', () {
    test('refreshes claims before accepting a session', () async {
      var refreshCalls = 0;
      var signOutCalls = 0;

      final EmulatorSession session = await EmulatorSessionGuard.validate(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        refreshClaims: () async {
          refreshCalls += 1;
          return <String, Object?>{'role': 'administrator'};
        },
        signOut: () async => signOutCalls += 1,
      );

      expect(session.role, InventoryRole.administrator);
      expect(refreshCalls, 1);
      expect(signOutCalls, 0);
    });

    test('signs out when refreshed claims are invalid', () async {
      var signOutCalls = 0;

      await expectLater(
        EmulatorSessionGuard.validate(
          userId: 'demo-local-seller-north',
          email: 'seller.north@demo-lda-inventory.invalid',
          refreshClaims: () async => <String, Object?>{'role': 'seller'},
          signOut: () async => signOutCalls += 1,
        ),
        throwsA(isA<UntrustedSessionException>()),
      );
      expect(signOutCalls, 1);
    });

    test('fails closed and signs out when token refresh fails', () async {
      var signOutCalls = 0;

      await expectLater(
        EmulatorSessionGuard.validate(
          userId: 'demo-local-seller-north',
          email: 'seller.north@demo-lda-inventory.invalid',
          refreshClaims: () async => throw StateError('emulator unavailable'),
          signOut: () async => signOutCalls += 1,
        ),
        throwsStateError,
      );
      expect(signOutCalls, 1);
    });
  });
}
