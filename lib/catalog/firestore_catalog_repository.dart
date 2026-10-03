import 'package:cloud_firestore/cloud_firestore.dart';

import '../auth/emulator_session.dart';
import 'catalog_product.dart';
import 'catalog_repository.dart';

class CatalogDocument {
  const CatalogDocument({required this.path, required this.data});

  final String path;
  final Map<String, Object?> data;
}

abstract interface class CatalogReadSource {
  Future<List<CatalogDocument>> listCollection(String path);

  Future<CatalogDocument> getDocument(String path);

  Future<List<CatalogDocument>> listCollectionGroup(String collectionId);
}

typedef ActiveSessionChecker = Future<EmulatorSession?> Function();

class FirebaseFirestoreCatalogReadSource implements CatalogReadSource {
  FirebaseFirestoreCatalogReadSource(this._firestore);

  final FirebaseFirestore _firestore;

  @override
  Future<CatalogDocument> getDocument(String path) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _firestore
        .doc(path)
        .get();
    final Map<String, dynamic>? data = snapshot.data();
    if (!snapshot.exists || data == null) {
      throw StateError('Catalog document is unavailable.');
    }
    return CatalogDocument(path: snapshot.reference.path, data: data);
  }

  @override
  Future<List<CatalogDocument>> listCollection(String path) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collection(path)
        .get();
    return snapshot.docs
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              CatalogDocument(
                path: document.reference.path,
                data: document.data(),
              ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<CatalogDocument>> listCollectionGroup(String collectionId) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collectionGroup(collectionId)
        .get();
    return snapshot.docs
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              CatalogDocument(
                path: document.reference.path,
                data: document.data(),
              ),
        )
        .toList(growable: false);
  }
}

class FirestoreCatalogRepository implements RoleScopedCatalogRepository {
  factory FirestoreCatalogRepository.seller({
    required CatalogReadSource source,
    required EmulatorSession session,
    required ActiveSessionChecker sessionChecker,
  }) => FirestoreCatalogRepository._(
    source,
    session,
    InventoryRole.seller,
    sessionChecker,
  );

  factory FirestoreCatalogRepository.administrator({
    required CatalogReadSource source,
    required EmulatorSession session,
    required ActiveSessionChecker sessionChecker,
  }) => FirestoreCatalogRepository._(
    source,
    session,
    InventoryRole.administrator,
    sessionChecker,
  );

  FirestoreCatalogRepository._(
    this._source,
    this._session,
    this._expectedRole,
    this._sessionChecker,
  );

  final CatalogReadSource _source;
  final EmulatorSession _session;
  final InventoryRole _expectedRole;
  final ActiveSessionChecker _sessionChecker;

  @override
  Future<CatalogSnapshot> fetchCatalog() async {
    try {
      await _requireActiveSession();
      return switch (_expectedRole) {
        InventoryRole.seller => await _fetchSeller(),
        InventoryRole.administrator => await _fetchAdministrator(),
      };
    } catch (_) {
      throw const CatalogRepositoryUnavailable(
        'Catalog data is unavailable or invalid.',
      );
    }
  }

  Future<CatalogSnapshot> _fetchSeller() async {
    final String? branchId = _session.branchId;
    if (branchId == null || !_branchIdPattern.hasMatch(branchId)) {
      throw const FormatException('seller branch is invalid');
    }

    final List<CatalogDocument> stockDocuments = await _readWithActiveSession(
      () => _source.listCollection('branches/$branchId/stock'),
    );
    final Set<String> productIds = <String>{};
    final List<_PendingHolding> pending = <_PendingHolding>[];
    for (final CatalogDocument document in stockDocuments) {
      final _StockPath path = _parseStockPath(document.path);
      if (path.branchId != branchId || !productIds.add(path.productId)) {
        throw const FormatException('stock path is invalid');
      }
      pending.add(
        _PendingHolding(
          branchId: branchId,
          productId: path.productId,
          data: _parseStock(document.data),
        ),
      );
    }

    final List<CatalogItem> items = <CatalogItem>[];
    for (final _PendingHolding holding in pending) {
      final CatalogDocument document = await _readWithActiveSession(
        () => _source.getDocument('products/${holding.productId}'),
      );
      final CatalogProduct product = _parseProduct(document);
      _requireMatchingQuantity(product.quantitySpec, holding.data);
      items.add(
        CatalogItem(
          product: product,
          holdings: <CatalogHolding>[
            CatalogHolding(
              branchId: branchId,
              quantityScaled: holding.data.quantityScaled,
            ),
          ],
        ),
      );
    }
    _sortItems(items);
    return CatalogSnapshot(items);
  }

