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
}
