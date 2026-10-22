import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-run theme preference. Loading never blocks the first frame; an explicit
/// selection wins over an in-flight load. Storage failures leave the UI usable.
class ThemeModeStore extends ChangeNotifier implements ValueListenable<ThemeMode> {
  ThemeModeStore() {
    loaded = _load();
  }

  static const String preferenceKey = 'lda.themeMode';
  ThemeMode _value = ThemeMode.system;
  bool _selected = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  /// Completes once the initial best-effort load has finished.
  late final Future<void> loaded;

  @override
  ThemeMode get value => _value;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.get(preferenceKey);
      final mode = switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      if (!_selected && !_disposed) _update(mode);
    } on Exception {
      // Unsupported/unavailable platform storage keeps the system default.
    }
  }

  /// Updates listeners synchronously, then persists in selection order.
  /// Persistence is best effort when platform storage is unavailable.
  Future<void> setThemeMode(ThemeMode mode) {
    _selected = true;
    _update(mode);
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(preferenceKey, mode.name);
      } on Exception {
        // Keep the user's current selection even if storage is unavailable.
      }
    });
    return _writes;
  }

  void _update(ThemeMode mode) {
    if (_value == mode) return;
    _value = mode;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
