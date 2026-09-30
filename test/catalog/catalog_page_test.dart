import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

class _Repository implements CatalogRepository {
  _Repository(this.result);

  final Future<List<CatalogProduct>> result;

  @override
  Future<List<CatalogProduct>> fetchProducts() => result;
}

class _CatalogLoader {
  final List<Completer<CatalogSnapshot>> requests =
      <Completer<CatalogSnapshot>>[];
  final List<EmulatorSession> sessions = <EmulatorSession>[];

  Future<CatalogSnapshot> call(EmulatorSession session) {
    sessions.add(session);
    final Completer<CatalogSnapshot> request = Completer<CatalogSnapshot>();
    requests.add(request);
    return request.future;
  }
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

CatalogSnapshot _snapshot(
  CatalogProduct product, {
  List<CatalogHolding> holdings = const <CatalogHolding>[],
}) => CatalogSnapshot(<CatalogItem>[
  CatalogItem(product: product, holdings: holdings),
]);

Widget _authenticatedApp({
  required EmulatorSession session,
  required CatalogSnapshotLoader loader,
  ProductCreationSubmit? createProduct,
  ProductDraftIdFactory? createDraftId,
  ProductCreationDraft? unresolvedProductDraft,
  ProductPricingSubmit? setProductPrice,
  ProductPricingIdFactory? createPricingId,
  List<ProductPricingDraft> unresolvedPricingDrafts =
      const <ProductPricingDraft>[],
  ProductPricingDraftLookup? unresolvedPricingDraftForProduct,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: loader,
    createProduct: createProduct,
    createDraftId: createDraftId,
    unresolvedProductDraft: unresolvedProductDraft,
    setProductPrice: setProductPrice,
    createPricingId: createPricingId,
    unresolvedPricingDrafts: unresolvedPricingDrafts,
    unresolvedPricingDraftForProduct: unresolvedPricingDraftForProduct,
    onLogout: () async {},
  ),
);

const CatalogProduct _coffee = CatalogProduct(
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
);

Widget _app(CatalogRepository repository) =>
    MaterialApp(home: CatalogPage(repository: repository));

void main() {
  testWidgets('shows an accessible loading state', (WidgetTester tester) async {
    final Completer<List<CatalogProduct>> completer =
        Completer<List<CatalogProduct>>();

    await tester.pumpWidget(_app(_Repository(completer.future)));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);
  });

