import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'seller-2',
  email: 'seller2@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-south',
);

Map<String, Object?> _leg({
  required String transferId,
  String branchId = 'branch-north',
  String productId = 'PRD-COFFEE-001',
  int quantityScaled = 500,
  required String movementId,
  int occurredAtMillis = 1767225600000,
}) => <String, Object?>{
  'branchId': branchId,
  'type': 'transfer-in',
  'productId': productId,
  'quantityScaled': quantityScaled,
  'unit': 'kg',
  'precision': 2,
  'transferId': transferId,
  'occurredAt': Timestamp.fromMillisecondsSinceEpoch(occurredAtMillis),
  'actorId': 'administrator-1',
};

CatalogDocument _doc(Map<String, Object?> data, String movementId) =>
    CatalogDocument(path: 'inventoryMovements/$movementId', data: data);

CatalogDocument _markerDoc(
  String transferId, {
  String userId = 'seller-1',
  String branchId = 'branch-north',
  int millis = 1767300000000,
}) => CatalogDocument(
  path: 'transferNoticeReads/$userId/branches/$branchId/transfers/$transferId',
  data: <String, Object?>{
    'userId': userId,
    'branchId': branchId,
    'transferId': transferId,
    'readAt': Timestamp.fromMillisecondsSinceEpoch(millis),
  },
);

const String _transferA = 'aaaaaaaa-0000-0000-0000-000000000001';
const String _transferB = 'aaaaaaaa-0000-0000-0000-000000000002';

class _FakeStreamSource implements TransferNoticeStreamSource {
  final StreamController<TransferNoticeStreamEnvelope> movementsCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  final StreamController<TransferNoticeStreamEnvelope> markersCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  int movementsSubscriptions = 0;
  int markersSubscriptions = 0;

  void emitMovements(
    List<CatalogDocument> documents, {
    bool isFromCache = false,
  }) => movementsCtrl.add(
    TransferNoticeStreamEnvelope(
      documents: documents,
      isFromCache: isFromCache,
    ),
  );

  void emitMarkers(
    List<CatalogDocument> documents, {
    bool isFromCache = false,
  }) => markersCtrl.add(
    TransferNoticeStreamEnvelope(
      documents: documents,
      isFromCache: isFromCache,
    ),
  );

  void failMovements(Object error) => movementsCtrl.addError(error);

  void failMarkers(Object error) => markersCtrl.addError(error);

  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) {
    movementsSubscriptions += 1;
    return movementsCtrl.stream;
  }

  @override
  Stream<TransferNoticeStreamEnvelope> markers() {
    markersSubscriptions += 1;
    return markersCtrl.stream;
  }
}

class _Harness {
  _Harness();

  EmulatorSession? checkerSession = _seller;

  /// When non-null, every session check parks on a completer here so tests
  /// control the completion order of overlapping checks.
  List<Completer<EmulatorSession?>>? pendingChecks;

  /// When set, the session checker throws instead of resolving.
  Object? checkerError;
  final _FakeStreamSource source = _FakeStreamSource();
  final List<String> events = <String>[];
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<Completer<Object?>> _replies = <Completer<Object?>>[];
  Object? throwOnInvoke;
  int backendLoads = 0;
  Completer<void>? loadGate;

  TransferNoticeReadInvoker get invoker =>
      (Map<String, Object?> request) async {
        events.add('call');
        requests.add(Map<String, Object?>.of(request));
        if (throwOnInvoke case final Object error) {
          throwOnInvoke = null;
          throw error;
        }
        final Completer<Object?> reply = Completer<Object?>();
        _replies.add(reply);
        return reply.future;
      };

  TransferNoticeController controller() {
    backendLoads += 1;
    return TransferNoticeController(
      session: _seller,
      loadBackend: () async {
        events.add('load');
        if (loadGate case final Completer<void> gate) await gate.future;
        return TransferNoticeBackend(streams: source, markRead: invoker);
      },
      sessionChecker: () async {
        events.add('session');
        if (checkerError case final Object error) throw error;
        if (pendingChecks != null) {
          final Completer<EmulatorSession?> check =
              Completer<EmulatorSession?>();
          pendingChecks!.add(check);
          return check.future;
        }
        return checkerSession;
      },
    );
  }

