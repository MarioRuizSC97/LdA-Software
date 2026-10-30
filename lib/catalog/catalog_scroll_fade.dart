import 'package:flutter/material.dart';

/// Keys of the two fade edges, so tests and review can point at one (T9/S10).
const ValueKey<String> catalogScrollFadeTopKey = ValueKey<String>(
  'catalog-scroll-fade-top',
);
const ValueKey<String> catalogScrollFadeBottomKey = ValueKey<String>(
  'catalog-scroll-fade-bottom',
);

/// Static fade edges over the catalog product list (T9/S10): the list melts
/// into the page background where it still has content behind it, so a card is
/// never cut off by a hard line. A bottom edge shows while products remain
/// below, a slimmer top edge once the seller has scrolled down, and a list that
/// fits shows neither.
///
/// The edges are paint, not motion: they hold their place while scrolling and
/// appear or vanish with the content, so reduced motion needs no special case
/// and nothing here adds a frame to the scroll. They never take a tap
/// ([IgnorePointer]), never reach the semantics tree (a decoration contributes
/// no semantics of its own), and never touch layout — the child gets the very
/// constraints it would have had without this widget, so card sizes, keys and
/// the scroll extent are unchanged.
class CatalogScrollFade extends StatefulWidget {
  const CatalogScrollFade({
    required this.child,
    this.bottomExtent = defaultBottomExtent,
    this.topExtent = defaultTopExtent,
    super.key,
  });

  /// Height of the bottom edge, enough to soften a cut-off card.
  static const double defaultBottomExtent = 48;

  /// Height of the top edge: a hint of what scrolled past, not a band.
  static const double defaultTopExtent = 24;

  /// The scrolling child, faded over.
  final Widget child;

  final double bottomExtent;
  final double topExtent;

  @override
  State<CatalogScrollFade> createState() => _CatalogScrollFadeState();
}

class _CatalogScrollFadeState extends State<CatalogScrollFade> {
  /// Visibility from the last metrics read. Offset changes within the same
  /// visibility region must not schedule another build. Both start hidden
  /// until layout reports whether there is any content beyond each edge.
  bool _above = false;
  bool _below = false;

  /// Below this many pixels there is nothing worth fading, which also keeps an
  /// overscroll bounce from flickering an edge in and out.
  static const double _tolerance = 0.5;

  bool _handle(Notification notification) {
    final ScrollMetrics? metrics = switch (notification) {
      final ScrollMetricsNotification changed => changed.metrics,
      final ScrollNotification scrolled => scrolled.metrics,
      _ => null,
    };
    if (metrics != null) _apply(metrics.extentBefore, metrics.extentAfter);
    return false;
  }

  void _apply(double above, double below) {
    final showAbove = above > _tolerance;
    final showBelow = below > _tolerance;
    if (_above == showAbove && _below == showBelow) return;
    setState(() {
      _above = showAbove;
      _below = showBelow;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color background = Theme.of(context).scaffoldBackgroundColor;
    // Scroll metrics are read, never owned: the list keeps its own position.
    // `Notification` is the only type that covers both branches — offset
    // updates while scrolling and dimension changes when the content grows or
    // shrinks, which is also what reports the very first layout.
    return NotificationListener<Notification>(
      onNotification: _handle,
      child: Stack(
        fit: StackFit.passthrough,
        // The child is a scroll view that clips itself and the edges sit inside
        // its box, so a clip layer here would only cost a save layer.
        clipBehavior: Clip.none,
        children: <Widget>[
          widget.child,
          if (_above)
            _edge(
              key: catalogScrollFadeTopKey,
              extent: widget.topExtent,
              background: background,
              downward: false,
            ),
          if (_below)
            _edge(
              key: catalogScrollFadeBottomKey,
              extent: widget.bottomExtent,
              background: background,
              downward: true,
            ),
        ],
      ),
    );
  }

  Widget _edge({
    required Key key,
    required double extent,
    required Color background,
    required bool downward,
  }) {
    return Positioned(
      left: 0,
      right: 0,
      top: downward ? null : 0,
      bottom: downward ? 0 : null,
      height: extent,
      child: IgnorePointer(
        key: key,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: downward ? Alignment.topCenter : Alignment.bottomCenter,
              end: downward ? Alignment.bottomCenter : Alignment.topCenter,
              colors: <Color>[background.withValues(alpha: 0), background],
            ),
          ),
        ),
      ),
    );
  }
}
