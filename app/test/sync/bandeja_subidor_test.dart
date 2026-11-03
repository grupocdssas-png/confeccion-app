import 'dart:io';

import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:confeccion/core/sync/subidor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

/// Simula el servidor: guarda los eventos por UUID (idempotente) igual que ingerir_eventos().
class ServidorSimulado {
  final recibidos = <String, Map<String, dynamic>>{};
  var sinRed = false;
  var llamadas = 0;
  final rechazar = <String>{}; // empleado_id que el servidor rechaza

  Future<Map<String, dynamic>> enviar(Map<String, dynamic> lote) async {
    llamadas++;
    if (sinRed) throw const SocketException('Sin conexión');
    final resultados = <Map<String, dynamic>>[];
    for (final e in (lote['eventos'] as List).cast<Map<String, dynamic>>()) {
      final id = e['id'] as String;
      if (rechazar.contains(e['datos']['empleado_id'])) {
        resultados.add({'id': id, 'estado': 'rechazado', 'motivo': 'Empleado inexistente o inactivo'});
      } else if (recibidos.containsKey(id)) {
        resultados.add({'id': id, 'estado': 'duplicado'});
      } else {
        recibidos[id] = e;
        resultados.add({'id': id, 'estado': 'aceptado'});
      }
    }
    return {'desfase_reloj_s': 0, 'resultados': resultados};
  }
}

void main() {
  late Directory dir;
  late PowerSyncDatabase db;
  late ServidorSimulado servidor;
  late Subidor subidor;
  var ahora = DateTime.utc(2026, 11, 3, 11, 0);

  Future<PowerSyncDatabase> abrir() async {
    final d = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await d.initialize();
    return d;
  }

  Future<String> marcar(String empleado, String tipo) async =>
      (await Bandeja(db, reloj: () => ahora).registrar(
        tabla: 'asistencia_marcas',
        datos: {'empleado_id': empleado, 'tipo': tipo},
        resumen: {'tipo': tipo},
        empleadoId: empleado,
      )).id;

  Future<Map<String, Object?>> enBandeja(String id) async => (await db.get('SELECT * FROM bandeja WHERE id = ?', [id]));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bandeja');
    db = await abrir();
    servidor = ServidorSimulado();
    subidor = Subidor(db: db, enviar: servidor.enviar, versionApp: 'prueba', reloj: () => ahora);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('sin conexión: los eventos quedan pendientes y en orden', () async {
    servidor.sinRed = true;
    final a = await marcar('emp-1', 'entrada');
    ahora = ahora.add(const Duration(minutes: 1));
    final b = await marcar('emp-2', 'entrada');

    await expectLater(subidor.subirTodo(), throwsA(isA<SocketException>()));
    expect((await enBandeja(a))['estado'], 'pendiente');
    expect((await enBandeja(b))['estado'], 'pendiente');
    final cola = await db.getCrudBatch();
    expect(cola!.crud.map((e) => e.id), [a, b]);
  });

  test('al volver la señal se envían y quedan sincronizados', () async {
    servidor.sinRed = true;
    final a = await marcar('emp-1', 'entrada');
    await expectLater(subidor.subirTodo(), throwsA(isA<SocketException>()));
    servidor.sinRed = false;
    expect(await subidor.subirTodo(), 1);
    expect((await enBandeja(a))['estado'], 'sincronizado');
    expect(servidor.recibidos.keys, [a]);
    expect(await db.getCrudBatch(), isNull, reason: 'la cola queda vacía');
  });

  test('los pendientes sobreviven al cierre y reapertura de la app', () async {
    servidor.sinRed = true;
    final a = await marcar('emp-1', 'entrada');
    await db.close();
    db = await abrir();
    subidor = Subidor(db: db, enviar: servidor.enviar, versionApp: 'prueba', reloj: () => ahora);
    expect((await enBandeja(a))['estado'], 'pendiente');
    servidor.sinRed = false;
    await subidor.subirTodo();
    expect((await enBandeja(a))['estado'], 'sincronizado');
  });

  test('respuesta perdida y reenvío: el servidor no duplica', () async {
    final a = await marcar('emp-1', 'entrada');
    // El servidor recibe el lote pero la respuesta no llega a la tablet:
    final lote = Subidor.construirLote((await db.getCrudBatch())!.crud, horaDispositivo: ahora);
    await servidor.enviar(lote);
    // La tablet reintenta el mismo lote
    await subidor.subirTodo();
    expect(servidor.recibidos.length, 1);
    expect((await enBandeja(a))['estado'], 'sincronizado');
  });

  test('evento rechazado queda visible con motivo y no bloquea la cola', () async {
    servidor.rechazar.add('emp-x');
    final a = await marcar('emp-x', 'entrada');
    final b = await marcar('emp-1', 'entrada');
    await subidor.subirTodo();
    final ra = await enBandeja(a);
    expect(ra['estado'], 'rechazado');
    expect(ra['motivo'], contains('inexistente'));
    expect((await enBandeja(b))['estado'], 'sincronizado');
  });

  test('resumen del indicador: pendientes y aviso de más de 8 horas', () async {
    servidor.sinRed = true;
    await marcar('emp-1', 'entrada');
    await marcar('emp-2', 'entrada');
    final r = await ResumenBandeja.observar(db).first;
    expect(r.pendientes, 2);
    expect(r.pendientesViejos(ahora.add(const Duration(hours: 9)), const Duration(hours: 8)), isTrue);
    expect(r.pendientesViejos(ahora.add(const Duration(hours: 2)), const Duration(hours: 8)), isFalse);
  });

  test('si alguien atrasa la hora de la tablet se detecta', () async {
    await marcar('emp-1', 'entrada');
    ahora = ahora.subtract(const Duration(hours: 2));
    final r = await Bandeja(db, reloj: () => ahora)
        .registrar(tabla: 'asistencia_marcas', datos: {'empleado_id': 'emp-1', 'tipo': 'salida'}, resumen: const {});
    expect(r.relojRetrocedio, isTrue);
  });

  test('las tablas de eventos no se pueden leer ni editar localmente: solo agregar', () async {
    await marcar('emp-1', 'entrada');
    expect(await db.getAll('SELECT * FROM asistencia_marcas'), isEmpty);
  });
}
