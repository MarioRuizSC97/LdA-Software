import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Animates mouse wheels; precise trackpad signals and finger drags stay native.
/// Attach the supplied controller to exactly one scroll view in [builder].
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({required this.builder, super.key});
  final Widget Function(BuildContext, ScrollController) builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  late final _WheelController _controller = _WheelController(_animate);
  bool _mouseWheel = false;
  double? _target;
  int _generation = 0;

  bool _animate(double delta) {
    if (!_mouseWheel || MediaQuery.disableAnimationsOf(context)) return false;
    final position = _controller.position;
    final target = ((_target ?? position.pixels) + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final generation = ++_generation;
    _target = target;
    _controller
        .animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (generation == _generation) _target = null;
        });
    return true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => NotificationListener<ScrollStartNotification>(
    onNotification: (notification) {
      if (notification.dragDetails != null) {
        _generation++;
        _target = null;
      }
      return false;
    },
    child: Listener(
      // Dispatch finishes before the native pointer-signal resolver calls the
      // position. Retain its routing/axis/extent logic, changing only the move.
      onPointerSignal: (event) {
        _mouseWheel =
            event is PointerScrollEvent &&
            event.kind == PointerDeviceKind.mouse;
        if (!_mouseWheel || MediaQuery.disableAnimationsOf(context)) {
          _generation++;
          _target = null;
        }
      },
      child: ScrollConfiguration(
        // Finger scrolling on Android/iOS takes the gentler bouncing glide
        // (review R3-001): a fling keeps easing instead of clamping to a hard
        // stop. Web and desktop keep their own platform physics.
        behavior: const _SmoothTouchScrollBehavior(),
        child: widget.builder(context, _controller),
      ),
    ),
  );
}

class _WheelController extends ScrollController {
  _WheelController(this.animate);
  final bool Function(double) animate;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _WheelPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    animate: animate,
  );
}

class _WheelPosition extends ScrollPositionWithSingleContext {
  _WheelPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.animate,
  });
  final bool Function(double) animate;

  @override
  void pointerScroll(double delta) {
    if (!animate(delta)) super.pointerScroll(delta);
  }
}

/// Gives the touch platforms the gentler bouncing glide while leaving every
/// other platform with the framework's own physics.
class _SmoothTouchScrollBehavior extends MaterialScrollBehavior {
  const _SmoothTouchScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
      return const BouncingScrollPhysics(
        parent: RangeMaintainingScrollPhysics(),
      );
    }
    return super.getScrollPhysics(context);
  }
}
