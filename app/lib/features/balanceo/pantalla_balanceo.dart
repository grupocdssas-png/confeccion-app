import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/calculos/balanceo.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, avisar, mensajeError, numeroCo;

final _baseBalanceoProvider = FutureProvider.autoDispose((ref) async {
  final r = await Future.wait<dynamic>([
    db.from('ordenes_produccion').select('id, consecutivo, cantidad_total, ficha_version_id, fecha_entrega_plan, referencias(codigo, nombre), op_procesos(proceso, estado, buenas)')
        .inFilter('estado', ['planeada', 'en_proceso']).order('consecutivo', ascending: true),
    db.from('celulas').select('id, codigo, nombre, proceso, eficiencia_planeada, turno_id').eq('activo', true).eq('proceso', 'confeccion').order('codigo', ascending: true),
  ]);
  final ops = [for (final o in r[0] as List) if ((o['op_procesos'] as List).any((p) => p['proceso'] == 'confeccion' && p['estado'] != 'terminado')) o];
  return {'ops': ops, 'celulas': r[1]};
});

typedef _Clave = ({String op, String celula});

final _contextoBalanceoProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, _Clave>((ref, k) async {
  final op = await db.from('ordenes_produccion').select('id, consecutivo, cantidad_total, ficha_version_id, referencias(codigo, nombre), op_procesos(proceso, buenas)')
      .eq('id', k.op).single();
  final r = await Future.wait<dynamic>([
    db.from('ficha_operaciones').select('id, secuencia, sam, repeticiones, agrega_minutos_sam, es_contadora, operaciones(codigo, nombre), tipos_maquina(codigo, nombre)')
        .eq('ficha_id', op['ficha_version_id']).eq('proceso', 'confeccion').order('secuencia', ascending: true),
    db.from('empleados').select('id, codigo, nombres, apellidos').eq('celula_id', k.celula).eq('activo', true).order('codigo', ascending: true),
    db.from('balanceos').select('*, balanceo_puestos(*, balanceo_asignaciones(ficha_operacion_id, fraccion))')
        .eq('op_id', k.op).eq('celula_id', k.celula).order('version', ascending: false).limit(1),
    db.from('celulas').select('id, codigo, nombre, eficiencia_planeada, turno_id').eq('id', k.celula).single(),
  ]);
  final celula = r[3] as Map<String, dynamic>;
  final minTurno = celula['turno_id'] == null ? 480 : await db.rpc('minutos_turno', params: {'p_turno': celula['turno_id']});
  return {'op': op, 'operaciones': r[0], 'empleados': r[1], 'ultimo': (r[2] as List).firstOrNull, 'celula': celula, 'minutos_turno': minTurno};
});

class _PuestoEd {
  _PuestoEd(this.numero, {this.empleado, Map<String, double>? fracciones}) : fracciones = fracciones ?? {};
  int numero;
  String? empleado;
  final Map<String, double> fracciones; // ficha_operacion_id → fracción
}

class PantallaBalanceo extends ConsumerStatefulWidget {
  const PantallaBalanceo({super.key});
  @override
  ConsumerState<PantallaBalanceo> createState() => _PantallaBalanceoState();
}

class _PantallaBalanceoState extends ConsumerState<PantallaBalanceo> {
  String? _op, _celula;

