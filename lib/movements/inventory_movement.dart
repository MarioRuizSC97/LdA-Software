import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import '../catalog/catalog_product.dart';
import '../catalog/firestore_catalog_repository.dart';

/// Every movement type the server writes, with its Spanish label.
enum MovementType {
  stockIntake('stock-intake', 'Entrada de stock'),
  sale('sale', 'Venta'),
  saleReturn('sale-return', 'Devolución'),
  saleReturnDefect('sale-return-defect', 'Devolución (defecto)'),
  replacementDefectIn(
    'replacement-defect-in',
    'Reemplazo (entrada defectuosa)',
  ),
  replacementOut('replacement-out', 'Reemplazo (salida)'),
  exchangeReturn('exchange-return', 'Cambio (devolución)'),
  exchangeReturnDefect(
    'exchange-return-defect',
    'Cambio (devolución, defecto)',
  ),
  exchangeOut('exchange-out', 'Cambio (salida)');

  const MovementType(this.wireName, this.label);

  final String wireName;
  final String label;

  static MovementType? fromWire(Object? value) {
    for (final MovementType type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

/// One row of the movements query: either a parsed movement or a document
/// that failed strict parsing. Malformed documents stay visible as rows so
/// the list never silently drops audit data.
sealed class MovementEntry {
  const MovementEntry(this.id);

  final String id;
}

class UnreadableMovement extends MovementEntry {
  const UnreadableMovement(super.id);
}

class InventoryMovement extends MovementEntry {
  const InventoryMovement({
    required String id,
    required this.type,
    required this.branchId,
    required this.productId,
    required this.quantityScaled,
    required this.unit,
    required this.precision,
    required this.actorId,
    required this.occurredAt,
  }) : super(id);

  final MovementType type;
  final String branchId;
  final String productId;

  /// Signed: negative leaves stock, positive enters it.
  final BigInt quantityScaled;
  final String unit;
  final int precision;
  final String actorId;
  final DateTime occurredAt;
}

const Set<String> _requiredFields = <String>{
  'type',
  'branchId',
  'productId',
  'quantityScaled',
  'unit',
  'precision',
  'actorId',
  'occurredAt',
};

/// Per-type references the server adds; never shown, only tolerated.
const Set<String> _referenceFields = <String>{
  'entryId',
  'saleId',
  'returnId',
  'replacementId',
  'exchangeId',
  'lineIndex',
  'newLineIndex',
};

final RegExp _branchIdPattern = RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$');
final RegExp _productIdPattern = RegExp(r'^[A-Z][A-Z0-9-]{7,63}$');
final RegExp _controlCharacters = RegExp(r'[\u0000-\u001f\u007f]');

/// Strictly parses one `inventoryMovements/{id}` document. Never throws: any
/// shape violation yields an [UnreadableMovement] with the document id.
MovementEntry parseMovementEntry(CatalogDocument document) {
  final List<String> segments = document.path.split('/');
  final String id = segments.last;
  try {
    if (segments.length != 2 || segments.first != 'inventoryMovements') {
      throw const FormatException('movement path is invalid');
    }
    return _parseMovement(id, document.data);
  } on Object {
    return UnreadableMovement(id);
  }
}

InventoryMovement _parseMovement(String id, Map<String, Object?> data) {
  if (!_requiredFields.every(data.containsKey) ||
      data.keys.any(
        (String key) =>
            !_requiredFields.contains(key) && !_referenceFields.contains(key),
      )) {
    throw const FormatException('movement fields are invalid');
  }
  final MovementType? type = MovementType.fromWire(data['type']);
  final Object? branchId = data['branchId'];
  final Object? productId = data['productId'];
  final Object? quantity = data['quantityScaled'];
  final Object? actorId = data['actorId'];
  final Object? occurredAt = data['occurredAt'];
  if (type == null ||
      branchId is! String ||
      !isBranchId(branchId) ||
      productId is! String ||
      !_productIdPattern.hasMatch(productId) ||
      quantity is! int ||
      !isPathSafeUid(actorId) ||
      occurredAt is! Timestamp) {
    throw const FormatException('movement values are invalid');
  }
  final QuantitySpec spec = QuantitySpec.fromFirestore(<String, Object?>{
    'unit': data['unit'],
    'precision': data['precision'],
  });
  return InventoryMovement(
    id: id,
    type: type,
    branchId: branchId,
    productId: productId,
    quantityScaled: BigInt.from(quantity),
    unit: spec.unit,
    precision: spec.precision,
    actorId: actorId as String,
    occurredAt: occurredAt.toDate(),
  );
}

/// The server's branch id contract, shared by every movements reader.
bool isBranchId(Object? value) =>
    value is String && _branchIdPattern.hasMatch(value);

/// The server's path-safe uid contract (1 to 128 characters, no slash).
bool isPathSafeUid(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'^__.*__$').hasMatch(value) &&
    !_controlCharacters.hasMatch(value);

/// Exact signed decimal at [precision] with the unit, for example `-250` at
/// precision 2 → `-2.50 kg`. Integer arithmetic only.
String formatSignedQuantity(BigInt scaled, int precision, String unit) {
  final String sign = scaled.isNegative
      ? '-'
      : (scaled > BigInt.zero ? '+' : '');
  final String digits = scaled.abs().toString().padLeft(precision + 1, '0');
  final int split = digits.length - precision;
  final String number = precision == 0
      ? digits
      : '${digits.substring(0, split)}.${digits.substring(split)}';
  return '$sign$number $unit';
}

/// The first six characters of a uid followed by an ellipsis.
String shortActorId(String uid) =>
    '${uid.length > 6 ? uid.substring(0, 6) : uid}…';

String unnamedSellerLabel(String uid) =>
    'Vendedor sin nombre (${shortActorId(uid)})';

String unavailableSellerLabel(String uid) =>
    'Nombre no disponible (${shortActorId(uid)})';

/// Mirrors the server's displayName validation: trimmed, 1 to 120
/// characters, no control characters. Returns the trimmed name or null.
String? normalizeSellerDisplayName(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 120 ||
      _controlCharacters.hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}
