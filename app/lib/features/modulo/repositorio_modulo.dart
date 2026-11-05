import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../../core/calculos/eficiencia.dart';
import '../../core/escaneo/codigos.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/bandeja.dart';
import '../../core/sync/proveedores_sync.dart';

/// Paquete completo o juego tal como lo ve la tablet (lo descargado + lo hecho aquí sin conexión).
class UnidadLocal {
  UnidadLocal(this.f, {this.estadoLocal});
  final Map<String, Object?> f;

  /// 'recibida' (recibida en esta tablet y aún no confirmada) | 'entregada' | null
  final String? estadoLocal;

  String get id => f['id'] as String;
  String get tipo => f['tipo'] as String; // paquete | juego
  String get codigo => f['codigo'] as String;
  String get opId => f['op_id'] as String;
  String get op => '${f['op'] ?? ''}';
  String get fichaId => '${f['ficha_version_id'] ?? ''}';
  String get referencia => '${f['ref_codigo'] ?? ''} ${f['ref_nombre'] ?? ''}'.trim();
  String get color => '${f['color'] ?? ''}';
  String? get colorHex => f['color_hex'] as String?;
  String get talla => '${f['talla'] ?? ''}';
  String? get combinacion => f['combinacion'] as String?;
  String? get lote => f['lote_tintura'] as String?;
  int get cantidad => ((f['cantidad_actual'] ?? f['cantidad']) as num?)?.toInt() ?? 0;
  String get estadoServidor => '${f['estado']}';
  String? get proceso => f['proceso_actual'] as String?;
  String? get celulaId => f['celula_id'] as String?;

  /// En proceso en esta estación (según el servidor o por una recepción hecha aquí)
  bool enProcesoAqui(String? proceso) =>
      estadoLocal != 'entregada' && this.proceso == proceso && (estadoLocal == 'recibida' || estadoServidor == 'en_proceso');
}

class OperacionLocal {
  OperacionLocal(this.f, this.unidadesPorDefecto);
  final Map<String, Object?> f;
  final int unidadesPorDefecto;
  String get id => f['id'] as String;
  String get codigo => '${f['codigo'] ?? ''}';
  String get nombre => '${f['nombre'] ?? ''}';
  double get sam => (f['sam'] as num?)?.toDouble() ?? 0;
  double? get samReproceso => (f['sam_reproceso'] as num?)?.toDouble();
  double get repeticiones => (f['repeticiones'] as num?)?.toDouble() ?? 1;
  bool get contadora => f['es_contadora'] == 1;
  int get secuencia => (f['secuencia'] as num?)?.toInt() ?? 0;
  int get unidadesMarcacion => ((f['fo_unidades'] ?? f['op_unidades']) as num?)?.toInt() ?? unidadesPorDefecto;
  String get titulo => repeticiones == 1 ? nombre : '$nombre ×${Formato.numero(repeticiones, decimales: repeticiones % 1 == 0 ? 0 : 1)}';
}

class MarcacionLocal {
  MarcacionLocal(this.id, this.r, this.hora, this.estado);
  final String id;
  final Map<String, dynamic> r;
  final DateTime hora;
  final String estado;
  String get operacion => '${r['operacion'] ?? ''}';
  String get fichaOperacionId => '${r['ficha_operacion_id']}';
  String get unidadId => '${r['unidad_id']}';
  int get unidades => (r['unidades'] as num?)?.toInt() ?? 1;
  bool get reproceso => r['tipo'] == 'reproceso';
  double get esperados => (r['esperados'] as num?)?.toDouble() ?? 0;
  double? get reales => (r['reales'] as num?)?.toDouble();
  double? get eficiencia => (r['eficiencia'] as num?)?.toDouble();
  String get talla => '${r['talla'] ?? ''}';
  MarcacionResumen get resumen => MarcacionResumen(hora: hora, esperados: esperados, reales: reales, unidades: unidades, reproceso: reproceso);
}

class EficienciasOperario {
  const EficienciasOperario({this.hora, this.hoy, this.mes, this.unidadesHoy = 0, this.reprocesosHoy = 0});
  final double? hora, hoy, mes;
  final int unidadesHoy, reprocesosHoy;
}

