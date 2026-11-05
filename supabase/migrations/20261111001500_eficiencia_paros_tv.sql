-- =====================================================================
-- Fase 8 · Migración 15: tiempos improductivos (paros), eficiencia por
-- operario / célula / planta, incentivos por tramos y tableros de TV.
-- (La planta no paga a destajo: no hay liquidación de destajo.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Causas de paro (configurables) y paros (E)
-- ---------------------------------------------------------------------
create table public.causas_paro (
  id                    uuid primary key default gen_random_uuid(),
  codigo                text not null unique,
  nombre                text not null,
  visible_tablet        boolean not null default true,
  descuenta_operario    boolean not null default true,    -- no cuenta en contra de su eficiencia
  descuenta_nomina      boolean not null default false,
  descuenta_celula      boolean not null default true,    -- tampoco en la de la célula
  detiene_trabajo       boolean not null default true,    -- bloquea marcar mientras dura
  detiene_celula        boolean not null default false,   -- aplica a todos los operarios de la célula
  rol_validador         text,                             -- p. ej. 'mecanico': quién confirma el fin
  cuenta_para_validador boolean not null default false,
  minutos_definidos     int check (minutos_definidos > 0),-- p. ej. almuerzo: termina solo
  activa                boolean not null default true
);

create table public.paros (
  id             uuid primary key,                       -- generado en la tablet
  causa_id       uuid not null references public.causas_paro(id),
  empleado_id    uuid references public.empleados(id),   -- null = paro de toda la célula
  celula_id      uuid references public.celulas(id),
  estacion_id    uuid references public.estaciones(id),
  maquina_id     uuid references public.maquinas(id),
  observacion    text,
  dispositivo_id uuid references public.dispositivos(id),
  usuario_id     uuid default auth.uid(),
  inicio         timestamptz not null,
  recibido_en    timestamptz not null default now()
);
create index on public.paros (empleado_id, inicio);
create index on public.paros (celula_id, inicio);
select public.aplicar_estandar_evento('paros');

create table public.paro_eventos (
  id                    uuid primary key,
  paro_id               uuid not null references public.paros(id),
  tipo                  text not null check (tipo in ('fin','validacion','anulacion')),
  validador_empleado_id uuid references public.empleados(id),
  motivo                text,
  dispositivo_id        uuid references public.dispositivos(id),
  usuario_id            uuid default auth.uid(),
  ocurrido_en           timestamptz not null,
  recibido_en           timestamptz not null default now(),
  check (tipo <> 'anulacion' or coalesce(trim(motivo), '') <> '')
);
create index on public.paro_eventos (paro_id);
create unique index paro_un_fin on public.paro_eventos (paro_id) where tipo = 'fin';
select public.aplicar_estandar_evento('paro_eventos');

-- Paros con su fin y duración (sin los anulados)
create view public.paros_vista with (security_invoker = true) as
select p.*, c.codigo as causa_codigo, c.nombre as causa, c.descuenta_operario, c.descuenta_celula, c.descuenta_nomina, c.detiene_celula,
       c.rol_validador,
       coalesce((select e.ocurrido_en from public.paro_eventos e where e.paro_id = p.id and e.tipo = 'fin'),
                case when c.minutos_definidos is not null then p.inicio + make_interval(mins => c.minutos_definidos) end) as fin,
       exists (select 1 from public.paro_eventos e where e.paro_id = p.id and e.tipo = 'validacion') as validado,
       round(extract(epoch from coalesce((select e.ocurrido_en from public.paro_eventos e where e.paro_id = p.id and e.tipo = 'fin'),
                                         case when c.minutos_definidos is not null then p.inicio + make_interval(mins => c.minutos_definidos) end,
                                         now()) - p.inicio) / 60, 1) as minutos,
       not exists (select 1 from public.paro_eventos e where e.paro_id = p.id and e.tipo = 'fin')
         and (c.minutos_definidos is null or p.inicio + make_interval(mins => c.minutos_definidos) > now()) as activo
from public.paros p join public.causas_paro c on c.id = p.causa_id
where not exists (select 1 from public.paro_eventos e where e.paro_id = p.id and e.tipo = 'anulacion');

-- Minutos de paro que descuentan al operario entre dos horas (los suyos y los de su célula entera)
create or replace function public.minutos_paro_operario(p_empleado uuid, p_celula uuid, p_desde timestamptz, p_hasta timestamptz) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, extract(epoch from least(coalesce(v.fin, p_hasta), p_hasta) - greatest(v.inicio, p_desde)) / 60)), 0)
  from paros_vista v
  where v.descuenta_operario and v.inicio < p_hasta and coalesce(v.fin, p_hasta) > p_desde
    and (v.empleado_id = p_empleado or (v.empleado_id is null and v.detiene_celula and v.celula_id = p_celula))
