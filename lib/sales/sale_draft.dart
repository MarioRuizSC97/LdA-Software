import '../catalog/stock_intake.dart' show createStockIntakeUuidV4;
import 'sale_cart.dart';
import 'sale_quote.dart';

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _branchCodePattern = RegExp(r'^[A-Z]{2,4}$');
final RegExp _nonAlphanumeric = RegExp(r'[^a-zA-Z0-9]');

const Set<String> _responseKeys = <String>{'receipt', 'replayed', 'createdAt'};

/// Largest epoch millisecond a [DateTime] can represent.
const int _maxDateTimeMillis = 8640000000000000;
const Set<String> _receiptKeys = <String>{
  'version',
  'saleId',
  'branchId',
  'branchCode',
  'folio',
  'productIds',
  'calculation',
  'payment',
};
const Set<String> _paymentKeys = <String>{'method', 'amountCentavos'};

/// Sale idempotency keys are lowercase UUID v4, generated once per draft with
/// the same secure generator stock intake uses.
String createSaleIdempotencyKey() => createStockIntakeUuidV4();

/// Mirrors the server `saleFolio`: `<CODE>-<XXXX>-<XXXX>` from the first eight
/// alphanumeric characters of the sale key, uppercased.
String saleFolio(String branchCode, String saleId) {
  final String head = saleId.replaceAll(_nonAlphanumeric, '');
  if (!_branchCodePattern.hasMatch(branchCode) || head.length < 8) {
    throw const SaleValidationException('Folio inputs are invalid.');
  }
  final String upper = head.substring(0, 8).toUpperCase();
  return '$branchCode-${upper.substring(0, 4)}-${upper.substring(4)}';
}

/// Immutable `submitSale` request frozen at confirmation.
///
/// The key is generated exactly once, when the draft is created; retrying an
/// uncertain submission must reuse this same draft (see [SaleDraftStore]), so
/// the server can replay instead of selling twice. The amount is always the
/// quoted authoritative total and is never typed by hand.
class SaleDraft {
  SaleDraft._({
    required this.idempotencyKey,
    required this.branchId,
    required this.cart,
    required this.paymentMethod,
    required this.amountCentavos,
  });

  factory SaleDraft.fromQuote({
    required SaleQuote quote,
    required String branchId,
    required SalePaymentMethod paymentMethod,
    String Function() createKey = createSaleIdempotencyKey,
  }) {
    if (!quote.allAvailable) {
      throw const SaleValidationException(
        'Every cart line must be available before confirming.',
      );
    }
    if (!isValidSaleId(branchId)) {
      throw const SaleValidationException('Branch ID is invalid.');
    }
    final String key = createKey();
    if (!_uuidV4Pattern.hasMatch(key)) {
      throw const SaleValidationException(
        'Sale key must be a lowercase UUID v4.',
      );
    }
    quote.cart.toQuoteRequest();
    return SaleDraft._(
      idempotencyKey: key,
      branchId: branchId,
      cart: quote.cart,
      paymentMethod: paymentMethod,
      amountCentavos: quote.totalCentavos,
    );
  }

  final String idempotencyKey;

  /// The seller's branch. It is not sent: the server takes it from claims.
  final String branchId;
  final SaleCart cart;
  final SalePaymentMethod paymentMethod;
  final int amountCentavos;

