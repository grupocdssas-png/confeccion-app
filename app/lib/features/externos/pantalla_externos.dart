import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, muestraColor, numeroCo, pedirTexto;
import 'datos_externos.dart';

final _remisionesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, filtro) {
  var q = db.from('remisiones').select('*, satelites(nombre), procesos(nombre), remision_unidades(cantidad, buenas)').eq('tipo', 'salida');
  if (filtro == 'abiertas') q = q.inFilter('estado', ['enviada', 'parcial']);
  return q.order('creado_en', ascending: false).limit(300);
});

final _cuentasProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, filtro) {
  var q = db.from('cuentas_pagar_satelite').select('*, satelites(nombre), ordenes_produccion(consecutivo), remisiones(consecutivo)');
  if (filtro != 'todas') q = q.eq('estado', filtro);
  return q.order('creado_en', ascending: false).limit(300);
});

final _tarifasProvider = FutureProvider.autoDispose((ref) =>
    db.from('tarifas_satelite').select('*, satelites(nombre), referencias(codigo, nombre)').order('vigente_desde', ascending: false));

bool _esSatelite(WidgetRef ref) => ref.watch(sesionProvider).value?.roles.contains('satelite') ?? false;
bool _apruebaCostos(WidgetRef ref) => ref.watch(sesionProvider).value?.permisos.any((p) => p.modulo == 'costos' && p.aprobar) ?? false;

/// Procesos externos y satélites: remisiones de salida y devolución, cuentas por pagar y tarifas.
/// El usuario de un satélite ve aquí solo lo suyo.
class PantallaExternos extends ConsumerStatefulWidget {
  const PantallaExternos({super.key});
  @override
  ConsumerState<PantallaExternos> createState() => _PantallaExternosState();
}

class _PantallaExternosState extends ConsumerState<PantallaExternos> {
  var _pestana = 'remisiones';
  var _filtro = 'abiertas';
  var _filtroCuentas = 'pendiente';

  @override
  Widget build(BuildContext context) {
    final sesion = ref.watch(sesionProvider).value;
    final editar = sesion?.puedeEditar('procesos_externos') ?? false;
    final satelite = _esSatelite(ref);
    final verCostos = satelite || (sesion?.puedeVer('costos') ?? false) || editar;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina(satelite ? 'Mis remisiones' : 'Procesos externos y satélites',
          subtitulo: satelite
              ? 'Lo que le enviamos, lo que ya devolvió y sus cuentas'
              : 'Remisión de salida → el satélite trabaja → devolución con buenas, segundas y faltantes → cuenta por pagar',
          acciones: [
            if (editar)
              FilledButton.icon(
                onPressed: () async {
                  final id = await showDialog<String>(context: context, builder: (_) => const DialogoNuevaRemision());
                  if (id != null && context.mounted) context.go('/externos/$id');
                },
                icon: const Icon(Icons.local_shipping_outlined),
                label: const Text('Nueva remisión'),
              ),
          ]),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Wrap(spacing: 8, children: [
          for (final (k, t) in [('remisiones', 'Remisiones'), if (verCostos) ('cuentas', 'Cuentas por pagar'), if (!satelite) ('tarifas', 'Tarifas')])
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
      switch (_pestana) {
        'cuentas' => _cuentas(),
        'tarifas' => _tarifas(),
        _ => _remisiones(),
      },
    ]);
  }

