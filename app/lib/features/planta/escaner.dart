import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/tema/tema.dart';

/// Abre la cámara y devuelve el primer QR leído (o null si se cancela).
Future<String?> escanearQr(BuildContext context, {String titulo = 'Escanear'}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => _PantallaEscaner(titulo: titulo)));

class _PantallaEscaner extends StatefulWidget {
  const _PantallaEscaner({required this.titulo});
  final String titulo;
  @override
  State<_PantallaEscaner> createState() => _PantallaEscanerState();
}

class _PantallaEscanerState extends State<_PantallaEscaner> {
  final _control = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  var _listo = false;

  @override
  void dispose() {
    _control.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.titulo, style: estilo(20, peso: FontWeight.w600, color: Colors.white)),
          actions: [
            IconButton(iconSize: 30, tooltip: 'Linterna', icon: const Icon(Icons.flashlight_on), onPressed: _control.toggleTorch),
            IconButton(iconSize: 30, tooltip: 'Cambiar cámara', icon: const Icon(Icons.cameraswitch), onPressed: _control.switchCamera),
          ],
        ),
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _control,
            errorBuilder: (_, e) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No se pudo abrir la cámara (${e.errorCode.name}). Revise el permiso de cámara.',
                    textAlign: TextAlign.center, style: estilo(18, color: Colors.white)),
              ),
            ),
            onDetect: (captura) {
              final v = captura.barcodes.firstOrNull?.rawValue;
              if (v == null || _listo) return;
              _listo = true;
              Navigator.of(context).pop(v);
            },
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Text('Ponga el código QR dentro del cuadro', textAlign: TextAlign.center, style: estilo(20, color: Colors.white)),
          ),
        ]),
      );
}
