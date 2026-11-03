// Prueba de punta a punta contra Supabase + PowerSync locales (docker).
// Se ejecuta solo con:  E2E=1 flutter test test/e2e   (ver README, sección "Pruebas").
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/conector.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase/supabase.dart';

final _env = Platform.environment;
final _url = _env['SUPABASE_URL'] ?? 'http://127.0.0.1:54321';
final _anon = _env['SUPABASE_ANON_KEY'] ?? '';
final _service = _env['SUPABASE_SERVICE_ROLE_KEY'] ?? '';
final _ps = _env['POWERSYNC_URL'] ?? 'http://127.0.0.1:8080';
final _clave = _env['CLAVE_DEMO'] ?? 'Planta-2026';

Future<void> esperar(Future<bool> Function() condicion, {Duration max = const Duration(seconds: 30)}) async {
  final fin = DateTime.now().add(max);
  while (!await condicion()) {
    if (DateTime.now().isAfter(fin)) throw TimeoutException('No se cumplió la condición');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

class TimeoutException implements Exception {
  TimeoutException(this.m);
  final String m;
  @override
  String toString() => m;
}

void main() {
  final activo = _env['E2E'] == '1';

  test('tablet sin conexión → registra → conecta → descarga su estación → sube sin duplicar', () async {
    final dir = await Directory.systemTemp.createTemp('e2e');
    final db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await db.initialize();
    final admin = SupabaseClient(_url, _service);
    final tablet = SupabaseClient(_url, _anon);
    try {
      await tablet.auth.signInWithPassword(email: 'tablet-ent@planta.local', password: _clave);
      final ana = await admin.from('empleados').select('id').eq('codigo', 'E001').single();
      final antes = await admin.from('asistencia_marcas').select('id');

      // 1. Sin conexión: se registran dos marcas (solo quedan en la tablet)
      final bandeja = Bandeja(db);
      final a = await bandeja.registrar(
          tabla: 'asistencia_marcas', datos: {'empleado_id': ana['id'], 'tipo': 'entrada'}, resumen: {'tipo': 'entrada'}, empleadoId: ana['id']);
      final b = await bandeja.registrar(
          tabla: 'asistencia_marcas', datos: {'empleado_id': ana['id'], 'tipo': 'salida'}, resumen: {'tipo': 'salida'}, empleadoId: ana['id']);
      expect((await db.get("SELECT count(*) n FROM bandeja WHERE estado = 'pendiente'"))['n'], 2);

      // 2. Vuelve la señal
      await db.connect(connector: ConectorSupabase(db, cliente: tablet, endpoint: _ps));

      // 3. Descarga: su estación (ENT) y los 14 empleados
      await esperar(() async => (await db.getOptional('SELECT codigo FROM estaciones'))?['codigo'] == 'ENT');
      expect((await db.get('SELECT count(*) n FROM empleados'))['n'], greaterThanOrEqualTo(14));
      expect((await db.getAll('SELECT * FROM dispositivos')).length, 1, reason: 'solo baja su propio dispositivo');

      // 4. Subida: ambas quedan sincronizadas y existen una sola vez en el servidor
      await esperar(() async => (await db.get("SELECT count(*) n FROM bandeja WHERE estado = 'sincronizado'"))['n'] == 2);
      final servidor = await admin.from('asistencia_marcas').select('id, estacion_id').inFilter('id', [a.id, b.id]);
      expect(servidor.length, 2);
      final despues = await admin.from('asistencia_marcas').select('id');
      expect(despues.length, antes.length + 2);
      final disp = await admin.from('dispositivos').select('ultima_sync').eq('nombre', 'Tablet entrada').single();
      expect(disp['ultima_sync'], isNotNull);
    } finally {
      await db.disconnectAndClear();
      await db.close();
      await tablet.dispose();
      await admin.dispose();
      await dir.delete(recursive: true);
    }
  }, skip: activo ? false : 'Pruebas e2e: ejecutar con E2E=1 y Supabase + PowerSync locales', timeout: const Timeout(Duration(minutes: 2)));
}
