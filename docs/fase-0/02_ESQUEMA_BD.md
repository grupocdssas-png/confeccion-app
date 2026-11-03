# Fase 0 — Esquema completo de base de datos (propuesta)

> Estado: **APROBADO** (3/nov/2026) con las recomendaciones de la sección 5 del documento 01.
> Ajustes al implementar la Fase 1: el salario va en `empleados_nomina` (no baja a las tablets) y
> la ingesta identifica la tablet por su sesión. Incluye las tablas de todas las fases; se crearán por
> migraciones en la fase indicada, pero el diseño queda fijo desde ahora.

**Leyenda**
- **(E)** Evento inmutable: solo INSERT; anulación = registro nuevo. Trigger bloquea UPDATE/DELETE.
- **↓** Se descarga a tablets/celulares. **↑** Se crea en el dispositivo y sube por la bandeja de salida.
- **F#** Fase en que se crea la tabla.
- Todas las tablas maestras llevan además: `creado_en, creado_por, actualizado_en, actualizado_por, activo`.
- Todos los eventos **↑** llevan además: `dispositivo_id, ocurrido_en` (hora tablet),
  `recibido_en` (hora servidor), `desfase_reloj_s`, `reloj_dudoso`.

Total aproximado: **~130 tablas** en 17 grupos.

---

## 1. Seguridad, sistema y auditoría (F1)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `roles` | codigo PK (gerencia, jefe_produccion, diseno, corte, estampacion, bordado, tejidos, confeccion, terminacion, calidad, bodega, compras, costos, comercial, mecanico, operario, satelite, dispositivo), nombre | Fijos. |
| `perfiles` | id = auth.users.id, nombre, empleado_id?, satelite_id?, activo | Un perfil por usuario de Supabase. |
| `usuario_roles` | usuario_id, rol, celula_id?, proceso? | Alcance opcional (ej. supervisor solo de su módulo). Base de RLS. |
| `permisos_modulo` | rol, modulo, puede_ver, puede_editar, puede_aprobar | Configurable desde la web; RLS consulta funciones `tiene_rol()` / `puede()`. |
| `estaciones` ↓ | id, codigo (C02, MOD3…), nombre, tipo (modulo, mesa_corte, bodega, calidad, entrada, estampacion, bordado, tejidos, terminacion), celula_id?, bodega_id?, impresora_id?, proceso | Define qué descarga cada tablet. |
| `dispositivos` | id, usuario_id (cuenta técnica), estacion_id, nombre, tipo (tablet, celular, tv), version_app, ultima_sync, desfase_reloj_s | |
| `parametros` ↓ | clave PK, valor jsonb, descripcion | Tolerancia ancho 2 cm, desviación ±5 %, máx. 20 prendas/paquete, unidades por marcación, horas aviso pendientes (8), etc. |
| `consecutivos` | tipo PK, prefijo, siguiente, relleno | OP, pedidos, remisiones, OC… (servidor). |
| `consecutivos_estacion` | estacion_id, tipo, ultimo | Para códigos creados sin conexión (`PQ-C02-000451`). |
| `auditoria` | id bigserial, tabla, registro_id, accion, antes jsonb, despues jsonb, usuario_id, dispositivo_id, ocurrido_en | Trigger genérico en todas las tablas. Solo inserción. |
| `ingesta_eventos` | id (uuid del evento), tabla, dispositivo_id, lote_id, recibido_en, estado (aceptado, duplicado, rechazado), motivo_rechazo | Bitácora de la sincronización; idempotencia y diagnóstico. |
| `alertas` | id, tipo (stock_negativo, sobreconsumo, op_atrasada, paro_largo, lote_mezclado, pendientes_8h, reloj_dudoso…), severidad, entidad, entidad_id, mensaje, estado (abierta, atendida), atendida_por, atendida_en | Alimenta panel y WhatsApp. |
| `adjuntos` | id, entidad, entidad_id, tipo (foto, boceto, molde, trazo, arte, soporte), storage_path, nombre, tamano | Archivos en Supabase Storage. |

