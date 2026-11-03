import 'package:intl/intl.dart';

/// Formato colombiano: 1.234,56 · COP · America/Bogota (UTC−5, sin horario de verano).
abstract final class Formato {
  static const _locale = 'es_CO';
  static final _numero2 = NumberFormat('#,##0.00', _locale);
  static final _entero = NumberFormat('#,##0', _locale);

  static String numero(num valor, {int decimales = 2}) =>
      decimales == 0 ? _entero.format(valor) : NumberFormat('#,##0.${'0' * decimales}', _locale).format(valor);
  static String dos(num valor) => _numero2.format(valor);
  static String cop(num valor) => '${valor < 0 ? '-' : ''}\$ ${_entero.format(valor.abs().round())}';
  static String porcentaje(num valor, {int decimales = 1}) => '${numero(valor, decimales: decimales)} %';

  /// Hora de Bogotá a partir de cualquier DateTime (la zona del dispositivo no importa).
  static DateTime aBogota(DateTime t) => t.toUtc().subtract(const Duration(hours: 5));
  static String hora(DateTime t) => DateFormat('HH:mm').format(aBogota(t));
  static String horaSeg(DateTime t) => DateFormat('HH:mm:ss').format(aBogota(t));
  static String fecha(DateTime t) => DateFormat('dd/MM/yyyy').format(aBogota(t));
  static String fechaHora(DateTime t) => DateFormat('dd/MM/yyyy HH:mm').format(aBogota(t));

  /// mm:ss para tiempos de marcación.
  static String mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Inicio del día de hoy en Bogotá, expresado en UTC (para filtros "de hoy").
  static DateTime inicioDiaBogota([DateTime? ahora]) {
    final b = aBogota(ahora ?? DateTime.now());
    return DateTime.utc(b.year, b.month, b.day).add(const Duration(hours: 5));
  }
}
