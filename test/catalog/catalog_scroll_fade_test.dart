// T9/S10: fade edges over the catalog product list. The list melts into the
// page background at the edge that still has content behind it — a bottom edge
// while more products lie below, a slimmer top edge once the seller has
// scrolled — and there is no edge at all over a list that fits. The edges are
// static paint: they never take a tap, never reach the semantics tree, and
// never move a card, change the scroll extent, or add a key.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_scroll_fade.dart';
import 'package:lda_inventory/catalog/catalog_search.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';

import '../sales/sale_ui_fixtures.dart';
import '../support/viewport.dart';

const Size _box = Size(360, 600);
const double _itemHeight = 60;

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Key itemKey(int index) => ValueKey<String>('fade-item-$index');

final Finder bottomEdge = find.byKey(catalogScrollFadeBottomKey);
final Finder topEdge = find.byKey(catalogScrollFadeTopKey);

List<int> tapped = <int>[];

Widget _list(int count) => ListView.builder(
  itemCount: count,
  itemBuilder: (BuildContext context, int index) => GestureDetector(
    key: itemKey(index),
    behavior: HitTestBehavior.opaque,
    onTap: () => tapped.add(index),
    child: const SizedBox(height: _itemHeight),
  ),
);

Widget _app(Widget body) => MaterialApp(
  theme: buildInventoryTheme(),
  home: Scaffold(body: body),
);

Widget _faded(
  int count, {
  double topExtent = CatalogScrollFade.defaultTopExtent,
  double bottomExtent = CatalogScrollFade.defaultBottomExtent,
}) => _app(
  SizedBox.expand(
    child: CatalogScrollFade(
      topExtent: topExtent,
      bottomExtent: bottomExtent,
      child: _list(count),
    ),
  ),
);

Finder itemFinder(int index) => find.byKey(itemKey(index));

double _top(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;

double _bottom(WidgetTester tester, Finder finder) =>
    tester.getBottomLeft(finder).dy;

/// Whether a real hit test at [point] still reaches [finder] underneath.
bool _reaches(WidgetTester tester, Offset point, Finder finder) {
  final RenderObject target = tester.renderObject(finder);
  return tester
      .hitTestOnBinding(point)
      .path
      .any((HitTestEntry entry) => entry.target == target);
}

/// Whether a real hit test at the centre of [finder] still reaches it.
bool _hittable(WidgetTester tester, Finder finder) =>
    _reaches(tester, tester.getCenter(finder), finder);

LinearGradient _edgeGradient(WidgetTester tester, Finder edge) {
  final DecoratedBox box = tester.widget<DecoratedBox>(
    find.descendant(of: edge, matching: find.byType(DecoratedBox)),
  );
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

void _scrollTo(WidgetTester tester, double offset) {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(offset);
}

CatalogSnapshot _sellerSnapshot(int count) => CatalogSnapshot(<CatalogItem>[
  for (int i = 1; i <= count; i++)
    CatalogItem(
      product: CatalogProduct(
        internalCode: 'FADE-PROD-$i',
        name: 'Producto $i',
        quantitySpec: const QuantitySpec(unit: 'kg', precision: 2),
        pricing: const CatalogPricing(
          listedPriceCentavos: 1000,
          currency: 'MXN',
          priceMode: 'iva-included',
          ivaTreatment: 'taxable',
          ivaRateBasisPoints: 1600,
        ),
      ),
      holdings: const <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 100000),
      ],
    ),
]);

Widget _catalogApp(int items) => MaterialApp(
  theme: buildInventoryTheme(),
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => _sellerSnapshot(items),
    onLogout: () async {},
    saleCheckout: FakeSaleCheckout().checkout,
  ),
);

/// Reaches for the last card the fade band lies over: the band must be paint
/// only, so the hit keeps going down into the card and a real long press still
/// opens its details.
Future<void> _tapCardUnderTheEdge(WidgetTester tester) async {
  final Rect band = tester.getRect(bottomEdge);
  for (int i = 1; i <= 12; i++) {
    final Finder card = find.byKey(
      ValueKey<String>('product-card-FADE-PROD-$i'),
    );
    if (card.evaluate().isEmpty) continue;
    final Rect overlap = band.intersect(tester.getRect(card));
    if (overlap.height < 8) continue;
    final String code = 'FADE-PROD-$i';

    expect(_hittable(tester, bottomEdge), isFalse);
    expect(_reaches(tester, overlap.center, card), isTrue);

    await tester.longPressAt(overlap.center);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey<String>('product-sheet-$code')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('product-sheet-close')));
    await tester.pumpAndSettle();
    return;
  }
  fail('no product card lies under the fade band: $band');
}

