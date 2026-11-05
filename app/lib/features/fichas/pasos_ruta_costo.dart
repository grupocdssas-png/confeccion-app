import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, numeroCo, Tabla, pedirTexto;
import 'datos_ficha.dart';
import 'importar_secuencia.dart';

// =====================================================================
// 6. Ruta de procesos + secuencia de operaciones
// =====================================================================
class PasoRuta extends ConsumerWidget {
  const PasoRuta({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ficha;
    final cat = ref.watch(catalogoFichaProvider).value;
    if (cat == null) return const LinearProgressIndicator();
    final ruta = {for (final r in f['ficha_ruta'] as List) r['proceso']: r as Map<String, dynamic>};
    final ops = ordenar(f['ficha_operaciones'], 'secuencia');
    final partes = ordenar(f['ficha_partes']);
    final samTotal = ops.where((o) => o['agrega_minutos_sam'] == true).fold<double>(0, (a, o) => a + (o['sam'] as num) * (o['repeticiones'] as num));
    Future<void> setRuta(String proceso, Map<String, dynamic> d) =>
        cambiar(context, ref, f['id'], () => db.from('ficha_ruta').update(d).eq('ficha_id', f['id']).eq('proceso', proceso));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Ruta de procesos (cuáles aplican y en qué orden)',
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final p in cat.procesos.where((p) => p['codigo'] != 'diseno'))
            Container(
              width: 250,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: ruta.containsKey(p['codigo']) ? Colores.deProceso(p['codigo']) : Colores.borde, width: ruta.containsKey(p['codigo']) ? 2 : 1),
                borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Checkbox(
                    value: ruta.containsKey(p['codigo']),
                    onChanged: !editable ? null : (v) => cambiar(context, ref, f['id'], () => v!
                        ? db.from('ficha_ruta').insert({'ficha_id': f['id'], 'proceso': p['codigo'], 'orden': p['orden']})
                        : db.from('ficha_ruta').delete().eq('ficha_id', f['id']).eq('proceso', p['codigo'])),
                  ),
                  Expanded(child: Text('${p['nombre']}', style: estilo(14, peso: FontWeight.w600, color: Colores.deProceso(p['codigo'])))),
                  if (ruta.containsKey(p['codigo']))
                    CampoGuardable(ancho: 66, etiqueta: 'Orden', numerico: true, habilitado: editable, valor: '${ruta[p['codigo']]!['orden']}',
                        onGuardar: (v) => setRuta(p['codigo'], {'orden': int.tryParse(v) ?? 0})),
                ]),
                if (ruta.containsKey(p['codigo'])) ...[
                  DropdownButtonFormField<String>(
                    initialValue: ruta[p['codigo']]!['modalidad'], isDense: true,
                    decoration: const InputDecoration(labelText: 'Modalidad', isDense: true),
                    items: const [DropdownMenuItem(value: 'interno', child: Text('Interno')), DropdownMenuItem(value: 'satelite', child: Text('Satélite')),
                      DropdownMenuItem(value: 'ambos', child: Text('Interno o satélite'))],
                    onChanged: editable ? (v) => setRuta(p['codigo'], {'modalidad': v}) : null,
                  ),
                  if (ruta[p['codigo']]!['modalidad'] != 'interno')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: CampoGuardable(etiqueta: 'Costo externo por prenda (COP)', ancho: 228, numerico: true, habilitado: editable,
                          valor: numTxt(ruta[p['codigo']]!['costo_externo_unidad']),
                          onGuardar: (v) => setRuta(p['codigo'], {'costo_externo_unidad': numeroCo(v) ?? 0})),
                    ),
                ],
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Secuencia de operaciones · SAM total ${Formato.numero(samTotal, decimales: 3)} min',
        accion: editable
            ? Wrap(spacing: 8, children: [
                OutlinedButton.icon(onPressed: () => importarSecuenciaSammu(context, ref, f), icon: const Icon(Icons.upload_file), label: const Text('Importar de SAMMU')),
                FilledButton.icon(onPressed: () => _agregar(context, ref, ops), icon: const Icon(Icons.add), label: const Text('Agregar operaciones')),
              ])
            : null,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
            dataRowMaxHeight: 58,
            columnSpacing: 14,
            columns: const [
              DataColumn(label: Text('Sec.'), numeric: true), DataColumn(label: Text('Código')), DataColumn(label: Text('Operación')),
              DataColumn(label: Text('Proceso')), DataColumn(label: Text('Parte')), DataColumn(label: Text('SAM'), numeric: true),
              DataColumn(label: Text('Und/h'), numeric: true), DataColumn(label: Text('Máquina')),
              DataColumn(label: Text('Rep.'), numeric: true), DataColumn(label: Text('Contadora')), DataColumn(label: Text('')),
            ],
            rows: [
              for (final o in ops)
                DataRow(cells: [
                  DataCell(CampoGuardable(ancho: 60, numerico: true, alinearDerecha: true, habilitado: editable, valor: '${o['secuencia']}',
                      onGuardar: (v) => cambiar(context, ref, f['id'], () => db.from('ficha_operaciones').update({'secuencia': int.tryParse(v)}).eq('id', o['id'])))),
                  DataCell(Text('${o['operaciones']?['codigo']}', style: estiloCodigo(12.5))),
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${o['operaciones']?['nombre']}'),
                    if (o['operaciones']?['sam'] != o['sam'])
                      Tooltip(message: 'En la lista maestra el SAM es ${o['operaciones']?['sam']}; esta ficha usa el suyo',
                          child: const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.info_outline, size: 16, color: Colores.ambar))),
                  ])),
                  DataCell(Pastilla(Colores.nombreProceso(o['proceso']), color: Colores.deProceso(o['proceso']))),
                  DataCell(SizedBox(width: 120, child: DropdownButtonFormField<String?>(
                    initialValue: o['parte_id'], isDense: true, isExpanded: true, decoration: const InputDecoration(isDense: true),
                    items: [const DropdownMenuItem(value: null, child: Text('—')), for (final p in partes) DropdownMenuItem(value: p['id'] as String, child: Text('${p['nombre']}'))],
                    onChanged: editable ? (v) => cambiar(context, ref, f['id'], () => db.from('ficha_operaciones').update({'parte_id': v}).eq('id', o['id'])) : null,
                  ))),
                  DataCell(CampoGuardable(ancho: 78, numerico: true, alinearDerecha: true, habilitado: editable, valor: numTxt(o['sam']),
                      onGuardar: (v) => cambiar(context, ref, f['id'], () => db.from('ficha_operaciones').update({'sam': numeroCo(v)}).eq('id', o['id'])))),
                  DataCell(Text(Formato.numero(60 / (o['sam'] as num), decimales: 1))),
                  DataCell(Text('${o['tipos_maquina']?['codigo'] ?? '—'}', style: estiloCodigo(12.5, peso: FontWeight.w400))),
                  DataCell(CampoGuardable(ancho: 56, numerico: true, alinearDerecha: true, habilitado: editable, valor: numTxt(o['repeticiones']),
                      onGuardar: (v) => cambiar(context, ref, f['id'], () => db.from('ficha_operaciones').update({'repeticiones': numeroCo(v) ?? 1}).eq('id', o['id'])))),
                  DataCell(IconButton(
                    tooltip: 'Operación contadora',
                    icon: Icon(o['es_contadora'] == true ? Icons.star : Icons.star_border, color: o['es_contadora'] == true ? Colores.ambar : Colores.textoSuave),
                    onPressed: !editable ? null : () => cambiar(context, ref, f['id'], () async {
                      await db.from('ficha_operaciones').update({'es_contadora': false}).eq('ficha_id', f['id']);
                      if (o['es_contadora'] != true) await db.from('ficha_operaciones').update({'es_contadora': true}).eq('id', o['id']);
                    }),
                  )),
                  DataCell(editable ? IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => cambiar(context, ref, f['id'], () => db.from('ficha_operaciones').delete().eq('id', o['id']))) : const SizedBox()),
                ]),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('La operación contadora es la que cuenta prendas terminadas en la célula (normalmente la última de confección). '
            'Para reordenar, cambie el número de secuencia.', style: estilo(12.5, color: Colores.textoSuave)),
      ),
    ]);
  }

  Future<void> _agregar(BuildContext context, WidgetRef ref, List<Map<String, dynamic>> actuales) async {
    final cat = ref.read(catalogoFichaProvider).value!;
    final familia = ficha['referencias']?['familia_id'];
    final ya = {for (final o in actuales) o['operacion_id']};
    final sel = <String>{};
    var filtro = '';
    var soloFamilia = familia != null;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) {
          final lista = cat.operaciones.where((o) => (!soloFamilia || o['familia_id'] == familia) &&
              '${o['codigo']} ${o['nombre']}'.toLowerCase().contains(filtro)).toList();
          final disponibles = lista.where((o) => !ya.contains(o['id'])).toList();
          return AlertDialog(
            title: const Text('Agregar operaciones de la lista maestra'),
            content: SizedBox(
              width: 760, height: 520,
              child: Column(children: [
                Row(children: [
                  Expanded(child: TextField(autofocus: true, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar', isDense: true),
                      onChanged: (v) => set(() => filtro = v.toLowerCase()))),
                  if (familia != null) ...[
                    const SizedBox(width: 8),
                    FilterChip(label: const Text('Solo su familia'), selected: soloFamilia, onSelected: (v) => set(() => soloFamilia = v)),
                  ],
                  TextButton(onPressed: () => set(() => sel.length == disponibles.length ? sel.clear() : sel.addAll([for (final o in disponibles) o['id'] as String])),
                      child: Text(sel.length == disponibles.length && disponibles.isNotEmpty ? 'Quitar todas' : 'Seleccionar todas')),
                ]),
                const SizedBox(height: 8),
                Expanded(child: ListView(children: [
                  for (final o in lista)
                    CheckboxListTile(
                      dense: true,
                      value: ya.contains(o['id']) || sel.contains(o['id']),
                      onChanged: ya.contains(o['id']) ? null : (v) => set(() => v! ? sel.add(o['id']) : sel.remove(o['id'])),
                      title: Text('${o['codigo']} · ${o['nombre']}'),
                      subtitle: Text('SAM ${Formato.numero(o['sam'], decimales: 3)} · ${o['tipos_maquina']?['codigo'] ?? '—'} · ${o['proceso']}'
                          '${ya.contains(o['id']) ? ' · ya agregada' : ''}'),
                    ),
                ])),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
              FilledButton(onPressed: sel.isEmpty ? null : () => Navigator.pop(d, true), child: Text('Agregar ${sel.length} operaciones')),
            ],
          );
        }));
    if (ok != true || !context.mounted) return;
    var sec = actuales.fold<int>(0, (a, o) => (o['secuencia'] as int) > a ? o['secuencia'] as int : a);
    final orden = cat.operaciones.where((o) => sel.contains(o['id'])).toList();
    await cambiar(context, ref, ficha['id'], () => db.from('ficha_operaciones').insert([
          for (final o in orden) {'ficha_id': ficha['id'], 'operacion_id': o['id'], 'secuencia': sec += 10, 'proceso': o['proceso']},
        ]));
  }
}

