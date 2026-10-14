import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';
import 'package:lda_inventory/transfers/transfer_draft_persistence.dart';

const String _key = '7f0c5d0e-2b9a-4c1e-8f3d-2a6b9c4d1e70';
const String _owner = 'administrator-1';
const QuantitySpec _kg = QuantitySpec(unit: 'kg', precision: 2);

TransferDraft _draft({
  String idempotencyKey = _key,
  String quantity = '2.50',
}) => TransferDraft(
  idempotencyKey: idempotencyKey,
  sourceBranchId: 'branch-north',
  destinationBranchId: 'branch-south',
  lines: <TransferLine>[
    TransferLine(
      productId: 'PRD-COFFEE-001',
      quantity: quantity,
      quantitySpec: _kg,
    ),
  ],
);

TransferJournalRecord _record({
  String owner = _owner,
  String idempotencyKey = _key,
  String quantity = '2.50',
}) => TransferJournalRecord(
  ownerUserId: owner,
  draft: _draft(idempotencyKey: idempotencyKey, quantity: quantity),
);

Map<String, Object?> _encodedMap() =>
    jsonDecode(TransferJournalCodec.encode(_record())) as Map<String, Object?>;

Matcher _journalFailure(TransferJournalFailure failure) =>
    isA<TransferJournalException>().having(
      (TransferJournalException error) => error.failure,
      'failure',
      failure,
    );

