import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';

import 'movement_fixtures.dart';

CatalogDocument _document(Map<String, Object?> data, {String id = 'm-1'}) =>
    CatalogDocument(path: 'inventoryMovements/$id', data: data);

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
