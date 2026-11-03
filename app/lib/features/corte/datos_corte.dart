import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/calculos/corte.dart';
import '../inventario/comun_inventario.dart' show db;

// ---------------------------------------------------------------------------
// Documento del corte en edición (se guarda como jsonb en cortes.documento)
// ---------------------------------------------------------------------------
class SeccionEd {
  SeccionEd({required this.letra, this.largo = 0, Map<String, int>? unidades}) : unidades = unidades ?? {};
  String letra;
  double largo;
  final Map<String, int> unidades; // talla_id → piezas por capa

  Map<String, dynamic> aJson() => {'letra': letra, 'largo_m': largo, 'unidades': {for (final e in unidades.entries) if (e.value > 0) e.key: e.value}};
  factory SeccionEd.desdeJson(Map<String, dynamic> j) => SeccionEd(
      letra: '${j['letra'] ?? 'A'}',
      largo: ((j['largo_m'] ?? 0) as num).toDouble(),
      unidades: {for (final e in ((j['unidades'] as Map?) ?? {}).entries) '${e.key}': (e.value as num).toInt()});
  SeccionEd copia() => SeccionEd(letra: letra, largo: largo, unidades: {...unidades});
}

class TramoEd {
  TramoEd({required this.rolloId, required this.colorId, this.espiga = 1, this.capas = 0}) : clave = const Uuid().v4();
  final String clave; // para los widgets
  String rolloId;
  String colorId;
  int espiga;
  int capas;

  Map<String, dynamic> aJson() => {'rollo_id': rolloId, 'color_id': colorId, 'espiga': espiga, 'capas': capas};
  factory TramoEd.desdeJson(Map<String, dynamic> j) => TramoEd(
      rolloId: '${j['rollo_id']}', colorId: '${j['color_id']}', espiga: ((j['espiga'] ?? 1) as num).toInt(), capas: ((j['capas'] ?? 0) as num).toInt());
}

class BloqueEd {
  BloqueEd({String? id, required this.nombre, this.materialId, List<String>? partes, List<String>? tallas, List<SeccionEd>? secciones, List<TramoEd>? tramos})
      : id = id ?? const Uuid().v4(),
        partes = partes ?? [],
        tallas = tallas ?? [],
        secciones = secciones ?? [SeccionEd(letra: 'A')],
        tramos = tramos ?? [];
  final String id;
  String nombre;
  String? materialId;
  final List<String> partes;
  final List<String> tallas;
  final List<SeccionEd> secciones;
  final List<TramoEd> tramos;

  bool get esEspigas => secciones.length > 1;

  Map<String, dynamic> aJson() => {
        'id': id,
        'nombre': nombre,
        'material_id': materialId,
        'partes': partes,
        'tallas': tallas,
        'secciones': [for (final s in secciones) s.aJson()],
        'tramos': [for (final t in tramos) t.aJson()],
      };

  factory BloqueEd.desdeJson(Map<String, dynamic> j) => BloqueEd(
        id: j['id'] as String?,
        nombre: '${j['nombre'] ?? ''}',
        materialId: j['material_id'] as String?,
        partes: [for (final p in (j['partes'] as List? ?? const [])) '$p'],
        tallas: [for (final t in (j['tallas'] as List? ?? const [])) '$t'],
        secciones: [for (final s in (j['secciones'] as List? ?? const [])) SeccionEd.desdeJson(Map<String, dynamic>.from(s as Map))],
        tramos: [for (final t in (j['tramos'] as List? ?? const [])) TramoEd.desdeJson(Map<String, dynamic>.from(t as Map))],
      );

  /// Para el motor de cálculo: el lote sale del rollo.
  BloqueCorte aCalculo(Map<String, Map<String, dynamic>> rollos) => BloqueCorte(
        tallas: tallas,
        secciones: [for (final s in secciones) SeccionTrazo(letra: s.letra, largoM: s.largo, unidades: {...s.unidades})],
        tramos: [
          for (final t in tramos)
            if (t.capas > 0 && t.espiga <= secciones.length)
              TramoRollo(rolloId: t.rolloId, colorId: t.colorId, lote: rollos[t.rolloId]?['lote_tintura'] as String?, espiga: t.espiga, capas: t.capas),
        ],
      );
}

class FinRollo {
  FinRollo({this.fin = 'vuelve', this.restante});
  String fin; // vuelve | retazo | agotado
  double? restante;
  Map<String, dynamic> aJson() => {'fin': fin, if (restante != null) 'restante_m': restante};
}

class DocumentoCorte {
  DocumentoCorte({List<BloqueEd>? bloques, Map<String, FinRollo>? rollos})
      : bloques = bloques ?? [],
        rollos = rollos ?? {};
  final List<BloqueEd> bloques;
  final Map<String, FinRollo> rollos;

