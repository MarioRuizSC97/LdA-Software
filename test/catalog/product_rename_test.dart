import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/product_rename.dart';

const ProductRenameDraft _draft = ProductRenameDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  productId: 'PRD-COFFEE-001',
  name: 'Café de especialidad 1 kg',
);

Map<String, Object?> _success({bool replayed = false}) => <String, Object?>{
  'productId': _draft.productId,
  'oldName': 'Café molido',
  'newName': _draft.name,
  'replayed': replayed,
};

void main() {
  group('ProductRenameDraft', () {
    test('serializes exactly the server request, deterministically', () {
      final Map<String, Object?> request = _draft.toRequest();
      expect(request, <String, Object?>{
        'idempotencyKey': '123e4567-e89b-42d3-a456-426614174000',
        'productId': 'PRD-COFFEE-001',
        'name': 'Café de especialidad 1 kg',
      });
      expect(request.keys.toSet().length, 3);
      expect(_draft.toRequest(), request);
    });

    test('accepts canonical names at the 1 and 120 UTF-16 unit boundaries', () {
      expect(_draft.copyWith(name: 'A').name, 'A');
      expect(_draft.copyWith(name: 'a' * 120).name.length, 120);
      // One astral character is two UTF-16 code units, as in the backend.
      expect(_draft.copyWith(name: '𝄞' * 60).name.length, 120);
    });

    test('rejects empty, long, padded, or control-character names', () {
      for (final String invalid in <String>[
        '',
        'a' * 121,
        '𝄞' * 61,
        ' Café',
        'Café ',
        'Café\t',
        '\u0000Café',
        'Café\u001f',
        'Café\u007f',
      ]) {
        expect(
          _draft.copyWith(name: invalid).validate,
          throwsA(isA<ProductRenameValidationException>()),
          reason: 'name: "$invalid"',
        );
      }
    });

    test('enforces the shared 1..128 identifier pattern on both fields', () {
      expect(
        _draft.copyWith(idempotencyKey: 'a' * 128).idempotencyKey.length,
        128,
      );
      expect(_draft.copyWith(productId: 'A-1_b' * 25).productId.length, 125);
      for (final ProductRenameDraft invalid in <ProductRenameDraft>[
        _draft.copyWith(idempotencyKey: 'a' * 129),
        _draft.copyWith(productId: 'a' * 129),
        _draft.copyWith(idempotencyKey: ''),
        _draft.copyWith(productId: ''),
        _draft.copyWith(idempotencyKey: ' bad'),
        _draft.copyWith(productId: 'bad id'),
        _draft.copyWith(idempotencyKey: 'bad\u0000'),
        _draft.copyWith(productId: 'bad+id'),
      ]) {
        expect(
          invalid.validate,
          throwsA(isA<ProductRenameValidationException>()),
        );
      }
    });

    test('copyWith keeps the idempotency key when only the name changes', () {
      final ProductRenameDraft renamed = _draft.copyWith(name: 'Nuevo nombre');
      expect(renamed.idempotencyKey, _draft.idempotencyKey);
      expect(renamed.productId, _draft.productId);
      expect(renamed.name, 'Nuevo nombre');
      expect(renamed, isNot(_draft));
    });
  });

  test('parses the exact success and binds it to the frozen request', () {
    for (final bool replayed in <bool>[false, true]) {
      final ProductRenameResult result = ProductRenameResult.fromCallable(
        _success(replayed: replayed),
        request: _draft,
      );
      expect(result.productId, _draft.productId);
      expect(result.newName, _draft.name);
      expect(result.oldName, 'Café molido');
      expect(result.replayed, replayed);
    }
  });

  test('never infers success from a malformed or unbound response', () {
    final List<Object?> invalidResponses = <Object?>[
      null,
      'ok',
      <String, Object?>{},
      <String, Object?>{..._success(), 'extra': 1},
      <String, Object?>{..._success()}..remove('oldName'),
      <String, Object?>{..._success(), 'productId': 'PRD-OTHER-001'},
      <String, Object?>{..._success(), 'newName': 'Otro nombre'},
      <String, Object?>{..._success(), 'replayed': 'false'},
      <String, Object?>{..._success(), 'oldName': 7},
      <String, Object?>{..._success(), 'productId': 1},
      <String, Object?>{..._success(), 'newName': null},
    ];
    for (final Object? response in invalidResponses) {
      expect(
        () => ProductRenameResult.fromCallable(response, request: _draft),
        throwsA(isA<ProductRenameProtocolException>()),
        reason: 'response: $response',
      );
    }
  });

  test('creates valid, unique idempotency keys', () {
    final RegExp pattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
    final String first = createProductRenameIdempotencyKey();
    expect(first, matches(pattern));
    expect(first.length, 36);
    expect(createProductRenameIdempotencyKey(), isNot(first));
  });
}
