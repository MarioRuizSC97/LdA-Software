import 'package:flutter/foundation.dart';

import '../catalog/catalog_product.dart';
import '../firebase/emulator_sale_gateway.dart';
import 'sale_cart.dart';
import 'sale_draft.dart';
import 'sale_quote.dart';

typedef SaleQuoteRequest = Future<SaleQuote> Function(SaleCart cart);
typedef SaleSubmitRequest = Future<SaleReceipt> Function(SaleDraft draft);
typedef SaleDraftLookup = SaleDraft? Function();
typedef SaleKeyFactory = String Function();
typedef SaleReceiptLookup = SaleReceipt? Function();
typedef SaleReceiptAcknowledge = void Function(SaleReceipt receipt);

SaleReceipt? _noUnacknowledgedReceipt() => null;
void _ignoreAcknowledge(SaleReceipt receipt) {}

/// Seller-only sale operations the shell hands to the catalog page.
///
/// [submit] owns the shell-level draft store: it begins the attempt, submits,
/// drops it on a deterministic rejection and, on success, keeps its receipt
/// until [acknowledge]. [unresolvedDraft] returns the stored draft that must
/// be retried before any other sale; [unacknowledgedReceipt] returns a
/// committed sale the seller has not dismissed yet, which must be shown
/// before any other sale.
class SaleCheckout {
  const SaleCheckout({
    required this.branchId,
    required this.quote,
    required this.submit,
    required this.unresolvedDraft,
    this.unacknowledgedReceipt = _noUnacknowledgedReceipt,
    this.acknowledge = _ignoreAcknowledge,
    this.createKey = createSaleIdempotencyKey,
  });

  final String branchId;
  final SaleQuoteRequest quote;
  final SaleSubmitRequest submit;
  final SaleDraftLookup unresolvedDraft;
  final SaleReceiptLookup unacknowledgedReceipt;
  final SaleReceiptAcknowledge acknowledge;
  final SaleKeyFactory createKey;
}

enum SaleQuoteStatus { empty, loading, ready, uncertain, rejected }

const String uncertainSaleMessage =
    'No sabemos si la venta se registró. Reintenta la misma venta antes de '
    'editar.';
const String saleTotalChangedMessage =
    'El total cambió. Revisa el nuevo total y vuelve a cobrar.';
const String saleInsufficientStockMessage =
    'No hay existencias suficientes para completar la venta.';
const String saleSessionMessage =
    'Tu sesión ya no permite registrar ventas. Vuelve a iniciar sesión.';
const String salePendingReceiptMessage =
    'Hay una venta registrada que aún no revisas. Revisa el comprobante y '
    'toca "Nueva venta" para continuar.';

/// Presentation state for the seller cart: lines, the server quote for the
/// exact current cart, payment, and the submit lifecycle.
///
/// Every cart or invoice change re-quotes; only the newest quote may land.
/// While a submission is pending, or after an uncertain one, the cart is
/// locked to the frozen draft until that same draft is retried and resolves.
class SaleCartController extends ChangeNotifier {
  SaleCartController({
    required SaleCheckout checkout,
    this.onCompleted,
    this.onReceiptPending,
  }) : _checkout = checkout {
    final SaleDraft? unresolved = checkout.unresolvedDraft();
    if (unresolved != null) {
      _lock(unresolved);
    } else {
      _adoptPendingReceipt();
    }
  }

  SaleCheckout _checkout;
  final ValueChanged<SaleReceipt>? onCompleted;

  /// Called when a cart action finds a committed sale the seller has not
  /// acknowledged; [lastReceipt] then holds it and must be shown.
  final VoidCallback? onReceiptPending;

  SaleCart _cart = SaleCart.empty();
  SalePaymentMethod _paymentMethod = SalePaymentMethod.cash;
  SaleQuote? _quote;
  SaleQuoteStatus _quoteStatus = SaleQuoteStatus.empty;
  String? _quoteMessage;
  int _quoteGeneration = 0;
  bool _submitting = false;
  SaleDraft? _lockedDraft;
  String? _message;
  SaleReceipt? _lastReceipt;
  bool _receiptPending = false;
  String? _editingProductId;
  String? _entryError;
  bool _disposed = false;

