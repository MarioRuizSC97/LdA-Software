# Devolver, reemplazar o cambiar productos de una venta

Aquí puedes localizar una venta de tu sucursal y registrar una devolución, un reemplazo por defecto de fábrica o un cambio por otros productos. Antes de confirmar una devolución o un cambio, puedes revisar el reembolso o la diferencia calculada.

## Paso a paso

### Localizar la venta

1. Con tu sesión de vendedor, abre **Correcciones**. Verás el campo **Folio**, el botón **Buscar** y **Ventas recientes (últimos 15 días)**.
2. Escribe el folio que aparece en el comprobante y toca **Buscar**, o toca una venta de la lista de ventas recientes. Verás el detalle de esa venta, con su fecha, total, método de pago y **Con factura** o **Sin factura**.
3. Revisa **Vendido**, **Devuelto** y **Restante** para cada producto, además de **Corregible hasta**, que muestra la fecha y hora límite. Verás qué cantidades quedan disponibles para corregir. Si no es la venta que buscas, toca **Volver a la búsqueda** y regresarás a la lista y al campo de búsqueda.

### Registrar una devolución

1. En el detalle de la venta, toca **Devolver**. Verás el formulario **Devolución**.
2. Marca **Devolver este producto** en cada producto que corresponda y escribe la **Cantidad a devolver** sin superar el **Máximo** indicado. Verás las opciones **En buen estado** y **Defecto de fábrica**; selecciona el estado del producto que recibes.
3. Elige un **Motivo**: **Cambio de opinión**, **Producto equivocado**, **Defecto de fábrica** u **Otro**. Si necesitas añadir información, escribe en **Nota (opcional)**. Al completar los datos válidos, verás el cálculo en **Reembolso**.
4. Espera el cálculo y revisa **Total a reembolsar** y **Se reembolsa por**. Toca **Confirmar devolución**: mientras se registra no podrás editar ni confirmar otra vez; al completarse verás **Devolución registrada**, los productos y el total reembolsado.

### Registrar un reemplazo por defecto de fábrica

1. En el detalle de la venta, toca **Reemplazar (defecto de fábrica)**. Verás **Reemplazo por defecto de fábrica**, el motivo fijo y **Sin costo para el cliente**.
2. Marca **Reemplazar este producto**, escribe la **Cantidad a reemplazar** sin superar el **Máximo** y, si lo necesitas, completa **Nota (opcional)**. Con al menos un producto seleccionado y cantidades válidas, se habilitará **Confirmar reemplazo**.
3. Toca **Confirmar reemplazo**. Los controles se desactivarán mientras se registra; al terminar verás **Reemplazo registrado**, las cantidades y **Sin costo**.

### Registrar un cambio por otros productos

1. En el detalle de la venta, toca **Cambiar producto**. Verás **Cambio de producto**, con las secciones **Productos a devolver** y **Productos nuevos**.
2. Marca **Devolver este producto**, escribe la **Cantidad a devolver** y selecciona **En buen estado** o **Defecto de fábrica**. Elige el **Motivo** y, si hace falta, completa **Nota (opcional)**. Verás tus selecciones y cantidades en el formulario.
3. En **Catálogo**, toca **Agregar** junto a cada producto nuevo y escribe su cantidad en el campo **Cantidad**, acompañado de la unidad. Verás el producto en **Productos nuevos**; puedes retirarlo con la papelera **Quitar**.
4. Espera el cálculo de **Diferencia**. Verás el valor devuelto, el total de productos nuevos y uno de estos resultados: **El cliente paga**, **Se reembolsa** o **Sin diferencia**. Si el cliente debe pagar, elige **Método de pago de la diferencia**; verás seleccionada la opción elegida. El importe se calcula, no se escribe.
5. Revisa el resultado y toca **Confirmar cambio**. Los controles se desactivarán mientras se registra, sin iniciar otro cobro si vuelves a tocar durante la espera. Al completarse verás **Cambio registrado**, los productos devueltos y nuevos y el importe pagado o reembolsado, o **Sin diferencia**.

### Revisar el comprobante y continuar

1. Revisa el comprobante de la corrección y toca **Volver a la venta**. Se volverá a consultar la venta y verás sus cantidades actualizadas.
2. Si quieres localizar otra venta, toca **Nueva búsqueda** en el comprobante. Volverás a la búsqueda con la lista de ventas recientes actualizada.

## Notas

