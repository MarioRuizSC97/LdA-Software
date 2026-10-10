import '../sales/sale_cart.dart';
import '../sales/sale_quote.dart';
import 'correction_draft.dart';
import 'correction_sale.dart';

const Set<String> _responseKeys = <String>{'receipt', 'replayed'};
const Set<String> _previewKeys = <String>{
  'saleId',
  'lines',
  'refund',
  'invoiced',
};
const Set<String> _returnKeys = <String>{
  'version',
  'returnId',
  'saleId',
  'branchId',
  'reason',
  'lines',
  'refund',
  'invoiced',
};
const Set<String> _refundLineKeys = <String>{
  'lineIndex',
  'productId',
  'quantity',
  'condition',
  'baseCentavos',
  'additionalIvaCentavos',
  'totalCentavos',
};
const Set<String> _refundKeys = <String>{
  'method',
  'baseCentavos',
  'additionalIvaCentavos',
  'totalCentavos',
};
const Set<String> _amountKeys = <String>{
  'baseCentavos',
  'additionalIvaCentavos',
  'totalCentavos',
};
const Set<String> _replacementKeys = <String>{
  'version',
  'replacementId',
  'saleId',
  'branchId',
  'reason',
  'lines',
  'chargeCentavos',
};
const Set<String> _replacementLineKeys = <String>{
  'lineIndex',
  'productId',
  'quantity',
};
const Set<String> _exchangeKeys = <String>{
  'version',
  'exchangeId',
  'saleId',
  'branchId',
  'reason',
  'returned',
  'newItems',
  'settlement',
  'invoiced',
};
const Set<String> _returnedKeys = <String>{'lines', ..._amountKeys};
const Set<String> _newItemsKeys = <String>{'productIds', 'calculation'};
const Set<String> _settlementKeys = <String>{
  'returnedCentavos',
  'newItemCentavos',
  'customerPaysCentavos',
  'refundCentavos',
  'refundMethod',
  'differencePayment',
};
const Set<String> _paymentKeys = <String>{'method', 'amountCentavos'};
const Set<String> _exchangePreviewKeys = <String>{
  'saleId',
  'returned',
  'newItems',
  'settlement',
  'newLines',
  'invoiced',
};
const Set<String> _previewSettlementKeys = <String>{
  'returnedCentavos',
  'newItemCentavos',
  'customerPaysCentavos',
  'refundCentavos',
  'refundMethod',
};
const Set<String> _previewNewLineKeys = <String>{'productId', 'available'};

/// Any committed correction receipt. Sealed, so every consumer that shows or
/// recovers a receipt must handle each kind explicitly.
sealed class SaleCorrectionReceipt {
  const SaleCorrectionReceipt();

  /// The correction document ID: always the draft's idempotency key.
  String get correctionId;
  String get saleId;
  String get branchId;

  /// The server answered with an already registered correction.
  bool get replayed;
}

/// One refunded line at the sale's frozen snapshot price.
class CorrectionRefundLine {
  const CorrectionRefundLine._({
    required this.lineIndex,
    required this.productId,
    required this.quantityDecimal,
    required this.quantityScaled,
    required this.condition,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
  });

  final int lineIndex;
  final String productId;

  /// Server-formatted quantity, padded to the line precision.
  final String quantityDecimal;
  final int quantityScaled;
  final ReturnCondition condition;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;
}

/// Parsed v1 `submitSaleReturn` result, bound to the draft that produced it.
///
/// The server returns no correction time, so none is shown: the device
/// clock is not the server's.
class SaleReturnReceipt extends SaleCorrectionReceipt {
  const SaleReturnReceipt._({
    required this.returnId,
    required this.saleId,
    required this.branchId,
    required this.reason,
    required this.lines,
    required this.refundMethod,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
    required this.invoiced,
    required this.replayed,
  });

