import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
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
  }) async => throw StateError('Design tests must not submit credentials.');

  @override
  Future<void> logout() async {}
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  required double width,
  required Brightness brightness,
  double bottomInset = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ThemeModeStore();
  await store.loaded;
  addTearDown(store.dispose);
  await tester.pumpWidget(
    ThemeModeScope(
      store: store,
      child: MaterialApp(
        theme: brightness == Brightness.light
            ? buildInventoryTheme()
            : buildDarkInventoryTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: EmulatorLoginShell(
          sessionGateway: Future.value(_SignedOutGateway()),
          catalogLoader: (_) async => throw StateError('Must stay signed out.'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in <double>[400, 1200]) {
    for (final brightness in Brightness.values) {
      final scenario = '${width.toInt()}px ${brightness.name}';
      for (final bottomInset in <double>[0, 24]) {
        testWidgets('version is a safe bottom-center caption: $scenario '
            'inset=$bottomInset', (tester) async {
          await _pumpLogin(
            tester,
            width: width,
            brightness: brightness,
            bottomInset: bottomInset,
          );

          final version = find.text('v1.0.0');
          expect(version, findsOneWidget);
          final rect = tester.getRect(version);
          expect(rect.center.dx, closeTo(width / 2, 1));
          expect(
            rect.center.dy,
            inInclusiveRange(850 - bottomInset, 875 - bottomInset),
          );
          expect(rect.bottom, lessThanOrEqualTo(900 - bottomInset - 16));
          final themeControl = tester.getRect(find.byType(ThemeModeSwitch));
          expect(themeControl.width, greaterThanOrEqualTo(48));
          expect(rect.overlaps(themeControl), isFalse);
          final form = tester.getRect(find.byType(Column).last);
          expect(rect.top, greaterThan(form.bottom));
          expect(
            find.ancestor(of: version, matching: find.byType(SafeArea)),
            findsWidgets,
          );
          final text = tester.widget<Text>(version);
          final theme = Theme.of(tester.element(version));
          expect(text.style?.fontSize, theme.textTheme.bodySmall?.fontSize);
          expect(text.style?.color, theme.colorScheme.onSurfaceVariant);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets(
        'login title matches catalog scale and is a heading: $scenario',
        (tester) async {
          await _pumpLogin(tester, width: width, brightness: brightness);
          final semantics = tester.ensureSemantics();
          try {
            final title = find.text(
              BackendEnvironment.localEmulator.loginTitle,
            );
            final text = tester.widget<Text>(title);
            final catalogStyle = Theme.of(tester.element(title))
                .textTheme
                .headlineMedium!;
            expect(tester.getSemantics(title).flagsCollection.isHeader, isTrue);
            expect(text.style?.fontSize, catalogStyle.fontSize);
            expect(text.style?.fontWeight, FontWeight.w400);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
