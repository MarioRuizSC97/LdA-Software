import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:lda_inventory/auth/emulator_session.dart';

const EmulatorSession movementsAdministrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession movementsSeller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const String namedSellerId = 'sellerNamed01';
const String unnamedSellerId = 'sellerPlain02';
final DateTime movementTime = DateTime(2026, 10, 8, 19, 42);

/// One stored movement document's data, as the server writes it.
Map<String, Object?> movementData({
  String type = 'sale',
  String branchId = 'branch-north',
  String productId = 'PRD-COFFEE-001',
  int quantityScaled = -250,
  String unit = 'kg',
  int precision = 2,
  String actorId = namedSellerId,
  Object? occurredAt,
  Map<String, Object?> extra = const <String, Object?>{'saleId': 'sale-key'},
}) => <String, Object?>{
  'type': type,
  'branchId': branchId,
  'productId': productId,
  'quantityScaled': quantityScaled,
  'unit': unit,
  'precision': precision,
  'actorId': actorId,
  'occurredAt': occurredAt ?? Timestamp.fromDate(movementTime),
  ...extra,
};
