import 'package:flutter/widgets.dart';

import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import 'correction_draft.dart';
import 'correction_form_support.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

const String replacementUncertainMessage =
    'No sabemos si el reemplazo se registró. Reintenta el mismo reemplazo '
    'antes de hacer otro cambio.';
const String replacementOutOfStockMessage =
    'Sin existencias suficientes para reemplazar';
const String replacementOverMessage =
    'La cantidad supera lo que queda por reemplazar. Revisa las cantidades.';
const String replacementRejectedMessage =
    'El reemplazo fue rechazado. Revisa los datos e intenta de nuevo.';

/// Form state of one sale line. Only lines with a remaining returnable
/// quantity can be replaced (decision 11).
class ReplacementLineEntry {
  ReplacementLineEntry._(this.line);

  final CorrectableSaleLine line;
  final TextEditingController quantity = TextEditingController();
  bool selected = false;
  String? error;

  bool get replaceable => line.remainingScaled > 0;
}

/// Presentation state for one factory-defect replacement: per-line
/// quantity, an optional note, and the submit lifecycle. The reason is
/// always `factory-defect` and the charge always 0, so nothing is
/// previewed.
///
/// While a submission is pending, or after an uncertain one, the form is
/// locked to the frozen draft until that same draft is retried and
/// resolves.
class CorrectionReplacementController extends ChangeNotifier {
  CorrectionReplacementController({
    required this.sale,
    required SaleCorrections corrections,
    this.onCompleted,
  }) : _corrections = corrections,
       lines = List<ReplacementLineEntry>.unmodifiable(<ReplacementLineEntry>[
         for (final CorrectableSaleLine line in sale.lines)
           ReplacementLineEntry._(line),
       ]) {
    final SaleReplacementDraft? own = _ownDraft(corrections.unresolvedDraft());
    if (own != null) {
      _lock(own);
    } else {
      _blockedMessage = correctionBlockedMessage(corrections);
    }
  }

  final CorrectableSale sale;
  final ValueChanged<SaleReplacementReceipt>? onCompleted;
  final List<ReplacementLineEntry> lines;
  final TextEditingController note = TextEditingController();
  SaleCorrections _corrections;

  String? _noteError;
  bool _submitting = false;
  SaleReplacementDraft? _lockedDraft;
  String? _message;
  String? _blockedMessage;
  bool _disposed = false;

  set corrections(SaleCorrections value) => _corrections = value;

  String? get noteError => _noteError;
  bool get isSubmitting => _submitting;
  bool get isLocked => _lockedDraft != null;

  /// A rejection, session or uncertainty message, else a blocking one.
  String? get message => _message ?? _blockedMessage;

  bool get canEdit => !_submitting && _lockedDraft == null;

  bool get canConfirm {
    if (!canEdit || _blockedMessage != null || _noteError != null) {
      return false;
    }
    final List<ReplacementLineEntry> selected = _selected();
    return selected.isNotEmpty &&
        selected.every(
          (ReplacementLineEntry entry) => _lineError(entry) == null,
        );
  }

  void setSelected(int lineIndex, bool selected) {
    final ReplacementLineEntry entry = lines[lineIndex];
    if (!canEdit || !entry.replaceable) return;
    entry.selected = selected;
    _formChanged();
  }

  /// Revalidates after a quantity edit; the line's controller already holds
  /// the new text.
  void quantityChanged() {
    if (!canEdit) return;
    _formChanged();
  }

  void setNote(String text) {
    if (!canEdit) return;
    _noteError = correctionNoteError(text);
    _message = null;
    _notify();
  }

  /// Freezes a draft from the form and submits it.
  Future<void> confirm() async {
    if (!canConfirm) return;
    final SaleReplacementDraft draft;
    try {
      draft = SaleReplacementDraft.create(
        sale: sale,
        branchId: _corrections.branchId,
        lines: <ReplacementLineInput>[
          for (final ReplacementLineEntry entry in _selected())
            ReplacementLineInput(
              lineIndex: entry.line.lineIndex,
              quantity: entry.quantity.text.trim(),
            ),
        ],
        note: note.text,
        createKey: _corrections.createKey,
      );
    } on CorrectionValidationException {
      _message = 'No se pudo preparar el reemplazo.';
      _notify();
      return;
    }
    await _send(draft);
  }

  /// Retries the unresolved draft, unchanged, with its original key.
  Future<void> retrySubmit() async {
    if (_submitting) return;
    final SaleReplacementDraft? draft =
        _ownDraft(_corrections.unresolvedDraft()) ?? _lockedDraft;
    if (draft == null) return;
    _lock(draft);
    await _send(draft);
  }

  Future<void> _send(SaleReplacementDraft draft) async {
    _submitting = true;
    _message = null;
    _notify();
    try {
      final SaleReplacementReceipt receipt = await _corrections
          .submitReplacement(draft);
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
      _notify();
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
      // A newer attempt owns the outcome; reflect whatever the store holds,
      // and explain an unlocked form instead of leaving it silent.
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: null, message: correctionStaleMessage);
    } catch (_) {
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: draft, message: null);
    }
  }

  void _reflectStore({
    required SaleReplacementDraft? fallback,
    required String? message,
  }) {
    final SaleReplacementDraft? stored =
        _ownDraft(_corrections.unresolvedDraft()) ?? fallback;
    if (stored != null) {
      _lock(stored);
    } else {
      _lockedDraft = null;
      _message = message;
    }
    _notify();
  }

  SaleReplacementDraft? _ownDraft(SaleCorrectionDraft? draft) =>
      draft is SaleReplacementDraft && draft.saleId == sale.saleId
      ? draft
      : null;

  void _lock(SaleReplacementDraft draft) {
    _lockedDraft = draft;
    for (final ReplacementLineEntry entry in lines) {
      entry.selected = false;
      entry.error = null;
    }
    for (final CorrectionLine line in draft.lines) {
      final ReplacementLineEntry entry = lines[line.lineIndex];
      entry.selected = true;
      entry.quantity.text = line.quantity;
    }
    note.text = draft.note ?? '';
    _noteError = null;
    _message = replacementUncertainMessage;
  }

  void _formChanged() {
    _message = null;
    for (final ReplacementLineEntry entry in lines) {
      entry.error = entry.selected ? _lineError(entry) : null;
    }
    _notify();
  }

  List<ReplacementLineEntry> _selected() => <ReplacementLineEntry>[
    for (final ReplacementLineEntry entry in lines)
      if (entry.selected) entry,
  ];

  @override
  void dispose() {
    _disposed = true;
    for (final ReplacementLineEntry entry in lines) {
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
  if (error.isOutOfStock) return replacementOutOfStockMessage;
  if (error.isOverReturn) return replacementOverMessage;
  if (error.isOutsideCorrectionWindow) return correctionWindowMessage;
  return replacementRejectedMessage;
}

String? _lineError(ReplacementLineEntry entry) =>
    correctionLineError(entry.quantity.text, entry.line, verb: 'reemplazar');
