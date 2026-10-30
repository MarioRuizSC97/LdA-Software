import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Widget _page({required VoidCallback? onChangePassword, double width = 1280}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 900)),
        child: AuthenticatedCatalogPage(
          session: _seller,
          environment: BackendEnvironment.production,
          catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
          onLogout: () async {},
          onChangePassword: onChangePassword,
        ),
      ),
    );

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  // Widget tests report Android by default, and Android always uses the menu;
  // the wide bar belongs to the web and desktop layout. The override is reset
  // inside the test because the framework checks it before tear-downs run.
  Future<void> onDesktop(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('the wide bar offers the password action, not the menu', (
    WidgetTester tester,
  ) async {
    await onDesktop(() async {
      await _setSize(tester, const Size(1280, 900));
      int opened = 0;
      await tester.pumpWidget(_page(onChangePassword: () => opened++));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('shell-more')), findsNothing);
      final Finder action = find.byKey(
        const ValueKey<String>('change-password-open'),
      );
      expect(action, findsOneWidget);

      await tester.tap(action);
      expect(opened, 1);
    });
  });

  testWidgets('without a password gateway neither placement appears', (
    WidgetTester tester,
  ) async {
    await onDesktop(() async {
      await _setSize(tester, const Size(1280, 900));
      await tester.pumpWidget(_page(onChangePassword: null));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('change-password-open')),
        findsNothing,
      );
    });
  });

  testWidgets('the compact bar keeps the entry inside the side panel', (
    WidgetTester tester,
  ) async {
    await _setSize(tester, const Size(420, 900));
    int opened = 0;
    await tester.pumpWidget(
      _page(onChangePassword: () => opened++, width: 420),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('change-password-open')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
    await tester.pumpAndSettle();

    final Finder entry = find.byKey(
      const ValueKey<String>('shell-change-password'),
    );
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