## 2. Maestros de organización (F1)

| Tabla | Columnas principales |
|---|---|
| `locaciones` | id, nombre, direccion, tipo (planta, bodega, satelite) |
| `areas` ↓ | id, codigo, nombre, proceso_codigo? |
| `procesos` ↓ | codigo PK (diseno, corte, estampacion, bordado, tejidos, confeccion, terminacion, calidad), nombre, color_hex, orden |
| `cargos` | id, nombre |
| `empleados` ↓ | id, codigo, documento, nombres, apellidos, foto_path, cargo_id, area_id, celula_id, grupo_incentivo_id?, qr (`OPR-…`), fecha_ingreso |
| `empleados_nomina` | empleado_id, salario_base, tipo_contrato | Solo gerencia y costos. No se sincroniza. |
| `celulas` ↓ | id, codigo, nombre, area_id, proceso, turno_id, grupo_incentivo_id, locacion_id |
| `jornadas` | id, nombre, horas_semana |
| `turnos` ↓ | id, nombre, hora_inicio, hora_fin, cruza_medianoche, jornada_id |
| `turno_pausas` ↓ | turno_id, causa_paro_id, hora_inicio, minutos | Almuerzo, pausas activas. |
| `festivos` ↓ | fecha PK, nombre |
| `programacion_turnos` ↓ | id, celula_id? / empleado_id? (uno de los dos), turno_id, desde, hasta, dias_semana |
| `tipos_maquina` ↓ | id, codigo, nombre, precio_minuto |
| `maquinas` ↓ | id, codigo (`MAQ-…`), tipo_maquina_id, marca, modelo, serie, categoria, celula_id?, estado (operativa, en_reparacion, baja), precio_minuto?, fecha_compra, valor_compra | También es el activo de mantenimiento. |
| `tallas` ↓ | id, codigo (XS…XXL, 2…16), orden |
| `curvas` | id, nombre | |
| `curva_tallas` | curva_id, talla_id, proporcion |
| `grupos_color` | id, nombre |
| `colores` ↓ | id, codigo, nombre, hex, grupo_color_id |
| `unidades_medida` ↓ | codigo PK (m, kg, und, cono, rollo, g, ml), nombre, decimales |
| `bodegas` ↓ | id, codigo, nombre, tipo (telas, insumos, piezas_corte, producto_terminado, segundas, satelite, transito), locacion_id, satelite_id? |
| `ubicaciones` ↓ | id, bodega_id, codigo (`UB-…`), descripcion |
| `proveedores` | id, nit, nombre, contacto, telefono, correo, plazo_dias |
| `satelites` | id, nit, nombre, contacto, whatsapp, procesos text[], tarifa_minuto?, calificacion (calculada), bodega_id |
| `canales` | id, codigo (directo, shopify, b2b, mayorista), nombre |
| `clientes` | id, nit, nombre, canal_id, contacto, whatsapp, ciudad |

