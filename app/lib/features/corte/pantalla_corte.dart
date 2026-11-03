import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/calculos/corte.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, muestraColor, numeroCo, pedirTexto;
import 'datos_corte.dart';
import 'impresion_corte.dart';
import 'vista_tendido.dart';

final lotesCorteProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>(
    (ref, id) async => (await db.rpc('corte_verificar_lotes', params: {'p_corte': id}) as List).cast<Map<String, dynamic>>());

bool _puedeAprobarCorte(WidgetRef ref) => ref.watch(sesionProvider).value?.permisos.any((p) => p.modulo == 'corte' && p.aprobar) ?? false;

class PantallaCorte extends ConsumerWidget {
  const PantallaCorte({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(contextoCorteProvider(id));
    return datos.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
      data: (k) => _EditorCorte(key: ValueKey('${k.corte['estado']}${k.corte['actualizado_en']}'), k: k),
    );
  }
}

class _EditorCorte extends ConsumerStatefulWidget {
  const _EditorCorte({super.key, required this.k});
  final ContextoCorte k;
  @override
  ConsumerState<_EditorCorte> createState() => _EditorCorteState();
}

class _EditorCorteState extends ConsumerState<_EditorCorte> {
  ContextoCorte get k => widget.k;
  late DocumentoCorte doc;
  late String tipo;
  String? mesa;
  String? cortador;
  late double despunte;
  var sucio = false;
  var ocupado = false;

  @override
  void initState() {
    super.initState();
    doc = DocumentoCorte.desdeJson(k.corte['documento'] as Map<String, dynamic>?);
    tipo = '${k.corte['tipo']}';
    mesa = k.corte['estacion_id'] as String? ?? (k.mesas.isNotEmpty ? k.mesas.first['id'] as String : null);
    cortador = k.corte['cortador_id'] as String?;
    despunte = ((k.corte['despunte_cm'] ?? 2) as num).toDouble();
    if (doc.bloques.isEmpty && !k.confirmado) {
      doc.bloques.addAll(k.bloquesPorDefecto());
      sucio = true;
    }
    if (k.corte['estacion_id'] == null && mesa != null) sucio = true;
  }

  void cambiar(VoidCallback f) => setState(() {
        f();
        sucio = true;
      });

  Future<void> guardar({bool avisarOk = true}) async {
    await db.rpc('guardar_corte', params: {
      'p': {
        'id': k.corte['id'],
        'tipo': tipo,
        'estacion_id': mesa,
        'cortador_id': cortador,
        'despunte_cm': despunte,
        'observacion': k.corte['observacion'],
        'documento': doc.aJson(),
      }
    });
    if (mounted) setState(() => sucio = false);
    ref.invalidate(lotesCorteProvider(k.corte['id']));
    if (avisarOk && mounted) avisar(context, 'Corte guardado');
  }

