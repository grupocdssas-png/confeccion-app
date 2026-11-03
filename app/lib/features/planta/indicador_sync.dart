import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/proveedores_sync.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'proveedores_planta.dart';

/// "Sin conexión · N pendientes" / "Enviando · N pendientes" / "Sincronizado hh:mm".
/// Siempre visible en el encabezado de la planta. Al tocarlo abre la bandeja.
class IndicadorSync extends ConsumerWidget {
  const IndicadorSync({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = ref.watch(estadoSyncProvider).value;
    final resumen = ref.watch(resumenBandejaProvider).value;
    final n = resumen?.pendientes ?? 0;
    // Si el último envío falló, la red está caída aunque PowerSync aún no lo haya notado.
    final conectado = (estado?.connected ?? false) && estado?.uploadError == null;
    final ultimo = [estado?.lastSyncedAt, resumen?.ultimoSincronizado].whereType<DateTime>().fold<DateTime?>(
        null, (a, b) => a == null || b.isAfter(a) ? b : a);

    final (texto, color, icono) = switch ((conectado, n)) {
      (false, _) => ('Sin conexión · $n pendientes', n > 0 ? Colores.ambar : Colores.textoSuave, Icons.cloud_off),
      (true, > 0) => ('Enviando · $n pendientes', Colores.ambar, Icons.cloud_upload_outlined),
      _ => (ultimo == null ? 'Conectado' : 'Sincronizado ${Formato.hora(ultimo)}', Colores.verde, Icons.cloud_done_outlined),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => context.push('/bandeja'),
      child: Wrap(spacing: 6, children: [
        Pastilla(texto, color: color, icono: icono, grande: true),
        if ((resumen?.rechazados ?? 0) > 0)
          Pastilla('${resumen!.rechazados} rechazados', color: Colores.rojo, icono: Icons.error_outline, grande: true),
      ]),
    );
  }
}

/// Avisos que deben verse sí o sí: pendientes viejos y hora de la tablet desfasada.
class AvisosPlanta extends ConsumerWidget {
  const AvisosPlanta({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ahora = ref.watch(relojProvider).value ?? DateTime.now();
    final resumen = ref.watch(resumenBandejaProvider).value;
    final horas = ref.watch(parametroProvider('horas_aviso_pendientes')).value ?? 8;
    final tolerancia = ref.watch(parametroProvider('tolerancia_reloj_s')).value ?? 300;
    final desfase = ref.watch(desfaseRelojProvider).value;

    final avisos = <String>[
      if (resumen != null && resumen.pendientesViejos(ahora, Duration(minutes: (horas * 60).round())))
        'Hay registros sin enviar desde las ${Formato.hora(resumen.pendienteMasAntiguo!)} '
            '(más de ${horas.round()} horas). Revise el internet de la tablet.',
      if (desfase != null && desfase.abs() > tolerancia)
        'La hora de esta tablet está desfasada ${(desfase.abs() / 60).round()} min. Corríjala en Ajustes del sistema.',
    ];
    if (avisos.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final a in avisos)
        Container(
          width: double.infinity,
          color: Colores.rojo,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(a, style: estilo(16, peso: FontWeight.w600, color: Colors.white))),
          ]),
        ),
    ]);
  }
}

/// Encabezado oscuro de las pantallas de planta: estación, hora y sincronización.
class EncabezadoPlanta extends ConsumerWidget implements PreferredSizeWidget {
  const EncabezadoPlanta({super.key, required this.titulo, this.atras = false});
  final String titulo;
  final bool atras;

  @override
  Size get preferredSize => const Size.fromHeight(76);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estacion = ref.watch(miEstacionProvider).value;
    final ahora = ref.watch(relojProvider).value ?? DateTime.now();
    return Material(
      color: Colores.menu,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              if (atras)
                IconButton(
                  iconSize: 32,
                  tooltip: 'Volver',
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => context.pop(),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(titulo, style: estilo(20, peso: FontWeight.w600, color: Colors.white), overflow: TextOverflow.ellipsis),
                  if (estacion != null)
                    Text('${estacion.codigo} · ${estacion.nombre}', style: estilo(14, color: Colores.menuTexto), overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(Formato.hora(ahora), style: estiloCodigo(26, color: Colors.white)),
              const SizedBox(width: 16),
              const DecoratedBox(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(999))),
                child: IndicadorSync(),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
