import 'package:flutter/material.dart';

import '../app/panel_layout.dart';
import '../app/primary_action_style.dart';
import '../catalog/catalog_product.dart';
import '../sales/sale_cart.dart';
import '../sales/sale_format.dart';
import '../sales/sale_quote.dart';
import 'correction_context.dart';
import 'correction_draft.dart';
import 'correction_exchange_controller.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_return_controller.dart' show ReturnLineEntry;
import 'correction_sale.dart';
import 'sale_corrections.dart';

export 'correction_exchange_controller.dart' show exchangePreviewDelay;

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Seller exchange form for one looked-up sale: the returned lines, reason
/// and note; new items from the branch catalog's priced products; the
/// server-computed settlement; the payment method for what the customer
/// owes; confirmation and the uncertain-retry lock.
class CorrectionExchangeForm extends StatefulWidget {
  const CorrectionExchangeForm({
    required this.sale,
    required this.corrections,
    required this.products,
    required this.productNames,
    required this.onBack,
    required this.onCompleted,
    this.previewDelay = exchangePreviewDelay,
    super.key,
  });

  final CorrectableSale sale;
  final SaleCorrections corrections;

  /// The branch catalog snapshot; only priced products are offered.
  final List<CatalogProduct> products;

  /// Catalog product names by product ID; unknown IDs are shown verbatim.
  final Map<String, String> productNames;
  final VoidCallback onBack;
  final ValueChanged<SaleExchangeReceipt> onCompleted;
  final Duration previewDelay;

  @override
  State<CorrectionExchangeForm> createState() => _CorrectionExchangeFormState();
}

class _CorrectionExchangeFormState extends State<CorrectionExchangeForm> {
  late final CorrectionExchangeController _controller =
      CorrectionExchangeController(
        sale: widget.sale,
        corrections: widget.corrections,
        products: widget.products,
        previewDelay: widget.previewDelay,
        onCompleted: (SaleExchangeReceipt receipt) =>
            widget.onCompleted(receipt),
      );

  @override
  void didUpdateWidget(CorrectionExchangeForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.corrections = widget.corrections;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _name(String productId) => widget.productNames[productId] ?? productId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (BuildContext context, _) => _buildForm(context),
  );

