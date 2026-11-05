-- Pruebas de la Fase 6: recorrido de juegos por los procesos (recepción y entrega con
-- cantidades, regla 5), marcaciones de operaciones desde la tablet del módulo (sin
-- conexión, idempotentes), eficiencia oficial y anulación (regla 2).
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
-- Un evento subido por la tablet del módulo 1; devuelve su resultado
create or replace function pg_temp.subir(p_id uuid, p_tabla text, p_datos jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000006', true);
  r := ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos',
         jsonb_build_array(jsonb_build_object('id', p_id, 'tabla', p_tabla, 'op', 'PUT', 'datos', p_datos))));
  reset role;
  return r -> 'resultados' -> 0;
end $$;

-- La OP de la Fase 5 ya tiene sus 90 prendas en juegos y el corte terminado
create temp table k as
select j.op_id as op, (select ficha_version_id from ordenes_produccion where id = j.op_id) as ficha,
       '16000000-0000-0000-0000-000000000001'::uuid as operario
from juegos j where j.estado <> 'anulado' limit 1;
create temp table j1 as select id, codigo, cantidad from juegos where op_id = (select op from k) order by codigo limit 1;
create temp table fo as select f.id, f.sam, f.repeticiones from ficha_operaciones f join operaciones o on o.id = f.operacion_id
  where f.ficha_id = (select ficha from k) and o.codigo = 'CAM-010';
grant select on k, j1, fo to authenticated;

select pg_temp.ok((select count(*) = 12 and bool_and(proceso_actual = 'estampacion') from juegos where op_id = (select op from k)),
                  'Al armar los juegos quedan esperando el proceso que sigue al corte (estampación)');
select pg_temp.ok((select bool_and(color_id is not null) from juegos where op_id = (select op from k)), 'Cada juego sabe el color de su parte principal');

-- ---------- 1. El módulo no recibe lo que va para otro proceso ----------
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000001', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'recepcion', 'ocurrido_en', now()))) ->> 'estado' = 'rechazado',
                  'La tablet de confección no recibe un juego que va para estampación');

-- ---------- 2. Estampación (satélite) desde la web, juego por juego ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega: sin permiso de OP
select pg_temp.falla($$select mover_unidad((select codigo from j1), 'recepcion', 'estampacion')$$, 'Bodega no mueve juegos');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
select pg_temp.falla($$select mover_unidad((select codigo from j1), 'entrega', 'estampacion', null, 5)$$, 'No se entrega lo que no se ha recibido');
do $$
declare j record;
begin
  for j in select codigo, cantidad from juegos where op_id = (select op from k) order by codigo loop
    perform mover_unidad(j.codigo, 'recepcion', 'estampacion');
  end loop;
end $$;
select pg_temp.falla($$select mover_unidad((select codigo from j1), 'entrega', 'estampacion', null, (select cantidad - 1 from j1), 0, 0)$$,
                     'Regla 5: la entrega no cuadra (buenas + segundas + faltantes ≠ lo que entró)');
do $$
declare j record;
begin
  for j in select codigo, cantidad from juegos where op_id = (select op from k) order by codigo loop
    perform mover_unidad(j.codigo, 'entrega', 'estampacion', null, j.cantidad, 0, 0);
  end loop;
end $$;
reset role;
select pg_temp.ok((select estado = 'terminado' and buenas = 90 from op_procesos where op_id = (select op from k) and proceso = 'estampacion'),
                  'Estampación queda terminada sola cuando pasaron todos los juegos (90 buenas)');
select pg_temp.ok((select proceso_actual = 'confeccion' from ordenes_produccion where id = (select op from k)), 'La OP pasa a confección');
select pg_temp.ok((select bool_and(estado = 'en_espera' and proceso_actual = 'confeccion') from juegos where op_id = (select op from k)),
                  'Los juegos quedan esperando confección');

-- ---------- 3. La tablet del módulo recibe (sin conexión: idempotente) ----------
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000002', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'recepcion', 'empleado_id', (select operario from k),
                                      'ocurrido_en', now() - interval '1 hour'))) ->> 'estado' = 'aceptado', 'El módulo recibe el juego');
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000002', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'recepcion', 'ocurrido_en', now()))) ->> 'estado' = 'duplicado',
                  'Si la tablet reenvía el mismo evento no se duplica');
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000003', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'recepcion', 'ocurrido_en', now()))) ->> 'estado' = 'rechazado',
                  'Recibir dos veces el mismo juego se rechaza con motivo');
select pg_temp.ok((select estado = 'en_proceso' and celula_id = '15000000-0000-0000-0000-000000000001' from juegos where id = (select id from j1)),
                  'El juego queda en proceso en la célula del módulo 1');

-- ---------- 4. Marcaciones y eficiencia oficial ----------
do $$
declare i int;
begin
  for i in 0..2 loop
    perform pg_temp.subir(('f6100000-0000-0000-0000-00000000000' || i)::uuid, 'marcaciones',
      jsonb_build_object('empleado_id', (select operario from k), 'unidad_id', (select id from j1), 'ficha_operacion_id', (select id from fo),
                         'unidades', 1, 'tipo', 'normal', 'ocurrido_en', now() - interval '50 minutes' + make_interval(mins => i)));
  end loop;
end $$;
select pg_temp.ok((select count(*) = 3 from marcaciones where paquete_id is null and juego_id = (select id from j1)), 'Tres marcaciones aceptadas');
select pg_temp.ok((select minutos_reales is null and eficiencia is null from marcaciones where id = 'f6100000-0000-0000-0000-000000000000'),
                  'La primera del día no tiene tiempo real (no hay marcación anterior)');
