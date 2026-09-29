import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/main.dart';

class _UnauthenticatedGateway implements EmulatorSessionGateway {
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

Future<EmulatorSessionGateway> _loadUnauthenticatedGateway() async =>
    _UnauthenticatedGateway();

Future<EmulatorSessionGateway> _unexpectedEmulatorLoad() =>
    throw StateError('fixture mode must remain disconnected');

void main() {
  testWidgets('ordinary bootstrap fails closed without fixture products', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LdaInventoryBootstrap(demoEnabled: false));
    await tester.pumpAndSettle();

    expect(find.text('Catalog not connected'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Tea'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('demo bootstrap labels fixture products persistently', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LdaInventoryBootstrap(demoEnabled: true));
    await tester.pumpAndSettle();

    expect(find.text('Demo data · Not connected'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Tea'), findsOneWidget);
  });

  testWidgets('explicit local-emulator mode shows login without catalog data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        localEmulatorsEnabled: true,
        emulatorLoader: _loadUnauthenticatedGateway,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(find.text('Catalog data is not connected.'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('fixture mode stays disconnected when both flags are enabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: true,
        localEmulatorsEnabled: true,
        emulatorLoader: _unexpectedEmulatorLoad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Demo data · Not connected'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Local emulator sign in'), findsNothing);
  });

  testWidgets('injected inventory catalog renders accessibly', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    try {
      await tester.pumpWidget(
        const LdaInventoryApp(
          catalogRepository: FixtureCatalogRepository(<CatalogProduct>[
            CatalogProduct(
              internalCode: 'PRD-TEST-001',
              name: 'Test product',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.title, 'LDA Inventory');
      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Test product'), findsOneWidget);
      expect(
        find.bySemanticsLabel('QR code for Test product. Code PRD-TEST-001'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
