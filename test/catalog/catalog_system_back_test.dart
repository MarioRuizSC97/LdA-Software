import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

Future<void> _mount(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: const EmulatorSession(
          userId: 'admin',
          email: 'test@demo.invalid',
          role: InventoryRole.administrator,
        ),
        catalogLoader: (_) async => CatalogSnapshot(<CatalogItem>[
          CatalogItem(
            product: const CatalogProduct(
              internalCode: 'BACK',
              name: 'Producto',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
            holdings: <CatalogHolding>[],
          ),
        ]),
        onLogout: () async {},
        createProduct: (_) => Completer<ProductCreationResult>().future,
        submitTransfer: (_) => Completer<TransferResult>().future,
        unresolvedTransferDraft: () => null,
        administratorMovements: AdministratorMovements(
          load: (_) async => <MovementEntry>[],
          readProfile: (_) async => const SellerUnnamed(),
          setSellerName: (uid, name) async =>
              SellerProfileResult(uid: uid, replayed: false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  for (final movements in [false, true]) {
    testWidgets(
      'system back from transfer restores ${movements ? 'Movimientos' : 'catalog'}',
      (tester) async {
        await _mount(tester);
        if (movements) {
          await tester.tap(find.text('Movimientos'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('transfer-open')));
        await tester.pumpAndSettle();
        await _back(tester);
        expect(find.byType(AdministratorTransferForm), findsNothing);
        expect(
          find.text('No hay movimientos'),
          movements ? findsOneWidget : findsNothing,
        );
        expect(find.byType(AuthenticatedCatalogPage), findsOneWidget);
      },
    );
  }

  testWidgets('Android root confirms exit only within two seconds', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _mount(tester);
    await _back(tester);
    expect(find.text('Desliza otra vez para salir'), findsOneWidget);
    expect(calls.where((m) => m == 'SystemNavigator.pop'), isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(calls.where((m) => m == 'SystemNavigator.pop'), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
    calls.clear();
    await _back(tester);
    expect(find.text('Desliza otra vez para salir'), findsOneWidget);
    expect(calls.where((m) => m == 'SystemNavigator.pop'), isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('focused search consumes back before root confirmation', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.text('Desliza otra vez para salir'), findsNothing);
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode
          .hasFocus,
      isFalse,
    );
  });

  testWidgets('side panel route consumes back before body panel', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('transfer-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Menú'));
    await tester.pumpAndSettle();
    await _back(tester);
    expect(find.byType(AdministratorTransferForm), findsOneWidget);
    expect(find.byKey(const ValueKey('app-side-panel-backdrop')), findsNothing);
  });

  testWidgets(
    'iOS only edge-origin swipe navigates and root never confirms exit',
    (tester) async {
      await _mount(tester);
      await _back(tester);
      expect(find.text('Desliza otra vez para salir'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('transfer-open')));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(300, 300), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(find.byType(AdministratorTransferForm), findsOneWidget);
      await tester.timedDragFrom(
        const Offset(8, 300),
        const Offset(25, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdministratorTransferForm), findsOneWidget);
      await tester.dragFrom(const Offset(8, 300), const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.byType(AdministratorTransferForm), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
