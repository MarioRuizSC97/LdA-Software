import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_info.dart';
import 'package:lda_inventory/app/app_side_panel.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/app/theme_mode_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({ThemeModeStore? store}) {
  Widget app(ThemeMode mode) => MaterialApp(
    theme: ThemeData.light(),
    darkTheme: ThemeData.dark(),
    themeMode: mode,
    home: Scaffold(
      appBar: AppBar(
        actions: <Widget>[
          AppMenuButton(
            entries: () => <AppSidePanelEntry>[
              AppSidePanelEntry(
                icon: const Icon(Icons.refresh),
                label: 'Actualizar catálogo',
                onSelected: () {},
              ),
            ],
            settings: (BuildContext context) => const ThemeModeSwitch(),
          ),
        ],
      ),
    ),
  );
  return store == null
      ? app(ThemeMode.system)
      : InventoryThemeHost(store: store, builder: (_, mode) => app(mode));
}

Future<void> _open(WidgetTester tester, {ThemeModeStore? store}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(store: store));
  await tester.tap(find.byTooltip('Menú'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<ThemeModeStore> storeForTest() async {
    final ThemeModeStore store = ThemeModeStore();
    addTearDown(store.dispose);
    await store.loaded;
    return store;
  }

  testWidgets('host shows all three exact theme labels above app info', (
    WidgetTester tester,
  ) async {
    final ThemeModeStore store = await storeForTest();
    await _open(tester, store: store);

    for (final String label in <String>['Sistema', 'Claro', 'Oscuro']) {
      expect(find.text(label), findsOneWidget);
      expect(
        tester.getRect(find.text(label)).bottom,
        lessThan(tester.getRect(find.text(appName)).top),
      );
    }
  });

  testWidgets('dark and system selections update the store and live theme', (
    WidgetTester tester,
  ) async {
    final ThemeModeStore store = await storeForTest();
    await _open(tester, store: store);

    await tester.tap(find.text('Oscuro'));
    expect(store.value, ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('Oscuro'))).brightness,
      Brightness.dark,
    );
    expect(find.byType(AppMenuButton), findsOneWidget);

    await tester.tap(find.text('Sistema'));
    expect(store.value, ThemeMode.system);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
  });

  testWidgets(
    'reflects external changes and exposes the checked light option',
    (WidgetTester tester) async {
      final ThemeModeStore store = await storeForTest();
      await _open(tester, store: store);

      await store.setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(RadioListTile<ThemeMode>, 'Oscuro'),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.checked == true &&
                widget.properties.inMutuallyExclusiveGroup == true,
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Claro'));
      expect(store.value, ThemeMode.light);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(RadioListTile<ThemeMode>, 'Claro'),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.checked == true &&
                widget.properties.inMutuallyExclusiveGroup == true,
          ),
        ),
        findsOneWidget,
      );
      expect(
        Theme.of(tester.element(find.text('Claro'))).brightness,
        Brightness.light,
      );
    },
  );

  testWidgets('without a host hides selector but preserves entries and info', (
    WidgetTester tester,
  ) async {
    await _open(tester);

    for (final String label in <String>['Sistema', 'Claro', 'Oscuro']) {
      expect(find.text(label), findsNothing);
    }
    expect(find.text('Actualizar catálogo'), findsOneWidget);
    expect(find.text(appName), findsOneWidget);
    expect(find.text('Versión $appVersion ($appBuild)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