  /// Requires exactly `{receipt, replayed}` with a v1 receipt whose ID is the
  /// draft key, whose sale, branch and reason are the draft's, whose lines
  /// match the draft lines in order (index, product, condition and quantity by
  /// value), and whose refund uses the sale's payment method and sums the
  /// lines. Amounts are checked for shape, sums and the sale-line bounds; the
  /// exact cumulative split stays a server decision.
  factory SaleReturnReceipt.fromCallable(
    Object? value, {
    required SaleReturnDraft draft,
  }) {
    final (Map<Object?, Object?> receipt, bool replayed) = _response(
      value,
      _returnKeys,
    );
    final Object? invoiced = receipt['invoiced'];
    if (receipt['version'] != 1 ||
        receipt['returnId'] != draft.idempotencyKey ||
        receipt['saleId'] != draft.saleId ||
        receipt['branchId'] != draft.branchId ||
        receipt['reason'] != draft.reason.wireValue ||
        invoiced != draft.sale.invoiced) {
      throw const CorrectionProtocolException();
    }
    final _Refund refund = _refund(
      receipt['lines'],
      draft.lines,
      draft.sale,
      invoiced! as bool,
    );
    final Map<Object?, Object?> totals = correctionExact(
      receipt['refund'],
      _refundKeys,
    );
    final _Amounts amounts = _amounts(totals, invoiced as bool);
    if (totals['method'] != draft.sale.paymentMethod.wireValue ||
        !amounts.sameAs(refund.sums)) {
      throw const CorrectionProtocolException();
    }
    return SaleReturnReceipt._(
      returnId: draft.idempotencyKey,
      saleId: draft.saleId,
      branchId: draft.branchId,
      reason: draft.reason,
      lines: refund.lines,
      refundMethod: draft.sale.paymentMethod,
      baseCentavos: amounts.base,
      additionalIvaCentavos: amounts.additionalIva,
      totalCentavos: amounts.total,
      invoiced: invoiced,
      replayed: replayed,
    );
  }

  final String returnId;
  @override
  final String saleId;
  @override
  final String branchId;
  final CorrectionReason reason;
  final List<CorrectionRefundLine> lines;

  /// Always the original sale's payment method (decision 6).
  final SalePaymentMethod refundMethod;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;

  /// The sale was invoiced: the administrator handles the credit note.
  final bool invoiced;
  @override
  final bool replayed;

  @override
  String get correctionId => returnId;
}

/// Parsed `previewSaleReturn` result: what [SaleReturnReceipt] would hold if
/// the previewed return were submitted right now. Read-only; nothing was
/// written, so a malformed preview is a protocol error, never uncertain.
class SaleReturnPreview {
  const SaleReturnPreview._({
    required this.request,
    required this.lines,
    required this.refundMethod,
    required this.baseCentavos,
    required this.additionalIvaCentavos,
    required this.totalCentavos,
    required this.invoiced,
  });

  /// Requires exactly `{saleId, lines, refund, invoiced}` for the requested
  /// sale, with the same per-line binding, sums and refund method checks as
  /// [SaleReturnReceipt.fromCallable].
  factory SaleReturnPreview.fromCallable(
    Object? value, {
    required SaleReturnPreviewRequest request,
  }) {
    final Map<Object?, Object?> preview = correctionExact(value, _previewKeys);
    final Object? invoiced = preview['invoiced'];
    if (preview['saleId'] != request.saleId ||
        invoiced is! bool ||
        invoiced != request.sale.invoiced) {
      throw const CorrectionProtocolException();
    }
    final _Refund refund = _refund(
      preview['lines'],
      request.lines,
      request.sale,
      invoiced,
    );
    final Map<Object?, Object?> totals = correctionExact(
      preview['refund'],
      _refundKeys,
    );
    final _Amounts amounts = _amounts(totals, invoiced);
    if (totals['method'] != request.sale.paymentMethod.wireValue ||
        !amounts.sameAs(refund.sums)) {
      throw const CorrectionProtocolException();
    }
    return SaleReturnPreview._(
      request: request,
      lines: refund.lines,
      refundMethod: request.sale.paymentMethod,
      baseCentavos: amounts.base,
      additionalIvaCentavos: amounts.additionalIva,
      totalCentavos: amounts.total,
      invoiced: invoiced,
    );
  }

  /// The exact request this preview answers.
  final SaleReturnPreviewRequest request;
  final List<CorrectionRefundLine> lines;

  /// Always the original sale's payment method (decision 6).
  final SalePaymentMethod refundMethod;
  final int baseCentavos;
  final int additionalIvaCentavos;
  final int totalCentavos;
  final bool invoiced;
}

/// One replaced line: same product, no charge.
class CorrectionReplacementLine {
  const CorrectionReplacementLine._({
    required this.lineIndex,
    required this.productId,
    required this.quantityDecimal,
    required this.quantityScaled,
  });
  final int lineIndex;
  final String productId;
  final String quantityDecimal;
  final int quantityScaled;
}

