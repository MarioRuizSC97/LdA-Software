import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/catalog/product_pricing.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/stock_intake.dart';
import 'package:lda_inventory/firebase/emulator_stock_intake_gateway.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart'
    show CatalogDocument;
import 'package:lda_inventory/catalog/product_qr.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

class _InjectedCost implements CatalogProductCost {
  _InjectedCost({
    this.latestUnitCostCentavos = 0,
    this.currency = 'MXN',
    this.sourceEntryId = 'entry-1',
  });

  @override
  final String productId = 'PRD-COFFEE-001';
  @override
  final int latestUnitCostCentavos;
  @override
  final String currency;
  @override
  final String sourceEntryId;
  @override
  final Timestamp updatedAt = Timestamp(0, 0);
}

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

const List<CatalogBranchChoice> _branches = <CatalogBranchChoice>[
  CatalogBranchChoice(
    branchId: 'branch-north',
    branchName: 'North Demo Branch',
  ),
  CatalogBranchChoice(
    branchId: 'branch-south',
    branchName: 'South Demo Branch',
  ),
];

CatalogSnapshot _snapshotWithBranches(
  CatalogProduct product, {
  List<CatalogBranchChoice> branchChoices = _branches,
}) => CatalogSnapshot(<CatalogItem>[
  CatalogItem(product: product, holdings: const <CatalogHolding>[]),
], branchChoices: branchChoices);

StockIntakeResult _intakeResult(
  StockIntakeDraft draft, {
  bool replayed = false,
}) => StockIntakeResult.fromCallable(<String, Object?>{
  'entryId': draft.idempotencyKey,
  'movementId': draft.idempotencyKey,
  'quantityScaled': draft.quantityScaled,
  'stockQuantityScaled': draft.quantityScaled,
  'unitCostCentavos': draft.unitCostCentavos,
  'lineTotalCentavos': draft.lineTotalCentavos,
  'replayed': replayed,
}, request: draft);

/// Opens the product detail sheet (T5): since T4 compacted the card, the
/// pricing and intake actions live inside it.
Future<void> _openProductSheet(WidgetTester tester, String code) async {
  await tester.ensureVisible(
    find.byKey(ValueKey<String>('product-details-$code')),
  );
  await tester.tap(find.byKey(ValueKey<String>('product-details-$code')));
  await tester.pumpAndSettle();
}

/// Closes the product detail sheet through its own close control.
Future<void> _closeProductSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('product-sheet-close')));
  await tester.pumpAndSettle();
}

/// Opens the detail sheet and taps the pricing action inside it; the sheet
/// closes first and the existing pricing form opens (T4/T5).
Future<void> _openSheetAndConfigurePricing(
  WidgetTester tester,
  String code,
) async {
  await _openProductSheet(tester, code);
  final Finder configure = find.byKey(
    ValueKey<String>('configure-price-$code'),
  );
  await tester.ensureVisible(configure);
  await tester.tap(configure);
  await tester.pumpAndSettle();
}

/// Opens the detail sheet and taps the intake action inside it; the sheet
/// closes first and the existing intake form opens (T4/T5).
Future<void> _openSheetAndStartIntake(WidgetTester tester, String code) async {
  await _openProductSheet(tester, code);
  final Finder intake = find.byKey(ValueKey<String>('intake-$code'));
  await tester.ensureVisible(intake);
  await tester.tap(intake);
  await tester.pumpAndSettle();
}

Future<void> _confirmIntake(WidgetTester tester) async {
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('intake-confirm-dialog')), findsOneWidget);
  await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
  await tester.pump();
}

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
  StockIntakeSubmit? submitStockIntake,
  StockIntakeIdFactory? createIntakeId,
  StockIntakeDraftLookup? unresolvedIntakeDraftFor,
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
    submitStockIntake: submitStockIntake,
    createIntakeId: createIntakeId,
    unresolvedIntakeDraftFor: unresolvedIntakeDraftFor,
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

/// Selects [value] in the creation precision dropdown, mirroring the intake
/// branch-selection interaction.
Future<void> _selectCreationPrecision(WidgetTester tester, int value) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('create-product-precision')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('$value').last);
  await tester.pumpAndSettle();
}

Widget _app(CatalogRepository repository) =>
    MaterialApp(home: CatalogPage(repository: repository));

/// In-process fake of both notice streams plus the callable transport.
class _FakeNoticeStreams implements TransferNoticeStreamSource {
  final StreamController<TransferNoticeStreamEnvelope> movementsCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  final StreamController<TransferNoticeStreamEnvelope> markersCtrl =
      StreamController<TransferNoticeStreamEnvelope>.broadcast();
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<Completer<Object?>> replies = <Completer<Object?>>[];

  void emitMovements(List<CatalogDocument> documents) => movementsCtrl.add(
    TransferNoticeStreamEnvelope(documents: documents, isFromCache: false),
  );

  void emitMarkers(List<CatalogDocument> documents) => markersCtrl.add(
    TransferNoticeStreamEnvelope(documents: documents, isFromCache: false),
  );

  CatalogDocument marker(String transferId) => CatalogDocument(
    path:
        'transferNoticeReads/seller-north/branches/branch-north/transfers/$transferId',
    data: <String, Object?>{
      'userId': 'seller-north',
      'branchId': 'branch-north',
      'transferId': transferId,
      'readAt': Timestamp.fromMillisecondsSinceEpoch(1767300000000),
    },
  );

  void completeAck(String transferId) =>
      replies.removeLast().complete(<String, Object?>{
        'transferId': transferId,
        'branchId': 'branch-north',
        'read': true,
      });

  @override
  Stream<TransferNoticeStreamEnvelope> movements({required String branchId}) =>
      movementsCtrl.stream;

  @override
  Stream<TransferNoticeStreamEnvelope> markers() => markersCtrl.stream;
}

