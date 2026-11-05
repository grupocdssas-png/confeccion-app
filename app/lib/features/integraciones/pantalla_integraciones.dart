import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, mensajeError, avisar, pedirTexto;

/// Llama la Edge Function "integraciones" (las claves de Alegra y WhatsApp viven allá, nunca aquí).
Future<dynamic> funcionIntegraciones(String accion, [Map<String, dynamic> datos = const {}]) async {
  try {
    final r = await Supabase.instance.client.functions.invoke('integraciones', body: {'accion': accion, ...datos});
    return r.data;
  } on FunctionException catch (e) {
    final d = e.details;
    throw Exception(d is Map && d['error'] != null ? d['error'] : 'La función de integraciones no respondió (${e.status}). ¿Está desplegada?');
  } catch (e) {
    throw Exception('La función de integraciones no está disponible: $e');
  }
}

const _tipos = {
  'crear_item': 'Crear producto', 'ajuste_pt': 'Producto terminado', 'despacho': 'Despacho', 'anular_despacho': 'Anular despacho',
  'factura_proveedor': 'Factura de proveedor', 'ajuste_consumo': 'Consumo de materia prima', 'documento_soporte': 'Documento soporte',
  'concepto_nomina': 'Incentivo a nómina', 'mensaje': 'WhatsApp',
};
const _estados = {
  'pendiente': ('Pendiente', Colores.textoSuave), 'enviando': ('Enviando', Colores.ambar), 'enviado': ('Enviado', Colores.verde),
  'bloqueado': ('Falta enlazar', Colores.ambar), 'error': ('Error', Colores.rojo), 'descartado': ('Descartado', Colores.textoSuave),
};
const tiposAlerta = {
  'op_atrasada': 'OP atrasada', 'stock_bajo': 'Stock bajo', 'paro_largo': 'Paro largo', 'desviacion_corte': 'Consumo de tela fuera de tolerancia',
  'auditoria_rechazada': 'Auditoría rechazada', 'material_faltante': 'Falta material para una OP', 'stock_negativo': 'Inventario negativo',
};

/// Integraciones: lo que se envía a Alegra y WhatsApp, sus ajustes, los enlaces
/// con Alegra, la nómina real y los destinatarios de WhatsApp.
class PantallaIntegraciones extends ConsumerStatefulWidget {
  const PantallaIntegraciones({super.key});
  @override
  ConsumerState<PantallaIntegraciones> createState() => _PantallaIntegracionesState();
}

class _PantallaIntegracionesState extends ConsumerState<PantallaIntegraciones> {
  var _pestana = 'envios';

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('integraciones') ?? false;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Integraciones', subtitulo: 'Alegra (contabilidad, inventario y nómina) y WhatsApp'),
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, t) in const [('envios', 'Envíos'), ('alegra', 'Ajustes de Alegra'), ('enlaces', 'Enlaces con Alegra'), ('nomina', 'Nómina real'),
            ('whatsapp', 'WhatsApp')])
            ChoiceChip(
              label: Text(t),
              selected: _pestana == k,
              showCheckmark: false,
              labelStyle: estilo(13.5, peso: FontWeight.w600, color: _pestana == k ? Colors.white : Colores.texto),
              selectedColor: Colores.texto,
              backgroundColor: Colors.white,
              side: const BorderSide(color: Colores.borde),
              onSelected: (_) => setState(() => _pestana = k),
            ),
        ]),
      ),
      switch (_pestana) {
        'alegra' => _AjustesAlegra(editar: editar),
        'enlaces' => _Enlaces(editar: editar),
        'nomina' => _Nomina(editar: editar),
        'whatsapp' => _WhatsApp(editar: editar),
        _ => _Envios(editar: editar),
      },
    ]);
  }
}

// ---------------------------------------------------------------------------
// Envíos (la cola)
// ---------------------------------------------------------------------------
class _Envios extends StatefulWidget {
  const _Envios({required this.editar});
  final bool editar;
  @override
  State<_Envios> createState() => _EnviosState();
}

class _EnviosState extends State<_Envios> {
  String? _estado;
  late Future<List<Map<String, dynamic>>> _datos = _cargar();
  late Future<List<Map<String, dynamic>>> _conteo = _contar();
  var _procesando = false;

