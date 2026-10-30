import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/backend_environment.dart';
import 'app/inventory_theme.dart';
import 'app/inventory_theme_host.dart';
import 'auth/emulator_login.dart';
import 'auth/emulator_session.dart';
import 'catalog/catalog_load_diagnostics.dart';
import 'catalog/catalog_page.dart';
import 'catalog/catalog_product.dart';
import 'catalog/catalog_repository.dart';
import 'catalog/product_qr_scan.dart';
import 'firebase/emulator_bootstrap.dart';
import 'firebase/emulator_correction_gateway.dart';
import 'firebase/emulator_sale_gateway.dart';
import 'firebase/production_bootstrap.dart';
import 'movements/administrator_movements.dart';
import 'app/app_info.dart';
import 'version/minimum_version.dart';
import 'version/version_gate.dart';

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
    this.emulatorProductRenameLoader,
    this.emulatorStockIntakeLoader,
    this.emulatorSaleLoader,
    this.emulatorCorrectionLoader,
    this.emulatorMovementsLoader,
    this.emulatorTransferLoader,
    this.emulatorTransferNoticeLoader,
    this.minimumVersionLoader,
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
  final ProductRenameGatewayLoader? emulatorProductRenameLoader;
  final StockIntakeGatewayLoader? emulatorStockIntakeLoader;
  final SaleGatewayLoader? emulatorSaleLoader;
  final CorrectionGatewayLoader? emulatorCorrectionLoader;
  final AdministratorMovementsLoader? emulatorMovementsLoader;
  final TransferGatewayLoader? emulatorTransferLoader;

  /// Seller transfer-notice backend loader; null uses the selected connected
  /// mode's bootstrap. Demo and disconnected modes never receive it.
  final TransferNoticeBackendSessionLoader? emulatorTransferNoticeLoader;

  /// Pre-login minimum-version reader; null uses the selected connected
  /// mode's bootstrap. Demo and disconnected modes never check a version.
  final MinimumVersionSourceLoader? minimumVersionLoader;

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
        productRenameGatewayLoader:
            emulatorProductRenameLoader ??
            DemoEmulatorBootstrap.initializeProductRenameGateway,
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
        minimumVersionLoader:
            minimumVersionLoader ??
            DemoEmulatorBootstrap.initializeMinimumVersionSource,
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
        productRenameGatewayLoader:
            emulatorProductRenameLoader ??
            ProductionFirebaseBootstrap.initializeProductRenameGateway,
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
        minimumVersionLoader:
            minimumVersionLoader ??
            ProductionFirebaseBootstrap.initializeMinimumVersionSource,
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
    required this.productRenameGatewayLoader,
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
    this.minimumVersionLoader =
        DemoEmulatorBootstrap.initializeMinimumVersionSource,
    this.environment = BackendEnvironment.localEmulator,
    super.key,
  });

  /// Which backend the shell's connection copy names.
  final BackendEnvironment environment;

  final EmulatorSessionGatewayLoader loader;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader productCreationGatewayLoader;
  final ProductPricingGatewayLoader productPricingGatewayLoader;
  final ProductRenameGatewayLoader productRenameGatewayLoader;
  final StockIntakeGatewayLoader stockIntakeGatewayLoader;

  final SaleGatewayLoader saleGatewayLoader;
  final CorrectionGatewayLoader correctionGatewayLoader;
  final AdministratorMovementsLoader administratorMovementsLoader;
  final TransferGatewayLoader transferGatewayLoader;

  /// Seller-only live notice backend; the shell gates it to exact seller
  /// sessions, so administrator/disconnected flows never invoke it.
  final TransferNoticeBackendSessionLoader transferNoticeBackendLoader;

  /// Reads the minimum supported version before the login or a restored
  /// session is shown.
  final MinimumVersionSourceLoader minimumVersionLoader;

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

  /// Waits for the session start first, so the version read never races the
  /// Firebase app initialization; a failed start still runs the check.
  Future<VersionGateDecision> _checkVersion() async {
    try {
      await _gateway;
    } on Object {
      // The login shell reports session failures itself.
    }
    return checkMinimumVersion(
      installedVersion: appVersion,
      loadSource: widget.minimumVersionLoader,
    );
  }

  Future<EmulatorSessionGateway> _retry() {
    final Future<EmulatorSessionGateway> gateway = widget.loader();
    _gateway = gateway;
    return gateway;
  }

  @override
  Widget build(BuildContext context) => InventoryThemeHost(
    builder: (context, mode) => MaterialApp(
      title: 'LDA Inventory',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es')],
      theme: _theme(),
      darkTheme: buildDarkInventoryTheme(),
      themeMode: mode,
      home: VersionGate(
        check: _checkVersion,
        loadingLabel: widget.environment.connectingLabel,
        builder: (BuildContext context) => EmulatorLoginShell(
          environment: widget.environment,
          sessionGateway: _gateway,
          retryLoader: _retry,
          catalogLoader: widget.catalogLoader,
          productCreationGatewayLoader: widget.productCreationGatewayLoader,
          productPricingGatewayLoader: widget.productPricingGatewayLoader,
          productRenameGatewayLoader: widget.productRenameGatewayLoader,
          stockIntakeGatewayLoader: widget.stockIntakeGatewayLoader,
          saleGatewayLoader: widget.saleGatewayLoader,
          correctionGatewayLoader: widget.correctionGatewayLoader,
          administratorMovementsLoader: widget.administratorMovementsLoader,
          transferGatewayLoader: widget.transferGatewayLoader,
          transferNoticeBackendLoader: widget.transferNoticeBackendLoader,
        ),
      ),
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
    return InventoryThemeHost(
      builder: (context, mode) => MaterialApp(
        title: 'LDA Inventory',
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es')],
        theme: _theme(),
        darkTheme: buildDarkInventoryTheme(),
        themeMode: mode,
        home: CatalogPage(
          repository: catalogRepository,
          statusLabel: statusLabel,
          qrScan: productQrScanSupported ? showProductQrScanner : null,
        ),
      ),
    );
  }
}

class CatalogSetupApp extends StatelessWidget {
  const CatalogSetupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return InventoryThemeHost(
      builder: (context, mode) => MaterialApp(
        title: 'LDA Inventory',
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es')],
        theme: _theme(),
        darkTheme: buildDarkInventoryTheme(),
        themeMode: mode,
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
      ),
    );
  }
}

ThemeData _theme() => buildInventoryTheme();

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
