import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_bar_surface.dart';

/// Shares only focus-mode chrome silencing, without rebuilding the catalog.
class CatalogSearchChromeScope extends StatefulWidget {
  const CatalogSearchChromeScope({required this.child, super.key});
  final Widget child;

  static ValueNotifier<bool>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ChromeFocus>()?.notifier;

  @override
  State<CatalogSearchChromeScope> createState() => _ChromeScopeState();
}

class _ChromeScopeState extends State<CatalogSearchChromeScope> {
  final ValueNotifier<bool> active = ValueNotifier(false);

  @override
  void dispose() {
    active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ChromeFocus(notifier: active, child: widget.child);
}

class _ChromeFocus extends InheritedNotifier<ValueNotifier<bool>> {
  const _ChromeFocus({required super.notifier, required super.child});
}

/// Silences the unchanged app bar/cart contents while the overlay covers them.
class CatalogSearchChrome extends StatelessWidget
    implements PreferredSizeWidget {
  const CatalogSearchChrome({
    required this.child,
    this.scrollSurface = false,
    super.key,
  });
  final Widget child;
  final bool scrollSurface;

  @override
  Size get preferredSize => (child as PreferredSizeWidget).preferredSize;

  @override
  Widget build(BuildContext context) {
    final active = CatalogSearchChromeScope.maybeOf(context)?.value ?? false;
    return IgnorePointer(
      ignoring: active,
      child: ExcludeSemantics(
        excluding: active,
        child: ExcludeFocus(
          excluding: active,
          child: scrollSurface ? AppBarSurface(child: child as AppBar) : child,
        ),
      ),
    );
  }
}

/// Keeps the real search field in its scroll view (never a second keyed copy),
/// with a hole in the focus scrim and results anchored to its measured bounds.
class CatalogSearchFocus extends StatefulWidget {
  const CatalogSearchFocus({
    required this.focusNode,
    required this.builder,
    required this.results,
    super.key,
  });

  final FocusNode focusNode;
  final Widget Function(Widget Function(Widget) liftSearch) builder;
  final Widget? results;

  @override
  State<CatalogSearchFocus> createState() => _CatalogSearchFocusState();
}

class _CatalogSearchFocusState extends State<CatalogSearchFocus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(() => setState(() {}));

  double get _scale => MediaQuery.disableAnimationsOf(context)
      ? 1
      : 1 + .04 * Curves.easeOutCubic.transform(_zoom.value);
  final OverlayPortalController _overlay = OverlayPortalController();
  final GlobalKey _panel = GlobalKey();
  final GlobalKey _field = GlobalKey();
  Rect _bounds = Rect.zero;
  double _globalTop = 0;
  bool _measurementPending = false;

  bool get _active => widget.focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlay.show();
    });
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    _zoom.dispose();
    super.dispose();
  }

  void _focusChanged() {
    setState(() {});
    if (MediaQuery.disableAnimationsOf(context)) {
      _zoom.value = 0;
    } else if (_active) {
      _zoom.forward();
    } else {
      _zoom.reverse();
    }
    CatalogSearchChromeScope.maybeOf(context)?.value = _active;
    if (_active) {
      final context = _field.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    }
    _measureAfterLayout();
  }

  void _measureAfterLayout() {
    if (_measurementPending) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      if (!mounted) return;
      final panel = _panel.currentContext?.findRenderObject() as RenderBox?;
      final field = _field.currentContext?.findRenderObject() as RenderBox?;
      if (panel == null || field == null || !field.hasSize) return;
      final bounds =
          panel.globalToLocal(field.localToGlobal(Offset.zero)) & field.size;
      final globalTop = panel.localToGlobal(Offset.zero).dy;
      if (_bounds != bounds || _globalTop != globalTop) {
        setState(() {
          _bounds = bounds;
          _globalTop = globalTop;
        });
      }
    });
  }

  Widget _lift(Widget child) => Padding(
    key: _field,
    padding: EdgeInsets.zero,
    child: Transform.scale(
      scale: _scale,
      alignment: Alignment.center,
      child: Material(
        key: const ValueKey<String>('catalog-search-lift'),
        elevation: _active ? 6 : 0,
        borderRadius: BorderRadius.circular(4),
        color: Theme.of(context).colorScheme.surface,
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    _measureAfterLayout();
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _active) widget.focusNode.unfocus();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape):
              widget.focusNode.unfocus,
        },
        child: OverlayPortal(
          controller: _overlay,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              if (_active) _measureAfterLayout();
              return false;
            },
            child: widget.builder(_lift),
          ),
          overlayChildBuilder: (context) => Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // A resizing Scaffold has already removed the keyboard. The minimum
                // also protects hosts that deliberately do not resize their body.
                final bottom = math.min(
                  constraints.maxHeight,
                  MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      _globalTop,
                );
                final top = _bounds.bottom + 8;
                return Stack(
                  key: _panel,
                  children: <Widget>[
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_active,
                        child: AnimatedOpacity(
                          key: const ValueKey<String>(
                            'catalog-search-scrim-fade',
                          ),
                          opacity: _active ? 1 : 0,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          child: ClipPath(
                            clipper: _SearchHole(
                              Rect.fromCenter(
                                center: _bounds.center,
                                width: _bounds.width * _scale + 4,
                                height: _bounds.height * _scale + 4,
                              ),
                            ),
                            child: GestureDetector(
                              key: const ValueKey<String>(
                                'catalog-search-scrim',
                              ),
                              behavior: HitTestBehavior.opaque,
                              excludeFromSemantics: true,
                              onTap: widget.focusNode.unfocus,
                              child: _active
                                  ? BackdropFilter(
                                      key: const ValueKey<String>(
                                        'catalog-search-blur',
                                      ),
                                      filter: ImageFilter.blur(
                                        sigmaX: 5,
                                        sigmaY: 5,
                                      ),
                                      child: ColoredBox(
                                        color: colors.scrim.withValues(
                                          alpha: .24,
                                        ),
                                      ),
                                    )
                                  : ColoredBox(
                                      color: colors.scrim.withValues(
                                        alpha: .24,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_active && widget.results != null && bottom > top + 24)
                      Positioned(
                        top: top,
                        left: _bounds.left,
                        width: _bounds.width,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: bottom - top - 12,
                          ),
                          child: Material(
                            key: const ValueKey<String>(
                              'catalog-search-results',
                            ),
                            color: colors.surface,
                            elevation: 8,
                            borderRadius: BorderRadius.circular(24),
                            clipBehavior: Clip.antiAlias,
                            child: TextFieldTapRegion(child: widget.results!),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchHole extends CustomClipper<Path> {
  const _SearchHole(this.field);
  final Rect field;

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRRect(RRect.fromRectAndRadius(field, const Radius.circular(4)));

  @override
  bool shouldReclip(_SearchHole oldClipper) => oldClipper.field != field;
}
