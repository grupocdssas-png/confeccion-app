import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, numeroCo;
import '../produccion/comun_produccion.dart' show referenciasProduciblesProvider;

const _diasGantt = 42;

final programaProvider = FutureProvider.autoDispose((ref) async {
  final r = await Future.wait<dynamic>([
    db.from('celulas').select('*, turnos(id, nombre, hora_inicio, hora_fin, minutos_pausa)').eq('activo', true).not('proceso', 'is', null).order('codigo', ascending: true),
    db.from('programacion').select('*, ordenes_produccion(consecutivo, estado, cantidad_total, fecha_entrega_plan, prioridad, referencias(codigo, nombre))')
        .order('orden', ascending: true),
    db.from('empleados').select('id, codigo, nombres, apellidos, celula_id').eq('activo', true).order('codigo', ascending: true),
    db.from('turnos').select().eq('activo', true).order('hora_inicio', ascending: true),
    db.from('festivos').select().gte('fecha', fechaIso(DateTime.now().subtract(const Duration(days: 30)))).order('fecha', ascending: true),
  ]);
  final celulas = (r[0] as List).cast<Map<String, dynamic>>();
  final cargas = <String, List<Map<String, dynamic>>>{};
  await Future.wait([
    for (final c in celulas)
      db.rpc('programar_cola', params: {'p_celula': c['id'], 'p_escribir': false, 'p_dias': _diasGantt})
          .then((v) => cargas[c['id'] as String] = ((v as Map)['dias'] as List).cast<Map<String, dynamic>>()),
  ]);
  return {'celulas': celulas, 'programa': r[1], 'empleados': r[2], 'turnos': r[3], 'festivos': r[4], 'cargas': cargas};
});

String fechaIso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime _f(String s) => DateTime.parse('${s}T12:00:00Z');
String _corta(String? s) => s == null ? '—' : Formato.fecha(_f(s));

class PantallaProgramacion extends ConsumerStatefulWidget {
  const PantallaProgramacion({super.key});
  @override
  ConsumerState<PantallaProgramacion> createState() => _PantallaProgramacionState();
}

class _PantallaProgramacionState extends ConsumerState<PantallaProgramacion> {
  var _pestana = 'programa';

  Future<void> _accion(Future<void> Function() f, [String? ok]) async {
    try {
      await f();
      ref.invalidate(programaProvider);
      if (ok != null && mounted) avisar(context, ok);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('programacion') ?? false;
    final datos = ref.watch(programaProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Programación de planta', subtitulo: 'Cola de OP por célula según su capacidad (turno × operarios × eficiencia planeada)', acciones: [
        OutlinedButton.icon(
            onPressed: () => showDialog(context: context, builder: (_) => const _DialogoFechaPosible()),
            icon: const Icon(Icons.event_available),
            label: const Text('Fecha posible de entrega')),
        if (editar)
          OutlinedButton.icon(
              onPressed: () => _accion(() => db.rpc('reprogramar_todo'), 'Programa recalculado'), icon: const Icon(Icons.refresh), label: const Text('Recalcular')),
      ]),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Wrap(spacing: 8, children: [
          for (final (k, t) in const [('programa', 'Programa'), ('celulas', 'Células y turnos')])
            ChoiceChip(
              label: Text(t),
              selected: _pestana == k,
              showCheckmark: false,
              labelStyle: estilo(13.5, peso: FontWeight.w600, color: _pestana == k ? Colors.white : Colores.texto),
              selectedColor: Colores.texto,
              backgroundColor: Colors.white,
              side: const BorderSide(color: Colores.borde),
              onSelected: (_) => setState(() => _pestana = k),
            ),
        ]),
      ),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (d) => _pestana == 'celulas' ? _CelulasTurnos(d: d, editar: editar, accion: _accion) : _programa(d, editar),
      ),
    ]);
  }

  Widget _programa(Map<String, dynamic> d, bool editar) {
    final celulas = (d['celulas'] as List).cast<Map<String, dynamic>>();
    final programa = (d['programa'] as List).cast<Map<String, dynamic>>();
    final empleados = (d['empleados'] as List).cast<Map<String, dynamic>>();
    final cargas = d['cargas'] as Map<String, List<Map<String, dynamic>>>;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in celulas) ...[
        _TarjetaCelula(
          c: c,
          filas: programa.where((p) => p['celula_id'] == c['id']).toList(),
          operarios: (c['operarios_planeados'] as int?) ?? empleados.where((e) => e['celula_id'] == c['id']).length,
          dias: cargas[c['id']] ?? const [],
          editar: editar,
          accion: _accion,
        ),
        const SizedBox(height: 16),
      ],
    ]);
  }
}

