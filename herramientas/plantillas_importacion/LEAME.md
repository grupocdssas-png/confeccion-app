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

