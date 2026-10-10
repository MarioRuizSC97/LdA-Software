import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../auth/emulator_session.dart';
import '../catalog/firestore_catalog_repository.dart';
import 'administrator_session.dart';
import 'inventory_movement.dart';
import 'seller_profiles.dart';

/// Newest movements shown per screen load.
const int movementPageSize = 50;

/// Administrator movement operations the shell hands to the catalog page,
/// like `SaleCorrections`. The shell re-checks the exact administrator around
/// every call; the page never sees the session or the backend.
class AdministratorMovements {
  const AdministratorMovements({
    required this.load,
    required this.readProfile,
    required this.setSellerName,
  });

  /// Newest movements, optionally for one branch. Throws
  /// [MovementsUnavailable] on any failure.
  final Future<List<MovementEntry>> Function(String? branchId) load;

  /// Never throws: failures become [SellerProfileUnavailable].
  final Future<SellerProfileLookup> Function(String uid) readProfile;
  final Future<SellerProfileResult> Function(String uid, String displayName)
  setSellerName;
}

abstract interface class MovementReader {
  Future<List<MovementEntry>> recentMovements({String? branchId});

  Future<SellerProfileLookup> sellerProfile(String uid);
}

/// What the shell loads once per exact administrator.
class AdministratorMovementsBackend {
  const AdministratorMovementsBackend({
    required this.reader,
    required this.profiles,
  });

  final MovementReader reader;
  final SellerProfileGateway profiles;
}

typedef AdministratorMovementsLoader =
    Future<AdministratorMovementsBackend> Function(EmulatorSession session);

class MovementsUnavailable implements Exception {
  const MovementsUnavailable({this.cause, this.stackTrace});

  /// The original failure, kept for diagnosis; null when there was none.
  final Object? cause;
  final StackTrace? stackTrace;
}

/// Spanish message for a failed movements load. A missing composite index
/// and a rules denial get their own message; everything else is generic.
String movementsUnavailableMessage(Object error) {
  final Object? cause = error is MovementsUnavailable ? error.cause : null;
  return switch (cause) {
    FirebaseException(code: 'failed-precondition') =>
      'Falta un índice en la base de datos; contacta a soporte.',
    FirebaseException(code: 'permission-denied') =>
      'No tienes permiso para ver los movimientos.',
    _ => 'No se pudieron cargar los movimientos',
  };
}

/// Logs a movements failure with its cause, like the corrections gateway.
void logMovementsFailure(String message, Object error, StackTrace stackTrace) {
  developer.log(
    message,
    name: 'lda.movements',
    error: error,
    stackTrace: stackTrace,
  );
}

/// Fakeable Firestore seam for the movements query and single profile GETs.
abstract interface class MovementReadSource {
  Future<List<CatalogDocument>> queryMovements({
    String? branchId,
    required int limit,
  });

  /// Returns null when the document does not exist.
  Future<CatalogDocument?> findDocument(String path);
}

class FirebaseFirestoreMovementReadSource implements MovementReadSource {
  FirebaseFirestoreMovementReadSource(this._firestore);

  final FirebaseFirestore _firestore;

  @override
  Future<List<CatalogDocument>> queryMovements({
    String? branchId,
    required int limit,
  }) async {
    Query<Map<String, dynamic>> query = _firestore.collection(
      'inventoryMovements',
    );
    if (branchId != null) {
      query = query.where('branchId', isEqualTo: branchId);
    }
    final QuerySnapshot<Map<String, dynamic>> snapshot = await query
        .orderBy('occurredAt', descending: true)
        .limit(limit)
        .get();
    return snapshot.docs
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              CatalogDocument(
                path: document.reference.path,
                data: document.data(),
              ),
        )
        .toList(growable: false);
  }

  @override
  Future<CatalogDocument?> findDocument(String path) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _firestore
        .doc(path)
        .get();
    final Map<String, dynamic>? data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return CatalogDocument(path: snapshot.reference.path, data: data);
  }
}

const Set<String> _profileFields = <String>{'displayName', 'branchId'};

class FirestoreMovementRepository implements MovementReader {
  const FirestoreMovementRepository({
    required this.source,
    required this.session,
    required this.sessionChecker,
  });

  final MovementReadSource source;
  final EmulatorSession session;
  final ActiveSessionChecker sessionChecker;

  @override
  Future<List<MovementEntry>> recentMovements({String? branchId}) async {
    try {
      if (branchId != null && !isBranchId(branchId)) {
        throw const FormatException('branch filter is invalid');
      }
      await _requireAdministrator();
      final List<CatalogDocument> documents = await source.queryMovements(
        branchId: branchId,
        limit: movementPageSize,
      );
      await _requireAdministrator();
      return documents
          .map((CatalogDocument document) {
            final MovementEntry entry = parseMovementEntry(document);
            // A row outside the requested branch is not what was asked for.
            if (branchId != null &&
                entry is InventoryMovement &&
                entry.branchId != branchId) {
              return UnreadableMovement(entry.id);
            }
            return entry;
          })
          .toList(growable: false);
    } catch (error, stackTrace) {
      logMovementsFailure('Movements query failed', error, stackTrace);
      throw MovementsUnavailable(cause: error, stackTrace: stackTrace);
    }
  }

  @override
  Future<SellerProfileLookup> sellerProfile(String uid) async {
    try {
      if (!isPathSafeUid(uid)) return const SellerProfileUnavailable();
      await _requireAdministrator();
      final CatalogDocument? document = await source.findDocument(
        'sellerProfiles/$uid',
      );
      await _requireAdministrator();
      if (document == null) return const SellerUnnamed();
      return SellerNamed(_parseDisplayName(document.data));
    } on FirebaseException catch (error) {
      return SellerProfileUnavailable(
        denied: error.code == 'permission-denied',
      );
    } catch (_) {
      return const SellerProfileUnavailable();
    }
  }

  Future<void> _requireAdministrator() async {
    final EmulatorSession? active = await sessionChecker();
    if (!isSameExactAdministrator(expected: session, current: active)) {
      throw const FormatException('administrator session is not active');
    }
  }
}

/// Strict `{displayName, branchId}`; only the name leaves this function.
String _parseDisplayName(Map<String, Object?> data) {
  final Object? displayName = data['displayName'];
  final Object? branchId = data['branchId'];
  // Two entries, both typed below, means exactly the two fields.
  if (data.length != _profileFields.length ||
      displayName is! String ||
      normalizeSellerDisplayName(displayName) != displayName ||
      !isBranchId(branchId)) {
    throw const FormatException('seller profile is invalid');
  }
  return displayName;
}
