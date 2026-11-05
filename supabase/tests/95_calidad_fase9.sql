-- Pruebas de la Fase 9: muestreo (mismos casos que la app), auditoría final y
-- en proceso desde la tablet de calidad, devoluciones a operario y operación,
-- reprocesos, ingreso a producto terminado y segundas, ajustes, traslados,
-- despachos a pedidos e informes de eficacia.
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
-- Sube un evento como una tablet (sub = usuario de la tablet)
create or replace function pg_temp.subir(p_sub text, p_id uuid, p_tabla text, p_datos jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', p_sub, true);
  r := ingerir_eventos(jsonb_build_object('hora_dispositivo', now(), 'eventos',
         jsonb_build_array(jsonb_build_object('id', p_id, 'tabla', p_tabla, 'op', 'PUT', 'datos', p_datos))));
  reset role;
  return r -> 'resultados' -> 0;
end $$;
-- Ejecuta como un usuario de la web
create or replace function pg_temp.como(p_sub text, p_sql text) returns void language plpgsql as $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', p_sub, true);
  execute p_sql;
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- ---------- Usuarios: tablet de calidad y Calidad en la web ----------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000019','tablet-cal@prueba'), ('aaaaaaaa-0000-0000-0000-000000000020','calidad@prueba');
insert into perfiles (id, nombre, es_dispositivo) values
  ('aaaaaaaa-0000-0000-0000-000000000019','Tablet calidad', true), ('aaaaaaaa-0000-0000-0000-000000000020','Calidad', false);
insert into usuario_roles (usuario_id, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000019','dispositivo'), ('aaaaaaaa-0000-0000-0000-000000000020','calidad');
insert into dispositivos (id, usuario_id, estacion_id, nombre, tipo) values
  ('dddddddd-0000-0000-0000-000000000019','aaaaaaaa-0000-0000-0000-000000000019','1b000000-0000-0000-0000-000000000006','Tablet calidad','tablet');

-- ---------- 1. Muestreo: mismos casos que la app ----------
\set vectores `jq -s -c . :raiz/test_vectores/calidad/*.json`
create temp table vectores as select v from jsonb_array_elements(:'vectores'::jsonb) v;
select pg_temp.ok((select bool_and(v->'plan' = (select tabla from planes_muestreo where por_defecto)) from vectores),
                  'El plan por defecto del servidor es el mismo de los casos de prueba');
do $$
declare v jsonb; c jsonb; m record;
begin
  for v in select x.v from vectores x loop
    for c in select * from jsonb_array_elements(v->'casos') loop
      select * into m from muestreo(null, (c->>'lote')::int);
      if m.muestra <> (c->>'muestra')::int or m.acepta <> (c->>'acepta')::int
         or (case when (c->>'defectuosas')::int <= m.acepta then 'aprobado' else 'rechazado' end) <> c->>'resultado' then
        raise exception 'FALLÓ: muestreo "%": muestra % acepta %', c->>'nombre', m.muestra, m.acepta;
      end if;
    end loop;
  end loop;
  raise notice '✓ Muestreo: muestra, aceptación y resultado iguales a la app en todos los casos';
end $$;
select pg_temp.falla($$select muestreo(null, 0)$$, 'Un lote sin prendas no se muestrea');

-- ---------- Datos: el primer juego de la OP (pasó por confección con 1 segunda) ----------
create temp table k as
select j.id as juego, j.codigo, j.op_id as op, j.talla_id as talla,
       (select m.ficha_operacion_id from marcaciones m where m.juego_id = j.id and m.tipo = 'normal'
         group by 1 order by sum(m.unidades) desc limit 1) as fo,
       (select id from defectos where codigo = 'PSA') as psa,
       (select id from defectos where codigo = 'MED') as med,
       (select m.id from ficha_medidas m join ordenes_produccion o on o.ficha_version_id = m.ficha_id where o.id = j.op_id order by m.orden limit 1) as medida
from juegos j where j.op_id = (select op_id from juegos where estado <> 'anulado' order by codigo limit 1) order by j.codigo limit 1;
alter table k add column operario uuid, add column esperado numeric, add column tol numeric, add column otro uuid;
update k set operario = (select m.empleado_id from marcaciones m where m.juego_id = k.juego and m.ficha_operacion_id = k.fo and m.tipo = 'normal'
                            and not exists (select 1 from marcaciones a where a.anula_id = m.id)
                          group by 1 order by sum(m.unidades) desc, max(m.ocurrido_en_servidor) desc limit 1),
             esperado = (select valor_cm from ficha_medida_tallas where medida_id = k.medida and talla_id = k.talla),
             tol = (select tolerancia_cm from ficha_medida_tallas where medida_id = k.medida and talla_id = k.talla),
             otro = (select id from juegos where op_id = k.op and id <> k.juego and proceso_actual = 'confeccion' and estado <> 'anulado' order by codigo limit 1);
grant select on k to authenticated;
select pg_temp.ok((select fo is not null and operario is not null and medida is not null and esperado is not null and otro is not null from k),
                  'Hay un juego con operaciones marcadas y medidas en la ficha');

-- ---------- 2. Segundas de confección → bodega de segundas ----------
select pg_temp.ok((select count(*) = 1 and sum(m.cantidad) = 1 and bool_and(b.tipo = 'segundas') and bool_and(s.codigo like 'PT-CAM-001-%')
                   from movimientos_producto m join bodegas b on b.id = m.bodega_id join skus s on s.id = m.sku_id
                   where m.juego_id = (select juego from k) and m.tipo = 'ingreso_segunda'),
                  'La segunda de confección entró a la bodega de segundas con su SKU (referencia, color y talla)');

-- ---------- 3. Terminación → calidad ----------
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', format($$select mover_unidad(%L, 'recepcion', 'terminacion')$$, (select codigo from k)));
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002',
  format($$select mover_unidad(%L, 'entrega', 'terminacion', null, %s, 0, 0)$$, (select codigo from k), (select cantidad_actual from juegos where id = (select juego from k))));
select pg_temp.ok((select proceso_actual = 'calidad' and estado = 'en_espera' from juegos where id = (select juego from k))
                  and not exists (select 1 from movimientos_producto where juego_id = (select juego from k) and tipo = 'ingreso_op'),
                  'Terminación entrega a calidad y todavía no entra a producto terminado');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', format($$select mover_unidad(%L, 'recepcion', 'calidad')$$, (select codigo from k)));
select pg_temp.falla(format($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select mover_unidad(''%s'', ''entrega'', ''calidad'', null, %s, 0, 0)')$$,
                     (select codigo from k), (select cantidad_actual from juegos where id = (select juego from k))),
                     'No se entrega desde calidad sin auditoría final');

-- ---------- 4. Auditoría rechazada (grupal) ----------
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000001', 'inspecciones',
                   jsonb_build_object('tipo', 'auditoria_final', 'unidad_id', juego, 'inspector_id', '16000000-0000-0000-0000-000000000015',
                     'alcance', 'grupal', 'ocurrido_en', now() - interval '30 minutes',
                     'defectos', jsonb_build_array(jsonb_build_object('defecto_id', psa, 'cantidad', 1, 'ficha_operacion_id', fo)))) from k) ->> 'estado' = 'aceptado',
                  'La tablet de calidad sube la auditoría');
