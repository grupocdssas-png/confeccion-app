import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../../core/calculos/calidad.dart';
import '../../core/sync/bandeja.dart';
import '../../core/sync/proveedores_sync.dart';
import '../modulo/repositorio_modulo.dart';

class DefectoLocal {
  DefectoLocal(this.f);
  final Map<String, Object?> f;
  String get id => f['id'] as String;
  String get codigo => '${f['codigo']}';
  String get nombre => '${f['nombre']}';
  String? get proceso => f['proceso'] as String?;
  String get severidad => '${f['severidad'] ?? 'mayor'}';
}

class MedidaLocal {
  MedidaLocal(this.f);
  final Map<String, Object?> f;
  String get id => f['id'] as String;
  String get punto => '${f['punto_medida']}';
  double get valor => (f['valor_cm'] as num).toDouble();
  double get tolerancia => (f['tolerancia_cm'] as num).toDouble();
}

/// Operación de la ficha (de cualquier proceso) para atribuir un defecto.
class OperacionFicha {
  OperacionFicha(this.f);
  final Map<String, Object?> f;
  String get id => f['id'] as String;
  String get nombre => '${f['nombre'] ?? f['codigo'] ?? ''}';
  String get proceso => '${f['proceso']}';
  int get secuencia => (f['secuencia'] as num?)?.toInt() ?? 0;
}

class DevolucionLocal {
  DevolucionLocal(this.f, this.defecto, this.operacion, this.empleado);
  final Map<String, Object?> f;
  final String defecto;
  final String? operacion;
  final String? empleado;
  String get id => f['id'] as String;
  String get alcance => '${f['alcance']}';
  int get cantidad => (f['cantidad'] as num).toInt();
  int get reprocesadas => (f['reprocesadas'] as num?)?.toInt() ?? 0;
  String? get fichaOperacionId => f['ficha_operacion_id'] as String?;
  String? get empleadoId => f['empleado_id'] as String?;
  String? get celulaId => f['celula_id'] as String?;
  int get pendientes => cantidad - reprocesadas;
}

/// Última auditoría final de una unidad (de esta tablet o bajada del servidor)
class AuditoriaLocal {
  const AuditoriaLocal({required this.id, required this.resultado, required this.hora, required this.defectuosas, required this.muestra, this.pendiente = false});
  final String id;
  final String resultado;
  final DateTime hora;
  final int defectuosas;
  final int muestra;
  final bool pendiente; // aún no sube
  bool get aprobada => resultado == 'aprobado';
}

/// Línea de defecto que anota el inspector
class LineaDefecto {
  LineaDefecto(this.defecto, {this.operacion, this.cantidad = 1});
  final DefectoLocal defecto;
  OperacionFicha? operacion;
  int cantidad;
}

class RepositorioCalidad {
  RepositorioCalidad(this._db, this._bandeja);
  final PowerSyncDatabase _db;
  final Bandeja _bandeja;

  Future<List<DefectoLocal>> defectos() async =>
      [for (final f in await _db.getAll('SELECT * FROM defectos ORDER BY nombre')) DefectoLocal(f)];

  /// Plan de muestreo por defecto. Si la tablet aún no lo tiene, el de la norma (el mismo del servidor).
  Future<List<TramoMuestreo>> plan() async {
    final f = await _db.getOptional('SELECT tabla FROM planes_muestreo ORDER BY por_defecto DESC LIMIT 1');
    if (f == null) return planPorDefecto;
    return [for (final t in (jsonDecode(f['tabla'] as String) as List).cast<Map<String, dynamic>>()) TramoMuestreo.fromJson(t)];
  }

  Future<List<MedidaLocal>> medidas(String fichaId, String? tallaId) async => [
        for (final f in await _db.getAll('''
          SELECT m.id, m.punto_medida, mt.valor_cm, mt.tolerancia_cm FROM ficha_medidas m
          JOIN ficha_medida_tallas mt ON mt.medida_id = m.id
          WHERE m.ficha_id = ? AND mt.talla_id = ? ORDER BY m.orden''', [fichaId, tallaId]))
          MedidaLocal(f),
      ];

  Future<List<OperacionFicha>> operacionesFicha(String fichaId) async => [
        for (final f in await _db.getAll('''
          SELECT fo.id, fo.proceso, fo.secuencia, op.codigo, op.nombre FROM ficha_operaciones fo
          LEFT JOIN operaciones op ON op.id = fo.operacion_id WHERE fo.ficha_id = ? ORDER BY fo.secuencia''', [fichaId]))
          OperacionFicha(f),
      ];

  Future<String?> tallaId(String unidadId) async => (await _db.getOptional(
          'SELECT talla_id FROM paquetes WHERE id = ? UNION ALL SELECT talla_id FROM juegos WHERE id = ? LIMIT 1', [unidadId, unidadId]))?['talla_id']
      as String?;