## 3. Inventario de materiales (F2)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `categorias_material` | id, nombre, tipo (tela, insumo) | |
| `materiales` ↓ | id, codigo, tipo (tela, insumo), categoria_id, nombre, unidad (m, kg, und…), composicion, ancho_nominal_cm, gramaje_gm2, rendimiento_m_kg, maneja_rollos bool, maneja_color bool, proveedor_id, costo_estandar, stock_minimo | Tela sin color (ver decisión 4). |
| `rollos` ↓ | id, codigo (`TL-…`), material_id, color_id, proveedor_id, lote_tintura, tono, ancho_real_cm, metros_iniciales, kilos_iniciales, metros_saldo*, kilos_saldo*, costo_metro, ubicacion_id, estado (disponible, reservado, en_corte, retazo, agotado), es_retazo, rollo_origen_id?, recepcion_linea_id, fecha_ingreso | *Saldo mantenido por trigger desde movimientos. Retazos = rollos con `es_retazo` y origen. |
| `movimientos_inventario` (E) ↑ | id uuid, tipo (entrada_compra, reserva, liberacion, salida_op, envio_satelite, devolucion, ajuste, conteo, traslado, anulacion), afecta (fisico, reservado), material_id, color_id?, rollo_id?, bodega_id, ubicacion_id?, cantidad (con signo), metros?, kilos?, costo_unitario, op_id?, ajuste_id?, documento_tipo, documento_id, motivo, anula_id?, usuario_id, empleado_id? | El kardex. Salidas exigen `op_id` o ajuste aprobado. |
| `saldos_inventario` ↓ | material_id, color_id, bodega_id, ubicacion_id, fisico, reservado, disponible (generada = fisico − reservado), costo_promedio, actualizado_en | Actualizada por trigger en la misma transacción. Si queda < 0 → alerta. |
| `reservas_op` | op_id, material_id, color_id, parte_id?, cantidad_reservada, cantidad_consumida, cantidad_liberada | Vista materializada de los movimientos de reserva por OP. |
| `ajustes_inventario` | id, consecutivo, motivo, estado (borrador, enviado, aprobado, rechazado), solicitado_por, aprobado_por, aprobado_en | Al aprobar genera movimientos. |
| `ajuste_lineas` | ajuste_id, material_id, color_id, rollo_id?, bodega_id, ubicacion_id, cantidad, costo |  |
| `conteos_fisicos` | id, bodega_id, ubicacion_id?, tipo (total, ciclico), estado (abierto, cerrado, ajustado), abierto_por, cerrado_en, ajuste_id? | |
| `conteo_registros` (E) ↑ | id uuid, conteo_id, rollo_id? / material_id+color_id, ubicacion_id, cantidad_contada, empleado_id | Escaneo con celular. Diferencias = vista contra saldo al cierre. |

## 4. Producto terminado y segundas (F9)

| Tabla | Columnas principales |
|---|---|
| `skus` ↓ | id, codigo (`PT-…`), referencia_id, combinacion_id?, color_id, talla_id, codigo_alegra, shopify_variant_id, codigo_barras, precio_venta |
| `movimientos_producto` (E) ↑ | id uuid, tipo (ingreso_op, ingreso_segunda, despacho, devolucion, ajuste, anulacion), sku_id, bodega_id (PT o segundas), cantidad, op_id?, paquete_id?, documento, motivo, anula_id?, usuario_id |
| `saldos_producto` | sku_id, bodega_id, cantidad |

## 5. Diseño y ficha técnica versionada (F3)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `lineas`, `colecciones` | id, nombre (colección: temporada, año) | |
| `familias_producto` ↓ | id, nombre (camiseta, buzo, jogger…) | Para lista maestra. |
| `tipos_producto` ↓ | id, familia_id, nombre | |
| `referencias` ↓ | id, codigo, nombre, linea_id, coleccion_id, tipo_producto_id, cliente_id?, version_vigente_id | |
| `muestras` | id, referencia_id, numero, estado (solicitada, en_desarrollo, aprobada, rechazada), responsable, fechas, observaciones | Desarrollo previo a la ficha. |
| `ficha_versiones` ↓ | id, referencia_id, version, estado (borrador, en_aprobacion, aprobada, obsoleta), basada_en_id?, composicion, instrucciones_lavado, precio_objetivo, curva_id, sam_total*, costo_estandar*, aprobada_en | **Aprobada = congelada** (trigger sobre ella y todas sus hijas). |
| `ficha_tallas` ↓ | ficha_id, talla_id, orden | |
| `ficha_partes` ↓ | id, ficha_id, nombre (cuerpo, mangas y capota, bolsillo…), orden, puede_cortarse_retazo | |
| `ficha_combinaciones` ↓ | id, ficha_id, codigo, nombre ("Negro / Gris jaspe") | Para un solo color: una combinación por color. |
| `ficha_combinacion_partes` ↓ | combinacion_id, parte_id, material_id, color_id | Color de cada parte en cada combinación. |
| `ficha_medidas` | id, ficha_id, punto_medida, metodo, orden | |
| `ficha_medida_tallas` | medida_id, talla_id, valor_cm, tolerancia_cm | Calidad inspecciona contra esto. |
| `ficha_bom` ↓ | id, ficha_id, material_id, parte_id?, combinacion_id? (null = todas), color_fijo_id?, unidad, merma_pct, permite_retazo, observacion | Línea de lista de materiales. |
| `ficha_bom_consumos` ↓ | bom_id, talla_id, consumo | Consumo por talla. |
| `ficha_artes` | id, ficha_id, proceso (estampacion, bordado), parte_id, archivo (adjunto), tecnica, tintas jsonb / hilos jsonb, puntadas, ancho_cm, alto_cm, ubicacion | |
| `ficha_ruta` ↓ | ficha_id, proceso, orden, modalidad (interno, satelite, ambos) | |
| `ficha_operaciones` ↓ | id, ficha_id, secuencia, operacion_id, proceso, parte_id?, sam (copia), valor_destajo (copia), tipo_maquina_id, repeticiones, es_contadora | Copia congelada de la lista maestra al aprobar. |
| `ficha_costo_estandar` | ficha_id, concepto (materiales, mano_obra, externos, indirectos), detalle jsonb, valor | Calculado y congelado al aprobar. |
| `ficha_aprobaciones` (E) | id, ficha_id, area (diseno, produccion, costos), decision, comentario, usuario_id, fecha | |

