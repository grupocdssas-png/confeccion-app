-- Pruebas de la Fase 8: paros que descuentan tiempo (misma regla que la tablet),
-- informes de eficiencia y paros, incentivos por tramos y tableros de TV.
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
create or replace function pg_temp.subir(p_id uuid, p_tabla text, p_datos jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000006', true);   -- tablet MOD1
  r := ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos',
         jsonb_build_array(jsonb_build_object('id', p_id, 'tabla', p_tabla, 'op', 'PUT', 'datos', p_datos))));
  reset role;
  return r -> 'resultados' -> 0;
end $$;

create temp table k as
select j.id as juego, (select f.id from ficha_operaciones f join operaciones o on o.id = f.operacion_id
                       where f.ficha_id = (select ficha_version_id from ordenes_produccion where id = j.op_id) and o.codigo = 'CAM-010') as fo,
       (select f.sam * f.repeticiones from ficha_operaciones f join operaciones o on o.id = f.operacion_id
         where f.ficha_id = (select ficha_version_id from ordenes_produccion where id = j.op_id) and o.codigo = 'CAM-010') as esperado,
       '16000000-0000-0000-0000-000000000005'::uuid as operario,
       (select id from causas_paro where codigo = 'MAQ') as maq, (select id from causas_paro where codigo = 'MAT') as mat,
       now() - interval '50 minutes' as t0
from juegos j where j.estado <> 'anulado' order by j.codigo limit 1;
grant select on k to authenticated;

-- ---------- 1. Paro por daño de máquina entre dos marcaciones ----------
select pg_temp.ok((select pg_temp.subir('f8000000-0000-0000-0000-000000000001', 'marcaciones', jsonb_build_object('empleado_id', operario, 'unidad_id', juego,
                   'ficha_operacion_id', fo, 'unidades', 1, 'ocurrido_en', t0)) from k) ->> 'estado' = 'aceptado', 'Primera marcación');
select pg_temp.ok((select pg_temp.subir('f8100000-0000-0000-0000-000000000001', 'paros', jsonb_build_object('causa_id', maq, 'empleado_id', operario,
                   'observacion', 'Se reventó la aguja (EJEMPLO)', 'ocurrido_en', t0 + interval '2 minutes')) from k) ->> 'estado' = 'aceptado',
                  'La tablet reporta el paro por daño de máquina');
select pg_temp.ok((select activo from paros_vista where id = 'f8100000-0000-0000-0000-000000000001'), 'El paro está activo');
select pg_temp.ok((select pg_temp.subir('f8200000-0000-0000-0000-000000000001', 'paro_eventos', jsonb_build_object('paro_id', 'f8100000-0000-0000-0000-000000000001',
                   'tipo', 'fin', 'validador_empleado_id', '16000000-0000-0000-0000-000000000006', 'ocurrido_en', t0 + interval '47 minutes')) from k) ->> 'estado' = 'aceptado',
                  'Fin del paro (validado con el carnet de otro empleado)');
select pg_temp.ok((select pg_temp.subir('f8200000-0000-0000-0000-000000000002', 'paro_eventos', jsonb_build_object('paro_id', 'f8100000-0000-0000-0000-000000000001',
                   'tipo', 'fin', 'ocurrido_en', t0 + interval '48 minutes')) from k) ->> 'estado' = 'duplicado', 'Un segundo fin (otra tablet) no lo cambia');
select pg_temp.ok((select pg_temp.subir('f8000000-0000-0000-0000-000000000002', 'marcaciones', jsonb_build_object('empleado_id', operario, 'unidad_id', juego,
                   'ficha_operacion_id', fo, 'unidades', 1, 'ocurrido_en', t0 + interval '48 minutes')) from k) ->> 'estado' = 'aceptado', 'Segunda marcación 48 min después');
select pg_temp.ok((select minutos_paro = 45 and minutos_reales = 3 and eficiencia = round(minutos_esperados / 3 * 100, 2)
                   from marcaciones where id = 'f8000000-0000-0000-0000-000000000002'),
                  'Se descuentan los 45 min de paro: 3 min reales (sin el paro no se habría medido)');
select pg_temp.ok((select pg_temp.subir('f8000000-0000-0000-0000-000000000003', 'marcaciones', jsonb_build_object('empleado_id', operario, 'unidad_id', juego,
                   'ficha_operacion_id', fo, 'unidades', 1, 'ocurrido_en', t0 + interval '48 minutes 30 seconds')) from k) ->> 'estado' = 'aceptado', 'Tercera marcación');

-- paro de toda la célula y anulación
select pg_temp.ok((select pg_temp.subir('f8100000-0000-0000-0000-000000000002', 'paros', jsonb_build_object('causa_id', mat, 'empleado_id', operario,
                   'ocurrido_en', now() - interval '5 minutes')) from k) ->> 'estado' = 'aceptado', 'Paro de célula por falta de material');
