import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/db_local/app_db.dart';
import '../../core/formato/formato.dart';
import '../../core/sync/bandeja.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../planta/escaner.dart';
import '../planta/indicador_sync.dart';
import '../planta/proveedores_planta.dart';

/// Entrada / salida con el QR del carnet. Funciona igual con o sin internet.
class PantallaAsistenciaPlanta extends ConsumerStatefulWidget {
  const PantallaAsistenciaPlanta({super.key, this.atras = false});
  final bool atras;
  @override
  ConsumerState<PantallaAsistenciaPlanta> createState() => _PantallaAsistenciaPlantaState();
}

class _PantallaAsistenciaPlantaState extends ConsumerState<PantallaAsistenciaPlanta> {
  final _codigo = TextEditingController();
  EmpleadoLocal? _empleado;
  String _sugerido = 'entrada';
  ({String tipo, DateTime hora})? _ultima;
  String? _error;
  ({String nombre, String tipo, DateTime hora})? _confirmacion;
  Timer? _limpiar;

  @override
  void dispose() {
    _limpiar?.cancel();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _escanear() async {
    final v = await escanearQr(context, titulo: 'Escanee su carnet');
    if (v != null) await _buscar(v);
  }

  Future<void> _buscar(String entrada) async {
    final repo = ref.read(repoAsistenciaProvider);
    final e = await repo.buscar(entrada);
    if (!mounted) return;
    if (e == null) {
      setState(() {
        _empleado = null;
        _error = 'No se encontró el carnet "$entrada". Verifique el código o pida al supervisor que lo registre.';
      });
      return;
    }
    final ultima = await repo.ultimaMarcaHoy(e.id);
    setState(() {
      _empleado = e;
      _ultima = ultima;
      _sugerido = ultima?.tipo == 'entrada' ? 'salida' : 'entrada';
      _error = null;
      _confirmacion = null;
      _codigo.clear();
    });
  }

  Future<void> _registrar(String tipo) async {
    final e = _empleado!;
    final r = await ref.read(repoAsistenciaProvider).registrar(e, tipo);
    if (!mounted) return;
    setState(() {
      _empleado = null;
      _confirmacion = (nombre: '${e.nombres} ${e.apellidos}', tipo: tipo, hora: DateTime.now());
    });
    if (r.relojRetrocedio) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Atención: la hora de la tablet retrocedió. Avise al supervisor.'),
        backgroundColor: Colores.rojo,
      ));
    }
    _limpiar?.cancel();
    _limpiar = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _confirmacion = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: EncabezadoPlanta(titulo: 'Asistencia', atras: widget.atras),
      body: Column(children: [
        const AvisosPlanta(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            if (_confirmacion != null)
              _Confirmacion(_confirmacion!)
            else if (_empleado != null)
              _Empleado(
                empleado: _empleado!,
                ultima: _ultima,
                sugerido: _sugerido,
                onRegistrar: _registrar,
                onCancelar: () => setState(() => _empleado = null),
              )
            else
              _Lector(codigo: _codigo, error: _error, onEscanear: _escanear, onBuscar: () => _buscar(_codigo.text)),
            const SizedBox(height: 24),
            const _UltimasMarcas(),
          ]),
        ),
      ]),
    );
  }
}

class _Lector extends StatelessWidget {
  const _Lector({required this.codigo, required this.error, required this.onEscanear, required this.onBuscar});
  final TextEditingController codigo;
  final String? error;
  final VoidCallback onEscanear, onBuscar;

  @override
  Widget build(BuildContext context) => Tarjeta(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Pase su carnet', style: estilo(28, peso: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Escanee el código QR del carnet para registrar su entrada o salida.', style: estilo(17, color: Colores.textoSuave)),
          const SizedBox(height: 20),
          SizedBox(
            height: 88,
            child: FilledButton.icon(
              onPressed: onEscanear,
              icon: const Icon(Icons.qr_code_scanner, size: 36),
              label: Text('Escanear carnet', style: estilo(24, peso: FontWeight.w600, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: TextField(
                controller: codigo,
                style: estiloCodigo(22),
                textCapitalization: TextCapitalization.characters,
                onSubmitted: (_) => onBuscar(),
                decoration: InputDecoration(
                  hintText: 'o digite su código (OPR-0001)',
                  hintStyle: estilo(18, color: Colores.textoSuave),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(height: 64, child: OutlinedButton(onPressed: onBuscar, child: const Text('Buscar'))),
          ]),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(error!, style: estilo(17, peso: FontWeight.w600, color: Colores.rojo)),
          ],
        ]),
      );
}

class _Empleado extends StatelessWidget {
  const _Empleado({required this.empleado, required this.ultima, required this.sugerido, required this.onRegistrar, required this.onCancelar});
  final EmpleadoLocal empleado;
  final ({String tipo, DateTime hora})? ultima;
  final String sugerido;
  final void Function(String tipo) onRegistrar;
  final VoidCallback onCancelar;