  /// Exact `submitSale` request:
  /// `{idempotencyKey, invoiceRequested, lines, payment}`.
  Map<String, Object?> toRequest() => <String, Object?>{
    'idempotencyKey': idempotencyKey,
    ...cart.toQuoteRequest(),
    'payment': <String, Object?>{
      'method': paymentMethod.wireValue,
      'amountCentavos': amountCentavos,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is SaleDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.branchId == branchId &&
      other.cart == cart &&
      other.paymentMethod == paymentMethod &&
      other.amountCentavos == amountCentavos;

  @override
  int get hashCode => Object.hash(
    idempotencyKey,
    branchId,
    cart,
    paymentMethod,
    amountCentavos,
  );
}

/// Parsed v2 `submitSale` result, bound to the draft that produced it.
///
/// [createdAt] is the authoritative server sale time (UTC). For a replay it
/// is the original sale time, never the time of the retry.
class SaleReceipt {
  const SaleReceipt._({
    required this.saleId,
    required this.branchId,
    required this.branchCode,
    required this.folio,
    required this.invoiceRequested,
    required this.calculation,
    required this.paymentMethod,
    required this.amountCentavos,
    required this.replayed,
    required this.createdAt,
  });

  /// Requires exactly `{receipt, replayed, createdAt}`, where `createdAt` is
  /// a non-negative integer of epoch milliseconds within the [DateTime]
  /// range, and a v2 receipt whose sale ID is
  /// the draft key, whose branch is the draft branch, whose folio is derived
  /// from its branch code and key, whose products and calculation match the
  /// draft cart, and whose payment is the draft method and amount, equal to
  /// the calculation total. Legacy v1 receipts cannot answer a new UUID key
  /// and are rejected.
  factory SaleReceipt.fromCallable(Object? value, {required SaleDraft draft}) {
    final Map<Object?, Object?> response = _exact(value, _responseKeys);
    final Object? replayed = response['replayed'];
    final Object? createdAt = response['createdAt'];
    if (createdAt is! int || createdAt < 0 || createdAt > _maxDateTimeMillis) {
      throw const SaleProtocolException();
    }
    final Map<Object?, Object?> receipt = _exact(
      response['receipt'],
      _receiptKeys,
    );
    final Object? branchCode = receipt['branchCode'];
    final Object? folio = receipt['folio'];
    if (replayed is! bool ||
        receipt['version'] != 2 ||
        receipt['saleId'] != draft.idempotencyKey ||
        receipt['branchId'] != draft.branchId ||
        branchCode is! String ||
        !_branchCodePattern.hasMatch(branchCode) ||
        folio is! String ||
        folio != saleFolio(branchCode, draft.idempotencyKey) ||
        !_sameProductIds(receipt['productIds'], draft.cart)) {
      throw const SaleProtocolException();
    }
    final SaleCalculation calculation = SaleCalculation.fromCallable(
      receipt['calculation'],
      cart: draft.cart,
    );
    final Map<Object?, Object?> payment = _exact(
      receipt['payment'],
      _paymentKeys,
    );
    if (payment['method'] != draft.paymentMethod.wireValue ||
        payment['amountCentavos'] != calculation.totalCentavos ||
        calculation.totalCentavos != draft.amountCentavos) {
      throw const SaleProtocolException();
    }
    return SaleReceipt._(
      saleId: draft.idempotencyKey,
      branchId: draft.branchId,
      branchCode: branchCode,
      folio: folio,
      invoiceRequested: draft.cart.invoiceRequested,
      calculation: calculation,
      paymentMethod: draft.paymentMethod,
      amountCentavos: calculation.totalCentavos,
      replayed: replayed,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
    );
  }

  final String saleId;
  final String branchId;
  final String branchCode;
  final String folio;
  final bool invoiceRequested;
  final SaleCalculation calculation;
  final SalePaymentMethod paymentMethod;
  final int amountCentavos;
  final bool replayed;

  /// Server sale time in UTC; convert with `toLocal()` for display.
  final DateTime createdAt;

  List<SalePricedLine> get lines => calculation.lines;
  int get baseCentavos => calculation.baseCentavos;
  int get additionalIvaCentavos => calculation.additionalIvaCentavos;
  int get totalCentavos => calculation.totalCentavos;
}

Map<Object?, Object?> _exact(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const SaleProtocolException();
  }
  return value;
}

bool _sameProductIds(Object? value, SaleCart cart) {
  if (value is! List || value.length != cart.lineCount) return false;
  for (int index = 0; index < value.length; index++) {
    if (value[index] != cart.lines[index].productId) return false;
  }
  return true;
}

/// A different sale is blocked until the stored one is resolved or, once
/// committed, its receipt is acknowledged.
class SaleUnresolvedException implements Exception {
  const SaleUnresolvedException();
}

class SaleAttempt {
  const SaleAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });
  final String ownerUserId;
  final SaleDraft draft;
  final int revision;
}

