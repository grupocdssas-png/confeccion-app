import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/sync/proveedores_sync.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../asistencia/pantalla_asistencia_planta.dart';
import 'indicador_sync.dart';
import 'proveedores_planta.dart';

/// Inicio de la tablet según el tipo de estación. La tablet de entrada abre
/// directo la asistencia; las demás muestran sus funciones (se activan por fase).
class PantallaInicioPlanta extends ConsumerWidget {
  const PantallaInicioPlanta({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estacion = ref.watch(miEstacionProvider);
    return estacion.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (e) {
        if (e == null) return const _EsperandoDescarga();
        if (e.tipo == 'entrada') return const PantallaAsistenciaPlanta();
        final funciones = <(String, IconData, String?, int)>[
          ('Asistencia', Icons.badge_outlined, '/asistencia', 1),
          if (e.tipo == 'modulo') ('Marcar operaciones', Icons.touch_app_outlined, null, 6),
          ('Escanear paquetes', Icons.qr_code_scanner, null, 6),
          if (e.tipo == 'mesa_corte') ('Corte en mesa', Icons.content_cut, null, 5),
          if (e.tipo == 'bodega') ('Bodega: recibir, despachar, contar', Icons.inventory_2_outlined, null, 2),
          if (e.tipo == 'calidad') ('Calidad en proceso', Icons.verified_outlined, null, 9),
        ];
        return Scaffold(
          appBar: const EncabezadoPlanta(titulo: 'Inicio'),
          body: Column(children: [
            const AvisosPlanta(),
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.all(20),
                crossAxisCount: MediaQuery.sizeOf(context).width > 700 ? 2 : 1,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 2.4,
                children: [
                  for (final (titulo, icono, ruta, fase) in funciones)
                    _Funcion(titulo: titulo, icono: icono, fase: fase, onTap: ruta == null ? null : () => context.push(ruta)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                onPressed: () => _desvincular(context, ref),
                icon: const Icon(Icons.link_off, color: Colores.textoSuave),
                label: Text('Desvincular tablet', style: estilo(15, color: Colores.textoSuave)),
              ),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _desvincular(BuildContext context, WidgetRef ref) async {
    final pendientes = ref.read(resumenBandejaProvider).value?.pendientes ?? 0;
    if (pendientes > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Hay $pendientes registros sin enviar. Conecte la tablet a internet antes de desvincularla.'),
        backgroundColor: Colores.rojo,
      ));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Desvincular tablet'),
        content: const Text('La tablet dejará de estar asociada a esta estación. Se necesitará la cuenta técnica para volver a vincularla.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Desvincular')),
        ],
      ),
    );
    if (ok != true) return;
    final db = ref.read(powerSyncProvider);
    await db.disconnectAndClear(); // seguro: no hay pendientes
    await ref.read(sesionProvider.notifier).salir();
  }
}

class _Funcion extends StatelessWidget {
  const _Funcion({required this.titulo, required this.icono, required this.fase, this.onTap});
  final String titulo;
  final IconData icono;
  final int fase;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final activa = onTap != null;
    final color = activa ? Colores.texto : Colores.textoSuave.withValues(alpha: 0.6);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Icon(icono, size: 44, color: color),
            const SizedBox(width: 18),
            Expanded(child: Text(titulo, style: estilo(22, peso: FontWeight.w600, color: color))),
            if (!activa) Pastilla('Fase $fase', color: Colores.textoSuave),
          ]),
        ),
      ),
    );
  }
}

class _EsperandoDescarga extends ConsumerWidget {
  const _EsperandoDescarga();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(estadoSyncProvider).value;
    final error = estado?.downloadError ?? estado?.uploadError;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text('Descargando los datos de la estación…', style: estilo(24, peso: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('La primera vez la tablet necesita internet. Después funciona sin conexión.',
                textAlign: TextAlign.center, style: estilo(17, color: Colores.textoSuave)),
            if (error != null) ...[
              const SizedBox(height: 16),
              Text('$error', textAlign: TextAlign.center, style: estilo(14, color: Colores.rojo)),
            ],
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => ref.read(sesionProvider.notifier).salir(),
              child: const Text('Usar otra cuenta'),
            ),
          ]),
        ),
      ),
    );
  }
}
