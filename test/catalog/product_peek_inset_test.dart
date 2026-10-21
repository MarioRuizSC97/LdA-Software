// T9 review follow-up (R3-001): a keyboard inset taller than the screen (for
// example a short landscape window) must never give the detail peek a
// negative height; the card simply gets the space that is left.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/catalog/product_peek.dart';

void main() {
  testWidgets('a keyboard taller than the window does not break the peek', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(viewInsets: const EdgeInsets.only(bottom: 400)),
          child: child!,
        ),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showProductPeek(
              context: context,
              builder: (_) => const Text('Detalle'),
            ),
            child: const Text('Abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('product-peek-card')), findsOne);
  });

  testWidgets('without a keyboard the peek keeps its 88% height cap', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showProductPeek(
              context: context,
              builder: (_) => const SizedBox(height: 2000),
            ),
            child: const Text('Abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();

    final double height = tester
        .getSize(find.byKey(const ValueKey<String>('product-peek-card')))
        .height;
    expect(height, lessThanOrEqualTo(500 * .88));
    expect(tester.takeException(), isNull);
  });
}
