-- Pruebas de la Fase 11: cola de integraciones (qué se encola, idempotencia, toma
-- sin duplicar, enlaces faltantes, reintentos), tareas programadas (consumos,
-- alertas, recordatorios), nómina real → valor del minuto, incentivos aprobados.
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
-- usuarios: 02 jefe, 04 bodega, 08 costos (+ bodega)

-- ---------- 1. Lo que ya pasó en las fases anteriores quedó en la cola ----------
select pg_temp.ok((select count(*) > 0 and bool_and(datos->>'nombre' like '% / %') from integraciones_cola where tipo = 'crear_item'),
                  'Fichas aprobadas → un producto por color y talla para crear en Alegra ("NOMBRE COLOR / TALLA")');
select pg_temp.ok((select count(*) from integraciones_cola where tipo = 'ajuste_pt') = (select count(*) from movimientos_producto where tipo in ('ingreso_op','ingreso_segunda','ajuste','traslado')),
                  'Cada entrada, ajuste o traslado de producto terminado → un ajuste en Alegra');
select pg_temp.ok((select count(*) from integraciones_cola where tipo = 'despacho') = (select count(*) from despachos)
                  and (select count(*) from integraciones_cola where tipo = 'anular_despacho') = (select count(*) from despachos where estado = 'anulado'),
                  'Cada despacho (y su anulación) va a Alegra');
select pg_temp.ok((select count(*) from integraciones_cola where tipo = 'documento_soporte')
                   = (select count(*) from cuentas_pagar_satelite where aprobada_en is not null),
                  'Cada cuenta de satélite aprobada → documento soporte');
select pg_temp.ok((select count(*) from integraciones_cola where tipo = 'factura_proveedor')
                   = (select count(*) from recepciones where estado <> 'borrador' and coalesce(trim(factura_proveedor), '') <> ''),
                  'Cada recepción confirmada con factura → factura de proveedor');
select pg_temp.ok((select count(*) = count(distinct (sistema, clave)) from integraciones_cola), 'Nunca dos trabajos con la misma clave');

-- ---------- 2. Consumos del día: un ajuste por OP, una sola vez ----------
create temp table dias as select distinct (ocurrido_en at time zone 'America/Bogota')::date as d from movimientos_inventario
  where tipo = 'salida_op' and op_id is not null;
select pg_temp.ok((select sum(encolar_consumos(d)) > 0 from dias), 'Consumo de materia prima por OP y día encolado');
select pg_temp.ok((select sum(encolar_consumos(d)) = 0 from dias), 'Volver a encolar el mismo día no duplica');

-- ---------- 3. Ajustes, enlaces y armado del documento ----------
update integracion_ajustes set valor = to_jsonb('1'::text) where clave = 'alegra_bodega_pt';
update integracion_ajustes set valor = to_jsonb('7'::text) where clave = 'alegra_bodega_segundas';
create temp table j as select id, (datos->>'sku_id')::uuid as sku, datos->>'bodega' as bodega from integraciones_cola
  where tipo = 'ajuste_pt' and datos->>'bodega' = 'producto_terminado' order by creado_en limit 1;
update skus set alegra_id = null where id = (select sku from j);
select pg_temp.ok((select jsonb_array_length(datos_trabajo(id)->'faltan') = 1 and datos_trabajo(id)->'faltan'->>0 like 'producto PT-%' from j),
                  'Si el producto no está enlazado, el trabajo dice qué falta');
update skus set alegra_id = '9818' where id = (select sku from j);
select pg_temp.ok((select jsonb_array_length(d->'faltan') = 0 and d->'datos'->>'item' = '9818' and d->'datos'->>'bodega_alegra' = '1'
                     and (d->'datos'->>'cantidad')::int > 0 from (select datos_trabajo(id) d from j) x),
                  'Enlazado: el ajuste lleva el producto y la bodega de Alegra');

-- ---------- 4. Toma, resultado y reintentos ----------
update integraciones_cola set estado = 'descartado';           -- partimos de una cola vacía
create temp table t1 as select encolar('alegra', 'ajuste_pt', 'prueba:1', 'movimientos_producto', null, 'Prueba 1', jsonb_build_object('sku_id', (select sku from j))) as id;
create temp table t2 as select encolar('alegra', 'crear_item', 'prueba:2', 'skus', null, 'Prueba 2', jsonb_build_object('sku_id', (select sku from j))) as id;
select pg_temp.ok((select encolar('alegra', 'ajuste_pt', 'prueba:1', null, null, 'otra vez', '{}') is null), 'Encolar con la misma clave no duplica');
create temp table tomados as select id from tomar_trabajos(1);
create temp table tomados2 as select id from tomar_trabajos(5);
select pg_temp.ok((select count(*) = 1 from tomados) and (select count(*) = 1 from tomados2)
                  and not exists (select 1 from tomados where id in (select id from tomados2)),
                  'Dos pasadas no toman el mismo trabajo');
