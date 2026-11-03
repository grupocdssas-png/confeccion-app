import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, avisar;
import '../operaciones/pantalla_operaciones.dart' show catalogoDisenoProvider;

final _referenciasProvider = FutureProvider.autoDispose((ref) => db
    .from('referencias')
    .select('*, familias_producto(nombre), tipos_producto(nombre), '
        'ficha_versiones!ficha_versiones_referencia_id_fkey(id, version, estado, costo_estandar, sam_total, precio_objetivo, creado_en)')
    .order('codigo', ascending: true));

Pastilla pastillaEstadoFicha(String e) => switch (e) {
      'borrador' => const Pastilla('Borrador', color: Colores.textoSuave),
      'en_aprobacion' => const Pastilla('En aprobación', color: Colores.ambar),
      'aprobada' => const Pastilla('Aprobada', color: Colores.verde, icono: Icons.lock_outline),
      'obsoleta' => const Pastilla('Obsoleta', color: Colores.textoSuave),
      _ => Pastilla(e, color: Colores.textoSuave),
    };

/// Referencias con sus versiones de ficha técnica.
class PantallaFichas extends ConsumerStatefulWidget {
  const PantallaFichas({super.key});
  @override
  ConsumerState<PantallaFichas> createState() => _PantallaFichasState();
}

class _PantallaFichasState extends ConsumerState<PantallaFichas> {
  var _filtro = '';

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_referenciasProvider);
    final editar = ref.watch(sesionProvider).value?.puedeEditar('ficha_tecnica') ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Fichas técnicas', subtitulo: 'Cada referencia con sus versiones. Una versión aprobada queda congelada.', acciones: [
        SizedBox(width: 240, child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Referencia o nombre', isDense: true),
            onChanged: (v) => setState(() => _filtro = v.toLowerCase()))),
        if (editar) FilledButton.icon(onPressed: _nueva, icon: const Icon(Icons.add), label: const Text('Nueva referencia')),
      ]),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (refs) {
          final lista = refs.where((r) => '${r['codigo']} ${r['nombre']}'.toLowerCase().contains(_filtro)).toList();
          return Tarjeta(
            padding: EdgeInsets.zero,
            child: Tabla(
              columnas: const ['Referencia', 'Nombre', 'Familia / tipo', 'Versiones', 'Vigente', 'SAM', 'Costo estándar', 'Precio objetivo', ''],
              numericas: const {5, 6, 7},
              vacio: 'No hay referencias.',
              filas: [
                for (final r in lista) _fila(r),
              ],
            ),
          );
        },
      ),
    ]);
  }

  DataRow _fila(Map<String, dynamic> r) {
    final versiones = (r['ficha_versiones'] as List).cast<Map<String, dynamic>>()..sort((a, b) => (b['version'] as int).compareTo(a['version'] as int));
    final vigente = versiones.where((v) => v['id'] == r['version_vigente_id']).firstOrNull;
    final ultima = versiones.firstOrNull;
    return DataRow(cells: [
      DataCell(Text('${r['codigo']}', style: estiloCodigo(13))),
      DataCell(Text('${r['nombre']}')),
      DataCell(Text([r['familias_producto']?['nombre'], r['tipos_producto']?['nombre']].whereType<String>().join(' · '), style: estilo(12.5))),
      DataCell(Wrap(spacing: 4, children: [
        for (final v in versiones.take(4))
          ActionChip(
            label: Text('v${v['version']}'),
            avatar: Icon(v['estado'] == 'aprobada' ? Icons.lock_outline : v['estado'] == 'borrador' ? Icons.edit_outlined : Icons.hourglass_empty, size: 14),
            onPressed: () => context.go('/fichas/${v['id']}'),
          ),
      ])),
      DataCell(vigente == null ? const Text('—') : Text('v${vigente['version']}')),
      DataCell(Text(vigente?['sam_total'] == null ? '—' : Formato.numero(vigente!['sam_total'], decimales: 2))),
      DataCell(Text(vigente?['costo_estandar'] == null ? '—' : Formato.cop(vigente!['costo_estandar']))),
      DataCell(Text(ultima?['precio_objetivo'] == null ? '—' : Formato.cop(ultima!['precio_objetivo']))),
      DataCell(ultima == null ? const SizedBox() : TextButton(onPressed: () => context.go('/fichas/${ultima['id']}'), child: const Text('Abrir'))),
    ]);
  }

  Future<void> _nueva() async {
    final cat = await ref.read(catalogoDisenoProvider.future);
    if (!mounted) return;
    final codigo = TextEditingController(), nombre = TextEditingController();
    String? familia, tipo;
    final id = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
            title: const Text('Nueva referencia'),
            content: SizedBox(
              width: 460,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: codigo, decoration: const InputDecoration(labelText: 'Código de referencia', hintText: 'CAM-010')),
                const SizedBox(height: 10),
                TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(decoration: const InputDecoration(labelText: 'Familia'),
                    items: [for (final f in cat.familias) DropdownMenuItem(value: f['id'] as String, child: Text('${f['nombre']}'))],
                    onChanged: (v) => set(() { familia = v; tipo = null; })),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(key: ValueKey(familia), decoration: const InputDecoration(labelText: 'Tipo de producto'),
                    items: [for (final t in cat.tipos.where((t) => t['familia_id'] == familia)) DropdownMenuItem(value: t['id'] as String, child: Text('${t['nombre']}'))],
                    onChanged: (v) => tipo = v),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
              FilledButton(
                onPressed: () async {
                  try {
                    final r = await db.rpc('nueva_referencia', params: {'p_codigo': codigo.text, 'p_nombre': nombre.text, 'p_familia': familia, 'p_tipo': tipo});
                    if (d.mounted) Navigator.pop(d, r as String);
                  } catch (e) {
                    if (d.mounted) avisar(d, mensajeError(e), error: true);
                  }
                },
                child: const Text('Crear ficha v1'),
              ),
            ],
          )),
    );
    if (id != null && mounted) context.go('/fichas/$id');
  }
}
