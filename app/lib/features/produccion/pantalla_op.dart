import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, avisar, pedirTexto;
import 'comun_produccion.dart';
import 'op_pdf.dart';
import 'unidades_op.dart';

final opDetalleProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  final op = await db.from('ordenes_produccion').select('*, referencias(codigo, nombre), ficha_versiones(id, version), '
      'op_cantidades(cantidad, ficha_combinaciones(codigo, nombre, orden), tallas(codigo, orden)), '
      'op_procesos(*), op_necesidades(*, materiales(codigo, nombre, unidad, tipo), colores(nombre)), '
      'op_pedidos(cantidad, pedido_lineas(pedido_id, pedidos(consecutivo)))').eq('id', id).single();
  // Historial: avances (las recepciones de cada paquete o juego se ven en "Paquetes y juegos")
  final eventos = await db.from('eventos_proceso').select('*, perfiles:usuario_id(nombre), satelites(nombre), paquetes(codigo), juegos!eventos_proceso_juego_id_fkey(codigo), '
      'estaciones(codigo)').eq('op_id', id).neq('tipo', 'recepcion').order('ocurrido_en', ascending: false).limit(200);
  final unidades = await db.from('unidades_trabajo').select('id').eq('op_id', id).limit(1);
  final req = await db.from('requisiciones').select('*, requisicion_lineas(*, materiales(nombre, unidad), colores(nombre), '
      'oc_lineas(cantidad_recibida, ordenes_compra(consecutivo, estado)))').eq('op_id', id).order('creado_en', ascending: false);
  return {...op, 'eventos': eventos, 'requisiciones': req, 'hay_unidades': unidades.isNotEmpty};
});

