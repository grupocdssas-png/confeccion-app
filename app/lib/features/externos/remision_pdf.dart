import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/formato/formato.dart';

/// Remisión para acompañar la mercancía (A4): qué sale, para qué satélite y proceso,
/// con espacio para las firmas de quien entrega y quien recibe.
Future<Uint8List> remisionPdf(Map<String, dynamic> r, List<Map<String, dynamic>> unidades, List<Map<String, dynamic>> insumos) async {
  final tema = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
  );
  pw.Widget tabla(List<String> enc, List<List<String>> filas) => pw.TableHelper.fromTextArray(
        headers: enc, data: filas,
        headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC), width: 0.5)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
  final total = unidades.fold<int>(0, (a, u) => a + (u['cantidad'] as int));
  final esSalida = r['tipo'] == 'salida';
  final d = pw.Document(theme: tema, title: '${r['consecutivo']}');
  d.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(esSalida ? 'Remisión de salida' : 'Devolución de satélite', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text('${r['consecutivo']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Satélite: ${r['satelites']?['nombre'] ?? ''}${r['satelites']?['nit'] != null ? ' · NIT ${r['satelites']['nit']}' : ''}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('Proceso: ${r['procesos']?['nombre'] ?? r['proceso']}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('Fecha: ${Formato.fecha(DateTime.parse('${r['fecha']}T12:00:00Z'))}'
                '${r['fecha_compromiso'] != null ? '   ·   Devolver a más tardar: ${Formato.fecha(DateTime.parse('${r['fecha_compromiso']}T12:00:00Z'))}' : ''}',
                style: const pw.TextStyle(fontSize: 10)),
          ]),
        ),
        pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: '${r['consecutivo']}', width: 70, height: 70),
      ]),
      pw.SizedBox(height: 14),
      tabla(['Juego / paquete', 'OP', 'Referencia', 'Color', 'Talla', 'Prendas', if (!esSalida) ...['Buenas', 'Segundas', 'Faltantes']], [
        for (final u in unidades)
          [
            '${u['codigo'] ?? ''}', '${u['op'] ?? ''}', '${u['referencia'] ?? ''}', '${u['color'] ?? ''}', '${u['talla'] ?? ''}', '${u['cantidad']}',
            if (!esSalida) ...['${u['buenas'] ?? ''}', '${u['segundas'] ?? ''}', '${u['faltantes'] ?? ''}'],
          ],
      ]),
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text('Total: ${unidades.length} ${unidades.length == 1 ? 'unidad' : 'unidades'} · $total prendas',
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      ),
      if (insumos.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        pw.Text('Insumos enviados', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        tabla(['Insumo', 'Color', 'OP', 'Cantidad'], [
          for (final i in insumos) ['${i['material'] ?? ''}', '${i['color'] ?? '—'}', '${i['op'] ?? ''}', '${Formato.numero(i['cantidad'] as num)} ${i['unidad'] ?? ''}'],
        ]),
      ],
      if ((r['observacion'] ?? '').toString().isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('Observación: ${r['observacion']}', style: const pw.TextStyle(fontSize: 10)),
      ],
      pw.SizedBox(height: 50),
      pw.Row(children: [
        for (final t in ['Entrega (nombre y firma)', 'Recibe (nombre y firma)'])
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 12),
              child: pw.Column(children: [
                pw.Divider(thickness: 0.6),
                pw.Text(t, style: const pw.TextStyle(fontSize: 9)),
              ]),
            ),
          ),
      ]),
      pw.SizedBox(height: 10),
      pw.Text('Cuente las prendas al recibir. Toda diferencia se anota en la devolución como segunda o faltante.', style: const pw.TextStyle(fontSize: 8)),
    ],
  ));
  return d.save();
}
