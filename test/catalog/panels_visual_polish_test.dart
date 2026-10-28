import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_sale_detail.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';
import 'package:lda_inventory/transfers/transfer_notices_view.dart';

import '../corrections/correction_fixtures.dart';
import '../movements/movement_fixtures.dart';

Future<void> pumpPanel(WidgetTester tester, Widget panel) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: panel)));
  await tester.pumpAndSettle();
}

void expectTonal(WidgetTester tester, String text) {
  final finder = find.widgetWithText(FilledButton, text);
  expect(finder, findsOneWidget);
  final button = tester.widget<FilledButton>(finder);
  final context = tester.element(finder);
  expect(
    button.defaultStyleOf(context).backgroundColor!.resolve({}),
    Theme.of(context).colorScheme.secondaryContainer,
  );
}

TextStyle styleOf(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return DefaultTextStyle.of(tester.element(finder)).style.merge(text.style);
}

void main() {
  testWidgets('Crear producto keeps header exit, submit remains primary', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedCatalogPage(
          session: movementsAdministrator,
          catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
          onLogout: () async {},
          createProduct: (_) async => const ProductCreationResult(
            productId: 'PRD-TEST',
            internalCode: 'PRD-TEST',
            replayed: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('panel-back')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Crear'), findsOneWidget);
  });

  testWidgets(
    'Correcciones return actions are tonal and totals are emphasized',
    (tester) async {
      final sale = lookupSale();
      await pumpPanel(
        tester,
        CorrectionLookupView(
          corrections: SaleCorrections(
            branchId: 'branch-north',
            find: (_) async => sale,
            listRecent: () async => RecentCorrectableSales.fromCallable({
              'sales': [lookupSaleJson()],
            }, query: RecentSalesQuery()),
            previewReturn: (_) async => throw UnimplementedError(),
            submitReturn: (_) async => throw UnimplementedError(),
            previewExchange: (_) async => throw UnimplementedError(),
            submitReplacement: (_) async => throw UnimplementedError(),
            submitExchange: (_) async => throw UnimplementedError(),
            unresolvedDraft: () => null,
            unacknowledged: () => null,
            acknowledge: (_) {},
          ),
          productNames: const {},
        ),
      );
      final tile = find.byType(ListTile);
      final total = tester.widget<ListTile>(tile).trailing! as Text;
      expect(
        total.style?.fontSize,
        Theme.of(tester.element(tile)).textTheme.titleLarge!.fontSize,
      );
      expect(total.style?.fontWeight, FontWeight.w700);
      expect(find.text('Volver al catálogo'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Buscar'), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expectTonal(tester, 'Volver a la búsqueda');
    },
  );

  testWidgets('Correcciones remaining quantity outranks sold and returned', (
    tester,
  ) async {
    // Open the same public detail used by the lookup panel.
    await pumpPanel(
      tester,
      CorrectionSaleDetail(
        sale: lookupSale(),
        productNames: const {},
        onBack: () {},
      ),
    );
    final remaining = styleOf(tester, find.textContaining('Restante:').first);
    for (final label in ['Vendido:', 'Devuelto:']) {
      final secondary = styleOf(tester, find.textContaining(label).first);
      expect(remaining.fontSize!, greaterThan(secondary.fontSize!));
      expect(
        remaining.fontWeight!.value,
        greaterThan(secondary.fontWeight!.value),
      );
      expect(remaining.color, isNot(secondary.color));
    }
  });

  for (final width in [400.0, 1200.0]) {
    testWidgets('Avisos bounds and empty hierarchy at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpPanel(
        tester,
        TransferNoticesView(
          state: const TransferNoticeState(phase: TransferNoticePhase.ready),
          productNames: const {},
          onMarkRead: (_) {},
        ),
      );
      final divider = find.byType(Divider);
      final rect = tester.getRect(divider);
      expect(rect.width, lessThanOrEqualTo(600));
      expect(rect.width, width < 600 ? width : greaterThanOrEqualTo(560));
      if (width < 600) {
        expect(rect.center.dx, closeTo(width / 2, 1));
      } else {
        // T15/D1: from the breakpoint up the primary column shares the screen
        // with the context rail, so the GROUP is centred and the primary
        // intentionally sits left of the viewport centre.
        final rail = tester.getRect(
          find.byKey(const Key('notices-context')),
        );
        expect(rail.left, greaterThan(rect.right));
        expect(rect.left, closeTo(width - rail.right, 2));
      }
      final headline = styleOf(tester, find.text('Sin avisos de traslados'));
      final explanation = styleOf(
        tester,
        find.text('Cuando te envíen un traslado, aparecerá aquí.'),
      );
      expect(headline.fontSize!, greaterThan(explanation.fontSize!));
      expect(
        headline.fontWeight!.value,
        greaterThan(explanation.fontWeight!.value),
      );
      expect(headline.color, isNot(explanation.color));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Movimientos secondary actions are tonal', (tester) async {
    await pumpPanel(
      tester,
      MovementsView(
        movements: AdministratorMovements(
          load: (_) async => [
            parseMovementEntry(
              CatalogDocument(
                path: 'inventoryMovements/m-1',
                data: movementData(),
              ),
            ),
          ],
          readProfile: (_) async => const SellerNamed('Ana'),
          setSellerName: (uid, _) async =>
              SellerProfileResult(uid: uid, replayed: false),
        ),
        productNames: const {'PRD-COFFEE-001': 'Café'},
        branchChoices: const [],
      ),
    );
    expect(find.text('Volver'), findsNothing);
    for (final label in ['Actualizar', 'Editar nombre']) {
      expectTonal(tester, label);
    }
  });

  testWidgets('Movimientos quantity has emphasis within its line', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      MovementsView(
        movements: AdministratorMovements(
          load: (_) async => [
            parseMovementEntry(
              CatalogDocument(
                path: 'inventoryMovements/m-1',
                data: movementData(),
              ),
            ),
          ],
          readProfile: (_) async => const SellerNamed('Ana'),
          setSellerName: (uid, _) async =>
              SellerProfileResult(uid: uid, replayed: false),
        ),
        productNames: const {'PRD-COFFEE-001': 'Café'},
        branchChoices: const [],
      ),
    );
    final line = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.data ?? widget.textSpan?.toPlainText()) == 'Café · -2.50 kg',
    );
    final text = tester.widget<Text>(line);
    expect(text.textSpan, isNotNull);
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    final quantity = spans.last.style!;
    final base = styleOf(tester, line);
    expect(quantity.fontWeight!.value, greaterThan(base.fontWeight!.value));
    expect(quantity.fontSize!, greaterThan(base.fontSize!));
  });

  testWidgets(
    'Traslados lines are bordered radius-12 cards and actions tonal',
    (tester) async {
      await pumpPanel(
        tester,
        AdministratorTransferForm(
          ownerUserId: 'admin',
          branches: const [],
          products: const [],
          submitTransfer: (_) async => throw UnimplementedError(),
          unresolvedDraft: () => null,
          onClose: () {},
          onCompleted: (_) {},
        ),
      );
      final product = find.byKey(const ValueKey<String>('transfer-product-1'));
      expect(product, findsOneWidget);
      final containers = tester.widgetList<Container>(
        find.ancestor(of: product, matching: find.byType(Container)),
      );
      expect(
        containers.any((container) {
          final decoration = container.decoration;
          return decoration is BoxDecoration &&
              decoration.borderRadius == BorderRadius.circular(12) &&
              decoration.border ==
                  Border.all(
                    color: Theme.of(tester.element(product))
                        .colorScheme
                        .outlineVariant,
                  );
        }),
        isTrue,
      );
      expectTonal(tester, 'Agregar producto');
      expectTonal(tester, 'Cerrar');
      expect(
        find.widgetWithText(FilledButton, 'Registrar traslado'),
        findsOneWidget,
      );
    },
  );
}
