import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import 'comun_inventario.dart';
import 'etiquetas_inventario_web.dart';

/// ('telas' | 'retazos', filtro de estado)
final _rollosProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, (bool, String)>((ref, k) async {
  final (retazos, estado) = k;
  var q = db.from('rollos').select('$selectRolloEtiqueta, material_id, color_id, estado, es_retazo, bodega_id, ubicacion_id, '
      'colores(nombre, hex), materiales(nombre, codigo, unidad), rollo_origen:rollo_origen_id(codigo)');
  q = q.eq('es_retazo', retazos);
  if (estado == 'vigentes') q = q.neq('estado', 'agotado');
  if (estado == 'agotados') q = q.eq('estado', 'agotado');
  return await q.order('codigo', ascending: true).limit(2000);
});

/// Inventario de telas agrupado por tela y color, con el detalle de cada rollo.
class PantallaTelas extends ConsumerStatefulWidget {
  const PantallaTelas({super.key, this.retazos = false});
  final bool retazos;
  @override
  ConsumerState<PantallaTelas> createState() => _PantallaTelasState();
}

class _PantallaTelasState extends ConsumerState<PantallaTelas> {
  var _estado = 'vigentes';
  var _filtro = '';
  final _abiertos = <String>{};

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_rollosProvider((widget.retazos, _estado)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina(widget.retazos ? 'Retazos' : 'Inventario de telas',
          subtitulo: widget.retazos ? 'Retazos utilizables, con su lote y rollo de origen' : 'Rollos por tela y color · lote de tintura, tono y ancho real',
          acciones: [
            SizedBox(
              width: 260,
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Tela, color, lote o rollo', isDense: true),
                onChanged: (v) => setState(() => _filtro = v.toLowerCase()),
              ),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'vigentes', label: Text('Con saldo')),
                ButtonSegment(value: 'agotados', label: Text('Agotados')),
                ButtonSegment(value: 'todos', label: Text('Todos')),
              ],
              selected: {_estado},
              onSelectionChanged: (s) => setState(() => _estado = s.first),
            ),
          ]),
      PestanasInventario(widget.retazos ? 'retazos' : 'telas'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text('Error: ${mensajeError(e)}', style: estilo(14, color: Colores.rojo)),
        data: (rollos) {
          final filtrados = rollos.where((r) => [r['codigo'], r['lote_tintura'], r['materiales']?['nombre'], r['colores']?['nombre']]
              .join(' ').toLowerCase().contains(_filtro)).toList();
          final grupos = <String, List<Map<String, dynamic>>>{};
          for (final r in filtrados) {
            grupos.putIfAbsent('${r['material_id']}|${r['color_id']}', () => []).add(r);
          }
          final totalM = filtrados.fold<double>(0, (a, r) => a + (r['metros_saldo'] as num));
          final totalK = filtrados.fold<double>(0, (a, r) => a + (r['kilos_saldo'] as num));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 16, runSpacing: 16, children: [
              _Indicador(widget.retazos ? 'Retazos' : 'Rollos', Formato.numero(filtrados.length, decimales: 0)),
              _Indicador('Metros', Formato.dos(totalM)),
              _Indicador('Kilos', Formato.dos(totalK)),
              _Indicador('Telas y colores', '${grupos.length}'),
            ]),
            const SizedBox(height: 16),
            if (grupos.isEmpty) Tarjeta(child: Text('No hay rollos con este filtro.', style: estilo(14, color: Colores.textoSuave))),
            for (final g in grupos.entries) ...[
              _Grupo(
                rollos: g.value,
                abierto: _abiertos.contains(g.key) || grupos.length <= 3,
                onTap: () => setState(() => _abiertos.contains(g.key) ? _abiertos.remove(g.key) : _abiertos.add(g.key)),
                onCambio: () => ref.invalidate(_rollosProvider),
              ),
              const SizedBox(height: 10),
            ],
          ]);
        },
      ),
    ]);
  }
}

class _Indicador extends StatelessWidget {
  const _Indicador(this.t, this.v);
  final String t, v;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: Tarjeta(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: estilo(13, color: Colores.textoSuave)),
            const SizedBox(height: 4),
            Text(v, style: estilo(26, peso: FontWeight.w600)),
          ]),
        ),
      );
}

class _Grupo extends StatelessWidget {
  const _Grupo({required this.rollos, required this.abierto, required this.onTap, required this.onCambio});
  final List<Map<String, dynamic>> rollos;
  final bool abierto;
  final VoidCallback onTap, onCambio;

