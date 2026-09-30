import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
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
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: loader,
    createProduct: createProduct,
    createDraftId: createDraftId,
    unresolvedProductDraft: unresolvedProductDraft,
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
    expect(find.text('IVA treatment: taxable'), findsOneWidget);
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
