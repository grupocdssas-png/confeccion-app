import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError;
import '../produccion/comun_produccion.dart' show diasRestantes;
import 'datos_corte.dart';

final _opsPorCortarProvider = FutureProvider.autoDispose((ref) async {
  final l = await db.from('ordenes_produccion').select('id, consecutivo, estado, prioridad, cantidad_total, fecha_entrega_plan, alerta_material, '
      'referencias(codigo, nombre), op_procesos(proceso, estado, buenas)').inFilter('estado', ['planeada', 'en_proceso'])
      .order('prioridad', ascending: true).order('fecha_entrega_plan', ascending: true);
  return l.where((o) => (o['op_procesos'] as List).any((p) => p['proceso'] == 'corte' && p['estado'] != 'terminado')).toList();
});

final _cortesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, filtro) {
  var q = db.from('cortes').select('id, consecutivo, tipo, estado, creado_en, confirmado_en, op_id, resultado, '
      'ordenes_produccion(consecutivo, referencias(codigo, nombre)), estaciones(codigo)');
  if (filtro != 'todos') q = q.eq('estado', filtro);
  return q.order('creado_en', ascending: false).limit(200);
});

class PantallaCortes extends ConsumerStatefulWidget {
  const PantallaCortes({super.key});
  @override
  ConsumerState<PantallaCortes> createState() => _PantallaCortesState();
}

class _PantallaCortesState extends ConsumerState<PantallaCortes> {
  var _filtro = 'todos';

  Future<void> _nuevo(Map<String, dynamic> op) async {
    try {
      final id = await db.rpc('guardar_corte', params: {
        'p': {'op_id': op['id'], 'tipo': 'combinada', 'despunte_cm': 2, 'documento': {'bloques': [], 'rollos': {}}},
      });
      if (mounted) context.go('/corte/$id');
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('corte') ?? false;
    final ops = ref.watch(_opsPorCortarProvider);
    final cortes = ref.watch(_cortesProvider(_filtro));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Corte', subtitulo: 'Tendidos normales y por espigas · paquetes por color, lote y talla · juegos de prenda combinada'),
      Tarjeta(
        titulo: 'OP por cortar',
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: ops.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
          data: (l) => Tabla(
            columnas: const ['OP', 'Referencia', 'Prendas', 'Cortadas', 'Entrega', ''],
            numericas: const {2, 3},
            vacio: 'No hay OP pendientes de corte.',
            filas: [
              for (final o in l)
                DataRow(cells: [
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${o['consecutivo']}', style: estiloCodigo(13)),
                    const SizedBox(width: 6),
                    Text('P${o['prioridad']}', style: estilo(12.5, peso: FontWeight.w700, color: (o['prioridad'] as int) <= 2 ? Colores.rojo : Colores.textoSuave)),
                    if (o['alerta_material'] == true)
                      const Padding(padding: EdgeInsets.only(left: 6), child: Tooltip(message: 'Falta material', child: Icon(Icons.warning_amber_rounded, size: 18, color: Colores.rojo))),
                  ])),
                  DataCell(ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text('${o['referencias']['codigo']} · ${o['referencias']['nombre']}', overflow: TextOverflow.ellipsis))),
                  DataCell(Text(Formato.numero(o['cantidad_total'], decimales: 0))),
                  DataCell(Text(Formato.numero((o['op_procesos'] as List).firstWhere((p) => p['proceso'] == 'corte')['buenas'], decimales: 0))),
                  DataCell(diasRestantes(o['fecha_entrega_plan'], estado: o['estado'])),
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    if (editar) FilledButton.tonal(onPressed: () => _nuevo(o), child: const Text('Nuevo corte')),
                    const SizedBox(width: 6),
                    TextButton(onPressed: () => context.go('/corte/op/${o['id']}'), child: const Text('Juegos')),
                  ])),
                ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Cortes',
        accion: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'todos', label: Text('Todos')),
            ButtonSegment(value: 'borrador', label: Text('Borradores')),
            ButtonSegment(value: 'confirmado', label: Text('Confirmados')),
            ButtonSegment(value: 'anulado', label: Text('Anulados')),
          ],
          selected: {_filtro},
          onSelectionChanged: (s) => setState(() => _filtro = s.first),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: cortes.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
          data: (l) => Tabla(
            columnas: const ['Corte', 'OP', 'Referencia', 'Tipo', 'Mesa', 'Fecha', 'Paquetes', 'Estado', ''],
            numericas: const {6},
            vacio: 'Sin cortes.',
            filas: [
              for (final c in l)
                DataRow(cells: [
                  DataCell(Text('${c['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text('${c['ordenes_produccion']['consecutivo']}')),
                  DataCell(Text('${c['ordenes_produccion']['referencias']['codigo']}')),
                  DataCell(Text(nombreTipoCorte(c['tipo']))),
                  DataCell(Text('${c['estaciones']?['codigo'] ?? '—'}')),
                  DataCell(Text(Formato.fechaHora(DateTime.parse(c['confirmado_en'] ?? c['creado_en'])))),
                  DataCell(Text('${c['resultado']?['paquetes'] ?? '—'}')),
                  DataCell(switch (c['estado']) {
                    'borrador' => const Pastilla('Borrador', color: Colores.textoSuave),
                    'confirmado' => const Pastilla('Confirmado', color: Colores.verde),
                    _ => const Pastilla('Anulado', color: Colores.rojo),
                  }),
                  DataCell(TextButton(onPressed: () => context.go('/corte/${c['id']}'), child: const Text('Abrir'))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}
