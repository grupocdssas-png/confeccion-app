import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/etiquetas/etiquetas_pdf.dart';
import '../../core/etiquetas/impresion_web.dart';
import '../../core/etiquetas/zpl.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart';

/// Terminación: lo que está en terminación y en calidad (con su última auditoría),
/// etiquetas de prenda con código de barras por talla y color, y lo que entró a
/// producto terminado y a segundas.
class PantallaTerminacion extends ConsumerStatefulWidget {
  const PantallaTerminacion({super.key});
  @override
  ConsumerState<PantallaTerminacion> createState() => _PantallaTerminacionState();
}

class _PantallaTerminacionState extends ConsumerState<PantallaTerminacion> {
  late Future<_Datos> _datos = _cargar();

  Future<_Datos> _cargar() async {
    final unidades = (await db.from('unidades_trabajo').select().inFilter('proceso_actual', ['terminacion', 'calidad']).neq('estado', 'terminado').neq('estado', 'anulado')
            .order('codigo', ascending: true))
        .cast<Map<String, dynamic>>();
    final ids = [for (final u in unidades) u['id']];
    final ops = {
      for (final o in await db.from('ordenes_produccion').select('id, consecutivo, referencia_id, referencias(codigo, nombre)').inFilter('id', {for (final u in unidades) u['op_id']}.toList()))
        o['id']: o,
    };
    final tallas = {for (final t in await db.from('tallas').select('id, codigo, orden')) t['id']: t};
    final aud = ids.isEmpty
        ? <Map<String, dynamic>>[]
        : [
            ...(await db.from('inspecciones').select('id, anula_id, tipo, paquete_id, juego_id, resultado, ocurrido_en_servidor').inFilter('paquete_id', ids)),
            ...(await db.from('inspecciones').select('id, anula_id, tipo, paquete_id, juego_id, resultado, ocurrido_en_servidor').inFilter('juego_id', ids)),
          ].cast<Map<String, dynamic>>();
    final anuladas = {for (final a in aud) if (a['anula_id'] != null) a['anula_id']};
    final ultima = <String, Map<String, dynamic>>{};
    for (final a in aud.where((a) => a['tipo'] == 'auditoria_final' && !anuladas.contains(a['id']))) {
      final k = '${a['paquete_id'] ?? a['juego_id']}';
      if (ultima[k] == null || '${a['ocurrido_en_servidor']}'.compareTo('${ultima[k]!['ocurrido_en_servidor']}') > 0) ultima[k] = a;
    }
    final movs = (await db
            .from('movimientos_producto')
            .select('cantidad, tipo, creado_en, documento, skus(codigo), bodegas(codigo), ordenes_produccion(consecutivo)')
            .inFilter('tipo', ['ingreso_op', 'ingreso_segunda'])
            .gte('creado_en', DateTime.now().subtract(const Duration(days: 7)).toUtc().toIso8601String())
            .order('creado_en', ascending: false)
            .limit(200))
        .cast<Map<String, dynamic>>();
    final abiertas = (await db.from('ordenes_produccion').select('id, consecutivo, referencias(codigo, nombre)').inFilter('estado', ['planeada', 'en_proceso'])
            .order('consecutivo', ascending: false))
        .cast<Map<String, dynamic>>();
    return _Datos(unidades, ops, tallas, ultima, movs, abiertas);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Terminación', subtitulo: 'Planchado, etiquetado y empaque · auditoría · ingreso a producto terminado y segundas'),
      FutureBuilder<_Datos>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final d = s.data!;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tarjeta(
              titulo: 'En terminación y calidad · ${d.unidades.fold<int>(0, (a, u) => a + ((u['cantidad_actual'] ?? 0) as int))} prendas',
              accion: OutlinedButton.icon(onPressed: () => setState(() => _datos = _cargar()), icon: const Icon(Icons.refresh), label: const Text('Actualizar')),
              child: Tabla(
                columnas: const ['Paquete / juego', 'OP', 'Referencia', 'Talla', 'Prendas', 'Proceso', 'Estado', 'Auditoría'],
                numericas: const {4},
                vacio: 'No hay nada en terminación ni en calidad.',
                filas: [
                  for (final u in d.unidades)
                    DataRow(cells: [
                      DataCell(Text('${u['codigo']}', style: estiloCodigo(12.5))),
                      DataCell(Text('${d.ops[u['op_id']]?['consecutivo'] ?? ''}')),
                      DataCell(Text('${d.ops[u['op_id']]?['referencias']?['codigo'] ?? ''}')),
                      DataCell(Text('${d.tallas[u['talla_id']]?['codigo'] ?? ''}')),
                      DataCell(Text('${u['cantidad_actual']}')),
                      DataCell(Pastilla(Colores.nombreProceso(u['proceso_actual']), color: Colores.deProceso('${u['proceso_actual']}'))),
                      DataCell(Text(u['estado'] == 'en_proceso' ? 'En proceso' : 'Esperando')),
                      DataCell(switch (d.ultima[u['id']]?['resultado']) {
                        'aprobado' => const Pastilla('Aprobada', color: Colores.verde),
                        'rechazado' => const Pastilla('Rechazada', color: Colores.rojo),
                        _ => Text(u['proceso_actual'] == 'calidad' ? 'Pendiente' : '—', style: estilo(13, color: Colores.textoSuave)),
                      }),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Etiquetas(ops: d.abiertas),
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Ingresos de los últimos 7 días',
              child: Tabla(
                columnas: const ['Fecha', 'Producto', 'Bodega', 'Prendas', 'Paquete / juego', 'OP'],
                numericas: const {3},
                vacio: 'Nada ha entrado a producto terminado ni a segundas esta semana.',
                filas: [
                  for (final m in d.movs)
                    DataRow(cells: [
                      DataCell(Text(Formato.fechaHora(DateTime.parse(m['creado_en'])))),
                      DataCell(Text('${m['skus']?['codigo'] ?? ''}', style: estiloCodigo(12.5))),
                      DataCell(m['tipo'] == 'ingreso_segunda' ? const Pastilla('Segundas', color: Colores.ambar) : const Pastilla('Terminado', color: Colores.verde)),
                      DataCell(Text('${m['cantidad']}')),
                      DataCell(Text('${m['documento'] ?? ''}')),
                      DataCell(Text('${m['ordenes_produccion']?['consecutivo'] ?? ''}')),
                    ]),
                ],
              ),
            ),
          ]);
        },
      ),
    ]);
  }
}