  Future<List<Map<String, dynamic>>> _cargar() async {
    var q = db.from('integraciones_cola').select();
    if (_estado != null) q = q.eq('estado', _estado!);
    return (await q.order('creado_en', ascending: false).limit(200)).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> _contar() async => (await db.from('integraciones_cola').select('estado, sistema')).cast<Map<String, dynamic>>();

  void _recargar() => setState(() {
        _datos = _cargar();
        _conteo = _contar();
      });

  Future<void> _procesar() async {
    setState(() => _procesando = true);
    try {
      final r = await funcionIntegraciones('procesar');
      if (mounted) {
        avisar(context, 'Enviados ${r['enviados']}, simulados ${r['simulados']}, falta enlazar ${r['bloqueados']}, con error ${r['fallidos']}');
      }
    } catch (e) {
      if (mounted) avisar(context, '$e'.replaceFirst('Exception: ', ''), error: true);
    }
    if (mounted) setState(() => _procesando = false);
    _recargar();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_conteo),
        future: _conteo,
        builder: (_, s) {
          final xs = s.data ?? [];
          int n(String e) => xs.where((x) => x['estado'] == e).length;
          return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final e in ['pendiente', 'bloqueado', 'error', 'enviado'])
              InkWell(
                onTap: () {
                  _estado = _estado == e ? null : e;
                  _recargar();
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 170,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white, borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _estado == e ? Colores.texto : Colores.borde, width: _estado == e ? 2 : 1)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_estados[e]!.$1, style: estilo(12.5, color: Colores.textoSuave)),
                    Text('${n(e)}', style: estilo(24, peso: FontWeight.w700, color: n(e) > 0 && e != 'enviado' && e != 'pendiente' ? _estados[e]!.$2 : null)),
                  ]),
                ),
              ),
            FilledButton.icon(
              onPressed: _procesando ? null : _procesar,
              icon: _procesando ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
              label: const Text('Procesar ahora'),
            ),
            Text('Se procesa sola cada 5 minutos.', style: estilo(12.5, color: Colores.textoSuave)),
          ]);
        },
      ),
      const SizedBox(height: 16),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          return Tarjeta(
            titulo: _estado == null ? 'Últimos envíos' : 'Envíos: ${_estados[_estado]!.$1.toLowerCase()}',
            child: Tabla(
              columnas: const ['Fecha', 'Destino', 'Qué', 'Estado', 'Intentos', 'Detalle', ''],
              numericas: const {4},
              vacio: 'No hay envíos.',
              filas: [
                for (final x in s.data!)
                  DataRow(cells: [
                    DataCell(Text(Formato.fechaHora(DateTime.parse(x['creado_en'])).replaceFirst(RegExp(r'/\d{4}'), ''))),
                    DataCell(Text(x['sistema'] == 'alegra' ? 'Alegra' : 'WhatsApp')),
                    DataCell(SizedBox(width: 360, child: Text('${_tipos[x['tipo']] ?? x['tipo']} · ${x['descripcion']}', maxLines: 2, overflow: TextOverflow.ellipsis))),
                    DataCell(x['externo_id'] == 'simulado'
                        ? const Pastilla('Simulado', color: Colores.ambar)
                        : Pastilla(_estados[x['estado']]!.$1, color: _estados[x['estado']]!.$2)),
                    DataCell(Text('${x['intentos']}')),
                    DataCell(SizedBox(
                      width: 240,
                      child: Text(
                          x['error'] ?? (x['externo_id'] == 'simulado' ? 'Para ${x['datos']['telefono']} (WhatsApp sin activar)' : x['externo_id'] != null ? 'Alegra #${x['externo_id']}' : ''),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: estilo(13, color: x['error'] != null ? Colores.rojo : Colores.textoSuave)),
                    )),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Ver', icon: const Icon(Icons.visibility_outlined, size: 20), onPressed: () => _ver(x)),
                      if (widget.editar && ['error', 'bloqueado', 'descartado'].contains(x['estado']))
                        IconButton(tooltip: 'Reintentar', icon: const Icon(Icons.replay, size: 20), onPressed: () => _accion(x, 'reintentar')),
                      if (widget.editar && ['pendiente', 'error', 'bloqueado'].contains(x['estado']))
                        IconButton(tooltip: 'Descartar', icon: const Icon(Icons.block, size: 20, color: Colores.rojo), onPressed: () => _accion(x, 'descartar')),
                    ])),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }

  Future<void> _accion(Map<String, dynamic> x, String a) async {
    try {
      await db.rpc('gestionar_trabajo', params: {'p_id': x['id'], 'p_accion': a});
      _recargar();
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  void _ver(Map<String, dynamic> x) {
    const enc = JsonEncoder.withIndent('  ');
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${_tipos[x['tipo']] ?? x['tipo']}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['descripcion']}', style: estilo(14, peso: FontWeight.w600)),
              if (x['respuesta']?['texto'] != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFFE7F7EC), borderRadius: BorderRadius.circular(8)),
                  child: Text('Para ${x['respuesta']?['para'] ?? x['datos']['telefono']}:\n${x['respuesta']['texto']}', style: estilo(14)),
                ),
              ],
              if (x['error'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${x['error']}', style: estilo(13.5, color: Colores.rojo))),
              const SizedBox(height: 8),
              Text('Datos', style: estilo(13, peso: FontWeight.w600)),
              SelectableText(enc.convert(x['datos']), style: estiloCodigo(12)),
              if (x['respuesta'] != null) ...[
                const SizedBox(height: 8),
                Text('Respuesta', style: estilo(13, peso: FontWeight.w600)),
                SelectableText(enc.convert(x['respuesta']), style: estiloCodigo(12)),
              ],
            ]),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Cerrar'))],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ajustes de Alegra
