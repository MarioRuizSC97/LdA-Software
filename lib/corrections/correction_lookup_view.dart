import 'package:flutter/material.dart';

import '../app/panel_layout.dart';
import '../app/primary_action_style.dart';
import '../catalog/catalog_product.dart';
import '../firebase/emulator_correction_gateway.dart';
import '../firebase/emulator_sale_gateway.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_format.dart';
import 'correction_context.dart';
import 'correction_draft.dart';
import 'correction_exchange_form.dart';
import 'correction_exchange_receipt_view.dart';
import 'correction_form_support.dart' show correctionSessionMessage;
import 'correction_receipt.dart';
import 'correction_replacement_form.dart';
import 'correction_replacement_receipt_view.dart';
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
/// [CorrectionSaleDetail], whose actions open the return, replacement and
/// exchange forms; a registered correction shows its receipt, then the
/// refetched sale. A correction of any kind committed while no form was
/// shown (for example, the view closed during its submit) shows its receipt
/// on entry, and an unresolved one reopens its locked form; leaving the
/// receipt acknowledges it.
class CorrectionLookupView extends StatefulWidget {
  const CorrectionLookupView({
    required this.corrections,
    required this.productNames,
    this.products = const <CatalogProduct>[],
    super.key,
  });

  final SaleCorrections corrections;

  /// Catalog product names by product ID, for the sale detail.
  final Map<String, String> productNames;

  /// The branch catalog snapshot; its priced products are the new items an
  /// exchange may offer.
  final List<CatalogProduct> products;

  @override
  State<CorrectionLookupView> createState() => _CorrectionLookupViewState();
}

enum _RecentStatus { loading, failed, ready }

enum _FormKind { returning, replacing, exchanging }

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

  /// The open correction form and the sale it corrects.
  (_FormKind, CorrectableSale)? _form;

  /// The registered correction and the sale it was made against.
  (SaleCorrectionReceipt, CorrectableSale)? _receipt;

  /// The sale ID being refetched after a return, and its failure if any.
  String? _refreshSaleId;
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    // A committed but unseen correction shows its receipt first; otherwise
    // an unresolved one reopens its form, locked to the stored draft.
    final CompletedCorrection? committed = widget.corrections.unacknowledged();
    final SaleCorrectionDraft? unresolved = widget.corrections
        .unresolvedDraft();
    if (committed != null) {
      _receipt = (committed.receipt, committed.draft.sale);
    } else if (unresolved != null) {
      _form = (
        switch (unresolved) {
          SaleReturnDraft() => _FormKind.returning,
          SaleReplacementDraft() => _FormKind.replacing,
          SaleExchangeDraft() => _FormKind.exchanging,
        },
        unresolved.sale,
      );
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

  void _complete(SaleCorrectionReceipt receipt) {
    final CorrectableSale? sale = _form?.$2;
    if (sale == null) return;
    setState(() {
      _form = null;
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
      _form = null;
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
    final (SaleCorrectionReceipt, CorrectableSale)? receipt = _receipt;
    if (receipt != null) return _receiptView(receipt.$1, receipt.$2);
    final (_FormKind, CorrectableSale)? form = _form;
    if (form != null) return _formView(form.$1, form.$2);
    final String? refreshSaleId = _refreshSaleId;
    if (refreshSaleId != null) return _refreshView(refreshSaleId);
    final CorrectableSale? selected = _selected;
    if (selected != null) {
      return CorrectionSaleDetail(
        sale: selected,
        productNames: widget.productNames,
        onBack: () => setState(() => _selected = null),
        onReturn: () => setState(() => _form = (_FormKind.returning, selected)),
        onReplace: () =>
            setState(() => _form = (_FormKind.replacing, selected)),
        onExchange: () =>
            setState(() => _form = (_FormKind.exchanging, selected)),
      );
    }
    final ThemeData theme = Theme.of(context);
    final Widget primary = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
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
                    style: primaryActionStyle(context),
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
    return PanelLayout(
      primary: primary,
      // A short help card needs a narrow rail; keeping it narrow also keeps
      // the recent-sale rows wide enough to show their total as a trailing.
      maxContextWidth: 240,
      context: const CorrectionHelpContext(),
    );
  }

  /// Every receipt kind has its view: the switch is exhaustive over the
  /// sealed receipt type. Leaving it acknowledges exactly that receipt.
  Widget _receiptView(SaleCorrectionReceipt receipt, CorrectableSale sale) {
    void back() {
      widget.corrections.acknowledge(receipt);
      _refreshSale(sale.saleId);
    }

    void search() {
      widget.corrections.acknowledge(receipt);
      _newSearch();
    }

    return switch (receipt) {
      final SaleReturnReceipt value => CorrectionReturnReceiptView(
        receipt: value,
        sale: sale,
        productNames: widget.productNames,
        onBackToSale: back,
        onNewSearch: search,
      ),
      final SaleReplacementReceipt value => CorrectionReplacementReceiptView(
        receipt: value,
        sale: sale,
        productNames: widget.productNames,
        onBackToSale: back,
        onNewSearch: search,
      ),
      final SaleExchangeReceipt value => CorrectionExchangeReceiptView(
        receipt: value,
        sale: sale,
        productNames: _allNames(),
        onBackToSale: back,
        onNewSearch: search,
      ),
    };
  }

  Widget _formView(_FormKind kind, CorrectableSale sale) {
    void back() => setState(() {
      _form = null;
      _selected ??= sale;
    });
    return switch (kind) {
      _FormKind.returning => CorrectionReturnForm(
        key: ValueKey<String>('return-form-${sale.saleId}'),
        sale: sale,
        corrections: widget.corrections,
        productNames: widget.productNames,
        onBack: back,
        onCompleted: _complete,
      ),
      _FormKind.replacing => CorrectionReplacementForm(
        key: ValueKey<String>('replacement-form-${sale.saleId}'),
        sale: sale,
        corrections: widget.corrections,
        productNames: widget.productNames,
        onBack: back,
        onCompleted: _complete,
      ),
      _FormKind.exchanging => CorrectionExchangeForm(
        key: ValueKey<String>('exchange-form-${sale.saleId}'),
        sale: sale,
        corrections: widget.corrections,
        products: widget.products,
        productNames: _allNames(),
        onBack: back,
        onCompleted: _complete,
      ),
    };
  }

  /// Sale product names plus the catalog products' names, for new items.
  Map<String, String> _allNames() => <String, String>{
    for (final CatalogProduct product in widget.products)
      product.internalCode: product.name,
    ...widget.productNames,
  };

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
                        style: primaryActionStyle(context),
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
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stacked =
            constraints.maxWidth <
            480 * MediaQuery.textScalerOf(context).scale(1);
        final Widget total = Text(
          formatMoney(sale.totalCentavos),
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        );
        return ListTile(
          onTap: onTap,
          title: Text(sale.folio ?? 'Venta sin folio'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${formatSaleDateTime(sale.createdAt.toLocal())} · '
                '${salePaymentLabel(sale.paymentMethod)}',
              ),
              if (stacked) total,
            ],
          ),
          trailing: stacked ? null : total,
        );
      },
    ),
  );
}
