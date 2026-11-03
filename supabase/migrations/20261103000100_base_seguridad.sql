-- =====================================================================
-- Fase 1 · Migración 1: base, seguridad, roles, auditoría e inmutabilidad
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Utilidades genéricas
-- ---------------------------------------------------------------------

-- Dispositivo que origina la petición (lo fija ingerir_eventos con set_config)
create or replace function public.dispositivo_actual() returns uuid
language sql stable as $$
  select nullif(current_setting('app.dispositivo_id', true), '')::uuid
$$;

-- Mantiene actualizado_en / actualizado_por en tablas maestras
create or replace function public.fn_set_actualizado() returns trigger
language plpgsql as $$
begin
  new.actualizado_en := now();
  new.actualizado_por := auth.uid();
  return new;
end $$;

-- Regla 2: los eventos nunca se editan ni se borran
create or replace function public.fn_bloquear_cambios() returns trigger
language plpgsql as $$
begin
  raise exception 'La tabla % es inmutable: no se permite %. Registre una anulación.',
    tg_table_name, tg_op
    using errcode = 'P0001';
end $$;

-- Regla 6: auditoría (antes / después, usuario, dispositivo)
create table public.auditoria (
  id            bigserial primary key,
  tabla         text        not null,
  registro_id   text,
  accion        text        not null check (accion in ('INSERT','UPDATE','DELETE')),
  antes         jsonb,
  despues       jsonb,
  usuario_id    uuid,
  dispositivo_id uuid,
  ocurrido_en   timestamptz not null default now()
);
create index on public.auditoria (tabla, registro_id);
create index on public.auditoria (ocurrido_en);

create or replace function public.fn_auditar() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_antes   jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_despues jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'UPDATE' and v_antes = v_despues then
    return new;
  end if;
  insert into public.auditoria (tabla, registro_id, accion, antes, despues, usuario_id, dispositivo_id)
  values (tg_table_name,
          coalesce(v_despues, v_antes) ->> coalesce(tg_argv[0], 'id'),
          tg_op, v_antes, v_despues, auth.uid(), public.dispositivo_actual());
  return coalesce(new, old);
end $$;

create trigger auditoria_inmutable before update or delete on public.auditoria
  for each row execute function public.fn_bloquear_cambios();

-- Aplica el estándar a una tabla maestra: actualizado_en/por + auditoría + RLS
create or replace function public.aplicar_estandar_maestro(p_tabla text, p_clave text default 'id')
returns void language plpgsql as $$
begin
  execute format('alter table public.%I
                    add column if not exists creado_en timestamptz not null default now(),
                    add column if not exists creado_por uuid default auth.uid(),
                    add column if not exists actualizado_en timestamptz,
                    add column if not exists actualizado_por uuid', p_tabla);
  execute format('create trigger %I before update on public.%I for each row execute function public.fn_set_actualizado()',
                 p_tabla || '_actualizado', p_tabla);
  execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.fn_auditar(%L)',
                 p_tabla || '_auditoria', p_tabla, p_clave);
  execute format('alter table public.%I enable row level security', p_tabla);
end $$;

-- Aplica el estándar a una tabla de eventos: inmutable + auditoría de inserción + RLS
create or replace function public.aplicar_estandar_evento(p_tabla text)
returns void language plpgsql as $$
begin
  execute format('create trigger %I before update or delete on public.%I for each row execute function public.fn_bloquear_cambios()',
                 p_tabla || '_inmutable', p_tabla);
  execute format('create trigger %I after insert on public.%I for each row execute function public.fn_auditar(%L)',
                 p_tabla || '_auditoria', p_tabla, 'id');
  execute format('alter table public.%I enable row level security', p_tabla);
end $$;

-- ---------------------------------------------------------------------
-- Roles, módulos y permisos
-- ---------------------------------------------------------------------
create table public.roles (
  codigo      text primary key,
  nombre      text not null,
  descripcion text,
  solo_planta boolean not null default false,  -- operario / dispositivo: solo app de tablet
  orden       int  not null default 0
);

create table public.modulos (
  codigo text primary key,
  nombre text not null,
  grupo  text not null,            -- Producción, Inventarios, Piso, Administración…
  icono  text,
  ruta   text not null,
  fase   int  not null,            -- fase en la que queda disponible
  orden  int  not null default 0
);

