import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inventario/comun_inventario.dart' show db;

/// Catálogos que usan las pantallas de satélites.
class CatalogoExternos {
  CatalogoExternos(this.satelites, this.procesos, this.colores, this.tallas);
  final List<Map<String, dynamic>> satelites, procesos;
  final Map<String, Map<String, dynamic>> colores;
  final Map<String, String> tallas;

  String proceso(String? c) => '${procesos.where((p) => p['codigo'] == c).firstOrNull?['nombre'] ?? c ?? ''}';
  String color(String? id) => '${colores[id]?['nombre'] ?? ''}';
  String? hex(String? id) => colores[id]?['hex'] as String?;
  String talla(String? id) => tallas[id] ?? '';
}

final catalogoExternosProvider = FutureProvider.autoDispose<CatalogoExternos>((ref) async {
  final r = await Future.wait<dynamic>([
    db.from('satelites').select('id, nit, nombre, procesos, contacto, whatsapp, activo').order('nombre', ascending: true),
    db.from('procesos').select('codigo, nombre, orden').order('orden', ascending: true),
    db.from('colores').select('id, nombre, hex'),
    db.from('tallas').select('id, codigo'),
  ]);
  return CatalogoExternos(
    (r[0] as List).cast(),
    (r[1] as List).cast(),
    {for (final c in r[2] as List) c['id'] as String: c as Map<String, dynamic>},
    {for (final t in r[3] as List) t['id'] as String: t['codigo'] as String},
  );
});

/// Selección de columnas de una remisión con sus unidades (juegos/paquetes) e insumos
const selectRemision = '*, satelites(nombre, nit, whatsapp), procesos(nombre), '
    'remision_unidades(*, paquetes(codigo, color_id, talla_id), juegos(codigo, color_id, talla_id), '
    'ordenes_produccion(consecutivo, referencias(codigo, nombre))), '
    'remision_insumos(*, materiales(nombre, unidad), colores(nombre), ordenes_produccion(consecutivo))';

/// Filas de unidad listas para mostrar o imprimir
List<Map<String, dynamic>> unidadesDeRemision(Map<String, dynamic> r, CatalogoExternos c) => [
      for (final u in (r['remision_unidades'] as List? ?? const []).cast<Map<String, dynamic>>())
        {
          ...u,
          'unidad_id': u['paquete_id'] ?? u['juego_id'],
          'codigo': u['paquetes']?['codigo'] ?? u['juegos']?['codigo'],
          'color': c.color(u['paquetes']?['color_id'] ?? u['juegos']?['color_id']),
          'color_hex': c.hex(u['paquetes']?['color_id'] ?? u['juegos']?['color_id']),
          'talla': c.talla(u['paquetes']?['talla_id'] ?? u['juegos']?['talla_id']),
          'op': u['ordenes_produccion']?['consecutivo'],
          'referencia': u['ordenes_produccion']?['referencias']?['codigo'],
        },
    ]..sort((a, b) => '${a['codigo']}'.compareTo('${b['codigo']}'));

List<Map<String, dynamic>> insumosDeRemision(Map<String, dynamic> r) => [
      for (final i in (r['remision_insumos'] as List? ?? const []).cast<Map<String, dynamic>>())
        {
          ...i,
          'material': i['materiales']?['nombre'],
          'unidad': i['materiales']?['unidad'],
          'color': i['colores']?['nombre'],
          'op': i['ordenes_produccion']?['consecutivo'],
        },
    ];

String nombreEstadoRemision(String? e) =>
    const {'enviada': 'En el satélite', 'parcial': 'Devuelta en parte', 'cerrada': 'Devuelta', 'anulada': 'Anulada', 'registrada': 'Registrada'}[e] ?? '$e';
