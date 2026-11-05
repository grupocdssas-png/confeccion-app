import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, muestraColor, pedirTexto;
import 'datos_externos.dart';
import 'remision_pdf.dart';

final remisionProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  final r = await db.from('remisiones').select(selectRemision).eq('id', id).single();
  final dev = await db.from('remisiones').select(selectRemision).eq('remision_salida_id', id).order('creado_en', ascending: true);
  final cuentas = dev.isEmpty
      ? <Map<String, dynamic>>[]
      : await db.from('cuentas_pagar_satelite').select('*, ordenes_produccion(consecutivo)').inFilter('remision_id', [for (final d in dev) d['id']]);
  return {...r, 'devoluciones': dev, 'cuentas': cuentas};
});

class PantallaRemision extends ConsumerWidget {
  const PantallaRemision({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(remisionProvider(id));
    final cat = ref.watch(catalogoExternosProvider).value;
    final sesion = ref.watch(sesionProvider).value;
    final editar = sesion?.puedeEditar('procesos_externos') ?? false;
    final esSatelite = sesion?.roles.contains('satelite') ?? false;
    return datos.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (r) {
        if (cat == null) return const LinearProgressIndicator();
        final unidades = unidadesDeRemision(r, cat);
        final insumos = insumosDeRemision(r);
        final pendientes = unidades.where((u) => u['buenas'] == null).toList();
        final abierta = r['estado'] == 'enviada' || r['estado'] == 'parcial';
        Future<void> accion(Future<void> Function() f, String ok) async {
          try {
            await f();
            ref.invalidate(remisionProvider(id));
            if (context.mounted) avisar(context, ok);
          } catch (e) {
            if (context.mounted) avisar(context, mensajeError(e), error: true);
          }
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EncabezadoPagina('${r['consecutivo']} · ${r['satelites']?['nombre'] ?? ''}',
              subtitulo: '${r['procesos']?['nombre'] ?? r['proceso']} · enviada el ${Formato.fecha(DateTime.parse('${r['fecha']}T12:00:00Z'))}'
                  '${r['fecha_compromiso'] != null ? ' · devolver a más tardar el ${Formato.fecha(DateTime.parse('${r['fecha_compromiso']}T12:00:00Z'))}' : ''}',
              acciones: [
                Pastilla(nombreEstadoRemision(r['estado']), color: abierta ? Colores.ambar : r['estado'] == 'anulada' ? Colores.rojo : Colores.verde),
                OutlinedButton(onPressed: () => context.go('/externos'), child: const Text('Volver')),
                OutlinedButton.icon(
                  onPressed: () async {
                    final bytes = await remisionPdf(r, unidades, insumos);
                    await Printing.layoutPdf(onLayout: (_) async => bytes, name: '${r['consecutivo']}');
                  },
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Imprimir remisión')),
                if (esSatelite && r['recibida_satelite'] == null && abierta)
                  FilledButton.icon(
                    onPressed: () async {
                      final nota = await pedirTexto(context, titulo: 'Confirmar que llegó', etiqueta: 'Nota (opcional; escriba "ok" si llegó completo)');
                      if (nota != null) await accion(() => db.rpc('confirmar_recibido_satelite', params: {'p_id': id, 'p_nota': nota}), 'Recibo confirmado');
                    },
                    icon: const Icon(Icons.check),
                    label: const Text('Confirmar que llegó')),
                if (editar && abierta && pendientes.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () async {
                      final lineas = await showDialog<List<Map<String, dynamic>>>(context: context, builder: (_) => _DialogoDevolucion(unidades: pendientes));
                      if (lineas != null) {
                        await accion(() => db.rpc('registrar_devolucion', params: {'p_salida': id, 'p_lineas': lineas}), 'Devolución registrada');
                      }
                    },
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text('Registrar devolución')),
                if (editar && r['estado'] == 'enviada')
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                    onPressed: () async {
                      final m = await pedirTexto(context, titulo: 'Anular ${r['consecutivo']}', etiqueta: 'Motivo (los juegos vuelven a esperar el proceso)');
                      if (m != null) await accion(() => db.rpc('anular_remision', params: {'p_id': id, 'p_motivo': m}), 'Remisión anulada');
                    },
                    child: const Text('Anular')),
              ]),
          if (r['estado'] == 'anulada') AvisoSinConexion('Anulada: ${r['motivo_anulacion']}'),
          if (r['recibida_satelite'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Colores.verde, size: 18),
                const SizedBox(width: 8),
                Text('El satélite confirmó que le llegó el ${Formato.fechaHora(DateTime.parse(r['recibida_satelite']))}'
                    '${(r['nota_satelite'] ?? '').toString().isNotEmpty ? ': ${r['nota_satelite']}' : ''}', style: estilo(14)),
              ]),
            ),
          Tarjeta(
            titulo: 'Lo que salió',
            child: Tabla(
              columnas: const ['Juego / paquete', 'OP', 'Referencia', 'Color', 'Talla', 'Prendas', 'Buenas', 'Segundas', 'Faltantes'],
              numericas: const {5, 6, 7, 8},
              filas: [
                for (final u in unidades)
                  DataRow(cells: [
                    DataCell(Text('${u['codigo']}', style: estiloCodigo(13))),
                    DataCell(Text('${u['op'] ?? ''}')),
                    DataCell(Text('${u['referencia'] ?? ''}')),
                    DataCell(Row(children: [muestraColor(u['color_hex'] as String?), const SizedBox(width: 6), Text('${u['color']}')])),
                    DataCell(Text('${u['talla']}', style: estilo(14, peso: FontWeight.w700))),
                    DataCell(Text('${u['cantidad']}')),
                    DataCell(Text(u['buenas'] == null ? 'En el satélite' : '${u['buenas']}', style: TextStyle(color: u['buenas'] == null ? Colores.ambar : null))),
                    DataCell(Text('${u['segundas'] ?? ''}')),
                    DataCell(Text('${u['faltantes'] ?? ''}', style: TextStyle(color: ((u['faltantes'] ?? 0) as int) > 0 ? Colores.rojo : null))),
                  ]),
              ],
            ),
          ),
          if (insumos.isNotEmpty) ...[
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Insumos enviados',
              child: Tabla(
                columnas: const ['Insumo', 'Color', 'OP', 'Cantidad'],
                numericas: const {3},
                filas: [
                  for (final i in insumos)
                    DataRow(cells: [
                      DataCell(Text('${i['material'] ?? ''}')),
                      DataCell(Text('${i['color'] ?? '—'}')),
                      DataCell(Text('${i['op'] ?? ''}')),
                      DataCell(Text('${Formato.numero(i['cantidad'] as num)} ${i['unidad'] ?? ''}')),
                    ]),
                ],
              ),
            ),
          ],
          if ((r['devoluciones'] as List).isNotEmpty) ...[
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Devoluciones',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final d in (r['devoluciones'] as List).cast<Map<String, dynamic>>())
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${d['consecutivo']} · ${Formato.fechaHora(DateTime.parse(d['creado_en']))}', style: estiloCodigo(13.5)),
                    subtitle: Text(() {
                      final us = (d['remision_unidades'] as List).cast<Map<String, dynamic>>();
                      int s(String k) => us.fold<int>(0, (a, u) => a + ((u[k] ?? 0) as int));
                      return '${us.length} juegos/paquetes · ${s('buenas')} buenas · ${s('segundas')} segundas · ${s('faltantes')} faltantes'
                          '${(d['observacion'] ?? '').toString().isNotEmpty ? ' · ${d['observacion']}' : ''}';
                    }()),
                    trailing: IconButton(
                      tooltip: 'Imprimir',
                      icon: const Icon(Icons.print_outlined),
                      onPressed: () async {
                        final bytes = await remisionPdf(d, unidadesDeRemision(d, cat), const []);
                        await Printing.layoutPdf(onLayout: (_) async => bytes, name: '${d['consecutivo']}');
                      },
                    ),
                  ),
              ]),
            ),
          ],
          if ((r['cuentas'] as List).isNotEmpty) ...[
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Cuentas por pagar de esta remisión',
              child: Tabla(
                columnas: const ['Cuenta', 'OP', 'Prendas buenas', 'Por prenda', 'Valor', 'Estado'],
                numericas: const {2, 3, 4},
                filas: [
                  for (final c in (r['cuentas'] as List).cast<Map<String, dynamic>>())
                    DataRow(cells: [
                      DataCell(Text('${c['consecutivo']}', style: estiloCodigo(13))),
                      DataCell(Text('${c['ordenes_produccion']?['consecutivo'] ?? ''}')),
                      DataCell(Text('${c['cantidad']}')),
                      DataCell(Text(c['valor_unidad'] == null ? 'Sin tarifa' : Formato.cop(c['valor_unidad']))),
                      DataCell(Text(c['valor'] == null ? '—' : Formato.cop(c['valor']))),
                      DataCell(Text('${c['estado']}')),
                    ]),
                ],
              ),
            ),
          ],
        ]);
      },
    );
  }
}

