import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';

const ProductPricingDraft _taxable = ProductPricingDraft(
  idempotencyKey: '123e4567-e89b-42d3-a456-426614174000',
  productId: 'PRD-COFFEE-001',
  listedPriceMxn: '90071992547409.91',
  priceMode: 'iva-additional-on-invoice',
  ivaTreatment: 'taxable',
  ivaRatePercent: '16.25',
);

void main() {
  group('ProductPricingDraft', () {
    test('serializes exactly the server request without normalization', () {
      expect(_taxable.toRequest(), <String, Object?>{
        'idempotencyKey': '123e4567-e89b-42d3-a456-426614174000',
        'productId': 'PRD-COFFEE-001',
        'listedPriceMxn': '90071992547409.91',
        'priceMode': 'iva-additional-on-invoice',
        'ivaTreatment': 'taxable',
        'ivaRatePercent': '16.25',
      });
    });

    test('parses MXN with exact integer arithmetic at safe boundaries', () {
      expect(_taxable.listedPriceCentavos, 9007199254740991);
      expect(_taxable.copyWith(listedPriceMxn: '0').listedPriceCentavos, 0);
      expect(_taxable.copyWith(listedPriceMxn: '1.2').listedPriceCentavos, 120);
      for (final String invalid in <String>[
        '',
        ' 1',
        '1 ',
        '+1',
        '-1',
        '01',
        '1.000',
        '90071992547409.92',
        '9007199254740991',
      ]) {
        expect(
          _taxable.copyWith(listedPriceMxn: invalid).validate,
          throwsA(isA<ProductPricingValidationException>()),
          reason: invalid,
        );
      }
    });

    test('enforces exact treatment and rate combinations', () {
      expect(_taxable.copyWith(ivaRatePercent: '0.01').ivaRateBasisPoints, 1);
      expect(
        _taxable.copyWith(ivaRatePercent: '100').ivaRateBasisPoints,
        10000,
      );
      expect(
        _taxable
            .copyWith(ivaTreatment: 'zero-rated', ivaRatePercent: '0')
            .ivaRateBasisPoints,
        0,
      );
      expect(
        _taxable
            .copyWith(ivaTreatment: 'exempt', clearIvaRatePercent: true)
            .ivaRateBasisPoints,
        isNull,
      );
      for (final ProductPricingDraft invalid in <ProductPricingDraft>[
        _taxable.copyWith(ivaRatePercent: '0'),
        _taxable.copyWith(ivaRatePercent: '16.000'),
        _taxable.copyWith(ivaRatePercent: '100.01'),
        _taxable.copyWith(ivaRatePercent: ' 16'),
        _taxable.copyWith(ivaTreatment: 'zero-rated', ivaRatePercent: '16'),
        _taxable.copyWith(ivaTreatment: 'exempt'),
      ]) {
        expect(
          invalid.validate,
          throwsA(isA<ProductPricingValidationException>()),
        );
      }
    });

    test('rejects unsupported modes, identifiers, controls, and fields', () {
      for (final ProductPricingDraft invalid in <ProductPricingDraft>[
        _taxable.copyWith(idempotencyKey: ' bad'),
        _taxable.copyWith(productId: 'bad\u0000id'),
        _taxable.copyWith(priceMode: 'threshold'),
        _taxable.copyWith(ivaTreatment: 'standard'),
      ]) {
        expect(
          invalid.validate,
          throwsA(isA<ProductPricingValidationException>()),
        );
      }
    });
  });

  test('accepts only exact success matching the frozen request', () {
    expect(
      ProductPricingResult.fromCallable(<String, Object?>{
        'auditId': _taxable.idempotencyKey,
        'productId': _taxable.productId,
        'pricing': <String, Object?>{
          'listedPriceCentavos': 9007199254740991,
          'currency': 'MXN',
          'priceMode': 'iva-additional-on-invoice',
          'ivaTreatment': 'taxable',
          'ivaRateBasisPoints': 1625,
        },
        'replayed': false,
      }, request: _taxable).pricing.ivaRateBasisPoints,
      1625,
    );

    final Map<String, Object?> valid = <String, Object?>{
      'auditId': _taxable.idempotencyKey,
      'productId': _taxable.productId,
      'pricing': <String, Object?>{
        'listedPriceCentavos': 9007199254740991,
        'currency': 'MXN',
        'priceMode': 'iva-additional-on-invoice',
        'ivaTreatment': 'taxable',
        'ivaRateBasisPoints': 1625,
      },
      'replayed': true,
    };
    for (final Object? invalid in <Object?>[
      null,
      <String, Object?>{...valid, 'extra': true},
      <String, Object?>{...valid, 'auditId': 'other'},
      <String, Object?>{...valid, 'productId': 'PRD-OTHER-001'},
      <String, Object?>{
        ...valid,
        'pricing': <String, Object?>{
          ...(valid['pricing']! as Map<String, Object?>),
          'listedPriceCentavos': 1,
        },
      },
      <String, Object?>{...valid, 'replayed': 'yes'},
    ]) {
      expect(
        () => ProductPricingResult.fromCallable(invalid, request: _taxable),
        throwsA(isA<ProductPricingProtocolException>()),
      );
    }
  });

  group('ProductPricingDraftStore', () {
    test('isolates immutable unresolved requests by owner and product', () {
      final ProductPricingDraftStore store = ProductPricingDraftStore();
      final ProductPricingAttempt coffee = store.begin(
        ownerUserId: 'admin-1',
        draft: _taxable,
      );
      final ProductPricingDraft teaDraft = _taxable.copyWith(
        idempotencyKey: 'tea-key',
        productId: 'PRD-TEA-0002',
      );
      final ProductPricingAttempt tea = store.begin(
        ownerUserId: 'admin-1',
        draft: teaDraft,
      );

      expect(store.unresolvedFor('admin-1', _taxable.productId), _taxable);
      expect(store.unresolvedFor('admin-1', teaDraft.productId), teaDraft);
      expect(store.unresolvedFor('admin-2', _taxable.productId), isNull);
      expect(
        () => store.begin(
          ownerUserId: 'admin-1',
          draft: _taxable.copyWith(
            idempotencyKey: 'replacement-key',
            listedPriceMxn: '1.00',
          ),
        ),
        throwsA(isA<ProductPricingUnresolvedException>()),
      );
      expect(store.resolve(coffee), isTrue);
      expect(store.unresolvedFor('admin-1', teaDraft.productId), teaDraft);
      expect(store.resolve(tea), isTrue);
    });

    test('owner keys remain exact even when UIDs contain delimiters', () {
      final ProductPricingDraftStore store = ProductPricingDraftStore();
      final ProductPricingDraft other = _taxable.copyWith(
        idempotencyKey: 'other-key',
        productId: 'PRD-OTHER-001',
      );
      store.begin(ownerUserId: 'admin-1\u0000other', draft: other);

      expect(store.unresolvedForOwner('admin-1'), isEmpty);
      expect(store.unresolvedFor('admin-1', other.productId), isNull);
      expect(store.unresolvedFor('admin-1\u0000other', other.productId), other);
    });

    test('attempt revisions keep old completions from clearing retries', () {
      final ProductPricingDraftStore store = ProductPricingDraftStore();
      final ProductPricingAttempt old = store.begin(
        ownerUserId: 'admin-1',
        draft: _taxable,
      );
      final ProductPricingAttempt retry = store.begin(
        ownerUserId: 'admin-1',
        draft: _taxable,
      );

      expect(retry.revision, greaterThan(old.revision));
      expect(store.resolve(old), isFalse);
      store.retain(old);
      expect(store.unresolvedFor('admin-1', _taxable.productId), _taxable);
      expect(store.resolve(retry), isTrue);
    });
  });

  test('pricing request IDs are unique RFC 4122 version 4 UUIDs', () {
    final Set<String> keys = <String>{
      for (var index = 0; index < 20; index += 1) createProductPricingUuidV4(),
    };
    expect(keys, hasLength(20));
    for (final String key in keys) {
      expect(
        key,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    }
  });

  test('validation messages are shown to users in Spanish', () {
    expect(
      _taxable.copyWith(ivaTreatment: 'exempt').validate,
      throwsA(
        isA<ProductPricingValidationException>().having(
          (ProductPricingValidationException error) => error.message,
          'message',
          'El IVA exento no debe tener tasa.',
        ),
      ),
    );
  });
}
