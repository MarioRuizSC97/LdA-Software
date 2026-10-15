import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/emulator_session.dart';
import '../corrections/correction_lookup_view.dart';
import '../corrections/sale_corrections.dart';
import '../firebase/emulator_stock_intake_gateway.dart';
import '../movements/administrator_movements.dart';
import '../movements/movements_view.dart';
import '../sales/sale_cart_controller.dart';
import '../sales/sale_cart_panel.dart';
import '../sales/sale_draft.dart';
import '../sales/sale_format.dart';
import '../sales/sale_receipt_view.dart';
import '../transfers/administrator_transfer_form.dart';
import '../transfers/transfer_draft.dart';
import '../transfers/transfer_notice_controller.dart';
import '../transfers/transfer_notices_view.dart';
import 'catalog_product.dart';
import 'catalog_repository.dart';
import 'product_creation.dart';
import 'product_pricing.dart';
import 'product_qr.dart';
import 'stock_intake.dart';

typedef CatalogSnapshotLoader = Future<CatalogSnapshot> Function(
  EmulatorSession session,
);
typedef ProductPricingDraftLookup = ProductPricingDraft? Function(
  String productId,
);
typedef StockIntakeSubmit = Future<StockIntakeResult> Function(
  StockIntakeDraft draft,
);
typedef StockIntakeIdFactory = String Function();
typedef StockIntakeDraftLookup = StockIntakeDraft? Function(
  String productId,
  String branchId,
);

class CatalogPage extends StatefulWidget {
  const CatalogPage({required this.repository, this.statusLabel, super.key});

