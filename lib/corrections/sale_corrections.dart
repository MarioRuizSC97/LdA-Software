import '../sales/sale_draft.dart' show createSaleIdempotencyKey;
import 'correction_draft.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';

typedef CorrectableSaleFinder = Future<CorrectableSale> Function(
  SaleLookupQuery query,
);
typedef RecentCorrectableSalesLoader =
    Future<RecentCorrectableSales> Function();
typedef SaleReturnPreviewer = Future<SaleReturnPreview> Function(
  SaleReturnPreviewRequest request,
);
typedef SaleReturnSubmitter = Future<SaleReturnReceipt> Function(
  SaleReturnDraft draft,
);
typedef SaleExchangePreviewer = Future<SaleExchangePreview> Function(
  SaleExchangePreviewRequest request,
);
typedef SaleReplacementSubmitter = Future<SaleReplacementReceipt> Function(
  SaleReplacementDraft draft,
);
typedef SaleExchangeSubmitter = Future<SaleExchangeReceipt> Function(
  SaleExchangeDraft draft,
);
typedef CorrectionDraftLookup = SaleCorrectionDraft? Function();
typedef CorrectionKeyFactory = String Function();

/// The committed correction, of any kind, whose receipt the seller has not
/// yet left.
typedef UnacknowledgedCorrectionLookup = CompletedCorrection? Function();
typedef CorrectionAcknowledger = void Function(SaleCorrectionReceipt receipt);

/// Seller-only correction operations the shell hands to the catalog page,
/// like `SaleCheckout`. The shell re-checks the exact seller around every
/// call; the page never sees the gateway or the session.
///
/// The submits own the shell-level draft store: each begins the attempt and
/// submits. A deterministic rejection drops the draft; a success keeps it
/// with its receipt until [acknowledge], so a receipt is never lost when the
/// form is disposed mid-submit. [unresolvedDraft] returns the stored
/// correction that must be retried before any other, and [unacknowledged]
/// the committed correction whose receipt must be shown before any other.
class SaleCorrections {
  const SaleCorrections({
    required this.branchId,
    required this.find,
    required this.listRecent,
    required this.previewReturn,
    required this.submitReturn,
    required this.previewExchange,
    required this.submitReplacement,
    required this.submitExchange,
    required this.unresolvedDraft,
    required this.unacknowledged,
    required this.acknowledge,
    this.createKey = createSaleIdempotencyKey,
  });

  /// The seller's branch. It is never sent (the server takes it from
  /// claims), but every correction draft is frozen with it, so the shell can
  /// refuse a draft made under another branch and the receipt parser can bind
  /// the server's `branchId` to it.
  final String branchId;
  final CorrectableSaleFinder find;
  final RecentCorrectableSalesLoader listRecent;
  final SaleReturnPreviewer previewReturn;
  final SaleReturnSubmitter submitReturn;
  final SaleExchangePreviewer previewExchange;
  final SaleReplacementSubmitter submitReplacement;
  final SaleExchangeSubmitter submitExchange;
  final CorrectionDraftLookup unresolvedDraft;
  final UnacknowledgedCorrectionLookup unacknowledged;

  /// Called once the seller leaves the receipt; only then may another
  /// correction begin.
  final CorrectionAcknowledger acknowledge;
  final CorrectionKeyFactory createKey;
}
