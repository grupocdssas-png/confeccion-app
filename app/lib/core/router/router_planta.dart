import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/acceso/pantalla_ingreso.dart';
import '../../features/asistencia/pantalla_asistencia_planta.dart';
import '../../features/bodega/pantallas_bodega.dart';
import '../../features/planta/pantalla_bandeja.dart';
import '../../features/planta/pantalla_inicio_planta.dart';
import '../auth/sesion.dart';

final routerPlantaProvider = Provider<GoRouter>((ref) {
  final cambios = ValueNotifier(0);
  ref.listen(sesionProvider, (_, _) => cambios.value++);
  ref.onDispose(cambios.dispose);
  return GoRouter(
    refreshListenable: cambios,
    redirect: (context, state) {
      final sesion = ref.read(sesionProvider);
      if (sesion.isLoading && !sesion.hasValue) return null;
      final vinculada = sesion.value != null;
      final enVincular = state.matchedLocation == '/vincular';
      if (!vinculada) return enVincular ? null : '/vincular';
      if (enVincular) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/vincular', builder: (_, _) => const PantallaIngreso(modoTablet: true)),
      GoRoute(path: '/', builder: (_, _) => const PantallaInicioPlanta()),
      GoRoute(path: '/asistencia', builder: (_, _) => const PantallaAsistenciaPlanta(atras: true)),
      GoRoute(path: '/bandeja', builder: (_, _) => const PantallaBandeja()),
      GoRoute(path: '/bodega', builder: (_, _) => const PantallaBodega()),
      GoRoute(path: '/bodega/rollo', builder: (_, _) => const PantallaRollo()),
      GoRoute(path: '/bodega/conteo', builder: (_, _) => const PantallaConteos()),
      GoRoute(path: '/bodega/conteo/:id', builder: (_, s) => PantallaConteo(conteoId: s.pathParameters['id']!)),
      GoRoute(path: '/bodega/impresion', builder: (_, _) => const PantallaColaImpresion()),
    ],
  );
});
