import 'package:flutter/material.dart';

import '../app/primary_action_style.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// On-screen confirmation of a registered factory-defect replacement. The
/// server returns no correction time, so none is shown.
class CorrectionReplacementReceiptView extends StatelessWidget {
  const CorrectionReplacementReceiptView({
    required this.receipt,
    required this.sale,
    required this.productNames,
    required this.onBackToSale,
    required this.onNewSearch,
    super.key,
  });

  final SaleReplacementReceipt receipt;

  /// The sale the replacement was made against, for its folio and units.
  final CorrectableSale sale;
  final Map<String, String> productNames;
  final VoidCallback onBackToSale;
  final VoidCallback onNewSearch;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? folio = sale.folio;
    return Center(
      key: const ValueKey<String>('replacement-receipt'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            Text('Reemplazo registrado', style: theme.textTheme.headlineSmall),
            if (receipt.replayed)
              Text(
                'Reemplazo repetido (ya registrado)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const SizedBox(height: 8),
            Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
            Text('Motivo: ${correctionReasonLabel(receipt.reason)}'),
            const Divider(height: 32),
            for (final CorrectionReplacementLine line in receipt.lines)
              MergeSemantics(
                key: ValueKey<String>(
                  'replacement-receipt-line-${line.lineIndex}',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        productNames[line.productId] ?? line.productId,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'Cantidad: ${line.quantityDecimal} '
                        '${sale.lines[line.lineIndex].quantitySpec.unit}',
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 32),
            Text('Sin costo', style: theme.textTheme.titleMedium),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  style: primaryActionStyle(context),
                  key: const ValueKey<String>('replacement-receipt-back'),
                  onPressed: onBackToSale,
                  child: const Text('Volver a la venta'),
                ),
                OutlinedButton(
                  key: const ValueKey<String>('replacement-receipt-new-search'),
                  onPressed: onNewSearch,
                  child: const Text('Nueva búsqueda'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