  set checkout(SaleCheckout value) => _checkout = value;

  SaleCart get cart => _cart;
  SalePaymentMethod get paymentMethod => _paymentMethod;
  SaleQuoteStatus get quoteStatus => _quoteStatus;
  String? get quoteMessage => _quoteMessage;
  bool get isSubmitting => _submitting;
  bool get isLocked => _lockedDraft != null;
  String? get message => _message;
  SaleReceipt? get lastReceipt => _lastReceipt;

  /// Whether [lastReceipt] is a committed sale taken over from the shell
  /// (one the seller has not acknowledged yet), rather than the receipt of
  /// a sale charged from this cart. Shown with [salePendingReceiptMessage].
  bool get receiptPending => _lastReceipt != null && _receiptPending;
  String? get editingProductId => _editingProductId;
  String? get entryError => _entryError;

  /// The quote for exactly the displayed cart, if one has landed.
  SaleQuote? get quote =>
      _quote != null && _quote!.cart == _cart ? _quote : null;

  /// Lines and invoice option may change only when nothing is pending or
  /// unresolved.
  bool get canEdit => !_submitting && _lockedDraft == null;

  /// The authoritative total to show: the frozen draft amount when locked,
  /// otherwise the current quote total.
  int? get totalCentavos =>
      _lockedDraft?.amountCentavos ?? quote?.totalCentavos;

  bool get canCharge {
    final SaleQuote? current = quote;
    return canEdit &&
        _quoteStatus == SaleQuoteStatus.ready &&
        current != null &&
        !_cart.isEmpty &&
        current.allAvailable;
  }

  bool isUnavailable(String productId) =>
      quote?.unavailableProductIds.contains(productId) ?? false;

  SalePricedLine? pricedLine(String productId) {
    final SaleQuote? current = quote;
    if (current == null) return null;
    for (final SalePricedLine line in current.lines) {
      if (line.productId == productId) return line;
    }
    return null;
  }

  SaleCartLine? lineFor(String productId) {
    for (final SaleCartLine line in _cart.lines) {
      if (line.productId == productId) return line;
    }
    return null;
  }

  void startEntry(String productId) {
    if (!canEdit) return;
    _editingProductId = productId;
    _entryError = null;
    _notify();
  }

  void cancelEntry() {
    _editingProductId = null;
    _entryError = null;
    _notify();
  }

  /// Adds the product, or updates its existing line, after validating the
  /// quantity at the product precision. Returns whether it was saved.
  bool saveEntry({
    required String productId,
    required String name,
    required QuantitySpec quantitySpec,
    required String quantity,
  }) {
    if (!canEdit) return false;
    final String text = quantity.trim();
    final SaleCart next;
    try {
      if (text.isEmpty) {
        throw const SaleValidationException('empty');
      }
      next = _cart.contains(productId)
          ? _cart.updateQuantity(productId, text)
          : _cart.add(
              SaleCartLine(
                productId: productId,
                name: name,
                quantitySpec: quantitySpec,
                quantity: text,
              ),
            );
    } on SaleValidationException catch (error) {
      _editingProductId = productId;
      _entryError = text.isEmpty
          ? 'Escribe una cantidad.'
          : _quantityError(error.reason, quantitySpec.precision);
      _notify();
      return false;
    }
    _editingProductId = null;
    _entryError = null;
    _changeCart(next);
    return true;
  }

  void remove(String productId) {
    if (!canEdit || !_cart.contains(productId)) return;
    if (_editingProductId == productId) {
      _editingProductId = null;
      _entryError = null;
    }
    _changeCart(_cart.remove(productId));
  }

  void setInvoiceRequested(bool value) {
    if (!canEdit || value == _cart.invoiceRequested) return;
    _changeCart(_cart.withInvoiceRequested(value));
  }

