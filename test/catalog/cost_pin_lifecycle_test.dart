import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lda_inventory/app/cost_pin_store.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import 'cost_pin_test_helper.dart';

const _admin = EmulatorSession(
  userId: 'admin',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);
const _product = CatalogProduct(
  internalCode: 'LIFECYCLE',
  name: 'Producto',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
);
final _movements = AdministratorMovements(
  load: (_) async => <MovementEntry>[],
  readProfile: (_) async => const SellerUnnamed(),
  setSellerName: (uid, name) async =>
      SellerProfileResult(uid: uid, replayed: false),
);

class _DelayedPinStore extends CostPinStore {
  final answer = Completer<bool>();
  bool started = false;
  @override
  Future<bool> verify(String pin) {
    started = true;
    return answer.future;
  }
}

Future<ValueNotifier<EmulatorSession?>> _mount(
  WidgetTester tester, {
  CostPinStore? store,
}) async {
  final session = ValueNotifier<EmulatorSession?>(_admin);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: ValueListenableBuilder<EmulatorSession?>(
        valueListenable: session,
        builder: (_, value, _) => value == null
            ? const Scaffold(body: Text('Sesión cerrada'))
            : AuthenticatedCatalogPage(
                session: value,
                costPinStore: store,
                onLogout: () async {
                  session.value = null;
                },
                catalogLoader: (_) async => CatalogSnapshot([
                  CatalogItem(
                    product: _product,
                    holdings: const [
                      CatalogHolding(
                        branchId: 'branch-north',
                        branchName: 'Norte',
                        quantityScaled: 100,
                      ),
                    ],
                  ),
                ]),
                submitStockIntake: (_) async =>
                    throw StateError('not submitted'),
                submitTransfer: (_) async => throw StateError('not submitted'),
                unresolvedTransferDraft: () => null,
                administratorMovements: _movements,
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Future<void> _details(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('product-details-LIFECYCLE')));
  await tester.pumpAndSettle();
}

Future<void> _intake(WidgetTester tester) async {
  await _details(tester);
  await tester.ensureVisible(find.byKey(const ValueKey('intake-LIFECYCLE')));
  await tester.tap(find.byKey(const ValueKey('intake-LIFECYCLE')));
  await unlockCostPin(tester);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CostPinStore().create('1234');
  });
  for (final replacement in <EmulatorSession?>[
    null,
    const EmulatorSession(
      userId: 'other',
      email: 'other@demo.invalid',
      role: InventoryRole.administrator,
    ),
    const EmulatorSession(
      userId: 'admin',
      email: 'admin@demo.invalid',
      role: InventoryRole.seller,
      branchId: 'branch-north',
    ),
    const EmulatorSession(
      userId: 'admin',
      email: 'admin@demo.invalid',
      role: InventoryRole.administrator,
      branchId: 'branch-north',
    ),
  ]) {
    testWidgets(
      'revealed details close on ${replacement == null ? 'logout' : '${replacement.userId}/${replacement.role}/${replacement.branchId}'}',
      (tester) async {
        final session = await _mount(tester);
        await _details(tester);
        await revealCost(tester);
        expect(find.text('Costo no disponible'), findsOneWidget);
        if (replacement == null) {
          await tester
              .widget<AuthenticatedCatalogPage>(
                find.byType(AuthenticatedCatalogPage),
              )
              .onLogout();
        } else {
          session.value = replacement;
        }
        await tester.pumpAndSettle();
        expect(find.text('Costo no disponible'), findsNothing);
        expect(
          find.byKey(const ValueKey('product-sheet-LIFECYCLE')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('cost-pin-dialog')), findsNothing);
      },
    );
  }
  for (final intake in [false, true]) {
    for (final logout in [false, true]) {
      testWidgets(
        'pending ${intake ? 'intake' : 'cost'} verification cannot survive ${logout ? 'logout' : 'seller replacement'}',
        (tester) async {
          final store = _DelayedPinStore();
          final session = await _mount(tester, store: store);
          await _details(tester);
          if (intake) {
            await tester.ensureVisible(
              find.byKey(const ValueKey('intake-LIFECYCLE')),
            );
            await tester.tap(find.byKey(const ValueKey('intake-LIFECYCLE')));
          } else {
            await tester.tap(find.text('Ver costo'));
          }
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('cost-pin')),
            '1234',
          );
          await tester.tap(find.text('Continuar'));
          await tester.pump();
          expect(store.started, isTrue);
          session.value = logout
              ? null
              : const EmulatorSession(
                  userId: 'admin',
                  email: 'admin@demo.invalid',
                  role: InventoryRole.seller,
                  branchId: 'branch-north',
                );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('cost-pin-dialog')), findsNothing);
          expect(
            find.byKey(const ValueKey('product-sheet-LIFECYCLE')),
            findsNothing,
          );
          store.answer.complete(true);
          await tester.pumpAndSettle();
          expect(find.text('Costo no disponible'), findsNothing);
          expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final intake in [false, true]) {
    testWidgets(
      'same-identity navigation invalidates pending ${intake ? 'intake' : 'cost'} answer without popping a newer PIN',
      (tester) async {
        final store = _DelayedPinStore();
        await _mount(tester, store: store);
        await _details(tester);
        if (intake) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('intake-LIFECYCLE')),
          );
          await tester.tap(find.byKey(const ValueKey('intake-LIFECYCLE')));
        } else {
          await tester.tap(find.text('Ver costo'));
        }
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('cost-pin')), '1234');
        await tester.tap(find.text('Continuar'));
        await tester.pump();
        expect(store.started, isTrue);
        // Simulate a navigation callback arriving while the modal is pending.
        // A real pointer cannot reach the covered toolbar through the scrim.
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('movements-open'), skipOffstage: false),
            )
            .onPressed!();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('cost-pin-dialog')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('panel-back')));
        await tester.pumpAndSettle();
        await _details(tester);
        await tester.tap(find.text('Ver costo'));
        await tester.pumpAndSettle();
        store.answer.complete(true);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('cost-pin-dialog')), findsOneWidget);
        expect(find.text('Costo no disponible'), findsNothing);
        expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final transfer in [false, true]) {
    testWidgets(
      '${transfer ? 'Traslados' : 'Movimientos'} clears intake rather than suspending authorization',
      (tester) async {
        await _mount(tester);
        await _intake(tester);
        expect(find.byKey(const ValueKey('intake-quantity')), findsOneWidget);
        await tester.tap(
          transfer
              ? find.byKey(const ValueKey('transfer-open'))
              : find.text('Movimientos'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('panel-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
        await _details(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('intake-LIFECYCLE')),
        );
        await tester.tap(find.byKey(const ValueKey('intake-LIFECYCLE')));
        await tester.pumpAndSettle();
        expect(find.text('Ingresa el PIN'), findsOneWidget);
      },
    );
  }
}
