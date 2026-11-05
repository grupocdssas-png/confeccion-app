-- Pruebas de la Fase 6 (segunda parte): remisiones a satélites, devolución con
-- cantidades (regla 5), anulación con eventos inversos (regla 2), insumos con OP
-- (regla 1), cuentas por pagar y lo que ve cada satélite.
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

-- ---------- Datos: una OP pequeña (2 S + 2 M negras) cortada y armada en 2 juegos ----------
create temp table k as
select (select id from satelites where nit = '900000004-4') as estampador, (select id from satelites where nit = '900000003-3') as confeccionista;
update perfiles set satelite_id = (select estampador from k) where id = 'aaaaaaaa-0000-0000-0000-000000000005';
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000012', 'otro-satelite@prueba');
insert into perfiles (id, nombre, satelite_id) values ('aaaaaaaa-0000-0000-0000-000000000012', 'Otro satélite', (select confeccionista from k));
insert into usuario_roles (usuario_id, rol) values ('aaaaaaaa-0000-0000-0000-000000000012', 'satelite');
insert into tarifas_satelite (satelite_id, proceso, valor_unidad, vigente_desde, observacion)
values ((select estampador from k), 'estampacion', 1100, current_date - 30, 'EJEMPLO vieja'), ((select estampador from k), 'estampacion', 1200, current_date - 1, 'EJEMPLO');

do $$
declare v_op uuid; v_ficha uuid; v_corte uuid; v_tallas jsonb; v_neg uuid := (select id from colores where codigo = 'N');
begin
  v_op := crear_op((select id from referencias where codigo = 'CAM-001'), '{"N":{"S":2,"M":2}}'::jsonb, current_date + 10, 1);
  select ficha_version_id into v_ficha from ordenes_produccion where id = v_op;
  select jsonb_agg(id order by orden) into v_tallas from tallas where codigo in ('S','M');
  v_corte := guardar_corte(jsonb_build_object('op_id', v_op, 'tipo', 'combinada', 'estacion_id', '1b000000-0000-0000-0000-000000000003', 'despunte_cm', 0,
    'documento', jsonb_build_object('bloques', jsonb_build_array(
      jsonb_build_object('id', 'b1', 'material_id', '1c000000-0000-0000-0000-000000000001', 'tallas', v_tallas,
        'partes', (select jsonb_agg(id) from ficha_partes where ficha_id = v_ficha and nombre in ('Cuerpo','Mangas')),
        'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 1.0,
                       'unidades', (select jsonb_object_agg(id, 1) from tallas where codigo in ('S','M')))),
        'tramos', jsonb_build_array(jsonb_build_object('rollo_id', (select id from rollos where codigo = 'TL-000002'), 'color_id', v_neg, 'capas', 2))),
      jsonb_build_object('id', 'b2', 'material_id', '1c000000-0000-0000-0000-000000000003', 'tallas', v_tallas,
        'partes', (select jsonb_agg(id) from ficha_partes where ficha_id = v_ficha and nombre = 'Cuello'),
        'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 0.1,
                       'unidades', (select jsonb_object_agg(id, 1) from tallas where codigo in ('S','M')))),
        'tramos', jsonb_build_array(jsonb_build_object('rollo_id', (select id from rollos where lote_tintura = 'L-RIB-N1' and es_retazo limit 1),
                                                       'color_id', v_neg, 'capas', 2)))))));
  perform confirmar_corte(v_corte);
  perform armar_juegos(v_op);
  perform terminar_corte_op(v_op);
  create temp table op6 as select v_op as id;
end $$;
create temp table jg as select id, codigo, cantidad from juegos where op_id = (select id from op6) order by codigo;
grant select on k, op6, jg to authenticated;
select pg_temp.ok((select count(*) = 2 and bool_and(proceso_actual = 'estampacion' and estado = 'armado') from juegos where op_id = (select id from op6)),
                  'Dos juegos listos para estampación');

