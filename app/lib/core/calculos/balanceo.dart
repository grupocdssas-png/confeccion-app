/// Balanceo de célula (Dart puro).
///
/// * SAM total = Σ SAM × repeticiones de las operaciones del proceso que suman al SAM.
/// * Tiempo de ciclo = SAM total / operarios.
/// * Meta por hora = 60 × operarios × eficiencia / SAM total.
/// * Meta por turno = meta por hora × horas efectivas del turno.
/// * Días para terminar = prendas pendientes / meta por turno.
/// * Reparto automático: en orden de secuencia, cada puesto se llena hasta el
///   tiempo de ciclo (+ tolerancia). Si una operación no cabe completa, se
///   comparte entre dos puestos. Se respeta la máquina: si el puesto ya tiene al
///   menos el 75 % del ciclo, una operación de otra máquina empieza puesto nuevo;
///   si tiene menos, el operario atiende dos máquinas (las manuales caben en cualquiera).
/// * Carga de cada puesto, cuello de botella (el más cargado) y % de balance =
///   carga promedio / carga del cuello de botella.
///
/// El servidor calcula las mismas métricas (metricas_balanceo) sobre lo guardado;
/// ambos se prueban con test_vectores/balanceo.
library;

import 'dart:math' as math;

class OperacionBalanceo {
  const OperacionBalanceo({required this.id, required this.secuencia, required this.sam, this.repeticiones = 1, this.tipoMaquina, this.sumaSam = true});
  final String id;
  final int secuencia;
  final double sam;
  final double repeticiones;

  /// Código del tipo de máquina (PLA, FIL…). null o 'MAN' = manual (cabe en cualquier puesto).
  final String? tipoMaquina;
  final bool sumaSam;
  double get minutos => sam * repeticiones;
  bool get manual => tipoMaquina == null || tipoMaquina == 'MAN';
}

class Asignacion {
  const Asignacion(this.operacionId, this.fraccion, this.minutos);
  final String operacionId;
  final double fraccion; // 0–1
  final double minutos;
  Map<String, dynamic> aJson() => {'operacion_id': operacionId, 'fraccion': _r(fraccion, 4), 'minutos': _r(minutos, 4)};
}

class PuestoBalanceo {
  PuestoBalanceo(this.numero, {Set<String>? maquinas, List<Asignacion>? asignaciones})
      : maquinas = maquinas ?? <String>{},
        asignaciones = asignaciones ?? [];
  final int numero;

  /// Tipos de máquina que usa el puesto (sin las manuales)
  final Set<String> maquinas;
  final List<Asignacion> asignaciones;
  double get carga => asignaciones.fold(0.0, (a, x) => a + x.minutos);
  Map<String, dynamic> aJson() => {'numero': numero, 'maquinas': maquinas.toList(), 'asignaciones': [for (final a in asignaciones) a.aJson()]};
}

/// Desde qué carga del ciclo un cambio de máquina abre puesto nuevo
const umbralCambioMaquina = 0.75;

class MetricasBalanceo {
  const MetricasBalanceo({
    required this.samTotal,
    required this.ciclo,
    required this.metaHora,
    required this.metaTurno,
    required this.dias,
    required this.cargas,
    required this.cuello,
    required this.pctBalance,
    required this.metaHoraCuello,
  });
  final double samTotal, ciclo, metaHora, metaTurno;
  final double? dias;
  final List<double> cargas;
  final int? cuello; // número de puesto
  final double pctBalance;

  /// Lo que realmente sale por hora según el cuello de botella: 60 × eficiencia / carga del cuello
  final double metaHoraCuello;

  Map<String, dynamic> aJson() => {
        'sam_total': _r(samTotal, 4),
        'ciclo': _r(ciclo, 4),
        'meta_hora': _r(metaHora, 2),
        'meta_turno': _r(metaTurno, 1),
        'dias': dias == null ? null : _r(dias!, 2),
        'cargas': [for (final c in cargas) _r(c, 4)],
        'cuello': cuello,
        'pct_balance': _r(pctBalance, 1),
        'meta_hora_cuello': _r(metaHoraCuello, 2),
      };
}

