import 'dart:math';

import '../catalog/catalog_product.dart';
import 'transfer_draft_persistence.dart';

/// Exact server contract for administrator inventory transfers.
///
/// The `transferInventory` callable accepts exactly `{idempotencyKey,
/// sourceBranchId, destinationBranchId, lines}` where every line is exactly
/// `{productId, quantity}`, and answers `transferId`, `sourceBranchId`,
/// `destinationBranchId`, `occurredAt`, `lines` plus `replayed`. Field names
/// here are copied from `functions/src/transfers.js`; nothing is renamed,
/// defaulted, or tolerated.
///
/// Stock is authoritative at the server at execution time: this contract never
/// receives a cached balance and never rejects a transfer because a locally
/// cached projection looked too small.
const int maxSafeTransferScaled = 9007199254740991;

/// Maximum number of distinct product lines the server accepts per transfer.
const int transferLineLimit = 50;

/// Maximum idempotency-key length the server accepts.
///
/// `transfers.js` derives `transfer-{key}-{index}-out` document ids for the
/// ledger legs and caps the key so the longest leg (index 49) still fits
/// Firestore's 128-character document id.
const int maxTransferIdempotencyKeyLength = 112;

const int _maxQuantityInputLength = 18;
const int _maxDecimalPrecision = 6;

final BigInt _maxSafeBigInt = BigInt.from(maxSafeTransferScaled);

final RegExp _keyPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$');
final RegExp _branchPattern = RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$');
final RegExp _productPattern = RegExp(r'^[A-Z][A-Z0-9-]{7,63}$');
final RegExp _quantityPattern = RegExp(r'^(?:0|[1-9]\d*)(?:\.\d+)?$');
final RegExp _unitPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

/// Which part of the transfer contract a [TransferValidationException] broke.
///
/// Presentation owns the wording; callers branch on these exact reasons instead
/// of parsing English server or developer text.
enum TransferValidationReason {
  idempotencyKey,
  branch,
  branchPair,
  lines,
  duplicateProduct,
  product,
  specification,
  quantity,
  quantityRange,
}

/// A request field the server would refuse with `invalid-argument`.
class TransferValidationException implements Exception {
  const TransferValidationException(this.message, {required this.reason});

  final String message;
  final TransferValidationReason reason;

  @override
  String toString() => 'TransferValidationException($reason): $message';
}

/// The callable answered with a shape the server does not produce.
class TransferProtocolException implements Exception {
  const TransferProtocolException();
}

/// The caller is not the exact branch-less administrator the draft was built for.
class TransferSessionException implements Exception {
  const TransferSessionException();
}

/// The stable key already holds a different unresolved payload.
class TransferUnresolvedException implements Exception {
  const TransferUnresolvedException();
}

/// One validated product line: an identifier, a canonical decimal string, and
/// the product's immutable quantity specification.
///
/// Like the server, the quantity is kept as the exact string that was entered
/// and scaled with BigInt only, so no value is ever rounded or truncated by
/// binary floating point.
class TransferLine {
  const TransferLine({
    required this.productId,
    required this.quantity,
    required this.quantitySpec,
  });

  final String productId;
  final String quantity;
  final QuantitySpec quantitySpec;

  /// Exact quantity scaled by `10^precision` as a safe integer.
  int get quantityScaled {
    final BigInt scaled = _scaledQuantity();
    return scaled.toInt();
  }

  /// Fails closed unless the identifier, specification, and quantity are all
  /// acceptable to the server.
  void validate() {
    if (!_productPattern.hasMatch(productId)) {
      throw const TransferValidationException(
        'Product ID must match ^[A-Z][A-Z0-9-]{7,63}\$.',
        reason: TransferValidationReason.product,
      );
    }
    if (!_unitPattern.hasMatch(quantitySpec.unit) ||
        quantitySpec.precision < 0 ||
        quantitySpec.precision > _maxDecimalPrecision) {
      throw const TransferValidationException(
        'Quantity specification must use a lowercase unit and a precision '
        'from 0 through 6.',
        reason: TransferValidationReason.specification,
      );
    }
    _scaledQuantity();
  }

