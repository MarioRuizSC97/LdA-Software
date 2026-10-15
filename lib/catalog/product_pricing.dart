import 'dart:math';

const int maxSafePricingInteger = 9007199254740991;
final RegExp _pricingIdPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
final RegExp _moneyPattern = RegExp(r'^(?:0|[1-9]\d*)(?:\.(\d{1,2}))?$');
final RegExp _ratePattern = RegExp(
  r'^(?:0|[1-9]\d?)(?:\.(\d{1,2}))?$|^100(?:\.0{1,2})?$',
);
const Set<String> _priceModes = <String>{
  'iva-included',
  'iva-additional-on-invoice',
};
const Set<String> _ivaTreatments = <String>{'taxable', 'zero-rated', 'exempt'};
const Set<String> _pricingKeys = <String>{
  'listedPriceCentavos',
  'currency',
  'priceMode',
  'ivaTreatment',
  'ivaRateBasisPoints',
};

abstract interface class ProductPricingGateway {
  Future<ProductPricingResult> setPrice(ProductPricingDraft draft);
}

typedef ProductPricingSubmit = Future<ProductPricingResult> Function(
  ProductPricingDraft draft,
);
typedef ProductPricingIdFactory = String Function();

class ProductPricingDraft {
  const ProductPricingDraft({
    required this.idempotencyKey,
    required this.productId,
    required this.listedPriceMxn,
    required this.priceMode,
    required this.ivaTreatment,
    required this.ivaRatePercent,
  });

  final String idempotencyKey;
  final String productId;
  final String listedPriceMxn;
  final String priceMode;
  final String ivaTreatment;
  final String? ivaRatePercent;

  ProductPricingDraft copyWith({
    String? idempotencyKey,
    String? productId,
    String? listedPriceMxn,
    String? priceMode,
    String? ivaTreatment,
    String? ivaRatePercent,
    bool clearIvaRatePercent = false,
  }) => ProductPricingDraft(
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    productId: productId ?? this.productId,
    listedPriceMxn: listedPriceMxn ?? this.listedPriceMxn,
    priceMode: priceMode ?? this.priceMode,
    ivaTreatment: ivaTreatment ?? this.ivaTreatment,
    ivaRatePercent: clearIvaRatePercent
        ? null
        : ivaRatePercent ?? this.ivaRatePercent,
  );

  int get listedPriceCentavos {
    validate();
    final List<String> parts = listedPriceMxn.split('.');
    final BigInt centavos =
        BigInt.parse(parts[0]) * BigInt.from(100) +
        BigInt.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
    return centavos.toInt();
  }

  int? get ivaRateBasisPoints {
    validate();
    if (ivaRatePercent == null) return null;
    final List<String> parts = ivaRatePercent!.split('.');
    return int.parse(parts[0]) * 100 +
        int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
  }

  void validate() {
    if (!_pricingIdPattern.hasMatch(idempotencyKey) ||
        !_pricingIdPattern.hasMatch(productId)) {
      throw const ProductPricingValidationException(
        'Los identificadores de solicitud y producto deben tener de 1 a 128 caracteres válidos.',
      );
    }
    if (listedPriceMxn.length > 17 || !_moneyPattern.hasMatch(listedPriceMxn)) {
      throw const ProductPricingValidationException(
        'El precio de lista debe ser un monto exacto en MXN, no negativo, con máximo dos decimales.',
      );
    }
    final List<String> priceParts = listedPriceMxn.split('.');
    final BigInt centavos =
        BigInt.parse(priceParts[0]) * BigInt.from(100) +
        BigInt.parse(
          priceParts.length == 1 ? '0' : priceParts[1].padRight(2, '0'),
        );
    if (centavos > BigInt.from(maxSafePricingInteger)) {
      throw const ProductPricingValidationException(
        'El precio de lista excede el límite permitido.',
      );
    }
    if (!_priceModes.contains(priceMode)) {
      throw const ProductPricingValidationException(
        'Modo de precio no admitido.',
      );
    }
    if (!_ivaTreatments.contains(ivaTreatment)) {
      throw const ProductPricingValidationException(
        'Tratamiento de IVA no admitido.',
      );
    }
    if (ivaTreatment == 'exempt') {
      if (ivaRatePercent != null) {
        throw const ProductPricingValidationException(
          'El IVA exento no debe tener tasa.',
        );
      }
      return;
    }
    final String? rate = ivaRatePercent;
    if (rate == null || !_ratePattern.hasMatch(rate)) {
      throw const ProductPricingValidationException(
        'La tasa de IVA debe ser un porcentaje exacto con máximo dos decimales.',
      );
    }
    final List<String> rateParts = rate.split('.');
    final int basisPoints =
        int.parse(rateParts[0]) * 100 +
        int.parse(rateParts.length == 1 ? '0' : rateParts[1].padRight(2, '0'));
    if (ivaTreatment == 'zero-rated' && basisPoints != 0) {
      throw const ProductPricingValidationException(
        'El IVA a tasa 0% debe usar tasa cero.',
      );
    }
    if (ivaTreatment == 'taxable' && basisPoints == 0) {
      throw const ProductPricingValidationException(
        'El IVA gravado debe usar una tasa positiva.',
      );
    }
  }

