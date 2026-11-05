-- =====================================================================
-- Fase 9 · Migración 16: calidad (defectos, muestreo, inspecciones en
-- proceso y auditoría final, devoluciones a operario y operación,
-- reprocesos, eficacia), terminación y producto terminado / segundas
-- (SKU por referencia + color/combinación + talla, ingresos automáticos,
-- ajustes, traslados y despachos a pedidos).
-- Reglas: 2 (eventos inmutables, se anulan con eventos inversos),
-- 5 (entra = buenas + segundas + faltantes), 7 (lo que mueve inventario
-- es una sola función SQL).
-- =====================================================================

insert into public.parametros (clave, valor, descripcion) values
  ('calidad_exige_auditoria', 'true', 'Un paquete o juego no sale del proceso de auditoría sin una auditoría final aprobada'),
  ('proceso_auditoria_final', '"calidad"', 'Proceso de la ruta donde se hace la auditoría final por muestreo')
on conflict (clave) do nothing;
insert into public.consecutivos (tipo, prefijo) values ('DES', 'DES'), ('INS', 'INS') on conflict do nothing;

-- ---------------------------------------------------------------------
-- Catálogo de defectos y planes de muestreo
-- ---------------------------------------------------------------------
create table public.defectos (
  id        uuid primary key default gen_random_uuid(),
  codigo    text not null unique,
  nombre    text not null,
  proceso   text references public.procesos(codigo),     -- null = cualquiera
  severidad text not null default 'mayor' check (severidad in ('menor','mayor','critico')),
  activo    boolean not null default true
);
insert into public.defectos (codigo, nombre, proceso, severidad) values
  ('PSA', 'Puntada saltada', 'confeccion', 'mayor'),
  ('COA', 'Costura abierta o reventada', 'confeccion', 'critico'),
  ('FRU', 'Costura fruncida o torcida', 'confeccion', 'mayor'),
  ('HIL', 'Hilos sin cortar', 'terminacion', 'menor'),
  ('MAN', 'Mancha', null, 'mayor'),
  ('HUE', 'Hueco o rotura en la tela', null, 'critico'),
  ('TON', 'Diferencia de tono entre partes', 'corte', 'mayor'),
  ('EST', 'Estampado defectuoso', 'estampacion', 'mayor'),
  ('ETQ', 'Etiqueta o marquilla mal puesta', 'terminacion', 'menor'),
  ('PLA', 'Mal planchado', 'terminacion', 'menor'),
  ('MED', 'Medida fuera de tolerancia', null, 'mayor')
on conflict (codigo) do nothing;

-- tabla: [{desde, hasta (null = sin tope), muestra, acepta}] por tamaño de lote
create table public.planes_muestreo (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null unique,
  aql         numeric(5,2) not null,
  tabla       jsonb not null check (jsonb_typeof(tabla) = 'array' and jsonb_array_length(tabla) > 0),
  por_defecto boolean not null default false,
  activo      boolean not null default true
);
create unique index planes_muestreo_un_defecto on public.planes_muestreo (por_defecto) where por_defecto;
-- ISO 2859-1, inspección normal, nivel general II, AQL 2,5 (las flechas de la norma ya resueltas)
insert into public.planes_muestreo (nombre, aql, por_defecto, tabla) values
  ('ISO 2859-1 nivel II · AQL 2,5', 2.5, true, '[
     {"desde": 1, "hasta": 1, "muestra": 1, "acepta": 0},
     {"desde": 2, "hasta": 50, "muestra": 5, "acepta": 0},
     {"desde": 51, "hasta": 150, "muestra": 20, "acepta": 1},
     {"desde": 151, "hasta": 280, "muestra": 32, "acepta": 2},
     {"desde": 281, "hasta": 500, "muestra": 50, "acepta": 3},
     {"desde": 501, "hasta": 1200, "muestra": 80, "acepta": 5},
     {"desde": 1201, "hasta": 3200, "muestra": 125, "acepta": 7},
     {"desde": 3201, "hasta": 10000, "muestra": 200, "acepta": 10},
     {"desde": 10001, "hasta": 35000, "muestra": 315, "acepta": 14},
     {"desde": 35001, "hasta": null, "muestra": 500, "acepta": 21}]'::jsonb)
on conflict (nombre) do nothing;

-- Muestra y número de aceptación para un lote (la muestra nunca pasa del lote)
create or replace function public.muestreo(p_plan uuid, p_lote int, out muestra int, out acepta int)
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(p_lote, 0) <= 0 then raise exception 'El lote debe tener prendas'; end if;
  select x into r from planes_muestreo p, jsonb_array_elements(p.tabla) x
   where p.id = coalesce(p_plan, (select id from planes_muestreo where por_defecto))
     and p_lote >= (x->>'desde')::int and (x->>'hasta' is null or p_lote <= (x->>'hasta')::int)
   limit 1;
  if r is null then raise exception 'El plan de muestreo no cubre un lote de %', p_lote; end if;
  muestra := least((r->>'muestra')::int, p_lote);
  acepta := (r->>'acepta')::int;
end $$;

-- ---------------------------------------------------------------------
-- Inspecciones (E): en proceso y auditoría final
-- ---------------------------------------------------------------------
create table public.inspecciones (
  id                   uuid primary key,                   -- generado en la tablet
  consecutivo          text not null unique default public.siguiente_consecutivo('INS'),
  tipo                 text not null check (tipo in ('en_proceso','auditoria_final','anulacion')),
  anula_id             uuid unique references public.inspecciones(id),
  motivo               text,
  op_id                uuid not null references public.ordenes_produccion(id),
  paquete_id           uuid references public.paquetes(id),
  juego_id             uuid references public.juegos(id),
  proceso              text references public.procesos(codigo),   -- donde estaba la unidad
  estacion_id          uuid references public.estaciones(id),
  celula_id            uuid references public.celulas(id),         -- módulo responsable (el que confeccionó)
  satelite_id          uuid references public.satelites(id),
  inspector_id         uuid references public.empleados(id),
  plan_id              uuid references public.planes_muestreo(id),
  tamano_lote          int not null default 0,
  tamano_muestra       int not null default 0,
  acepta               int,
  defectuosas          int not null default 0,
  resultado            text check (resultado in ('aprobado','rechazado')),
  alcance              text check (alcance in ('individual','grupal')),
  observacion          text,
  dispositivo_id       uuid references public.dispositivos(id),
  usuario_id           uuid default auth.uid(),
  ocurrido_en          timestamptz not null,
  ocurrido_en_servidor timestamptz not null,
  recibido_en          timestamptz not null default now(),
  check ((tipo = 'anulacion') = (anula_id is not null)),
  check (tipo <> 'anulacion' or coalesce(trim(motivo), '') <> ''),
  check (paquete_id is not null or juego_id is not null)
);
create index on public.inspecciones (paquete_id);
create index on public.inspecciones (juego_id);
create index on public.inspecciones (op_id);
create index on public.inspecciones (ocurrido_en_servidor);
select public.aplicar_estandar_evento('inspecciones');

