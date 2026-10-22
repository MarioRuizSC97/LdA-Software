import 'package:flutter/material.dart';

import 'theme_mode_store.dart';

/// Owns one store for the lifetime of an app root, not per MaterialApp rebuild.
class InventoryThemeHost extends StatefulWidget {
  const InventoryThemeHost({required this.builder, this.store, super.key});

  final Widget Function(BuildContext context, ThemeMode mode) builder;
  final ThemeModeStore? store;

  @override
  State<InventoryThemeHost> createState() => _InventoryThemeHostState();
}

class _InventoryThemeHostState extends State<InventoryThemeHost> {
  late final ThemeModeStore _store = widget.store ?? ThemeModeStore();
  late final bool _ownsStore = widget.store == null;

  @override
  void dispose() {
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ThemeModeScope(
    store: _store,
    child: ValueListenableBuilder<ThemeMode>(
      valueListenable: _store,
      builder: (context, mode, _) => widget.builder(context, mode),
    ),
  );
}

/// Access for login and future in-session selectors.
class ThemeModeScope extends InheritedNotifier<ThemeModeStore> {
  const ThemeModeScope({required ThemeModeStore store, required super.child, super.key})
      : super(notifier: store);

  static ThemeModeStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeModeScope>()?.notifier;
}
