import 'dart:convert';

import 'package:confeccion/features/produccion/op_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es_CO'));

  test('hoja de secuencia y de máquinas: 2 páginas A4', () async {
    final op = {
      'consecutivo': 'OP-000001', 'cantidad_total': 180, 'fecha_entrega_plan': '2026-11-23',
      'referencias': {'codigo': 'CAM-001', 'nombre': 'Camiseta'}, 'ficha_versiones': {'version': 1},
    };
    final ops = [
      {'secuencia': 10, 'proceso': 'confeccion', 'sam': 0.35, 'repeticiones': 2, 'agrega_minutos_sam': true, 'es_contadora': false,
       'operaciones': {'codigo': 'CAM-010', 'nombre': 'Unir hombros'}, 'tipos_maquina': {'codigo': 'FIL', 'nombre': 'Fileteadora'}},
      {'secuencia': 20, 'proceso': 'confeccion', 'sam': 0.42, 'repeticiones': 1, 'agrega_minutos_sam': true, 'es_contadora': true,
       'operaciones': {'codigo': 'CAM-080', 'nombre': 'Dobladillo ruedo'}, 'tipos_maquina': {'codigo': 'REC', 'nombre': 'Recubridora'}},
    ];
    final bytes = await hojasOpPdf(op, ops, {'N': {'S': 20, 'M': 40}}, ['S', 'M']);
    final texto = latin1.decode(bytes);
    expect(texto, startsWith('%PDF'));
    expect(RegExp(r'/Type\s*/Page\b').allMatches(texto).length, 2);
  });
}
