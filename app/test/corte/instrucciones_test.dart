import 'dart:convert';

import 'package:confeccion/features/corte/datos_corte.dart';
import 'package:confeccion/features/corte/impresion_corte.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es_CO'));

  final k = ContextoCorte({
    'corte': {'id': 'c', 'consecutivo': 'CRT-000001', 'tipo': 'combinada', 'estado': 'borrador', 'despunte_cm': 2, 'estaciones': {'codigo': 'C01'}},
    'op': {'consecutivo': 'OP-000001', 'referencias': {'codigo': 'CAM-001', 'nombre': 'Camiseta'}, 'op_cantidades': [
      {'combinacion_id': 'n', 'talla_id': 's', 'cantidad': 10}, {'combinacion_id': 'n', 'talla_id': 'm', 'cantidad': 20}]},
    'partes': [{'id': 'p1', 'nombre': 'Cuerpo', 'orden': 1}],
    'tallas': [{'id': 's', 'codigo': 'S', 'orden': 1}, {'id': 'm', 'codigo': 'M', 'orden': 2}],
    'combinaciones': [{'id': 'n', 'codigo': 'N', 'nombre': 'Negro', 'orden': 1, 'ficha_combinacion_partes': [{'parte_id': 'p1', 'material_id': 'j', 'color_id': 'neg'}]}],
    'bom': [{'material_id': 'j', 'parte_id': 'p1', 'combinacion_id': null, 'merma_pct': 4, 'ficha_bom_consumos': [{'talla_id': 's', 'consumo': 0.2}, {'talla_id': 'm', 'consumo': 0.25}]}],
    'materiales': {'j': {'id': 'j', 'nombre': 'Jersey', 'unidad': 'kg', 'tipo': 'tela', 'rendimiento_m_kg': 3.45}},
    'colores': {'neg': {'id': 'neg', 'nombre': 'Negro', 'hex': '#1A1A1A'}},
    'rollos': {'r1': {'id': 'r1', 'codigo': 'TL-000001', 'material_id': 'j', 'color_id': 'neg', 'lote_tintura': 'L1', 'tono': 'A', 'ancho_real_cm': 180,
                      'metros_saldo': 77.28, 'kilos_saldo': 22.4}},
    'mesas': [], 'cortadores': [], 'trazos': [], 'cortado_antes': [], 'parametros': {},
  });

  test('pendiente, consumo estándar y tendidos por defecto salen de la ficha', () {
    final b = k.bloquesPorDefecto().single;
    expect(b.partes, ['p1']);
    expect(k.pendiente(b, 'neg'), {'s': 10, 'm': 20});
    expect(k.consumoPorTalla(b)['m'], closeTo(0.26, 1e-9));
    expect(k.kilos('r1', 7.728), closeTo(2.24, 1e-9));
  });

  test('instrucciones de mesa en PDF A4', () async {
    final doc = DocumentoCorte.desdeJson({
      'bloques': [
        {'id': 'b1', 'nombre': 'Cuerpo', 'material_id': 'j', 'partes': ['p1'], 'tallas': ['s', 'm'],
         'secciones': [{'letra': 'A', 'largo_m': 1.5, 'unidades': {'s': 1, 'm': 2}}], 'tramos': [{'rollo_id': 'r1', 'color_id': 'neg', 'espiga': 1, 'capas': 10}]},
      ],
      'rollos': {'r1': {'fin': 'retazo'}},
    });
    expect(jsonEncode(doc.aJson()['rollos']), '{"r1":{"fin":"retazo"}}');
    final bytes = await instruccionesCortePdf(k, doc);
    expect(latin1.decode(bytes), startsWith('%PDF'));
  });
}
