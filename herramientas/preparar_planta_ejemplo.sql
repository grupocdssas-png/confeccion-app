-- Deja la OP-000001 de EJEMPLO lista para probar la tablet del módulo (Fase 6):
-- llega el rib, se cortan cuerpo + mangas y cuellos, se arman los juegos, termina el
-- corte y 8 pasan por estampación en el satélite de EJEMPLO (remisión y devolución).
-- Resultado: 8 juegos esperando confección y 2 esperando estampación.
-- Uso (base local de Supabase, conexión directa):
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f herramientas/preparar_planta_ejemplo.sql
\set ON_ERROR_STOP 1
begin;
-- 1. Llega el rib negro (EJEMPLO)
insert into recepciones (id, proveedor_id, bodega_id, factura_proveedor)
values ('ac000000-0000-0000-0000-0000000000e6', (select id from proveedores where nit = '900000001-1'), '1a000000-0000-0000-0000-000000000001', 'FE-EJEMPLO-RIB');
insert into recepcion_lineas (recepcion_id, orden, material_id, color_id, cantidad, costo_unitario, lote_tintura, ancho_real_cm, metros, kilos)
values ('ac000000-0000-0000-0000-0000000000e6', 1, '1c000000-0000-0000-0000-000000000003', (select id from colores where codigo = 'N'), 3.0, 35000, 'L-RIB-N1', 100, 13.6, 3.0);
select count(*) from confirmar_recepcion('ac000000-0000-0000-0000-0000000000e6');

-- 2. Corte combinado de OP-000001 (trazos de EJEMPLO)
with k as (
  select o.id as op, o.ficha_version_id as ficha,
         (select jsonb_agg(t.id order by t.orden) from tallas t where t.codigo in ('S','M','L','XL')) as tallas,
         (select id from colores where codigo = 'N') as negro, (select id from colores where codigo = 'GJ') as gris
  from ordenes_produccion o where o.consecutivo = 'OP-000001'
)
select confirmar_corte(guardar_corte(jsonb_build_object('op_id', k.op, 'tipo', 'combinada', 'estacion_id', '1b000000-0000-0000-0000-000000000003',
  'despunte_cm', 2, 'documento', jsonb_build_object('bloques', jsonb_build_array(
    jsonb_build_object('id', 'b1', 'nombre', 'Cuerpo y mangas', 'material_id', '1c000000-0000-0000-0000-000000000001',
      'partes', (select jsonb_agg(id order by orden) from ficha_partes where ficha_id = k.ficha and nombre in ('Cuerpo','Mangas')),
      'tallas', k.tallas,
      'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 5.70,
          'unidades', (select jsonb_object_agg(t.id, case t.codigo when 'S' then 1 when 'XL' then 1 else 2 end) from tallas t where t.codigo in ('S','M','L','XL')))),
      'tramos', jsonb_build_array(
        jsonb_build_object('rollo_id', (select id from rollos where codigo = 'TL-000003'), 'color_id', k.negro, 'capas', 13),
        jsonb_build_object('rollo_id', (select id from rollos where codigo = 'TL-000001'), 'color_id', k.negro, 'capas', 7),
        jsonb_build_object('rollo_id', (select id from rollos where codigo = 'TL-000005'), 'color_id', k.gris, 'capas', 10))),
    jsonb_build_object('id', 'b2', 'nombre', 'Cuellos', 'material_id', '1c000000-0000-0000-0000-000000000003',
      'partes', (select jsonb_agg(id) from ficha_partes where ficha_id = k.ficha and nombre = 'Cuello'),
      'tallas', k.tallas,
      'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 0.60,
          'unidades', (select jsonb_object_agg(t.id, case t.codigo when 'S' then 4 when 'XL' then 4 else 8 end) from tallas t where t.codigo in ('S','M','L','XL')))),
      'tramos', jsonb_build_array(jsonb_build_object('rollo_id', (select id from rollos where lote_tintura = 'L-RIB-N1' and not es_retazo), 'color_id', k.negro, 'capas', 8)))),
    'rollos', jsonb_build_object((select id from rollos where lote_tintura = 'L-RIB-N1' and not es_retazo), jsonb_build_object('fin', 'retazo'))))))
from k;

-- 3. Juegos y fin del corte
select count(*) as juegos from (select armar_juegos(id) from ordenes_produccion where consecutivo = 'OP-000001') x;
select terminar_corte_op(id) from ordenes_produccion where consecutivo = 'OP-000001';

-- 4. Estampación en el satélite de EJEMPLO: remisión con 8 juegos y su devolución completa.
--    JG-000009 y JG-000010 quedan esperando estampación (para probar una remisión en la web).
create temp table rem_ejemplo as
select crear_remision_salida((select id from satelites where nit = '900000004-4'), 'estampacion',
        (select array_agg(j.id order by j.codigo) from juegos j join ordenes_produccion o on o.id = j.op_id
          where o.consecutivo = 'OP-000001' and j.codigo not in ('JG-000009', 'JG-000010')),
        '[]', 'Remisión de EJEMPLO', current_date + 3) as id;
select count(*) as devolucion from (
  select registrar_devolucion(r.id, (select jsonb_agg(jsonb_build_object('unidad_id', coalesce(ru.juego_id, ru.paquete_id), 'buenas', ru.cantidad))
                                     from remision_unidades ru where ru.remision_id = r.id)) from rem_ejemplo r) x;
commit;
select codigo, cantidad, estado, proceso_actual from juegos order by codigo;
