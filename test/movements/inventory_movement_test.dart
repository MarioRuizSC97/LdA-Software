import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';

import 'movement_fixtures.dart';

CatalogDocument _document(Map<String, Object?> data, {String id = 'm-1'}) =>
    CatalogDocument(path: 'inventoryMovements/$id', data: data);

/// One transfer leg exactly as the backend writes it: the eight ledger fields
/// plus `transferId`, an administrator actor and no counterpart metadata.
Map<String, Object?> transferLegData({
  required String type,
  required int quantityScaled,
  String? transferId = 'tr-key-1',
  String branchId = 'branch-north',
  Map<String, Object?> references = const <String, Object?>{},
}) => movementData(
  type: type,
  branchId: branchId,
  quantityScaled: quantityScaled,
  actorId: 'administrator-1',
  extra: <String, Object?>{'transferId': ?transferId, ...references},
);

MovementEntry _parse(Map<String, Object?> data) =>
    parseMovementEntry(_document(data));

void main() {
  test('every server movement type has a Spanish label', () {
    final Map<String, String> labels = <String, String>{
      for (final MovementType type in MovementType.values)
        type.wireName: type.label,
    };
    expect(labels, <String, String>{
      'stock-intake': 'Entrada de stock',
      'sale': 'Venta',
      'sale-return': 'Devolución',
      'sale-return-defect': 'Devolución (defecto)',
      'replacement-defect-in': 'Reemplazo (entrada defectuosa)',
      'replacement-out': 'Reemplazo (salida)',
      'exchange-return': 'Cambio (devolución)',
      'exchange-return-defect': 'Cambio (devolución, defecto)',
      'exchange-out': 'Cambio (salida)',
      'transfer-out': 'Traslado (salida)',
      'transfer-in': 'Traslado (entrada)',
    });
  });

  test('formats signed scaled quantities exactly at precision', () {
    expect(formatSignedQuantity(BigInt.from(-250), 2, 'kg'), '-2.50 kg');
    expect(formatSignedQuantity(BigInt.from(-5), 2, 'kg'), '-0.05 kg');
    expect(formatSignedQuantity(BigInt.from(1205), 3, 'l'), '+1.205 l');
    expect(formatSignedQuantity(BigInt.from(3), 0, 'pieza'), '+3 pieza');
    expect(formatSignedQuantity(BigInt.from(-3), 0, 'pieza'), '-3 pieza');
    expect(formatSignedQuantity(BigInt.zero, 1, 'kg'), '0.0 kg');
    expect(
      formatSignedQuantity(BigInt.parse('-9007199254740991'), 6, 'g'),
      '-9007199254.740991 g',
    );
  });

  test('parses a stored movement strictly with a BigInt quantity', () {
    final MovementEntry entry = parseMovementEntry(_document(movementData()));
    expect(entry, isA<InventoryMovement>());
    final InventoryMovement movement = entry as InventoryMovement;
    expect(movement.id, 'm-1');
    expect(movement.type, MovementType.sale);
    expect(movement.branchId, 'branch-north');
    expect(movement.productId, 'PRD-COFFEE-001');
    expect(movement.quantityScaled, BigInt.from(-250));
    expect(movement.unit, 'kg');
    expect(movement.precision, 2);
    expect(movement.actorId, namedSellerId);
    expect(movement.occurredAt, movementTime);
  });

  test('malformed documents become unreadable entries, never throws', () {
    final List<Map<String, Object?>> malformed = <Map<String, Object?>>[
      movementData(type: 'teleport'),
      movementData(branchId: 'north'),
      movementData(unit: 'KG'),
      movementData(precision: 7),
      movementData(actorId: ''),
      movementData(actorId: 'a/b'),
      movementData(occurredAt: 'yesterday'),
      movementData(extra: <String, Object?>{'note': 'private'}),
      <String, Object?>{...movementData(), 'quantityScaled': 2.5},
      <String, Object?>{...movementData()}..remove('actorId'),
    ];
    for (final Map<String, Object?> data in malformed) {
      final MovementEntry entry = parseMovementEntry(_document(data));
      expect(entry, isA<UnreadableMovement>(), reason: '$data');
      expect(entry.id, 'm-1');
    }
    expect(
      parseMovementEntry(
        CatalogDocument(path: 'elsewhere/m-1', data: movementData()),
      ),
      isA<UnreadableMovement>(),
    );
  });

  test('accepts every per-type reference field the server writes', () {
    for (final String key in <String>[
      'entryId',
      'saleId',
      'returnId',
      'replacementId',
      'exchangeId',
    ]) {
      expect(
        parseMovementEntry(
          _document(movementData(extra: <String, Object?>{key: 'ref-1'})),
        ),
        isA<InventoryMovement>(),
      );
    }
    expect(
      parseMovementEntry(
        _document(
          movementData(
            extra: <String, Object?>{
              'exchangeId': 'x',
              'saleId': 's',
              'lineIndex': 0,
              'newLineIndex': 1,
            },
          ),
        ),
      ),
      isA<InventoryMovement>(),
    );
  });

  test('reads both transfer directions with the server labels', () {
    final MovementEntry out = _parse(
      transferLegData(type: 'transfer-out', quantityScaled: -250),
    );
    expect(out, isA<InventoryMovement>());
    final InventoryMovement outLeg = out as InventoryMovement;
    expect(outLeg.type.wireName, 'transfer-out');
    expect(outLeg.type.label, 'Traslado (salida)');
    expect(outLeg.quantityScaled, BigInt.from(-250));
    expect(outLeg.branchId, 'branch-north');
    expect(outLeg.productId, 'PRD-COFFEE-001');
    expect(outLeg.actorId, 'administrator-1');

    final MovementEntry inLeg = _parse(
      transferLegData(
        type: 'transfer-in',
        quantityScaled: 250,
        branchId: 'branch-south',
      ),
    );
    expect(inLeg, isA<InventoryMovement>());
    final InventoryMovement entered = inLeg as InventoryMovement;
    expect(entered.type.wireName, 'transfer-in');
    expect(entered.type.label, 'Traslado (entrada)');
    expect(entered.quantityScaled, BigInt.from(250));
    expect(entered.branchId, 'branch-south');
  });

  test('accepts a transfer key up to the backend leg-identifier bound', () {
    final String key = 'k' * 112;
    // The backend derives `transfer-{key}-{index}-out`, so a 112-character key
    // is the longest one whose last leg id still fits Firestore's 128.
    expect('transfer-$key-49-out'.length, 128);
    expect(
      _parse(
        transferLegData(
          type: 'transfer-out',
          quantityScaled: -1,
          transferId: key,
        ),
      ),
      isA<InventoryMovement>(),
    );
    expect(
      _parse(
        transferLegData(
          type: 'transfer-in',
          quantityScaled: 1,
          transferId: 'k_9-A',
        ),
      ),
      isA<InventoryMovement>(),
    );
  });

  test('rejects a missing, malformed or over-long transfer key', () {
    final List<Map<String, Object?>> rejected = <Map<String, Object?>>[
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: null,
      ),
      transferLegData(type: 'transfer-in', quantityScaled: 1, transferId: ''),
      transferLegData(
        type: 'transfer-in',
        quantityScaled: 1,
        transferId: 'k' * 113,
      ),
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: '_key',
      ),
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: '-key',
      ),
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: 'key one',
      ),
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: 'key.one',
      ),
      transferLegData(
        type: 'transfer-out',
        quantityScaled: -1,
        transferId: 'key/one',
      ),
      <String, Object?>{
        ...transferLegData(type: 'transfer-in', quantityScaled: 1),
        'transferId': 42,
      },
    ];
    for (final Map<String, Object?> data in rejected) {
      expect(_parse(data), isA<UnreadableMovement>(), reason: '$data');
    }
  });

  test('requires the quantity sign to match the transfer direction', () {
    expect(
      _parse(transferLegData(type: 'transfer-out', quantityScaled: -250)),
      isA<InventoryMovement>(),
    );
    expect(
      _parse(transferLegData(type: 'transfer-in', quantityScaled: 250)),
      isA<InventoryMovement>(),
    );
    final List<Map<String, Object?>> wrong = <Map<String, Object?>>[
      transferLegData(type: 'transfer-out', quantityScaled: 250),
      transferLegData(type: 'transfer-out', quantityScaled: 0),
      transferLegData(type: 'transfer-in', quantityScaled: -250),
      transferLegData(type: 'transfer-in', quantityScaled: 0),
    ];
    for (final Map<String, Object?> data in wrong) {
      expect(_parse(data), isA<UnreadableMovement>(), reason: '$data');
    }
  });

  test('keeps each transfer reference inside its own contract', () {
    // A transfer leg carries `transferId` and nothing else.
    for (final String key in <String>[
      'entryId',
      'saleId',
      'returnId',
      'replacementId',
      'exchangeId',
      'lineIndex',
      'newLineIndex',
    ]) {
      expect(
        _parse(
          transferLegData(
            type: 'transfer-out',
            quantityScaled: -1,
            references: <String, Object?>{key: 'ref-1'},
          ),
        ),
        isA<UnreadableMovement>(),
        reason: 'transfer leg with legacy $key',
      );
    }
    // Legacy documents never get a transfer reference.
    expect(
      _parse(movementData(extra: <String, Object?>{'transferId': 'tr-key-1'})),
      isA<UnreadableMovement>(),
    );
    expect(
      _parse(
        movementData(
          type: 'stock-intake',
          quantityScaled: 250,
          extra: <String, Object?>{'entryId': 'e-1', 'transferId': 'tr-key-1'},
        ),
      ),
      isA<UnreadableMovement>(),
    );
    // Existing legacy parsing stays backward compatible.
    for (final String key in <String>[
      'entryId',
      'saleId',
      'returnId',
      'replacementId',
      'exchangeId',
    ]) {
      expect(
        _parse(movementData(extra: <String, Object?>{key: 'ref-1'})),
        isA<InventoryMovement>(),
        reason: 'legacy $key',
      );
    }
  });

  test('actor labels and display-name validation mirror the server', () {
    expect(shortActorId('abcdefghij'), 'abcdef…');
    expect(shortActorId('abc'), 'abc…');
    expect(unnamedSellerLabel('abcdefghij'), 'Vendedor sin nombre (abcdef…)');
    expect(normalizeSellerDisplayName('  Ana  '), 'Ana');
    expect(normalizeSellerDisplayName('   '), isNull);
    expect(normalizeSellerDisplayName('x' * 120), 'x' * 120);
    expect(normalizeSellerDisplayName('x' * 121), isNull);
    expect(normalizeSellerDisplayName('A\u0007na'), isNull);
  });
}
