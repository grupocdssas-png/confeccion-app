import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/acceso/pantalla_ingreso.dart';
import '../../features/asistencia/pantalla_asistencia_web.dart';
import '../../features/configuracion/pantalla_configuracion.dart';
import '../../features/configuracion/pantalla_etiquetas.dart';
import '../../features/balanceo/pantalla_balanceo.dart';
import '../../features/calidad/pantalla_calidad_web.dart';
import '../../features/corte/pantalla_corte.dart';
import '../../features/eficiencia/pantalla_eficiencia.dart';
import '../../features/corte/pantalla_cortes.dart';
import '../../features/corte/pantalla_juegos.dart';
import '../../features/externos/pantalla_externos.dart';
import '../../features/externos/pantalla_remision.dart';
import '../../features/fichas/pantalla_ficha.dart';
import '../../features/fichas/pantalla_fichas.dart';
import '../../features/inventario/pantalla_ajustes_conteos.dart';
import '../../features/produccion/pantalla_compras.dart';
import '../../features/produccion/pantalla_op.dart';
import '../../features/produccion/pantalla_ops.dart';
import '../../features/produccion/pantalla_pedidos.dart';
import '../../features/operaciones/pantalla_importar.dart';
import '../../features/operaciones/pantalla_operaciones.dart';
import '../../features/inventario/pantalla_entradas.dart';
import '../../features/inventario/pantalla_producto.dart';
import '../../features/inventario/pantalla_insumos_kardex.dart';
import '../../features/inventario/pantalla_materiales_ubicaciones.dart';
import '../../features/inventario/pantalla_telas.dart';
import '../../features/inicio/pantalla_inicio_web.dart';
import '../../features/personal/pantalla_personal.dart';
import '../../features/programacion/pantalla_programacion.dart';
import '../../features/shell_web/shell_web.dart';
import '../../features/terminacion/pantalla_terminacion.dart';
import '../../features/tv/pantalla_tv.dart';
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
      // la cuenta del televisor entra directo a sus tableros
      final permisos = sesion.value!.permisos;
      if (state.matchedLocation == '/' && permisos.isNotEmpty && permisos.every((p) => p.modulo == 'tv')) return '/tv';
      return null;
    },
    routes: [
      GoRoute(path: '/ingreso', builder: (_, _) => const PantallaIngreso()),
      // pantalla completa para el televisor (sin menú lateral)
      GoRoute(path: '/tv/ver/:id', builder: (_, s) => PantallaTv(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!)),
      ShellRoute(
        builder: (_, _, child) => ShellWeb(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PaginaWeb(child: PantallaInicioWeb())), // inicio: todos los usuarios
          GoRoute(path: '/personal', builder: (_, _) => protegida('/personal', const PantallaPersonal())),
          GoRoute(path: '/asistencia', builder: (_, _) => protegida('/asistencia', const PantallaAsistenciaWeb())),
          GoRoute(path: '/configuracion', builder: (_, _) => protegida('/configuracion', const PantallaConfiguracion())),
          GoRoute(path: '/configuracion/etiquetas', builder: (_, _) => protegida('/configuracion', const PantallaEtiquetas())),
          GoRoute(path: '/pedidos', builder: (_, _) => protegida('/pedidos', const PantallaPedidos())),
          GoRoute(path: '/pedidos/:id', builder: (_, s) => protegida('/pedidos', PantallaPedido(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
          GoRoute(path: '/op', builder: (_, _) => protegida('/op', const PantallaOps())),
          GoRoute(path: '/op/:id', builder: (_, s) => protegida('/op', PantallaOp(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
          GoRoute(path: '/compras', builder: (_, _) => protegida('/compras', const PantallaCompras())),
          GoRoute(path: '/compras/oc/:id', builder: (_, s) => protegida('/compras', PantallaOc(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
          GoRoute(path: '/corte', builder: (_, _) => protegida('/corte', const PantallaCortes())),
          GoRoute(path: '/corte/op/:op', builder: (_, s) => protegida('/corte', PantallaJuegosOp(key: ValueKey(s.pathParameters['op']), opId: s.pathParameters['op']!))),
          GoRoute(path: '/corte/:id', builder: (_, s) => protegida('/corte', PantallaCorte(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
          GoRoute(path: '/externos', builder: (_, _) => protegida('/externos', const PantallaExternos())),
          GoRoute(path: '/externos/:id', builder: (_, s) => protegida('/externos', PantallaRemision(key: ValueKey(s.pathParameters['id']), id: s.pathParameters['id']!))),
          GoRoute(path: '/programacion', builder: (_, _) => protegida('/programacion', const PantallaProgramacion())),
          GoRoute(path: '/balanceo', builder: (_, _) => protegida('/balanceo', const PantallaBalanceo())),
          GoRoute(path: '/calidad', builder: (_, _) => protegida('/calidad', const PantallaCalidadWeb())),
          GoRoute(path: '/terminacion', builder: (_, _) => protegida('/terminacion', const PantallaTerminacion())),
          GoRoute(path: '/eficiencia', builder: (_, _) => protegida('/eficiencia', const PantallaEficiencia())),
          GoRoute(path: '/tv', builder: (_, _) => protegida('/tv', const PantallaTableros())),
          GoRoute(path: '/operaciones', builder: (_, _) => protegida('/operaciones', const PantallaOperaciones())),
          GoRoute(path: '/operaciones/importar', builder: (_, _) => protegida('/operaciones', const PantallaImportar())),
          GoRoute(path: '/fichas', builder: (_, _) => protegida('/fichas', const PantallaFichas())),
          GoRoute(path: '/fichas/:id', builder: (_, s) => protegida('/fichas', PantallaFicha(key: ValueKey(s.uri.toString()), id: s.pathParameters['id']!, paso: int.tryParse(s.uri.queryParameters['paso'] ?? '') ?? 0))),
          GoRoute(path: '/inventario', redirect: (_, _) => '/inventario/telas'),
          GoRoute(path: '/inventario/telas', builder: (_, _) => protegida('/inventario', const PantallaTelas())),
          GoRoute(path: '/inventario/retazos', builder: (_, _) => protegida('/inventario', const PantallaTelas(retazos: true))),
          GoRoute(path: '/inventario/insumos', builder: (_, _) => protegida('/inventario', const PantallaInsumos())),
          GoRoute(path: '/inventario/producto', builder: (_, _) => protegida('/inventario', const PantallaProducto())),
          GoRoute(path: '/inventario/despachos', builder: (_, _) => protegida('/inventario', const PantallaDespachos())),
          GoRoute(path: '/inventario/kardex', builder: (_, _) => protegida('/inventario', const PantallaKardex())),
          GoRoute(path: '/inventario/entradas', builder: (_, _) => protegida('/inventario', const PantallaEntradas())),
          GoRoute(path: '/inventario/entradas/nueva', builder: (_, s) => protegida('/inventario', PantallaNuevaEntrada(key: ValueKey(s.uri.toString()), ocId: s.uri.queryParameters['oc']))),
          GoRoute(path: '/inventario/entradas/:id', builder: (_, s) => protegida('/inventario', PantallaDetalleEntrada(id: s.pathParameters['id']!))),
          GoRoute(path: '/inventario/ajustes', builder: (_, _) => protegida('/inventario', const PantallaAjustes())),
          GoRoute(path: '/inventario/conteos', builder: (_, _) => protegida('/inventario', const PantallaConteosWeb())),
          GoRoute(path: '/inventario/conteos/:id', builder: (_, s) => protegida('/inventario', PantallaDetalleConteo(id: s.pathParameters['id']!))),
          GoRoute(path: '/inventario/materiales', builder: (_, _) => protegida('/inventario', const PantallaMateriales())),
          GoRoute(path: '/inventario/ubicaciones', builder: (_, _) => protegida('/inventario', const PantallaUbicaciones())),
          GoRoute(path: '/:modulo', builder: (_, s) => PaginaWeb(child: PantallaProximamente(ruta: '/${s.pathParameters['modulo']}'))),
        ],
      ),
    ],
  );
});
