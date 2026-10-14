@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';
import 'package:lda_inventory/transfers/transfer_draft_persistence.dart';
import 'package:lda_inventory/transfers/transfer_draft_persistence_indexeddb.dart';

const String _key = '7f0c5d0e-2b9a-4c1e-8f3d-2a6b9c4d1e70';

TransferJournalRecord _record(
  String owner, {
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

void main() {
  test('records survive a new adapter and clear only by key', () async {
    // A unique owner per run keeps the shared browser database independent.
    final String owner = 'admin-${DateTime.now().microsecondsSinceEpoch}';
    await IndexedDbTransferDraftJournal().save(_record(owner));
    await IndexedDbTransferDraftJournal().save(_record(owner));

    final IndexedDbTransferDraftJournal reloaded =
        IndexedDbTransferDraftJournal();
    expect(await reloaded.load(owner), _record(owner));
    expect(await reloaded.load('$owner-other'), isNull);
    await expectLater(
      reloaded.save(_record(owner, idempotencyKey: 'other-key')),
      throwsA(isA<TransferUnresolvedException>()),
    );
    await expectLater(
      reloaded.save(_record(owner, quantity: '9.00')),
      throwsA(isA<TransferUnresolvedException>()),
    );

    expect(await reloaded.clear(owner, 'other-key'), isFalse);
    expect(await IndexedDbTransferDraftJournal().load(owner), _record(owner));
    expect(await reloaded.clear(owner, _key), isTrue);
    expect(await IndexedDbTransferDraftJournal().load(owner), isNull);
  });

  test('the platform factory selects IndexedDB on the web', () {
    expect(
      createPlatformTransferDraftJournal(),
      isA<IndexedDbTransferDraftJournal>(),
    );
  });
}
