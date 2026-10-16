import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/firebase/emulator_auth_routing_preinit.dart';
import 'package:lda_inventory/firebase/production_bootstrap.dart';
import 'package:lda_inventory/firebase_options.dart';

void main() {
  test('production uses the real project options for each app platform', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      try {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          ProductionFirebaseBootstrap.options,
          DefaultFirebaseOptions.currentPlatform,
          reason: platform.name,
        );
        expect(
          ProductionFirebaseBootstrap.options.projectId,
          'lda-inventory-dev-mx',
          reason: platform.name,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });

  test('production never shares the emulator app or its demo project', () {
    expect(ProductionFirebaseBootstrap.appName, isNot(emulatorDemoAppName));
    expect(ProductionFirebaseBootstrap.appName, isNotEmpty);
    expect(
      ProductionFirebaseBootstrap.options.projectId,
      isNot(emulatorDemoOptions.projectId),
    );
    expect(ProductionFirebaseBootstrap.functionsRegion, 'us-south1');
  });

  test('desktop targets fail closed before touching Firebase', () {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(() => ProductionFirebaseBootstrap.options, throwsUnsupportedError);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