  final CatalogRepository repository;
  final String? statusLabel;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late Future<List<CatalogProduct>> _products;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) _load();
  }

  void _load() {
    _products = widget.repository.fetchProducts();
  }

  void _retry() {
    setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LDA Inventory')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (widget.statusLabel case final String label)
              _ConnectionStatus(label: label),
            Expanded(
              child: FutureBuilder<List<CatalogProduct>>(
                future: _products,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<CatalogProduct>> snapshot,
                    ) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const _CatalogLoading();
                      }
                      if (snapshot.hasError) {
                        return _CatalogError(onRetry: _retry);
                      }

                      final List<CatalogProduct> products =
                          snapshot.data ?? const <CatalogProduct>[];
                      if (products.isEmpty) return const _EmptyCatalog();
                      return _CatalogList(
                        items: products
                            .map(
                              (CatalogProduct product) => CatalogItem(
                                product: product,
                                holdings: const <CatalogHolding>[],
                              ),
                            )
                            .toList(growable: false),
                      );
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthenticatedCatalogPage extends StatefulWidget {
  const AuthenticatedCatalogPage({
    required this.session,
    required this.catalogLoader,
    required this.onLogout,
    this.createProduct,
    this.createDraftId,
    this.unresolvedProductDraft,
    this.setProductPrice,
    this.createPricingId,
    this.unresolvedPricingDrafts = const <ProductPricingDraft>[],
    this.unresolvedPricingDraftForProduct,
    this.submitStockIntake,
    this.createIntakeId,
    this.unresolvedIntakeDraftFor,
    this.saleCheckout,
    this.onSaleCompleted,
    this.saleCorrections,
    this.administratorMovements,
    this.submitTransfer,
    this.unresolvedTransferDraft,
    this.createTransferId,
    this.transferNotices,
    super.key,
  });

  final EmulatorSession session;
  final CatalogSnapshotLoader catalogLoader;
  final Future<void> Function() onLogout;
  final ProductCreationSubmit? createProduct;
  final ProductDraftIdFactory? createDraftId;
  final ProductCreationDraft? unresolvedProductDraft;
  final ProductPricingSubmit? setProductPrice;
  final ProductPricingIdFactory? createPricingId;
  final List<ProductPricingDraft> unresolvedPricingDrafts;
  final ProductPricingDraftLookup? unresolvedPricingDraftForProduct;
  final StockIntakeSubmit? submitStockIntake;
  final StockIntakeIdFactory? createIntakeId;
  final StockIntakeDraftLookup? unresolvedIntakeDraftFor;

  /// Seller-only sale operations; null hides the cart.
  final SaleCheckout? saleCheckout;

  /// Receives each confirmed sale. Optional: the page itself shows the
  /// receipt from its cart controller.
  final ValueChanged<SaleReceipt>? onSaleCompleted;

  /// Seller-only sale corrections; null hides the "Correcciones" action.
  final SaleCorrections? saleCorrections;

  /// Administrator-only movements; null hides the "Movimientos" action.
  final AdministratorMovements? administratorMovements;

  /// Branch-less administrator transfer submit seam; null hides transfers.
  final TransferSubmit? submitTransfer;

  /// Resumes the shell-retained transfer draft; required with [submitTransfer].
  final TransferDraftLookup? unresolvedTransferDraft;

  /// Mints the stable key for a fresh transfer.
  final TransferIdFactory? createTransferId;

  /// Seller-only transfer-destination notice controller factory; null hides
  /// the badge entry and the inbox. The controller belongs to the page so its
  /// streams stay alive while the seller navigates inside the shell.
  final TransferNoticeControllerFactory? transferNotices;

  @override
  State<AuthenticatedCatalogPage> createState() =>
      _AuthenticatedCatalogPageState();
}

class _AuthenticatedCatalogPageState extends State<AuthenticatedCatalogPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _unit = TextEditingController();
  final TextEditingController _listedPrice = TextEditingController();
  final TextEditingController _ivaRate = TextEditingController();
  final TextEditingController _intakeQuantity = TextEditingController();
  final TextEditingController _intakeCost = TextEditingController();
  CatalogSnapshot? _snapshot;
  ProductCreationCoordinator? _creationCoordinator;
  final Map<String, Timer> _successTimers = <String, Timer>{};
  ProductCreationResult? _creationSuccess;
  ProductCreationDraft? _successfulCreationDraft;
  String? _creationError;
  String? _creationNameError;
  String? _creationUnitError;
  String? _creationPrecisionError;
  int? _creationPrecision;
  bool _creationVisible = false;
  bool _creationPending = false;
  bool _creationUncertain = false;
  CatalogProduct? _pricingProduct;
  ProductPricingDraft? _lockedPricingDraft;
  ProductPricingResult? _pricingSuccess;
  String? _pricingError;
  String? _listedPriceError;
  String? _priceModeError;
  String? _ivaTreatmentError;
  String? _ivaRateError;
  String? _priceMode;
  String? _ivaTreatment;
  bool _pricingPending = false;
  bool _pricingUncertain = false;
  CatalogProduct? _intakeProduct;
  StockIntakeDraft? _lockedIntakeDraft;
  StockIntakeResult? _intakeSuccess;
  String? _intakeError;
  String? _intakeBranchError;
  String? _intakeQuantityError;
  String? _intakeCostError;
  String? _intakeBranch;
  bool _intakePending = false;
  bool _intakeUncertain = false;
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;
  int _creationGeneration = 0;
  // Navigation intent outlives visible forms; it only owns delayed handoffs,
  // never mutation completion, stored drafts, or idempotency keys.
  int _presentationRevision = 0;
  int _pricingGeneration = 0;
  int _intakeGeneration = 0;
  SaleCartController? _sale;
  bool _cartVisible = false;
  bool _correctionsVisible = false;
  bool _movementsVisible = false;
  bool _transferVisible = false;
  bool _noticesVisible = false;
  TransferNoticeController? _noticeController;
  int _transferGeneration = 0;

  /// The global admin snapshot captured when the transfer view opened, the
  /// same way the intake form captures its branch choices. A page refresh
  /// briefly has no snapshot at all, and an authorized flow must never be
  /// made to look like an empty catalog while the administrator is reading its
  /// own receipt banner.
  CatalogSnapshot? _transferSnapshot;

  @override
  void initState() {
    super.initState();
    _configureCreation();
    _configureSale();
    _configureNotices();
    _requestCatalog(initial: true);
  }

  @override
  void didUpdateWidget(AuthenticatedCatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sessionChanged =
        _sessionIdentity(oldWidget.session) != _sessionIdentity(widget.session);
    final ProductCreationCoordinator? coordinator = _creationCoordinator;
    // The shell freezes our request before token refresh can rebuild this
    // page. That matching pending echo is not an uncertain restored request.
    final bool selfOwnedPendingDraft =
        !sessionChanged &&
        oldWidget.createProduct == widget.createProduct &&
        _creationPending &&
        coordinator != null &&
        coordinator.isPending &&
        coordinator.lockedDraft != null &&
        widget.unresolvedProductDraft == coordinator.lockedDraft;
    // A later token frame can observe store resolution during the refresh
    // await. Only our accepted success may consume that exact old draft's null
    // echo; clearing an unresolved or pending foreign request stays authoritative.
    final bool selfOwnedResolvedDraft =
        !sessionChanged &&
        oldWidget.createProduct == widget.createProduct &&
        !_creationPending &&
        coordinator != null &&
        !coordinator.isPending &&
        !coordinator.isLocked &&
        _successfulCreationDraft != null &&
        oldWidget.unresolvedProductDraft == _successfulCreationDraft &&
        widget.unresolvedProductDraft == null;
    if (sessionChanged ||
        oldWidget.createProduct != widget.createProduct ||
        (oldWidget.unresolvedProductDraft != widget.unresolvedProductDraft &&
            !selfOwnedPendingDraft &&
            !selfOwnedResolvedDraft)) {
      _creationGeneration += 1;
      _creationVisible = false;
      _creationPending = false;
      _creationUncertain = false;
      _creationError = null;
      _cancelSuccessNotice('creation');
      _creationSuccess = null;
      _successfulCreationDraft = null;
      _configureCreation();
    }
    if (sessionChanged || oldWidget.setProductPrice != widget.setProductPrice) {
      _pricingGeneration += 1;
      _clearPricingPresentation();
    }
    if (sessionChanged ||
        oldWidget.submitStockIntake != widget.submitStockIntake) {
      _intakeGeneration += 1;
      _clearIntakePresentation();
    }
    final SaleCheckout? checkout = widget.saleCheckout;
    if (sessionChanged ||
        (checkout == null) != (oldWidget.saleCheckout == null)) {
      _sale?.dispose();
      _cartVisible = false;
      _configureSale();
    } else if (checkout != null) {
      _sale?.checkout = checkout;
    }
    if (sessionChanged ||
        (widget.saleCorrections == null) !=
            (oldWidget.saleCorrections == null)) {
      _correctionsVisible = false;
    }
    if (sessionChanged ||
        (widget.administratorMovements == null) !=
            (oldWidget.administratorMovements == null)) {
      _movementsVisible = false;
    }
    // A replaced session or a removed seam cannot keep an open transfer view:
    // the retained draft belongs to the shell, not to this presentation.
    if (sessionChanged ||
        (widget.submitTransfer == null) != (oldWidget.submitTransfer == null) ||
        (widget.unresolvedTransferDraft == null) !=
            (oldWidget.unresolvedTransferDraft == null)) {
      _transferGeneration += 1;
      _transferVisible = false;
      _transferSnapshot = null;
    }
    if (sessionChanged ||
        (widget.transferNotices == null) !=
            (oldWidget.transferNotices == null)) {
      // A replaced session or a removed seam never keeps live notice streams.
      _teardownNotices();
      _noticesVisible = false;
      _configureNotices();
    }
    if (sessionChanged) _requestCatalog();
  }

  SaleCorrections? get _corrections =>
      widget.session.role == InventoryRole.seller
      ? widget.saleCorrections
      : null;

  void _showCorrections() {
    _presentationRevision += 1;
    setState(() {
      _cartVisible = false;
      _correctionsVisible = true;
    });
  }

  AdministratorMovements? get _movements =>
      widget.session.role == InventoryRole.administrator &&
          widget.session.branchId == null
      ? widget.administratorMovements
      : null;

  void _showMovements() {
    _presentationRevision += 1;
    setState(() => _movementsVisible = true);
  }

  void _closeMovements() {
    _presentationRevision += 1;
    setState(() => _movementsVisible = false);
  }

  /// Transfers need both seams and the exact branch-less administrator: a
  /// seller, a branch-bound account, or an unwired shell gets no entry.
  TransferSubmit? get _transfer =>
      widget.session.role == InventoryRole.administrator &&
          widget.session.branchId == null &&
          widget.submitTransfer != null &&
          widget.unresolvedTransferDraft != null
      ? widget.submitTransfer
      : null;

  void _showTransfer() {
    _presentationRevision += 1;
    setState(() {
      _transferSnapshot = _snapshot;
      // The transfer form takes over the whole body, so any other open admin
      // view must close here or the body priority would keep it on screen and
      // the entry would look like a dead end. Nothing else is reset.
      _movementsVisible = false;
      _correctionsVisible = false;
      _transferVisible = true;
    });
  }

  void _closeTransfer() {
    _presentationRevision += 1;
    setState(() {
      _transferVisible = false;
      _transferSnapshot = null;
    });
  }

  /// A settled transfer moved stock in two branches, so the page re-runs the
  /// catalog load it is already authorized to perform and keeps its current
  /// view: no new query path, no extra read, and the ledger parser untouched.
  /// A late answer from a replaced session is dropped instead of completing
  /// into the new one.
  void _onTransferCompleted(int generation) {
    if (!mounted || generation != _transferGeneration) return;
    _requestCatalog();
  }

  /// The form gets the whole authorized admin snapshot — every branch choice
  /// and every product — never the currently visible rows, and it owns its own
  /// pending, confirmation, and frozen state. This page only supplies the
  /// seams, the snapshot, and the navigation handoff.
  Widget _transferForm(TransferSubmit submit) {
    final CatalogSnapshot? source = _transferSnapshot;
    // Captured at build time, so a completion that somehow arrives after this
    // presentation was already replaced cannot refresh the new session.
    final int generation = _transferGeneration;
    return AdministratorTransferForm(
      ownerUserId: widget.session.userId,
      branches: source?.branchChoices ?? const <CatalogBranchChoice>[],
      products: <CatalogProduct>[
        for (final CatalogItem item in source?.items ?? const <CatalogItem>[])
          item.product,
      ],
      submitTransfer: submit,
      unresolvedDraft: widget.unresolvedTransferDraft!,
      onClose: _closeTransfer,
      // The receipt and its Spanish banner belong to the form; the page only
      // needs the settled signal to re-run the catalog load it already owns.
      onCompleted: (TransferResult result) => _onTransferCompleted(generation),
      createTransferId: widget.createTransferId ?? createTransferUuidV4,
    );
  }

  void _closeCorrections() {
    _presentationRevision += 1;
    setState(() => _correctionsVisible = false);
  }

  void _configureNotices() {
    if (widget.session.role != InventoryRole.seller) return;
    final TransferNoticeController? controller = widget.transferNotices?.call(
      widget.session,
    );
    if (controller == null) return;
    controller.addListener(_onNoticesChanged);
    controller.start();
    _noticeController = controller;
  }

  void _onNoticesChanged() {
    if (mounted) setState(() {});
  }

  void _teardownNotices() {
    _noticeController?.removeListener(_onNoticesChanged);
    _noticeController?.dispose();
    _noticeController = null;
  }

  void _showNotices() {
    _presentationRevision += 1;
    setState(() {
      _cartVisible = false;
      _correctionsVisible = false;
      _noticesVisible = true;
    });
  }

  void _closeNotices() {
    _presentationRevision += 1;
    setState(() => _noticesVisible = false);
  }

  /// The explicit ack path. Opening the inbox never writes; only this user
  /// action reaches the callable. A session loss abandons silently because
  /// the shell rebuilds the page for the new owner; any other failure is
  /// surfaced without inventing success.
  Future<void> _markNoticeRead(String transferId) async {
    final TransferNoticeController? controller = _noticeController;
    if (controller == null) return;
    try {
      await controller.markRead(transferId);
    } on TransferNoticeSessionException {
      return;
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo marcar el aviso como leído. Reintenta.'),
        ),
      );
    }
  }

  /// Product names from the loaded catalog, for correction lines.
  Map<String, String> _productNames() => <String, String>{
    for (final CatalogItem item in _snapshot?.items ?? const <CatalogItem>[])
      item.product.internalCode: item.product.name,
  };

  /// The loaded catalog's products; the exchange form offers the priced
  /// ones as new items. Prices are shown for reference only: the server
  /// prices every exchange.
  List<CatalogProduct> _catalogProducts() => <CatalogProduct>[
    for (final CatalogItem item in _snapshot?.items ?? const <CatalogItem>[])
      item.product,
  ];

  void _configureSale() {
    final SaleCheckout? checkout = widget.saleCheckout;
    _sale = widget.session.role == InventoryRole.seller && checkout != null
        ? SaleCartController(
            checkout: checkout,
            onCompleted: _saleCompleted,
            onReceiptPending: _saleReceiptPending,
          )
        : null;
  }

  /// A cart action found a committed sale the seller has not acknowledged:
  /// leave the cart so its receipt is shown first.
  void _saleReceiptPending() {
    if (!mounted) return;
    setState(() => _cartVisible = false);
  }

  /// Opens the cart, unless a committed sale awaits acknowledgement: then
  /// its receipt is shown instead.
  void _openCart(SaleCartController sale) {
    final bool receiptPending = sale.reconcileOnOpen();
    setState(() => _cartVisible = !receiptPending);
  }

  void _saleCompleted(SaleReceipt receipt) {
    if (!mounted) return;
    setState(() => _cartVisible = false);
    _requestCatalog();
    widget.onSaleCompleted?.call(receipt);
  }

  /// "Nueva venta": dismiss the receipt and return to the empty cart and
  /// the catalog.
  void _startNewSale() {
    _sale?.dismissReceipt();
    setState(() => _cartVisible = false);
  }

  void _cancelSuccessNotice(String category) {
    _successTimers.remove(category)?.cancel();
  }

  // Presentation-only ownership: never changes requests or handoff authority.
  void _expireSuccessNotice(String category, VoidCallback clear) {
    _cancelSuccessNotice(category);
    late final Timer timer;
    timer = Timer(const Duration(seconds: 10), () {
      if (!mounted || !identical(_successTimers[category], timer)) return;
      _successTimers.remove(category);
      setState(clear);
    });
    _successTimers[category] = timer;
  }

  @override
  void dispose() {
    for (final Timer timer in _successTimers.values) {
      timer.cancel();
    }
    _successTimers.clear();
    _generation += 1;
    _creationGeneration += 1;
    _pricingGeneration += 1;
    _intakeGeneration += 1;
    _transferGeneration += 1;
    _transferSnapshot = null;
    _teardownNotices();
    _sale?.dispose();
    _name.dispose();
    _unit.dispose();
    _listedPrice.dispose();
    _ivaRate.dispose();
    _intakeQuantity.dispose();
    _intakeCost.dispose();
    super.dispose();
  }

  void _configureCreation() {
    _name.clear();
    _unit.clear();
    _creationPrecision = null;
    _creationNameError = null;
    _creationUnitError = null;
    _creationPrecisionError = null;
    final ProductCreationSubmit? submit = widget.createProduct;
    if (widget.session.role != InventoryRole.administrator || submit == null) {
      _creationCoordinator = null;
      return;
    }
    final ProductCreationDraft? unresolved = widget.unresolvedProductDraft;
    _creationCoordinator = ProductCreationCoordinator(
      createIdempotencyKey: widget.createDraftId ?? createProductDraftUuidV4,
      submitRequest: submit,
      restoredDraft: unresolved,
    );
    if (unresolved != null) {
      _name.text = unresolved.name;
      _unit.text = unresolved.unit;
      _creationPrecision = unresolved.precision;
      _creationVisible = true;
      _creationUncertain = true;
      _creationError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
    }
  }

  void _clearPricingPresentation() {
    _cancelSuccessNotice('pricing');
    _pricingSuccess = null;
    _pricingProduct = null;
    _lockedPricingDraft = null;
    _pricingError = null;
    _listedPriceError = null;
    _priceModeError = null;
    _ivaTreatmentError = null;
    _ivaRateError = null;
    _priceMode = null;
    _ivaTreatment = null;
    _pricingPending = false;
    _pricingUncertain = false;
    _listedPrice.clear();
    _ivaRate.clear();
  }

  void _restorePricingDraft(CatalogSnapshot snapshot) {
    if (widget.session.role != InventoryRole.administrator ||
        widget.setProductPrice == null ||
        _pricingProduct != null ||
        _pricingSuccess != null) {
      return;
    }
    for (final CatalogItem item in snapshot.items) {
      final ProductPricingDraft? draft = _unresolvedPricingDraftFor(
        item.product.internalCode,
      );
      if (draft == null) continue;
      _pricingProduct = item.product;
      _lockPricingDraft(draft);
      break;
    }
  }

  ProductPricingDraft? _unresolvedPricingDraftFor(String productId) {
    final ProductPricingDraftLookup? liveLookup =
        widget.unresolvedPricingDraftForProduct;
    if (liveLookup != null) return liveLookup(productId);
    for (final ProductPricingDraft draft in widget.unresolvedPricingDrafts) {
      if (draft.productId == productId) return draft;
    }
    return null;
  }

  void _lockPricingDraft(ProductPricingDraft draft) {
    _listedPriceError = null;
    _priceModeError = null;
    _ivaTreatmentError = null;
    _ivaRateError = null;
    _lockedPricingDraft = draft;
    _listedPrice.text = draft.listedPriceMxn;
    _priceMode = draft.priceMode;
    _ivaTreatment = draft.ivaTreatment;
    _ivaRate.text = draft.ivaRatePercent ?? '';
    _pricingUncertain = true;
    _pricingError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
  }

  void _clearIntakePresentation() {
    _cancelSuccessNotice('intake');
    _intakeSuccess = null;
    _intakeProduct = null;
    _lockedIntakeDraft = null;
    _intakeError = null;
    _intakeBranchError = null;
    _intakeQuantityError = null;
    _intakeCostError = null;
    _intakeBranch = null;
    _intakePending = false;
    _intakeUncertain = false;
    _intakeQuantity.clear();
    _intakeCost.clear();
  }

  StockIntakeDraft? _unresolvedIntakeDraftFor(
    String productId,
    String branchId,
  ) {
    final StockIntakeDraftLookup? liveLookup = widget.unresolvedIntakeDraftFor;
    if (liveLookup == null) return null;
    return liveLookup(productId, branchId);
  }

  void _lockIntakeDraft(StockIntakeDraft draft) {
    _intakeBranchError = null;
    _intakeQuantityError = null;
    _intakeCostError = null;
    _lockedIntakeDraft = draft;
    _intakeBranch = draft.branchId;
    _intakeQuantity.text = draft.quantity;
    _intakeCost.text = draft.unitCostMxn;
    _intakeUncertain = true;
    _intakeError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
  }

  /// Loads the catalog and returns the accepted snapshot, or null when the
  /// load failed or a newer request or disposal superseded it.
  Future<CatalogSnapshot?> _requestCatalog({bool initial = false}) async {
    final int generation = ++_generation;
    if (initial) {
      _snapshot = null;
      _loading = true;
      _failed = false;
    } else {
      setState(() {
        _snapshot = null;
        _loading = true;
        _failed = false;
      });
    }

    try {
      final CatalogSnapshot snapshot = await widget.catalogLoader(
        widget.session,
      );
      _validateCatalogSnapshot(snapshot, widget.session);
      if (!mounted || generation != _generation) return null;
      setState(() {
        _restorePricingDraft(snapshot);
        _snapshot = snapshot;
        _loading = false;
      });
      return snapshot;
    } catch (_) {
      if (!mounted || generation != _generation) return null;
      setState(() {
        _snapshot = null;
        _loading = false;
        _failed = true;
      });
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final SaleCartController? sale = _sale;
    final SaleReceipt? receipt = sale?.lastReceipt;
    final SaleCorrections? corrections = _corrections;
    final bool showCorrections = corrections != null && _correctionsVisible;
    final AdministratorMovements? movements = _movements;
    final bool showMovements = movements != null && _movementsVisible;
    final TransferSubmit? transfer = _transfer;
    final bool showTransfer = transfer != null && _transferVisible;
    final TransferNoticeController? noticeController =
        widget.session.role == InventoryRole.seller ? _noticeController : null;
    final bool showNotices = noticeController != null && _noticesVisible;
    final int? unreadNotices = noticeController?.state.unreadCount;
    // Text actions collapse into an overflow menu when the window (measured
    // in unscaled text units) cannot hold them next to the title.
    final bool compactBar =
        MediaQuery.sizeOf(context).width <
        _compactShellWidth * MediaQuery.textScalerOf(context).scale(1);
    final VoidCallback? openCorrections = showCorrections || showTransfer
        ? null
        : _showCorrections;
    final VoidCallback? openMovements = showMovements || showTransfer
        ? null
        : _showMovements;
    return Scaffold(
      bottomNavigationBar:
          sale != null &&
              receipt == null &&
              !_cartVisible &&
              !showCorrections &&
              !showNotices
          ? SaleCartButton(controller: sale, onPressed: () => _openCart(sale))
          : null,
      appBar: AppBar(
        title: const Text('LDA Inventory'),
        actions: <Widget>[
          if (corrections != null && !compactBar)
            TextButton.icon(
              key: const ValueKey<String>('corrections-open'),
              onPressed: openCorrections,
              icon: const Icon(Icons.assignment_return_outlined),
              label: const Text('Correcciones'),
            ),
          if (noticeController != null)
            IconButton(
              key: const ValueKey<String>('notices-open'),
              tooltip: 'Avisos de traslados',
              onPressed: showNotices ? null : _showNotices,
              // Screen readers hear the badge state in words, not the bare
              // count or the '!' glyph.
              icon: Semantics(
                label: unreadNotices == null
                    ? 'sin confirmar'
                    : unreadNotices > 0
                    ? '$unreadNotices sin leer'
                    : null,
                child: ExcludeSemantics(
                  child: Badge(
                    isLabelVisible: unreadNotices == null || unreadNotices > 0,
                    label: Text(unreadNotices == null ? '!' : '$unreadNotices'),
                    backgroundColor: unreadNotices == null
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : null,
                    child: const Icon(Icons.inbox_outlined),
                  ),
                ),
              ),
            ),
          if (movements != null && !compactBar)
            TextButton.icon(
              key: const ValueKey<String>('movements-open'),
              onPressed: openMovements,
              icon: const Icon(Icons.swap_vert),
              label: const Text('Movimientos'),
            ),
          IconButton(
            tooltip: 'Actualizar catálogo',
            onPressed: _loading ? null : _requestCatalog,
            icon: const Icon(Icons.refresh),
          ),
          if (compactBar)
            PopupMenuButton<VoidCallback>(
              key: const ValueKey<String>('shell-more'),
              onSelected: (VoidCallback action) => action(),
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<VoidCallback>>[
                    if (corrections != null)
                      PopupMenuItem<VoidCallback>(
                        key: const ValueKey<String>('corrections-open'),
                        enabled: openCorrections != null,
                        value: openCorrections,
                        child: const ListTile(
                          leading: Icon(Icons.assignment_return_outlined),
                          title: Text('Correcciones'),
                        ),
                      ),
                    if (movements != null)
                      PopupMenuItem<VoidCallback>(
                        key: const ValueKey<String>('movements-open'),
                        enabled: openMovements != null,
                        value: openMovements,
                        child: const ListTile(
                          leading: Icon(Icons.swap_vert),
                          title: Text('Movimientos'),
                        ),
                      ),
                    PopupMenuItem<VoidCallback>(
                      value: widget.onLogout,
                      child: const ListTile(
                        leading: Icon(Icons.logout),
                        title: Text('Cerrar sesión'),
                      ),
                    ),
                  ],
            )
          else ...<Widget>[
            OutlinedButton(
              onPressed: widget.onLogout,
              child: const Text('Cerrar sesión'),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _SessionStatus(session: widget.session),
            if (_creationSuccess case final ProductCreationResult result)
              _CreationSuccess(result: result),
            if (_pricingSuccess case final ProductPricingResult result)
              _PricingSuccess(result: result),
            if (_intakeSuccess case final StockIntakeResult result)
              _IntakeSuccess(result: result),
            if (transfer != null)
              _TransferToolbar(
                enabled: !showTransfer,
                onPressed: _showTransfer,
              ),
            if (_creationCoordinator != null && !showMovements && !showTransfer)
              _CreationToolbar(
                onPressed: _creationPending ? null : _showCreation,
              ),
            Expanded(
              child: showMovements
                  ? MovementsView(
                      movements: movements,
                      productNames: _productNames(),
                      branchChoices:
                          _snapshot?.branchChoices ??
                          const <CatalogBranchChoice>[],
                      onClose: _closeMovements,
                    )
                  : showCorrections
                  ? CorrectionLookupView(
                      corrections: corrections,
                      productNames: _productNames(),
                      products: _catalogProducts(),
                      onClose: _closeCorrections,
                    )
                  : transfer != null && _transferVisible
                  ? _transferForm(transfer)
                  : showNotices
                  ? TransferNoticesView(
                      state: noticeController.state,
                      productNames: _productNames(),
                      onMarkRead: _markNoticeRead,
                      onClose: _closeNotices,
                      onRetry: noticeController.retry,
                    )
                  : receipt != null
                  ? SaleReceiptView(
                      receipt: receipt,
                      notice: sale?.receiptPending ?? false
                          ? salePendingReceiptMessage
                          : null,
                      onNewSale: _startNewSale,
                    )
                  : sale != null && _cartVisible
                  ? SaleCartPanel(
                      controller: sale,
                      onClose: () => setState(() => _cartVisible = false),
                    )
                  : _creationVisible
                  ? _creationForm()
                  : _pricingProduct != null
                  ? _pricingForm()
                  : _intakeProduct != null
                  ? _intakeForm()
                  : _catalogBody(),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreation() {
    _presentationRevision += 1;
    setState(() => _creationVisible = true);
  }

  void _closeCreation() {
    _presentationRevision += 1;
    _creationCoordinator?.closePresentation();
    setState(() => _creationVisible = false);
  }

  Future<void> _submitCreation() async {
    final ProductCreationCoordinator? coordinator = _creationCoordinator;
    if (coordinator == null || _creationPending) return;
    final int generation = ++_creationGeneration;
    int? precision;
    if (!_creationUncertain) {
      // One pass reports every applicable missing or invalid required field
      // before any gateway call. Empty fields read as required; non-empty
      // invalid values use the canonical client messages. The server stays
      // authoritative: its validation still reports through the banner.
      precision = _creationPrecision;
      final String? nameError = _creationNameFieldError(_name.text);
      final String? unitError = _creationUnitFieldError(_unit.text);
      final String? precisionError = _creationPrecisionFieldError(precision);
      if (nameError != null || unitError != null || precisionError != null) {
        setState(() {
          _creationError = null;
          _creationNameError = nameError;
          _creationUnitError = unitError;
          _creationPrecisionError = precisionError;
        });
        return;
      }
    }

    final int presentationRevision = ++_presentationRevision;
    setState(() {
      _creationPending = true;
      _creationError = null;
      _successfulCreationDraft = null;
    });
    try {
      final Future<ProductCreationResult> pending = _creationUncertain
          ? coordinator.retry()
          : coordinator.submit(
              name: _name.text,
              unit: _unit.text,
              precision: precision!,
            );
      final ProductCreationDraft? submittedDraft = coordinator.lockedDraft;
      final ProductCreationResult result = await pending;
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = false;
        _creationVisible = false;
        _creationSuccess = result;
        _expireSuccessNotice('creation', () => _creationSuccess = null);
        _successfulCreationDraft = submittedDraft;
        _name.clear();
        _unit.clear();
        _creationPrecision = null;
        _creationNameError = null;
        _creationUnitError = null;
        _creationPrecisionError = null;
      });
      final CatalogSnapshot? refreshed = await _requestCatalog();
      if (refreshed == null) return;
      if (!mounted ||
          generation != _creationGeneration ||
          presentationRevision != _presentationRevision) {
        return;
      }
      _openPricingForCreated(result, refreshed);
    } on ProductCreationValidationException catch (error) {
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = false;
        _creationError = error.message;
      });
    } on ProductCreationRejectedException catch (error) {
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = false;
        _creationError = 'Se rechazó la creación del producto (${error.code}).';
      });
    } on ProductCreationStaleException {
      // A newer attempt or session owns presentation authority.
    } catch (_) {
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = true;
        _creationError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
      });
    }
  }

  /// Chains creation to pricing: opens the ordinary, empty pricing form for
  /// the new product, never submitting and never overriding a form that
  /// already owns the screen.
  void _openPricingForCreated(
    ProductCreationResult result,
    CatalogSnapshot snapshot,
  ) {
    if (widget.session.role != InventoryRole.administrator ||
        widget.setProductPrice == null ||
        _creationVisible ||
        _pricingProduct != null ||
        _pricingPending ||
        _pricingUncertain ||
        _intakeProduct != null) {
      return;
    }
    for (final CatalogItem item in snapshot.items) {
      if (item.product.internalCode == result.internalCode) {
        _showPricing(item.product);
        return;
      }
    }
  }

  Widget _creationForm() {
    final bool locked = _creationPending || _creationUncertain;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Crear producto',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'El servidor asigna el código interno permanente y la identidad QR.',
              ),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                liveRegion: _creationNameError != null,
                label: _creationNameError == null
                    ? null
                    : 'Error en el nombre del producto: $_creationNameError',
                child: TextFormField(
                  key: const ValueKey<String>('create-product-name'),
                  controller: _name,
                  enabled: !locked,
                  maxLength: maxProductNameLength,
                  onChanged: (_) {
                    if (_creationNameError == null) return;
                    setState(() => _creationNameError = null);
                  },
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Nombre del producto',
                      border: _pricingFieldBorder,
                    ),
                    _creationNameError,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                container: true,
                liveRegion: _creationUnitError != null,
                label: _creationUnitError == null
                    ? null
                    : 'Error en la unidad: $_creationUnitError',
                child: TextFormField(
                  key: const ValueKey<String>('create-product-unit'),
                  controller: _unit,
                  enabled: !locked,
                  onChanged: (_) {
                    if (_creationUnitError == null) return;
                    setState(() => _creationUnitError = null);
                  },
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Identificador de unidad',
                      border: _pricingFieldBorder,
                      helperText: 'Identificador en minúsculas, por ejemplo piece o kg.',
                    ),
                    _creationUnitError,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                container: true,
                liveRegion: _creationPrecisionError != null,
                label: _creationPrecisionError == null
                    ? null
                    : 'Error en la precisión: $_creationPrecisionError',
                child: DropdownButtonFormField<int>(
                  key: const ValueKey<String>('create-product-precision'),
                  isExpanded: true,
                  initialValue: _creationPrecision,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Precisión de cantidad',
                      border: _pricingFieldBorder,
                      helperText: 'Entero del 0 al 6.',
                    ),
                    _creationPrecisionError,
                  ),
                  hint: const Text('Selecciona 0–6'),
                  items: List<DropdownMenuItem<int>>.generate(
                    7,
                    (int index) => DropdownMenuItem<int>(
                      value: index,
                      child: Text('$index'),
                    ),
                  ),
                  onChanged: locked
                      ? null
                      : (int? value) => setState(() {
                          _creationPrecision = value;
                          _creationPrecisionError = null;
                        }),
                ),
              ),
              if (_creationError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Error al crear el producto',
                  liveRegion: true,
                  child: ExcludeSemantics(child: Text(error)),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: _creationPending ? null : _submitCreation,
                    child: _creationPending
                        ? Semantics(
                            label: 'Creando producto',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _creationUncertain
                                ? 'Reintentar misma solicitud'
                                : 'Crear',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _creationPending ? null : _closeCreation,
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPricing(CatalogProduct product) {
    _presentationRevision += 1;
    final ProductPricingDraft? unresolved = _unresolvedPricingDraftFor(
      product.internalCode,
    );
    final CatalogPricing? pricing = product.pricing;
    setState(() {
      _pricingProduct = product;
      _cancelSuccessNotice('pricing');
      _pricingSuccess = null;
      _pricingError = null;
      _listedPriceError = null;
      _priceModeError = null;
      _ivaTreatmentError = null;
      _ivaRateError = null;
      _pricingUncertain = unresolved != null;
      _lockedPricingDraft = unresolved;
      if (unresolved != null) {
        _lockPricingDraft(unresolved);
      } else if (pricing != null) {
        _listedPrice.text = formatCentavos(pricing.listedPriceCentavos);
        _priceMode = pricing.priceMode;
        _ivaTreatment = pricing.ivaTreatment;
        _ivaRate.text = pricing.ivaRateBasisPoints == null
            ? ''
            : _formatBasisPoints(pricing.ivaRateBasisPoints!);
      } else {
        _listedPrice.clear();
        _priceMode = null;
        _ivaTreatment = null;
        _ivaRate.clear();
      }
    });
  }

  void _closePricing() {
    if (_pricingPending) return;
    _presentationRevision += 1;
    setState(() {
      _pricingProduct = null;
      _listedPriceError = null;
      _priceModeError = null;
      _ivaTreatmentError = null;
      _ivaRateError = null;
    });
  }

  void _changeIvaTreatment(String? value) {
    setState(() {
      _ivaTreatment = value;
      _ivaTreatmentError = null;
      _ivaRateError = null;
      if (value == 'zero-rated') {
        _ivaRate.text = '0';
      } else if (value == 'exempt') {
        _ivaRate.clear();
      } else {
        _ivaRate.clear();
      }
    });
  }

  Future<void> _submitPricing() async {
    final CatalogProduct? product = _pricingProduct;
    final ProductPricingSubmit? submit = widget.setProductPrice;
    if (product == null || submit == null || _pricingPending) return;
    if (!_pricingUncertain) {
      final bool missingPrice = _listedPrice.text.trim().isEmpty;
      final bool missingMode = _priceMode == null;
      final bool missingTreatment = _ivaTreatment == null;
      final bool missingRate =
          _ivaTreatment == 'taxable' && _ivaRate.text.trim().isEmpty;
      if (missingPrice || missingMode || missingTreatment || missingRate) {
        setState(() {
          _pricingError = null;
          _listedPriceError = missingPrice ? 'Listed price is required.' : null;
          _priceModeError = missingMode ? 'Price mode is required.' : null;
          _ivaTreatmentError = missingTreatment
              ? 'IVA treatment is required.'
              : null;
          _ivaRateError = missingRate
              ? 'IVA rate is required for taxable products.'
              : null;
        });
        return;
      }
    }
    ProductPricingDraft draft;
    try {
      final ProductPricingDraft? authoritative = _unresolvedPricingDraftFor(
        product.internalCode,
      );
      if (authoritative != null) _lockPricingDraft(authoritative);
      draft =
          authoritative ??
          (_pricingUncertain
              ? _lockedPricingDraft!
              : ProductPricingDraft(
                  idempotencyKey:
                      (widget.createPricingId ?? createProductPricingUuidV4)(),
                  productId: product.internalCode,
                  listedPriceMxn: _listedPrice.text,
                  priceMode: _priceMode ?? '',
                  ivaTreatment: _ivaTreatment ?? '',
                  ivaRatePercent: switch (_ivaTreatment) {
                    'zero-rated' => '0',
                    'exempt' => null,
                    _ => _ivaRate.text,
                  },
                ));
      draft.validate();
    } on ProductPricingValidationException catch (error) {
      setState(() => _pricingError = error.message);
      return;
    }

    final int generation = ++_pricingGeneration;
    _lockedPricingDraft ??= draft;
    setState(() {
      _pricingPending = true;
      _pricingError = null;
    });
    try {
      final ProductPricingResult result = await submit(draft);
      if (!mounted || generation != _pricingGeneration) return;
      setState(() {
        _pricingPending = false;
        _pricingUncertain = false;
        _lockedPricingDraft = null;
        _pricingProduct = null;
        _pricingSuccess = result;
        _expireSuccessNotice('pricing', () => _pricingSuccess = null);
      });
      await _requestCatalog();
    } on ProductPricingValidationException catch (error) {
      if (!mounted || generation != _pricingGeneration) return;
      setState(() {
        _pricingPending = false;
        _pricingUncertain = false;
        _lockedPricingDraft = null;
        _pricingError = error.message;
      });
    } on ProductPricingRejectedException catch (error) {
      if (!mounted || generation != _pricingGeneration) return;
      setState(() {
        _pricingPending = false;
        _pricingUncertain = false;
        _lockedPricingDraft = null;
        _pricingError = 'Product pricing was rejected (${error.code}).';
      });
    } on ProductPricingUnresolvedException {
      if (!mounted || generation != _pricingGeneration) return;
      final ProductPricingDraft? authoritative = _unresolvedPricingDraftFor(
        product.internalCode,
      );
      setState(() {
        _pricingPending = false;
        if (authoritative != null) {
          _lockPricingDraft(authoritative);
        } else {
          _pricingProduct = null;
          _lockedPricingDraft = null;
          _pricingUncertain = false;
          _pricingError = null;
          _snapshot = null;
          _failed = true;
        }
      });
    } on ProductPricingStaleException {
      // A newer attempt or session owns presentation authority.
    } catch (_) {
      if (!mounted || generation != _pricingGeneration) return;
      final ProductPricingDraft? authoritative = _unresolvedPricingDraftFor(
        product.internalCode,
      );
      setState(() {
        _pricingPending = false;
        if (authoritative != null) {
          _lockPricingDraft(authoritative);
        } else {
          _pricingUncertain = true;
          _lockedPricingDraft = draft;
          _pricingError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
        }
      });
    }
  }

  Widget _pricingForm() {
    final CatalogProduct product = _pricingProduct!;
    final bool locked = _pricingPending || _pricingUncertain;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Edit price / IVA',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 12),
              Text(product.name),
              SelectableText(product.internalCode),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                liveRegion: _listedPriceError != null,
                label: _listedPriceError == null
                    ? null
                    : 'Listed price error: $_listedPriceError',
                child: TextFormField(
                  key: const ValueKey<String>('pricing-listed-price'),
                  controller: _listedPrice,
                  enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    if (_listedPriceError == null) return;
                    setState(() => _listedPriceError = null);
                  },
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Listed price (MXN)',
                      helperText: 'Exact MXN amount with at most two decimals.',
                      border: _pricingFieldBorder,
                    ),
                    _listedPriceError,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                container: true,
                liveRegion: _priceModeError != null,
                label: _priceModeError == null
                    ? null
                    : 'Price mode error: $_priceModeError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('pricing-mode'),
                  isExpanded: true,
                  initialValue: _priceMode,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Price mode',
                      border: _pricingFieldBorder,
                    ),
                    _priceModeError,
                  ),
                  hint: const Text('Select price mode'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(
                      value: 'iva-included',
                      child: Text('IVA included'),
                    ),
                    DropdownMenuItem(
                      value: 'iva-additional-on-invoice',
                      child: Text('IVA additional on invoice'),
                    ),
                  ],
                  onChanged: locked
                      ? null
                      : (String? value) => setState(() {
                          _priceMode = value;
                          _priceModeError = null;
                        }),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                container: true,
                liveRegion: _ivaTreatmentError != null,
                label: _ivaTreatmentError == null
                    ? null
                    : 'IVA treatment error: $_ivaTreatmentError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('pricing-treatment'),
                  isExpanded: true,
                  initialValue: _ivaTreatment,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'IVA treatment',
                      border: _pricingFieldBorder,
                    ),
                    _ivaTreatmentError,
                  ),
                  hint: const Text('Select IVA treatment'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'taxable', child: Text('Taxable')),
                    DropdownMenuItem(
                      value: 'zero-rated',
                      child: Text('Zero-rated'),
                    ),
                    DropdownMenuItem(value: 'exempt', child: Text('Exempt')),
                  ],
                  onChanged: locked ? null : _changeIvaTreatment,
                ),
              ),
              const SizedBox(height: 12),
              if (_ivaTreatment == 'exempt')
                const Text('IVA rate: Not required')
              else
                Semantics(
                  container: true,
                  liveRegion: _ivaRateError != null,
                  label: _ivaRateError == null
                      ? null
                      : 'IVA rate error: $_ivaRateError',
                  child: TextFormField(
                    key: const ValueKey<String>('pricing-iva-rate'),
                    controller: _ivaRate,
                    enabled: !locked && _ivaTreatment != 'zero-rated',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) {
                      if (_ivaRateError == null) return;
                      setState(() => _ivaRateError = null);
                    },
                    decoration: _requiredErrorDecoration(
                      context,
                      const InputDecoration(
                        labelText: 'IVA rate (%)',
                        helperText:
                            'Taxable rate must be greater than 0 through 100.',
                        border: _pricingFieldBorder,
                      ),
                      _ivaRateError,
                    ),
                  ),
                ),
              if (_pricingError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Product pricing error',
                  liveRegion: true,
                  child: ExcludeSemantics(child: Text(error)),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: _pricingPending ? null : _submitPricing,
                    child: _pricingPending
                        ? Semantics(
                            label: 'Saving product pricing',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _pricingUncertain
                                ? 'Reintentar misma solicitud'
                                : 'Save price / IVA',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _pricingPending ? null : _closePricing,
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showIntake(CatalogProduct product) {
    _presentationRevision += 1;
    // Explicitly scan every existing administrator branch choice for an
    // unresolved draft. A draft found for any branch — including one different
    // from the first choice — is restored by selecting its exact branch and
    // locking, never discarded or replaced.
    final List<CatalogBranchChoice> choices =
        _snapshot?.branchChoices ?? const <CatalogBranchChoice>[];
    StockIntakeDraft? unresolved;
    String? unresolvedBranchId;
    for (final CatalogBranchChoice choice in choices) {
      final StockIntakeDraft? draft = _unresolvedIntakeDraftFor(
        product.internalCode,
        choice.branchId,
      );
      if (draft == null) continue;
      unresolved = draft;
      unresolvedBranchId = choice.branchId;
      break;
    }
    setState(() {
      _intakeProduct = product;
      _cancelSuccessNotice('intake');
      _intakeSuccess = null;
      _intakeError = null;
      _intakeBranchError = null;
      _intakeQuantityError = null;
      _intakeCostError = null;
      _intakePending = false;
      _intakeQuantity.clear();
      _intakeCost.clear();
      _lockedIntakeDraft = null;
      if (unresolved != null) {
        _intakeBranch = unresolvedBranchId;
        _lockIntakeDraft(unresolved);
      } else {
        _intakeBranch = null;
        _intakeUncertain = false;
      }
    });
  }

  void _closeIntake() {
    if (_intakePending) return;
    _presentationRevision += 1;
    setState(() {
      _intakeProduct = null;
      _intakeBranchError = null;
      _intakeQuantityError = null;
      _intakeCostError = null;
    });
  }

  void _changeIntakeBranch(String? branchId) {
    final CatalogProduct? product = _intakeProduct;
    if (product == null) return;
    final StockIntakeDraft? unresolved = branchId == null
        ? null
        : _unresolvedIntakeDraftFor(product.internalCode, branchId);
    setState(() {
      _intakeBranchError = null;
      if (unresolved != null) {
        // An unresolved request for the newly selected branch is restored
        // explicitly: the branch switches to the draft's branch and the form
        // locks for a same-request retry. The stored draft is never replaced.
        _lockIntakeDraft(unresolved);
      } else {
        _intakeBranch = branchId;
      }
    });
  }

  /// Exact truncated line-total preview from the draft's exact BigInt
  /// arithmetic. Never allocates an idempotency key: a fixed preview
  /// identifier is used and any validation failure simply hides the preview.
  String? _intakeTotalPreview() {
    final CatalogProduct? product = _intakeProduct;
    final String? branchId = _intakeBranch;
    if (product == null || branchId == null) return null;
    final String quantity = _intakeQuantity.text;
    final String cost = _intakeCost.text;
    if (quantity.trim().isEmpty || cost.trim().isEmpty) return null;
    try {
      final StockIntakeDraft preview = StockIntakeDraft(
        idempotencyKey: 'intake-total-preview',
        branchId: branchId,
        productId: product.internalCode,
        quantity: quantity,
        unitCostMxn: cost,
        quantitySpec: StockIntakeQuantitySpec(
          unit: product.quantitySpec.unit,
          precision: product.quantitySpec.precision,
        ),
      );
      return '${formatCentavos(preview.lineTotalCentavos)} MXN';
    } on StockIntakeValidationException {
      return null;
    }
  }

  Future<void> _submitIntake() async {
    final CatalogProduct? product = _intakeProduct;
    final StockIntakeSubmit? submit = widget.submitStockIntake;
    if (product == null || submit == null || _intakePending) return;
    if (!_intakeUncertain) {
      // One pass reports every applicable missing required field before any
      // UUID allocation or gateway call.
      final bool missingBranch = _intakeBranch == null;
      final bool missingQuantity = _intakeQuantity.text.trim().isEmpty;
      final bool missingCost = _intakeCost.text.trim().isEmpty;
      if (missingBranch || missingQuantity || missingCost) {
        setState(() {
          _intakeError = null;
          _intakeBranchError = missingBranch ? 'Branch is required.' : null;
          _intakeQuantityError = missingQuantity
              ? 'Quantity is required.'
              : null;
          _intakeCostError = missingCost ? 'Unit cost is required.' : null;
        });
        return;
      }
    }
    StockIntakeDraft draft;
    try {
      final StockIntakeDraft? authoritative = _intakeBranch == null
          ? null
          : _unresolvedIntakeDraftFor(product.internalCode, _intakeBranch!);
      if (authoritative != null) _lockIntakeDraft(authoritative);
      draft =
          authoritative ??
          (_intakeUncertain
              ? _lockedIntakeDraft!
              : StockIntakeDraft(
                  idempotencyKey:
                      (widget.createIntakeId ?? createStockIntakeUuidV4)(),
                  branchId: _intakeBranch!,
                  productId: product.internalCode,
                  quantity: _intakeQuantity.text,
                  unitCostMxn: _intakeCost.text,
                  quantitySpec: StockIntakeQuantitySpec(
                    unit: product.quantitySpec.unit,
                    precision: product.quantitySpec.precision,
                  ),
                ));
      draft.validate();
    } on StockIntakeValidationException catch (error) {
      setState(() => _intakeError = error.message);
      return;
    }

    final int generation = ++_intakeGeneration;
    _lockedIntakeDraft ??= draft;
    setState(() {
      _intakePending = true;
      _intakeError = null;
    });
    try {
      final StockIntakeResult result = await submit(draft);
      if (!mounted || generation != _intakeGeneration) return;
      setState(() {
        _intakePending = false;
        _intakeUncertain = false;
        _lockedIntakeDraft = null;
        _intakeProduct = null;
        _intakeSuccess = result;
        _expireSuccessNotice('intake', () => _intakeSuccess = null);
      });
      await _requestCatalog();
    } on StockIntakeRejectedException catch (error) {
      if (!mounted || generation != _intakeGeneration) return;
      setState(() {
        _intakePending = false;
        _intakeUncertain = false;
        _lockedIntakeDraft = null;
        _intakeError = 'Stock intake was rejected (${error.code}).';
      });
    } on StockIntakeUnresolvedException {
      if (!mounted || generation != _intakeGeneration) return;
      final StockIntakeDraft? authoritative = _intakeBranch == null
          ? null
          : _unresolvedIntakeDraftFor(product.internalCode, _intakeBranch!);
      setState(() {
        _intakePending = false;
        if (authoritative != null) {
          _lockIntakeDraft(authoritative);
        } else {
          _intakeProduct = null;
          _lockedIntakeDraft = null;
          _intakeUncertain = false;
          _intakeError = null;
          _snapshot = null;
          _failed = true;
        }
      });
    } on StockIntakeStaleException {
      // A newer attempt or session owns presentation authority.
    } catch (_) {
      if (!mounted || generation != _intakeGeneration) return;
      final StockIntakeDraft? authoritative = _intakeBranch == null
          ? null
          : _unresolvedIntakeDraftFor(product.internalCode, _intakeBranch!);
      setState(() {
        _intakePending = false;
        if (authoritative != null) {
          _lockIntakeDraft(authoritative);
        } else {
          _intakeUncertain = true;
          _lockedIntakeDraft = draft;
          _intakeError = 'El resultado es incierto. Reintenta la misma solicitud antes de editar.';
        }
      });
    }
  }

  Widget _intakeForm() {
    final CatalogProduct product = _intakeProduct!;
    final bool locked = _intakePending || _intakeUncertain;
    final List<CatalogBranchChoice> choices =
        _snapshot?.branchChoices ?? const <CatalogBranchChoice>[];
    final String? totalPreview = _intakeTotalPreview();
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Record stock intake',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 12),
              Text(product.name),
              SelectableText(product.internalCode),
              const SizedBox(height: 8),
              Text(
                'Unit: ${product.quantitySpec.unit} '
                '(precision ${product.quantitySpec.precision})',
              ),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                liveRegion: _intakeBranchError != null,
                label: _intakeBranchError == null
                    ? null
                    : 'Branch error: $_intakeBranchError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('intake-branch'),
                  isExpanded: true,
                  initialValue: _intakeBranch,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Branch',
                      border: _pricingFieldBorder,
                    ),
                    _intakeBranchError,
                  ),
                  hint: const Text('Select branch'),
                  items: choices
                      .map(
                        (CatalogBranchChoice choice) =>
                            DropdownMenuItem<String>(
                              value: choice.branchId,
                              child: Text(choice.branchName),
                            ),
                      )
                      .toList(growable: false),
                  onChanged: locked ? null : _changeIntakeBranch,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                container: true,
                liveRegion: _intakeQuantityError != null,
                label: _intakeQuantityError == null
                    ? null
                    : 'Quantity error: $_intakeQuantityError',
                child: TextFormField(
                  key: const ValueKey<String>('intake-quantity'),
                  controller: _intakeQuantity,
                  enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    setState(() => _intakeQuantityError = null);
                  },
                  decoration: _requiredErrorDecoration(
                    context,
                    InputDecoration(
                      labelText: 'Quantity (${product.quantitySpec.unit})',
                      helperText: product.quantitySpec.precision == 0
                          ? 'Whole ${product.quantitySpec.unit} only.'
                          : 'Up to ${product.quantitySpec.precision} decimal '
                                'places.',
                      border: _pricingFieldBorder,
                    ),
                    _intakeQuantityError,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                container: true,
                liveRegion: _intakeCostError != null,
                label: _intakeCostError == null
                    ? null
                    : 'Unit cost error: $_intakeCostError',
                child: TextFormField(
                  key: const ValueKey<String>('intake-unit-cost'),
                  controller: _intakeCost,
                  enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    setState(() => _intakeCostError = null);
                  },
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Unit cost (MXN)',
                      helperText: 'Exact MXN amount with at most two decimals.',
                      border: _pricingFieldBorder,
                    ),
                    _intakeCostError,
                  ),
                ),
              ),
              if (totalPreview case final String total) ...<Widget>[
                const SizedBox(height: 12),
                Text('Line total (truncated): $total'),
              ],
              if (_intakeError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Stock intake error',
                  liveRegion: true,
                  child: ExcludeSemantics(child: Text(error)),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: _intakePending ? null : _submitIntake,
                    child: _intakePending
                        ? Semantics(
                            label: 'Recording stock intake',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _intakeUncertain
                                ? 'Reintentar misma solicitud'
                                : 'Record intake',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _intakePending ? null : _closeIntake,
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _catalogBody() {
    if (_loading) return const _CatalogLoading();
    if (_failed) return _CatalogError(onRetry: _requestCatalog);
    final List<CatalogItem> items = _snapshot?.items ?? const <CatalogItem>[];
    if (items.isEmpty) return const _EmptyCatalog();
    return _CatalogList(
      items: items,
      role: widget.session.role,
      branchChoices: _snapshot!.branchChoices,
      snapshot: _snapshot,
      onConfigurePricing:
          widget.session.role == InventoryRole.administrator &&
              widget.setProductPrice != null
          ? _showPricing
          : null,
      onRecordIntake:
          widget.session.role == InventoryRole.administrator &&
              widget.submitStockIntake != null
          ? _showIntake
          : null,
      saleAction: switch (_sale) {
        final SaleCartController sale =>
          (CatalogProduct product) => product.pricing == null
              ? null
              : SaleAddControl(controller: sale, product: product),
        null => null,
      },
    );
  }
}

typedef _SaleActionBuilder = Widget? Function(CatalogProduct product);

String _sessionIdentity(EmulatorSession session) =>
    '${session.userId}|${session.role.name}|${session.branchId ?? ''}';

void _validateCatalogSnapshot(
  CatalogSnapshot snapshot,
  EmulatorSession session,
) {
  if ((session.role == InventoryRole.seller &&
          (snapshot.costsAvailable || snapshot.costs.isNotEmpty)) ||
      (!snapshot.costsAvailable && snapshot.costs.isNotEmpty)) {
    throw const FormatException('catalog cost scope mismatch');
  }
  final Set<String> productIds = snapshot.items
      .map((CatalogItem item) => item.product.internalCode)
      .toSet();
  for (final MapEntry<String, CatalogProductCost> entry
      in snapshot.costs.entries) {
    final CatalogProductCost cost = entry.value;
    if (entry.key != cost.productId ||
        !productIds.contains(entry.key) ||
        cost.currency != 'MXN' ||
        cost.latestUnitCostCentavos < 0 ||
        cost.latestUnitCostCentavos > maxSafePricingInteger ||
        RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$')
                .stringMatch(cost.sourceEntryId) !=
            cost.sourceEntryId) {
      throw const FormatException('catalog cost metadata is inconsistent');
    }
  }
  final Map<String, String> namesByBranchId = <String, String>{};
  final Map<String, String> branchIdsByName = <String, String>{};
  void correlateBranch(String branchId, String branchName) {
    final String? knownName = namesByBranchId[branchId];
    final String? knownId = branchIdsByName[branchName];
    if ((knownName != null && knownName != branchName) ||
        (knownId != null && knownId != branchId)) {
      throw const FormatException('catalog branch metadata is inconsistent');
    }
    namesByBranchId[branchId] = branchName;
    branchIdsByName[branchName] = branchId;
  }

  if (session.role == InventoryRole.administrator) {
    final Set<String> branchIds = <String>{};
    final Set<String> branchNames = <String>{};
    for (final CatalogBranchChoice choice in snapshot.branchChoices) {
      if (!_validBranchId(choice.branchId) ||
          !branchIds.add(choice.branchId) ||
          !branchNames.add(choice.branchName)) {
        throw const FormatException('catalog branch choice is invalid');
      }
      _validateBranchName(choice.branchName);
      correlateBranch(choice.branchId, choice.branchName);
    }
  }
  final Set<String> productCodes = <String>{};
  for (final CatalogItem item in snapshot.items) {
    if (!productCodes.add(item.product.internalCode)) {
      throw const FormatException('duplicate catalog product');
    }

    if (session.role == InventoryRole.seller) {
      final String? branchId = session.branchId;
      if (branchId == null ||
          !_validBranchId(branchId) ||
          item.holdings.length != 1 ||
          item.holdings.single.branchId != branchId) {
        throw const FormatException('seller catalog scope mismatch');
      }
      _validateHolding(item.holdings.single, requireBranchName: false);
      continue;
    }

    final Set<String> branchIds = <String>{};
    for (final CatalogHolding holding in item.holdings) {
      _validateHolding(holding, requireBranchName: true);
      correlateBranch(holding.branchId, holding.branchName!);
      if (!branchIds.add(holding.branchId)) {
        throw const FormatException('duplicate branch holding');
      }
    }
  }
}

void _validateHolding(
  CatalogHolding holding, {
  required bool requireBranchName,
}) {
  if (!_validBranchId(holding.branchId) ||
      holding.quantityScaled < 0 ||
      holding.quantityScaled > maxSafeScaledQuantity) {
    throw const FormatException('catalog holding is invalid');
  }
  if (requireBranchName) {
    _validateBranchName(holding.branchName);
  }
}

void _validateBranchName(String? name) {
  if (name == null ||
      name.isEmpty ||
      name.length > 120 ||
      name.trim() != name ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
    throw const FormatException('catalog branch name is invalid');
  }
}

/// Width of the required-error border, stronger than the 1.0 normal border.
const double _errorBorderWidth = 2.0;

/// Spanish display name of a session role; the wire value stays unchanged.
String _roleLabel(InventoryRole role) => switch (role) {
  InventoryRole.administrator => 'Administrador',
  InventoryRole.seller => 'Vendedor',
};

/// Below this window width (in unscaled text units) the shell AppBar moves
/// its text actions into an overflow menu.
const double _compactShellWidth = 600;

/// Stable outlined shape shared by the pricing form fields in normal and error
/// states, so an error never switches the field's border shape.
const OutlineInputBorder _pricingFieldBorder = OutlineInputBorder();

/// Resolves the stable outlined shape for [decoration]: the field's own border
/// first, then the theme's input decoration border, then the default outline.
OutlineInputBorder _resolvedOutlineBorder(
  InputDecoration decoration,
  BuildContext context,
) {
  final InputBorder? decorationBorder = decoration.border;
  if (decorationBorder is OutlineInputBorder) {
    return OutlineInputBorder(
      borderRadius: decorationBorder.borderRadius,
      gapPadding: decorationBorder.gapPadding,
    );
  }
  final InputBorder? themeBorder = Theme.of(context)
      .inputDecorationTheme
      .border;
  if (themeBorder is OutlineInputBorder) {
    return OutlineInputBorder(
      borderRadius: themeBorder.borderRadius,
      gapPadding: themeBorder.gapPadding,
    );
  }
  return const OutlineInputBorder();
}

/// Returns [decoration] with a strong required-error presentation: the field
/// message plus a decorative themed error icon and explicit error/focused-error
/// borders in the theme error color, keeping the field's own outlined shape.
/// Decorative-only: the icon is excluded from semantics so the existing live
/// error label remains the announcement.
InputDecoration _requiredErrorDecoration(
  BuildContext context,
  InputDecoration decoration,
  String? errorText,
) {
  if (errorText == null) return decoration;
  final ThemeData theme = Theme.of(context);
  final OutlineInputBorder outline = _resolvedOutlineBorder(
    decoration,
    context,
  );
  final BorderSide errorSide = BorderSide(
    color: theme.colorScheme.error,
    width: _errorBorderWidth,
  );
  return decoration.copyWith(
    errorText: errorText,
    suffixIcon: ExcludeSemantics(
      child: Icon(Icons.error_outline, color: theme.colorScheme.error),
    ),
    errorBorder: outline.copyWith(borderSide: errorSide),
    focusedErrorBorder: outline.copyWith(borderSide: errorSide),
  );
}

String _formatBasisPoints(int basisPoints) {
  final int whole = basisPoints ~/ 100;
  final int fraction = basisPoints % 100;
  if (fraction == 0) return whole.toString();
  if (fraction % 10 == 0) return '$whole.${fraction ~/ 10}';
  return '$whole.${fraction.toString().padLeft(2, '0')}';
}

String _priceModeLabel(String value) => switch (value) {
  'iva-included' => 'IVA included',
  'iva-additional-on-invoice' => 'IVA additional on invoice',
  _ => throw StateError('validated price mode became invalid'),
};

String _ivaTreatmentLabel(String value) => switch (value) {
  'taxable' => 'Taxable',
  'zero-rated' => 'Zero-rated',
  'exempt' => 'Exempt',
  _ => throw StateError('validated IVA treatment became invalid'),
};

bool _validBranchId(String value) =>
    RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);