class PantallaOp extends ConsumerWidget {
  const PantallaOp({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(opDetalleProvider(id));
    final editar = ref.watch(sesionProvider).value?.puedeEditar('op') ?? false;
    return datos.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (o) {
        Future<void> accion(Future<void> Function() f, [String? ok]) async {
          try {
            await f();
            ref.invalidate(opDetalleProvider(id));
            if (ok != null && context.mounted) avisar(context, ok);
          } catch (e) {
            if (context.mounted) avisar(context, mensajeError(e), error: true);
          }
        }

        final cant = (o['op_cantidades'] as List).cast<Map<String, dynamic>>();
        final tallasOrd = (cant.map((c) => c['tallas']).toList()..sort((a, b) => (a['orden'] as int).compareTo(b['orden'] as int)))
            .map((t) => t['codigo'] as String).toSet().toList();
        final combs = ({for (final c in cant) c['ficha_combinaciones']['codigo']: c['ficha_combinaciones']}.values.toList()
          ..sort((a, b) => ((a['orden'] ?? 0) as num).compareTo((b['orden'] ?? 0) as num)));
        final matriz = <String, Map<String, int>>{};
        for (final c in cant) {
          (matriz[c['ficha_combinaciones']['codigo']] ??= {})[c['tallas']['codigo']] = c['cantidad'] as int;
        }
        final nombres = {for (final c in combs) c['codigo'] as String: c['nombre'] as String};
        final planeada = o['estado'] == 'planeada';
        final procesos = ((o['op_procesos'] as List).cast<Map<String, dynamic>>()..sort((a, b) => (a['orden'] as int).compareTo(b['orden'] as int)));
        final pedidos = {for (final p in o['op_pedidos'] as List) p['pedido_lineas']['pedidos']['consecutivo']: p['pedido_lineas']['pedido_id']};

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('${o['consecutivo']} · ${o['referencias']['codigo']} ${o['referencias']['nombre']}',
              subtitulo: '${Formato.numero(o['cantidad_total'], decimales: 0)} prendas · ficha v${o['ficha_versiones']['version']} · '
                  'creada el ${Formato.fecha(DateTime.parse(o['creado_en']))}${o['observacion'] != null ? ' · ${o['observacion']}' : ''}',
              acciones: [
                pastillaEstadoOp('${o['estado']}'),
                OutlinedButton(onPressed: () => context.go('/op'), child: const Text('Volver')),
                OutlinedButton.icon(onPressed: () => _imprimir(context, o, matriz, tallasOrd), icon: const Icon(Icons.print_outlined), label: const Text('Hoja de secuencia y máquinas')),
                OutlinedButton(onPressed: () => context.go('/fichas/${o['ficha_versiones']['id']}'), child: const Text('Ver ficha')),
                if (editar && (o['estado'] == 'planeada' || o['estado'] == 'en_proceso'))
                  OutlinedButton.icon(onPressed: () => accion(() => db.rpc('reservar_op', params: {'p_op': id}), 'Necesidades y reservas recalculadas'),
                      icon: const Icon(Icons.refresh), label: const Text('Recalcular reservas')),
                if (editar && planeada)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                    onPressed: () async {
                      final m = await pedirTexto(context, titulo: 'Anular ${o['consecutivo']}', etiqueta: 'Motivo (se liberan las reservas)');
                      if (m != null) await accion(() => db.rpc('anular_op', params: {'p_op': id, 'p_motivo': m}), 'OP anulada');
                    },
                    child: const Text('Anular')),
              ]),
          if (o['estado'] == 'anulada') AvisoSinConexion('Anulada: ${o['motivo_anulacion']}'),
          if (o['alerta_material'] == true)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colores.rojo.withValues(alpha: 0.08), border: Border.all(color: Colores.rojo.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(6)),
              child: Text('Falta material para esta OP. Se generó requisición de compra; al recibirlo se reserva solo.', style: estilo(14, peso: FontWeight.w600, color: Colores.rojo)),
            ),
          // ---- Datos y fechas ----
          Tarjeta(
            child: Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _dato('Entrega', diasRestantes(o['fecha_entrega_plan'], estado: o['estado'])),
              if (editar && (planeada || o['estado'] == 'en_proceso')) ...[
                CampoFecha(etiqueta: 'Inicio planeado', valor: o['fecha_inicio_plan'],
                    onCambio: (v) => accion(() => db.from('ordenes_produccion').update({'fecha_inicio_plan': v}).eq('id', id))),
                CampoFecha(etiqueta: 'Entrega planeada', valor: o['fecha_entrega_plan'],
                    onCambio: (v) => accion(() => db.from('ordenes_produccion').update({'fecha_entrega_plan': v}).eq('id', id))),
                CampoFecha(etiqueta: 'Comprometida', valor: o['fecha_comprometida'],
                    onCambio: (v) => accion(() => db.from('ordenes_produccion').update({'fecha_comprometida': v}).eq('id', id))),
                SizedBox(width: 150, child: DropdownButtonFormField<int>(
                  initialValue: o['prioridad'], decoration: const InputDecoration(labelText: 'Prioridad', isDense: true),
                  items: [for (var i = 1; i <= 5; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                  onChanged: (v) => accion(() => db.from('ordenes_produccion').update({'prioridad': v}).eq('id', id)))),
              ] else ...[
                _dato('Inicio planeado', Text(o['fecha_inicio_plan'] == null ? '—' : Formato.fecha(DateTime.parse('${o['fecha_inicio_plan']}T12:00:00Z')))),
                _dato('Prioridad', Text('${o['prioridad']}')),
              ],
              if (pedidos.isNotEmpty)
                _dato('Pedidos', Wrap(spacing: 6, children: [
                  for (final p in pedidos.entries) ActionChip(label: Text('${p.key}'), onPressed: () => context.go('/pedidos/${p.value}')),
                ])),
            ]),
          ),
          const SizedBox(height: 16),
          // ---- Cantidades ----
          Tarjeta(
            titulo: 'Cantidades por combinación y talla',
            accion: editar && planeada
                ? OutlinedButton.icon(
                    onPressed: () async {
                      final nuevo = await showDialog<Map<String, Map<String, int>>>(context: context, builder: (_) => _DialogoCantidades(
                          combinaciones: combs.map((c) => c['codigo'] as String).toList(), tallas: tallasOrd, nombres: nombres, valores: matriz));
                      if (nuevo != null) await accion(() => db.rpc('actualizar_cantidades_op', params: {'p_op': id, 'p_cantidades': nuevo}), 'Cantidades y reservas actualizadas');
                    },
                    icon: const Icon(Icons.edit_outlined), label: const Text('Cambiar cantidades'))
                : null,
            child: MatrizCantidades(combinaciones: combs.map((c) => c['codigo'] as String).toList(), tallas: tallasOrd, nombres: nombres, valores: matriz),
          ),
          const SizedBox(height: 16),
          // ---- Línea de tiempo de procesos ----
          Tarjeta(
            titulo: 'Línea de tiempo de procesos',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final (i, p) in procesos.indexed)
                  _Proceso(p: p, actual: o['proceso_actual'] == p['proceso'],
                      // solo donde puede entrar algo: el primero o si el anterior ya entregó prendas buenas
                      // con paquetes o juegos el avance después de corte se registra por unidad (tablet o "Paquetes y juegos")
                      onAvance: editar && (planeada || o['estado'] == 'en_proceso') && p['estado'] != 'terminado'
                              && !(o['hay_unidades'] == true && p['proceso'] != 'corte')
                              && (i == 0 || (procesos[i - 1]['buenas'] as int) > (p['entra'] as int))
                          ? () async {
                              final ok = await showDialog<bool>(context: context, builder: (_) => _DialogoAvance(op: o, proceso: p));
                              if (ok == true) ref.invalidate(opDetalleProvider(id));
                            }
                          : null),
              ]),
              const SizedBox(height: 14),
              Text('Historial de avances', style: estilo(13, peso: FontWeight.w600, color: Colores.textoSuave)),
              Tabla(
                columnas: const ['Fecha', 'Proceso', 'Paquete / juego', 'Entra', 'Buenas', 'Segundas', 'Faltantes', 'Responsable', 'Observación'],
                numericas: const {3, 4, 5, 6},
                vacio: 'Sin avances todavía.',
                filas: [
                  for (final e in o['eventos'] as List)
                    DataRow(cells: [
                      DataCell(Text(Formato.fechaHora(DateTime.parse(e['ocurrido_en'])))),
                      DataCell(Pastilla(Colores.nombreProceso(e['proceso']), color: Colores.deProceso(e['proceso']))),
                      DataCell(Text('${e['paquetes']?['codigo'] ?? e['juegos']?['codigo'] ?? '—'}${e['tipo'] == 'anulacion' ? ' (anulación)' : ''}', style: estiloCodigo(12.5))),
                      DataCell(Text('${e['entra']}')), DataCell(Text('${e['buenas']}')), DataCell(Text('${e['segundas']}')), DataCell(Text('${e['faltantes']}')),
                      DataCell(Text('${e['satelites']?['nombre'] ?? e['estaciones']?['codigo'] ?? e['perfiles']?['nombre'] ?? ''}${e['termina'] == true ? ' · terminó' : ''}')),
                      DataCell(Text('${e['observacion'] ?? ''}')),
                    ]),
                ],
              ),
            ]),
          ),
          const SizedBox(height: 16),
          UnidadesOp(opId: id, editar: editar, onCambio: () => ref.invalidate(opDetalleProvider(id))),
          const SizedBox(height: 16),
          // ---- Materiales ----
          Tarjeta(
            titulo: 'Materiales: estándar, reservado y faltante',
            child: Tabla(
              columnas: const ['Material', 'Color', 'Estándar', 'Reservado', 'Faltante', 'Consumido real', 'Unidad'],
              numericas: const {2, 3, 4, 5},
              filas: [
                for (final n in ((o['op_necesidades'] as List).cast<Map<String, dynamic>>()..sort((a, b) => '${a['materiales']['tipo']}${a['materiales']['nombre']}'.compareTo('${b['materiales']['tipo']}${b['materiales']['nombre']}'))))
                  DataRow(cells: [
                    DataCell(Text('${n['materiales']['nombre']}')),
                    DataCell(Text('${n['colores']?['nombre'] ?? '—'}')),
                    DataCell(Text(Formato.numero(n['cantidad_estandar'], decimales: 2))),
                    DataCell(Text(Formato.numero(n['reservado'], decimales: 2), style: const TextStyle(color: Colores.verde))),
                    DataCell((n['faltante'] as num) > 0 ? Text(Formato.numero(n['faltante'], decimales: 2), style: const TextStyle(color: Colores.rojo, fontWeight: FontWeight.w700)) : const Text('—')),
                    DataCell(Text((n['consumido'] as num) == 0 ? '—' : Formato.numero(n['consumido'], decimales: 2))),
                    DataCell(Text('${n['materiales']['unidad']}')),
                  ]),
              ],
            ),
          ),
          if ((o['requisiciones'] as List).isNotEmpty) ...[
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Requisiciones de compra',
              accion: TextButton(onPressed: () => context.go('/compras'), child: const Text('Ir a compras')),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final r in o['requisiciones'] as List) ...[
                  Text('${r['consecutivo']} · ${r['estado']}', style: estilo(14, peso: FontWeight.w600)),
                  for (final l in r['requisicion_lineas'] as List)
                    Text('• ${l['materiales']['nombre']} ${l['colores']?['nombre'] ?? ''}: ${Formato.numero(l['cantidad'], decimales: 2)} ${l['materiales']['unidad']}'
                        '${l['oc_lineas'] != null ? ' · en ${l['oc_lineas']['ordenes_compra']['consecutivo']} (${l['oc_lineas']['ordenes_compra']['estado']})' : ' · sin orden de compra'}',
                        style: estilo(13.5)),
                ],
              ]),
            ),
          ],
        ]);
      },
    );
  }

  Widget _dato(String t, Widget v) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(t, style: estilo(12, color: Colores.textoSuave)),
        const SizedBox(height: 4),
        v,
      ]);

  Future<void> _imprimir(BuildContext context, Map<String, dynamic> o, Map<String, Map<String, int>> matriz, List<String> tallas) async {
    try {
      final ops = (await db.from('ficha_operaciones').select('*, operaciones(codigo, nombre), tipos_maquina(codigo, nombre)')
          .eq('ficha_id', o['ficha_versiones']['id']).order('secuencia', ascending: true)).cast<Map<String, dynamic>>();
      final bytes = await hojasOpPdf(o, ops, matriz, tallas);
      await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: 'Hojas ${o['consecutivo']}');
    } catch (e) {
      if (context.mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}

class _Proceso extends StatelessWidget {
  const _Proceso({required this.p, required this.actual, this.onAvance});
  final Map<String, dynamic> p;
  final bool actual;
  final VoidCallback? onAvance;
  @override
  Widget build(BuildContext context) {
    final color = Colores.deProceso(p['proceso']);
    final estado = p['estado'] as String;
    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: estado == 'terminado' ? color.withValues(alpha: 0.08) : Colors.white,
        border: Border.all(color: actual || estado != 'pendiente' ? color : Colores.borde, width: actual ? 2.5 : 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${p['orden']}. ${Colores.nombreProceso(p['proceso'])}', style: estilo(14.5, peso: FontWeight.w600, color: color)),
          const Spacer(),
          Icon(estado == 'terminado' ? Icons.check_circle : estado == 'en_proceso' ? Icons.timelapse : Icons.radio_button_unchecked, size: 18, color: color),
        ]),
        if (p['modalidad'] != 'interno') Text(p['modalidad'] == 'satelite' ? 'Satélite' : 'Interno o satélite', style: estilo(11.5, color: Colores.textoSuave)),
        const SizedBox(height: 6),
        Text('Entra ${p['entra']} · buenas ${p['buenas']}', style: estilo(13)),
        if ((p['segundas'] as int) + (p['faltantes'] as int) > 0) Text('Segundas ${p['segundas']} · faltantes ${p['faltantes']}', style: estilo(12.5, color: Colores.ambar)),
        if (p['inicio'] != null) Text('Desde ${Formato.fechaHora(DateTime.parse(p['inicio']))}', style: estilo(11.5, color: Colores.textoSuave)),
        if (p['fin'] != null) Text('Terminó ${Formato.fechaHora(DateTime.parse(p['fin']))}', style: estilo(11.5, color: Colores.textoSuave)),
        if (onAvance != null) Padding(padding: const EdgeInsets.only(top: 6), child: TextButton(onPressed: onAvance, child: const Text('Registrar avance'))),
      ]),
    );
  }
}

