import 'package:flutter/material.dart';

import '../sales/sale_format.dart';
import 'correction_sale.dart';

// Wide-layout context column of the corrections panel. It only restates data
// the panel already holds; below the wide breakpoint it is never mounted.
// User-visible text is neutral, professional Spanish; identifiers stay in
// English.

/// Short, honest help shown while no sale is selected.
class CorrectionHelpContext extends StatelessWidget {
  const CorrectionHelpContext({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: const ValueKey<String>('corrections-context'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Cómo corregir una venta', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Busca la venta por su folio o elígela en la lista de ventas '
              'recientes. Solo se pueden corregir las ventas de los últimos '
              '$correctionWindowDays días de esta sucursal.',
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected sale at a glance: folio, date, total, payment, invoice flag,
/// correction window and, when [showLines], what remains per line.
class CorrectionSaleContext extends StatelessWidget {
  const CorrectionSaleContext({
    required this.sale,
    required this.productNames,
    this.showLines = true,
    super.key,
  });

  final CorrectableSale sale;
  final Map<String, String> productNames;
  final bool showLines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      key: const ValueKey<String>('corrections-context'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Resumen de la venta', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Folio: ${sale.folio ?? 'Sin folio'}'),
            Text('Registrada: ${formatSaleDateTime(sale.createdAt.toLocal())}'),
            Text(
              'Total vendido: ${formatMoney(sale.totalCentavos)}',
              style: theme.textTheme.titleSmall,
            ),
            Text('Pago: ${salePaymentLabel(sale.paymentMethod)}'),
            Text(sale.invoiced ? 'Con factura' : 'Sin factura'),
            Text(
              'Plazo de corrección: hasta '
              '${formatSaleDateTime(sale.correctionWindowEndsAt.toLocal())}',
            ),
            if (showLines) ...<Widget>[
              const Divider(height: 24),
              for (final CorrectableSaleLine line in sale.lines)
                Padding(
                  key: ValueKey<String>(
                    'corrections-context-line-${line.lineIndex}',
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${productNames[line.productId] ?? line.productId} · '
                    'restan ${line.remainingDecimal} de ${line.soldDecimal} '
                    '${line.quantitySpec.unit}',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