## 6. Lista maestra de operaciones y estudio de tiempos (F3 / F12)

| Tabla | Columnas principales |
|---|---|
| `operaciones` ↓ | id, codigo, nombre, familia_id, tipo_producto_id?, proceso, sam, unidades_hora (generada 60/sam), valor_destajo, tipo_maquina_id, parte_nombre, repeticiones, agrega_minutos_sam, restrictiva, tipo (normal, reproceso, manual, inspeccion, empaque) |
| `operaciones_historial` (E) | id, operacion_id, sam_anterior, sam_nuevo, valor_anterior, valor_nuevo, origen (manual, estudio, importacion), estudio_id?, usuario_id, fecha |
| `estudios_tiempo` | id, operacion_id, empleado_id, analista_id, fecha, valoracion_pct, suplementos_pct, metodo (promedio, moda), tiempo_normal, sam_propuesto, estado (borrador, propuesto, aprobado, rechazado), aprobado_por |
| `estudio_tomas` | estudio_id, numero, elemento?, segundos, descartada |

## 7. Pedidos, OP, requisiciones y compras (F4)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `pedidos` | id, consecutivo, cliente_id, canal_id, origen (manual, shopify, b2b), externo_id, fecha, fecha_comprometida, estado (abierto, en_produccion, cumplido, cancelado) | |
| `pedido_lineas` | id, pedido_id, referencia_id, combinacion/color_id, talla_id, cantidad, cantidad_en_op | |
| `ordenes_produccion` ↓ | id, consecutivo (`OP-…`), referencia_id, ficha_version_id, prioridad, estado (planeada, en_proceso, terminada, cerrada, anulada), proceso_actual, fecha_inicio_plan, fecha_entrega_plan, fecha_comprometida, cantidad_total, alerta_material, primera_marcacion*, ultima_marcacion* | Conserva su versión de ficha. |
| `op_pedidos` | op_id, pedido_linea_id, cantidad | Una OP puede agrupar varios pedidos. |
| `op_cantidades` ↓ | op_id, combinacion_id, color_id, talla_id, cantidad_pedida, cantidad_cortada*, saldo_recorte*, sobrante* | Matriz talla × color. |
| `op_necesidades` | op_id, material_id, color_id, parte_id?, cantidad_estandar, cantidad_reservada*, cantidad_consumida*, faltante* | Σ (consumo BOM × cantidad por talla). |
| `op_procesos` ↓ | op_id, proceso, orden, modalidad, estado (pendiente, en_proceso, terminado), responsable_id, entra*, buenas*, segundas*, faltantes*, inicio*, fin* | Línea de tiempo (acumulados desde eventos). |
| `eventos_proceso` (E) ↑ | id uuid, op_id, proceso, paquete_id? / juego_id?, estacion_id, celula_id? / satelite_id?, tipo (recepcion, entrega, inicio, cierre, anulacion), entra, buenas, segundas, faltantes, danadas, consumos jsonb, remision_id?, anula_id?, usuario_id/empleado_id | Escaneo por estación. `entra = buenas + segundas + faltantes`. |
| `requisiciones` | id, consecutivo, op_id?, origen (automatica, manual), estado | |
| `requisicion_lineas` | requisicion_id, material_id, color_id, cantidad, fecha_requerida, oc_linea_id? | |
| `ordenes_compra` | id, consecutivo, proveedor_id, fecha, fecha_entrega, estado, total, alegra_id? | |
| `oc_lineas` | id, oc_id, material_id, color_id, cantidad, precio_unitario, cantidad_recibida* | |
| `recepciones` | id, consecutivo, oc_id?, proveedor_id, bodega_id, factura_proveedor, fecha, estado | Confirmar = crea rollos + movimientos + etiquetas (transacción). |
| `recepcion_lineas` | id, recepcion_id, oc_linea_id?, material_id, color_id, cantidad, costo_unitario, lote_tintura | Telas: una línea por rollo recibido. |