  @override
  Widget build(BuildContext context) {
    final base = ref.watch(_baseBalanceoProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Balanceo de célula', subtitulo: 'Reparte las operaciones de confección entre los operarios del módulo; al publicarlo, cada tablet propone a cada operario sus operaciones'),
      base.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (b) => Tarjeta(
          child: Wrap(spacing: 16, runSpacing: 12, children: [
            SizedBox(
              width: 420,
              child: DropdownButtonFormField<String>(
                initialValue: _op,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'OP', isDense: true),
                items: [
                  for (final o in b['ops'] as List)
                    DropdownMenuItem(value: o['id'] as String, child: Text('${o['consecutivo']} · ${o['referencias']['codigo']} ${o['referencias']['nombre']} · ${o['cantidad_total']}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _op = v),
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                initialValue: _celula,
                decoration: const InputDecoration(labelText: 'Célula', isDense: true),
                items: [for (final c in b['celulas'] as List) DropdownMenuItem(value: c['id'] as String, child: Text('${c['codigo']} · ${c['nombre']}'))],
                onChanged: (v) => setState(() => _celula = v),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      if (_op != null && _celula != null)
        ref.watch(_contextoBalanceoProvider((op: _op!, celula: _celula!))).when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
              data: (k) => _Editor(key: ValueKey('$_op$_celula${k['ultimo']?['id']}${k['ultimo']?['estado']}'), k: k, clave: (op: _op!, celula: _celula!)),
            ),
    ]);
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, required this.k, required this.clave});
  final Map<String, dynamic> k;
  final _Clave clave;
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  Map<String, dynamic> get k => widget.k;
  List<Map<String, dynamic>> get ops => (k['operaciones'] as List).cast();
  List<Map<String, dynamic>> get empleados => (k['empleados'] as List).cast();
  late int operarios;
  late double eficiencia, minutosTurno, tolerancia;
  String? contadora;
  final puestos = <_PuestoEd>[];
  var sucio = false;

  double minutos(Map<String, dynamic> o) => (o['sam'] as num).toDouble() * (o['repeticiones'] as num).toDouble();
  String nombre(Map<String, dynamic> o) => '${o['operaciones']?['nombre'] ?? ''}${(o['repeticiones'] as num) != 1 ? ' ×${Formato.numero(o['repeticiones'], decimales: 0)}' : ''}';
  Map<String, dynamic>? op(String id) => ops.where((o) => o['id'] == id).firstOrNull;
  String? maquina(Map<String, dynamic> o) => o['tipos_maquina']?['codigo'] as String?;

  @override
  void initState() {
    super.initState();
    final u = k['ultimo'] as Map<String, dynamic>?;
    operarios = (u?['operarios'] as int?) ?? (empleados.isEmpty ? 6 : empleados.length);
    eficiencia = ((u?['eficiencia_objetivo'] ?? k['celula']['eficiencia_planeada'] ?? 80) as num).toDouble();
    minutosTurno = ((u?['minutos_turno'] ?? k['minutos_turno'] ?? 480) as num).toDouble();
    tolerancia = ((u?['tolerancia_pct'] ?? 10) as num).toDouble();
    contadora = u?['operacion_contadora_id'] as String? ?? ops.where((o) => o['es_contadora'] == true).firstOrNull?['id'] as String?;
    if (u != null) {
      for (final p in ((u['balanceo_puestos'] as List).cast<Map<String, dynamic>>()..sort((a, b) => (a['numero'] as int).compareTo(b['numero'] as int)))) {
        puestos.add(_PuestoEd(p['numero'] as int, empleado: p['empleado_id'] as String?, fracciones: {
          for (final a in p['balanceo_asignaciones'] as List) a['ficha_operacion_id'] as String: (a['fraccion'] as num).toDouble(),
        }));
      }
    } else {
      _automatico();
      sucio = true;
    }
  }

  void _automatico() {
    final r = balancear([
      for (final o in ops)
        OperacionBalanceo(id: o['id'], secuencia: o['secuencia'], sam: (o['sam'] as num).toDouble(), repeticiones: (o['repeticiones'] as num).toDouble(),
            tipoMaquina: maquina(o), sumaSam: o['agrega_minutos_sam'] == true),
    ], operarios, tolerancia: tolerancia / 100);
    final antes = {for (final p in puestos) p.numero: p.empleado};
    puestos
      ..clear()
      ..addAll([
        for (final p in r)
          _PuestoEd(p.numero, empleado: antes[p.numero] ?? (p.numero <= empleados.length ? empleados[p.numero - 1]['id'] as String : null), fracciones: {
            for (final a in p.asignaciones) a.operacionId: (puestosFraccion(a)),
          }),
      ]);
  }

  double puestosFraccion(Asignacion a) => (a.fraccion * 10000).round() / 10000;

  double carga(_PuestoEd p) => p.fracciones.entries.fold(0.0, (s, e) => s + (op(e.key) == null ? 0 : minutos(op(e.key)!) * e.value));
  double asignado(String opId) => puestos.fold(0.0, (s, p) => s + (p.fracciones[opId] ?? 0));

  Map<String, dynamic> _json(String? id) => {
        'id': id,
        'op_id': widget.clave.op,
        'celula_id': widget.clave.celula,
        'operarios': operarios,
        'eficiencia_objetivo': eficiencia,
        'minutos_turno': minutosTurno,
        'tolerancia_pct': tolerancia,
        'operacion_contadora_id': contadora,
        'puestos': [
          for (final p in puestos)
            {
              'numero': p.numero,
              'empleado_id': p.empleado,
              'maquinas': {for (final id in p.fracciones.keys) if (op(id) != null && maquina(op(id)!) != null && maquina(op(id)!) != 'MAN') maquina(op(id)!)}.toList(),
              'asignaciones': [for (final e in p.fracciones.entries) if (e.value > 0) {'ficha_operacion_id': e.key, 'fraccion': e.value}],
            },
        ],
      };

  Future<String?> _guardar() async {
    final u = k['ultimo'] as Map<String, dynamic>?;
    final id = await db.rpc('guardar_balanceo', params: {'p': _json(u?['estado'] == 'borrador' ? u!['id'] as String : (u?['id'] as String?))});
    setState(() => sucio = false);
    return '$id';
  }

  void cambiar(VoidCallback f) => setState(() {
        f();
        sucio = true;
      });

  @override
  Widget build(BuildContext context) {
    final editar = ref.watch(sesionProvider).value?.puedeEditar('balanceo') ?? false;
    final u = k['ultimo'] as Map<String, dynamic>?;
    final o = k['op'] as Map<String, dynamic>;
    final buenas = ((o['op_procesos'] as List).where((p) => p['proceso'] == 'confeccion').firstOrNull?['buenas'] ?? 0) as int;
    final pendientes = ((o['cantidad_total'] as int) - buenas).clamp(0, 1 << 30);
    final sam = ops.where((x) => x['agrega_minutos_sam'] == true).fold(0.0, (s, x) => s + minutos(x));
    final cargas = [for (final p in puestos) carga(p)];
    final m = metricas(samTotal: sam, operarios: operarios, eficienciaPct: eficiencia, minutosTurno: minutosTurno, cargas: cargas, pendientes: pendientes);
    final sinAsignar = [for (final x in ops) if ((asignado(x['id']) - 1).abs() > 0.002) x];
    final maxCarga = cargas.isEmpty ? 0.0 : cargas.reduce((a, b) => a > b ? a : b);

    Future<void> accion(Future<void> Function() f, String ok) async {
      try {
        await f();
        ref.invalidate(_contextoBalanceoProvider(widget.clave));
        if (mounted) avisar(this.context, ok);
      } catch (e) {
        if (mounted) avisar(this.context, mensajeError(e), error: true);
      }
    }

    Widget campo(String et, num v, ValueChanged<double> f, {double ancho = 130}) => SizedBox(
          width: ancho,
          child: TextFormField(
            initialValue: Formato.numero(v, decimales: v % 1 == 0 ? 0 : 1),
            enabled: editar,
            decoration: InputDecoration(labelText: et, isDense: true),
            onChanged: (t) {
              final x = numeroCo(t);
              if (x != null && x > 0) cambiar(() => f(x));
            },
          ),
        );

    Widget dato(String t, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(t, style: estilo(12, color: Colores.textoSuave)),
          Text(v, style: estilo(20, peso: FontWeight.w700, color: color)),
        ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
              u == null
                  ? 'Sin balanceo guardado: propuesta automática'
                  : 'Versión ${u['version']} · ${const {'borrador': 'borrador', 'publicado': 'publicada en las tablets', 'reemplazado': 'reemplazada'}[u['estado']]}'
                      '${u['publicado_en'] != null ? ' el ${Formato.fechaHora(DateTime.parse(u['publicado_en']))}' : ''}${sucio ? ' · cambios sin guardar' : ''}',
              style: estilo(14, peso: FontWeight.w600, color: sucio ? Colores.ambar : Colores.textoSuave)),
        ),
        OutlinedButton.icon(onPressed: () => _imprimir(o, m), icon: const Icon(Icons.print_outlined), label: const Text('Hoja de balanceo')),
        if (editar) ...[
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: () => cambiar(_automatico), icon: const Icon(Icons.auto_fix_high), label: const Text('Balancear automático')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: sucio ? () => accion(() async => _guardar(), u?['estado'] == 'publicado' ? 'Guardado como versión nueva (borrador)' : 'Balanceo guardado') : null,
              child: const Text('Guardar')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: sinAsignar.isNotEmpty
                ? null
                : () => accion(() async {
                      final id = sucio || u == null || u['estado'] != 'borrador' ? await _guardar() : u['id'] as String;
                      await db.rpc('publicar_balanceo', params: {'p_id': id});
                    }, 'Publicado: las tablets proponen estas operaciones a cada operario'),
            icon: const Icon(Icons.send_to_mobile),
            label: const Text('Publicar en tablets'),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      Tarjeta(
        child: Wrap(spacing: 18, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.end, children: [
          campo('Operarios', operarios, (x) => operarios = x.round(), ancho: 100),
          campo('Eficiencia objetivo (%)', eficiencia, (x) => eficiencia = x, ancho: 170),
          campo('Minutos del turno', minutosTurno, (x) => minutosTurno = x, ancho: 150),
          campo('Tolerancia (%)', tolerancia, (x) => tolerancia = x, ancho: 120),
          SizedBox(
            width: 300,
            child: DropdownButtonFormField<String>(
              initialValue: contadora,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Operación contadora', isDense: true),
              items: [for (final x in ops) DropdownMenuItem(value: x['id'] as String, child: Text('${x['secuencia']} · ${nombre(x)}', overflow: TextOverflow.ellipsis))],
              onChanged: editar ? (v) => cambiar(() => contadora = v) : null,
            ),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Tarjeta(
        child: Wrap(spacing: 36, runSpacing: 12, children: [
          dato('SAM total', '${Formato.numero(m.samTotal, decimales: 3)} min'),
          dato('Tiempo de ciclo', '${Formato.numero(m.ciclo, decimales: 3)} min'),
          dato('Meta por hora', Formato.numero(m.metaHora, decimales: 1)),
          dato('Meta por turno', Formato.numero(m.metaTurno, decimales: 0)),
          dato('Días para terminar', m.dias == null ? '—' : Formato.numero(m.dias!, decimales: 1)),
          dato('% de balance', '${Formato.numero(m.pctBalance, decimales: 1)} %', color: m.pctBalance >= 85 ? Colores.verde : m.pctBalance >= 70 ? Colores.ambar : Colores.rojo),
          dato('Sale por hora (cuello)', Formato.numero(m.metaHoraCuello, decimales: 1), color: Colores.textoSuave),
          dato('Prendas pendientes', Formato.numero(pendientes, decimales: 0)),
        ]),
      ),
      if (sinAsignar.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colores.ambar.withValues(alpha: 0.08), border: Border.all(color: Colores.ambar.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(6)),
          child: Text('Operaciones que no suman 100 %: ${sinAsignar.map((x) => '${nombre(x)} (${Formato.numero(asignado(x['id']) * 100, decimales: 0)} %)').join(', ')}',
              style: estilo(13.5, peso: FontWeight.w600, color: Colores.ambar)),
        ),
      const SizedBox(height: 12),
      for (final p in puestos) ...[
        _tarjetaPuesto(p, maxCarga, m.ciclo, editar),
        const SizedBox(height: 10),
      ],
      if (editar)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => cambiar(() => puestos.add(_PuestoEd(puestos.length + 1))), icon: const Icon(Icons.add), label: const Text('Agregar puesto')),
        ),
    ]);
  }

  Widget _tarjetaPuesto(_PuestoEd p, double maxCarga, double ciclo, bool editar) {
    final c = carga(p);
    final cuello = c > 0 && (c - maxCarga).abs() < 1e-9;
    final pct = ciclo <= 0 ? 0.0 : c / ciclo;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: cuello ? Colores.rojo : Colores.borde, width: cuello ? 2 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Puesto ${p.numero}', style: estilo(16, peso: FontWeight.w700)),
            const SizedBox(width: 12),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String?>(
                initialValue: p.empleado,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Operario', isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('—')),
                  for (final e in empleados) DropdownMenuItem(value: e['id'] as String, child: Text('${e['codigo']} · ${e['nombres']} ${e['apellidos']}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: editar ? (v) => cambiar(() => p.empleado = v) : null,
              ),
            ),
            const SizedBox(width: 12),
            Text({for (final id in p.fracciones.keys) if (op(id) != null) maquina(op(id)!) ?? 'MAN'}.join(' + '), style: estiloCodigo(13, color: Colores.textoSuave)),
            const Spacer(),
            if (cuello) const Padding(padding: EdgeInsets.only(right: 10), child: Pastilla('Cuello de botella', color: Colores.rojo)),
            SizedBox(
              width: 180,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${Formato.numero(c, decimales: 3)} min · ${Formato.numero(pct * 100, decimales: 0)} % del ciclo', style: estilo(13, peso: FontWeight.w600)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: pct.clamp(0, 1.5) / 1.5, minHeight: 7, backgroundColor: Colores.borde,
                      color: pct > 1 + tolerancia / 100 ? Colores.rojo : pct >= 0.85 ? Colores.verde : Colores.ambar),
                ),
              ]),
            ),
            if (editar && p.fracciones.isEmpty)
              IconButton(tooltip: 'Quitar puesto', onPressed: () => cambiar(() {
                    puestos.remove(p);
                    for (var i = 0; i < puestos.length; i++) {
                      puestos[i].numero = i + 1;
                    }
                  }), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          for (final e in (p.fracciones.entries.toList()..sort((a, b) => ((op(a.key)?['secuencia'] ?? 0) as int).compareTo((op(b.key)?['secuencia'] ?? 0) as int))))
            if (op(e.key) != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  SizedBox(width: 44, child: Text('${op(e.key)!['secuencia']}', style: estiloCodigo(12.5, color: Colores.textoSuave))),
                  Expanded(child: Text(nombre(op(e.key)!), style: estilo(14))),
                  SizedBox(width: 60, child: Text(maquina(op(e.key)!) ?? 'MAN', style: estiloCodigo(12.5, color: Colores.textoSuave))),
                  SizedBox(
                    width: 90,
                    child: editar
                        ? TextFormField(
                            key: ValueKey('${p.numero}${e.key}${e.value}'),
                            initialValue: Formato.numero(e.value * 100, decimales: e.value * 100 % 1 == 0 ? 0 : 1),
                            textAlign: TextAlign.right,
                            decoration: const InputDecoration(isDense: true, suffixText: '%'),
                            onFieldSubmitted: (t) {
                              final x = numeroCo(t);
                              if (x != null && x >= 0 && x <= 100) cambiar(() => x == 0 ? p.fracciones.remove(e.key) : p.fracciones[e.key] = x / 100);
                            },
                          )
                        : Text('${Formato.numero(e.value * 100, decimales: 0)} %', textAlign: TextAlign.right),
                  ),
                  SizedBox(width: 90, child: Text('${Formato.numero(minutos(op(e.key)!) * e.value, decimales: 3)} min', textAlign: TextAlign.right, style: estilo(13))),
                  if (editar)
                    PopupMenuButton<int>(
                      tooltip: 'Mover a otro puesto',
                      icon: const Icon(Icons.swap_horiz, size: 20),
                      itemBuilder: (_) => [for (final q in puestos) if (q != p) PopupMenuItem(value: q.numero, child: Text('Mover a puesto ${q.numero}'))],
                      onSelected: (n) => cambiar(() {
                        final q = puestos.firstWhere((x) => x.numero == n);
                        q.fracciones[e.key] = (q.fracciones[e.key] ?? 0) + e.value;
                        p.fracciones.remove(e.key);
                      }),
                    ),
                ]),
              ),
          if (editar)
            Align(
              alignment: Alignment.centerLeft,
              child: PopupMenuButton<String>(
                tooltip: 'Agregar operación',
                itemBuilder: (_) => [
                  for (final x in ops)
                    if (asignado(x['id']) < 0.999)
                      PopupMenuItem(value: x['id'] as String, child: Text('${x['secuencia']} · ${nombre(x)} (falta ${Formato.numero((1 - asignado(x['id'])) * 100, decimales: 0)} %)')),
                ],
                onSelected: (id) => cambiar(() => p.fracciones[id] = (p.fracciones[id] ?? 0) + (1 - asignado(id))),
                child: Padding(padding: const EdgeInsets.all(6), child: Text('+ Agregar operación', style: estilo(13.5, peso: FontWeight.w600, color: Colores.deProceso('corte')))),
              ),
            ),
        ]),
      ),
    );
  }

  Future<void> _imprimir(Map<String, dynamic> o, MetricasBalanceo m) async {
    final tema = pw.ThemeData.withFont(
      base: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-Regular.ttf')),
      bold: pw.Font.ttf(await rootBundle.load('assets/fuentes/IBMPlexSans-SemiBold.ttf')),
    );
    final d = pw.Document(theme: tema, title: 'Balanceo ${o['consecutivo']}');
    String emp(String? id) {
      final e = empleados.where((x) => x['id'] == id).firstOrNull;
      return e == null ? '—' : '${e['codigo']} ${e['nombres']} ${e['apellidos']}';
    }

    d.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (_) => [
        pw.Text('Hoja de balanceo · ${o['consecutivo']} · ${o['referencias']['codigo']} ${o['referencias']['nombre']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('${k['celula']['codigo']} · $operarios operarios · eficiencia ${Formato.numero(eficiencia, decimales: 0)} % · turno ${Formato.numero(minutosTurno, decimales: 0)} min',
            style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 6),
        pw.Text('SAM ${Formato.numero(m.samTotal, decimales: 3)} · ciclo ${Formato.numero(m.ciclo, decimales: 3)} · meta/hora ${Formato.numero(m.metaHora, decimales: 1)} · '
            'meta/turno ${Formato.numero(m.metaTurno, decimales: 0)} · balance ${Formato.numero(m.pctBalance, decimales: 1)} %${m.dias != null ? ' · ${Formato.numero(m.dias!, decimales: 1)} días' : ''}',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 10),
        pw.TableHelper.fromTextArray(
          headers: ['Puesto', 'Operario', 'Operaciones', 'Carga (min)', '% ciclo'],
          headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          data: [
            for (final p in puestos)
              [
                '${p.numero}',
                emp(p.empleado),
                [for (final e in p.fracciones.entries) if (op(e.key) != null) '${op(e.key)!['secuencia']} ${nombre(op(e.key)!)}${e.value < 0.999 ? ' (${Formato.numero(e.value * 100, decimales: 0)} %)' : ''}'].join('\n'),
                Formato.numero(carga(p), decimales: 3),
                '${Formato.numero(m.ciclo <= 0 ? 0 : carga(p) / m.ciclo * 100, decimales: 0)} %',
              ],
          ],
        ),
      ],
    ));
    final bytes = await d.save();
    await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: 'Balanceo ${o['consecutivo']}');
  }
}
