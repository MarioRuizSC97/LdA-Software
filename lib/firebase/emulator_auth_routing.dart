/// Actual JS Auth configuration, not FlutterFire's sessionStorage bookkeeping.
class AuthEmulatorRoute {
  const AuthEmulatorRoute(this.appName, this.protocol, this.host, this.port);

  final String appName;
  final String protocol;
  final String host;
  final int? port;
}

/// Repairs only the named app's FlutterFire emulator-origin bookkeeping.
/// Inspection and storage exceptions intentionally propagate before consumers exist.
class WebAuthEmulatorRouting {
  WebAuthEmulatorRouting({
    required this.appName,
    required this.inspect,
    required this.readOrigin,
    required this.removeOrigin,
    required this.connect,
  });

  final String appName;
  final AuthEmulatorRoute? Function() inspect;
  final String? Function(String key) readOrigin;
  final void Function(String key) removeOrigin;
  final Future<void> Function(String host, int port) connect;

  void verify(String host, int port) {
    final route = inspect();
    if (route == null || !_matches(route, host, port)) {
      throw StateError(
        'The named Auth app is not routed to the local emulator.',
      );
    }
  }

  bool _matches(AuthEmulatorRoute route, String host, int port) =>
      route.appName == appName &&
      route.protocol == 'http' &&
      route.host == host &&
      route.port == port;

  Future<void> ensureConnected(String host, int port) async {
    if (host != '127.0.0.1' || port != 9099) {
      throw StateError('Unexpected web Auth emulator endpoint.');
    }
    final route = inspect();
    if (route != null) {
      verify(host, port);
      return;
    }
    final key = '$appName-firebaseEmulatorOrigin';
    final stored = readOrigin(key);
    if (stored != null) {
      if (stored != 'http://$host:$port') {
        throw StateError('Conflicting stored Auth emulator origin.');
      }
      // 6.3.0 otherwise skips connectAuthEmulator even with fresh JS Auth.
      removeOrigin(key);
      if (readOrigin(key) != null) {
        throw StateError('Stale Auth emulator origin could not be removed.');
      }
    }
    await connect(host, port);
    verify(host, port);
  }
}
