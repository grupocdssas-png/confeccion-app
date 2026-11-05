import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../eficiencia/pantalla_eficiencia.dart' show descargarCsv;
import '../inventario/comun_inventario.dart';

String _iso(DateTime d) => d.toIso8601String().substring(0, 10);
String _corta(String iso) => Formato.fechaHora(DateTime.parse(iso)).replaceFirst(RegExp(r'/\d{4}'), '');
String _prendas(int n) => '$n ${n == 1 ? 'prenda' : 'prendas'}';
Color _semaforo(num? v) => v == null ? Colores.textoSuave : v >= 97 ? Colores.verde : v >= 90 ? Colores.ambar : Colores.rojo;
const _severidades = {'menor': 'Menor', 'mayor': 'Mayor', 'critico': 'Crítico'};

/// Calidad en la oficina: inspecciones y auditorías, devoluciones abiertas, eficacia
/// (% de primera calidad), Pareto de defectos, catálogo de defectos y plan de muestreo.
class PantallaCalidadWeb extends ConsumerStatefulWidget {
  const PantallaCalidadWeb({super.key});
  @override
  ConsumerState<PantallaCalidadWeb> createState() => _PantallaCalidadWebState();
}

class _PantallaCalidadWebState extends ConsumerState<PantallaCalidadWeb> {
  var _pestana = 'inspecciones';
  DateTime _desde = DateTime.now().subtract(const Duration(days: 7));
  DateTime _hasta = DateTime.now();
  var _agrupar = 'operario';
  Future<List<dynamic>>? _datos;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  void _cargar() {
    final d = _iso(_desde), h = _iso(_hasta);
    setState(() {
      _datos = switch (_pestana) {
        'devoluciones' => Future.wait([db.from('devoluciones_vista').select().eq('estado', 'abierta').order('creada_en', ascending: false)]),
        'eficacia' => Future.wait([
            db.rpc('informe_eficacia', params: {'p_desde': d, 'p_hasta': h, 'p_agrupar': _agrupar}),
            db.rpc('informe_defectos', params: {'p_desde': d, 'p_hasta': h}),
          ]),
        'defectos' => Future.wait([db.from('defectos').select().order('nombre', ascending: true), db.from('procesos').select('codigo, nombre').order('orden', ascending: true)]),
        'muestreo' => Future.wait([db.from('planes_muestreo').select().order('por_defecto', ascending: false)]),
        _ => Future.wait([
            db
                .from('inspecciones')
                .select('id, consecutivo, tipo, anula_id, resultado, alcance, tamano_lote, tamano_muestra, acepta, defectuosas, ocurrido_en_servidor, proceso, '
                    'observacion, paquetes(codigo), juegos(codigo), ordenes_produccion(consecutivo), celulas(codigo), empleados(nombres, apellidos), '
                    'inspeccion_defectos(cantidad, defectos(nombre), empleados(nombres, apellidos), ficha_operaciones(operaciones(nombre))), '
                    'inspeccion_medidas(valor_cm, esperado_cm, tolerancia_cm, fuera_tolerancia, ficha_medidas(punto_medida))')
                .gte('ocurrido_en_servidor', '${d}T05:00:00Z')
                .lte('ocurrido_en_servidor', '${_iso(_hasta.add(const Duration(days: 1)))}T05:00:00Z')
                .order('ocurrido_en_servidor', ascending: false)
                .limit(300),
          ]),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final sesion = ref.watch(sesionProvider).value;
    final editar = sesion?.puedeEditar('calidad') ?? false;
    final aprobar = sesion?.permisos.any((p) => p.modulo == 'calidad' && p.aprobar) ?? false;
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
      const EncabezadoPagina('Calidad', subtitulo: 'Auditoría por muestreo, inspección en proceso, devoluciones y eficacia (% de primera calidad)'),
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, t) in const [('inspecciones', 'Inspecciones'), ('devoluciones', 'Devoluciones abiertas'), ('eficacia', 'Eficacia y defectos'),
            ('defectos', 'Catálogo de defectos'), ('muestreo', 'Plan de muestreo')])
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
      if (_pestana == 'inspecciones' || _pestana == 'eficacia')
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            fecha('Desde', _desde, (v) => _desde = v),
            fecha('Hasta', _hasta, (v) => _hasta = v),
            if (_pestana == 'eficacia')
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'operario', label: Text('Operario')), ButtonSegment(value: 'celula', label: Text('Módulo')),
                  ButtonSegment(value: 'satelite', label: Text('Satélite'))],
                selected: {_agrupar},
                onSelectionChanged: (s) {
                  _agrupar = s.first;
                  _cargar();
                },
              ),
          ]),
        ),
      FutureBuilder<List<dynamic>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          List<Map<String, dynamic>> l(int i) => (s.data![i] as List).cast<Map<String, dynamic>>();
          return switch (_pestana) {
            'devoluciones' => _devoluciones(l(0), editar),
            'eficacia' => _eficacia(l(0), l(1)),
            'defectos' => _defectos(l(0), l(1), editar),
            'muestreo' => _muestreo(l(0), aprobar),
            _ => _inspecciones(l(0), editar),
          };
        },
      ),
    ]);
  }

  // ---------- Inspecciones ----------
  Widget _inspecciones(List<Map<String, dynamic>> xs, bool editar) {
    final anuladas = {for (final x in xs) if (x['anula_id'] != null) x['anula_id']};
    final vigentes = xs.where((x) => x['tipo'] != 'anulacion').toList();
    final aud = vigentes.where((x) => x['tipo'] == 'auditoria_final' && !anuladas.contains(x['id'])).toList();
    final rech = aud.where((x) => x['resultado'] == 'rechazado').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _dato('Auditorías', '${aud.length}'),
        _dato('Rechazadas', '$rech', color: rech > 0 ? Colores.rojo : null),
        _dato('Aceptación', aud.isEmpty ? '—' : '${Formato.numero((aud.length - rech) * 100 / aud.length, decimales: 1)} %'),
        _dato('Inspecciones en proceso', '${vigentes.where((x) => x['tipo'] == 'en_proceso').length}'),
      ]),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Inspecciones',
        child: Tabla(
          columnas: const ['Número', 'Fecha', 'Tipo', 'Unidad', 'OP', 'Módulo', 'Revisadas', 'Malas / acepta', 'Resultado', ''],
          numericas: const {6, 7},
          vacio: 'No hay inspecciones en el rango.',
          filas: [
            for (final x in vigentes)
              () {
                void ver() => _detalle(x, editar && !anuladas.contains(x['id']));
                DataCell c(Widget w) => DataCell(w, onTap: ver);
                return DataRow(cells: [
                  c(Text('${x['consecutivo']}', style: estiloCodigo(12.5))),
                  c(Text(_corta(x['ocurrido_en_servidor']))),
                  c(Text(x['tipo'] == 'auditoria_final' ? 'Auditoría' : 'En proceso')),
                  c(Text('${x['paquetes']?['codigo'] ?? x['juegos']?['codigo'] ?? ''}', style: estiloCodigo(12.5))),
                  c(Text('${x['ordenes_produccion']?['consecutivo'] ?? ''}')),
                  c(Text('${x['celulas']?['codigo'] ?? ''}')),
                  c(Text('${x['tamano_muestra']} de ${x['tamano_lote']}')),
                  c(Text('${x['defectuosas']}${x['acepta'] != null ? ' / ${x['acepta']}' : ''}')),
                  c(anuladas.contains(x['id'])
                      ? const Pastilla('Anulada', color: Colores.textoSuave)
                      : x['resultado'] == 'aprobado'
                          ? const Pastilla('Aprobado', color: Colores.verde)
                          : Pastilla(x['alcance'] == 'grupal' ? 'Rechazado · todo' : 'Rechazado', color: Colores.rojo)),
                  DataCell(IconButton(tooltip: 'Ver detalle', icon: const Icon(Icons.chevron_right), onPressed: ver)),
                ]);
              }(),
          ],
        ),
      ),
    ]);
  }

  Widget _dato(String t, String v, {Color? color}) => Container(
        width: 210,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colores.borde)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: estilo(12.5, color: Colores.textoSuave)),
          const SizedBox(height: 4),
          Text(v, style: estilo(24, peso: FontWeight.w700, color: color)),
        ]),
      );

  Future<void> _detalle(Map<String, dynamic> x, bool puedeAnular) async {
    final defs = (x['inspeccion_defectos'] as List).cast<Map<String, dynamic>>();
    final meds = (x['inspeccion_medidas'] as List).cast<Map<String, dynamic>>();
    final anular = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${x['consecutivo']} · ${x['paquetes']?['codigo'] ?? x['juegos']?['codigo'] ?? ''}'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${x['tipo'] == 'auditoria_final' ? 'Auditoría final' : 'Inspección en proceso'} · ${x['tamano_muestra']} revisadas de ${x['tamano_lote']}'
                ' · ${x['defectuosas']} con defecto', style: estilo(14)),
            const SizedBox(height: 10),
            if (defs.isEmpty) Text('Sin defectos.', style: estilo(14, color: Colores.textoSuave)),
            for (final f in defs)
              Text('• ${f['cantidad']} ${f['defectos']['nombre']}'
                  '${f['ficha_operaciones'] != null ? ' · ${f['ficha_operaciones']['operaciones']?['nombre'] ?? ''}' : ''}'
                  '${f['empleados'] != null ? ' · ${f['empleados']['nombres']} ${f['empleados']['apellidos']}' : ''}', style: estilo(14)),
            if (meds.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Medidas', style: estilo(14, peso: FontWeight.w600)),
              for (final m in meds)
                Text('${m['ficha_medidas']['punto_medida']}: ${Formato.numero(m['valor_cm'], decimales: 1)} cm (ficha ${Formato.numero(m['esperado_cm'] ?? 0, decimales: 1)} ± '
                    '${Formato.numero(m['tolerancia_cm'] ?? 0, decimales: 1)})${m['fuera_tolerancia'] == true ? '  ✗ fuera' : '  ✓'}',
                    style: estilo(14, color: m['fuera_tolerancia'] == true ? Colores.rojo : null)),
            ],
            if (x['observacion'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${x['observacion']}', style: estilo(14))),
          ]),
        ),
        actions: [
          if (puedeAnular) TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Anular', style: TextStyle(color: Colores.rojo))),
          FilledButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cerrar')),
        ],
      ),
    );
    if (anular != true || !mounted) return;
    final m = await pedirTexto(context, titulo: 'Anular ${x['consecutivo']}', etiqueta: 'Motivo', ayuda: 'Sus devoluciones abiertas también se anulan.');
    if (m == null) return;
    try {
      await db.rpc('registrar_inspeccion', params: {'p_datos': {'tipo': 'anulacion', 'anula_id': x['id'], 'motivo': m}});
      _cargar();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  // ---------- Devoluciones ----------
  Widget _devoluciones(List<Map<String, dynamic>> xs, bool editar) => Tarjeta(
        titulo: 'Devoluciones abiertas · ${_prendas(xs.fold<int>(0, (a, x) => a + (x['cantidad'] as int)))}',
        child: Tabla(
          columnas: const ['Desde', 'Unidad', 'Defecto', 'Operación', 'Operario', 'Módulo', 'Prendas', 'Arregladas', ''],
          numericas: const {6, 7},
          vacio: 'No hay prendas devueltas pendientes.',
          filas: [
            for (final x in xs)
              DataRow(cells: [
                DataCell(Text(_corta(x['creada_en']))),
                DataCell(Text('${x['unidad_codigo']}${x['alcance'] == 'grupal' ? ' · todo' : ''}', style: estiloCodigo(12.5))),
                DataCell(Text('${x['defecto']}', style: estilo(14, color: x['severidad'] == 'critico' ? Colores.rojo : null))),
                DataCell(Text('${x['operacion'] ?? '—'}')),
                DataCell(Text('${x['empleado'] ?? '—'}')),
                DataCell(Text('${x['celula'] ?? x['satelite'] ?? '—'}')),
                DataCell(Text('${x['cantidad']}')),
                DataCell(Text('${x['reprocesadas']}')),
                DataCell(editar ? TextButton(onPressed: () => _cerrar(x), child: const Text('Recibir arreglo')) : const SizedBox()),
              ]),
          ],
        ),
      );

  Future<void> _cerrar(Map<String, dynamic> x) async {
    final c = TextEditingController(text: '${x['cantidad']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Arreglo de ${x['defecto']}'),
        content: SizedBox(
          width: 360,
          child: TextField(controller: c, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Quedaron bien (de ${x['cantidad']}); el resto es segunda')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Recibir')),
        ],
      ),
    );
    if (ok != true) return;
    final bien = (int.tryParse(c.text.trim()) ?? 0).clamp(0, x['cantidad'] as int);
    try {
      await db.rpc('cerrar_devolucion', params: {'p_devolucion': x['id'], 'p_reprocesadas': bien, 'p_segundas': (x['cantidad'] as int) - bien});
      _cargar();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  // ---------- Eficacia ----------
  Widget _eficacia(List<Map<String, dynamic>> xs, List<Map<String, dynamic>> pareto) {
    final total = pareto.fold<int>(0, (a, x) => a + (x['cantidad'] as int));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Eficacia (% de primera calidad)',
        accion: OutlinedButton.icon(
          onPressed: xs.isEmpty
              ? null
              : () => descargarCsv('eficacia_${_agrupar}_${_iso(_desde)}_${_iso(_hasta)}.csv',
                  ['Código', 'Nombre', 'Revisadas', 'Con defecto', '% primera calidad', 'Devoluciones', 'Entraron', 'Segundas', '% segundas', 'Defecto principal'],
                  [for (final x in xs) [x['codigo'], x['nombre'], x['inspeccionadas'], x['defectuosas'], x['primera_calidad'], x['devoluciones'], x['entra'],
                    x['segundas'], x['segundas_pct'], x['defecto_principal']]]),
          icon: const Icon(Icons.download),
          label: const Text('Excel (CSV)'),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
                'Primera calidad = 1 − prendas con defecto atribuidas / prendas revisadas de lo que hizo. '
                '${_agrupar == 'operario' ? 'El responsable sale de quien marcó la operación.' : 'Segundas = las registradas al entregar en el proceso.'}',
                style: estilo(12.5, color: Colores.textoSuave)),
          ),
          Tabla(
            columnas: [
              'Código', 'Nombre', 'Revisadas', 'Con defecto', '% primera', 'Devoluciones',
              if (_agrupar != 'operario') ...['Entraron', 'Segundas', '% segundas'],
              'Defecto principal',
            ],
            numericas: {2, 3, 4, 5, if (_agrupar != 'operario') ...{6, 7, 8}},
            vacio: 'Sin inspecciones en el rango.',
            filas: [
              for (final x in xs)
                DataRow(cells: [
                  DataCell(Text('${x['codigo'] ?? ''}', style: estiloCodigo(12.5))),
                  DataCell(Text('${x['nombre'] ?? ''}')),
                  DataCell(Text('${x['inspeccionadas']}')),
                  DataCell(Text('${x['defectuosas']}')),
                  DataCell(Text(x['primera_calidad'] == null ? '—' : '${Formato.numero(x['primera_calidad'], decimales: 1)} %',
                      style: estilo(14, peso: FontWeight.w700, color: _semaforo(x['primera_calidad'] as num?)))),
                  DataCell(Text('${x['devoluciones']}')),
                  if (_agrupar != 'operario') ...[
                    DataCell(Text('${x['entra']}')),
                    DataCell(Text('${x['segundas']}')),
                    DataCell(Text(x['segundas_pct'] == null ? '—' : '${Formato.numero(x['segundas_pct'], decimales: 1)} %')),
                  ],
                  DataCell(Text('${x['defecto_principal'] ?? ''}')),
                ]),
            ],
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Tarjeta(
        titulo: 'Defectos más frecuentes · ${_prendas(total)}',
        child: pareto.isEmpty
            ? Padding(padding: const EdgeInsets.all(12), child: Text('Sin defectos en el rango.', style: estilo(14, color: Colores.textoSuave)))
            : Column(children: [
                for (final x in pareto)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      SizedBox(width: 240, child: Text('${x['nombre']}', style: estilo(14, color: x['severidad'] == 'critico' ? Colores.rojo : null))),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, c) => Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 16,
                              width: c.maxWidth * (x['cantidad'] as int) / (pareto.first['cantidad'] as int),
                              decoration: BoxDecoration(color: Colores.deProceso('calidad'), borderRadius: BorderRadius.circular(3)),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 210, child: Text('${x['cantidad']} · ${Formato.numero(x['porcentaje'], decimales: 1)} % (acum. ${Formato.numero(x['acumulado'], decimales: 0)} %)',
                          textAlign: TextAlign.right, style: estilo(13))),
                    ]),
                  ),
              ]),
      ),
    ]);
  }

  // ---------- Defectos ----------
  Widget _defectos(List<Map<String, dynamic>> xs, List<Map<String, dynamic>> procesos, bool editar) {
    Future<void> cambiar(Map<String, dynamic> d, String campo, Object? v) async {
      try {
        await db.from('defectos').update({campo: v}).eq('id', d['id']);
        _cargar();
      } catch (e) {
        if (mounted) avisar(context, mensajeError(e), error: true);
      }
    }

    return Tarjeta(
      titulo: 'Catálogo de defectos',
      accion: editar
          ? FilledButton.icon(
              onPressed: () async {
                final n = await pedirTexto(context, titulo: 'Nuevo defecto', etiqueta: 'Nombre (ej. Botón flojo)');
                if (n == null) return;
                try {
                  final base = n.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '').padRight(3, 'X').substring(0, 3);
                  await db.from('defectos').insert({'codigo': '$base${DateTime.now().millisecondsSinceEpoch % 1000}', 'nombre': n});
                  _cargar();
                } catch (e) {
                  if (mounted) avisar(context, mensajeError(e), error: true);
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Nuevo defecto'))
          : null,
      child: Tabla(
        columnas: const ['Código', 'Defecto', 'Proceso donde se origina', 'Severidad', 'Activo'],
        filas: [
          for (final d in xs)
            DataRow(cells: [
              DataCell(Text('${d['codigo']}', style: estiloCodigo(12.5))),
              DataCell(Text('${d['nombre']}')),
              DataCell(DropdownButton<String?>(
                value: d['proceso'] as String?,
                underline: const SizedBox(),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Cualquiera')),
                  for (final p in procesos) DropdownMenuItem(value: p['codigo'] as String, child: Text('${p['nombre']}')),
                ],
                onChanged: editar ? (v) => cambiar(d, 'proceso', v) : null,
              )),
              DataCell(DropdownButton<String>(
                value: d['severidad'] as String,
                underline: const SizedBox(),
                items: [for (final e in _severidades.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: editar ? (v) => cambiar(d, 'severidad', v) : null,
              )),
              DataCell(Checkbox(value: d['activo'] == true, onChanged: editar ? (v) => cambiar(d, 'activo', v) : null)),
            ]),
        ],
      ),
    );
  }

  // ---------- Muestreo ----------
  Widget _muestreo(List<Map<String, dynamic>> planes, bool aprobar) {
    final p = planes.firstOrNull;
    if (p == null) return const Text('No hay plan de muestreo.');
    final tabla = (p['tabla'] is String ? jsonDecode(p['tabla']) : p['tabla'] as List).cast<Map<String, dynamic>>();
    return Tarjeta(
      titulo: '${p['nombre']}',
      accion: aprobar
          ? OutlinedButton.icon(
              onPressed: () async {
                final c = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(tabla));
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Editar tabla de muestreo'),
                    content: SizedBox(
                        width: 520,
                        child: TextField(controller: c, maxLines: 18, style: estiloCodigo(12.5),
                            decoration: const InputDecoration(helperText: 'Lista de {desde, hasta, muestra, acepta}; hasta = null sin tope'))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
                      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Guardar')),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  await db.from('planes_muestreo').update({'tabla': jsonDecode(c.text)}).eq('id', p['id']);
                  _cargar();
                } catch (e) {
                  if (mounted) avisar(context, 'No se guardó: ${mensajeError(e)}', error: true);
                }
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Editar'))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('En la auditoría final la tablet pide revisar la muestra al azar. Se aprueba si las prendas con defecto no pasan del número de aceptación; '
            'si el lote es más pequeño que la muestra, se revisa completo.', style: estilo(13, color: Colores.textoSuave)),
        const SizedBox(height: 10),
        Tabla(
          columnas: const ['Prendas del lote', 'Revisar', 'Aprobar con hasta', 'Rechazar con'],
          numericas: const {1, 2, 3},
          filas: [
            for (final t in tabla)
              DataRow(cells: [
                DataCell(Text(t['hasta'] == null ? '${Formato.numero(t['desde'], decimales: 0)} o más'
                    : '${Formato.numero(t['desde'], decimales: 0)} a ${Formato.numero(t['hasta'], decimales: 0)}')),
                DataCell(Text('${t['muestra']}')),
                DataCell(Text('${t['acepta']}')),
                DataCell(Text('${(t['acepta'] as int) + 1}')),
              ]),
          ],
        ),
      ]),
    );
  }
}
