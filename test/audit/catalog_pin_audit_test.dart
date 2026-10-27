import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/cost_pin_dialog.dart';
import 'package:lda_inventory/app/cost_pin_store.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/privacy_curtain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/cost_pin_test_helper.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

class _DelayedStore extends CostPinStore {
  final verification = Completer<bool>();
  int calls = 0;
  bool broken = false;

  @override
  Future<bool> get isConfigured async => true;

  @override
  Future<bool> verify(String pin) {
    calls++;
    if (broken) throw StateError('private storage exception in English');
    return verification.future;
  }
}

Future<void> _mount(
  WidgetTester tester, {
  double width = 400,
  Brightness brightness = Brightness.light,
  bool change = false,
  CostPinStore? store,
  PrivacyCurtain? curtain,
  ValueChanged<bool>? result,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light
        ? buildInventoryTheme()
        : buildDarkInventoryTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.3),
        // A realistic on-screen keyboard must not hide the PIN actions.
        viewInsets: const EdgeInsets.only(bottom: 280),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () async {
        final accepted = await showCostPinDialog(
          context, store: store, curtain: curtain, change: change,
        );
        result?.call(accepted);
      },
      child: const Text('Abrir PIN'),
    ))),
  ));
  await tester.tap(find.text('Abrir PIN'));
  await tester.pumpAndSettle();
}

void main() {
  setUpCostPin();

  for (final mode in ['create', 'verify', 'change']) {
    for (final brightness in Brightness.values) {
      for (final width in [320.0, 400.0, 600.0, 1200.0]) {
        testWidgets('PIN $mode fits $width $brightness scale 1.3 with keyboard', (tester) async {
          if (mode == 'create') SharedPreferences.setMockInitialValues({});
          await _mount(tester, width: width, brightness: brightness, change: mode == 'change');
          expect(_key('cost-pin-dialog'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final field = tester.widget<TextField>(_key('cost-pin'));
          expect(field.obscureText, isTrue);
          expect(field.enableSuggestions, isFalse);
          await tester.enterText(_key('cost-pin'), '12');
          final save = find.text(mode == 'change' ? 'Guardar PIN' : 'Continuar');
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(find.text('El PIN debe tener de 4 a 6 dígitos.'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Cancelar'));
          await tester.pumpAndSettle();
          expect(_key('cost-pin-dialog'), findsNothing);
        });
      }
    }
  }

  testWidgets('PIN repeated submit and keyboard action invoke verification exactly once', (tester) async {
    final store = _DelayedStore();
    final results = <bool>[];
    await _mount(tester, store: store, result: results.add);
    await tester.enterText(_key('cost-pin'), '1234');
    await tester.tap(find.text('Continuar'));
    await tester.tap(find.text('Continuar'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(store.calls, 1);
    expect(results, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_key('cost-pin-dialog'), findsOneWidget);
    store.verification.complete(true);
    await tester.pumpAndSettle();
    expect(results, [true]);
    expect(_key('cost-pin-dialog'), findsNothing);
  });

  testWidgets('PIN storage failure is Spanish and cancel never authorizes', (tester) async {
    final store = _DelayedStore()..broken = true;
    final results = <bool>[];
    await _mount(tester, store: store, result: results.add);
    await tester.enterText(_key('cost-pin'), '1234');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(find.text('No se pudo guardar o verificar el PIN. Intenta de nuevo.'), findsOneWidget);
    expect(find.textContaining('private storage'), findsNothing);
    expect(results, isEmpty);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalidated privacy curtain rejects late correct PIN and removes its route', (tester) async {
    final store = _DelayedStore();
    final curtain = PrivacyCurtain()..bind('administrator-session');
    final results = <bool>[];
    await _mount(tester, store: store, curtain: curtain, result: results.add);
    await tester.enterText(_key('cost-pin'), '1234');
    await tester.tap(find.text('Continuar'));
    await tester.pump();
    expect(store.calls, 1);
    curtain.bind('seller-session');
    await tester.pumpAndSettle();
    expect(_key('cost-pin-dialog'), findsNothing);
    store.verification.complete(true);
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(tester.takeException(), isNull);
  });
}
