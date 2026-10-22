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

/// The summed quantity with its unit when every line shares a unit and
/// precision; null for mixed-unit carts, whose quantities never add up.
String? _summedUniformQuantity(SaleCart cart) {
  if (cart.lines.isEmpty) return null;
  final SaleCartLine first = cart.lines.first;
  final bool uniform = cart.lines.every(
    (SaleCartLine line) =>
        line.quantitySpec.unit == first.quantitySpec.unit &&
        line.quantitySpec.precision == first.quantitySpec.precision,
  );
  if (!uniform) return null;
  int totalScaled = 0;
  for (final SaleCartLine line in cart.lines) {
    totalScaled += line.quantityScaled;
  }
  return '${formatScaledQuantity(totalScaled, first.quantitySpec.precision)} '
      '${first.quantitySpec.unit}';
}

/// Per-card "Agregar" action, or the inline quantity entry for the product
/// being added or edited. Once the product is in the cart the card shows the
/// same stepper as the cart line (S11), bound to the same controller so card
/// and cart stay in sync.
class SaleAddControl extends StatefulWidget {
  const SaleAddControl({
    required this.controller,
    required this.product,
    super.key,
  });

  final SaleCartController controller;
  final CatalogProduct product;

  @override
  State<SaleAddControl> createState() => _SaleAddControlState();
}

class _SaleAddControlState extends State<SaleAddControl> {
  int? _previousQuantity;

  SaleCartController get controller => widget.controller;
  CatalogProduct get product => widget.product;

