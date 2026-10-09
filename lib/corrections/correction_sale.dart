import '../catalog/catalog_product.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_draft.dart' show saleFolio;

/// Days in the fixed global correction window (decision 2): exactly
/// 15×24h from the sale's server createdAt. The server owns and enforces the
/// rule; the client uses it only for display and copy.
const int correctionWindowDays = 15;

/// [correctionWindowDays] as a duration, for display only.
const Duration correctionWindow = Duration(days: correctionWindowDays);

/// Server bounds for `listRecentCorrectableSales`.
const int recentSalesDefaultLimit = 50;
const int recentSalesMaxLimit = 100;

/// Largest epoch millisecond a [DateTime] can represent.
const int _maxDateTimeMillis = 8640000000000000;
const int _folioInputMaxLength = 32;
final RegExp _folioPattern = RegExp(r'^[A-Z]{2,4}-[A-Z0-9]{4}-[A-Z0-9]{4}$');
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

const Set<String> _findResponseKeys = <String>{'sale'};
const Set<String> _listResponseKeys = <String>{'sales'};
const Set<String> _saleKeys = <String>{
  'saleId',
  'folio',
  'createdAt',
  'receipt',
  'lines',
};
const Set<String> _receiptKeys = <String>{
  'calculation',
  'payment',
  'productIds',
  'invoiceRequested',
};
const Set<String> _paymentKeys = <String>{'method', 'amountCentavos'};
const Set<String> _remainingKeys = <String>{
  'lineIndex',
  'soldScaled',
  'returnedScaled',
  'remainingScaled',
};
const Set<String> _calculationKeys = <String>{
  'version',
  'currency',
  'invoiceRequested',
  'calculationPolicy',
  'lines',
  'baseCentavos',
  'additionalIvaCentavos',
  'totalCentavos',
};
const Map<String, Object?> _calculationPolicy = <String, Object?>{
  'version': 1,
  'rounding': 'half-up',
  'roundingScope': 'per-line',
  'additionalIvaBase': 'rounded-line-base',
  'includedIvaExtraction': 'not-calculated',
};
const Set<String> _lineKeys = <String>{
  'quantity',
  'pricing',
  'baseCentavos',
  'additionalIvaCentavos',
  'includedIvaCentavos',
  'totalCentavos',
};
const Set<String> _quantityKeys = <String>{
  'version',
  'spec',
  'scaled',
  'decimal',
};
const Set<String> _specKeys = <String>{'unit', 'precision'};
const Set<String> _pricingKeys = <String>{
  'version',
  'currency',
  'listedPriceCentavos',
  'priceMode',
  'ivaTreatment',
  'ivaRateBasisPoints',
};

/// Why local correction validation failed. The UI maps these to its own
/// copy and never depends on the English [CorrectionValidationException.message].
enum CorrectionValidationReason {
  invalidSaleId,
  invalidFolio,
  invalidLimit,
  noLines,
  unknownLine,
  duplicateLine,
  malformedQuantity,
  tooPrecise,
  notPositive,
  tooLarge,
  exceedsRemaining,
  noNewItems,
  newItemIsReturned,
  invalidPayment,
  noteTooLong,
  invalidDraft,
}

class CorrectionValidationException implements Exception {
  const CorrectionValidationException(
    this.message, {
    this.reason = CorrectionValidationReason.invalidDraft,
  });

  /// English diagnostic for logs and tests, never shown to the seller.
  final String message;
  final CorrectionValidationReason reason;
}

/// A correction callable response did not match the exact contract.
class CorrectionProtocolException implements Exception {
  const CorrectionProtocolException();
}

/// Exactly one of `{saleId}` or `{folio}` for `findCorrectableSale`.
sealed class SaleLookupQuery {
  const SaleLookupQuery._();

  /// The receipt's full sale ID, sent verbatim.
  factory SaleLookupQuery.bySaleId(String saleId) {
    if (!isValidSaleId(saleId)) {
      throw const CorrectionValidationException(
        'Sale ID is invalid.',
        reason: CorrectionValidationReason.invalidSaleId,
      );
    }
    return SaleIdLookup._(saleId);
  }

  /// A typed or dictated folio, trimmed and uppercased like the server does.
  factory SaleLookupQuery.byFolio(String folio) {
    final String normalized = folio.length > _folioInputMaxLength
        ? ''
        : folio.trim().toUpperCase();
    if (!_folioPattern.hasMatch(normalized)) {
      throw const CorrectionValidationException(
        'Folio is invalid.',
        reason: CorrectionValidationReason.invalidFolio,
      );
    }
    return FolioLookup._(normalized);
  }

