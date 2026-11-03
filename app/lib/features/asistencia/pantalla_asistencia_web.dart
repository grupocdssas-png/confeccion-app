import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/datos_cache.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

final _marcasHoyProvider = FutureProvider.autoDispose<ConCache<List<Map<String, dynamic>>>>((ref) {
  // Se actualiza solo cuando llega una marca nueva (Realtime de Supabase).
  final canal = Supabase.instance.client
      .channel('asistencia-web')
      .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'asistencia_marcas',
        callback: (_) => ref.invalidateSelf(),
      )
      .subscribe();
  ref.onDispose(() => Supabase.instance.client.removeChannel(canal));
  // Respaldo por si Realtime se cae: refresco cada 60 s.
  final t = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(t.cancel);

  return consultarConCache(
    ref.watch(prefsProvider),
    'asistencia_hoy',
    () => Supabase.instance.client
        .from('asistencia_marcas')
        .select('id, tipo, anula_id, motivo, ocurrido_en, ocurrido_en_servidor, recibido_en, reloj_dudoso, '
            'empleados(codigo, nombres, apellidos), estaciones(codigo, nombre)')
        .gte('ocurrido_en_servidor', Formato.inicioDiaBogota().toIso8601String())
        .order('ocurrido_en_servidor', ascending: false),
  );
});

class PantallaAsistenciaWeb extends ConsumerWidget {
  const PantallaAsistenciaWeb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_marcasHoyProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      EncabezadoPagina('Asistencia de hoy',
          subtitulo: 'Entradas y salidas registradas con el carnet en las tablets · se actualiza sola',
          acciones: [
            OutlinedButton.icon(
              onPressed: () => ref.invalidate(_marcasHoyProvider),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Actualizar'),
            ),
          ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text('Error: $e', style: estilo(14, color: Colores.rojo)),
        data: (r) {
          final anuladas = {for (final m in r.datos) if (m['anula_id'] != null) m['anula_id']: m['motivo']};
          final vigentes = r.datos.where((m) => m['tipo'] != 'anulacion' && !anuladas.containsKey(m['id'])).toList();
          // Presente = su última marca vigente es una entrada
          final ultima = <String, String>{};
          for (final m in vigentes.reversed) {
            ultima['${m['empleados']['codigo']}'] = m['tipo'] as String;
          }
          final presentes = ultima.values.where((t) => t == 'entrada').length;

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (r.esCopia) AvisoSinConexion('Sin conexión · mostrando los datos de las ${Formato.hora(r.guardadoEn!)}'),
            Wrap(spacing: 16, runSpacing: 16, children: [
              _Indicador('En planta ahora', '$presentes', Colores.verde),
              _Indicador('Marcas de hoy', '${vigentes.length}', Colores.texto),
              _Indicador('Con reloj dudoso', '${vigentes.where((m) => m['reloj_dudoso'] == true).length}', Colores.ambar),
            ]),
            const SizedBox(height: 16),
            Tarjeta(
              padding: EdgeInsets.zero,
              child: r.datos.isEmpty
                  ? Padding(padding: const EdgeInsets.all(20), child: Text('Aún no hay marcas hoy.', style: estilo(14, color: Colores.textoSuave)))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
                        columns: const [
                          DataColumn(label: Text('Hora')),
                          DataColumn(label: Text('Empleado')),
                          DataColumn(label: Text('Tipo')),
                          DataColumn(label: Text('Estación')),
                          DataColumn(label: Text('Recibido')),
                          DataColumn(label: Text('Observación')),
                        ],
                        rows: [
                          for (final m in r.datos.where((m) => m['tipo'] != 'anulacion'))
                            _fila(m, anuladas[m['id']]),
                        ],
                      ),
                    ),
            ),
          ]);
        },
      ),
    ]);
  }

  DataRow _fila(Map<String, dynamic> m, Object? motivoAnulacion) {
    final anulada = motivoAnulacion != null;
    final tachado = anulada ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colores.textoSuave) : null;
    final e = m['empleados'];
    final hora = DateTime.parse(m['ocurrido_en_servidor'] as String);
    final recibido = DateTime.parse(m['recibido_en'] as String);
    final demora = recibido.difference(hora);
    return DataRow(cells: [
      DataCell(Text(Formato.hora(hora), style: estiloCodigo(13).merge(tachado))),
      DataCell(Text('${e['codigo']} · ${e['nombres']} ${e['apellidos']}', style: tachado)),
      DataCell(Pastilla(m['tipo'] == 'entrada' ? 'Entrada' : 'Salida',
          color: anulada ? Colores.textoSuave : (m['tipo'] == 'entrada' ? Colores.verde : Colores.deProceso('corte')))),
      DataCell(Text('${m['estaciones']?['codigo'] ?? ''}', style: estiloCodigo(13))),
      DataCell(Text(demora.inMinutes >= 5 ? '${Formato.hora(recibido)} (sin conexión ${demora.inMinutes} min)' : Formato.hora(recibido),
          style: estilo(13, color: demora.inMinutes >= 5 ? Colores.ambar : null))),
      DataCell(Text(
        [if (anulada) 'Anulada: $motivoAnulacion', if (m['reloj_dudoso'] == true) 'Hora de la tablet desfasada (corregida)'].join(' · '),
        style: estilo(13, color: Colores.textoSuave),
      )),
    ]);
  }
}

class _Indicador extends StatelessWidget {
  const _Indicador(this.titulo, this.valor, this.color);
  final String titulo, valor;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
        child: Tarjeta(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titulo, style: estilo(13, color: Colores.textoSuave)),
            const SizedBox(height: 6),
            Text(valor, style: estilo(30, peso: FontWeight.w600, color: color)),
          ]),
        ),
      );
}
