import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_qr_scan.dart';

class _FakeCamera implements ProductQrCamera {
  _FakeCamera({this.access = ProductQrCameraAccess.ready, this.startGate});

  final ProductQrCameraAccess access;

  /// When set, start() waits for it, so the starting state can be observed.
  final Completer<ProductQrCameraAccess>? startGate;

  final StreamController<ProductQrReading> _readings =
      StreamController<ProductQrReading>.broadcast();

  int disposeCount = 0;
  int startCount = 0;

  @override
  Stream<ProductQrReading> get readings => _readings.stream;

  @override
  Future<ProductQrCameraAccess> start() async {
    startCount++;
    if (startGate != null) return startGate!.future;
    return access;
  }

  @override
  Widget preview(BuildContext context) =>
      const SizedBox(key: ValueKey<String>('fake-preview'));

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!_readings.isClosed) await _readings.close();
  }

  void emit(ProductQrReading reading) => _readings.add(reading);
}

class _Opened {
  _Opened(this.camera, this.popped);

  final _FakeCamera camera;
  final Completer<String?> popped;
}

Future<_Opened> _openSheet(
  WidgetTester tester, {
  required _FakeCamera camera,
}) async {
  final Completer<String?> popped = Completer<String?>();

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => popped.complete(
            Navigator.of(context).push<String>(
              MaterialPageRoute<String>(
                builder: (BuildContext context) =>
                    ProductQrScanSheet(camera: camera),
              ),
            ),
          ),
          child: const Text('abrir-escaner'),
        ),
      ),
    ),
  );

  await tester.tap(find.text('abrir-escaner'));
  await tester.pumpAndSettle();

  return _Opened(camera, popped);
}

class _Repository implements CatalogRepository {
  _Repository(this.products);

  final List<CatalogProduct> products;

  @override
  Future<List<CatalogProduct>> fetchProducts() async => products;
}

const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Café Grano Selecto',
  quantitySpec: QuantitySpec(unit: 'pieza', precision: 0),
);

const CatalogProduct _water = CatalogProduct(
  internalCode: 'PRD-WATER-002',
  name: 'Agua Mineral 1 L',
  quantitySpec: QuantitySpec(unit: 'pieza', precision: 0),
);

Finder _scanButton() =>
    find.byKey(const ValueKey<String>('catalog-search-scan'));

Widget _catalogApp({ProductQrScanOpener? qrScan}) => MaterialApp(
  home: CatalogPage(
    repository: _Repository(<CatalogProduct>[_coffee, _water]),
    qrScan: qrScan,
  ),
);

