-- =====================================================================
-- Fase 1 · Migración 3: ingesta de eventos desde dispositivos (sin conexión)
-- Caso de prueba de la Fase 1: marcas de asistencia (entrada / salida con
-- el QR del carnet). Las demás tablas de eventos se suman en sus fases
-- agregando un "when" en ingerir_eventos().
-- =====================================================================

-- Bitácora de todo lo que llega por la bandeja de salida (idempotencia y diagnóstico)
create table public.ingesta_eventos (
  id             uuid primary key,             -- = id del evento (UUID generado en la tablet)
  tabla          text not null,
  dispositivo_id uuid references public.dispositivos(id),
  estado         text not null check (estado in ('aceptado','rechazado')),
  motivo         text,
  intentos       int  not null default 1,
  primer_intento timestamptz not null default now(),
  recibido_en    timestamptz not null default now()
);
create index on public.ingesta_eventos (estado, recibido_en desc);
alter table public.ingesta_eventos enable row level security;

-- ---------------------------------------------------------------------
-- Evento: marca de asistencia  (E) inmutable
-- ---------------------------------------------------------------------
create table public.asistencia_marcas (
  id                   uuid primary key,                 -- generado en el dispositivo
  empleado_id          uuid not null references public.empleados(id),
  tipo                 text not null check (tipo in ('entrada','salida','anulacion')),
  anula_id             uuid references public.asistencia_marcas(id),
  motivo               text,
  estacion_id          uuid not null references public.estaciones(id),
  dispositivo_id       uuid not null references public.dispositivos(id),
  usuario_id           uuid default auth.uid(),
  ocurrido_en          timestamptz not null,             -- hora del dispositivo
  ocurrido_en_servidor timestamptz not null,             -- hora corregida con el desfase medido
  desfase_reloj_s      int  not null default 0,
  reloj_dudoso         boolean not null default false,
  recibido_en          timestamptz not null default now(),
  check ((tipo = 'anulacion') = (anula_id is not null)),
  check (tipo <> 'anulacion' or coalesce(trim(motivo), '') <> '')
);
create index on public.asistencia_marcas (empleado_id, ocurrido_en_servidor);
create unique index asistencia_una_anulacion on public.asistencia_marcas (anula_id) where anula_id is not null;
select public.aplicar_estandar_evento('asistencia_marcas');

-- Marcas vigentes (sin las anuladas ni las anulaciones)
create view public.asistencia_marcas_vigentes with (security_invoker = true) as
select m.*
from public.asistencia_marcas m
where m.tipo <> 'anulacion'
  and not exists (select 1 from public.asistencia_marcas a where a.anula_id = m.id);

