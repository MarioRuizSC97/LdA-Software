import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
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
  int calls = 0;

  Future<CatalogSnapshot> call(EmulatorSession session) async {
    calls += 1;
    return session.role == InventoryRole.seller
        ? sellerSaleSnapshot()
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

Future<void> _enterQuantity(
  WidgetTester tester,
  String productId,
  String quantity,
) async {
  await _tap(tester, _key('sale-add-$productId'));
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

    expect(sales.quotedCarts, hasLength(1));
    expect(sales.quotedCarts.single.toQuoteRequest(), <String, Object?>{
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

  testWidgets('invalid quantities show inline errors and never quote', (
    WidgetTester tester,
  ) async {
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
    for (final MapEntry<String, String> entry in ribbonCases.entries) {
      await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), entry.key);
      await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
    await _tap(tester, _key('sale-entry-cancel-DEMO-RIBBON'));

    await _enterQuantity(tester, 'DEMO-PIN', '1.5');
    expect(
      find.text('Este producto solo admite cantidades enteras.'),
      findsOneWidget,
    );
    expect(sales.quotedCarts, isEmpty);
    expect(find.textContaining('Carrito vacío'), findsOneWidget);
  });

  testWidgets('Agregar on a product in the cart edits that line', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();

    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _tap(tester, _key('sale-add-DEMO-PIN'));
    final TextField field = tester.widget(_key('sale-quantity-DEMO-PIN'));
    expect(field.controller!.text, '2');
    expect(find.text('Actualizar cantidad'), findsOneWidget);
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '4');
    await _tap(tester, _key('sale-entry-save-DEMO-PIN'));

    expect(sales.quotedCarts, hasLength(2));
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
    expect(sales.quotedCarts, hasLength(3));
    expect(find.text('1.00 meter'), findsOneWidget);
    expect(find.textContaining('17.50 MXN'), findsWidgets);

    await _tap(tester, _key('sale-line-remove-DEMO-RIBBON'));
    expect(sales.quotedCarts, hasLength(4));
    expect(_key('sale-line-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-DEMO-PIN'), findsOneWidget);

    await _tap(tester, _key('sale-line-remove-DEMO-PIN'));
    expect(sales.quotedCarts, hasLength(4));
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
    expect(sales.heldQuotes, hasLength(2));

    sales.heldQuotes[1].complete(sales.quoteNow(sales.quotedCarts[1]));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 productos · 32.50 MXN'), findsOneWidget);

    sales.heldQuotes[0].complete(sales.quoteNow(sales.quotedCarts[0]));
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
    sales.heldQuotes[1].complete(sales.quoteNow(sales.quotedCarts[1]));
    await tester.pumpAndSettle();
    sales.heldQuotes[0].completeError(const SaleUncertainException());
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
    expect(sales.quotedCarts, hasLength(2));
    expect(sales.quotedCarts.last.invoiceRequested, isTrue);
    expect(find.textContaining('29.00 MXN'), findsWidgets);
    expect(find.text('IVA adicional'), findsOneWidget);

    await _tap(tester, _key('sale-invoice-switch'));
    expect(sales.quotedCarts, hasLength(3));
    expect(sales.quotedCarts.last.invoiceRequested, isFalse);
  });

  testWidgets('an uncertain quote offers Reintentar; a rejected one shows '
      'the server message', (WidgetTester tester) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.quoteFailures.add(const SaleUncertainException());
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-RIBBON', '2.5');
    expect(find.textContaining('Total no disponible'), findsOneWidget);
    await _openCart(tester);
    expect(find.text('No se pudo calcular el total'), findsOneWidget);
    expect(_enabled(tester, _key('sale-charge')), isFalse);

    await _tap(tester, _key('sale-retry-quote'));
    expect(sales.quotedCarts, hasLength(2));
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

  testWidgets('a successful sale shows the folio, clears the cart and '
      'refreshes the catalog', (WidgetTester tester) async {
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
    expect(find.textContaining('Folio NTE-3F2A-9C1B'), findsOneWidget);
    expect(find.textContaining('Venta registrada'), findsOneWidget);
    expect(find.textContaining('Carrito vacío'), findsOneWidget);
    expect(loader.calls, 2);
    expect(sales.store.unresolvedFor('seller-north', 'branch-north'), isNull);
  });

  testWidgets('a payment mismatch re-quotes and asks to confirm again', (
    WidgetTester tester,
  ) async {
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
    expect(find.textContaining('5.00 MXN'), findsWidgets);

    sales.priceDelta = 50;
    await _tap(tester, _key('sale-charge'));

    expect(sales.quotedCarts, hasLength(2));
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
    expect(find.textContaining('Folio NTE-7C1D-0E2F'), findsOneWidget);
  });

  testWidgets('another rejection shows the message and unlocks the cart', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    sales.submitFailures.add(
      const SaleRejectedException(
        code: 'failed-precondition',
        message: 'insufficient stock',
      ),
    );
    await tester.pumpWidget(_page(sales));
    await tester.pumpAndSettle();
    await _enterQuantity(tester, 'DEMO-PIN', '2');
    await _openCart(tester);
    await _tap(tester, _key('sale-charge'));

    expect(
      find.text('La venta fue rechazada: insufficient stock'),
      findsOneWidget,
    );
    expect(sales.quotedCarts, hasLength(1));
    expect(_enabled(tester, _key('sale-line-remove-DEMO-PIN')), isTrue);
    expect(_key('sale-retry-submit'), findsNothing);
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
    expect(find.textContaining('Folio NTE-3F2A-9C1B'), findsOneWidget);
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
    expect(_enabled(tester, _key('sale-add-DEMO-PIN')), isFalse);
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
    expect(find.textContaining('Folio NTE-3F2A-9C1B'), findsOneWidget);
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
    sales.heldQuotes.single.complete(sales.quoteNow(sales.quotedCarts.single));
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
}