-- ---------- Salida ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.falla($$select crear_remision_salida((select estampador from k), 'estampacion', array[(select id from jg limit 1)])$$, 'Bodega no hace remisiones');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
select pg_temp.falla($$select crear_remision_salida((select confeccionista from k), 'estampacion', array[(select id from jg limit 1)])$$,
                     'Un satélite que no estampa no recibe estampación');
select pg_temp.falla($$select crear_remision_salida((select estampador from k), 'estampacion', array[]::uuid[])$$, 'Remisión sin juegos');
create temp table r1 as select crear_remision_salida((select estampador from k), 'estampacion', array[(select id from jg order by codigo limit 1)],
  jsonb_build_array(jsonb_build_object('op_id', (select id from op6), 'material_id', '1c000000-0000-0000-0000-000000000012',
                                       'bodega_id', '1a000000-0000-0000-0000-000000000002', 'cantidad', 4)), 'EJEMPLO', current_date + 3) as id;
create temp table r2 as select crear_remision_salida((select estampador from k), 'estampacion', array[(select id from jg order by codigo desc limit 1)]) as id;
select pg_temp.falla($$select crear_remision_salida((select estampador from k), 'estampacion', array[(select id from jg order by codigo limit 1)])$$,
                     'Un juego que ya está en el satélite no se vuelve a enviar');
reset role;
select pg_temp.ok((select consecutivo like 'REM-%' and estado = 'enviada' from remisiones where id = (select id from r1)), 'La remisión de salida queda enviada (REM-…)');
select pg_temp.ok((select estado = 'en_proceso' from juegos where id = (select id from jg order by codigo limit 1)), 'El juego queda en proceso en el satélite');
select pg_temp.ok(exists (select 1 from eventos_proceso where tipo = 'recepcion' and satelite_id = (select estampador from k)
                          and juego_id = (select id from jg order by codigo limit 1)), 'La recepción queda a nombre del satélite');
select pg_temp.ok((select cantidad = -4 and op_id = (select id from op6) from movimientos_inventario where tipo = 'envio_satelite'
                   and documento_id = (select consecutivo from remisiones where id = (select id from r1))), 'Las marquillas salen del inventario con la OP (regla 1)');

-- ---------- Anular la segunda salida ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select pg_temp.falla($$select anular_remision((select id from r2), '')$$, 'Anular sin motivo');
select anular_remision((select id from r2), 'Se envió al satélite equivocado');
reset role;
select pg_temp.ok((select estado = 'en_espera' from juegos where id = (select id from jg order by codigo desc limit 1)), 'Al anular, el juego vuelve a esperar estampación');
select pg_temp.ok(exists (select 1 from eventos_proceso where tipo = 'anulacion' and juego_id = (select id from jg order by codigo desc limit 1)),
                  'La recepción se anula con un evento inverso');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
create temp table r3 as select crear_remision_salida((select estampador from k), 'estampacion', array[(select id from jg order by codigo desc limit 1)]) as id;
reset role;

-- ---------- Lo que ve cada satélite ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000005';  -- el estampador
select pg_temp.ok((select count(*) = 3 from remisiones), 'El estampador ve sus 3 remisiones');
select pg_temp.ok((select count(*) = 2 from juegos), 'Ve los juegos que le enviaron');
select pg_temp.ok((select count(*) = 1 from ordenes_produccion), 'Ve solo la OP de lo que le enviaron');
select pg_temp.ok((select count(*) = 0 from rollos), 'No ve el inventario');
select confirmar_recibido_satelite((select id from r1), 'Llegó completo');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000012';  -- otro satélite
select pg_temp.ok((select count(*) = 0 from remisiones), 'Otro satélite no ve remisiones ajenas');
select pg_temp.falla($$select confirmar_recibido_satelite((select id from r1))$$, 'Otro satélite no confirma una remisión ajena');
select pg_temp.falla($$select registrar_devolucion((select id from r1), '[]')$$, 'El satélite no registra devoluciones');
reset role;
select pg_temp.ok((select recibida_satelite is not null and nota_satelite = 'Llegó completo' from remisiones where id = (select id from r1)),
                  'Queda la confirmación del satélite');
