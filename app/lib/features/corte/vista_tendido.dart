import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/calculos/corte.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

/// Vista lateral del tendido: el largo de cada espiga (sección A a la
/// izquierda) y las capas apiladas, con el color de cada rollo.
class VistaTendido extends StatelessWidget {
  const VistaTendido({super.key, required this.bloque, required this.resultado, required this.colorHex});
  final BloqueCorte bloque;
  final ResultadoBloque resultado;
  final String? Function(String colorId) colorHex;

  @override
  Widget build(BuildContext context) {
    if (resultado.capasTotales == 0 || bloque.largoEspiga(1) <= 0) {
      return Container(
        height: 90,
        alignment: Alignment.center,
        decoration: BoxDecoration(border: Border.all(color: Colores.borde), borderRadius: BorderRadius.circular(6)),
        child: Text('Ingrese el largo del trazo y las capas para ver el tendido', style: estilo(13, color: Colores.textoSuave)),
      );
    }
    return SizedBox(
      height: 150,
      child: CustomPaint(painter: _Pintor(bloque, resultado, colorHex), size: Size.infinite),
    );
  }
}

class _Pintor extends CustomPainter {
  _Pintor(this.b, this.r, this.hex);
  final BloqueCorte b;
  final ResultadoBloque r;
  final String? Function(String) hex;

  Color _color(String id) {
    final h = hex(id);
    if (h == null) return Colores.deProceso('corte');
    return Color(int.parse('FF${h.replaceFirst('#', '')}', radix: 16));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const arriba = 18.0, abajo = 20.0, izq = 4.0;
    final ancho = size.width - izq * 2;
    final alto = size.height - arriba - abajo;
    final largo = b.largoEspiga(1);
    final escalaX = ancho / largo;
    final capas = math.max(1, r.capasTotales);
    final altoCapa = alto / capas;
    final borde = Paint()
      ..color = Colores.texto.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    // capas: espiga 1 abajo; cada tramo un bloque de su color
    var y = arriba + alto;
    for (final t in r.tramos) {
      final w = b.largoEspiga(t.tramo.espiga) * escalaX;
      final h = t.tramo.capas * altoCapa;
      final rect = Rect.fromLTWH(izq, y - h, w, h);
      canvas.drawRect(rect, Paint()..color = _color(t.tramo.colorId).withValues(alpha: 0.85));
      canvas.drawRect(rect, borde);
      if (h > 13 && w > 60) {
        _texto(canvas, '${t.tramo.capas} capas', Offset(izq + 6, y - h / 2 - 7), 11,
            _color(t.tramo.colorId).computeLuminance() > 0.5 ? Colores.texto : Colors.white);
      }
      y -= h;
    }
    // secciones (líneas y letras)
    var x = izq;
    final linea = Paint()
      ..color = Colores.texto.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final s in b.secciones) {
      final w = s.largoM * escalaX;
      _texto(canvas, '${s.letra} · ${Formato.numero(s.largoM)} m', Offset(x + 4, 0), 11, Colores.textoSuave);
      x += w;
      canvas.drawLine(Offset(x, arriba - 2), Offset(x, arriba + alto), linea);
    }
    _texto(canvas, '${r.capasTotales} capas · ${Formato.numero(r.metros)} m tendidos', Offset(izq, size.height - 15), 11, Colores.textoSuave);
  }

  void _texto(Canvas c, String t, Offset o, double tam, Color color) {
    final p = TextPainter(text: TextSpan(text: t, style: estilo(tam, peso: FontWeight.w600, color: color)), textDirection: TextDirection.ltr)..layout();
    p.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _Pintor old) => true;
}
