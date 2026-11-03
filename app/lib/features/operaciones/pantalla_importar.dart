import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/importacion/lector_tablas.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError;
import 'pantalla_operaciones.dart' show operacionesProvider, catalogoDisenoProvider;

const _tipos = {
  'secuencia': 'Secuencia de una referencia',
  'operaciones': 'Lista maestra de operaciones',
  'celulas': 'Células / módulos',
  'empleados': 'Empleados',
  'maquinas': 'Máquinas',
};

/// Importa desde archivos exportados de SAMMU: 1) elegir qué se importa y el
/// archivo, 2) revisar qué columna corresponde a cada campo, 3) validar sin
/// guardar, 4) importar. Lo existente (mismo código) se actualiza.
class PantallaImportar extends ConsumerStatefulWidget {
  const PantallaImportar({super.key});
  @override
  ConsumerState<PantallaImportar> createState() => _PantallaImportarState();
}

final _fichasBorradorProvider = FutureProvider.autoDispose((ref) => db
    .from('ficha_versiones')
    .select('id, version, referencias!ficha_versiones_referencia_id_fkey(codigo, nombre)')
    .eq('estado', 'borrador'));

/// "POLO_ECONOMICA001.csv" → ("POLO-ECONOMICA-001", "Polo economica 001")
(String, String) referenciaDesdeArchivo(String archivo) {
  final base = archivo.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll(RegExp(r'[_\s]+'), ' ').trim()
      .replaceAllMapped(RegExp(r'([A-Za-zÁÉÍÓÚÑáéíóúñ])(\d)'), (m) => '${m[1]} ${m[2]}');
  final codigo = base.toUpperCase().replaceAll(' ', '-');
  final nombre = base.isEmpty ? '' : base[0].toUpperCase() + base.substring(1).toLowerCase();
  return (codigo, nombre);
}

class _PantallaImportarState extends ConsumerState<PantallaImportar> {
  var _tipo = 'secuencia';
  // Opciones de la secuencia
  var _destinoNuevo = true;
  String? _fichaId, _familia, _tipoProducto;
  final _codigoRef = TextEditingController(), _nombreRef = TextEditingController();
  var _crearMaquinas = true;
  var _reemplazar = true;
  String? _archivo;
  TablaLeida? _tabla;
  Map<String, int?> _mapeo = {};
  Map<String, dynamic>? _validacion;
  Map<String, dynamic>? _resultado;
  String? _error;
  var _trabajando = false;

  Future<void> _elegir() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv', 'txt']);
    if (f == null) return;
    try {
      final t = leerTablaArchivo(await f.readAsBytes(), f.name);
      if (t.filas.length < 2) throw const FormatException('El archivo no tiene filas de datos');
      setState(() {
        _archivo = f.name;
        final (cod, nom) = referenciaDesdeArchivo(f.name);
        _codigoRef.text = cod;
        _nombreRef.text = nom;
        _tabla = t;
        _mapeo = autoMapear(_tipo, t.filas.first);
        _validacion = null;
        _resultado = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'No se pudo leer el archivo: $e');
    }
  }

  List<Map<String, String?>> get _filas =>
      construirFilas(_tipo, _tabla!.filas.sublist(1), _mapeo, decimalComa: _tabla!.decimalComa);

  Map<String, dynamic> get _opciones => {
        'crear_maquinas': _crearMaquinas,
        if (_tipo == 'secuencia') ...{
          'reemplazar': _reemplazar,
          if (_destinoNuevo)
            'nueva_referencia': {'codigo': _codigoRef.text.trim(), 'nombre': _nombreRef.text.trim(), 'familia_id': _familia, 'tipo_producto_id': _tipoProducto}
          else
            'ficha_id': _fichaId,
        },
      };

  bool get _destinoListo => _tipo != 'secuencia' || (_destinoNuevo ? _codigoRef.text.trim().isNotEmpty && _nombreRef.text.trim().isNotEmpty : _fichaId != null);

  bool get _mapeoCompleto => camposImportacion[_tipo]!.where((c) => c.obligatorio).every((c) => _mapeo[c.clave] != null);

