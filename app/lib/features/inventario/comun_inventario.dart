import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../compartido/widgets.dart';
import '../../core/auth/sesion.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';

SupabaseClient get db => Supabase.instance.client;

/// Catálogos que usan los formularios de inventario (se cargan una vez).
class Catalogos {
  Catalogos(this.materiales, this.colores, this.bodegas, this.ubicaciones, this.proveedores, this.categorias);
  final List<Map<String, dynamic>> materiales, colores, bodegas, ubicaciones, proveedores, categorias;

  Map<String, dynamic>? material(String? id) => materiales.where((m) => m['id'] == id).firstOrNull;
  List<Map<String, dynamic>> ubicacionesDe(String? bodegaId) => ubicaciones.where((u) => u['bodega_id'] == bodegaId).toList();
}

final catalogosProvider = FutureProvider<Catalogos>((ref) async {
  final r = await Future.wait([
    db.from('materiales').select().eq('activo', true).order('nombre', ascending: true),
    db.from('colores').select().eq('activo', true).order('nombre', ascending: true),
    db.from('bodegas').select().eq('activo', true).order('codigo', ascending: true),
    db.from('ubicaciones').select().eq('activo', true).order('codigo', ascending: true),
    db.from('proveedores').select().eq('activo', true).order('nombre', ascending: true),
    db.from('categorias_material').select().eq('activo', true).order('nombre', ascending: true),
  ]);
  return Catalogos(r[0], r[1], r[2], r[3], r[4], r[5]);
});

bool puedeAprobarInventario(WidgetRef ref) =>
    ref.watch(sesionProvider).value?.permisos.any((p) => p.modulo == 'inventario' && p.aprobar) ?? false;
bool puedeEditarInventario(WidgetRef ref) => ref.watch(sesionProvider).value?.puedeEditar('inventario') ?? false;

const seccionesInventario = [
  ('telas', 'Telas por rollo'),
  ('retazos', 'Retazos'),
  ('insumos', 'Insumos'),
  ('kardex', 'Kardex'),
  ('entradas', 'Entradas'),
  ('ajustes', 'Ajustes'),
  ('conteos', 'Conteos'),
  ('materiales', 'Materiales'),
  ('ubicaciones', 'Ubicaciones'),
];

/// Pestañas del módulo de inventarios.
class PestanasInventario extends StatelessWidget {
  const PestanasInventario(this.actual, {super.key});
  final String actual;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (clave, nombre) in seccionesInventario)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(nombre),
                  selected: clave == actual,
                  showCheckmark: false,
                  labelStyle: estilo(13.5, peso: FontWeight.w600, color: clave == actual ? Colors.white : Colores.texto),
                  selectedColor: Colores.texto,
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Colores.borde),
                  onSelected: (_) => context.go('/inventario/$clave'),
                ),
              ),
          ]),
        ),
      );
}

/// Tabla de datos simple con encabezado gris (reutilizada en todo el módulo).
class Tabla extends StatelessWidget {
  const Tabla({super.key, required this.columnas, required this.filas, this.numericas = const {}, this.vacio = 'Sin datos.'});
  final List<String> columnas;
  final List<DataRow> filas;
  final Set<int> numericas;
  final String vacio;
  @override
  Widget build(BuildContext context) => filas.isEmpty
      ? Padding(padding: const EdgeInsets.all(16), child: Text(vacio, style: estilo(14, color: Colores.textoSuave)))
      : SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 42,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 52,
            headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
            columns: [for (var i = 0; i < columnas.length; i++) DataColumn(label: Text(columnas[i]), numeric: numericas.contains(i))],
            rows: filas,
          ),
        );
}

Widget muestraColor(String? hex, {double tam = 14}) {
  final c = hex == null ? Colores.borde : Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
  return Container(
    width: tam, height: tam,
    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3), border: Border.all(color: Colores.borde)),
  );
}

Pastilla pastillaEstadoRollo(String estado) => switch (estado) {
      'disponible' => const Pastilla('Disponible', color: Colores.verde),
      'reservado' => Pastilla('Reservado', color: Colores.deProceso('corte')),
      'en_corte' => Pastilla('En corte', color: Colores.deProceso('corte')),
      'retazo' => const Pastilla('Retazo', color: Colores.ambar),
      'agotado' => const Pastilla('Agotado', color: Colores.textoSuave),
      _ => Pastilla(estado, color: Colores.textoSuave),
    };

Pastilla pastillaEstadoDoc(String estado) => switch (estado) {
      'borrador' => const Pastilla('Borrador', color: Colores.textoSuave),
      'enviado' => const Pastilla('Por aprobar', color: Colores.ambar),
      'aprobado' || 'confirmada' || 'ajustado' => Pastilla(estado == 'confirmada' ? 'Confirmada' : estado == 'ajustado' ? 'Ajustado' : 'Aprobado', color: Colores.verde),
      'rechazado' || 'anulada' || 'anulado' => Pastilla(estado == 'rechazado' ? 'Rechazado' : 'Anulada', color: Colores.rojo),
      'abierto' => Pastilla('Abierto', color: Colores.deProceso('corte')),
      'cerrado' => const Pastilla('Cerrado', color: Colores.ambar),
      _ => Pastilla(estado, color: Colores.textoSuave),
    };

/// Convierte "1.234,5" o "1234.5" a número.
double? numeroCo(String t) {
  final s = t.trim();
  if (s.isEmpty) return null;
  final normal = s.contains(',') ? s.replaceAll('.', '').replaceAll(',', '.') : s;
  return double.tryParse(normal);
}

void avisar(BuildContext context, String texto, {bool error = false}) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(texto), backgroundColor: error ? Colores.rojo : Colores.texto));

/// Mensaje legible de un error de Supabase.
String mensajeError(Object e) => e is PostgrestException ? e.message : '$e';

Future<String?> pedirTexto(BuildContext context, {required String titulo, required String etiqueta, String? ayuda}) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(titulo),
      content: SizedBox(
        width: 420,
        child: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: etiqueta, hintText: ayuda)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isNotEmpty), child: const Text('Aceptar')),
      ],
    ),
  );
  return ok == true ? c.text.trim() : null;
}
