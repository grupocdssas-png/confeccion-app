import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/calculos/calidad.dart';
import '../../core/db_local/app_db.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/proveedores_sync.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../modulo/pantalla_modulo.dart';
import '../modulo/repositorio_modulo.dart';
import '../planta/escaner.dart';
import '../planta/indicador_sync.dart';
import '../planta/proveedores_planta.dart';
import 'repositorio_calidad.dart';

/// Tablet de calidad: inspector → paquete o juego → recibir, auditoría final por
/// muestreo, inspección en proceso, arreglos devueltos y entrega. Sin conexión.
class PantallaCalidad extends ConsumerStatefulWidget {
  const PantallaCalidad({super.key});
  @override
  ConsumerState<PantallaCalidad> createState() => _PantallaCalidadState();
}

class _Inspeccion {
  _Inspeccion(this.tipo, this.lote, this.muestra, this.acepta);
  final String tipo; // auditoria_final | en_proceso
  final int lote;
  int muestra;
  final int? acepta;
  final lineas = <LineaDefecto>[];
  final medidas = <String, double>{};
}

class _PantallaCalidadState extends ConsumerState<PantallaCalidad> {
  final _codigo = TextEditingController();
  EmpleadoLocal? _inspector;
  UnidadLocal? _unidad;
  AuditoriaLocal? _auditoria;
  List<DevolucionLocal> _devoluciones = [];
  List<DefectoLocal> _defectos = [];
  List<OperacionFicha> _ops = [];
  List<MedidaLocal> _fichaMedidas = [];
  _Inspeccion? _ins;
  String? _error;

