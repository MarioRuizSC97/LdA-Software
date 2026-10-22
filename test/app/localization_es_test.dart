import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _root(String mode) => LdaInventoryBootstrap(
  demoEnabled: mode == 'demo',
  localEmulatorsEnabled: mode == 'connected',
  emulatorLoader: () => Completer<EmulatorSessionGateway>().future,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final mode in <String>['setup', 'demo', 'connected']) {
    testWidgets('$mode root supplies all three Spanish SDK delegates', (
      tester,
    ) async {
      await tester.pumpWidget(_root(mode));
      await tester.pump();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.supportedLocales, contains(const Locale('es')));
      final delegates = app.localizationsDelegates;
      expect(delegates, isNotNull);
      expect(
        delegates!
            .whereType<LocalizationsDelegate<MaterialLocalizations>>()
            .single
            .isSupported(const Locale('es')),
        isTrue,
      );
      expect(
        delegates
            .whereType<LocalizationsDelegate<WidgetsLocalizations>>()
            .single
            .isSupported(const Locale('es')),
        isTrue,
      );
      expect(
        delegates
            .whereType<LocalizationsDelegate<CupertinoLocalizations>>()
            .single
            .isSupported(const Locale('es')),
        isTrue,
      );
    });

    testWidgets('$mode app configuration localizes the length counter', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_root(mode));
      await tester.pump();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      // Use each real root's configuration, without its unrelated page/backend.
      await tester.pumpWidget(
        MaterialApp(
          theme: app.theme,
          localizationsDelegates: app.localizationsDelegates,
          supportedLocales: app.supportedLocales,
          home: const Scaffold(body: TextField(maxLength: 120)),
        ),
      );
      await tester.pumpAndSettle();
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration;
      expect(decoration.semanticCounterText, 'Quedan 120 caracteres');
      expect(find.bySemanticsLabel('Quedan 120 caracteres'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Hola');
      await tester.pump();
      expect(find.bySemanticsLabel('Quedan 116 caracteres'), findsOneWidget);
      semantics.dispose();
    });
  }
}
