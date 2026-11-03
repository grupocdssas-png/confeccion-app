# Fase 0 — Propuesta de arquitectura

> Estado: **APROBADO** el 3/nov/2026 con todas las recomendaciones (⭐) de la sección 5.
> El esquema completo de base de datos está en [`02_ESQUEMA_BD.md`](02_ESQUEMA_BD.md).
> Las decisiones que necesito que elijas están en la sección 5.

---

## 1. Estructura del proyecto (monorepo)

```
confeccion/
├── app/                          ← Flutter (un solo código)
│   ├── lib/
│   │   ├── main_planta.dart      ← entrada Android (tablets y celulares, modo kiosco)
│   │   ├── main_web.dart         ← entrada web (panel de oficina + modo TV)
│   │   ├── core/
│   │   │   ├── tema/             ← colores, IBM Plex Sans/Mono, tamaños planta/TV
│   │   │   ├── router/           ← go_router, rutas por rol
│   │   │   ├── auth/             ← sesión Supabase, roles, ingreso por QR de carnet
│   │   │   ├── db_local/         ← drift sobre SQLite (tablas locales, vistas)
│   │   │   ├── sync/             ← descarga, bandeja de salida, indicador de sincronización
│   │   │   ├── impresion/        ← ZPL, TCP 9100, Bluetooth, Browser Print, cola local
│   │   │   ├── escaneo/          ← mobile_scanner + lectores QR con prefijos (PQ, JG, TL…)
│   │   │   └── formato/          ← COP, 1.234,56, America/Bogota, unidades
│   │   ├── features/             ← un módulo por área, cada uno con data/ dominio/ ui/
│   │   │   ├── maestros/  inventario/  ficha_tecnica/  operaciones/
│   │   │   ├── pedidos_op/  programacion/  corte/  piso_tablet/
│   │   │   ├── balanceo/  eficiencia/  tv/  procesos_externos/  calidad/
│   │   │   ├── terminacion/  compras/  costos/  mantenimiento/  asistencia/
│   │   │   ├── estudio_tiempos/  trazabilidad/  informes/  configuracion/  mensajes/
│   │   └── compartido/           ← widgets comunes (tarjetas, semáforo, tablas, botones 64–72 px)
│   └── test/
├── packages/
│   └── calculos/                 ← Dart PURO, sin Flutter: BOM × curva, corte normal y por
│                                   espigas, juegos, balanceo, eficiencia, incentivos,
│                                   capacidad, costos. 100 % cubierto por pruebas.
├── supabase/
│   ├── migrations/               ← SQL versionado (tablas, triggers, RLS, funciones)
│   ├── seed/                     ← datos de ejemplo marcados "EJEMPLO"
│   ├── functions/                ← Edge Functions (Alegra, Shopify, WhatsApp, importador SAMMU)
│   └── tests/                    ← pgTAP: inmutabilidad, RLS, kardex, recálculo oficial
├── sync/                         ← reglas de sincronización (ver sección 2)
├── test_vectores/                ← casos JSON compartidos: los mismos se prueban en Dart y en SQL
└── docs/                         ← fases, guías por rol, README de instalación
```

**Por qué `packages/calculos` aparte:** los cálculos se hacen en la tablet (Dart) y el servidor
recalcula como fuente oficial (SQL). Para que nunca den distinto, ambos se prueban contra los
mismos vectores de prueba en `test_vectores/`.

---

## 2. Estrategia sin conexión: PowerSync vs. cola propia

