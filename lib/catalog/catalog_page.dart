import 'package:flutter/material.dart';

import '../auth/emulator_session.dart';
import 'catalog_product.dart';
import 'catalog_repository.dart';
import 'product_qr.dart';

typedef CatalogSnapshotLoader =
    Future<CatalogSnapshot> Function(EmulatorSession session);

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
    super.key,
  });

  final EmulatorSession session;
  final CatalogSnapshotLoader catalogLoader;
  final Future<void> Function() onLogout;

  @override
  State<AuthenticatedCatalogPage> createState() =>
      _AuthenticatedCatalogPageState();
}

class _AuthenticatedCatalogPageState extends State<AuthenticatedCatalogPage> {
  CatalogSnapshot? _snapshot;
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _requestCatalog(initial: true);
  }

  @override
  void didUpdateWidget(AuthenticatedCatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sessionIdentity(oldWidget.session) != _sessionIdentity(widget.session)) {
      _requestCatalog();
    }
  }

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
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
      final CatalogSnapshot snapshot = await widget.catalogLoader(widget.session);
      _validateCatalogSnapshot(snapshot, widget.session);
      if (!mounted || generation != _generation) return;
      setState(() {
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
          OutlinedButton(onPressed: widget.onLogout, child: const Text('Log out')),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _SessionStatus(session: widget.session),
            Expanded(child: _catalogBody()),
          ],
        ),
      ),
    );
  }

  Widget _catalogBody() {
    if (_loading) return const _CatalogLoading();
    if (_failed) return _CatalogError(onRetry: _requestCatalog);
    final List<CatalogItem> items = _snapshot?.items ?? const <CatalogItem>[];
    if (items.isEmpty) return const _EmptyCatalog();
    return _CatalogList(items: items, role: widget.session.role);
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
  const _CatalogList({required this.items, this.role});

  final List<CatalogItem> items;
  final InventoryRole? role;

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
                child: _ProductCard(item: items[index], role: role),
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
  const _ProductCard({required this.item, required this.role});

  final CatalogItem item;
  final InventoryRole? role;

  @override
  Widget build(BuildContext context) {
    final Widget details = _ProductDetails(item: item, role: role);
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
  const _ProductDetails({required this.item, required this.role});

  final CatalogItem item;
  final InventoryRole? role;

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
            'Listed price: ${_formatCentavos(pricing.listedPriceCentavos)} '
            '${pricing.currency}',
          ),
          const SizedBox(height: 4),
          Text('IVA treatment: ${pricing.ivaTreatment}'),
        ],
        if (role != null) ...<Widget>[
          const SizedBox(height: 12),
          ..._holdingRows(),
        ],
      ],
    );
  }

  List<Widget> _holdingRows() {
    if (role == InventoryRole.administrator && item.holdings.isEmpty) {
      return const <Widget>[Text('No branch holdings')];
    }
    return item.holdings.map((CatalogHolding holding) {
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
    }).toList(growable: false);
  }

  String _formatCentavos(int centavos) {
    final int absolute = centavos.abs();
    final String sign = centavos < 0 ? '-' : '';
    final String fraction = (absolute % 100).toString().padLeft(2, '0');
    return '$sign${absolute ~/ 100}.$fraction';
  }

  String _formatQuantity(int scaled, int precision) {
    if (precision == 0) return scaled.toString();
    final int divisor = _powerOfTen(precision);
    final String fraction = (scaled % divisor).toString().padLeft(precision, '0');
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
