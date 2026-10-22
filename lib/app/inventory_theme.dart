import 'package:flutter/material.dart';

/// Shared restrained light theme (T9/S4): a neutral, very light gray
/// scaffold so white card surfaces stand out without strong shadows, blue
/// reserved for important actions, and subtle hairline borders for card
/// structure. Every screen builds on this one theme.
ThemeData buildInventoryTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF6F7F9),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: const BorderSide(color: Color(0xFFE8EBEF)),
      ),
    ),
  );
}

/// Dark sibling: all default Material controls derive their contrast and tonal
/// colors from the same blue-seeded scheme, without changing the light theme.
ThemeData buildDarkInventoryTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: Brightness.dark,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
    ),
  );
}
