import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Etiquetas en PDF al tamaño real (100 × 50 mm), una por página, para imprimir
/// desde el navegador cuando no hay Zebra Browser Print. Misma distribución
/// que la plantilla ZPL.
class EtiquetasPdf {
  static pw.ThemeData? _tema;

  static Future<pw.ThemeData> _cargarTema() async => _tema ??= pw.ThemeData.withFont(
        base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
        bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
      );

  static const _formato = PdfPageFormat(100 * PdfPageFormat.mm, 50 * PdfPageFormat.mm);

  static pw.Widget _qr(String codigo, double ladoMm) => pw.BarcodeWidget(
        barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
        data: codigo,
        width: ladoMm * PdfPageFormat.mm,
        height: ladoMm * PdfPageFormat.mm,
      );

  /// [rollos]: mapas de datosEtiquetaRollo().
  static Future<List<int>> rollos(List<Map<String, Object?>> rollos) async {
    final doc = pw.Document(theme: await _cargarTema(), title: 'Etiquetas de rollo');
    for (final r in rollos) {
      doc.addPage(pw.Page(
        pageFormat: _formato,
        margin: const pw.EdgeInsets.all(2.5 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _qr('${r['codigo']}', 30),
              pw.SizedBox(width: 4 * PdfPageFormat.mm),
              pw.Expanded(
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  pw.Text('${r['codigo']}', style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
                  pw.Text('${r['tela']}', maxLines: 2, style: const pw.TextStyle(fontSize: 9)),
                  pw.SizedBox(height: 3),
                  pw.Text('Color: ${r['color']}', style: const pw.TextStyle(fontSize: 9)),
                  pw.Text('Lote: ${r['lote']}   Tono: ${r['tono']}', style: const pw.TextStyle(fontSize: 9)),
                  pw.Text('Ancho: ${r['ancho']} cm', style: const pw.TextStyle(fontSize: 9)),
                  pw.Text('${r['metros']} m   ${r['kilos']} kg', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                ]),
              ),
            ]),
          ),
          pw.Divider(height: 4, thickness: 0.6),
          pw.Text('${r['proveedor']}', style: const pw.TextStyle(fontSize: 7)),
          pw.Text('Ingreso: ${r['fecha']}   Ubicación: ${r['ubicacion']}', style: const pw.TextStyle(fontSize: 7)),
        ]),
      ));
    }
    return doc.save();
  }

  /// [ubicaciones]: mapas de datosEtiquetaUbicacion().
  static Future<List<int>> ubicaciones(List<Map<String, Object?>> ubicaciones) async {
    final doc = pw.Document(theme: await _cargarTema(), title: 'Etiquetas de ubicación');
    for (final u in ubicaciones) {
      doc.addPage(pw.Page(
        pageFormat: _formato,
        margin: const pw.EdgeInsets.all(3 * PdfPageFormat.mm),
        build: (_) => pw.Row(children: [
          _qr('${u['codigo']}', 30),
          pw.SizedBox(width: 5 * PdfPageFormat.mm),
          pw.Expanded(
            child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('${u['codigo']}', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text('${u['bodega']}', style: const pw.TextStyle(fontSize: 11)),
              pw.Text('${u['descripcion']}', style: const pw.TextStyle(fontSize: 9)),
            ]),
          ),
        ]),
      ));
    }
    return doc.save();
  }

  static const _formatoChico = PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm);

  static pw.Widget _chica({required String codigo, required String linea1, required String grande, required List<String> lineas, required String pie}) =>
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _qr(codigo, 15),
            pw.SizedBox(width: 2 * PdfPageFormat.mm),
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(codigo, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                pw.Text(linea1, style: const pw.TextStyle(fontSize: 6), maxLines: 1),
                pw.Text(grande, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                for (final l in lineas) pw.Text(l, style: const pw.TextStyle(fontSize: 6), maxLines: 1),
              ]),
            ),
          ]),
        ),
        pw.Divider(height: 2, thickness: 0.4),
        pw.Text(pie, style: const pw.TextStyle(fontSize: 5.5), maxLines: 2),
      ]);

  /// [paquetes]: mapas de datosEtiquetaPaquete() (50 × 30 mm).
  static Future<List<int>> paquetes(List<Map<String, Object?>> paquetes) async {
    final doc = pw.Document(theme: await _cargarTema(), title: 'Etiquetas de paquete');
    for (final p in paquetes) {
      doc.addPage(pw.Page(
        pageFormat: _formatoChico,
        margin: const pw.EdgeInsets.all(1.5 * PdfPageFormat.mm),
        build: (_) => _chica(
          codigo: '${p['codigo']}',
          linea1: '${p['op']}  ${p['referencia']}',
          grande: 'T: ${p['talla']}  x${p['cantidad']}',
          lineas: ['${p['color']}', 'Lote ${p['lote']}'],
          pie: '${p['partes']}  Capas ${p['capas']}  ·  Corte ${p['corte']} ${p['fecha']}',
        ),
      ));
    }
    return doc.save();
  }

  /// [juegos]: mapas de datosEtiquetaJuego() (50 × 30 mm).
  static Future<List<int>> juegos(List<Map<String, Object?>> juegos) async {
    final doc = pw.Document(theme: await _cargarTema(), title: 'Etiquetas de juego');
    for (final j in juegos) {
      doc.addPage(pw.Page(
        pageFormat: _formatoChico,
        margin: const pw.EdgeInsets.all(1.5 * PdfPageFormat.mm),
        build: (_) => _chica(
          codigo: '${j['codigo']}',
          linea1: '${j['op']}  ${j['referencia']}',
          grande: 'T: ${j['talla']}  x${j['cantidad']}',
          lineas: ['${j['combinacion']}'],
          pie: '${j['paquetes']}',
        ),
      ));
    }
    return doc.save();
  }
}
