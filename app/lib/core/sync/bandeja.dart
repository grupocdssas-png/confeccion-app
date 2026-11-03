import 'dart:convert';

import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

/// Estados de un evento en la bandeja de salida.
abstract final class EstadoEvento {
  static const pendiente = 'pendiente';
  static const sincronizado = 'sincronizado';
  static const rechazado = 'rechazado';
}

/// Registra eventos en la base local. Cada evento:
///  1. recibe un UUID v7 generado en la tablet y la hora del dispositivo,
///  2. se escribe en su tabla `insertOnly` (cola de subida) y en `bandeja`
///     dentro de la MISMA transacción (o se guardan ambos o ninguno).
/// Nada se borra hasta que el servidor confirme.
class Bandeja {
  Bandeja(this.db, {DateTime Function()? reloj}) : _reloj = reloj ?? DateTime.now;

  final PowerSyncDatabase db;
  final DateTime Function() _reloj;
  static const _uuid = Uuid();

  /// Devuelve el id del evento y si la hora del dispositivo retrocedió respecto
  /// al último evento (posible cambio manual de hora).
  Future<({String id, bool relojRetrocedio})> registrar({
    required String tabla,
    required Map<String, Object?> datos,
    required Map<String, Object?> resumen,
    String? empleadoId,
  }) async {
    final id = _uuid.v7();
    final ahora = _reloj().toUtc();
    final ocurrido = ahora.toIso8601String();
    final columnas = {...datos, 'ocurrido_en': ocurrido};
    var retrocedio = false;

    await db.writeTransaction((tx) async {
      final ultimo = await tx.getOptional('SELECT max(ocurrido_en) AS t FROM bandeja');
      final t = ultimo?['t'] as String?;
      if (t != null && DateTime.parse(t).difference(ahora) > const Duration(minutes: 1)) retrocedio = true;

      final nombres = columnas.keys.join(', ');
      final signos = List.filled(columnas.length, '?').join(', ');
      await tx.execute('INSERT INTO $tabla (id, $nombres) VALUES (?, $signos)', [id, ...columnas.values]);
      await tx.execute(
        'INSERT INTO bandeja (id, tabla, estado, resumen, empleado_id, ocurrido_en, intentos) VALUES (?, ?, ?, ?, ?, ?, 0)',
        [id, tabla, EstadoEvento.pendiente, jsonEncode(resumen), empleadoId, ocurrido],
      );
    });
    return (id: id, relojRetrocedio: retrocedio);
  }
}

/// Resumen para el indicador de sincronización.
class ResumenBandeja {
  const ResumenBandeja({required this.pendientes, required this.rechazados, this.pendienteMasAntiguo, this.ultimoSincronizado});
  final int pendientes;
  final int rechazados;
  final DateTime? pendienteMasAntiguo;
  final DateTime? ultimoSincronizado;

  bool pendientesViejos(DateTime ahora, Duration limite) =>
      pendienteMasAntiguo != null && ahora.toUtc().difference(pendienteMasAntiguo!) > limite;

  static Stream<ResumenBandeja> observar(PowerSyncDatabase db) => db.watch('''
        SELECT
          (SELECT count(*) FROM bandeja WHERE estado = 'pendiente') AS pendientes,
          (SELECT count(*) FROM bandeja WHERE estado = 'rechazado') AS rechazados,
          (SELECT min(ocurrido_en) FROM bandeja WHERE estado = 'pendiente') AS mas_antiguo,
          (SELECT max(sincronizado_en) FROM bandeja WHERE estado <> 'pendiente') AS ultimo
      ''').map((rs) {
        final r = rs.first;
        DateTime? f(Object? v) => v == null ? null : DateTime.parse(v as String);
        return ResumenBandeja(
          pendientes: r['pendientes'] as int,
          rechazados: r['rechazados'] as int,
          pendienteMasAntiguo: f(r['mas_antiguo']),
          ultimoSincronizado: f(r['ultimo']),
        );
      });
}
