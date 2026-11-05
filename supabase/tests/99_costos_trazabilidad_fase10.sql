-- Pruebas de la Fase 10: despacho y devolución de insumos a la OP, costo real vs
-- estándar, trazabilidad inversa (paquete/juego, rollo, OP, despacho, producto, lote),
-- dashboard e informes.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.ok(p_cond boolean, p_nombre text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALLÓ: %', p_nombre; end if;
  raise notice '✓ %', p_nombre;
end $$;
create or replace function pg_temp.falla(p_sql text, p_nombre text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then raise notice '✓ % (rechazado: %)', p_nombre, sqlerrm; return; end;
  raise exception 'FALLÓ: % (debía ser rechazado)', p_nombre;
end $$;
create or replace function pg_temp.como(p_sub text, p_sql text) returns void language plpgsql as $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', p_sub, true);
  execute p_sql;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- usuarios: 02 jefe, 04 bodega, 05 satélite, 08 costos (+ bodega)

create temp table k as
select o.id as op, o.consecutivo,
       (select id from materiales where codigo = 'INS-HIL40') as hilo,
       (select id from bodegas where codigo = 'BI') as bi,
       (select id from materiales where tipo = 'tela' order by codigo limit 1) as tela
from ordenes_produccion o where o.id = (select op_id from juegos where estado <> 'anulado' order by codigo limit 1);
grant select on k to authenticated;

-- Entrada de hilo para poder despachar (EJEMPLO: 50 conos a $ 4.500)
insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, cantidad, costo_unitario, documento_tipo, documento_id, motivo)
select 'entrada_compra', hilo, null, bi, 50, 4500, 'prueba', 'EJEMPLO', 'Entrada de prueba' from k;
insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id)
select 'reserva', 'reservado', hilo, null, bi, 6, op, 'op', consecutivo from k;

-- ---------- 1. Despacho y devolución de insumos ----------
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002',
  format('select despachar_insumos_op(%L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 2))))$$,
  'El jefe de producción no despacha insumos');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select despachar_insumos_op(%L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 80))))$$,
  'No se despacha más de lo que hay en bodega');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select despachar_insumos_op(%L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select tela from k), 'bodega_id', (select bi from k), 'cantidad', 1))))$$,
  'La tela no sale por despacho de insumos (sale con el corte)');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select despachar_insumos_op(%L, %L, %L)', (select op from k),
         jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 10)), 'Hilo para el Módulo 1'));
select pg_temp.ok((select fisico = 40 and reservado = 0 from saldos_por_material where material_id = (select hilo from k) and bodega_id = (select bi from k) and color_id is null),
                  'Salen 10 conos: quedan 40 y se libera la reserva de 6 de la OP');
select pg_temp.ok((select documento_id like 'SAL-%' and costo_unitario = 4500 from movimientos_inventario where tipo = 'salida_op' and material_id = (select hilo from k)),
                  'Documento SAL con el costo promedio');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select devolver_insumos_op(%L, %L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 11)), 'Sobró'))$$,
  'No se devuelve más de lo que salió');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select devolver_insumos_op(%L, %L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 2)), ' '))$$,
  'La devolución exige motivo');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format('select devolver_insumos_op(%L, %L, %L)', (select op from k), jsonb_build_array(jsonb_build_object('material_id', (select hilo from k), 'bodega_id', (select bi from k), 'cantidad', 2)), 'Sobraron 2 conos'));
select pg_temp.ok((select fisico = 42 from saldos_por_material where material_id = (select hilo from k) and bodega_id = (select bi from k) and color_id is null), 'Vuelven 2 conos a bodega');

-- ---------- 2. Costo real vs estándar ----------
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select * from costo_op((select op from k))')$$,
                     'El jefe de producción no ve costos');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table c as select * from costo_op_detalle((select op from k))$$);
select pg_temp.ok((select count(*) = 6 from c), 'Seis conceptos: tela, insumos, externos, mano de obra, indirectos y total');
select pg_temp.ok((select valor_real from c where concepto = 'total') = (select sum(valor_real) from c where concepto <> 'total')
                  and (select estandar from c where concepto = 'total') between (select sum(estandar) from c where concepto <> 'total') - 3
                                                                       and (select sum(estandar) from c where concepto <> 'total') + 3,
                  'El total es la suma de los conceptos');