// ---------------------------------------------------------------------------
class _AjustesAlegra extends StatefulWidget {
  const _AjustesAlegra({required this.editar});
  final bool editar;
  @override
  State<_AjustesAlegra> createState() => _AjustesAlegraState();
}

class _AjustesAlegraState extends State<_AjustesAlegra> {
  late Future<List<Map<String, dynamic>>> _ajustes = _cargar();
  Map<String, dynamic>? _catalogos;
  String? _conexion;

  Future<List<Map<String, dynamic>>> _cargar() async => (await db.from('integracion_ajustes').select().order('clave', ascending: true)).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    funcionIntegraciones('catalogos').then((c) {
      if (mounted && c is Map && c['bodegas'] != null) setState(() => _catalogos = Map<String, dynamic>.from(c));
    }).catchError((_) {});
  }

  Future<void> _guardar(String clave, Object? valor) async {
    try {
      await db.rpc('guardar_ajuste_integracion', params: {'p_clave': clave, 'p_valor': valor});
      setState(() => _ajustes = _cargar());
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  List<Map<String, dynamic>>? _opciones(String clave) {
    final c = _catalogos;
    if (c == null) return null;
    final k = clave.contains('bodega') ? 'bodegas' : clave.contains('lista') ? 'listas' : clave.contains('impuesto') ? 'impuestos'
        : clave.contains('categoria_item') ? 'categorias' : clave.contains('numeracion') ? 'numeraciones' : null;
    return k == null ? null : (c[k] as List).cast<Map<String, dynamic>>();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Tarjeta(
        titulo: 'Conexión',
        accion: OutlinedButton.icon(
          onPressed: () async {
            setState(() => _conexion = 'Probando…');
            try {
              final r = await funcionIntegraciones('probar');
              setState(() => _conexion = '${r['mensaje']}');
            } catch (e) {
              setState(() => _conexion = '$e'.replaceFirst('Exception: ', ''));
            }
          },
          icon: const Icon(Icons.wifi_tethering),
          label: const Text('Probar conexión con Alegra'),
        ),
        child: Text(
            _conexion ??
                'El correo y el token de Alegra se guardan como secretos de Supabase (ALEGRA_USUARIO y ALEGRA_TOKEN), no en esta pantalla. '
                    'El token se genera en Alegra → Configuración → Integraciones con otros sistemas → API.',
            style: estilo(13.5, color: Colores.textoSuave)),
      ),
      const SizedBox(height: 16),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_ajustes),
        future: _ajustes,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          return Tarjeta(
            titulo: 'Ajustes',
            child: Column(children: [
              for (final a in s.data!.where((a) => !'${a['clave']}'.startsWith('whatsapp')))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text('${a['descripcion']}', style: estilo(14))),
                    SizedBox(width: 320, child: _editor(a)),
                  ]),
                ),
            ]),
          );
        },
      ),
    ]);
  }

  Widget _editor(Map<String, dynamic> a) {
    final clave = '${a['clave']}';
    final v = a['valor'];
    if (v is bool || clave.endsWith('_activo')) {
      return Align(alignment: Alignment.centerLeft, child: Switch(value: v == true, onChanged: widget.editar ? (x) => _guardar(clave, x) : null));
    }
    final ops = _opciones(clave);
    if (ops != null) {
      return DropdownButtonFormField<String?>(
        initialValue: ops.any((o) => o['id'] == v?.toString()) ? v?.toString() : null,
        items: [const DropdownMenuItem(value: null, child: Text('—')), for (final o in ops) DropdownMenuItem(value: o['id'] as String, child: Text('${o['nombre']} (${o['id']})'))],
        onChanged: widget.editar ? (x) => _guardar(clave, x) : null,
      );
    }
    return TextFormField(
      initialValue: v?.toString() ?? '',
      enabled: widget.editar,
      decoration: InputDecoration(hintText: _catalogos == null ? 'Id en Alegra' : null),
      onFieldSubmitted: (x) => _guardar(clave, x.trim().isEmpty ? null : (num.tryParse(x.trim()) != null && clave.startsWith('alerta') ? num.parse(x.trim()) : x.trim())),
    );
  }
}

