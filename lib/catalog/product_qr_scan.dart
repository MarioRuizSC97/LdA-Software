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
/// A payload that is a valid QR but not a known product code is still returned:
/// the search then shows its own "Sin resultados" panel, which tells the truth
/// about what was read instead of pretending nothing happened.
String? catalogQueryFromQrReading(ProductQrReading reading) {
  if (!reading.isQrCode) return null;
  final String trimmed = reading.rawValue.trim();
  return trimmed.isEmpty ? null : trimmed;
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

/// Access states the sheet can explain to the seller.
enum ProductQrCameraAccess { starting, ready, denied, unavailable }

/// The camera the sheet needs. The production implementation is backed by
/// `mobile_scanner`; tests drive a fake one, so no test opens a real camera.
abstract interface class ProductQrCamera {
  Stream<ProductQrReading> get readings;

  /// Starts the feed and reports whether it can show a preview.
  Future<ProductQrCameraAccess> start();

  Widget preview(BuildContext context);

  Future<void> dispose();
}

/// Opens the scanner and returns the payload to search for, or null when the
/// seller cancels.
typedef ProductQrScanOpener = Future<String?> Function(BuildContext context);

/// The camera sheet: a preview, one readable QR, and honest Spanish feedback
/// when the camera or the code is not usable.
class ProductQrScanSheet extends StatefulWidget {
  const ProductQrScanSheet({required this.camera, super.key});

  final ProductQrCamera camera;

  @override
  State<ProductQrScanSheet> createState() => _ProductQrScanSheetState();
}

class _ProductQrScanSheetState extends State<ProductQrScanSheet> {
  ProductQrCameraAccess _access = ProductQrCameraAccess.starting;
  String? _rejection;
  StreamSubscription<ProductQrReading>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    _subscription = widget.camera.readings.listen(_onReading);
    final ProductQrCameraAccess access = await widget.camera.start();
    if (!mounted) return;
    setState(() => _access = access);
  }

  void _onReading(ProductQrReading reading) {
    final String? query = catalogQueryFromQrReading(reading);
    if (query == null) {
      // Not usable: keep the camera open and say what happened.
      setState(() => _rejection = 'El código leído no es un QR de producto.');
      return;
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
    Navigator.of(context).pop(query);
  }

  @override
  void dispose() {
    // Cancel and release synchronously: the teardown order must not depend on
    // when microtasks run, and the camera owns its own asynchronous cleanup.
    _subscription?.cancel();
    _subscription = null;
    unawaited(widget.camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              child: switch (_access) {
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
                ProductQrCameraAccess.ready => widget.camera.preview(context),
              },
            ),
            if (_rejection case final String message)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Semantics(
                  liveRegion: true,
                  label: message,
                  child: ExcludeSemantics(child: Text(message)),
                ),
              ),
            if (_access == ProductQrCameraAccess.ready)
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              label: message,
              child: ExcludeSemantics(
                child: Text(message, textAlign: TextAlign.center),
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The `mobile_scanner` adapter. It is only constructed on Android and iOS,
/// where [productQrScanSupported] is true.
class MobileScannerProductQrCamera implements ProductQrCamera {
  MobileScannerProductQrCamera({MobileScannerController? controller})
    : _controller =
          controller ??
          MobileScannerController(
            // Only product QR codes are decoded; other barcode symbologies
            // found on packaging are reported as unusable, not as a search.
            formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
          );

  final MobileScannerController _controller;

  @override
  Stream<ProductQrReading> get readings =>
      _controller.barcodes.map((BarcodeCapture capture) {
        final Barcode? value = capture.barcodes.firstOrNull;
        return ProductQrReading(
          rawValue: value?.rawValue ?? '',
          isQrCode: value?.format == BarcodeFormat.qrCode,
        );
      });

  @override
  Future<ProductQrCameraAccess> start() async {
    try {
      await _controller.start();
    } on MobileScannerException catch (error) {
      return switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied => ProductQrCameraAccess.denied,
        _ => ProductQrCameraAccess.unavailable,
      };
    } catch (_) {
      return ProductQrCameraAccess.unavailable;
    }
    if (!_controller.value.hasCameraPermission) {
      return ProductQrCameraAccess.denied;
    }
    return ProductQrCameraAccess.ready;
  }

  @override
  Widget preview(BuildContext context) => MobileScanner(
    key: const ValueKey<String>('qr-scan-preview'),
    controller: _controller,
    errorBuilder: (BuildContext context, MobileScannerException error) =>
        error.errorCode == MobileScannerErrorCode.permissionDenied
        ? const _CameraNotice(
            icon: Icons.no_photography_outlined,
            message:
                'No se permitió el acceso a la cámara. Actívalo en '
                'Ajustes para poder escanear códigos QR.',
          )
        : const _CameraNotice(
            icon: Icons.videocam_off_outlined,
            message: 'La cámara no está disponible en este momento.',
          ),
  );

  @override
  Future<void> dispose() async {
    await _controller.dispose();
  }
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
