import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';

/// Hoja de secuencia y hoja de máquinas de una OP (A4).
/// [op]: OP con referencias y cantidades; [ops]: operaciones de su ficha (ficha_operaciones con operaciones y tipos_maquina).
Future<Uint8List> hojasOpPdf(Map<String, dynamic> op, List<Map<String, dynamic>> ops, Map<String, Map<String, int>> matriz,
    List<String> tallas) async {
  final tema = pw.ThemeData.withFont(
    base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
    bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
  );
  final cantidad = (op['cantidad_total'] as num).toInt();
  String n(num v, [int d = 2]) => Formato.numero(v, decimales: d);
  pw.Widget tabla(List<String> enc, List<List<String>> filas) => pw.TableHelper.fromTextArray(
        headers: enc, data: filas,
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 8.5),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF4F4F1)),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E2DC), width: 0.5)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
  pw.Widget encabezado(String titulo) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(titulo, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 3),
        pw.Text('${op['consecutivo']} · ${op['referencias']['codigo']} ${op['referencias']['nombre']} · ficha v${op['ficha_versiones']?['version']} · '
            '${n(cantidad, 0)} prendas${op['fecha_entrega_plan'] != null ? ' · entrega ${Formato.fecha(DateTime.parse('${op['fecha_entrega_plan']}T12:00:00Z'))}' : ''}',
            style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 8),
        tabla(['Combinación', ...tallas, 'Total'], [
          for (final c in matriz.entries)
            [c.key, for (final t in tallas) n(c.value[t] ?? 0, 0), n(c.value.values.fold<int>(0, (a, b) => a + b), 0)],
        ]),
        pw.SizedBox(height: 10),
      ]);

  final samTotal = ops.where((o) => o['agrega_minutos_sam'] == true).fold<double>(0, (a, o) => a + (o['sam'] as num) * (o['repeticiones'] as num));
  final porMaquina = <String, (String, double, int)>{};
  for (final o in ops) {
    final k = '${o['tipos_maquina']?['codigo'] ?? 'MANUAL'}';
    final v = porMaquina[k] ?? ('${o['tipos_maquina']?['nombre'] ?? 'Manual'}', 0.0, 0);
    porMaquina[k] = (v.$1, v.$2 + (o['sam'] as num) * (o['repeticiones'] as num), v.$3 + 1);
  }

  final doc = pw.Document(theme: tema, title: 'Hojas ${op['consecutivo']}');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => [
      encabezado('Hoja de secuencia'),
      tabla(['Sec.', 'Código', 'Operación', 'Proceso', 'Máquina', 'SAM', 'Rep.', 'Und/h', 'Min. OP', 'Horas OP'], [
        for (final o in ops)
          [
            '${o['secuencia']}', '${o['operaciones']?['codigo']}', '${o['operaciones']?['nombre']}${o['es_contadora'] == true ? ' *' : ''}',
            Colores.nombreProceso(o['proceso']), '${o['tipos_maquina']?['codigo'] ?? ''}', n(o['sam'], 3), n(o['repeticiones'], 0),
            n(60 / (o['sam'] as num), 1), n((o['sam'] as num) * (o['repeticiones'] as num) * cantidad, 0),
            n((o['sam'] as num) * (o['repeticiones'] as num) * cantidad / 60, 1),
          ],
      ]),
      pw.SizedBox(height: 6),
      pw.Text('SAM total ${n(samTotal, 3)} min por prenda · ${n(samTotal * cantidad / 60, 1)} horas para la OP · * operación contadora',
          style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
    ],
  ));
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => [
      encabezado('Hoja de máquinas'),
      tabla(['Máquina', 'Tipo', 'Operaciones', 'Min. por prenda', 'Horas OP', '% de la carga'], [
        for (final e in (porMaquina.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2))))
          [e.key, e.value.$1, '${e.value.$3}', n(e.value.$2, 3), n(e.value.$2 * cantidad / 60, 1),
           '${n(samTotal == 0 ? 0 : e.value.$2 / samTotal * 100, 1)} %'],
      ]),
      pw.SizedBox(height: 6),
      pw.Text('Las horas por máquina indican cuántos puestos de cada tipo necesita la célula (balanceo en la Fase 7).',
          style: const pw.TextStyle(fontSize: 8.5)),
    ],
  ));
  return doc.save();
}