create table public.inspeccion_defectos (
  id                 uuid primary key default gen_random_uuid(),
  inspeccion_id      uuid not null references public.inspecciones(id),
  defecto_id         uuid not null references public.defectos(id),
  cantidad           int not null check (cantidad > 0),       -- prendas con este defecto
  talla_id           uuid references public.tallas(id),
  ficha_operacion_id uuid references public.ficha_operaciones(id),
  empleado_id        uuid references public.empleados(id),    -- responsable (sale de las marcaciones)
  celula_id          uuid references public.celulas(id),
  satelite_id        uuid references public.satelites(id)
);
create index on public.inspeccion_defectos (inspeccion_id);
create index on public.inspeccion_defectos (empleado_id);
select public.aplicar_estandar_evento('inspeccion_defectos');

create table public.inspeccion_medidas (
  id             uuid primary key default gen_random_uuid(),
  inspeccion_id  uuid not null references public.inspecciones(id),
  medida_id      uuid not null references public.ficha_medidas(id),
  talla_id       uuid references public.tallas(id),
  valor_cm       numeric(7,2) not null,
  esperado_cm    numeric(7,2),
  tolerancia_cm  numeric(5,2),
  fuera_tolerancia boolean not null default false
);
create index on public.inspeccion_medidas (inspeccion_id);
select public.aplicar_estandar_evento('inspeccion_medidas');

-- Devoluciones a operario y operación: trabajo pendiente que nace de los
-- defectos (inmutables) y se cierra con reprocesos o con el cierre del inspector.
create table public.devoluciones_calidad (
  id                  uuid primary key default gen_random_uuid(),
  inspeccion_id       uuid not null references public.inspecciones(id),
  inspeccion_defecto_id uuid not null unique references public.inspeccion_defectos(id),
  op_id               uuid not null references public.ordenes_produccion(id),
  paquete_id          uuid references public.paquetes(id),
  juego_id            uuid references public.juegos(id),
  unidad_codigo       text not null,
  alcance             text not null default 'individual' check (alcance in ('individual','grupal')),
  defecto_id          uuid not null references public.defectos(id),
  ficha_operacion_id  uuid references public.ficha_operaciones(id),
  empleado_id         uuid references public.empleados(id),
  celula_id           uuid references public.celulas(id),
  satelite_id         uuid references public.satelites(id),
  cantidad            int not null check (cantidad > 0),
  reprocesadas        int not null default 0,
  segundas            int not null default 0,
  estado              text not null default 'abierta' check (estado in ('abierta','reprocesada','segunda','anulada')),
  creada_en           timestamptz not null default now(),
  cerrada_en          timestamptz
);
create index on public.devoluciones_calidad (estado);
create index on public.devoluciones_calidad (paquete_id);
create index on public.devoluciones_calidad (juego_id);
alter table public.devoluciones_calidad enable row level security;
create trigger devoluciones_calidad_auditoria after insert or update on public.devoluciones_calidad
  for each row execute function public.fn_auditar('id');

create or replace function public.fn_devolucion_protegida() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.calidad_sistema', true), '') <> 'si' then
    raise exception 'Las devoluciones de calidad solo cambian con reprocesos o cierres';
  end if;
  return coalesce(new, old);
end $$;
create trigger devoluciones_protegidas before update or delete on public.devoluciones_calidad
  for each row execute function public.fn_devolucion_protegida();

create table public.devolucion_cierres (
  id                   uuid primary key,
  devolucion_id        uuid not null unique references public.devoluciones_calidad(id),
  reprocesadas         int not null default 0 check (reprocesadas >= 0),
  segundas             int not null default 0 check (segundas >= 0),
  empleado_id          uuid references public.empleados(id),
  observacion          text,
  dispositivo_id       uuid references public.dispositivos(id),
  usuario_id           uuid default auth.uid(),
  ocurrido_en          timestamptz not null,
  ocurrido_en_servidor timestamptz not null,
  recibido_en          timestamptz not null default now()
);
select public.aplicar_estandar_evento('devolucion_cierres');