/// Parsed v1 `submitSaleReplacement` result, bound to its draft.
class SaleReplacementReceipt extends SaleCorrectionReceipt {
  const SaleReplacementReceipt._({
    required this.replacementId,
    required this.saleId,
    required this.branchId,
    required this.lines,
    required this.replayed,
  });

  /// Requires exactly `{receipt, replayed}` with a v1 receipt for the draft
  /// key, sale and branch, reason `factory-defect`, `chargeCentavos: 0`, and
  /// lines matching the draft lines in order.
  factory SaleReplacementReceipt.fromCallable(
    Object? value, {
    required SaleReplacementDraft draft,
  }) {
    final (Map<Object?, Object?> receipt, bool replayed) = _response(
      value,
      _replacementKeys,
    );
    final Object? rawLines = receipt['lines'];
    if (receipt['version'] != 1 ||
        receipt['replacementId'] != draft.idempotencyKey ||
        receipt['saleId'] != draft.saleId ||
        receipt['branchId'] != draft.branchId ||
        receipt['reason'] != CorrectionReason.factoryDefect.wireValue ||
        receipt['chargeCentavos'] != 0 ||
        rawLines is! List ||
        rawLines.length != draft.lines.length) {
      throw const CorrectionProtocolException();
    }
    final List<CorrectionReplacementLine> lines = <CorrectionReplacementLine>[];
    for (int index = 0; index < rawLines.length; index++) {
      final CorrectionLine requested = draft.lines[index];
      final Map<Object?, Object?> line = correctionExact(
        rawLines[index],
        _replacementLineKeys,
      );
      final String quantity = _sameQuantity(line['quantity'], requested);
      if (line['lineIndex'] != requested.lineIndex ||
          line['productId'] != requested.productId) {
        throw const CorrectionProtocolException();
      }
      lines.add(
        CorrectionReplacementLine._(
          lineIndex: requested.lineIndex,
          productId: requested.productId,
          quantityDecimal: quantity,
          quantityScaled: requested.quantityScaled,
        ),
      );
    }
    return SaleReplacementReceipt._(
      replacementId: draft.idempotencyKey,
      saleId: draft.saleId,
      branchId: draft.branchId,
      lines: List<CorrectionReplacementLine>.unmodifiable(lines),
      replayed: replayed,
    );
  }

  final String replacementId;
  @override
  final String saleId;
  @override
  final String branchId;
  final List<CorrectionReplacementLine> lines;
  @override
  final bool replayed;

  @override
  String get correctionId => replacementId;

  /// Replacements are always free and always `factory-defect`.
  int get chargeCentavos => 0;
  CorrectionReason get reason => CorrectionReason.factoryDefect;
}

/// Server settlement of an exchange: exactly one side is positive, or both
/// are zero.
class SaleExchangeSettlement {
  const SaleExchangeSettlement._({
    required this.returnedCentavos,
    required this.newItemCentavos,
    required this.customerPaysCentavos,
    required this.refundCentavos,
    required this.refundMethod,
    required this.differencePayment,
  });
  final int returnedCentavos;
  final int newItemCentavos;
  final int customerPaysCentavos;
  final int refundCentavos;
  final SalePaymentMethod refundMethod;

  /// The exact payment taken for [customerPaysCentavos]; null when nothing
  /// was owed.
  final SaleExchangePayment? differencePayment;
}

/// Parsed v1 `submitSaleExchange` result, bound to its draft.
class SaleExchangeReceipt extends SaleCorrectionReceipt {
  const SaleExchangeReceipt._({
    required this.exchangeId,
    required this.saleId,
    required this.branchId,
    required this.reason,
    required this.returnedLines,
    required this.returnedBaseCentavos,
    required this.returnedAdditionalIvaCentavos,
    required this.returnedTotalCentavos,
    required this.newItems,
    required this.settlement,
    required this.invoiced,
    required this.replayed,
  });

