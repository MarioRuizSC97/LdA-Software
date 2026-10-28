# Trasladar productos entre sucursales

Aquí puedes enviar productos de una sucursal a otra y revisar las cantidades antes de confirmar. Esta acción está disponible para el administrador.

## Paso a paso

1. Desde el catálogo, pulsa **Traslados**. Verás **Traslado entre sucursales**.
2. Selecciona **Sucursal de origen** y **Sucursal de destino**. Verás las dos sucursales elegidas; deben ser distintas.
3. Selecciona un **Producto** y escribe su **Cantidad**. Verás la unidad y los decimales admitidos; usa una cantidad positiva con punto decimal cuando corresponda.
4. Si necesitas trasladar más productos, pulsa **Agregar producto**. Verás otra línea para seleccionar un producto distinto y su cantidad. Puedes incluir hasta 50 productos; **Quitar producto** elimina una línea cuando hay más de una.
5. Pulsa **Registrar traslado**. Verás **Confirmar traslado**, con las sucursales y los productos que vas a enviar. Si las existencias cargadas no alcanzan o no hay entrada registrada, verás una advertencia; puedes continuar con el envío.
6. Pulsa **Cancelar** si necesitas regresar a revisar los datos, o **Confirmar y enviar** para registrar el traslado. Si se confirma, verás **Traslado registrado correctamente.** y el formulario quedará preparado para otro traslado.

## Notas

- La advertencia de existencias no bloquea el envío. La aplicación comprueba las existencias al ejecutar el traslado; la advertencia por sí sola no confirma ni rechaza la operación.
- En pantallas amplias puedes ver un resumen del traslado y las existencias cargadas de la sucursal de origen.
- La revisión visual de esta pantalla en la aplicación está pendiente; las instrucciones se contrastaron con la pantalla y las pruebas disponibles.

## Si algo no funciona

- **Se necesitan al menos dos sucursales para registrar un traslado.** o **No hay productos disponibles para trasladar.**: no puedes iniciar un traslado hasta que haya sucursales y productos disponibles.
- **Selecciona la sucursal de origen y la de destino.**: completa ambas selecciones.
- **La sucursal de origen y la de destino deben ser distintas.**: cambia una de las sucursales.
- **La cantidad debe ser un número positivo escrito con punto decimal.**: corrige la cantidad y respeta los decimales del producto.
- **No se pudo confirmar el resultado. Reintenta el mismo envío antes de editar.**: pulsa **Reintentar mismo envío**. Verás los datos conservados sin poder modificarlos; se vuelve a enviar la misma operación.
- **El traslado ya estaba registrado; el servidor devolvió el recibo original.**: la aplicación reconoce el registro anterior; no significa que se haya creado otro traslado.
- **Tu sesión expiró. Inicia sesión para continuar.**: vuelve a iniciar sesión antes de continuar.
