import 'dart:convert';

import '../catalog/catalog_product.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_draft.dart' show createSaleIdempotencyKey;
import 'correction_sale.dart';

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Server limit for the optional free-text correction note.
const int correctionNoteMaxLength = 500;

/// The fixed correction reasons (decision 10), in wire order.
enum CorrectionReason {
  changeOfMind('change-of-mind'),
  wrongProduct('wrong-product'),
  factoryDefect('factory-defect'),
  other('other');

  const CorrectionReason(this.wireValue);
  final String wireValue;

  static CorrectionReason? fromWire(Object? value) {
    for (final CorrectionReason reason in values) {
      if (reason.wireValue == value) return reason;
    }
    return null;
  }
}

/// Condition of a returned unit (decision 4): only `good` restocks.
enum ReturnCondition {
  good('good'),
  factoryDefect('factory-defect');

  const ReturnCondition(this.wireValue);
  final String wireValue;

  static ReturnCondition? fromWire(Object? value) {
    for (final ReturnCondition condition in values) {
      if (condition.wireValue == value) return condition;
    }
    return null;
  }
}

/// Seller input for one returned sale line.
class ReturnLineInput {
  const ReturnLineInput({
    required this.lineIndex,
    required this.quantity,
    required this.condition,
  });
  final int lineIndex;

  /// Canonical decimal string at the line precision, sent verbatim.
  final String quantity;
  final ReturnCondition condition;
}

/// Seller input for one factory-defect replacement line.
class ReplacementLineInput {
  const ReplacementLineInput({required this.lineIndex, required this.quantity});
  final int lineIndex;
  final String quantity;
}

/// One validated correction line against the looked-up sale.
class CorrectionLine {
  const CorrectionLine._({
    required this.lineIndex,
    required this.productId,
    required this.quantitySpec,
    required this.quantity,
    required this.quantityScaled,
    this.condition,
  });

  final int lineIndex;
  final String productId;
  final QuantitySpec quantitySpec;
  final String quantity;

  /// Exact quantity scaled with BigInt at the sale line precision.
  final int quantityScaled;

  /// Null for replacement lines.
  final ReturnCondition? condition;

  Map<String, Object?> toRequestLine() => <String, Object?>{
    'lineIndex': lineIndex,
    'quantity': quantity,
    if (condition != null) 'condition': condition!.wireValue,
  };
}

/// Difference the customer pays in an exchange: always exactly the amount
/// the server computes as owed, never typed by hand.
class SaleExchangePayment {
  const SaleExchangePayment({
    required this.method,
    required this.amountCentavos,
  });
  final SalePaymentMethod method;
  final int amountCentavos;

  Map<String, Object?> toRequest() => <String, Object?>{
    'method': method.wireValue,
    'amountCentavos': amountCentavos,
  };
}

/// Immutable correction request frozen at confirmation.
///
/// The idempotency key is generated exactly once, when the draft is created;
/// an uncertain submission must be retried with this same draft (see
/// [CorrectionDraftStore]) so the server replays instead of correcting twice.
sealed class SaleCorrectionDraft {
  SaleCorrectionDraft._({
    required this.idempotencyKey,
    required this.branchId,
    required this.sale,
  });

  final String idempotencyKey;

  /// The seller's branch. It is not sent: the server takes it from claims.
  final String branchId;

  /// The looked-up sale the draft was validated against.
  final CorrectableSale sale;

  String get saleId => sale.saleId;

  /// Exact callable request.
  Map<String, Object?> toRequest();

  /// Drafts are equal when they would send the same request from the same
  /// branch: a retry of an equal draft is the same server operation.
  @override
  bool operator ==(Object other) =>
      other is SaleCorrectionDraft &&
      other.runtimeType == runtimeType &&
      other.branchId == branchId &&
      jsonEncode(other.toRequest()) == jsonEncode(toRequest());

  @override
  int get hashCode =>
      Object.hash(runtimeType, branchId, jsonEncode(toRequest()));
}

/// `submitSaleReturn`: `{idempotencyKey, saleId, reason, lines, note?}`.
class SaleReturnDraft extends SaleCorrectionDraft {
  SaleReturnDraft._({
    required super.idempotencyKey,
    required super.branchId,
    required super.sale,
    required this.reason,
    required this.note,
    required this.lines,
  }) : super._();

