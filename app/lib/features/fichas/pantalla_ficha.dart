import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, mensajeError, avisar;
import 'datos_ficha.dart';
import 'ficha_pdf.dart';
import 'pantalla_fichas.dart' show pastillaEstadoFicha;
import 'pasos_generales.dart';
import 'pasos_materiales.dart';
import 'pasos_ruta_costo.dart';

const pasosFicha = ['1. Datos generales', '2. Medidas', '3. Partes y combinaciones', '4. Materiales', '5. Artes', '6. Ruta y operaciones', '7. Costo y aprobación'];

/// Editor de una versión de ficha técnica (7 pasos).
class PantallaFicha extends ConsumerStatefulWidget {
  const PantallaFicha({super.key, required this.id, this.paso = 0});
  final String id;
  final int paso;
  @override
  ConsumerState<PantallaFicha> createState() => _PantallaFichaState();
}

class _PantallaFichaState extends ConsumerState<PantallaFicha> {
  late var _paso = widget.paso;

  @override
  Widget build(BuildContext context) {
    final ficha = ref.watch(fichaProvider(widget.id));
    return ficha.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (f) {
        final r = f['referencias'];
        final editable = fichaEditable(ref, f);
        final puedeEditar = ref.watch(sesionProvider).value?.puedeEditar('ficha_tecnica') ?? false;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('${r['codigo']} · ${r['nombre']}',
              subtitulo: 'Versión ${f['version']}${f['basada_en_id'] != null ? ' (basada en una versión anterior)' : ''} · '
                  '${[r['familias_producto']?['nombre'], r['tipos_producto']?['nombre']].whereType<String>().join(' · ')}',
              acciones: [
                pastillaEstadoFicha('${f['estado']}'),
                OutlinedButton(onPressed: () => context.go('/fichas'), child: const Text('Volver')),
                OutlinedButton.icon(onPressed: () async {
                  final cat = await ref.read(catalogoFichaProvider.future);
                  registrarColoresPdf(cat.colores);
                  if (context.mounted) await exportarFichaPdf(context, f);
                }, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('PDF')),
                if (puedeEditar && f['estado'] != 'borrador' && f['estado'] != 'en_aprobacion')
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        final nueva = await db.rpc('copiar_ficha', params: {'p_origen': f['id']});
                        if (context.mounted) context.go('/fichas/$nueva');
                      } catch (e) {
                        if (context.mounted) avisar(context, mensajeError(e), error: true);
                      }
                    },
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('Nueva versión'),
                  ),
                if (puedeEditar)
                  OutlinedButton.icon(onPressed: () => _duplicar(f), icon: const Icon(Icons.copy_all_outlined), label: const Text('Duplicar a otra referencia')),
              ]),
          if (f['comentario_rechazo'] != null && f['estado'] == 'borrador')
            AvisoSinConexion('Devuelta por ${f['comentario_rechazo']}'),
          if (!editable && f['estado'] == 'aprobada')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Esta versión está aprobada y congelada. Para cambiarla cree una nueva versión; las OP existentes conservan esta.',
                  style: estilo(13.5, color: Colores.textoSuave)),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < pasosFicha.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(pasosFicha[i]),
                    selected: _paso == i,
                    showCheckmark: false,
                    selectedColor: Colores.deProceso('diseno'),
                    labelStyle: estilo(13.5, peso: FontWeight.w600, color: _paso == i ? Colors.white : Colores.texto),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: Colores.borde),
                    onSelected: (_) => setState(() => _paso = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          switch (_paso) {
            0 => PasoGenerales(ficha: f, editable: editable),
            1 => PasoMedidas(ficha: f, editable: editable),
            2 => PasoPartes(ficha: f, editable: editable),
            3 => PasoMateriales(ficha: f, editable: editable),
            4 => PasoArtes(ficha: f, editable: editable),
            5 => PasoRuta(ficha: f, editable: editable),
            _ => PasoCosto(ficha: f, editable: editable),
          },
          const SizedBox(height: 16),
          Row(children: [
            if (_paso > 0) OutlinedButton.icon(onPressed: () => setState(() => _paso--), icon: const Icon(Icons.chevron_left), label: const Text('Anterior')),
            const Spacer(),
            if (_paso < pasosFicha.length - 1)
              FilledButton.icon(onPressed: () => setState(() => _paso++), icon: const Icon(Icons.chevron_right), label: Text(pasosFicha[_paso + 1])),
          ]),
        ]);
      },
    );
  }

  Future<void> _duplicar(Map<String, dynamic> f) async {
    final codigo = TextEditingController(), nombre = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Duplicar a otra referencia'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Se copia toda la ficha (v${f['version']}) como versión 1 de una referencia nueva.'),
          const SizedBox(height: 10),
          TextField(controller: codigo, decoration: const InputDecoration(labelText: 'Código de la referencia nueva')),
          const SizedBox(height: 10),
          TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Duplicar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = f['referencias'];
      final nueva = await db.from('referencias').insert({
        'codigo': codigo.text.trim().toUpperCase(), 'nombre': nombre.text.trim(),
        'familia_id': r['familia_id'], 'tipo_producto_id': r['tipo_producto_id'], 'linea_id': r['linea_id'], 'coleccion_id': r['coleccion_id'],
      }).select('id').single();
      final id = await db.rpc('copiar_ficha', params: {'p_origen': f['id'], 'p_referencia_destino': nueva['id']});
      if (mounted) context.go('/fichas/$id');
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}