// ---------------------------------------------------------------------------
// Enlaces: productos, materiales, terceros y empleados ↔ ids de Alegra
// ---------------------------------------------------------------------------
class _Enlaces extends StatefulWidget {
  const _Enlaces({required this.editar});
  final bool editar;
  @override
  State<_Enlaces> createState() => _EnlacesState();
}

class _EnlacesState extends State<_Enlaces> {
  var _tabla = 'skus';
  var _soloSin = true;
  late Future<List<Map<String, dynamic>>> _datos = _cargar();

  static const _tablas = {
    'skus': ('Productos', 'codigo', 'codigo'),
    'materiales': ('Telas e insumos', 'nombre', 'codigo'),
    'proveedores': ('Proveedores', 'nombre', 'nit'),
    'satelites': ('Satélites', 'nombre', 'nit'),
    'clientes': ('Clientes', 'nombre', 'nit'),
    'empleados': ('Empleados', 'nombres', 'documento'),
  };

  Future<List<Map<String, dynamic>>> _cargar() async {
    var q = db.from(_tabla).select(_tabla == 'clientes' ? '*' : '*');
    if (_soloSin) q = q.isFilter('alegra_id', null);
    return (await q.order(_tablas[_tabla]!.$2, ascending: true).limit(500)).cast<Map<String, dynamic>>();
  }

  Future<void> _enlazar(Map<String, dynamic> x) async {
    final (nombreTabla, campo, ident) = _tablas[_tabla]!;
    final nombre = _tabla == 'empleados' ? '${x['nombres']} ${x['apellidos']}' : '${x[campo]}';
    final id = await showDialog<String>(context: context, builder: (_) => _BuscarEnAlegra(tabla: _tabla, titulo: nombre, sugerencia: '${x[ident] ?? ''}', actual: x['alegra_id']));
    if (id == null) return;
    String? bodega;
    if (_tabla == 'clientes') {
      if (!mounted) return;
      bodega = await pedirTexto(context, titulo: 'Tienda propia', etiqueta: 'Bodega de Alegra de la tienda (vacío si es un cliente externo)',
          ayuda: 'Si es una tienda propia, los despachos se envían como traslado de bodega en vez de remisión.');
    }
    try {
      await db.rpc('enlazar_alegra', params: {'p_tabla': _tabla, 'p_id': x['id'], 'p_alegra': id, 'p_bodega': bodega});
      setState(() => _datos = _cargar());
      if (mounted) avisar(context, '$nombreTabla: $nombre enlazado con Alegra #$id');
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (_, campo, ident) = _tablas[_tabla]!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<String>(
          segments: [for (final e in _tablas.entries) ButtonSegment(value: e.key, label: Text(e.value.$1))],
          selected: {_tabla},
          onSelectionChanged: (s) => setState(() {
            _tabla = s.first;
            _datos = _cargar();
          }),
        ),
        FilterChip(label: const Text('Solo sin enlazar'), selected: _soloSin, onSelected: (v) => setState(() {
          _soloSin = v;
          _datos = _cargar();
        })),
      ]),
      const SizedBox(height: 8),
      Text(
          _tabla == 'skus'
              ? 'Las referencias nuevas se crean solas en Alegra al aprobar la ficha. Enlace aquí los productos que ya existían en Alegra.'
              : _tabla == 'empleados'
                  ? 'La nómina se enlaza sola por la cédula; enlace a mano solo si no coincide.'
                  : 'Busque el registro en Alegra por nombre o NIT.',
          style: estilo(13, color: Colores.textoSuave)),
      const SizedBox(height: 12),
      FutureBuilder<List<Map<String, dynamic>>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          return Tarjeta(
            titulo: '${_tablas[_tabla]!.$1} · ${s.data!.length}${_soloSin ? ' sin enlazar' : ''}',
            child: Tabla(
              columnas: [_tabla == 'empleados' ? 'Nombre' : 'Nombre / código', 'Identificación', 'Id en Alegra', if (_tabla == 'clientes') 'Tienda propia', ''],
              vacio: _soloSin ? 'Todo está enlazado.' : 'Sin registros.',
              filas: [
                for (final x in s.data!)
                  DataRow(cells: [
                    DataCell(Text(_tabla == 'empleados' ? '${x['codigo']} · ${x['nombres']} ${x['apellidos']}' : '${x[campo]}${_tabla == 'materiales' ? ' (${x['codigo']})' : ''}')),
                    DataCell(Text('${x[ident] ?? ''}')),
                    DataCell(Text('${x['alegra_id'] ?? '—'}', style: estiloCodigo(13))),
                    if (_tabla == 'clientes') DataCell(Text(x['alegra_bodega_id'] == null ? '—' : 'Bodega ${x['alegra_bodega_id']}')),
                    DataCell(widget.editar ? TextButton(onPressed: () => _enlazar(x), child: Text(x['alegra_id'] == null ? 'Enlazar' : 'Cambiar')) : const SizedBox()),
                  ]),
              ],
            ),
          );
        },
      ),
    ]);
  }
}

