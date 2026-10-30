import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

const _code = 'PRD-POLISH-001';
const _product = CatalogProduct(
  internalCode: _code,
  name: 'Café para pulir detalles',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);
Finder get _peek => find.byKey(const ValueKey('product-sheet-$_code'));
Finder get _card => find.byKey(const ValueKey('product-peek-card'));
Finder get _qrSurface => find.byKey(const ValueKey('product-sheet-qr-$_code'));

Future<void> _pump(
  WidgetTester tester, {
  bool admin = false,
  double textScale = 1,
  Size size = const Size(1184, 1182),
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
        ),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: EmulatorSession(
          userId: 'polish-user',
          email: 'polish@example.invalid',
          role: admin ? InventoryRole.administrator : InventoryRole.seller,
          branchId: admin ? null : 'branch-north',
        ),
        catalogLoader: (_) async => CatalogSnapshot([
          CatalogItem(
            product: _product,
            holdings: [
              CatalogHolding(
                branchId: 'branch-north',
                branchName: 'North',
                quantityScaled: 100,
              ),
            ],
          ),
        ]),
        onLogout: () async {},
        setProductPrice: admin ? (_) => throw UnimplementedError() : null,
        submitStockIntake: admin ? (_) => throw UnimplementedError() : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('product-details-$_code')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('product-details-$_code')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('seller peek is content-sized on a large window (1184x1182)', (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester);
    expect(_peek, findsOneWidget);
    expect(
      tester.getSize(_card).height,
      lessThan(1182 * .6),
      reason:
          'Short seller detail must hug its content instead of '
          'filling the capped peek height.',
    );
  });

  testWidgets('seller peek is content-sized on a phone (390x844)', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    await _open(tester);
    expect(_peek, findsOneWidget);
    expect(
      tester.getSize(_card).height,
      lessThan(844 * .75),
      reason: 'Short seller detail must hug its content on phones too.',
    );
  });

  testWidgets('name and price outrank the attribute lines', (tester) async {
    await _pump(tester);
    await _open(tester);
    final BuildContext sheetContext = tester.element(_peek.first);
    final TextTheme textTheme = Theme.of(sheetContext).textTheme;
    final Color ink = Theme.of(sheetContext).colorScheme.onSurface;

    final Text name = tester.widget<Text>(
      find.descendant(of: _peek, matching: find.text(_product.name)),
    );
    expect(name.style?.fontSize, textTheme.headlineSmall?.fontSize);

    final Text price = tester.widget<Text>(
      find.descendant(
        of: _peek,
        matching: find.textContaining('Precio de lista'),
      ),
    );
    expect(price.style?.fontSize, textTheme.titleLarge?.fontSize);
    expect(price.style?.color, ink);
    expect(name.style!.fontSize, greaterThanOrEqualTo(price.style!.fontSize!));

    final Text mode = tester.widget<Text>(
      find.descendant(
        of: _peek,
        matching: find.textContaining('Modo de precio'),
      ),
    );
    expect(price.style!.fontSize!, greaterThan(mode.style!.fontSize!));
  });

  testWidgets('QR lives on its own surface inside the peek', (tester) async {
    await _pump(tester);
    await _open(tester);
    expect(_qrSurface, findsOneWidget);
    expect(
      find.descendant(of: _qrSurface, matching: find.byType(ProductQrView)),
      findsOneWidget,
    );
  });

  testWidgets('admin peek stays capped and scrollable at 1184x1182 with '
      'text scale 2', (tester) async {
    await _pump(tester, admin: true, textScale: 2);
    await _open(tester);
    expect(_peek, findsOneWidget);
    expect(
      tester.getSize(_card).height,
      lessThanOrEqualTo(1182 * .88 + 1),
      reason: 'Tall admin detail must respect the peek height cap.',
    );
    final priceAction = find.byKey(ValueKey<String>('configure-price-$_code'));
    await tester.ensureVisible(priceAction);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(ProductQrView));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard inset keeps the peek above the keyboard without '
      'overflowing the top', (tester) async {
    await _pump(tester, size: const Size(390, 844), keyboardInset: 240);
    await _open(tester);
    final Rect bounds = tester.getRect(_card);
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.bottom, lessThanOrEqualTo(844 - 240));
    expect(tester.takeException(), isNull);
  });
}
