/// Motor de cálculo del corte (Dart puro, sin Flutter).
///
/// La app lo usa para mostrar en vivo lo que va a salir del tendido. La fuente
/// oficial es el servidor (funciones SQL `corte_calcular_bloque` y
/// `corte_plan_paquetes`), que hace exactamente las mismas cuentas: ambos se
/// prueban contra los mismos casos en `test_vectores/corte/*.json`.
///
/// Modelo
/// - Un **bloque** es un tendido sobre la mesa: un material, unas partes de la
///   prenda y un trazo.
/// - El **trazo** tiene 1 sección (tendido normal) o de 2 a 5 secciones (tendido
///   por **espigas**). La sección 0 es la cabecera (A).
/// - Con n secciones hay n espigas: la espiga k cubre las secciones 0..n−k
///   (la espiga 1 es el largo completo; la espiga n solo la cabecera).
///   Un tendido normal es el caso n = 1.
/// - Un **tramo** son las capas que salieron de un rollo en una espiga.
///   Las capas se numeran en orden: primero la espiga 1, luego la 2…
/// - metros de un tramo = capas × (largo de las secciones cubiertas + despunte).
/// - piezas de una talla en un tramo = capas × unidades de esa talla en las
///   secciones cubiertas.
library;

import 'dart:math' as math;

class SeccionTrazo {
  const SeccionTrazo({required this.letra, required this.largoM, required this.unidades});
  final String letra;
  final double largoM;

  /// talla → piezas de esa talla por capa en esta sección
  final Map<String, int> unidades;

  factory SeccionTrazo.desdeJson(Map<String, dynamic> j) => SeccionTrazo(
        letra: '${j['letra'] ?? ''}',
        largoM: _num(j['largo_m']).toDouble(),
        unidades: {for (final e in ((j['unidades'] as Map?) ?? {}).entries) '${e.key}': _num(e.value).toInt()},
      );

  Map<String, dynamic> aJson() => {'letra': letra, 'largo_m': largoM, 'unidades': unidades};
}

class TramoRollo {
  const TramoRollo({required this.rolloId, required this.colorId, this.lote, this.espiga = 1, required this.capas});
  final String rolloId;
  final String colorId;
  final String? lote;
  final int espiga;
  final int capas;

  factory TramoRollo.desdeJson(Map<String, dynamic> j) => TramoRollo(
        rolloId: '${j['rollo_id']}',
        colorId: '${j['color_id']}',
        lote: j['lote'] as String?,
        espiga: _num(j['espiga'] ?? 1).toInt(),
        capas: _num(j['capas']).toInt(),
      );

  Map<String, dynamic> aJson() => {'rollo_id': rolloId, 'color_id': colorId, 'lote': lote, 'espiga': espiga, 'capas': capas};

  TramoRollo copiar({String? colorId, String? lote, int? espiga, int? capas}) => TramoRollo(
      rolloId: rolloId, colorId: colorId ?? this.colorId, lote: lote ?? this.lote, espiga: espiga ?? this.espiga, capas: capas ?? this.capas);
}

class BloqueCorte {
  const BloqueCorte({required this.tallas, required this.secciones, required this.tramos});

  /// Orden de las tallas (para listar y para numerar los paquetes)
  final List<String> tallas;
  final List<SeccionTrazo> secciones;
  final List<TramoRollo> tramos;

  int get numEspigas => secciones.length;
  bool get esEspigas => secciones.length > 1;

  factory BloqueCorte.desdeJson(Map<String, dynamic> j) => BloqueCorte(
        tallas: [for (final t in (j['tallas'] as List? ?? const [])) '$t'],
        secciones: [for (final s in (j['secciones'] as List? ?? const [])) SeccionTrazo.desdeJson(Map<String, dynamic>.from(s as Map))],
        tramos: [for (final t in (j['tramos'] as List? ?? const [])) TramoRollo.desdeJson(Map<String, dynamic>.from(t as Map))],
      );

  /// Secciones que cubre la espiga k (1..n): 0..n−k
  Iterable<SeccionTrazo> seccionesDeEspiga(int k) => secciones.take(numEspigas - k + 1);

  /// Largo de una capa de la espiga k (m), sin despunte
  double largoEspiga(int k) => seccionesDeEspiga(k).fold(0.0, (a, s) => a + s.largoM);

