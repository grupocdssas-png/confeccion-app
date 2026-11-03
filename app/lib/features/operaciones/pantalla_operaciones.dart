import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, numeroCo;

final operacionesProvider = FutureProvider.autoDispose((ref) => db
    .from('operaciones')
    .select('*, familias_producto(nombre), tipos_producto(nombre), tipos_maquina(codigo, nombre)')
    .order('codigo', ascending: true));

final catalogoDisenoProvider = FutureProvider((ref) async {
  final r = await Future.wait([
    db.from('familias_producto').select().eq('activo', true).order('nombre', ascending: true),
    db.from('tipos_producto').select().eq('activo', true).order('nombre', ascending: true),
    db.from('tipos_maquina').select().eq('activo', true).order('codigo', ascending: true),
    db.from('procesos').select().order('orden', ascending: true),
  ]);
  return (familias: r[0], tipos: r[1], maquinas: r[2], procesos: r[3]);
});

/// Lista maestra de operaciones (SAM, unidades/hora, valor a destajo, máquina…).
class PantallaOperaciones extends ConsumerStatefulWidget {
  const PantallaOperaciones({super.key});
  @override
  ConsumerState<PantallaOperaciones> createState() => _PantallaOperacionesState();
}

class _PantallaOperacionesState extends ConsumerState<PantallaOperaciones> {
  var _filtro = '';
  String? _familia;

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(operacionesProvider);
    final cat = ref.watch(catalogoDisenoProvider).value;
    final editar = ref.watch(sesionProvider).value?.puedeEditar('operaciones') ?? false;
    Future<void> abrir([Map<String, dynamic>? o]) async {
      if (await showDialog<bool>(context: context, builder: (_) => DialogoOperacion(operacion: o)) == true) ref.invalidate(operacionesProvider);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Lista maestra de operaciones', subtitulo: 'SAM en minutos · unidades por hora = 60 / SAM · cada cambio de SAM o valor queda en el historial',
          acciones: [
            SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Código o nombre', isDense: true),
                onChanged: (v) => setState(() => _filtro = v.toLowerCase()),
              ),
            ),
            if (cat != null)
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Familia', isDense: true),
                  items: [const DropdownMenuItem(value: null, child: Text('Todas')),
                    for (final f in cat.familias) DropdownMenuItem(value: f['id'] as String, child: Text('${f['nombre']}'))],
                  onChanged: (v) => setState(() => _familia = v),
                ),
              ),
            if (editar) ...[
              OutlinedButton.icon(onPressed: () => context.go('/operaciones/importar'), icon: const Icon(Icons.upload_file), label: const Text('Importar de SAMMU')),
              FilledButton.icon(onPressed: abrir, icon: const Icon(Icons.add), label: const Text('Nueva operación')),
            ],
          ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (ops) {
          final lista = ops.where((o) => (_familia == null || o['familia_id'] == _familia) &&
              '${o['codigo']} ${o['nombre']}'.toLowerCase().contains(_filtro)).toList();
          return Tarjeta(
            padding: EdgeInsets.zero,
            child: Tabla(
              columnas: const ['Código', 'Operación', 'Familia / tipo', 'Proceso', 'SAM', 'Und/h', 'Valor', 'Máquina', 'Parte', 'Rep.', '', ''],
              numericas: const {4, 5, 6, 9},
              vacio: 'No hay operaciones. Créelas o impórtelas desde SAMMU.',
              filas: [
                for (final o in lista)
                  DataRow(cells: [
                    DataCell(Text('${o['codigo']}', style: estiloCodigo(13))),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${o['nombre']}', style: TextStyle(color: o['activo'] == true ? null : Colores.textoSuave)),
                      if (o['restrictiva'] == true) const Padding(padding: EdgeInsets.only(left: 6), child: Pastilla('Restrictiva', color: Colores.ambar)),
                      if (o['agrega_minutos_sam'] == false) const Padding(padding: EdgeInsets.only(left: 6), child: Pastilla('No suma SAM', color: Colores.textoSuave)),
                    ])),
                    DataCell(Text([o['familias_producto']?['nombre'], o['tipos_producto']?['nombre']].whereType<String>().join(' · '), style: estilo(12.5))),
                    DataCell(Pastilla(Colores.nombreProceso(o['proceso']), color: Colores.deProceso(o['proceso']))),
                    DataCell(Text(Formato.numero(o['sam'], decimales: 3), style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text(Formato.numero(o['unidades_hora'], decimales: 1))),
                    DataCell(Text(Formato.cop(o['valor_destajo']))),
                    DataCell(Text('${o['tipos_maquina']?['codigo'] ?? '—'}', style: estiloCodigo(12.5, peso: FontWeight.w400))),
                    DataCell(Text('${o['parte'] ?? '—'}')),
                    DataCell(Text(Formato.numero(o['repeticiones'], decimales: (o['repeticiones'] as num) % 1 == 0 ? 0 : 2))),
                    DataCell(IconButton(tooltip: 'Historial de SAM', icon: const Icon(Icons.history, size: 20),
                        onPressed: () => showDialog(context: context, builder: (_) => _DialogoHistorial(o)))),
                    DataCell(editar ? TextButton(onPressed: () => abrir(o), child: const Text('Editar')) : const SizedBox()),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}

class _DialogoHistorial extends StatelessWidget {
  const _DialogoHistorial(this.o);
  final Map<String, dynamic> o;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Historial de ${o['codigo']}'),
        content: SizedBox(
          width: 620,
          child: FutureBuilder(
            future: db.from('operaciones_historial').select('*, perfiles:usuario_id(nombre)').eq('operacion_id', o['id']).order('fecha', ascending: false),
            builder: (_, s) => !s.hasData
                ? const LinearProgressIndicator()
                : Tabla(
                    columnas: const ['Fecha', 'SAM', 'Valor', 'Origen', 'Usuario'],
                    filas: [
                      for (final h in s.data!)
                        DataRow(cells: [
                          DataCell(Text(Formato.fechaHora(DateTime.parse(h['fecha'])))),
                          DataCell(Text(h['sam_anterior'] == null ? Formato.numero(h['sam_nuevo'], decimales: 3)
                              : '${Formato.numero(h['sam_anterior'], decimales: 3)} → ${Formato.numero(h['sam_nuevo'], decimales: 3)}')),
                          DataCell(Text(h['valor_anterior'] == null ? Formato.cop(h['valor_nuevo'])
                              : '${Formato.cop(h['valor_anterior'])} → ${Formato.cop(h['valor_nuevo'])}')),
                          DataCell(Text(const {'creacion': 'Creación', 'manual': 'Manual', 'importacion': 'Importación', 'estudio': 'Estudio de tiempos'}[h['origen']] ?? '${h['origen']}')),
                          DataCell(Text('${h['perfiles']?['nombre'] ?? 'Sistema'}')),
                        ]),
                    ],
                  ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
      );
}

class DialogoOperacion extends ConsumerStatefulWidget {
  const DialogoOperacion({super.key, this.operacion});
  final Map<String, dynamic>? operacion;
  @override
  ConsumerState<DialogoOperacion> createState() => _DialogoOperacionState();
}

class _DialogoOperacionState extends ConsumerState<DialogoOperacion> {
  late final o = widget.operacion;
  late final _c = {
    for (final k in ['codigo', 'nombre', 'sam', 'valor_destajo', 'parte', 'repeticiones'])
      k: TextEditingController(text: o?[k] == null ? (k == 'repeticiones' ? '1' : '') : '${o![k]}'.replaceAll('.', ',')),
  };
  late String? _familia = o?['familia_id'], _tipo = o?['tipo_producto_id'], _maquina = o?['tipo_maquina_id'];
  late String _proceso = o?['proceso'] ?? 'confeccion', _tipoOp = o?['tipo'] ?? 'normal';
  late bool _restrictiva = o?['restrictiva'] ?? false, _suma = o?['agrega_minutos_sam'] ?? true, _activo = o?['activo'] ?? true;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogoDisenoProvider).value;
    final sam = numeroCo(_c['sam']!.text);
    Widget t(String k, String et, double w) => SizedBox(width: w, child: TextField(controller: _c[k], onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: et, isDense: true)));
    Widget dd(String et, String? v, List<Map<String, dynamic>> items, String Function(Map<String, dynamic>) txt, void Function(String?) cb, double w) =>
        SizedBox(width: w, child: DropdownButtonFormField<String?>(
          initialValue: v, isExpanded: true, decoration: InputDecoration(labelText: et, isDense: true),
          items: [const DropdownMenuItem(value: null, child: Text('—')), for (final i in items) DropdownMenuItem(value: i['id'] as String, child: Text(txt(i), overflow: TextOverflow.ellipsis))],
          onChanged: (x) => setState(() => cb(x))));
    return AlertDialog(
      title: Text(o == null ? 'Nueva operación' : 'Editar ${o!['codigo']}'),
      content: SizedBox(
        width: 680,
        child: cat == null ? const LinearProgressIndicator() : SingleChildScrollView(
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            t('codigo', 'Código', 140),
            t('nombre', 'Nombre', 480),
            dd('Familia', _familia, cat.familias, (i) => '${i['nombre']}', (x) { _familia = x; _tipo = null; }, 230),
            dd('Tipo de producto', _tipo, cat.tipos.where((x) => x['familia_id'] == _familia).toList(), (i) => '${i['nombre']}', (x) => _tipo = x, 230),
            SizedBox(width: 180, child: DropdownButtonFormField<String>(initialValue: _proceso, decoration: const InputDecoration(labelText: 'Proceso', isDense: true),
                items: [for (final p in cat.procesos) DropdownMenuItem(value: p['codigo'] as String, child: Text('${p['nombre']}'))], onChanged: (x) => _proceso = x!)),
            t('sam', 'SAM (minutos)', 130),
            SizedBox(width: 140, child: InputDecorator(decoration: const InputDecoration(labelText: 'Unidades / hora', isDense: true),
                child: Text(sam == null || sam <= 0 ? '—' : Formato.numero(60 / sam, decimales: 1)))),
            t('valor_destajo', 'Valor a destajo (COP)', 170),
            dd('Máquina', _maquina, cat.maquinas, (i) => '${i['codigo']} · ${i['nombre']}', (x) => _maquina = x, 230),
            t('parte', 'Parte', 150),
            t('repeticiones', 'Repeticiones por unidad', 180),
            SizedBox(width: 170, child: DropdownButtonFormField<String>(initialValue: _tipoOp, decoration: const InputDecoration(labelText: 'Tipo', isDense: true),
                items: const [DropdownMenuItem(value: 'normal', child: Text('Normal')), DropdownMenuItem(value: 'reproceso', child: Text('Reproceso')),
                  DropdownMenuItem(value: 'manual', child: Text('Manual')), DropdownMenuItem(value: 'inspeccion', child: Text('Inspección')),
                  DropdownMenuItem(value: 'empaque', child: Text('Empaque'))], onChanged: (x) => _tipoOp = x!)),
            _check('Operación restrictiva', _restrictiva, (v) => _restrictiva = v),
            _check('Agrega minutos al SAM', _suma, (v) => _suma = v),
            _check('Activa', _activo, (v) => _activo = v),
            if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _guardar, child: const Text('Guardar')),
      ],
    );
  }

  Widget _check(String t, bool v, void Function(bool) cb) => Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: v, onChanged: (x) => setState(() => cb(x!))),
        Text(t),
      ]);

  Future<void> _guardar() async {
    final d = {
      'codigo': _c['codigo']!.text.trim().toUpperCase(), 'nombre': _c['nombre']!.text.trim(),
      'familia_id': _familia, 'tipo_producto_id': _tipo, 'proceso': _proceso, 'sam': numeroCo(_c['sam']!.text),
      'valor_destajo': numeroCo(_c['valor_destajo']!.text) ?? 0, 'tipo_maquina_id': _maquina,
      'parte': _c['parte']!.text.trim().isEmpty ? null : _c['parte']!.text.trim(),
      'repeticiones': numeroCo(_c['repeticiones']!.text) ?? 1, 'tipo': _tipoOp,
      'restrictiva': _restrictiva, 'agrega_minutos_sam': _suma, 'activo': _activo,
    };
    if (d['sam'] == null || (d['sam'] as double) <= 0) return setState(() => _error = 'El SAM debe ser mayor que cero');
    try {
      o == null ? await db.from('operaciones').insert(d) : await db.from('operaciones').update(d).eq('id', o!['id']);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = mensajeError(e));
    }
  }
}
