import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_info.dart';
import '../app/backend_environment.dart';
import '../app/panel_layout.dart';
import '../app/primary_action_style.dart';
import '../app/theme_mode_switch.dart';
import '../catalog/catalog_page.dart';
import '../catalog/product_creation.dart';
import '../catalog/product_pricing.dart';
import '../catalog/product_rename.dart';
import '../catalog/product_qr_scan.dart';
import '../catalog/stock_intake.dart';
import '../corrections/correction_draft.dart';
import '../corrections/correction_receipt.dart';
import '../corrections/correction_sale.dart';
import '../corrections/sale_corrections.dart';
import 'account_password.dart';
import 'change_password_view.dart';
import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../firebase/emulator_stock_intake_gateway.dart';
import '../firebase/emulator_transfer_gateway.dart';
import '../movements/administrator_movements.dart';
import '../movements/inventory_movement.dart';
import '../movements/seller_profiles.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_cart_controller.dart';
import '../sales/sale_draft.dart';
import '../sales/sale_quote.dart';
import '../transfers/administrator_transfer_form.dart';
import '../transfers/transfer_draft.dart';
import '../transfers/transfer_draft_persistence.dart';
import '../transfers/transfer_draft_persistence_platform.dart';
import '../transfers/transfer_notice_controller.dart';
import 'emulator_bootstrap_diagnostics.dart';
import 'emulator_session.dart';

typedef EmulatorSessionGatewayLoader =
    Future<EmulatorSessionGateway> Function();
typedef ProductCreationGatewayLoader = Future<ProductCreationGateway> Function(
  EmulatorSession session,
);
typedef ProductPricingGatewayLoader = Future<ProductPricingGateway> Function(
  EmulatorSession session,
);
typedef ProductRenameGatewayLoader = Future<ProductRenameGateway> Function(
  EmulatorSession session,
);
typedef StockIntakeGatewayLoader = Future<EmulatorStockIntakeGateway> Function(
  EmulatorSession session,
);
typedef TransferGatewayLoader = Future<EmulatorTransferGateway> Function(
  EmulatorSession session,
);
typedef TransferNoticeBackendSessionLoader =
    Future<TransferNoticeBackend> Function(EmulatorSession session);

class EmulatorLoginShell extends StatefulWidget {
  const EmulatorLoginShell({
    required this.sessionGateway,
    required this.catalogLoader,
    this.productCreationGatewayLoader,
    this.productPricingGatewayLoader,
    this.productRenameGatewayLoader,
    this.stockIntakeGatewayLoader,
    this.saleGatewayLoader,
    this.correctionGatewayLoader,
    this.administratorMovementsLoader,
    this.transferGatewayLoader,
    this.transferNoticeBackendLoader,
    this.transferDraftJournal,
    this.retryLoader,
    this.environment = BackendEnvironment.localEmulator,
    super.key,
  });

  /// Which backend the connection copy names; behavior is identical.
  final BackendEnvironment environment;

  final Future<EmulatorSessionGateway> sessionGateway;
  final CatalogSnapshotLoader catalogLoader;
  final ProductCreationGatewayLoader? productCreationGatewayLoader;
  final ProductPricingGatewayLoader? productPricingGatewayLoader;

  /// Administrator rename gateway loader; null hides the rename section for
  /// every role.
  final ProductRenameGatewayLoader? productRenameGatewayLoader;
  final StockIntakeGatewayLoader? stockIntakeGatewayLoader;

  /// Seller sale gateway loader; null hides the cart for every role.
  final SaleGatewayLoader? saleGatewayLoader;

  /// Seller correction gateway loader; null hides corrections for every role.
  final CorrectionGatewayLoader? correctionGatewayLoader;

  /// Administrator movements backend loader; null hides movements.
  final AdministratorMovementsLoader? administratorMovementsLoader;

  /// Branch-less administrator transfer gateway loader; null hides transfers.
  final TransferGatewayLoader? transferGatewayLoader;

