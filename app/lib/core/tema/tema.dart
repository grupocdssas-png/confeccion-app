import 'package:flutter/material.dart';

import 'colores.dart';

const _sans = 'IBMPlexSans';
const mono = 'IBMPlexMono';

/// La fuente es variable: además del FontWeight se fija el eje 'wght'.
TextStyle estilo(double tamano, {FontWeight peso = FontWeight.w400, Color? color, String familia = _sans, double? alto}) =>
    TextStyle(
      fontFamily: familia,
      fontSize: tamano,
      fontWeight: peso,
      fontVariations: [FontVariation('wght', peso.value.toDouble())],
      color: color,
      height: alto,
    );

/// Estilo para códigos (OP-000123, PQ-C02-000451…).
TextStyle estiloCodigo(double tamano, {Color? color, FontWeight peso = FontWeight.w600}) =>
    TextStyle(fontFamily: mono, fontSize: tamano, fontWeight: peso, color: color);

enum Modo { oficina, planta, tv }

ThemeData crearTema(Modo modo) {
  final oscuro = modo == Modo.tv;
  final escala = switch (modo) { Modo.oficina => 1.0, Modo.planta => 1.3, Modo.tv => 1.6 };
  final fondo = oscuro ? Colores.tvFondo : Colores.fondo;
  final texto = oscuro ? Colors.white : Colores.texto;
  final esquema = ColorScheme.fromSeed(
    seedColor: Colores.deProceso('confeccion'),
    brightness: oscuro ? Brightness.dark : Brightness.light,
  ).copyWith(surface: oscuro ? Colores.tvTarjeta : Colores.tarjeta, onSurface: texto, primary: Colores.texto, error: Colores.rojo);

  TextStyle s(double t, [FontWeight p = FontWeight.w400]) => estilo(t * escala, peso: p, color: texto);
  final alturaBoton = modo == Modo.planta ? 64.0 : 44.0;

  return ThemeData(
    useMaterial3: true,
    colorScheme: esquema,
    scaffoldBackgroundColor: fondo,
    fontFamily: _sans,
    textTheme: TextTheme(
      displaySmall: s(32, FontWeight.w600),
      headlineSmall: s(22, FontWeight.w600),
      titleLarge: s(18, FontWeight.w600),
      titleMedium: s(15, FontWeight.w600),
      bodyLarge: s(15),
      bodyMedium: s(14),
      bodySmall: s(12),
      labelLarge: s(14, FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: oscuro ? Colores.tvTarjeta : Colores.tarjeta,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: oscuro ? Colors.white12 : Colores.borde),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Colores.borde, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colores.texto,
        foregroundColor: Colors.white,
        minimumSize: Size(64, alturaBoton),
        textStyle: s(15, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: texto,
        minimumSize: Size(64, alturaBoton),
        side: const BorderSide(color: Colores.borde),
        textStyle: s(15, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: oscuro ? Colores.tvTarjeta : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colores.borde)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colores.borde)),
    ),
  );
}
