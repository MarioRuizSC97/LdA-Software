import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_search.dart';

const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Café Grano Selecto',
  quantitySpec: QuantitySpec(unit: 'pieza', precision: 0),
);

const CatalogProduct _water = CatalogProduct(
  internalCode: 'PRD-WATER-002',
  name: 'Agua Mineral 1 L',
  quantitySpec: QuantitySpec(unit: 'pieza', precision: 0),
);

const CatalogProduct _tea = CatalogProduct(
  internalCode: 'AUT-BRSM-777',
  name: 'Té Verde',
  quantitySpec: QuantitySpec(unit: 'gr', precision: 0),
);

List<CatalogProduct> _products() => <CatalogProduct>[_coffee, _water, _tea];

List<CatalogItem> _items() => <CatalogItem>[
  for (final CatalogProduct product in _products())
    CatalogItem(
      product: product,
      holdings: const <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 10),
      ],
    ),
];

class _Repository implements CatalogRepository {
  _Repository(this.products);

  final List<CatalogProduct> products;

  @override
  Future<List<CatalogProduct>> fetchProducts() async => products;
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Widget _catalogApp(CatalogRepository repository) =>
    MaterialApp(home: CatalogPage(repository: repository));

Widget _authenticatedApp() => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (EmulatorSession session) async =>
        CatalogSnapshot(_items(), branchChoices: const <CatalogBranchChoice>[]),
    onLogout: () async {},
  ),
);

Finder _searchField() => find.byKey(const ValueKey<String>('catalog-search'));

Finder _clearButton() =>
    find.byKey(const ValueKey<String>('catalog-search-clear'));

String _searchFieldValue(WidgetTester tester) {
  final EditableText editable = tester.widget<EditableText>(
    find.descendant(of: _searchField(), matching: find.byType(EditableText)),
  );
  return editable.controller.text;
}

Future<void> _type(WidgetTester tester, String value) async {
  await tester.enterText(_searchField(), value);
  await tester.pumpAndSettle();
}

void main() {
  group('catalog search matcher', () {
    test('empty and whitespace-only queries keep every product in order', () {
      final List<CatalogProduct> products = _products();

      expect(filterCatalogProducts(products, ''), products);
      expect(filterCatalogProducts(products, '   '), products);
      expect(
        filterCatalogItems(
          _items(),
          '',
        ).map((CatalogItem item) => item.product.internalCode).toList(),
        <String>['PRD-COFFEE-001', 'PRD-WATER-002', 'AUT-BRSM-777'],
      );
      expect(
        products.map((CatalogProduct p) => p.internalCode).toList(),
        <String>['PRD-COFFEE-001', 'PRD-WATER-002', 'AUT-BRSM-777'],
      );
    });

    test('matches the name ignoring case, accents and surrounding spaces', () {
      for (final String query in <String>[
        'cafe',
        '  CAFÉ  ',
        'Cafe Grano',
        'grano selecto',
        'select',
      ]) {
        expect(
          catalogProductMatchesQuery(_coffee, query),
          isTrue,
          reason: 'query "$query" must match "Café Grano Selecto"',
        );
      }

      expect(catalogProductMatchesQuery(_tea, 'te'), isTrue);
      expect(catalogProductMatchesQuery(_tea, 'té'), isTrue);
      expect(catalogProductMatchesQuery(_water, 'agua'), isTrue);
      expect(catalogProductMatchesQuery(_water, 'MINERAL 1'), isTrue);
      expect(catalogProductMatchesQuery(_coffee, 'agua'), isFalse);
      expect(catalogProductMatchesQuery(_coffee, 'verde'), isFalse);
    });

    test('matches the internal code, which is also the QR payload', () {
      expect(catalogProductMatchesQuery(_coffee, 'PRD-COFFEE-001'), isTrue);
      expect(catalogProductMatchesQuery(_coffee, 'prd-coffee-001'), isTrue);
      expect(catalogProductMatchesQuery(_coffee, 'COFFEE-001'), isTrue);
      expect(catalogProductMatchesQuery(_coffee, 'coffee'), isTrue);
      expect(catalogProductMatchesQuery(_tea, 'aut-brsm'), isTrue);
      expect(filterCatalogProducts(_products(), 'water-002'), <CatalogProduct>[
        _water,
      ]);
    });

    test('requires every term to match the same product name or code', () {
      expect(
        filterCatalogProducts(_products(), 'grano 002'),
        isEmpty,
        reason:
            'a term from one product and a term from another must not match',
      );
      expect(filterCatalogProducts(_products(), 'agua 002'), <CatalogProduct>[
        _water,
      ]);
      expect(filterCatalogProducts(_products(), 'zzz'), isEmpty);
      expect(
        _products().map((CatalogProduct p) => p.internalCode).toList(),
        <String>['PRD-COFFEE-001', 'PRD-WATER-002', 'AUT-BRSM-777'],
        reason: 'filtering must not mutate the input list',
      );
    });
  });

  group('catalog search field', () {
    testWidgets('is offered above the product list with an accessible label', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();

      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      expect(_searchField(), findsOneWidget);
      expect(
        find.bySemanticsLabel(catalogSearchLabel),
        findsOneWidget,
        reason: 'the search input must be announced by its visible label',
      );
      expect(_clearButton(), findsNothing);

      semantics.dispose();
    });

    testWidgets('filters the list by name as the seller types', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      await _type(tester, 'café');

      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
      expect(find.text('Té Verde'), findsNothing);
    });

    testWidgets('filters the list by product code', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      await _type(tester, 'brsm');

      expect(find.text('Té Verde'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
    });

    testWidgets('shows a no-results state instead of a blank catalog', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      await _type(tester, 'zebra');

      expect(find.textContaining('Sin resultados'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
      expect(find.text('Té Verde'), findsNothing);
    });

    testWidgets('clear restores every product and empties the field', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      await _type(tester, 'agua');
      expect(find.text('Café Grano Selecto'), findsNothing);
      expect(_clearButton(), findsOneWidget);

      await tester.tap(_clearButton());
      await tester.pumpAndSettle();

      expect(_searchFieldValue(tester), isEmpty);
      expect(_clearButton(), findsNothing);
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsOneWidget);
      expect(find.text('Té Verde'), findsOneWidget);
    });

    testWidgets('keeps the typed query across list rebuilds', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      await _type(tester, 'CAFE');
      await tester.pumpWidget(_catalogApp(_Repository(_products())));
      await tester.pumpAndSettle();

      expect(_searchFieldValue(tester), 'CAFE');
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
    });

    testWidgets('is available in the authenticated catalog used in store', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_authenticatedApp());
      await tester.pumpAndSettle();

      expect(_searchField(), findsOneWidget);

      await _type(tester, 'selecto');

      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
    });

    testWidgets('keeps the query and its results through a catalog reload', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_authenticatedApp());
      await tester.pumpAndSettle();

      await _type(tester, 'selecto');
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.refresh),
        ),
      );
      await tester.pumpAndSettle();

      expect(_searchFieldValue(tester), 'selecto');
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);
      expect(find.text('Té Verde'), findsNothing);
    });
  });
}
