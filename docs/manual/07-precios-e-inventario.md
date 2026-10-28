# Actualizar precios y registrar inventario

Aquí puedes ajustar el precio y el IVA de un producto y registrar las cantidades que ingresan a una sucursal. Estas acciones están disponibles para el administrador.

## Paso a paso

### Cambiar el precio y el IVA

1. Abre la ficha del producto y pulsa **Editar precio / IVA**. Verás el formulario del mismo nombre con los datos del producto.
2. Escribe el **Precio de lista (MXN)**, sin signo negativo y con un máximo de dos decimales; usa punto decimal. Verás el importe en el campo.
3. En **Modo de precio**, selecciona **IVA incluido** o **IVA adicional en factura**. Verás la opción elegida.
4. En **Tratamiento de IVA**, selecciona **Gravado**, **Tasa 0%** o **Exento**. Con Gravado puedes editar la **Tasa de IVA (%)**, mayor que cero y hasta 100; con Tasa 0% verás cero sin poder editarlo; con Exento verás **Tasa de IVA: No requerida**.
5. Pulsa **Guardar precio / IVA**. Si se confirma el cambio, verás **Precio guardado** y se actualizará el catálogo.

### Registrar una entrada

1. Abre la ficha del producto y pulsa **Registrar entrada de inventario**. Verás la solicitud del PIN; créalo o introdúcelo y pulsa **Continuar** para ver el formulario de entrada.
2. Selecciona **Sucursal** y escribe la cantidad en el campo **Cantidad**, que incluye la unidad del producto. Verás la sucursal y la cantidad elegidas; respeta los decimales indicados y usa una cantidad mayor que cero.
3. Escribe el **Costo unitario (MXN)** con punto decimal y un máximo de dos decimales. Con los datos válidos completos verás **Total de la línea (truncado)**: el importe se corta a centavos, sin redondear hacia arriba.
4. Pulsa **Registrar entrada**. Verás **Confirmar entrada de inventario**, con el producto, la sucursal, la cantidad, el costo unitario y el total.
5. Revisa el resumen. Pulsa **Corregir** para regresar conservando lo escrito, o **Confirmar** para enviarlo. Si se registra, verás **Entrada registrada.** y se actualizará el catálogo.

## Notas

- Cambiar el precio no registra una entrada de inventario: son acciones separadas.
- En pantallas amplias puedes consultar el precio actual y la vista previa; al registrar entradas también puedes consultar las existencias por sucursal y el último costo unitario.
- La revisión visual de estas pantallas en la aplicación está pendiente; las instrucciones se contrastaron con las pantallas y las pruebas disponibles.

## Si algo no funciona

- **El precio de lista es obligatorio.**: completa el importe antes de guardar. Revisa también las selecciones de modo y tratamiento de IVA.
- **La sucursal es obligatoria.**, **La cantidad es obligatoria.** o **El costo unitario es obligatorio.**: completa los campos señalados antes de registrar la entrada.
- **La cantidad debe ser mayor que cero.**: corrige la cantidad; no uses cero ni excedas los decimales permitidos para el producto.
- **Se rechazó la entrada de inventario.**: revisa los datos antes de volver a intentarlo; no se muestra una confirmación de registro.
- **El resultado es incierto. Reintenta la misma solicitud antes de editar.**: pulsa **Reintentar misma solicitud**. Los datos quedan sin posibilidad de edición mientras se aclara el resultado; en las entradas volverás a revisar la confirmación antes de enviar.