  Set<String> get rollosUsados => {for (final b in bloques) for (final t in b.tramos) if (t.capas > 0) t.rolloId};

  Map<String, dynamic> aJson() => {
        'bloques': [for (final b in bloques) b.aJson()],
        'rollos': {for (final r in rollosUsados) r: (rollos[r] ?? FinRollo()).aJson()},
      };

  factory DocumentoCorte.desdeJson(Map<String, dynamic>? j) => DocumentoCorte(
        bloques: [for (final b in (j?['bloques'] as List? ?? const [])) BloqueEd.desdeJson(Map<String, dynamic>.from(b as Map))],
        rollos: {
          for (final e in ((j?['rollos'] as Map?) ?? {}).entries)
            '${e.key}': FinRollo(fin: '${(e.value as Map)['fin'] ?? 'vuelve'}', restante: ((e.value as Map)['restante_m'] as num?)?.toDouble()),
        },
      );
}

// ---------------------------------------------------------------------------
// Contexto: OP, ficha, rollos, mesas… (lo necesario para editar y calcular)
// ---------------------------------------------------------------------------
class ContextoCorte {
  ContextoCorte(this.datos);
  final Map<String, dynamic> datos;

  Map<String, dynamic> get corte => datos['corte'];
  Map<String, dynamic> get op => datos['op'];
  List<Map<String, dynamic>> get partes => (datos['partes'] as List).cast();
  List<Map<String, dynamic>> get tallas => (datos['tallas'] as List).cast();
  List<Map<String, dynamic>> get combinaciones => (datos['combinaciones'] as List).cast();
  List<Map<String, dynamic>> get bom => (datos['bom'] as List).cast();
  Map<String, Map<String, dynamic>> get materiales => (datos['materiales'] as Map).cast();
  Map<String, Map<String, dynamic>> get colores => (datos['colores'] as Map).cast();
  Map<String, Map<String, dynamic>> get rollos => (datos['rollos'] as Map).cast();
  List<Map<String, dynamic>> get mesas => (datos['mesas'] as List).cast();
  List<Map<String, dynamic>> get cortadores => (datos['cortadores'] as List).cast();
  List<Map<String, dynamic>> get trazos => (datos['trazos'] as List).cast();
  List<Map<String, dynamic>> get cortadoAntes => (datos['cortado_antes'] as List).cast();
  double _param(String clave, double defecto) => num.tryParse('${(datos['parametros'] as Map)[clave] ?? ''}')?.toDouble() ?? defecto;
  double get toleranciaDesviacion => _param('tolerancia_desviacion_corte_pct', 5);
  int get maxPaquete => _param('max_prendas_paquete', 20).toInt();

  /// Telas que usa la ficha (en la lista de materiales o en las combinaciones)
  List<Map<String, dynamic>> get telasFicha {
    final ids = <String>{
      for (final l in bom) if (materiales.containsKey(l['material_id'])) l['material_id'] as String,
      for (final c in combinaciones) for (final p in c['ficha_combinacion_partes'] as List) if (materiales.containsKey(p['material_id'])) p['material_id'] as String,
    };
    return [for (final i in ids) materiales[i]!]..sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
  }

  String nombreCortador(Map<String, dynamic>? e) => e == null ? '—' : '${e['nombres']} ${e['apellidos']}'.trim();

  /// cantidades de la OP: combinación → talla → prendas
  Map<String, Map<String, int>> get cantidades {
    final r = <String, Map<String, int>>{};
    for (final c in (op['op_cantidades'] as List)) {
      (r[c['combinacion_id']] ??= {})[c['talla_id']] = c['cantidad'] as int;
    }
    return r;
  }

  bool get confirmado => corte['estado'] != 'borrador';
  String talla(String id) => tallas.firstWhere((t) => t['id'] == id, orElse: () => {'codigo': '?'})['codigo'];
  String parte(String id) => partes.firstWhere((p) => p['id'] == id, orElse: () => {'nombre': '?'})['nombre'];
  String color(String? id) => colores[id]?['nombre'] ?? '—';
  String? hex(String? id) => colores[id]?['hex'];

  /// color y material de una parte en una combinación
  Map<String, dynamic>? parteEn(Map<String, dynamic> comb, String parteId) =>
      (comb['ficha_combinacion_partes'] as List).cast<Map<String, dynamic>>().where((p) => p['parte_id'] == parteId).firstOrNull;

