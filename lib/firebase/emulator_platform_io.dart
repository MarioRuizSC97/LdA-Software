import 'dart:io';

/// The iOS simulator runtime always exports `SIMULATOR_DEVICE_NAME`; a
/// physical device does not, so it fails closed.
bool isIosSimulator() =>
    Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