  /// Piezas de la talla t por capa en la espiga k
  int piezasPorCapa(int k, String talla) => seccionesDeEspiga(k).fold(0, (a, s) => a + (s.unidades[talla] ?? 0));

  /// Tramos en orden de tendido: espiga 1 primero, luego 2… (estable)
  List<TramoRollo> get tramosOrdenados {
    final idx = [for (var i = 0; i < tramos.length; i++) i];
    idx.sort((a, b) {
      final c = tramos[a].espiga.compareTo(tramos[b].espiga);
      return c != 0 ? c : a.compareTo(b);
    });
    return [for (final i in idx) tramos[i]];
  }
}

class TramoCalculado {
  const TramoCalculado(this.tramo, this.capaDesde, this.capaHasta, this.metros);
  final TramoRollo tramo;
  final int capaDesde;
  final int capaHasta;
  final double metros;
}

class ResultadoBloque {
  const ResultadoBloque({
    required this.metros,
    required this.capasEspiga,
    required this.capasSeccion,
    required this.piezas,
    required this.metrosPorRollo,
    required this.tramos,
  });

  /// Metros totales tendidos (incluye el despunte de cada capa)
  final double metros;

  /// Capas por espiga (índice 0 = espiga 1)
  final List<int> capasEspiga;

  /// Capas que tiene cada sección del trazo (índice 0 = cabecera)
  final List<int> capasSeccion;

  /// color → talla → piezas
  final Map<String, Map<String, int>> piezas;
  final Map<String, double> metrosPorRollo;
  final List<TramoCalculado> tramos;

  int get capasTotales => capasEspiga.fold(0, (a, b) => a + b);

  /// talla → piezas de todos los colores
  Map<String, int> get piezasPorTalla {
    final r = <String, int>{};
    for (final c in piezas.values) {
      c.forEach((t, n) => r[t] = (r[t] ?? 0) + n);
    }
    return r;
  }

  Map<String, dynamic> aJson() => {
        'metros': metros,
        'capas_espiga': capasEspiga,
        'capas_seccion': capasSeccion,
        'piezas': piezas,
        'metros_por_rollo': metrosPorRollo,
      };
}

double redondear(num v, int decimales) {
  final f = math.pow(10, decimales);
  // + épsilon para que 0,125 → 0,13 como en PostgreSQL (redondeo "mitad hacia arriba")
  return ((v.abs() * f + 1e-9).round() / f) * (v < 0 ? -1 : 1);
}

/// Cálculo de un bloque. [despunteCm]: lo que se deja de más en cada capa.
ResultadoBloque calcularBloque(BloqueCorte b, {double despunteCm = 0}) {
  final n = b.numEspigas;
  if (n < 1 || n > 5) throw ArgumentError('El trazo debe tener de 1 a 5 secciones');
  final capasEspiga = List<int>.filled(n, 0);
  final piezas = <String, Map<String, int>>{};
  final porRollo = <String, double>{};
  final tramos = <TramoCalculado>[];
  var capa = 0;
  var metros = 0.0;
  for (final t in b.tramosOrdenados) {
    if (t.espiga < 1 || t.espiga > n) throw ArgumentError('La espiga ${t.espiga} no existe en un trazo de $n secciones');
    if (t.capas <= 0) continue;
    capasEspiga[t.espiga - 1] += t.capas;
    final m = redondear(t.capas * (b.largoEspiga(t.espiga) + despunteCm / 100), 2);
    metros += m;
    porRollo[t.rolloId] = redondear((porRollo[t.rolloId] ?? 0) + m, 2);
    final pc = piezas.putIfAbsent(t.colorId, () => {});
    for (final talla in b.tallas) {
      final u = b.piezasPorCapa(t.espiga, talla);
      if (u > 0) pc[talla] = (pc[talla] ?? 0) + t.capas * u;
    }
    tramos.add(TramoCalculado(t, capa + 1, capa + t.capas, m));
    capa += t.capas;
  }
  // capas de la sección i = capas de las espigas 1..n−i
  final capasSeccion = [for (var i = 0; i < n; i++) capasEspiga.take(n - i).fold(0, (a, c) => a + c)];
  return ResultadoBloque(
    metros: redondear(metros, 2),
    capasEspiga: capasEspiga,
    capasSeccion: capasSeccion,
    piezas: piezas,
    metrosPorRollo: porRollo,
    tramos: tramos,
  );
}