create table public.permisos_modulo (
  rol           text not null references public.roles(codigo),
  modulo        text not null references public.modulos(codigo),
  puede_ver     boolean not null default true,
  puede_editar  boolean not null default false,
  puede_aprobar boolean not null default false,
  primary key (rol, modulo)
);

-- Perfil de cada usuario de Supabase Auth
create table public.perfiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  nombre          text not null,
  correo          text,
  empleado_id     uuid,           -- FK se agrega en migración de maestros
  satelite_id     uuid,           -- idem
  es_dispositivo  boolean not null default false,
  creado_en       timestamptz not null default now(),
  creado_por      uuid default auth.uid(),
  actualizado_en  timestamptz,
  actualizado_por uuid,
  activo          boolean not null default true
);

create table public.usuario_roles (
  id         uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.perfiles(id) on delete cascade,
  rol        text not null references public.roles(codigo),
  celula_id  uuid,                -- alcance opcional (supervisor de un módulo)
  proceso    text,                -- alcance opcional
  creado_en  timestamptz not null default now(),
  creado_por uuid default auth.uid()
);
create unique index usuario_roles_unico
  on public.usuario_roles (usuario_id, rol, coalesce(celula_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- ---------------------------------------------------------------------
-- Funciones de autorización (usadas por RLS y por la app)
-- ---------------------------------------------------------------------
create or replace function public.mis_roles() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(ur.rol), '{}')
  from public.usuario_roles ur
  join public.perfiles p on p.id = ur.usuario_id and p.activo
  where ur.usuario_id = auth.uid()
$$;

create or replace function public.tiene_rol(p_roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select public.mis_roles() && p_roles
$$;

create or replace function public.es_gerencia() returns boolean
language sql stable security definer set search_path = public as $$
  select 'gerencia' = any(public.mis_roles())
$$;

-- p_accion: 'ver' | 'editar' | 'aprobar'. Gerencia puede todo.
create or replace function public.puede(p_modulo text, p_accion text default 'ver') returns boolean
language sql stable security definer set search_path = public as $$
  select public.es_gerencia() or exists (
    select 1 from public.permisos_modulo pm
    where pm.modulo = p_modulo
      and pm.rol = any(public.mis_roles())
      and case p_accion
            when 'ver'     then pm.puede_ver
            when 'editar'  then pm.puede_editar
            when 'aprobar' then pm.puede_aprobar
            else false end)
$$;

-- Lo que la app necesita al iniciar sesión: perfil, roles y permisos efectivos
create or replace function public.mi_sesion() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'usuario_id', p.id,
    'nombre', p.nombre,
    'es_dispositivo', p.es_dispositivo,
    'empleado_id', p.empleado_id,
    'roles', public.mis_roles(),
    'permisos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'modulo', x.codigo, 'nombre', x.nombre, 'grupo', x.grupo, 'ruta', x.ruta,
               'icono', x.icono, 'fase', x.fase, 'ver', true,
               'editar', x.editar, 'aprobar', x.aprobar) order by x.orden)
      from (
        select m.codigo, m.nombre, m.grupo, m.ruta, m.icono, m.fase, m.orden,
               public.es_gerencia() or coalesce(bool_or(pm.puede_editar), false)  as editar,
               public.es_gerencia() or coalesce(bool_or(pm.puede_aprobar), false) as aprobar
        from public.modulos m
        left join public.permisos_modulo pm on pm.modulo = m.codigo and pm.rol = any(public.mis_roles())
        where public.es_gerencia() or pm.puede_ver
        group by m.codigo, m.nombre, m.grupo, m.ruta, m.icono, m.fase, m.orden
      ) x
    ), '[]'::jsonb))
  from public.perfiles p
  where p.id = auth.uid() and p.activo
$$;

select public.aplicar_estandar_maestro('perfiles');
select public.aplicar_estandar_maestro('usuario_roles');
select public.aplicar_estandar_maestro('permisos_modulo', 'modulo');
alter table public.roles enable row level security;
alter table public.modulos enable row level security;
alter table public.auditoria enable row level security;
