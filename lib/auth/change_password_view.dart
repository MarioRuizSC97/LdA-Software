import 'package:flutter/material.dart';

import '../app/app_info.dart';
import '../app/panel_layout.dart';
import '../app/primary_action_style.dart';
import 'account_password.dart';
import 'emulator_session.dart';

/// Lets a signed-in person replace their password with a new one.
///
/// The change needs the current password: it is the honest proof that the
/// person owns the account and Firebase requires a recent sign-in anyway.
class ChangePasswordView extends StatefulWidget {
  const ChangePasswordView({
    required this.gateway,
    this.minimumLength = minimumPasswordLength,
    super.key,
  });

  final AccountPasswordGateway gateway;
  final int minimumLength;

  @override
  State<ChangePasswordView> createState() => _ChangePasswordViewState();
}

class _ChangePasswordViewState extends State<ChangePasswordView> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _submitting = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final String? problem = validatePasswordChange(
      currentPassword: _current.text,
      newPassword: _next.text,
      repeatedPassword: _repeat.text,
    );
    if (problem != null) {
      setState(() {
        _error = problem;
        _success = null;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });
    try {
      await widget.gateway.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _success = 'Contraseña actualizada.';
        _current.clear();
        _next.clear();
        _repeat.clear();
      });
    } on LoginFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = passwordChangeFailureText(failure);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = loginFailureText(const LoginConnectionFailure());
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cambiar contraseña')),
    // Same two-column framing as the login: the form, and on wide screens a
    // context card with suggestions. Compact screens show the form alone.
    body: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          PanelLayout(
            maxPrimaryWidth: 608,
            context: _suggestions(context),
            primary: Center(
              heightFactor: constraints.maxWidth >= panelWideBreakpoint
                  ? 1
                  : null,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Elige una contraseña de al menos '
                        '$minimumPasswordLength caracteres.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _current,
                        enabled: !_submitting,
                        obscureText: true,
                        autofillHints: const <String>[AutofillHints.password],
                        decoration: const InputDecoration(
                          labelText: 'Contraseña actual',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _next,
                        enabled: !_submitting,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Contraseña nueva',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _repeat,
                        enabled: !_submitting,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Repite la contraseña nueva',
                        ),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      if (_success case final String success) ...<Widget>[
                        const SizedBox(height: 12),
                        Semantics(
                          container: true,
                          liveRegion: true,
                          label: success,
                          child: ExcludeSemantics(
                            child: ColoredBox(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    Icon(
                                      Icons.check_circle_outline,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        success,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        style: primaryActionStyle(context),
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Guardar contraseña'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    ),
  );

  /// Wide-only context card, styled like the login's reminders card.
  Widget _suggestions(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Card.filled(
        key: const ValueKey<String>('change-password-context'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('$appName\n$appVersionLabel\nCambiar contraseña'),
                const SizedBox(height: 24),
                Text(
                  'Sugerencias',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Usa al menos $minimumPasswordLength caracteres.'),
                const SizedBox(height: 12),
                const Text(
                  'Una frase de varias palabras es fácil de recordar y '
                  'difícil de adivinar.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'No uses la misma contraseña que en otros servicios.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Si la olvidas, usa «¿Olvidaste tu contraseña?» al iniciar '
                  'sesión.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
