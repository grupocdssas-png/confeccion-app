import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/datos_cache.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

final _usuariosProvider = FutureProvider.autoDispose((ref) => consultarConCache(
      ref.watch(prefsProvider),
      'usuarios',
      () => Supabase.instance.client
          .from('perfiles')
          .select('id, nombre, correo, es_dispositivo, activo, usuario_roles(rol)')
          .order('nombre', ascending: true),
    ));

final _dispositivosProvider = FutureProvider.autoDispose((ref) => consultarConCache(
      ref.watch(prefsProvider),
      'dispositivos',
      () => Supabase.instance.client
          .from('dispositivos')
          .select('id, nombre, tipo, version_app, ultima_sync, desfase_reloj_s, activo, estaciones(codigo, nombre)')
          .order('nombre', ascending: true),
    ));

final _rechazosProvider = FutureProvider.autoDispose((ref) => consultarConCache(
      ref.watch(prefsProvider),
      'rechazos',
      () => Supabase.instance.client
          .from('ingesta_eventos')
          .select('id, tabla, motivo, intentos, recibido_en, dispositivos(nombre)')
          .eq('estado', 'rechazado')
          .order('recibido_en', ascending: false)
          .limit(50),
    ));

class PantallaConfiguracion extends ConsumerWidget {
  const PantallaConfiguracion({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Configuración', subtitulo: 'Usuarios, roles y tablets de planta', acciones: [
        OutlinedButton.icon(
          onPressed: () => context.go('/configuracion/etiquetas'),
          icon: const Icon(Icons.print_outlined),
          label: const Text('Impresoras y etiquetas'),
        ),
      ]),
      _Seccion(
        titulo: 'Usuarios y roles',
        proveedor: ref.watch(_usuariosProvider),
        columnas: const ['Nombre', 'Correo', 'Roles', 'Tipo', 'Estado'],
        fila: (u) => [
          Text('${u['nombre']}'),
          Text('${u['correo'] ?? ''}', style: estilo(13, color: Colores.textoSuave)),
          Text([for (final r in u['usuario_roles'] as List) r['rol']].join(', ')),
          Text(u['es_dispositivo'] == true ? 'Tablet / dispositivo' : 'Persona'),
          u['activo'] == true ? const Pastilla('Activo', color: Colores.verde) : const Pastilla('Inactivo', color: Colores.textoSuave),
        ],
      ),
      const SizedBox(height: 20),
      _Seccion(
        titulo: 'Tablets y dispositivos',
        proveedor: ref.watch(_dispositivosProvider),
        columnas: const ['Dispositivo', 'Estación', 'Última sincronización', 'Desfase de hora', 'Versión'],
        fila: (d) {
          final ultima = d['ultima_sync'] == null ? null : DateTime.parse(d['ultima_sync'] as String);
          final desfase = (d['desfase_reloj_s'] as num?)?.toInt();
          return [
            Text('${d['nombre']}'),
            Text('${d['estaciones']?['codigo']} · ${d['estaciones']?['nombre']}'),
            Text(ultima == null ? 'Nunca' : Formato.fechaHora(ultima)),
            desfase == null
                ? const Text('—')
                : Pastilla('${desfase >= 0 ? '+' : ''}$desfase s', color: desfase.abs() > 300 ? Colores.rojo : Colores.verde),
            Text('${d['version_app'] ?? '—'}', style: estiloCodigo(12)),
          ];
        },
      ),
      const SizedBox(height: 20),
      _Seccion(
        titulo: 'Eventos rechazados por el servidor',
        proveedor: ref.watch(_rechazosProvider),
        vacio: 'No hay eventos rechazados.',
        columnas: const ['Recibido', 'Dispositivo', 'Tipo de evento', 'Motivo', 'Intentos'],
        fila: (e) => [
          Text(Formato.fechaHora(DateTime.parse(e['recibido_en'] as String))),
          Text('${e['dispositivos']?['nombre'] ?? '—'}'),
          Text('${e['tabla']}', style: estiloCodigo(12)),
          Text('${e['motivo']}', style: estilo(13, color: Colores.rojo)),
          Text('${e['intentos']}'),
        ],
      ),
      const SizedBox(height: 12),
      Text('Crear usuarios y asignar roles desde esta pantalla llega en una fase posterior (requiere una función de servidor segura). '
          'Por ahora se usan los usuarios de ejemplo del README.', style: estilo(12.5, color: Colores.textoSuave)),
    ]);
  }
}

class _Seccion extends StatelessWidget {
  const _Seccion({required this.titulo, required this.proveedor, required this.columnas, required this.fila, this.vacio = 'Sin datos.'});
  final String titulo, vacio;
  final AsyncValue<ConCache<List<Map<String, dynamic>>>> proveedor;
  final List<String> columnas;
  final List<Widget> Function(Map<String, dynamic>) fila;

  @override
  Widget build(BuildContext context) {
    final datos = proveedor;
    return Tarjeta(
      titulo: titulo,
      child: datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text('Error: $e', style: estilo(13, color: Colores.rojo)),
        data: (r) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (r.esCopia) AvisoSinConexion('Sin conexión · datos de las ${Formato.hora(r.guardadoEn!)}'),
          if (r.datos.isEmpty)
            Text(vacio, style: estilo(14, color: Colores.textoSuave))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                horizontalMargin: 0,
                headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
                columns: [for (final c in columnas) DataColumn(label: Text(c))],
                rows: [for (final f in r.datos) DataRow(cells: [for (final w in fila(f)) DataCell(w)])],
              ),
            ),
        ]),
      ),
    );
  }
}