void main() {
  setUp(() => tapped = <int>[]);

  testWidgets('an overflowing list keeps a bottom edge', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(20));
    await tester.pumpAndSettle();

    expect(bottomEdge, findsOneWidget);
    expect(topEdge, findsNothing);
    expect(
      tester.getSize(bottomEdge).height,
      CatalogScrollFade.defaultBottomExtent,
    );
    expect(_bottom(tester, bottomEdge), _box.height);
  });

  testWidgets('the edge moves to the top once the list is scrolled down', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(20));
    await tester.pumpAndSettle();

    _scrollTo(tester, 180);
    await tester.pumpAndSettle();

    expect(topEdge, findsOneWidget);
    expect(tester.getSize(topEdge).height, CatalogScrollFade.defaultTopExtent);
    expect(_top(tester, topEdge), 0);
    expect(bottomEdge, findsOneWidget);

    // At the very end of the list there is nothing left to fade below.
    _scrollTo(tester, 20 * _itemHeight - _box.height);
    await tester.pumpAndSettle();

    expect(bottomEdge, findsNothing);
    expect(topEdge, findsOneWidget);
  });

  testWidgets('a list that fits shows no edge', (WidgetTester tester) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(6));
    await tester.pumpAndSettle();

    expect(bottomEdge, findsNothing);
    expect(topEdge, findsNothing);
  });

  testWidgets('a card under the bottom edge still takes the tap', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(20));
    await tester.pumpAndSettle();

    // Item 9 reaches into the band: its centre is inside the faded region.
    final Finder item = itemFinder(9);
    expect(tester.getRect(bottomEdge).contains(tester.getCenter(item)), isTrue);
    expect(_hittable(tester, bottomEdge), isFalse);
    await tester.tap(item);
    await tester.pump();
    expect(tapped, <int>[9]);
  });

  testWidgets('a card under the top edge still takes the tap', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(20, topExtent: 96));
    await tester.pumpAndSettle();

    _scrollTo(tester, 180);
    await tester.pumpAndSettle();

    final Finder item = itemFinder(3);
    expect(tester.getRect(topEdge).contains(tester.getCenter(item)), isTrue);
    expect(_hittable(tester, topEdge), isFalse);
    await tester.tap(item);
    await tester.pump();
    expect(tapped, <int>[3]);
  });

  testWidgets('the edges fade to the page background, not to white', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);
    await tester.pumpWidget(_faded(20));
    await tester.pumpAndSettle();

    final Color background = Theme.of(tester.element(find.byType(ListView)))
        .scaffoldBackgroundColor;
    expect(background, const Color(0xFFF6F7F9));
    expect(background, isNot(Colors.white));

    final LinearGradient bottom = _edgeGradient(tester, bottomEdge);
    expect(bottom.colors.first, background.withValues(alpha: 0));
    expect(bottom.colors.last, background);
    expect(bottom.begin, Alignment.topCenter);
    expect(bottom.end, Alignment.bottomCenter);

    _scrollTo(tester, 180);
    await tester.pumpAndSettle();
    final LinearGradient top = _edgeGradient(tester, topEdge);
    expect(top.colors.first, background.withValues(alpha: 0));
    expect(top.colors.last, background);
    expect(top.begin, Alignment.bottomCenter);
    expect(top.end, Alignment.topCenter);
  });

  testWidgets('the fade leaves the list layout and its extent untouched', (
    WidgetTester tester,
  ) async {
    useViewport(tester, _box);

    await tester.pumpWidget(_app(SizedBox.expand(child: _list(20))));
    await tester.pumpAndSettle();
    final Rect plainList = tester.getRect(find.byType(ListView));
    final Rect plainCard = tester.getRect(find.byKey(itemKey(4)));
    _scrollTo(tester, 120);
    await tester.pumpAndSettle();
    final Rect plainScrolled = tester.getRect(itemFinder(4));

    await tester.pumpWidget(_faded(20));
    _scrollTo(tester, 0);
    await tester.pumpAndSettle();

    // The same cards at the same places, and the same scroll travel.
    expect(tester.getRect(find.byType(ListView)), plainList);
    expect(tester.getRect(find.byKey(itemKey(4))), plainCard);
    _scrollTo(tester, 120);
    await tester.pumpAndSettle();
    expect(tester.getRect(itemFinder(4)), plainScrolled);
    expect(tapped, isEmpty);
  });

  testWidgets('the catalog page fades its list without eating card taps', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_catalogApp(12));
    await tester.pumpAndSettle();

    expect(bottomEdge, findsOneWidget);
    expect(topEdge, findsNothing);
    await _tapCardUnderTheEdge(tester);

    // The search field stays reachable while the band is on screen.
    await tester.tap(find.byKey(catalogSearchFieldKey));
    await tester.enterText(find.byKey(catalogSearchFieldKey), 'Producto 1');
    await tester.pumpAndSettle();
    expect(find.text('Producto 2'), findsNothing);

    // The cart bar under the band still answers, next to the faded list.
    await tester.tap(find.byKey(const ValueKey<String>('sale-cart-button')));
    await tester.pumpAndSettle();
    expect(find.text('Carrito'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a filtered catalog that fits loses its edge', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_catalogApp(12));
    await tester.pumpAndSettle();
    expect(bottomEdge, findsOneWidget);

    await tester.enterText(find.byKey(catalogSearchFieldKey), 'Producto 10');
    await tester.pumpAndSettle();

    expect(find.text('Producto 10'), findsWidgets);
    expect(find.text('Producto 11'), findsNothing);
    expect(bottomEdge, findsNothing);
    expect(topEdge, findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the edges hold at 360 px and text scale 2', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(360, 640), 2);
    await tester.pumpWidget(_catalogApp(12));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(bottomEdge, findsOneWidget);
    expect(_bottom(tester, bottomEdge), lessThanOrEqualTo(640));
    await _tapCardUnderTheEdge(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
