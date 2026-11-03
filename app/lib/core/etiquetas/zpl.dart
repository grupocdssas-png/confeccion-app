import '../formato/formato.dart';

/// Reemplaza {{campo}} de la plantilla ZPL por los datos. Campos desconocidos
/// quedan vacíos. Los caracteres de control de ZPL (^ y ~) se cambian por "-"
/// para que un dato nunca rompa la etiqueta. La plantilla trae ^CI28 (UTF-8):
/// las tildes y la ñ salen bien.
String renderizarZpl(String plantilla, Map<String, Object?> datos, {int copias = 1}) {
  final valores = <String, Object?>{'copias': copias < 1 ? 1 : copias, ...datos};
  return plantilla.replaceAllMapped(RegExp(r'\{\{\s*(\w+)\s*\}\}'), (m) => limpiarCampoZpl(valores[m.group(1)]));
}

String limpiarCampoZpl(Object? v) =>
    v == null ? '' : '$v'.replaceAll(RegExp(r'[\^~]'), '-').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

/// Datos de la etiqueta de rollo (100 × 50 mm).
Map<String, Object?> datosEtiquetaRollo({
  required String codigo,
  required String tela,
  required String color,
  required String lote,
  String? tono,
  required num anchoCm,
  required num metros,
  required num kilos,
  String? proveedor,
  required DateTime fechaIngreso,
  String? ubicacion,
}) =>
    {
      'codigo': codigo,
      'tela': tela,
      'color': color,
      'lote': lote,
      'tono': tono ?? '—',
      'ancho': Formato.numero(anchoCm, decimales: 1),
      'metros': Formato.numero(metros, decimales: 2),
      'kilos': Formato.numero(kilos, decimales: 2),
      'proveedor': proveedor ?? '',
      'fecha': '${fechaIngreso.day.toString().padLeft(2, '0')}/${fechaIngreso.month.toString().padLeft(2, '0')}/${fechaIngreso.year}',
      'ubicacion': ubicacion ?? '—',
    };

/// Datos de la etiqueta de ubicación de bodega (100 × 50 mm).
Map<String, Object?> datosEtiquetaUbicacion({required String codigo, required String bodega, String? descripcion}) =>
    {'codigo': codigo, 'bodega': bodega, 'descripcion': descripcion ?? ''};

/// Plantillas por defecto (las mismas de la migración 7) para pruebas y vista previa
/// cuando aún no se ha descargado la configuración.
const plantillaRolloPorDefecto = '''^XA
^CI28
^PW800
^LL400
^LH0,0
^FO20,40^BQN,2,11^FDMA,{{codigo}}^FS
^FO300,28^A0N,52,52^FD{{codigo}}^FS
^FO300,90^A0N,30,30^FB480,2,0,L^FD{{tela}}^FS
^FO300,160^A0N,30,30^FDColor: {{color}}^FS
^FO300,198^A0N,30,30^FDLote: {{lote}}   Tono: {{tono}}^FS
^FO300,236^A0N,30,30^FDAncho: {{ancho}} cm^FS
^FO300,274^A0N,34,34^FD{{metros}} m   {{kilos}} kg^FS
^FO20,322^GB760,2,2^FS
^FO20,336^A0N,24,24^FD{{proveedor}}^FS
^FO20,366^A0N,24,24^FDIngreso: {{fecha}}   Ubicación: {{ubicacion}}^FS
^PQ{{copias}}
^XZ''';

const plantillaUbicacionPorDefecto = '''^XA
^CI28
^PW800
^LL400
^LH0,0
^FO30,60^BQN,2,11^FDMA,{{codigo}}^FS
^FO320,70^A0N,70,70^FB460,2,0,L^FD{{codigo}}^FS
^FO320,230^A0N,34,34^FB460,2,0,L^FD{{bodega}}^FS
^FO320,310^A0N,28,28^FB460,2,0,L^FD{{descripcion}}^FS
^PQ{{copias}}
^XZ''';

/// Etiqueta de prueba para el botón "Imprimir prueba".
String zplPrueba(String nombreImpresora) => renderizarZpl('''^XA
^CI28
^PW800
^LL400
^FO20,40^BQN,2,8^FDMA,PRUEBA^FS
^FO240,60^A0N,48,48^FDPrueba de impresión^FS
^FO240,130^A0N,30,30^FD{{impresora}}^FS
^FO240,180^A0N,30,30^FDÁÉÍÓÚ Ñ ñ · {{hora}}^FS
^FO20,330^GB760,4,4^FS
^XZ''', {'impresora': nombreImpresora, 'hora': Formato.fechaHora(DateTime.now())});
