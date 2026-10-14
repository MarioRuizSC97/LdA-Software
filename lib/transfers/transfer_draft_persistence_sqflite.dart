import 'dart:io' show Platform;

import 'package:sqflite/sqflite.dart';

import 'transfer_draft.dart';
import 'transfer_draft_persistence.dart';

const String _databaseName = 'transfer_journal.db';
const String _table = 'unresolved_transfers';
const String _ownerColumn = 'owner_user_id';
const String _keyColumn = 'idempotency_key';
const String _payloadColumn = 'payload';

/// Durable journal for Android and iOS; the in-memory journal elsewhere.
TransferDraftJournal createPlatformTransferDraftJournal() =>
    Platform.isAndroid || Platform.isIOS
    ? SqfliteTransferDraftJournal.platform()
    : InMemoryTransferDraftJournal();

/// Creates the journal table; one row per owner.
Future<void> createTransferJournalSchema(Database db, int version) =>
    db.execute(
      'CREATE TABLE $_table ('
      '$_ownerColumn TEXT PRIMARY KEY NOT NULL, '
      '$_keyColumn TEXT NOT NULL, '
      '$_payloadColumn TEXT NOT NULL)',
    );

/// SQLite adapter for [TransferDraftJournal].
///
/// Every operation runs inside one transaction and fails closed: any storage
/// error becomes an unavailable [TransferJournalException], and any row that
/// does not decode under the strict codec, or whose columns disagree with its
/// payload, becomes a corrupt one and is left untouched.
class SqfliteTransferDraftJournal implements TransferDraftJournal {
  SqfliteTransferDraftJournal({required this._open});

  /// Opens the app-private database file through the sqflite plugin.
  factory SqfliteTransferDraftJournal.platform() => SqfliteTransferDraftJournal(
    open: () async => openDatabase(
      '${await getDatabasesPath()}/$_databaseName',
      version: 1,
      onCreate: createTransferJournalSchema,
    ),
  );

  final Future<Database> Function() _open;
  Future<Database>? _database;

  Future<Database> _db() {
    final Future<Database> opening = _database ??= _open();
    // A failed open is retried on the next operation instead of being cached.
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_database, opening)) _database = null;
      },
    );
    return opening;
  }

  @override
  Future<TransferJournalRecord?> load(String ownerUserId) => _guard(() async {
    final Database db = await _db();
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? row = await _row(txn, ownerUserId);
      return row == null ? null : _decodeRow(row, ownerUserId);
    });
  });

  @override
  Future<void> save(TransferJournalRecord record) => _guard(() async {
    final String encoded = TransferJournalCodec.encode(record);
    final Database db = await _db();
    await db.transaction((Transaction txn) async {
      final Map<String, Object?>? row = await _row(txn, record.ownerUserId);
      if (row != null) {
        _decodeRow(row, record.ownerUserId);
        if (row[_payloadColumn] != encoded) {
          throw const TransferUnresolvedException();
        }
        return;
      }
      await txn.insert(_table, <String, Object?>{
        _ownerColumn: record.ownerUserId,
        _keyColumn: record.idempotencyKey,
        _payloadColumn: encoded,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    });
  });

  @override
  Future<bool> clear(String ownerUserId, String idempotencyKey) =>
      _guard(() async {
        final Database db = await _db();
        return db.transaction((Transaction txn) async {
          final Map<String, Object?>? row = await _row(txn, ownerUserId);
          if (row == null) return false;
          final TransferJournalRecord stored = _decodeRow(row, ownerUserId);
          if (stored.idempotencyKey != idempotencyKey) return false;
          final int deleted = await txn.delete(
            _table,
            where: '$_ownerColumn = ? AND $_keyColumn = ?',
            whereArgs: <Object?>[ownerUserId, idempotencyKey],
          );
          return deleted == 1;
        });
      });

  Future<Map<String, Object?>?> _row(Transaction txn, String owner) async {
    final List<Map<String, Object?>> rows = await txn.query(
      _table,
      columns: <String>[_ownerColumn, _keyColumn, _payloadColumn],
      where: '$_ownerColumn = ?',
      whereArgs: <Object?>[owner],
    );
    return rows.isEmpty ? null : rows.single;
  }

  TransferJournalRecord _decodeRow(Map<String, Object?> row, String owner) {
    final Object? payload = row[_payloadColumn];
    if (payload is! String) _corrupt();
    final TransferJournalRecord record = TransferJournalCodec.decode(payload);
    if (record.ownerUserId != owner ||
        row[_ownerColumn] != owner ||
        row[_keyColumn] != record.idempotencyKey) {
      _corrupt();
    }
    return record;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on TransferJournalException {
      rethrow;
    } on TransferUnresolvedException {
      rethrow;
    } on TransferSessionException {
      rethrow;
    } on TransferValidationException {
      rethrow;
    } catch (_) {
      throw const TransferJournalException(TransferJournalFailure.unavailable);
    }
  }
}

Never _corrupt() =>
    throw const TransferJournalException(TransferJournalFailure.corrupt);
