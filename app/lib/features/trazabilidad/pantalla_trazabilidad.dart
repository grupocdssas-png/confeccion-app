import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, mensajeError, Tabla;

/// Trazabilidad inversa: desde un paquete o juego, un rollo, un lote de tintura, una OP,
/// un despacho o la etiqueta de una prenda (reclamo) → rollos, cortador, satélites,
/// operarios, calidad, fechas y a dónde fue.
class PantallaTrazabilidad extends ConsumerStatefulWidget {
  const PantallaTrazabilidad({super.key, this.codigo});
  final String? codigo;
  @override
  ConsumerState<PantallaTrazabilidad> createState() => _PantallaTrazabilidadState();
}

class _PantallaTrazabilidadState extends ConsumerState<PantallaTrazabilidad> {
  late final _c = TextEditingController(text: widget.codigo ?? '');
  Future<Map<String, dynamic>>? _datos;

  @override
  void initState() {
    super.initState();
    if ((widget.codigo ?? '').isNotEmpty) _buscar();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _buscar() {
    final v = _c.text.trim();
    if (v.isEmpty) return;
    setState(() => _datos = db.rpc('trazabilidad', params: {'p_codigo': v}).then((x) => Map<String, dynamic>.from(x as Map)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Trazabilidad', subtitulo: 'Escanee o escriba: paquete (PQ-), juego (JG-), rollo (TL-), lote de tintura, OP, despacho (DES-) o etiqueta de prenda (PT-)'),
      Row(children: [
        SizedBox(
          width: 420,
          child: TextField(
            controller: _c,
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.qr_code_scanner), hintText: 'Código o lote (el lector de códigos escribe aquí)'),
            onSubmitted: (_) => _buscar(),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(onPressed: _buscar, icon: const Icon(Icons.search), label: const Text('Buscar')),
      ]),
      const SizedBox(height: 16),
      if (_datos != null)
        FutureBuilder<Map<String, dynamic>>(
          key: ObjectKey(_datos),
          future: _datos,
          builder: (_, s) {
            if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
            if (!s.hasData) return const LinearProgressIndicator();
            return _resultado(s.data!);
          },
        ),
    ]);
  }

  Widget _resultado(Map<String, dynamic> t) {
    final unidades = ((t['unidades'] ?? []) as List).cast<Map<String, dynamic>>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (t['tipo'] == 'rollo') _rollo(Map<String, dynamic>.from(t['rollo']), (t['cortes'] as List).cast<Map<String, dynamic>>()),
      if (t['tipo'] == 'despacho') _despacho(Map<String, dynamic>.from(t['despacho']), (t['productos'] as List).cast<Map<String, dynamic>>()),
      if (t['tipo'] == 'producto') _producto(t['codigo'], (t['despachos'] as List).cast<Map<String, dynamic>>()),
      if (t['tipo'] == 'lote') _lote(t['codigo'], (t['rollos'] as List).cast<Map<String, dynamic>>()),
      if (t['tipo'] != 'unidad') const SizedBox(height: 16),
      Text(
          t['tipo'] == 'unidad'
              ? 'Recorrido'
              : t['tipo'] == 'producto'
                  ? 'Paquetes y juegos que entraron con este código (${unidades.length}). Si el cliente trae la etiqueta del paquete, búsquela para saber exactamente cuál fue.'
                  : 'Paquetes y juegos (${unidades.length})',
          style: estilo(15, peso: FontWeight.w600)),
      const SizedBox(height: 8),
      for (final u in unidades) _Unidad(u: u, abierta: unidades.length == 1),
    ]);
  }

  Widget _rollo(Map<String, dynamic> r, List<Map<String, dynamic>> cortes) => Tarjeta(
        titulo: 'Rollo ${r['codigo']}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${r['material']} · ${r['color'] ?? ''} · lote ${r['lote_tintura'] ?? '—'}${r['tono'] != null ? ' · tono ${r['tono']}' : ''}', style: estilo(14)),
          Text('Proveedor ${r['proveedor'] ?? '—'} · ingresó ${r['ingreso'] == null ? '—' : Formato.fecha(DateTime.parse('${r['ingreso']}T12:00:00Z'))}'
              '${r['recepcion'] != null ? ' en ${r['recepcion']}' : ''}${r['origen'] != null ? ' · retazo de ${r['origen']}' : ''}'
              ' · ${Formato.numero(r['metros_iniciales'] ?? 0, decimales: 1)} m iniciales, quedan ${Formato.numero(r['metros_saldo'] ?? 0, decimales: 1)} m (${r['estado']})',
              style: estilo(13.5, color: Colores.textoSuave)),
          const SizedBox(height: 8),
          for (final c in cortes)
            Text('• Corte ${c['corte']} de ${c['op']}: ${Formato.numero(c['metros'] ?? 0, decimales: 2)} m${c['fecha'] != null ? ' · ${Formato.fechaHora(DateTime.parse(c['fecha']))}' : ''}',
                style: estilo(13.5)),
        ]),
      );

  Widget _despacho(Map<String, dynamic> d, List<Map<String, dynamic>> p) => Tarjeta(
        titulo: 'Despacho ${d['consecutivo']}${d['estado'] == 'anulado' ? ' (anulado)' : ''}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Cliente ${d['cliente'] ?? '—'} · pedido ${d['pedido'] ?? '—'} · ${Formato.fecha(DateTime.parse('${d['fecha']}T12:00:00Z'))}', style: estilo(14)),
          const SizedBox(height: 6),
          for (final x in p) Text('• ${x['producto']}: ${x['cantidad']}', style: estiloCodigo(13)),
        ]),
      );

  Widget _producto(String codigo, List<Map<String, dynamic>> ds) => Tarjeta(
        titulo: 'Producto $codigo',
        child: ds.isEmpty
            ? Text('No se ha despachado.', style: estilo(14, color: Colores.textoSuave))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final d in ds)
                  Text('• ${d['despacho']} · ${d['cliente'] ?? ''} · ${d['cantidad']} prendas · ${Formato.fecha(DateTime.parse('${d['fecha']}T12:00:00Z'))}',
                      style: estilo(13.5)),
              ]),
      );

  Widget _lote(String codigo, List<Map<String, dynamic>> rs) => Tarjeta(
        titulo: 'Lote de tintura $codigo',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in rs)
            Text('• ${r['codigo']} · ${r['material']} · ${r['proveedor'] ?? ''} · ${r['estado']} · quedan ${Formato.numero(r['metros_saldo'] ?? 0, decimales: 1)} m',
                style: estilo(13.5)),
        ]),
      );
}