select pg_temp.falla($$update remisiones set estado = 'cerrada' where id = (select id from r1)$$, 'Una remisión no se cambia a mano');

-- ---------- Devolución ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select pg_temp.falla($$select registrar_devolucion((select id from r1), jsonb_build_array(jsonb_build_object('unidad_id', (select id from jg order by codigo limit 1), 'buenas', 1)))$$,
                     'Regla 5: la devolución no cuadra');
select pg_temp.falla($$select registrar_devolucion((select id from r1), jsonb_build_array(jsonb_build_object('unidad_id', (select id from jg order by codigo desc limit 1), 'buenas', 2)))$$,
                     'No se devuelve lo que no salió en esa remisión');
create temp table d1 as select registrar_devolucion((select id from r1),
  jsonb_build_array(jsonb_build_object('unidad_id', (select id from jg order by codigo limit 1), 'buenas', (select cantidad - 1 from jg order by codigo limit 1),
                                       'segundas', 1, 'faltantes', 0))) as id;
create temp table d2 as select registrar_devolucion((select id from r3),
  jsonb_build_array(jsonb_build_object('unidad_id', (select id from jg order by codigo desc limit 1), 'buenas', (select cantidad from jg order by codigo desc limit 1)))) as id;
reset role;
select pg_temp.ok((select estado = 'cerrada' from remisiones where id = (select id from r1)) and (select consecutivo like 'DEV-%' from remisiones where id = (select id from d1)),
                  'Con todo devuelto la salida queda cerrada; la devolución es DEV-…');
select pg_temp.ok((select estado = 'en_espera' and proceso_actual = 'confeccion' and cantidad_actual = cantidad - 1 from juegos where id = (select id from jg order by codigo limit 1)),
                  'El juego sigue a confección con las buenas');
select pg_temp.ok((select estado = 'terminado' and buenas = 3 and segundas = 1 from op_procesos where op_id = (select id from op6) and proceso = 'estampacion'),
                  'Estampación queda terminada con 3 buenas y 1 segunda');
select pg_temp.ok((select cantidad = (select cantidad - 1 from jg order by codigo limit 1) and valor_unidad = 1200 and valor = cantidad * 1200 and estado = 'pendiente'
                   from cuentas_pagar_satelite where remision_id = (select id from d1)), 'Cuenta por pagar: buenas × tarifa vigente ($ 1.200)');

-- ---------- Cuentas por pagar ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select pg_temp.falla($$select decidir_cuenta_satelite((select id from cuentas_pagar_satelite where remision_id = (select id from d1)), 'aprobar')$$,
                     'Producción no aprueba pagos');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000008';  -- costos
select pg_temp.falla($$select decidir_cuenta_satelite((select id from cuentas_pagar_satelite where remision_id = (select id from d1)), 'pagar', 'TR-1')$$,
                     'No se paga sin aprobar');
select decidir_cuenta_satelite((select id from cuentas_pagar_satelite where remision_id = (select id from d1)), 'aprobar');
select decidir_cuenta_satelite((select id from cuentas_pagar_satelite where remision_id = (select id from d1)), 'pagar', 'Transferencia EJEMPLO');
reset role;
select pg_temp.ok((select estado = 'pagada' and referencia_pago = 'Transferencia EJEMPLO' and aprobada_por = 'aaaaaaaa-0000-0000-0000-000000000008'
                   from cuentas_pagar_satelite where remision_id = (select id from d1)), 'Costos aprueba y paga (queda quién aprobó)');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000005';
select pg_temp.ok((select count(*) = 2 from cuentas_pagar_satelite), 'El satélite ve sus cuentas');
reset role;
