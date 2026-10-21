import 'package:flutter/material.dart';

/// Soft transition between the catalog page's body panels (T9/S9): the panel
/// being left cross-fades underneath the one arriving, which eases up a short
/// distance into place. Complementary opacities keep the cross-fade level,
/// `Curves.easeOutCubic` keeps it calm, and 220 ms is short enough to read as
/// polish rather than a wait.
///
/// [identity] names the panel in front and is the whole contract:
///
/// * A rebuild that keeps the identity never re-animates and never rebuilds
///   the panel's element, so an in-panel change — a tap, a typed character, a
///   new quote — leaves the panel's own state and scroll offset alone.
/// * A new identity fades the panel before it out. Only one panel leaves at a
///   time: navigating again during a fade drops the panel that was already
///   fading, since it was covered and half gone anyway.
/// * A fading panel is silenced. It takes no pointer, contributes no semantics
///   and cannot hold focus, so a fast second tap can never act on the panel the
///   user already left, finders still see one interactive tree, and no stale
///   focus outlives the swap.
/// * `MediaQuery.disableAnimations` swaps instantly, and the very first panel a
///   [PanelTransition] presents is shown still — an initial load animates
///   nothing. Callers that have a body which is not a panel at all (a loading
///   placeholder, for instance) present it outside this widget.
class PanelTransition extends StatefulWidget {
  const PanelTransition({
    required this.identity,
    required this.child,
    super.key,
  });

  /// How long the arriving panel takes, and with it the one before it.
  static const Duration duration = Duration(milliseconds: 220);

  /// How far the arriving panel settles up from, in logical pixels.
  static const double settleDistance = 12;

  /// Stable name of the panel in front: the key the transition is keyed by.
  final String identity;

  /// The panel itself. It is never given a key here — [identity] owns it — so
  /// the panel keeps one element for as long as it is the panel in front.
  final Widget child;

  @override
  State<PanelTransition> createState() => _PanelTransitionState();
}

class _PanelTransitionState extends State<PanelTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: PanelTransition.duration,
  );

  /// The panel in front and the last child built for it.
  late String _identity = widget.identity;
  late Widget _presented = widget.child;

  /// The panel fading out underneath, and the child it was last built with.
  String? _leavingIdentity;
  Widget? _leavingChild;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _leavingIdentity != null) {
      setState(() {
        _leavingIdentity = null;
        _leavingChild = null;
      });
    }
  }

  @override
  void didUpdateWidget(PanelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity) {
      // The same panel with new content: rebuild it in place, no motion.
      _presented = widget.child;
      return;
    }
    final bool instant = MediaQuery.disableAnimationsOf(context);
    final String leaving = _identity;
    final Widget leavingChild = _presented;
    setState(() {
      _identity = widget.identity;
      _presented = widget.child;
      _leavingIdentity = instant ? null : leaving;
      _leavingChild = instant ? null : leavingChild;
      if (instant) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? leaving = _leavingIdentity;
    final double progress = leaving == null
        ? 1
        : Curves.easeOutCubic.transform(_controller.value);
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        if (leaving case final String identity)
          _layer(
            identity: identity,
            child: _leavingChild!,
            opacity: 1 - progress,
            interactive: false,
          ),
        _layer(
          identity: _identity,
          child: _presented,
          opacity: progress,
          rise: (1 - progress) * PanelTransition.settleDistance,
          interactive: true,
        ),
      ],
    );
  }

  /// One panel layer. Its shape is identical whether the panel is arriving or
  /// leaving — only properties change — so the panel keeps the same element,
  /// and with it its own state and scroll offset, for the whole transition.
  Widget _layer({
    required String identity,
    required Widget child,
    required double opacity,
    required bool interactive,
    double rise = 0,
  }) {
    return KeyedSubtree(
      key: ValueKey<String>('panel-transition-$identity'),
      child: IgnorePointer(
        ignoring: !interactive,
        child: ExcludeSemantics(
          excluding: !interactive,
          child: ExcludeFocus(
            excluding: !interactive,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(0, rise), child: child),
            ),
          ),
        ),
      ),
    );
  }
}