select pg_temp.ok((select empleado_id is null and celula_id = '15000000-0000-0000-0000-000000000001' from paros where id = 'f8100000-0000-0000-0000-000000000002'),
                  'Un paro que detiene la célula queda para toda la célula');
select pg_temp.ok((select pg_temp.subir('f8200000-0000-0000-0000-000000000003', 'paro_eventos', jsonb_build_object('paro_id', 'f8100000-0000-0000-0000-000000000001',
                   'tipo', 'anulacion', 'ocurrido_en', now())) from k) ->> 'estado' = 'rechazado', 'Anular un paro exige motivo');
select pg_temp.falla($$delete from paros$$, 'Los paros no se borran');

-- ---------- 2. Informes ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
create temp table inf as select * from informe_eficiencia(hoy_bogota(), hoy_bogota(), 'operario', 'dia');
create temp table pl as select * from informe_eficiencia(hoy_bogota(), hoy_bogota(), 'planta', 'dia');
create temp table pa as select * from informe_paros(hoy_bogota(), hoy_bogota());
reset role;
select pg_temp.ok((select unidades = 3 and minutos_paro = 45 and eficiencia = round((select esperado from k) * 2 / 3.5 * 100, 1)
                   from inf where clave = (select operario from k)),
                  'Eficiencia del operario = esperados / reales de las marcaciones medidas (2 de 3)');
select pg_temp.ok((select count(*) = 1 and bool_and(codigo = 'PLANTA') from pl), 'Total planta');
select pg_temp.ok((select minutos = 45 and causa = 'Daño de máquina' and validado = false from pa where paro_id = 'f8100000-0000-0000-0000-000000000001'),
                  'Informe de paros: 45 min de daño de máquina');
select pg_temp.ok((select operario = 'Toda la célula' from pa where paro_id = 'f8100000-0000-0000-0000-000000000002'), 'El paro de célula aparece para toda la célula');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.falla($$select * from informe_eficiencia(hoy_bogota(), hoy_bogota())$$, 'Bodega no ve eficiencias');
reset role;
reset request.jwt.claim.sub;

-- ---------- 3. Incentivos por tramos ----------
insert into grupos_incentivo (id, nombre, tipo, periodo, minimo_minutos) values ('9a000000-0000-0000-0000-000000000001', 'Prueba individual', 'individual', 'quincena', 0);
insert into incentivo_tramos (grupo_id, desde_pct, hasta_pct, valor) values
  ('9a000000-0000-0000-0000-000000000001', 0, 30, 0), ('9a000000-0000-0000-0000-000000000001', 30, 60, 20000), ('9a000000-0000-0000-0000-000000000001', 60, null, 50000);
update celulas set grupo_incentivo_id = '9a000000-0000-0000-0000-000000000001' where codigo = 'MOD1';
create temp table li as select * from liquidar_incentivos(hoy_bogota(), hoy_bogota());
select pg_temp.ok((select valor = case when eficiencia >= 60 then 50000 when eficiencia >= 30 then 20000 else 0 end from li where empleado_id = (select operario from k)),
                  'El incentivo sale del tramo de su eficiencia en la quincena');
update grupos_incentivo set minimo_minutos = 500 where id = '9a000000-0000-0000-0000-000000000001';
select pg_temp.ok((select valor = 0 from liquidar_incentivos(hoy_bogota(), hoy_bogota()) where empleado_id = (select operario from k)),
                  'Sin el mínimo de minutos medidos no hay incentivo');
update grupos_incentivo set tipo = 'modular', minimo_minutos = 0 where id = '9a000000-0000-0000-0000-000000000001';
select pg_temp.ok((select count(distinct eficiencia) = 1 from liquidar_incentivos(hoy_bogota(), hoy_bogota()) where celula = 'MOD1'),
                  'Modular: todos los de la célula con la eficiencia de la célula');
update celulas set grupo_incentivo_id = null where codigo = 'MOD1';

-- ---------- 4. Tableros de TV ----------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000013', 'tv@prueba');
insert into perfiles (id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000013', 'TV');
insert into usuario_roles (usuario_id, rol) values ('aaaaaaaa-0000-0000-0000-000000000013', 'tv');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000013';
create temp table tc as select tablero_celula('15000000-0000-0000-0000-000000000001') as t;
create temp table tp as select tablero_planta() as t;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';
select pg_temp.falla($$select tablero_planta()$$, 'Bodega no abre el tablero');
reset role;
select pg_temp.ok((select t -> 'paro_activo' ->> 'causa' = 'Falta de material o trabajo' from tc), 'El tablero de la célula muestra el paro activo');
select pg_temp.ok((select (t ->> 'meta_hora')::numeric > 0 and jsonb_array_length(t -> 'operarios') >= 1 and jsonb_array_length(t -> 'hora_a_hora') >= 1 from tc),
                  'Meta por hora, eficiencia por operario y hora a hora');
select pg_temp.ok((select jsonb_array_length(t -> 'celulas') = 2 and jsonb_array_length(t -> 'procesos') >= 3 from tp), 'Tablero de planta: módulos y avance por proceso');
