import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

/// Shared server-shaped fixtures for the sale domain and gateway tests.
///
/// Ribbon: precision 2, 10.00 MXN per meter, IVA added on invoice (16%).
/// 2.5 m → base 2500, IVA 400 when invoiced, total 2900.
/// Pin: precision 0, 2.50 MXN each, IVA included. 3 → base 750, total 750.
const String saleKey = '3f2a9c1b-e89b-42d3-a456-426614174000';
const String saleBranchId = 'branch-north';

final SaleCartLine ribbonLine = SaleCartLine(
  productId: 'DEMO-RIBBON',
  name: 'Ribbon',
  quantitySpec: const QuantitySpec(unit: 'meter', precision: 2),
  quantity: '2.5',
);
final SaleCartLine pinLine = SaleCartLine(
  productId: 'DEMO-PIN',
  name: 'Pin',
  quantitySpec: const QuantitySpec(unit: 'piece', precision: 0),
  quantity: '3',
);

SaleCart invoicedCart() =>
    SaleCart.empty().add(ribbonLine).add(pinLine).withInvoiceRequested(true);

Map<String, Object?> ribbonCalculationLine() => <String, Object?>{
  'quantity': <String, Object?>{
    'version': 1,
    'spec': <String, Object?>{'unit': 'meter', 'precision': 2},
    'scaled': 250,
    'decimal': '2.50',
  },
  'pricing': <String, Object?>{
    'version': 1,
    'currency': 'MXN',
    'listedPriceCentavos': 1000,
    'priceMode': 'iva-additional-on-invoice',
    'ivaTreatment': 'taxable',
    'ivaRateBasisPoints': 1600,
  },
  'baseCentavos': 2500,
  'additionalIvaCentavos': 400,
  'includedIvaCentavos': null,
  'totalCentavos': 2900,
};

Map<String, Object?> pinCalculationLine() => <String, Object?>{
  'quantity': <String, Object?>{
    'version': 1,
    'spec': <String, Object?>{'unit': 'piece', 'precision': 0},
    'scaled': 3,
    'decimal': '3',
  },
  'pricing': <String, Object?>{
    'version': 1,
    'currency': 'MXN',
    'listedPriceCentavos': 250,
    'priceMode': 'iva-included',
    'ivaTreatment': 'taxable',
    'ivaRateBasisPoints': 1600,
  },
  'baseCentavos': 750,
  'additionalIvaCentavos': 0,
  'includedIvaCentavos': null,
  'totalCentavos': 750,
};

Map<String, Object?> invoicedCalculation() => <String, Object?>{
  'version': 1,
  'currency': 'MXN',
  'invoiceRequested': true,
  'calculationPolicy': <String, Object?>{
    'version': 1,
    'rounding': 'half-up',
    'roundingScope': 'per-line',
    'additionalIvaBase': 'rounded-line-base',
    'includedIvaExtraction': 'not-calculated',
  },
  'lines': <Object?>[ribbonCalculationLine(), pinCalculationLine()],
  'baseCentavos': 3250,
  'additionalIvaCentavos': 400,
  'totalCentavos': 3650,
};

Map<String, Object?> quoteResponse({bool pinAvailable = true}) =>
    <String, Object?>{
      'calculation': invoicedCalculation(),
      'totalCentavos': 3650,
      'lines': <Object?>[
        <String, Object?>{'productId': 'DEMO-RIBBON', 'available': true},
        <String, Object?>{'productId': 'DEMO-PIN', 'available': pinAvailable},
      ],
    };

Map<String, Object?> receiptV2({
  String method = 'card',
  int amountCentavos = 3650,
}) => <String, Object?>{
  'version': 2,
  'saleId': saleKey,
  'branchId': saleBranchId,
  'branchCode': 'NTE',
  'folio': 'NTE-3F2A-9C1B',
  'productIds': <Object?>['DEMO-RIBBON', 'DEMO-PIN'],
  'calculation': invoicedCalculation(),
  'payment': <String, Object?>{
    'method': method,
    'amountCentavos': amountCentavos,
  },
};

/// Server sale time in epoch milliseconds: 2026-10-09T01:42:00Z.
const int saleCreatedAtMillis = 1791510120000;

Map<String, Object?> submitResponse({
  bool replayed = false,
  Object? createdAt = saleCreatedAtMillis,
}) => <String, Object?>{
  'receipt': receiptV2(),
  'replayed': replayed,
  'createdAt': createdAt,
};
