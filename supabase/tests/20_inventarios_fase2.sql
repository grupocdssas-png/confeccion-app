-- Pruebas de la Fase 2: kardex, saldos, reglas 1–4 y 7, ajustes con aprobación,
-- conteo físico desde el celular, traslados sin conexión, retazos, anulaciones, etiquetas.
-- Usa los usuarios creados en 10_reglas_fase1.sql (misma base).
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

-- Usuarios adicionales: costos (aprueba ajustes) y la tablet de bodega
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000007','tablet-bod@prueba'), ('aaaaaaaa-0000-0000-0000-000000000008','costos@prueba');
insert into perfiles (id, nombre, es_dispositivo) values
  ('aaaaaaaa-0000-0000-0000-000000000007','Tablet bodega', true), ('aaaaaaaa-0000-0000-0000-000000000008','Costos', false);
insert into usuario_roles (usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000007','dispositivo'), ('aaaaaaaa-0000-0000-0000-000000000008','costos'),
  ('aaaaaaaa-0000-0000-0000-000000000008','bodega');   -- puede crear y aprobar ajustes, pero no los suyos
insert into dispositivos (id, usuario_id, estacion_id, nombre, tipo) values
  ('dddddddd-0000-0000-0000-000000000007','aaaaaaaa-0000-0000-0000-000000000007','1b000000-0000-0000-0000-000000000004','Celular bodega','celular');

create temp table ids as select
  (select id from materiales where codigo = 'TEL-JER30') as jersey,
  (select id from materiales where codigo = 'INS-HIL40') as hilo,
  (select id from colores where codigo = 'N') as negro,
  (select id from ubicaciones where codigo = 'UB-BT-A01') as a01,
  (select id from ubicaciones where codigo = 'UB-BT-B01') as b01,
  (select id from ubicaciones where codigo = 'UB-BI-01') as bi01,
  '1a000000-0000-0000-0000-000000000001'::uuid as bt,
  '1a000000-0000-0000-0000-000000000002'::uuid as bi;
grant select on ids to authenticated;

-- ---------- Entrada de ejemplo ----------
select pg_temp.ok((select count(*) from rollos) = 6 and (select min(codigo) from rollos) = 'TL-000001', 'La entrada crea 6 rollos con código TL consecutivo');
select pg_temp.ok((select metros_saldo = metros_iniciales and kilos_saldo = kilos_iniciales from rollos where codigo = 'TL-000001'), 'Saldo del rollo = lo recibido');

-- Regla 3: el saldo es exactamente la suma del kardex
create or replace function pg_temp.saldos_cuadran() returns boolean language sql as $$
  select not exists (
    select 1 from saldos_inventario s
    full join (select material_id, color_id, bodega_id, ubicacion_id, sum(cantidad) c
               from movimientos_inventario where afecta = 'fisico' group by 1,2,3,4) k
      on k.material_id = s.material_id and k.color_id is not distinct from s.color_id
     and k.bodega_id = s.bodega_id and k.ubicacion_id is not distinct from s.ubicacion_id
    where coalesce(k.c, 0) <> coalesce(s.fisico, 0))
  and not exists (
    select 1 from rollos r
    where r.metros_saldo <> coalesce((select sum(metros) from movimientos_inventario where rollo_id = r.id and afecta = 'fisico'), 0))
$$;
select pg_temp.ok(pg_temp.saldos_cuadran(), 'Saldos y rollos = suma del kardex');
select pg_temp.ok((select fisico from saldos_por_material s, ids where s.material_id = ids.jersey and s.color_id = ids.negro) = 22.4 + 21.8 + 23.1 + 22.0,
                  'Jersey negro: 89,3 kg (4 rollos, unidad kg)');

-- Regla 4: disponible = físico − reservado
insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, ubicacion_id, cantidad, documento_tipo)
select 'reserva', 'reservado', hilo, negro, bi, bi01, 10, 'prueba' from ids;
select pg_temp.ok((select fisico = 24 and reservado = 10 and disponible = 14 from saldos_inventario s, ids
                   where s.material_id = ids.hilo and s.color_id = ids.negro), 'Disponible = físico − reservado (24 − 10 = 14)');

