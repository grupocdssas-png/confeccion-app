import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/config.dart';

class PermisoModulo {
  const PermisoModulo({
    required this.modulo, required this.nombre, required this.grupo, required this.ruta,
    required this.fase, this.icono, this.editar = false, this.aprobar = false,
  });
  final String modulo, nombre, grupo, ruta;
  final String? icono;
  final int fase;
  final bool editar, aprobar;

  factory PermisoModulo.fromJson(Map<String, dynamic> j) => PermisoModulo(
        modulo: j['modulo'], nombre: j['nombre'], grupo: j['grupo'], ruta: j['ruta'], icono: j['icono'],
        fase: (j['fase'] as num).toInt(), editar: j['editar'] == true, aprobar: j['aprobar'] == true,
      );
  Map<String, dynamic> toJson() => {
        'modulo': modulo, 'nombre': nombre, 'grupo': grupo, 'ruta': ruta, 'icono': icono,
        'fase': fase, 'editar': editar, 'aprobar': aprobar,
      };
}

/// Perfil, roles y permisos efectivos del usuario (RPC `mi_sesion`).
class SesionUsuario {
  const SesionUsuario({
    required this.usuarioId, required this.nombre, required this.esDispositivo,
    required this.roles, required this.permisos, this.empleadoId,
  });
  final String usuarioId, nombre;
  final bool esDispositivo;
  final String? empleadoId;
  final List<String> roles;
  final List<PermisoModulo> permisos;

  bool get esGerencia => roles.contains('gerencia');
  bool puedeVer(String modulo) => permisos.any((p) => p.modulo == modulo);
  bool puedeEditar(String modulo) => permisos.any((p) => p.modulo == modulo && p.editar);
  PermisoModulo? permisoPorRuta(String ruta) => permisos.where((p) => p.ruta == ruta).firstOrNull;

  factory SesionUsuario.fromJson(Map<String, dynamic> j) => SesionUsuario(
        usuarioId: j['usuario_id'], nombre: j['nombre'], esDispositivo: j['es_dispositivo'] == true,
        empleadoId: j['empleado_id'],
        roles: List<String>.from(j['roles'] ?? const []),
        permisos: [for (final p in (j['permisos'] as List? ?? const [])) PermisoModulo.fromJson(Map<String, dynamic>.from(p))],
      );
  Map<String, dynamic> toJson() => {
        'usuario_id': usuarioId, 'nombre': nombre, 'es_dispositivo': esDispositivo, 'empleado_id': empleadoId,
        'roles': roles, 'permisos': [for (final p in permisos) p.toJson()],
      };
}

class ErrorSesion implements Exception {
  ErrorSesion(this.mensaje);
  final String mensaje;
  @override
  String toString() => mensaje;
}

/// Carga la sesión desde el servidor; si no hay red, usa la última guardada
/// (así la tablet y el panel siguen funcionando sin internet).
class RepositorioSesion {
  RepositorioSesion(this._cliente, this._prefs);
  final SupabaseClient _cliente;
  final SharedPreferences _prefs;
  static const _clave = 'sesion_cache';

  Future<SesionUsuario?> cargar() async {
    final usuario = _cliente.auth.currentUser;
    if (usuario == null) return null;
    try {
      final r = await _cliente.rpc('mi_sesion');
      if (r == null) throw ErrorSesion('Su usuario no tiene un perfil activo. Consulte al administrador.');
      final sesion = SesionUsuario.fromJson(Map<String, dynamic>.from(r as Map));
      await _prefs.setString(_clave, jsonEncode(sesion.toJson()));
      return sesion;
    } on ErrorSesion {
      rethrow;
    } catch (_) {
      final guardada = _prefs.getString(_clave);
      if (guardada == null) rethrow;
      final sesion = SesionUsuario.fromJson(jsonDecode(guardada));
      return sesion.usuarioId == usuario.id ? sesion : null;
    }
  }

  Future<SesionUsuario> ingresar(String correo, String clave) async {
    try {
      await _cliente.auth.signInWithPassword(email: correo.trim(), password: clave);
    } on AuthException catch (e) {
      throw ErrorSesion(e.code == 'invalid_credentials' || e.message.contains('Invalid login')
          ? 'Correo o contraseña incorrectos.'
          : 'No se pudo ingresar: ${e.message}');
    } catch (_) {
      throw ErrorSesion('Sin conexión con el servidor. Revise el internet e intente de nuevo.');
    }
    final sesion = await cargar();
    if (sesion == null) {
      await salir();
      throw ErrorSesion('Su usuario no tiene un perfil activo. Consulte al administrador.');
    }
    return sesion;
  }

  Future<void> salir() async {
    await _prefs.remove(_clave);
    await _cliente.auth.signOut();
  }
}

final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('Inicializar en main'));
final repositorioSesionProvider =
    Provider((ref) => RepositorioSesion(Supabase.instance.client, ref.watch(prefsProvider)));

class SesionNotifier extends AsyncNotifier<SesionUsuario?> {
  @override
  Future<SesionUsuario?> build() async => Config.completa ? ref.read(repositorioSesionProvider).cargar() : null;

  Future<void> ingresar(String correo, String clave) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => ref.read(repositorioSesionProvider).ingresar(correo, clave));
  }

  Future<void> salir() async {
    await ref.read(repositorioSesionProvider).salir();
    state = const AsyncData(null);
  }
}

final sesionProvider = AsyncNotifierProvider<SesionNotifier, SesionUsuario?>(SesionNotifier.new);
