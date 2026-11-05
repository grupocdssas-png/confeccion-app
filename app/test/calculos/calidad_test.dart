import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/calculos/calidad.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos se prueban en SQL (supabase/tests/95_calidad_fase9.sql).
void main() {
  final archivos = Directory('../test_vectores/calidad').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
  test('hay casos', () => expect(archivos, isNotEmpty));
  for (final f in archivos) {
    final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final plan = [for (final t in (v['plan'] as List).cast<Map<String, dynamic>>()) TramoMuestreo.fromJson(t)];
    for (final c in (v['casos'] as List).cast<Map<String, dynamic>>()) {
      test('${f.uri.pathSegments.last}: ${c['nombre']}', () {
        final m = muestreo(plan, c['lote']);
        expect(m.muestra, c['muestra']);
        expect(m.acepta, c['acepta']);
        expect(auditoriaAprobada(plan, c['lote'], c['defectuosas']) ? 'aprobado' : 'rechazado', c['resultado']);
      });
    }
  }

  test('lote vacío no se muestrea', () => expect(() => muestreo(const [TramoMuestreo(desde: 1, muestra: 1, acepta: 0)], 0), throwsArgumentError));

  test('medidas contra la ficha', () {
    expect(medidaFuera(52.0, 51.0, 1.0), isFalse, reason: 'justo en la tolerancia');
    expect(medidaFuera(52.5, 51.0, 1.0), isTrue);
    expect(medidaFuera(49.9, 51.0, 1.0), isTrue);
  });

  test('prendas con defecto', () {
    expect(prendasConDefecto([1, 2]), 3);
    expect(prendasConDefecto([1], medidaFueraDeTolerancia: true), 2);
    expect(prendasConDefecto([1], medidaFueraDeTolerancia: true, yaAnotoMedida: true), 1);
  });
}
