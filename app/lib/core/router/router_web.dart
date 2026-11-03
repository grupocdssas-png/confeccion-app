import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/acceso/pantalla_ingreso.dart';
import '../../features/asistencia/pantalla_asistencia_web.dart';
import '../../features/configuracion/pantalla_configuracion.dart';
import '../../features/inicio/pantalla_inicio_web.dart';
import '../../features/personal/pantalla_personal.dart';
import '../../features/shell_web/shell_web.dart';
import '../auth/sesion.dart';

/// Rutas del panel web. Cada ruta exige permiso de "ver" sobre su módulo.
final routerWebProvider = Provider<GoRouter>((ref) {
  final cambios = ValueNotifier(0);
  ref.listen(sesionProvider, (_, _) => cambios.value++);
  ref.onDispose(cambios.dispose);

  Widget protegida(String ruta, Widget pagina) => PaginaWeb(
        child: Consumer(builder: (context, ref, _) {
          final s = ref.watch(sesionProvider).value;
          if (s == null) return const SizedBox.shrink();
          return s.permisoPorRuta(ruta) != null ? pagina : PantallaProximamente(ruta: ruta);
        }),
      );

  return GoRouter(
    refreshListenable: cambios,
    redirect: (context, state) {
      final sesion = ref.read(sesionProvider);
      if (sesion.isLoading && !sesion.hasValue) return null;
      final dentro = sesion.value != null;
      final enIngreso = state.matchedLocation == '/ingreso';
      if (!dentro) return enIngreso ? null : '/ingreso';
      if (enIngreso) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/ingreso', builder: (_, _) => const PantallaIngreso()),
      ShellRoute(
        builder: (_, _, child) => ShellWeb(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PaginaWeb(child: PantallaInicioWeb())), // inicio: todos los usuarios
          GoRoute(path: '/personal', builder: (_, _) => protegida('/personal', const PantallaPersonal())),
          GoRoute(path: '/asistencia', builder: (_, _) => protegida('/asistencia', const PantallaAsistenciaWeb())),
          GoRoute(path: '/configuracion', builder: (_, _) => protegida('/configuracion', const PantallaConfiguracion())),
          GoRoute(path: '/:modulo', builder: (_, s) => PaginaWeb(child: PantallaProximamente(ruta: '/${s.pathParameters['modulo']}'))),
        ],
      ),
    ],
  );
});
