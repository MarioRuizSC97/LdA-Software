import '../auth/emulator_session.dart';
import '../movements/inventory_movement.dart';
import '../movements/seller_profiles.dart';
import 'emulator_sale_gateway.dart';

/// Administrator gateway over the `setSellerProfile` callable, modeled on the
/// product pricing gateway: exact administrator checks before and after the
/// call, stale detection by generation, and a closed rejection whitelist.
/// Everything else is uncertain; an identical retry is safe because the
/// server replays identical content without writing.
class EmulatorSellerProfileGateway implements SellerProfileGateway {
  EmulatorSellerProfileGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final SaleSessionChecker sessionChecker;

  /// A callable built with `saleCallableFromInvoker`, so server failures
  /// arrive as [SaleCallableException] with `details.reason`.
  final SaleCallable invoke;
  int _generation = 0;

  static const Set<String> _rejectedCodes = <String>{
    'invalid-argument',
    'unauthenticated',
    'permission-denied',
    'not-found',
    'failed-precondition',
  };

  @override
  Future<SellerProfileResult> setSellerProfile({
    required String uid,
    required String displayName,
  }) async {
    final String? name = normalizeSellerDisplayName(displayName);
    if (name == null || !isSellerUid(uid)) {
      throw const SellerProfileRejectedException(code: 'invalid-argument');
    }
    final int generation = ++_generation;
    await _requireCurrentAdministrator();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(<String, Object?>{
        'uid': uid,
        'displayName': name,
      });
    } catch (error) {
      invocationError = error;
    }

    try {
      await _requireCurrentAdministrator();
    } catch (_) {
      throw const SellerProfileUncertainException();
    }
    if (generation != _generation) throw const SellerProfileStaleException();
    if (invocationError != null) _throwMapped(invocationError);
    try {
      return SellerProfileResult.fromCallable(response, uid: uid);
    } on SellerProfileProtocolException {
      throw const SellerProfileUncertainException();
    }
  }

  Future<void> _requireCurrentAdministrator() async {
    final EmulatorSession? current = await sessionChecker();
    if (current == null ||
        current.userId != expectedSession.userId ||
        current.role != InventoryRole.administrator ||
        current.branchId != null ||
        expectedSession.role != InventoryRole.administrator ||
        expectedSession.branchId != null) {
      throw const SellerProfileSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is SaleCallableException && _rejectedCodes.contains(error.code)) {
      final String? reason = error.reason;
      throw SellerProfileRejectedException(
        code: error.code,
        reason:
            error.code == 'failed-precondition' &&
                sellerProfileReasons.contains(reason)
            ? reason
            : null,
      );
    }
    throw const SellerProfileUncertainException();
  }
}