class _Datos {
  _Datos(this.unidades, this.ops, this.tallas, this.ultima, this.movs, this.abiertas);
  final List<Map<String, dynamic>> unidades;
  final Map<dynamic, Map<String, dynamic>> ops;
  final Map<dynamic, Map<String, dynamic>> tallas;
  final Map<String, Map<String, dynamic>> ultima;
  final List<Map<String, dynamic>> movs;
  final List<Map<String, dynamic>> abiertas;
}

/// Etiquetas de prenda de una OP: una por prenda, por color y talla (cantidades de la OP)
class _Etiquetas extends StatefulWidget {
  const _Etiquetas({required this.ops});
  final List<Map<String, dynamic>> ops;
  @override
  State<_Etiquetas> createState() => _EtiquetasState();
}

class _EtiquetasState extends State<_Etiquetas> {
  String? _op;
  List<Map<String, dynamic>> _filas = [];
  final _copias = <String, TextEditingController>{};

  Future<void> _elegir(String id) async {
    final cant = (await db.from('op_cantidades').select('cantidad, talla_id, ficha_combinaciones(codigo, nombre), tallas(codigo, orden)').eq('op_id', id))
        .cast<Map<String, dynamic>>();
    cant.sort((a, b) => '${a['ficha_combinaciones']['codigo']}'.compareTo('${b['ficha_combinaciones']['codigo']}') != 0
        ? '${a['ficha_combinaciones']['codigo']}'.compareTo('${b['ficha_combinaciones']['codigo']}')
        : (a['tallas']['orden'] as int).compareTo(b['tallas']['orden'] as int));
    for (final c in _copias.values) {
      c.dispose();
    }
    _copias.clear();
    for (final c in cant) {
      _copias['${c['ficha_combinaciones']['codigo']}_${c['talla_id']}'] = TextEditingController(text: '${c['cantidad']}');
    }
    setState(() {
      _op = id;
      _filas = cant;
    });
  }

