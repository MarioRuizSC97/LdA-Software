import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Presents product details without changing their role or action ownership.
Future<void> showProductPeek({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black54,
  transitionDuration: MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 260),
  pageBuilder: (context, animation, secondaryAnimation) => Stack(
    children: <Widget>[
      Positioned.fill(
        child: IgnorePointer(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      SafeArea(
        child: Padding(
          // The keyboard inset is absorbed here (not inside the sheet) so the
          // centered card rises above the keyboard instead of growing. The
          // padding already removes the inset from the available height, so
          // the cap below never subtracts it again (it could go negative).
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: MediaQuery.sizeOf(context).height * .88,
              ),
              child: _PeekCard(child: builder(context)),
            ),
          ),
        ),
      ),
    ],
  ),
  transitionBuilder: (context, animation, secondaryAnimation, child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    // Only the card zooms; the full-screen blur stays fixed in place.
    return _PeekTransition(animation: curved, child: child);
  },
);

// The transition animation is inherited by the card rather than scaling the
// backdrop (which would expose unblurred edges during the zoom).
class _PeekTransition extends InheritedWidget {
  const _PeekTransition({required this.animation, required super.child});
  final Animation<double> animation;

  @override
  bool updateShouldNotify(_PeekTransition oldWidget) =>
      animation != oldWidget.animation;
}

class _PeekCard extends StatefulWidget {
  const _PeekCard({required this.child});
  final Widget child;

  @override
  State<_PeekCard> createState() => _PeekCardState();
}

class _PeekCardState extends State<_PeekCard> {
  Offset? _start;
  bool _scrollAtTop = true;
  bool _startedAtTop = true;

  @override
  Widget build(BuildContext context) {
    Widget card = Listener(
      // Observe rather than compete with the scrollable's drag recognizer.
      // A downward swipe only dismisses if it started at the top of the text.
      onPointerDown: (event) {
        _start = event.position;
        _startedAtTop = _scrollAtTop;
      },
      onPointerUp: (event) {
        final start = _start;
        _start = null;
        if (start == null || !_startedAtTop) return;
        final delta = event.position - start;
        if (delta.dy > 80 && delta.dy > delta.dx.abs()) {
          Navigator.of(context).maybePop();
        }
      },
      onPointerCancel: (_) => _start = null,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _scrollAtTop =
              notification.metrics.pixels <=
              notification.metrics.minScrollExtent;
          return false;
        },
        child: Material(
          key: const ValueKey<String>('product-peek-card'),
          clipBehavior: Clip.antiAlias,
          elevation: 12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                label: 'Desliza hacia abajo para cerrar detalles',
                child: SizedBox(
                  key: const ValueKey<String>('product-peek-handle'),
                  height: 28,
                  width: double.infinity,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(child: widget.child),
            ],
          ),
        ),
      ),
    );
    final transition = context
        .dependOnInheritedWidgetOfExactType<_PeekTransition>();
    if (transition != null) {
      card = FadeTransition(
        key: const ValueKey<String>('product-peek-fade'),
        opacity: transition.animation,
        child: ScaleTransition(
          key: const ValueKey<String>('product-peek-scale'),
          scale: Tween<double>(
            begin: .85,
            end: 1,
          ).animate(transition.animation),
          child: card,
        ),
      );
    }
    return card;
  }
}