void main() {
  for (final String category in <String>['creation', 'pricing', 'intake']) {
    group('$category notice ownership', () {
      final List<Object> requests = <Object>[];
      late Completer<Object> acknowledgement;
      int ids = 0;
      Future<T> submit<T>(Object draft) {
        requests.add(draft);
        acknowledgement = Completer<Object>();
        return acknowledgement.future.then((Object value) => value as T);
      }

      Widget page({EmulatorSession session = _administrator}) =>
          _authenticatedApp(
            session: session,
            loader: (_) async => _snapshotWithBranches(_coffee),
            createDraftId: () => 'notice-${++ids}',
            createPricingId: () => 'notice-${++ids}',
            createIntakeId: () => 'notice-${++ids}',
            createProduct: submit<ProductCreationResult>,
            setProductPrice: submit<ProductPricingResult>,
            submitStockIntake: submit<StockIntakeResult>,
          );
      Finder banner() => find.textContaining(switch (category) {
        'creation' => 'Producto creado',
        'pricing' => 'Precio guardado',
        _ => 'Entrada registrada.',
      });
      Future<void> begin(WidgetTester tester) async {
        // Since T4/T5 the pricing and intake actions live in the product
        // detail sheet: open it first.
        if (category != 'creation') {
          await _openProductSheet(tester, 'PRD-COFFEE-001');
        }
        final Finder open = category == 'creation'
            ? find.text('Crear producto')
            : find.byKey(
                ValueKey<String>(
                  '${category == 'pricing' ? 'configure-price' : 'intake'}-PRD-COFFEE-001',
                ),
              );
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        if (category == 'creation') {
          await tester.enterText(
            find.byKey(const ValueKey<String>('create-product-name')),
            'Coffee',
          );
          await tester.enterText(
            find.byKey(const ValueKey<String>('create-product-unit')),
            'kg',
          );
          await _selectCreationPrecision(tester, 2);
        } else if (category == 'intake') {
          await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('North Demo Branch').last);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey<String>('intake-quantity')),
            '2',
          );
          await tester.enterText(
            find.byKey(const ValueKey<String>('intake-unit-cost')),
            '12.50',
          );
        }
        final Finder button = find.widgetWithText(
          FilledButton,
          switch (category) {
            'creation' => 'Crear',
            'pricing' => 'Guardar precio / IVA',
            _ => 'Registrar entrada',
          },
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        if (category == 'intake') await _confirmIntake(tester);
        await tester.pump();
      }

      Future<void> accept(WidgetTester tester) async {
        final Object draft = requests.last;
        acknowledgement.complete(switch (draft) {
          ProductCreationDraft() => const ProductCreationResult(
            productId: 'PRD-COFFEE-001',
            internalCode: 'PRD-COFFEE-001',
            replayed: false,
          ),
          ProductPricingDraft() => ProductPricingResult.fromCallable(
            <String, Object?>{
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
            },
            request: draft,
          ),
          StockIntakeDraft() => _intakeResult(draft),
          _ => throw StateError('unexpected draft'),
        });
        await tester.pump();
        await tester.pump();
      }

      setUp(() {
        requests.clear();
        ids = 0;
      });
      testWidgets(
        'ack owns full ten seconds; replacement owns a new deadline',
        (WidgetTester tester) async {
          await tester.pumpWidget(page());
          await tester.pumpAndSettle();
          await begin(tester);
          await tester.pump(const Duration(seconds: 11));
          expect(banner(), findsNothing);
          expect(requests, hasLength(1));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await accept(tester);
          expect(banner(), findsOneWidget);
          // Creation's automatic pricing handoff remains available.
          if (category == 'creation') {
            expect(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
              findsOneWidget,
            );
          }
          await tester.pump(const Duration(seconds: 9));
          expect(banner(), findsOneWidget);
          await begin(tester);
          await accept(tester);
          expect(banner(), findsOneWidget);
          await tester.pump(const Duration(seconds: 1));
          expect(banner(), findsOneWidget);
          await tester.pump(const Duration(seconds: 8));
          expect(banner(), findsOneWidget);
          await tester.pumpWidget(
            page(
              session: EmulatorSession(
                userId: _administrator.userId,
                email: _administrator.email,
                role: _administrator.role,
              ),
            ),
          );
          await tester.pump();
          // An identical SDK identity frame does not own a new deadline.
          await tester.pump(const Duration(seconds: 1));
          // All three banners start their short exit at the unchanged
          // ten-second deadline: still on screen mid-exit, then gone.
          expect(banner(), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 120));
          expect(banner(), findsOneWidget);
          await tester.pumpAndSettle();
          expect(banner(), findsNothing);
          expect(requests, hasLength(2));
          expect(find.textContaining('resultado es incierto'), findsNothing);
          if (category != 'creation') {
            // Price and cost moved into the detail sheet (T4/T5); the branch
            // reminder stays on the card.
            await _openProductSheet(tester, 'PRD-COFFEE-001');
            expect(find.text('Coffee'), findsWidgets);
            expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
            expect(find.text('Costo no disponible'), findsOneWidget);
            await _closeProductSheet(tester);
            expect(find.textContaining('Sin entrada registrada'), findsWidgets);
          } else {
            expect(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
              findsOneWidget,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
      if (category == 'creation') {
        testWidgets(
          'simultaneous creation and pricing have independent clocks',
          (WidgetTester tester) async {
            await tester.pumpWidget(page());
            await tester.pumpAndSettle();
            await begin(tester);
            await accept(tester);
            await tester.pump(const Duration(seconds: 5));
            final Finder save = find.widgetWithText(
              FilledButton,
              'Guardar precio / IVA',
            );
            await tester.ensureVisible(save);
            await tester.tap(save);
            await tester.pump();
            await accept(tester);
            expect(banner(), findsOneWidget);
            expect(find.text('Precio guardado'), findsOneWidget);
            await tester.pump(const Duration(seconds: 5));
            expect(banner(), findsOneWidget);
            await tester.pump(const Duration(milliseconds: 120));
            await tester.pumpAndSettle();
            expect(banner(), findsNothing);
            expect(find.text('Precio guardado'), findsOneWidget);
            await tester.pump(const Duration(seconds: 5));
            await tester.pumpAndSettle();
            expect(find.text('Precio guardado'), findsNothing);
            await _openProductSheet(tester, 'PRD-COFFEE-001');
            expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
            await _closeProductSheet(tester);
            expect(requests, hasLength(2));
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
      for (final bool unknown in <bool>[false, true]) {
        testWidgets(
          '${unknown ? 'unknown' : 'rejection'} never expires or retries',
          (WidgetTester tester) async {
            await tester.pumpWidget(page());
            await tester.pumpAndSettle();
            await begin(tester);
            acknowledgement.completeError(
              unknown
                  ? StateError('lost acknowledgement')
                  : switch (category) {
                      'creation' => const ProductCreationRejectedException(
                        code: 'permission-denied',
                      ),
                      'pricing' => const ProductPricingRejectedException(
                        code: 'permission-denied',
                      ),
                      _ => const StockIntakeRejectedException(
                        code: 'permission-denied',
                      ),
                    },
            );
            await tester.pumpAndSettle();
            final Finder error = find.textContaining(
              unknown ? 'resultado es incierto' : 'Se rechazó',
            );
            expect(error, findsOneWidget);
            await tester.pump(const Duration(seconds: 20));
            expect(error, findsOneWidget);
            expect(requests, hasLength(1));
            if (unknown) {
              await tester.ensureVisible(
                find.text('Reintentar misma solicitud'),
              );
              await tester.tap(find.text('Reintentar misma solicitud'));
              if (category == 'intake') await _confirmIntake(tester);
              await tester.pump();
              expect(requests, hasLength(2));
              expect(requests.last, requests.first);
              await accept(tester);
            }
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
      for (final String reset in <String>[
        'callback',
        'actor',
        'role',
        'dispose',
      ]) {
        testWidgets('$reset cancels accepted notice ownership', (
          WidgetTester tester,
        ) async {
          await tester.pumpWidget(page());
          await tester.pumpAndSettle();
          await begin(tester);
          await accept(tester);
          expect(banner(), findsOneWidget);
          await tester.pumpWidget(switch (reset) {
            'dispose' => const SizedBox.shrink(),
            'callback' => _authenticatedApp(
              session: _administrator,
              loader: (_) async => _snapshotWithBranches(_coffee),
            ),
            'role' => page(session: _seller),
            _ => page(
              session: const EmulatorSession(
                userId: 'other-admin',
                email: 'other@demo.invalid',
                role: InventoryRole.administrator,
              ),
            ),
          });
          await tester.pump();
          expect(banner(), findsNothing);
          await tester.pump(const Duration(seconds: 20));
          expect(tester.takeException(), isNull);
          expect(requests, hasLength(1));
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    });
  }
  testWidgets('private cost metadata injection fails closed', (
    WidgetTester tester,
  ) async {
    final cost = CatalogProductCost.fromFirestore(
      'costs/PRD-COFFEE-001',
      <String, Object?>{
        'latestUnitCostCentavos': 0,
        'currency': 'MXN',
        'sourceEntryId': 'entry-1',
        'updatedAt': Timestamp(0, 0),
      },
    );
    for (final InventoryRole role in InventoryRole.values) {
      for (final bool available in <bool>[false, true]) {
        for (final String key in <String>['PRD-COFFEE-001', 'PRD-OTHER-001']) {
          if (role == InventoryRole.administrator &&
              available &&
              key == cost.productId) {
            continue;
          }
          await tester.pumpWidget(
            _authenticatedApp(
              session: role == InventoryRole.seller ? _seller : _administrator,
              loader: (_) async => CatalogSnapshot(
                <CatalogItem>[
                  CatalogItem(
                    product: _coffee,
                    holdings: const <CatalogHolding>[
                      CatalogHolding(
                        branchId: 'branch-north',
                        quantityScaled: 0,
                      ),
                    ],
                  ),
                ],
                costsAvailable: available,
                costs: <String, CatalogProductCost>{key: cost},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Coffee'), findsNothing);
          expect(find.text('Catálogo no disponible'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await tester.pumpWidget(
      _authenticatedApp(
        session: _seller,
        loader: (_) async =>
            CatalogSnapshot(const <CatalogItem>[], costsAvailable: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Catálogo no disponible'), findsOneWidget);
  });
  group('administrator global latest unit cost cards', () {
    CatalogSnapshot snapshot({
      int? cents,
      bool available = true,
      CatalogProduct product = _coffee,
      String costProductId = 'PRD-COFFEE-001',
    }) => CatalogSnapshot(
      <CatalogItem>[CatalogItem(product: product, holdings: const [])],
      branchChoices: _branches,
      costsAvailable: available,
      costs: <String, CatalogProductCost>{
        if (cents != null)
          costProductId: CatalogProductCost.fromFirestore(
            'costs/$costProductId',
            <String, Object?>{
              'latestUnitCostCentavos': cents,
              'currency': 'MXN',
              'sourceEntryId': 'entry-from-any-branch',
              'updatedAt': Timestamp(0, 0),
            },
          ),
      },
    );
    const CatalogProduct unpriced = CatalogProduct(
      internalCode: 'PRD-COFFEE-001',
      name: 'Coffee',
      quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
    );
    for (final (int?, bool, String) state in <(int?, bool, String)>[
      (0, true, 'Último costo unitario: 0.00 MXN'),
      (12345, true, 'Último costo unitario: 123.45 MXN'),
      (9007199254740991, true, 'Último costo unitario: 90071992547409.91 MXN'),
      (null, true, 'Sin costo registrado'),
      (null, false, 'Costo no disponible'),
    ]) {
      for (final CatalogProduct product in <CatalogProduct>[
        _coffee,
        unpriced,
      ]) {
        testWidgets('${state.$3}, priced=${product.pricing != null}, narrow', (
          WidgetTester tester,
        ) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final SemanticsHandle semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            _authenticatedApp(
              session: _administrator,
              loader: (_) async => snapshot(
                cents: state.$1,
                available: state.$2,
                product: product,
              ),
            ),
          );
          await tester.pumpAndSettle();
          // The branch reminders stay on the compact card; price, cost and
          // QR moved into the detail sheet (T4/T5).
          expect(
            find.text('North Demo Branch: Agotado · Sin entrada registrada'),
            findsOneWidget,
          );
          expect(
            find.text('South Demo Branch: Agotado · Sin entrada registrada'),
            findsOneWidget,
          );
          await _openProductSheet(tester, _coffee.internalCode);
          expect(find.text(state.$3), findsOneWidget);
          expect(find.bySemanticsLabel(state.$3), findsOneWidget);
          expect(
            find.text('Precio de lista: 129.00 MXN'),
            product.pricing == null ? findsNothing : findsOneWidget,
          );
          expect(find.byType(ProductQrView), findsOneWidget);
          await _closeProductSheet(tester);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
    testWidgets('hostile typed costs fail closed without rendering values', (
      WidgetTester tester,
    ) async {
      for (final CatalogProductCost cost in <CatalogProductCost>[
        _InjectedCost(latestUnitCostCentavos: -1),
        _InjectedCost(latestUnitCostCentavos: 9007199254740992),
        _InjectedCost(currency: 'USD'),
        _InjectedCost(sourceEntryId: 'entry-1\n'),
      ]) {
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: (_) async => CatalogSnapshot(
              <CatalogItem>[CatalogItem(product: _coffee, holdings: const [])],
              costsAvailable: true,
              costs: <String, CatalogProductCost>{cost.productId: cost},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Catálogo no disponible'), findsOneWidget);
        expect(find.text('Coffee'), findsNothing);
        expect(find.textContaining('Último costo unitario:'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
    testWidgets('correlated but orphan cost fails closed', (tester) async {
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async =>
              snapshot(cents: 1, costProductId: 'PRD-OTHER-001'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Catálogo no disponible'), findsOneWidget);
      expect(find.text('Coffee'), findsNothing);
      expect(find.textContaining('Último costo unitario:'), findsNothing);
    });
    testWidgets(
      'refresh replaces latest cost, clears stale states and role',
      (WidgetTester tester) async {
        final _CatalogLoader loader = _CatalogLoader();
        await tester.pumpWidget(
          _authenticatedApp(session: _administrator, loader: loader.call),
        );
        loader.requests.last.complete(snapshot(cents: 345));
        await tester.pumpAndSettle();
        await _openProductSheet(tester, _coffee.internalCode);
        expect(find.text('Último costo unitario: 3.45 MXN'), findsOneWidget);
        await _closeProductSheet(tester);
        for (final CatalogSnapshot next in <CatalogSnapshot>[
          snapshot(cents: 678),
          snapshot(available: false),
          snapshot(),
        ]) {
          await tester.tap(find.byTooltip('Actualizar catálogo'));
          await tester.pump();
          expect(find.textContaining('Último costo unitario:'), findsNothing);
          expect(find.text('Costo no disponible'), findsNothing);
          expect(find.text('Sin costo registrado'), findsNothing);
          loader.requests.last.complete(next);
          await tester.pumpAndSettle();
          await _openProductSheet(tester, _coffee.internalCode);
          final String expected = !next.costsAvailable
              ? 'Costo no disponible'
              : next.costs.isEmpty
              ? 'Sin costo registrado'
              : 'Último costo unitario: 6.78 MXN';
          expect(find.text(expected), findsOneWidget);
          expect(find.text('Último costo unitario: 3.45 MXN'), findsNothing);
          await _closeProductSheet(tester);
        }
        await tester.tap(find.byTooltip('Actualizar catálogo'));
        await tester.pump();
        final Completer<CatalogSnapshot> stale = loader.requests.last;
        await tester.pumpWidget(
          _authenticatedApp(session: _seller, loader: loader.call),
        );
        await tester.pump();
        stale.complete(snapshot(cents: 999));
        loader.requests.last.complete(
          _snapshot(
            _coffee,
            holdings: const [
              CatalogHolding(branchId: 'branch-north', quantityScaled: 0),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Coffee'), findsOneWidget);
        expect(find.text('Existencias: 0.00 kg'), findsOneWidget);
        expect(find.text('Agotado'), findsOneWidget);
        // The seller sees the price only in the detail sheet (T5), and never
        // any cost.
        await _openProductSheet(tester, _coffee.internalCode);
        expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
        await _closeProductSheet(tester);
        expect(find.textContaining('Último costo unitario:'), findsNothing);
        expect(find.text('Costo no disponible'), findsNothing);
        expect(find.text('Sin costo registrado'), findsNothing);
        // The refresh tests drive the desktop app-bar button (web/desktop
        // keeps it); the mobile menu entry is covered in
        // mobile_app_bar_test.dart.
      },
      // Desktop/web keeps the bar refresh button (S2).
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
  group('creation pending draft authority', () {
    const ProductCreationDraft own = ProductCreationDraft(
      idempotencyKey: 'self-pending-request',
      name: 'Coffee',
      unit: 'piece',
      precision: 0,
    );
    final ProductCreationDraft same = ProductCreationDraft(
      idempotencyKey: 'self-pending-request',
      name: 'Coffee',
      unit: 'piece',
      precision: 0,
    );
    for (final String change in <String>[
      'foreign UUID',
      'foreign payload',
      'null draft',
      'callback replacement',
      'callback null',
      'other UID',
      'seller role',
      'branch identity',
      'disposal',
    ]) {
      testWidgets('$change invalidates matching pending late success', (
        WidgetTester tester,
      ) async {
        final Completer<ProductCreationResult> result =
            Completer<ProductCreationResult>();
        int calls = 0;
        Future<ProductCreationResult> submit(ProductCreationDraft draft) {
          calls += 1;
          expect(draft, own);
          return result.future;
        }

        Future<ProductCreationResult> replacement(ProductCreationDraft draft) =>
            throw StateError('replacement must not auto-submit');
        Future<CatalogSnapshot> load(EmulatorSession session) async =>
            CatalogSnapshot(const <CatalogItem>[]);
        Widget page({
          EmulatorSession session = _administrator,
          ProductCreationDraft? draft = own,
          ProductCreationSubmit? callback,
          bool noCallback = false,
        }) => _authenticatedApp(
          session: session,
          loader: load,
          createProduct: noCallback ? null : callback ?? submit,
          unresolvedProductDraft: draft,
        );
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        final Finder retry = find.widgetWithText(
          FilledButton,
          'Reintentar misma solicitud',
        );
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pump();
        // Payload equality, not object identity, defines the self-owned echo.
        expect(identical(own, same), isFalse);
        await tester.pumpWidget(page(draft: same));
        await tester.pump();
        expect(find.textContaining('resultado es incierto'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        ProductCreationDraft? next = own;
        EmulatorSession session = _administrator;
        if (change == 'foreign UUID' || change == 'foreign payload') {
          next = ProductCreationDraft(
            idempotencyKey: change == 'foreign UUID'
                ? 'foreign-request'
                : own.idempotencyKey,
            name: 'Foreign product',
            unit: 'kg',
            precision: 2,
          );
        }
        if (change == 'null draft') next = null;
        if (change == 'other UID') {
          session = const EmulatorSession(
            userId: 'other-admin',
            email: 'other@demo.invalid',
            role: InventoryRole.administrator,
          );
        }
        if (change == 'seller role') {
          session = EmulatorSession(
            userId: _administrator.userId,
            email: _administrator.email,
            role: InventoryRole.seller,
            branchId: 'branch-north',
          );
        }
        if (change == 'branch identity') {
          session = EmulatorSession(
            userId: _administrator.userId,
            email: _administrator.email,
            role: InventoryRole.administrator,
            branchId: 'branch-north',
          );
        }
        await tester.pumpWidget(
          change == 'disposal'
              ? const SizedBox()
              : page(
                  session: session,
                  draft: next,
                  callback: change == 'callback replacement'
                      ? replacement
                      : submit,
                  noCallback: change == 'callback null',
                ),
        );
        await tester.pump();
        result.complete(
          const ProductCreationResult(
            productId: 'PRD-STALE-001',
            internalCode: 'PRD-STALE-001',
            replayed: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Producto creado correctamente'), findsNothing);
        expect(calls, 1);
        if (change.startsWith('foreign')) {
          expect(find.textContaining('resultado es incierto'), findsOneWidget);
          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const ValueKey<String>('create-product-name')),
                )
                .controller!
                .text,
            'Foreign product',
          );
          expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
        }
      });
    }
  });

  group('administrator missing-stock reminders', () {
    CatalogSnapshot snapshot({
      List<CatalogHolding> holdings = const <CatalogHolding>[],
      List<CatalogBranchChoice> choices = _branches,
    }) => CatalogSnapshot(<CatalogItem>[
      CatalogItem(product: _coffee, holdings: holdings),
    ], branchChoices: choices);

    const CatalogHolding north = CatalogHolding(
      branchId: 'branch-north',
      branchName: 'North Demo Branch',
      quantityScaled: 125,
    );
    const String southMissing =
        'South Demo Branch: Agotado · Sin entrada registrada';

    for (final CatalogBranchChoice choice in const <CatalogBranchChoice>[
      CatalogBranchChoice(
        branchId: 'branch-south',
        branchName: 'North Demo Branch',
      ),
      CatalogBranchChoice(
        branchId: 'branch-north',
        branchName: 'Different North Branch',
      ),
    ]) {
      testWidgets(
        'rejects holding-choice correlation conflict ${choice.branchId}',
        (tester) async {
          final CatalogSnapshot data = snapshot(
            holdings: const <CatalogHolding>[north],
            choices: <CatalogBranchChoice>[choice],
          );
          await tester.pumpWidget(
            _authenticatedApp(
              session: _administrator,
              loader: (_) async => data,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Catálogo no disponible'), findsOneWidget);
          expect(
            find.widgetWithText(FilledButton, 'Reintentar'),
            findsOneWidget,
          );
          expect(find.text('Coffee'), findsNothing);
          expect(find.text('North Demo Branch: 1.25 kg'), findsNothing);
          expect(find.textContaining('Sin entrada registrada'), findsNothing);
          expect(find.textContaining('Different North Branch'), findsNothing);
          expect(data.items.single.holdings, hasLength(1));
          expect(identical(data.items.single.holdings.single, north), isTrue);
        },
      );
    }

    testWidgets('north holding leaves a named south reminder', (tester) async {
      final CatalogSnapshot data = snapshot(holdings: <CatalogHolding>[north]);
      var loads = 0;
      var mutations = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return data;
          },
          createProduct: (_) async {
            mutations += 1;
            throw StateError('unused');
          },
          setProductPrice: (_) async {
            mutations += 1;
            throw StateError('unused');
          },
          submitStockIntake: (_) async {
            mutations += 1;
            throw StateError('unused');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('North Demo Branch: 1.25 kg'), findsOneWidget);
      expect(find.text(southMissing), findsOneWidget);
      expect(find.textContaining('South Demo Branch: 0'), findsNothing);
      expect(data.items.single.holdings, hasLength(1));
      expect(identical(data.items.single.holdings.single, north), isTrue);
      expect(loads, 1);
      expect(mutations, 0);
    });

    testWidgets('unheld product lists both known branches without quantities', (
      tester,
    ) async {
      final CatalogSnapshot data = snapshot();
      await tester.pumpWidget(
        _authenticatedApp(session: _administrator, loader: (_) async => data),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('North Demo Branch: Agotado · Sin entrada registrada'),
        findsOneWidget,
      );
      expect(find.text(southMissing), findsOneWidget);
      expect(find.text('Sin existencias en sucursales'), findsNothing);
      expect(find.textContaining(': 0.00 kg'), findsNothing);
      expect(data.items.single.holdings, isEmpty);
    });

    testWidgets(
      'positive zero and absent rows are distinct in branch ID order',
      (tester) async {
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: (_) async => snapshot(
              holdings: const <CatalogHolding>[
                CatalogHolding(
                  branchId: 'branch-west',
                  branchName: 'West Branch',
                  quantityScaled: 0,
                ),
                north,
              ],
              choices: <CatalogBranchChoice>[
                const CatalogBranchChoice(
                  branchId: 'branch-west',
                  branchName: 'West Branch',
                ),
                _branches[1],
                _branches[0],
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('North Demo Branch: 1.25 kg'), findsOneWidget);
        expect(find.text(southMissing), findsOneWidget);
        expect(find.text('West Branch: 0.00 kg · Agotado'), findsOneWidget);
        expect(
          find.textContaining('West Branch: Agotado · Sin entrada'),
          findsNothing,
        );
        expect(
          tester.getTopLeft(find.text('North Demo Branch: 1.25 kg')).dy,
          lessThan(tester.getTopLeft(find.text(southMissing)).dy),
        );
        expect(
          tester.getTopLeft(find.text(southMissing)).dy,
          lessThan(
            tester.getTopLeft(find.text('West Branch: 0.00 kg · Agotado')).dy,
          ),
        );
      },
    );

    for (final int quantity in <int>[125, 0]) {
      testWidgets(
        'seller quantity $quantity ignores available branch metadata',
        (tester) async {
          var mutations = 0;
          await tester.pumpWidget(
            _authenticatedApp(
              session: _seller,
              loader: (_) async => snapshot(
                holdings: <CatalogHolding>[
                  CatalogHolding(
                    branchId: 'branch-north',
                    branchName: 'North Demo Branch',
                    quantityScaled: quantity,
                  ),
                ],
              ),
              submitStockIntake: (_) async {
                mutations += 1;
                throw StateError('unused');
              },
              setProductPrice: (_) async {
                mutations += 1;
                throw StateError('unused');
              },
              createProduct: (_) async {
                mutations += 1;
                throw StateError('unused');
              },
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(
              quantity == 0 ? 'Existencias: 0.00 kg' : 'Existencias: 1.25 kg',
            ),
            findsOneWidget,
          );
          expect(
            find.text('Agotado'),
            quantity == 0 ? findsOneWidget : findsNothing,
          );
          expect(find.textContaining('Demo Branch'), findsNothing);
          expect(find.textContaining('Sin entrada registrada'), findsNothing);
          expect(find.text('Registrar entrada de inventario'), findsNothing);
          expect(find.text('Editar precio / IVA'), findsNothing);
          expect(
            find.textContaining(RegExp('costo?', caseSensitive: false)),
            findsNothing,
          );
          expect(mutations, 0);
        },
      );
    }

    testWidgets(
      'refresh replaces missing stock and adds new branch reminders',
      (tester) async {
        final _CatalogLoader loader = _CatalogLoader();
        await tester.pumpWidget(
          _authenticatedApp(session: _administrator, loader: loader.call),
        );
        loader.requests.single.complete(
          snapshot(holdings: const <CatalogHolding>[north]),
        );
        await tester.pumpAndSettle();
        expect(find.text(southMissing), findsOneWidget);
        await tester.tap(find.byTooltip('Actualizar catálogo'));
        await tester.pump();
        expect(find.text(southMissing), findsNothing);
        loader.requests.last.complete(
          snapshot(
            holdings: const <CatalogHolding>[
              north,
              CatalogHolding(
                branchId: 'branch-south',
                branchName: 'South Demo Branch',
                quantityScaled: 250,
              ),
            ],
            choices: const <CatalogBranchChoice>[
              ..._branches,
              CatalogBranchChoice(
                branchId: 'branch-west',
                branchName: 'West Branch',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(southMissing), findsNothing);
        expect(find.text('South Demo Branch: 2.50 kg'), findsOneWidget);
        expect(
          find.text('West Branch: Agotado · Sin entrada registrada'),
          findsOneWidget,
        );
        expect(loader.requests, hasLength(2));
        // Desktop/web keeps the bar refresh button (S2); the mobile menu
        // entry is covered in mobile_app_bar_test.dart.
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('administrator to seller replacement clears branch reminders', (
      tester,
    ) async {
      final _CatalogLoader loader = _CatalogLoader();
      await tester.pumpWidget(
        _authenticatedApp(session: _administrator, loader: loader.call),
      );
      loader.requests.single.complete(snapshot());
      await tester.pumpAndSettle();
      expect(find.text(southMissing), findsOneWidget);
      await tester.pumpWidget(
        _authenticatedApp(session: _seller, loader: loader.call),
      );
      expect(find.text(southMissing), findsNothing);
      loader.requests.last.complete(
        snapshot(holdings: const <CatalogHolding>[north]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existencias: 1.25 kg'), findsOneWidget);
      expect(find.textContaining('Demo Branch'), findsNothing);
      expect(find.textContaining('Sin entrada registrada'), findsNothing);
    });

    testWidgets('real holding omitted from choices is retained once', (
      tester,
    ) async {
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => snapshot(
            holdings: const <CatalogHolding>[north],
            choices: <CatalogBranchChoice>[_branches[1]],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('North Demo Branch: 1.25 kg'), findsOneWidget);
      expect(find.text(southMissing), findsOneWidget);
    });

    for (final List<CatalogBranchChoice> choices in <List<CatalogBranchChoice>>[
      <CatalogBranchChoice>[_branches[0], _branches[0]],
      const <CatalogBranchChoice>[
        CatalogBranchChoice(
          branchId: 'branch-north',
          branchName: 'Same Branch',
        ),
        CatalogBranchChoice(
          branchId: 'branch-south',
          branchName: 'Same Branch',
        ),
      ],
      const <CatalogBranchChoice>[
        CatalogBranchChoice(branchId: 'raw-id', branchName: 'South'),
      ],
      const <CatalogBranchChoice>[
        CatalogBranchChoice(branchId: 'branch-south', branchName: ''),
      ],
      const <CatalogBranchChoice>[
        CatalogBranchChoice(branchId: 'branch-south', branchName: ' South '),
      ],
      const <CatalogBranchChoice>[
        CatalogBranchChoice(
          branchId: 'branch-south',
          branchName: 'South\nBranch',
        ),
      ],
    ]) {
      testWidgets(
        'invalid metadata fails closed ${choices.first.branchId} ${choices.first.branchName.codeUnits}',
        (tester) async {
          await tester.pumpWidget(
            _authenticatedApp(
              session: _administrator,
              loader: (_) async => snapshot(choices: choices),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Catálogo no disponible'), findsOneWidget);
          expect(find.text('Coffee'), findsNothing);
          expect(find.textContaining('Sin entrada registrada'), findsNothing);
        },
      );
    }
  });
  testWidgets('shows an accessible loading state', (WidgetTester tester) async {
    final Completer<List<CatalogProduct>> completer =
        Completer<List<CatalogProduct>>();

    await tester.pumpWidget(_app(_Repository(completer.future)));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Cargando catálogo'), findsOneWidget);
  });

  testWidgets('shows an empty catalog state', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aún no hay productos'), findsOneWidget);
    expect(
      find.text('Los productos aparecerán aquí cuando estén disponibles.'),
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

    expect(find.text('Catálogo no disponible'), findsOneWidget);
    expect(find.textContaining('secret-stack-value'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Reintentar'), findsOneWidget);
  });

  testWidgets('renders the exact internal code as the QR data', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(_Repository(Future.value(<CatalogProduct>[_coffee]))),
    );
    await tester.pumpAndSettle();

    // The QR and the full pricing detail live in the detail sheet since T5;
    // the compact card shows only name, stock and price.
    await tester.tap(
      find.byKey(const ValueKey<String>('product-details-PRD-COFFEE-001')),
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
      find.bySemanticsLabel('Código QR de Coffee. Código PRD-COFFEE-001'),
      findsOneWidget,
    );
    expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
    expect(find.text('Modo de precio: IVA incluido'), findsOneWidget);
    expect(find.text('Tratamiento de IVA: Gravado'), findsOneWidget);
    expect(find.text('Tasa de IVA: 16%'), findsOneWidget);
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

      expect(find.text('Catálogo'), findsOneWidget);
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
    expect(find.bySemanticsLabel('Cargando catálogo'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Actualizar catálogo'));
    await tester.pump();

    expect(loader.requests, hasLength(2));
    expect(find.text('Coffee'), findsNothing);
    expect(find.bySemanticsLabel('Cargando catálogo'), findsOneWidget);

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
    expect(find.text('Existencias: 4 piece'), findsOneWidget);
    // Desktop/web keeps the bar refresh button (S2); the mobile menu entry
    // is covered in mobile_app_bar_test.dart.
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
    expect(find.text('Sin existencias en sucursales'), findsOneWidget);
  });

  testWidgets('empty catalog is explicit', (WidgetTester tester) async {
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aún no hay productos'), findsOneWidget);
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

    expect(find.text('Catálogo no disponible'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Existencias: 9.99 kg'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Reintentar'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Existencias: 1.00 kg'), findsOneWidget);
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

      expect(find.text('Catálogo no disponible'), findsOneWidget);
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

      expect(find.text('Catálogo no disponible'), findsOneWidget);
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

    expect(find.text('Catálogo no disponible'), findsOneWidget);
    expect(find.textContaining('secret firestore sdk detail'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Reintentar'));
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
    expect(find.bySemanticsLabel('Cargando catálogo'), findsOneWidget);

    loader.requests.first.complete(_snapshot(_coffee));
    await tester.pump();
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Catálogo no disponible'), findsNothing);

    const CatalogProduct tea = CatalogProduct(
      internalCode: 'PRD-TEA-002',
      name: 'Tea',
      quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
    );
    loader.requests.last.complete(_snapshot(tea));
    await tester.pumpAndSettle();
    expect(find.text('Tea'), findsOneWidget);
  });

  testWidgets('product card labels the unit as Unit with its precision', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshot(
          _coffee,
          holdings: const <CatalogHolding>[
            CatalogHolding(
              branchId: 'branch-north',
              branchName: 'North Demo Branch',
              quantityScaled: 100,
            ),
          ],
        ),
        setProductPrice: (_) async => throw StateError('must not submit'),
      ),
    );
    await tester.pumpAndSettle();

    // The unit line and the pricing action moved into the detail sheet
    // (T4/T5); the per-branch stock line stays on the compact card.
    expect(find.text('North Demo Branch: 1.00 kg'), findsOneWidget);
    await _openProductSheet(tester, _coffee.internalCode);
    expect(find.text('Unidad: kg (precisión 2)'), findsOneWidget);
    expect(find.text('Cantidad: kg (precisión 2)'), findsNothing);
    expect(find.text('Editar precio / IVA'), findsOneWidget);
    expect(find.text('Configure price / IVA'), findsNothing);
    await _closeProductSheet(tester);
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

    expect(find.text('Crear producto'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('create-product-name')),
      findsNothing,
    );
    expect(creationCalls, 0);
  });

  testWidgets(
    'one create reports every invalid field at once with accessible errors',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Nombre del producto'), findsOneWidget);
      expect(find.bySemanticsLabel('Identificador de unidad'), findsOneWidget);
      // The collapsed precision dropdown announces through its hint until a
      // value is selected, so assert the hint and the decoration label.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('create-product-precision')),
          matching: find.text('Selecciona de 0 a 6 decimales'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const ValueKey<String>('create-product-precision')),
            )
            .decoration
            .labelText,
        'Decimales del producto',
      );
      final Finder nameField = find.byKey(
        const ValueKey<String>('create-product-name'),
      );
      final Finder unitField = find.byKey(
        const ValueKey<String>('create-product-unit'),
      );
      final Finder precisionField = find.byKey(
        const ValueKey<String>('create-product-precision'),
      );
      expect(find.byIcon(Icons.error_outline), findsNothing);

      void expectFieldFeedback(Finder field, String message, RegExp label) {
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

      void expectDropdownFeedback(String message, RegExp label) {
        expect(
          tester
              .widget<DropdownButtonFormField<int>>(precisionField)
              .decoration
              .errorText,
          message,
        );
        expect(find.text(message), findsOneWidget);
        final Finder icon = find.descendant(
          of: precisionField,
          matching: find.byIcon(Icons.error_outline),
        );
        expect(icon, findsOneWidget);
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

      await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
      await tester.pump();

      expect(requests, isEmpty);
      expect(find.bySemanticsLabel('Error al crear el producto'), findsNothing);
      expectFieldFeedback(
        nameField,
        'El nombre del producto es obligatorio.',
        RegExp('^Error en el nombre del producto: '),
      );
      expectFieldFeedback(
        unitField,
        'La unidad es obligatoria.',
        RegExp('^Error en la unidad: '),
      );
      expectDropdownFeedback(
        'La precisión es obligatoria.',
        RegExp('^Error en la precisión: '),
      );

      // Invalid non-empty values report their own field, not the banner.
      await tester.enterText(nameField, ' Coffee ');
      await tester.enterText(unitField, 'Piece');
      await tester.pump();
      expect(find.text('El nombre del producto es obligatorio.'), findsNothing);
      expect(find.text('La unidad es obligatoria.'), findsNothing);
      expect(find.text('La precisión es obligatoria.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
      await tester.pump();

      expect(requests, isEmpty);
      expectFieldFeedback(
        nameField,
        'El nombre debe tener de 1 a 120 caracteres, sin espacios al inicio '
        'o al final ni caracteres de control.',
        RegExp('^Error en el nombre del producto: '),
      );
      expectFieldFeedback(
        unitField,
        'La unidad debe empezar con una letra minúscula y usar solo minúsculas, '
        'números, guiones bajos o guiones (de 1 a 32 caracteres).',
        RegExp('^Error en la unidad: '),
      );
      expectDropdownFeedback(
        'La precisión es obligatoria.',
        RegExp('^Error en la precisión: '),
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: nameField, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        ' Coffee ',
      );
      semantics.dispose();
    },
  );

  testWidgets('partial fill blocks submit and clears only the edited error', (
    WidgetTester tester,
  ) async {
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
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await tester.pump();

    expect(requests, isEmpty);
    expect(find.text('El nombre del producto es obligatorio.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Coffee',
    );
    await tester.pump();
    expect(find.text('El nombre del producto es obligatorio.'), findsNothing);
    expect(find.text('La unidad es obligatoria.'), findsOneWidget);
    expect(find.text('La precisión es obligatoria.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await tester.pump();
    expect(find.text('La unidad es obligatoria.'), findsNothing);
    expect(find.text('La precisión es obligatoria.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await tester.pump();
    expect(requests, isEmpty);

    await _selectCreationPrecision(tester, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(
      requests.single,
      const ProductCreationDraft(
        idempotencyKey: 'draft-key-1',
        name: 'Coffee',
        unit: 'piece',
        precision: 0,
      ),
    );
    expect(find.text('Producto creado correctamente'), findsOneWidget);
  });

  testWidgets(
    'precision is a required dropdown of 0 through 6 without a default',
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
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();

      final Finder precisionField = find.byKey(
        const ValueKey<String>('create-product-precision'),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(precisionField)
            .initialValue,
        isNull,
      );
      expect(
        find.descendant(
          of: precisionField,
          matching: find.text('Selecciona de 0 a 6 decimales'),
        ),
        findsOneWidget,
      );

      await tester.tap(precisionField);
      await tester.pumpAndSettle();
      for (final int value in <int>[0, 1, 2, 3, 4, 5, 6]) {
        expect(find.text('$value'), findsOneWidget);
      }
      expect(find.text('7'), findsNothing);
      await tester.tap(find.text('6').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        'Coffee',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'piece',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
      await tester.pumpAndSettle();
      expect(requests.single.precision, 6);

      // Reopening starts unset again: no silent default, not even to 0.
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(precisionField)
            .initialValue,
        isNull,
      );
      expect(
        find.descendant(
          of: precisionField,
          matching: find.text('Selecciona de 0 a 6 decimales'),
        ),
        findsOneWidget,
      );
      await tester.tap(precisionField);
      await tester.pumpAndSettle();
      await tester.tap(find.text('0').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        'Tea',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'kg',
      );
      final Finder createAgain = find.widgetWithText(FilledButton, 'Crear');
      await tester.ensureVisible(createAgain);
      await tester.tap(createAgain);
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(requests.last.precision, 0);
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
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await _selectCreationPrecision(tester, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await tester.pumpAndSettle();

    expect(find.textContaining('resultado es incierto'), findsOneWidget);
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
      'Reintentar misma solicitud',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests[1], same(requests[0]));
    expect(find.text('Producto creado correctamente'), findsOneWidget);
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
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const ValueKey<String>('create-product-precision')),
          )
          .initialValue,
      0,
    );
    expect(keyCalls, 0);
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Reintentar misma solicitud',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(attempts, <ProductCreationDraft>[unresolved]);
    expect(keyCalls, 1);
    expect(find.text('Producto creado correctamente'), findsOneWidget);
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
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'Coffee',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await _selectCreationPrecision(tester, 0);
    final Finder create = find.widgetWithText(FilledButton, 'Crear');
    await tester.tap(create);
    await tester.tap(create, warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
    expect(find.bySemanticsLabel('Creando producto'), findsOneWidget);
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
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-name')),
      'New product',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('create-product-unit')),
      'piece',
    );
    await _selectCreationPrecision(tester, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Producto creado correctamente'), findsOneWidget);
    // The QR lives in the detail sheet since T5.
    await _openProductSheet(tester, 'PRD-NEW-0001');
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
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        'New product',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'piece',
      );
      await _selectCreationPrecision(tester, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
      await tester.pumpAndSettle();

      expect(creates, 1);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.text('Catálogo no disponible'), findsOneWidget);
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
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();

      expect(find.text('Nombre del producto'), findsOneWidget);
      expect(find.text('Crear'), findsOneWidget);
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
        await tester.tap(find.text('Crear producto'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-name')),
          'Coffee',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-unit')),
          'piece',
        );
        await _selectCreationPrecision(tester, 0);
        await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
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

        expect(find.text('Producto creado correctamente'), findsNothing);
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

    // The seller's sheet shows price and price mode; IVA treatment and rate
    // are administrator-only (S5), and no pricing control ever appears.
    await _openProductSheet(tester, _coffee.internalCode);
    expect(find.text('Precio de lista: 129.00 MXN'), findsOneWidget);
    expect(find.text('Modo de precio: IVA incluido'), findsOneWidget);
    await _closeProductSheet(tester);
    expect(find.text('Tratamiento de IVA: Gravado'), findsNothing);
    expect(find.text('Tasa de IVA: 16%'), findsNothing);
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.text('Editar precio / IVA'), findsNothing);
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');

    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('PRD-COFFEE-001'), findsNothing);
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

    await tester.tap(find.widgetWithText(FilledButton, 'Guardar precio / IVA'));
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
    expect(find.text('Precio guardado'), findsOneWidget);
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');

      final Finder rateField = find.byKey(
        const ValueKey<String>('pricing-iva-rate'),
      );
      await tester.enterText(rateField, '');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pump();

      expect(requests, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: rateField, matching: find.byType(TextField)),
            )
            .decoration
            ?.errorText,
        'La tasa de IVA es obligatoria para productos gravados.',
      );
      expect(
        find.bySemanticsLabel(
          RegExp(
            'tasa de IVA.*obligatoria para productos gravados',
            caseSensitive: false,
          ),
        ),
        findsOneWidget,
      );

      await tester.enterText(rateField, '16');
      await tester.pump();
      expect(
        find.text('La tasa de IVA es obligatoria para productos gravados.'),
        findsNothing,
      );

      await tester.enterText(rateField, '');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('pricing-treatment')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasa 0%').last);
      await tester.pumpAndSettle();
      expect(
        find.text('La tasa de IVA es obligatoria para productos gravados.'),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
      expect(
        find.text('La tasa de IVA es obligatoria para productos gravados.'),
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
        await _openProductSheet(tester, productId);
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
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');

      expect(requests, isEmpty);
      expect(pricingIds, 0);
      expect(find.text('Editar precio / IVA'), findsOneWidget);
      expect(find.text('Configure price / IVA'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: priceField, matching: find.byType(TextField)),
            )
            .decoration
            ?.errorText,
        'El precio de lista es obligatorio.',
      );
      expect(
        find.bySemanticsLabel(
          RegExp('precio de lista.*obligatorio', caseSensitive: false),
        ),
        findsOneWidget,
      );

      await tester.enterText(priceField, 'invalid');
      await tester.pump();
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');
      expect(requests, isEmpty);
      expect(pricingIds, 1);
      expect(
        find.bySemanticsLabel('Error en el precio del producto'),
        findsOneWidget,
      );

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');
      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();
      await openPricing(_coffee.internalCode);
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');
      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();
      await openPricing(tea.internalCode);
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');
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
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);
      await openPricing(_coffee.internalCode);

      await tester.enterText(priceField, '');
      await tapPricingButton(FilledButton, 'Guardar precio / IVA');
      authoritative = restored;
      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();
      await openPricing(_coffee.internalCode);
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);
      expect(find.text('Reintentar misma solicitud'), findsOneWidget);
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
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
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);
      expect(
        find.text('La tasa de IVA es obligatoria para productos gravados.'),
        findsNothing,
      );

      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
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
        'El precio de lista es obligatorio.',
        RegExp('precio de lista.*obligatorio', caseSensitive: false),
      );
      expectRequiredFeedback(
        rateField,
        'La tasa de IVA es obligatoria para productos gravados.',
        RegExp(
          'tasa de IVA.*obligatoria para productos gravados',
          caseSensitive: false,
        ),
      );
      await tester.enterText(priceField, '129.00');
      await tester.pump();
      expect(find.text('El precio de lista es obligatorio.'), findsNothing);
      expectRequiredFeedback(
        rateField,
        'La tasa de IVA es obligatoria para productos gravados.',
        RegExp(
          'tasa de IVA.*obligatoria para productos gravados',
          caseSensitive: false,
        ),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pump();
      expect(pricingIds, 0);
      expect(requests, isEmpty);
      await tester.enterText(rateField, '16');
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsNothing);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pumpAndSettle();
      expect(pricingIds, 1);
      expect(requests, hasLength(1));
      expect(requests.single.listedPriceMxn, '129.00');
      expect(requests.single.ivaRatePercent, '16');
      expect(find.text('Precio guardado'), findsOneWidget);
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');

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

        // Errors inherit the themed outline (or the default fallback).
        final OutlineInputBorder normalOutline =
            themeBorder is OutlineInputBorder
            ? themeBorder
            : const OutlineInputBorder();
        expect(errorBorder.borderRadius, normalOutline.borderRadius);
        expect(focusedErrorBorder.borderRadius, normalOutline.borderRadius);

        // The icon is decorative only: its render object contributes no
        // semantics node, so the live region keeps announcing the message.
        expect(tester.renderObject(errorIcon).debugSemantics, isNull);
        expect(find.bySemanticsLabel(announcedLabel), findsOneWidget);
      }

      // Pricing fields leave the normal shape to the app theme.
      expect(decorationOf('pricing-listed-price').border, isNull);
      expect(decorationOf('pricing-iva-rate').border, isNull);

      // Blank listed price: strong local error presentation.
      final Finder priceField = find.byKey(
        const ValueKey<String>('pricing-listed-price'),
      );
      await tester.enterText(priceField, '');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pump();
      expectStrongErrorPresentation(
        'pricing-listed-price',
        'El precio de lista es obligatorio.',
        RegExp('precio de lista.*obligatorio', caseSensitive: false),
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
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pump();
      expectStrongErrorPresentation(
        'pricing-iva-rate',
        'La tasa de IVA es obligatoria para productos gravados.',
        RegExp(
          'tasa de IVA.*obligatoria para productos gravados',
          caseSensitive: false,
        ),
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'unset pricing errors are simultaneous accessible and independently cleared',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const CatalogProduct product = CatalogProduct(
        internalCode: 'PRD-UNPRICED',
        name: 'Unpriced',
        quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
      );
      var ids = 0;
      var calls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshot(product),
          createPricingId: () {
            ids += 1;
            return 'unused-key';
          },
          setProductPrice: (_) async {
            calls += 1;
            throw StateError('invalid');
          },
        ),
      );
      await tester.pumpAndSettle();
      Future<void> open() async {
        await _openSheetAndConfigurePricing(tester, 'PRD-UNPRICED');
      }

      Future<void> save() async {
        await tester.tap(
          find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
        );
        await tester.pumpAndSettle();
      }

      Future<void> select(String key, String label) async {
        await tester.tap(find.byKey(ValueKey<String>(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      InputDecoration decoration(String key) {
        final Finder field = find.byKey(ValueKey<String>(key));
        if (key == 'pricing-mode' || key == 'pricing-treatment') {
          return tester
              .widget<DropdownButtonFormField<String>>(field)
              .decoration;
        }
        return tester
            .widget<TextField>(
              find.descendant(of: field, matching: find.byType(TextField)),
            )
            .decoration!;
      }

      final Map<String, String> messages = <String, String>{
        'pricing-listed-price': 'El precio de lista es obligatorio.',
        'pricing-mode': 'El modo de precio es obligatorio.',
        'pricing-treatment': 'El tratamiento de IVA es obligatorio.',
      };
      await open();
      for (final String key in messages.keys) {
        expect(decoration(key).border, isNull);
        expect(decoration(key).errorText, isNull);
      }
      await save();
      final ThemeData theme = Theme.of(
        tester.element(find.byKey(const ValueKey<String>('pricing-mode'))),
      );
      for (final MapEntry<String, String> entry in messages.entries) {
        final InputDecoration value = decoration(entry.key);
        expect(value.errorText, entry.value);
        final InputBorder? themed = theme.inputDecorationTheme.border;
        final OutlineInputBorder normal = themed is OutlineInputBorder
            ? themed
            : const OutlineInputBorder();
        for (final InputBorder? border in <InputBorder?>[
          value.errorBorder,
          value.focusedErrorBorder,
        ]) {
          final OutlineInputBorder error = border! as OutlineInputBorder;
          expect(error.borderSide.width, 2);
          expect(error.borderSide.color, theme.colorScheme.error);
          expect(error.borderRadius, normal.borderRadius);
        }
        final Finder icon = find.descendant(
          of: find.byKey(ValueKey<String>(entry.key)),
          matching: find.byIcon(Icons.error_outline),
        );
        expect(icon, findsOneWidget);
        expect(tester.renderObject(icon).debugSemantics, isNull);
        final Finder announcement = find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics &&
              widget.properties.label?.endsWith(entry.value) == true,
        );
        expect(announcement, findsOneWidget);
        expect(tester.widget<Semantics>(announcement).container, isTrue);
        expect(
          tester.widget<Semantics>(announcement).properties.liveRegion,
          isTrue,
        );
        expect(
          find.bySemanticsLabel(
            RegExp('^Error en .*: ${RegExp.escape(entry.value)}'),
          ),
          findsOneWidget,
        );
      }
      expect(decoration('pricing-iva-rate').errorText, isNull);
      await tester.enterText(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        '129.00',
      );
      await tester.pump();
      expect(decoration('pricing-listed-price').errorText, isNull);
      await save();
      expect(decoration('pricing-mode').errorText, messages['pricing-mode']);
      expect(
        decoration('pricing-treatment').errorText,
        messages['pricing-treatment'],
      );
      await select('pricing-mode', 'IVA adicional en factura');
      expect(decoration('pricing-mode').errorText, isNull);
      expect(
        decoration('pricing-treatment').errorText,
        messages['pricing-treatment'],
      );
      await select('pricing-treatment', 'Gravado');
      expect(decoration('pricing-treatment').errorText, isNull);
      await tester.enterText(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        '   ',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('pricing-iva-rate')),
        '   ',
      );
      await save();
      expect(
        decoration('pricing-listed-price').errorText,
        messages['pricing-listed-price'],
      );
      expect(
        decoration('pricing-iva-rate').errorText,
        'La tasa de IVA es obligatoria para productos gravados.',
      );
      await select('pricing-treatment', 'Tasa 0%');
      expect(decoration('pricing-iva-rate').errorText, isNull);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-iva-rate')),
            )
            .controller!
            .text,
        '0',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-iva-rate')),
            )
            .enabled,
        isFalse,
      );
      await save();
      expect(decoration('pricing-iva-rate').errorText, isNull);
      await select('pricing-treatment', 'Exento');
      await save();
      expect(
        find.byKey(const ValueKey<String>('pricing-iva-rate')),
        findsNothing,
      );
      expect(
        find.text('La tasa de IVA es obligatoria para productos gravados.'),
        findsNothing,
      );
      expect(
        decoration('pricing-listed-price').errorText,
        messages['pricing-listed-price'],
      );
      expect(ids, 0);
      expect(calls, 0);
      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();
      await open();
      for (final String key in messages.keys) {
        expect(decoration(key).errorText, isNull);
      }
      expect(find.text('Selecciona el modo de precio'), findsOneWidget);
      expect(find.text('Selecciona el tratamiento de IVA'), findsOneWidget);
      await select('pricing-treatment', 'Gravado');
      await save();
      expect(
        decoration('pricing-listed-price').errorText,
        messages['pricing-listed-price'],
      );
      expect(decoration('pricing-mode').errorText, messages['pricing-mode']);
      expect(decoration('pricing-treatment').errorText, isNull);
      expect(decoration('pricing-iva-rate').errorText, isNull);
      await tester.enterText(
        find.byKey(const ValueKey<String>('pricing-iva-rate')),
        '8',
      );
      await tester.pump();
      expect(decoration('pricing-iva-rate').errorText, isNull);
      expect(
        decoration('pricing-listed-price').errorText,
        messages['pricing-listed-price'],
      );
      expect(decoration('pricing-mode').errorText, messages['pricing-mode']);
      expect(ids, 0);
      expect(calls, 0);
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
    await _openSheetAndConfigurePricing(tester, 'PRD-TEA-0002');

    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
          )
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.text('Selecciona el modo de precio'), findsOneWidget);
    expect(find.text('Selecciona el tratamiento de IVA'), findsOneWidget);
    expect(find.text('16'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar precio / IVA'));
    await tester.pump();
    expect(find.text('El precio de lista es obligatorio.'), findsOneWidget);
    expect(find.text('El modo de precio es obligatorio.'), findsOneWidget);
    expect(find.text('El tratamiento de IVA es obligatorio.'), findsOneWidget);
    expect(
      find.text('La tasa de IVA es obligatoria para productos gravados.'),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel('Error en el precio del producto'),
      findsNothing,
    );
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar precio / IVA'));
    await tester.pumpAndSettle();

    expect(find.textContaining('resultado es incierto'), findsOneWidget);
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
      'Reintentar misma solicitud',
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pumpAndSettle();

      expect(requests.single.idempotencyKey, 'pricing-new-faux');
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
            )
            .controller
            ?.text,
        stored.listedPriceMxn,
      );
      expect(find.text('Tasa de IVA: No requerida'), findsNWidgets(2));

      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(requests, hasLength(2));
      expect(requests[1], same(stored));
      expect(requests[1].idempotencyKey, 'pricing-original-a');
      expect(find.text('Precio guardado'), findsOneWidget);
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
      await tester.tap(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Catálogo no disponible'), findsOneWidget);
      expect(find.text('Reintentar misma solicitud'), findsNothing);
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
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
      await tester.tap(find.byKey(const ValueKey<String>('pricing-treatment')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(treatment == 'zero-rated' ? 'Tasa 0%' : 'Exento').last,
      );
      await tester.pumpAndSettle();

      if (treatment == 'zero-rated') {
        final TextFormField rate = tester.widget<TextFormField>(
          find.byKey(const ValueKey<String>('pricing-iva-rate')),
        );
        expect(rate.enabled, isFalse);
        expect(rate.controller?.text, '0');
      } else {
        expect(find.text('Tasa de IVA: No requerida'), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey<String>('pricing-iva-rate')),
          findsNothing,
        );
      }
      final Finder save = find.widgetWithText(
        FilledButton,
        'Guardar precio / IVA',
      );
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
    final Finder save = find.widgetWithText(
      FilledButton,
      'Guardar precio / IVA',
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);
    expect(
      find.bySemanticsLabel('Guardando precio del producto'),
      findsOneWidget,
    );
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
    final Finder save = find.widgetWithText(
      FilledButton,
      'Guardar precio / IVA',
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(mutations, 1);
    expect(find.text('Precio guardado'), findsOneWidget);
    // The refreshed pricing fields show in the detail sheet (T5).
    await _openProductSheet(tester, _coffee.internalCode);
    expect(find.text('Precio de lista: 200.00 MXN'), findsOneWidget);
    expect(
      find.text('Modo de precio: IVA adicional en factura'),
      findsOneWidget,
    );
    expect(find.text('Tratamiento de IVA: Exento'), findsOneWidget);
    expect(find.text('Tasa de IVA: No requerida'), findsOneWidget);
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
    final Finder save = find.widgetWithText(
      FilledButton,
      'Guardar precio / IVA',
    );
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Precio guardado'), findsOneWidget);
    expect(find.text('Catálogo no disponible'), findsOneWidget);
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
    await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
    await tester.binding.setSurfaceSize(const Size(320, 480));
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();

    expect(find.text('Precio de lista (MXN)'), findsOneWidget);
    expect(find.text('Guardar precio / IVA'), findsOneWidget);
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
    expect(find.text('Catálogo no disponible'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    loader.requests.last.completeError(StateError('disposed secret'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('seller has no stock intake control, callback, or cost field', (
    WidgetTester tester,
  ) async {
    var intakeCalls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _seller,
        loader: (_) async => _snapshot(
          _coffee,
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 100),
          ],
        ),
        submitStockIntake: (_) async {
          intakeCalls += 1;
          throw StateError('seller callback must not run');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Registrar entrada de inventario'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('intake-PRD-COFFEE-001')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('intake-quantity')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('intake-unit-cost')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('intake-branch')), findsNothing);
    expect(intakeCalls, 0);
  });

  testWidgets(
    'one save reports all missing intake fields without allocating a key',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<StockIntakeDraft> requests = <StockIntakeDraft>[];
      var intakeIds = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshotWithBranches(_coffee),
          createIntakeId: () => 'intake-key-${++intakeIds}',
          submitStockIntake: (StockIntakeDraft draft) async {
            requests.add(draft);
            return _intakeResult(draft);
          },
        ),
      );
      await tester.pumpAndSettle();
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');

      final Finder branchField = find.byKey(
        const ValueKey<String>('intake-branch'),
      );
      final Finder quantityField = find.byKey(
        const ValueKey<String>('intake-quantity'),
      );
      final Finder costField = find.byKey(
        const ValueKey<String>('intake-unit-cost'),
      );
      expect(find.text('Selecciona una sucursal'), findsOneWidget);
      expect(find.textContaining('Total de la línea'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.text('La sucursal es obligatoria.'), findsNothing);
      expect(find.text('La cantidad es obligatoria.'), findsNothing);
      expect(find.text('El costo unitario es obligatorio.'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Registrar entrada'));
      await tester.pump();

      expect(intakeIds, 0);
      expect(requests, isEmpty);
      void expectFieldFeedback(Finder field, String message, RegExp label) {
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

      void expectDropdownFeedback(String message, RegExp label) {
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(branchField)
              .decoration
              .errorText,
          message,
        );
        expect(find.text(message), findsOneWidget);
        final Finder icon = find.descendant(
          of: branchField,
          matching: find.byIcon(Icons.error_outline),
        );
        expect(icon, findsOneWidget);
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

      expectDropdownFeedback(
        'La sucursal es obligatoria.',
        RegExp('^Error en la sucursal: '),
      );
      expectFieldFeedback(
        quantityField,
        'La cantidad es obligatoria.',
        RegExp('^Error en la cantidad: '),
      );
      expectFieldFeedback(
        costField,
        'El costo unitario es obligatorio.',
        RegExp('^Error en el costo unitario: '),
      );

      // Correcting one field keeps the remaining feedback visible.
      await tester.tap(branchField);
      await tester.pumpAndSettle();
      await tester.tap(find.text('North Demo Branch').last);
      await tester.pumpAndSettle();
      expect(find.text('La sucursal es obligatoria.'), findsNothing);
      expectFieldFeedback(
        quantityField,
        'La cantidad es obligatoria.',
        RegExp('^Error en la cantidad: '),
      );
      expectFieldFeedback(
        costField,
        'El costo unitario es obligatorio.',
        RegExp('^Error en el costo unitario: '),
      );

      await tester.enterText(quantityField, '2');
      await tester.enterText(costField, '12.50');
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Registrar entrada'));
      await tester.pumpAndSettle();

      await _confirmIntake(tester);
      await tester.pumpAndSettle();
      expect(intakeIds, 1);
      expect(requests, hasLength(1));
      expect(requests.single.toRequest(), <String, Object?>{
        'idempotencyKey': 'intake-key-1',
        'branchId': 'branch-north',
        'productId': 'PRD-COFFEE-001',
        'quantity': '2',
        'unitCostMxn': '12.50',
      });
      expect(find.text('Entrada registrada.'), findsOneWidget);
      expect(find.text('Registrar entrada'), findsNothing);

      // The next intake advances to a fresh idempotency key.
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
      await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('South Demo Branch').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-quantity')),
        '1',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-unit-cost')),
        '5',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Registrar entrada'));
      await tester.pumpAndSettle();
      await _confirmIntake(tester);
      await tester.pumpAndSettle();
      expect(intakeIds, 2);
      expect(requests, hasLength(2));
      expect(requests.last.idempotencyKey, 'intake-key-2');
      expect(requests.last.branchId, 'branch-south');
      semantics.dispose();
    },
  );

  testWidgets('intake shows the exact truncated line total preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshotWithBranches(_coffee),
        createIntakeId: () => 'intake-key-1',
        submitStockIntake: (_) async =>
            throw StateError('preview must not submit'),
      ),
    );
    await tester.pumpAndSettle();
    await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');

    final Finder branchField = find.byKey(
      const ValueKey<String>('intake-branch'),
    );
    final Finder quantityField = find.byKey(
      const ValueKey<String>('intake-quantity'),
    );
    final Finder costField = find.byKey(
      const ValueKey<String>('intake-unit-cost'),
    );
    expect(find.textContaining('Total de la línea'), findsNothing);

    await tester.tap(branchField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('North Demo Branch').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Total de la línea'), findsNothing);

    await tester.enterText(quantityField, '2.55');
    await tester.pump();
    expect(find.textContaining('Total de la línea'), findsNothing);

    await tester.enterText(costField, '12.33');
    await tester.pump();
    // 2.55 kg * 12.33 MXN: 255 * 1233 / 100 truncates to 3144 centavos.
    expect(
      find.text('Total de la línea (truncado): 31.44 MXN'),
      findsNWidgets(2),
    );

    await tester.enterText(quantityField, '0.01');
    await tester.enterText(costField, '0.01');
    await tester.pump();
    expect(
      find.text('Total de la línea (truncado): 0.00 MXN'),
      findsNWidgets(2),
    );

    await tester.enterText(quantityField, '0.001');
    await tester.pump();
    expect(find.textContaining('Total de la línea'), findsNothing);
  });

  testWidgets('uncertain intake locks fields and retries the same request', (
    WidgetTester tester,
  ) async {
    final List<StockIntakeDraft> requests = <StockIntakeDraft>[];
    var calls = 0;
    var keyCalls = 0;
    await tester.pumpWidget(
      _authenticatedApp(
        session: _administrator,
        loader: (_) async => _snapshotWithBranches(_coffee),
        createIntakeId: () => 'intake-key-${++keyCalls}',
        submitStockIntake: (StockIntakeDraft draft) async {
          requests.add(draft);
          calls += 1;
          if (calls == 1) throw const StockIntakeUncertainException();
          return _intakeResult(draft, replayed: true);
        },
      ),
    );
    await tester.pumpAndSettle();
    await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
    await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('North Demo Branch').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('intake-quantity')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('intake-unit-cost')),
      '12.50',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Registrar entrada'));
    await tester.pumpAndSettle();

    await _confirmIntake(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('resultado es incierto'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('intake-quantity')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey<String>('intake-unit-cost')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey<String>('intake-branch')),
          )
          .onChanged,
      isNull,
    );
    final Finder retry = find.widgetWithText(
      FilledButton,
      'Reintentar misma solicitud',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    await _confirmIntake(tester);
    await tester.pumpAndSettle();
    expect(keyCalls, 1);
    expect(requests, hasLength(2));
    expect(requests[1], same(requests[0]));
    expect(requests[1].idempotencyKey, 'intake-key-1');
    expect(find.text('Entrada registrada.'), findsOneWidget);
  });

  testWidgets(
    'deterministic intake rejection clears the lock and allows a fresh request',
    (WidgetTester tester) async {
      final List<StockIntakeDraft> requests = <StockIntakeDraft>[];
      var calls = 0;
      var keyCalls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshotWithBranches(_coffee),
          createIntakeId: () => 'intake-key-${++keyCalls}',
          submitStockIntake: (StockIntakeDraft draft) async {
            requests.add(draft);
            calls += 1;
            if (calls == 1) {
              throw const StockIntakeRejectedException(code: 'out-of-range');
            }
            return _intakeResult(draft);
          },
        ),
      );
      await tester.pumpAndSettle();
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
      await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('North Demo Branch').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-quantity')),
        '3',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-unit-cost')),
        '12.50',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Registrar entrada'));
      await tester.pumpAndSettle();

      await _confirmIntake(tester);
      await tester.pumpAndSettle();
      expect(find.text('Se rechazó la entrada de inventario.'), findsOneWidget);
      expect(find.text('Reintentar misma solicitud'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .enabled,
        isTrue,
      );

      final Finder retryRecord = find.widgetWithText(
        FilledButton,
        'Registrar entrada',
      );
      await tester.ensureVisible(retryRecord);
      await tester.tap(retryRecord);
      await tester.pumpAndSettle();

      await _confirmIntake(tester);
      await tester.pumpAndSettle();
      expect(keyCalls, 2);
      expect(requests, hasLength(2));
      expect(requests.last.idempotencyKey, 'intake-key-2');
      expect(find.text('Entrada registrada.'), findsOneWidget);
    },
  );

  testWidgets('intake success survives catalog refresh failure', (
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
          return _snapshotWithBranches(_coffee);
        },
        createIntakeId: () => 'intake-key-1',
        submitStockIntake: (StockIntakeDraft draft) async {
          mutations += 1;
          return _intakeResult(draft);
        },
      ),
    );
    await tester.pumpAndSettle();
    await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
    await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('North Demo Branch').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('intake-quantity')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('intake-unit-cost')),
      '12.50',
    );
    final Finder record = find.widgetWithText(
      FilledButton,
      'Registrar entrada',
    );
    await tester.ensureVisible(record);
    await tester.tap(record);
    await tester.pumpAndSettle();

    await _confirmIntake(tester);
    await tester.pumpAndSettle();
    expect(mutations, 1);
    expect(find.text('Entrada registrada.'), findsOneWidget);
    expect(find.text('Catálogo no disponible'), findsOneWidget);
    expect(find.text('Reintentar misma solicitud'), findsNothing);
  });

  testWidgets(
    'reopening intake restores the unresolved draft from the shell lookup',
    (WidgetTester tester) async {
      const StockIntakeDraft stored = StockIntakeDraft(
        idempotencyKey: 'intake-stored',
        branchId: 'branch-south',
        productId: 'PRD-COFFEE-001',
        quantity: '1.5',
        unitCostMxn: '10.00',
        quantitySpec: StockIntakeQuantitySpec(unit: 'kg', precision: 2),
      );
      StockIntakeDraft? authoritative;
      final List<StockIntakeDraft> requests = <StockIntakeDraft>[];
      var keyCalls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshotWithBranches(_coffee),
          createIntakeId: () {
            keyCalls += 1;
            return 'intake-key-new';
          },
          unresolvedIntakeDraftFor: (String productId, String branchId) =>
              productId == stored.productId && branchId == stored.branchId
              ? authoritative
              : null,
          submitStockIntake: (StockIntakeDraft draft) async {
            requests.add(draft);
            return _intakeResult(draft, replayed: true);
          },
        ),
      );
      await tester.pumpAndSettle();

      // First open: no unresolved draft, fresh form.
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
      expect(find.text('Selecciona una sucursal'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .controller
            ?.text,
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
      await tester.pumpAndSettle();

      // Reopen: the draft for South is restored explicitly and locked.
      authoritative = stored;
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');

      expect(find.text('South Demo Branch'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .controller
            ?.text,
        '1.5',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-unit-cost')),
            )
            .controller
            ?.text,
        '10.00',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .enabled,
        isFalse,
      );
      expect(find.text('Reintentar misma solicitud'), findsOneWidget);
      expect(keyCalls, 0);

      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      await _confirmIntake(tester);
      await tester.pumpAndSettle();
      expect(requests, <StockIntakeDraft>[stored]);
      expect(requests.single.idempotencyKey, 'intake-stored');
      expect(find.text('Entrada registrada.'), findsOneWidget);
    },
  );

  testWidgets(
    'selecting a branch with an unresolved request restores it explicitly',
    (WidgetTester tester) async {
      const StockIntakeDraft stored = StockIntakeDraft(
        idempotencyKey: 'intake-stored-south',
        branchId: 'branch-south',
        productId: 'PRD-COFFEE-001',
        quantity: '1.5',
        unitCostMxn: '10.00',
        quantitySpec: StockIntakeQuantitySpec(unit: 'kg', precision: 2),
      );
      final List<StockIntakeDraft> requests = <StockIntakeDraft>[];
      var keyCalls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async => _snapshotWithBranches(_coffee),
          createIntakeId: () {
            keyCalls += 1;
            return 'intake-key-new';
          },
          unresolvedIntakeDraftFor: (String productId, String branchId) =>
              productId == stored.productId && branchId == stored.branchId
              ? stored
              : null,
          submitStockIntake: (StockIntakeDraft draft) async {
            requests.add(draft);
            return _intakeResult(draft, replayed: true);
          },
        ),
      );
      await tester.pumpAndSettle();
      await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
      await tester.enterText(
        find.byKey(const ValueKey<String>('intake-quantity')),
        '9',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('South Demo Branch').last);
      await tester.pumpAndSettle();

      expect(find.text('South Demo Branch'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('intake-quantity')),
            )
            .controller
            ?.text,
        '1.5',
      );
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(find.text('Reintentar misma solicitud'), findsOneWidget);
      expect(keyCalls, 0);
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'stale intake completion is discarded after role change and disposal',
    (WidgetTester tester) async {
      for (final bool dispose in <bool>[false, true]) {
        final Completer<StockIntakeResult> pending =
            Completer<StockIntakeResult>();
        StockIntakeDraft? submitted;
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: (_) async => _snapshotWithBranches(_coffee),
            createIntakeId: () => 'intake-key-1',
            submitStockIntake: (StockIntakeDraft draft) {
              submitted = draft;
              return pending.future;
            },
          ),
        );
        await tester.pumpAndSettle();
        await _openSheetAndStartIntake(tester, 'PRD-COFFEE-001');
        await tester.tap(find.byKey(const ValueKey<String>('intake-branch')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('North Demo Branch').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('intake-quantity')),
          '3',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('intake-unit-cost')),
          '12.50',
        );
        final Finder record = find.widgetWithText(
          FilledButton,
          'Registrar entrada',
        );
        await tester.ensureVisible(record);
        await tester.tap(record);
        await _confirmIntake(tester);
        await tester.pump();

        if (dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
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
        }
        pending.complete(_intakeResult(submitted!));
        await tester.pumpAndSettle();

        expect(find.textContaining('Entrada registrada'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'creation outline inherits its theme and stays stable on errors',
    (WidgetTester tester) async {
      for (final ThemeData theme in <ThemeData>[
        ThemeData(
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
          ),
        ),
        ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(40)),
            ),
          ),
        ),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: AuthenticatedCatalogPage(
              session: _administrator,
              catalogLoader: (_) async =>
                  CatalogSnapshot(const <CatalogItem>[]),
              onLogout: () async {},
              createDraftId: () => 'outline-key',
              createProduct: (_) => throw StateError('must not submit'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Crear producto'));
        await tester.pumpAndSettle();
        InputDecoration decoration(String key) {
          final Finder field = find.byKey(ValueKey<String>(key));
          return tester
              .widget<InputDecorator>(
                find.descendant(
                  of: field,
                  matching: find.byType(InputDecorator),
                ),
              )
              .decoration;
        }

        final List<OutlineInputBorder> normal = <OutlineInputBorder>[];
        for (final String key in <String>[
          'create-product-name',
          'create-product-unit',
          'create-product-precision',
        ]) {
          final InputDecoration input = decoration(key);
          expect(input.border, isA<OutlineInputBorder>());
          normal.add(input.border! as OutlineInputBorder);
          expect(input.border, theme.inputDecorationTheme.border);
          expect(
            input.focusedBorder ?? input.border,
            isA<OutlineInputBorder>(),
          );
        }
        final Finder create = find.widgetWithText(FilledButton, 'Crear');
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();
        var index = 0;
        for (final String key in <String>[
          'create-product-name',
          'create-product-unit',
          'create-product-precision',
        ]) {
          final InputDecoration input = decoration(key);
          for (final InputBorder? border in <InputBorder?>[
            input.border,
            input.errorBorder,
            input.focusedErrorBorder,
          ]) {
            expect(border, isA<OutlineInputBorder>());
            final OutlineInputBorder outline = border! as OutlineInputBorder;
            expect(outline.borderRadius, normal[index].borderRadius);
            expect(outline.gapPadding, normal[index].gapPadding);
          }
          expect(input.errorBorder!.borderSide.width, 2);
          expect(
            input.focusedErrorBorder!.borderSide.color,
            theme.colorScheme.error,
          );
          index += 1;
        }
        expect(find.byIcon(Icons.error_outline), findsNWidgets(3));
      }
    },
  );

  for (final bool validation in <bool>[false, true]) {
    testWidgets(
      'client-valid creation retains server ${validation ? 'validation' : 'rejection'} banner',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
            createDraftId: () => 'banner-key',
            createProduct: (ProductCreationDraft draft) async {
              expect(draft.name, 'Coffee');
              expect(draft.unit, 'piece');
              expect(draft.precision, 0);
              if (validation) {
                throw const ProductCreationValidationException(
                  'Server validation declined the request.',
                );
              }
              throw const ProductCreationRejectedException(
                code: 'permission-denied',
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Crear producto'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-name')),
          'Coffee',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('create-product-unit')),
          'piece',
        );
        await _selectCreationPrecision(tester, 0);
        await tester.tap(find.widgetWithText(FilledButton, 'Crear'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            validation
                ? 'Server validation declined the request.'
                : 'Se rechazó la creación del producto (permission-denied).',
          ),
          findsOneWidget,
        );
        final Finder banner = find.bySemanticsLabel(
          'Error al crear el producto',
        );
        expect(banner, findsOneWidget);
        expect(
          tester
              .getSemantics(banner)
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(find.byIcon(Icons.error_outline), findsNothing);
        expect(
          find.textContaining(RegExp(r'es obligatori[oa]\.')),
          findsNothing,
        );
        expect(find.textContaining('Exception'), findsNothing);
        expect(find.textContaining('credential'), findsNothing);
        expect(find.text('Reintentar misma solicitud'), findsNothing);
        semantics.dispose();
      },
    );
  }

  group('chained creation-to-pricing', () {
    const CatalogProduct created = CatalogProduct(
      internalCode: 'PRD-NEW-0001',
      name: 'New product',
      quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
    );
    const ProductCreationResult createdResult = ProductCreationResult(
      productId: 'PRD-NEW-0001',
      internalCode: 'PRD-NEW-0001',
      replayed: false,
    );

    final CatalogSnapshot both = CatalogSnapshot(<CatalogItem>[
      CatalogItem(product: _coffee, holdings: const <CatalogHolding>[]),
      CatalogItem(product: created, holdings: const <CatalogHolding>[]),
    ]);

    Future<void> fillAndCreate(WidgetTester tester) async {
      await tester.tap(find.text('Crear producto'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-name')),
        'New product',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-product-unit')),
        'piece',
      );
      await _selectCreationPrecision(tester, 0);
      final Finder create = find.widgetWithText(FilledButton, 'Crear');
      await tester.ensureVisible(create);
      await tester.tap(create);
    }

    void expectEmptyPricingFormFor(WidgetTester tester, String code) {
      expect(
        find.widgetWithText(FilledButton, 'Guardar precio / IVA'),
        findsOneWidget,
      );
      expect(find.text(code), findsNothing);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey<String>('pricing-listed-price')),
            )
            .controller
            ?.text,
        isEmpty,
      );
      expect(find.text('Selecciona el modo de precio'), findsOneWidget);
      expect(find.text('Selecciona el tratamiento de IVA'), findsOneWidget);
    }

    testWidgets(
      'one save after real creation marks all unset pricing policies',
      (WidgetTester tester) async {
        final _CatalogLoader loader = _CatalogLoader();
        var pricingIds = 0;
        var pricingCalls = 0;
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: loader.call,
            createDraftId: () => 'creation-required-key',
            createProduct: (_) async => createdResult,
            createPricingId: () {
              pricingIds += 1;
              return 'pricing-required-key';
            },
            setProductPrice: (_) async {
              pricingCalls += 1;
              throw StateError('must not submit missing policies');
            },
          ),
        );
        loader.requests[0].complete(CatalogSnapshot(const <CatalogItem>[]));
        await tester.pumpAndSettle();
        await fillAndCreate(tester);
        await tester.pump();
        await tester.pump();
        expect(loader.requests, hasLength(2));
        loader.requests[1].complete(_snapshot(created));
        await tester.pumpAndSettle();
        expectEmptyPricingFormFor(tester, created.internalCode);
        expect(
          find.textContaining(RegExp(r'es obligatori[oa]\.')),
          findsNothing,
        );
        final Finder save = find.widgetWithText(
          FilledButton,
          'Guardar precio / IVA',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pump();
        expect(find.text('El precio de lista es obligatorio.'), findsOneWidget);
        expect(find.text('El modo de precio es obligatorio.'), findsOneWidget);
        expect(
          find.text('El tratamiento de IVA es obligatorio.'),
          findsOneWidget,
        );
        expect(
          find.text('La tasa de IVA es obligatoria para productos gravados.'),
          findsNothing,
        );
        expect(pricingIds, 0);
        expect(pricingCalls, 0);
      },
    );

    for (final bool close in <bool>[false, true]) {
      testWidgets(
        'manual new creation ${close ? 'open-close' : 'open'} cancels delayed handoff',
        (WidgetTester tester) async {
          final _CatalogLoader loader = _CatalogLoader();
          var creates = 0;
          await tester.pumpWidget(
            _authenticatedApp(
              session: _administrator,
              loader: loader.call,
              createDraftId: () => 'handoff-key',
              createProduct: (_) async {
                creates += 1;
                return createdResult;
              },
              setProductPrice: (_) => throw StateError('must not auto-submit'),
            ),
          );
          loader.requests[0].complete(CatalogSnapshot(const <CatalogItem>[]));
          await tester.pumpAndSettle();
          await fillAndCreate(tester);
          await tester.pump();
          await tester.pump();
          expect(loader.requests, hasLength(2));
          expect(find.text('Producto creado correctamente'), findsOneWidget);
          await tester.tap(find.text('Crear producto'));
          await tester.pump();
          if (close) {
            final Finder button = find.byKey(
              const ValueKey<String>('panel-back'),
            );
            await tester.ensureVisible(button);
            await tester.tap(button);
            await tester.pump();
          }
          loader.requests[1].complete(_snapshot(created));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('create-product-name')),
            close ? findsNothing : findsOneWidget,
          );
          expect(creates, 1);
          expect(find.text('Reintentar misma solicitud'), findsNothing);
          if (close) {
            await _openSheetAndConfigurePricing(tester, 'PRD-NEW-0001');
            expectEmptyPricingFormFor(tester, 'PRD-NEW-0001');
          }
        },
      );
    }

    for (final bool intake in <bool>[false, true]) {
      testWidgets(
        'manual ${intake ? 'intake' : 'pricing'} close cancels delayed creation handoff',
        (WidgetTester tester) async {
          final _CatalogLoader loader = _CatalogLoader();
          await tester.pumpWidget(
            _authenticatedApp(
              session: _administrator,
              loader: loader.call,
              createDraftId: () => 'manual-key',
              createProduct: (_) async => createdResult,
              setProductPrice: (_) => throw StateError('must not auto-submit'),
              submitStockIntake: (_) =>
                  throw StateError('must not auto-submit'),
            ),
          );
          loader.requests[0].complete(_snapshotWithBranches(_coffee));
          await tester.pumpAndSettle();
          await _openProductSheet(tester, 'PRD-COFFEE-001');
          final Finder action = find.byKey(
            ValueKey<String>(
              intake
                  ? 'intake-PRD-COFFEE-001'
                  : 'configure-price-PRD-COFFEE-001',
            ),
          );
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          await tester.tap(action);
          await tester.pumpAndSettle();
          await fillAndCreate(tester);
          await tester.pump();
          await tester.pump();
          expect(loader.requests, hasLength(2));
          // Let the 350 ms panel cross-fade (T9/S15) finish before leaving
          // through the header; a refresh is still pending, so a bounded
          // pump is used instead of pumpAndSettle.
          await tester.pump(const Duration(milliseconds: 400));
          final Finder close = find.byKey(const ValueKey<String>('panel-back'));
          await tester.ensureVisible(close);
          await tester.tap(close);
          await tester.pump();
          loader.requests[1].complete(both);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey<String>('pricing-listed-price')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('intake-quantity')),
            findsNothing,
          );
          expect(find.text('Producto creado correctamente'), findsOneWidget);
          expect(find.text('Reintentar misma solicitud'), findsNothing);
        },
      );
    }

    testWidgets(
      'newer creation owns its handoff and keeps distinct draft keys',
      (WidgetTester tester) async {
        final _CatalogLoader loader = _CatalogLoader();
        final List<ProductCreationDraft> drafts = <ProductCreationDraft>[];
        var keys = 0;
        const CatalogProduct newer = CatalogProduct(
          internalCode: 'PRD-NEW-0002',
          name: 'New product',
          quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
        );
        await tester.pumpWidget(
          _authenticatedApp(
            session: _administrator,
            loader: loader.call,
            createDraftId: () => 'handoff-key-${++keys}',
            createProduct: (ProductCreationDraft draft) async {
              drafts.add(draft);
              return drafts.length == 1
                  ? createdResult
                  : const ProductCreationResult(
                      productId: 'PRD-NEW-0002',
                      internalCode: 'PRD-NEW-0002',
                      replayed: false,
                    );
            },
            setProductPrice: (_) => throw StateError('must not auto-submit'),
          ),
        );
        loader.requests[0].complete(CatalogSnapshot(const <CatalogItem>[]));
        await tester.pumpAndSettle();
        await fillAndCreate(tester);
        await tester.pump();
        await tester.pump();
        await fillAndCreate(tester);
        await tester.pump();
        await tester.pump();
        expect(loader.requests, hasLength(3));
        loader.requests[1].complete(_snapshot(created));
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('pricing-listed-price')),
          findsNothing,
        );
        loader.requests[2].complete(_snapshot(newer));
        await tester.pumpAndSettle();
        expectEmptyPricingFormFor(tester, 'PRD-NEW-0002');
        expect(drafts, hasLength(2));
        expect(drafts[0].idempotencyKey, 'handoff-key-1');
        expect(drafts[1].idempotencyKey, 'handoff-key-2');
      },
    );

    testWidgets('success opens the empty pricing form without submitting', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      var pricingCalls = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1
                ? CatalogSnapshot(const <CatalogItem>[])
                : _snapshot(created);
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          setProductPrice: (_) {
            pricingCalls += 1;
            throw StateError('must not auto-submit');
          },
        ),
      );
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(loads, 2);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expectEmptyPricingFormFor(tester, 'PRD-NEW-0001');
      expect(pricingCalls, 0);
    });

    testWidgets('without a pricing gateway no pricing form opens', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1
                ? CatalogSnapshot(const <CatalogItem>[])
                : _snapshot(created);
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
        ),
      );
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
    });

    testWidgets('refresh failure keeps success and opens no pricing form', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            if (loads > 1) throw StateError('refresh failed');
            return CatalogSnapshot(const <CatalogItem>[]);
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.text('Catálogo no disponible'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
    });

    testWidgets('product missing from refreshed catalog opens no pricing', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1
                ? CatalogSnapshot(const <CatalogItem>[])
                : _snapshot(_coffee);
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
    });

    testWidgets('uncertain retry success opens the pricing form', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      var creates = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1
                ? CatalogSnapshot(const <CatalogItem>[])
                : _snapshot(created);
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async {
            creates += 1;
            if (creates == 1) throw const ProductCreationUncertainException();
            return createdResult;
          },
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );

      final Finder retry = find.widgetWithText(
        FilledButton,
        'Reintentar misma solicitud',
      );
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(creates, 2);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expectEmptyPricingFormFor(tester, 'PRD-NEW-0001');
    });

    testWidgets('a restored pricing draft keeps ownership of the form', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      const ProductPricingDraft restored = ProductPricingDraft(
        idempotencyKey: 'pricing-key-restored',
        productId: 'PRD-COFFEE-001',
        listedPriceMxn: '129.00',
        priceMode: 'iva-included',
        ivaTreatment: 'taxable',
        ivaRatePercent: '16',
      );
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1 ? _snapshot(_coffee) : both;
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          setProductPrice: (_) => throw StateError('must not call'),
          unresolvedPricingDrafts: const <ProductPricingDraft>[restored],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Coffee'), findsOneWidget);
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(loads, 2);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.text('PRD-COFFEE-001'), findsNothing);
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('PRD-NEW-0001'), findsNothing);
      expect(find.textContaining('resultado es incierto'), findsOneWidget);
    });

    testWidgets('an open pricing form for another product is not replaced', (
      WidgetTester tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: (_) async {
            loads += 1;
            return loads == 1 ? _snapshot(_coffee) : both;
          },
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          createPricingId: () => 'pricing-key-1',
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      await tester.pumpAndSettle();
      await _openSheetAndConfigurePricing(tester, 'PRD-COFFEE-001');
      await fillAndCreate(tester);
      await tester.pumpAndSettle();

      expect(loads, 2);
      expect(find.text('Producto creado correctamente'), findsOneWidget);
      expect(find.text('PRD-COFFEE-001'), findsNothing);
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('PRD-NEW-0001'), findsNothing);
    });

    testWidgets('role change during the refresh opens no pricing form', (
      WidgetTester tester,
    ) async {
      final _CatalogLoader loader = _CatalogLoader();
      Widget app(EmulatorSession session) => _authenticatedApp(
        session: session,
        loader: loader.call,
        createDraftId: () => 'draft-key-1',
        createProduct: (_) async => createdResult,
        setProductPrice: (_) => throw StateError('must not call'),
      );
      await tester.pumpWidget(app(_administrator));
      loader.requests[0].complete(CatalogSnapshot(const <CatalogItem>[]));
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pump();
      await tester.pump();
      expect(loader.requests, hasLength(2));

      await tester.pumpWidget(app(_seller));
      expect(loader.requests, hasLength(3));
      loader.requests[1].complete(_snapshot(created));
      loader.requests[2].complete(
        _snapshot(
          created,
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 0),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposal during the refresh is safe and opens nothing', (
      WidgetTester tester,
    ) async {
      final _CatalogLoader loader = _CatalogLoader();
      await tester.pumpWidget(
        _authenticatedApp(
          session: _administrator,
          loader: loader.call,
          createDraftId: () => 'draft-key-1',
          createProduct: (_) async => createdResult,
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      loader.requests[0].complete(CatalogSnapshot(const <CatalogItem>[]));
      await tester.pumpAndSettle();
      await fillAndCreate(tester);
      await tester.pump();
      await tester.pump();
      expect(loader.requests, hasLength(2));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      loader.requests[1].complete(_snapshot(created));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('seller never gets creation or the chained pricing form', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _authenticatedApp(
          session: _seller,
          loader: (_) async => _snapshot(
            created,
            holdings: const <CatalogHolding>[
              CatalogHolding(branchId: 'branch-north', quantityScaled: 0),
            ],
          ),
          createProduct: (_) => throw StateError('must not call'),
          setProductPrice: (_) => throw StateError('must not call'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Crear producto'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('pricing-listed-price')),
        findsNothing,
      );
    });
  });

  group('seller transfer notices', () {
    Map<String, Object?> leg(String transferId, String movementId) =>
        <String, Object?>{
          'branchId': 'branch-north',
          'type': 'transfer-in',
          'productId': 'PRD-COFFEE-001',
          'quantityScaled': 500,
          'unit': 'kg',
          'precision': 2,
          'transferId': transferId,
          'occurredAt': Timestamp.fromMillisecondsSinceEpoch(1767225600000),
          'actorId': 'administrator-1',
        };

    TransferNoticeController controllerFor(_FakeNoticeStreams streams) {
      final TransferNoticeController controller = TransferNoticeController(
        session: _seller,
        loadBackend: () async => TransferNoticeBackend(
          streams: streams,
          markRead: (Map<String, Object?> request) async {
            streams.requests.add(Map<String, Object?>.of(request));
            final Completer<Object?> reply = Completer<Object?>();
            streams.replies.add(reply);
            return reply.future;
          },
        ),
        sessionChecker: () async => _seller,
      );
      controller.start();
      return controller;
    }

    Future<void> flush(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    Widget appWithNotices(
      _FakeNoticeStreams streams, {
      EmulatorSession session = _seller,
    }) {
      final TransferNoticeController? controller =
          session.role == InventoryRole.seller ? controllerFor(streams) : null;
      return MaterialApp(
        home: AuthenticatedCatalogPage(
          session: session,
          catalogLoader: (_) async => _snapshot(
            _coffee,
            holdings: const <CatalogHolding>[
              CatalogHolding(
                branchId: 'branch-north',
                branchName: 'North Demo Branch',
                quantityScaled: 5000,
              ),
            ],
          ),
          transferNotices: controller == null
              ? null
              : (EmulatorSession _) => controller,
          onLogout: () async {},
        ),
      );
    }

    testWidgets(
      'seller badge shows the live unread count with a closed inbox',
      (WidgetTester tester) async {
        final _FakeNoticeStreams streams = _FakeNoticeStreams();
        await tester.pumpWidget(appWithNotices(streams));
        await flush(tester);

        // Confirmed zero: no badge label yet, but the entry exists in the
        // overflow menu (T10/S10), whose items are built at open time.
        streams.emitMovements(<CatalogDocument>[]);
        streams.emitMarkers(<CatalogDocument>[]);
        await flush(tester);
        await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey<String>('notices-open')),
          findsOneWidget,
        );
        expect(find.text('1'), findsNothing);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // A new arrival updates the badge on the menu icon live.
        streams.emitMovements(<CatalogDocument>[
          CatalogDocument(
            path: 'inventoryMovements/m1',
            data: leg('t-a', 'm1'),
          ),
        ]);
        await flush(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey<String>('shell-more')),
            matching: find.text('1'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the notices entry announces its unread state', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      await tester.pumpWidget(appWithNotices(streams));
      await flush(tester);
      // Before both streams confirm, the count is unknown, never zero.
      // The entry lives in the overflow menu (T10/S10); its items are built
      // at open time, and the badge state rides on the menu icon too.
      Future<void> openMenu() async {
        await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await openMenu();
      // A list entry merges its badge label into its own node.
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey<String>('notices-open')))
            .label,
        contains('sin confirmar'),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('notices-open')),
          matching: find.text('Avisos de traslados'),
        ),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      streams.emitMovements(<CatalogDocument>[
        CatalogDocument(path: 'inventoryMovements/m1', data: leg('t-a', 'm1')),
      ]);
      streams.emitMarkers(<CatalogDocument>[]);
      await flush(tester);
      await openMenu();
      expect(
        find.bySemanticsLabel(RegExp('Avisos de traslados: 1 sin leer')),
        findsOneWidget,
      );
      // A list entry merges its badge label into its own node.
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey<String>('notices-open')))
            .label,
        contains('1 sin leer'),
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Confirmed zero announces no unread state at all.
      streams.emitMarkers(<CatalogDocument>[streams.marker('t-a')]);
      await flush(tester);
      await openMenu();
      expect(find.bySemanticsLabel(RegExp('sin confirmar')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('1 sin leer')), findsNothing);
      semantics.dispose();
    });

    testWidgets('administrator never gets the notices entry', (
      WidgetTester tester,
    ) async {
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      await tester.pumpWidget(appWithNotices(streams, session: _administrator));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('notices-open')), findsNothing);
    });

    testWidgets('opening the inbox lists notices and acks through the seam', (
      WidgetTester tester,
    ) async {
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      await tester.pumpWidget(appWithNotices(streams));
      await flush(tester);
      streams.emitMovements(<CatalogDocument>[
        CatalogDocument(path: 'inventoryMovements/m1', data: leg('t-a', 'm1')),
      ]);
      streams.emitMarkers(<CatalogDocument>[]);
      await flush(tester);

      // The entry is the first item of the overflow menu (T10/S10).
      await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey<String>('notices-open')));
      await tester.pumpAndSettle();
      expect(find.text('Avisos de traslados'), findsOneWidget);
      expect(find.text('Coffee: +5.00 kg'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // Merely opening the inbox never marks anything read.
      expect(streams.requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey<String>('notice-read-t-a')));
      await flush(tester);
      expect(streams.requests.single, <String, Object?>{'transferId': 't-a'});
      streams.completeAck('t-a');
      await flush(tester);
      expect(find.text('Leído'), findsOneWidget);
      // The badge clears once the ack settles: no unread count on the menu
      // icon, and none on the reopened menu item.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('shell-more')),
          matching: find.text('1'),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('notices-open')),
          matching: find.text('1'),
        ),
        findsNothing,
      );
    });

    testWidgets('removing the seam disposes the notice controller', (
      WidgetTester tester,
    ) async {
      final _FakeNoticeStreams streams = _FakeNoticeStreams();
      await tester.pumpWidget(appWithNotices(streams));
      await flush(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthenticatedCatalogPage(
            session: _seller,
            catalogLoader: (_) async => _snapshot(_coffee),
            onLogout: () async {},
          ),
        ),
      );
      await flush(tester);

      expect(streams.movementsCtrl.hasListener, isFalse);
      expect(streams.markersCtrl.hasListener, isFalse);
    });
  });
}