/// Busca en Alegra (productos o contactos) a través de la Edge Function, o deja escribir el id.
class _BuscarEnAlegra extends StatefulWidget {
  const _BuscarEnAlegra({required this.tabla, required this.titulo, required this.sugerencia, this.actual});
  final String tabla, titulo, sugerencia;
  final String? actual;
  @override
  State<_BuscarEnAlegra> createState() => _BuscarEnAlegraState();
}

class _BuscarEnAlegraState extends State<_BuscarEnAlegra> {
  late final _q = TextEditingController(text: widget.tabla == 'skus' ? '' : widget.sugerencia);
  late final _id = TextEditingController(text: widget.actual ?? '');
  List<Map<String, dynamic>> _res = [];
  String? _error;

  Future<void> _buscar() async {
    try {
      final r = await funcionIntegraciones(widget.tabla == 'skus' || widget.tabla == 'materiales' ? 'buscar_items' : 'buscar_contactos', {'texto': _q.text});
      setState(() {
        _res = (r as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Enlazar ${widget.titulo}'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: TextField(controller: _q, decoration: const InputDecoration(labelText: 'Buscar en Alegra (nombre, referencia o NIT)'), onSubmitted: (_) => _buscar())),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _buscar, child: const Text('Buscar')),
            ]),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: estilo(13, color: Colores.ambar))),
            if (_res.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView(shrinkWrap: true, children: [
                  for (final r in _res)
                    ListTile(
                      dense: true,
                      title: Text('${r['nombre']}'),
                      subtitle: Text('Id ${r['id']}${r['referencia'] != null ? ' · ref. ${r['referencia']}' : ''}${r['identificacion'] != null ? ' · ${r['identificacion']}' : ''}'),
                      onTap: () => Navigator.pop(context, '${r['id']}'),
                    ),
                ]),
              ),
            const SizedBox(height: 10),
            TextField(controller: _id, decoration: const InputDecoration(labelText: 'O escriba el id de Alegra')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, _id.text.trim()), child: const Text('Guardar')),
        ],
      );
}

// ---------------------------------------------------------------------------
// Nómina real
// ---------------------------------------------------------------------------
class _Nomina extends StatefulWidget {
  const _Nomina({required this.editar});
  final bool editar;
  @override
  State<_Nomina> createState() => _NominaState();
}

class _NominaState extends State<_Nomina> {
  late Future<List<dynamic>> _datos = _cargar();
  var _importando = false;

  Future<List<dynamic>> _cargar() => Future.wait([
        db.from('valor_minuto_real').select().order('desde', ascending: false).limit(24),
        db.from('costos_nomina').select().isFilter('empleado_id', null).order('desde', ascending: false).limit(50),
      ]);