| | **PowerSync** | **Cola propia (drift + RPC)** |
|---|---|---|
| Descarga incremental | Resuelta: "reglas de sincronización" filtran por estación/célula y solo bajan cambios (incluye borrados lógicos). | Hay que construirla: `updated_at` en cada tabla, cursores por tabla, lápidas para eliminaciones, paginación. Es lo que más errores produce. |
| Bandeja de salida | Cola persistente en SQLite incluida, en orden, sobrevive reinicios. Nosotros escribimos la función de subida. | La construimos nosotros (sencillo porque todo es evento). |
| Subida idempotente | La hacemos igual en ambos casos: RPC `ingerir_eventos` con upsert por UUID. | Igual. |
| Base local / drift | Usa su propia SQLite; drift funciona encima (`drift_sqlite_async`). Esquema local declarado. | drift directo, control total de migraciones locales. |
| Web / TV | Tiene SDK web, pero no lo necesitamos (ver decisión 2). | — |
| Costo / operación | Servicio adicional: PowerSync Cloud (plan gratuito limitado, luego pago mensual) o autoalojado gratis (Open Edition, requiere un servidor con Docker). | Sin costo extra. |
| Riesgo | Dependencia de un tercero; curva de aprendizaje de las reglas. | Más código nuestro que mantener y probar. |
| Tiempo estimado Fase 1 | Menor. | +1 a 2 semanas de trabajo y más pruebas. |

**Recomendación: PowerSync (Cloud para empezar)** para la *descarga* y la base local; la *subida*
va por nuestra propia RPC idempotente. Como todo lo que se crea en planta es un evento que solo
se agrega, no hay conflictos de edición que resolver. Si más adelante el costo no se justifica,
la subida ya es nuestra y la descarga se puede reemplazar sin tocar las pantallas.

### Cómo funciona (igual con cualquiera de las dos opciones)

1. **Identidad del dispositivo:** cada tablet tiene su cuenta técnica (rol `dispositivo`) ligada a
   una *estación* (módulo, mesa de corte, bodega, calidad, entrada). El operario **no** tiene
   correo: se identifica escaneando su carnet (`OPR-xxxx`) y su `empleado_id` va en cada evento.
2. **Descarga** al iniciar turno y cada vez que hay señal: maestros (empleados, células, turnos,
   causas de paro, plantillas), OP activas de la célula/estación, paquetes, secuencias con SAM y
   valor, rollos e insumos de la bodega de la estación.
3. **Evento local:** UUID v7 generado en la tablet + `ocurrido_en` (hora del dispositivo) + estado
   `pendiente`. Se guarda en SQLite antes de mostrar nada en pantalla.
4. **Subida en orden** a `ingerir_eventos(lote)`: el servidor valida (permisos, lote de tintura,
   paros con validador…), hace `INSERT … ON CONFLICT (id) DO NOTHING`, guarda `recibido_en`, y
   responde por cada UUID: `aceptado`, `duplicado` (se trata como aceptado) o `rechazado + motivo`.
   Solo entonces se marca `sincronizado` localmente. Los rechazados quedan visibles para el
   supervisor, nunca se borran en silencio.
5. **Inventario sin conexión:** los movimientos son deltas (`−12,5 m`), no saldos. Si dos tablets
   descuentan el mismo rollo, ambos se aplican; si el saldo queda negativo se crea alerta para bodega.
6. **Hora del dispositivo:** en cada sincronización se mide el desfase `hora servidor − hora tablet`
   y se guarda con el evento. Si el desfase supera 5 min el evento se marca `reloj_dudoso` (se
   acepta, pero el recálculo oficial usa la hora corregida) y se alerta al supervisor. La tablet
   además guarda un reloj monótono para detectar cambios de hora durante el turno.
7. **Indicador:** "Sin conexión · N pendientes" / "Sincronizado hh:mm"; aviso rojo si hay pendientes
   de más de 8 h. Los datos locales nunca se borran hasta confirmación del servidor.

---

## 3. Reglas de negocio → cómo se garantizan en la base de datos

