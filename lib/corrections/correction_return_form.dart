import 'package:flutter/material.dart';

import '../app/panel_layout.dart';
import '../sales/sale_format.dart';
import 'correction_context.dart';
import 'correction_draft.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_return_controller.dart';
import 'correction_sale.dart';
import 'sale_corrections.dart';

export 'correction_return_controller.dart' show returnPreviewDelay;

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Seller return form for one looked-up sale: per-line quantity and
/// condition, reason and note, the server-computed refund, confirmation,
/// and the uncertain-retry lock.
class CorrectionReturnForm extends StatefulWidget {
  const CorrectionReturnForm({
    required this.sale,
    required this.corrections,
    required this.productNames,
    required this.onBack,
    required this.onCompleted,
    this.previewDelay = returnPreviewDelay,
    super.key,
  });

  final CorrectableSale sale;
  final SaleCorrections corrections;

  /// Catalog product names by product ID; unknown IDs are shown verbatim.
  final Map<String, String> productNames;
  final VoidCallback onBack;
  final ValueChanged<SaleReturnReceipt> onCompleted;
  final Duration previewDelay;

  @override
  State<CorrectionReturnForm> createState() => _CorrectionReturnFormState();
}

class _CorrectionReturnFormState extends State<CorrectionReturnForm> {
  late final CorrectionReturnController _controller =
      CorrectionReturnController(
        sale: widget.sale,
        corrections: widget.corrections,
        previewDelay: widget.previewDelay,
        onCompleted: (SaleReturnReceipt receipt) => widget.onCompleted(receipt),
      );

  @override
  void didUpdateWidget(CorrectionReturnForm oldWidget) {
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
    final CorrectionReturnController form = _controller;
    final String? folio = widget.sale.folio;
    final String? message = form.message;
    final Widget primary = Center(
      key: const ValueKey<String>('return-form'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        // Not a lazy ListView: the form is short and every field must stay
        // built so its state and focus survive scrolling.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey<String>('return-back'),
                  onPressed: form.isSubmitting ? null : widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver a la venta'),
                ),
              ),
              Text('Devolución', style: theme.textTheme.headlineSmall),
              Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
              const Divider(height: 32),
              Text('Productos', style: theme.textTheme.titleMedium),
              for (final ReturnLineEntry entry in form.lines)
                _LineEditor(
                  key: ValueKey<String>('return-line-${entry.line.lineIndex}'),
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
                        'return-reason-${reason.wireValue}',
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
                key: const ValueKey<String>('return-note'),
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
              _PreviewSection(controller: form, name: _name, sale: widget.sale),
              if (message != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const ValueKey<String>('return-message'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (form.isLocked)
                FilledButton(
                  key: const ValueKey<String>('return-retry'),
                  onPressed: form.isSubmitting ? null : form.retrySubmit,
                  child: _label(form.isSubmitting, 'Reintentar'),
                )
              else
                FilledButton(
                  key: const ValueKey<String>('return-confirm'),
                  onPressed: form.canConfirm ? form.confirm : null,
                  child: _label(form.isSubmitting, 'Confirmar devolución'),
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

class _LineEditor extends StatelessWidget {
  const _LineEditor({
    required this.entry,
    required this.name,
    required this.controller,
    super.key,
  });

  final ReturnLineEntry entry;
  final String name;
  final CorrectionReturnController controller;

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
                    key: ValueKey<String>('return-line-select-$index'),
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
                  key: ValueKey<String>('return-line-quantity-$index'),
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
                          'return-line-condition-$index-${condition.wireValue}',
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

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({
    required this.controller,
    required this.name,
    required this.sale,
  });

  final CorrectionReturnController controller;
  final String Function(String productId) name;
  final CorrectableSale sale;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SaleReturnPreview? preview = controller.preview;
    final List<Widget> children = <Widget>[
      Text('Reembolso', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
    ];
    switch (controller.previewStatus) {
      case ReturnPreviewStatus.incomplete:
        children.add(
          Text(
            controller.isLocked
                ? 'El reembolso se confirmará al reintentar.'
                : 'Elige productos, cantidades y motivo para calcular el '
                      'reembolso.',
          ),
        );
      case ReturnPreviewStatus.loading:
        children.add(const Text('Calculando reembolso…'));
      case ReturnPreviewStatus.failed:
        children.addAll(<Widget>[
          Text(controller.previewMessage ?? returnPreviewFailedMessage),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey<String>('return-preview-retry'),
              onPressed: controller.canEdit ? controller.retryPreview : null,
              child: const Text('Reintentar'),
            ),
          ),
        ]);
      case ReturnPreviewStatus.ready:
        if (preview != null) {
          children.addAll(<Widget>[
            for (final CorrectionRefundLine line in preview.lines)
              Padding(
                key: ValueKey<String>('return-preview-line-${line.lineIndex}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${name(line.productId)} · ${line.quantityDecimal} '
                        '${sale.lines[line.lineIndex].quantitySpec.unit} · '
                        '${returnConditionLabel(line.condition)}',
                      ),
                    ),
                    Text(formatMoney(line.totalCentavos)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (preview.invoiced)
              Text(
                'IVA reembolsado: '
                '${formatMoney(preview.additionalIvaCentavos)}',
              ),
            Text(
              'Total a reembolsar: ${formatMoney(preview.totalCentavos)}',
              style: theme.textTheme.titleSmall,
            ),
            Text('Se reembolsa por: ${salePaymentLabel(preview.refundMethod)}'),
          ]);
        }
    }
    return Column(
      key: const ValueKey<String>('return-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
