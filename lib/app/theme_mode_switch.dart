import 'dart:async';

import 'package:flutter/material.dart';

import 'inventory_theme_host.dart';
import 'theme_mode_store.dart';

/// Cycles the persisted theme preference; hidden without an app theme host.
class ThemeModeSwitch extends StatelessWidget {
  const ThemeModeSwitch({
    super.key,
    this.compact = false,
    this.showLabel = false,
  });

  /// Shrinks only the painted circle, retaining a 48px accessible tap target.
  final bool compact;

  /// Panel presentation: current preference followed by its cycling control.
  final bool showLabel;

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
    final Widget button = IconButton.filled(
      tooltip: 'Tema: $label',
      style: IconButton.styleFrom(
        backgroundColor: colors.inverseSurface,
        foregroundColor: colors.onInverseSurface,
        shape: const CircleBorder(),
        minimumSize: Size.square(compact ? 36 : 48),
        maximumSize: compact ? const Size.square(36) : null,
        padding: compact ? const EdgeInsets.all(6) : null,
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      onPressed: () => unawaited(store.setThemeMode(next)),
      icon: Icon(icon),
    );
    if (!showLabel) return button;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Tema: $label')),
          const SizedBox(width: 12),
          button,
        ],
      ),
    );
  }
}
