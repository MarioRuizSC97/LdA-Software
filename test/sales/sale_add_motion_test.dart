import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _mount(
  WidgetTester tester, {
  bool reduced = false,
  bool cart = false,
}) async {
  final controller = SaleCartController(checkout: FakeSaleCheckout().checkout);
  addTearDown(controller.dispose);
  if (cart) {
    controller.saveEntry(
      productId: pinProduct.internalCode,
      name: pinProduct.name,
      quantitySpec: pinProduct.quantitySpec,
      quantity: '1',
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: cart
              ? SaleCartPanel(controller: controller, onClose: () {})
              : SaleAddControl(controller: controller, product: pinProduct),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _ancestor(Finder child, Type type) =>
    find.ancestor(of: child, matching: find.byType(type)).first;

AnimatedSwitcher _switcher(WidgetTester tester, Finder child) =>
    tester.widget(_ancestor(child, AnimatedSwitcher));

void _expectEntrance(WidgetTester tester, Finder child, double direction) {
  expect(
    _switcher(tester, child).duration.inMilliseconds,
    inInclusiveRange(150, 200),
  );
  final slide = tester.widget<SlideTransition>(_ancestor(child, SlideTransition));
  expect(slide.position.value.dy * direction, greaterThan(0));
  expect(slide.position.value.dx, 0);
  final fade = tester.widget<FadeTransition>(_ancestor(child, FadeTransition));
  expect(fade.opacity.value, inExclusiveRange(0, 1));
}

void _expectSettled(WidgetTester tester, Finder child) {
  final slide = tester.widget<SlideTransition>(_ancestor(child, SlideTransition));
  final fade = tester.widget<FadeTransition>(_ancestor(child, FadeTransition));
  expect(slide.position.value, Offset.zero);
  expect(fade.opacity.value, 1);
}

void _expectReduced(WidgetTester tester) {
  expect(
    tester
        .widgetList<AnimatedSwitcher>(find.byType(AnimatedSwitcher))
        .every((swap) => swap.duration == Duration.zero),
    isTrue,
  );
  for (final slide in tester.widgetList<SlideTransition>(
    find.descendant(
      of: find.byType(SaleAddControl),
      matching: find.byType(SlideTransition),
    ),
  )) {
    expect(slide.position.value, Offset.zero);
  }
}

Future<void> _change(WidgetTester tester, String action) async {
  await tester.tap(_key('sale-line-$action-DEMO-PIN'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
}

void main() {
  testWidgets('Agregar enters the stepper with an upward slide and fade', (
    tester,
  ) async {
    await _mount(tester);
    _expectSettled(tester, _key('sale-add-DEMO-PIN'));
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final stepper = find.byType(SaleLineStepper);
    _expectEntrance(tester, stepper, 1);
    final outgoing = _key('sale-add-DEMO-PIN');
    expect(
      tester.widget<IgnorePointer>(_ancestor(outgoing, IgnorePointer)).ignoring,
      isTrue,
    );
    expect(
      tester.widget<ExcludeFocus>(_ancestor(outgoing, ExcludeFocus)).excluding,
      isTrue,
    );
    expect(
      tester
          .widget<ExcludeSemantics>(_ancestor(outgoing, ExcludeSemantics))
          .excluding,
      isTrue,
    );
    expect(
      tester
          .widget<SlideTransition>(_ancestor(outgoing, SlideTransition))
          .position
          .value,
      Offset.zero, // Only fades: no outgoing slide.
    );
    await tester.pumpAndSettle();
    expect(outgoing, findsNothing);
    _expectSettled(tester, stepper);
  });

  testWidgets('quantity slides up on plus and down on minus', (tester) async {
    await _mount(tester);
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pumpAndSettle();
    await _change(tester, 'increment');
    _expectEntrance(tester, _key('sale-quantity-value-DEMO-PIN-2'), 1);
    await tester.pumpAndSettle();
    await _change(tester, 'decrement');
    _expectEntrance(tester, _key('sale-quantity-value-DEMO-PIN-1'), -1);
    await tester.pumpAndSettle();
    _expectSettled(tester, _key('sale-quantity-value-DEMO-PIN-1'));
  });

  for (final cart in [false, true]) {
    testWidgets(
      'entry commit animates the number in either direction${cart ? ' in cart' : ''}',
      (tester) async {
        await _mount(tester, cart: cart);
        if (!cart) {
          await tester.tap(_key('sale-add-DEMO-PIN'));
          await tester.pumpAndSettle();
        }
        for (final value in ['4', '2']) {
          await tester.tap(_key('sale-line-edit-DEMO-PIN'));
          await tester.pumpAndSettle();
          expect(find.byType(SaleLineStepper), findsNothing);
          if (!cart) {
            expect(
              _switcher(tester, _key('sale-quantity-DEMO-PIN')).duration,
              Duration.zero,
            );
          }
          await tester.enterText(_key('sale-quantity-DEMO-PIN'), value);
          await tester.tap(_key('sale-entry-save-DEMO-PIN'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(_key('sale-quantity-DEMO-PIN'), findsNothing);
          final number = _key('sale-quantity-value-DEMO-PIN-$value');
          _expectEntrance(tester, number, value == '4' ? 1 : -1);
          await tester.pumpAndSettle();
          _expectSettled(tester, number);
        }
        await tester.tap(_key('sale-line-edit-DEMO-PIN'));
        await tester.pumpAndSettle();
        await tester.tap(_key('sale-entry-cancel-DEMO-PIN'));
        await tester.pump();
        _expectSettled(tester, _key('sale-quantity-value-DEMO-PIN-2'));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('reduced motion makes control and quantity swaps instant', (
    tester,
  ) async {
    await _mount(tester, reduced: true);
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pumpAndSettle();
    expect(
      _switcher(tester, find.byType(SaleLineStepper)).duration,
      Duration.zero,
    );
    for (final action in ['increment', 'decrement']) {
      await _change(tester, action);
      _expectReduced(tester);
      expect(find.text(action == 'increment' ? '2' : '1'), findsOneWidget);
    }
    await tester.tap(_key('sale-line-edit-DEMO-PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '5');
    await tester.tap(_key('sale-entry-save-DEMO-PIN'));
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    _expectReduced(tester);
  });
}
