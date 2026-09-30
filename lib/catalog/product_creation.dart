import 'dart:math';

const int maxProductNameLength = 120;
final RegExp _idempotencyKeyPattern = RegExp(
  r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$',
);
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
final RegExp _controlCharacterPattern = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _internalCodePattern = RegExp(r'^[A-Z][A-Z0-9-]{7,63}$');

abstract interface class ProductCreationGateway {
  Future<ProductCreationResult> create(ProductCreationDraft draft);
}

typedef ProductCreationSubmit = Future<ProductCreationResult> Function(
  ProductCreationDraft draft,
);
typedef ProductDraftIdFactory = String Function();

class ProductCreationDraft {
  const ProductCreationDraft({
    required this.idempotencyKey,
    required this.name,
    required this.unit,
    required this.precision,
  });

  final String idempotencyKey;
  final String name;
  final String unit;
  final int precision;

  void validate() {
    if (!_idempotencyKeyPattern.hasMatch(idempotencyKey)) {
      throw const ProductCreationValidationException(
        'The draft identifier is invalid.',
      );
    }
    if (name.isEmpty ||
        name.length > maxProductNameLength ||
        name.trim() != name ||
        _controlCharacterPattern.hasMatch(name)) {
      throw const ProductCreationValidationException(
        'Name must be canonical text of 1 to 120 characters with no leading, '
        'trailing, or control characters.',
      );
    }
    if (!_unitPattern.hasMatch(unit)) {
      throw const ProductCreationValidationException(
        'Unit must start with a lowercase letter and use only lowercase '
        'letters, numbers, underscores, or hyphens (1 to 32 characters).',
      );
    }
    if (precision < 0 || precision > 6) {
      throw const ProductCreationValidationException(
        'Precision must be an integer from 0 through 6.',
      );
    }
  }

  Map<String, Object?> toRequest() {
    validate();
    return <String, Object?>{
      'idempotencyKey': idempotencyKey,
      'name': name,
      'quantitySpec': <String, Object?>{'unit': unit, 'precision': precision},
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ProductCreationDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.name == name &&
      other.unit == unit &&
      other.precision == precision;

  @override
  int get hashCode => Object.hash(idempotencyKey, name, unit, precision);
}

class ProductCreationResult {
  const ProductCreationResult({
    required this.productId,
    required this.internalCode,
    required this.replayed,
  });

  factory ProductCreationResult.fromCallable(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        !value.containsKey('productId') ||
        !value.containsKey('internalCode') ||
        !value.containsKey('replayed')) {
      throw const ProductCreationProtocolException();
    }
    final Object? productId = value['productId'];
    final Object? internalCode = value['internalCode'];
    final Object? replayed = value['replayed'];
    if (productId is! String ||
        internalCode is! String ||
        productId != internalCode ||
        !_internalCodePattern.hasMatch(internalCode) ||
        replayed is! bool) {
      throw const ProductCreationProtocolException();
    }
    return ProductCreationResult(
      productId: productId,
      internalCode: internalCode,
      replayed: replayed,
    );
  }

  final String productId;
  final String internalCode;
  final bool replayed;

  @override
  bool operator ==(Object other) =>
      other is ProductCreationResult &&
      other.productId == productId &&
      other.internalCode == internalCode &&
      other.replayed == replayed;

  @override
  int get hashCode => Object.hash(productId, internalCode, replayed);
}

class ProductCreationValidationException implements Exception {
  const ProductCreationValidationException(this.message);

  final String message;
}

class ProductCreationProtocolException implements Exception {
  const ProductCreationProtocolException();
}

class ProductCreationRejectedException implements Exception {
  const ProductCreationRejectedException({required this.code});

  final String code;
}

class ProductCreationUncertainException implements Exception {
  const ProductCreationUncertainException();
}

class ProductCreationSessionException implements Exception {
  const ProductCreationSessionException();
}

class ProductCreationStaleException implements Exception {
  const ProductCreationStaleException();
}

class ProductCreationUnresolvedException implements Exception {
  const ProductCreationUnresolvedException();
}

class ProductCreationAttempt {
  const ProductCreationAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });

  final String ownerUserId;
  final ProductCreationDraft draft;
  final int revision;
}

