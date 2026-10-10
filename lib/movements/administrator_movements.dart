import 'package:cloud_firestore/cloud_firestore.dart';

import '../auth/emulator_session.dart';
import '../catalog/firestore_catalog_repository.dart';
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
  const MovementsUnavailable();
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

final RegExp _branchIdPattern = RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$');
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
      if (branchId != null && !_branchIdPattern.hasMatch(branchId)) {
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
    } catch (_) {
      throw const MovementsUnavailable();
    }
  }

  @override
  Future<SellerProfileLookup> sellerProfile(String uid) async {
    try {
      if (!isSellerUid(uid)) return const SellerProfileUnavailable();
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
    if (active == null ||
        active.userId != session.userId ||
        active.role != InventoryRole.administrator ||
        session.role != InventoryRole.administrator ||
        active.branchId != null) {
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
      branchId is! String ||
      !_branchIdPattern.hasMatch(branchId)) {
    throw const FormatException('seller profile is invalid');
  }
  return displayName;
}
