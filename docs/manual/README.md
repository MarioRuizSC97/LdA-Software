# Manual de usuario — LDA Inventory

Guía para usar la aplicación de inventario de la tienda: catálogo, ventas, correcciones,
existencias, traslados, avisos y movimientos. Está escrita para quien opera la aplicación, no
para quien la programa: no necesitas conocimientos técnicos para seguirla.

## Por dónde empezar

1. Si es tu primera vez, lee **Acceder** y después **Catálogo**.
2. Si vendes, sigue con **Ventas**, **Correcciones** y **Avisos de traslados**.
3. Si administras, añade **Precios, IVA e inventario**, **Traslados** y **Movimientos**.

## Capítulos

| Capítulo | Qué encontrarás |
| --- | --- |
| [Acceder](01-acceso.md) | Iniciar sesión, mensajes de rechazo y cierre de sesión. |
| [Catálogo](02-catalogo.md) | Ver productos, buscar por nombre o código y escanear un QR. |
| [Ficha de producto](03-ficha-producto.md) | Detalles, existencias por sucursal y costo protegido con PIN. |
| [Crear producto](04-crear-producto.md) | Alta de productos, validaciones y reintento de una solicitud incierta. |
| [Ventas](05-ventas.md) | Carrito, cantidades, cobro y comprobante. |
| [Correcciones](06-correcciones.md) | Devoluciones, reemplazos y cambios sobre una venta. |
| [Precios, IVA e inventario](07-precios-e-inventario.md) | Editar precio e IVA y registrar entradas de inventario. |
| [Traslados](08-traslados.md) | Enviar productos entre sucursales y revisar la advertencia de existencias. |
| [Avisos de traslados](09-avisos.md) | Bandeja de traslados recibidos y marcado de avisos revisados. |
| [Movimientos](10-movimientos.md) | Historial, filtro por sucursal y nombres de vendedor. |
| [Privacidad, tema y navegación](11-privacidad-y-tema.md) | PIN de costo, cortina de privacidad, tema claro u oscuro y cómo moverse. |

## Cómo está escrito este manual

- Cada capítulo tiene la misma forma: qué puedes hacer, paso a paso, notas y qué hacer si algo falla.
- Las etiquetas entre **negritas** son textos que verás tal cual en pantalla.
- Cuando algo todavía no está disponible, el manual lo dice en lugar de omitirlo.
- Ninguna pantalla se ha verificado visualmente en la aplicación desde una sesión real: los textos se
  contrastaron con el código y con las pruebas automáticas. Si algo no coincide con lo que ves,
  repórtalo antes de dar el manual por bueno.

## Versión en PDF

`manual-lda-inventory.pdf` se genera desde estos mismos capítulos. Para regenerarlo después de
editar el Markdown:

```bash
docs/manual/build-pdf.sh
```

El script arma un solo documento en orden, aplica el estilo y lo imprime con Chrome o Brave en modo
headless. No requiere conexión.
