# Sale quantity controls

In the sale cart, each product has a quantity selector on Android, iOS, and web:

- Tap **+** to add one product unit.
- Tap **−** to subtract one product unit. Fractional quantities retain their
  decimals (for example, `1.01` becomes `0.01`).
- At one unit or less, the left button becomes a trash icon and removes the line.
- Tap the quantity to type an exact amount, then choose **Actualizar cantidad**.
  **Cancelar** keeps the previous quantity. The product's existing precision and
  positive-quantity validation still apply.
- A separate trash button can remove a multi-unit line without repeated taps.

Changes recalculate the server quote; the displayed total is never computed by
these controls. Quantity controls are disabled while a sale is being submitted
or its outcome is unresolved. The plus button is also disabled when another
whole unit would exceed the supported quantity limit.
