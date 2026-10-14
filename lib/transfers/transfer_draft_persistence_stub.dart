import 'transfer_draft_persistence.dart';

/// Platforms without durable storage keep the journal in memory only.
TransferDraftJournal createPlatformTransferDraftJournal() =>
    InMemoryTransferDraftJournal();
