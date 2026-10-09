import 'dart:async';

import 'package:flutter/widgets.dart';

import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import 'correction_draft.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Quiet time after the last edit before the refund is previewed.
const Duration returnPreviewDelay = Duration(milliseconds: 400);

const String returnUncertainMessage =
    'No sabemos si la devolución se registró. Reintenta la misma devolución '
    'antes de hacer otro cambio.';
const String returnOverMessage =
    'La cantidad supera lo que queda por devolver. Revisa las cantidades.';
const String returnWindowMessage =
    'La venta ya está fuera del plazo de $correctionWindowDays días para '
    'correcciones.';
const String returnRejectedMessage =
    'La devolución fue rechazada. Revisa los datos e intenta de nuevo.';
const String returnPreviewFailedMessage = 'No se pudo calcular el reembolso.';
const String correctionSessionMessage =
    'Tu sesión cambió. Inicia sesión de nuevo para continuar.';
const String correctionUnresolvedMessage =
    'Hay otra corrección sin confirmar. Reinténtala antes de registrar una '
    'nueva.';

enum ReturnPreviewStatus { incomplete, loading, ready, failed }

/// Form state of one sale line. Only lines with a remaining returnable
/// quantity can be selected.
class ReturnLineEntry {
  ReturnLineEntry._(this.line);

  final CorrectableSaleLine line;
  final TextEditingController quantity = TextEditingController();
  bool selected = false;
  ReturnCondition condition = ReturnCondition.good;
  String? error;

  bool get returnable => line.remainingScaled > 0;
}

/// Presentation state for one return: per-line quantity and condition,
/// reason, note, the server preview of exactly the current form, and the
/// submit lifecycle.
///
/// Every edit re-previews after [previewDelay]; only the newest preview may
/// land, and "Confirmar devolución" is enabled only while the landed preview
/// equals the current form. While a submission is pending, or after an
/// uncertain one, the form is locked to the frozen draft until that same
/// draft is retried and resolves.
class CorrectionReturnController extends ChangeNotifier {
  CorrectionReturnController({
    required this.sale,
    required SaleCorrections corrections,
    this.onCompleted,
    this.previewDelay = returnPreviewDelay,
  }) : _corrections = corrections,
       lines = List<ReturnLineEntry>.unmodifiable(<ReturnLineEntry>[
         for (final CorrectableSaleLine line in sale.lines)
           ReturnLineEntry._(line),
       ]) {
    final SaleCorrectionDraft? unresolved = corrections.unresolvedDraft();
    final SaleReturnDraft? own = _ownDraft(unresolved);
    if (own != null) {
      _lock(own);
    } else if (unresolved != null ||
        corrections.unacknowledgedReturn() != null) {
      // The lookup shows an unacknowledged receipt before any form; this only
      // guards a form opened anyway.
      _blockedMessage = correctionUnresolvedMessage;
    }
  }

  final CorrectableSale sale;
  final ValueChanged<SaleReturnReceipt>? onCompleted;
  final Duration previewDelay;
  final List<ReturnLineEntry> lines;
  final TextEditingController note = TextEditingController();
  SaleCorrections _corrections;

  CorrectionReason? _reason;
  String? _noteError;
  SaleReturnPreview? _preview;
  ReturnPreviewStatus _status = ReturnPreviewStatus.incomplete;
  String? _previewMessage;
  int _previewGeneration = 0;
  Timer? _previewTimer;
  bool _submitting = false;
  SaleReturnDraft? _lockedDraft;
  String? _message;
  String? _blockedMessage;
  bool _disposed = false;

  set corrections(SaleCorrections value) => _corrections = value;

  CorrectionReason? get reason => _reason;
  String? get noteError => _noteError;
  ReturnPreviewStatus get previewStatus => _status;
  String? get previewMessage => _previewMessage;
  bool get isSubmitting => _submitting;
  bool get isLocked => _lockedDraft != null;

  /// A rejection, session or uncertainty message, else a blocking one.
  String? get message => _message ?? _blockedMessage;

  bool get canEdit => !_submitting && _lockedDraft == null;

  /// The landed preview, only while it answers exactly the current form.
  SaleReturnPreview? get preview {
    final SaleReturnPreview? landed = _preview;
    if (landed == null) return null;
    return landed.request == _currentRequest() ? landed : null;
  }

  bool get canConfirm =>
      canEdit &&
      _blockedMessage == null &&
      _noteError == null &&
      _status == ReturnPreviewStatus.ready &&
      preview != null;

  void setSelected(int lineIndex, bool selected) {
    final ReturnLineEntry entry = lines[lineIndex];
    if (!canEdit || !entry.returnable) return;
    entry.selected = selected;
    _formChanged();
  }

