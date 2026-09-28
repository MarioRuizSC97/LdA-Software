import 'package:flutter/material.dart';

import 'catalog_product.dart';
import 'catalog_repository.dart';
import 'product_qr.dart';

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
                        return Center(
                          child: Semantics(
                            label: 'Loading catalog',
                            child: const CircularProgressIndicator(),
                          ),
                        );
                      }
                      if (snapshot.hasError) {
                        return _CatalogError(onRetry: _retry);
                      }

                      final List<CatalogProduct> products =
                          snapshot.data ?? const <CatalogProduct>[];
                      if (products.isEmpty) return const _EmptyCatalog();
                      return _CatalogList(products: products);
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  const _CatalogList({required this.products});

  final List<CatalogProduct> products;

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
            itemCount: products.length,
            itemBuilder: (BuildContext context, int index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: _ProductCard(product: products[index]),
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
  const _ProductCard({required this.product});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    final Widget details = _ProductDetails(product: product);
    final Widget qr = ProductQrView(product: product);

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
  const _ProductDetails({required this.product});

  final CatalogProduct product;

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
      ],
    );
  }

  String _formatCentavos(int centavos) {
    final int absolute = centavos.abs();
    final String sign = centavos < 0 ? '-' : '';
    final String fraction = (absolute % 100).toString().padLeft(2, '0');
    return '$sign${absolute ~/ 100}.$fraction';
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