-- ---------------------------------------------------------------------
-- Manejador por tabla. Devuelve true si insertó, false si ya existía.
-- ---------------------------------------------------------------------
create or replace function public.ingerir_asistencia_marca(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_ocurrido timestamptz := (p_datos->>'ocurrido_en')::timestamptz;
  v_corregido timestamptz;
  v_tipo text := p_datos->>'tipo';
  v_empleado uuid := (p_datos->>'empleado_id')::uuid;
  v_n int;
begin
  if v_ocurrido is null then raise exception 'Falta ocurrido_en'; end if;
  v_corregido := v_ocurrido + make_interval(secs => p_desfase);
  if v_corregido > now() + interval '2 minutes' then
    raise exception 'Hora del evento en el futuro (%)', v_corregido;
  end if;
  if not exists (select 1 from empleados where id = v_empleado and activo) then
    raise exception 'Empleado inexistente o inactivo';
  end if;

  insert into asistencia_marcas (id, empleado_id, tipo, anula_id, motivo, estacion_id, dispositivo_id,
                                 ocurrido_en, ocurrido_en_servidor, desfase_reloj_s, reloj_dudoso)
  values (p_id, v_empleado, v_tipo, (p_datos->>'anula_id')::uuid, p_datos->>'motivo',
          p_disp.estacion_id,              -- la estación la define el servidor, no la tablet
          p_disp.id, v_ocurrido, v_corregido, p_desfase, abs(p_desfase) > p_tolerancia)
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- ---------------------------------------------------------------------
-- Punto único de entrada de la bandeja de salida
-- El dispositivo se identifica por la sesión (cada cuenta técnica = una tablet),
-- así la tablet puede subir aunque aún no haya descargado nada.
-- p_lote = { hora_dispositivo, version_app, dispositivo_id (opcional, se verifica),
--            eventos: [ { id, tabla, op: 'PUT', datos: {...} }, ... ] }
-- Respuesta: { hora_servidor, desfase_reloj_s,
--              resultados: [ { id, estado: aceptado|duplicado|rechazado, motivo } ] }
-- ---------------------------------------------------------------------
create or replace function public.ingerir_eventos(p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_disp       dispositivos;
  v_desfase    int;
  v_tolerancia int := coalesce((select (valor #>> '{}')::int from parametros where clave = 'tolerancia_reloj_s'), 300);
  v_ev         jsonb;
  v_id         uuid;
  v_estado     text;
  v_motivo     text;
  v_resultados jsonb := '[]'::jsonb;
  v_insertado  boolean;
begin
  select * into v_disp from dispositivos where usuario_id = auth.uid() and activo;
  if not found or (p_lote ? 'dispositivo_id' and (p_lote->>'dispositivo_id')::uuid is distinct from v_disp.id) then
    raise exception 'Dispositivo no autorizado' using errcode = '42501';
  end if;

  v_desfase := round(extract(epoch from now() - (p_lote->>'hora_dispositivo')::timestamptz));
  perform set_config('app.dispositivo_id', v_disp.id::text, true);

  update dispositivos
     set ultima_sync = now(), desfase_reloj_s = v_desfase,
         version_app = coalesce(p_lote->>'version_app', version_app)
   where id = v_disp.id;

  if abs(v_desfase) > v_tolerancia then
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
    values ('reloj_dudoso', 'media', 'dispositivos', v_disp.id::text,
            format('La hora de %s está desfasada %s segundos. Corríjala en la tablet.', v_disp.nombre, v_desfase),
            jsonb_build_object('desfase_s', v_desfase));
  end if;

  for v_ev in select * from jsonb_array_elements(coalesce(p_lote->'eventos', '[]'::jsonb)) loop
    v_motivo := null;
    begin
      v_id := (v_ev->>'id')::uuid;
      if coalesce(v_ev->>'op', 'PUT') <> 'PUT' then
        raise exception 'Los eventos solo se agregan; operación % no permitida', v_ev->>'op';
      end if;

      case v_ev->>'tabla'
        when 'asistencia_marcas' then
          v_insertado := ingerir_asistencia_marca(v_id, v_ev->'datos', v_disp, v_desfase, v_tolerancia);
        else
          raise exception 'Tabla % no admitida en la ingesta', v_ev->>'tabla';
      end case;

      v_estado := case when v_insertado then 'aceptado' else 'duplicado' end;
    exception when others then
      v_estado := 'rechazado';
      v_motivo := sqlerrm;
    end;

    if v_id is not null then
      insert into ingesta_eventos (id, tabla, dispositivo_id, estado, motivo)
      values (v_id, coalesce(v_ev->>'tabla', '?'), v_disp.id,
              case when v_estado = 'rechazado' then 'rechazado' else 'aceptado' end, v_motivo)
      on conflict (id) do update
        set intentos = ingesta_eventos.intentos + 1,
            recibido_en = now(),
            estado = case when ingesta_eventos.estado = 'aceptado' then 'aceptado' else excluded.estado end,
            motivo = case when ingesta_eventos.estado = 'aceptado' then null else excluded.motivo end;
    end if;

    v_resultados := v_resultados || jsonb_build_object('id', v_ev->>'id', 'estado', v_estado, 'motivo', v_motivo);
  end loop;

  return jsonb_build_object('hora_servidor', now(), 'desfase_reloj_s', v_desfase, 'resultados', v_resultados);
end $$;

revoke all on function public.ingerir_eventos(jsonb) from public, anon;
grant execute on function public.ingerir_eventos(jsonb) to authenticated;
revoke all on function public.ingerir_asistencia_marca(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
