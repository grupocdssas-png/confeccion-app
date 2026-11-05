import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:confeccion/features/modulo/repositorio_modulo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

/// La tablet del módulo sobre la base local real (SQLite de PowerSync), sin servidor.
void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late RepositorioModulo repo;
  var ahora = DateTime.utc(2026, 11, 5, 14, 0); // 9:00 en Bogotá

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('modulo');
    db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await db.initialize();
    repo = RepositorioModulo(db, Bandeja(db, reloj: () => ahora), reloj: () => ahora);
    // datos que bajarían del servidor
    await db.execute("INSERT INTO parametros (id, valor) VALUES ('unidades_por_marcacion', '1'), ('max_minutos_entre_marcaciones', '30')");
    await db.execute("INSERT INTO referencias (id, codigo, nombre) VALUES ('r', 'CAM-001', 'Camiseta')");
    await db.execute("INSERT INTO ordenes_produccion (id, consecutivo, referencia_id, ficha_version_id, estado, proceso_actual, cantidad_total) "
        "VALUES ('op', 'OP-000001', 'r', 'f', 'en_proceso', 'confeccion', 180)");
    await db.execute("INSERT INTO colores (id, codigo, nombre, hex) VALUES ('gj', 'GJ', 'Gris jaspe', '#A7A9AC')");
    await db.execute("INSERT INTO tallas (id, codigo, orden) VALUES ('s', 'S', 1)");
    await db.execute("INSERT INTO ficha_combinaciones (id, ficha_id, codigo, nombre) VALUES ('c', 'f', 'GJ', 'Gris con cuello negro')");
    await db.execute("INSERT INTO juegos (id, codigo, op_id, combinacion_id, color_id, talla_id, cantidad, cantidad_actual, estado, proceso_actual) "
        "VALUES ('j1', 'JG-000007', 'op', 'c', 'gj', 's', 10, 10, 'en_espera', 'confeccion')");
    await db.execute("INSERT INTO operaciones (id, codigo, nombre) VALUES ('o1', 'CAM-010', 'Unir hombros'), ('o2', 'CAM-020', 'Pegar cuello')");
    await db.execute("INSERT INTO ficha_operaciones (id, ficha_id, secuencia, operacion_id, proceso, sam, repeticiones, es_contadora) VALUES "
        "('fo1', 'f', 10, 'o1', 'confeccion', 0.35, 2, 0), ('fo2', 'f', 20, 'o2', 'confeccion', 0.52, 1, 1), ('fo3', 'f', 30, 'o1', 'terminacion', 0.4, 1, 0)");
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('busca el juego por lo escaneado y lo recibe sin conexión', () async {
    final u = (await repo.unidadPorCodigo(' jg-000007 '))!;
    expect(u.tipo, 'juego');
    expect(u.op, 'OP-000001');
    expect(u.combinacion, 'Gris con cuello negro');
    expect(u.enProcesoAqui('confeccion'), isFalse);
    expect(await repo.unidadPorCodigo('TL-000001'), isNull);

    await repo.recibir(u, empleadoId: 'e1');
    final r = (await repo.unidadPorId('j1'))!;
    expect(r.estadoLocal, 'recibida');
    expect(r.enProcesoAqui('confeccion'), isTrue);
    expect((await repo.unidadesEnCelula('cel', 'confeccion')).map((x) => x.codigo), ['JG-000007']);
    final cola = await db.getAll('SELECT * FROM ps_crud');
    expect(cola.where((c) => '${c['data']}'.contains('eventos_unidad')), hasLength(1), reason: 'queda en la cola de subida');
  });

  test('operaciones del proceso de la estación, marcación, eficiencia y anulación', () async {
    final u = (await repo.unidadPorId('j1'))!;
    final ops = await repo.operaciones(u, 'confeccion');
    expect(ops.map((o) => o.titulo), ['Unir hombros ×2', 'Pegar cuello']);
    expect(ops.last.contadora, isTrue);

    await repo.marcar(empleadoId: 'e1', unidad: u, op: ops.first);
    ahora = ahora.add(const Duration(seconds: 42));
    await repo.marcar(empleadoId: 'e1', unidad: u, op: ops.first);
    ahora = ahora.add(const Duration(seconds: 35));
    final idUltima = await repo.marcar(empleadoId: 'e1', unidad: u, op: ops.first);
    ahora = ahora.add(const Duration(seconds: 30));
    await repo.marcar(empleadoId: 'e1', unidad: u, op: ops.last, reproceso: true);

    final av = await repo.avance('j1');
    expect(av['fo1'], (hechas: 3, reprocesos: 0));
    expect(av['fo2'], (hechas: 0, reprocesos: 1));

    final ult = await repo.ultimas('e1');
    expect(ult.first.reproceso, isTrue);
    expect(ult[1].reales, closeTo(35 / 60, 0.001));
    expect(ult[1].eficiencia, 120.07, reason: '0,7 esperados / 0,583 min, igual que el servidor');
    expect(ult.last.reales, isNull, reason: 'la primera del día no se mide');

    final ef = await repo.eficiencias('e1');
    expect(ef.unidadesHoy, 3);
    expect(ef.reprocesosHoy, 1);
    expect(ef.hoy, isNotNull);

    final m = ult.firstWhere((x) => x.id == idUltima);
    await repo.anularMarcacion(m, 'e1', 'Toqué de más');
    expect((await repo.avance('j1'))['fo1']!.hechas, 2);
    final evento = (await db.getAll("SELECT resumen FROM bandeja WHERE tabla = 'marcaciones'")).last;
    expect(jsonDecode(evento['resumen'] as String)['tipo'], 'anulacion');
  });

  test('entrega: buenas + segundas + faltantes = lo que entró (regla 5)', () async {
    final u = (await repo.unidadPorId('j1'))!;
    await repo.recibir(u);
    ahora = ahora.add(const Duration(minutes: 20));
    expect(() => repo.entregar(u, buenas: 9, faltantes: 0), throwsArgumentError);
    await repo.entregar(u, buenas: 9, segundas: 1, faltantes: 0);
    final r = (await repo.unidadPorId('j1'))!;
    expect(r.estadoLocal, 'entregada');
    expect(r.enProcesoAqui('confeccion'), isFalse);
  });

  test('mes: días anteriores del servidor más lo de hoy en la tablet', () async {
    await db.execute("INSERT INTO eficiencia_diaria (id, empleado_id, fecha, unidades, reprocesos, minutos_esperados, minutos_reales) VALUES "
        "('e1_2026-11-03', 'e1', '2026-11-03', 100, 0, 90, 100), ('e1_2026-10-30', 'e1', '2026-10-30', 50, 0, 500, 100)");
    final ef = await repo.eficiencias('e1');
    expect(ef.mes, 90.0, reason: 'octubre no cuenta');
    expect(ef.hoy, isNull);
  });
}
