import 'package:flutter/material.dart';

import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_format.dart';
import 'correction_draft.dart';
import 'correction_receipt.dart';
import 'correction_return_controller.dart' show correctionSessionMessage;
import 'correction_return_form.dart';
import 'correction_return_receipt_view.dart';
import 'correction_sale.dart';
import 'correction_sale_detail.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English. This view replaces the catalog body while shown, like the sale
// receipt, so it is disposed with the page whenever the session changes.

const String _searchFailedMessage =
    'No se pudo buscar la venta. Intenta de nuevo.';

/// Seller correction lookup: a folio search plus the branch's recent sales
/// (last [correctionWindowDays] days). Choosing a sale shows its
/// [CorrectionSaleDetail], whose "Devolver" opens the [CorrectionReturnForm];
/// a registered return shows its receipt, then the refetched sale. A return
/// committed while no form was shown (for example, the view closed during
/// its submit) shows its receipt on entry; leaving the receipt acknowledges
/// it.
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

  /// The sale whose return form is shown.
  CorrectableSale? _returning;

  /// The registered return and the sale it was made against.
  (SaleReturnReceipt, CorrectableSale)? _receipt;

  /// The sale ID being refetched after a return, and its failure if any.
  String? _refreshSaleId;
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    // A committed but unseen return shows its receipt first; otherwise an
    // unresolved return reopens its form, locked to the stored draft.
    final UnacknowledgedReturn? committed = widget.corrections
        .unacknowledgedReturn();
    final SaleCorrectionDraft? unresolved = widget.corrections
        .unresolvedDraft();
    if (committed != null) {
      _receipt = (committed.receipt, committed.draft.sale);
    } else if (unresolved is SaleReturnDraft) {
      _returning = unresolved.sale;
    }
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
            ? correctionSessionMessage
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
    } catch (failure) {
      // A stale result whose generation still matches was superseded by a
      // lookup outside this view; nothing else owns the outcome here, so it
      // is shown as a retryable failure rather than dropped.
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
          '(últimos $correctionWindowDays días)',
    final SaleRejectedException rejected when rejected.isFolioAmbiguous =>
      'Hay más de una venta con ese folio. '
          'Elige la venta en la lista de ventas recientes.',
    SaleRejectedException(code: 'failed-precondition') =>
      'Esta venta no se puede corregir en este momento.',
    SaleSessionException() => correctionSessionMessage,
    _ => _searchFailedMessage,
  };

  void _completeReturn(SaleReturnReceipt receipt) {
    final CorrectableSale? sale = _returning;
    if (sale == null) return;
    setState(() {
      _returning = null;
      _selected = null;
      _receipt = (receipt, sale);
    });
  }

  /// Refetches the sale by ID so the detail shows the server's updated
  /// returned and remaining quantities.
  Future<void> _refreshSale(String saleId) async {
    final int generation = ++_searchGeneration;
    setState(() {
      _receipt = null;
      _selected = null;
      _refreshSaleId = saleId;
      _refreshError = null;
    });
    try {
      final CorrectableSale sale = await widget.corrections.find(
        SaleLookupQuery.bySaleId(saleId),
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _refreshSaleId = null;
        _selected = sale;
      });
    } catch (failure) {
      if (!mounted || generation != _searchGeneration) return;
      setState(
        () => _refreshError = failure is SaleSessionException
            ? correctionSessionMessage
            : 'No se pudo actualizar la venta.',
      );
    }
  }

  void _newSearch() {
    _searchGeneration += 1;
    setState(() {
      _receipt = null;
      _returning = null;
      _selected = null;
      _refreshSaleId = null;
      _refreshError = null;
      _searching = false;
      _searchError = null;
      _folio.clear();
    });
    _loadRecent();
  }

  @override
  Widget build(BuildContext context) {
    final (SaleReturnReceipt, CorrectableSale)? receipt = _receipt;
    if (receipt != null) {
      return CorrectionReturnReceiptView(
        receipt: receipt.$1,
        sale: receipt.$2,
        productNames: widget.productNames,
        onBackToSale: () {
          widget.corrections.acknowledgeReturn(receipt.$1);
          _refreshSale(receipt.$2.saleId);
        },
        onNewSearch: () {
          widget.corrections.acknowledgeReturn(receipt.$1);
          _newSearch();
        },
      );
    }
    final CorrectableSale? returning = _returning;
    if (returning != null) {
      return CorrectionReturnForm(
        key: ValueKey<String>('return-form-${returning.saleId}'),
        sale: returning,
        corrections: widget.corrections,
        productNames: widget.productNames,
        onBack: () => setState(() {
          _returning = null;
          _selected ??= returning;
        }),
        onCompleted: _completeReturn,
      );
    }
    final String? refreshSaleId = _refreshSaleId;
    if (refreshSaleId != null) return _refreshView(refreshSaleId);
    final CorrectableSale? selected = _selected;
    if (selected != null) {
      return CorrectionSaleDetail(
        sale: selected,
        productNames: widget.productNames,
        onBack: () => setState(() => _selected = null),
        onReturn: () => setState(() => _returning = selected),
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
              'Ventas recientes (últimos $correctionWindowDays días)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ..._recentSection(),
          ],
        ),
      ),
    );
  }

  Widget _refreshView(String saleId) {
    final String? error = _refreshError;
    return Center(
      key: const ValueKey<String>('correction-refresh'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    error,
                    key: const ValueKey<String>('correction-refresh-error'),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      FilledButton(
                        key: const ValueKey<String>('correction-refresh-retry'),
                        onPressed: () => _refreshSale(saleId),
                        child: const Text('Reintentar'),
                      ),
                      OutlinedButton(
                        key: const ValueKey<String>(
                          'correction-refresh-new-search',
                        ),
                        onPressed: _newSearch,
                        child: const Text('Nueva búsqueda'),
                      ),
                    ],
                  ),
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