/// Lo que hace la tablet del módulo. Todo funciona sin conexión: recepciones,
/// marcaciones, anulaciones y entregas son eventos que suben solos.
class RepositorioModulo {
  RepositorioModulo(this._db, this._bandeja, {DateTime Function()? reloj}) : _reloj = reloj ?? DateTime.now;
  final PowerSyncDatabase _db;
  final Bandeja _bandeja;
  final DateTime Function() _reloj;

  static const _selectUnidad = '''
    SELECT u.*, o.consecutivo AS op, o.ficha_version_id, r.codigo AS ref_codigo, r.nombre AS ref_nombre,
           c.nombre AS color, c.hex AS color_hex, t.codigo AS talla, fc.nombre AS combinacion
    FROM (SELECT id, 'paquete' AS tipo, codigo, op_id, color_id, talla_id, lote_tintura, NULL AS combinacion_id, cantidad, cantidad_actual,
                 estado, proceso_actual, celula_id FROM paquetes
          UNION ALL
          SELECT id, 'juego', codigo, op_id, color_id, talla_id, NULL, combinacion_id, cantidad, cantidad_actual,
                 estado, proceso_actual, celula_id FROM juegos) u
    LEFT JOIN ordenes_produccion o ON o.id = u.op_id
    LEFT JOIN referencias r ON r.id = o.referencia_id
    LEFT JOIN colores c ON c.id = u.color_id
    LEFT JOIN tallas t ON t.id = u.talla_id
    LEFT JOIN ficha_combinaciones fc ON fc.id = u.combinacion_id''';

  /// Último evento de recepción/entrega hecho en esta tablet para la unidad (no rechazado).
  Future<String?> _estadoLocal(String unidadId) async {
    final r = await _db.getOptional('''
      SELECT json_extract(resumen, '\$.tipo') AS tipo FROM bandeja
      WHERE tabla = 'eventos_unidad' AND estado <> 'rechazado' AND json_extract(resumen, '\$.unidad_id') = ?
      ORDER BY ocurrido_en DESC LIMIT 1''', [unidadId]);
    return switch (r?['tipo']) { 'recepcion' => 'recibida', 'entrega' => 'entregada', _ => null };
  }

  /// Busca por lo leído en la cámara (PQ-… o JG-…). null si no es un código de paquete o juego, o no está en la tablet.
  Future<UnidadLocal?> unidadPorCodigo(String leido) async {
    final c = leerCodigo(leido);
    if (c.tipo != TipoCodigo.paquete && c.tipo != TipoCodigo.juego) return null;
    final f = await _db.getOptional('$_selectUnidad WHERE u.codigo = ?', [c.codigo]);
    return f == null ? null : UnidadLocal(f, estadoLocal: await _estadoLocal(f['id'] as String));
  }

  Future<UnidadLocal?> unidadPorId(String id) async {
    final f = await _db.getOptional('$_selectUnidad WHERE u.id = ?', [id]);
    return f == null ? null : UnidadLocal(f, estadoLocal: await _estadoLocal(id));
  }

  /// Unidades en proceso en la célula de la estación (para elegir sin escanear)
  Future<List<UnidadLocal>> unidadesEnCelula(String? celulaId, String? proceso) async {
    final filas = await _db.getAll('$_selectUnidad WHERE u.proceso_actual = ? ORDER BY u.codigo', [proceso]);
    final r = <UnidadLocal>[];
    for (final f in filas) {
      final u = UnidadLocal(f, estadoLocal: await _estadoLocal(f['id'] as String));
      if (u.enProcesoAqui(proceso) && (u.estadoLocal == 'recibida' || u.celulaId == celulaId)) r.add(u);
    }
    return r;
  }

  /// Operaciones de la ficha de la OP para el proceso de la estación
  Future<List<OperacionLocal>> operaciones(UnidadLocal u, String? proceso) async {
    final porDefecto = (await _db.getOptional("SELECT valor FROM parametros WHERE id = 'unidades_por_marcacion'"))?['valor'];
    final filas = await _db.getAll('''
      SELECT fo.*, fo.unidades_marcacion AS fo_unidades, op.unidades_marcacion AS op_unidades, op.codigo, op.nombre
      FROM ficha_operaciones fo LEFT JOIN operaciones op ON op.id = fo.operacion_id
      WHERE fo.ficha_id = ? AND fo.proceso = ? ORDER BY fo.secuencia''', [u.fichaId, proceso]);
    return [for (final f in filas) OperacionLocal(f, int.tryParse('${porDefecto ?? 1}') ?? 1)];
  }