  /// The exact two-field server line, sent verbatim.
  Map<String, Object?> toRequestLine() => <String, Object?>{
    'productId': productId,
    'quantity': quantity,
  };

  BigInt _scaledQuantity() {
    if (quantity.length > _maxQuantityInputLength ||
        !_quantityPattern.hasMatch(quantity) ||
        !quantity.contains(RegExp(r'[1-9]'))) {
      throw const TransferValidationException(
        'Quantity must be a canonical positive decimal string of at most 18 '
        'characters without sign, whitespace, commas, or exponents.',
        reason: TransferValidationReason.quantity,
      );
    }
    final List<String> parts = quantity.split('.');
    final String fraction = parts.length == 1 ? '' : parts[1];
    if (fraction.length > quantitySpec.precision) {
      throw TransferValidationException(
        'Quantity exceeds the product precision of '
        '${quantitySpec.precision} decimal places; excess digits are '
        'rejected even when they are zeros.',
        reason: TransferValidationReason.quantity,
      );
    }
    final BigInt scale = BigInt.from(10).pow(quantitySpec.precision);
    final String paddedFraction = fraction.isEmpty
        ? '0'
        : fraction.padRight(quantitySpec.precision, '0');
    final BigInt scaled =
        BigInt.parse(parts[0]) * scale + BigInt.parse(paddedFraction);
    if (scaled <= BigInt.zero) {
      throw const TransferValidationException(
        'Quantity must be strictly greater than zero.',
        reason: TransferValidationReason.quantity,
      );
    }
    if (scaled > _maxSafeBigInt) {
      throw const TransferValidationException(
        'Quantity exceeds safe integer bounds.',
        reason: TransferValidationReason.quantityRange,
      );
    }
    return scaled;
  }

  @override
  bool operator ==(Object other) =>
      other is TransferLine &&
      other.productId == productId &&
      other.quantity == quantity &&
      other.quantitySpec.unit == quantitySpec.unit &&
      other.quantitySpec.precision == quantitySpec.precision;

  @override
  int get hashCode => Object.hash(
    productId,
    quantity,
    quantitySpec.unit,
    quantitySpec.precision,
  );
}

/// Immutable, fully validated transfer request.
///
/// The caller's line list is copied at construction and every request map is
/// rebuilt on demand, so no later mutation of a caller-owned list or map can
/// change the payload that was frozen into [TransferDraftStore].
class TransferDraft {
  TransferDraft({
    required this.idempotencyKey,
    required this.sourceBranchId,
    required this.destinationBranchId,
    required List<TransferLine> lines,
  }) : _lines = List<TransferLine>.unmodifiable(lines);

  final String idempotencyKey;
  final String sourceBranchId;
  final String destinationBranchId;
  final List<TransferLine> _lines;

  /// Defensive, unmodifiable view of the frozen lines.
  List<TransferLine> get lines => _lines;

  /// Fails closed unless every request field is acceptable to the server.
  void validate() {
    if (!_keyPattern.hasMatch(idempotencyKey) ||
        idempotencyKey.length > maxTransferIdempotencyKeyLength) {
      throw const TransferValidationException(
        'Idempotency key must be 1 to 112 characters, starting with an '
        'alphanumeric character and using only - or _ internally.',
        reason: TransferValidationReason.idempotencyKey,
      );
    }
    _validateBranch(sourceBranchId);
    _validateBranch(destinationBranchId);
    if (sourceBranchId == destinationBranchId) {
      throw const TransferValidationException(
        'Source and destination branch must be distinct.',
        reason: TransferValidationReason.branchPair,
      );
    }
    if (_lines.isEmpty || _lines.length > transferLineLimit) {
      throw TransferValidationException(
        'A transfer must carry between 1 and $transferLineLimit product '
        'lines.',
        reason: TransferValidationReason.lines,
      );
    }

    final Set<String> seen = <String>{};
    for (final TransferLine line in _lines) {
      line.validate();
      if (!seen.add(line.productId)) {
        throw TransferValidationException(
          'Product ${line.productId} appears more than once; each product '
          'may appear only once per transfer.',
          reason: TransferValidationReason.duplicateProduct,
        );
      }
    }
  }

