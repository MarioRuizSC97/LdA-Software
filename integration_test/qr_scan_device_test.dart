// Camera scan on a physical device, with the local emulators NOT required.
//
// Proves the two things a unit test cannot reach, because they live in the
// plugin against a real camera:
//
//   1. the preview mounts and starts. This is the H1 deadlock: the sheet used
//      to call start() before the MobileScanner widget existed, and the
//      controller only attaches from that widget, so on hardware the camera
//      never opened and the sheet reported "no camera";
//   2. cancelling really closes the sheet and releases the camera.
//
// The camera permission must already be granted, otherwise the sheet shows the
// denied state by design:
//
//   adb shell pm grant com.ldasoftware.lda_inventory android.permission.CAMERA
//
// Run it against a connected device or simulator with a camera:
//
//   flutter test integration_test/qr_scan_device_test.dart -d <device-id>
//
// The second test decodes a code a human has to aim at, so it is opt-in: it
// only runs with -Dart-define=LDA_CAMERA_DETECTION=true while somebody holds
// a product QR in front of the camera. Its QR page is generated with the
// project's own ProductQr payload (see odd/tasks/v1-0-ui-t7-qr-scan.md, L25).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lda_inventory/catalog/product_qr_scan.dart';

/// Pumps frames until any of [finders] matches or about 40 seconds pass.
///
/// Used where several outcomes are valid, so the test then asserts which one
/// actually happened instead of racing a fixed delay.
Future<void> _pumpUntilAny(WidgetTester tester, List<Finder> finders) async {
  for (int i = 0; i < 160; i++) {
    if (finders.any((Finder finder) => finder.evaluate().isNotEmpty)) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Pumps frames until [finder] matches or about 40 seconds pass.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 160 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the scanner opens a real preview and cancels cleanly',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('open-scanner'),
                  onPressed: () => showProductQrScanner(context),
                  child: const Text('Escanear'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('open-scanner')));
      await tester.pump(const Duration(milliseconds: 600));

      // Wait for an outcome, not for the preview: the preview is in the tree
      // from the first frame, so waiting for it proves nothing about the
      // camera. Within about 40 seconds one of three things has to show up,
      // and the assertions below say which one it was.
      await _pumpUntilAny(tester, <Finder>[
        find.textContaining('Coloca el código QR'),
        find.byKey(const ValueKey<String>('qr-scan-denied')),
        find.byKey(const ValueKey<String>('qr-scan-unavailable')),
      ]);

      expect(
        find.byKey(const ValueKey<String>('qr-scan-preview')),
        findsOneWidget,
        reason: 'the preview must mount and start the camera (H1 regression)',
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-denied')),
        findsNothing,
        reason: 'the camera permission was granted before the run',
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-unavailable')),
        findsNothing,
        reason: 'a device with a camera must not report it as missing',
      );
      expect(find.textContaining('Coloca el código QR'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no exception while live');

      await tester.tap(find.byKey(const ValueKey<String>('qr-scan-cancel')));
      await tester.pumpAndSettle();

      expect(find.text('Escanear código QR'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('open-scanner')),
        findsOneWidget,
        reason: 'the scanner is gone and the app behind it still works',
      );
      expect(tester.takeException(), isNull, reason: 'no exception on close');
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !productQrScanSupported,
  );

  testWidgets(
    'a product QR held to the camera is decoded and closes the sheet',
    (WidgetTester tester) async {
      String? scanned;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('open-scanner-detect'),
                  onPressed: () async {
                    scanned = await showProductQrScanner(context);
                  },
                  child: const Text('Escanear'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('open-scanner-detect')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('qr-scan-preview')),
      );
      expect(
        find.byKey(const ValueKey<String>('qr-scan-preview')),
        findsOneWidget,
        reason: 'the camera has to be running before aiming a code at it',
      );

      // A human holds the QR in front of the lens; the sheet pops once the
      // plugin decodes it and the opener future resolves with the payload.
      final Stopwatch watch = Stopwatch()..start();
      while (scanned == null &&
          watch.elapsed < const Duration(seconds: 60) &&
          find
              .byKey(const ValueKey<String>('qr-scan-preview'))
              .evaluate()
              .isNotEmpty) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        scanned,
        isNotNull,
        reason: 'no QR was decoded within the window (nobody aimed a code)',
      );
      expect(
        scanned,
        'PRD-COFFEE-001',
        reason: 'the payload must be the product code the search matches',
      );
      // The pop is already requested and the payload is in hand, but the sheet
      // stays in the tree until the route finishes animating out. Wait for it
      // instead of sampling after a fixed delay.
      final Stopwatch closing = Stopwatch()..start();
      while (find.text('Escanear código QR').evaluate().isNotEmpty &&
          closing.elapsed < const Duration(seconds: 10)) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Escanear código QR'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip:
        !productQrScanSupported ||
        !const bool.fromEnvironment('LDA_CAMERA_DETECTION'),
  );
}
