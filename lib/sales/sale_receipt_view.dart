import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'sale_draft.dart';
import 'sale_format.dart';
import 'sale_quote.dart';

// On-screen sale receipt (product decision 6). User-visible text is neutral,
// professional Spanish (product decision 8); identifiers stay in English.
// Ticket printing is deferred.

/// The confirmed sale: folio, QR of the full sale ID, lines, totals, payment,
/// invoice option, server time and branch, plus the secondary "Nueva venta"
/// action that acknowledges the receipt.
class SaleReceiptView extends StatelessWidget {
  const SaleReceiptView({
    required this.receipt,
    required this.onNewSale,
    this.notice,
    super.key,
  });

  final SaleReceipt receipt;
  final VoidCallback onNewSale;

  /// Why this receipt is shown now, for a sale recovered after its cart
  /// closed or one that blocked a new sale.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String dateTime = formatSaleDateTime(receipt.createdAt.toLocal());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                header: true,
                liveRegion: true,
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.check_circle_outline,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Venta registrada',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  ],
                ),
              ),
              if (notice case final String text) ...<Widget>[
                const SizedBox(height: 8),
                Text(text, key: const ValueKey<String>('sale-receipt-notice')),
              ],
              if (receipt.replayed) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Venta repetida (ya registrada)',
                  key: const ValueKey<String>('sale-receipt-replayed'),
                  style: TextStyle(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Folio', style: theme.textTheme.labelLarge),
              Semantics(
                label: 'Folio ${receipt.folio}',
                excludeSemantics: true,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    receipt.folio,
                    key: const ValueKey<String>('sale-receipt-folio'),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: SaleReceiptQr(
                  data: receipt.saleId,
                  semanticsLabel: 'Código QR de la venta ${receipt.folio}',
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              for (final SalePricedLine line in receipt.lines)
                _ReceiptLine(line: line),
              const Divider(),
              _amountRow('Subtotal', formatMoney(receipt.baseCentavos)),
              if (receipt.additionalIvaCentavos > 0)
                _amountRow(
                  'IVA adicional',
                  formatMoney(receipt.additionalIvaCentavos),
                ),
              _amountRow(
                'Total',
                formatMoney(receipt.totalCentavos),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              _detail(
                'Método de pago',
                salePaymentLabel(receipt.paymentMethod),
              ),
              _detail(
                'Factura',
                receipt.invoiceRequested ? 'Con factura' : 'Sin factura',
              ),
              _detail('Fecha y hora', dateTime),
              _detail('Sucursal', receipt.branchCode),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('sale-receipt-new'),
                onPressed: onNewSale,
                icon: const Icon(Icons.add_shopping_cart_outlined),
                label: const Text(
                  'Nueva venta',
                  semanticsLabel: 'Iniciar una nueva venta',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _amountRow(String label, String value, {TextStyle? style}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      children: <Widget>[
        Text(label, style: style),
        Text(value, style: style),
      ],
    ),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: MergeSemantics(
      child: Wrap(
        spacing: 8,
        children: <Widget>[
          Text('$label:', style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(value),
        ],
      ),
    ),
  );
}

class _ReceiptLine extends StatelessWidget {
  const _ReceiptLine({required this.line});

  final SalePricedLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              children: <Widget>[
                Text(line.name, style: theme.textTheme.titleMedium),
                Text(
                  formatMoney(line.totalCentavos),
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            Text('${line.quantityDecimal} ${line.unit}'),
          ],
        ),
      ),
    );
  }
}

/// QR of the full sale ID, for a future scanner. [data] is exactly the
/// encoded payload.
class SaleReceiptQr extends StatelessWidget {
  const SaleReceiptQr({
    required this.data,
    required this.semanticsLabel,
    super.key,
  });

  final String data;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    image: true,
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: ColoredBox(
        color: Colors.white,
        child: QrImageView(
          key: ValueKey<String>('sale-receipt-qr-$data'),
          data: data,
          version: QrVersions.auto,
          size: 168,
        ),
      ),
    ),
  );
}
