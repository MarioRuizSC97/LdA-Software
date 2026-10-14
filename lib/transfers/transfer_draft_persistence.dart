import 'dart:convert';

import '../catalog/catalog_product.dart';
import 'transfer_draft.dart';

/// Only encoding version this build reads or writes.
const int transferJournalVersion = 1;

/// Why the durable transfer journal could not be trusted.
enum TransferJournalFailure {
  /// The storage backend could not be opened, read, or written.
  unavailable,

  /// A stored record exists but does not decode under the strict codec.
  corrupt,
}

/// The durable journal failed; callers must fail closed and never drop or
/// recreate the unresolved record on their own.
class TransferJournalException implements Exception {
  const TransferJournalException(this.failure);

  final TransferJournalFailure failure;

  @override
  String toString() => 'TransferJournalException($failure)';
}

/// The minimal owner-bound record persisted before a transfer leaves the
/// device: the frozen idempotency key plus the exact payload it guards.
class TransferJournalRecord {
  const TransferJournalRecord({required this.ownerUserId, required this.draft});

  final String ownerUserId;
  final TransferDraft draft;

  String get idempotencyKey => draft.idempotencyKey;

  @override
  bool operator ==(Object other) =>
      other is TransferJournalRecord &&
      other.ownerUserId == ownerUserId &&
      other.draft == draft;

  @override
  int get hashCode => Object.hash(ownerUserId, draft);
}

/// Durable port for the unresolved transfer journal.
///
/// Holds at most one record per owner. Every adapter must be transactional:
/// * [load] answers the owner's record, null when none exists, and throws
///   [TransferJournalException] when the storage is unavailable or the stored
///   bytes are corrupt.
/// * [save] stores the record only when the owner has no record or the very
///   same encoded record; a different stored record throws
///   [TransferUnresolvedException] and is left untouched.
/// * [clear] deletes the owner's record only when its stored key equals
///   [idempotencyKey], answering whether anything was deleted.
abstract interface class TransferDraftJournal {
  Future<TransferJournalRecord?> load(String ownerUserId);

  Future<void> save(TransferJournalRecord record);

  Future<bool> clear(String ownerUserId, String idempotencyKey);
}

const Set<String> _recordFields = <String>{
  'version',
  'ownerUserId',
  'idempotencyKey',
  'sourceBranchId',
  'destinationBranchId',
  'lines',
};

const Set<String> _lineFields = <String>{
  'productId',
  'quantity',
  'unit',
  'precision',
};

/// Strict, deterministic codec for [TransferJournalRecord].
///
/// Encoding is stable for equal records, so adapters may compare encoded
/// strings. Decoding rejects unknown or missing fields, wrong types, other
/// versions, and any payload the server contract would refuse.
abstract final class TransferJournalCodec {
  static String encode(TransferJournalRecord record) {
    if (record.ownerUserId.isEmpty) throw const TransferSessionException();
    final TransferDraft draft = record.draft;
    draft.validate();
    return jsonEncode(<String, Object?>{
      'version': transferJournalVersion,
      'ownerUserId': record.ownerUserId,
      'idempotencyKey': draft.idempotencyKey,
      'sourceBranchId': draft.sourceBranchId,
      'destinationBranchId': draft.destinationBranchId,
      'lines': <Map<String, Object?>>[
        for (final TransferLine line in draft.lines)
          <String, Object?>{
            'productId': line.productId,
            'quantity': line.quantity,
            'unit': line.quantitySpec.unit,
            'precision': line.quantitySpec.precision,
          },
      ],
    });
  }

  /// Decodes [encoded]; any deviation throws a corrupt
  /// [TransferJournalException].
  static TransferJournalRecord decode(String encoded) {
    try {
      return _decode(jsonDecode(encoded));
    } on TransferJournalException {
      rethrow;
    } catch (_) {
      throw const TransferJournalException(TransferJournalFailure.corrupt);
    }
  }

