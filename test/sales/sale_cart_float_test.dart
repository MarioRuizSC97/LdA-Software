import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

const _buttonKey = ValueKey<String>('sale-cart-button');
const _summary = 'Carrito · 2 piece · 5.00 MXN';

void main() {
  Future<SaleCartController> mount(
    WidgetTester tester, {
    bool disableAnimations = false,
    double width = 800,
    double textScale = 1,
    VoidCallback? onPressed,
  }) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SaleCartController(
      checkout: FakeSaleCheckout().checkout,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          floatingActionButton: SaleCartButton(
            controller: controller,
            onPressed: onPressed ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  void addItems(SaleCartController controller) => controller.saveEntry(
    productId: pinProduct.internalCode,
    name: pinProduct.name,
    quantitySpec: pinProduct.quantitySpec,
    quantity: '2',
  );

  testWidgets('empty cart is a bottom-right icon-only circle and opens', (
    tester,
  ) async {
    var opened = 0;
    await mount(tester, onPressed: () => opened++);
    final rect = tester.getRect(find.byKey(_buttonKey));
    expect(rect.size, const Size(56, 56));
    expect(rect.center.dx, greaterThan(400));
    expect(rect.center.dy, greaterThan(300));
    expect(rect.right, 784);
    expect(rect.bottom, 584);
    expect(find.text('Carrito vacío'), findsNothing);
    expect(
      find.bySemanticsLabel('Abrir carrito. Carrito vacío'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(_buttonKey));
    expect(opened, 1);
  });

  testWidgets('pill preserves exact summary, height, right edge and callback', (
    tester,
  ) async {
    var opened = 0;
    final controller = await mount(tester, onPressed: () => opened++);
    final empty = tester.getRect(find.byKey(_buttonKey));
    final emptySize = tester.getSize(find.byKey(_buttonKey));
    addItems(controller);
    await tester.pumpAndSettle();
    final pill = tester.getRect(find.byKey(_buttonKey));
    expect(pill.width, greaterThan(pill.height));
    expect(pill.width, lessThanOrEqualTo(720));
    expect(tester.getSize(find.byKey(_buttonKey)).height, emptySize.height);
    expect(pill.right, closeTo(empty.right, 1e-9));
    expect(pill.bottom, closeTo(empty.bottom, 1e-9));
    expect(find.text(_summary), findsOneWidget);
    await tester.tap(find.byKey(_buttonKey));
    expect(opened, 1);
    // Measured geometry is included in the implementation handoff.
    debugPrint('Cart sizes: empty=${empty.size}, pill=${pill.size}');
    controller.remove(pinProduct.internalCode);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_buttonKey)), empty);
  });

  testWidgets('width and label transitions respect reduced motion', (
    tester,
  ) async {
    final controller = await mount(tester, disableAnimations: true);
    addItems(controller);
    await tester.pump();
    await tester.pump();
    final control = find.byType(SaleCartButton);
    final sizes = tester.widgetList<AnimatedSize>(
      find.descendant(of: control, matching: find.byType(AnimatedSize)),
    );
    expect(sizes, isNotEmpty);
    expect(sizes.every((widget) => widget.duration == Duration.zero), isTrue);
    final labels = tester.widgetList<AnimatedSwitcher>(
      find.descendant(of: control, matching: find.byType(AnimatedSwitcher)),
    );
    expect(labels, isNotEmpty);
    expect(labels.every((widget) => widget.duration == Duration.zero), isTrue);
    final size = tester.getSize(find.byKey(_buttonKey));
    await tester.pump(const Duration(milliseconds: 125));
    expect(tester.getSize(find.byKey(_buttonKey)), size);
  });

  testWidgets('normal motion animates leftward without changing height', (
    tester,
  ) async {
    final controller = await mount(tester);
    addItems(controller);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final middle = tester.getRect(find.byKey(_buttonKey));
    expect(tester.getSize(find.byKey(_buttonKey)).height, 56);
    expect(middle.right, closeTo(784, 1e-9));
    await tester.pumpAndSettle();
    expect(middle.width, greaterThan(56));
    expect(
      middle.width,
      lessThan(tester.getSize(find.byKey(_buttonKey)).width),
    );
  });

  testWidgets('narrow viewport and large text ellipsize within the cap', (
    tester,
  ) async {
    final controller = await mount(tester, width: 320, textScale: 2);
    addItems(controller);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(_buttonKey)).width,
      lessThanOrEqualTo(288),
    );
    expect(tester.getSize(find.byKey(_buttonKey)).height, 56);
    final text = tester.widget<Text>(find.text(_summary));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