  Widget _remisiones() {
    final datos = ref.watch(_remisionesProvider(_filtro));
    return Tarjeta(
      titulo: 'Remisiones de salida',
      accion: SegmentedButton<String>(
        segments: const [ButtonSegment(value: 'abiertas', label: Text('En satélites')), ButtonSegment(value: 'todas', label: Text('Todas'))],
        selected: {_filtro},
        onSelectionChanged: (s) => setState(() => _filtro = s.first),
      ),
      child: datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) => Tabla(
          columnas: const ['Remisión', 'Satélite', 'Proceso', 'Fecha', 'Devolver', 'Prendas', 'Devueltas', 'Estado', 'Recibido', ''],
          numericas: const {5, 6},
          vacio: 'No hay remisiones.',
          filas: [
            for (final r in l)
              () {
                final us = (r['remision_unidades'] as List).cast<Map<String, dynamic>>();
                final enviadas = us.fold<int>(0, (a, u) => a + (u['cantidad'] as int));
                final devueltas = us.where((u) => u['buenas'] != null).fold<int>(0, (a, u) => a + (u['cantidad'] as int));
                final vence = r['fecha_compromiso'] != null && ['enviada', 'parcial'].contains(r['estado']) &&
                    DateTime.parse('${r['fecha_compromiso']}T23:59:59-05:00').isBefore(DateTime.now());
                return DataRow(cells: [
                  DataCell(Text('${r['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text('${r['satelites']?['nombre'] ?? ''}')),
                  DataCell(Pastilla('${r['procesos']?['nombre'] ?? r['proceso']}', color: Colores.deProceso(r['proceso']))),
                  DataCell(Text(Formato.fecha(DateTime.parse('${r['fecha']}T12:00:00Z')))),
                  DataCell(Text(r['fecha_compromiso'] == null ? '—' : Formato.fecha(DateTime.parse('${r['fecha_compromiso']}T12:00:00Z')),
                      style: TextStyle(color: vence ? Colores.rojo : null, fontWeight: vence ? FontWeight.w700 : null))),
                  DataCell(Text('$enviadas')),
                  DataCell(Text('$devueltas')),
                  DataCell(_pastilla('${r['estado']}')),
                  DataCell(r['recibida_satelite'] == null ? const Text('—') : const Icon(Icons.check_circle, color: Colores.verde, size: 18)),
                  DataCell(TextButton(onPressed: () => context.go('/externos/${r['id']}'), child: const Text('Abrir'))),
                ]);
              }(),
          ],
        ),
      ),
    );
  }

  Widget _cuentas() {
    final datos = ref.watch(_cuentasProvider(_filtroCuentas));
    final aprueba = _apruebaCostos(ref);
    Future<void> decidir(Map<String, dynamic> c, String accion, [String? dato]) async {
      try {
        await db.rpc('decidir_cuenta_satelite', params: {'p_id': c['id'], 'p_accion': accion, 'p_dato': dato});
        ref.invalidate(_cuentasProvider);
      } catch (e) {
        if (mounted) avisar(context, mensajeError(e), error: true);
      }
    }

    return Tarjeta(
      titulo: 'Cuentas por pagar a satélites',
      accion: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'pendiente', label: Text('Pendientes')),
          ButtonSegment(value: 'aprobada', label: Text('Aprobadas')),
          ButtonSegment(value: 'pagada', label: Text('Pagadas')),
          ButtonSegment(value: 'todas', label: Text('Todas')),
        ],
        selected: {_filtroCuentas},
        onSelectionChanged: (s) => setState(() => _filtroCuentas = s.first),
      ),
      child: datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) {
          final total = l.fold<num>(0, (a, c) => a + ((c['valor'] ?? 0) as num));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tabla(
              columnas: const ['Cuenta', 'Satélite', 'OP', 'Devolución', 'Prendas', 'Por prenda', 'Valor', 'Estado', ''],
              numericas: const {4, 5, 6},
              vacio: 'Sin cuentas.',
              filas: [
                for (final c in l)
                  DataRow(cells: [
                    DataCell(Text('${c['consecutivo']}', style: estiloCodigo(13))),
                    DataCell(Text('${c['satelites']?['nombre'] ?? ''}')),
                    DataCell(Text('${c['ordenes_produccion']?['consecutivo'] ?? ''}')),
                    DataCell(Text('${c['remisiones']?['consecutivo'] ?? ''}')),
                    DataCell(Text('${c['cantidad']}')),
                    DataCell(Text(c['valor_unidad'] == null ? 'Sin tarifa' : Formato.cop(c['valor_unidad']),
                        style: TextStyle(color: c['valor_unidad'] == null ? Colores.rojo : null))),
                    DataCell(Text(c['valor'] == null ? '—' : Formato.cop(c['valor']), style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(_pastilla('${c['estado']}')),
                    DataCell(!aprueba
                        ? const SizedBox.shrink()
                        : Row(mainAxisSize: MainAxisSize.min, children: [
                            if (c['estado'] == 'pendiente') ...[
                              TextButton(
                                onPressed: () async {
                                  final v = await pedirTexto(context, titulo: 'Valor por prenda', etiqueta: 'COP por prenda');
                                  final n = v == null ? null : numeroCo(v);
                                  if (n != null) await decidir(c, 'valor', '$n');
                                },
                                child: const Text('Corregir valor')),
                              FilledButton.tonal(onPressed: () => decidir(c, 'aprobar'), child: const Text('Aprobar')),
                            ],
                            if (c['estado'] == 'aprobada')
                              FilledButton.tonal(
                                onPressed: () async {
                                  final ref0 = await pedirTexto(context, titulo: 'Registrar pago', etiqueta: 'Referencia del pago (transferencia, comprobante)');
                                  if (ref0 != null) await decidir(c, 'pagar', ref0);
                                },
                                child: const Text('Marcar pagada')),
                          ])),
                  ]),
              ],
            ),
            if (l.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('Total: ${Formato.cop(total)}', textAlign: TextAlign.right, style: estilo(15, peso: FontWeight.w700)),
              ),
            const SizedBox(height: 6),
            Text('Se paga por prenda buena devuelta. La exportación a Alegra llega con las integraciones.', style: estilo(12.5, color: Colores.textoSuave)),
          ]);
        },
      ),
    );
  }

  Widget _tarifas() {
    final datos = ref.watch(_tarifasProvider);
    final editar = ref.watch(sesionProvider).value?.puedeEditar('costos') ?? false;
    return Tarjeta(
      titulo: 'Tarifas por satélite (precio por prenda)',
      accion: editar
          ? FilledButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(context: context, builder: (_) => const _DialogoTarifa());
                if (ok == true) ref.invalidate(_tarifasProvider);
              },
              icon: const Icon(Icons.add),
              label: const Text('Nueva tarifa'))
          : null,
      child: datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Tabla(
            columnas: const ['Satélite', 'Proceso', 'Referencia', 'Por prenda', 'Desde', 'Observación'],
            numericas: const {3},
            vacio: 'Sin tarifas: las cuentas quedarán sin valor hasta registrarlas.',
            filas: [
              for (final t in l)
                DataRow(cells: [
                  DataCell(Text('${t['satelites']?['nombre'] ?? ''}')),
                  DataCell(Pastilla(Colores.nombreProceso(t['proceso']), color: Colores.deProceso(t['proceso']))),
                  DataCell(Text(t['referencias'] == null ? 'Todas' : '${t['referencias']['codigo']}')),
                  DataCell(Text(Formato.cop(t['valor_unidad']), style: const TextStyle(fontWeight: FontWeight.w600))),
                  DataCell(Text(Formato.fecha(DateTime.parse('${t['vigente_desde']}T12:00:00Z')))),
                  DataCell(Text('${t['observacion'] ?? ''}')),
                ]),
            ],
          ),
          const SizedBox(height: 6),
          Text('Una tarifa nueva no cambia las anteriores: cada devolución usa la vigente en su fecha. La de una referencia gana sobre la general.',
              style: estilo(12.5, color: Colores.textoSuave)),
        ]),
      ),
    );
  }
}