  (DateTime, DateTime) _quincenaAnterior() {
    final h = DateTime.now();
    if (h.day > 15) return (DateTime(h.year, h.month, 1), DateTime(h.year, h.month, 15));
    final m = DateTime(h.year, h.month - 1, 1);
    return (DateTime(m.year, m.month, 16), DateTime(h.year, h.month, 0));
  }

  Future<void> _importar() async {
    final (d, h) = _quincenaAnterior();
    String iso(DateTime x) => x.toIso8601String().substring(0, 10);
    setState(() => _importando = true);
    try {
      final r = await funcionIntegraciones('importar_nomina', {'desde': iso(d), 'hasta': iso(h)});
      if (mounted) avisar(context, 'Nómina del ${Formato.fecha(d)} al ${Formato.fecha(h)}: ${r['filas']} empleados, valor del minuto ${Formato.cop(r['valor_minuto'] ?? 0)}');
    } catch (e) {
      if (mounted) avisar(context, '$e'.replaceFirst('Exception: ', ''), error: true);
    }
    if (mounted) {
      setState(() {
        _importando = false;
        _datos = _cargar();
      });
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final vm = (s.data![0] as List).cast<Map<String, dynamic>>();
          final sin = (s.data![1] as List).cast<Map<String, dynamic>>();
          final (d, h) = _quincenaAnterior();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tarjeta(
              titulo: 'Valor real del minuto por quincena',
              accion: widget.editar
                  ? FilledButton.icon(
                      onPressed: _importando ? null : _importar,
                      icon: const Icon(Icons.download),
                      label: Text('Importar nómina ${Formato.fecha(d)} – ${Formato.fecha(h)}'))
                  : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Costo total de la nómina de planta (salario, otros ingresos, aportes y prestaciones de los empleados con célula) dividido entre los minutos '
                    'de turno pagados. El costo de mano de obra de cada OP usa este valor en los días de esa quincena.',
                    style: estilo(13, color: Colores.textoSuave)),
                const SizedBox(height: 8),
                Tabla(
                  columnas: const ['Quincena', 'Empleados', 'Costo nómina', 'Minutos pagados', 'Valor del minuto'],
                  numericas: const {1, 2, 3, 4},
                  vacio: 'Aún no se ha importado nómina.',
                  filas: [
                    for (final v in vm)
                      DataRow(cells: [
                        DataCell(Text('${Formato.fecha(DateTime.parse('${v['desde']}T12:00:00Z'))} – ${Formato.fecha(DateTime.parse('${v['hasta']}T12:00:00Z'))}')),
                        DataCell(Text('${v['empleados']}')),
                        DataCell(Text(Formato.cop(v['costo_nomina']))),
                        DataCell(Text(Formato.numero(v['minutos'], decimales: 0))),
                        DataCell(Text(Formato.cop(v['valor_minuto']), style: estilo(14, peso: FontWeight.w700))),
                      ]),
                  ],
                ),
              ]),
            ),
            if (sin.isNotEmpty) ...[
              const SizedBox(height: 16),
              Tarjeta(
                titulo: 'En la nómina de Alegra pero no en la app (${sin.length})',
                child: Tabla(
                  columnas: const ['Cédula', 'Nombre', 'Quincena', 'Costo'],
                  numericas: const {3},
                  filas: [
                    for (final x in sin)
                      DataRow(cells: [
                        DataCell(Text('${x['identificacion']}')),
                        DataCell(Text('${x['nombre'] ?? ''}')),
                        DataCell(Text('${x['desde']} – ${x['hasta']}')),
                        DataCell(Text(Formato.cop(x['costo_total']))),
                      ]),
                  ],
                ),
              ),
            ],
          ]);
        },
      );
}

// ---------------------------------------------------------------------------
// WhatsApp
// ---------------------------------------------------------------------------
class _WhatsApp extends StatefulWidget {
  const _WhatsApp({required this.editar});
  final bool editar;
  @override
  State<_WhatsApp> createState() => _WhatsAppState();
}

class _WhatsAppState extends State<_WhatsApp> {
  late Future<List<dynamic>> _datos = _cargar();
  Future<List<dynamic>> _cargar() => Future.wait([
        db.from('whatsapp_destinatarios').select().order('nombre', ascending: true),
        db.from('integracion_ajustes').select().like('clave', 'whatsapp%'),
        db.from('integracion_ajustes').select().eq('clave', 'alerta_paro_largo_min'),
        db.from('satelites').select('id, nombre, whatsapp').eq('activo', true).order('nombre', ascending: true),
      ]);

