import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../auth/emulator_session.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import '../catalog/product_rename.dart';
import 'emulator_auth_routing.dart';
import 'emulator_auth_routing_platform.dart';
import 'emulator_auth_routing_preinit.dart';
import 'emulator_platform_stub.dart'
    if (dart.library.io) 'emulator_platform_io.dart'
    as emulator_platform;
import '../movements/administrator_movements.dart';
import '../transfers/transfer_notice_controller.dart';
import 'emulator_correction_gateway.dart';
import 'emulator_seller_profile_gateway.dart';
import 'emulator_sale_gateway.dart';
import 'emulator_transfer_gateway.dart';
import 'emulator_stock_intake_gateway.dart';
import 'live_firebase_gateways.dart';

/// Where the app runs relative to the host's local emulators.
///
/// [androidUsbDevice] is a physical Android device whose emulator ports are
/// forwarded to the host with `adb reverse`, so it reaches them on its own
/// loopback instead of the Android emulator's 10.0.2.2 alias.
/// [iosLanDevice] is an iPhone (or, for verification, the simulator) that
/// reaches the emulators through the host's private LAN address, because a
/// physical iPhone has no `adb reverse` equivalent.
enum EmulatorClientPlatform {
  android,
  androidUsbDevice,
  ios,
  iosLanDevice,
  web,
  unsupported,
}

/// Opt-in for [EmulatorClientPlatform.androidUsbDevice]; off by default.
const bool _androidUsbReverse = bool.fromEnvironment('LDA_ANDROID_USB_REVERSE');

/// Opt-in for [EmulatorClientPlatform.iosLanDevice]: the host's private LAN
/// IPv4 address. Empty by default.
const String _iosLanHostDefine = String.fromEnvironment(
  'LDA_IOS_EMULATOR_HOST',
);

/// 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16 only.
final RegExp _privateIpv4 = RegExp(
  r'^(?:10\.(?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3})'
  r'|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3})\.(?:\d{1,3})'
  r'|192\.168\.(?:\d{1,3})\.(?:\d{1,3}))$',
);

typedef AuthEmulatorConnect = Future<void> Function(String host, int port);
typedef FirestoreEmulatorConnect = Future<void> Function(String host, int port);
typedef FunctionsEmulatorConnect = Future<void> Function(String host, int port);

class AuthEmulatorConnection {
  AuthEmulatorConnection(
    AuthEmulatorConnect connect, {
    String appName = emulatorDemoAppName,
    void Function(String host, int port)? verify,
  }) {
    final WebAuthEmulatorRouting? routing = webAuthEmulatorRouting(
      appName: appName,
      connect: connect,
    );
    _connect = routing?.ensureConnected ?? connect;
    _verify = verify ?? routing?.verify;
  }

  late final AuthEmulatorConnect _connect;
  late final void Function(String host, int port)? _verify;
  Future<void>? _connectionAttempt;
  String? _host;
  int? _port;

  Future<void> ensureConnected(String host, int port) async {
    if (_host != null) {
      if (_host != host || _port != port) {
        throw StateError('Auth is already configured for another emulator.');
      }
      _verify?.call(host, port);
      return;
    }

    final Future<void>? inProgress = _connectionAttempt;
    if (inProgress != null) {
      await inProgress;
      return ensureConnected(host, port);
    }

    final Future<void> attempt = _connect(host, port);
    _connectionAttempt = attempt;
    try {
      await attempt;
      _verify?.call(host, port);
      _host = host;
      _port = port;
    } finally {
      _connectionAttempt = null;
    }
  }
}

class FirestoreEmulatorConnection {
  FirestoreEmulatorConnection(this._connect);

  final FirestoreEmulatorConnect _connect;
  Future<void>? _connectionAttempt;
  String? _host;
  int? _port;

