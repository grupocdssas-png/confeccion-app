import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/arranque.dart';
import 'core/auth/sesion.dart';
import 'core/router/router_web.dart';
import 'core/tema/tema.dart';

/// Panel web de oficina (y, desde la Fase 8, tableros de TV).
Future<void> main() async {
  final prefs = await arrancarComun();
  runApp(ProviderScope(overrides: [prefsProvider.overrideWithValue(prefs)], child: const AppWeb()));
}

class AppWeb extends ConsumerWidget {
  const AppWeb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'Confección',
        debugShowCheckedModeBanner: false,
        theme: crearTema(Modo.oficina),
        locale: idiomas.first,
        supportedLocales: idiomas,
        localizationsDelegates: localizaciones,
        routerConfig: ref.watch(routerWebProvider),
      );
}