  /// Colores que llevan las partes del bloque en las combinaciones de la OP
  List<String> coloresDe(BloqueEd b) {
    if (b.partes.isEmpty) return [];
    final r = <String>[];
    for (final c in combinaciones) {
      if (!cantidades.containsKey(c['id'])) continue;
      final p = parteEn(c, b.partes.first);
      if (p != null && !r.contains(p['color_id'])) r.add(p['color_id'] as String);
    }
    return r;
  }

  /// Lo que falta cortar de las partes del bloque en un color, por talla:
  /// pedido de la OP (combinaciones que llevan ese color en la parte) menos lo
  /// ya cortado en otros cortes confirmados.
  Map<String, int> pendiente(BloqueEd b, String colorId) {
    final r = <String, int>{};
    if (b.partes.isEmpty) return r;
    final p0 = b.partes.first;
    for (final c in combinaciones) {
      final p = parteEn(c, p0);
      if (p == null || p['color_id'] != colorId) continue;
      cantidades[c['id']]?.forEach((t, n) => r[t] = (r[t] ?? 0) + n);
    }
    for (final pq in cortadoAntes) {
      if (pq['color_id'] == colorId && (pq['partes'] as List).contains(p0)) {
        r[pq['talla_id']] = (r[pq['talla_id']] ?? 0) - (pq['cantidad'] as int);
      }
    }
    return {for (final e in r.entries) e.key: e.value < 0 ? 0 : e.value};
  }

  /// Consumo estándar por prenda (con merma) del material del bloque en sus partes
  Map<String, double> consumoPorTalla(BloqueEd b) {
    final r = <String, double>{};
    for (final parte in b.partes) {
      final lineas = bom.where((l) => l['material_id'] == b.materialId && l['parte_id'] == parte).toList()
        ..sort((a, c) => (a['combinacion_id'] == null ? 0 : 1).compareTo(c['combinacion_id'] == null ? 0 : 1));
      if (lineas.isEmpty) continue;
      final l = lineas.first;
      final merma = ((l['merma_pct'] ?? 0) as num).toDouble();
      for (final c in (l['ficha_bom_consumos'] as List)) {
        r[c['talla_id']] = (r[c['talla_id']] ?? 0) + (c['consumo'] as num).toDouble() * (1 + merma / 100);
      }
    }
    return r;
  }

  /// Rollos posibles para un bloque (de su tela, con saldo), por color y lote
  List<Map<String, dynamic>> rollosDe(BloqueEd b) => rollos.values
      .where((r) => r['material_id'] == b.materialId && ((r['metros_saldo'] as num) > 0 || b.tramos.any((t) => t.rolloId == r['id'])))
      .toList()
    ..sort((a, c) => '${color(a['color_id'])}${a['lote_tintura']}${a['codigo']}'.compareTo('${color(c['color_id'])}${c['lote_tintura']}${c['codigo']}'));

  /// Kilos estimados de unos metros de un rollo
  double kilos(String rolloId, double metros) {
    final r = rollos[rolloId];
    if (r == null) return 0;
    return kilosDeMetros(metros,
        metrosSaldo: (r['metros_saldo'] as num).toDouble(),
        kilosSaldo: (r['kilos_saldo'] as num).toDouble(),
        rendimientoMKg: (materiales[r['material_id']]?['rendimiento_m_kg'] as num?)?.toDouble());
  }

  /// Tendidos por defecto según la ficha: uno por tela, con las partes que la llevan.
  List<BloqueEd> bloquesPorDefecto() {
    final porMaterial = <String, List<String>>{};
    final combs = combinaciones.where((c) => cantidades.containsKey(c['id'])).toList();
    for (final p in partes) {
      String? mat;
      for (final c in combs) {
        mat ??= parteEn(c, p['id'])?['material_id'] as String?;
      }
      mat ??= bom.where((l) => l['parte_id'] == p['id'] && materiales[l['material_id']]?['tipo'] == 'tela').firstOrNull?['material_id'] as String?;
      if (mat == null) continue;
      (porMaterial[mat] ??= []).add(p['id'] as String);
    }
    return [
      for (final e in porMaterial.entries)
        BloqueEd(
          nombre: e.value.map(parte).join(' y '),
          materialId: e.key,
          partes: e.value,
          tallas: [for (final t in tallas) t['id'] as String],
        ),
    ];
  }
}

