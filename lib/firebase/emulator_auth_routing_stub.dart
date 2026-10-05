import 'package:firebase_core/firebase_core.dart';

import 'emulator_auth_routing.dart';

Future<void> prepareWebAuthEmulator({
  required String appName,
  required FirebaseOptions options,
}) async {}

// Native Auth keeps the existing FlutterFire connector and host mapping.
WebAuthEmulatorRouting? webAuthEmulatorRouting({
  required String appName,
  required Future<void> Function(String host, int port) connect,
}) => null;
