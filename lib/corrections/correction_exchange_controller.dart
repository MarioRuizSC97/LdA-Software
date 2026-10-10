import 'dart:async';

import 'package:flutter/widgets.dart';

import '../catalog/catalog_product.dart';
import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import 'correction_draft.dart';
import 'correction_form_support.dart';
import 'correction_receipt.dart';
import 'correction_return_controller.dart' show ReturnLineEntry;
import 'correction_sale.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Quiet time after the last edit before the settlement is previewed.
const Duration exchangePreviewDelay = Duration(milliseconds: 400);

const String exchangeUncertainMessage =
    'No sabemos si el cambio se registró. Reintenta el mismo cambio antes de '
    'hacer otro.';
const String exchangePaymentChangedMessage =
    'El monto a pagar cambió. Revisa el nuevo cálculo y confirma de nuevo.';
const String exchangeOutOfStockMessage =
    'Sin existencias suficientes para los productos nuevos.';
const String exchangeOverMessage =
    'La cantidad supera lo que queda por devolver. Revisa las cantidades.';
const String exchangeRejectedMessage =
    'El cambio fue rechazado. Revisa los datos e intenta de nuevo.';
const String exchangePreviewFailedMessage = 'No se pudo calcular el cambio.';
const String exchangeDuplicateMessage =
    'Este producto ya está en el cambio. Edita su cantidad.';

/// Builds the exchange draft at confirmation; [SaleExchangeDraft.create]
/// except in tests that need the derivation to drift from the preview.
typedef ExchangeDraftBuilder = SaleExchangeDraft Function({
  required CorrectableSale sale,
  required String branchId,
  required CorrectionReason reason,
  required List<ReturnLineInput> returnLines,
  required SaleCart newItems,
  SaleExchangePayment? differencePayment,
  String? note,
  String Function() createKey,
});

enum ExchangePreviewStatus { incomplete, loading, ready, failed }

/// Form state of one new item: a priced product and its quantity.
class ExchangeNewLineEntry {
  ExchangeNewLineEntry._({
    required this.productId,
    required this.name,
    required this.quantitySpec,
  });

  final String productId;
  final String name;
  final QuantitySpec quantitySpec;
  final TextEditingController quantity = TextEditingController();
  String? error;
}

/// Presentation state for one exchange: returned lines (quantity up to the
/// remaining amount, condition), reason and note; new items chosen from the
/// branch catalog's priced products, each at most once; the server preview
/// of exactly the current form; the payment method for what the customer
/// owes; and the submit lifecycle.
///
/// Every edit re-previews after [previewDelay]; only the newest preview may
/// land. "Confirmar cambio" is enabled only while the landed preview equals
/// the current form and every new item is in stock. The difference payment
/// is never typed: it is exactly the preview's `customerPaysCentavos`, sent
/// only when positive. While a submission is pending, or after an uncertain
/// one, the form is locked to the frozen draft.
class CorrectionExchangeController extends ChangeNotifier {
  CorrectionExchangeController({
    required this.sale,
    required SaleCorrections corrections,
    required List<CatalogProduct> products,
    this.onCompleted,
    this.previewDelay = exchangePreviewDelay,
    this.buildDraft = SaleExchangeDraft.create,
  }) : _corrections = corrections,
       products = List<CatalogProduct>.unmodifiable(<CatalogProduct>[
         for (final CatalogProduct product in products)
           if (product.pricing != null) product,
       ]),
       returnLines = List<ReturnLineEntry>.unmodifiable(<ReturnLineEntry>[
         for (final CorrectableSaleLine line in sale.lines)
           ReturnLineEntry(line),
       ]),
       _paymentMethod = sale.paymentMethod {
    final SaleExchangeDraft? own = _ownDraft(corrections.unresolvedDraft());
    if (own != null) {
      _lock(own);
    } else {
      _blockedMessage = correctionBlockedMessage(corrections);
    }
  }

