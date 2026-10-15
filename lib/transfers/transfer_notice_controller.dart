import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';

/// Server-confirmed-ness of one Firestore snapshot event.
class TransferNoticeStreamEnvelope {
  const TransferNoticeStreamEnvelope({
    required this.documents,
    required this.isFromCache,
  });

  final List<CatalogDocument> documents;
  final bool isFromCache;
}

/// Backend transport the controller binds to once per seller session.
abstract interface class TransferNoticeStreamSource {
  /// Live `inventoryMovements` filtered server-side by destination branch
  /// only. No composite index, no client-side hard cap.
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId});

  /// Live persisted read markers at
  /// `transferNoticeReads/{userId}/branches/{branchId}/transfers`.
  Stream<TransferNoticeStreamEnvelope> markers();
}

/// The exact `markTransferNoticeRead` callable transport.
typedef TransferNoticeReadInvoker = Future<Object?> Function(
  Map<String, Object?> request,
);

/// One session's notice backend.
class TransferNoticeBackend {
  const TransferNoticeBackend({required this.streams, required this.markRead});

  final TransferNoticeStreamSource streams;
  final TransferNoticeReadInvoker markRead;
}

/// Loads the backend bound to the controller's exact seller session.
typedef TransferNoticeBackendLoader = Future<TransferNoticeBackend> Function();

/// Builds the page's notice controller for one exact session. Returns a
/// controller only for the exact seller sessions the host authorizes.
typedef TransferNoticeControllerFactory = TransferNoticeController Function(
  EmulatorSession session,
);

/// Resolves the current session, or null once signed out.
typedef TransferNoticeSessionChecker = Future<EmulatorSession?> Function();

/// The controller's authoritative phase. [error] means "unknown", never
/// "zero unread".
enum TransferNoticePhase { loading, ready, error }

/// Immutable snapshot of the notice book shown by the badge and inbox.
class TransferNoticeState {
  const TransferNoticeState({
    this.phase = TransferNoticePhase.loading,
    this.notices = const <TransferNotice>[],
    this.readTransferIds = const <String>{},
    this.pendingAckTransferIds = const <String>{},
  });

  final TransferNoticePhase phase;
  final List<TransferNotice> notices;
  final Set<String> readTransferIds;
  final Set<String> pendingAckTransferIds;

  /// Authoritative only while [phase] is ready; null otherwise so the UI can
  /// never turn loading or error into a false "zero unread".
  int? get unreadCount => phase == TransferNoticePhase.ready
      ? notices
            .where(
              (TransferNotice notice) =>
                  !readTransferIds.contains(notice.transferId),
            )
            .length
      : null;

  bool isRead(String transferId) => readTransferIds.contains(transferId);

  bool isAckPending(String transferId) =>
      pendingAckTransferIds.contains(transferId);
}

/// The callable refused deterministically; retrying will refuse again.
class TransferNoticeAckRejectedException implements Exception {
  const TransferNoticeAckRejectedException({required this.code});

  final String code;

  @override
  String toString() => 'TransferNoticeAckRejectedException(code: $code)';
}

/// The callable mapped the request but the outcome is unknown; replays are
/// safe and the marker stream is the source of truth.
class TransferNoticeAckUncertainException implements Exception {
  const TransferNoticeAckUncertainException();

  @override
  String toString() => 'TransferNoticeAckUncertainException()';
}

/// The seller session holding this controller is no longer current.
class TransferNoticeSessionException implements Exception {
  const TransferNoticeSessionException();

  @override
  String toString() => 'TransferNoticeSessionException()';
}

/// The callable transport raised a structured failure carrying its code.
class TransferNoticeCallableException implements Exception {
  const TransferNoticeCallableException({required this.code});

  final String code;

  @override
  String toString() => 'TransferNoticeCallableException(code: $code)';
}

/// Deterministic refusal codes of `markTransferNoticeRead`.
const Set<String> transferNoticeRejectCodes = <String>{
  'invalid-argument',
  'failed-precondition',
  'permission-denied',
  'not-found',
  'resource-exhausted',
  'unauthenticated',
};

