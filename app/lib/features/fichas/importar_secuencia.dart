import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/importacion/lector_tablas.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError;
import '../operaciones/pantalla_operaciones.dart' show operacionesProvider;
import 'datos_ficha.dart';

/// Importa la secuencia de operaciones del producto desde el reporte de SAMMU,
/// directamente en esta ficha (en borrador). El SAM de cada operación queda en
/// la ficha; la lista maestra solo recibe las operaciones que no existan.
Future<void> importarSecuenciaSammu(BuildContext context, WidgetRef ref, Map<String, dynamic> ficha) =>
    showDialog(context: context, builder: (_) => _DialogoSecuencia(ficha: ficha));

class _DialogoSecuencia extends ConsumerStatefulWidget {
  const _DialogoSecuencia({required this.ficha});
  final Map<String, dynamic> ficha;
  @override
  ConsumerState<_DialogoSecuencia> createState() => _DialogoSecuenciaState();
}

class _DialogoSecuenciaState extends ConsumerState<_DialogoSecuencia> {
  String? _archivo, _error;
  TablaLeida? _tabla;
  Map<String, int?> _mapeo = {};
  var _crearMaquinas = true;
  Map<String, dynamic>? _validacion, _resultado;
  var _trabajando = false;

  bool get _tieneOps => (widget.ficha['ficha_operaciones'] as List).isNotEmpty;
  bool get _mapeoCompleto => camposImportacion['secuencia']!.where((c) => c.obligatorio).every((c) => _mapeo[c.clave] != null);
  List<Map<String, String?>> get _filas => construirFilas('secuencia', _tabla!.filas.sublist(1), _mapeo, decimalComa: _tabla!.decimalComa);
  Map<String, dynamic> get _opciones => {'ficha_id': widget.ficha['id'], 'crear_maquinas': _crearMaquinas, 'reemplazar': true};

