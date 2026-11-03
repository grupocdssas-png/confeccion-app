import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

part 'app_db.g.dart';

// Las tablas reales las crea PowerSync (vistas sobre su almacenamiento JSON).
// Aquí solo se describen para tener consultas tipadas con drift.

@DataClassName('EmpleadoLocal')
class Empleados extends Table {
  TextColumn get id => text()();
  TextColumn get codigo => text().nullable()();
  TextColumn get nombres => text().nullable()();
  TextColumn get apellidos => text().nullable()();
  TextColumn get celulaId => text().named('celula_id').nullable()();
  TextColumn get qr => text().nullable()();
  TextColumn get fotoPath => text().named('foto_path').nullable()();
  IntColumn get activo => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('EstacionLocal')
class Estaciones extends Table {
  TextColumn get id => text()();
  TextColumn get codigo => text().nullable()();
  TextColumn get nombre => text().nullable()();
  TextColumn get tipo => text().nullable()();
  TextColumn get proceso => text().nullable()();
  TextColumn get celulaId => text().named('celula_id').nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('EventoBandeja')
class BandejaEventos extends Table {
  @override
  String get tableName => 'bandeja';
  TextColumn get id => text()();
  TextColumn get tabla => text().nullable()();
  TextColumn get estado => text().nullable()();
  TextColumn get resumen => text().nullable()();
  TextColumn get empleadoId => text().named('empleado_id').nullable()();
  TextColumn get ocurridoEn => text().named('ocurrido_en').nullable()();
  TextColumn get sincronizadoEn => text().named('sincronizado_en').nullable()();
  TextColumn get motivo => text().nullable()();
  IntColumn get intentos => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Empleados, Estaciones, BandejaEventos])
class AppDb extends _$AppDb {
  AppDb(PowerSyncDatabase db) : super(SqliteAsyncDriftConnection(db));

  @override
  int get schemaVersion => 1;

  // PowerSync administra el esquema: drift no crea ni migra nada.
  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {}, onUpgrade: (_, _, _) async {});

  Future<EmpleadoLocal?> empleadoPorQr(String qr) => (select(empleados)
        ..where((e) => e.qr.equals(qr.trim().toUpperCase()) & e.activo.equals(1)))
      .getSingleOrNull();

  Future<EmpleadoLocal?> empleadoPorId(String id) =>
      (select(empleados)..where((e) => e.id.equals(id))).getSingleOrNull();

  /// Mi estación: la del (único) dispositivo descargado para esta tablet.
  Stream<EstacionLocal?> observarMiEstacion() => customSelect(
        'SELECT e.* FROM estaciones e JOIN dispositivos d ON d.estacion_id = e.id LIMIT 1',
        readsFrom: {estaciones},
      ).watchSingleOrNull().map((r) => r == null ? null : estaciones.map(r.data));

  Stream<List<EventoBandeja>> observarRecientes({String? tabla, int limite = 30}) {
    final q = select(bandejaEventos)
      ..orderBy([(b) => OrderingTerm.desc(b.ocurridoEn)])
      ..limit(limite);
    if (tabla != null) q.where((b) => b.tabla.equals(tabla));
    return q.watch();
  }

  /// Último evento de asistencia de un empleado desde [desde] (para sugerir entrada o salida).
  Future<EventoBandeja?> ultimaAsistencia(String empleadoId, DateTime desde) => (select(bandejaEventos)
        ..where((b) =>
            b.tabla.equals('asistencia_marcas') &
            b.empleadoId.equals(empleadoId) &
            b.ocurridoEn.isBiggerOrEqualValue(desde.toUtc().toIso8601String()))
        ..orderBy([(b) => OrderingTerm.desc(b.ocurridoEn)])
        ..limit(1))
      .getSingleOrNull();
}