  Future<void> _accion(Future<void> Function() f) async {
    if (ocupado) return;
    setState(() => ocupado = true);
    try {
      await f();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
  }

  Future<void> confirmar() => _accion(() async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Confirmar ${k.corte['consecutivo']}'),
            content: const SizedBox(
              width: 460,
              child: Text('Se descuenta la tela de cada rollo en el kardex (con la OP), se libera esa reserva, se crean los paquetes '
                  'y los retazos. Después no se puede editar: solo anular con un motivo.'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Confirmar corte')),
            ],
          ),
        );
        if (ok != true) return;
        await guardar(avisarOk: false);
        final r = await db.rpc('confirmar_corte', params: {'p_corte': k.corte['id']}) as Map<String, dynamic>;
        if (!mounted) return;
        avisar(context, 'Corte confirmado: ${r['paquetes']} paquetes'
            '${(r['alertas_desviacion'] as int) > 0 ? ' · ${r['alertas_desviacion']} alerta(s) de consumo' : ''}');
        ref.invalidate(contextoCorteProvider(k.corte['id']));
      });

  @override
  Widget build(BuildContext context) {
    final editar = (ref.watch(sesionProvider).value?.puedeEditar('corte') ?? false) && !k.confirmado;
    final aprobar = _puedeAprobarCorte(ref);
    final c = k.corte;
    final opActiva = k.op['estado'] == 'planeada' || k.op['estado'] == 'en_proceso';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('${c['consecutivo']} · ${k.op['consecutivo']} · ${k.op['referencias']['codigo']} ${k.op['referencias']['nombre']}',
          subtitulo: '${nombreTipoCorte(tipo)} · ${Formato.numero(k.op['cantidad_total'], decimales: 0)} prendas en la OP · ficha v${k.op['ficha_versiones']['version']}'
              '${c['confirmado_en'] != null ? ' · confirmado el ${Formato.fechaHora(DateTime.parse(c['confirmado_en']))}' : ''}',
          acciones: [
            _pastillaEstado('${c['estado']}'),
            OutlinedButton(onPressed: () => context.go('/corte'), child: const Text('Volver')),
            OutlinedButton.icon(
                onPressed: () async {
                  final bytes = await instruccionesCortePdf(k, doc);
                  await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'Instrucciones ${c['consecutivo']}');
                },
                icon: const Icon(Icons.print_outlined),
                label: const Text('Instrucciones de mesa')),
            OutlinedButton(onPressed: () => context.go('/corte/op/${k.op['id']}'), child: const Text('Piezas y juegos de la OP')),
            if (editar) ...[
              OutlinedButton.icon(
                  onPressed: sucio && !ocupado ? () => _accion(guardar) : null,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(sucio ? 'Guardar' : 'Guardado')),
              FilledButton.icon(onPressed: ocupado || !opActiva ? null : confirmar, icon: const Icon(Icons.check), label: const Text('Confirmar corte')),
            ],
            if (c['estado'] != 'anulado' && (editar || (aprobar && c['estado'] == 'confirmado')))
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colores.rojo),
                onPressed: () async {
                  final m = await pedirTexto(context, titulo: 'Anular ${c['consecutivo']}',
                      etiqueta: c['estado'] == 'confirmado' ? 'Motivo (la tela vuelve a los rollos con movimientos inversos)' : 'Motivo');
                  if (m == null) return;
                  await _accion(() async {
                    await db.rpc('anular_corte', params: {'p_corte': c['id'], 'p_motivo': m});
                    ref.invalidate(contextoCorteProvider(c['id']));
                  });
                },
                child: const Text('Anular')),
          ]),
      if (c['estado'] == 'anulado') AvisoSinConexion('Anulado: ${c['motivo_anulacion']}'),
      if (ocupado) const LinearProgressIndicator(),
      _datosGenerales(editar),
      const SizedBox(height: 16),
      if (!k.confirmado) ...[_TarjetaLotes(k: k, aprobar: aprobar, sucio: sucio, onGuardar: () => _accion(guardar)), const SizedBox(height: 16)],
      for (final b in doc.bloques) ...[
        _TarjetaBloque(
          key: ValueKey(b.id),
          k: k,
          doc: doc,
          b: b,
          despunte: despunte,
          editable: editar,
          onCambio: cambiar,
          onQuitar: () => cambiar(() => doc.bloques.remove(b)),
        ),
        const SizedBox(height: 16),
      ],
      if (editar)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => cambiar(() => doc.bloques.add(BloqueEd(nombre: 'Tendido ${doc.bloques.length + 1}', tallas: [for (final t in k.tallas) t['id'] as String]))),
            icon: const Icon(Icons.add),
            label: const Text('Agregar tendido (otra tela o partes)'),
          ),
        ),
      if (k.confirmado) _ResultadoConfirmado(k: k),
    ]);
  }

  Widget _datosGenerales(bool editar) {
    final c = k.corte;
    if (!editar) {
      return Tarjeta(
        child: Wrap(spacing: 28, runSpacing: 10, children: [
          _dato('Tipo', nombreTipoCorte(tipo)),
          _dato('Mesa', '${c['estaciones']?['codigo'] ?? '—'} ${c['estaciones']?['nombre'] ?? ''}'),
          _dato('Cortador', k.nombreCortador(c['empleados'] as Map<String, dynamic>?)),
          _dato('Despunte', '${Formato.numero(despunte, decimales: 1)} cm por capa'),
        ]),
      );
    }
    return Tarjeta(
      child: Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'un_color', label: Text('Un color')),
            ButtonSegment(value: 'multicolor', label: Text('Multicolor')),
            ButtonSegment(value: 'combinada', label: Text('Prenda combinada')),
          ],
          selected: {tipo},
          onSelectionChanged: (s) => cambiar(() => tipo = s.first),
        ),
        _Desplegable(
          etiqueta: 'Mesa de corte',
          ancho: 200,
          valor: mesa,
          opciones: {for (final m in k.mesas) m['id'] as String: '${m['codigo']} · ${m['nombre']}'},
          onCambio: (v) => cambiar(() => mesa = v),
        ),
        _Desplegable(
          etiqueta: 'Cortador',
          ancho: 240,
          valor: cortador,
          opciones: {'': '—', for (final e in k.cortadores) e['id'] as String: '${e['codigo']} · ${k.nombreCortador(e)}'},
          onCambio: (v) => cambiar(() => cortador = (v == null || v.isEmpty) ? null : v),
        ),
        SizedBox(
          width: 150,
          child: CampoNum(
            etiqueta: 'Despunte (cm/capa)',
            valor: despunte,
            decimales: 1,
            onCambio: (v) => cambiar(() => despunte = v ?? 0),
          ),
        ),
        Text(switch (tipo) {
          'un_color' => 'Toda la prenda de un color: cada tendido lleva un solo color.',
          'multicolor' => 'Varios colores en el mismo tendido (capas de cada color).',
          _ => 'Partes de distinto color o tela: se cortan por separado y se arman juegos completos.',
        }, style: estilo(13, color: Colores.textoSuave)),
      ]),
    );
  }
}

Widget _dato(String etiqueta, String valor) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(etiqueta, style: estilo(12, color: Colores.textoSuave)),
      Text(valor, style: estilo(14, peso: FontWeight.w600)),
    ]);

Pastilla _pastillaEstado(String e) => switch (e) {
      'borrador' => const Pastilla('Borrador', color: Colores.textoSuave),
      'confirmado' => const Pastilla('Confirmado', color: Colores.verde),
      _ => const Pastilla('Anulado', color: Colores.rojo),
    };

