-- =====================================================================
-- Fase 2 · Migración 6: inventarios (telas por rollo, retazos, insumos,
-- kardex, entradas, ajustes con aprobación, conteos físicos, traslados)
-- Reglas: 1 (sin salida sin OP/ajuste), 2 (kardex inmutable), 3 (stock =
-- suma de movimientos, saldos en la misma transacción), 4 (disponible =
-- físico − reservado), 7 (operaciones transaccionales).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Autorización dentro de funciones
-- ---------------------------------------------------------------------
-- Conexión directa a la base (psql, seed, tareas del servidor): sin JWT.
create or replace function public.es_conexion_directa() returns boolean
language sql stable as $$
  select auth.uid() is null
     and coalesce(current_setting('request.jwt.claims', true), '') in ('', 'null')
     and coalesce(current_setting('request.jwt.claim.sub', true), '') = ''
$$;

create or replace function public.exigir_permiso(p_modulo text, p_accion text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.es_conexion_directa() or public.puede(p_modulo, p_accion)) then
    raise exception 'Sin permiso para % en %', p_accion, p_modulo using errcode = '42501';
  end if;
end $$;

insert into public.consecutivos (tipo, prefijo) values ('TL', 'TL') on conflict do nothing;

-- ---------------------------------------------------------------------
-- Maestros de inventario
-- ---------------------------------------------------------------------
create table public.categorias_material (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  tipo   text not null check (tipo in ('tela','insumo')),
  activo boolean not null default true
);

create table public.materiales (
  id                uuid primary key default gen_random_uuid(),
  codigo            text not null unique,
  tipo              text not null check (tipo in ('tela','insumo')),
  categoria_id      uuid references public.categorias_material(id),
  nombre            text not null,
  unidad            text not null references public.unidades_medida(codigo),
  composicion       text,
  ancho_nominal_cm  numeric(6,1),
  gramaje_gm2       numeric(7,1),
  rendimiento_m_kg  numeric(8,3),       -- metros por kilo (para convertir)
  maneja_rollos     boolean not null default false,
  maneja_color      boolean not null default true,
  proveedor_id      uuid references public.proveedores(id),
  costo_estandar    numeric(14,2),      -- por unidad
  stock_minimo      numeric(14,3),
  activo            boolean not null default true,
  check (tipo <> 'tela' or (maneja_rollos and unidad in ('m','kg')))
);

create table public.rollos (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique check (codigo like 'TL-%'),
  material_id        uuid not null references public.materiales(id),
  color_id           uuid not null references public.colores(id),
  proveedor_id       uuid references public.proveedores(id),
  lote_tintura       text not null,
  tono               text,
  ancho_real_cm      numeric(6,1) not null check (ancho_real_cm > 0),
  metros_iniciales   numeric(10,2) not null check (metros_iniciales >= 0),
  kilos_iniciales    numeric(10,3) not null check (kilos_iniciales >= 0),
  metros_saldo       numeric(10,2) not null default 0,   -- lo mantiene el kardex
  kilos_saldo        numeric(10,3) not null default 0,   -- lo mantiene el kardex
  costo_unitario     numeric(14,2),                      -- por unidad del material
  bodega_id          uuid not null references public.bodegas(id),
  ubicacion_id       uuid references public.ubicaciones(id),
  estado             text not null default 'disponible'
                     check (estado in ('disponible','reservado','en_corte','retazo','agotado')),
  es_retazo          boolean not null default false,
  rollo_origen_id    uuid references public.rollos(id),
  recepcion_linea_id uuid,
  fecha_ingreso      date not null default current_date,
  observacion        text,
  check (not es_retazo or rollo_origen_id is not null)
);
create index on public.rollos (material_id, color_id, estado);
create index on public.rollos (bodega_id, estado);
create index on public.rollos (lote_tintura);

-- ---------------------------------------------------------------------
-- Ajustes (con aprobación) — se definen antes del kardex por la FK
-- ---------------------------------------------------------------------
create table public.ajustes_inventario (
  id             uuid primary key default gen_random_uuid(),
  consecutivo    text not null unique default public.siguiente_consecutivo('AJU'),
  motivo         text not null check (trim(motivo) <> ''),
  origen         text not null default 'manual' check (origen in ('manual','conteo')),
  conteo_id      uuid,
  estado         text not null default 'borrador' check (estado in ('borrador','enviado','aprobado','rechazado')),
  solicitado_por uuid default auth.uid(),
  aprobado_por   uuid,
  decidido_en    timestamptz,
  comentario     text
);

create table public.ajuste_lineas (
  id             uuid primary key default gen_random_uuid(),
  ajuste_id      uuid not null references public.ajustes_inventario(id),
  material_id    uuid not null references public.materiales(id),
  color_id       uuid references public.colores(id),
  rollo_id       uuid references public.rollos(id),
  bodega_id      uuid not null references public.bodegas(id),
  ubicacion_id   uuid references public.ubicaciones(id),
  cantidad       numeric(14,3) not null check (cantidad <> 0),   -- con signo, en la unidad del material
  metros         numeric(12,2),
  kilos          numeric(12,3),
  costo_unitario numeric(14,2),
  observacion    text
);
create index on public.ajuste_lineas (ajuste_id);

