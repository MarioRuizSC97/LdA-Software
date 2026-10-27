import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local privacy curtain, NOT a security boundary. The administrator
/// still receives costs from the server. Local storage and this UI can be
/// bypassed; a short PIN's salted SHA-256 digest also permits offline guessing.
class CostPinStore {
  CostPinStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static const preferenceKey = 'lda.costPin.v1';
  final Future<SharedPreferences> Function() _preferences;

  Future<bool> get isConfigured async =>
      (await _preferences()).containsKey(preferenceKey);

  static bool isValid(String pin) => RegExp(r'^[0-9]{4,6}$').hasMatch(pin);

  void _validate(String pin) {
    if (!isValid(pin)) throw ArgumentError('PIN must contain 4 to 6 digits');
  }

  Future<void> create(String pin) async {
    _validate(pin);
    if (await isConfigured) throw StateError('PIN already configured');
    await _write(pin);
  }

  Future<bool> verify(String pin) async {
    if (!isValid(pin)) return false;
    final record = (await _preferences()).get(preferenceKey);
    if (record is! String) return false;
    final parts = record.split(':');
    if (parts.length != 2 ||
        !RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(parts[0]) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(parts[1])) {
      return false;
    }
    final candidate = _digest(parts[0], pin);
    var difference = 0;
    // Fixed-size comparison: never return early on a mismatched digest byte.
    for (var i = 0; i < 64; i++) {
      difference |= candidate.codeUnitAt(i) ^ parts[1].codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<bool> change(String currentPin, String newPin) async {
    _validate(newPin);
    if (!await verify(currentPin)) return false;
    await _write(newPin);
    return true;
  }

  String _digest(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt$pin')).toString();

  Future<void> _write(String pin) async {
    final random = Random.secure();
    final salt = base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    // One record avoids a partially updated salt/digest pair.
    final saved = await (await _preferences()).setString(
      preferenceKey,
      '$salt:${_digest(salt, pin)}',
    );
    if (!saved) throw StateError('PIN could not be saved');
  }
}
