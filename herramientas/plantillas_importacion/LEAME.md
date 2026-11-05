# Plantillas para importar desde SAMMU

Archivos de **ejemplo** (datos ficticios) con las columnas que reconoce el importador
(*Lista de operaciones → Importar de SAMMU*). Se pueden abrir y llenar en Excel y guardar como
`.xlsx` o como CSV (separado por `;`, como lo guarda Excel en español).

No hace falta que las columnas se llamen igual: el importador reconoce nombres parecidos
(por ejemplo "Cód. Operación", "Tiempo estándar") y deja elegir la columna a mano.

Orden recomendado: **células → empleados → máquinas → operaciones**.
Los tipos de máquina (PLA, FIL, REC…) y las familias deben existir antes.

## Secuencia de una referencia (formato real de SAMMU)

El reporte de SAMMU por referencia (`Secuencia;Nombre;Sitio de trabajo;Sam;Proceso;Repeticiones;…`) se importa tal cual
**desde la ficha técnica del producto** (paso 6, botón *Importar de SAMMU*). No hay que convertirlo ni cambiarle el formato.

## OP que están en proceso al pasar de SAMMU (propuesta)

`op_activas_ejemplo.csv` es una **propuesta** (aún no se importa): sirve para el día del cambio, para que las órdenes que
van por la mitad en SAMMU sigan en la app sin crearlas a mano. Una fila por OP × color × talla:

| Columna | Qué es |
|---|---|
| OP | Número de la orden en SAMMU (se guarda como referencia externa) |
| Referencia | Código de la referencia (debe tener ficha aprobada en la app) |
| Color | Código de la combinación de color de la ficha (N, GJ…) |
| Talla | Código de la talla |
| Cantidad | Prendas de la OP en ese color y talla |
| Fecha entrega | Fecha planeada de entrega |
| Proceso actual | corte, estampacion, confeccion, terminacion, calidad… |
| Cantidad terminada en el proceso | Lo que ya salió del proceso actual (lo de procesos anteriores se toma como terminado) |
| Pedido / cliente | Opcional |
| Observación | Opcional |

Si SAMMU tiene un reporte o consulta de OP abiertas que se pueda exportar a Excel, con esas columnas (o parecidas)
basta; si no, se llena esta plantilla.
