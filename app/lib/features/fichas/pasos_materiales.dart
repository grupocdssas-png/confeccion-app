import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, numeroCo, Tabla, mensajeError;
import 'datos_ficha.dart';

// =====================================================================
// 4. Lista de materiales (BOM) + simulador de necesidades
// =====================================================================
class PasoMateriales extends ConsumerWidget {
  const PasoMateriales({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final cat = ref.watch(catalogoFichaProvider).value;
    final tallas = tallasFicha(f);
    final partes = ordenar(f['ficha_partes']);
    final combs = ordenar(f['ficha_combinaciones']);
    final bom = ordenar(f['ficha_bom']);
    if (tallas.isEmpty) return const Tarjeta(child: Text('Primero elija las tallas en "Datos generales".'));
    if (cat == null) return const LinearProgressIndicator();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Lista de materiales · consumo por prenda y por talla',
        accion: editable
            ? FilledButton.icon(
                onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_bom').insert({
                      'ficha_id': f['id'], 'material_id': cat.materiales.first['id'], 'orden': bom.length + 1})),
                icon: const Icon(Icons.add), label: const Text('Material'))
            : null,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
            dataRowMaxHeight: 64,
            columnSpacing: 14,
            columns: [
              const DataColumn(label: Text('Material')),
              const DataColumn(label: Text('Parte (toma su color)')),
              const DataColumn(label: Text('Combinación')),
              const DataColumn(label: Text('Color fijo')),
              for (final t in tallas) DataColumn(label: Text('${t['tallas']['codigo']}'), numeric: true),
              const DataColumn(label: Text('Unidad')),
              const DataColumn(label: Text('Merma %'), numeric: true),
              const DataColumn(label: Text('Retazo')),
              const DataColumn(label: Text('')),
            ],
            rows: [
              for (final b in bom)
                DataRow(cells: [
                  DataCell(_dd(context, ref, b, 'material_id', b['material_id'], [
                    for (final m in cat.materiales) (m['id'] as String, '${m['codigo']} · ${m['nombre']}'),
                  ], 260, nulo: false)),
                  DataCell(_dd(context, ref, b, 'parte_id', b['parte_id'], [for (final p in partes) (p['id'] as String, '${p['nombre']}')], 150)),
                  DataCell(_dd(context, ref, b, 'combinacion_id', b['combinacion_id'], [for (final c in combs) (c['id'] as String, '${c['codigo']}')], 110, textoNulo: 'Todas')),
                  DataCell(_dd(context, ref, b, 'color_fijo_id', b['color_fijo_id'], [for (final c in cat.colores) (c['id'] as String, '${c['nombre']}')], 130)),
                  for (final t in tallas)
                    DataCell(() {
                      final c = (b['ficha_bom_consumos'] as List).where((x) => x['talla_id'] == t['talla_id']).firstOrNull;
                      return CampoGuardable(
                        ancho: 72, numerico: true, alinearDerecha: true, habilitado: editable, valor: numTxt(c?['consumo']),
                        onGuardar: (s) => cambiar(context, ref, f['id'], () => db.from('ficha_bom_consumos').upsert({
                              'bom_id': b['id'], 'talla_id': t['talla_id'], 'consumo': numeroCo(s) ?? 0})),
                      );
                    }()),
                  DataCell(Text('${b['materiales']?['unidad'] ?? ''}')),
                  DataCell(CampoGuardable(ancho: 60, numerico: true, alinearDerecha: true, habilitado: editable, valor: numTxt(b['merma_pct']),
                      onGuardar: (s) => cambiar(context, ref, f['id'], () => db.from('ficha_bom').update({'merma_pct': numeroCo(s) ?? 0}).eq('id', b['id'])))),
                  DataCell(Checkbox(value: b['permite_retazo'] == true, onChanged: editable
                      ? (v) => cambiar(context, ref, f['id'], () => db.from('ficha_bom').update({'permite_retazo': v}).eq('id', b['id'])) : null)),
                  DataCell(editable ? IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_bom').delete().eq('id', b['id']))) : const SizedBox()),
                ]),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Telas: elija la parte para que el color salga de la combinación. Insumos sin parte (marquilla, bolsa) usan el color fijo o ninguno.',
            style: estilo(12.5, color: Colores.textoSuave)),
      ),
      const SizedBox(height: 8),
      _Simulador(ficha: f, tallas: tallas, combs: combs, cat: cat),
    ]);
  }

  Widget _dd(BuildContext context, WidgetRef ref, Map<String, dynamic> b, String campo, String? valor, List<(String, String)> items, double ancho,
          {bool nulo = true, String textoNulo = '—'}) =>
      SizedBox(
        width: ancho,
        child: DropdownButtonFormField<String?>(
          initialValue: valor, isDense: true, isExpanded: true,
          decoration: const InputDecoration(isDense: true),
          items: [if (nulo) DropdownMenuItem(value: null, child: Text(textoNulo)), for (final (id, t) in items) DropdownMenuItem(value: id, child: Text(t, overflow: TextOverflow.ellipsis))],
          onChanged: editable ? (v) => cambiar(context, ref, ficha['id'], () => db.from('ficha_bom').update({campo: v}).eq('id', b['id'])) : null,
        ),
      );
}

