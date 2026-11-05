import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/calculos/calidad.dart';
import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:confeccion/features/calidad/repositorio_calidad.dart';
import 'package:confeccion/features/modulo/repositorio_modulo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

/// La tablet de calidad sobre la base local real (SQLite de PowerSync), sin servidor.
void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late RepositorioCalidad repo;
  late RepositorioModulo modulo;
  var ahora = DateTime.utc(2026, 11, 5, 14, 0);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calidad');
    db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await db.initialize();
    final bandeja = Bandeja(db, reloj: () => ahora);
    repo = RepositorioCalidad(db, bandeja);
    modulo = RepositorioModulo(db, bandeja, reloj: () => ahora);
    await db.execute("INSERT INTO referencias (id, codigo, nombre) VALUES ('r', 'CAM-001', 'Camiseta')");
    await db.execute("INSERT INTO ordenes_produccion (id, consecutivo, referencia_id, ficha_version_id, estado, proceso_actual, cantidad_total) "
        "VALUES ('op', 'OP-000001', 'r', 'f', 'en_proceso', 'calidad', 180)");
    await db.execute("INSERT INTO tallas (id, codigo, orden) VALUES ('m', 'M', 2)");
    await db.execute("INSERT INTO juegos (id, codigo, op_id, talla_id, cantidad, cantidad_actual, estado, proceso_actual) "
        "VALUES ('j1', 'JG-000007', 'op', 'm', 10, 9, 'en_proceso', 'calidad')");
    await db.execute("INSERT INTO operaciones (id, codigo, nombre) VALUES ('o1', 'CAM-010', 'Unir hombros')");
    await db.execute("INSERT INTO ficha_operaciones (id, ficha_id, secuencia, operacion_id, proceso, sam, repeticiones) VALUES "
        "('fo1', 'f', 10, 'o1', 'confeccion', 0.35, 1)");
    await db.execute("INSERT INTO defectos (id, codigo, nombre, severidad) VALUES ('psa', 'PSA', 'Puntada saltada', 'mayor'), ('med', 'MED', 'Medida fuera de tolerancia', 'mayor')");
    await db.execute("INSERT INTO ficha_medidas (id, ficha_id, punto_medida, orden) VALUES ('pecho', 'f', 'Contorno de pecho (1/2)', 1)");
    await db.execute("INSERT INTO ficha_medida_tallas (id, medida_id, talla_id, valor_cm, tolerancia_cm) VALUES ('pecho_m', 'pecho', 'm', 51, 1)");
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('el plan que trae la app es el de los casos de prueba del servidor', () {
    final v = jsonDecode(File('../test_vectores/calidad/01_aql_2_5_nivel_II.json').readAsStringSync()) as Map<String, dynamic>;
    final plan = [for (final t in (v['plan'] as List).cast<Map<String, dynamic>>()) TramoMuestreo.fromJson(t)];
    expect(planPorDefecto.length, plan.length);
    for (var i = 0; i < plan.length; i++) {
      expect([planPorDefecto[i].desde, planPorDefecto[i].hasta, planPorDefecto[i].muestra, planPorDefecto[i].acepta],
          [plan[i].desde, plan[i].hasta, plan[i].muestra, plan[i].acepta]);
    }
  });

  test('auditoría sin conexión: rechazada, luego aprobada; la última manda', () async {
    final u = (await modulo.unidadPorId('j1'))!;
    final ops = await repo.operacionesFicha('f');
    final psa = (await repo.defectos()).firstWhere((d) => d.codigo == 'PSA');
    final r1 = await repo.inspeccionar(unidad: u, tipo: 'auditoria_final', inspectorId: 'e15', alcance: 'grupal',
        lineas: [LineaDefecto(psa, operacion: ops.first)]);
    expect((r1.muestra, r1.acepta, r1.resultado), (5, 0, 'rechazado'));
    expect((await repo.ultimaAuditoria('j1'))!.aprobada, isFalse);
    final subida = await db.get("SELECT data FROM ps_crud ORDER BY id DESC LIMIT 1");
    final datos = (jsonDecode(subida['data'] as String) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    expect(jsonDecode(datos['defectos'] as String), [{'defecto_id': 'psa', 'cantidad': 1, 'ficha_operacion_id': 'fo1'}]);

    ahora = ahora.add(const Duration(minutes: 20));
    final medidas = await repo.medidas('f', await repo.tallaId('j1'));
    final r2 = await repo.inspeccionar(unidad: u, tipo: 'auditoria_final', inspectorId: 'e15', lineas: [], medidas: {'pecho': 51.5}, fichaMedidas: medidas);
    expect(r2.resultado, 'aprobado');
    expect((await repo.ultimaAuditoria('j1'))!.aprobada, isTrue);
  });

  test('una medida fuera de tolerancia cuenta como prenda con defecto', () async {
    final u = (await modulo.unidadPorId('j1'))!;
    final medidas = await repo.medidas('f', 'm');
    final r = await repo.inspeccionar(unidad: u, tipo: 'auditoria_final', inspectorId: 'e15', lineas: [], medidas: {'pecho': 53}, fichaMedidas: medidas);
    expect((r.defectuosas, r.resultado), (1, 'rechazado'));
  });

  test('no más prendas con defecto que revisadas', () async {
    final u = (await modulo.unidadPorId('j1'))!;
    final psa = (await repo.defectos()).first;
    expect(() => repo.inspeccionar(unidad: u, tipo: 'auditoria_final', inspectorId: 'e15', lineas: [LineaDefecto(psa, cantidad: 6)]), throwsArgumentError);
  });

  test('devoluciones: el cierre en esta tablet la quita de la lista', () async {
    await db.execute("INSERT INTO devoluciones_calidad (id, inspeccion_id, op_id, juego_id, unidad_codigo, alcance, defecto_id, ficha_operacion_id, "
        "celula_id, cantidad, reprocesadas, estado) VALUES ('d1', 'i1', 'op', 'j1', 'JG-000007', 'individual', 'psa', 'fo1', 'mod1', 2, 0, 'abierta')");
    final ds = await repo.devoluciones('j1');
    expect(ds.single.defecto, 'Puntada saltada');
    expect(ds.single.operacion, 'Unir hombros');
    expect(await repo.devoluciones('j1', celulaId: 'mod2'), isEmpty, reason: 'solo las del módulo de la tablet');
    expect(() => repo.cerrarDevolucion(ds.single, reprocesadas: 1, segundas: 0), throwsArgumentError);
    await repo.cerrarDevolucion(ds.single, reprocesadas: 1, segundas: 1, inspectorId: 'e15');
    expect(await repo.devoluciones('j1'), isEmpty);
  });
}
