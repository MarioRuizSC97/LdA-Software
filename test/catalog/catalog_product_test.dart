import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

void main() {
  group('CatalogProduct', () {
    test('maps the nested backend pricing shape and only safe fields', () {
      final CatalogProduct product = CatalogProduct.fromFirestore(
        <String, Object?>{
          'internalCode': 'PRD-COFFEE-001',
          'name': 'Coffee',
          'quantitySpec': <String, Object?>{'unit': 'kg', 'precision': 2},
          'pricing': <String, Object?>{
            'listedPriceCentavos': 12900,
            'currency': 'MXN',
            'priceMode': 'iva-included',
            'ivaTreatment': 'taxable',
            'ivaRateBasisPoints': 1600,
          },
          'acquisitionCostCentavos': 7700,
          'createdBy': 'admin-1',
        },
      );

      expect(product.toSafeFields(), <String, Object?>{
        'internalCode': 'PRD-COFFEE-001',
        'name': 'Coffee',
        'quantitySpec': <String, Object?>{'unit': 'kg', 'precision': 2},
        'pricing': <String, Object?>{
          'listedPriceCentavos': 12900,
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'taxable',
          'ivaRateBasisPoints': 1600,
        },
      });
      expect(
        product.toSafeFields(),
        isNot(contains('acquisitionCostCentavos')),
      );
      expect(product.toSafeFields(), isNot(contains('createdBy')));
    });

    test('preserves absent pricing without inventing values', () {
      final CatalogProduct product = CatalogProduct.fromFirestore(
        <String, Object?>{
          'internalCode': 'PRD-TEA-002',
          'name': 'Tea',
          'quantitySpec': <String, Object?>{'unit': 'piece', 'precision': 0},
        },
      );

      expect(product.pricing, isNull);
      expect(product.toSafeFields().keys, <String>[
        'internalCode',
        'name',
        'quantitySpec',
      ]);
    });

    test('accepts valid exempt and zero-rated pricing combinations', () {
      for (final Map<String, Object?> pricing in <Map<String, Object?>>[
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'exempt',
          'ivaRateBasisPoints': null,
        },
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'currency': 'MXN',
          'priceMode': 'iva-additional-on-invoice',
          'ivaTreatment': 'zero-rated',
          'ivaRateBasisPoints': 0,
        },
      ]) {
        final CatalogProduct product = CatalogProduct.fromFirestore(
          <String, Object?>{
            'internalCode': 'PRD-TEA-002',
            'name': 'Tea',
            'quantitySpec': <String, Object?>{'unit': 'piece', 'precision': 0},
            'pricing': pricing,
          },
        );

        expect(product.toSafeFields()['pricing'], pricing);
      }
    });

    test('rejects malformed pricing and treatment-rate mismatches', () {
      final Map<String, Object?> base = <String, Object?>{
        'internalCode': 'PRD-TEA-002',
        'name': 'Tea',
        'quantitySpec': <String, Object?>{'unit': 'piece', 'precision': 0},
      };

      for (final Object? malformed in <Object?>[
        'not-a-map',
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'priceMode': 'iva-included',
          'ivaTreatment': 'taxable',
          'ivaRateBasisPoints': 1600,
        },
        <String, Object?>{
          'listedPriceCentavos': '5000',
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'taxable',
          'ivaRateBasisPoints': 1600,
        },
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'taxable',
          'ivaRateBasisPoints': 0,
        },
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'zero-rated',
          'ivaRateBasisPoints': 1600,
        },
        <String, Object?>{
          'listedPriceCentavos': 5000,
          'currency': 'MXN',
          'priceMode': 'iva-included',
          'ivaTreatment': 'exempt',
          'ivaRateBasisPoints': 0,
        },
      ]) {
        expect(
          () => CatalogProduct.fromFirestore(<String, Object?>{
            ...base,
            'pricing': malformed,
          }),
          throwsFormatException,
        );
      }
    });
  });

  test('QR payload is exactly the stable backend-valid internal code', () {
    const CatalogProduct product = CatalogProduct(
      internalCode: 'PRD-COFFEE-001',
      name: 'Premium roast',
      quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
      pricing: CatalogPricing(
        listedPriceCentavos: 12900,
        currency: 'MXN',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRateBasisPoints: 1600,
      ),
    );

    expect(ProductQr.payloadFor(product), 'PRD-COFFEE-001');
    expect(ProductQr.payloadFor(product), isNot(contains('Premium roast')));
    expect(ProductQr.payloadFor(product), isNot(contains('12900')));
  });

  test('disconnected Firestore repository fails before any catalog read', () {
    const DisconnectedFirestoreCatalogRepository repository =
        DisconnectedFirestoreCatalogRepository();

    expect(
      repository.fetchProducts(),
      throwsA(isA<CatalogRepositoryUnavailable>()),
    );
  });
}
