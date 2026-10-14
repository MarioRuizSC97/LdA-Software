import 'dart:async';
import 'dart:js_interop';

import 'transfer_draft.dart';
import 'transfer_draft_persistence.dart';

const String _databaseName = 'lda_transfer_journal';
const int _databaseVersion = 1;
const String _storeName = 'unresolvedTransfers';

/// Durable IndexedDB journal for the web build.
TransferDraftJournal createPlatformTransferDraftJournal() =>
    IndexedDbTransferDraftJournal();

@JS('indexedDB')
external _IdbFactory? get _indexedDB;

extension type _IdbFactory(JSObject _) implements JSObject {
  external _IdbOpenRequest open(String name, int version);
}

extension type _IdbRequest(JSObject _) implements JSObject {
  external JSAny? get result;
  external set onsuccess(JSFunction? handler);
  external set onerror(JSFunction? handler);
}

extension type _IdbOpenRequest(JSObject _) implements _IdbRequest {
  external set onupgradeneeded(JSFunction? handler);
  external set onblocked(JSFunction? handler);
}

extension type _IdbDatabase(JSObject _) implements JSObject {
  external _IdbStringList get objectStoreNames;
  external JSObject createObjectStore(String name);
  external _IdbTransaction transaction(String storeName, String mode);
  external set onversionchange(JSFunction? handler);
  external void close();
}

extension type _IdbStringList(JSObject _) implements JSObject {
  external bool contains(String name);
}

extension type _IdbTransaction(JSObject _) implements JSObject {
  external _IdbObjectStore objectStore(String name);
  external set oncomplete(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external set onabort(JSFunction? handler);
  external void abort();
}

extension type _IdbObjectStore(JSObject _) implements JSObject {
  external _IdbRequest get(JSString key);
  external _IdbRequest put(JSString value, JSString key);
  external _IdbRequest delete(JSString key);
}

/// IndexedDB adapter for [TransferDraftJournal].
///
/// Each operation runs in a single IndexedDB transaction keyed by owner uid
/// and resolves only on the transaction's `complete` event, so a write is
/// reported only once the browser committed it. A failed open, request, abort,
/// or missing IndexedDB becomes an unavailable [TransferJournalException]; a
/// stored value that does not decode under the strict codec becomes a corrupt
/// one and the transaction is aborted without touching it.
class IndexedDbTransferDraftJournal implements TransferDraftJournal {
  Future<_IdbDatabase>? _database;

