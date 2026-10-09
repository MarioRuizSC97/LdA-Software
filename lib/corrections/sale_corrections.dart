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
typedef CorrectionDraftLookup = SaleCorrectionDraft? Function();
typedef CorrectionKeyFactory = String Function();

/// Seller-only correction operations the shell hands to the catalog page,
/// like `SaleCheckout`. The shell re-checks the exact seller around every
/// call; the page never sees the gateway or the session.
///
/// [submitReturn] owns the shell-level draft store: it begins the attempt,
/// submits, and resolves it only on success or a deterministic rejection.
/// [unresolvedDraft] returns the stored correction that must be retried
/// before any other.
class SaleCorrections {
  const SaleCorrections({
    required this.branchId,
    required this.find,
    required this.listRecent,
    required this.previewReturn,
    required this.submitReturn,
    required this.unresolvedDraft,
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
  final CorrectionDraftLookup unresolvedDraft;
  final CorrectionKeyFactory createKey;
}
