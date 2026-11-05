import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db, Tabla, avisar, mensajeError;

final _tablerosProvider = FutureProvider.autoDispose((ref) => db.from('tableros_tv').select().order('nombre', ascending: true));

/// Lista de tableros configurados (desde aquí se abren en el televisor).
class PantallaTableros extends ConsumerWidget {
  const PantallaTableros({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final datos = ref.watch(_tablerosProvider);
    final editar = (ref.watch(sesionProvider).value?.puedeEditar('tv') ?? false) || (ref.watch(sesionProvider).value?.puedeEditar('eficiencia') ?? false);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EncabezadoPagina('Tableros TV', subtitulo: 'Abra el tablero en el navegador del televisor (pantalla completa con F11). Se actualiza cada 30 segundos.'),
      datos.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(mensajeError(e), style: estilo(14, color: Colores.rojo)),
        data: (l) => Tarjeta(
          child: Tabla(
            columnas: const ['Tablero', 'Vistas', 'Rotación', ''],
            filas: [
              for (final t in l)
                DataRow(cells: [
                  DataCell(Text('${t['nombre']}', style: estilo(14, peso: FontWeight.w600))),
                  DataCell(Text([
                    for (final v in t['vistas'] as List)
                      const {'celulas': 'Todos los módulos', 'procesos': 'Avance por proceso', 'celula': 'Un módulo'}[v['tipo']] ?? '${v['tipo']}',
                  ].join(' → '))),
                  DataCell(Text('${t['rotacion_s']} s')),
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    FilledButton.icon(onPressed: () => context.go('/tv/ver/${t['id']}'), icon: const Icon(Icons.tv), label: const Text('Abrir')),
                    if (editar) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          final ok = await showDialog<bool>(context: context, builder: (_) => _EditarTablero(t: t));
                          if (ok == true) ref.invalidate(_tablerosProvider);
                        },
                        child: const Text('Editar')),
                    ],
                  ])),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _EditarTablero extends StatefulWidget {
  const _EditarTablero({required this.t});
  final Map<String, dynamic> t;
  @override
  State<_EditarTablero> createState() => _EditarTableroState();
}

class _EditarTableroState extends State<_EditarTablero> {
  late final _vistas = [for (final v in widget.t['vistas'] as List) Map<String, dynamic>.from(v as Map)];
  late double _rot = (widget.t['rotacion_s'] as num).toDouble();
  List<Map<String, dynamic>> _celulas = [];

  @override
  void initState() {
    super.initState();
    db.from('celulas').select('id, codigo, nombre').eq('activo', true).eq('proceso', 'confeccion').order('codigo', ascending: true).then((l) {
      if (mounted) setState(() => _celulas = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final opciones = <String, Map<String, dynamic>>{
      'celulas': {'tipo': 'celulas'},
      'procesos': {'tipo': 'procesos'},
      for (final c in _celulas) 'celula:${c['id']}': {'tipo': 'celula', 'celula_id': c['id']},
    };
    String nombre(String k) => k == 'celulas' ? 'Todos los módulos' : k == 'procesos' ? 'Avance por proceso'
        : 'Módulo ${_celulas.where((c) => 'celula:${c['id']}' == k).firstOrNull?['codigo'] ?? ''}';
    String clave(Map<String, dynamic> v) => v['tipo'] == 'celula' ? 'celula:${v['celula_id']}' : '${v['tipo']}';
    return AlertDialog(
      title: Text('Tablero ${widget.t['nombre']}'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Vistas que rotan (en orden):', style: estilo(13, color: Colores.textoSuave)),
          for (final k in opciones.keys)
            CheckboxListTile(
              dense: true,
              value: _vistas.any((v) => clave(v) == k),
              title: Text(nombre(k)),
              onChanged: (s) => setState(() => s! ? _vistas.add(opciones[k]!) : _vistas.removeWhere((v) => clave(v) == k)),
            ),
          Row(children: [
            Text('Cambia cada ${_rot.round()} s'),
            Expanded(child: Slider(value: _rot, min: 5, max: 120, divisions: 23, onChanged: (v) => setState(() => _rot = v))),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _vistas.isEmpty
              ? null
              : () async {
                  try {
                    await db.from('tableros_tv').update({'vistas': _vistas, 'rotacion_s': _rot.round()}).eq('id', widget.t['id']);
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (context.mounted) avisar(context, mensajeError(e), error: true);
                  }
                },
          child: const Text('Guardar')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Modo TV
// ---------------------------------------------------------------------------
class PantallaTv extends StatefulWidget {
  const PantallaTv({super.key, required this.id});
  final String id;
  @override
  State<PantallaTv> createState() => _PantallaTvState();
}

class _PantallaTvState extends State<PantallaTv> {
  Map<String, dynamic>? _tablero;
  Map<String, dynamic>? _datos;
  String? _error;
  var _vista = 0;
  Timer? _datosTimer, _rotarTimer, _reloj;
  DateTime _ahora = DateTime.now();

  static const fondo = Colores.tvFondo;
  static const tarjeta = Colores.tvTarjeta;
  static const suave = Color(0xFFA3A6AD);

  @override
  void initState() {
    super.initState();
    _cargar();
    _datosTimer = Timer.periodic(const Duration(seconds: 30), (_) => _cargarDatos());
    _reloj = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _ahora = DateTime.now()));
  }

  Future<void> _cargar() async {
    try {
      final t = await db.from('tableros_tv').select().eq('id', widget.id).single();
      setState(() => _tablero = t);
      _rotarTimer = Timer.periodic(Duration(seconds: (t['rotacion_s'] as num).toInt()), (_) {
        setState(() => _vista = (_vista + 1) % math.max(1, (t['vistas'] as List).length));
      });
      await _cargarDatos();
    } catch (e) {
      setState(() => _error = mensajeError(e));
    }
  }

  Future<void> _cargarDatos() async {
    try {
      final d = await db.rpc('tablero_planta') as Map<String, dynamic>;
      if (mounted) setState(() { _datos = d; _error = null; });
    } catch (e) {
      // sin red: se queda mostrando lo último y avisa
      if (mounted) setState(() => _error = 'Sin conexión: datos de las ${_datos == null ? '—' : Formato.hora(DateTime.parse(_datos!['hora']))}');
    }
  }

  @override
  void dispose() {
    _datosTimer?.cancel();
    _rotarTimer?.cancel();
    _reloj?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vistas = (_tablero?['vistas'] as List?) ?? const [];
    final v = vistas.isEmpty ? null : Map<String, dynamic>.from(vistas[_vista % vistas.length] as Map);
    return Scaffold(
      backgroundColor: fondo,
      body: DefaultTextStyle(
        style: estilo(22, color: Colors.white),
        child: GestureDetector(
          onDoubleTap: () => context.go('/tv'),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text(_titulo(v), style: estilo(34, peso: FontWeight.w700, color: Colors.white)),
                const Spacer(),
                if (_error != null) Padding(padding: const EdgeInsets.only(right: 20), child: Text(_error!, style: estilo(18, color: Colores.ambar))),
                if (_datos?['eficiencia_planta'] != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 28),
                    child: Text('Planta ${Formato.numero(_datos!['eficiencia_planta'], decimales: 0)} %',
                        style: estilo(30, peso: FontWeight.w700, color: Colores.semaforo((_datos!['eficiencia_planta'] as num).toDouble()))),
                  ),
                Text(Formato.hora(_ahora), style: estiloCodigo(40, color: Colors.white)),
              ]),
              const SizedBox(height: 20),
              Expanded(
                child: _datos == null
                    ? const Center(child: CircularProgressIndicator())
                    : switch (v?['tipo']) {
                        'procesos' => _procesos(),
                        'celula' => _celula(((_datos!['celulas'] as List).cast<Map<String, dynamic>>())
                            .where((c) => c['celula']['id'] == v!['celula_id']).firstOrNull),
                        _ => _celulas(),
                      },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  String _titulo(Map<String, dynamic>? v) {
    if (v?['tipo'] == 'procesos') return 'Avance por proceso';
    if (v?['tipo'] == 'celula') {
      final c = ((_datos?['celulas'] as List?) ?? const []).where((c) => c['celula']['id'] == v!['celula_id']).firstOrNull;
      return c == null ? 'Módulo' : '${c['celula']['codigo']} · ${c['celula']['nombre']}';
    }
    return 'Módulos de confección · hoy';
  }

  Widget _caja(Widget child, {Color? borde}) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: tarjeta, borderRadius: BorderRadius.circular(16), border: Border.all(color: borde ?? Colors.white10, width: borde == null ? 1 : 3)),
        child: child,
      );

  Widget _celulas() {
    final cs = (_datos!['celulas'] as List).cast<Map<String, dynamic>>();
    return GridView.count(
      crossAxisCount: cs.length <= 2 ? 2 : 3,
      mainAxisSpacing: 20,
      crossAxisSpacing: 20,
      childAspectRatio: 1.5,
      children: [
        for (final c in cs)
          _caja(
            borde: c['paro_activo'] != null ? Colores.rojo : null,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${c['celula']['codigo']}', style: estilo(30, peso: FontWeight.w700, color: Colors.white)),
              Text('${c['op']?['consecutivo'] ?? 'Sin OP en curso'} ${c['op']?['referencia'] ?? ''}', style: estilo(18, color: suave), maxLines: 1, overflow: TextOverflow.ellipsis),
              const Spacer(),
              Text(c['eficiencia_dia'] == null ? '—' : '${Formato.numero(c['eficiencia_dia'], decimales: 0)} %',
                  style: estilo(72, peso: FontWeight.w700, color: c['eficiencia_dia'] == null ? suave : Colores.semaforo((c['eficiencia_dia'] as num).toDouble()))),
              Text('${Formato.numero(c['producidas_dia'] ?? 0, decimales: 0)} prendas hoy · meta ${c['meta_hora'] == null ? '—' : Formato.numero(c['meta_hora'], decimales: 0)}/h',
                  style: estilo(20, color: suave)),
              if (c['paro_activo'] != null)
                Text('Paro: ${c['paro_activo']['causa']}', style: estilo(20, peso: FontWeight.w700, color: Colores.rojo)),
            ]),
          ),
      ],
    );
  }

  Widget _celula(Map<String, dynamic>? c) {
    if (c == null) return Center(child: Text('Módulo no encontrado', style: estilo(28, color: suave)));
    final horas = (c['hora_a_hora'] as List).cast<Map<String, dynamic>>();
    final meta = (c['meta_hora'] as num?)?.toDouble();
    final horaActual = _ahora.toUtc().subtract(const Duration(hours: 5)).hour;
    final enCurso = horas.where((h) => h['hora'] == horaActual).firstOrNull;
    final ops = (c['operarios'] as List).cast<Map<String, dynamic>>();
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        flex: 3,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (c['paro_activo'] != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colores.rojo, borderRadius: BorderRadius.circular(12)),
              child: Text('PARO · ${c['paro_activo']['causa']} · ${c['paro_activo']['operario']}', style: estilo(30, peso: FontWeight.w700, color: Colors.white)),
            ),
          Row(children: [
            Expanded(child: _caja(_dato('Eficiencia hoy', c['eficiencia_dia'] == null ? '—' : '${Formato.numero(c['eficiencia_dia'], decimales: 0)} %',
                color: c['eficiencia_dia'] == null ? suave : Colores.semaforo((c['eficiencia_dia'] as num).toDouble())))),
            const SizedBox(width: 16),
            Expanded(child: _caja(_dato('Esta hora ($horaActual:00)', '${enCurso?['producidas'] ?? 0} / ${meta == null ? '—' : Formato.numero(meta, decimales: 0)}',
                color: meta != null && ((enCurso?['producidas'] ?? 0) as num) >= meta * _ahora.minute / 60 ? Colores.verde : Colores.ambar))),
            const SizedBox(width: 16),
            Expanded(child: _caja(_dato('Producidas hoy', Formato.numero(c['producidas_dia'] ?? 0, decimales: 0)))),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _caja(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Hora a hora (línea = meta)', style: estilo(20, color: suave)),
              const SizedBox(height: 10),
              Expanded(child: CustomPaint(painter: _HoraAHora(horas, meta), size: Size.infinite)),
            ])),
          ),
          const SizedBox(height: 10),
          Text('${c['op']?['consecutivo'] ?? ''} ${c['op']?['referencia'] ?? ''}${c['op'] != null ? ' · ${c['op']['confeccionadas'] ?? 0} de ${c['op']['cantidad']} entregadas' : ''}'
              ' · ${Formato.numero(c['minutos_paro_dia'] ?? 0, decimales: 0)} min de paro hoy', style: estilo(20, color: suave)),
        ]),
      ),
      const SizedBox(width: 20),
      Expanded(
        flex: 2,
        child: _caja(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Eficiencia por operario', style: estilo(20, color: suave)),
          const SizedBox(height: 10),
          for (final o in ops.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text('${o['nombre']}', style: estilo(24, color: Colors.white), overflow: TextOverflow.ellipsis)),
                Text(o['eficiencia'] == null ? '—' : '${Formato.numero(o['eficiencia'], decimales: 0)} %',
                    style: estilo(28, peso: FontWeight.w700, color: o['eficiencia'] == null ? suave : Colores.semaforo((o['eficiencia'] as num).toDouble()))),
              ]),
            ),
          if (ops.isEmpty) Text('Nadie ha marcado hoy', style: estilo(22, color: suave)),
        ])),
      ),
    ]);
  }

  Widget _dato(String t, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: estilo(20, color: suave)),
        Text(v, style: estilo(56, peso: FontWeight.w700, color: color ?? Colors.white)),
      ]);

  Widget _procesos() {
    final ps = (_datos!['procesos'] as List).cast<Map<String, dynamic>>();
    return _caja(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${_datos!['ops_activas']} órdenes de producción activas · prendas buenas por proceso', style: estilo(22, color: suave)),
      const SizedBox(height: 24),
      for (final p in ps)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            SizedBox(width: 260, child: Text('${p['nombre']}', style: estilo(30, peso: FontWeight.w600, color: Colors.white))),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: (p['total'] as num) == 0 ? 0 : ((p['buenas'] as num) / (p['total'] as num)).clamp(0, 1).toDouble(),
                  minHeight: 34,
                  backgroundColor: Colors.white10,
                  color: Color(int.parse('FF${'${p['color'] ?? '#3F4A5A'}'.replaceFirst('#', '')}', radix: 16)),
                ),
              ),
            ),
            SizedBox(
              width: 260,
              child: Text('${Formato.numero(p['buenas'], decimales: 0)} / ${Formato.numero(p['total'], decimales: 0)}',
                  textAlign: TextAlign.right, style: estilo(30, peso: FontWeight.w700, color: Colors.white)),
            ),
          ]),
        ),
    ]));
  }
}