-- Las líneas solo se tocan mientras el ajuste está en borrador
create or replace function public.fn_ajuste_editable() returns trigger
language plpgsql as $$
declare v_estado text;
begin
  select estado into v_estado from public.ajustes_inventario
   where id = coalesce(new.ajuste_id, old.ajuste_id);
  if v_estado <> 'borrador' then
    raise exception 'El ajuste ya fue enviado (%): no se pueden cambiar sus líneas', v_estado;
  end if;
  return coalesce(new, old);
end $$;
create trigger ajuste_lineas_editable before insert or update or delete on public.ajuste_lineas
  for each row execute function public.fn_ajuste_editable();

-- ---------------------------------------------------------------------
-- KARDEX: movimientos de inventario (E) — nunca se editan ni se borran
-- ---------------------------------------------------------------------
create table public.movimientos_inventario (
  id              uuid primary key default gen_random_uuid(),
  tipo            text not null check (tipo in ('entrada_compra','reserva','liberacion','salida_op','envio_satelite',
                                                'devolucion','ajuste','conteo','traslado','anulacion')),
  afecta          text not null default 'fisico' check (afecta in ('fisico','reservado')),
  material_id     uuid not null references public.materiales(id),
  color_id        uuid references public.colores(id),
  rollo_id        uuid references public.rollos(id),
  bodega_id       uuid not null references public.bodegas(id),
  ubicacion_id    uuid references public.ubicaciones(id),
  cantidad        numeric(14,3) not null,              -- con signo, unidad del material
  metros          numeric(12,2),
  kilos           numeric(12,3),
  costo_unitario  numeric(14,2),
  op_id           uuid,                                -- FK a ordenes_produccion en la Fase 4
  ajuste_id       uuid references public.ajustes_inventario(id),
  documento_tipo  text,
  documento_id    text,
  motivo          text,
  anula_id        uuid unique references public.movimientos_inventario(id),
  usuario_id      uuid default auth.uid(),
  dispositivo_id  uuid references public.dispositivos(id),
  ocurrido_en     timestamptz not null default now(),
  recibido_en     timestamptz not null default now(),
  -- Regla 1: ninguna salida física sin OP o ajuste (los traslados y anulaciones son internos)
  constraint salida_requiere_op_o_ajuste check (
    afecta <> 'fisico' or cantidad >= 0 or tipo in ('traslado','anulacion')
    or op_id is not null or ajuste_id is not null),
  constraint ajuste_requiere_documento check (tipo not in ('ajuste','conteo') or ajuste_id is not null),
  constraint anulacion_con_motivo check (tipo <> 'anulacion' or (anula_id is not null and coalesce(trim(motivo), '') <> ''))
);
create index on public.movimientos_inventario (material_id, color_id, ocurrido_en);
create index on public.movimientos_inventario (rollo_id, ocurrido_en);
create index on public.movimientos_inventario (documento_tipo, documento_id);
select public.aplicar_estandar_evento('movimientos_inventario');

