// T10 / S9, S10: app bar feedback.
// S9: 'Inicio' is hidden on the main panel on EVERY platform (web and
// desktop included, not just Android/iOS); it appears next to 'Volver' once
// a panel is open.
// S10: transfer notices become the FIRST entry of the overflow menu wherever
// that menu exists (always on Android/iOS; on web/desktop when the bar is
// compact), with the unread state on the item and a badge on the menu icon;
// the wide web/desktop bar keeps its own notices icon.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart'
    show CatalogDocument;
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

import '../support/viewport.dart';

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Future<ProductCreationResult> _neverCreates(ProductCreationDraft draft) =>
    Completer<ProductCreationResult>().future;

CatalogSnapshot _sellerSnapshot() => CatalogSnapshot(const <CatalogItem>[]);

Widget _adminPage() => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _administrator,
    catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
    onLogout: () async {},
    createProduct: _neverCreates,
    createDraftId: () => 'draft-1',
  ),
);

Widget _sellerPage({TransferNoticeControllerFactory? transferNotices}) =>
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: _seller,
        catalogLoader: (_) async => _sellerSnapshot(),
        onLogout: () async {},
        transferNotices: transferNotices,
      ),
    );

/// A notice controller whose backend never resolves: the unread state stays
/// unconfirmed ('!') without any stream wiring.
TransferNoticeController _pendingNotices(EmulatorSession session) {
  final TransferNoticeController controller = TransferNoticeController(
    session: session,
    loadBackend: () => Completer<TransferNoticeBackend>().future,
    sessionChecker: () async => session,
  );
  controller.start();
  return controller;
}

class _FakeNoticeStreams implements TransferNoticeStreamSource {
  final StreamController<TransferNoticeStreamEnvelope> movementsCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  final StreamController<TransferNoticeStreamEnvelope> markersCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();

  void emitMovements(List<CatalogDocument> documents) => movementsCtrl.add(
    TransferNoticeStreamEnvelope(documents: documents, isFromCache: false),
  );

  void emitMarkers(List<CatalogDocument> documents) => markersCtrl.add(
    TransferNoticeStreamEnvelope(documents: documents, isFromCache: false),
  );

  CatalogDocument marker(String transferId) => CatalogDocument(
    path:
        'transferNoticeReads/seller-north/branches/branch-north/transfers/$transferId',
    data: <String, Object?>{
      'userId': 'seller-north',
      'branchId': 'branch-north',
      'transferId': transferId,
      'readAt': Timestamp.fromMillisecondsSinceEpoch(1767300000000),
    },
  );

  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      movementsCtrl.stream;

  @override
  Stream<TransferNoticeStreamEnvelope> markers() => markersCtrl.stream;
}

Map<String, Object?> _leg(String transferId, String movementId) =>
    <String, Object?>{
      'branchId': 'branch-north',
      'type': 'transfer-in',
      'productId': 'PRD-COFFEE-001',
      'quantityScaled': 500,
      'unit': 'kg',
      'precision': 2,
      'transferId': transferId,
      'occurredAt': Timestamp.fromMillisecondsSinceEpoch(1767225600000),
      'actorId': 'administrator-1',
    };

TransferNoticeController _liveNotices(
  EmulatorSession session,
  _FakeNoticeStreams streams,
) {
  final TransferNoticeController controller = TransferNoticeController(
    session: session,
    loadBackend: () async =>
        TransferNoticeBackend(streams: streams, markRead: (_) async => null),
    sessionChecker: () async => session,
  );
  controller.start();
  return controller;
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _inAppBar(Finder finder) =>
    find.descendant(of: find.byType(AppBar), matching: finder);

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(_key('shell-more'));
  await tester.pumpAndSettle();
}

