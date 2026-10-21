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
}
