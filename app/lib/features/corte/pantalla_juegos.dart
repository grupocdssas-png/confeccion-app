import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, muestraColor;
import 'impresion_corte.dart';

final _juegosOpProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, op) async {
  final r = await Future.wait<dynamic>([
    db.from('ordenes_produccion').select('id, consecutivo, estado, cantidad_total, referencias(codigo, nombre), op_procesos(proceso, estado, buenas)')
        .eq('id', op).single(),
    db.rpc('simular_juegos', params: {'p_op': op}),
    db.from('juegos').select('id, codigo, cantidad, estado, creado_en, ficha_combinaciones(codigo, nombre), tallas(codigo, orden), '
        'juego_componentes(cantidad, paquetes(codigo, lote_tintura), ficha_partes(nombre, orden))').eq('op_id', op).order('codigo', ascending: true),
    db.from('paquetes').select('codigo, completo, cantidad, color_id').eq('op_id', op).eq('estado', 'cortado'),
    db.from('cortes').select('id, consecutivo, estado').eq('op_id', op).order('creado_en', ascending: false),
    db.from('colores').select('id, nombre, hex'),
  ]);
  return {'op': r[0], 'sim': r[1], 'juegos': r[2], 'paquetes': r[3], 'cortes': r[4], 'colores': {for (final c in r[5] as List) c['id']: c}};
});

