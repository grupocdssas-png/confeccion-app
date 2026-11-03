import 'package:powersync/powersync.dart';

import 'bandeja.dart';

/// Envía un lote al servidor y devuelve su respuesta. En producción llama a la
/// RPC `ingerir_eventos` de Supabase; en pruebas se reemplaza por un simulador.
typedef EnviarLote = Future<Map<String, dynamic>> Function(Map<String, dynamic> lote);

/// Toma la cola de subida de PowerSync en orden, la manda en lotes a
/// `ingerir_eventos` y marca cada evento de la bandeja según la respuesta:
///  * aceptado / duplicado → sincronizado (el servidor ya lo tiene)
///  * rechazado            → rechazado, con motivo visible para el supervisor
/// Si el envío falla (sin red, error del servidor) se lanza la excepción, la
/// cola NO se toca y PowerSync reintenta más tarde.
class Subidor {
  Subidor({required this.db, required this.enviar, required this.versionApp, DateTime Function()? reloj})
      : _reloj = reloj ?? DateTime.now;

  final PowerSyncDatabase db;
  final EnviarLote enviar;
  final String versionApp;
  final DateTime Function() _reloj;

  /// Sube todo lo pendiente. Devuelve cuántos eventos se procesaron.
  Future<int> subirTodo() async {
    var total = 0;
    while (true) {
      final n = await subirLote();
      if (n == 0) return total;
      total += n;
    }
  }

  Future<int> subirLote({int limite = 100}) async {
    final lote = await db.getCrudBatch(limit: limite);
    if (lote == null) return 0;

    // El servidor identifica la tablet por su sesión: no hace falta haber descargado nada
    // (PowerSync no aplica descargas mientras haya pendientes por subir).
    final cuerpo = construirLote(lote.crud, horaDispositivo: _reloj().toUtc(), versionApp: versionApp);
    await db.execute(
      "UPDATE bandeja SET intentos = intentos + 1 WHERE id IN (SELECT value FROM json_each(?))",
      [_jsonIds(lote.crud)],
    );

    final respuesta = await enviar(cuerpo); // si falla, lanza y no se completa el lote
    await aplicarRespuesta(respuesta);
    await lote.complete();
    return lote.crud.length;
  }

  static Map<String, dynamic> construirLote(List<CrudEntry> crud,
          {required DateTime horaDispositivo, String? versionApp}) =>
      {
        'hora_dispositivo': horaDispositivo.toIso8601String(),
        'version_app': ?versionApp,
        'eventos': [
          for (final e in crud) {'id': e.id, 'tabla': e.table, 'op': e.op.toJson(), 'datos': e.opData ?? const {}},
        ],
      };

  Future<void> aplicarRespuesta(Map<String, dynamic> respuesta) async {
    final ahora = _reloj().toUtc().toIso8601String();
    final resultados = (respuesta['resultados'] as List).cast<Map<String, dynamic>>();
    await db.writeTransaction((tx) async {
      for (final r in resultados) {
        final rechazado = r['estado'] == 'rechazado';
        await tx.execute(
          'UPDATE bandeja SET estado = ?, motivo = ?, sincronizado_en = ? WHERE id = ?',
          [rechazado ? EstadoEvento.rechazado : EstadoEvento.sincronizado, r['motivo'], ahora, r['id']],
        );
      }
      final desfase = respuesta['desfase_reloj_s'];
      if (desfase != null) {
        await tx.execute("DELETE FROM ajustes_locales WHERE id = 'desfase_reloj_s'");
        await tx.execute("INSERT INTO ajustes_locales (id, valor) VALUES ('desfase_reloj_s', ?)", ['$desfase']);
      }
    });
  }

  static String _jsonIds(List<CrudEntry> crud) => '[${crud.map((e) => '"${e.id}"').join(',')}]';
}
