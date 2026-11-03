import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, avisar, numeroCo, catalogosProvider;
import 'comun_produccion.dart';

final _pendientesProvider = FutureProvider.autoDispose((ref) => db
    .from('requisicion_lineas')
    .select('*, materiales(codigo, nombre, unidad, proveedor_id, costo_estandar, proveedores(nombre)), colores(nombre), '
        'requisiciones!inner(consecutivo, estado, origen, ordenes_produccion(consecutivo, prioridad, fecha_entrega_plan))')
    .isFilter('oc_linea_id', null)
    .neq('requisiciones.estado', 'anulada')
    .order('fecha_requerida', ascending: true));

final _ocsProvider = FutureProvider.autoDispose((ref) => db
    .from('ordenes_compra')
    .select('*, proveedores(nombre), oc_lineas(cantidad, cantidad_recibida, precio_unitario, materiales(nombre, unidad), colores(nombre))')
    .order('creado_en', ascending: false)
    .limit(200));

/// Compras: requisiciones pendientes → órdenes de compra → recepción en inventario.
class PantallaCompras extends ConsumerStatefulWidget {
  const PantallaCompras({super.key});
  @override
  ConsumerState<PantallaCompras> createState() => _PantallaComprasState();
}

class _PantallaComprasState extends ConsumerState<PantallaCompras> {
  final _sel = <String>{};

