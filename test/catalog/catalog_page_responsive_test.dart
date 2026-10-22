import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
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

  testWidgets('wide shell keeps every action inline and still offers the '
      'side panel (T10 S6)', (WidgetTester tester) async {
    useViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(_Shell().seller());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_key('shell-more'), findsOneWidget);
    expect(_inAppBar(find.text('Correcciones')), findsOneWidget);
    expect(_inAppBar(_key('notices-open')), findsOneWidget);
    expect(_inAppBar(find.text('Cerrar sesión')), findsOneWidget);
    // Desktop/web keeps this wide-window layout (S2); the mobile app bar is
    // covered in mobile_app_bar_test.dart.
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
