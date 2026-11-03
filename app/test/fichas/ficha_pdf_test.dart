import 'dart:convert';

import 'package:confeccion/features/fichas/ficha_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Ficha mínima con la forma que devuelve fichaProvider.
Map<String, dynamic> fichaDePrueba() => {
      'id': 'f1', 'version': 2, 'estado': 'aprobada', 'descripcion': 'Camiseta básica', 'composicion': '100% algodón',
      'instrucciones_lavado': 'Agua fría', 'precio_objetivo': 38000, 'sam_total': 6.53, 'costo_estandar': 12192.89,
      'referencias': {'codigo': 'CAM-001', 'nombre': 'Camiseta básica (EJEMPLO)', 'familias_producto': {'nombre': 'Camisetas'}, 'tipos_producto': null},
      'curvas': {'nombre': 'S-XL 1-2-2-1'},
      'ficha_tallas': [
        {'talla_id': 's', 'orden': 2, 'tallas': {'codigo': 'S', 'orden': 2}},
        {'talla_id': 'm', 'orden': 3, 'tallas': {'codigo': 'M', 'orden': 3}},
      ],
      'ficha_partes': [{'id': 'p1', 'nombre': 'Cuerpo', 'orden': 1, 'puede_cortarse_retazo': false}],
      'ficha_combinaciones': [
        {'id': 'c1', 'codigo': 'N', 'nombre': 'Negro', 'orden': 1, 'ficha_combinacion_partes': [{'parte_id': 'p1', 'color_id': 'negro'}]},
      ],
      'ficha_medidas': [
        {'punto_medida': 'Pecho', 'orden': 1, 'ficha_medida_tallas': [{'talla_id': 's', 'valor_cm': 48, 'tolerancia_cm': 1}, {'talla_id': 'm', 'valor_cm': 51, 'tolerancia_cm': 1}]},
      ],
      'ficha_bom': [
        {'orden': 1, 'parte_id': 'p1', 'combinacion_id': null, 'merma_pct': 4, 'materiales': {'nombre': 'Jersey', 'unidad': 'kg'},
         'ficha_bom_consumos': [{'talla_id': 's', 'consumo': 0.172}, {'talla_id': 'm', 'consumo': 0.185}]},
      ],
      'ficha_artes': [],
      'ficha_ruta': [{'proceso': 'corte', 'orden': 1, 'modalidad': 'interno'}, {'proceso': 'confeccion', 'orden': 2, 'modalidad': 'interno'}],
      'ficha_operaciones': [
        {'secuencia': 10, 'proceso': 'confeccion', 'parte_id': 'p1', 'sam': 0.35, 'repeticiones': 2, 'valor_destajo': 70, 'es_contadora': true,
         'operaciones': {'codigo': 'CAM-010', 'nombre': 'Unir hombros'}, 'tipos_maquina': {'codigo': 'FIL'}},
      ],
      'ficha_costo_estandar': [
        {'combinacion_id': 'c1', 'concepto': 'materiales', 'valor': 9164.49}, {'combinacion_id': 'c1', 'concepto': 'total', 'valor': 12192.89},
      ],
      'ficha_aprobaciones': [{'fecha': '2026-11-03T11:00:00Z', 'area': 'costos', 'decision': 'aprobada', 'perfiles': {'nombre': 'Costos'}}],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es_CO'));

  test('genera el PDF A4 de la ficha con todas las secciones', () async {
    registrarColoresPdf([{'id': 'negro', 'nombre': 'Negro'}]);
    final bytes = await generarFichaPdf(fichaDePrueba(), conImagenes: false);
    final texto = latin1.decode(bytes);
    expect(texto, startsWith('%PDF'));
    final caja = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)').firstMatch(texto)!;
    expect(double.parse(caja.group(1)!), closeTo(595.28, 0.1), reason: 'A4 de ancho');
    expect(bytes.length, greaterThan(5000));
  });
}
