# Transfer-destination notices (seller inbox and counter)

DN-01 — Flutter side. A seller with stock arriving from another branch sees a
live badge with the number of unread transfer notices, opens an inbox, and
acknowledges each notice explicitly. Nothing pops up; nothing is marked read
implicitly.

## Data flow

1. `inventoryMovements` is streamed by destination `branchId` only
   (single-field filter, no composite index, no hard cap). The controller
   groups strict-valid transfer-in legs by `transferId` locally
   (`groupTransferInNotices` in `lib/transfers/transfer_notice.dart`).
   Grouping, ordering, and counting are local: a high volume of old arrivals
   can never hide an unread notice behind a page size.
2. Persisted read markers are streamed from
   `transferNoticeReads/{userId}/branches/{branchId}/transfers`. Markers are
   written only by the backend callable `markTransferNoticeRead`; the client
   never writes to that collection.
3. Acknowledgement: the seller presses "Marcar como leído". The controller
   sends `{transferId}` to `markTransferNoticeRead` and accepts only the exact
   response `{transferId, branchId, read: true}` for its own branch. Replays
   are safe (the marker keeps its original `readAt`), so an uncertain outcome
   is resolved by the marker stream, never guessed by the client.

## Guarantees

- **Server-confirmed readiness.** The unread count and the ack buttons are
  enabled only after BOTH streams deliver a server-confirmed snapshot
  (`isFromCache == false`). Both queries subscribe with
  `includeMetadataChanges: true`, so a metadata-only server confirmation
  (cached documents already equal to the server's) still arrives. Cache-only
  events are never applied as data and never produce a "zero unread".
- **Errors stay unknown, never zero.** A stream failure or backend-load
  failure switches the book to an explicit error phase (`unreadCount` is null)
  and the badge shows "!" instead of a count; the inbox offers "Reintentar".
- **One notice per transfer.** Every strict-valid transfer-in leg of the same
  `transferId` at the destination branch is one notice with all its lines.
- **Read history is retained.** Read notices stay listed with a "Leído" chip.
  A recreated controller reproduces the same read state from the persisted
  markers, so no notice re-appears unread across restarts or navigation.
- **Exact session ownership.** The shell builds one controller per exact
  seller session; every stream event and both ends of the ack await re-check
  the session through the shell. A logout, role change, user change, or branch
  change disposes the controller and clears its notices; a late ack never
  lands on a new owner (`TransferNoticeSessionException`). A session check
  that throws mid-event or at startup becomes an explicit error phase, never
  an unhandled async exception.
- **Per-stream event sequencing.** Each stream keeps an arrival-order
  sequence; an event applies only if its sequence is at least the last one
  actually applied on its own stream. When two same-stream snapshots have
  their session checks complete out of order, the older snapshot can never
  overwrite the newer one's applied read state. The two streams are fully
  independent: a movement event never invalidates an in-flight marker event
  or vice versa.
- **Failures latch until retry.** A stream error (or any load/subscription
  setup failure) tears down both streams and latches the error for the
  current generation: a later healthy opposite-stream snapshot cannot re-enter
  readiness, so a failed marker stream can never be "recovered" by stale
  movement data that would renotify already-read notices. Only the explicit
  `retry()` starts a fresh generation with full proof. The unread count stays
  null (unknown) while latched — never a false zero.
- **No source-branch leakage.** Notice lines expose only `movementId`,
  `productId`, `quantityScaled`, `unit`, `precision`, `occurredAt`. The strict
  movement parser rejects any other field, so costs, source-branch audit
  fields, and the opposite branch's legs can never surface.

## Rejection codes of the ack (client mapping)

Deterministic refusals (`invalid-argument`, `failed-precondition`,
`permission-denied`, `not-found`, `resource-exhausted`, `unauthenticated`)
map to `TransferNoticeAckRejectedException` (a retry will refuse again).
Everything else is `TransferNoticeAckUncertainException`; the marker stream is
the source of truth and the UI keeps the notice unread until a marker lands.

## Integration points

- `lib/firebase/emulator_transfer_notice_gateway.dart` — Firestore stream
  adapter and callable mapping (`transferNoticeCallableFromInvoker`,
  `loadTransferNoticeBackend`).
- `lib/auth/emulator_login.dart` — `transferNoticeBackendLoader` shell
  parameter; builds the controller factory for exact seller sessions only.
- `lib/firebase/emulator_bootstrap.dart` —
  `DemoEmulatorBootstrap.initializeTransferNoticeBackend`: seller-only,
  emulator-only binding of `loadTransferNoticeBackend` over the already
  connected named-app Firestore and the us-south1 Functions instance.
- `lib/main.dart` — `LdaInventoryBootstrap.emulatorTransferNoticeLoader`
  threads the optional injectable seam through `LocalEmulatorAuthApp` to the
  shell; the production default applies only in the local-emulator branch, so
  demo and disconnected modes never load notices.
- `lib/catalog/catalog_page.dart` — the live "Avisos de traslados" badge entry
  (visible with the inbox closed) and the inbox body priority.
- `lib/transfers/transfer_notice_controller.dart` — state machine
  (loading/ready/error), grouping, read markers, ack fences.
- `lib/transfers/transfer_notices_view.dart` — Spanish inbox UI, accessible
  labels, responsive down to 320 px.

## MVP tradeoff

The movements query filters by destination branch only and keeps the full
history of the branch in memory for grouping. This avoids a composite index
and any unread-hiding cap; a future pagination policy must preserve the
"no unread behind a cap" property before shrinking the window.
