import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, avisar;
import 'comun_produccion.dart';

final _pedidosProvider = FutureProvider.autoDispose((ref) async {
  final p = await db.from('pedidos').select('*, clientes(nombre), canales(nombre)').order('creado_en', ascending: false).limit(300);
  final s = await db.from('pedido_saldos').select('pedido_id, cantidad, en_op, pendiente');
  final tot = <String, (int, int, int)>{};
  for (final x in s) {
    final t = tot[x['pedido_id']] ?? (0, 0, 0);
    tot[x['pedido_id']] = (t.$1 + (x['cantidad'] as int), t.$2 + (x['en_op'] as int), t.$3 + (x['pendiente'] as int));
  }
  return [for (final x in p) {...x, 'tot': tot[x['id']] ?? (0, 0, 0)}];
});

class PantallaPedidos extends ConsumerWidget {
  const PantallaPedidos({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_pedidosProvider);
    final editar = ref.watch(sesionProvider).value?.puedeEditar('pedidos') ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Pedidos', subtitulo: 'Pedidos de clientes por referencia, color y talla; se convierten en órdenes de producción', acciones: [
        if (editar)
          FilledButton.icon(
            onPressed: () async {
              final id = await showDialog<String>(context: context, builder: (_) => const _DialogoPedido());
              if (id != null && context.mounted) context.go('/pedidos/$id');
            },
            icon: const Icon(Icons.add), label: const Text('Nuevo pedido')),
      ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) => Tarjeta(
          padding: EdgeInsets.zero,
          child: Tabla(
            columnas: const ['Pedido', 'Cliente', 'Canal', 'Fecha', 'Comprometida', 'Prendas', 'En OP', 'Pendiente', 'Estado', ''],
            numericas: const {5, 6, 7},
            vacio: 'No hay pedidos.',
            filas: [
              for (final p in l)
                DataRow(cells: [
                  DataCell(Text('${p['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text('${p['clientes']?['nombre'] ?? '—'}')),
                  DataCell(Text('${p['canales']?['nombre'] ?? '—'}')),
                  DataCell(Text(Formato.fecha(DateTime.parse('${p['fecha']}T12:00:00Z')))),
                  DataCell(diasRestantes(p['fecha_comprometida'], estado: (p['tot'] as (int, int, int)).$3 == 0 ? 'terminada' : 'planeada')),
                  DataCell(Text(Formato.numero((p['tot'] as (int, int, int)).$1, decimales: 0))),
                  DataCell(Text(Formato.numero((p['tot'] as (int, int, int)).$2, decimales: 0))),
                  DataCell(Text(Formato.numero((p['tot'] as (int, int, int)).$3, decimales: 0),
                      style: TextStyle(fontWeight: FontWeight.w600, color: (p['tot'] as (int, int, int)).$3 > 0 ? Colores.ambar : Colores.verde))),
                  DataCell(p['estado'] == 'cancelado' ? const Pastilla('Cancelado', color: Colores.rojo)
                      : (p['tot'] as (int, int, int)).$3 == 0 && (p['tot'] as (int, int, int)).$1 > 0 ? const Pastilla('En producción', color: Colores.verde)
                      : (p['tot'] as (int, int, int)).$2 > 0 ? const Pastilla('Parcial en OP', color: Colores.ambar) : Pastilla('Abierto', color: Colores.deProceso('corte'))),
                  DataCell(TextButton(onPressed: () => context.go('/pedidos/${p['id']}'), child: const Text('Abrir'))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _DialogoPedido extends ConsumerStatefulWidget {
  const _DialogoPedido();
  @override
  ConsumerState<_DialogoPedido> createState() => _DialogoPedidoState();
}

class _DialogoPedidoState extends ConsumerState<_DialogoPedido> {
  String? _cliente, _canal, _comprometida;
  final _obs = TextEditingController();
  String? _error;

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(clientesProvider).value;
    return AlertDialog(
      title: const Text('Nuevo pedido'),
      content: SizedBox(
        width: 460,
        child: c == null ? const LinearProgressIndicator() : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            isExpanded: true, decoration: const InputDecoration(labelText: 'Cliente'),
            items: [for (final x in c.clientes) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() {
              _cliente = v;
              _canal = c.clientes.firstWhere((x) => x['id'] == v)['canal_id'];
            }),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey(_canal), initialValue: _canal, decoration: const InputDecoration(labelText: 'Canal'),
            items: [for (final x in c.canales) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
            onChanged: (v) => _canal = v,
          ),
          const SizedBox(height: 10),
          CampoFecha(etiqueta: 'Fecha comprometida', valor: _comprometida, ancho: 460, onCambio: (v) => setState(() => _comprometida = v)),
          const SizedBox(height: 10),
          TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: estilo(13, color: Colores.rojo))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () async {
            try {
              final p = await db.from('pedidos').insert({
                'cliente_id': _cliente, 'canal_id': _canal, 'fecha_comprometida': _comprometida,
                'observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(),
              }).select('id').single();
              if (context.mounted) Navigator.pop(context, p['id'] as String);
            } catch (e) {
              setState(() => _error = mensajeError(e));
            }
          },
          child: const Text('Crear y agregar referencias'),
        ),
      ],
    );
  }
}

// =====================================================================
// Detalle del pedido
// =====================================================================
class PantallaPedido extends ConsumerStatefulWidget {
  const PantallaPedido({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PantallaPedido> createState() => _PantallaPedidoState();
}

class _PantallaPedidoState extends ConsumerState<PantallaPedido> {
  late Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<Map<String, dynamic>>)> _datos = _cargar();

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>, List<Map<String, dynamic>>)> _cargar() async {
    final p = await db.from('pedidos').select('*, clientes(nombre), canales(nombre)').eq('id', widget.id).single();
    final s = await db.from('pedido_saldos').select('*, referencias(codigo, nombre), tallas(codigo, orden)').eq('pedido_id', widget.id);
    final ops = await db.from('op_pedidos').select('cantidad, pedido_linea_id, ordenes_produccion(id, consecutivo, estado)')
        .inFilter('pedido_linea_id', [for (final x in s) x['pedido_linea_id']]);
    return (p, s, ops);
  }

  void _recargar() => setState(() => _datos = _cargar());

  @override
  Widget build(BuildContext context) {
    final editarPedido = ref.watch(sesionProvider).value?.puedeEditar('pedidos') ?? false;
    final crearOp = ref.watch(sesionProvider).value?.puedeEditar('op') ?? false;
    final refs = ref.watch(referenciasProduciblesProvider).value ?? const [];
    return FutureBuilder(
      future: _datos,
      builder: (context, s) {
        if (s.hasError) return Text(mensajeError(s.error!));
        if (!s.hasData) return const LinearProgressIndicator();
        final (p, lineas, ops) = s.data!;
        final porRef = <String, List<Map<String, dynamic>>>{};
        for (final l in lineas) {
          porRef.putIfAbsent(l['referencia_id'], () => []).add(l);
        }
        final opsUnicas = {for (final o in ops) o['ordenes_produccion']['id']: o['ordenes_produccion']}.values.toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('Pedido ${p['consecutivo']}',
              subtitulo: '${p['clientes']?['nombre'] ?? 'Sin cliente'} · ${p['canales']?['nombre'] ?? ''}'
                  '${p['fecha_comprometida'] != null ? ' · comprometido para el ${Formato.fecha(DateTime.parse('${p['fecha_comprometida']}T12:00:00Z'))}' : ''}',
              acciones: [
                OutlinedButton(onPressed: () => context.go('/pedidos'), child: const Text('Volver')),
                if (editarPedido)
                  FilledButton.icon(
                    onPressed: () async {
                      if (await showDialog<bool>(context: context, builder: (_) => _DialogoLineas(pedidoId: widget.id)) == true) _recargar();
                    },
                    icon: const Icon(Icons.add), label: const Text('Agregar referencia')),
              ]),
          if (porRef.isEmpty) Tarjeta(child: Text('Agregue las referencias, colores y tallas del pedido.', style: estilo(14, color: Colores.textoSuave))),
          for (final e in porRef.entries) ...[
            () {
              final r = refs.where((x) => x['id'] == e.key).firstOrNull;
              final orden = r == null ? const <String>[] : combinacionesDe(r);
              final combs = {for (final l in e.value) l['combinacion_codigo'] as String}.toList()
                ..sort((a, b) => (orden.contains(a) ? orden.indexOf(a) : 99).compareTo(orden.contains(b) ? orden.indexOf(b) : 99));
              final nombres = r == null ? const <String, String>{} : nombresCombinacion(r);
              final tallas = (e.value.map((l) => l['tallas']).toSet().toList()..sort((a, b) => (a['orden'] as int).compareTo(b['orden'] as int)))
                  .map((t) => t['codigo'] as String).toSet().toList();
              Map<String, Map<String, int>> matriz(String campo) {
                final m = <String, Map<String, int>>{};
                for (final l in e.value) {
                  final t = m.putIfAbsent(l['combinacion_codigo'], () => {});
                  t[l['tallas']['codigo']] = (t[l['tallas']['codigo']] ?? 0) + (l[campo] as int);
                }
                return m;
              }
              final pendiente = e.value.fold<int>(0, (a, l) => a + (l['pendiente'] as int));
              return Tarjeta(
                titulo: '${e.value.first['referencias']['codigo']} · ${e.value.first['referencias']['nombre']}',
                accion: crearOp && pendiente > 0
                    ? FilledButton.icon(
                        onPressed: r == null
                            ? null
                            : () async {
                                final id = await showDialog<String>(context: context, builder: (_) => DialogoNuevaOp(referencia: r, lineasPedido: e.value));
                                if (id != null && context.mounted) context.go('/op/$id');
                              },
                        icon: const Icon(Icons.precision_manufacturing_outlined),
                        label: Text(r == null ? 'Sin ficha aprobada' : 'Crear OP con $pendiente pendientes'))
                    : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Pedido', style: estilo(13, peso: FontWeight.w600, color: Colores.textoSuave)),
                  MatrizCantidades(combinaciones: combs, tallas: tallas, nombres: nombres, valores: matriz('cantidad')),
                  const SizedBox(height: 8),
                  Text('Pendiente de producir', style: estilo(13, peso: FontWeight.w600, color: Colores.textoSuave)),
                  MatrizCantidades(combinaciones: combs, tallas: tallas, nombres: nombres, valores: matriz('pendiente')),
                ]),
              );
            }(),
            const SizedBox(height: 12),
          ],
          if (opsUnicas.isNotEmpty)
            Tarjeta(
              titulo: 'Órdenes de producción de este pedido',
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final o in opsUnicas)
                  ActionChip(label: Text('${o['consecutivo']} · ${o['estado']}'), onPressed: () => context.go('/op/${o['id']}')),
              ]),
            ),
        ]);
      },
    );
  }
}

