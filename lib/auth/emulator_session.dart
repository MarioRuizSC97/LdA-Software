import 'package:firebase_auth/firebase_auth.dart';

enum InventoryRole { administrator, seller }

extension InventoryRoleLabel on InventoryRole {
  String get label => switch (this) {
    InventoryRole.administrator => 'administrator',
    InventoryRole.seller => 'seller',
  };
}

class EmulatorSession {
  const EmulatorSession({
    required this.userId,
    required this.email,
    required this.role,
    this.branchId,
  });

  final String userId;
  final String email;
  final InventoryRole role;
  final String? branchId;
}

class UntrustedSessionException implements Exception {
  const UntrustedSessionException();
}

class EmulatorSessionConnectionException implements Exception {
  const EmulatorSessionConnectionException();
}

abstract interface class EmulatorSessionGateway {
  Future<EmulatorSession?> restoreSession();

  Stream<EmulatorSession?> sessionChanges();

  Future<EmulatorSession> login({
    required String email,
    required String password,
  });

  Future<void> logout();
}

class EmulatorSessionClaims {
  const EmulatorSessionClaims._();

  static EmulatorSession validate({
    required String userId,
    required String? email,
    required Map<String, Object?> claims,
  }) {
    if (userId.trim().isEmpty || email == null || email.trim().isEmpty) {
      throw const UntrustedSessionException();
    }

    final Object? roleClaim = claims['role'];
    final InventoryRole role = switch (roleClaim) {
      'administrator' => InventoryRole.administrator,
      'seller' => InventoryRole.seller,
      _ => throw const UntrustedSessionException(),
    };

    final bool hasBranchClaim = claims.containsKey('branchId');
    final Object? branchClaim = claims['branchId'];
    if (role == InventoryRole.administrator && hasBranchClaim) {
      throw const UntrustedSessionException();
    }
    if (role == InventoryRole.seller &&
        (branchClaim is! String || !_validBranchId(branchClaim))) {
      throw const UntrustedSessionException();
    }

    return EmulatorSession(
      userId: userId,
      email: email.trim(),
      role: role,
      branchId: role == InventoryRole.seller ? branchClaim as String : null,
    );
  }

  static bool _validBranchId(String value) =>
      RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);
}

class EmulatorSessionGuard {
  const EmulatorSessionGuard._();

  static Future<EmulatorSession> validate({
    required String userId,
    required String? email,
    required Future<Map<String, Object?>> Function() refreshClaims,
    required Future<void> Function() signOut,
  }) async {
    try {
      final Map<String, Object?> claims = await refreshClaims();
      return EmulatorSessionClaims.validate(
        userId: userId,
        email: email,
        claims: claims,
      );
    } catch (_) {
      try {
        await signOut();
      } catch (_) {
        // The rejected session remains invalid even if local cleanup fails.
      }
      rethrow;
    }
  }
}

class FirebaseEmulatorSessionGateway implements EmulatorSessionGateway {
  FirebaseEmulatorSessionGateway(this._auth);

  final FirebaseAuth _auth;

  @override
  Future<EmulatorSession?> restoreSession() async {
    final User? user = _auth.currentUser;
    if (user == null) return null;
    return _validatedSession(user);
  }

  @override
  Stream<EmulatorSession?> sessionChanges() =>
      _auth.idTokenChanges().asyncMap((User? user) async {
        if (user == null) return null;
        return _validatedSession(user);
      });

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) async {
    try {
      final UserCredential credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final User? user = credential.user;
      if (user == null) throw const UntrustedSessionException();
      return await _validatedSession(user);
    } catch (_) {
      await _safeSignOut();
      rethrow;
    }
  }

  @override
  Future<void> logout() => _auth.signOut();

  Future<EmulatorSession> _validatedSession(User user) async {
    try {
      return await EmulatorSessionGuard.validate(
        userId: user.uid,
        email: user.email,
        refreshClaims: () async {
          final IdTokenResult token = await user.getIdTokenResult(true);
          final Map<String, dynamic>? rawClaims = token.claims;
          if (rawClaims == null) throw const UntrustedSessionException();
          return rawClaims.cast<String, Object?>();
        },
        signOut: _auth.signOut,
      );
    } catch (error) {
      if (error is FirebaseAuthException) {
        if (_isRejectedCredential(error.code)) {
          throw const UntrustedSessionException();
        }
        throw const EmulatorSessionConnectionException();
      }
      rethrow;
    }
  }

  static bool _isRejectedCredential(String code) => <String>{
    'user-disabled',
    'user-not-found',
    'invalid-user-token',
    'user-token-expired',
  }.contains(code);

  Future<void> _safeSignOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // The original authentication failure remains the useful fail-closed result.
    }
  }
}
