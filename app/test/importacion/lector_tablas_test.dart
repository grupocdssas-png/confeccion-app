import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:confeccion/core/importacion/lector_tablas.dart';
import 'package:flutter_test/flutter_test.dart';

/// Arma un .xlsx mínimo (como lo guarda Excel: textos compartidos y números).
Uint8List xlsxDePrueba() {
  final a = Archive();
  void add(String n, String c) => a.addFile(ArchiveFile.bytes(n, utf8.encode(c)));
  add('xl/workbook.xml', '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Operaciones" sheetId="1" r:id="rId1"/></sheets></workbook>');
  add('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>');
  add('xl/sharedStrings.xml', '<sst><si><t>Cód. Operación</t></si><si><t>Descripción</t></si><si><t>Tiempo estándar</t></si>'
      '<si><t>Máquina</t></si><si><t>CAM-010</t></si><si><t>Unir hombros</t></si><si><t>FIL</t></si><si><t>Pegar cuello</t></si></sst>');
  add('xl/worksheets/sheet1.xml', '<worksheet><sheetData>'
      '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>'
      '<row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c><c r="C2"><v>0.35000000000000003</v></c><c r="D2" t="s"><v>6</v></c></row>'
      '<row r="3"><c r="A3" t="inlineStr"><is><t>CAM-020</t></is></c><c r="B3" t="s"><v>7</v></c><c r="C3"><v>0.52</v></c></row>'
      '</sheetData></worksheet>');
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  test('lee un .xlsx: textos compartidos, en línea, números sin ruido y celdas vacías', () {
    final t = leerTabla(xlsxDePrueba(), 'SAMMU operaciones.xlsx');
    expect(t[0], ['Cód. Operación', 'Descripción', 'Tiempo estándar', 'Máquina']);
    expect(t[1], ['CAM-010', 'Unir hombros', '0.35', 'FIL']);
    expect(t[2], ['CAM-020', 'Pegar cuello', '0.52', '']);
  });

  test('lee CSV con punto y coma y coma decimal (Excel en español)', () {
    final b = Uint8List.fromList(latin1.encode('Código;Operación;SAM;Valor\r\nCAM-010;Unir hombros;0,35;1.250\r\n'));
    final tl = leerTablaArchivo(b, 'ops.csv');
    final t = tl.filas;
    expect(t[1], ['CAM-010', 'Unir hombros', '0,35', '1.250']);
    expect(tl.decimalComa, isTrue);
    final m = autoMapear('operaciones', t[0]);
    final filas = construirFilas('operaciones', t.sublist(1), m, decimalComa: tl.decimalComa);
    expect(filas.first['sam'], '0.35');
    expect(filas.first['valor_destajo'], '1250');
  });

  test('CSV UTF-8 con BOM y comas', () {
    final b = Uint8List.fromList(utf8.encode('﻿codigo,nombre,sam\nE1,"Pegar, cuello",0.5\n'));
    expect(leerTabla(b, 'x.csv')[1], ['E1', 'Pegar, cuello', '0.5']);
  });

  test('reconoce columnas de SAMMU por nombre, sin importar tildes ni mayúsculas', () {
    final m = autoMapear('operaciones', ['Cód. Operación', 'Descripción', 'Tiempo estándar', 'Máquina', 'Tarifa']);
    expect(m['codigo'], 0);
    expect(m['nombre'], 1);
    expect(m['sam'], 2);
    expect(m['maquina'], 3);
    expect(m['valor_destajo'], 4);
    expect(m['familia'], isNull);
  });

  test('números de .xlsx no se confunden con miles', () {
    expect(numeroNormalizado('1.125'), '1.125');
    expect(numeroNormalizado('1,234.5'), '1234.5');
    expect(numeroNormalizado('0,35'), '0.35');
    expect(numeroNormalizado('1.234,5', decimalComa: true), '1234.5');
    expect(numeroNormalizado('abc'), isNull);
  });

  test('formato no soportado', () {
    expect(() => leerTabla(Uint8List(0), 'datos.xls'), throwsFormatException);
  });

  group('Archivo real de SAMMU (POLO_ECONOMICA001.csv: ";" con punto decimal, Windows-1252)', () {
    final bytes = File('test/importacion/archivos/POLO_ECONOMICA001.csv').readAsBytesSync();
    final t = leerTablaArchivo(bytes, 'POLO_ECONOMICA001.csv');

    test('lee las 34 operaciones y detecta el punto decimal', () {
      expect(t.filas.length, 35);
      expect(t.decimalComa, isFalse, reason: 'aunque separa con ";", los SAM vienen como 0.33');
      expect(t.filas[0][6], 'Operación contadora');
      expect(t.filas[16][1], 'MONTAR PUÑO');
    });

    test('reconoce todas sus columnas para importar la secuencia', () {
      final m = autoMapear('secuencia', t.filas.first);
      for (final c in ['secuencia', 'nombre', 'maquina', 'sam', 'proceso', 'repeticiones', 'contadora', 'revision', 'sam_reproceso',
                       'sin_talla_color', 'cambiar_unidades', 'unidades_marcacion', 'valor_destajo']) {
        expect(m[c], isNotNull, reason: c);
      }
      expect(m['maquina'], 2, reason: '"Sitio de trabajo" es la máquina');
    });

    test('los SAM quedan en minutos (0.33, no 33) y el SAM total es 14,0596', () {
      final filas = construirFilas('secuencia', t.filas.sublist(1), autoMapear('secuencia', t.filas.first), decimalComa: t.decimalComa);
      expect(filas.first['sam'], '0.33');
      expect(filas[32]['sam'], '0.0208');
      expect(filas[31]['unidades_marcacion'], '12');
      final total = filas.fold<double>(0, (a, f) => a + double.parse(f['sam']!) * double.parse(f['repeticiones']!));
      expect(total, closeTo(14.0596, 1e-9));
    });

    test('detección de decimales', () {
      expect(detectarDecimalComa([['x'], ['0,35'], ['1,5']]), isTrue);
      expect(detectarDecimalComa([['x'], ['0.085'], ['0.33']]), isFalse);
      expect(detectarDecimalComa([['x'], ['1.250']]), isNull, reason: 'ambiguo');
    });
  });
}
