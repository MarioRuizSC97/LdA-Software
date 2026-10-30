import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/primary_action_style.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('primary action style $brightness', (tester) async {
      final theme = brightness == Brightness.light
          ? buildInventoryTheme()
          : buildDarkInventoryTheme();
      ButtonStyle? style;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              style = primaryActionStyle(context);
              return const SizedBox();
            },
          ),
        ),
      );
      if (brightness == Brightness.dark) {
        expect(style, isNull);
        return;
      }
      final colors = theme.colorScheme;
      for (final states in [
        <WidgetState>{},
        {WidgetState.disabled},
        {WidgetState.hovered},
        {WidgetState.focused},
        {WidgetState.pressed},
      ]) {
        final fill = style!.backgroundColor!.resolve(states)!;
        final text = style!.foregroundColor!.resolve(states)!;
        expect(fill, colors.primaryContainer);
        if (!states.contains(WidgetState.disabled)) {
          expect(text, colors.onPrimaryContainer);
        }
        expect(_contrast(fill, text), greaterThanOrEqualTo(4.5));
      }
      expect(style!.fixedSize, isNull);
      expect(style!.minimumSize, isNull);
      expect(style!.padding, isNull);
      expect(style!.shape, isNull);
      // Keep the measured palette in the test transcript.
      debugPrint(
        'Light fill=${colors.primaryContainer.toARGB32().toRadixString(16)} '
        'text=${colors.onPrimaryContainer.toARGB32().toRadixString(16)} '
        'contrast=${_contrast(colors.primaryContainer, colors.onPrimaryContainer)} '
        'disabled=${_contrast(colors.primaryContainer, colors.onSurfaceVariant)}',
      );
    });
  }
}
