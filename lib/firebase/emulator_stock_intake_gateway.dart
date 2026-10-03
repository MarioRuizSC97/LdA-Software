import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../catalog/stock_intake.dart';

typedef StockIntakeCallable = Future<Object?> Function(
  Map<String, Object?> request,
);
typedef StockIntakeSessionChecker = Future<EmulatorSession?> Function();

class StockIntakeCallableException implements Exception {
  const StockIntakeCallableException({required this.code});
  final String code;
}

class StockIntakeRejectedException implements Exception {
  const StockIntakeRejectedException({required this.code});
  final String code;
}

class StockIntakeUncertainException implements Exception {
  const StockIntakeUncertainException();
}

class StockIntakeStaleException implements Exception {
  const StockIntakeStaleException();
}

class EmulatorStockIntakeGateway {
  EmulatorStockIntakeGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final StockIntakeSessionChecker sessionChecker;
  final StockIntakeCallable invoke;
  int _generation = 0;

  Future<StockIntakeResult> submitIntake(StockIntakeDraft draft) async {
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
      throw const StockIntakeUncertainException();
    }
    if (generation != _generation) {
      throw const StockIntakeStaleException();
    }
    if (invocationError != null) _throwMapped(invocationError);
    try {
      return StockIntakeResult.fromCallable(response, request: draft);
    } on StockIntakeProtocolException {
      throw const StockIntakeUncertainException();
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
      throw const StockIntakeSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is StockIntakeCallableException &&
        <String>{
          'unauthenticated',
          'permission-denied',
          'invalid-argument',
          'not-found',
          'out-of-range',
          'already-exists',
        }.contains(error.code)) {
      throw StockIntakeRejectedException(code: error.code);
    }
    throw const StockIntakeUncertainException();
  }
}

StockIntakeCallable firebaseStockIntakeCallable(FirebaseFunctions functions) {
  final HttpsCallable callable = functions.httpsCallable('stockIntake');
  return (Map<String, Object?> request) async {
    try {
      final HttpsCallableResult<Object?> result = await callable.call<Object?>(
        request,
      );
      return result.data;
    } on FirebaseFunctionsException catch (error) {
      throw StockIntakeCallableException(code: error.code);
    }
  };
}
