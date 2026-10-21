import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../catalog/product_rename.dart';

/// Raw callable transport the production gateway wraps.
typedef ProductRenameCallable = Future<Object?> Function(
  Map<String, Object?> request,
);
typedef ProductRenameSessionChecker = Future<EmulatorSession?> Function();

class ProductRenameCallableException implements Exception {
  const ProductRenameCallableException({required this.code});
  final String code;
}

/// Guards one privileged rename behind the exact current administrator
/// session, following the pricing gateway behavior:
///
/// - the request is validated before any session check or network call;
/// - the session is re-checked before and after the callable await, so a
///   session that ends mid-flight makes the outcome uncertain instead of
///   exposing a result the caller can no longer trust;
/// - a newer attempt invalidates the result of any older in-flight one;
/// - only verified prewrite server rejections are deterministic; transport,
///   runtime-guard (`failed-precondition`) and malformed-response failures
///   stay uncertain because the rename may or may not have persisted.
class EmulatorProductRenameGateway implements ProductRenameGateway {
  EmulatorProductRenameGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final ProductRenameSessionChecker sessionChecker;
  final ProductRenameCallable invoke;
  int _generation = 0;

  @override
  Future<ProductRenameResult> renameProduct(ProductRenameDraft draft) async {
    final int generation = ++_generation;
    draft.validate();
    await _requireCurrentAdministrator();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(draft.toRequest());
    } catch (error) {
      invocationError = error;
    }

    try {
      await _requireCurrentAdministrator();
    } catch (_) {
      throw const ProductRenameUncertainException();
    }
    if (generation != _generation) {
      throw const ProductRenameStaleException();
    }
    if (invocationError != null) _throwMapped(invocationError);
    try {
      return ProductRenameResult.fromCallable(response, request: draft);
    } on ProductRenameProtocolException {
      throw const ProductRenameUncertainException();
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
      throw const ProductRenameSessionException();
    }
  }

  // The rename backend answers `invalid-argument`, `unauthenticated`,
  // `permission-denied`, `not-found` and `already-exists` before any write,
  // so those codes are definite rejections. Every other code, including the
  // masked `internal` and the runtime-guard `failed-precondition`, cannot
  // prove what happened to the write and stays uncertain.
  Never _throwMapped(Object error) {
    if (error is ProductRenameCallableException &&
        <String>{
          'invalid-argument',
          'unauthenticated',
          'permission-denied',
          'not-found',
          'already-exists',
        }.contains(error.code)) {
      throw ProductRenameRejectedException(code: error.code);
    }
    throw const ProductRenameUncertainException();
  }
}

/// Maps the raw callable into the typed transport: only SDK exceptions carry
/// a deterministic code; everything else propagates untouched. Server text is
/// never parsed into meaning.
ProductRenameCallable productRenameCallableFromInvoker(
  ProductRenameCallable callable,
) => (Map<String, Object?> request) async {
  try {
    return await callable(request);
  } on FirebaseFunctionsException catch (error) {
    throw ProductRenameCallableException(code: error.code);
  }
};

/// Binds the backend `renameProduct` callable.
ProductRenameCallable firebaseProductRenameCallable(
  FirebaseFunctions functions,
) {
  final HttpsCallable callable = functions.httpsCallable('renameProduct');
  return productRenameCallableFromInvoker(
    (Map<String, Object?> request) =>
        callable.call<Object?>(request).then((result) => result.data),
  );
}