  Future<void> _elegir() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv', 'txt']);
    if (f == null) return;
    try {
      final t = leerTablaArchivo(await f.readAsBytes(), f.name);
      if (t.filas.length < 2) throw const FormatException('El archivo no tiene filas');
      setState(() {
        _archivo = f.name;
        _tabla = t;
        _mapeo = autoMapear('secuencia', t.filas.first);
        _validacion = null;
        _error = null;
      });
      if (_mapeoCompleto) await _ejecutar(true); // se valida apenas se carga
    } catch (e) {
      setState(() => _error = 'No se pudo leer el archivo: $e');
    }
  }

  Future<void> _ejecutar(bool soloValidar) async {
    setState(() {
      _trabajando = true;
      _error = null;
    });
    try {
      final r = soloValidar
          ? await db.rpc('validar_importacion', params: {'p_tipo': 'secuencia', 'p_filas': _filas, 'p_opciones': _opciones})
          : await db.rpc('importar', params: {'p_tipo': 'secuencia', 'p_filas': _filas, 'p_archivo': _archivo, 'p_opciones': _opciones});
      setState(() => soloValidar ? _validacion = Map<String, dynamic>.from(r) : _resultado = Map<String, dynamic>.from(r));
      if (!soloValidar) {
        ref.invalidate(fichaProvider(widget.ficha['id']));
        ref.invalidate(operacionesProvider);
        ref.invalidate(catalogoFichaProvider);
      }
    } catch (e) {
      setState(() => _error = mensajeError(e));
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _tabla;
    final r = _resultado ?? _validacion;
    final errores = (r?['errores'] as List?) ?? const [];
    final resumen = r?['resumen'] as Map<String, dynamic>?;
    final distintos = (resumen?['sam_distintos_maestra'] as List?) ?? const [];
    return AlertDialog(
      title: Text('Importar secuencia de SAMMU · ${widget.ficha['referencias']['codigo']} v${widget.ficha['version']}'),
      content: SizedBox(
        width: 900,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Use el reporte de SAMMU de esta referencia (Secuencia; Nombre; Sitio de trabajo; Sam; Proceso; Repeticiones…), '
                'en .csv o .xlsx, sin cambiarle nada.', style: estilo(13.5, color: Colores.textoSuave)),
            if (_tieneOps)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('La ficha ya tiene ${(widget.ficha['ficha_operaciones'] as List).length} operaciones: se reemplazan por las del archivo.',
                    style: estilo(13.5, peso: FontWeight.w600, color: Colores.ambar)),
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.icon(onPressed: _trabajando || _resultado != null ? null : _elegir, icon: const Icon(Icons.upload_file), label: Text(_archivo ?? 'Elegir archivo')),
              if (t != null) Text('${t.filas.length - 1} operaciones', style: estilo(13, color: Colores.textoSuave)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(value: _crearMaquinas, onChanged: _resultado != null ? null : (v) => setState(() { _crearMaquinas = v!; _validacion = null; })),
                const Text('Crear tipos de máquina que no existan'),
              ]),
            ]),
            if (t != null && !_mapeoCompleto) ...[
              const SizedBox(height: 12),
              Text('No se reconocieron todas las columnas. Indique cuáles son:', style: estilo(13.5, color: Colores.rojo)),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final c in camposImportacion['secuencia']!.where((c) => c.obligatorio || _mapeo[c.clave] == null).take(6))
                  SizedBox(width: 200, child: DropdownButtonFormField<int?>(
                    initialValue: _mapeo[c.clave], isExpanded: true, isDense: true,
                    decoration: InputDecoration(labelText: '${c.nombre}${c.obligatorio ? ' *' : ''}', isDense: true),
                    items: [const DropdownMenuItem(value: null, child: Text('(no importar)')),
                      for (var i = 0; i < t.filas.first.length; i++) DropdownMenuItem(value: i, child: Text(t.filas.first[i], overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() { _mapeo[c.clave] = v; _validacion = null; }))),
              ]),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: _mapeoCompleto ? () => _ejecutar(true) : null, child: const Text('Validar'))),
            ],
            if (_trabajando) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: estilo(14, color: Colores.rojo))),
            if (r != null) ...[
              const SizedBox(height: 14),
              Text(_resultado != null ? 'Importada: ${r['ok']} operaciones en la ficha' : 'Revisión: ${r['ok']} operaciones correctas · ${errores.length} con error',
                  style: estilo(15, peso: FontWeight.w600, color: errores.isEmpty ? Colores.verde : Colores.ambar)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (resumen?['sam_total'] != null) Pastilla('SAM total ${Formato.numero(resumen!['sam_total'], decimales: 4)} min', color: Colores.verde),
                Pastilla('${resumen?['operaciones_nuevas'] ?? 0} nuevas en la lista maestra', color: Colores.deProceso('corte')),
                Pastilla('${resumen?['operaciones_existentes'] ?? 0} ya estaban', color: Colores.textoSuave),
                if ((resumen?['maquinas_creadas'] ?? 0) > 0) Pastilla('${resumen!['maquinas_creadas']} tipos de máquina nuevos', color: Colores.ambar),
              ]),
              if (distintos.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('En esta ficha el SAM es distinto al de la lista maestra (la lista maestra no cambia):', style: estilo(13, peso: FontWeight.w600)),
                for (final d in distintos.take(20))
                  Text('${d['nombre']}: ficha ${Formato.numero(d['ficha'], decimales: 4)} · lista maestra ${Formato.numero(d['maestra'], decimales: 4)}', style: estilo(13)),
              ],
              if (errores.isNotEmpty)
                Tabla(columnas: const ['Fila', 'Operación', 'Error'], filas: [
                  for (final e in errores.take(100))
                    DataRow(cells: [DataCell(Text('${(e['fila'] as int) + 1}')), DataCell(Text('${e['nombre'] ?? ''}')),
                      DataCell(Text('${e['error']}', style: estilo(13, color: Colores.rojo)))]),
                ]),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_resultado != null ? 'Cerrar' : 'Cancelar')),
        if (_resultado == null)
          FilledButton(
            onPressed: _trabajando || _validacion == null || errores.isNotEmpty ? null : () => _ejecutar(false),
            child: Text(_validacion == null ? 'Importar' : 'Importar ${_validacion!['ok']} operaciones'),
          ),
      ],
    );
  }
}
