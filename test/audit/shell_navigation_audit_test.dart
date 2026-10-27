import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/app_info.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/inventory_theme_host.dart';
import 'package:lda_inventory/app/theme_mode_store.dart';
import 'package:lda_inventory/app/theme_mode_switch.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/viewport.dart';
import '../catalog/cost_pin_test_helper.dart';

const _admin = EmulatorSession(userId: 'audit-admin-a', email: 'admin@demo.invalid', role: InventoryRole.administrator);
Finder _key(String key) => find.byKey(ValueKey(key));
Future<CatalogSnapshot> _catalog(EmulatorSession _) async => CatalogSnapshot([CatalogItem(product: const CatalogProduct(internalCode: 'audit-product', name: 'Café', quantitySpec: QuantitySpec(unit: 'kg', precision: 2)), holdings: const [])], branchChoices: const [CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'), CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur')]);
class _Creation implements ProductCreationGateway {
 @override Future<ProductCreationResult> create(ProductCreationDraft draft) => Completer<ProductCreationResult>().future;
}
class _Gateway implements EmulatorSessionGateway {
 final events = StreamController<EmulatorSession?>.broadcast();
 EmulatorSession? restored;
 final loginReply = Completer<EmulatorSession>();
 int calls = 0;
 @override Future<EmulatorSession?> restoreSession() async => restored;
 @override Stream<EmulatorSession?> sessionChanges() => events.stream;
 @override Future<EmulatorSession> login({required String email, required String password}) { calls++; return loginReply.future; }
 @override Future<void> logout() async { events.add(null); }
}
Future<void> _mount(WidgetTester tester, {Brightness brightness = Brightness.light, String owner = 'audit-admin-a'}) async {
 final store = ThemeModeStore();
 await store.loaded;
 addTearDown(store.dispose);
 await tester.pumpWidget(ThemeModeScope(store: store, child: MaterialApp(theme: brightness == Brightness.light ? buildInventoryTheme() : buildDarkInventoryTheme(), home: AuthenticatedCatalogPage(session: EmulatorSession(userId: owner, email: 'admin@demo.invalid', role: InventoryRole.administrator), catalogLoader: _catalog, onLogout: () async {}, submitStockIntake: (_) async => throw StateError('not submitted'), createProduct: (_) => Completer<ProductCreationResult>().future, submitTransfer: (_) => Completer<TransferResult>().future, unresolvedTransferDraft: () => null, administratorMovements: AdministratorMovements(load: (_) async => [], readProfile: (_) async => const SellerUnnamed(), setSellerName: (uid, _) async => SellerProfileResult(uid: uid, replayed: false))))));
 await tester.pumpAndSettle();
}
Future<void> _open(WidgetTester tester, String panel) async {
 var target = panel == 'Traslados' ? _key('transfer-open') : find.text(panel).first;
 if (target.evaluate().isEmpty) {
  await tester.tap(find.byTooltip('Menú'));
  await tester.pumpAndSettle();
  target = panel == 'Traslados' ? _key('transfer-open') : find.text(panel).first;
 }
 await tester.ensureVisible(target);
 await tester.tap(target);
 await tester.pumpAndSettle();
}
void main() {
 setUpCostPin();
 for (final width in [320.0, 400.0, 600.0, 1200.0]) {
  for (final brightness in Brightness.values) {
   testWidgets('header side panel semantics $width ${brightness.name} scale 1.3', (tester) async {
    useViewport(tester, Size(width, 900), 1.3);
    final semantics = tester.ensureSemantics();
    await _mount(tester, brightness: brightness);
    expect(tester.takeException(), isNull);
    if (_key('shell-more').evaluate().isNotEmpty) {
     await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
     await tester.tap(find.byTooltip('Menú'));
     await tester.pumpAndSettle();
     expect(_key('app-side-panel'), findsOneWidget);
     expect(find.text(appVersionLabel), findsOneWidget);
     final switcher = find.byType(ThemeModeSwitch);
     final store = ThemeModeScope.maybeOf(tester.element(switcher))!;
     final original = store.value;
     for (var i = 0; i < 3; i++) { await tester.tap(find.byTooltip('Tema: ${switch (store.value) { ThemeMode.system => 'Sistema', ThemeMode.light => 'Claro', ThemeMode.dark => 'Oscuro' }}')); await tester.pumpAndSettle(); }
     expect(store.value, original);
     expect(tester.takeException(), isNull);
     await tester.binding.handlePopRoute();
     await tester.pumpAndSettle();
     expect(_key('app-side-panel'), findsNothing);
    }
    await _open(tester, 'Traslados');
    expect(find.byTooltip('Volver'), findsOneWidget);
    expect(find.byTooltip('Inicio'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
    await tester.tap(_key('shell-home'));
    await tester.pumpAndSettle();
    expect(find.byType(AdministratorTransferForm), findsNothing);
    semantics.dispose();
   });
   testWidgets('login rail theme cycle and failure $width ${brightness.name} scale 1.3', (tester) async {
    useViewport(tester, Size(width, 900), 1.3);
    SharedPreferences.setMockInitialValues({});
    final store = ThemeModeStore();
    await store.loaded;
    addTearDown(store.dispose);
    final gateway = _Gateway();
    addTearDown(gateway.events.close);
    await tester.pumpWidget(InventoryThemeHost(store: store, builder: (context, mode) => MaterialApp(theme: buildInventoryTheme(), darkTheme: buildDarkInventoryTheme(), themeMode: mode, home: EmulatorLoginShell(sessionGateway: Future.value(gateway), catalogLoader: _catalog))));
    await tester.pumpAndSettle();
    if (brightness == Brightness.dark) { await store.setThemeMode(ThemeMode.dark); await tester.pumpAndSettle(); }
    expect(_key('login-context'), width >= 600 ? findsOneWidget : findsNothing);
    expect(find.text(appVersionLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    final theme = find.byType(ThemeModeSwitch);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
    await tester.enterText(_key('login-email'), 'admin@demo.invalid');
    await tester.enterText(_key('login-password'), 'audit-password');
    for (var i = 0; i < 3; i++) { await tester.tap(theme); await tester.pumpAndSettle(); }
    expect(tester.widget<TextFormField>(_key('login-password')).controller!.text, 'audit-password');
    final login = find.widgetWithText(FilledButton, 'Iniciar sesión');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.tap(login);
    await tester.pump();
    gateway.loginReply.completeError(StateError('PRIVATE English backend failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.text('No se pudo iniciar sesión en el emulador local.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(gateway.calls, 1, reason: 'D2: rapid repeated login must invoke authentication once');
   });
  }
 }
 for (final source in ['Movimientos', 'Crear producto']) {
  for (final back in ['header', 'system', 'edge']) {
   testWidgets('$source transfer return via $back', (tester) async {
    await _mount(tester);
    await _open(tester, source);
    if (source == 'Crear producto') { await tester.enterText(_key('create-product-name'), 'Borrador privado'); }
    await _open(tester, 'Traslados');
    if (back == 'header') { await tester.tap(_key('panel-back')); }
    else if (back == 'system') { await tester.binding.handlePopRoute(); }
    else { await tester.dragFrom(const Offset(8, 300), const Offset(180, 0)); }
    await tester.pumpAndSettle();
    expect(find.byType(AdministratorTransferForm), findsNothing);
    if (source == 'Movimientos') { expect(find.text('No hay movimientos'), findsOneWidget); }
    else { expect(_key('create-product-name'), findsOneWidget); }
    expect(tester.takeException(), isNull);
   }, variant: TargetPlatformVariant.only(back == 'edge' ? TargetPlatform.iOS : TargetPlatform.android));
  }
 }
 testWidgets('session owner replacement clears active creation panel and draft', (tester) async {
  await _mount(tester);
  await _open(tester, 'Crear producto');
  await tester.enterText(_key('create-product-name'), 'Borrador privado');
  await _mount(tester, owner: 'audit-admin-b');
  expect(_key('create-product-name'), findsNothing, reason: 'D2: a new session starts at catalog, not a previous user panel');
  expect(find.text('Borrador privado'), findsNothing);
 });
 testWidgets('logout from creation clears draft before another session', (tester) async {
  final gateway = _Gateway()..restored = _admin;
  addTearDown(gateway.events.close);
  await tester.pumpWidget(MaterialApp(home: EmulatorLoginShell(sessionGateway: Future.value(gateway), catalogLoader: _catalog, productCreationGatewayLoader: (_) async => _Creation())));
  await tester.pumpAndSettle();
  await _open(tester, 'Crear producto');
  await tester.enterText(_key('create-product-name'), 'Borrador privado');
  // A null auth event models logout/expiration even when a panel is open.
  gateway.events.add(null);
  await tester.pumpAndSettle();
  expect(find.byType(AuthenticatedCatalogPage), findsNothing);
  expect(_key('login-password'), findsOneWidget);
  expect(find.text('Borrador privado'), findsNothing);
  gateway.events.add(const EmulatorSession(userId: 'audit-admin-b', email: 'other@demo.invalid', role: InventoryRole.administrator));
  await tester.pumpAndSettle();
  expect(_key('panel-back'), findsNothing);
  expect(find.byType(AdministratorTransferForm), findsNothing);
  expect(tester.takeException(), isNull);
 });
 for (final route in ['Movimientos', 'Traslados', 'chain']) {
  for (final back in ['header', 'system', 'edge']) {
   testWidgets('intake privacy draft return $route via $back', (tester) async {
    await _mount(tester);
    await tester.tap(_key('product-details-audit-product'));
    await tester.pumpAndSettle();
    await tester.tap(_key('intake-audit-product'));
    await unlockCostPin(tester);
    await tester.enterText(_key('intake-quantity'), '7.25');
    await tester.enterText(_key('intake-unit-cost'), '98.76');
    await _open(tester, route == 'chain' ? 'Movimientos' : route);
    expect(_key('intake-unit-cost'), findsNothing);
    expect(find.textContaining('98.76'), findsNothing);
    if (route == 'chain') { await _open(tester, 'Traslados'); }
    Future<void> goBack() async {
     if (back == 'header') { await tester.tap(_key('panel-back')); }
     else if (back == 'system') { await tester.binding.handlePopRoute(); }
     else { await tester.dragFrom(const Offset(8, 300), const Offset(180, 0)); }
     await tester.pumpAndSettle();
    }
    await goBack();
    if (route == 'chain') { expect(find.text('No hay movimientos'), findsOneWidget); await goBack(); }
    expect(_key('cost-pin'), findsOneWidget);
    expect(_key('intake-unit-cost'), findsNothing);
    expect(find.textContaining('98.76'), findsNothing);
    await unlockCostPin(tester);
    expect(tester.widget<TextFormField>(_key('intake-unit-cost')).controller!.text, '98.76');
    expect(tester.widget<TextFormField>(_key('intake-quantity')).controller!.text, '7.25');
    expect(tester.takeException(), isNull);
   }, variant: TargetPlatformVariant.only(back == 'edge' ? TargetPlatform.iOS : TargetPlatform.android));
  }
 }
 testWidgets('Android back after panel return requires two root presses', (tester) async {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async { calls.add(call.method); return null; });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  await _mount(tester);
  await _open(tester, 'Movimientos');
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(calls.where((m) => m == 'SystemNavigator.pop'), isEmpty);
  await tester.binding.handlePopRoute();
  await tester.pump();
  expect(find.text('Desliza otra vez para salir'), findsOneWidget);
  expect(calls.where((m) => m == 'SystemNavigator.pop'), isEmpty);
  await tester.binding.handlePopRoute();
  await tester.pump();
  expect(calls.where((m) => m == 'SystemNavigator.pop'), hasLength(1));
  await tester.pump(const Duration(seconds: 3));
 }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