## 8. Programación de planta (F7)

| Tabla | Columnas principales |
|---|---|
| `programacion` | id, op_id, proceso, celula_id? / satelite_id?, inicio_plan, fin_plan, minutos_requeridos, orden, fijado bool |
| `capacidad_dia` (vista) | celula, fecha, minutos_disponibles (turnos × operarios − pausas − festivos − ausentismos), minutos_cargados |

## 9. Corte (F5)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `trazos` ↓ | id, referencia_id, ficha_version_id?, parte_id?, nombre, archivo (adjunto), forma (normal, espigas), largo_m (normal), ancho_util_cm, eficiencia_pct, es_plantilla | Plantilla por referencia (y por parte en combinada). |
| `trazo_secciones` ↓ | id, trazo_id, letra (A–E), orden (1 = cabecera), largo_m | 2 a 5 secciones. |
| `trazo_unidades` ↓ | trazo_id, seccion_id? (null en normal), talla_id, unidades | Una talla puede estar en varias secciones. |
| `cortes` ↓↑ | id uuid, codigo, op_id, numero (1 = inicial, 2+ = recortes), tipo (un_color, multicolor, combinada), forma (normal, espigas), estacion_id (mesa), cortador_id, despunte_cm, tol_ancho_cm, tol_desviacion_pct, estado (borrador, tendiendo, confirmado, anulado), confirmado_en | Puede crearse y confirmarse sin conexión. |
| `corte_tendidos` ↑ | id uuid, corte_id, parte_id? (combinada), trazo_id, orden, estacion_id, fecha | Uno en un color/multicolor; uno por parte en combinada. |
| `corte_bloques` ↑ | id uuid, tendido_id, orden, color_id, lote_tintura, tono, ancho_real_cm, capas (normal) | Bloque de color en el orden tendido. |
| `corte_bloque_espigas` ↑ | bloque_id, espiga (1–5), capas | Capas por espiga y color. |
| `corte_rollos` ↑ | id uuid, bloque_id, rollo_id, orden, metros_usados, kilos_usados, metros_sobrantes, destino_sobrante (vuelve, retazo) | Se descuentan en orden. |
| `corte_empalmes` ↑ | id uuid, bloque_id, rollo_sale_id, rollo_entra_id, capa, merma_m | |
| `corte_autorizaciones` (E) ↑ | id uuid, corte_id, tipo (mezcla_lote, mezcla_tono, ancho_fuera_tolerancia, desviacion), detalle jsonb, motivo, autorizado_por (jefe de corte), fecha | Regla 8. |
| `corte_resultados` | corte_id, parte_id?, color_id, talla_id, piezas_teoricas, piezas_cortadas, diferencia | Pedido vs cortado. |
| `corte_totales` | corte_id, tendido_id?, metros_teoricos, metros_reales, desviacion_pct, retazos_m, desperdicio_kg | |
| `paquetes` ↓↑ | id uuid, codigo (`PQ-…`), op_id, corte_id, parte_id?, color_id, talla_id, lote_tintura, cantidad, espiga?, capa_desde, capa_hasta, juego_id?, estado, proceso_actual, celula_id?, satelite_id? | Un color, una talla, un lote (regla 9). Máx. configurable. |
| `juegos` ↓↑ | id uuid, codigo (`JG-…`), op_id, talla_id, combinacion_id, cantidad, estado | Agrupa paquetes de todas las partes. |
| `movimientos_piezas` (E) ↑ | id uuid, op_id, corte_id?, parte_id, color_id, talla_id, lote_tintura, cantidad (±), tipo (corte, armado_juego, recorte, anulacion), bodega_id (piezas_corte) | Piezas sueltas = saldo de esta tabla. |

