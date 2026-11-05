import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../eficiencia/pantalla_eficiencia.dart' show descargarCsv;
import '../inventario/comun_inventario.dart' show db, mensajeError, Tabla;

const conceptosCosto = {'tela': 'Tela', 'insumos': 'Insumos', 'externos': 'Satélites', 'mano_obra': 'Mano de obra', 'indirectos': 'Indirectos', 'total': 'Total'};
Color? colorDesviacion(num? d) => d == null ? null : d > 5 ? Colores.rojo : d < -5 ? Colores.verde : null;

/// Costos: costo real vs estándar de cada OP y su detalle por concepto.
class PantallaCostos extends ConsumerStatefulWidget {
  const PantallaCostos({super.key});
  @override
  ConsumerState<PantallaCostos> createState() => _PantallaCostosState();
}

class _PantallaCostosState extends ConsumerState<PantallaCostos> {
  DateTime _desde = DateTime.now().subtract(const Duration(days: 60));
  DateTime _hasta = DateTime.now();
  late Future<List<Map<String, dynamic>>> _datos = _cargar();
  late final Future<List<dynamic>> _vm = db.rpc('valor_minuto_vigente').then((v) => v as List);

  String _iso(DateTime d) => d.toIso8601String().substring(0, 10);
  Future<List<Map<String, dynamic>>> _cargar() async =>
      ((await db.rpc('informe_costos', params: {'p_desde': _iso(_desde), 'p_hasta': _iso(_hasta)})) as List).cast<Map<String, dynamic>>();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Costos', subtitulo: 'Costo real vs estándar por OP: tela, insumos, satélites, mano de obra e indirectos'),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (t, v, f) in [('Desde', _desde, (DateTime x) => _desde = x), ('Hasta', _hasta, (DateTime x) => _hasta = x)])
          OutlinedButton.icon(
            onPressed: () async {
              final x = await showDatePicker(context: context, initialDate: v, firstDate: DateTime(2025), lastDate: DateTime.now().add(const Duration(days: 1)));
              if (x != null) {
                f(x);
                setState(() => _datos = _cargar());
              }
            },
            icon: const Icon(Icons.event, size: 18),
            label: Text('$t ${Formato.fecha(v)}'),
          ),
        FutureBuilder<List<dynamic>>(
          future: _vm,
          builder: (_, s) {
            final v = (s.data?.isNotEmpty ?? false) ? s.data!.first as Map : null;
            return Text(v == null ? '' : 'Valor del minuto ${Formato.cop(v['valor_minuto'])} · indirectos ${Formato.cop(v['indirecto_minuto'])} por minuto',
                style: estilo(13, color: Colores.textoSuave));
          },
        ),
        TextButton(onPressed: () => context.go('/configuracion'), child: const Text('Cambiar en Configuración')),
      ]),
      const SizedBox(height: 14),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final xs = s.data!;
          final est = xs.fold<num>(0, (a, x) => a + (x['estandar'] ?? 0));
          final real = xs.fold<num>(0, (a, x) => a + (x['valor_real'] ?? 0));
          return Tarjeta(
            titulo: 'Órdenes de producción · estándar ${Formato.cop(est)} · real ${Formato.cop(real)}',
            accion: OutlinedButton.icon(
              onPressed: xs.isEmpty
                  ? null
                  : () => descargarCsv('costos_${_iso(_desde)}_${_iso(_hasta)}.csv',
                      ['OP', 'Referencia', 'Estado', 'Cortadas', 'Terminadas', 'Estándar', 'Real', 'Desviación %', 'Unitario estándar', 'Unitario real'],
                      [for (final x in xs) [x['op'], x['referencia'], x['estado'], x['prendas'], x['buenas'], x['estandar'], x['valor_real'], x['desviacion_pct'],
                        x['unitario_estandar'], x['unitario_real']]]),
              icon: const Icon(Icons.download),
              label: const Text('Excel (CSV)'),
            ),
            child: Tabla(
              columnas: const ['OP', 'Referencia', 'Cortadas', 'Terminadas', 'Estándar', 'Real', 'Desviación', 'Real por prenda', ''],
              numericas: const {2, 3, 4, 5, 6, 7},
              vacio: 'No hay OP en el rango.',
              filas: [
                for (final x in xs)
                  DataRow(cells: [
                    DataCell(Text('${x['op']}', style: estiloCodigo(13))),
                    DataCell(Tooltip(message: '${x['referencia']} · ${'${x['estado']}'.replaceAll('_', ' ')}', child: Text('${x['referencia']}'.split(' ').first))),
                    DataCell(Text(Formato.numero(x['prendas'] ?? 0, decimales: 0))),
                    DataCell(Text(Formato.numero(x['buenas'] ?? 0, decimales: 0))),
                    DataCell(Text(Formato.cop(x['estandar'] ?? 0))),
                    DataCell(Text(Formato.cop(x['valor_real'] ?? 0), style: estilo(14, peso: FontWeight.w600))),
                    DataCell(Text(x['desviacion_pct'] == null ? '—' : '${Formato.numero(x['desviacion_pct'], decimales: 1)} %',
                        style: estilo(14, peso: FontWeight.w600, color: colorDesviacion(x['desviacion_pct'] as num?)))),
                    DataCell(Text(x['unitario_real'] == null ? '—' : Formato.cop(x['unitario_real']))),
                    DataCell(TextButton(onPressed: () => showDialog(context: context, builder: (_) => DetalleCostoOp(opId: x['op_id'], titulo: '${x['op']} · ${x['referencia']}')),
                        child: const Text('Detalle'))),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}

/// Estándar vs real por concepto de una OP (lo usa también el detalle de la OP)
class TablaCostoOp extends StatelessWidget {
  const TablaCostoOp({super.key, required this.filas});
  final List<Map<String, dynamic>> filas;
  @override
  Widget build(BuildContext context) {
    final total = filas.where((f) => f['concepto'] == 'total').firstOrNull;
    final base = (total?['detalle']?['prendas_base'] ?? 0) as num;
    final buenas = (total?['detalle']?['prendas_buenas'] ?? 0) as num;
    final mo = filas.where((f) => f['concepto'] == 'mano_obra').firstOrNull?['detalle'];
    final mats = ((filas.where((f) => f['concepto'] == 'tela').firstOrNull?['detalle']?['materiales'] ?? []) as List).cast<Map<String, dynamic>>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tabla(
        columnas: const ['Concepto', 'Estándar', 'Real', 'Desviación'],
        numericas: const {1, 2, 3},
        filas: [
          for (final f in filas)
            DataRow(cells: [
              DataCell(Text(conceptosCosto[f['concepto']] ?? '${f['concepto']}', style: estilo(14, peso: f['concepto'] == 'total' ? FontWeight.w700 : FontWeight.w400))),
              DataCell(Text(Formato.cop(f['estandar'] ?? 0))),
              DataCell(Text(Formato.cop(f['valor_real'] ?? 0), style: estilo(14, peso: FontWeight.w600))),
              DataCell(Text(f['desviacion_pct'] == null ? '—' : '${Formato.numero(f['desviacion_pct'], decimales: 1)} %',
                  style: estilo(14, peso: FontWeight.w600, color: colorDesviacion(f['desviacion_pct'] as num?)))),
            ]),
        ],
      ),
      const SizedBox(height: 8),
      Text(
          'Base: ${Formato.numero(base, decimales: 0)} prendas cortadas'
          '${base > 0 ? ' · real por prenda cortada ${Formato.cop((total!['valor_real'] as num) / base)} (estándar ${Formato.cop((total['estandar'] as num) / base)})' : ''}'
          '${buenas > 0 ? ' · ${Formato.numero(buenas, decimales: 0)} terminadas' : ''}'
          '${mo != null ? ' · mano de obra: ${Formato.numero(mo['minutos_marcados'] ?? 0, decimales: 0)} min marcados + ${Formato.numero(mo['minutos_sin_marcar_estandar'] ?? 0, decimales: 0)} min de operaciones sin marcar (al estándar)' : ''}',
          style: estilo(12.5, color: Colores.textoSuave)),
      if (mats.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Materiales que salieron para la OP', style: estilo(13.5, peso: FontWeight.w600)),
        for (final m in mats)
          Text('• ${m['material']}: ${Formato.numero(m['cantidad'] ?? 0, decimales: 2)} ${m['unidad']} · ${Formato.cop(m['valor'] ?? 0)}', style: estilo(13)),
      ],
    ]);
  }
}

class DetalleCostoOp extends StatelessWidget {
  const DetalleCostoOp({super.key, required this.opId, required this.titulo});
  final String opId, titulo;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Costo de $titulo'),
        content: SizedBox(
          width: 620,
          child: FutureBuilder<List<dynamic>>(
            future: db.rpc('costo_op_detalle', params: {'p_op': opId}).then((v) => v as List),
            builder: (_, s) {
              if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
              if (!s.hasData) return const LinearProgressIndicator();
              return SingleChildScrollView(child: TablaCostoOp(filas: s.data!.cast<Map<String, dynamic>>()));
            },
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      );
}
