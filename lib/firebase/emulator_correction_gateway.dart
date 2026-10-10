import 'dart:developer' as developer;

import '../auth/emulator_session.dart';
import '../corrections/correction_draft.dart';
import '../corrections/correction_receipt.dart';
import '../corrections/correction_sale.dart';
import '../sales/sale_cart.dart';
import 'emulator_sale_gateway.dart';

typedef CorrectionGatewayLoader = Future<EmulatorCorrectionGateway> Function(
  EmulatorSession session,
);

/// Deterministic server refusals, identical to the sale gateway. `internal`
/// is excluded: the server masks any unexpected failure (including a
/// transaction failure) as `internal`, so its effect is unknown.
const Set<String> _rejectedCodes = <String>{
  'invalid-argument',
  'not-found',
  'failed-precondition',
  'out-of-range',
  'permission-denied',
  'unauthenticated',
  'already-exists',
};

/// Server `details.reason` for a folio that matches more than one sale.
const String correctionFolioAmbiguousReason = 'folio-ambiguous';

/// Server `details.reason` for a sale outside the correction window. The
/// server owns the window rule.
const String correctionWindowClosedReason = 'correction-window-closed';

/// Server `details.reason` for a line that would exceed its remaining
/// returnable quantity, in returns, replacements, exchanges and previews.
const String correctionOverReturnReason = 'over-return';

/// Correction meanings of a deterministic refusal. Each one is identified by
/// its code and structured server reason only, never by the English message.
extension CorrectionRejection on SaleRejectedException {
  /// The folio matches several sales.
  bool get isFolioAmbiguous =>
      code == 'failed-precondition' && reason == correctionFolioAmbiguousReason;

  /// A line would exceed its remaining returnable quantity.
  bool get isOverReturn =>
      code == 'out-of-range' && reason == correctionOverReturnReason;

  /// The sale's correction window has closed.
  bool get isOutsideCorrectionWindow =>
      code == 'failed-precondition' && reason == correctionWindowClosedReason;

  /// The branch's sellable stock cannot cover a replacement or a new exchange
  /// item. The server uses the same reason as for a sale.
  bool get isOutOfStock =>
      code == 'failed-precondition' && reason == saleInsufficientStockReason;
}

/// An uncertain submission whose response arrived but could not be parsed.
/// Keeps the original parse failure for diagnosis; callers still treat it as
/// any [SaleUncertainException] and retry the same draft.
class CorrectionUncertainException extends SaleUncertainException {
  const CorrectionUncertainException(this.cause, this.stackTrace);
  final Object cause;
  final StackTrace stackTrace;
}

/// Seller-only adapter for the sale-correction callables: five operations
/// plus the read-only return and exchange previews.
///
/// Mirrors [EmulatorSaleGateway] and shares its callable, session and outcome
/// types: the exact assigned seller is re-checked before and after each call;
/// a newer call of the same operation makes older ones stale (each operation
/// counts separately); whitelisted codes become [SaleRejectedException] with
/// the server message and `details.reason`; anything else is
/// [SaleUncertainException]. A malformed lookup or list response is a
/// [CorrectionProtocolException] (reads have no effect to be uncertain
/// about), and so is a malformed preview, while a malformed submission
/// response is uncertain, because the correction may have committed and must
/// be retried with the same draft.
class EmulatorCorrectionGateway {
  EmulatorCorrectionGateway({
    required this.expectedSession,
    required this.sessionChecker,
    required this.findInvoke,
    required this.listInvoke,
    required this.returnInvoke,
    required this.replacementInvoke,
    required this.exchangeInvoke,
    required this.previewReturnInvoke,
    required this.previewExchangeInvoke,
  });

  final EmulatorSession expectedSession;
  final SaleSessionChecker sessionChecker;
  final SaleCallable findInvoke;
  final SaleCallable listInvoke;
  final SaleCallable returnInvoke;
  final SaleCallable replacementInvoke;
  final SaleCallable exchangeInvoke;
  final SaleCallable previewReturnInvoke;
  final SaleCallable previewExchangeInvoke;
  int _findGeneration = 0;
  int _previewReturnGeneration = 0;
  int _previewExchangeGeneration = 0;
  int _listGeneration = 0;
  int _returnGeneration = 0;
  int _replacementGeneration = 0;
  int _exchangeGeneration = 0;

  Future<CorrectableSale> find(SaleLookupQuery query) async {
    final Map<String, Object?> request = query.toRequest();
    final int generation = ++_findGeneration;
    final Object? response = await _staleAware(
      _call(findInvoke, request),
      () => generation != _findGeneration,
    );
    return CorrectableSale.fromLookup(response, query: query);
  }

  Future<RecentCorrectableSales> listRecent([RecentSalesQuery? query]) async {
    final RecentSalesQuery effective = query ?? RecentSalesQuery();
    final Map<String, Object?> request = effective.toRequest();
    final int generation = ++_listGeneration;
    final Object? response = await _staleAware(
      _call(listInvoke, request),
      () => generation != _listGeneration,
    );
    return RecentCorrectableSales.fromCallable(response, query: effective);
  }

  /// Read-only refund preview; a newer preview makes older ones stale.
  Future<SaleReturnPreview> previewReturn(
    SaleReturnPreviewRequest request,
  ) async {
    final Map<String, Object?> wire = request.toRequest();
    final int generation = ++_previewReturnGeneration;
    final Object? response = await _staleAware(
      _call(previewReturnInvoke, wire),
      () => generation != _previewReturnGeneration,
    );
    return _protocolIfMalformed(
      () => SaleReturnPreview.fromCallable(response, request: request),
    );
  }

