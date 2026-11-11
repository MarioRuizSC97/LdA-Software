import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_search.dart';
import 'package:lda_inventory/catalog/product_qr_scan.dart';
import 'package:lda_inventory/catalog/product_qr.dart';
import 'package:mobile_scanner/mobile_scanner.dart'
    show
        Barcode,
        BarcodeCapture,
        BarcodeFormat,
        CameraFacing,
        CameraLensType,
        MobileScannerErrorCode,
        MobileScannerException,
        MobileScannerController,
        MobileScannerState,
        TorchState;

class _FakeCamera implements ProductQrCamera {
  _FakeCamera();

  final StreamController<ProductQrReading> _readings =
      StreamController<ProductQrReading>.broadcast();
  final StreamController<ProductQrCameraAccess> _access =
      StreamController<ProductQrCameraAccess>.broadcast();

  int disposeCount = 0;

  /// The camera stream cannot carry another reading after the sheet disposed
  /// the camera, which is what makes a second pop impossible.
  bool get readingsClosed => _readings.isClosed;

  @override
  Stream<ProductQrReading> get readings => _readings.stream;

  @override
  Stream<ProductQrCameraAccess> get access => _access.stream;

  @override
  Widget preview(BuildContext context) =>
      const SizedBox(key: ValueKey<String>('fake-preview'));

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!_readings.isClosed) await _readings.close();
    if (!_access.isClosed) await _access.close();
  }

  void emit(ProductQrReading reading) => _readings.add(reading);

  void emitAccess(ProductQrCameraAccess value) => _access.add(value);
}

class _Opened {
  _Opened(this.camera, this.popped);

  final _FakeCamera camera;
  final Completer<String?> popped;
}

Future<_Opened> _openSheet(
  WidgetTester tester, {
  required _FakeCamera camera,
  ProductQrCameraAccess initial = ProductQrCameraAccess.ready,
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

  // The sheet subscribes in initState, so anything emitted after the first
  // settle is delivered to a listener that already exists.
  camera.emitAccess(initial);
  await tester.pumpAndSettle();

  return _Opened(camera, popped);
}

/// A camera state with the shutter running, used to prove the bridge maps a
/// live state instead of echoing a fixed one.
const MobileScannerState _runningScannerState = MobileScannerState(
  availableCameras: 1,
  cameraDirection: CameraFacing.back,
  cameraLensType: CameraLensType.wide,
  isInitialized: true,
  isStarting: false,
  isRunning: true,
  size: Size.zero,
  torchState: TorchState.off,
  zoomScale: 1,
  deviceOrientation: DeviceOrientation.portraitUp,
);

/// Records listener removal.
///
/// A broadcast stream with no listeners silently drops whatever is added to
/// it, so "no events after cancel" would prove nothing on its own; this is
/// what shows the bridge really unsubscribes.
class _RecordingScannerController extends MobileScannerController {
  int removedListeners = 0;

  @override
  void removeListener(VoidCallback listener) {
    removedListeners++;
    super.removeListener(listener);
  }
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

const CatalogProduct _tea = CatalogProduct(
  internalCode: 'AUT-BRSM-777',
  name: 'Té Verde',
  quantitySpec: QuantitySpec(unit: 'pieza', precision: 0),
);

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

List<CatalogProduct> _products() => <CatalogProduct>[_coffee, _water, _tea];

/// A seller snapshot every item of which holds the seller branch, which is
/// what AuthenticatedCatalogPage accepts.
CatalogSnapshot _sellerSnapshot() => CatalogSnapshot(<CatalogItem>[
  for (final CatalogProduct product in _products())
    CatalogItem(
      product: product,
      holdings: const <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 10),
      ],
    ),
]);

/// The four sentences the sheet can show for a failed camera, written out here
/// instead of read back from `productQrCameraNoticeText` so a widget test that
/// ran with the wrong runtime still fails.
const String _deviceUnavailable =
    'Este dispositivo no tiene una cámara disponible.';
const String _deviceDenied =
    'No se permitió el acceso a la cámara. Actívalo en '
    'Ajustes para poder escanear códigos QR.';
const String _browserUnavailable =
    'Este navegador no pudo abrir la cámara o leer códigos QR. Revisa tu '
    'conexión o busca el producto por nombre o código.';
