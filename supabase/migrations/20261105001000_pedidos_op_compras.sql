-- =====================================================================
-- Fase 4 · Migración 10: pedidos, órdenes de producción, reservas de
-- material, requisiciones, órdenes de compra y avance de procesos.
-- Reglas: 1 (salidas ligadas a OP), 4 (disponible = físico − reservado),
-- 5 (una OP no avanza sin cantidades), 7 (todo o nada), 11 (la OP
-- conserva su versión de ficha).
-- =====================================================================

insert into public.consecutivos (tipo, prefijo) values ('PED','PED'), ('OP','OP'), ('REQ','REQ'), ('OC','OC')
on conflict (tipo) do nothing;

-- ---------------------------------------------------------------------
-- Pedidos de clientes
-- ---------------------------------------------------------------------
create table public.pedidos (
  id                 uuid primary key default gen_random_uuid(),
  consecutivo        text not null unique default public.siguiente_consecutivo('PED'),
  cliente_id         uuid references public.clientes(id),
  canal_id           uuid references public.canales(id),
  origen             text not null default 'manual' check (origen in ('manual','shopify','b2b','importado')),
  externo_id         text,
  fecha              date not null default current_date,
  fecha_comprometida date,
  estado             text not null default 'abierto' check (estado in ('abierto','cancelado')),
  observacion        text
);

create table public.pedido_lineas (
  id                 uuid primary key default gen_random_uuid(),
  pedido_id          uuid not null references public.pedidos(id) on delete cascade,
  referencia_id      uuid not null references public.referencias(id),
  combinacion_codigo text not null,           -- código de color/combinación de la ficha (N, GJ…)
  talla_id           uuid not null references public.tallas(id),
  cantidad           int  not null check (cantidad > 0)
);
create index on public.pedido_lineas (pedido_id);
create index on public.pedido_lineas (referencia_id);

-- ---------------------------------------------------------------------
-- Órdenes de producción
-- ---------------------------------------------------------------------
create table public.ordenes_produccion (
  id                 uuid primary key default gen_random_uuid(),
  consecutivo        text not null unique default public.siguiente_consecutivo('OP'),
  referencia_id      uuid not null references public.referencias(id),
  ficha_version_id   uuid not null references public.ficha_versiones(id),   -- regla 11: conserva su versión
  prioridad          int  not null default 3 check (prioridad between 1 and 5),  -- 1 = más urgente
  estado             text not null default 'planeada' check (estado in ('planeada','en_proceso','terminada','cerrada','anulada')),
  proceso_actual     text references public.procesos(codigo),
  fecha_inicio_plan  date,
  fecha_entrega_plan date,
  fecha_comprometida date,
  cantidad_total     int  not null default 0,
  alerta_material    boolean not null default false,
  observacion        text,
  motivo_anulacion   text,
  primera_marcacion  timestamptz,
  ultima_marcacion   timestamptz,
  origen             text not null default 'manual' check (origen in ('manual','pedido','importada'))
);
create index on public.ordenes_produccion (estado, fecha_entrega_plan);

alter table public.movimientos_inventario
  add constraint movimientos_op_fk foreign key (op_id) references public.ordenes_produccion(id);
create index on public.movimientos_inventario (op_id);

create table public.op_cantidades (
  op_id          uuid not null references public.ordenes_produccion(id) on delete cascade,
  combinacion_id uuid not null references public.ficha_combinaciones(id),
  talla_id       uuid not null references public.tallas(id),
  cantidad       int  not null check (cantidad > 0),
  primary key (op_id, combinacion_id, talla_id)
);

create table public.op_pedidos (
  op_id           uuid not null references public.ordenes_produccion(id) on delete cascade,
  pedido_linea_id uuid not null references public.pedido_lineas(id),
  cantidad        int  not null check (cantidad > 0),
  primary key (op_id, pedido_linea_id)
);