  static TransferJournalRecord _decode(Object? value) {
    if (!_isExact(value, _recordFields)) _corrupt();
    final Map<Object?, Object?> root = value! as Map<Object?, Object?>;
    final Object? version = root['version'];
    final Object? owner = root['ownerUserId'];
    final Object? key = root['idempotencyKey'];
    final Object? source = root['sourceBranchId'];
    final Object? destination = root['destinationBranchId'];
    final Object? rawLines = root['lines'];
    if (version is! int ||
        version != transferJournalVersion ||
        owner is! String ||
        owner.isEmpty ||
        key is! String ||
        source is! String ||
        destination is! String ||
        rawLines is! List) {
      _corrupt();
    }
    final List<TransferLine> lines = <TransferLine>[
      for (final Object? rawLine in rawLines) _decodeLine(rawLine),
    ];
    final TransferDraft draft = TransferDraft(
      idempotencyKey: key,
      sourceBranchId: source,
      destinationBranchId: destination,
      lines: lines,
    );
    draft.validate();
    return TransferJournalRecord(ownerUserId: owner, draft: draft);
  }

  static TransferLine _decodeLine(Object? value) {
    if (!_isExact(value, _lineFields)) _corrupt();
    final Map<Object?, Object?> line = value! as Map<Object?, Object?>;
    final Object? productId = line['productId'];
    final Object? quantity = line['quantity'];
    final Object? unit = line['unit'];
    final Object? precision = line['precision'];
    if (productId is! String ||
        quantity is! String ||
        unit is! String ||
        precision is! int) {
      _corrupt();
    }
    return TransferLine(
      productId: productId,
      quantity: quantity,
      quantitySpec: QuantitySpec(unit: unit, precision: precision),
    );
  }

  static bool _isExact(Object? value, Set<String> fields) =>
      value is Map &&
      value.length == fields.length &&
      value.keys.every((Object? key) => key is String && fields.contains(key));

  static Never _corrupt() =>
      throw const TransferJournalException(TransferJournalFailure.corrupt);
}

/// In-memory journal for tests and platforms without durable storage.
///
/// It stores encoded strings, so it exercises the same strict codec and
/// conflict rules as the durable adapters. [failNextWith] and [unavailable]
/// let tests drive the fail-closed paths.
class InMemoryTransferDraftJournal implements TransferDraftJournal {
  final Map<String, String> _records = <String, String>{};

  /// When true every operation throws an unavailable journal failure.
  bool unavailable = false;

  int saves = 0;
  int clears = 0;

  /// Raw stored text per owner, for tests that inspect or corrupt it.
  Map<String, String> get rawRecords => _records;

  void _guard() {
    if (unavailable) {
      throw const TransferJournalException(TransferJournalFailure.unavailable);
    }
  }

  @override
  Future<TransferJournalRecord?> load(String ownerUserId) async {
    _guard();
    final String? encoded = _records[ownerUserId];
    if (encoded == null) return null;
    final TransferJournalRecord record = TransferJournalCodec.decode(encoded);
    if (record.ownerUserId != ownerUserId) {
      throw const TransferJournalException(TransferJournalFailure.corrupt);
    }
    return record;
  }

  @override
  Future<void> save(TransferJournalRecord record) async {
    _guard();
    final String encoded = TransferJournalCodec.encode(record);
    final String? current = _records[record.ownerUserId];
    if (current != null && current != encoded) {
      TransferJournalCodec.decode(current);
      throw const TransferUnresolvedException();
    }
    _records[record.ownerUserId] = encoded;
    saves += 1;
  }

  @override
  Future<bool> clear(String ownerUserId, String idempotencyKey) async {
    _guard();
    final String? encoded = _records[ownerUserId];
    if (encoded == null) return false;
    final TransferJournalRecord record = TransferJournalCodec.decode(encoded);
    if (record.idempotencyKey != idempotencyKey) return false;
    _records.remove(ownerUserId);
    clears += 1;
    return true;
  }
}
