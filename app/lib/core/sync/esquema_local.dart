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
    Column.text('celula_id'), Column.text('bodega_id'),
  ]),
  Table('dispositivos', [Column.text('estacion_id'), Column.text('nombre'), Column.text('tipo')]),

  // --- Eventos que suben (solo se agregan) ---
  Table.insertOnly('asistencia_marcas', [
    Column.text('empleado_id'), Column.text('tipo'), Column.text('anula_id'), Column.text('motivo'), Column.text('ocurrido_en'),
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
]);
