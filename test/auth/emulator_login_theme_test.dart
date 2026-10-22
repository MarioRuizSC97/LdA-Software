import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/app/theme_mode_switch.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedOutGateway implements EmulatorSessionGateway {
  @override
  Future<EmulatorSession?> restoreSession() async => null;
  @override
  Stream<EmulatorSession?> sessionChanges() => const Stream.empty();
  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();
  @override
  Future<void> logout() async {}
}

void main() {
  testWidgets('login cycles persisted themes from its bottom-right corner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ThemeModeStore();
    addTearDown(store.dispose);
    await store.loaded;
    final gateway = Future<EmulatorSessionGateway>.value(_SignedOutGateway());
    await tester.pumpWidget(
      InventoryThemeHost(
        store: store,
        builder: (context, mode) => MaterialApp(
          theme: buildInventoryTheme(),
          darkTheme: buildDarkInventoryTheme(),
          themeMode: mode,
          home: EmulatorLoginShell(
            sessionGateway: gateway,
            catalogLoader: (_) async => throw UnimplementedError(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final control = find.byType(ThemeModeSwitch);
    expect(control, findsOneWidget);
    expect(find.byTooltip('Tema: Sistema'), findsOneWidget);
    final view = tester.getRect(find.byType(Scaffold));
    final button = tester.getRect(control);
    expect(button.center.dx, greaterThan(view.center.dx));
    expect(button.center.dy, greaterThan(view.center.dy));
    expect(view.right - button.right, lessThanOrEqualTo(24));
    expect(view.bottom - button.bottom, lessThanOrEqualTo(24));
    final formColumn = find
        .ancestor(
          of: find.byKey(const ValueKey<String>('login-email')),
          matching: find.byType(Column),
        )
        .first;
    expect(find.descendant(of: formColumn, matching: control), findsNothing);
    expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
    final semantics = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
    final password = find.byKey(const ValueKey<String>('login-password'));
    await tester.enterText(password, 'keep-form-state');
    for (final (mode, label, persisted, brightness) in [
      (ThemeMode.light, 'Claro', 'light', Brightness.light),
      (ThemeMode.dark, 'Oscuro', 'dark', Brightness.dark),
      (ThemeMode.system, 'Sistema', 'system', Brightness.light),
    ]) {
      await tester.tap(control);
      expect(store.value, mode);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Tema: $label'), findsOneWidget);
      expect(Theme.of(tester.element(password)).brightness, brightness);
      expect(
        tester.widget<TextFormField>(password).controller!.text,
        'keep-form-state',
      );
      expect(
        (await SharedPreferences.getInstance()).getString('lda.themeMode'),
        persisted,
      );
    }
  });
}