  /// Requires exactly `{receipt, replayed}` with a v1 receipt for the draft
  /// key, sale, branch and reason; returned lines matching the draft return
  /// lines; new items whose product IDs and calculation match the draft cart
  /// (strictly, via [SaleCalculation.fromCallable]); and a settlement derived
  /// from both totals, refunded through the sale's method, whose difference
  /// payment is exactly the draft's and equals what the customer owes.
  factory SaleExchangeReceipt.fromCallable(
    Object? value, {
    required SaleExchangeDraft draft,
  }) {
    final (Map<Object?, Object?> receipt, bool replayed) = _response(
      value,
      _exchangeKeys,
    );
    final Object? invoiced = receipt['invoiced'];
    if (receipt['version'] != 1 ||
        receipt['exchangeId'] != draft.idempotencyKey ||
        receipt['saleId'] != draft.saleId ||
        receipt['branchId'] != draft.branchId ||
        receipt['reason'] != draft.reason.wireValue ||
        invoiced != draft.sale.invoiced) {
      throw const CorrectionProtocolException();
    }
    final Map<Object?, Object?> returned = correctionExact(
      receipt['returned'],
      _returnedKeys,
    );
    final _Refund refund = _refund(
      returned['lines'],
      draft.returnLines,
      draft.sale,
      invoiced! as bool,
    );
    final _Amounts returnedAmounts = _amounts(returned, invoiced as bool);
    if (!returnedAmounts.sameAs(refund.sums)) {
      throw const CorrectionProtocolException();
    }
    final SaleCalculation calculation = _newItems(
      receipt['newItems'],
      draft.newItems,
    );
    final SaleExchangeSettlement settlement = _settlement(
      receipt['settlement'],
      draft,
      returnedAmounts.total,
      calculation.totalCentavos,
    );
    return SaleExchangeReceipt._(
      exchangeId: draft.idempotencyKey,
      saleId: draft.saleId,
      branchId: draft.branchId,
      reason: draft.reason,
      returnedLines: refund.lines,
      returnedBaseCentavos: returnedAmounts.base,
      returnedAdditionalIvaCentavos: returnedAmounts.additionalIva,
      returnedTotalCentavos: returnedAmounts.total,
      newItems: calculation,
      settlement: settlement,
      invoiced: invoiced,
      replayed: replayed,
    );
  }

  final String exchangeId;
  @override
  final String saleId;
  @override
  final String branchId;
  final CorrectionReason reason;
  final List<CorrectionRefundLine> returnedLines;
  final int returnedBaseCentavos;
  final int returnedAdditionalIvaCentavos;
  final int returnedTotalCentavos;

  /// New items priced at current prices with the original invoice intent.
  final SaleCalculation newItems;
  final SaleExchangeSettlement settlement;
  final bool invoiced;
  @override
  final bool replayed;

  @override
  String get correctionId => exchangeId;
}

/// Parsed `previewSaleExchange` result: what [SaleExchangeReceipt] would hold
/// if the previewed exchange were submitted right now, plus per new line
/// whether the branch stock covers it. Read-only; nothing was written, so a
/// malformed preview is a protocol error, never uncertain.
///
/// [customerPaysCentavos] is the only amount a submit may send as its
/// difference payment; the seller never types it.
class SaleExchangePreview {
  const SaleExchangePreview._({
    required this.request,
    required this.returnedLines,
    required this.returnedBaseCentavos,
    required this.returnedAdditionalIvaCentavos,
    required this.returnedTotalCentavos,
    required this.newItems,
    required this.customerPaysCentavos,
    required this.refundCentavos,
    required this.refundMethod,
    required this.unavailableProductIds,
    required this.invoiced,
  });

