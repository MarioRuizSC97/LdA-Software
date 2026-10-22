import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_info.dart';
import 'package:lda_inventory/app/app_side_panel.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/app/theme_mode_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _themeButton() => find.descendant(
  of: find.byType(ThemeModeSwitch),
  matching: find.byType(IconButton),
);

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
            settings: (BuildContext context) =>
                const ThemeModeSwitch(showLabel: true),
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

  testWidgets('theme settings have live mode text left of circle and no bars', (
    tester,
  ) async {
    final store = await storeForTest();
    await _open(tester, store: store);
    final label = find.text('Tema: Sistema');
    expect(label, findsOneWidget);
    expect(
      tester.getRect(label).right,
      lessThan(tester.getRect(find.byTooltip('Tema: Sistema')).left),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('app-side-panel')),
        matching: find.byType(Divider),
      ),
      findsOneWidget,
    );
    for (final mode in ['Claro', 'Oscuro', 'Sistema']) {
      await tester.tap(_themeButton());
      await tester.pumpAndSettle();
      expect(find.text('Tema: $mode'), findsOneWidget);
    }
  });

  testWidgets('host shows one circular theme button above app info', (
    tester,
  ) async {
    final store = await storeForTest();
    await _open(tester, store: store);
    final control = find.descendant(
      of: find.byType(ThemeModeSwitch),
      matching: find.byType(IconButton),
    );
    expect(control, findsOneWidget);
    expect(find.byTooltip('Tema: Sistema'), findsOneWidget);
    expect(find.byType(RadioListTile<ThemeMode>), findsNothing);
    expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
    for (final label in ['Sistema', 'Claro', 'Oscuro']) {
      expect(find.text(label), findsNothing);
    }
    expect(
      tester.getRect(control).bottom,
      lessThan(tester.getRect(find.text(appName)).top),
    );
    final button = tester.widget<IconButton>(control);
    final colors = Theme.of(tester.element(control)).colorScheme;
    expect(button.style!.shape!.resolve({}), isA<CircleBorder>());
    expect(button.style!.backgroundColor!.resolve({}), colors.inverseSurface);
    expect(button.style!.foregroundColor!.resolve({}), colors.onInverseSurface);
  });

  testWidgets(
    'cycles system light dark system with live theme and persistence',
    (tester) async {
      final store = await storeForTest();
      await _open(tester, store: store);
      for (final (mode, label, icon, brightness) in [
        (ThemeMode.light, 'Claro', Icons.light_mode, Brightness.light),
        (ThemeMode.dark, 'Oscuro', Icons.dark_mode, Brightness.dark),
        (ThemeMode.system, 'Sistema', Icons.brightness_auto, Brightness.light),
      ]) {
        await tester.tap(_themeButton());
        expect(store.value, mode);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Tema: $label'), findsOneWidget);
        expect(find.byIcon(icon), findsOneWidget);
        expect(
          Theme.of(tester.element(find.byType(ThemeModeSwitch))).brightness,
          brightness,
        );
        expect(
          (await SharedPreferences.getInstance()).getString('lda.themeMode'),
          mode.name,
        );
        expect(find.byType(AppMenuButton), findsOneWidget);
      }
    },
  );

  testWidgets('reflects external changes and cycles from restored light mode', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lda.themeMode': 'light'});
    final store = await storeForTest();
    await _open(tester, store: store);
    expect(find.byTooltip('Tema: Claro'), findsOneWidget);
    await tester.tap(find.byTooltip('Tema: Claro'));
    await tester.pumpAndSettle();
    expect(store.value, ThemeMode.dark);
    expect(find.byTooltip('Tema: Oscuro'), findsOneWidget);
    await store.setThemeMode(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Tema: Sistema'), findsOneWidget);
    await tester.tap(find.byTooltip('Tema: Sistema'));
    await tester.pumpAndSettle();
    expect(store.value, ThemeMode.light);
    expect(find.byTooltip('Tema: Claro'), findsOneWidget);
  });

  testWidgets('without a host hides selector but preserves entries and info', (
    tester,
  ) async {
    await _open(tester);
    expect(
      find.descendant(
        of: find.byType(ThemeModeSwitch),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
    for (final label in ['Sistema', 'Claro', 'Oscuro']) {
      expect(find.text(label), findsNothing);
      expect(find.byTooltip('Tema: $label'), findsNothing);
    }
    expect(find.text('Actualizar catálogo'), findsOneWidget);
    expect(find.text(appName), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