  /// The exact four-field server request, rebuilt fresh on every call.
  Map<String, Object?> toRequest() {
    validate();
    return <String, Object?>{
      'idempotencyKey': idempotencyKey,
      'sourceBranchId': sourceBranchId,
      'destinationBranchId': destinationBranchId,
      'lines': _lines.map((TransferLine line) => line.toRequestLine()).toList(),
    };
  }

  void _validateBranch(String branchId) {
    if (branchId.length > 128 || !_branchPattern.hasMatch(branchId)) {
      throw const TransferValidationException(
        'Branch ID must match ^branch-[a-z0-9]+(-[a-z0-9]+)*\$.',
        reason: TransferValidationReason.branch,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TransferDraft &&
      other.idempotencyKey == idempotencyKey &&
      other.sourceBranchId == sourceBranchId &&
      other.destinationBranchId == destinationBranchId &&
      other._lines.length == _lines.length &&
      _sameLines(other._lines);

  bool _sameLines(List<TransferLine> other) {
    for (int index = 0; index < _lines.length; index += 1) {
      if (_lines[index] != other[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    idempotencyKey,
    sourceBranchId,
    destinationBranchId,
    Object.hashAll(_lines),
  );
}

/// One parsed result line: the transferred quantity plus the projections the
/// server wrote for both branches.
class TransferResultLine {
  const TransferResultLine({
    required this.productId,
    required this.quantity,
    required this.quantityScaled,
    required this.unit,
    required this.precision,
    required this.sourceQuantityScaled,
    required this.destinationQuantityScaled,
  });

  final String productId;
  final String quantity;
  final int quantityScaled;
  final String unit;
  final int precision;

  /// Remaining source stock after the outbound leg.
  final int sourceQuantityScaled;

  /// Destination stock after the inbound leg.
  final int destinationQuantityScaled;

  @override
  bool operator ==(Object other) =>
      other is TransferResultLine &&
      other.productId == productId &&
      other.quantity == quantity &&
      other.quantityScaled == quantityScaled &&
      other.unit == unit &&
      other.precision == precision &&
      other.sourceQuantityScaled == sourceQuantityScaled &&
      other.destinationQuantityScaled == destinationQuantityScaled;

  @override
  int get hashCode => Object.hash(
    productId,
    quantity,
    quantityScaled,
    unit,
    precision,
    sourceQuantityScaled,
    destinationQuantityScaled,
  );
}

/// Immutable success value parsed from the callable result.
///
/// Requires the exact six root fields and, per line, the exact seven server
/// fields. Every returned value is re-derived against the frozen request:
/// identity, line count, product order, verbatim quantity strings, scaled
/// quantity, unit and precision. A response that does not match is a protocol
/// failure, never a success with a guessed field.
class TransferResult {
  const TransferResult._({
    required this.transferId,
    required this.sourceBranchId,
    required this.destinationBranchId,
    required this.occurredAt,
    required this.lines,
    required this.replayed,
  });

  factory TransferResult.fromCallable(
    Object? value, {
    required TransferDraft request,
  }) {
    const Set<String> resultKeys = <String>{
      'transferId',
      'sourceBranchId',
      'destinationBranchId',
      'occurredAt',
      'lines',
      'replayed',
    };
    if (!_isExactMap(value, resultKeys)) {
      throw const TransferProtocolException();
    }
    final Map<Object?, Object?> root = value! as Map<Object?, Object?>;

    final Object? transferId = root['transferId'];
    final Object? sourceBranchId = root['sourceBranchId'];
    final Object? destinationBranchId = root['destinationBranchId'];
    final Object? occurredAt = root['occurredAt'];
    final Object? replayed = root['replayed'];
    if (transferId != request.idempotencyKey ||
        sourceBranchId != request.sourceBranchId ||
        destinationBranchId != request.destinationBranchId ||
        !_isSafeNonNegative(occurredAt) ||
        replayed is! bool) {
      throw const TransferProtocolException();
    }

    final Object? rawLines = root['lines'];
    if (rawLines is! List || rawLines.length != request.lines.length) {
      throw const TransferProtocolException();
    }
    const Set<String> lineKeys = <String>{
      'productId',
      'quantity',
      'quantityScaled',
      'unit',
      'precision',
      'sourceQuantityScaled',
      'destinationQuantityScaled',
    };
    final List<TransferResultLine> lines = <TransferResultLine>[];
    for (int index = 0; index < rawLines.length; index += 1) {
      lines.add(
        _parseLine(rawLines[index], lineKeys, request: request.lines[index]),
      );
    }

    return TransferResult._(
      transferId: transferId! as String,
      sourceBranchId: sourceBranchId! as String,
      destinationBranchId: destinationBranchId! as String,
      occurredAt: occurredAt! as int,
      lines: List<TransferResultLine>.unmodifiable(lines),
      replayed: replayed,
    );
  }

  final String transferId;
  final String sourceBranchId;
  final String destinationBranchId;

  /// Server execution instant in epoch milliseconds, never a client guess.
  final int occurredAt;

  final List<TransferResultLine> lines;

  /// True when the server answered from the stored receipt instead of moving
  /// stock again; the legs were written exactly once either way.
  final bool replayed;
}

TransferResultLine _parseLine(
  Object? value,
  Set<String> expected, {
  required TransferLine request,
}) {
  if (!_isExactMap(value, expected)) throw const TransferProtocolException();
  final Map<Object?, Object?> line = value! as Map<Object?, Object?>;

  final Object? productId = line['productId'];
  final Object? quantity = line['quantity'];
  final Object? unit = line['unit'];
  final Object? precision = line['precision'];
  if (productId != request.productId ||
      quantity != request.quantity ||
      unit != request.quantitySpec.unit ||
      precision != request.quantitySpec.precision) {
    throw const TransferProtocolException();
  }

  final Object? quantityScaled = line['quantityScaled'];
  final Object? sourceQuantityScaled = line['sourceQuantityScaled'];
  final Object? destinationQuantityScaled = line['destinationQuantityScaled'];
  if (!_isSafePositive(quantityScaled) ||
      !_isSafeNonNegative(sourceQuantityScaled) ||
      !_isSafeNonNegative(destinationQuantityScaled)) {
    throw const TransferProtocolException();
  }
  final int scaled = quantityScaled! as int;
  final int source = sourceQuantityScaled! as int;
  final int destination = destinationQuantityScaled! as int;
  // The server echoes the request's own quantity and specification; a mismatch
  // means this answer did not come from the transfer that was sent.
  if (scaled != request.quantityScaled || destination < scaled) {
    throw const TransferProtocolException();
  }

  return TransferResultLine(
    productId: productId! as String,
    quantity: quantity! as String,
    quantityScaled: scaled,
    unit: unit! as String,
    precision: precision! as int,
    sourceQuantityScaled: source,
    destinationQuantityScaled: destination,
  );
}

bool _isExactMap(Object? value, Set<String> expected) =>
    value is Map &&
    value.length == expected.length &&
    expected.every(value.containsKey);

bool _isSafeNonNegative(Object? value) =>
    value is int && value >= 0 && value <= maxSafeTransferScaled;

bool _isSafePositive(Object? value) =>
    value is int && value > 0 && value <= maxSafeTransferScaled;

class TransferAttempt {
  const TransferAttempt._({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });

  final String ownerUserId;
  final TransferDraft draft;
  final int revision;

  /// The stable retry key: the same key can only ever move this payload once.
  String get idempotencyKey => draft.idempotencyKey;
}

class _StoredTransferDraft {
  const _StoredTransferDraft(this.draft, this.revision);
  final TransferDraft draft;
  final int revision;
}

/// Whether an owner's durable unresolved-transfer journal can be trusted.
enum TransferJournalStatus {
  /// Not read yet for this owner; nothing may be offered or minted.
  unknown,

  /// The journal is being read.
  loading,

  /// The journal was read and the in-memory view matches it.
  ready,

  /// Storage could not be opened, read, or written: fail closed.
  unavailable,

  /// A stored record is unreadable: fail closed and never drop it.
  corrupt,
}

/// Owner-bound store of the single unresolved transfer per administrator,
/// backed by a durable [TransferDraftJournal].
///
/// Lifecycle a caller must follow:
/// * [hydrate] reads the owner's durable record before any form is shown or
///   any key is minted. It never calls the server.
/// * [begin] persists the frozen payload before answering the attempt, so the
///   caller only sends after the key survives a reload or an app restart. A
///   storage failure throws [TransferJournalException] and nothing is sent.
/// * A confirmed success or a deterministic [TransferRejectedException] means
///   the server settled the key, so the caller resolves the attempt; only the
///   current attempt clears the durable record, conditionally on its key.
/// * A transport failure, an unavailable function, a malformed response, or a
///   session change after the request was sent leaves the outcome unknown, so
///   the caller retains the attempt. The key must never be discarded, because
///   the server may already have moved the stock and only the same key plus
///   the same payload can turn that into a replay instead of a second
///   transfer.
///
/// At most one unresolved record exists per owner: a `begin` with a different
/// key or payload throws [TransferUnresolvedException] instead of replacing
/// it. Unavailable or corrupt storage blocks the owner instead of silently
/// dropping or recreating the record, and records never expire.
class TransferDraftStore {
  TransferDraftStore({TransferDraftJournal? journal})
    : journal = journal ?? InMemoryTransferDraftJournal();

  /// Durable backing port; in-memory only on unsupported platforms and tests.
  final TransferDraftJournal journal;

  final Map<String, _StoredTransferDraft> _drafts =
      <String, _StoredTransferDraft>{};
  final Map<String, TransferJournalStatus> _status =
      <String, TransferJournalStatus>{};
  final Map<String, Future<TransferJournalStatus>> _hydrations =
      <String, Future<TransferJournalStatus>>{};

  // Journal operations run one at a time, so a begin and a resolve can never
  // interleave their read-check-write steps.
  Future<void> _tail = Future<void>.value();

  /// Current journal status for [ownerUserId].
  TransferJournalStatus statusFor(String ownerUserId) =>
      _status[ownerUserId] ?? TransferJournalStatus.unknown;

  /// The frozen unresolved payload for this exact owner and key, if any.
  TransferDraft? unresolvedFor(String ownerUserId, String idempotencyKey) {
    final _StoredTransferDraft? stored = _drafts[ownerUserId];
    return stored?.draft.idempotencyKey == idempotencyKey
        ? stored!.draft
        : null;
  }

  /// Unmodifiable snapshot of this owner's unresolved payload, if any.
  List<TransferDraft> unresolvedByOwner(String ownerUserId) {
    final _StoredTransferDraft? stored = _drafts[ownerUserId];
    if (stored == null) return const <TransferDraft>[];
    return List<TransferDraft>.unmodifiable(<TransferDraft>[stored.draft]);
  }

  /// Reads [ownerUserId]'s durable record once; a failed read may be retried.
  Future<TransferJournalStatus> hydrate(String ownerUserId) {
    if (ownerUserId.isEmpty) throw const TransferSessionException();
    if (statusFor(ownerUserId) == TransferJournalStatus.ready) {
      return Future<TransferJournalStatus>.value(TransferJournalStatus.ready);
    }
    final Future<TransferJournalStatus>? running = _hydrations[ownerUserId];
    if (running != null) return running;
    _status[ownerUserId] = TransferJournalStatus.loading;
    // The callback must not return the removed future: whenComplete would
    // await it and the hydration would wait on itself.
    final Future<TransferJournalStatus> hydration =
        _serial(() => _load(ownerUserId)).whenComplete(() {
          _hydrations.remove(ownerUserId);
        });
    _hydrations[ownerUserId] = hydration;
    return hydration;
  }

  Future<TransferJournalStatus> _load(String ownerUserId) async {
    try {
      final TransferJournalRecord? record = await journal.load(ownerUserId);
      final _StoredTransferDraft? memory = _drafts[ownerUserId];
      if (record != null && record.ownerUserId != ownerUserId) {
        throw const TransferJournalException(TransferJournalFailure.corrupt);
      }
      // The in-memory view is only ever written after a durable save, so any
      // divergence means the journal can no longer be trusted.
      if (memory != null && memory.draft != record?.draft) {
        throw const TransferJournalException(TransferJournalFailure.corrupt);
      }
      if (record != null && memory == null) {
        _drafts[ownerUserId] = _StoredTransferDraft(record.draft, 0);
      }
      return _status[ownerUserId] = TransferJournalStatus.ready;
    } catch (error) {
      return _status[ownerUserId] = _statusForFailure(error);
    }
  }

  /// Freezes and durably saves [draft] for [ownerUserId] before answering.
  Future<TransferAttempt> begin({
    required String ownerUserId,
    required TransferDraft draft,
  }) async {
    if (ownerUserId.isEmpty) throw const TransferSessionException();
    draft.validate();
    final TransferJournalStatus status = await hydrate(ownerUserId);
    if (status != TransferJournalStatus.ready) throw _exceptionFor(status);

    return _serial(() async {
      _requireReady(ownerUserId);
      final _StoredTransferDraft? current = _drafts[ownerUserId];
      if (current != null && current.draft != draft) {
        throw const TransferUnresolvedException();
      }
      try {
        await journal.save(
          TransferJournalRecord(ownerUserId: ownerUserId, draft: draft),
        );
      } on TransferUnresolvedException {
        // The journal holds a record the in-memory view never saw.
        _status[ownerUserId] = TransferJournalStatus.corrupt;
        throw const TransferJournalException(TransferJournalFailure.corrupt);
      } catch (error) {
        throw _exceptionFor(_status[ownerUserId] = _statusForFailure(error));
      }
      final int revision = (current?.revision ?? 0) + 1;
      _drafts[ownerUserId] = _StoredTransferDraft(draft, revision);
      return TransferAttempt._(
        ownerUserId: ownerUserId,
        draft: draft,
        revision: revision,
      );
    });
  }

  bool isCurrent(TransferAttempt attempt) {
    final _StoredTransferDraft? stored = _drafts[attempt.ownerUserId];
    return stored != null &&
        stored.revision == attempt.revision &&
        stored.draft == attempt.draft;
  }

  /// Drops the payload once the server settled the key, clearing the durable
  /// record only when it still holds this attempt's key. Stale attempts cannot
  /// discard the current unresolved payload. A failed clear keeps everything
  /// and throws [TransferJournalException].
  Future<bool> resolve(TransferAttempt attempt) => _serial(() async {
    if (!isCurrent(attempt)) return false;
    try {
      await journal.clear(attempt.ownerUserId, attempt.idempotencyKey);
    } catch (error) {
      throw _exceptionFor(
        _status[attempt.ownerUserId] = _statusForFailure(error),
      );
    }
    _drafts.remove(attempt.ownerUserId);
    return true;
  });

  /// Keeps the unresolved payload for a retry with the same key.
  void retain(TransferAttempt attempt) {
    // begin() already froze and durably saved the payload; nothing here may
    // replace, expire, or forget it.
  }

  void _requireReady(String ownerUserId) {
    final TransferJournalStatus status = statusFor(ownerUserId);
    if (status != TransferJournalStatus.ready) throw _exceptionFor(status);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

TransferJournalStatus _statusForFailure(Object error) =>
    error is TransferJournalException &&
        error.failure == TransferJournalFailure.corrupt
    ? TransferJournalStatus.corrupt
    : TransferJournalStatus.unavailable;

TransferJournalException _exceptionFor(TransferJournalStatus status) =>
    TransferJournalException(
      status == TransferJournalStatus.corrupt
          ? TransferJournalFailure.corrupt
          : TransferJournalFailure.unavailable,
    );

/// Canonical UUID v4 for a fresh, stable transfer idempotency key.
String createTransferUuidV4() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex = bytes
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
