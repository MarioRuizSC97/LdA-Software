import 'package:firebase_core/firebase_core.dart';

const emulatorDemoSdkVersion = '12.19.0';
const emulatorDemoAppName = 'lda-demo-emulators';
const emulatorDemoOptions = FirebaseOptions(
  apiKey: 'demo-api-key',
  appId: '1:1234567890:web:demo-lda-inventory',
  messagingSenderId: '1234567890',
  projectId: 'demo-lda-inventory',
  authDomain: 'demo-lda-inventory.firebaseapp.com',
);

/// Native iOS FirebaseCore requires a v1 appId shaped
/// `1:<project number>:ios:<hex>`; any other platform segment aborts
/// configuration. Native FirebaseInstallations also aborts unless the apiKey
/// is exactly 39 base64 url-safe characters starting with `A`, so iOS uses a
/// format-valid, obviously fake demo key. Same demo project and sender as
/// [emulatorDemoOptions].
const emulatorDemoIosOptions = FirebaseOptions(
  apiKey: 'A-demo-lda-inventory-emulator-only-0000',
  appId: '1:1234567890:ios:0dda0dda0dda0dda',
  messagingSenderId: '1234567890',
  projectId: 'demo-lda-inventory',
);

void validateDemoAuthApp(String name, FirebaseOptions options) {
  if (name != emulatorDemoAppName || options != emulatorDemoOptions) {
    throw StateError('Unexpected local Auth app/options.');
  }
}

void validateDemoAuthSdkVersion(String? version) {
  if (version != emulatorDemoSdkVersion) {
    throw StateError('Local Auth requires the installed Firebase SDK version.');
  }
}

/// Module loading may yield. Auth creation, connection and verification must not.
/// A failed/unknown Auth initialization is never retried against a live Auth queue.
class AuthEmulatorPreinitializer {
  AuthEmulatorPreinitializer({
    required this.loadModules,
    required this.prepareApp,
    required this.initializeAuth,
    required this.connect,
    required this.verify,
  });

  final Future<void> Function() loadModules;
  final void Function() prepareApp;
  final void Function() initializeAuth;
  final void Function() connect;
  final void Function() verify;
  Future<void>? _attempt;
  bool _ready = false;
  bool _authStarted = false;

  Future<void> prepare() async {
    if (_ready) {
      verify();
      return;
    }
    if (_authStarted) {
      throw StateError('An unverified Auth initialization cannot be reused.');
    }
    final pending = _attempt;
    if (pending != null) {
      await pending;
      verify();
      return;
    }
    final attempt = _prepare();
    _attempt = attempt;
    try {
      await attempt;
    } finally {
      _attempt = null;
    }
  }

  Future<void> _prepare() async {
    await loadModules();
    // Storage/options/existing-app checks happen before an Auth queue exists.
    prepareApp();
    _authStarted = true;
    // NO await, Future-returning callback, or scheduler yield in this sequence.
    initializeAuth();
    connect();
    verify();
    _ready = true;
  }
}
