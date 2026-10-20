import 'dart:math';

/// Maximum product-name length in UTF-16 code units, identical to the
/// `renameProduct` and `createProduct` backend validation.
const int maxProductRenameNameLength = 120;

final RegExp _renameIdPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
final RegExp _renameControlCharacterPattern = RegExp(r'[\u0000-\u001f\u007f]');

abstract interface class ProductRenameGateway {
  Future<ProductRenameResult> renameProduct(ProductRenameDraft draft);
}

typedef ProductRenameSubmit = Future<ProductRenameResult> Function(
  ProductRenameDraft draft,
);

/// Frozen rename request sent to the `renameProduct` callable.
///
/// Callers must reuse one draft (and therefore its idempotency key) while a
/// rename is unresolved; the backend replays the stored receipt for the same
/// actor, product and name.
class ProductRenameDraft {
  const ProductRenameDraft({
    required this.idempotencyKey,
    required this.productId,
    required this.name,
  });

  final String idempotencyKey;
  final String productId;
  final String name;

  ProductRenameDraft copyWith({
    String? idempotencyKey,
    String? productId,
    String? name,
  }) => ProductRenameDraft(
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    productId: productId ?? this.productId,
    name: name ?? this.name,
  );

  void validate() {
    if (!_renameIdPattern.hasMatch(idempotencyKey) ||
        !_renameIdPattern.hasMatch(productId)) {
      throw const ProductRenameValidationException(
        'Los identificadores de solicitud y producto deben tener de 1 a 128 '
        'caracteres válidos.',
      );
    }
    // Dart strings count UTF-16 code units, exactly like the backend.
    if (name.isEmpty ||
        name.length > maxProductRenameNameLength ||
        name.trim() != name ||
        _renameControlCharacterPattern.hasMatch(name)) {
      throw const ProductRenameValidationException(
        'El nombre debe tener de 1 a 120 caracteres, sin espacios al inicio '
        'o al final ni caracteres de control.',
      );
    }
  }

  /// The exact callable request: these three fields and nothing more.
  Map<String, Object?> toRequest() {
    validate();
    return <String, Object?>{
      'idempotencyKey': idempotencyKey,
      'productId': productId,
      'name': name,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ProductRenameDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.productId == productId &&
      other.name == name;

  @override
  int get hashCode => Object.hash(idempotencyKey, productId, name);
}

/// Verified server confirmation of one applied (or replayed) rename.
class ProductRenameResult {
  const ProductRenameResult({
    required this.productId,
    required this.oldName,
    required this.newName,
    required this.replayed,
  });

  /// Accepts only the exact successful server shape
  /// `{productId, oldName, newName, replayed}` and binds `productId` and
  /// `newName` to the frozen request, so an unrelated or malformed payload
  /// can never be presented as a successful rename.
  factory ProductRenameResult.fromCallable(
    Object? value, {
    required ProductRenameDraft request,
  }) {
    if (value is! Map ||
        value.length != 4 ||
        !value.containsKey('productId') ||
        !value.containsKey('oldName') ||
        !value.containsKey('newName') ||
        !value.containsKey('replayed')) {
      throw const ProductRenameProtocolException();
    }
    final Object? productId = value['productId'];
    final Object? oldName = value['oldName'];
    final Object? newName = value['newName'];
    final Object? replayed = value['replayed'];
    if (productId is! String ||
        oldName is! String ||
        newName is! String ||
        replayed is! bool ||
        productId != request.productId ||
        newName != request.name) {
      throw const ProductRenameProtocolException();
    }
    return ProductRenameResult(
      productId: productId,
      oldName: oldName,
      newName: newName,
      replayed: replayed,
    );
  }

  final String productId;
  final String oldName;
  final String newName;
  final bool replayed;
}

class ProductRenameValidationException implements Exception {
  const ProductRenameValidationException(this.message);
  final String message;
}

class ProductRenameProtocolException implements Exception {
  const ProductRenameProtocolException();
}

class ProductRenameRejectedException implements Exception {
  const ProductRenameRejectedException({required this.code});
  final String code;
}

class ProductRenameUncertainException implements Exception {
  const ProductRenameUncertainException();
}

class ProductRenameSessionException implements Exception {
  const ProductRenameSessionException();
}

class ProductRenameStaleException implements Exception {
  const ProductRenameStaleException();
}

String createProductRenameIdempotencyKey() {
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
