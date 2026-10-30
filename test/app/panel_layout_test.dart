import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/panel_layout.dart';

const _primaryKey = ValueKey<String>('primary');
const _contextKey = ValueKey<String>('context');

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  Widget primary = const SizedBox(
    key: _primaryKey,
    width: double.infinity,
    height: 100,
  ),
  Widget? rail = const SizedBox(key: _contextKey, height: 200),
  bool disableAnimations = false,
  double maxPrimaryWidth = 600,
  double maxContextWidth = 340,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: PanelLayout(
            primary: primary,
            context: rail,
            maxPrimaryWidth: maxPrimaryWidth,
            maxContextWidth: maxContextWidth,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('compact keeps the existing form padding and width unchanged', (
    WidgetTester tester,
  ) async {
    // The existing Crear producto form owns this padding and width cap.
    final baseline = SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: const SizedBox(
            key: _primaryKey,
            width: double.infinity,
            height: 100,
          ),
        ),
      ),
    );
    await _pump(tester, width: 400, primary: baseline);
    expect(find.byKey(_contextKey), findsNothing);
    expect(
      tester.getRect(find.byKey(_primaryKey)),
      const Rect.fromLTWH(20, 20, 360, 100),
    );
    expect(
      tester.widget<PanelLayout>(find.byType(PanelLayout)).primary,
      same(baseline),
    );
  });

  testWidgets('wide centers capped columns, primary first, with declared gap', (
    WidgetTester tester,
  ) async {
    await _pump(tester, width: 1200);
    final primary = tester.getRect(find.byKey(_primaryKey));
    final rail = tester.getRect(find.byKey(_contextKey));
    expect(primary.width, 600);
    expect(rail.width, 340);
    expect(rail.left - primary.right, panelColumnGap);
    expect(primary.top, rail.top);
    expect(primary.left, 1200 - rail.right);
    expect(primary.left, greaterThanOrEqualTo(panelHorizontalPadding));
  });

  testWidgets('wide starts exactly at the catalog-family breakpoint', (
    WidgetTester tester,
  ) async {
    expect(panelWideBreakpoint, 600);
    await _pump(tester, width: panelWideBreakpoint - 1);
    expect(find.byKey(_contextKey), findsNothing);
    await _pump(tester, width: panelWideBreakpoint);
    expect(find.byKey(_contextKey), findsOneWidget);
    expect(
      tester.getRect(find.byKey(_primaryKey)).right,
      lessThan(tester.getRect(find.byKey(_contextKey)).left),
    );
  });

  for (final width in <double>[400, 601, 800, 1200]) {
    testWidgets('no overflow with long context at width $width', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width: width,
        rail: const SizedBox(key: _contextKey, height: 2400),
      );
      expect(tester.takeException(), isNull);
      if (width >= panelWideBreakpoint) {
        final primaryBefore = tester.getRect(find.byKey(_primaryKey));
        final scroll = find.ancestor(
          of: find.byKey(_contextKey),
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget);
        expect(tester.getSize(scroll).height, lessThanOrEqualTo(800));
        await tester.drag(scroll, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byKey(_contextKey)).dy, lessThan(0));
        expect(tester.getRect(find.byKey(_primaryKey)), primaryBefore);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('reduced motion does not change compact or wide geometry', (
    WidgetTester tester,
  ) async {
    for (final width in <double>[400, 1200]) {
      await _pump(tester, width: width);
      final primary = tester.getRect(find.byKey(_primaryKey));
      final rail = width >= panelWideBreakpoint
          ? tester.getRect(find.byKey(_contextKey))
          : null;
      await _pump(tester, width: width, disableAnimations: true);
      expect(tester.getRect(find.byKey(_primaryKey)), primary);
      if (rail != null) {
        expect(tester.getRect(find.byKey(_contextKey)), rail);
      } else {
        expect(find.byKey(_contextKey), findsNothing);
      }
    }
  });

  testWidgets('an omitted context preserves primary even on wide screens', (
    WidgetTester tester,
  ) async {
    await _pump(tester, width: 1200, rail: null);
    expect(tester.getSize(find.byKey(_primaryKey)).width, 1200);
    expect(find.byType(Row), findsNothing);
  });

  testWidgets('custom maximum widths keep their ratio when space is limited', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      width: 1200,
      maxPrimaryWidth: 560,
      maxContextWidth: 320,
    );
    expect(tester.getSize(find.byKey(_primaryKey)).width, 560);
    expect(tester.getSize(find.byKey(_contextKey)).width, 320);
    await _pump(tester, width: 800, maxPrimaryWidth: 560, maxContextWidth: 320);
    final primary = tester.getRect(find.byKey(_primaryKey));
    final rail = tester.getRect(find.byKey(_contextKey));
    expect(primary.width / rail.width, closeTo(560 / 320, 0.001));
    expect(primary.left, panelHorizontalPadding);
    expect(rail.right, 800 - panelHorizontalPadding);
    expect(tester.takeException(), isNull);
  });
}
