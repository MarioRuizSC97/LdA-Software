import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:firebase_core/firebase_core.dart';

import 'emulator_auth_routing.dart';
import 'emulator_auth_routing_preinit.dart';

// Same modular CDN paths/version as firebase_core_web 3.12.0. Importing
// modules registers components; it does not create an app or initialize Auth.
const _sdkVersion = emulatorDemoSdkVersion;
const _modules = <String, String>{
  'firebase_core': 'app',
  'firebase_auth': 'auth',
  'firebase_firestore': 'firestore-pipelines',
  'firebase_functions': 'functions',
};

// Dart's importModule uses native import(): no eval, injected script, temporary
// global callback, or unresolved callback future on a rejected module import.
@JS('window.sessionStorage')
external _Storage get _sessionStorage;

extension type _CoreModule(JSObject _) implements JSObject {
  external JSArray<_App> getApps();
  external _App initializeApp(_Options options, JSString name);
}

extension type _AuthModule(JSObject _) implements JSObject {
  external _Auth initializeAuth(_App app, _Dependencies dependencies);
  external void connectAuthEmulator(_Auth auth, JSString origin);
  external JSObject get debugErrorMap;
  external JSObject get indexedDBLocalPersistence;
  external JSObject get browserLocalPersistence;
  external JSObject get browserSessionPersistence;
  external JSObject get browserPopupRedirectResolver;
}

extension type _App(JSObject _) implements JSObject {
  external JSString get name;
  external _Options get options;
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({
    JSString? apiKey,
    JSString? appId,
    JSString? messagingSenderId,
    JSString? projectId,
    JSString? authDomain,
    JSString? databaseURL,
    JSString? storageBucket,
    JSString? measurementId,
  });
  external JSString? get apiKey;
  external JSString? get appId;
  external JSString? get messagingSenderId;
  external JSString? get projectId;
  external JSString? get authDomain;
  external JSString? get databaseURL;
  external JSString? get storageBucket;
  external JSString? get measurementId;
}

extension type _Dependencies._(JSObject _) implements JSObject {
  external factory _Dependencies({
    required JSObject errorMap,
    required JSArray<JSObject> persistence,
    required JSObject popupRedirectResolver,
  });
}

extension type _Auth(JSObject _) implements JSObject {
  external _App get app;
  external _Config? get emulatorConfig;
}

extension type _Config(JSObject _) implements JSObject {
  external JSString get protocol;
  external JSString get host;
  external JSNumber? get port;
}

extension type _Storage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void removeItem(JSString key);
}

Map<String, JSObject> _loadedModules = {};
_CoreModule? _core;
_AuthModule? _authModule;
_App? _ownedApp;
_Auth? _ownedAuth;

void _requireFunction(JSObject module, String name) {
  final value = module.getProperty<JSAny?>(name.toJS);
  if (value == null || !value.typeofEquals('function')) {
    throw StateError('A required Firebase SDK export is unavailable.');
  }
}

Future<void> _loadModules() async {
  final override = globalContext.getProperty<JSAny?>(
    'flutterfire_web_sdk_version'.toJS,
  );
  if (override != null &&
      (!override.typeofEquals('string') ||
          (override as JSString).toDart != _sdkVersion)) {
    throw StateError('Local Auth requires the installed Firebase SDK version.');
  }
  final loaded = <String, JSObject>{};
  // Core first, matching FlutterFire's WebKit module-evaluation ordering.
  for (final entry in _modules.entries) {
    final url =
        'https://www.gstatic.com/firebasejs/$_sdkVersion/firebase-${entry.value}.js';
    final module = await importModule(url.toJS).toDart
        .timeout(const Duration(seconds: 30));
    final existing = globalContext.getProperty<JSAny?>(entry.key.toJS);
    if (existing != null && !jsIdentical(existing, module)) {
      throw StateError('The existing Firebase SDK module does not match.');
    }
    loaded[entry.key] = module;
  }
  final core = loaded['firebase_core']!;
  final version = core.getProperty<JSAny?>('SDK_VERSION'.toJS);
  validateDemoAuthSdkVersion(
    version != null && version.typeofEquals('string')
        ? (version as JSString).toDart
        : null,
  );
  for (final name in ['getApps', 'initializeApp']) {
    _requireFunction(core, name);
  }
  final auth = loaded['firebase_auth']!;
  for (final name in [
    'initializeAuth',
    'connectAuthEmulator',
    'debugErrorMap',
    'indexedDBLocalPersistence',
    'browserLocalPersistence',
    'browserSessionPersistence',
    'browserPopupRedirectResolver',
  ]) {
    _requireFunction(auth, name);
  }
  _requireFunction(loaded['firebase_firestore']!, 'getFirestore');
  _requireFunction(loaded['firebase_functions']!, 'getFunctions');
  // Publish only absent baseline module namespaces, never replace/clear globals.
  for (final entry in loaded.entries) {
    if (globalContext.getProperty<JSAny?>(entry.key.toJS) == null) {
      globalContext.setProperty(entry.key.toJS, entry.value);
    }
  }
  _loadedModules = loaded;
  _core = _CoreModule(core);
  _authModule = _AuthModule(auth);
}

