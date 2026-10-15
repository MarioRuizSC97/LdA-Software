import 'dart:math';

/// Exact server contract for stock intake requests and results.
///
/// The callable accepts exactly `{idempotencyKey, branchId, productId,
/// quantity, unitCostMxn}` and answers exactly seven fields: `entryId`,
/// `movementId`, `quantityScaled`, `stockQuantityScaled`,
/// `unitCostCentavos`, `lineTotalCentavos`, `replayed`.
const int maxSafeStockInteger = 9007199254740991;

final BigInt _maxSafeBigInt = BigInt.from(maxSafeStockInteger);
final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
final RegExp _quantityPattern = RegExp(r'^(?:0|[1-9]\d*)(?:\.(\d+))?$');
final RegExp _moneyPattern = RegExp(r'^(?:0|[1-9]\d*)(?:\.(\d{1,2}))?$');
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

const int _maxQuantityInputLength = 18;
const int _maxCostInputLength = 17;
const int _maxDecimalPrecision = 6;

/// Historical policy id persisted with every accepted intake entry.
const String stockIntakeCalculationPolicyVersion = 'mxn-unit-cost-truncate-v1';

/// Immutable per-product quantity specification frozen into every draft.
///
/// Mirrors the server's `createQuantitySpec`: a lowercase unit identifier and
/// a precision from 0 through 6 decimal places. Quantities are stored as
/// scaled safe integers in that unit; changing either field requires an
/// explicit product migration outside this contract.
class StockIntakeQuantitySpec {
  const StockIntakeQuantitySpec({required this.unit, required this.precision});

  final String unit;
  final int precision;

