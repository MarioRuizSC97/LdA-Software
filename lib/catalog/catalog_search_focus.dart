import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class _CatalogSearchFocusState extends State<CatalogSearchFocus> {
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
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    setState(() {});
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
    child: Material(
      key: const ValueKey<String>('catalog-search-lift'),
      elevation: _active ? 6 : 0,
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.surface,
      child: child,
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
                NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    _measureAfterLayout();
                    return false;
                  },
                  child: widget.builder(_lift),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_active,
                    child: AnimatedOpacity(
                      key: const ValueKey<String>('catalog-search-scrim-fade'),
                      opacity: _active ? 1 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: ClipPath(
                        clipper: _SearchHole(_bounds.inflate(2)),
                        child: GestureDetector(
                          key: const ValueKey<String>('catalog-search-scrim'),
                          behavior: HitTestBehavior.opaque,
                          excludeFromSemantics: true,
                          onTap: widget.focusNode.unfocus,
                          child: _active && widget.results != null
                              ? BackdropFilter(
                                  key: const ValueKey<String>(
                                    'catalog-search-blur',
                                  ),
                                  filter: ImageFilter.blur(
                                    sigmaX: 8,
                                    sigmaY: 8,
                                  ),
                                  child: ColoredBox(
                                    color: colors.scrim.withValues(alpha: .24),
                                  ),
                                )
                              : ColoredBox(
                                  color: colors.scrim.withValues(alpha: .24),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_active && widget.results != null && bottom > top + 24)
                  Positioned(
                    top: top,
                    left: math.max(16, _bounds.left),
                    width: math.min(
                      560,
                      math.min(_bounds.width, constraints.maxWidth - 32),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: bottom - top - 12),
                      child: Material(
                        key: const ValueKey<String>('catalog-search-results'),
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
