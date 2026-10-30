import 'package:flutter/material.dart';

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
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Elige una contraseña de al menos '
                '$minimumPasswordLength caracteres.',
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_success != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _success!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
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
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Guardar contraseña'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
