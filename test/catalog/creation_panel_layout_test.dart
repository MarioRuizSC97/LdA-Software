import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/app/panel_layout.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';

const _previewKey = ValueKey<String>('create-product-preview');
const _nameKey = ValueKey<String>('create-product-name');
const _unitKey = ValueKey<String>('create-product-unit');
const _precisionKey = ValueKey<String>('create-product-precision');

Future<void> _open(WidgetTester tester, double width, double scale) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildInventoryTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: AuthenticatedCatalogPage(
        session: const EmulatorSession(
          userId: 'admin',
          email: 'admin@demo.invalid',
          role: InventoryRole.administrator,
        ),
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
}

Finder _previewText(String text) =>
    find.descendant(of: find.byKey(_previewKey), matching: find.text(text));

void main() {
  testWidgets('compact creation keeps the original form without context', (
    tester,
  ) async {
    await _open(tester, 400, 1);
    expect(find.byType(PanelLayout), findsOneWidget);
    expect(find.byKey(_previewKey), findsNothing);
    expect(tester.getRect(find.byKey(_nameKey)).left, 20);
    expect(tester.getSize(find.byKey(_nameKey)).width, 360);
    expect(find.byKey(_unitKey), findsOneWidget);
    expect(find.byKey(_precisionKey), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Crear'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('panel-back')), findsOneWidget);
    expect(find.text('Nombre del producto'), findsOneWidget);
    expect(find.text('Identificador de unidad'), findsOneWidget);
    expect(find.text('Decimales del producto'), findsOneWidget);
    expect(
      find.text(
        'Identificador en minúsculas, por ejemplo: pieza, mts, serv, etc.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Identificador en minúsculas, por ejemplo piece o kg.'),
      findsNothing,
    );
    expect(
      find.text(
        'Selecciona cuántos decimales usarás en las cantidades del producto (de 0 a 6).',
      ),
      findsOneWidget,
    );
    expect(find.text('Selecciona de 0 a 6 decimales'), findsOneWidget);
    expect(find.text('Entero del 0 al 6.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide preview sits beside form and follows its live values', (
    tester,
  ) async {
    await _open(tester, 1200, 1);
    final preview = find.byKey(_previewKey);
    expect(preview, findsOneWidget);
    expect(
      tester.getRect(preview).left,
      greaterThan(tester.getRect(find.byKey(_nameKey)).right),
    );
    expect(_previewText('Nombre del producto'), findsOneWidget);
    expect(_previewText('Identificador de unidad'), findsOneWidget);
    expect(
      _previewText(
        'Selecciona cuántos decimales usarás en las cantidades del producto (de 0 a 6).',
      ),
      findsOneWidget,
    );
    expect(
      _previewText(
        'Identificador en minúsculas, por ejemplo: pieza, mts, serv, etc.',
      ),
      findsOneWidget,
    );
    expect(
      _previewText(
        'El servidor asigna el código interno permanente y la identidad QR.',
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(_nameKey), 'Tornillo');
    await tester.enterText(find.byKey(_unitKey), 'piece');
    await tester.pump();
    expect(_previewText('Tornillo'), findsOneWidget);
    expect(_previewText('piece'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<int>>(
      find.descendant(
        of: find.byKey(_precisionKey),
        matching: find.byType(DropdownButton<int>),
      ),
    );
    expect(
      dropdown.items!.map((item) => item.value),
      orderedEquals([0, 1, 2, 3, 4, 5, 6]),
    );
    expect(
      dropdown.items!.map((item) => (item.child as Text).data),
      orderedEquals(['0', '1', '2', '3', '4', '5', '6']),
    );
    for (final decimals in [3, 0, 6]) {
      await tester.tap(find.byKey(_precisionKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$decimals').last);
      await tester.pumpAndSettle();
      expect(
        _previewText(
          'Las cantidades de este producto se trabajarán con $decimals decimales.',
        ),
        findsOneWidget,
      );
    }
    await tester.enterText(find.byKey(_nameKey), '');
    await tester.enterText(find.byKey(_unitKey), 'kg');
    await tester.pump();
    expect(_previewText('Nombre del producto'), findsOneWidget);
    expect(_previewText('kg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in <double>[400, 601, 1200]) {
    for (final scale in <double>[1, 2]) {
      testWidgets('creation has no overflow at $width and text scale $scale', (
        tester,
      ) async {
        await _open(tester, width, scale);
        expect(
          find.byKey(_previewKey),
          width < panelWideBreakpoint ? findsNothing : findsOneWidget,
        );
        await tester.enterText(
          find.byKey(_nameKey),
          'Producto con un nombre largo para comprobar el ajuste de líneas',
        );
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('panel-back')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
