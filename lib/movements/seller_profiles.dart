/// Seller profile domain: name lookups for the movements screen and the
/// administrator `setSellerProfile` mutation contract.
library;

/// The outcome of one `sellerProfiles/{uid}` GET.
sealed class SellerProfileLookup {
  const SellerProfileLookup();
}

class SellerNamed extends SellerProfileLookup {
  const SellerNamed(this.displayName);

  final String displayName;

  @override
  bool operator ==(Object other) =>
      other is SellerNamed && other.displayName == displayName;

  @override
  int get hashCode => displayName.hashCode;
}

/// The profile document does not exist.
class SellerUnnamed extends SellerProfileLookup {
  const SellerUnnamed();

  @override
  bool operator ==(Object other) => other is SellerUnnamed;

  @override
  int get hashCode => 0;
}

/// The read was denied, failed, or returned a malformed profile.
class SellerProfileUnavailable extends SellerProfileLookup {
  const SellerProfileUnavailable({this.denied = false});

  final bool denied;

  @override
  bool operator ==(Object other) =>
      other is SellerProfileUnavailable && other.denied == denied;

  @override
  int get hashCode => denied.hashCode;
}

abstract interface class SellerProfileGateway {
  Future<SellerProfileResult> setSellerProfile({
    required String uid,
    required String displayName,
  });
}

class SellerProfileResult {
  const SellerProfileResult({required this.uid, required this.replayed});

  /// Strict `{uid, replayed}` bound to the requested uid.
  factory SellerProfileResult.fromCallable(
    Object? value, {
    required String uid,
  }) {
    if (value is! Map ||
        value.length != 2 ||
        value['uid'] != uid ||
        value['replayed'] is! bool) {
      throw const SellerProfileProtocolException();
    }
    return SellerProfileResult(uid: uid, replayed: value['replayed'] as bool);
  }

  final String uid;
  final bool replayed;
}

/// The server deterministically refused; nothing was written.
class SellerProfileRejectedException implements Exception {
  const SellerProfileRejectedException({required this.code, this.reason});

  final String code;

  /// One of `not-a-seller`, `invalid-branch-claim`, `invalid-stored-profile`,
  /// or null.
  final String? reason;
}

/// The outcome is unknown. Retrying the identical name is safe: the server
/// replays identical content without writing.
class SellerProfileUncertainException implements Exception {
  const SellerProfileUncertainException();
}

/// A newer call on the same gateway superseded this one.
class SellerProfileStaleException implements Exception {
  const SellerProfileStaleException();
}

/// The exact administrator session is no longer active; nothing was sent.
class SellerProfileSessionException implements Exception {
  const SellerProfileSessionException();
}

class SellerProfileProtocolException implements Exception {
  const SellerProfileProtocolException();
}

const Set<String> sellerProfileReasons = <String>{
  'not-a-seller',
  'invalid-branch-claim',
  'invalid-stored-profile',
};

/// Spanish message for a rejected name assignment.
String sellerProfileRejectionMessage(SellerProfileRejectedException error) =>
    switch (error.reason) {
      'not-a-seller' => 'Este usuario no es vendedor',
      'invalid-branch-claim' =>
        'La cuenta del vendedor no tiene una sucursal válida',
      'invalid-stored-profile' =>
        'El perfil guardado está dañado; contacta a soporte',
      _ => 'No se pudo guardar el nombre.',
    };
