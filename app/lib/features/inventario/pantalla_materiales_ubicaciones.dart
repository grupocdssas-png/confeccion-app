import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'comun_inventario.dart';
import 'etiquetas_inventario_web.dart';

final _materialesProvider = FutureProvider.autoDispose((ref) => db
    .from('materiales')
    .select('*, categorias_material(nombre), proveedores(nombre)')
    .order('tipo', ascending: false)
    .order('nombre', ascending: true));

class PantallaMateriales extends ConsumerWidget {
  const PantallaMateriales({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_materialesProvider);
    final editar = puedeEditarInventario(ref);
    Future<void> abrir([Map<String, dynamic>? m]) async {
      final ok = await showDialog<bool>(context: context, builder: (_) => _DialogoMaterial(material: m));
      if (ok == true) {
        ref.invalidate(_materialesProvider);
        ref.invalidate(catalogosProvider);
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Materiales', subtitulo: 'Maestro de telas (sin color: el color, lote y tono van en el rollo) e insumos', acciones: [
        if (editar) FilledButton.icon(onPressed: abrir, icon: const Icon(Icons.add), label: const Text('Nuevo material')),
      ]),
      const PestanasInventario('materiales'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e)),
        data: (filas) => Tarjeta(
          padding: EdgeInsets.zero,
          child: Tabla(
            columnas: const ['Código', 'Nombre', 'Tipo', 'Categoría', 'Unidad', 'Ancho', 'Gramaje', 'm/kg', 'Costo estándar', 'Mínimo', 'Proveedor', ''],
            numericas: const {5, 6, 7, 8, 9},
            filas: [
              for (final m in filas)
                DataRow(cells: [
                  DataCell(Text('${m['codigo']}', style: estiloCodigo(13))),
                  DataCell(Text('${m['nombre']}')),
                  DataCell(Pastilla(m['tipo'] == 'tela' ? 'Tela' : 'Insumo', color: m['tipo'] == 'tela' ? Colores.deProceso('corte') : Colores.textoSuave)),
                  DataCell(Text('${m['categorias_material']?['nombre'] ?? '—'}')),
                  DataCell(Text('${m['unidad']}')),
                  DataCell(Text(m['ancho_nominal_cm'] == null ? '—' : '${Formato.numero(m['ancho_nominal_cm'], decimales: 0)} cm')),
                  DataCell(Text(m['gramaje_gm2'] == null ? '—' : '${Formato.numero(m['gramaje_gm2'], decimales: 0)} g/m²')),
                  DataCell(Text(m['rendimiento_m_kg'] == null ? '—' : Formato.dos(m['rendimiento_m_kg']))),
                  DataCell(Text(m['costo_estandar'] == null ? '—' : Formato.cop(m['costo_estandar']))),
                  DataCell(Text(m['stock_minimo'] == null ? '—' : Formato.numero(m['stock_minimo'], decimales: 0))),
                  DataCell(Text('${m['proveedores']?['nombre'] ?? '—'}')),
                  DataCell(editar ? TextButton(onPressed: () => abrir(m), child: const Text('Editar')) : const SizedBox()),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _DialogoMaterial extends ConsumerStatefulWidget {
  const _DialogoMaterial({this.material});
  final Map<String, dynamic>? material;
  @override
  ConsumerState<_DialogoMaterial> createState() => _DialogoMaterialState();
}

class _DialogoMaterialState extends ConsumerState<_DialogoMaterial> {
  late final m = widget.material;
  late var _tipo = m?['tipo'] ?? 'tela';
  late var _unidad = m?['unidad'] ?? 'kg';
  late String? _categoria = m?['categoria_id'];
  late String? _proveedor = m?['proveedor_id'];
  late var _color = m?['maneja_color'] ?? true;
  late final _c = {
    for (final k in ['codigo', 'nombre', 'composicion', 'ancho_nominal_cm', 'gramaje_gm2', 'rendimiento_m_kg', 'costo_estandar', 'stock_minimo'])
      k: TextEditingController(text: m?[k] == null ? '' : '${m![k]}'.replaceAll('.', ',')),
  };
  String? _error;

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogosProvider).value;
    final esTela = _tipo == 'tela';
    Widget t(String k, String et, {double w = 200}) =>
        SizedBox(width: w, child: TextField(controller: _c[k], decoration: InputDecoration(labelText: et, isDense: true)));
    return AlertDialog(
      title: Text(m == null ? 'Nuevo material' : 'Editar ${m!['codigo']}'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'tela', label: Text('Tela')), ButtonSegment(value: 'insumo', label: Text('Insumo'))],
              selected: {_tipo},
              onSelectionChanged: m != null ? null : (s) => setState(() {
                _tipo = s.first;
                _unidad = _tipo == 'tela' ? 'kg' : 'und';
              }),
            ),
            t('codigo', 'Código', w: 160),
            t('nombre', 'Nombre', w: 420),
            SizedBox(
              width: 140,
              child: DropdownButtonFormField<String>(
                initialValue: _unidad,
                decoration: const InputDecoration(labelText: 'Unidad', isDense: true),
                items: [for (final u in esTela ? ['kg', 'm'] : ['und', 'm', 'kg', 'g', 'cono', 'par', 'ml']) DropdownMenuItem(value: u, child: Text(u))],
                onChanged: (v) => setState(() => _unidad = v!),
              ),
            ),
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                initialValue: _categoria,
                decoration: const InputDecoration(labelText: 'Categoría', isDense: true),
                items: [for (final c in (cat?.categorias ?? []).where((c) => c['tipo'] == _tipo)) DropdownMenuItem(value: c['id'] as String, child: Text('${c['nombre']}'))],
                onChanged: (v) => _categoria = v,
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                initialValue: _proveedor,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Proveedor habitual', isDense: true),
                items: [for (final p in cat?.proveedores ?? []) DropdownMenuItem(value: p['id'] as String, child: Text('${p['nombre']}', overflow: TextOverflow.ellipsis))],
                onChanged: (v) => _proveedor = v,
              ),
            ),
            if (esTela) ...[
              t('composicion', 'Composición', w: 280),
              t('ancho_nominal_cm', 'Ancho nominal (cm)', w: 150),
              t('gramaje_gm2', 'Gramaje (g/m²)', w: 130),
              t('rendimiento_m_kg', 'Rendimiento (m/kg)', w: 150),
            ] else
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(value: _color, onChanged: (v) => setState(() => _color = v!)),
                const Text('Se maneja por color'),
              ]),
            t('costo_estandar', 'Costo estándar (COP por $_unidad)', w: 230),
            t('stock_minimo', 'Stock mínimo ($_unidad)', w: 170),
            if (_error != null) Text(_error!, style: estilo(13, color: Colores.rojo)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () async {
            final datos = {
              'codigo': _c['codigo']!.text.trim().toUpperCase(),
              'nombre': _c['nombre']!.text.trim(),
              'tipo': _tipo, 'unidad': _unidad, 'categoria_id': _categoria, 'proveedor_id': _proveedor,
              'maneja_rollos': _tipo == 'tela', 'maneja_color': _tipo == 'tela' ? true : _color,
              'composicion': _c['composicion']!.text.trim().isEmpty ? null : _c['composicion']!.text.trim(),
              for (final k in ['ancho_nominal_cm', 'gramaje_gm2', 'rendimiento_m_kg', 'costo_estandar', 'stock_minimo']) k: numeroCo(_c[k]!.text),
            };
            try {
              if (m == null) {
                await db.from('materiales').insert(datos);
              } else {
                await db.from('materiales').update(datos).eq('id', m!['id']);
              }
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              setState(() => _error = mensajeError(e));
            }
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// =====================================================================
// Ubicaciones
// =====================================================================
final _ubicacionesProvider = FutureProvider.autoDispose((ref) => db
    .from('ubicaciones')
    .select('*, bodegas(nombre, codigo)')
    .order('codigo', ascending: true));

class PantallaUbicaciones extends ConsumerStatefulWidget {
  const PantallaUbicaciones({super.key});
  @override
  ConsumerState<PantallaUbicaciones> createState() => _PantallaUbicacionesState();
}

class _PantallaUbicacionesState extends ConsumerState<PantallaUbicaciones> {
  final _sel = <String>{};

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_ubicacionesProvider);
    final lista = datos.value ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Ubicaciones de bodega', subtitulo: 'Cada estante o zona con su etiqueta UB-… para escanear', acciones: [
        OutlinedButton.icon(
          onPressed: _sel.isEmpty ? null : () => imprimirUbicacionesWeb(context, lista.where((u) => _sel.contains(u['id'])).toList()),
          icon: const Icon(Icons.print_outlined),
          label: Text('Imprimir ${_sel.length} etiquetas'),
        ),
        if (puedeEditarInventario(ref))
          FilledButton.icon(onPressed: _nueva, icon: const Icon(Icons.add), label: const Text('Nueva ubicación')),
      ]),
      const PestanasInventario('ubicaciones'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e)),
        data: (filas) => Tarjeta(
          padding: EdgeInsets.zero,
          child: Tabla(
            columnas: const ['', 'Código', 'Bodega', 'Descripción', 'Estado'],
            filas: [
              for (final u in filas)
                DataRow(cells: [
                  DataCell(Checkbox(value: _sel.contains(u['id']), onChanged: (v) => setState(() => v! ? _sel.add(u['id']) : _sel.remove(u['id'])))),
                  DataCell(Text('${u['codigo']}', style: estiloCodigo(13))),
                  DataCell(Text('${u['bodegas']['nombre']}')),
                  DataCell(Text('${u['descripcion'] ?? ''}')),
                  DataCell(u['activo'] == true ? const Pastilla('Activa', color: Colores.verde) : const Pastilla('Inactiva', color: Colores.textoSuave)),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }

  Future<void> _nueva() async {
    final cat = await ref.read(catalogosProvider.future);
    if (!mounted) return;
    String? bodega;
    final codigo = TextEditingController(text: 'UB-'), desc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Nueva ubicación'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Bodega'),
              items: [for (final b in cat.bodegas) DropdownMenuItem(value: b['id'] as String, child: Text('${b['nombre']}'))],
              onChanged: (v) => bodega = v,
            ),
            const SizedBox(height: 10),
            TextField(controller: codigo, decoration: const InputDecoration(labelText: 'Código', hintText: 'UB-BT-C01')),
            const SizedBox(height: 10),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'Descripción')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await db.from('ubicaciones').insert({'bodega_id': bodega, 'codigo': codigo.text.trim().toUpperCase(), 'descripcion': desc.text.trim()});
      ref.invalidate(_ubicacionesProvider);
      ref.invalidate(catalogosProvider);
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }
}