  /// Read-only exchange settlement preview, bound to [request]; a newer
  /// exchange preview makes older ones stale.
  Future<SaleExchangePreview> previewExchange(
    SaleExchangePreviewRequest request,
  ) async {
    final Map<String, Object?> wire = request.toRequest();
    final int generation = ++_previewExchangeGeneration;
    final Object? response = await _staleAware(
      _call(previewExchangeInvoke, wire),
      () => generation != _previewExchangeGeneration,
    );
    return _protocolIfMalformed(
      () => SaleExchangePreview.fromCallable(response, request: request),
    );
  }

  /// A preview wrote nothing, so any failure to parse it (a protocol, cast
  /// or range error alike) is a protocol error, logged with its cause.
  T _protocolIfMalformed<T>(T Function() parse) {
    try {
      return parse();
    } on CorrectionProtocolException {
      rethrow;
    } catch (error, stackTrace) {
      _logParseFailure('preview', error, stackTrace);
      throw const CorrectionProtocolException();
    }
  }

  Future<SaleReturnReceipt> submitReturn(SaleReturnDraft draft) async {
    final Object? response = await _submit(
      draft,
      returnInvoke,
      () => ++_returnGeneration,
      () => _returnGeneration,
    );
    return _uncertainIfMalformed(
      () => SaleReturnReceipt.fromCallable(response, draft: draft),
    );
  }

  Future<SaleReplacementReceipt> submitReplacement(
    SaleReplacementDraft draft,
  ) async {
    final Object? response = await _submit(
      draft,
      replacementInvoke,
      () => ++_replacementGeneration,
      () => _replacementGeneration,
    );
    return _uncertainIfMalformed(
      () => SaleReplacementReceipt.fromCallable(response, draft: draft),
    );
  }

  Future<SaleExchangeReceipt> submitExchange(SaleExchangeDraft draft) async {
    final Object? response = await _submit(
      draft,
      exchangeInvoke,
      () => ++_exchangeGeneration,
      () => _exchangeGeneration,
    );
    return _uncertainIfMalformed(
      () => SaleExchangeReceipt.fromCallable(response, draft: draft),
    );
  }

  /// The request is built before any session check, so local validation
  /// errors are never reported as uncertain.
  Future<Object?> _submit(
    SaleCorrectionDraft draft,
    SaleCallable invoke,
    int Function() nextGeneration,
    int Function() currentGeneration,
  ) {
    final Map<String, Object?> request = draft.toRequest();
    if (draft.branchId != expectedSession.branchId) {
      throw const SaleSessionException();
    }
    final int generation = nextGeneration();
    return _staleAware(
      _call(invoke, request),
      () => generation != currentGeneration(),
    );
  }

  /// Once a submit returned, the correction may have committed, so any
  /// failure to parse its response (a protocol, validation, cast or range
  /// error alike) keeps the draft for a same-key retry instead of escaping.
  /// The original failure is logged and kept as the exception's cause.
  T _uncertainIfMalformed<T>(T Function() parse) {
    try {
      return parse();
    } catch (error, stackTrace) {
      _logParseFailure('submission', error, stackTrace);
      throw CorrectionUncertainException(error, stackTrace);
    }
  }

  void _logParseFailure(String kind, Object error, StackTrace stackTrace) {
    developer.log(
      'Malformed correction $kind response',
      name: 'lda.corrections',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// A superseded call is stale whatever its outcome: a late rejection or
  /// uncertainty must not reach a UI that already moved on. Session failures
  /// still surface, because they are not about this call's result.
  Future<Object?> _staleAware(
    Future<Object?> call,
    bool Function() superseded,
  ) async {
    final Object? response;
    try {
      response = await call;
    } on SaleRejectedException {
      if (superseded()) throw const SaleStaleException();
      rethrow;
    } on SaleUncertainException {
      if (superseded()) throw const SaleStaleException();
      rethrow;
    }
    if (superseded()) throw const SaleStaleException();
    return response;
  }

  /// Runs one call between two seller checks. A failed post-call check makes
  /// even a valid response uncertain; staleness is checked by the caller.
  Future<Object?> _call(
    SaleCallable invoke,
    Map<String, Object?> request,
  ) async {
    await _requireCurrentSeller();

    Object? response;
    Object? invocationError;
    try {
      response = await invoke(request);
    } catch (error) {
      invocationError = error;
    }

    try {
      await _requireCurrentSeller();
    } catch (_) {
      throw const SaleUncertainException();
    }
    if (invocationError != null) _throwMapped(invocationError);
    return response;
  }

  Future<void> _requireCurrentSeller() async {
    final EmulatorSession? current = await sessionChecker();
    if (current == null ||
        expectedSession.role != InventoryRole.seller ||
        expectedSession.branchId == null ||
        current.userId != expectedSession.userId ||
        current.role != InventoryRole.seller ||
        current.branchId != expectedSession.branchId) {
      throw const SaleSessionException();
    }
  }

  Never _throwMapped(Object error) {
    if (error is SaleCallableException && _rejectedCodes.contains(error.code)) {
      throw SaleRejectedException(
        code: error.code,
        message: error.message,
        reason: error.reason,
      );
    }
    throw const SaleUncertainException();
  }
}