class _Simulador extends StatefulWidget {
  const _Simulador({required this.ficha, required this.tallas, required this.combs, required this.cat});
  final Map<String, dynamic> ficha;
  final List<Map<String, dynamic>> tallas, combs;
  final CatalogoFicha cat;
  @override
  State<_Simulador> createState() => _SimuladorState();
}

class _SimuladorState extends State<_Simulador> {
  final _cant = <String, TextEditingController>{};
  Future<List<Map<String, dynamic>>>? _resultado;
  TextEditingController _c(String comb, String talla) => _cant.putIfAbsent('$comb|$talla', () => TextEditingController());

  void _curva() {
    final curva = widget.cat.curvas.where((c) => c['id'] == widget.ficha['curva_id']).firstOrNull;
    final total = TextEditingController();
    showDialog(context: context, builder: (d) => AlertDialog(
          title: const Text('Repartir por curva'),
          content: TextField(controller: total, autofocus: true, decoration: InputDecoration(labelText: 'Prendas por combinación',
              helperText: curva == null ? 'La ficha no tiene curva: partes iguales' : 'Curva: ${curva['nombre']}')),
          actions: [FilledButton(onPressed: () {
            final n = int.tryParse(total.text) ?? 0;
            final pesos = {for (final t in widget.tallas) t['talla_id']: ((curva?['curva_tallas'] as List?)?.where((x) => x['talla_id'] == t['talla_id']).firstOrNull?['proporcion'] as num?) ?? (curva == null ? 1 : 0)};
            final suma = pesos.values.fold<num>(0, (a, b) => a + b);
            setState(() {
              for (final c in widget.combs) {
                for (final t in widget.tallas) {
                  _c(c['id'], t['talla_id']).text = suma == 0 ? '0' : (n * pesos[t['talla_id']]! / suma).round().toString();
                }
              }
            });
            Navigator.pop(d);
          }, child: const Text('Repartir'))],
        ));
  }

