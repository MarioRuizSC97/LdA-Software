import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/catalog/product_rename.dart';

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
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

CatalogSnapshot _snapshot(CatalogProduct product) =>
    CatalogSnapshot(<CatalogItem>[
      CatalogItem(product: product, holdings: const <CatalogHolding>[]),
    ]);

CatalogSnapshot _sellerSnapshot(CatalogProduct product) =>
    CatalogSnapshot(<CatalogItem>[
      CatalogItem(
        product: product,
        holdings: const <CatalogHolding>[
          CatalogHolding(
            branchId: 'branch-north',
            branchName: 'North Demo Branch',
            quantityScaled: 125,
          ),
        ],
      ),
    ]);

ProductRenameResult _renameResult(ProductRenameDraft draft) =>
    ProductRenameResult.fromCallable(<String, Object?>{
      'productId': draft.productId,
      'oldName': 'Coffee',
      'newName': draft.name,
      'replayed': false,
    }, request: draft);

/// A pricing submit that must never be called by rename-only tests.
Future<ProductPricingResult> _unusedPricingSubmit(ProductPricingDraft _) =>
    throw StateError('rename tests must never submit pricing');

/// A rename submit that must never be called by the pricing regression test.
Future<ProductRenameResult> _unusedRenameSubmit(ProductRenameDraft _) =>
    throw StateError('pricing test must never submit a rename');

class _RecordingRenames {
  final List<ProductRenameDraft> drafts = <ProductRenameDraft>[];
  final List<Object> failures = <Object>[];

  Future<ProductRenameResult> submit(ProductRenameDraft draft) async {
    drafts.add(draft);
    if (failures.isNotEmpty) {
      final Object failure = failures.removeAt(0);
      throw failure;
    }
    return _renameResult(draft);
  }
}

/// Records the full pricing flow without touching rename.
class _RecordingPricing {
  final List<ProductPricingDraft> drafts = <ProductPricingDraft>[];
  int loads = 0;

  CatalogSnapshotLoader loader(CatalogProduct product) => (_) {
    loads += 1;
    return Future<CatalogSnapshot>.value(_snapshot(product));
  };

  Future<ProductPricingResult> submit(ProductPricingDraft draft) async {
    drafts.add(draft);
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
  }
}

/// The name section sits below the pricing controls in the scrollable panel;
/// it is built lazily, so scroll until it exists before interacting.
Future<void> _ensureRenameVisible(WidgetTester tester, String code) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey<String>('rename-name-$code')),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.ensureVisible(
    find.byKey(ValueKey<String>('rename-submit-$code')),
  );
}

/// Detail sheet first (T4/T5): the price panel opens through
/// 'Editar precio / IVA' inside the sheet.
Future<void> _openPricePanel(WidgetTester tester, String code) async {
  await tester.ensureVisible(
    find.byKey(ValueKey<String>('product-details-$code')),
  );
  await tester.tap(find.byKey(ValueKey<String>('product-details-$code')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>('configure-price-$code')));
  await tester.pumpAndSettle();
}

Widget _page({
  EmulatorSession session = _administrator,
  required CatalogSnapshotLoader loader,
  ProductPricingSubmit? setProductPrice = _unusedPricingSubmit,
  ProductRenameSubmit? renameProduct,
  ProductRenameDraftLookup? unresolvedRenameDraftForProduct,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: loader,
    setProductPrice: setProductPrice,
    renameProduct: renameProduct,
    unresolvedRenameDraftForProduct: unresolvedRenameDraftForProduct,
    onLogout: () async {},
  ),
);