$$;

-- La eficiencia oficial de cada marcación descuenta los paros (misma regla que la tablet)
alter table public.marcaciones add column minutos_paro numeric(10,3) not null default 0;
create or replace function public.fn_marcacion_oficial() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ant timestamptz;
  v_max numeric := coalesce((select (valor #>> '{}')::numeric from parametros where clave = 'max_minutos_entre_marcaciones'), 30);
  v_min numeric;
  v_paro numeric;
begin
  if new.tipo = 'anulacion' then return new; end if;
  select max(m.ocurrido_en_servidor) into v_ant from marcaciones m
  where m.empleado_id = new.empleado_id and m.tipo <> 'anulacion' and m.ocurrido_en_servidor < new.ocurrido_en_servidor
    and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date = (new.ocurrido_en_servidor at time zone 'America/Bogota')::date
    and not exists (select 1 from marcaciones a where a.anula_id = m.id);
  if v_ant is not null then
    v_paro := minutos_paro_operario(new.empleado_id, new.celula_id, v_ant, new.ocurrido_en_servidor);
    v_min := extract(epoch from new.ocurrido_en_servidor - v_ant) / 60 - v_paro;
    new.minutos_paro := round(v_paro, 3);
    if v_min > 0 and v_min <= v_max then
      new.minutos_reales := round(v_min, 3);
      new.eficiencia := round(new.minutos_esperados / new.minutos_reales * 100, 2);
    end if;
  end if;
  return new;
end $$;

-- Ingesta desde la tablet
create or replace function public.ingerir_paro(p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare e estaciones; c causas_paro; v_n int;
begin
  select * into e from estaciones where id = p_disp.estacion_id;
  select * into c from causas_paro where id = (p_datos->>'causa_id')::uuid;
  if c.id is null then raise exception 'Causa de paro inexistente'; end if;
  insert into paros (id, causa_id, empleado_id, celula_id, estacion_id, maquina_id, observacion, dispositivo_id, inicio)
  values (p_id, c.id, case when c.detiene_celula then null else (p_datos->>'empleado_id')::uuid end, e.celula_id, e.id,
          (p_datos->>'maquina_id')::uuid, p_datos->>'observacion', p_disp.id, hora_evento(p_datos, p_desfase))
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

create or replace function public.ingerir_paro_evento(p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int; v_tipo text := p_datos->>'tipo';
begin
  if not exists (select 1 from paros where id = (p_datos->>'paro_id')::uuid) then raise exception 'Paro inexistente'; end if;
  if v_tipo = 'fin' and exists (select 1 from paro_eventos where paro_id = (p_datos->>'paro_id')::uuid and tipo = 'fin' and id <> p_id) then
    return false;   -- otra tablet ya lo terminó
  end if;
  insert into paro_eventos (id, paro_id, tipo, validador_empleado_id, motivo, dispositivo_id, ocurrido_en)
  values (p_id, (p_datos->>'paro_id')::uuid, v_tipo, (p_datos->>'validador_empleado_id')::uuid, p_datos->>'motivo', p_disp.id,
          hora_evento(p_datos, p_desfase))
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;
revoke all on function public.ingerir_paro(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
revoke all on function public.ingerir_paro_evento(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
insert into public.ingesta_manejadores values ('paros', 'ingerir_paro'), ('paro_eventos', 'ingerir_paro_evento')
on conflict (tabla) do update set funcion = excluded.funcion;

-- ---------------------------------------------------------------------
-- Informes de eficiencia
-- p_agrupar: operario | celula | planta; p_periodo: hora | dia | semana | quincena | mes
-- Eficiencia = Σ minutos esperados / Σ minutos reales (de las marcaciones con tiempo medido).
-- ---------------------------------------------------------------------
create or replace function public.periodo_de(p_t timestamptz, p_periodo text) returns text
language sql immutable as $$
  select case p_periodo
    when 'hora' then to_char(p_t at time zone 'America/Bogota', 'YYYY-MM-DD HH24":00"')
    when 'dia' then to_char(p_t at time zone 'America/Bogota', 'YYYY-MM-DD')
    when 'semana' then to_char(p_t at time zone 'America/Bogota', 'IYYY-"S"IW')
    when 'quincena' then to_char(p_t at time zone 'America/Bogota', 'YYYY-MM') || case when extract(day from p_t at time zone 'America/Bogota') <= 15 then '-Q1' else '-Q2' end
    else to_char(p_t at time zone 'America/Bogota', 'YYYY-MM') end
$$;

create or replace function public.informe_eficiencia(p_desde date, p_hasta date, p_agrupar text default 'operario', p_periodo text default 'dia',
                                                      p_celula uuid default null)
returns table (clave uuid, codigo text, nombre text, periodo text, unidades int, reprocesos int, minutos_esperados numeric,
               minutos_reales numeric, eficiencia numeric, minutos_paro numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('eficiencia', 'ver') or public.puede('balanceo', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso para ver eficiencias' using errcode = '42501';
  end if;
  return query
  with m as (
    select mm.*, coalesce(e.celula_id, mm.celula_id) as cel
    from marcaciones mm join empleados e on e.id = mm.empleado_id
    where mm.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = mm.id)
      and (mm.ocurrido_en_servidor at time zone 'America/Bogota')::date between p_desde and p_hasta
      and (p_celula is null or mm.celula_id = p_celula)
  ), g as (
    select case p_agrupar when 'operario' then m.empleado_id when 'celula' then m.celula_id else null end as k,
           periodo_de(m.ocurrido_en_servidor, p_periodo) as per,
           sum(m.unidades) filter (where m.tipo = 'normal')::int as u, sum(m.unidades) filter (where m.tipo = 'reproceso')::int as r,
           sum(m.minutos_esperados) filter (where m.minutos_reales is not null) as e, sum(m.minutos_reales) as re,
           sum(m.minutos_paro) as pa
    from m group by 1, 2
  )
  select g.k,
         case p_agrupar when 'operario' then (select e.codigo from empleados e where e.id = g.k) when 'celula' then (select c.codigo from celulas c where c.id = g.k) else 'PLANTA' end,
         case p_agrupar when 'operario' then (select e.nombres || ' ' || e.apellidos from empleados e where e.id = g.k)
                        when 'celula' then (select c.nombre from celulas c where c.id = g.k) else 'Total planta' end,
         g.per, coalesce(g.u, 0), coalesce(g.r, 0), round(coalesce(g.e, 0), 2), round(coalesce(g.re, 0), 2),
         case when coalesce(g.re, 0) > 0 then round(g.e / g.re * 100, 1) end, round(coalesce(g.pa, 0), 1)
  from g order by 2, 4;
end $$;

-- Minutos improductivos por causa y por célula u operario entre fechas
create or replace function public.informe_paros(p_desde date, p_hasta date, p_celula uuid default null)
returns table (paro_id uuid, inicio timestamptz, fin timestamptz, minutos numeric, causa text, celula text, operario text, validado boolean,
               descuenta_operario boolean, descuenta_nomina boolean, observacion text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('eficiencia', 'ver') or public.puede('balanceo', 'ver') or public.puede('mantenimiento', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return query
  select v.id, v.inicio, v.fin, v.minutos, v.causa, c.codigo, coalesce(e.nombres || ' ' || e.apellidos, 'Toda la célula'), v.validado,
         v.descuenta_operario, v.descuenta_nomina, v.observacion
  from paros_vista v left join celulas c on c.id = v.celula_id left join empleados e on e.id = v.empleado_id
  where (v.inicio at time zone 'America/Bogota')::date between p_desde and p_hasta and (p_celula is null or v.celula_id = p_celula)
  order by v.inicio desc;
end $$;

-- ---------------------------------------------------------------------
-- Incentivos por tramos de eficiencia (opcionales: solo para células con grupo)
-- ---------------------------------------------------------------------
create table public.grupos_incentivo (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null unique,
  tipo        text not null default 'individual' check (tipo in ('individual','modular')),  -- modular = eficiencia de la célula
  periodo     text not null default 'quincena' check (periodo in ('dia','semana','quincena','mes')),
  minimo_minutos numeric(8,1) not null default 0,   -- minutos medidos mínimos en el periodo para tener derecho
  activo      boolean not null default true
);
create table public.incentivo_tramos (
  id         uuid primary key default gen_random_uuid(),
  grupo_id   uuid not null references public.grupos_incentivo(id) on delete cascade,
  desde_pct  numeric(6,2) not null,
  hasta_pct  numeric(6,2),                         -- null = sin tope
  valor      numeric(14,2) not null check (valor >= 0), -- COP por periodo
  check (hasta_pct is null or hasta_pct > desde_pct)
);
alter table public.celulas add column grupo_incentivo_id uuid references public.grupos_incentivo(id);

create or replace function public.liquidar_incentivos(p_desde date, p_hasta date)
returns table (empleado_id uuid, codigo text, nombre text, celula text, grupo text, periodo text, minutos_esperados numeric,
               minutos_reales numeric, eficiencia numeric, valor numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('eficiencia', 'ver') or public.puede('costos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return query
  with base as (
    select m.empleado_id, e.celula_id, g.id as grupo_id, g.nombre as grupo, g.tipo, g.minimo_minutos,
           periodo_de(m.ocurrido_en_servidor, g.periodo) as per, m.minutos_esperados, m.minutos_reales
    from marcaciones m join empleados e on e.id = m.empleado_id join celulas c on c.id = e.celula_id
    join grupos_incentivo g on g.id = c.grupo_incentivo_id and g.activo
    where m.tipo <> 'anulacion' and m.minutos_reales is not null and not exists (select 1 from marcaciones a where a.anula_id = m.id)
      and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date between p_desde and p_hasta
  ), ind as (
    select empleado_id, celula_id, grupo_id, grupo, tipo, minimo_minutos, per, sum(minutos_esperados) as e, sum(minutos_reales) as r from base group by 1, 2, 3, 4, 5, 6, 7
  ), cel as (
    select celula_id, per, sum(minutos_esperados) as e, sum(minutos_reales) as r from base group by 1, 2
  )
  select i.empleado_id, em.codigo, em.nombres || ' ' || em.apellidos, c.codigo, i.grupo, i.per, round(i.e, 2), round(i.r, 2),
         round(case when i.tipo = 'modular' then ce.e / nullif(ce.r, 0) else i.e / nullif(i.r, 0) end * 100, 1),
         case when i.r < i.minimo_minutos then 0 else coalesce((
           select t.valor from incentivo_tramos t where t.grupo_id = i.grupo_id
             and round(case when i.tipo = 'modular' then ce.e / nullif(ce.r, 0) else i.e / nullif(i.r, 0) end * 100, 1) >= t.desde_pct
             and (t.hasta_pct is null or round(case when i.tipo = 'modular' then ce.e / nullif(ce.r, 0) else i.e / nullif(i.r, 0) end * 100, 1) < t.hasta_pct)
           order by t.desde_pct desc limit 1), 0) end
  from ind i join empleados em on em.id = i.empleado_id join celulas c on c.id = i.celula_id
  join cel ce on ce.celula_id = i.celula_id and ce.per = i.per
  order by c.codigo, em.codigo, i.per;
end $$;

-- ---------------------------------------------------------------------
-- Tableros de TV
-- ---------------------------------------------------------------------
insert into public.roles (codigo, nombre, solo_planta, orden) values ('tv', 'Pantalla de TV (cuenta técnica)', true, 19) on conflict do nothing;
insert into public.permisos_modulo (rol, modulo, puede_ver, puede_editar, puede_aprobar) values ('tv', 'tv', true, false, false) on conflict do nothing;

create table public.tableros_tv (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  vistas     jsonb not null default '[{"tipo":"celulas"},{"tipo":"procesos"}]',   -- [{tipo: celula|celulas|procesos, celula_id}]
  rotacion_s int not null default 20 check (rotacion_s between 5 and 600),
  activo     boolean not null default true
);

-- Meta por hora de la célula: la del balanceo publicado de su OP en curso, o la calculada (60 × operarios × eficiencia / SAM)
create or replace function public.meta_hora_celula(p_celula uuid, p_op uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (metricas_balanceo(b.id) ->> 'meta_hora')::numeric from balanceos b where b.op_id = p_op and b.celula_id = p_celula and b.estado = 'publicado'),
    (select round(60 * operarios_celula(c.id) * c.eficiencia_planeada / 100 / nullif(sum(fo.sam * fo.repeticiones), 0), 1)
     from celulas c cross join ordenes_produccion o join ficha_operaciones fo on fo.ficha_id = o.ficha_version_id
     where c.id = p_celula and o.id = p_op and fo.proceso = c.proceso and fo.agrega_minutos_sam group by c.id, c.eficiencia_planeada))
$$;

-- Todo lo que muestra el tablero de una célula hoy
create or replace function public.tablero_celula(p_celula uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c celulas;
  v_hoy date := hoy_bogota();
  v_op uuid;
  v_meta numeric;
  r jsonb;
begin
  if not (public.puede('tv', 'ver') or public.puede('eficiencia', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  select * into c from celulas where id = p_celula;
  -- OP en curso: la de la última marcación de hoy en la célula
  select m.op_id into v_op from marcaciones m where m.celula_id = p_celula and m.tipo = 'normal'
    and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date = v_hoy order by m.ocurrido_en_servidor desc limit 1;
  v_meta := meta_hora_celula(p_celula, v_op);
  with m as (
    select mm.*, fo.es_contadora from marcaciones mm join ficha_operaciones fo on fo.id = mm.ficha_operacion_id
    where mm.celula_id = p_celula and mm.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = mm.id)
      and (mm.ocurrido_en_servidor at time zone 'America/Bogota')::date = v_hoy
  )
  select jsonb_build_object(
    'celula', jsonb_build_object('id', c.id, 'codigo', c.codigo, 'nombre', c.nombre),
    'op', (select jsonb_build_object('consecutivo', o.consecutivo, 'referencia', r2.codigo || ' ' || r2.nombre, 'cantidad', o.cantidad_total,
                                     'confeccionadas', (select buenas from op_procesos where op_id = o.id and proceso = c.proceso))
           from ordenes_produccion o join referencias r2 on r2.id = o.referencia_id where o.id = v_op),
    'meta_hora', v_meta,
    'eficiencia_dia', (select round(sum(minutos_esperados) filter (where minutos_reales is not null) / nullif(sum(minutos_reales), 0) * 100, 1) from m),
    'producidas_dia', (select coalesce(sum(unidades), 0) from m where es_contadora and tipo = 'normal'),
    'hora_a_hora', (select coalesce(jsonb_agg(jsonb_build_object('hora', h, 'producidas', p, 'eficiencia', ef) order by h), '[]') from (
                      select extract(hour from ocurrido_en_servidor at time zone 'America/Bogota')::int as h,
                             coalesce(sum(unidades) filter (where es_contadora and tipo = 'normal'), 0) as p,
                             round(sum(minutos_esperados) filter (where minutos_reales is not null) / nullif(sum(minutos_reales), 0) * 100, 1) as ef
                      from m group by 1) x),
    'operarios', (select coalesce(jsonb_agg(jsonb_build_object('nombre', e.nombres, 'codigo', e.codigo, 'eficiencia', x.ef, 'unidades', x.u) order by x.ef desc nulls last), '[]')
                  from (select empleado_id, round(sum(minutos_esperados) filter (where minutos_reales is not null) / nullif(sum(minutos_reales), 0) * 100, 1) as ef,
                               sum(unidades) filter (where tipo = 'normal') as u from m group by 1) x join empleados e on e.id = x.empleado_id),
    'paro_activo', (select jsonb_build_object('causa', v.causa, 'desde', v.inicio, 'operario', coalesce(e.nombres, 'Toda la célula'))
                    from paros_vista v left join empleados e on e.id = v.empleado_id where v.celula_id = p_celula and v.activo order by v.inicio desc limit 1),
    'minutos_paro_dia', (select coalesce(sum(v.minutos), 0) from paros_vista v where v.celula_id = p_celula and (v.inicio at time zone 'America/Bogota')::date = v_hoy)
  ) into r;
  return r;
end $$;

-- Planta: todas las células hoy y avance por proceso de las OP activas
create or replace function public.tablero_planta() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.puede('tv', 'ver') or public.puede('eficiencia', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'celulas', (select coalesce(jsonb_agg(tablero_celula(c.id) order by c.codigo), '[]') from celulas c where c.activo and c.proceso = 'confeccion'),
    'procesos', (select coalesce(jsonb_agg(jsonb_build_object('proceso', p.codigo, 'nombre', p.nombre, 'color', p.color_hex, 'buenas', x.b, 'total', x.t) order by p.orden), '[]')
                 from procesos p join (select op.proceso, sum(op.buenas) as b, sum(o.cantidad_total) as t from op_procesos op
                                       join ordenes_produccion o on o.id = op.op_id where o.estado in ('planeada','en_proceso') group by 1) x on x.proceso = p.codigo),
    'eficiencia_planta', (select round(sum(minutos_esperados) filter (where minutos_reales is not null) / nullif(sum(minutos_reales), 0) * 100, 1)
                          from marcaciones m where m.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = m.id)
                            and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date = hoy_bogota()),
    'ops_activas', (select count(*) from ordenes_produccion where estado in ('planeada','en_proceso')),
    'hora', now());
end $$;

-- ---------------------------------------------------------------------
-- RLS, datos de sistema y publicación
-- ---------------------------------------------------------------------
select public.aplicar_estandar_maestro('causas_paro');
select public.aplicar_estandar_maestro('grupos_incentivo');
select public.aplicar_estandar_maestro('incentivo_tramos');
select public.aplicar_estandar_maestro('tableros_tv');
create policy causas_paro_leer on public.causas_paro for select to authenticated using (public.es_interno());
create policy causas_paro_editar on public.causas_paro for all to authenticated using (public.puede('eficiencia','editar')) with check (public.puede('eficiencia','editar'));
create policy paros_leer on public.paros for select to authenticated using (public.es_interno());
create policy paro_eventos_leer on public.paro_eventos for select to authenticated using (public.es_interno());
create policy grupos_incentivo_leer on public.grupos_incentivo for select to authenticated using (public.es_interno());
create policy grupos_incentivo_editar on public.grupos_incentivo for all to authenticated using (public.puede('eficiencia','aprobar')) with check (public.puede('eficiencia','aprobar'));
create policy incentivo_tramos_leer on public.incentivo_tramos for select to authenticated using (public.es_interno());
create policy incentivo_tramos_editar on public.incentivo_tramos for all to authenticated using (public.puede('eficiencia','aprobar')) with check (public.puede('eficiencia','aprobar'));
create policy tableros_leer on public.tableros_tv for select to authenticated using (public.es_interno());
create policy tableros_editar on public.tableros_tv for all to authenticated using (public.puede('tv','editar') or public.puede('eficiencia','editar'))
  with check (public.puede('tv','editar') or public.puede('eficiencia','editar'));
create policy celulas_incentivo on public.celulas for update to authenticated using (public.puede('eficiencia','aprobar')) with check (public.puede('eficiencia','aprobar'));

-- Causas de paro por defecto (editables)
insert into public.causas_paro (codigo, nombre, visible_tablet, descuenta_operario, descuenta_nomina, descuenta_celula, detiene_trabajo, detiene_celula, rol_validador, cuenta_para_validador, minutos_definidos) values
  ('MAQ', 'Daño de máquina', true, true, false, true, true, false, 'mecanico', true, null),
  ('MAT', 'Falta de material o trabajo', true, true, false, true, true, true, null, false, null),
  ('CAL', 'Revisión de calidad', true, true, false, true, true, false, null, false, null),
  ('REU', 'Reunión o capacitación', true, true, false, true, true, true, null, false, null),
  ('ALM', 'Almuerzo', true, true, true, true, true, false, null, false, 60),
  ('PER', 'Permiso personal', true, false, true, false, true, false, null, false, null)
on conflict (codigo) do nothing;

insert into public.tableros_tv (nombre, vistas, rotacion_s) values
  ('TV de planta', '[{"tipo":"celulas"},{"tipo":"procesos"}]', 20);

alter publication powersync add table public.causas_paro;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.paros, public.paro_eventos;
  end if;
end $$;