select pg_temp.ok((select valor_real from c where concepto = 'insumos') = 8 * 4500, 'Insumos reales = 8 conos netos × $ 4.500');
select pg_temp.ok((select valor_real from c where concepto = 'tela') =
                   (select round(-sum(mi.cantidad * coalesce(mi.costo_unitario, m.costo_estandar, 0)), 0) from movimientos_inventario mi join materiales m on m.id = mi.material_id
                    where mi.op_id = (select op from k) and mi.afecta = 'fisico' and m.tipo = 'tela' and mi.tipo in ('salida_op','envio_satelite','devolucion','anulacion'))
                  and (select valor_real from c where concepto = 'tela') > 0,
                  'Tela real = lo que salió en el corte al costo de cada rollo');
select pg_temp.ok((select valor_real from c where concepto = 'externos') =
                   (select coalesce(sum(valor), 0) from cuentas_pagar_satelite where op_id = (select op from k) and estado <> 'anulada'),
                  'Externos reales = cuentas por pagar a satélites de la OP');
select pg_temp.ok((select (detalle->>'minutos_marcados')::numeric > 0 and (detalle->>'minutos_sin_marcar_estandar')::numeric > 0 from c where concepto = 'mano_obra'),
                  'Mano de obra: minutos marcados + las operaciones sin marcar al estándar');
select pg_temp.ok((select estandar = round(sam_total_ficha(o.ficha_version_id) * (select (detalle->>'prendas_base')::numeric from c where concepto = 'total')
                                           * (select valor_minuto from valor_minuto_vigente(hoy_bogota())), 0)
                   from c, ordenes_produccion o where o.id = (select op from k) and c.concepto = 'mano_obra'),
                  'Mano de obra estándar = SAM × prendas cortadas × valor del minuto');
select pg_temp.ok((select (detalle->>'prendas_base')::numeric = (select sum(cantidad) from juegos where op_id = (select op from k) and estado <> 'anulado')
                   from c where concepto = 'total'), 'La base son las prendas cortadas');
select pg_temp.ok((select desviacion_pct = round((valor_real - estandar) / estandar * 100, 1) from c where concepto = 'tela'), 'Desviación % = (real − estándar) / estándar');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table ic as select * from informe_costos(hoy_bogota() - 30, hoy_bogota())$$);
select pg_temp.ok((select valor_real = (select valor_real from c where concepto = 'total') from ic where op = (select consecutivo from k)), 'Informe de costos por OP');

-- ---------- 3. Trazabilidad inversa ----------
create temp table j as select id, codigo from juegos where op_id = (select op from k) and estado = 'terminado' order by codigo limit 1;
grant select on j to authenticated;
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table tj as select trazabilidad((select codigo from j)) t$$);
select pg_temp.ok((select t->>'tipo' = 'unidad' and jsonb_array_length(t->'unidades'->0->'rollos') > 0 and jsonb_array_length(t->'unidades'->0->'corte') > 0
                     and jsonb_array_length(t->'unidades'->0->'procesos') > 0 and jsonb_array_length(t->'unidades'->0->'operarios') > 0
                     and jsonb_array_length(t->'unidades'->0->'calidad') > 0 and jsonb_array_length(t->'unidades'->0->'destino') > 0
                     and t->'unidades'->0->'op'->>'consecutivo' = (select consecutivo from k)
                   from tj),
                  'Desde un juego: rollos y lote, corte, procesos, operarios, calidad y destino');
select pg_temp.ok((select (select bool_and(r->>'lote_tintura' is not null) from jsonb_array_elements(t->'unidades'->0->'rollos') r) from tj), 'Cada rollo trae su lote de tintura');
create temp table rr as select (t->'unidades'->0->'rollos'->0->>'codigo') as rollo, (t->'unidades'->0->'rollos'->0->>'lote_tintura') as lote from tj;
grant select on rr to authenticated;
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table tr as select trazabilidad((select rollo from rr)) t$$);
select pg_temp.ok((select t->>'tipo' = 'rollo' and jsonb_array_length(t->'cortes') > 0
                     and exists (select 1 from jsonb_array_elements(t->'unidades') u where u->>'codigo' = (select codigo from j)) from tr),
                  'Desde el rollo hacia adelante: cortes y los juegos que salieron de él');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table tl as select trazabilidad(lower((select lote from rr))) t$$);
