import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../eficiencia/pantalla_eficiencia.dart' show descargarCsv;
import 'comun_inventario.dart';

const _tipos = {'ingreso_op': 'Ingreso de OP', 'ingreso_segunda': 'Segunda', 'despacho': 'Despacho', 'devolucion': 'Devolución',
  'ajuste': 'Ajuste', 'traslado': 'Traslado', 'anulacion': 'Anulación'};

/// Producto terminado y segundas: existencias por referencia, color y talla; movimientos, ajustes y traslados.
class PantallaProducto extends ConsumerStatefulWidget {
  const PantallaProducto({super.key});
  @override
  ConsumerState<PantallaProducto> createState() => _PantallaProductoState();
}

class _PantallaProductoState extends ConsumerState<PantallaProducto> {
  var _bodega = 'producto_terminado';
  final _filtro = TextEditingController();
  Map<String, dynamic>? _sku; // fila de existencias elegida
  late Future<List<Map<String, dynamic>>> _datos = _cargar();
  late Future<List<Map<String, dynamic>>> _movs = _cargarMovs();

  Future<List<Map<String, dynamic>>> _cargar() async =>
      (await db.from('existencias_producto').select().eq('bodega_tipo', _bodega).order('referencia', ascending: true)).cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> _cargarMovs() async {
    var q = db.from('movimientos_producto').select('*, skus(codigo), bodegas(codigo, tipo), ordenes_produccion(consecutivo)');
    if (_sku != null) q = q.eq('sku_id', _sku!['sku_id']);
    return (await q.order('creado_en', ascending: false).limit(_sku == null ? 40 : 200)).cast<Map<String, dynamic>>();
  }