  @override
  Widget build(BuildContext context) {
    final r0 = rollos.first;
    final metros = rollos.fold<double>(0, (a, r) => a + (r['metros_saldo'] as num));
    final kilos = rollos.fold<double>(0, (a, r) => a + (r['kilos_saldo'] as num));
    final lotes = {for (final r in rollos) '${r['lote_tintura']}|${r['tono'] ?? ''}'};
    final anchos = rollos.map((r) => (r['ancho_real_cm'] as num).toDouble());
    final difAncho = anchos.reduce((a, b) => a > b ? a : b) - anchos.reduce((a, b) => a < b ? a : b);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 14, runSpacing: 8, children: [
              Icon(abierto ? Icons.expand_less : Icons.expand_more, color: Colores.textoSuave),
              muestraColor(r0['colores']?['hex'], tam: 18),
              Text('${r0['materiales']?['nombre']}', style: estilo(15, peso: FontWeight.w600)),
              Text('${r0['colores']?['nombre']}', style: estilo(15)),
              Text('${rollos.length} rollos · ${Formato.dos(metros)} m · ${Formato.dos(kilos)} kg', style: estilo(14, color: Colores.textoSuave)),
              if (lotes.length > 1) Pastilla('${lotes.length} lotes/tonos', color: Colores.ambar, icono: Icons.layers_outlined),
              if (difAncho > 2) Pastilla('Anchos difieren ${Formato.numero(difAncho, decimales: 1)} cm', color: Colores.ambar),
            ]),
          ),
        ),
        if (abierto) ...[
          const Divider(),
          Tabla(
            columnas: const ['Rollo', 'Lote', 'Tono', 'Ancho (cm)', 'Metros', 'Kilos', 'Ubicación', 'Ingreso', 'Estado', ''],
            numericas: const {3, 4, 5},
            filas: [
              for (final r in rollos)
                DataRow(cells: [
                  DataCell(Text('${r['codigo']}', style: estiloCodigo(13))),
                  DataCell(Text('${r['lote_tintura']}', style: estiloCodigo(13, peso: FontWeight.w400))),
                  DataCell(Text('${r['tono'] ?? '—'}')),
                  DataCell(Text(Formato.numero(r['ancho_real_cm'] as num, decimales: 1))),
                  DataCell(Text(Formato.dos(r['metros_saldo'] as num))),
                  DataCell(Text(Formato.dos(r['kilos_saldo'] as num))),
                  DataCell(Text('${r['ubicaciones']?['codigo'] ?? '—'}', style: estiloCodigo(13, peso: FontWeight.w400))),
                  DataCell(Text(Formato.fecha(DateTime.parse('${r['fecha_ingreso']}T12:00:00Z')))),
                  DataCell(pastillaEstadoRollo('${r['estado']}')),
                  DataCell(TextButton(
                    onPressed: () async {
                      final cambio = await showDialog<bool>(context: context, builder: (_) => DialogoRollo(rolloId: r['id']));
                      if (cambio == true) onCambio();
                    },
                    child: const Text('Ver'),
                  )),
                ]),
            ],
          ),
        ],
      ]),
    );
  }
}

/// Detalle de un rollo: datos, kardex, imprimir, trasladar y separar retazo.
class DialogoRollo extends ConsumerStatefulWidget {
  const DialogoRollo({super.key, required this.rolloId});
  final String rolloId;
  @override
  ConsumerState<DialogoRollo> createState() => _DialogoRolloState();
}

class _DialogoRolloState extends ConsumerState<DialogoRollo> {
  late Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _datos = _cargar();
  var _cambio = false;

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _cargar() async {
    final r = await db.from('rollos').select('$selectRolloEtiqueta, estado, es_retazo, bodega_id, ubicacion_id, bodegas(nombre), '
        'materiales(nombre, unidad), rollo_origen:rollo_origen_id(codigo)').eq('id', widget.rolloId).single();
    final k = await db.from('movimientos_inventario').select('tipo, cantidad, metros, kilos, documento_tipo, documento_id, motivo, ocurrido_en, '
        'ubicaciones(codigo)').eq('rollo_id', widget.rolloId).order('ocurrido_en', ascending: true).order('recibido_en', ascending: true);
    return (r, k);
  }

  void _recargar() => setState(() {
        _cambio = true;
        _datos = _cargar();
      });

