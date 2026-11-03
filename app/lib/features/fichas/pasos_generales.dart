import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, numeroCo, avisar, mensajeError;
import 'datos_ficha.dart';

// =====================================================================
// 1. Datos generales
// =====================================================================
class PasoGenerales extends ConsumerWidget {
  const PasoGenerales({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final cat = ref.watch(catalogoFichaProvider).value;
    Future<void> guardar(String campo, Object? valor) =>
        cambiar(context, ref, f['id'], () => db.from('ficha_versiones').update({campo: valor}).eq('id', f['id']));
    final tallasSel = {for (final t in tallasFicha(f)) t['talla_id']};

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Descripción',
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          CampoGuardable(etiqueta: 'Descripción', ancho: 520, valor: f['descripcion'] ?? '', habilitado: editable, onGuardar: (v) => guardar('descripcion', v)),
          CampoGuardable(etiqueta: 'Precio objetivo (COP)', ancho: 200, numerico: true, valor: numTxt(f['precio_objetivo']), habilitado: editable,
              onGuardar: (v) => guardar('precio_objetivo', numeroCo(v))),
          CampoGuardable(etiqueta: 'Composición', ancho: 320, valor: f['composicion'] ?? '', habilitado: editable, onGuardar: (v) => guardar('composicion', v)),
          CampoGuardable(etiqueta: 'Instrucciones de lavado', ancho: 520, lineas: 2, valor: f['instrucciones_lavado'] ?? '', habilitado: editable,
              onGuardar: (v) => guardar('instrucciones_lavado', v)),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Tallas y curva',
        child: cat == null ? const LinearProgressIndicator() : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in cat.tallas)
              FilterChip(
                label: Text('${t['codigo']}'),
                selected: tallasSel.contains(t['id']),
                onSelected: !editable ? null : (s) => cambiar(context, ref, f['id'], () => s
                    ? db.from('ficha_tallas').insert({'ficha_id': f['id'], 'talla_id': t['id'], 'orden': t['orden']})
                    : db.from('ficha_tallas').delete().eq('ficha_id', f['id']).eq('talla_id', t['id'])),
              ),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: 360,
            child: DropdownButtonFormField<String?>(
              initialValue: f['curva_id'],
              decoration: const InputDecoration(labelText: 'Curva (para costo estándar y simulador)', isDense: true),
              items: [const DropdownMenuItem(value: null, child: Text('Partes iguales entre tallas')),
                for (final c in cat.curvas) DropdownMenuItem(value: c['id'] as String, child: Text('${c['nombre']}'))],
              onChanged: editable ? (v) => guardar('curva_id', v) : null,
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Foto, boceto técnico y molde',
        child: Wrap(spacing: 16, runSpacing: 16, children: [
          for (final (campo, nombre) in [('foto_path', 'Foto'), ('boceto_path', 'Boceto técnico'), ('molde_path', 'Molde / patrón')])
            _Archivo(ficha: f, campo: campo, nombre: nombre, editable: editable),
        ]),
      ),
    ]);
  }
}

/// Archivo en Supabase Storage (bucket "fichas"): vista previa si es imagen.
class _Archivo extends ConsumerWidget {
  const _Archivo({required this.ficha, required this.campo, required this.nombre, required this.editable});
  final Map<String, dynamic> ficha;
  final String campo, nombre;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ruta = ficha[campo] as String?;
    final esImagen = ruta != null && RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(ruta);
    return SizedBox(
      width: 220,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nombre, style: estilo(13, peso: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          height: 150,
          decoration: BoxDecoration(border: Border.all(color: Colores.borde), borderRadius: BorderRadius.circular(6), color: Colores.fondo),
          alignment: Alignment.center,
          child: ruta == null
              ? Text('Sin archivo', style: estilo(13, color: Colores.textoSuave))
              : esImagen
                  ? FutureBuilder(
                      future: db.storage.from('fichas').createSignedUrl(ruta, 3600),
                      builder: (_, s) => s.hasData ? Image.network(s.data!, fit: BoxFit.contain) : const CircularProgressIndicator(),
                    )
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.insert_drive_file_outlined, size: 40),
                      Text(ruta.split('/').last, style: estilo(12), overflow: TextOverflow.ellipsis),
                      TextButton(
                        onPressed: () async {
                          final url = await db.storage.from('fichas').createSignedUrl(ruta, 3600);
                          if (context.mounted) avisar(context, 'Enlace (1 hora): $url');
                        },
                        child: const Text('Obtener enlace'),
                      ),
                    ]),
        ),
        if (editable)
          TextButton.icon(
            icon: const Icon(Icons.upload_outlined, size: 18),
            label: Text(ruta == null ? 'Subir' : 'Reemplazar'),
            onPressed: () async {
              final a = await FilePicker.pickFile();
              if (a == null || !context.mounted) return;
              final destino = '${ficha['referencia_id']}/v${ficha['version']}/${campo.replaceAll('_path', '')}_${a.name}';
              await cambiar(context, ref, ficha['id'], () async {
                await db.storage.from('fichas').uploadBinary(destino, await a.readAsBytes());
                await db.from('ficha_versiones').update({campo: destino}).eq('id', ficha['id']);
              }, ok: '$nombre subido');
            },
          ),
      ]),
    );
  }
}

