import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/primary_action_style.dart';
import 'minimum_version.dart';

/// Opens a store page outside the app.
Future<void> openStoreUrl(Uri url) async {
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

/// Reloads the web app in the same tab, which fetches the published build.
void reloadWebApp() {
  launchUrl(Uri.base, webOnlyWindowName: '_self');
}

/// Runs the minimum-version [check] before building the app.
///
/// While checking it shows a loading state; a build older than the minimum
/// gets a blocking screen instead of [builder]. A check that throws lets the
/// app in, matching [checkMinimumVersion]'s fail-open policy.
class VersionGate extends StatefulWidget {
  const VersionGate({
    required this.check,
    required this.builder,
    this.loadingLabel = 'Conectando con el servidor',
    this.isWeb = kIsWeb,
    this.platform,
    this.openUrl = openStoreUrl,
    this.reload = reloadWebApp,
    super.key,
  });

  final Future<VersionGateDecision> Function() check;
  final WidgetBuilder builder;
  final String loadingLabel;
  final bool isWeb;

  /// Null uses the running platform.
  final TargetPlatform? platform;
  final Future<void> Function(Uri url) openUrl;
  final VoidCallback reload;

  @override
  State<VersionGate> createState() => _VersionGateState();
}

class _VersionGateState extends State<VersionGate> {
  late final Future<VersionGateDecision> _decision = _safeCheck();

  Future<VersionGateDecision> _safeCheck() async {
    try {
      return await widget.check();
    } on Object {
      return const VersionAllowed();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<VersionGateDecision>(
    future: _decision,
    builder: (BuildContext context, AsyncSnapshot<VersionGateDecision> snap) {
      final VersionGateDecision? decision = snap.data;
      return switch (decision) {
        null => _VersionLoading(label: widget.loadingLabel),
        VersionAllowed() => widget.builder(context),
        UpdateRequired() => _UpdateRequiredView(
          required: decision,
          action: _actionFor(decision),
        ),
      };
    },
  );

  _UpdateAction? _actionFor(UpdateRequired required) {
    if (widget.isWeb) {
      return _UpdateAction('Recargar', widget.reload);
    }
    final Uri? url = switch (widget.platform ?? defaultTargetPlatform) {
      TargetPlatform.android => required.androidUpdateUrl,
      TargetPlatform.iOS => required.iosUpdateUrl,
      _ => null,
    };
    if (url == null) return null;
    return _UpdateAction('Abrir la tienda', () => widget.openUrl(url));
  }
}

class _UpdateAction {
  const _UpdateAction(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}

class _VersionLoading extends StatelessWidget {
  const _VersionLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    ),
  );
}

class _UpdateRequiredView extends StatelessWidget {
  const _UpdateRequiredView({required this.required, required this.action});

  final UpdateRequired required;
  final _UpdateAction? action;

  @override
  Widget build(BuildContext context) {
    final _UpdateAction? action = this.action;
    return Scaffold(
      appBar: AppBar(title: const Text('LDA Inventory')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.system_update_outlined, size: 56),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    'Actualización necesaria',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Hay una versión nueva de LDA Inventory. '
                  'Actualiza la app para continuar.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Versión instalada: ${required.installedVersion}',
                  textAlign: TextAlign.center,
                ),
                Text(
                  'Versión requerida: ${required.minimumVersion}',
                  textAlign: TextAlign.center,
                ),
                if (action != null) ...<Widget>[
                  const SizedBox(height: 24),
                  FilledButton(
                    style: primaryActionStyle(context),
                    onPressed: action.onPressed,
                    child: Text(action.label),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