select pg_temp.ok((select resultado = 'rechazado' and alcance = 'grupal' and tamano_muestra = 5 and acepta = 0 and defectuosas = 1
                     and celula_id = '15000000-0000-0000-0000-000000000001' and consecutivo like 'INS-%'
                   from inspecciones where id = 'f9000000-0000-0000-0000-000000000001'),
                  'Paquete de hasta 20: revisa 5, acepta 0; 1 con defecto → rechazado; queda a cargo del Módulo 1');
select pg_temp.ok((select empleado_id = (select operario from k) and alcance = 'grupal' and estado = 'abierta' and cantidad = 1
                   from devoluciones_calidad where inspeccion_id = 'f9000000-0000-0000-0000-000000000001'),
                  'La devolución queda para el operario que hizo la operación (sale de sus marcaciones)');
select pg_temp.ok(exists (select 1 from alertas where tipo = 'auditoria_rechazada' and entidad_id = 'f9000000-0000-0000-0000-000000000001'),
                  'Alerta de auditoría rechazada');
select pg_temp.falla(format($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select mover_unidad(''%s'', ''entrega'', ''calidad'', null, %s, 0, 0)')$$,
                     (select codigo from k), (select cantidad_actual from juegos where id = (select juego from k))),
                     'Un juego rechazado no sale de calidad');
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000002', 'inspecciones',
                   jsonb_build_object('tipo', 'auditoria_final', 'unidad_id', juego, 'ocurrido_en', now(),
                     'defectos', jsonb_build_array(jsonb_build_object('defecto_id', psa, 'cantidad', 6)))) from k) ->> 'estado' = 'rechazado',
                  'No puede haber más prendas con defecto que revisadas');