  /// Operaciones que el balanceo publicado le asigna al operario en esta OP y célula
  /// (puesto y fracción). Vacío si no hay balanceo o el operario no tiene puesto.
  Future<Map<String, ({int puesto, double fraccion})>> operacionesDelBalanceo(String empleadoId, String opId, String? celulaId) async {
    final filas = await _db.getAll('''
      SELECT a.ficha_operacion_id, a.fraccion, p.numero FROM balanceos b
      JOIN balanceo_puestos p ON p.balanceo_id = b.id
      JOIN balanceo_asignaciones a ON a.puesto_id = p.id
      WHERE b.op_id = ? AND b.celula_id = ? AND p.empleado_id = ?''', [opId, celulaId, empleadoId]);
    return {for (final f in filas) f['ficha_operacion_id'] as String: (puesto: (f['numero'] as num).toInt(), fraccion: (f['fraccion'] as num).toDouble())};
  }

  Future<List<MarcacionLocal>> _marcaciones({String? empleadoId, String? unidadId, DateTime? desde}) async {
    final filas = await _db.getAll('''
      SELECT b.id, b.resumen, b.ocurrido_en, b.estado FROM bandeja b
      WHERE b.tabla = 'marcaciones' AND b.estado <> 'rechazado' AND json_extract(b.resumen, '\$.tipo') <> 'anulacion'
        AND (? IS NULL OR b.empleado_id = ?) AND (? IS NULL OR json_extract(b.resumen, '\$.unidad_id') = ?) AND (? IS NULL OR b.ocurrido_en >= ?)
        AND b.id NOT IN (SELECT json_extract(a.resumen, '\$.anula_id') FROM bandeja a
                         WHERE a.tabla = 'marcaciones' AND a.estado <> 'rechazado' AND json_extract(a.resumen, '\$.tipo') = 'anulacion')
      ORDER BY b.ocurrido_en DESC''', [empleadoId, empleadoId, unidadId, unidadId, desde?.toUtc().toIso8601String(), desde?.toUtc().toIso8601String()]);
    return [
      for (final f in filas)
        MarcacionLocal(f['id'] as String, jsonDecode(f['resumen'] as String) as Map<String, dynamic>, DateTime.parse(f['ocurrido_en'] as String),
            f['estado'] as String),
    ];
  }

  /// Hechas y reprocesos por operación en la unidad (marcado en esta tablet)
  Future<Map<String, ({int hechas, int reprocesos})>> avance(String unidadId) async {
    final r = <String, ({int hechas, int reprocesos})>{};
    for (final m in await _marcaciones(unidadId: unidadId)) {
      final a = r[m.fichaOperacionId] ?? (hechas: 0, reprocesos: 0);
      r[m.fichaOperacionId] = m.reproceso ? (hechas: a.hechas, reprocesos: a.reprocesos + m.unidades) : (hechas: a.hechas + m.unidades, reprocesos: a.reprocesos);
    }
    return r;
  }

  Future<List<MarcacionLocal>> ultimas(String empleadoId, {int limite = 6}) async =>
      (await _marcaciones(empleadoId: empleadoId, desde: Formato.inicioDiaBogota(_reloj()))).take(limite).toList();

  Future<double> _maxMinutos() async =>
      double.tryParse('${(await _db.getOptional("SELECT valor FROM parametros WHERE id = 'max_minutos_entre_marcaciones'"))?['valor'] ?? 30}') ?? 30;

  Future<String> marcar({
    required String empleadoId,
    required UnidadLocal unidad,
    required OperacionLocal op,
    int? unidades,
    bool reproceso = false,
  }) async {
    final n = unidades ?? op.unidadesMarcacion;
    final ahora = _reloj().toUtc();
    final anterior = (await _marcaciones(empleadoId: empleadoId, desde: Formato.inicioDiaBogota(ahora))).firstOrNull;
    final esperados = minutosEsperados(sam: op.sam, samReproceso: op.samReproceso, repeticiones: op.repeticiones, unidades: n, reproceso: reproceso);
    final reales = minutosReales(anterior?.hora, ahora, maxMinutos: await _maxMinutos());
    final r = await _bandeja.registrar(
      tabla: 'marcaciones',
      datos: {'empleado_id': empleadoId, 'unidad_id': unidad.id, 'ficha_operacion_id': op.id, 'unidades': n, 'tipo': reproceso ? 'reproceso' : 'normal'},
      resumen: {
        'tipo': reproceso ? 'reproceso' : 'normal', 'unidad_id': unidad.id, 'unidad': unidad.codigo, 'ficha_operacion_id': op.id,
        'operacion': op.titulo, 'unidades': n, 'esperados': esperados, 'reales': reales, 'eficiencia': eficiencia(esperados, reales),
        'talla': unidad.talla,
      },
      empleadoId: empleadoId,
    );
    return r.id;
  }