class _Unidad extends StatelessWidget {
  const _Unidad({required this.u, required this.abierta});
  final Map<String, dynamic> u;
  final bool abierta;

  String _f(Object? v) => v == null ? '' : Formato.fechaHora(DateTime.parse('$v'));

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> l(String k) => ((u[k] ?? []) as List).cast<Map<String, dynamic>>();
    final op = u['op'] as Map?;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Colores.borde)),
      child: ExpansionTile(
        initiallyExpanded: abierta,
        shape: const Border(),
        title: Text('${u['codigo']} · ${u['tipo'] == 'juego' ? 'juego' : 'paquete'} de ${u['cantidad']} · talla ${u['talla'] ?? ''}', style: estiloCodigo(14, peso: FontWeight.w700)),
        subtitle: Text('${op?['consecutivo'] ?? ''} · ${op?['referencia'] ?? ''} · ${u['estado']}${u['proceso_actual'] != null && u['estado'] != 'terminado' ? ' en ${Colores.nombreProceso(u['proceso_actual'])}' : ''}',
            style: estilo(13, color: Colores.textoSuave)),
        trailing: op == null ? null : TextButton(onPressed: () => context.go('/op/${op['id']}'), child: const Text('Ver OP')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _seccion('Tela', [
            for (final r in l('rollos'))
              '${r['codigo']} · ${r['material']} · lote ${r['lote_tintura'] ?? '—'}${r['tono'] != null ? ' · tono ${r['tono']}' : ''} · ${r['proveedor'] ?? ''}',
          ]),
          _seccion('Corte', [
            for (final c in l('corte'))
              '${c['consecutivo']} · ${_f(c['fecha'])} · cortador ${c['cortador'] ?? '—'} · paquete ${c['paquete']} (${c['color'] ?? ''}, lote ${c['lote_tintura'] ?? '—'})',
          ]),
          if (l('remisiones').isNotEmpty)
            _seccion('Satélites', [
              for (final r in l('remisiones'))
                '${r['consecutivo']} · ${r['tipo'] == 'salida' ? 'salió a' : 'volvió de'} ${r['satelite']} (${Colores.nombreProceso(r['proceso'])}) · ${Formato.fecha(DateTime.parse('${r['fecha']}T12:00:00Z'))}',
            ]),
          if (l('procesos').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Procesos', style: estilo(13.5, peso: FontWeight.w600)),
            Tabla(
              columnas: const ['Fecha', 'Proceso', 'Evento', 'Entra', 'Buenas', 'Segundas', 'Faltantes', 'Dónde', 'Quién'],
              numericas: const {3, 4, 5, 6},
              filas: [
                for (final p in l('procesos'))
                  DataRow(cells: [
                    DataCell(Text(_f(p['fecha']))),
                    DataCell(Text('${p['proceso']}')),
                    DataCell(Text(p['tipo'] == 'recepcion' ? 'Recibe' : 'Entrega')),
                    DataCell(Text('${p['entra'] ?? ''}')),
                    DataCell(Text(p['tipo'] == 'recepcion' ? '' : '${p['buenas']}')),
                    DataCell(Text(p['tipo'] == 'recepcion' ? '' : '${p['segundas']}')),
                    DataCell(Text(p['tipo'] == 'recepcion' ? '' : '${p['faltantes']}')),
                    DataCell(Text('${p['celula'] ?? p['satelite'] ?? ''}')),
                    DataCell(Text('${p['empleado'] ?? ''}')),
                  ]),
              ],
            ),
          ],
          if (l('operarios').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Operarios', style: estilo(13.5, peso: FontWeight.w600)),
            Tabla(
              columnas: const ['Operación', 'Proceso', 'Operario', 'Unidades', 'Reprocesos', 'Desde', 'Hasta'],
              numericas: const {3, 4},
              filas: [
                for (final o in l('operarios'))
                  DataRow(cells: [
                    DataCell(Text('${o['operacion']}')),
                    DataCell(Text(Colores.nombreProceso(o['proceso']))),
                    DataCell(Text('${o['codigo']} · ${o['empleado']}')),
                    DataCell(Text('${o['unidades'] ?? 0}')),
                    DataCell(Text('${o['reprocesos'] ?? ''}')),
                    DataCell(Text(_f(o['desde']))),
                    DataCell(Text(_f(o['hasta']))),
                  ]),
              ],
            ),
          ],
          if (l('calidad').isNotEmpty)
            _seccion('Calidad', [
              for (final i in l('calidad'))
                '${i['consecutivo']} · ${i['tipo'] == 'auditoria_final' ? 'auditoría' : 'en proceso'} · ${i['resultado']} · ${i['defectuosas']} de ${i['muestra']}'
                    '${(i['defectos'] as List).isNotEmpty ? ' (${(i['defectos'] as List).join(', ')})' : ''} · ${i['inspector'] ?? ''} · ${_f(i['fecha'])}',
            ]),
          if (l('destino').isNotEmpty)
            _seccion('Destino', [
              for (final d in l('destino'))
                '${d['tipo'] == 'ingreso_segunda' ? 'Segundas' : 'Producto terminado'}: ${d['cantidad']} × ${d['producto']} · ${_f(d['fecha'])}',
            ]),
        ],
      ),
    );
  }

  Widget _seccion(String t, List<String> lineas) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: estilo(13.5, peso: FontWeight.w600)),
          if (lineas.isEmpty) Text('—', style: estilo(13.5, color: Colores.textoSuave)),
          for (final x in lineas) Text(x, style: estilo(13.5)),
        ]),
      );
}