/// Client-side mirror of `ProductCreationDraft.validate()` used to mark each
/// creation field independently before a submit. The server remains the
/// authority: empty values read as required, non-empty invalid values reuse
/// the canonical client messages verbatim.
String? _creationNameFieldError(String name) {
  if (name.isEmpty) return 'El nombre del producto es obligatorio.';
  if (name.length > maxProductNameLength ||
      name.trim() != name ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
    return 'El nombre debe tener de 1 a 120 caracteres, sin espacios al inicio '
        'o al final ni caracteres de control.';
  }
  return null;
}

String? _creationUnitFieldError(String unit) {
  if (unit.isEmpty) return 'La unidad es obligatoria.';
  if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(unit)) {
    return 'La unidad debe empezar con una letra minúscula y usar solo minúsculas, '
        'números, guiones bajos o guiones (de 1 a 32 caracteres).';
  }
  return null;
}

String? _creationPrecisionFieldError(int? precision) {
  if (precision == null) return 'La precisión es obligatoria.';
  if (precision < 0 || precision > 6) {
    return 'La precisión debe ser un entero del 0 al 6.';
  }
  return null;
}

class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.session});

  final EmulatorSession session;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle style = TextStyle(
      color: colors.onSecondaryContainer,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Sesión local autenticada del catálogo',
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: <Widget>[
              Text('Autenticado localmente', style: style),
              Text(session.email, style: style),
              Text('Rol: ${_roleLabel(session.role)}', style: style),
              if (session.branchId case final String branchId)
                Text('Sucursal: $branchId', style: style),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreationToolbar extends StatelessWidget {
  const _CreationToolbar({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: const Text('Crear producto'),
      ),
    ),
  );
}

/// The transfer entry lives in a labelled body toolbar at every width, so the
/// legacy AppBar action row gains no width from it. The Spanish label, icon,
/// key, and tooltip semantics stay the same. The form disables it while it
/// owns the body, and it stays reachable while Movimientos or Correcciones is
/// open because pressing it hands the body to the transfer form.
class _TransferToolbar extends StatelessWidget {
  const _TransferToolbar({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Tooltip(
        message: 'Traslados',
        child: TextButton.icon(
          key: const ValueKey<String>('transfer-open'),
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Traslados'),
        ),
      ),
    ),
  );
}

class _PricingSuccess extends StatelessWidget {
  const _PricingSuccess({required this.result});

  final ProductPricingResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Product pricing succeeded',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(child: Text('Pricing saved. Audit ${result.auditId}')),
          ],
        ),
      ),
    ),
  );
}

