import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to system before and after nonblocking load', () async {
    final store = ThemeModeStore();
    addTearDown(store.dispose);
    expect(store.value, ThemeMode.system);
    await store.loaded;
    expect(store.value, ThemeMode.system);
  });

  for (final mode in ThemeMode.values) {
    test('persists and restores ${mode.name}', () async {
      final store = ThemeModeStore();
      addTearDown(store.dispose);
      await store.loaded;
      var notifications = 0;
      store.addListener(() => notifications++);
      final saving = store.setThemeMode(mode);
      expect(store.value, mode);
      await saving;
      expect(notifications, mode == ThemeMode.system ? 0 : 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lda.themeMode'), mode.name);
      final restored = ThemeModeStore();
      addTearDown(restored.dispose);
      await restored.loaded;
      expect(restored.value, mode);
    });
  }

  for (final corrupt in <Object>['invalid', 42]) {
    test('corrupt value $corrupt falls back to system', () async {
      SharedPreferences.setMockInitialValues({'lda.themeMode': corrupt});
      final store = ThemeModeStore();
      addTearDown(store.dispose);
      await store.loaded;
      expect(store.value, ThemeMode.system);
    });
  }

  test('rapid selections persist in order and finish with the latest', () async {
    final store = ThemeModeStore();
    addTearDown(store.dispose);
    await Future.wait([
      store.setThemeMode(ThemeMode.dark),
      store.setThemeMode(ThemeMode.light),
      store.setThemeMode(ThemeMode.system),
    ]);
    expect(store.value, ThemeMode.system);
    expect((await SharedPreferences.getInstance()).getString('lda.themeMode'), 'system');
  });

  test('selection during startup wins over persisted value', () async {
    SharedPreferences.setMockInitialValues({'lda.themeMode': 'light'});
    final store = ThemeModeStore();
    addTearDown(store.dispose);
    await store.setThemeMode(ThemeMode.dark);
    await store.loaded;
    expect(store.value, ThemeMode.dark);
    expect((await SharedPreferences.getInstance()).getString('lda.themeMode'), 'dark');
  });
}
