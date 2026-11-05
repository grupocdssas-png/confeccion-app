import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/sesion.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../../compartido/widgets.dart';
import 'iconos.dart';

/// Fase que está implementada hasta ahora (los módulos de fases posteriores se
/// muestran en el menú pero atenuados).
const faseActual = 6;

/// Estructura del panel web: menú lateral oscuro (fijo en pantallas anchas,
/// desplegable en celular) + contenido.
class ShellWeb extends ConsumerWidget {
  const ShellWeb({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ancho = MediaQuery.sizeOf(context).width;
    final fijo = ancho >= 960;
    final menu = const _MenuLateral();
    return Scaffold(
      drawer: fijo ? null : Drawer(backgroundColor: Colores.menu, width: 260, child: menu),
      appBar: fijo
          ? null
          : AppBar(
              backgroundColor: Colores.menu,
              foregroundColor: Colors.white,
              title: Text('Confección', style: estilo(17, peso: FontWeight.w600, color: Colors.white)),
            ),
      body: Row(children: [
        if (fijo) const SizedBox(width: 240, child: ColoredBox(color: Colores.menu, child: _MenuLateral())),
        Expanded(child: child),
      ]),
    );
  }
}

class _MenuLateral extends ConsumerWidget {
  const _MenuLateral();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesion = ref.watch(sesionProvider).value;
    if (sesion == null) return const SizedBox.shrink();
    final rutaActual = GoRouterState.of(context).uri.path;
    final grupos = <String, List<PermisoModulo>>{};
    for (final p in sesion.permisos) {
      if (p.modulo == 'tv') continue; // la TV se abre aparte
      grupos.putIfAbsent(p.grupo, () => []).add(p);
    }
    const orden = ['General', 'Producción', 'Diseño', 'Inventarios', 'Piso', 'Administración'];
    final claves = grupos.keys.toList()..sort((a, b) => orden.indexOf(a).compareTo(orden.indexOf(b)));

    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Row(children: [
            Container(width: 8, height: 22, color: Colores.deProceso('corte')),
            const SizedBox(width: 10),
            Text('Confección', style: estilo(17, peso: FontWeight.w600, color: Colors.white)),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
            for (final g in claves) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
                child: Text(g.toUpperCase(), style: estilo(11, peso: FontWeight.w600, color: Colores.menuTexto.withValues(alpha: 0.6))),
              ),
              for (final p in grupos[g]!) _ItemMenu(permiso: p, activo: rutaActual == p.ruta || (p.ruta != '/' && rutaActual.startsWith('${p.ruta}/'))),
            ],
          ]),
        ),
        const Divider(color: Colors.white12),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Row(children: [
            Iniciales(sesion.nombre, tamano: 32, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(sesion.nombre, style: estilo(13, peso: FontWeight.w600, color: Colors.white), overflow: TextOverflow.ellipsis),
                Text(sesion.roles.join(', '), style: estilo(11, color: Colores.menuTexto), overflow: TextOverflow.ellipsis),
              ]),
            ),
            IconButton(
              tooltip: 'Salir',
              icon: const Icon(Icons.logout, color: Colores.menuTexto, size: 20),
              onPressed: () => ref.read(sesionProvider.notifier).salir(),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _ItemMenu extends StatelessWidget {
  const _ItemMenu({required this.permiso, required this.activo});
  final PermisoModulo permiso;
  final bool activo;

  @override
  Widget build(BuildContext context) {
    final disponible = permiso.fase <= faseActual;
    final color = activo ? Colors.white : Colores.menuTexto.withValues(alpha: disponible ? 1 : 0.45);
    return Material(
      color: activo ? Colores.menuActivo : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          Scaffold.maybeOf(context)?.closeDrawer();
          context.go(permiso.ruta);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(iconoModulo(permiso.icono), size: 18, color: color),
              const SizedBox(width: 12),
              Expanded(child: Text(permiso.nombre, style: estilo(13.5, peso: activo ? FontWeight.w600 : FontWeight.w400, color: color))),
              if (!disponible) Text('F${permiso.fase}', style: estiloCodigo(10.5, color: color, peso: FontWeight.w400)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Contenedor de cada página del panel: desplazamiento, márgenes y ancho máximo.
class PaginaWeb extends StatelessWidget {
  const PaginaWeb({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final fijo = MediaQuery.sizeOf(context).width >= 960;
    return SelectionArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: fijo ? 32 : 16, vertical: fijo ? 28 : 16),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1400), child: child),
        ),
      ),
    );
  }
}

/// Página para módulos que llegan en fases posteriores.
class PantallaProximamente extends ConsumerWidget {
  const PantallaProximamente({super.key, required this.ruta});
  final String ruta;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(sesionProvider).value?.permisoPorRuta(ruta);
    if (p == null) {
      return const EncabezadoPagina('Sin acceso', subtitulo: 'Su rol no tiene permiso para este módulo.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      EncabezadoPagina(p.nombre),
      Tarjeta(
        child: Row(children: [
          Icon(iconoModulo(p.icono), size: 28, color: Colores.textoSuave),
          const SizedBox(width: 14),
          Expanded(child: Text('Este módulo se construye en la Fase ${p.fase}.', style: estilo(15))),
        ]),
      ),
    ]);
  }
}