  RepositorioCalidad get _repo => ref.read(repositorioCalidadProvider);
  RepositorioModulo get _modulo => ref.read(repositorioModuloProvider);
  EstacionLocal? get _estacion => ref.read(miEstacionProvider).value;

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  void _avisar(String t, {bool error = false}) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t, style: estilo(18, color: Colors.white)), backgroundColor: error ? Colores.rojo : Colores.texto));

  Future<void> _refrescar() async {
    if (_unidad == null) return;
    final u = await _modulo.unidadPorId(_unidad!.id);
    final a = await _repo.ultimaAuditoria(_unidad!.id);
    final d = await _repo.devoluciones(_unidad!.id);
    if (mounted) {
      setState(() {
        _unidad = u;
        _auditoria = a;
        _devoluciones = d;
      });
    }
  }

  Future<void> _buscarInspector(String entrada) async {
    final e = await ref.read(repoAsistenciaProvider).buscar(entrada);
    if (!mounted) return;
    setState(() {
      _inspector = e;
      _error = e == null ? 'No se encontró el carnet "$entrada".' : null;
      _codigo.clear();
    });
  }

  Future<void> _abrirUnidad(String leido) async {
    final u = await _modulo.unidadPorCodigo(leido);
    if (!mounted) return;
    if (u == null) {
      setState(() => _error = 'No se encontró "$leido". Escanee la etiqueta del paquete (PQ-…) o del juego (JG-…).');
      return;
    }
    final defectos = await _repo.defectos();
    final ops = await _repo.operacionesFicha(u.fichaId);
    final medidas = await _repo.medidas(u.fichaId, await _repo.tallaId(u.id));
    setState(() {
      _unidad = u;
      _defectos = defectos;
      _ops = ops;
      _fichaMedidas = medidas;
      _ins = null;
      _error = null;
      _codigo.clear();
    });
    await _refrescar();
  }

  bool get _enCalidad => _unidad != null && _unidad!.enProcesoAqui(_estacion?.proceso);

  Future<void> _empezar(String tipo) async {
    final u = _unidad!;
    if (tipo == 'auditoria_final') {
      final m = muestreo(await _repo.plan(), u.cantidad);
      setState(() => _ins = _Inspeccion(tipo, u.cantidad, m.muestra, m.acepta));
    } else {
      setState(() => _ins = _Inspeccion(tipo, u.cantidad, u.cantidad < 5 ? u.cantidad : 5, null));
    }
  }

  int get _defectuosas {
    final i = _ins!;
    final fuera = _fichaMedidas.any((m) => i.medidas[m.id] != null && medidaFuera(i.medidas[m.id]!, m.valor, m.tolerancia));
    return prendasConDefecto(i.lineas.map((l) => l.cantidad), medidaFueraDeTolerancia: fuera, yaAnotoMedida: i.lineas.any((l) => l.defecto.codigo == 'MED'));
  }

  bool get _aprobada => _ins!.acepta != null ? _defectuosas <= _ins!.acepta! : _defectuosas == 0;

  Future<void> _guardar() async {
    final i = _ins!;
    if (_defectuosas > i.muestra) {
      _avisar('Hay más prendas con defecto que revisadas (${i.muestra})', error: true);
      return;
    }
    var alcance = 'individual';
    if (i.tipo == 'auditoria_final' && !_aprobada) {
      final a = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('Rechazado: ¿qué se devuelve?', style: estilo(24, peso: FontWeight.w700)),
          content: Text('$_defectuosas prendas con defecto de ${i.muestra} revisadas (acepta ${i.acepta}).', style: estilo(18)),
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(d, 'individual'), child: Text('Solo las prendas malas', style: estilo(18))),
            FilledButton(onPressed: () => Navigator.pop(d, 'grupal'), child: Text('Todo el ${_unidad!.tipo} a revisión', style: estilo(18, color: Colors.white))),
          ],
        ),
      );
      if (a == null) return;
      alcance = a;
    }
    try {
      final r = await _repo.inspeccionar(
        unidad: _unidad!,
        tipo: i.tipo,
        inspectorId: _inspector!.id,
        lineas: i.lineas,
        medidas: i.medidas,
        fichaMedidas: _fichaMedidas,
        muestraEnProceso: i.tipo == 'en_proceso' ? i.muestra : null,
        alcance: alcance,
      );
      _avisar(r.resultado == 'aprobado'
          ? '${_unidad!.codigo}: ${i.tipo == 'auditoria_final' ? 'auditoría aprobada' : 'inspección sin defectos'}'
          : '${_unidad!.codigo}: ${r.defectuosas} con defecto. Las devoluciones salen al sincronizar.',
          error: r.resultado != 'aprobado');
      setState(() => _ins = null);
      await _refrescar();
    } catch (e) {
      _avisar('$e', error: true);
    }
  }

  Future<void> _recibir() async {
    await _modulo.recibir(_unidad!, empleadoId: _inspector?.id);
    _avisar('${_unidad!.codigo} recibido en calidad');
    await _refrescar();
  }

  Future<void> _entregar() async {
    final u = _unidad!;
    final r = await showDialog<({int buenas, int segundas})>(context: context, builder: (_) => DialogoEntrega(u: u, buenas: u.cantidad));
    if (r == null) return;
    await _modulo.entregar(u, buenas: r.buenas, segundas: r.segundas, faltantes: u.cantidad - r.buenas - r.segundas, empleadoId: _inspector?.id);
    _avisar('${u.codigo} entregado: ${r.buenas} buenas${r.segundas > 0 ? ', ${r.segundas} segundas' : ''}');
    setState(() => _unidad = null);
  }

  Future<void> _cerrarDevolucion(DevolucionLocal d) async {
    var arregladas = d.cantidad;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Arreglo de ${d.defecto}', style: estilo(24, peso: FontWeight.w700)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Volvieron ${d.cantidad}${d.operacion != null ? ' · ${d.operacion}' : ''}${d.empleado != null ? ' · ${d.empleado}' : ''}', style: estilo(17)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text('Quedaron bien', style: estilo(20))),
              IconButton(iconSize: 36, onPressed: arregladas > 0 ? () => set(() => arregladas--) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$arregladas', style: estilo(30, peso: FontWeight.w700)),
              IconButton(iconSize: 36, onPressed: arregladas < d.cantidad ? () => set(() => arregladas++) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
            Text('Segundas: ${d.cantidad - arregladas}', style: estilo(18, color: d.cantidad - arregladas > 0 ? Colores.ambar : null)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Cancelar', style: estilo(18))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('Recibir arreglo', style: estilo(18, color: Colors.white))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _repo.cerrarDevolucion(d, reprocesadas: arregladas, segundas: d.cantidad - arregladas, inspectorId: _inspector?.id);
    _avisar('Arreglo recibido');
    await _refrescar();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(temaModuloProvider).value ?? PaletaModulo.negra;
    ref.watch(resumenBandejaProvider);
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
        appBar: const EncabezadoPlanta(titulo: 'Calidad', atras: true),
        body: DefaultTextStyle(
          style: estilo(16, color: p.texto),
          child: Column(children: [
            const AvisosPlanta(),
            _barraInspector(p),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: _contenido(p))),
            if (_ins != null) _barraResultado(p),
          ]),
        ),
      ),
    );
  }

  Widget _barraInspector(PaletaModulo p) => Container(
        color: p.barra,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          Icon(Icons.verified_outlined, color: Colores.deProceso('calidad'), size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text(_inspector == null ? 'Sin inspector' : '${_inspector!.nombres} ${_inspector!.apellidos}',
                style: estilo(20, peso: FontWeight.w600, color: p.texto), overflow: TextOverflow.ellipsis),
          ),
          if (_inspector != null)
            TextButton(
              onPressed: () => setState(() {
                _inspector = null;
                _unidad = null;
                _ins = null;
              }),
              child: Text('Cambiar inspector', style: estilo(16, color: p.acento)),
            ),
          IconButton(
            tooltip: p.oscuro ? 'Fondo claro' : 'Fondo oscuro',
            iconSize: 28,
            icon: Icon(p.oscuro ? Icons.light_mode_outlined : Icons.dark_mode_outlined, color: p.suave),
            onPressed: () => cambiarTemaModulo(ref, p.oscuro),
          ),
        ]),
      );

  Widget _tarjeta(PaletaModulo p, Widget child, {Color? borde}) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: p.tarjeta, borderRadius: BorderRadius.circular(16), border: Border.all(color: borde ?? p.borde, width: borde == null ? 1 : 3)),
        child: child,
      );

  Widget _entrada(PaletaModulo p, {required String titulo, required String ayuda, required String hint, required Future<void> Function(String) onCodigo}) =>
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
    if (_inspector == null) {
      return _entrada(p, titulo: 'Escanee su carnet', ayuda: 'Las inspecciones quedan a nombre del inspector.', hint: 'o escriba el código', onCodigo: _buscarInspector);
    }
    final u = _unidad;
    if (u == null) {
      return _entrada(p, titulo: 'Escanee el paquete o juego', ayuda: 'Para auditar, inspeccionar en el módulo o recibir un arreglo.',
          hint: 'o escriba el código', onCodigo: _abrirUnidad);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _cabecera(p, u),
      const SizedBox(height: 16),
      if (_ins != null) ..._formulario(p) else ..._estado(p, u),
    ]);
  }

  Widget _cabecera(PaletaModulo p, UnidadLocal u) => _tarjeta(
        p,
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${u.codigo} · ${u.cantidad} prendas', style: estiloCodigo(20, color: p.texto)),
              const SizedBox(height: 4),
              Text('${u.op} · ${u.referencia} · ${u.combinacion ?? u.color}', style: estilo(16, color: p.suave)),
              const SizedBox(height: 4),
              Text('${Colores.nombreProceso(u.proceso)} · ${switch (u.estadoServidor) { 'en_espera' => 'esperando', 'en_proceso' => 'en proceso', final x => x }}',
                  style: estilo(16, color: p.suave)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(color: p.texto, borderRadius: BorderRadius.circular(10)),
            child: Text(u.talla, style: estilo(24, peso: FontWeight.w700, color: p.fondo)),
          ),
        ]),
      );

  Widget _boton(PaletaModulo p, String t, IconData i, VoidCallback? f, {Color? color}) => SizedBox(
        height: 80,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: color ?? p.boton, foregroundColor: Colors.white),
          onPressed: f,
          icon: Icon(i, size: 32),
          label: Text(t, style: estilo(22, peso: FontWeight.w700, color: Colors.white)),
        ),
      );

  List<Widget> _estado(PaletaModulo p, UnidadLocal u) {
    final proceso = _estacion?.proceso;
    final a = _auditoria;
    return [
      if (a != null)
        _tarjeta(
          p,
          Row(children: [
            Icon(a.aprobada ? Icons.check_circle : Icons.cancel, color: a.aprobada ? p.verde : p.rojo, size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                  '${a.aprobada ? 'Auditoría aprobada' : 'Rechazado en auditoría'} · ${a.defectuosas} de ${a.muestra} con defecto · ${Formato.hora(a.hora)}'
                  '${a.pendiente ? ' · sin subir' : ''}',
                  style: estilo(19, peso: FontWeight.w600, color: a.aprobada ? p.verde : p.rojo)),
            ),
          ]),
          borde: a.aprobada ? null : p.rojo,
        ),
      if (_devoluciones.isNotEmpty) ...[
        const SizedBox(height: 16),
        _tarjeta(
          p,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Devuelto para arreglo', style: estilo(22, peso: FontWeight.w700, color: p.ambar)),
            const SizedBox(height: 8),
            for (final d in _devoluciones)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(
                    child: Text('${d.cantidad} · ${d.defecto}${d.operacion != null ? ' · ${d.operacion}' : ''}${d.empleado != null ? ' · ${d.empleado}' : ''}'
                        '${d.alcance == 'grupal' ? ' · todo el ${u.tipo}' : ''}${d.reprocesadas > 0 ? ' · ${d.reprocesadas} reprocesadas' : ''}',
                        style: estilo(18, color: p.texto)),
                  ),
                  OutlinedButton(onPressed: () => _cerrarDevolucion(d), child: Text('Recibir arreglo', style: estilo(17, color: p.texto))),
                ]),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      if (u.proceso == proceso && !_enCalidad && u.estadoLocal != 'entregada')
        _boton(p, 'Recibir ${u.cantidad} prendas en calidad', Icons.move_to_inbox_outlined, _recibir),
      if (_enCalidad) ...[
        _boton(p, 'Auditoría final', Icons.fact_check_outlined, () => _empezar('auditoria_final')),
        const SizedBox(height: 12),
        _boton(p, 'Entregar', Icons.outbox_outlined, a != null && a.aprobada ? _entregar : null, color: Colores.deProceso('calidad')),
        if (a == null || !a.aprobada)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Para entregar necesita una auditoría final aprobada.', style: estilo(16, color: p.suave), textAlign: TextAlign.center),
          ),
      ],
      if (u.estadoLocal == 'entregada') Text('Ya se entregó desde esta tablet.', style: estilo(18, color: p.suave)),
      if (!_enCalidad && u.estadoServidor != 'terminado') ...[
        const SizedBox(height: 12),
        _boton(p, 'Inspección en proceso', Icons.search, () => _empezar('en_proceso'), color: p.oscuro ? const Color(0xFF2A2E33) : Colores.textoSuave),
      ],
      const SizedBox(height: 12),
      OutlinedButton(onPressed: () => setState(() => _unidad = null), child: Text('Escanear otro', style: estilo(20, color: p.texto))),
    ];
  }

  List<Widget> _formulario(PaletaModulo p) {
    final i = _ins!;
    return [
      _tarjeta(
        p,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(i.tipo == 'auditoria_final' ? 'Auditoría final' : 'Inspección en proceso', style: estilo(26, peso: FontWeight.w700, color: p.texto)),
          const SizedBox(height: 6),
          if (i.tipo == 'auditoria_final')
            Text('Lote de ${i.lote}: revise ${i.muestra} prendas al azar. Se aprueba con ${i.acepta} o menos con defecto.', style: estilo(19, color: p.suave))
          else
            Row(children: [
              Expanded(child: Text('Prendas revisadas', style: estilo(19, color: p.suave))),
              IconButton(iconSize: 34, onPressed: i.muestra > 1 ? () => setState(() => i.muestra--) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('${i.muestra}', style: estilo(28, peso: FontWeight.w700, color: p.texto)),
              IconButton(iconSize: 34, onPressed: i.muestra < i.lote ? () => setState(() => i.muestra++) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
        ]),
      ),
      const SizedBox(height: 16),
      Text('Toque el defecto que encuentre', style: estilo(18, peso: FontWeight.w600, color: p.suave)),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 4.6,
        children: [
          for (final d in _defectos)
            OutlinedButton(
              style: OutlinedButton.styleFrom(side: BorderSide(color: d.severidad == 'critico' ? p.rojo : p.borde, width: 2), alignment: Alignment.centerLeft),
              onPressed: () => _agregarDefecto(d),
              child: Text(d.nombre, style: estilo(17, peso: FontWeight.w600, color: p.texto), maxLines: 2),
            ),
        ],
      ),
      if (i.lineas.isNotEmpty) ...[
        const SizedBox(height: 16),
        _tarjeta(
          p,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final l in i.lineas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.defecto.nombre, style: estilo(19, peso: FontWeight.w600, color: p.texto)),
                      InkWell(
                        onTap: () => _elegirOperacion(l),
                        child: Text(l.operacion == null ? 'Operación: toque para elegir' : '${Colores.nombreProceso(l.operacion!.proceso)} · ${l.operacion!.nombre}',
                            style: estilo(16, color: l.operacion == null ? p.ambar : p.acento)),
                      ),
                    ]),
                  ),
                  IconButton(iconSize: 32, onPressed: () => setState(() => l.cantidad > 1 ? l.cantidad-- : i.lineas.remove(l)), icon: const Icon(Icons.remove_circle_outline)),
                  Text('${l.cantidad}', style: estilo(26, peso: FontWeight.w700, color: p.texto)),
                  IconButton(iconSize: 32, onPressed: () => setState(() => l.cantidad++), icon: const Icon(Icons.add_circle_outline)),
                ]),
              ),
          ]),
        ),
      ],
      if (_fichaMedidas.isNotEmpty) ...[
        const SizedBox(height: 16),
        _tarjeta(
          p,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Medidas de una prenda (talla ${_unidad!.talla}, en cm)', style: estilo(19, peso: FontWeight.w600, color: p.texto)),
            for (final m in _fichaMedidas) _filaMedida(p, m),
          ]),
        ),
      ],
      const SizedBox(height: 90),
    ];
  }

  Widget _filaMedida(PaletaModulo p, MedidaLocal m) {
    final v = _ins!.medidas[m.id];
    final fuera = v != null && medidaFuera(v, m.valor, m.tolerancia);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        Expanded(
          child: Text('${m.punto}\n${Formato.numero(m.valor, decimales: 1)} ± ${Formato.numero(m.tolerancia, decimales: 1)}',
              style: estilo(17, color: p.texto)),
        ),
        SizedBox(
          width: 130,
          child: TextField(
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: estilo(22, color: p.texto),
            decoration: const InputDecoration(hintText: 'cm'),
            onChanged: (t) => setState(() {
              final x = double.tryParse(t.replaceAll(',', '.'));
              x == null ? _ins!.medidas.remove(m.id) : _ins!.medidas[m.id] = x;
            }),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 34,
          child: v == null ? null : Icon(fuera ? Icons.cancel : Icons.check_circle, color: fuera ? p.rojo : p.verde, size: 30),
        ),
      ]),
    );
  }

  Future<void> _agregarDefecto(DefectoLocal d) async {
    final l = LineaDefecto(d);
    setState(() => _ins!.lineas.add(l));
    if (d.codigo != 'MED') await _elegirOperacion(l);
  }

  Future<void> _elegirOperacion(LineaDefecto l) async {
    final sugeridas = l.defecto.proceso == null ? _ops : _ops.where((o) => o.proceso == l.defecto.proceso).toList();
    final otras = _ops.where((o) => !sugeridas.contains(o)).toList();
    final r = await showDialog<OperacionFicha?>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('¿En qué operación?', style: estilo(24, peso: FontWeight.w700)),
        children: [
          for (final o in [...sugeridas, ...otras])
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              onPressed: () => Navigator.pop(c, o),
              child: Text('${o.nombre} · ${Colores.nombreProceso(o.proceso)}', style: estilo(19)),
            ),
          SimpleDialogOption(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14), onPressed: () => Navigator.pop(c), child: Text('No sé', style: estilo(19, color: Colores.textoSuave))),
        ],
      ),
    );
    if (mounted) setState(() => l.operacion = r);
  }

  Widget _barraResultado(PaletaModulo p) {
    final ok = _aprobada;
    return Container(
      color: p.barra,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Expanded(
            child: Text(
              '$_defectuosas con defecto de ${_ins!.muestra}${_ins!.acepta != null ? ' · acepta ${_ins!.acepta}' : ''}\n'
              '${ok ? (_ins!.tipo == 'auditoria_final' ? 'APROBADO' : 'SIN DEFECTOS') : (_ins!.tipo == 'auditoria_final' ? 'RECHAZADO' : 'CON DEFECTOS: vuelven al operario')}',
              style: estilo(20, peso: FontWeight.w700, color: ok ? p.verde : p.rojo),
            ),
          ),
          TextButton(onPressed: () => setState(() => _ins = null), child: Text('Cancelar', style: estilo(18, color: p.suave))),
          const SizedBox(width: 8),
          SizedBox(
            height: 72,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.boton, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 28)),
              onPressed: _guardar,
              child: Text('Guardar', style: estilo(22, peso: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ]),
      ),
    );
  }
}
