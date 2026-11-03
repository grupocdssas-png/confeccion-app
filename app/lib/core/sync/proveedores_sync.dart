import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';

import '../config/config.dart';
import '../db_local/app_db.dart';
import 'bandeja.dart';
import 'conector.dart';
import 'esquema_local.dart';

/// Abre la base local de la planta (persiste entre cierres y reinicios).
/// En el navegador (vista previa de la app de planta) usa almacenamiento del navegador.
Future<PowerSyncDatabase> abrirBaseLocal() async {
  final ruta = kIsWeb ? 'planta.db' : '${(await getApplicationSupportDirectory()).path}/planta.db';
  final db = PowerSyncDatabase(schema: esquemaLocal, path: ruta);
  await db.initialize();
  return db;
}

/// Se sobreescribe en main_planta una vez abierta la base.
final powerSyncProvider = Provider<PowerSyncDatabase>((ref) => throw UnimplementedError('Abrir la base local primero'));
final appDbProvider = Provider<AppDb>((ref) {
  final db = AppDb(ref.watch(powerSyncProvider));
  ref.onDispose(db.close);
  return db;
});
final bandejaProvider = Provider<Bandeja>((ref) => Bandeja(ref.watch(powerSyncProvider)));

/// Conecta con PowerSync (descarga + subida). Sin red, reintenta solo.
Future<void> conectarSincronizacion(PowerSyncDatabase db) async {
  if (!Config.tienePowerSync) return;
  await db.connect(connector: ConectorSupabase(db));
}

final estadoSyncProvider = StreamProvider<SyncStatus>((ref) => ref.watch(powerSyncProvider).statusStream);
final resumenBandejaProvider = StreamProvider<ResumenBandeja>((ref) => ResumenBandeja.observar(ref.watch(powerSyncProvider)));

/// Parámetro numérico descargado (tabla parametros), con valor por defecto.
final parametroProvider = StreamProvider.family<double?, String>((ref, clave) => ref
    .watch(powerSyncProvider)
    .watch('SELECT valor FROM parametros WHERE id = ?', parameters: [clave])
    .map((rs) => rs.isEmpty ? null : double.tryParse('${rs.first['valor']}')));