  final CorrectableSale sale;
  final ValueChanged<SaleExchangeReceipt>? onCompleted;
  final Duration previewDelay;

  /// Priced catalog products a new item may be chosen from.
  final List<CatalogProduct> products;
  final List<ReturnLineEntry> returnLines;
  final TextEditingController note = TextEditingController();

  /// Builds the draft at confirmation; only tests replace it.
  @visibleForTesting
  final ExchangeDraftBuilder buildDraft;
  final List<ExchangeNewLineEntry> _newLines = <ExchangeNewLineEntry>[];
  SaleCorrections _corrections;

  CorrectionReason? _reason;
  SalePaymentMethod _paymentMethod;
  String? _noteError;
  String? _newItemsMessage;
  SaleExchangePreview? _preview;
  ExchangePreviewStatus _status = ExchangePreviewStatus.incomplete;
  String? _previewMessage;
  int _previewGeneration = 0;
  Timer? _previewTimer;
  bool _submitting = false;
  SaleExchangeDraft? _lockedDraft;
  String? _message;
  String? _blockedMessage;
  bool _disposed = false;

  set corrections(SaleCorrections value) => _corrections = value;

  List<ExchangeNewLineEntry> get newLines =>
      List<ExchangeNewLineEntry>.unmodifiable(_newLines);
  CorrectionReason? get reason => _reason;

  /// How the customer pays what they owe; defaults to the sale's method.
  SalePaymentMethod get paymentMethod => _paymentMethod;
  String? get noteError => _noteError;
  String? get newItemsMessage => _newItemsMessage;
  ExchangePreviewStatus get previewStatus => _status;
  String? get previewMessage => _previewMessage;
  bool get isSubmitting => _submitting;
  bool get isLocked => _lockedDraft != null;

  /// A rejection, session or uncertainty message, else a blocking one.
  String? get message => _message ?? _blockedMessage;

  bool get canEdit => !_submitting && _lockedDraft == null;

  /// The landed preview, only while it answers exactly the current form.
  SaleExchangePreview? get preview {
    final SaleExchangePreview? landed = _preview;
    if (landed == null) return null;
    return landed.request == _currentRequest() ? landed : null;
  }

  bool get canConfirm {
    final SaleExchangePreview? current = preview;
    return canEdit &&
        _blockedMessage == null &&
        _noteError == null &&
        _status == ExchangePreviewStatus.ready &&
        current != null &&
        current.allAvailable;
  }

  bool contains(String productId) => _newLines.any(
    (ExchangeNewLineEntry entry) => entry.productId == productId,
  );

  void setSelected(int lineIndex, bool selected) {
    final ReturnLineEntry entry = returnLines[lineIndex];
    if (!canEdit || !entry.returnable) return;
    entry.selected = selected;
    _formChanged();
  }

  /// Revalidates and re-previews after any quantity edit; the controller of
  /// the edited line already holds the new text.
  void quantityChanged() {
    if (!canEdit) return;
    _formChanged();
  }

  void setCondition(int lineIndex, ReturnCondition condition) {
    final ReturnLineEntry entry = returnLines[lineIndex];
    if (!canEdit || !entry.selected) return;
    entry.condition = condition;
    _formChanged();
  }

  void setReason(CorrectionReason reason) {
    if (!canEdit) return;
    _reason = reason;
    _formChanged();
  }

  /// Adds a priced product as a new item. A product already added is
  /// rejected, as in the sale cart: edit its quantity instead.
  void addProduct(String productId) {
    if (!canEdit) return;
    if (contains(productId)) {
      _newItemsMessage = exchangeDuplicateMessage;
      _notify();
      return;
    }
    final CatalogProduct product = products.firstWhere(
      (CatalogProduct product) => product.internalCode == productId,
    );
    _newLines.add(
      ExchangeNewLineEntry._(
        productId: productId,
        name: product.name,
        quantitySpec: product.quantitySpec,
      ),
    );
    _formChanged();
  }

