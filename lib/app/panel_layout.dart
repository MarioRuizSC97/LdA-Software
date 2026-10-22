import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Wide panels start here, mirroring catalog_page.dart's private
/// `_compactShellWidth` (600). This is the single breakpoint for panel adopters.
const double panelWideBreakpoint = 600;

/// Space between the primary and context slots on wide layouts.
const double panelColumnGap = 28;

/// Minimum outer horizontal padding of the wide column group.
const double panelHorizontalPadding = 20;

/// Mobile-first panel framing: compact layouts return [primary] unchanged,
/// preserving its existing padding, width limits, and scrolling byte-for-byte.
///
/// At [panelWideBreakpoint] available logical pixels, a non-null [context]
/// appears after [primary] in reading order. The top-aligned group is centered;
/// slots shrink proportionally below their maximum widths. No motion is added.
/// Keep the primary's existing scroll view and pass non-scrolling context
/// content: this widget supplies the rail's independent scroll view. Its height
/// is capped by the parent, or the window height if the parent is unbounded.
class PanelLayout extends StatelessWidget {
  const PanelLayout({
    super.key,
    required this.primary,
    this.context,
    this.maxPrimaryWidth = 600,
    this.maxContextWidth = 340,
  }) : assert(maxPrimaryWidth > 0 && maxPrimaryWidth < double.infinity),
       assert(maxContextWidth > 0 && maxContextWidth < double.infinity);

  /// Existing panel body, including its compact padding and scrolling.
  final Widget primary;

  /// Optional wide-only context content; never mounted in compact layouts.
  final Widget? context;

  /// Maximum width of the primary slot, including the body's own padding.
  final double maxPrimaryWidth;

  /// Maximum width of the independently scrolling context slot.
  final double maxContextWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final Widget? rail = this.context;
      if (constraints.maxWidth < panelWideBreakpoint || rail == null) {
        return primary;
      }
      final double availableWidth =
          constraints.maxWidth - 2 * panelHorizontalPadding - panelColumnGap;
      final double scale = math.min(
        1,
        availableWidth / (maxPrimaryWidth + maxContextWidth),
      );
      final double railHeight = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : MediaQuery.sizeOf(context).height;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: panelHorizontalPadding),
        child: Align(
          alignment: Alignment.topCenter,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: maxPrimaryWidth * scale, child: primary),
              const SizedBox(width: panelColumnGap),
              SizedBox(
                width: maxContextWidth * scale,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: railHeight),
                  child: SingleChildScrollView(primary: false, child: rail),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