class _TarjetaCelula extends StatelessWidget {
  const _TarjetaCelula({required this.c, required this.filas, required this.operarios, required this.dias, required this.editar, required this.accion});
  final Map<String, dynamic> c;
  final List<Map<String, dynamic>> filas;
  final int operarios;
  final List<Map<String, dynamic>> dias;
  final bool editar;
  final Future<void> Function(Future<void> Function(), [String?]) accion;

  @override
  Widget build(BuildContext context) {
    final cap = dias.isEmpty ? 0 : dias.map((x) => (x['capacidad'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
    final activas = filas.where((f) => f['fin_plan'] != null || f['inicio_plan'] != null).toList();
    return Tarjeta(
      titulo: '${c['codigo']} · ${c['nombre']} · ${Colores.nombreProceso(c['proceso'])}',
      accion: editar
          ? OutlinedButton.icon(
              onPressed: () async {
                final r = await showDialog<({String op, double? minutos})>(context: context, builder: (_) => _DialogoAgregarOp(celula: c));
                if (r != null) {
                  await accion(() => db.rpc('programar_op', params: {'p_op': r.op, 'p_proceso': c['proceso'], 'p_celula': c['id'], 'p_minutos_manual': r.minutos}),
                      'OP programada');
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Programar OP'))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('$operarios operarios · ${Formato.numero(cap, decimales: 0)} min-operario por día · eficiencia planeada '
            '${Formato.numero(c['eficiencia_planeada'], decimales: 0)} % · turno ${c['turnos']?['nombre'] ?? '—'}',
            style: estilo(13, color: Colores.textoSuave)),
        const SizedBox(height: 10),
        _Gantt(filas: activas, dias: dias),
        const SizedBox(height: 12),
        Tabla(
          columnas: const ['#', 'OP', 'Referencia', 'Prendas', 'Minutos', 'Inicio', 'Fin', 'Entrega', '', ''],
          numericas: const {3, 4},
          vacio: 'Sin OP programadas en esta célula.',
          filas: [
            for (final (i, f) in filas.indexed)
              () {
                final o = f['ordenes_produccion'] as Map<String, dynamic>;
                final entrega = o['fecha_entrega_plan'] as String?;
                final tarde = entrega != null && f['fin_plan'] != null && (f['fin_plan'] as String).compareTo(entrega) > 0;
                final sinFecha = f['fin_plan'] == null && ((f['minutos_requeridos'] ?? 0) as num) > 0;
                return DataRow(cells: [
                  DataCell(Text('${i + 1}')),
                  DataCell(TextButton(onPressed: () => context.go('/op/${f['op_id']}'), child: Text('${o['consecutivo']}', style: estiloCodigo(13)))),
                  DataCell(Text('${o['referencias']?['codigo'] ?? ''}')),
                  DataCell(Text(Formato.numero(o['cantidad_total'], decimales: 0))),
                  DataCell(Text(Formato.numero(f['minutos_requeridos'] ?? 0, decimales: 0))),
                  DataCell(Text(_corta(f['inicio_plan']))),
                  DataCell(Text(sinFecha ? 'Sin capacidad' : _corta(f['fin_plan']),
                      style: TextStyle(color: tarde || sinFecha ? Colores.rojo : null, fontWeight: tarde ? FontWeight.w700 : null))),
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_corta(entrega)),
                    if (tarde) const Padding(padding: EdgeInsets.only(left: 6), child: Pastilla('Atrasada', color: Colores.rojo)),
                    if ((f['minutos_requeridos'] ?? 0) == 0) const Padding(padding: EdgeInsets.only(left: 6), child: Pastilla('Terminada', color: Colores.verde)),
                  ])),
                  DataCell(!editar
                      ? const SizedBox.shrink()
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Subir', onPressed: i == 0 ? null : () => accion(() => db.rpc('mover_programacion', params: {'p_id': f['id'], 'p_direccion': -1})),
                              icon: const Icon(Icons.arrow_upward, size: 18)),
                          IconButton(tooltip: 'Bajar', onPressed: i == filas.length - 1 ? null : () => accion(() => db.rpc('mover_programacion', params: {'p_id': f['id'], 'p_direccion': 1})),
                              icon: const Icon(Icons.arrow_downward, size: 18)),
                        ])),
                  DataCell(!editar
                      ? const SizedBox.shrink()
                      : IconButton(tooltip: 'Quitar de la célula', onPressed: () => accion(() => db.rpc('quitar_programacion', params: {'p_id': f['id']})),
                          icon: const Icon(Icons.close, size: 18))),
                ]);
              }(),
          ],
        ),
      ]),
    );
  }
}

