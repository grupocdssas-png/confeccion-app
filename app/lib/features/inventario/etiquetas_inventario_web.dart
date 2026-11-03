import 'package:flutter/material.dart';

import '../../core/etiquetas/etiquetas_pdf.dart';
import '../../core/etiquetas/impresion_web.dart';
import '../../core/etiquetas/zpl.dart';
import 'comun_inventario.dart';

/// Columnas que necesita una etiqueta de rollo.
const selectRolloEtiqueta =
    'id, codigo, lote_tintura, tono, ancho_real_cm, metros_saldo, kilos_saldo, metros_iniciales, kilos_iniciales, fecha_ingreso, '
    'materiales(nombre, codigo, unidad), colores(nombre, hex), proveedores(nombre), ubicaciones(codigo)';

Map<String, Object?> datosRolloDesdeFila(Map<String, dynamic> r, {bool iniciales = false}) => datosEtiquetaRollo(
      codigo: r['codigo'],
      tela: r['materiales']?['nombre'] ?? '',
      color: r['colores']?['nombre'] ?? '',
      lote: r['lote_tintura'] ?? '',
      tono: r['tono'],
      anchoCm: (r['ancho_real_cm'] as num?) ?? 0,
      metros: (r[iniciales ? 'metros_iniciales' : 'metros_saldo'] as num?) ?? 0,
      kilos: (r[iniciales ? 'kilos_iniciales' : 'kilos_saldo'] as num?) ?? 0,
      proveedor: r['proveedores']?['nombre'],
      fechaIngreso: DateTime.tryParse('${r['fecha_ingreso']}') ?? DateTime.now(),
      ubicacion: r['ubicaciones']?['codigo'],
    );

Future<Map<String, dynamic>?> _plantilla(String tipo) =>
    db.from('plantillas_etiqueta').select().eq('tipo', tipo).eq('activa', true).maybeSingle();

/// Imprime etiquetas de rollo desde la web (Browser Print o PDF), en el orden recibido.
Future<void> imprimirRollosWeb(BuildContext context, List<Map<String, dynamic>> rollos,
    {bool reimpresion = false, String? motivo}) async {
  try {
    final p = await _plantilla('rollo');
    final datos = [for (final r in rollos) datosRolloDesdeFila(r)];
    final res = await imprimirEtiquetasWeb(
      etiquetas: [
        for (var i = 0; i < rollos.length; i++)
          (codigo: rollos[i]['codigo'] as String, entidadId: rollos[i]['id'] as String?,
           zpl: renderizarZpl(p?['zpl'] ?? plantillaRolloPorDefecto, datos[i])),
      ],
      generarPdf: () => EtiquetasPdf.rollos(datos),
      entidad: 'rollos',
      plantillaId: p?['id'],
      plantillaVersion: p?['version'],
      esReimpresion: reimpresion,
      motivo: motivo,
    );
    if (context.mounted) {
      avisar(context, res.medio == 'browser_print'
          ? '${rollos.length} etiquetas enviadas a ${res.impresora}'
          : 'Zebra Browser Print no está activo: se abrió el PDF (100 × 50 mm)');
    }
  } catch (e) {
    if (context.mounted) avisar(context, 'No se pudo imprimir: ${mensajeError(e)}', error: true);
  }
}

Future<void> imprimirUbicacionesWeb(BuildContext context, List<Map<String, dynamic>> ubicaciones) async {
  try {
    final p = await _plantilla('ubicacion');
    final datos = [
      for (final u in ubicaciones)
        datosEtiquetaUbicacion(codigo: u['codigo'], bodega: u['bodegas']?['nombre'] ?? '', descripcion: u['descripcion']),
    ];
    final res = await imprimirEtiquetasWeb(
      etiquetas: [
        for (var i = 0; i < ubicaciones.length; i++)
          (codigo: ubicaciones[i]['codigo'] as String, entidadId: ubicaciones[i]['id'] as String?,
           zpl: renderizarZpl(p?['zpl'] ?? plantillaUbicacionPorDefecto, datos[i])),
      ],
      generarPdf: () => EtiquetasPdf.ubicaciones(datos),
      entidad: 'ubicaciones',
      plantillaId: p?['id'],
      plantillaVersion: p?['version'],
    );
    if (context.mounted) {
      avisar(context, res.medio == 'browser_print' ? 'Enviadas a ${res.impresora}' : 'Se abrió el PDF de etiquetas');
    }
  } catch (e) {
    if (context.mounted) avisar(context, 'No se pudo imprimir: ${mensajeError(e)}', error: true);
  }
}
