import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../app/backend_environment.dart';
import '../app/panel_transition.dart';
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
import 'catalog_scroll_fade.dart';
import 'catalog_search.dart';
import 'product_qr_scan.dart';
import 'product_creation.dart';
import 'product_pricing.dart';
import 'product_peek.dart';
import 'product_qr.dart';
import 'product_rename.dart';
import 'stock_intake.dart';

typedef CatalogSnapshotLoader = Future<CatalogSnapshot> Function(
  EmulatorSession session,
);
typedef ProductPricingDraftLookup = ProductPricingDraft? Function(
  String productId,
);
typedef ProductRenameDraftLookup = ProductRenameDraft? Function(
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
  const CatalogPage({
    required this.repository,
    this.statusLabel,
    this.qrScan,
    super.key,
  });

  final CatalogRepository repository;
  final String? statusLabel;

  /// Opens the product QR camera and returns the code to search for. It is
  /// offered only on Android and iOS; web and desktop keep the typed search.
  final ProductQrScanOpener? qrScan;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late Future<List<CatalogProduct>> _products;

  /// Products of the last successful load, kept so a reload does not unmount
  /// the list and lose the search query typed in it.
  List<CatalogProduct>? _lastProducts;

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

  Widget _catalogList(List<CatalogProduct> products) => _CatalogList(
    qrScan: widget.qrScan,
    items: products
        .map(
          (CatalogProduct product) =>
              CatalogItem(product: product, holdings: const <CatalogHolding>[]),
        )
        .toList(growable: false),
  );

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
                      if (snapshot.data
                          case final List<CatalogProduct> loaded) {
                        _lastProducts = loaded;
                      }
                      if (snapshot.hasError) {
                        return _CatalogError(onRetry: _retry);
                      }
                      if (snapshot.connectionState != ConnectionState.done) {
                        // A reload keeps the list already on screen, so the
                        // search query and its results survive it.
                        return _lastProducts == null
                            ? const _CatalogLoading()
                            : _catalogList(_lastProducts!);
                      }

                      final List<CatalogProduct> products =
                          snapshot.data ?? const <CatalogProduct>[];
                      if (products.isEmpty) return const _EmptyCatalog();
                      return _catalogList(products);
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
    this.environment = BackendEnvironment.localEmulator,
    this.createProduct,
    this.createDraftId,
    this.unresolvedProductDraft,
    this.setProductPrice,
    this.createPricingId,
    this.unresolvedPricingDrafts = const <ProductPricingDraft>[],
    this.unresolvedPricingDraftForProduct,
    this.renameProduct,
    this.unresolvedRenameDraftForProduct,
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
    this.qrScan,
    super.key,
  });

  final EmulatorSession session;

  /// Which backend the session banner names.
  final BackendEnvironment environment;
  final CatalogSnapshotLoader catalogLoader;
  final Future<void> Function() onLogout;
  final ProductCreationSubmit? createProduct;
  final ProductDraftIdFactory? createDraftId;
  final ProductCreationDraft? unresolvedProductDraft;
  final ProductPricingSubmit? setProductPrice;
  final ProductPricingIdFactory? createPricingId;
  final List<ProductPricingDraft> unresolvedPricingDrafts;
  final ProductPricingDraftLookup? unresolvedPricingDraftForProduct;

  /// Administrator-only rename submit seam inside the price panel; null hides
  /// the name section. Name and price stay separate operations with separate
  /// submits, so a partial failure can never mix them.
  final ProductRenameSubmit? renameProduct;

  /// Live lookup of the shell-retained unresolved rename draft for one
  /// product; a draft is offered back only to its owning exact administrator.
  final ProductRenameDraftLookup? unresolvedRenameDraftForProduct;
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

  /// Opens the product QR camera and returns the code to search for. It is
  /// offered only on Android and iOS; web and desktop keep the typed search.
  final ProductQrScanOpener? qrScan;

  @override
  State<AuthenticatedCatalogPage> createState() =>
      _AuthenticatedCatalogPageState();
}