  factory SaleReturnDraft.create({
    required CorrectableSale sale,
    required String branchId,
    required CorrectionReason reason,
    required List<ReturnLineInput> lines,
    String? note,
    String Function() createKey = createSaleIdempotencyKey,
  }) {
    final List<CorrectionLine> validated = _returnLines(sale, lines);
    final String? normalizedNote = normalizeCorrectionNote(note);
    _requireBranch(branchId);
    return SaleReturnDraft._(
      idempotencyKey: _newKey(createKey),
      branchId: branchId,
      sale: sale,
      reason: reason,
      note: normalizedNote,
      lines: validated,
    );
  }

  final CorrectionReason reason;
  final String? note;
  final List<CorrectionLine> lines;

  /// The preview of exactly this return: same sale, reason and lines. A
  /// draft may be confirmed only against a preview equal to this one.
  SaleReturnPreviewRequest get previewRequest =>
      SaleReturnPreviewRequest._(sale: sale, reason: reason, lines: lines);

  @override
  Map<String, Object?> toRequest() => <String, Object?>{
    'idempotencyKey': idempotencyKey,
    'saleId': saleId,
    'reason': reason.wireValue,
    'lines': <Object?>[
      for (final CorrectionLine line in lines) line.toRequestLine(),
    ],
    if (note != null) 'note': note,
  };
}

/// `previewSaleReturn`: exactly `{saleId, reason, lines}`, the return
/// request without its write-only key and note. Lines are validated exactly
/// like [SaleReturnDraft.create]; the server recomputes against its ledger.
class SaleReturnPreviewRequest {
  const SaleReturnPreviewRequest._({
    required this.sale,
    required this.reason,
    required this.lines,
  });

  factory SaleReturnPreviewRequest.create({
    required CorrectableSale sale,
    required CorrectionReason reason,
    required List<ReturnLineInput> lines,
  }) => SaleReturnPreviewRequest._(
    sale: sale,
    reason: reason,
    lines: _returnLines(sale, lines),
  );

  /// The looked-up sale the lines were validated against.
  final CorrectableSale sale;
  final CorrectionReason reason;
  final List<CorrectionLine> lines;

  String get saleId => sale.saleId;

  Map<String, Object?> toRequest() => <String, Object?>{
    'saleId': saleId,
    'reason': reason.wireValue,
    'lines': <Object?>[
      for (final CorrectionLine line in lines) line.toRequestLine(),
    ],
  };

  /// Equal when they would send the same preview request.
  @override
  bool operator ==(Object other) =>
      other is SaleReturnPreviewRequest &&
      jsonEncode(other.toRequest()) == jsonEncode(toRequest());

  @override
  int get hashCode => jsonEncode(toRequest()).hashCode;
}

/// `submitSaleReplacement`: `{idempotencyKey, saleId, lines, note?}`. The
/// reason is always `factory-defect` and is fixed by the server.
class SaleReplacementDraft extends SaleCorrectionDraft {
  SaleReplacementDraft._({
    required super.idempotencyKey,
    required super.branchId,
    required super.sale,
    required this.note,
    required this.lines,
  }) : super._();

  /// Each line is capped at its remaining returnable quantity (decision 11).
  factory SaleReplacementDraft.create({
    required CorrectableSale sale,
    required String branchId,
    required List<ReplacementLineInput> lines,
    String? note,
    String Function() createKey = createSaleIdempotencyKey,
  }) {
    final List<CorrectionLine> validated = _validatedLines(sale, <_LineInput>[
      for (final ReplacementLineInput line in lines)
        _LineInput(line.lineIndex, line.quantity, null),
    ]);
    final String? normalizedNote = normalizeCorrectionNote(note);
    _requireBranch(branchId);
    return SaleReplacementDraft._(
      idempotencyKey: _newKey(createKey),
      branchId: branchId,
      sale: sale,
      note: normalizedNote,
      lines: validated,
    );
  }

  final String? note;
  final List<CorrectionLine> lines;

  @override
  Map<String, Object?> toRequest() => <String, Object?>{
    'idempotencyKey': idempotencyKey,
    'saleId': saleId,
    'lines': <Object?>[
      for (final CorrectionLine line in lines) line.toRequestLine(),
    ],
    if (note != null) 'note': note,
  };
}

/// `submitSaleExchange`: `{idempotencyKey, saleId, reason, returnLines,
/// newLines, differencePayment?, note?}`.
class SaleExchangeDraft extends SaleCorrectionDraft {
  SaleExchangeDraft._({
    required super.idempotencyKey,
    required super.branchId,
    required super.sale,
    required this.reason,
    required this.note,
    required this.returnLines,
    required this.newItems,
    required this.differencePayment,
  }) : super._();

