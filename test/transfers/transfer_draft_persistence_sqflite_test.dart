import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';
import 'package:lda_inventory/transfers/transfer_draft_persistence.dart';
import 'package:lda_inventory/transfers/transfer_draft_persistence_sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _owner = 'administrator-1';
const String _key = '7f0c5d0e-2b9a-4c1e-8f3d-2a6b9c4d1e70';

TransferJournalRecord _record({
  String owner = _owner,
  String idempotencyKey = _key,
  String quantity = '2.50',
}) => TransferJournalRecord(
  ownerUserId: owner,
  draft: TransferDraft(
    idempotencyKey: idempotencyKey,
    sourceBranchId: 'branch-north',
    destinationBranchId: 'branch-south',
    lines: <TransferLine>[
      TransferLine(
        productId: 'PRD-COFFEE-001',
        quantity: quantity,
        quantitySpec: const QuantitySpec(unit: 'kg', precision: 2),
      ),
    ],
  ),
);

Matcher _journalFailure(TransferJournalFailure failure) =>
    isA<TransferJournalException>().having(
      (TransferJournalException error) => error.failure,
      'failure',
      failure,
    );

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: createTransferJournalSchema,
      ),
    );
  });

  tearDown(() => db.close());

  SqfliteTransferDraftJournal journal() =>
      SqfliteTransferDraftJournal(open: () async => db);

  test('a fresh adapter over the same database reads the record', () async {
    await journal().save(_record());
    await journal().save(_record());

    // A new adapter instance stands in for an app restart.
    final SqfliteTransferDraftJournal restarted = journal();
    expect(await restarted.load(_owner), _record());
    expect(await restarted.load('administrator-2'), isNull);
  });

  test('keeps one record per owner and clears only the matching key', () async {
    final SqfliteTransferDraftJournal adapter = journal();
    await adapter.save(_record());
    await expectLater(
      adapter.save(_record(idempotencyKey: 'other-key')),
      throwsA(isA<TransferUnresolvedException>()),
    );
    await expectLater(
      adapter.save(_record(quantity: '9.00')),
      throwsA(isA<TransferUnresolvedException>()),
    );
    await adapter.save(_record(owner: 'administrator-2'));

    expect(await adapter.clear(_owner, 'other-key'), isFalse);
    expect(await adapter.load(_owner), _record());
    expect(await adapter.clear(_owner, _key), isTrue);
    expect(await adapter.load(_owner), isNull);
    expect(
      await adapter.load('administrator-2'),
      _record(owner: 'administrator-2'),
    );
  });

  test('corrupt rows fail closed and are never dropped', () async {
    await db.insert('unresolved_transfers', <String, Object?>{
      'owner_user_id': _owner,
      'idempotency_key': _key,
      'payload': '{"version":1}',
    });
    final SqfliteTransferDraftJournal adapter = journal();

    await expectLater(
      adapter.load(_owner),
      throwsA(_journalFailure(TransferJournalFailure.corrupt)),
    );
    await expectLater(
      adapter.save(_record()),
      throwsA(_journalFailure(TransferJournalFailure.corrupt)),
    );
    await expectLater(
      adapter.clear(_owner, _key),
      throwsA(_journalFailure(TransferJournalFailure.corrupt)),
    );
    expect(await db.query('unresolved_transfers'), hasLength(1));
  });

  test('a key column that disagrees with its payload is corrupt', () async {
    await db.insert('unresolved_transfers', <String, Object?>{
      'owner_user_id': _owner,
      'idempotency_key': 'other-key',
      'payload': TransferJournalCodec.encode(_record()),
    });
    await expectLater(
      journal().load(_owner),
      throwsA(_journalFailure(TransferJournalFailure.corrupt)),
    );
  });

  test('an unavailable database fails closed and is retried', () async {
    int opens = 0;
    final SqfliteTransferDraftJournal adapter = SqfliteTransferDraftJournal(
      open: () async {
        opens += 1;
        if (opens == 1) throw StateError('disk unavailable');
        return db;
      },
    );

    await expectLater(
      adapter.save(_record()),
      throwsA(_journalFailure(TransferJournalFailure.unavailable)),
    );
    expect(await adapter.load(_owner), isNull);
    await adapter.save(_record());
    expect(await adapter.load(_owner), _record());
    expect(opens, 2);
  });

  test('the durable store keeps the key across a restart', () async {
    final TransferDraftStore first = TransferDraftStore(journal: journal());
    await first.begin(ownerUserId: _owner, draft: _record().draft);

    final TransferDraftStore restarted = TransferDraftStore(journal: journal());
    expect(await restarted.hydrate(_owner), TransferJournalStatus.ready);
    expect(restarted.unresolvedByOwner(_owner), <TransferDraft>[
      _record().draft,
    ]);
  });
}
