import 'dart:async';

import 'package:flutter/material.dart';

import 'inventory_theme_host.dart';
import 'theme_mode_store.dart';

/// In-session theme preference; omitted when no app theme host is available.
class ThemeModeSwitch extends StatelessWidget {
  const ThemeModeSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeModeStore? store = ThemeModeScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();

    // Radio tiles expose their checked state and support keyboard navigation.
    // A vertical layout also leaves room for large accessibility text sizes.
    return RadioGroup<ThemeMode>(
      groupValue: store.value,
      onChanged: (ThemeMode? mode) {
        if (mode != null) unawaited(store.setThemeMode(mode));
      },
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RadioListTile<ThemeMode>(
            value: ThemeMode.system,
            title: Text('Sistema'),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.light,
            title: Text('Claro'),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.dark,
            title: Text('Oscuro'),
          ),
        ],
      ),
    );
  }
}
