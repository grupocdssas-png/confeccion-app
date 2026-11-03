import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:xml/xml.dart';

/// Tabla leída de un archivo. [decimalComa]: los números vienen como "1.234,5"
/// (CSV de Excel en español, separado por ";"). En .xlsx los números vienen en
/// formato interno (punto decimal) y no hay ambigüedad.
class TablaLeida {
  const TablaLeida(this.filas, {this.decimalComa = false});
  final List<List<String>> filas;
  final bool decimalComa;
}

/// Lee la primera hoja de un .xlsx o un .csv (separado por "," o ";", con o
/// sin BOM, UTF-8 o Latin-1). La primera fila son los encabezados.
TablaLeida leerTablaArchivo(Uint8List bytes, String nombreArchivo) {
  final n = nombreArchivo.toLowerCase();
  if (n.endsWith('.xlsx')) return TablaLeida(_leerXlsx(bytes));
  if (n.endsWith('.csv') || n.endsWith('.txt')) {
    final (filas, sep) = _leerCsv(bytes);
    return TablaLeida(filas, decimalComa: sep == ';');
  }
  throw FormatException('Formato no soportado: use .xlsx o .csv (en Excel: Guardar como → CSV UTF-8). Archivo: $nombreArchivo');
}

List<List<String>> leerTabla(Uint8List bytes, String nombreArchivo) => leerTablaArchivo(bytes, nombreArchivo).filas;

(List<List<String>>, String) _leerCsv(Uint8List bytes) {
  String texto;
  try {
    texto = utf8.decode(bytes);
  } on FormatException {
    texto = latin1.decode(bytes); // CSV guardado por Excel en Windows
  }
  if (texto.startsWith('﻿')) texto = texto.substring(1);
  final primera = texto.split(RegExp(r'\r?\n')).first;
  final sep = ';'.allMatches(primera).length > ','.allMatches(primera).length ? ';' : ',';
  final filas = Csv(fieldDelimiter: sep, autoDetect: false).decode(texto);
  return ([for (final f in filas) [for (final c in f) '$c'.trim()]].where((f) => f.any((c) => c.isNotEmpty)).toList(), sep);
}

