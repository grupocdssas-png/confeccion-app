import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, muestraColor;

final unidadesOpProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, op) async {
  final r = await Future.wait<dynamic>([
    db.from('unidades_trabajo').select().eq('op_id', op).order('codigo', ascending: true),
    db.from('avance_unidad_operacion').select('unidad_id, hechas').eq('op_id', op),
    db.from('colores').select('id, nombre, hex'),
    db.from('tallas').select('id, codigo'),
    db.from('celulas').select('id, codigo, nombre'),
  ]);
  return {
    'unidades': r[0],
    // la operación que más avanza en cada unidad (en las tablets)
    'marcadas': (r[1] as List).fold<Map<dynamic, int>>({}, (m, a) {
      final n = ((a['hechas'] ?? 0) as num).toInt();
      if (n > (m[a['unidad_id']] ?? 0)) m[a['unidad_id']] = n;
      return m;
    }),
    'colores': {for (final c in r[2] as List) c['id']: c},
    'tallas': {for (final t in r[3] as List) t['id']: t['codigo']},
    'celulas': {for (final c in r[4] as List) c['id']: c['codigo']},
  };
});

/// Paquetes completos y juegos de la OP: dónde va cada uno. Desde aquí se reciben y
/// entregan los procesos sin tablet (p. ej. estampación en un satélite).
class UnidadesOp extends ConsumerWidget {
  const UnidadesOp({super.key, required this.opId, required this.editar, required this.onCambio});
  final String opId;
  final bool editar;
  final VoidCallback onCambio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(unidadesOpProvider(opId));
    return Tarjeta(
      titulo: 'Paquetes y juegos en planta',
      child: datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (d) {
          final l = (d['unidades'] as List).cast<Map<String, dynamic>>().where((u) => u['estado'] != 'anulado').toList();
          if (l.isEmpty) return Text('Todavía no hay paquetes completos ni juegos (salen del corte).', style: estilo(14, color: Colores.textoSuave));
          final porProceso = <String, int>{};
          for (final u in l) {
            final k = u['estado'] == 'terminado' ? 'terminado' : '${u['proceso_actual']}';
            porProceso[k] = (porProceso[k] ?? 0) + ((u['cantidad_actual'] ?? 0) as num).toInt();
          }
          Future<void> mover(Map<String, dynamic> u, String tipo, {int? buenas, int segundas = 0}) async {
            try {
              await db.rpc('mover_unidad', params: {
                'p_codigo': u['codigo'], 'p_tipo': tipo, 'p_proceso': u['proceso_actual'],
                if (tipo == 'entrega') ...{'p_buenas': buenas, 'p_segundas': segundas, 'p_faltantes': (u['cantidad_actual'] as int) - buenas! - segundas},
              });
              ref.invalidate(unidadesOpProvider(opId));
              onCambio();
            } catch (e) {
              if (context.mounted) avisar(context, mensajeError(e), error: true);
            }
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in porProceso.entries)
                Pastilla('${e.key == 'terminado' ? 'Terminadas' : Colores.nombreProceso(e.key)}: ${Formato.numero(e.value, decimales: 0)}',
                    color: e.key == 'terminado' ? Colores.verde : Colores.deProceso(e.key)),
            ]),
            const SizedBox(height: 10),
            Tabla(
              columnas: const ['Código', 'Color', 'Talla', 'Prendas', 'Proceso', 'Estado', 'Célula', 'Marcadas (máx.)', ''],
              numericas: const {3, 7},
              filas: [
                for (final u in l)
                  DataRow(cells: [
                    DataCell(Text('${u['codigo']}', style: estiloCodigo(13))),
                    DataCell(Row(children: [
                      muestraColor((d['colores'] as Map)[u['color_id']]?['hex']),
                      const SizedBox(width: 6),
                      Text('${(d['colores'] as Map)[u['color_id']]?['nombre'] ?? ''}'),
                    ])),
                    DataCell(Text('${(d['tallas'] as Map)[u['talla_id']] ?? ''}', style: estilo(14, peso: FontWeight.w700))),
                    DataCell(Text('${u['cantidad_actual']}${u['cantidad_actual'] != u['cantidad'] ? ' de ${u['cantidad']}' : ''}')),
                    DataCell(u['estado'] == 'terminado' ? const Text('—')
                        : Pastilla(Colores.nombreProceso(u['proceso_actual']), color: Colores.deProceso(u['proceso_actual']))),
                    DataCell(Text(const {'cortado': 'Por recibir', 'armado': 'Por recibir', 'en_espera': 'Por recibir', 'en_proceso': 'En proceso',
                        'terminado': 'Terminado'}[u['estado']] ?? '${u['estado']}')),
                    DataCell(Text('${(d['celulas'] as Map)[u['celula_id']] ?? '—'}')),
                    DataCell(Text('${(d['marcadas'] as Map)[u['id']] ?? 0}')),
                    DataCell(!editar || u['estado'] == 'terminado'
                        ? const SizedBox.shrink()
                        : u['estado'] == 'en_proceso'
                            ? TextButton(
                                onPressed: () async {
                                  final r = await showDialog<({int buenas, int segundas})>(context: context, builder: (_) => _Entrega(u));
                                  if (r != null) await mover(u, 'entrega', buenas: r.buenas, segundas: r.segundas);
                                },
                                child: const Text('Entregar'))
                            : TextButton(onPressed: () => mover(u, 'recepcion'), child: const Text('Recibir'))),
                  ]),
              ],
            ),
          ]);
        },
      ),
    );
  }
}

class _Entrega extends StatefulWidget {
  const _Entrega(this.u);
  final Map<String, dynamic> u;
  @override
  State<_Entrega> createState() => _EntregaState();
}

class _EntregaState extends State<_Entrega> {
  late final _b = TextEditingController(text: '${widget.u['cantidad_actual']}');
  final _s = TextEditingController(text: '0');
  @override
  Widget build(BuildContext context) {
    final total = widget.u['cantidad_actual'] as int;
    final b = int.tryParse(_b.text) ?? -1, s = int.tryParse(_s.text) ?? -1;
    final f = total - b - s;
    return AlertDialog(
      title: Text('Entregar ${widget.u['codigo']} de ${Colores.nombreProceso(widget.u['proceso_actual'])}'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Entraron $total prendas.'),
          const SizedBox(height: 10),
          TextField(controller: _b, decoration: const InputDecoration(labelText: 'Buenas'), keyboardType: TextInputType.number, onChanged: (_) => setState(() {})),
          const SizedBox(height: 10),
          TextField(controller: _s, decoration: const InputDecoration(labelText: 'Segundas'), keyboardType: TextInputType.number, onChanged: (_) => setState(() {})),
          const SizedBox(height: 10),
          Text('Faltantes: $f', style: estilo(15, peso: FontWeight.w600, color: f < 0 ? Colores.rojo : null)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: b < 0 || s < 0 || f < 0 ? null : () => Navigator.pop(context, (buenas: b, segundas: s)), child: const Text('Entregar')),
      ],
    );
  }
}