  Map<String, Object?> toRequest() {
    validate();
    return <String, Object?>{
      'idempotencyKey': idempotencyKey,
      'productId': productId,
      'listedPriceMxn': listedPriceMxn,
      'priceMode': priceMode,
      'ivaTreatment': ivaTreatment,
      'ivaRatePercent': ivaRatePercent,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ProductPricingDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.productId == productId &&
      other.listedPriceMxn == listedPriceMxn &&
      other.priceMode == priceMode &&
      other.ivaTreatment == ivaTreatment &&
      other.ivaRatePercent == ivaRatePercent;

  @override
  int get hashCode => Object.hash(
    idempotencyKey,
    productId,
    listedPriceMxn,
    priceMode,
    ivaTreatment,
    ivaRatePercent,
  );
}

class ProductPricingValue {
  const ProductPricingValue({
    required this.listedPriceCentavos,
    required this.currency,
    required this.priceMode,
    required this.ivaTreatment,
    required this.ivaRateBasisPoints,
  });

  factory ProductPricingValue.fromCallable(Object? value) {
    if (value is! Map ||
        value.length != _pricingKeys.length ||
        !_pricingKeys.every(value.containsKey)) {
      throw const ProductPricingProtocolException();
    }
    final Object? listedPriceCentavos = value['listedPriceCentavos'];
    final Object? currency = value['currency'];
    final Object? priceMode = value['priceMode'];
    final Object? ivaTreatment = value['ivaTreatment'];
    final Object? ivaRateBasisPoints = value['ivaRateBasisPoints'];
    if (listedPriceCentavos is! int ||
        listedPriceCentavos < 0 ||
        listedPriceCentavos > maxSafePricingInteger ||
        currency != 'MXN' ||
        priceMode is! String ||
        !_priceModes.contains(priceMode) ||
        ivaTreatment is! String ||
        !_ivaTreatments.contains(ivaTreatment) ||
        (ivaTreatment == 'taxable' &&
            (ivaRateBasisPoints is! int ||
                ivaRateBasisPoints < 1 ||
                ivaRateBasisPoints > 10000)) ||
        (ivaTreatment == 'zero-rated' && ivaRateBasisPoints != 0) ||
        (ivaTreatment == 'exempt' && ivaRateBasisPoints != null)) {
      throw const ProductPricingProtocolException();
    }
    return ProductPricingValue(
      listedPriceCentavos: listedPriceCentavos,
      currency: currency as String,
      priceMode: priceMode,
      ivaTreatment: ivaTreatment,
      ivaRateBasisPoints: ivaRateBasisPoints as int?,
    );
  }

  final int listedPriceCentavos;
  final String currency;
  final String priceMode;
  final String ivaTreatment;
  final int? ivaRateBasisPoints;

  bool matches(ProductPricingDraft request) =>
      listedPriceCentavos == request.listedPriceCentavos &&
      currency == 'MXN' &&
      priceMode == request.priceMode &&
      ivaTreatment == request.ivaTreatment &&
      ivaRateBasisPoints == request.ivaRateBasisPoints;
}

class ProductPricingResult {
  const ProductPricingResult({
    required this.auditId,
    required this.productId,
    required this.pricing,
    required this.replayed,
  });

  factory ProductPricingResult.fromCallable(
    Object? value, {
    required ProductPricingDraft request,
  }) {
    if (value is! Map ||
        value.length != 4 ||
        !value.containsKey('auditId') ||
        !value.containsKey('productId') ||
        !value.containsKey('pricing') ||
        !value.containsKey('replayed')) {
      throw const ProductPricingProtocolException();
    }
    final Object? auditId = value['auditId'];
    final Object? productId = value['productId'];
    final Object? replayed = value['replayed'];
    final ProductPricingValue pricing = ProductPricingValue.fromCallable(
      value['pricing'],
    );
    if (auditId != request.idempotencyKey ||
        productId != request.productId ||
        replayed is! bool ||
        !pricing.matches(request)) {
      throw const ProductPricingProtocolException();
    }
    return ProductPricingResult(
      auditId: auditId as String,
      productId: productId as String,
      pricing: pricing,
      replayed: replayed,
    );
  }

  final String auditId;
  final String productId;
  final ProductPricingValue pricing;
  final bool replayed;
}

class ProductPricingValidationException implements Exception {
  const ProductPricingValidationException(this.message);
  final String message;
}

class ProductPricingProtocolException implements Exception {
  const ProductPricingProtocolException();
}

class ProductPricingRejectedException implements Exception {
  const ProductPricingRejectedException({required this.code});
  final String code;
}

class ProductPricingUncertainException implements Exception {
  const ProductPricingUncertainException();
}

class ProductPricingSessionException implements Exception {
  const ProductPricingSessionException();
}

class ProductPricingStaleException implements Exception {
  const ProductPricingStaleException();
}

class ProductPricingUnresolvedException implements Exception {
  const ProductPricingUnresolvedException();
}

class ProductPricingAttempt {
  const ProductPricingAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });
  final String ownerUserId;
  final ProductPricingDraft draft;
  final int revision;
}

