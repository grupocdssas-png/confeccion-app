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

/// Datos de la etiqueta de paquete de corte (50 × 30 mm).
Map<String, Object?> datosEtiquetaPaquete({
  required String codigo,
  required String op,
  required String referencia,
  required String talla,
  required int cantidad,
  required String color,
  required String lote,
  required String partes,
  required int capaDesde,
  required int capaHasta,
  int espiga = 1,
  required String corte,
  required DateTime fecha,
}) =>
    {
      'codigo': codigo,
      'op': op,
      'referencia': referencia,
      'talla': talla,
      'cantidad': cantidad,
      'color': color,
      'lote': lote,
      'partes': partes,
      'capas': capaDesde == capaHasta ? '$capaDesde' : '$capaDesde-$capaHasta${espiga > 1 ? ' E$espiga' : ''}',
      'corte': corte,
      'fecha': '${fecha.day.toString().padLeft(2, '0')}/${fecha.month.toString().padLeft(2, '0')}',
    };

/// Datos de la etiqueta de juego (prenda combinada, 50 × 30 mm).
Map<String, Object?> datosEtiquetaJuego({
  required String codigo,
  required String op,
  required String referencia,
  required String talla,
  required int cantidad,
  required String combinacion,
  required List<String> paquetes,
}) =>
    {
      'codigo': codigo,
      'op': op,
      'referencia': referencia,
      'talla': talla,
      'cantidad': cantidad,
      'combinacion': combinacion,
      'paquetes': paquetes.join(' '),
    };

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

/// Plantillas de corte por defecto (las mismas de la migración 11).
const plantillaPaquetePorDefecto = '''^XA
^CI28
^PW400
^LL240
^LH0,0
^FO10,14^BQN,2,5^FDMA,{{codigo}}^FS
^FO150,14^A0N,30,30^FD{{codigo}}^FS
^FO150,50^A0N,24,24^FD{{op}}  {{referencia}}^FS
^FO150,80^A0N,40,40^FDT: {{talla}}  x{{cantidad}}^FS
^FO150,126^A0N,22,22^FB240,1,0,L^FD{{color}}^FS
^FO150,152^A0N,20,20^FB240,1,0,L^FDLote {{lote}}^FS
^FO10,186^GB380,2,2^FS
^FO10,196^A0N,20,20^FB380,1,0,L^FD{{partes}}  Capas {{capas}}^FS
^FO10,218^A0N,18,18^FDCorte {{corte}}  {{fecha}}^FS
^PQ{{copias}}
^XZ''';

const plantillaJuegoPorDefecto = '''^XA
^CI28
^PW400
^LL240
^LH0,0
^FO10,14^BQN,2,5^FDMA,{{codigo}}^FS
^FO150,14^A0N,30,30^FD{{codigo}}^FS
^FO150,50^A0N,24,24^FD{{op}}  {{referencia}}^FS
^FO150,80^A0N,40,40^FDT: {{talla}}  x{{cantidad}}^FS
^FO150,126^A0N,22,22^FB240,2,0,L^FD{{combinacion}}^FS
^FO10,186^GB380,2,2^FS
^FO10,196^A0N,18,18^FB380,2,0,L^FD{{paquetes}}^FS
^PQ{{copias}}
^XZ''';
