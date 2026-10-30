import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/smooth_scroll.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('wheel accumulates and clamps; reduced motion $reduced', (
      tester,
    ) async {
      late ScrollController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: SmoothScroll(
                builder: (context, scrollController) {
                  controller = scrollController;
                  return ListView.builder(
                    controller: controller,
                    itemExtent: 60,
                    itemCount: 50,
                    itemBuilder: (_, index) => Text('Row $index'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> wheel(
        double delta, {
        PointerDeviceKind kind = PointerDeviceKind.mouse,
      }) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(200, 200),
            scrollDelta: Offset(0, delta),
            kind: kind,
          ),
        );
      }

      await wheel(120);
      if (reduced) {
        expect(controller.offset, 120);
      } else {
        expect(controller.offset, 0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final first = controller.offset;
        expect(first, inExclusiveRange(0, 120));
        await wheel(120);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.offset, inExclusiveRange(first, 240));
      }
      await tester.pumpAndSettle();
      expect(controller.offset, reduced ? 120 : 240);
      await wheel(100000);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      await wheel(-100000);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      await wheel(40, kind: PointerDeviceKind.trackpad);
      expect(controller.offset, 40);
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(40));
    });
  }

  _touchPhysicsTests();
}

// T9G correction (review R3-001): finger scrolling on Android and iOS must be
// smoother too, not only the mouse wheel. Those platforms get the gentler
// bouncing glide; web and desktop keep their own platform physics.
void _touchPhysicsTests() {
  Future<ScrollPhysics> pumpList(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: SmoothScroll(
            builder: (context, controller) => ListView.builder(
              controller: controller,
              itemExtent: 60,
              itemCount: 50,
              itemBuilder: (_, index) => Text('Row $index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    return scrollable.position.physics;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform finger scrolling glides instead of stopping hard', (
      WidgetTester tester,
    ) async {
      final ScrollPhysics physics = await pumpList(tester, platform);
      expect(physics, isA<BouncingScrollPhysics>());
    });
  }

  // Web and desktop keep the framework's own physics for their platform.
  testWidgets('linux keeps its own platform physics', (
    WidgetTester tester,
  ) async {
    final ScrollPhysics physics = await pumpList(tester, TargetPlatform.linux);
    expect(physics, isA<ClampingScrollPhysics>());
  });

  testWidgets('a mobile fling keeps gliding for several frames', (
    WidgetTester tester,
  ) async {
    await pumpList(tester, TargetPlatform.android);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    await tester.fling(find.byType(ListView), const Offset(0, -300), 1200);
    await tester.pump();
    final double first = scrollable.position.pixels;
    await tester.pump(const Duration(milliseconds: 300));
    final double second = scrollable.position.pixels;
    expect(first, greaterThan(0));
    expect(second, greaterThan(first));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(second));
  });
}
