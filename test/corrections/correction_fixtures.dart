import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';

/// Server-shaped correction fixtures built on the invoiced sale fixture:
/// ribbon 2.50 m (base 2500, IVA 400, total 2900; 0.50 m already returned)
/// and pin 3 pieces (base 750, total 750), paid by card, folio NTE-3F2A-9C1B.
const String returnKey = '11111111-2222-4333-8444-555555555555';
const String replacementKey = '22222222-3333-4444-9555-666666666666';
const String exchangeKey = '33333333-4444-4555-a666-777777777777';
const String otherSaleId = '4b5c6d7e-e89b-42d3-a456-426614174999';

Map<String, Object?> lookupSaleJson({
  String saleId = saleKey,
  Object? folio = 'NTE-3F2A-9C1B',
  int createdAt = saleCreatedAtMillis,
  int ribbonReturned = 50,
}) => <String, Object?>{
  'saleId': saleId,
  'folio': folio,
  'createdAt': createdAt,
  'receipt': <String, Object?>{
    'calculation': invoicedCalculation(),
    'payment': <String, Object?>{'method': 'card', 'amountCentavos': 3650},
    'productIds': <Object?>['DEMO-RIBBON', 'DEMO-PIN'],
    'invoiceRequested': true,
  },
  'lines': <Object?>[
    <String, Object?>{
      'lineIndex': 0,
      'soldScaled': 250,
      'returnedScaled': ribbonReturned,
      'remainingScaled': 250 - ribbonReturned,
    },
    <String, Object?>{
      'lineIndex': 1,
      'soldScaled': 3,
      'returnedScaled': 0,
      'remainingScaled': 3,
    },
  ],
};

Map<String, Object?> findResponse() => <String, Object?>{
  'sale': lookupSaleJson(),
};

CorrectableSale lookupSale() => CorrectableSale.fromLookup(
  findResponse(),
  query: SaleLookupQuery.bySaleId(saleKey),
);

SaleReturnDraft returnDraft({String? note = 'Customer changed mind'}) =>
    SaleReturnDraft.create(
      sale: lookupSale(),
      branchId: saleBranchId,
      reason: CorrectionReason.changeOfMind,
      note: note,
      lines: const <ReturnLineInput>[
        ReturnLineInput(
          lineIndex: 0,
          quantity: '1',
          condition: ReturnCondition.good,
        ),
        ReturnLineInput(
          lineIndex: 1,
          quantity: '1',
          condition: ReturnCondition.factoryDefect,
        ),
      ],
      createKey: () => returnKey,
    );

Map<String, Object?> returnReceiptJson() => <String, Object?>{
  'version': 1,
  'returnId': returnKey,
  'saleId': saleKey,
  'branchId': saleBranchId,
  'reason': 'change-of-mind',
  'lines': <Object?>[
    <String, Object?>{
      'lineIndex': 0,
      'productId': 'DEMO-RIBBON',
      'quantity': '1.00',
      'condition': 'good',
      'baseCentavos': 1000,
      'additionalIvaCentavos': 160,
      'totalCentavos': 1160,
    },
    <String, Object?>{
      'lineIndex': 1,
      'productId': 'DEMO-PIN',
      'quantity': '1',
      'condition': 'factory-defect',
      'baseCentavos': 250,
      'additionalIvaCentavos': 0,
      'totalCentavos': 250,
    },
  ],
  'refund': <String, Object?>{
    'method': 'card',
    'baseCentavos': 1250,
    'additionalIvaCentavos': 160,
    'totalCentavos': 1410,
  },
  'invoiced': true,
};

Map<String, Object?> returnResponse({bool replayed = false}) =>
    <String, Object?>{'receipt': returnReceiptJson(), 'replayed': replayed};

SaleReplacementDraft replacementDraft() => SaleReplacementDraft.create(
  sale: lookupSale(),
  branchId: saleBranchId,
  lines: const <ReplacementLineInput>[
    ReplacementLineInput(lineIndex: 1, quantity: '2'),
  ],
  createKey: () => replacementKey,
);

