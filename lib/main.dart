import 'package:flutter/material.dart';

import 'app/backend_environment.dart';
import 'auth/emulator_login.dart';
import 'auth/emulator_session.dart';
import 'catalog/catalog_load_diagnostics.dart';
import 'catalog/catalog_page.dart';
import 'catalog/catalog_product.dart';
import 'catalog/catalog_repository.dart';
import 'firebase/emulator_bootstrap.dart';
import 'firebase/emulator_correction_gateway.dart';
import 'firebase/emulator_sale_gateway.dart';
import 'firebase/production_bootstrap.dart';
import 'movements/administrator_movements.dart';

const bool _demoCatalogEnabled = bool.fromEnvironment('LDA_DEMO_CATALOG');
const bool _localEmulatorsEnabled = bool.fromEnvironment('LDA_LOCAL_EMULATORS');
const bool _productionEnabled = bool.fromEnvironment('LDA_FIREBASE_PRODUCTION');

void main() {
  runApp(
    const LdaInventoryBootstrap(
      demoEnabled: _demoCatalogEnabled,
      localEmulatorsEnabled: _localEmulatorsEnabled,
      productionEnabled: _productionEnabled,
    ),
  );
}

class LdaInventoryBootstrap extends StatelessWidget {
  const LdaInventoryBootstrap({
    required this.demoEnabled,
    this.localEmulatorsEnabled = false,
    this.productionEnabled = false,
    this.emulatorLoader,
    this.emulatorCatalogLoader,
    this.emulatorProductCreationLoader,
    this.emulatorProductPricingLoader,
    this.emulatorStockIntakeLoader,
    this.emulatorSaleLoader,
    this.emulatorCorrectionLoader,
    this.emulatorMovementsLoader,
    this.emulatorTransferLoader,
    this.emulatorTransferNoticeLoader,
    super.key,
  });

  final bool demoEnabled;
  final bool localEmulatorsEnabled;

  /// Connects to the real Firebase project. Combined with
  /// [localEmulatorsEnabled] the choice is ambiguous, so the app stays offline.
  final bool productionEnabled;

  // The loader overrides below exist for tests and apply to whichever
  // connected mode is selected; null uses that mode's own bootstrap.
  final EmulatorSessionGatewayLoader? emulatorLoader;
  final CatalogSnapshotLoader? emulatorCatalogLoader;
  final ProductCreationGatewayLoader? emulatorProductCreationLoader;
  final ProductPricingGatewayLoader? emulatorProductPricingLoader;
  final StockIntakeGatewayLoader? emulatorStockIntakeLoader;
  final SaleGatewayLoader? emulatorSaleLoader;
  final CorrectionGatewayLoader? emulatorCorrectionLoader;
  final AdministratorMovementsLoader? emulatorMovementsLoader;
  final TransferGatewayLoader? emulatorTransferLoader;

  /// Seller transfer-notice backend loader; null uses the selected connected
  /// mode's bootstrap. Demo and disconnected modes never receive it.
  final TransferNoticeBackendSessionLoader? emulatorTransferNoticeLoader;

  @override
  Widget build(BuildContext context) {
    if (demoEnabled) {
      return const LdaInventoryApp(
        catalogRepository: FixtureCatalogRepository(_catalogFixtures),
        statusLabel: 'Datos de demostración · Sin conexión',
      );
    }
    if (localEmulatorsEnabled && productionEnabled) {
      return const CatalogSetupApp();
    }
    if (localEmulatorsEnabled) {
      return LocalEmulatorAuthApp(
        loader: emulatorLoader ?? DemoEmulatorBootstrap.initialize,
        catalogLoader: emulatorCatalogLoader ?? _loadLiveCatalog,
        productCreationGatewayLoader:
            emulatorProductCreationLoader ??
            DemoEmulatorBootstrap.initializeProductCreationGateway,
        productPricingGatewayLoader:
            emulatorProductPricingLoader ??
            DemoEmulatorBootstrap.initializeProductPricingGateway,
        stockIntakeGatewayLoader:
            emulatorStockIntakeLoader ??
            DemoEmulatorBootstrap.initializeStockIntakeGateway,
        saleGatewayLoader:
            emulatorSaleLoader ?? DemoEmulatorBootstrap.initializeSaleGateway,
        correctionGatewayLoader:
            emulatorCorrectionLoader ??
            DemoEmulatorBootstrap.initializeCorrectionGateway,
        administratorMovementsLoader:
            emulatorMovementsLoader ??
            DemoEmulatorBootstrap.initializeAdministratorMovements,
        transferGatewayLoader:
            emulatorTransferLoader ??
            DemoEmulatorBootstrap.initializeTransferGateway,
        transferNoticeBackendLoader:
            emulatorTransferNoticeLoader ??
            DemoEmulatorBootstrap.initializeTransferNoticeBackend,
      );
    }
    if (productionEnabled) {
      return LocalEmulatorAuthApp(
        environment: BackendEnvironment.production,
        loader: emulatorLoader ?? ProductionFirebaseBootstrap.initialize,
        catalogLoader: emulatorCatalogLoader ?? _loadProductionCatalog,
        productCreationGatewayLoader:
            emulatorProductCreationLoader ??
            ProductionFirebaseBootstrap.initializeProductCreationGateway,
        productPricingGatewayLoader:
            emulatorProductPricingLoader ??
            ProductionFirebaseBootstrap.initializeProductPricingGateway,
        stockIntakeGatewayLoader:
            emulatorStockIntakeLoader ??
            ProductionFirebaseBootstrap.initializeStockIntakeGateway,
        saleGatewayLoader:
            emulatorSaleLoader ??
            ProductionFirebaseBootstrap.initializeSaleGateway,
        correctionGatewayLoader:
            emulatorCorrectionLoader ??
            ProductionFirebaseBootstrap.initializeCorrectionGateway,
        administratorMovementsLoader:
            emulatorMovementsLoader ??
            ProductionFirebaseBootstrap.initializeAdministratorMovements,
        transferGatewayLoader:
            emulatorTransferLoader ??
            ProductionFirebaseBootstrap.initializeTransferGateway,
        transferNoticeBackendLoader:
            emulatorTransferNoticeLoader ??
            ProductionFirebaseBootstrap.initializeTransferNoticeBackend,
      );
    }
    return const CatalogSetupApp();
  }
}