class _HoraAHora extends CustomPainter {
  _HoraAHora(this.horas, this.meta);
  final List<Map<String, dynamic>> horas;
  final double? meta;

  @override
  void paint(Canvas canvas, Size size) {
    if (horas.isEmpty) return;
    final desde = 6, hasta = math.max(16, horas.map((h) => h['hora'] as int).reduce(math.max) + 1);
    final n = hasta - desde;
    final maxV = math.max(meta ?? 0, horas.map((h) => (h['producidas'] as num).toDouble()).reduce(math.max)) * 1.15 + 1;
    final ancho = size.width / n;
    final abajo = size.height - 30;
    for (final h in horas) {
      final i = (h['hora'] as int) - desde;
      if (i < 0 || i >= n) continue;
      final v = (h['producidas'] as num).toDouble();
      final alto = abajo * v / maxV;
      final ok = meta == null || v >= meta!;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * ancho + ancho * 0.15, abajo - alto, ancho * 0.7, alto), const Radius.circular(4)),
          Paint()..color = ok ? Colores.verde : Colores.ambar);
      _t(canvas, '${v.round()}', Offset(i * ancho + ancho / 2, abajo - alto - 26), 18);
    }
    for (var i = 0; i < n; i++) {
      _t(canvas, '${desde + i}', Offset(i * ancho + ancho / 2, abajo + 4), 16, color: const Color(0xFFA3A6AD));
    }
    if (meta != null) {
      final y = abajo - abajo * meta! / maxV;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()
        ..color = Colors.white70
        ..strokeWidth = 2);
    }
  }

  void _t(Canvas c, String s, Offset centro, double tam, {Color color = Colors.white}) {
    final p = TextPainter(text: TextSpan(text: s, style: estilo(tam, peso: FontWeight.w600, color: color)), textDirection: TextDirection.ltr)..layout();
    p.paint(c, centro - Offset(p.width / 2, 0));
  }

  @override
  bool shouldRepaint(covariant _HoraAHora old) => true;
}