  Future<CatalogSnapshot> _fetchAdministrator() async {
    if (_session.branchId != null) throw const FormatException();

    final List<CatalogDocument> productDocuments = await _readWithActiveSession(
      () => _source.listCollection('products'),
    );
    final List<CatalogDocument> branchDocuments = await _readWithActiveSession(
      () => _source.listCollection('branches'),
    );
    final List<CatalogDocument> stockDocuments = await _readWithActiveSession(
      () => _source.listCollectionGroup('stock'),
    );

    final Map<String, CatalogProduct> products = <String, CatalogProduct>{};
    for (final CatalogDocument document in productDocuments) {
      final CatalogProduct product = _parseProduct(document);
      if (products[product.internalCode] != null) {
        throw const FormatException('duplicate product');
      }
      products[product.internalCode] = product;
    }

    final Map<String, String> branches = <String, String>{};
    final Set<String> branchNames = <String>{};
    for (final CatalogDocument document in branchDocuments) {
      final String branchId = _parseBranchPath(document.path);
      final String branchName = _parseBranch(document.data);
      if (branches[branchId] != null || !branchNames.add(branchName)) {
        throw const FormatException('duplicate branch');
      }
      branches[branchId] = branchName;
    }
    final List<CatalogBranchChoice> branchChoices =
        List<CatalogBranchChoice>.of(
          branches.entries.map(
            (MapEntry<String, String> branch) => CatalogBranchChoice(
              branchId: branch.key,
              branchName: branch.value,
            ),
          ),
        )..sort(
          (CatalogBranchChoice left, CatalogBranchChoice right) =>
              left.branchId.compareTo(right.branchId),
        );

    final Map<String, List<CatalogHolding>> holdings =
        <String, List<CatalogHolding>>{};
    final Set<String> holdingKeys = <String>{};
    for (final CatalogDocument document in stockDocuments) {
      final _StockPath path = _parseStockPath(document.path);
      final CatalogProduct? product = products[path.productId];
      final String? branchName = branches[path.branchId];
      if (product == null || branchName == null) {
        throw const FormatException('orphan stock');
      }
      if (!holdingKeys.add('${path.branchId}/${path.productId}')) {
        throw const FormatException('duplicate stock');
      }
      final _StockData stock = _parseStock(document.data);
      _requireMatchingQuantity(product.quantitySpec, stock);
      holdings
          .putIfAbsent(path.productId, () => <CatalogHolding>[])
          .add(
            CatalogHolding(
              branchId: path.branchId,
              branchName: branchName,
              quantityScaled: stock.quantityScaled,
            ),
          );
    }

    final List<CatalogItem> items = products.values
        .map((CatalogProduct product) {
          final List<CatalogHolding> productHoldings =
              holdings[product.internalCode] ?? <CatalogHolding>[];
          productHoldings.sort(
            (CatalogHolding left, CatalogHolding right) =>
                left.branchId.compareTo(right.branchId),
          );
          return CatalogItem(product: product, holdings: productHoldings);
        })
        .toList(growable: false);
    _sortItems(items);
    return CatalogSnapshot(items, branchChoices: branchChoices);
  }

  Future<T> _readWithActiveSession<T>(Future<T> Function() read) async {
    await _requireActiveSession();
    final T result = await read();
    await _requireActiveSession();
    return result;
  }