class LocalEmulatorAuthApp extends StatefulWidget {
  const LocalEmulatorAuthApp({
    required this.loader,
    required this.catalogLoader,
    required this.productCreationGatewayLoader,
    required this.productPricingGatewayLoader,
    required this.stockIntakeGatewayLoader,
    this.saleGatewayLoader = DemoEmulatorBootstrap.initializeSaleGateway,
    this.correctionGatewayLoader =
        DemoEmulatorBootstrap.initializeCorrectionGateway,
    this.administratorMovementsLoader =
        DemoEmulatorBootstrap.initializeAdministratorMovements,
    this.transferGatewayLoader =
        DemoEmulatorBootstrap.initializeTransferGateway,
    this.transferNoticeBackendLoader =
        DemoEmulatorBootstrap.initializeTransferNoticeBackend,
    this.environment = BackendEnvironment.localEmulator,
    super.key,
  });

  /// Which backend the shell's connection copy names.
  final BackendEnvironment environment;

  final EmulatorSessionGatewayLoader loader;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader productCreationGatewayLoader;
  final ProductPricingGatewayLoader productPricingGatewayLoader;
  final StockIntakeGatewayLoader stockIntakeGatewayLoader;

  final SaleGatewayLoader saleGatewayLoader;
  final CorrectionGatewayLoader correctionGatewayLoader;
  final AdministratorMovementsLoader administratorMovementsLoader;
  final TransferGatewayLoader transferGatewayLoader;

  /// Seller-only live notice backend; the shell gates it to exact seller
  /// sessions, so administrator/disconnected flows never invoke it.
  final TransferNoticeBackendSessionLoader transferNoticeBackendLoader;

  @override
  State<LocalEmulatorAuthApp> createState() => _LocalEmulatorAuthAppState();
}

class _LocalEmulatorAuthAppState extends State<LocalEmulatorAuthApp> {
  late Future<EmulatorSessionGateway> _gateway;

  @override
  void initState() {
    super.initState();
    _gateway = widget.loader();
  }

  Future<EmulatorSessionGateway> _retry() {
    final Future<EmulatorSessionGateway> gateway = widget.loader();
    _gateway = gateway;
    return gateway;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LDA Inventory',
    theme: _theme(),
    home: EmulatorLoginShell(
      environment: widget.environment,
      sessionGateway: _gateway,
      retryLoader: _retry,
      catalogLoader: widget.catalogLoader,
      productCreationGatewayLoader: widget.productCreationGatewayLoader,
      productPricingGatewayLoader: widget.productPricingGatewayLoader,
      stockIntakeGatewayLoader: widget.stockIntakeGatewayLoader,
      saleGatewayLoader: widget.saleGatewayLoader,
      correctionGatewayLoader: widget.correctionGatewayLoader,
      administratorMovementsLoader: widget.administratorMovementsLoader,
      transferGatewayLoader: widget.transferGatewayLoader,
      transferNoticeBackendLoader: widget.transferNoticeBackendLoader,
    ),
  );
}

Future<CatalogSnapshot> _loadLiveCatalog(EmulatorSession session) =>
    guardCatalogBootstrap(() async {
      final RoleScopedCatalogRepository repository =
          await DemoEmulatorBootstrap.initializeCatalogRepository(session);
      return repository.fetchCatalog();
    });

Future<CatalogSnapshot> _loadProductionCatalog(EmulatorSession session) =>
    guardCatalogBootstrap(() async {
      final RoleScopedCatalogRepository repository =
          await ProductionFirebaseBootstrap.initializeCatalogRepository(
            session,
          );
      return repository.fetchCatalog();
    });

class LdaInventoryApp extends StatelessWidget {
  const LdaInventoryApp({
    required this.catalogRepository,
    this.statusLabel,
    super.key,
  });

  final CatalogRepository catalogRepository;
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LDA Inventory',
      theme: _theme(),
      home: CatalogPage(
        repository: catalogRepository,
        statusLabel: statusLabel,
      ),
    );
  }
}

class CatalogSetupApp extends StatelessWidget {
  const CatalogSetupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LDA Inventory',
      theme: _theme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('LDA Inventory')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.cloud_off_outlined, size: 56),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(
                      'Catálogo sin conexión',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No hay datos de productos cargados. No se ha configurado '
                    'el acceso autenticado al emulador.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ThemeData _theme() {
  return ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
}

const List<CatalogProduct> _catalogFixtures = <CatalogProduct>[
  CatalogProduct(
    internalCode: 'PRD-COFFEE-001',
    name: 'Coffee',
    quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
    pricing: CatalogPricing(
      listedPriceCentavos: 12900,
      currency: 'MXN',
      priceMode: 'iva-included',
      ivaTreatment: 'taxable',
      ivaRateBasisPoints: 1600,
    ),
  ),
  CatalogProduct(
    internalCode: 'PRD-TEA-002',
    name: 'Tea',
    quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
  ),
];
