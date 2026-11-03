import 'dart:convert';
import 'dart:io';

import 'package:confeccion/core/escaneo/codigos.dart';
import 'package:confeccion/core/etiquetas/cola_impresion.dart';
import 'package:confeccion/core/etiquetas/transporte.dart';
import 'package:confeccion/core/etiquetas/zpl.dart';
import 'package:confeccion/core/sync/bandeja.dart';
import 'package:confeccion/core/sync/esquema_local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:powersync/powersync.dart';

/// "Impresora" Zebra simulada: escucha TCP y guarda lo que recibe.
class ZebraSimulada {
  late ServerSocket servidor;
  final recibido = <String>[];
  Future<int> iniciar([int puerto = 0]) async {
    servidor = await ServerSocket.bind(InternetAddress.loopbackIPv4, puerto);
    servidor.listen((s) async => recibido.add(utf8.decode(await s.fold<List<int>>([], (a, b) => a..addAll(b)))));
    return servidor.port;
  }

  Future<void> detener() => servidor.close();
}

void main() {
  setUpAll(() => initializeDateFormatting('es_CO'));

  group('Códigos QR con prefijo', () {
    test('reconoce cada prefijo', () {
      expect(leerCodigo('TL-000123').tipo, TipoCodigo.rollo);
      expect(leerCodigo(' ub-bt-a01 ').codigo, 'UB-BT-A01');
      expect(leerCodigo('UB-BT-A01').tipo, TipoCodigo.ubicacion);
      expect(leerCodigo('OPR-0001').tipo, TipoCodigo.operario);
      expect(leerCodigo('MAQ-003').tipo, TipoCodigo.maquina);
      expect(leerCodigo('PQ-C02-000451').tipo, TipoCodigo.paquete);
      expect(leerCodigo('XYZ').tipo, isNull);
    });
    test('rollo digitado sin ceros ni guion', () {
      expect(leerCodigo('tl12').codigo, 'TL-000012');
      expect(leerCodigo('TL-7').codigo, 'TL-000007');
    });
  });

  group('ZPL', () {
    final datos = datosEtiquetaRollo(
      codigo: 'TL-000123', tela: 'Jersey 30/1 algodón', color: 'Negro', lote: 'L-2410-N1', tono: 'A',
      anchoCm: 180.5, metros: 77.28, kilos: 22.4, proveedor: 'Textiles Ejemplo', fechaIngreso: DateTime(2026, 11, 3),
      ubicacion: 'UB-BT-A01',
    );
    final zpl = renderizarZpl(plantillaRolloPorDefecto, datos);

    test('etiqueta de rollo 100 × 50 mm a 203 dpi, UTF-8 y QR modelo 2 corrección M', () {
      expect(zpl, startsWith('^XA'));
      expect(zpl.trim(), endsWith('^XZ'));
      expect(zpl, contains('^CI28'));
      expect(zpl, contains('^PW800'));
      expect(zpl, contains('^LL400'));
      expect(zpl, contains('^BQN,2,11^FDMA,TL-000123^FS'), reason: 'el QR lleva SOLO el código');
    });
    test('datos con formato colombiano y tildes', () {
      expect(zpl, contains('Ancho: 180,5 cm'));
      expect(zpl, contains('77,28 m   22,40 kg'));
      expect(zpl, contains('Jersey 30/1 algodón'));
      expect(zpl, contains('Ingreso: 03/11/2026'));
      expect(zpl, isNot(contains('{{')));
    });
    test('un dato con ^ o ~ no rompe la etiqueta', () {
      final z = renderizarZpl('^XA^CI28^FD{{tela}}^FS^XZ', {'tela': 'Tela ^XZ rara ~JA'});
      expect(z, '^XA^CI28^FDTela -XZ rara -JA^FS^XZ');
    });
    test('copias y campos faltantes', () {
      expect(renderizarZpl('^PQ{{copias}}{{nada}}', {}, copias: 3), '^PQ3');
    });
    test('el QR mide unos 29 mm: 21 módulos × 11 puntos a 203 dpi', () {
      expect(21 * 11 / 203 * 25.4, closeTo(29, 0.5));
    });
  });

  group('Envío TCP al puerto de la impresora', () {
    test('llega el ZPL completo', () async {
      final zebra = ZebraSimulada();
      final puerto = await zebra.iniciar();
      await enviarZplTcp('127.0.0.1', puerto, '^XA^CI28^FDÑandú^FS^XZ');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(zebra.recibido.single, '^XA^CI28^FDÑandú^FS^XZ');
      await zebra.detener();
    });
  });

  group('Cola de impresión local', () {
    late Directory dir;
    late PowerSyncDatabase db;
    var ahora = DateTime.utc(2026, 11, 3, 12);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cola');
      db = PowerSyncDatabase(schema: esquemaLocal, path: '${dir.path}/c.db');
      await db.initialize();
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('impresora apagada: no se pierde, reintenta y al encenderla imprime en orden', () async {
      // Reservamos un puerto y lo liberamos para que la "impresora" esté apagada
      final tmp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final puerto = tmp.port;
      await tmp.close();
      final cola = ColaImpresion(db, Bandeja(db, reloj: () => ahora), reloj: () => ahora,
          enviar: (h, p, z) => enviarZplTcp(h, p, z, espera: const Duration(seconds: 1)));
      final imp = ImpresoraLocal(id: 'imp-1', nombre: 'Zebra bodega', conexion: 'tcp', ip: '127.0.0.1', puerto: puerto);

      await cola.encolar(impresora: imp, zpl: '^XA^FD1^FS^XZ', entidad: 'rollos', codigo: 'TL-000001');
      await cola.encolar(impresora: imp, zpl: '^XA^FD2^FS^XZ', entidad: 'rollos', codigo: 'TL-000002');
      await cola.procesar();
      final fallidas = await db.getAll('SELECT * FROM cola_impresion ORDER BY creado_en');
      expect(fallidas.every((t) => t['estado'] == 'pendiente' && t['error'] != null), isTrue);

      final zebra = ZebraSimulada();
      await zebra.iniciar(puerto);
      ahora = ahora.add(const Duration(minutes: 1)); // pasó la espera de reintento
      expect(await cola.procesar(), 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(zebra.recibido, ['^XA^FD1^FS^XZ', '^XA^FD2^FS^XZ']);
      final crud = await db.getCrudBatch();
      expect(crud!.crud.where((e) => e.table == 'trabajos_impresion').length, 2, reason: 'se registra cada impresión');
      await zebra.detener();
    });

    test('reimpresión sin motivo no se permite', () async {
      final cola = ColaImpresion(db, Bandeja(db));
      const imp = ImpresoraLocal(id: 'i', nombre: 'Z', conexion: 'tcp', ip: '127.0.0.1');
      expect(() => cola.encolar(impresora: imp, zpl: '^XA^XZ', entidad: 'rollos', codigo: 'TL-1', esReimpresion: true),
          throwsArgumentError);
    });
  });
}