/// Reparto automático. [tolerancia] 0,10 = un puesto puede pasar el ciclo hasta en 10 %.
List<PuestoBalanceo> balancear(List<OperacionBalanceo> operaciones, int operarios, {double tolerancia = 0.10}) {
  final ops = operaciones.where((o) => o.minutos > 0).toList()..sort((a, b) => a.secuencia.compareTo(b.secuencia));
  if (ops.isEmpty || operarios <= 0) return [];
  final total = ops.where((o) => o.sumaSam).fold(0.0, (a, o) => a + o.minutos);
  final ciclo = total / operarios;
  final limite = ciclo * (1 + tolerancia);
  final puestos = <PuestoBalanceo>[PuestoBalanceo(1)];
  var p = puestos.first;

  void nuevo() {
    p = PuestoBalanceo(puestos.length + 1);
    puestos.add(p);
  }

  bool ultimo() => puestos.length >= operarios;
  bool cambiaMaquina(OperacionBalanceo o) => !o.manual && p.maquinas.isNotEmpty && !p.maquinas.contains(o.tipoMaquina);
  void asignar(OperacionBalanceo o, double f, double m) {
    p.asignaciones.add(Asignacion(o.id, f, m));
    if (!o.manual) p.maquinas.add(o.tipoMaquina!);
  }

  for (final o in ops) {
    var resto = 1.0; // fracción de la operación por asignar
    while (resto > 1e-9) {
      final minutos = o.minutos * resto;
      if (cambiaMaquina(o) && p.carga >= ciclo * umbralCambioMaquina - 1e-9 && !ultimo()) {
        nuevo();
        continue;
      }
      if (p.carga + minutos <= limite + 1e-9 || ultimo()) {
        asignar(o, resto, minutos);
        resto = 0;
        break;
      }
      // no cabe completa: se llena el puesto hasta el ciclo y el resto sigue en el siguiente
      final espacio = ciclo - p.carga;
      if (espacio > o.minutos * 0.1) {
        final f = espacio / o.minutos;
        asignar(o, f, espacio);
        resto -= f;
      }
      nuevo();
    }
  }
  puestos.removeWhere((x) => x.asignaciones.isEmpty);
  return [for (var i = 0; i < puestos.length; i++) PuestoBalanceo(i + 1, maquinas: puestos[i].maquinas, asignaciones: puestos[i].asignaciones)];
}

/// Métricas de un balanceo (automático o ajustado a mano).
MetricasBalanceo metricas({
  required double samTotal,
  required int operarios,
  required double eficienciaPct,
  required double minutosTurno,
  required List<double> cargas,
  int? pendientes,
}) {
  final e = eficienciaPct / 100;
  final ciclo = operarios <= 0 ? 0.0 : samTotal / operarios;
  final metaHora = samTotal <= 0 ? 0.0 : 60 * operarios * e / samTotal;
  final metaTurno = metaHora * minutosTurno / 60;
  final maxCarga = cargas.isEmpty ? 0.0 : cargas.reduce(math.max);
  final prom = cargas.isEmpty ? 0.0 : cargas.fold(0.0, (a, c) => a + c) / cargas.length;
  return MetricasBalanceo(
    samTotal: samTotal,
    ciclo: ciclo,
    metaHora: metaHora,
    metaTurno: metaTurno,
    dias: pendientes == null || metaTurno <= 0 ? null : pendientes / metaTurno,
    cargas: cargas,
    cuello: cargas.isEmpty ? null : cargas.indexOf(maxCarga) + 1,
    pctBalance: maxCarga <= 0 ? 0 : prom / maxCarga * 100,
    metaHoraCuello: maxCarga <= 0 ? 0 : 60 * e / maxCarga,
  );
}

double _r(num v, int d) {
  final f = math.pow(10, d);
  return ((v.abs() * f + 1e-9).round() / f) * (v < 0 ? -1 : 1);
}