## 10. Control de piso (F6 / F7 / F8)

| Tabla | Columnas principales | Notas |
|---|---|---|
| `causas_paro` ↓ | id, codigo, nombre, visible_tablet, descuenta_operario, descuenta_nomina, descuenta_celula, detiene_trabajo, detiene_celula, rol_validador?, cuenta_para_validador, minutos_definidos?, activa | |
| `paros` (E) ↑ | id uuid, empleado_id?, celula_id, causa_id, maquina_id?, inicio, observacion | |
| `paro_eventos` (E) ↑ | id uuid, paro_id, tipo (fin, validacion, anulacion), ocurrido_en, validador_id?, motivo | Duración = vista. |
| `balanceos` ↓ | id, op_id, celula_id, version, operarios, eficiencia_objetivo, sam_total, tiempo_ciclo, meta_hora, meta_turno, dias_estimados, operacion_contadora_id, pct_balance, cuello_botella_puesto, estado (borrador, publicado), publicado_en | Publicado = se envía a tablets. |
| `balanceo_puestos` ↓ | id, balanceo_id, numero, empleado_id?, maquina_id?, carga_min | |
| `balanceo_asignaciones` ↓ | puesto_id, ficha_operacion_id, fraccion (0–1), minutos | Operación compartida = dos filas. |
| `operario_operaciones` (E) ↑ | id uuid, empleado_id, op_id, ficha_operacion_id, accion (agregar, quitar) | "Mis operaciones" (sobrevive al cambio de tablet). |
| `marcaciones` (E) ↑ | id uuid, empleado_id, celula_id, op_id, paquete_id?, ficha_operacion_id, talla_id, color_id, unidades, tipo (normal, reproceso), sam, minutos_esperados, minutos_reales, minutos_paro_descontados, eficiencia, valor_destajo, marcacion_anterior_id? | Valores calculados en tablet; el servidor recalcula en `marcaciones_oficial`. |
| `marcacion_anulaciones` (E) ↑ | id uuid, marcacion_id (único), motivo, usuario/empleado_id | Queda tachada. |
| `marcaciones_oficial` | marcacion_id, minutos_reales, minutos_paro, eficiencia, recalculado_en | Fuente oficial del servidor. |
| `eficiencia_hora` | empleado_id, celula_id, fecha, hora, unidades, minutos_esperados, minutos_disponibles, minutos_paro, eficiencia | Acumulado del servidor (para TV e informes). |
| `grupos_incentivo` ↓ | id, nombre, tipo (individual, modular), periodo (diario, semanal, quincenal, mensual), base (eficiencia) | |
| `incentivo_tramos` ↓ | grupo_id, eficiencia_desde, eficiencia_hasta, forma (fijo, por_minuto, porcentaje), valor | |
| `liquidaciones` | id, tipo (destajo, incentivo), desde, hasta, estado (borrador, cerrada, exportada), generado_por | Una vez cerrada no cambia. |
| `liquidacion_lineas` | liquidacion_id, empleado_id, unidades, minutos_esperados, minutos_disponibles, eficiencia, valor_destajo, valor_incentivo, total | Exportable a Excel. |
| `tableros_tv` | id, nombre, vistas jsonb (célula, todas, procesos, planta), rotacion_s, dispositivo_id? | |

