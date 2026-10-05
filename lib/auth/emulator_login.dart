import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog/catalog_page.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import '../catalog/stock_intake.dart';
import '../firebase/emulator_stock_intake_gateway.dart';
import 'emulator_session.dart';

typedef EmulatorSessionGatewayLoader =
    Future<EmulatorSessionGateway> Function();
typedef ProductCreationGatewayLoader = Future<ProductCreationGateway> Function(
  EmulatorSession session,
);
typedef ProductPricingGatewayLoader = Future<ProductPricingGateway> Function(
  EmulatorSession session,
);
typedef StockIntakeGatewayLoader = Future<EmulatorStockIntakeGateway> Function(
  EmulatorSession session,
);

class EmulatorLoginShell extends StatefulWidget {
  const EmulatorLoginShell({
    required this.sessionGateway,
    required this.catalogLoader,
    this.productCreationGatewayLoader,
    this.productPricingGatewayLoader,
    this.stockIntakeGatewayLoader,
    this.retryLoader,
    super.key,
  });

  final Future<EmulatorSessionGateway> sessionGateway;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader? productCreationGatewayLoader;
  final ProductPricingGatewayLoader? productPricingGatewayLoader;
  final StockIntakeGatewayLoader? stockIntakeGatewayLoader;
  final EmulatorSessionGatewayLoader? retryLoader;

  @override
  State<EmulatorLoginShell> createState() => EmulatorLoginShellState();
}

enum _SessionFailure { none, bootstrap, rejected, connection }

class EmulatorLoginShellState extends State<EmulatorLoginShell> {
  EmulatorSessionGateway? _gateway;
  EmulatorSession? _session;
  StreamSubscription<EmulatorSession?>? _sessionSubscription;
  bool _loading = true;
  bool _logoutIntent = false;
  int _authGeneration = 0;
  // Failure feedback is not authentication authority. SDK null events always
  // invalidate success, but cannot identify cleanup versus external sign-out.
  // Only the current explicit attempt may still report a sanitized failure.
  int? _loginFeedbackAttempt;
  int _streamGeneration = 0;
  final ProductCreationDraftStore _productCreationDrafts =
      ProductCreationDraftStore();
  final ProductPricingDraftStore _productPricingDrafts =
      ProductPricingDraftStore();

  // Intake draft retention is intentionally volatile: this store lives only in
  // this live shell state. There is no disk, preference, database, or global
  // singleton persistence, so unresolved intake drafts do not survive shell
  // disposal, browser reload, process restart, or app restart. Keeping the
  // store above the disposable authenticated page is what lets an unresolved
  // intake request survive closing the intake presentation, logout, role
  // replacement, and same-UID administrator reentry on this live shell.
  final StockIntakeDraftStore _stockIntakeDrafts = StockIntakeDraftStore();
  _SessionFailure _failure = _SessionFailure.none;

  @override
  void initState() {
    super.initState();
    _load(widget.sessionGateway);
  }

  @override
  void dispose() {
    _loginFeedbackAttempt = null;
    _authGeneration += 1;
    _streamGeneration += 1;
    _sessionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load(Future<EmulatorSessionGateway> gatewayFuture) async {
    _loginFeedbackAttempt = null;
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
    _loginFeedbackAttempt = null;
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
      (EmulatorSession? session) {
        _sessionChanged(session, generation);
      },
      onError: (Object error, StackTrace stackTrace) {
        _sessionChangeFailed(error, stackTrace, generation);
      },
    );
  }

