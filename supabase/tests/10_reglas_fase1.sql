-- Pruebas de la Fase 1: inmutabilidad, ingesta idempotente, desfase de reloj,
-- auditoría, consecutivos y RLS por rol.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.ok(p_cond boolean, p_nombre text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALLÓ: %', p_nombre; end if;
  raise notice '✓ %', p_nombre;
end $$;

create or replace function pg_temp.falla(p_sql text, p_nombre text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice '✓ % (rechazado: %)', p_nombre, sqlerrm;
    return;
  end;
  raise exception 'FALLÓ: % (debía ser rechazado)', p_nombre;
end $$;

-- ---------- Usuarios de prueba ----------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','gerencia@prueba'),
  ('aaaaaaaa-0000-0000-0000-000000000002','jefe@prueba'),
  ('aaaaaaaa-0000-0000-0000-000000000003','tablet-ent@prueba'),
  ('aaaaaaaa-0000-0000-0000-000000000004','bodega@prueba'),
  ('aaaaaaaa-0000-0000-0000-000000000005','satelite@prueba'),
  ('aaaaaaaa-0000-0000-0000-000000000006','tablet-mod1@prueba');
insert into perfiles (id, nombre, es_dispositivo) values
  ('aaaaaaaa-0000-0000-0000-000000000001','Gerencia', false),
  ('aaaaaaaa-0000-0000-0000-000000000002','Jefe', false),
  ('aaaaaaaa-0000-0000-0000-000000000003','Tablet entrada', true),
  ('aaaaaaaa-0000-0000-0000-000000000004','Bodega', false),
  ('aaaaaaaa-0000-0000-0000-000000000005','Satélite', false),
  ('aaaaaaaa-0000-0000-0000-000000000006','Tablet MOD1', true);
insert into usuario_roles (usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000001','gerencia'),
  ('aaaaaaaa-0000-0000-0000-000000000002','jefe_produccion'),
  ('aaaaaaaa-0000-0000-0000-000000000003','dispositivo'),
  ('aaaaaaaa-0000-0000-0000-000000000004','bodega'),
  ('aaaaaaaa-0000-0000-0000-000000000005','satelite'),
  ('aaaaaaaa-0000-0000-0000-000000000006','dispositivo');
insert into dispositivos (id, usuario_id, estacion_id, nombre, tipo) values
  ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000003','1b000000-0000-0000-0000-000000000001','Tablet entrada','tablet'),
  ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000006','1b000000-0000-0000-0000-000000000002','Tablet MOD1','tablet');

-- ---------- Ingesta como tablet de entrada ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000003';

create temp table r as select ingerir_eventos(jsonb_build_object(
  'dispositivo_id','dddddddd-0000-0000-0000-000000000001',
  'hora_dispositivo', now(),
  'eventos', jsonb_build_array(
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','16000000-0000-0000-0000-000000000001','tipo','entrada','ocurrido_en', now() - interval '3 hours')),
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000002','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','99999999-0000-0000-0000-000000000000','tipo','entrada','ocurrido_en', now())),
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000003','tabla','asistencia_marcas','op','PATCH',
      'datos', jsonb_build_object('tipo','salida')),
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000004','tabla','tabla_inexistente','op','PUT','datos','{}'::jsonb)
  ))) as res;

select pg_temp.ok((select res->'resultados'->0->>'estado' from r) = 'aceptado', 'Marca de entrada sin conexión (hace 3 h) aceptada');
select pg_temp.ok((select res->'resultados'->1->>'estado' from r) = 'rechazado', 'Empleado inexistente rechazado con motivo');
select pg_temp.ok((select res->'resultados'->2->>'estado' from r) = 'rechazado', 'Operación PATCH sobre un evento rechazada');
select pg_temp.ok((select res->'resultados'->3->>'estado' from r) = 'rechazado', 'Tabla no admitida rechazada');

-- Reenvío duplicado (la tablet perdió la respuesta y vuelve a mandar el mismo lote)
create temp table r2 as select ingerir_eventos(jsonb_build_object(
  'dispositivo_id','dddddddd-0000-0000-0000-000000000001', 'hora_dispositivo', now(),
  'eventos', jsonb_build_array(
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000001','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','16000000-0000-0000-0000-000000000001','tipo','entrada','ocurrido_en', now() - interval '3 hours'))
  ))) as res;
select pg_temp.ok((select res->'resultados'->0->>'estado' from r2) = 'duplicado', 'Reenvío del mismo UUID responde "duplicado"');
select pg_temp.ok((select count(*) from asistencia_marcas where id = 'eeeeeeee-0000-0000-0000-000000000001') = 1, 'El duplicado no crea un segundo registro');
select pg_temp.ok((select estacion_id from asistencia_marcas where id = 'eeeeeeee-0000-0000-0000-000000000001') = '1b000000-0000-0000-0000-000000000001', 'La estación la asigna el servidor');

-- Tablet con la hora atrasada 20 minutos
create temp table r3 as select ingerir_eventos(jsonb_build_object(
  'dispositivo_id','dddddddd-0000-0000-0000-000000000001', 'hora_dispositivo', now() - interval '20 minutes',
  'eventos', jsonb_build_array(
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000005','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','16000000-0000-0000-0000-000000000002','tipo','entrada','ocurrido_en', now() - interval '20 minutes'))
  ))) as res;
select pg_temp.ok((select reloj_dudoso and abs(extract(epoch from ocurrido_en_servidor - now())) < 5
                   from asistencia_marcas where id = 'eeeeeeee-0000-0000-0000-000000000005'),
                  'Reloj atrasado: evento marcado "reloj dudoso" y hora corregida con el desfase');

-- Evento con hora en el futuro
create temp table r4 as select ingerir_eventos(jsonb_build_object(
  'dispositivo_id','dddddddd-0000-0000-0000-000000000001', 'hora_dispositivo', now(),
  'eventos', jsonb_build_array(
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000006','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','16000000-0000-0000-0000-000000000002','tipo','salida','ocurrido_en', now() + interval '1 hour'))
  ))) as res;
select pg_temp.ok((select res->'resultados'->0->>'estado' from r4) = 'rechazado', 'Evento con hora futura rechazado');

-- Una tablet no puede enviar a nombre de otra
select pg_temp.falla($$select ingerir_eventos(jsonb_build_object('dispositivo_id','dddddddd-0000-0000-0000-000000000002','hora_dispositivo',now(),'eventos','[]'::jsonb))$$,
                     'Tablet suplantando a otro dispositivo');
reset role;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe (persona, no tablet)
select pg_temp.falla($$select ingerir_eventos(jsonb_build_object('hora_dispositivo',now(),'eventos','[]'::jsonb))$$,
                     'Usuario que no es tablet enviando eventos');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000003';

-- Inserción directa (saltándose la ingesta) bloqueada por RLS
select pg_temp.falla($$insert into asistencia_marcas (id, empleado_id, tipo, estacion_id, dispositivo_id, ocurrido_en, ocurrido_en_servidor)
                      values (gen_random_uuid(),'16000000-0000-0000-0000-000000000001','entrada','1b000000-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001',now(),now())$$,
                     'Insertar asistencia sin pasar por la ingesta');
select pg_temp.ok((select count(*) from empleados_nomina) = 0, 'Tablet no ve datos de nómina');

-- Anulación: evento nuevo con motivo
create temp table r5 as select ingerir_eventos(jsonb_build_object(
  'dispositivo_id','dddddddd-0000-0000-0000-000000000001', 'hora_dispositivo', now(),
  'eventos', jsonb_build_array(
    jsonb_build_object('id','eeeeeeee-0000-0000-0000-000000000007','tabla','asistencia_marcas','op','PUT',
      'datos', jsonb_build_object('empleado_id','16000000-0000-0000-0000-000000000001','tipo','anulacion',
                                  'anula_id','eeeeeeee-0000-0000-0000-000000000001','motivo','Marcó con el carnet equivocado','ocurrido_en', now()))
  ))) as res;
select pg_temp.ok((select res->'resultados'->0->>'estado' from r5) = 'aceptado', 'Anulación registrada como evento nuevo');
select pg_temp.ok(not exists (select 1 from asistencia_marcas_vigentes where id = 'eeeeeeee-0000-0000-0000-000000000001'), 'La marca anulada ya no está vigente');
reset role;

-- ---------- Inmutabilidad (incluso para el dueño de la base) ----------
select pg_temp.falla($$update asistencia_marcas set tipo = 'salida' where id = 'eeeeeeee-0000-0000-0000-000000000005'$$, 'Editar un evento de asistencia');
select pg_temp.falla($$delete from asistencia_marcas where id = 'eeeeeeee-0000-0000-0000-000000000005'$$, 'Borrar un evento de asistencia');
select pg_temp.falla($$delete from auditoria$$, 'Borrar la auditoría');

-- ---------- Permisos por rol ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.ok((select count(*) from empleados) = 14, 'Bodega puede leer empleados');
update empleados set nombres = 'X' where codigo = 'E001';
select pg_temp.ok((select nombres from empleados where codigo = 'E001') <> 'X', 'Bodega NO puede editar empleados');
select pg_temp.falla($$insert into empleados (codigo, nombres, apellidos, qr) values ('E999','X','Y','OPR-9999')$$, 'Bodega creando empleados');
select pg_temp.ok((select count(*) from asistencia_marcas) = 0, 'Bodega no ve asistencia');

set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000005';  -- satélite
select pg_temp.ok((select count(*) from empleados) = 0, 'Satélite no ve empleados');
select pg_temp.ok((select count(*) from tallas) > 0, 'Satélite sí ve tallas');

set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
select pg_temp.ok((select count(*) from asistencia_marcas) = 3, 'Jefe de producción ve la asistencia');
select pg_temp.ok((mi_sesion()->'permisos') @> '[{"modulo":"asistencia","editar":true}]', 'mi_sesion() entrega permisos efectivos');
select pg_temp.ok(not ((mi_sesion()->'permisos') @> '[{"modulo":"costos"}]'), 'Jefe de producción no ve el módulo de costos');

set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';  -- gerencia
update empleados set nombres = 'Ana María (editado)' where codigo = 'E001';
select pg_temp.ok((select nombres from empleados where codigo = 'E001') = 'Ana María (editado)', 'Gerencia edita empleados');
insert into empleados_nomina (empleado_id, salario_base) values ('16000000-0000-0000-0000-000000000001', 1750905);
select pg_temp.ok((select count(*) from empleados_nomina) = 1, 'Gerencia registra y consulta nómina');
reset role;

select pg_temp.ok((select antes->>'nombres' = 'Ana María' and despues->>'nombres' = 'Ana María (editado)'
                     and usuario_id = 'aaaaaaaa-0000-0000-0000-000000000001'
                   from auditoria where tabla = 'empleados' and accion = 'UPDATE' order by id desc limit 1),
                  'Auditoría guarda antes, después y usuario');
select pg_temp.ok((select actualizado_por from empleados where codigo = 'E001') = 'aaaaaaaa-0000-0000-0000-000000000001', 'actualizado_por se llena solo');
select pg_temp.ok((select count(*) from alertas where tipo = 'reloj_dudoso') = 1, 'Alerta creada por reloj desfasado');

-- ---------- Consecutivos ----------
select pg_temp.ok((select split_part(b, '-', 2)::int = split_part(a, '-', 2)::int + 1
                   from (select siguiente_consecutivo('OP') a, siguiente_consecutivo('OP') b) x), 'Consecutivo de OP sin repetir (cada uno es el siguiente)');
