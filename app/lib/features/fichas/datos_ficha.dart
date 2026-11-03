import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/sesion.dart';
import '../inventario/comun_inventario.dart' show db, avisar, mensajeError;

/// Toda la ficha (una versión) con sus detalles, en una sola consulta.
final fichaProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) => db
    .from('ficha_versiones')
    .select('*, referencias(*, familias_producto(nombre), tipos_producto(nombre)), curvas(nombre), '
        'ficha_tallas(talla_id, orden, tallas(codigo, orden)), '
        'ficha_partes(*), '
        'ficha_combinaciones(*, ficha_combinacion_partes(*)), '
        'ficha_medidas(*, ficha_medida_tallas(*)), '
        'ficha_bom(*, ficha_bom_consumos(*), materiales(codigo, nombre, unidad, tipo, costo_estandar, maneja_color)), '
        'ficha_artes(*), ficha_ruta(*), '
        'ficha_operaciones(*, operaciones(codigo, nombre, sam, valor_destajo), tipos_maquina(codigo, nombre)), '
        'ficha_costo_estandar(*), ficha_aprobaciones(*, perfiles:usuario_id(nombre))')
    .eq('id', id)
    .single());

/// Catálogos que usan los pasos de la ficha.
final catalogoFichaProvider = FutureProvider((ref) async {
  final r = await Future.wait([
    db.from('tallas').select().eq('activo', true).order('orden', ascending: true),
    db.from('colores').select().eq('activo', true).order('nombre', ascending: true),
    db.from('materiales').select().eq('activo', true).order('nombre', ascending: true),
    db.from('curvas').select('*, curva_tallas(talla_id, proporcion)').eq('activo', true),
    db.from('procesos').select().order('orden', ascending: true),
    db.from('operaciones').select('*, tipos_maquina(codigo)').eq('activo', true).order('codigo', ascending: true),
    db.from('tipos_maquina').select().order('codigo', ascending: true),
  ]);
  return (tallas: r[0], colores: r[1], materiales: r[2], curvas: r[3], procesos: r[4], operaciones: r[5], maquinas: r[6]);
});

typedef CatalogoFicha = ({
  List<Map<String, dynamic>> tallas, List<Map<String, dynamic>> colores, List<Map<String, dynamic>> materiales,
  List<Map<String, dynamic>> curvas, List<Map<String, dynamic>> procesos, List<Map<String, dynamic>> operaciones,
  List<Map<String, dynamic>> maquinas,
});

/// Tallas de la ficha en orden.
List<Map<String, dynamic>> tallasFicha(Map<String, dynamic> f) =>
    (f['ficha_tallas'] as List).cast<Map<String, dynamic>>().toList()..sort((a, b) => (a['tallas']['orden'] as int).compareTo(b['tallas']['orden'] as int));

List<Map<String, dynamic>> ordenar(List l, [String campo = 'orden']) =>
    l.cast<Map<String, dynamic>>().toList()..sort((a, b) => ((a[campo] ?? 0) as num).compareTo((b[campo] ?? 0) as num));

/// La ficha se edita solo en borrador y con permiso de editar fichas.
bool fichaEditable(WidgetRef ref, Map<String, dynamic> f) =>
    f['estado'] == 'borrador' && (ref.watch(sesionProvider).value?.puedeEditar('ficha_tecnica') ?? false);

/// Ejecuta un cambio, avisa si falla y recarga la ficha.
Future<bool> cambiar(BuildContext context, WidgetRef ref, String fichaId, Future<void> Function() f, {String? ok}) async {
  try {
    await f();
    ref.invalidate(fichaProvider(fichaId));
    if (ok != null && context.mounted) avisar(context, ok);
    return true;
  } catch (e) {
    if (context.mounted) avisar(context, mensajeError(e), error: true);
    return false;
  }
}

/// Campo de texto que guarda al salir del campo o con Enter.
class CampoGuardable extends StatefulWidget {
  const CampoGuardable({super.key, required this.valor, required this.onGuardar, this.etiqueta, this.ancho = 120,
      this.habilitado = true, this.numerico = false, this.alinearDerecha = false, this.lineas = 1});
  final String valor;
  final String? etiqueta;
  final double ancho;
  final bool habilitado, numerico, alinearDerecha;
  final int lineas;
  final Future<void> Function(String) onGuardar;
  @override
  State<CampoGuardable> createState() => _CampoGuardableState();
}

class _CampoGuardableState extends State<CampoGuardable> {
  late final _c = TextEditingController(text: widget.valor);
  final _foco = FocusNode();

  @override
  void initState() {
    super.initState();
    _foco.addListener(() {
      if (!_foco.hasFocus && _c.text != widget.valor) widget.onGuardar(_c.text);
    });
  }

  @override
  void didUpdateWidget(covariant CampoGuardable old) {
    super.didUpdateWidget(old);
    if (old.valor != widget.valor && !_foco.hasFocus) _c.text = widget.valor;
  }

  @override
  void dispose() {
    _foco.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.ancho,
        child: TextField(
          controller: _c,
          focusNode: _foco,
          enabled: widget.habilitado,
          maxLines: widget.lineas,
          textAlign: widget.alinearDerecha ? TextAlign.right : TextAlign.start,
          keyboardType: widget.numerico ? const TextInputType.numberWithOptions(decimal: true) : null,
          onSubmitted: (v) {
            if (v != widget.valor) widget.onGuardar(v);
          },
          decoration: InputDecoration(labelText: widget.etiqueta, isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
        ),
      );
}

/// "0.185" → "0,185" para mostrar en campos editables.
String numTxt(Object? v) {
  if (v == null) return '';
  final d = (v as num).toDouble();
  var s = d.toString();
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return s.replaceAll('.', ',');
}