  Future<void> _ejecutar(bool soloValidar) async {
    setState(() {
      _trabajando = true;
      _error = null;
    });
    try {
      final r = soloValidar
          ? await db.rpc('validar_importacion', params: {'p_tipo': _tipo, 'p_filas': _filas, 'p_opciones': _opciones})
          : await db.rpc('importar', params: {'p_tipo': _tipo, 'p_filas': _filas, 'p_archivo': _archivo, 'p_opciones': _opciones});
      setState(() => soloValidar ? _validacion = Map<String, dynamic>.from(r) : _resultado = Map<String, dynamic>.from(r));
      if (!soloValidar) {
        ref.invalidate(operacionesProvider);
        ref.invalidate(_fichasBorradorProvider);
      }
    } catch (e) {
      setState(() => _error = mensajeError(e));
    } finally {
      setState(() => _trabajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final campos = camposImportacion[_tipo]!;
    final t = _tabla;
    final sesion = ref.watch(sesionProvider).value;
    final modulo = const {'operaciones': 'operaciones', 'secuencia': 'ficha_tecnica', 'empleados': 'personal', 'maquinas': 'mantenimiento'}[_tipo] ?? 'configuracion';
    final puede = (sesion?.puedeEditar(modulo) ?? false) && (_tipo != 'secuencia' || (sesion?.puedeEditar('operaciones') ?? false));
    final catDiseno = ref.watch(catalogoDisenoProvider).value;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Importar desde SAMMU', subtitulo: 'Excel (.xlsx) o CSV exportado de SAMMU. Lo que ya existe con el mismo código se actualiza.',
          acciones: [OutlinedButton(onPressed: () => context.go('/operaciones'), child: const Text('Volver'))]),
      Tarjeta(
        titulo: '1. Qué importar y archivo',
        child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<String>(
            segments: [for (final e in _tipos.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {_tipo},
            onSelectionChanged: (s) => setState(() {
              _tipo = s.first;
              if (_tabla != null) _mapeo = autoMapear(_tipo, _tabla!.filas.first);
              _validacion = null;
              _resultado = null;
            }),
          ),
          FilledButton.icon(onPressed: puede ? _elegir : null, icon: const Icon(Icons.upload_file), label: Text(_archivo ?? 'Elegir archivo')),
          if (!puede) Text('Su rol no puede importar ${_tipos[_tipo]!.toLowerCase()}.', style: estilo(13, color: Colores.rojo)),
          if (t != null) Text('${t.filas.length - 1} filas${t.decimalComa ? ' · números con coma decimal' : ''}', style: estilo(13, color: Colores.textoSuave)),
          Text(switch (_tipo) {
            'secuencia' => 'El archivo de SAMMU con la secuencia de una referencia: crea las operaciones que falten en la lista maestra y arma la secuencia de la ficha.',
            'empleados' => 'Importe primero las células: los empleados se asignan a su célula por código.',
            'operaciones' => 'Las máquinas se reconocen por el código o nombre del tipo de máquina (ej. FIL o Fileteadora).',
            _ => '',
          }, style: estilo(12.5, color: Colores.textoSuave)),
        ]),
      ),
      if (_tipo == 'secuencia' || _tipo == 'operaciones' || _tipo == 'maquinas') ...[
        const SizedBox(height: 16),
        Tarjeta(
          titulo: _tipo == 'secuencia' ? 'Referencia de destino y opciones' : 'Opciones',
          child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (_tipo == 'secuencia') ...[
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: true, label: Text('Referencia nueva')), ButtonSegment(value: false, label: Text('Ficha existente en borrador'))],
                selected: {_destinoNuevo},
                onSelectionChanged: (x) => setState(() { _destinoNuevo = x.first; _validacion = null; }),
              ),
              if (_destinoNuevo) ...[
                SizedBox(width: 200, child: TextField(controller: _codigoRef, onChanged: (_) => setState(() => _validacion = null),
                    decoration: const InputDecoration(labelText: 'Código de referencia', isDense: true))),
                SizedBox(width: 260, child: TextField(controller: _nombreRef, onChanged: (_) => setState(() => _validacion = null),
                    decoration: const InputDecoration(labelText: 'Nombre', isDense: true))),
                if (catDiseno != null) ...[
                  SizedBox(width: 200, child: DropdownButtonFormField<String?>(
                    initialValue: _familia, isDense: true, decoration: const InputDecoration(labelText: 'Familia', isDense: true),
                    items: [const DropdownMenuItem(value: null, child: Text('—')), for (final x in catDiseno.familias) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
                    onChanged: (v) => setState(() { _familia = v; _tipoProducto = null; _validacion = null; }))),
                  SizedBox(width: 220, child: DropdownButtonFormField<String?>(
                    key: ValueKey(_familia), initialValue: _tipoProducto, isDense: true, decoration: const InputDecoration(labelText: 'Tipo de producto', isDense: true),
                    items: [const DropdownMenuItem(value: null, child: Text('—')),
                      for (final x in catDiseno.tipos.where((t) => t['familia_id'] == _familia)) DropdownMenuItem(value: x['id'] as String, child: Text('${x['nombre']}'))],
                    onChanged: (v) => setState(() { _tipoProducto = v; _validacion = null; }))),
                ],
              ] else
                SizedBox(width: 360, child: DropdownButtonFormField<String>(
                  initialValue: _fichaId, isExpanded: true, decoration: const InputDecoration(labelText: 'Ficha en borrador', isDense: true),
                  items: [for (final x in ref.watch(_fichasBorradorProvider).value ?? const [])
                    DropdownMenuItem(value: x['id'] as String, child: Text('${x['referencias']['codigo']} v${x['version']} · ${x['referencias']['nombre']}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() { _fichaId = v; _validacion = null; }))),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(value: _reemplazar, onChanged: (v) => setState(() { _reemplazar = v!; _validacion = null; })),
                const Text('Reemplazar la secuencia que tenga la ficha'),
              ]),
            ],
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _crearMaquinas, onChanged: (v) => setState(() { _crearMaquinas = v!; _validacion = null; })),
              const Text('Crear tipos de máquina que no existan (ej. PL1, FLT, OJ…)'),
            ]),
            if (_tipo == 'secuencia')
              Text('Las operaciones se reconocen por nombre dentro del mismo tipo de producto; si el SAM cambió, se actualiza en la lista maestra y queda en el historial.',
                  style: estilo(12.5, color: Colores.textoSuave)),
          ]),
        ),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: estilo(14, color: Colores.rojo))),
      if (t != null) ...[
        const SizedBox(height: 16),
        Tarjeta(
          titulo: '2. Columnas del archivo',
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (final c in campos)
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<int?>(
                  key: ValueKey('$_tipo-${c.clave}-${_archivo ?? ''}'),
                  initialValue: _mapeo[c.clave],
                  isExpanded: true,
                  decoration: InputDecoration(labelText: '${c.nombre}${c.obligatorio ? ' *' : ''}', isDense: true,
                      labelStyle: TextStyle(color: c.obligatorio && _mapeo[c.clave] == null ? Colores.rojo : null)),
                  items: [const DropdownMenuItem(value: null, child: Text('(no importar)')),
                    for (var i = 0; i < t.filas.first.length; i++) DropdownMenuItem(value: i, child: Text(t.filas.first[i].isEmpty ? 'Columna ${i + 1}' : t.filas.first[i], overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() {
                    _mapeo[c.clave] = v;
                    _validacion = null;
                  }),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Tarjeta(
          titulo: 'Vista previa (primeras 15 filas)',
          child: Tabla(
            columnas: [for (final c in campos) if (_mapeo[c.clave] != null) c.nombre],
            filas: [
              for (final f in _filas.take(15))
                DataRow(cells: [for (final c in campos) if (_mapeo[c.clave] != null) DataCell(Text(f[c.clave] ?? '—'))]),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Tarjeta(
          titulo: '3. Validar e importar',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, children: [
              OutlinedButton.icon(onPressed: _trabajando || !_mapeoCompleto || !_destinoListo ? null : () => _ejecutar(true),
                  icon: const Icon(Icons.rule), label: const Text('Validar sin guardar')),
              FilledButton.icon(onPressed: _trabajando || !_mapeoCompleto || !_destinoListo || _validacion == null || _resultado != null ? null : () => _ejecutar(false),
                  icon: const Icon(Icons.download_done), label: Text('Importar ${(_validacion?['ok'] ?? 0)} filas válidas')),
            ]),
            if (!_mapeoCompleto) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Falta relacionar los campos marcados con *.', style: estilo(13, color: Colores.rojo))),
            for (final (titulo, r) in [('Validación', _validacion), ('Resultado de la importación', _resultado)])
              if (r != null) ...[
                const SizedBox(height: 14),
                Text('$titulo: ${Formato.numero(r['ok'], decimales: 0)} filas correctas · ${(r['errores'] as List).length} con error',
                    style: estilo(15, peso: FontWeight.w600, color: (r['errores'] as List).isEmpty ? Colores.verde : Colores.ambar)),
                if (r['resumen'] != null) _Resumen(r['resumen'] as Map<String, dynamic>, importado: identical(r, _resultado)),
                if ((r['errores'] as List).isNotEmpty)
                  Tabla(columnas: const ['Fila', 'Código', 'Error'], filas: [
                    for (final e in (r['errores'] as List).take(200))
                      DataRow(cells: [DataCell(Text('${(e['fila'] as int) + 1}')), DataCell(Text('${e['codigo'] ?? ''}')),
                        DataCell(Text('${e['error']}', style: estilo(13, color: Colores.rojo)))]),
                  ]),
              ],
          ]),
        ),
      ],
    ]);
  }
}