  Future<List<Map<String, dynamic>>> _calcular() async {
    final cant = {
      for (final c in widget.combs) c['id']: {for (final t in widget.tallas) t['talla_id']: int.tryParse(_c(c['id'], t['talla_id']).text) ?? 0},
    };
    final nec = (await db.rpc('necesidades_ficha', params: {'p_ficha': widget.ficha['id'], 'p_cantidades': cant}) as List).cast<Map<String, dynamic>>();
    final saldos = await db.from('saldos_por_material').select().inFilter('material_id', [for (final n in nec) n['material_id']]);
    return [
      for (final n in nec)
        {
          ...n,
          'disponible': saldos.where((s) => s['material_id'] == n['material_id'] && s['color_id'] == n['color_id']).fold<num>(0, (a, s) => a + (s['disponible'] as num)),
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mats = {for (final m in widget.cat.materiales) m['id']: m};
    final colores = {for (final c in widget.cat.colores) c['id']: c['nombre']};
    final partes = {for (final p in widget.ficha['ficha_partes'] as List) p['id']: p['nombre']};
    return Tarjeta(
      titulo: 'Simulador: cantidad y curva → necesidades de cada material',
      accion: Wrap(spacing: 8, children: [
        OutlinedButton(onPressed: _curva, child: const Text('Repartir por curva')),
        FilledButton(onPressed: () => setState(() => _resultado = _calcular()), child: const Text('Calcular')),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
            columns: [const DataColumn(label: Text('Combinación')), for (final t in widget.tallas) DataColumn(label: Text('${t['tallas']['codigo']}'))],
            rows: [
              for (final c in widget.combs)
                DataRow(cells: [
                  DataCell(Text('${c['codigo']} · ${c['nombre']}')),
                  for (final t in widget.tallas)
                    DataCell(SizedBox(width: 70, child: TextField(controller: _c(c['id'], t['talla_id']), textAlign: TextAlign.right,
                        keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, hintText: '0')))),
                ]),
            ],
          ),
        ),
        if (_resultado != null) ...[
          const SizedBox(height: 12),
          FutureBuilder(
            future: _resultado,
            builder: (_, s) {
              if (s.hasError) return Text(mensajeError(s.error!), style: estilo(13, color: Colores.rojo));
              if (!s.hasData) return const LinearProgressIndicator();
              return Tabla(
                columnas: const ['Material', 'Parte', 'Color', 'Necesidad', 'Disponible', 'Falta', 'Unidad'],
                numericas: const {3, 4, 5},
                vacio: 'Escriba cantidades y presione Calcular.',
                filas: [
                  for (final n in s.data!)
                    DataRow(cells: [
                      DataCell(Text('${mats[n['material_id']]?['nombre']}')),
                      DataCell(Text('${partes[n['parte_id']] ?? '—'}')),
                      DataCell(Text('${colores[n['color_id']] ?? '—'}')),
                      DataCell(Text(Formato.numero(n['cantidad'], decimales: 2), style: const TextStyle(fontWeight: FontWeight.w600))),
                      DataCell(Text(Formato.numero(n['disponible'], decimales: 2))),
                      DataCell(() {
                        final falta = (n['cantidad'] as num) - (n['disponible'] as num);
                        return falta > 0
                            ? Text(Formato.numero(falta, decimales: 2), style: const TextStyle(color: Colores.rojo, fontWeight: FontWeight.w600))
                            : const Pastilla('Alcanza', color: Colores.verde);
                      }()),
                      DataCell(Text('${mats[n['material_id']]?['unidad']}')),
                    ]),
                ],
              );
            },
          ),
        ],
      ]),
    );
  }
}