  void setPaymentMethod(SalePaymentMethod method) {
    if (!canEdit) return;
    _paymentMethod = method;
    _notify();
  }

  void retryQuote() {
    if (!canEdit) return;
    _requote();
  }

  /// "Nueva venta": acknowledges the shown receipt, so the shell drops it.
  void dismissReceipt() {
    final SaleReceipt? receipt = _lastReceipt;
    if (receipt != null) {
      _checkout.acknowledge(receipt);
      _resetCart();
    }
    _lastReceipt = null;
    _message = null;
    _notify();
  }

  /// Reconciles with the shell when the cart opens: shows a committed sale
  /// the seller has not acknowledged yet, and unlocks a draft the shell no
  /// longer holds (a rejection that landed after an earlier cart closed).
  /// Returns whether a receipt is to be shown.
  bool reconcileOnOpen() {
    if (_submitting) return _lastReceipt != null;
    if (_blockOnPendingReceipt()) return true;
    if (_lockedDraft != null && _checkout.unresolvedDraft() == null) {
      _lockedDraft = null;
      _message = null;
      _requote();
    }
    return _lastReceipt != null;
  }

  /// Freezes a draft from the current quote and submits it.
  Future<void> charge() async {
    final SaleQuote? current = quote;
    if (!canCharge || current == null) return;
    if (_blockOnPendingReceipt()) return;
    final SaleDraft draft;
    try {
      draft = SaleDraft.fromQuote(
        quote: current,
        branchId: _checkout.branchId,
        paymentMethod: _paymentMethod,
        createKey: _checkout.createKey,
      );
    } on SaleValidationException {
      _message = 'No se pudo preparar la venta.';
      _notify();
      return;
    }
    await _send(draft);
  }

  /// Retries the unresolved draft, unchanged, with its original key.
  Future<void> retrySubmit() async {
    if (_submitting) return;
    if (_blockOnPendingReceipt()) return;
    final SaleDraft? draft = _checkout.unresolvedDraft() ?? _lockedDraft;
    if (draft == null) return;
    _lock(draft);
    await _send(draft);
  }

  Future<void> _send(SaleDraft draft) async {
    _submitting = true;
    _message = null;
    _lastReceipt = null;
    _notify();
    try {
      final SaleReceipt receipt = await _checkout.submit(draft);
      // The shell keeps the receipt until it is acknowledged, so a disposed
      // cart loses nothing: the next cart shows it first.
      if (_disposed) return;
      _submitting = false;
      _resetCart();
      _lastReceipt = receipt;
      _receiptPending = false;
      _notify();
      onCompleted?.call(receipt);
    } on SaleRejectedException catch (error) {
      if (_disposed) return;
      _submitting = false;
      _lockedDraft = null;
      _message = error.isPaymentMismatch
          ? saleTotalChangedMessage
          : error.isInsufficientStock
          ? saleInsufficientStockMessage
          : error.message.isEmpty
          ? 'La venta fue rechazada.'
          : 'La venta fue rechazada: ${error.message}';
      // Every rejection re-quotes: the old ready quote may be stale (a
      // changed price, short stock), so it must never keep "Cobrar" enabled.
      _requote();
    } on SaleSessionException {
      if (_disposed) return;
      _submitting = false;
      if (_blockOnPendingReceipt()) return;
      final SaleDraft? stored = _checkout.unresolvedDraft();
      if (stored != null) {
        _lock(stored);
      } else {
        _lockedDraft = null;
        _message = saleSessionMessage;
      }
      _notify();
    } on SaleStaleException {
      // A newer attempt owns the outcome; reflect whatever the store holds.
      if (_disposed) return;
      _submitting = false;
      if (_blockOnPendingReceipt()) return;
      final SaleDraft? stored = _checkout.unresolvedDraft();
      if (stored != null) {
        _lock(stored);
      } else {
        _lockedDraft = null;
      }
      _notify();
    } catch (_) {
      // Includes the shell refusing a new sale while another is stored.
      if (_disposed) return;
      _submitting = false;
      if (_blockOnPendingReceipt()) return;
      _lock(_checkout.unresolvedDraft() ?? draft);
      _notify();
    }
  }

