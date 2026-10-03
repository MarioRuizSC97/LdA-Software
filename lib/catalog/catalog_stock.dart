import 'catalog_product.dart';

const int maxSafeScaledQuantity = 9007199254740991;

class CatalogHolding {
  const CatalogHolding({
    required this.branchId,
    required this.quantityScaled,
    this.branchName,
  });

  final String branchId;
  final String? branchName;
  final int quantityScaled;

  bool get isOutOfStock => quantityScaled == 0;
}

class CatalogItem {
  CatalogItem({required this.product, required List<CatalogHolding> holdings})
    : holdings = List<CatalogHolding>.unmodifiable(holdings);

  final CatalogProduct product;
  final List<CatalogHolding> holdings;
}

class CatalogBranchChoice {
  const CatalogBranchChoice({required this.branchId, required this.branchName});

  final String branchId;
  final String branchName;

  @override
  bool operator ==(Object other) =>
      other is CatalogBranchChoice &&
      other.branchId == branchId &&
      other.branchName == branchName;

  @override
  int get hashCode => Object.hash(branchId, branchName);
}

class CatalogSnapshot {
  CatalogSnapshot(
    List<CatalogItem> items, {
    List<CatalogBranchChoice> branchChoices = const <CatalogBranchChoice>[],
  }) : items = List<CatalogItem>.unmodifiable(items),
       branchChoices = List<CatalogBranchChoice>.unmodifiable(branchChoices);

  final List<CatalogItem> items;

  /// Administrator-only branch choices covering every existing branch,
  /// including branches without any holdings or stock documents. Seller
  /// snapshots expose an empty list.
  final List<CatalogBranchChoice> branchChoices;
}
