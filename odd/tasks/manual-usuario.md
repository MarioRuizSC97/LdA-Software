# Manual de usuario (v1.0)

Manual en español de toda la aplicación para el cliente, entregado como Markdown en `docs/manual/`
y un PDF generado desde ese Markdown. Se escribe después de cerrar las revisiones de la v1.0.

## Specs

- S1. Pedido registrado (sesión del 2026-10-27, no es cita textual): manual en español de toda la
  aplicación, en Markdown dentro de `docs/`, más un PDF generado desde ese Markdown.

## Decisions

- D1. Audiencia: usuario final (administrador, vendedor y capturista), no desarrollador. Sin jerga
  técnica, sin nombres de archivos, sin identificadores internos crudos.
- D2. Cada paso describe una acción y su resultado observable ("verás…"), nunca un estado interno.
  Cuando algo no está disponible, el manual lo dice con honestidad en lugar de omitirlo.
- D3. Toda etiqueta, mensaje y flujo citado debe existir en el código o en las pruebas; nada se
  inventa. Si una pantalla no se pudo verificar, se indica como pendiente de verificación visual.
- D4. Un archivo por área, con encabezados de acción, pasos numerados y notas cortas. Índice único
  en `docs/manual/README.md`.
- D5. El PDF se genera desde el Markdown con la herramienta disponible en la máquina y se verifica
  abriendo el resultado; si no hay herramienta, se documenta como pendiente.

## Tasks

- M1 · outline, tono y terminología compartida · inline · sin commit propio
- M2 · acceso, catálogo y búsqueda, ficha de producto, crear producto · worker A · commit propio
- M3 · punto de venta (carrito, cobro, recibo) y correcciones · worker B · commit propio
- M4 · precios/IVA, entradas de inventario, traslados, avisos, movimientos, PIN de costo, tema y navegación · worker C · commit propio
- M5 · índice, PDF y verificación visual del PDF · inline · commit propio
- M6 · revisión cruzada de terminología y enlaces · inline · sin commit propio

## Log

- L1 (2026-10-27, usuario, registrado en el resumen de sesión): pidió el manual en español de toda la
  aplicación, en Markdown dentro de `docs/` y con su PDF, para después de las revisiones.
- L2 (2026-10-28, parent): revisiones cerradas; se retoma el manual. Tres redactores en paralelo con
  superficies disjuntas bajo `docs/manual/`, prohibido inventar etiquetas: cada texto citado debe
  existir en `lib/` o en `test/`.
- L3 (2026-10-28, parent): el aviso de traslado no muestra la sucursal de origen (D5 diferido,
  Engram `odd/backlog/d5-origen-en-avisos`). El manual describe el aviso como es hoy y no promete esa
  etiqueta.
- L4 (2026-10-28, parent): los tres redactores entregaron 11 capítulos más el índice; cada uno citó `path:line` para las etiquetas y mensajes usados. Verificación del parent: sin voseo, sin rutas ni identificadores internos, los 11 enlaces del índice resuelven, y una muestra de etiquetas se comprobó contra `lib/`/`test/`. Corrección de revisión cruzada: dos frases decían «opción de factura» y la app muestra «Con factura»/«Sin factura»; quedaron alineadas. PDF generado y verificado: 23 páginas, portada y contenido interior revisados con capturas; el capítulo 09 declara que el aviso no nombra la sucursal de origen.
- L5 (2026-10-28, parent): entregables en `docs/manual/`: `README.md` (índice), once capítulos en Markdown y `manual-lda-inventory.pdf`. Para regenerar el PDF, `docs/manual/build-pdf.sh` arma el HTML sin dependencias y lo imprime con Brave o Chrome en modo headless; `LDA_MANUAL_HTML` conserva el HTML intermedio para inspección. Verificación visual de la aplicación en una sesión real queda pendiente y así se indica en el manual.