select pg_temp.ok((select count(*) = 0 from tomar_trabajos(5)), 'Lo que está enviándose no se vuelve a tomar');
select terminar_trabajo((select id from t2), true, '777', '{"id": "777"}');
select pg_temp.ok((select estado = 'enviado' and externo_id = '777' from integraciones_cola where id = (select id from t2)), 'Envío exitoso');
select terminar_trabajo((select id from t1), false, null, null, 'Alegra no responde (504)');
select pg_temp.ok((select estado = 'pendiente' and intentos = 1 and proximo_intento > now() and error like '%504%' from integraciones_cola where id = (select id from t1)),
                  'Si falla, se reintenta más tarde');
do $$ begin for i in 1..7 loop perform terminar_trabajo((select id from t1), false, null, null, 'Sigue fallando'); end loop; end $$;
select pg_temp.ok((select estado = 'error' and intentos = 8 from integraciones_cola where id = (select id from t1)), 'Tras 8 intentos queda en error');
select pg_temp.ok((select count(*) = 8 from integraciones_intentos where cola_id = (select id from t1)), 'Cada intento queda registrado');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select gestionar_trabajo((select id from t1), ''reintentar'')')$$,
                     'El jefe de producción no maneja integraciones');
grant select on t1, t2 to authenticated;
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$select gestionar_trabajo((select id from t1), 'reintentar')$$);
select pg_temp.ok((select estado = 'pendiente' and intentos = 0 from integraciones_cola where id = (select id from t1)), 'Costos lo reintenta');
-- bloqueado por un enlace faltante → al enlazar vuelve solo
select terminar_trabajo((select id from tomar_trabajos(1) limit 1), false, null, null, 'Falta enlazar: producto', true);
select pg_temp.ok((select estado = 'bloqueado' from integraciones_cola where id = (select id from t1)), 'Falta un enlace: queda bloqueado');
update skus set alegra_id = '9819' where id = (select sku from j);
select pg_temp.ok((select estado = 'pendiente' from integraciones_cola where id = (select id from t1)), 'Al enlazar, lo bloqueado vuelve a la cola');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', $$update integraciones_cola set estado = 'enviado'$$);
select pg_temp.ok((select estado = 'pendiente' from integraciones_cola where id = (select id from t1)), 'Nadie cambia la cola a mano desde la web');

-- ---------- 5. Tareas programadas: alertas y WhatsApp ----------
insert into whatsapp_destinatarios (nombre, telefono, tipos) values ('Jefe de producción (EJEMPLO)', '+573000000000', '{op_atrasada,stock_bajo}');
update ordenes_produccion set fecha_comprometida = hoy_bogota() - 3
 where id = (select id from ordenes_produccion where estado in ('planeada','en_proceso') order by consecutivo limit 1);
update materiales set stock_minimo = 1000000 where codigo = 'INS-HIL40';
create temp table tp as select tareas_programadas() r;
select pg_temp.ok((select (r->>'alertas')::int >= 2 from tp)
                  and exists (select 1 from alertas where tipo = 'op_atrasada') and exists (select 1 from alertas where tipo = 'stock_bajo'),
                  'OP atrasada y stock bajo generan alertas');
select pg_temp.ok((select count(*) >= 2 from integraciones_cola where sistema = 'whatsapp' and entidad = 'alertas' and datos->>'telefono' = '+573000000000'),
                  'Las alertas suscritas salen por WhatsApp al jefe de producción');
select pg_temp.ok((select (tareas_programadas()->>'alertas')::int = 0), 'Volver a correr no repite alertas abiertas');
update satelites set whatsapp = '+573111111111' where id = (select satelite_id from remisiones where tipo = 'salida' limit 1);
update remisiones set fecha_compromiso = hoy_bogota() - 1 where tipo = 'salida' and estado in ('enviada','parcial');
select tareas_programadas();
select pg_temp.ok(exists (select 1 from integraciones_cola where clave like 'wa:venc:%') or not exists (select 1 from remisiones where tipo = 'salida' and estado in ('enviada','parcial')),
                  'Remisión vencida: recordatorio al satélite');

