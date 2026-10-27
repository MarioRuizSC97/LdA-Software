import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Owns only privacy UI routes, never authentication or server permissions.
/// Tokens bind asynchronous answers to both an identity and a presentation.
class PrivacyCurtain {
  String? _identity;
  int _generation = 0;
  final Set<Route<dynamic>> _routes = {};

  (String?, int) get token => (_identity, _generation);
  bool isCurrent((String?, int) token) => token == this.token;

  void bind(String identity) {
    if (_identity == identity) return;
    invalidate();
    _identity = identity;
  }

  void invalidate() {
    _generation++;
    if (_routes.isEmpty) return;
    final routes = _routes.toList().reversed.toList();
    _routes.clear();
    void dismiss() {
      for (final route in routes) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    }

    // Session replacement/disposal can happen during a widget build. Do not
    // mutate the navigator's overlay while it is building.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      dismiss();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
    }
  }
}

/// Same route semantics as showGeneralDialog, with explicit owner tracking.
Future<T?> showCurtainedDialog<T>({
  required BuildContext context,
  required RoutePageBuilder pageBuilder,
  required bool barrierDismissible,
  required Color barrierColor,
  required Duration transitionDuration,
  String? barrierLabel,
  RouteTransitionsBuilder? transitionBuilder,
  PrivacyCurtain? curtain,
}) {
  final token = curtain?.token;
  final route = RawDialogRoute<T>(
    pageBuilder: (context, animation, secondaryAnimation) =>
        curtain != null && !curtain.isCurrent(token!)
        ? const SizedBox.shrink()
        : pageBuilder(context, animation, secondaryAnimation),
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    transitionDuration: transitionDuration,
    transitionBuilder: transitionBuilder,
  );
  curtain?._routes.add(route);
  return Navigator.of(context, rootNavigator: true).push(route).whenComplete(
    () {
      curtain?._routes.remove(route);
    },
  );
}
