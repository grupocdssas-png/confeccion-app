import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../planta/escaner.dart';
import '../planta/indicador_sync.dart';
import 'repositorio_bodega.dart';

/// Campo grande para escanear con la cámara o digitar un código.
class CampoEscaneo extends StatefulWidget {
  const CampoEscaneo({super.key, required this.titulo, required this.ayuda, required this.onCodigo});
  final String titulo, ayuda;
  final Future<void> Function(String codigo) onCodigo;
  @override
  State<CampoEscaneo> createState() => _CampoEscaneoState();
}

class _CampoEscaneoState extends State<CampoEscaneo> {
  final _texto = TextEditingController();

  Future<void> _enviar(String v) async {
    if (v.trim().isEmpty) return;
    _texto.clear();
    await widget.onCodigo(v);
  }

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: SizedBox(
            height: 72,
            child: FilledButton.icon(
              onPressed: () async {
                final v = await escanearQr(context, titulo: widget.titulo);
                if (v != null) await _enviar(v);
              },
              icon: const Icon(Icons.qr_code_scanner, size: 32),
              label: Text(widget.titulo, style: estilo(20, peso: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 220,
          child: TextField(
            controller: _texto,
            style: estiloCodigo(20),
            textCapitalization: TextCapitalization.characters,
            onSubmitted: _enviar,
            decoration: InputDecoration(hintText: widget.ayuda, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 22)),
          ),
        ),
      ]);
}

void _aviso(BuildContext context, String texto, {bool error = false}) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(texto, style: estilo(17, color: Colors.white)), backgroundColor: error ? Colores.rojo : Colores.texto));

Future<String?> pedirMotivo(BuildContext context, String titulo, String ayuda) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(titulo),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: ayuda)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isNotEmpty), child: const Text('Aceptar')),
      ],
    ),
  );
  return ok == true ? c.text.trim() : null;
}

