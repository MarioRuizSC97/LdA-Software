import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

/// Protected global latest unit cost, never part of a seller-safe product.
class CatalogProductCost {
  const CatalogProductCost._(
    this.productId,
    this.latestUnitCostCentavos,
    this.currency,
    this.sourceEntryId,
    this.updatedAt,
  );

  factory CatalogProductCost.fromFirestore(
    String path,
    Map<String, Object?> data,
  ) {
    final RegExp productPath = RegExp(r'^costs/([A-Z][A-Z0-9-]{7,63})$');
    final RegExp entryId = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
    const Set<String> fields = <String>{
      'latestUnitCostCentavos',
      'currency',
      'sourceEntryId',
      'updatedAt',
    };
    final RegExpMatch? match = productPath.firstMatch(path);
    final Object? cents = data['latestUnitCostCentavos'];
    final Object? source = data['sourceEntryId'];
    final Object? timestamp = data['updatedAt'];
    if (match == null ||
        match.group(0) != path ||
        data.length != fields.length ||
        data.keys.any((String key) => !fields.contains(key)) ||
        cents is! int ||
        cents < 0 ||
        cents > 9007199254740991 ||
        data['currency'] != 'MXN' ||
        source is! String ||
        entryId.stringMatch(source) != source ||
        timestamp is! Timestamp) {
      throw const FormatException('cost document is invalid');
    }
    return CatalogProductCost._(
      match.group(1)!,
      cents,
      'MXN',
      source,
      timestamp,
    );
  }

  final String productId;
  final int latestUnitCostCentavos;
  final String currency;
  final String sourceEntryId;
  final Timestamp updatedAt;
}