  /// Takes over a committed, unacknowledged sale from the shell: the cart
  /// resets and [lastReceipt] holds it. A lock on that same sale is moot.
  bool _adoptPendingReceipt() {
    final SaleReceipt? receipt = _checkout.unacknowledgedReceipt();
    if (receipt == null) return false;
    if (identical(receipt, _lastReceipt)) return true;
    _resetCart();
    _lastReceipt = receipt;
    _receiptPending = true;
    return true;
  }

  /// An empty, unlocked cart with no quote, entry or message, paying cash:
  /// after a committed sale, a taken-over receipt, or "Nueva venta".
  void _resetCart() {
    _lockedDraft = null;
    _quoteGeneration += 1;
    _cart = SaleCart.empty();
    _quote = null;
    _quoteStatus = SaleQuoteStatus.empty;
    _quoteMessage = null;
    _paymentMethod = SalePaymentMethod.cash;
    _editingProductId = null;
    _entryError = null;
    _message = null;
  }

  /// Refuses a cart action while a committed sale awaits acknowledgement,
  /// showing its receipt as [receiptPending] instead.
  bool _blockOnPendingReceipt() {
    if (!_adoptPendingReceipt()) return false;
    _notify();
    onReceiptPending?.call();
    return true;
  }

  void _lock(SaleDraft draft) {
    _lockedDraft = draft;
    _cart = draft.cart;
    _paymentMethod = draft.paymentMethod;
    _editingProductId = null;
    _entryError = null;
    _message = uncertainSaleMessage;
    if (_quote?.cart != draft.cart) {
      _quoteGeneration += 1;
      _quote = null;
      _quoteStatus = SaleQuoteStatus.empty;
      _quoteMessage = null;
    }
  }

  void _changeCart(SaleCart next) {
    _cart = next;
    _message = null;
    _lastReceipt = null;
    _requote();
  }

  Future<void> _requote() async {
    final SaleCart cart = _cart;
    final int generation = ++_quoteGeneration;
    _quote = null;
    _quoteMessage = null;
    if (cart.isEmpty) {
      _quoteStatus = SaleQuoteStatus.empty;
      _notify();
      return;
    }
    _quoteStatus = SaleQuoteStatus.loading;
    _notify();
    try {
      final SaleQuote quote = await _checkout.quote(cart);
      if (!_isCurrentQuote(generation)) return;
      if (quote.cart != cart) throw const SaleUncertainException();
      _quote = quote;
      _quoteStatus = SaleQuoteStatus.ready;
    } on SaleStaleException {
      return;
    } on SaleRejectedException catch (error) {
      if (!_isCurrentQuote(generation)) return;
      _quoteStatus = SaleQuoteStatus.rejected;
      _quoteMessage = error.message;
    } on SaleSessionException {
      if (!_isCurrentQuote(generation)) return;
      _quoteStatus = SaleQuoteStatus.rejected;
      _quoteMessage = saleSessionMessage;
    } catch (_) {
      if (!_isCurrentQuote(generation)) return;
      _quoteStatus = SaleQuoteStatus.uncertain;
    }
    _notify();
  }

  bool _isCurrentQuote(int generation) =>
      !_disposed && generation == _quoteGeneration;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _quoteGeneration += 1;
    super.dispose();
  }
}

String _quantityError(SaleValidationReason reason, int precision) =>
    switch (reason) {
      SaleValidationReason.tooPrecise =>
        precision == 0
            ? 'Este producto solo admite cantidades enteras.'
            : 'Usa como máximo $precision '
                  '${precision == 1 ? 'decimal' : 'decimales'}.',
      SaleValidationReason.notPositive =>
        'La cantidad debe ser mayor que cero.',
      SaleValidationReason.tooLarge => 'La cantidad es demasiado grande.',
      _ => 'Escribe una cantidad válida, por ejemplo 2 o 1.5.',
    };
