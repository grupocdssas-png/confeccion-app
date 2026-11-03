import 'package:confeccion/core/formato/formato.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es_CO'));

  test('números con formato colombiano', () {
    expect(Formato.dos(1234.56), '1.234,56');
    expect(Formato.numero(1234567, decimales: 0), '1.234.567');
    expect(Formato.numero(12.5, decimales: 3), '12,500');
    expect(Formato.porcentaje(87.25), '87,3 %');
  });

  test('pesos colombianos sin decimales', () {
    expect(Formato.cop(1750905).replaceAll(' ', ' '), r'$ 1.750.905');
  });

  test('hora de Bogotá independiente de la zona del dispositivo', () {
    final t = DateTime.utc(2026, 11, 3, 13, 5, 9); // 08:05:09 en Bogotá
    expect(Formato.hora(t), '08:05');
    expect(Formato.horaSeg(t), '08:05:09');
    expect(Formato.fecha(DateTime.utc(2026, 11, 3, 3)), '02/11/2026'); // 22:00 del día anterior
  });

  test('inicio del día en Bogotá', () {
    final ahora = DateTime.utc(2026, 11, 3, 3); // 2 nov 22:00 Bogotá
    expect(Formato.inicioDiaBogota(ahora), DateTime.utc(2026, 11, 2, 5));
  });

  test('mm:ss', () {
    expect(Formato.mmss(const Duration(minutes: 3, seconds: 7)), '03:07');
  });
}
