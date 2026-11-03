import 'dart:async';
import 'dart:math';

import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

import '../sync/bandeja.dart';
import 'transporte.dart';

typedef EnviarZpl = Future<void> Function(String host, int puerto, String zpl);

class ImpresoraLocal {
  const ImpresoraLocal({required this.id, required this.nombre, required this.conexion, this.ip, this.puerto = 9100});
  final String id, nombre, conexion;
  final String? ip;
  final int puerto;
}

/// Cola local de impresión (tablets y celulares de planta).
///  * Cada etiqueta se guarda primero en la base local: nunca se pierde.
///  * Se envía a la Zebra por TCP; si falla, reintenta con espera creciente
///    (5 s, 10 s, 20 s… hasta 5 min) y muestra el error.
///  * Al imprimirse, se registra el trabajo (evento) para el servidor.
class ColaImpresion {
  ColaImpresion(this.db, this.bandeja, {EnviarZpl? enviar, DateTime Function()? reloj})
      : _enviar = enviar ?? ((h, p, z) => enviarZplTcp(h, p, z)),
        _reloj = reloj ?? DateTime.now;

  final PowerSyncDatabase db;
  final Bandeja bandeja;
  final EnviarZpl _enviar;
  final DateTime Function() _reloj;
  static const _uuid = Uuid();
  Future<int>? _enCurso;

  Future<String> encolar({
    required ImpresoraLocal impresora,
    required String zpl,
    required String entidad,
    String? entidadId,
    required String codigo,
    String? plantillaId,
    int? plantillaVersion,
    bool esReimpresion = false,
    String? motivo,
  }) async {
    if (esReimpresion && (motivo == null || motivo.trim().isEmpty)) {
      throw ArgumentError('Una reimpresión necesita motivo');
    }
    if (impresora.conexion != 'tcp' || impresora.ip == null) {
      throw UnsupportedError('La impresora ${impresora.nombre} no está configurada por red (TCP).');
    }
    final id = _uuid.v7();
    final ahora = _reloj().toUtc().toIso8601String();
    await db.execute('''
      INSERT INTO cola_impresion (id, impresora_id, impresora_nombre, ip, puerto, zpl, entidad, entidad_id, codigo,
        plantilla_id, plantilla_version, es_reimpresion, motivo, estado, intentos, creado_en, proximo_intento)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pendiente', 0, ?, ?)''', [
      id, impresora.id, impresora.nombre, impresora.ip, impresora.puerto, zpl, entidad, entidadId, codigo,
      plantillaId, plantillaVersion, esReimpresion ? 1 : 0, motivo, ahora, ahora,
    ]);
    unawaited(procesar());
    return id;
  }

  /// Envía lo pendiente en orden de llegada. Devuelve cuántas se imprimieron.
  /// Si ya hay un envío en curso, espera a que termine y vuelve a revisar.
  Future<int> procesar() async {
    while (_enCurso != null) {
      await _enCurso;
    }
    final f = _procesar();
    _enCurso = f;
    try {
      return await f;
    } finally {
      _enCurso = null;
    }
  }

  Future<int> _procesar() async {
    var impresas = 0;
    {
      final ahora = _reloj().toUtc();
      final pendientes = await db.getAll(
          "SELECT * FROM cola_impresion WHERE estado = 'pendiente' AND proximo_intento <= ? ORDER BY creado_en, id",
          [ahora.toIso8601String()]);
      for (final t in pendientes) {
        final intentos = (t['intentos'] as int) + 1;
        try {
          await _enviar(t['ip'] as String, t['puerto'] as int, t['zpl'] as String);
        } catch (e) {
          final espera = Duration(seconds: min(300, 5 * pow(2, intentos - 1).toInt()));
          await db.execute(
            'UPDATE cola_impresion SET intentos = ?, error = ?, proximo_intento = ? WHERE id = ?',
            [intentos, _mensaje(e), ahora.add(espera).toIso8601String(), t['id']],
          );
          // Si la impresora no responde, las siguientes de la misma impresora esperan su turno
          continue;
        }
        await db.execute(
          "UPDATE cola_impresion SET estado = 'enviado', intentos = ?, error = NULL, enviado_en = ? WHERE id = ?",
          [intentos, _reloj().toUtc().toIso8601String(), t['id']],
        );
        await bandeja.registrar(
          tabla: 'trabajos_impresion',
          datos: {
            'impresora_id': t['impresora_id'],
            'plantilla_id': t['plantilla_id'],
            'plantilla_version': t['plantilla_version'],
            'entidad': t['entidad'],
            'entidad_id': t['entidad_id'],
            'codigo': t['codigo'],
            'medio': 'tcp',
            'es_reimpresion': t['es_reimpresion'] == 1,
            'motivo': t['motivo'],
            'estado_final': 'enviado',
            'intentos': intentos,
          },
          resumen: {'codigo': t['codigo'], 'impresora': t['impresora_nombre'], 'reimpresion': t['es_reimpresion'] == 1},
        );
        impresas++;
      }
    }
    return impresas;
  }

  /// "Reintentar ahora" desde la pantalla de la cola.
  Future<void> reintentarYa() async {
    await db.execute("UPDATE cola_impresion SET proximo_intento = ? WHERE estado = 'pendiente'",
        [_reloj().toUtc().toIso8601String()]);
    await procesar();
  }

  static String _mensaje(Object e) {
    final s = '$e';
    if (s.contains('Connection refused') || s.contains('timed out') || s.contains('No route')) {
      return 'La impresora no responde. Revise que esté encendida y en la misma red wifi.';
    }
    return s.length > 160 ? s.substring(0, 160) : s;
  }
}
