// T9/S4: shared restrained light theme. Neutral very light gray scaffold,
// white card surfaces, blue reserved for primary actions, subtle borders
// instead of strong shadows.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/app/inventory_theme.dart';

double _luminanceOf(Color color) => color.computeLuminance();

bool _blueDominant(Color color) => color.b >= color.r && color.b >= color.g;

void main() {
  test('the scaffold background is a very light neutral gray, not white', () {
    final ThemeData theme = buildInventoryTheme();

    final Color background = theme.scaffoldBackgroundColor;
    expect(background, isNot(Colors.white));
    // Very light: readable, soft, clearly not the card surface.
    expect(_luminanceOf(background), greaterThan(0.92));
    expect(_luminanceOf(background), lessThan(0.98));
    // Neutral: channels nearly equal, so no saturated tint.
    expect(
      ((background.r - background.g).abs() +
              (background.g - background.b).abs()) *
          255,
      lessThan(12),
    );
  });

  test('card surfaces are white with no elevation and a subtle border', () {
    final ThemeData theme = buildInventoryTheme();

    expect(theme.cardTheme.color, Colors.white);
    expect(theme.cardTheme.elevation, 0);
    final ShapeBorder? shape = theme.cardTheme.shape;
    expect(shape, isA<RoundedRectangleBorder>());
    final RoundedRectangleBorder rounded = shape! as RoundedRectangleBorder;
    expect(rounded.side.style, BorderStyle.solid);
    expect(rounded.side.width, greaterThan(0));
    // Subtle: a hairline far lighter than the on-surface ink.
    expect(_luminanceOf(rounded.side.color), greaterThan(0.8));
  });

  test('the primary accent stays blue for important actions', () {
    final ThemeData theme = buildInventoryTheme();

    expect(
      theme.colorScheme.brightness,
      Brightness.light,
      reason: 'the restrained theme is light',
    );
    expect(_blueDominant(theme.colorScheme.primary), isTrue);
  });

  testWidgets('a card paints white on the gray scaffold under the theme', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInventoryTheme(),
        home: const Scaffold(body: Card(child: SizedBox(height: 40))),
      ),
    );
    await tester.pumpAndSettle();

    final Material cardMaterial = tester.widget<Material>(
      find
          .descendant(of: find.byType(Card), matching: find.byType(Material))
          .first,
    );
    expect(cardMaterial.color, Colors.white);

    final ThemeData theme = Theme.of(tester.element(find.byType(Card)));
    expect(theme.scaffoldBackgroundColor, isNot(Colors.white));
    expect(tester.takeException(), isNull);
  });
}
