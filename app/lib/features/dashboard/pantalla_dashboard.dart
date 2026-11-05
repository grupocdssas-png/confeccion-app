import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, mensajeError;

final dashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async => Map<String, dynamic>.from(await db.rpc('dashboard') as Map));

/// Dashboard: indicadores de la planta, Kanban de OP por proceso y alertas abiertas.
class PantallaDashboard extends ConsumerWidget {
  const PantallaDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(dashboardProvider);
    return datos.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (d) {
        final ind = Map<String, dynamic>.from(d['indicadores'] as Map);
        final procesos = (d['procesos'] as List).cast<Map<String, dynamic>>();
        final ops = (d['ops'] as List).cast<Map<String, dynamic>>();
        final alertas = (d['alertas'] as List).cast<Map<String, dynamic>>();
        String n(Object? v) => v == null ? '—' : Formato.numero(v as num, decimales: 0);
        String pct(Object? v) => v == null ? '—' : '${Formato.numero(v as num, decimales: 1)} %';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('Dashboard', subtitulo: 'Producción hoy, ${Formato.fecha(DateTime.parse('${d['hoy']}T12:00:00Z'))}'),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Indicador('OP activas', n(ind['ops_activas'])),
            _Indicador('OP atrasadas', n(ind['ops_atrasadas']), color: (ind['ops_atrasadas'] as num? ?? 0) > 0 ? Colores.rojo : null, ir: '/informes?i=atrasadas'),
            _Indicador('Prendas en proceso', n(ind['prendas_en_proceso'])),
            _Indicador('Eficiencia hoy', pct(ind['eficiencia_hoy']), color: ind['eficiencia_hoy'] == null ? null : Colores.semaforo((ind['eficiencia_hoy'] as num).toDouble()), ir: '/eficiencia'),
            _Indicador('Terminadas (7 días)', n(ind['terminadas_semana']), ir: '/inventario/producto'),
            _Indicador('Aceptación calidad (7 días)', pct(ind['aceptacion_calidad']), ir: '/calidad'),
            _Indicador('Por despachar', n(ind['por_despachar']), ir: '/inventario/despachos'),
            _Indicador('Paros activos', n(ind['paros_activos']), color: (ind['paros_activos'] as num? ?? 0) > 0 ? Colores.ambar : null),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Text('Órdenes de producción por proceso', style: estilo(16, peso: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(onPressed: () => ref.invalidate(dashboardProvider), icon: const Icon(Icons.refresh, size: 18), label: const Text('Actualizar')),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 380,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final p in procesos)
                  _Columna(proceso: p, ops: ops.where((o) => o['proceso'] == p['codigo']).toList()),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Tarjeta(
            titulo: 'Alertas abiertas · ${n(ind['alertas'])}',
            child: alertas.isEmpty
                ? Padding(padding: const EdgeInsets.all(12), child: Text('No hay alertas abiertas.', style: estilo(14, color: Colores.textoSuave)))
                : Column(children: [
                    for (final a in alertas)
                      ListTile(
                        dense: true,
                        leading: Icon(a['severidad'] == 'alta' ? Icons.error : Icons.warning_amber,
                            color: a['severidad'] == 'alta' ? Colores.rojo : a['severidad'] == 'media' ? Colores.ambar : Colores.textoSuave),
                        title: Text('${a['mensaje']}', style: estilo(14)),
                        trailing: Text(Formato.fechaHora(DateTime.parse(a['creada'])), style: estilo(12.5, color: Colores.textoSuave)),
                      ),
                  ]),
          ),
        ]);
      },
    );
  }
}

class _Indicador extends StatelessWidget {
  const _Indicador(this.titulo, this.valor, {this.color, this.ir});
  final String titulo, valor;
  final Color? color;
  final String? ir;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: ir == null ? null : () => context.go(ir!),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 196,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colores.borde)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: estilo(12.5, color: Colores.textoSuave)),
            const SizedBox(height: 4),
            Text(valor, style: estilo(26, peso: FontWeight.w700, color: color)),
          ]),
        ),
      );
}

