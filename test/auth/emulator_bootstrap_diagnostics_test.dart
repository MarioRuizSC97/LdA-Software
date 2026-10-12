import 'dart:async';

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_bootstrap_diagnostics.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';

const String _secret =
    'seller@demo.invalid AIzaSecretKey http://10.0.2.2:9099 stack-frame';

/// Not an SDK error: its text and runtime type must never reach the console.
class _Hostile {
  const _Hostile();

  @override
  String toString() => _secret;
}

Future<CatalogSnapshot> _emptyCatalog(EmulatorSession session) async =>
    CatalogSnapshot(const <CatalogItem>[]);

void main() {
  final List<EmulatorBootstrapDiagnostic> captured =
      <EmulatorBootstrapDiagnostic>[];

  setUp(() {
    captured.clear();
    EmulatorBootstrapDiagnostics.reporter = captured.add;
  });

  tearDown(EmulatorBootstrapDiagnostics.restoreDefaultReporter);

  group('emulator bootstrap diagnostic', () {
    test('maps each failure family to a fixed category', () {
      final Map<Object, String> expected = <Object, String>{
        UnsupportedError(_secret): 'unsupported-platform',
        FirebaseException(plugin: 'firebase_core', message: _secret):
            'firebase',
        StateError(_secret): 'state',
        const _Hostile(): 'other',
        UnimplementedError(_secret): 'other',
        _secret: 'other',
      };
      for (final MapEntry<Object, String> entry in expected.entries) {
        expect(
          emulatorBootstrapDiagnosticFor(entry.key).render(),
          startsWith(
            '[emulator-bootstrap] stage=gateway category=${entry.value} ',
          ),
          reason: '${entry.key.runtimeType}',
        );
      }
    });

    test('prints only allowlisted Firebase codes', () {
      expect(
        emulatorBootstrapDiagnosticFor(
          FirebaseException(plugin: 'firebase_core', code: 'duplicate-app'),
        ).render(),
        '[emulator-bootstrap] stage=gateway category=firebase '
        'code=duplicate-app',
      );
      expect(
        emulatorBootstrapDiagnosticFor(
          FirebaseException(plugin: 'firebase_core', code: _secret),
        ).render(),
        '[emulator-bootstrap] stage=gateway category=firebase code=other',
      );
      expect(
        emulatorBootstrapDiagnosticFor(StateError(_secret)).render(),
        '[emulator-bootstrap] stage=gateway category=state code=none',
      );
    });

    test('never renders the message, type or any secret', () {
      for (final Object error in <Object>[
        UnsupportedError(_secret),
        FirebaseException(plugin: _secret, code: _secret, message: _secret),
        StateError(_secret),
        const _Hostile(),
      ]) {
        reportEmulatorBootstrapFailure(error);
      }
      expect(captured, hasLength(4));
      for (final EmulatorBootstrapDiagnostic diagnostic in captured) {
        final String line = diagnostic.render();
        expect(line, isNot(contains('demo.invalid')));
        expect(line, isNot(contains('AIza')));
        expect(line, isNot(contains('10.0.2.2')));
        expect(line, isNot(contains('stack')));
        expect(line, isNot(contains('Hostile')));
        expect(diagnostic.toString(), line);
      }
    });

    test('a throwing reporter is swallowed', () {
      EmulatorBootstrapDiagnostics.reporter = (_) => throw StateError('sink');
      expect(
        () => reportEmulatorBootstrapFailure(StateError('x')),
        returnsNormally,
      );
    });
  });

  group('login shell bootstrap failure', () {
    Widget shell(Future<EmulatorSessionGateway> gateway) => MaterialApp(
      home: EmulatorLoginShell(
        sessionGateway: gateway,
        catalogLoader: _emptyCatalog,
      ),
    );

    testWidgets('reports one sanitized diagnostic', (
      WidgetTester tester,
    ) async {
      final Completer<EmulatorSessionGateway> gateway =
          Completer<EmulatorSessionGateway>();
      await tester.pumpWidget(shell(gateway.future));
      gateway.completeError(UnsupportedError(_secret));
      await tester.pumpAndSettle();

      expect(find.text('Local Auth emulator unavailable'), findsOneWidget);
      expect(
        captured.map((EmulatorBootstrapDiagnostic d) => d.render()),
        <String>[
          '[emulator-bootstrap] stage=gateway category=unsupported-platform '
              'code=none',
        ],
      );
    });

    testWidgets('a throwing reporter keeps the same failure state', (
      WidgetTester tester,
    ) async {
      EmulatorBootstrapDiagnostics.reporter = (_) => throw StateError('sink');
      final Completer<EmulatorSessionGateway> gateway =
          Completer<EmulatorSessionGateway>();
      await tester.pumpWidget(shell(gateway.future));
      gateway.completeError(StateError(_secret));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Local Auth emulator unavailable'), findsOneWidget);
      expect(find.textContaining('demo.invalid'), findsNothing);
    });
  });
}