  @override
  void didUpdateWidget(SaleAddControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller ||
        oldWidget.product.internalCode != product.internalCode) {
      _previousQuantity = null;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, _) {
      final String productId = product.internalCode;
      final bool editing = controller.editingProductId == productId;
      final SaleCartLine? line = controller.lineFor(productId);
      final int? previousQuantity = _previousQuantity;
      if (!editing) _previousQuantity = line?.quantityScaled;
      // The state decides which control shows; the swap below animates the
      // change without ever animating a quantity entry (S6).
      final Widget control;
      // Reserve the same painted footprint for both card actions. Grow with
      // text scaling so the tonal label can wrap without clipping; narrow
      // cards still constrain the width and the stepper scales down to fit.
      final Size actionSize = Size(
        176,
        MediaQuery.textScalerOf(context).scale(48).clamp(48, double.infinity),
      );
      if (editing) {
        control = SaleQuantityEntry(
          controller: controller,
          productId: productId,
          name: product.name,
          quantitySpec: product.quantitySpec,
        );
      } else if (line != null) {
        control = SaleLineStepper(
          controller: controller,
          line: line,
          previousQuantityScaled: previousQuantity,
          actionSize: actionSize,
        );
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
          style: FilledButton.styleFrom(fixedSize: actionSize),
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

/// Presentation-only slide/fade entrance between sale control states:
/// 'Agregar' ↔ stepper ↔ quantity entry, and directional quantity changes.
/// No motion on initial load; only a changed entry commit animates a newly
/// mounted number. System reduced motion skips every animation.
/// Outgoing controls stop receiving
/// pointers during the fade, so a fast second tap can never act on a stale
/// button or duplicate an action.
class _ControlSwap extends StatefulWidget {
  const _ControlSwap({
    required this.stateKey,
    required this.child,
    this.enabled = true,
    this.value,
    this.previousValue,
  });

  final Key stateKey;
  final Widget child;
  final int? value;
  final int? previousValue;

  /// Set to false to force an instant swap (quantity entry involvement).
  final bool enabled;

  @override
  State<_ControlSwap> createState() => _ControlSwapState();
}

class _ControlSwapState extends State<_ControlSwap>
    with SingleTickerProviderStateMixin {
  static const Duration _fadeDuration = Duration(milliseconds: 150);
  late final AnimationController _initialEntrance = AnimationController(
    vsync: this,
    value: 1,
  );
  Animation<double>? _firstAnimation;
  late double _direction =
      widget.value != null &&
          widget.previousValue != null &&
          widget.value! < widget.previousValue!
      ? -1
      : 1;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    _initialEntrance.duration = reducedMotion ? Duration.zero : _fadeDuration;
    if (!_initialized) {
      _initialized = true;
      // An entry replaces the stepper, so its newly mounted number needs
      // its own entrance only when the committed quantity actually changed.
      if (widget.value != null &&
          widget.previousValue != null &&
          widget.value != widget.previousValue &&
          !reducedMotion) {
        _initialEntrance.forward(from: 0);
      }
    }
    if (reducedMotion) _initialEntrance.value = 1;
  }

  @override
  void didUpdateWidget(_ControlSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != null &&
        oldWidget.value != null &&
        widget.value != oldWidget.value) {
      _direction = widget.value! > oldWidget.value! ? 1 : -1;
    }
  }

  @override
  void dispose() {
    _initialEntrance.dispose();
    super.dispose();
  }

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
        final double direction = _direction;
        _firstAnimation ??= animation;
        final Animation<double> entrance = identical(animation, _firstAnimation)
            ? _initialEntrance.drive(CurveTween(curve: Curves.easeOut))
            : animation;
        // Reverse means the child is the outgoing control: silence it for
        // pointers, focus and assistive technology while it fades.
        return AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[animation, entrance]),
          builder: (BuildContext context, Widget? built) {
            final bool outgoing = animation.status == AnimationStatus.reverse;
            final Animation<double> opacity = outgoing ? animation : entrance;
            // Controls settle upwards; numbers settle upwards on increase
            // and downwards on decrease. Outgoing children only fade away.
            final Animation<Offset> position = outgoing || reducedMotion
                ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
                : Tween<Offset>(
                    begin: Offset(
                      0,
                      direction * (widget.value == null ? .2 : .5),
                    ),
                    end: Offset.zero,
                  ).animate(entrance);
            return IgnorePointer(
              ignoring: outgoing,
              child: ExcludeFocus(
                excluding: outgoing,
                child: ExcludeSemantics(
                  excluding: outgoing,
                  child: FadeTransition(
                    opacity: opacity,
                    child: SlideTransition(position: position, child: built),
                  ),
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
    this.previousQuantityScaled,
    this.actionSize,
    super.key,
  });

  final SaleCartController controller;
  final SaleCartLine line;

  /// Shared card-action footprint; cart lines retain their natural sizing.
  final Size? actionSize;

  /// Last displayed quantity, retained by the host while an entry is open.
  final int? previousQuantityScaled;

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
    // Only product cards need the compact fallback. Cart lines have the full
    // panel width and must retain full-sized quantity targets on mobile too.
    final bool compact =
        actionSize != null && MediaQuery.sizeOf(context).width < 600;
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
                  value: line.quantityScaled,
                  previousValue: previousQuantityScaled,
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
        if (actionSize != null)
          SizedBox.fromSize(size: actionSize, child: pill)
        else
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

/// Floating cart control with a fixed height and the authoritative summary.
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
        // When every line shares a unit and precision, the bar shows the
        // summed quantity (S24): one product added twice reads 2, and it does
        // so even when the quantity equals the line count. Mixed units never
        // add up, so those carts keep counting product lines.
        final String amount =
            _summedUniformQuantity(cart) ??
            '$count ${count == 1 ? 'producto' : 'productos'}';
        label = 'Carrito · $amount · ${_totalLabel(controller)}';
      }
      final Duration duration = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250);
      return FilledButton.tonal(
        key: const ValueKey<String>('sale-cart-button'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          // Desktop compact density must not shrink the painted circle below
          // its 56px height. Keep these surface constraints density-independent.
          visualDensity: VisualDensity.standard,
          minimumSize: const Size(56, 56),
          maximumSize: Size(MediaQuery.sizeOf(context).width * .9, 56),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const StadiumBorder(),
        ),
        child: Semantics(
          label: 'Abrir carrito. $label',
          excludeSemantics: true,
          child: AnimatedSize(
            // Recreate the zero-duration render object to avoid restarting
            // its animation during layout when reduced motion is enabled.
            key: duration == Duration.zero ? ValueKey<String>(label) : null,
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.shopping_cart_outlined),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: duration,
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        // Outgoing text must not hold the pill open.
                        layoutBuilder: (child, previous) => Stack(
                          alignment: Alignment.centerLeft,
                          children: <Widget>[
                            for (final outgoing in previous)
                              Positioned.fill(child: outgoing),
                            ?child,
                          ],
                        ),
                        child: count == 0
                            ? const SizedBox.shrink(key: ValueKey('empty'))
                            : Padding(
                                key: ValueKey<String>(label),
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
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
        return Align(
          alignment: Alignment.topCenter,
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
                      FilledButton.tonalIcon(
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
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

class _SaleLineTile extends StatefulWidget {
  const _SaleLineTile({required this.controller, required this.line});

  final SaleCartController controller;
  final SaleCartLine line;

  @override
  State<_SaleLineTile> createState() => _SaleLineTileState();
}

class _SaleLineTileState extends State<_SaleLineTile> {
  int? _previousQuantity;
  String? _previousProductId;
  SaleCartController get controller => widget.controller;
  SaleCartLine get line => widget.line;

  @override
  Widget build(BuildContext context) {
    if (_previousProductId != line.productId) _previousQuantity = null;
    _previousProductId = line.productId;
    final int? previousQuantity = _previousQuantity;
    if (controller.editingProductId != line.productId) {
      _previousQuantity = line.quantityScaled;
    }
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
              SaleLineStepper(
                controller: controller,
                line: line,
                previousQuantityScaled: previousQuantity,
              ),
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
