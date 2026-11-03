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
import 'pantalla_operaciones.dart' show operacionesProvider;

const _tipos = {
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

class _PantallaImportarState extends ConsumerState<PantallaImportar> {
  var _tipo = 'operaciones';
  var _crearMaquinas = true;
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

  Map<String, dynamic> get _opciones => {'crear_maquinas': _crearMaquinas};

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
    final modulo = const {'operaciones': 'operaciones', 'empleados': 'personal', 'maquinas': 'mantenimiento'}[_tipo] ?? 'configuracion';
    final puede = sesion?.puedeEditar(modulo) ?? false;
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
            'empleados' => 'Importe primero las células: los empleados se asignan a su célula por código.',
            'operaciones' => 'Lista maestra general. La secuencia de una referencia (reporte de SAMMU por producto) se importa desde su ficha técnica, paso 6.',
            _ => '',
          }, style: estilo(12.5, color: Colores.textoSuave)),
        ]),
      ),
      if (_tipo == 'operaciones' || _tipo == 'maquinas') ...[
        const SizedBox(height: 16),
        Tarjeta(
          titulo: 'Opciones',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: _crearMaquinas, onChanged: (v) => setState(() { _crearMaquinas = v!; _validacion = null; })),
            const Text('Crear tipos de máquina que no existan (ej. PL1, FLT, OJ…)'),
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
              OutlinedButton.icon(onPressed: _trabajando || !_mapeoCompleto ? null : () => _ejecutar(true),
                  icon: const Icon(Icons.rule), label: const Text('Validar sin guardar')),
              FilledButton.icon(onPressed: _trabajando || !_mapeoCompleto || _validacion == null || _resultado != null ? null : () => _ejecutar(false),
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
        ]),
        if (cambios.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('SAM que cambian en la lista maestra:', style: estilo(13, peso: FontWeight.w600)),
          for (final c in cambios.take(30))
            Text('${c['codigo']} ${c['nombre']}: ${Formato.numero(c['antes'], decimales: 4)} → ${Formato.numero(c['ahora'], decimales: 4)}', style: estilo(13)),
        ],
      ]),
    );
  }
}