  void _recargar() => setState(() {
        _datos = _cargar();
        _movs = _cargarMovs();
      });

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editar = puedeEditarInventario(ref);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Inventarios', subtitulo: 'Producto terminado y segundas por referencia, color y talla'),
      const PestanasInventario('producto'),
      Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'producto_terminado', label: Text('Producto terminado')), ButtonSegment(value: 'segundas', label: Text('Segundas'))],
          selected: {_bodega},
          onSelectionChanged: (s) {
            _bodega = s.first;
            _sku = null;
            _recargar();
          },
        ),
        SizedBox(
          width: 260,
          child: TextField(
            controller: _filtro,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Referencia'),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final f = _filtro.text.trim().toUpperCase();
          final filas = s.data!.where((x) => f.isEmpty || '${x['referencia']} ${x['referencia_nombre']}'.toUpperCase().contains(f)).toList();
          final refs = <String, List<Map<String, dynamic>>>{};
          for (final x in filas) {
            refs.putIfAbsent('${x['referencia']}', () => []).add(x);
          }
          final total = filas.fold<int>(0, (a, x) => a + (x['cantidad'] as int));
          return Tarjeta(
            titulo: '${_bodega == 'segundas' ? 'Segundas' : 'Producto terminado'} · ${Formato.numero(total, decimales: 0)} prendas',
            accion: OutlinedButton.icon(
              onPressed: filas.isEmpty
                  ? null
                  : () => descargarCsv('${_bodega}_${DateTime.now().toIso8601String().substring(0, 10)}.csv',
                      ['Código', 'Referencia', 'Nombre', 'Color', 'Talla', 'Cantidad', 'Precio'],
                      [for (final x in filas) [x['codigo'], x['referencia'], x['referencia_nombre'], x['combinacion_codigo'], x['talla'], x['cantidad'], x['precio_venta']]]),
              icon: const Icon(Icons.download),
              label: const Text('Excel (CSV)'),
            ),
            child: filas.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text('Sin existencias. Entran solas cuando un paquete sale del último proceso de su ruta.',
                    style: estilo(14, color: Colores.textoSuave)))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final e in refs.entries) _matriz(e.value)]),
          );
        },
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: _sku == null ? 'Últimos movimientos' : 'Movimientos de ${_sku!['codigo']} · hay ${_sku!['cantidad']}',
        accion: _sku == null
            ? null
            : Wrap(spacing: 8, children: [
                if (editar) OutlinedButton.icon(onPressed: _ajustar, icon: const Icon(Icons.tune), label: const Text('Ajuste')),
                if (editar) OutlinedButton.icon(onPressed: _trasladar, icon: const Icon(Icons.swap_horiz), label: Text(_bodega == 'segundas' ? 'Pasar a terminado' : 'Pasar a segundas')),
                TextButton(onPressed: () => setState(() {
                  _sku = null;
                  _movs = _cargarMovs();
                }), child: const Text('Ver todos')),
              ]),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          key: ObjectKey(_movs),
          future: _movs,
          builder: (_, s) {
            if (!s.hasData) return const LinearProgressIndicator();
            return Tabla(
              columnas: const ['Fecha', 'Tipo', 'Producto', 'Bodega', 'Cantidad', 'Documento', 'OP', 'Motivo'],
              numericas: const {4},
              vacio: 'Sin movimientos.',
              filas: [
                for (final m in s.data!)
                  DataRow(cells: [
                    DataCell(Text(Formato.fechaHora(DateTime.parse(m['creado_en'])))),
                    DataCell(Text(_tipos[m['tipo']] ?? '${m['tipo']}')),
                    DataCell(Text('${m['skus']?['codigo'] ?? ''}', style: estiloCodigo(12.5))),
                    DataCell(Text('${m['bodegas']?['codigo'] ?? ''}')),
                    DataCell(Text('${(m['cantidad'] as int) > 0 ? '+' : ''}${m['cantidad']}',
                        style: estilo(14, peso: FontWeight.w600, color: (m['cantidad'] as int) > 0 ? Colores.verde : Colores.rojo))),
                    DataCell(Text('${m['documento'] ?? ''}')),
                    DataCell(Text('${m['ordenes_produccion']?['consecutivo'] ?? ''}')),
                    DataCell(Text('${m['motivo'] ?? ''}')),
                  ]),
              ],
            );
          },
        ),
      ),
    ]);
  }

  /// Una referencia: filas = color/combinación, columnas = tallas
  Widget _matriz(List<Map<String, dynamic>> xs) {
    final tallas = <String, int>{for (final x in xs) '${x['talla']}': x['talla_orden'] as int};
    final orden = tallas.keys.toList()..sort((a, b) => tallas[a]!.compareTo(tallas[b]!));
    final combs = {for (final x in xs) '${x['combinacion_codigo']}'}.toList()..sort();
    Map<String, dynamic>? celda(String c, String t) => xs.where((x) => x['combinacion_codigo'] == c && x['talla'] == t).firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${xs.first['referencia']} · ${xs.first['referencia_nombre']}', style: estilo(15, peso: FontWeight.w600)),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const FixedColumnWidth(76),
            columnWidths: const {0: FixedColumnWidth(110)},
            border: TableBorder.all(color: Colores.borde),
            children: [
              TableRow(decoration: const BoxDecoration(color: Colores.fondo), children: [
                _c('Color', negrita: true),
                for (final t in orden) _c(t, negrita: true, centro: true),
                _c('Total', negrita: true, centro: true),
              ]),
              for (final c in combs)
                TableRow(children: [
                  _c(c, negrita: true),
                  for (final t in orden)
                    InkWell(
                      onTap: celda(c, t) == null ? null : () => setState(() {
                        _sku = celda(c, t);
                        _movs = _cargarMovs();
                      }),
                      child: Container(
                        color: _sku != null && celda(c, t)?['sku_id'] == _sku!['sku_id'] ? Colores.deProceso('calidad').withValues(alpha: 0.15) : null,
                        child: _c(celda(c, t) == null ? '·' : Formato.numero(celda(c, t)!['cantidad'], decimales: 0), centro: true),
                      ),
                    ),
                  _c(Formato.numero(xs.where((x) => x['combinacion_codigo'] == c).fold<int>(0, (a, x) => a + (x['cantidad'] as int)), decimales: 0),
                      negrita: true, centro: true),
                ]),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _c(String t, {bool negrita = false, bool centro = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Text(t, textAlign: centro ? TextAlign.center : TextAlign.start, style: estilo(13.5, peso: negrita ? FontWeight.w600 : FontWeight.w400)),
      );

  Future<void> _ajustar() async {
    final s = _sku!;
    final cant = TextEditingController();
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Ajuste de ${s['codigo']}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Hay ${s['cantidad']}. Escriba cuántas suma (+) o resta (−).', style: estilo(14, color: Colores.textoSuave)),
            const SizedBox(height: 10),
            TextField(controller: cant, keyboardType: const TextInputType.numberWithOptions(signed: true), decoration: const InputDecoration(labelText: 'Cantidad (ej. -2)')),
            const SizedBox(height: 10),
            TextField(controller: motivo, decoration: const InputDecoration(labelText: 'Motivo')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Ajustar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await db.rpc('ajustar_producto', params: {'p_sku': s['sku_id'], 'p_bodega': s['bodega_id'], 'p_cantidad': int.tryParse(cant.text.trim()) ?? 0, 'p_motivo': motivo.text});
      _sku = null;
      _recargar();
      if (mounted) avisar(context, 'Ajuste registrado');
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  Future<void> _trasladar() async {
    final s = _sku!;
    final cant = TextEditingController(text: '1');
    final motivo = TextEditingController();
    final hacia = _bodega == 'segundas' ? 'producto_terminado' : 'segundas';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(hacia == 'segundas' ? 'Pasar a segundas' : 'Pasar a producto terminado'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: cant, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Prendas (hay ${s['cantidad']})')),
            const SizedBox(height: 10),
            TextField(controller: motivo, decoration: const InputDecoration(labelText: 'Motivo (ej. mancha en bodega)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Trasladar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final destino = (await db.from('bodegas').select('id').eq('tipo', hacia).eq('activo', true).order('codigo', ascending: true).limit(1).single())['id'];
      await db.rpc('trasladar_producto', params: {'p_sku': s['sku_id'], 'p_desde': s['bodega_id'], 'p_hacia': destino,
        'p_cantidad': int.tryParse(cant.text.trim()) ?? 0, 'p_motivo': motivo.text});
      _sku = null;
      _recargar();
      if (mounted) avisar(context, 'Traslado registrado');
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Despachos a pedidos
// ---------------------------------------------------------------------------
class PantallaDespachos extends ConsumerStatefulWidget {
  const PantallaDespachos({super.key});
  @override
  ConsumerState<PantallaDespachos> createState() => _PantallaDespachosState();
}

class _PantallaDespachosState extends ConsumerState<PantallaDespachos> {
  late Future<List<Map<String, dynamic>>> _datos = _cargar();

  Future<List<Map<String, dynamic>>> _cargar() async => (await db
          .from('despachos')
          .select('*, pedidos(consecutivo), clientes(nombre), movimientos_producto(cantidad, tipo, skus(codigo, talla_id, combinacion_codigo, referencias(codigo, nombre), tallas(codigo)))')
          .order('creado_en', ascending: false)
          .limit(100))
      .cast<Map<String, dynamic>>();

  @override
  Widget build(BuildContext context) {
    final editar = puedeEditarInventario(ref);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Inventarios', subtitulo: 'Despachos de producto terminado a pedidos'),
      const PestanasInventario('despachos'),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          return Tarjeta(
            titulo: 'Despachos',
            accion: editar
                ? FilledButton.icon(
                    onPressed: () async {
                      final ok = await showDialog<bool>(context: context, builder: (_) => const _NuevoDespacho());
                      if (ok == true) setState(() => _datos = _cargar());
                    },
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: const Text('Nuevo despacho'))
                : null,
            child: Tabla(
              columnas: const ['Despacho', 'Fecha', 'Pedido', 'Cliente', 'Prendas', 'Estado', ''],
              numericas: const {4},
              vacio: 'Aún no hay despachos.',
              filas: [
                for (final d in s.data!)
                  DataRow(cells: [
                    DataCell(Text('${d['consecutivo']}', style: estiloCodigo(13))),
                    DataCell(Text(Formato.fecha(DateTime.parse('${d['fecha']}T12:00:00Z')))),
                    DataCell(Text('${d['pedidos']?['consecutivo'] ?? ''}')),
                    DataCell(Text('${d['clientes']?['nombre'] ?? ''}')),
                    DataCell(Text(Formato.numero(_prendas(d), decimales: 0))),
                    DataCell(d['estado'] == 'anulado' ? const Pastilla('Anulado', color: Colores.rojo) : const Pastilla('Despachado', color: Colores.verde)),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Remisión (PDF)', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: () => _pdf(d)),
                      if (editar && d['estado'] != 'anulado')
                        IconButton(tooltip: 'Anular', icon: const Icon(Icons.block, color: Colores.rojo), onPressed: () => _anular(d)),
                    ])),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }

  int _prendas(Map<String, dynamic> d) =>
      -(d['movimientos_producto'] as List).where((m) => m['tipo'] == 'despacho').fold<int>(0, (a, m) => a + (m['cantidad'] as int));

  Future<void> _anular(Map<String, dynamic> d) async {
    final m = await pedirTexto(context, titulo: 'Anular ${d['consecutivo']}', etiqueta: 'Motivo', ayuda: 'Las prendas vuelven a producto terminado.');
    if (m == null) return;
    try {
      await db.rpc('anular_despacho', params: {'p_despacho': d['id'], 'p_motivo': m});
      setState(() => _datos = _cargar());
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  Future<void> _pdf(Map<String, dynamic> d) async {
    final tema = pw.ThemeData.withFont(
      base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
      bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
    );
    final lineas = [for (final m in d['movimientos_producto'] as List) if (m['tipo'] == 'despacho') m];
    final doc = pw.Document(theme: tema, title: '${d['consecutivo']}');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Remisión de despacho', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.Text('${d['consecutivo']}${d['estado'] == 'anulado' ? '  (ANULADO)' : ''}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text('Cliente: ${d['clientes']?['nombre'] ?? ''}   ·   Pedido: ${d['pedidos']?['consecutivo'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
              pw.Text('Fecha: ${Formato.fecha(DateTime.parse('${d['fecha']}T12:00:00Z'))}', style: const pw.TextStyle(fontSize: 10)),
              if (d['observacion'] != null) pw.Text('${d['observacion']}', style: const pw.TextStyle(fontSize: 10)),
            ]),
          ),
          pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: '${d['consecutivo']}', width: 64, height: 64),
        ]),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: ['Código', 'Referencia', 'Color', 'Talla', 'Prendas'],
          data: [
            for (final m in lineas)
              [
                '${m['skus']['codigo']}', '${m['skus']['referencias']['codigo']} ${m['skus']['referencias']['nombre']}', '${m['skus']['combinacion_codigo']}',
                '${m['skus']['tallas']['codigo']}', '${-(m['cantidad'] as int)}',
              ],
          ],
          headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
          cellAlignments: {4: pw.Alignment.centerRight},
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('Total: ${_prendas(d)} prendas', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ),
        pw.SizedBox(height: 50),
        pw.Row(children: [
          pw.Expanded(child: pw.Column(children: [pw.Divider(), pw.Text('Entrega', style: const pw.TextStyle(fontSize: 9))])),
          pw.SizedBox(width: 40),
          pw.Expanded(child: pw.Column(children: [pw.Divider(), pw.Text('Recibe (nombre, cédula y fecha)', style: const pw.TextStyle(fontSize: 9))])),
        ]),
      ],
    ));
    final bytes = Uint8List.fromList(await doc.save());
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: '${d['consecutivo']}');
  }
}

/// Elegir pedido → líneas por despachar con lo que hay en producto terminado → cantidades
class _NuevoDespacho extends StatefulWidget {
  const _NuevoDespacho();
  @override
  State<_NuevoDespacho> createState() => _NuevoDespachoState();
}

class _NuevoDespachoState extends State<_NuevoDespacho> {
  List<Map<String, dynamic>> _pedidos = [];
  String? _pedido;
  List<Map<String, dynamic>> _lineas = [];
  final _cant = <String, TextEditingController>{};
  final _obs = TextEditingController();
  var _ocupado = false;

  @override
  void initState() {
    super.initState();
    db.from('pedidos').select('id, consecutivo, clientes(nombre)').eq('estado', 'abierto').order('consecutivo', ascending: false).then((v) {
      if (mounted) setState(() => _pedidos = v.cast<Map<String, dynamic>>());
    });
  }

  Future<void> _elegir(String id) async {
    setState(() {
      _pedido = id;
      _lineas = [];
    });
    final ls = (await db.from('pedido_despachos').select().eq('pedido_id', id).gt('por_despachar', 0)).cast<Map<String, dynamic>>();
    final skus = [for (final l in ls) if (l['sku_id'] != null) l['sku_id']];
    final stock = skus.isEmpty
        ? <Map<String, dynamic>>[]
        : (await db.from('existencias_producto').select('sku_id, cantidad, codigo').eq('bodega_tipo', 'producto_terminado').inFilter('sku_id', skus)).cast<Map<String, dynamic>>();
    final refs = {for (final r in await db.from('referencias').select('id, codigo').inFilter('id', [for (final l in ls) l['referencia_id']])) r['id']: r['codigo']};
    final tallas = {for (final t in await db.from('tallas').select('id, codigo, orden')) t['id']: t};
    final filas = [
      for (final l in ls)
        {
          ...l,
          'ref': refs[l['referencia_id']],
          'talla': tallas[l['talla_id']]?['codigo'],
          'orden': tallas[l['talla_id']]?['orden'] ?? 0,
          'hay': stock.where((s) => s['sku_id'] == l['sku_id']).fold<int>(0, (a, s) => a + (s['cantidad'] as int)),
          'codigo': stock.where((s) => s['sku_id'] == l['sku_id']).firstOrNull?['codigo'],
        },
    ]..sort((a, b) => '${a['ref']}${a['combinacion_codigo']}'.compareTo('${b['ref']}${b['combinacion_codigo']}') != 0
        ? '${a['ref']}${a['combinacion_codigo']}'.compareTo('${b['ref']}${b['combinacion_codigo']}')
        : (a['orden'] as int).compareTo(b['orden'] as int));
    for (final c in _cant.values) {
      c.dispose();
    }
    _cant.clear();
    for (final f in filas) {
      final n = [(f['por_despachar'] as int), (f['hay'] as int)].reduce((a, b) => a < b ? a : b);
      _cant['${f['pedido_linea_id']}'] = TextEditingController(text: '${n < 0 ? 0 : n}');
    }
    if (mounted) setState(() => _lineas = filas);
  }

  @override
  void dispose() {
    for (final c in _cant.values) {
      c.dispose();
    }
    _obs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo despacho'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: _pedido,
              decoration: const InputDecoration(labelText: 'Pedido abierto'),
              items: [
                for (final p in _pedidos)
                  DropdownMenuItem(value: p['id'] as String, child: Text('${p['consecutivo']} · ${p['clientes']?['nombre'] ?? 'Sin cliente'}')),
              ],
              onChanged: (v) => v == null ? null : _elegir(v),
            ),
            const SizedBox(height: 12),
            if (_pedido != null && _lineas.isEmpty) Text('Este pedido no tiene nada por despachar.', style: estilo(14, color: Colores.textoSuave)),
            if (_lineas.isNotEmpty)
              Tabla(
                columnas: const ['Referencia', 'Color', 'Talla', 'Por despachar', 'Hay', 'Despachar'],
                numericas: const {3, 4},
                filas: [
                  for (final l in _lineas)
                    DataRow(cells: [
                      DataCell(Text('${l['ref']}')),
                      DataCell(Text('${l['combinacion_codigo']}')),
                      DataCell(Text('${l['talla']}')),
                      DataCell(Text('${l['por_despachar']}')),
                      DataCell(Text('${l['hay']}', style: estilo(14, color: (l['hay'] as int) < (l['por_despachar'] as int) ? Colores.ambar : null))),
                      DataCell(SizedBox(
                        width: 70,
                        child: TextField(controller: _cant['${l['pedido_linea_id']}'], keyboardType: TextInputType.number, enabled: l['sku_id'] != null),
                      )),
                    ]),
                ],
              ),
            const SizedBox(height: 10),
            TextField(controller: _obs, decoration: const InputDecoration(labelText: 'Observación (transportadora, guía…)')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _pedido == null || _lineas.isEmpty || _ocupado
              ? null
              : () async {
                  setState(() => _ocupado = true);
                  try {
                    final id = await db.rpc('despachar', params: {
                      'p_pedido': _pedido,
                      'p_lineas': [
                        for (final l in _lineas)
                          if (l['sku_id'] != null && (int.tryParse(_cant['${l['pedido_linea_id']}']!.text.trim()) ?? 0) > 0)
                            {'sku_id': l['sku_id'], 'cantidad': int.parse(_cant['${l['pedido_linea_id']}']!.text.trim())},
                      ],
                      'p_observacion': _obs.text,
                    });
                    final d = await db.from('despachos').select('consecutivo').eq('id', id).single();
                    if (context.mounted) {
                      avisar(context, 'Despacho ${d['consecutivo']} registrado');
                      Navigator.pop(context, true);
                    }
                  } catch (e) {
                    if (context.mounted) avisar(context, mensajeError(e), error: true);
                    setState(() => _ocupado = false);
                  }
                },
          child: const Text('Despachar'),
        ),
      ],
    );
  }
}
