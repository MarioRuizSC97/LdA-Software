import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../catalog/product_pricing.dart';

typedef ProductPricingCallable = Future<Object?> Function(
  Map<String, Object?> request,
);
typedef ProductPricingSessionChecker = Future<EmulatorSession?> Function();

class ProductPricingCallableException implements Exception {
  const ProductPricingCallableException({required this.code});
  final String code;
}

class EmulatorProductPricingGateway implements ProductPricingGateway {
  EmulatorProductPricingGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final ProductPricingSessionChecker sessionChecker;
  final ProductPricingCallable invoke;
  int _generation = 0;

  @override
  Future<ProductPricingResult> setPrice(ProductPricingDraft draft) async {
    final int generation = ++_generation;
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
      throw const ProductPricingUncertainException();
    }
    if (generation != _generation) {
      throw const ProductPricingStaleException();
    }
    if (invocationError != null) _throwMapped(invocationError);
    try {
      return ProductPricingResult.fromCallable(response, request: draft);
    } on ProductPricingProtocolException {
      throw const ProductPricingUncertainException();
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
      throw const ProductPricingSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is ProductPricingCallableException &&
        <String>{
          'invalid-argument',
          'out-of-range',
          'unauthenticated',
          'permission-denied',
          'not-found',
          'already-exists',
        }.contains(error.code)) {
      throw ProductPricingRejectedException(code: error.code);
    }
    throw const ProductPricingUncertainException();
  }
}

ProductPricingCallable firebaseProductPricingCallable(
  FirebaseFunctions functions,
) {
  final HttpsCallable callable = functions.httpsCallable('setProductPrice');
  return (Map<String, Object?> request) async {
    try {
      final HttpsCallableResult<Object?> result = await callable.call<Object?>(
        request,
      );
      return result.data;
    } on FirebaseFunctionsException catch (error) {
      throw ProductPricingCallableException(code: error.code);
    }
  };
}