-- ---------- 5. El operario marca el reproceso ----------
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000006', 'f9100000-0000-0000-0000-000000000001', 'marcaciones',
                   jsonb_build_object('empleado_id', operario, 'unidad_id', juego, 'ficha_operacion_id', fo, 'unidades', 1, 'tipo', 'reproceso',
                     'ocurrido_en', now() - interval '20 minutes')) from k) ->> 'estado' = 'aceptado', 'El operario marca el reproceso en la tablet del módulo');
select pg_temp.ok((select estado = 'reprocesada' and reprocesadas = 1 from devoluciones_calidad where inspeccion_id = 'f9000000-0000-0000-0000-000000000001'),
                  'El reproceso cierra su devolución');

-- ---------- 6. Medida fuera de tolerancia ----------
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000003', 'inspecciones',
                   jsonb_build_object('tipo', 'auditoria_final', 'unidad_id', juego, 'ocurrido_en', now() - interval '15 minutes',
                     'medidas', jsonb_build_array(jsonb_build_object('medida_id', medida, 'valor_cm', esperado + tol + 1)))) from k) ->> 'estado' = 'aceptado',
                  'Auditoría con una medida');
select pg_temp.ok((select i.resultado = 'rechazado' and i.defectuosas = 1 and i.alcance = 'individual'
                     and (select fuera_tolerancia from inspeccion_medidas where inspeccion_id = i.id)
                     and (select d.defecto_id = (select med from k) from inspeccion_defectos d where d.inspeccion_id = i.id)
                   from inspecciones i where i.id = 'f9000000-0000-0000-0000-000000000003'),
                  'Medida fuera de tolerancia = prenda con defecto "Medida" → rechazado');

-- ---------- 7. El inspector recibe el arreglo ----------
create temp table dv as select id from devoluciones_calidad where inspeccion_id = 'f9000000-0000-0000-0000-000000000003';
grant select on dv to authenticated;
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9200000-0000-0000-0000-000000000001', 'devolucion_cierres',
                   jsonb_build_object('devolucion_id', id, 'reprocesadas', 2, 'segundas', 0, 'ocurrido_en', now())) from dv) ->> 'estado' = 'rechazado',
                  'Cierre con cantidades que no cuadran');
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9200000-0000-0000-0000-000000000002', 'devolucion_cierres',
                   jsonb_build_object('devolucion_id', id, 'reprocesadas', 1, 'segundas', 0, 'empleado_id', '16000000-0000-0000-0000-000000000015',
                     'ocurrido_en', now() - interval '10 minutes')) from dv) ->> 'estado' = 'aceptado', 'Arreglo recibido');
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9200000-0000-0000-0000-000000000003', 'devolucion_cierres',
                   jsonb_build_object('devolucion_id', id, 'reprocesadas', 1, 'segundas', 0, 'ocurrido_en', now())) from dv) ->> 'estado' <> 'rechazado',
                  'La segunda tablet no recibe error');
select pg_temp.ok((select count(*) = 1 from devolucion_cierres where devolucion_id = (select id from dv)),
                  'Otra tablet sin conexión cierra la misma devolución: no se duplica');
select pg_temp.ok((select estado = 'reprocesada' from devoluciones_calidad where id = (select id from dv)), 'Devolución cerrada');

-- ---------- 8. Reinspección aprobada y entrega a producto terminado ----------
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000004', 'inspecciones',
                   jsonb_build_object('tipo', 'auditoria_final', 'unidad_id', juego, 'ocurrido_en', now() - interval '5 minutes',
                     'medidas', jsonb_build_array(jsonb_build_object('medida_id', medida, 'valor_cm', esperado)))) from k) ->> 'estado' = 'aceptado',
                  'Reinspección subida');
select pg_temp.ok((select resultado = 'aprobado' from inspecciones where id = 'f9000000-0000-0000-0000-000000000004'), 'Reinspección aprobada');
create temp table antes as select coalesce(sum(cantidad), 0) as sg from movimientos_producto m join bodegas b on b.id = m.bodega_id where b.tipo = 'segundas';
create temp table cant as select cantidad_actual as c from juegos where id = (select juego from k);
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002',
  format($$select mover_unidad(%L, 'entrega', 'calidad', null, %s, 1, 0)$$, (select codigo from k), (select c - 1 from cant)));
