import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError, numeroCo, pedirTexto;

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Descarga un CSV que Excel en español abre bien (separador ; y decimales con coma).
Future<void> descargarCsv(String nombre, List<String> encabezados, List<List<Object?>> filas) async {
  String celda(Object? v) {
    final t = v is num ? Formato.numero(v, decimales: v % 1 == 0 ? 0 : 2).replaceAll('.', '') : '${v ?? ''}';
    return t.contains(';') || t.contains('"') ? '"${t.replaceAll('"', '""')}"' : t;
  }

  final texto = [encabezados.map(celda).join(';'), for (final f in filas) f.map(celda).join(';')].join('\r\n');
  await FilePicker.saveFile(fileName: nombre, bytes: Uint8List.fromList(utf8.encode('﻿$texto')), mimeType: 'text/csv');
}

Color _semaforo(num? v) => v == null ? Colores.textoSuave : Colores.semaforo(v.toDouble());

/// Eficiencia por operario, célula y planta; minutos improductivos; incentivos; causas de paro.
class PantallaEficiencia extends ConsumerStatefulWidget {
  const PantallaEficiencia({super.key});
  @override
  ConsumerState<PantallaEficiencia> createState() => _PantallaEficienciaState();
}

class _PantallaEficienciaState extends ConsumerState<PantallaEficiencia> {
  var _pestana = 'eficiencia';
  late DateTime _desde = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day <= 15 ? 1 : 16);
  DateTime _hasta = DateTime.now();
  var _agrupar = 'operario';
  var _periodo = 'dia';
  Future<List<Map<String, dynamic>>>? _datos;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  void _cargar() {
    setState(() {
      _datos = switch (_pestana) {
        'paros' => db.rpc('informe_paros', params: {'p_desde': _iso(_desde), 'p_hasta': _iso(_hasta)}).then((v) => (v as List).cast<Map<String, dynamic>>()),
        'incentivos' => db.rpc('liquidar_incentivos', params: {'p_desde': _iso(_desde), 'p_hasta': _iso(_hasta)}).then((v) => (v as List).cast<Map<String, dynamic>>()),
        'causas' => db.from('causas_paro').select().order('nombre', ascending: true),
        _ => db.rpc('informe_eficiencia', params: {'p_desde': _iso(_desde), 'p_hasta': _iso(_hasta), 'p_agrupar': _agrupar, 'p_periodo': _periodo})
            .then((v) => (v as List).cast<Map<String, dynamic>>()),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final sesion = ref.watch(sesionProvider).value;
    final editar = sesion?.puedeEditar('eficiencia') ?? false;
    final aprobar = sesion?.permisos.any((p) => p.modulo == 'eficiencia' && p.aprobar) ?? false;
    Widget fecha(String t, DateTime v, ValueChanged<DateTime> f) => OutlinedButton.icon(
          onPressed: () async {
            final x = await showDatePicker(context: context, initialDate: v, firstDate: DateTime(2025), lastDate: DateTime.now().add(const Duration(days: 1)));
            if (x != null) {
              f(x);
              _cargar();
            }
          },
          icon: const Icon(Icons.event, size: 18),
          label: Text('$t ${Formato.fecha(v)}'),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Eficiencia e incentivos', subtitulo: 'Eficiencia = minutos estándar producidos / minutos trabajados (descontando paros)'),
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Wrap(spacing: 8, children: [
          for (final (k, t) in const [('eficiencia', 'Eficiencia'), ('paros', 'Tiempos improductivos'), ('incentivos', 'Incentivos'), ('causas', 'Causas de paro')])
            ChoiceChip(
              label: Text(t),
              selected: _pestana == k,
              showCheckmark: false,
              labelStyle: estilo(13.5, peso: FontWeight.w600, color: _pestana == k ? Colors.white : Colores.texto),
              selectedColor: Colores.texto,
              backgroundColor: Colors.white,
              side: const BorderSide(color: Colores.borde),
              onSelected: (_) {
                _pestana = k;
                _cargar();
              },
            ),
        ]),
      ),
      if (_pestana != 'causas')
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            fecha('Desde', _desde, (x) => _desde = x),
            fecha('Hasta', _hasta, (x) => _hasta = x),
            if (_pestana == 'eficiencia') ...[
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'operario', label: Text('Operario')), ButtonSegment(value: 'celula', label: Text('Célula')),
                  ButtonSegment(value: 'planta', label: Text('Planta'))],
                selected: {_agrupar},
                onSelectionChanged: (s) {
                  _agrupar = s.first;
                  _cargar();
                },
              ),
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'hora', label: Text('Hora')), ButtonSegment(value: 'dia', label: Text('Día')),
                  ButtonSegment(value: 'semana', label: Text('Semana')), ButtonSegment(value: 'quincena', label: Text('Quincena')),
                  ButtonSegment(value: 'mes', label: Text('Mes'))],
                selected: {_periodo},
                onSelectionChanged: (s) {
                  _periodo = s.first;
                  _cargar();
                },
              ),
            ],
          ]),
        ),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos), // estado nuevo por consulta: no mezcla filas de otra pestaña
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final l = s.data!;
          return switch (_pestana) {
            'paros' => _paros(l),
            'incentivos' => _incentivos(l, aprobar),
            'causas' => _causas(l, editar),
            _ => _eficiencia(l),
          };
        },
      ),
    ]);
  }

  Widget _eficiencia(List<Map<String, dynamic>> l) {
    // ranking del rango completo por operario
    final porClave = <String, ({String nombre, double e, double r})>{};
    for (final x in l) {
      final k = '${x['codigo']}';
      final a = porClave[k] ?? (nombre: '${x['codigo']} · ${x['nombre']}', e: 0.0, r: 0.0);
      porClave[k] = (nombre: a.nombre, e: a.e + ((x['minutos_esperados'] as num?) ?? 0).toDouble(), r: a.r + ((x['minutos_reales'] as num?) ?? 0).toDouble());
    }
    final ranking = [for (final e in porClave.entries) if (e.value.r > 0) (nombre: e.value.nombre, ef: e.value.e / e.value.r * 100)]
      ..sort((a, b) => b.ef.compareTo(a.ef));
    Widget lista(String t, Iterable<({String nombre, double ef})> xs) => Expanded(
          child: Tarjeta(
            titulo: t,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (xs.isEmpty) Text('Sin datos', style: estilo(13, color: Colores.textoSuave)),
              for (final x in xs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(child: Text(x.nombre, overflow: TextOverflow.ellipsis)),
                    Text('${Formato.numero(x.ef, decimales: 1)} %', style: estilo(14, peso: FontWeight.w700, color: _semaforo(x.ef))),
                  ]),
                ),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_agrupar != 'planta') ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          lista('Mayor eficiencia', ranking.take(5)),
          const SizedBox(width: 16),
          lista('Menor eficiencia', ranking.reversed.take(5)),
        ]),
        const SizedBox(height: 16),
      ],
      Tarjeta(
        titulo: 'Detalle',
        accion: OutlinedButton.icon(
          onPressed: l.isEmpty
              ? null
              : () => descargarCsv('eficiencia_${_iso(_desde)}_${_iso(_hasta)}.csv',
                  ['Código', 'Nombre', 'Periodo', 'Unidades', 'Reprocesos', 'Min. estándar', 'Min. trabajados', 'Eficiencia %', 'Min. paro'], [
                    for (final x in l)
                      [x['codigo'], x['nombre'], x['periodo'], x['unidades'], x['reprocesos'], x['minutos_esperados'], x['minutos_reales'], x['eficiencia'], x['minutos_paro']],
                  ]),
          icon: const Icon(Icons.download),
          label: const Text('Excel (CSV)')),
        child: Tabla(
          columnas: const ['Código', 'Nombre', 'Periodo', 'Unidades', 'Reprocesos', 'Min. estándar', 'Min. trabajados', 'Eficiencia', 'Min. paro'],
          numericas: const {3, 4, 5, 6, 7, 8},
          vacio: 'Sin marcaciones en el rango.',
          filas: [
            for (final x in l)
              DataRow(cells: [
                DataCell(Text('${x['codigo']}', style: estiloCodigo(13))),
                DataCell(Text('${x['nombre']}')),
                DataCell(Text('${x['periodo']}')),
                DataCell(Text(Formato.numero(x['unidades'], decimales: 0))),
                DataCell(Text(Formato.numero(x['reprocesos'], decimales: 0))),
                DataCell(Text(Formato.numero(x['minutos_esperados'] ?? 0, decimales: 1))),
                DataCell(Text(Formato.numero(x['minutos_reales'] ?? 0, decimales: 1))),
                DataCell(Text(x['eficiencia'] == null ? '—' : '${Formato.numero(x['eficiencia'], decimales: 1)} %',
                    style: estilo(14, peso: FontWeight.w700, color: _semaforo(x['eficiencia'] as num?)))),
                DataCell(Text(Formato.numero(x['minutos_paro'] ?? 0, decimales: 0))),
              ]),
          ],
        ),
      ),
    ]);
  }

  Widget _paros(List<Map<String, dynamic>> l) {
    final porCausa = <String, double>{};
    for (final x in l) {
      porCausa['${x['causa']}'] = (porCausa['${x['causa']}'] ?? 0) + ((x['minutos'] as num?) ?? 0).toDouble();
    }
    final total = porCausa.values.fold(0.0, (a, b) => a + b);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Minutos improductivos por causa · total ${Formato.numero(total, decimales: 0)} min',
        child: Column(children: [
          for (final e in (porCausa.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 240, child: Text(e.key)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: total == 0 ? 0 : e.value / total, minHeight: 12, backgroundColor: Colores.borde, color: Colores.ambar),
                  ),
                ),
                SizedBox(width: 90, child: Text('${Formato.numero(e.value, decimales: 0)} min', textAlign: TextAlign.right)),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Paros',
        accion: OutlinedButton.icon(
          onPressed: l.isEmpty
              ? null
              : () => descargarCsv('paros_${_iso(_desde)}_${_iso(_hasta)}.csv', ['Inicio', 'Fin', 'Minutos', 'Causa', 'Célula', 'Operario', 'Validado', 'Descuenta nómina', 'Observación'], [
                    for (final x in l)
                      [Formato.fechaHora(DateTime.parse(x['inicio'])), x['fin'] == null ? 'En curso' : Formato.fechaHora(DateTime.parse(x['fin'])), x['minutos'], x['causa'],
                        x['celula'], x['operario'], x['validado'] == true ? 'Sí' : 'No', x['descuenta_nomina'] == true ? 'Sí' : 'No', x['observacion']],
                  ]),
          icon: const Icon(Icons.download),
          label: const Text('Excel (CSV)')),
        child: Tabla(
          columnas: const ['Inicio', 'Fin', 'Minutos', 'Causa', 'Célula', 'Operario', 'Validado', 'Observación'],
          numericas: const {2},
          vacio: 'Sin paros en el rango.',
          filas: [
            for (final x in l)
              DataRow(cells: [
                DataCell(Text(Formato.fechaHora(DateTime.parse(x['inicio'])))),
                DataCell(x['fin'] == null ? const Pastilla('En curso', color: Colores.rojo) : Text(Formato.hora(DateTime.parse(x['fin'])))),
                DataCell(Text(Formato.numero(x['minutos'] ?? 0, decimales: 0))),
                DataCell(Text('${x['causa']}')),
                DataCell(Text('${x['celula'] ?? ''}')),
                DataCell(Text('${x['operario']}')),
                DataCell(Icon(x['validado'] == true ? Icons.check : Icons.remove, size: 18, color: x['validado'] == true ? Colores.verde : Colores.textoSuave)),
                DataCell(Text('${x['observacion'] ?? ''}')),
              ]),
          ],
        ),
      ),
    ]);
  }

  Widget _incentivos(List<Map<String, dynamic>> l, bool aprobar) {
    final total = l.fold<num>(0, (a, x) => a + ((x['valor'] ?? 0) as num));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _GruposIncentivo(aprobar: aprobar, onCambio: _cargar),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Liquidación del rango · ${Formato.cop(total)}',
        accion: OutlinedButton.icon(
          onPressed: l.isEmpty
              ? null
              : () => descargarCsv('incentivos_${_iso(_desde)}_${_iso(_hasta)}.csv',
                  ['Código', 'Operario', 'Célula', 'Grupo', 'Periodo', 'Min. estándar', 'Min. trabajados', 'Eficiencia %', 'Valor'], [
                    for (final x in l)
                      [x['codigo'], x['nombre'], x['celula'], x['grupo'], x['periodo'], x['minutos_esperados'], x['minutos_reales'], x['eficiencia'], x['valor']],
                  ]),
          icon: const Icon(Icons.download),
          label: const Text('Excel para nómina (CSV)')),
        child: Tabla(
          columnas: const ['Código', 'Operario', 'Célula', 'Grupo', 'Periodo', 'Eficiencia', 'Valor'],
          numericas: const {5, 6},
          vacio: 'Ninguna célula tiene grupo de incentivos, o no hay marcaciones en el rango.',
          filas: [
            for (final x in l)
              DataRow(cells: [
                DataCell(Text('${x['codigo']}', style: estiloCodigo(13))),
                DataCell(Text('${x['nombre']}')),
                DataCell(Text('${x['celula']}')),
                DataCell(Text('${x['grupo']}')),
                DataCell(Text('${x['periodo']}')),
                DataCell(Text(x['eficiencia'] == null ? '—' : '${Formato.numero(x['eficiencia'], decimales: 1)} %',
                    style: estilo(14, peso: FontWeight.w700, color: _semaforo(x['eficiencia'] as num?)))),
                DataCell(Text(Formato.cop(x['valor'] ?? 0), style: estilo(14, peso: FontWeight.w600))),
              ]),
          ],
        ),
      ),
    ]);
  }

  Widget _causas(List<Map<String, dynamic>> l, bool editar) {
    Widget check(Map<String, dynamic> c, String campo) => Checkbox(
          value: c[campo] == true,
          onChanged: !editar
              ? null
              : (v) async {
                  try {
                    await db.from('causas_paro').update({campo: v}).eq('id', c['id']);
                    _cargar();
                  } catch (e) {
                    if (mounted) avisar(context, mensajeError(e), error: true);
                  }
                },
        );
    return Tarjeta(
      titulo: 'Causas de paro',
      accion: editar
          ? FilledButton.icon(
              onPressed: () async {
                final n = await pedirTexto(context, titulo: 'Nueva causa', etiqueta: 'Nombre (ej. Cambio de referencia)');
                if (n == null) return;
                try {
                  await db.from('causas_paro').insert({'codigo': n.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '').padRight(3, 'X').substring(0, 3) +
                      DateTime.now().millisecondsSinceEpoch.toString().substring(10), 'nombre': n});
                  _cargar();
                } catch (e) {
                  if (mounted) avisar(context, mensajeError(e), error: true);
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Nueva causa'))
          : null,
      child: Tabla(
        columnas: const ['Causa', 'Tablet', 'Desc. operario', 'Desc. célula', 'Desc. nómina', 'Detiene', 'Toda célula', 'Lo cierra', 'Min. fijos', 'Activa'],
        filas: [
          for (final c in l)
            DataRow(cells: [
              DataCell(Text('${c['nombre']}')),
              DataCell(check(c, 'visible_tablet')),
              DataCell(check(c, 'descuenta_operario')),
              DataCell(check(c, 'descuenta_celula')),
              DataCell(check(c, 'descuenta_nomina')),
              DataCell(check(c, 'detiene_trabajo')),
              DataCell(check(c, 'detiene_celula')),
              DataCell(Text('${c['rol_validador'] ?? '—'}')),
              DataCell(Text('${c['minutos_definidos'] ?? '—'}')),
              DataCell(check(c, 'activa')),
            ]),
        ],
      ),
    );
  }
}

class _GruposIncentivo extends ConsumerStatefulWidget {
  const _GruposIncentivo({required this.aprobar, required this.onCambio});
  final bool aprobar;
  final VoidCallback onCambio;
  @override
  ConsumerState<_GruposIncentivo> createState() => _GruposIncentivoState();
}

class _GruposIncentivoState extends ConsumerState<_GruposIncentivo> {
  late Future<List<dynamic>> _f = _cargar();
  Future<List<dynamic>> _cargar() => Future.wait<dynamic>([
        db.from('grupos_incentivo').select('*, incentivo_tramos(*)').order('nombre', ascending: true),
        db.from('celulas').select('id, codigo, nombre, grupo_incentivo_id').eq('activo', true).order('codigo', ascending: true),
      ]);

  Future<void> _hacer(Future<void> Function() f) async {
    try {
      await f();
      setState(() => _f = _cargar());
      widget.onCambio();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
        future: _f,
        builder: (_, s) {
          if (!s.hasData) return const LinearProgressIndicator();
          final grupos = (s.data![0] as List).cast<Map<String, dynamic>>();
          final celulas = (s.data![1] as List).cast<Map<String, dynamic>>();
          return Tarjeta(
            titulo: 'Grupos de incentivos (opcionales)',
            accion: widget.aprobar
                ? FilledButton.icon(
                    onPressed: () async {
                      final n = await pedirTexto(context, titulo: 'Nuevo grupo', etiqueta: 'Nombre');
                      if (n != null) await _hacer(() => db.from('grupos_incentivo').insert({'nombre': n}));
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Nuevo grupo'))
                : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Un grupo paga un valor por periodo según el tramo de eficiencia (individual: la del operario; modular: la de su célula). '
                  'Solo aplica a las células que tengan grupo asignado.', style: estilo(13, color: Colores.textoSuave)),
              const SizedBox(height: 10),
              if (grupos.isEmpty) Text('No hay grupos: no se liquidan incentivos.', style: estilo(14, color: Colores.textoSuave)),
              for (final g in grupos) ...[
                Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${g['nombre']}', style: estilo(15, peso: FontWeight.w700)),
                  DropdownButton<String>(
                    value: g['tipo'] as String,
                    items: const [DropdownMenuItem(value: 'individual', child: Text('Individual')), DropdownMenuItem(value: 'modular', child: Text('Modular'))],
                    onChanged: !widget.aprobar ? null : (v) => _hacer(() => db.from('grupos_incentivo').update({'tipo': v}).eq('id', g['id'])),
                  ),
                  DropdownButton<String>(
                    value: g['periodo'] as String,
                    items: const [DropdownMenuItem(value: 'dia', child: Text('Diario')), DropdownMenuItem(value: 'semana', child: Text('Semanal')),
                      DropdownMenuItem(value: 'quincena', child: Text('Quincenal')), DropdownMenuItem(value: 'mes', child: Text('Mensual'))],
                    onChanged: !widget.aprobar ? null : (v) => _hacer(() => db.from('grupos_incentivo').update({'periodo': v}).eq('id', g['id'])),
                  ),
                  for (final t in ((g['incentivo_tramos'] as List).cast<Map<String, dynamic>>()..sort((a, b) => (a['desde_pct'] as num).compareTo(b['desde_pct'] as num))))
                    InputChip(
                      label: Text('${Formato.numero(t['desde_pct'], decimales: 0)}–${t['hasta_pct'] == null ? '…' : Formato.numero(t['hasta_pct'], decimales: 0)} %: ${Formato.cop(t['valor'])}'),
                      onDeleted: !widget.aprobar ? null : () => _hacer(() => db.from('incentivo_tramos').delete().eq('id', t['id'])),
                    ),
                  if (widget.aprobar)
                    TextButton(
                      onPressed: () async {
                        final x = await pedirTexto(context, titulo: 'Nuevo tramo', etiqueta: 'desde %; hasta % (vacío = sin tope); valor', ayuda: '90; 100; 50000');
                        if (x == null) return;
                        final p = x.split(';').map((s) => s.trim()).toList();
                        if (p.length != 3) return;
                        await _hacer(() => db.from('incentivo_tramos').insert({
                              'grupo_id': g['id'], 'desde_pct': numeroCo(p[0]), 'hasta_pct': p[1].isEmpty ? null : numeroCo(p[1]), 'valor': numeroCo(p[2]),
                            }));
                      },
                      child: const Text('+ Tramo')),
                ]),
                const SizedBox(height: 4),
              ],
              const Divider(),
              Wrap(spacing: 16, runSpacing: 8, children: [
                for (final c in celulas)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${c['codigo']}: ', style: estilo(13.5, peso: FontWeight.w600)),
                    DropdownButton<String?>(
                      value: c['grupo_incentivo_id'] as String?,
                      items: [const DropdownMenuItem(value: null, child: Text('Sin incentivo')), for (final g in grupos) DropdownMenuItem(value: g['id'] as String, child: Text('${g['nombre']}'))],
                      onChanged: !widget.aprobar ? null : (v) => _hacer(() => db.from('celulas').update({'grupo_incentivo_id': v}).eq('id', c['id'])),
                    ),
                  ]),
              ]),
            ]),
          );
        },
      );
}