// ---------------------------------------------------------------------------
// Regla 8: lotes, tonos y anchos
// ---------------------------------------------------------------------------
class _TarjetaLotes extends ConsumerWidget {
  const _TarjetaLotes({required this.k, required this.aprobar, required this.sucio, required this.onGuardar});
  final ContextoCorte k;
  final bool aprobar;
  final bool sucio;
  final VoidCallback onGuardar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = k.corte['id'] as String;
    final lotes = ref.watch(lotesCorteProvider(id));
    return lotes.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text(mensajeError(e), style: estilo(13, color: Colores.rojo)),
      data: (l) {
        if (l.isEmpty) {
          return Row(children: [
            const Icon(Icons.verified_outlined, color: Colores.verde, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(sucio ? 'Guarde para revisar lotes y anchos de los rollos.' : 'Lotes, tonos y anchos al día: un solo lote por color en la OP.',
                    style: estilo(13, color: Colores.textoSuave))),
            if (sucio) TextButton(onPressed: onGuardar, child: const Text('Guardar y revisar')),
          ]);
        }
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colores.ambar.withValues(alpha: 0.08),
              border: Border.all(color: Colores.ambar.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Regla de lotes: necesita autorización del jefe de corte', style: estilo(14, peso: FontWeight.w600, color: Colores.ambar)),
            const SizedBox(height: 6),
            for (final x in l)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(x['autorizado'] == true ? Icons.check_circle : Icons.warning_amber_rounded,
                      color: x['autorizado'] == true ? Colores.verde : Colores.ambar, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${x['mensaje']}', style: estilo(13))),
                  if (x['autorizado'] == true)
                    Text('Autorizado', style: estilo(13, peso: FontWeight.w600, color: Colores.verde))
                  else if (aprobar)
                    FilledButton.tonal(
                      onPressed: () async {
                        final m = await pedirTexto(context, titulo: 'Autorizar mezcla', etiqueta: 'Motivo (queda registrado con su nombre)');
                        if (m == null) return;
                        try {
                          await db.rpc('autorizar_corte', params: {'p_corte': id, 'p_material': x['material_id'], 'p_color': x['color_id'], 'p_motivo': m});
                          ref.invalidate(lotesCorteProvider(id));
                        } catch (e) {
                          if (context.mounted) avisar(context, mensajeError(e), error: true);
                        }
                      },
                      child: const Text('Autorizar'))
                  else
                    Text('Pida autorización al jefe de corte', style: estilo(12.5, color: Colores.textoSuave)),
                ]),
              ),
            Text('Los paquetes nunca mezclan lotes: cada lote sale en sus propios paquetes.', style: estilo(12.5, color: Colores.textoSuave)),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Un tendido (bloque): tela, partes, trazo, rollos y resultado en vivo
// ---------------------------------------------------------------------------
class _TarjetaBloque extends StatelessWidget {
  const _TarjetaBloque({
    super.key,
    required this.k,
    required this.doc,
    required this.b,
    required this.despunte,
    required this.editable,
    required this.onCambio,
    required this.onQuitar,
  });
  final ContextoCorte k;
  final DocumentoCorte doc;
  final BloqueEd b;
  final double despunte;
  final bool editable;
  final void Function(VoidCallback) onCambio;
  final VoidCallback onQuitar;