  Future<void> anularMarcacion(MarcacionLocal m, String empleadoId, String motivo) => _bandeja.registrar(
        tabla: 'marcaciones',
        datos: {'empleado_id': empleadoId, 'tipo': 'anulacion', 'anula_id': m.id, 'motivo': motivo},
        resumen: {'tipo': 'anulacion', 'anula_id': m.id, 'operacion': m.operacion, 'unidad_id': m.unidadId, 'motivo': motivo},
        empleadoId: empleadoId,
      );

  Future<void> recibir(UnidadLocal u, {String? empleadoId}) => _bandeja.registrar(
        tabla: 'eventos_unidad',
        datos: {'unidad_id': u.id, 'tipo': 'recepcion', 'empleado_id': empleadoId},
        resumen: {'tipo': 'recepcion', 'unidad_id': u.id, 'unidad': u.codigo, 'cantidad': u.cantidad},
        empleadoId: empleadoId,
      );

  /// Regla 5: buenas + segundas + faltantes = lo que entró
  Future<void> entregar(UnidadLocal u, {required int buenas, int segundas = 0, required int faltantes, String? empleadoId, String? observacion}) {
    if (buenas < 0 || segundas < 0 || faltantes < 0 || buenas + segundas + faltantes != u.cantidad) {
      throw ArgumentError('Las cantidades no cuadran: entraron ${u.cantidad}');
    }
    return _bandeja.registrar(
      tabla: 'eventos_unidad',
      datos: {'unidad_id': u.id, 'tipo': 'entrega', 'buenas': buenas, 'segundas': segundas, 'faltantes': faltantes,
              'empleado_id': empleadoId, 'observacion': observacion},
      resumen: {'tipo': 'entrega', 'unidad_id': u.id, 'unidad': u.codigo, 'buenas': buenas, 'segundas': segundas, 'faltantes': faltantes},
      empleadoId: empleadoId,
    );
  }

  /// Hora: última hora (esta tablet). Hoy: lo marcado hoy aquí. Mes: días anteriores del servidor + hoy.
  Future<EficienciasOperario> eficiencias(String empleadoId) async {
    final ahora = _reloj().toUtc();
    final inicioHoy = Formato.inicioDiaBogota(ahora);
    final hoy = await _marcaciones(empleadoId: empleadoId, desde: inicioHoy);
    final hora = hoy.where((m) => ahora.difference(m.hora) <= const Duration(hours: 1));
    final bogota = ahora.subtract(const Duration(hours: 5));
    final mesTxt = '${bogota.year}-${bogota.month.toString().padLeft(2, '0')}';
    final hoyTxt = '$mesTxt-${bogota.day.toString().padLeft(2, '0')}';
    final s = await _db.getOptional('''
      SELECT coalesce(sum(minutos_esperados), 0) AS e, coalesce(sum(minutos_reales), 0) AS r FROM eficiencia_diaria
      WHERE empleado_id = ? AND fecha >= ? AND fecha < ?''', [empleadoId, '$mesTxt-01', hoyTxt]);
    var e = (s?['e'] as num?)?.toDouble() ?? 0, r = (s?['r'] as num?)?.toDouble() ?? 0;
    for (final m in hoy) {
      if (m.reales == null) continue;
      e += m.esperados;
      r += m.reales!;
    }
    return EficienciasOperario(
      hora: eficienciaDe(hora.map((m) => m.resumen)),
      hoy: eficienciaDe(hoy.map((m) => m.resumen)),
      mes: r <= 0 ? null : (e / r * 1000).round() / 10,
      unidadesHoy: hoy.where((m) => !m.reproceso).fold(0, (a, m) => a + m.unidades),
      reprocesosHoy: hoy.where((m) => m.reproceso).fold(0, (a, m) => a + m.unidades),
    );
  }
}

final repositorioModuloProvider = Provider<RepositorioModulo>((ref) => RepositorioModulo(ref.watch(powerSyncProvider), ref.watch(bandejaProvider)));
