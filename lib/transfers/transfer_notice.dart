import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';

/// One visible line of a transfer-destination notice.
///
/// Only presentation-relevant fields are kept: what arrived, how much, when.
/// Source-branch audit fields and costs never cross this boundary.
class TransferNoticeLine {
  const TransferNoticeLine({
    required this.movementId,
    required this.productId,
    required this.quantityScaled,
    required this.unit,
    required this.precision,
    required this.occurredAt,
  });

  final String movementId;
  final String productId;
  final BigInt quantityScaled;
  final String unit;
  final int precision;
  final DateTime occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'movementId': movementId,
    'productId': productId,
    'quantityScaled': quantityScaled.toString(),
    'unit': unit,
    'precision': precision,
    'occurredAt': occurredAt.toIso8601String(),
  };
}

/// A grouped arrival notice: every strict-valid transfer-in leg of one
/// transfer observed at the session branch.
class TransferNotice {
  const TransferNotice({required this.transferId, required this.lines})
    : assert(lines.length > 0);

  final String transferId;
  final List<TransferNoticeLine> lines;

  /// Latest leg arrival time; the notice's public timestamp.
  DateTime get occurredAt => lines
      .map((TransferNoticeLine line) => line.occurredAt)
      .reduce((DateTime a, DateTime b) => a.isAfter(b) ? a : b);
}

/// Groups raw movement documents into destination notices.
///
/// Strictness contract (DN-01):
/// - only `parseMovementEntry`-valid [InventoryMovement] legs count;
/// - only `MovementType.transferIn` legs at [branchId] are notices;
/// - grouping is by the wire `transferId`, which the parser already
///   guarantees to be a valid identifier for transfer legs;
/// - every other document (unreadable, other branch, other type) is skipped,
///   never silently converted into a notice.
List<TransferNotice> groupTransferInNotices(
  Iterable<CatalogDocument> documents, {
  required String branchId,
}) {
  final Map<String, List<TransferNoticeLine>> byTransfer =
      <String, List<TransferNoticeLine>>{};
  for (final CatalogDocument document in documents) {
    final MovementEntry entry = parseMovementEntry(document);
    if (entry is! InventoryMovement) continue;
    if (entry.type != MovementType.transferIn) continue;
    if (entry.branchId != branchId) continue;
    final Object? transferId = document.data['transferId'];
    if (transferId is! String) continue;
    final Object? occurredAt = document.data['occurredAt'];
    if (occurredAt is! Timestamp) continue;
    byTransfer
        .putIfAbsent(transferId, () => <TransferNoticeLine>[])
        .add(
          TransferNoticeLine(
            movementId: entry.id,
            productId: entry.productId,
            quantityScaled: entry.quantityScaled,
            unit: entry.unit,
            precision: entry.precision,
            occurredAt: occurredAt.toDate(),
          ),
        );
  }
  final List<TransferNotice> notices = <TransferNotice>[
    for (final MapEntry<String, List<TransferNoticeLine>> group
        in byTransfer.entries)
      if (group.value.isNotEmpty)
        TransferNotice(transferId: group.key, lines: group.value.toList()),
  ];
  // Newest arrivals first; a stable tie-break on transferId.
  notices.sort((TransferNotice a, TransferNotice b) {
    final int byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : a.transferId.compareTo(b.transferId);
  });
  for (final TransferNotice notice in notices) {
    notice.lines.sort((TransferNoticeLine a, TransferNoticeLine b) {
      final int byTime = a.occurredAt.compareTo(b.occurredAt);
      return byTime != 0 ? byTime : a.movementId.compareTo(b.movementId);
    });
  }
  return notices;
}

/// A persisted read acknowledgement as stored by the backend callable at
/// `transferNoticeReads/{userId}/branches/{branchId}/transfers/{transferId}`.
class TransferNoticeReadMarker {
  const TransferNoticeReadMarker({
    required this.transferId,
    required this.readAt,
  });

  final String transferId;
  final Timestamp readAt;
}

/// Parses a read-marker document against the exact reading session.
///
/// Returns null for anything that is not a marker of this user, this branch,
/// this transfer, with the exact four-field shape the callable writes.
///
/// The path is compared by exact segment equality — never by interpolating
/// the UID into a RegExp: path-safe UIDs may contain `+`, `.`, `^`, and other
/// punctuation that a pattern treats as metacharacters, which would lose a
/// real owner's markers or match a different owner's path.
TransferNoticeReadMarker? parseTransferNoticeReadMarker(
  CatalogDocument document, {
  required String userId,
  required String branchId,
}) {
  final List<String> segments = document.path.split('/');
  // transferNoticeReads/{userId}/branches/{branchId}/transfers/{transferId}
  if (segments.length != 6 ||
      segments[0] != 'transferNoticeReads' ||
      segments[2] != 'branches' ||
      segments[4] != 'transfers') {
    return null;
  }
  if (segments[1] != userId || segments[3] != branchId) {
    return null;
  }
  final Object? dataTransferId = document.data['transferId'];
  final Object? dataUserId = document.data['userId'];
  final Object? dataBranchId = document.data['branchId'];
  final Object? readAt = document.data['readAt'];
  if (dataUserId is! String || dataUserId != userId) return null;
  if (dataBranchId is! String || dataBranchId != branchId) return null;
  if (dataTransferId is! String || dataTransferId != segments[5]) {
    return null;
  }
  if (readAt is! Timestamp) return null;
  return TransferNoticeReadMarker(transferId: dataTransferId, readAt: readAt);
}
