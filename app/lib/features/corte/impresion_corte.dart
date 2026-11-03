import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/calculos/corte.dart';
import '../../core/etiquetas/etiquetas_pdf.dart';
import '../../core/etiquetas/impresion_web.dart';
import '../../core/etiquetas/zpl.dart';
import '../../core/formato/formato.dart';
import '../inventario/comun_inventario.dart' show db, avisar, mensajeError;
import 'datos_corte.dart';

Future<Map<String, dynamic>?> _plantilla(String tipo) =>
    db.from('plantillas_etiqueta').select().eq('tipo', tipo).eq('activa', true).maybeSingle();

/// Imprime etiquetas de paquetes (Browser Print o PDF de 50 × 30 mm).
Future<void> imprimirPaquetesWeb(BuildContext context, ContextoCorte k, List<Map<String, dynamic>> paquetes) async {
  if (paquetes.isEmpty) return;
  try {
    final p = await _plantilla('paquete');
    final datos = [
      for (final q in paquetes)
        datosEtiquetaPaquete(
          codigo: q['codigo'],
          op: k.op['consecutivo'],
          referencia: k.op['referencias']['codigo'],
          talla: k.talla(q['talla_id']),
          cantidad: q['cantidad'] as int,
          color: k.color(q['color_id']),
          lote: '${q['lote_tintura']}',
          partes: (q['partes'] as List).map((x) => k.parte('$x')).join(' + '),
          capaDesde: q['capa_desde'] as int,
          capaHasta: q['capa_hasta'] as int,
          espiga: q['espiga'] as int,
          corte: k.corte['consecutivo'],
          fecha: DateTime.tryParse('${k.corte['confirmado_en']}') ?? DateTime.now(),
        ),
    ];
    final res = await imprimirEtiquetasWeb(
      etiquetas: [
        for (var i = 0; i < paquetes.length; i++)
          (codigo: paquetes[i]['codigo'] as String, entidadId: paquetes[i]['id'] as String?,
           zpl: renderizarZpl(p?['zpl'] ?? plantillaPaquetePorDefecto, datos[i])),
      ],
      generarPdf: () => EtiquetasPdf.paquetes(datos),
      entidad: 'paquetes',
      plantillaId: p?['id'],
      plantillaVersion: p?['version'],
    );
    if (context.mounted) {
      avisar(context, res.medio == 'browser_print'
          ? '${paquetes.length} etiquetas enviadas a ${res.impresora}'
          : 'Zebra Browser Print no está activo: se abrió el PDF (50 × 30 mm)');
    }
  } catch (e) {
    if (context.mounted) avisar(context, 'No se pudo imprimir: ${mensajeError(e)}', error: true);
  }
}

/// Imprime etiquetas de juegos. [juegos]: filas de `juegos` con combinación, talla y componentes.
Future<void> imprimirJuegosWeb(BuildContext context, Map<String, dynamic> op, List<Map<String, dynamic>> juegos) async {
  if (juegos.isEmpty) return;
  try {
    final p = await _plantilla('juego');
    final datos = [
      for (final j in juegos)
        datosEtiquetaJuego(
          codigo: j['codigo'],
          op: op['consecutivo'],
          referencia: op['referencias']['codigo'],
          talla: j['tallas']['codigo'],
          cantidad: j['cantidad'] as int,
          combinacion: '${j['ficha_combinaciones']['codigo']} · ${j['ficha_combinaciones']['nombre']}',
          paquetes: {for (final c in j['juego_componentes'] as List) '${c['paquetes']['codigo']}'.replaceFirst('PQ-', '')}.toList(),
        ),
    ];
    final res = await imprimirEtiquetasWeb(
      etiquetas: [
        for (var i = 0; i < juegos.length; i++)
          (codigo: juegos[i]['codigo'] as String, entidadId: juegos[i]['id'] as String?,
           zpl: renderizarZpl(p?['zpl'] ?? plantillaJuegoPorDefecto, datos[i])),
      ],
      generarPdf: () => EtiquetasPdf.juegos(datos),
      entidad: 'juegos',
      plantillaId: p?['id'],
      plantillaVersion: p?['version'],
    );
    if (context.mounted) {
      avisar(context, res.medio == 'browser_print' ? '${juegos.length} etiquetas enviadas a ${res.impresora}' : 'Se abrió el PDF de etiquetas (50 × 30 mm)');
    }
  } catch (e) {
    if (context.mounted) avisar(context, 'No se pudo imprimir: ${mensajeError(e)}', error: true);
  }
}

