import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'comun_inventario.dart';
import 'pantalla_telas.dart' show nombreTipoMovimiento;

final _saldosProvider = FutureProvider.autoDispose((ref) => db
    .from('saldos_inventario')
    .select('material_id, color_id, bodega_id, fisico, reservado, disponible, costo_promedio, '
        'materiales!inner(codigo, nombre, unidad, tipo, stock_minimo), colores(nombre, hex), bodegas(nombre), ubicaciones(codigo)')
    .eq('materiales.tipo', 'insumo'));

/// Saldos de insumos por material, color y bodega (suma de ubicaciones).
class PantallaInsumos extends ConsumerWidget {
  const PantallaInsumos({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_saldosProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Insumos', subtitulo: 'Físico, reservado para OP y disponible · stock mínimo'),
      const PestanasInventario('insumos'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (filas) {
          final grupos = <String, Map<String, dynamic>>{};
          for (final f in filas) {
            final k = '${f['material_id']}|${f['color_id']}|${f['bodega_id']}';
            final g = grupos.putIfAbsent(k, () => {...f, 'fisico': 0.0, 'reservado': 0.0, 'disponible': 0.0, 'ubic': <String>{}});
            for (final c in ['fisico', 'reservado', 'disponible']) {
              g[c] = (g[c] as double) + (f[c] as num).toDouble();
            }
            if (f['ubicaciones'] != null && (f['fisico'] as num) != 0) (g['ubic'] as Set<String>).add(f['ubicaciones']['codigo']);
          }
          final lista = grupos.values.toList()..sort((a, b) => '${a['materiales']['nombre']}'.compareTo('${b['materiales']['nombre']}'));
          return Tarjeta(
            padding: EdgeInsets.zero,
            child: Tabla(
              columnas: const ['Código', 'Insumo', 'Color', 'Bodega', 'Ubicaciones', 'Físico', 'Reservado', 'Disponible', 'Unidad', 'Mínimo', 'Costo prom.'],
              numericas: const {5, 6, 7, 9, 10},
              filas: [
                for (final g in lista)
                  DataRow(cells: [
                    DataCell(Text('${g['materiales']['codigo']}', style: estiloCodigo(13))),
                    DataCell(Text('${g['materiales']['nombre']}')),
                    DataCell(Row(children: [
                      if (g['colores'] != null) ...[muestraColor(g['colores']['hex']), const SizedBox(width: 6)],
                      Text('${g['colores']?['nombre'] ?? '—'}'),
                    ])),
                    DataCell(Text('${g['bodegas']['nombre']}')),
                    DataCell(Text((g['ubic'] as Set<String>).join(', '), style: estilo(12.5))),
                    DataCell(Text(Formato.numero(g['fisico'], decimales: 0),
                        style: TextStyle(color: (g['fisico'] as double) < 0 ? Colores.rojo : null, fontWeight: FontWeight.w600))),
                    DataCell(Text(Formato.numero(g['reservado'], decimales: 0))),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(Formato.numero(g['disponible'], decimales: 0)),
                      if (g['materiales']['stock_minimo'] != null && (g['disponible'] as double) < (g['materiales']['stock_minimo'] as num))
                        const Padding(padding: EdgeInsets.only(left: 6), child: Pastilla('Bajo mínimo', color: Colores.rojo)),
                    ])),
                    DataCell(Text('${g['materiales']['unidad']}')),
                    DataCell(Text(g['materiales']['stock_minimo'] == null ? '—' : Formato.numero(g['materiales']['stock_minimo'], decimales: 0))),
                    DataCell(Text(g['costo_promedio'] == null ? '—' : Formato.cop(g['costo_promedio']))),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}

// =====================================================================
// Kardex
// =====================================================================
class PantallaKardex extends ConsumerStatefulWidget {
  const PantallaKardex({super.key});
  @override
  ConsumerState<PantallaKardex> createState() => _PantallaKardexState();
}

class _PantallaKardexState extends ConsumerState<PantallaKardex> {
  String? _material;
  String? _color;
  String? _bodega;
  Future<List<Map<String, dynamic>>>? _movs;

  void _consultar() {
    if (_material == null) return;
    var q = db.from('kardex').select().eq('material_id', _material!);
    if (_color != null) q = q.eq('color_id', _color!);
    if (_bodega != null) q = q.eq('bodega_id', _bodega!);
    setState(() => _movs = q.order('ocurrido_en', ascending: false).limit(500));
  }

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(catalogosProvider).value;
    final mat = cat?.material(_material);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Kardex', subtitulo: 'Todos los movimientos de un material con su saldo acumulado. Nunca se editan ni se borran.'),
      const PestanasInventario('kardex'),
      if (cat != null)
        Tarjeta(
          child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 340,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Material', isDense: true),
                items: [for (final m in cat.materiales) DropdownMenuItem(value: m['id'] as String, child: Text('${m['codigo']} · ${m['nombre']}', overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _material = v),
              ),
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String?>(
                decoration: const InputDecoration(labelText: 'Color', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('Todos')), for (final c in cat.colores) DropdownMenuItem(value: c['id'] as String, child: Text('${c['nombre']}'))],
                onChanged: (v) => _color = v,
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String?>(
                decoration: const InputDecoration(labelText: 'Bodega', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('Todas')), for (final b in cat.bodegas) DropdownMenuItem(value: b['id'] as String, child: Text('${b['nombre']}'))],
                onChanged: (v) => _bodega = v,
              ),
            ),
            FilledButton(onPressed: _material == null ? null : _consultar, child: const Text('Consultar')),
          ]),
        ),
      const SizedBox(height: 16),
      if (_movs != null)
        FutureBuilder(
          future: _movs,
          builder: (_, s) {
            if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
            if (!s.hasData) return const LinearProgressIndicator();
            final u = mat?['unidad'] ?? '';
            return Tarjeta(
              padding: EdgeInsets.zero,
              child: Tabla(
                columnas: ['Fecha', 'Movimiento', 'Documento', 'Cantidad ($u)', 'Saldo ($u)', 'Costo unit.', 'Motivo'],
                numericas: const {3, 4, 5},
                vacio: 'Sin movimientos.',
                filas: [
                  for (final m in s.data!)
                    DataRow(cells: [
                      DataCell(Text(Formato.fechaHora(DateTime.parse(m['ocurrido_en'])))),
                      DataCell(Text(nombreTipoMovimiento('${m['tipo']}'))),
                      DataCell(Text('${m['documento_tipo'] ?? ''} ${m['documento_id'] ?? ''}'.trim(), style: estilo(12.5))),
                      DataCell(Text(Formato.dos(m['cantidad']), style: TextStyle(color: (m['cantidad'] as num) < 0 ? Colores.rojo : Colores.verde))),
                      DataCell(Text(Formato.dos(m['saldo_acumulado']), style: const TextStyle(fontWeight: FontWeight.w600))),
                      DataCell(Text(m['costo_unitario'] == null ? '—' : Formato.cop(m['costo_unitario']))),
                      DataCell(Text('${m['motivo'] ?? ''}', style: estilo(12.5))),
                    ]),
                ],
              ),
            );
          },
        ),
    ]);
  }
}
