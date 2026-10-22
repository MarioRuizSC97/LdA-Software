import 'dart:async';

import 'package:flutter/material.dart';

import 'inventory_theme_host.dart';
import 'theme_mode_store.dart';

/// Cycles the persisted theme preference; hidden without an app theme host.
class ThemeModeSwitch extends StatelessWidget {
  const ThemeModeSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeModeStore? store = ThemeModeScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();

    final (String label, IconData icon, ThemeMode next) = switch (store.value) {
      ThemeMode.system => ('Sistema', Icons.brightness_auto, ThemeMode.light),
      ThemeMode.light => ('Claro', Icons.light_mode, ThemeMode.dark),
      ThemeMode.dark => ('Oscuro', Icons.dark_mode, ThemeMode.system),
    };
    final ColorScheme colors = Theme.of(context).colorScheme;
    return IconButton.filled(
      tooltip: 'Tema: $label',
      style: IconButton.styleFrom(
        backgroundColor: colors.inverseSurface,
        foregroundColor: colors.onInverseSurface,
        shape: const CircleBorder(),
        minimumSize: const Size.square(48),
      ),
      onPressed: () => unawaited(store.setThemeMode(next)),
      icon: Icon(icon),
    );
  }
}