/// Hoja de instrucciones para la mesa de corte (A4): trazo, orden de tendido,
/// rollos con lote, capas y metros, y qué hacer con lo que sobra de cada rollo.
Future<Uint8List> instruccionesCortePdf(ContextoCorte k, DocumentoCorte doc) async {
  final tema = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
  );
  final despunte = ((k.corte['despunte_cm'] ?? 0) as num).toDouble();
  String n(num v, [int d = 2]) => Formato.numero(v, decimales: d);
  pw.Widget tabla(List<String> enc, List<List<String>> filas) => pw.TableHelper.fromTextArray(
        headers: enc, data: filas,
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC), width: 0.5)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
  const fines = {'vuelve': 'Vuelve a bodega', 'retazo': 'Pasa a retazo', 'agotado': 'Se agota (sobrante es desperdicio)'};
  final d = pw.Document(theme: tema, title: 'Instrucciones ${k.corte['consecutivo']}');
  d.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => [
      pw.Text('Instrucciones de corte ${k.corte['consecutivo']}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 3),
      pw.Text('${k.op['consecutivo']} · ${k.op['referencias']['codigo']} ${k.op['referencias']['nombre']} · ${nombreTipoCorte(k.corte['tipo'])} · '
          'mesa ${k.corte['estaciones']?['codigo'] ?? '—'} · despunte ${n(despunte, 1)} cm por capa', style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 10),
      for (final b in doc.bloques) ...() {
        final calc = calcularBloque(b.aCalculo(k.rollos), despunteCm: despunte);
        return [
          pw.Text('${b.nombre} · ${k.materiales[b.materialId]?['nombre'] ?? 'sin tela'}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text(b.esEspigas ? 'Tendido por espigas (${b.secciones.length} secciones; A es la cabecera)' : 'Tendido normal',
              style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 4),
          tabla(['Sección', 'Largo (m)', ...b.tallas.map(k.talla), 'Capas'], [
            for (final (i, s) in b.secciones.indexed)
              [s.letra, n(s.largo), for (final t in b.tallas) '${s.unidades[t] ?? 0}', '${calc.capasSeccion.length > i ? calc.capasSeccion[i] : 0}'],
          ]),
          pw.SizedBox(height: 6),
          pw.Text('Orden de tendido', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          tabla(['Capas', if (b.esEspigas) 'Espiga', 'Rollo', 'Color', 'Lote / tono', 'Ancho', 'Capas', 'Metros', 'Al terminar'], [
            for (final t in calc.tramos)
              [
                '${t.capaDesde}–${t.capaHasta}',
                if (b.esEspigas) 'E${t.tramo.espiga} (${b.secciones.take(b.secciones.length - t.tramo.espiga + 1).map((s) => s.letra).join('')})',
                '${k.rollos[t.tramo.rolloId]?['codigo'] ?? '?'}',
                k.color(t.tramo.colorId),
                '${k.rollos[t.tramo.rolloId]?['lote_tintura'] ?? ''} ${k.rollos[t.tramo.rolloId]?['tono'] ?? ''}',
                '${n((k.rollos[t.tramo.rolloId]?['ancho_real_cm'] ?? 0) as num, 1)} cm',
                '${t.tramo.capas}',
                n(t.metros),
                fines[doc.rollos[t.tramo.rolloId]?.fin ?? 'vuelve']!,
              ],
          ]),
          pw.SizedBox(height: 6),
          tabla(['Color', ...b.tallas.map(k.talla), 'Total'], [
            for (final c in calc.piezas.entries)
              [k.color(c.key), for (final t in b.tallas) '${c.value[t] ?? 0}', '${c.value.values.fold<int>(0, (a, x) => a + x)}'],
          ]),
          pw.Text('Total tendido: ${calc.capasTotales} capas · ${n(calc.metros)} m', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 14),
        ];
      }(),
      pw.Text('No mezcle lotes ni tonos en un paquete. Cada paquete lleva una sola talla, un color y un lote, máximo 20 prendas.',
          style: const pw.TextStyle(fontSize: 8.5)),
    ],
  ));
  return d.save();
}
