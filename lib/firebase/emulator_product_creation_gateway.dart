import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../catalog/product_creation.dart';

// Kept as a narrow seam so domain tests never require a Functions network.
typedef ProductCreationCallable = Future<Object?> Function(
  Map<String, Object?> request,
);
typedef ProductCreationSessionChecker = Future<EmulatorSession?> Function();

class ProductCreationCallableException implements Exception {
  const ProductCreationCallableException({required this.code});

  final String code;
}

class EmulatorProductCreationGateway implements ProductCreationGateway {
  EmulatorProductCreationGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final ProductCreationSessionChecker sessionChecker;
  final ProductCreationCallable invoke;
  int _generation = 0;

  @override
  Future<ProductCreationResult> create(ProductCreationDraft draft) async {
    final int generation = ++_generation;
    await _requireCurrentAdministrator();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(draft.toRequest());
    } catch (error) {
      invocationError = error;
    }

    await _requireCurrentAdministrator();
    if (generation != _generation) {
      throw const ProductCreationStaleException();
    }
    if (invocationError != null) {
      _throwMapped(invocationError);
    }
    try {
      return ProductCreationResult.fromCallable(response);
    } on ProductCreationProtocolException {
      throw const ProductCreationUncertainException();
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
      throw const ProductCreationSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is ProductCreationCallableException) {
      if (<String>{
        'invalid-argument',
        'unauthenticated',
        'permission-denied',
        'already-exists',
      }.contains(error.code)) {
        throw ProductCreationRejectedException(code: error.code);
      }
    }
    throw const ProductCreationUncertainException();
  }
}

ProductCreationCallable firebaseProductCreationCallable(
  FirebaseFunctions functions,
) {
  final HttpsCallable callable = functions.httpsCallable('createProduct');
  return (Map<String, Object?> request) async {
    try {
      final HttpsCallableResult<Object?> result = await callable.call<Object?>(
        request,
      );
      return result.data;
    } on FirebaseFunctionsException catch (error) {
      throw ProductCreationCallableException(code: error.code);
    }
  };
}
