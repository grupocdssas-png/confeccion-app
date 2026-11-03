import 'dart:convert';
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
}