## 11. Procesos externos y satélites (F6)

| Tabla | Columnas principales |
|---|---|
| `remisiones` ↑ | id uuid, consecutivo, tipo (salida, entrada), satelite_id, proceso, op_id, fecha, estado (abierta, parcial, cerrada), remision_salida_id? (en entradas), usuario_id |
| `remision_paquetes` ↑ | remision_id, paquete_id / juego_id, cantidad, buenas, segundas, faltantes, danadas |
| `remision_insumos` ↑ | remision_id, material_id, color_id, cantidad (genera movimiento `envio_satelite`) |
| `tarifas_satelite` | satelite_id, referencia_id? / proceso, valor_unidad / valor_minuto, vigente_desde |
| `cuentas_pagar_satelite` | id, satelite_id, op_id, remision_id?, base (op_terminada, marcaciones), cantidad, valor, estado (pendiente, aprobada, pagada), alegra_id? |

## 12. Calidad (F9)

| Tabla | Columnas principales |
|---|---|
| `defectos` ↓ | id, codigo, nombre, proceso, severidad (menor, mayor, critico) |
| `planes_muestreo` ↓ | id, nombre, nivel_inspeccion, aql, tabla jsonb (tamaño lote → muestra, aceptación) |
| `inspecciones` (E) ↑ | id uuid, tipo (en_proceso, auditoria_final), op_id, paquete_id? / juego_id?, celula_id? / satelite_id?, inspector_id, tamano_lote, tamano_muestra, plan_id, resultado (aprobado, rechazado), alcance (individual, grupal) |
| `inspeccion_defectos` (E) ↑ | inspeccion_id, defecto_id, cantidad, talla_id, empleado_responsable_id?, ficha_operacion_id? |
| `inspeccion_medidas` ↑ | inspeccion_id, medida_id, talla_id, valor_medido, fuera_tolerancia |
| `devoluciones_calidad` (E) ↑ | id uuid, paquete_id, cantidad, defecto_id, empleado_id, ficha_operacion_id, estado (asignada, reprocesada, segunda) , marcacion_reproceso_id? |

## 13. Costos (F10)

| Tabla | Columnas principales |
|---|---|
| `valores_minuto` ↓ | id, area_id? / celula_id?, valor, vigente_desde |
| `tasas_indirectos` | periodo, base (minuto, unidad, porcentaje_mo), valor |
| `costos_op` | op_id, concepto (tela, insumos, satelites, mano_obra, indirectos), estandar, real, desviacion_pct, calculado_en | Real = vista sobre movimientos, marcaciones y cuentas de satélites. |

## 14. Mantenimiento (F12)

| Tabla | Columnas principales |
|---|---|
| `maquina_partes` | id, maquina_id, nombre, referencia |
| `tipos_mantenimiento` | id, nombre (preventivo, correctivo, ajuste) |
| `fallas` ↓ | id, codigo, nombre, tipo_maquina_id? |
| `planes_preventivos` | id, maquina_id / tipo_maquina_id, tipo_mantenimiento_id, frecuencia_dias, ultima_fecha, proxima_fecha |
| `ordenes_mantenimiento` ↑ | id uuid, maquina_id, tipo_mantenimiento_id, falla_id?, paro_id?, mecanico_id, inicio, fin, error_mantenimiento bool, descripcion, repuestos jsonb |

## 15. Asistencia (F12)

| Tabla | Columnas principales |
|---|---|
| `asistencia_marcas` (E) ↑ | id uuid, empleado_id, tipo (entrada, salida), estacion_id |
| `tipos_ausentismo` | id, nombre, remunerado, descuenta_disponible |
| `ausentismos` | id, empleado_id, tipo_id, desde, hasta, horas, soporte (adjunto), aprobado_por |
| `asistencia_dia` (vista) | empleado, fecha, entrada, salida, horas_normales, horas_extra, minutos_disponibles |