  @override
  Widget build(BuildContext context) {
    final calculo = b.aCalculo(k.rollos);
    ResultadoBloque? r;
    String? error;
    try {
      r = calcularBloque(calculo, despunteCm: despunte);
    } catch (e) {
      error = e is ArgumentError ? '${e.message}' : '$e';
    }
    final material = k.materiales[b.materialId];
    final unidad = '${material?['unidad'] ?? ''}';
    final colores = {...k.coloresDe(b), ...b.tramos.map((t) => t.colorId)}.toList();

    return Tarjeta(
      titulo: '${b.nombre}${material != null ? ' · ${material['nombre']}' : ''}',
      accion: editable
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              _MenuPlantillas(k: k, b: b, onCambio: onCambio),
              IconButton(tooltip: 'Quitar tendido', onPressed: onQuitar, icon: const Icon(Icons.delete_outline)),
            ])
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ---- tela y partes ----
        if (editable)
          Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 220, child: CampoTexto(etiqueta: 'Nombre del tendido', valor: b.nombre, onCambio: (v) => onCambio(() => b.nombre = v))),
            _Desplegable(
              etiqueta: 'Tela',
              ancho: 280,
              valor: b.materialId,
              opciones: {for (final m in k.telasFicha) m['id'] as String: '${m['nombre']} (${m['unidad']})'},
              onCambio: (v) => onCambio(() {
                b.materialId = v;
                b.tramos.removeWhere((t) => k.rollos[t.rolloId]?['material_id'] != v);
              }),
            ),
            Text('Partes:', style: estilo(13, color: Colores.textoSuave)),
            for (final p in k.partes)
              FilterChip(
                label: Text('${p['nombre']}'),
                selected: b.partes.contains(p['id']),
                onSelected: (s) => onCambio(() {
                  s ? b.partes.add(p['id'] as String) : b.partes.remove(p['id']);
                  b.partes.sort((x, y) => k.partes.indexWhere((q) => q['id'] == x).compareTo(k.partes.indexWhere((q) => q['id'] == y)));
                }),
              ),
          ])
        else
          Text('Partes: ${b.partes.map(k.parte).join(', ')}', style: estilo(13, color: Colores.textoSuave)),
        const SizedBox(height: 14),
        // ---- trazo ----
        Row(children: [
          Text('Trazo', style: estilo(14, peso: FontWeight.w600)),
          const SizedBox(width: 12),
          if (editable)
            SegmentedButton<int>(
              segments: const [ButtonSegment(value: 1, label: Text('Normal')), ButtonSegment(value: 2, label: Text('Por espigas'))],
              selected: {b.esEspigas ? 2 : 1},
              onSelectionChanged: (s) => onCambio(() {
                if (s.first == 1) {
                  b.secciones.removeRange(1, b.secciones.length);
                  for (final t in b.tramos) {
                    t.espiga = 1;
                  }
                } else if (b.secciones.length == 1) {
                  b.secciones.add(SeccionEd(letra: 'B'));
                }
              }),
            )
          else
            Text(b.esEspigas ? 'Por espigas (${b.secciones.length} secciones)' : 'Normal', style: estilo(13, color: Colores.textoSuave)),
          if (editable && b.esEspigas) ...[
            const SizedBox(width: 12),
            _Desplegable(
              etiqueta: 'Secciones',
              ancho: 120,
              valor: '${b.secciones.length}',
              opciones: {for (var i = 2; i <= 5; i++) '$i': '$i'},
              onCambio: (v) => onCambio(() {
                final n = int.parse(v!);
                while (b.secciones.length < n) {
                  b.secciones.add(SeccionEd(letra: String.fromCharCode(65 + b.secciones.length)));
                }
                if (b.secciones.length > n) b.secciones.removeRange(n, b.secciones.length);
                for (final t in b.tramos) {
                  if (t.espiga > n) t.espiga = n;
                }
              }),
            ),
            const SizedBox(width: 8),
            if (colores.isNotEmpty)
              TextButton.icon(
                onPressed: () => onCambio(() {
                  final o = ordenarPorDemanda([for (final s in calculo.secciones) s], k.pendiente(b, colores.first));
                  final copia = [
                    for (final s in o) SeccionEd(letra: s.letra, largo: s.largoM, unidades: {...s.unidades}),
                  ];
                  b.secciones
                    ..clear()
                    ..addAll(copia);
                }),
                icon: const Icon(Icons.sort, size: 18),
                label: const Text('Ordenar por demanda'),
              ),
          ],
        ]),
        const SizedBox(height: 8),
        _TablaTrazo(k: k, b: b, r: r, editable: editable, onCambio: onCambio),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error, style: estilo(13, color: Colores.rojo))),
        const SizedBox(height: 16),
        // ---- tendido ----
        Row(children: [
          Text('Tendido (rollos y capas)', style: estilo(14, peso: FontWeight.w600)),
          const Spacer(),
          if (editable)
            for (final col in colores)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: TextButton.icon(
                  onPressed: () => _sugerir(context, col),
                  icon: muestraColor(k.hex(col)),
                  label: Text('Sugerir capas ${k.color(col)}'),
                ),
              ),
          if (editable && b.materialId != null)
            OutlinedButton.icon(
              onPressed: () => onCambio(() {
                final libres = k.rollosDe(b).where((x) => !b.tramos.any((t) => t.rolloId == x['id'])).toList();
                if (libres.isEmpty) return;
                final r0 = libres.first;
                b.tramos.add(TramoEd(rolloId: r0['id'], colorId: r0['color_id']));
              }),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Agregar rollo'),
            ),
        ]),
        const SizedBox(height: 6),
        _TablaTramos(k: k, doc: doc, b: b, despunte: despunte, editable: editable, onCambio: onCambio),
        const SizedBox(height: 14),
        if (r != null) ...[
          VistaTendido(bloque: calculo, resultado: r, colorHex: k.hex),
          const SizedBox(height: 14),
          _PedidoVsCortado(k: k, b: b, r: r, unidad: unidad, despunte: despunte),
        ],
      ]),
    );
  }

  void _sugerir(BuildContext context, String colorId) {
    final pend = k.pendiente(b, colorId);
    final calc = b.aCalculo(k.rollos);
    final texto = [for (final t in b.tallas) if ((pend[t] ?? 0) > 0) '${k.talla(t)} ${pend[t]}'].join(' · ');
    if (pend.values.every((v) => v <= 0)) {
      avisar(context, 'No falta nada por cortar de ${k.color(colorId)} en estas partes');
      return;
    }
    late List<int> capas;
    if (!b.esEspigas) {
      final c = sugerirCapasNormal(calc.secciones.first.unidades, pend);
      if (c == null) {
        avisar(context, 'El trazo no tiene todas las tallas pedidas ($texto)', error: true);
        return;
      }
      capas = [c];
    } else {
      capas = sugerirEspigas(calc.secciones, pend);
    }
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Capas sugeridas · ${k.color(colorId)}'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Falta cortar: $texto', style: estilo(14)),
            const SizedBox(height: 10),
            Text(b.esEspigas ? [for (var i = 0; i < capas.length; i++) 'Espiga ${i + 1}: ${capas[i]} capas'].join('\n') : '${capas.first} capas',
                style: estilo(16, peso: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Al aplicar se reparten entre los rollos de ese color sin pasar su saldo, primero los del mismo lote.', style: estilo(12.5, color: Colores.textoSuave)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cerrar')),
          FilledButton(
            onPressed: () {
              Navigator.pop(d);
              onCambio(() {
                // rollos de ese color: primero los ya puestos, luego los de su mismo lote, luego el resto (más metros primero)
                final puestos = [for (final t in b.tramos) if (t.colorId == colorId) t.rolloId];
                final candidatos = k.rollosDe(b).where((x) => x['color_id'] == colorId).toList();
                final loteBase = candidatos.where((x) => puestos.contains(x['id'])).firstOrNull?['lote_tintura'] ??
                    (candidatos.toList()..sort((x, y) => (y['metros_saldo'] as num).compareTo(x['metros_saldo'] as num))).firstOrNull?['lote_tintura'];
                int orden(Map<String, dynamic> x) => puestos.contains(x['id']) ? 0 : x['lote_tintura'] == loteBase ? 1 : 2;
                candidatos.sort((x, y) {
                  final c = orden(x).compareTo(orden(y));
                  return c != 0 ? c : (y['metros_saldo'] as num).compareTo(x['metros_saldo'] as num);
                });
                if (candidatos.isEmpty) {
                  avisar(context, 'No hay rollos de ${k.materiales[b.materialId]?['nombre'] ?? 'esa tela'} ${k.color(colorId)} con saldo', error: true);
                  return;
                }
                // lo que ya usan otros tendidos del mismo rollo no está disponible
                final usadoOtros = <String, double>{};
                for (final otro in doc.bloques.where((x) => x != b)) {
                  try {
                    calcularBloque(otro.aCalculo(k.rollos), despunteCm: despunte).metrosPorRollo.forEach((r, m) => usadoOtros[r] = (usadoOtros[r] ?? 0) + m);
                  } catch (_) {}
                }
                final rep = repartirCapas(
                  rollos: [for (final x in candidatos) (id: x['id'] as String, metros: (x['metros_saldo'] as num).toDouble() - (usadoOtros[x['id']] ?? 0))],
                  capasPorEspiga: capas,
                  metrosPorCapa: [for (var e = 1; e <= capas.length; e++) calc.largoEspiga(e) + despunte / 100],
                );
                b.tramos.removeWhere((t) => t.colorId == colorId);
                b.tramos.addAll([for (final t in rep.tramos) TramoEd(rolloId: t.rolloId, colorId: colorId, espiga: t.espiga, capas: t.capas)]);
                if (rep.sinRollo > 0) avisar(context, 'No hay rollos de ${k.color(colorId)} para ${rep.sinRollo} capas: falta tela', error: true);
              });
            },
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
  }
}

class _TablaTrazo extends StatelessWidget {
  const _TablaTrazo({required this.k, required this.b, required this.r, required this.editable, required this.onCambio});
  final ContextoCorte k;
  final BloqueEd b;
  final ResultadoBloque? r;
  final bool editable;
  final void Function(VoidCallback) onCambio;

