import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_draft.dart';
import '../sales/sale_quote.dart';

typedef SaleCallable = Future<Object?> Function(Map<String, Object?> request);
typedef SaleSessionChecker = Future<EmulatorSession?> Function();
typedef SaleGatewayLoader = Future<EmulatorSaleGateway> Function(
  EmulatorSession session,
);

/// Transport-level callable failure with the server code and message.
class SaleCallableException implements Exception {
  const SaleCallableException({required this.code, required this.message});
  final String code;
  final String message;
}

/// The server deterministically refused before writing anything. [message]
/// is the server text, kept as data for the UI to classify (for example
/// "full payment must equal the authoritative total" means re-quote).
class SaleRejectedException implements Exception {
  const SaleRejectedException({required this.code, required this.message});
  final String code;
  final String message;

  /// The submitted amount no longer equals the authoritative total (prices
  /// changed after the quote): re-quote and let the seller confirm again.
  bool get isPaymentMismatch =>
      code == 'invalid-argument' &&
      message == 'full payment must equal the authoritative total';
}

/// The outcome is unknown. For a submission, retry the same draft.
class SaleUncertainException implements Exception {
  const SaleUncertainException();
}

/// A newer call of the same operation superseded this one.
class SaleStaleException implements Exception {
  const SaleStaleException();
}

/// Deterministic server refusals. `internal` is excluded: the server maps any
/// unexpected failure (including a transaction failure) to it, so its effect
/// is unknown and it stays uncertain.
const Set<String> _rejectedCodes = <String>{
  'invalid-argument',
  'not-found',
  'failed-precondition',
  'out-of-range',
  'permission-denied',
  'unauthenticated',
  'already-exists',
};

/// Seller-only `quoteSale` and `submitSale` adapter.
///
/// Mirrors the stock-intake gateway: the exact assigned seller is re-checked
/// before and after each call, a newer call of the same operation makes older
/// ones stale (quote and submit count separately), whitelisted codes become
/// rejections, and anything else, including a malformed response, is
/// uncertain.
class EmulatorSaleGateway {
  EmulatorSaleGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.quoteInvoke,
    required this.submitInvoke,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final EmulatorSession expectedSession;
  final SaleSessionChecker sessionChecker;
  final SaleCallable quoteInvoke;
  final SaleCallable submitInvoke;
  final DateTime Function() _clock;
  int _quoteGeneration = 0;
  int _submitGeneration = 0;

  Future<SaleQuote> quote(SaleCart cart) async {
    final Map<String, Object?> request = cart.toQuoteRequest();
    final int generation = ++_quoteGeneration;
    final Object? response = await _staleAware(
      _call(quoteInvoke, request),
      () => generation != _quoteGeneration,
    );
    try {
      return SaleQuote.fromCallable(response, cart: cart);
    } on SaleProtocolException {
      throw const SaleUncertainException();
    }
  }

  Future<SaleReceipt> submit(SaleDraft draft) async {
    final Map<String, Object?> request = draft.toRequest();
    if (draft.branchId != expectedSession.branchId) {
      throw const SaleSessionException();
    }
    final int generation = ++_submitGeneration;
    final Object? response = await _staleAware(
      _call(submitInvoke, request),
      () => generation != _submitGeneration,
    );
    try {
      return SaleReceipt.fromCallable(
        response,
        draft: draft,
        confirmedAt: _clock(),
      );
    } on SaleProtocolException {
      throw const SaleUncertainException();
    }
  }

  /// A superseded call is stale whatever its outcome: a late rejection or
  /// uncertainty must not reach a UI that already moved on. Session failures
  /// still surface, because they are not about this call's result.
  Future<Object?> _staleAware(
    Future<Object?> call,
    bool Function() superseded,
  ) async {
    final Object? response;
    try {
      response = await call;
    } on SaleRejectedException {
      if (superseded()) throw const SaleStaleException();
      rethrow;
    } on SaleUncertainException {
      if (superseded()) throw const SaleStaleException();
      rethrow;
    }
    if (superseded()) throw const SaleStaleException();
    return response;
  }

  /// Runs one call between two seller checks. A failed post-call check makes
  /// even a valid response uncertain; staleness is checked by the caller.
  Future<Object?> _call(
    SaleCallable invoke,
    Map<String, Object?> request,
  ) async {
    await _requireCurrentSeller();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(request);
    } catch (error) {
      invocationError = error;
    }

    try {
      await _requireCurrentSeller();
    } catch (_) {
      throw const SaleUncertainException();
    }
    if (invocationError != null) _throwMapped(invocationError);
    return response;
  }

  Future<void> _requireCurrentSeller() async {
    final EmulatorSession? current = await sessionChecker();
    if (current == null ||
        expectedSession.role != InventoryRole.seller ||
        expectedSession.branchId == null ||
        current.userId != expectedSession.userId ||
        current.role != InventoryRole.seller ||
        current.branchId != expectedSession.branchId) {
      throw const SaleSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is SaleCallableException && _rejectedCodes.contains(error.code)) {
      throw SaleRejectedException(code: error.code, message: error.message);
    }
    throw const SaleUncertainException();
  }
}

SaleCallable firebaseSaleCallable(FirebaseFunctions functions, String name) {
  final HttpsCallable callable = functions.httpsCallable(name);
  return saleCallableFromInvoker((Map<String, Object?> request) async {
    final HttpsCallableResult<Object?> result = await callable.call<Object?>(
      request,
    );
    return result.data;
  });
}

/// Translates SDK callable failures into [SaleCallableException], keeping the
/// server code and turning a missing message into an empty one. Any other
/// failure passes through unchanged (the gateway treats it as uncertain).
SaleCallable saleCallableFromInvoker(SaleCallable invoke) {
  return (Map<String, Object?> request) async {
    try {
      return await invoke(request);
    } on FirebaseFunctionsException catch (error) {
      throw SaleCallableException(
        code: error.code,
        message: error.message ?? '',
      );
    }
  };
}