// =====================================================================
// 7. Costo estándar y aprobación
// =====================================================================
class PasoCosto extends ConsumerStatefulWidget {
  const PasoCosto({super.key, required this.ficha, required this.editable});
  final Map<String, dynamic> ficha;
  final bool editable;
  @override
  ConsumerState<PasoCosto> createState() => _PasoCostoState();
}

class _PasoCostoState extends ConsumerState<PasoCosto> {
  late Future<(List<Map<String, dynamic>>, List<String>, List<Map<String, dynamic>>)> _datos = _cargar();

  @override
  void didUpdateWidget(covariant PasoCosto old) {
    super.didUpdateWidget(old);
    if (old.ficha != widget.ficha) _datos = _cargar();
  }

  Future<(List<Map<String, dynamic>>, List<String>, List<Map<String, dynamic>>)> _cargar() async {
    final f = widget.ficha;
    final faltan = (await db.rpc('validar_ficha', params: {'p_ficha': f['id']}) as List).cast<String>();
    // Costo con los valores de hoy (valor minuto vigente y costos de materiales actuales)
    var hoy = <Map<String, dynamic>>[];
    try {
      hoy = (await db.rpc('calcular_costo_estandar', params: {'p_ficha': f['id']}) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
    if (f['estado'] != 'borrador') {
      // costo congelado al enviar a aprobación
      final filas = (f['ficha_costo_estandar'] as List).cast<Map<String, dynamic>>();
      final porComb = <String, Map<String, dynamic>>{};
      for (final x in filas) {
        final c = porComb.putIfAbsent(x['combinacion_id'], () => {'combinacion_id': x['combinacion_id']});
        c[x['concepto']] = x['valor'];
        if (x['concepto'] == 'materiales') c['detalle'] = x['detalle']; // incluye materiales, SAM y valor minuto
      }
      return (porComb.values.toList(), faltan, hoy);
    }
    return (hoy, faltan, hoy);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.ficha;
    final sesion = ref.watch(sesionProvider).value;
    final combs = {for (final c in f['ficha_combinaciones'] as List) c['id']: c};
    final precio = (f['precio_objetivo'] as num?)?.toDouble();
    return FutureBuilder(
      future: _datos,
      builder: (context, s) {
        if (!s.hasData) return const LinearProgressIndicator();
        final (costos, faltan, hoy) = s.data!;
        final totalHoy = {for (final c in hoy) c['combinacion_id']: c['total']};
        final congelado = f['estado'] != 'borrador';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Tarjeta(
            titulo: f['estado'] == 'borrador' ? 'Costo estándar por prenda (cálculo en vivo)' : 'Costo estándar por prenda (congelado al enviar a aprobación)',
            child: costos.isEmpty
                ? Text('Complete tallas, combinaciones y materiales para calcular el costo.', style: estilo(14, color: Colores.textoSuave))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Tabla(
                      columnas: [
                        'Combinación', 'Materiales', 'Mano de obra', 'Procesos externos', 'Indirectos', congelado ? 'Total aprobado' : 'Total',
                        if (congelado) 'Total hoy', 'Margen',
                      ],
                      numericas: congelado ? const {1, 2, 3, 4, 5, 6} : const {1, 2, 3, 4, 5},
                      filas: [
                        for (final c in costos)
                          DataRow(cells: [
                            DataCell(Text('${combs[c['combinacion_id']]?['codigo']} · ${combs[c['combinacion_id']]?['nombre']}')),
                            for (final k in ['materiales', 'mano_obra', 'externos', 'indirectos']) DataCell(Text(Formato.cop(c[k] ?? 0))),
                            DataCell(Text(Formato.cop(c['total'] ?? 0), style: const TextStyle(fontWeight: FontWeight.w700))),
                            if (congelado)
                              DataCell(Text(totalHoy[c['combinacion_id']] == null ? '—' : Formato.cop(totalHoy[c['combinacion_id']]),
                                  style: TextStyle(fontWeight: FontWeight.w600,
                                      color: (totalHoy[c['combinacion_id']] ?? c['total']) != c['total'] ? Colores.ambar : null))),
                            DataCell(precio == null || precio == 0
                                ? const Text('—')
                                : () {
                                    final m = (precio - ((congelado ? totalHoy[c['combinacion_id']] : null) ?? c['total'] as num)) / precio * 100;
                                    return Text(Formato.porcentaje(m), style: TextStyle(color: m < 30 ? Colores.rojo : m < 45 ? Colores.ambar : Colores.verde, fontWeight: FontWeight.w600));
                                  }()),
                          ]),
                      ],
                    ),
                    if (congelado)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('"Total hoy" usa el valor minuto vigente y los costos actuales de los materiales; el margen se calcula con él.',
                            style: estilo(12.5, color: Colores.textoSuave)),
                      ),
                    if (costos.first['detalle']?['sam_total'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('SAM ${Formato.numero(costos.first['detalle']['sam_total'], decimales: 3)} min × valor minuto ${Formato.cop(costos.first['detalle']['valor_minuto'] ?? 0)}'
                            ' · indirectos ${Formato.cop(costos.first['detalle']['indirecto_minuto'] ?? 0)} por minuto · materiales ponderados por la curva',
                            style: estilo(12.5, color: Colores.textoSuave)),
                      ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('Detalle de materiales (${combs[costos.first['combinacion_id']]?['codigo']})', style: estilo(14, peso: FontWeight.w600)),
                      children: [
                        Tabla(
                          columnas: const ['Material', 'Consumo promedio', 'Unidad', 'Costo unitario', 'Valor'],
                          numericas: const {1, 3, 4},
                          filas: [
                            for (final m in (costos.first['detalle']?['materiales'] as List? ?? []))
                              DataRow(cells: [
                                DataCell(Text('${m['material']}')),
                                DataCell(Text(Formato.numero(m['cantidad'], decimales: 4))),
                                DataCell(Text('${m['unidad']}')),
                                DataCell(Text(m['costo_unitario'] == null ? 'Sin costo' : Formato.cop(m['costo_unitario']),
                                    style: TextStyle(color: m['costo_unitario'] == null ? Colores.rojo : null))),
                                DataCell(Text(Formato.cop(m['valor']))),
                              ]),
                          ],
                        ),
                      ],
                    ),
                  ]),
          ),
          const SizedBox(height: 16),
          Tarjeta(
            titulo: 'Aprobación (Diseño, Producción y Costos)',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (f['estado'] == 'borrador') ...[
                if (faltan.isEmpty)
                  Text('La ficha está completa.', style: estilo(14, peso: FontWeight.w600, color: Colores.verde))
                else ...[
                  Text('Falta para enviar a aprobación:', style: estilo(14, peso: FontWeight.w600)),
                  for (final x in faltan) Text('• $x', style: estilo(14, color: Colores.rojo)),
                ],
                const SizedBox(height: 12),
                if (widget.editable)
                  Align(alignment: Alignment.centerLeft, child: FilledButton.icon(
                    onPressed: faltan.isNotEmpty ? null : () => cambiar(context, ref, f['id'], () => db.rpc('enviar_ficha_aprobacion', params: {'p_ficha': f['id']}),
                        ok: 'Enviada a aprobación: el costo quedó calculado con el SAM vigente'),
                    icon: const Icon(Icons.send), label: const Text('Enviar a aprobación'))),
              ],
              if (f['estado'] == 'en_aprobacion') ...[
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final (area, nombre, roles) in [
                    ('diseno', 'Diseño', ['diseno', 'gerencia']),
                    ('produccion', 'Producción', ['jefe_produccion', 'gerencia']),
                    ('costos', 'Costos', ['costos', 'gerencia']),
                  ])
                    _Area(ficha: f, area: area, nombre: nombre,
                        puede: sesion != null && sesion.roles.any(roles.contains) &&
                            // tres personas distintas: quien ya aprobó otra área no aprueba esta
                            !(f['ficha_aprobaciones'] as List).any((a) => a['usuario_id'] == sesion.usuarioId && a['decision'] == 'aprobada' &&
                                !DateTime.parse(a['fecha']).isBefore(DateTime.parse(f['enviada_en'])))),
                ]),
                const SizedBox(height: 12),
                if (sesion?.puedeEditar('ficha_tecnica') ?? false)
                  Align(alignment: Alignment.centerLeft, child: TextButton(
                    onPressed: () => cambiar(context, ref, f['id'], () => db.rpc('devolver_ficha_borrador', params: {'p_ficha': f['id']})),
                    child: const Text('Devolver a borrador para corregir'))),
              ],
              if (f['estado'] == 'aprobada')
                Text('Aprobada el ${Formato.fechaHora(DateTime.parse(f['aprobada_en']))}. Versión congelada.', style: estilo(14, peso: FontWeight.w600, color: Colores.verde)),
              const SizedBox(height: 12),
              Text('Historial', style: estilo(13, peso: FontWeight.w600, color: Colores.textoSuave)),
              for (final a in ((f['ficha_aprobaciones'] as List).cast<Map<String, dynamic>>()..sort((a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'))))
                Text('${Formato.fechaHora(DateTime.parse(a['fecha']))} · ${a['area']} · ${a['decision']} · ${a['perfiles']?['nombre'] ?? ''}'
                    '${a['comentario'] != null ? ' · «${a['comentario']}»' : ''}', style: estilo(13)),
            ]),
          ),
        ]);
      },
    );
  }
}

