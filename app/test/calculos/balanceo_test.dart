import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/calculos/balanceo.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los mismos casos se prueban en SQL (supabase/tests/80_programacion_fase7.sql).
void main() {
  final archivos = Directory('../test_vectores/balanceo').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
  test('hay casos', () => expect(archivos, isNotEmpty));
  for (final f in archivos) {
    final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final ops = [
      for (final o in (v['operaciones'] as List).cast<Map<String, dynamic>>())
        OperacionBalanceo(id: o['id'], secuencia: o['secuencia'], sam: (o['sam'] as num).toDouble(), repeticiones: (o['repeticiones'] as num).toDouble(),
            tipoMaquina: o['maquina']),
    ];
    group(v['nombre'], () {
      final puestos = balancear(ops, v['operarios'] as int, tolerancia: (v['tolerancia'] as num).toDouble());
      test('reparto automático', () {
        expect(jsonDecode(jsonEncode([for (final p in puestos) p.aJson()])), v['esperado']['puestos']);
        // cada operación queda asignada completa
        for (final o in ops) {
          final f = puestos.expand((p) => p.asignaciones).where((a) => a.operacionId == o.id).fold(0.0, (a, x) => a + x.fraccion);
          expect(f, closeTo(1, 1e-9), reason: o.id);
        }
      });
      test('métricas', () {
        final total = ops.fold(0.0, (a, o) => a + o.minutos);
        final m = metricas(samTotal: total, operarios: v['operarios'], eficienciaPct: (v['eficiencia_pct'] as num).toDouble(),
            minutosTurno: (v['minutos_turno'] as num).toDouble(), cargas: [for (final p in puestos) p.carga], pendientes: v['pendientes']);
        expect(m.aJson(), v['esperado']['metricas']);
      });
    });
  }

  test('operación manual cabe en cualquier puesto y nunca más puestos que operarios', () {
    final p = balancear(const [
      OperacionBalanceo(id: 'a', secuencia: 1, sam: 1, tipoMaquina: 'PLA'),
      OperacionBalanceo(id: 'b', secuencia: 2, sam: 0.2, tipoMaquina: 'MAN'),
      OperacionBalanceo(id: 'c', secuencia: 3, sam: 1, tipoMaquina: 'FIL'),
      OperacionBalanceo(id: 'd', secuencia: 4, sam: 3, tipoMaquina: 'REC'),
    ], 2);
    expect(p.length, 2);
    expect(p.first.asignaciones.map((a) => a.operacionId), ['a', 'b', 'c']);
    expect(p.first.maquinas, {'PLA', 'FIL'});
  });
}
