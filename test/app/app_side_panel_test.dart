import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_info.dart';
import 'package:lda_inventory/app/app_side_panel.dart';

Finder _key(String value) => find.byKey(ValueKey<String>(value));

void _useViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _host({
  required List<AppSidePanelEntry> Function() entries,
  bool disableAnimations = false,
}) => MaterialApp(
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(
    appBar: AppBar(
      title: const Text('LDA Inventory'),
      actions: <Widget>[
        AppMenuButton(
          key: const ValueKey<String>('shell-more'),
          entries: entries,
        ),
      ],
    ),
    body: const Center(child: Text('catálogo')),
  ),
);

double _iconProgress(WidgetTester tester) => tester
    .widget<AnimatedIcon>(
      find.descendant(
        of: _key('shell-more'),
        matching: find.byType(AnimatedIcon),
      ),
    )
    .progress
    .value;

void main() {
  testWidgets('the three bars open a side panel from the right (S6)', (
    WidgetTester tester,
  ) async {
    _useViewport(tester);
    await tester.pumpWidget(_host(entries: () => const <AppSidePanelEntry>[]));

    expect(_key('app-side-panel'), findsNothing);
    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();

    expect(_key('app-side-panel'), findsOneWidget);
    final Rect panel = tester.getRect(_key('app-side-panel'));
    expect(panel.right, 400);
    expect(panel.width, lessThan(400));
  });

  testWidgets('the three bars animate into a close icon while the panel '
      'opens and back when it closes (S7)', (WidgetTester tester) async {
    await tester.pumpWidget(_host(entries: () => const <AppSidePanelEntry>[]));
    expect(_iconProgress(tester), 0);

    await tester.tap(_key('shell-more'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final double midway = _iconProgress(tester);
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1));

    await tester.pumpAndSettle();
    expect(_iconProgress(tester), 1);

    await tester.tap(find.byTooltip('Cerrar menú'));
    await tester.pumpAndSettle();
    expect(_key('app-side-panel'), findsNothing);
    expect(_iconProgress(tester), 0);
  });

  testWidgets('everything outside the panel is blurred and dimmed, and '
      'tapping it closes the panel (S8)', (WidgetTester tester) async {
    await tester.pumpWidget(_host(entries: () => const <AppSidePanelEntry>[]));
    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();

    expect(_key('app-side-panel-backdrop'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('app-side-panel-backdrop'),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();
    expect(_key('app-side-panel'), findsNothing);
  });

  testWidgets('Escape closes the panel (S8)', (WidgetTester tester) async {
    await tester.pumpWidget(_host(entries: () => const <AppSidePanelEntry>[]));
    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key('app-side-panel'), findsNothing);
    expect(_iconProgress(tester), 0);
  });

  testWidgets('the settings slot renders above the app information (S10 '
      'seam)', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: <Widget>[
              AppMenuButton(
                key: const ValueKey<String>('shell-more'),
                entries: () => const <AppSidePanelEntry>[],
                settings: (BuildContext context) =>
                    const Text('ajustes', key: ValueKey<String>('settings')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();

    expect(_key('settings'), findsOneWidget);
    expect(
      tester.getRect(_key('settings')).bottom,
      lessThanOrEqualTo(tester.getRect(_key('app-side-panel-info')).top),
    );
  });

  testWidgets('entries run their action once and close the panel; disabled '
      'entries do nothing (S9)', (WidgetTester tester) async {
    int refreshes = 0;
    int logouts = 0;
    await tester.pumpWidget(
      _host(
        entries: () => <AppSidePanelEntry>[
          AppSidePanelEntry(
            key: const ValueKey<String>('refresh'),
            icon: const Icon(Icons.refresh),
            label: 'Actualizar catálogo',
            onSelected: () => refreshes++,
          ),
          const AppSidePanelEntry(
            key: ValueKey<String>('corrections-open'),
            icon: Icon(Icons.assignment_return_outlined),
            label: 'Correcciones',
            onSelected: null,
          ),
          AppSidePanelEntry(
            icon: const Icon(Icons.logout),
            label: 'Cerrar sesión',
            onSelected: () => logouts++,
          ),
        ],
      ),
    );

    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Correcciones'));
    await tester.pumpAndSettle();
    expect(_key('app-side-panel'), findsOneWidget);

    await tester.tap(find.text('Actualizar catálogo'));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(logouts, 0);
    expect(_key('app-side-panel'), findsNothing);
  });

  testWidgets('the bottom of the panel shows the app name and version (S9)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(entries: () => const <AppSidePanelEntry>[]));
    await tester.tap(_key('shell-more'));
    await tester.pumpAndSettle();

    final Finder info = _key('app-side-panel-info');
    expect(
      find.descendant(of: info, matching: find.text(appName)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: info,
        matching: find.text('Versión $appVersion ($appBuild)'),
      ),
      findsOneWidget,
    );
    final Rect panel = tester.getRect(_key('app-side-panel'));
    expect(tester.getRect(info).bottom, greaterThan(panel.bottom - 120));
  });

  testWidgets('reduced motion opens and closes the panel instantly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        entries: () => const <AppSidePanelEntry>[],
        disableAnimations: true,
      ),
    );
    await tester.tap(_key('shell-more'));
    await tester.pump();
    await tester.pump();
    expect(_key('app-side-panel'), findsOneWidget);
    expect(_iconProgress(tester), 1);
  });

  test('the displayed version matches pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^version:\s*([^+\s]+)\+(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(appVersion, match!.group(1));
    expect(appBuild, match.group(2));
  });
}
