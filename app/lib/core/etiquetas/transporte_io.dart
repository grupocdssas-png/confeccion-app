import 'dart:convert';
import 'dart:io';

Future<void> enviarZplTcp(String host, int puerto, String zpl, {required Duration espera}) async {
  final socket = await Socket.connect(host, puerto, timeout: espera);
  try {
    socket.add(utf8.encode(zpl));
    await socket.flush().timeout(espera);
  } finally {
    await socket.close();
    socket.destroy();
  }
}