  Map<String, Object?> toRequest();
}

class SaleIdLookup extends SaleLookupQuery {
  const SaleIdLookup._(this.saleId) : super._();
  final String saleId;

  @override
  Map<String, Object?> toRequest() => <String, Object?>{'saleId': saleId};
}

class FolioLookup extends SaleLookupQuery {
  const FolioLookup._(this.folio) : super._();

  /// Normalized (trimmed, uppercased) folio.
  final String folio;

  @override
  Map<String, Object?> toRequest() => <String, Object?>{'folio': folio};
}

/// `listRecentCorrectableSales` request: `{}` (server default 50) or
/// `{limit}` from 1 through 100.
class RecentSalesQuery {
  RecentSalesQuery({this.limit}) {
    final int? value = limit;
    if (value != null && (value < 1 || value > recentSalesMaxLimit)) {
      throw const CorrectionValidationException(
        'Recent sales limit is out of range.',
        reason: CorrectionValidationReason.invalidLimit,
      );
    }
  }

  final int? limit;
  int get effectiveLimit => limit ?? recentSalesDefaultLimit;

  Map<String, Object?> toRequest() => <String, Object?>{
    if (limit != null) 'limit': limit,
  };
}

/// One sold line with its server-computed returnable state. Quantities are
/// exact scaled integers (unit × 10^precision); decimals are formatted with
/// BigInt at the line precision. Amounts are the sale snapshot, in centavos.
class CorrectableSaleLine {
  const CorrectableSaleLine._({
    required this.lineIndex,
    required this.productId,
    required this.quantitySpec,
    required this.soldScaled,
    required this.returnedScaled,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
  });

  final int lineIndex;
  final String productId;
  final QuantitySpec quantitySpec;
  final int soldScaled;
  final int returnedScaled;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;

  int get remainingScaled => soldScaled - returnedScaled;
  String get soldDecimal => formatScaledQuantity(soldScaled, quantitySpec);
  String get returnedDecimal =>
      formatScaledQuantity(returnedScaled, quantitySpec);
  String get remainingDecimal =>
      formatScaledQuantity(remainingScaled, quantitySpec);
}

/// A sale the seller may correct, as `findCorrectableSale` and
/// `listRecentCorrectableSales` return it. The server never returns product
/// names, the branch, costs or audits; the UI resolves names from its catalog.
class CorrectableSale {
  const CorrectableSale._({
    required this.saleId,
    required this.folio,
    required this.createdAt,
    required this.paymentMethod,
    required this.amountCentavos,
    required this.invoiced,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.lines,
  });

  /// Parses an exact `{sale}` lookup response bound to [query]: the sale ID
  /// must be the requested one, or the folio the searched (normalized) one.
  factory CorrectableSale.fromLookup(
    Object? value, {
    required SaleLookupQuery query,
  }) {
    final CorrectableSale sale = parseCorrectableSale(
      _exact(value, _findResponseKeys)['sale'],
    );
    final bool bound = switch (query) {
      SaleIdLookup(:final String saleId) => sale.saleId == saleId,
      FolioLookup(:final String folio) => sale.folio == folio,
    };
    if (!bound) throw const CorrectionProtocolException();
    return sale;
  }

  final String saleId;

  /// Branch-prefixed receipt folio; null for legacy sales made before folios.
  final String? folio;

  /// Server sale time in UTC.
  final DateTime createdAt;
  final SalePaymentMethod paymentMethod;
  final int amountCentavos;
  final bool invoiced;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final List<CorrectableSaleLine> lines;

  int get totalCentavos => amountCentavos;

  /// End of the correction window (exclusive), from the server sale time.
  /// Only the server decides whether the window is still open.
  DateTime get correctionWindowEndsAt => createdAt.add(correctionWindow);

  bool get hasReturnableQuantity =>
      lines.any((CorrectableSaleLine line) => line.remainingScaled > 0);
}

/// Parsed `listRecentCorrectableSales` result: at most the requested limit,
/// unique, newest first.
class RecentCorrectableSales {
  const RecentCorrectableSales._(this.sales);