  @override
  Widget build(BuildContext context) {
    final nombre = '${empleado.nombres} ${empleado.apellidos}';
    Widget boton(String tipo, String texto, Color color, IconData icono) {
      final principal = tipo == sugerido;
      final estiloTexto = estilo(26, peso: FontWeight.w600, color: principal ? Colors.white : color);
      return Expanded(
        child: SizedBox(
          height: 112,
          child: principal
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: color),
                  onPressed: () => onRegistrar(tipo),
                  icon: Icon(icono, size: 36),
                  label: Text(texto, style: estiloTexto),
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: BorderSide(color: color, width: 2), foregroundColor: color),
                  onPressed: () => onRegistrar(tipo),
                  icon: Icon(icono, size: 36),
                  label: Text(texto, style: estiloTexto),
                ),
        ),
      );
    }

    return Tarjeta(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Iniciales(nombre, tamano: 72),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nombre, style: estilo(26, peso: FontWeight.w600)),
              Text('${empleado.codigo} · ${empleado.qr}', style: estiloCodigo(17, color: Colores.textoSuave, peso: FontWeight.w400)),
              const SizedBox(height: 6),
              Text(
                ultima == null
                    ? 'Sin marcas hoy en esta tablet'
                    : 'Última marca: ${ultima!.tipo == 'entrada' ? 'Entrada' : 'Salida'} ${Formato.hora(ultima!.hora)}',
                style: estilo(17, color: Colores.textoSuave),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 24),
        Row(children: [
          boton('entrada', 'ENTRADA', Colores.verde, Icons.login),
          const SizedBox(width: 16),
          boton('salida', 'SALIDA', Colores.deProceso('corte'), Icons.logout),
        ]),
        const SizedBox(height: 12),
        TextButton(onPressed: onCancelar, child: Text('Cancelar', style: estilo(18, color: Colores.textoSuave))),
      ]),
    );
  }
}

class _Confirmacion extends StatelessWidget {
  const _Confirmacion(this.c);
  final ({String nombre, String tipo, DateTime hora}) c;
  @override
  Widget build(BuildContext context) {
    final color = c.tipo == 'entrada' ? Colores.verde : Colores.deProceso('corte');
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        const Icon(Icons.check_circle, color: Colors.white, size: 72),
        const SizedBox(height: 12),
        Text('${c.tipo == 'entrada' ? 'Entrada' : 'Salida'} registrada · ${Formato.hora(c.hora)}',
            textAlign: TextAlign.center, style: estilo(30, peso: FontWeight.w600, color: Colors.white)),
        const SizedBox(height: 6),
        Text(c.nombre, textAlign: TextAlign.center, style: estilo(22, color: Colors.white)),
      ]),
    );
  }
}

class _UltimasMarcas extends ConsumerWidget {
  const _UltimasMarcas();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventos = ref.watch(recientesAsistenciaProvider).value ?? const <EventoBandeja>[];
    final anuladas = {
      for (final e in eventos)
        if (jsonDecode(e.resumen ?? '{}')['tipo'] == 'anulacion' && e.estado != EstadoEvento.rechazado)
          jsonDecode(e.resumen!)['anula_id']: jsonDecode(e.resumen!)['motivo'],
    };
    final visibles = eventos.where((e) => jsonDecode(e.resumen ?? '{}')['tipo'] != 'anulacion').toList();

    return Tarjeta(
      titulo: 'Últimas marcas en esta tablet',
      child: visibles.isEmpty
          ? Text('Todavía no hay marcas.', style: estilo(17, color: Colores.textoSuave))
          : Column(children: [
              for (final e in visibles) _FilaMarca(evento: e, motivoAnulacion: anuladas[e.id] as String?),
            ]),
    );
  }
}

class _FilaMarca extends ConsumerWidget {
  const _FilaMarca({required this.evento, this.motivoAnulacion});
  final EventoBandeja evento;
  final String? motivoAnulacion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = jsonDecode(evento.resumen ?? '{}') as Map<String, dynamic>;
    final anulada = motivoAnulacion != null;
    final tachado = anulada ? TextDecoration.lineThrough : null;
    final hora = DateTime.parse(evento.ocurridoEn!);
    final (estadoTexto, estadoColor, estadoIcono) = switch (evento.estado) {
      EstadoEvento.sincronizado => ('Enviada', Colores.verde, Icons.cloud_done_outlined),
      EstadoEvento.rechazado => ('Rechazada', Colores.rojo, Icons.error_outline),
      _ => ('Pendiente', Colores.ambar, Icons.schedule),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(
          width: 80,
          child: Text(Formato.hora(hora), style: estiloCodigo(20, color: anulada ? Colores.textoSuave : null).copyWith(decoration: tachado)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['nombre']}', style: estilo(18, peso: FontWeight.w600).copyWith(decoration: tachado)),
            if (anulada) Text('Anulada: $motivoAnulacion', style: estilo(14, color: Colores.textoSuave)),
            if (evento.estado == EstadoEvento.rechazado) Text('${evento.motivo}', style: estilo(14, color: Colores.rojo)),
          ]),
        ),
        Pastilla(r['tipo'] == 'entrada' ? 'Entrada' : 'Salida',
            color: anulada ? Colores.textoSuave : (r['tipo'] == 'entrada' ? Colores.verde : Colores.deProceso('corte')), grande: true),
        const SizedBox(width: 10),
        Pastilla(estadoTexto, color: estadoColor, icono: estadoIcono),
        const SizedBox(width: 6),
        if (!anulada && evento.estado != EstadoEvento.rechazado)
          SizedBox(
            height: 48,
            child: TextButton(onPressed: () => _anular(context, ref), child: Text('Anular', style: estilo(16, color: Colores.rojo))),
          )
        else
          const SizedBox(width: 72),
      ]),
    );
  }

  Future<void> _anular(BuildContext context, WidgetRef ref) async {
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Anular marca'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('La marca queda en el historial tachada. Escriba el motivo:'),
          const SizedBox(height: 12),
          TextField(controller: motivo, autofocus: true, decoration: const InputDecoration(hintText: 'Ej.: marcó con el carnet equivocado')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colores.rojo),
            onPressed: () => Navigator.pop(c, motivo.text.trim().isNotEmpty),
            child: const Text('Anular'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(repoAsistenciaProvider).anular(evento, motivo.text);
  }
}
