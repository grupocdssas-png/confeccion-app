import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../../core/escaneo/codigos.dart';
import '../../core/etiquetas/cola_impresion.dart';
import '../../core/etiquetas/zpl.dart';
import '../../core/sync/bandeja.dart';
import '../../core/sync/proveedores_sync.dart';

class RolloLocal {
  RolloLocal(this.f);
  final Map<String, Object?> f;
  String get id => f['id'] as String;
  String get codigo => f['codigo'] as String;
  String get material => '${f['material'] ?? ''}';
  String get unidad => '${f['unidad'] ?? 'm'}';
  String get color => '${f['color'] ?? ''}';
  String get lote => '${f['lote_tintura'] ?? ''}';
  String? get tono => f['tono'] as String?;
  double get ancho => (f['ancho_real_cm'] as num?)?.toDouble() ?? 0;
  double get metros => (f['metros_saldo'] as num?)?.toDouble() ?? 0;
  double get kilos => (f['kilos_saldo'] as num?)?.toDouble() ?? 0;
  String? get ubicacionId => f['ubicacion_id'] as String?;
  String get ubicacion => '${f['ubicacion'] ?? '—'}';
  String get bodega => '${f['bodega'] ?? ''}';
  String get estado => '${f['estado']}';
  bool get esRetazo => f['es_retazo'] == 1;
  String? get proveedor => f['proveedor'] as String?;
  DateTime get fechaIngreso => DateTime.tryParse('${f['fecha_ingreso']}') ?? DateTime.now();
}

/// Operaciones de bodega en la tablet/celular. Todo funciona sin conexión:
/// los traslados, conteos e impresiones se guardan como eventos y suben solos.
class RepositorioBodega {
  RepositorioBodega(this._db, this._bandeja, this._cola);
  final PowerSyncDatabase _db;
  final Bandeja _bandeja;
  final ColaImpresion _cola;

  static const _selectRollo = '''
    SELECT r.*, m.nombre AS material, m.unidad, c.nombre AS color, u.codigo AS ubicacion, b.nombre AS bodega
    FROM rollos r
    LEFT JOIN materiales m ON m.id = r.material_id
    LEFT JOIN colores c ON c.id = r.color_id
    LEFT JOIN ubicaciones u ON u.id = r.ubicacion_id
    LEFT JOIN bodegas b ON b.id = r.bodega_id''';

  Future<RolloLocal?> rolloPorCodigo(String leido) async {
    final c = leerCodigo(leido);
    if (c.tipo != TipoCodigo.rollo) return null;
    final f = await _db.getOptional('$_selectRollo WHERE r.codigo = ?', [c.codigo]);
    return f == null ? null : RolloLocal(f);
  }

  Future<Map<String, Object?>?> ubicacionPorCodigo(String leido) async {
    final c = leerCodigo(leido);
    if (c.tipo != TipoCodigo.ubicacion) return null;
    return _db.getOptional(
        'SELECT u.*, b.nombre AS bodega FROM ubicaciones u LEFT JOIN bodegas b ON b.id = u.bodega_id WHERE u.codigo = ? AND u.activo = 1',
        [c.codigo]);
  }

  /// Traslado pendiente de un rollo (registrado en esta tablet, aún sin confirmar por el servidor).
  Future<String?> trasladoPendiente(String rolloId) async {
    final r = await _db.getOptional('''
      SELECT json_extract(resumen, '\$.destino') AS destino FROM bandeja
      WHERE tabla = 'traslados_rollo' AND estado = 'pendiente' AND json_extract(resumen, '\$.rollo_id') = ?
      ORDER BY ocurrido_en DESC LIMIT 1''', [rolloId]);
    return r?['destino'] as String?;
  }

  Future<void> trasladar(RolloLocal rollo, Map<String, Object?> destino) => _bandeja.registrar(
        tabla: 'traslados_rollo',
        datos: {'rollo_id': rollo.id, 'ubicacion_destino_id': destino['id']},
        resumen: {'rollo_id': rollo.id, 'codigo': rollo.codigo, 'origen': rollo.ubicacion, 'destino': destino['codigo']},
      );

  // ---------- Conteo ----------
  Stream<List<Map<String, Object?>>> conteosAbiertos() => _db
      .watch('''SELECT c.*, b.nombre AS bodega, u.codigo AS ubicacion FROM conteos_fisicos c
                LEFT JOIN bodegas b ON b.id = c.bodega_id LEFT JOIN ubicaciones u ON u.id = c.ubicacion_id
                WHERE c.estado = 'abierto' ORDER BY c.consecutivo''')
      .map((rs) => rs.toList());

  Stream<List<Map<String, Object?>>> registrosConteo(String conteoId) => _db
      .watch('''SELECT * FROM bandeja WHERE tabla = 'conteo_registros' AND json_extract(resumen, '\$.conteo_id') = ?
                ORDER BY ocurrido_en DESC''', parameters: [conteoId])
      .map((rs) => rs.toList());

