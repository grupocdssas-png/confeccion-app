import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart';

import '../../core/db_local/app_db.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/bandeja.dart';

/// Normaliza lo que se escanea o digita: "OPR-0001", "opr-1", "0001", "1" → OPR-0001.
/// Si empieza por "E" (E001) se busca por código de empleado.
({String? qr, String? codigo}) normalizarCodigoCarnet(String entrada) {
  final t = entrada.trim().toUpperCase().replaceAll(' ', '');
  if (t.isEmpty) return (qr: null, codigo: null);
  final m = RegExp(r'^(?:OPR-?)?(\d{1,6})$').firstMatch(t);
  if (m != null) return (qr: 'OPR-${m.group(1)!.padLeft(4, '0')}', codigo: null);
  if (t.startsWith('OPR-')) return (qr: t, codigo: null);
  return (qr: null, codigo: t);
}

class RepositorioAsistenciaPlanta {
  RepositorioAsistenciaPlanta(this._db, this._ps, this._bandeja);
  final AppDb _db;
  final PowerSyncDatabase _ps;
  final Bandeja _bandeja;

  Future<EmpleadoLocal?> buscar(String entrada) async {
    final n = normalizarCodigoCarnet(entrada);
    if (n.qr != null) return _db.empleadoPorQr(n.qr!);
    if (n.codigo != null) {
      return (_db.select(_db.empleados)..where((e) => e.codigo.equals(n.codigo!) & e.activo.equals(1))).getSingleOrNull();
    }
    return null;
  }

  /// Última marca vigente (no anulada) del empleado hoy, según lo registrado en esta tablet.
  Future<({String tipo, DateTime hora})?> ultimaMarcaHoy(String empleadoId, {DateTime? ahora}) async {
    final r = await _ps.getOptional('''
      SELECT json_extract(b.resumen, '\$.tipo') AS tipo, b.ocurrido_en
      FROM bandeja b
      WHERE b.tabla = 'asistencia_marcas' AND b.empleado_id = ? AND b.ocurrido_en >= ?
        AND b.estado <> 'rechazado'
        AND json_extract(b.resumen, '\$.tipo') IN ('entrada', 'salida')
        AND b.id NOT IN (
          SELECT json_extract(a.resumen, '\$.anula_id') FROM bandeja a
          WHERE a.tabla = 'asistencia_marcas' AND json_extract(a.resumen, '\$.tipo') = 'anulacion' AND a.estado <> 'rechazado')
      ORDER BY b.ocurrido_en DESC LIMIT 1''', [empleadoId, Formato.inicioDiaBogota(ahora).toIso8601String()]);
    if (r == null) return null;
    return (tipo: r['tipo'] as String, hora: DateTime.parse(r['ocurrido_en'] as String));
  }

  /// Si la última marca de hoy fue entrada, se sugiere salida; si no, entrada.
  Future<String> sugerirTipo(String empleadoId, {DateTime? ahora}) async =>
      (await ultimaMarcaHoy(empleadoId, ahora: ahora))?.tipo == 'entrada' ? 'salida' : 'entrada';

  Future<({String id, bool relojRetrocedio})> registrar(EmpleadoLocal e, String tipo) => _bandeja.registrar(
        tabla: 'asistencia_marcas',
        datos: {'empleado_id': e.id, 'tipo': tipo},
        resumen: {'tipo': tipo, 'nombre': '${e.nombres} ${e.apellidos}', 'codigo': e.codigo},
        empleadoId: e.id,
      );

  Future<void> anular(EventoBandeja evento, String motivo) async {
    final r = jsonDecode(evento.resumen ?? '{}') as Map<String, dynamic>;
    await _bandeja.registrar(
      tabla: 'asistencia_marcas',
      datos: {'empleado_id': evento.empleadoId, 'tipo': 'anulacion', 'anula_id': evento.id, 'motivo': motivo.trim()},
      resumen: {'tipo': 'anulacion', 'anula_id': evento.id, 'nombre': r['nombre'], 'codigo': r['codigo'], 'motivo': motivo.trim()},
      empleadoId: evento.empleadoId,
    );
  }
}
