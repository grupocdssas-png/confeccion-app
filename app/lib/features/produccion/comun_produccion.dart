import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../compartido/widgets.dart';
import '../../core/formato/formato.dart';
import '../../core/tema/colores.dart';
import '../../core/tema/tema.dart';
import '../inventario/comun_inventario.dart' show db;

/// Referencias con ficha aprobada (vigente), con sus combinaciones y tallas: lo que se puede producir.
final referenciasProduciblesProvider = FutureProvider.autoDispose((ref) async {
  final r = await db
      .from('referencias')
      .select('id, codigo, nombre, version_vigente_id, '
          'vigente:ficha_versiones!referencias_version_fk(id, version, estado, sam_total, costo_estandar, '
          'ficha_combinaciones(codigo, nombre, orden), ficha_tallas(tallas(codigo, orden)))')
      .not('version_vigente_id', 'is', null)
      .eq('activo', true)
      .order('codigo', ascending: true);
  return [for (final x in r) if (x['vigente']?['estado'] == 'aprobada') x];
});

final clientesProvider = FutureProvider.autoDispose((ref) async => (
      clientes: await db.from('clientes').select('id, nombre, canal_id').eq('activo', true).order('nombre', ascending: true),
      canales: await db.from('canales').select('id, nombre').eq('activo', true).order('nombre', ascending: true),
    ));

List<String> combinacionesDe(Map<String, dynamic> ref) =>
    [for (final c in ((ref['vigente']?['ficha_combinaciones'] as List? ?? [])..sort((a, b) => ((a['orden'] ?? 0) as num).compareTo((b['orden'] ?? 0) as num)))) c['codigo'] as String];
Map<String, String> nombresCombinacion(Map<String, dynamic> ref) =>
    {for (final c in (ref['vigente']?['ficha_combinaciones'] as List? ?? [])) c['codigo'] as String: c['nombre'] as String};
List<String> tallasDe(Map<String, dynamic> ref) {
  final t = [for (final x in (ref['vigente']?['ficha_tallas'] as List? ?? [])) x['tallas']];
  t.sort((a, b) => (a['orden'] as int).compareTo(b['orden'] as int));
  return [for (final x in t) x['codigo'] as String];
}

/// Matriz de cantidades combinación × talla, con totales. Valores: {comb: {talla: n}}.
class MatrizCantidades extends StatelessWidget {
  const MatrizCantidades({
    super.key, required this.combinaciones, required this.tallas, required this.valores,
    this.nombres = const {}, this.onCambio, this.maximos,
  });
  final List<String> combinaciones, tallas;
  final Map<String, String> nombres;
  final Map<String, Map<String, int>> valores;
  final void Function(String comb, String talla, int n)? onCambio;
  final Map<String, Map<String, int>>? maximos; // ej. pendiente de pedido

  int _v(String c, String t) => valores[c]?[t] ?? 0;

  @override
  Widget build(BuildContext context) {
    final total = combinaciones.fold<int>(0, (a, c) => a + tallas.fold<int>(0, (b, t) => b + _v(c, t)));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: estilo(12.5, peso: FontWeight.w600, color: Colores.textoSuave),
        columnSpacing: 18,
        dataRowMaxHeight: 58,
        columns: [
          const DataColumn(label: Text('Combinación')),
          for (final t in tallas) DataColumn(label: Text(t), numeric: true),
          const DataColumn(label: Text('Total'), numeric: true),
        ],
        rows: [
          for (final c in combinaciones)
            DataRow(cells: [
              DataCell(Text(nombres[c] == null ? c : '$c · ${nombres[c]}')),
              for (final t in tallas)
                DataCell(onCambio == null
                    ? Text(_v(c, t) == 0 ? '—' : Formato.numero(_v(c, t), decimales: 0))
                    : SizedBox(
                        width: 72,
                        child: TextFormField(
                          key: ValueKey('$c-$t'),
                          initialValue: _v(c, t) == 0 ? '' : '${_v(c, t)}',
                          textAlign: TextAlign.right,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(isDense: true, hintText: '0',
                              helperText: maximos?[c]?[t] == null ? null : 'máx ${maximos![c]![t]}',
                              helperStyle: estilo(10.5, color: Colores.textoSuave)),
                          onChanged: (s) => onCambio!(c, t, int.tryParse(s.replaceAll('.', '')) ?? 0),
                        ),
                      )),
              DataCell(Text(Formato.numero(tallas.fold<int>(0, (b, t) => b + _v(c, t)), decimales: 0), style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          DataRow(cells: [
            DataCell(Text('Total', style: estilo(13, peso: FontWeight.w700))),
            for (final t in tallas)
              DataCell(Text(Formato.numero(combinaciones.fold<int>(0, (a, c) => a + _v(c, t)), decimales: 0), style: const TextStyle(fontWeight: FontWeight.w600))),
            DataCell(Text(Formato.numero(total, decimales: 0), style: estilo(14, peso: FontWeight.w700))),
          ]),
        ],
      ),
    );
  }
}

Pastilla pastillaEstadoOp(String e) => switch (e) {
      'planeada' => Pastilla('Planeada', color: Colores.deProceso('corte')),
      'en_proceso' => const Pastilla('En proceso', color: Colores.ambar),
      'terminada' => const Pastilla('Terminada', color: Colores.verde),
      'cerrada' => const Pastilla('Cerrada', color: Colores.textoSuave),
      'anulada' => const Pastilla('Anulada', color: Colores.rojo),
      _ => Pastilla(e, color: Colores.textoSuave),
    };

/// Días que faltan para la entrega, con semáforo (atrasado / en riesgo / a tiempo).
Widget diasRestantes(String? fecha, {String estado = 'planeada'}) {
  if (fecha == null) return const Text('—');
  if (estado == 'terminada' || estado == 'cerrada' || estado == 'anulada') return Text(Formato.fecha(DateTime.parse('${fecha}T12:00:00Z')));
  final f = DateTime.parse(fecha);
  final hoy = Formato.aBogota(DateTime.now());
  final dias = DateTime(f.year, f.month, f.day).difference(DateTime(hoy.year, hoy.month, hoy.day)).inDays;
  final color = dias < 0 ? Colores.rojo : dias <= 3 ? Colores.ambar : Colores.verde;
  return Pastilla(dias < 0 ? 'Atrasada ${-dias} d' : dias == 0 ? 'Hoy' : '$dias días', color: color);
}

String fechaIso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Selector de fecha compacto.
class CampoFecha extends StatelessWidget {
  const CampoFecha({super.key, required this.etiqueta, required this.valor, required this.onCambio, this.ancho = 170});
  final String etiqueta;
  final String? valor;
  final void Function(String?) onCambio;
  final double ancho;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: ancho,
        child: InkWell(
          onTap: () async {
            final ini = valor == null ? DateTime.now() : DateTime.parse(valor!);
            final f = await showDatePicker(context: context, initialDate: ini, firstDate: DateTime(2024), lastDate: DateTime(2100));
            if (f != null) onCambio(fechaIso(f));
          },
          child: InputDecorator(
            decoration: InputDecoration(labelText: etiqueta, isDense: true, suffixIcon: const Icon(Icons.calendar_month_outlined, size: 18)),
            child: Text(valor == null ? '—' : Formato.fecha(DateTime.parse('${valor}T12:00:00Z'))),
          ),
        ),
      );
}