Pastilla _pastilla(String e) => switch (e) {
      'enviada' => Pastilla(nombreEstadoRemision(e), color: Colores.deProceso('estampacion')),
      'parcial' => Pastilla(nombreEstadoRemision(e), color: Colores.ambar),
      'cerrada' || 'pagada' => Pastilla(e == 'pagada' ? 'Pagada' : nombreEstadoRemision(e), color: Colores.verde),
      'anulada' => const Pastilla('Anulada', color: Colores.rojo),
      'pendiente' => const Pastilla('Pendiente', color: Colores.ambar),
      'aprobada' => Pastilla('Aprobada', color: Colores.deProceso('corte')),
      _ => Pastilla(e, color: Colores.textoSuave),
    };

// ---------------------------------------------------------------------------
// Nueva remisión de salida
// ---------------------------------------------------------------------------
class DialogoNuevaRemision extends ConsumerStatefulWidget {
  const DialogoNuevaRemision({super.key});
  @override
  ConsumerState<DialogoNuevaRemision> createState() => _DialogoNuevaRemisionState();
}

class _DialogoNuevaRemisionState extends ConsumerState<DialogoNuevaRemision> {
  String? _satelite, _proceso;
  DateTime? _compromiso;
  final _obs = TextEditingController();
  final _sel = <String>{};
  List<Map<String, dynamic>> _esperando = [];
  var _cargando = false;
  String? _error;