  /// Devoluciones abiertas de una unidad (las que esta tablet ya cerró no salen)
  Future<List<DevolucionLocal>> devoluciones(String unidadId, {String? celulaId}) async {
    final filas = await _db.getAll('''
      SELECT d.*, df.nombre AS defecto, op.nombre AS operacion, e.nombres || ' ' || e.apellidos AS empleado FROM devoluciones_calidad d
      LEFT JOIN defectos df ON df.id = d.defecto_id
      LEFT JOIN ficha_operaciones fo ON fo.id = d.ficha_operacion_id
      LEFT JOIN operaciones op ON op.id = fo.operacion_id
      LEFT JOIN empleados e ON e.id = d.empleado_id
      WHERE d.estado = 'abierta' AND (d.paquete_id = ? OR d.juego_id = ?) AND (? IS NULL OR d.celula_id = ?)
        AND NOT EXISTS (SELECT 1 FROM bandeja b WHERE b.tabla = 'devolucion_cierres' AND b.estado <> 'rechazado'
                        AND json_extract(b.resumen, '\$.devolucion_id') = d.id)
      ORDER BY d.id''', [unidadId, unidadId, celulaId, celulaId]);
    return [for (final f in filas) DevolucionLocal(f, '${f['defecto'] ?? ''}', f['operacion'] as String?, f['empleado'] as String?)];
  }

  /// Última auditoría final vigente: la más reciente entre las de esta tablet y las del servidor.
  Future<AuditoriaLocal?> ultimaAuditoria(String unidadId) async {
    final anuladas = {
      for (final f in await _db.getAll("SELECT anula_id FROM auditorias WHERE tipo = 'anulacion'")) f['anula_id'],
      for (final f in await _db.getAll("SELECT json_extract(resumen, '\$.anula_id') AS a FROM bandeja WHERE tabla = 'inspecciones' AND estado <> 'rechazado'"))
        f['a'],
    };
    final xs = <AuditoriaLocal>[
      for (final f in await _db.getAll(
          "SELECT * FROM auditorias WHERE tipo = 'auditoria_final' AND (paquete_id = ? OR juego_id = ?)", [unidadId, unidadId]))
        if (!anuladas.contains(f['id']))
          AuditoriaLocal(id: f['id'] as String, resultado: '${f['resultado']}', hora: DateTime.parse(f['ocurrido_en'] as String),
              defectuosas: (f['defectuosas'] as num?)?.toInt() ?? 0, muestra: (f['tamano_muestra'] as num?)?.toInt() ?? 0),
      for (final f in await _db.getAll('''
          SELECT id, resumen, ocurrido_en, estado FROM bandeja WHERE tabla = 'inspecciones' AND estado <> 'rechazado'
            AND json_extract(resumen, '\$.tipo') = 'auditoria_final' AND json_extract(resumen, '\$.unidad_id') = ?''', [unidadId]))
        if (!anuladas.contains(f['id']))
          () {
            final r = jsonDecode(f['resumen'] as String) as Map<String, dynamic>;
            return AuditoriaLocal(id: f['id'] as String, resultado: '${r['resultado']}', hora: DateTime.parse(f['ocurrido_en'] as String),
                defectuosas: (r['defectuosas'] as num).toInt(), muestra: (r['muestra'] as num).toInt(), pendiente: f['estado'] == 'pendiente');
          }(),
    ];
    // el mismo evento puede estar en la bandeja y ya bajado del servidor
    final porId = {for (final a in xs) a.id: a};
    final l = porId.values.toList()..sort((a, b) => b.hora.compareTo(a.hora));
    return l.firstOrNull;
  }

