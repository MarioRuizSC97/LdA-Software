import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_info.dart';
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
  double height = 900,
  double bottomInset = 0,
  double textScale = 1,
  BackendEnvironment environment = BackendEnvironment.localEmulator,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
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
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: EmulatorLoginShell(
          environment: environment,
          sessionGateway: Future.value(_SignedOutGateway()),
          catalogLoader: (_) async => throw StateError('Must stay signed out.'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _reminderFacts = <String>[
  'El servidor asigna el código interno permanente y la identidad QR.',
  'Solo el administrador puede crear productos, ver movimientos y registrar traslados.',
];

void main() {
  final rail = find.byKey(const ValueKey<String>('login-context'));
  final email = find.byKey(const ValueKey<String>('login-email'));
  final password = find.byKey(const ValueKey<String>('login-password'));

  testWidgets('400px preserves the compact login without a context rail', (
    tester,
  ) async {
    await _pumpLogin(tester, width: 400, brightness: Brightness.light);
    expect(rail, findsNothing);
    expect(find.text('Recordatorios'), findsNothing);
    for (final fact in _reminderFacts) {
      expect(find.text(fact), findsNothing);
    }
    expect(email, findsOneWidget);
    expect(password, findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(tester.getRect(email).left, 24);
    expect(tester.getSize(email).width, 352);
    final control = find.byType(ThemeModeSwitch);
    expect(control, findsOneWidget);
    final controlRect = tester.getRect(control);
    expect(controlRect.width, controlRect.height);
    expect(controlRect.right, 384);
    expect(controlRect.bottom, 884);
    expect(tester.takeException(), isNull);
  });

  for (final width in <double>[601, 1200]) {
    testWidgets('rail shares the form top at ${width.toInt()}px', (
      tester,
    ) async {
      await _pumpLogin(tester, width: width, brightness: Brightness.light);
      final title = find.text(BackendEnvironment.localEmulator.loginTitle);
      final titleRect = tester.getRect(title);
      final railRect = tester.getRect(rail);
      expect(railRect.top, closeTo(titleRect.top, 1));
      expect(railRect.top, lessThan(tester.getRect(email).top));
    });
  }

  testWidgets('1200px centers the wide group on the page', (tester) async {
    await _pumpLogin(tester, width: 1200, brightness: Brightness.light);
    final titleRect = tester.getRect(
      find.text(BackendEnvironment.localEmulator.loginTitle),
    );
    final railRect = tester.getRect(rail);
    final buttonRect = tester.getRect(
      find.widgetWithText(FilledButton, 'Iniciar sesión'),
    );
    final groupRect = titleRect
        .expandToInclude(railRect)
        .expandToInclude(buttonRect);
    debugPrint(
      'wide title=$titleRect rail=$railRect button=$buttonRect group=$groupRect',
    );
    expect(groupRect.center.dy, closeTo(450, 2));
    expect(titleRect.top, closeTo(railRect.top, 1));
  });

  testWidgets('short wide viewport scrolls above the reachable footer', (
    tester,
  ) async {
    await _pumpLogin(
      tester,
      width: 1200,
      height: 500,
      brightness: Brightness.light,
    );
    expect(tester.takeException(), isNull);
    final scrollables = tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(
      scrollables.any((state) => state.position.maxScrollExtent > 0),
      isTrue,
    );
    final button = find.widgetWithText(FilledButton, 'Iniciar sesión');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    final buttonRect = tester.getRect(button);
    final caption = find.text('v1.0.0');
    final control = find.byType(ThemeModeSwitch);
    expect(caption, findsOneWidget);
    expect(control, findsOneWidget);
    final captionRect = tester.getRect(caption);
    final controlRect = tester.getRect(control);
    debugPrint(
      'short button=$buttonRect caption=$captionRect control=$controlRect',
    );
    expect(button.hitTestable(), findsOneWidget);
    expect(control.hitTestable(), findsOneWidget);
    expect(buttonRect.bottom, lessThan(captionRect.top));
    expect(buttonRect.bottom, lessThan(controlRect.top));
    expect(captionRect.overlaps(controlRect), isFalse);
    expect(captionRect.bottom, lessThanOrEqualTo(500));
    expect(controlRect.bottom, lessThanOrEqualTo(500));
    final lastReminder = find.text(_reminderFacts.last);
    await tester.ensureVisible(lastReminder);
    await tester.pumpAndSettle();
    final reminderRect = tester.getRect(lastReminder);
    expect(lastReminder.hitTestable(), findsOneWidget);
    expect(reminderRect.top, greaterThanOrEqualTo(80));
    expect(reminderRect.bottom, lessThan(controlRect.top));
    expect(reminderRect.bottom, lessThan(captionRect.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide rail presents each verified reminder as a separate line', (
    tester,
  ) async {
    await _pumpLogin(tester, width: 1200, brightness: Brightness.light);
    expect(
      find.descendant(of: rail, matching: find.text('Recordatorios')),
      findsOneWidget,
    );
    Rect? previous;
    for (final fact in _reminderFacts) {
      final line = find.descendant(of: rail, matching: find.text(fact));
      expect(line, findsOneWidget);
      final rect = tester.getRect(line);
      if (previous != null) expect(rect.top, greaterThan(previous.bottom));
      previous = rect;
    }
  });

  for (final environment in BackendEnvironment.values) {
    testWidgets('1200px shows honest context beside the form: '
        '${environment.name}', (tester) async {
      await _pumpLogin(
        tester,
        width: 1200,
        brightness: Brightness.light,
        environment: environment,
      );
      expect(rail, findsOneWidget);
      for (final content in <String>[
        appName,
        appVersionLabel,
        environment.loginTitle,
        'Ingresa con las credenciales de tu tienda.',
      ]) {
        expect(
          find.descendant(of: rail, matching: find.textContaining(content)),
          findsOneWidget,
        );
      }
      final formRect = tester.getRect(email);
      final railRect = tester.getRect(rail);
      expect(railRect.left, greaterThan(formRect.right));
      expect(formRect.width, lessThanOrEqualTo(440));
      expect(railRect.right, lessThanOrEqualTo(1180));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in <double>[400, 601, 1200]) {
    testWidgets('login has no overflow at ${width.toInt()}px, text scale 2', (
      tester,
    ) async {
      await _pumpLogin(
        tester,
        width: width,
        brightness: Brightness.light,
        textScale: 2,
      );
      expect(rail, width < 600 ? findsNothing : findsOneWidget);
      expect(email, findsOneWidget);
      expect(password, findsOneWidget);
      expect(find.byType(ThemeModeSwitch), findsOneWidget);
      expect(find.text('v1.0.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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