_Options _jsOptions(FirebaseOptions value) => _Options(
  apiKey: value.apiKey.toJS,
  appId: value.appId.toJS,
  messagingSenderId: value.messagingSenderId.toJS,
  projectId: value.projectId.toJS,
  authDomain: value.authDomain?.toJS,
  databaseURL: value.databaseURL?.toJS,
  storageBucket: value.storageBucket?.toJS,
  measurementId: value.measurementId?.toJS,
);

void _verifyOptions(_App app) {
  final options = app.options;
  validateDemoAuthApp(
    app.name.toDart,
    FirebaseOptions(
      apiKey: options.apiKey?.toDart ?? '',
      appId: options.appId?.toDart ?? '',
      messagingSenderId: options.messagingSenderId?.toDart ?? '',
      projectId: options.projectId?.toDart ?? '',
      authDomain: options.authDomain?.toDart,
      databaseURL: options.databaseURL?.toDart,
      storageBucket: options.storageBucket?.toDart,
      measurementId: options.measurementId?.toDart,
    ),
  );
}

AuthEmulatorRoute _inspectOwnedRoute() {
  for (final entry in _loadedModules.entries) {
    if (!jsIdentical(
      globalContext.getProperty<JSAny?>(entry.key.toJS),
      entry.value,
    )) {
      throw StateError(
        'The preloaded Firebase SDK module was replaced or lost.',
      );
    }
  }
  final apps = _core!.getApps().toDart.where(
    (app) => app.name.toDart == emulatorDemoAppName,
  );
  final auth = _ownedAuth;
  if (apps.length != 1 ||
      auth == null ||
      !jsIdentical(apps.single, _ownedApp) ||
      !jsIdentical(auth.app, _ownedApp)) {
    throw StateError('The preconnected named JS Auth app is unavailable.');
  }
  _verifyOptions(apps.single);
  final config = auth.emulatorConfig;
  if (config == null) {
    // Never attempt to repair a previously initializing unconfigured Auth.
    throw StateError('The actual Auth emulator configuration was lost.');
  }
  return AuthEmulatorRoute(
    auth.app.name.toDart,
    config.protocol.toDart,
    config.host.toDart,
    config.port?.toDartInt,
  );
}

void _verifyRoute() {
  final route = _inspectOwnedRoute();
  if (route.protocol != 'http' ||
      route.host != '127.0.0.1' ||
      route.port != 9099) {
    throw StateError('The named Auth app is not routed to the local emulator.');
  }
}

final _preinitializer = AuthEmulatorPreinitializer(
  loadModules: _loadModules,
  prepareApp: () {
    final existing = _core!.getApps().toDart.where(
      (app) => app.name.toDart == emulatorDemoAppName,
    );
    // Public getAuth can INITIALIZE Auth. Do not inspect an unowned existing app
    // with it: its persistence queue may already be running. A fresh document
    // is required after hot restart loses app-owned initialization authority.
    if (existing.isNotEmpty) {
      _verifyOptions(existing.single);
      throw StateError(
        'An existing unowned Auth app cannot be safely initialized. Reload the document.',
      );
    }
    const key = '$emulatorDemoAppName-firebaseEmulatorOrigin';
    final stored = _sessionStorage.getItem(key.toJS)?.toDart;
    if (stored != null) {
      if (stored != 'http://127.0.0.1:9099') {
        throw StateError('Conflicting stored Auth emulator origin.');
      }
      _sessionStorage.removeItem(key.toJS);
      if (_sessionStorage.getItem(key.toJS) != null) {
        throw StateError('Stale Auth emulator origin could not be removed.');
      }
    }
    _ownedApp = _core!.initializeApp(
      _jsOptions(emulatorDemoOptions),
      emulatorDemoAppName.toJS,
    );
    _verifyOptions(_ownedApp!);
  },
  initializeAuth: () {
    final module = _authModule!;
    // Exact getAuthInstance dependencies in firebase_auth_web 6.3.0:
    // same errorMap, ordered persistence hierarchy and redirect resolver.
    _ownedAuth = module.initializeAuth(
      _ownedApp!,
      _Dependencies(
        errorMap: module.debugErrorMap,
        persistence: [
          module.indexedDBLocalPersistence,
          module.browserLocalPersistence,
          module.browserSessionPersistence,
        ].toJS,
        popupRedirectResolver: module.browserPopupRedirectResolver,
      ),
    );
  },
  connect: () => _authModule!.connectAuthEmulator(
    _ownedAuth!,
    'http://127.0.0.1:9099'.toJS,
  ),
  verify: _verifyRoute,
);

Future<void> prepareWebAuthEmulator({
  required String appName,
  required FirebaseOptions options,
}) async {
  validateDemoAuthApp(appName, options);
  await _preinitializer.prepare();
}

WebAuthEmulatorRouting webAuthEmulatorRouting({
  required String appName,
  required Future<void> Function(String host, int port) connect,
}) {
  if (appName != emulatorDemoAppName) {
    throw StateError('Unexpected local Auth app.');
  }
  return WebAuthEmulatorRouting(
    appName: appName,
    inspect: _inspectOwnedRoute,
    readOrigin: (key) => _sessionStorage.getItem(key.toJS)?.toDart,
    removeOrigin: (key) => _sessionStorage.removeItem(key.toJS),
    connect: connect,
  );
}
