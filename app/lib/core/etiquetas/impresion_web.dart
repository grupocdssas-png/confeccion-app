import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Impresión desde el panel web:
///  1. Zebra Browser Print (programa gratuito de Zebra instalado en el PC de oficina
///     con la impresora conectada por USB o red). Envía el ZPL tal cual.
///  2. Si no está instalado: PDF al tamaño real para imprimir con el diálogo del navegador.
class BrowserPrint {
  BrowserPrint({http.Client? cliente}) : _cliente = cliente ?? http.Client();
  final http.Client _cliente;
  static const _base = 'http://127.0.0.1:9100';

  /// Impresora predeterminada de Browser Print, o null si el programa no responde.
  Future<Map<String, dynamic>?> impresora() async {
    try {
      final r = await _cliente.get(Uri.parse('$_base/default?type=printer')).timeout(const Duration(seconds: 2));
      if (r.statusCode != 200 || r.body.trim().isEmpty) return null;
      final j = jsonDecode(r.body);
      return j is Map<String, dynamic> && j['name'] != null ? j : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> enviar(Map<String, dynamic> impresora, String zpl) async {
    final r = await _cliente
        .post(Uri.parse('$_base/write'), body: jsonEncode({'device': impresora, 'data': zpl}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode >= 300) throw Exception('Browser Print respondió ${r.statusCode}: ${r.body}');
  }
}

class ResultadoImpresionWeb {
  const ResultadoImpresionWeb(this.medio, this.impresora);
  final String medio; // browser_print | pdf
  final String? impresora;
}

/// Imprime un lote de etiquetas: ZPL por Browser Print o, si no hay, PDF.
/// Registra cada etiqueta en trabajos_impresion (evento).
Future<ResultadoImpresionWeb> imprimirEtiquetasWeb({
  required List<({String codigo, String? entidadId, String zpl})> etiquetas,
  required Future<List<int>> Function() generarPdf,
  required String entidad,
  String? plantillaId,
  int? plantillaVersion,
  bool esReimpresion = false,
  String? motivo,
  BrowserPrint? browserPrint,
}) async {
  final bp = browserPrint ?? BrowserPrint();
  final impresora = await bp.impresora();
  String medio;
  if (impresora != null) {
    for (final e in etiquetas) {
      await bp.enviar(impresora, e.zpl);
    }
    medio = 'browser_print';
  } else {
    final bytes = await generarPdf();
    await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes), name: 'Etiquetas $entidad');
    medio = 'pdf';
  }
  final cliente = Supabase.instance.client;
  await cliente.from('trabajos_impresion').insert([
    for (final e in etiquetas)
      {
        'id': const Uuid().v4(),
        'entidad': entidad,
        'entidad_id': e.entidadId,
        'codigo': e.codigo,
        'plantilla_id': plantillaId,
        'plantilla_version': plantillaVersion,
        'medio': medio,
        'es_reimpresion': esReimpresion,
        'motivo': motivo,
        'estado_final': 'enviado',
      }
  ]);
  return ResultadoImpresionWeb(medio, impresora?['name'] as String?);
}