  Future<void> ensureConnected(String host, int port) async {
    if (_host != null) {
      if (_host != host || _port != port) {
        throw StateError(
          'Firestore is already configured for another emulator.',
        );
      }
      return;
    }
    final Future<void>? inProgress = _connectionAttempt;
    if (inProgress != null) {
      await inProgress;
      return ensureConnected(host, port);
    }

    final Future<void> attempt = _connect(host, port);
    _connectionAttempt = attempt;
    try {
      await attempt;
      _host = host;
      _port = port;
    } finally {
      _connectionAttempt = null;
    }
  }
}

class FunctionsEmulatorConnection {
  FunctionsEmulatorConnection(this._connect);

  final FunctionsEmulatorConnect _connect;
  Future<void>? _connectionAttempt;
  String? _host;
  int? _port;

  Future<void> ensureConnected(String host, int port) async {
    if (_host != null) {
      if (_host != host || _port != port) {
        throw StateError(
          'Functions is already configured for another emulator.',
        );
      }
      return;
    }
    final Future<void>? inProgress = _connectionAttempt;
    if (inProgress != null) {
      await inProgress;
      return ensureConnected(host, port);
    }

    final Future<void> attempt = _connect(host, port);
    _connectionAttempt = attempt;
    try {
      await attempt;
      _host = host;
      _port = port;
    } finally {
      _connectionAttempt = null;
    }
  }
}

class DemoEmulatorBootstrap {
  const DemoEmulatorBootstrap._();

  static const String _appName = emulatorDemoAppName;
  static final Map<String, AuthEmulatorConnection> _authConnections =
      <String, AuthEmulatorConnection>{};
  static final Map<String, FirestoreEmulatorConnection> _firestoreConnections =
      <String, FirestoreEmulatorConnection>{};
  static final Map<String, FunctionsEmulatorConnection> _functionsConnections =
      <String, FunctionsEmulatorConnection>{};

  /// The web demo options. iOS uses [emulatorDemoIosOptions] and Android
  /// [emulatorDemoAndroidOptions]; call [optionsFor] for a specific platform.
  static const FirebaseOptions sharedOptions = emulatorDemoOptions;

  /// Native iOS FirebaseCore rejects the shared web-format appId at configure
  /// time, so iOS gets an iOS-format appId for the same demo project.
  static FirebaseOptions optionsFor(EmulatorClientPlatform platform) =>
      switch (platform) {
        EmulatorClientPlatform.ios ||
        EmulatorClientPlatform.iosLanDevice => emulatorDemoIosOptions,
        EmulatorClientPlatform.android ||
        EmulatorClientPlatform.androidUsbDevice => emulatorDemoAndroidOptions,
        EmulatorClientPlatform.web => emulatorDemoOptions,
        EmulatorClientPlatform.unsupported => throw _unsupportedPlatform(),
      };

  /// The iOS simulator probe [currentPlatform] asks. Tests may replace it to
  /// prove the wiring and must restore it; production never reassigns it.
  @visibleForTesting
  static bool Function() iosSimulatorProbe = emulator_platform.isIosSimulator;

  static EmulatorClientPlatform get currentPlatform => platformFor(
    isWeb: kIsWeb,
    target: defaultTargetPlatform,
    isIosSimulator: !kIsWeb && iosSimulatorProbe(),
    androidUsbReverse: _androidUsbReverse,
    iosLanHost: iosLanHost,
  );

  /// The host's private LAN address for [EmulatorClientPlatform.iosLanDevice].
  /// Tests may replace it and must restore it; production never reassigns it.
  @visibleForTesting
  static String iosLanHost = _iosLanHostDefine;

  @visibleForTesting
  static EmulatorClientPlatform platformFor({
    required bool isWeb,
    required TargetPlatform target,
    required bool isIosSimulator,
    bool androidUsbReverse = false,
    String iosLanHost = '',
  }) {
    if (isWeb) return EmulatorClientPlatform.web;
    return switch (target) {
      TargetPlatform.android when androidUsbReverse =>
        EmulatorClientPlatform.androidUsbDevice,
      TargetPlatform.android => EmulatorClientPlatform.android,
      // Simulator only: a physical device cannot reach the host loopback.
      TargetPlatform.iOS when iosLanHost.isNotEmpty =>
        EmulatorClientPlatform.iosLanDevice,
      TargetPlatform.iOS when isIosSimulator => EmulatorClientPlatform.ios,
      _ => EmulatorClientPlatform.unsupported,
    };
  }

