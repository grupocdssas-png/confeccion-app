import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../eficiencia/pantalla_eficiencia.dart' show descargarCsv;
import '../inventario/comun_inventario.dart' show db, mensajeError, avisar;

enum TipoCol { texto, entero, decimal, pct, cop, fecha, sino }

class ColInforme {
  const ColInforme(this.clave, this.titulo, [this.tipo = TipoCol.texto]);
  final String clave, titulo;
  final TipoCol tipo;
  bool get numerica => tipo != TipoCol.texto && tipo != TipoCol.fecha && tipo != TipoCol.sino;

  String formato(Object? v) => v == null
      ? ''
      : switch (tipo) {
          TipoCol.entero => Formato.numero(v as num, decimales: 0),
          TipoCol.decimal => Formato.numero(v as num, decimales: 2),
          TipoCol.pct => '${Formato.numero(v as num, decimales: 1)} %',
          TipoCol.cop => Formato.cop(v as num),
          TipoCol.fecha => Formato.fecha(DateTime.parse(v.toString().length == 10 ? '${v}T12:00:00Z' : v.toString())),
          TipoCol.sino => v == true ? 'Sí' : 'No',
          TipoCol.texto => '$v',
        };
}

class DefInforme {
  const DefInforme(this.clave, this.titulo, this.descripcion, this.rpc, this.columnas, {this.conFechas = true, this.params = const {}, this.diasPorDefecto = 30});
  final String clave, titulo, descripcion, rpc;
  final List<ColInforme> columnas;
  final bool conFechas;
  final Map<String, Object> params;
  final int diasPorDefecto;
}