  /// Exact-seller transfer-notice backend loader; null hides the notice badge
  /// and inbox for every role.
  final TransferNoticeBackendSessionLoader? transferNoticeBackendLoader;

  /// Durable unresolved-transfer journal; null uses the platform adapter.
  final TransferDraftJournal? transferDraftJournal;
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
  final _ProductRenameDraftStore _productRenameDrafts =
      _ProductRenameDraftStore();

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

  // Transfer retention is durable, unlike the stores above: the unresolved
  // payload and its frozen key are journaled per owner before anything leaves
  // the device, so they survive closing the form, logout, role replacement,
  // same-UID re-entry, a browser reload, and an app restart. An administrator
  // carries at most one unresolved flow; it is hydrated before the form is
  // offered or a key is minted, never sent automatically, and only cleared by
  // a confirmed settlement of that same key. Unavailable or corrupt storage
  // blocks transfers instead of dropping or recreating the record.
  late final TransferDraftStore _transferDrafts = TransferDraftStore(
    journal:
        widget.transferDraftJournal ?? createPlatformTransferDraftJournal(),
  );

  // Owner whose last confirmed transfer could not be journaled and therefore
  // was never sent; cleared once the journal is trusted again.
  String? _unsentTransferOwner;

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
    } catch (error) {
      reportEmulatorBootstrapFailure(error);
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
  /// A lost session throws a [StateError].
  Future<T> _movementsCall<T>(
    EmulatorSession session,
    Future<T> Function(AdministratorMovementsBackend backend) call,
  ) async {
    _requireSameAdministrator(session);
    final T result = await call(await _movementsBackendFor(session));
    _requireSameAdministrator(session);
    return result;
  }

  void _requireSameAdministrator(EmulatorSession session) {
    if (!_isSameCurrentAdministrator(session)) {
      throw StateError('administrator session changed');
    }
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
          );
        } on MovementsUnavailable {
          // The reader already logged it and kept its cause.
          rethrow;
        } catch (error, stackTrace) {
          logMovementsFailure('Movements load failed', error, stackTrace);
          throw MovementsUnavailable(cause: error, stackTrace: stackTrace);
        }
      },
      readProfile: (String uid) async {
        try {
          return await _movementsCall<SellerProfileLookup>(
            session,
            (AdministratorMovementsBackend backend) =>
                backend.reader.sellerProfile(uid),
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

  /// Exact transfer submit API consumed by the authenticated page.
  ///
  /// The owner and the immutable payload are frozen before the lazy gateway is
  /// built, and the exact branch-less administrator is required again after
  /// that await and before anything leaves the device: a loader that resolves
  /// after a logout must never reach the callable. Only the current attempt's
  /// proven success or deterministic rejection settles the key. A session
  /// change after the request was sent, an unknown transport outcome, a
  /// malformed answer, or a superseded revision keeps the frozen payload under
  /// its own key, because only that key can turn a second send into a replay.
  Future<TransferResult> submitTransfer(TransferDraft draft) async {
    final EmulatorSession? session = _session;
    final TransferGatewayLoader? loader = widget.transferGatewayLoader;
    if (!_isExactAdministrator(session) || loader == null) {
      throw const TransferSessionException();
    }

    // One unresolved flow per owner: a different payload is refused instead of
    // discarding the retained key, while the identical retry stays allowed.
    final List<TransferDraft> retained = _transferDrafts.unresolvedByOwner(
      session!.userId,
    );
    if (retained.isNotEmpty && retained.last != draft) {
      throw const TransferUnresolvedException();
    }
    // The frozen record is durable before the loader or the callable runs; a
    // storage failure means nothing is sent and transfers stay blocked.
    final TransferAttempt attempt;
    try {
      attempt = await _transferDrafts.begin(
        ownerUserId: session.userId,
        draft: draft,
      );
    } on TransferJournalException {
      _unsentTransferOwner = session.userId;
      _transferJournalChanged();
      rethrow;
    }

    try {
      if (!_isSameCurrentAdministrator(session)) {
        throw const TransferUncertainException();
      }
      // Every attempt builds a gateway bound to the current validated session.
      final EmulatorTransferGateway gateway = await loader(session);
      if (!_isSameCurrentAdministrator(session)) {
        throw const TransferUncertainException();
      }
      final TransferResult result = await gateway.submitTransfer(draft);
      if (!_isSameCurrentAdministrator(session)) {
        throw const TransferUncertainException();
      }
      await _settleTransfer(attempt);
      return result;
    } on TransferRejectedException {
      // The server settled the key, but only for the owner that sent it.
      if (!_isSameCurrentAdministrator(session)) {
        _transferDrafts.retain(attempt);
        throw const TransferUncertainException();
      }
      await _settleTransfer(attempt);
      rethrow;
    } catch (_) {
      // Unknown, session-changed, superseded, or an uncleared journal: retain,
      // never reset.
      _transferDrafts.retain(attempt);
      rethrow;
    }
  }

  /// Clears the durable record of a settled attempt. A superseded attempt is
  /// stale; a journal that cannot be cleared keeps the record and blocks.
  Future<void> _settleTransfer(TransferAttempt attempt) async {
    final bool resolved;
    try {
      resolved = await _transferDrafts.resolve(attempt);
    } on TransferJournalException {
      _transferJournalChanged();
      rethrow;
    }
    if (!resolved) throw const TransferStaleException();
  }

  /// The owner's journal status, hydrating it on first sight. Null when the
  /// session can never transfer.
  TransferJournalStatus? _transferJournalFor(EmulatorSession session) {
    if (!_isExactAdministrator(session) ||
        widget.transferGatewayLoader == null ||
        session.userId.isEmpty) {
      return null;
    }
    if (_transferDrafts.statusFor(session.userId) ==
        TransferJournalStatus.unknown) {
      _hydrateTransferJournal(session.userId);
    }
    return _transferDrafts.statusFor(session.userId);
  }

  /// Reads the durable journal; never sends anything to the server.
  void _hydrateTransferJournal(String ownerUserId) {
    _transferDrafts.hydrate(ownerUserId).then((TransferJournalStatus status) {
      if (status == TransferJournalStatus.ready &&
          _unsentTransferOwner == ownerUserId) {
        _unsentTransferOwner = null;
      }
      _transferJournalChanged();
    });
  }

  void _transferJournalChanged() {
    if (mounted) setState(() {});
  }

  /// Exact transfer lookup API the authenticated page calls for the current
  /// session. A retained payload is answered only while the same branch-less
  /// administrator UID is signed in, so a seller, another administrator, or a
  /// replaced session receives neither fields nor retry authority. The most
  /// recent owned request is returned; other keys and owners are never
  /// dropped, and a new key is never minted over a retained flow.
  TransferDraft? unresolvedTransferDraftFor(
    EmulatorSession originatingSession,
  ) {
    if (!_isSameCurrentAdministrator(originatingSession)) return null;
    final List<TransferDraft> retained = _transferDrafts.unresolvedByOwner(
      originatingSession.userId,
    );
    return retained.isEmpty ? null : retained.last;
  }

  /// Both seams or neither: the page needs the submit API and the retained
  /// lookup together, and only for the exact branch-less administrator.
  /// The seams also require a trusted, hydrated journal for this owner.
  TransferSubmit? _transferSubmitFor(EmulatorSession session) =>
      _isExactAdministrator(session) &&
          widget.transferGatewayLoader != null &&
          _transferDrafts.statusFor(session.userId) ==
              TransferJournalStatus.ready
      ? submitTransfer
      : null;

  TransferDraftLookup? _transferLookupFor(EmulatorSession session) =>
      _transferSubmitFor(session) == null
      ? null
      : () => unresolvedTransferDraftFor(session);

  /// The page's notice controller factory, only for the exact seller session
  /// currently signed in. The session checker the controller consults is the
  /// shell's own current session, so a replaced or signed-out seller never
  /// receives late events or acknowledgements.
  TransferNoticeControllerFactory? _transferNoticesFor(
    EmulatorSession session,
  ) {
    if (!_isExactSeller(session) ||
        widget.transferNoticeBackendLoader == null) {
      return null;
    }
    return (EmulatorSession seller) => TransferNoticeController(
      session: seller,
      loadBackend: () => widget.transferNoticeBackendLoader!(seller),
      sessionChecker: () async {
        final EmulatorSession? current = _session;
        return _isSameCurrentSeller(seller) ? current : null;
      },
    );
  }

  /// Exact rename submit API consumed by the authenticated page (S7 rename
  /// slice): freezes ownership and the immutable request under the current
  /// exact administrator before gateway initialization or transport, then
  /// resolves only the current attempt's proven success or deterministic
  /// rejection. Mirrors [EmulatorLoginShellState._setProductPrice]; every
  /// attempt — including a retry — initializes a fresh gateway bound to the
  /// current validated session.
  Future<ProductRenameResult> _renameProduct(ProductRenameDraft draft) async {
    final EmulatorSession? session = _session;
    final ProductRenameGatewayLoader? loader =
        widget.productRenameGatewayLoader;
    if (!_isExactAdministrator(session) || loader == null) {
      throw const ProductRenameSessionException();
    }

    // Freeze ownership and the exact payload before gateway initialization or
    // any network operation. Initialization failure therefore remains retryable.
    final _ProductRenameAttempt attempt = _productRenameDrafts.begin(
      ownerUserId: session!.userId,
      draft: draft,
    );
    try {
      final ProductRenameGateway gateway = await loader(session);
      final ProductRenameResult result = await gateway.renameProduct(draft);
      if (!_isSameCurrentAdministrator(session)) {
        throw const ProductRenameUncertainException();
      }
      if (!_productRenameDrafts.resolve(attempt)) {
        throw const ProductRenameStaleException();
      }
      return result;
    } on ProductRenameRejectedException {
      if (!_isSameCurrentAdministrator(session)) {
        _productRenameDrafts.retain(attempt);
        throw const ProductRenameUncertainException();
      }
      if (!_productRenameDrafts.resolve(attempt)) {
        throw const ProductRenameStaleException();
      }
      rethrow;
    } catch (_) {
      _productRenameDrafts.retain(attempt);
      rethrow;
    }
  }

  /// Exact rename lookup API the authenticated page (S7 rename slice) calls
  /// for the current exact administrator's unresolved rename draft.
  ProductRenameDraft? _unresolvedRenameDraftFor(
    EmulatorSession originatingSession,
    String productId,
  ) {
    if (!_isSameCurrentAdministrator(originatingSession)) return null;
    return _productRenameDrafts.unresolvedFor(
      originatingSession.userId,
      productId,
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
    if (_loading) return _LoadingView(widget.environment);
    switch (_failure) {
      case _SessionFailure.bootstrap:
        return _SessionErrorView(
          title: 'Emulador local de autenticación no disponible',
          canRetry: widget.retryLoader != null,
          onRetry: _retryBootstrap,
        );
      case _SessionFailure.rejected:
        return _SessionErrorView(
          title: 'Sesión rechazada',
          canRetry: true,
          retryLabel: 'Volver a iniciar sesión',
          onRetry: _returnToLogin,
        );
      case _SessionFailure.connection:
        return _SessionErrorView(
          title: 'No se pudo verificar la sesión',
          canRetry: _gateway != null,
          onRetry: _retryRestore,
        );
      case _SessionFailure.none:
        break;
    }
    if (_session case final EmulatorSession session) {
      final TransferJournalStatus? transferJournal = _transferJournalFor(
        session,
      );
      final AccountPasswordGateway? passwordGateway =
          _gateway is AccountPasswordGateway
          ? _gateway! as AccountPasswordGateway
          : null;
      final Widget page = AuthenticatedCatalogPage(
        qrScan: productQrScanSupported ? showProductQrScanner : null,
        passwordSettings: passwordGateway != null
            ? (BuildContext context) => ListTile(
                key: const ValueKey<String>('shell-change-password'),
                leading: const Icon(Icons.password_outlined),
                title: const Text('Cambiar contraseña'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(this.context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          ChangePasswordView(gateway: passwordGateway),
                    ),
                  );
                },
              )
            : null,
        key: ValueKey<String>(
          '${session.userId}|${session.role.name}|${session.branchId ?? ''}',
        ),
        session: session,
        environment: widget.environment,
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
        renameProduct:
            _isExactAdministrator(session) &&
                widget.productRenameGatewayLoader != null
            ? _renameProduct
            : null,
        unresolvedRenameDraftForProduct: _isExactAdministrator(session)
            ? (String productId) =>
                  _unresolvedRenameDraftFor(session, productId)
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
        submitTransfer: _transferSubmitFor(session),
        unresolvedTransferDraft: _transferLookupFor(session),
        createTransferId: _transferSubmitFor(session) == null
            ? null
            : createTransferUuidV4,
        saleCheckout: _saleCheckoutFor(session),
        saleCorrections: _saleCorrectionsFor(session),
        administratorMovements: _administratorMovementsFor(session),
        transferNotices: _transferNoticesFor(session),
        onLogout: _logout,
      );
      if (transferJournal == null) return page;
      final bool blocked =
          transferJournal == TransferJournalStatus.unavailable ||
          transferJournal == TransferJournalStatus.corrupt;
      // One stable tree for every journal status, so the page keeps its state
      // while the notice appears or disappears above it.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (blocked)
            _TransferJournalNotice(
              corrupt: transferJournal == TransferJournalStatus.corrupt,
              unsent: _unsentTransferOwner == session.userId,
              onRetry: () => _hydrateTransferJournal(session.userId),
            ),
          Expanded(
            key: const ValueKey<String>('transfer-journal-page'),
            child: MediaQuery.removePadding(
              context: context,
              removeTop: blocked,
              child: page,
            ),
          ),
        ],
      );
    }
    return _LoginView(
      gateway: _gateway!,
      passwordGateway: _gateway is AccountPasswordGateway
          ? _gateway! as AccountPasswordGateway
          : null,
      authGeneration: _authGeneration,
      onLoginStarted: _startLoginAttempt,
      onAuthenticated: _completeLoginAttempt,
      mayShowLoginFailure: _mayShowLoginFailure,
      environment: widget.environment,
    );
  }
}