  Future<void> _requireActiveSession() async {
    final EmulatorSession? active = await _sessionChecker();
    if (active == null ||
        active.userId != _session.userId ||
        active.role != _expectedRole ||
        active.role != _session.role ||
        active.branchId != _session.branchId) {
      throw const FormatException('catalog session is no longer active');
    }
  }
}

final RegExp _branchIdPattern = RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$');
const Set<String> _branchFields = <String>{'name', 'demoSeedVersion'};
const Set<String> _stockFields = <String>{
  'quantityScaled',
  'unit',
  'precision',
  'demoSeedVersion',
};

CatalogProduct _parseProduct(CatalogDocument document) {
  final List<String> segments = document.path.split('/');
  if (segments.length != 2 || segments.first != 'products') {
    throw const FormatException('product path is invalid');
  }
  final CatalogProduct product = CatalogProduct.fromFirestore(document.data);
  if (segments.last != product.internalCode) {
    throw const FormatException('product identity mismatch');
  }
  return product;
}

String _parseBranchPath(String path) {
  final List<String> segments = path.split('/');
  if (segments.length != 2 ||
      segments.first != 'branches' ||
      !_branchIdPattern.hasMatch(segments.last)) {
    throw const FormatException('branch path is invalid');
  }
  return segments.last;
}

String _parseBranch(Map<String, Object?> data) {
  _requireOnlyFields(data, _branchFields);
  final Object? name = data['name'];
  if (name is! String ||
      name.isEmpty ||
      name.length > 120 ||
      name.trim() != name ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
    throw const FormatException('branch name is invalid');
  }
  return name;
}

_StockPath _parseStockPath(String path) {
  final List<String> segments = path.split('/');
  if (segments.length != 4 ||
      segments[0] != 'branches' ||
      !_branchIdPattern.hasMatch(segments[1]) ||
      segments[2] != 'stock' ||
      !RegExp(r'^[A-Z][A-Z0-9-]{7,63}$').hasMatch(segments[3])) {
    throw const FormatException('stock path is invalid');
  }
  return _StockPath(branchId: segments[1], productId: segments[3]);
}

_StockData _parseStock(Map<String, Object?> data) {
  _requireOnlyFields(data, _stockFields);
  final Object? quantity = data['quantityScaled'];
  final QuantitySpec spec = QuantitySpec.fromFirestore(<String, Object?>{
    'unit': data['unit'],
    'precision': data['precision'],
  });
  if (quantity is! int || quantity < 0 || quantity > maxSafeScaledQuantity) {
    throw const FormatException('stock quantity is invalid');
  }
  return _StockData(
    quantityScaled: quantity,
    unit: spec.unit,
    precision: spec.precision,
  );
}

void _requireOnlyFields(Map<String, Object?> data, Set<String> fields) {
  if (data.keys.any((String key) => !fields.contains(key))) {
    throw const FormatException('document contains unsupported fields');
  }
}

void _requireMatchingQuantity(QuantitySpec product, _StockData stock) {
  if (product.unit != stock.unit || product.precision != stock.precision) {
    throw const FormatException('stock quantity specification mismatch');
  }
}

void _sortItems(List<CatalogItem> items) {
  items.sort(
    (CatalogItem left, CatalogItem right) =>
        left.product.name == right.product.name
        ? left.product.internalCode.compareTo(right.product.internalCode)
        : left.product.name.compareTo(right.product.name),
  );
}

class _StockPath {
  const _StockPath({required this.branchId, required this.productId});

  final String branchId;
  final String productId;
}

class _StockData {
  const _StockData({
    required this.quantityScaled,
    required this.unit,
    required this.precision,
  });

  final int quantityScaled;
  final String unit;
  final int precision;
}

class _PendingHolding {
  const _PendingHolding({
    required this.branchId,
    required this.productId,
    required this.data,
  });

  final String branchId;
  final String productId;
  final _StockData data;
}