-- ---------------------------------------------------------------------
-- Responsables de una operación en una unidad
-- ---------------------------------------------------------------------
-- Operario: el que más unidades marcó de esa operación en el paquete/juego.
-- Célula o satélite: quien entregó la unidad en el proceso de la operación.
create or replace function public.responsable_operacion(p_unidad uuid, p_fo uuid,
  out empleado_id uuid, out celula_id uuid, out satelite_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_proceso text := (select proceso from ficha_operaciones where id = p_fo);
begin
  select m.empleado_id into empleado_id from marcaciones m
   where (m.paquete_id = p_unidad or m.juego_id = p_unidad) and m.ficha_operacion_id = p_fo and m.tipo = 'normal'
     and not exists (select 1 from marcaciones a where a.anula_id = m.id)
   group by m.empleado_id order by sum(m.unidades) desc, max(m.ocurrido_en_servidor) desc limit 1;
  -- la entrega (avance) dice quién la hizo; si se registró sin célula (web), vale la de la recepción
  select e.celula_id, e.satelite_id into celula_id, satelite_id from eventos_proceso e
   where (e.paquete_id = p_unidad or e.juego_id = p_unidad) and e.proceso = v_proceso and e.tipo in ('avance','recepcion')
     and (e.celula_id is not null or e.satelite_id is not null)
     and not exists (select 1 from eventos_proceso a where a.anula_id = e.id)
   order by (e.tipo = 'avance') desc, e.ocurrido_en_servidor desc nulls last limit 1;
  if celula_id is null and satelite_id is null then
    select m.celula_id into celula_id from marcaciones m
     where (m.paquete_id = p_unidad or m.juego_id = p_unidad) and m.ficha_operacion_id = p_fo order by m.ocurrido_en_servidor desc limit 1;
  end if;
end $$;

-- Módulo que confeccionó la unidad (para atribuir la auditoría)
create or replace function public.celula_confeccion(p_unidad uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.celula_id from eventos_proceso e
  where (e.paquete_id = p_unidad or e.juego_id = p_unidad) and e.tipo in ('avance','recepcion') and e.proceso = 'confeccion' and e.celula_id is not null
    and not exists (select 1 from eventos_proceso a where a.anula_id = e.id)
  order by (e.tipo = 'avance') desc, e.ocurrido_en_servidor desc nulls last limit 1
$$;

-- Última auditoría final vigente (no anulada) de una unidad
create or replace function public.ultima_auditoria(p_unidad uuid) returns public.inspecciones
language sql stable security definer set search_path = public as $$
  select i.* from inspecciones i
  where (i.paquete_id = p_unidad or i.juego_id = p_unidad) and i.tipo = 'auditoria_final'
    and not exists (select 1 from inspecciones a where a.anula_id = i.id)
  order by i.ocurrido_en_servidor desc, i.recibido_en desc limit 1
$$;

-- ---------------------------------------------------------------------
-- Registrar una inspección (tablet de calidad, sin conexión → ingesta)
-- datos = {tipo, unidad_id, inspector_id, tamano_muestra?, alcance?, observacion?, ocurrido_en,
--          defectos: [{defecto_id, cantidad, ficha_operacion_id?}], medidas: [{medida_id, valor_cm}]}
-- ---------------------------------------------------------------------
-- La tablet manda las listas como texto JSON (columnas de SQLite); la web, como arreglos
create or replace function public.lista_json(p jsonb) returns jsonb
language sql immutable as $$
  select case jsonb_typeof(p) when 'array' then p when 'string' then coalesce(nullif(p #>> '{}', '')::jsonb, '[]') else '[]'::jsonb end
$$;

create or replace function public.aplicar_inspeccion(p_id uuid, p_datos jsonb, p_estacion uuid, p_dispositivo uuid,
                                                     p_ocurrido timestamptz, p_servidor timestamptz)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_tipo text := p_datos->>'tipo';
  u unidades_trabajo;
  orig inspecciones;
  v_plan uuid := (select id from planes_muestreo where por_defecto);
  v_lote int;
  v_muestra int;
  v_acepta int;
  v_def int := 0;
  v_fuera boolean := false;
  v_result text;
  v_alcance text := coalesce(nullif(p_datos->>'alcance', ''), 'individual');
  v_talla uuid;
  v_ficha uuid;
  d jsonb;
  m jsonb;
  r record;
  v_esp numeric;
  v_tol numeric;
  v_def_id uuid;
begin
  if exists (select 1 from inspecciones where id = p_id) then return false; end if;
  perform set_config('app.calidad_sistema', 'si', true);
  p_datos := p_datos || jsonb_build_object('defectos', lista_json(p_datos->'defectos'), 'medidas', lista_json(p_datos->'medidas'));

  if v_tipo = 'anulacion' then
    select * into orig from inspecciones where id = (p_datos->>'anula_id')::uuid;
    if orig.id is null then raise exception 'La inspección a anular no existe'; end if;
    if orig.tipo = 'anulacion' then raise exception 'Una anulación no se anula'; end if;
    insert into inspecciones (id, tipo, anula_id, motivo, op_id, paquete_id, juego_id, proceso, estacion_id, inspector_id,
                              dispositivo_id, ocurrido_en, ocurrido_en_servidor)
    values (p_id, 'anulacion', orig.id, coalesce(nullif(trim(p_datos->>'motivo'), ''), 'Anulada'), orig.op_id, orig.paquete_id, orig.juego_id,
            orig.proceso, p_estacion, (p_datos->>'inspector_id')::uuid, p_dispositivo, p_ocurrido, p_servidor);
    update devoluciones_calidad set estado = 'anulada', cerrada_en = p_servidor where inspeccion_id = orig.id and estado = 'abierta';
    return true;
  end if;

  if v_tipo not in ('en_proceso','auditoria_final') then raise exception 'Tipo de inspección inválido: %', v_tipo; end if;
  u := buscar_unidad(null, (p_datos->>'unidad_id')::uuid);
  if u.id is null then raise exception 'Paquete o juego no encontrado'; end if;
  if u.estado = 'anulado' then raise exception '% está anulado', u.codigo; end if;
  if (p_datos->>'inspector_id') is not null and not exists (select 1 from empleados where id = (p_datos->>'inspector_id')::uuid) then
    raise exception 'Inspector inexistente';
  end if;
  if v_alcance not in ('individual','grupal') then raise exception 'Alcance inválido'; end if;
  v_lote := u.cantidad_actual;
  v_talla := u.talla_id;
  v_ficha := (select ficha_version_id from ordenes_produccion where id = u.op_id);

  if v_tipo = 'auditoria_final' then
    select x.muestra, x.acepta into v_muestra, v_acepta from muestreo(v_plan, v_lote) x;
  else
    v_plan := null;
    v_muestra := least(greatest(coalesce((p_datos->>'tamano_muestra')::int, v_lote), 1), v_lote);
    v_acepta := null;
  end if;

  -- Medidas contra la ficha (talla de la unidad); una fuera de tolerancia es un defecto "MED"
  for m in select * from jsonb_array_elements(coalesce(p_datos->'medidas', '[]')) loop
    select mt.valor_cm, mt.tolerancia_cm into v_esp, v_tol from ficha_medida_tallas mt
     where mt.medida_id = (m->>'medida_id')::uuid and mt.talla_id = v_talla;
    if v_esp is not null and abs((m->>'valor_cm')::numeric - v_esp) > v_tol then v_fuera := true; end if;
  end loop;

  select coalesce(sum((x->>'cantidad')::int), 0) into v_def from jsonb_array_elements(coalesce(p_datos->'defectos', '[]')) x;
  v_def_id := (select id from defectos where codigo = 'MED');
  if v_fuera and not exists (select 1 from jsonb_array_elements(coalesce(p_datos->'defectos', '[]')) x where (x->>'defecto_id')::uuid = v_def_id) then
    v_def := v_def + 1;
  end if;
  if v_def > v_muestra then raise exception 'Hay más prendas con defecto (%) que prendas revisadas (%)', v_def, v_muestra; end if;

  v_result := case when v_tipo = 'auditoria_final' then case when v_def <= v_acepta then 'aprobado' else 'rechazado' end
                   else case when v_def = 0 then 'aprobado' else 'rechazado' end end;

  insert into inspecciones (id, tipo, op_id, paquete_id, juego_id, proceso, estacion_id, celula_id, satelite_id, inspector_id, plan_id,
                            tamano_lote, tamano_muestra, acepta, defectuosas, resultado, alcance, observacion, dispositivo_id,
                            ocurrido_en, ocurrido_en_servidor)
  values (p_id, v_tipo, u.op_id, case when u.tipo = 'paquete' then u.id end, case when u.tipo = 'juego' then u.id end,
          u.proceso_actual, p_estacion,
          case when v_tipo = 'auditoria_final' then celula_confeccion(u.id) else u.celula_id end, null,
          (p_datos->>'inspector_id')::uuid, v_plan, v_lote, v_muestra, v_acepta, v_def, v_result,
          case when v_result = 'rechazado' then v_alcance end, nullif(trim(p_datos->>'observacion'), ''), p_dispositivo, p_ocurrido, p_servidor);

  for m in select * from jsonb_array_elements(coalesce(p_datos->'medidas', '[]')) loop
    select mt.valor_cm, mt.tolerancia_cm into v_esp, v_tol from ficha_medida_tallas mt
     where mt.medida_id = (m->>'medida_id')::uuid and mt.talla_id = v_talla;
    insert into inspeccion_medidas (inspeccion_id, medida_id, talla_id, valor_cm, esperado_cm, tolerancia_cm, fuera_tolerancia)
    values (p_id, (m->>'medida_id')::uuid, v_talla, (m->>'valor_cm')::numeric, v_esp, v_tol,
            v_esp is not null and abs((m->>'valor_cm')::numeric - v_esp) > v_tol);
  end loop;

  -- Una auditoría aprobada cierra lo que estaba devuelto (ya volvió arreglado)
  if v_tipo = 'auditoria_final' and v_result = 'aprobado' then
    update devoluciones_calidad set estado = 'reprocesada', reprocesadas = greatest(reprocesadas, cantidad - segundas), cerrada_en = p_servidor
     where (paquete_id = u.id or juego_id = u.id) and estado = 'abierta';
  end if;

  for d in select * from jsonb_array_elements(coalesce(p_datos->'defectos', '[]'))
           union all
           select jsonb_build_object('defecto_id', v_def_id, 'cantidad', 1) where v_fuera
             and not exists (select 1 from jsonb_array_elements(coalesce(p_datos->'defectos', '[]')) x where (x->>'defecto_id')::uuid = v_def_id)
  loop
    if not exists (select 1 from defectos where id = (d->>'defecto_id')::uuid) then raise exception 'Defecto inexistente'; end if;
    if (d->>'ficha_operacion_id') is not null
       and not exists (select 1 from ficha_operaciones where id = (d->>'ficha_operacion_id')::uuid and ficha_id = v_ficha) then
      raise exception 'La operación no es de la ficha de la OP';
    end if;
    select * into r from responsable_operacion(u.id, (d->>'ficha_operacion_id')::uuid);
    with nuevo as (
      insert into inspeccion_defectos (inspeccion_id, defecto_id, cantidad, talla_id, ficha_operacion_id, empleado_id, celula_id, satelite_id)
      values (p_id, (d->>'defecto_id')::uuid, (d->>'cantidad')::int, v_talla, (d->>'ficha_operacion_id')::uuid, r.empleado_id,
              coalesce(r.celula_id, case when v_tipo = 'auditoria_final' then celula_confeccion(u.id) end), r.satelite_id)
      returning *)
    insert into devoluciones_calidad (inspeccion_id, inspeccion_defecto_id, op_id, paquete_id, juego_id, unidad_codigo, alcance, defecto_id,
                                      ficha_operacion_id, empleado_id, celula_id, satelite_id, cantidad, creada_en)
    select p_id, n.id, u.op_id, case when u.tipo = 'paquete' then u.id end, case when u.tipo = 'juego' then u.id end, u.codigo,
           case when v_result = 'rechazado' then v_alcance else 'individual' end, n.defecto_id, n.ficha_operacion_id, n.empleado_id,
           n.celula_id, n.satelite_id, n.cantidad, p_servidor
    from nuevo n;
  end loop;

  if v_tipo = 'auditoria_final' and v_result = 'rechazado' then
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
    values ('auditoria_rechazada', case when v_alcance = 'grupal' then 'alta' else 'media' end, 'inspecciones', p_id::text,
            format('%s rechazado en auditoría: %s prendas con defecto de %s revisadas (acepta %s). Devolución %s.',
                   u.codigo, v_def, v_muestra, v_acepta, v_alcance),
            jsonb_build_object('op_id', u.op_id, 'unidad_id', u.id));
  end if;
  return true;
end $$;
revoke all on function public.aplicar_inspeccion(uuid, jsonb, uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.ingerir_inspeccion(p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return aplicar_inspeccion(p_id, p_datos, p_disp.estacion_id, p_disp.id, (p_datos->>'ocurrido_en')::timestamptz, hora_evento(p_datos, p_desfase));
end $$;
revoke all on function public.ingerir_inspeccion(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;

-- Desde la web (Calidad): misma regla
create or replace function public.registrar_inspeccion(p_datos jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce((p_datos->>'id')::uuid, gen_random_uuid());
begin
  perform exigir_permiso('calidad', 'editar');
  perform aplicar_inspeccion(v_id, p_datos, null, null, now(), now());
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Cierre de devoluciones: el inspector recibe el arreglo
-- datos = {devolucion_id, reprocesadas, segundas, empleado_id, observacion, ocurrido_en}
-- ---------------------------------------------------------------------
create or replace function public.aplicar_cierre_devolucion(p_id uuid, p_datos jsonb, p_dispositivo uuid, p_ocurrido timestamptz, p_servidor timestamptz)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  dv devoluciones_calidad;
  v_rep int := coalesce((p_datos->>'reprocesadas')::int, 0);
  v_seg int := coalesce((p_datos->>'segundas')::int, 0);
begin
  if exists (select 1 from devolucion_cierres where id = p_id) then return false; end if;
  select * into dv from devoluciones_calidad where id = (p_datos->>'devolucion_id')::uuid for update;
  if dv.id is null then raise exception 'Devolución no encontrada'; end if;
  if exists (select 1 from devolucion_cierres where devolucion_id = dv.id) then return false; end if;  -- otra tablet ya la cerró
  if v_rep + v_seg <> dv.cantidad then
    raise exception 'Las cantidades no cuadran: se devolvieron %, arregladas + segundas = %', dv.cantidad, v_rep + v_seg;
  end if;
  insert into devolucion_cierres (id, devolucion_id, reprocesadas, segundas, empleado_id, observacion, dispositivo_id, ocurrido_en, ocurrido_en_servidor)
  values (p_id, dv.id, v_rep, v_seg, (p_datos->>'empleado_id')::uuid, nullif(trim(p_datos->>'observacion'), ''), p_dispositivo, p_ocurrido, p_servidor);
  perform set_config('app.calidad_sistema', 'si', true);
  update devoluciones_calidad set reprocesadas = greatest(reprocesadas, v_rep), segundas = v_seg,
         estado = case when v_seg > 0 and v_rep = 0 then 'segunda' else 'reprocesada' end, cerrada_en = coalesce(cerrada_en, p_servidor)
   where id = dv.id;
  return true;
end $$;
revoke all on function public.aplicar_cierre_devolucion(uuid, jsonb, uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.ingerir_cierre_devolucion(p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return aplicar_cierre_devolucion(p_id, p_datos, p_disp.id, (p_datos->>'ocurrido_en')::timestamptz, hora_evento(p_datos, p_desfase));
end $$;
revoke all on function public.ingerir_cierre_devolucion(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;

create or replace function public.cerrar_devolucion(p_devolucion uuid, p_reprocesadas int, p_segundas int, p_observacion text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('calidad', 'editar');
  perform aplicar_cierre_devolucion(gen_random_uuid(), jsonb_build_object('devolucion_id', p_devolucion, 'reprocesadas', p_reprocesadas,
                                    'segundas', p_segundas, 'observacion', p_observacion), null, now(), now());
end $$;

-- El reproceso que marca el operario en la tablet descuenta su devolución
create or replace function public.fn_reproceso_devolucion() returns trigger
language plpgsql security definer set search_path = public as $$
declare dv devoluciones_calidad;
begin
  if new.tipo <> 'reproceso' then return new; end if;
  select * into dv from devoluciones_calidad d
   where d.estado = 'abierta' and (d.paquete_id = coalesce(new.paquete_id, new.juego_id) or d.juego_id = coalesce(new.juego_id, new.paquete_id))
     and (d.ficha_operacion_id = new.ficha_operacion_id or d.ficha_operacion_id is null)
   order by (d.empleado_id = new.empleado_id) desc nulls last, (d.ficha_operacion_id is not null) desc, d.creada_en
   limit 1 for update;
  if dv.id is null then return new; end if;
  perform set_config('app.calidad_sistema', 'si', true);
  update devoluciones_calidad set reprocesadas = reprocesadas + new.unidades,
         estado = case when reprocesadas + new.unidades >= cantidad then 'reprocesada' else estado end,
         cerrada_en = case when reprocesadas + new.unidades >= cantidad then new.ocurrido_en_servidor end
   where id = dv.id;
  return new;
end $$;
create trigger marcaciones_reproceso_devolucion after insert on public.marcaciones for each row execute function public.fn_reproceso_devolucion();

-- Vista: devoluciones con nombres (web y tablet)
create view public.devoluciones_vista with (security_invoker = true) as
select d.*, df.codigo as defecto_codigo, df.nombre as defecto, df.severidad, o.consecutivo as op, op2.nombre as operacion,
       e.codigo as empleado_codigo, e.nombres || ' ' || e.apellidos as empleado, c.codigo as celula, s.nombre as satelite,
       i.consecutivo as inspeccion, i.tipo as tipo_inspeccion
from public.devoluciones_calidad d
join public.defectos df on df.id = d.defecto_id
join public.ordenes_produccion o on o.id = d.op_id
join public.inspecciones i on i.id = d.inspeccion_id
left join public.ficha_operaciones fo on fo.id = d.ficha_operacion_id
left join public.operaciones op2 on op2.id = fo.operacion_id
left join public.empleados e on e.id = d.empleado_id
left join public.celulas c on c.id = d.celula_id
left join public.satelites s on s.id = d.satelite_id;

-- ---------------------------------------------------------------------
-- No sale de la auditoría lo que no está aprobado
-- ---------------------------------------------------------------------
create or replace function public.fn_exigir_auditoria() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_proc text := coalesce((select valor #>> '{}' from parametros where clave = 'proceso_auditoria_final'), 'calidad');
  a inspecciones;
  v_cod text;
begin
  if new.tipo <> 'avance' or coalesce(new.paquete_id, new.juego_id) is null or new.proceso <> v_proc then return new; end if;
  if coalesce((select valor #>> '{}' from parametros where clave = 'calidad_exige_auditoria'), 'true') <> 'true' then return new; end if;
  if new.buenas = 0 then return new; end if;   -- nada bueno que liberar (todo segunda o faltante)
  a := ultima_auditoria(coalesce(new.paquete_id, new.juego_id));
  v_cod := coalesce((select codigo from paquetes where id = new.paquete_id), (select codigo from juegos where id = new.juego_id));
  if a.id is null then raise exception '% necesita la auditoría final antes de entregarse', v_cod; end if;
  if a.resultado <> 'aprobado' then raise exception '% está rechazado en auditoría: después del arreglo haga una nueva auditoría', v_cod; end if;
  return new;
end $$;
create trigger eventos_exigir_auditoria before insert on public.eventos_proceso for each row execute function public.fn_exigir_auditoria();

-- ---------------------------------------------------------------------
-- Producto terminado y segundas
-- ---------------------------------------------------------------------
create table public.skus (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique,
  referencia_id      uuid not null references public.referencias(id),
  combinacion_codigo text not null,
  talla_id           uuid not null references public.tallas(id),
  codigo_barras      text unique,
  precio_venta       numeric(14,2),
  codigo_alegra      text,
  shopify_variant_id text,
  activo             boolean not null default true,
  unique (referencia_id, combinacion_codigo, talla_id)
);
select public.aplicar_estandar_maestro('skus');

-- SKU de una referencia + color/combinación + talla (lo crea si no existe)
create or replace function public.sku_de(p_referencia uuid, p_combinacion text, p_talla uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from skus where referencia_id = p_referencia and combinacion_codigo = p_combinacion and talla_id = p_talla;
  if v is null then
    insert into skus (codigo, referencia_id, combinacion_codigo, talla_id, codigo_barras)
    select x.c, p_referencia, p_combinacion, p_talla, x.c
    from (select 'PT-' || r.codigo || '-' || p_combinacion || '-' || t.codigo as c from referencias r, tallas t
          where r.id = p_referencia and t.id = p_talla) x
    on conflict (referencia_id, combinacion_codigo, talla_id) do nothing
    returning id into v;
    if v is null then
      select id into v from skus where referencia_id = p_referencia and combinacion_codigo = p_combinacion and talla_id = p_talla;
    end if;
  end if;
  return v;
end $$;

-- Código de color/combinación de un paquete o juego (el mismo de los pedidos)
create or replace function public.combinacion_de_unidad(p_paquete uuid, p_juego uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.codigo from juegos j join ficha_combinaciones c on c.id = j.combinacion_id where j.id = p_juego),
    (select c.codigo from paquetes p join ordenes_produccion o on o.id = p.op_id
       join ficha_combinaciones c on c.ficha_id = o.ficha_version_id
      where p.id = p_paquete
        and (select cp.color_id from ficha_combinacion_partes cp join ficha_partes fp on fp.id = cp.parte_id
              where cp.combinacion_id = c.id order by fp.orden limit 1) = p.color_id
      order by c.codigo limit 1),
    (select co.codigo from paquetes p join colores co on co.id = p.color_id where p.id = p_paquete))
$$;

create table public.despachos (
  id          uuid primary key default gen_random_uuid(),
  consecutivo text not null unique default public.siguiente_consecutivo('DES'),
  pedido_id   uuid references public.pedidos(id),
  cliente_id  uuid references public.clientes(id),
  fecha       date not null default public.hoy_bogota(),
  observacion text,
  estado      text not null default 'despachado' check (estado in ('despachado','anulado')),
  motivo_anulacion text,
  creado_por  uuid default auth.uid(),
  creado_en   timestamptz not null default now()
);
alter table public.despachos enable row level security;
create trigger despachos_auditoria after insert or update on public.despachos for each row execute function public.fn_auditar('id');

create table public.movimientos_producto (
  id          uuid primary key default gen_random_uuid(),
  tipo        text not null check (tipo in ('ingreso_op','ingreso_segunda','despacho','devolucion','ajuste','traslado','anulacion')),
  sku_id      uuid not null references public.skus(id),
  bodega_id   uuid not null references public.bodegas(id),
  cantidad    int  not null check (cantidad <> 0),        -- + entra, − sale
  op_id       uuid references public.ordenes_produccion(id),
  paquete_id  uuid references public.paquetes(id),
  juego_id    uuid references public.juegos(id),
  evento_id   uuid references public.eventos_proceso(id),
  despacho_id uuid references public.despachos(id),
  documento   text,
  motivo      text,
  anula_id    uuid references public.movimientos_producto(id),
  usuario_id  uuid default auth.uid(),
  creado_en   timestamptz not null default now(),
  check (tipo <> 'anulacion' or anula_id is not null),
  check (tipo not in ('ajuste','traslado','anulacion','devolucion') or coalesce(trim(motivo), '') <> '')
);
create index on public.movimientos_producto (sku_id, bodega_id);
create index on public.movimientos_producto (op_id);
create index on public.movimientos_producto (despacho_id);
create unique index movimientos_producto_una_anulacion on public.movimientos_producto (anula_id) where anula_id is not null;
select public.aplicar_estandar_evento('movimientos_producto');

create view public.saldos_producto with (security_invoker = true) as
select m.sku_id, m.bodega_id, sum(m.cantidad)::int as cantidad
from public.movimientos_producto m group by 1, 2 having sum(m.cantidad) <> 0;

create view public.existencias_producto with (security_invoker = true) as
select s.id as sku_id, s.codigo, s.referencia_id, r.codigo as referencia, r.nombre as referencia_nombre, s.combinacion_codigo,
       s.talla_id, t.codigo as talla, t.orden as talla_orden, b.id as bodega_id, b.codigo as bodega, b.tipo as bodega_tipo,
       sp.cantidad, s.precio_venta
from public.saldos_producto sp
join public.skus s on s.id = sp.sku_id
join public.referencias r on r.id = s.referencia_id
join public.tallas t on t.id = s.talla_id
join public.bodegas b on b.id = sp.bodega_id;

create or replace function public.bodega_de_tipo(p_tipo text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from bodegas where tipo = p_tipo and activo order by codigo limit 1
$$;

create or replace function public.saldo_producto(p_sku uuid, p_bodega uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(cantidad), 0)::int from movimientos_producto where sku_id = p_sku and bodega_id = p_bodega
$$;

-- Ingreso automático: las segundas de cualquier proceso van a la bodega de segundas;
-- las buenas del último proceso de la ruta, a producto terminado (por talla y color).
create or replace function public.fn_ingreso_producto() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ref uuid;
  v_talla uuid;
  v_comb text;
  v_sku uuid;
  v_bod uuid;
  v_cod text;
begin
  if new.tipo <> 'avance' or coalesce(new.paquete_id, new.juego_id) is null then return new; end if;
  if new.segundas = 0 and (new.buenas = 0 or siguiente_proceso(new.op_id, new.proceso) is not null) then return new; end if;
  select o.referencia_id into v_ref from ordenes_produccion o where o.id = new.op_id;
  select coalesce((select talla_id from paquetes where id = new.paquete_id), (select talla_id from juegos where id = new.juego_id)),
         coalesce((select codigo from paquetes where id = new.paquete_id), (select codigo from juegos where id = new.juego_id))
    into v_talla, v_cod;
  v_comb := combinacion_de_unidad(new.paquete_id, new.juego_id);
  v_sku := sku_de(v_ref, v_comb, v_talla);
  if new.segundas > 0 then
    v_bod := bodega_de_tipo('segundas');
    if v_bod is null then raise exception 'No hay bodega de segundas activa'; end if;
    insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, op_id, paquete_id, juego_id, evento_id, documento)
    values ('ingreso_segunda', v_sku, v_bod, new.segundas, new.op_id, new.paquete_id, new.juego_id, new.id,
            v_cod || ' · ' || (select nombre from procesos where codigo = new.proceso));
  end if;
  if new.buenas > 0 and siguiente_proceso(new.op_id, new.proceso) is null then
    v_bod := bodega_de_tipo('producto_terminado');
    if v_bod is null then raise exception 'No hay bodega de producto terminado activa'; end if;
    insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, op_id, paquete_id, juego_id, evento_id, documento)
    values ('ingreso_op', v_sku, v_bod, new.buenas, new.op_id, new.paquete_id, new.juego_id, new.id, v_cod);
  end if;
  return new;
end $$;
create trigger eventos_ingreso_producto after insert on public.eventos_proceso for each row execute function public.fn_ingreso_producto();

-- Ajuste (conteo, prenda perdida o encontrada): con motivo
create or replace function public.ajustar_producto(p_sku uuid, p_bodega uuid, p_cantidad int, p_motivo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform exigir_permiso('inventario', 'editar');
  if coalesce(p_cantidad, 0) = 0 then raise exception 'La cantidad del ajuste no puede ser cero'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'El ajuste necesita un motivo'; end if;
  if not exists (select 1 from bodegas where id = p_bodega and tipo in ('producto_terminado','segundas')) then
    raise exception 'La bodega no es de producto terminado ni de segundas';
  end if;
  perform 1 from skus where id = p_sku for update;
  if saldo_producto(p_sku, p_bodega) + p_cantidad < 0 then
    raise exception 'No hay suficientes: hay %, el ajuste saca %', saldo_producto(p_sku, p_bodega), -p_cantidad;
  end if;
  insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, motivo, documento)
  values ('ajuste', p_sku, p_bodega, p_cantidad, trim(p_motivo), 'Ajuste') returning id into v;
  return v;
end $$;

-- Traslado entre producto terminado y segundas (p. ej. una prenda dañada en bodega)
create or replace function public.trasladar_producto(p_sku uuid, p_desde uuid, p_hacia uuid, p_cantidad int, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('inventario', 'editar');
  if coalesce(p_cantidad, 0) <= 0 then raise exception 'La cantidad debe ser mayor que cero'; end if;
  if p_desde = p_hacia then raise exception 'Elija bodegas distintas'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'El traslado necesita un motivo'; end if;
  if (select count(*) from bodegas where id in (p_desde, p_hacia) and tipo in ('producto_terminado','segundas')) <> 2 then
    raise exception 'Solo entre producto terminado y segundas';
  end if;
  perform 1 from skus where id = p_sku for update;
  if saldo_producto(p_sku, p_desde) < p_cantidad then
    raise exception 'No hay suficientes: hay %', saldo_producto(p_sku, p_desde);
  end if;
  insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, motivo, documento) values
    ('traslado', p_sku, p_desde, -p_cantidad, trim(p_motivo), 'Traslado'),
    ('traslado', p_sku, p_hacia, p_cantidad, trim(p_motivo), 'Traslado');
end $$;

-- Lo pedido, lo despachado y lo que falta por despachar de cada línea de pedido
create view public.pedido_despachos with (security_invoker = true) as
select pl.id as pedido_linea_id, pl.pedido_id, pl.referencia_id, pl.combinacion_codigo, pl.talla_id, pl.cantidad,
       coalesce(d.despachado, 0)::int as despachado, (pl.cantidad - coalesce(d.despachado, 0))::int as por_despachar,
       s.id as sku_id
from public.pedido_lineas pl
left join public.skus s on s.referencia_id = pl.referencia_id and s.combinacion_codigo = pl.combinacion_codigo and s.talla_id = pl.talla_id
left join lateral (
  select -sum(m.cantidad) as despachado from public.movimientos_producto m join public.despachos de on de.id = m.despacho_id
  where de.pedido_id = pl.pedido_id and m.sku_id = s.id and m.tipo in ('despacho','anulacion')
) d on true;

-- Despacho de producto terminado a un pedido: todo o nada
-- p_lineas = [{sku_id, cantidad}]
create or replace function public.despachar(p_pedido uuid, p_lineas jsonb, p_observacion text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  pe pedidos;
  v_des despachos;
  x jsonb;
  v_pt uuid := bodega_de_tipo('producto_terminado');
  v_falta int;
  v_cod text;
begin
  perform exigir_permiso('inventario', 'editar');
  select * into pe from pedidos where id = p_pedido for update;
  if pe.id is null then raise exception 'Pedido no encontrado'; end if;
  if pe.estado <> 'abierto' then raise exception 'El pedido % está %', pe.consecutivo, pe.estado; end if;
  if jsonb_array_length(coalesce(p_lineas, '[]')) = 0 or not exists (select 1 from jsonb_array_elements(p_lineas) y where (y->>'cantidad')::int > 0) then
    raise exception 'El despacho no tiene prendas';
  end if;
  insert into despachos (pedido_id, cliente_id, observacion) values (pe.id, pe.cliente_id, nullif(trim(p_observacion), '')) returning * into v_des;
  for x in select * from jsonb_array_elements(p_lineas) where (value->>'cantidad')::int <> 0 loop
    if (x->>'cantidad')::int < 0 then raise exception 'Cantidades negativas no'; end if;
    perform 1 from skus where id = (x->>'sku_id')::uuid for update;
    v_cod := (select codigo from skus where id = (x->>'sku_id')::uuid);
    if v_cod is null then raise exception 'Producto no encontrado'; end if;
    select coalesce(sum(por_despachar), -1) into v_falta from pedido_despachos where pedido_id = pe.id and sku_id = (x->>'sku_id')::uuid;
    if v_falta < 0 then raise exception '% no está en el pedido %', v_cod, pe.consecutivo; end if;
    if (x->>'cantidad')::int > v_falta then
      raise exception '%: el pedido solo tiene % por despachar', v_cod, v_falta;
    end if;
    if saldo_producto((x->>'sku_id')::uuid, v_pt) < (x->>'cantidad')::int then
      raise exception '%: en producto terminado hay %', v_cod, saldo_producto((x->>'sku_id')::uuid, v_pt);
    end if;
    insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, despacho_id, documento)
    values ('despacho', (x->>'sku_id')::uuid, v_pt, -(x->>'cantidad')::int, v_des.id, v_des.consecutivo);
  end loop;
  return v_des.id;
end $$;

create or replace function public.anular_despacho(p_despacho uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare d despachos;
begin
  perform exigir_permiso('inventario', 'editar');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la anulación'; end if;
  select * into d from despachos where id = p_despacho for update;
  if d.id is null then raise exception 'Despacho no encontrado'; end if;
  if d.estado = 'anulado' then raise exception 'El despacho % ya está anulado', d.consecutivo; end if;
  insert into movimientos_producto (tipo, sku_id, bodega_id, cantidad, despacho_id, documento, motivo, anula_id)
  select 'anulacion', m.sku_id, m.bodega_id, -m.cantidad, m.despacho_id, d.consecutivo, trim(p_motivo), m.id
  from movimientos_producto m where m.despacho_id = d.id and m.tipo = 'despacho';
  update despachos set estado = 'anulado', motivo_anulacion = trim(p_motivo) where id = d.id;
end $$;

-- ---------------------------------------------------------------------
-- Informes de calidad
-- ---------------------------------------------------------------------
-- Eficacia (% de primera calidad) por operario, célula o satélite en un rango (fechas de Bogotá)
create or replace function public.informe_eficacia(p_desde date, p_hasta date, p_agrupar text default 'operario')
returns table (clave uuid, codigo text, nombre text, inspeccionadas int, defectuosas int, primera_calidad numeric,
               devoluciones int, entra int, segundas int, segundas_pct numeric, defecto_principal text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('calidad', 'ver') or public.puede('eficiencia', 'ver') or public.puede('procesos_externos', 'ver')
          or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  if p_agrupar not in ('operario','celula','satelite') then raise exception 'Agrupación inválida'; end if;
  return query
  with ins as (
    select i.* from inspecciones i
    where i.tipo <> 'anulacion' and not exists (select 1 from inspecciones a where a.anula_id = i.id)
      and (i.ocurrido_en_servidor at time zone 'America/Bogota')::date between p_desde and p_hasta
  ), def as (
    select d.*, i.paquete_id, i.juego_id from inspeccion_defectos d join ins i on i.id = d.inspeccion_id
  ), quien as (   -- quién trabajó en cada unidad inspeccionada
    select distinct i.id as inspeccion_id, i.tamano_muestra,
           case p_agrupar when 'operario' then m.empleado_id end as k
    from ins i join marcaciones m on (m.paquete_id = coalesce(i.paquete_id, i.juego_id) or m.juego_id = coalesce(i.juego_id, i.paquete_id))
      and m.tipo = 'normal' and not exists (select 1 from marcaciones a where a.anula_id = m.id)
    where p_agrupar = 'operario'
    union
    select distinct i.id, i.tamano_muestra, case p_agrupar when 'celula' then e.celula_id else e.satelite_id end
    from ins i join eventos_proceso e on (e.paquete_id = coalesce(i.paquete_id, i.juego_id) or e.juego_id = coalesce(i.juego_id, i.paquete_id))
      and e.tipo in ('avance','recepcion')
    where p_agrupar in ('celula','satelite') and case p_agrupar when 'celula' then e.celula_id else e.satelite_id end is not null
  ), base as (
    select k, sum(tamano_muestra)::int as insp from quien where k is not null group by k
  ), malos as (
    select case p_agrupar when 'operario' then empleado_id when 'celula' then celula_id else satelite_id end as k,
           sum(cantidad)::int as def
    from def group by 1
  ), dev as (
    select case p_agrupar when 'operario' then empleado_id when 'celula' then celula_id else satelite_id end as k, count(*)::int as n
    from devoluciones_calidad where estado <> 'anulada'
      and (creada_en at time zone 'America/Bogota')::date between p_desde and p_hasta group by 1
  ), seg as (
    select case p_agrupar when 'celula' then e.celula_id else e.satelite_id end as k, sum(e.entra)::int as entra, sum(e.segundas)::int as segundas
    from eventos_proceso e where p_agrupar in ('celula','satelite') and e.tipo = 'avance'
      and (coalesce(e.ocurrido_en_servidor, e.recibido_en) at time zone 'America/Bogota')::date between p_desde and p_hasta
    group by 1
  ), top as (
    select distinct on (k) k, nombre from (
      select case p_agrupar when 'operario' then d.empleado_id when 'celula' then d.celula_id else d.satelite_id end as k, df.nombre,
             sum(d.cantidad) as n
      from def d join defectos df on df.id = d.defecto_id group by 1, 2) z
    order by k, n desc
  ), claves as (
    select k from base union select k from malos union select k from seg where p_agrupar <> 'operario'
  )
  select c.k,
         coalesce(e.codigo, ce.codigo, sa.nit),
         coalesce(e.nombres || ' ' || e.apellidos, ce.nombre, sa.nombre),
         coalesce(b.insp, 0), coalesce(ma.def, 0),
         case when coalesce(b.insp, 0) > 0 then round(greatest(0, 1 - coalesce(ma.def, 0)::numeric / b.insp) * 100, 1) end,
         coalesce(dv.n, 0), coalesce(sg.entra, 0), coalesce(sg.segundas, 0),
         case when coalesce(sg.entra, 0) > 0 then round(sg.segundas::numeric / sg.entra * 100, 1) end,
         t.nombre
  from claves c
  left join base b on b.k = c.k
  left join malos ma on ma.k = c.k
  left join dev dv on dv.k = c.k
  left join seg sg on sg.k = c.k
  left join top t on t.k = c.k
  left join empleados e on p_agrupar = 'operario' and e.id = c.k
  left join celulas ce on p_agrupar = 'celula' and ce.id = c.k
  left join satelites sa on p_agrupar = 'satelite' and sa.id = c.k
  where c.k is not null
  order by 6 nulls last, 2;
end $$;

-- Defectos más frecuentes (Pareto)
create or replace function public.informe_defectos(p_desde date, p_hasta date)
returns table (defecto_id uuid, codigo text, nombre text, severidad text, cantidad int, porcentaje numeric, acumulado numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('calidad', 'ver') or public.es_conexion_directa()) then raise exception 'Sin permiso' using errcode = '42501'; end if;
  return query
  with x as (
    select d.defecto_id, sum(d.cantidad)::int as n from inspeccion_defectos d join inspecciones i on i.id = d.inspeccion_id
    where not exists (select 1 from inspecciones a where a.anula_id = i.id)
      and (i.ocurrido_en_servidor at time zone 'America/Bogota')::date between p_desde and p_hasta
    group by 1
  ), t as (select sum(n) as total from x)
  select x.defecto_id, df.codigo, df.nombre, df.severidad, x.n, round(x.n * 100.0 / t.total, 1),
         round(sum(x.n) over (order by x.n desc, df.codigo) * 100.0 / t.total, 1)
  from x join defectos df on df.id = x.defecto_id, t
  order by x.n desc, df.codigo;
end $$;

-- Calidad de una OP: auditorías, defectos y destino de lo producido
create or replace function public.op_calidad_resumen(p_op uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'auditorias', (select count(*) from inspecciones i where i.op_id = p_op and i.tipo = 'auditoria_final'
                     and not exists (select 1 from inspecciones a where a.anula_id = i.id)),
    'rechazadas', (select count(*) from inspecciones i where i.op_id = p_op and i.tipo = 'auditoria_final' and i.resultado = 'rechazado'
                     and not exists (select 1 from inspecciones a where a.anula_id = i.id)),
    'devoluciones_abiertas', (select count(*) from devoluciones_calidad where op_id = p_op and estado = 'abierta'),
    'producto_terminado', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_op'),
    'segundas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_segunda'))
$$;

-- ---------------------------------------------------------------------
-- Seguridad (RLS), ingesta y sincronización
-- ---------------------------------------------------------------------
select public.aplicar_estandar_maestro('defectos');
select public.aplicar_estandar_maestro('planes_muestreo');

create policy defectos_leer on public.defectos for select to authenticated using (public.es_interno());
create policy defectos_editar on public.defectos for all to authenticated using (public.puede('calidad','editar')) with check (public.puede('calidad','editar'));
create policy planes_leer on public.planes_muestreo for select to authenticated using (public.es_interno());
create policy planes_editar on public.planes_muestreo for all to authenticated using (public.puede('calidad','aprobar')) with check (public.puede('calidad','aprobar'));
create policy inspecciones_leer on public.inspecciones for select to authenticated using (public.es_interno());
create policy inspeccion_defectos_leer on public.inspeccion_defectos for select to authenticated using (public.es_interno());
create policy inspeccion_medidas_leer on public.inspeccion_medidas for select to authenticated using (public.es_interno());
create policy devoluciones_leer on public.devoluciones_calidad for select to authenticated using (public.es_interno());
create policy devolucion_cierres_leer on public.devolucion_cierres for select to authenticated using (public.es_interno());
create policy skus_leer on public.skus for select to authenticated using (public.es_interno());
create policy skus_editar on public.skus for update to authenticated
  using (public.puede('inventario','editar') or public.puede('comercial','editar') or public.puede('costos','editar'))
  with check (public.puede('inventario','editar') or public.puede('comercial','editar') or public.puede('costos','editar'));
create policy movimientos_producto_leer on public.movimientos_producto for select to authenticated using (public.es_interno());
create policy despachos_leer on public.despachos for select to authenticated using (public.es_interno());

insert into public.ingesta_manejadores values
  ('inspecciones', 'ingerir_inspeccion'),
  ('devolucion_cierres', 'ingerir_cierre_devolucion')
on conflict (tabla) do update set funcion = excluded.funcion;

do $$
declare t text;
begin
  foreach t in array array['defectos','planes_muestreo','inspecciones','devoluciones_calidad','ficha_medidas','ficha_medida_tallas']
  loop
    if not exists (select 1 from pg_publication_tables where pubname = 'powersync' and schemaname = 'public' and tablename = t) then
      execute format('alter publication powersync add table public.%I', t);
    end if;
  end loop;
end $$;

-- La terminación también marca operaciones (planchar, etiquetar, empacar)
insert into public.plantillas_etiqueta (tipo, tamano, nombre, zpl) values
  ('producto_terminado', '50x30', 'Prenda: código de barras, referencia, color y talla', '^XA
^CI28
^PW400
^LL240
^LH0,0
^FO20,16^A0N,26,26^FD{{referencia}}^FS
^FO20,46^A0N,20,20^FB360,1,0,L^FD{{nombre}}^FS
^FO20,74^A0N,36,36^FDT: {{talla}}^FS
^FO170,80^A0N,22,22^FB220,1,0,L^FD{{color}}^FS
^FO20,120^BY2^BCN,70,Y,N,N^FD{{codigo}}^FS
^PQ{{copias}}
^XZ')
on conflict do nothing;