  Widget _buildForm(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectionExchangeController form = _controller;
    final String? folio = widget.sale.folio;
    final String? message = form.message;
    final String? newItemsMessage = form.newItemsMessage;
    final SaleExchangePreview? preview = form.preview;
    final bool owes =
        preview != null &&
        form.previewStatus == ExchangePreviewStatus.ready &&
        preview.customerPaysCentavos > 0;
    final Widget primary = Center(
      key: const ValueKey<String>('exchange-form'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('exchange-back'),
                  onPressed: form.isSubmitting ? null : widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver a la venta'),
                ),
              ),
              Text('Cambio de producto', style: theme.textTheme.headlineSmall),
              Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
              const Divider(height: 32),
              Text('Productos a devolver', style: theme.textTheme.titleMedium),
              for (final ReturnLineEntry entry in form.returnLines)
                _ReturnLineEditor(
                  key: ValueKey<String>(
                    'exchange-line-${entry.line.lineIndex}',
                  ),
                  entry: entry,
                  name: _name(entry.line.productId),
                  controller: form,
                ),
              const Divider(height: 32),
              Text('Motivo', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final CorrectionReason reason in CorrectionReason.values)
                    ChoiceChip(
                      key: ValueKey<String>(
                        'exchange-reason-${reason.wireValue}',
                      ),
                      label: Text(correctionReasonLabel(reason)),
                      selected: form.reason == reason,
                      onSelected: form.canEdit
                          ? (_) => form.setReason(reason)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey<String>('exchange-note'),
                controller: form.note,
                enabled: form.canEdit,
                onChanged: form.setNote,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: 'Nota (opcional)',
                  errorText: form.noteError,
                ),
              ),
              const Divider(height: 32),
              Text('Productos nuevos', style: theme.textTheme.titleMedium),
              for (final ExchangeNewLineEntry entry in form.newLines)
                _NewLineEditor(
                  key: ValueKey<String>('exchange-new-${entry.productId}'),
                  entry: entry,
                  controller: form,
                ),
              if (newItemsMessage != null)
                Text(
                  newItemsMessage,
                  key: const ValueKey<String>('exchange-new-message'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              const SizedBox(height: 8),
              Text('Catálogo', style: theme.textTheme.titleSmall),
              if (form.products.isEmpty)
                const Text('No hay productos con precio en el catálogo.'),
              for (final CatalogProduct product in form.products)
                _CatalogRow(product: product, controller: form),
              const Divider(height: 32),
              _PreviewSection(controller: form, name: _name),
              if (owes) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  'Método de pago de la diferencia',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final SalePaymentMethod method
                        in SalePaymentMethod.values)
                      ChoiceChip(
                        key: ValueKey<String>(
                          'exchange-payment-${method.wireValue}',
                        ),
                        label: Text(salePaymentLabel(method)),
                        selected: form.paymentMethod == method,
                        onSelected: form.canEdit
                            ? (_) => form.setPaymentMethod(method)
                            : null,
                      ),
                  ],
                ),
              ],
              if (message != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const ValueKey<String>('exchange-message'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (form.isLocked)
                FilledButton(
                  style: primaryActionStyle(context),
                  key: const ValueKey<String>('exchange-retry'),
                  onPressed: form.isSubmitting ? null : form.retrySubmit,
                  child: _label(form.isSubmitting, 'Reintentar'),
                )
              else
                FilledButton(
                  style: primaryActionStyle(context),
                  key: const ValueKey<String>('exchange-confirm'),
                  onPressed: form.canConfirm ? form.confirm : null,
                  child: _label(form.isSubmitting, 'Confirmar cambio'),
                ),
            ],
          ),
        ),
      ),
    );
    return PanelLayout(
      primary: primary,
      context: CorrectionSaleContext(
        sale: widget.sale,
        productNames: widget.productNames,
      ),
    );
  }

  Widget _label(bool busy, String text) => busy
      ? const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Text(text);
}

class _ReturnLineEditor extends StatelessWidget {
  const _ReturnLineEditor({
    required this.entry,
    required this.name,
    required this.controller,
    super.key,
  });

