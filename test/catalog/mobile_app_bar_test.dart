// T2 / S2: mobile app bar. On Android and iOS only, the shell centers the
// 'LDA Inventory' title, hides 'Inicio' on the main panel (it appears once a
// second panel is open, next to 'Volver'), moves 'Actualizar catálogo' into
// the overflow menu, and renders that menu with three bars (Icons.menu).
// Web and desktop builds keep the current app bar at every window width.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

final AdministratorMovements _movements = AdministratorMovements(
  load: (String? branchId) async => <MovementEntry>[],
  readProfile: (String uid) async => const SellerUnnamed(),
  setSellerName: (String uid, String name) async =>
      SellerProfileResult(uid: uid, replayed: false),
);

Future<ProductCreationResult> _neverCreates(ProductCreationDraft draft) =>
    Completer<ProductCreationResult>().future;

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _adminPage({
  ProductCreationSubmit? createProduct,
  CatalogSnapshotLoader? loader,
  bool withMovements = false,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _administrator,
    catalogLoader:
        loader ?? (_) async => CatalogSnapshot(const <CatalogItem>[]),
    onLogout: () async {},
    createProduct: createProduct,
    administratorMovements: withMovements ? _movements : null,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _inAppBar(Finder finder) =>
    find.descendant(of: find.byType(AppBar), matching: finder);

/// Horizontal distance between the 'LDA Inventory' text center and the app
/// bar center: ~0 when centered, strongly negative when left-aligned.
/// Horizontal offset of the title column's left edge from where AppBar's
/// NavigationToolbar places a `centerTitle: true` title: screen-centered,
/// clamped against the action row when the block would collide with it
/// (leading slot 56, middleSpacing 16, action row from 'shell-more' left).
/// ~0 exactly when the title block is centered; far right of that when the
/// title is left-aligned after the leading slot.
double _titleCenterOffset(WidgetTester tester) {
  final Rect bar = tester.getRect(find.byType(AppBar));
  final Rect column = tester.getRect(
    find
        .ancestor(of: find.text('LDA Inventory'), matching: find.byType(Column))
        .first,
  );
  const double leadingWidth = 56;
  const double middleSpacing = NavigationToolbar.kMiddleSpacing;
  final double trailingWidth =
      bar.right - tester.getRect(_key('shell-more')).left;
  double middleStart = (bar.width - column.width) / 2;
  if (middleStart + column.width > bar.width - trailingWidth) {
    middleStart = bar.width - trailingWidth - column.width - middleSpacing;
  } else if (middleStart < leadingWidth + middleSpacing) {
    middleStart = leadingWidth + middleSpacing;
  }
  return column.left - middleStart;
}

void main() {
  group('centered title (S2a)', () {
    testWidgets('the title is centered on Android', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_adminPage());
      await tester.pumpAndSettle();

      expect(_titleCenterOffset(tester).abs(), lessThan(1.0));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the title is centered on iOS', (WidgetTester tester) async {
      await tester.pumpWidget(_adminPage());
      await tester.pumpAndSettle();

      expect(_titleCenterOffset(tester).abs(), lessThan(1.0));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('the title is not centered on desktop', (
      WidgetTester tester,
    ) async {
      // A representative desktop action row (Movimientos + logout): macOS
      // auto-centers bars with fewer than two actions, which is not the
      // layout this rule pins. Left-aligned means the title sits right after
      // the leading slot, far left of the bar's center.
      await tester.pumpWidget(_adminPage(withMovements: true));
      await tester.pumpAndSettle();

      final Rect bar = tester.getRect(find.byType(AppBar));
      final Rect title = tester.getRect(find.text('LDA Inventory'));
      expect(title.center.dx, lessThan(bar.center.dx - 100));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('home icon on the main panel (S2b)', () {
    testWidgets('Inicio is hidden at the main panel and appears with a panel '
        'open on mobile', (WidgetTester tester) async {
      await tester.pumpWidget(_adminPage(createProduct: _neverCreates));
      await tester.pumpAndSettle();

      expect(_key('shell-home'), findsNothing);
      expect(_key('panel-back'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Crear producto'));
      await tester.pumpAndSettle();

      expect(_key('panel-back'), findsOneWidget);
      expect(_key('shell-home'), findsOneWidget);

      await tester.tap(_key('shell-home'));
      await tester.pumpAndSettle();

      expect(_key('panel-back'), findsNothing);
      expect(_key('shell-home'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('reload in the overflow menu (S2c)', () {
    testWidgets('Actualizar catálogo lives in the menu on mobile, even wide', (
      WidgetTester tester,
    ) async {
      _useViewport(tester, const Size(1000, 800));
      int loads = 0;
      await tester.pumpWidget(
        _adminPage(
          loader: (_) async {
            loads++;
            return CatalogSnapshot(const <CatalogItem>[]);
          },
        ),
      );
      await tester.pumpAndSettle();

      // The menu must exist on a tablet-width mobile window: Reload is never
      // a bar icon there.
      expect(_key('shell-more'), findsOneWidget);
      expect(_inAppBar(find.byIcon(Icons.refresh)), findsNothing);
      expect(loads, 1);

      await tester.tap(_key('shell-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actualizar catálogo'));
      await tester.pumpAndSettle();

      expect(loads, 2);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the menu reload entry is disabled while the catalog loads '
        'and the bar has no refresh button', (WidgetTester tester) async {
      await tester.pumpWidget(
        _adminPage(loader: (_) => Completer<CatalogSnapshot>().future),
      );
      await tester.pump();

      expect(_inAppBar(find.byTooltip('Actualizar catálogo')), findsNothing);

      await tester.tap(_key('shell-more'));
      // The indeterminate loading spinner never settles; pump fixed frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final ListTile item = tester.widget(
        find.widgetWithText(ListTile, 'Actualizar catálogo'),
      );
      expect(item.enabled, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('overflow menu icon (S2d)', () {
    testWidgets('the menu icon is the animated three bars on every platform '
        '(T10 S6/S7)', (WidgetTester tester) async {
      await tester.pumpWidget(_adminPage());
      await tester.pumpAndSettle();

      final AnimatedIcon icon = tester.widget(
        find.descendant(
          of: _key('shell-more'),
          matching: find.byType(AnimatedIcon),
        ),
      );
      expect(icon.icon, AnimatedIcons.menu_close);
      expect(icon.progress.value, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('web and desktop keep the current app bar', () {
    testWidgets('a wide desktop window keeps text actions, the refresh button '
        'and Cerrar sesión inline', (WidgetTester tester) async {
      _useViewport(tester, const Size(1000, 800));
      await tester.pumpWidget(_adminPage(withMovements: true));
      await tester.pumpAndSettle();

      // The side panel exists at every width (T10 S6); the wide bar still
      // keeps its inline actions.
      expect(_key('shell-more'), findsOneWidget);
      expect(_inAppBar(find.text('Movimientos')), findsOneWidget);
      expect(_inAppBar(find.byIcon(Icons.refresh)), findsOneWidget);
      expect(_inAppBar(find.text('Cerrar sesión')), findsOneWidget);
      // 'Inicio' is hidden at the main panel on every platform (S9, T10).
      expect(_key('shell-home'), findsNothing);
      final Rect wideBar = tester.getRect(find.byType(AppBar));
      final Rect wideTitle = tester.getRect(find.text('LDA Inventory'));
      expect(wideTitle.center.dx, lessThan(wideBar.center.dx - 100));

      // A narrow desktop window collapses its text actions into the side
      // panel (three bars, T10 S6) with the refresh button kept in the bar.
      _useViewport(tester, const Size(320, 700));
      await tester.pumpWidget(_adminPage(withMovements: true));
      await tester.pumpAndSettle();

      expect(_key('shell-more'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('shell-more'),
          matching: find.byType(AnimatedIcon),
        ),
        findsOneWidget,
      );
      expect(_inAppBar(find.text('Movimientos')), findsNothing);
      expect(_inAppBar(find.byIcon(Icons.refresh)), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}
