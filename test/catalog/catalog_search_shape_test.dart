import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_search.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    group('catalog search in ${brightness.name} mode', () {
      Future<void> pumpField(WidgetTester tester) async {
        final TextEditingController controller = TextEditingController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: CatalogSearchField(
                controller: controller,
                onChanged: (_) {},
                onClear: controller.clear,
              ),
            ),
          ),
        );
      }

      testWidgets('uses only the hint, keeping dense layout and search icon', (
        WidgetTester tester,
      ) async {
        await pumpField(tester);
        final InputDecoration decoration = tester
            .widget<TextField>(find.byKey(catalogSearchFieldKey))
            .decoration!;

        expect(decoration.labelText, isNull);
        expect(decoration.label, isNull);
        expect(decoration.hintText, 'Nombre o código');
        expect(decoration.isDense, isTrue);
        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(find.text('Buscar por nombre o código'), findsNothing);
      });

      testWidgets('has a generous circular outline in resting and focus states', (
        WidgetTester tester,
      ) async {
        await pumpField(tester);
        for (final bool focused in <bool>[false, true]) {
          if (focused) {
            await tester.tap(find.byKey(catalogSearchFieldKey));
            await tester.pumpAndSettle();
          }
          final InputDecoration decoration = tester
              .widget<TextField>(find.byKey(catalogSearchFieldKey))
              .decoration!;
          expect(decoration.border, isA<OutlineInputBorder>());
          final BorderRadius radius =
              (decoration.border! as OutlineInputBorder).borderRadius;
          expect(radius.topLeft.x, greaterThanOrEqualTo(24));
          expect(radius, BorderRadius.circular(radius.topLeft.x));
        }
      });

      testWidgets('names the editable field from its hint even when focused', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await pumpField(tester);
        for (final bool focused in <bool>[false, true]) {
          if (focused) {
            await tester.tap(find.byKey(catalogSearchFieldKey));
            await tester.pumpAndSettle();
          }
          expect(
            tester.getSemantics(find.byType(EditableText)).label,
            'Nombre o código',
          );
          expect(
            find.bySemanticsLabel('Buscar por nombre o código'),
            findsNothing,
          );
        }
        semantics.dispose();
      });
    });
  }
}
