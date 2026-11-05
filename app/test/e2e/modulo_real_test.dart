// Tablet del módulo de punta a punta contra Supabase + PowerSync locales (docker).
// Requiere haber corrido herramientas/preparar_planta_ejemplo.sql (juegos esperando confección).
// Se ejecuta solo con:  E2E=1 flutter test test/e2e
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/conector.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
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

  test('módulo: descarga juegos → recibe → marca sin conexión → entrega → el servidor calcula la eficiencia', () async {
    final dir = await Directory.systemTemp.createTemp('e2e_modulo');
    final db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/planta.db');
    await db.initialize();
    final admin = SupabaseClient(_url, _service);
    final tablet = SupabaseClient(_url, _anon);
    var reloj = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
    final repo = RepositorioModulo(db, Bandeja(db, reloj: () => reloj), reloj: () => reloj);
    try {
      await tablet.auth.signInWithPassword(email: 'tablet-mod1@planta.local', password: _clave);
      await db.connect(connector: ConectorSupabase(db, cliente: tablet, endpoint: _ps));

      // 1. Bajan las OP activas, sus operaciones y los juegos que esperan confección
      await esperar(() async => (await db.getOptional("SELECT id FROM juegos WHERE codigo = 'JG-000007'")) != null);
      final juego = (await repo.unidadPorCodigo('JG-000007'))!;
      expect(juego.op, 'OP-000001');
      expect(juego.proceso, 'confeccion');
      final ops = await repo.operaciones(juego, 'confeccion');
      expect(ops, isNotEmpty);
      final empleado = await admin.from('empleados').select('id').eq('codigo', 'E002').single();

      // 2. Sin conexión: recibe, marca 3 veces la primera operación y entrega con una segunda
      await db.disconnect();
      await repo.recibir(juego, empleadoId: empleado['id']);
      for (var i = 0; i < 3; i++) {
        reloj = reloj.add(const Duration(seconds: 45));
        await repo.marcar(empleadoId: empleado['id'], unidad: (await repo.unidadPorId(juego.id))!, op: ops.first);
      }
      reloj = reloj.add(const Duration(minutes: 1));
      await repo.entregar((await repo.unidadPorId(juego.id))!, buenas: juego.cantidad - 1, segundas: 1, faltantes: 0, empleadoId: empleado['id']);
      expect((await db.get("SELECT count(*) n FROM bandeja WHERE estado = 'pendiente'"))['n'], 5);

      // 3. Vuelve la señal: sube todo una sola vez
      await db.connect(connector: ConectorSupabase(db, cliente: tablet, endpoint: _ps));
      await esperar(() async => (await db.get("SELECT count(*) n FROM bandeja WHERE estado = 'sincronizado'"))['n'] == 5);
      final ms = await admin.from('marcaciones').select('minutos_reales, eficiencia, estacion_id').eq('juego_id', juego.id).order('ocurrido_en_servidor', ascending: true);
      expect(ms.length, 3);
      expect(ms.first['minutos_reales'], isNull);
      expect((ms[1]['minutos_reales'] as num).toDouble(), closeTo(0.75, 0.01));
      final j = await admin.from('juegos').select('estado, proceso_actual, cantidad_actual').eq('id', juego.id).single();
      expect(j, {'estado': 'en_espera', 'proceso_actual': 'terminacion', 'cantidad_actual': juego.cantidad - 1});

      // 4. Baja la eficiencia del día calculada por el servidor
      await esperar(() async => (await db.getOptional('SELECT unidades FROM eficiencia_diaria WHERE empleado_id = ?', [empleado['id']]))?['unidades'] == 3);
    } finally {
      await db.disconnectAndClear();
      await db.close();
      await tablet.dispose();
      await admin.dispose();
      await dir.delete(recursive: true);
    }
  }, skip: activo ? false : 'Solo con E2E=1 (Supabase y PowerSync locales)', timeout: const Timeout(Duration(minutes: 3)));
}
