import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_side_panel.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/app/theme_mode_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart';
import '../support/viewport.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-1',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

final SaleCorrections _corrections = SaleCorrections(
  branchId: saleBranchId,
  find: (SaleLookupQuery query) async => lookupSale(),
  listRecent: () async => RecentCorrectableSales.fromCallable(<String, Object?>{
    'sales': <Object?>[lookupSaleJson()],
  }, query: RecentSalesQuery()),
  previewReturn: (_) async => throw UnimplementedError(),
  submitReturn: (_) async => throw UnimplementedError(),
  previewExchange: (_) async => throw UnimplementedError(),
  submitReplacement: (_) async => throw UnimplementedError(),
  submitExchange: (_) async => throw UnimplementedError(),
  unresolvedDraft: () => null,
  unacknowledged: () => null,
  acknowledge: (_) {},
);

final AdministratorMovements _movements = AdministratorMovements(
  load: (String? branchId) async => <MovementEntry>[],
  readProfile: (String uid) async => const SellerUnnamed(),
  setSellerName: (String uid, String name) async =>
      SellerProfileResult(uid: uid, replayed: false),
);

/// A notice controller whose backend never resolves: the badge stays in its
/// unknown state, which is enough to put the inbox entry in the AppBar.
TransferNoticeController _pendingNotices(EmulatorSession session) {
  final TransferNoticeController controller = TransferNoticeController(
    session: session,
    loadBackend: () => Completer<TransferNoticeBackend>().future,
    sessionChecker: () async => session,
  );
  controller.start();
  return controller;
}

class _SignedOutGateway implements EmulatorSessionGateway {
  @override
  Future<EmulatorSession?> restoreSession() async => null;
  @override
  Stream<EmulatorSession?> sessionChanges() => const Stream.empty();
  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();
  @override
  Future<void> logout() async {}
}

class _Shell {
  int logouts = 0;

  Widget seller() => MaterialApp(
    home: AuthenticatedCatalogPage(
      session: _seller,
      catalogLoader: (_) async => sellerSaleSnapshot(branchId: saleBranchId),
      onLogout: () async => logouts++,
      saleCheckout: FakeSaleCheckout().checkout,
      saleCorrections: _corrections,
      transferNotices: _pendingNotices,
    ),
  );

  Widget administrator() => MaterialApp(
    home: AuthenticatedCatalogPage(
      session: _administrator,
      catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
      onLogout: () async => logouts++,
      administratorMovements: _movements,
    ),
  );
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _inAppBar(Finder finder) =>
    find.descendant(of: find.byType(AppBar), matching: finder);

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(_key('shell-more'));
  await tester.pumpAndSettle();
}

