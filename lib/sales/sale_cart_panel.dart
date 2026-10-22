import 'package:flutter/material.dart';

import '../catalog/catalog_product.dart';
import 'sale_cart.dart';
import 'sale_cart_controller.dart';
import 'sale_format.dart';
import 'sale_quote.dart';

// Seller point-of-sale widgets. User-visible text is neutral, professional
// Spanish (product decision 8); identifiers stay in English.

/// The total as the seller should read it right now.
String _totalLabel(SaleCartController controller) {
  final int? total = controller.totalCentavos;
  if (total != null) return formatMoney(total);
  return controller.quoteStatus == SaleQuoteStatus.loading
      ? 'Calculando…'
      : 'Total no disponible';
}

/// Per-card "Agregar" action, or the inline quantity entry for the product
/// being added or edited. Once the product is in the cart the card shows the
/// same stepper as the cart line (S11), bound to the same controller so card
/// and cart stay in sync.
class SaleAddControl extends StatelessWidget {
  const SaleAddControl({
    required this.controller,
    required this.product,
    super.key,
  });

  final SaleCartController controller;
  final CatalogProduct product;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, _) {
      final String productId = product.internalCode;
      final bool editing = controller.editingProductId == productId;
      final SaleCartLine? line = controller.lineFor(productId);
      // The state decides which control shows; the swap below animates the
      // change without ever animating a quantity entry (S6).
      final Widget control;
      if (editing) {
        control = SaleQuantityEntry(
          controller: controller,
          productId: productId,
          name: product.name,
          quantitySpec: product.quantitySpec,
        );
      } else if (line != null) {
        control = SaleLineStepper(controller: controller, line: line);
      } else {
        // 'Agregar' adds one product unit and shows the stepper at once
        // (S13); a larger quantity is typed by tapping the stepper's
        // quantity. It is the card's primary action (S3), drawn with the
        // soft tonal fill so it does not clash with the white card (S11).
        final bool inStock = controller.fitsLoadedStock(
          productId,
          BigInt.from(10).pow(product.quantitySpec.precision).toInt(),
        );
        control = FilledButton.tonalIcon(
          key: ValueKey<String>('sale-add-$productId'),
          onPressed: controller.canEdit && inStock
              ? () => controller.saveEntry(
                  productId: productId,
                  name: product.name,
                  quantitySpec: product.quantitySpec,
                  quantity: '1',
                )
              : null,
          icon: const Icon(Icons.add_shopping_cart_outlined),
          label: Text(
            inStock ? 'Agregar' : 'Agotado',
            semanticsLabel: inStock
                ? 'Agregar ${product.name} al carrito'
                : '${product.name}: Agotado',
          ),
        );
      }
      return _ControlSwap(
        stateKey: ValueKey<String>(
          'sale-control-$productId-${editing
              ? 'entry'
              : line == null
              ? 'add'
              : 'stepper'}',
        ),
        // Opening or closing the quantity entry is never animated: the entry
        // receives focus immediately and must not fight a fade (S6).
        enabled: !editing,
        child: control,
      );
    },
  );
}

/// Presentation-only cross-fade between sale control states (T9/S6):
/// 'Agregar' ↔ stepper ↔ quantity entry. It never animates a widget's first
/// appearance (no motion on initial load), and it is skipped entirely when
/// the system reports reduced motion. Outgoing controls stop receiving
/// pointers during the fade, so a fast second tap can never act on a stale
/// button or duplicate an action.
class _ControlSwap extends StatefulWidget {
  const _ControlSwap({
    required this.stateKey,
    required this.child,
    this.enabled = true,
  });

  final Key stateKey;
  final Widget child;

  /// Set to false to force an instant swap (quantity entry involvement).
  final bool enabled;

  @override
  State<_ControlSwap> createState() => _ControlSwapState();
}

class _ControlSwapState extends State<_ControlSwap> {
  static const Duration _fadeDuration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: widget.enabled && !reducedMotion
          ? _fadeDuration
          : Duration.zero,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (Widget child, Animation<double> animation) {
        // Reverse means the child is the outgoing control: silence it for
        // pointers, focus and assistive technology while it fades.
        return AnimatedBuilder(
          animation: animation,
          builder: (BuildContext context, Widget? built) {
            final bool outgoing = animation.status == AnimationStatus.reverse;
            return IgnorePointer(
              ignoring: outgoing,
              child: ExcludeFocus(
                excluding: outgoing,
                child: ExcludeSemantics(
                  excluding: outgoing,
                  child: FadeTransition(opacity: animation, child: built),
                ),
              ),
            );
          },
          child: child,
        );
      },
      child: KeyedSubtree(key: widget.stateKey, child: widget.child),
    );
  }
}