-- Saldos (rendimiento). Se actualizan en la misma transacción del movimiento.
create table public.saldos_inventario (
  id             bigserial primary key,
  material_id    uuid not null references public.materiales(id),
  color_id       uuid references public.colores(id),
  bodega_id      uuid not null references public.bodegas(id),
  ubicacion_id   uuid references public.ubicaciones(id),
  fisico         numeric(14,3) not null default 0,
  reservado      numeric(14,3) not null default 0,
  disponible     numeric(14,3) generated always as (fisico - reservado) stored,
  kilos          numeric(14,3) not null default 0,
  costo_promedio numeric(14,2),
  actualizado_en timestamptz not null default now()
);
create unique index saldos_clave on public.saldos_inventario (
  material_id, coalesce(color_id, '00000000-0000-0000-0000-000000000000'::uuid),
  bodega_id, coalesce(ubicacion_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table public.saldos_inventario enable row level security;

-- Aplica cada movimiento a saldos y rollo. Si algo queda negativo (p. ej. por
-- descuentos hechos sin conexión) se aplica igual y se alerta a bodega.
create or replace function public.fn_aplicar_movimiento() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_saldo saldos_inventario;
  v_rollo rollos;
  v_material materiales;
begin
  if new.ajuste_id is not null and not exists (
       select 1 from ajustes_inventario where id = new.ajuste_id and estado = 'aprobado') then
    raise exception 'El ajuste del movimiento no está aprobado';
  end if;

  insert into saldos_inventario as s (material_id, color_id, bodega_id, ubicacion_id, fisico, reservado, kilos, costo_promedio)
  values (new.material_id, new.color_id, new.bodega_id, new.ubicacion_id,
          case when new.afecta = 'fisico' then new.cantidad else 0 end,
          case when new.afecta = 'reservado' then new.cantidad else 0 end,
          case when new.afecta = 'fisico' then coalesce(new.kilos, 0) else 0 end,
          new.costo_unitario)
  on conflict (material_id, coalesce(color_id, '00000000-0000-0000-0000-000000000000'::uuid),
               bodega_id, coalesce(ubicacion_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set
    -- costo promedio ponderado solo con entradas que traen costo
    costo_promedio = case
      when new.afecta = 'fisico' and new.cantidad > 0 and new.costo_unitario is not null
           and s.fisico + new.cantidad > 0 and new.tipo in ('entrada_compra','devolucion')
        then round((greatest(s.fisico, 0) * coalesce(s.costo_promedio, new.costo_unitario)
                    + new.cantidad * new.costo_unitario) / (greatest(s.fisico, 0) + new.cantidad), 2)
      else coalesce(s.costo_promedio, new.costo_unitario) end,
    fisico = s.fisico + case when new.afecta = 'fisico' then new.cantidad else 0 end,
    reservado = s.reservado + case when new.afecta = 'reservado' then new.cantidad else 0 end,
    kilos = s.kilos + case when new.afecta = 'fisico' then coalesce(new.kilos, 0) else 0 end,
    actualizado_en = now()
  returning * into v_saldo;

  if v_saldo.fisico < 0 then
    select * into v_material from materiales where id = new.material_id;
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
    values ('stock_negativo', 'alta', 'materiales', new.material_id::text,
            format('Saldo negativo de %s: %s %s. Revise en bodega.', v_material.nombre, v_saldo.fisico, v_material.unidad),
            jsonb_build_object('movimiento_id', new.id, 'bodega_id', new.bodega_id, 'saldo', v_saldo.fisico));
  end if;

  if new.rollo_id is not null and new.afecta = 'fisico' then
    update rollos r set
      metros_saldo = r.metros_saldo + coalesce(new.metros, 0),
      kilos_saldo  = r.kilos_saldo + coalesce(new.kilos, 0),
      estado = case
        when r.metros_saldo + coalesce(new.metros, 0) <= 0.005 and r.kilos_saldo + coalesce(new.kilos, 0) <= 0.0005 then 'agotado'
        when r.es_retazo then 'retazo'
        when r.estado = 'agotado' then 'disponible'
        else r.estado end
    where r.id = new.rollo_id
    returning * into v_rollo;
    if v_rollo.metros_saldo < 0 or v_rollo.kilos_saldo < 0 then
      insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
      values ('stock_negativo', 'alta', 'rollos', v_rollo.id::text,
              format('El rollo %s quedó con saldo negativo (%s m / %s kg).', v_rollo.codigo, v_rollo.metros_saldo, v_rollo.kilos_saldo),
              jsonb_build_object('movimiento_id', new.id));
    end if;
  end if;
  return new;
end $$;

create trigger movimientos_aplicar after insert on public.movimientos_inventario
  for each row execute function public.fn_aplicar_movimiento();

-- Cantidad de un rollo expresada en la unidad de su material
create or replace function public.cantidad_rollo(p_rollo public.rollos) returns numeric
language sql stable as $$
  select case m.unidad when 'kg' then p_rollo.kilos_saldo else p_rollo.metros_saldo end
  from public.materiales m where m.id = p_rollo.material_id
$$;

-- ---------------------------------------------------------------------
-- Entradas (recepción de mercancía). Con orden de compra desde la Fase 4.
-- ---------------------------------------------------------------------
create table public.recepciones (
  id                uuid primary key default gen_random_uuid(),
  consecutivo       text not null unique default public.siguiente_consecutivo('REC'),
  proveedor_id      uuid references public.proveedores(id),
  bodega_id         uuid not null references public.bodegas(id),
  factura_proveedor text,
  fecha             date not null default current_date,
  estado            text not null default 'borrador' check (estado in ('borrador','confirmada','anulada')),
  observacion       text,
  oc_id             uuid,               -- FK a ordenes_compra en la Fase 4
  confirmada_por    uuid,
  confirmada_en     timestamptz,
  motivo_anulacion  text
);

create table public.recepcion_lineas (
  id             uuid primary key default gen_random_uuid(),
  recepcion_id   uuid not null references public.recepciones(id),
  orden          int  not null default 0,
  material_id    uuid not null references public.materiales(id),
  color_id       uuid references public.colores(id),
  cantidad       numeric(14,3) not null check (cantidad > 0),   -- unidad del material
  costo_unitario numeric(14,2),
  -- solo telas (una línea por rollo):
  lote_tintura   text,
  tono           text,
  ancho_real_cm  numeric(6,1),
  metros         numeric(10,2),
  kilos          numeric(10,3),
  ubicacion_id   uuid references public.ubicaciones(id),
  rollo_id       uuid references public.rollos(id)              -- se llena al confirmar
);
create index on public.recepcion_lineas (recepcion_id, orden);
alter table public.rollos add constraint rollos_recepcion_fk
  foreign key (recepcion_linea_id) references public.recepcion_lineas(id);

create or replace function public.fn_recepcion_editable() returns trigger
language plpgsql as $$
begin
  if current_setting('app.confirmando_recepcion', true) = 'si' then return coalesce(new, old); end if;
  if (select estado from public.recepciones where id = coalesce(new.recepcion_id, old.recepcion_id)) <> 'borrador' then
    raise exception 'La entrada ya no está en borrador: no se pueden cambiar sus líneas';
  end if;
  return coalesce(new, old);
end $$;
create trigger recepcion_lineas_editable before insert or update or delete on public.recepcion_lineas
  for each row execute function public.fn_recepcion_editable();

-- El encabezado tampoco cambia después de confirmar (salvo por las funciones)
create or replace function public.fn_recepcion_cabecera() returns trigger
language plpgsql as $$
begin
  if old.estado <> 'borrador' and current_setting('app.confirmando_recepcion', true) is distinct from 'si' then
    raise exception 'La entrada % ya está %: no se puede modificar', old.consecutivo, old.estado;
  end if;
  return new;
end $$;
create trigger recepciones_editable before update on public.recepciones
  for each row execute function public.fn_recepcion_cabecera();

-- Confirma la entrada: crea rollos y movimientos. Todo o nada. Devuelve los rollos creados.
create or replace function public.confirmar_recepcion(p_recepcion uuid) returns setof public.rollos
language plpgsql security definer set search_path = public as $$
declare
  v_rec recepciones;
  l record;
  v_rollo rollos;
  v_ubicacion uuid;
begin
  perform exigir_permiso('inventario', 'editar');
  select * into v_rec from recepciones where id = p_recepcion for update;
  if not found then raise exception 'Entrada inexistente'; end if;
  if v_rec.estado <> 'borrador' then raise exception 'La entrada % ya está %', v_rec.consecutivo, v_rec.estado; end if;
  if not exists (select 1 from recepcion_lineas where recepcion_id = p_recepcion) then
    raise exception 'La entrada no tiene líneas';
  end if;
  perform set_config('app.confirmando_recepcion', 'si', true);

  for l in select rl.*, m.tipo, m.unidad, m.maneja_color, m.nombre as material
           from recepcion_lineas rl join materiales m on m.id = rl.material_id
           where rl.recepcion_id = p_recepcion order by rl.orden, rl.id loop
    if l.ubicacion_id is not null and not exists (select 1 from ubicaciones where id = l.ubicacion_id and bodega_id = v_rec.bodega_id) then
      raise exception 'La ubicación de la línea de % no pertenece a la bodega de la entrada', l.material;
    end if;
    if l.maneja_color and l.color_id is null then raise exception 'Falta el color de %', l.material; end if;

    if l.tipo = 'tela' then
      if coalesce(trim(l.lote_tintura), '') = '' then raise exception 'Falta el lote de tintura del rollo de %', l.material; end if;
      if l.ancho_real_cm is null or l.metros is null or l.kilos is null then
        raise exception 'Cada rollo de % necesita ancho, metros y kilos', l.material;
      end if;
      insert into rollos (codigo, material_id, color_id, proveedor_id, lote_tintura, tono, ancho_real_cm,
                          metros_iniciales, kilos_iniciales, costo_unitario, bodega_id, ubicacion_id, recepcion_linea_id, fecha_ingreso)
      values (siguiente_consecutivo('TL'), l.material_id, l.color_id, v_rec.proveedor_id, trim(l.lote_tintura), l.tono,
              l.ancho_real_cm, l.metros, l.kilos, l.costo_unitario, v_rec.bodega_id, l.ubicacion_id, l.id, v_rec.fecha)
      returning * into v_rollo;
      update recepcion_lineas set rollo_id = v_rollo.id where id = l.id;
      insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                          costo_unitario, documento_tipo, documento_id)
      values ('entrada_compra', l.material_id, l.color_id, v_rollo.id, v_rec.bodega_id, l.ubicacion_id,
              case l.unidad when 'kg' then l.kilos else l.metros end, l.metros, l.kilos,
              l.costo_unitario, 'recepcion', v_rec.consecutivo);
      select * into v_rollo from rollos where id = v_rollo.id;
      return next v_rollo;
    else
      insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, ubicacion_id, cantidad, costo_unitario,
                                          documento_tipo, documento_id)
      values ('entrada_compra', l.material_id, l.color_id, v_rec.bodega_id, l.ubicacion_id, l.cantidad, l.costo_unitario,
              'recepcion', v_rec.consecutivo);
    end if;
  end loop;

  update recepciones set estado = 'confirmada', confirmada_por = auth.uid(), confirmada_en = now() where id = p_recepcion;
  perform set_config('app.confirmando_recepcion', '', true);
end $$;

-- Anula una entrada confirmada con movimientos inversos. Solo si sus rollos no se han tocado.
create or replace function public.anular_recepcion(p_recepcion uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_rec recepciones;
  m movimientos_inventario;
begin
  perform exigir_permiso('inventario', 'aprobar');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la anulación'; end if;
  select * into v_rec from recepciones where id = p_recepcion for update;
  if v_rec.estado <> 'confirmada' then raise exception 'Solo se anulan entradas confirmadas'; end if;
  if exists (select 1 from movimientos_inventario mi join recepcion_lineas rl on rl.rollo_id = mi.rollo_id
             where rl.recepcion_id = p_recepcion and not (mi.documento_tipo = 'recepcion' and mi.documento_id = v_rec.consecutivo)) then
    raise exception 'Hay rollos de esta entrada que ya tienen otros movimientos: haga un ajuste';
  end if;
  for m in select * from movimientos_inventario where documento_tipo = 'recepcion' and documento_id = v_rec.consecutivo
           and tipo = 'entrada_compra' loop
    insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                        costo_unitario, documento_tipo, documento_id, anula_id, motivo)
    values ('anulacion', m.material_id, m.color_id, m.rollo_id, m.bodega_id, m.ubicacion_id, -m.cantidad, -m.metros, -m.kilos,
            m.costo_unitario, 'recepcion', v_rec.consecutivo, m.id, p_motivo);
  end loop;
  perform set_config('app.confirmando_recepcion', 'si', true);
  update recepciones set estado = 'anulada', motivo_anulacion = p_motivo where id = p_recepcion;
end $$;

-- ---------------------------------------------------------------------
-- Ajustes: enviar, aprobar (otra persona), rechazar
-- ---------------------------------------------------------------------
create or replace function public.enviar_ajuste(p_ajuste uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('inventario', 'editar');
  perform set_config('app.cambio_ajuste', 'si', true);
  if not exists (select 1 from ajuste_lineas where ajuste_id = p_ajuste) then raise exception 'El ajuste no tiene líneas'; end if;
  update ajustes_inventario set estado = 'enviado' where id = p_ajuste and estado = 'borrador';
  if not found then raise exception 'Solo se envían ajustes en borrador'; end if;
  insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
  select 'ajuste_por_aprobar', 'media', 'ajustes_inventario', id::text,
         format('Ajuste %s por aprobar: %s', consecutivo, motivo)
  from ajustes_inventario where id = p_ajuste;
end $$;

create or replace function public.decidir_ajuste(p_ajuste uuid, p_aprobar boolean, p_comentario text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v ajustes_inventario;
begin
  perform exigir_permiso('inventario', 'aprobar');
  select * into v from ajustes_inventario where id = p_ajuste for update;
  perform set_config('app.cambio_ajuste', 'si', true);
  if v.estado <> 'enviado' then raise exception 'El ajuste % no está pendiente de aprobación (%)', v.consecutivo, v.estado; end if;
  if v.solicitado_por = auth.uid() and not es_gerencia() then
    raise exception 'Un ajuste debe aprobarlo una persona distinta de quien lo solicitó';
  end if;
  if not p_aprobar and coalesce(trim(p_comentario), '') = '' then raise exception 'Escriba el motivo del rechazo'; end if;

  update ajustes_inventario
     set estado = case when p_aprobar then 'aprobado' else 'rechazado' end,
         aprobado_por = auth.uid(), decidido_en = now(), comentario = p_comentario
   where id = p_ajuste;

  if p_aprobar then
    insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                        costo_unitario, ajuste_id, documento_tipo, documento_id, motivo)
    select case when v.origen = 'conteo' then 'conteo' else 'ajuste' end,
           l.material_id, l.color_id, l.rollo_id, l.bodega_id, l.ubicacion_id, l.cantidad, l.metros, l.kilos,
           l.costo_unitario, v.id, 'ajuste', v.consecutivo, v.motivo
    from ajuste_lineas l where l.ajuste_id = p_ajuste;
    if v.conteo_id is not null then
      update conteos_fisicos set estado = 'ajustado' where id = v.conteo_id;
    end if;
  end if;
  update alertas set estado = 'atendida', atendida_por = auth.uid(), atendida_en = now()
   where tipo = 'ajuste_por_aprobar' and entidad_id = p_ajuste::text and estado = 'abierta';
end $$;

-- ---------------------------------------------------------------------
-- Traslados de rollo (también desde el celular sin conexión)
-- ---------------------------------------------------------------------
create table public.traslados_rollo (
  id                   uuid primary key,
  rollo_id             uuid not null references public.rollos(id),
  ubicacion_origen_id  uuid references public.ubicaciones(id),
  ubicacion_destino_id uuid not null references public.ubicaciones(id),
  usuario_id           uuid default auth.uid(),
  dispositivo_id       uuid references public.dispositivos(id),
  ocurrido_en          timestamptz not null default now(),
  recibido_en          timestamptz not null default now()
);
select public.aplicar_estandar_evento('traslados_rollo');

create or replace function public.aplicar_traslado(p_id uuid, p_rollo uuid, p_destino uuid, p_ocurrido timestamptz default now(),
                                                   p_dispositivo uuid default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  r rollos;
  v_bodega_destino uuid;
  v_cant numeric;
  v_n int;
begin
  select * into r from rollos where id = p_rollo for update;
  if not found then raise exception 'Rollo inexistente'; end if;
  select bodega_id into v_bodega_destino from ubicaciones where id = p_destino and activo;
  if v_bodega_destino is null then raise exception 'Ubicación de destino inexistente o inactiva'; end if;

  insert into traslados_rollo (id, rollo_id, ubicacion_origen_id, ubicacion_destino_id, dispositivo_id, ocurrido_en)
  values (p_id, p_rollo, r.ubicacion_id, p_destino, p_dispositivo, p_ocurrido)
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;                         -- ya aplicado (reenvío)
  if r.ubicacion_id = p_destino then return true; end if;       -- ya estaba ahí

  v_cant := cantidad_rollo(r);
  if v_cant <> 0 or r.kilos_saldo <> 0 then
    insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                        costo_unitario, documento_tipo, documento_id, dispositivo_id, ocurrido_en)
    values ('traslado', r.material_id, r.color_id, r.id, r.bodega_id, r.ubicacion_id, -v_cant, -r.metros_saldo, -r.kilos_saldo,
            r.costo_unitario, 'traslado', p_id::text, p_dispositivo, p_ocurrido),
           ('traslado', r.material_id, r.color_id, r.id, v_bodega_destino, p_destino, v_cant, r.metros_saldo, r.kilos_saldo,
            r.costo_unitario, 'traslado', p_id::text, p_dispositivo, p_ocurrido);
  end if;
  update rollos set ubicacion_id = p_destino, bodega_id = v_bodega_destino where id = p_rollo;
  return true;
end $$;

create or replace function public.trasladar_rollo(p_rollo uuid, p_destino uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('inventario', 'editar');
  perform aplicar_traslado(gen_random_uuid(), p_rollo, p_destino);
end $$;

-- Separa un retazo utilizable de un rollo: queda como un rollo nuevo (TL-…) con el mismo lote.
create or replace function public.separar_retazo(p_rollo uuid, p_metros numeric, p_kilos numeric, p_ubicacion uuid default null)
returns public.rollos
language plpgsql security definer set search_path = public as $$
declare
  r rollos;
  n rollos;
  v_unidad text;
begin
  perform exigir_permiso('inventario', 'editar');
  select * into r from rollos where id = p_rollo for update;
  if p_metros <= 0 or p_kilos < 0 then raise exception 'Metros y kilos del retazo deben ser positivos'; end if;
  if p_metros > r.metros_saldo or p_kilos > r.kilos_saldo then raise exception 'El retazo no puede ser mayor que el saldo del rollo'; end if;
  select unidad into v_unidad from materiales where id = r.material_id;
  insert into rollos (codigo, material_id, color_id, proveedor_id, lote_tintura, tono, ancho_real_cm, metros_iniciales, kilos_iniciales,
                      costo_unitario, bodega_id, ubicacion_id, estado, es_retazo, rollo_origen_id, observacion)
  values (siguiente_consecutivo('TL'), r.material_id, r.color_id, r.proveedor_id, r.lote_tintura, r.tono, r.ancho_real_cm,
          p_metros, p_kilos, r.costo_unitario, r.bodega_id, coalesce(p_ubicacion, r.ubicacion_id), 'retazo', true, r.id,
          'Retazo de ' || r.codigo)
  returning * into n;
  insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                      costo_unitario, documento_tipo, documento_id)
  values ('traslado', r.material_id, r.color_id, r.id, r.bodega_id, r.ubicacion_id,
          -(case v_unidad when 'kg' then p_kilos else p_metros end), -p_metros, -p_kilos, r.costo_unitario, 'retazo', n.codigo),
         ('traslado', n.material_id, n.color_id, n.id, n.bodega_id, n.ubicacion_id,
          case v_unidad when 'kg' then p_kilos else p_metros end, p_metros, p_kilos, n.costo_unitario, 'retazo', n.codigo);
  select * into n from rollos where id = n.id;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Conteos físicos (con el celular, también sin conexión)
-- ---------------------------------------------------------------------
create table public.conteos_fisicos (
  id           uuid primary key default gen_random_uuid(),
  consecutivo  text not null unique default public.siguiente_consecutivo('CON'),
  bodega_id    uuid not null references public.bodegas(id),
  ubicacion_id uuid references public.ubicaciones(id),     -- null = toda la bodega
  alcance      text not null default 'todo' check (alcance in ('telas','insumos','todo')),
  estado       text not null default 'abierto' check (estado in ('abierto','cerrado','ajustado','anulado')),
  abierto_por  uuid default auth.uid(),
  abierto_en   timestamptz not null default now(),
  cerrado_por  uuid,
  cerrado_en   timestamptz,
  ajuste_id    uuid references public.ajustes_inventario(id),
  observacion  text
);
alter table public.ajustes_inventario add constraint ajustes_conteo_fk foreign key (conteo_id) references public.conteos_fisicos(id);

create table public.conteo_registros (
  id             uuid primary key,
  conteo_id      uuid not null references public.conteos_fisicos(id),
  rollo_id       uuid references public.rollos(id),
  material_id    uuid references public.materiales(id),
  color_id       uuid references public.colores(id),
  ubicacion_id   uuid references public.ubicaciones(id),
  cantidad       numeric(14,3),        -- insumos (o metros/kilos medidos de un rollo, opcional)
  anula_id       uuid unique references public.conteo_registros(id),
  usuario_id     uuid default auth.uid(),
  dispositivo_id uuid references public.dispositivos(id),
  ocurrido_en    timestamptz not null default now(),
  recibido_en    timestamptz not null default now(),
  check (anula_id is not null or rollo_id is not null or (material_id is not null and cantidad is not null))
);
create index on public.conteo_registros (conteo_id);
select public.aplicar_estandar_evento('conteo_registros');

-- Diferencias del conteo contra el sistema (rollos: presencia; insumos: cantidad)
create or replace function public.diferencias_conteo(p_conteo uuid)
returns table (material_id uuid, color_id uuid, rollo_id uuid, ubicacion_id uuid, sistema numeric, contado numeric,
               diferencia numeric, observacion text)
language sql stable security definer set search_path = public as $$
  with c as (select * from conteos_fisicos where id = p_conteo),
  reg as (
    select r.* from conteo_registros r
    where r.conteo_id = p_conteo and r.anula_id is null
      and not exists (select 1 from conteo_registros a where a.anula_id = r.id)
  ),
  rollos_alcance as (
    select ro.* from rollos ro, c
    where ro.bodega_id = c.bodega_id and ro.estado <> 'agotado'
      and (c.ubicacion_id is null or ro.ubicacion_id = c.ubicacion_id)
      and c.alcance in ('telas','todo')
  ),
  rollos_contados as (select distinct on (rollo_id) rollo_id, ubicacion_id from reg where rollo_id is not null order by rollo_id, ocurrido_en desc),
  -- rollos del sistema no encontrados → faltante
  faltantes as (
    select ra.material_id, ra.color_id, ra.id as rollo_id, ra.ubicacion_id, cantidad_rollo(ra) as sistema, 0::numeric as contado,
           -cantidad_rollo(ra) as diferencia, 'Rollo no encontrado' as observacion
    from rollos_alcance ra where ra.id not in (select rollo_id from rollos_contados)
  ),
  -- rollos encontrados en otra ubicación → solo informativo (se corrige con un traslado)
  movidos(material_id, color_id, rollo_id, ubicacion_id, sistema, contado, diferencia, observacion) as (
    select ro.material_id, ro.color_id, ro.id, rc.ubicacion_id, cantidad_rollo(ro), cantidad_rollo(ro), 0::numeric,
           case when ro.estado = 'agotado' then 'Rollo agotado en el sistema pero encontrado'
                else 'Encontrado en otra ubicación: hacer traslado' end
    from rollos_contados rc join rollos ro on ro.id = rc.rollo_id
    where rc.ubicacion_id is distinct from ro.ubicacion_id or ro.estado = 'agotado'
  ),
  insumos_sistema as (
    select s.material_id, s.color_id, s.ubicacion_id, s.fisico
    from saldos_inventario s join materiales m on m.id = s.material_id, c
    where m.tipo = 'insumo' and s.bodega_id = c.bodega_id and c.alcance in ('insumos','todo')
      and (c.ubicacion_id is null or s.ubicacion_id = c.ubicacion_id) and s.fisico <> 0
  ),
  insumos_contados as (
    select reg.material_id, reg.color_id, reg.ubicacion_id, sum(reg.cantidad) as contado
    from reg join materiales m on m.id = reg.material_id
    where reg.rollo_id is null and m.tipo = 'insumo' group by 1, 2, 3
  ),
  insumos(material_id, color_id, rollo_id, ubicacion_id, sistema, contado, diferencia, observacion) as (
    select coalesce(s.material_id, k.material_id), coalesce(s.color_id, k.color_id), null::uuid,
           coalesce(s.ubicacion_id, k.ubicacion_id), coalesce(s.fisico, 0), coalesce(k.contado, 0),
           coalesce(k.contado, 0) - coalesce(s.fisico, 0), null::text
    from insumos_sistema s
    full join insumos_contados k on k.material_id = s.material_id and k.color_id is not distinct from s.color_id
                                and k.ubicacion_id is not distinct from s.ubicacion_id
  )
  select * from faltantes
  union all select * from movidos
  union all select * from insumos where diferencia <> 0
$$;

-- Cierra el conteo y genera el ajuste (queda "enviado", por aprobar)
create or replace function public.cerrar_conteo(p_conteo uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  c conteos_fisicos;
  v_ajuste uuid;
begin
  perform exigir_permiso('inventario', 'editar');
  select * into c from conteos_fisicos where id = p_conteo for update;
  perform set_config('app.cambio_ajuste', 'si', true);
  if c.estado <> 'abierto' then raise exception 'El conteo % no está abierto', c.consecutivo; end if;

  if exists (select 1 from diferencias_conteo(p_conteo) where diferencia <> 0) then
    insert into ajustes_inventario (motivo, origen, conteo_id)
    values ('Diferencias del conteo físico ' || c.consecutivo, 'conteo', p_conteo)
    returning id into v_ajuste;
    insert into ajuste_lineas (ajuste_id, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos, costo_unitario, observacion)
    select v_ajuste, d.material_id, d.color_id, d.rollo_id, c.bodega_id, d.ubicacion_id, d.diferencia,
           case when d.rollo_id is not null then -ro.metros_saldo end,
           case when d.rollo_id is not null then -ro.kilos_saldo end,
           coalesce(ro.costo_unitario, s.costo_promedio), d.observacion
    from diferencias_conteo(p_conteo) d
    left join rollos ro on ro.id = d.rollo_id
    left join saldos_inventario s on d.rollo_id is null and s.material_id = d.material_id
         and s.color_id is not distinct from d.color_id and s.bodega_id = c.bodega_id
         and s.ubicacion_id is not distinct from d.ubicacion_id
    where d.diferencia <> 0;
    update ajustes_inventario set estado = 'enviado' where id = v_ajuste;
    update conteos_fisicos set estado = 'cerrado', cerrado_por = auth.uid(), cerrado_en = now(), ajuste_id = v_ajuste where id = p_conteo;
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
    values ('ajuste_por_aprobar', 'media', 'ajustes_inventario', v_ajuste::text,
            format('El conteo %s tiene diferencias: ajuste por aprobar', c.consecutivo));
  else
    update conteos_fisicos set estado = 'ajustado', cerrado_por = auth.uid(), cerrado_en = now() where id = p_conteo;
  end if;
  return v_ajuste;
end $$;

-- ---------------------------------------------------------------------
-- Impresoras, plantillas ZPL y registro de impresiones
-- ---------------------------------------------------------------------
create table public.impresoras (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  modelo        text,
  conexion      text not null default 'tcp' check (conexion in ('tcp','bluetooth','browser_print')),
  ip            inet,
  puerto        int not null default 9100,
  mac_bluetooth text,
  dpi           int not null default 203,
  material      text not null default 'termico_directo' check (material in ('termico_directo','transferencia','sintetico')),
  activo        boolean not null default true,
  check (conexion <> 'tcp' or ip is not null)
);
alter table public.estaciones add column impresora_id uuid references public.impresoras(id);

create table public.plantillas_etiqueta (
  id      uuid primary key default gen_random_uuid(),
  tipo    text not null check (tipo in ('paquete','juego','rollo','ubicacion','maquina','producto_terminado','carnet')),
  tamano  text not null check (tamano in ('50x30','100x50')),
  nombre  text not null,
  zpl     text not null check (zpl like '%^XA%' and zpl like '%^XZ%' and zpl like '%^CI28%'),
  version int  not null default 1,
  activa  boolean not null default true
);
create unique index plantilla_activa_por_tipo on public.plantillas_etiqueta (tipo) where activa;

-- Cada cambio del ZPL sube la versión (la impresión registra con qué versión salió)
create or replace function public.fn_version_plantilla() returns trigger
language plpgsql as $$
begin
  if new.zpl is distinct from old.zpl then new.version := old.version + 1; end if;
  return new;
end $$;
create trigger plantillas_version before update on public.plantillas_etiqueta
  for each row execute function public.fn_version_plantilla();

create table public.trabajos_impresion (
  id                uuid primary key,
  impresora_id      uuid references public.impresoras(id),
  plantilla_id      uuid references public.plantillas_etiqueta(id),
  plantilla_version int,
  entidad           text not null,           -- rollos, ubicaciones…
  entidad_id        uuid,
  codigo            text not null,
  medio             text not null default 'tcp' check (medio in ('tcp','bluetooth','browser_print','pdf')),
  es_reimpresion    boolean not null default false,
  motivo            text,
  estado_final      text not null check (estado_final in ('enviado','error')),
  intentos          int not null default 1,
  error             text,
  usuario_id        uuid default auth.uid(),
  dispositivo_id    uuid references public.dispositivos(id),
  ocurrido_en       timestamptz not null default now(),
  recibido_en       timestamptz not null default now(),
  check (not es_reimpresion or coalesce(trim(motivo), '') <> '')
);
create index on public.trabajos_impresion (entidad, entidad_id);
select public.aplicar_estandar_evento('trabajos_impresion');

-- ---------------------------------------------------------------------
-- Estándar de maestros/documentos (auditoría, actualizado, RLS)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['categorias_material','materiales','rollos','ajustes_inventario','ajuste_lineas',
                           'recepciones','recepcion_lineas','conteos_fisicos','impresoras','plantillas_etiqueta']
  loop
    perform public.aplicar_estandar_maestro(t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Vistas de consulta
-- ---------------------------------------------------------------------
-- Kardex con saldo acumulado por material + color + bodega
create view public.kardex with (security_invoker = true) as
select m.*,
       sum(m.cantidad) over (partition by m.material_id, m.color_id, m.bodega_id
                             order by m.ocurrido_en, m.recibido_en, m.id) as saldo_acumulado
from public.movimientos_inventario m
where m.afecta = 'fisico';

-- Saldos totales por material y color (todas las ubicaciones de cada bodega)
create view public.saldos_por_material with (security_invoker = true) as
select s.material_id, s.color_id, s.bodega_id,
       sum(s.fisico) as fisico, sum(s.reservado) as reservado, sum(s.disponible) as disponible, sum(s.kilos) as kilos,
       max(s.costo_promedio) as costo_promedio
from public.saldos_inventario s
group by s.material_id, s.color_id, s.bodega_id;
