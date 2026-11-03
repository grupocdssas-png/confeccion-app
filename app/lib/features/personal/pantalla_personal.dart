import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/datos_cache.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

final _empleadosProvider = FutureProvider.autoDispose<ConCache<List<Map<String, dynamic>>>>((ref) => consultarConCache(
      ref.watch(prefsProvider),
      'empleados',
      () => Supabase.instance.client
          .from('empleados')
          .select('id, codigo, nombres, apellidos, qr, activo, celulas(codigo, nombre), cargos(nombre)')
          .order('codigo', ascending: true),
    ));

class PantallaPersonal extends ConsumerStatefulWidget {
  const PantallaPersonal({super.key});
  @override
  ConsumerState<PantallaPersonal> createState() => _PantallaPersonalState();
}

class _PantallaPersonalState extends ConsumerState<PantallaPersonal> {
  var _filtro = '';

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_empleadosProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      EncabezadoPagina('Personal', subtitulo: 'Empleados, célula y código del carnet', acciones: [
        SizedBox(
          width: 260,
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar por nombre o código', isDense: true),
            onChanged: (v) => setState(() => _filtro = v.toLowerCase()),
          ),
        ),
      ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text('Error: $e', style: estilo(14, color: Colores.rojo)),
        data: (r) {
          final filas = r.datos.where((e) => '${e['codigo']} ${e['nombres']} ${e['apellidos']}'.toLowerCase().contains(_filtro)).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (r.esCopia) AvisoSinConexion('Sin conexión · datos de las ${Formato.hora(r.guardadoEn!)}'),
            Tarjeta(
              padding: EdgeInsets.zero,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
                  columns: const [
                    DataColumn(label: Text('Código')),
                    DataColumn(label: Text('Nombre')),
                    DataColumn(label: Text('Cargo')),
                    DataColumn(label: Text('Célula')),
                    DataColumn(label: Text('Carnet (QR)')),
                    DataColumn(label: Text('Estado')),
                  ],
                  rows: [
                    for (final e in filas)
                      DataRow(cells: [
                        DataCell(Text('${e['codigo']}', style: estiloCodigo(13))),
                        DataCell(Row(children: [
                          Iniciales('${e['nombres']} ${e['apellidos']}', tamano: 28),
                          const SizedBox(width: 10),
                          Text('${e['nombres']} ${e['apellidos']}'),
                        ])),
                        DataCell(Text('${e['cargos']?['nombre'] ?? '—'}')),
                        DataCell(Text('${e['celulas']?['codigo'] ?? '—'}', style: estiloCodigo(13))),
                        DataCell(Text('${e['qr']}', style: estiloCodigo(13))),
                        DataCell(e['activo'] == true
                            ? const Pastilla('Activo', color: Colores.verde)
                            : const Pastilla('Inactivo', color: Colores.textoSuave)),
                      ]),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${filas.length} empleados', style: estilo(12, color: Colores.textoSuave)),
            ),
          ]);
        },
      ),
    ]);
  }
}
