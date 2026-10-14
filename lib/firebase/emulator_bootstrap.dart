import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../auth/emulator_session.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/firestore_catalog_repository.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import 'emulator_auth_routing.dart';
import 'emulator_auth_routing_platform.dart';
import 'emulator_auth_routing_preinit.dart';
import 'emulator_platform_stub.dart'
    if (dart.library.io) 'emulator_platform_io.dart'
    as emulator_platform;
import '../movements/administrator_movements.dart';
import 'emulator_correction_gateway.dart';
import 'emulator_product_creation_gateway.dart';
import 'emulator_product_pricing_gateway.dart';
import 'emulator_seller_profile_gateway.dart';
import 'emulator_sale_gateway.dart';
import 'emulator_transfer_gateway.dart';
import 'emulator_stock_intake_gateway.dart';

enum EmulatorClientPlatform { android, ios, web, unsupported }

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

  /// The shared Android and web demo options. iOS uses
  /// [emulatorDemoIosOptions]; call [optionsFor] for a specific platform.
  static const FirebaseOptions sharedOptions = emulatorDemoOptions;

  /// Native iOS FirebaseCore rejects the shared web-format appId at configure
  /// time, so iOS gets an iOS-format appId for the same demo project.
  static FirebaseOptions optionsFor(EmulatorClientPlatform platform) =>
      switch (platform) {
        EmulatorClientPlatform.ios => emulatorDemoIosOptions,
        EmulatorClientPlatform.android ||
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
  );

  @visibleForTesting
  static EmulatorClientPlatform platformFor({
    required bool isWeb,
    required TargetPlatform target,
    required bool isIosSimulator,
  }) {
    if (isWeb) return EmulatorClientPlatform.web;
    return switch (target) {
      TargetPlatform.android => EmulatorClientPlatform.android,
      // Simulator only: a physical device cannot reach the host loopback.
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
      createGateway: () => FirebaseEmulatorSessionGateway(auth),
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
                firestore.useFirestoreEmulator(host, port);
              }),
            );
        return connection.ensureConnected(host, port);
      },
      createCatalog: () {
        final FirebaseFirestoreCatalogReadSource source =
            FirebaseFirestoreCatalogReadSource(firestore);
        final ActiveSessionChecker sessionChecker =
            _firebaseActiveSessionChecker(auth);
        return switch (session.role) {
          InventoryRole.administrator =>
            FirestoreCatalogRepository.administrator(
              source: source,
              session: session,
              sessionChecker: sessionChecker,
            ),
          InventoryRole.seller => FirestoreCatalogRepository.seller(
            source: source,
            session: session,
            sessionChecker: sessionChecker,
          ),
        };
      },
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
                firestore.useFirestoreEmulator(host, port);
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
      createGateway: () => EmulatorProductCreationGateway(
        expectedSession: session,
        sessionChecker: _firebaseActiveSessionChecker(auth),
        invoke: firebaseProductCreationCallable(functions),
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
                firestore.useFirestoreEmulator(host, port);
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
      createGateway: () => EmulatorProductPricingGateway(
        expectedSession: session,
        sessionChecker: _firebaseActiveSessionChecker(auth),
        invoke: firebaseProductPricingCallable(functions),
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
          EmulatorStockIntakeGateway(
            expectedSession: session,
            sessionChecker: _firebaseActiveSessionChecker(auth),
            invoke: firebaseStockIntakeCallable(functions),
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
          EmulatorTransferGateway(
            expectedSession: session,
            sessionChecker: _firebaseActiveSessionChecker(auth),
            invoke: firebaseTransferCallable(functions),
          ),
    );
  }

  /// Seller sale gateway over the `quoteSale` and `submitSale` callables,
  /// wired exactly like stock intake.
  static Future<EmulatorSaleGateway> initializeSaleGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorSaleGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) => createSaleGateway(
        session: session,
        sessionChecker: _firebaseActiveSessionChecker(auth),
        callable: (String name) => firebaseSaleCallable(functions, name),
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
  }) => EmulatorSaleGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    quoteInvoke: callable('quoteSale'),
    submitInvoke: callable('submitSale'),
  );

  /// Seller correction gateway over the sale-correction callables,
  /// wired exactly like the sale gateway.
  static Future<EmulatorCorrectionGateway> initializeCorrectionGateway(
    EmulatorSession session,
  ) {
    return _initializeLiveFunctionsGateway<EmulatorCorrectionGateway>(
      (FirebaseAuth auth, FirebaseFunctions functions) =>
          createCorrectionGateway(
            session: session,
            sessionChecker: _firebaseActiveSessionChecker(auth),
            callable: (String name) => firebaseSaleCallable(functions, name),
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
  }) => EmulatorCorrectionGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    findInvoke: callable('findCorrectableSale'),
    listInvoke: callable('listRecentCorrectableSales'),
    returnInvoke: callable('submitSaleReturn'),
    replacementInvoke: callable('submitSaleReplacement'),
    exchangeInvoke: callable('submitSaleExchange'),
    previewReturnInvoke: callable('previewSaleReturn'),
    previewExchangeInvoke: callable('previewSaleExchange'),
  );

  /// Administrator movements: the Firestore movements and profile reads,
  /// plus the `setSellerProfile` gateway, on one trusted emulator app.
  static Future<AdministratorMovementsBackend> initializeAdministratorMovements(
    EmulatorSession session,
  ) {
    return _initializeLiveFirebase<AdministratorMovementsBackend>((
      FirebaseAuth auth,
      FirebaseFirestore firestore,
      FirebaseFunctions functions,
    ) {
      final ActiveSessionChecker sessionChecker = _firebaseActiveSessionChecker(
        auth,
      );
      return AdministratorMovementsBackend(
        reader: FirestoreMovementRepository(
          source: FirebaseFirestoreMovementReadSource(firestore),
          session: session,
          sessionChecker: sessionChecker,
        ),
        profiles: createSellerProfileGateway(
          session: session,
          sessionChecker: sessionChecker,
          callable: (String name) => firebaseSaleCallable(functions, name),
        ),
      );
    });
  }

  /// Binds the `setSellerProfile` callable by name. Separate from
  /// [initializeAdministratorMovements] so the binding is testable without
  /// Firebase.
  @visibleForTesting
  static EmulatorSellerProfileGateway createSellerProfileGateway({
    required EmulatorSession session,
    required SaleSessionChecker sessionChecker,
    required SaleCallable Function(String name) callable,
  }) => EmulatorSellerProfileGateway(
    expectedSession: session,
    sessionChecker: sessionChecker,
    invoke: callable('setSellerProfile'),
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
                firestore.useFirestoreEmulator(host, port);
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

  static ActiveSessionChecker _firebaseActiveSessionChecker(FirebaseAuth auth) {
    return () async {
      final User? user = auth.currentUser;
      if (user == null) return null;
      final IdTokenResult token = await user.getIdTokenResult(true);
      if (auth.currentUser?.uid != user.uid) return null;
      final Map<String, dynamic>? claims = token.claims;
      if (claims == null) throw const UntrustedSessionException();
      return EmulatorSessionClaims.validate(
        userId: user.uid,
        email: user.email,
        claims: claims.cast<String, Object?>(),
      );
    };
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

  static String _hostFor(EmulatorClientPlatform platform) => switch (platform) {
    EmulatorClientPlatform.android => '10.0.2.2',
    EmulatorClientPlatform.web => '127.0.0.1',
    // The iOS simulator shares the host network stack.
    EmulatorClientPlatform.ios => '127.0.0.1',
    EmulatorClientPlatform.unsupported => throw _unsupportedPlatform(),
  };

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