class _DialogoAvance extends StatefulWidget {
  const _DialogoAvance({required this.op, required this.proceso});
  final Map<String, dynamic> op, proceso;
  @override
  State<_DialogoAvance> createState() => _DialogoAvanceState();
}

class _DialogoAvanceState extends State<_DialogoAvance> {
  final _c = {for (final k in ['entra', 'buenas', 'segundas', 'faltantes']) k: TextEditingController(text: k == 'entra' || k == 'buenas' ? '' : '0')};
  final _obs = TextEditingController();
  var _termina = false;
  String? _error;
  int _n(String k) => int.tryParse(_c[k]!.text.replaceAll('.', '')) ?? 0;

  @override
  Widget build(BuildContext context) {
    final cuadra = _n('entra') == _n('buenas') + _n('segundas') + _n('faltantes');
    return AlertDialog(
      title: Text('Avance de ${Colores.nombreProceso(widget.proceso['proceso'])} · ${widget.op['consecutivo']}'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Una OP no avanza sin cantidades: lo que entra debe ser igual a buenas + segundas + faltantes.', style: estilo(13, color: Colores.textoSuave)),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final (k, t) in [('entra', 'Entra'), ('buenas', 'Buenas'), ('segundas', 'Segundas'), ('faltantes', 'Faltantes')])
              SizedBox(width: 100, child: TextField(controller: _c[k], keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: t, isDense: true))),
          ]),
          const SizedBox(height: 8),
          Text(cuadra ? 'Cuadra' : 'No cuadra: ${_n('entra')} ≠ ${_n('buenas') + _n('segundas') + _n('faltantes')}',
              style: estilo(13, peso: FontWeight.w600, color: cuadra ? Colores.verde : Colores.rojo)),
          const SizedBox(height: 8),
          TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación', isDense: true)),
          Row(children: [
            Checkbox(value: _termina, onChanged: (v) => setState(() => _termina = v!)),
            const Text('Con esto se termina el proceso'),
          ]),
          if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: !cuadra || _n('entra') == 0 ? null : () async {
            try {
              await db.rpc('registrar_avance', params: {
                'p_op': widget.op['id'], 'p_proceso': widget.proceso['proceso'], 'p_entra': _n('entra'), 'p_buenas': _n('buenas'),
                'p_segundas': _n('segundas'), 'p_faltantes': _n('faltantes'), 'p_termina': _termina,
                'p_observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(),
              });
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              setState(() => _error = mensajeError(e));
            }
          },
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}

class _DialogoCantidades extends StatefulWidget {
  const _DialogoCantidades({required this.combinaciones, required this.tallas, required this.nombres, required this.valores});
  final List<String> combinaciones, tallas;
  final Map<String, String> nombres;
  final Map<String, Map<String, int>> valores;
  @override
  State<_DialogoCantidades> createState() => _DialogoCantidadesState();
}

class _DialogoCantidadesState extends State<_DialogoCantidades> {
  late final _v = {for (final e in widget.valores.entries) e.key: {...e.value}};
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Cambiar cantidades'),
        content: SizedBox(width: 760, child: Column(mainAxisSize: MainAxisSize.min, children: [
          MatrizCantidades(combinaciones: widget.combinaciones, tallas: widget.tallas, nombres: widget.nombres, valores: _v,
              onCambio: (c, t, n) => setState(() => (_v[c] ??= {})[t] = n)),
          Text('Al guardar se recalculan las necesidades: se reserva lo que falte y se libera lo que sobre.', style: estilo(12.5, color: Colores.textoSuave)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, _v), child: const Text('Guardar')),
        ],
      );
}