class _StoredProductCreationDraft {
  const _StoredProductCreationDraft({
    required this.draft,
    required this.revision,
  });

  final ProductCreationDraft draft;
  final int revision;
}

/// Volatile shell-owned storage for unresolved mutations.
///
/// This deliberately provides no disk or process-restart persistence. Attempt
/// revisions prevent a late completion from resolving a newer retry or draft.
class ProductCreationDraftStore {
  final Map<String, _StoredProductCreationDraft> _drafts =
      <String, _StoredProductCreationDraft>{};

  ProductCreationDraft? unresolvedFor(String ownerUserId) =>
      _drafts[ownerUserId]?.draft;

  ProductCreationAttempt begin({
    required String ownerUserId,
    required ProductCreationDraft draft,
  }) {
    if (ownerUserId.isEmpty) {
      throw const ProductCreationSessionException();
    }
    draft.validate();
    final _StoredProductCreationDraft? current = _drafts[ownerUserId];
    if (current != null && current.draft != draft) {
      throw const ProductCreationUnresolvedException();
    }
    final int revision = (current?.revision ?? 0) + 1;
    _drafts[ownerUserId] = _StoredProductCreationDraft(
      draft: draft,
      revision: revision,
    );
    return ProductCreationAttempt._(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(ProductCreationAttempt attempt) {
    final _StoredProductCreationDraft? current = _drafts[attempt.ownerUserId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  bool resolve(ProductCreationAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    _drafts.remove(attempt.ownerUserId);
    return true;
  }

  void retain(ProductCreationAttempt attempt) {
    // begin() already froze the request. A stale attempt must never recreate or
    // overwrite the current owner's newer request.
  }
}

class ProductCreationCoordinator {
  ProductCreationCoordinator({
    required ProductDraftIdFactory createIdempotencyKey,
    required this.submitRequest,
    ProductCreationDraft? restoredDraft,
  }) : _createIdempotencyKey = createIdempotencyKey,
       _currentIdempotencyKey =
           restoredDraft?.idempotencyKey ?? createIdempotencyKey(),
       _lockedDraft = restoredDraft {
    restoredDraft?.validate();
  }

  final ProductDraftIdFactory _createIdempotencyKey;
  final ProductCreationSubmit submitRequest;
  String _currentIdempotencyKey;
  ProductCreationDraft? _lockedDraft;
  bool _pending = false;

  String get currentIdempotencyKey => _currentIdempotencyKey;
  ProductCreationDraft? get lockedDraft => _lockedDraft;
  bool get isLocked => _lockedDraft != null;
  bool get isPending => _pending;

  Future<ProductCreationResult> submit({
    required String name,
    required String unit,
    required int precision,
  }) {
    final ProductCreationDraft draft = ProductCreationDraft(
      idempotencyKey: _currentIdempotencyKey,
      name: name,
      unit: unit,
      precision: precision,
    );
    draft.validate();
    return _run(draft);
  }

  Future<ProductCreationResult> retry() {
    final ProductCreationDraft? draft = _lockedDraft;
    if (draft == null) {
      throw StateError('There is no uncertain draft to retry.');
    }
    return _run(draft);
  }

  void closePresentation() {
    // Presentation may close, but an uncertain draft remains locked so reopening
    // cannot silently allocate a new key after a possible server-side success.
  }

  Future<ProductCreationResult> _run(ProductCreationDraft draft) async {
    if (_pending) throw StateError('Product creation is already pending.');
    if (_lockedDraft != null && !identical(_lockedDraft, draft)) {
      throw StateError('The uncertain draft must be resolved before editing.');
    }
    _pending = true;
    _lockedDraft ??= draft;
    try {
      final ProductCreationResult result = await submitRequest(draft);
      _lockedDraft = null;
      _currentIdempotencyKey = _createIdempotencyKey();
      return result;
    } on ProductCreationRejectedException {
      _lockedDraft = null;
      rethrow;
    } on ProductCreationValidationException {
      _lockedDraft = null;
      rethrow;
    } catch (_) {
      rethrow;
    } finally {
      _pending = false;
    }
  }
}

String createProductDraftUuidV4() {
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