  @override
  Widget build(BuildContext context) {
    final enc = estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(78),
        columnWidths: const {0: FixedColumnWidth(110), 1: FixedColumnWidth(100)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            Padding(padding: const EdgeInsets.all(6), child: Text('Sección', style: enc)),
            Padding(padding: const EdgeInsets.all(6), child: Text('Largo (m)', style: enc)),
            for (final t in b.tallas) Padding(padding: const EdgeInsets.all(6), child: Text('${k.talla(t)} / capa', style: enc, textAlign: TextAlign.center)),
            Padding(padding: const EdgeInsets.all(6), child: Text('Capas', style: enc, textAlign: TextAlign.right)),
          ]),
          for (final (i, s) in b.secciones.indexed)
            TableRow(children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(b.esEspigas ? '${s.letra}${i == 0 ? ' (cabecera)' : ''}' : 'Trazo', style: estilo(13.5, peso: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.all(4),
                child: editable
                    ? CampoNum(valor: s.largo, decimales: 3, onCambio: (v) => onCambio(() => s.largo = v ?? 0))
                    : Text(Formato.numero(s.largo, decimales: 3)),
              ),
              for (final t in b.tallas)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: editable
                      ? CampoNum(valor: (s.unidades[t] ?? 0).toDouble(), decimales: 0, onCambio: (v) => onCambio(() => s.unidades[t] = (v ?? 0).round()))
                      : Text('${s.unidades[t] ?? 0}', textAlign: TextAlign.center),
                ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text('${r != null && r!.capasSeccion.length > i ? r!.capasSeccion[i] : 0}',
                    textAlign: TextAlign.right, style: estilo(14, peso: FontWeight.w700)),
              ),
            ]),
        ],
      ),
    );
  }
}

class _TablaTramos extends StatelessWidget {
  const _TablaTramos({required this.k, required this.doc, required this.b, required this.despunte, required this.editable, required this.onCambio});
  final ContextoCorte k;
  final DocumentoCorte doc;
  final BloqueEd b;
  final double despunte;
  final bool editable;
  final void Function(VoidCallback) onCambio;

  @override
  Widget build(BuildContext context) {
    if (b.tramos.isEmpty) {
      return Text(b.materialId == null ? 'Elija la tela del tendido.' : 'Agregue los rollos que va a tender.', style: estilo(13, color: Colores.textoSuave));
    }
    final rollos = k.rollosDe(b);
    // metros de cada tramo: capas × (largo de las secciones de su espiga + despunte)
    double metrosTramo(TramoEd t) => t.capas <= 0 || t.espiga > b.secciones.length
        ? 0
        : redondear(t.capas * (b.secciones.take(b.secciones.length - t.espiga + 1).fold(0.0, (a, s) => a + s.largo) + despunte / 100), 2);
    return Column(children: [
      for (final t in b.tramos)
        Padding(
          key: ValueKey(t.clave),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            muestraColor(k.hex(t.colorId), tam: 18),
            if (editable)
              _Desplegable(
                etiqueta: 'Rollo',
                ancho: 330,
                valor: t.rolloId,
                opciones: {
                  for (final x in rollos)
                    x['id'] as String: '${x['codigo']} · ${k.color(x['color_id'])} · ${x['lote_tintura']}${x['tono'] != null ? ' ${x['tono']}' : ''}'
                        ' · ${Formato.numero(x['ancho_real_cm'], decimales: 1)} cm · ${Formato.numero(x['metros_saldo'])} m${x['es_retazo'] == true ? ' (retazo)' : ''}',
                },
                onCambio: (v) => onCambio(() {
                  t.rolloId = v!;
                  t.colorId = k.rollos[v]!['color_id'] as String;
                }),
              )
            else
              SizedBox(
                  width: 330,
                  child: Text('${k.rollos[t.rolloId]?['codigo'] ?? '?'} · ${k.color(t.colorId)} · lote ${k.rollos[t.rolloId]?['lote_tintura'] ?? ''}',
                      style: estilo(13.5, peso: FontWeight.w600))),
            if (b.esEspigas)
              editable
                  ? _Desplegable(
                      etiqueta: 'Espiga',
                      ancho: 150,
                      valor: '${t.espiga}',
                      opciones: {
                        for (var e = 1; e <= b.secciones.length; e++)
                          '$e': 'E$e · ${b.secciones.take(b.secciones.length - e + 1).map((s) => s.letra).join('')}',
                      },
                      onCambio: (v) => onCambio(() => t.espiga = int.parse(v!)),
                    )
                  : Text('Espiga ${t.espiga}', style: estilo(13.5)),
            SizedBox(
              width: 90,
              child: editable
                  ? CampoNum(etiqueta: 'Capas', valor: t.capas.toDouble(), decimales: 0, onCambio: (v) => onCambio(() => t.capas = (v ?? 0).round()))
                  : Text('${t.capas} capas', style: estilo(13.5, peso: FontWeight.w600)),
            ),
            Text('${Formato.numero(metrosTramo(t))} m', style: estilo(12.5, color: Colores.textoSuave)),
            _saldoRollo(t),
            if (editable) _finRollo(t),
            if (editable)
              IconButton(tooltip: 'Quitar', onPressed: () => onCambio(() => b.tramos.remove(t)), icon: const Icon(Icons.close, size: 18)),
          ]),
        ),
    ]);
  }

  Widget _saldoRollo(TramoEd t) {
    final x = k.rollos[t.rolloId];
    if (x == null) return const SizedBox.shrink();
    // todo lo que se tiende de este rollo en el corte (todos los tendidos)
    var total = 0.0;
    for (final bb in doc.bloques) {
      try {
        total += calcularBloque(bb.aCalculo(k.rollos), despunteCm: despunte).metrosPorRollo[t.rolloId] ?? 0;
      } catch (_) {}
    }
    final saldo = (x['metros_saldo'] as num).toDouble();
    final falta = total > saldo * 1.03 + 0.01;
    return Text(
      falta
          ? 'No alcanza: necesita ${Formato.numero(total)} m y tiene ${Formato.numero(saldo)} m'
          : '${Formato.numero(total)} de ${Formato.numero(saldo)} m · ≈ ${Formato.numero(k.kilos(t.rolloId, total), decimales: 2)} kg',
      style: estilo(12.5, peso: falta ? FontWeight.w700 : FontWeight.w400, color: falta ? Colores.rojo : Colores.textoSuave),
    );
  }

  Widget _finRollo(TramoEd t) {
    final f = doc.rollos[t.rolloId] ??= FinRollo();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _Desplegable(
        etiqueta: 'Lo que sobra',
        ancho: 165,
        valor: f.fin,
        opciones: const {'vuelve': 'Vuelve a bodega', 'retazo': 'Pasa a retazo', 'agotado': 'Agotar (desperdicio)'},
        onCambio: (v) => onCambio(() => f.fin = v!),
      ),
      const SizedBox(width: 8),
      if (f.fin != 'agotado')
        SizedBox(
          width: 130,
          child: CampoNum(
            etiqueta: 'Quedó (m)',
            valor: f.restante,
            decimales: 2,
            onCambio: (v) => onCambio(() => f.restante = v),
          ),
        ),
    ]);
  }
}

