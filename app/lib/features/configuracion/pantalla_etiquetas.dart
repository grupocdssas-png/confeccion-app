import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/etiquetas/etiquetas_pdf.dart';
import '../../core/etiquetas/impresion_web.dart';
import '../../core/etiquetas/zpl.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart';

final _impresorasProvider = FutureProvider.autoDispose((ref) => db.from('impresoras').select('*, estaciones(codigo, nombre)').order('nombre', ascending: true));
final _plantillasProvider = FutureProvider.autoDispose((ref) => db.from('plantillas_etiqueta').select().order('tipo', ascending: true));

final _ejemplos = <String, Map<String, Object?>>{
  'rollo': datosEtiquetaRollo(codigo: 'TL-000123', tela: 'Jersey 30/1 algodón (EJEMPLO)', color: 'Negro', lote: 'L-2410-N1', tono: 'A',
      anchoCm: 180.5, metros: 77.28, kilos: 22.4, proveedor: 'Proveedor de ejemplo', fechaIngreso: DateTime.now(), ubicacion: 'UB-BT-A01'),
  'ubicacion': datosEtiquetaUbicacion(codigo: 'UB-BT-A01', bodega: 'Bodega de telas', descripcion: 'Estantería A, nivel 1'),
};

/// Configuración → Impresoras y plantillas de etiquetas (ZPL editable).
class PantallaEtiquetas extends ConsumerWidget {
  const PantallaEtiquetas({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('configuracion') ?? false;
    final imp = ref.watch(_impresorasProvider);
    final pla = ref.watch(_plantillasProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EncabezadoPagina('Impresoras y etiquetas', subtitulo: 'Zebra a 203 dpi · ZPL con ^CI28 (UTF-8) · QR modelo 2, corrección M', acciones: [
        OutlinedButton(onPressed: () => context.go('/configuracion'), child: const Text('Volver a configuración')),
      ]),
      Tarjeta(
        titulo: 'Impresoras',
        accion: editar
            ? FilledButton.icon(
                onPressed: () async {
                  if (await showDialog<bool>(context: context, builder: (_) => const _DialogoImpresora()) == true) ref.invalidate(_impresorasProvider);
                },
                icon: const Icon(Icons.add),
                label: const Text('Agregar'))
            : null,
        child: imp.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(mensajeError(e)),
          data: (l) => Tabla(
            columnas: const ['Nombre', 'Modelo', 'Conexión', 'Dirección', 'Material', 'Estaciones', ''],
            filas: [
              for (final i in l)
                DataRow(cells: [
                  DataCell(Text('${i['nombre']}')),
                  DataCell(Text('${i['modelo'] ?? ''}')),
                  DataCell(Text('${i['conexion']}'.toUpperCase())),
                  DataCell(Text(i['conexion'] == 'tcp' ? '${i['ip']}:${i['puerto']}' : '${i['mac_bluetooth'] ?? '—'}', style: estiloCodigo(13, peso: FontWeight.w400))),
                  DataCell(Text(switch (i['material']) { 'termico_directo' => 'Térmico directo', 'transferencia' => 'Transferencia', _ => 'Sintético' })),
                  DataCell(Text([for (final e in i['estaciones'] as List) e['codigo']].join(', '))),
                  DataCell(editar
                      ? TextButton(
                          onPressed: () async {
                            if (await showDialog<bool>(context: context, builder: (_) => _DialogoImpresora(impresora: i)) == true) {
                              ref.invalidate(_impresorasProvider);
                            }
                          },
                          child: const Text('Editar'))
                      : const SizedBox()),
                ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text('La impresora de cada tablet se asigna en su estación. Desde el navegador se imprime con Zebra Browser Print '
          '(programa gratuito de Zebra en el PC) o, si no está, en PDF al tamaño real.',
          style: estilo(12.5, color: Colores.textoSuave)),
      const SizedBox(height: 20),
      pla.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e)),
        data: (l) => Column(children: [
          for (final p in l) ...[_EditorPlantilla(plantilla: p, editar: editar, onGuardado: () => ref.invalidate(_plantillasProvider)), const SizedBox(height: 16)],
        ]),
      ),
    ]);
  }
}

class _EditorPlantilla extends StatefulWidget {
  const _EditorPlantilla({required this.plantilla, required this.editar, required this.onGuardado});
  final Map<String, dynamic> plantilla;
  final bool editar;
  final VoidCallback onGuardado;
  @override
  State<_EditorPlantilla> createState() => _EditorPlantillaState();
}

class _EditorPlantillaState extends State<_EditorPlantilla> {
  late final _zpl = TextEditingController(text: widget.plantilla['zpl']);
  var _verResultado = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.plantilla;
    final ejemplo = _ejemplos[p['tipo']] ?? {};
    return Tarjeta(
      titulo: '${p['nombre']} · versión ${p['version']}',
      accion: Wrap(spacing: 8, children: [
        OutlinedButton(onPressed: () => setState(() => _verResultado = !_verResultado), child: Text(_verResultado ? 'Ver plantilla' : 'Ver con datos de ejemplo')),
        OutlinedButton.icon(
          icon: const Icon(Icons.print_outlined),
          label: const Text('Imprimir prueba'),
          onPressed: () async {
            try {
              final r = await imprimirEtiquetasWeb(
                etiquetas: [(codigo: 'PRUEBA-${p['tipo']}', entidadId: null, zpl: renderizarZpl(_zpl.text, ejemplo))],
                generarPdf: () => p['tipo'] == 'rollo' ? EtiquetasPdf.rollos([ejemplo]) : EtiquetasPdf.ubicaciones([ejemplo]),
                entidad: 'prueba', plantillaId: p['id'], plantillaVersion: p['version'],
              );
              if (context.mounted) avisar(context, r.medio == 'browser_print' ? 'Prueba enviada a ${r.impresora}' : 'Browser Print no está activo: se abrió el PDF');
            } catch (e) {
              if (context.mounted) avisar(context, mensajeError(e), error: true);
            }
          },
        ),
        if (widget.editar && !_verResultado)
          FilledButton(
            onPressed: () async {
              try {
                await db.from('plantillas_etiqueta').update({'zpl': _zpl.text}).eq('id', p['id']);
                widget.onGuardado();
                if (context.mounted) avisar(context, 'Plantilla guardada (nueva versión)');
              } catch (e) {
                if (context.mounted) avisar(context, mensajeError(e), error: true);
              }
            },
            child: const Text('Guardar'),
          ),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Campos disponibles: ${ejemplo.keys.map((k) => '{{$k}}').join('  ')}  {{copias}}', style: estilo(12.5, color: Colores.textoSuave)),
        const SizedBox(height: 8),
        TextField(
          controller: _verResultado ? TextEditingController(text: renderizarZpl(_zpl.text, ejemplo)) : _zpl,
          readOnly: _verResultado || !widget.editar,
          maxLines: 18,
          style: estiloCodigo(12.5, peso: FontWeight.w400),
          decoration: const InputDecoration(),
        ),
      ]),
    );
  }
}

class _DialogoImpresora extends ConsumerStatefulWidget {
  const _DialogoImpresora({this.impresora});
  final Map<String, dynamic>? impresora;
  @override
  ConsumerState<_DialogoImpresora> createState() => _DialogoImpresoraState();
}

class _DialogoImpresoraState extends ConsumerState<_DialogoImpresora> {
  late final i = widget.impresora;
  late final _nombre = TextEditingController(text: i?['nombre']);
  late final _modelo = TextEditingController(text: i?['modelo']);
  late final _ip = TextEditingController(text: '${i?['ip'] ?? ''}'.split('/').first);
  late final _puerto = TextEditingController(text: '${i?['puerto'] ?? 9100}');
  late var _conexion = i?['conexion'] ?? 'tcp';
  late var _material = i?['material'] ?? 'termico_directo';
  String? _error;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(i == null ? 'Nueva impresora' : 'Editar impresora'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _nombre, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 10),
            TextField(controller: _modelo, decoration: const InputDecoration(labelText: 'Modelo', hintText: 'ZD421t')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _conexion,
              decoration: const InputDecoration(labelText: 'Conexión'),
              items: const [
                DropdownMenuItem(value: 'tcp', child: Text('Red (IP fija, puerto 9100)')),
                DropdownMenuItem(value: 'browser_print', child: Text('PC de oficina (Zebra Browser Print)')),
              ],
              onChanged: (v) => setState(() => _conexion = v!),
            ),
            if (_conexion == 'tcp') ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _ip, decoration: const InputDecoration(labelText: 'IP fija', hintText: '192.168.1.50'))),
                const SizedBox(width: 10),
                SizedBox(width: 100, child: TextField(controller: _puerto, decoration: const InputDecoration(labelText: 'Puerto'))),
              ]),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _material,
              decoration: const InputDecoration(labelText: 'Material de etiqueta'),
              items: const [
                DropdownMenuItem(value: 'termico_directo', child: Text('Térmico directo (paquetes, juegos)')),
                DropdownMenuItem(value: 'transferencia', child: Text('Transferencia térmica (rollos, ubicaciones, máquinas)')),
                DropdownMenuItem(value: 'sintetico', child: Text('Sintética')),
              ],
              onChanged: (v) => _material = v!,
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: estilo(13, color: Colores.rojo))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              final d = {
                'nombre': _nombre.text.trim(), 'modelo': _modelo.text.trim(), 'conexion': _conexion, 'material': _material,
                'ip': _conexion == 'tcp' ? _ip.text.trim() : null, 'puerto': int.tryParse(_puerto.text) ?? 9100,
              };
              try {
                i == null ? await db.from('impresoras').insert(d) : await db.from('impresoras').update(d).eq('id', i!['id']);
                if (context.mounted) Navigator.pop(context, true);
              } catch (e) {
                setState(() => _error = mensajeError(e));
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      );
}
