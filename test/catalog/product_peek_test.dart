import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr.dart';

const _code = 'PRD-PEEK-001';
const _product = CatalogProduct(
  internalCode: _code,
  name: 'Café para probar detalles',
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
Finder get _scale => find.byKey(const ValueKey('product-peek-scale'));

Future<void> _pump(
  WidgetTester tester, {
  bool admin = false,
  bool reduced = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: EmulatorSession(
          userId: 'peek-user',
          email: 'peek@example.invalid',
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
  testWidgets('long press opens peek and gives light haptic', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester);
    await tester.longPress(find.text(_product.name));
    await tester.pumpAndSettle();
    expect(_peek, findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      calls.any(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.lightImpact',
      ),
      isTrue,
    );
  });
  testWidgets('Detalles opens centered rounded width capped card', (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester);
    final card = find.byKey(const ValueKey('product-peek-card'));
    expect(_peek, findsOneWidget);
    expect(tester.getSize(card).width, lessThanOrEqualTo(560));
    expect(tester.getCenter(card).dx, closeTo(400, 1));
    expect(tester.getCenter(card).dy, closeTo(300, 1));
    expect(tester.widget<Material>(card).shape, isA<RoundedRectangleBorder>());
  });
  testWidgets('backdrop is blurred and dimmed', (tester) async {
    await _pump(tester);
    await _open(tester);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      isNot(Colors.transparent),
    );
  });
  testWidgets('peek zooms and fades over 260ms', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('product-details-$_code')));
    await tester.pump();
    final transition = tester.widget<ScaleTransition>(_scale);
    expect(transition.scale.value, closeTo(.85, .01));
    await tester.pump(const Duration(milliseconds: 130));
    expect(
      tester.widget<ScaleTransition>(_scale).scale.value,
      inExclusiveRange(.85, 1),
    );
    expect(find.byKey(const ValueKey('product-peek-fade')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.widget<ScaleTransition>(_scale).scale.value, 1);
  });
  testWidgets('reduced motion has no scale transition', (tester) async {
    await _pump(tester, reduced: true);
    await _open(tester);
    expect(_peek, findsOneWidget);
    expect(_scale, findsNothing);
  });
  for (final method in ['outside', 'close', 'back', 'swipe']) {
    testWidgets('$method dismisses peek', (tester) async {
      await _pump(tester);
      await _open(tester);
      switch (method) {
        case 'outside':
          await tester.tapAt(const Offset(5, 5));
        case 'close':
          await tester.tap(find.byKey(const ValueKey('product-sheet-close')));
        case 'back':
          await tester.binding.handlePopRoute();
        case 'swipe':
          await tester.drag(
            find.byKey(const ValueKey('product-peek-handle')),
            const Offset(0, 150),
          );
      }
      await tester.pumpAndSettle();
      expect(_peek, findsNothing);
    });
  }
  testWidgets('downward swipe on content at the top dismisses', (tester) async {
    await _pump(tester);
    await _open(tester);
    await tester.drag(
      find.text('Modo de precio: IVA incluido'),
      const Offset(0, 150),
    );
    await tester.pumpAndSettle();
    expect(_peek, findsNothing);
  });
  testWidgets('scrolling back through details does not dismiss', (
    tester,
  ) async {
    await _pump(tester, admin: true, textScale: 2);
    await _open(tester);
    final scrollable = find.descendant(
      of: _peek,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable.first);
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ProductQrView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(_peek, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final admin in [false, true]) {
    testWidgets(
      '${admin ? 'administrator' : 'seller'} fields stay role scoped',
      (tester) async {
        await _pump(tester, admin: admin);
        await _open(tester);
        expect(find.text('Modo de precio: IVA incluido'), findsOneWidget);
        expect(find.byType(ProductQrView), findsOneWidget);
        for (final text in ['Unidad:', 'Tratamiento de IVA:', 'Tasa de IVA:']) {
          expect(
            find.textContaining(text),
            admin ? findsOneWidget : findsNothing,
          );
        }
        expect(find.text(_code), admin ? findsOneWidget : findsNothing);
        expect(
          find.byKey(const ValueKey('intake-$_code')),
          admin ? findsOneWidget : findsNothing,
        );
      },
    );
  }
  testWidgets('admin price action closes peek then opens price flow', (
    tester,
  ) async {
    await _pump(tester, admin: true);
    await _open(tester);
    final action = find.byKey(const ValueKey('configure-price-$_code'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(_peek, findsNothing);
    expect(find.byKey(const ValueKey('pricing-listed-price')), findsOneWidget);
  });
  testWidgets('360px at text scale 2 scrolls without overflow for both roles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final admin in [false, true]) {
      await _pump(tester, admin: admin, textScale: 2);
      await _open(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(ProductQrView));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
  });
}
