import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Resultado de una consulta del panel web: los datos y, si vienen de la
/// copia guardada por falta de conexión, la hora en que se guardaron.
class ConCache<T> {
  const ConCache(this.datos, {this.guardadoEn});
  final T datos;
  final DateTime? guardadoEn;
  bool get esCopia => guardadoEn != null;
}

/// Ejecuta la consulta; si funciona, guarda una copia. Si falla (sin internet),
/// devuelve la última copia. El panel y la TV siguen mostrando el último dato.
Future<ConCache<List<Map<String, dynamic>>>> consultarConCache(
  SharedPreferences prefs,
  String clave,
  Future<List<Map<String, dynamic>>> Function() consulta,
) async {
  final k = 'cache:$clave';
  try {
    final datos = await consulta();
    await prefs.setString(k, jsonEncode({'t': DateTime.now().toUtc().toIso8601String(), 'd': datos}));
    return ConCache(datos);
  } catch (e) {
    final g = prefs.getString(k);
    if (g == null) rethrow;
    final j = jsonDecode(g) as Map<String, dynamic>;
    return ConCache(
      [for (final r in j['d'] as List) Map<String, dynamic>.from(r as Map)],
      guardadoEn: DateTime.parse(j['t'] as String),
    );
  }
}
