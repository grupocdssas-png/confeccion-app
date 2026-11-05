/// Eficiencia de las marcaciones (Dart puro). La tablet la muestra al instante;
/// la oficial la calcula el servidor (fn_marcacion_oficial) con la misma regla:
///  * minutos esperados = SAM × repeticiones × unidades (reproceso: SAM de reproceso);
///  * minutos reales = desde la marcación anterior del mismo operario el mismo día;
///    si pasaron más de [maxMinutos] (pausa, almuerzo) no se mide;
///  * eficiencia % = esperados / reales × 100.
library;

double minutosEsperados({required double sam, double? samReproceso, required double repeticiones, required int unidades, bool reproceso = false}) =>
    _r((reproceso ? (samReproceso ?? sam) : sam) * repeticiones * unidades, 3);

/// null si no hay anterior, si es otro día (Bogotá) o si pasó más de [maxMinutos].
double? minutosReales(DateTime? anterior, DateTime actual, {double maxMinutos = 30}) {
  if (anterior == null) return null;
  if (_diaBogota(anterior) != _diaBogota(actual)) return null;
  final m = actual.difference(anterior).inMilliseconds / 60000;
  if (m <= 0 || m > maxMinutos) return null;
  return _r(m, 3);
}

double? eficiencia(double esperados, double? reales) => reales == null || reales <= 0 ? null : _r(esperados / reales * 100, 2);

class MarcacionResumen {
  const MarcacionResumen({required this.hora, required this.esperados, this.reales, this.unidades = 1, this.reproceso = false});
  final DateTime hora;
  final double esperados;
  final double? reales;
  final int unidades;
  final bool reproceso;
}

/// Eficiencia de un conjunto de marcaciones: solo cuentan las que tienen tiempo real.
double? eficienciaDe(Iterable<MarcacionResumen> ms) {
  var e = 0.0, r = 0.0;
  for (final m in ms) {
    if (m.reales == null) continue;
    e += m.esperados;
    r += m.reales!;
  }
  return r <= 0 ? null : _r(e / r * 100, 1);
}

DateTime _diaBogota(DateTime t) {
  final b = t.toUtc().subtract(const Duration(hours: 5));
  return DateTime.utc(b.year, b.month, b.day);
}

double _r(num v, int d) {
  var f = 1.0;
  for (var i = 0; i < d; i++) {
    f *= 10;
  }
  return (v * f + (v >= 0 ? 1e-9 : -1e-9)).round() / f;
}