// =====================================================================
// Inicio de bodega
// =====================================================================
class PantallaBodega extends StatelessWidget {
  const PantallaBodega({super.key});
  @override
  Widget build(BuildContext context) {
    Widget item(String t, String sub, IconData i, String ruta) => Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push(ruta),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Icon(i, size: 44),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t, style: estilo(22, peso: FontWeight.w600)),
                    Text(sub, style: estilo(16, color: Colores.textoSuave)),
                  ]),
                ),
                const Icon(Icons.chevron_right, size: 32),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: const EncabezadoPlanta(titulo: 'Bodega', atras: true),
      body: Column(children: [
        const AvisosPlanta(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            item('Consultar rollo', 'Ver saldo, trasladar de ubicación y reimprimir etiqueta', Icons.search, '/bodega/rollo'),
            const SizedBox(height: 14),
            item('Conteo físico', 'Escanear rollos e insumos de un conteo abierto', Icons.fact_check_outlined, '/bodega/conteo'),
            const SizedBox(height: 14),
            item('Impresora y cola', 'Etiquetas pendientes, reintentar, imprimir prueba', Icons.print_outlined, '/bodega/impresion'),
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================
// Consultar / trasladar / reimprimir rollo
// =====================================================================
class PantallaRollo extends ConsumerStatefulWidget {
  const PantallaRollo({super.key});
  @override
  ConsumerState<PantallaRollo> createState() => _PantallaRolloState();
}

class _PantallaRolloState extends ConsumerState<PantallaRollo> {
  RolloLocal? _rollo;
  String? _pendiente;
  String? _error;
  var _esperandoDestino = false;

  Future<void> _leer(String codigo) async {
    final repo = ref.read(repoBodegaProvider);
    if (_esperandoDestino && _rollo != null) {
      final u = await repo.ubicacionPorCodigo(codigo);
      if (!mounted) return;
      if (u == null) return setState(() => _error = 'Escanee una etiqueta de ubicación (UB-…). Leído: $codigo');
      await repo.trasladar(_rollo!, u);
      if (!mounted) return;
      _aviso(context, '${_rollo!.codigo} → ${u['codigo']}. Se enviará al servidor.');
      setState(() {
        _esperandoDestino = false;
        _pendiente = u['codigo'] as String;
        _error = null;
      });
      return;
    }
    final r = await repo.rolloPorCodigo(codigo);
    final pendiente = r == null ? null : await repo.trasladoPendiente(r.id);
    if (!mounted) return;
    setState(() {
      _rollo = r;
      _pendiente = pendiente;
      _error = r == null ? 'No se encontró el rollo "$codigo" en esta tablet (puede estar agotado o aún no sincronizado).' : null;
    });
  }

  Future<void> _reimprimir() async {
    final motivo = await pedirMotivo(context, 'Reimprimir etiqueta', 'Motivo (ej.: etiqueta dañada)');
    if (motivo == null || !mounted) return;
    try {
      await ref.read(repoBodegaProvider).imprimirRollo(_rollo!, reimpresion: true, motivo: motivo);
      if (mounted) _aviso(context, 'Etiqueta en cola de impresión');
    } catch (e) {
      if (mounted) _aviso(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _rollo;
    return Scaffold(
      appBar: const EncabezadoPlanta(titulo: 'Consultar rollo', atras: true),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        CampoEscaneo(
          titulo: _esperandoDestino ? 'Escanear ubicación destino' : 'Escanear rollo',
          ayuda: _esperandoDestino ? 'UB-…' : 'TL-…',
          onCodigo: _leer,
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: estilo(17, color: Colores.rojo))),
        const SizedBox(height: 20),
        if (r != null)
          Tarjeta(
            padding: const EdgeInsets.all(22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(r.codigo, style: estiloCodigo(30)),
                const SizedBox(width: 12),
                if (r.esRetazo) const Pastilla('Retazo', color: Colores.ambar, grande: true),
                const Spacer(),
                Pastilla(const {'disponible': 'Disponible', 'reservado': 'Reservado', 'en_corte': 'En corte', 'retazo': 'Retazo'}[r.estado] ?? r.estado,
                    color: r.estado == 'disponible' ? Colores.verde : Colores.ambar, grande: true),
              ]),
              const SizedBox(height: 8),
              Text(r.material, style: estilo(20, peso: FontWeight.w600)),
              const SizedBox(height: 14),
              _dato('Color', r.color),
              _dato('Lote / tono', '${r.lote}  ·  ${r.tono ?? '—'}'),
              _dato('Ancho real', '${Formato.numero(r.ancho, decimales: 1)} cm'),
              _dato('Saldo', '${Formato.dos(r.metros)} m   ·   ${Formato.dos(r.kilos)} kg'),
              _dato('Ubicación', '${r.ubicacion}  (${r.bodega})'),
              if (_pendiente != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Pastilla('Traslado a $_pendiente pendiente de envío', color: Colores.ambar, icono: Icons.schedule, grande: true),
                ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 64,
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() {
                        _esperandoDestino = true;
                        _error = null;
                      }),
                      icon: const Icon(Icons.move_down),
                      label: const Text('Trasladar'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 64,
                    child: OutlinedButton.icon(onPressed: _reimprimir, icon: const Icon(Icons.print), label: const Text('Reimprimir')),
                  ),
                ),
              ]),
              if (_esperandoDestino)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Ahora escanee la etiqueta de la ubicación donde queda el rollo.',
                      style: estilo(17, peso: FontWeight.w600, color: Colores.deProceso('corte'))),
                ),
            ]),
          ),
      ]),
    );
  }

  Widget _dato(String t, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 140, child: Text(t, style: estilo(17, color: Colores.textoSuave))),
          Expanded(child: Text(v, style: estilo(18, peso: FontWeight.w600))),
        ]),
      );
}

// =====================================================================
// Conteo físico
// =====================================================================
final _conteosProvider = StreamProvider((ref) => ref.watch(repoBodegaProvider).conteosAbiertos());

class PantallaConteos extends ConsumerWidget {
  const PantallaConteos({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conteos = ref.watch(_conteosProvider).value ?? const [];
    return Scaffold(
      appBar: const EncabezadoPlanta(titulo: 'Conteo físico', atras: true),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (conteos.isEmpty)
          Tarjeta(child: Text('No hay conteos abiertos. Se abren desde el panel web (Inventarios → Conteos).', style: estilo(18))),
        for (final c in conteos)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                title: Text('${c['consecutivo']}', style: estiloCodigo(22)),
                subtitle: Text('${c['bodega']}${c['ubicacion'] == null ? '' : ' · ${c['ubicacion']}'} · ${c['alcance']}',
                    style: estilo(17, color: Colores.textoSuave)),
                trailing: const Icon(Icons.chevron_right, size: 32),
                onTap: () => context.push('/bodega/conteo/${c['id']}'),
              ),
            ),
          ),
      ]),
    );
  }
}

class PantallaConteo extends ConsumerStatefulWidget {
  const PantallaConteo({super.key, required this.conteoId});
  final String conteoId;
  @override
  ConsumerState<PantallaConteo> createState() => _PantallaConteoState();
}