  factory RecentCorrectableSales.fromCallable(
    Object? value, {
    required RecentSalesQuery query,
  }) {
    final Object? raw = _exact(value, _listResponseKeys)['sales'];
    if (raw is! List || raw.length > query.effectiveLimit) {
      throw const CorrectionProtocolException();
    }
    final List<CorrectableSale> sales = <CorrectableSale>[];
    final Set<String> seen = <String>{};
    for (final Object? entry in raw) {
      final CorrectableSale sale = parseCorrectableSale(entry);
      if (!seen.add(sale.saleId) ||
          (sales.isNotEmpty && sale.createdAt.isAfter(sales.last.createdAt))) {
        throw const CorrectionProtocolException();
      }
      sales.add(sale);
    }
    return RecentCorrectableSales._(List<CorrectableSale>.unmodifiable(sales));
  }

  final List<CorrectableSale> sales;
}

/// Strict parser for one lookup sale: exact keys at every level, a v1
/// calculation whose sums hold, the payment equal to its total, the folio
/// derived from the sale ID, and per-line sold/returned/remaining quantities
/// consistent with the calculation.
CorrectableSale parseCorrectableSale(Object? value) {
  final Map<Object?, Object?> sale = _exact(value, _saleKeys);
  final Object? saleId = sale['saleId'];
  final Object? folio = sale['folio'];
  final Object? createdAt = sale['createdAt'];
  if (!isValidSaleId(saleId) ||
      createdAt is! int ||
      createdAt < 0 ||
      createdAt > _maxDateTimeMillis ||
      (folio != null && !_validFolio(folio, saleId! as String))) {
    throw const CorrectionProtocolException();
  }
  final Map<Object?, Object?> receipt = _exact(sale['receipt'], _receiptKeys);
  final Object? invoiced = receipt['invoiceRequested'];
  if (invoiced is! bool) throw const CorrectionProtocolException();
  final _Calculation calculation = _calculation(
    receipt['calculation'],
    invoiced,
  );
  final Map<Object?, Object?> payment = _exact(
    receipt['payment'],
    _paymentKeys,
  );
  final SalePaymentMethod? method = SalePaymentMethod.fromWire(
    payment['method'],
  );
  final Object? productIds = receipt['productIds'];
  final Object? remaining = sale['lines'];
  if (method == null ||
      payment['amountCentavos'] != calculation.totalCentavos ||
      productIds is! List ||
      productIds.length != calculation.lines.length ||
      remaining is! List ||
      remaining.length != calculation.lines.length) {
    throw const CorrectionProtocolException();
  }
  final List<CorrectableSaleLine> lines = <CorrectableSaleLine>[];
  for (int index = 0; index < remaining.length; index++) {
    final Object? productId = productIds[index];
    final _CalculationLine sold = calculation.lines[index];
    final Map<Object?, Object?> line = _exact(remaining[index], _remainingKeys);
    final Object? returned = line['returnedScaled'];
    if (!isValidSaleId(productId) ||
        line['lineIndex'] != index ||
        line['soldScaled'] != sold.scaled ||
        returned is! int ||
        returned < 0 ||
        returned > sold.scaled ||
        line['remainingScaled'] != sold.scaled - returned) {
      throw const CorrectionProtocolException();
    }
    lines.add(
      CorrectableSaleLine._(
        lineIndex: index,
        productId: productId! as String,
        quantitySpec: sold.spec,
        soldScaled: sold.scaled,
        returnedScaled: returned,
        baseCentavos: sold.baseCentavos,
        additionalIvaCentavos: sold.additionalIvaCentavos,
        totalCentavos: sold.totalCentavos,
      ),
    );
  }
  return CorrectableSale._(
    saleId: saleId! as String,
    folio: folio as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
    paymentMethod: method,
    amountCentavos: calculation.totalCentavos,
    invoiced: invoiced,
    baseCentavos: calculation.baseCentavos,
    additionalIvaCentavos: calculation.additionalIvaCentavos,
    lines: List<CorrectableSaleLine>.unmodifiable(lines),
  );
}

/// Formats a scaled quantity with BigInt, padded to the spec precision,
/// exactly like the server `formatQuantity`.
String formatScaledQuantity(int scaled, QuantitySpec spec) {
  final int precision = spec.precision;
  if (precision == 0) return '$scaled';
  final BigInt scale = BigInt.from(10).pow(precision);
  final BigInt value = BigInt.from(scaled);
  return '${value ~/ scale}.'
      '${(value % scale).toString().padLeft(precision, '0')}';
}

bool _validFolio(Object folio, String saleId) {
  if (folio is! String || !_folioPattern.hasMatch(folio)) return false;
  try {
    return saleFolio(folio.split('-').first, saleId) == folio;
  } on SaleValidationException {
    return false;
  }
}