/// Gantt de la célula: una fila por OP con su barra de inicio a fin, y abajo la carga de cada día.
class _Gantt extends StatelessWidget {
  const _Gantt({required this.filas, required this.dias});
  final List<Map<String, dynamic>> filas;
  final List<Map<String, dynamic>> dias;
  static const _ancho = 26.0;

  @override
  Widget build(BuildContext context) {
    if (dias.isEmpty) return const SizedBox.shrink();
    final inicio = _f(dias.first['fecha'] as String);
    int indice(String? s) => s == null ? -1 : _f(s).difference(inicio).inDays;
    const colores = [Color(0xFF3F4A5A), Color(0xFF1F5FA8), Color(0xFF2F7A6A), Color(0xFFB4521C), Color(0xFF6B4FA0)];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 110,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 34),
            for (final f in filas) SizedBox(height: 26, child: Align(alignment: Alignment.centerLeft, child: Text('${f['ordenes_produccion']['consecutivo']}', style: estiloCodigo(12)))),
            SizedBox(height: 34, child: Align(alignment: Alignment.centerLeft, child: Text('Carga', style: estilo(12, color: Colores.textoSuave)))),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // encabezado de días
          Row(children: [
            for (final d in dias)
              () {
                final f = _f(d['fecha'] as String);
                final libre = (d['capacidad'] as num) == 0;
                return Container(
                  width: _ancho,
                  height: 34,
                  alignment: Alignment.center,
                  color: libre ? Colores.borde.withValues(alpha: 0.6) : null,
                  child: Text('${const ['L', 'M', 'X', 'J', 'V', 'S', 'D'][f.weekday - 1]}\n${f.day}',
                      textAlign: TextAlign.center, style: estilo(10.5, color: f.day == 1 ? Colores.texto : Colores.textoSuave, alto: 1.2)),
                );
              }(),
          ]),
          for (final (i, f) in filas.indexed)
            () {
              final a = indice(f['inicio_plan']).clamp(0, dias.length);
              final b = (f['fin_plan'] == null ? dias.length - 1 : indice(f['fin_plan'])).clamp(-1, dias.length - 1);
              final entrega = indice(f['ordenes_produccion']['fecha_entrega_plan']);
              final tarde = f['fin_plan'] != null && entrega >= -1000 && indice(f['fin_plan']) > entrega && f['ordenes_produccion']['fecha_entrega_plan'] != null;
              return SizedBox(
                height: 26,
                width: _ancho * dias.length,
                child: Stack(children: [
                  for (var j = 0; j < dias.length; j++)
                    if ((dias[j]['capacidad'] as num) == 0)
                      Positioned(left: j * _ancho, top: 0, bottom: 0, width: _ancho, child: Container(color: Colores.borde.withValues(alpha: 0.35))),
                  if (b >= a && a < dias.length)
                    Positioned(
                      left: a * _ancho + 1,
                      width: (b - a + 1) * _ancho - 2,
                      top: 4,
                      bottom: 4,
                      child: Container(
                        decoration: BoxDecoration(color: tarde ? Colores.rojo : colores[i % colores.length], borderRadius: BorderRadius.circular(4)),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 6),
                        child: Text('${f['ordenes_produccion']['referencias']?['codigo'] ?? ''}', overflow: TextOverflow.clip, maxLines: 1,
                            style: estilo(11, peso: FontWeight.w600, color: Colors.white)),
                      ),
                    ),
                  if (entrega >= 0 && entrega < dias.length)
                    Positioned(left: entrega * _ancho + _ancho / 2 - 1, top: 0, bottom: 0, width: 2, child: Container(color: Colores.rojo)),
                ]),
              );
            }(),
          // carga vs capacidad
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final d in dias)
              () {
                final cap = (d['capacidad'] as num).toDouble();
                final carga = (d['carga'] as num).toDouble();
                final pct = cap <= 0 ? 0.0 : (carga / cap).clamp(0.0, 1.0);
                return Tooltip(
                  message: '${Formato.fecha(_f(d['fecha'] as String))}: ${Formato.numero(carga, decimales: 0)} de ${Formato.numero(cap, decimales: 0)} min',
                  child: Container(
                    width: _ancho,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 28 * pct,
                      color: pct >= 0.999 ? Colores.ambar : Colores.verde.withValues(alpha: 0.7),
                    ),
                  ),
                );
              }(),
          ]),
        ]),
      ]),
    );
  }
}

