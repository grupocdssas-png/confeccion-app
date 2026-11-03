import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError;
import 'comun_produccion.dart';
import 'pantalla_pedidos.dart' show DialogoNuevaOp;

final _opsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, filtro) {
  var q = db.from('ordenes_produccion').select('*, referencias(codigo, nombre), ficha_versiones(version)');
  if (filtro == 'activas') q = q.inFilter('estado', ['planeada', 'en_proceso']);
  if (filtro != 'activas' && filtro != 'todas') q = q.eq('estado', filtro);
  return q.order('prioridad', ascending: true).order('fecha_entrega_plan', ascending: true).limit(500);
});

class PantallaOps extends ConsumerStatefulWidget {
  const PantallaOps({super.key});
  @override
  ConsumerState<PantallaOps> createState() => _PantallaOpsState();
}

class _PantallaOpsState extends ConsumerState<PantallaOps> {
  var _filtro = 'activas';
  var _buscar = '';

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_opsProvider(_filtro));
    final editar = ref.watch(sesionProvider).value?.puedeEditar('op') ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Órdenes de producción', subtitulo: 'Por prioridad y fecha de entrega · proceso actual · alerta si falta material', acciones: [
        SizedBox(width: 220, child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'OP o referencia', isDense: true),
            onChanged: (v) => setState(() => _buscar = v.toLowerCase()))),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'activas', label: Text('Activas')), ButtonSegment(value: 'terminada', label: Text('Terminadas')),
            ButtonSegment(value: 'anulada', label: Text('Anuladas')), ButtonSegment(value: 'todas', label: Text('Todas'))],
          selected: {_filtro},
          onSelectionChanged: (s) => setState(() => _filtro = s.first),
        ),
        if (editar)
          FilledButton.icon(
            onPressed: () async {
              final id = await showDialog<String>(context: context, builder: (_) => const DialogoNuevaOp());
              if (id != null && context.mounted) context.go('/op/$id');
            },
            icon: const Icon(Icons.add), label: const Text('Nueva OP')),
      ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) {
          final lista = l.where((o) => '${o['consecutivo']} ${o['referencias']['codigo']} ${o['referencias']['nombre']}'.toLowerCase().contains(_buscar)).toList();
          return Tarjeta(
            padding: EdgeInsets.zero,
            child: Tabla(
              columnas: const ['OP', 'Referencia', 'Ficha', 'Cantidad', 'Prioridad', 'Proceso actual', 'Entrega', 'Material', 'Estado', ''],
              numericas: const {3},
              vacio: 'No hay órdenes con este filtro.',
              filas: [
                for (final o in lista)
                  DataRow(cells: [
                    DataCell(Text('${o['consecutivo']}', style: estiloCodigo(13))),
                    DataCell(Text('${o['referencias']['codigo']} · ${o['referencias']['nombre']}')),
                    DataCell(Text('v${o['ficha_versiones']?['version']}')),
                    DataCell(Text(Formato.numero(o['cantidad_total'], decimales: 0), style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text('${o['prioridad']}', style: TextStyle(color: (o['prioridad'] as int) <= 2 ? Colores.rojo : null, fontWeight: FontWeight.w600))),
                    DataCell(o['proceso_actual'] == null ? const Text('—')
                        : Pastilla(Colores.nombreProceso(o['proceso_actual']), color: Colores.deProceso(o['proceso_actual']))),
                    DataCell(diasRestantes(o['fecha_entrega_plan'], estado: o['estado'])),
                    DataCell(o['alerta_material'] == true ? const Pastilla('Falta material', color: Colores.rojo, icono: Icons.warning_amber_rounded)
                        : const Pastilla('Completo', color: Colores.verde)),
                    DataCell(pastillaEstadoOp('${o['estado']}')),
                    DataCell(TextButton(onPressed: () => context.go('/op/${o['id']}'), child: const Text('Abrir'))),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}