void main() {
  group('TransferJournalCodec', () {
    test('round-trips the minimal owner-bound record deterministically', () {
      final String encoded = TransferJournalCodec.encode(_record());

      expect(TransferJournalCodec.encode(_record()), encoded);
      expect(jsonDecode(encoded), <String, Object?>{
        'version': 1,
        'ownerUserId': _owner,
        'idempotencyKey': _key,
        'sourceBranchId': 'branch-north',
        'destinationBranchId': 'branch-south',
        'lines': <Object?>[
          <String, Object?>{
            'productId': 'PRD-COFFEE-001',
            'quantity': '2.50',
            'unit': 'kg',
            'precision': 2,
          },
        ],
      });
      final TransferJournalRecord decoded = TransferJournalCodec.decode(
        encoded,
      );
      expect(decoded, _record());
      expect(decoded.draft.toRequest(), _draft().toRequest());
    });

    test('rejects unknown, missing, mistyped, and out-of-contract fields', () {
      final List<Map<String, Object?> Function()> corruptions =
          <Map<String, Object?> Function()>[
            () => _encodedMap()..['extra'] = true,
            () => _encodedMap()..remove('ownerUserId'),
            () => _encodedMap()..['version'] = 2,
            () => _encodedMap()..['version'] = '1',
            () => _encodedMap()..['ownerUserId'] = '',
            () => _encodedMap()..['idempotencyKey'] = 7,
            () => _encodedMap()..['destinationBranchId'] = 'branch-north',
            () => _encodedMap()..['lines'] = <Object?>[],
            () => _encodedMap()..['lines'] = 'PRD-COFFEE-001',
            () {
              final Map<String, Object?> map = _encodedMap();
              ((map['lines']! as List<Object?>).single!
                      as Map<String, Object?>)['precision'] =
                  '2';
              return map;
            },
            () {
              final Map<String, Object?> map = _encodedMap();
              ((map['lines']! as List<Object?>).single!
                      as Map<String, Object?>)['note'] =
                  'x';
              return map;
            },
            () {
              final Map<String, Object?> map = _encodedMap();
              ((map['lines']! as List<Object?>).single! as Map<String, Object?>)
                  .remove('unit');
              return map;
            },
            () {
              final Map<String, Object?> map = _encodedMap();
              ((map['lines']! as List<Object?>).single!
                      as Map<String, Object?>)['quantity'] =
                  '2.505';
              return map;
            },
          ];
      for (final Map<String, Object?> Function() corrupt in corruptions) {
        expect(
          () => TransferJournalCodec.decode(jsonEncode(corrupt())),
          throwsA(_journalFailure(TransferJournalFailure.corrupt)),
        );
      }
      for (final String raw in <String>['', 'not json', '[]', 'null', '{}']) {
        expect(
          () => TransferJournalCodec.decode(raw),
          throwsA(_journalFailure(TransferJournalFailure.corrupt)),
        );
      }
    });
  });

  group('InMemoryTransferDraftJournal', () {
    test(
      'keeps one record per owner and clears only the matching key',
      () async {
        final InMemoryTransferDraftJournal journal =
            InMemoryTransferDraftJournal();
        await journal.save(_record());
        // The identical record is idempotent; a different one is refused.
        await journal.save(_record());
        await expectLater(
          journal.save(_record(idempotencyKey: 'other-key')),
          throwsA(isA<TransferUnresolvedException>()),
        );
        await expectLater(
          journal.save(_record(quantity: '9.00')),
          throwsA(isA<TransferUnresolvedException>()),
        );
        expect(await journal.load(_owner), _record());
        expect(await journal.load('administrator-2'), isNull);

        expect(await journal.clear(_owner, 'other-key'), isFalse);
        expect(await journal.load(_owner), _record());
        expect(await journal.clear(_owner, _key), isTrue);
        expect(await journal.load(_owner), isNull);
      },
    );
  });

  group('TransferDraftStore durable journal', () {
    test(
      'a new store over the same journal hydrates the retained record',
      () async {
        final InMemoryTransferDraftJournal journal =
            InMemoryTransferDraftJournal();
        final TransferDraftStore first = TransferDraftStore(journal: journal);
        final TransferAttempt attempt = await first.begin(
          ownerUserId: _owner,
          draft: _draft(),
        );
        first.retain(attempt);

        // Reload: the volatile store is gone, the journal survives.
        final TransferDraftStore reloaded = TransferDraftStore(
          journal: journal,
        );
        expect(reloaded.statusFor(_owner), TransferJournalStatus.unknown);
        expect(reloaded.unresolvedByOwner(_owner), isEmpty);
        expect(await reloaded.hydrate(_owner), TransferJournalStatus.ready);
        expect(reloaded.unresolvedByOwner(_owner), <TransferDraft>[_draft()]);
        expect(reloaded.unresolvedFor(_owner, _key), _draft());

        // The retry keeps the identical key and payload and then settles.
        final TransferAttempt retry = await reloaded.begin(
          ownerUserId: _owner,
          draft: _draft(),
        );
        expect(retry.idempotencyKey, _key);
        expect(await reloaded.resolve(retry), isTrue);
        expect(await journal.load(_owner), isNull);
      },
    );

    test('hydration is owner-bound', () async {
      final InMemoryTransferDraftJournal journal =
          InMemoryTransferDraftJournal();
      await journal.save(_record());
      final TransferDraftStore store = TransferDraftStore(journal: journal);

      expect(
        await store.hydrate('administrator-2'),
        TransferJournalStatus.ready,
      );
      expect(store.unresolvedByOwner('administrator-2'), isEmpty);
      expect(store.unresolvedByOwner(_owner), isEmpty);
      expect(store.statusFor(_owner), TransferJournalStatus.unknown);
    });

    test(
      'saves before answering the attempt and fails closed on save',
      () async {
        final InMemoryTransferDraftJournal journal =
            InMemoryTransferDraftJournal();
        final TransferDraftStore store = TransferDraftStore(journal: journal);
        expect(await store.hydrate(_owner), TransferJournalStatus.ready);

        await store.begin(ownerUserId: _owner, draft: _draft());
        expect(
          journal.rawRecords[_owner],
          TransferJournalCodec.encode(_record()),
        );

        final TransferDraftStore failing = TransferDraftStore(
          journal: InMemoryTransferDraftJournal(),
        );
        expect(await failing.hydrate(_owner), TransferJournalStatus.ready);
        (failing.journal as InMemoryTransferDraftJournal).unavailable = true;
        await expectLater(
          failing.begin(ownerUserId: _owner, draft: _draft()),
          throwsA(_journalFailure(TransferJournalFailure.unavailable)),
        );
        expect(failing.unresolvedByOwner(_owner), isEmpty);
        expect(failing.statusFor(_owner), TransferJournalStatus.unavailable);
      },
    );

    test('allows at most one unresolved record per owner', () async {
      final InMemoryTransferDraftJournal journal =
          InMemoryTransferDraftJournal();
      final TransferDraftStore store = TransferDraftStore(journal: journal);
      await store.begin(ownerUserId: _owner, draft: _draft());

      await expectLater(
        store.begin(
          ownerUserId: _owner,
          draft: _draft(idempotencyKey: 'other-key'),
        ),
        throwsA(isA<TransferUnresolvedException>()),
      );
      expect(store.unresolvedByOwner(_owner), <TransferDraft>[_draft()]);
      expect(
        journal.rawRecords[_owner],
        TransferJournalCodec.encode(_record()),
      );

      // Another owner keeps its own independent record.
      await store.begin(
        ownerUserId: 'administrator-2',
        draft: _draft(idempotencyKey: 'other-key'),
      );
      expect(
        journal.rawRecords.keys,
        unorderedEquals(<String>[_owner, 'administrator-2']),
      );
    });

    test('clears only on a current settlement', () async {
      final InMemoryTransferDraftJournal journal =
          InMemoryTransferDraftJournal();
      final TransferDraftStore store = TransferDraftStore(journal: journal);
      final TransferAttempt stale = await store.begin(
        ownerUserId: _owner,
        draft: _draft(),
      );
      final TransferAttempt current = await store.begin(
        ownerUserId: _owner,
        draft: _draft(),
      );

      store.retain(current);
      expect(await store.resolve(stale), isFalse);
      expect(journal.rawRecords, contains(_owner));
      expect(journal.clears, 0);

      expect(await store.resolve(current), isTrue);
      expect(journal.rawRecords, isNot(contains(_owner)));
      expect(store.unresolvedByOwner(_owner), isEmpty);
      expect(await store.resolve(current), isFalse);
    });

    test('a failed clear keeps the record and blocks the owner', () async {
      final InMemoryTransferDraftJournal journal =
          InMemoryTransferDraftJournal();
      final TransferDraftStore store = TransferDraftStore(journal: journal);
      final TransferAttempt attempt = await store.begin(
        ownerUserId: _owner,
        draft: _draft(),
      );
      journal.unavailable = true;

      await expectLater(
        store.resolve(attempt),
        throwsA(_journalFailure(TransferJournalFailure.unavailable)),
      );
      expect(store.unresolvedByOwner(_owner), <TransferDraft>[_draft()]);
      expect(store.statusFor(_owner), TransferJournalStatus.unavailable);

      journal.unavailable = false;
      expect(await store.hydrate(_owner), TransferJournalStatus.ready);
      expect(store.unresolvedByOwner(_owner), <TransferDraft>[_draft()]);
    });

    test(
      'unavailable or corrupt storage blocks without dropping data',
      () async {
        final InMemoryTransferDraftJournal journal =
            InMemoryTransferDraftJournal()..unavailable = true;
        final TransferDraftStore store = TransferDraftStore(journal: journal);
        expect(await store.hydrate(_owner), TransferJournalStatus.unavailable);
        await expectLater(
          store.begin(ownerUserId: _owner, draft: _draft()),
          throwsA(_journalFailure(TransferJournalFailure.unavailable)),
        );

        final InMemoryTransferDraftJournal corrupt =
            InMemoryTransferDraftJournal();
        corrupt.rawRecords[_owner] = '{"version":1}';
        final TransferDraftStore blocked = TransferDraftStore(journal: corrupt);
        expect(await blocked.hydrate(_owner), TransferJournalStatus.corrupt);
        await expectLater(
          blocked.begin(ownerUserId: _owner, draft: _draft()),
          throwsA(_journalFailure(TransferJournalFailure.corrupt)),
        );
        expect(corrupt.rawRecords[_owner], '{"version":1}');
        expect(blocked.unresolvedByOwner(_owner), isEmpty);
      },
    );
  });
}