class _DialogoAgregarOp extends StatefulWidget {
  const _DialogoAgregarOp({required this.celula});
  final Map<String, dynamic> celula;
  @override
  State<_DialogoAgregarOp> createState() => _DialogoAgregarOpState();
}

class _DialogoAgregarOpState extends State<_DialogoAgregarOp> {
  List<Map<String, dynamic>>? _ops;
  String? _op;
  final _min = TextEditingController();

  @override
  void initState() {
    super.initState();
    () async {
      final l = await db.from('ordenes_produccion').select('id, consecutivo, cantidad_total, fecha_entrega_plan, prioridad, referencias(codigo, nombre), '
          'op_procesos(proceso, estado), programacion(proceso, celula_id)').inFilter('estado', ['planeada', 'en_proceso'])
          .order('prioridad', ascending: true).order('fecha_entrega_plan', ascending: true);
      final p = widget.celula['proceso'];
      if (mounted) {
        setState(() => _ops = [
              for (final o in l)
                if ((o['op_procesos'] as List).any((x) => x['proceso'] == p && x['estado'] != 'terminado') &&
                    !(o['programacion'] as List).any((x) => x['proceso'] == p && x['celula_id'] == widget.celula['id']))
                  o,
            ]);
      }
    }();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Programar OP en ${widget.celula['codigo']}'),
        content: SizedBox(
          width: 520,
          child: _ops == null
              ? const LinearProgressIndicator()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_ops!.isEmpty) Text('No hay OP con ${Colores.nombreProceso(widget.celula['proceso'])} pendiente sin programar en esta célula.'),
                  RadioGroup<String>(
                    groupValue: _op,
                    onChanged: (v) => setState(() => _op = v),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final o in _ops!)
                        RadioListTile<String>(
                          value: o['id'] as String,
                          title: Text('${o['consecutivo']} · ${o['referencias']['codigo']} ${o['referencias']['nombre']}'),
                          subtitle: Text('${Formato.numero(o['cantidad_total'], decimales: 0)} prendas · prioridad ${o['prioridad']} · entrega ${_corta(o['fecha_entrega_plan'])}'
                              '${(o['programacion'] as List).any((x) => x['proceso'] == widget.celula['proceso']) ? ' · está en otra célula (se mueve)' : ''}'),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  TextField(controller: _min, decoration: const InputDecoration(labelText: 'Minutos (solo si la ficha no tiene SAM de este proceso)', isDense: true)),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: _op == null ? null : () => Navigator.pop(context, (op: _op!, minutos: numeroCo(_min.text))), child: const Text('Programar')),
        ],
      );
}

class _DialogoFechaPosible extends ConsumerStatefulWidget {
  const _DialogoFechaPosible();
  @override
  ConsumerState<_DialogoFechaPosible> createState() => _DialogoFechaPosibleState();
}

