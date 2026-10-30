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
import 'package:lda_inventory/movements/movements_view.dart';
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
  bool delayed = true;
  @override
  Future<bool> verify(String pin) {
    if (!delayed) return super.verify(pin);
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
                catalogLoader: (_) async => CatalogSnapshot(
                  [
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
                  ],
                  branchChoices: const [
                    CatalogBranchChoice(
                      branchId: 'branch-north',
                      branchName: 'Norte',
                    ),
                  ],
                ),
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

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _typeDraft(WidgetTester tester) async {
  await tester.tap(_key('intake-branch'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Norte').last);
  await tester.pumpAndSettle();
  await tester.enterText(_key('intake-quantity'), '12.30');
  await tester.enterText(_key('intake-unit-cost'), '987.60');
}

void _expectDraft(WidgetTester tester) {
  expect(
    tester.widget<TextFormField>(_key('intake-quantity')).controller!.text,
    '12.30',
  );
  expect(
    tester.widget<TextFormField>(_key('intake-unit-cost')).controller!.text,
    '987.60',
  );
  expect(find.text('Norte'), findsOneWidget);
}

void _expectNoIntake(WidgetTester tester) {
  expect(_key('intake-quantity'), findsNothing);
  expect(_key('intake-unit-cost'), findsNothing);
  expect(find.text('987.60', skipOffstage: false), findsNothing);
  expect(find.text('12.30', skipOffstage: false), findsNothing);
  expect(
    find.text('Registrar entrada de inventario', skipOffstage: false),
    findsNothing,
  );
  expect(
    find.bySemanticsLabel('Registrar entrada de inventario'),
    findsNothing,
  );
  expect(find.bySemanticsLabel(RegExp('987[.,]60|12[.,]30')), findsNothing);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CostPinStore().create('1234');
  });
  testWidgets('system back restores intake only behind a fresh PIN', (
    tester,
  ) async {
    await _mount(tester);
    await _intake(tester);
    await _typeDraft(tester);
    await _tap(tester, 'transfer-open');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Ingresa el PIN'), findsOneWidget);
    _expectNoIntake(tester);
    await unlockCostPin(tester);
    _expectDraft(tester);
    await _tap(tester, 'transfer-open');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('cost-pin-dialog'), findsNothing);
    _expectNoIntake(tester);
  });
  testWidgets('system back dismisses details before catalog navigation', (
    tester,
  ) async {
    await _mount(tester);
    await _details(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('product-sheet-LIFECYCLE'), findsNothing);
    expect(find.text('Desliza otra vez para salir'), findsNothing);
    expect(find.byType(AuthenticatedCatalogPage), findsOneWidget);
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
  testWidgets(
    'an authorized intake panel does not survive a session replacement',
    (tester) async {
      final session = await _mount(tester);
      await _details(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('intake-LIFECYCLE')),
      );
      await tester.tap(find.byKey(const ValueKey('intake-LIFECYCLE')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cost-pin')), '1234');
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intake-quantity')), findsOneWidget);
      session.value = const EmulatorSession(
        userId: 'admin',
        email: 'admin@demo.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-north',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
      expect(
        find.byKey(const ValueKey('product-sheet-LIFECYCLE')),
        findsNothing,
      );
      // Reopening the sheet in the new session must not inherit the intake
      // presentation the previous session authorized.
      await _details(tester);
      expect(
        find.byKey(const ValueKey('product-sheet-LIFECYCLE')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
      expect(find.byKey(const ValueKey('cost-pin-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
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
    final panel = transfer ? 'transfer-open' : 'movements-open';
    testWidgets('return from $panel rechecks PIN and restores exact draft', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester);
      await _intake(tester);
      await _typeDraft(tester);
      await tester.tap(_key(panel));
      await tester.pump();
      _expectNoIntake(tester);
      await tester.pump(const Duration(milliseconds: 100));
      _expectNoIntake(tester);
      await tester.pumpAndSettle();
      await _tap(tester, 'panel-back');
      expect(find.text('Ingresa el PIN'), findsOneWidget);
      _expectNoIntake(tester);
      await unlockCostPin(tester);
      _expectDraft(tester);
      semantics.dispose();
    });
    for (final wrong in [false, true]) {
      testWidgets(
        '$panel ${wrong ? 'wrong PIN then ' : ''}cancel discards return',
        (tester) async {
          await _mount(tester);
          await _intake(tester);
          await _typeDraft(tester);
          await _tap(tester, panel);
          await _tap(tester, 'panel-back');
          expect(find.text('Ingresa el PIN'), findsOneWidget);
          if (wrong) {
            await tester.enterText(_key('cost-pin'), '9999');
            await tester.tap(find.text('Continuar'));
            await tester.pumpAndSettle();
            expect(find.text('Ingresa el PIN'), findsOneWidget);
          }
          await tester.tap(find.text('Cancelar'));
          await tester.pumpAndSettle();
          _expectNoIntake(tester);
          await _tap(tester, panel);
          await _tap(tester, 'panel-back');
          expect(_key('cost-pin-dialog'), findsNothing);
          _expectNoIntake(tester);
          await _intake(tester);
          expect(
            tester
                .widget<TextFormField>(_key('intake-unit-cost'))
                .controller!
                .text,
            '',
          );
        },
      );
    }
    if (transfer) {
      testWidgets('$panel Cerrar discards return', (tester) async {
        await _mount(tester);
        await _intake(tester);
        await _typeDraft(tester);
        await _tap(tester, panel);
        await tester.ensureVisible(find.text('Cerrar'));
        await tester.tap(find.text('Cerrar'));
        await tester.pumpAndSettle();
        await _tap(tester, panel);
        await _tap(tester, 'panel-back');
        expect(_key('cost-pin-dialog'), findsNothing);
        _expectNoIntake(tester);
      });
    }
    testWidgets('$panel Inicio discards return', (tester) async {
      await _mount(tester);
      await _intake(tester);
      await _typeDraft(tester);
      await _tap(tester, panel);
      await _tap(tester, 'shell-home');
      await _tap(tester, panel);
      await _tap(tester, 'panel-back');
      expect(_key('cost-pin-dialog'), findsNothing);
      _expectNoIntake(tester);
    });
  }
  for (final withIntake in [false, true]) {
    testWidgets('Movimientos transfer chain with intake=$withIntake', (
      tester,
    ) async {
      await _mount(tester);
      if (withIntake) {
        await _intake(tester);
        await _typeDraft(tester);
      }
      await _tap(tester, 'movements-open');
      await _tap(tester, 'transfer-open');
      await _tap(tester, 'panel-back');
      expect(_key('cost-pin-dialog'), findsNothing);
      expect(find.byType(MovementsView), findsOneWidget);
      await _tap(tester, 'panel-back');
      if (withIntake) {
        expect(find.text('Ingresa el PIN'), findsOneWidget);
        await unlockCostPin(tester);
        _expectDraft(tester);
      } else {
        expect(_key('cost-pin-dialog'), findsNothing);
        _expectNoIntake(tester);
      }
    });
  }
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
    testWidgets('transfer return discarded on session $replacement', (
      tester,
    ) async {
      final session = await _mount(tester);
      await _intake(tester);
      await _typeDraft(tester);
      await _tap(tester, 'transfer-open');
      if (replacement == null) {
        await tester.tap(find.text('Cerrar sesión'));
        await tester.pumpAndSettle();
      } else {
        session.value = replacement;
        await tester.pumpAndSettle();
      }
      session.value = _admin;
      await tester.pumpAndSettle();
      await _tap(tester, 'transfer-open');
      await _tap(tester, 'panel-back');
      expect(_key('cost-pin-dialog'), findsNothing);
      _expectNoIntake(tester);
    });
  }
  for (final action in ['navigation', 'logout', 'session', 'home']) {
    testWidgets('pending return verification discarded by $action', (
      tester,
    ) async {
      final store = _DelayedPinStore()..delayed = false;
      final session = await _mount(tester, store: store);
      await _intake(tester);
      await _typeDraft(tester);
      store.delayed = true;
      await _tap(tester, 'transfer-open');
      final home = tester.widget<IconButton>(_key('shell-home')).onPressed!;
      await _tap(tester, 'panel-back');
      await tester.enterText(_key('cost-pin'), '1234');
      await tester.tap(find.text('Continuar'));
      await tester.pump();
      if (action == 'logout') {
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(
                OutlinedButton,
                'Cerrar sesión',
                skipOffstage: false,
              ),
            )
            .onPressed!();
      } else if (action == 'session') {
        session.value = const EmulatorSession(
          userId: 'other',
          email: 'other@demo.invalid',
          role: InventoryRole.administrator,
        );
      } else if (action == 'home') {
        home();
      } else {
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('movements-open'), skipOffstage: false),
            )
            .onPressed!();
      }
      await tester.pumpAndSettle();
      store.answer.complete(true);
      await tester.pumpAndSettle();
      _expectNoIntake(tester);
      expect(_key('cost-pin-dialog'), findsNothing);
      expect(tester.takeException(), isNull);
      if (action == 'logout') expect(session.value, isNull);
    });
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
        expect(find.text('Ingresa el PIN'), findsOneWidget);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
      },
    );
  }
}
