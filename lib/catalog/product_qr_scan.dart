import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Camera scan of a product QR code, used to fill the catalog search.
///
/// The QR payload of a product is its internal code (`product_qr.dart`), and
/// the catalog search already matches by code, so a scan simply types that
/// payload into the search field. No second lookup path is introduced.
///
/// Camera entry points exist on Android and iOS only, one reading closes the
/// scanner, and Android ships the bundled ML Kit barcode model so it also
/// works offline and on devices without Google Play Services.

/// What the camera can report to the scanner sheet.
class ProductQrReading {
  const ProductQrReading({required this.rawValue, required this.isQrCode});

  final String rawValue;
  final bool isQrCode;
}

/// The search query a reading should type, or null when the reading cannot be
/// used and the camera has to stay open.
///
/// A payload that is a valid QR but not a known product code is still
/// returned: the search then shows its own "Sin resultados" panel, which tells
/// the truth about what was read instead of pretending nothing happened.
String? catalogQueryFromQrReading(ProductQrReading reading) {
  if (!reading.isQrCode) return null;
  final String trimmed = reading.rawValue.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Why a reading could not be used, in the words shown to the seller. Naming
/// the case keeps an empty QR from being described as the wrong thing.
String qrReadingRejectionMessage(ProductQrReading reading) {
  if (!reading.isQrCode) {
    return 'Lo que leyó la cámara no es un código QR de producto.';
  }
  return 'El código QR no contiene un código de producto.';
}

/// The reading carried by one camera capture, or null when the capture found
/// nothing. An empty capture is not a code, so it must not be reported as one.
ProductQrReading? productQrReadingFromCapture(BarcodeCapture capture) {
  final Barcode? barcode = capture.barcodes.firstOrNull;
  if (barcode == null) return null;
  return ProductQrReading(
    rawValue: barcode.rawValue ?? '',
    isQrCode: barcode.format == BarcodeFormat.qrCode,
  );
}

/// Access states the sheet can explain to the seller.
enum ProductQrCameraAccess { starting, ready, denied, unavailable }

/// Folds the plugin camera state into the one state the sheet shows.
///
/// The preview is always in the tree, so the widget owns starting the camera;
/// this only reads the outcome. Anything other than a denied permission or a
/// running camera is still starting, and a failure that is not a permission
/// problem is reported as unavailable.
ProductQrCameraAccess productQrCameraAccessFor(MobileScannerState state) {
  if (state.error?.errorCode == MobileScannerErrorCode.permissionDenied) {
    return ProductQrCameraAccess.denied;
  }
  if (state.isRunning) return ProductQrCameraAccess.ready;
  if (state.error != null) return ProductQrCameraAccess.unavailable;
  return ProductQrCameraAccess.starting;
}

/// Whether the camera entry point is offered on this platform.
bool productQrScanAvailable({
  required bool isWeb,
  required TargetPlatform target,
}) {
  if (isWeb) return false;
  return target == TargetPlatform.android || target == TargetPlatform.iOS;
}

/// The same rule for the running platform.
bool get productQrScanSupported =>
    productQrScanAvailable(isWeb: kIsWeb, target: defaultTargetPlatform);

/// The camera the sheet needs. The production implementation is backed by
/// `mobile_scanner`; tests drive a fake one, so no test opens a real camera.
///
/// Both streams are broadcast and are subscribed as soon as the sheet is
/// built, because the sheet keeps the preview mounted from the first frame.
abstract interface class ProductQrCamera {
  Stream<ProductQrReading> get readings;

  /// The camera access as it becomes known. Starts reporting from the first
  /// subscription.
  Stream<ProductQrCameraAccess> get access;

  Widget preview(BuildContext context);

  Future<void> dispose();
}

/// Opens the scanner and returns the payload to search for, or null when the
/// seller cancels.
typedef ProductQrScanOpener = Future<String?> Function(BuildContext context);

/// The camera sheet: a preview that is mounted from the first frame, one
/// readable QR, and honest Spanish feedback when the camera or the code is
/// not usable.
class ProductQrScanSheet extends StatefulWidget {
  const ProductQrScanSheet({required this.camera, super.key});

  final ProductQrCamera camera;

  @override
  State<ProductQrScanSheet> createState() => _ProductQrScanSheetState();
}

class _ProductQrScanSheetState extends State<ProductQrScanSheet> {
  ProductQrCameraAccess _access = ProductQrCameraAccess.starting;
  String? _rejection;

  /// Guards the single scan: readings after the first usable code are
  /// dropped, so the sheet cannot pop twice.
  bool _done = false;

  StreamSubscription<ProductQrReading>? _readings;
  StreamSubscription<ProductQrCameraAccess>? _accessSubscription;

  @override
  void initState() {
    super.initState();
    _readings = widget.camera.readings.listen(_onReading);
    _accessSubscription = widget.camera.access.listen((
      ProductQrCameraAccess access,
    ) {
      if (!mounted) return;
      setState(() => _access = access);
    });
  }

  void _onReading(ProductQrReading reading) {
    if (_done) return;
    final String? query = catalogQueryFromQrReading(reading);
    if (query == null) {
      // Not usable: keep the camera open and say what happened, in the words
      // that name this case.
      setState(() => _rejection = qrReadingRejectionMessage(reading));
      return;
    }
    _done = true;
    Navigator.of(context).pop(query);
  }

  @override
  void dispose() {
    // Cancel and release synchronously: the teardown order must not depend on
    // when microtasks run, and the camera owns its own asynchronous cleanup.
    _readings?.cancel();
    _readings = null;
    _accessSubscription?.cancel();
    _accessSubscription = null;
    unawaited(widget.camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _access == ProductQrCameraAccess.ready;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código QR'),
        leading: Navigator.of(context).canPop()
            ? TextButton(
                key: const ValueKey<String>('qr-scan-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              )
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // The preview stays mounted: the MobileScanner widget is
                  // what attaches and starts the controller.
                  widget.camera.preview(context),
                  if (!ready) _accessNotice(),
                ],
              ),
            ),
            if (_rejection case final String message)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Semantics(
                  liveRegion: true,
                  label: message,
                  child: ExcludeSemantics(child: Text(message)),
                ),
              ),
            if (ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  'Coloca el código QR del producto dentro del recuadro. '
                  'Al leerlo se buscará en el inventario.',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _accessNotice() {
    return switch (_access) {
      ProductQrCameraAccess.starting => const _CameraNotice(
        key: ValueKey<String>('qr-scan-starting'),
        icon: Icons.camera_alt_outlined,
        message: 'Encendiendo la cámara…',
      ),
      ProductQrCameraAccess.denied => _CameraNotice(
        key: const ValueKey<String>('qr-scan-denied'),
        icon: Icons.no_photography_outlined,
        message:
            'No se permitió el acceso a la cámara. Actívalo en '
            'Ajustes para poder escanear códigos QR.',
        action: _closeButton(),
      ),
      ProductQrCameraAccess.unavailable => _CameraNotice(
        key: const ValueKey<String>('qr-scan-unavailable'),
        icon: Icons.videocam_off_outlined,
        message: 'Este dispositivo no tiene una cámara disponible.',
        action: _closeButton(),
      ),
      ProductQrCameraAccess.ready => const SizedBox.shrink(),
    };
  }

  Widget _closeButton() => FilledButton(
    key: const ValueKey<String>('qr-scan-close'),
    onPressed: () => Navigator.of(context).pop(),
    child: const Text('Cerrar'),
  );
}

class _CameraNotice extends StatelessWidget {
  const _CameraNotice({
    required this.icon,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 48,
                color: Theme.of(context).colorScheme.surface,
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                label: message,
                child: ExcludeSemantics(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.surface,
                    ),
                  ),
                ),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The controller the adapter uses.
///
/// It is a function so a test can pin the decision that keeps H2 closed: no
/// `formats` filter, so every symbology the device can read reaches the sheet
/// and a shelf barcode is reported instead of silently ignored.
MobileScannerController createProductQrCameraController() =>
    MobileScannerController();

/// The `mobile_scanner` adapter. It is only constructed on Android and iOS,
/// where [productQrScanSupported] is true.
///
/// Every barcode symbology is decoded on purpose: a store shelf carries 1D
/// barcodes too, and the sheet tells the seller that what was read is not a
/// product QR instead of staying silent.
class MobileScannerProductQrCamera implements ProductQrCamera {
  MobileScannerProductQrCamera({MobileScannerController? controller})
    : _controller = controller ?? createProductQrCameraController();

  final MobileScannerController _controller;

  @override
  Stream<ProductQrReading> get readings =>
      _controller.barcodes.expand((BarcodeCapture capture) sync* {
        final ProductQrReading? reading = productQrReadingFromCapture(capture);
        if (reading != null) yield reading;
      });

  @override
  Stream<ProductQrCameraAccess> get access {
    // The controller is a ValueNotifier, so its state is bridged here. The
    // current value is emitted on subscription, which is what the sheet sees
    // before the preview has managed to start the camera.
    late final StreamController<ProductQrCameraAccess> controller;
    late final void Function() emit;
    emit = () => controller.add(productQrCameraAccessFor(_controller.value));
    controller = StreamController<ProductQrCameraAccess>.broadcast(
      onListen: () {
        emit();
        _controller.addListener(emit);
      },
      onCancel: () => _controller.removeListener(emit),
    );
    return controller.stream;
  }

  @override
  Widget preview(BuildContext context) => MobileScanner(
    key: const ValueKey<String>('qr-scan-preview'),
    controller: _controller,
    errorBuilder: (BuildContext context, MobileScannerException error) =>
        const SizedBox.shrink(),
  );

  @override
  Future<void> dispose() => _controller.dispose();
}

/// Pushes the camera sheet and returns the scanned payload, or null when the
/// seller cancels.
Future<String?> showProductQrScanner(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) =>
            ProductQrScanSheet(camera: MobileScannerProductQrCamera()),
      ),
    );
