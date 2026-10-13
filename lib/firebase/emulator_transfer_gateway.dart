import 'package:cloud_functions/cloud_functions.dart';

import '../auth/emulator_session.dart';
import '../transfers/transfer_draft.dart';

/// Injectable `transferInventory` adapter so tests never touch the SDK.
typedef TransferCallable = Future<Object?> Function(
  Map<String, Object?> request,
);

/// Reads the live session again, returning null when signed out.
typedef TransferSessionChecker = Future<EmulatorSession?> Function();

/// Transport-level callable failure carrying only the exact server code.
class TransferCallableException implements Exception {
  const TransferCallableException({required this.code});
  final String code;
}

/// The server refused before writing anything, so no stock moved.
///
/// Classification uses the exact code only; the English server message is
/// never parsed. Presentation owns the Spanish wording.
class TransferRejectedException implements Exception {
  const TransferRejectedException({required this.code});
  final String code;
}

/// The outcome is unknown. Retry the same frozen payload under the same key.
class TransferUncertainException implements Exception {
  const TransferUncertainException();
}

/// A newer submission superseded this one; its late answer must be ignored.
class TransferStaleException implements Exception {
  const TransferStaleException();
}

/// Deterministic domain refusals, each of which `transfers.js` raises before
/// buffering any write. `internal` is excluded: the callable masks every
/// unexpected failure with it, including a transaction that aborted after
/// writes were buffered, so its effect is unknown and it stays uncertain.
const Set<String> _rejectedCodes = <String>{
  'unauthenticated',
  'permission-denied',
  'invalid-argument',
  'not-found',
  'failed-precondition',
  'out-of-range',
  'already-exists',
};

/// Administrator-only `transferInventory` adapter.
///
/// Mirrors the stock-intake gateway: the exact branch-less administrator is
/// checked before and again after the await, a newer submission makes older
/// ones stale, whitelisted pre-write codes become rejections, and everything
/// else — transport failures, `internal`, and any malformed answer — is
/// uncertain. A valid response is never reported as success once the session
/// changed, and an unknown outcome after the request left the device is never
/// reported as definitely unexecuted. No permission or claim refresh and no
/// additional read path are performed here.
class EmulatorTransferGateway {
  EmulatorTransferGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.invoke,
  });

  final EmulatorSession expectedSession;
  final TransferSessionChecker sessionChecker;
  final TransferCallable invoke;
  int _generation = 0;

  /// Submits [draft] verbatim and parses the exact server answer.
  Future<TransferResult> submitTransfer(TransferDraft draft) async {
    final int generation = ++_generation;
    await _requireCurrentAdministrator();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(draft.toRequest());
    } catch (error) {
      invocationError = error;
    }

    // The request may already have executed, so a session change here can only
    // be uncertain: the caller retains the key for a replay-safe retry.
    try {
      await _requireCurrentAdministrator();
    } catch (_) {
      throw const TransferUncertainException();
    }
    if (generation != _generation) throw const TransferStaleException();
    if (invocationError != null) _throwMapped(invocationError);
    try {
      return TransferResult.fromCallable(response, request: draft);
    } on TransferProtocolException {
      throw const TransferUncertainException();
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
      throw const TransferSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is TransferCallableException &&
        _rejectedCodes.contains(error.code)) {
      throw TransferRejectedException(code: error.code);
    }
    throw const TransferUncertainException();
  }
}

/// Production adapter for the emulator-backed `transferInventory` callable.
TransferCallable firebaseTransferCallable(FirebaseFunctions functions) {
  final HttpsCallable callable = functions.httpsCallable('transferInventory');
  return transferCallableFromInvoker((Map<String, Object?> request) async {
    final HttpsCallableResult<Object?> result = await callable.call<Object?>(
      request,
    );
    return result.data;
  });
}

/// Translates SDK callable failures into [TransferCallableException], keeping
/// the exact server code and nothing else: `transfers.js` raises domain
/// failures as `InventoryError`s whose code is the whole classification
/// signal, and masks every unexpected failure as `internal`. Any non-SDK
/// failure passes through unchanged, so the gateway still treats it as
/// uncertain.
TransferCallable transferCallableFromInvoker(TransferCallable invoke) {
  return (Map<String, Object?> request) async {
    try {
      return await invoke(request);
    } on FirebaseFunctionsException catch (error) {
      throw TransferCallableException(code: error.code);
    }
  };
}
