import 'correction_sale.dart';

typedef CorrectableSaleFinder = Future<CorrectableSale> Function(
  SaleLookupQuery query,
);
typedef RecentCorrectableSalesLoader =
    Future<RecentCorrectableSales> Function();

/// Seller-only correction operations the shell hands to the catalog page,
/// like `SaleCheckout`. The shell re-checks the exact seller around every
/// call; the page never sees the gateway or the session.
class SaleCorrections {
  const SaleCorrections({
    required this.branchId,
    required this.find,
    required this.listRecent,
  });

  /// The seller's branch; every lookup is scoped to it server-side.
  final String branchId;
  final CorrectableSaleFinder find;
  final RecentCorrectableSalesLoader listRecent;
}
