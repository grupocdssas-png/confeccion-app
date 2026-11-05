import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db_local/app_db.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/proveedores_sync.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../planta/escaner.dart';
import '../planta/indicador_sync.dart';
import '../planta/proveedores_planta.dart';
import 'repositorio_modulo.dart';

/// Colores de la tablet del módulo: oscuro (predeterminado) o claro.
class PaletaModulo {
  const PaletaModulo._(this.oscuro, this.fondo, this.barra, this.tarjeta, this.borde, this.texto, this.suave, this.acento, this.boton,
      this.verde, this.ambar, this.rojo);
  final bool oscuro;
  final Color fondo, barra, tarjeta, borde, texto, suave, acento, boton, verde, ambar, rojo;

  static const negra = PaletaModulo._(true, Color(0xFF0F1113), Color(0xFF16191C), Color(0xFF1A1D21), Color(0xFF2A2E33), Color(0xFFECECE8),
      Color(0xFFA3A6AD), Color(0xFF4C8DD6), Color(0xFF1F5FA8), Color(0xFF6FCF97), Color(0xFFE8B04B), Color(0xFFF08A82));
  static const clara = PaletaModulo._(false, Colores.fondo, Colors.white, Colors.white, Colores.borde, Colores.texto, Colores.textoSuave,
      Color(0xFF1F5FA8), Color(0xFF1F5FA8), Colores.verde, Color(0xFF9A6A08), Colores.rojo);

  Color semaforo(double? v) => v == null ? suave : v >= 100 ? verde : v >= 85 ? ambar : rojo;
}

/// Ajuste por tablet (se guarda en la base local; no sube al servidor).
final temaModuloProvider = StreamProvider<PaletaModulo>((ref) => ref
    .watch(powerSyncProvider)
    .watch("SELECT valor FROM ajustes_locales WHERE id = 'tema_modulo'")
    .map((rs) => rs.isNotEmpty && rs.first['valor'] == 'claro' ? PaletaModulo.clara : PaletaModulo.negra));

Future<void> cambiarTemaModulo(WidgetRef ref, bool claro) => ref.read(powerSyncProvider).execute(
    "INSERT OR REPLACE INTO ajustes_locales (id, valor) VALUES ('tema_modulo', ?)", [claro ? 'claro' : 'oscuro']);

/// Tablet del módulo (y de cualquier estación con proceso): operario → paquete o juego → operaciones → contador → entregar.
class PantallaModulo extends ConsumerStatefulWidget {
  const PantallaModulo({super.key});
  @override
  ConsumerState<PantallaModulo> createState() => _PantallaModuloState();
}

class _PantallaModuloState extends ConsumerState<PantallaModulo> {
  final _codigo = TextEditingController();
  EmpleadoLocal? _operario;
  UnidadLocal? _unidad;
  List<OperacionLocal> _ops = [];
  List<OperacionLocal> _elegidas = [];
  Map<String, ({int hechas, int reprocesos})> _avance = {};
  List<MarcacionLocal> _ultimas = [];
  EficienciasOperario _ef = const EficienciasOperario();
  List<UnidadLocal> _enCelula = [];
  String? _error;
  String? _ultimaOp;

