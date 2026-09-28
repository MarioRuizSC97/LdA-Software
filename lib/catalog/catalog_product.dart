class QuantitySpec {
  const QuantitySpec({required this.unit, required this.precision});

  factory QuantitySpec.fromFirestore(Object? value) {
    if (value is! Map) {
      throw const FormatException('quantitySpec must be a map');
    }
    final Object? unit = value['unit'];
    final Object? precision = value['precision'];
    if (unit is! String || unit.isEmpty || precision is! int) {
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

    final Object? listedPriceCentavos = value['listedPriceCentavos'];
    final Object? currency = value['currency'];
    final Object? priceMode = value['priceMode'];
    final Object? ivaTreatment = value['ivaTreatment'];
    final Object? ivaRateBasisPoints = value['ivaRateBasisPoints'];

    if (listedPriceCentavos is! int || listedPriceCentavos < 0) {
      throw const FormatException(
        'pricing.listedPriceCentavos must be a non-negative integer',
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
    final Object? internalCode = data['internalCode'];
    final Object? name = data['name'];
    if (internalCode is! String || internalCode.isEmpty) {
      throw const FormatException('internalCode is required');
    }
    if (name is! String || name.isEmpty) {
      throw const FormatException('name is required');
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