  @override
  void dispose() {
    for (final c in _copias.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _imprimir() async {
    final op = widget.ops.firstWhere((o) => o['id'] == _op);
    final ref = op['referencias'];
    try {
      final p = await db.from('plantillas_etiqueta').select().eq('tipo', 'producto_terminado').eq('activa', true).maybeSingle();
      final datos = <(Map<String, Object?>, int)>[];
      for (final f in _filas) {
        final n = int.tryParse(_copias['${f['ficha_combinaciones']['codigo']}_${f['talla_id']}']!.text.trim()) ?? 0;
        if (n <= 0) continue;
        final comb = '${f['ficha_combinaciones']['codigo']}';
        final talla = '${f['tallas']['codigo']}';
        datos.add((
          datosEtiquetaProducto(codigo: 'PT-${ref['codigo']}-$comb-$talla', referencia: '${ref['codigo']}', nombre: '${ref['nombre']}', talla: talla,
              color: '${f['ficha_combinaciones']['nombre']}'),
          n,
        ));
      }
      if (datos.isEmpty) return;
      final res = await imprimirEtiquetasWeb(
        etiquetas: [
          for (final (x, n) in datos) (codigo: '${x['codigo']}', entidadId: null, zpl: renderizarZpl(p?['zpl'] ?? plantillaProductoPorDefecto, x, copias: n)),
        ],
        generarPdf: () => EtiquetasPdf.productos(datos),
        entidad: 'producto',
        plantillaId: p?['id'],
        plantillaVersion: p?['version'],
      );
      final total = datos.fold<int>(0, (a, x) => a + x.$2);
      if (mounted) avisar(context, res.medio == 'browser_print' ? '$total etiquetas enviadas a ${res.impresora}' : 'Se abrió el PDF de $total etiquetas (50 × 30 mm)');
    } catch (e) {
      if (mounted) avisar(context, 'No se pudo imprimir: ${mensajeError(e)}', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Tarjeta(
        titulo: 'Etiquetas de prenda',
        accion: FilledButton.icon(onPressed: _filas.isEmpty ? null : _imprimir, icon: const Icon(Icons.print_outlined), label: const Text('Imprimir')),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Código de barras por referencia, color y talla (el mismo código del producto terminado). Una etiqueta por prenda.',
              style: estilo(13, color: Colores.textoSuave)),
          const SizedBox(height: 10),
          SizedBox(
            width: 420,
            child: DropdownButtonFormField<String>(
              initialValue: _op,
              decoration: const InputDecoration(labelText: 'Orden de producción'),
              items: [
                for (final o in widget.ops)
                  DropdownMenuItem(value: o['id'] as String, child: Text('${o['consecutivo']} · ${o['referencias']?['codigo']} ${o['referencias']?['nombre']}')),
              ],
              onChanged: (v) => v == null ? null : _elegir(v),
            ),
          ),
          if (_filas.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final f in _filas)
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: _copias['${f['ficha_combinaciones']['codigo']}_${f['talla_id']}'],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: '${f['ficha_combinaciones']['codigo']} · ${f['tallas']['codigo']}'),
                  ),
                ),
            ]),
          ],
        ]),
      );
}