select pg_temp.ok((select estado = 'terminado' from juegos where id = (select juego from k)), 'Calidad era el último proceso: el juego queda terminado');
select pg_temp.ok((select sum(m.cantidad) = (select c - 1 from cant) and bool_and(b.tipo = 'producto_terminado')
                   from movimientos_producto m join bodegas b on b.id = m.bodega_id where m.juego_id = (select juego from k) and m.tipo = 'ingreso_op'),
                  'Las buenas entran a producto terminado');
select pg_temp.ok((select coalesce(sum(cantidad), 0) from movimientos_producto m join bodegas b on b.id = m.bodega_id where b.tipo = 'segundas') = (select sg + 1 from antes),
                  'La segunda de calidad va a la bodega de segundas');
create temp table sk as select sku_id from movimientos_producto where juego_id = (select juego from k) and tipo = 'ingreso_op' limit 1;
grant select on sk to authenticated;
select pg_temp.ok((select cantidad = (select c - 1 from cant) from existencias_producto where sku_id = (select sku_id from sk) and bodega_tipo = 'producto_terminado'),
                  'Existencias de producto terminado por talla y color');

-- ---------- 9. Inspección en proceso y anulación ----------
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000005', 'inspecciones',
                   jsonb_build_object('tipo', 'en_proceso', 'unidad_id', otro, 'tamano_muestra', 3, 'ocurrido_en', now(),
                     'defectos', jsonb_build_array(jsonb_build_object('defecto_id', psa, 'cantidad', 1, 'ficha_operacion_id', fo))::text)) from k) ->> 'estado' = 'aceptado',
                  'Inspección en proceso subida (la tablet manda los defectos como texto JSON)');
select pg_temp.ok((select tamano_muestra = 3 and plan_id is null and resultado = 'rechazado' from inspecciones where id = 'f9000000-0000-0000-0000-000000000005')
                  and (select alcance = 'individual' and estado = 'abierta' from devoluciones_calidad where inspeccion_id = 'f9000000-0000-0000-0000-000000000005'),
                  'Inspección en proceso: la prenda vuelve al operario (devolución individual)');
select pg_temp.ok((select pg_temp.subir('aaaaaaaa-0000-0000-0000-000000000019', 'f9000000-0000-0000-0000-000000000006', 'inspecciones',
                   jsonb_build_object('tipo', 'anulacion', 'anula_id', 'f9000000-0000-0000-0000-000000000005', 'motivo', '', 'ocurrido_en', now())) ->> 'estado') in ('aceptado'),
                  'Anular sin motivo escrito usa "Anulada"');
select pg_temp.ok((select estado = 'anulada' from devoluciones_calidad where inspeccion_id = 'f9000000-0000-0000-0000-000000000005'),
                  'Anular la inspección anula sus devoluciones abiertas');
select pg_temp.falla($$update inspecciones set resultado = 'aprobado'$$, 'Las inspecciones no se editan');
select pg_temp.falla($$delete from movimientos_producto$$, 'Los movimientos de producto no se borran');
select pg_temp.falla($$update devoluciones_calidad set estado = 'abierta'$$, 'Las devoluciones no se cambian a mano');

-- ---------- 10. Despacho a un pedido ----------
insert into pedidos (id, cliente_id, observacion)
select 'f9300000-0000-0000-0000-000000000001', (select id from clientes order by nombre limit 1), 'Pedido de prueba (EJEMPLO)';
insert into pedido_lineas (pedido_id, referencia_id, combinacion_codigo, talla_id, cantidad)
select 'f9300000-0000-0000-0000-000000000001', s.referencia_id, s.combinacion_codigo, s.talla_id, 5 from skus s where s.id = (select sku_id from sk);
select pg_temp.falla(format($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000002', 'select despachar(''f9300000-0000-0000-0000-000000000001'', ''[{"sku_id": "%s", "cantidad": 1}]'')')$$,
                     (select sku_id from sk)), 'El jefe de producción no despacha (no edita inventario)');
