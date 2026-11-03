/// Los QR contienen SOLO un código corto con prefijo (sección 12 del prompt).
enum TipoCodigo {
  paquete('PQ'),
  juego('JG'),
  rollo('TL'),
  ubicacion('UB'),
  maquina('MAQ'),
  operario('OPR'),
  productoTerminado('PT');

  const TipoCodigo(this.prefijo);
  final String prefijo;
}

class CodigoLeido {
  const CodigoLeido(this.tipo, this.codigo);
  final TipoCodigo? tipo; // null = no reconocido
  final String codigo;
  @override
  String toString() => codigo;
}

/// Interpreta lo leído por la cámara o digitado: limpia espacios, pasa a mayúsculas
/// y reconoce el prefijo. Acepta "tl-12" → TL-000012 y "TL000012" → TL-000012.
CodigoLeido leerCodigo(String crudo) {
  final t = crudo.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  for (final tipo in TipoCodigo.values) {
    final p = tipo.prefijo;
    if (!t.startsWith(p)) continue;
    final resto = t.substring(p.length).replaceFirst(RegExp(r'^-'), '');
    if (resto.isEmpty) break;
    // Rollos: número puro → se rellena a 6 dígitos como los genera el servidor
    if (tipo == TipoCodigo.rollo && RegExp(r'^\d{1,6}$').hasMatch(resto)) {
      return CodigoLeido(tipo, 'TL-${resto.padLeft(6, '0')}');
    }
    return CodigoLeido(tipo, '$p-$resto');
  }
  return CodigoLeido(null, t);
}
