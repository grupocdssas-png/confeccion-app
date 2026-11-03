import 'transporte_stub.dart' if (dart.library.io) 'transporte_io.dart' as impl;

/// Envía ZPL crudo a una Zebra por la red local (TCP, puerto 9100).
/// Funciona sin internet: solo necesita el wifi de la planta.
Future<void> enviarZplTcp(String host, int puerto, String zpl, {Duration espera = const Duration(seconds: 6)}) =>
    impl.enviarZplTcp(host, puerto, zpl, espera: espera);
