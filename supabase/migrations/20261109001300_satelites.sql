-- =====================================================================
-- Fase 6 (segunda parte) · Migración 13: procesos externos y satélites.
-- Remisión de salida (lo que se envía: juegos/paquetes e insumos) y
-- devolución (lo que vuelve, con buenas, segundas y faltantes: regla 5),
-- tarifas por satélite y cuentas por pagar. El satélite ve solo lo suyo.
-- =====================================================================

insert into public.consecutivos (tipo, prefijo) values ('REM','REM'), ('DEV','DEV'), ('CPS','CPS') on conflict (tipo) do nothing;

-- ---------------------------------------------------------------------
-- Tarifas por satélite (precio por prenda; por referencia o general del proceso)
-- ---------------------------------------------------------------------
create table public.tarifas_satelite (
  id            uuid primary key default gen_random_uuid(),
  satelite_id   uuid not null references public.satelites(id),
  proceso       text not null references public.procesos(codigo),
  referencia_id uuid references public.referencias(id),         -- null = todas las referencias
  valor_unidad  numeric(14,2) not null check (valor_unidad >= 0),
  vigente_desde date not null default (now() at time zone 'America/Bogota')::date,
  observacion   text
);
create index on public.tarifas_satelite (satelite_id, proceso, vigente_desde desc);

create or replace function public.tarifa_satelite(p_satelite uuid, p_proceso text, p_referencia uuid, p_fecha date default (now() at time zone 'America/Bogota')::date)
returns numeric language sql stable security definer set search_path = public as $$
  select valor_unidad from tarifas_satelite
  where satelite_id = p_satelite and proceso = p_proceso and (referencia_id = p_referencia or referencia_id is null) and vigente_desde <= p_fecha
  order by (referencia_id is not null) desc, vigente_desde desc, id limit 1
$$;

-- ---------------------------------------------------------------------
-- Remisiones
-- ---------------------------------------------------------------------
create table public.remisiones (
  id                 uuid primary key default gen_random_uuid(),
  consecutivo        text not null unique,
  tipo               text not null check (tipo in ('salida','entrada')),
  satelite_id        uuid not null references public.satelites(id),
  proceso            text not null references public.procesos(codigo),
  remision_salida_id uuid references public.remisiones(id),        -- en las devoluciones
  fecha              date not null default (now() at time zone 'America/Bogota')::date,
  fecha_compromiso   date,
  estado             text not null default 'enviada' check (estado in ('enviada','parcial','cerrada','anulada','registrada')),
  recibida_satelite  timestamptz,                                  -- el satélite confirmó que le llegó
  nota_satelite      text,
  observacion        text,
  motivo_anulacion   text,
  check ((tipo = 'entrada') = (remision_salida_id is not null))
);
create index on public.remisiones (satelite_id, estado);

create table public.remision_unidades (
  id           uuid primary key default gen_random_uuid(),
  remision_id  uuid not null references public.remisiones(id),
  paquete_id   uuid references public.paquetes(id),
  juego_id     uuid references public.juegos(id),
  op_id        uuid not null references public.ordenes_produccion(id),
  cantidad     int not null check (cantidad > 0),
  buenas       int,
  segundas     int,
  faltantes    int,
  check ((paquete_id is null) <> (juego_id is null)),
  check (buenas is null or buenas + coalesce(segundas, 0) + coalesce(faltantes, 0) = cantidad)
);
create index on public.remision_unidades (remision_id);
create index on public.remision_unidades (paquete_id);
create index on public.remision_unidades (juego_id);

create table public.remision_insumos (
  id              uuid primary key default gen_random_uuid(),
  remision_id     uuid not null references public.remisiones(id),
  op_id           uuid not null references public.ordenes_produccion(id),
  material_id     uuid not null references public.materiales(id),
  color_id        uuid references public.colores(id),
  bodega_id       uuid not null references public.bodegas(id),
  cantidad        numeric(14,3) not null check (cantidad > 0),
  movimiento_id   uuid references public.movimientos_inventario(id)
);

-- ---------------------------------------------------------------------
-- Cuentas por pagar a satélites (una por devolución y OP)
-- ---------------------------------------------------------------------
create table public.cuentas_pagar_satelite (
  id             uuid primary key default gen_random_uuid(),
  consecutivo    text not null unique default public.siguiente_consecutivo('CPS'),
  satelite_id    uuid not null references public.satelites(id),
  op_id          uuid not null references public.ordenes_produccion(id),
  remision_id    uuid not null references public.remisiones(id),   -- la devolución
  proceso        text not null references public.procesos(codigo),
  cantidad       int not null,                                     -- prendas buenas devueltas
  valor_unidad   numeric(14,2),
  valor          numeric(14,2),
  estado         text not null default 'pendiente' check (estado in ('pendiente','aprobada','pagada','anulada')),
  aprobada_por   uuid references public.perfiles(id),
  aprobada_en    timestamptz,
  pagada_en      timestamptz,
  referencia_pago text,
  alegra_id      text,
  observacion    text
);
create index on public.cuentas_pagar_satelite (satelite_id, estado);