class _CreationSuccess extends StatelessWidget {
  const _CreationSuccess({required this.result});

  final ProductCreationResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Producto creado correctamente',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(child: Text('Producto creado ${result.internalCode}')),
          ],
        ),
      ),
    ),
  );
}

class _IntakeSuccess extends StatelessWidget {
  const _IntakeSuccess({required this.result});

  final StockIntakeResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Stock intake succeeded',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(child: Text('Intake recorded. Entry ${result.entryId}')),
          ],
        ),
      ),
    ),
  );
}

class _CatalogLoading extends StatelessWidget {
  const _CatalogLoading();

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: 'Cargando catálogo',
      liveRegion: true,
      child: const CircularProgressIndicator(),
    ),
  );
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.science_outlined, color: colors.onSecondaryContainer),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: colors.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogList extends StatelessWidget {
  const _CatalogList({
    required this.items,
    this.branchChoices = const <CatalogBranchChoice>[],
    this.snapshot,
    this.role,
    this.onConfigurePricing,
    this.onRecordIntake,
    this.saleAction,
  });

  final List<CatalogItem> items;
  final CatalogSnapshot? snapshot;
  final List<CatalogBranchChoice> branchChoices;
  final InventoryRole? role;
  final void Function(CatalogProduct product)? onConfigurePricing;
  final void Function(CatalogProduct product)? onRecordIntake;
  final _SaleActionBuilder? saleAction;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Semantics(
                  header: true,
                  child: Text(
                    'Catálogo',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.separated(
            itemCount: items.length,
            itemBuilder: (BuildContext context, int index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: _ProductCard(
                  item: items[index],
                  costLabel: role == InventoryRole.administrator
                      ? _latestCostLabel(
                          snapshot,
                          items[index].product.internalCode,
                        )
                      : null,
                  role: role,
                  branchChoices: branchChoices,
                  onConfigurePricing: onConfigurePricing,
                  onRecordIntake: onRecordIntake,
                  saleAction: saleAction,
                ),
              ),
            ),
            separatorBuilder: (_, _) => const SizedBox(height: 12),
          ),
        ),
      ],
    );
  }
}