-- Regla 1: ninguna salida sin OP ni ajuste aprobado (ni siquiera el dueño de la base)
select pg_temp.falla($$insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, cantidad)
                      select 'salida_op', hilo, negro, bi, -2 from ids$$, 'Salida de material sin OP ni ajuste');
-- Regla 2: el kardex no se edita ni se borra
select pg_temp.falla($$update movimientos_inventario set cantidad = 0$$, 'Editar el kardex');
select pg_temp.falla($$delete from movimientos_inventario$$, 'Borrar el kardex');

-- ---------- Permisos ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.ok((select count(*) from rollos) = 6, 'Bodega ve los rollos');
select pg_temp.falla($$insert into movimientos_inventario (tipo, material_id, bodega_id, cantidad) select 'entrada_compra', hilo, bi, 5 from ids$$,
                     'Bodega insertando directo en el kardex (solo por funciones)');
update rollos set metros_saldo = 999 where codigo = 'TL-000001';
select pg_temp.ok((select metros_saldo from rollos where codigo = 'TL-000001') <> 999, 'Nadie cambia el saldo de un rollo a mano');

-- ---------- Ajustes ----------
insert into ajustes_inventario (id, motivo) values ('a1000000-0000-0000-0000-000000000001', 'Conos dañados por humedad');
insert into ajuste_lineas (ajuste_id, material_id, color_id, bodega_id, ubicacion_id, cantidad)
select 'a1000000-0000-0000-0000-000000000001', hilo, negro, bi, bi01, -2 from ids;
select enviar_ajuste('a1000000-0000-0000-0000-000000000001');
select pg_temp.falla($$update ajuste_lineas set cantidad = -20 where ajuste_id = 'a1000000-0000-0000-0000-000000000001'$$, 'Cambiar líneas de un ajuste enviado');
select pg_temp.falla($$update ajustes_inventario set estado = 'aprobado' where id = 'a1000000-0000-0000-0000-000000000001'$$, 'Aprobar con un UPDATE directo');
select pg_temp.falla($$select decidir_ajuste('a1000000-0000-0000-0000-000000000001', true)$$, 'Bodega aprobando su propio ajuste');
select pg_temp.ok((select fisico from saldos_inventario s, ids where s.material_id = ids.hilo and s.color_id = ids.negro) = 24, 'Sin aprobar, el stock no cambia');

set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000008';  -- costos
select pg_temp.falla($$select decidir_ajuste('a1000000-0000-0000-0000-000000000001', false)$$, 'Rechazar sin escribir el motivo');
select decidir_ajuste('a1000000-0000-0000-0000-000000000001', true, 'Verificado');
select pg_temp.ok((select fisico from saldos_inventario s, ids where s.material_id = ids.hilo and s.color_id = ids.negro) = 22, 'Ajuste aprobado: 24 − 2 = 22 conos');
select pg_temp.ok((select tipo = 'ajuste' and ajuste_id is not null from movimientos_inventario where documento_id = (select consecutivo from ajustes_inventario where id = 'a1000000-0000-0000-0000-000000000001')),
                  'El movimiento queda ligado al ajuste aprobado');
-- quien solicita no aprueba
insert into ajustes_inventario (id, motivo) values ('a1000000-0000-0000-0000-000000000002', 'Corrección de prueba');
insert into ajuste_lineas (ajuste_id, material_id, color_id, bodega_id, ubicacion_id, cantidad)
select 'a1000000-0000-0000-0000-000000000002', hilo, negro, bi, bi01, -1000 from ids;
select enviar_ajuste('a1000000-0000-0000-0000-000000000002');
select pg_temp.falla($$select decidir_ajuste('a1000000-0000-0000-0000-000000000002', true)$$, 'Aprobar un ajuste que uno mismo solicitó');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';  -- gerencia
select decidir_ajuste('a1000000-0000-0000-0000-000000000002', true, 'Prueba de saldo negativo');
select pg_temp.ok((select fisico from saldos_inventario s, ids where s.material_id = ids.hilo and s.color_id = ids.negro) = -978,
                  'Saldo negativo: se aplica igual');