| Regla | Mecanismo |
|---|---|
| 1. Ningún material sale sin OP o ajuste aprobado | `CHECK` en `movimientos_inventario`: salidas exigen `op_id` o `ajuste_id` aprobado (validado por trigger). |
| 2. Eventos nunca se borran ni editan | Trigger `BEFORE UPDATE OR DELETE` que lanza error en todas las tablas marcadas **(E)**; RLS sin políticas de UPDATE/DELETE. Anulación = nuevo registro con `anula_id`, motivo y usuario. |
| 3. Stock = suma de movimientos | `saldos_inventario` se actualiza por trigger **en la misma transacción** del movimiento; prueba nocturna compara saldo vs suma del kardex. |
| 4. Disponible = físico − reservado | Reservas y liberaciones son movimientos que afectan la columna `reservado`; `disponible` es columna generada. |
| 5. OP no avanza sin cantidades | `eventos_proceso` exige entra/buenas/segundas/faltantes y `entra = buenas + segundas + faltantes`. |
| 6. Auditoría total | Trigger genérico → `auditoria` (tabla, id, antes, después, usuario, dispositivo, fecha). |
| 7. Transaccional | Toda operación que mueve inventario (confirmar corte, recepción, despacho, ajuste) es **una** función SQL; o todo o nada. |
| 8. Lotes de tintura | Validación en tablet y repetida en `confirmar_corte()`: mismo color con lote/tono distinto o ancho > tolerancia → requiere `corte_autorizaciones` del jefe de corte. |
| 9. Paquete = un color, lote y talla | El paquete tiene un único `color_id`, `talla_id`, `lote_tintura` (no son listas). |
| 10. Solo juegos completos | En combinada, el paso a confección exige `juego_id`; `armar_juegos()` solo crea juegos con todas las partes. |
| 11. Ficha aprobada congelada | Trigger impide modificar una `ficha_versiones` aprobada y todas sus tablas hijas; la OP guarda `ficha_version_id`. |

---

## 4. Convenciones

- PostgreSQL esquema `public`, nombres en español `snake_case` sin tildes.
- Ids `uuid` (v7 en eventos creados en dispositivos; `gen_random_uuid()` en el servidor).
- Códigos legibles: consecutivos del servidor (`OP-000123`). Lo que se crea **sin conexión**
  (paquetes al confirmar corte en mesa, por ejemplo) usa prefijo de estación:
  `PQ-C02-000451` → único sin preguntar al servidor.
- Dinero `numeric(14,2)` COP · cantidades `numeric(14,3)` · SAM `numeric(8,4)` minutos.
- Fechas `timestamptz` (se muestran en America/Bogota).
- Toda tabla maestra: `creado_en, creado_por, actualizado_en, actualizado_por, activo`
  (los maestros se *desactivan*, no se borran).
- Datos de ejemplo con prefijo/sufijo `EJEMPLO` para no confundirlos con reales.

---

## 5. Decisiones que necesito que elijas

1. **Sincronización:** (a) PowerSync Cloud ⭐ recomendado · (b) PowerSync autoalojado · (c) cola propia.
2. **Panel web y TV:** (a) en línea con caché local del último dato + Realtime ⭐ recomendado
   (más simple; cumple "muestra el último dato sin internet") · (b) también sin conexión completa con PowerSync web.
3. **Ingreso del operario:** (a) cuenta técnica por tablet + QR del carnet ⭐ recomendado ·
   (b) cuenta Supabase individual por operario (más gestión de usuarios, no aporta en planta).
4. **Telas:** (a) el maestro de tela es la base sin color (ej. "Jersey 30/1 algodón"); el color,
   lote y tono viven en el rollo; stock por tela + color ⭐ recomendado · (b) una referencia de tela por cada color.
5. **Empresa:** ¿una sola empresa/planta (sin multiempresa)? Recomiendo una sola, con `locaciones`
   para sedes y satélites.
6. **Cálculo oficial en servidor:** en funciones SQL (Postgres) ⭐ recomendado, probadas con los
   mismos vectores que Dart · alternativa: Edge Functions en TypeScript.

---

## 6. Pendientes de mi lado

- **No recibí las 12 capturas del diseño.** No son necesarias para aprobar esta fase, pero sí antes
  de la Fase 1 (pantallas de ingreso y menú). Adjúntalas cuando puedas.
- Esta sesión corre en un contenedor temporal en la nube y la carpeta **no es un repositorio git**.
  Para no perder el trabajo entre sesiones, conviene crear un repositorio en GitHub (privado) y
  conectarlo; a partir de la Fase 1 haré commit al final de cada fase.
- Herramientas: aquí no hay Flutter ni CLI de Supabase instalados; en la Fase 1 los instalo en el
  contenedor y el README explica la instalación en tu VS Code.