List<List<String>> _leerXlsx(Uint8List bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  String? leer(String ruta) {
    final f = zip.findFile(ruta);
    return f == null ? null : utf8.decode(f.content as List<int>);
  }

  // Textos compartidos
  final compartidos = <String>[];
  final ss = leer('xl/sharedStrings.xml');
  if (ss != null) {
    for (final si in XmlDocument.parse(ss).findAllElements('si')) {
      compartidos.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }
  // Primera hoja según el libro
  var rutaHoja = 'xl/worksheets/sheet1.xml';
  final libro = leer('xl/workbook.xml');
  final rels = leer('xl/_rels/workbook.xml.rels');
  if (libro != null && rels != null) {
    final hoja = XmlDocument.parse(libro).findAllElements('sheet').firstOrNull;
    final rid = hoja?.attributes.where((a) => a.name.local == 'id').firstOrNull?.value;
    final rel = XmlDocument.parse(rels).findAllElements('Relationship').where((r) => r.getAttribute('Id') == rid).firstOrNull;
    final destino = rel?.getAttribute('Target');
    if (destino != null) rutaHoja = destino.startsWith('/') ? destino.substring(1) : 'xl/$destino';
  }
  final xml = leer(rutaHoja);
  if (xml == null) throw const FormatException('El archivo .xlsx no tiene hojas');

  final filas = <List<String>>[];
  for (final row in XmlDocument.parse(xml).findAllElements('row')) {
    final fila = <String>[];
    for (final c in row.findElements('c')) {
      final ref = c.getAttribute('r') ?? '';
      final col = _columna(ref);
      while (fila.length < col) {
        fila.add('');
      }
      final tipo = c.getAttribute('t');
      final v = c.getElement('v')?.innerText;
      final valor = switch (tipo) {
        's' => v == null ? '' : compartidos[int.parse(v)],
        'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
        'b' => v == '1' ? 'true' : 'false',
        _ => _numero(v ?? ''),
      };
      fila.add(valor.trim());
    }
    if (fila.any((x) => x.isNotEmpty)) filas.add(fila);
  }
  final ancho = filas.fold<int>(0, (a, f) => f.length > a ? f.length : a);
  return [for (final f in filas) [...f, ...List.filled(ancho - f.length, '')]];
}

/// "B12" → 1 (columna base 0)
int _columna(String ref) {
  var n = 0;
  for (final ch in ref.codeUnits) {
    if (ch < 65 || ch > 90) break;
    n = n * 26 + (ch - 64);
  }
  return n == 0 ? 0 : n - 1;
}

/// Excel guarda 0.35 como "0.35000000000000003": se limpia el ruido de coma flotante.
String _numero(String v) {
  final d = double.tryParse(v);
  if (d == null) return v;
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
  return double.parse(d.toStringAsFixed(10)).toString();
}

// ---------------------------------------------------------------------
// Campos que entiende cada importación y nombres de columna reconocidos
// ---------------------------------------------------------------------
class CampoImportacion {
  const CampoImportacion(this.clave, this.nombre, this.sinonimos, {this.obligatorio = false, this.numero = false});
  final String clave, nombre;
  final List<String> sinonimos;
  final bool obligatorio, numero;
}

const camposImportacion = <String, List<CampoImportacion>>{
  'operaciones': [
    CampoImportacion('codigo', 'Código', ['codigo', 'cod', 'cod operacion', 'codigo operacion', 'id operacion'], obligatorio: true),
    CampoImportacion('nombre', 'Nombre', ['nombre', 'operacion', 'descripcion', 'nombre operacion', 'desc'], obligatorio: true),
    CampoImportacion('sam', 'SAM (minutos)', ['sam', 'tiempo estandar', 'minutos', 'tiempo', 'min estandar', 'samm', 'tiempo std'], obligatorio: true, numero: true),
    CampoImportacion('valor_destajo', 'Valor a destajo', ['valor', 'valor destajo', 'tarifa', 'precio', 'valor unidad', 'destajo'], numero: true),
    CampoImportacion('maquina', 'Máquina', ['maquina', 'tipo maquina', 'equipo', 'cod maquina']),
    CampoImportacion('familia', 'Familia', ['familia', 'familia producto', 'linea']),
    CampoImportacion('tipo_producto', 'Tipo de producto', ['tipo producto', 'tipo', 'producto']),
    CampoImportacion('parte', 'Parte', ['parte', 'pieza', 'zona']),
    CampoImportacion('proceso', 'Proceso', ['proceso', 'area', 'seccion']),
    CampoImportacion('repeticiones', 'Repeticiones', ['repeticiones', 'rep', 'veces', 'frecuencia'], numero: true),
  ],
  'celulas': [
    CampoImportacion('codigo', 'Código', ['codigo', 'cod', 'modulo', 'celula', 'cod modulo'], obligatorio: true),
    CampoImportacion('nombre', 'Nombre', ['nombre', 'descripcion', 'nombre modulo'], obligatorio: true),
    CampoImportacion('proceso', 'Proceso', ['proceso', 'tipo']),
    CampoImportacion('area', 'Área', ['area', 'seccion']),
    CampoImportacion('turno', 'Turno', ['turno', 'jornada']),
  ],
  'empleados': [
    CampoImportacion('codigo', 'Código', ['codigo', 'cod', 'cod empleado', 'ficha', 'carnet'], obligatorio: true),
    CampoImportacion('documento', 'Documento', ['documento', 'cedula', 'cc', 'identificacion', 'nit']),
    CampoImportacion('nombres', 'Nombres', ['nombres', 'nombre', 'nombre completo'], obligatorio: true),
    CampoImportacion('apellidos', 'Apellidos', ['apellidos', 'apellido']),
    CampoImportacion('celula', 'Célula / módulo', ['celula', 'modulo', 'cod modulo', 'grupo']),
    CampoImportacion('cargo', 'Cargo', ['cargo', 'oficio']),
    CampoImportacion('fecha_ingreso', 'Fecha de ingreso', ['fecha ingreso', 'ingreso', 'fecha']),
  ],
  'maquinas': [
    CampoImportacion('codigo', 'Código', ['codigo', 'cod', 'activo', 'placa', 'cod maquina'], obligatorio: true),
    CampoImportacion('tipo', 'Tipo de máquina', ['tipo', 'tipo maquina', 'clase', 'maquina'], obligatorio: true),
    CampoImportacion('marca', 'Marca', ['marca']),
    CampoImportacion('modelo', 'Modelo', ['modelo', 'referencia']),
    CampoImportacion('serie', 'Serie', ['serie', 'serial', 'no serie']),
    CampoImportacion('celula', 'Célula / módulo', ['celula', 'modulo', 'ubicacion']),
  ],
};

String normalizarEncabezado(String s) {
  const de = 'áéíóúüñÁÉÍÓÚÜÑ';
  const a = 'aeiouunAEIOUUN';
  var t = s.trim();
  for (var i = 0; i < de.length; i++) {
    t = t.replaceAll(de[i], a[i]);
  }
  return t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

/// Relaciona cada campo con el índice de la columna cuyo encabezado coincide.
Map<String, int?> autoMapear(String tipo, List<String> encabezados) {
  final norm = [for (final e in encabezados) normalizarEncabezado(e)];
  final usados = <int>{};
  final r = <String, int?>{};
  for (final c in camposImportacion[tipo]!) {
    int? idx;
    for (final s in c.sinonimos) {
      final i = norm.indexWhere((h) => h == s);
      if (i >= 0 && !usados.contains(i)) {
        idx = i;
        break;
      }
    }
    r[c.clave] = idx;
    if (idx != null) usados.add(idx);
  }
  return r;
}

/// Número en el formato que entiende la base ("1234.5").
/// Con [decimalComa]: "1.234,5" → 1234.5 y "1.250" → 1250.
/// Sin él: "1234.5" o "1,234.5" → 1234.5; "0,35" (solo coma) → 0.35.
String? numeroNormalizado(String v, {bool decimalComa = false}) {
  final s = v.trim().replaceAll(RegExp(r'[\s$]'), '');
  if (s.isEmpty) return null;
  final String t;
  if (decimalComa) {
    t = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (s.contains(',') && !s.contains('.')) {
    t = s.replaceAll(',', '.');
  } else {
    t = s.replaceAll(',', '');
  }
  return double.tryParse(t) == null ? null : t;
}

/// Convierte filas (sin encabezado) a objetos según el mapeo.
List<Map<String, String?>> construirFilas(String tipo, List<List<String>> filas, Map<String, int?> mapeo, {bool decimalComa = false}) => [
      for (final f in filas)
        {
          for (final c in camposImportacion[tipo]!)
            if (mapeo[c.clave] != null)
              c.clave: () {
                final v = mapeo[c.clave]! < f.length ? f[mapeo[c.clave]!] : '';
                if (v.isEmpty) return null;
                return c.numero ? (numeroNormalizado(v, decimalComa: decimalComa) ?? v) : v;
              }(),
        },
    ];