  testWidgets('shows an empty catalog state', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('No products yet'), findsOneWidget);
    expect(
      find.text('Products will appear here when available.'),
      findsOneWidget,
    );
  });

  testWidgets('shows an error without leaking technical details', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Repository(
          Future<List<CatalogProduct>>.delayed(
            Duration.zero,
            () => throw 'secret-stack-value',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.textContaining('secret-stack-value'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('renders the exact internal code as the QR data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[_coffee]))),
    );
    await tester.pumpAndSettle();

    final ProductQrView qr = tester.widget<ProductQrView>(
      find.byType(ProductQrView),
    );
    expect(ProductQr.payloadFor(qr.product), 'PRD-COFFEE-001');
    expect(
      find.byKey(const ValueKey<String>('product-qr-PRD-COFFEE-001')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('QR code for Coffee. Code PRD-COFFEE-001'),
      findsOneWidget,
    );
    expect(find.text('Listed price: 129.00 MXN'), findsOneWidget);
    expect(find.text('Price mode: IVA included'), findsOneWidget);
    expect(find.text('IVA treatment: Taxable'), findsOneWidget);
    expect(find.text('IVA rate: 16%'), findsOneWidget);
    expect(find.textContaining('acquisition'), findsNothing);
    expect(find.textContaining('admin'), findsNothing);
  });

  testWidgets('fits narrow and wide layouts without overflow', (
    WidgetTester tester,
  ) async {
    for (final Size size in <Size>[
      const Size(320, 700),
      const Size(1200, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        _app(_Repository(Future.value(<CatalogProduct>[_coffee]))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('loads once and seller zero stock is labeled Agotado', (
    WidgetTester tester,
  ) async {
    final _CatalogLoader loader = _CatalogLoader();
    await tester.pumpWidget(
      _authenticatedApp(session: _seller, loader: loader.call),
    );

    expect(loader.requests, hasLength(1));
    expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);
    loader.requests.single.complete(
      _snapshot(
        _coffee,
        holdings: const <CatalogHolding>[
          CatalogHolding(
            branchId: 'branch-north',
            branchName: 'North Demo Branch',
            quantityScaled: 0,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.textContaining('North Demo Branch'), findsNothing);
    expect(loader.requests, hasLength(1));
  });

  testWidgets('manual refresh clears stale data and displays new snapshot', (
    WidgetTester tester,
  ) async {
    final _CatalogLoader loader = _CatalogLoader();
    await tester.pumpWidget(
      _authenticatedApp(session: _seller, loader: loader.call),
    );
    loader.requests.single.complete(
      _snapshot(
        _coffee,
        holdings: const <CatalogHolding>[
          CatalogHolding(branchId: 'branch-north', quantityScaled: 125),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Refresh catalog'));
    await tester.pump();

    expect(loader.requests, hasLength(2));
    expect(find.text('Coffee'), findsNothing);
    expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);

    const CatalogProduct tea = CatalogProduct(
      internalCode: 'PRD-TEA-002',
      name: 'Tea',
      quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
    );
    loader.requests.last.complete(
      _snapshot(
        tea,
        holdings: const <CatalogHolding>[
          CatalogHolding(branchId: 'branch-north', quantityScaled: 4),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Tea'), findsOneWidget);
    expect(find.text('Stock: 4 piece'), findsOneWidget);
  });

  testWidgets('administrator sees named zero holdings and no-holdings state', (
    WidgetTester tester,
  ) async {
    Future<CatalogSnapshot> load(EmulatorSession session) async =>
        CatalogSnapshot(<CatalogItem>[
          CatalogItem(
            product: _coffee,
            holdings: const <CatalogHolding>[
              CatalogHolding(
                branchId: 'branch-north',
                branchName: 'North Demo Branch',
                quantityScaled: 0,
              ),
              CatalogHolding(
                branchId: 'branch-south',
                branchName: 'South Demo Branch',
                quantityScaled: 250,
              ),
            ],
          ),
          CatalogItem(
            product: const CatalogProduct(
              internalCode: 'PRD-UNHELD-003',
              name: 'Unheld product',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
            holdings: const <CatalogHolding>[],
          ),
        ]);

    await tester.pumpWidget(
      _authenticatedApp(session: _administrator, loader: load),
    );
    await tester.pumpAndSettle();

    expect(find.text('North Demo Branch: 0.00 kg · Agotado'), findsOneWidget);
    expect(find.text('South Demo Branch: 2.50 kg'), findsOneWidget);
    expect(find.text('No branch holdings'), findsOneWidget);
  });

  testWidgets('empty catalog is explicit', (WidgetTester tester) async {
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No products yet'), findsOneWidget);
  });

  testWidgets('rejects cross-branch seller data and retries safely', (
    WidgetTester tester,
  ) async {
    var calls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      calls += 1;
      return _snapshot(
        _coffee,
        holdings: <CatalogHolding>[
          CatalogHolding(
            branchId: calls == 1 ? 'branch-south' : 'branch-north',
            quantityScaled: calls == 1 ? 999 : 100,
          ),
        ],
      );
    }

    await tester.pumpWidget(_authenticatedApp(session: _seller, loader: load));
    await tester.pumpAndSettle();

    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Stock: 9.99 kg'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Stock: 1.00 kg'), findsOneWidget);
  });

  testWidgets('rejects missing and multiple seller holdings', (
    WidgetTester tester,
  ) async {
    for (final List<CatalogHolding> holdings in <List<CatalogHolding>>[
      const <CatalogHolding>[],
      const <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 100),
        CatalogHolding(branchId: 'branch-north', quantityScaled: 200),
      ],
    ]) {
      await tester.pumpWidget(
        _authenticatedApp(
          session: _seller,
          loader: (_) async => _snapshot(_coffee, holdings: holdings),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Catalog unavailable'), findsOneWidget);
      expect(find.text('Coffee'), findsNothing);
    }
  });

  testWidgets('administrator rejects unnamed or invalid branch names', (
    WidgetTester tester,
  ) async {
    for (final String? branchName in <String?>[null, '', ' North Branch']) {
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(
            _coffee,
            holdings: <CatalogHolding>[
              CatalogHolding(
                branchId: 'branch-north',
                branchName: branchName,
                quantityScaled: 500,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Catalog unavailable'), findsOneWidget);
      expect(find.textContaining('branch-north:'), findsNothing);
      expect(find.text('Coffee'), findsNothing);
    }
  });

  testWidgets('authenticated catalog fits a narrow viewport', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    await tester.pumpWidget(
      _authenticatedApp(
        session: _seller,
        loader: (_) async => _snapshot(
          _coffee,
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 100),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('catalog error is sanitized and retryable', (
    WidgetTester tester,
  ) async {
    var calls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      calls += 1;
      if (calls == 1) throw StateError('secret firestore sdk detail');
      return _snapshot(
        _coffee,
        holdings: const <CatalogHolding>[
          CatalogHolding(branchId: 'branch-north', quantityScaled: 100),
        ],
      );
    }

    await tester.pumpWidget(_authenticatedApp(session: _seller, loader: load));
    await tester.pumpAndSettle();

    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.textContaining('secret firestore sdk detail'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Coffee'), findsOneWidget);
  });

  testWidgets('session replacement clears data and ignores stale completion', (
    WidgetTester tester,
  ) async {
    final _CatalogLoader loader = _CatalogLoader();
    await tester.pumpWidget(
      _authenticatedApp(session: _seller, loader: loader.call),
    );
    expect(loader.requests, hasLength(1));

    await tester.pumpWidget(
      _authenticatedApp(session: _administrator, loader: loader.call),
    );
    await tester.pump();
    expect(loader.requests, hasLength(2));
    expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);

    loader.requests.first.complete(_snapshot(_coffee));
    await tester.pump();
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Catalog unavailable'), findsNothing);

    const CatalogProduct tea = CatalogProduct(
      internalCode: 'PRD-TEA-002',
      name: 'Tea',
      quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
    );
    loader.requests.last.complete(_snapshot(tea));
    await tester.pumpAndSettle();
    expect(find.text('Tea'), findsOneWidget);
  });

  testWidgets('seller has no product creation control or callback', (
    WidgetTester tester,
  ) async {
    var creationCalls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _seller,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
        createProduct: (_) async {
          creationCalls += 1;
          return const ProductCreationResult(
            productId: 'PRD-INVALID-001',
            internalCode: 'PRD-INVALID-001',
            replayed: false,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Create product'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('create-product-name')),
      findsNothing,
    );
    expect(creationCalls, 0);
  });

  testWidgets(
    'admin validation preserves exact name and reports accessible errors',
    (WidgetTester tester) async {
      final List<ProductCreationDraft> requests = <ProductCreationDraft>[];
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
          createDraftId: () => 'draft-key-1',
          createProduct: (ProductCreationDraft draft) async {
            requests.add(draft);
            return const ProductCreationResult(
              productId: 'PRD-COFFEE-001',
              internalCode: 'PRD-COFFEE-001',
              replayed: false,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create product'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Product name'), findsOneWidget);
      expect(find.bySemanticsLabel('Unit identifier'), findsOneWidget);
      expect(find.bySemanticsLabel('Quantity precision'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        ' Coffee ',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'Piece',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-precision')),
        '7',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pump();

      expect(find.bySemanticsLabel('Product creation error'), findsOneWidget);
      expect(find.textContaining('canonical'), findsOneWidget);
      expect(requests, isEmpty);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('create-product-name')),
            )
            .controller
            ?.text,
        ' Coffee ',
      );
    },
  );

  testWidgets('uncertain retry locks fields and reuses identical request', (
    WidgetTester tester,
  ) async {
    final List<ProductCreationDraft> requests = <ProductCreationDraft>[];
    var calls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
        createDraftId: () => calls < 2 ? 'draft-key-1' : 'draft-key-2',
        createProduct: (ProductCreationDraft draft) async {
          requests.add(draft);
          calls += 1;
          if (calls == 1) throw const ProductCreationUncertainException();
          return const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: true,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-precision')),
      '0',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('outcome is unknown'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('create-product-name')),
          )
          .enabled,
      isFalse,
    );
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Retry same request',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests[1], same(requests[0]));
    expect(find.text('Created product PRD-COFFEE-001'), findsOneWidget);
  });

  testWidgets('restored same-admin uncertainty is prefilled and must resolve', (
    WidgetTester tester,
  ) async {
    const ProductCreationDraft unresolved = ProductCreationDraft(
      idempotencyKey: 'draft-key-1',
      name: 'Coffee',
      unit: 'piece',
      precision: 0,
    );
    final List<ProductCreationDraft> attempts = <ProductCreationDraft>[];
    var keyCalls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
        unresolvedProductDraft: unresolved,
        createDraftId: () {
          keyCalls += 1;
          return 'draft-key-2';
        },
        createProduct: (ProductCreationDraft draft) async {
          attempts.add(draft);
          return const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: true,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('create-product-name')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('create-product-name')),
          )
          .controller
          ?.text,
      'Coffee',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('create-product-name')),
          )
          .enabled,
      isFalse,
    );
    expect(keyCalls, 0);
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Retry same request',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(attempts, <ProductCreationDraft>[unresolved]);
    expect(keyCalls, 1);
    expect(find.text('Created product PRD-COFFEE-001'), findsOneWidget);
  });

  testWidgets('duplicate taps invoke once and progress is accessible', (
    WidgetTester tester,
  ) async {
    final Completer<ProductCreationResult> pending =
        Completer<ProductCreationResult>();
    var calls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
        createDraftId: () => 'draft-key-1',
        createProduct: (_) {
          calls += 1;
          return pending.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-precision')),
      '0',
    );
    final Finder create = find.widgetWithText(FilledButton, 'Create');
    await tester.tap(create);
    await tester.tap(create, warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
    expect(find.bySemanticsLabel('Creating product'), findsOneWidget);
    pending.complete(
      const ProductCreationResult(
        productId: 'PRD-COFFEE-001',
        internalCode: 'PRD-COFFEE-001',
        replayed: false,
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('success refreshes catalog and renders the server QR code', (
    WidgetTester tester,
  ) async {
    var loads = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      loads += 1;
      if (loads == 1) return CatalogSnapshot(const <CatalogItem>[]);
      return _snapshot(
        const CatalogProduct(
          internalCode: 'PRD-NEW-0001',
          name: 'New product',
          quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
        ),
      );
    }

    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: load,
        createDraftId: () => loads == 1 ? 'draft-key-1' : 'draft-key-2',
        createProduct: (_) async => const ProductCreationResult(
          productId: 'PRD-NEW-0001',
          internalCode: 'PRD-NEW-0001',
          replayed: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'New product',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-precision')),
      '0',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Created product PRD-NEW-0001'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('product-qr-PRD-NEW-0001')),
      findsOneWidget,
    );
  });

  testWidgets(
    'refresh failure keeps creation success and never resubmits mutation',
    (WidgetTester tester) async {
      var loads = 0;
      var creates = 0;
      Future<CatalogSnapshot> load(EmulatorSession session) async {
        loads += 1;
        if (loads > 1) throw StateError('refresh detail');
        return CatalogSnapshot(const <CatalogItem>[]);
      }

      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: load,
          createDraftId: () => 'draft-key-$loads',
          createProduct: (_) async {
            creates += 1;
            return const ProductCreationResult(
              productId: 'PRD-NEW-0001',
              internalCode: 'PRD-NEW-0001',
              replayed: false,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create product'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        'New product',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'piece',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-precision')),
        '0',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(creates, 1);
      expect(find.text('Created product PRD-NEW-0001'), findsOneWidget);
      expect(find.text('Catalog unavailable'), findsOneWidget);
    },
  );

  testWidgets(
    'creation form remains usable with keyboard on a narrow viewport',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => const ProductCreationResult(
            productId: 'PRD-NEW-0001',
            internalCode: 'PRD-NEW-0001',
            replayed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create product'));
      await tester.pumpAndSettle();

      expect(find.text('Product name'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'late creation completion is discarded after role change and disposal',
    (WidgetTester tester) async {
      for (final bool dispose in <bool>[false, true]) {
        final Completer<ProductCreationResult> pending =
            Completer<ProductCreationResult>();
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
            createDraftId: () => 'draft-key-1',
            createProduct: (_) => pending.future,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create product'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-name')),
          'Coffee',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-unit')),
          'piece',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-precision')),
          '0',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pump();

        if (dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.pumpWidget(
            _authenticatedApp(
              session: _seller,
              loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
            ),
          );
        }
        pending.complete(
          const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: false,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Created product PRD-COFFEE-001'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('seller sees safe pricing details and no pricing controls', (
    WidgetTester tester,
  ) async {
    var pricingCalls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _seller,
        loader: (_) async => _snapshot(
          _coffee,
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 0),
          ],
        ),
        setProductPrice: (_) async {
          pricingCalls += 1;
          throw StateError('seller callback must not run');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Listed price: 129.00 MXN'), findsOneWidget);
    expect(find.text('Price mode: IVA included'), findsOneWidget);
    expect(find.text('IVA treatment: Taxable'), findsOneWidget);
    expect(find.text('IVA rate: 16%'), findsOneWidget);
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.text('Configure price / IVA'), findsNothing);
    expect(find.textContaining('audit'), findsNothing);
    expect(pricingCalls, 0);
  });

  testWidgets('admin form pre-fills actual pricing and submits exact values', (
    WidgetTester tester,
  ) async {
    final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
    var loads = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      loads += 1;
      return _snapshot(_coffee);
    }

    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: load,
        createPricingId: () => 'pricing-key-1',
        setProductPrice: (ProductPricingDraft draft) async {
          requests.add(draft);
          return ProductPricingResult.fromCallable(<String, Object?>{
            'auditId': draft.idempotencyKey,
            'productId': draft.productId,
            'pricing': <String, Object?>{
              'listedPriceCentavos': 12900,
              'currency': 'MXN',
              'priceMode': 'iva-included',
              'ivaTreatment': 'taxable',
              'ivaRateBasisPoints': 1600,
            },
            'replayed': false,
          }, request: draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('PRD-COFFEE-001'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .controller
          ?.text,
      '129.00',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-iva-rate')),
          )
          .controller
          ?.text,
      '16',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.toRequest(), <String, Object?>{
      'idempotencyKey': 'pricing-key-1',
      'productId': 'PRD-COFFEE-001',
      'listedPriceMxn': '129.00',
      'priceMode': 'iva-included',
      'ivaTreatment': 'taxable',
      'ivaRatePercent': '16',
    });
    expect(find.text('Pricing saved. Audit pricing-key-1'), findsOneWidget);
    expect(loads, 2);
  });

  testWidgets(
    'blank taxable IVA rate stays local and shows field-associated feedback',
    (WidgetTester tester) async {
      final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-key-1',
          setProductPrice: (ProductPricingDraft draft) async {
            requests.add(draft);
            throw StateError('blank rate must not submit');
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();

      final Finder rateField = find.byKey(
        const ValueKey<String>('pricing-iva-rate'),
      );
      await tester.enterText(rateField, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();

      expect(requests, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: rateField, matching: find.byType(TextField)),
            )
            .decoration
            ?.errorText,
        'IVA rate is required for taxable products.',
      );
      expect(
        find.bySemanticsLabel(
          RegExp(
            'IVA rate.*required for taxable products',
            caseSensitive: false,
          ),
        ),
        findsOneWidget,
      );

      await tester.enterText(rateField, '16');
      await tester.pump();
      expect(
        find.text('IVA rate is required for taxable products.'),
        findsNothing,
      );

      await tester.enterText(rateField, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('pricing-treatment')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zero-rated').last);
      await tester.pumpAndSettle();
      expect(
        find.text('IVA rate is required for taxable products.'),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('IVA rate is required for taxable products.'),
        findsNothing,
      );
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'blank listed price stays local and shows field-associated feedback',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const CatalogProduct tea = CatalogProduct(
        internalCode: 'PRD-TEA-002',
        name: 'Tea',
        quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
        pricing: CatalogPricing(
          listedPriceCentavos: 4500,
          currency: 'MXN',
          priceMode: 'iva-included',
          ivaTreatment: 'taxable',
          ivaRateBasisPoints: 1600,
        ),
      );
      const ProductPricingDraft restored = ProductPricingDraft(
        idempotencyKey: 'pricing-restored',
        productId: 'PRD-COFFEE-001',
        listedPriceMxn: '129.00',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRatePercent: '16',
      );
      ProductPricingDraft? authoritative;
      final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
      var pricingIds = 0;

      Future<CatalogSnapshot> load(EmulatorSession _) async =>
          CatalogSnapshot(<CatalogItem>[
            CatalogItem(product: _coffee, holdings: const <CatalogHolding>[]),
            CatalogItem(product: tea, holdings: const <CatalogHolding>[]),
          ]);

      String createPricingId() {
        pricingIds += 1;
        return 'pricing-key-$pricingIds';
      }

      Future<ProductPricingResult> submit(ProductPricingDraft draft) async {
        requests.add(draft);
        throw StateError('invalid listed price must not submit');
      }

      Widget app(EmulatorSession session) => _authenticatedApp(
        session: session,
        loader: load,
        createPricingId: createPricingId,
        unresolvedPricingDraftForProduct: (String productId) =>
            productId == restored.productId ? authoritative : null,
        setProductPrice: submit,
      );

      Future<void> openPricing(String productId) async {
        final Finder configure = find.byKey(
          ValueKey<String>('configure-price-$productId'),
        );
        await tester.ensureVisible(configure);
        await tester.tap(configure);
        await tester.pumpAndSettle();
      }

      Future<void> tapPricingButton(Type type, String label) async {
        final Finder button = find.widgetWithText(type, label);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
      }

      await tester.pumpWidget(app(_administrator));
      await tester.pumpAndSettle();
      await openPricing(_coffee.internalCode);

      final Finder priceField = find.byKey(
        const ValueKey<String>('pricing-listed-price'),
      );
      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Save price / IVA');

      expect(requests, isEmpty);
      expect(pricingIds, 0);
      expect(find.text('Configure price / IVA'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: priceField, matching: find.byType(TextField)),
            )
            .decoration
            ?.errorText,
        'Listed price is required.',
      );
      expect(
        find.bySemanticsLabel(
          RegExp('listed price.*required', caseSensitive: false),
        ),
        findsOneWidget,
      );

      await tester.enterText(priceField, 'invalid');
      await tester.pump();
      expect(find.text('Listed price is required.'), findsNothing);
      await tapPricingButton(FilledButton, 'Save price / IVA');
      expect(requests, isEmpty);
      expect(pricingIds, 1);
      expect(find.bySemanticsLabel('Product pricing error'), findsOneWidget);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Save price / IVA');
      await tapPricingButton(OutlinedButton, 'Close');
      await tester.pumpAndSettle();
      await openPricing(_coffee.internalCode);
      expect(find.text('Listed price is required.'), findsNothing);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Save price / IVA');
      await tapPricingButton(OutlinedButton, 'Close');
      await tester.pumpAndSettle();
      await openPricing(tea.internalCode);
      expect(find.text('Listed price is required.'), findsNothing);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Save price / IVA');
      await tester.pumpWidget(
        app(
          const EmulatorSession(
            userId: 'administrator-two',
            email: 'admin-two@demo.invalid',
            role: InventoryRole.administrator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Listed price is required.'), findsNothing);
      await openPricing(_coffee.internalCode);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Save price / IVA');
      authoritative = restored;
      await tapPricingButton(OutlinedButton, 'Close');
      await tester.pumpAndSettle();
      await openPricing(_coffee.internalCode);
      expect(find.text('Listed price is required.'), findsNothing);
      expect(find.text('Retry same request'), findsOneWidget);
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'one save reports both missing pricing fields and allows correction',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
      var pricingIds = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-key-${++pricingIds}',
          setProductPrice: (ProductPricingDraft draft) async {
            requests.add(draft);
            return ProductPricingResult.fromCallable(<String, Object?>{
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': <String, Object?>{
                'listedPriceCentavos': 12900,
                'currency': 'MXN',
                'priceMode': 'iva-included',
                'ivaTreatment': 'taxable',
                'ivaRateBasisPoints': 1600,
              },
              'replayed': false,
            }, request: draft);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      final Finder priceField = find.byKey(
        const ValueKey<String>('pricing-listed-price'),
      );
      final Finder rateField = find.byKey(
        const ValueKey<String>('pricing-iva-rate'),
      );
      await tester.enterText(priceField, '');
      await tester.enterText(rateField, '');
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.text('Listed price is required.'), findsNothing);
      expect(
        find.text('IVA rate is required for taxable products.'),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();
      expect(pricingIds, 0);
      expect(requests, isEmpty);
      void expectRequiredFeedback(Finder field, String message, RegExp label) {
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: field, matching: find.byType(TextField)),
              )
              .decoration
              ?.errorText,
          message,
        );
        expect(find.text(message), findsOneWidget);
        final Finder icon = find.descendant(
          of: field,
          matching: find.byIcon(Icons.error_outline),
        );
        expect(icon, findsOneWidget);
        expect(tester.renderObject(icon).debugSemantics, isNull);
        final Finder announcement = find.bySemanticsLabel(label);
        expect(announcement, findsOneWidget);
        expect(
          tester
              .getSemantics(announcement)
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
      }

      expectRequiredFeedback(
        priceField,
        'Listed price is required.',
        RegExp('listed price.*required', caseSensitive: false),
      );
      expectRequiredFeedback(
        rateField,
        'IVA rate is required for taxable products.',
        RegExp('IVA rate.*required for taxable products', caseSensitive: false),
      );
      await tester.enterText(priceField, '129.00');
      await tester.pump();
      expect(find.text('Listed price is required.'), findsNothing);
      expectRequiredFeedback(
        rateField,
        'IVA rate is required for taxable products.',
        RegExp('IVA rate.*required for taxable products', caseSensitive: false),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();
      expect(pricingIds, 0);
      expect(requests, isEmpty);
      await tester.enterText(rateField, '16');
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pumpAndSettle();
      expect(pricingIds, 1);
      expect(requests, hasLength(1));
      expect(requests.single.listedPriceMxn, '129.00');
      expect(requests.single.ivaRatePercent, '16');
      expect(find.text('Pricing saved. Audit pricing-key-1'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets(
    'required-field errors show a strong themed border, icon, and message',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-key-1',
          setProductPrice: (_) async =>
              throw StateError('invalid form must not submit'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();

      final ThemeData theme = Theme.of(
        tester.element(
          find.byKey(const ValueKey<String>('pricing-listed-price')),
        ),
      );
      final InputBorder? themeBorder = theme.inputDecorationTheme.border;
      final double normalBorderWidth = themeBorder is OutlineInputBorder
          ? themeBorder.borderSide.width
          : 1.0;

      InputDecoration decorationOf(String fieldKey) => tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(ValueKey<String>(fieldKey)),
              matching: find.byType(TextField),
            ),
          )
          .decoration!;

      void expectStrongErrorPresentation(
        String fieldKey,
        String message,
        RegExp announcedLabel,
      ) {
        final Finder field = find.byKey(ValueKey<String>(fieldKey));
        final InputDecoration decoration = decorationOf(fieldKey);
        expect(decoration.errorText, message);

        final Finder errorIcon = find.descendant(
          of: field,
          matching: find.byIcon(Icons.error_outline),
        );
        expect(errorIcon, findsOneWidget);
        expect(tester.widget<Icon>(errorIcon).color, theme.colorScheme.error);

        final OutlineInputBorder errorBorder =
            decoration.errorBorder! as OutlineInputBorder;
        expect(errorBorder.borderSide.color, theme.colorScheme.error);
        expect(errorBorder.borderSide.width, greaterThan(normalBorderWidth));
        final OutlineInputBorder focusedErrorBorder =
            decoration.focusedErrorBorder! as OutlineInputBorder;
        expect(focusedErrorBorder.borderSide.color, theme.colorScheme.error);
        expect(
          focusedErrorBorder.borderSide.width,
          greaterThan(normalBorderWidth),
        );

        // The error state keeps the field's own stable outlined shape.
        final OutlineInputBorder normalOutline =
            decoration.border! as OutlineInputBorder;
        expect(errorBorder.borderRadius, normalOutline.borderRadius);
        expect(focusedErrorBorder.borderRadius, normalOutline.borderRadius);

        // The icon is decorative only: its render object contributes no
        // semantics node, so the live region keeps announcing the message.
        expect(tester.renderObject(errorIcon).debugSemantics, isNull);
        expect(find.bySemanticsLabel(announcedLabel), findsOneWidget);
      }

      // Both pricing fields declare one stable outlined shape in normal state.
      expect(
        decorationOf('pricing-listed-price').border,
        isA<OutlineInputBorder>(),
      );
      expect(
        decorationOf('pricing-iva-rate').border,
        isA<OutlineInputBorder>(),
      );

      // Blank listed price: strong local error presentation.
      final Finder priceField = find.byKey(
        const ValueKey<String>('pricing-listed-price'),
      );
      await tester.enterText(priceField, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();
      expectStrongErrorPresentation(
        'pricing-listed-price',
        'Listed price is required.',
        RegExp('listed price.*required', caseSensitive: false),
      );

      // Entering a price clears the visual error along with the message.
      await tester.enterText(priceField, '129.00');
      await tester.pump();
      expect(
        find.descendant(
          of: priceField,
          matching: find.byIcon(Icons.error_outline),
        ),
        findsNothing,
      );

      // Blank taxable IVA rate: the same strong local error presentation.
      final Finder rateField = find.byKey(
        const ValueKey<String>('pricing-iva-rate'),
      );
      await tester.enterText(rateField, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pump();
      expectStrongErrorPresentation(
        'pricing-iva-rate',
        'IVA rate is required for taxable products.',
        RegExp('IVA rate.*required for taxable products', caseSensitive: false),
      );
      semantics.dispose();
    },
  );

  testWidgets('unpriced form guesses neither tax policy nor rate', (
    WidgetTester tester,
  ) async {
    const CatalogProduct unpriced = CatalogProduct(
      internalCode: 'PRD-TEA-0002',
      name: 'Tea',
      quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
    );
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(unpriced),
        createPricingId: () => 'pricing-key-1',
        setProductPrice: (_) => throw StateError('invalid form must not call'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-TEA-0002')),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.text('Select price mode'), findsOneWidget);
    expect(find.text('Select IVA treatment'), findsOneWidget);
    expect(find.text('16'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
    await tester.pump();
    expect(find.text('Listed price is required.'), findsOneWidget);
    expect(find.bySemanticsLabel('Product pricing error'), findsNothing);
  });

  testWidgets('uncertain pricing locks payload and retries the same UUID', (
    WidgetTester tester,
  ) async {
    final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
    var calls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(_coffee),
        createPricingId: () => calls == 0 ? 'pricing-key-1' : 'pricing-key-2',
        setProductPrice: (ProductPricingDraft draft) async {
          requests.add(draft);
          calls += 1;
          if (calls == 1) throw const ProductPricingUncertainException();
          return ProductPricingResult.fromCallable(<String, Object?>{
            'auditId': draft.idempotencyKey,
            'productId': draft.productId,
            'pricing': <String, Object?>{
              'listedPriceCentavos': 12900,
              'currency': 'MXN',
              'priceMode': 'iva-included',
              'ivaTreatment': 'taxable',
              'ivaRateBasisPoints': 1600,
            },
            'replayed': true,
          }, request: draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
    await tester.pumpAndSettle();

    expect(find.textContaining('outcome is unknown'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .enabled,
      isFalse,
    );
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Retry same request',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests[1], same(requests[0]));
    expect(requests[1].idempotencyKey, 'pricing-key-1');
  });

  testWidgets(
    'unresolved conflict recovers authoritative draft instead of faux request',
    (WidgetTester tester) async {
      const ProductPricingDraft stored = ProductPricingDraft(
        idempotencyKey: 'pricing-original-a',
        productId: 'PRD-COFFEE-001',
        listedPriceMxn: '88.88',
        priceMode: 'iva-additional-on-invoice',
        ivaTreatment: 'exempt',
        ivaRatePercent: null,
      );
      ProductPricingDraft? authoritative;
      final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-new-faux',
          unresolvedPricingDraftForProduct: (String productId) =>
              productId == stored.productId ? authoritative : null,
          setProductPrice: (ProductPricingDraft draft) async {
            requests.add(draft);
            if (requests.length == 1) {
              authoritative = stored;
              throw const ProductPricingUnresolvedException();
            }
            return ProductPricingResult.fromCallable(<String, Object?>{
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': <String, Object?>{
                'listedPriceCentavos': draft.listedPriceCentavos,
                'currency': 'MXN',
                'priceMode': draft.priceMode,
                'ivaTreatment': draft.ivaTreatment,
                'ivaRateBasisPoints': draft.ivaRateBasisPoints,
              },
              'replayed': true,
            }, request: draft);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pumpAndSettle();

      expect(requests.single.idempotencyKey, 'pricing-new-faux');
      expect(find.textContaining('outcome is unknown'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
            )
            .controller
            ?.text,
        stored.listedPriceMxn,
      );
      expect(find.text('IVA rate: Not required'), findsOneWidget);

      final Finder retry = find.widgetWithText(
        FilledButton,
        'Retry same request',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(requests, hasLength(2));
      expect(requests[1], same(stored));
      expect(requests[1].idempotencyKey, 'pricing-original-a');
      expect(
        find.text('Pricing saved. Audit pricing-original-a'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'unresolved conflict without authorized draft fails closed without retry',
    (WidgetTester tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-not-stored',
          unresolvedPricingDraftForProduct: (_) => null,
          setProductPrice: (_) async {
            calls += 1;
            throw const ProductPricingUnresolvedException();
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save price / IVA'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Catalog unavailable'), findsOneWidget);
      expect(find.text('Retry same request'), findsNothing);
      expect(find.textContaining('pricing-not-stored'), findsNothing);
    },
  );

  testWidgets('zero-rated is read-only zero and exempt sends null', (
    WidgetTester tester,
  ) async {
    for (final String treatment in <String>['zero-rated', 'exempt']) {
      final List<ProductPricingDraft> requests = <ProductPricingDraft>[];
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(_coffee),
          createPricingId: () => 'pricing-$treatment',
          setProductPrice: (ProductPricingDraft draft) async {
            requests.add(draft);
            return ProductPricingResult.fromCallable(<String, Object?>{
              'auditId': draft.idempotencyKey,
              'productId': draft.productId,
              'pricing': <String, Object?>{
                'listedPriceCentavos': draft.listedPriceCentavos,
                'currency': 'MXN',
                'priceMode': draft.priceMode,
                'ivaTreatment': draft.ivaTreatment,
                'ivaRateBasisPoints': draft.ivaRateBasisPoints,
              },
              'replayed': false,
            }, request: draft);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('pricing-treatment')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(treatment == 'zero-rated' ? 'Zero-rated' : 'Exempt').last,
      );
      await tester.pumpAndSettle();

      if (treatment == 'zero-rated') {
        final TextFormField rate = tester.widget<TextFormField>(
          find.byKey(const ValueKey<String>('pricing-iva-rate')),
        );
        expect(rate.enabled, isFalse);
        expect(rate.controller?.text, '0');
      } else {
        expect(find.text('IVA rate: Not required'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('pricing-iva-rate')),
          findsNothing,
        );
      }
      final Finder save = find.widgetWithText(FilledButton, 'Save price / IVA');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(requests.single.ivaTreatment, treatment);
      expect(
        requests.single.ivaRatePercent,
        treatment == 'zero-rated' ? '0' : isNull,
      );
    }
  });

  testWidgets('pending pricing blocks double tap and exposes progress', (
    WidgetTester tester,
  ) async {
    final Completer<ProductPricingResult> pending =
        Completer<ProductPricingResult>();
    var calls = 0;
    ProductPricingDraft? submitted;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(_coffee),
        createPricingId: () => 'pricing-key-1',
        setProductPrice: (ProductPricingDraft draft) {
          calls += 1;
          submitted = draft;
          return pending.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    final Finder save = find.widgetWithText(FilledButton, 'Save price / IVA');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
    expect(find.bySemanticsLabel('Saving product pricing'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .enabled,
      isFalse,
    );
    final ProductPricingDraft draft = submitted!;
    pending.complete(
      ProductPricingResult.fromCallable(<String, Object?>{
        'auditId': draft.idempotencyKey,
        'productId': draft.productId,
        'pricing': <String, Object?>{
          'listedPriceCentavos': draft.listedPriceCentavos,
          'currency': 'MXN',
          'priceMode': draft.priceMode,
          'ivaTreatment': draft.ivaTreatment,
          'ivaRateBasisPoints': draft.ivaRateBasisPoints,
        },
        'replayed': false,
      }, request: draft),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('success is final before refresh and external pricing wins', (
    WidgetTester tester,
  ) async {
    var loads = 0;
    var mutations = 0;
    const CatalogProduct external = CatalogProduct(
      internalCode: 'PRD-COFFEE-001',
      name: 'Coffee',
      quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
      pricing: CatalogPricing(
        listedPriceCentavos: 20000,
        currency: 'MXN',
        priceMode: 'iva-additional-on-invoice',
        ivaTreatment: 'exempt',
        ivaRateBasisPoints: null,
      ),
    );
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(loads++ == 0 ? _coffee : external),
        createPricingId: () => 'pricing-key-1',
        setProductPrice: (ProductPricingDraft draft) async {
          mutations += 1;
          return ProductPricingResult.fromCallable(<String, Object?>{
            'auditId': draft.idempotencyKey,
            'productId': draft.productId,
            'pricing': <String, Object?>{
              'listedPriceCentavos': draft.listedPriceCentavos,
              'currency': 'MXN',
              'priceMode': draft.priceMode,
              'ivaTreatment': draft.ivaTreatment,
              'ivaRateBasisPoints': draft.ivaRateBasisPoints,
            },
            'replayed': false,
          }, request: draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    final Finder save = find.widgetWithText(FilledButton, 'Save price / IVA');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(mutations, 1);
    expect(find.text('Pricing saved. Audit pricing-key-1'), findsOneWidget);
    expect(find.text('Listed price: 200.00 MXN'), findsOneWidget);
    expect(find.text('Price mode: IVA additional on invoice'), findsOneWidget);
    expect(find.text('IVA treatment: Exempt'), findsOneWidget);
    expect(find.text('IVA rate: Not required'), findsOneWidget);
  });

  testWidgets('pricing refresh failure keeps success without resubmission', (
    WidgetTester tester,
  ) async {
    var loads = 0;
    var mutations = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async {
          loads += 1;
          if (loads > 1) throw StateError('refresh failed');
          return _snapshot(_coffee);
        },
        createPricingId: () => 'pricing-key-1',
        setProductPrice: (ProductPricingDraft draft) async {
          mutations += 1;
          return ProductPricingResult.fromCallable(<String, Object?>{
            'auditId': draft.idempotencyKey,
            'productId': draft.productId,
            'pricing': <String, Object?>{
              'listedPriceCentavos': draft.listedPriceCentavos,
              'currency': 'MXN',
              'priceMode': draft.priceMode,
              'ivaTreatment': draft.ivaTreatment,
              'ivaRateBasisPoints': draft.ivaRateBasisPoints,
            },
            'replayed': false,
          }, request: draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('configure-price-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();
    final Finder save = find.widgetWithText(FilledButton, 'Save price / IVA');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Pricing saved. Audit pricing-key-1'), findsOneWidget);
    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(mutations, 1);
  });

  testWidgets('pricing form remains usable with a narrow keyboard viewport', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(_coffee),
        setProductPrice: (_) => throw const ProductPricingUncertainException(),
      ),
    );
    await tester.pumpAndSettle();
    final Finder configure = find.byKey(
      const ValueKey<String>('configure-price-PRD-COFFEE-001'),
    );
    await tester.tap(configure);
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(320, 480));
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();

    expect(find.text('Listed price (MXN)'), findsOneWidget);
    expect(find.text('Save price / IVA'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('stale error and disposed completion are discarded', (
    WidgetTester tester,
  ) async {
    final _CatalogLoader loader = _CatalogLoader();
    await tester.pumpWidget(
      _authenticatedApp(session: _seller, loader: loader.call),
    );
    await tester.pumpWidget(
      _authenticatedApp(session: _administrator, loader: loader.call),
    );

    loader.requests.first.completeError(StateError('stale secret'));
    await tester.pump();
    expect(find.text('Catalog unavailable'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    loader.requests.last.completeError(StateError('disposed secret'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
