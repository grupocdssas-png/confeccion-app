import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/arranque.dart';
import 'core/auth/sesion.dart';
import 'core/router/router_planta.dart';
import 'core/sync/proveedores_sync.dart';
import 'core/tema/tema.dart';
import 'features/bodega/repositorio_bodega.dart';

/// App Android de planta (tablets y celulares): trabaja siempre contra la base
/// local y sincroniza con el servidor cuando hay señal.
Future<void> main() async {
  final prefs = await arrancarComun();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); // pantalla completa
  final db = await abrirBaseLocal();
  runApp(ProviderScope(
    overrides: [prefsProvider.overrideWithValue(prefs), powerSyncProvider.overrideWithValue(db)],
    child: const AppPlanta(),
  ));
}

class AppPlanta extends ConsumerStatefulWidget {
  const AppPlanta({super.key});
  @override
  ConsumerState<AppPlanta> createState() => _AppPlantaState();
}

class _AppPlantaState extends ConsumerState<AppPlanta> {
  @override
  void initState() {
    super.initState();
    // Conecta la sincronización cuando hay una cuenta técnica vinculada.
    ref.listenManual(sesionProvider, (_, s) {
      final db = ref.read(powerSyncProvider);
      if (s.value != null) {
        conectarSincronizacion(db);
      } else if (s.hasValue) {
        db.disconnect();
      }
    }, fireImmediately: true);
    // La cola de impresión revisa pendientes cada 15 s (reintentos con espera creciente).
    _cola = Timer.periodic(const Duration(seconds: 15), (_) => ref.read(colaImpresionProvider).procesar());
  }

  Timer? _cola;

  @override
  void dispose() {
    _cola?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Confección · Planta',
      debugShowCheckedModeBanner: false,
      theme: crearTema(Modo.planta),
      locale: idiomas.first,
      supportedLocales: idiomas,
      localizationsDelegates: localizaciones,
      routerConfig: ref.watch(routerPlantaProvider),
    );
  }
}