/// One live seller's transfer-destination notice book.
///
/// Guarantees (DN-01):
/// - readiness requires a server-confirmed snapshot from BOTH streams;
/// - cache-only events are never applied as data and never zero the count;
/// - a stream error becomes an explicit error phase, never zero unread;
/// - events are applied only while the exact seller session is still current;
/// - `markRead` checks the session before and after the await and only
///   updates local read state on an exact, confirmed success response;
/// - nothing is marked read implicitly: only an explicit user ack writes.
class TransferNoticeController extends ChangeNotifier {
  TransferNoticeController({
    required this.session,
    required this.loadBackend,
    required this.sessionChecker,
  }) : assert(session.role == InventoryRole.seller),
       assert(session.branchId != null);

  /// The exact seller session this controller belongs to.
  final EmulatorSession session;

  /// Loads the backend bound to [session]; consulted once per generation.
  final TransferNoticeBackendLoader loadBackend;

  /// Resolves the current session for the shell's exact-seller guarantee.
  final TransferNoticeSessionChecker sessionChecker;

  TransferNoticeState _state = const TransferNoticeState();

  TransferNoticeBackend? _backend;
  StreamSubscription<TransferNoticeStreamEnvelope>? _movementsSub;
  StreamSubscription<TransferNoticeStreamEnvelope>? _markersSub;

  /// Monotonic fence: every restart or dispose invalidates in-flight work.
  int _generation = 0;
  bool _disposed = false;
  bool _started = false;

  List<CatalogDocument> _movementsDocuments = const <CatalogDocument>[];
  bool _movementsConfirmed = false;
  bool _markersConfirmed = false;

  /// Per-stream event sequencing: two snapshots of the same stream may have
  /// their async session checks complete out of order, and the older one must
  /// never overwrite the newer one's applied state. The two streams are
  /// independent: a movement event never invalidates an in-flight marker
  /// event or vice versa.
  int _movementsEvents = 0;
  int _markersEvents = 0;

  /// Highest event sequence actually applied per stream. An event whose
  /// sequence is older than the last applied one is dropped after its
  /// guards pass, so a late old snapshot can never overwrite newer state.
  int _movementsApplied = 0;
  int _markersApplied = 0;

  /// The generation whose streams failed. While set for the current
  /// generation, no event may re-enter readiness: a failed stream carries no
  /// proof, and a healthy opposite-stream snapshot must not renotify. Cleared
  /// only by [retry] (a fresh generation) — a full-stream recovery.
  int? _failedGeneration;

  TransferNoticeState get state => _state;

  bool _isCurrentSession(EmulatorSession? current) =>
      current != null &&
      current.userId == session.userId &&
      current.role == InventoryRole.seller &&
      current.branchId == session.branchId;

  void _update(TransferNoticeState Function(TransferNoticeState) change) {
    if (_disposed) return;
    _state = change(_state);
    notifyListeners();
  }

  /// Subscribes to both streams once. A repeated start never tears down the
  /// live subscriptions; [retry] is the explicit restart path.
  void start() {
    if (_started) return;
    _started = true;
    _restart();
  }

