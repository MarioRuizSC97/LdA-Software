import 'catalog_product.dart';
import 'catalog_stock.dart';

export 'catalog_stock.dart';

abstract interface class CatalogRepository {
  Future<List<CatalogProduct>> fetchProducts();
}

abstract interface class RoleScopedCatalogRepository {
  Future<CatalogSnapshot> fetchCatalog();
}

class FixtureCatalogRepository implements CatalogRepository {
  const FixtureCatalogRepository(this.products);

  final List<CatalogProduct> products;

  @override
  Future<List<CatalogProduct>> fetchProducts() async =>
      List<CatalogProduct>.unmodifiable(products);
}

/// Deliberately prevents a Firestore read until authentication provisioning and
/// an emulator-only connection are available.
class DisconnectedFirestoreCatalogRepository implements CatalogRepository {
  const DisconnectedFirestoreCatalogRepository();

  @override
  Future<List<CatalogProduct>> fetchProducts() {
    return Future<List<CatalogProduct>>.error(
      const CatalogRepositoryUnavailable(
        'Firestore catalog access requires an authenticated emulator session.',
      ),
    );
  }
}

class CatalogRepositoryUnavailable implements Exception {
  const CatalogRepositoryUnavailable(this.message);

  final String message;
}