  /// One in-flight ack waiting for the fake callable's answer.
  Future<void> startAck(TransferNoticeController noticeController) async {
    final Future<void> ack = noticeController
        .markRead(_transferA)
        .then((_) => null, onError: (Object _) => null);
    await _flushEvents();
    return ack;
  }

  void succeedLastAck() => _replies.removeLast().complete(<String, Object?>{
    'transferId': _transferA,
    'branchId': 'branch-north',
    'read': true,
  });

  /// Drains controller microtasks without closing streams.
  Future<void> _flushEvents() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('TransferNoticeController readiness', () {
    test(
      'stays loading until both streams deliver a server-confirmed event',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();

        expect(noticeController.state.phase, TransferNoticePhase.loading);
        expect(noticeController.state.unreadCount, isNull);

        // Cache-only snapshots are never authoritative, not even as zero.
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ], isFromCache: true);
        await harness._flushEvents();
        expect(noticeController.state.phase, TransferNoticePhase.loading);
        expect(noticeController.state.unreadCount, isNull);

        // Server-confirmed movements alone are not enough.
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        await harness._flushEvents();
        expect(noticeController.state.phase, TransferNoticePhase.loading);
        expect(noticeController.state.unreadCount, isNull);

        // A metadata-only confirmed marker snapshot (no docs) completes readiness.
        harness.source.emitMarkers(<CatalogDocument>[]);
        await harness._flushEvents();

        expect(noticeController.state.phase, TransferNoticePhase.ready);
        expect(noticeController.state.unreadCount, 1);
        noticeController.dispose();
      },
    );

    test('updates the unread count live as new arrivals land', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();

      expect(noticeController.state.unreadCount, 1);

      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        _doc(_leg(transferId: _transferB, movementId: 'm2'), 'm2'),
      ]);
      await harness._flushEvents();

      expect(noticeController.state.unreadCount, 2);
      noticeController.dispose();
    });

    test('cache-only events after readiness never change the count', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      final TransferNoticeState before = noticeController.state;

      harness.source.emitMovements(<CatalogDocument>[], isFromCache: true);
      harness.source.emitMarkers(<CatalogDocument>[], isFromCache: true);
      await harness._flushEvents();

      expect(noticeController.state.unreadCount, before.unreadCount);
      expect(noticeController.state.phase, TransferNoticePhase.ready);
      noticeController.dispose();
    });

    test(
      'a stream error surfaces explicitly and never reports zero unread',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        harness.source.emitMarkers(<CatalogDocument>[]);
        await harness._flushEvents();
        expect(noticeController.state.unreadCount, 1);

        harness.source.failMovements(Exception('stream failed'));
        await harness._flushEvents();

        expect(noticeController.state.phase, TransferNoticePhase.error);
        expect(noticeController.state.unreadCount, isNull);
        noticeController.dispose();
      },
    );

    test('retry resubscribes both streams and recovers readiness', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      harness.source.failMovements(Exception('stream failed'));
      await harness._flushEvents();
      final int movementsBefore = harness.source.movementsSubscriptions;
      final int markersBefore = harness.source.markersSubscriptions;

      await noticeController.retry();
      await harness._flushEvents();

      expect(harness.source.movementsSubscriptions, movementsBefore + 1);
      expect(harness.source.markersSubscriptions, markersBefore + 1);

      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      expect(noticeController.state.phase, TransferNoticePhase.ready);
      expect(noticeController.state.unreadCount, 1);
      noticeController.dispose();
    });
  });

  group('TransferNoticeController grouping and read state', () {
    test(
      'groups multi-line transfers and applies persisted read markers',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
          _doc(
            _leg(
              transferId: _transferA,
              productId: 'PRD-SUGAR-002',
              quantityScaled: 2500,
              movementId: 'm2',
              occurredAtMillis: 1767225601000,
            ),
            'm2',
          ),
          _doc(_leg(transferId: _transferB, movementId: 'm3'), 'm3'),
        ]);
        harness.source.emitMarkers(<CatalogDocument>[_markerDoc(_transferB)]);
        await harness._flushEvents();

        expect(noticeController.state.notices, hasLength(2));
        expect(noticeController.state.readTransferIds, <String>{_transferB});
        expect(noticeController.state.unreadCount, 1);
        // History is retained: the read notice is still listed.
        expect(
          noticeController.state.notices.map(
            (TransferNotice n) => n.transferId,
          ),
          contains(_transferB),
        );
        noticeController.dispose();
      },
    );

    test('reports every unread notice beyond fifty without capping', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        for (int i = 0; i < 60; i++)
          _doc(
            _leg(
              transferId:
                  'aaaaaaaa-0000-0000-0000-${i.toString().padLeft(12, '0')}',
              movementId: 'm$i',
            ),
            'm$i',
          ),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();

      expect(noticeController.state.unreadCount, 60);
      noticeController.dispose();
    });

    test('a recreated controller reproduces the same read state', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController first = harness.controller();
      first.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      expect(first.state.unreadCount, 1);

      final Future<void> ack = first
          .markRead(_transferA)
          .then((_) => null, onError: (Object _) => null);
      await harness._flushEvents();
      harness.succeedLastAck();
      await ack;
      await harness._flushEvents();
      expect(first.state.readTransferIds, <String>{_transferA});
      first.dispose();

      // Recreated controller: markers (persisted) arrive before movements.
      final TransferNoticeController second = harness.controller();
      second.start();
      await harness._flushEvents();
      harness.source.emitMarkers(<CatalogDocument>[
        _markerDoc(_transferA, millis: 1767300000000),
      ]);
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      await harness._flushEvents();

      expect(second.state.phase, TransferNoticePhase.ready);
      expect(second.state.readTransferIds, <String>{_transferA});
      expect(second.state.unreadCount, 0);
      second.dispose();
    });

    test('another user\'s controller keeps the transfer unread', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      // Marker belongs to another user: strict parsing must ignore it.
      harness.source.emitMarkers(<CatalogDocument>[
        _markerDoc(_transferA, userId: 'seller-2'),
      ]);
      await harness._flushEvents();

      expect(noticeController.state.readTransferIds, isEmpty);
      expect(noticeController.state.unreadCount, 1);
      noticeController.dispose();
    });

    test('emitting events never marks anything read by itself', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();

      expect(harness.requests, isEmpty);
      noticeController.dispose();
    });

    test('ignores events from a stale session', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.checkerSession = null;
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();

      expect(noticeController.state.phase, TransferNoticePhase.loading);
      expect(noticeController.state.unreadCount, isNull);
      noticeController.dispose();
    });

    test('dispose cancels both stream subscriptions', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      expect(harness.source.movementsCtrl.hasListener, isTrue);
      expect(harness.source.markersCtrl.hasListener, isTrue);

      noticeController.dispose();
      await harness._flushEvents();
      expect(harness.source.movementsCtrl.hasListener, isFalse);
      expect(harness.source.markersCtrl.hasListener, isFalse);
    });
  });

  group('TransferNoticeController.markRead', () {
    test('sends the exact callable payload and checks the session twice around the await', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      harness.events.clear();

      final Future<void> ack = noticeController
          .markRead(_transferA)
          .then((_) => null);
      await harness._flushEvents();
      harness.succeedLastAck();
      await ack;

      expect(harness.events, <String>['session', 'call', 'session']);
      expect(harness.requests.single, <String, Object?>{
        'transferId': _transferA,
      });
      expect(noticeController.state.readTransferIds, <String>{_transferA});
      expect(noticeController.state.pendingAckTransferIds, isEmpty);
      noticeController.dispose();
    });

    test('refuses to ack while not ready', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();

      await expectLater(
        noticeController.markRead(_transferA),
        throwsStateError,
      );
      expect(harness.requests, isEmpty);
      noticeController.dispose();
    });

    test(
      'a late session change makes the ack fail without local effects',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        harness.source.emitMarkers(<CatalogDocument>[]);
        await harness._flushEvents();

        final Future<Object?> ack = noticeController
            .markRead(_transferA)
            .then<Object?>((_) => null, onError: (Object error) => error);
        await harness._flushEvents();
        // The seller logged out while the callable was in flight.
        harness.checkerSession = _otherSeller;
        harness.succeedLastAck();
        final Object? error = await ack;

        expect(error, isA<TransferNoticeSessionException>());
        expect(noticeController.state.readTransferIds, isEmpty);
        expect(noticeController.state.pendingAckTransferIds, isEmpty);
        noticeController.dispose();
      },
    );

    test(
      'a malformed success response is uncertain and never marked read',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        harness.source.emitMarkers(<CatalogDocument>[]);
        await harness._flushEvents();

        final Future<Object?> ack = noticeController
            .markRead(_transferA)
            .then<Object?>((_) => null, onError: (Object error) => error);
        await harness._flushEvents();
        // Missing the exact {transferId, branchId, read:true} shape.
        harness._replies.removeLast().complete(<String, Object?>{
          'transferId': _transferA,
          'read': 'yes',
        });
        final Object? error = await ack;

        expect(error, isA<TransferNoticeAckUncertainException>());
        expect(noticeController.state.readTransferIds, isEmpty);
        noticeController.dispose();
      },
    );

    test('a deterministic rejection code maps to a rejected ack', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();

      harness.throwOnInvoke = TransferNoticeCallableException(
        code: 'permission-denied',
      );
      final Object? error = await noticeController
          .markRead(_transferA)
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(error, isA<TransferNoticeAckRejectedException>());
      expect(
        (error as TransferNoticeAckRejectedException).code,
        'permission-denied',
      );
      expect(noticeController.state.readTransferIds, isEmpty);
      expect(noticeController.state.pendingAckTransferIds, isEmpty);
      noticeController.dispose();
    });
  });

  group('live event sequencing', () {
    test('a stale marker snapshot never erases newer persisted reads when checks complete in reverse order', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        _doc(
          _leg(
            transferId: _transferB,
            movementId: 'm2',
            occurredAtMillis: 1767229200000,
          ),
          'm2',
        ),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[_markerDoc(_transferA)]);
      await harness._flushEvents();
      expect(noticeController.state.unreadCount, 1);

      // Two marker snapshots arrive in order: A (older snapshot) then
      // B (newer persisted state). Their session checks complete in
      // reverse order: B first, then A.
      harness.pendingChecks = <Completer<EmulatorSession?>>[];
      harness.source.emitMarkers(<CatalogDocument>[_markerDoc(_transferA)]);
      harness.source.emitMarkers(<CatalogDocument>[
        _markerDoc(_transferA),
        _markerDoc(_transferB, millis: 1767300001000),
      ]);
      await harness._flushEvents();
      expect(harness.pendingChecks!.length, 2);

      // The newer snapshot resolves first and applies.
      harness.pendingChecks![1].complete(_seller);
      await harness._flushEvents();
      expect(noticeController.state.readTransferIds, <String>{
        _transferA,
        _transferB,
      });

      // The older snapshot resolves last and must not erase B's state.
      harness.pendingChecks![0].complete(_seller);
      await harness._flushEvents();

      expect(noticeController.state.phase, TransferNoticePhase.ready);
      expect(noticeController.state.readTransferIds, <String>{
        _transferA,
        _transferB,
      });
      expect(noticeController.state.unreadCount, 0);
      noticeController.dispose();
    });

    test('marker and movement events keep independent sequences', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[_markerDoc(_transferA)]);
      await harness._flushEvents();
      expect(noticeController.state.unreadCount, 0);

      harness.pendingChecks = <Completer<EmulatorSession?>>[];
      // A marker update is in flight when a movement snapshot arrives.
      harness.source.emitMarkers(<CatalogDocument>[
        _markerDoc(_transferA),
        _markerDoc(_transferB, millis: 1767300001000),
      ]);
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        _doc(
          _leg(
            transferId: _transferB,
            movementId: 'm2',
            occurredAtMillis: 1767229200000,
          ),
          'm2',
        ),
      ]);
      await harness._flushEvents();
      expect(harness.pendingChecks!.length, 2);

      // Both apply: the marker event is not dropped for the movement event.
      harness.pendingChecks![0].complete(_seller);
      harness.pendingChecks![1].complete(_seller);
      await harness._flushEvents();

      expect(noticeController.state.phase, TransferNoticePhase.ready);
      expect(noticeController.state.readTransferIds, <String>{
        _transferA,
        _transferB,
      });
      expect(noticeController.state.notices, hasLength(2));
      expect(noticeController.state.unreadCount, 0);
      noticeController.dispose();
    });

    test(
      'a failing session check during an event becomes an explicit error',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        harness.source.emitMarkers(<CatalogDocument>[]);
        await harness._flushEvents();
        expect(noticeController.state.unreadCount, 1);

        harness.checkerError = StateError('auth backend down');
        harness.source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        await harness._flushEvents();

        // Explicit unknown state; never an unhandled async exception.
        expect(noticeController.state.phase, TransferNoticePhase.error);
        expect(noticeController.state.unreadCount, isNull);
        noticeController.dispose();
      },
    );
  });

  group('stream failure latching', () {
    test('a healthy opposite-stream event cannot revive readiness after a marker stream failure', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        _doc(
          _leg(
            transferId: _transferB,
            movementId: 'm2',
            occurredAtMillis: 1767229200000,
          ),
          'm2',
        ),
      ]);
      // Confirmed empty markers: ready, both unread.
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      expect(noticeController.state.unreadCount, 2);

      harness.source.failMarkers(Exception('markers listener dropped'));
      await harness._flushEvents();
      expect(noticeController.state.phase, TransferNoticePhase.error);
      expect(noticeController.state.unreadCount, isNull);

      // A stale re-emission of the movement snapshot must not re-enter
      // ready with the empty read set: all notices would look renotified.
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        _doc(
          _leg(
            transferId: _transferB,
            movementId: 'm2',
            occurredAtMillis: 1767229200000,
          ),
          'm2',
        ),
      ]);
      await harness._flushEvents();

      expect(noticeController.state.phase, TransferNoticePhase.error);
      expect(noticeController.state.unreadCount, isNull);
      // The failed book is fully torn down until an explicit retry.
      expect(harness.source.movementsCtrl.hasListener, isFalse);
      expect(harness.source.markersCtrl.hasListener, isFalse);
      noticeController.dispose();
    });

    test('retry after a latched failure recovers with full proof', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      harness.source.failMovements(Exception('movements listener dropped'));
      await harness._flushEvents();
      expect(noticeController.state.phase, TransferNoticePhase.error);

      await noticeController.retry();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[_markerDoc(_transferA)]);
      await harness._flushEvents();

      expect(noticeController.state.phase, TransferNoticePhase.ready);
      expect(noticeController.state.readTransferIds, <String>{_transferA});
      expect(noticeController.state.unreadCount, 0);
      noticeController.dispose();
    });

    test(
      'a throwing session checker at startup becomes an explicit error',
      () async {
        final _Harness harness = _Harness();
        harness.checkerError = StateError('auth backend down');
        final TransferNoticeController noticeController = harness.controller();
        noticeController.start();
        await harness._flushEvents();

        expect(noticeController.state.phase, TransferNoticePhase.error);
        expect(noticeController.state.unreadCount, isNull);
        noticeController.dispose();
      },
    );

    test(
      'a source that throws during subscription setup becomes an error',
      () async {
        final TransferNoticeController noticeController =
            TransferNoticeController(
              session: _seller,
              loadBackend: () async => TransferNoticeBackend(
                streams: _ThrowingSource(),
                markRead: (_) async => null,
              ),
              sessionChecker: () async => _seller,
            );
        noticeController.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(noticeController.state.phase, TransferNoticePhase.error);
        expect(noticeController.state.unreadCount, isNull);
        noticeController.dispose();
      },
    );
  });

  group('acknowledgement recovery (B2)', () {
    Future<TransferNoticeController> readyController(_Harness harness) async {
      final TransferNoticeController noticeController = harness.controller();
      noticeController.start();
      await harness._flushEvents();
      harness.source.emitMovements(<CatalogDocument>[
        _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
      ]);
      harness.source.emitMarkers(<CatalogDocument>[]);
      await harness._flushEvents();
      expect(noticeController.state.unreadCount, 1);
      return noticeController;
    }

    test('a malformed success response clears pending and an explicit retry can succeed', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = await readyController(
        harness,
      );

      final Future<Object?> first = noticeController
          .markRead(_transferA)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await harness._flushEvents();
      harness._replies.removeLast().complete(<String, Object?>{
        'transferId': _transferA,
        'read': 'yes',
      });
      final Object? error = await first;

      expect(error, isA<TransferNoticeAckUncertainException>());
      expect(noticeController.state.pendingAckTransferIds, isEmpty);
      expect(noticeController.state.readTransferIds, isEmpty);
      expect(noticeController.state.unreadCount, 1);

      // The seller retries explicitly: the backend is invoked again and a
      // valid response finally marks the notice read.
      final Future<void> second = noticeController
          .markRead(_transferA)
          .then<Object?>((_) => null, onError: (Object _) => null);
      await harness._flushEvents();
      expect(harness.requests.length, 2);
      harness.succeedLastAck();
      await second;
      await harness._flushEvents();

      expect(noticeController.state.readTransferIds, <String>{_transferA});
      expect(noticeController.state.pendingAckTransferIds, isEmpty);
      expect(noticeController.state.unreadCount, 0);
      noticeController.dispose();
    });

    test(
      'an ordinary transport failure clears pending and allows a retry',
      () async {
        final _Harness harness = _Harness();
        final TransferNoticeController noticeController =
            await readyController(harness);

        harness.throwOnInvoke = StateError('socket gone');
        final Object? error = await noticeController
            .markRead(_transferA)
            .then<Object?>((_) => null, onError: (Object failure) => failure);

        expect(error, isA<StateError>());
        expect(noticeController.state.pendingAckTransferIds, isEmpty);
        expect(noticeController.state.readTransferIds, isEmpty);

        final Future<void> second = noticeController
            .markRead(_transferA)
            .then<Object?>((_) => null, onError: (Object _) => null);
        await harness._flushEvents();
        expect(harness.requests.length, 2);
        harness.succeedLastAck();
        await second;
        await harness._flushEvents();

        expect(noticeController.state.readTransferIds, <String>{_transferA});
        expect(noticeController.state.pendingAckTransferIds, isEmpty);
        noticeController.dispose();
      },
    );

    test('a late settled ack cannot mutate a newer generation', () async {
      final _Harness harness = _Harness();
      final TransferNoticeController noticeController = await readyController(
        harness,
      );

      final Future<Object?> ack = noticeController
          .markRead(_transferA)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await harness._flushEvents();
      expect(noticeController.state.pendingAckTransferIds, <String>{
        _transferA,
      });

      // The book restarts (new generation) while the ack is in flight.
      await noticeController.retry();
      await harness._flushEvents();
      expect(noticeController.state.phase, TransferNoticePhase.loading);

      harness.succeedLastAck();
      final Object? error = await ack;
      await harness._flushEvents();

      expect(error, isA<TransferNoticeSessionException>());
      // The stale result cleanup left no trace on the new generation.
      expect(noticeController.state.readTransferIds, isEmpty);
      expect(noticeController.state.pendingAckTransferIds, isEmpty);
      expect(noticeController.state.phase, TransferNoticePhase.loading);
      noticeController.dispose();
    });
  });

  group('punctuation UID read markers (B3)', () {
    const EmulatorSession punctuationSeller = EmulatorSession(
      userId: 'user+tag@gmail.com',
      email: 'user@demo.invalid',
      role: InventoryRole.seller,
      branchId: 'branch-north',
    );

    CatalogDocument punctuationMarker(String transferId) => CatalogDocument(
      path:
          'transferNoticeReads/user+tag@gmail.com/branches/branch-north/transfers/$transferId',
      data: <String, Object?>{
        'userId': 'user+tag@gmail.com',
        'branchId': 'branch-north',
        'transferId': transferId,
        'readAt': Timestamp.fromMillisecondsSinceEpoch(1767300000000),
      },
    );

    test(
      'read state survives controller recreation for a punctuation UID',
      () async {
        final _FakeStreamSource source = _FakeStreamSource();
        TransferNoticeController controllerFor() => TransferNoticeController(
          session: punctuationSeller,
          loadBackend: () async => TransferNoticeBackend(
            streams: source,
            markRead: (_) async => null,
          ),
          sessionChecker: () async => punctuationSeller,
        );

        final TransferNoticeController first = controllerFor();
        first.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        source.emitMarkers(<CatalogDocument>[punctuationMarker(_transferA)]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(first.state.readTransferIds, <String>{_transferA});
        expect(first.state.unreadCount, 0);
        first.dispose();

        // Recreated controller: persisted markers still parse for this UID.
        final TransferNoticeController second = controllerFor();
        second.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        source.emitMarkers(<CatalogDocument>[punctuationMarker(_transferA)]);
        source.emitMovements(<CatalogDocument>[
          _doc(_leg(transferId: _transferA, movementId: 'm1'), 'm1'),
        ]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(second.state.phase, TransferNoticePhase.ready);
        expect(second.state.readTransferIds, <String>{_transferA});
        expect(second.state.unreadCount, 0);
        second.dispose();
      },
    );
  });
}

/// A source whose stream factory throws synchronously, like a misconfigured
/// Firestore adapter can.
class _ThrowingSource implements TransferNoticeStreamSource {
  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      throw StateError('query construction failed');

  @override
  Stream<TransferNoticeStreamEnvelope> markers() =>
      const Stream<TransferNoticeStreamEnvelope>.empty();
}
