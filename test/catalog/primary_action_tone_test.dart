import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';

import '../sales/sale_ui_fixtures.dart';

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

Color? _fill(WidgetTester tester, Finder button) => tester
    .widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    )
    .color;

void main() {
  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light
        ? buildInventoryTheme()
        : buildDarkInventoryTheme();
    final colors = theme.colorScheme;
    final expected = brightness == Brightness.light
        ? colors.primaryContainer
        : colors.primary;
    for (final area in ['login', 'transfer', 'cart']) {
      testWidgets('$area primary fill in $brightness', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = SaleCartController(
          checkout: FakeSaleCheckout().checkout,
        );
        addTearDown(controller.dispose);
        final Widget body = switch (area) {
          'login' => EmulatorLoginShell(
            sessionGateway: Future.value(_SignedOutGateway()),
            catalogLoader: (_) async => throw UnimplementedError(),
          ),
          'transfer' => AdministratorTransferForm(
            ownerUserId: 'admin',
            branches: const [
              CatalogBranchChoice(branchId: 'north', branchName: 'Norte'),
              CatalogBranchChoice(branchId: 'south', branchName: 'Sur'),
            ],
            products: const [pinProduct],
            submitTransfer: (_) async => throw UnimplementedError(),
            unresolvedDraft: () => null,
            onClose: () {},
            onCompleted: (_) {},
          ),
          _ => SaleCartPanel(controller: controller, onClose: () {}),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: body),
          ),
        );
        await tester.pumpAndSettle();
        final primary = switch (area) {
          'login' => find.widgetWithText(FilledButton, 'Iniciar sesión'),
          'transfer' => find.byKey(const ValueKey('transfer-submit')),
          _ => find.byKey(const ValueKey('sale-charge')),
        };
        expect(primary, findsOneWidget);
        if (area == 'cart' && brightness == Brightness.light) {
          expect(tester.widget<FilledButton>(primary).onPressed, isNull);
          expect(_fill(tester, primary), colors.primaryContainer);
        }
        if (area == 'cart') {
          controller.saveEntry(
            productId: pinProduct.internalCode,
            name: pinProduct.name,
            quantitySpec: pinProduct.quantitySpec,
            quantity: '1',
          );
        }
        await tester.pumpAndSettle();
        await tester.ensureVisible(primary);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
        expect(_fill(tester, primary), expected);
        // Render a real tonal secondary under the same theme, without a shared
        // override that could accidentally make both action levels identical.
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: FilledButton.tonal(
                onPressed: () {},
                child: const Text('Secondary'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final secondary = _fill(
          tester,
          find.widgetWithText(FilledButton, 'Secondary'),
        );
        expect(secondary, colors.secondaryContainer);
        expect(secondary, isNot(expected));
      });
    }
  }
}