  static Future<EmulatorSessionGateway> start({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required EmulatorSessionGateway Function() createGateway,
    Future<void> Function()? prepareWebAuth,
  }) async {
    final String host = _hostFor(platform);
    await _prepareWebAuth(platform, prepareWebAuth);
    await initializeApp(optionsFor(platform));
    await connectAuthEmulator(host, 9099);
    return createGateway();
  }

  static Future<T> startCatalog<T>({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required Future<void> Function(String host, int port)
    connectFirestoreEmulator,
    required T Function() createCatalog,
    Future<void> Function()? prepareWebAuth,
  }) async {
    final String host = _hostFor(platform);
    await _prepareWebAuth(platform, prepareWebAuth);
    await initializeApp(optionsFor(platform));
    await connectAuthEmulator(host, 9099);
    await connectFirestoreEmulator(host, 8080);
    return createCatalog();
  }

  static Future<T> startProductCreation<T>({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required Future<void> Function(String host, int port)
    connectFirestoreEmulator,
    required Future<void> Function(String host, int port)
    connectFunctionsEmulator,
    required T Function() createGateway,
    Future<void> Function()? prepareWebAuth,
  }) async {
    final String host = _hostFor(platform);
    await _prepareWebAuth(platform, prepareWebAuth);
    await initializeApp(optionsFor(platform));
    await connectAuthEmulator(host, 9099);
    await connectFirestoreEmulator(host, 8080);
    await connectFunctionsEmulator(host, 5001);
    return createGateway();
  }

  static Future<T> startProductPricing<T>({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required Future<void> Function(String host, int port)
    connectFirestoreEmulator,
    required Future<void> Function(String host, int port)
    connectFunctionsEmulator,
    required T Function() createGateway,
    Future<void> Function()? prepareWebAuth,
  }) async {
    final String host = _hostFor(platform);
    await _prepareWebAuth(platform, prepareWebAuth);
    await initializeApp(optionsFor(platform));
    await connectAuthEmulator(host, 9099);
    await connectFirestoreEmulator(host, 8080);
    await connectFunctionsEmulator(host, 5001);
    return createGateway();
  }

  static Future<EmulatorSessionGateway> initialize() async {
    late FirebaseApp app;
    late FirebaseAuth auth;
    return start(
      platform: currentPlatform,
      initializeApp: (FirebaseOptions explicitOptions) async {
        app = await _initializeTrustedApp(explicitOptions);
        auth = FirebaseAuth.instanceFor(app: app);
      },
      connectAuthEmulator: (String host, int port) {
        final AuthEmulatorConnection connection = _authConnections.putIfAbsent(
          app.name,
          () => AuthEmulatorConnection(
            (String emulatorHost, int emulatorPort) => auth.useAuthEmulator(
              emulatorHost,
              emulatorPort,
              automaticHostMapping: false,
            ),
          ),
        );
        return connection.ensureConnected(host, port);
      },
      createGateway: () => LiveFirebaseGateways.session(auth),
    );
  }