class _PedidoVsCortado extends StatelessWidget {
  const _PedidoVsCortado({required this.k, required this.b, required this.r, required this.unidad, required this.despunte});
  final ContextoCorte k;
  final BloqueEd b;
  final ResultadoBloque r;
  final String unidad;
  final double despunte;

  @override
  Widget build(BuildContext context) {
    final colores = {...k.coloresDe(b), ...r.piezas.keys}.toList();
    final consumo = k.consumoPorTalla(b);
    final enc = estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Por cortar vs lo que sale del tendido', style: estilo(14, peso: FontWeight.w600)),
      const SizedBox(height: 6),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const FixedColumnWidth(96),
          columnWidths: {0: const FixedColumnWidth(150), b.tallas.length + 1: const FixedColumnWidth(190)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(children: [
              Padding(padding: const EdgeInsets.all(6), child: Text('Color', style: enc)),
              for (final t in b.tallas) Padding(padding: const EdgeInsets.all(6), child: Text(k.talla(t), style: enc, textAlign: TextAlign.center)),
              Padding(padding: const EdgeInsets.all(6), child: Text('Consumo', style: enc, textAlign: TextAlign.right)),
            ]),
            for (final c in colores) _fila(c, consumo),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 14, children: [
        _leyenda(Colores.rojo, 'faltan'),
        _leyenda(Colores.ambar, 'sobran'),
        _leyenda(Colores.verde, 'exacto'),
        Text('Consumo: estimado del tendido frente al estándar de la ficha (alerta si pasa ±${Formato.numero(k.toleranciaDesviacion, decimales: 0)} %)',
            style: estilo(12, color: Colores.textoSuave)),
      ]),
    ]);
  }

  TableRow _fila(String colorId, Map<String, double> consumo) {
    final pend = k.pendiente(b, colorId);
    final cortado = r.piezas[colorId] ?? const {};
    final comp = {for (final x in compararPedidoCortado(b.tallas, pend, cortado)) x.talla: x};
    // consumo estimado del tendido en la unidad del material
    var real = 0.0;
    for (final t in r.tramos.where((t) => t.tramo.colorId == colorId)) {
      real += unidad == 'kg' ? k.kilos(t.tramo.rolloId, t.metros) : t.metros;
    }
    final teo = consumoTeorico(cortado, consumo);
    final dev = desviacion(real, teo);
    final tol = k.toleranciaDesviacion / 100;
    return TableRow(children: [
      Padding(
        padding: const EdgeInsets.all(6),
        child: Row(children: [muestraColor(k.hex(colorId)), const SizedBox(width: 6), Flexible(child: Text(k.color(colorId), style: estilo(13.5, peso: FontWeight.w600)))]),
      ),
      for (final t in b.tallas)
        Padding(
          padding: const EdgeInsets.all(6),
          child: () {
            final x = comp[t];
            if (x == null) return const Text('—', textAlign: TextAlign.center);
            final color = x.faltan ? Colores.rojo : x.sobran ? Colores.ambar : Colores.verde;
            return Column(children: [
              Text('${x.cortado} / ${x.pedido}', style: estilo(13.5, peso: FontWeight.w600, color: color)),
              if (x.diferencia != 0) Text(x.faltan ? 'faltan ${-x.diferencia}' : 'sobran ${x.diferencia}', style: estilo(11.5, color: color)),
            ]);
          }(),
        ),
      Padding(
        padding: const EdgeInsets.all(6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${Formato.numero(real, decimales: unidad == 'kg' ? 2 : 1)} $unidad', style: estilo(13.5, peso: FontWeight.w600)),
          if (dev != null)
            Text('${dev >= 0 ? '+' : ''}${Formato.numero(dev * 100, decimales: 1)} % vs ${Formato.numero(teo, decimales: 2)}',
                style: estilo(11.5, peso: FontWeight.w600, color: dev.abs() > tol * 2 ? Colores.rojo : dev.abs() > tol ? Colores.ambar : Colores.verde)),
        ]),
      ),
    ]);
  }

  Widget _leyenda(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(t, style: estilo(12, color: Colores.textoSuave)),
      ]);
}

