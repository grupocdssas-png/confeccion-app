import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/db_local/app_db.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/bandeja.dart';
import '../../core/sync/proveedores_sync.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'indicador_sync.dart';

final _todosProvider = StreamProvider((ref) => ref.watch(appDbProvider).observarRecientes(limite: 200));

/// Bandeja de salida: qué está pendiente, qué se envió y qué rechazó el servidor.
class PantallaBandeja extends ConsumerWidget {
  const PantallaBandeja({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventos = ref.watch(_todosProvider).value ?? const <EventoBandeja>[];
    final estado = ref.watch(estadoSyncProvider).value;
    return Scaffold(
      appBar: const EncabezadoPlanta(titulo: 'Sincronización', atras: true),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Tarjeta(
          titulo: 'Estado',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(estado?.connected == true ? 'Conectado al servidor' : 'Sin conexión: los registros se guardan en la tablet y se envían solos al volver la señal.',
                style: estilo(17)),
            if (estado?.lastSyncedAt != null)
              Text('Última descarga: ${Formato.fechaHora(estado!.lastSyncedAt!)}', style: estilo(15, color: Colores.textoSuave)),
            if (estado?.uploadError != null)
              Text('Error al enviar: ${estado!.uploadError}', style: estilo(14, color: Colores.rojo)),
          ]),
        ),
        const SizedBox(height: 16),
        Tarjeta(
          titulo: 'Registros (${eventos.length})',
          child: Column(children: [
            for (final e in eventos)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_describir(e), style: estilo(17)),
                subtitle: Text(
                  [
                    Formato.fechaHora(DateTime.parse(e.ocurridoEn!)),
                    if (e.estado == EstadoEvento.rechazado) 'Motivo: ${e.motivo}',
                    if ((e.intentos ?? 0) > 1) '${e.intentos} intentos',
                  ].join(' · '),
                  style: estilo(14, color: e.estado == EstadoEvento.rechazado ? Colores.rojo : Colores.textoSuave),
                ),
                trailing: switch (e.estado) {
                  EstadoEvento.sincronizado => const Pastilla('Enviado', color: Colores.verde, icono: Icons.check),
                  EstadoEvento.rechazado => const Pastilla('Rechazado', color: Colores.rojo, icono: Icons.error_outline),
                  _ => const Pastilla('Pendiente', color: Colores.ambar, icono: Icons.schedule),
                },
              ),
          ]),
        ),
      ]),
    );
  }

  String _describir(EventoBandeja e) {
    final r = jsonDecode(e.resumen ?? '{}') as Map<String, dynamic>;
    return switch (e.tabla) {
      'asistencia_marcas' => switch (r['tipo']) {
          'anulacion' => 'Anulación de marca · ${r['nombre']}',
          final t => '${t == 'entrada' ? 'Entrada' : 'Salida'} · ${r['nombre']}',
        },
      _ => '${e.tabla}',
    };
  }
}
