import 'package:flutter/material.dart';

import 'auth/emulator_login.dart';
import 'auth/emulator_session.dart';
import 'catalog/catalog_load_diagnostics.dart';
import 'catalog/catalog_page.dart';
import 'catalog/catalog_product.dart';
import 'catalog/catalog_repository.dart';
import 'firebase/emulator_bootstrap.dart';
import 'firebase/emulator_correction_gateway.dart';
import 'firebase/emulator_sale_gateway.dart';
import 'movements/administrator_movements.dart';

const bool _demoCatalogEnabled = bool.fromEnvironment('LDA_DEMO_CATALOG');
const bool _localEmulatorsEnabled = bool.fromEnvironment('LDA_LOCAL_EMULATORS');

void main() {
  runApp(
    const LdaInventoryBootstrap(
      demoEnabled: _demoCatalogEnabled,
      localEmulatorsEnabled: _localEmulatorsEnabled,
    ),
  );
}

class LdaInventoryBootstrap extends StatelessWidget {
  const LdaInventoryBootstrap({
    required this.demoEnabled,
    this.localEmulatorsEnabled = false,
    this.emulatorLoader,
    this.emulatorCatalogLoader,
    this.emulatorProductCreationLoader,
    this.emulatorProductPricingLoader,
    this.emulatorStockIntakeLoader,
    this.emulatorSaleLoader,
    this.emulatorCorrectionLoader,
    this.emulatorMovementsLoader,
    super.key,
  });

  final bool demoEnabled;
  final bool localEmulatorsEnabled;
  final EmulatorSessionGatewayLoader? emulatorLoader;
  final CatalogSnapshotLoader? emulatorCatalogLoader;
  final ProductCreationGatewayLoader? emulatorProductCreationLoader;
  final ProductPricingGatewayLoader? emulatorProductPricingLoader;
  final StockIntakeGatewayLoader? emulatorStockIntakeLoader;
  final SaleGatewayLoader? emulatorSaleLoader;
  final CorrectionGatewayLoader? emulatorCorrectionLoader;
  final AdministratorMovementsLoader? emulatorMovementsLoader;

  @override
  Widget build(BuildContext context) {
    if (demoEnabled) {
      return const LdaInventoryApp(
        catalogRepository: FixtureCatalogRepository(_catalogFixtures),
        statusLabel: 'Demo data · Not connected',
      );
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
    super.key,
  });

  final EmulatorSessionGatewayLoader loader;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader productCreationGatewayLoader;
  final ProductPricingGatewayLoader productPricingGatewayLoader;
  final StockIntakeGatewayLoader stockIntakeGatewayLoader;

  final SaleGatewayLoader saleGatewayLoader;
  final CorrectionGatewayLoader correctionGatewayLoader;
  final AdministratorMovementsLoader administratorMovementsLoader;

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
      sessionGateway: _gateway,
      retryLoader: _retry,
      catalogLoader: widget.catalogLoader,
      productCreationGatewayLoader: widget.productCreationGatewayLoader,
      productPricingGatewayLoader: widget.productPricingGatewayLoader,
      stockIntakeGatewayLoader: widget.stockIntakeGatewayLoader,
      saleGatewayLoader: widget.saleGatewayLoader,
      correctionGatewayLoader: widget.correctionGatewayLoader,
      administratorMovementsLoader: widget.administratorMovementsLoader,
    ),
  );
}

Future<CatalogSnapshot> _loadLiveCatalog(EmulatorSession session) =>
    guardCatalogBootstrap(() async {
      final RoleScopedCatalogRepository repository =
          await DemoEmulatorBootstrap.initializeCatalogRepository(session);
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
                      'Catalog not connected',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No product data is loaded. Authenticated emulator access '
                    'has not been configured.',
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