/// Piezas cortadas de una OP, juegos posibles, qué falta recortar, juegos armados y sus etiquetas.
class PantallaJuegosOp extends ConsumerWidget {
  const PantallaJuegosOp({super.key, required this.opId});
  final String opId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_juegosOpProvider(opId));
    final editar = ref.watch(sesionProvider).value?.puedeEditar('corte') ?? false;
    return datos.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (d) {
        final op = d['op'] as Map<String, dynamic>;
        final sim = d['sim'] as Map<String, dynamic>;
        final juegos = (d['juegos'] as List).cast<Map<String, dynamic>>();
        final detalle = (sim['detalle'] as List).cast<Map<String, dynamic>>();
        final sueltas = (sim['sueltas'] as List).cast<Map<String, dynamic>>();
        final colores = d['colores'] as Map;
        final corte = (op['op_procesos'] as List).firstWhere((p) => p['proceso'] == 'corte', orElse: () => null);
        final completas = (d['paquetes'] as List).where((p) => p['completo'] == true).fold<int>(0, (a, p) => a + (p['cantidad'] as int));
        final activa = op['estado'] == 'planeada' || op['estado'] == 'en_proceso';
        final terminado = corte?['estado'] == 'terminado';

        Future<void> accion(Future<void> Function() f) async {
          try {
            await f();
            ref.invalidate(_juegosOpProvider(opId));
          } catch (e) {
            if (context.mounted) avisar(context, mensajeError(e), error: true);
          }
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('Piezas y juegos · ${op['consecutivo']}',
              subtitulo: '${op['referencias']['codigo']} ${op['referencias']['nombre']} · ${Formato.numero(op['cantidad_total'], decimales: 0)} prendas · '
                  'cortadas ${Formato.numero(corte?['buenas'] ?? 0, decimales: 0)}${terminado ? ' · corte terminado' : ''}',
              acciones: [
                OutlinedButton(onPressed: () => context.go('/corte'), child: const Text('Volver')),
                OutlinedButton(onPressed: () => context.go('/op/$opId'), child: const Text('Ver OP')),
                if (editar && activa && !terminado)
                  FilledButton.icon(
                    onPressed: (sim['juegos'] as int) == 0
                        ? null
                        : () => accion(() async {
                              final r = await db.rpc('armar_juegos', params: {'p_op': opId}) as Map<String, dynamic>;
                              if (context.mounted) avisar(context, '${r['juegos']} prendas armadas en juegos');
                            }),
                    icon: const Icon(Icons.join_inner),
                    label: Text('Armar ${sim['juegos']} juegos'),
                  ),
                if (editar && activa && !terminado)
                  OutlinedButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dl) => AlertDialog(
                          title: const Text('Terminar el corte de la OP'),
                          content: Text('Quedan ${Formato.numero(corte?['buenas'] ?? 0, decimales: 0)} prendas cortadas de ${op['cantidad_total']}. '
                              'La OP pasa al siguiente proceso y no se confirman más cortes.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dl, false), child: const Text('Cancelar')),
                            FilledButton(onPressed: () => Navigator.pop(dl, true), child: const Text('Terminar corte')),
                          ],
                        ),
                      );
                      if (ok == true) await accion(() => db.rpc('terminar_corte_op', params: {'p_op': opId}));
                    },
                    child: const Text('Terminar corte'),
                  ),
              ]),
          if (completas > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Además hay $completas prendas en paquetes completos (el tendido trae todas las partes: no necesitan juego).',
                  style: estilo(13.5, color: Colores.textoSuave)),
            ),
          Tarjeta(
            titulo: 'Juegos por combinación y talla',
            child: Tabla(
              columnas: const ['Combinación', 'Talla', 'Pedido', 'Armados', 'Se pueden armar', 'Qué falta recortar'],
              numericas: const {2, 3, 4},
              vacio: 'Todavía no hay piezas cortadas.',
              filas: [
                for (final x in detalle)
                  DataRow(cells: [
                    DataCell(Text('${x['combinacion']}', style: estilo(14, peso: FontWeight.w600))),
                    DataCell(Text('${x['talla']}', style: estilo(14, peso: FontWeight.w700))),
                    DataCell(Text('${x['pedido']}')),
                    DataCell(Text('${x['hechos']}')),
                    DataCell(Text('${(x['arma'] as int) + ((x['extra'] ?? 0) as int)}${x['extra'] != null ? ' (${x['extra']} de más)' : ''}',
                        style: estilo(14, peso: FontWeight.w600, color: (x['arma'] as int) > 0 ? Colores.verde : null))),
                    DataCell((x['faltan'] as List).isEmpty
                        ? Text((x['hechos'] as int) + (x['arma'] as int) >= (x['pedido'] as int) ? 'Completo' : '—', style: estilo(13, color: Colores.verde))
                        : Wrap(spacing: 6, children: [
                            for (final f in x['faltan'] as List)
                              Pastilla('${f['parte']} ${colores[f['color_id']]?['nombre'] ?? ''}: ${f['faltan']}', color: Colores.rojo),
                          ])),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Piezas sueltas (sin juego)',
            child: sueltas.isEmpty
                ? Text('No hay piezas sueltas.', style: estilo(14, color: Colores.textoSuave))
                : Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in sueltas)
                      Chip(
                        avatar: muestraColor(colores[s['color_id']]?['hex']),
                        label: Text('${s['parte']} ${s['color']} · ${s['talla']}: ${s['cantidad']}'),
                      ),
                  ]),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Juegos armados (${juegos.length})',
            accion: FilledButton.icon(
              onPressed: juegos.isEmpty ? null : () => imprimirJuegosWeb(context, op, juegos),
              icon: const Icon(Icons.print_outlined),
              label: const Text('Imprimir etiquetas'),
            ),
            child: Tabla(
              columnas: const ['Juego', 'Combinación', 'Talla', 'Prendas', 'Paquetes de cada parte'],
              numericas: const {3},
              vacio: 'Sin juegos armados.',
              filas: [
                for (final j in juegos)
                  DataRow(cells: [
                    DataCell(Text('${j['codigo']}', style: estiloCodigo(13))),
                    DataCell(Text('${j['ficha_combinaciones']['codigo']} · ${j['ficha_combinaciones']['nombre']}')),
                    DataCell(Text('${j['tallas']['codigo']}', style: estilo(14, peso: FontWeight.w700))),
                    DataCell(Text('${j['cantidad']}')),
                    DataCell(Text(() {
                      // partes que vienen del mismo paquete se muestran juntas: "Cuerpo + Mangas PQ-C01-000001"
                      final porPaquete = <String, List<String>>{};
                      final comps = (j['juego_componentes'] as List).cast<Map<String, dynamic>>()
                        ..sort((a, b) => (a['ficha_partes']['orden'] as int).compareTo(b['ficha_partes']['orden'] as int));
                      for (final c in comps) {
                        (porPaquete['${c['paquetes']['codigo']} (${c['cantidad']})'] ??= []).add('${c['ficha_partes']['nombre']}');
                      }
                      return porPaquete.entries.map((e) => '${e.value.join(' + ')} ${e.key}').join(' · ');
                    }())),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Cortes de esta OP',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in d['cortes'] as List)
                ActionChip(label: Text('${c['consecutivo']} · ${c['estado']}'), onPressed: () => context.go('/corte/${c['id']}')),
            ]),
          ),
        ]);
      },
    );
  }
}