final contextoCorteProvider = FutureProvider.autoDispose.family<ContextoCorte, String>((ref, id) async {
  final corte = await db.from('cortes').select('*, estaciones(codigo, nombre), empleados:cortador_id(nombres, apellidos)').eq('id', id).single();
  final op = await db.from('ordenes_produccion').select('id, consecutivo, estado, cantidad_total, fecha_entrega_plan, ficha_version_id, '
      'referencias(id, codigo, nombre), ficha_versiones(version), op_cantidades(combinacion_id, talla_id, cantidad), op_procesos(proceso, estado, buenas)')
      .eq('id', corte['op_id']).single();
  final ficha = op['ficha_version_id'] as String;
  final r = await Future.wait([
    db.from('ficha_partes').select('id, nombre, orden, puede_cortarse_retazo').eq('ficha_id', ficha).order('orden', ascending: true),
    db.from('ficha_tallas').select('orden, tallas(id, codigo, orden)').eq('ficha_id', ficha).order('orden', ascending: true),
    db.from('ficha_combinaciones').select('id, codigo, nombre, orden, ficha_combinacion_partes(parte_id, material_id, color_id)')
        .eq('ficha_id', ficha).order('orden', ascending: true),
    db.from('ficha_bom').select('material_id, parte_id, combinacion_id, merma_pct, ficha_bom_consumos(talla_id, consumo)').eq('ficha_id', ficha),
    db.from('materiales').select('id, codigo, nombre, unidad, tipo, rendimiento_m_kg, ancho_nominal_cm').eq('tipo', 'tela'),
    db.from('colores').select('id, codigo, nombre, hex'),
    db.from('estaciones').select('id, codigo, nombre').eq('tipo', 'mesa_corte').eq('activo', true).order('codigo', ascending: true),
    db.from('empleados').select('id, codigo, nombres, apellidos').eq('activo', true).order('nombres', ascending: true),
    db.from('trazos').select().eq('referencia_id', op['referencias']['id']).eq('activo', true).order('nombre', ascending: true),
    db.from('paquetes').select('partes, color_id, talla_id, cantidad').eq('op_id', op['id']).eq('estado', 'cortado').neq('corte_id', id),
    db.from('parametros').select('clave, valor').inFilter('clave', ['tolerancia_desviacion_corte_pct', 'tolerancia_ancho_cm', 'max_prendas_paquete']),
  ]);
  final telas = {for (final m in r[4]) m['id'] as String: m};
  final rollos = await db.from('rollos').select('id, codigo, material_id, color_id, lote_tintura, tono, ancho_real_cm, metros_saldo, kilos_saldo, estado, es_retazo, '
      'bodegas(tipo), ubicaciones(codigo)').inFilter('material_id', telas.keys.toList()).neq('estado', 'agotado');
  final usados = {
    for (final b in (corte['documento']?['bloques'] as List? ?? const [])) for (final t in (b['tramos'] as List? ?? const [])) '${t['rollo_id']}',
  };
  final extra = usados.isEmpty ? <Map<String, dynamic>>[] : await db.from('rollos').select('id, codigo, material_id, color_id, lote_tintura, tono, '
      'ancho_real_cm, metros_saldo, kilos_saldo, estado, es_retazo, bodegas(tipo), ubicaciones(codigo)').inFilter('id', usados.toList());
  final datos = <String, dynamic>{
    'corte': corte,
    'op': op,
    'partes': r[0],
    'tallas': [for (final t in r[1]) t['tallas']],
    'combinaciones': r[2],
    'bom': r[3],
    'materiales': telas,
    'colores': {for (final c in r[5]) c['id'] as String: c},
    'rollos': {for (final x in [...rollos, ...extra]) if (x['bodegas']?['tipo'] == 'telas' || usados.contains(x['id'])) x['id'] as String: x},
    'mesas': r[6],
    'cortadores': r[7],
    'trazos': r[8],
    'cortado_antes': r[9],
    'parametros': {for (final x in r[10]) x['clave'] as String: x['valor']},
  };
  if (corte['estado'] != 'borrador') {
    final c = await Future.wait([
      db.from('paquetes').select('*').eq('corte_id', id).order('codigo', ascending: true),
      db.from('corte_rollos').select('*, rollos!corte_rollos_rollo_id_fkey(codigo), retazo:rollos!corte_rollos_retazo_id_fkey(codigo)').eq('corte_id', id),
      db.from('corte_consumos').select('*').eq('corte_id', id),
      db.from('corte_autorizaciones').select('*, perfiles:usuario_id(nombre)').eq('corte_id', id),
    ]);
    datos.addAll({'paquetes': c[0], 'corte_rollos': c[1], 'consumos': c[2], 'autorizaciones': c[3]});
  } else {
    datos['autorizaciones'] = await db.from('corte_autorizaciones').select('*, perfiles:usuario_id(nombre)').eq('corte_id', id);
  }
  return ContextoCorte(datos);
});

String nombreTipoCorte(String? t) => const {'un_color': 'Un color', 'multicolor': 'Multicolor', 'combinada': 'Prenda combinada'}[t] ?? '$t';