  void removeProduct(String productId) {
    if (!canEdit) return;
    final int index = _newLines.indexWhere(
      (ExchangeNewLineEntry entry) => entry.productId == productId,
    );
    if (index < 0) return;
    _newLines.removeAt(index).quantity.dispose();
    _formChanged();
  }

  /// Not previewed: only the method of the difference payment changes.
  void setPaymentMethod(SalePaymentMethod method) {
    if (!canEdit) return;
    _paymentMethod = method;
    _notify();
  }

  void setNote(String text) {
    if (!canEdit) return;
    _noteError = correctionNoteError(text);
    _message = null;
    _notify();
  }

  void retryPreview() {
    if (!canEdit) return;
    _preview = null;
    _requestPreview(immediate: true);
  }

  /// Freezes a draft equal to the fresh preview, paying exactly what it
  /// says the customer owes, and submits it.
  Future<void> confirm() async {
    final SaleExchangePreview? current = preview;
    if (!canConfirm || current == null) return;
    final int owed = current.customerPaysCentavos;
    final SaleExchangeDraft draft;
    try {
      draft = buildDraft(
        sale: sale,
        branchId: _corrections.branchId,
        reason: current.request.reason,
        returnLines: _returnInputs(),
        newItems: _newItemsCart()!,
        differencePayment: owed > 0
            ? SaleExchangePayment(method: _paymentMethod, amountCentavos: owed)
            : null,
        note: note.text,
        createKey: _corrections.createKey,
      );
    } on Object {
      _message = 'No se pudo preparar el cambio.';
      _notify();
      return;
    }
    // Built from the same form as the fresh preview, so this cannot differ
    // unless the request derivation drifts. Never send a settlement the
    // seller was not shown: re-preview instead.
    if (draft.previewRequest != current.request) {
      retryPreview();
      return;
    }
    await _send(draft);
  }

  /// Retries the unresolved draft, unchanged, with its original key.
  Future<void> retrySubmit() async {
    if (_submitting) return;
    final SaleExchangeDraft? draft =
        _ownDraft(_corrections.unresolvedDraft()) ?? _lockedDraft;
    if (draft == null) return;
    _lock(draft);
    await _send(draft);
  }