/// Presentation-only entrance for the whole cart panel (T9/S6): a short fade
/// with a slight upward settle when the panel opens. Skipped entirely under
/// reduced motion, and never re-run while the panel stays open.
class _PanelEntrance extends StatelessWidget {
  const _PanelEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: reducedMotion ? 1 : 0, end: 1),
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      builder: (BuildContext context, double t, Widget? child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 12),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Quantity stepper shared by the cart line and the product card (S11):
/// trash at one unit / minus above, the quantity (tap to type), and plus.
/// It edits exactly the given [line] through the controller, so every
/// mounted copy shows the same cart.
class SaleLineStepper extends StatelessWidget {
  const SaleLineStepper({
    required this.controller,
    required this.line,
    super.key,
  });

  final SaleCartController controller;
  final SaleCartLine line;

  void _step(int scaled) {
    controller.saveEntry(
      productId: line.productId,
      name: line.name,
      quantitySpec: line.quantitySpec,
      quantity: formatScaledQuantity(scaled, line.quantitySpec.precision),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Step by one product unit, keeping fractional quantities exact. A
    // quantity at or below one unit is removed instead of becoming zero.
    final int unitScaled = BigInt.from(10)
        .pow(line.quantitySpec.precision)
        .toInt();
    final bool removeOnDecrease = line.quantityScaled <= unitScaled;
    final bool stockAllowsIncrease = controller.fitsLoadedStock(
      line.productId,
      line.quantityScaled + unitScaled,
    );
    final bool canIncrease =
        line.quantityScaled <= maxSafeSaleInteger - unitScaled &&
        stockAllowsIncrease;
    // The compact product card (S4) can be far narrower than a cart line —
    // below the shell's compact-bar width the card grid is at most two
    // columns — so the controls shrink there instead of overflowing. The
    // FittedBox is a final guard (it supports dry layout, unlike a
    // LayoutBuilder inside the IntrinsicHeight grid) and scales down only
    // when nothing else fits, e.g. extreme text scales.
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    final BoxConstraints? iconConstraints = compact
        ? const BoxConstraints(minWidth: 36, minHeight: 36)
        : null;
    final VisualDensity density = compact
        ? VisualDensity.compact
        : VisualDensity.standard;
    final Widget pill = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(24),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              visualDensity: density,
              constraints: iconConstraints,
              padding: compact ? EdgeInsets.zero : null,
              key: ValueKey<String>(
                removeOnDecrease
                    ? 'sale-line-remove-${line.productId}'
                    : 'sale-line-decrement-${line.productId}',
              ),
              tooltip: removeOnDecrease
                  ? 'Quitar ${line.name} del carrito'
                  : 'Disminuir cantidad de ${line.name}',
              onPressed: !controller.canEdit
                  ? null
                  : removeOnDecrease
                  ? () => controller.remove(line.productId)
                  : () => _step(line.quantityScaled - unitScaled),
              icon: Icon(
                removeOnDecrease ? Icons.delete_outline : Icons.remove,
              ),
            ),
            Tooltip(
              message: 'Editar cantidad de ${line.name}',
              child: TextButton(
                style: compact
                    ? TextButton.styleFrom(
                        visualDensity: density,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
                key: ValueKey<String>('sale-line-edit-${line.productId}'),
                onPressed: controller.canEdit
                    ? () => controller.startEntry(line.productId)
                    : null,
                child: _ControlSwap(
                  stateKey: ValueKey<String>(
                    'sale-quantity-value-${line.productId}-${line.quantity}',
                  ),
                  child: Text(
                    line.quantity,
                    semanticsLabel:
                        'Editar cantidad de ${line.name}: '
                        '${line.quantity} ${line.quantitySpec.unit}',
                  ),
                ),
              ),
            ),
            IconButton(
              visualDensity: density,
              constraints: iconConstraints,
              padding: compact ? EdgeInsets.zero : null,
              key: ValueKey<String>('sale-line-increment-${line.productId}'),
              tooltip: stockAllowsIncrease
                  ? 'Aumentar cantidad de ${line.name}'
                  : 'No hay más existencias',
              onPressed: controller.canEdit && canIncrease
                  ? () => _step(line.quantityScaled + unitScaled)
                  : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        pill,
        // Keep direct removal available for multi-unit lines too.
        if (!removeOnDecrease)
          IconButton(
            key: ValueKey<String>('sale-line-remove-${line.productId}'),
            tooltip: 'Quitar ${line.name} del carrito',
            onPressed: controller.canEdit
                ? () => controller.remove(line.productId)
                : null,
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    );
  }
}

/// Inline quantity entry validated at the product precision. Editing a
/// product already in the cart starts from its current quantity.
class SaleQuantityEntry extends StatefulWidget {
  const SaleQuantityEntry({
    required this.controller,
    required this.productId,
    required this.name,
    required this.quantitySpec,
    super.key,
  });

  final SaleCartController controller;
  final String productId;
  final String name;
  final QuantitySpec quantitySpec;

  @override
  State<SaleQuantityEntry> createState() => _SaleQuantityEntryState();
}

class _SaleQuantityEntryState extends State<SaleQuantityEntry> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.lineFor(widget.productId)?.quantity ?? '',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    widget.controller.saveEntry(
      productId: widget.productId,
      name: widget.name,
      quantitySpec: widget.quantitySpec,
      quantity: _text.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final SaleCartController controller = widget.controller;
    final int precision = widget.quantitySpec.precision;
    final bool editing = controller.lineFor(widget.productId) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: ValueKey<String>('sale-quantity-${widget.productId}'),
          controller: _text,
          autofocus: true,
          enabled: controller.canEdit,
          keyboardType: TextInputType.numberWithOptions(decimal: precision > 0),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Cantidad (${widget.quantitySpec.unit})',
            helperText: precision == 0
                ? 'Solo cantidades enteras'
                : 'Hasta $precision '
                      '${precision == 1 ? 'decimal' : 'decimales'}',
            errorText: controller.entryError,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              key: ValueKey<String>('sale-entry-save-${widget.productId}'),
              onPressed: controller.canEdit ? _save : null,
              child: Text(
                editing ? 'Actualizar cantidad' : 'Agregar al carrito',
                semanticsLabel: editing
                    ? 'Actualizar cantidad de ${widget.name}'
                    : 'Agregar ${widget.name} al carrito',
              ),
            ),
            TextButton(
              key: ValueKey<String>('sale-entry-cancel-${widget.productId}'),
              onPressed: controller.cancelEntry,
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Fixed cart button with the line count and the authoritative total.
class SaleCartButton extends StatelessWidget {
  const SaleCartButton({
    required this.controller,
    required this.onPressed,
    super.key,
  });

  final SaleCartController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, _) {
      final SaleCart cart = controller.cart;
      final int count = cart.lineCount;
      String label = 'Carrito vacío';
      if (count > 0) {
        // When every line shares a unit and precision, the bar can count
        // pieces too: one product added twice reads 2, not 1 line. Mixed
        // units never add up, so those carts keep counting product lines.
        final SaleCartLine first = cart.lines.first;
        final bool uniform = cart.lines.every(
          (SaleCartLine line) =>
              line.quantitySpec.unit == first.quantitySpec.unit &&
              line.quantitySpec.precision == first.quantitySpec.precision,
        );
        final int unitScaled = BigInt.from(10)
            .pow(first.quantitySpec.precision)
            .toInt();
        int totalScaled = 0;
        if (uniform) {
          for (final SaleCartLine line in cart.lines) {
            totalScaled += line.quantityScaled;
          }
        }
        final bool countsPieces = uniform && totalScaled != count * unitScaled;
        label = countsPieces
            ? 'Carrito · '
                  '${formatScaledQuantity(totalScaled, first.quantitySpec.precision)} '
                  '${first.quantitySpec.unit} · ${_totalLabel(controller)}'
            : 'Carrito · $count ${count == 1 ? 'producto' : 'productos'} · '
                  '${_totalLabel(controller)}';
      }
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.tonalIcon(
            key: const ValueKey<String>('sale-cart-button'),
            onPressed: onPressed,
            icon: const Icon(Icons.shopping_cart_outlined),
            label: Text(
              label,
              semanticsLabel: 'Abrir carrito. $label',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    },
  );
}

/// Cart review: lines, invoice option, payment method, totals and "Cobrar".
class SaleCartPanel extends StatelessWidget {
  const SaleCartPanel({
    required this.controller,
    required this.onClose,
    super.key,
  });

  final SaleCartController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => _PanelEntrance(
    child: ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final ThemeData theme = Theme.of(context);
        final SaleCart cart = controller.cart;
        final bool canEdit = controller.canEdit;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: <Widget>[
                      Semantics(
                        header: true,
                        child: Text(
                          'Carrito',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey<String>('sale-close-cart'),
                        onPressed: controller.isSubmitting ? null : onClose,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Seguir vendiendo'),
                      ),
                    ],
                  ),
                  if (controller.message case final String message) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          color: controller.isLocked
                              ? theme.colorScheme.error
                              : null,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (cart.isEmpty)
                    const Text(
                      'El carrito está vacío. Agrega productos desde el catálogo.',
                    )
                  else
                    for (final SaleCartLine line in cart.lines)
                      _SaleLineTile(controller: controller, line: line),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey<String>('sale-invoice-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Factura'),
                    subtitle: const Text(
                      'Calcula el IVA para una venta facturada.',
                    ),
                    value: cart.invoiceRequested,
                    onChanged: canEdit ? controller.setInvoiceRequested : null,
                  ),
                  const SizedBox(height: 8),
                  Text('Método de pago', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final SalePaymentMethod method
                          in SalePaymentMethod.values)
                        ChoiceChip(
                          key: ValueKey<String>(
                            'sale-payment-${method.wireValue}',
                          ),
                          label: Text(salePaymentLabel(method)),
                          selected: controller.paymentMethod == method,
                          onSelected: canEdit
                              ? (_) => controller.setPaymentMethod(method)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SaleTotals(controller: controller),
                  const SizedBox(height: 16),
                  _SaleActions(controller: controller),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _SaleLineTile extends StatelessWidget {
  const _SaleLineTile({required this.controller, required this.line});

  final SaleCartController controller;
  final SaleCartLine line;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SalePricedLine? priced = controller.pricedLine(line.productId);
    final String quantity =
        priced?.quantityDecimal ??
        formatScaledQuantity(line.quantityScaled, line.quantitySpec.precision);
    final String lineTotal = priced != null
        ? formatMoney(priced.totalCentavos)
        : controller.quoteStatus == SaleQuoteStatus.loading
        ? 'Calculando…'
        : '—';
    final bool editing = controller.editingProductId == line.productId;
    return Card(
      key: ValueKey<String>('sale-line-${line.productId}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              children: <Widget>[
                Text(line.name, style: theme.textTheme.titleMedium),
                Text(lineTotal, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text('$quantity ${line.quantitySpec.unit}'),
            if (controller.isUnavailable(line.productId)) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Sin existencias suficientes',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (editing)
              SaleQuantityEntry(
                controller: controller,
                productId: line.productId,
                name: line.name,
                quantitySpec: line.quantitySpec,
              )
            else
              SaleLineStepper(controller: controller, line: line),
          ],
        ),
      ),
    );
  }
}

class _SaleTotals extends StatelessWidget {
  const _SaleTotals({required this.controller});

  final SaleCartController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (controller.cart.isEmpty) return const SizedBox.shrink();
    final SaleQuote? quote = controller.quote;
    final List<Widget> rows = <Widget>[
      if (quote != null) ...<Widget>[
        _row('Subtotal', formatMoney(quote.baseCentavos)),
        if (quote.additionalIvaCentavos > 0)
          _row('IVA adicional', formatMoney(quote.additionalIvaCentavos)),
      ],
      if (controller.totalCentavos != null || controller.isLocked)
        _row(
          'Total',
          _totalLabel(controller),
          style: theme.textTheme.titleLarge,
        )
      else
        switch (controller.quoteStatus) {
          SaleQuoteStatus.loading => _row(
            'Total',
            'Calculando…',
            style: theme.textTheme.titleLarge,
          ),
          SaleQuoteStatus.rejected => Text(
            'No se pudo calcular el total: ${controller.quoteMessage}',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          _ => Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: <Widget>[
              Text(
                'No se pudo calcular el total',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              TextButton(
                key: const ValueKey<String>('sale-retry-quote'),
                onPressed: controller.canEdit ? controller.retryQuote : null,
                child: const Text(
                  'Reintentar',
                  semanticsLabel: 'Reintentar el cálculo del total',
                ),
              ),
            ],
          ),
        },
      if (quote != null && !quote.allAvailable)
        Text(
          'Hay productos sin existencias suficientes. Ajusta o quita esas '
          'líneas para cobrar.',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final Widget row in rows) ...<Widget>[
            row,
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, {TextStyle? style}) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    spacing: 12,
    children: <Widget>[
      Text(label, style: style),
      Text(value, style: style),
    ],
  );
}

class _SaleActions extends StatelessWidget {
  const _SaleActions({required this.controller});

  final SaleCartController controller;

  @override
  Widget build(BuildContext context) {
    final bool submitting = controller.isSubmitting;
    final bool locked = controller.isLocked;
    const Widget progress = SizedBox.square(
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    final int? total = controller.totalCentavos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (locked) ...<Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('sale-retry-submit'),
            onPressed: submitting ? null : controller.retrySubmit,
            icon: submitting ? progress : const Icon(Icons.refresh),
            label: const Text(
              'Reintentar',
              semanticsLabel: 'Reintentar la misma venta',
            ),
          ),
          const SizedBox(height: 8),
        ],
        FilledButton(
          key: const ValueKey<String>('sale-charge'),
          onPressed: controller.canCharge ? controller.charge : null,
          child: submitting && !locked
              ? progress
              : Text(
                  'Cobrar',
                  semanticsLabel: total == null
                      ? 'Cobrar'
                      : 'Cobrar ${formatMoney(total)}',
                ),
        ),
      ],
    );
  }
}
