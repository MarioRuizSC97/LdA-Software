import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'app_info.dart';

const Duration _panelDuration = Duration(milliseconds: 280);

/// One action listed in the side panel. A null [onSelected] shows the entry
/// disabled.
class AppSidePanelEntry {
  const AppSidePanelEntry({
    this.key,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final Key? key;
  final Widget icon;
  final String label;
  final VoidCallback? onSelected;
}

/// The three-bar button that opens the side panel.
///
/// The bars morph into a close icon while the panel slides in and back when
/// it closes. [entries] is read each time the panel opens, so it reflects the
/// shell state at that moment. [decorate] wraps the icon (for example with a
/// badge) without touching the animation.
class AppMenuButton extends StatefulWidget {
  const AppMenuButton({
    super.key,
    required this.entries,
    this.decorate,
    this.settings,
  });

  final List<AppSidePanelEntry> Function() entries;
  final Widget Function(Widget icon)? decorate;

  /// Optional block shown above the app information (e.g. the theme switch).
  final WidgetBuilder? settings;

  @override
  State<AppMenuButton> createState() => _AppMenuButtonState();
}

class _AppMenuButtonState extends State<AppMenuButton> {
  Animation<double> _progress = kAlwaysDismissedAnimation;

  Future<void> _open() async {
    final Future<void> closed = showAppSidePanel(
      context: context,
      entries: widget.entries(),
      settings: widget.settings,
      onRoute: (Animation<double> animation) =>
          setState(() => _progress = animation),
    );
    await closed;
    if (mounted) setState(() => _progress = kAlwaysDismissedAnimation);
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = AnimatedIcon(
      icon: AnimatedIcons.menu_close,
      progress: _progress,
    );
    return IconButton(
      tooltip: 'Menú',
      onPressed: _open,
      icon: widget.decorate?.call(icon) ?? icon,
    );
  }
}

/// Slides the side panel in from the right over a blurred, dimmed shell.
/// Tapping outside the panel, the close icon or an entry closes it; an entry
/// runs its action after the panel starts closing.
Future<void> showAppSidePanel({
  required BuildContext context,
  required List<AppSidePanelEntry> entries,
  WidgetBuilder? settings,
  void Function(Animation<double> animation)? onRoute,
}) {
  final bool instant = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cerrar menú',
    barrierColor: Colors.transparent,
    transitionDuration: instant ? Duration.zero : _panelDuration,
    pageBuilder: (BuildContext context, Animation<double> animation, _) {
      if (onRoute != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onRoute(animation));
      }
      return _SidePanelLayer(
        animation: animation,
        entries: entries,
        settings: settings,
      );
    },
  );
}

class _SidePanelLayer extends StatelessWidget {
  const _SidePanelLayer({
    required this.animation,
    required this.entries,
    required this.settings,
  });

  final Animation<double> animation;
  final List<AppSidePanelEntry> entries;
  final WidgetBuilder? settings;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double width = math.min(320, MediaQuery.sizeOf(context).width * 0.85);
    final Animation<double> eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Stack(
      children: <Widget>[
        // Taps pass through to the dismissible barrier underneath.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              key: const ValueKey<String>('app-side-panel-backdrop'),
              animation: eased,
              builder: (BuildContext context, Widget? child) => BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: 6 * eased.value,
                  sigmaY: 6 * eased.value,
                ),
                child: ColoredBox(
                  color: colors.scrim.withValues(alpha: 0.32 * eased.value),
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(eased),
            child: SizedBox(
              key: const ValueKey<String>('app-side-panel'),
              width: width,
              height: double.infinity,
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: 'Menú',
                child: Material(
                  elevation: 16,
                  color: colors.surfaceContainerLow,
                  child: SafeArea(
                    left: false,
                    child: _SidePanelBody(
                      animation: animation,
                      entries: entries,
                      settings: settings,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SidePanelBody extends StatelessWidget {
  const _SidePanelBody({
    required this.animation,
    required this.entries,
    required this.settings,
  });

  final Animation<double> animation;
  final List<AppSidePanelEntry> entries;
  final WidgetBuilder? settings;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('Menú', style: text.titleMedium)),
              IconButton(
                tooltip: 'Cerrar menú',
                onPressed: () => Navigator.of(context).pop(),
                icon: AnimatedIcon(
                  icon: AnimatedIcons.menu_close,
                  progress: animation,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Entries, settings and the app information share one scroll view:
        // at large text sizes nothing is clipped behind a fixed footer, and
        // with room to spare the information still sits at the bottom (S9).
        Expanded(
          child: CustomScrollView(
            slivers: <Widget>[
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                sliver: SliverList.list(
                  children: <Widget>[
                    for (final AppSidePanelEntry entry in entries)
                      ListTile(
                        key: entry.key,
                        leading: entry.icon,
                        title: Text(entry.label),
                        enabled: entry.onSelected != null,
                        onTap: entry.onSelected == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                entry.onSelected!();
                              },
                      ),
                  ],
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (settings != null) settings!(context),
                    Padding(
                      key: const ValueKey<String>('app-side-panel-info'),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(appName, style: text.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            appVersionLabel,
                            style: text.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