  /// Revalidates and re-previews after a quantity edit. The line's
  /// [ReturnLineEntry.quantity] controller already holds the new text.
  void quantityChanged() {
    if (!canEdit) return;
    _formChanged();
  }

  void setCondition(int lineIndex, ReturnCondition condition) {
    final ReturnLineEntry entry = lines[lineIndex];
    if (!canEdit || !entry.selected) return;
    entry.condition = condition;
    _formChanged();
  }

  void setReason(CorrectionReason reason) {
    if (!canEdit) return;
    _reason = reason;
    _formChanged();
  }

  /// The note is not previewed, so editing it only revalidates it.
  void setNote(String text) {
    if (!canEdit) return;
    _noteError = _validateNote(text);
    _message = null;
    _notify();
  }

  void retryPreview() {
    if (!canEdit) return;
    _preview = null;
    _requestPreview(immediate: true);
  }

  /// Freezes a draft equal to the fresh preview and submits it.
  Future<void> confirm() async {
    final SaleReturnPreview? current = preview;
    if (!canConfirm || current == null) return;
    final SaleReturnDraft draft;
    try {
      draft = SaleReturnDraft.create(
        sale: sale,
        branchId: _corrections.branchId,
        reason: current.request.reason,
        lines: _inputs(),
        note: note.text,
        createKey: _corrections.createKey,
      );
    } on CorrectionValidationException {
      _message = 'No se pudo preparar la devolución.';
      _notify();
      return;
    }
    // The draft is built from the same form as the fresh preview, so this
    // cannot differ unless the request derivation itself drifts. Never send
    // a refund the seller was not shown: re-preview instead.
    if (draft.previewRequest != current.request) {
      retryPreview();
      return;
    }
    await _send(draft);
  }

  /// Retries the unresolved draft, unchanged, with its original key.
  Future<void> retrySubmit() async {
    if (_submitting) return;
    final SaleReturnDraft? draft =
        _ownDraft(_corrections.unresolvedDraft()) ?? _lockedDraft;
    if (draft == null) return;
    _lock(draft);
    await _send(draft);
  }

  Future<void> _send(SaleReturnDraft draft) async {
    _submitting = true;
    _message = null;
    _cancelPreview();
    _notify();
    try {
      final SaleReturnReceipt receipt = await _corrections.submitReturn(draft);
      // A disposed form drops the receipt here safely: the shell keeps it
      // until the seller acknowledges it, and the lookup shows it on the
      // next opening.
      if (_disposed) return;
      _submitting = false;
      _lockedDraft = null;
      _notify();
      onCompleted?.call(receipt);
    } on SaleRejectedException catch (error) {
      if (_disposed) return;
      _submitting = false;
      _lockedDraft = null;
      _message = _rejectionMessage(error) ?? returnRejectedMessage;
      // Every rejection re-previews: the shown refund may no longer hold.
      _preview = null;
      _requestPreview(immediate: true);
    } on CorrectionUnresolvedException {
      if (_disposed) return;
      _submitting = false;
      _blockedMessage = correctionUnresolvedMessage;
      _notify();
    } on SaleSessionException {
      if (_disposed) return;
      _submitting = false;
      _reflectStore(fallback: null, message: correctionSessionMessage);
    } on SaleStaleException {
      // A newer attempt owns the outcome; reflect whatever the store holds.
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
    required SaleReturnDraft? fallback,
    required String? message,
  }) {
    final SaleReturnDraft? stored =
        _ownDraft(_corrections.unresolvedDraft()) ?? fallback;
    if (stored != null) {
      _lock(stored);
    } else {
      _lockedDraft = null;
      _message = message;
      _formChanged(keepMessage: true);
      return;
    }
    _notify();
  }

  SaleReturnDraft? _ownDraft(SaleCorrectionDraft? draft) =>
      draft is SaleReturnDraft && draft.saleId == sale.saleId ? draft : null;

  /// Shows the frozen draft in the form and freezes editing.
  void _lock(SaleReturnDraft draft) {
    _lockedDraft = draft;
    _cancelPreview();
    for (final ReturnLineEntry entry in lines) {
      entry.selected = false;
      entry.error = null;
    }
    for (final CorrectionLine line in draft.lines) {
      final ReturnLineEntry entry = lines[line.lineIndex];
      entry.selected = true;
      entry.quantity.text = line.quantity;
      entry.condition = line.condition ?? ReturnCondition.good;
    }
    _reason = draft.reason;
    note.text = draft.note ?? '';
    _noteError = null;
    _message = returnUncertainMessage;
    _status = _preview?.request == draft.previewRequest
        ? ReturnPreviewStatus.ready
        : ReturnPreviewStatus.incomplete;
  }

  void _formChanged({bool keepMessage = false}) {
    if (!keepMessage) _message = null;
    for (final ReturnLineEntry entry in lines) {
      entry.error = entry.selected ? _lineError(entry) : null;
    }
    _requestPreview(immediate: false);
  }

