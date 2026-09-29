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

class CatalogSnapshot {
  CatalogSnapshot(List<CatalogItem> items)
    : items = List<CatalogItem>.unmodifiable(items);

  final List<CatalogItem> items;
}
