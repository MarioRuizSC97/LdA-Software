// Native smoke test against the running local demo emulators.
//
// Proves, on a real Android/iOS runtime, that the app reaches all three
// emulators: Auth (sign-in), Firestore (live catalog) and Functions (the
// read-only recent-sales callable behind Correcciones). It never writes
// business data. See README.md, "Native smoke test", for the run commands.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lda_inventory/main.dart' as app;

// Fake demo credentials seeded by functions/scripts/provision-demo-identities.mjs;
// valid only in the local Auth emulator.
const String _sellerEmail = 'seller.north@demo-lda-inventory.invalid';
const String _sellerPassword = 'Demo-Only-Seller-2026!';
const String _recentSalesFailure =
    'No se pudieron cargar las ventas recientes.';

const bool _localEmulators = bool.fromEnvironment('LDA_LOCAL_EMULATORS');

/// Pumps frames until [finder] matches or about 40 seconds pass.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 160 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('demo seller reaches Auth, Firestore and Functions', (
    WidgetTester tester,
  ) async {
    app.main();

    // A previous run may have left a session (on iOS it survives uninstall
    // in the Keychain), so accept either the login form or the catalog.
    final Finder email = find.widgetWithText(TextField, 'Correo electrónico');
    final Finder catalog = find.text('Demo Coffee');
    await _pumpUntil(
      tester,
      find.byWidgetPredicate(
        (_) => email.evaluate().isNotEmpty || catalog.evaluate().isNotEmpty,
      ),
    );
    if (email.evaluate().isNotEmpty) {
      await tester.enterText(email, _sellerEmail);
      await tester.enterText(
        find.widgetWithText(TextField, 'Contraseña'),
        _sellerPassword,
      );
      await tester.tap(find.text('Iniciar sesión'));
    }

    await _pumpUntil(tester, catalog);
    expect(find.text('Autenticado localmente'), findsOneWidget);
    expect(find.text(_sellerEmail), findsOneWidget);
    expect(catalog, findsOneWidget);

    // Narrow screens move Correcciones into the overflow menu.
    final Finder more = find.byKey(const ValueKey<String>('shell-more'));
    if (more.evaluate().isNotEmpty) {
      await tester.tap(more);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey<String>('corrections-open')));
    await tester.pumpAndSettle();

    final Finder recentSettled = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Text &&
          (widget.data == _recentSalesFailure ||
              widget.data == 'No hay ventas recientes' ||
              (widget.data ?? '').startsWith('NTE-')),
    );
    await _pumpUntil(tester, recentSettled);
    expect(find.text(_recentSalesFailure), findsNothing);
    expect(recentSettled, findsWidgets);
  }, skip: !_localEmulators);
}