  Future<void> _cargar() async {
    if (_proceso == null) return;
    setState(() => _cargando = true);
    final u = await db.from('unidades_trabajo').select()
        .eq('proceso_actual', _proceso!).inFilter('estado', ['cortado', 'armado', 'en_espera']).order('codigo', ascending: true);
    final ops = u.isEmpty ? <Map<String, dynamic>>[]
        : await db.from('ordenes_produccion').select('id, consecutivo, referencias(codigo, nombre)').inFilter('id', {for (final x in u) x['op_id']}.toList());
    final porId = {for (final o in ops) o['id']: o};
    final l = [for (final x in u) {...x, 'ordenes_produccion': porId[x['op_id']]}];
    if (mounted) {
      setState(() {
        _esperando = l;
        _sel.clear();
        _cargando = false;
      });
    }
  }

  Future<void> _crear() async {
    try {
      final id = await db.rpc('crear_remision_salida', params: {
        'p_satelite': _satelite, 'p_proceso': _proceso, 'p_unidades': _sel.toList(), 'p_insumos': [],
        'p_observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(),
        'p_fecha_compromiso': _compromiso == null ? null : '${_compromiso!.year}-${_compromiso!.month.toString().padLeft(2, '0')}-${_compromiso!.day.toString().padLeft(2, '0')}',
      });
      if (mounted) Navigator.pop(context, '$id');
    } catch (e) {
      setState(() => _error = mensajeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogoExternosProvider).value;
    final sat = cat?.satelites.where((s) => s['id'] == _satelite).firstOrNull;
    final procesos = [for (final p in (sat?['procesos'] as List? ?? const [])) '$p'];
    final prendas = _esperando.where((u) => _sel.contains(u['id'])).fold<int>(0, (a, u) => a + ((u['cantidad_actual'] ?? 0) as num).toInt());
    return AlertDialog(
      title: const Text('Nueva remisión de salida'),
      content: SizedBox(
        width: 760,
        child: cat == null
            ? const LinearProgressIndicator()
            : SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    SizedBox(
                      width: 300,
                      child: DropdownButtonFormField<String>(
                        initialValue: _satelite,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Satélite', isDense: true),
                        items: [for (final s in cat.satelites.where((s) => s['activo'] == true)) DropdownMenuItem(value: s['id'] as String, child: Text('${s['nombre']}'))],
                        onChanged: (v) {
                          setState(() {
                            _satelite = v;
                            final ps = [for (final p in (cat.satelites.firstWhere((s) => s['id'] == v)['procesos'] as List)) '$p'];
                            _proceso = ps.length == 1 ? ps.first : null;
                          });
                          _cargar();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('$_satelite$_proceso'),
                        initialValue: _proceso,
                        decoration: const InputDecoration(labelText: 'Proceso', isDense: true),
                        items: [for (final p in procesos) DropdownMenuItem(value: p, child: Text(cat.proceso(p)))],
                        onChanged: (v) {
                          setState(() => _proceso = v);
                          _cargar();
                        },
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final f = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 120)),
                            initialDate: _compromiso ?? DateTime.now().add(const Duration(days: 3)));
                        if (f != null) setState(() => _compromiso = f);
                      },
                      icon: const Icon(Icons.event),
                      label: Text(_compromiso == null ? 'Fecha de devolución' : 'Devolver: ${Formato.fecha(_compromiso!)}'),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  if (_proceso == null)
                    Text('Elija el satélite y el proceso para ver lo que está esperando.', style: estilo(14, color: Colores.textoSuave))
                  else if (_cargando)
                    const LinearProgressIndicator()
                  else if (_esperando.isEmpty)
                    Text('No hay juegos ni paquetes esperando ${cat.proceso(_proceso)}.', style: estilo(14, color: Colores.textoSuave))
                  else ...[
                    Row(children: [
                      Text('Esperando ${cat.proceso(_proceso)} (${_esperando.length})', style: estilo(14, peso: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _sel.length == _esperando.length ? _sel.clear() : _sel.addAll(_esperando.map((u) => u['id'] as String))),
                        child: Text(_sel.length == _esperando.length ? 'Quitar todos' : 'Elegir todos')),
                    ]),
                    for (final u in _esperando)
                      CheckboxListTile(
                        dense: true,
                        value: _sel.contains(u['id']),
                        onChanged: (v) => setState(() => v! ? _sel.add(u['id']) : _sel.remove(u['id'])),
                        secondary: muestraColor(cat.hex(u['color_id'])),
                        title: Text('${u['codigo']} · ${u['ordenes_produccion']?['consecutivo'] ?? ''} ${u['ordenes_produccion']?['referencias']?['codigo'] ?? ''}',
                            style: estiloCodigo(13.5)),
                        subtitle: Text('${cat.color(u['color_id'])} · talla ${cat.talla(u['talla_id'])} · ${u['cantidad_actual']} prendas'),
                      ),
                  ],
                  const SizedBox(height: 10),
                  TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación (opcional)', isDense: true)),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: estilo(13.5, color: Colores.rojo))),
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _sel.isEmpty ? null : _crear,
          child: Text(_sel.isEmpty ? 'Crear remisión' : 'Enviar ${_sel.length} (${Formato.numero(prendas, decimales: 0)} prendas)'),
        ),
      ],
    );
  }
}

