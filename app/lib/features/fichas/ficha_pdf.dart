import 'dart:typed_data';

import 'package:flutter/material.dart' show BuildContext;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/formato/formato.dart';
import '../inventario/comun_inventario.dart' show db, avisar, mensajeError;
import 'datos_ficha.dart';

/// Genera el PDF de la ficha técnica (A4) y abre el diálogo de impresión/descarga.
Future<void> exportarFichaPdf(BuildContext context, Map<String, dynamic> f) async {
  try {
    final bytes = await generarFichaPdf(f);
    final r = f['referencias'];
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Ficha ${r['codigo']} v${f['version']}');
  } catch (e) {
    if (context.mounted) avisar(context, 'No se pudo generar el PDF: ${mensajeError(e)}', error: true);
  }
}

Future<Uint8List?> _imagen(String? ruta) async {
  if (ruta == null || !RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(ruta)) return null;
  try {
    final url = await db.storage.from('fichas').createSignedUrl(ruta, 300);
    final r = await http.get(Uri.parse(url));
    return r.statusCode == 200 ? r.bodyBytes : null;
  } catch (_) {
    return null;
  }
}

Future<Uint8List> generarFichaPdf(Map<String, dynamic> f, {bool conImagenes = true}) async {
  final tema = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
  );
  final r = f['referencias'];
  final tallas = tallasFicha(f);
  final partes = ordenar(f['ficha_partes']);
  final nombreParte = {for (final p in partes) p['id']: p['nombre']};
  final combs = ordenar(f['ficha_combinaciones']);
  final ops = ordenar(f['ficha_operaciones'], 'secuencia');
  final boceto = conImagenes ? await _imagen(f['boceto_path']) : null;
  final foto = conImagenes ? await _imagen(f['foto_path']) : null;

  pw.Widget titulo(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(t, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#3F4A5A'))),
      );
  pw.Widget tabla(List<String> enc, List<List<String>> filas) => pw.TableHelper.fromTextArray(
        headers: enc, data: filas,
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 8),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC), width: 0.5)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
  String n(Object? v, [int d = 2]) => v == null ? '' : Formato.numero(v as num, decimales: d);

  final costos = <String, Map<String, num>>{};
  for (final x in f['ficha_costo_estandar'] as List) {
    costos.putIfAbsent(x['combinacion_id'], () => {})[x['concepto']] = x['valor'];
  }

  final doc = pw.Document(theme: tema, title: 'Ficha técnica ${r['codigo']} v${f['version']}');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    header: (c) => pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC)))),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('FICHA TÉCNICA · ${r['codigo']} · versión ${f['version']} · ${f['estado']}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Text('Página ${c.pageNumber} de ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      ]),
    ),
    build: (_) => [
      pw.Text('${r['nombre']}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text([r['familias_producto']?['nombre'], r['tipos_producto']?['nombre']].whereType<String>().join(' · '), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 10),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          for (final (k, v) in [
            ('Descripción', f['descripcion']), ('Composición', f['composicion']), ('Lavado', f['instrucciones_lavado']),
            ('Tallas', tallas.map((t) => t['tallas']['codigo']).join(', ')), ('Curva', f['curvas']?['nombre'] ?? 'Partes iguales'),
            ('Precio objetivo', f['precio_objetivo'] == null ? null : Formato.cop(f['precio_objetivo'])),
            ('SAM total', f['sam_total'] == null ? null : '${n(f['sam_total'], 3)} min'),
            ('Costo estándar', f['costo_estandar'] == null ? null : Formato.cop(f['costo_estandar'])),
          ])
            if (v != null) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 3), child: pw.RichText(text: pw.TextSpan(children: [
              pw.TextSpan(text: '$k: ', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
              pw.TextSpan(text: '$v', style: const pw.TextStyle(fontSize: 9)),
            ]))),
        ])),
        if (foto != null) pw.Container(width: 120, height: 120, child: pw.Image(pw.MemoryImage(foto), fit: pw.BoxFit.contain)),
        if (boceto != null) pw.Container(width: 160, height: 120, margin: const pw.EdgeInsets.only(left: 8), child: pw.Image(pw.MemoryImage(boceto), fit: pw.BoxFit.contain)),
      ]),
      titulo('Medidas (cm)'),
      tabla(['Punto de medida', for (final t in tallas) '${t['tallas']['codigo']}', 'Tol. ±'], [
        for (final m in ordenar(f['ficha_medidas']))
          [
            '${m['punto_medida']}',
            for (final t in tallas) n((m['ficha_medida_tallas'] as List).where((x) => x['talla_id'] == t['talla_id']).firstOrNull?['valor_cm'], 1),
            n((m['ficha_medida_tallas'] as List).firstOrNull?['tolerancia_cm'], 1),
          ],
      ]),
      titulo('Partes y combinaciones de color'),
      tabla(['Combinación', for (final p in partes) '${p['nombre']}${p['puede_cortarse_retazo'] == true ? ' (retazo)' : ''}'], [
        for (final c in combs)
          ['${c['codigo']} · ${c['nombre']}', for (final p in partes) _colorParte(c, p['id'])],
      ]),
      titulo('Lista de materiales (consumo por prenda)'),
      tabla(['Material', 'Parte', 'Comb.', for (final t in tallas) '${t['tallas']['codigo']}', 'Unidad', 'Merma'], [
        for (final b in ordenar(f['ficha_bom']))
          [
            '${b['materiales']?['nombre']}', '${nombreParte[b['parte_id']] ?? ''}',
            b['combinacion_id'] == null ? 'Todas' : '${combs.where((c) => c['id'] == b['combinacion_id']).firstOrNull?['codigo'] ?? ''}',
            for (final t in tallas) n((b['ficha_bom_consumos'] as List).where((x) => x['talla_id'] == t['talla_id']).firstOrNull?['consumo'], 3),
            '${b['materiales']?['unidad']}', '${n(b['merma_pct'], 1)} %',
          ],
      ]),
      if ((f['ficha_artes'] as List).isNotEmpty) ...[
        titulo('Artes'),
        tabla(['Proceso', 'Nombre', 'Parte', 'Técnica', 'Tintas / hilos', 'Puntadas', 'Tamaño (cm)', 'Ubicación'], [
          for (final a in ordenar(f['ficha_artes']))
            ['${a['proceso']}', '${a['nombre']}', '${nombreParte[a['parte_id']] ?? ''}', '${a['tecnica'] ?? ''}', '${a['tintas'] ?? a['hilos'] ?? ''}',
             '${a['puntadas'] ?? ''}', '${n(a['ancho_cm'], 1)} × ${n(a['alto_cm'], 1)}', '${a['ubicacion'] ?? ''}'],
        ]),
      ],
      titulo('Ruta de procesos'),
      pw.Text([for (final x in ordenar(f['ficha_ruta'])) '${x['orden']}. ${x['proceso']}${x['modalidad'] != 'interno' ? ' (${x['modalidad']})' : ''}'].join('   →   '),
          style: const pw.TextStyle(fontSize: 9)),
      titulo('Secuencia de operaciones'),
      tabla(['Sec.', 'Código', 'Operación', 'Proceso', 'Parte', 'SAM', 'Und/h', 'Rep.', 'Máquina'], [
        for (final o in ops)
          ['${o['secuencia']}', '${o['operaciones']?['codigo']}', '${o['operaciones']?['nombre']}${o['es_contadora'] == true ? ' ★' : ''}', '${o['proceso']}',
           '${nombreParte[o['parte_id']] ?? ''}', n(o['sam'], 3), n(60 / (o['sam'] as num), 1), n(o['repeticiones'], 0),
           '${o['tipos_maquina']?['codigo'] ?? ''}'],
      ]),
      pw.Text('★ operación contadora', style: const pw.TextStyle(fontSize: 7)),
      if (costos.isNotEmpty) ...[
        titulo('Costo estándar por prenda'),
        tabla(['Combinación', 'Materiales', 'Mano de obra', 'Externos', 'Indirectos', 'Total'], [
          for (final e in costos.entries)
            ['${combs.where((c) => c['id'] == e.key).firstOrNull?['codigo'] ?? ''}',
             for (final k in ['materiales', 'mano_obra', 'externos', 'indirectos', 'total']) Formato.cop(e.value[k] ?? 0)],
        ]),
      ],
      if ((f['ficha_aprobaciones'] as List).isNotEmpty) ...[
        titulo('Aprobaciones'),
        for (final a in f['ficha_aprobaciones'] as List)
          pw.Text('${Formato.fechaHora(DateTime.parse(a['fecha']))} · ${a['area']} · ${a['decision']} · ${a['perfiles']?['nombre'] ?? ''}',
              style: const pw.TextStyle(fontSize: 8)),
      ],
    ],
  ));
  return doc.save();
}

String _colorParte(Map<String, dynamic> c, String parteId) {
  final cp = (c['ficha_combinacion_partes'] as List).where((x) => x['parte_id'] == parteId).firstOrNull;
  return cp == null ? '' : '${cp['color_nombre'] ?? _colores[cp['color_id']] ?? ''}';
}

/// Nombres de colores (se llena antes de generar el PDF desde el catálogo).
final _colores = <String, String>{};
void registrarColoresPdf(List<Map<String, dynamic>> colores) {
  for (final c in colores) {
    _colores[c['id']] = c['nombre'];
  }
}