const String _transferJournalUnavailableText =
    'No se pudo usar el almacenamiento local de traslados. Los traslados '
    'quedan bloqueados para no duplicar un envío pendiente.';
const String _transferJournalCorruptText =
    'El traslado pendiente guardado en este dispositivo no se puede leer. '
    'Los traslados quedan bloqueados para no duplicar un envío; contacta a '
    'soporte.';
const String _transferJournalUnsentText = 'El último traslado no se envió.';

/// Fail-closed notice shown while the durable transfer journal is untrusted.
class _TransferJournalNotice extends StatelessWidget {
  const _TransferJournalNotice({
    required this.corrupt,
    required this.unsent,
    required this.onRetry,
  });

  final bool corrupt;
  final bool unsent;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey<String>('transfer-journal-blocked'),
      color: colors.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: <Widget>[
              Icon(Icons.lock_outline, color: colors.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        corrupt
                            ? _transferJournalCorruptText
                            : _transferJournalUnavailableText,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                      if (unsent)
                        Text(
                          _transferJournalUnsentText,
                          key: const ValueKey<String>(
                            'transfer-journal-unsent',
                          ),
                          style: TextStyle(color: colors.onErrorContainer),
                        ),
                    ],
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey<String>('transfer-journal-retry'),
                onPressed: onRetry,
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView(this.environment);

  final BackendEnvironment environment;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(environment.connectingLabel),
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
    this.retryLabel = 'Reintentar',
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
            const Text(
              'No se cargaron los datos del catálogo.',
              textAlign: TextAlign.center,
            ),
            if (canRetry) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(
                style: primaryActionStyle(context),
                onPressed: onRetry,
                child: Text(retryLabel),
              ),
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
    this.passwordGateway,
    required this.authGeneration,
    required this.onLoginStarted,
    required this.onAuthenticated,
    required this.mayShowLoginFailure,
    required this.environment,
  });

  final BackendEnvironment environment;
  final EmulatorSessionGateway gateway;

  /// Enables «¿Olvidaste tu contraseña?»; null hides the action.
  final AccountPasswordGateway? passwordGateway;
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
  String? _notice;

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

  /// Sends the reset email. The answer never reveals whether the address has
  /// an account, so the same notice covers every case.
  Future<void> _sendReset() async {
    final AccountPasswordGateway? gateway = widget.passwordGateway;
    if (gateway == null) return;
    final TextEditingController controller = TextEditingController(
      text: _email.text.trim(),
    );
    final String? address = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Restablecer contraseña'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Correo electrónico'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Enviar enlace'),
          ),
        ],
      ),
    );
    if (address == null || address.isEmpty) return;
    try {
      await gateway.sendResetEmail(address);
    } on Object {
      // The same notice answers success and failure on purpose.
    }
    if (!mounted) return;
    setState(() {
      _notice =
          'Si el correo existe, enviamos un enlace para restablecer '
          'la contraseña.';
      _error = null;
      _errorAttempt = null;
    });
  }

  Future<void> _submit() async {
    // Session-generation changes release this guard in didUpdateWidget.
    if (_submitting) return;
    final String email = _email.text.trim();
    final String password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorAttempt = null;
        _error = 'Ingresa el correo y la contraseña de demostración local.';
      });
      return;
    }

    final int generation = widget.onLoginStarted();
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
      _errorAttempt = null;
    });
    try {
      final EmulatorSession session = await widget.gateway.login(
        email: email,
        password: password,
      );
      if (mounted) widget.onAuthenticated(generation, session);
    } catch (error) {
      if (!mounted || !widget.mayShowLoginFailure(generation)) return;
      setState(() {
        _submitting = false;
        _errorAttempt = generation;
        _error = error is LoginFailure
            ? loginFailureText(error)
            : widget.environment.loginFailure;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LDA Inventory')),
    body: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final panel = PanelLayout(
              maxPrimaryWidth: 488,
              context: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Card.filled(
                  key: const ValueKey<String>('login-context'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: DefaultTextStyle(
                      style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '$appName\n$appVersionLabel\n'
                            '${widget.environment.loginTitle}\n\n'
                            'Ingresa con las credenciales de tu tienda.',
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Recordatorios',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'El servidor asigna el código interno permanente y la identidad QR.',
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Solo el administrador puede crear productos, ver movimientos y registrar traslados.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              primary: Center(
                heightFactor: constraints.maxWidth >= panelWideBreakpoint
                    ? 1
                    : null,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Semantics(
                          header: true,
                          child: Text(
                            widget.environment.loginTitle,
                            style: Theme.of(context).textTheme.headlineMedium,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (widget.environment.loginNote
                            case final String note) ...[
                          const SizedBox(height: 12),
                          Text(note, textAlign: TextAlign.center),
                        ],
                        const SizedBox(height: 24),
                        TextFormField(
                          key: const ValueKey<String>('login-email'),
                          controller: _email,
                          enabled: !_submitting,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const <String>[AutofillHints.username],
                          decoration: const InputDecoration(
                            labelText: 'Correo electrónico',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey<String>('login-password'),
                          controller: _password,
                          enabled: !_submitting,
                          obscureText: true,
                          autofillHints: const <String>[AutofillHints.password],
                          decoration: const InputDecoration(
                            labelText: 'Contraseña',
                          ),
                          onFieldSubmitted: (_) =>
                              _submitting ? null : _submit(),
                        ),
                        if (_error case final String error) ...<Widget>[
                          const SizedBox(height: 12),
                          Semantics(liveRegion: true, child: Text(error)),
                        ],
                        if (_notice case final String notice) ...<Widget>[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              notice,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          style: primaryActionStyle(context),
                          onPressed: _submitting ? null : _submit,
                          child: _submitting
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Iniciar sesión'),
                        ),
                        if (widget.passwordGateway != null) ...<Widget>[
                          const SizedBox(height: 8),
                          TextButton(
                            key: const ValueKey<String>(
                              'login-forgot-password',
                            ),
                            onPressed: _submitting ? null : _sendReset,
                            child: const Text('¿Olvidaste tu contraseña?'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
            if (constraints.maxWidth < panelWideBreakpoint) return panel;

            // Together with the app bar, the top inset balances the footer
            // space so the whole group centers on the page, not just the body.
            // Keep scrolling content out of the fixed footer's touch targets.
            final bottomSpace = 80 + MediaQuery.paddingOf(context).bottom;
            return Padding(
              padding: EdgeInsets.only(top: 24, bottom: bottomSpace),
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 24 - bottomSpace).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Center(child: panel),
                ),
              ),
            );
          },
        ),
        Positioned(
          left: 80,
          right: 80,
          bottom: 32,
          child: SafeArea(
            child: Text(
              appVersionLabel,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const Positioned(
          right: 16,
          bottom: 16,
          child: SafeArea(child: ThemeModeSwitch()),
        ),
      ],
    ),
  );
}

/// One in-flight rename per owner and product; the stored draft and its
/// idempotency key stay frozen until a definite outcome resolves them.
class _ProductRenameAttempt {
  const _ProductRenameAttempt({
    required this.ownerUserId,
    required this.draft,
    required this.revision,
  });

  final String ownerUserId;
  final ProductRenameDraft draft;
  final int revision;
}

/// Volatile, live-shell-only retention of unresolved rename requests,
/// mirroring [ProductPricingDraftStore]: an uncertain rename survives closing
/// the price panel, logout, role replacement, and same-UID administrator
/// reentry on this live shell, so its retry reuses the frozen draft and
/// idempotency key. There is no disk, preference, database, or global
/// singleton persistence.
class _ProductRenameDraftStore {
  final Map<String, Map<String, _StoredProductRenameDraft>> _drafts =
      <String, Map<String, _StoredProductRenameDraft>>{};

  ProductRenameDraft? unresolvedFor(String ownerUserId, String productId) =>
      _drafts[ownerUserId]?[productId]?.draft;

  _ProductRenameAttempt begin({
    required String ownerUserId,
    required ProductRenameDraft draft,
  }) {
    if (ownerUserId.isEmpty) throw const ProductRenameSessionException();
    draft.validate();
    final Map<String, _StoredProductRenameDraft> ownerDrafts = _drafts
        .putIfAbsent(ownerUserId, () => <String, _StoredProductRenameDraft>{});
    final _StoredProductRenameDraft? current = ownerDrafts[draft.productId];
    if (current != null && current.draft != draft) {
      throw StateError(
        'an unresolved rename draft already exists for ${draft.productId}',
      );
    }
    final int revision = (current?.revision ?? 0) + 1;
    ownerDrafts[draft.productId] = _StoredProductRenameDraft(draft, revision);
    return _ProductRenameAttempt(
      ownerUserId: ownerUserId,
      draft: draft,
      revision: revision,
    );
  }

  bool isCurrent(_ProductRenameAttempt attempt) {
    final _StoredProductRenameDraft? current =
        _drafts[attempt.ownerUserId]?[attempt.draft.productId];
    return current != null &&
        current.revision == attempt.revision &&
        current.draft == attempt.draft;
  }

  bool resolve(_ProductRenameAttempt attempt) {
    if (!isCurrent(attempt)) return false;
    final Map<String, _StoredProductRenameDraft> ownerDrafts =
        _drafts[attempt.ownerUserId]!;
    ownerDrafts.remove(attempt.draft.productId);
    if (ownerDrafts.isEmpty) _drafts.remove(attempt.ownerUserId);
    return true;
  }

  void retain(_ProductRenameAttempt attempt) {
    // begin() froze the request. Stale attempts cannot recreate or replace it.
  }
}

class _StoredProductRenameDraft {
  const _StoredProductRenameDraft(this.draft, this.revision);

  final ProductRenameDraft draft;
  final int revision;
}