// =====================================================================
// 5. Artes de estampado y bordado
// =====================================================================
class PasoArtes extends ConsumerWidget {
  const PasoArtes({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final artes = ordenar(f['ficha_artes']);
    final partes = ordenar(f['ficha_partes']);
    Future<void> set(Map<String, dynamic> a, String campo, Object? v) =>
        cambiar(context, ref, f['id'], () => db.from('ficha_artes').update({campo: v}).eq('id', a['id']));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Artes de estampado y bordado: archivo, técnica, tintas o hilos, puntadas, tamaño y ubicación.', style: estilo(13.5, color: Colores.textoSuave))),
        if (editable) ...[
          OutlinedButton.icon(onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_artes').insert({'ficha_id': f['id'], 'proceso': 'estampacion', 'nombre': 'Nuevo estampado', 'orden': artes.length + 1})),
              icon: Icon(Icons.add, color: Colores.deProceso('estampacion')), label: const Text('Estampado')),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_artes').insert({'ficha_id': f['id'], 'proceso': 'bordado', 'nombre': 'Nuevo bordado', 'orden': artes.length + 1})),
              icon: Icon(Icons.add, color: Colores.deProceso('bordado')), label: const Text('Bordado')),
        ],
      ]),
      const SizedBox(height: 12),
      if (artes.isEmpty) const Tarjeta(child: Text('Esta referencia no tiene artes.')),
      for (final a in artes) ...[
        Tarjeta(
          child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Pastilla(a['proceso'] == 'bordado' ? 'Bordado' : 'Estampación', color: Colores.deProceso(a['proceso'])),
            CampoGuardable(etiqueta: 'Nombre', ancho: 240, valor: a['nombre'] ?? '', habilitado: editable, onGuardar: (v) => set(a, 'nombre', v)),
            SizedBox(width: 160, child: DropdownButtonFormField<String?>(initialValue: a['parte_id'], isDense: true,
                decoration: const InputDecoration(labelText: 'Parte', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('—')), for (final p in partes) DropdownMenuItem(value: p['id'] as String, child: Text('${p['nombre']}'))],
                onChanged: editable ? (v) => set(a, 'parte_id', v) : null)),
            CampoGuardable(etiqueta: 'Técnica', ancho: 200, valor: a['tecnica'] ?? '', habilitado: editable, onGuardar: (v) => set(a, 'tecnica', v)),
            if (a['proceso'] == 'estampacion')
              CampoGuardable(etiqueta: 'Tintas', ancho: 220, valor: a['tintas'] ?? '', habilitado: editable, onGuardar: (v) => set(a, 'tintas', v))
            else ...[
              CampoGuardable(etiqueta: 'Hilos', ancho: 200, valor: a['hilos'] ?? '', habilitado: editable, onGuardar: (v) => set(a, 'hilos', v)),
              CampoGuardable(etiqueta: 'Puntadas', ancho: 100, numerico: true, valor: '${a['puntadas'] ?? ''}', habilitado: editable,
                  onGuardar: (v) => set(a, 'puntadas', int.tryParse(v.replaceAll('.', '')))),
            ],
            CampoGuardable(etiqueta: 'Ancho cm', ancho: 90, numerico: true, valor: numTxt(a['ancho_cm']), habilitado: editable, onGuardar: (v) => set(a, 'ancho_cm', numeroCo(v))),
            CampoGuardable(etiqueta: 'Alto cm', ancho: 90, numerico: true, valor: numTxt(a['alto_cm']), habilitado: editable, onGuardar: (v) => set(a, 'alto_cm', numeroCo(v))),
            CampoGuardable(etiqueta: 'Ubicación en la prenda', ancho: 280, valor: a['ubicacion'] ?? '', habilitado: editable, onGuardar: (v) => set(a, 'ubicacion', v)),
            if (a['archivo_path'] != null) Text('Archivo: ${(a['archivo_path'] as String).split('/').last}', style: estilo(12.5)),
            if (editable) ...[
              TextButton.icon(
                icon: const Icon(Icons.upload_outlined, size: 18),
                label: Text(a['archivo_path'] == null ? 'Subir arte' : 'Reemplazar arte'),
                onPressed: () async {
                  final x = await FilePicker.pickFile();
                  if (x == null || !context.mounted) return;
                  final destino = '${f['referencia_id']}/v${f['version']}/arte_${a['id']}_${x.name}';
                  await cambiar(context, ref, f['id'], () async {
                    await db.storage.from('fichas').uploadBinary(destino, await x.readAsBytes());
                    await db.from('ficha_artes').update({'archivo_path': destino}).eq('id', a['id']);
                  }, ok: 'Arte subido');
                },
              ),
              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_artes').delete().eq('id', a['id']))),
            ],
          ]),
        ),
        const SizedBox(height: 10),
      ],
    ]);
  }
}