  void validate() {
    if (!_unitPattern.hasMatch(unit)) {
      throw const StockIntakeValidationException(
        'La unidad debe ser un identificador en minúsculas de 1 a 32 caracteres.',
      );
    }
    if (precision < 0 || precision > _maxDecimalPrecision) {
      throw const StockIntakeValidationException(
        'La precisión de cantidad debe ser un entero del 0 al 6.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StockIntakeQuantitySpec &&
      other.unit == unit &&
      other.precision == precision;

  @override
  int get hashCode => Object.hash(unit, precision);
}

/// Immutable, fully validated stock-intake request.
///
/// The product's quantity specification is frozen at creation; quantities are
/// canonical decimal strings scaled with BigInt arithmetic only. Binary
/// floating point is deliberately never used anywhere in this contract.
class StockIntakeDraft {
  const StockIntakeDraft({
    required this.idempotencyKey,
    required this.branchId,
    required this.productId,
    required this.quantity,
    required this.unitCostMxn,
    required this.quantitySpec,
  });

  final String idempotencyKey;
  final String branchId;
  final String productId;
  final String quantity;
  final String unitCostMxn;
  final StockIntakeQuantitySpec quantitySpec;

  /// Historical truncation policy id mirrored from the server contract.
  static const String calculationPolicyVersion =
      stockIntakeCalculationPolicyVersion;

  /// Exact scaled quantity as a safe integer, per the frozen specification.
  int get quantityScaled {
    validate();
    return _computeScaledQuantity().toInt();
  }

  /// Exact unit cost in MXN centavos as a safe non-negative integer.
  int get unitCostCentavos {
    validate();
    return _computeUnitCostCentavos().toInt();
  }

  /// Line total truncated toward zero to centavos, exactly as the server:
  /// `(quantityScaled * unitCostCentavos) ~/ 10^precision`.
  int get lineTotalCentavos {
    validate();
    return _computeLineTotalCentavos().toInt();
  }

  /// Fails closed unless every request field is acceptable.
  ///
  /// This also rejects requests whose fractional line total would overflow
  /// the safe integer bound the server enforces, so `toRequest()` never
  /// emits a request the server would answer with `out-of-range`.
  void validate() {
    if (!_idPattern.hasMatch(idempotencyKey) ||
        !_idPattern.hasMatch(branchId) ||
        !_idPattern.hasMatch(productId)) {
      throw const StockIntakeValidationException(
        'Los identificadores de idempotencia, sucursal y producto deben tener '
        'de 1 a 128 caracteres alfanuméricos (con - o _ internos).',
      );
    }
    quantitySpec.validate();
    _validateQuantity();
    _validateUnitCost();
    _computeLineTotalCentavos();
  }

  /// The exact five-field server request, without normalization.
  Map<String, Object?> toRequest() {
    validate();
    return <String, Object?>{
      'idempotencyKey': idempotencyKey,
      'branchId': branchId,
      'productId': productId,
      'quantity': quantity,
      'unitCostMxn': unitCostMxn,
    };
  }

  void _validateQuantity() {
    if (quantity.length > _maxQuantityInputLength ||
        !_quantityPattern.hasMatch(quantity)) {
      throw const StockIntakeValidationException(
        'La cantidad debe ser un decimal positivo de máximo 18 caracteres, '
        'sin signo, espacios, comas ni exponentes.',
      );
    }
    final List<String> parts = quantity.split('.');
    final String fraction = parts.length == 1 ? '' : parts[1];
    if (fraction.length > quantitySpec.precision) {
      throw StockIntakeValidationException(
        'La cantidad excede la precisión del producto de '
        '${quantitySpec.precision} decimales; los dígitos de más se '
        'rechazan aunque sean ceros.',
      );
    }
    final BigInt scaled = _computeScaledQuantity();
    if (scaled <= BigInt.zero) {
      throw const StockIntakeValidationException(
        'La cantidad debe ser mayor que cero.',
      );
    }
    if (scaled > _maxSafeBigInt) {
      throw const StockIntakeValidationException(
        'La cantidad excede el límite permitido.',
      );
    }
  }

  void _validateUnitCost() {
    if (unitCostMxn.length > _maxCostInputLength ||
        !_moneyPattern.hasMatch(unitCostMxn)) {
      throw const StockIntakeValidationException(
        'El costo unitario debe ser un monto exacto en MXN, no negativo, con '
        'máximo dos decimales.',
      );
    }
    final BigInt centavos = _computeUnitCostCentavos();
    if (centavos > _maxSafeBigInt) {
      throw const StockIntakeValidationException(
        'El costo unitario excede el límite permitido.',
      );
    }
  }

  BigInt _computeScaledQuantity() {
    final List<String> parts = quantity.split('.');
    final BigInt scale = BigInt.from(10).pow(quantitySpec.precision);
    final String paddedFraction = parts.length == 1
        ? '0'
        : parts[1].padRight(quantitySpec.precision, '0');
    return BigInt.parse(parts[0]) * scale + BigInt.parse(paddedFraction);
  }

  BigInt _computeUnitCostCentavos() {
    final List<String> parts = unitCostMxn.split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100) +
        BigInt.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
  }

  BigInt _computeLineTotalCentavos() {
    final BigInt scale = BigInt.from(10).pow(quantitySpec.precision);
    final BigInt total =
        _computeScaledQuantity() * _computeUnitCostCentavos() ~/ scale;
    if (total < BigInt.zero || total > _maxSafeBigInt) {
      throw const StockIntakeValidationException(
        'El total de la línea excede el límite permitido.',
      );
    }
    return total;
  }

  @override
  bool operator ==(Object other) =>
      other is StockIntakeDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.branchId == branchId &&
      other.productId == productId &&
      other.quantity == quantity &&
      other.unitCostMxn == unitCostMxn &&
      other.quantitySpec == quantitySpec;

  @override
  int get hashCode => Object.hash(
    idempotencyKey,
    branchId,
    productId,
    quantity,
    unitCostMxn,
    quantitySpec,
  );
}

/// Immutable success value parsed from the callable result.
///
/// Requires exactly the seven server fields and verifies that the returned
/// quantity, cost, and line total match the frozen request and that the
/// returned stock projection is a safe non-negative integer at least as
/// large as the requested quantity. Cached stock is deliberately not
/// compared: the server result is authoritative.
class StockIntakeResult {
  const StockIntakeResult._({
    required this.entryId,
    required this.movementId,
    required this.quantityScaled,
    required this.stockQuantityScaled,
    required this.unitCostCentavos,
    required this.lineTotalCentavos,
    required this.replayed,
  });

  factory StockIntakeResult.fromCallable(
    Object? value, {
    required StockIntakeDraft request,
  }) {
    const Set<String> resultKeys = <String>{
      'entryId',
      'movementId',
      'quantityScaled',
      'stockQuantityScaled',
      'unitCostCentavos',
      'lineTotalCentavos',
      'replayed',
    };
    if (value is! Map ||
        value.length != resultKeys.length ||
        !resultKeys.every(value.containsKey)) {
      throw const StockIntakeProtocolException();
    }
    final Object? entryId = value['entryId'];
    final Object? movementId = value['movementId'];
    final Object? quantityScaled = value['quantityScaled'];
    final Object? stockQuantityScaled = value['stockQuantityScaled'];
    final Object? unitCostCentavos = value['unitCostCentavos'];
    final Object? lineTotalCentavos = value['lineTotalCentavos'];
    final Object? replayed = value['replayed'];
    if (entryId is! String ||
        movementId is! String ||
        entryId != request.idempotencyKey ||
        movementId != request.idempotencyKey ||
        replayed is! bool) {
      throw const StockIntakeProtocolException();
    }
    if (quantityScaled is! int ||
        quantityScaled < 0 ||
        quantityScaled > maxSafeStockInteger ||
        quantityScaled != request.quantityScaled ||
        unitCostCentavos is! int ||
        unitCostCentavos < 0 ||
        unitCostCentavos > maxSafeStockInteger ||
        unitCostCentavos != request.unitCostCentavos ||
        lineTotalCentavos is! int ||
        lineTotalCentavos < 0 ||
        lineTotalCentavos > maxSafeStockInteger ||
        lineTotalCentavos != request.lineTotalCentavos ||
        stockQuantityScaled is! int ||
        stockQuantityScaled < 0 ||
        stockQuantityScaled > maxSafeStockInteger ||
        stockQuantityScaled < quantityScaled) {
      throw const StockIntakeProtocolException();
    }
    return StockIntakeResult._(
      entryId: entryId,
      movementId: movementId,
      quantityScaled: quantityScaled,
      stockQuantityScaled: stockQuantityScaled,
      unitCostCentavos: unitCostCentavos,
      lineTotalCentavos: lineTotalCentavos,
      replayed: replayed,
    );
  }

  final String entryId;
  final String movementId;
  final int quantityScaled;
  final int stockQuantityScaled;
  final int unitCostCentavos;
  final int lineTotalCentavos;
  final bool replayed;
}

class StockIntakeValidationException implements Exception {
  const StockIntakeValidationException(this.message);
  final String message;
}

class StockIntakeProtocolException implements Exception {
  const StockIntakeProtocolException();
}

class StockIntakeSessionException implements Exception {
  const StockIntakeSessionException();
}

class StockIntakeUnresolvedException implements Exception {
  const StockIntakeUnresolvedException();
}

class StockIntakeAttempt {
  const StockIntakeAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });
  final String ownerUserId;
  final StockIntakeDraft draft;
  final int revision;
}