  Future<void> _accion(Future<void> Function() f, [String? ok]) async {
    try {
      await f();
      ref.invalidate(_pendientesProvider);
      ref.invalidate(_ocsProvider);
      if (ok != null && mounted) avisar(context, ok);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('compras') ?? false;
    final pend = ref.watch(_pendientesProvider);
    final ocs = ref.watch(_ocsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Compras', subtitulo: 'Lo que falta para las OP se convierte en requisiciones; de ellas salen las órdenes de compra', acciones: [
        if (editar || (ref.watch(sesionProvider).value?.puedeEditar('op') ?? false))
          OutlinedButton.icon(onPressed: () async {
            if (await showDialog<bool>(context: context, builder: (_) => const _DialogoRequisicion()) == true) ref.invalidate(_pendientesProvider);
          }, icon: const Icon(Icons.add), label: const Text('Requisición manual')),
      ]),
      pend.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (lineas) {
          final porProv = <String?, List<Map<String, dynamic>>>{};
          for (final l in lineas) {
            porProv.putIfAbsent(l['materiales']['proveedor_id'], () => []).add(l);
          }
          return Tarjeta(
            titulo: 'Requisiciones pendientes de compra (${lineas.length} líneas)',
            child: lineas.isEmpty
                ? Text('No hay nada pendiente por comprar.', style: estilo(14, color: Colores.textoSuave))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final e in porProv.entries) ...[
                      Row(children: [
                        Expanded(child: Text(e.value.first['materiales']['proveedores']?['nombre'] ?? 'Sin proveedor habitual (asígnelo en el material)',
                            style: estilo(14.5, peso: FontWeight.w600))),
                        if (editar && e.key != null)
                          FilledButton.icon(
                            onPressed: e.value.any((l) => _sel.contains(l['id']))
                                ? () => _accion(() async {
                                      final id = await db.rpc('crear_oc', params: {'p_proveedor': e.key, 'p_lineas': [for (final l in e.value) if (_sel.contains(l['id'])) l['id']]});
                                      _sel.clear();
                                      if (mounted) GoRouter.of(this.context).go('/compras/oc/$id');
                                    }, 'Orden de compra creada')
                                : null,
                            icon: const Icon(Icons.shopping_cart_outlined), label: const Text('Crear orden de compra')),
                      ]),
                      Tabla(
                        columnas: const ['', 'Requisición', 'OP', 'Material', 'Color', 'Cantidad', 'Requerido para', 'Costo estimado'],
                        numericas: const {5, 7},
                        filas: [
                          for (final l in e.value)
                            DataRow(cells: [
                              DataCell(Checkbox(value: _sel.contains(l['id']), onChanged: e.key == null ? null : (v) => setState(() => v! ? _sel.add(l['id']) : _sel.remove(l['id'])))),
                              DataCell(Text('${l['requisiciones']['consecutivo']}${l['requisiciones']['origen'] == 'automatica' ? '' : ' (manual)'}', style: estiloCodigo(12.5))),
                              DataCell(Text('${l['requisiciones']['ordenes_produccion']?['consecutivo'] ?? '—'}', style: estiloCodigo(12.5))),
                              DataCell(Text('${l['materiales']['nombre']}')),
                              DataCell(Text('${l['colores']?['nombre'] ?? '—'}')),
                              DataCell(Text('${Formato.numero(l['cantidad'], decimales: 2)} ${l['materiales']['unidad']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text(l['fecha_requerida'] == null ? '—' : Formato.fecha(DateTime.parse('${l['fecha_requerida']}T12:00:00Z')))),
                              DataCell(Text(l['materiales']['costo_estandar'] == null ? '—' : Formato.cop((l['cantidad'] as num) * (l['materiales']['costo_estandar'] as num)))),
                            ]),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                  ]),
          );
        },
      ),
      const SizedBox(height: 16),
      ocs.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e)),
        data: (l) => Tarjeta(
          titulo: 'Órdenes de compra',
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Tabla(
            columnas: const ['OC', 'Proveedor', 'Fecha', 'Entrega', 'Líneas', 'Total', 'Recibido', 'Estado', ''],
            numericas: const {4, 5},
            vacio: 'No hay órdenes de compra.',
            filas: [
              for (final o in l)
                DataRow(cells: [
                  DataCell(Text('${o['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text('${o['proveedores']['nombre']}')),
                  DataCell(Text(Formato.fecha(DateTime.parse('${o['fecha']}T12:00:00Z')))),
                  DataCell(Text(o['fecha_entrega'] == null ? '—' : Formato.fecha(DateTime.parse('${o['fecha_entrega']}T12:00:00Z')))),
                  DataCell(Text('${(o['oc_lineas'] as List).length}')),
                  DataCell(Text(Formato.cop((o['oc_lineas'] as List).fold<num>(0, (a, x) => a + (x['cantidad'] as num) * ((x['precio_unitario'] ?? 0) as num))))),
                  DataCell(Text('${Formato.numero(_pct(o), decimales: 0)} %')),
                  DataCell(pastillaOc('${o['estado']}')),
                  DataCell(TextButton(onPressed: () => context.go('/compras/oc/${o['id']}'), child: const Text('Abrir'))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }

  double _pct(Map<String, dynamic> o) {
    final pedido = (o['oc_lineas'] as List).fold<num>(0, (a, x) => a + (x['cantidad'] as num));
    final recibido = (o['oc_lineas'] as List).fold<num>(0, (a, x) => a + (x['cantidad_recibida'] as num));
    return pedido == 0 ? 0 : (recibido / pedido * 100).clamp(0, 999).toDouble();
  }
}

Pastilla pastillaOc(String e) => switch (e) {
      'borrador' => const Pastilla('Borrador', color: Colores.textoSuave),
      'enviada' => Pastilla('Enviada', color: Colores.deProceso('corte')),
      'parcial' => const Pastilla('Recibida parcial', color: Colores.ambar),
      'recibida' => const Pastilla('Recibida', color: Colores.verde),
      'anulada' => const Pastilla('Anulada', color: Colores.rojo),
      _ => Pastilla(e, color: Colores.textoSuave),
    };

class _DialogoRequisicion extends ConsumerStatefulWidget {
  const _DialogoRequisicion();
  @override
  ConsumerState<_DialogoRequisicion> createState() => _DialogoRequisicionState();
}

class _DialogoRequisicionState extends ConsumerState<_DialogoRequisicion> {
  String? _material, _color, _fecha, _error;
  final _cant = TextEditingController(), _obs = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(catalogosProvider).value;
    final m = c?.material(_material);
    return AlertDialog(
      title: const Text('Requisición manual'),
      content: SizedBox(width: 460, child: c == null ? const LinearProgressIndicator() : Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(isExpanded: true, decoration: const InputDecoration(labelText: 'Material'),
            items: [for (final x in c.materiales) DropdownMenuItem(value: x['id'] as String, child: Text('${x['codigo']} · ${x['nombre']}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _material = v)),
        if (m?['maneja_color'] == true) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(decoration: const InputDecoration(labelText: 'Color'),
              items: [for (final x in c.colores) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))], onChanged: (v) => _color = v),
        ],
        const SizedBox(height: 10),
        TextField(controller: _cant, decoration: InputDecoration(labelText: 'Cantidad (${m?['unidad'] ?? ''})')),
        const SizedBox(height: 10),
        CampoFecha(etiqueta: 'Requerido para', valor: _fecha, ancho: 460, onCambio: (v) => setState(() => _fecha = v)),
        const SizedBox(height: 10),
        TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Motivo / observación')),
        if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () async {
          try {
            final r = await db.from('requisiciones').insert({'origen': 'manual', 'observacion': _obs.text.trim()}).select('id').single();
            await db.from('requisicion_lineas').insert({'requisicion_id': r['id'], 'material_id': _material, 'color_id': _color,
              'cantidad': numeroCo(_cant.text), 'fecha_requerida': _fecha});
            if (context.mounted) Navigator.pop(context, true);
          } catch (e) {
            setState(() => _error = mensajeError(e));
          }
        }, child: const Text('Crear')),
      ],
    );
  }
}

// =====================================================================
// Detalle de la orden de compra
// =====================================================================
class PantallaOc extends ConsumerStatefulWidget {
  const PantallaOc({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PantallaOc> createState() => _PantallaOcState();
}

class _PantallaOcState extends ConsumerState<PantallaOc> {
  late Future<Map<String, dynamic>> _datos = _cargar();
  Future<Map<String, dynamic>> _cargar() => db.from('ordenes_compra')
      .select('*, proveedores(nombre, nit, contacto, telefono), oc_lineas(*, materiales(codigo, nombre, unidad, tipo), colores(nombre), '
          'requisicion_lineas(requisiciones(consecutivo, ordenes_produccion(consecutivo)))), recepciones(id, consecutivo, estado, fecha)')
      .eq('id', widget.id).single();

  Future<void> _accion(Future<void> Function() f, [String? ok]) async {
    try {
      await f();
      setState(() => _datos = _cargar());
      if (ok != null && mounted) avisar(context, ok);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('compras') ?? false;
    final bodega = ref.watch(sesionProvider).value?.puedeEditar('inventario') ?? false;
    return FutureBuilder(
      future: _datos,
      builder: (context, s) {
        if (s.hasError) return Text(mensajeError(s.error!));
        if (!s.hasData) return const LinearProgressIndicator();
        final o = s.data!;
        final abierta = o['estado'] == 'enviada' || o['estado'] == 'parcial';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('Orden de compra ${o['consecutivo']}',
              subtitulo: '${o['proveedores']['nombre']} · NIT ${o['proveedores']['nit'] ?? '—'} · ${o['proveedores']['contacto'] ?? ''} ${o['proveedores']['telefono'] ?? ''}',
              acciones: [
                pastillaOc('${o['estado']}'),
                OutlinedButton(onPressed: () => context.go('/compras'), child: const Text('Volver')),
                if (editar && o['estado'] == 'borrador')
                  FilledButton(onPressed: () => _accion(() => db.rpc('cambiar_estado_oc', params: {'p_oc': widget.id, 'p_estado': 'enviada'}), 'OC marcada como enviada'),
                      child: const Text('Marcar como enviada')),
                if (bodega && abierta)
                  FilledButton.icon(onPressed: () => context.go('/inventario/entradas/nueva?oc=${widget.id}'), icon: const Icon(Icons.move_to_inbox_outlined),
                      label: const Text('Registrar entrada')),
                if (editar && (o['estado'] == 'borrador' || o['estado'] == 'enviada'))
                  OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                      onPressed: () => _accion(() => db.rpc('cambiar_estado_oc', params: {'p_oc': widget.id, 'p_estado': 'anulada'}), 'OC anulada: lo pedido vuelve a requisiciones pendientes'),
                      child: const Text('Anular')),
              ]),
          Tarjeta(
            child: Wrap(spacing: 16, runSpacing: 12, children: [
              CampoFecha(etiqueta: 'Fecha de entrega', valor: o['fecha_entrega'],
                  onCambio: editar ? (v) => _accion(() => db.from('ordenes_compra').update({'fecha_entrega': v}).eq('id', widget.id)) : (_) {}),
              SizedBox(width: 520, child: TextFormField(initialValue: o['observacion'] ?? '', enabled: editar,
                  decoration: const InputDecoration(labelText: 'Observación', isDense: true),
                  onFieldSubmitted: (v) => _accion(() => db.from('ordenes_compra').update({'observacion': v}).eq('id', widget.id), 'Guardado'))),
            ]),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Líneas',
            child: Tabla(
              columnas: const ['Material', 'Color', 'Cantidad', 'Recibido', 'Precio unitario', 'Subtotal', 'Para'],
              numericas: const {2, 3, 4, 5},
              filas: [
                for (final l in o['oc_lineas'] as List)
                  DataRow(cells: [
                    DataCell(Text('${l['materiales']['nombre']}')),
                    DataCell(Text('${l['colores']?['nombre'] ?? '—'}')),
                    DataCell(Text('${Formato.numero(l['cantidad'], decimales: 2)} ${l['materiales']['unidad']}')),
                    DataCell(Text(Formato.numero(l['cantidad_recibida'], decimales: 2),
                        style: TextStyle(color: (l['cantidad_recibida'] as num) >= (l['cantidad'] as num) ? Colores.verde : null, fontWeight: FontWeight.w600))),
                    DataCell(editar && o['estado'] == 'borrador'
                        ? SizedBox(width: 110, child: TextFormField(initialValue: '${l['precio_unitario'] ?? ''}', textAlign: TextAlign.right,
                            decoration: const InputDecoration(isDense: true),
                            onFieldSubmitted: (v) => _accion(() => db.from('oc_lineas').update({'precio_unitario': numeroCo(v)}).eq('id', l['id']))))
                        : Text(l['precio_unitario'] == null ? '—' : Formato.cop(l['precio_unitario']))),
                    DataCell(Text(Formato.cop((l['cantidad'] as num) * ((l['precio_unitario'] ?? 0) as num)))),
                    DataCell(Text({for (final r in l['requisicion_lineas'] as List) r['requisiciones']['ordenes_produccion']?['consecutivo'] ?? r['requisiciones']['consecutivo']}.join(', '),
                        style: estilo(12.5))),
                  ]),
              ],
            ),
          ),
          if ((o['recepciones'] as List).isNotEmpty) ...[
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Entradas recibidas',
              child: Wrap(spacing: 8, children: [
                for (final r in o['recepciones'] as List)
                  ActionChip(label: Text('${r['consecutivo']} · ${r['estado']}'), onPressed: () => context.go('/inventario/entradas/${r['id']}')),
              ]),
            ),
          ],
        ]);
      },
    );
  }
}
