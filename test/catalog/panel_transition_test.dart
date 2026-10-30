// T9/S9: soft transitions between the catalog page body panels. A swap
// cross-fades with a short vertical settle; the panel that is leaving is
// silenced while it fades — no pointers, no semantics, no focus — so it can
// never act twice, answer a finder that matters, or hold stale focus.
// Rebuilding inside one panel never re-triggers the transition, and the first
// body shown after the catalog loads appears instantly.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/app/panel_transition.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';

import '../sales/sale_ui_fixtures.dart';

const String _branchId = 'branch-north';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: _branchId,
);

/// Records which panel answered a tap, in order.
final List<String> actions = <String>[];

Key tapKey(String identity) => ValueKey<String>('tap-$identity');

Finder panelAt(String identity) => find.byKey(tapKey(identity));

/// A panel of its own: a labelled semantic subtree, one action parked at
/// [tapAt] so two panels can differ in what occupies the same pixels, and an
/// optional field the test can give focus to.
Widget _panel(
  String identity, {
  String? text,
  Alignment tapAt = Alignment.topLeft,
  FocusNode? focusNode,
}) {
  return Semantics(
    label: 'panel-$identity',
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Align(
          alignment: tapAt,
          child: GestureDetector(
            key: tapKey(identity),
            behavior: HitTestBehavior.opaque,
            onTap: () => actions.add(identity),
            child: const SizedBox(width: 140, height: 48),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(text ?? identity),
              if (focusNode != null)
                TextField(
                  key: ValueKey<String>('field-$identity'),
                  focusNode: focusNode,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _transitionApp(String identity, Widget child) => MaterialApp(
  home: Scaffold(
    body: PanelTransition(identity: identity, child: child),
  ),
);

CatalogSnapshot _sellerSnapshot(int count) => CatalogSnapshot(<CatalogItem>[
  for (int i = 0; i < count; i++)
    CatalogItem(
      product: CatalogProduct(
        internalCode: 'TRANS-PROD-${i + 1}',
        name: 'Producto ${i + 1}',
        quantitySpec: const QuantitySpec(unit: 'kg', precision: 2),
        pricing: const CatalogPricing(
          listedPriceCentavos: 1000,
          currency: 'MXN',
          priceMode: 'iva-included',
          ivaTreatment: 'taxable',
          ivaRateBasisPoints: 1600,
        ),
      ),
      holdings: <CatalogHolding>[
        CatalogHolding(branchId: _branchId, quantityScaled: 100000),
      ],
    ),
]);

Widget _sellerApp(int items) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => _sellerSnapshot(items),
    onLogout: () async {},
    saleCheckout: FakeSaleCheckout().checkout,
  ),
);

void _useReducedMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Whether a real hit test at the centre of [finder] still reaches it: a
/// silenced panel must answer neither a tap nor a finder that acts on it.
bool _hittable(WidgetTester tester, Finder finder) {
  final RenderObject target = tester.renderObject(finder);
  final HitTestResult result = tester.hitTestOnBinding(
    tester.getCenter(finder),
  );
  return result.path.any((HitTestEntry entry) => entry.target == target);
}

void main() {
  setUp(() => actions.clear());

  testWidgets('a panel swap cross-fades with a short settle, then rests', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_transitionApp('a', _panel('a')));
    await tester.pumpAndSettle();
    // The first panel a transition presents is never animated.
    expect(tester.binding.transientCallbackCount, 0);
    final Offset resting = tester.getTopLeft(find.text('a'));

    await tester.pumpWidget(_transitionApp('b', _panel('b')));
    await tester.pump();

    // Both panels are on screen mid-swap, and the arriving one eases up from
    // a short distance below its resting place.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('b')).dy - resting.dy,
      moreOrLessEquals(PanelTransition.settleDistance, epsilon: 0.1),
    );

    expect(PanelTransition.duration, const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 175));
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    // Mid-fade both panels are visibly partial, not frozen until the end.
    double opacityOf(String text) => tester
        .widget<Opacity>(
          find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
        )
        .opacity;
    expect(opacityOf('b'), inExclusiveRange(0, 1));
    expect(opacityOf('a'), inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    expect(tester.getTopLeft(find.text('b')), resting);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the fading panel takes no taps', (WidgetTester tester) async {
    await tester.pumpWidget(_transitionApp('a', _panel('a')));
    await tester.pumpAndSettle();
    expect(_hittable(tester, panelAt('a')), isTrue);

    // The arriving panel has nothing where the old action was, so a tap there
    // may reach the fading panel or nothing at all.
    await tester.pumpWidget(
      _transitionApp('b', _panel('b', tapAt: Alignment.bottomLeft)),
    );
    await tester.pump();

    expect(find.text('a'), findsOneWidget);
    expect(_hittable(tester, panelAt('a')), isFalse);
    await tester.tap(panelAt('a'), warnIfMissed: false);
    await tester.pump();
    expect(actions, isEmpty);

    // The panel in front keeps acting, and once the fade rests the old one is
    // gone from the tree entirely.
    expect(_hittable(tester, panelAt('b')), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    await tester.tap(panelAt('b'));
    await tester.pump();
    expect(actions, <String>['b']);
  });

  testWidgets('the fading panel is out of the semantic tree', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_transitionApp('a', _panel('a')));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('panel-a')), findsOneWidget);

    await tester.pumpWidget(
      _transitionApp('b', _panel('b', tapAt: Alignment.bottomLeft)),
    );
    await tester.pump();

    // The first frame of the fade still paints the old panel at full opacity,
    // so only the exclusion can explain this: an accessibility client reads
    // nothing from the panel the user has already left.
    expect(find.text('a'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('panel-a')), findsNothing);

    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('panel-a')), findsNothing);
    expect(find.semantics.byLabel(RegExp('panel-b')), findsOneWidget);

    handle.dispose();
  });

  testWidgets('the fading panel never keeps focus', (
    WidgetTester tester,
  ) async {
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(_transitionApp('a', _panel('a', focusNode: node)));
    await tester.pumpAndSettle();
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);

    await tester.pumpWidget(
      _transitionApp('b', _panel('b', tapAt: Alignment.bottomLeft)),
    );
    await tester.pump();

    expect(find.text('a'), findsOneWidget);
    expect(node.hasFocus, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('rebuilding inside a panel does not re-animate it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_transitionApp('a', _panel('a', text: 'a-1')));
    await tester.pumpAndSettle();
    final Offset resting = tester.getTopLeft(find.text('a-1'));

    // Same identity, new content: an ordinary in-panel change.
    await tester.pumpWidget(_transitionApp('a', _panel('a', text: 'a-2')));
    await tester.pump();

    expect(find.text('a-2'), findsOneWidget);
    expect(find.text('a-1'), findsNothing);
    expect(tester.getTopLeft(find.text('a-2')), resting);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the transition never recreates the panel it shows', (
    WidgetTester tester,
  ) async {
    _ProbeState.created = 0;
    await tester.pumpWidget(_transitionApp('a', const _Probe(tag: 'a-1')));
    await tester.pumpAndSettle();
    expect(_ProbeState.created, 1);

    // Rebuilds under one identity keep the very same element and its state.
    await tester.pumpWidget(_transitionApp('a', const _Probe(tag: 'a-2')));
    await tester.pump();
    expect(_ProbeState.created, 1);
    expect(find.text('a-2'), findsOneWidget);
  });

  testWidgets('reduced motion swaps panels instantly', (
    WidgetTester tester,
  ) async {
    _useReducedMotion(tester);
    await tester.pumpWidget(_transitionApp('a', _panel('a')));
    await tester.pumpAndSettle();
    final Offset resting = tester.getTopLeft(find.text('a'));

    await tester.pumpWidget(
      _transitionApp('b', _panel('b', tapAt: Alignment.bottomLeft)),
    );
    await tester.pump();

    expect(find.text('a'), findsNothing);
    expect(tester.getTopLeft(find.text('b')), resting);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the catalog page cross-fades into a panel and back', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp(2));
    await tester.pumpAndSettle();
    expect(find.text('Catálogo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('sale-cart-button')));
    await tester.pump();

    // The catalog fades out under the cart instead of vanishing.
    expect(find.text('Carrito'), findsOneWidget);
    expect(find.text('Catálogo'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Catálogo'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
    await tester.pump();

    // "Volver" cross-fades back: the cart leaves, the catalog arrives.
    expect(find.text('Catálogo'), findsOneWidget);
    expect(find.text('Carrito'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Carrito'), findsNothing);
    expect(find.text('Catálogo'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the first catalog body never animates', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp(2));
    await tester.pump();

    // The list arrives in place of the loading indicator: the indicator is
    // gone in the same frame instead of fading, and nothing is animating.
    expect(find.text('Catálogo'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion opens a panel instantly on the page', (
    WidgetTester tester,
  ) async {
    _useReducedMotion(tester);
    await tester.pumpWidget(_sellerApp(2));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('sale-cart-button')));
    await tester.pump();

    expect(find.text('Carrito'), findsOneWidget);
    expect(find.text('Catálogo'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Método de pago'), findsOneWidget);
  });
}

/// Probe panel: counts how many times its element was created, so a
/// transition that rebuilt the panel instead of reusing it cannot pass.
class _Probe extends StatefulWidget {
  const _Probe({required this.tag});

  final String tag;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int created = 0;

  @override
  void initState() {
    super.initState();
    created += 1;
  }

  @override
  Widget build(BuildContext context) => Text(widget.tag);
}