// ---------------------------------------------------------------------------
// Paquetes: nunca mezclan color, lote ni talla; máximo [maxPrendas] por paquete
// (parámetro max_prendas_paquete). Se arman por rangos de capas.
// ---------------------------------------------------------------------------
class PaquetePlan {
  const PaquetePlan({
    required this.colorId,
    required this.lote,
    required this.espiga,
    required this.talla,
    required this.capaDesde,
    required this.capaHasta,
    required this.cantidad,
  });
  final String colorId;
  final String? lote;
  final int espiga;
  final String talla;
  final int capaDesde;
  final int capaHasta;
  final int cantidad;

  Map<String, dynamic> aJson() => {
        'color_id': colorId,
        'lote': lote,
        'espiga': espiga,
        'talla': talla,
        'capa_desde': capaDesde,
        'capa_hasta': capaHasta,
        'cantidad': cantidad,
      };
}

List<PaquetePlan> planPaquetes(BloqueCorte b, {int maxPrendas = 20}) {
  final r = calcularBloque(b);
  // Une tramos seguidos con el mismo color, lote y espiga (p. ej. dos rollos del mismo lote)
  final corridas = <({String color, String? lote, int espiga, int desde, int hasta})>[];
  for (final t in r.tramos) {
    final u = corridas.isEmpty ? null : corridas.last;
    if (u != null && u.color == t.tramo.colorId && u.lote == t.tramo.lote && u.espiga == t.tramo.espiga && u.hasta + 1 == t.capaDesde) {
      corridas[corridas.length - 1] = (color: u.color, lote: u.lote, espiga: u.espiga, desde: u.desde, hasta: t.capaHasta);
    } else {
      corridas.add((color: t.tramo.colorId, lote: t.tramo.lote, espiga: t.tramo.espiga, desde: t.capaDesde, hasta: t.capaHasta));
    }
  }
  final paquetes = <PaquetePlan>[];
  for (final c in corridas) {
    for (final talla in b.tallas) {
      final p = b.piezasPorCapa(c.espiga, talla);
      if (p <= 0) continue;
      final capasPorPaquete = math.max(1, maxPrendas ~/ p);
      for (var desde = c.desde; desde <= c.hasta; desde += capasPorPaquete) {
        final hasta = math.min(c.hasta, desde + capasPorPaquete - 1);
        paquetes.add(PaquetePlan(
            colorId: c.color, lote: c.lote, espiga: c.espiga, talla: talla, capaDesde: desde, capaHasta: hasta, cantidad: (hasta - desde + 1) * p));
      }
    }
  }
  return paquetes;
}

// ---------------------------------------------------------------------------
// Sugerencias para planear el tendido (solo ayudas; el cortador decide)
// ---------------------------------------------------------------------------

/// Tendido normal: capas para cubrir la demanda (talla → prendas).
/// Devuelve null si alguna talla con demanda no está en el trazo.
int? sugerirCapasNormal(Map<String, int> unidades, Map<String, int> demanda) {
  var capas = 0;
  for (final e in demanda.entries) {
    if (e.value <= 0) continue;
    final u = unidades[e.key] ?? 0;
    if (u <= 0) return null;
    capas = math.max(capas, (e.value / u).ceil());
  }
  return capas;
}

/// Capas que necesita cada sección para cubrir la demanda. Una talla repartida
/// en varias secciones se reparte por igual (aproximación).
List<int> capasRequeridasPorSeccion(List<SeccionTrazo> secciones, Map<String, int> demanda) {
  final total = <String, int>{};
  for (final s in secciones) {
    s.unidades.forEach((t, u) => total[t] = (total[t] ?? 0) + u);
  }
  return [
    for (final s in secciones)
      s.unidades.entries
          .where((e) => e.value > 0 && (demanda[e.key] ?? 0) > 0)
          .fold(0, (a, e) => math.max(a, ((demanda[e.key] ?? 0) / total[e.key]!).ceil())),
  ];
}