class _Area extends ConsumerWidget {
  const _Area({required this.ficha, required this.area, required this.nombre, required this.puede});
  final Map<String, dynamic> ficha;
  final String area, nombre;
  final bool puede;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enviada = DateTime.parse(ficha['enviada_en']);
    final decision = (ficha['ficha_aprobaciones'] as List).where((a) => a['area'] == area && !DateTime.parse(a['fecha']).isBefore(enviada)).firstOrNull;
    return Container(
      width: 260,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border.all(color: Colores.borde), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nombre, style: estilo(15, peso: FontWeight.w600)),
        const SizedBox(height: 8),
        if (decision != null)
          Pastilla(decision['decision'] == 'aprobada' ? 'Aprobó' : 'Rechazó', color: decision['decision'] == 'aprobada' ? Colores.verde : Colores.rojo)
        else if (puede)
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: () => cambiar(context, ref, ficha['id'], () => db.rpc('decidir_ficha', params: {'p_ficha': ficha['id'], 'p_area': area, 'p_aprobar': true})),
                child: const Text('Aprobar')),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
              onPressed: () async {
                final m = await pedirTexto(context, titulo: 'Rechazar ($nombre)', etiqueta: 'Motivo');
                if (m != null && context.mounted) {
                  await cambiar(context, ref, ficha['id'], () => db.rpc('decidir_ficha', params: {'p_ficha': ficha['id'], 'p_area': area, 'p_aprobar': false, 'p_comentario': m}));
                }
              },
              child: const Text('Rechazar'),
            ),
          ])
        else
          const Pastilla('Pendiente', color: Colores.ambar),
      ]),
    );
  }
}