class _CalculationLine {
  const _CalculationLine(
    this.spec,
    this.scaled,
    this.baseCentavos,
    this.additionalIvaCentavos,
    this.totalCentavos,
  );
  final QuantitySpec spec;
  final int scaled;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;
}

class _Calculation {
  const _Calculation(
    this.lines,
    this.baseCentavos,
    this.additionalIvaCentavos,
    this.totalCentavos,
  );
  final List<_CalculationLine> lines;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;
}

_Calculation _calculation(Object? value, bool invoiced) {
  final Map<Object?, Object?> calculation = _exact(value, _calculationKeys);
  final Object? rawLines = calculation['lines'];
  if (calculation['version'] != 1 ||
      calculation['currency'] != 'MXN' ||
      calculation['invoiceRequested'] != invoiced ||
      !_sameFlatMap(calculation['calculationPolicy'], _calculationPolicy) ||
      rawLines is! List ||
      rawLines.isEmpty) {
    throw const CorrectionProtocolException();
  }
  final List<_CalculationLine> lines = <_CalculationLine>[];
  int base = 0;
  int additional = 0;
  int total = 0;
  for (final Object? raw in rawLines) {
    final _CalculationLine line = _calculationLine(raw);
    base += line.baseCentavos;
    additional += line.additionalIvaCentavos;
    total += line.totalCentavos;
    if (total > maxSafeSaleInteger) throw const CorrectionProtocolException();
    lines.add(line);
  }
  final int baseCentavos = correctionCentavos(calculation['baseCentavos']);
  final int additionalIvaCentavos = correctionCentavos(
    calculation['additionalIvaCentavos'],
  );
  final int totalCentavos = correctionCentavos(calculation['totalCentavos']);
  if (base != baseCentavos ||
      additional != additionalIvaCentavos ||
      total != totalCentavos) {
    throw const CorrectionProtocolException();
  }
  return _Calculation(
    List<_CalculationLine>.unmodifiable(lines),
    baseCentavos,
    additionalIvaCentavos,
    totalCentavos,
  );
}

_CalculationLine _calculationLine(Object? value) {
  final Map<Object?, Object?> line = _exact(value, _lineKeys);
  final Map<Object?, Object?> quantity = _exact(
    line['quantity'],
    _quantityKeys,
  );
  final Map<Object?, Object?> spec = _exact(quantity['spec'], _specKeys);
  final Map<Object?, Object?> pricing = _exact(line['pricing'], _pricingKeys);
  final Object? unit = spec['unit'];
  final Object? precision = spec['precision'];
  final Object? scaled = quantity['scaled'];
  if (unit is! String ||
      !_unitPattern.hasMatch(unit) ||
      precision is! int ||
      precision < 0 ||
      precision > 6 ||
      scaled is! int ||
      scaled <= 0 ||
      scaled > maxSafeSaleInteger ||
      quantity['version'] != 1 ||
      pricing['version'] != 1 ||
      pricing['currency'] != 'MXN' ||
      pricing['priceMode'] is! String ||
      pricing['ivaTreatment'] is! String ||
      line['includedIvaCentavos'] != null) {
    throw const CorrectionProtocolException();
  }
  final QuantitySpec quantitySpec = QuantitySpec(
    unit: unit,
    precision: precision,
  );
  if (quantity['decimal'] != formatScaledQuantity(scaled, quantitySpec)) {
    throw const CorrectionProtocolException();
  }
  correctionCentavos(pricing['listedPriceCentavos']);
  final int base = correctionCentavos(line['baseCentavos']);
  final int additional = correctionCentavos(line['additionalIvaCentavos']);
  final int total = correctionCentavos(line['totalCentavos']);
  if (base + additional != total) throw const CorrectionProtocolException();
  return _CalculationLine(quantitySpec, scaled, base, additional, total);
}

/// Validates a safe non-negative integer centavo amount.
int correctionCentavos(Object? value) {
  if (value is! int || value < 0 || value > maxSafeSaleInteger) {
    throw const CorrectionProtocolException();
  }
  return value;
}

/// Requires a map with exactly [keys].
Map<Object?, Object?> correctionExact(Object? value, Set<String> keys) =>
    _exact(value, keys);

Map<Object?, Object?> _exact(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const CorrectionProtocolException();
  }
  return value;
}

bool _sameFlatMap(Object? value, Map<String, Object?> expected) {
  if (value is! Map || value.length != expected.length) return false;
  return expected.entries.every(
    (MapEntry<String, Object?> entry) =>
        value.containsKey(entry.key) && value[entry.key] == entry.value,
  );
}