class _StoredStockIntakeDraft {
  const _StoredStockIntakeDraft(this.draft, this.revision);
  final StockIntakeDraft draft;
  final int revision;
}

/// Volatile, live-shell-only retry storage keyed by exact user, product, and
/// branch identity — never a delimiter-concatenated key.
///
/// Requests are frozen at `begin` and are immutable; only the current
/// attempt's revision may resolve. Actors, products, and branches are fully
/// isolated by the nested exact maps.
class StockIntakeDraftStore {
  final Map<String, Map<String, Map<String, _StoredStockIntakeDraft>>> _drafts =
      <String, Map<String, Map<String, _StoredStockIntakeDraft>>>{};

  StockIntakeDraft? unresolvedFor(
    String ownerUserId,
    String productId,
    String branchId,
  ) => _drafts[ownerUserId]?[productId]?[branchId]?.draft;

  StockIntakeAttempt begin({
    required String ownerUserId,
    required StockIntakeDraft draft,
  }) {
    if (ownerUserId.isEmpty) throw const StockIntakeSessionException();
    draft.validate();
    final Map<String, Map<String, _StoredStockIntakeDraft>> productDrafts =
        _drafts.putIfAbsent(
          ownerUserId,
          () => <String, Map<String, _StoredStockIntakeDraft>>{},
        );
    final Map<String, _StoredStockIntakeDraft> branchDrafts = productDrafts
        .putIfAbsent(
          draft.productId,
          () => <String, _StoredStockIntakeDraft>{},
        );
    final _StoredStockIntakeDraft? current = branchDrafts[draft.branchId];
    if (current != null && current.draft != draft) {
      throw const StockIntakeUnresolvedException();
    }
    final int revision = (current?.revision ?? 0) + 1;
    branchDrafts[draft.branchId] = _StoredStockIntakeDraft(draft, revision);
    return StockIntakeAttempt._(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(StockIntakeAttempt attempt) {
    final _StoredStockIntakeDraft? current =
        _drafts[attempt.ownerUserId]?[attempt.draft.productId]?[attempt
            .draft
            .branchId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  bool resolve(StockIntakeAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    final Map<String, _StoredStockIntakeDraft> branchDrafts =
        _drafts[attempt.ownerUserId]![attempt.draft.productId]!;
    branchDrafts.remove(attempt.draft.branchId);
    if (branchDrafts.isEmpty) {
      _drafts[attempt.ownerUserId]!.remove(attempt.draft.productId);
    }
    if (_drafts[attempt.ownerUserId]!.isEmpty) {
      _drafts.remove(attempt.ownerUserId);
    }
    return true;
  }

  void retain(StockIntakeAttempt attempt) {
    // begin() froze the request. Stale attempts cannot recreate or replace it.
  }
}

String createStockIntakeUuidV4() {
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