class _PantallaConteoState extends ConsumerState<PantallaConteo> {
  Map<String, Object?>? _ubicacion;
  late final Stream<List<Map<String, Object?>>> _registros = ref.read(repoBodegaProvider).registrosConteo(widget.conteoId);

  Future<void> _leer(String codigo) async {
    final repo = ref.read(repoBodegaProvider);
    final u = await repo.ubicacionPorCodigo(codigo);
    if (u != null) {
      setState(() => _ubicacion = u);
      if (mounted) _aviso(context, 'Contando en ${u['codigo']}');
      return;
    }
    final r = await repo.rolloPorCodigo(codigo);
    if (!mounted) return;
    if (r == null) return _aviso(context, 'Código no reconocido: $codigo', error: true);
    final nuevo = await repo.contarRollo(widget.conteoId, r,
        ubicacionId: _ubicacion?['id'] as String?, ubicacionCodigo: _ubicacion?['codigo'] as String?);
    if (mounted) _aviso(context, nuevo ? '${r.codigo} contado' : '${r.codigo} ya estaba contado', error: !nuevo);
  }

  Future<void> _insumo() async {
    final repo = ref.read(repoBodegaProvider);
    final res = await showDialog<(Map<String, Object?>, Map<String, Object?>?, double)>(
      context: context,
      builder: (_) => _DialogoInsumo(repo: repo),
    );
    if (res == null) return;
    await repo.contarInsumo(widget.conteoId, res.$1, res.$2, res.$3,
        ubicacionId: _ubicacion?['id'] as String?, ubicacionCodigo: _ubicacion?['codigo'] as String?);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const EncabezadoPlanta(titulo: 'Conteo', atras: true),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Tarjeta(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_ubicacion == null ? 'Escanee primero la ubicación y luego los rollos que hay en ella.' : 'Ubicación actual: ${_ubicacion!['codigo']}',
                  style: estilo(18, peso: FontWeight.w600)),
              const SizedBox(height: 14),
              CampoEscaneo(titulo: 'Escanear', ayuda: 'UB-… o TL-…', onCodigo: _leer),
              const SizedBox(height: 12),
              SizedBox(height: 60, child: OutlinedButton.icon(onPressed: _insumo, icon: const Icon(Icons.add), label: const Text('Contar insumo'))),
            ]),
          ),
          const SizedBox(height: 18),
          StreamBuilder(
            stream: _registros,
            builder: (_, s) {
              final regs = s.data ?? const [];
              return Tarjeta(
                titulo: 'Contado en esta tablet (${regs.length})',
                child: Column(children: [
                  for (final r in regs) _FilaRegistro(r),
                ]),
              );
            },
          ),
        ]),
      );
}

class _FilaRegistro extends StatelessWidget {
  const _FilaRegistro(this.r);
  final Map<String, Object?> r;
  @override
  Widget build(BuildContext context) {
    final resumen = r['resumen'] as String? ?? '{}';
    final d = Map<String, Object?>.from(jsonDecodeSeguro(resumen));
    final estado = r['estado'];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${d['codigo']}  ${d['cantidad'] != null ? '× ${Formato.numero(d['cantidad'] as num, decimales: 0)} ${d['unidad']}' : ''}',
          style: estiloCodigo(18)),
      subtitle: Text('${d['detalle'] ?? ''} · ${d['ubicacion'] ?? ''}${d['otra_ubicacion'] == true ? ' (otra ubicación)' : ''}'
          '${estado == 'rechazado' ? '\n${r['motivo']}' : ''}', style: estilo(15, color: estado == 'rechazado' ? Colores.rojo : Colores.textoSuave)),
      trailing: Pastilla(estado == 'sincronizado' ? 'Enviado' : estado == 'rechazado' ? 'Rechazado' : 'Pendiente',
          color: estado == 'sincronizado' ? Colores.verde : estado == 'rechazado' ? Colores.rojo : Colores.ambar),
    );
  }
}

Map<String, dynamic> jsonDecodeSeguro(String s) {
  try {
    return Map<String, dynamic>.from(jsonDecode(s) as Map);
  } catch (_) {
    return {};
  }
}

class _DialogoInsumo extends StatefulWidget {
  const _DialogoInsumo({required this.repo});
  final RepositorioBodega repo;
  @override
  State<_DialogoInsumo> createState() => _DialogoInsumoState();
}

class _DialogoInsumoState extends State<_DialogoInsumo> {
  var _lista = <Map<String, Object?>>[];
  var _colores = <Map<String, Object?>>[];
  Map<String, Object?>? _material;
  Map<String, Object?>? _color;
  final _cantidad = TextEditingController();

