import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';

/// A transfer-in movement document as written by the backend callable.
Map<String, Object?> _transferIn({
  required String transferId,
  String branchId = 'branch-north',
  String productId = 'PRD-COFFEE-001',
  int quantityScaled = 500,
  int precision = 2,
  String unit = 'kg',
  int occurredAtMillis = 1767225600000,
  String type = 'transfer-in',
}) => <String, Object?>{
  'branchId': branchId,
  'type': type,
  'productId': productId,
  'quantityScaled': quantityScaled,
  'unit': unit,
  'precision': precision,
  'transferId': transferId,
  'occurredAt': Timestamp.fromMillisecondsSinceEpoch(occurredAtMillis),
  'actorId': 'administrator-1',
};

CatalogDocument _doc(Map<String, Object?> data, String movementId) =>
    CatalogDocument(path: 'inventoryMovements/$movementId', data: data);

void main() {
  group('groupTransferInNotices', () {
    test(
      'groups two transfer-in legs of one transfer into a single notice',
      () {
        final List<TransferNotice> notices = groupTransferInNotices(
          <CatalogDocument>[
            _doc(
              _transferIn(
                transferId: '550e8400-e29b-41d4-a716-446655440000',
                productId: 'PRD-COFFEE-001',
                quantityScaled: 500,
                unit: 'kg',
                precision: 2,
                occurredAtMillis: 1767225600000,
              ),
              'movement-a',
            ),
            _doc(
              _transferIn(
                transferId: '550e8400-e29b-41d4-a716-446655440000',
                productId: 'PRD-SUGAR-002',
                quantityScaled: 2500,
                unit: 'g',
                precision: 0,
                occurredAtMillis: 1767225601000,
              ),
              'movement-b',
            ),
          ],
          branchId: 'branch-north',
        );

        expect(notices, hasLength(1));
        final TransferNotice notice = notices.single;
        expect(notice.transferId, '550e8400-e29b-41d4-a716-446655440000');
        expect(notice.lines, hasLength(2));
        // Lines stay chronological within the notice.
        expect(notice.lines[0].movementId, 'movement-a');
        expect(notice.lines[1].movementId, 'movement-b');
        expect(notice.occurredAt.millisecondsSinceEpoch, 1767225601000);
        expect(notice.lines[0].productId, 'PRD-COFFEE-001');
        expect(notice.lines[0].quantityScaled, BigInt.from(500));
        expect(notice.lines[0].unit, 'kg');
        expect(notice.lines[0].precision, 2);
      },
    );

    test(
      'keeps distinct transfers as separate notices ordered newest first',
      () {
        final List<TransferNotice> notices = groupTransferInNotices(
          <CatalogDocument>[
            _doc(
              _transferIn(
                transferId: 'aaaaaaaa-0000-0000-0000-000000000001',
                occurredAtMillis: 1767225600000,
              ),
              'movement-old',
            ),
            _doc(
              _transferIn(
                transferId: 'aaaaaaaa-0000-0000-0000-000000000002',
                occurredAtMillis: 1767229200000,
              ),
              'movement-new',
            ),
          ],
          branchId: 'branch-north',
        );

        expect(notices, hasLength(2));
        expect(notices[0].transferId, 'aaaaaaaa-0000-0000-0000-000000000002');
        expect(notices[1].transferId, 'aaaaaaaa-0000-0000-0000-000000000001');
      },
    );

    test('keeps only strict valid transfer-in legs of the session branch', () {
      final List<TransferNotice> notices = groupTransferInNotices(
        <CatalogDocument>[
          // Outgoing leg of the same transfer: never shown to the destination.
          _doc(
            _transferIn(
              transferId: 'aaaaaaaa-0000-0000-0000-000000000001',
              type: 'transfer-out',
              branchId: 'branch-north',
              quantityScaled: -500,
            ),
            'movement-out',
          ),
          // Arrival at another branch.
          _doc(
            _transferIn(
              transferId: 'aaaaaaaa-0000-0000-0000-000000000001',
              branchId: 'branch-south',
            ),
            'movement-south',
          ),
          // Unrelated movement type.
          _doc(<String, Object?>{
            'branchId': 'branch-north',
            'type': 'sale',
            'productId': 'PRD-COFFEE-001',
            'quantityScaled': -100,
            'unit': 'kg',
            'precision': 2,
            'occurredAt': Timestamp.fromMillisecondsSinceEpoch(1767225600000),
            'actorId': 'seller-1',
          }, 'movement-sale'),
          // Malformed document: stays visible as unreadable, never a notice.
          _doc(<String, Object?>{
            'branchId': 'branch-north',
            'type': 'transfer-in',
          }, 'movement-broken'),
          // The one strict valid arrival of the batch.
          _doc(
            _transferIn(
              transferId: 'aaaaaaaa-0000-0000-0000-000000000003',
              occurredAtMillis: 1767230000000,
            ),
            'movement-kept',
          ),
        ],
        branchId: 'branch-north',
      );

      expect(notices, hasLength(1));
      expect(notices.single.transferId, 'aaaaaaaa-0000-0000-0000-000000000003');
      expect(notices.single.lines.single.movementId, 'movement-kept');
    });

    test('never exposes cost or source-audit fields on notice lines', () {
      final TransferNotice notice = groupTransferInNotices(<CatalogDocument>[
        _doc(
          _transferIn(
            transferId: 'aaaaaaaa-0000-0000-0000-000000000001',
            occurredAtMillis: 1767225600000,
          ),
          'movement-1',
        ),
      ], branchId: 'branch-north').single;

      // Lines expose exactly the six presentation fields, nothing else.
      expect(notice.lines.single.toJson(), <String, Object?>{
        'movementId': 'movement-1',
        'productId': 'PRD-COFFEE-001',
        'quantityScaled': '500',
        'unit': 'kg',
        'precision': 2,
        'occurredAt': isA<String>(),
      });

      // A document carrying cost fields is not a strict valid leg at all:
      // the parser rejects it and it never becomes a notice.
      final Map<String, Object?> withCost =
          _transferIn(
            transferId: 'aaaaaaaa-0000-0000-0000-000000000001',
            occurredAtMillis: 1767225600000,
          )..addAll(<String, Object?>{
            'unitCostCentavos': 120000,
            'lineTotalCentavos': 600000,
          });
      expect(
        groupTransferInNotices(<CatalogDocument>[
          _doc(withCost, 'movement-with-cost'),
        ], branchId: 'branch-north'),
        isEmpty,
      );
    });
  });

  group('parseTransferNoticeReadMarker', () {
    const String transferId = '550e8400-e29b-41d4-a716-446655440000';
    final Timestamp readAt = Timestamp.fromMillisecondsSinceEpoch(
      1767300000000,
    );

    test('accepts a marker in the exact leaf path of the reading user', () {
      final TransferNoticeReadMarker? marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/seller-1/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': 'seller-1',
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );

      expect(marker, isNotNull);
      expect(marker!.transferId, transferId);
      expect(marker.readAt, readAt);
    });

    test('rejects markers outside the reading user or branch', () {
      TransferNoticeReadMarker? marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/other-seller/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': 'other-seller',
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );
      expect(marker, isNull);

      marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/seller-1/branches/branch-south/transfers/$transferId',
          data: <String, Object?>{
            'userId': 'seller-1',
            'branchId': 'branch-south',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );
      expect(marker, isNull);
    });

    test('rejects markers with mismatched fields or path ids', () {
      // Path id differs from the data transferId.
      TransferNoticeReadMarker? marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path: 'transferNoticeReads/seller-1/branches/branch-north/transfers/wrong-id',
          data: <String, Object?>{
            'userId': 'seller-1',
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );
      expect(marker, isNull);

      // Wrong field values.
      marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/seller-1/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': 'someone-else',
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );
      expect(marker, isNull);

      // Missing readAt.
      marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/seller-1/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': 'seller-1',
            'branchId': 'branch-north',
            'transferId': transferId,
          },
        ),
        userId: 'seller-1',
        branchId: 'branch-north',
      );
      expect(marker, isNull);
    });

    test('parses a marker for a path-safe punctuation UID', () {
      const String uid = 'user+tag@gmail.com';
      final TransferNoticeReadMarker? marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/$uid/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': uid,
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: uid,
        branchId: 'branch-north',
      );

      expect(marker, isNotNull);
      expect(marker!.transferId, transferId);
    });

    test('rejects a cross-owner punctuation path even with matching data', () {
      // The literal owner UID must not be interpreted as a pattern: a path
      // segment that the regex form would match is still another owner.
      const String uid = 'user+tag@gmail.com';
      final TransferNoticeReadMarker? marker = parseTransferNoticeReadMarker(
        CatalogDocument(
          path:
              'transferNoticeReads/userrrrtag@gmailcom/branches/branch-north/transfers/$transferId',
          data: <String, Object?>{
            'userId': uid,
            'branchId': 'branch-north',
            'transferId': transferId,
            'readAt': readAt,
          },
        ),
        userId: uid,
        branchId: 'branch-north',
      );

      expect(marker, isNull);
    });
  });
}