  /// Requires exactly `{saleId, returned, newItems, settlement, newLines,
  /// invoiced}` for the requested sale: returned lines bound to the request
  /// like [SaleReturnPreview]; new-item product IDs and calculation bound to
  /// the request cart (strictly, via [SaleCalculation.fromCallable]); exactly
  /// the five settlement amounts re-derived from both totals, refunded
  /// through the sale's method; and one `{productId, available}` per new
  /// line, in cart order.
  factory SaleExchangePreview.fromCallable(
    Object? value, {
    required SaleExchangePreviewRequest request,
  }) {
    final Map<Object?, Object?> preview = correctionExact(
      value,
      _exchangePreviewKeys,
    );
    final Object? invoiced = preview['invoiced'];
    if (preview['saleId'] != request.saleId ||
        invoiced is! bool ||
        invoiced != request.sale.invoiced) {
      throw const CorrectionProtocolException();
    }
    final Map<Object?, Object?> returned = correctionExact(
      preview['returned'],
      _returnedKeys,
    );
    final _Refund refund = _refund(
      returned['lines'],
      request.returnLines,
      request.sale,
      invoiced,
    );
    final _Amounts returnedAmounts = _amounts(returned, invoiced);
    if (!returnedAmounts.sameAs(refund.sums)) {
      throw const CorrectionProtocolException();
    }
    final SaleCalculation calculation = _newItems(
      preview['newItems'],
      request.newItems,
    );
    final (pays: int pays, refund: int refundCentavos) = _settledAmounts(
      correctionExact(preview['settlement'], _previewSettlementKeys),
      request.sale,
      returnedAmounts.total,
      calculation.totalCentavos,
    );
    final Object? newLines = preview['newLines'];
    if (newLines is! List || newLines.length != request.newItems.lineCount) {
      throw const CorrectionProtocolException();
    }
    final Set<String> unavailable = <String>{};
    for (int index = 0; index < newLines.length; index++) {
      final Map<Object?, Object?> line = correctionExact(
        newLines[index],
        _previewNewLineKeys,
      );
      final String productId = request.newItems.lines[index].productId;
      final Object? available = line['available'];
      if (line['productId'] != productId || available is! bool) {
        throw const CorrectionProtocolException();
      }
      if (!available) unavailable.add(productId);
    }
    return SaleExchangePreview._(
      request: request,
      returnedLines: refund.lines,
      returnedBaseCentavos: returnedAmounts.base,
      returnedAdditionalIvaCentavos: returnedAmounts.additionalIva,
      returnedTotalCentavos: returnedAmounts.total,
      newItems: calculation,
      customerPaysCentavos: pays,
      refundCentavos: refundCentavos,
      refundMethod: request.sale.paymentMethod,
      unavailableProductIds: Set<String>.unmodifiable(unavailable),
      invoiced: invoiced,
    );
  }

  /// The exact request this preview answers.
  final SaleExchangePreviewRequest request;
  final List<CorrectionRefundLine> returnedLines;
  final int returnedBaseCentavos;
  final int returnedAdditionalIvaCentavos;
  final int returnedTotalCentavos;

  /// New items at current prices with the original invoice intent.
  final SaleCalculation newItems;
  final int customerPaysCentavos;
  final int refundCentavos;

  /// Always the original sale's payment method (decision 7).
  final SalePaymentMethod refundMethod;

  /// New products the branch stock cannot cover; a submit would refuse them.
  final Set<String> unavailableProductIds;
  final bool invoiced;

  bool get allAvailable => unavailableProductIds.isEmpty;
}

(Map<Object?, Object?>, bool) _response(Object? value, Set<String> keys) {
  final Map<Object?, Object?> response = correctionExact(value, _responseKeys);
  final Object? replayed = response['replayed'];
  if (replayed is! bool) throw const CorrectionProtocolException();
  return (correctionExact(response['receipt'], keys), replayed);
}

class _Amounts {
  const _Amounts(this.base, this.additionalIva, this.total);
  final int base;
  final int additionalIva;
  final int total;

  bool sameAs(_Amounts other) =>
      base == other.base &&
      additionalIva == other.additionalIva &&
      total == other.total;
}

/// Safe centavos with `total = base + additional IVA`, and no additional IVA
/// on an uninvoiced sale.
_Amounts _amounts(Map<Object?, Object?> value, bool invoiced) {
  final int base = correctionCentavos(value['baseCentavos']);
  final int additional = correctionCentavos(value['additionalIvaCentavos']);
  final int total = correctionCentavos(value['totalCentavos']);
  if (base + additional != total || (!invoiced && additional != 0)) {
    throw const CorrectionProtocolException();
  }
  return _Amounts(base, additional, total);
}

class _Refund {
  const _Refund(this.lines, this.sums);
  final List<CorrectionRefundLine> lines;
  final _Amounts sums;
}