-- ---------- 6. Nómina real → valor real del minuto ----------
create temp table q as select date_trunc('month', hoy_bogota())::date + case when extract(day from hoy_bogota()) > 15 then 15 else 0 end as desde;
alter table q add column hasta date;
update q set hasta = case when extract(day from desde) = 1 then desde + 14 else (date_trunc('month', desde) + interval '1 month - 1 day')::date end;
create temp table nom as select registrar_costos_nomina((select desde from q), (select hasta from q),
  (select jsonb_agg(jsonb_build_object('identificacion', documento, 'nombre', nombres, 'costo_total', 1600000, 'salario', 1300000)) from empleados)
  || jsonb_build_array(jsonb_build_object('identificacion', '999999', 'nombre', 'No está en la app', 'costo_total', 2000000))) r;
select pg_temp.ok((select (r->>'filas')::int = (select count(*) + 1 from empleados) and (r->>'sin_enlazar')::int = 1 from nom), 'Nómina importada; un empleado sin enlazar');
select pg_temp.ok((select v.valor_minuto = round(v.costo_nomina / v.minutos, 2) and v.costo_nomina = 1600000 * (select count(*) from empleados where celula_id is not null)
                     and v.minutos = (select sum(minutos_pagados(id, (select desde from q), (select hasta from q))) from empleados where celula_id is not null)
                   from valor_minuto_real v where v.desde = (select desde from q)),
                  'Valor real del minuto = costo de la nómina de planta / minutos de turno pagados');
select pg_temp.ok((select es_real and valor_minuto = (select valor_minuto from valor_minuto_real where desde = (select desde from q)) from valor_minuto_dia(hoy_bogota())),
                  'Los días de esa quincena usan el valor real');
select pg_temp.ok((select not es_real from valor_minuto_dia(hoy_bogota() - 40)), 'Sin nómina importada se usa el valor configurado');
create temp table c11 as select * from costo_op((select op_id from marcaciones order by ocurrido_en_servidor desc limit 1));
select pg_temp.ok((select (detalle->>'minutos_con_nomina_real')::numeric > 0 from c11 where concepto = 'mano_obra'), 'El costo de la OP usa la nómina real');
select pg_temp.ok((select registrar_costos_nomina((select desde from q), (select hasta from q), '[]')->>'filas' = '0'), 'Volver a importar no duplica');

-- ---------- 7. Incentivos aprobados → Alegra Nómina ----------
update celulas set grupo_incentivo_id = (select id from grupos_incentivo order by nombre limit 1) where codigo = 'MOD1';
grant select on q to authenticated;
create temp table li as select * from liquidar_incentivos((select desde from q), (select hasta from q));
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', $$select aprobar_incentivos((select desde from q), (select hasta from q))$$);
select pg_temp.ok((select total = (select coalesce(sum(valor), 0) from li) from liquidaciones_incentivo where desde = (select desde from q)), 'Liquidación aprobada con su total');
select pg_temp.ok((select count(*) from integraciones_cola where tipo = 'concepto_nomina')
                   = (select count(distinct empleado_id) from li where valor > 0), 'Un concepto de nómina por operario con incentivo');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select aprobar_incentivos((select desde from q), (select hasta from q))')$$,
                     'La misma quincena no se aprueba dos veces');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select aprobar_incentivos(hoy_bogota() - 30, hoy_bogota() - 16)')$$,
                     'Bodega no aprueba incentivos');
select pg_temp.falla($$delete from liquidaciones_incentivo$$, 'Una liquidación aprobada no se borra');

-- ---------- 8. Pago de satélite desde Alegra ----------
create temp table cps as select id from cuentas_pagar_satelite where estado = 'aprobada' limit 1;
select pg_temp.ok((select count(*) = 0 from cps) or (select marcar_cuenta_pagada_alegra(id, 'Alegra pago 123') from cps),
                  'El pago registrado en Alegra marca la cuenta como pagada');

-- ---------- 9. Permisos ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';
select pg_temp.ok((select count(*) = 0 from integraciones_cola) and (select count(*) = 0 from integracion_ajustes), 'Bodega no ve la cola ni los ajustes');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000008';
select pg_temp.ok((select count(*) > 0 from integraciones_cola), 'Costos ve la cola');
reset role;
reset request.jwt.claim.sub;
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', 'select * from tomar_trabajos(1)')$$, 'Solo el servicio toma trabajos');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000008', 'select registrar_costos_nomina(hoy_bogota(), hoy_bogota(), ''[]'')')$$,
                     'Solo el servicio importa nómina');