// =====================================================================
// 2. Medidas por talla con tolerancia
// =====================================================================
class PasoMedidas extends ConsumerWidget {
  const PasoMedidas({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final tallas = tallasFicha(f);
    final medidas = ordenar(f['ficha_medidas']);
    if (tallas.isEmpty) return const Tarjeta(child: Text('Primero elija las tallas en "Datos generales".'));
    return Tarjeta(
      titulo: 'Tabla de medidas (cm) · Calidad inspecciona contra esta tabla',
      accion: editable
          ? FilledButton.icon(
              onPressed: () async {
                final n = await _pedir(context, 'Nuevo punto de medida', 'Ej.: Contorno de pecho (1/2)');
                if (n != null && context.mounted) {
                  await cambiar(context, ref, f['id'], () => db.from('ficha_medidas').insert({'ficha_id': f['id'], 'punto_medida': n, 'orden': medidas.length + 1}));
                }
              },
              icon: const Icon(Icons.add), label: const Text('Punto de medida'))
          : null,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
          dataRowMaxHeight: 60,
          columns: [
            const DataColumn(label: Text('Punto de medida')),
            for (final t in tallas) DataColumn(label: Text('${t['tallas']['codigo']}'), numeric: true),
            const DataColumn(label: Text('Tolerancia ±')),
            const DataColumn(label: Text('')),
          ],
          rows: [
            for (final m in medidas)
              DataRow(cells: [
                DataCell(Text('${m['punto_medida']}')),
                for (final t in tallas)
                  DataCell(() {
                    final v = (m['ficha_medida_tallas'] as List).where((x) => x['talla_id'] == t['talla_id']).firstOrNull;
                    return CampoGuardable(
                      ancho: 76, numerico: true, alinearDerecha: true, habilitado: editable, valor: numTxt(v?['valor_cm']),
                      onGuardar: (s) => cambiar(context, ref, f['id'], () => db.from('ficha_medida_tallas').upsert({
                        'medida_id': m['id'], 'talla_id': t['talla_id'], 'valor_cm': numeroCo(s),
                        'tolerancia_cm': v?['tolerancia_cm'] ?? _tolerancia(m) ?? 1,
                      })),
                    );
                  }()),
                DataCell(CampoGuardable(
                  ancho: 70, numerico: true, alinearDerecha: true, habilitado: editable && (m['ficha_medida_tallas'] as List).isNotEmpty,
                  valor: numTxt(_tolerancia(m)),
                  onGuardar: (s) => cambiar(context, ref, f['id'], () => db.from('ficha_medida_tallas').update({'tolerancia_cm': numeroCo(s)}).eq('medida_id', m['id'])),
                )),
                DataCell(editable
                    ? IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_medidas').delete().eq('id', m['id'])))
                    : const SizedBox()),
              ]),
          ],
        ),
      ),
    );
  }

  static num? _tolerancia(Map<String, dynamic> m) => (m['ficha_medida_tallas'] as List).firstOrNull?['tolerancia_cm'];
}

Future<String?> _pedir(BuildContext context, String titulo, String ayuda) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
        title: Text(titulo),
        content: SizedBox(width: 400, child: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: ayuda))),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isNotEmpty), child: const Text('Agregar'))],
      ));
  return ok == true ? c.text.trim() : null;
}