  Future<void> _trasladar(Map<String, dynamic> r) async {
    final cat = await ref.read(catalogosProvider.future);
    if (!mounted) return;
    String? destino;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
            title: Text('Trasladar ${r['codigo']}'),
            content: SizedBox(
              width: 400,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Ubicación destino'),
                items: [
                  for (final u in cat.ubicaciones)
                    DropdownMenuItem(value: u['id'] as String, child: Text('${u['codigo']} · ${u['descripcion'] ?? ''}')),
                ],
                onChanged: (v) => set(() => destino = v),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
              FilledButton(onPressed: destino == null ? null : () => Navigator.pop(d, true), child: const Text('Trasladar')),
            ],
          )),
    );
    if (ok != true) return;
    try {
      await db.rpc('trasladar_rollo', params: {'p_rollo': r['id'], 'p_destino': destino});
      _recargar();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  Future<void> _retazo(Map<String, dynamic> r) async {
    final m = TextEditingController(), k = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Separar retazo de ${r['codigo']}'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Saldo: ${Formato.dos(r['metros_saldo'])} m · ${Formato.dos(r['kilos_saldo'])} kg. El retazo queda como un rollo nuevo con el mismo lote.'),
            const SizedBox(height: 12),
            TextField(controller: m, decoration: const InputDecoration(labelText: 'Metros del retazo')),
            const SizedBox(height: 8),
            TextField(controller: k, decoration: const InputDecoration(labelText: 'Kilos del retazo')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Separar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final nuevo = await db.rpc('separar_retazo',
          params: {'p_rollo': r['id'], 'p_metros': numeroCo(m.text), 'p_kilos': numeroCo(k.text) ?? 0});
      if (mounted) avisar(context, 'Retazo ${nuevo['codigo']} creado');
      _recargar();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editar = puedeEditarInventario(ref);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: FutureBuilder(
          future: _datos,
          builder: (context, s) {
            if (s.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text(mensajeError(s.error!)));
            if (!s.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            final (r, kardex) = s.data!;
            var saldo = 0.0;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text('${r['codigo']}', style: estiloCodigo(24)),
                  const SizedBox(width: 12),
                  pastillaEstadoRollo('${r['estado']}'),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(context, _cambio), icon: const Icon(Icons.close)),
                ]),
                Text('${r['materiales']?['nombre']} · ${r['colores']?['nombre']}', style: estilo(16, peso: FontWeight.w600)),
                if (r['rollo_origen'] != null) Text('Retazo del rollo ${r['rollo_origen']['codigo']}', style: estilo(13, color: Colores.textoSuave)),
                const SizedBox(height: 14),
                Wrap(spacing: 28, runSpacing: 10, children: [
                  _dato('Lote', '${r['lote_tintura']}'),
                  _dato('Tono', '${r['tono'] ?? '—'}'),
                  _dato('Ancho real', '${Formato.numero(r['ancho_real_cm'], decimales: 1)} cm'),
                  _dato('Saldo', '${Formato.dos(r['metros_saldo'])} m · ${Formato.dos(r['kilos_saldo'])} kg'),
                  _dato('Inicial', '${Formato.dos(r['metros_iniciales'])} m · ${Formato.dos(r['kilos_iniciales'])} kg'),
                  _dato('Ubicación', '${r['ubicaciones']?['codigo'] ?? '—'} (${r['bodegas']?['nombre']})'),
                  _dato('Proveedor', '${r['proveedores']?['nombre'] ?? '—'}'),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final motivo = await pedirTexto(context, titulo: 'Reimprimir etiqueta', etiqueta: 'Motivo', ayuda: 'Ej.: etiqueta dañada');
                      if (motivo != null && context.mounted) await imprimirRollosWeb(context, [r], reimpresion: true, motivo: motivo);
                    },
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Reimprimir etiqueta'),
                  ),
                  if (editar && r['estado'] != 'agotado') ...[
                    OutlinedButton.icon(onPressed: () => _trasladar(r), icon: const Icon(Icons.move_down), label: const Text('Trasladar')),
                    if (r['es_retazo'] != true)
                      OutlinedButton.icon(onPressed: () => _retazo(r), icon: const Icon(Icons.content_cut), label: const Text('Separar retazo')),
                  ],
                ]),
                const SizedBox(height: 20),
                Text('Kardex del rollo', style: estilo(15, peso: FontWeight.w600)),
                const SizedBox(height: 6),
                Tabla(
                  columnas: const ['Fecha', 'Movimiento', 'Documento', 'Ubicación', 'Metros', 'Kilos', 'Saldo m'],
                  numericas: const {4, 5, 6},
                  filas: [
                    for (final k in kardex)
                      DataRow(cells: [
                        DataCell(Text(Formato.fechaHora(DateTime.parse(k['ocurrido_en'])))),
                        DataCell(Text(_tipo('${k['tipo']}'))),
                        DataCell(Text('${k['documento_tipo'] ?? ''} ${k['documento_id'] ?? ''}'.trim(), style: estilo(12.5))),
                        DataCell(Text('${k['ubicaciones']?['codigo'] ?? '—'}')),
                        DataCell(Text(Formato.dos(k['metros'] ?? 0),
                            style: TextStyle(color: (k['metros'] ?? 0) < 0 ? Colores.rojo : Colores.verde))),
                        DataCell(Text(Formato.dos(k['kilos'] ?? 0))),
                        DataCell(Text(Formato.dos(saldo += ((k['metros'] ?? 0) as num).toDouble()))),
                      ]),
                  ],
                ),
              ]),
            );
          },
        ),
      ),
    );
  }

  Widget _dato(String t, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: estilo(12, color: Colores.textoSuave)),
        Text(v, style: estilo(14.5, peso: FontWeight.w600)),
      ]);
}

String _tipo(String t) => switch (t) {
      'entrada_compra' => 'Entrada por compra',
      'traslado' => 'Traslado',
      'ajuste' => 'Ajuste',
      'conteo' => 'Ajuste por conteo',
      'anulacion' => 'Anulación',
      'salida_op' => 'Salida a OP',
      'reserva' => 'Reserva',
      'liberacion' => 'Liberación',
      'devolucion' => 'Devolución',
      'envio_satelite' => 'Envío a satélite',
      _ => t,
    };
String nombreTipoMovimiento(String t) => _tipo(t);
