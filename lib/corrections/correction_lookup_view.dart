import 'package:flutter/material.dart';

import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_format.dart';
import 'correction_sale.dart';
import 'correction_sale_detail.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English. This view replaces the catalog body while shown, like the sale
// receipt, so it is disposed with the page whenever the session changes.

const String _sessionMessage =
    'Tu sesión cambió. Inicia sesión de nuevo para continuar.';

/// Seller correction lookup: a folio search plus the branch's recent sales
/// (last 15 days). Choosing a sale shows its [CorrectionSaleDetail].
class CorrectionLookupView extends StatefulWidget {
  const CorrectionLookupView({
    required this.corrections,
    required this.productNames,
    required this.onClose,
    super.key,
  });

  final SaleCorrections corrections;

  /// Catalog product names by product ID, for the sale detail.
  final Map<String, String> productNames;
  final VoidCallback onClose;

  @override
  State<CorrectionLookupView> createState() => _CorrectionLookupViewState();
}

enum _RecentStatus { loading, failed, ready }

class _CorrectionLookupViewState extends State<CorrectionLookupView> {
  final TextEditingController _folio = TextEditingController();
  _RecentStatus _recentStatus = _RecentStatus.loading;
  String? _recentError;
  List<CorrectableSale> _recent = const <CorrectableSale>[];
  int _recentGeneration = 0;
  int _searchGeneration = 0;
  bool _searching = false;
  String? _searchError;
  CorrectableSale? _selected;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _folio.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final int generation = ++_recentGeneration;
    setState(() {
      _recentStatus = _RecentStatus.loading;
      _recentError = null;
    });
    try {
      final RecentCorrectableSales recent = await widget.corrections
          .listRecent();
      if (!mounted || generation != _recentGeneration) return;
      setState(() {
        _recent = recent.sales;
        _recentStatus = _RecentStatus.ready;
      });
    } catch (error) {
      if (!mounted || generation != _recentGeneration) return;
      setState(() {
        _recentStatus = _RecentStatus.failed;
        _recentError = error is SaleSessionException
            ? _sessionMessage
            : 'No se pudieron cargar las ventas recientes.';
      });
    }
  }

  Future<void> _search() async {
    if (_searching) return;
    final String text = _folio.text.trim();
    if (text.isEmpty) {
      setState(() => _searchError = 'Escribe el folio del ticket.');
      return;
    }
    final SaleLookupQuery query;
    try {
      query = SaleLookupQuery.byFolio(text);
    } on CorrectionValidationException {
      setState(
        () => _searchError =
            'El folio no es válido. Usa el formato del ticket, '
            'por ejemplo NTE-3F2A-9C1B.',
      );
      return;
    }
    final int generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    String? error;
    CorrectableSale? sale;
    try {
      sale = await widget.corrections.find(query);
    } on SaleStaleException {
      // Superseded by a newer search, which owns the outcome.
    } catch (failure) {
      error = _searchMessage(failure);
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _searching = false;
      _searchError = error;
      if (sale != null) _selected = sale;
    });
  }

  String _searchMessage(Object failure) => switch (failure) {
    SaleRejectedException(code: 'not-found') =>
      'No se encontró una venta con ese folio en esta sucursal '
          '(últimos 15 días)',
    SaleRejectedException(code: 'failed-precondition') =>
      'Hay más de una venta con ese folio. '
          'Elige la venta en la lista de ventas recientes.',
    SaleSessionException() => _sessionMessage,
    _ => 'No se pudo buscar la venta. Intenta de nuevo.',
  };

  @override
  Widget build(BuildContext context) {
    final CorrectableSale? selected = _selected;
    if (selected != null) {
      return CorrectionSaleDetail(
        sale: selected,
        productNames: widget.productNames,
        onBack: () => setState(() => _selected = null),
      );
    }
    final ThemeData theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey<String>('corrections-close'),
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Volver al catálogo'),
              ),
            ),
            Text('Correcciones', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('correction-folio'),
                    controller: _folio,
                    enabled: !_searching,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      labelText: 'Folio',
                      hintText: 'NTE-3F2A-9C1B',
                      errorText: _searchError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton(
                    key: const ValueKey<String>('correction-search'),
                    onPressed: _searching ? null : _search,
                    child: _searching
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Buscar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Ventas recientes (últimos 15 días)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ..._recentSection(),
          ],
        ),
      ),
    );
  }

  List<Widget> _recentSection() => switch (_recentStatus) {
    _RecentStatus.loading => <Widget>[
      const Center(
        key: ValueKey<String>('correction-recent-loading'),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      ),
    ],
    _RecentStatus.failed => <Widget>[
      Text(
        _recentError!,
        key: const ValueKey<String>('correction-recent-error'),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          key: const ValueKey<String>('correction-recent-retry'),
          onPressed: _loadRecent,
          child: const Text('Reintentar'),
        ),
      ),
    ],
    _RecentStatus.ready when _recent.isEmpty => <Widget>[
      const Text('No hay ventas recientes'),
    ],
    _RecentStatus.ready => <Widget>[
      for (final CorrectableSale sale in _recent)
        _RecentSaleTile(
          key: ValueKey<String>('correction-sale-${sale.saleId}'),
          sale: sale,
          onTap: () => setState(() {
            _searchGeneration += 1;
            _searching = false;
            _selected = sale;
          }),
        ),
    ],
  };
}

class _RecentSaleTile extends StatelessWidget {
  const _RecentSaleTile({required this.sale, required this.onTap, super.key});

  final CorrectableSale sale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      title: Text(sale.folio ?? 'Venta sin folio'),
      subtitle: Text(
        '${formatSaleDateTime(sale.createdAt.toLocal())} · '
        '${salePaymentLabel(sale.paymentMethod)}',
      ),
      trailing: Text(formatMoney(sale.totalCentavos)),
    ),
  );
}
