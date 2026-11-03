import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/datos_cache.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

final _alertasProvider = FutureProvider.autoDispose<ConCache<List<Map<String, dynamic>>>>((ref) => consultarConCache(
      ref.watch(prefsProvider),
      'alertas',
      () => Supabase.instance.client
          .from('alertas')
          .select()
          .eq('estado', 'abierta')
          .order('creada_en', ascending: false)
          .limit(20),
    ));

const _fases = [
  (1, 'Base: acceso, roles, maestros y sincronización'),
  (2, 'Inventarios y etiquetas de rollo'),
  (3, 'Operaciones y ficha técnica'),
  (4, 'Pedidos y órdenes de producción'),
  (5, 'Corte, paquetes y juegos'),
  (6, 'Tablet del operario y satélites'),
  (7, 'Células, balanceo y programación'),
  (8, 'Eficiencia, incentivos y TV'),
  (9, 'Calidad y terminación'),
  (10, 'Costos, trazabilidad e informes'),
  (11, 'Integraciones'),
  (12, 'Mantenimiento, asistencia y tiempos'),
];

class PantallaInicioWeb extends ConsumerWidget {
  const PantallaInicioWeb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesion = ref.watch(sesionProvider).value;
    if (sesion == null) return const SizedBox.shrink();
    final alertas = ref.watch(_alertasProvider);
    final ancho = MediaQuery.sizeOf(context).width;

    final tarjetaAlertas = Tarjeta(
      titulo: 'Alertas abiertas',
      child: alertas.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text('No se pudieron cargar: $e', style: estilo(13, color: Colores.rojo)),
        data: (r) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (r.esCopia) AvisoSinConexion('Sin conexión · datos de las ${Formato.hora(r.guardadoEn!)}'),
          if (r.datos.isEmpty) Text('No hay alertas abiertas.', style: estilo(14, color: Colores.textoSuave)),
          for (final a in r.datos)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.warning_amber_rounded, color: a['severidad'] == 'alta' ? Colores.rojo : Colores.ambar),
              title: Text(a['mensaje'] as String, style: estilo(14)),
              subtitle: Text(Formato.fechaHora(DateTime.parse(a['creada_en'] as String)), style: estilo(12, color: Colores.textoSuave)),
            ),
        ]),
      ),
    );

    final tarjetaFases = Tarjeta(
      titulo: 'Avance del proyecto',
      child: Column(children: [
        for (final (n, nombre) in _fases)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              SizedBox(width: 34, child: Text('F$n', style: estiloCodigo(12, color: Colores.textoSuave))),
              Expanded(child: Text(nombre, style: estilo(14, color: n <= 3 ? Colores.texto : Colores.textoSuave))),
              if (n <= 3) const Pastilla('Lista', color: Colores.verde, icono: Icons.check),
            ]),
          ),
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      EncabezadoPagina('Hola, ${sesion.nombre}', subtitulo: 'Planta de confección · ${Formato.fecha(DateTime.now())}'),
      if (ancho >= 1100)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: tarjetaAlertas),
          const SizedBox(width: 20),
          Expanded(flex: 2, child: tarjetaFases),
        ])
      else ...[tarjetaAlertas, const SizedBox(height: 16), tarjetaFases],
    ]);
  }
}