// =====================================================================
// 3. Partes y combinaciones de color
// =====================================================================
class PasoPartes extends ConsumerWidget {
  const PasoPartes({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final cat = ref.watch(catalogoFichaProvider).value;
    final partes = ordenar(f['ficha_partes']);
    final combs = ordenar(f['ficha_combinaciones']);
    final telas = (cat?.materiales ?? []).where((m) => m['tipo'] == 'tela').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Partes de la prenda',
        accion: editable
            ? FilledButton.icon(onPressed: () async {
                final n = await _pedir(context, 'Nueva parte', 'Ej.: Cuerpo, Mangas y capota, Bolsillo');
                if (n != null && context.mounted) await cambiar(context, ref, f['id'], () => db.from('ficha_partes').insert({'ficha_id': f['id'], 'nombre': n, 'orden': partes.length + 1}));
              }, icon: const Icon(Icons.add), label: const Text('Parte'))
            : null,
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          if (partes.isEmpty) Text('Agregue las partes (cuerpo, mangas, cuello…). En prenda combinada cada parte se corta aparte.', style: estilo(13.5, color: Colores.textoSuave)),
          for (final p in partes)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(border: Border.all(color: Colores.borde), borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${p['nombre']}', style: estilo(14, peso: FontWeight.w600)),
                const SizedBox(width: 10),
                Checkbox(value: p['puede_cortarse_retazo'] == true, onChanged: editable
                    ? (v) => cambiar(context, ref, f['id'], () => db.from('ficha_partes').update({'puede_cortarse_retazo': v}).eq('id', p['id'])) : null),
                Text('Se puede cortar de retazos', style: estilo(12.5)),
                if (editable) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_partes').delete().eq('id', p['id']))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Combinaciones de color por parte',
        accion: editable && partes.isNotEmpty
            ? FilledButton.icon(onPressed: () => _nuevaCombinacion(context, ref, combs.length), icon: const Icon(Icons.add), label: const Text('Combinación'))
            : null,
        child: cat == null ? const LinearProgressIndicator() : partes.isEmpty
            ? Text('Primero agregue las partes.', style: estilo(13.5, color: Colores.textoSuave))
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
                  dataRowMaxHeight: 110,
                  columns: [const DataColumn(label: Text('Combinación')), for (final p in partes) DataColumn(label: Text('${p['nombre']}')), const DataColumn(label: Text(''))],
                  rows: [
                    for (final c in combs)
                      DataRow(cells: [
                        DataCell(Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${c['codigo']}', style: estiloCodigo(13)),
                          Text('${c['nombre']}', style: estilo(13)),
                        ])),
                        for (final p in partes)
                          DataCell(() {
                            final cp = (c['ficha_combinacion_partes'] as List).where((x) => x['parte_id'] == p['id']).firstOrNull;
                            Future<void> set(Map<String, dynamic> d) => cambiar(context, ref, f['id'], () => db.from('ficha_combinacion_partes').upsert({
                                  'combinacion_id': c['id'], 'parte_id': p['id'], 'material_id': cp?['material_id'], 'color_id': cp?['color_id'], ...d,
                                }));
                            return SizedBox(width: 210, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              DropdownButtonFormField<String>(
                                initialValue: cp?['color_id'], isDense: true, isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Color', isDense: true),
                                items: [for (final x in cat.colores) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
                                onChanged: editable ? (v) => set({'color_id': v}) : null,
                              ),
                              const SizedBox(height: 4),
                              DropdownButtonFormField<String?>(
                                initialValue: cp?['material_id'], isDense: true, isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Tela', isDense: true),
                                items: [const DropdownMenuItem(value: null, child: Text('—')),
                                  for (final x in telas) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}', overflow: TextOverflow.ellipsis))],
                                onChanged: editable && cp != null ? (v) => set({'material_id': v}) : null,
                              ),
                            ]));
                          }()),
                        DataCell(editable ? IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_combinaciones').delete().eq('id', c['id']))) : const SizedBox()),
                      ]),
                  ],
                ),
              ),
      ),
    ]);
  }

  Future<void> _nuevaCombinacion(BuildContext context, WidgetRef ref, int n) async {
    final codigo = TextEditingController(), nombre = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
          title: const Text('Nueva combinación'),
          content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: codigo, decoration: const InputDecoration(labelText: 'Código', hintText: 'N, GJ, AZM-B…')),
            const SizedBox(height: 10),
            TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Negro con cuello gris')),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Agregar'))],
        ));
    if (ok == true && context.mounted) {
      await cambiar(context, ref, ficha['id'], () => db.from('ficha_combinaciones').insert({
            'ficha_id': ficha['id'], 'codigo': codigo.text.trim().toUpperCase(), 'nombre': nombre.text.trim(), 'orden': n + 1}));
    }
  }
}

// Exportado para otros pasos
String formatoCop(num? v) => v == null ? '—' : Formato.cop(v);
void avisoError(BuildContext c, Object e) => avisar(c, mensajeError(e), error: true);
