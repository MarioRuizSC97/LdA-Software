import 'package:flutter/material.dart';

/// Shares the primary vertical scroll offset without rebuilding the shell body.
class AppBarSurfaceScope extends StatefulWidget {
  const AppBarSurfaceScope({required this.child, super.key});
  final Widget child;

  @override
  State<AppBarSurfaceScope> createState() => _AppBarSurfaceScopeState();
}

class _AppBarSurfaceScopeState extends State<AppBarSurfaceScope> {
  final offset = ValueNotifier<double>(0);

  @override
  void dispose() {
    offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SurfaceOffset(
    notifier: offset,
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          offset.value = notification.metrics.pixels;
        }
        return false;
      },
      child: widget.child,
    ),
  );
}

class _SurfaceOffset extends InheritedNotifier<ValueNotifier<double>> {
  const _SurfaceOffset({required super.notifier, required super.child});
}

/// Paints a direct 36px color ramp, with no time-based lag (also for reduced
/// motion). The transparent AppBar cannot add a binary scrolled-under tint or
/// shadow; all existing title, navigation and action widgets remain untouched.
class AppBarSurface extends StatelessWidget implements PreferredSizeWidget {
  const AppBarSurface({required this.child, super.key});
  final AppBar child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) {
    final offset =
        context
            .dependOnInheritedWidgetOfExactType<_SurfaceOffset>()
            ?.notifier
            ?.value ??
        0;
    final theme = Theme.of(context);
    final color = Color.lerp(
      theme.colorScheme.surface,
      theme.colorScheme.surfaceContainerLow,
      (offset / 36).clamp(0.0, 1.0),
    )!;
    return ColoredBox(
      key: const ValueKey<String>('catalog-app-bar-surface'),
      color: color,
      child: Theme(
        data: theme.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            shadowColor: Colors.transparent,
          ),
        ),
        child: child,
      ),
    );
  }
}
