import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/sesion.dart';
import '../../core/config/config.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

/// Ingreso con correo y contraseña. En la tablet se usa una sola vez para
/// vincularla con su cuenta técnica (rol "dispositivo").
class PantallaIngreso extends ConsumerStatefulWidget {
  const PantallaIngreso({super.key, this.modoTablet = false});
  final bool modoTablet;
  @override
  ConsumerState<PantallaIngreso> createState() => _PantallaIngresoState();
}

class _PantallaIngresoState extends ConsumerState<PantallaIngreso> {
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  var _ocultar = true;

  Future<void> _ingresar() => ref.read(sesionProvider.notifier).ingresar(_correo.text, _clave.text);

  @override
  Widget build(BuildContext context) {
    final sesion = ref.watch(sesionProvider);
    final cargando = sesion.isLoading;
    final error = sesion.hasError ? '${sesion.error}' : null;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Container(width: 10, height: 28, color: Colores.deProceso('corte')),
                      const SizedBox(width: 10),
                      Text('Confección', style: estilo(22, peso: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      widget.modoTablet
                          ? 'Vincular esta tablet. Use la cuenta técnica de la estación (lo hace el administrador una sola vez).'
                          : 'Gestión y trazabilidad de producción',
                      style: estilo(14, color: Colores.textoSuave),
                    ),
                    const SizedBox(height: 24),
                    if (!Config.completa)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text('Falta configurar SUPABASE_URL y SUPABASE_ANON_KEY (ver README).',
                            style: estilo(13, color: Colores.rojo)),
                      ),
                    TextField(
                      controller: _correo,
                      autofillHints: const [AutofillHints.email],
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Correo'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clave,
                      obscureText: _ocultar,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _ingresar(),
                      decoration: InputDecoration(
                        labelText: 'Contraseña',
                        suffixIcon: IconButton(
                          tooltip: _ocultar ? 'Mostrar' : 'Ocultar',
                          icon: Icon(_ocultar ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _ocultar = !_ocultar),
                        ),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(error, style: estilo(13, color: Colores.rojo)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: cargando ? null : _ingresar,
                      child: cargando
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(widget.modoTablet ? 'Vincular tablet' : 'Ingresar'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