  @override
  void initState() {
    super.initState();
    _buscar('');
    widget.repo.colores().then((c) => setState(() => _colores = c));
  }

  Future<void> _buscar(String f) async {
    final l = await widget.repo.insumos(f);
    if (mounted) setState(() => _lista = l);
  }

  @override
  Widget build(BuildContext context) {
    final cantidad = double.tryParse(_cantidad.text.replaceAll('.', '').replaceAll(',', '.'));
    final requiereColor = _material?['maneja_color'] == 1;
    return AlertDialog(
      title: const Text('Contar insumo'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_material == null) ...[
            TextField(decoration: const InputDecoration(hintText: 'Buscar insumo', prefixIcon: Icon(Icons.search)), onChanged: _buscar),
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              child: ListView(children: [
                for (final m in _lista)
                  ListTile(title: Text('${m['nombre']}'), subtitle: Text('${m['codigo']} · ${m['unidad']}'), onTap: () => setState(() => _material = m)),
              ]),
            ),
          ] else ...[
            Text('${_material!['nombre']}', style: estilo(18, peso: FontWeight.w600)),
            if (requiereColor) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<Map<String, Object?>>(
                initialValue: _color,
                decoration: const InputDecoration(labelText: 'Color'),
                items: [for (final c in _colores) DropdownMenuItem(value: c, child: Text('${c['nombre']}'))],
                onChanged: (c) => setState(() => _color = c),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _cantidad,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: estilo(24),
              decoration: InputDecoration(labelText: 'Cantidad contada (${_material!['unidad']})'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _material != null && cantidad != null && cantidad >= 0 && (!requiereColor || _color != null)
              ? () => Navigator.pop(context, (_material!, _color, cantidad))
              : null,
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}

// =====================================================================
// Impresora y cola
// =====================================================================
final _colaProvider = StreamProvider((ref) => ref.watch(repoBodegaProvider).cola());

class PantallaColaImpresion extends ConsumerWidget {
  const PantallaColaImpresion({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cola = ref.watch(_colaProvider).value ?? const [];
    final repo = ref.read(repoBodegaProvider);
    return Scaffold(
      appBar: const EncabezadoPlanta(titulo: 'Impresora', atras: true),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        FutureBuilder(
          future: repo.impresoraDeLaEstacion(),
          builder: (_, s) => Tarjeta(
            titulo: 'Impresora de esta estación',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(s.data == null ? 'Sin impresora asignada' : '${s.data!.nombre} · ${s.data!.ip}:${s.data!.puerto}', style: estilo(18)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 60,
                    child: OutlinedButton.icon(
                      onPressed: s.data == null
                          ? null
                          : () async {
                              try {
                                await repo.imprimirPrueba();
                                if (context.mounted) _aviso(context, 'Prueba enviada a la cola');
                              } catch (e) {
                                if (context.mounted) _aviso(context, '$e', error: true);
                              }
                            },
                      icon: const Icon(Icons.print),
                      label: const Text('Imprimir prueba'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 60,
                    child: OutlinedButton.icon(
                      onPressed: () => unawaited(ref.read(colaImpresionProvider).reintentarYa()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar ahora'),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 18),
        Tarjeta(
          titulo: 'Cola (${cola.where((t) => t['estado'] == 'pendiente').length} pendientes)',
          child: Column(children: [
            if (cola.isEmpty) Text('No hay etiquetas en la cola.', style: estilo(17, color: Colores.textoSuave)),
            for (final t in cola)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${t['codigo']}${t['es_reimpresion'] == 1 ? '  (reimpresión)' : ''}', style: estiloCodigo(18)),
                subtitle: Text(
                  [
                    '${t['impresora_nombre']}',
                    Formato.hora(DateTime.parse(t['creado_en'] as String)),
                    if ((t['intentos'] as int? ?? 0) > 0) '${t['intentos']} intentos',
                    if (t['error'] != null && t['estado'] == 'pendiente') '${t['error']}',
                  ].join(' · '),
                  style: estilo(15, color: t['error'] != null && t['estado'] == 'pendiente' ? Colores.rojo : Colores.textoSuave),
                ),
                trailing: t['estado'] == 'enviado'
                    ? const Pastilla('Impresa', color: Colores.verde, icono: Icons.check)
                    : const Pastilla('Pendiente', color: Colores.ambar, icono: Icons.schedule),
              ),
          ]),
        ),
      ]),
    );
  }
}