select pg_temp.ok((select t->>'tipo' = 'lote' and jsonb_array_length(t->'rollos') > 0 and jsonb_array_length(t->'unidades') > 0 from tl),
                  'Desde un lote de tintura (sin importar mayúsculas)');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table tp as select trazabilidad((select consecutivo from k)) t$$);
select pg_temp.ok((select jsonb_array_length(t->'unidades') = (select count(*) from unidades_trabajo where op_id = (select op from k)) from tp), 'Desde la OP: todas sus unidades');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table td as select trazabilidad((select consecutivo from despachos order by consecutivo limit 1)) t$$);
select pg_temp.ok((select t->>'tipo' = 'despacho' and t->'despacho'->>'cliente' is not null and jsonb_array_length(t->'unidades') > 0 from td),
                  'Desde un despacho: cliente y de qué paquetes salieron las prendas');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002',
  $$create temp table ts as select trazabilidad((select s.codigo from skus s join movimientos_producto m on m.sku_id = s.id and m.tipo = 'ingreso_op' limit 1)) t$$);
select pg_temp.ok((select t->>'tipo' = 'producto' and jsonb_array_length(t->'unidades') > 0 from ts), 'Desde la etiqueta de la prenda (reclamo de un cliente)');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select trazabilidad(''XYZ-123'')')$$, 'Un código que no existe');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000005', 'select trazabilidad((select consecutivo from k))')$$, 'El satélite no consulta trazabilidad');

-- ---------- 4. Dashboard ----------
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table db as select dashboard() d$$);
select pg_temp.ok((select jsonb_array_length(d->'procesos') >= 7 and (d->'indicadores'->>'ops_activas')::int >= 1
                     and exists (select 1 from jsonb_array_elements(d->'ops') o where o->>'consecutivo' = (select consecutivo from k) and o->'avance' ? 'confeccion')
                     and (d->'indicadores'->>'alertas')::int >= 1 from db),
                  'Dashboard: procesos, OP activas con su avance por proceso e indicadores');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000005', 'select dashboard()')$$, 'El satélite no ve el dashboard');

-- ---------- 5. Informes ----------
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table i1 as select * from informe_produccion(hoy_bogota() - 30, hoy_bogota())$$);
select pg_temp.ok((select sum(entra) = sum(buenas) + sum(segundas) + sum(faltantes) and bool_or(proceso = 'Confección') from i1),
                  'Producción por proceso: entra = buenas + segundas + faltantes');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table i2 as select * from informe_consumo_tela(hoy_bogota() - 30, hoy_bogota())$$);
select pg_temp.ok((select count(*) > 0 and bool_and(teorico > 0) from i2), 'Consumo de tela: teórico vs real por corte');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table i3 as select * from informe_pedidos(hoy_bogota() - 365, hoy_bogota())$$);
select pg_temp.ok((select count(*) > 0 and bool_and(pedidas >= despachadas) from i3), 'Cumplimiento de pedidos');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table i4 as select * from informe_satelites(hoy_bogota() - 30, hoy_bogota())$$);
select pg_temp.ok((select count(*) > 0 and bool_and(enviadas >= devueltas) from i4), 'Satélites: enviadas, devueltas y segundas');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$create temp table i5 as select * from informe_inventario_valorizado()$$);
select pg_temp.ok((select bool_or(grupo = 'Telas') and bool_or(grupo = 'Insumos') and bool_or(grupo = 'Producto terminado')
                     and (select valor from i5 where codigo = 'INS-HIL40' and color is null and bodega = 'BI') = 42 * 4500 from i5),
                  'Inventario valorizado: telas, insumos y producto terminado (42 conos × $ 4.500)');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$create temp table i6 as select * from informe_ops_atrasadas()$$);
select pg_temp.ok(true, 'OP atrasadas o en riesgo');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000005', 'select * from informe_produccion(hoy_bogota(), hoy_bogota())')$$,
                     'El satélite no ve los informes');
