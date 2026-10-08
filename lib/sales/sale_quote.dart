import 'sale_cart.dart';

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
const Set<String> _quoteKeys = <String>{
  'calculation',
  'totalCentavos',
  'lines',
};
const Set<String> _quoteLineKeys = <String>{'productId', 'available'};

/// One server-priced cart line, kept only with what the UI shows.
class SalePricedLine {
  const SalePricedLine({
    required this.productId,
    required this.name,
    required this.quantityDecimal,
    required this.unit,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
  });

  final String productId;
  final String name;

  /// Server-formatted quantity, padded to the product precision.
  final String quantityDecimal;
  final String unit;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;
}

/// The authoritative v1 sale calculation, verified against the cart it priced.
class SaleCalculation {
  const SaleCalculation._({
    required this.lines,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
  });

  /// Strict parser: exact keys at every level, safe non-negative integer
  /// centavos, `total = base + additional IVA` per line and in sum, the
  /// cart's invoice option, and each line's spec and scaled quantity equal to
  /// the cart line at the same position. Pricing is checked for shape only;
  /// the server stays the only pricing authority.
  factory SaleCalculation.fromCallable(
    Object? value, {
    required SaleCart cart,
  }) {
    final Map<Object?, Object?> calculation = _exact(value, _calculationKeys);
    if (calculation['version'] != 1 ||
        calculation['currency'] != 'MXN' ||
        calculation['invoiceRequested'] != cart.invoiceRequested ||
        !_sameFlatMap(calculation['calculationPolicy'], _calculationPolicy)) {
      throw const SaleProtocolException();
    }
    final Object? rawLines = calculation['lines'];
    if (rawLines is! List || rawLines.length != cart.lineCount) {
      throw const SaleProtocolException();
    }
    final List<SalePricedLine> lines = <SalePricedLine>[];
    int base = 0;
    int additional = 0;
    int total = 0;
    for (int index = 0; index < rawLines.length; index++) {
      final SalePricedLine line = _line(rawLines[index], cart.lines[index]);
      base += line.baseCentavos;
      additional += line.additionalIvaCentavos;
      total += line.totalCentavos;
      if (total > maxSafeSaleInteger) throw const SaleProtocolException();
      lines.add(line);
    }
    final int baseCentavos = _centavos(calculation['baseCentavos']);
    final int additionalIvaCentavos = _centavos(
      calculation['additionalIvaCentavos'],
    );
    final int totalCentavos = _centavos(calculation['totalCentavos']);
    if (base != baseCentavos ||
        additional != additionalIvaCentavos ||
        total != totalCentavos ||
        baseCentavos + additionalIvaCentavos != totalCentavos) {
      throw const SaleProtocolException();
    }
    return SaleCalculation._(
      lines: List<SalePricedLine>.unmodifiable(lines),
      baseCentavos: baseCentavos,
      additionalIvaCentavos: additionalIvaCentavos,
      totalCentavos: totalCentavos,
    );
  }

  final List<SalePricedLine> lines;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;

  static SalePricedLine _line(Object? value, SaleCartLine cartLine) {
    final Map<Object?, Object?> line = _exact(value, _lineKeys);
    final Map<Object?, Object?> quantity = _exact(
      line['quantity'],
      _quantityKeys,
    );
    final Map<Object?, Object?> spec = _exact(quantity['spec'], _specKeys);
    final Map<Object?, Object?> pricing = _exact(line['pricing'], _pricingKeys);
    final int precision = cartLine.quantitySpec.precision;
    if (quantity['version'] != 1 ||
        spec['unit'] != cartLine.quantitySpec.unit ||
        spec['precision'] != precision ||
        quantity['scaled'] != cartLine.quantityScaled ||
        quantity['decimal'] != _format(cartLine.quantityScaled, precision) ||
        pricing['version'] != 1 ||
        pricing['currency'] != 'MXN' ||
        line['includedIvaCentavos'] != null) {
      throw const SaleProtocolException();
    }
    _centavos(pricing['listedPriceCentavos']);
    final int base = _centavos(line['baseCentavos']);
    final int additional = _centavos(line['additionalIvaCentavos']);
    final int total = _centavos(line['totalCentavos']);
    if (base + additional != total) throw const SaleProtocolException();
    return SalePricedLine(
      productId: cartLine.productId,
      name: cartLine.name,
      quantityDecimal: quantity['decimal']! as String,
      unit: cartLine.quantitySpec.unit,
      baseCentavos: base,
      additionalIvaCentavos: additional,
      totalCentavos: total,
    );
  }
}

/// Parsed `quoteSale` result for exactly one cart snapshot.
///
/// `totalCentavos` is what `submitSale` would charge right now. Short stock is
/// reported per line in [unavailableProductIds]; a sale may only be drafted
/// from a quote where [allAvailable] is true.
class SaleQuote {
  const SaleQuote._({
    required this.cart,
    required this.calculation,
    required this.unavailableProductIds,
  });

  factory SaleQuote.fromCallable(Object? value, {required SaleCart cart}) {
    final Map<Object?, Object?> quote = _exact(value, _quoteKeys);
    final SaleCalculation calculation = SaleCalculation.fromCallable(
      quote['calculation'],
      cart: cart,
    );
    final Object? lines = quote['lines'];
    if (_centavos(quote['totalCentavos']) != calculation.totalCentavos ||
        lines is! List ||
        lines.length != cart.lineCount) {
      throw const SaleProtocolException();
    }
    final Set<String> unavailable = <String>{};
    for (int index = 0; index < lines.length; index++) {
      final Map<Object?, Object?> line = _exact(lines[index], _quoteLineKeys);
      final Object? available = line['available'];
      if (line['productId'] != cart.lines[index].productId ||
          available is! bool) {
        throw const SaleProtocolException();
      }
      if (!available) unavailable.add(cart.lines[index].productId);
    }
    return SaleQuote._(
      cart: cart,
      calculation: calculation,
      unavailableProductIds: Set<String>.unmodifiable(unavailable),
    );
  }

  final SaleCart cart;
  final SaleCalculation calculation;
  final Set<String> unavailableProductIds;

  bool get allAvailable => unavailableProductIds.isEmpty;
  List<SalePricedLine> get lines => calculation.lines;
  int get baseCentavos => calculation.baseCentavos;
  int get additionalIvaCentavos => calculation.additionalIvaCentavos;
  int get totalCentavos => calculation.totalCentavos;
}

Map<Object?, Object?> _exact(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const SaleProtocolException();
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

/// Validates a safe non-negative integer centavo amount.
int _centavos(Object? value) {
  if (value is! int || value < 0 || value > maxSafeSaleInteger) {
    throw const SaleProtocolException();
  }
  return value;
}

String _format(int scaled, int precision) {
  if (precision == 0) return '$scaled';
  final BigInt scale = BigInt.from(10).pow(precision);
  final BigInt value = BigInt.from(scaled);
  return '${value ~/ scale}.'
      '${(value % scale).toString().padLeft(precision, '0')}';
}
