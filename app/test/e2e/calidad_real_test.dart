// Tablet de calidad de punta a punta contra Supabase + PowerSync locales (docker).
// Requiere haber corrido herramientas/preparar_planta_ejemplo.sql.
// Se ejecuta solo con:  E2E=1 flutter test test/e2e
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/conector.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:confeccion/features/calidad/repositorio_calidad.dart';
import 'package:confeccion/features/modulo/repositorio_modulo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase/supabase.dart';

final _env = Platform.environment;
final _url = _env['SUPABASE_URL'] ?? 'http://127.0.0.1:54321';
final _anon = _env['SUPABASE_ANON_KEY'] ?? '';
final _service = _env['SUPABASE_SERVICE_ROLE_KEY'] ?? '';
final _ps = _env['POWERSYNC_URL'] ?? 'http://127.0.0.1:8080';
final _clave = _env['CLAVE_DEMO'] ?? 'Planta-2026';

Future<void> esperar(Future<bool> Function() c, {Duration max = const Duration(seconds: 40)}) async {
  final fin = DateTime.now().add(max);
  while (!await c()) {
    if (DateTime.now().isAfter(fin)) throw StateError('No se cumplió la condición a tiempo');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

void main() {
  final activo = _env['E2E'] == '1';

  test('calidad sin conexión: inspección con defecto → sube → la devolución baja → se recibe el arreglo', () async {
    final dir = await Directory.systemTemp.createTemp('e2e_calidad');
    final db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await db.initialize();
    final admin = SupabaseClient(_url, _service);
    final tablet = SupabaseClient(_url, _anon);
    final bandeja = Bandeja(db);
    final repo = RepositorioCalidad(db, bandeja);
    final modulo = RepositorioModulo(db, bandeja);
    try {
      await tablet.auth.signInWithPassword(email: 'tablet-cal@planta.local', password: _clave);
      await db.connect(connector: ConectorSupabase(db, cliente: tablet, endpoint: _ps));

      // 1. Bajan los defectos, el plan de muestreo, las medidas de la ficha y los juegos
      await esperar(() async => (await repo.defectos()).length >= 10 && (await modulo.unidadPorCodigo('JG-000009')) != null);
      final u = (await modulo.unidadPorCodigo('JG-000009'))!;
      expect((await repo.plan()).first.muestra, 1);
      expect(await repo.medidas(u.fichaId, await repo.tallaId(u.id)), hasLength(3));
      final op = (await repo.operacionesFicha(u.fichaId)).firstWhere((o) => o.proceso == 'confeccion');
      final psa = (await repo.defectos()).firstWhere((d) => d.codigo == 'PSA');
      final inspectora = await admin.from('empleados').select('id').eq('codigo', 'E015').single();

      // 2. Sin conexión: inspección en proceso con una prenda mala
      await db.disconnect();
      final r = await repo.inspeccionar(unidad: u, tipo: 'en_proceso', inspectorId: inspectora['id'], muestraEnProceso: 5,
          lineas: [LineaDefecto(psa, operacion: op)]);
      expect(r.resultado, 'rechazado');

      // 3. Vuelve la señal: sube, el servidor atribuye y crea la devolución, y baja a la tablet
      await db.connect(connector: ConectorSupabase(db, cliente: tablet, endpoint: _ps));
      await esperar(() async => (await db.get("SELECT count(*) n FROM bandeja WHERE tabla = 'inspecciones' AND estado = 'sincronizado'"))['n'] == 1);
      final ins = await admin.from('inspecciones').select('resultado, tamano_muestra, defectuosas, consecutivo').eq('id', r.id).single();
      expect(ins['resultado'], 'rechazado');
      expect(ins['tamano_muestra'], 5);
      expect(ins['defectuosas'], 1);
      await esperar(() async => (await repo.devoluciones(u.id)).isNotEmpty);
      final d = (await repo.devoluciones(u.id)).single;
      expect(d.defecto, 'Puntada saltada');

      // 4. El inspector recibe el arreglo
      await repo.cerrarDevolucion(d, reprocesadas: 1, segundas: 0, inspectorId: inspectora['id']);
      await esperar(() async => (await db.get("SELECT count(*) n FROM bandeja WHERE tabla = 'devolucion_cierres' AND estado = 'sincronizado'"))['n'] == 1);
      final s = await admin.from('devoluciones_calidad').select('estado, reprocesadas').eq('id', d.id).single();
      expect(s, {'estado': 'reprocesada', 'reprocesadas': 1});
      // y deja de bajar (ya no está abierta)
      await esperar(() async => (await db.getAll('SELECT id FROM devoluciones_calidad WHERE id = ?', [d.id])).isEmpty);
    } finally {
      await db.disconnectAndClear();
      await db.close();
      await tablet.dispose();
      await admin.dispose();
      await dir.delete(recursive: true);
    }
  }, skip: activo ? false : 'Solo con E2E=1 (Supabase y PowerSync locales)', timeout: const Timeout(Duration(minutes: 3)));
}