const informes = [
  DefInforme('produccion', 'Producción por OP y proceso', 'Entra, buenas, segundas y faltantes de cada proceso (regla: entra = buenas + segundas + faltantes).',
      'informe_produccion', [
        ColInforme('op', 'OP'), ColInforme('referencia', 'Referencia'), ColInforme('proceso', 'Proceso'), ColInforme('entra', 'Entra', TipoCol.entero),
        ColInforme('buenas', 'Buenas', TipoCol.entero), ColInforme('segundas', 'Segundas', TipoCol.entero), ColInforme('faltantes', 'Faltantes', TipoCol.entero),
        ColInforme('segundas_pct', '% segundas', TipoCol.pct), ColInforme('unidades', 'Entregas', TipoCol.entero),
      ]),
  DefInforme('atrasadas', 'OP atrasadas o en riesgo', 'OP cuya fecha de entrega ya pasó o cuya programación termina después de la entrega.',
      'informe_ops_atrasadas', [
        ColInforme('op', 'OP'), ColInforme('referencia', 'Referencia'), ColInforme('cantidad', 'Prendas', TipoCol.entero), ColInforme('proceso', 'Proceso actual'),
        ColInforme('entrega', 'Entrega', TipoCol.fecha), ColInforme('fin_programado', 'Fin programado', TipoCol.fecha),
        ColInforme('dias_atraso', 'Días de atraso', TipoCol.entero), ColInforme('terminadas', 'Terminadas', TipoCol.entero), ColInforme('avance_pct', 'Avance', TipoCol.pct),
      ], conFechas: false),
  DefInforme('costos', 'Costo real vs estándar por OP', 'Tela, insumos, satélites, mano de obra e indirectos. Solo Costos y Gerencia.', 'informe_costos', [
    ColInforme('op', 'OP'), ColInforme('referencia', 'Referencia'), ColInforme('estado', 'Estado'), ColInforme('prendas', 'Cortadas', TipoCol.entero),
    ColInforme('buenas', 'Terminadas', TipoCol.entero), ColInforme('estandar', 'Estándar', TipoCol.cop), ColInforme('valor_real', 'Real', TipoCol.cop),
    ColInforme('desviacion_pct', 'Desviación', TipoCol.pct), ColInforme('unitario_estandar', 'Unitario estándar', TipoCol.cop),
    ColInforme('unitario_real', 'Unitario real', TipoCol.cop), ColInforme('tela_desv', 'Desv. tela', TipoCol.pct), ColInforme('mano_obra_desv', 'Desv. mano de obra', TipoCol.pct),
  ]),
  DefInforme('consumo', 'Consumo de tela por corte', 'Teórico (trazo) contra real (lo que salió de los rollos). Alerta si pasa de la tolerancia.', 'informe_consumo_tela', [
    ColInforme('corte', 'Corte'), ColInforme('op', 'OP'), ColInforme('fecha', 'Fecha', TipoCol.fecha), ColInforme('material', 'Tela'), ColInforme('color', 'Color'),
    ColInforme('piezas', 'Piezas', TipoCol.entero), ColInforme('teorico', 'Teórico', TipoCol.decimal), ColInforme('consumo_real', 'Real', TipoCol.decimal),
    ColInforme('desviacion_pct', 'Desviación', TipoCol.pct), ColInforme('unidad', 'Unidad'),
  ]),
  DefInforme('eficiencia', 'Eficiencia por operario', 'Minutos estándar producidos sobre minutos trabajados (descontando paros), por día.', 'informe_eficiencia', [
    ColInforme('codigo', 'Código'), ColInforme('nombre', 'Operario'), ColInforme('periodo', 'Día'), ColInforme('unidades', 'Unidades', TipoCol.entero),
    ColInforme('reprocesos', 'Reprocesos', TipoCol.entero), ColInforme('minutos_esperados', 'Min. estándar', TipoCol.decimal),
    ColInforme('minutos_reales', 'Min. trabajados', TipoCol.decimal), ColInforme('eficiencia', 'Eficiencia', TipoCol.pct), ColInforme('minutos_paro', 'Min. paro', TipoCol.entero),
  ], params: {'p_agrupar': 'operario', 'p_periodo': 'dia'}, diasPorDefecto: 7),
  DefInforme('calidad', 'Eficacia de calidad por operario', '% de primera calidad: prendas con defecto atribuidas sobre las revisadas de lo que hizo.', 'informe_eficacia', [
    ColInforme('codigo', 'Código'), ColInforme('nombre', 'Nombre'), ColInforme('inspeccionadas', 'Revisadas', TipoCol.entero),
    ColInforme('defectuosas', 'Con defecto', TipoCol.entero), ColInforme('primera_calidad', '% primera', TipoCol.pct),
    ColInforme('devoluciones', 'Devoluciones', TipoCol.entero), ColInforme('defecto_principal', 'Defecto principal'),
  ], params: {'p_agrupar': 'operario'}),
  DefInforme('pedidos', 'Cumplimiento de pedidos', 'Pedido, en OP, despachado y lo que falta, por pedido.', 'informe_pedidos', [
    ColInforme('pedido', 'Pedido'), ColInforme('cliente', 'Cliente'), ColInforme('fecha', 'Fecha', TipoCol.fecha), ColInforme('comprometida', 'Comprometida', TipoCol.fecha),
    ColInforme('pedidas', 'Pedidas', TipoCol.entero), ColInforme('en_op', 'En OP', TipoCol.entero), ColInforme('despachadas', 'Despachadas', TipoCol.entero),
    ColInforme('por_despachar', 'Por despachar', TipoCol.entero), ColInforme('cumplimiento_pct', 'Cumplimiento', TipoCol.pct), ColInforme('atrasado', 'Atrasado', TipoCol.sino),
  ], diasPorDefecto: 90),
  DefInforme('satelites', 'Satélites', 'Prendas enviadas y devueltas, segundas, faltantes, devoluciones a tiempo y valor.', 'informe_satelites', [
    ColInforme('satelite', 'Satélite'), ColInforme('proceso', 'Proceso'), ColInforme('remisiones', 'Remisiones', TipoCol.entero),
    ColInforme('enviadas', 'Enviadas', TipoCol.entero), ColInforme('devueltas', 'Devueltas', TipoCol.entero), ColInforme('buenas', 'Buenas', TipoCol.entero),
    ColInforme('segundas', 'Segundas', TipoCol.entero), ColInforme('faltantes', 'Faltantes', TipoCol.entero), ColInforme('segundas_pct', '% segundas', TipoCol.pct),
    ColInforme('a_tiempo_pct', 'A tiempo', TipoCol.pct), ColInforme('valor', 'Valor', TipoCol.cop),
  ]),
  DefInforme('inventario', 'Inventario valorizado', 'Telas e insumos al costo promedio; producto terminado y segundas al costo estándar.', 'informe_inventario_valorizado', [
    ColInforme('grupo', 'Grupo'), ColInforme('codigo', 'Código'), ColInforme('nombre', 'Nombre'), ColInforme('color', 'Color'), ColInforme('bodega', 'Bodega'),
    ColInforme('cantidad', 'Cantidad', TipoCol.decimal), ColInforme('unidad', 'Unidad'), ColInforme('costo_unitario', 'Costo unitario', TipoCol.cop),
    ColInforme('valor', 'Valor', TipoCol.cop),
  ], conFechas: false),
];

/// Informes exportables a Excel (CSV) y PDF.
class PantallaInformes extends ConsumerStatefulWidget {
  const PantallaInformes({super.key, this.inicial});
  final String? inicial;
  @override
  ConsumerState<PantallaInformes> createState() => _PantallaInformesState();
}

class _PantallaInformesState extends ConsumerState<PantallaInformes> {
  late DefInforme _def = informes.firstWhere((i) => i.clave == widget.inicial, orElse: () => informes.first);
  late DateTime _desde = DateTime.now().subtract(Duration(days: _def.diasPorDefecto));
  DateTime _hasta = DateTime.now();
  Future<List<Map<String, dynamic>>>? _datos;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