class _Resumen extends StatelessWidget {
  const _Resumen(this.r, {required this.importado});
  final Map<String, dynamic> r;
  final bool importado;
  @override
  Widget build(BuildContext context) {
    final cambios = (r['sam_cambiados'] as List? ?? const []);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 6, children: [
          Pastilla('${r['operaciones_nuevas'] ?? 0} operaciones nuevas', color: Colores.deProceso('corte')),
          Pastilla('${r['operaciones_existentes'] ?? 0} ya existían', color: Colores.textoSuave),
          if ((r['maquinas_creadas'] ?? 0) > 0) Pastilla('${r['maquinas_creadas']} tipos de máquina nuevos', color: Colores.ambar),
          if (r['sam_total'] != null) Pastilla('SAM total ${Formato.numero(r['sam_total'], decimales: 4)} min', color: Colores.verde),
        ]),
        if (cambios.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('SAM que cambian en la lista maestra:', style: estilo(13, peso: FontWeight.w600)),
          for (final c in cambios.take(30))
            Text('${c['codigo']} ${c['nombre']}: ${Formato.numero(c['antes'], decimales: 4)} → ${Formato.numero(c['ahora'], decimales: 4)}', style: estilo(13)),
        ],
        if (importado && r['ficha_id'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(onPressed: () => context.go('/fichas/${r['ficha_id']}?paso=5'), icon: const Icon(Icons.open_in_new), label: const Text('Abrir la ficha')),
          ),
      ]),
    );
  }
}