-- Las remisiones y cuentas solo cambian por sus funciones
create or replace function public.fn_satelite_protegido() returns trigger
language plpgsql as $$
begin
  if current_setting('app.satelite_sistema', true) = 'si' or public.es_conexion_directa() then return coalesce(new, old); end if;
  raise exception 'Las remisiones y cuentas de satélite solo cambian con sus funciones';
end $$;
create trigger remisiones_protegida before update or delete on public.remisiones for each row execute function public.fn_satelite_protegido();
create trigger remision_unidades_protegida before update or delete on public.remision_unidades for each row execute function public.fn_satelite_protegido();
create trigger remision_insumos_protegida before update or delete on public.remision_insumos for each row execute function public.fn_satelite_protegido();
create trigger cuentas_satelite_protegida before update or delete on public.cuentas_pagar_satelite for each row execute function public.fn_satelite_protegido();

-- ---------------------------------------------------------------------
-- Salida: juegos/paquetes (y, si se quiere, insumos) para un satélite
-- p_insumos: [{op_id, material_id, color_id, bodega_id, cantidad}]
-- ---------------------------------------------------------------------
create or replace function public.crear_remision_salida(p_satelite uuid, p_proceso text, p_unidades uuid[], p_insumos jsonb default '[]',
                                                        p_observacion text default null, p_fecha_compromiso date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  s satelites;
  u unidades_trabajo;
  v_id uuid;
  x record;
  v_mov uuid;
  v_unidad text;
begin
  perform exigir_permiso('procesos_externos', 'editar');
  select * into s from satelites where id = p_satelite and activo;
  if s.id is null then raise exception 'Satélite inexistente o inactivo'; end if;
  if not (p_proceso = any(s.procesos)) then
    raise exception '% no hace %', s.nombre, (select nombre from procesos where codigo = p_proceso);
  end if;
  if coalesce(cardinality(p_unidades), 0) = 0 then raise exception 'Elija los juegos o paquetes que se envían'; end if;

  perform set_config('app.satelite_sistema', 'si', true);
  insert into remisiones (consecutivo, tipo, satelite_id, proceso, fecha_compromiso, observacion)
  values (siguiente_consecutivo('REM'), 'salida', p_satelite, p_proceso, p_fecha_compromiso, p_observacion) returning id into v_id;

  foreach v_unidad in array (select array_agg(distinct un.v) from unnest(p_unidades) un(v)) loop
    u := buscar_unidad(null, v_unidad::uuid);
    if u.id is null then raise exception 'Hay un juego o paquete que no existe'; end if;
    if exists (select 1 from remision_unidades ru join remisiones r on r.id = ru.remision_id
               where (ru.paquete_id = u.id or ru.juego_id = u.id) and r.tipo = 'salida' and r.estado in ('enviada','parcial') and ru.buenas is null) then
      raise exception '% ya está en otra remisión sin devolver', u.codigo;
    end if;
    if (select modalidad from op_procesos where op_id = u.op_id and proceso = p_proceso) = 'interno' then
      raise exception 'En la ruta de la OP de % el proceso % es interno', u.codigo, p_proceso;
    end if;
    -- entra al proceso en el satélite (mismas validaciones que en planta)
    perform aplicar_evento_unidad(gen_random_uuid(), 'recepcion', u, p_proceso, null, null, null, null, null,
                                  'Remisión ' || (select consecutivo from remisiones where id = v_id), null, null, now(), now(), p_satelite);
    insert into remision_unidades (remision_id, paquete_id, juego_id, op_id, cantidad)
    values (v_id, case when u.tipo = 'paquete' then u.id end, case when u.tipo = 'juego' then u.id end, u.op_id, u.cantidad_actual);
  end loop;

  -- insumos: salen del inventario con la OP (regla 1)
  for x in select (e->>'op_id')::uuid as op_id, (e->>'material_id')::uuid as material_id, nullif(e->>'color_id', '')::uuid as color_id,
                  (e->>'bodega_id')::uuid as bodega_id, (e->>'cantidad')::numeric as cantidad
           from jsonb_array_elements(coalesce(p_insumos, '[]')) e loop
    if x.cantidad is null or x.cantidad <= 0 then raise exception 'Cantidad de insumo inválida'; end if;
    insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, cantidad, costo_unitario, op_id, documento_tipo, documento_id, motivo)
    values ('envio_satelite', x.material_id, x.color_id, x.bodega_id, -x.cantidad,
            (select costo_promedio from saldos_por_material where material_id = x.material_id and color_id is not distinct from x.color_id and bodega_id = x.bodega_id),
            x.op_id, 'remision', (select consecutivo from remisiones where id = v_id), 'Enviado a ' || s.nombre)
    returning id into v_mov;
    insert into remision_insumos (remision_id, op_id, material_id, color_id, bodega_id, cantidad, movimiento_id)
    values (v_id, x.op_id, x.material_id, x.color_id, x.bodega_id, x.cantidad, v_mov);
  end loop;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Devolución (parcial o total): p_lineas = [{unidad_id, buenas, segundas, faltantes}]
