import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/firebase/emulator_auth_routing_preinit.dart';
import 'package:lda_inventory/firebase/production_bootstrap.dart';
import 'package:lda_inventory/firebase_options.dart';

void main() {
  group('production app start', productionAppStartTests);

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

class _FakeApp extends Fake implements FirebaseApp {}

void productionAppStartTests() {
  tearDown(ProductionFirebaseBootstrap.resetForTesting);

  test('concurrent loads share one start', () async {
    int starts = 0;
    final Completer<FirebaseApp> pending = Completer<FirebaseApp>();
    ProductionFirebaseBootstrap.createApp = () {
      starts++;
      return pending.future;
    };
    final Future<FirebaseApp> first =
        ProductionFirebaseBootstrap.initializeApp();
    final Future<FirebaseApp> second =
        ProductionFirebaseBootstrap.initializeApp();
    final FirebaseApp app = _FakeApp();
    pending.complete(app);
    expect(await first, same(app));
    expect(await second, same(app));
    expect(starts, 1);
  });

  test('a failed start is retried on the next load', () async {
    int starts = 0;
    final FirebaseApp app = _FakeApp();
    ProductionFirebaseBootstrap.createApp = () async {
      starts++;
      if (starts == 1) throw StateError('offline');
      return app;
    };
    await expectLater(
      ProductionFirebaseBootstrap.initializeApp(),
      throwsStateError,
    );
    expect(await ProductionFirebaseBootstrap.initializeApp(), same(app));
    expect(starts, 2);
  });

  test('an existing production app with other options is refused', () {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      ProductionFirebaseBootstrap.verifyExistingOptions(
        ProductionFirebaseBootstrap.options,
      );
      expect(
        () => ProductionFirebaseBootstrap.verifyExistingOptions(
          emulatorDemoOptions,
        ),
        throwsStateError,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
