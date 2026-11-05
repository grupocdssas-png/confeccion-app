import 'dart:convert';

import 'package:confeccion/features/externos/remision_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es_CO'));

  test('remisión de salida y devolución en PDF', () async {
    final r = {'consecutivo': 'REM-000002', 'tipo': 'salida', 'fecha': '2026-11-05', 'fecha_compromiso': '2026-11-08', 'proceso': 'estampacion',
               'satelites': {'nombre': 'Estampados Ejemplo (EJEMPLO)', 'nit': '900000004-4'}, 'procesos': {'nombre': 'Estampación'}};
    final u = [
      {'codigo': 'JG-000009', 'op': 'OP-000001', 'referencia': 'CAM-001', 'color': 'Gris jaspe', 'talla': 'L', 'cantidad': 20},
    ];
    for (final doc in [r, {...r, 'tipo': 'entrada', 'consecutivo': 'DEV-000002'}]) {
      final bytes = await remisionPdf(doc, [for (final x in u) {...x, 'buenas': 19, 'segundas': 1, 'faltantes': 0}],
          [{'material': 'Marquilla (EJEMPLO)', 'op': 'OP-000001', 'cantidad': 4, 'unidad': 'und'}]);
      expect(latin1.decode(bytes), startsWith('%PDF'));
    }
  });
}
