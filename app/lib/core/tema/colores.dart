import 'package:flutter/material.dart';

/// Paleta aprobada (sección 4 del prompt).
abstract final class Colores {
  static const fondo = Color(0xFFF4F4F1);
  static const tarjeta = Colors.white;
  static const borde = Color(0xFFE2E2DC);
  static const texto = Color(0xFF1A1A1A);
  static const textoSuave = Color(0xFF5F5F5A);
  static const menu = Color(0xFF1C1E21);
  static const menuTexto = Color(0xFFC9CBCF);
  static const menuActivo = Color(0xFF2E3238);

  // Semáforo
  static const verde = Color(0xFF2E7D4F);
  static const ambar = Color(0xFFC98A0B);
  static const rojo = Color(0xFFB3261E);

  // TV
  static const tvFondo = Color(0xFF0F1113);
  static const tvTarjeta = Color(0xFF1A1D21);

  /// Color por proceso (código de la tabla `procesos`).
  static const proceso = <String, Color>{
    'diseno': Color(0xFF6B4FA0),
    'corte': Color(0xFF1F5FA8),
    'estampacion': Color(0xFFB4521C),
    'bordado': Color(0xFFA3306B),
    'tejidos': Color(0xFF5C6B2E),
    'confeccion': Color(0xFF3F4A5A),
    'terminacion': Color(0xFF2F7A6A),
    'calidad': Color(0xFF4E7A1F),
  };

  static Color deProceso(String? codigo) => proceso[codigo] ?? textoSuave;

  /// Nombre para mostrar de un proceso a partir de su código.
  static String nombreProceso(String? codigo) => const {
        'diseno': 'Diseño', 'corte': 'Corte', 'estampacion': 'Estampación', 'bordado': 'Bordado', 'tejidos': 'Tejidos',
        'confeccion': 'Confección', 'terminacion': 'Terminación', 'calidad': 'Calidad',
      }[codigo] ?? codigo ?? '';

  /// Semáforo por eficiencia (%): ≥ meta verde, ≥ 85 % de la meta ámbar, resto rojo.
  static Color semaforo(double valor, {double meta = 100}) {
    if (valor >= meta) return verde;
    if (valor >= meta * 0.85) return ambar;
    return rojo;
  }
}
