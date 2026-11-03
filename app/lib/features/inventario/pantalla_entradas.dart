import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'comun_inventario.dart';
import 'etiquetas_inventario_web.dart';

final _entradasProvider = FutureProvider.autoDispose((ref) => db
    .from('recepciones')
    .select('id, consecutivo, fecha, factura_proveedor, estado, proveedores(nombre), bodegas(nombre), recepcion_lineas(count)')
    .order('creado_en', ascending: false)
    .limit(200));

class PantallaEntradas extends ConsumerWidget {
  const PantallaEntradas({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_entradasProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Entradas', subtitulo: 'Recepción de telas (rollo por rollo) e insumos', acciones: [
        if (puedeEditarInventario(ref))
          FilledButton.icon(onPressed: () => context.go('/inventario/entradas/nueva'), icon: const Icon(Icons.add), label: const Text('Nueva entrada')),
      ]),
      const PestanasInventario('entradas'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (filas) => Tarjeta(
          padding: EdgeInsets.zero,
          child: Tabla(
            columnas: const ['Entrada', 'Fecha', 'Proveedor', 'Factura', 'Bodega', 'Líneas', 'Estado', ''],
            numericas: const {5},
            vacio: 'Aún no hay entradas.',
            filas: [
              for (final e in filas)
                DataRow(cells: [
                  DataCell(Text('${e['consecutivo']}', style: estiloCodigo(13))),
                  DataCell(Text(Formato.fecha(DateTime.parse('${e['fecha']}T12:00:00Z')))),
                  DataCell(Text('${e['proveedores']?['nombre'] ?? '—'}')),
                  DataCell(Text('${e['factura_proveedor'] ?? '—'}')),
                  DataCell(Text('${e['bodegas']?['nombre']}')),
                  DataCell(Text('${(e['recepcion_lineas'] as List).firstOrNull?['count'] ?? 0}')),
                  DataCell(pastillaEstadoDoc('${e['estado']}')),
                  DataCell(TextButton(onPressed: () => context.go('/inventario/entradas/${e['id']}'), child: const Text('Abrir'))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

// =====================================================================
// Nueva entrada
// =====================================================================
class _Linea {
  _Linea({this.material, this.color, String lote = '', String tono = '', String costo = '', this.ubicacion})
      : lote = TextEditingController(text: lote),
        tono = TextEditingController(text: tono),
        costo = TextEditingController(text: costo);
  String? material, color, ubicacion;
  final TextEditingController lote, tono, costo;
  final ancho = TextEditingController(), metros = TextEditingController(), kilos = TextEditingController(),
      cantidad = TextEditingController();
}

class PantallaNuevaEntrada extends ConsumerStatefulWidget {
  const PantallaNuevaEntrada({super.key});
  @override
  ConsumerState<PantallaNuevaEntrada> createState() => _PantallaNuevaEntradaState();
}

class _PantallaNuevaEntradaState extends ConsumerState<PantallaNuevaEntrada> {
  String? _proveedor, _bodega;
  final _factura = TextEditingController();
  final _obs = TextEditingController();
  final _lineas = <_Linea>[];
  var _guardando = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogosProvider);
    return cat.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e)),
      data: (c) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        EncabezadoPagina('Nueva entrada', subtitulo: 'Al confirmar se crean los rollos (TL-…), se suma al inventario y se imprimen las etiquetas.',
            acciones: [OutlinedButton(onPressed: () => context.go('/inventario/entradas'), child: const Text('Cancelar'))]),
        Tarjeta(
          titulo: 'Datos de la entrada',
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Proveedor'),
                items: [for (final p in c.proveedores) DropdownMenuItem(value: p['id'] as String, child: Text('${p['nombre']}', overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _proveedor = v),
                isExpanded: true,
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Bodega'),
                items: [for (final b in c.bodegas.where((b) => ['telas', 'insumos'].contains(b['tipo'])))
                  DropdownMenuItem(value: b['id'] as String, child: Text('${b['nombre']}'))],
                onChanged: (v) => setState(() {
                  _bodega = v;
                  for (final l in _lineas) {
                    l.ubicacion = null;
                  }
                }),
              ),
            ),
            SizedBox(width: 200, child: TextField(controller: _factura, decoration: const InputDecoration(labelText: 'Factura del proveedor'))),
            SizedBox(width: 360, child: TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación'))),
          ]),
        ),
        const SizedBox(height: 16),
        Tarjeta(
          titulo: 'Líneas (${_lineas.length})',
          accion: Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: _bodega == null ? null : () => setState(() => _lineas.add(_Linea(material: _primero(c, 'tela')))),
              icon: const Icon(Icons.add), label: const Text('Rollo de tela')),
            OutlinedButton.icon(
              onPressed: _bodega == null ? null : () => setState(() => _lineas.add(_Linea(material: _primero(c, 'insumo')))),
              icon: const Icon(Icons.add), label: const Text('Insumo')),
          ]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_bodega == null) Text('Elija primero la bodega.', style: estilo(14, color: Colores.textoSuave)),
            for (var i = 0; i < _lineas.length; i++) _filaLinea(c, i),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: estilo(14, color: Colores.rojo))),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _guardando || _lineas.isEmpty || _bodega == null ? null : () => _confirmar(c),
            icon: const Icon(Icons.check),
            label: Text(_guardando ? 'Guardando…' : 'Confirmar entrada'),
          ),
        ),
      ]),
    );
  }

  String? _primero(Catalogos c, String tipo) => c.materiales.where((m) => m['tipo'] == tipo).firstOrNull?['id'];

  Widget _filaLinea(Catalogos c, int i) {
    final l = _lineas[i];
    final m = c.material(l.material);
    final esTela = m?['tipo'] == 'tela';
    final rend = (m?['rendimiento_m_kg'] as num?)?.toDouble();
    final kilos = numeroCo(l.kilos.text);
    Widget campo(TextEditingController t, String et, double ancho, {String? ayuda}) => SizedBox(
          width: ancho,
          child: TextField(controller: t, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: et, hintText: ayuda, isDense: true)),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Colores.borde), borderRadius: BorderRadius.circular(6)),
      child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${i + 1}', style: estiloCodigo(14, color: Colores.textoSuave)),
        SizedBox(
          width: 280,
          child: DropdownButtonFormField<String>(
            initialValue: l.material,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Material', isDense: true),
            items: [
              for (final x in c.materiales.where((x) => x['tipo'] == (esTela ? 'tela' : 'insumo')))
                DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => l.material = v),
          ),
        ),
        if (m?['maneja_color'] == true)
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              initialValue: l.color,
              decoration: const InputDecoration(labelText: 'Color', isDense: true),
              items: [for (final x in c.colores) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
              onChanged: (v) => setState(() => l.color = v),
            ),
          ),
        if (esTela) ...[
          campo(l.lote, 'Lote tintura', 130),
          campo(l.tono, 'Tono', 70),
          campo(l.ancho, 'Ancho cm', 95),
          campo(l.kilos, 'Kilos', 90),
          campo(l.metros, 'Metros', 100, ayuda: rend != null && kilos != null ? Formato.dos(kilos * rend) : null),
        ] else
          campo(l.cantidad, 'Cantidad (${m?['unidad'] ?? ''})', 130),
        campo(l.costo, 'Costo / ${m?['unidad'] ?? 'und'}', 120),
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<String>(
            initialValue: l.ubicacion,
            decoration: const InputDecoration(labelText: 'Ubicación', isDense: true),
            items: [for (final u in ref.read(catalogosProvider).value!.ubicacionesDe(_bodega)) DropdownMenuItem(value: u['id'] as String, child: Text('${u['codigo']}'))],
            onChanged: (v) => setState(() => l.ubicacion = v),
          ),
        ),
        if (esTela)
          IconButton(
            tooltip: 'Otro rollo igual (mismo material, color, lote y costo)',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => setState(() => _lineas.insert(i + 1, _Linea(material: l.material, color: l.color, lote: l.lote.text,
                tono: l.tono.text, costo: l.costo.text, ubicacion: l.ubicacion)..ancho.text = l.ancho.text)),
          ),
        IconButton(tooltip: 'Quitar', icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => _lineas.removeAt(i))),
      ]),
    );
  }

  Future<void> _confirmar(Catalogos c) async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    String? recId;
    try {
      final filas = <Map<String, dynamic>>[];
      for (var i = 0; i < _lineas.length; i++) {
        final l = _lineas[i];
        final m = c.material(l.material);
        if (m == null) throw 'Línea ${i + 1}: elija el material';
        final esTela = m['tipo'] == 'tela';
        final kilos = numeroCo(l.kilos.text);
        var metros = numeroCo(l.metros.text);
        if (esTela && metros == null && kilos != null && m['rendimiento_m_kg'] != null) {
          metros = double.parse((kilos * (m['rendimiento_m_kg'] as num)).toStringAsFixed(2));
        }
        final cantidad = esTela ? (m['unidad'] == 'kg' ? kilos : metros) : numeroCo(l.cantidad.text);
        if (cantidad == null || cantidad <= 0) throw 'Línea ${i + 1}: falta la cantidad (${esTela ? 'kilos y metros' : m['unidad']})';
        filas.add({
          'orden': i + 1, 'material_id': l.material, 'color_id': l.color, 'cantidad': cantidad,
          'costo_unitario': numeroCo(l.costo.text), 'ubicacion_id': l.ubicacion,
          if (esTela) ...{'lote_tintura': l.lote.text.trim(), 'tono': l.tono.text.trim().isEmpty ? null : l.tono.text.trim(),
            'ancho_real_cm': numeroCo(l.ancho.text), 'metros': metros, 'kilos': kilos},
        });
      }
      final rec = await db.from('recepciones').insert({
        'proveedor_id': _proveedor, 'bodega_id': _bodega,
        'factura_proveedor': _factura.text.trim().isEmpty ? null : _factura.text.trim(),
        'observacion': _obs.text.trim().isEmpty ? null : _obs.text.trim(),
      }).select('id, consecutivo').single();
      recId = rec['id'] as String;
      await db.from('recepcion_lineas').insert([for (final f in filas) {...f, 'recepcion_id': recId}]);
      final creados = await db.rpc('confirmar_recepcion', params: {'p_recepcion': recId}) as List;
      if (!mounted) return;
      ref.invalidate(_entradasProvider);
      ref.invalidate(catalogosProvider);
      if (creados.isNotEmpty) {
        final imprimir = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Entrada ${rec['consecutivo']} confirmada'),
            content: Text('Se crearon ${creados.length} rollos. ¿Imprimir sus etiquetas ahora?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Después')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: Text('Imprimir ${creados.length} etiquetas')),
            ],
          ),
        );
        if (imprimir == true && mounted) {
          final rollos = await db.from('rollos').select(selectRolloEtiqueta).inFilter('id', [for (final r in creados) r['id']]).order('codigo', ascending: true);
          if (mounted) await imprimirRollosWeb(context, rollos);
        }
      }
      if (mounted) context.go('/inventario/entradas/$recId');
    } catch (e) {
      setState(() => _error = recId == null
          ? mensajeError(e)
          : 'La entrada quedó en borrador porque no se pudo confirmar: ${mensajeError(e)}. Ábrala en la lista para revisarla.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }
}

// =====================================================================
// Detalle de entrada
// =====================================================================
class PantallaDetalleEntrada extends ConsumerStatefulWidget {
  const PantallaDetalleEntrada({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PantallaDetalleEntrada> createState() => _PantallaDetalleEntradaState();
}

class _PantallaDetalleEntradaState extends ConsumerState<PantallaDetalleEntrada> {
  late Future<Map<String, dynamic>> _datos = _cargar();

  Future<Map<String, dynamic>> _cargar() => db
      .from('recepciones')
      .select('*, proveedores(nombre), bodegas(nombre), recepcion_lineas(*, materiales(nombre, unidad, tipo), colores(nombre), '
          'ubicaciones(codigo), rollos:rollo_id($selectRolloEtiqueta))')
      .eq('id', widget.id)
      .single();

  Future<void> _accion(Future<void> Function() f) async {
    try {
      await f();
      setState(() => _datos = _cargar());
      ref.invalidate(_entradasProvider);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _datos,
        builder: (context, s) {
          if (s.hasError) return Text(mensajeError(s.error!));
          if (!s.hasData) return const LinearProgressIndicator();
          final e = s.data!;
          final lineas = (e['recepcion_lineas'] as List).cast<Map<String, dynamic>>()..sort((a, b) => (a['orden'] as int).compareTo(b['orden'] as int));
          final rollos = [for (final l in lineas) if (l['rollos'] != null) l['rollos'] as Map<String, dynamic>];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            EncabezadoPagina('Entrada ${e['consecutivo']}',
                subtitulo: '${e['proveedores']?['nombre'] ?? 'Sin proveedor'} · ${e['bodegas']?['nombre']} · factura ${e['factura_proveedor'] ?? '—'}',
                acciones: [
                  pastillaEstadoDoc('${e['estado']}'),
                  OutlinedButton(onPressed: () => context.go('/inventario/entradas'), child: const Text('Volver')),
                  if (e['estado'] == 'borrador' && puedeEditarInventario(ref))
                    FilledButton(onPressed: () => _accion(() => db.rpc('confirmar_recepcion', params: {'p_recepcion': widget.id})),
                        child: const Text('Confirmar')),
                  if (rollos.isNotEmpty && e['estado'] == 'confirmada')
                    OutlinedButton.icon(
                      icon: const Icon(Icons.print_outlined),
                      label: Text('Reimprimir ${rollos.length} etiquetas'),
                      onPressed: () async {
                        final motivo = await pedirTexto(context, titulo: 'Reimprimir etiquetas', etiqueta: 'Motivo');
                        if (motivo != null && context.mounted) await imprimirRollosWeb(context, rollos, reimpresion: true, motivo: motivo);
                      },
                    ),
                  if (e['estado'] == 'confirmada' && puedeAprobarInventario(ref))
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                      onPressed: () async {
                        final motivo = await pedirTexto(context, titulo: 'Anular entrada', etiqueta: 'Motivo de la anulación');
                        if (motivo != null) await _accion(() => db.rpc('anular_recepcion', params: {'p_recepcion': widget.id, 'p_motivo': motivo}));
                      },
                      child: const Text('Anular'),
                    ),
                ]),
            if (e['estado'] == 'anulada') AvisoSinConexion('Anulada: ${e['motivo_anulacion']}'),
            Tarjeta(
              padding: EdgeInsets.zero,
              child: Tabla(
                columnas: const ['#', 'Material', 'Color', 'Lote', 'Ancho', 'Kilos', 'Metros', 'Cantidad', 'Costo unit.', 'Ubicación', 'Rollo'],
                numericas: const {4, 5, 6, 7, 8},
                filas: [
                  for (final l in lineas)
                    DataRow(cells: [
                      DataCell(Text('${l['orden']}')),
                      DataCell(Text('${l['materiales']['nombre']}')),
                      DataCell(Text('${l['colores']?['nombre'] ?? '—'}')),
                      DataCell(Text('${l['lote_tintura'] ?? '—'}${l['tono'] == null ? '' : ' · ${l['tono']}'}')),
                      DataCell(Text(l['ancho_real_cm'] == null ? '—' : Formato.numero(l['ancho_real_cm'], decimales: 1))),
                      DataCell(Text(l['kilos'] == null ? '—' : Formato.dos(l['kilos']))),
                      DataCell(Text(l['metros'] == null ? '—' : Formato.dos(l['metros']))),
                      DataCell(Text('${Formato.dos(l['cantidad'])} ${l['materiales']['unidad']}')),
                      DataCell(Text(l['costo_unitario'] == null ? '—' : Formato.cop(l['costo_unitario']))),
                      DataCell(Text('${l['ubicaciones']?['codigo'] ?? '—'}')),
                      DataCell(Text('${l['rollos']?['codigo'] ?? ''}', style: estiloCodigo(13))),
                    ]),
                ],
              ),
            ),
          ]);
        },
      );
}