class _DialogoLineas extends ConsumerStatefulWidget {
  const _DialogoLineas({required this.pedidoId});
  final String pedidoId;
  @override
  ConsumerState<_DialogoLineas> createState() => _DialogoLineasState();
}

class _DialogoLineasState extends ConsumerState<_DialogoLineas> {
  Map<String, dynamic>? _ref;
  final _valores = <String, Map<String, int>>{};
  String? _error;

  @override
  Widget build(BuildContext context) {
    final refs = ref.watch(referenciasProduciblesProvider).value;
    return AlertDialog(
      title: const Text('Agregar referencia al pedido'),
      content: SizedBox(
        width: 760,
        child: refs == null ? const LinearProgressIndicator() : SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              isExpanded: true, decoration: const InputDecoration(labelText: 'Referencia (con ficha aprobada)'),
              items: [for (final r in refs) DropdownMenuItem(value: r['id'] as String, child: Text('${r['codigo']} · ${r['nombre']}'))],
              onChanged: (v) => setState(() {
                _ref = refs.firstWhere((r) => r['id'] == v);
                _valores.clear();
              }),
            ),
            if (_ref != null) ...[
              const SizedBox(height: 12),
              MatrizCantidades(
                combinaciones: combinacionesDe(_ref!), tallas: tallasDe(_ref!), nombres: nombresCombinacion(_ref!), valores: _valores,
                onCambio: (c, t, n) => setState(() => (_valores[c] ??= {})[t] = n),
              ),
            ],
            if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _ref == null ? null : () async {
            try {
              final tallas = await db.from('tallas').select('id, codigo');
              final idTalla = {for (final t in tallas) t['codigo']: t['id']};
              final filas = [
                for (final c in _valores.entries)
                  for (final t in c.value.entries)
                    if (t.value > 0)
                      {'pedido_id': widget.pedidoId, 'referencia_id': _ref!['id'], 'combinacion_codigo': c.key, 'talla_id': idTalla[t.key], 'cantidad': t.value},
              ];
              if (filas.isEmpty) return setState(() => _error = 'Escriba al menos una cantidad');
              await db.from('pedido_lineas').insert(filas);
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              setState(() => _error = mensajeError(e));
            }
          },
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}

// =====================================================================
// Nueva OP (desde un pedido o directa)
// =====================================================================
class DialogoNuevaOp extends ConsumerStatefulWidget {
  const DialogoNuevaOp({super.key, this.referencia, this.lineasPedido});
  final Map<String, dynamic>? referencia;
  final List<Map<String, dynamic>>? lineasPedido;
  @override
  ConsumerState<DialogoNuevaOp> createState() => _DialogoNuevaOpState();
}

class _DialogoNuevaOpState extends ConsumerState<DialogoNuevaOp> {
  late Map<String, dynamic>? _ref = widget.referencia;
  final _valores = <String, Map<String, int>>{};
  Map<String, Map<String, int>>? _maximos;
  String? _inicio, _entrega, _comprometida;
  var _prioridad = 3;
  final _obs = TextEditingController();
  String? _error;
  var _creando = false;

  @override
  void initState() {
    super.initState();
    final l = widget.lineasPedido;
    if (l != null) {
      _maximos = {};
      for (final x in l) {
        final c = x['combinacion_codigo'] as String, t = x['tallas']['codigo'] as String;
        (_valores[c] ??= {})[t] = ((_valores[c]?[t]) ?? 0) + (x['pendiente'] as int);
        (_maximos![c] ??= {})[t] = _valores[c]![t]!;
      }
    }
  }

  /// Reparte la cantidad de la OP entre las líneas del pedido (por combinación y talla).
  List<Map<String, dynamic>> _lineasAsignadas() {
    final out = <Map<String, dynamic>>[];
    final usado = <String, int>{};
    for (final l in widget.lineasPedido ?? const <Map<String, dynamic>>[]) {
      final c = l['combinacion_codigo'] as String, t = l['tallas']['codigo'] as String;
      final k = '$c|$t';
      final quiere = (_valores[c]?[t] ?? 0) - (usado[k] ?? 0);
      final toma = quiere.clamp(0, l['pendiente'] as int);
      if (toma > 0) {
        out.add({'pedido_linea_id': l['pedido_linea_id'], 'cantidad': toma});
        usado[k] = (usado[k] ?? 0) + toma;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final refs = ref.watch(referenciasProduciblesProvider).value;
    final r = _ref;
    return AlertDialog(
      title: Text(widget.lineasPedido != null ? 'Nueva OP desde el pedido' : 'Nueva orden de producción'),
      content: SizedBox(
        width: 820,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.referencia == null)
              DropdownButtonFormField<String>(
                isExpanded: true, decoration: const InputDecoration(labelText: 'Referencia (solo con ficha aprobada)'),
                items: [for (final x in refs ?? const []) DropdownMenuItem(value: x['id'] as String, child: Text('${x['codigo']} · ${x['nombre']}'))],
                onChanged: (v) => setState(() {
                  _ref = refs!.firstWhere((x) => x['id'] == v);
                  _valores.clear();
                }),
              )
            else
              Text('${r!['codigo']} · ${r['nombre']} · ficha v${r['vigente']?['version']}', style: estilo(15, peso: FontWeight.w600)),
            if (r != null) ...[
              const SizedBox(height: 12),
              MatrizCantidades(
                combinaciones: combinacionesDe(r), tallas: tallasDe(r), nombres: nombresCombinacion(r), valores: _valores, maximos: _maximos,
                onCambio: (c, t, n) => setState(() => (_valores[c] ??= {})[t] = n),
              ),
              if (widget.lineasPedido != null)
                Text('Si produce más de lo pendiente, el excedente queda en la OP sin pedido asignado.', style: estilo(12.5, color: Colores.textoSuave)),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              CampoFecha(etiqueta: 'Inicio planeado', valor: _inicio, onCambio: (v) => setState(() => _inicio = v)),
              CampoFecha(etiqueta: 'Entrega planeada', valor: _entrega, onCambio: (v) => setState(() => _entrega = v)),
              CampoFecha(etiqueta: 'Comprometida al cliente', valor: _comprometida, onCambio: (v) => setState(() => _comprometida = v)),
              SizedBox(width: 160, child: DropdownButtonFormField<int>(
                initialValue: _prioridad, decoration: const InputDecoration(labelText: 'Prioridad', isDense: true),
                items: const [DropdownMenuItem(value: 1, child: Text('1 · Urgente')), DropdownMenuItem(value: 2, child: Text('2 · Alta')),
                  DropdownMenuItem(value: 3, child: Text('3 · Normal')), DropdownMenuItem(value: 4, child: Text('4 · Baja')), DropdownMenuItem(value: 5, child: Text('5 · Relleno'))],
                onChanged: (v) => _prioridad = v!)),
              SizedBox(width: 400, child: TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación', isDense: true))),
            ]),
            const SizedBox(height: 8),
            Text('Al crearla se calculan las necesidades de material, se reserva lo disponible y lo que falte queda en una requisición de compra.',
                style: estilo(12.5, color: Colores.textoSuave)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: estilo(13.5, color: Colores.rojo))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: r == null || _creando ? null : () async {
            setState(() {
              _creando = true;
              _error = null;
            });
            try {
              final cant = {for (final c in _valores.entries) c.key: {for (final t in c.value.entries) if (t.value > 0) t.key: t.value}};
              final id = await db.rpc('crear_op', params: {
                'p_referencia': r['id'], 'p_cantidades': cant, 'p_fecha_entrega': _entrega, 'p_prioridad': _prioridad,
                'p_observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(), 'p_pedido_lineas': _lineasAsignadas(),
                'p_fecha_inicio': _inicio, 'p_fecha_comprometida': _comprometida,
              });
              if (context.mounted) {
                avisar(context, 'OP creada');
                Navigator.pop(context, id as String);
              }
            } catch (e) {
              setState(() {
                _error = mensajeError(e);
                _creando = false;
              });
            }
          },
          child: Text(_creando ? 'Creando…' : 'Crear OP'),
        ),
      ],
    );
  }
}