Map<String, Object?> replacementReceiptJson() => <String, Object?>{
  'version': 1,
  'replacementId': replacementKey,
  'saleId': saleKey,
  'branchId': saleBranchId,
  'reason': 'factory-defect',
  'lines': <Object?>[
    <String, Object?>{'lineIndex': 1, 'productId': 'DEMO-PIN', 'quantity': '2'},
  ],
  'chargeCentavos': 0,
};

Map<String, Object?> replacementResponse({bool replayed = false}) =>
    <String, Object?>{
      'receipt': replacementReceiptJson(),
      'replayed': replayed,
    };

/// Tape: precision 0, 10.00 MXN each, IVA added on invoice (16%).
/// 2 → base 2000, IVA 320, total 2320.
final SaleCartLine tapeLine = SaleCartLine(
  productId: 'DEMO-TAPE',
  name: 'Tape',
  quantitySpec: const QuantitySpec(unit: 'piece', precision: 0),
  quantity: '2',
);

SaleExchangeDraft exchangeDraft({
  SaleExchangePayment? payment = const SaleExchangePayment(
    method: SalePaymentMethod.cash,
    amountCentavos: 2070,
  ),
}) => SaleExchangeDraft.create(
  sale: lookupSale(),
  branchId: saleBranchId,
  reason: CorrectionReason.wrongProduct,
  returnLines: const <ReturnLineInput>[
    ReturnLineInput(
      lineIndex: 1,
      quantity: '1',
      condition: ReturnCondition.good,
    ),
  ],
  newItems: SaleCart.empty().add(tapeLine),
  differencePayment: payment,
  createKey: () => exchangeKey,
);

Map<String, Object?> tapeCalculation() => <String, Object?>{
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
  'lines': <Object?>[
    <String, Object?>{
      'quantity': <String, Object?>{
        'version': 1,
        'spec': <String, Object?>{'unit': 'piece', 'precision': 0},
        'scaled': 2,
        'decimal': '2',
      },
      'pricing': <String, Object?>{
        'version': 1,
        'currency': 'MXN',
        'listedPriceCentavos': 1000,
        'priceMode': 'iva-additional-on-invoice',
        'ivaTreatment': 'taxable',
        'ivaRateBasisPoints': 1600,
      },
      'baseCentavos': 2000,
      'additionalIvaCentavos': 320,
      'includedIvaCentavos': null,
      'totalCentavos': 2320,
    },
  ],
  'baseCentavos': 2000,
  'additionalIvaCentavos': 320,
  'totalCentavos': 2320,
};

Map<String, Object?> exchangeReceiptJson() => <String, Object?>{
  'version': 1,
  'exchangeId': exchangeKey,
  'saleId': saleKey,
  'branchId': saleBranchId,
  'reason': 'wrong-product',
  'returned': <String, Object?>{
    'lines': <Object?>[
      <String, Object?>{
        'lineIndex': 1,
        'productId': 'DEMO-PIN',
        'quantity': '1',
        'condition': 'good',
        'baseCentavos': 250,
        'additionalIvaCentavos': 0,
        'totalCentavos': 250,
      },
    ],
    'baseCentavos': 250,
    'additionalIvaCentavos': 0,
    'totalCentavos': 250,
  },
  'newItems': <String, Object?>{
    'productIds': <Object?>['DEMO-TAPE'],
    'calculation': tapeCalculation(),
  },
  'settlement': <String, Object?>{
    'returnedCentavos': 250,
    'newItemCentavos': 2320,
    'customerPaysCentavos': 2070,
    'refundCentavos': 0,
    'refundMethod': 'card',
    'differencePayment': <String, Object?>{
      'method': 'cash',
      'amountCentavos': 2070,
    },
  },
  'invoiced': true,
};

Map<String, Object?> exchangeResponse({bool replayed = false}) =>
    <String, Object?>{'receipt': exchangeReceiptJson(), 'replayed': replayed};
