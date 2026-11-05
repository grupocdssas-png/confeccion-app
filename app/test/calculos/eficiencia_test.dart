import 'package:confeccion/core/calculos/eficiencia.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('minutos esperados con repeticiones y reproceso', () {
    expect(minutosEsperados(sam: 0.35, repeticiones: 2, unidades: 1), 0.7);
    expect(minutosEsperados(sam: 0.35, samReproceso: 0.2, repeticiones: 2, unidades: 3, reproceso: true), 1.2);
    expect(minutosEsperados(sam: 0.35, repeticiones: 2, unidades: 1, reproceso: true), 0.7, reason: 'sin SAM de reproceso usa el normal');
  });

  test('minutos reales: misma regla que el servidor', () {
    final t0 = DateTime.utc(2026, 11, 5, 14, 0); // 9:00 en Bogotá
    expect(minutosReales(null, t0), isNull, reason: 'primera del día');
    expect(minutosReales(t0, t0.add(const Duration(seconds: 42))), 0.7);
    expect(minutosReales(t0, t0.add(const Duration(minutes: 31))), isNull, reason: 'pausa de más de 30 min');
    expect(minutosReales(t0, t0.add(const Duration(minutes: 45)), maxMinutos: 60), 45);
    // 23:59 y 00:01 en Bogotá son días distintos
    expect(minutosReales(DateTime.utc(2026, 11, 6, 4, 59), DateTime.utc(2026, 11, 6, 5, 1)), isNull);
  });

  test('eficiencia por marcación y de un grupo', () {
    expect(eficiencia(0.7, 0.65), 107.69);
    expect(eficiencia(0.7, null), isNull);
    final h = DateTime.utc(2026, 11, 5, 14);
    expect(eficienciaDe([
      MarcacionResumen(hora: h, esperados: 0.7),
      MarcacionResumen(hora: h, esperados: 0.7, reales: 0.7),
      MarcacionResumen(hora: h, esperados: 0.7, reales: 0.5),
    ]), 116.7);
    expect(eficienciaDe(const []), isNull);
  });
}
