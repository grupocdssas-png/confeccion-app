import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/calculos/corte.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos se prueban en SQL (supabase/tests/50_corte_fase5.sql):
/// la app y el servidor siempre calculan lo mismo.
void main() {
  final dir = Directory('../test_vectores/corte');
  final archivos = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('hay casos compartidos', () => expect(archivos, isNotEmpty));

  for (final f in archivos) {
    final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    group(v['nombre'], () {
      final b = BloqueCorte.desdeJson(v['bloque'] as Map<String, dynamic>);
      final e = v['esperado'] as Map<String, dynamic>;
      final r = calcularBloque(b, despunteCm: (v['despunte_cm'] as num).toDouble());

      test('metros, capas y piezas', () {
        expect(r.metros, closeTo((e['metros'] as num).toDouble(), 1e-9));
        expect(r.capasEspiga, (e['capas_espiga'] as List).cast<int>());
        expect(r.capasSeccion, (e['capas_seccion'] as List).cast<int>());
        expect(jsonEncode(r.piezas), jsonEncode(e['piezas']));
        final mpr = (e['metros_por_rollo'] as Map).map((k, x) => MapEntry(k as String, (x as num).toDouble()));
        expect(r.metrosPorRollo.keys.toSet(), mpr.keys.toSet());
        mpr.forEach((k, x) => expect(r.metrosPorRollo[k], closeTo(x, 1e-9), reason: k));
      });

      test('paquetes', () {
        final p = planPaquetes(b, maxPrendas: v['max_paquete'] as int);
        expect([for (final x in p) x.aJson()], e['paquetes']);
        // regla: nunca más de una talla, color o lote por paquete (por construcción) y máximo 20
        for (final x in p) {
          expect(x.cantidad, lessThanOrEqualTo(20));
        }
        // los paquetes suman exactamente las piezas
        final suma = <String, int>{};
        for (final x in p) {
          suma['${x.colorId}/${x.talla}'] = (suma['${x.colorId}/${x.talla}'] ?? 0) + x.cantidad;
        }
        r.piezas.forEach((c, m) => m.forEach((t, n) => expect(suma['$c/$t'], n)));
      });
    });
  }

  group('sugerencias', () {
    test('capas para tendido normal', () {
      expect(sugerirCapasNormal({'S': 1, 'M': 2, 'L': 2, 'XL': 1}, {'S': 20, 'M': 40, 'L': 41, 'XL': 20}), 21);
      expect(sugerirCapasNormal({'S': 1}, {'S': 5, 'XL': 3}), isNull, reason: 'XL no está en el trazo');
    });

    test('espigas: cada sección queda con lo que necesita', () {
      const secciones = [
        SeccionTrazo(letra: 'A', largoM: 1.5, unidades: {'M': 2, 'L': 1}),
        SeccionTrazo(letra: 'B', largoM: 0.8, unidades: {'S': 1, 'L': 1}),
        SeccionTrazo(letra: 'C', largoM: 0.7, unidades: {'XL': 1}),
      ];
      final demanda = {'S': 16, 'M': 40, 'L': 36, 'XL': 10};
      expect(capasRequeridasPorSeccion(secciones, demanda), [20, 18, 10]);
      final c = sugerirEspigas(secciones, demanda);
      expect(c, [10, 8, 2]);
      final b = BloqueCorte(tallas: const ['S', 'M', 'L', 'XL'], secciones: secciones, tramos: [
        for (var k = 1; k <= 3; k++) TramoRollo(rolloId: 'r', colorId: 'N', espiga: k, capas: c[k - 1]),
      ]);
      final r = calcularBloque(b);
      expect(r.capasSeccion, [20, 18, 10]);
      demanda.forEach((t, n) => expect(r.piezas['N']![t], greaterThanOrEqualTo(n), reason: t));
    });

    test('ordenar secciones: la cabecera es la de más demanda', () {
      const secciones = [
        SeccionTrazo(letra: 'A', largoM: 0.7, unidades: {'XL': 1}),
        SeccionTrazo(letra: 'B', largoM: 1.5, unidades: {'M': 2}),
      ];
      final o = ordenarPorDemanda(secciones, {'XL': 10, 'M': 40});
      expect(o.map((s) => s.unidades.keys.first), ['M', 'XL']);
      expect(o.map((s) => s.letra), ['A', 'B']);
    });
  });

  test('repartir capas entre rollos sin pasar su saldo', () {
    final r = repartirCapas(
      rollos: const [(id: 'a', metros: 77.28), (id: 'b', metros: 75.21), (id: 'c', metros: 10)],
      capasPorEspiga: const [20, 3],
      metrosPorCapa: const [5.72, 3.0],
    );
    // a: 13 capas de 5,72 (74,36 m, le quedan 2,92); b: 7 capas y luego las 3 de la espiga 2
    expect(r.tramos, [(rolloId: 'a', espiga: 1, capas: 13), (rolloId: 'b', espiga: 1, capas: 7), (rolloId: 'b', espiga: 2, capas: 3)]);
    expect(r.sinRollo, 0);
    final corto = repartirCapas(rollos: const [(id: 'a', metros: 10)], capasPorEspiga: const [5], metrosPorCapa: const [3]);
    expect(corto.tramos.single.capas, 3);
    expect(corto.sinRollo, 2);
  });

  group('consumo', () {
    test('teórico, desviación y kilos', () {
      expect(consumoTeorico({'S': 10, 'M': 20}, {'S': 0.2, 'M': 0.25}), 7.0);
      expect(desviacion(7.35, 7.0), closeTo(0.05, 1e-9));
      expect(desviacion(1, 0), isNull);
      expect(kilosDeMetros(10, metrosSaldo: 77.28, kilosSaldo: 22.4), closeTo(2.899, 1e-9));
      expect(kilosDeMetros(10, metrosSaldo: 0, kilosSaldo: 0, rendimientoMKg: 3.45), closeTo(2.899, 1e-9));
    });

    test('pedido vs cortado', () {
      final c = compararPedidoCortado(['S', 'M', 'L'], {'S': 10, 'M': 20}, {'S': 8, 'M': 22, 'L': 1});
      expect(c.map((x) => x.diferencia), [-2, 2, 1]);
      expect(c.first.faltan, isTrue);
      expect(c[1].sobran, isTrue);
    });

    test('espiga inexistente es error', () {
      const b = BloqueCorte(tallas: ['M'], secciones: [SeccionTrazo(letra: 'A', largoM: 1, unidades: {'M': 1})], tramos: [
        TramoRollo(rolloId: 'r', colorId: 'N', espiga: 2, capas: 3),
      ]);
      expect(() => calcularBloque(b), throwsArgumentError);
    });
  });
}