// ---------------------------------------------------------------------------
// Plantillas de trazo (por referencia)
// ---------------------------------------------------------------------------
class _MenuPlantillas extends ConsumerWidget {
  const _MenuPlantillas({required this.k, required this.b, required this.onCambio});
  final ContextoCorte k;
  final BloqueEd b;
  final void Function(VoidCallback) onCambio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codigoTalla = {for (final t in k.tallas) t['codigo'] as String: t['id'] as String};
    return PopupMenuButton<String>(
      tooltip: 'Trazos guardados',
      icon: const Icon(Icons.bookmarks_outlined),
      itemBuilder: (_) => [
        for (final t in k.trazos.where((t) => t['material_id'] == null || b.materialId == null || t['material_id'] == b.materialId))
          PopupMenuItem(value: t['id'] as String, child: Text('Usar: ${t['nombre']}')),
        const PopupMenuItem(value: '_guardar', child: Text('Guardar este trazo para la referencia')),
      ],
      onSelected: (v) async {
        if (v == '_guardar') {
          final nombre = await pedirTexto(context, titulo: 'Guardar trazo', etiqueta: 'Nombre (ej. Cuerpo 1-2-2-1)');
          if (nombre == null) return;
          try {
            // las tallas se guardan por código para que sirvan en otras versiones de la ficha
            await db.from('trazos').upsert({
              'referencia_id': k.op['referencias']['id'],
              'nombre': nombre,
              'material_id': b.materialId,
              'partes': b.partes.map(k.parte).toList(),
              'tallas': b.tallas.map(k.talla).toList(),
              'secciones': [
                for (final s in b.secciones)
                  {'letra': s.letra, 'largo_m': s.largo, 'unidades': {for (final e in s.unidades.entries) if (e.value > 0) k.talla(e.key): e.value}},
              ],
            }, onConflict: 'referencia_id,nombre');
            ref.invalidate(contextoCorteProvider(k.corte['id']));
            if (context.mounted) avisar(context, 'Trazo "$nombre" guardado');
          } catch (e) {
            if (context.mounted) avisar(context, mensajeError(e), error: true);
          }
          return;
        }
        final t = k.trazos.firstWhere((x) => x['id'] == v);
        onCambio(() {
          final secciones = (t['secciones'] as List).cast<Map<String, dynamic>>();
          b.secciones
            ..clear()
            ..addAll([
              for (final s in secciones)
                SeccionEd(
                  letra: '${s['letra']}',
                  largo: ((s['largo_m'] ?? 0) as num).toDouble(),
                  unidades: {
                    for (final e in ((s['unidades'] as Map?) ?? {}).entries)
                      if (codigoTalla[e.key] != null) codigoTalla[e.key]!: (e.value as num).toInt(),
                  },
                ),
            ]);
          if (t['material_id'] != null) b.materialId = t['material_id'] as String;
          final partes = [for (final p in k.partes) if ((t['partes'] as List).contains(p['nombre'])) p['id'] as String];
          if (partes.isNotEmpty) {
            b.partes
              ..clear()
              ..addAll(partes);
          }
          for (final x in b.tramos) {
            if (x.espiga > b.secciones.length) x.espiga = b.secciones.length;
          }
        });
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Corte confirmado: paquetes, rollos y consumo
// ---------------------------------------------------------------------------
class _ResultadoConfirmado extends StatefulWidget {
  const _ResultadoConfirmado({required this.k});
  final ContextoCorte k;
  @override
  State<_ResultadoConfirmado> createState() => _ResultadoConfirmadoState();
}

class _ResultadoConfirmadoState extends State<_ResultadoConfirmado> {
  final _colores = <String>{};
  final _tallas = <String>{};

  @override
  Widget build(BuildContext context) {
    final k = widget.k;
    final paquetes = ((k.datos['paquetes'] ?? []) as List).cast<Map<String, dynamic>>();
    final rollos = ((k.datos['corte_rollos'] ?? []) as List).cast<Map<String, dynamic>>();
    final consumos = ((k.datos['consumos'] ?? []) as List).cast<Map<String, dynamic>>();
    final aut = ((k.datos['autorizaciones'] ?? []) as List).cast<Map<String, dynamic>>();
    final colores = {for (final p in paquetes) p['color_id'] as String}.toList();
    final tallas = [for (final t in k.tallas) if (paquetes.any((p) => p['talla_id'] == t['id'])) t['id'] as String];
    final elegidos = paquetes.where((p) => (_colores.isEmpty || _colores.contains(p['color_id'])) && (_tallas.isEmpty || _tallas.contains(p['talla_id']))).toList();
    const fines = {'vuelve': 'Volvió a bodega', 'retazo': 'Retazo', 'agotado': 'Agotado'};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Paquetes (${paquetes.length})',
        accion: FilledButton.icon(
          onPressed: elegidos.isEmpty || k.corte['estado'] != 'confirmado' ? null : () => imprimirPaquetesWeb(context, k, elegidos),
          icon: const Icon(Icons.print_outlined),
          label: Text('Imprimir ${elegidos.length} etiquetas'),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Color:', style: estilo(13, color: Colores.textoSuave)),
            for (final c in colores)
              FilterChip(
                avatar: muestraColor(k.hex(c)),
                label: Text(k.color(c)),
                selected: _colores.contains(c),
                onSelected: (s) => setState(() => s ? _colores.add(c) : _colores.remove(c)),
              ),
            const SizedBox(width: 12),
            Text('Talla:', style: estilo(13, color: Colores.textoSuave)),
            for (final t in tallas)
              FilterChip(label: Text(k.talla(t)), selected: _tallas.contains(t), onSelected: (s) => setState(() => s ? _tallas.add(t) : _tallas.remove(t))),
          ]),
          const SizedBox(height: 8),
          Tabla(
            columnas: const ['Paquete', 'Partes', 'Color', 'Lote', 'Talla', 'Espiga', 'Capas', 'Prendas', 'Estado'],
            numericas: const {7},
            filas: [
              for (final p in elegidos)
                DataRow(cells: [
                  DataCell(Text('${p['codigo']}', style: estiloCodigo(13))),
                  DataCell(Text((p['partes'] as List).map((x) => k.parte('$x')).join(' + '))),
                  DataCell(Row(children: [muestraColor(k.hex(p['color_id'])), const SizedBox(width: 6), Text(k.color(p['color_id']))])),
                  DataCell(Text('${p['lote_tintura']}')),
                  DataCell(Text(k.talla(p['talla_id']), style: estilo(14, peso: FontWeight.w700))),
                  DataCell(Text('${p['espiga']}')),
                  DataCell(Text('${p['capa_desde']}–${p['capa_hasta']}')),
                  DataCell(Text('${p['cantidad']}', style: estilo(14, peso: FontWeight.w600))),
                  DataCell(p['estado'] == 'anulado' ? const Pastilla('Anulado', color: Colores.rojo)
                      : p['completo'] == true ? const Pastilla('Prendas completas', color: Colores.verde) : const Pastilla('Para juego', color: Colores.ambar)),
                ]),
            ],
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Consumo de tela',
        child: Tabla(
          columnas: const ['Tela', 'Color', 'Piezas', 'Estándar', 'Real', 'Desviación'],
          numericas: const {2, 3, 4, 5},
          filas: [
            for (final c in consumos)
              DataRow(cells: [
                DataCell(Text('${k.materiales[c['material_id']]?['nombre'] ?? ''}')),
                DataCell(Text(k.color(c['color_id']))),
                DataCell(Text('${c['piezas']}')),
                DataCell(Text('${Formato.numero(c['teorico'], decimales: 3)} ${k.materiales[c['material_id']]?['unidad'] ?? ''}')),
                DataCell(Text('${Formato.numero(c['real'], decimales: 3)} ${k.materiales[c['material_id']]?['unidad'] ?? ''}')),
                DataCell(() {
                  final d = (c['desviacion_pct'] as num?)?.toDouble();
                  if (d == null) return const Text('—');
                  final tol = k.toleranciaDesviacion;
                  return Text('${d >= 0 ? '+' : ''}${Formato.numero(d, decimales: 1)} %',
                      style: estilo(14, peso: FontWeight.w700, color: d.abs() > tol * 2 ? Colores.rojo : d.abs() > tol ? Colores.ambar : Colores.verde));
                }()),
              ]),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Rollos usados',
        child: Tabla(
          columnas: const ['Rollo', 'Color', 'Lote', 'Ancho', 'Capas', 'Tendido (m)', 'Consumo (m)', 'Consumo (kg)', 'Al terminar'],
          numericas: const {3, 4, 5, 6, 7},
          filas: [
            for (final x in rollos)
              DataRow(cells: [
                DataCell(Text('${x['rollos']?['codigo'] ?? ''}', style: estiloCodigo(13))),
                DataCell(Text(k.color(x['color_id']))),
                DataCell(Text('${x['lote_tintura']} ${x['tono'] ?? ''}')),
                DataCell(Text('${Formato.numero(x['ancho_cm'], decimales: 1)} cm')),
                DataCell(Text('${x['capas']}')),
                DataCell(Text(Formato.numero(x['metros_tendido']))),
                DataCell(Text(Formato.numero(x['metros_consumo']))),
                DataCell(Text(Formato.numero(x['kilos_consumo'], decimales: 3))),
                DataCell(Text('${fines[x['fin']]}${x['retazo'] != null ? ' ${x['retazo']['codigo']}' : ''}${x['vigente'] == false ? ' (anulado)' : ''}')),
              ]),
          ],
        ),
      ),
      if (aut.isNotEmpty) ...[
        const SizedBox(height: 16),
        Tarjeta(
          titulo: 'Autorizaciones de lote',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final a in aut)
              Text('• ${a['detalle']?['mensaje'] ?? ''} — ${a['perfiles']?['nombre'] ?? ''}, ${Formato.fechaHora(DateTime.parse(a['ocurrido_en']))}: ${a['motivo']}',
                  style: estilo(13.5)),
          ]),
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Campos
// ---------------------------------------------------------------------------
class _Desplegable extends StatelessWidget {
  const _Desplegable({required this.etiqueta, required this.valor, required this.opciones, required this.onCambio, this.ancho = 200});
  final String etiqueta;
  final String? valor;
  final Map<String, String> opciones;
  final ValueChanged<String?> onCambio;
  final double ancho;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: ancho,
        child: InputDecorator(
          decoration: InputDecoration(labelText: etiqueta, isDense: true, contentPadding: const EdgeInsets.fromLTRB(10, 8, 4, 8)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: opciones.containsKey(valor) ? valor : (opciones.containsKey('') ? '' : null),
              isExpanded: true,
              isDense: true,
              items: [for (final e in opciones.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
              onChanged: onCambio,
            ),
          ),
        ),
      );
}

/// Campo numérico en formato colombiano (1.234,56) que avisa al cambiar.
class CampoNum extends StatefulWidget {
  const CampoNum({super.key, this.etiqueta, required this.valor, required this.onCambio, this.decimales = 2});
  final String? etiqueta;
  final double? valor;
  final ValueChanged<double?> onCambio;
  final int decimales;
  @override
  State<CampoNum> createState() => _CampoNumState();
}

class _CampoNumState extends State<CampoNum> {
  late final TextEditingController _c = TextEditingController(text: _texto(widget.valor));
  final _foco = FocusNode();

  String _texto(double? v) => v == null || (v == 0 && widget.decimales > 0)
      ? ''
      : Formato.numero(v, decimales: widget.decimales).replaceAll(RegExp(r',0+$'), '').replaceAllMapped(RegExp(r'(,\d*?)0+$'), (m) => m.group(1)!);

  @override
  void didUpdateWidget(covariant CampoNum old) {
    super.didUpdateWidget(old);
    if (!_foco.hasFocus && numeroCo(_c.text) != widget.valor && !(numeroCo(_c.text) == null && (widget.valor ?? 0) == 0)) {
      _c.text = _texto(widget.valor);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _foco.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        focusNode: _foco,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: widget.etiqueta, isDense: true, hintText: '0'),
        onChanged: (t) => widget.onCambio(numeroCo(t)),
      );
}

class CampoTexto extends StatefulWidget {
  const CampoTexto({super.key, required this.etiqueta, required this.valor, required this.onCambio});
  final String etiqueta;
  final String valor;
  final ValueChanged<String> onCambio;
  @override
  State<CampoTexto> createState() => _CampoTextoState();
}

class _CampoTextoState extends State<CampoTexto> {
  late final TextEditingController _c = TextEditingController(text: widget.valor);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(controller: _c, decoration: InputDecoration(labelText: widget.etiqueta, isDense: true), onChanged: widget.onCambio);
}
