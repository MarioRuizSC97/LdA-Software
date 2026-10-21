import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/firebase/emulator_bootstrap.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_stock_intake_gateway.dart';
import 'package:lda_inventory/firebase/production_bootstrap.dart';
import 'package:lda_inventory/main.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

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

Future<ProductCreationGateway> _unexpectedFunctionsLoad(
  EmulatorSession session,
) => throw StateError('fixture mode must never initialize Functions');

Future<ProductPricingGateway> _unexpectedPricingLoad(EmulatorSession session) =>
    throw StateError('fixture mode must never initialize pricing Functions');

Future<EmulatorStockIntakeGateway> _unexpectedStockIntakeLoad(
  EmulatorSession session,
) => throw StateError('fixture mode must never initialize intake Functions');

Future<EmulatorCorrectionGateway> _unexpectedCorrectionLoad(
  EmulatorSession session,
) => throw StateError('the shell must not initialize corrections eagerly');

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway(this.restored);

  final EmulatorSession? restored;

  @override
  Future<EmulatorSession?> restoreSession() async => restored;

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

class _RecordingNoticeStreams implements TransferNoticeStreamSource {
  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      const Stream<TransferNoticeStreamEnvelope>.empty();

  @override
  Stream<TransferNoticeStreamEnvelope> markers() =>
      const Stream<TransferNoticeStreamEnvelope>.empty();
}

class _RecordingNoticeLoader {
  int calls = 0;
  final List<EmulatorSession> sessions = <EmulatorSession>[];

  Future<TransferNoticeBackend> call(EmulatorSession session) async {
    calls += 1;
    sessions.add(session);
    return TransferNoticeBackend(
      streams: _RecordingNoticeStreams(),
      markRead: (_) async => null,
    );
  }
}