  RepositorioModulo get _repo => ref.read(repositorioModuloProvider);
  EstacionLocal? get _estacion => ref.read(miEstacionProvider).value;
  bool get _marcaOperaciones => _estacion?.tipo == 'modulo';

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  void _avisar(String t, {bool error = false}) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t, style: estilo(18, color: Colors.white)), backgroundColor: error ? Colores.rojo : Colores.texto));

  Future<void> _refrescar() async {
    final e = _estacion;
    final enCelula = await _repo.unidadesEnCelula(e?.celulaId, e?.proceso);
    if (_operario != null) {
      _ultimas = await _repo.ultimas(_operario!.id);
      _ef = await _repo.eficiencias(_operario!.id);
    }
    if (_unidad != null) {
      _unidad = await _repo.unidadPorId(_unidad!.id);
      _avance = await _repo.avance(_unidad!.id);
    }
    if (mounted) setState(() => _enCelula = enCelula);
  }

  // ---------- operario ----------
  Future<void> _buscarOperario(String entrada) async {
    final e = await ref.read(repoAsistenciaProvider).buscar(entrada);
    if (!mounted) return;
    if (e == null) {
      setState(() => _error = 'No se encontró el carnet "$entrada".');
      return;
    }
    setState(() {
      _operario = e;
      _error = null;
      _codigo.clear();
    });
    await _refrescar();
  }

  // ---------- paquete / juego ----------
  Future<void> _abrirUnidad(String leido) async {
    final u = await _repo.unidadPorCodigo(leido);
    if (!mounted) return;
    if (u == null) {
      setState(() => _error = 'No se encontró "$leido". Escanee la etiqueta del paquete (PQ-…) o del juego (JG-…).');
      return;
    }
    await _usarUnidad(u);
  }

  Future<void> _usarUnidad(UnidadLocal u) async {
    final ops = _marcaOperaciones ? await _repo.operaciones(u, _estacion?.proceso) : <OperacionLocal>[];
    final guardadas = await _opsGuardadas(u);
    setState(() {
      _unidad = u;
      _ops = ops;
      _elegidas = ops.where((o) => guardadas.contains(o.id)).toList();
      _error = null;
      _codigo.clear();
    });
    await _refrescar();
  }

  String get _claveOps => 'ops_${_operario?.id}_${_unidad?.fichaId}';
  Future<Set<String>> _opsGuardadas(UnidadLocal u) async {
    final r = await ref.read(powerSyncProvider).getOptional('SELECT valor FROM ajustes_locales WHERE id = ?', ['ops_${_operario?.id}_${u.fichaId}']);
    return r == null ? {} : {for (final x in jsonDecode(r['valor'] as String) as List) '$x'};
  }

  Future<void> _guardarOps(List<OperacionLocal> ops) async {
    await ref.read(powerSyncProvider).execute('INSERT OR REPLACE INTO ajustes_locales (id, valor) VALUES (?, ?)', [_claveOps, jsonEncode(ops.map((o) => o.id).toList())]);
    setState(() => _elegidas = ops);
  }

  Future<void> _recibir() async {
    await _repo.recibir(_unidad!, empleadoId: _operario?.id);
    _avisar('${_unidad!.codigo} recibido en ${_estacion?.codigo ?? 'el módulo'}');
    await _refrescar();
  }

  Future<void> _marcar(OperacionLocal op, {bool reproceso = false}) async {
    final hechas = _avance[op.id]?.hechas ?? 0;
    if (!reproceso && hechas + op.unidadesMarcacion > _unidad!.cantidad) {
      _avisar('${op.nombre} ya está completa en este ${_unidad!.tipo} (${_unidad!.cantidad})', error: true);
      return;
    }
    await _repo.marcar(empleadoId: _operario!.id, unidad: _unidad!, op: op, reproceso: reproceso);
    _ultimaOp = op.id;
    await _refrescar();
  }

  Future<void> _entregar(PaletaModulo p) async {
    final u = _unidad!;
    final contadora = _ops.where((o) => o.contadora).firstOrNull;
    final sugeridas = contadora != null && _avance[contadora.id] != null ? _avance[contadora.id]!.hechas : u.cantidad;
    final r = await showDialog<({int buenas, int segundas})>(context: context, builder: (_) => _DialogoEntrega(u: u, buenas: sugeridas.clamp(0, u.cantidad)));
    if (r == null) return;
    await _repo.entregar(u, buenas: r.buenas, segundas: r.segundas, faltantes: u.cantidad - r.buenas - r.segundas, empleadoId: _operario?.id);
    _avisar('${u.codigo} entregado: ${r.buenas} buenas${r.segundas > 0 ? ', ${r.segundas} segundas' : ''}');
    setState(() {
      _unidad = null;
      _ops = [];
      _elegidas = [];
    });
    await _refrescar();
  }

  Future<void> _anular(MarcacionLocal m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Anular marcación'),
        content: Text('${m.operacion} · ${Formato.hora(m.hora)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Anular')),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.anularMarcacion(m, _operario!.id, 'Anulada por el operario');
    await _refrescar();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(temaModuloProvider).value ?? PaletaModulo.negra;
    ref.watch(resumenBandejaProvider); // refresca cuando cambia la bandeja
    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: p.fondo,
        colorScheme: Theme.of(context).colorScheme.copyWith(brightness: p.oscuro ? Brightness.dark : Brightness.light, surface: p.tarjeta, onSurface: p.texto),
        dialogTheme: DialogThemeData(backgroundColor: p.tarjeta),
        textTheme: Theme.of(context).textTheme.apply(bodyColor: p.texto, displayColor: p.texto),
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(fillColor: p.tarjeta),
      ),
      child: Scaffold(
        backgroundColor: p.fondo,
        appBar: EncabezadoPlanta(titulo: _marcaOperaciones ? 'Marcar operaciones' : 'Recibir y entregar', atras: true),
        body: DefaultTextStyle(
          style: estilo(16, color: p.texto),
          child: Column(children: [
            const AvisosPlanta(),
            _barraOperario(p),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: _contenido(p))),
            if (_operario != null && _unidad != null && _unidad!.enProcesoAqui(_estacion?.proceso)) _acciones(p),
          ]),
        ),
      ),
    );
  }

  Widget _barraOperario(PaletaModulo p) => Container(
        color: p.barra,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: p.borde,
            child: Text(_operario == null ? '?' : _iniciales(_operario!), style: estilo(18, peso: FontWeight.w700, color: p.texto)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(_operario == null ? 'Sin operario' : '${_operario!.nombres} ${_operario!.apellidos}',
                style: estilo(20, peso: FontWeight.w600, color: p.texto), overflow: TextOverflow.ellipsis),
          ),
          if (_operario != null)
            TextButton(
              onPressed: () => setState(() {
                _operario = null;
                _unidad = null;
              }),
              child: Text('Cambiar operario', style: estilo(16, color: p.acento)),
            ),
          IconButton(
            tooltip: p.oscuro ? 'Fondo claro' : 'Fondo oscuro',
            iconSize: 28,
            icon: Icon(p.oscuro ? Icons.light_mode_outlined : Icons.dark_mode_outlined, color: p.suave),
            onPressed: () => cambiarTemaModulo(ref, p.oscuro),
          ),
        ]),
      );

  String _iniciales(EmpleadoLocal e) => '${(e.nombres ?? ' ').trim().characters.firstOrNull ?? ''}${(e.apellidos ?? ' ').trim().characters.firstOrNull ?? ''}'.toUpperCase();

  Widget _tarjeta(PaletaModulo p, Widget child, {EdgeInsets padding = const EdgeInsets.all(18), Color? borde}) => Container(
        padding: padding,
        decoration: BoxDecoration(color: p.tarjeta, borderRadius: BorderRadius.circular(16), border: Border.all(color: borde ?? p.borde, width: borde == null ? 1 : 3)),
        child: child,
      );

  Widget _entradaCodigo(PaletaModulo p, {required String titulo, required String ayuda, required String hint, required Future<void> Function(String) onCodigo}) =>
      _tarjeta(
        p,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(titulo, style: estilo(28, peso: FontWeight.w700, color: p.texto)),
          const SizedBox(height: 6),
          Text(ayuda, style: estilo(17, color: p.suave)),
          const SizedBox(height: 20),
          SizedBox(
            height: 96,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: p.boton, foregroundColor: Colors.white),
              onPressed: () async {
                final v = await escanearQr(context, titulo: titulo);
                if (v != null) await onCodigo(v);
              },
              icon: const Icon(Icons.qr_code_scanner, size: 40),
              label: Text('Escanear', style: estilo(26, peso: FontWeight.w700, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _codigo,
                style: estilo(22, color: p.texto),
                decoration: InputDecoration(hintText: hint, hintStyle: estilo(20, color: p.suave)),
                onSubmitted: onCodigo,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(height: 64, child: OutlinedButton(onPressed: () => onCodigo(_codigo.text), child: Text('Buscar', style: estilo(20, color: p.texto)))),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: estilo(17, peso: FontWeight.w600, color: p.rojo))),
        ]),
      );

  Widget _contenido(PaletaModulo p) {
    if (_operario == null) {
      return _entradaCodigo(p, titulo: 'Escanee su carnet', ayuda: 'Para marcar a su nombre las operaciones que haga.', hint: 'o escriba el código (E001, OPR-0001)',
          onCodigo: _buscarOperario);
    }
    final u = _unidad;
    if (u == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _entradaCodigo(p, titulo: 'Escanee el paquete o juego', ayuda: 'La etiqueta que viene de corte (PQ-…) o el juego armado (JG-…).',
            hint: 'o escriba el código', onCodigo: _abrirUnidad),
        if (_enCelula.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('En este módulo', style: estilo(18, peso: FontWeight.w600, color: p.suave)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final x in _enCelula)
              ActionChip(
                backgroundColor: p.tarjeta,
                side: BorderSide(color: p.borde),
                padding: const EdgeInsets.all(12),
                label: Text('${x.codigo} · ${x.talla} · ${x.cantidad}', style: estiloCodigo(18, color: p.texto)),
                onPressed: () => _usarUnidad(x),
              ),
          ]),
        ],
        const SizedBox(height: 20),
        _eficiencias(p),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _cabeceraUnidad(p, u),
      const SizedBox(height: 16),
      ..._cuerpoUnidad(p, u),
    ]);
  }

  Widget _cabeceraUnidad(PaletaModulo p, UnidadLocal u) => _tarjeta(
        p,
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${u.codigo}${u.tipo == 'juego' ? ' · juego de ${u.cantidad}' : ' · ${u.cantidad} prendas'}', style: estiloCodigo(20, color: p.texto)),
              const SizedBox(height: 4),
              Text('${u.op} · ${u.referencia}${u.lote != null ? ' · lote ${u.lote}' : ''}${u.combinacion != null ? ' · ${u.combinacion}' : ''}',
                  style: estilo(16, color: p.suave)),
            ]),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: u.colorHex == null ? p.borde : Color(int.parse('FF${u.colorHex!.replaceFirst('#', '')}', radix: 16)),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: p.suave),
            ),
          ),
          const SizedBox(width: 8),
          Text(u.color, style: estilo(18, peso: FontWeight.w600, color: p.texto)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(color: p.texto, borderRadius: BorderRadius.circular(10)),
            child: Text(u.talla, style: estilo(24, peso: FontWeight.w700, color: p.fondo)),
          ),
        ]),
      );

  List<Widget> _cuerpoUnidad(PaletaModulo p, UnidadLocal u) {
    final proceso = _estacion?.proceso;
    if (u.estadoLocal == 'entregada') {
      return [_mensaje(p, 'Este ${u.tipo} ya se entregó desde esta tablet.', p.suave), _volver(p)];
    }
    if (!u.enProcesoAqui(proceso)) {
      if (u.proceso != proceso) {
        return [
          _mensaje(p, 'Este ${u.tipo} va para ${Colores.nombreProceso(u.proceso)}, no para ${Colores.nombreProceso(proceso)}. No se puede recibir aquí.', p.rojo),
          _volver(p),
        ];
      }
      return [
        _tarjeta(
          p,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('¿Recibir en ${_estacion?.codigo ?? 'este módulo'}?', style: estilo(26, peso: FontWeight.w700, color: p.texto)),
            const SizedBox(height: 6),
            Text('Cuente las prendas: deben ser ${u.cantidad}. Si no coinciden, avise al supervisor antes de recibir.', style: estilo(17, color: p.suave)),
            const SizedBox(height: 18),
            SizedBox(
              height: 80,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: p.boton, foregroundColor: Colors.white),
                onPressed: _recibir,
                child: Text('Recibir ${u.cantidad} prendas', style: estilo(24, peso: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ]),
        ),
        _volver(p),
      ];
    }
    if (!_marcaOperaciones) {
      return [_mensaje(p, 'En proceso aquí. Cuando termine, pulse Entregar.', p.suave)];
    }
    if (_elegidas.isEmpty) return [_elegirOperaciones(p)];
    return [
      if (_elegidas.length == 1) _contadorUno(p, _elegidas.first) else _contadorVarios(p),
      const SizedBox(height: 16),
      _eficiencias(p),
      const SizedBox(height: 16),
      _listaUltimas(p),
    ];
  }

  Widget _mensaje(PaletaModulo p, String t, Color c) => _tarjeta(p, Text(t, style: estilo(20, peso: FontWeight.w600, color: c)));
  Widget _volver(PaletaModulo p) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: OutlinedButton(onPressed: () => setState(() => _unidad = null), child: Text('Escanear otro', style: estilo(20, color: p.texto))),
      );

  Widget _elegirOperaciones(PaletaModulo p) {
    final sel = {for (final o in _elegidas) o.id};
    return StatefulBuilder(builder: (context, set) {
      return _tarjeta(
        p,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('¿Qué operaciones hace en este ${_unidad!.tipo}?', style: estilo(24, peso: FontWeight.w700, color: p.texto)),
          const SizedBox(height: 4),
          Text('Se recuerdan para los siguientes de la misma referencia.', style: estilo(16, color: p.suave)),
          const SizedBox(height: 12),
          if (_ops.isEmpty) Text('La ficha no tiene operaciones de ${Colores.nombreProceso(_estacion?.proceso)}.', style: estilo(18, color: p.rojo)),
          for (final o in _ops)
            CheckboxListTile(
              value: sel.contains(o.id),
              onChanged: (v) => set(() => v! ? sel.add(o.id) : sel.remove(o.id)),
              title: Text(o.titulo, style: estilo(21, peso: FontWeight.w600, color: p.texto)),
              subtitle: Text('${o.codigo} · SAM ${Formato.numero(o.sam, decimales: 3)}${o.contadora ? ' · contadora' : ''}', style: estilo(15, color: p.suave)),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.boton, foregroundColor: Colors.white),
              onPressed: sel.isEmpty ? null : () => _guardarOps(_ops.where((o) => sel.contains(o.id)).toList()),
              child: Text('Empezar', style: estilo(22, peso: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ]),
      );
    });
  }

  Widget _contadorUno(PaletaModulo p, OperacionLocal o) {
    final a = _avance[o.id] ?? (hechas: 0, reprocesos: 0);
    final total = _unidad!.cantidad;
    final completa = a.hechas >= total;
    return _tarjeta(
      p,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: Text(o.titulo, style: estilo(30, peso: FontWeight.w700, color: p.texto))),
          Text('${o.codigo} · SAM ${Formato.numero(o.sam, decimales: 2)}', style: estiloCodigo(16, color: p.suave)),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Semantics(
            button: true,
            label: 'Sumar ${o.unidadesMarcacion}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _marcar(o),
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.fondo, border: Border.all(color: completa ? p.verde : p.acento, width: 10)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('${a.hechas}', style: estilo(96, peso: FontWeight.w700, color: p.texto, alto: 1)),
                  Text('de $total', style: estilo(18, color: p.suave)),
                  const SizedBox(height: 8),
                  Text('Tocar +${o.unidadesMarcacion}', style: estilo(22, peso: FontWeight.w600, color: p.acento)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Faltan', style: estilo(16, color: p.suave)),
              Text('${(total - a.hechas).clamp(0, total)}', style: estilo(44, peso: FontWeight.w700, color: p.texto)),
              const SizedBox(height: 10),
              if (_ultimas.isNotEmpty && _ultimas.first.reales != null) ...[
                Text('Última prenda', style: estilo(16, color: p.suave)),
                Text('${_mmss(_ultimas.first.reales!)} de ${_mmss(_ultimas.first.esperados)}',
                    style: estilo(24, peso: FontWeight.w600, color: p.semaforo(_ultimas.first.eficiencia))),
                const SizedBox(height: 14),
              ],
              SizedBox(
                height: 64,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(side: BorderSide(color: p.rojo, width: 2), foregroundColor: p.rojo),
                  onPressed: () => _marcar(o, reproceso: true),
                  child: Text('Reproceso · ${a.reprocesos}', style: estilo(20, peso: FontWeight.w600, color: p.rojo)),
                ),
              ),
            ]),
          ),
        ]),
      ]),
    );
  }

  Widget _contadorVarios(PaletaModulo p) {
    final total = _unidad!.cantidad;
    return LayoutBuilder(builder: (context, c) {
      final ancho = (c.maxWidth - 14) / 2;
      return Wrap(spacing: 14, runSpacing: 14, children: [
        for (final o in _elegidas)
          SizedBox(
            width: ancho,
            child: () {
              final a = _avance[o.id] ?? (hechas: 0, reprocesos: 0);
              final completa = a.hechas >= total;
              return _tarjeta(
                p,
                padding: const EdgeInsets.all(10),
                borde: completa ? p.verde : (_ultimaOp == o.id ? p.acento : null),
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _marcar(o),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(o.titulo, style: estilo(22, peso: FontWeight.w700, color: p.texto), maxLines: 2),
                        Text('${o.codigo} · SAM ${Formato.numero(o.sam, decimales: 2)}', style: estiloCodigo(14, color: p.suave)),
                        const SizedBox(height: 6),
                        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                          Text('${a.hechas}', style: estilo(64, peso: FontWeight.w700, color: p.texto, alto: 1)),
                          const SizedBox(width: 8),
                          Text('de $total', style: estilo(18, color: p.suave)),
                          const Spacer(),
                          Text('+${o.unidadesMarcacion}', style: estilo(22, peso: FontWeight.w700, color: p.acento)),
                        ]),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(value: total == 0 ? 0 : (a.hechas / total).clamp(0, 1), minHeight: 8,
                              backgroundColor: p.borde, color: completa ? p.verde : p.acento),
                        ),
                        const SizedBox(height: 6),
                        Text('Faltan ${(total - a.hechas).clamp(0, total)}', style: estilo(16, color: p.suave)),
                      ]),
                    ),
                  ),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(side: BorderSide(color: p.rojo, width: 2), foregroundColor: p.rojo),
                      onPressed: () => _marcar(o, reproceso: true),
                      child: Text('Reproceso · ${a.reprocesos}', style: estilo(17, peso: FontWeight.w600, color: p.rojo)),
                    ),
                  ),
                ]),
              );
            }(),
          ),
      ]);
    });
  }

  Widget _eficiencias(PaletaModulo p) {
    Widget caja(String t, double? v, String pie) => Expanded(
          child: _tarjeta(
            p,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: estilo(14, color: p.suave)),
              Text(v == null ? '—' : '${Formato.numero(v, decimales: 0)} %', style: estilo(36, peso: FontWeight.w700, color: p.semaforo(v))),
              Text(pie, style: estilo(13, color: p.suave)),
            ]),
          ),
        );
    return Row(children: [
      caja('EFICIENCIA · HORA', _ef.hora, 'meta 100 %'),
      const SizedBox(width: 12),
      caja('EFICIENCIA · HOY', _ef.hoy, '${_ef.unidadesHoy} unidades'),
      const SizedBox(width: 12),
      caja('EFICIENCIA · MES', _ef.mes, '${_ef.reprocesosHoy} reprocesos hoy'),
    ]);
  }

  Widget _listaUltimas(PaletaModulo p) => _tarjeta(
        p,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            for (final (t, f) in const [('OPERACIÓN', 3), ('ESPERADO', 2), ('REAL', 2), ('EFICIENCIA', 2), ('HORA', 2), ('', 1)])
              Expanded(flex: f, child: Text(t, style: estilo(13, color: p.suave))),
          ]),
          if (_ultimas.isEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Todavía no ha marcado hoy.', style: estilo(16, color: p.suave))),
          for (final m in _ultimas)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                Expanded(flex: 3, child: Text('${m.operacion}${m.reproceso ? ' (reproceso)' : ''}', style: estilo(16, color: m.reproceso ? p.rojo : p.texto), overflow: TextOverflow.ellipsis)),
                Expanded(flex: 2, child: Text(_mmss(m.esperados), style: estilo(16, color: p.suave))),
                Expanded(flex: 2, child: Text(m.reales == null ? '—' : _mmss(m.reales!), style: estilo(16, color: p.texto))),
                Expanded(flex: 2, child: Text(m.eficiencia == null ? '—' : '${Formato.numero(m.eficiencia!, decimales: 0)} %',
                    style: estilo(16, peso: FontWeight.w600, color: p.semaforo(m.eficiencia)))),
                Expanded(flex: 2, child: Text(Formato.hora(m.hora), style: estilo(16, color: p.suave))),
                Expanded(
                  flex: 1,
                  child: IconButton(tooltip: 'Anular', icon: Icon(Icons.undo, color: p.suave), onPressed: () => _anular(m)),
                ),
              ]),
            ),
        ]),
      );

  Widget _acciones(PaletaModulo p) {
    Widget boton(IconData i, String t, VoidCallback? f) => SizedBox(
          width: 150,
          child: TextButton(
            onPressed: f,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, size: 34, color: p.texto),
              const SizedBox(height: 4),
              Text(t, style: estilo(15, color: p.texto), textAlign: TextAlign.center),
            ]),
          ),
        );
    return Container(
      color: p.barra,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      child: SafeArea(
        top: false,
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          boton(Icons.qr_code_scanner, 'Cambiar paquete', () => setState(() => _unidad = null)),
          if (_marcaOperaciones) boton(Icons.checklist, 'Mis operaciones', () => setState(() => _elegidas = [])),
          if (_marcaOperaciones && _elegidas.length == 1)
            SizedBox(
              width: 96,
              height: 96,
              child: FilledButton(
                style: FilledButton.styleFrom(shape: const CircleBorder(), backgroundColor: p.boton, foregroundColor: Colors.white, padding: EdgeInsets.zero),
                onPressed: () => _marcar(_elegidas.first),
                child: const Icon(Icons.add, size: 48),
              ),
            ),
          boton(Icons.outbox_outlined, 'Entregar', () => _entregar(p)),
          boton(Icons.home_outlined, 'Inicio', () => context.go('/')),
        ]),
      ),
    );
  }

  String _mmss(double minutos) {
    final s = (minutos * 60).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _DialogoEntrega extends StatefulWidget {
  const _DialogoEntrega({required this.u, required this.buenas});
  final UnidadLocal u;
  final int buenas;
  @override
  State<_DialogoEntrega> createState() => _DialogoEntregaState();
}

class _DialogoEntregaState extends State<_DialogoEntrega> {
  late int _buenas = widget.buenas;
  var _segundas = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.u.cantidad;
    final faltan = total - _buenas - _segundas;
    Widget fila(String t, int v, ValueChanged<int> f, {int? max}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(t, style: estilo(22, peso: FontWeight.w600))),
            IconButton.outlined(iconSize: 32, onPressed: v > 0 ? () => f(v - 1) : null, icon: const Icon(Icons.remove)),
            SizedBox(width: 80, child: Text('$v', textAlign: TextAlign.center, style: estilo(34, peso: FontWeight.w700))),
            IconButton.outlined(iconSize: 32, onPressed: max == null || v < max ? () => f(v + 1) : null, icon: const Icon(Icons.add)),
          ]),
        );
    return AlertDialog(
      title: Text('Entregar ${widget.u.codigo}', style: estilo(24, peso: FontWeight.w700)),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Entraron $total prendas. Lo que no sea buena ni segunda queda como faltante.', style: estilo(17)),
          const SizedBox(height: 10),
          fila('Buenas', _buenas, (v) => setState(() => _buenas = v), max: total - _segundas),
          fila('Segundas', _segundas, (v) => setState(() => _segundas = v), max: total - _buenas),
          const Divider(),
          Row(children: [
            Expanded(child: Text('Faltantes', style: estilo(22, peso: FontWeight.w600))),
            Text('$faltan', style: estilo(34, peso: FontWeight.w700, color: faltan > 0 ? Colores.rojo : null)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancelar', style: estilo(18))),
        FilledButton(
          onPressed: faltan < 0 ? null : () => Navigator.pop(context, (buenas: _buenas, segundas: _segundas)),
          child: Text('Entregar', style: estilo(18, peso: FontWeight.w700, color: Colors.white)),
        ),
      ],
    );
  }
}
