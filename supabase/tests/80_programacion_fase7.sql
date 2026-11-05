-- Pruebas de la Fase 7: capacidad por célula, cola de programación, fecha posible de
-- entrega y balanceo (métricas iguales a la app, validaciones al publicar, versiones).
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

-- ---------- 1. Métricas del balanceo: mismo caso que la app ----------
\set vectores `jq -s -c . :raiz/test_vectores/balanceo/*.json`
create temp table vectores as select v from jsonb_array_elements(:'vectores'::jsonb) v;
do $$
declare v jsonb; e jsonb; r jsonb; c numeric[];
begin
  for v in select x.v from vectores x loop
    e := v -> 'esperado';
    -- las cargas se toman sin redondear de las operaciones (como la app)
    c := array(select sum(o.minutos) from (
           select pu ->> 'numero' as n, (a ->> 'fraccion')::numeric * (op ->> 'sam')::numeric * (op ->> 'repeticiones')::numeric as minutos
           from jsonb_array_elements(e -> 'puestos') pu, jsonb_array_elements(pu -> 'asignaciones') a, jsonb_array_elements(v -> 'operaciones') op
           where op ->> 'id' = a ->> 'operacion_id') o group by o.n order by o.n::int);
    r := metricas_balanceo_calc((select sum((op ->> 'sam')::numeric * (op ->> 'repeticiones')::numeric) from jsonb_array_elements(v -> 'operaciones') op),
                                (v ->> 'operarios')::int, (v ->> 'eficiencia_pct')::numeric, (v ->> 'minutos_turno')::numeric, c, (v ->> 'pendientes')::int);
    perform pg_temp.ok(r - 'cargas' = (e -> 'metricas') - 'cargas', (v ->> 'nombre') || ': métricas iguales a la app');
  end loop;
end $$;

-- ---------- 2. Capacidad ----------
create temp table k as
select '15000000-0000-0000-0000-000000000001'::uuid as mod1, '15000000-0000-0000-0000-000000000002'::uuid as mod2,
       '15000000-0000-0000-0000-000000000003'::uuid as cort,
       (hoy_bogota() + (8 - extract(isodow from hoy_bogota())::int))::date as lunes;   -- el próximo lunes
grant select on k to authenticated;
select pg_temp.ok(minutos_turno('14000000-0000-0000-0000-000000000001') = 510, 'Turno día: 6:00 a 15:30 menos 60 min de pausa = 510 min');
select pg_temp.ok(capacidad_celula((select mod1 from k), (select lunes from k)) = 510 * (select count(*) from empleados where celula_id = (select mod1 from k) and activo),
                  'Capacidad de un lunes = 510 min × operarios activos de la célula');
select pg_temp.ok(capacidad_celula((select mod1 from k), (select lunes + 5 from k)) = 0, 'El sábado no es día laboral del módulo');
insert into festivos values ((select lunes + 1 from k), 'Festivo de EJEMPLO');
select pg_temp.ok(capacidad_celula((select mod1 from k), (select lunes + 1 from k)) = 0, 'Un festivo no tiene capacidad');

-- ---------- 3. Programación ----------
create temp table ops as
select o.id, o.consecutivo, row_number() over (order by o.consecutivo) as n
from ordenes_produccion o join op_procesos p on p.op_id = o.id and p.proceso = 'confeccion'
where o.estado in ('planeada','en_proceso') and p.estado <> 'terminado' order by o.consecutivo limit 2;
grant select on ops to authenticated;
select pg_temp.ok((select count(*) = 2 from ops), 'Hay dos OP con confección pendiente');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.falla($$select programar_op((select id from ops where n = 1), 'confeccion', (select mod1 from k))$$, 'Bodega no programa');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
select pg_temp.falla($$select programar_op((select id from ops where n = 1), 'confeccion', (select cort from k))$$, 'Una OP no se programa en confección en la célula de corte');
select programar_op((select id from ops where n = 1), 'confeccion', (select mod1 from k));
select programar_op((select id from ops where n = 2), 'confeccion', (select mod1 from k));
reset role;
select pg_temp.ok((select minutos_requeridos = minutos_pendientes(op_id, 'confeccion', 80) and minutos_requeridos > 0 from programacion where op_id = (select id from ops where n = 1)),
                  'Minutos requeridos = prendas pendientes × SAM de confección / 80 %');
select pg_temp.ok((select a.fin_plan <= b.inicio_plan and a.inicio_plan = hoy_bogota() or extract(isodow from hoy_bogota()) in (6, 7)
                   from programacion a, programacion b where a.op_id = (select id from ops where n = 1) and b.op_id = (select id from ops where n = 2)),
                  'La segunda OP empieza cuando termina la primera');
set role authenticated;
select mover_programacion((select id from programacion where op_id = (select id from ops where n = 2)), -1);
reset role;
select pg_temp.ok((select orden = 1 from programacion where op_id = (select id from ops where n = 2) and orden < (select orden from programacion where op_id = (select id from ops where n = 1))),
                  'Subir una OP en la cola la pone primero');
select pg_temp.ok((select count(*) = 60 and bool_and((d ->> 'carga')::numeric <= (d ->> 'capacidad')::numeric + 0.1)
                   from jsonb_array_elements(programar_cola((select mod1 from k), false) -> 'dias') d), 'La carga de cada día nunca pasa la capacidad');