select pg_temp.ok((select abs(minutos_reales - 1) < 0.01 and minutos_esperados = round((select sam * repeticiones from fo), 3)
                          and abs(eficiencia - round((select sam * repeticiones from fo) * 100, 2)) < 0.5
                   from marcaciones where id = 'f6100000-0000-0000-0000-000000000001'),
                  'La segunda: 1 minuto real; eficiencia = SAM × repeticiones / minutos reales');
select pg_temp.ok((select unidades = 3 and abs(minutos_reales - 2) < 0.02 from eficiencia_diaria where empleado_id = (select operario from k)),
                  'La eficiencia del día suma 3 unidades y 2 minutos medidos');
select pg_temp.ok((select pg_temp.subir('f6100000-0000-0000-0000-000000000009', 'marcaciones',
                   jsonb_build_object('empleado_id', (select operario from k), 'unidad_id', (select id from j1), 'ficha_operacion_id',
                                      (select id from ficha_operaciones where ficha_id <> (select ficha from k) limit 1),
                                      'unidades', 1, 'ocurrido_en', now()))) ->> 'estado' = 'rechazado',
                  'Una operación de otra ficha se rechaza');
select pg_temp.ok((select pg_temp.subir('f6100000-0000-0000-0000-00000000000a', 'marcaciones',
                   jsonb_build_object('empleado_id', (select operario from k), 'unidad_id', (select id from j1), 'ficha_operacion_id', (select id from fo),
                                      'unidades', 1, 'ocurrido_en', now() + interval '1 hour'))) ->> 'estado' = 'rechazado',
                  'Una marcación con la hora en el futuro se rechaza');
-- sin conexión pudo marcar de más: se acepta y se avisa
select pg_temp.ok((select pg_temp.subir('f6100000-0000-0000-0000-00000000000b', 'marcaciones',
                   jsonb_build_object('empleado_id', (select operario from k), 'unidad_id', (select id from j1), 'ficha_operacion_id', (select id from fo),
                                      'unidades', 50, 'ocurrido_en', now() - interval '40 minutes'))) ->> 'estado' = 'aceptado',
                  'Marcar más de lo que trae el juego se acepta (no se pierde lo hecho sin conexión)');
select pg_temp.ok((select excede_unidad from marcaciones where id = 'f6100000-0000-0000-0000-00000000000b')
                  and exists (select 1 from alertas where tipo = 'marcacion_excede' and entidad_id = 'f6100000-0000-0000-0000-00000000000b'),
                  '… y queda marcada con alerta para el supervisor');
select pg_temp.ok((select pg_temp.subir('f6100000-0000-0000-0000-00000000000c', 'marcaciones',
                   jsonb_build_object('tipo', 'anulacion', 'anula_id', 'f6100000-0000-0000-0000-00000000000b', 'motivo', 'Toqué de más',
                                      'ocurrido_en', now()))) ->> 'estado' = 'aceptado', 'La marcación equivocada se anula con un evento');
select pg_temp.ok((select unidades = 3 from eficiencia_diaria where empleado_id = (select operario from k)), 'Al anular, la eficiencia vuelve a 3 unidades');
select pg_temp.ok((select hechas = 3 from avance_unidad_operacion where unidad_id = (select id from j1) and ficha_operacion_id = (select id from fo)),
                  'El avance de la operación en el juego cuenta 3 (sin la anulada)');
select pg_temp.falla($$delete from marcaciones$$, 'Las marcaciones no se borran');
select pg_temp.ok((select pg_temp.subir('f6100000-0000-0000-0000-00000000000d', 'marcaciones',
                   jsonb_build_object('empleado_id', (select operario from k), 'unidad_id', (select id from j1), 'ficha_operacion_id', (select id from fo),
                                      'unidades', 1, 'tipo', 'reproceso', 'ocurrido_en', now() - interval '30 minutes'))) ->> 'estado' = 'aceptado',
                  'Un reproceso se marca aparte');
select pg_temp.ok((select reprocesos = 1 from eficiencia_diaria where empleado_id = (select operario from k)), 'Reprocesos del día: 1');

-- ---------- 5. Entrega del módulo con buenas, segundas y faltantes ----------
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000004', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'entrega', 'buenas', 10, 'segundas', 0, 'faltantes', 0,
                                      'ocurrido_en', now()))) ->> 'estado' = 'rechazado', 'Entrega que no cuadra rechazada (regla 5)');
select pg_temp.ok((select pg_temp.subir('f6000000-0000-0000-0000-000000000005', 'eventos_unidad',
                   jsonb_build_object('unidad_id', (select id from j1), 'tipo', 'entrega', 'buenas', (select cantidad - 1 from j1), 'segundas', 1,
                                      'faltantes', 0, 'ocurrido_en', now()))) ->> 'estado' = 'aceptado', 'Entrega con una segunda aceptada');
select pg_temp.ok((select estado = 'en_espera' and proceso_actual = 'terminacion' and cantidad_actual = (select cantidad - 1 from j1)
                   from juegos where id = (select id from j1)), 'El juego sigue a terminación con las buenas');
select pg_temp.ok((select buenas = (select cantidad - 1 from j1) and segundas = 1 and estado = 'en_proceso' from op_procesos
                   where op_id = (select op from k) and proceso = 'confeccion'), 'Confección acumula buenas y segundas y sigue en proceso (faltan juegos)');
select pg_temp.ok((select count(*) = 2 from eventos_proceso where juego_id = (select id from j1) and proceso = 'confeccion'),
                  'Quedan dos eventos de confección del juego: recepción y entrega');
