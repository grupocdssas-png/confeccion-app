# Guía corta por rol

Se amplía en cada fase. Lo disponible hoy (Fase 1) está marcado con ✅.

| Rol | Dónde trabaja | Qué puede hacer hoy |
|---|---|---|
| **Gerencia** | Panel web | ✅ Ve todos los módulos. ✅ Personal, asistencia del día, usuarios y tablets, eventos rechazados. |
| **Jefe de producción** | Panel web | ✅ Asistencia del día en vivo. ✅ Lista de personal. ✅ Aprueba fichas técnicas por Producción y ajusta la lista de operaciones. ✅ Órdenes de producción: crear (desde pedidos o directas), cambiar cantidades, prioridad y fechas, anular, registrar avance por proceso, hojas de secuencia y máquinas. Próximo: programación y balanceo. |
| **Supervisor de módulo (confección)** | Panel web / tablet | ✅ Asistencia de su gente. Próximo: balanceo y tablero de su módulo. |
| **Bodega** | Panel web / celular | ✅ Entradas de telas e insumos con etiquetas, rollos, retazos, traslados, kardex, conteos con el celular, solicitar ajustes. |
| **Costos** | Panel web | ✅ Aprueba o rechaza ajustes de inventario (con motivo). Consulta inventario y kardex. ✅ Valor minuto e indirectos. ✅ Aprueba fichas técnicas por Costos. |
| **Comercial** | Panel web | ✅ Pedidos de clientes por referencia, color y talla; ve qué está en OP y qué falta. |
| **Compras** | Panel web | ✅ Requisiciones pendientes (automáticas por faltantes de OP y manuales) → órdenes de compra → seguimiento de lo recibido. |
| **Diseño** | Panel web | ✅ Lista maestra de operaciones e importación desde SAMMU. ✅ Fichas técnicas: crea, edita versiones en borrador, envía a aprobación y aprueba por Diseño. |
| **Operario** | Tablet | ✅ Marca entrada y salida con el QR del carnet (también sin internet). Próximo (Fase 6): marcar operaciones. |
| **Satélite** | Panel web (limitado) | Próximo (Fase 6): ver sus remisiones. |
| Demás roles | Panel web | Ven en el menú sus módulos; se activan en la fase indicada (F2, F3…). |

## Tablet de entrada (asistencia)

1. El operario toca **Escanear carnet** y acerca el QR a la cámara (o digita su número: `1`, `0001` u `OPR-0001`).
2. La tablet muestra su nombre y resalta el botón sugerido (**ENTRADA** si no ha marcado hoy, **SALIDA** si ya entró).
3. Toca el botón. Aparece la confirmación verde/azul con la hora.
4. Si se equivocó, el supervisor toca **Anular** en "Últimas marcas" y escribe el motivo. La marca queda tachada, no se borra.

**Indicador arriba a la derecha:**
- `Sincronizado hh:mm` (verde): todo enviado.
- `Enviando · N pendientes` / `Sin conexión · N pendientes` (ámbar): se guardó en la tablet y se enviará solo.
- `N rechazados` (rojo): el servidor no aceptó algo; tóquelo para ver el motivo y avise al supervisor.
- Franja roja: hay registros sin enviar hace más de 8 horas, o la hora de la tablet está mal. Revise el wifi o la hora.

Nunca desinstale la app ni borre sus datos con registros pendientes: se perderían. La opción
**Desvincular tablet** no deja hacerlo mientras haya pendientes.

## Celular de bodega

- **Consultar rollo:** escanee la etiqueta `TL-…` (o digite `tl12`). Ve saldo, lote, tono, ancho y ubicación.
  **Trasladar:** toque *Trasladar* y escanee la etiqueta de la ubicación nueva (`UB-…`). **Reimprimir:** escriba el motivo.
- **Conteo físico:** elija el conteo abierto, escanee la ubicación y luego cada rollo que está en ella. Para insumos toque
  *Contar insumo* y escriba la cantidad. Funciona sin internet; la oficina ve el avance en vivo.
- **Impresora:** *Imprimir prueba* para revisar la conexión. Si una etiqueta no sale, queda en la cola y se reintenta sola.

## Ficha técnica (Diseño)

1. *Fichas técnicas → Nueva referencia*: crea la versión 1 en borrador.
2. Complete los 7 pasos. Todo se guarda solo al salir de cada campo. La secuencia de operaciones se puede traer de SAMMU
   en el paso 6 (*Importar de SAMMU*, con el reporte de la referencia).
3. En el paso 7 la ficha dice qué le falta. Cuando esté completa: **Enviar a aprobación**.
4. Diseño, Producción y Costos aprueban cada uno su parte. Si alguien rechaza, vuelve a borrador con el motivo.
5. Una ficha aprobada no se toca: para cambiarla, **Nueva versión**. Las OP que ya la usan conservan la anterior.