-- Cada unidad sale del proceso con sus cantidades y sigue la ruta. Genera
-- la cuenta por pagar por OP (buenas × tarifa vigente).
-- ---------------------------------------------------------------------
create or replace function public.registrar_devolucion(p_salida uuid, p_lineas jsonb, p_observacion text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  sal remisiones;
  v_id uuid;
  l record;
  ru remision_unidades;
  u unidades_trabajo;
  c record;
  v_tarifa numeric;
begin
  perform exigir_permiso('procesos_externos', 'editar');
  select * into sal from remisiones where id = p_salida and tipo = 'salida' for update;
  if sal.id is null then raise exception 'Remisión de salida no encontrada'; end if;
  if sal.estado not in ('enviada','parcial') then raise exception 'La remisión % está %', sal.consecutivo, sal.estado; end if;
  if jsonb_array_length(coalesce(p_lineas, '[]')) = 0 then raise exception 'Registre al menos un juego o paquete devuelto'; end if;

  perform set_config('app.satelite_sistema', 'si', true);
  insert into remisiones (consecutivo, tipo, satelite_id, proceso, remision_salida_id, estado, observacion)
  values (siguiente_consecutivo('DEV'), 'entrada', sal.satelite_id, sal.proceso, sal.id, 'registrada', p_observacion) returning id into v_id;

  for l in select (e->>'unidad_id')::uuid as unidad_id, (e->>'buenas')::int as buenas, coalesce((e->>'segundas')::int, 0) as segundas,
                  coalesce((e->>'faltantes')::int, 0) as faltantes
           from jsonb_array_elements(p_lineas) e loop
    select * into ru from remision_unidades where remision_id = sal.id and (paquete_id = l.unidad_id or juego_id = l.unidad_id) for update;
    if ru.id is null then raise exception 'Ese juego o paquete no salió en la remisión %', sal.consecutivo; end if;
    if ru.buenas is not null then raise exception 'Ya se registró la devolución de ese juego o paquete'; end if;
    if l.buenas is null or l.buenas < 0 or l.segundas < 0 or l.faltantes < 0 or l.buenas + l.segundas + l.faltantes <> ru.cantidad then
      raise exception 'Las cantidades no cuadran: salieron %, buenas + segundas + faltantes = %', ru.cantidad,
        coalesce(l.buenas, 0) + l.segundas + l.faltantes;
    end if;
    u := buscar_unidad(null, l.unidad_id);
    perform aplicar_evento_unidad(gen_random_uuid(), 'entrega', u, sal.proceso, null, null, l.buenas, l.segundas, l.faltantes,
                                  'Devolución ' || (select consecutivo from remisiones where id = v_id), null, null, now(), now(), sal.satelite_id);
    update remision_unidades set buenas = l.buenas, segundas = l.segundas, faltantes = l.faltantes where id = ru.id;
    insert into remision_unidades (remision_id, paquete_id, juego_id, op_id, cantidad, buenas, segundas, faltantes)
    values (v_id, ru.paquete_id, ru.juego_id, ru.op_id, ru.cantidad, l.buenas, l.segundas, l.faltantes);
  end loop;

  update remisiones set estado = case when exists (select 1 from remision_unidades where remision_id = sal.id and buenas is null) then 'parcial' else 'cerrada' end
   where id = sal.id;

  -- cuenta por pagar por OP: se pagan las buenas
  for c in select ru2.op_id, sum(ru2.buenas)::int as buenas, o.referencia_id, o.consecutivo
           from remision_unidades ru2 join ordenes_produccion o on o.id = ru2.op_id
           where ru2.remision_id = v_id group by ru2.op_id, o.referencia_id, o.consecutivo loop
    v_tarifa := tarifa_satelite(sal.satelite_id, sal.proceso, c.referencia_id);
    insert into cuentas_pagar_satelite (satelite_id, op_id, remision_id, proceso, cantidad, valor_unidad, valor, observacion)
    values (sal.satelite_id, c.op_id, v_id, sal.proceso, c.buenas, v_tarifa, round(c.buenas * v_tarifa, 2),
            case when v_tarifa is null then 'Sin tarifa registrada para este satélite y proceso' end);
    if v_tarifa is null then
      insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
      values ('satelite_sin_tarifa', 'media', 'satelites', sal.satelite_id::text,
              format('%s: no hay tarifa de %s para %s; la cuenta quedó sin valor', (select nombre from satelites where id = sal.satelite_id),
                     (select nombre from procesos where codigo = sal.proceso), c.consecutivo));
    end if;
  end loop;
  return v_id;
end $$;

-- Anular una salida sin devoluciones: las unidades vuelven a esperar el proceso
-- y los insumos vuelven a la bodega (eventos inversos).
create or replace function public.anular_remision(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  r remisiones;
  e record;
  m movimientos_inventario;
begin
  perform exigir_permiso('procesos_externos', 'editar');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la anulación'; end if;
  select * into r from remisiones where id = p_id for update;
  if r.tipo <> 'salida' or r.estado <> 'enviada' then raise exception 'Solo se anula una remisión de salida sin devoluciones'; end if;
  perform set_config('app.satelite_sistema', 'si', true);
  perform set_config('app.op_sistema', 'si', true);
  for e in select ep.* from eventos_proceso ep join remision_unidades ru on ru.remision_id = p_id and (ep.paquete_id = ru.paquete_id or ep.juego_id = ru.juego_id)
           where ep.tipo = 'recepcion' and ep.proceso = r.proceso and ep.satelite_id = r.satelite_id
             and not exists (select 1 from eventos_proceso a where a.anula_id = ep.id) loop
    insert into eventos_proceso (op_id, proceso, tipo, paquete_id, juego_id, satelite_id, entra, buenas, observacion, anula_id)
    values (e.op_id, e.proceso, 'anulacion', e.paquete_id, e.juego_id, e.satelite_id, e.entra, e.buenas, 'Remisión anulada: ' || p_motivo, e.id);
  end loop;
  update paquetes set estado = 'en_espera' where id in (select paquete_id from remision_unidades where remision_id = p_id);
  update juegos set estado = 'en_espera' where id in (select juego_id from remision_unidades where remision_id = p_id);
  for m in select mi.* from movimientos_inventario mi join remision_insumos ri on ri.movimiento_id = mi.id where ri.remision_id = p_id loop
    insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, costo_unitario, op_id, documento_tipo, documento_id, motivo, anula_id)
    values ('anulacion', m.afecta, m.material_id, m.color_id, m.bodega_id, -m.cantidad, m.costo_unitario, m.op_id, 'remision', r.consecutivo,
            'Remisión anulada: ' || p_motivo, m.id);
  end loop;
  update remisiones set estado = 'anulada', motivo_anulacion = trim(p_motivo) where id = p_id;
end $$;

-- El satélite confirma que le llegó la remisión (desde su panel)
create or replace function public.confirmar_recibido_satelite(p_id uuid, p_nota text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r remisiones;
begin
  select * into r from remisiones where id = p_id;
  if r.id is null or r.tipo <> 'salida' then raise exception 'Remisión no encontrada'; end if;
  if r.satelite_id is distinct from (select satelite_id from perfiles where id = auth.uid()) and not public.puede('procesos_externos', 'editar') then
    raise exception 'Esta remisión no es de su taller' using errcode = '42501';
  end if;
  if r.estado = 'anulada' then raise exception 'La remisión está anulada'; end if;
  perform set_config('app.satelite_sistema', 'si', true);
  update remisiones set recibida_satelite = coalesce(recibida_satelite, now()), nota_satelite = coalesce(nullif(trim(p_nota), ''), nota_satelite) where id = p_id;
end $$;

-- Cuentas por pagar: Costos aprueba; luego se marca pagada (la exportación a Alegra llega en la Fase 11)
create or replace function public.decidir_cuenta_satelite(p_id uuid, p_accion text, p_dato text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c cuentas_pagar_satelite;
begin
  if not (public.puede('costos', 'aprobar') or public.es_conexion_directa()) then
    raise exception 'Solo Costos aprueba y paga cuentas de satélites' using errcode = '42501';
  end if;
  select * into c from cuentas_pagar_satelite where id = p_id for update;
  perform set_config('app.satelite_sistema', 'si', true);
  if p_accion = 'valor' then
    if c.estado <> 'pendiente' then raise exception 'Solo se corrige el valor de una cuenta pendiente'; end if;
    update cuentas_pagar_satelite set valor_unidad = p_dato::numeric, valor = round(cantidad * p_dato::numeric, 2), observacion = null where id = p_id;
  elsif p_accion = 'aprobar' then
    if c.estado <> 'pendiente' then raise exception 'La cuenta % ya está %', c.consecutivo, c.estado; end if;
    if c.valor is null then raise exception 'La cuenta % no tiene valor: registre la tarifa o corrija el valor', c.consecutivo; end if;
    update cuentas_pagar_satelite set estado = 'aprobada', aprobada_por = auth.uid(), aprobada_en = now() where id = p_id;
  elsif p_accion = 'pagar' then
    if c.estado <> 'aprobada' then raise exception 'Primero se aprueba la cuenta %', c.consecutivo; end if;
    update cuentas_pagar_satelite set estado = 'pagada', pagada_en = now(), referencia_pago = p_dato where id = p_id;
  elsif p_accion = 'anular' then
    if c.estado = 'pagada' then raise exception 'Una cuenta pagada no se anula'; end if;
    if coalesce(trim(p_dato), '') = '' then raise exception 'Escriba el motivo'; end if;
    update cuentas_pagar_satelite set estado = 'anulada', observacion = 'Anulada: ' || p_dato where id = p_id;
  else
    raise exception 'Acción inválida';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Estándar y RLS: internos ven todo; el satélite solo lo suyo
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['tarifas_satelite','remisiones','remision_unidades','remision_insumos','cuentas_pagar_satelite']
  loop perform public.aplicar_estandar_maestro(t); end loop;
end $$;

create or replace function public.mi_satelite() returns uuid
language sql stable security definer set search_path = public as $$
  select satelite_id from perfiles where id = auth.uid()
$$;

create policy remisiones_leer on public.remisiones for select to authenticated
  using (public.es_interno() or satelite_id = public.mi_satelite());
create policy remision_unidades_leer on public.remision_unidades for select to authenticated
  using (public.es_interno() or exists (select 1 from public.remisiones r where r.id = remision_id and r.satelite_id = public.mi_satelite()));
create policy remision_insumos_leer on public.remision_insumos for select to authenticated
  using (public.es_interno() or exists (select 1 from public.remisiones r where r.id = remision_id and r.satelite_id = public.mi_satelite()));
create policy cuentas_satelite_leer on public.cuentas_pagar_satelite for select to authenticated
  using (public.puede('costos', 'ver') or public.puede('procesos_externos', 'editar') or satelite_id = public.mi_satelite());
create policy tarifas_leer on public.tarifas_satelite for select to authenticated
  using (public.puede('costos', 'ver') or public.puede('procesos_externos', 'ver') and public.es_interno() or satelite_id = public.mi_satelite());
create policy tarifas_insertar on public.tarifas_satelite for insert to authenticated with check (public.puede('costos', 'editar'));

-- El satélite ve lo que necesita de lo que le enviaron (paquetes, juegos, OP, referencia)
create policy paquetes_leer_satelite on public.paquetes for select to authenticated
  using (exists (select 1 from public.remision_unidades ru join public.remisiones r on r.id = ru.remision_id
                 where ru.paquete_id = paquetes.id and r.satelite_id = public.mi_satelite()));
create policy juegos_leer_satelite on public.juegos for select to authenticated
  using (exists (select 1 from public.remision_unidades ru join public.remisiones r on r.id = ru.remision_id
                 where ru.juego_id = juegos.id and r.satelite_id = public.mi_satelite()));
create policy op_leer_satelite on public.ordenes_produccion for select to authenticated
  using (exists (select 1 from public.remision_unidades ru join public.remisiones r on r.id = ru.remision_id
                 where ru.op_id = ordenes_produccion.id and r.satelite_id = public.mi_satelite()));
create policy referencias_leer_satelite on public.referencias for select to authenticated
  using (exists (select 1 from public.ordenes_produccion o join public.remision_unidades ru on ru.op_id = o.id
                 join public.remisiones r on r.id = ru.remision_id
                 where o.referencia_id = referencias.id and r.satelite_id = public.mi_satelite()));
create policy materiales_leer_satelite on public.materiales for select to authenticated
  using (exists (select 1 from public.remision_insumos ri join public.remisiones r on r.id = ri.remision_id
                 where ri.material_id = materiales.id and r.satelite_id = public.mi_satelite()));