  /// New items always keep the original sale's invoice intent, so their
  /// invoice flag is set from the sale. They must differ from every returned
  /// product (a same-product swap is a replacement). [differencePayment] is
  /// required by the server exactly when the customer owes a difference, with
  /// exactly that amount, and must be absent otherwise.
  factory SaleExchangeDraft.create({
    required CorrectableSale sale,
    required String branchId,
    required CorrectionReason reason,
    required List<ReturnLineInput> returnLines,
    required SaleCart newItems,
    SaleExchangePayment? differencePayment,
    String? note,
    String Function() createKey = createSaleIdempotencyKey,
  }) {
    final List<CorrectionLine> validated = _returnLines(sale, returnLines);
    if (newItems.isEmpty) {
      throw const CorrectionValidationException(
        'An exchange needs at least one new item.',
        reason: CorrectionValidationReason.noNewItems,
      );
    }
    final Set<String> returned = <String>{
      for (final CorrectionLine line in validated) line.productId,
    };
    if (newItems.lines.any(
      (SaleCartLine line) => returned.contains(line.productId),
    )) {
      throw const CorrectionValidationException(
        'A new item cannot be a returned product.',
        reason: CorrectionValidationReason.newItemIsReturned,
      );
    }
    final SaleExchangePayment? payment = differencePayment;
    if (payment != null &&
        (payment.amountCentavos <= 0 ||
            payment.amountCentavos > maxSafeSaleInteger)) {
      throw const CorrectionValidationException(
        'Difference payment must be a positive safe centavo amount.',
        reason: CorrectionValidationReason.invalidPayment,
      );
    }
    final String? normalizedNote = normalizeCorrectionNote(note);
    _requireBranch(branchId);
    return SaleExchangeDraft._(
      idempotencyKey: _newKey(createKey),
      branchId: branchId,
      sale: sale,
      reason: reason,
      note: normalizedNote,
      returnLines: validated,
      newItems: newItems.withInvoiceRequested(sale.invoiced),
      differencePayment: payment,
    );
  }

  final CorrectionReason reason;
  final String? note;
  final List<CorrectionLine> returnLines;
  final SaleCart newItems;
  final SaleExchangePayment? differencePayment;

  @override
  Map<String, Object?> toRequest() => <String, Object?>{
    'idempotencyKey': idempotencyKey,
    'saleId': saleId,
    'reason': reason.wireValue,
    'returnLines': <Object?>[
      for (final CorrectionLine line in returnLines) line.toRequestLine(),
    ],
    'newLines': <Object?>[
      for (final SaleCartLine line in newItems.lines) line.toRequestLine(),
    ],
    if (differencePayment != null)
      'differencePayment': differencePayment!.toRequest(),
    if (note != null) 'note': note,
  };
}

/// Trims the optional note; blank becomes absent. The server refuses padded,
/// empty or over-long notes, so this is the only accepted normalization.
String? normalizeCorrectionNote(String? note) {
  if (note == null) return null;
  final String trimmed = note.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > correctionNoteMaxLength) {
    throw const CorrectionValidationException(
      'Note is too long.',
      reason: CorrectionValidationReason.noteTooLong,
    );
  }
  return trimmed;
}

class _LineInput {
  const _LineInput(this.lineIndex, this.quantity, this.condition);
  final int lineIndex;
  final String quantity;
  final ReturnCondition? condition;
}

List<CorrectionLine> _returnLines(
  CorrectableSale sale,
  List<ReturnLineInput> lines,
) => _validatedLines(sale, <_LineInput>[
  for (final ReturnLineInput line in lines)
    _LineInput(line.lineIndex, line.quantity, line.condition),
]);

/// Unique known lines, each a canonical positive quantity at the line
/// precision (scaled with BigInt through [SaleCartLine]) that does not exceed
/// the remaining returnable quantity of the looked-up sale. The server
/// re-checks against its ledger.
List<CorrectionLine> _validatedLines(
  CorrectableSale sale,
  List<_LineInput> lines,
) {
  if (lines.isEmpty) {
    throw const CorrectionValidationException(
      'A correction needs at least one line.',
      reason: CorrectionValidationReason.noLines,
    );
  }
  final Set<int> seen = <int>{};
  return List<CorrectionLine>.unmodifiable(<CorrectionLine>[
    for (final _LineInput input in lines) _line(sale, input, seen),
  ]);
}

