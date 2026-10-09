import 'package:flutter/material.dart';

import '../sales/sale_format.dart';
import 'correction_sale.dart';

// User-visible text is neutral, professional Spanish; identifiers stay in
// English. The correction forms arrive in CORR-07C/D, so their actions are
// shown disabled here.

/// One looked-up sale: folio, date, total, payment, invoice flag, the
/// client-derived correction window (display only; the server decides), and
/// per line the sold, returned and remaining quantities.
class CorrectionSaleDetail extends StatelessWidget {
  const CorrectionSaleDetail({
    required this.sale,
    required this.productNames,
    required this.onBack,
    super.key,
  });

  final CorrectableSale sale;

  /// Catalog product names by product ID; unknown IDs are shown verbatim.
  final Map<String, String> productNames;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? folio = sale.folio;
    return Center(
      key: const ValueKey<String>('correction-detail'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey<String>('correction-detail-back'),
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Volver a la búsqueda'),
              ),
            ),
            Text(
              folio == null ? 'Venta sin folio' : 'Venta $folio',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text('Fecha: ${formatSaleDateTime(sale.createdAt.toLocal())}'),
            Text('Total: ${formatMoney(sale.totalCentavos)}'),
            Text('Método de pago: ${salePaymentLabel(sale.paymentMethod)}'),
            Text(
              sale.invoiced ? 'Factura: Con factura' : 'Factura: Sin factura',
            ),
            Text(
              'Corregible hasta '
              '${formatSaleDateTime(sale.correctionWindowEndsAt.toLocal())}',
            ),
            const Divider(height: 32),
            Text('Productos', style: theme.textTheme.titleMedium),
            for (final CorrectableSaleLine line in sale.lines)
              _CorrectionLine(
                key: ValueKey<String>('correction-line-${line.lineIndex}'),
                line: line,
                name: productNames[line.productId] ?? line.productId,
              ),
            const Divider(height: 32),
            const _PendingActions(),
          ],
        ),
      ),
    );
  }
}

class _CorrectionLine extends StatelessWidget {
  const _CorrectionLine({required this.line, required this.name, super.key});

  final CorrectableSaleLine line;
  final String name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String unit = line.quantitySpec.unit;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(name, style: theme.textTheme.titleSmall),
            Text('Vendido: ${line.soldDecimal} $unit'),
            Text('Devuelto: ${line.returnedDecimal} $unit'),
            Text('Restante: ${line.remainingDecimal} $unit'),
            if (line.remainingScaled == 0)
              Text(
                'Devuelto por completo',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingActions extends StatelessWidget {
  const _PendingActions();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton(
            key: ValueKey<String>('correction-action-return'),
            onPressed: null,
            child: Text('Devolver'),
          ),
          OutlinedButton(
            key: ValueKey<String>('correction-action-replace'),
            onPressed: null,
            child: Text('Reemplazar (defecto de fábrica)'),
          ),
          OutlinedButton(
            key: ValueKey<String>('correction-action-exchange'),
            onPressed: null,
            child: Text('Cambiar producto'),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text('Próximamente', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