  Future<void> _hacer(Future<void> Function() f) async {
    try {
      await f();
      setState(() => _datos = _cargar());
    } catch (e) {
      if (mounted) avisar(context, mensajeError(e), error: true);
    }
  }

  Future<void> _editar([Map<String, dynamic>? d]) async {
    final nombre = TextEditingController(text: d?['nombre'] ?? '');
    final tel = TextEditingController(text: d?['telefono'] ?? '');
    final tipos = {...((d?['tipos'] ?? []) as List).cast<String>()};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(d == null ? 'Nuevo destinatario' : 'Editar destinatario'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
              TextField(controller: tel, decoration: const InputDecoration(labelText: 'Celular (ej. 3001234567)')),
              const SizedBox(height: 10),
              Text('Recibe', style: estilo(13.5, peso: FontWeight.w600)),
              for (final e in tiposAlerta.entries)
                CheckboxListTile(
                  dense: true,
                  value: tipos.contains(e.key),
                  onChanged: (v) => set(() => v! ? tipos.add(e.key) : tipos.remove(e.key)),
                  title: Text(e.value),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final datos = {'nombre': nombre.text.trim(), 'telefono': tel.text.replaceAll(RegExp(r'[^0-9+]'), ''), 'tipos': tipos.toList()};
    await _hacer(() async => d == null
        ? await db.from('whatsapp_destinatarios').insert(datos)
        : await db.from('whatsapp_destinatarios').update(datos).eq('id', d['id']));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
        key: ObjectKey(_datos),
        future: _datos,
        builder: (_, s) {
          if (s.hasError) return Text(mensajeError(s.error!), style: estilo(14, color: Colores.rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final dest = (s.data![0] as List).cast<Map<String, dynamic>>();
          final aj = {for (final a in [...s.data![1] as List, ...s.data![2] as List]) a['clave']: a};
          final sats = (s.data![3] as List).cast<Map<String, dynamic>>();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tarjeta(
              titulo: 'Envío',
              child: Wrap(spacing: 24, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(value: aj['whatsapp_activo']?['valor'] == true,
                      onChanged: !widget.editar ? null : (v) => _hacer(() => db.rpc('guardar_ajuste_integracion', params: {'p_clave': 'whatsapp_activo', 'p_valor': v}))),
                  Text(aj['whatsapp_activo']?['valor'] == true ? 'Activo: los mensajes salen por WhatsApp' : 'Simulado: se registran pero no salen', style: estilo(14)),
                ]),
                Text('Horario: de ${aj['whatsapp_hora_inicio']?['valor']} a ${aj['whatsapp_hora_fin']?['valor']} h · Paro largo: ${aj['alerta_paro_largo_min']?['valor']} min',
                    style: estilo(14, color: Colores.textoSuave)),
              ]),
            ),
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Alertas internas',
              accion: widget.editar ? FilledButton.icon(onPressed: () => _editar(), icon: const Icon(Icons.add), label: const Text('Destinatario')) : null,
              child: Tabla(
                columnas: const ['Nombre', 'Celular', 'Recibe', ''],
                vacio: 'Nadie recibe alertas todavía.',
                filas: [
                  for (final d in dest)
                    DataRow(cells: [
                      DataCell(Text('${d['nombre']}')),
                      DataCell(Text('${d['telefono']}')),
                      DataCell(SizedBox(width: 420, child: Text([for (final t in (d['tipos'] as List)) tiposAlerta[t] ?? t].join(', '), maxLines: 2))),
                      DataCell(widget.editar
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _editar(d)),
                              IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: Colores.rojo),
                                  onPressed: () => _hacer(() => db.from('whatsapp_destinatarios').delete().eq('id', d['id']))),
                            ])
                          : const SizedBox()),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Tarjeta(
              titulo: 'Satélites',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Reciben aviso de cada remisión, recordatorio si se vence y aviso de pago. Se usa el WhatsApp de su ficha en Procesos externos.',
                    style: estilo(13, color: Colores.textoSuave)),
                for (final x in sats)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('• ${x['nombre']}: ${x['whatsapp'] ?? 'sin WhatsApp'}', style: estilo(14, color: x['whatsapp'] == null ? Colores.textoSuave : null)),
                  ),
              ]),
            ),
          ]);
        },
      );
}