void main() {
  for (final double scale in <double>[1, 2]) {
    group('narrow shell at text scale $scale', () {
      testWidgets('seller shell fits 320px and keeps every action reachable', (
        WidgetTester tester,
      ) async {
        useViewport(tester, const Size(320, 700), scale);
        final _Shell shell = _Shell();
        await tester.pumpWidget(shell.seller());
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Icon-only text actions move to the menu (T10/S10): notices live in
        // the overflow menu at compact widths, not in the bar.
        expect(_inAppBar(_key('notices-open')), findsNothing);
        expect(_inAppBar(find.byIcon(Icons.refresh)), findsOneWidget);
        expect(_inAppBar(find.text('Correcciones')), findsNothing);
        expect(_inAppBar(find.text('Cerrar sesión')), findsNothing);

        await _openMore(tester);
        expect(_key('notices-open'), findsOneWidget);
        // First menu entry, ahead of Correcciones and Cerrar sesión (S10).
        final Rect notices = tester.getRect(_key('notices-open'));
        final Rect corrections = tester.getRect(find.text('Correcciones'));
        expect(notices.top, lessThan(corrections.top));

        await tester.tap(_key('corrections-open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // At large text the folio field may sit below the fold; the open view
        // is proven by its close action.
        expect(_key('corrections-close'), findsOneWidget);

        // While corrections is open its menu entry is disabled, like the
        // inline button.
        await _openMore(tester);
        expect(
          tester.widget<ListTile>(_key('corrections-open')).enabled,
          isFalse,
        );
        await tester.tap(find.text('Cerrar sesión'));
        await tester.pumpAndSettle();
        expect(shell.logouts, 1);
        // Desktop/web keeps this narrow-window layout (S2); the mobile app
        // bar is covered in mobile_app_bar_test.dart.
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets(
        'administrator shell fits 320px and keeps every action reachable',
        (WidgetTester tester) async {
          useViewport(tester, const Size(320, 700), scale);
          final _Shell shell = _Shell();
          await tester.pumpWidget(shell.administrator());
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(_inAppBar(find.byIcon(Icons.refresh)), findsOneWidget);
          expect(_inAppBar(find.text('Movimientos')), findsNothing);

          await _openMore(tester);
          await tester.tap(_key('movements-open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          await _openMore(tester);
          expect(
            tester.widget<ListTile>(_key('movements-open')).enabled,
            isFalse,
          );
          await tester.tap(find.text('Cerrar sesión'));
          await tester.pumpAndSettle();
          expect(shell.logouts, 1);
          // Desktop/web keeps this narrow-window layout (S2); the mobile app
          // bar is covered in mobile_app_bar_test.dart.
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    });
  }

  testWidgets(
    'a tablet width at text scale 2 collapses instead of overflowing',
    (WidgetTester tester) async {
      useViewport(tester, const Size(700, 900), 2);
      await tester.pumpWidget(_Shell().seller());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_key('shell-more'), findsOneWidget);
    },
  );

  testWidgets(
    'wide shell keeps every action inline without a side menu (T11 S2)',
    (WidgetTester tester) async {
      useViewport(tester, const Size(1000, 800));
      await tester.pumpWidget(_Shell().seller());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_key('shell-more'), findsNothing);
      expect(_inAppBar(find.text('Correcciones')), findsOneWidget);
      expect(_inAppBar(_key('notices-open')), findsOneWidget);
      expect(_inAppBar(find.text('Cerrar sesión')), findsOneWidget);
      // Desktop/web keeps this wide-window layout (S2); the mobile app bar is
      // covered in mobile_app_bar_test.dart.
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final double width in <double>[600, 601, 1000, 1400]) {
    testWidgets('wide header at ${width}px shows version and cycles theme', (
      WidgetTester tester,
    ) async {
      useViewport(tester, Size(width, 800));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ThemeModeStore();
      await store.loaded;
      addTearDown(store.dispose);
      await tester.pumpWidget(
        InventoryThemeHost(
          store: store,
          builder: (_, mode) => _Shell().seller(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AppMenuButton), findsNothing);
      expect(_inAppBar(find.byType(ThemeModeSwitch)), findsOneWidget);
      final title = tester.getRect(find.text('LDA Inventory'));
      final session = tester.getRect(_key('session-status'));
      final version = tester.getRect(find.text('v1.0.0'));
      expect(find.textContaining('Versión'), findsNothing);
      expect(find.textContaining('(1)'), findsNothing);
      expect(title.top, lessThan(session.top));
      expect(session.right, lessThanOrEqualTo(version.left));
      expect(version.width, greaterThan(0));
      expect(title.width, greaterThan(0));
      expect(
        version.right,
        lessThanOrEqualTo(
          tester.getRect(_inAppBar(find.text('Correcciones'))).left,
        ),
      );
      final themeButton = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(ThemeModeSwitch),
          matching: find.byType(IconButton),
        ),
      );
      expect(
        themeButton.style!.shape!.resolve(<WidgetState>{}),
        isA<CircleBorder>(),
      );
      final logoutButton = _inAppBar(find.byType(OutlinedButton));
      final row = tester.widget<Row>(
        find.ancestor(of: logoutButton, matching: find.byType(Row)).first,
      );
      expect(
        row.children.where((action) => action is! SizedBox).last,
        isA<OutlinedButton>(),
      );
      final logout = tester.getRect(_inAppBar(find.text('Cerrar sesión')));
      expect(
        tester.getRect(find.byType(ThemeModeSwitch)).right,
        lessThan(logout.left),
      );

      for (final mode in <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
        ThemeMode.system,
      ]) {
        await tester.tap(find.byType(ThemeModeSwitch));
        await tester.pumpAndSettle();
        expect(store.value, mode);
        expect(tester.takeException(), isNull);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('compact header keeps the panel and version only in its footer', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(400, 800));
    await tester.pumpWidget(_Shell().seller());
    await tester.pumpAndSettle();
    expect(find.byType(AppMenuButton), findsOneWidget);
    expect(find.text('v1.0.0'), findsNothing);
    await _openMore(tester);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.textContaining('Versión'), findsNothing);
    expect(find.textContaining('(1)'), findsNothing);
    expect(find.text('Correcciones'), findsOneWidget);
    expect(find.text('Cerrar sesión'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('header circle is smaller than the login and panel circles', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(1000, 800));
    SharedPreferences.setMockInitialValues({});
    final store = ThemeModeStore();
    await store.loaded;
    addTearDown(store.dispose);
    Widget host(Widget child) =>
        InventoryThemeHost(store: store, builder: (_, mode) => child);
    Size circleSize() => tester.getSize(
      find.descendant(
        of: find.byType(ThemeModeSwitch),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.shape is CircleBorder,
        ),
      ),
    );
    await tester.pumpWidget(
      host(
        MaterialApp(
          home: EmulatorLoginShell(
            sessionGateway: Future.value(_SignedOutGateway()),
            catalogLoader: (_) async => throw UnimplementedError(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final defaultSize = circleSize();
    expect(defaultSize, const Size(48, 48));
    await tester.pumpWidget(host(_Shell().seller()));
    await tester.pumpAndSettle();
    final headerSize = circleSize();
    expect(headerSize.width, lessThan(defaultSize.width));
    expect(headerSize.height, headerSize.width);
    final semantics = tester.ensureSemantics();
    final target = tester.getSemantics(find.byTooltip('Tema: Sistema')).rect;
    expect(target.width, greaterThanOrEqualTo(40));
    expect(target.height, greaterThanOrEqualTo(40));
    semantics.dispose();
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    await _openMore(tester);
    expect(circleSize(), defaultSize);
    // Only the menu-heading divider remains; settings have no delimiting bars.
    expect(
      find.descendant(
        of: _key('app-side-panel'),
        matching: find.byType(Divider),
      ),
      findsOneWidget,
    );
    final label = find.text('Tema: Sistema');
    expect(label, findsOneWidget);
    expect(
      tester.getRect(label).right,
      lessThan(tester.getRect(find.byTooltip('Tema: Sistema')).left),
    );
    await tester.tap(find.byTooltip('Tema: Sistema'));
    await tester.pumpAndSettle();
    expect(find.text('Tema: Claro'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the wide seller shell meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    useViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(_Shell().seller());
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('the narrow administrator shell meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    useViewport(tester, const Size(320, 700));
    await tester.pumpWidget(_Shell().administrator());
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
