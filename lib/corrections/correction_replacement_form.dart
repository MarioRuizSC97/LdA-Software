import 'package:flutter/material.dart';

import '../app/panel_layout.dart';
import '../app/primary_action_style.dart';
import 'correction_context.dart';
import 'correction_draft.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_replacement_controller.dart';
import 'correction_sale.dart';
import 'sale_corrections.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Seller factory-defect replacement form for one looked-up sale: per-line
/// quantity up to the remaining returnable quantity, the fixed reason, an
/// optional note, no charge, confirmation and the uncertain-retry lock.
class CorrectionReplacementForm extends StatefulWidget {
  const CorrectionReplacementForm({
    required this.sale,
    required this.corrections,
    required this.productNames,
    required this.onBack,
    required this.onCompleted,
    super.key,
  });

  final CorrectableSale sale;
  final SaleCorrections corrections;

  /// Catalog product names by product ID; unknown IDs are shown verbatim.
  final Map<String, String> productNames;
  final VoidCallback onBack;
  final ValueChanged<SaleReplacementReceipt> onCompleted;

  @override
  State<CorrectionReplacementForm> createState() =>
      _CorrectionReplacementFormState();
}

class _CorrectionReplacementFormState extends State<CorrectionReplacementForm> {
  late final CorrectionReplacementController _controller =
      CorrectionReplacementController(
        sale: widget.sale,
        corrections: widget.corrections,
        onCompleted: (SaleReplacementReceipt receipt) =>
            widget.onCompleted(receipt),
      );

  @override
  void didUpdateWidget(CorrectionReplacementForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.corrections = widget.corrections;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (BuildContext context, _) => _buildForm(context),
  );

  Widget _buildForm(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectionReplacementController form = _controller;
    final String? folio = widget.sale.folio;
    final String? message = form.message;
    final Widget primary = Center(
      key: const ValueKey<String>('replacement-form'),
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
                  key: const ValueKey<String>('replacement-back'),
                  onPressed: form.isSubmitting ? null : widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver a la venta'),
                ),
              ),
              Text(
                'Reemplazo por defecto de fábrica',
                style: theme.textTheme.headlineSmall,
              ),
              Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
              const SizedBox(height: 8),
              Text(
                'Motivo: '
                '${correctionReasonLabel(CorrectionReason.factoryDefect)}',
              ),
              Text(
                'Sin costo para el cliente',
                style: theme.textTheme.titleSmall,
              ),
              const Divider(height: 32),
              Text('Productos', style: theme.textTheme.titleMedium),
              for (final ReplacementLineEntry entry in form.lines)
                _LineEditor(
                  key: ValueKey<String>(
                    'replacement-line-${entry.line.lineIndex}',
                  ),
                  entry: entry,
                  name:
                      widget.productNames[entry.line.productId] ??
                      entry.line.productId,
                  controller: form,
                ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey<String>('replacement-note'),
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
              if (message != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const ValueKey<String>('replacement-message'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (form.isLocked)
                FilledButton(
                  style: primaryActionStyle(context),
                  key: const ValueKey<String>('replacement-retry'),
                  onPressed: form.isSubmitting ? null : form.retrySubmit,
                  child: _label(form.isSubmitting, 'Reintentar'),
                )
              else
                FilledButton(
                  style: primaryActionStyle(context),
                  key: const ValueKey<String>('replacement-confirm'),
                  onPressed: form.canConfirm ? form.confirm : null,
                  child: _label(form.isSubmitting, 'Confirmar reemplazo'),
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

  final ReplacementLineEntry entry;
  final String name;
  final CorrectionReplacementController controller;

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
            if (!entry.replaceable)
              Text(
                'Sin cantidad restante',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else ...<Widget>[
              Row(
                children: <Widget>[
                  Checkbox(
                    semanticLabel: 'Seleccionar $name',
                    key: ValueKey<String>('replacement-line-select-$index'),
                    value: entry.selected,
                    onChanged: editable
                        ? (bool? value) =>
                              controller.setSelected(index, value ?? false)
                        : null,
                  ),
                  const Flexible(child: Text('Reemplazar este producto')),
                ],
              ),
              if (entry.selected) ...<Widget>[
                TextField(
                  key: ValueKey<String>('replacement-line-quantity-$index'),
                  controller: entry.quantity,
                  enabled: editable,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => controller.quantityChanged(),
                  decoration: InputDecoration(
                    labelText: 'Cantidad a reemplazar',
                    errorText: entry.error,
                    errorMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Máximo: ${line.remainingDecimal} $unit',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
