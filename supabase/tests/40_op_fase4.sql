-- Pruebas de la Fase 4: pedidos → OP, reservas (regla 4), faltantes y
-- requisiciones, compras con recepción que reasigna, avance con cantidades (regla 5).
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
-- reservado de una OP cuadra con el kardex y con sus necesidades
create or replace function pg_temp.reservas_cuadran(p_op uuid) returns boolean language sql as $$
  select not exists (
    select 1 from op_necesidades n
    where n.op_id = p_op and n.reservado <> coalesce((select sum(cantidad) from movimientos_inventario m
                                                      where m.op_id = p_op and m.afecta = 'reservado' and m.material_id = n.material_id
                                                        and m.color_id is not distinct from n.color_id), 0))
$$;
create or replace function pg_temp.disponible(p_cod text, p_color text) returns numeric language sql as $$
  select coalesce(sum(s.disponible), 0) from saldos_inventario s join materiales m on m.id = s.material_id
  left join colores c on c.id = s.color_id where m.codigo = p_cod and c.codigo is not distinct from p_color
$$;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000010', 'compras@prueba');
insert into perfiles (id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000010', 'Compras');
insert into usuario_roles (usuario_id, rol) values ('aaaaaaaa-0000-0000-0000-000000000010', 'compras'), ('aaaaaaaa-0000-0000-0000-000000000010', 'bodega');

-- Las pruebas de inventario anularon la OP de ejemplo y movieron stock: se parte de una OP nueva igual a la del seed.
reset role;
reset request.jwt.claim.sub;
create temp table cam as select (select id from referencias where codigo = 'CAM-001') as ref;
grant select on cam to authenticated;

set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción

-- ---------- Validaciones al crear la OP ----------
select pg_temp.falla($$select crear_op((select id from referencias where codigo = 'JOG-001'), '{"N":{"S":1}}')$$, 'OP de una referencia sin ficha aprobada');
select pg_temp.falla($$select crear_op((select ref from cam), '{"AZUL":{"S":10}}')$$, 'OP con una combinación que no está en la ficha');
select pg_temp.falla($$select crear_op((select ref from cam), '{"N":{"XXL":10}}')$$, 'OP con una talla que no está en la ficha');
select pg_temp.falla($$select crear_op((select ref from cam), '{"N":{"S":0}}')$$, 'OP sin cantidades');

-- ---------- OP 1: reserva lo disponible y pide el rib que no hay ----------
create temp table op1 as select crear_op((select ref from cam), '{"N":{"S":20,"M":40,"L":40,"XL":20},"GJ":{"S":10,"M":20,"L":20,"XL":10}}'::jsonb,
                                         current_date + 20, 2) as id;
reset role;
select pg_temp.ok((select cantidad_total = 180 and estado = 'planeada' and proceso_actual = 'corte' and alerta_material
                   from ordenes_produccion where id = (select id from op1)), 'OP de 180 prendas, planeada, en corte, con alerta de material');
select pg_temp.ok((select cantidad_estandar from op_necesidades n join materiales m on m.id = n.material_id join colores c on c.id = n.color_id
                   where n.op_id = (select id from op1) and m.codigo = 'TEL-JER30' and c.codigo = 'N') = 33.176,
                  'Jersey negro con la ficha v2 = (0,24×20 + 0,257×40 + 0,274×40 + 0,293×20) × 1,04 = 33,176 kg');
select pg_temp.ok((select reservado = 33.176 and faltante = 0 from op_necesidades n join materiales m on m.id = n.material_id join colores c on c.id = n.color_id
                   where n.op_id = (select id from op1) and m.codigo = 'TEL-JER30' and c.codigo = 'N'), 'El jersey negro queda reservado completo');
select pg_temp.ok((select reservado = 0 and faltante = 2.41 from op_necesidades n join materiales m on m.id = n.material_id
                   where n.op_id = (select id from op1) and m.codigo = 'TEL-RIB'), 'Rib sin existencias: faltante 2,41 kg');
select pg_temp.ok((select count(distinct r.id) = 1 and bool_or(m.codigo = 'TEL-RIB' and rl.cantidad = 2.41)
                   from requisiciones r join requisicion_lineas rl on rl.requisicion_id = r.id join materiales m on m.id = rl.material_id
                   where r.op_id = (select id from op1) and r.origen = 'automatica'), 'Se genera una requisición automática con lo que falta (rib 2,41 kg)');
select pg_temp.ok(exists (select 1 from alertas where tipo = 'material_faltante' and entidad_id = (select id from op1)::text and estado = 'abierta'),
                  'Y una alerta de material faltante');
select pg_temp.ok(pg_temp.reservas_cuadran((select id from op1)), 'Reservado de la OP = suma de sus movimientos de reserva');
select pg_temp.ok((select count(*) from op_procesos where op_id = (select id from op1)) = 5, 'La OP toma los 5 procesos de la ruta de su ficha');
select pg_temp.ok((select ficha_version_id from ordenes_produccion where id = (select id from op1)) = (select version_vigente_id from referencias where codigo = 'CAM-001'),
                  'La OP guarda la versión de ficha con que se creó (regla 11)');

-- ---------- OP 2 compite por el mismo jersey: nunca queda disponible negativo ----------
create temp table antes as select pg_temp.disponible('TEL-JER30', 'N') as d;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
create temp table op2 as select crear_op((select ref from cam), '{"N":{"S":100,"M":100,"L":100,"XL":100}}'::jsonb, current_date + 40, 4) as id;
reset role;
select pg_temp.ok(pg_temp.disponible('TEL-JER30', 'N') = 0, 'OP 2 toma todo el jersey negro que quedaba: disponible 0, nunca negativo');
select pg_temp.ok((select reservado = (select d from antes) and faltante > 0 from op_necesidades n join materiales m on m.id = n.material_id join colores c on c.id = n.color_id
                   where n.op_id = (select id from op2) and m.codigo = 'TEL-JER30' and c.codigo = 'N'), 'y queda con faltante el resto');
select pg_temp.ok((select reservado from op_necesidades n join materiales m on m.id = n.material_id join colores c on c.id = n.color_id
                   where n.op_id = (select id from op1) and m.codigo = 'TEL-JER30' and c.codigo = 'N') = 33.176, 'La reserva de la OP 1 no se toca');

-- Bajar cantidades libera lo que sobra
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select actualizar_cantidades_op((select id from op2), '{"N":{"S":10,"M":10}}'::jsonb);
reset role;
select pg_temp.ok((select cantidad_total from ordenes_produccion where id = (select id from op2)) = 20 and pg_temp.reservas_cuadran((select id from op2)),
                  'Cambiar cantidades recalcula y las reservas siguen cuadrando');
select pg_temp.ok(pg_temp.disponible('TEL-JER30', 'N') > 0, 'Al bajar cantidades se libera jersey');

-- ---------- Pedidos ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
insert into pedidos (id, cliente_id) values ('ab000000-0000-0000-0000-000000000001', (select id from clientes limit 1));
insert into pedido_lineas (id, pedido_id, referencia_id, combinacion_codigo, talla_id, cantidad)
values ('ab000000-0000-0000-0000-000000000011', 'ab000000-0000-0000-0000-000000000001', (select ref from cam), 'N', (select id from tallas where codigo = 'M'), 30);
select pg_temp.falla($$select crear_op((select ref from cam), '{"N":{"M":40}}', null, 3, null, '[{"pedido_linea_id":"ab000000-0000-0000-0000-000000000011","cantidad":40}]')$$,
                     'Asignar a la OP más de lo pendiente del pedido');
create temp table op3 as select crear_op((select ref from cam), '{"N":{"M":30}}', null, 3, null,
                                         '[{"pedido_linea_id":"ab000000-0000-0000-0000-000000000011","cantidad":30}]'::jsonb) as id;
select pg_temp.ok((select en_op = 30 and pendiente = 0 from pedido_saldos where pedido_linea_id = 'ab000000-0000-0000-0000-000000000011'), 'El pedido queda en OP (pendiente 0)');
select pg_temp.falla($$delete from pedido_lineas where id = 'ab000000-0000-0000-0000-000000000011'$$, 'Borrar una línea de pedido que ya está en una OP')
  where false;
delete from pedido_lineas where id = 'ab000000-0000-0000-0000-000000000011';
select pg_temp.ok(exists (select 1 from pedido_lineas where id = 'ab000000-0000-0000-0000-000000000011'), 'Una línea de pedido que ya está en una OP no se borra');
select anular_op((select id from op3), 'Cliente canceló');
reset role;
select pg_temp.ok((select pendiente from pedido_saldos where pedido_linea_id = 'ab000000-0000-0000-0000-000000000011') = 30, 'Al anular la OP el pedido vuelve a quedar pendiente');
select pg_temp.ok(not exists (select 1 from reservado_op((select id from op3))), 'Anular libera todas las reservas de la OP');

-- ---------- Protecciones de la OP ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select pg_temp.falla($$update ordenes_produccion set estado = 'terminada' where id = (select id from op1)$$, 'Cambiar el estado de la OP con un UPDATE directo');
select pg_temp.falla($$update ordenes_produccion set cantidad_total = 1 where id = (select id from op1)$$, 'Cambiar la cantidad total directo');
update ordenes_produccion set prioridad = 1, observacion = 'Urgente' where id = (select id from op1);
select pg_temp.ok((select prioridad from ordenes_produccion where id = (select id from op1)) = 1, 'Prioridad y observación sí se editan');

-- ---------- Regla 5: avance con cantidades ----------
select pg_temp.falla($$select registrar_avance((select id from op1), 'corte', 180, 170, 2, 0)$$, 'Avance que no cuadra (180 ≠ 170 + 2 + 0)');
select pg_temp.falla($$select registrar_avance((select id from op1), 'confeccion', 10, 10)$$, 'Pasar a confección sin que haya salido nada de los procesos anteriores');
select registrar_avance((select id from op1), 'corte', 180, 178, 2, 0, true);
select pg_temp.ok((select estado = 'en_proceso' and proceso_actual = 'estampacion' from ordenes_produccion where id = (select id from op1)),
                  'Al terminar corte la OP queda en proceso, en estampación');
select pg_temp.falla($$select registrar_avance((select id from op1), 'estampacion', 179, 179)$$, 'A estampación no pueden entrar más de las 178 buenas de corte');
select registrar_avance((select id from op1), 'estampacion', 100, 99, 1, 0);
select registrar_avance((select id from op1), 'estampacion', 78, 78, 0, 0, true);
select pg_temp.ok((select entra = 178 and buenas = 177 and segundas = 1 and estado = 'terminado' from op_procesos where op_id = (select id from op1) and proceso = 'estampacion'),
                  'Los avances parciales se acumulan (178 = 177 + 1)');
select pg_temp.falla($$select actualizar_cantidades_op((select id from op1), '{"N":{"S":1}}')$$, 'Cambiar cantidades de una OP en proceso');
select pg_temp.falla($$select anular_op((select id from op1), 'x')$$, 'Anular una OP en proceso');
reset role;
select pg_temp.falla($$delete from eventos_proceso$$, 'Borrar eventos de proceso');

-- ---------- Compras: requisición → OC → recepción → reasigna a la OP ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000010';  -- compras
create temp table oc as select crear_oc((select id from proveedores where nit = '900000001-1'),
  (select array_agg(rl.id) from requisicion_lineas rl join requisiciones r on r.id = rl.requisicion_id join materiales m on m.id = rl.material_id
    where r.op_id = (select id from op1) and m.codigo = 'TEL-RIB')) as id;
reset role;
select pg_temp.ok((select rl.oc_linea_id is not null from requisicion_lineas rl join requisiciones r on r.id = rl.requisicion_id join materiales m on m.id = rl.material_id
                   where r.op_id = (select id from op1) and m.codigo = 'TEL-RIB'), 'La línea del rib queda en la orden de compra');
select pg_temp.ok((select cantidad = 2.41 from oc_lineas where oc_id = (select id from oc)), 'La OC lleva la cantidad faltante');
-- recalcular la OP no duplica lo que ya está en la OC
select reservar_op((select id from op1));
select pg_temp.ok(not exists (select 1 from requisicion_lineas rl join requisiciones r on r.id = rl.requisicion_id join materiales m on m.id = rl.material_id
                              where r.op_id = (select id from op1) and rl.oc_linea_id is null and m.codigo = 'TEL-RIB'), 'Lo que ya está en una OC no se vuelve a pedir');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000010';
select cambiar_estado_oc((select id from oc), 'enviada');
insert into recepciones (id, proveedor_id, bodega_id, oc_id) values ('ac000000-0000-0000-0000-000000000001',
  (select id from proveedores where nit = '900000001-1'), '1a000000-0000-0000-0000-000000000001', (select id from oc));
insert into recepcion_lineas (recepcion_id, material_id, color_id, cantidad, lote_tintura, ancho_real_cm, metros, kilos, oc_linea_id)
select 'ac000000-0000-0000-0000-000000000001', material_id, color_id, 3.0, 'L-RIB-N1', 100, 13.6, 3.0, id from oc_lineas where oc_id = (select id from oc);
select count(*) from confirmar_recepcion('ac000000-0000-0000-0000-000000000001');
reset role;
select pg_temp.ok((select estado from ordenes_compra where id = (select id from oc)) = 'recibida', 'Al recibir, la OC queda recibida');
select pg_temp.ok((select reservado = 2.41 and faltante = 0 from op_necesidades n join materiales m on m.id = n.material_id
                   where n.op_id = (select id from op1) and m.codigo = 'TEL-RIB'), 'El rib recibido se reserva solo para la OP que lo esperaba');
select pg_temp.ok((select alerta_material from ordenes_produccion where id = (select id from op1))
                  and not exists (select 1 from op_necesidades n join materiales m on m.id = n.material_id
                                  where n.op_id = (select id from op1) and n.faltante > 0 and m.tipo = 'tela'),
                  'La OP ya no tiene faltante de telas; la alerta sigue solo por los insumos que faltan');
select pg_temp.ok(pg_temp.reservas_cuadran((select id from op1)) and pg_temp.reservas_cuadran((select id from op2)), 'Todas las reservas siguen cuadrando con el kardex');
