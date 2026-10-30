import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/version/minimum_version.dart';
import 'package:lda_inventory/version/version_gate.dart';

const UpdateRequired _required = UpdateRequired(
  installedVersion: '1.0.0',
  minimumVersion: '1.0.1',
);

final UpdateRequired _requiredWithUrls = UpdateRequired(
  installedVersion: '1.0.0',
  minimumVersion: '1.0.1',
  androidUpdateUrl: Uri.parse('https://play.example/lda'),
  iosUpdateUrl: Uri.parse('https://apps.example/lda'),
);

class _Recorder {
  final List<Uri> opened = <Uri>[];
  int reloads = 0;
  int builds = 0;
}

Widget _gate(
  _Recorder recorder,
  Future<VersionGateDecision> Function() check, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  home: VersionGate(
    check: check,
    isWeb: isWeb,
    platform: platform,
    openUrl: (Uri url) async => recorder.opened.add(url),
    reload: () => recorder.reloads++,
    builder: (BuildContext context) {
      recorder.builds++;
      return const Text('app content');
    },
  ),
);

void main() {
  testWidgets('shows a loading state and builds nothing while checking', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();
    final Completer<VersionGateDecision> pending =
        Completer<VersionGateDecision>();

    await tester.pumpWidget(_gate(recorder, () => pending.future));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('app content'), findsNothing);
    expect(recorder.builds, 0);

    pending.complete(const VersionAllowed());
    await tester.pumpAndSettle();
    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('an allowed version shows the app', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(
      _gate(recorder, () async => const VersionAllowed()),
    );
    await tester.pumpAndSettle();

    expect(find.text('app content'), findsOneWidget);
    expect(find.text('Actualización necesaria'), findsNothing);
  });

  testWidgets('a check that throws still lets the app in', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(
      _gate(recorder, () async => throw StateError('unexpected')),
    );
    await tester.pumpAndSettle();

    expect(find.text('app content'), findsOneWidget);
  });

  testWidgets('an old version is blocked with the exact copy and versions', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(_gate(recorder, () async => _required));
    await tester.pumpAndSettle();

    expect(find.text('Actualización necesaria'), findsOneWidget);
    expect(
      find.text(
        'Hay una versión nueva de LDA Inventory. '
        'Actualiza la app para continuar.',
      ),
      findsOneWidget,
    );
    expect(find.text('Versión instalada: 1.0.0'), findsOneWidget);
    expect(find.text('Versión requerida: 1.0.1'), findsOneWidget);
    expect(find.text('app content'), findsNothing);
    expect(recorder.builds, 0);
  });

  testWidgets('on the web the action reloads the page', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(
      _gate(recorder, () async => _requiredWithUrls, isWeb: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Abrir la tienda'), findsNothing);
    await tester.tap(find.text('Recargar'));
    expect(recorder.reloads, 1);
    expect(recorder.opened, isEmpty);
  });

  testWidgets('on Android the action opens the Android store URL', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(_gate(recorder, () async => _requiredWithUrls));
    await tester.pumpAndSettle();

    expect(find.text('Recargar'), findsNothing);
    await tester.tap(find.text('Abrir la tienda'));
    expect(recorder.opened, <Uri>[Uri.parse('https://play.example/lda')]);
  });

  testWidgets('on iOS the action opens the iOS store URL', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(
      _gate(
        recorder,
        () async => _requiredWithUrls,
        platform: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Abrir la tienda'));
    expect(recorder.opened, <Uri>[Uri.parse('https://apps.example/lda')]);
  });

  testWidgets('on mobile without a store URL there is no action', (
    WidgetTester tester,
  ) async {
    final _Recorder recorder = _Recorder();

    await tester.pumpWidget(_gate(recorder, () async => _required));
    await tester.pumpAndSettle();

    expect(find.text('Actualización necesaria'), findsOneWidget);
    expect(find.text('Abrir la tienda'), findsNothing);
    expect(find.text('Recargar'), findsNothing);
  });
}