select pg_temp.falla(format($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select despachar(''f9300000-0000-0000-0000-000000000001'', ''[{"sku_id": "%s", "cantidad": 6}]'')')$$,
                     (select sku_id from sk)), 'No se despacha más de lo pedido');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  format($$select despachar('f9300000-0000-0000-0000-000000000001', '[{"sku_id": "%s", "cantidad": 3}]', 'Primera entrega')$$, (select sku_id from sk)));
select pg_temp.ok((select despachado = 3 and por_despachar = 2 from pedido_despachos where pedido_id = 'f9300000-0000-0000-0000-000000000001'),
                  'El pedido queda con 3 despachadas y 2 por despachar');
select pg_temp.ok((select cantidad = (select c - 4 from cant) from existencias_producto where sku_id = (select sku_id from sk) and bodega_tipo = 'producto_terminado'),
                  'El despacho descuenta producto terminado');
select pg_temp.ok((select consecutivo like 'DES-%' and estado = 'despachado' from despachos where pedido_id = 'f9300000-0000-0000-0000-000000000001'), 'Consecutivo DES');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select anular_despacho((select id from despachos where pedido_id = ''f9300000-0000-0000-0000-000000000001''), '' '')')$$,
                     'Anular un despacho exige motivo');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  $$select anular_despacho((select id from despachos where pedido_id = 'f9300000-0000-0000-0000-000000000001'), 'Cliente no recibió (EJEMPLO)')$$);
select pg_temp.ok((select despachado = 0 from pedido_despachos where pedido_id = 'f9300000-0000-0000-0000-000000000001')
                  and (select cantidad = (select c - 1 from cant) from existencias_producto where sku_id = (select sku_id from sk) and bodega_tipo = 'producto_terminado'),
                  'Anular el despacho devuelve las prendas con un movimiento inverso');

-- ---------- 11. Ajustes y traslados ----------
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select ajustar_producto((select sku_id from sk), bodega_de_tipo(''producto_terminado''), -1000, ''Conteo'')')$$,
                     'Un ajuste no deja existencias negativas');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select ajustar_producto((select sku_id from sk), bodega_de_tipo(''producto_terminado''), 2, '''')')$$,
                     'Un ajuste exige motivo');
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004',
  $$select trasladar_producto((select sku_id from sk), bodega_de_tipo('producto_terminado'), bodega_de_tipo('segundas'), 1, 'Mancha en bodega (EJEMPLO)')$$);
select pg_temp.ok((select cantidad = (select c - 2 from cant) from existencias_producto where sku_id = (select sku_id from sk) and bodega_tipo = 'producto_terminado'),
                  'Traslado de producto terminado a segundas');

-- ---------- 12. Informes de eficacia ----------
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000020', $$create temp table ef as select * from informe_eficacia(hoy_bogota() - 1, hoy_bogota(), 'operario')$$);
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000020', $$create temp table efc as select * from informe_eficacia(hoy_bogota() - 1, hoy_bogota(), 'celula')$$);
select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000020', $$create temp table pareto as select * from informe_defectos(hoy_bogota() - 1, hoy_bogota())$$);
select pg_temp.ok((select defectuosas >= 1 and inspeccionadas > 0 and primera_calidad < 100 and defecto_principal = 'Puntada saltada'
                   from ef where clave = (select operario from k)),
                  'Eficacia del operario: prendas con defecto sobre las revisadas de lo que hizo');
select pg_temp.ok((select segundas >= 1 and entra > 0 and inspeccionadas > 0 from efc where codigo = 'MOD1'), 'Eficacia del Módulo 1 con sus segundas');
select pg_temp.ok((select bool_or(codigo = 'PSA') and max(acumulado) = 100 from pareto), 'Pareto de defectos');
select pg_temp.falla($$select pg_temp.como('aaaaaaaa-0000-0000-0000-000000000004', 'select * from informe_eficacia(hoy_bogota(), hoy_bogota())')$$,
                     'Bodega no ve la eficacia');
select pg_temp.ok((select (r->>'auditorias')::int = 3 and (r->>'rechazadas')::int = 2 and (r->>'producto_terminado')::int > 0 from (select op_calidad_resumen(op) r from k) x),
                  'Resumen de calidad de la OP: 3 auditorías, 2 rechazadas');

-- ---------- 13. El satélite no ve la calidad de la planta ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000005';
select pg_temp.ok((select count(*) = 0 from inspecciones) and (select count(*) = 0 from movimientos_producto), 'El satélite no ve inspecciones ni producto terminado');
reset role;
reset request.jwt.claim.sub;