  static Future<RoleScopedCatalogRepository> initializeCatalogRepository(
    EmulatorSession session,
  ) async {
    late FirebaseApp app;
    late FirebaseAuth auth;
    late FirebaseFirestore firestore;
    return startCatalog<RoleScopedCatalogRepository>(
      platform: currentPlatform,
      initializeApp: (FirebaseOptions explicitOptions) async {
        app = await _initializeTrustedApp(explicitOptions);
        auth = FirebaseAuth.instanceFor(app: app);
        firestore = FirebaseFirestore.instanceFor(app: app);
      },
      connectAuthEmulator: (String host, int port) {
        final AuthEmulatorConnection connection = _authConnections.putIfAbsent(
          app.name,
          () => AuthEmulatorConnection(
            (String emulatorHost, int emulatorPort) => auth.useAuthEmulator(
              emulatorHost,
              emulatorPort,
              automaticHostMapping: false,
            ),
          ),
        );
        return connection.ensureConnected(host, port);
      },
      connectFirestoreEmulator: (String host, int port) {
        final FirestoreEmulatorConnection connection = _firestoreConnections
            .putIfAbsent(
              app.name,
              () => FirestoreEmulatorConnection((String host, int port) async {
                // The bootstrap already chose the per-platform host; the
                // SDK's own Android remap would undo the USB device route.
                firestore.useFirestoreEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      createCatalog: () => LiveFirebaseGateways.catalog(
        auth: auth,
        firestore: firestore,
        session: session,
      ),
    );
  }

  static Future<ProductCreationGateway> initializeProductCreationGateway(
    EmulatorSession session,
  ) async {
    late FirebaseApp app;
    late FirebaseAuth auth;
    late FirebaseFirestore firestore;
    late FirebaseFunctions functions;
    return startProductCreation<ProductCreationGateway>(
      platform: currentPlatform,
      initializeApp: (FirebaseOptions explicitOptions) async {
        app = await _initializeTrustedApp(explicitOptions);
        auth = FirebaseAuth.instanceFor(app: app);
        firestore = FirebaseFirestore.instanceFor(app: app);
        functions = FirebaseFunctions.instanceFor(
          app: app,
          region: 'us-south1',
        );
      },
      connectAuthEmulator: (String host, int port) {
        final AuthEmulatorConnection connection = _authConnections.putIfAbsent(
          app.name,
          () => AuthEmulatorConnection(
            (String emulatorHost, int emulatorPort) => auth.useAuthEmulator(
              emulatorHost,
              emulatorPort,
              automaticHostMapping: false,
            ),
          ),
        );
        return connection.ensureConnected(host, port);
      },
      connectFirestoreEmulator: (String host, int port) {
        final FirestoreEmulatorConnection connection = _firestoreConnections
            .putIfAbsent(
              app.name,
              () => FirestoreEmulatorConnection((String host, int port) async {
                // The bootstrap already chose the per-platform host; the
                // SDK's own Android remap would undo the USB device route.
                firestore.useFirestoreEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      connectFunctionsEmulator: (String host, int port) {
        final String key = '${app.name}|us-south1';
        final FunctionsEmulatorConnection connection = _functionsConnections
            .putIfAbsent(
              key,
              () => FunctionsEmulatorConnection((String host, int port) async {
                functions.useFunctionsEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      createGateway: () => LiveFirebaseGateways.productCreation(
        auth: auth,
        functions: functions,
        session: session,
      ),
    );
  }

  static Future<ProductPricingGateway> initializeProductPricingGateway(
    EmulatorSession session,
  ) async {
    late FirebaseApp app;
    late FirebaseAuth auth;
    late FirebaseFirestore firestore;
    late FirebaseFunctions functions;
    return startProductPricing<ProductPricingGateway>(
      platform: currentPlatform,
      initializeApp: (FirebaseOptions explicitOptions) async {
        app = await _initializeTrustedApp(explicitOptions);
        auth = FirebaseAuth.instanceFor(app: app);
        firestore = FirebaseFirestore.instanceFor(app: app);
        functions = FirebaseFunctions.instanceFor(
          app: app,
          region: 'us-south1',
        );
      },
      connectAuthEmulator: (String host, int port) {
        final AuthEmulatorConnection connection = _authConnections.putIfAbsent(
          app.name,
          () => AuthEmulatorConnection(
            (String emulatorHost, int emulatorPort) => auth.useAuthEmulator(
              emulatorHost,
              emulatorPort,
              automaticHostMapping: false,
            ),
          ),
        );
        return connection.ensureConnected(host, port);
      },
      connectFirestoreEmulator: (String host, int port) {
        final FirestoreEmulatorConnection connection = _firestoreConnections
            .putIfAbsent(
              app.name,
              () => FirestoreEmulatorConnection((String host, int port) async {
                // The bootstrap already chose the per-platform host; the
                // SDK's own Android remap would undo the USB device route.
                firestore.useFirestoreEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      connectFunctionsEmulator: (String host, int port) {
        final String key = '${app.name}|us-south1';
        final FunctionsEmulatorConnection connection = _functionsConnections
            .putIfAbsent(
              key,
              () => FunctionsEmulatorConnection((String host, int port) async {
                functions.useFunctionsEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      createGateway: () => LiveFirebaseGateways.productPricing(
        auth: auth,
        functions: functions,
        session: session,
      ),
    );
  }

  static Future<T> startStockIntake<T>({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required Future<void> Function(String host, int port)
    connectFirestoreEmulator,
    required Future<void> Function(String host, int port)
    connectFunctionsEmulator,
    required T Function() createGateway,
    Future<void> Function()? prepareWebAuth,
  }) async {
    final String host = _hostFor(platform);
    await _prepareWebAuth(platform, prepareWebAuth);
    await initializeApp(optionsFor(platform));
    await connectAuthEmulator(host, 9099);
    await connectFirestoreEmulator(host, 8080);
    await connectFunctionsEmulator(host, 5001);
    return createGateway();
  }

  static Future<EmulatorStockIntakeGateway> initializeStockIntakeGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorStockIntakeGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          LiveFirebaseGateways.stockIntake(
            auth: auth,
            functions: functions,
            session: session,
          ),
    );
  }

  /// Administrator product rename over the `renameProduct` callable, wired
  /// exactly like stock intake: lazily on submit, no startup read, no extra
  /// service, and no new Firebase app. The callable instance is bound to the
  /// bootstrap-created Functions for region us-south1, never the default
  /// singleton.
  static Future<ProductRenameGateway> initializeProductRenameGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<ProductRenameGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          LiveFirebaseGateways.productRename(
            auth: auth,
            functions: functions,
            session: session,
          ),
    );
  }

  /// Branch-less administrator transfer gateway over the `transferInventory`
  /// callable, wired exactly like stock intake. It is created lazily on submit
  /// only: no startup read, no extra service, and no new Firebase app.
  static Future<EmulatorTransferGateway> initializeTransferGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorTransferGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          LiveFirebaseGateways.transfer(
            auth: auth,
            functions: functions,
            session: session,
          ),
    );
  }

  /// Seller transfer-destination notice backend over the already-connected
  /// trusted emulator Firestore (named app, never the default cloud instance)
  /// and the `markTransferNoticeRead` callable in region us-south1, wired
  /// exactly like the other live gateways. Seller-only: an administrator or
  /// branch-less session is refused before any SDK work, so only exact seller
  /// sessions ever load this backend.
  static Future<TransferNoticeBackend> initializeTransferNoticeBackend(
    EmulatorSession session,
  ) {
    LiveFirebaseGateways.requireNoticeSeller(session);
    return _initializeLiveFirebase<TransferNoticeBackend>(
      (
        FirebaseAuth auth,
        FirebaseFirestore firestore,
        FirebaseFunctions functions,
      ) => LiveFirebaseGateways.transferNotices(
        firestore: firestore,
        functions: functions,
        session: session,
      ),
    );
  }

  /// Seller sale gateway over the `quoteSale` and `submitSale` callables,
  /// wired exactly like stock intake.
  static Future<EmulatorSaleGateway> initializeSaleGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorSaleGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          LiveFirebaseGateways.sale(
            auth: auth,
            functions: functions,
            session: session,
          ),
    );
  }

  /// Binds the `quoteSale` and `submitSale` callables by name. Separate from
  /// [initializeSaleGateway] so the binding is testable without Firebase.
  @visibleForTesting
  static EmulatorSaleGateway createSaleGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => LiveFirebaseGateways.saleGateway(
    session: session,
    sessionChecker: sessionChecker,
    callable: callable,
  );

  /// Seller correction gateway over the sale-correction callables,
  /// wired exactly like the sale gateway.
  static Future<EmulatorCorrectionGateway> initializeCorrectionGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorCorrectionGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          LiveFirebaseGateways.correction(
            auth: auth,
            functions: functions,
            session: session,
          ),
    );
  }

  /// Binds `findCorrectableSale`, `listRecentCorrectableSales`,
  /// `submitSaleReturn`, `submitSaleReplacement`, `submitSaleExchange`,
  /// `previewSaleReturn` and `previewSaleExchange` by name. Separate from
  /// [initializeCorrectionGateway] so the binding is testable without
  /// Firebase.
  @visibleForTesting
  static EmulatorCorrectionGateway createCorrectionGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => LiveFirebaseGateways.correctionGateway(
    session: session,
    sessionChecker: sessionChecker,
    callable: callable,
  );

  /// Administrator movements: the Firestore movements and profile reads,
  /// plus the `setSellerProfile` gateway, on one trusted emulator app.
  static Future<AdministratorMovementsBackend> initializeAdministratorMovements(
    EmulatorSession session,
  ) {
    return _initializeLiveFirebase<AdministratorMovementsBackend>(
      (
        FirebaseAuth auth,
        FirebaseFirestore firestore,
        FirebaseFunctions functions,
      ) => LiveFirebaseGateways.administratorMovements(
        auth: auth,
        firestore: firestore,
        functions: functions,
        session: session,
      ),
    );
  }

  /// Binds the `setSellerProfile` callable by name. Separate from
  /// [initializeAdministratorMovements] so the binding is testable without
  /// Firebase.
  @visibleForTesting
  static EmulatorSellerProfileGateway createSellerProfileGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => LiveFirebaseGateways.sellerProfileGateway(
    session: session,
    sessionChecker: sessionChecker,
    callable: callable,
  );

  static Future<T> _initializeLiveFunctionsGateway<T>(
    T Function(FirebaseAuth auth, FirebaseFunctions functions) create,
  ) => _initializeLiveFirebase<T>(
    (FirebaseAuth auth, FirebaseFirestore _, FirebaseFunctions functions) =>
        create(auth, functions),
  );

  static Future<T> _initializeLiveFirebase<T>(
    T Function(
      FirebaseAuth auth,
      FirebaseFirestore firestore,
      FirebaseFunctions functions,
    )
    create,
  ) async {
    late FirebaseApp app;
    late FirebaseAuth auth;
    late FirebaseFirestore firestore;
    late FirebaseFunctions functions;
    return startStockIntake<T>(
      platform: currentPlatform,
      initializeApp: (FirebaseOptions explicitOptions) async {
        app = await _initializeTrustedApp(explicitOptions);
        auth = FirebaseAuth.instanceFor(app: app);
        firestore = FirebaseFirestore.instanceFor(app: app);
        functions = FirebaseFunctions.instanceFor(
          app: app,
          region: 'us-south1',
        );
      },
      connectAuthEmulator: (String host, int port) {
        final AuthEmulatorConnection connection = _authConnections.putIfAbsent(
          app.name,
          () => AuthEmulatorConnection(
            (String emulatorHost, int emulatorPort) => auth.useAuthEmulator(
              emulatorHost,
              emulatorPort,
              automaticHostMapping: false,
            ),
          ),
        );
        return connection.ensureConnected(host, port);
      },
      connectFirestoreEmulator: (String host, int port) {
        final FirestoreEmulatorConnection connection = _firestoreConnections
            .putIfAbsent(
              app.name,
              () => FirestoreEmulatorConnection((String host, int port) async {
                // The bootstrap already chose the per-platform host; the
                // SDK's own Android remap would undo the USB device route.
                firestore.useFirestoreEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      connectFunctionsEmulator: (String host, int port) {
        final String key = '${app.name}|us-south1';
        final FunctionsEmulatorConnection connection = _functionsConnections
            .putIfAbsent(
              key,
              () => FunctionsEmulatorConnection((String host, int port) async {
                functions.useFunctionsEmulator(
                  host,
                  port,
                  automaticHostMapping: false,
                );
              }),
            );
        return connection.ensureConnected(host, port);
      },
      createGateway: () => create(auth, firestore, functions),
    );
  }

  static Future<void> _prepareWebAuth(
    EmulatorClientPlatform platform,
    Future<void> Function()? prepare,
  ) async {
    if (platform == EmulatorClientPlatform.web) {
      await (prepare ??
          () => prepareWebAuthEmulator(
            appName: _appName,
            options: sharedOptions,
          ))();
    }
  }

  static String _hostFor(EmulatorClientPlatform platform) => hostFor(platform);

  /// The emulator host for [platform]. The iOS LAN route accepts only a
  /// private IPv4 address and otherwise fails closed before any connection.
  @visibleForTesting
  static String hostFor(
    EmulatorClientPlatform platform, {
    String? iosLanHost,
  }) => switch (platform) {
    EmulatorClientPlatform.android => '10.0.2.2',
    // `adb reverse` forwards each emulator port from the device loopback.
    EmulatorClientPlatform.androidUsbDevice => '127.0.0.1',
    EmulatorClientPlatform.web => '127.0.0.1',
    // The iOS simulator shares the host network stack.
    EmulatorClientPlatform.ios => '127.0.0.1',
    EmulatorClientPlatform.iosLanDevice => _privateLanHost(
      iosLanHost ?? DemoEmulatorBootstrap.iosLanHost,
    ),
    EmulatorClientPlatform.unsupported => throw _unsupportedPlatform(),
  };

  static String _privateLanHost(String host) {
    final bool octetsValid = host
        .split('.')
        .every((String octet) => (int.tryParse(octet) ?? 256) <= 255);
    if (!_privateIpv4.hasMatch(host) || !octetsValid) {
      throw UnsupportedError(
        'LDA_IOS_EMULATOR_HOST must be a private LAN IPv4 address.',
      );
    }
    return host;
  }

  static UnsupportedError _unsupportedPlatform() => UnsupportedError(
    'Local Firebase emulators are supported only on Android, iOS and web.',
  );

  static Future<FirebaseApp> _initializeTrustedApp(
    FirebaseOptions explicitOptions,
  ) async {
    FirebaseApp? existing;
    for (final FirebaseApp candidate in Firebase.apps) {
      if (candidate.name == _appName) existing = candidate;
    }
    // Web preinitialization creates the JS app, not FlutterFire's per-app
    // plugin initialization. Run that initialization with identical options
    // only after the synchronous local Auth route has been verified.
    final FirebaseApp app =
        currentPlatform == EmulatorClientPlatform.web || existing == null
        ? await Firebase.initializeApp(name: _appName, options: explicitOptions)
        : existing;
    verifyTrustedApp(
      platform: currentPlatform,
      appName: app.name,
      explicitOptions: explicitOptions,
      appOptions: app.options,
    );
    return app;
  }

  @visibleForTesting
  static void verifyTrustedApp({
    required EmulatorClientPlatform platform,
    required String appName,
    required FirebaseOptions explicitOptions,
    required FirebaseOptions appOptions,
  }) {
    final FirebaseOptions trusted = optionsFor(platform);
    if (appName != _appName ||
        explicitOptions != trusted ||
        appOptions.projectId != trusted.projectId ||
        appOptions.appId != trusted.appId ||
        appOptions.apiKey != trusted.apiKey) {
      throw StateError('The local emulator Firebase app is not trusted.');
    }
  }
}
