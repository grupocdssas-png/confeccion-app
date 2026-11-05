// Cálculos de calidad: muestreo por atributos (tabla por tamaño de lote),
// resultado de la auditoría y medidas contra la ficha. El servidor aplica
// la misma regla (supabase: muestreo, aplicar_inspeccion).

/// Un tramo del plan: lotes de [desde] a [hasta] (null = sin tope).
class TramoMuestreo {
  const TramoMuestreo({required this.desde, this.hasta, required this.muestra, required this.acepta});
  factory TramoMuestreo.fromJson(Map<String, dynamic> j) => TramoMuestreo(
      desde: (j['desde'] as num).toInt(), hasta: (j['hasta'] as num?)?.toInt(), muestra: (j['muestra'] as num).toInt(), acepta: (j['acepta'] as num).toInt());
  final int desde;
  final int? hasta;
  final int muestra;
  final int acepta;
}

/// Prendas a revisar y máximo de prendas con defecto para aprobar. La muestra nunca pasa del lote.
({int muestra, int acepta}) muestreo(List<TramoMuestreo> plan, int lote) {
  if (lote <= 0) throw ArgumentError('El lote debe tener prendas');
  final t = plan.where((t) => lote >= t.desde && (t.hasta == null || lote <= t.hasta!)).firstOrNull;
  if (t == null) throw ArgumentError('El plan de muestreo no cubre un lote de $lote');
  return (muestra: t.muestra < lote ? t.muestra : lote, acepta: t.acepta);
}

/// Auditoría final: aprobada si las prendas con defecto no pasan del número de aceptación.
bool auditoriaAprobada(List<TramoMuestreo> plan, int lote, int defectuosas) => defectuosas <= muestreo(plan, lote).acepta;

/// Una medida está fuera si se aleja del valor de la ficha más que la tolerancia.
bool medidaFuera(double valor, double esperado, double tolerancia) => (valor - esperado).abs() > tolerancia + 1e-9;

/// Prendas con defecto de una inspección: la suma de las líneas, más una si alguna medida
/// quedó fuera y no se anotó ya el defecto de medida.
int prendasConDefecto(Iterable<int> cantidades, {bool medidaFueraDeTolerancia = false, bool yaAnotoMedida = false}) =>
    cantidades.fold(0, (a, b) => a + b) + (medidaFueraDeTolerancia && !yaAnotoMedida ? 1 : 0);