class _StoredSaleDraft {
  _StoredSaleDraft(this.draft, this.revision);
  final SaleDraft draft;
  final int revision;

  /// The committed sale's receipt, kept until the seller acknowledges it.
  SaleReceipt? completed;
}

/// Volatile, live-shell-only retry storage: at most one stored sale per
/// exact seller and branch, held in nested exact maps (never a concatenated
/// key). A draft is frozen at `begin`; an uncertain submission retries the
/// same draft (same key, same payload) until it resolves, and only the current
/// attempt's revision may resolve or complete it. A committed sale keeps its
/// receipt until [acknowledge], so a receipt that lands after the cart is
/// gone is still shown, and no other sale can begin unaware of it.
class SaleDraftStore {
  final Map<String, Map<String, _StoredSaleDraft>> _drafts =
      <String, Map<String, _StoredSaleDraft>>{};

  // Store-wide and never reset, so an attempt from before a resolution can
  // never match an equal draft begun again afterwards.
  int _lastRevision = 0;

  /// The stored draft still awaiting an outcome; null once completed.
  SaleDraft? unresolvedFor(String ownerUserId, String branchId) {
    final _StoredSaleDraft? stored = _drafts[ownerUserId]?[branchId];
    return stored == null || stored.completed != null ? null : stored.draft;
  }

  /// The committed sale's receipt awaiting acknowledgement, if any.
  SaleReceipt? completedFor(String ownerUserId, String branchId) =>
      _drafts[ownerUserId]?[branchId]?.completed;

  /// Begins an attempt. An equal draft, even an already completed one, may
  /// be sent again (the server replays it); any other draft is refused
  /// while one is stored.
  SaleAttempt begin({required String ownerUserId, required SaleDraft draft}) {
    if (ownerUserId.isEmpty) throw const SaleSessionException();
    final Map<String, _StoredSaleDraft> branchDrafts = _drafts.putIfAbsent(
      ownerUserId,
      () => <String, _StoredSaleDraft>{},
    );
    final _StoredSaleDraft? current = branchDrafts[draft.branchId];
    if (current != null && current.draft != draft) {
      throw const SaleUnresolvedException();
    }
    final int revision = ++_lastRevision;
    branchDrafts[draft.branchId] = _StoredSaleDraft(draft, revision);
    return SaleAttempt._(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(SaleAttempt attempt) {
    final _StoredSaleDraft? current =
        _drafts[attempt.ownerUserId]?[attempt.draft.branchId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  /// Drops the current attempt's draft: a deterministic rejection committed
  /// nothing.
  bool resolve(SaleAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    _remove(attempt.ownerUserId, attempt.draft.branchId);
    return true;
  }

  /// Records the current attempt's committed [receipt] and keeps the entry
  /// until [acknowledge]. The receipt must answer the attempt's own draft,
  /// or this throws [ArgumentError].
  bool complete(SaleAttempt attempt, SaleReceipt receipt) {
    final SaleDraft draft = attempt.draft;
    if (receipt.saleId != draft.idempotencyKey ||
        receipt.branchId != draft.branchId ||
        receipt.paymentMethod != draft.paymentMethod ||
        receipt.amountCentavos != draft.amountCentavos) {
      throw ArgumentError.value(receipt, 'receipt', 'is not the draft sale');
    }
    if (!isCurrent(attempt)) return false;
    _drafts[attempt.ownerUserId]![draft.branchId]!.completed = receipt;
    return true;
  }

  /// Drops the completed entry whose receipt is exactly [receipt]; anything
  /// else (an unresolved draft, another receipt) is kept.
  bool acknowledge(String ownerUserId, String branchId, SaleReceipt receipt) {
    final _StoredSaleDraft? stored = _drafts[ownerUserId]?[branchId];
    if (stored == null || !identical(stored.completed, receipt)) return false;
    _remove(ownerUserId, branchId);
    return true;
  }

  void _remove(String ownerUserId, String branchId) {
    final Map<String, _StoredSaleDraft> branchDrafts = _drafts[ownerUserId]!;
    branchDrafts.remove(branchId);
    if (branchDrafts.isEmpty) _drafts.remove(ownerUserId);
  }
}