  Future<_IdbDatabase> _db() {
    final Future<_IdbDatabase> opening = _database ??= _open();
    // A failed open is retried on the next operation instead of being cached.
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_database, opening)) _database = null;
      },
    );
    return opening;
  }

  Future<_IdbDatabase> _open() {
    final _IdbFactory? factory = _indexedDB;
    if (factory == null) return Future<_IdbDatabase>.error(_unavailable);
    final Completer<_IdbDatabase> opened = Completer<_IdbDatabase>();
    final _IdbOpenRequest request = factory.open(
      _databaseName,
      _databaseVersion,
    );
    request.onupgradeneeded = ((JSObject _) {
      final _IdbDatabase db = request.result! as _IdbDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    request.onsuccess = ((JSObject _) {
      final _IdbDatabase db = request.result! as _IdbDatabase;
      // Another tab upgrading the schema closes this handle; reopen lazily.
      db.onversionchange = ((JSObject _) {
        db.close();
        _database = null;
      }).toJS;
      if (!opened.isCompleted) opened.complete(db);
    }).toJS;
    request.onerror = ((JSObject _) {
      if (!opened.isCompleted) opened.completeError(_unavailable);
    }).toJS;
    request.onblocked = ((JSObject _) {
      if (!opened.isCompleted) opened.completeError(_unavailable);
    }).toJS;
    return opened.future;
  }

  @override
  Future<TransferJournalRecord?> load(String ownerUserId) async {
    final _Outcome<String?> outcome = await _run<String?>('readonly', (
      _IdbObjectStore store,
      _Outcome<String?> outcome,
    ) {
      final _IdbRequest read = store.get(ownerUserId.toJS);
      read.onsuccess = ((JSObject _) {
        outcome.value = _storedText(read.result, outcome);
      }).toJS;
    });
    final String? encoded = outcome.value;
    if (encoded == null) return null;
    return _decodeOwned(encoded, ownerUserId);
  }

  @override
  Future<void> save(TransferJournalRecord record) async {
    final String encoded = TransferJournalCodec.encode(record);
    final String owner = record.ownerUserId;
    await _run<void>('readwrite', (
      _IdbObjectStore store,
      _Outcome<void> outcome,
    ) {
      final _IdbRequest read = store.get(owner.toJS);
      read.onsuccess = ((JSObject _) {
        final String? current = _storedText(read.result, outcome);
        if (outcome.failure != null) return;
        if (current == null) {
          store.put(encoded.toJS, owner.toJS);
          return;
        }
        if (current == encoded) return;
        outcome.fail(
          _isDecodable(current, owner)
              ? const TransferUnresolvedException()
              : _corrupt,
        );
      }).toJS;
    });
  }

  @override
  Future<bool> clear(String ownerUserId, String idempotencyKey) async {
    final _Outcome<bool> outcome = await _run<bool>('readwrite', (
      _IdbObjectStore store,
      _Outcome<bool> outcome,
    ) {
      outcome.value = false;
      final _IdbRequest read = store.get(ownerUserId.toJS);
      read.onsuccess = ((JSObject _) {
        final String? current = _storedText(read.result, outcome);
        if (outcome.failure != null || current == null) return;
        final TransferJournalRecord stored;
        try {
          stored = _decodeOwned(current, ownerUserId);
        } catch (_) {
          outcome.fail(_corrupt);
          return;
        }
        if (stored.idempotencyKey != idempotencyKey) return;
        store.delete(ownerUserId.toJS);
        outcome.value = true;
      }).toJS;
    });
    return outcome.value ?? false;
  }

  /// Runs [body] in one transaction and completes only on `complete`.
  Future<_Outcome<T>> _run<T>(
    String mode,
    void Function(_IdbObjectStore store, _Outcome<T> outcome) body,
  ) async {
    final _IdbDatabase db;
    try {
      db = await _db();
    } catch (_) {
      throw _unavailable;
    }
    final _Outcome<T> outcome = _Outcome<T>();
    final Completer<_Outcome<T>> done = Completer<_Outcome<T>>();
    final _IdbTransaction transaction;
    try {
      transaction = db.transaction(_storeName, mode);
    } catch (_) {
      _database = null;
      throw _unavailable;
    }
    outcome._abort = () => transaction.abort();
    transaction.oncomplete = ((JSObject _) {
      if (done.isCompleted) return;
      final Object? failure = outcome.failure;
      if (failure != null) {
        done.completeError(failure);
      } else {
        done.complete(outcome);
      }
    }).toJS;
    void failClosed(JSObject _) {
      if (!done.isCompleted) {
        done.completeError(outcome.failure ?? _unavailable);
      }
    }

    transaction.onerror = failClosed.toJS;
    transaction.onabort = failClosed.toJS;
    try {
      body(transaction.objectStore(_storeName), outcome);
    } catch (_) {
      outcome.fail(_unavailable);
    }
    return done.future;
  }

  String? _storedText(JSAny? value, _Outcome<Object?> outcome) {
    if (value == null || value.isUndefinedOrNull) return null;
    if (!value.isA<JSString>()) {
      outcome.fail(_corrupt);
      return null;
    }
    return (value as JSString).toDart;
  }

  bool _isDecodable(String encoded, String owner) {
    try {
      _decodeOwned(encoded, owner);
      return true;
    } catch (_) {
      return false;
    }
  }

  TransferJournalRecord _decodeOwned(String encoded, String owner) {
    final TransferJournalRecord record = TransferJournalCodec.decode(encoded);
    if (record.ownerUserId != owner) throw _corrupt;
    return record;
  }
}

/// Mutable result of one transaction; a failure aborts it.
class _Outcome<T> {
  T? value;
  Object? failure;
  void Function()? _abort;

  void fail(Object error) {
    if (failure != null) return;
    failure = error;
    try {
      _abort?.call();
    } catch (_) {
      // The transaction may already be finishing; the failure still wins.
    }
  }
}

const TransferJournalException _unavailable = TransferJournalException(
  TransferJournalFailure.unavailable,
);
const TransferJournalException _corrupt = TransferJournalException(
  TransferJournalFailure.corrupt,
);