-- Necesidades de material de la OP (foto al reservar): estándar, reservado, faltante
create table public.op_necesidades (
  op_id             uuid not null references public.ordenes_produccion(id) on delete cascade,
  material_id       uuid not null references public.materiales(id),
  color_id          uuid references public.colores(id),
  cantidad_estandar numeric(14,3) not null,
  reservado         numeric(14,3) not null default 0,
  faltante          numeric(14,3) not null default 0,
  consumido         numeric(14,3) not null default 0,     -- se llena con el corte y los despachos (Fase 5)
  detalle           jsonb,
  calculado_en      timestamptz not null default now()
);
create unique index op_necesidades_clave on public.op_necesidades (op_id, material_id, coalesce(color_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Procesos de la OP (de la ruta de su ficha) con acumulados
create table public.op_procesos (
  op_id      uuid not null references public.ordenes_produccion(id) on delete cascade,
  proceso    text not null references public.procesos(codigo),
  orden      int  not null,
  modalidad  text not null default 'interno',
  estado     text not null default 'pendiente' check (estado in ('pendiente','en_proceso','terminado')),
  entra      int  not null default 0,
  buenas     int  not null default 0,
  segundas   int  not null default 0,
  faltantes  int  not null default 0,
  inicio     timestamptz,
  fin        timestamptz,
  primary key (op_id, proceso)
);

-- Eventos de proceso (E): cada registro de avance con sus cantidades
create table public.eventos_proceso (
  id             uuid primary key default gen_random_uuid(),
  op_id          uuid not null references public.ordenes_produccion(id),
  proceso        text not null references public.procesos(codigo),
  tipo           text not null default 'avance' check (tipo in ('avance','anulacion')),
  paquete_id     uuid,                 -- Fase 5/6
  estacion_id    uuid references public.estaciones(id),
  celula_id      uuid references public.celulas(id),
  satelite_id    uuid references public.satelites(id),
  entra          int not null check (entra >= 0),
  buenas         int not null check (buenas >= 0),
  segundas       int not null default 0 check (segundas >= 0),
  faltantes      int not null default 0 check (faltantes >= 0),
  termina        boolean not null default false,
  observacion    text,
  anula_id       uuid unique references public.eventos_proceso(id),
  usuario_id     uuid default auth.uid() references public.perfiles(id),
  dispositivo_id uuid references public.dispositivos(id),
  ocurrido_en    timestamptz not null default now(),
  recibido_en    timestamptz not null default now(),
  -- Regla 5: lo que entra = buenas + segundas + faltantes
  constraint cantidades_cuadran check (tipo = 'anulacion' or entra = buenas + segundas + faltantes)
);
create index on public.eventos_proceso (op_id, proceso, ocurrido_en);
select public.aplicar_estandar_evento('eventos_proceso');

-- ---------------------------------------------------------------------
-- Requisiciones y órdenes de compra
-- ---------------------------------------------------------------------
create table public.requisiciones (
  id          uuid primary key default gen_random_uuid(),
  consecutivo text not null unique default public.siguiente_consecutivo('REQ'),
  op_id       uuid references public.ordenes_produccion(id),
  origen      text not null default 'manual' check (origen in ('automatica','manual')),
  estado      text not null default 'pendiente' check (estado in ('pendiente','en_compra','atendida','anulada')),
  observacion text
);
create unique index requisicion_automatica_por_op on public.requisiciones (op_id) where origen = 'automatica' and estado <> 'anulada';

create table public.ordenes_compra (
  id            uuid primary key default gen_random_uuid(),
  consecutivo   text not null unique default public.siguiente_consecutivo('OC'),
  proveedor_id  uuid not null references public.proveedores(id),
  fecha         date not null default current_date,
  fecha_entrega date,
  estado        text not null default 'borrador' check (estado in ('borrador','enviada','parcial','recibida','anulada')),
  observacion   text,
  alegra_id     text
);

create table public.oc_lineas (
  id                uuid primary key default gen_random_uuid(),
  oc_id             uuid not null references public.ordenes_compra(id) on delete cascade,
  material_id       uuid not null references public.materiales(id),
  color_id          uuid references public.colores(id),
  cantidad          numeric(14,3) not null check (cantidad > 0),
  precio_unitario   numeric(14,2),
  cantidad_recibida numeric(14,3) not null default 0
);

create table public.requisicion_lineas (
  id              uuid primary key default gen_random_uuid(),
  requisicion_id  uuid not null references public.requisiciones(id) on delete cascade,
  material_id     uuid not null references public.materiales(id),
  color_id        uuid references public.colores(id),
  cantidad        numeric(14,3) not null check (cantidad > 0),
  fecha_requerida date,
  oc_linea_id     uuid references public.oc_lineas(id)
);
create index on public.requisicion_lineas (requisicion_id);

alter table public.recepciones add constraint recepciones_oc_fk foreign key (oc_id) references public.ordenes_compra(id);
alter table public.recepcion_lineas add column oc_linea_id uuid references public.oc_lineas(id);

-- ---------------------------------------------------------------------
-- Reservas
-- ---------------------------------------------------------------------
-- Disponible por material y color en bodegas de materia prima (telas / insumos)
create or replace function public.disponible_material(p_material uuid, p_color uuid)
returns table (bodega_id uuid, disponible numeric)
language sql stable security definer set search_path = public as $$
  select s.bodega_id, sum(s.disponible)
  from saldos_inventario s join bodegas b on b.id = s.bodega_id
  where s.material_id = p_material and s.color_id is not distinct from p_color and b.tipo in ('telas','insumos')
  group by s.bodega_id
  having sum(s.disponible) > 0
  order by sum(s.disponible) desc
$$;

-- Reservado vigente de una OP por material, color y bodega
create or replace function public.reservado_op(p_op uuid)
returns table (material_id uuid, color_id uuid, bodega_id uuid, reservado numeric)
language sql stable security definer set search_path = public as $$
  select m.material_id, m.color_id, m.bodega_id, sum(m.cantidad)
  from movimientos_inventario m
  where m.op_id = p_op and m.afecta = 'reservado'
  group by 1, 2, 3
  having sum(m.cantidad) <> 0
$$;

-- Cantidades de la OP en el formato de necesidades_ficha: {combinacion: {talla: n}}
create or replace function public.cantidades_op(p_op uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(combinacion_id, tallas), '{}') from (
    select combinacion_id, jsonb_object_agg(talla_id, cantidad) as tallas
    from op_cantidades where op_id = p_op group by combinacion_id) x
$$;

-- Calcula necesidades, reserva lo disponible, libera lo sobrante, registra
-- faltantes y mantiene la requisición automática. Todo en una transacción.
create or replace function public.reservar_op(p_op uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  n record;
  b record;
  r record;
  v_ya numeric;
  v_falta numeric;
  v_toma numeric;
  v_req uuid;
  v_en_oc numeric;
  v_hay_faltante boolean := false;
begin
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado in ('anulada','cerrada','terminada') then return; end if;
  perform set_config('app.op_sistema', 'si', true);

  -- 1. Necesidades estándar (BOM × cantidades), agrupadas por material y color
  delete from op_necesidades where op_id = p_op;
  insert into op_necesidades (op_id, material_id, color_id, cantidad_estandar, detalle)
  select p_op, x.material_id, x.color_id, round(sum(x.cantidad), 3), jsonb_agg(jsonb_build_object('parte_id', x.parte_id, 'cantidad', round(x.cantidad, 3)))
  from necesidades_ficha(o.ficha_version_id, cantidades_op(p_op)) x
  group by x.material_id, x.color_id;

  -- 2. Ajustar reservas a la necesidad
  for n in select * from op_necesidades where op_id = p_op loop
    select coalesce(sum(reservado), 0) into v_ya from reservado_op(p_op) x
     where x.material_id = n.material_id and x.color_id is not distinct from n.color_id;
    v_falta := n.cantidad_estandar - v_ya;

    if v_falta > 0 then
      for b in select * from disponible_material(n.material_id, n.color_id) loop
        exit when v_falta <= 0;
        v_toma := least(v_falta, b.disponible);
        insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id)
        values ('reserva', 'reservado', n.material_id, n.color_id, b.bodega_id, v_toma, p_op, 'op', o.consecutivo);
        v_falta := v_falta - v_toma;
      end loop;
    elsif v_falta < 0 then
      -- sobra reservado (bajó la cantidad): se libera
      for r in select * from reservado_op(p_op) x where x.material_id = n.material_id and x.color_id is not distinct from n.color_id
               order by x.reservado loop
        exit when v_falta >= 0;
        v_toma := least(-v_falta, r.reservado);
        insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id)
        values ('liberacion', 'reservado', n.material_id, n.color_id, r.bodega_id, -v_toma, p_op, 'op', o.consecutivo);
        v_falta := v_falta + v_toma;
      end loop;
    end if;

    update op_necesidades set
      reservado = (select coalesce(sum(reservado), 0) from reservado_op(p_op) x where x.material_id = n.material_id and x.color_id is not distinct from n.color_id),
      faltante = greatest(0, v_falta),
      calculado_en = now()
    where op_id = p_op and material_id = n.material_id and color_id is not distinct from n.color_id;
    if v_falta > 0 then v_hay_faltante := true; end if;
  end loop;

  -- materiales que ya no se necesitan (cambió la OP): liberar todo
  for r in select * from reservado_op(p_op) x
           where not exists (select 1 from op_necesidades nx where nx.op_id = p_op and nx.material_id = x.material_id and nx.color_id is not distinct from x.color_id) loop
    insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id)
    values ('liberacion', 'reservado', r.material_id, r.color_id, r.bodega_id, -r.reservado, p_op, 'op', o.consecutivo);
  end loop;

  -- 3. Requisición automática por lo que falta (menos lo que ya va en órdenes de compra)
  select id into v_req from requisiciones where op_id = p_op and origen = 'automatica' and estado <> 'anulada';
  if v_req is not null then
    delete from requisicion_lineas where requisicion_id = v_req and oc_linea_id is null;
  end if;
  for n in select * from op_necesidades where op_id = p_op and faltante > 0 loop
    select coalesce(sum(rl.cantidad), 0) into v_en_oc
    from requisicion_lineas rl join oc_lineas ol on ol.id = rl.oc_linea_id join ordenes_compra oc on oc.id = ol.oc_id
    where rl.requisicion_id = v_req and rl.material_id = n.material_id and rl.color_id is not distinct from n.color_id
      and oc.estado not in ('recibida','anulada');
    if n.faltante - v_en_oc > 0 then
      if v_req is null then
        insert into requisiciones (op_id, origen, observacion)
        values (p_op, 'automatica', 'Faltante de material para ' || o.consecutivo) returning id into v_req;
      end if;
      insert into requisicion_lineas (requisicion_id, material_id, color_id, cantidad, fecha_requerida)
      values (v_req, n.material_id, n.color_id, n.faltante - v_en_oc, coalesce(o.fecha_inicio_plan, o.fecha_entrega_plan));
    end if;
  end loop;
  if v_req is not null then
    update requisiciones set estado = case
        when not exists (select 1 from requisicion_lineas where requisicion_id = v_req) then 'atendida'
        when exists (select 1 from requisicion_lineas where requisicion_id = v_req and oc_linea_id is null) then 'pendiente'
        else 'en_compra' end
    where id = v_req;
  end if;

  update ordenes_produccion set alerta_material = v_hay_faltante where id = p_op;
  if v_hay_faltante and not exists (select 1 from alertas where tipo = 'material_faltante' and entidad_id = p_op::text and estado = 'abierta') then
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
    values ('material_faltante', 'alta', 'ordenes_produccion', p_op::text, format('La %s no tiene todo el material: se generó requisición de compra', o.consecutivo));
  elsif not v_hay_faltante then
    update alertas set estado = 'atendida', atendida_en = now() where tipo = 'material_faltante' and entidad_id = p_op::text and estado = 'abierta';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Crear, modificar y anular OP