  void _sessionChanged(EmulatorSession? session, int generation) {
    if (!mounted || generation != _streamGeneration) return;
    if (_logoutIntent && session != null) return;
    if (session != null) _loginFeedbackAttempt = null;
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
    _loginFeedbackAttempt = null;
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

  int _startLoginAttempt() {
    final int generation = ++_authGeneration;
    _loginFeedbackAttempt = generation;
    return generation;
  }

  bool _completeLoginAttempt(int generation, EmulatorSession session) {
    final EmulatorSessionGateway? gateway = _gateway;
    if (!mounted || gateway == null || generation != _authGeneration) {
      return false;
    }
    _loginFeedbackAttempt = null;
    _authGeneration += 1;
    _logoutIntent = false;
    if (_sessionSubscription == null) _listenToSessionChanges(gateway);
    setState(() => _session = session);
    return true;
  }

  bool _mayShowLoginFailure(int generation) =>
      mounted && generation == _loginFeedbackAttempt;

  Future<void> _logout() async {
    final EmulatorSessionGateway? gateway = _gateway;
    if (gateway == null) return;
    _loginFeedbackAttempt = null;
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

  Future<ProductCreationResult> _createProduct(
    ProductCreationDraft draft,
  ) async {
    final EmulatorSession? session = _session;
    final ProductCreationGatewayLoader? loader =
        widget.productCreationGatewayLoader;
    if (!_isExactAdministrator(session) || loader == null) {
      throw const ProductCreationSessionException();
    }

    final ProductCreationAttempt attempt = _productCreationDrafts.begin(
      ownerUserId: session!.userId,
      draft: draft,
    );
    try {
      // Every attempt, including a retry, gets a gateway bound to the current
      // freshly validated session rather than retaining one from a disposed page.
      final ProductCreationGateway gateway = await loader(session);
      final ProductCreationResult result = await gateway.create(draft);
      if (!_isSameCurrentAdministrator(session)) {
        throw const ProductCreationSessionException();
      }
      if (!_productCreationDrafts.resolve(attempt)) {
        throw const ProductCreationStaleException();
      }
      return result;
    } on ProductCreationRejectedException {
      if (!_isSameCurrentAdministrator(session)) {
        throw const ProductCreationSessionException();
      }
      if (!_productCreationDrafts.resolve(attempt)) {
        throw const ProductCreationStaleException();
      }
      rethrow;
    } catch (_) {
      _productCreationDrafts.retain(attempt);
      rethrow;
    }
  }

  Future<ProductPricingResult> _setProductPrice(
    ProductPricingDraft draft,
  ) async {
    final EmulatorSession? session = _session;
    final ProductPricingGatewayLoader? loader =
        widget.productPricingGatewayLoader;
    if (!_isExactAdministrator(session) || loader == null) {
      throw const ProductPricingSessionException();
    }

    // Freeze ownership and the exact payload before gateway initialization or
    // any network operation. Initialization failure therefore remains retryable.
    final ProductPricingAttempt attempt = _productPricingDrafts.begin(
      ownerUserId: session!.userId,
      draft: draft,
    );
    try {
      final ProductPricingGateway gateway = await loader(session);
      final ProductPricingResult result = await gateway.setPrice(draft);
      if (!_isSameCurrentAdministrator(session)) {
        throw const ProductPricingUncertainException();
      }
      if (!_productPricingDrafts.resolve(attempt)) {
        throw const ProductPricingStaleException();
      }
      return result;
    } on ProductPricingRejectedException {
      if (!_isSameCurrentAdministrator(session)) {
        _productPricingDrafts.retain(attempt);
        throw const ProductPricingUncertainException();
      }
      if (!_productPricingDrafts.resolve(attempt)) {
        throw const ProductPricingStaleException();
      }
      rethrow;
    } catch (_) {
      _productPricingDrafts.retain(attempt);
      rethrow;
    }
  }

  /// Exact intake submit API consumed by the authenticated page (intake UI
  /// slice): freezes ownership and the immutable request under the current
  /// exact administrator before gateway initialization or transport, then
  /// resolves only the current attempt's proven success or deterministic
  /// rejection. Every attempt — including a retry — initializes a fresh
  /// gateway bound to the current validated session.
  Future<StockIntakeResult> submitStockIntake(StockIntakeDraft draft) async {
    final EmulatorSession? session = _session;
    final StockIntakeGatewayLoader? loader = widget.stockIntakeGatewayLoader;
    if (!_isExactAdministrator(session) || loader == null) {
      throw const StockIntakeSessionException();
    }

    final StockIntakeAttempt attempt = _stockIntakeDrafts.begin(
      ownerUserId: session!.userId,
      draft: draft,
    );
    try {
      final EmulatorStockIntakeGateway gateway = await loader(session);
      final StockIntakeResult result = await gateway.submitIntake(draft);
      if (!_isSameCurrentAdministrator(session)) {
        throw const StockIntakeUncertainException();
      }
      if (!_stockIntakeDrafts.resolve(attempt)) {
        throw const StockIntakeStaleException();
      }
      return result;
    } on StockIntakeRejectedException {
      if (!_isSameCurrentAdministrator(session)) {
        _stockIntakeDrafts.retain(attempt);
        throw const StockIntakeUncertainException();
      }
      if (!_stockIntakeDrafts.resolve(attempt)) {
        throw const StockIntakeStaleException();
      }
      rethrow;
    } catch (_) {
      _stockIntakeDrafts.retain(attempt);
      rethrow;
    }
  }

  /// Exact intake lookup API the authenticated page (intake UI slice) calls
  /// for an exact (current uid, product id, branch id) unresolved draft. The
  /// draft is returned only while the current session is the same exact UID
  /// with the exact administrator role and a null branch, so sellers, other
  /// administrators, and replaced sessions receive neither fields nor retry
  /// authority.
  StockIntakeDraft? unresolvedStockIntakeDraftFor(
    EmulatorSession originatingSession,
    String productId,
    String branchId,
  ) {
    if (!_isSameCurrentAdministrator(originatingSession)) return null;
    return _stockIntakeDrafts.unresolvedFor(
      originatingSession.userId,
      productId,
      branchId,
    );
  }

  bool _isExactAdministrator(EmulatorSession? session) =>
      session != null &&
      session.role == InventoryRole.administrator &&
      session.branchId == null;
  bool _isSameCurrentAdministrator(EmulatorSession originatingSession) {
    final EmulatorSession? current = _session;
    return _isExactAdministrator(current) &&
        current!.userId == originatingSession.userId;
  }

  StockIntakeDraft? _unresolvedIntakeDraftFor(
    EmulatorSession originatingSession,
    String productId,
    String branchId,
  ) {
    if (!_isSameCurrentAdministrator(originatingSession)) return null;
    return _stockIntakeDrafts.unresolvedFor(
      originatingSession.userId,
      productId,
      branchId,
    );
  }

  ProductPricingDraft? _unresolvedPricingDraftFor(
    EmulatorSession originatingSession,
    String productId,
  ) {
    if (!_isSameCurrentAdministrator(originatingSession)) return null;
    return _productPricingDrafts.unresolvedFor(
      originatingSession.userId,
      productId,
    );
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
        createProduct:
            _isExactAdministrator(session) &&
                widget.productCreationGatewayLoader != null
            ? _createProduct
            : null,
        unresolvedProductDraft: _isExactAdministrator(session)
            ? _productCreationDrafts.unresolvedFor(session.userId)
            : null,
        setProductPrice:
            _isExactAdministrator(session) &&
                widget.productPricingGatewayLoader != null
            ? _setProductPrice
            : null,
        unresolvedPricingDraftForProduct: _isExactAdministrator(session)
            ? (String productId) =>
                  _unresolvedPricingDraftFor(session, productId)
            : null,
        submitStockIntake:
            _isExactAdministrator(session) &&
                widget.stockIntakeGatewayLoader != null
            ? submitStockIntake
            : null,
        unresolvedIntakeDraftFor: _isExactAdministrator(session)
            ? (String productId, String branchId) =>
                  _unresolvedIntakeDraftFor(session, productId, branchId)
            : null,
        onLogout: _logout,
      );
    }
    return _LoginView(
      gateway: _gateway!,
      authGeneration: _authGeneration,
      onLoginStarted: _startLoginAttempt,
      onAuthenticated: _completeLoginAttempt,
      mayShowLoginFailure: _mayShowLoginFailure,
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
    required this.mayShowLoginFailure,
  });

  final EmulatorSessionGateway gateway;
  final int authGeneration;
  final int Function() onLoginStarted;
  final bool Function(int generation, EmulatorSession session) onAuthenticated;
  final bool Function(int generation) mayShowLoginFailure;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;
  String? _error;
  int? _errorAttempt;

  @override
  void didUpdateWidget(_LoginView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authGeneration != widget.authGeneration) {
      _submitting = false;
      if (_errorAttempt == null ||
          !widget.mayShowLoginFailure(_errorAttempt!)) {
        _error = null;
        _errorAttempt = null;
      }
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
      setState(() {
        _errorAttempt = null;
        _error = 'Enter the local demo email and password.';
      });
      return;
    }

    final int generation = widget.onLoginStarted();
    setState(() {
      _submitting = true;
      _error = null;
      _errorAttempt = null;
    });
    try {
      final EmulatorSession session = await widget.gateway.login(
        email: email,
        password: password,
      );
      if (mounted) widget.onAuthenticated(generation, session);
    } catch (_) {
      if (!mounted || !widget.mayShowLoginFailure(generation)) return;
      setState(() {
        _submitting = false;
        _errorAttempt = generation;
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
