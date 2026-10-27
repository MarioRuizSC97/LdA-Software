import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

import '../support/viewport.dart';

const _products = [CatalogProduct(internalCode: 'PRD-COFFEE-001', name: 'Café', quantitySpec: QuantitySpec(unit: 'kg', precision: 2)), CatalogProduct(internalCode: 'DEMO-RIBBON-01', name: 'Cinta', quantitySpec: QuantitySpec(unit: 'piece', precision: 0))];
const _branches = [CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'), CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur')];
Finder _key(String key) => find.byKey(ValueKey(key));
Future<void> _tap(WidgetTester tester, Finder target) async { await tester.ensureVisible(target); await tester.tap(target); await tester.pumpAndSettle(); }
Future<void> _pick(WidgetTester tester, Finder target, String label) async { await _tap(tester, target); await _tap(tester, find.text(label).last); }
Future<void> _line(WidgetTester tester, int index, String label, String quantity) async {
  final products = find.byWidgetPredicate((w) => w is DropdownButtonFormField<String> && w.key.toString().contains('transfer-product-'));
  await _pick(tester, products.at(index), label);
  final field = find.byType(TextFormField).at(index);
  await tester.ensureVisible(field);
  await tester.enterText(field, quantity);
  await tester.pump();
}
Widget _app({required Brightness brightness, required TransferSubmit submit, String owner = 'admin-a', VoidCallback? close, List<CatalogProduct> products = _products}) => MaterialApp(
 theme: brightness == Brightness.light ? buildInventoryTheme() : buildDarkInventoryTheme(),
 home: Scaffold(body: AdministratorTransferForm(ownerUserId: owner, branches: _branches, products: products, holdingsByProduct: const {'PRD-COFFEE-001': [CatalogHolding(branchId: 'branch-north', quantityScaled: 100)]}, submitTransfer: submit, unresolvedDraft: () => null, onClose: close ?? () {}, onCompleted: (_) {}, createTransferId: () => 'audit-operation')),
);
Future<void> _fill(WidgetTester tester) async {
 await _pick(tester, _key('transfer-source'), 'Norte');
 await _pick(tester, _key('transfer-destination'), 'Sur');
 await _line(tester, 0, 'Café', '2');
 await _tap(tester, _key('transfer-add-line'));
 await _line(tester, 1, 'Cinta', '3');
}
void main() {
 for (final width in [320.0, 400.0, 600.0, 1200.0]) {
  for (final brightness in Brightness.values) {
   testWidgets('multi-product advisory blur cancel close $width ${brightness.name} scale 1.3', (tester) async {
    useViewport(tester, Size(width, 900), 1.3);
    var calls = 0;
    var closes = 0;
    await tester.pumpWidget(_app(brightness: brightness, submit: (_) async { calls++; throw StateError('PRIVATE'); }, close: () => closes++));
    await tester.pumpAndSettle();
    await _fill(tester);
    expect(tester.takeException(), isNull);
    if (width >= 600) {
     expect(find.text('Existencias en sucursal origen'), findsOneWidget);
     expect(find.text('Cinta: Sin entrada registrada'), findsOneWidget);
     expect(find.text('Cinta: 0 piece'), findsNothing);
    }
    await _tap(tester, _key('transfer-submit'));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.textContaining('Puedes continuar con el envío.'), findsOneWidget);
    expect(find.textContaining('PRD-COFFEE-001'), findsNothing);
    expect(tester.takeException(), isNull);
    await _tap(tester, _key('transfer-confirm-cancel'));
    expect(calls, 0);
    expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, '2');
    await _tap(tester, _key('transfer-close'));
    expect(closes, 1);
    expect(tester.takeException(), isNull);
   });
   testWidgets('empty transfer catalog $width ${brightness.name} scale 1.3', (tester) async {
    useViewport(tester, Size(width, 900), 1.3);
    await tester.pumpWidget(_app(brightness: brightness, products: const [], submit: (_) => throw StateError('must not submit')));
    await tester.pumpAndSettle();
    expect(find.text('No hay productos disponibles para trasladar.'), findsOneWidget);
    expect(tester.widget<FilledButton>(_key('transfer-submit')).onPressed, isNull);
    expect(tester.takeException(), isNull);
   });
  }
 }
 testWidgets('rapid confirmation invokes once and hides unexpected exception', (tester) async {
  final reply = Completer<TransferResult>();
  var calls = 0;
  await tester.pumpWidget(_app(brightness: Brightness.dark, submit: (_) { calls++; return reply.future; }));
  await tester.pumpAndSettle();
  await _fill(tester);
  await _tap(tester, _key('transfer-submit'));
  final confirm = _key('transfer-confirm-ok');
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.tap(confirm, warnIfMissed: false);
  await tester.pump();
  expect(calls, 1);
  reply.completeError(StateError('PRIVATE English backend error'));
  await tester.pumpAndSettle();
  expect(find.textContaining('PRIVATE'), findsNothing);
  expect(find.text('Reintentar mismo envío'), findsOneWidget);
  expect(tester.takeException(), isNull);
 });
 testWidgets('owner change dismisses old confirmation and clears draft', (tester) async {
  var calls = 0;
  Future<TransferResult> submit(TransferDraft _) async { calls++; throw StateError('should not submit old draft'); }
  await tester.pumpWidget(_app(brightness: Brightness.light, submit: submit));
  await tester.pumpAndSettle();
  await _fill(tester);
  await _tap(tester, _key('transfer-submit'));
  await tester.pumpWidget(_app(brightness: Brightness.light, submit: submit, owner: 'admin-b'));
  await tester.pumpAndSettle();
  expect(_key('transfer-confirm-dialog'), findsNothing, reason: 'D2: session change must not leave another user draft visible');
  expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, isEmpty);
  expect(calls, 0);
 });
 testWidgets('piece unit has Spanish user-facing label', (tester) async {
  await tester.pumpWidget(_app(brightness: Brightness.light, submit: (_) => throw StateError('not submitted')));
  await tester.pumpAndSettle();
  await _line(tester, 0, 'Cinta', '1');
  expect(find.textContaining('piece'), findsNothing, reason: 'T22 D2: English storage unit must be localized for Spanish users');
 });
}
