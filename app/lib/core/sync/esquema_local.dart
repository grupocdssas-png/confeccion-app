import 'package:powersync/powersync.dart';

/// Esquema de la base local (SQLite) de la app de planta.
///
/// * Tablas sincronizadas (bajan del servidor según sync/sync-rules.yaml).
/// * Tablas de eventos `insertOnly`: lo que se inserta va directo a la cola de
///   subida de PowerSync (no se lee de ellas).
/// * `bandeja` (solo local): copia legible de cada evento con su estado
///   (pendiente / sincronizado / rechazado). Es lo que ve el operario y lo que
///   alimenta el indicador "Sin conexión · N pendientes".
const esquemaLocal = Schema([
  // --- Maestros que bajan ---
  Table('parametros', [Column.text('valor')]),
  Table('procesos', [Column.text('nombre'), Column.text('color_hex'), Column.integer('orden')]),
  Table('celulas', [
    Column.text('codigo'), Column.text('nombre'), Column.text('proceso'), Column.text('turno_id'), Column.integer('activo'),
  ]),
  Table('empleados', [
    Column.text('codigo'), Column.text('nombres'), Column.text('apellidos'), Column.text('celula_id'),
    Column.text('qr'), Column.text('foto_path'), Column.integer('activo'),
  ], indexes: [Index('por_qr', [IndexedColumn('qr')])]),
  Table('turnos', [
    Column.text('nombre'), Column.text('hora_inicio'), Column.text('hora_fin'), Column.integer('cruza_medianoche'), Column.integer('activo'),
  ]),
  Table('festivos', [Column.text('nombre')]),
  Table('tallas', [Column.text('codigo'), Column.integer('orden'), Column.integer('activo')]),
  Table('colores', [Column.text('codigo'), Column.text('nombre'), Column.text('hex'), Column.integer('activo')]),
  Table('estaciones', [
    Column.text('codigo'), Column.text('nombre'), Column.text('tipo'), Column.text('proceso'),
    Column.text('celula_id'), Column.text('bodega_id'), Column.text('impresora_id'),
  ]),
  // --- Inventario (Fase 2) ---
  Table('materiales', [
    Column.text('codigo'), Column.text('tipo'), Column.text('nombre'), Column.text('unidad'),
    Column.integer('maneja_color'), Column.integer('activo'),
  ]),
  Table('proveedores', [Column.text('nombre')]),
  Table('bodegas', [Column.text('codigo'), Column.text('nombre'), Column.text('tipo')]),
  Table('ubicaciones', [Column.text('bodega_id'), Column.text('codigo'), Column.text('descripcion'), Column.integer('activo')],
      indexes: [Index('ubic_codigo', [IndexedColumn('codigo')])]),
  Table('rollos', [
    Column.text('codigo'), Column.text('material_id'), Column.text('color_id'), Column.text('proveedor_id'),
    Column.text('lote_tintura'), Column.text('tono'), Column.real('ancho_real_cm'),
    Column.real('metros_saldo'), Column.real('kilos_saldo'), Column.text('bodega_id'), Column.text('ubicacion_id'),
    Column.text('estado'), Column.integer('es_retazo'), Column.text('fecha_ingreso'),
  ], indexes: [Index('rollo_codigo', [IndexedColumn('codigo')])]),
  Table('conteos_fisicos', [
    Column.text('consecutivo'), Column.text('bodega_id'), Column.text('ubicacion_id'), Column.text('alcance'), Column.text('estado'),
  ]),
  Table('impresoras', [
    Column.text('nombre'), Column.text('modelo'), Column.text('conexion'), Column.text('ip'), Column.integer('puerto'),
  ]),
  Table('plantillas_etiqueta', [Column.text('tipo'), Column.text('tamano'), Column.text('zpl'), Column.integer('version')]),
  Table('dispositivos', [Column.text('estacion_id'), Column.text('nombre'), Column.text('tipo')]),

  // --- Producción para la tablet del módulo (Fase 6) ---
  Table('ordenes_produccion', [
    Column.text('consecutivo'), Column.text('referencia_id'), Column.text('ficha_version_id'), Column.text('estado'),
    Column.text('proceso_actual'), Column.integer('cantidad_total'),
  ]),
  Table('referencias', [Column.text('codigo'), Column.text('nombre')]),
  Table('operaciones', [
    Column.text('codigo'), Column.text('nombre'), Column.integer('unidades_marcacion'), Column.integer('permite_cambiar_unidades'),
    Column.integer('sin_talla_color'),
  ]),
  Table('ficha_operaciones', [
    Column.text('ficha_id'), Column.integer('secuencia'), Column.text('operacion_id'), Column.text('proceso'), Column.real('sam'),
    Column.real('sam_reproceso'), Column.real('repeticiones'), Column.integer('es_contadora'), Column.integer('unidades_marcacion'),
    Column.integer('permite_cambiar_unidades'),
  ], indexes: [Index('fo_ficha', [IndexedColumn('ficha_id'), IndexedColumn('proceso')])]),
  Table('ficha_combinaciones', [Column.text('ficha_id'), Column.text('codigo'), Column.text('nombre')]),
  Table('paquetes', [
    Column.text('codigo'), Column.text('op_id'), Column.text('color_id'), Column.text('talla_id'), Column.text('lote_tintura'),
    Column.integer('cantidad'), Column.integer('cantidad_actual'), Column.text('estado'), Column.text('proceso_actual'), Column.text('celula_id'),
  ], indexes: [Index('paquete_codigo', [IndexedColumn('codigo')])]),
  Table('juegos', [
    Column.text('codigo'), Column.text('op_id'), Column.text('combinacion_id'), Column.text('color_id'), Column.text('talla_id'),
    Column.integer('cantidad'), Column.integer('cantidad_actual'), Column.text('estado'), Column.text('proceso_actual'), Column.text('celula_id'),
  ], indexes: [Index('juego_codigo', [IndexedColumn('codigo')])]),
  Table('eficiencia_diaria', [
    Column.text('empleado_id'), Column.text('fecha'), Column.integer('unidades'), Column.integer('reprocesos'),
    Column.real('minutos_esperados'), Column.real('minutos_reales'),
  ], indexes: [Index('ef_empleado', [IndexedColumn('empleado_id'), IndexedColumn('fecha')])]),

  // --- Eventos que suben (solo se agregan) ---
  Table.insertOnly('asistencia_marcas', [
    Column.text('empleado_id'), Column.text('tipo'), Column.text('anula_id'), Column.text('motivo'), Column.text('ocurrido_en'),
  ]),

  Table.insertOnly('conteo_registros', [
    Column.text('conteo_id'), Column.text('rollo_id'), Column.text('material_id'), Column.text('color_id'),
    Column.text('ubicacion_id'), Column.real('cantidad'), Column.text('anula_id'), Column.text('ocurrido_en'),
  ]),
  Table.insertOnly('traslados_rollo', [
    Column.text('rollo_id'), Column.text('ubicacion_destino_id'), Column.text('ocurrido_en'),
  ]),
  Table.insertOnly('trabajos_impresion', [
    Column.text('impresora_id'), Column.text('plantilla_id'), Column.integer('plantilla_version'), Column.text('entidad'),
    Column.text('entidad_id'), Column.text('codigo'), Column.text('medio'), Column.integer('es_reimpresion'),
    Column.text('motivo'), Column.text('estado_final'), Column.integer('intentos'), Column.text('ocurrido_en'),
  ]),

  Table.insertOnly('marcaciones', [
    Column.text('empleado_id'), Column.text('unidad_id'), Column.text('ficha_operacion_id'), Column.integer('unidades'),
    Column.text('tipo'), Column.text('anula_id'), Column.text('motivo'), Column.text('ocurrido_en'),
  ]),
  Table.insertOnly('eventos_unidad', [
    Column.text('unidad_id'), Column.text('tipo'), Column.integer('buenas'), Column.integer('segundas'), Column.integer('faltantes'),
    Column.text('empleado_id'), Column.text('observacion'), Column.text('ocurrido_en'),
  ]),

  // --- Solo locales ---
  Table.localOnly('bandeja', [
    Column.text('tabla'),
    Column.text('estado'), // pendiente | sincronizado | rechazado
    Column.text('resumen'), // JSON legible para pantallas
    Column.text('empleado_id'),
    Column.text('ocurrido_en'), // hora del dispositivo (UTC ISO-8601)
    Column.text('sincronizado_en'),
    Column.text('motivo'),
    Column.integer('intentos'),
  ], indexes: [
    Index('por_estado', [IndexedColumn('estado'), IndexedColumn('ocurrido_en')]),
    Index('por_empleado', [IndexedColumn('empleado_id'), IndexedColumn('ocurrido_en')]),
  ]),
  Table.localOnly('ajustes_locales', [Column.text('valor')]), // id = clave
  Table.localOnly('cola_impresion', [
    Column.text('impresora_id'), Column.text('impresora_nombre'), Column.text('ip'), Column.integer('puerto'),
    Column.text('zpl'), Column.text('entidad'), Column.text('entidad_id'), Column.text('codigo'),
    Column.text('plantilla_id'), Column.integer('plantilla_version'), Column.integer('es_reimpresion'), Column.text('motivo'),
    Column.text('estado'), // pendiente | enviado
    Column.integer('intentos'), Column.text('error'), Column.text('creado_en'), Column.text('proximo_intento'),
    Column.text('enviado_en'),
  ], indexes: [Index('cola_estado', [IndexedColumn('estado'), IndexedColumn('creado_en')])]),
]);