class _StoredProductPricingDraft {
  const _StoredProductPricingDraft(this.draft, this.revision);
  final ProductPricingDraft draft;
  final int revision;
}

/// Volatile, live-shell-only storage keyed by exact user and product identity.
class ProductPricingDraftStore {
  final Map<String, Map<String, _StoredProductPricingDraft>> _drafts =
      <String, Map<String, _StoredProductPricingDraft>>{};

  ProductPricingDraft? unresolvedFor(String ownerUserId, String productId) =>
      _drafts[ownerUserId]?[productId]?.draft;

  List<ProductPricingDraft> unresolvedForOwner(String ownerUserId) =>
      (_drafts[ownerUserId]?.values ?? const <_StoredProductPricingDraft>[])
          .map((_StoredProductPricingDraft stored) => stored.draft)
          .toList(growable: false);

  ProductPricingAttempt begin({
    required String ownerUserId,
    required ProductPricingDraft draft,
  }) {
    if (ownerUserId.isEmpty) throw const ProductPricingSessionException();
    draft.validate();
    final Map<String, _StoredProductPricingDraft> ownerDrafts = _drafts
        .putIfAbsent(ownerUserId, () => <String, _StoredProductPricingDraft>{});
    final _StoredProductPricingDraft? current = ownerDrafts[draft.productId];
    if (current != null && current.draft != draft) {
      throw const ProductPricingUnresolvedException();
    }
    final int revision = (current?.revision ?? 0) + 1;
    ownerDrafts[draft.productId] = _StoredProductPricingDraft(draft, revision);
    return ProductPricingAttempt._(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(ProductPricingAttempt attempt) {
    final _StoredProductPricingDraft? current =
        _drafts[attempt.ownerUserId]?[attempt.draft.productId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  bool resolve(ProductPricingAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    final Map<String, _StoredProductPricingDraft> ownerDrafts =
        _drafts[attempt.ownerUserId]!;
    ownerDrafts.remove(attempt.draft.productId);
    if (ownerDrafts.isEmpty) _drafts.remove(attempt.ownerUserId);
    return true;
  }

  void retain(ProductPricingAttempt attempt) {
    // begin() froze the request. Stale attempts cannot recreate or replace it.
  }
}

String createProductPricingUuidV4() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex = bytes
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
