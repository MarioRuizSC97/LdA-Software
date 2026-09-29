import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog/catalog_page.dart';
import 'emulator_session.dart';

typedef EmulatorSessionGatewayLoader =
    Future<EmulatorSessionGateway> Function();

class EmulatorLoginShell extends StatefulWidget {
  const EmulatorLoginShell({
    required this.sessionGateway,
    required this.catalogLoader,
    this.retryLoader,
    super.key,
  });

  final Future<EmulatorSessionGateway> sessionGateway;
  final CatalogSnapshotLoader catalogLoader;
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
  bool _logoutIntent = false;
  int _authGeneration = 0;
  int _streamGeneration = 0;
  _SessionFailure _failure = _SessionFailure.none;

  @override
  void initState() {
    super.initState();
    _load(widget.sessionGateway);
  }

  @override
  void dispose() {
    _authGeneration += 1;
    _streamGeneration += 1;
    _sessionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load(Future<EmulatorSessionGateway> gatewayFuture) async {
    final int generation = ++_authGeneration;
    setState(() {
      _loading = true;
      _failure = _SessionFailure.none;
    });
    late EmulatorSessionGateway gateway;
    try {
      gateway = await gatewayFuture;
    } catch (_) {
      if (!_isCurrentAuthOperation(generation)) return;
      setState(() {
        _gateway = null;
        _session = null;
        _loading = false;
        _failure = _SessionFailure.bootstrap;
      });
      return;
    }
    if (!_isCurrentAuthOperation(generation)) return;
    _gateway = gateway;
    await _restore(gateway, generation: generation);
  }

  Future<void> _restore(
    EmulatorSessionGateway gateway, {
    int? generation,
  }) async {
    final int operation = generation ?? ++_authGeneration;
    setState(() {
      _loading = true;
      _failure = _SessionFailure.none;
      _session = null;
    });
    try {
      final EmulatorSession? session = await gateway.restoreSession();
      if (!_isCurrentAuthOperation(operation)) return;
      await _replaceSessionSubscription(gateway);
      if (!_isCurrentAuthOperation(operation)) return;
      setState(() {
        _session = session;
        _loading = false;
      });
    } on UntrustedSessionException {
      if (_isCurrentAuthOperation(operation)) {
        _showFailure(_SessionFailure.rejected);
      }
    } on EmulatorSessionConnectionException {
      if (_isCurrentAuthOperation(operation)) {
        _showFailure(_SessionFailure.connection);
      }
    } catch (_) {
      if (_isCurrentAuthOperation(operation)) {
        _showFailure(_SessionFailure.connection);
      }
    }
  }

  bool _isCurrentAuthOperation(int generation) =>
      mounted && generation == _authGeneration && !_logoutIntent;

  Future<void> _replaceSessionSubscription(
    EmulatorSessionGateway gateway,
  ) async {
    await _detachSessionSubscription();
    if (!mounted || _logoutIntent) return;
    _listenToSessionChanges(gateway);
  }

  Future<void> _detachSessionSubscription() {
    _streamGeneration += 1;
    final StreamSubscription<EmulatorSession?>? subscription =
        _sessionSubscription;
    _sessionSubscription = null;
    return subscription?.cancel() ?? Future<void>.value();
  }

  void _listenToSessionChanges(EmulatorSessionGateway gateway) {
    final int generation = ++_streamGeneration;
    _sessionSubscription = gateway.sessionChanges().listen(
      (EmulatorSession? session) => _sessionChanged(session, generation),
      onError: (Object error, StackTrace stackTrace) =>
          _sessionChangeFailed(error, stackTrace, generation),
    );
  }

  void _sessionChanged(EmulatorSession? session, int generation) {
    if (!mounted || generation != _streamGeneration) return;
    if (_logoutIntent && session != null) return;
    _authGeneration += 1;
    setState(() {
      _session = session;
      _failure = _SessionFailure.none;
      _loading = false;
    });
  }

  void _sessionChangeFailed(
    Object error,
    StackTrace stackTrace,
    int generation,
  ) {
    if (generation != _streamGeneration || _logoutIntent) return;
    _authGeneration += 1;
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

  int _startLoginAttempt() => ++_authGeneration;

  bool _completeLoginAttempt(int generation, EmulatorSession session) {
    final EmulatorSessionGateway? gateway = _gateway;
    if (!mounted || gateway == null || generation != _authGeneration) {
      return false;
    }
    _authGeneration += 1;
    _logoutIntent = false;
    if (_sessionSubscription == null) _listenToSessionChanges(gateway);
    setState(() => _session = session);
    return true;
  }

  bool _isLoginAttemptCurrent(int generation) =>
      mounted && generation == _authGeneration;

  Future<void> _logout() async {
    final EmulatorSessionGateway? gateway = _gateway;
    if (gateway == null) return;
    _authGeneration += 1;
    _logoutIntent = true;
    final Future<void> detach = _detachSessionSubscription();
    final Future<void> signOut = Future<void>.sync(gateway.logout).then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // The local presentation remains signed out after cleanup failures.
      },
    );
    setState(() => _session = null);
    try {
      await detach;
      await signOut;
    } catch (_) {
      // Subscription cleanup failures also remain fail-closed and sanitized.
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
      return AuthenticatedCatalogPage(
        key: ValueKey<String>(
          '${session.userId}|${session.role.name}|${session.branchId ?? ''}',
        ),
        session: session,
        catalogLoader: widget.catalogLoader,
        onLogout: _logout,
      );
    }
    return _LoginView(
      gateway: _gateway!,
      authGeneration: _authGeneration,
      onLoginStarted: _startLoginAttempt,
      onAuthenticated: _completeLoginAttempt,
      isLoginAttemptCurrent: _isLoginAttemptCurrent,
    );
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
  const _LoginView({
    required this.gateway,
    required this.authGeneration,
    required this.onLoginStarted,
    required this.onAuthenticated,
    required this.isLoginAttemptCurrent,
  });

  final EmulatorSessionGateway gateway;
  final int authGeneration;
  final int Function() onLoginStarted;
  final bool Function(int generation, EmulatorSession session) onAuthenticated;
  final bool Function(int generation) isLoginAttemptCurrent;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void didUpdateWidget(_LoginView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authGeneration != widget.authGeneration) {
      _submitting = false;
      _error = null;
    }
  }

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

    final int generation = widget.onLoginStarted();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final EmulatorSession session = await widget.gateway.login(
        email: email,
        password: password,
      );
      if (mounted) widget.onAuthenticated(generation, session);
    } catch (_) {
      if (!mounted || !widget.isLoginAttemptCurrent(generation)) return;
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
