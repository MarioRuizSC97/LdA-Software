import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../auth/emulator_session.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/firestore_catalog_repository.dart';

enum EmulatorClientPlatform { android, web, unsupported }

typedef AuthEmulatorConnect = Future<void> Function(String host, int port);
typedef FirestoreEmulatorConnect = Future<void> Function(String host, int port);

class AuthEmulatorConnection {
  AuthEmulatorConnection(this._connect);

  final AuthEmulatorConnect _connect;
  Future<void>? _connectionAttempt;
  String? _host;
  int? _port;

  Future<void> ensureConnected(String host, int port) async {
    if (_host != null) {
      if (_host != host || _port != port) {
        throw StateError('Auth is already configured for another emulator.');
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

class DemoEmulatorBootstrap {
  const DemoEmulatorBootstrap._();

  static const String _appName = 'lda-demo-emulators';
  static final Map<String, AuthEmulatorConnection> _authConnections =
      <String, AuthEmulatorConnection>{};
  static final Map<String, FirestoreEmulatorConnection> _firestoreConnections =
      <String, FirestoreEmulatorConnection>{};

  static const FirebaseOptions options = FirebaseOptions(
    apiKey: 'demo-api-key',
    appId: '1:1234567890:web:demo-lda-inventory',
    messagingSenderId: '1234567890',
    projectId: 'demo-lda-inventory',
    authDomain: 'demo-lda-inventory.firebaseapp.com',
  );

  static EmulatorClientPlatform get currentPlatform {
    if (kIsWeb) return EmulatorClientPlatform.web;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return EmulatorClientPlatform.android;
    }
    return EmulatorClientPlatform.unsupported;
  }

  static Future<EmulatorSessionGateway> start({
    required EmulatorClientPlatform platform,
    required Future<void> Function(FirebaseOptions options) initializeApp,
    required Future<void> Function(String host, int port) connectAuthEmulator,
    required EmulatorSessionGateway Function() createGateway,
  }) async {
    final String host = _hostFor(platform);
    await initializeApp(options);
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
  }) async {
    final String host = _hostFor(platform);
    await initializeApp(options);
    await connectAuthEmulator(host, 9099);
    await connectFirestoreEmulator(host, 8080);
    return createCatalog();
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

  static String _hostFor(EmulatorClientPlatform platform) => switch (platform) {
    EmulatorClientPlatform.android => '10.0.2.2',
    EmulatorClientPlatform.web => '127.0.0.1',
    EmulatorClientPlatform.unsupported => throw UnsupportedError(
      'Local Firebase emulators are supported only on Android and web.',
    ),
  };

  static Future<FirebaseApp> _initializeTrustedApp(
    FirebaseOptions explicitOptions,
  ) async {
    FirebaseApp? existing;
    for (final FirebaseApp candidate in Firebase.apps) {
      if (candidate.name == _appName) existing = candidate;
    }
    final FirebaseApp app =
        existing ??
        await Firebase.initializeApp(name: _appName, options: explicitOptions);
    if (app.name != _appName ||
        app.options.projectId != options.projectId ||
        app.options.appId != options.appId ||
        app.options.apiKey != options.apiKey) {
      throw StateError('The local emulator Firebase app is not trusted.');
    }
    return app;
  }
}
