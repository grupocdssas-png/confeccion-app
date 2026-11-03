import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/config.dart';
import 'subidor.dart';

/// Conecta PowerSync con Supabase:
///  * credenciales: el JWT de la sesión de Supabase de la cuenta técnica de la tablet,
///  * subida: la RPC idempotente `ingerir_eventos`.
class ConectorSupabase extends PowerSyncBackendConnector {
  ConectorSupabase(this._db, {SupabaseClient? cliente, String? endpoint})
      : _clienteFijo = cliente,
        _endpoint = endpoint ?? Config.powersyncUrl;

  final PowerSyncDatabase _db;
  final SupabaseClient? _clienteFijo;
  final String _endpoint;
  SupabaseClient get _cliente => _clienteFijo ?? Supabase.instance.client;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    var sesion = _cliente.auth.currentSession;
    if (sesion == null) return null;
    if (sesion.isExpired) {
      sesion = (await _cliente.auth.refreshSession()).session;
      if (sesion == null) return null;
    }
    return PowerSyncCredentials(endpoint: _endpoint, token: sesion.accessToken, userId: sesion.user.id);
  }

  @override
  void invalidateCredentials() {
    // Fuerza a pedir un token nuevo en el próximo intento.
    _cliente.auth.refreshSession().ignore();
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) => Subidor(
        db: _db,
        versionApp: Config.versionApp,
        enviar: (lote) async =>
            Map<String, dynamic>.from(await _cliente.rpc('ingerir_eventos', params: {'p_lote': lote}) as Map),
      ).subirTodo();
}