const String _browserDenied =
    'No se permitió el acceso a la cámara. Permite la cámara para este '
    'sitio en tu navegador para poder escanear códigos QR.';

Finder _scanButton() =>
    find.byKey(const ValueKey<String>('catalog-search-scan'));

Finder _searchField() => find.byKey(const ValueKey<String>('catalog-search'));

String _searchFieldValue(WidgetTester tester) {
  final EditableText editable = tester.widget<EditableText>(
    find.descendant(of: _searchField(), matching: find.byType(EditableText)),
  );
  return editable.controller.text;
}

Widget _catalogApp({ProductQrScanOpener? qrScan}) => MaterialApp(
  home: CatalogPage(repository: _Repository(_products()), qrScan: qrScan),
);

Widget _authenticatedApp({ProductQrScanOpener? qrScan}) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    qrScan: qrScan,
    catalogLoader: (EmulatorSession session) async => _sellerSnapshot(),
    onLogout: () async {},
  ),
);

void main() {
  group('camera scanning availability', () {
    // The phone target is the whole gate, on a device and in a browser alike:
    // in a browser `defaultTargetPlatform` is the platform the browser
    // announces. These are plain VM tests on purpose (R3-chrome-skipped): the
    // phone-browser rule must be pinned by `flutter test` alone, and the
    // chrome-only widget group below only adds that a real browser reaches the
    // same button.
    const List<(TargetPlatform, bool)> gate = <(TargetPlatform, bool)>[
      (TargetPlatform.android, true),
      (TargetPlatform.iOS, true),
      (TargetPlatform.macOS, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
    ];

    test('is offered on the phone targets and on nothing else', () {
      for (final (TargetPlatform target, bool offered) in gate) {
        expect(
          productQrScanAvailable(target),
          offered,
          reason:
              '$target ${offered ? 'has a camera route' : 'keeps the typed search only'}',
        );
      }
    });

    test('the running build reads the same gate as the pure one', () {
      // This is the path `main.dart`, `emulator_login.dart` and the search
      // field take, and in a browser it is the browser's own platform report.
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final (TargetPlatform target, bool offered) in gate) {
        debugDefaultTargetPlatformOverride = target;
        expect(
          productQrScanSupported,
          offered,
          reason:
              '$target ${offered ? 'offers' : 'hides'} the scan entry point',
        );
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('camera notice copy', () {
    // The sheet is one widget on both runtimes, but why the camera failed is
    // not one problem: natively it is the device or its settings, while in a
    // browser it is the browser — no secure context, a denied site permission,
    // or the WASM decoder it fetches never arrived. Telling a phone-browser
    // seller that the *device* has no camera sends them looking for a setting
    // that does not exist, so the words are one pure function of (access,
    // isWeb) and are pinned here, where no browser is needed.
    test('a browser that cannot use a camera names the browser', () {
      expect(
        productQrCameraNoticeText(
          ProductQrCameraAccess.unavailable,
          isWeb: true,
        ),
        'Este navegador no pudo abrir la cámara o leer códigos QR. Revisa tu '
        'conexión o busca el producto por nombre o código.',
      );
      expect(
        productQrCameraNoticeText(ProductQrCameraAccess.denied, isWeb: true),
        'No se permitió el acceso a la cámara. Permite la cámara para este '
        'sitio en tu navegador para poder escanear códigos QR.',
      );
    });

    test(
      'the web copy never sends the seller to device hardware or settings',
      () {
        // The two sentences this copy replaces, and the reason R1 and
        // R3-web-offline-scan were filed.
        expect(
          productQrCameraNoticeText(
            ProductQrCameraAccess.unavailable,
            isWeb: true,
          ),
          isNot(contains('dispositivo')),
        );
        expect(
          productQrCameraNoticeText(ProductQrCameraAccess.denied, isWeb: true),
          isNot(contains('Ajustes')),
        );
      },
    );

    test('the native copy keeps its exact words', () {
      expect(
        productQrCameraNoticeText(
          ProductQrCameraAccess.unavailable,
          isWeb: false,
        ),
        'Este dispositivo no tiene una cámara disponible.',
      );
      expect(
        productQrCameraNoticeText(ProductQrCameraAccess.denied, isWeb: false),
        'No se permitió el acceso a la cámara. Actívalo en '
        'Ajustes para poder escanear códigos QR.',
      );
    });

    test(
      'only the failures change, and a running camera has nothing to say',
      () {
        for (final bool isWeb in <bool>[false, true]) {
          expect(
            productQrCameraNoticeText(
              ProductQrCameraAccess.starting,
              isWeb: isWeb,
            ),
            'Encendiendo la cámara…',
            reason: 'starting is not a failure on either runtime',
          );
          expect(
            productQrCameraNoticeText(
              ProductQrCameraAccess.ready,
              isWeb: isWeb,
            ),
            isNull,
            reason: 'no notice while the camera works, on either runtime',
          );
        }
      },
    );
  });

  group('scanned payload becomes a search query', () {
    test('a QR payload is used as typed, without surrounding whitespace', () {
      const ProductQrReading reading = ProductQrReading(
        rawValue: '  PRD-COFFEE-001 ',
        isQrCode: true,
      );

      expect(catalogQueryFromQrReading(reading), 'PRD-COFFEE-001');
    });

    test('a scanned product QR drives the same filter as the typed search', () {
      // The payload of a product QR is its internal code; the scan must reach
      // the matcher through that same payload, not through a second lookup.
      const CatalogProduct product = _coffee;
      final String payload = ProductQr.payloadFor(product);
      expect(payload, product.internalCode);

      final String? query = catalogQueryFromQrReading(
        ProductQrReading(rawValue: payload, isQrCode: true),
      );
      expect(query, payload);

      expect(
        filterCatalogProducts(_products(), query!).single,
        _coffee,
        reason: 'the scanned code narrows the catalog to its product',
      );
      expect(filterCatalogProducts(_products(), 'zzz'), isEmpty);
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
      expect(
        qrReadingRejectionMessage(reading),
        'Lo que leyó la cámara no es un código QR de producto.',
      );
    });

    test('an empty QR payload is rejected with its own words', () {
      const ProductQrReading empty = ProductQrReading(
        rawValue: '',
        isQrCode: true,
      );
      const ProductQrReading blank = ProductQrReading(
        rawValue: '   \n ',
        isQrCode: true,
      );

      expect(catalogQueryFromQrReading(empty), isNull);
      expect(catalogQueryFromQrReading(blank), isNull);
      expect(
        qrReadingRejectionMessage(empty),
        'El código QR no contiene un código de producto.',
        reason: 'an empty QR must not be described as a barcode',
      );
      expect(
        qrReadingRejectionMessage(blank),
        qrReadingRejectionMessage(empty),
      );
    });

    test('a capture with no code yields no reading at all', () {
      expect(
        productQrReadingFromCapture(
          const BarcodeCapture(barcodes: <Barcode>[]),
        ),
        isNull,
        reason: 'an empty capture is not a code and must not be reported',
      );
    });

    test('a captured code reports whether it is a QR', () {
      final ProductQrReading? qr = productQrReadingFromCapture(
        BarcodeCapture(
          barcodes: <Barcode>[
            Barcode(rawValue: 'PRD-TEA-002', format: BarcodeFormat.qrCode),
          ],
        ),
      );
      expect(qr, isNotNull);
      expect(catalogQueryFromQrReading(qr!), 'PRD-TEA-002');

      final ProductQrReading? notQr = productQrReadingFromCapture(
        BarcodeCapture(
          barcodes: <Barcode>[
            Barcode(rawValue: '123456789012', format: BarcodeFormat.ean13),
          ],
        ),
      );
      expect(notQr, isNotNull);
      expect(catalogQueryFromQrReading(notQr!), isNull);
      expect(notQr.isQrCode, isFalse);
    });
  });

  group('camera access from the scanner state', () {
    const MobileScannerState running = MobileScannerState(
      availableCameras: 1,
      cameraDirection: CameraFacing.back,
      cameraLensType: CameraLensType.wide,
      isInitialized: true,
      isStarting: false,
      isRunning: true,
      size: Size.zero,
      torchState: TorchState.off,
      zoomScale: 1,
      deviceOrientation: DeviceOrientation.portraitUp,
    );

    test('a denied permission is reported as denied', () {
      expect(
        productQrCameraAccessFor(
          running.copyWith(
            error: const MobileScannerException(
              errorCode: MobileScannerErrorCode.permissionDenied,
            ),
          ),
        ),
        ProductQrCameraAccess.denied,
      );
    });

    test('a running camera is ready', () {
      expect(productQrCameraAccessFor(running), ProductQrCameraAccess.ready);
    });

    test('an error that is not a permission problem is unavailable', () {
      expect(
        productQrCameraAccessFor(
          const MobileScannerState.uninitialized().copyWith(
            error: const MobileScannerException(
              errorCode: MobileScannerErrorCode.unsupported,
            ),
          ),
        ),
        ProductQrCameraAccess.unavailable,
      );
    });

    test('an uninitialized camera is still starting', () {
      expect(
        productQrCameraAccessFor(const MobileScannerState.uninitialized()),
        ProductQrCameraAccess.starting,
      );
    });
  });

  group('camera sheet', () {
    testWidgets('explains that the camera is starting', (
      WidgetTester tester,
    ) async {
      await _openSheet(
        tester,
        camera: _FakeCamera(),
        initial: ProductQrCameraAccess.starting,
      );

      expect(
        find.byKey(const ValueKey<String>('qr-scan-starting')),
        findsOneWidget,
      );
      expect(find.text('Encendiendo la cámara…'), findsOneWidget);
      expect(find.textContaining('Coloca el código QR'), findsNothing);
    });

    testWidgets('announces the preview once the camera runs', (
      WidgetTester tester,
    ) async {
      await _openSheet(tester, camera: _FakeCamera());

      expect(
        find.byKey(const ValueKey<String>('fake-preview')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Coloca el código QR del producto'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-starting')),
        findsNothing,
      );
    });

    testWidgets('closes on the first readable QR and frees the camera', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-COFFEE-001', isQrCode: true),
      );
      await tester.pumpAndSettle();

      expect(await opened.popped.future, 'PRD-COFFEE-001');
      expect(opened.camera.disposeCount, 1);
      expect(find.byKey(const ValueKey<String>('fake-preview')), findsNothing);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the sheet pops exactly once',
      );

      // Once the sheet disposed the camera there is no source for another
      // reading, which is the structural half of "only one pop".
      expect(opened.camera.readingsClosed, isTrue);
    });

    testWidgets('only the first readable code closes the sheet', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-COFFEE-001', isQrCode: true),
      );
      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-TEA-002', isQrCode: true),
      );
      await tester.pumpAndSettle();

      expect(await opened.popped.future, 'PRD-COFFEE-001');
      expect(tester.takeException(), isNull, reason: 'the route pops once');
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('keeps scanning and explains a code that is not a QR', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

      opened.camera.emit(
        const ProductQrReading(rawValue: '123456789012', isQrCode: false),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Lo que leyó la cámara no es un código QR de producto.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('fake-preview')),
        findsOneWidget,
        reason: 'the camera stays open (spec S3)',
      );
      expect(find.text('Escanear código QR'), findsOneWidget);
      expect(opened.camera.disposeCount, 0);

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-TEA-002', isQrCode: true),
      );
      await tester.pumpAndSettle();

      expect(await opened.popped.future, 'PRD-TEA-002');
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('explains an empty QR with its own words', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

      opened.camera.emit(const ProductQrReading(rawValue: '', isQrCode: true));
      await tester.pumpAndSettle();

      expect(
        find.text('El código QR no contiene un código de producto.'),
        findsOneWidget,
        reason: 'an empty QR is not reported as a barcode',
      );
      expect(opened.camera.disposeCount, 0);

      opened.camera.emit(
        const ProductQrReading(rawValue: 'PRD-COFFEE-001', isQrCode: true),
      );
      await tester.pumpAndSettle();
      expect(await opened.popped.future, 'PRD-COFFEE-001');
    });

    testWidgets('offers a way out when the camera permission is denied', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(
        tester,
        camera: _FakeCamera(),
        initial: ProductQrCameraAccess.denied,
      );

      expect(
        find.text(kIsWeb ? _browserDenied : _deviceDenied),
        findsOneWidget,
      );
      expect(
        find.text(kIsWeb ? _deviceDenied : _browserDenied),
        findsNothing,
        reason: 'the other runtime\'s words would send the seller elsewhere',
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-denied')),
        findsOneWidget,
      );
      expect(find.textContaining('Coloca el código QR'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-close')));
      await tester.pumpAndSettle();

      expect(await opened.popped.future, isNull);
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('says so when the camera cannot be used, and lets you out', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(
        tester,
        camera: _FakeCamera(),
        initial: ProductQrCameraAccess.unavailable,
      );

      expect(
        find.text(kIsWeb ? _browserUnavailable : _deviceUnavailable),
        findsOneWidget,
      );
      expect(
        find.text(kIsWeb ? _deviceUnavailable : _browserUnavailable),
        findsNothing,
        reason: 'a phone browser must not be told the device has no camera',
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-unavailable')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-close')));
      await tester.pumpAndSettle();

      expect(await opened.popped.future, isNull);
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('cancel returns no query and releases the camera', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-cancel')));
      await tester.pumpAndSettle();

      expect(await opened.popped.future, isNull);
      expect(opened.camera.disposeCount, 1);
    });

    testWidgets('a payload that is not a known product still reaches search', (
      WidgetTester tester,
    ) async {
      final _Opened opened = await _openSheet(tester, camera: _FakeCamera());

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

  group('camera adapter against the real controller', () {
    // MobileScannerController is a plain ValueNotifier before it ever talks to
    // a platform, so this exercises the bridge that closed H1 without a lens.
    // It is deliberately never disposed: disposing it would reach the plugin
    // platform, which a unit test has no camera to answer with.
    test(
      'a new listener is given the current state, not the next change',
      () async {
        final _RecordingScannerController controller =
            _RecordingScannerController();
        final MobileScannerProductQrCamera camera =
            MobileScannerProductQrCamera(controller: controller);

        // Denied before anything observes it. A bridge that echoed a fixed
        // "starting" (a fresh controller also starts as uninitialized), or one
        // that only reported changes, would not say denied right here.
        controller.value = const MobileScannerState.uninitialized().copyWith(
          error: const MobileScannerException(
            errorCode: MobileScannerErrorCode.permissionDenied,
          ),
        );

        final List<ProductQrCameraAccess> seen = <ProductQrCameraAccess>[];
        final StreamSubscription<ProductQrCameraAccess> subscription = camera
            .access
            .listen(seen.add);

        await pumpEventQueue();

        expect(
          seen,
          <ProductQrCameraAccess>[ProductQrCameraAccess.denied],
          reason: 'the sheet must know the state without waiting for a change',
        );

        controller.value = _runningScannerState;
        await pumpEventQueue();

        expect(seen, <ProductQrCameraAccess>[
          ProductQrCameraAccess.denied,
          ProductQrCameraAccess.ready,
        ]);

        await subscription.cancel();
        await pumpEventQueue();
        final int seenBeforeCancel = seen.length;

        // The proof that cancelling unsubscribes: without it the broadcast
        // stream would drop the next event whether we removed the listener
        // or not.
        expect(
          controller.removedListeners,
          greaterThanOrEqualTo(1),
          reason: 'cancelling must remove the listener again',
        );

        controller.value = const MobileScannerState.uninitialized();
        await pumpEventQueue();

        expect(seen.length, seenBeforeCancel);
      },
    );

    test(
      'the adapter filters no symbology, so a shelf barcode is reported',
      () {
        // If a formats filter came back, H2 would reopen silently: the plugin
        // would never deliver a barcode, and the seller would see nothing.
        final MobileScannerController controller =
            createProductQrCameraController();

        expect(controller.formats, isEmpty);
        expect(
          controller.autoStart,
          isTrue,
          reason: 'the mounted widget is what starts the camera',
        );

        // The adapter's own default path too: a filter written where the
        // controller is chosen (controller ?? ...) must fail here as well,
        // not only at the factory.
        final MobileScannerProductQrCamera camera =
            MobileScannerProductQrCamera();

        expect(camera.debugController.formats, isEmpty);
        expect(camera.debugController.autoStart, isTrue);
      },
    );
  });

  group('search field at 320px', () {
    for (final double scale in <double>[1, 2]) {
      testWidgets('both actions fit at text scale $scale', (
        WidgetTester tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        // The framework does not undo these after a failed expect, so they are
        // released through tearDown. The platform override is the exception:
        // foundation debug variables are verified before tearDown runs, so it
        // stays inline below.
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(320, 700));
        tester.platformDispatcher.textScaleFactorTestValue = scale;

        await tester.pumpWidget(
          _catalogApp(qrScan: (BuildContext context) async => null),
        );
        await tester.pumpAndSettle();

        await tester.enterText(_searchField(), 'grano');
        await tester.pumpAndSettle();

        expect(_scanButton(), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('catalog-search-clear')),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'clear and scan share the field suffix without overflowing',
        );

        debugDefaultTargetPlatformOverride = null;
      }, skip: kIsWeb);
    }
  });
  group('scan entry point in a phone browser', () {
    // Only runs under `flutter test --platform chrome`, where kIsWeb is true
    // for real. This is the runtime half of the mobile-web gate: the pure
    // function alone cannot prove the button reaches a browser. The opener is
    // a fake, so no test asks a browser for camera permission.
    testWidgets('an Android browser offers the camera and types the code', (
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
      expect(_searchFieldValue(tester), 'PRD-WATER-002');
      expect(find.text('Agua Mineral 1 L'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: !kIsWeb);

    testWidgets('an iOS browser offers it too, store screen included', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      int opened = 0;

      await tester.pumpWidget(
        _catalogApp(
          qrScan: (BuildContext context) async {
            opened++;
            return 'AUT-BRSM-777';
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();

      expect(opened, 1);
      expect(_searchFieldValue(tester), 'AUT-BRSM-777');
      expect(find.text('Té Verde'), findsOneWidget);

      // The store screen runs the same rule on the same browser.
      await tester.pumpWidget(
        _authenticatedApp(qrScan: (BuildContext context) async => null),
      );
      await tester.pumpAndSettle();
      expect(_scanButton(), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    }, skip: !kIsWeb);

    testWidgets('a desktop browser keeps the typed search only', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => 'PRD-WATER-002'),
      );
      await tester.pumpAndSettle();

      expect(
        _scanButton(),
        findsNothing,
        reason: 'a desktop browser has no camera route',
      );
      expect(find.text('Café Grano Selecto'), findsOneWidget);

      // The typed search stays fully usable on the web.
      await tester.enterText(_searchField(), 'grano');
      await tester.pumpAndSettle();
      // Leave focus mode before inspecting the retained, filtered grid.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: !kIsWeb);
  });

  group('scan entry point in the search field', () {
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
      expect(_searchFieldValue(tester), 'PRD-WATER-002');
      expect(find.text('Agua Mineral 1 L'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: kIsWeb);

    testWidgets('is offered on iOS as well', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => null),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    }, skip: kIsWeb);

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

    testWidgets('a cancelled scan keeps the query already typed', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => null),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_searchField(), 'grano');
      await tester.pumpAndSettle();
      // Inspect the filtered grid, not its focus-mode results copy.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_searchFieldValue(tester), 'grano');
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      expect(
        _scanButton(),
        findsOneWidget,
        reason:
            'a query must not hide the camera, otherwise a seller has to '
            'clear the field before scanning again',
      );
      expect(
        find.byKey(const ValueKey<String>('catalog-search-clear')),
        findsOneWidget,
      );

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();

      expect(
        _searchFieldValue(tester),
        'grano',
        reason: 'cancel must not clear what was already typed',
      );
      expect(find.text('Café Grano Selecto'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: kIsWeb);

    testWidgets('a scan replaces the query already typed', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(
        _catalogApp(qrScan: (BuildContext context) async => 'AUT-BRSM-777'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_searchField(), 'grano');
      await tester.pumpAndSettle();
      expect(find.text('Té Verde'), findsNothing);

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();
      // Leave focus mode before inspecting the retained, filtered grid.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(_searchFieldValue(tester), 'AUT-BRSM-777');
      expect(find.text('Té Verde'), findsOneWidget);
      expect(find.text('Café Grano Selecto'), findsNothing);
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: kIsWeb);

    testWidgets('no scan button is offered without an opener', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(_catalogApp());
      await tester.pumpAndSettle();

      expect(_scanButton(), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the store screen gets the same camera entry point', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      int opened = 0;

      await tester.pumpWidget(
        _authenticatedApp(
          qrScan: (BuildContext context) async {
            opened++;
            return 'AUT-BRSM-777';
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(_scanButton(), findsOneWidget);

      await tester.tap(_scanButton());
      await tester.pumpAndSettle();

      expect(opened, 1);
      expect(_searchFieldValue(tester), 'AUT-BRSM-777');
      expect(find.text('Té Verde'), findsOneWidget);
      expect(find.text('Agua Mineral 1 L'), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    }, skip: kIsWeb);
  });
}
