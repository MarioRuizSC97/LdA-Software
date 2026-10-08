import 'dart:async';

import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

/// UI fixtures: server-shaped quote and receipt responses computed from any
/// cart, so widget tests can drive real domain parsing end to end.
///
/// Ribbon: 10.00 MXN per meter, IVA added on invoice (16%).
/// Pin: 2.50 MXN each, IVA included.
const CatalogProduct ribbonProduct = CatalogProduct(
  internalCode: 'DEMO-RIBBON',
  name: 'Ribbon',
  quantitySpec: QuantitySpec(unit: 'meter', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 1000,
    currency: 'MXN',
    priceMode: 'iva-additional-on-invoice',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);
const CatalogProduct pinProduct = CatalogProduct(
  internalCode: 'DEMO-PIN',
  name: 'Pin',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
  pricing: CatalogPricing(
    listedPriceCentavos: 250,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);
const Map<String, CatalogProduct> saleProducts = <String, CatalogProduct>{
  'DEMO-RIBBON': ribbonProduct,
  'DEMO-PIN': pinProduct,
};

const String firstSaleKey = '3f2a9c1b-e89b-42d3-a456-426614174000';
const String secondSaleKey = '7c1d0e2f-1a2b-4c3d-8e4f-5a6b7c8d9e0f';
const String paymentMismatchMessage =
    'full payment must equal the authoritative total';

CatalogSnapshot sellerSaleSnapshot({String branchId = 'branch-north'}) =>
    CatalogSnapshot(<CatalogItem>[
      for (final CatalogProduct product in saleProducts.values)
        CatalogItem(
          product: product,
          holdings: <CatalogHolding>[
            CatalogHolding(branchId: branchId, quantityScaled: 1000),
          ],
        ),
    ]);

String _decimal(int scaled, int precision) {
  if (precision == 0) return '$scaled';
  final BigInt scale = BigInt.from(10).pow(precision);
  final BigInt value = BigInt.from(scaled);
  return '${value ~/ scale}.'
      '${(value % scale).toString().padLeft(precision, '0')}';
}

Map<String, Object?> calculationFor(SaleCart cart, {int priceDelta = 0}) {
  final List<Object?> lines = <Object?>[];
  var base = 0;
  var additional = 0;
  for (final SaleCartLine line in cart.lines) {
    final CatalogPricing pricing = saleProducts[line.productId]!.pricing!;
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
        'decimal': _decimal(line.quantityScaled, precision),
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

Map<String, Object?> quoteFor(
  SaleCart cart, {
  Set<String> unavailable = const <String>{},
  int priceDelta = 0,
}) {
  final Map<String, Object?> calculation = calculationFor(
    cart,
    priceDelta: priceDelta,
  );
  return <String, Object?>{
    'calculation': calculation,
    'totalCentavos': calculation['totalCentavos'],
    'lines': <Object?>[
      for (final SaleCartLine line in cart.lines)
        <String, Object?>{
          'productId': line.productId,
          'available': !unavailable.contains(line.productId),
        },
    ],
  };
}

/// Rebuilds the cart a `quoteSale` or `submitSale` request describes.
SaleCart cartForRequest(Map<String, Object?> request) {
  SaleCart cart = SaleCart.empty().withInvoiceRequested(
    request['invoiceRequested']! as bool,
  );
  for (final Object? raw in request['lines']! as List<Object?>) {
    final Map<Object?, Object?> line = raw! as Map<Object?, Object?>;
    final CatalogProduct product = saleProducts[line['productId']]!;
    cart = cart.add(
      SaleCartLine(
        productId: product.internalCode,
        name: product.name,
        quantitySpec: product.quantitySpec,
        quantity: line['quantity']! as String,
      ),
    );
  }
  return cart;
}

Map<String, Object?> submitResponseForRequest(
  Map<String, Object?> request, {
  String branchId = 'branch-north',
  bool replayed = false,
  int priceDelta = 0,
}) {
  final SaleCart cart = cartForRequest(request);
  final String key = request['idempotencyKey']! as String;
  return <String, Object?>{
    'receipt': <String, Object?>{
      'version': 2,
      'saleId': key,
      'branchId': branchId,
      'branchCode': 'NTE',
      'folio': saleFolio('NTE', key),
      'productIds': <Object?>[
        for (final SaleCartLine line in cart.lines) line.productId,
      ],
      'calculation': calculationFor(cart, priceDelta: priceDelta),
      'payment': request['payment'],
    },
    'replayed': replayed,
  };
}

/// In-memory seller checkout backed by a real [SaleDraftStore], mirroring the
/// shell contract: begin before submit, resolve on success or rejection.
class FakeSaleCheckout {
  FakeSaleCheckout({
    this.ownerUserId = 'seller-north',
    this.branchId = 'branch-north',
    List<String> keys = const <String>[firstSaleKey, secondSaleKey],
  }) : _keys = List<String>.of(keys);

  final String ownerUserId;
  final String branchId;
  final List<String> _keys;
  final SaleDraftStore store = SaleDraftStore();
  final List<SaleCart> quotedCarts = <SaleCart>[];
  final List<Completer<SaleQuote>> heldQuotes = <Completer<SaleQuote>>[];
  final List<Object> quoteFailures = <Object>[];
  final List<SaleDraft> submittedDrafts = <SaleDraft>[];
  final List<Object> submitFailures = <Object>[];
  bool holdQuotes = false;
  Completer<void>? holdSubmit;
  Set<String> unavailable = <String>{};
  int priceDelta = 0;

  SaleCheckout get checkout => SaleCheckout(
    branchId: branchId,
    quote: quote,
    submit: submit,
    unresolvedDraft: () => store.unresolvedFor(ownerUserId, branchId),
    createKey: () => _keys.removeAt(0),
  );

  SaleQuote quoteNow(SaleCart cart) => SaleQuote.fromCallable(
    quoteFor(cart, unavailable: unavailable, priceDelta: priceDelta),
    cart: cart,
  );

  Future<SaleQuote> quote(SaleCart cart) async {
    quotedCarts.add(cart);
    if (holdQuotes) {
      final Completer<SaleQuote> held = Completer<SaleQuote>();
      heldQuotes.add(held);
      return held.future;
    }
    if (quoteFailures.isNotEmpty) throw quoteFailures.removeAt(0);
    return quoteNow(cart);
  }

  Future<SaleReceipt> submit(SaleDraft draft) async {
    submittedDrafts.add(draft);
    final SaleAttempt attempt = store.begin(
      ownerUserId: ownerUserId,
      draft: draft,
    );
    final Completer<void>? hold = holdSubmit;
    if (hold != null) await hold.future;
    if (submitFailures.isNotEmpty) {
      final Object failure = submitFailures.removeAt(0);
      if (failure is! SaleUncertainException) store.resolve(attempt);
      throw failure;
    }
    store.resolve(attempt);
    return SaleReceipt.fromCallable(
      submitResponseForRequest(
        draft.toRequest(),
        branchId: branchId,
        priceDelta: priceDelta,
      ),
      draft: draft,
      confirmedAt: DateTime.utc(2026, 10, 8, 18, 30),
    );
  }
}