  Future<void> _restart() async {
    _generation += 1;
    final int generation = _generation;
    _cancelSubscriptions();
    _movementsDocuments = const <CatalogDocument>[];
    _movementsConfirmed = false;
    _markersConfirmed = false;
    _movementsEvents = 0;
    _markersEvents = 0;
    _movementsApplied = 0;
    _markersApplied = 0;
    _failedGeneration = null;
    _update(
      (TransferNoticeState _) =>
          const TransferNoticeState(phase: TransferNoticePhase.loading),
    );

    try {
      // Session guard around the backend load. A throwing checker is an
      // explicit failure, never an unhandled async exception.
      final EmulatorSession? beforeLoad = await sessionChecker();
      if (_disposed ||
          generation != _generation ||
          !_isCurrentSession(beforeLoad)) {
        return;
      }
      final TransferNoticeBackend backend = await loadBackend();
      final EmulatorSession? afterLoad = await sessionChecker();
      if (_disposed ||
          generation != _generation ||
          !_isCurrentSession(afterLoad)) {
        return;
      }
      _backend = backend;
      _movementsSub = backend.streams
          .movements(branchId: session.branchId!)
          .listen((TransferNoticeStreamEnvelope envelope) {
            final int sequence = ++_movementsEvents;
            _onEnvelope(
              envelope,
              isMovements: true,
              generation: generation,
              sequence: sequence,
            );
          }, onError: (Object error) => _onStreamError(generation: generation));
      _markersSub = backend.streams.markers().listen((
        TransferNoticeStreamEnvelope envelope,
      ) {
        final int sequence = ++_markersEvents;
        _onEnvelope(
          envelope,
          isMovements: false,
          generation: generation,
          sequence: sequence,
        );
      }, onError: (Object _) => _onStreamError(generation: generation));
    } on Object {
      // Load or subscription-setup failures (including a throwing checker or
      // a throwing source) are an explicit unknown state for this generation.
      _onStreamError(generation: generation);
    }
  }