void main() {
  testWidgets(
    'administrator sees the prefilled name field in the price panel',
    (tester) async {
      await tester.pumpWidget(
        _page(
          loader: (_) async => _snapshot(_coffee),
          renameProduct: _RecordingRenames().submit,
        ),
      );
      await tester.pumpAndSettle();
      await _openPricePanel(tester, 'PRD-COFFEE-001');
      await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

      final TextFormField field = tester.widget<TextFormField>(
        find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      );
      expect(field.controller!.text, 'Coffee');
      expect(
        find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
        findsOneWidget,
      );
      expect(find.text('Guardar nombre'), findsOneWidget);
    },
  );

  testWidgets('seller never sees any rename control', (tester) async {
    await tester.pumpWidget(
      _page(
        session: _seller,
        loader: (_) async => _sellerSnapshot(_coffee),
        renameProduct: _RecordingRenames().submit,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('product-details-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(find.text('Guardar nombre'), findsNothing);
  });

  testWidgets('a null rename submit hides the name section for the '
      'administrator too', (tester) async {
    await tester.pumpWidget(_page(loader: (_) async => _snapshot(_coffee)));
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');

    expect(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(find.text('Guardar nombre'), findsNothing);
  });

  testWidgets('success submits a draft whose productId is the internal code', (
    tester,
  ) async {
    final _RecordingRenames renames = _RecordingRenames();
    await tester.pumpWidget(
      _page(
        loader: (_) async => _snapshot(_coffee),
        renameProduct: renames.submit,
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');
    await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      'Café de especialidad',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(renames.drafts, hasLength(1));
    expect(renames.drafts.single.productId, 'PRD-COFFEE-001');
    expect(renames.drafts.single.name, 'Café de especialidad');
  });

  testWidgets('trimmed-invalid names are rejected client-side with the '
      'creation name message, before any submit', (tester) async {
    final _RecordingRenames renames = _RecordingRenames();
    await tester.pumpWidget(
      _page(
        loader: (_) async => _snapshot(_coffee),
        renameProduct: renames.submit,
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');
    await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      ' Coffee',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(renames.drafts, isEmpty);
    expect(
      find.text(
        'El nombre debe tener de 1 a 120 caracteres, sin espacios al inicio '
        'o al final ni caracteres de control.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('success shows the confirmation, closes the panel and refreshes '
      'the catalog so the card shows the new name', (tester) async {
    var renames = 0;
    await tester.pumpWidget(
      _page(
        loader: (_) async => _snapshot(
          renames == 0
              ? _coffee
              : const CatalogProduct(
                  internalCode: 'PRD-COFFEE-001',
                  name: 'Café de especialidad',
                  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
                  pricing: CatalogPricing(
                    listedPriceCentavos: 12900,
                    currency: 'MXN',
                    priceMode: 'iva-included',
                    ivaTreatment: 'taxable',
                    ivaRateBasisPoints: 1600,
                  ),
                ),
        ),
        renameProduct: (ProductRenameDraft draft) async {
          renames += 1;
          return _renameResult(draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');
    await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      'Café de especialidad',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Nombre actualizado a Café de especialidad'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(find.text('Café de especialidad'), findsOneWidget);
  });

  testWidgets('an uncertain outcome keeps the same idempotency key and retries '
      'the same request', (tester) async {
    final _RecordingRenames renames = _RecordingRenames()
      ..failures.add(const ProductRenameUncertainException());
    await tester.pumpWidget(
      _page(
        loader: (_) async => _snapshot(_coffee),
        renameProduct: renames.submit,
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');
    await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      'Café de especialidad',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(renames.drafts, hasLength(1));
    expect(
      find.text(
        'El resultado es incierto. Reintenta la misma solicitud antes de editar.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reintentar misma solicitud'), findsOneWidget);
    final TextFormField field = tester.widget<TextFormField>(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
    );
    expect(field.controller!.text, 'Café de especialidad');

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(renames.drafts, hasLength(2));
    expect(
      renames.drafts.first.idempotencyKey,
      renames.drafts.last.idempotencyKey,
    );
    expect(renames.drafts.first, renames.drafts.last);
  });

  testWidgets('a rejected code maps to a safe Spanish message with no retry '
      'and no server text', (tester) async {
    final _RecordingRenames renames = _RecordingRenames()
      ..failures.add(const ProductRenameRejectedException(code: 'not-found'));
    await tester.pumpWidget(
      _page(
        loader: (_) async => _snapshot(_coffee),
        renameProduct: renames.submit,
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');
    await _ensureRenameVisible(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-name-PRD-COFFEE-001')),
      'Café de especialidad',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-submit-PRD-COFFEE-001')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'El producto ya no existe en el catálogo. Actualiza e inténtalo de nuevo.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('not-found'), findsNothing);
    expect(find.text('Reintentar misma solicitud'), findsNothing);
    expect(find.text('Guardar nombre'), findsOneWidget);
  });

  testWidgets('the existing pricing submit still behaves as before from the '
      'same panel', (tester) async {
    final _RecordingPricing pricing = _RecordingPricing();
    await tester.pumpWidget(
      _page(
        loader: pricing.loader(_coffee),
        setProductPrice: pricing.submit,
        renameProduct: _unusedRenameSubmit,
      ),
    );
    await tester.pumpAndSettle();
    await _openPricePanel(tester, 'PRD-COFFEE-001');

    await tester.enterText(
      find.byKey(const ValueKey<String>('pricing-listed-price')),
      '150',
    );
    await tester.tap(find.text('Guardar precio / IVA'));
    await tester.pumpAndSettle();

    expect(pricing.drafts, hasLength(1));
    expect(pricing.drafts.single.productId, 'PRD-COFFEE-001');
    expect(pricing.drafts.single.listedPriceMxn, '150');
    expect(find.text('Precio guardado'), findsOneWidget);
  });
}