  /// Registra una inspección. Devuelve el resultado calculado aquí (el servidor aplica la misma regla).
  Future<({String id, String resultado, int defectuosas, int muestra, int? acepta})> inspeccionar({
    required UnidadLocal unidad,
    required String tipo, // en_proceso | auditoria_final
    required String inspectorId,
    required List<LineaDefecto> lineas,
    Map<String, double> medidas = const {},
    List<MedidaLocal> fichaMedidas = const [],
    int? muestraEnProceso,
    String alcance = 'individual',
    String? observacion,
  }) async {
    final lote = unidad.cantidad;
    final p = await plan();
    final m = tipo == 'auditoria_final' ? muestreo(p, lote) : (muestra: (muestraEnProceso ?? lote).clamp(1, lote), acepta: null);
    final fuera = fichaMedidas.any((x) => medidas[x.id] != null && medidaFuera(medidas[x.id]!, x.valor, x.tolerancia));
    final defectuosas = prendasConDefecto(lineas.map((l) => l.cantidad),
        medidaFueraDeTolerancia: fuera, yaAnotoMedida: lineas.any((l) => l.defecto.codigo == 'MED'));
    if (defectuosas > m.muestra) throw ArgumentError('Hay más prendas con defecto ($defectuosas) que revisadas (${m.muestra})');
    final resultado = tipo == 'auditoria_final'
        ? (defectuosas <= m.acepta! ? 'aprobado' : 'rechazado')
        : (defectuosas == 0 ? 'aprobado' : 'rechazado');
    final r = await _bandeja.registrar(
      tabla: 'inspecciones',
      datos: {
        'tipo': tipo,
        'unidad_id': unidad.id,
        'inspector_id': inspectorId,
        'tamano_muestra': m.muestra,
        'alcance': alcance,
        'observacion': observacion,
        'defectos': jsonEncode([
          for (final l in lineas) {'defecto_id': l.defecto.id, 'cantidad': l.cantidad, 'ficha_operacion_id': ?l.operacion?.id},
        ]),
        'medidas': jsonEncode([
          for (final e in medidas.entries) {'medida_id': e.key, 'valor_cm': e.value},
        ]),
      },
      resumen: {
        'tipo': tipo, 'unidad_id': unidad.id, 'unidad': unidad.codigo, 'resultado': resultado, 'defectuosas': defectuosas,
        'muestra': m.muestra, 'acepta': m.acepta, 'alcance': resultado == 'rechazado' ? alcance : null,
        'defectos': [for (final l in lineas) '${l.cantidad} ${l.defecto.nombre}${l.operacion != null ? ' (${l.operacion!.nombre})' : ''}'],
      },
      empleadoId: inspectorId,
    );
    return (id: r.id, resultado: resultado, defectuosas: defectuosas, muestra: m.muestra, acepta: m.acepta);
  }

  Future<void> anular(String inspeccionId, String inspectorId, String motivo) => _bandeja.registrar(
        tabla: 'inspecciones',
        datos: {'tipo': 'anulacion', 'anula_id': inspeccionId, 'motivo': motivo, 'inspector_id': inspectorId},
        resumen: {'tipo': 'anulacion', 'anula_id': inspeccionId, 'motivo': motivo},
        empleadoId: inspectorId,
      );

  Future<void> cerrarDevolucion(DevolucionLocal d, {required int reprocesadas, required int segundas, String? inspectorId}) {
    if (reprocesadas + segundas != d.cantidad) throw ArgumentError('Deben sumar ${d.cantidad}');
    return _bandeja.registrar(
      tabla: 'devolucion_cierres',
      datos: {'devolucion_id': d.id, 'reprocesadas': reprocesadas, 'segundas': segundas, 'empleado_id': inspectorId},
      resumen: {'devolucion_id': d.id, 'defecto': d.defecto, 'reprocesadas': reprocesadas, 'segundas': segundas},
      empleadoId: inspectorId,
    );
  }

  /// Inspecciones de hoy hechas en esta tablet (para revisar o anular)
  Future<List<({String id, Map<String, dynamic> r, DateTime hora, String estado})>> recientes({int limite = 8}) async => [
        for (final f in await _db.getAll('''
          SELECT id, resumen, ocurrido_en, estado FROM bandeja WHERE tabla = 'inspecciones'
            AND json_extract(resumen, '\$.tipo') <> 'anulacion' ORDER BY ocurrido_en DESC LIMIT ?''', [limite]))
          (id: f['id'] as String, r: jsonDecode(f['resumen'] as String) as Map<String, dynamic>, hora: DateTime.parse(f['ocurrido_en'] as String),
           estado: '${f['estado']}'),
      ];
}

/// ISO 2859-1 nivel II, AQL 2,5 (igual al plan por defecto del servidor)
const planPorDefecto = [
  TramoMuestreo(desde: 1, hasta: 1, muestra: 1, acepta: 0),
  TramoMuestreo(desde: 2, hasta: 50, muestra: 5, acepta: 0),
  TramoMuestreo(desde: 51, hasta: 150, muestra: 20, acepta: 1),
  TramoMuestreo(desde: 151, hasta: 280, muestra: 32, acepta: 2),
  TramoMuestreo(desde: 281, hasta: 500, muestra: 50, acepta: 3),
  TramoMuestreo(desde: 501, hasta: 1200, muestra: 80, acepta: 5),
  TramoMuestreo(desde: 1201, hasta: 3200, muestra: 125, acepta: 7),
  TramoMuestreo(desde: 3201, hasta: 10000, muestra: 200, acepta: 10),
  TramoMuestreo(desde: 10001, hasta: 35000, muestra: 315, acepta: 14),
  TramoMuestreo(desde: 35001, muestra: 500, acepta: 21),
];

final repositorioCalidadProvider = Provider<RepositorioCalidad>((ref) => RepositorioCalidad(ref.watch(powerSyncProvider), ref.watch(bandejaProvider)));
