import 'package:flutter/material.dart';

import '../auth/emulator_session.dart';
import 'catalog_product.dart';
import 'catalog_repository.dart';
import 'product_creation.dart';
import 'product_pricing.dart';
import 'product_qr.dart';

typedef CatalogSnapshotLoader = Future<CatalogSnapshot> Function(
  EmulatorSession session,
);
typedef ProductPricingDraftLookup = ProductPricingDraft? Function(
  String productId,
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

  @override
  State<AuthenticatedCatalogPage> createState() =>
      _AuthenticatedCatalogPageState();
}

class _AuthenticatedCatalogPageState extends State<AuthenticatedCatalogPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _unit = TextEditingController();
  final TextEditingController _precision = TextEditingController();
  final TextEditingController _listedPrice = TextEditingController();
  final TextEditingController _ivaRate = TextEditingController();
  CatalogSnapshot? _snapshot;
  ProductCreationCoordinator? _creationCoordinator;
  ProductCreationResult? _creationSuccess;
  String? _creationError;
  bool _creationVisible = false;
  bool _creationPending = false;
  bool _creationUncertain = false;
  CatalogProduct? _pricingProduct;
  ProductPricingDraft? _lockedPricingDraft;
  ProductPricingResult? _pricingSuccess;
  String? _pricingError;
  String? _listedPriceError;
  String? _ivaRateError;
  String? _priceMode;
  String? _ivaTreatment;
  bool _pricingPending = false;
  bool _pricingUncertain = false;
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;
  int _creationGeneration = 0;
  int _pricingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _configureCreation();
    _requestCatalog(initial: true);
  }

  @override
  void didUpdateWidget(AuthenticatedCatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sessionChanged =
        _sessionIdentity(oldWidget.session) != _sessionIdentity(widget.session);
    if (sessionChanged ||
        oldWidget.createProduct != widget.createProduct ||
        oldWidget.unresolvedProductDraft != widget.unresolvedProductDraft) {
      _creationGeneration += 1;
      _creationVisible = false;
      _creationPending = false;
      _creationUncertain = false;
      _creationError = null;
      _creationSuccess = null;
      _configureCreation();
    }
    if (sessionChanged || oldWidget.setProductPrice != widget.setProductPrice) {
      _pricingGeneration += 1;
      _clearPricingPresentation();
    }
    if (sessionChanged) _requestCatalog();
  }

  @override
  void dispose() {
    _generation += 1;
    _creationGeneration += 1;
    _pricingGeneration += 1;
    _name.dispose();
    _unit.dispose();
    _precision.dispose();
    _listedPrice.dispose();
    _ivaRate.dispose();
    super.dispose();
  }

  void _configureCreation() {
    _name.clear();
    _unit.clear();
    _precision.clear();
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
      _precision.text = unresolved.precision.toString();
      _creationVisible = true;
      _creationUncertain = true;
      _creationError =
          'The outcome is unknown. Retry the same request before editing.';
    }
  }

  void _clearPricingPresentation() {
    _pricingProduct = null;
    _lockedPricingDraft = null;
    _pricingError = null;
    _listedPriceError = null;
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
    _ivaRateError = null;
    _lockedPricingDraft = draft;
    _listedPrice.text = draft.listedPriceMxn;
    _priceMode = draft.priceMode;
    _ivaTreatment = draft.ivaTreatment;
    _ivaRate.text = draft.ivaRatePercent ?? '';
    _pricingUncertain = true;
    _pricingError =
        'The outcome is unknown. Retry the same request before editing.';
  }

  Future<void> _requestCatalog({bool initial = false}) async {
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
      if (!mounted || generation != _generation) return;
      setState(() {
        _restorePricingDraft(snapshot);
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LDA Inventory'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh catalog',
            onPressed: _loading ? null : _requestCatalog,
            icon: const Icon(Icons.refresh),
          ),
          OutlinedButton(
            onPressed: widget.onLogout,
            child: const Text('Log out'),
          ),
          const SizedBox(width: 12),
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
            if (_creationCoordinator != null)
              _CreationToolbar(
                onPressed: _creationPending ? null : _showCreation,
              ),
            Expanded(
              child: _creationVisible
                  ? _creationForm()
                  : _pricingProduct != null
                  ? _pricingForm()
                  : _catalogBody(),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreation() {
    setState(() => _creationVisible = true);
  }

  void _closeCreation() {
    _creationCoordinator?.closePresentation();
    setState(() => _creationVisible = false);
  }

  Future<void> _submitCreation() async {
    final ProductCreationCoordinator? coordinator = _creationCoordinator;
    if (coordinator == null || _creationPending) return;
    final int generation = ++_creationGeneration;
    int? precision;
    if (!_creationUncertain) {
      precision = int.tryParse(_precision.text);
      if (precision == null) {
        setState(() {
          _creationError = 'Precision must be an integer from 0 through 6.';
        });
        return;
      }
    }

    setState(() {
      _creationPending = true;
      _creationError = null;
    });
    try {
      final ProductCreationResult result = _creationUncertain
          ? await coordinator.retry()
          : await coordinator.submit(
              name: _name.text,
              unit: _unit.text,
              precision: precision!,
            );
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = false;
        _creationVisible = false;
        _creationSuccess = result;
        _name.clear();
        _unit.clear();
        _precision.clear();
      });
      await _requestCatalog();
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
        _creationError = 'Product creation was rejected (${error.code}).';
      });
    } on ProductCreationStaleException {
      // A newer attempt or session owns presentation authority.
    } catch (_) {
      if (!mounted || generation != _creationGeneration) return;
      setState(() {
        _creationPending = false;
        _creationUncertain = true;
        _creationError =
            'The outcome is unknown. Retry the same request before editing.';
      });
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
                  'Create product',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'The server assigns the stable internal code and QR identity.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey<String>('create-product-name'),
                controller: _name,
                enabled: !locked,
                maxLength: maxProductNameLength,
                decoration: const InputDecoration(labelText: 'Product name'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey<String>('create-product-unit'),
                controller: _unit,
                enabled: !locked,
                decoration: const InputDecoration(
                  labelText: 'Unit identifier',
                  helperText: 'Lowercase identifier, for example piece or kg.',
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey<String>('create-product-precision'),
                controller: _precision,
                enabled: !locked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Quantity precision',
                  helperText: 'Integer from 0 through 6.',
                ),
              ),
              if (_creationError case final String error) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Product creation error',
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
                            label: 'Creating product',
                            liveRegion: true,
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _creationUncertain
                                ? 'Retry same request'
                                : 'Create',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _creationPending ? null : _closeCreation,
                    child: const Text('Close'),
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
    final ProductPricingDraft? unresolved = _unresolvedPricingDraftFor(
      product.internalCode,
    );
    final CatalogPricing? pricing = product.pricing;
    setState(() {
      _pricingProduct = product;
      _pricingSuccess = null;
      _pricingError = null;
      _listedPriceError = null;
      _ivaRateError = null;
      _pricingUncertain = unresolved != null;
      _lockedPricingDraft = unresolved;
      if (unresolved != null) {
        _lockPricingDraft(unresolved);
      } else if (pricing != null) {
        _listedPrice.text = _formatPricingCentavos(pricing.listedPriceCentavos);
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
    setState(() {
      _pricingProduct = null;
      _listedPriceError = null;
      _ivaRateError = null;
    });
  }

  void _changeIvaTreatment(String? value) {
    setState(() {
      _ivaTreatment = value;
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
      final bool missingRate =
          _ivaTreatment == 'taxable' && _ivaRate.text.trim().isEmpty;
      if (missingPrice || missingRate) {
        setState(() {
          _pricingError = null;
          _listedPriceError = missingPrice ? 'Listed price is required.' : null;
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
          _pricingError =
              'The outcome is unknown. Retry the same request before editing.';
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
                  'Configure price / IVA',
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
              DropdownButtonFormField<String>(
                key: const ValueKey<String>('pricing-mode'),
                isExpanded: true,
                initialValue: _priceMode,
                decoration: const InputDecoration(labelText: 'Price mode'),
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
                    : (String? value) => setState(() => _priceMode = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey<String>('pricing-treatment'),
                isExpanded: true,
                initialValue: _ivaTreatment,
                decoration: const InputDecoration(labelText: 'IVA treatment'),
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
                                ? 'Retry same request'
                                : 'Save price / IVA',
                          ),
                  ),
                  OutlinedButton(
                    onPressed: _pricingPending ? null : _closePricing,
                    child: const Text('Close'),
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
      onConfigurePricing:
          widget.session.role == InventoryRole.administrator &&
              widget.setProductPrice != null
          ? _showPricing
          : null,
    );
  }
}

String _sessionIdentity(EmulatorSession session) =>
    '${session.userId}|${session.role.name}|${session.branchId ?? ''}';

void _validateCatalogSnapshot(
  CatalogSnapshot snapshot,
  EmulatorSession session,
) {
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
    final String? name = holding.branchName;
    if (name == null ||
        name.isEmpty ||
        name.length > 120 ||
        name.trim() != name ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
      throw const FormatException('catalog branch name is invalid');
    }
  }
}

/// Width of the required-error border, stronger than the 1.0 normal border.
const double _errorBorderWidth = 2.0;

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

String _formatPricingCentavos(int centavos) {
  final int absolute = centavos.abs();
  final String sign = centavos < 0 ? '-' : '';
  final String fraction = (absolute % 100).toString().padLeft(2, '0');
  return '$sign${absolute ~/ 100}.$fraction';
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
      label: 'Authenticated local catalog session',
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: <Widget>[
              Text('Authenticated locally', style: style),
              Text(session.email, style: style),
              Text('Role: ${session.role.label}', style: style),
              if (session.branchId case final String branchId)
                Text('Branch: $branchId', style: style),
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
        label: const Text('Create product'),
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
    label: 'Product creation succeeded',
    child: ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Flexible(child: Text('Created product ${result.internalCode}')),
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
      label: 'Loading catalog',
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
  const _CatalogList({required this.items, this.role, this.onConfigurePricing});

  final List<CatalogItem> items;
  final InventoryRole? role;
  final void Function(CatalogProduct product)? onConfigurePricing;

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
                    'Catalog',
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
                  role: role,
                  onConfigurePricing: onConfigurePricing,
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

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.item,
    required this.role,
    required this.onConfigurePricing,
  });

  final CatalogItem item;
  final InventoryRole? role;
  final void Function(CatalogProduct product)? onConfigurePricing;

  @override
  Widget build(BuildContext context) {
    final Widget details = _ProductDetails(
      item: item,
      role: role,
      onConfigurePricing: onConfigurePricing,
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
    required this.item,
    required this.role,
    required this.onConfigurePricing,
  });

  final CatalogItem item;
  final InventoryRole? role;
  final void Function(CatalogProduct product)? onConfigurePricing;

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
          'Quantity: ${product.quantitySpec.unit} '
          '(precision ${product.quantitySpec.precision})',
        ),
        if (product.pricing case final CatalogPricing pricing) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            'Listed price: ${_formatPricingCentavos(pricing.listedPriceCentavos)} '
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
            label: const Text('Configure price / IVA'),
          ),
        ],
      ],
    );
  }

  List<Widget> _holdingRows() {
    if (role == InventoryRole.administrator && item.holdings.isEmpty) {
      return const <Widget>[Text('No branch holdings')];
    }
    return item.holdings
        .map((CatalogHolding holding) {
          final String quantity = _formatQuantity(
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
                Text(
                  'Agotado',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
            ],
          );
        })
        .toList(growable: false);
  }

  String _formatQuantity(int scaled, int precision) {
    if (precision == 0) return scaled.toString();
    final int divisor = _powerOfTen(precision);
    final String fraction = (scaled % divisor).toString().padLeft(
      precision,
      '0',
    );
    return '${scaled ~/ divisor}.$fraction';
  }

  int _powerOfTen(int exponent) {
    var result = 1;
    for (var index = 0; index < exponent; index += 1) {
      result *= 10;
    }
    return result;
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) {
    return const _CatalogMessage(
      icon: Icons.inventory_2_outlined,
      title: 'No products yet',
      message: 'Products will appear here when available.',
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
      title: 'Catalog unavailable',
      message: 'Check your connection and try again.',
      action: FilledButton(onPressed: onRetry, child: const Text('Try again')),
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