void main() {
  group('S9: home icon on the main panel', () {
    testWidgets('desktop hides Inicio at the main panel and shows it next to '
        'Volver with a panel open', (WidgetTester tester) async {
      await tester.pumpWidget(_adminPage());
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('S10: transfer notices in the overflow menu', () {
    testWidgets('mobile moves the notices entry from the bar into the menu as '
        'its first item', (WidgetTester tester) async {
      await tester.pumpWidget(_sellerPage(transferNotices: _pendingNotices));
      await tester.pumpAndSettle();

      // Notices leave the bar wherever the overflow menu exists.
      expect(_inAppBar(_key('notices-open')), findsNothing);

      await _openMore(tester);

      expect(_key('notices-open'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('notices-open'),
          matching: find.text('Avisos de traslados'),
        ),
        findsOneWidget,
      );
      // First entry of the menu: above every other entry, including logout.
      final Rect notices = tester.getRect(_key('notices-open'));
      final Rect logout = tester.getRect(
        find.descendant(
          of: _key('app-side-panel'),
          matching: find.text('Cerrar sesión'),
        ),
      );
      expect(notices.top, lessThan(logout.top));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the unconfirmed state shows the ! badge on the menu item and '
        'on the menu icon', (WidgetTester tester) async {
      await tester.pumpWidget(_sellerPage(transferNotices: _pendingNotices));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: _key('shell-more'), matching: find.text('!')),
        findsOneWidget,
      );

      await _openMore(tester);

      expect(
        find.descendant(of: _key('notices-open'), matching: find.text('!')),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the item and the menu icon announce the unread count', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      await tester.pumpWidget(
        _sellerPage(
          transferNotices: (EmulatorSession session) =>
              _liveNotices(session, streams),
        ),
      );
      await tester.pump();
      await tester.pump();

      // One unread arrival: the menu icon mentions the unread notices.
      streams.emitMovements(<CatalogDocument>[
        CatalogDocument(path: 'inventoryMovements/m1', data: _leg('t-a', 'm1')),
      ]);
      streams.emitMarkers(<CatalogDocument>[]);
      await tester.pump();
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('Avisos de traslados: 1 sin leer')),
        findsOneWidget,
      );

      await _openMore(tester);

      expect(
        find.descendant(of: _key('notices-open'), matching: find.text('1')),
        findsOneWidget,
      );
      // A list entry merges its badge label into its own node.
      expect(
        tester.getSemantics(_key('notices-open')).label,
        contains('1 sin leer'),
      );

      // Confirmed zero announces no unread state at all (reopen the menu:
      // its items are built at open time).
      streams.emitMarkers(<CatalogDocument>[streams.marker('t-a')]);
      await tester.pump();
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _openMore(tester);

      expect(find.bySemanticsLabel(RegExp('sin confirmar')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('1 sin leer')), findsNothing);
      expect(
        find.descendant(of: _key('notices-open'), matching: find.text('1')),
        findsNothing,
      );
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('opening the menu item opens the same notices inbox', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_sellerPage(transferNotices: _pendingNotices));
      await tester.pumpAndSettle();

      await _openMore(tester);
      await tester.tap(_key('notices-open'));
      // The pending backend keeps an indeterminate spinner alive in the
      // inbox; pump fixed frames instead of settling. The menu exits in
      // parallel with the inbox opening underneath it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Avisos de traslados'), findsWidgets);
      expect(_key('notices-close'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('the open inbox disables the menu entry', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_sellerPage(transferNotices: _pendingNotices));
      await tester.pumpAndSettle();

      await _openMore(tester);
      await tester.tap(_key('notices-open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // The inbox spinner never settles, so reopen the menu with fixed pumps.
      await tester.tap(_key('shell-more'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<ListTile>(_key('notices-open')).enabled, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('wide web/desktop keeps the notices icon in the bar (unchanged)', () {
    testWidgets('the wide shell keeps the bar notices icon without a menu '
        'or duplicate badge (T11 S2)', (WidgetTester tester) async {
      useViewport(tester, const Size(1000, 800));
      await tester.pumpWidget(_sellerPage(transferNotices: _pendingNotices));
      await tester.pumpAndSettle();

      expect(_key('shell-more'), findsNothing);
      expect(_inAppBar(_key('notices-open')), findsOneWidget);
      expect(
        find.descendant(of: _key('shell-more'), matching: find.text('!')),
        findsNothing,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('an administrator without notices gets no badge on the menu', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_adminPage());
      await tester.pumpAndSettle();

      final Finder menu = find.byKey(const ValueKey<String>('shell-more'));
      expect(menu, findsOneWidget);
      final Badge badge = tester.widget<Badge>(
        find.descendant(of: menu, matching: find.byType(Badge)),
      );
      expect(badge.isLabelVisible, isFalse);
      expect(find.descendant(of: menu, matching: find.text('!')), findsNothing);
      expect(find.bySemanticsLabel('sin confirmar'), findsNothing);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