class _DialogoDevolucion extends StatefulWidget {
  const _DialogoDevolucion({required this.unidades});
  final List<Map<String, dynamic>> unidades;
  @override
  State<_DialogoDevolucion> createState() => _DialogoDevolucionState();
}

class _DialogoDevolucionState extends State<_DialogoDevolucion> {
  late final _incluir = {for (final u in widget.unidades) u['unidad_id'] as String: true};
  late final _buenas = {for (final u in widget.unidades) u['unidad_id'] as String: u['cantidad'] as int};
  late final _segundas = {for (final u in widget.unidades) u['unidad_id'] as String: 0};

  @override
  Widget build(BuildContext context) {
    final elegidas = widget.unidades.where((u) => _incluir[u['unidad_id']] == true).toList();
    final malas = elegidas.any((u) => _buenas[u['unidad_id']]! + _segundas[u['unidad_id']]! > (u['cantidad'] as int));
    Widget contador(Map<String, int> m, String id, int max) => Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(onPressed: m[id]! > 0 ? () => setState(() => m[id] = m[id]! - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
          SizedBox(width: 36, child: Text('${m[id]}', textAlign: TextAlign.center, style: estilo(16, peso: FontWeight.w700))),
          IconButton(onPressed: m[id]! < max ? () => setState(() => m[id] = m[id]! + 1) : null, icon: const Icon(Icons.add_circle_outline)),
        ]);
    return AlertDialog(
      title: const Text('Registrar devolución'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('Cuente lo que llegó de cada juego o paquete. Lo que no sea buena ni segunda queda como faltante.', style: estilo(14)),
            const SizedBox(height: 8),
            for (final u in widget.unidades)
              () {
                final id = u['unidad_id'] as String;
                final total = u['cantidad'] as int;
                final faltan = total - _buenas[id]! - _segundas[id]!;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Checkbox(value: _incluir[id], onChanged: (v) => setState(() => _incluir[id] = v!)),
                    SizedBox(width: 170, child: Text('${u['codigo']} · ${u['talla']} · $total', style: estiloCodigo(13))),
                    Text('Buenas', style: estilo(13, color: Colores.textoSuave)),
                    contador(_buenas, id, total - _segundas[id]!),
                    const SizedBox(width: 8),
                    Text('Segundas', style: estilo(13, color: Colores.textoSuave)),
                    contador(_segundas, id, total - _buenas[id]!),
                    const SizedBox(width: 8),
                    Text('Faltan $faltan', style: estilo(13.5, peso: FontWeight.w600, color: faltan > 0 ? Colores.rojo : Colores.textoSuave)),
                  ]),
                );
              }(),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: elegidas.isEmpty || malas
              ? null
              : () => Navigator.pop(context, [
                    for (final u in elegidas)
                      {
                        'unidad_id': u['unidad_id'],
                        'buenas': _buenas[u['unidad_id']],
                        'segundas': _segundas[u['unidad_id']],
                        'faltantes': (u['cantidad'] as int) - _buenas[u['unidad_id']]! - _segundas[u['unidad_id']]!,
                      },
                  ]),
          child: Text('Registrar ${elegidas.length}'),
        ),
      ],
    );
  }
}