class _AuthenticatedCatalogPageState extends State<AuthenticatedCatalogPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _unit = TextEditingController();
  final TextEditingController _listedPrice = TextEditingController();
  final TextEditingController _ivaRate = TextEditingController();
  final TextEditingController _renameName = TextEditingController();
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
  ProductRenameDraft? _lockedRenameDraft;
  ProductRenameResult? _renameSuccess;
  String? _renameError;
  String? _renameNameError;
  bool _renamePending = false;
  bool _renameUncertain = false;
  int _renameGeneration = 0;
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
  bool _saleReceiptShown = false;
  bool _cartVisible = false;
  bool _correctionsVisible = false;
  bool _movementsVisible = false;
  bool _transferVisible = false;
  bool _transferPending = false;
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
    if (sessionChanged ||
        oldWidget.setProductPrice != widget.setProductPrice ||
        oldWidget.renameProduct != widget.renameProduct) {
      _pricingGeneration += 1;
      _renameGeneration += 1;
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

  void _closeCart() => setState(() => _cartVisible = false);

  /// The open body panels, topmost first, each closed by the same action as
  /// its own "Cerrar". A sale receipt covers the panels below it, so while one
  /// is shown only the panels drawn above it are listed.
  List<VoidCallback> _openPanelClosers() {
    final bool receiptShown = _sale?.lastReceipt != null;
    return <VoidCallback>[
      if (_movements != null && _movementsVisible) _closeMovements,
      if (_corrections != null && _correctionsVisible) _closeCorrections,
      if (_transfer != null && _transferVisible) _closeTransfer,
      if (widget.session.role == InventoryRole.seller &&
          _noticeController != null &&
          _noticesVisible)
        _closeNotices,
      if (!receiptShown) ...<VoidCallback>[
        if (_sale != null && _cartVisible) _closeCart,
        if (_creationVisible) _closeCreation,
        if (_pricingProduct != null) _closePricing,
        if (_intakeProduct != null) _closeIntake,
      ],
    ];
  }

  /// Navigation is disabled exactly when the open panel's own "Cerrar" is:
  /// while a creation, pricing, intake, transfer or sale request is in flight.
  /// Correcciones and transfer notices keep "Cerrar" enabled, and so does this.
  bool get _navigationBlocked =>
      _creationPending ||
      _pricingPending ||
      _intakePending ||
      _transferPending ||
      (_sale?.isSubmitting ?? false);

  /// "Volver": closes the topmost panel and reveals the one below it.
  void _goBack() {
    if (_navigationBlocked) return;
    final List<VoidCallback> closers = _openPanelClosers();
    if (closers.isNotEmpty) closers.first();
  }

  /// "Inicio": closes every open panel and returns to the catalog. Retained
  /// uncertain drafts stay stored and are offered again when reopened.
  void _goHome() {
    if (_navigationBlocked) return;
    for (final VoidCallback close in _openPanelClosers()) {
      close();
    }
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
      submitTransfer: (TransferDraft draft) async {
        setState(() => _transferPending = true);
        try {
          return await submit(draft);
        } finally {
          if (mounted) setState(() => _transferPending = false);
        }
      },
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

  int? _availableSaleStock(String productId) {
    for (final CatalogItem item in _snapshot?.items ?? const <CatalogItem>[]) {
      if (item.product.internalCode != productId) continue;
      for (final CatalogHolding holding in item.holdings) {
        if (holding.branchId == widget.session.branchId) {
          return holding.quantityScaled;
        }
      }
    }
    return null;
  }

  void _configureSale() {
    final SaleCheckout? checkout = widget.saleCheckout;
    _sale = widget.session.role == InventoryRole.seller && checkout != null
        ? SaleCartController(
            checkout: checkout,
            availableScaled: _availableSaleStock,
            onCompleted: _saleCompleted,
            onReceiptPending: _saleReceiptPending,
          )
        : null;
    _saleReceiptShown = _sale?.lastReceipt != null;
    _sale?.addListener(_onSaleChanged);
  }

  /// A receipt shown or cleared changes which panels navigation can close,
  /// and so the width of the leading navigation slot: rebuild the page then.
  void _onSaleChanged() {
    final bool shown = _sale?.lastReceipt != null;
    if (!mounted || shown == _saleReceiptShown) return;
    setState(() => _saleReceiptShown = shown);
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
    _renameName.dispose();
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
      _creationError = _uncertainOutcomeMessage;
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
    _cancelSuccessNotice('rename');
    _renameSuccess = null;
    _lockedRenameDraft = null;
    _renameError = null;
    _renameNameError = null;
    _renamePending = false;
    _renameUncertain = false;
    _renameName.clear();
  }

  void _restorePricingDraft(CatalogSnapshot snapshot) {
    if (widget.session.role != InventoryRole.administrator) return;
    final bool pricingAvailable = widget.setProductPrice != null;
    final bool renameAvailable = widget.renameProduct != null;
    if ((!pricingAvailable && !renameAvailable) ||
        _pricingProduct != null ||
        _pricingSuccess != null ||
        _renameSuccess != null) {
      return;
    }
    for (final CatalogItem item in snapshot.items) {
      final ProductPricingDraft? pricing = pricingAvailable
          ? _unresolvedPricingDraftFor(item.product.internalCode)
          : null;
      final ProductRenameDraft? rename = renameAvailable
          ? _unresolvedRenameDraftFor(item.product.internalCode)
          : null;
      if (pricing == null && rename == null) continue;
      _pricingProduct = item.product;
      if (pricing != null) _lockPricingDraft(pricing);
      if (rename != null) _lockRenameDraft(rename);
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
    _pricingError = _uncertainOutcomeMessage;
  }

  ProductRenameDraft? _unresolvedRenameDraftFor(String productId) =>
      widget.unresolvedRenameDraftForProduct?.call(productId);

  void _lockRenameDraft(ProductRenameDraft draft) {
    _renameNameError = null;
    _lockedRenameDraft = draft;
    _renameName.text = draft.name;
    _renameUncertain = true;
    _renameError = _uncertainOutcomeMessage;
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
    _intakeError = _uncertainOutcomeMessage;
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
      // A refresh may reveal stock changes for an unchanged cart. Keep its
      // quantities and let a fresh server quote decide availability.
      if (_sale?.cart.isEmpty == false) _sale?.retryQuote();
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
    // Mobile means an Android or iOS app build, never a web browser: a narrow
    // web window must keep the desktop app bar even though a phone browser
    // reports an Android/iOS platform (S2).
    final TargetPlatform platform = Theme.of(context).platform;
    final bool mobilePlatform =
        !kIsWeb &&
        (platform == TargetPlatform.android || platform == TargetPlatform.iOS);
    // On mobile the overflow menu always exists so Reload stays reachable at
    // every window width; on web/desktop it appears only when compact.
    final bool menuActions = mobilePlatform || compactBar;
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
        // The title centers on Android and iOS only (S2); desktop and web
        // keep Flutter's platform default at every window width.
        centerTitle: mobilePlatform ? true : null,
        // Navigation lives in the leading slot: it has its own width, so it
        // never crowds the action row or adds height above a form on a
        // narrow phone. "Volver" (left) appears only while a panel is open;
        // "Inicio" sits to its right — on mobile only while a panel is open,
        // because at the main panel the home icon is redundant (S2).
        leadingWidth: _openPanelClosers().isEmpty ? null : 104,
        leading: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[?sale]),
          builder: (BuildContext context, Widget? child) {
            final bool panelOpen = _openPanelClosers().isNotEmpty;
            final bool enabled = panelOpen && !_navigationBlocked;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (panelOpen)
                  IconButton(
                    key: const ValueKey<String>('panel-back'),
                    tooltip: 'Volver',
                    onPressed: enabled ? _goBack : null,
                    icon: const Icon(Icons.arrow_back),
                  ),
                // "Inicio" appears only while a panel is open, on every
                // platform: at the main panel the home icon is redundant
                // (S2, extended to web/desktop by S9).
                if (panelOpen)
                  IconButton(
                    key: const ValueKey<String>('shell-home'),
                    tooltip: 'Inicio',
                    onPressed: enabled ? _goHome : null,
                    icon: const Icon(Icons.home_outlined),
                  ),
              ],
            );
          },
        ),
        title: _ShellTitle(
          session: widget.session,
          environment: widget.environment,
          centered: mobilePlatform,
        ),
        actions: <Widget>[
          if (corrections != null && !compactBar)
            TextButton.icon(
              key: const ValueKey<String>('corrections-open'),
              onPressed: openCorrections,
              icon: const Icon(Icons.assignment_return_outlined),
              label: const Text('Correcciones'),
            ),
          // Transfer notices (S10) live in the overflow menu wherever that
          // menu exists — always on Android/iOS, on web/desktop when the bar
          // is compact — as its first entry. The wide web/desktop bar keeps
          // its own icon.
          if (noticeController != null && !menuActions)
            IconButton(
              key: const ValueKey<String>('notices-open'),
              tooltip: 'Avisos de traslados',
              onPressed: showNotices ? null : _showNotices,
              icon: _noticeBadge(context, unreadNotices),
            ),
          if (movements != null && !compactBar)
            TextButton.icon(
              key: const ValueKey<String>('movements-open'),
              onPressed: openMovements,
              icon: const Icon(Icons.swap_vert),
              label: const Text('Movimientos'),
            ),
          // On mobile the refresh button leaves the bar (S2): Reload lives
          // in the overflow menu below, so the bar spends no space on it.
          // Desktop and web keep the bar button at every window width.
          if (!mobilePlatform)
            IconButton(
              tooltip: 'Actualizar catálogo',
              onPressed: _loading ? null : _requestCatalog,
              icon: const Icon(Icons.refresh),
            ),
          if (menuActions)
            PopupMenuButton<VoidCallback>(
              key: const ValueKey<String>('shell-more'),
              // Three bars on mobile (S2); web/desktop keeps the three dots.
              // The unread-notice badge rides on the menu icon itself, and
              // screen readers hear the unread notices named on the button.
              // Only a session with transfer notices can have an unread
              // badge; administrators have none.
              icon: Semantics(
                label: noticeController == null
                    ? null
                    : unreadNotices == null
                    ? 'sin confirmar'
                    : unreadNotices > 0
                    ? 'Avisos de traslados: $unreadNotices sin leer'
                    : null,
                child: ExcludeSemantics(
                  child: Badge(
                    isLabelVisible:
                        noticeController != null &&
                        (unreadNotices == null || unreadNotices > 0),
                    label: Text(unreadNotices == null ? '!' : '$unreadNotices'),
                    backgroundColor: unreadNotices == null
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : null,
                    child: Icon(mobilePlatform ? Icons.menu : Icons.more_vert),
                  ),
                ),
              ),
              onSelected: (VoidCallback action) => action(),
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<VoidCallback>>[
                    // First entry for the fastest access (S10); the count on
                    // the item is read when the menu opens.
                    if (noticeController != null)
                      PopupMenuItem<VoidCallback>(
                        key: const ValueKey<String>('notices-open'),
                        enabled: !showNotices,
                        value: _showNotices,
                        child: ListTile(
                          leading: _noticeBadge(context, unreadNotices),
                          title: const Text('Avisos de traslados'),
                        ),
                      ),
                    if (mobilePlatform)
                      PopupMenuItem<VoidCallback>(
                        enabled: !_loading,
                        value: _requestCatalog,
                        child: const ListTile(
                          leading: Icon(Icons.refresh),
                          title: Text('Actualizar catálogo'),
                        ),
                      ),
                    if (corrections != null && compactBar)
                      PopupMenuItem<VoidCallback>(
                        key: const ValueKey<String>('corrections-open'),
                        enabled: openCorrections != null,
                        value: openCorrections,
                        child: const ListTile(
                          leading: Icon(Icons.assignment_return_outlined),
                          title: Text('Correcciones'),
                        ),
                      ),
                    if (movements != null && compactBar)
                      PopupMenuItem<VoidCallback>(
                        key: const ValueKey<String>('movements-open'),
                        enabled: openMovements != null,
                        value: openMovements,
                        child: const ListTile(
                          leading: Icon(Icons.swap_vert),
                          title: Text('Movimientos'),
                        ),
                      ),
                    if (compactBar)
                      PopupMenuItem<VoidCallback>(
                        value: widget.onLogout,
                        child: const ListTile(
                          leading: Icon(Icons.logout),
                          title: Text('Cerrar sesión'),
                        ),
                      ),
                  ],
            ),
          // The inline logout keeps its place whenever the bar is wide enough
          // for it — mobile only moved Reload out of the bar (S2c).
          if (!compactBar) ...<Widget>[
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
            if (_creationSuccess case final ProductCreationResult result)
              _CreationSuccess(result: result),
            if (_pricingSuccess case final ProductPricingResult result)
              _PricingSuccess(result: result),
            if (_renameSuccess case final ProductRenameResult result)
              _RenameSuccess(result: result),
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
              child: _bodyPanel(
                showMovements
                    ? _panel(
                        'movements',
                        MovementsView(
                          movements: movements,
                          productNames: _productNames(),
                          branchChoices:
                              _snapshot?.branchChoices ??
                              const <CatalogBranchChoice>[],
                          onClose: _closeMovements,
                        ),
                      )
                    : showCorrections
                    ? _panel(
                        'corrections',
                        CorrectionLookupView(
                          corrections: corrections,
                          productNames: _productNames(),
                          products: _catalogProducts(),
                          onClose: _closeCorrections,
                        ),
                      )
                    : transfer != null && _transferVisible
                    ? _panel('transfer', _transferForm(transfer))
                    : showNotices
                    ? _panel(
                        'notices',
                        TransferNoticesView(
                          state: noticeController.state,
                          productNames: _productNames(),
                          onMarkRead: _markNoticeRead,
                          onClose: _closeNotices,
                          onRetry: noticeController.retry,
                        ),
                      )
                    : receipt != null
                    ? _panel(
                        'receipt',
                        SaleReceiptView(
                          receipt: receipt,
                          notice: sale?.receiptPending ?? false
                              ? salePendingReceiptMessage
                              : null,
                          onNewSale: _startNewSale,
                        ),
                      )
                    : sale != null && _cartVisible
                    ? _panel(
                        'cart',
                        SaleCartPanel(
                          controller: sale,
                          onClose: () => setState(() => _cartVisible = false),
                        ),
                      )
                    : _creationVisible
                    ? _panel('creation', _creationForm())
                    : _pricingProduct != null
                    ? _panel('pricing', _pricingForm())
                    : _intakeProduct != null
                    ? _panel('intake', _intakeForm())
                    : _catalogPanel(),
              ),
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
        _creationError = _uncertainOutcomeMessage;
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
    final ProductRenameDraft? unresolvedRename = _unresolvedRenameDraftFor(
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
      // The name section is a separate operation with its own state: an
      // unresolved rename restores its own locked draft, otherwise the field
      // simply offers the current product name.
      if (unresolvedRename != null) {
        _lockRenameDraft(unresolvedRename);
      } else {
        _cancelSuccessNotice('rename');
        _renameSuccess = null;
        _renameError = null;
        _renameNameError = null;
        _renamePending = false;
        _renameUncertain = false;
        _lockedRenameDraft = null;
        _renameName.text = product.name;
      }
    });
  }

  void _closePricing() {
    if (_pricingPending || _renamePending) return;
    _presentationRevision += 1;
    setState(() {
      _pricingProduct = null;
      _listedPriceError = null;
      _priceModeError = null;
      _ivaTreatmentError = null;
      _ivaRateError = null;
      _renameNameError = null;
      _renameError = null;
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
          _listedPriceError = missingPrice
              ? 'El precio de lista es obligatorio.'
              : null;
          _priceModeError = missingMode
              ? 'El modo de precio es obligatorio.'
              : null;
          _ivaTreatmentError = missingTreatment
              ? 'El tratamiento de IVA es obligatorio.'
              : null;
          _ivaRateError = missingRate
              ? 'La tasa de IVA es obligatoria para productos gravados.'
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
        _pricingError = 'Se rechazó el precio del producto (${error.code}).';
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
          _pricingError = _uncertainOutcomeMessage;
        }
      });
    }
  }

  bool get _renameLocked => _renamePending || _renameUncertain;

  /// Separate rename submit (S7): name and price stay independent operations,
  /// so a partial failure can never mix them. The uncertain pattern mirrors
  /// [_submitPricing]: an unresolved draft keeps its frozen idempotency key
  /// and the retry resends the exact same request.
  Future<void> _submitRename() async {
    final CatalogProduct? product = _pricingProduct;
    final ProductRenameSubmit? submit = widget.renameProduct;
    if (product == null || submit == null || _renamePending) return;
    if (!_renameUncertain) {
      final String? nameError = _creationNameFieldError(_renameName.text);
      if (nameError != null) {
        setState(() {
          _renameError = null;
          _renameNameError = nameError;
        });
        return;
      }
    }
    ProductRenameDraft draft;
    try {
      final ProductRenameDraft? authoritative = _unresolvedRenameDraftFor(
        product.internalCode,
      );
      if (authoritative != null) _lockRenameDraft(authoritative);
      draft =
          authoritative ??
          (_renameUncertain
              ? _lockedRenameDraft!
              : ProductRenameDraft(
                  idempotencyKey: createProductRenameIdempotencyKey(),
                  productId: product.internalCode,
                  name: _renameName.text,
                ));
      draft.validate();
    } on ProductRenameValidationException catch (error) {
      setState(() => _renameError = error.message);
      return;
    }

    final int generation = ++_renameGeneration;
    _lockedRenameDraft ??= draft;
    setState(() {
      _renamePending = true;
      _renameError = null;
    });
    try {
      final ProductRenameResult result = await submit(draft);
      if (!mounted || generation != _renameGeneration) return;
      setState(() {
        _renamePending = false;
        _renameUncertain = false;
        _lockedRenameDraft = null;
        _pricingProduct = null;
        _renameSuccess = result;
        _expireSuccessNotice('rename', () => _renameSuccess = null);
      });
      await _requestCatalog();
    } on ProductRenameValidationException catch (error) {
      if (!mounted || generation != _renameGeneration) return;
      setState(() {
        _renamePending = false;
        _renameUncertain = false;
        _lockedRenameDraft = null;
        _renameError = error.message;
      });
    } on ProductRenameSessionException {
      // Definite: the exact administrator session ended before any write.
      if (!mounted || generation != _renameGeneration) return;
      setState(() {
        _renamePending = false;
        _renameUncertain = false;
        _renameError =
            'Tu sesión ya no permite editar nombres. Vuelve a '
            'iniciar sesión.';
      });
    } on ProductRenameRejectedException catch (error) {
      if (!mounted || generation != _renameGeneration) return;
      setState(() {
        _renamePending = false;
        _renameUncertain = false;
        _lockedRenameDraft = null;
        _renameError = _renameRejectionMessage(error.code);
      });
    } on ProductRenameStaleException {
      // A newer attempt or session owns presentation authority.
    } catch (_) {
      if (!mounted || generation != _renameGeneration) return;
      final ProductRenameDraft? authoritative = _unresolvedRenameDraftFor(
        product.internalCode,
      );
      setState(() {
        _renamePending = false;
        if (authoritative != null) {
          _lockRenameDraft(authoritative);
        } else {
          _renameUncertain = true;
          _lockedRenameDraft = draft;
          _renameError = _uncertainOutcomeMessage;
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
                  'Editar precio / IVA',
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
                    : 'Error en el precio de lista: $_listedPriceError',
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
                      labelText: 'Precio de lista (MXN)',
                      helperText:
                          'Monto exacto en MXN con máximo dos decimales.',
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
                    : 'Error en el modo de precio: $_priceModeError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('pricing-mode'),
                  isExpanded: true,
                  initialValue: _priceMode,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Modo de precio',
                      border: _pricingFieldBorder,
                    ),
                    _priceModeError,
                  ),
                  hint: const Text('Selecciona el modo de precio'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(
                      value: 'iva-included',
                      child: Text('IVA incluido'),
                    ),
                    DropdownMenuItem(
                      value: 'iva-additional-on-invoice',
                      child: Text('IVA adicional en factura'),
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
                    : 'Error en el tratamiento de IVA: $_ivaTreatmentError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('pricing-treatment'),
                  isExpanded: true,
                  initialValue: _ivaTreatment,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Tratamiento de IVA',
                      border: _pricingFieldBorder,
                    ),
                    _ivaTreatmentError,
                  ),
                  hint: const Text('Selecciona el tratamiento de IVA'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'taxable', child: Text('Gravado')),
                    DropdownMenuItem(
                      value: 'zero-rated',
                      child: Text('Tasa 0%'),
                    ),
                    DropdownMenuItem(value: 'exempt', child: Text('Exento')),
                  ],
                  onChanged: locked ? null : _changeIvaTreatment,
                ),
              ),
              const SizedBox(height: 12),
              if (_ivaTreatment == 'exempt')
                const Text('Tasa de IVA: No requerida')
              else
                Semantics(
                  container: true,
                  liveRegion: _ivaRateError != null,
                  label: _ivaRateError == null
                      ? null
                      : 'Error en la tasa de IVA: $_ivaRateError',
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
                        labelText: 'Tasa de IVA (%)',
                        helperText:
                            'La tasa gravada debe ser mayor que 0 y hasta 100.',
                        border: _pricingFieldBorder,
                      ),
                      _ivaRateError,
                    ),
                  ),
                ),
              if (_pricingError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Error en el precio del producto',
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
                            label: 'Guardando precio del producto',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _pricingUncertain
                                ? 'Reintentar misma solicitud'
                                : 'Guardar precio / IVA',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _pricingPending ? null : _closePricing,
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
              if (widget.renameProduct != null) ...<Widget>[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: Text(
                    'Nombre del producto',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  container: true,
                  liveRegion: _renameNameError != null,
                  label: _renameNameError == null
                      ? null
                      : 'Error en el nombre del producto: $_renameNameError',
                  child: TextFormField(
                    key: ValueKey<String>(
                      'rename-name-${product.internalCode}',
                    ),
                    controller: _renameName,
                    enabled: !_renameLocked,
                    maxLength: maxProductRenameNameLength,
                    onChanged: (_) {
                      if (_renameNameError == null) return;
                      setState(() => _renameNameError = null);
                    },
                    decoration: _requiredErrorDecoration(
                      context,
                      const InputDecoration(
                        labelText: 'Nombre del producto',
                        border: _pricingFieldBorder,
                      ),
                      _renameNameError,
                    ),
                  ),
                ),
                if (_renameError case final String error) ...<Widget>[
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'Error en el nombre del producto',
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
                      key: ValueKey<String>(
                        'rename-submit-${product.internalCode}',
                      ),
                      onPressed: _renamePending ? null : _submitRename,
                      child: _renamePending
                          ? Semantics(
                              label: 'Guardando nombre del producto',
                              liveRegion: true,
                              child: const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Text(
                              _renameUncertain
                                  ? 'Reintentar misma solicitud'
                                  : 'Guardar nombre',
                            ),
                    ),
                  ],
                ),
              ],
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
          _intakeBranchError = missingBranch
              ? 'La sucursal es obligatoria.'
              : null;
          _intakeQuantityError = missingQuantity
              ? 'La cantidad es obligatoria.'
              : null;
          _intakeCostError = missingCost
              ? 'El costo unitario es obligatorio.'
              : null;
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
        _intakeError = 'Se rechazó la entrada de inventario (${error.code}).';
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
          _intakeError = _uncertainOutcomeMessage;
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
                  'Registrar entrada de inventario',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 12),
              Text(product.name),
              SelectableText(product.internalCode),
              const SizedBox(height: 8),
              Text(
                'Unidad: ${product.quantitySpec.unit} '
                '(precisión ${product.quantitySpec.precision})',
              ),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                liveRegion: _intakeBranchError != null,
                label: _intakeBranchError == null
                    ? null
                    : 'Error en la sucursal: $_intakeBranchError',
                child: DropdownButtonFormField<String>(
                  key: const ValueKey<String>('intake-branch'),
                  isExpanded: true,
                  initialValue: _intakeBranch,
                  decoration: _requiredErrorDecoration(
                    context,
                    const InputDecoration(
                      labelText: 'Sucursal',
                      border: _pricingFieldBorder,
                    ),
                    _intakeBranchError,
                  ),
                  hint: const Text('Selecciona una sucursal'),
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
                    : 'Error en la cantidad: $_intakeQuantityError',
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
                      labelText: 'Cantidad (${product.quantitySpec.unit})',
                      helperText: product.quantitySpec.precision == 0
                          ? 'Solo cantidades enteras.'
                          : 'Hasta ${product.quantitySpec.precision} decimales.',
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
                    : 'Error en el costo unitario: $_intakeCostError',
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
                      labelText: 'Costo unitario (MXN)',
                      helperText:
                          'Monto exacto en MXN con máximo dos decimales.',
                      border: _pricingFieldBorder,
                    ),
                    _intakeCostError,
                  ),
                ),
              ),
              if (totalPreview case final String total) ...<Widget>[
                const SizedBox(height: 12),
                Text('Total de la línea (truncado): $total'),
              ],
              if (_intakeError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Error en la entrada de inventario',
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
                            label: 'Registrando entrada de inventario',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _intakeUncertain
                                ? 'Reintentar misma solicitud'
                                : 'Registrar entrada',
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

  /// A body panel with the identity its transition is keyed by (T9/S9). The
  /// identity names the panel, not its content, so an in-panel change never
  /// re-animates and never recreates the panel.
  ({String? identity, Widget child}) _panel(String identity, Widget child) =>
      (identity: identity, child: child);

  /// The body: one panel cross-fades into the next (T9/S9). A body that is not
  /// a panel at all carries no identity and is presented without the wrapper,
  /// so the transition always mounts on its first panel still and an initial
  /// load never animates. Panel priority stays exactly where it was: in the
  /// chain that produced this record.
  Widget _bodyPanel(({String? identity, Widget child}) panel) {
    if (panel.identity case final String identity) {
      return PanelTransition(identity: identity, child: panel.child);
    }
    return panel.child;
  }

  /// The catalog list, or the body that stands in for it while there is none.
  /// Those stand-ins are not panels (T9/S9): no identity, so no transition in
  /// either direction.
  ({String? identity, Widget child}) _catalogPanel() {
    if (_loading && _snapshot == null) {
      return (identity: null, child: const _CatalogLoading());
    }
    if (_failed) {
      return (identity: null, child: _CatalogError(onRetry: _requestCatalog));
    }
    final List<CatalogItem> items = _snapshot?.items ?? const <CatalogItem>[];
    if (items.isEmpty) return (identity: null, child: const _EmptyCatalog());
    return (
      identity: 'catalog',
      child: _CatalogList(
        qrScan: widget.qrScan,
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
      ),
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

/// Badge state shared by the wide-shell bar icon and the overflow menu entry
/// (S10): the unread count, or the '!' glyph while the count is unconfirmed.
/// Screen readers hear the state in words, never the bare count or glyph.
Widget _noticeBadge(BuildContext context, int? unreadNotices) => Semantics(
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
);

/// Shown when a create, pricing or intake request may or may not have landed.
const String _uncertainOutcomeMessage =
    'El resultado es incierto. Reintenta la misma solicitud antes de editar.';

/// Safe Spanish message for a proven pre-write rename rejection. The server
/// text never reaches the UI; only its stable code is mapped here.
String _renameRejectionMessage(String code) => switch (code) {
  'invalid-argument' =>
    'El nombre no es válido. Revisa el campo e inténtalo de nuevo.',
  'unauthenticated' => 'Tu sesión ya no es válida. Vuelve a iniciar sesión.',
  'permission-denied' => 'Tu sesión ya no permite cambiar nombres de producto.',
  'not-found' =>
    'El producto ya no existe en el catálogo. Actualiza e inténtalo de nuevo.',
  'already-exists' => 'Esa solicitud de cambio de nombre ya se usó para otro cambio. Inicia uno nuevo.',
  _ => 'Se rechazó el cambio de nombre ($code).',
};

/// Spanish display name of a session role; the wire value stays unchanged.
String _roleDisplayName(InventoryRole role) => switch (role) {
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
  'iva-included' => 'IVA incluido',
  'iva-additional-on-invoice' => 'IVA adicional en factura',
  _ => throw StateError('validated price mode became invalid'),
};

String _ivaTreatmentLabel(String value) => switch (value) {
  'taxable' => 'Gravado',
  'zero-rated' => 'Tasa 0%',
  'exempt' => 'Exento',
  _ => throw StateError('validated IVA treatment became invalid'),
};

bool _validBranchId(String value) =>
    RegExp(r'^branch-[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);

/// Client-side mirror of `ProductCreationDraft.validate()` used to mark each
/// creation field independently before a submit. The server remains the
/// authority: empty values read as required, non-empty invalid values show
/// the same Spanish messages as the client-side draft validators.
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

/// Display name derived from a branch id: `branch-centro-sur` reads as
/// `Sucursal Centro Sur`. Sellers cannot read branch documents, so the id is
/// the only source; ids are chosen to follow the branch name.
String _branchDisplayName(String branchId) {
  final String words = branchId
      .replaceFirst(RegExp(r'^branch-'), '')
      .split('-')
      .where((String word) => word.isNotEmpty)
      .map((String word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
  return 'Sucursal $words';
}

/// App title with a compact session line (role and branch, never the email)
/// in place of a full-width session banner.
class _ShellTitle extends StatelessWidget {
  const _ShellTitle({
    required this.session,
    required this.environment,
    this.centered = false,
  });

  final EmulatorSession session;
  final BackendEnvironment environment;

  /// Whether the title and its session line center under the app bar's
  /// centerTitle layout (Android and iOS only).
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final String status = <String>[
      ?environment.sessionStatusPrefix,
      _roleDisplayName(session.role),
      if (session.branchId case final String branchId)
        _branchDisplayName(branchId),
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      // Centered with the title on mobile (S2); left-aligned on desktop/web.
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: <Widget>[
        const Text('LDA Inventory'),
        Text(
          status,
          key: const ValueKey<String>('session-status'),
          style: Theme.of(context).textTheme.labelMedium,
          overflow: TextOverflow.ellipsis,
        ),
      ],
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
    label: 'Precio del producto guardado',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Precio guardado. Auditoría ${result.auditId}'),
            ),
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
    label: 'Entrada de inventario registrada',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Entrada registrada. Folio ${result.entryId}'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RenameSuccess extends StatelessWidget {
  const _RenameSuccess({required this.result});

  final ProductRenameResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Nombre del producto actualizado',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(child: Text('Nombre actualizado a ${result.newName}')),
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

class _CatalogList extends StatefulWidget {
  const _CatalogList({
    required this.items,
    this.branchChoices = const <CatalogBranchChoice>[],
    this.snapshot,
    this.role,
    this.onConfigurePricing,
    this.onRecordIntake,
    this.saleAction,
    this.qrScan,
  });

  final List<CatalogItem> items;
  final CatalogSnapshot? snapshot;
  final List<CatalogBranchChoice> branchChoices;
  final InventoryRole? role;
  final void Function(CatalogProduct product)? onConfigurePricing;
  final void Function(CatalogProduct product)? onRecordIntake;
  final _SaleActionBuilder? saleAction;

  final ProductQrScanOpener? qrScan;

  @override
  State<_CatalogList> createState() => _CatalogListState();
}

class _CatalogListState extends State<_CatalogList> {
  final TextEditingController _search = TextEditingController();

  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) => setState(() => _query = value);

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  /// Reads one product QR and types its payload into the search field, so the
  /// scanned code goes through the same matcher as a typed one.
  Future<void> _scanSearch() async {
    final ProductQrScanOpener? opener = widget.qrScan;
    if (opener == null) return;
    final String? scanned = await opener(context);
    if (!mounted || scanned == null || scanned.isEmpty) return;
    _search.value = TextEditingValue(
      text: scanned,
      selection: TextSelection.collapsed(offset: scanned.length),
    );
    setState(() => _query = scanned);
  }

  @override
  Widget build(BuildContext context) {
    final List<CatalogItem> visible = filterCatalogItems(widget.items, _query);
    // S10: the product list melts into the page background at the edges that
    // still have products behind it. Paint only — taps, card layout, keys, the
    // scroll extent and the semantics tree stay exactly where the list puts
    // them.
    return CatalogScrollFade(child: _catalogScroll(visible));
  }

  /// The catalog header, the search field and the product grid, sized by the
  /// panel they are given (S4 columns).
  Widget _catalogScroll(List<CatalogItem> visible) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = _columnsFor(context, constraints.maxWidth);
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
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: CatalogSearchField(
                      controller: _search,
                      onChanged: _onSearchChanged,
                      onClear: _clearSearch,
                      onScan: widget.qrScan == null || !productQrScanSupported
                          ? null
                          : _scanSearch,
                    ),
                  ),
                ),
              ),
            ),
            if (visible.isEmpty)
              SliverToBoxAdapter(
                child: _CatalogMessage(
                  icon: Icons.search_off,
                  title: 'Sin resultados',
                  message: 'Ningún producto coincide con "$_query".',
                  action: OutlinedButton(
                    onPressed: _clearSearch,
                    child: const Text('Limpiar búsqueda'),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.separated(
                  // The grid lays out complete rows of Expanded cards so the
                  // row height follows the tallest card instead of a fixed
                  // aspect ratio (S4).
                  itemCount: (visible.length + columns - 1) ~/ columns,
                  itemBuilder: (BuildContext context, int index) {
                    final int first = index * columns;
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          // Incomplete final rows keep their empty slots so
                          // the loaded cards never stretch across the row
                          // (S5). The slots are inert and noninteractive.
                          for (int i = first; i < first + columns; i++)
                            if (i < visible.length)
                              Expanded(
                                child: _ProductCard(
                                  item: visible[i],
                                  costLabel:
                                      widget.role == InventoryRole.administrator
                                      ? _latestCostLabel(
                                          widget.snapshot,
                                          visible[i].product.internalCode,
                                        )
                                      : null,
                                  role: widget.role,
                                  branchChoices: widget.branchChoices,
                                  onConfigurePricing: widget.onConfigurePricing,
                                  onRecordIntake: widget.onRecordIntake,
                                  saleAction: widget.saleAction,
                                ),
                              )
                            else
                              const Expanded(child: SizedBox.shrink()),
                        ],
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Products per row (S4): an Android or iOS app build always shows 2, at any
/// width — the same mobile rule the shell app bar uses. Web and desktop use
/// width breakpoints so cards never get unreadably thin: 3 columns from 900px,
/// 2 from 560px, and a single column below that.
int _columnsFor(BuildContext context, double width) {
  final TargetPlatform platform = Theme.of(context).platform;
  final bool mobile =
      !kIsWeb &&
      (platform == TargetPlatform.android || platform == TargetPlatform.iOS);
  if (mobile) return 2;
  if (width >= 900) return 3;
  if (width >= 560) return 2;
  return 1;
}

String _latestCostLabel(CatalogSnapshot? snapshot, String productId) {
  if (snapshot == null || !snapshot.costsAvailable) {
    return 'Costo no disponible';
  }
  final CatalogProductCost? cost = snapshot.costs[productId];
  if (cost == null) return 'Sin costo registrado';
  return 'Último costo unitario: '
      '${formatCentavos(cost.latestUnitCostCentavos)} MXN';
}

/// Compact product card (S4). Shows only name, stock and price — the code,
/// unit, price mode, IVA treatment and rate, cost, and QR moved to the detail
/// sheet (S5), which opens by long-press and by the visible "Detalles" button
/// on every platform. The seller's sale action stays on the card so selling
/// remains one tap.
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

  CatalogProduct get product => item.product;

  void _openDetails(BuildContext context) {
    showProductPeek(
      context: context,
      builder: (BuildContext context) => _ProductSheet(
        costLabel: costLabel,
        item: item,
        role: role,
        branchChoices: branchChoices,
        onConfigurePricing: onConfigurePricing,
        onRecordIntake: onRecordIntake,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CatalogPricing? pricing = product.pricing;
    final String priceLine = pricing == null
        ? 'Sin precio'
        : 'Precio: ${formatCentavos(pricing.listedPriceCentavos)} '
              '${pricing.currency}';
    return Card(
      key: ValueKey<String>('product-card-${product.internalCode}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: () {
          HapticFeedback.lightImpact();
          _openDetails(context);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(product.name, style: theme.textTheme.titleLarge),
              ),
              if (role != null) ...<Widget>[
                const SizedBox(height: 8),
                // Stock is secondary information (S2): small, muted ink under
                // the name. The shared _holdingLines contribute only text.
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: _holdingLines(
                      item: item,
                      role: role,
                      branchChoices: branchChoices,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              // The price is the card's strongest line (S2): large and bold,
              // with the exact amount and copy unchanged.
              Text(
                priceLine,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  if (saleAction?.call(product) case final Widget action)
                    action,
                  // 'Detalles' is the discreet secondary action (S3); the
                  // sale 'Agregar' FilledButton above keeps the primary role.
                  TextButton.icon(
                    key: ValueKey<String>(
                      'product-details-${product.internalCode}',
                    ),
                    onPressed: () => _openDetails(context),
                    icon: const Icon(Icons.info_outline),
                    label: Text(
                      'Detalles',
                      semanticsLabel: 'Ver detalles de ${product.name}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Detail content for one product (S1, S5), presented in the S12 peek. The
/// sheet hugs its content: short seller details stay compact while tall
/// administrator details (or large text) cap and scroll. The name and price
/// lead the visual hierarchy and the QR sits on its own surface. The seller
/// sees name, price, price mode, stock and the QR; the administrator
/// additionally sees the IVA treatment and rate, unit and precision, the
/// internal code, the latest cost, per-branch stock, and the pricing and
/// intake actions. The unauthenticated diagnostic page (role null) keeps the
/// full detail set it always showed.
class _ProductSheet extends StatelessWidget {
  const _ProductSheet({
    required this.costLabel,
    required this.item,
    required this.role,
    required this.branchChoices,
    required this.onConfigurePricing,
    required this.onRecordIntake,
  });

  final CatalogItem item;
  final InventoryRole? role;
  final List<CatalogBranchChoice> branchChoices;
  final void Function(CatalogProduct product)? onConfigurePricing;
  final void Function(CatalogProduct product)? onRecordIntake;

  final String? costLabel;

  CatalogProduct get product => item.product;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final TextStyle? secondaryStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final bool administrator = role == InventoryRole.administrator;
    final bool fullDetails = administrator || role == null;
    final CatalogPricing? pricing = product.pricing;
    // No Center here: the sheet must size to its content so short seller
    // details do not stretch the peek card (S1). Keyboard avoidance lives in
    // showProductPeek.
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: ConstrainedBox(
        key: ValueKey<String>('product-sheet-${product.internalCode}'),
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Detalles del producto',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('product-sheet-close'),
                    tooltip: 'Cerrar detalles',
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Semantics(
                header: true,
                child: Text(
                  product.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (fullDetails) ...<Widget>[
                const SizedBox(height: 4),
                SelectableText(
                  product.internalCode,
                  semanticsLabel: 'Código interno ${product.internalCode}',
                  style: secondaryStyle,
                ),
              ],
              if (pricing case final CatalogPricing shown) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'Precio de lista: ${formatCentavos(shown.listedPriceCentavos)} '
                  '${shown.currency}',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Modo de precio: ${_priceModeLabel(shown.priceMode)}',
                  style: secondaryStyle,
                ),
                if (fullDetails) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'Tratamiento de IVA: ${_ivaTreatmentLabel(shown.ivaTreatment)}',
                    style: secondaryStyle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tasa de IVA: ${shown.ivaRateBasisPoints == null ? 'No requerida' : '${_formatBasisPoints(shown.ivaRateBasisPoints!)}%'}',
                    style: secondaryStyle,
                  ),
                ],
              ],
              if (administrator && costLabel != null) ...<Widget>[
                const SizedBox(height: 4),
                Semantics(
                  container: true,
                  label: costLabel,
                  excludeSemantics: true,
                  child: Text(costLabel!, style: secondaryStyle),
                ),
              ],
              if (fullDetails) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Unidad: ${product.quantitySpec.unit} '
                  '(precisión ${product.quantitySpec.precision})',
                  style: secondaryStyle,
                ),
              ],
              if (role != null) ...<Widget>[
                const SizedBox(height: 8),
                ..._holdingLines(
                  item: item,
                  role: role,
                  branchChoices: branchChoices,
                ),
              ],
              if (administrator && onConfigurePricing != null) ...<Widget>[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: ValueKey<String>(
                    'configure-price-${product.internalCode}',
                  ),
                  // Close the sheet first, then open the existing flow.
                  onPressed: () {
                    Navigator.of(context).pop();
                    onConfigurePricing!(product);
                  },
                  icon: const Icon(Icons.price_change_outlined),
                  label: const Text('Editar precio / IVA'),
                ),
              ],
              if (administrator && onRecordIntake != null) ...<Widget>[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: ValueKey<String>('intake-${product.internalCode}'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    onRecordIntake!(product);
                  },
                  icon: const Icon(Icons.inventory_outlined),
                  label: const Text('Registrar entrada de inventario'),
                ),
              ],
              const SizedBox(height: 16),
              // Separate QR surface (S1) so the code reads as its own block.
              Container(
                key: ValueKey<String>(
                  'product-sheet-qr-${product.internalCode}',
                ),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(child: ProductQrView(product: product)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stock lines shared by the compact card and the detail sheet. The
/// administrator sees a short line per known branch (Agotado markers stay);
/// the seller sees their own branch as "Existencias: N unidad" plus
/// "Agotado" when out of stock.
List<Widget> _holdingLines({
  required CatalogItem item,
  required InventoryRole? role,
  required List<CatalogBranchChoice> branchChoices,
}) {
  final CatalogProduct product = item.product;
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
          if (holding != null) return _holdingLine(holding, product, role);
          return Text(
            '${choices[branchId]!.branchName}: Agotado · Sin entrada registrada',
          );
        })
        .toList(growable: false);
  }
  if (role == InventoryRole.administrator && item.holdings.isEmpty) {
    return const <Widget>[Text('Sin existencias en sucursales')];
  }
  return item.holdings
      .map((CatalogHolding holding) => _holdingLine(holding, product, role))
      .toList(growable: false);
}

Widget _holdingLine(
  CatalogHolding holding,
  CatalogProduct product,
  InventoryRole? role,
) {
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
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text('Existencias: $quantity $unit'),
      if (holding.isOutOfStock)
        Text('Agotado', style: const TextStyle(fontWeight: FontWeight.bold)),
    ],
  );
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