/// Ordena las secciones de mayor a menor necesidad: la cabecera (A) debe ser
/// la que más capas necesita. Reasigna las letras A, B, C…
List<SeccionTrazo> ordenarPorDemanda(List<SeccionTrazo> secciones, Map<String, int> demanda) {
  final req = capasRequeridasPorSeccion(secciones, demanda);
  final idx = [for (var i = 0; i < secciones.length; i++) i]..sort((a, b) {
      final c = req[b].compareTo(req[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  return [
    for (var j = 0; j < idx.length; j++)
      SeccionTrazo(letra: String.fromCharCode(65 + j), largoM: secciones[idx[j]].largoM, unidades: secciones[idx[j]].unidades),
  ];
}

/// Capas por espiga (índice 0 = espiga 1) para que cada sección tenga al menos
/// lo requerido: la sección i recibe las espigas 1..n−i.
List<int> sugerirEspigas(List<SeccionTrazo> secciones, Map<String, int> demanda) {
  final req = capasRequeridasPorSeccion(secciones, demanda);
  final n = req.length;
  final c = List<int>.filled(n, 0);
  c[0] = req[n - 1];
  var acumulado = c[0];
  for (var i = n - 2; i >= 0; i--) {
    final k = n - i; // espiga que empieza a cubrir la sección i
    c[k - 1] = math.max(0, req[i] - acumulado);
    acumulado += c[k - 1];
  }
  return c;
}

/// Reparte las capas sugeridas entre rollos (en el orden dado: primero los del
/// mismo lote) sin pasar el saldo de cada uno. Las capas largas (espiga 1) se
/// ponen primero. Devuelve los tramos y las capas que no alcanzaron.
({List<({String rolloId, int espiga, int capas})> tramos, int sinRollo}) repartirCapas({
  required List<({String id, double metros})> rollos,
  required List<int> capasPorEspiga,
  required List<double> metrosPorCapa,
}) {
  final saldo = {for (final r in rollos) r.id: r.metros};
  final tramos = <({String rolloId, int espiga, int capas})>[];
  var sinRollo = 0;
  for (var e = 0; e < capasPorEspiga.length; e++) {
    var falta = capasPorEspiga[e];
    final m = metrosPorCapa[e];
    if (falta <= 0 || m <= 0) continue;
    for (final r in rollos) {
      if (falta <= 0) break;
      final caben = ((saldo[r.id]! + 1e-9) / m).floor();
      if (caben <= 0) continue;
      final n = math.min(caben, falta);
      tramos.add((rolloId: r.id, espiga: e + 1, capas: n));
      saldo[r.id] = saldo[r.id]! - n * m;
      falta -= n;
    }
    sinRollo += falta;
  }
  return (tramos: tramos, sinRollo: sinRollo);
}

// ---------------------------------------------------------------------------
// Pedido vs cortado y consumo
// ---------------------------------------------------------------------------
class ComparacionTalla {
  const ComparacionTalla(this.talla, this.pedido, this.cortado);
  final String talla;
  final int pedido;
  final int cortado;
  int get diferencia => cortado - pedido;
  bool get faltan => diferencia < 0;
  bool get sobran => diferencia > 0;
}

List<ComparacionTalla> compararPedidoCortado(List<String> tallas, Map<String, int> pedido, Map<String, int> cortado) => [
      for (final t in tallas)
        if ((pedido[t] ?? 0) > 0 || (cortado[t] ?? 0) > 0) ComparacionTalla(t, pedido[t] ?? 0, cortado[t] ?? 0),
    ];

/// Consumo teórico (unidad del material) = Σ piezas × consumo por prenda de la
/// talla (ya con merma, sumando las partes del bloque).
double consumoTeorico(Map<String, int> piezasPorTalla, Map<String, double> consumoPorTalla) =>
    redondear(piezasPorTalla.entries.fold(0.0, (a, e) => a + e.value * (consumoPorTalla[e.key] ?? 0)), 3);

/// Desviación de consumo: (real − teórico) / teórico. null si no hay teórico.
double? desviacion(double real, double teorico) => teorico <= 0 ? null : (real - teorico) / teorico;

/// Kilos que corresponden a unos metros de un rollo (proporción del propio rollo;
/// si el rollo no tiene metros, con el rendimiento del material).
double kilosDeMetros(double metros, {required double metrosSaldo, required double kilosSaldo, double? rendimientoMKg}) {
  if (metrosSaldo > 0) return redondear(metros * kilosSaldo / metrosSaldo, 3);
  if (rendimientoMKg != null && rendimientoMKg > 0) return redondear(metros / rendimientoMKg, 3);
  return 0;
}

num _num(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
