import 'package:flutter/material.dart';

import '../sales/sale_format.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// On-screen confirmation of a registered return. The server returns no
/// correction time, so no date or time is shown: the device clock is not the
/// server's.
class CorrectionReturnReceiptView extends StatelessWidget {
  const CorrectionReturnReceiptView({
    required this.receipt,
    required this.sale,
    required this.productNames,
    required this.onBackToSale,
    required this.onNewSearch,
    super.key,
  });

  final SaleReturnReceipt receipt;

  /// The sale the return was made against, for its folio and units.
  final CorrectableSale sale;
  final Map<String, String> productNames;
  final VoidCallback onBackToSale;
  final VoidCallback onNewSearch;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? folio = sale.folio;
    return Center(
      key: const ValueKey<String>('return-receipt'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            Text('Devolución registrada', style: theme.textTheme.headlineSmall),
            if (receipt.replayed)
              Text(
                'Devolución repetida (ya registrada)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const SizedBox(height: 8),
            Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
            Text('Motivo: ${correctionReasonLabel(receipt.reason)}'),
            const Divider(height: 32),
            for (final CorrectionRefundLine line in receipt.lines)
              MergeSemantics(
                key: ValueKey<String>('return-receipt-line-${line.lineIndex}'),
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
                      Text('Estado: ${returnConditionLabel(line.condition)}'),
                      Text('Reembolso: ${formatMoney(line.totalCentavos)}'),
                    ],
                  ),
                ),
              ),
            const Divider(height: 32),
            if (receipt.invoiced)
              Text(
                'IVA reembolsado: '
                '${formatMoney(receipt.additionalIvaCentavos)}',
              ),
            Text(
              'Total reembolsado: ${formatMoney(receipt.totalCentavos)}',
              style: theme.textTheme.titleMedium,
            ),
            Text('Se reembolsa por: ${salePaymentLabel(receipt.refundMethod)}'),
            if (receipt.invoiced) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'Venta con factura: el administrador emitirá la nota de '
                'crédito',
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  key: const ValueKey<String>('return-receipt-back'),
                  onPressed: onBackToSale,
                  child: const Text('Volver a la venta'),
                ),
                OutlinedButton(
                  key: const ValueKey<String>('return-receipt-new-search'),
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