String _latestCostLabel(CatalogSnapshot? snapshot, String productId) {
  if (snapshot == null || !snapshot.costsAvailable) return 'Cost unavailable';
  final CatalogProductCost? cost = snapshot.costs[productId];
  if (cost == null) return 'No cost recorded';
  return 'Latest unit cost: '
      '${formatCentavos(cost.latestUnitCostCentavos)} MXN';
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.costLabel,
    required this.item,
    required this.role,
    required this.branchChoices,
    required this.onConfigurePricing,
    required this.onRecordIntake,
    this.saleAction,
  });

  final CatalogItem item;
  final InventoryRole? role;
  final List<CatalogBranchChoice> branchChoices;
  final void Function(CatalogProduct product)? onConfigurePricing;
  final void Function(CatalogProduct product)? onRecordIntake;
  final _SaleActionBuilder? saleAction;

  final String? costLabel;

  @override
  Widget build(BuildContext context) {
    final Widget details = _ProductDetails(
      costLabel: costLabel,
      item: item,
      role: role,
      branchChoices: branchChoices,
      onConfigurePricing: onConfigurePricing,
      onRecordIntake: onRecordIntake,
      saleAction: saleAction,
    );
    final Widget qr = ProductQrView(product: item.product);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  details,
                  const SizedBox(height: 16),
                  Align(child: qr),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: details),
                const SizedBox(width: 20),
                qr,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProductDetails extends StatelessWidget {
  const _ProductDetails({
    required this.costLabel,
    required this.item,
    required this.role,
    required this.branchChoices,
    required this.onConfigurePricing,
    required this.onRecordIntake,
    this.saleAction,
  });

  final CatalogItem item;
  final InventoryRole? role;
  final List<CatalogBranchChoice> branchChoices;
  final void Function(CatalogProduct product)? onConfigurePricing;
  final void Function(CatalogProduct product)? onRecordIntake;
  final _SaleActionBuilder? saleAction;

  final String? costLabel;

  CatalogProduct get product => item.product;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            product.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          product.internalCode,
          semanticsLabel: 'Internal code ${product.internalCode}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Unit: ${product.quantitySpec.unit} '
          '(precision ${product.quantitySpec.precision})',
        ),
        if (product.pricing case final CatalogPricing pricing) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            'Listed price: ${formatCentavos(pricing.listedPriceCentavos)} '
            '${pricing.currency}',
          ),
          const SizedBox(height: 4),
          Text('Price mode: ${_priceModeLabel(pricing.priceMode)}'),
          const SizedBox(height: 4),
          Text('IVA treatment: ${_ivaTreatmentLabel(pricing.ivaTreatment)}'),
          const SizedBox(height: 4),
          Text(
            'IVA rate: ${pricing.ivaRateBasisPoints == null ? 'Not required' : '${_formatBasisPoints(pricing.ivaRateBasisPoints!)}%'}',
          ),
        ],
        if (role == InventoryRole.administrator &&
            costLabel != null) ...<Widget>[
          const SizedBox(height: 4),
          Semantics(
            container: true,
            label: costLabel,
            excludeSemantics: true,
            child: Text(costLabel!),
          ),
        ],
        if (role != null) ...<Widget>[
          const SizedBox(height: 12),
          ..._holdingRows(),
        ],
        if (onConfigurePricing != null) ...<Widget>[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: ValueKey<String>('configure-price-${product.internalCode}'),
            onPressed: () => onConfigurePricing!(product),
            icon: const Icon(Icons.price_change_outlined),
            label: const Text('Edit price / IVA'),
          ),
        ],
        if (onRecordIntake != null) ...<Widget>[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: ValueKey<String>('intake-${product.internalCode}'),
            onPressed: () => onRecordIntake!(product),
            icon: const Icon(Icons.inventory_outlined),
            label: const Text('Record stock intake'),
          ),
        ],
        if (saleAction?.call(product) case final Widget action) ...<Widget>[
          const SizedBox(height: 12),
          action,
        ],
      ],
    );
  }

  List<Widget> _holdingRows() {
    if (role == InventoryRole.administrator && branchChoices.isNotEmpty) {
      final Map<String, CatalogHolding> holdings = <String, CatalogHolding>{
        for (final CatalogHolding holding in item.holdings)
          holding.branchId: holding,
      };
      final Map<String, CatalogBranchChoice> choices =
          <String, CatalogBranchChoice>{
            for (final CatalogBranchChoice choice in branchChoices)
              choice.branchId: choice,
          };
      final List<String> branchIds = <String>{
        ...choices.keys,
        ...holdings.keys,
      }.toList()..sort();
      return branchIds
          .map((String branchId) {
            final CatalogHolding? holding = holdings[branchId];
            if (holding != null) return _holdingRow(holding);
            return Text(
              '${choices[branchId]!.branchName}: Agotado · Sin entrada registrada',
            );
          })
          .toList(growable: false);
    }
    if (role == InventoryRole.administrator && item.holdings.isEmpty) {
      return const <Widget>[Text('No branch holdings')];
    }
    return item.holdings.map(_holdingRow).toList(growable: false);
  }

  Widget _holdingRow(CatalogHolding holding) {
    final String quantity = formatScaledQuantity(
      holding.quantityScaled,
      product.quantitySpec.precision,
    );
    final String unit = product.quantitySpec.unit;
    if (role == InventoryRole.administrator) {
      final String branchName = holding.branchName!;
      final String empty = holding.isOutOfStock ? ' · Agotado' : '';
      return Text('$branchName: $quantity $unit$empty');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Stock: $quantity $unit'),
        if (holding.isOutOfStock)
          Text('Agotado', style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) {
    return const _CatalogMessage(
      icon: Icons.inventory_2_outlined,
      title: 'Aún no hay productos',
      message: 'Los productos aparecerán aquí cuando estén disponibles.',
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CatalogMessage(
      icon: Icons.cloud_off_outlined,
      title: 'Catálogo no disponible',
      message: 'Revisa tu conexión e inténtalo de nuevo.',
      action: FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
    );
  }
}

class _CatalogMessage extends StatelessWidget {
  const _CatalogMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