  void _requestPreview({required bool immediate}) {
    _cancelPreview();
    final SaleReturnPreviewRequest? request = _currentRequest();
    _previewMessage = null;
    if (request == null) {
      _status = ReturnPreviewStatus.incomplete;
      _notify();
      return;
    }
    if (_preview?.request == request) {
      _status = ReturnPreviewStatus.ready;
      _notify();
      return;
    }
    _status = ReturnPreviewStatus.loading;
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
    SaleReturnPreviewRequest request,
    int generation,
  ) async {
    try {
      final SaleReturnPreview landed = await _corrections.previewReturn(
        request,
      );
      if (!_isCurrentPreview(generation)) return;
      if (landed.request != request) {
        throw const CorrectionProtocolException();
      }
      _preview = landed;
      _status = ReturnPreviewStatus.ready;
    } on SaleRejectedException catch (error) {
      if (!_isCurrentPreview(generation)) return;
      _status = ReturnPreviewStatus.failed;
      _previewMessage = _rejectionMessage(error) ?? returnPreviewFailedMessage;
    } on SaleSessionException {
      if (!_isCurrentPreview(generation)) return;
      _status = ReturnPreviewStatus.failed;
      _previewMessage = correctionSessionMessage;
    } catch (_) {
      // Protocol, uncertain, or stale while this preview still owns the
      // form: a newer caller superseded it, so offer a retry.
      if (!_isCurrentPreview(generation)) return;
      _status = ReturnPreviewStatus.failed;
      _previewMessage = returnPreviewFailedMessage;
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

  /// The preview request for the current form, or null while incomplete
  /// or invalid. When locked, it is the frozen draft's.
  SaleReturnPreviewRequest? _currentRequest() {
    final SaleReturnDraft? locked = _lockedDraft;
    if (locked != null) return locked.previewRequest;
    final CorrectionReason? reason = _reason;
    final List<ReturnLineEntry> selected = <ReturnLineEntry>[
      for (final ReturnLineEntry entry in lines)
        if (entry.selected) entry,
    ];
    if (reason == null ||
        selected.isEmpty ||
        selected.any((ReturnLineEntry entry) => _lineError(entry) != null)) {
      return null;
    }
    try {
      return SaleReturnPreviewRequest.create(
        sale: sale,
        reason: reason,
        lines: _inputs(),
      );
    } on CorrectionValidationException {
      return null;
    }
  }

  List<ReturnLineInput> _inputs() => <ReturnLineInput>[
    for (final ReturnLineEntry entry in lines)
      if (entry.selected)
        ReturnLineInput(
          lineIndex: entry.line.lineIndex,
          quantity: entry.quantity.text.trim(),
          condition: entry.condition,
        ),
  ];

  @override
  void dispose() {
    _disposed = true;
    _cancelPreview();
    for (final ReturnLineEntry entry in lines) {
      entry.quantity.dispose();
    }
    note.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// Spanish copy for the refusals the seller can act on; null otherwise.
String? _rejectionMessage(SaleRejectedException error) {
  if (error.isOverReturn) return returnOverMessage;
  if (error.isOutsideCorrectionWindow) return returnWindowMessage;
  return null;
}

String? _validateNote(String text) {
  try {
    normalizeCorrectionNote(text);
    return null;
  } on CorrectionValidationException {
    return 'La nota admite como máximo $correctionNoteMaxLength caracteres.';
  }
}

/// Validates one selected line at its precision with BigInt, against its
/// remaining quantity.
String? _lineError(ReturnLineEntry entry) {
  final String text = entry.quantity.text.trim();
  if (text.isEmpty) return 'Escribe una cantidad.';
  final CorrectableSaleLine line = entry.line;
  final String over =
      'No puedes devolver más de lo restante '
      '(${line.remainingDecimal} ${line.quantitySpec.unit}).';
  final int scaled;
  try {
    scaled = scaleCorrectionQuantity(
      text,
      line.quantitySpec,
      productId: line.productId,
    );
  } on CorrectionValidationException catch (error) {
    final int precision = line.quantitySpec.precision;
    return switch (error.reason) {
      CorrectionValidationReason.tooPrecise =>
        precision == 0
            ? 'Este producto solo admite cantidades enteras.'
            : 'Usa como máximo $precision '
                  '${precision == 1 ? 'decimal' : 'decimales'}.',
      CorrectionValidationReason.notPositive =>
        'La cantidad debe ser mayor que cero.',
      CorrectionValidationReason.tooLarge => over,
      _ => 'Escribe una cantidad válida, por ejemplo 2 o 1.5.',
    };
  }
  return scaled > line.remainingScaled ? over : null;
}