  final ReturnLineEntry entry;
  final String name;
  final CorrectionExchangeController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectableSaleLine line = entry.line;
    final String unit = line.quantitySpec.unit;
    final int index = line.lineIndex;
    final bool editable = controller.canEdit;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(name, style: theme.textTheme.titleSmall),
            Text('Restante: ${line.remainingDecimal} $unit'),
            if (!entry.returnable)
              Text(
                'Devuelto por completo',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else ...<Widget>[
              Row(
                children: <Widget>[
                  Checkbox(
                    semanticLabel: 'Seleccionar $name',
                    key: ValueKey<String>('exchange-line-select-$index'),
                    value: entry.selected,
                    onChanged: editable
                        ? (bool? value) =>
                              controller.setSelected(index, value ?? false)
                        : null,
                  ),
                  const Flexible(child: Text('Devolver este producto')),
                ],
              ),
              if (entry.selected) ...<Widget>[
                TextField(
                  key: ValueKey<String>('exchange-line-quantity-$index'),
                  controller: entry.quantity,
                  enabled: editable,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => controller.quantityChanged(),
                  decoration: InputDecoration(
                    labelText: 'Cantidad a devolver',
                    errorText: entry.error,
                    errorMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Máximo: ${line.remainingDecimal} $unit',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final ReturnCondition condition
                        in ReturnCondition.values)
                      ChoiceChip(
                        key: ValueKey<String>(
                          'exchange-line-condition-$index-'
                          '${condition.wireValue}',
                        ),
                        label: Text(returnConditionLabel(condition)),
                        selected: entry.condition == condition,
                        onSelected: editable
                            ? (_) => controller.setCondition(index, condition)
                            : null,
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _NewLineEditor extends StatelessWidget {
  const _NewLineEditor({
    required this.entry,
    required this.controller,
    super.key,
  });

  final ExchangeNewLineEntry entry;
  final CorrectionExchangeController controller;

  @override
  Widget build(BuildContext context) {
    final bool editable = controller.canEdit;
    final String id = entry.productId;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: ValueKey<String>('exchange-new-remove-$id'),
                  tooltip: 'Quitar',
                  onPressed: editable
                      ? () => controller.removeProduct(id)
                      : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            TextField(
              key: ValueKey<String>('exchange-new-quantity-$id'),
              controller: entry.quantity,
              enabled: editable,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => controller.quantityChanged(),
              decoration: InputDecoration(
                labelText: 'Cantidad (${entry.quantitySpec.unit})',
                errorText: entry.error,
                errorMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({required this.product, required this.controller});

  final CatalogProduct product;
  final CorrectionExchangeController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(product.name),
              // Informational only: the server prices the new items.
              Text(
                'Precio de lista: '
                '${formatMoney(product.pricing!.listedPriceCentavos)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        OutlinedButton(
          key: ValueKey<String>('exchange-product-add-${product.internalCode}'),
          onPressed: controller.canEdit
              ? () => controller.addProduct(product.internalCode)
              : null,
          child: const Text('Agregar'),
        ),
      ],
    ),
  );
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.controller, required this.name});

  final CorrectionExchangeController controller;
  final String Function(String productId) name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SaleExchangePreview? preview = controller.preview;
    final List<Widget> children = <Widget>[
      Text('Diferencia', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
    ];
    switch (controller.previewStatus) {
      case ExchangePreviewStatus.incomplete:
        children.add(
          Text(
            controller.isLocked
                ? 'El cálculo se confirmará al reintentar.'
                : 'Elige productos a devolver, productos nuevos y motivo para '
                      'calcular la diferencia.',
          ),
        );
      case ExchangePreviewStatus.loading:
        children.add(const Text('Calculando…'));
      case ExchangePreviewStatus.failed:
        children.addAll(<Widget>[
          Text(controller.previewMessage ?? exchangePreviewFailedMessage),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey<String>('exchange-preview-retry'),
              onPressed: controller.canEdit ? controller.retryPreview : null,
              child: const Text('Reintentar'),
            ),
          ),
        ]);
      case ExchangePreviewStatus.ready:
        if (preview != null) children.addAll(_ready(theme, preview));
    }
    return Column(
      key: const ValueKey<String>('exchange-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  List<Widget> _ready(ThemeData theme, SaleExchangePreview preview) {
    final List<SalePricedLine> lines = preview.newItems.lines;
    return <Widget>[
      Text('Valor devuelto: ${formatMoney(preview.returnedTotalCentavos)}'),
      if (preview.invoiced)
        Text(
          'IVA devuelto: '
          '${formatMoney(preview.returnedAdditionalIvaCentavos)}',
        ),
      const SizedBox(height: 8),
      for (final SalePricedLine line in lines)
        Padding(
          key: ValueKey<String>('exchange-preview-new-${line.productId}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${name(line.productId)} · ${line.quantityDecimal} '
                      '${line.unit}',
                    ),
                  ),
                  Text(formatMoney(line.totalCentavos)),
                ],
              ),
              if (preview.unavailableProductIds.contains(line.productId))
                Text(
                  'Sin existencias suficientes',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
      if (preview.invoiced)
        Text(
          'IVA de productos nuevos: '
          '${formatMoney(preview.newItems.additionalIvaCentavos)}',
        ),
      Text(
        'Total de productos nuevos: '
        '${formatMoney(preview.newItems.totalCentavos)}',
      ),
      const SizedBox(height: 8),
      Text(_settlement(preview), style: theme.textTheme.titleSmall),
    ];
  }

  String _settlement(SaleExchangePreview preview) {
    if (preview.customerPaysCentavos > 0) {
      return 'El cliente paga: ${formatMoney(preview.customerPaysCentavos)}';
    }
    if (preview.refundCentavos > 0) {
      return 'Se reembolsa: ${formatMoney(preview.refundCentavos)} por '
          '${salePaymentLabel(preview.refundMethod)}';
    }
    return 'Sin diferencia';
  }
}