- Las correcciones están disponibles para ventas de tu sucursal dentro del plazo de 15 días. La fecha mostrada es orientativa: al calcular o confirmar, la aplicación comprueba si la operación todavía está permitida.
- Si no queda cantidad restante en ningún producto, las tres acciones de corrección estarán desactivadas. Un producto devuelto por completo no se puede seleccionar otra vez.
- En devoluciones y cambios, el reembolso se calcula con el método de pago de la venta original. Para los productos nuevos de un cambio, el catálogo solo ofrece productos con precio.
- Para cambiar por el mismo producto, usa el reemplazo por defecto de fábrica, no el cambio por otros productos.
- La nota admite hasta 500 caracteres. Es opcional en las tres operaciones.
- Si una devolución con factura muestra **Venta con factura: el administrador emitirá la nota de crédito**, corresponde al administrador realizar esa gestión. En un cambio con factura verás **Venta con factura: el administrador gestionará el ajuste de la factura**. No son documentos emitidos desde estas pantallas.
- **Devolución repetida (ya registrada)**, **Reemplazo repetido (ya registrado)** o **Cambio repetido (ya registrado)** indican la confirmación de la misma corrección tras un reintento, no una operación adicional.
- Las pantallas se contrastaron con las vistas y sus pruebas; su verificación visual en la aplicación está pendiente.

## Si algo no funciona

- **Escribe el folio del ticket.**: completa **Folio** con el dato del comprobante. Si se indica que el formato no es válido, cópialo tal como aparece, incluidos los guiones.
- **No se encontró una venta con ese folio en esta sucursal (últimos 15 días)**: comprueba el folio, la sucursal y la fecha de la venta.
- **Hay más de una venta con ese folio. Elige la venta en la lista de ventas recientes.**: selecciona la venta por sus datos en esa lista.
- **No hay ventas recientes**: la lista está vacía. **No se pudieron cargar las ventas recientes.**: toca **Reintentar** para volver a cargarla. **No se pudo buscar la venta. Intenta de nuevo.**: vuelve a tocar **Buscar**.
- **Esta venta no se puede corregir en este momento.**: no se ha abierto una venta disponible para corregir. Si aparece **La venta ya está fuera del plazo de 15 días para correcciones.**, esa operación ya no está permitida.
- Si el campo de cantidad muestra un error, escribe un valor mayor que cero, respeta los enteros o decimales permitidos y no superes lo restante. Si aparece **La nota admite como máximo 500 caracteres.**, acorta la nota para poder confirmar.
- **No se pudo calcular el reembolso.** o **No se pudo calcular el cambio.**: toca **Reintentar** en la sección del cálculo. No podrás confirmar hasta que termine un cálculo válido; después de editar, espera el nuevo resultado.
- **Sin existencias suficientes para reemplazar**: no hay existencias suficientes para ese reemplazo. **Sin existencias suficientes para los productos nuevos.** o **Sin existencias suficientes** en el cambio: reduce la cantidad o quita el producto nuevo afectado y revisa el cálculo.
- **La cantidad supera lo que queda por devolver. Revisa las cantidades.** o **La cantidad supera lo que queda por reemplazar. Revisa las cantidades.**: vuelve a consultar la venta y ajusta las cantidades a lo restante.
- **Este producto ya está en el cambio. Edita su cantidad.**: modifica la cantidad del producto que ya agregaste. **Este producto se está devolviendo. Para el mismo producto usa el reemplazo.**: quita ese producto de los productos nuevos; para un reemplazo por defecto de fábrica, vuelve a la venta y elige esa operación.
- **El monto a pagar cambió. Revisa el nuevo cálculo y confirma de nuevo.**: revisa la diferencia actualizada antes de volver a confirmar el cambio.
- **La devolución fue rechazada. Revisa los datos e intenta de nuevo.**, **El reemplazo fue rechazado. Revisa los datos e intenta de nuevo.** o **El cambio fue rechazado. Revisa los datos e intenta de nuevo.**: revisa el formulario y corrige lo necesario. En devoluciones y cambios, espera el nuevo cálculo antes de confirmar otra vez.
- **No sabemos si la devolución se registró. Reintenta la misma devolución antes de hacer otro cambio.**, **No sabemos si el reemplazo se registró. Reintenta el mismo reemplazo antes de hacer otro cambio.** o **No sabemos si el cambio se registró. Reintenta el mismo cambio antes de hacer otro.**: los campos quedan sin posibilidad de edición. Toca **Reintentar** para resolver esa misma operación; no prepares otra para sustituirla.
- **Hay otra corrección sin confirmar. Reinténtala antes de registrar una nueva.**: resuelve primero la corrección pendiente. **Hay una corrección registrada pendiente de revisar. Abre su comprobante para continuar.**: vuelve a **Correcciones** y revisa el comprobante antes de continuar.
- **No se pudo actualizar la venta.** después de revisar un comprobante: toca **Reintentar** para consultar de nuevo las cantidades, o **Nueva búsqueda** para volver a buscar. Este aviso no pide registrar otra corrección.
- **Tu sesión cambió. Inicia sesión de nuevo para continuar.**: inicia sesión de nuevo antes de continuar.
