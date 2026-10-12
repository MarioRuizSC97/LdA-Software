import 'dart:io';

/// The marker every iOS simulator app executable path contains: simulator
/// apps run from `~/Library/Developer/CoreSimulator/Devices/<UDID>/...`.
/// Physical devices run from `/private/var/containers/Bundle/Application/...`.
const _coreSimulatorDevicesMarker = '/Library/Developer/CoreSimulator/Devices/';

/// Whether [path] is the executable of an app installed on an iOS simulator.
bool isIosSimulatorExecutable(String path) =>
    path.contains(_coreSimulatorDevicesMarker);

/// The iOS simulator does not expose its environment to Dart
/// (`Platform.environment` is empty there), so detection uses the app
/// executable location instead. Any other platform, and a physical device,
/// fails closed.
bool isIosSimulator() =>
    Platform.isIOS && isIosSimulatorExecutable(Platform.resolvedExecutable);
