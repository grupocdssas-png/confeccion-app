import 'package:flutter/material.dart';

import '../core/tema/colores.dart';
import '../core/tema/tema.dart';

/// Tarjeta blanca con borde #E2E2DC.
class Tarjeta extends StatelessWidget {
  const Tarjeta({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.titulo, this.accion});
  final Widget child;
  final EdgeInsets padding;
  final String? titulo;
  final Widget? accion;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (titulo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    Expanded(child: Text(titulo!, style: Theme.of(context).textTheme.titleMedium)),
                    ?accion,
                  ]),
                ),
              child,
            ],
          ),
        ),
      );
}

/// Pastilla de estado con color (semáforo, procesos, sincronización).
class Pastilla extends StatelessWidget {
  const Pastilla(this.texto, {super.key, required this.color, this.icono, this.grande = false});
  final String texto;
  final Color color;
  final IconData? icono;
  final bool grande;

  @override
  Widget build(BuildContext context) {
    final t = grande ? 15.0 : 12.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: grande ? 12 : 8, vertical: grande ? 6 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icono != null) ...[Icon(icono, size: t + 3, color: color), const SizedBox(width: 6)],
        Text(texto, style: estilo(t, peso: FontWeight.w600, color: color)),
      ]),
    );
  }
}

class EncabezadoPagina extends StatelessWidget {
  const EncabezadoPagina(this.titulo, {super.key, this.subtitulo, this.acciones = const []});
  final String titulo;
  final String? subtitulo;
  final List<Widget> acciones;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 12,
          spacing: 12,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(titulo, style: Theme.of(context).textTheme.headlineSmall),
              if (subtitulo != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(subtitulo!, style: estilo(14, color: Colores.textoSuave)),
                ),
            ]),
            Wrap(spacing: 8, children: acciones),
          ],
        ),
      );
}

/// Aviso cuando se muestran datos guardados por falta de conexión.
class AvisoSinConexion extends StatelessWidget {
  const AvisoSinConexion(this.mensaje, {super.key});
  final String mensaje;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colores.ambar.withValues(alpha: 0.10),
          border: Border.all(color: Colores.ambar.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          const Icon(Icons.cloud_off, color: Colores.ambar, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(mensaje, style: estilo(13, color: Colores.texto))),
        ]),
      );
}

/// Inicial del nombre en un círculo (cuando aún no hay foto).
class Iniciales extends StatelessWidget {
  const Iniciales(this.nombre, {super.key, this.tamano = 40, this.color = Colores.texto});
  final String nombre;
  final double tamano;
  final Color color;
  @override
  Widget build(BuildContext context) {
    // Solo palabras que empiezan por letra: "Gerencia (EJEMPLO)" → "G", "Ana María" → "AM".
    final partes = nombre.trim().split(RegExp(r'\s+')).where((p) => RegExp(r'^\p{L}', unicode: true).hasMatch(p)).toList();
    final ini = partes.take(2).map((p) => p[0].toUpperCase()).join();
    return CircleAvatar(
      radius: tamano / 2,
      backgroundColor: color.withValues(alpha: 0.12),
      child: Text(ini, style: estilo(tamano * 0.38, peso: FontWeight.w600, color: color)),
    );
  }
}
