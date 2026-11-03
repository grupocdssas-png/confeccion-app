import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db_local/app_db.dart';
import '../../core/sync/proveedores_sync.dart';
import '../asistencia/repositorio_asistencia_planta.dart';

final miEstacionProvider = StreamProvider<EstacionLocal?>((ref) => ref.watch(appDbProvider).observarMiEstacion());

final repoAsistenciaProvider = Provider((ref) =>
    RepositorioAsistenciaPlanta(ref.watch(appDbProvider), ref.watch(powerSyncProvider), ref.watch(bandejaProvider)));

final recientesAsistenciaProvider =
    StreamProvider((ref) => ref.watch(appDbProvider).observarRecientes(tabla: 'asistencia_marcas', limite: 40));

/// Reloj que avanza cada segundo (encabezado y cálculos "hace X horas").
final relojProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now());
});

/// Desfase medido por el servidor en la última sincronización (segundos).
final desfaseRelojProvider = StreamProvider<int?>((ref) => ref
    .watch(powerSyncProvider)
    .watch("SELECT valor FROM ajustes_locales WHERE id = 'desfase_reloj_s'")
    .map((rs) => rs.isEmpty ? null : int.tryParse('${rs.first['valor']}')));