class _DialogoTarifa extends ConsumerStatefulWidget {
  const _DialogoTarifa();
  @override
  ConsumerState<_DialogoTarifa> createState() => _DialogoTarifaState();
}

class _DialogoTarifaState extends ConsumerState<_DialogoTarifa> {
  String? _satelite, _proceso, _referencia;
  final _valor = TextEditingController();
  final _obs = TextEditingController();
  String? _error;
  List<Map<String, dynamic>> _refs = [];

  @override
  void initState() {
    super.initState();
    db.from('referencias').select('id, codigo, nombre').order('codigo', ascending: true).then((l) {
      if (mounted) setState(() => _refs = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogoExternosProvider).value;
    final sat = cat?.satelites.where((s) => s['id'] == _satelite).firstOrNull;
    return AlertDialog(
      title: const Text('Nueva tarifa'),
      content: SizedBox(
        width: 460,
        child: cat == null
            ? const LinearProgressIndicator()
            : Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  initialValue: _satelite,
                  decoration: const InputDecoration(labelText: 'Satélite'),
                  items: [for (final s in cat.satelites) DropdownMenuItem(value: s['id'] as String, child: Text('${s['nombre']}'))],
                  onChanged: (v) => setState(() {
                    _satelite = v;
                    _proceso = null;
                  }),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: ValueKey(_satelite),
                  initialValue: _proceso,
                  decoration: const InputDecoration(labelText: 'Proceso'),
                  items: [for (final p in (sat?['procesos'] as List? ?? const [])) DropdownMenuItem(value: '$p', child: Text(cat.proceso('$p')))],
                  onChanged: (v) => setState(() => _proceso = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: _referencia,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Referencia'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Todas las referencias')),
                    for (final r in _refs) DropdownMenuItem(value: r['id'] as String, child: Text('${r['codigo']} · ${r['nombre']}', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _referencia = v),
                ),
                const SizedBox(height: 10),
                TextField(controller: _valor, decoration: const InputDecoration(labelText: 'Valor por prenda (COP)')),
                const SizedBox(height: 10),
                TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación')),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: estilo(13.5, color: Colores.rojo))),
              ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () async {
            final v = numeroCo(_valor.text);
            if (_satelite == null || _proceso == null || v == null) {
              setState(() => _error = 'Complete satélite, proceso y valor');
              return;
            }
            try {
              await db.from('tarifas_satelite').insert({
                'satelite_id': _satelite, 'proceso': _proceso, 'referencia_id': _referencia, 'valor_unidad': v,
                'observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(),
              });
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              setState(() => _error = mensajeError(e));
            }
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