reset role;
select pg_temp.ok(exists (select 1 from alertas where tipo = 'stock_negativo' and estado = 'abierta'), 'y se crea alerta para bodega');

-- ---------- Traslado desde el celular sin conexión ----------
-- (la tablet conoce los ids por su descarga; aquí los tomamos antes de cambiar de rol)
create temp table rol as select id, codigo, ubicacion_id from rollos;
grant select on rol to authenticated;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000007';  -- celular bodega
create temp table t1 as select ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos', jsonb_build_array(
  jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','tabla','traslados_rollo','op','PUT','datos',
    jsonb_build_object('rollo_id', (select id from rol where codigo = 'TL-000002'), 'ubicacion_destino_id', (select b01 from ids),
                       'ocurrido_en', now() - interval '1 hour'))))) as r;
create temp table t2 as select ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos', jsonb_build_array(
  jsonb_build_object('id','bbbbbbbb-0000-0000-0000-000000000001','tabla','traslados_rollo','op','PUT','datos',
    jsonb_build_object('rollo_id', (select id from rol where codigo = 'TL-000002'), 'ubicacion_destino_id', (select b01 from ids),
                       'ocurrido_en', now() - interval '1 hour'))))) as r;
reset role;
select pg_temp.ok((select r->'resultados'->0->>'estado' from t1) = 'aceptado' and (select r->'resultados'->0->>'estado' from t2) = 'duplicado',
                  'Traslado sin conexión aceptado; el reenvío responde duplicado');
select pg_temp.ok((select ubicacion_id from rollos where codigo = 'TL-000002') = (select b01 from ids), 'El rollo queda en la nueva ubicación');
select pg_temp.ok((select count(*) = 2 and sum(cantidad) = 0 from movimientos_inventario where documento_tipo = 'traslado'
                   and documento_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 'Traslado = 2 movimientos que suman cero (sin duplicar)');

-- ---------- Retazos ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
create temp table ret as select * from separar_retazo((select id from rollos where codigo = 'TL-000003'), 5.0, 1.45,
                                                      (select id from ubicaciones where codigo = 'UB-BT-RET'));
reset role;
select pg_temp.ok((select es_retazo and estado = 'retazo' and lote_tintura = 'L-2410-N1' and metros_saldo = 5 from ret),
                  'Retazo: rollo nuevo con el mismo lote y 5 m');
select pg_temp.ok((select fisico from saldos_por_material s, ids where s.material_id = ids.jersey and s.color_id = ids.negro) = 89.3,
                  'Separar un retazo no cambia el total del material');

-- ---------- Conteo físico con el celular ----------
drop table rol;
create temp table rol as select id, codigo, ubicacion_id from rollos;
grant select on rol to authenticated;
insert into conteos_fisicos (id, bodega_id, alcance) select 'c0000000-0000-0000-0000-000000000001', bt, 'telas' from ids;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000007';
create temp table t3 as select ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos', (
  select jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'tabla', 'conteo_registros', 'op', 'PUT', 'datos',
           jsonb_build_object('conteo_id', 'c0000000-0000-0000-0000-000000000001', 'rollo_id', r.id,
                              'ubicacion_id', case when r.codigo = 'TL-000005' then (select b01 from ids) else r.ubicacion_id end,
                              'ocurrido_en', now())))
  from rol r where r.codigo <> 'TL-000006'))) as r;   -- TL-000006 no aparece
