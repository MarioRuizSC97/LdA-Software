/// Picks the durable unresolved-transfer journal for the running platform:
/// IndexedDB on the web, SQLite on Android and iOS, and an in-memory journal
/// everywhere else.
library;

export 'transfer_draft_persistence_stub.dart'
    if (dart.library.js_interop) 'transfer_draft_persistence_indexeddb.dart'
    if (dart.library.io) 'transfer_draft_persistence_sqflite.dart';