class _Columna extends StatelessWidget {
  const _Columna({required this.proceso, required this.ops});
  final Map<String, dynamic> proceso;
  final List<Map<String, dynamic>> ops;
  @override
  Widget build(BuildContext context) {
    final color = Colores.deProceso('${proceso['codigo']}');
    final prendas = ops.fold<int>(0, (a, o) => a + ((o['prendas'] ?? 0) as int));
    return Container(
      width: 250,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(color: Colores.fondo, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colores.borde)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: color, width: 4))),
          child: Row(children: [
            Expanded(child: Text('${proceso['nombre']}', style: estilo(14.5, peso: FontWeight.w700))),
            Text('${ops.length} OP · ${Formato.numero(prendas, decimales: 0)}', style: estilo(12, color: Colores.textoSuave)),
          ]),
        ),
        Expanded(
          child: ops.isEmpty
              ? Center(child: Text('Sin OP', style: estilo(13, color: Colores.textoSuave)))
              : ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), children: [for (final o in ops) _Tarjeta(o: o, color: color)]),
        ),
      ]),
    );
  }
}

class _Tarjeta extends StatelessWidget {
  const _Tarjeta({required this.o, required this.color});
  final Map<String, dynamic> o;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final aqui = (o['prendas'] ?? 0) as num;
    final term = (o['terminadas'] ?? 0) as num;
    final cant = (o['cantidad'] ?? 0) as num;
    final enProc = (o['en_proceso'] ?? 0) as num, esp = (o['esperando'] ?? 0) as num, sat = (o['en_satelite'] ?? 0) as num;
    final entrega = o['entrega'] == null ? null : DateTime.parse('${o['entrega']}T12:00:00Z');
    final atrasada = o['atrasada'] == true;
    final riesgo = o['en_riesgo'] == true;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: atrasada ? Colores.rojo : Colores.borde)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.go('/op/${o['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${o['consecutivo']}', style: estiloCodigo(13.5, peso: FontWeight.w700))),
              if (o['alerta_material'] == true) const Tooltip(message: 'Falta material', child: Icon(Icons.inventory_2_outlined, size: 16, color: Colores.ambar)),
              if ((o['devoluciones'] ?? 0) as num > 0)
                Tooltip(message: 'Devoluciones de calidad abiertas', child: Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.replay, size: 16, color: Colores.rojo))),
            ]),
            Text('${o['referencia']} · ${o['nombre']}', style: estilo(12.5, color: Colores.textoSuave), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Text('${Formato.numero(aqui, decimales: 0)} prendas aquí', style: estilo(14, peso: FontWeight.w600)),
            Text([
              if (enProc > 0) '$enProc en proceso${sat > 0 ? ' ($sat en satélite)' : ''}',
              if (esp > 0) '$esp esperando',
            ].join(' · '), style: estilo(12, color: Colores.textoSuave)),
            const SizedBox(height: 6),
            Tooltip(
              message: 'Terminadas de la OP: ${Formato.numero(term, decimales: 0)} de ${Formato.numero(cant, decimales: 0)}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: cant == 0 ? 0 : (term / cant).clamp(0, 1).toDouble(), minHeight: 5, color: Colores.verde, backgroundColor: Colores.borde),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Text('${Formato.numero(term, decimales: 0)} / ${Formato.numero(cant, decimales: 0)} terminadas', style: estilo(12, color: Colores.textoSuave)),
              const Spacer(),
              if (entrega != null)
                Text(Formato.fecha(entrega),
                    style: estilo(12.5, peso: atrasada || riesgo ? FontWeight.w700 : FontWeight.w400,
                        color: atrasada ? Colores.rojo : riesgo ? Colores.ambar : Colores.textoSuave)),
            ]),
          ]),
        ),
      ),
    );
  }
}
