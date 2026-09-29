import 'dart:async';

import 'package:flutter/material.dart';

import 'emulator_session.dart';

typedef EmulatorSessionGatewayLoader =
    Future<EmulatorSessionGateway> Function();

class EmulatorLoginShell extends StatefulWidget {
  const EmulatorLoginShell({
    required this.sessionGateway,
    this.retryLoader,
    super.key,
  });

  final Future<EmulatorSessionGateway> sessionGateway;
  final EmulatorSessionGatewayLoader? retryLoader;

  @override
  State<EmulatorLoginShell> createState() => _EmulatorLoginShellState();
}

enum _SessionFailure { none, bootstrap, rejected, connection }

class _EmulatorLoginShellState extends State<EmulatorLoginShell> {
  EmulatorSessionGateway? _gateway;
  EmulatorSession? _session;
  StreamSubscription<EmulatorSession?>? _sessionSubscription;
  bool _loading = true;
  _SessionFailure _failure = _SessionFailure.none;

  @override
  void initState() {
    super.initState();
    _load(widget.sessionGateway);
  }

  @override
  void dispose() {
    _sessionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load(Future<EmulatorSessionGateway> gatewayFuture) async {
    setState(() {
      _loading = true;
      _failure = _SessionFailure.none;
    });
    late EmulatorSessionGateway gateway;
    try {
      gateway = await gatewayFuture;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _gateway = null;
        _session = null;
        _loading = false;
        _failure = _SessionFailure.bootstrap;
      });
      return;
    }
    if (!mounted) return;
    _gateway = gateway;
    await _restore(gateway);
  }

  Future<void> _restore(EmulatorSessionGateway gateway) async {
    setState(() {
      _loading = true;
      _failure = _SessionFailure.none;
      _session = null;
    });
    try {
      final EmulatorSession? session = await gateway.restoreSession();
      if (!mounted) return;
      await _sessionSubscription?.cancel();
      if (!mounted) return;
      _sessionSubscription = gateway.sessionChanges().listen(
        _sessionChanged,
        onError: _sessionChangeFailed,
      );
      setState(() {
        _session = session;
        _loading = false;
      });
    } on UntrustedSessionException {
      _showFailure(_SessionFailure.rejected);
    } on EmulatorSessionConnectionException {
      _showFailure(_SessionFailure.connection);
    } catch (_) {
      _showFailure(_SessionFailure.connection);
    }
  }

  void _sessionChanged(EmulatorSession? session) {
    if (!mounted) return;
    setState(() {
      _session = session;
      _failure = _SessionFailure.none;
      _loading = false;
    });
  }

  void _sessionChangeFailed(Object error, StackTrace stackTrace) {
    _showFailure(
      error is UntrustedSessionException
          ? _SessionFailure.rejected
          : _SessionFailure.connection,
    );
  }

  void _showFailure(_SessionFailure failure) {
    if (!mounted) return;
    setState(() {
      _session = null;
      _loading = false;
      _failure = failure;
    });
  }

  void _retryBootstrap() {
    final EmulatorSessionGatewayLoader? loader = widget.retryLoader;
    if (loader != null) _load(loader());
  }

  void _retryRestore() {
    final EmulatorSessionGateway? gateway = _gateway;
    if (gateway != null) _restore(gateway);
  }

  void _returnToLogin() {
    setState(() {
      _session = null;
      _failure = _SessionFailure.none;
    });
  }

  void _authenticated(EmulatorSession session) {
    setState(() => _session = session);
  }

  Future<void> _logout() async {
    final EmulatorSessionGateway? gateway = _gateway;
    if (gateway == null) return;
    try {
      await gateway.logout();
    } finally {
      if (mounted) setState(() => _session = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _LoadingView();
    switch (_failure) {
      case _SessionFailure.bootstrap:
        return _SessionErrorView(
          title: 'Local Auth emulator unavailable',
          canRetry: widget.retryLoader != null,
          onRetry: _retryBootstrap,
        );
      case _SessionFailure.rejected:
        return _SessionErrorView(
          title: 'Session rejected',
          canRetry: true,
          retryLabel: 'Return to sign in',
          onRetry: _returnToLogin,
        );
      case _SessionFailure.connection:
        return _SessionErrorView(
          title: 'Unable to verify session',
          canRetry: _gateway != null,
          onRetry: _retryRestore,
        );
      case _SessionFailure.none:
        break;
    }
    if (_session case final EmulatorSession session) {
      return _AuthenticatedView(session: session, onLogout: _logout);
    }
    return _LoginView(gateway: _gateway!, onAuthenticated: _authenticated);
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Connecting to local Auth emulator'),
        ],
      ),
    ),
  );
}

class _SessionErrorView extends StatelessWidget {
  const _SessionErrorView({
    required this.title,
    required this.canRetry,
    required this.onRetry,
    this.retryLabel = 'Try again',
  });

  final String title;
  final bool canRetry;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LDA Inventory')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text('Catalog data not loaded.', textAlign: TextAlign.center),
            if (canRetry) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    ),
  );
}

class _LoginView extends StatefulWidget {
  const _LoginView({required this.gateway, required this.onAuthenticated});

  final EmulatorSessionGateway gateway;
  final ValueChanged<EmulatorSession> onAuthenticated;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String email = _email.text.trim();
    final String password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter the local demo email and password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final EmulatorSession session = await widget.gateway.login(
        email: email,
        password: password,
      );
      if (mounted) widget.onAuthenticated(session);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Unable to sign in to the local emulator.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LDA Inventory')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Local emulator sign in',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Catalog data is not connected.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextFormField(
                key: const ValueKey<String>('login-email'),
                controller: _email,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey<String>('login-password'),
                controller: _password,
                enabled: !_submitting,
                obscureText: true,
                autofillHints: const <String>[AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password'),
                onFieldSubmitted: (_) => _submitting ? null : _submit(),
              ),
              if (_error case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AuthenticatedView extends StatelessWidget {
  const _AuthenticatedView({required this.session, required this.onLogout});

  final EmulatorSession session;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('LDA Inventory'),
      actions: <Widget>[
        OutlinedButton(onPressed: onLogout, child: const Text('Log out')),
        const SizedBox(width: 12),
      ],
    ),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.verified_user_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              'Authenticated locally',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(session.email),
            Text('Role: ${session.role.label}'),
            if (session.branchId case final String branchId)
              Text('Branch: $branchId'),
            const SizedBox(height: 16),
            const Text('Catalog data not loaded.', textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}