CorrectionLine _line(CorrectableSale sale, _LineInput input, Set<int> seen) {
  if (input.lineIndex < 0 || input.lineIndex >= sale.lines.length) {
    throw const CorrectionValidationException(
      'The sale has no such line.',
      reason: CorrectionValidationReason.unknownLine,
    );
  }
  if (!seen.add(input.lineIndex)) {
    throw const CorrectionValidationException(
      'A sale line may appear only once.',
      reason: CorrectionValidationReason.duplicateLine,
    );
  }
  final CorrectableSaleLine sold = sale.lines[input.lineIndex];
  final int scaled = scaleCorrectionQuantity(
    input.quantity,
    sold.quantitySpec,
    productId: sold.productId,
  );
  if (scaled > sold.remainingScaled) {
    throw const CorrectionValidationException(
      'Quantity exceeds the remaining returnable quantity.',
      reason: CorrectionValidationReason.exceedsRemaining,
    );
  }
  return CorrectionLine._(
    lineIndex: input.lineIndex,
    productId: sold.productId,
    quantitySpec: sold.quantitySpec,
    quantity: input.quantity,
    quantityScaled: scaled,
    condition: input.condition,
  );
}

/// Scales a canonical decimal at [spec] with the sale cart's BigInt rules,
/// translating its typed reasons into correction reasons.
int scaleCorrectionQuantity(
  String quantity,
  QuantitySpec spec, {
  required String productId,
}) {
  try {
    return SaleCartLine(
      productId: productId,
      name: productId,
      quantitySpec: spec,
      quantity: quantity,
    ).quantityScaled;
  } on SaleValidationException catch (error) {
    throw CorrectionValidationException(
      error.message,
      reason: switch (error.reason) {
        SaleValidationReason.malformedQuantity =>
          CorrectionValidationReason.malformedQuantity,
        SaleValidationReason.tooPrecise =>
          CorrectionValidationReason.tooPrecise,
        SaleValidationReason.notPositive =>
          CorrectionValidationReason.notPositive,
        SaleValidationReason.tooLarge => CorrectionValidationReason.tooLarge,
        _ => CorrectionValidationReason.invalidDraft,
      },
    );
  }
}

void _requireBranch(String branchId) {
  if (!isValidSaleId(branchId)) {
    throw const CorrectionValidationException('Branch ID is invalid.');
  }
}

String _newKey(String Function() createKey) {
  final String key = createKey();
  if (!_uuidV4Pattern.hasMatch(key)) {
    throw const CorrectionValidationException(
      'Correction key must be a lowercase UUID v4.',
    );
  }
  return key;
}

/// A different correction is blocked until the unresolved one is resolved.
class CorrectionUnresolvedException implements Exception {
  const CorrectionUnresolvedException();
}

class CorrectionAttempt {
  const CorrectionAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });
  final String ownerUserId;
  final SaleCorrectionDraft draft;
  final int revision;
}

class _StoredCorrectionDraft {
  const _StoredCorrectionDraft(this.draft, this.revision);
  final SaleCorrectionDraft draft;
  final int revision;
}

/// Volatile, live-shell-only retry storage mirroring `SaleDraftStore`: at
/// most one unresolved correction (of any kind) per exact seller and branch.
/// An uncertain submission retries the same draft (same key, same payload)
/// until it resolves; only the current attempt's revision may resolve it.
class CorrectionDraftStore {
  final Map<String, Map<String, _StoredCorrectionDraft>> _drafts =
      <String, Map<String, _StoredCorrectionDraft>>{};

  // Store-wide and never reset, so an attempt from before a resolution can
  // never match an equal draft begun again afterwards.
  int _lastRevision = 0;

  SaleCorrectionDraft? unresolvedFor(String ownerUserId, String branchId) =>
      _drafts[ownerUserId]?[branchId]?.draft;

  CorrectionAttempt begin({
    required String ownerUserId,
    required SaleCorrectionDraft draft,
  }) {
    if (ownerUserId.isEmpty) throw const SaleSessionException();
    final Map<String, _StoredCorrectionDraft> branchDrafts = _drafts
        .putIfAbsent(ownerUserId, () => <String, _StoredCorrectionDraft>{});
    final _StoredCorrectionDraft? current = branchDrafts[draft.branchId];
    if (current != null && current.draft != draft) {
      throw const CorrectionUnresolvedException();
    }
    final int revision = ++_lastRevision;
    branchDrafts[draft.branchId] = _StoredCorrectionDraft(draft, revision);
    return CorrectionAttempt._(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(CorrectionAttempt attempt) {
    final _StoredCorrectionDraft? current =
        _drafts[attempt.ownerUserId]?[attempt.draft.branchId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  bool resolve(CorrectionAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    final Map<String, _StoredCorrectionDraft> branchDrafts =
        _drafts[attempt.ownerUserId]!;
    branchDrafts.remove(attempt.draft.branchId);
    if (branchDrafts.isEmpty) _drafts.remove(attempt.ownerUserId);
    return true;
  }
}
