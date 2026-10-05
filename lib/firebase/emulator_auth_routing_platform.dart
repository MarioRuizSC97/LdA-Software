import 'package:firebase_core/firebase_core.dart';

import 'emulator_auth_routing_stub.dart'
    if (dart.library.js_interop) 'emulator_auth_routing_web.dart'
    as platform;
import 'emulator_auth_routing.dart';

Future<void> prepareWebAuthEmulator({
  required String appName,
  required FirebaseOptions options,
}) => platform.prepareWebAuthEmulator(appName: appName, options: options);

WebAuthEmulatorRouting? webAuthEmulatorRouting({
  required String appName,
  required Future<void> Function(String host, int port) connect,
}) => platform.webAuthEmulatorRouting(appName: appName, connect: connect);