reset role;
select pg_temp.ok((select bool_and(x->>'estado' = 'aceptado') from t3, jsonb_array_elements(r->'resultados') x), 'Registros de conteo sin conexión aceptados');
select pg_temp.ok((select count(*) from diferencias_conteo('c0000000-0000-0000-0000-000000000001') where observacion = 'Rollo no encontrado') = 1,
                  'Diferencias: 1 rollo no encontrado');
select pg_temp.ok((select count(*) from diferencias_conteo('c0000000-0000-0000-0000-000000000001') where observacion like 'Encontrado en otra%') = 1,
                  'Diferencias: 1 rollo en otra ubicación (informativo)');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';
create temp table aj as select cerrar_conteo('c0000000-0000-0000-0000-000000000001') as id;
reset role;
select pg_temp.ok((select estado = 'enviado' and origen = 'conteo' from ajustes_inventario where id = (select id from aj)), 'Cerrar el conteo genera un ajuste por aprobar');
select pg_temp.ok((select count(*) = 1 from ajuste_lineas where ajuste_id = (select id from aj)), 'Con una línea: el faltante');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000007';
create temp table t4 as select ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos', jsonb_build_array(
  jsonb_build_object('id', gen_random_uuid(), 'tabla', 'conteo_registros', 'op', 'PUT', 'datos',
    jsonb_build_object('conteo_id', 'c0000000-0000-0000-0000-000000000001', 'rollo_id', (select id from rol where codigo = 'TL-000006'),
                       'ocurrido_en', now()))))) as r;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000008';
select decidir_ajuste((select id from aj), true, 'Rollo perdido');
reset role;
select pg_temp.ok((select r->'resultados'->0->>'estado' from t4) = 'rechazado', 'Registro que llega después de cerrar el conteo: rechazado con motivo');
select pg_temp.ok((select estado from rollos where codigo = 'TL-000006') = 'agotado', 'Al aprobar, el rollo faltante queda agotado');
select pg_temp.ok((select estado from conteos_fisicos where id = 'c0000000-0000-0000-0000-000000000001') = 'ajustado', 'Conteo queda ajustado');

-- ---------- Anular entradas ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.falla($$select anular_recepcion('1e000000-0000-0000-0000-000000000001', 'Error')$$, 'Anular una entrada cuyos rollos ya se movieron');
select pg_temp.falla($$select anular_recepcion('1e000000-0000-0000-0000-000000000002', '')$$, 'Anular sin motivo');
select anular_recepcion('1e000000-0000-0000-0000-000000000002', 'Factura duplicada');
select pg_temp.falla($$update recepcion_lineas set cantidad = 1 where recepcion_id = '1e000000-0000-0000-0000-000000000002'$$, 'Editar una entrada anulada');
reset role;
select pg_temp.ok((select coalesce(sum(fisico), 0) from saldos_inventario s join materiales m on m.id = s.material_id
                   where m.codigo in ('INS-MARQ','INS-BOLSA')) = 0, 'Anulada: marquillas y bolsas vuelven a cero');
select pg_temp.ok(pg_temp.saldos_cuadran(), 'Después de todo, saldos y rollos siguen cuadrando con el kardex');

-- ---------- Etiquetas ----------
update plantillas_etiqueta set zpl = replace(zpl, '^A0N,52,52', '^A0N,56,56') where tipo = 'rollo';
select pg_temp.ok((select version from plantillas_etiqueta where tipo = 'rollo') = 2, 'Editar la plantilla ZPL sube la versión');
select pg_temp.falla($$update plantillas_etiqueta set zpl = '^XA^FDsin codificacion^FS^XZ' where tipo = 'rollo'$$, 'Plantilla sin ^CI28 (UTF-8)');
select pg_temp.falla($$insert into trabajos_impresion (id, entidad, codigo, es_reimpresion, estado_final) values (gen_random_uuid(), 'rollos', 'TL-000001', true, 'enviado')$$,
                     'Reimpresión sin motivo');