## 16. Etiquetas e impresión (F2 en adelante)

| Tabla | Columnas principales |
|---|---|
| `impresoras` ↓ | id, nombre, modelo, conexion (tcp, bluetooth, browser_print), ip, puerto (9100), mac_bluetooth, dpi (203), estacion_id |
| `plantillas_etiqueta` ↓ | id, tipo (paquete, juego, rollo, ubicacion, maquina, producto_terminado, carnet), tamano (50x30, 100x50), zpl (con ^CI28 y marcadores `{{codigo}}`), version, activa |
| `trabajos_impresion` (E) ↑ | id uuid, impresora_id, plantilla_id, plantilla_version, entidad, entidad_id, codigo, es_reimpresion, motivo?, estado_final (enviado, error), intentos, usuario_id | La cola con reintentos vive en la tablet; aquí queda el registro. |

## 17. Integraciones, importación y mensajería (F3 / F11 / F12)

| Tabla | Columnas principales |
|---|---|
| `integracion_mapeos` | sistema (alegra, shopify, b2b), entidad, id_local, id_externo, ultimo_sync |
| `integracion_log` | id, sistema, direccion (entrada, salida), entidad, payload jsonb, estado, error, fecha |
| `notificaciones` | id, canal (whatsapp, interno), destino, plantilla, payload, alerta_id?, estado, enviado_en |
| `importaciones` | id, tipo (operaciones, empleados, celulas, maquinas, op_activas), archivo, estado, filas_ok, filas_error, errores jsonb, usuario_id |
| `mensajes` ↓↑ | id uuid, canal (celula_id / area_id), autor_id, texto, adjunto_id? |
| `mensaje_lecturas` ↑ | mensaje_id, usuario_id, leido_en |

---

## Funciones SQL principales (transaccionales)

| Función | Qué hace |
|---|---|
| `ingerir_eventos(lote jsonb)` | Recibe la bandeja de salida; valida, upsert idempotente por UUID, responde estado por evento. |
| `crear_op(...)` | Calcula necesidades, reserva, crea requisición si falta, marca alerta. |
| `confirmar_corte(corte_id)` | Valida lotes/anchos/autorizaciones, descuenta rollos en orden, libera reservas sobrantes, calcula resultados y desviación, genera paquetes/juegos/piezas sueltas y trabajos de impresión. |
| `armar_juegos(op_id, talla)` | Juegos = mínimo de piezas entre partes; resto a piezas sueltas. |
| `confirmar_recepcion(recepcion_id)` | Crea rollos, movimientos de entrada y trabajos de impresión. |
| `aprobar_ajuste(ajuste_id)` / `cerrar_conteo(conteo_id)` | Genera movimientos de ajuste. |
| `aprobar_ficha(ficha_id)` | Congela versión, copia SAM/valores, calcula costo estándar. |
| `recalcular_eficiencia(desde, hasta, celula)` | Fuente oficial de eficiencia, `eficiencia_hora`. |
| `liquidar(tipo, desde, hasta)` | Destajo e incentivos por tramos. |
| `trazabilidad(codigo)` | Desde PQ/JG/TL/PT/lote → rollos, lote de tintura, cortador, satélites, operarios, fechas. |

## Diagrama simplificado de relaciones clave

```
referencias ─< ficha_versiones ─< ficha_partes / combinaciones / bom / operaciones / ruta
                     │
pedidos ─< pedido_lineas ─< op_pedidos >─ ordenes_produccion ─< op_cantidades / op_necesidades / op_procesos
                                                │
          rollos ─< corte_rollos >─ corte_bloques >─ corte_tendidos >─ cortes
                                                │
                                   paquetes ─< marcaciones >─ empleados ─ celulas
                                   juegos      eventos_proceso / remisiones / inspecciones
materiales ─< movimientos_inventario  ──►  saldos_inventario (trigger, misma transacción)
```
