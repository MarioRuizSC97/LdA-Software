import '../catalog/catalog_product.dart';

/// Largest integer the server accepts (`Number.MAX_SAFE_INTEGER`).
const int maxSafeSaleInteger = 9007199254740991;

final BigInt _maxSafeBigInt = BigInt.from(maxSafeSaleInteger);
final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
final RegExp _quantityPattern = RegExp(r'^(?:0|[1-9]\d*)(?:\.(\d+))?$');
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
const int _maxQuantityInputLength = 18;
const int _maxDecimalPrecision = 6;

bool isValidSaleId(Object? value) =>
    value is String && _idPattern.hasMatch(value);

/// Server payment methods, in wire order.
enum SalePaymentMethod {
  cash('cash'),
  card('card'),
  transfer('transfer');

  const SalePaymentMethod(this.wireValue);
  final String wireValue;

  static SalePaymentMethod? fromWire(Object? value) {
    for (final SalePaymentMethod method in values) {
      if (method.wireValue == value) return method;
    }
    return null;
  }
}

/// One validated cart line. The quantity stays the canonical decimal string
/// the seller typed (sent verbatim); it is scaled with BigInt only, against
/// the product's precision, and never through binary floating point.
class SaleCartLine {
  SaleCartLine({
    required this.productId,
    required this.name,
    required this.quantitySpec,
    required this.quantity,
  }) : quantityScaled = _scale(productId, quantitySpec, quantity);

  final String productId;
  final String name;
  final QuantitySpec quantitySpec;
  final String quantity;

  /// Exact quantity in the product unit times 10^precision.
  final int quantityScaled;

  SaleCartLine withQuantity(String value) => SaleCartLine(
    productId: productId,
    name: name,
    quantitySpec: quantitySpec,
    quantity: value,
  );

  Map<String, Object?> toRequestLine() => <String, Object?>{
    'productId': productId,
    'quantity': quantity,
  };

  static int _scale(String productId, QuantitySpec spec, String quantity) {
    if (!isValidSaleId(productId)) {
      throw const SaleValidationException('Product ID is invalid.');
    }
    if (!_unitPattern.hasMatch(spec.unit) ||
        spec.precision < 0 ||
        spec.precision > _maxDecimalPrecision) {
      throw const SaleValidationException('Quantity specification is invalid.');
    }
    final RegExpMatch? match = quantity.length > _maxQuantityInputLength
        ? null
        : _quantityPattern.firstMatch(quantity);
    if (match == null) {
      throw const SaleValidationException(
        'Quantity must be a canonical positive decimal string.',
      );
    }
    final String fraction = match.group(1) ?? '';
    if (fraction.length > spec.precision) {
      throw const SaleValidationException(
        'Quantity exceeds the product precision.',
      );
    }
    final String whole = quantity.split('.').first;
    final String padded = fraction.padRight(spec.precision, '0');
    final BigInt scaled =
        BigInt.parse(whole) * BigInt.from(10).pow(spec.precision) +
        (padded.isEmpty ? BigInt.zero : BigInt.parse(padded));
    if (scaled <= BigInt.zero) {
      throw const SaleValidationException(
        'Quantity must be strictly greater than zero.',
      );
    }
    if (scaled > _maxSafeBigInt) {
      throw const SaleValidationException(
        'Quantity exceeds safe integer bounds.',
      );
    }
    return scaled.toInt();
  }

  @override
  bool operator ==(Object other) =>
      other is SaleCartLine &&
      other.productId == productId &&
      other.name == name &&
      other.quantitySpec.unit == quantitySpec.unit &&
      other.quantitySpec.precision == quantitySpec.precision &&
      other.quantity == quantity;

  @override
  int get hashCode => Object.hash(
    productId,
    name,
    quantitySpec.unit,
    quantitySpec.precision,
    quantity,
  );
}

/// Immutable, ordered cart of unique products plus the invoice option.
///
/// A product appears at most once: adding it again is rejected rather than
/// merged, because the server rejects duplicates and merging two lines could
/// change the per-line rounding. Edit the existing line instead.
class SaleCart {
  SaleCart._(List<SaleCartLine> lines, this.invoiceRequested)
    : lines = List<SaleCartLine>.unmodifiable(lines);

  factory SaleCart.empty() => SaleCart._(const <SaleCartLine>[], false);

  final List<SaleCartLine> lines;
  final bool invoiceRequested;

  bool get isEmpty => lines.isEmpty;
  int get lineCount => lines.length;

  bool contains(String productId) =>
      lines.any((SaleCartLine line) => line.productId == productId);

  SaleCart add(SaleCartLine line) {
    if (contains(line.productId)) {
      throw SaleDuplicateProductException(line.productId);
    }
    return SaleCart._(<SaleCartLine>[...lines, line], invoiceRequested);
  }

  SaleCart updateQuantity(String productId, String quantity) {
    _requireLine(productId);
    return SaleCart._(<SaleCartLine>[
      for (final SaleCartLine line in lines)
        line.productId == productId ? line.withQuantity(quantity) : line,
    ], invoiceRequested);
  }

  SaleCart remove(String productId) {
    _requireLine(productId);
    return SaleCart._(<SaleCartLine>[
      for (final SaleCartLine line in lines)
        if (line.productId != productId) line,
    ], invoiceRequested);
  }

  SaleCart withInvoiceRequested(bool value) => SaleCart._(lines, value);

  /// Exact `quoteSale` request: `{invoiceRequested, lines}`.
  Map<String, Object?> toQuoteRequest() {
    if (isEmpty) {
      throw const SaleValidationException('The cart has no lines.');
    }
    return <String, Object?>{
      'invoiceRequested': invoiceRequested,
      'lines': <Object?>[
        for (final SaleCartLine line in lines) line.toRequestLine(),
      ],
    };
  }

  void _requireLine(String productId) {
    if (!contains(productId)) {
      throw const SaleValidationException('The product is not in the cart.');
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! SaleCart ||
        other.invoiceRequested != invoiceRequested ||
        other.lines.length != lines.length) {
      return false;
    }
    for (int index = 0; index < lines.length; index++) {
      if (other.lines[index] != lines[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(invoiceRequested, Object.hashAll(lines));
}

class SaleValidationException implements Exception {
  const SaleValidationException(this.message);
  final String message;
}

class SaleDuplicateProductException extends SaleValidationException {
  const SaleDuplicateProductException(this.productId)
    : super('The product is already in the cart.');
  final String productId;
}

/// A callable response did not match the exact contract.
class SaleProtocolException implements Exception {
  const SaleProtocolException();
}

/// The signed-in session is not the assigned seller this flow started with.
class SaleSessionException implements Exception {
  const SaleSessionException();
}