_Refund _refund(
  Object? value,
  List<CorrectionLine> requested,
  CorrectableSale sale,
  bool invoiced,
) {
  if (value is! List || value.length != requested.length) {
    throw const CorrectionProtocolException();
  }
  final List<CorrectionRefundLine> lines = <CorrectionRefundLine>[];
  int base = 0;
  int additional = 0;
  int total = 0;
  for (int index = 0; index < value.length; index++) {
    final CorrectionLine draft = requested[index];
    final CorrectableSaleLine sold = sale.lines[draft.lineIndex];
    final Map<Object?, Object?> line = correctionExact(
      value[index],
      _refundLineKeys,
    );
    final String quantity = _sameQuantity(line['quantity'], draft);
    final _Amounts amounts = _amounts(line, invoiced);
    if (line['lineIndex'] != draft.lineIndex ||
        line['productId'] != draft.productId ||
        line['condition'] != draft.condition?.wireValue ||
        amounts.base > sold.baseCentavos ||
        amounts.additionalIva > sold.additionalIvaCentavos) {
      throw const CorrectionProtocolException();
    }
    base += amounts.base;
    additional += amounts.additionalIva;
    total += amounts.total;
    if (total > maxSafeSaleInteger) throw const CorrectionProtocolException();
    lines.add(
      CorrectionRefundLine._(
        lineIndex: draft.lineIndex,
        productId: draft.productId,
        quantityDecimal: quantity,
        quantityScaled: draft.quantityScaled,
        condition: draft.condition!,
        baseCentavos: amounts.base,
        additionalIvaCentavos: amounts.additionalIva,
        totalCentavos: amounts.total,
      ),
    );
  }
  return _Refund(
    List<CorrectionRefundLine>.unmodifiable(lines),
    _Amounts(base, additional, total),
  );
}

/// The server echoes the quantity formatted at the line precision; it must
/// be exactly the draft quantity, compared by scaled value.
String _sameQuantity(Object? value, CorrectionLine draft) {
  if (value is! String ||
      value != formatScaledQuantity(draft.quantityScaled, draft.quantitySpec)) {
    throw const CorrectionProtocolException();
  }
  return value;
}

/// The new items' product IDs, in cart order, and their strict calculation
/// against [cart].
SaleCalculation _newItems(Object? value, SaleCart cart) {
  final Map<Object?, Object?> newItems = correctionExact(value, _newItemsKeys);
  final Object? productIds = newItems['productIds'];
  if (productIds is! List || productIds.length != cart.lineCount) {
    throw const CorrectionProtocolException();
  }
  for (int index = 0; index < productIds.length; index++) {
    if (productIds[index] != cart.lines[index].productId) {
      throw const CorrectionProtocolException();
    }
  }
  try {
    return SaleCalculation.fromCallable(newItems['calculation'], cart: cart);
  } on SaleProtocolException {
    throw const CorrectionProtocolException();
  }
}

/// The settlement amounts, re-derived from both totals: exactly one side is
/// positive, or both are zero, and a refund always uses the sale's method.
({int pays, int refund}) _settledAmounts(
  Map<Object?, Object?> settlement,
  CorrectableSale sale,
  int returnedCentavos,
  int newItemCentavos,
) {
  final int difference = newItemCentavos - returnedCentavos;
  final int pays = difference > 0 ? difference : 0;
  final int refund = difference < 0 ? -difference : 0;
  if (settlement['returnedCentavos'] != returnedCentavos ||
      settlement['newItemCentavos'] != newItemCentavos ||
      settlement['customerPaysCentavos'] != pays ||
      settlement['refundCentavos'] != refund ||
      settlement['refundMethod'] != sale.paymentMethod.wireValue) {
    throw const CorrectionProtocolException();
  }
  return (pays: pays, refund: refund);
}

SaleExchangeSettlement _settlement(
  Object? value,
  SaleExchangeDraft draft,
  int returnedCentavos,
  int newItemCentavos,
) {
  final Map<Object?, Object?> settlement = correctionExact(
    value,
    _settlementKeys,
  );
  final (:int pays, :int refund) = _settledAmounts(
    settlement,
    draft.sale,
    returnedCentavos,
    newItemCentavos,
  );
  final Object? rawPayment = settlement['differencePayment'];
  final SaleExchangePayment? expected = draft.differencePayment;
  if (pays == 0) {
    if (rawPayment != null || expected != null) {
      throw const CorrectionProtocolException();
    }
  } else {
    final Map<Object?, Object?> payment = correctionExact(
      rawPayment,
      _paymentKeys,
    );
    if (expected == null ||
        payment['method'] != expected.method.wireValue ||
        payment['amountCentavos'] != expected.amountCentavos ||
        expected.amountCentavos != pays) {
      throw const CorrectionProtocolException();
    }
  }
  return SaleExchangeSettlement._(
    returnedCentavos: returnedCentavos,
    newItemCentavos: newItemCentavos,
    customerPaysCentavos: pays,
    refundCentavos: refund,
    refundMethod: draft.sale.paymentMethod,
    differencePayment: pays == 0 ? null : expected,
  );
}
