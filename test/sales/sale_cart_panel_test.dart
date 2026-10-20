import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';

import 'sale_ui_fixtures.dart';

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

class _Loader {
  _Loader({this.snapshot});

  final CatalogSnapshot? snapshot;
  int calls = 0;

  Future<CatalogSnapshot> call(EmulatorSession session) async {
    calls += 1;
    return session.role == InventoryRole.seller
        ? snapshot ?? sellerSaleSnapshot()
        : CatalogSnapshot(const <CatalogItem>[]);
  }
}

Widget _page(
  FakeSaleCheckout sales, {
  EmulatorSession session = _seller,
  _Loader? loader,
  List<SaleReceipt>? completed,
}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: session,
    catalogLoader: (loader ?? _Loader()).call,
    onLogout: () async {},
    saleCheckout: sales.checkout,
    onSaleCompleted: completed?.add,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Agregar saves one unit; other quantities are typed through the stepper.
Future<void> _enterQuantity(
  WidgetTester tester,
  String productId,
  String quantity,
) async {
  await _tap(tester, _key('sale-add-$productId'));
  if (quantity == '1') return;
  await _tap(tester, _key('sale-line-edit-$productId'));
  await tester.enterText(_key('sale-quantity-$productId'), quantity);
  await _tap(tester, _key('sale-entry-save-$productId'));
}

Future<void> _openCart(WidgetTester tester) =>
    _tap(tester, _key('sale-cart-button'));

bool _enabled(WidgetTester tester, Finder finder) {
  final Widget widget = tester.widget(finder);
  return switch (widget) {
    ButtonStyleButton button => button.onPressed != null,
    IconButton button => button.onPressed != null,
    SwitchListTile tile => tile.onChanged != null,
    ChoiceChip chip => chip.onSelected != null,
    _ => throw StateError('unsupported ${widget.runtimeType}'),
  };
}

void main() {
  testWidgets('seller sees Agregar on each card and an empty cart button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(FakeSaleCheckout()));
    await tester.pumpAndSettle();

    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-add-DEMO-PIN'), findsOneWidget);
    expect(find.text('Agregar'), findsNWidgets(2));
    expect(_key('sale-cart-button'), findsOneWidget);
    expect(find.textContaining('Carrito vacío'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Agregar Ribbon al carrito')),
      findsOneWidget,
    );
  });

  testWidgets('Agregar adds one unit and shows the stepper without an entry', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _tap(tester, _key('sale-add-DEMO-RIBBON'));

    expect(sales.quotedCarts.single.lines.single.quantity, '1');
    expect(_key('sale-quantity-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-add-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-remove-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-line-increment-DEMO-RIBBON'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('sale-line-edit-DEMO-RIBBON'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Agregar with less than one loaded unit is disabled and '
      'leaves the cart empty', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()
      ..unavailable = <String>{'DEMO-RIBBON'};
    final _Loader loader = _Loader(
      snapshot: CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: ribbonProduct,
          holdings: <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 50),
          ],
        ),
      ]),
    );
    await tester.pumpWidget(_page(sales, loader: loader));
    await tester.pumpAndSettle();

    // S14 supersedes T13's acceptance of one unit above loaded stock.
    expect(_enabled(tester, _key('sale-add-DEMO-RIBBON')), isFalse);
    expect(find.text('Agotado'), findsWidgets);
    expect(sales.quotedCarts, isEmpty);
    expect(_key('sale-quantity-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsNothing);
    await _openCart(tester);
    expect(find.textContaining('El carrito está vacío.'), findsOneWidget);
    expect(_enabled(tester, _key('sale-charge')), isFalse);
    expect(sales.submittedDrafts, isEmpty);
  });

  testWidgets('an administrator never sees the cart even with a checkout', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(FakeSaleCheckout(), session: _administrator));
    await tester.pumpAndSettle();

    expect(find.text('Agregar'), findsNothing);
    expect(_key('sale-cart-button'), findsNothing);
  });

  testWidgets('adding a line quotes the cart and shows the total', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');

    expect(sales.quotedCarts, hasLength(2));
    expect(sales.quotedCarts.first.lines.single.quantity, '1');
    expect(sales.quotedCarts.last.toQuoteRequest(), <String, Object?>{
      'invoiceRequested': false,
      'lines': <Object?>[
        <String, Object?>{'productId': 'DEMO-RIBBON', 'quantity': '2.5'},
      ],
    });
    expect(find.textContaining('1 producto · 25.00 MXN'), findsOneWidget);

    await _openCart(tester);
    expect(_key('sale-line-DEMO-RIBBON'), findsOneWidget);
    expect(find.text('Ribbon'), findsOneWidget);
    expect(find.text('2.50 meter'), findsOneWidget);
    expect(find.text('25.00 MXN'), findsWidgets);
    expect(_enabled(tester, _key('sale-charge')), isTrue);
  });

  testWidgets(
    'invalid typed edits show inline errors without changing one-unit lines',
    (WidgetTester tester) async {
      final FakeSaleCheckout sales = FakeSaleCheckout();
      await tester.pumpWidget(_page(sales));
      await tester.pumpAndSettle();

      final Map<String, String> ribbonCases = <String, String>{
        '': 'Escribe una cantidad.',
        '0': 'La cantidad debe ser mayor que cero.',
        '1.234': 'Usa como máximo 2 decimales.',
        'abc': 'Escribe una cantidad válida, por ejemplo 2 o 1.5.',
        '-1': 'Escribe una cantidad válida, por ejemplo 2 o 1.5.',
        '99999999999999999': 'La cantidad es demasiado grande.',
      };
      await _tap(tester, _key('sale-add-DEMO-RIBBON'));
      await _tap(tester, _key('sale-line-edit-DEMO-RIBBON'));
      for (final MapEntry<String, String> entry in ribbonCases.entries) {
        await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), entry.key);
        await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
        expect(sales.quotedCarts, hasLength(1));
        expect(sales.quotedCarts.single.lines.single.quantity, '1');
      }
      await _tap(tester, _key('sale-entry-cancel-DEMO-RIBBON'));

      await _enterQuantity(tester, 'DEMO-PIN', '1.5');
      expect(
        find.text('Este producto solo admite cantidades enteras.'),
        findsOneWidget,
      );
      expect(sales.quotedCarts, hasLength(2));
      expect(
        sales.quotedCarts.last.lines.map((line) => line.quantity),
        <String>['1', '1'],
      );
      await _tap(tester, _key('sale-entry-cancel-DEMO-PIN'));
      await _openCart(tester);
      expect(find.text('1.00 meter'), findsOneWidget);
      expect(find.text('1 piece'), findsOneWidget);
    },
  );

  testWidgets('the quantity on a product in the cart edits that line', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _enterQuantity(tester, 'DEMO-PIN', '2');
    // T11/S11: once the product is in the cart the card shows the stepper
    // instead of a second 'Agregar'; the typed edit is reached from the
    // stepper's quantity control, which pre-fills the current quantity.
    await _tap(tester, _key('sale-line-edit-DEMO-PIN'));
    final TextField field = tester.widget(_key('sale-quantity-DEMO-PIN'));
    expect(field.controller!.text, '2');
    expect(find.text('Actualizar cantidad'), findsOneWidget);
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '4');
    await _tap(tester, _key('sale-entry-save-DEMO-PIN'));

    expect(sales.quotedCarts, hasLength(3));
    expect(sales.quotedCarts.last.lineCount, 1);
    expect(sales.quotedCarts.last.lines.single.quantity, '4');
    expect(find.textContaining('1 producto · 10.00 MXN'), findsOneWidget);
  });

  testWidgets('the panel edits and removes lines, re-quoting each time', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _enterQuantity(tester, 'DEMO-PIN', '3');
    expect(find.textContaining('2 productos · 32.50 MXN'), findsOneWidget);

    await _openCart(tester);
    await _tap(tester, _key('sale-line-edit-DEMO-RIBBON'));
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '1');
    await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
    expect(sales.quotedCarts, hasLength(5));
    expect(find.text('1.00 meter'), findsOneWidget);
    expect(find.textContaining('17.50 MXN'), findsWidgets);

    await _tap(tester, _key('sale-line-remove-DEMO-RIBBON'));
    expect(sales.quotedCarts, hasLength(6));
    expect(_key('sale-line-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-DEMO-PIN'), findsOneWidget);

    await _tap(tester, _key('sale-line-remove-DEMO-PIN'));
    expect(sales.quotedCarts, hasLength(6));
    expect(
      find.text('El carrito está vacío. Agrega productos desde el catálogo.'),
      findsOneWidget,
    );
    expect(_enabled(tester, _key('sale-charge')), isFalse);
  });

  testWidgets('a stale quote result is ignored', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()..holdQuotes = true;
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    expect(find.textContaining('Calculando…'), findsOneWidget);
    await _enterQuantity(tester, 'DEMO-PIN', '3');
    expect(sales.heldQuotes, hasLength(4));

    sales.heldQuotes[3].complete(sales.quoteNow(sales.quotedCarts[3]));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 productos · 32.50 MXN'), findsOneWidget);

    // The typed 2.5 quote is stale too, not just the initial one-unit quote.
    sales.heldQuotes[1].complete(sales.quoteNow(sales.quotedCarts[1]));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 productos · 32.50 MXN'), findsOneWidget);
    expect(find.textContaining('25.00 MXN'), findsNothing);
  });

  testWidgets('a stale quote failure is ignored', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()..holdQuotes = true;
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _enterQuantity(tester, 'DEMO-PIN', '3');
    sales.heldQuotes[3].complete(sales.quoteNow(sales.quotedCarts[3]));
    await tester.pumpAndSettle();
    sales.heldQuotes[1].completeError(const SaleUncertainException());
    await tester.pumpAndSettle();

    expect(find.textContaining('2 productos · 32.50 MXN'), findsOneWidget);
    expect(find.textContaining('Total no disponible'), findsNothing);
  });

  testWidgets('an unavailable line is flagged and blocks Cobrar', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()
      ..unavailable = <String>{'DEMO-PIN'};
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _enterQuantity(tester, 'DEMO-PIN', '3');
    await _openCart(tester);

    expect(
      find.descendant(
        of: _key('sale-line-DEMO-PIN'),
        matching: find.text('Sin existencias suficientes'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('sale-line-DEMO-RIBBON'),
        matching: find.text('Sin existencias suficientes'),
      ),
      findsNothing,
    );
    expect(_enabled(tester, _key('sale-charge')), isFalse);

    sales.unavailable = <String>{};
    await _tap(tester, _key('sale-line-remove-DEMO-PIN'));
    expect(_enabled(tester, _key('sale-charge')), isTrue);
  });

  testWidgets('toggling the invoice re-quotes with the new option', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _openCart(tester);
    expect(find.textContaining('25.00 MXN'), findsWidgets);

    await _tap(tester, _key('sale-invoice-switch'));
    expect(sales.quotedCarts, hasLength(3));
    expect(sales.quotedCarts.last.invoiceRequested, isTrue);
    expect(find.textContaining('29.00 MXN'), findsWidgets);
    expect(find.text('IVA adicional'), findsOneWidget);

    await _tap(tester, _key('sale-invoice-switch'));
    expect(sales.quotedCarts, hasLength(4));
    expect(sales.quotedCarts.last.invoiceRequested, isFalse);
  });

  testWidgets('an uncertain quote offers Reintentar; a rejected one shows '
      'the server message', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '1');
    sales.quoteFailures.add(const SaleUncertainException());
    await _tap(tester, _key('sale-line-edit-DEMO-RIBBON'));
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '2.5');
    await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
    expect(find.textContaining('Total no disponible'), findsOneWidget);
    await _openCart(tester);
    expect(find.text('No se pudo calcular el total'), findsOneWidget);
    expect(_enabled(tester, _key('sale-charge')), isFalse);

    await _tap(tester, _key('sale-retry-quote'));
    expect(sales.quotedCarts, hasLength(3));
    expect(_enabled(tester, _key('sale-charge')), isTrue);

    sales.quoteFailures.add(
      const SaleRejectedException(
        code: 'failed-precondition',
        message: 'product has no price',
      ),
    );
    await _tap(tester, _key('sale-invoice-switch'));
    expect(find.textContaining('product has no price'), findsOneWidget);
    expect(_enabled(tester, _key('sale-charge')), isFalse);
  });

  testWidgets('a successful sale shows the receipt, clears the cart and '
      'refreshes the catalog; Nueva venta returns to the catalog', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final _Loader loader = _Loader();
    final List<SaleReceipt> completed = <SaleReceipt>[];
    await tester.pumpWidget(_page(sales, loader: loader, completed: completed));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _enterQuantity(tester, 'DEMO-PIN', '3');
    await _openCart(tester);
    await _tap(tester, _key('sale-invoice-switch'));
    await _tap(tester, _key('sale-payment-card'));
    expect(loader.calls, 1);

    await _tap(tester, _key('sale-charge'));

    final SaleDraft draft = sales.submittedDrafts.single;
    expect(draft.idempotencyKey, firstSaleKey);
    expect(draft.paymentMethod, SalePaymentMethod.card);
    expect(draft.amountCentavos, 3650);
    expect(draft.cart.invoiceRequested, isTrue);
    expect(completed.single.folio, 'NTE-3F2A-9C1B');
    expect(find.text('Venta registrada'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      'NTE-3F2A-9C1B',
    );
    expect(find.text('36.50 MXN'), findsOneWidget);
    expect(find.text('Tarjeta'), findsOneWidget);
    expect(find.text('Con factura'), findsOneWidget);
    expect(_key('sale-cart-button'), findsNothing);
    expect(_key('sale-add-DEMO-RIBBON'), findsNothing);
    expect(loader.calls, 2);
    expect(sales.store.unresolvedFor('seller-north', 'branch-north'), isNull);

    await _tap(tester, _key('sale-receipt-new'));
    expect(_key('sale-receipt-folio'), findsNothing);
    expect(find.textContaining('Carrito vacío'), findsOneWidget);
    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
    expect(completed, hasLength(1));
  });

  testWidgets('a payment mismatch re-quotes and asks to confirm again', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(paymentMismatchRejection);
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    expect(find.textContaining('5.00 MXN'), findsWidgets);

    sales.priceDelta = 50;
    await _tap(tester, _key('sale-charge'));

    expect(sales.quotedCarts, hasLength(3));
    expect(
      find.text('El total cambió. Revisa el nuevo total y vuelve a cobrar.'),
      findsOneWidget,
    );
    expect(find.textContaining('6.00 MXN'), findsWidgets);
    expect(_enabled(tester, _key('sale-charge')), isTrue);

    await _tap(tester, _key('sale-charge'));
    expect(sales.submittedDrafts, hasLength(2));
    expect(sales.submittedDrafts.last.idempotencyKey, secondSaleKey);
    expect(sales.submittedDrafts.last.amountCentavos, 600);
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      'NTE-7C1D-0E2F',
    );
  });

  testWidgets('insufficient stock re-quotes and flags the unavailable line', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(insufficientStockRejection);
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    sales.unavailable = <String>{'DEMO-PIN'};
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text('No hay existencias suficientes para completar la venta.'),
      findsOneWidget,
    );
    expect(sales.quotedCarts, hasLength(3));
    expect(find.text('Sin existencias suficientes'), findsOneWidget);
    expect(_enabled(tester, _key('sale-charge')), isFalse);
    expect(_enabled(tester, _key('sale-line-remove-DEMO-PIN')), isTrue);
    expect(_key('sale-retry-submit'), findsNothing);
  });

  testWidgets('any other rejection re-quotes, so a stale quote never keeps '
      'Cobrar enabled', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(
      const SaleRejectedException(
        code: 'not-found',
        message: 'product does not exist',
      ),
    );
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    sales.holdQuotes = true;
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text('La venta fue rechazada: product does not exist'),
      findsOneWidget,
    );
    expect(sales.quotedCarts, hasLength(3));
    expect(_enabled(tester, _key('sale-charge')), isFalse);
    expect(_enabled(tester, _key('sale-line-remove-DEMO-PIN')), isTrue);

    sales.heldQuotes.single.complete(sales.quoteNow(sales.quotedCarts.last));
    await tester.pumpAndSettle();
    expect(_enabled(tester, _key('sale-charge')), isTrue);
    expect(
      find.text('La venta fue rechazada: product does not exist'),
      findsOneWidget,
    );
  });

  testWidgets('the English mismatch text without a reason is a plain '
      'rejection', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(
      const SaleRejectedException(
        code: 'invalid-argument',
        message: paymentMismatchMessage,
      ),
    );
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text('El total cambió. Revisa el nuevo total y vuelve a cobrar.'),
      findsNothing,
    );
    expect(
      find.text('La venta fue rechazada: $paymentMismatchMessage'),
      findsOneWidget,
    );
    expect(sales.quotedCarts, hasLength(3));
  });

  testWidgets('an uncertain sale locks the cart and retries the same key', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(const SaleUncertainException());
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text(
        'No sabemos si la venta se registró. Reintenta la misma venta antes '
        'de editar.',
      ),
      findsOneWidget,
    );
    expect(_enabled(tester, _key('sale-charge')), isFalse);
    expect(_enabled(tester, _key('sale-line-remove-DEMO-PIN')), isFalse);
    expect(_enabled(tester, _key('sale-line-edit-DEMO-PIN')), isFalse);
    expect(_enabled(tester, _key('sale-invoice-switch')), isFalse);
    expect(_enabled(tester, _key('sale-payment-card')), isFalse);
    expect(_enabled(tester, _key('sale-retry-submit')), isTrue);

    await _tap(tester, _key('sale-close-cart'));
    expect(_enabled(tester, _key('sale-add-DEMO-RIBBON')), isFalse);
    await _openCart(tester);

    await _tap(tester, _key('sale-retry-submit'));
    expect(sales.submittedDrafts, hasLength(2));
    expect(sales.submittedDrafts[1], same(sales.submittedDrafts[0]));
    expect(sales.submittedDrafts[1].idempotencyKey, firstSaleKey);
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      'NTE-3F2A-9C1B',
    );
  });

  testWidgets('an unresolved stored draft restores the locked cart', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final SaleCart cart = SaleCart.empty().add(
      SaleCartLine(
        productId: 'DEMO-PIN',
        name: 'Pin',
        quantitySpec: pinProduct.quantitySpec,
        quantity: '2',
      ),
    );
    final SaleDraft draft = SaleDraft.fromQuote(
      quote: SaleQuote.fromCallable(quoteFor(cart), cart: cart),
      branchId: 'branch-north',
      paymentMethod: SalePaymentMethod.transfer,
      createKey: () => firstSaleKey,
    );
    sales.store.begin(ownerUserId: 'seller-north', draft: draft);

    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 producto · 5.00 MXN'), findsOneWidget);
    // T11/S11: the in-cart product shows the (locked) stepper, not 'Agregar'.
    expect(_key('sale-add-DEMO-PIN'), findsNothing);
    expect(_enabled(tester, _key('sale-line-increment-DEMO-PIN')), isFalse);
    await _openCart(tester);
    expect(_key('sale-retry-submit'), findsOneWidget);

    await _tap(tester, _key('sale-retry-submit'));
    expect(sales.submittedDrafts.single, same(draft));
    expect(sales.quotedCarts, isEmpty);
  });

  testWidgets('pending submission disables every cart action', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()
      ..holdSubmit = Completer<void>();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);

    await tester.ensureVisible(_key('sale-charge'));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-charge'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (final String key in <String>[
      'sale-charge',
      'sale-line-edit-DEMO-PIN',
      'sale-line-remove-DEMO-PIN',
      'sale-invoice-switch',
      'sale-payment-cash',
      'sale-close-cart',
    ]) {
      expect(_enabled(tester, _key(key)), isFalse, reason: key);
    }

    sales.holdSubmit!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      'NTE-3F2A-9C1B',
    );
  });

  testWidgets('a pending quote disables Cobrar and shows Calculando…', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()..holdQuotes = true;
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);

    expect(find.textContaining('Calculando…'), findsWidgets);
    expect(_enabled(tester, _key('sale-charge')), isFalse);
    expect(sales.heldQuotes, hasLength(2));
    sales.heldQuotes.last.complete(sales.quoteNow(sales.quotedCarts.last));
    await tester.pumpAndSettle();
    expect(_enabled(tester, _key('sale-charge')), isTrue);
  });

  testWidgets('a session error without a stored draft asks to sign in', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(const SaleSessionException());
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text(
        'Tu sesión ya no permite registrar ventas. Vuelve a iniciar sesión.',
      ),
      findsOneWidget,
    );
    expect(_key('sale-retry-submit'), findsNothing);
  });

  testWidgets('the cart works on a narrow screen', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _openCart(tester);
    await _tap(tester, _key('sale-payment-transfer'));
    await _tap(tester, _key('sale-charge'));

    expect(tester.takeException(), isNull);
    expect(
      sales.submittedDrafts.single.paymentMethod,
      SalePaymentMethod.transfer,
    );
  });

  group('unacknowledged receipts', () {
    // Commits a sale through the checkout, outside this page's cart, as a
    // sale whose cart was disposed before its outcome landed.
    Future<SaleReceipt> commitElsewhere(FakeSaleCheckout sales) {
      final SaleCart cart = SaleCart.empty().add(
        SaleCartLine(
          productId: ribbonProduct.internalCode,
          name: ribbonProduct.name,
          quantitySpec: ribbonProduct.quantitySpec,
          quantity: '1',
        ),
      );
      return sales.checkout.submit(
        SaleDraft.fromQuote(
          quote: sales.quoteNow(cart),
          branchId: sales.branchId,
          paymentMethod: SalePaymentMethod.cash,
          createKey: () => secondSaleKey,
        ),
      );
    }

    testWidgets('a held receipt is flagged pending apart from the message', (
      WidgetTester tester,
    ) async {
      final FakeSaleCheckout sales = FakeSaleCheckout();
      final SaleReceipt held = await commitElsewhere(sales);
      final SaleCartController controller = SaleCartController(
        checkout: sales.checkout,
      );
      addTearDown(controller.dispose);
      expect(controller.lastReceipt, same(held));
      expect(controller.receiptPending, isTrue);
      expect(controller.message, isNull);
      expect(controller.reconcileOnOpen(), isTrue);

      controller.dismissReceipt();
      expect(controller.lastReceipt, isNull);
      expect(controller.receiptPending, isFalse);
      expect(controller.reconcileOnOpen(), isFalse);

      // A sale charged from this cart shows its own receipt, not as pending.
      controller.saveEntry(
        productId: pinProduct.internalCode,
        name: pinProduct.name,
        quantitySpec: pinProduct.quantitySpec,
        quantity: '1',
      );
      await tester.pump();
      await controller.charge();
      expect(controller.lastReceipt, isNotNull);
      expect(controller.receiptPending, isFalse);
      expect(controller.cart.isEmpty, isTrue);
    });

    testWidgets('the page shows a held receipt first until "Nueva venta"', (
      WidgetTester tester,
    ) async {
      final FakeSaleCheckout sales = FakeSaleCheckout();
      final SaleReceipt receipt = await commitElsewhere(sales);
      await tester.pumpWidget(_page(sales));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(_key('sale-receipt-folio')).data,
        receipt.folio,
      );
      expect(
        tester.widget<Text>(_key('sale-receipt-notice')).data,
        salePendingReceiptMessage,
      );
      expect(_key('sale-cart-button'), findsNothing);
      expect(
        sales.store.completedFor('seller-north', 'branch-north'),
        same(receipt),
      );

      await _tap(tester, _key('sale-receipt-new'));
      expect(_key('sale-receipt-folio'), findsNothing);
      expect(sales.store.completedFor('seller-north', 'branch-north'), isNull);
      expect(find.textContaining('Carrito vacío'), findsOneWidget);
    });

    testWidgets('opening the cart or charging shows a receipt that landed '
        'meanwhile instead of selling again', (WidgetTester tester) async {
      final FakeSaleCheckout sales = FakeSaleCheckout(
        keys: const <String>[firstSaleKey],
      );
      await tester.pumpWidget(_page(sales));
      await tester.pumpAndSettle();
      await _enterQuantity(tester, 'DEMO-PIN', '1');
      await _openCart(tester);

      // Charging is refused: the receipt shows with the pending message.
      final SaleReceipt receipt = await commitElsewhere(sales);
      await _tap(tester, _key('sale-charge'));
      expect(sales.submittedDrafts, hasLength(1));
      expect(
        tester.widget<Text>(_key('sale-receipt-folio')).data,
        receipt.folio,
      );
      expect(
        tester.widget<Text>(_key('sale-receipt-notice')).data,
        salePendingReceiptMessage,
      );
      await _tap(tester, _key('sale-receipt-new'));
      expect(sales.store.completedFor('seller-north', 'branch-north'), isNull);

      // Opening the cart also shows one first.
      final SaleReceipt again = await commitElsewhere(sales);
      await _openCart(tester);
      expect(tester.widget<Text>(_key('sale-receipt-folio')).data, again.folio);
      expect(_key('sale-charge'), findsNothing);
    });
  });

  testWidgets('the open cart meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_page(FakeSaleCheckout()));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    await _openCart(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
