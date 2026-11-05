-- =====================================================================
-- Fase 7 · Migración 14: células y turnos (capacidad), programación de
-- planta (cola por célula, Gantt, carga vs capacidad, fecha posible de
-- entrega) y balanceo de célula (publicado a las tablets).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Capacidad
-- ---------------------------------------------------------------------
alter table public.turnos add column minutos_pausa int not null default 0 check (minutos_pausa >= 0);
alter table public.celulas
  add column dias_laborales      int[] not null default '{1,2,3,4,5}',        -- 1 = lunes … 7 = domingo
  add column eficiencia_planeada numeric(5,2) not null default 80 check (eficiencia_planeada > 0 and eficiencia_planeada <= 150),
  add column operarios_planeados int check (operarios_planeados >= 0);         -- null = los empleados activos de la célula

create or replace function public.hoy_bogota() returns date language sql stable as $$ select (now() at time zone 'America/Bogota')::date $$;

-- Minutos de un turno (fin − inicio − pausa)
create or replace function public.minutos_turno(p_turno uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(0, extract(epoch from (hora_fin - hora_inicio)) / 60
                       + case when cruza_medianoche or hora_fin <= hora_inicio then 1440 else 0 end - minutos_pausa)
  from turnos where id = p_turno
$$;

create or replace function public.operarios_celula(p_celula uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(c.operarios_planeados, (select count(*)::int from empleados e where e.celula_id = c.id and e.activo))
  from celulas c where c.id = p_celula
$$;

-- Minutos-operario disponibles de una célula en un día (0 en festivos y días no laborales)
create or replace function public.capacidad_celula(p_celula uuid, p_fecha date) returns numeric
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from festivos where fecha = p_fecha) or not (extract(isodow from p_fecha)::int = any(c.dias_laborales)) then 0
              else coalesce(minutos_turno(c.turno_id), 0) * operarios_celula(c.id) end
  from celulas c where c.id = p_celula
$$;

-- ---------------------------------------------------------------------
-- Programación: cola de OP por célula y proceso
-- ---------------------------------------------------------------------
create table public.programacion (
  id                 uuid primary key default gen_random_uuid(),
  op_id              uuid not null references public.ordenes_produccion(id),
  proceso            text not null references public.procesos(codigo),
  celula_id          uuid not null references public.celulas(id),
  orden              int not null,
  minutos_manual     numeric(12,1) check (minutos_manual > 0),   -- si el proceso no tiene SAM en la ficha
  minutos_requeridos numeric(12,1),
  inicio_plan        date,
  fin_plan           date,
  unique (op_id, proceso)
);
create index on public.programacion (celula_id, orden);

-- Minutos que le faltan a una OP en un proceso: prendas pendientes × SAM del proceso / eficiencia
create or replace function public.minutos_pendientes(p_op uuid, p_proceso text, p_eficiencia numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select round(greatest(0, o.cantidad_total - coalesce(p.buenas, 0))
               * coalesce((select sum(fo.sam * fo.repeticiones) from ficha_operaciones fo
                           where fo.ficha_id = o.ficha_version_id and fo.proceso = p_proceso and fo.agrega_minutos_sam), 0)
               / (p_eficiencia / 100), 1)
  from ordenes_produccion o left join op_procesos p on p.op_id = o.id and p.proceso = p_proceso
  where o.id = p_op
$$;

-- Recorre la cola de la célula día por día con su capacidad. Con p_escribir guarda
-- inicio y fin de cada OP. p_extra: minutos de una OP imaginaria al final (fecha posible).
-- Devuelve {fin_extra, dias: [{fecha, capacidad, carga}]}.
create or replace function public.programar_cola(p_celula uuid, p_escribir boolean default true, p_extra numeric default null, p_dias int default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c celulas;
  r record;
  v_dia date := hoy_bogota();
  v_resto numeric;
  v_cap numeric;
  v_need numeric;
  v_ini date;
  v_guard int;
  v_carga jsonb := '{}';
  v_fin_extra date;
  v_dias jsonb := '[]';
  d date;
begin
  select * into c from celulas where id = p_celula;
  if c.id is null then raise exception 'Célula no encontrada'; end if;
  v_cap := capacidad_celula(p_celula, v_dia);
  v_resto := v_cap;

  for r in
    select pr.*, o.estado as estado_op, coalesce(op.estado, 'pendiente') as estado_proceso
    from programacion pr join ordenes_produccion o on o.id = pr.op_id
    left join op_procesos op on op.op_id = pr.op_id and op.proceso = pr.proceso
    where pr.celula_id = p_celula order by pr.orden
  loop
    if r.estado_op not in ('planeada','en_proceso') or r.estado_proceso = 'terminado' then
      if p_escribir then update programacion set minutos_requeridos = 0, inicio_plan = null, fin_plan = null where id = r.id; end if;
      continue;
    end if;
    v_need := coalesce(r.minutos_manual, minutos_pendientes(r.op_id, r.proceso, c.eficiencia_planeada));
    v_ini := null;
    v_guard := 0;
    loop
      -- avanza a un día con capacidad
      while v_resto <= 0.0001 and v_guard < 730 loop
        v_dia := v_dia + 1; v_guard := v_guard + 1;
        v_cap := capacidad_celula(p_celula, v_dia); v_resto := v_cap;
      end loop;
      exit when v_guard >= 730;
      v_ini := coalesce(v_ini, v_dia);
      if v_need <= v_resto then
        v_carga := jsonb_set(v_carga, array[v_dia::text], to_jsonb(coalesce((v_carga ->> v_dia::text)::numeric, 0) + v_need));
        v_resto := v_resto - v_need; v_need := 0;
        exit;
      end if;
      v_carga := jsonb_set(v_carga, array[v_dia::text], to_jsonb(coalesce((v_carga ->> v_dia::text)::numeric, 0) + v_resto));
      v_need := v_need - v_resto; v_resto := 0;
    end loop;
    if p_escribir then
      update programacion set minutos_requeridos = coalesce(r.minutos_manual, minutos_pendientes(r.op_id, r.proceso, c.eficiencia_planeada)),
             inicio_plan = coalesce(v_ini, hoy_bogota()), fin_plan = case when v_guard >= 730 then null else v_dia end
       where id = r.id;
    end if;
  end loop;

  if p_extra is not null then
    v_need := p_extra; v_guard := 0;
    loop
      while v_resto <= 0.0001 and v_guard < 730 loop
        v_dia := v_dia + 1; v_guard := v_guard + 1;
        v_cap := capacidad_celula(p_celula, v_dia); v_resto := v_cap;
      end loop;
      exit when v_guard >= 730;
      if v_need <= v_resto then v_resto := v_resto - v_need; v_need := 0; exit; end if;
      v_need := v_need - v_resto; v_resto := 0;
    end loop;
    v_fin_extra := case when v_guard >= 730 then null else v_dia end;
  end if;

  for d in select generate_series(hoy_bogota(), hoy_bogota() + p_dias - 1, interval '1 day')::date loop
    v_dias := v_dias || jsonb_build_object('fecha', d, 'capacidad', capacidad_celula(p_celula, d), 'carga', round(coalesce((v_carga ->> d::text)::numeric, 0), 1));
  end loop;
  return jsonb_build_object('fin_extra', v_fin_extra, 'dias', v_dias);
end $$;

create or replace function public.programar_op(p_op uuid, p_proceso text, p_celula uuid, p_minutos_manual numeric default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_viejo uuid;
begin
  perform exigir_permiso('programacion', 'editar');
  if (select proceso from celulas where id = p_celula) is distinct from p_proceso then
    raise exception 'La célula no es de %', (select nombre from procesos where codigo = p_proceso);
  end if;
  if not exists (select 1 from op_procesos where op_id = p_op and proceso = p_proceso) then
    raise exception 'La ruta de la OP no tiene %', (select nombre from procesos where codigo = p_proceso);
  end if;
  select celula_id into v_viejo from programacion where op_id = p_op and proceso = p_proceso;
  insert into programacion (op_id, proceso, celula_id, orden, minutos_manual)
  values (p_op, p_proceso, p_celula, coalesce((select max(orden) from programacion where celula_id = p_celula), 0) + 1, p_minutos_manual)
  on conflict (op_id, proceso) do update set celula_id = excluded.celula_id, orden = excluded.orden, minutos_manual = excluded.minutos_manual
  returning id into v_id;
  perform programar_cola(p_celula);
  if v_viejo is not null and v_viejo <> p_celula then perform programar_cola(v_viejo); end if;
  return v_id;
end $$;

create or replace function public.mover_programacion(p_id uuid, p_direccion int) returns void
language plpgsql security definer set search_path = public as $$
declare a programacion; b programacion;
begin
  perform exigir_permiso('programacion', 'editar');
  select * into a from programacion where id = p_id;
  select * into b from programacion where celula_id = a.celula_id
    and case when p_direccion < 0 then orden < a.orden else orden > a.orden end
    order by case when p_direccion < 0 then -orden else orden end limit 1;
  if b.id is null then return; end if;
  update programacion set orden = b.orden where id = a.id;
  update programacion set orden = a.orden where id = b.id;
  perform programar_cola(a.celula_id);
end $$;

create or replace function public.quitar_programacion(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_cel uuid;
begin
  perform exigir_permiso('programacion', 'editar');
  delete from programacion where id = p_id returning celula_id into v_cel;
  if v_cel is not null then perform programar_cola(v_cel); end if;
end $$;

-- Recalcula todas las colas (p. ej. cada mañana o después de cambiar capacidades)
create or replace function public.reprogramar_todo() returns int
language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  perform exigir_permiso('programacion', 'editar');
  for c in select distinct celula_id from programacion loop perform programar_cola(c.celula_id); n := n + 1; end loop;
  return n;
end $$;

-- Fecha posible de entrega de una OP nueva en cada célula del proceso (sin guardar nada)
create or replace function public.fecha_posible(p_referencia uuid, p_cantidad int, p_proceso text default 'confeccion')
returns table (celula_id uuid, codigo text, nombre text, minutos numeric, fecha_fin date)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_sam numeric; c record;
begin
  if not (public.puede('programacion', 'ver') or public.puede('op', 'ver') or public.puede('pedidos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  select coalesce(sum(fo.sam * fo.repeticiones), 0) into v_sam
  from referencias r join ficha_operaciones fo on fo.ficha_id = r.version_vigente_id and fo.proceso = p_proceso and fo.agrega_minutos_sam
  where r.id = p_referencia;
  if v_sam = 0 then raise exception 'La referencia no tiene ficha aprobada con operaciones de %', p_proceso; end if;
  for c in select * from celulas where proceso = p_proceso and activo order by codigo loop
    celula_id := c.id; codigo := c.codigo; nombre := c.nombre;
    minutos := round(p_cantidad * v_sam / (c.eficiencia_planeada / 100), 1);
    fecha_fin := (programar_cola(c.id, false, minutos, 1) ->> 'fin_extra')::date;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Balanceo de célula
-- ---------------------------------------------------------------------
create table public.balanceos (
  id                     uuid primary key default gen_random_uuid(),
  op_id                  uuid not null references public.ordenes_produccion(id),
  celula_id              uuid not null references public.celulas(id),
  proceso                text not null default 'confeccion' references public.procesos(codigo),
  version                int not null default 1,
  operarios              int not null check (operarios > 0),
  eficiencia_objetivo    numeric(5,2) not null default 80 check (eficiencia_objetivo > 0),
  minutos_turno          numeric(6,1) not null check (minutos_turno > 0),
  tolerancia_pct         numeric(5,2) not null default 10,
  operacion_contadora_id uuid references public.ficha_operaciones(id),
  estado                 text not null default 'borrador' check (estado in ('borrador','publicado','reemplazado')),
  publicado_en           timestamptz,
  publicado_por          uuid references public.perfiles(id),
  observacion            text,
  unique (op_id, celula_id, version)
);
create unique index balanceo_publicado on public.balanceos (op_id, celula_id) where estado = 'publicado';

create table public.balanceo_puestos (
  id          uuid primary key default gen_random_uuid(),
  balanceo_id uuid not null references public.balanceos(id) on delete cascade,
  numero      int not null,
  empleado_id uuid references public.empleados(id),
  maquina_id  uuid references public.maquinas(id),
  maquinas    text[] not null default '{}',
  unique (balanceo_id, numero)
);

create table public.balanceo_asignaciones (
  id                 uuid primary key default gen_random_uuid(),
  balanceo_id        uuid not null references public.balanceos(id) on delete cascade,
  puesto_id          uuid not null references public.balanceo_puestos(id) on delete cascade,
  ficha_operacion_id uuid not null references public.ficha_operaciones(id),
  fraccion           numeric(6,4) not null check (fraccion > 0 and fraccion <= 1),
  minutos            numeric(10,4) not null
);
create index on public.balanceo_asignaciones (balanceo_id);

-- Solo un borrador se edita; uno publicado queda fijo (para cambiarlo se hace una versión nueva)
create or replace function public.fn_balanceo_editable() returns trigger
language plpgsql as $$
declare v_estado text;
begin
  if current_setting('app.balanceo_sistema', true) = 'si' or public.es_conexion_directa() then return coalesce(new, old); end if;
  raise exception 'El balanceo solo cambia con sus funciones';
end $$;
create trigger balanceos_editable before update or delete on public.balanceos for each row execute function public.fn_balanceo_editable();
create trigger balanceo_puestos_editable before insert or update or delete on public.balanceo_puestos for each row execute function public.fn_balanceo_editable();
create trigger balanceo_asignaciones_editable before insert or update or delete on public.balanceo_asignaciones for each row execute function public.fn_balanceo_editable();

-- Métricas (mismas fórmulas que lib/core/calculos/balanceo.dart; casos en test_vectores/balanceo)
create or replace function public.metricas_balanceo_calc(p_sam numeric, p_operarios int, p_eficiencia numeric, p_minutos_turno numeric,
                                                         p_cargas numeric[], p_pendientes int default null)
returns jsonb language plpgsql immutable as $$
declare
  e numeric := p_eficiencia / 100;
  v_ciclo numeric := case when p_operarios > 0 then p_sam / p_operarios else 0 end;
  v_meta numeric := case when p_sam > 0 then 60 * p_operarios * e / p_sam else 0 end;
  v_turno numeric := v_meta * p_minutos_turno / 60;
  v_max numeric := (select max(c) from unnest(p_cargas) c);
  v_prom numeric := (select avg(c) from unnest(p_cargas) c);
begin
  return jsonb_build_object(
    'sam_total', round(p_sam, 4), 'ciclo', round(v_ciclo, 4), 'meta_hora', round(v_meta, 2), 'meta_turno', round(v_turno, 1),
    'dias', case when p_pendientes is null or v_turno <= 0 then null else round(p_pendientes / v_turno, 2) end,
    'cargas', (select coalesce(jsonb_agg(round(c, 4) order by i), '[]') from unnest(p_cargas) with ordinality x(c, i)),
    'cuello', (select i from unnest(p_cargas) with ordinality x(c, i) where c = v_max order by i limit 1),
    'pct_balance', case when coalesce(v_max, 0) <= 0 then 0 else round(v_prom / v_max * 100, 1) end,
    'meta_hora_cuello', case when coalesce(v_max, 0) <= 0 then 0 else round(60 * e / v_max, 2) end);
end $$;

create or replace function public.metricas_balanceo(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select metricas_balanceo_calc(
    (select coalesce(sum(fo.sam * fo.repeticiones), 0) from ficha_operaciones fo
      where fo.ficha_id = o.ficha_version_id and fo.proceso = b.proceso and fo.agrega_minutos_sam),
    b.operarios, b.eficiencia_objetivo, b.minutos_turno,
    (select coalesce(array_agg(coalesce((select sum(a.minutos) from balanceo_asignaciones a where a.puesto_id = p.id), 0) order by p.numero), '{}')
      from balanceo_puestos p where p.balanceo_id = b.id),
    greatest(0, o.cantidad_total - coalesce((select buenas from op_procesos where op_id = o.id and proceso = b.proceso), 0))::int)
  from balanceos b join ordenes_produccion o on o.id = b.op_id where b.id = p_id
$$;

-- p = {id?, op_id, celula_id, operarios, eficiencia_objetivo, minutos_turno, tolerancia_pct, operacion_contadora_id, observacion,
--      puestos: [{numero, empleado_id, maquina_id, maquinas, asignaciones: [{ficha_operacion_id, fraccion}]}]}
-- Si el balanceo está publicado se crea una versión nueva en borrador.
create or replace function public.guardar_balanceo(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  b balanceos;
  o ordenes_produccion;
  v_id uuid;
  pu jsonb;
  a jsonb;
  v_puesto uuid;
  fo ficha_operaciones;
begin
  perform exigir_permiso('balanceo', 'editar');
  if nullif(p ->> 'id', '') is not null then select * into b from balanceos where id = (p ->> 'id')::uuid; end if;
  select * into o from ordenes_produccion where id = coalesce(b.op_id, (p ->> 'op_id')::uuid);
  if o.id is null then raise exception 'Elija la OP'; end if;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La % está %', o.consecutivo, replace(o.estado, '_', ' '); end if;
  perform set_config('app.balanceo_sistema', 'si', true);
  if b.id is null or b.estado <> 'borrador' then
    insert into balanceos (op_id, celula_id, proceso, version, operarios, eficiencia_objetivo, minutos_turno, tolerancia_pct, operacion_contadora_id, observacion)
    values (o.id, coalesce(b.celula_id, (p ->> 'celula_id')::uuid), coalesce(b.proceso, p ->> 'proceso', 'confeccion'),
            coalesce((select max(version) from balanceos where op_id = o.id and celula_id = coalesce(b.celula_id, (p ->> 'celula_id')::uuid)), 0) + 1,
            (p ->> 'operarios')::int, coalesce((p ->> 'eficiencia_objetivo')::numeric, 80), (p ->> 'minutos_turno')::numeric,
            coalesce((p ->> 'tolerancia_pct')::numeric, 10), nullif(p ->> 'operacion_contadora_id', '')::uuid, p ->> 'observacion')
    returning id into v_id;
  else
    v_id := b.id;
    update balanceos set operarios = (p ->> 'operarios')::int, eficiencia_objetivo = coalesce((p ->> 'eficiencia_objetivo')::numeric, eficiencia_objetivo),
           minutos_turno = (p ->> 'minutos_turno')::numeric, tolerancia_pct = coalesce((p ->> 'tolerancia_pct')::numeric, tolerancia_pct),
           operacion_contadora_id = nullif(p ->> 'operacion_contadora_id', '')::uuid, observacion = p ->> 'observacion'
     where id = v_id;
    delete from balanceo_puestos where balanceo_id = v_id;
  end if;
  if (select proceso from celulas where id = (select celula_id from balanceos where id = v_id)) is distinct from (select proceso from balanceos where id = v_id) then
    raise exception 'La célula no es de ese proceso';
  end if;

  for pu in select * from jsonb_array_elements(coalesce(p -> 'puestos', '[]')) loop
    insert into balanceo_puestos (balanceo_id, numero, empleado_id, maquina_id, maquinas)
    values (v_id, (pu ->> 'numero')::int, nullif(pu ->> 'empleado_id', '')::uuid, nullif(pu ->> 'maquina_id', '')::uuid,
            coalesce(array(select jsonb_array_elements_text(pu -> 'maquinas')), '{}'))
    returning id into v_puesto;
    for a in select * from jsonb_array_elements(coalesce(pu -> 'asignaciones', '[]')) loop
      select * into fo from ficha_operaciones where id = (a ->> 'ficha_operacion_id')::uuid;
      if fo.id is null or fo.ficha_id <> o.ficha_version_id then raise exception 'Hay una operación que no es de la ficha de la %', o.consecutivo; end if;
      insert into balanceo_asignaciones (balanceo_id, puesto_id, ficha_operacion_id, fraccion, minutos)
      values (v_id, v_puesto, fo.id, (a ->> 'fraccion')::numeric, round(fo.sam * fo.repeticiones * (a ->> 'fraccion')::numeric, 4));
    end loop;
  end loop;
  return v_id;
end $$;

create or replace function public.publicar_balanceo(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b balanceos;
  o ordenes_produccion;
  x record;
begin
  perform exigir_permiso('balanceo', 'editar');
  select * into b from balanceos where id = p_id for update;
  if b.estado <> 'borrador' then raise exception 'Solo se publica un borrador'; end if;
  select * into o from ordenes_produccion where id = b.op_id;
  for x in select fo.id, op.nombre, coalesce((select sum(a.fraccion) from balanceo_asignaciones a where a.balanceo_id = p_id and a.ficha_operacion_id = fo.id), 0) as f
           from ficha_operaciones fo join operaciones op on op.id = fo.operacion_id
           where fo.ficha_id = o.ficha_version_id and fo.proceso = b.proceso loop
    if abs(x.f - 1) > 0.002 then raise exception 'La operación "%" está asignada al % %%: debe sumar 100 %%', x.nombre, round(x.f * 100, 1); end if;
  end loop;
  if exists (select empleado_id from balanceo_puestos where balanceo_id = p_id and empleado_id is not null group by empleado_id having count(*) > 1) then
    raise exception 'Un operario está en dos puestos';
  end if;
  perform set_config('app.balanceo_sistema', 'si', true);
  update balanceos set estado = 'reemplazado' where op_id = b.op_id and celula_id = b.celula_id and estado = 'publicado';
  update balanceos set estado = 'publicado', publicado_en = now(), publicado_por = auth.uid() where id = p_id;
  return metricas_balanceo(p_id);
end $$;

create or replace function public.borrar_balanceo(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('balanceo', 'editar');
  if (select estado from balanceos where id = p_id) <> 'borrador' then raise exception 'Solo se borra un borrador'; end if;
  perform set_config('app.balanceo_sistema', 'si', true);
  delete from balanceos where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- RLS y publicación (las tablets reciben el balanceo publicado)
-- ---------------------------------------------------------------------
select public.aplicar_estandar_maestro('programacion');
select public.aplicar_estandar_maestro('balanceos');
select public.aplicar_estandar_maestro('balanceo_puestos');
select public.aplicar_estandar_maestro('balanceo_asignaciones');
do $$
declare t text;
begin
  foreach t in array array['programacion','balanceos','balanceo_puestos','balanceo_asignaciones'] loop
    execute format('create policy %I on public.%I for select to authenticated using (public.es_interno())', t || '_leer', t);
  end loop;
end $$;
-- células y turnos se editan en Programación (además de Configuración)
create policy celulas_editar_programacion on public.celulas for update to authenticated
  using (public.puede('programacion','editar')) with check (public.puede('programacion','editar'));
create policy turnos_editar_programacion on public.turnos for update to authenticated
  using (public.puede('programacion','editar')) with check (public.puede('programacion','editar'));

-- Mover un operario de célula (sin tocar el resto de su ficha de personal)
create or replace function public.asignar_celula(p_empleado uuid, p_celula uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.puede('programacion', 'editar') or public.puede('personal', 'editar')) then
    raise exception 'Sin permiso para cambiar operarios de célula' using errcode = '42501';
  end if;
  update empleados set celula_id = p_celula where id = p_empleado;
end $$;

alter publication powersync add table public.balanceos, public.balanceo_puestos, public.balanceo_asignaciones;
create policy festivos_insertar_programacion on public.festivos for insert to authenticated with check (public.puede('programacion','editar'));
create policy festivos_borrar_programacion on public.festivos for delete to authenticated using (public.puede('programacion','editar'));
