import 'package:flutter/material.dart';

/// Soft light-mode primary actions, distinct from secondary tonal buttons.
///
/// Only colors are overridden: call-site geometry and dark Material defaults
/// remain intact. Disabled text stays opaque and legible, but more neutral.
/// Do not apply through FilledButtonTheme: it also styles tonal secondaries.
ButtonStyle? primaryActionStyle(BuildContext context) {
  final theme = Theme.of(context);
  if (theme.brightness == Brightness.dark) return null;
  final colors = theme.colorScheme;
  return ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(colors.primaryContainer),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurfaceVariant
          : colors.onPrimaryContainer,
    ),
  );
}
