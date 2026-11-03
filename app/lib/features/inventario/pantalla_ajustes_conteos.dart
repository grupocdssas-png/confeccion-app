import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'comun_inventario.dart';

// =====================================================================
// Ajustes
// =====================================================================
final _ajustesProvider = FutureProvider.autoDispose((ref) => db
    .from('ajustes_inventario')
    .select('*, conteos_fisicos:conteo_id(consecutivo), ajuste_lineas(*, materiales(nombre, unidad), colores(nombre), rollos(codigo), '
        'bodegas(nombre), ubicaciones(codigo)), solicitante:solicitado_por(nombre), aprobador:aprobado_por(nombre)')
    .order('creado_en', ascending: false)
    .limit(200));

class PantallaAjustes extends ConsumerWidget {
  const PantallaAjustes({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_ajustesProvider);
    final aprobar = puedeAprobarInventario(ref);
    final yo = ref.watch(sesionProvider).value;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Ajustes de inventario',
          subtitulo: 'Toda salida que no va a una OP necesita un ajuste con motivo, aprobado por otra persona.',
          acciones: [
            if (puedeEditarInventario(ref))
              FilledButton.icon(
                onPressed: () async {
                  final ok = await showDialog<bool>(context: context, builder: (_) => const _DialogoNuevoAjuste());
                  if (ok == true) ref.invalidate(_ajustesProvider);
                },
                icon: const Icon(Icons.add),
                label: const Text('Nuevo ajuste'),
              ),
          ]),
      const PestanasInventario('ajustes'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (ajustes) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (ajustes.isEmpty) Tarjeta(child: Text('No hay ajustes.', style: estilo(14, color: Colores.textoSuave))),
          for (final a in ajustes) ...[
            Tarjeta(
              titulo: '${a['consecutivo']} · ${a['motivo']}',
              accion: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                pastillaEstadoDoc('${a['estado']}'),
                if (a['estado'] == 'enviado' && aprobar && (a['solicitado_por'] != yo?.usuarioId || yo?.esGerencia == true)) ...[
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                    onPressed: () async {
                      final c = await pedirTexto(context, titulo: 'Rechazar ajuste', etiqueta: 'Motivo del rechazo');
                      if (c == null || !context.mounted) return;
                      await _decidir(context, ref, a['id'], false, c);
                    },
                    child: const Text('Rechazar'),
                  ),
                  FilledButton(onPressed: () => _decidir(context, ref, a['id'], true, null), child: const Text('Aprobar')),
                ],
                if (a['estado'] == 'borrador' && puedeEditarInventario(ref))
                  FilledButton(
                    onPressed: () async {
                      try {
                        await db.rpc('enviar_ajuste', params: {'p_ajuste': a['id']});
                        ref.invalidate(_ajustesProvider);
                      } catch (e) {
                        if (context.mounted) avisar(context, mensajeError(e), error: true);
                      }
                    },
                    child: const Text('Enviar a aprobación'),
                  ),
              ]),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  [
                    'Solicitó ${a['solicitante']?['nombre'] ?? '—'} el ${Formato.fechaHora(DateTime.parse(a['creado_en']))}',
                    if (a['conteos_fisicos'] != null) 'Origen: conteo ${a['conteos_fisicos']['consecutivo']}',
                    if (a['aprobador'] != null) '${a['estado'] == 'rechazado' ? 'Rechazó' : 'Aprobó'} ${a['aprobador']['nombre']}',
                    if (a['comentario'] != null) '«${a['comentario']}»',
                  ].join(' · '),
                  style: estilo(13, color: Colores.textoSuave),
                ),
                const SizedBox(height: 6),
                Tabla(
                  columnas: const ['Material', 'Color', 'Rollo', 'Bodega / ubicación', 'Cantidad', 'Observación'],
                  numericas: const {4},
                  filas: [
                    for (final l in (a['ajuste_lineas'] as List).cast<Map<String, dynamic>>())
                      DataRow(cells: [
                        DataCell(Text('${l['materiales']['nombre']}')),
                        DataCell(Text('${l['colores']?['nombre'] ?? '—'}')),
                        DataCell(Text('${l['rollos']?['codigo'] ?? '—'}', style: estiloCodigo(13))),
                        DataCell(Text('${l['bodegas']['nombre']} ${l['ubicaciones']?['codigo'] ?? ''}')),
                        DataCell(Text('${Formato.dos(l['cantidad'])} ${l['materiales']['unidad']}',
                            style: TextStyle(color: (l['cantidad'] as num) < 0 ? Colores.rojo : Colores.verde, fontWeight: FontWeight.w600))),
                        DataCell(Text('${l['observacion'] ?? ''}')),
                      ]),
                  ],
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],
        ]),
      ),
    ]);
  }

  Future<void> _decidir(BuildContext context, WidgetRef ref, String id, bool aprobar, String? comentario) async {
    try {
      await db.rpc('decidir_ajuste', params: {'p_ajuste': id, 'p_aprobar': aprobar, 'p_comentario': comentario});
      ref.invalidate(_ajustesProvider);
      if (context.mounted) avisar(context, aprobar ? 'Ajuste aprobado: el inventario se actualizó' : 'Ajuste rechazado');
    } catch (e) {
      if (context.mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}

class _DialogoNuevoAjuste extends ConsumerStatefulWidget {
  const _DialogoNuevoAjuste();
  @override
  ConsumerState<_DialogoNuevoAjuste> createState() => _DialogoNuevoAjusteState();
}

class _DialogoNuevoAjusteState extends ConsumerState<_DialogoNuevoAjuste> {
  final _motivo = TextEditingController();
  final _cantidad = TextEditingController();
  final _rollo = TextEditingController();
  String? _material, _color, _bodega, _ubicacion;
  var _sumar = false;
  String? _error;

  Future<void> _guardar(Catalogos c) async {
    try {
      final m = c.material(_material);
      if (m == null || _bodega == null) throw 'Elija material y bodega';
      Map<String, dynamic>? rollo;
      if (m['tipo'] == 'tela') {
        rollo = await db.from('rollos').select().eq('codigo', _rollo.text.trim().toUpperCase()).maybeSingle();
        if (rollo == null) throw 'Para telas indique el rollo (TL-…) a ajustar';
      }
      final cant = numeroCo(_cantidad.text);
      if (cant == null || cant <= 0) throw 'Cantidad inválida';
      final signo = _sumar ? 1 : -1;
      final unidadKg = m['unidad'] == 'kg';
      final aj = await db.from('ajustes_inventario').insert({'motivo': _motivo.text.trim()}).select('id').single();
      await db.from('ajuste_lineas').insert({
        'ajuste_id': aj['id'], 'material_id': _material,
        'color_id': rollo?['color_id'] ?? _color,
        'rollo_id': rollo?['id'],
        'bodega_id': rollo?['bodega_id'] ?? _bodega,
        'ubicacion_id': rollo?['ubicacion_id'] ?? _ubicacion,
        'cantidad': signo * cant,
        if (rollo != null) ...{
          // proporción de metros/kilos según la unidad del material
          'metros': signo * (unidadKg ? cant * (rollo['metros_saldo'] / (rollo['kilos_saldo'] == 0 ? 1 : rollo['kilos_saldo'])) : cant),
          'kilos': signo * (unidadKg ? cant : cant * (rollo['kilos_saldo'] / (rollo['metros_saldo'] == 0 ? 1 : rollo['metros_saldo']))),
        },
      });
      await db.rpc('enviar_ajuste', params: {'p_ajuste': aj['id']});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e is String ? e : mensajeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(catalogosProvider).value;
    if (c == null) return const AlertDialog(content: LinearProgressIndicator());
    final m = c.material(_material);
    return AlertDialog(
      title: const Text('Nuevo ajuste'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _motivo, decoration: const InputDecoration(labelText: 'Motivo (obligatorio)', hintText: 'Ej.: rollo con daño de tintura')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Material'),
            items: [for (final x in c.materiales) DropdownMenuItem(value: x['id'] as String, child: Text('${x['codigo']} · ${x['nombre']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _material = v),
          ),
          const SizedBox(height: 10),
          if (m?['tipo'] == 'tela')
            TextField(controller: _rollo, decoration: const InputDecoration(labelText: 'Rollo', hintText: 'TL-000123'))
          else ...[
            if (m?['maneja_color'] == true)
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Color'),
                items: [for (final x in c.colores) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
                onChanged: (v) => _color = v,
              ),
            const SizedBox(height: 10),
          ],
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Bodega'),
                items: [for (final b in c.bodegas) DropdownMenuItem(value: b['id'] as String, child: Text('${b['nombre']}'))],
                onChanged: (v) => setState(() => _bodega = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(_bodega),
                decoration: const InputDecoration(labelText: 'Ubicación'),
                items: [for (final u in c.ubicacionesDe(_bodega)) DropdownMenuItem(value: u['id'] as String, child: Text('${u['codigo']}'))],
                onChanged: (v) => _ubicacion = v,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Restar')), ButtonSegment(value: true, label: Text('Sumar'))],
              selected: {_sumar},
              onSelectionChanged: (s) => setState(() => _sumar = s.first),
            ),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _cantidad, decoration: InputDecoration(labelText: 'Cantidad (${m?['unidad'] ?? ''})'))),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: estilo(13, color: Colores.rojo))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => _guardar(c), child: const Text('Enviar a aprobación')),
      ],
    );
  }
}

// =====================================================================
// Conteos
// =====================================================================
final _conteosProvider = FutureProvider.autoDispose((ref) => db
    .from('conteos_fisicos')
    .select('*, bodegas(nombre), ubicaciones(codigo), conteo_registros(count), ajustes_inventario:ajuste_id(consecutivo, estado)')
    .order('abierto_en', ascending: false)
    .limit(100));

class PantallaConteosWeb extends ConsumerWidget {
  const PantallaConteosWeb({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_conteosProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Conteos físicos', subtitulo: 'Se abren aquí y se cuentan con el celular de bodega (también sin conexión).', acciones: [
        if (puedeEditarInventario(ref))
          FilledButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (_) => const _DialogoAbrirConteo());
              if (ok == true) ref.invalidate(_conteosProvider);
            },
            icon: const Icon(Icons.add),
            label: const Text('Abrir conteo'),
          ),
      ]),
      const PestanasInventario('conteos'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (filas) => Tarjeta(
          padding: EdgeInsets.zero,
          child: Tabla(
            columnas: const ['Conteo', 'Abierto', 'Bodega', 'Ubicación', 'Alcance', 'Registros', 'Estado', 'Ajuste', ''],
            numericas: const {5},
            vacio: 'No hay conteos.',
            filas: [
              for (final c in filas)
                DataRow(cells: [
                  DataCell(Text('${c['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text(Formato.fechaHora(DateTime.parse(c['abierto_en'])))),
                  DataCell(Text('${c['bodegas']['nombre']}')),
                  DataCell(Text('${c['ubicaciones']?['codigo'] ?? 'Toda'}')),
                  DataCell(Text('${c['alcance']}')),
                  DataCell(Text('${(c['conteo_registros'] as List).firstOrNull?['count'] ?? 0}')),
                  DataCell(pastillaEstadoDoc('${c['estado']}')),
                  DataCell(Text('${c['ajustes_inventario']?['consecutivo'] ?? '—'}')),
                  DataCell(TextButton(onPressed: () => context.go('/inventario/conteos/${c['id']}'), child: const Text('Abrir'))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _DialogoAbrirConteo extends ConsumerStatefulWidget {
  const _DialogoAbrirConteo();
  @override
  ConsumerState<_DialogoAbrirConteo> createState() => _DialogoAbrirConteoState();
}

class _DialogoAbrirConteoState extends ConsumerState<_DialogoAbrirConteo> {
  String? _bodega, _ubicacion;
  var _alcance = 'todo';
  String? _error;
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(catalogosProvider).value;
    if (c == null) return const AlertDialog(content: LinearProgressIndicator());
    return AlertDialog(
      title: const Text('Abrir conteo físico'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            decoration: const InputDecoration(labelText: 'Bodega'),
            items: [for (final b in c.bodegas) DropdownMenuItem(value: b['id'] as String, child: Text('${b['nombre']}'))],
            onChanged: (v) => setState(() => _bodega = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            key: ValueKey(_bodega),
            decoration: const InputDecoration(labelText: 'Ubicación (vacío = toda la bodega)'),
            items: [const DropdownMenuItem(value: null, child: Text('Toda la bodega')),
              for (final u in c.ubicacionesDe(_bodega)) DropdownMenuItem(value: u['id'] as String, child: Text('${u['codigo']}'))],
            onChanged: (v) => _ubicacion = v,
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'todo', label: Text('Todo')), ButtonSegment(value: 'telas', label: Text('Telas')),
              ButtonSegment(value: 'insumos', label: Text('Insumos'))],
            selected: {_alcance},
            onSelectionChanged: (s) => setState(() => _alcance = s.first),
          ),
          if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _bodega == null
              ? null
              : () async {
                  try {
                    await db.from('conteos_fisicos').insert({'bodega_id': _bodega, 'ubicacion_id': _ubicacion, 'alcance': _alcance});
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    setState(() => _error = mensajeError(e));
                  }
                },
          child: const Text('Abrir'),
        ),
      ],
    );
  }
}

class PantallaDetalleConteo extends ConsumerStatefulWidget {
  const PantallaDetalleConteo({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PantallaDetalleConteo> createState() => _PantallaDetalleConteoState();
}

class _PantallaDetalleConteoState extends ConsumerState<PantallaDetalleConteo> {
  late Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<dynamic>)> _datos = _cargar();
  RealtimeChannel? _canal;

  @override
  void initState() {
    super.initState();
    // Se actualiza solo cuando llegan registros del celular
    _canal = db.channel('conteo-${widget.id}').onPostgresChanges(
      event: PostgresChangeEvent.insert, schema: 'public', table: 'conteo_registros',
      filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'conteo_id', value: widget.id),
      callback: (_) { if (mounted) setState(() => _datos = _cargar()); },
    ).subscribe();
  }

  @override
  void dispose() {
    if (_canal != null) unawaited(db.removeChannel(_canal!));
    super.dispose();
  }

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<dynamic>)> _cargar() async {
    final c = await db.from('conteos_fisicos').select('*, bodegas(nombre), ubicaciones(codigo), ajustes_inventario:ajuste_id(consecutivo, estado)')
        .eq('id', widget.id).single();
    final regs = await db.from('conteo_registros').select('*, rollos(codigo), materiales(nombre, unidad), ubicaciones(codigo), dispositivos(nombre)')
        .eq('conteo_id', widget.id).order('ocurrido_en', ascending: false);
    final dif = await db.rpc('diferencias_conteo', params: {'p_conteo': widget.id}) as List;
    return (c, regs, dif);
  }

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogosProvider).value;
    return FutureBuilder(
      future: _datos,
      builder: (context, s) {
        if (s.hasError) return Text(mensajeError(s.error!));
        if (!s.hasData) return const LinearProgressIndicator();
        final (c, regs, dif) = s.data!;
        final rollosCont = regs.where((r) => r['rollo_id'] != null).length;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('Conteo ${c['consecutivo']}',
              subtitulo: '${c['bodegas']['nombre']} · ${c['ubicaciones']?['codigo'] ?? 'toda la bodega'} · ${c['alcance']} · se actualiza solo',
              acciones: [
                pastillaEstadoDoc('${c['estado']}'),
                OutlinedButton(onPressed: () => context.go('/inventario/conteos'), child: const Text('Volver')),
                if (c['estado'] == 'abierto' && puedeEditarInventario(ref))
                  FilledButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                        title: const Text('Cerrar conteo'),
                        content: Text(dif.where((x) => (x['diferencia'] as num) != 0).isEmpty
                            ? 'No hay diferencias. El conteo queda ajustado.'
                            : 'Se generará un ajuste con ${dif.where((x) => (x['diferencia'] as num) != 0).length} diferencias para aprobación. Los registros que lleguen después se rechazan.'),
                        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Cerrar conteo'))],
                      ));
                      if (ok != true) return;
                      try {
                        await db.rpc('cerrar_conteo', params: {'p_conteo': widget.id});
                        setState(() => _datos = _cargar());
                      } catch (e) {
                        if (context.mounted) avisar(context, mensajeError(e), error: true);
                      }
                    },
                    child: const Text('Cerrar conteo'),
                  ),
              ]),
          if (c['ajustes_inventario'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Ajuste generado: ${c['ajustes_inventario']['consecutivo']} (${c['ajustes_inventario']['estado']}). Apruébelo en Ajustes.',
                  style: estilo(14, peso: FontWeight.w600)),
            ),
          Wrap(spacing: 16, runSpacing: 16, children: [
            _Cifra('Rollos contados', '$rollosCont'),
            _Cifra('Registros de insumos', '${regs.length - rollosCont}'),
            _Cifra('Diferencias', '${dif.where((x) => (x['diferencia'] as num) != 0).length}', color: Colores.rojo),
          ]),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Diferencias contra el sistema',
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Tabla(
              columnas: const ['Material', 'Rollo', 'Ubicación', 'Sistema', 'Contado', 'Diferencia', 'Observación'],
              numericas: const {3, 4, 5},
              vacio: 'Sin diferencias por ahora.',
              filas: [
                for (final d in dif)
                  DataRow(cells: [
                    DataCell(Text('${cat?.material(d['material_id'])?['nombre'] ?? ''}')),
                    DataCell(Text('${regs.firstWhere((r) => r['rollo_id'] == d['rollo_id'], orElse: () => {})['rollos']?['codigo'] ?? (d['rollo_id'] == null ? '—' : '(no contado)')}',
                        style: estiloCodigo(13))),
                    DataCell(Text('${cat?.ubicaciones.where((u) => u['id'] == d['ubicacion_id']).firstOrNull?['codigo'] ?? '—'}')),
                    DataCell(Text(Formato.dos(d['sistema']))),
                    DataCell(Text(Formato.dos(d['contado']))),
                    DataCell(Text(Formato.dos(d['diferencia']), style: TextStyle(fontWeight: FontWeight.w600,
                        color: (d['diferencia'] as num) < 0 ? Colores.rojo : (d['diferencia'] as num) > 0 ? Colores.verde : Colores.textoSuave))),
                    DataCell(Text('${d['observacion'] ?? ''}')),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Registros recibidos (${regs.length})',
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Tabla(
              columnas: const ['Hora', 'Rollo / insumo', 'Cantidad', 'Ubicación', 'Dispositivo'],
              filas: [
                for (final r in regs.take(300))
                  DataRow(cells: [
                    DataCell(Text(Formato.hora(DateTime.parse(r['ocurrido_en'])))),
                    DataCell(Text(r['rollos']?['codigo'] ?? r['materiales']?['nombre'] ?? (r['anula_id'] != null ? 'Anulación' : ''))),
                    DataCell(Text(r['cantidad'] == null ? '—' : '${Formato.dos(r['cantidad'])} ${r['materiales']?['unidad'] ?? ''}')),
                    DataCell(Text('${r['ubicaciones']?['codigo'] ?? '—'}')),
                    DataCell(Text('${r['dispositivos']?['nombre'] ?? 'Web'}')),
                  ]),
              ],
            ),
          ),
        ]);
      },
    );
  }
}

class _Cifra extends StatelessWidget {
  const _Cifra(this.t, this.v, {this.color});
  final String t, v;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
        child: Tarjeta(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: estilo(13, color: Colores.textoSuave)),
          Text(v, style: estilo(26, peso: FontWeight.w600, color: color)),
        ])),
      );
}
