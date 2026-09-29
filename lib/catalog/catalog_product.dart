import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

const Set<String> _productFields = <String>{
  'internalCode',
  'name',
  'quantitySpec',
  'pricing',
  'createdAt',
  'pricingUpdatedAt',
  'lastPricingAuditId',
};
const Set<String> _quantitySpecFields = <String>{'unit', 'precision'};
const Set<String> _pricingFields = <String>{
  'listedPriceCentavos',
  'currency',
  'priceMode',
  'ivaTreatment',
  'ivaRateBasisPoints',
};
final RegExp _internalCodePattern = RegExp(r'^[A-Z][A-Z0-9-]{7,63}$');
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
final RegExp _auditIdPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');

void _requireOnlyKeys(Map<Object?, Object?> value, Set<String> allowed) {
  if (value.keys.any(
    (Object? key) => key is! String || !allowed.contains(key),
  )) {
    throw const FormatException('document contains unsupported fields');
  }
}

void _requireExactKeys(Map<Object?, Object?> value, Set<String> required) {
  _requireOnlyKeys(value, required);
  if (value.length != required.length ||
      required.any((String key) => !value.containsKey(key))) {
    throw const FormatException('document contains missing fields');
  }
}

void _validateOptionalMetadata(Map<String, Object?> data) {
  for (final String field in <String>['createdAt', 'pricingUpdatedAt']) {
    if (data.containsKey(field) &&
        data[field] != null &&
        data[field] is! Timestamp) {
      throw FormatException('$field must be a Firestore timestamp or null');
    }
  }

  if (data.containsKey('lastPricingAuditId')) {
    final Object? auditId = data['lastPricingAuditId'];
    if (auditId != null &&
        (auditId is! String || !_auditIdPattern.hasMatch(auditId))) {
      throw const FormatException(
        'lastPricingAuditId must be a valid identifier or null',
      );
    }
  }
}

class QuantitySpec {
  const QuantitySpec({required this.unit, required this.precision});

  factory QuantitySpec.fromFirestore(Object? value) {
    if (value is! Map) {
      throw const FormatException('quantitySpec must be a map');
    }
    _requireOnlyKeys(value, _quantitySpecFields);
    final Object? unit = value['unit'];
    final Object? precision = value['precision'];
    if (unit is! String ||
        !_unitPattern.hasMatch(unit) ||
        precision is! int ||
        precision < 0 ||
        precision > 6) {
      throw const FormatException('quantitySpec is invalid');
    }
    return QuantitySpec(unit: unit, precision: precision);
  }

  final String unit;
  final int precision;

  Map<String, Object?> toSafeFields() => <String, Object?>{
    'unit': unit,
    'precision': precision,
  };
}

class CatalogPricing {
  const CatalogPricing({
    required this.listedPriceCentavos,
    required this.currency,
    required this.priceMode,
    required this.ivaTreatment,
    required this.ivaRateBasisPoints,
  });

  factory CatalogPricing.fromFirestore(Object? value) {
    if (value is! Map) {
      throw const FormatException('pricing must be a map');
    }
    _requireExactKeys(value, _pricingFields);

    final Object? listedPriceCentavos = value['listedPriceCentavos'];
    final Object? currency = value['currency'];
    final Object? priceMode = value['priceMode'];
    final Object? ivaTreatment = value['ivaTreatment'];
    final Object? ivaRateBasisPoints = value['ivaRateBasisPoints'];

    if (listedPriceCentavos is! int ||
        listedPriceCentavos < 0 ||
        listedPriceCentavos > 9007199254740991) {
      throw const FormatException(
        'pricing.listedPriceCentavos must be a non-negative safe integer',
      );
    }
    if (currency != 'MXN') {
      throw const FormatException('pricing.currency must be MXN');
    }
    if (priceMode != 'iva-included' &&
        priceMode != 'iva-additional-on-invoice') {
      throw const FormatException('pricing.priceMode is invalid');
    }
    if (ivaTreatment is! String) {
      throw const FormatException('pricing.ivaTreatment is invalid');
    }
    switch (ivaTreatment) {
      case 'taxable':
        if (ivaRateBasisPoints is! int ||
            ivaRateBasisPoints < 1 ||
            ivaRateBasisPoints > 10000) {
          throw const FormatException(
            'taxable pricing requires a rate between 1 and 10000',
          );
        }
      case 'zero-rated':
        if (ivaRateBasisPoints != 0) {
          throw const FormatException('zero-rated pricing requires rate 0');
        }
      case 'exempt':
        if (ivaRateBasisPoints != null) {
          throw const FormatException('exempt pricing requires a null rate');
        }
      default:
        throw const FormatException('pricing.ivaTreatment is invalid');
    }

    return CatalogPricing(
      listedPriceCentavos: listedPriceCentavos,
      currency: currency as String,
      priceMode: priceMode as String,
      ivaTreatment: ivaTreatment,
      ivaRateBasisPoints: ivaRateBasisPoints as int?,
    );
  }

  final int listedPriceCentavos;
  final String currency;
  final String priceMode;
  final String ivaTreatment;
  final int? ivaRateBasisPoints;

  Map<String, Object?> toSafeFields() => <String, Object?>{
    'listedPriceCentavos': listedPriceCentavos,
    'currency': currency,
    'priceMode': priceMode,
    'ivaTreatment': ivaTreatment,
    'ivaRateBasisPoints': ivaRateBasisPoints,
  };
}

class CatalogProduct {
  const CatalogProduct({
    required this.internalCode,
    required this.name,
    required this.quantitySpec,
    this.pricing,
  });

  factory CatalogProduct.fromFirestore(Map<String, Object?> data) {
    _requireOnlyKeys(data, _productFields);
    _validateOptionalMetadata(data);
    final Object? internalCode = data['internalCode'];
    final Object? name = data['name'];
    if (internalCode is! String ||
        !_internalCodePattern.hasMatch(internalCode)) {
      throw const FormatException('internalCode is invalid');
    }
    if (name is! String ||
        name.isEmpty ||
        name.length > 120 ||
        name.trim() != name ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
      throw const FormatException('name is invalid');
    }

    return CatalogProduct(
      internalCode: internalCode,
      name: name,
      quantitySpec: QuantitySpec.fromFirestore(data['quantitySpec']),
      pricing: data.containsKey('pricing')
          ? CatalogPricing.fromFirestore(data['pricing'])
          : null,
    );
  }

  final String internalCode;
  final String name;
  final QuantitySpec quantitySpec;
  final CatalogPricing? pricing;

  Map<String, Object?> toSafeFields() {
    return <String, Object?>{
      'internalCode': internalCode,
      'name': name,
      'quantitySpec': quantitySpec.toSafeFields(),
      if (pricing case final CatalogPricing value)
        'pricing': value.toSafeFields(),
    };
  }
}