-- ---------------------------------------------------------------------
-- p_cantidades: {combinacion_codigo: {talla_codigo: n}} (códigos legibles)
-- p_pedido_lineas: [{pedido_linea_id, cantidad}]
create or replace function public.crear_op(p_referencia uuid, p_cantidades jsonb, p_fecha_entrega date default null,
                                           p_prioridad int default 3, p_observacion text default null,
                                           p_pedido_lineas jsonb default '[]', p_fecha_inicio date default null,
                                           p_fecha_comprometida date default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_ficha ficha_versiones;
  v_op uuid;
  c record;
  v_total int;
begin
  perform exigir_permiso('op', 'editar');
  select f.* into v_ficha from referencias r join ficha_versiones f on f.id = r.version_vigente_id where r.id = p_referencia;
  if v_ficha.id is null or v_ficha.estado <> 'aprobada' then
    raise exception 'La referencia no tiene una ficha técnica aprobada: no se puede crear la OP';
  end if;

  insert into ordenes_produccion (referencia_id, ficha_version_id, prioridad, fecha_inicio_plan, fecha_entrega_plan, fecha_comprometida,
                                  observacion, origen)
  values (p_referencia, v_ficha.id, coalesce(p_prioridad, 3), p_fecha_inicio, p_fecha_entrega, p_fecha_comprometida, p_observacion,
          case when jsonb_array_length(coalesce(p_pedido_lineas, '[]')) > 0 then 'pedido' else 'manual' end)
  returning id into v_op;

  for c in select fc.id as combinacion_id, t.id as talla_id, (x.n #>> '{}')::int as n, cc.comb, x.talla
           from jsonb_each(p_cantidades) cc(comb, tallas) cross join lateral jsonb_each(cc.tallas) x(talla, n)
           left join ficha_combinaciones fc on fc.ficha_id = v_ficha.id and fc.codigo = cc.comb
           left join tallas t on t.codigo = x.talla
           where (x.n #>> '{}')::int > 0 loop
    if c.combinacion_id is null then raise exception 'La combinación "%" no existe en la ficha v%', c.comb, v_ficha.version; end if;
    if c.talla_id is null or not exists (select 1 from ficha_tallas where ficha_id = v_ficha.id and talla_id = c.talla_id) then
      raise exception 'La talla "%" no está en la ficha', c.talla;
    end if;
    insert into op_cantidades (op_id, combinacion_id, talla_id, cantidad) values (v_op, c.combinacion_id, c.talla_id, c.n);
  end loop;
  select coalesce(sum(cantidad), 0) into v_total from op_cantidades where op_id = v_op;
  if v_total = 0 then raise exception 'La OP no tiene cantidades'; end if;
  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set cantidad_total = v_total where id = v_op;

  insert into op_procesos (op_id, proceso, orden, modalidad)
  select v_op, proceso, orden, modalidad from ficha_ruta where ficha_id = v_ficha.id;
  update ordenes_produccion set proceso_actual = (select proceso from op_procesos where op_id = v_op order by orden limit 1) where id = v_op;

  insert into op_pedidos (op_id, pedido_linea_id, cantidad)
  select v_op, (x->>'pedido_linea_id')::uuid, (x->>'cantidad')::int from jsonb_array_elements(coalesce(p_pedido_lineas, '[]')) x;
  if exists (select 1 from op_pedidos op join pedido_lineas pl on pl.id = op.pedido_linea_id where op.op_id = v_op and pl.referencia_id <> p_referencia) then
    raise exception 'Hay líneas de pedido de otra referencia';
  end if;
  if exists (select 1 from pedido_saldos s join op_pedidos op on op.pedido_linea_id = s.pedido_linea_id where op.op_id = v_op and s.pendiente < 0) then
    raise exception 'Se asignó a la OP más de lo pendiente de un pedido';
  end if;

  perform reservar_op(v_op);
  return v_op;
end $$;

create or replace function public.actualizar_cantidades_op(p_op uuid, p_cantidades jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  c record;
  v_total int;
begin
  perform exigir_permiso('op', 'editar');
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado <> 'planeada' then raise exception 'Solo se cambian cantidades de una OP planeada (la % está %)', o.consecutivo, replace(o.estado, '_', ' '); end if;
  delete from op_cantidades where op_id = p_op;
  for c in select fc.id as combinacion_id, t.id as talla_id, (x.n #>> '{}')::int as n, cc.comb, x.talla
           from jsonb_each(p_cantidades) cc(comb, tallas) cross join lateral jsonb_each(cc.tallas) x(talla, n)
           left join ficha_combinaciones fc on fc.ficha_id = o.ficha_version_id and fc.codigo = cc.comb
           left join tallas t on t.codigo = x.talla
           where (x.n #>> '{}')::int > 0 loop
    if c.combinacion_id is null or c.talla_id is null then raise exception 'Combinación o talla inválida (%, %)', c.comb, c.talla; end if;
    insert into op_cantidades values (p_op, c.combinacion_id, c.talla_id, c.n);
  end loop;
  select coalesce(sum(cantidad), 0) into v_total from op_cantidades where op_id = p_op;
  if v_total = 0 then raise exception 'La OP no puede quedar sin cantidades (anúlela)'; end if;
  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set cantidad_total = v_total where id = p_op;
  perform reservar_op(p_op);
end $$;

create or replace function public.anular_op(p_op uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  r record;
begin
  perform exigir_permiso('op', 'editar');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la anulación'; end if;
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado <> 'planeada' then raise exception 'Solo se anula una OP planeada (la % está %)', o.consecutivo, replace(o.estado, '_', ' '); end if;
  for r in select * from reservado_op(p_op) loop
    insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id, motivo)
    values ('liberacion', 'reservado', r.material_id, r.color_id, r.bodega_id, -r.reservado, p_op, 'op', o.consecutivo, 'OP anulada: ' || p_motivo);
  end loop;
  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set estado = 'anulada', motivo_anulacion = p_motivo, alerta_material = false where id = p_op;
  update op_necesidades set reservado = 0, faltante = 0 where op_id = p_op;
  update requisiciones set estado = 'anulada' where op_id = p_op and estado = 'pendiente';
  delete from requisicion_lineas rl using requisiciones rq where rq.id = rl.requisicion_id and rq.op_id = p_op and rl.oc_linea_id is null and rq.estado = 'anulada';
  update alertas set estado = 'atendida', atendida_en = now() where entidad_id = p_op::text and estado = 'abierta';
  -- lo liberado queda para las OP que tienen faltante
  perform reasignar_faltantes();
end $$;

-- Reasigna material a las OP con faltante (después de una recepción o de anular otra OP),
-- por prioridad y fecha de entrega.
create or replace function public.reasignar_faltantes() returns int
language plpgsql security definer set search_path = public as $$
declare o record; n int := 0;
begin
  for o in select id from ordenes_produccion where alerta_material and estado in ('planeada','en_proceso')
           order by prioridad, fecha_entrega_plan nulls last, creado_en loop
    perform reservar_op(o.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- El estado, la ficha y las cantidades de la OP solo cambian por funciones
create or replace function public.fn_op_protegida() returns trigger
language plpgsql as $$
begin
  if current_setting('app.op_sistema', true) = 'si' or public.es_conexion_directa() then return new; end if;
  if (new.estado, new.ficha_version_id, new.referencia_id, new.cantidad_total, new.consecutivo, new.alerta_material, new.proceso_actual)
     is distinct from (old.estado, old.ficha_version_id, old.referencia_id, old.cantidad_total, old.consecutivo, old.alerta_material, old.proceso_actual) then
    raise exception 'El estado, la ficha, las cantidades y el proceso de la OP solo cambian con sus funciones';
  end if;
  if old.estado in ('anulada','cerrada') then raise exception 'La OP % está % y no se modifica', old.consecutivo, old.estado; end if;
  return new;
end $$;
create trigger op_protegida before update on public.ordenes_produccion
  for each row execute function public.fn_op_protegida();

-- ---------------------------------------------------------------------
-- Avance de procesos (regla 5)
-- ---------------------------------------------------------------------
create or replace function public.registrar_avance(p_op uuid, p_proceso text, p_entra int, p_buenas int, p_segundas int default 0,
                                                   p_faltantes int default 0, p_termina boolean default false, p_observacion text default null,
                                                   p_satelite uuid default null, p_celula uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  p op_procesos;
  v_ant op_procesos;
  v_disponible int;
  v_id uuid;
begin
  perform exigir_permiso('op', 'editar');
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La OP % está %', o.consecutivo, o.estado; end if;
  select * into p from op_procesos where op_id = p_op and proceso = p_proceso;
  if not found then raise exception 'El proceso % no está en la ruta de la OP', p_proceso; end if;
  if p.estado = 'terminado' then raise exception '% ya se terminó en esta OP', (select nombre from procesos where codigo = p_proceso); end if;
  if p_entra is null or p_buenas is null or p_entra <> p_buenas + coalesce(p_segundas, 0) + coalesce(p_faltantes, 0) then
    raise exception 'Registre las cantidades: entra (%) debe ser igual a buenas + segundas + faltantes', p_entra;
  end if;
  if p_entra <= 0 then raise exception 'Registre cuántas prendas entran al proceso'; end if;

  -- Lo que entra no puede superar lo que salió bueno del proceso anterior (o la cantidad de la OP en el primero)
  select * into v_ant from op_procesos where op_id = p_op and orden < p.orden order by orden desc limit 1;
  v_disponible := case when v_ant.op_id is null then ceil(o.cantidad_total * 1.10)::int else v_ant.buenas end - p.entra;
  if p_entra > v_disponible then
    raise exception 'A % solo pueden entrar % prendas (lo que salió bueno de %)',
      (select nombre from procesos where codigo = p_proceso), greatest(v_disponible, 0),
      coalesce((select nombre from procesos where codigo = v_ant.proceso), 'la OP');
  end if;

  insert into eventos_proceso (op_id, proceso, entra, buenas, segundas, faltantes, termina, observacion, satelite_id, celula_id)
  values (p_op, p_proceso, p_entra, p_buenas, coalesce(p_segundas, 0), coalesce(p_faltantes, 0), coalesce(p_termina, false), p_observacion, p_satelite, p_celula)
  returning id into v_id;

  update op_procesos set entra = entra + p_entra, buenas = buenas + p_buenas, segundas = segundas + coalesce(p_segundas, 0),
         faltantes = faltantes + coalesce(p_faltantes, 0),
         estado = case when p_termina then 'terminado' else 'en_proceso' end,
         inicio = coalesce(inicio, now()), fin = case when p_termina then now() end
   where op_id = p_op and proceso = p_proceso;

  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set
    estado = case when not exists (select 1 from op_procesos where op_id = p_op and estado <> 'terminado') then 'terminada' else 'en_proceso' end,
    proceso_actual = coalesce((select proceso from op_procesos where op_id = p_op and estado <> 'terminado' order by orden limit 1), p_proceso)
  where id = p_op;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Compras
-- ---------------------------------------------------------------------
-- Crea una orden de compra con las líneas de requisición elegidas (todas del mismo proveedor)
create or replace function public.crear_oc(p_proveedor uuid, p_lineas uuid[], p_fecha_entrega date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_oc uuid;
  g record;
  v_linea uuid;
begin
  perform exigir_permiso('compras', 'editar');
  if exists (select 1 from requisicion_lineas where id = any(p_lineas) and oc_linea_id is not null) then
    raise exception 'Alguna línea ya está en una orden de compra';
  end if;
  insert into ordenes_compra (proveedor_id, fecha_entrega) values (p_proveedor, p_fecha_entrega) returning id into v_oc;
  for g in select rl.material_id, rl.color_id, sum(rl.cantidad) as cantidad, array_agg(rl.id) as ids, m.costo_estandar
           from requisicion_lineas rl join materiales m on m.id = rl.material_id
           where rl.id = any(p_lineas) group by rl.material_id, rl.color_id, m.costo_estandar loop
    insert into oc_lineas (oc_id, material_id, color_id, cantidad, precio_unitario)
    values (v_oc, g.material_id, g.color_id, g.cantidad, g.costo_estandar) returning id into v_linea;
    update requisicion_lineas set oc_linea_id = v_linea where id = any(g.ids);
  end loop;
  if not exists (select 1 from oc_lineas where oc_id = v_oc) then raise exception 'Elija al menos una línea'; end if;
  update requisiciones r set estado = 'en_compra'
   where r.id in (select requisicion_id from requisicion_lineas where id = any(p_lineas))
     and not exists (select 1 from requisicion_lineas x where x.requisicion_id = r.id and x.oc_linea_id is null);
  return v_oc;
end $$;

create or replace function public.cambiar_estado_oc(p_oc uuid, p_estado text) returns void
language plpgsql security definer set search_path = public as $$
declare v ordenes_compra;
begin
  perform exigir_permiso('compras', 'editar');
  select * into v from ordenes_compra where id = p_oc for update;
  if p_estado = 'enviada' and v.estado <> 'borrador' then raise exception 'Solo se envía una OC en borrador'; end if;
  if p_estado = 'anulada' and v.estado not in ('borrador','enviada') then raise exception 'No se anula una OC con recepciones'; end if;
  if p_estado not in ('enviada','anulada') then raise exception 'Estado inválido'; end if;
  perform set_config('app.oc_sistema', 'si', true);
  update ordenes_compra set estado = p_estado where id = p_oc;
  if p_estado = 'anulada' then
    -- las líneas de requisición vuelven a quedar pendientes de compra
    update requisicion_lineas set oc_linea_id = null where oc_linea_id in (select id from oc_lineas where oc_id = p_oc);
    update requisiciones r set estado = 'pendiente'
     where exists (select 1 from requisicion_lineas x where x.requisicion_id = r.id and x.oc_linea_id is null) and r.estado = 'en_compra';
  end if;
end $$;

-- Al confirmar una entrada con orden de compra: suma lo recibido, actualiza la OC y
-- reasigna el material a las OP con faltante (misma transacción).
create or replace function public.fn_recepcion_oc() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_oc uuid := new.oc_id;
begin
  if new.estado = 'confirmada' and old.estado = 'borrador' then
    if v_oc is not null then
      update oc_lineas ol set cantidad_recibida = ol.cantidad_recibida + x.cant
      from (select coalesce(rl.oc_linea_id,
                            (select l.id from oc_lineas l where l.oc_id = v_oc and l.material_id = rl.material_id
                               and l.color_id is not distinct from rl.color_id order by l.id limit 1)) as linea, sum(rl.cantidad) as cant
            from recepcion_lineas rl where rl.recepcion_id = new.id group by 1) x
      where ol.id = x.linea;
      update ordenes_compra set estado = case
          when not exists (select 1 from oc_lineas where oc_id = v_oc and cantidad_recibida < cantidad) then 'recibida' else 'parcial' end
       where id = v_oc;
      update requisiciones r set estado = 'atendida'
       where r.estado = 'en_compra' and not exists (
         select 1 from requisicion_lineas rl join oc_lineas ol on ol.id = rl.oc_linea_id join ordenes_compra oc on oc.id = ol.oc_id
         where rl.requisicion_id = r.id and oc.estado <> 'recibida');
    end if;
    perform reasignar_faltantes();
  end if;
  return new;
end $$;
create trigger recepciones_oc after update on public.recepciones
  for each row execute function public.fn_recepcion_oc();

-- ---------------------------------------------------------------------
-- Vistas
-- ---------------------------------------------------------------------
-- Saldo de cada línea de pedido: pedido, en OP (no anuladas) y pendiente
create view public.pedido_saldos with (security_invoker = true) as
select pl.id as pedido_linea_id, pl.pedido_id, pl.referencia_id, pl.combinacion_codigo, pl.talla_id, pl.cantidad,
       coalesce(sum(op.cantidad) filter (where o.estado <> 'anulada'), 0)::int as en_op,
       (pl.cantidad - coalesce(sum(op.cantidad) filter (where o.estado <> 'anulada'), 0))::int as pendiente
from public.pedido_lineas pl
left join public.op_pedidos op on op.pedido_linea_id = pl.id
left join public.ordenes_produccion o on o.id = op.op_id
group by pl.id;

-- ---------------------------------------------------------------------
-- Estándar y RLS
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['pedidos','pedido_lineas','ordenes_produccion','requisiciones','requisicion_lineas','ordenes_compra','oc_lineas']
  loop perform public.aplicar_estandar_maestro(t); end loop;
end $$;
select public.aplicar_estandar_maestro('op_cantidades', 'op_id');
select public.aplicar_estandar_maestro('op_procesos', 'op_id');
alter table public.op_pedidos enable row level security;
alter table public.op_necesidades enable row level security;

-- Lectura: internos (las OP las consultan casi todas las áreas)
do $$
declare t text;
begin
  foreach t in array array['pedidos','pedido_lineas','ordenes_produccion','op_cantidades','op_pedidos','op_necesidades','op_procesos',
                           'eventos_proceso','requisiciones','requisicion_lineas','ordenes_compra','oc_lineas']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.es_interno())', t || '_leer', t);
  end loop;
end $$;
-- Pedidos: Comercial y Producción los crean y editan
create policy pedidos_insertar on public.pedidos for insert to authenticated with check (public.puede('pedidos','editar'));
create policy pedidos_actualizar on public.pedidos for update to authenticated using (public.puede('pedidos','editar')) with check (public.puede('pedidos','editar'));
create policy pedido_lineas_insertar on public.pedido_lineas for insert to authenticated with check (public.puede('pedidos','editar'));
create policy pedido_lineas_actualizar on public.pedido_lineas for update to authenticated using (public.puede('pedidos','editar')) with check (public.puede('pedidos','editar'));
create policy pedido_lineas_borrar on public.pedido_lineas for delete to authenticated
  using (public.puede('pedidos','editar') and not exists (select 1 from public.op_pedidos where pedido_linea_id = pedido_lineas.id));
-- OP: fechas, prioridad y observación (lo demás por funciones, protegido por trigger)
create policy op_actualizar on public.ordenes_produccion for update to authenticated using (public.puede('op','editar')) with check (public.puede('op','editar'));
-- Requisiciones manuales (Compras y Producción)
create policy req_insertar on public.requisiciones for insert to authenticated
  with check ((public.puede('compras','editar') or public.puede('op','editar')) and origen = 'manual');
create policy req_lineas_insertar on public.requisicion_lineas for insert to authenticated
  with check (public.puede('compras','editar') or public.puede('op','editar'));
create policy oc_actualizar on public.ordenes_compra for update to authenticated using (public.puede('compras','editar')) with check (public.puede('compras','editar'));
create policy oc_lineas_actualizar on public.oc_lineas for update to authenticated using (public.puede('compras','editar')) with check (public.puede('compras','editar'));

-- Las OP que bajan a las tablets (Fase 6) se agregan a la publicación entonces.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.ordenes_produccion, public.op_procesos;
  end if;
end $$;