  /// Re-subscribes after an error. In-flight acks keep their fences.
  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    return _restart();
  }

  /// Cancels synchronously: teardown must never leave a live subscription
  /// behind while its microtask chain is still pending.
  void _cancelSubscriptions() {
    _movementsSub?.cancel();
    _markersSub?.cancel();
    _movementsSub = null;
    _markersSub = null;
  }

  Future<void> _onEnvelope(
    TransferNoticeStreamEnvelope envelope, {
    required bool isMovements,
    required int generation,
    required int sequence,
  }) async {
    if (_disposed || generation != _generation) return;
    try {
      // Every emitted event belongs to the exact current session only.
      final EmulatorSession? current = await sessionChecker();
      if (_disposed ||
          generation != _generation ||
          _failedGeneration == generation) {
        return;
      }
      if (!_isCurrentSession(current)) {
        return;
      }
      // Cache-only snapshots are never authoritative data.
      if (envelope.isFromCache) return;

      bool applied = false;
      if (isMovements) {
        if (sequence >= _movementsApplied) {
          _movementsApplied = sequence;
          _movementsDocuments = envelope.documents;
          _movementsConfirmed = true;
          applied = true;
        }
      } else {
        if (sequence >= _markersApplied) {
          _markersApplied = sequence;
          final Set<String> reads = <String>{};
          for (final CatalogDocument document in envelope.documents) {
            final TransferNoticeReadMarker? marker =
                parseTransferNoticeReadMarker(
                  document,
                  userId: session.userId,
                  branchId: session.branchId!,
                );
            if (marker != null) reads.add(marker.transferId);
          }
          _update(
            (TransferNoticeState state) => TransferNoticeState(
              phase: state.phase,
              notices: state.notices,
              readTransferIds: reads,
              pendingAckTransferIds: state.pendingAckTransferIds,
            ),
          );
          _markersConfirmed = true;
          applied = true;
        }
      }
      if (applied && _movementsConfirmed && _markersConfirmed) {
        final List<TransferNotice> notices = groupTransferInNotices(
          _movementsDocuments,
          branchId: session.branchId!,
        );
        _update(
          (TransferNoticeState state) => TransferNoticeState(
            phase: TransferNoticePhase.ready,
            notices: notices,
            readTransferIds: state.readTransferIds,
            pendingAckTransferIds: state.pendingAckTransferIds,
          ),
        );
      }
    } on Object {
      // A failing session check mid-event is an unknown state, never a data
      // update and never an unhandled async exception.
      _onStreamError(generation: generation);
    }
  }

  void _onStreamError({required int generation}) {
    if (_disposed ||
        generation != _generation ||
        _failedGeneration == generation) {
      return;
    }
    // Latch the failure for this generation and tear down both streams: the
    // failed stream has no proof, and no subsequent snapshot may re-enter
    // readiness. Only an explicit [retry] starts a proven-fresh generation.
    _failedGeneration = generation;
    _cancelSubscriptions();
    _update(
      (TransferNoticeState _) =>
          const TransferNoticeState(phase: TransferNoticePhase.error),
    );
  }

  /// Explicitly marks one transfer's notice as read through the callable.
  ///
  /// Throws [StateError] unless the book is ready and the notice is unread
  /// and not already pending. Throws [TransferNoticeSessionException] when
  /// the exact seller session is no longer current before or after the call.
  Future<void> markRead(String transferId) async {
    final TransferNoticeState state = _state;
    if (state.phase != TransferNoticePhase.ready) {
      throw StateError('transfer notices are not ready');
    }
    if (state.readTransferIds.contains(transferId)) return;
    if (state.pendingAckTransferIds.contains(transferId)) return;
    final TransferNoticeBackend? backend = _backend;
    if (backend == null) {
      throw StateError('transfer notice backend is not bound');
    }

    final int generation = _generation;
    final EmulatorSession? before = await sessionChecker();
    if (_disposed || generation != _generation || !_isCurrentSession(before)) {
      throw const TransferNoticeSessionException();
    }
    _update(
      (TransferNoticeState state) => TransferNoticeState(
        phase: state.phase,
        notices: state.notices,
        readTransferIds: state.readTransferIds,
        pendingAckTransferIds: <String>{
          ...state.pendingAckTransferIds,
          transferId,
        },
      ),
    );
    try {
      final Object? response = await backend.markRead(<String, Object?>{
        'transferId': transferId,
      });
      if (_disposed || generation != _generation) {
        throw const TransferNoticeSessionException();
      }
      final EmulatorSession? after = await sessionChecker();
      if (_disposed || generation != _generation || !_isCurrentSession(after)) {
        // A late ack never lands on a new owner; the persisted marker stream
        // already reflects the server truth for the old session.
        throw const TransferNoticeSessionException();
      }
      _validateAckResponse(response, transferId);
      _update(
        (TransferNoticeState state) => TransferNoticeState(
          phase: state.phase,
          notices: state.notices,
          readTransferIds: <String>{...state.readTransferIds, transferId},
          pendingAckTransferIds: state.pendingAckTransferIds
            ..remove(transferId),
        ),
      );
    } on TransferNoticeCallableException catch (error) {
      if (transferNoticeRejectCodes.contains(error.code)) {
        throw TransferNoticeAckRejectedException(code: error.code);
      }
      throw const TransferNoticeAckUncertainException();
    } finally {
      // Every settled outcome — success, malformed response, rejection,
      // transport failure, or session/generation loss — clears this ack's
      // pending flag, or a failed attempt would silently block all retries.
      // The generation fence keeps a stale cleanup off the new generation.
      if (!_disposed && generation == _generation) {
        _clearPending(transferId);
      }
    }
  }

  void _clearPending(String transferId) {
    _update(
      (TransferNoticeState state) => TransferNoticeState(
        phase: state.phase,
        notices: state.notices,
        readTransferIds: state.readTransferIds,
        pendingAckTransferIds: state.pendingAckTransferIds..remove(transferId),
      ),
    );
  }

  /// The exact response contract: `{transferId, branchId, read:true}`.
  void _validateAckResponse(Object? response, String transferId) {
    if (response is! Map<Object?, Object?>) {
      throw const TransferNoticeAckUncertainException();
    }
    final Object? responseTransferId = response['transferId'];
    final Object? branchId = response['branchId'];
    final Object? read = response['read'];
    if (responseTransferId is! String || responseTransferId != transferId) {
      throw const TransferNoticeAckUncertainException();
    }
    if (branchId is! String || branchId != session.branchId) {
      throw const TransferNoticeAckUncertainException();
    }
    if (read is! bool || !read) {
      throw const TransferNoticeAckUncertainException();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _cancelSubscriptions();
    super.dispose();
  }
}
