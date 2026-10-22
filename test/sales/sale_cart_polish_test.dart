import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<SaleCartController> _mount(
  WidgetTester tester, {
  double width = 400,
  String quantity = '2',
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = SaleCartController(checkout: FakeSaleCheckout().checkout);
  addTearDown(controller.dispose);
  controller.saveEntry(
    productId: pinProduct.internalCode,
    name: pinProduct.name,
    quantitySpec: pinProduct.quantitySpec,
    quantity: quantity,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: SaleCartPanel(controller: controller, onClose: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  for (final quantity in <String>['1', '2']) {
    testWidgets('400px cart quantity $quantity has 40px hit targets', (
      tester,
    ) async {
      await _mount(tester, quantity: quantity);
      final sizes = <String, Size>{};
      for (final action in <String>[
        if (quantity != '1') 'decrement',
        'edit',
        'increment',
        'remove',
      ]) {
        final control = _key('sale-line-$action-DEMO-PIN');
        final rect = tester.getRect(control);
        sizes[action] = rect.size;
        debugPrint('400px quantity=$quantity $action: ${rect.size}');
        expect(rect.width, greaterThanOrEqualTo(40), reason: action);
        expect(rect.height, greaterThanOrEqualTo(40), reason: action);
        for (final alignment in <Alignment>[
          const Alignment(-.95, -.95),
          const Alignment(.95, .95),
        ]) {
          expect(control.hitTestable(at: alignment), findsOneWidget);
        }
      }
      expect(sizes, isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in <double>[400, 1200]) {
    testWidgets('cart is top aligned with 16px padding at width $width', (
      tester,
    ) async {
      await _mount(tester, width: width);
      final scroll = find.descendant(
        of: find.byType(SaleCartPanel),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getTopLeft(scroll).dy, 0);
      expect(
        tester.widget<SingleChildScrollView>(scroll).padding,
        const EdgeInsets.fromLTRB(16, 16, 16, 24),
      );
      final lineTop = tester.getTopLeft(_key('sale-line-DEMO-PIN')).dy;
      debugPrint('width=$width first cart line y=$lineTop');
      // The tonal action wraps below the title on mobile; preserve that
      // accessible header rather than squeezing it into a single row.
      expect(lineTop, width == 400 ? 108 : 76);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Seguir vendiendo uses the secondary tonal filled action', (
    tester,
  ) async {
    await _mount(tester);
    final action = _key('sale-close-cart');
    expect(action, findsOneWidget);
    expect(tester.widget(action), isA<FilledButton>());
    expect(
      find.descendant(of: action, matching: find.text('Seguir vendiendo')),
      findsOneWidget,
    );
    final context = tester.element(action);
    final button = tester.widget<FilledButton>(action);
    final style = button.defaultStyleOf(context);
    expect(
      style.backgroundColor!.resolve(<WidgetState>{}),
      Theme.of(context).colorScheme.secondaryContainer,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('payment chips match the 24px capsule radius in $brightness', (
      tester,
    ) async {
      await _mount(tester, brightness: brightness);
      final capsule = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(SaleLineStepper),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.borderRadius != null);
      final reference = (capsule.borderRadius! as BorderRadius).topLeft.x;
      expect(reference, 24);
      for (final method in <String>['cash', 'card', 'transfer']) {
        final shape = tester
            .widgetList<Material>(
              find.descendant(
                of: _key('sale-payment-$method'),
                matching: find.byType(Material),
              ),
            )
            .map((material) => material.shape)
            .whereType<RoundedRectangleBorder>()
            .single;
        final radius = shape.borderRadius.resolve(TextDirection.ltr);
        for (final corner in <Radius>[
          radius.topLeft,
          radius.topRight,
          radius.bottomLeft,
          radius.bottomRight,
        ]) {
          expect(corner.x, greaterThanOrEqualTo(reference));
          expect(corner.y, greaterThanOrEqualTo(reference));
        }
      }
    });
  }
}