void main() {
  testWidgets('ordinary bootstrap fails closed without fixture products', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        emulatorProductCreationLoader: _unexpectedFunctionsLoad,
        emulatorProductPricingLoader: _unexpectedPricingLoad,
        emulatorStockIntakeLoader: _unexpectedStockIntakeLoad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Catálogo sin conexión'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Tea'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('demo bootstrap labels fixture products persistently', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LdaInventoryBootstrap(demoEnabled: true));
    await tester.pumpAndSettle();

    expect(find.text('Datos de demostración · Sin conexión'), findsOneWidget);
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

    expect(find.text('Inicio de sesión en el emulador local'), findsOneWidget);
    expect(
      find.text('Los datos del catálogo no están conectados.'),
      findsOneWidget,
    );
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('local-emulator mode hands the correction loader to the shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        localEmulatorsEnabled: true,
        emulatorLoader: _loadUnauthenticatedGateway,
        emulatorCorrectionLoader: _unexpectedCorrectionLoad,
      ),
    );
    await tester.pumpAndSettle();

    final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
      find.byType(EmulatorLoginShell),
    );
    expect(shell.correctionGatewayLoader, same(_unexpectedCorrectionLoad));
  });

  testWidgets('production mode shows a login that never names the emulator', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        productionEnabled: true,
        emulatorLoader: _loadUnauthenticatedGateway,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Inicio de sesión'), findsOneWidget);
    expect(find.textContaining('emulador'), findsNothing);
    final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
      find.byType(EmulatorLoginShell),
    );
    expect(shell.environment, BackendEnvironment.production);
  });

  testWidgets('production mode defaults to the production session loader', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(demoEnabled: false, productionEnabled: true),
    );

    final LocalEmulatorAuthApp app = tester.widget<LocalEmulatorAuthApp>(
      find.byType(LocalEmulatorAuthApp),
    );
    expect(app.loader, same(ProductionFirebaseBootstrap.initialize));
    expect(app.environment, BackendEnvironment.production);
  });

  testWidgets('production mode defaults to the production loaders', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        productionEnabled: true,
        emulatorLoader: _loadUnauthenticatedGateway,
      ),
    );
    await tester.pumpAndSettle();

    final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
      find.byType(EmulatorLoginShell),
    );
    expect(
      shell.productCreationGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeProductCreationGateway),
    );
    expect(
      shell.productPricingGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeProductPricingGateway),
    );
    expect(
      shell.stockIntakeGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeStockIntakeGateway),
    );
    expect(
      shell.saleGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeSaleGateway),
    );
    expect(
      shell.correctionGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeCorrectionGateway),
    );
    expect(
      shell.administratorMovementsLoader,
      same(ProductionFirebaseBootstrap.initializeAdministratorMovements),
    );
    expect(
      shell.transferGatewayLoader,
      same(ProductionFirebaseBootstrap.initializeTransferGateway),
    );
    expect(
      shell.transferNoticeBackendLoader,
      same(ProductionFirebaseBootstrap.initializeTransferNoticeBackend),
    );
  });

  testWidgets(
    'rename gateway loader defaults follow the selected connected mode',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const LdaInventoryBootstrap(
          demoEnabled: false,
          productionEnabled: true,
          emulatorLoader: _loadUnauthenticatedGateway,
        ),
      );
      await tester.pumpAndSettle();

      EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
        find.byType(EmulatorLoginShell),
      );
      expect(
        shell.productRenameGatewayLoader,
        same(ProductionFirebaseBootstrap.initializeProductRenameGateway),
      );

      await tester.pumpWidget(
        const LdaInventoryBootstrap(
          demoEnabled: false,
          localEmulatorsEnabled: true,
          emulatorLoader: _loadUnauthenticatedGateway,
        ),
      );
      await tester.pumpAndSettle();

      shell = tester.widget<EmulatorLoginShell>(
        find.byType(EmulatorLoginShell),
      );
      expect(
        shell.productRenameGatewayLoader,
        same(DemoEmulatorBootstrap.initializeProductRenameGateway),
      );
    },
  );

  testWidgets('production and local-emulator flags together stay offline', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: false,
        localEmulatorsEnabled: true,
        productionEnabled: true,
        emulatorLoader: _unexpectedEmulatorLoad,
        emulatorProductCreationLoader: _unexpectedFunctionsLoad,
        emulatorProductPricingLoader: _unexpectedPricingLoad,
        emulatorStockIntakeLoader: _unexpectedStockIntakeLoad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Catálogo sin conexión'), findsOneWidget);
    expect(find.byType(EmulatorLoginShell), findsNothing);
  });

  testWidgets('fixture mode stays disconnected when both flags are enabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const LdaInventoryBootstrap(
        demoEnabled: true,
        localEmulatorsEnabled: true,
        emulatorLoader: _unexpectedEmulatorLoad,
        emulatorProductCreationLoader: _unexpectedFunctionsLoad,
        emulatorProductPricingLoader: _unexpectedPricingLoad,
        emulatorStockIntakeLoader: _unexpectedStockIntakeLoad,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Datos de demostración · Sin conexión'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Inicio de sesión en el emulador local'), findsNothing);
  });

  group('transfer notice bootstrap wiring (B1)', () {
    const EmulatorSession sellerSession = EmulatorSession(
      userId: 'seller-1',
      email: 'seller@demo.invalid',
      role: InventoryRole.seller,
      branchId: 'branch-north',
    );
    const EmulatorSession adminSession = EmulatorSession(
      userId: 'administrator-1',
      email: 'admin@demo.invalid',
      role: InventoryRole.administrator,
    );

    CatalogSnapshot sellerSnapshot() => CatalogSnapshot(<CatalogItem>[
      CatalogItem(
        product: const CatalogProduct(
          internalCode: 'PRD-COFFEE-001',
          name: 'Coffee',
          quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
        ),
        holdings: const <CatalogHolding>[
          CatalogHolding(
            branchId: 'branch-north',
            branchName: 'North Demo Branch',
            quantityScaled: 1000,
          ),
        ],
      ),
    ]);

    testWidgets(
      'local-emulator seller sees the live notice badge and binds the backend',
      (WidgetTester tester) async {
        final _RecordingNoticeLoader loader = _RecordingNoticeLoader();
        await tester.pumpWidget(
          LdaInventoryBootstrap(
            demoEnabled: false,
            localEmulatorsEnabled: true,
            emulatorLoader: () async => _SessionGateway(sellerSession),
            emulatorCatalogLoader: (_) async => sellerSnapshot(),
            emulatorTransferNoticeLoader: loader.call,
          ),
        );
        await tester.pumpAndSettle();

        // Notices live in the overflow menu (T10/S10); its items are built
        // at open time.
        await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey<String>('notices-open')),
          findsOneWidget,
        );
        expect(loader.calls, 1);
        expect(loader.sessions.single.userId, 'seller-1');
        expect(loader.sessions.single.branchId, 'branch-north');
      },
    );

    testWidgets('local-emulator administrator never loads the seller backend', (
      WidgetTester tester,
    ) async {
      final _RecordingNoticeLoader loader = _RecordingNoticeLoader();
      await tester.pumpWidget(
        LdaInventoryBootstrap(
          demoEnabled: false,
          localEmulatorsEnabled: true,
          emulatorLoader: () async => _SessionGateway(adminSession),
          emulatorCatalogLoader: (_) async => sellerSnapshot(),
          emulatorTransferNoticeLoader: loader.call,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
      expect(loader.calls, 0);
    });

    testWidgets('demo mode never loads or shows notices', (
      WidgetTester tester,
    ) async {
      final _RecordingNoticeLoader loader = _RecordingNoticeLoader();
      await tester.pumpWidget(
        LdaInventoryBootstrap(
          demoEnabled: true,
          localEmulatorsEnabled: true,
          emulatorTransferNoticeLoader: loader.call,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmulatorLoginShell), findsNothing);
      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
      expect(loader.calls, 0);
    });

    testWidgets('disconnected mode never loads notices', (
      WidgetTester tester,
    ) async {
      final _RecordingNoticeLoader loader = _RecordingNoticeLoader();
      await tester.pumpWidget(
        LdaInventoryBootstrap(
          demoEnabled: false,
          emulatorTransferNoticeLoader: loader.call,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Catálogo sin conexión'), findsOneWidget);
      expect(loader.calls, 0);
    });

    testWidgets(
      'local-emulator bootstrap defaults to the live notice backend loader',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const LdaInventoryBootstrap(
            demoEnabled: false,
            localEmulatorsEnabled: true,
            emulatorLoader: _loadUnauthenticatedGateway,
          ),
        );
        await tester.pumpAndSettle();

        final EmulatorLoginShell shell = tester.widget<EmulatorLoginShell>(
          find.byType(EmulatorLoginShell),
        );
        expect(
          shell.transferNoticeBackendLoader,
          same(DemoEmulatorBootstrap.initializeTransferNoticeBackend),
        );
      },
    );
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
      expect(find.text('Catálogo'), findsOneWidget);
      expect(find.text('Test product'), findsOneWidget);
      // The QR lives in the product detail sheet (S5).
      await tester.tap(
        find.byKey(const ValueKey<String>('product-details-PRD-TEST-001')),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Código QR de Test product. Código PRD-TEST-001'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
