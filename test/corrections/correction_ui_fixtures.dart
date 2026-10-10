import 'dart:async';

import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart' show pinProduct, ribbonProduct;
import 'correction_fixtures.dart';

/// Answers a preview or submit with the generic server-shaped amounts.
const Object answerNormally = Object();

/// Answers a submit as a replay of an already registered correction.
const Object answerReplayed = #replayed;

/// Tape: 10.00 MXN per piece, IVA added on invoice (16%).
const CatalogProduct tapeProduct = CatalogProduct(
  internalCode: 'DEMO-TAPE',
  name: 'Tape',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
  pricing: CatalogPricing(
    listedPriceCentavos: 1000,
    currency: 'MXN',
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

/// Cord: 0.40 MXN per meter, one decimal, IVA included.
const CatalogProduct cordProduct = CatalogProduct(
  internalCode: 'DEMO-CORD',
  name: 'Cord',
  quantitySpec: QuantitySpec(unit: 'meter', precision: 1),
  pricing: CatalogPricing(
    listedPriceCentavos: 40,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);

/// An unpriced product: never offered as a new exchange item.
const CatalogProduct unpricedProduct = CatalogProduct(
  internalCode: 'DEMO-UNPRICED',
  name: 'Unpriced',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);

/// The catalog an exchange form chooses new items from.
const List<CatalogProduct> exchangeCatalog = <CatalogProduct>[
  ribbonProduct,
  pinProduct,
  tapeProduct,
  cordProduct,
  unpricedProduct,
];

const Map<String, String> catalogNames = <String, String>{
  'DEMO-RIBBON': 'Ribbon',
  'DEMO-PIN': 'Pin',
  'DEMO-TAPE': 'Tape',
  'DEMO-CORD': 'Cord',
};

/// Server-shaped v1 calculation of [cart] at the [exchangeCatalog] prices,
/// half-up per line; IVA is added only on invoice for the additive mode.
Map<String, Object?> catalogCalculationFor(
  SaleCart cart, {
  int priceDelta = 0,
}) {
  final List<Object?> lines = <Object?>[];
  int base = 0;
  int additional = 0;
  for (final SaleCartLine line in cart.lines) {
    final CatalogPricing pricing = exchangeCatalog
        .firstWhere(
          (CatalogProduct product) => product.internalCode == line.productId,
        )
        .pricing!;
    final int listed = pricing.listedPriceCentavos + priceDelta;
    final int precision = line.quantitySpec.precision;
    final int scale = BigInt.from(10).pow(precision).toInt();
    final int lineBase =
        (listed * line.quantityScaled * 2 + scale) ~/ (2 * scale);
    final int lineAdditional =
        cart.invoiceRequested &&
            pricing.priceMode == 'iva-additional-on-invoice'
        ? (lineBase * 16 * 2 + 100) ~/ 200
        : 0;
    base += lineBase;
    additional += lineAdditional;
    lines.add(<String, Object?>{
      'quantity': <String, Object?>{
        'version': 1,
        'spec': <String, Object?>{
          'unit': line.quantitySpec.unit,
          'precision': precision,
        },
        'scaled': line.quantityScaled,
        'decimal': formatScaledQuantity(line.quantityScaled, line.quantitySpec),
      },
      'pricing': <String, Object?>{
        'version': 1,
        'currency': 'MXN',
        'listedPriceCentavos': listed,
        'priceMode': pricing.priceMode,
        'ivaTreatment': pricing.ivaTreatment,
        'ivaRateBasisPoints': pricing.ivaRateBasisPoints,
      },
      'baseCentavos': lineBase,
      'additionalIvaCentavos': lineAdditional,
      'includedIvaCentavos': null,
      'totalCentavos': lineBase + lineAdditional,
    });
  }
  return <String, Object?>{
    'version': 1,
    'currency': 'MXN',
    'invoiceRequested': cart.invoiceRequested,
    'calculationPolicy': <String, Object?>{
      'version': 1,
      'rounding': 'half-up',
      'roundingScope': 'per-line',
      'additionalIvaBase': 'rounded-line-base',
      'includedIvaExtraction': 'not-calculated',
    },
    'lines': lines,
    'baseCentavos': base,
    'additionalIvaCentavos': additional,
    'totalCentavos': base + additional,
  };
}

/// The returned part, new items and settlement amounts of an exchange.
Map<String, Object?> _exchangeParts(
  CorrectableSale sale,
  List<CorrectionLine> returnLines,
  SaleCart newItems,
  int priceDelta,
) {
  final Map<String, Object?> returned = returnAmountsFor(returnLines, sale);
  final Map<String, Object?> refund =
      returned['refund']! as Map<String, Object?>;
  final Map<String, Object?> calculation = catalogCalculationFor(
    newItems,
    priceDelta: priceDelta,
  );
  final int returnedTotal = refund['totalCentavos']! as int;
  final int newTotal = calculation['totalCentavos']! as int;
  final int difference = newTotal - returnedTotal;
  return <String, Object?>{
    'returned': <String, Object?>{
      'lines': returned['lines'],
      'baseCentavos': refund['baseCentavos'],
      'additionalIvaCentavos': refund['additionalIvaCentavos'],
      'totalCentavos': returnedTotal,
    },
    'newItems': <String, Object?>{
      'productIds': <Object?>[
        for (final SaleCartLine line in newItems.lines) line.productId,
      ],
      'calculation': calculation,
    },
    'settlement': <String, Object?>{
      'returnedCentavos': returnedTotal,
      'newItemCentavos': newTotal,
      'customerPaysCentavos': difference > 0 ? difference : 0,
      'refundCentavos': difference < 0 ? -difference : 0,
      'refundMethod': sale.paymentMethod.wireValue,
    },
    'invoiced': sale.invoiced,
  };
}

/// Server preview of [request]; [unavailable] products are short of stock,
/// and [priceDelta] moves every current price (a price change).
Map<String, Object?> exchangePreviewJsonFor(
  SaleExchangePreviewRequest request, {
  Set<String> unavailable = const <String>{},
  int priceDelta = 0,
}) => <String, Object?>{
  'saleId': request.saleId,
  ..._exchangeParts(
    request.sale,
    request.returnLines,
    request.newItems,
    priceDelta,
  ),
  'newLines': <Object?>[
    for (final SaleCartLine line in request.newItems.lines)
      <String, Object?>{
        'productId': line.productId,
        'available': !unavailable.contains(line.productId),
      },
  ],
};

Map<String, Object?> exchangeResponseFor(
  SaleExchangeDraft draft, {
  bool replayed = false,
}) {
  final Map<String, Object?> parts = _exchangeParts(
    draft.sale,
    draft.returnLines,
    draft.newItems,
    0,
  );
  final Map<String, Object?> settlement =
      parts['settlement']! as Map<String, Object?>;
  return <String, Object?>{
    'receipt': <String, Object?>{
      'version': 1,
      'exchangeId': draft.idempotencyKey,
      'saleId': draft.saleId,
      'branchId': draft.branchId,
      'reason': draft.reason.wireValue,
      ...parts,
      'settlement': <String, Object?>{
        ...settlement,
        'differencePayment': draft.differencePayment?.toRequest(),
      },
    },
    'replayed': replayed,
  };
}

Map<String, Object?> replacementResponseFor(
  SaleReplacementDraft draft, {
  bool replayed = false,
}) => <String, Object?>{
  'receipt': <String, Object?>{
    'version': 1,
    'replacementId': draft.idempotencyKey,
    'saleId': draft.saleId,
    'branchId': draft.branchId,
    'reason': 'factory-defect',
    'lines': <Object?>[
      for (final CorrectionLine line in draft.lines)
        <String, Object?>{
          'lineIndex': line.lineIndex,
          'productId': line.productId,
          'quantity': formatScaledQuantity(
            line.quantityScaled,
            line.quantitySpec,
          ),
        },
    ],
    'chargeCentavos': 0,
  },
  'replayed': replayed,
};

/// Fake seller correction operations that behave like the shell: one stored
/// correction of any kind per seller. A deterministic rejection drops it; a
/// success keeps it, with its receipt, until that receipt is acknowledged;
/// anything else keeps it unresolved. Queued results are [answerNormally],
/// [answerReplayed], a [Completer] of the receipt (or a `Completer<Object?>`
/// gate completed with it or with an error), or an error to throw.
class FakeCorrections {
  FakeCorrections({this.unresolved});

  SaleCorrectionDraft? unresolved;

  /// The committed correction awaiting acknowledgement.
  CompletedCorrection? completed;
  final List<SaleCorrectionReceipt> acknowledged = <SaleCorrectionReceipt>[];
  final List<Map<String, Object?>> finds = <Map<String, Object?>>[];
  final List<Object> findResults = <Object>[];
  final List<SaleReturnPreviewRequest> previews = <SaleReturnPreviewRequest>[];
  final List<Object> previewResults = <Object>[];
  final List<SaleReturnDraft> submits = <SaleReturnDraft>[];
  final List<Object> submitResults = <Object>[];
  final List<SaleReplacementDraft> replacementSubmits =
      <SaleReplacementDraft>[];
  final List<Object> replacementResults = <Object>[];
  final List<SaleExchangePreviewRequest> exchangePreviews =
      <SaleExchangePreviewRequest>[];

  /// Queued exchange preview answers: [answerNormally], a [Completer], a
  /// JSON function of the request, or an error to throw.
  final List<Object> exchangePreviewResults = <Object>[];
  final List<SaleExchangeDraft> exchangeSubmits = <SaleExchangeDraft>[];
  final List<Object> exchangeResults = <Object>[];
  int _keys = 0;

  String nextKey() {
    _keys += 1;
    return '00000000-0000-4000-8000-${_keys.toString().padLeft(12, '0')}';
  }

  Future<SaleReturnPreview> preview(SaleReturnPreviewRequest request) async {
    previews.add(request);
    final Object result = previewResults.isEmpty
        ? answerNormally
        : previewResults.removeAt(0);
    if (result is Completer<SaleReturnPreview>) return result.future;
    if (identical(result, answerNormally)) {
      return SaleReturnPreview.fromCallable(
        returnPreviewJsonFor(request),
        request: request,
      );
    }
    throw result;
  }

  Future<SaleExchangePreview> previewExchange(
    SaleExchangePreviewRequest request,
  ) async {
    exchangePreviews.add(request);
    final Object result = exchangePreviewResults.isEmpty
        ? answerNormally
        : exchangePreviewResults.removeAt(0);
    if (result is Completer<SaleExchangePreview>) return result.future;
    if (identical(result, answerNormally)) {
      return SaleExchangePreview.fromCallable(
        exchangePreviewJsonFor(request),
        request: request,
      );
    }
    if (result is Map<String, Object?> Function(SaleExchangePreviewRequest)) {
      return SaleExchangePreview.fromCallable(
        result(request),
        request: request,
      );
    }
    throw result;
  }

  Future<R>
  _submit<D extends SaleCorrectionDraft, R extends SaleCorrectionReceipt>(
    D draft,
    List<D> sent,
    List<Object> results,
    R Function(D draft, {required bool replayed}) parse,
  ) async {
    final Object result = results.isEmpty
        ? answerNormally
        : results.removeAt(0);
    // Like the shell, a session refusal happens before the draft is stored.
    if (result is SaleSessionException) throw result;
    final SaleCorrectionDraft? current = unresolved ?? completed?.draft;
    if (current != null && current != draft) {
      throw const CorrectionUnresolvedException();
    }
    completed = null;
    unresolved = draft;
    sent.add(draft);
    try {
      final R receipt;
      if (result is Completer<R>) {
        receipt = await result.future;
      } else if (result is Completer<Object?>) {
        // A gate released later with the receipt, or with an error to throw.
        receipt = (await result.future)! as R;
      } else if (identical(result, answerNormally) ||
          identical(result, answerReplayed)) {
        receipt = parse(draft, replayed: identical(result, answerReplayed));
      } else {
        throw result;
      }
      unresolved = null;
      completed = CompletedCorrection.of(draft, receipt);
      return receipt;
    } on SaleRejectedException {
      unresolved = null;
      rethrow;
    }
  }

  Future<SaleReturnReceipt> submit(SaleReturnDraft draft) => _submit(
    draft,
    submits,
    submitResults,
    (SaleReturnDraft draft, {required bool replayed}) =>
        SaleReturnReceipt.fromCallable(
          returnResponseFor(draft, replayed: replayed),
          draft: draft,
        ),
  );

  Future<SaleReplacementReceipt> submitReplacement(
    SaleReplacementDraft draft,
  ) => _submit(
    draft,
    replacementSubmits,
    replacementResults,
    (SaleReplacementDraft draft, {required bool replayed}) =>
        SaleReplacementReceipt.fromCallable(
          replacementResponseFor(draft, replayed: replayed),
          draft: draft,
        ),
  );

  Future<SaleExchangeReceipt> submitExchange(SaleExchangeDraft draft) =>
      _submit(
        draft,
        exchangeSubmits,
        exchangeResults,
        (SaleExchangeDraft draft, {required bool replayed}) =>
            SaleExchangeReceipt.fromCallable(
              exchangeResponseFor(draft, replayed: replayed),
              draft: draft,
            ),
      );

  Future<CorrectableSale> find(SaleLookupQuery query) async {
    finds.add(query.toRequest());
    final Object result = findResults.isEmpty
        ? lookupSale()
        : findResults.removeAt(0);
    if (result is CorrectableSale) return result;
    if (result is Completer<CorrectableSale>) return result.future;
    throw result;
  }

  SaleCorrections get corrections => SaleCorrections(
    branchId: saleBranchId,
    find: find,
    listRecent: () async => RecentCorrectableSales.fromCallable(
      <String, Object?>{'sales': <Object?>[]},
      query: RecentSalesQuery(),
    ),
    previewReturn: preview,
    submitReturn: submit,
    previewExchange: previewExchange,
    submitReplacement: submitReplacement,
    submitExchange: submitExchange,
    unresolvedDraft: () => unresolved,
    unacknowledged: () => completed,
    acknowledge: (SaleCorrectionReceipt receipt) {
      acknowledged.add(receipt);
      if (identical(completed?.receipt, receipt)) completed = null;
    },
    createKey: nextKey,
  );
}
