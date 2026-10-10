import 'package:flutter/material.dart';

import '../sales/sale_format.dart';
import '../sales/sale_quote.dart';
import 'correction_draft.dart';
import 'correction_labels.dart';
import 'correction_receipt.dart';
import 'correction_sale.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// On-screen confirmation of a registered exchange: the returned and new
/// lines, the settlement (paid or refunded, and how) and, for an invoiced
/// sale, the note for the administrator. The server returns no correction
/// time, so none is shown.
class CorrectionExchangeReceiptView extends StatelessWidget {
  const CorrectionExchangeReceiptView({
    required this.receipt,
    required this.sale,
    required this.productNames,
    required this.onBackToSale,
    required this.onNewSearch,
    super.key,
  });

  final SaleExchangeReceipt receipt;

  /// The sale the exchange was made against, for its folio and units.
  final CorrectableSale sale;
  final Map<String, String> productNames;
  final VoidCallback onBackToSale;
  final VoidCallback onNewSearch;

  String _name(String productId) => productNames[productId] ?? productId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? folio = sale.folio;
    final SaleExchangeSettlement settlement = receipt.settlement;
    return Center(
      key: const ValueKey<String>('exchange-receipt'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            Text('Cambio registrado', style: theme.textTheme.headlineSmall),
            if (receipt.replayed)
              Text(
                'Cambio repetido (ya registrado)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const SizedBox(height: 8),
            Text(folio == null ? 'Venta sin folio' : 'Venta $folio'),
            Text('Motivo: ${correctionReasonLabel(receipt.reason)}'),
            const Divider(height: 32),
            Text('Productos devueltos', style: theme.textTheme.titleMedium),
            for (final CorrectionRefundLine line in receipt.returnedLines)
              MergeSemantics(
                key: ValueKey<String>(
                  'exchange-receipt-returned-${line.lineIndex}',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _name(line.productId),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'Cantidad: ${line.quantityDecimal} '
                        '${sale.lines[line.lineIndex].quantitySpec.unit}',
                      ),
                      Text('Estado: ${returnConditionLabel(line.condition)}'),
                      Text('Valor: ${formatMoney(line.totalCentavos)}'),
                    ],
                  ),
                ),
              ),
            Text(
              'Valor devuelto: '
              '${formatMoney(receipt.returnedTotalCentavos)}',
            ),
            const Divider(height: 32),
            Text('Productos nuevos', style: theme.textTheme.titleMedium),
            for (final SalePricedLine line in receipt.newItems.lines)
              MergeSemantics(
                key: ValueKey<String>('exchange-receipt-new-${line.productId}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _name(line.productId),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text('Cantidad: ${line.quantityDecimal} ${line.unit}'),
                      Text('Importe: ${formatMoney(line.totalCentavos)}'),
                    ],
                  ),
                ),
              ),
            if (receipt.invoiced)
              Text(
                'IVA de productos nuevos: '
                '${formatMoney(receipt.newItems.additionalIvaCentavos)}',
              ),
            Text(
              'Total de productos nuevos: '
              '${formatMoney(receipt.newItems.totalCentavos)}',
            ),
            const Divider(height: 32),
            ..._settlement(theme, settlement),
            if (receipt.invoiced) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'Venta con factura: el administrador gestionará el ajuste de '
                'la factura',
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  key: const ValueKey<String>('exchange-receipt-back'),
                  onPressed: onBackToSale,
                  child: const Text('Volver a la venta'),
                ),
                OutlinedButton(
                  key: const ValueKey<String>('exchange-receipt-new-search'),
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

  List<Widget> _settlement(ThemeData theme, SaleExchangeSettlement value) {
    final SaleExchangePayment? payment = value.differencePayment;
    if (payment != null) {
      return <Widget>[
        Text(
          'El cliente pagó: ${formatMoney(payment.amountCentavos)}',
          style: theme.textTheme.titleMedium,
        ),
        Text('Método de pago: ${salePaymentLabel(payment.method)}'),
      ];
    }
    if (value.refundCentavos > 0) {
      return <Widget>[
        Text(
          'Se reembolsó: ${formatMoney(value.refundCentavos)} por '
          '${salePaymentLabel(value.refundMethod)}',
          style: theme.textTheme.titleMedium,
        ),
      ];
    }
    return <Widget>[Text('Sin diferencia', style: theme.textTheme.titleMedium)];
  }
}
