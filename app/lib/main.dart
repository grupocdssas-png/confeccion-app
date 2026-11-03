import 'package:flutter/foundation.dart' show kIsWeb;

import 'main_planta.dart' as planta;
import 'main_web.dart' as web;

/// Punto de entrada por defecto: en el navegador abre el panel web y en
/// Android la app de planta. También se puede compilar cada uno por separado
/// con -t lib/main_web.dart o -t lib/main_planta.dart.
Future<void> main() => kIsWeb ? web.main() : planta.main();
