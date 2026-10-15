import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

/// Raw callable transport the production gateway wraps.
typedef TransferNoticeCallable = Future<Object?> Function(
  Map<String, Object?> request,
);

/// Maps the raw callable into the controller's typed invoker.
///
/// Only SDK exceptions carry a deterministic code; everything else propagates
/// untouched. Server text is never parsed into meaning.
TransferNoticeReadInvoker transferNoticeCallableFromInvoker(
  TransferNoticeCallable callable,
) => (Map<String, Object?> request) async {
  try {
    return await callable(request);
  } on FirebaseFunctionsException catch (error) {
    throw TransferNoticeCallableException(code: error.code);
  }
};

/// Narrow handle over one Firestore query's live stream. Exists so tests can
/// assert how the production adapter subscribes without initializing Firebase
/// or issuing any read.
abstract interface class TransferNoticeQueryHandle {
  Stream<QuerySnapshot<Map<String, Object?>>> snapshots({
    required bool includeMetadataChanges,
  });
}

/// Narrow factory for the two notice queries of one session.
abstract interface class TransferNoticeQueryFactory {
  TransferNoticeQueryHandle movementsQuery({required String branchId});

  TransferNoticeQueryHandle markersQuery({
    required String userId,
    required String branchId,
  });
}

/// Real Firestore query factory for one exact seller session.
class FirebaseTransferNoticeQueryFactory implements TransferNoticeQueryFactory {
  const FirebaseTransferNoticeQueryFactory(this._firestore);

  final FirebaseFirestore _firestore;

  @override
  TransferNoticeQueryHandle movementsQuery({required String branchId}) =>
      _FirestoreQueryHandle(
        _firestore
            .collection('inventoryMovements')
            .where('branchId', isEqualTo: branchId),
      );

  @override
  TransferNoticeQueryHandle markersQuery({
    required String userId,
    required String branchId,
  }) => _FirestoreQueryHandle(
    _firestore.collection(
      'transferNoticeReads/$userId/branches/$branchId/transfers',
    ),
  );
}

class _FirestoreQueryHandle implements TransferNoticeQueryHandle {
  const _FirestoreQueryHandle(this._query);

  final Query<Map<String, Object?>> _query;

  @override
  Stream<QuerySnapshot<Map<String, Object?>>> snapshots({
    required bool includeMetadataChanges,
  }) => _query.snapshots(includeMetadataChanges: includeMetadataChanges);
}

/// Live Firestore streams for one exact seller session.
///
/// The movements query filters by destination `branchId` only, which keeps the
/// query single-field (no composite index) and lets the controller group and
/// count locally without a hard cap that could hide unread notices.
///
/// Both queries subscribe with `includeMetadataChanges: true`: when the cached
/// documents already equal the server documents, the server confirmation is a
/// metadata-only snapshot that the default subscription never emits, and the
/// controller would never leave loading.
class FirebaseTransferNoticeStreamSource implements TransferNoticeStreamSource {
  const FirebaseTransferNoticeStreamSource(this._session, this._queries);

  final EmulatorSession _session;
  final TransferNoticeQueryFactory _queries;

  static TransferNoticeStreamEnvelope _envelope(
    QuerySnapshot<Map<String, Object?>> snapshot,
  ) => TransferNoticeStreamEnvelope(
    documents: <CatalogDocument>[
      for (final QueryDocumentSnapshot<Map<String, Object?>> doc
          in snapshot.docs)
        CatalogDocument(path: doc.reference.path, data: doc.data()),
    ],
    isFromCache: snapshot.metadata.isFromCache,
  );

  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      _queries
          .movementsQuery(branchId: branchId)
          .snapshots(includeMetadataChanges: true)
          .map(_envelope);

  @override
  Stream<TransferNoticeStreamEnvelope> markers() => _queries
      .markersQuery(userId: _session.userId, branchId: _session.branchId!)
      .snapshots(includeMetadataChanges: true)
      .map(_envelope);
}

/// Binds the DN-01 notice backend for one exact seller session.
///
/// The backend writer (server callable `markTransferNoticeRead` plus the leaf
/// `transferNoticeReads` collection) is implemented independently; the client
/// never writes markers directly.
TransferNoticeBackend loadTransferNoticeBackend({
  required FirebaseFirestore firestore,
  required FirebaseFunctions functions,
  required EmulatorSession session,
}) {
  if (session.role != InventoryRole.seller || session.branchId == null) {
    throw ArgumentError('transfer notices belong to an exact seller session');
  }
  final HttpsCallable callable = functions.httpsCallable(
    'markTransferNoticeRead',
  );
  return TransferNoticeBackend(
    streams: FirebaseTransferNoticeStreamSource(
      session,
      FirebaseTransferNoticeQueryFactory(firestore),
    ),
    markRead: transferNoticeCallableFromInvoker(
      (Map<String, Object?> request) => callable
          .call(request)
          .then((HttpsCallableResult result) => result.data),
    ),
  );
}
