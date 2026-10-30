import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lda_inventory/app/cost_pin_store.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';

const _product = CatalogProduct(
  internalCode: 'PIN-PRODUCT',
  name: 'Producto',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
);

Future<void> _open(WidgetTester tester, {bool seller = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: EmulatorSession(
          userId: 'pin-user',
          email: 'pin@demo.invalid',
          role: seller ? InventoryRole.seller : InventoryRole.administrator,
          branchId: seller ? 'branch-north' : null,
        ),
        onLogout: () async {},
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
        submitStockIntake: (_) async => throw StateError('not submitted'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _details(tester);
}

Future<void> _details(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('product-details-PIN-PRODUCT')));
  await tester.pumpAndSettle();
}

Future<void> _intake(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('intake-PIN-PRODUCT')));
  await tester.tap(find.byKey(const ValueKey('intake-PIN-PRODUCT')));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const ValueKey('cost-pin')), pin);
  await tester.tap(find.text('Continuar'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('intake cancels, rejects wrong PIN, unlocks and locks on exit', (
    tester,
  ) async {
    await CostPinStore().create('1234');
    await _open(tester);
    await _intake(tester);
    expect(find.text('Ingresa el PIN'), findsOneWidget);
    expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
    await _details(tester);
    await _intake(tester);
    await _enter(tester, '0000');
    expect(find.text('PIN incorrecto.'), findsOneWidget);
    expect(find.byKey(const ValueKey('intake-quantity')), findsNothing);
    await _enter(tester, '1234');
    expect(find.byKey(const ValueKey('intake-quantity')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('panel-back')));
    await tester.pumpAndSettle();
    await _details(tester);
    await _intake(tester);
    expect(find.text('Ingresa el PIN'), findsOneWidget);
  });
  testWidgets(
    'home locks intake and changing PIN requires current and matching new PIN',
    (tester) async {
      await CostPinStore().create('1234');
      await _open(tester);
      await _intake(tester);
      await _enter(tester, '1234');
      await tester.tap(find.text('Cambiar PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cost-pin-current')),
        '0000',
      );
      await tester.enterText(find.byKey(const ValueKey('cost-pin')), '5678');
      await tester.enterText(
        find.byKey(const ValueKey('cost-pin-confirm')),
        '9999',
      );
      await tester.tap(find.text('Guardar PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Los PIN no coinciden.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('cost-pin-confirm')),
        '5678',
      );
      await tester.tap(find.text('Guardar PIN'));
      await tester.pumpAndSettle();
      expect(find.text('PIN incorrecto.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('cost-pin-current')),
        '1234',
      );
      await tester.tap(find.text('Guardar PIN'));
      await tester.pumpAndSettle();
      expect(await CostPinStore().verify('5678'), isTrue);
      await tester.tap(find.byKey(const ValueKey('shell-home')));
      await tester.pumpAndSettle();
      await _details(tester);
      await _intake(tester);
      await _enter(tester, '1234');
      expect(find.text('PIN incorrecto.'), findsOneWidget);
      await _enter(tester, '5678');
      expect(find.byKey(const ValueKey('intake-quantity')), findsOneWidget);
    },
  );
  testWidgets('first use checks confirmation before creating device PIN', (
    tester,
  ) async {
    await _open(tester);
    await _intake(tester);
    expect(find.text('Crea un PIN'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('cost-pin-confirm')),
      '9999',
    );
    await _enter(tester, '1234');
    expect(find.text('Los PIN no coinciden.'), findsOneWidget);
    expect(await CostPinStore().isConfigured, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('cost-pin-confirm')),
      '1234',
    );
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('intake-quantity')), findsOneWidget);
    expect(await CostPinStore().verify('1234'), isTrue);
  });
  testWidgets('cost is hidden until verified and hidden on reopening', (
    tester,
  ) async {
    await CostPinStore().create('1234');
    await _open(tester);
    expect(find.text('Costo no disponible'), findsNothing);
    await tester.tap(find.text('Ver costo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Costo no disponible'), findsNothing);
    await tester.tap(find.text('Ver costo'));
    await tester.pumpAndSettle();
    await _enter(tester, '0000');
    expect(find.text('Costo no disponible'), findsNothing);
    await _enter(tester, '1234');
    expect(find.text('Costo no disponible'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('product-sheet-close')));
    await tester.pumpAndSettle();
    await _details(tester);
    expect(find.text('Costo no disponible'), findsNothing);
    expect(find.text('Ver costo'), findsOneWidget);
  });
  testWidgets('seller has no cost reveal action', (tester) async {
    await _open(tester, seller: true);
    expect(find.text('Ver costo'), findsNothing);
    expect(find.text('Costo no disponible'), findsNothing);
  });
}
