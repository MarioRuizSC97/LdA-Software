import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog/catalog_page.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import '../catalog/stock_intake.dart';
import '../corrections/correction_draft.dart';
import '../corrections/correction_receipt.dart';
import '../corrections/correction_sale.dart';
import '../corrections/sale_corrections.dart';
import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../firebase/emulator_stock_intake_gateway.dart';
import '../movements/administrator_movements.dart';
import '../movements/inventory_movement.dart';
import '../movements/seller_profiles.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_cart_controller.dart';
import '../sales/sale_draft.dart';
import '../sales/sale_quote.dart';
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
    this.saleGatewayLoader,
    this.correctionGatewayLoader,
    this.administratorMovementsLoader,
    this.retryLoader,
    super.key,
  });

  final Future<EmulatorSessionGateway> sessionGateway;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader? productCreationGatewayLoader;
  final ProductPricingGatewayLoader? productPricingGatewayLoader;
  final StockIntakeGatewayLoader? stockIntakeGatewayLoader;

  /// Seller sale gateway loader; null hides the cart for every role.
  final SaleGatewayLoader? saleGatewayLoader;

  /// Seller correction gateway loader; null hides corrections for every role.
  final CorrectionGatewayLoader? correctionGatewayLoader;

  /// Administrator movements backend loader; null hides movements.
  final AdministratorMovementsLoader? administratorMovementsLoader;
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

  // Same volatile, live-shell-only retention for sales: an uncertain sale
  // survives closing the cart, logout and same-seller reentry on this shell,
  // so its retry reuses the frozen draft and idempotency key.
  final SaleDraftStore _saleDrafts = SaleDraftStore();

  // One sale gateway per exact seller session, so quote staleness spans the
  // whole cart. A failed initialization is dropped and retried next call.
  String? _saleGatewayOwner;
  Future<EmulatorSaleGateway>? _saleGateway;

  // Likewise one correction gateway per exact seller session; a failed
  // initialization is dropped and retried on the next call.
  String? _correctionGatewayOwner;
  Future<EmulatorCorrectionGateway>? _correctionGateway;

  // Volatile retry storage: at most one unresolved correction per exact
  // seller and branch, retried with the same key until it resolves.
  final CorrectionDraftStore _correctionDrafts = CorrectionDraftStore();

  // One movements backend per exact administrator, so the seller-profile
  // gateway's stale generation spans the screen. A failed load is retried.
  String? _movementsOwner;
  Future<AdministratorMovementsBackend>? _movementsBackend;
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

  bool _isExactSeller(EmulatorSession? session) =>
      session != null &&
      session.role == InventoryRole.seller &&
      session.branchId != null;
  bool _isSameCurrentSeller(EmulatorSession originatingSession) {
    final EmulatorSession? current = _session;
    return _isExactSeller(current) &&
        current!.userId == originatingSession.userId &&
        current.branchId == originatingSession.branchId;
  }

  Future<EmulatorSaleGateway> _saleGatewayFor(EmulatorSession session) async {
    final String owner = '${session.userId}|${session.branchId}';
    if (_saleGatewayOwner != owner) {
      _saleGatewayOwner = owner;
      _saleGateway = null;
    }
    final Future<EmulatorSaleGateway> pending = _saleGateway ??=
        widget.saleGatewayLoader!(session);
    try {
      return await pending;
    } catch (_) {
      if (identical(_saleGateway, pending)) _saleGateway = null;
      rethrow;
    }
  }

  /// Seller quote: the exact current seller, before and after the call.
  Future<SaleQuote> _quoteSale(SaleCart cart) async {
    final EmulatorSession? session = _session;
    if (!_isExactSeller(session) || widget.saleGatewayLoader == null) {
      throw const SaleSessionException();
    }
    final EmulatorSaleGateway gateway = await _saleGatewayFor(session!);
    final SaleQuote quote = await gateway.quote(cart);
    if (!_isSameCurrentSeller(session)) throw const SaleSessionException();
    return quote;
  }

  /// Seller submit, mirroring intake: freezes ownership and the draft before
  /// gateway initialization or transport. Only the current attempt's
  /// deterministic rejection drops the draft, and only its proven success
  /// completes it, keeping the receipt until the seller acknowledges it, so
  /// a sale that commits after its cart closed is never lost. Anything else
  /// keeps the draft stored for a same-key retry.
  Future<SaleReceipt> _submitSale(SaleDraft draft) async {
    final EmulatorSession? session = _session;
    if (!_isExactSeller(session) ||
        widget.saleGatewayLoader == null ||
        draft.branchId != session!.branchId) {
      throw const SaleSessionException();
    }
    final SaleAttempt attempt = _saleDrafts.begin(
      ownerUserId: session.userId,
      draft: draft,
    );
    try {
      final EmulatorSaleGateway gateway = await _saleGatewayFor(session);
      final SaleReceipt receipt = await gateway.submit(draft);
      if (!_isSameCurrentSeller(session)) {
        throw const SaleUncertainException();
      }
      if (!_saleDrafts.complete(attempt, receipt)) {
        throw const SaleStaleException();
      }
      return receipt;
    } on SaleRejectedException {
      if (!_isSameCurrentSeller(session)) {
        throw const SaleUncertainException();
      }
      if (!_saleDrafts.resolve(attempt)) throw const SaleStaleException();
      rethrow;
    }
  }

  Future<EmulatorCorrectionGateway> _correctionGatewayFor(
    EmulatorSession session,
  ) async {
    final String owner = '${session.userId}|${session.branchId}';
    if (_correctionGatewayOwner != owner) {
      _correctionGatewayOwner = owner;
      _correctionGateway = null;
    }
    final Future<EmulatorCorrectionGateway> pending = _correctionGateway ??=
        widget.correctionGatewayLoader!(session);
    try {
      return await pending;
    } catch (_) {
      if (identical(_correctionGateway, pending)) _correctionGateway = null;
      rethrow;
    }
  }

  /// Runs one correction read for the exact current seller, checked before
  /// the gateway is loaded and again after the call returns.
  Future<T> _correctionRead<T>(
    Future<T> Function(EmulatorCorrectionGateway gateway) read,
  ) async {
    final EmulatorSession? session = _session;
    if (!_isExactSeller(session) || widget.correctionGatewayLoader == null) {
      throw const SaleSessionException();
    }
    final EmulatorCorrectionGateway gateway = await _correctionGatewayFor(
      session!,
    );
    final T result = await read(gateway);
    if (!_isSameCurrentSeller(session)) throw const SaleSessionException();
    return result;
  }

  /// Seller correction submit of any kind, mirroring [_submitSale]: freezes
  /// ownership and the draft before gateway initialization or transport.
  /// Only the current attempt's deterministic rejection drops the draft, and
  /// only its proven success completes it, keeping the receipt until the
  /// seller acknowledges it. Anything else keeps the draft stored for a
  /// same-key retry.
  Future<R> _submitCorrection<
    D extends SaleCorrectionDraft,
    R extends SaleCorrectionReceipt
  >(
    D draft,
    Future<R> Function(EmulatorCorrectionGateway gateway, D draft) submit,
  ) async {
    final EmulatorSession? session = _session;
    if (!_isExactSeller(session) ||
        widget.correctionGatewayLoader == null ||
        draft.branchId != session!.branchId) {
      throw const SaleSessionException();
    }
    final CorrectionAttempt attempt = _correctionDrafts.begin(
      ownerUserId: session.userId,
      draft: draft,
    );
    try {
      final EmulatorCorrectionGateway gateway = await _correctionGatewayFor(
        session,
      );
      final R receipt = await submit(gateway, draft);
      if (!_isSameCurrentSeller(session)) {
        throw const SaleUncertainException();
      }
      // Kept with its receipt, not dropped, until the seller has seen it.
      if (!_correctionDrafts.complete(attempt, receipt)) {
        throw const SaleStaleException();
      }
      return receipt;
    } on SaleRejectedException {
      if (!_isSameCurrentSeller(session)) {
        throw const SaleUncertainException();
      }
      if (!_correctionDrafts.resolve(attempt)) {
        throw const SaleStaleException();
      }
      rethrow;
    }
  }

  Future<AdministratorMovementsBackend> _movementsBackendFor(
    EmulatorSession session,
  ) async {
    if (_movementsOwner != session.userId) {
      _movementsOwner = session.userId;
      _movementsBackend = null;
    }
    final Future<AdministratorMovementsBackend> pending = _movementsBackend ??=
        widget.administratorMovementsLoader!(session);
    try {
      return await pending;
    } catch (_) {
      if (identical(_movementsBackend, pending)) _movementsBackend = null;
      rethrow;
    }
  }

  /// Runs one movements operation for the exact current administrator,
  /// checked before the backend is loaded and again after the call returns.
  Future<T> _movementsCall<T>(
    EmulatorSession session,
    Future<T> Function(AdministratorMovementsBackend backend) call,
    Exception Function() lost,
  ) async {
    if (!_isSameCurrentAdministrator(session)) throw lost();
    final T result = await call(await _movementsBackendFor(session));
    if (!_isSameCurrentAdministrator(session)) throw lost();
    return result;
  }

  AdministratorMovements? _administratorMovementsFor(EmulatorSession session) {
    if (!_isExactAdministrator(session) ||
        widget.administratorMovementsLoader == null) {
      return null;
    }
    return AdministratorMovements(
      load: (String? branchId) async {
        try {
          return await _movementsCall<List<MovementEntry>>(
            session,
            (AdministratorMovementsBackend backend) =>
                backend.reader.recentMovements(branchId: branchId),
            () => const MovementsUnavailable(),
          );
        } catch (_) {
          throw const MovementsUnavailable();
        }
      },
      readProfile: (String uid) async {
        try {
          return await _movementsCall<SellerProfileLookup>(
            session,
            (AdministratorMovementsBackend backend) =>
                backend.reader.sellerProfile(uid),
            () => const MovementsUnavailable(),
          );
        } catch (_) {
          return const SellerProfileUnavailable();
        }
      },
      setSellerName: (String uid, String displayName) async {
        if (!_isSameCurrentAdministrator(session)) {
          throw const SellerProfileSessionException();
        }
        final SellerProfileGateway gateway;
        try {
          gateway = (await _movementsBackendFor(session)).profiles;
        } catch (_) {
          // Nothing was sent; retrying the same name is safe.
          throw const SellerProfileUncertainException();
        }
        final SellerProfileResult result = await gateway.setSellerProfile(
          uid: uid,
          displayName: displayName,
        );
        // Written, but the screen's owner changed: report it as uncertain.
        if (!_isSameCurrentAdministrator(session)) {
          throw const SellerProfileUncertainException();
        }
        return result;
      },
    );
  }

  SaleCorrections? _saleCorrectionsFor(EmulatorSession session) {
    if (!_isExactSeller(session) || widget.correctionGatewayLoader == null) {
      return null;
    }
    return SaleCorrections(
      branchId: session.branchId!,
      find: (SaleLookupQuery query) => _correctionRead<CorrectableSale>(
        (EmulatorCorrectionGateway gateway) => gateway.find(query),
      ),
      listRecent: () => _correctionRead<RecentCorrectableSales>(
        (EmulatorCorrectionGateway gateway) => gateway.listRecent(),
      ),
      previewReturn: (SaleReturnPreviewRequest request) =>
          _correctionRead<SaleReturnPreview>(
            (EmulatorCorrectionGateway gateway) =>
                gateway.previewReturn(request),
          ),
      submitReturn: (SaleReturnDraft draft) => _submitCorrection(
        draft,
        (EmulatorCorrectionGateway gateway, SaleReturnDraft draft) =>
            gateway.submitReturn(draft),
      ),
      previewExchange: (SaleExchangePreviewRequest request) =>
          _correctionRead<SaleExchangePreview>(
            (EmulatorCorrectionGateway gateway) =>
                gateway.previewExchange(request),
          ),
      submitReplacement: (SaleReplacementDraft draft) => _submitCorrection(
        draft,
        (EmulatorCorrectionGateway gateway, SaleReplacementDraft draft) =>
            gateway.submitReplacement(draft),
      ),
      submitExchange: (SaleExchangeDraft draft) => _submitCorrection(
        draft,
        (EmulatorCorrectionGateway gateway, SaleExchangeDraft draft) =>
            gateway.submitExchange(draft),
      ),
      unresolvedDraft: () => _isSameCurrentSeller(session)
          ? _correctionDrafts.unresolvedFor(session.userId, session.branchId!)
          : null,
      unacknowledged: () => _isSameCurrentSeller(session)
          ? _correctionDrafts.completedFor(session.userId, session.branchId!)
          : null,
      acknowledge: (SaleCorrectionReceipt receipt) {
        if (!_isSameCurrentSeller(session)) return;
        _correctionDrafts.acknowledge(
          session.userId,
          session.branchId!,
          receipt,
        );
      },
    );
  }

  SaleCheckout? _saleCheckoutFor(EmulatorSession session) {
    if (!_isExactSeller(session) || widget.saleGatewayLoader == null) {
      return null;
    }
    return SaleCheckout(
      branchId: session.branchId!,
      quote: _quoteSale,
      submit: _submitSale,
      unresolvedDraft: () => _isSameCurrentSeller(session)
          ? _saleDrafts.unresolvedFor(session.userId, session.branchId!)
          : null,
      unacknowledgedReceipt: () => _isSameCurrentSeller(session)
          ? _saleDrafts.completedFor(session.userId, session.branchId!)
          : null,
      acknowledge: (SaleReceipt receipt) {
        if (!_isSameCurrentSeller(session)) return;
        _saleDrafts.acknowledge(session.userId, session.branchId!, receipt);
      },
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
        saleCheckout: _saleCheckoutFor(session),
        saleCorrections: _saleCorrectionsFor(session),
        administratorMovements: _administratorMovementsFor(session),
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