void main() {
  group('camera scanning availability', () {
    test('is offered on Android and iOS only', () {
      expect(
        productQrScanAvailable(isWeb: false, target: TargetPlatform.android),
        isTrue,
      );
      expect(
        productQrScanAvailable(isWeb: false, target: TargetPlatform.iOS),
        isTrue,
      );
    });

    test('is never offered on the web, even on a phone browser', () {
      for (final TargetPlatform target in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        expect(
          productQrScanAvailable(isWeb: true, target: target),
          isFalse,
          reason: 'web keeps the typed search only (spec S2)',
        );
      }
    });

    test('is not offered on desktop platforms', () {
      for (final TargetPlatform target in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          productQrScanAvailable(isWeb: false, target: target),
          isFalse,
          reason: '$target has no product QR camera route in v1.0',
        );
      }
    });
  });

  group('scanned payload becomes a search query', () {
    test('a QR payload is used as typed, without surrounding whitespace', () {
      const ProductQrReading reading = ProductQrReading(
        rawValue: '  PRD-COFFEE-001 ',
        isQrCode: true,
      );

      expect(catalogQueryFromQrReading(reading), 'PRD-COFFEE-001');
    });

    test('the payload of the app QR is the internal code, so it filters', () {
      // ProductQr.payloadFor is the internal code; the catalog search matches
      // by name and code, so a scanned code must produce that same query.
      const ProductQrReading reading = ProductQrReading(
        rawValue: 'AUT-BRSM-777',
        isQrCode: true,
      );

      expect(catalogQueryFromQrReading(reading), 'AUT-BRSM-777');
    });

    test('a barcode that is not a QR is rejected', () {
      const ProductQrReading reading = ProductQrReading(
        rawValue: '123456789012',
        isQrCode: false,
      );

      expect(
        catalogQueryFromQrReading(reading),
        isNull,
        reason: 'only product QR codes drive the search (spec S3)',
      );
    });

    test('an empty or whitespace-only payload is rejected', () {
      expect(
        catalogQueryFromQrReading(
          const ProductQrReading(rawValue: '', isQrCode: true),
        ),
        isNull,
      );
      expect(
        catalogQueryFromQrReading(
          const ProductQrReading(rawValue: '   \n ', isQrCode: true),
        ),
        isNull,
      );
    });
  });

  group('camera sheet', () {
    testWidgets('explains that the camera is starting', (
      WidgetTester tester,
    ) async {
      final Completer<ProductQrCameraAccess> gate =
          Completer<ProductQrCameraAccess>();
      final _Opened opened = await _openSheet(
        tester,
        camera: _FakeCamera(startGate: gate),
      );

      expect(
        find.byKey(const ValueKey<String>('qr-scan-starting')),
        findsOneWidget,
      );
      expect(find.text('Encendiendo la cámara…'), findsOneWidget);
      expect(opened.camera.startCount, 1);

      gate.complete(ProductQrCameraAccess.ready);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('fake-preview')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Coloca el código QR del producto'),
        findsOneWidget,
      );
    });

    testWidgets('closes on the first readable QR and frees the camera', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());
      await tester.pumpAndSettle();

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-COFFEE-001', isQrCode: true),
      );
      await tester.pumpAndSettle();

      expect(await opened.popped.future, 'PRD-COFFEE-001');
      expect(opened.camera.disposeCount, 1);
      expect(find.byKey(const ValueKey<String>('fake-preview')), findsNothing);
    });

    testWidgets('keeps scanning and explains a code that is not a QR', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());
      await tester.pumpAndSettle();

      opened.camera.emit(
        const ProductQrReading(rawValue: '123456789012', isQrCode: false),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('El código leído no es un QR de producto.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('fake-preview')),
        findsOneWidget,
      );
      // Still on the sheet: the camera was not released. (The popped completer
      // is completed with the route future, so it cannot prove "not popped".)
      expect(find.text('Escanear código QR'), findsOneWidget);
      expect(opened.camera.disposeCount, 0);

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-TEA-002', isQrCode: true),
      );
      await tester.pumpAndSettle();

      expect(await opened.popped.future, 'PRD-TEA-002');
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('offers a way out when the camera permission is denied', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(
        tester,
        camera: _FakeCamera(access: ProductQrCameraAccess.denied),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No se permitió el acceso a la cámara'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-denied')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('fake-preview')), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-close')));
      await tester.pumpAndSettle();

      expect(await opened.popped.future, isNull);
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('says so when the device has no camera', (
      WidgetTester tester,
    ) async {
      await _openSheet(
        tester,
        camera: _FakeCamera(access: ProductQrCameraAccess.unavailable),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Este dispositivo no tiene una cámara disponible.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('cancel returns no query and releases the camera', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-cancel')));
      await tester.pumpAndSettle();

      expect(await opened.popped.future, isNull);
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('a payload that is not a known product still reaches search', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());
      await tester.pumpAndSettle();

      opened.camera.emit(
        const ProductQrReading(
          rawValue: 'https://otro-negocio.example/x',
          isQrCode: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        await opened.popped.future,
        'https://otro-negocio.example/x',
        reason:
            'the search shows "Sin resultados"; the sheet must not decide '
            'what exists in the catalog',
      );
    });
  });

  group('scan entry point in the search field', () {
    // The platform override is a foundation debug variable, so it has to be
    // released before the test body ends (the same rule as SemanticsHandle).
    testWidgets('is offered on Android and types the scanned code', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      int opened = 0;

      await tester.pumpWidget(
        _catalogApp(
          qrScan: (BuildContext context) async {
            opened++;
            return 'PRD-WATER-002';
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();

      expect(opened, 1);
      final EditableText editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('catalog-search')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.controller.text, 'PRD-WATER-002');
      expect(find.text('Agua Mineral 1 L'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('is offered on iOS as well', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => null),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('is hidden when the platform has no camera route', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => 'PRD-COFFEE-001'),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsNothing);
      expect(find.text('Café Grano Selecto'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a cancelled scan leaves the search untouched', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => null),
      );
      await tester.pumpAndSettle();

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('no scan button is offered without an opener', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(_catalogApp());
      await tester.pumpAndSettle();

      expect(_scanButton(), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