  Future<void> _send(SaleExchangeDraft draft) async {
    _submitting = true;
    _message = null;
    _cancelPreview();
    _notify();
    try {
      final SaleExchangeReceipt receipt = await _corrections.submitExchange(
        draft,
      );
      // A disposed form drops the receipt here safely: the shell keeps it
      // until the seller acknowledges it.
      if (_disposed) return;
      _submitting = false;
      _lockedDraft = null;
      _notify();
      onCompleted?.call(receipt);
    } on SaleRejectedException catch (error) {
      if (_disposed) return;
      _submitting = false;
      _lockedDraft = null;
      _message = _rejectionMessage(error);
      // Every rejection re-previews: the shown settlement may no longer hold
      // (a payment mismatch means the amount owed changed).
      _preview = null;
      _requestPreview(immediate: true);
    } on CorrectionUnresolvedException {
      if (_disposed) return;
      _submitting = false;
      _blockedMessage =
          correctionBlockedMessage(_corrections) ?? correctionUnresolvedMessage;
      _notify();
    } on SaleSessionException {
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: null, message: correctionSessionMessage);
    } on SaleStaleException {
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: null, message: null);
    } catch (_) {
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: draft, message: null);
    }
  }

  void _reflectStore({
    required SaleExchangeDraft? fallback,
    required String? message,
  }) {
    final SaleExchangeDraft? stored =
        _ownDraft(_corrections.unresolvedDraft()) ?? fallback;
    if (stored != null) {
      _lock(stored);
      _notify();
      return;
    }
    _lockedDraft = null;
    _message = message;
    _formChanged(keepMessage: true);
  }

  SaleExchangeDraft? _ownDraft(SaleCorrectionDraft? draft) =>
      draft is SaleExchangeDraft && draft.saleId == sale.saleId ? draft : null;

  /// Shows the frozen draft in the form and freezes editing.
  void _lock(SaleExchangeDraft draft) {
    _lockedDraft = draft;
    _cancelPreview();
    for (final ReturnLineEntry entry in returnLines) {
      entry.selected = false;
      entry.error = null;
    }
    for (final CorrectionLine line in draft.returnLines) {
      final ReturnLineEntry entry = returnLines[line.lineIndex];
      entry.selected = true;
      entry.quantity.text = line.quantity;
      entry.condition = line.condition ?? ReturnCondition.good;
    }
    for (final ExchangeNewLineEntry entry in _newLines) {
      entry.quantity.dispose();
    }
    _newLines
      ..clear()
      ..addAll(<ExchangeNewLineEntry>[
        for (final SaleCartLine line in draft.newItems.lines)
          ExchangeNewLineEntry._(
            productId: line.productId,
            name: line.name,
            quantitySpec: line.quantitySpec,
          )..quantity.text = line.quantity,
      ]);
    _reason = draft.reason;
    _paymentMethod = draft.differencePayment?.method ?? sale.paymentMethod;
    note.text = draft.note ?? '';
    _noteError = null;
    _newItemsMessage = null;
    _message = exchangeUncertainMessage;
    _status = _preview?.request == draft.previewRequest
        ? ExchangePreviewStatus.ready
        : ExchangePreviewStatus.incomplete;
  }

  void _formChanged({bool keepMessage = false}) {
    if (!keepMessage) _message = null;
    _newItemsMessage = null;
    for (final ReturnLineEntry entry in returnLines) {
      entry.error = entry.selected ? _returnLineError(entry) : null;
    }
    final Set<String> returned = _returnedProducts();
    for (final ExchangeNewLineEntry entry in _newLines) {
      entry.error = _newLineError(entry, returned);
    }
    _requestPreview(immediate: false);
  }

  void _requestPreview({required bool immediate}) {
    _cancelPreview();
    final SaleExchangePreviewRequest? request = _currentRequest();
    _previewMessage = null;
    if (request == null) {
      _status = ExchangePreviewStatus.incomplete;
      _notify();
      return;
    }
    if (_preview?.request == request) {
      _status = ExchangePreviewStatus.ready;
      _notify();
      return;
    }
    _status = ExchangePreviewStatus.loading;
    _notify();
    final int generation = _previewGeneration;
    if (immediate) {
      _runPreview(request, generation);
    } else {
      _previewTimer = Timer(
        previewDelay,
        () => _runPreview(request, generation),
      );
    }
  }

  Future<void> _runPreview(
    SaleExchangePreviewRequest request,
    int generation,
  ) async {
    try {
      final SaleExchangePreview landed = await _corrections.previewExchange(
        request,
      );
      if (!_isCurrentPreview(generation)) return;
      if (landed.request != request) {
        throw const CorrectionProtocolException();
      }
      _preview = landed;
      _status = ExchangePreviewStatus.ready;
    } on SaleRejectedException catch (error) {
      if (!_isCurrentPreview(generation)) return;
      _status = ExchangePreviewStatus.failed;
      _previewMessage = _previewRejectionMessage(error);
    } on SaleSessionException {
      if (!_isCurrentPreview(generation)) return;
      _status = ExchangePreviewStatus.failed;
      _previewMessage = correctionSessionMessage;
    } catch (_) {
      // Protocol, uncertain, or stale while this preview still owns the
      // form: a newer caller superseded it, so offer a retry.
      if (!_isCurrentPreview(generation)) return;
      _status = ExchangePreviewStatus.failed;
      _previewMessage = exchangePreviewFailedMessage;
    }
    _notify();
  }

  bool _isCurrentPreview(int generation) =>
      !_disposed && generation == _previewGeneration;

  void _cancelPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    _previewGeneration += 1;
  }

  /// The preview request for the current form, or null while incomplete or
  /// invalid. When locked, it is the frozen draft's.
  SaleExchangePreviewRequest? _currentRequest() {
    final SaleExchangeDraft? locked = _lockedDraft;
    if (locked != null) return locked.previewRequest;
    final CorrectionReason? reason = _reason;
    final List<ReturnLineEntry> selected = <ReturnLineEntry>[
      for (final ReturnLineEntry entry in returnLines)
        if (entry.selected) entry,
    ];
    final Set<String> returned = _returnedProducts();
    if (reason == null ||
        selected.isEmpty ||
        _newLines.isEmpty ||
        selected.any((ReturnLineEntry e) => _returnLineError(e) != null) ||
        _newLines.any(
          (ExchangeNewLineEntry e) => _newLineError(e, returned) != null,
        )) {
      return null;
    }
    try {
      return SaleExchangePreviewRequest.create(
        sale: sale,
        reason: reason,
        returnLines: _returnInputs(),
        newItems: _newItemsCart()!,
      );
    } on CorrectionValidationException {
      return null;
    } on SaleValidationException {
      return null;
    }
  }

  List<ReturnLineInput> _returnInputs() => <ReturnLineInput>[
    for (final ReturnLineEntry entry in returnLines)
      if (entry.selected)
        ReturnLineInput(
          lineIndex: entry.line.lineIndex,
          quantity: entry.quantity.text.trim(),
          condition: entry.condition,
        ),
  ];

  /// The new items as a cart in the order added, or null when any quantity
  /// is invalid. Duplicates cannot occur: [addProduct] refuses them.
  SaleCart? _newItemsCart() {
    SaleCart cart = SaleCart.empty();
    try {
      for (final ExchangeNewLineEntry entry in _newLines) {
        cart = cart.add(
          SaleCartLine(
            productId: entry.productId,
            name: entry.name,
            quantitySpec: entry.quantitySpec,
            quantity: entry.quantity.text.trim(),
          ),
        );
      }
    } on SaleValidationException {
      return null;
    }
    return cart;
  }

  Set<String> _returnedProducts() => <String>{
    for (final ReturnLineEntry entry in returnLines)
      if (entry.selected) entry.line.productId,
  };

  @override
  void dispose() {
    _disposed = true;
    _cancelPreview();
    for (final ReturnLineEntry entry in returnLines) {
      entry.quantity.dispose();
    }
    for (final ExchangeNewLineEntry entry in _newLines) {
      entry.quantity.dispose();
    }
    note.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

String _rejectionMessage(SaleRejectedException error) {
  if (error.isPaymentMismatch) return exchangePaymentChangedMessage;
  if (error.isOutOfStock) return exchangeOutOfStockMessage;
  if (error.isOverReturn) return exchangeOverMessage;
  if (error.isOutsideCorrectionWindow) return correctionWindowMessage;
  return exchangeRejectedMessage;
}

String _previewRejectionMessage(SaleRejectedException error) {
  if (error.isOverReturn) return exchangeOverMessage;
  if (error.isOutsideCorrectionWindow) return correctionWindowMessage;
  return exchangePreviewFailedMessage;
}

String? _returnLineError(ReturnLineEntry entry) =>
    correctionLineError(entry.quantity.text, entry.line, verb: 'devolver');

String? _newLineError(ExchangeNewLineEntry entry, Set<String> returned) {
  if (returned.contains(entry.productId)) {
    return 'Este producto se está devolviendo. Para el mismo producto usa el '
        'reemplazo.';
  }
  return newItemQuantityError(
    entry.quantity.text,
    entry.quantitySpec,
    entry.productId,
  );
}