select pg_temp.ok((select sum((d ->> 'carga')::numeric) from jsonb_array_elements(programar_cola((select mod1 from k), false) -> 'dias') d)
                  = (select sum(minutos_requeridos) from programacion where celula_id = (select mod1 from k)), 'Lo cargado suma lo requerido de la cola');

-- fecha posible de entrega (no guarda nada)
set role authenticated;
create temp table fp as select * from fecha_posible((select id from referencias where codigo = 'CAM-001'), 500);
reset role;
select pg_temp.ok((select count(*) = 2 and bool_and(fecha_fin is not null) from fp), 'Fecha posible para 500 camisetas en cada módulo');
select pg_temp.ok((select (select fecha_fin from fp where codigo = 'MOD2') <= (select fecha_fin from fp where codigo = 'MOD1')),
                  'El módulo sin cola termina antes o igual que el que tiene OP programadas');
update celulas set operarios_planeados = 0 where id = (select mod2 from k);
select pg_temp.ok((select fecha_fin is null from fecha_posible((select id from referencias where codigo = 'CAM-001'), 500) where codigo = 'MOD2'),
                  'Sin operarios no hay fecha posible');
update celulas set operarios_planeados = null where id = (select mod2 from k);

-- ---------- 4. Balanceo ----------
create temp table fo as
select f.id, f.sam * f.repeticiones as minutos, row_number() over (order by f.secuencia) as n
from ficha_operaciones f where f.ficha_id = (select ficha_version_id from ordenes_produccion where id = (select id from ops where n = 1)) and f.proceso = 'confeccion';
grant select on fo to authenticated;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
create temp table b1 as select guardar_balanceo(jsonb_build_object('op_id', (select id from ops where n = 1), 'celula_id', (select mod1 from k),
  'operarios', 2, 'eficiencia_objetivo', 80, 'minutos_turno', 510,
  'puestos', jsonb_build_array(
    jsonb_build_object('numero', 1, 'empleado_id', '16000000-0000-0000-0000-000000000001',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', case when n = 1 then 0.5 else 1 end)) from fo where n <= 4)),
    jsonb_build_object('numero', 2, 'empleado_id', '16000000-0000-0000-0000-000000000002',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', 1)) from fo where n > 4))))) as id;
select pg_temp.falla($$select publicar_balanceo((select id from b1))$$, 'No se publica con una operación asignada al 50 %');
select guardar_balanceo(jsonb_build_object('id', (select id from b1), 'operarios', 2, 'minutos_turno', 510,
  'puestos', jsonb_build_array(
    jsonb_build_object('numero', 1, 'empleado_id', '16000000-0000-0000-0000-000000000001',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', case when n = 1 then 0.5 else 1 end)) from fo where n <= 4)),
    jsonb_build_object('numero', 2, 'empleado_id', '16000000-0000-0000-0000-000000000001',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', case when n = 1 then 0.5 else 1 end)) from fo where n = 1 or n > 4)))));
select pg_temp.falla($$select publicar_balanceo((select id from b1))$$, 'No se publica con el mismo operario en dos puestos');
select guardar_balanceo(jsonb_build_object('id', (select id from b1), 'operarios', 2, 'minutos_turno', 510,
  'puestos', jsonb_build_array(
    jsonb_build_object('numero', 1, 'empleado_id', '16000000-0000-0000-0000-000000000001',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', case when n = 1 then 0.5 else 1 end)) from fo where n <= 4)),
    jsonb_build_object('numero', 2, 'empleado_id', '16000000-0000-0000-0000-000000000002',
      'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', case when n = 1 then 0.5 else 1 end)) from fo where n = 1 or n > 4)))));
create temp table m1 as select publicar_balanceo((select id from b1)) as m;
reset role;
select pg_temp.ok((select estado = 'publicado' from balanceos where id = (select id from b1)), 'El balanceo queda publicado (llega a las tablets)');
select pg_temp.ok((select (m ->> 'sam_total')::numeric = round((select sum(minutos) from fo), 4) and (m ->> 'ciclo')::numeric = round((select sum(minutos) from fo) / 2, 4) from m1),
                  'SAM total de confección y tiempo de ciclo = SAM / 2 operarios');
select pg_temp.ok((select (m ->> 'meta_hora')::numeric = round(60 * 2 * 0.8 / (select sum(minutos) from fo), 2) from m1), 'Meta por hora = 60 × operarios × eficiencia / SAM');
select pg_temp.ok((select jsonb_array_length(m -> 'cargas') = 2 and (m ->> 'pct_balance')::numeric > 0 and (m ->> 'pct_balance')::numeric <= 100 from m1),
                  'Carga por puesto y % de balance');
select pg_temp.falla($$update balanceos set operarios = 9 where id = (select id from b1)$$, 'Un balanceo publicado no se edita a mano');
set role authenticated;
create temp table b2 as select guardar_balanceo(jsonb_build_object('id', (select id from b1), 'operarios', 1, 'minutos_turno', 510,
  'puestos', jsonb_build_array(jsonb_build_object('numero', 1, 'asignaciones', (select jsonb_agg(jsonb_build_object('ficha_operacion_id', id, 'fraccion', 1)) from fo))))) as id;
select publicar_balanceo((select id from b2));
reset role;
select pg_temp.ok((select version = 2 from balanceos where id = (select id from b2)) and (select estado = 'reemplazado' from balanceos where id = (select id from b1)),
                  'Cambiar uno publicado crea la versión 2; al publicarla, la 1 queda reemplazada');