class _DialogoFechaPosibleState extends ConsumerState<_DialogoFechaPosible> {
  String? _ref;
  final _cant = TextEditingController(text: '500');
  List<Map<String, dynamic>>? _r;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final refs = ref.watch(referenciasProduciblesProvider).value ?? const [];
    return AlertDialog(
      title: const Text('Fecha posible de entrega'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Antes de comprometer una fecha: cuándo terminaría confección si la OP entra al final de la cola de cada módulo.',
              style: estilo(13.5, color: Colores.textoSuave)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _ref,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Referencia'),
            items: [for (final r in refs) DropdownMenuItem(value: r['id'] as String, child: Text('${r['codigo']} · ${r['nombre']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _ref = v),
          ),
          const SizedBox(height: 10),
          TextField(controller: _cant, decoration: const InputDecoration(labelText: 'Prendas'), keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: estilo(13.5, color: Colores.rojo)),
          if (_r != null)
            Tabla(
              columnas: const ['Célula', 'Minutos', 'Terminaría'],
              numericas: const {1},
              filas: [
                for (final x in _r!)
                  DataRow(cells: [
                    DataCell(Text('${x['codigo']} · ${x['nombre']}')),
                    DataCell(Text(Formato.numero(x['minutos'] ?? 0, decimales: 0))),
                    DataCell(Text(x['fecha_fin'] == null ? 'Sin capacidad' : _corta(x['fecha_fin']), style: estilo(14, peso: FontWeight.w700))),
                  ]),
              ],
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
        FilledButton(
          onPressed: _ref == null
              ? null
              : () async {
                  try {
                    final r = await db.rpc('fecha_posible', params: {'p_referencia': _ref, 'p_cantidad': int.tryParse(_cant.text.trim()) ?? 0});
                    setState(() {
                      _r = (r as List).cast<Map<String, dynamic>>();
                      _error = null;
                    });
                  } catch (e) {
                    setState(() => _error = mensajeError(e));
                  }
                },
          child: const Text('Calcular'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Células y turnos
// ---------------------------------------------------------------------------
class _CelulasTurnos extends StatelessWidget {
  const _CelulasTurnos({required this.d, required this.editar, required this.accion});
  final Map<String, dynamic> d;
  final bool editar;
  final Future<void> Function(Future<void> Function(), [String?]) accion;

  @override
  Widget build(BuildContext context) {
    final celulas = (d['celulas'] as List).cast<Map<String, dynamic>>();
    final turnos = (d['turnos'] as List).cast<Map<String, dynamic>>();
    final empleados = (d['empleados'] as List).cast<Map<String, dynamic>>();
    final festivos = (d['festivos'] as List).cast<Map<String, dynamic>>();
    const dias = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Células',
        child: Tabla(
          columnas: const ['Célula', 'Proceso', 'Turno', 'Días laborales', 'Eficiencia planeada', 'Operarios', ''],
          filas: [
            for (final c in celulas)
              DataRow(cells: [
                DataCell(Text('${c['codigo']} · ${c['nombre']}')),
                DataCell(Pastilla(Colores.nombreProceso(c['proceso']), color: Colores.deProceso(c['proceso']))),
                DataCell(editar
                    ? DropdownButton<String>(
                        value: c['turno_id'] as String?,
                        underline: const SizedBox.shrink(),
                        items: [for (final t in turnos) DropdownMenuItem(value: t['id'] as String, child: Text('${t['nombre']}'))],
                        onChanged: (v) => accion(() => db.from('celulas').update({'turno_id': v}).eq('id', c['id'])))
                    : Text('${c['turnos']?['nombre'] ?? '—'}')),
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 1; i <= 7; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: InkWell(
                        onTap: !editar
                            ? null
                            : () {
                                final l = [for (final x in c['dias_laborales'] as List) x as int];
                                l.contains(i) ? l.remove(i) : l.add(i);
                                l.sort();
                                accion(() => db.from('celulas').update({'dias_laborales': l}).eq('id', c['id']));
                              },
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: (c['dias_laborales'] as List).contains(i) ? Colores.texto : Colors.white,
                            border: Border.all(color: Colores.borde),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(dias[i - 1], style: estilo(11, peso: FontWeight.w600, color: (c['dias_laborales'] as List).contains(i) ? Colors.white : Colores.textoSuave)),
                        ),
                      ),
                    ),
                ])),
                DataCell(editar
                    ? _CampoNumero(valor: c['eficiencia_planeada'] as num, sufijo: '%', onGuardar: (v) => accion(() => db.from('celulas').update({'eficiencia_planeada': v}).eq('id', c['id'])))
                    : Text('${Formato.numero(c['eficiencia_planeada'], decimales: 0)} %')),
                DataCell(Text('${c['operarios_planeados'] ?? empleados.where((e) => e['celula_id'] == c['id']).length}'
                    '${c['operarios_planeados'] == null ? ' (empleados)' : ' (fijo)'}')),
                DataCell(editar
                    ? TextButton(
                        onPressed: () => showDialog(context: context, builder: (_) => _DialogoOperarios(celula: c, celulas: celulas, empleados: empleados, accion: accion)),
                        child: const Text('Operarios'))
                    : const SizedBox.shrink()),
              ]),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Turnos',
        child: Tabla(
          columnas: const ['Turno', 'Inicio', 'Fin', 'Pausas (min)', 'Minutos efectivos'],
          numericas: const {3, 4},
          filas: [
            for (final t in turnos)
              DataRow(cells: [
                DataCell(Text('${t['nombre']}')),
                DataCell(Text('${t['hora_inicio']}'.substring(0, 5))),
                DataCell(Text('${t['hora_fin']}'.substring(0, 5))),
                DataCell(editar
                    ? _CampoNumero(valor: t['minutos_pausa'] as num, onGuardar: (v) => accion(() => db.from('turnos').update({'minutos_pausa': v.round()}).eq('id', t['id'])))
                    : Text('${t['minutos_pausa']}')),
                DataCell(Text(() {
                  int m(String h) => int.parse(h.substring(0, 2)) * 60 + int.parse(h.substring(3, 5));
                  var x = m('${t['hora_fin']}') - m('${t['hora_inicio']}');
                  if (x <= 0) x += 1440;
                  return Formato.numero(x - (t['minutos_pausa'] as num), decimales: 0);
                }())),
              ]),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Festivos',
        accion: editar
            ? OutlinedButton.icon(
                onPressed: () async {
                  final f = await showDatePicker(context: context, firstDate: DateTime.now().subtract(const Duration(days: 30)), lastDate: DateTime.now().add(const Duration(days: 730)));
                  if (f != null) await accion(() => db.from('festivos').insert({'fecha': fechaIso(f), 'nombre': 'Festivo'}), 'Festivo agregado');
                },
                icon: const Icon(Icons.add),
                label: const Text('Agregar'))
            : null,
        child: festivos.isEmpty
            ? Text('Sin festivos registrados.', style: estilo(14, color: Colores.textoSuave))
            : Wrap(spacing: 8, runSpacing: 8, children: [
                for (final f in festivos)
                  InputChip(
                    label: Text('${_corta(f['fecha'])} · ${f['nombre']}'),
                    onDeleted: editar ? () => accion(() => db.from('festivos').delete().eq('fecha', f['fecha'])) : null,
                  ),
              ]),
      ),
    ]);
  }
}

class _CampoNumero extends StatefulWidget {
  const _CampoNumero({required this.valor, required this.onGuardar, this.sufijo});
  final num valor;
  final ValueChanged<double> onGuardar;
  final String? sufijo;
  @override
  State<_CampoNumero> createState() => _CampoNumeroState();
}

class _CampoNumeroState extends State<_CampoNumero> {
  late final _c = TextEditingController(text: Formato.numero(widget.valor, decimales: 0));
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 90,
        child: TextField(
          controller: _c,
          textAlign: TextAlign.right,
          decoration: InputDecoration(isDense: true, suffixText: widget.sufijo),
          onSubmitted: (t) {
            final v = numeroCo(t);
            if (v != null) widget.onGuardar(v);
          },
          onTapOutside: (_) {
            final v = numeroCo(_c.text);
            if (v != null && v != widget.valor) widget.onGuardar(v);
          },
        ),
      );
}

class _DialogoOperarios extends StatelessWidget {
  const _DialogoOperarios({required this.celula, required this.celulas, required this.empleados, required this.accion});
  final Map<String, dynamic> celula;
  final List<Map<String, dynamic>> celulas, empleados;
  final Future<void> Function(Future<void> Function(), [String?]) accion;

  @override
  Widget build(BuildContext context) {
    final de = empleados.where((e) => e['celula_id'] == celula['id']).toList();
    final otros = empleados.where((e) => e['celula_id'] != celula['id']).toList();
    return AlertDialog(
      title: Text('Operarios de ${celula['codigo']}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            for (final e in de)
              ListTile(
                dense: true,
                title: Text('${e['codigo']} · ${e['nombres']} ${e['apellidos']}'),
                trailing: TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await accion(() => db.rpc('asignar_celula', params: {'p_empleado': e['id'], 'p_celula': null}), 'Operario quitado de ${celula['codigo']}');
                  },
                  child: const Text('Quitar')),
              ),
            const Divider(),
            Text('Agregar desde otra célula o sin célula', style: estilo(13, color: Colores.textoSuave)),
            for (final e in otros)
              ListTile(
                dense: true,
                title: Text('${e['codigo']} · ${e['nombres']} ${e['apellidos']}'),
                subtitle: Text(celulas.where((c) => c['id'] == e['celula_id']).firstOrNull?['codigo'] ?? 'Sin célula'),
                trailing: TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await accion(() => db.rpc('asignar_celula', params: {'p_empleado': e['id'], 'p_celula': celula['id']}), 'Operario movido a ${celula['codigo']}');
                  },
                  child: const Text('Agregar')),
              ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
    );
  }
}