  /// Devuelve false si el rollo ya estaba contado en este conteo (no se duplica).
  Future<bool> contarRollo(String conteoId, RolloLocal r, {String? ubicacionId, String? ubicacionCodigo}) async {
    final ya = await _db.getOptional('''SELECT 1 FROM bandeja WHERE tabla = 'conteo_registros' AND estado <> 'rechazado'
        AND json_extract(resumen, '\$.conteo_id') = ? AND json_extract(resumen, '\$.rollo_id') = ?''', [conteoId, r.id]);
    if (ya != null) return false;
    await _bandeja.registrar(
      tabla: 'conteo_registros',
      datos: {'conteo_id': conteoId, 'rollo_id': r.id, 'ubicacion_id': ubicacionId ?? r.ubicacionId},
      resumen: {
        'conteo_id': conteoId, 'rollo_id': r.id, 'codigo': r.codigo, 'detalle': '${r.material} · ${r.color}',
        'ubicacion': ubicacionCodigo ?? r.ubicacion, 'otra_ubicacion': ubicacionId != null && ubicacionId != r.ubicacionId,
      },
    );
    return true;
  }

  Future<List<Map<String, Object?>>> insumos(String filtro) => _db.getAll(
      "SELECT * FROM materiales WHERE tipo = 'insumo' AND activo = 1 AND (nombre LIKE ? OR codigo LIKE ?) ORDER BY nombre LIMIT 30",
      ['%$filtro%', '%$filtro%']);

  Future<List<Map<String, Object?>>> colores() => _db.getAll('SELECT * FROM colores WHERE activo = 1 ORDER BY nombre');

  Future<void> contarInsumo(String conteoId, Map<String, Object?> material, Map<String, Object?>? color, double cantidad,
          {String? ubicacionId, String? ubicacionCodigo}) =>
      _bandeja.registrar(
        tabla: 'conteo_registros',
        datos: {'conteo_id': conteoId, 'material_id': material['id'], 'color_id': color?['id'], 'cantidad': cantidad, 'ubicacion_id': ubicacionId},
        resumen: {
          'conteo_id': conteoId, 'codigo': material['codigo'],
          'detalle': '${material['nombre']}${color == null ? '' : ' · ${color['nombre']}'}',
          'cantidad': cantidad, 'unidad': material['unidad'], 'ubicacion': ubicacionCodigo ?? '—',
        },
      );

  Future<void> anularRegistroConteo(String conteoId, String registroId) => _bandeja.registrar(
        tabla: 'conteo_registros',
        datos: {'conteo_id': conteoId, 'anula_id': registroId},
        resumen: {'conteo_id': conteoId, 'anula_id': registroId, 'codigo': 'Anulación'},
      );

  // ---------- Impresión ----------
  Future<ImpresoraLocal?> impresoraDeLaEstacion() async {
    final f = await _db.getOptional('''SELECT i.* FROM impresoras i JOIN estaciones e ON e.impresora_id = i.id
                                       JOIN dispositivos d ON d.estacion_id = e.id LIMIT 1''');
    if (f == null) return null;
    return ImpresoraLocal(
      id: f['id'] as String, nombre: f['nombre'] as String, conexion: f['conexion'] as String,
      ip: (f['ip'] as String?)?.split('/').first, puerto: (f['puerto'] as int?) ?? 9100,
    );
  }

  Future<({String zpl, String? id, int? version})> plantilla(String tipo) async {
    final p = await _db.getOptional('SELECT * FROM plantillas_etiqueta WHERE tipo = ? LIMIT 1', [tipo]);
    return (
      zpl: (p?['zpl'] as String?) ?? (tipo == 'rollo' ? plantillaRolloPorDefecto : plantillaUbicacionPorDefecto),
      id: p?['id'] as String?,
      version: p?['version'] as int?,
    );
  }

  Future<void> imprimirRollo(RolloLocal r, {required bool reimpresion, String? motivo}) async {
    final imp = await impresoraDeLaEstacion();
    if (imp == null) throw StateError('Esta estación no tiene impresora asignada (Configuración → Impresoras).');
    final p = await plantilla('rollo');
    final proveedor = r.f['proveedor_id'] == null
        ? null
        : (await _db.getOptional('SELECT nombre FROM proveedores WHERE id = ?', [r.f['proveedor_id']]))?['nombre'];
    final zpl = renderizarZpl(p.zpl, datosEtiquetaRollo(
      codigo: r.codigo, tela: r.material, color: r.color, lote: r.lote, tono: r.tono, anchoCm: r.ancho,
      metros: r.metros, kilos: r.kilos, proveedor: proveedor as String?, fechaIngreso: r.fechaIngreso, ubicacion: r.ubicacion,
    ));
    await _cola.encolar(
      impresora: imp, zpl: zpl, entidad: 'rollos', entidadId: r.id, codigo: r.codigo,
      plantillaId: p.id, plantillaVersion: p.version, esReimpresion: reimpresion, motivo: motivo,
    );
  }

  Future<void> imprimirPrueba() async {
    final imp = await impresoraDeLaEstacion();
    if (imp == null) throw StateError('Esta estación no tiene impresora asignada.');
    await _cola.encolar(impresora: imp, zpl: zplPrueba(imp.nombre), entidad: 'prueba', codigo: 'PRUEBA');
  }

  Stream<List<Map<String, Object?>>> cola() => _db
      .watch("SELECT * FROM cola_impresion ORDER BY CASE estado WHEN 'pendiente' THEN 0 ELSE 1 END, creado_en DESC LIMIT 100")
      .map((rs) => rs.toList());
}

final colaImpresionProvider = Provider((ref) => ColaImpresion(ref.watch(powerSyncProvider), ref.watch(bandejaProvider)));
final repoBodegaProvider = Provider(
    (ref) => RepositorioBodega(ref.watch(powerSyncProvider), ref.watch(bandejaProvider), ref.watch(colaImpresionProvider)));