  void _cargar() => setState(() {
        _datos = db
            .rpc(_def.rpc, params: {if (_def.conFechas) ...{'p_desde': _iso(_desde), 'p_hasta': _iso(_hasta)}, ..._def.params})
            .then((v) => (v as List).cast<Map<String, dynamic>>());
      });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Informes', subtitulo: 'Exportables a Excel (CSV) y PDF'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final i in informes)
          ChoiceChip(
            label: Text(i.titulo),
            selected: _def == i,
            showCheckmark: false,
            labelStyle: estilo(13, peso: FontWeight.w600, color: _def == i ? Colors.white : Colores.texto),
            selectedColor: Colores.texto,
            backgroundColor: Colors.white,
            side: const BorderSide(color: Colores.borde),
            onSelected: (_) {
              _def = i;
              _desde = DateTime.now().subtract(Duration(days: i.diasPorDefecto));
              _hasta = DateTime.now();
              context.go('/informes?i=${i.clave}');
              _cargar();
            },
          ),
      ]),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (_def.conFechas) ...[
          for (final (t, v, f) in [('Desde', _desde, (DateTime x) => _desde = x), ('Hasta', _hasta, (DateTime x) => _hasta = x)])
            OutlinedButton.icon(
              onPressed: () async {
                final x = await showDatePicker(context: context, initialDate: v, firstDate: DateTime(2025), lastDate: DateTime.now().add(const Duration(days: 1)));
                if (x != null) {
                  f(x);
                  _cargar();
                }
              },
              icon: const Icon(Icons.event, size: 18),
              label: Text('$t ${Formato.fecha(v)}'),
            ),
        ],
        Text(_def.descripcion, style: estilo(13, color: Colores.textoSuave)),
      ]),
      const SizedBox(height: 14),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) {
            final m = mensajeError(s.error!);
            return Text(m.contains('Sin permiso') ? 'Su rol no tiene acceso a este informe.' : m, style: estilo(14, color: Colores.rojo));
          }
          if (!s.hasData) return const LinearProgressIndicator();
          final filas = s.data!;
          return Tarjeta(
            titulo: '${_def.titulo} · ${filas.length} filas',
            accion: Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: filas.isEmpty
                    ? null
                    : () => descargarCsv('${_def.clave}_${_iso(_desde)}_${_iso(_hasta)}.csv', [for (final c in _def.columnas) c.titulo],
                        [for (final f in filas) [for (final c in _def.columnas) c.tipo == TipoCol.sino ? c.formato(f[c.clave]) : f[c.clave]]]),
                icon: const Icon(Icons.download),
                label: const Text('Excel (CSV)'),
              ),
              OutlinedButton.icon(
                onPressed: filas.isEmpty ? null : () => _pdf(filas),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF'),
              ),
            ]),
            child: filas.isEmpty
                ? Padding(padding: const EdgeInsets.all(12), child: Text('Sin datos en el rango.', style: estilo(14, color: Colores.textoSuave)))
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: const WidgetStatePropertyAll(Colores.fondo),
                      headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
                      columnSpacing: 22,
                      columns: [for (final c in _def.columnas) DataColumn(label: Text(c.titulo), numeric: c.numerica)],
                      rows: [
                        for (final f in filas)
                          DataRow(cells: [
                            for (final c in _def.columnas)
                              DataCell(Text(c.formato(f[c.clave]),
                                  style: estilo(13.5, color: _color(c, f[c.clave])))),
                          ]),
                      ],
                    ),
                  ),
          );
        },
      ),
    ]);
  }

  Color? _color(ColInforme c, Object? v) {
    if (v is! num) return v == true && c.tipo == TipoCol.sino ? Colores.rojo : null;
    if (c.clave.contains('desv')) return v > 5 ? Colores.rojo : v < -5 ? Colores.verde : null;
    if (c.clave == 'eficiencia') return Colores.semaforo(v.toDouble());
    if (c.clave == 'dias_atraso' && v > 0) return Colores.rojo;
    return null;
  }

  Future<void> _pdf(List<Map<String, dynamic>> filas) async {
    try {
      final tema = pw.ThemeData.withFont(
        base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
        bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
      );
      final d = pw.Document(theme: tema, title: _def.titulo);
      final cols = _def.columnas;
      d.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(_def.titulo, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.Text('${_def.conFechas ? 'Del ${Formato.fecha(_desde)} al ${Formato.fecha(_hasta)} · ' : ''}Generado ${Formato.fechaHora(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
          pw.SizedBox(height: 8),
        ]),
        footer: (c) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Página ${c.pageNumber} de ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
        build: (_) => [
          pw.TableHelper.fromTextArray(
            headers: [for (final c in cols) c.titulo],
            data: [for (final f in filas) [for (final c in cols) c.formato(f[c.clave])]],
            headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
            cellAlignments: {for (var i = 0; i < cols.length; i++) if (cols[i].numerica) i: pw.Alignment.centerRight},
            border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC), width: 0.5)),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2.5),
          ),
        ],
      ));
      final bytes = Uint8List.fromList(await d.save());
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: _def.titulo);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}
