import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedOutGateway implements EmulatorSessionGateway {
  @override
  Future<EmulatorSession?> restoreSession() async => null;
  @override
  Stream<EmulatorSession?> sessionChanges() => const Stream.empty();
  @override
  Future<EmulatorSession> login({required String email, required String password}) =>
      throw UnimplementedError();
  @override
  Future<void> logout() async {}
}

void main() {
  testWidgets('login selects and immediately applies all theme modes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ThemeModeStore();
    addTearDown(store.dispose);
    final gateway = Future<EmulatorSessionGateway>.value(_SignedOutGateway());
    await tester.pumpWidget(InventoryThemeHost(
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
    ));
    await tester.pumpAndSettle();
    for (final label in ['Sistema', 'Claro', 'Oscuro']) {
      expect(find.text(label), findsOneWidget);
    }
    final semantics = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
    final password = find.byKey(const ValueKey<String>('login-password'));
    await tester.enterText(password, 'keep-form-state');
    await tester.tap(find.text('Oscuro'));
    expect(store.value, ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(password)).brightness, Brightness.dark);
    expect(tester.widget<TextFormField>(password).controller!.text, 'keep-form-state');
    await tester.tap(find.text('Claro'));
    await tester.pumpAndSettle();
    expect(store.value, ThemeMode.light);
    expect(Theme.of(tester.element(password)).brightness, Brightness.light);
    await tester.tap(find.text('Sistema'));
    await tester.pumpAndSettle();
    expect(store.value, ThemeMode.system);
    expect((await SharedPreferences.getInstance()).getString('lda.themeMode'), 'system');
  });
}
