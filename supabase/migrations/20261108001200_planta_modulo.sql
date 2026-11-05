-- =====================================================================
-- Fase 6 · Migración 12: recorrido de paquetes y juegos por los procesos
-- y marcación de operaciones en la tablet del módulo (sin conexión).
-- Reglas: 2 (eventos inmutables, se anulan), 5 (entra = buenas + segundas
-- + faltantes), 10 (a confección solo van juegos completos o paquetes con
-- todas las partes).
--
-- "Unidad de trabajo" = lo que se escanea y recorre la planta:
--   * un paquete completo (el tendido trae todas las partes), o
--   * un juego (prenda combinada armada en corte).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Estado de las unidades de trabajo
-- ---------------------------------------------------------------------
alter table public.paquetes drop constraint paquetes_estado_check;
alter table public.paquetes add constraint paquetes_estado_check
  check (estado in ('cortado','en_proceso','en_espera','terminado','anulado'));
alter table public.paquetes
  add column proceso_actual  text references public.procesos(codigo),
  add column celula_id       uuid references public.celulas(id),
  add column cantidad_actual int;

alter table public.juegos drop constraint juegos_estado_check;
alter table public.juegos add constraint juegos_estado_check
  check (estado in ('armado','en_proceso','en_espera','terminado','anulado'));
alter table public.juegos
  add column proceso_actual  text references public.procesos(codigo),
  add column celula_id       uuid references public.celulas(id),
  add column cantidad_actual int,
  add column color_id        uuid references public.colores(id);   -- color de la parte principal (para mostrar)

-- Proceso que sigue a otro en la ruta de la OP (null = era el último)
create or replace function public.siguiente_proceso(p_op uuid, p_proceso text) returns text
language sql stable security definer set search_path = public as $$
  select p.proceso from op_procesos p
  where p.op_id = p_op and p.orden > (select orden from op_procesos where op_id = p_op and proceso = p_proceso)
  order by p.orden limit 1
$$;

-- Al nacer, la unidad queda esperando el proceso que sigue al corte
create or replace function public.fn_unidad_nueva() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.cantidad_actual := coalesce(new.cantidad_actual, new.cantidad);
  new.proceso_actual := coalesce(new.proceso_actual, siguiente_proceso(new.op_id, 'corte'));
  return new;
end $$;
create trigger paquetes_nuevo before insert on public.paquetes for each row execute function public.fn_unidad_nueva();
create trigger juegos_nuevo before insert on public.juegos for each row execute function public.fn_unidad_nueva();
create or replace function public.fn_juego_color() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.color_id := coalesce(new.color_id, (select cp.color_id from ficha_combinacion_partes cp join ficha_partes fp on fp.id = cp.parte_id
                                          where cp.combinacion_id = new.combinacion_id order by fp.orden limit 1));
  return new;
end $$;
create trigger juegos_color before insert on public.juegos for each row execute function public.fn_juego_color();
update public.juegos j set color_id = (select cp.color_id from public.ficha_combinacion_partes cp join public.ficha_partes fp on fp.id = cp.parte_id
                                        where cp.combinacion_id = j.combinacion_id order by fp.orden limit 1) where color_id is null;
update public.paquetes set cantidad_actual = cantidad, proceso_actual = siguiente_proceso(op_id, 'corte') where cantidad_actual is null;
update public.juegos set cantidad_actual = cantidad, proceso_actual = siguiente_proceso(op_id, 'corte') where cantidad_actual is null;

-- Vista: todo lo que se puede escanear en planta
create view public.unidades_trabajo with (security_invoker = true) as
select p.id, 'paquete'::text as tipo, p.codigo, p.op_id, p.color_id, null::uuid as combinacion_id, p.talla_id, p.cantidad,
       p.cantidad_actual, p.estado, p.proceso_actual, p.celula_id
from public.paquetes p where p.completo
union all
select j.id, 'juego', j.codigo, j.op_id, j.color_id, j.combinacion_id, j.talla_id, j.cantidad, j.cantidad_actual, j.estado, j.proceso_actual, j.celula_id
from public.juegos j;

-- Eventos de proceso por unidad: recepción (entra al módulo) y avance (sale)
alter table public.eventos_proceso drop constraint eventos_proceso_tipo_check;
alter table public.eventos_proceso add constraint eventos_proceso_tipo_check check (tipo in ('avance','anulacion','recepcion'));
alter table public.eventos_proceso
  add constraint eventos_proceso_paquete_fk foreign key (paquete_id) references public.paquetes(id),
  add column juego_id uuid references public.juegos(id),
  add column empleado_id uuid references public.empleados(id),
  add column ocurrido_en_servidor timestamptz;
create index on public.eventos_proceso (paquete_id);
create index on public.eventos_proceso (juego_id);

-- Marca el proceso como terminado cuando el anterior terminó y ya no queda
-- ninguna unidad de la OP por pasar por él; recalcula el estado de la OP.
create or replace function public.cerrar_proceso_si_corresponde(p_op uuid, p_proceso text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_orden int;
  v_ant op_procesos;
begin
  select orden into v_orden from op_procesos where op_id = p_op and proceso = p_proceso;
  select * into v_ant from op_procesos where op_id = p_op and orden < v_orden order by orden desc limit 1;
  if v_ant.op_id is not null and v_ant.estado <> 'terminado' then return; end if;
  if exists (select 1 from unidades_trabajo u join op_procesos p on p.op_id = u.op_id and p.proceso = u.proceso_actual
             where u.op_id = p_op and u.estado not in ('terminado','anulado') and p.orden <= v_orden) then
    return;
  end if;
  update op_procesos set estado = 'terminado', fin = coalesce(fin, now()) where op_id = p_op and proceso = p_proceso and estado <> 'terminado';
  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set
    estado = case when not exists (select 1 from op_procesos where op_id = p_op and estado <> 'terminado') then 'terminada' else 'en_proceso' end,
    proceso_actual = coalesce((select proceso from op_procesos where op_id = p_op and estado <> 'terminado' order by orden limit 1), proceso_actual)
  where id = p_op;
end $$;

-- Al terminar el corte se cierran en cadena los procesos que ya no tienen nada pendiente
create or replace function public.fn_proceso_terminado() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if new.estado = 'terminado' and old.estado <> 'terminado' then
    v := siguiente_proceso(new.op_id, new.proceso);
    if v is not null and (select estado from op_procesos where op_id = new.op_id and proceso = v) = 'en_proceso' then
      perform cerrar_proceso_si_corresponde(new.op_id, v);
    end if;
  end if;
  return new;
end $$;
create trigger op_procesos_terminado after update on public.op_procesos for each row execute function public.fn_proceso_terminado();

-- ---------------------------------------------------------------------
-- Recepción y entrega de una unidad en un proceso (lo usan la tablet y la web)
-- ---------------------------------------------------------------------
create or replace function public.buscar_unidad(p_codigo text, p_id uuid default null)
returns public.unidades_trabajo
language sql stable security definer set search_path = public as $$
  select * from unidades_trabajo where (p_id is not null and id = p_id) or (p_id is null and codigo = upper(trim(p_codigo))) limit 1
$$;

create or replace function public.aplicar_evento_unidad(
  p_id uuid, p_tipo text, p_unidad public.unidades_trabajo, p_proceso text, p_estacion uuid, p_celula uuid,
  p_buenas int, p_segundas int, p_faltantes int, p_observacion text, p_empleado uuid, p_dispositivo uuid,
  p_ocurrido timestamptz, p_ocurrido_servidor timestamptz, p_satelite uuid default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  pr op_procesos;
  v_sig text;
  v_n int;
  v_paquete uuid := case when p_unidad.tipo = 'paquete' then p_unidad.id end;
  v_juego uuid := case when p_unidad.tipo = 'juego' then p_unidad.id end;
begin
  if exists (select 1 from eventos_proceso where id = p_id) then return false; end if;
  if p_unidad.id is null then raise exception 'Paquete o juego no encontrado'; end if;
  select * into o from ordenes_produccion where id = p_unidad.op_id for update;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La % está %', o.consecutivo, replace(o.estado, '_', ' '); end if;
  select * into pr from op_procesos where op_id = o.id and proceso = p_proceso;
  if pr.op_id is null then raise exception 'La ruta de la % no tiene %', o.consecutivo, p_proceso; end if;
  if p_unidad.estado in ('anulado','terminado') then raise exception '% está %', p_unidad.codigo, p_unidad.estado; end if;

  perform set_config('app.op_sistema', 'si', true);
  if p_tipo = 'recepcion' then
    if p_unidad.estado = 'en_proceso' and p_unidad.proceso_actual = p_proceso then
      raise exception '% ya se recibió en %', p_unidad.codigo, (select nombre from procesos where codigo = p_proceso);
    end if;
    if p_unidad.proceso_actual is distinct from p_proceso then
      raise exception '% va para %, no para %', p_unidad.codigo,
        coalesce((select nombre from procesos where codigo = p_unidad.proceso_actual), '—'), (select nombre from procesos where codigo = p_proceso);
    end if;
    insert into eventos_proceso (id, op_id, proceso, tipo, paquete_id, juego_id, estacion_id, celula_id, satelite_id, entra, buenas,
                                 observacion, empleado_id, dispositivo_id, ocurrido_en, ocurrido_en_servidor)
    values (p_id, o.id, p_proceso, 'recepcion', v_paquete, v_juego, p_estacion, p_celula, p_satelite, p_unidad.cantidad_actual, p_unidad.cantidad_actual,
            p_observacion, p_empleado, p_dispositivo, p_ocurrido, p_ocurrido_servidor);
    if v_paquete is not null then
      update paquetes set estado = 'en_proceso', celula_id = p_celula where id = v_paquete;
    else
      update juegos set estado = 'en_proceso', celula_id = p_celula where id = v_juego;
    end if;
    update op_procesos set estado = case when estado = 'pendiente' then 'en_proceso' else estado end, inicio = coalesce(inicio, p_ocurrido_servidor)
     where op_id = o.id and proceso = p_proceso;
    update ordenes_produccion set estado = 'en_proceso', primera_marcacion = coalesce(primera_marcacion, p_ocurrido_servidor) where id = o.id;

  elsif p_tipo = 'entrega' then
    if p_unidad.estado <> 'en_proceso' or p_unidad.proceso_actual <> p_proceso then
      raise exception '% no está en % (primero se recibe)', p_unidad.codigo, (select nombre from procesos where codigo = p_proceso);
    end if;
    if coalesce(p_buenas, -1) < 0 or coalesce(p_segundas, 0) < 0 or coalesce(p_faltantes, 0) < 0
       or p_buenas + coalesce(p_segundas, 0) + coalesce(p_faltantes, 0) <> p_unidad.cantidad_actual then
      raise exception 'Las cantidades no cuadran: entraron %, buenas + segundas + faltantes = %', p_unidad.cantidad_actual,
        coalesce(p_buenas, 0) + coalesce(p_segundas, 0) + coalesce(p_faltantes, 0);
    end if;
    insert into eventos_proceso (id, op_id, proceso, tipo, paquete_id, juego_id, estacion_id, celula_id, satelite_id, entra, buenas, segundas, faltantes,
                                 observacion, empleado_id, dispositivo_id, ocurrido_en, ocurrido_en_servidor)
    values (p_id, o.id, p_proceso, 'avance', v_paquete, v_juego, p_estacion, p_celula, p_satelite, p_unidad.cantidad_actual, p_buenas,
            coalesce(p_segundas, 0), coalesce(p_faltantes, 0), p_observacion, p_empleado, p_dispositivo, p_ocurrido, p_ocurrido_servidor);
    v_sig := siguiente_proceso(o.id, p_proceso);
    if v_paquete is not null then
      update paquetes set estado = case when v_sig is null or p_buenas = 0 then 'terminado' else 'en_espera' end,
             proceso_actual = coalesce(v_sig, proceso_actual), cantidad_actual = p_buenas, celula_id = null where id = v_paquete;
    else
      update juegos set estado = case when v_sig is null or p_buenas = 0 then 'terminado' else 'en_espera' end,
             proceso_actual = coalesce(v_sig, proceso_actual), cantidad_actual = p_buenas, celula_id = null where id = v_juego;
    end if;
    update op_procesos set entra = entra + p_unidad.cantidad_actual, buenas = buenas + p_buenas, segundas = segundas + coalesce(p_segundas, 0),
           faltantes = faltantes + coalesce(p_faltantes, 0), estado = case when estado = 'pendiente' then 'en_proceso' else estado end,
           inicio = coalesce(inicio, p_ocurrido_servidor)
     where op_id = o.id and proceso = p_proceso;
    update ordenes_produccion set ultima_marcacion = greatest(coalesce(ultima_marcacion, p_ocurrido_servidor), p_ocurrido_servidor) where id = o.id;
    perform cerrar_proceso_si_corresponde(o.id, p_proceso);
  else
    raise exception 'Tipo de evento inválido: %', p_tipo;
  end if;
  get diagnostics v_n = row_count;
  return true;
end $$;
revoke all on function public.aplicar_evento_unidad(uuid, text, public.unidades_trabajo, text, uuid, uuid, int, int, int, text, uuid, uuid, timestamptz, timestamptz, uuid)
  from public, anon, authenticated;

-- Desde la web (jefe de producción): recibir o entregar a mano
create or replace function public.mover_unidad(p_codigo text, p_tipo text, p_proceso text, p_celula uuid default null,
                                               p_buenas int default null, p_segundas int default 0, p_faltantes int default 0,
                                               p_observacion text default null)
returns void language plpgsql security definer set search_path = public as $$
declare u unidades_trabajo;
begin
  perform exigir_permiso('op', 'editar');
  u := buscar_unidad(p_codigo);
  perform aplicar_evento_unidad(gen_random_uuid(), p_tipo, u, p_proceso, null, p_celula, p_buenas, p_segundas, p_faltantes,
                                p_observacion, null, null, now(), now());
end $$;

-- Ingesta desde la tablet: tabla local "eventos_unidad"
-- datos = {unidad_id, tipo: recepcion|entrega, buenas, segundas, faltantes, empleado_id, observacion, ocurrido_en}
create or replace function public.ingerir_evento_unidad(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  e estaciones;
  v_hora timestamptz := hora_evento(p_datos, p_desfase);
begin
  select * into e from estaciones where id = p_disp.estacion_id;
  if e.proceso is null then raise exception 'La estación % no tiene proceso', e.codigo; end if;
  return aplicar_evento_unidad(p_id, p_datos->>'tipo', buscar_unidad(null, (p_datos->>'unidad_id')::uuid), e.proceso, e.id, e.celula_id,
                               (p_datos->>'buenas')::int, (p_datos->>'segundas')::int, (p_datos->>'faltantes')::int,
                               p_datos->>'observacion', (p_datos->>'empleado_id')::uuid, p_disp.id,
                               (p_datos->>'ocurrido_en')::timestamptz, v_hora);
end $$;
revoke all on function public.ingerir_evento_unidad(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Marcaciones de operaciones (E)
-- ---------------------------------------------------------------------
insert into public.parametros (clave, valor, descripcion) values
  ('max_minutos_entre_marcaciones', '30', 'Si entre dos marcaciones del operario pasan más minutos, la segunda no cuenta para la eficiencia (pausa, almuerzo)')
on conflict (clave) do nothing;

create table public.marcaciones (
  id                  uuid primary key,                       -- generado en la tablet
  tipo                text not null default 'normal' check (tipo in ('normal','reproceso','anulacion')),
  anula_id            uuid unique references public.marcaciones(id),
  motivo              text,
  empleado_id         uuid not null references public.empleados(id),
  estacion_id         uuid references public.estaciones(id),
  celula_id           uuid references public.celulas(id),
  dispositivo_id      uuid references public.dispositivos(id),
  op_id               uuid not null references public.ordenes_produccion(id),
  paquete_id          uuid references public.paquetes(id),
  juego_id            uuid references public.juegos(id),
  ficha_operacion_id  uuid not null references public.ficha_operaciones(id),
  proceso             text not null references public.procesos(codigo),
  talla_id            uuid references public.tallas(id),
  color_id            uuid references public.colores(id),
  unidades            int not null check (unidades > 0),
  sam                 numeric(8,4) not null,
  minutos_esperados   numeric(10,3) not null,
  minutos_reales      numeric(10,3),                          -- desde la marcación anterior del operario (oficial)
  eficiencia          numeric(8,2),                           -- % = esperados / reales
  excede_unidad       boolean not null default false,         -- marcó más de lo que trae el paquete
  usuario_id          uuid default auth.uid(),
  ocurrido_en         timestamptz not null,
  ocurrido_en_servidor timestamptz not null,
  recibido_en         timestamptz not null default now(),
  check ((tipo = 'anulacion') = (anula_id is not null)),
  check (tipo <> 'anulacion' or coalesce(trim(motivo), '') <> ''),
  check (paquete_id is not null or juego_id is not null)
);
create index on public.marcaciones (empleado_id, ocurrido_en_servidor);
create index on public.marcaciones (op_id);
create index on public.marcaciones (paquete_id, ficha_operacion_id);
create index on public.marcaciones (juego_id, ficha_operacion_id);
select public.aplicar_estandar_evento('marcaciones');

-- Eficiencia por operario y día (Bogotá): la suma de lo esperado y lo real
create table public.eficiencia_diaria (
  empleado_id       uuid not null references public.empleados(id),
  fecha             date not null,
  unidades          int not null default 0,
  reprocesos        int not null default 0,
  minutos_esperados numeric(12,3) not null default 0,       -- solo de marcaciones con tiempo real
  minutos_reales    numeric(12,3) not null default 0,
  primary key (empleado_id, fecha)
);
alter table public.eficiencia_diaria enable row level security;

-- Minutos reales = desde la marcación anterior del mismo operario el mismo día
-- (si pasaron más de max_minutos_entre_marcaciones, no se mide).
create or replace function public.fn_marcacion_oficial() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ant timestamptz;
  v_max numeric := coalesce((select (valor #>> '{}')::numeric from parametros where clave = 'max_minutos_entre_marcaciones'), 30);
  v_min numeric;
begin
  if new.tipo = 'anulacion' then return new; end if;
  select max(m.ocurrido_en_servidor) into v_ant from marcaciones m
  where m.empleado_id = new.empleado_id and m.tipo <> 'anulacion' and m.ocurrido_en_servidor < new.ocurrido_en_servidor
    and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date = (new.ocurrido_en_servidor at time zone 'America/Bogota')::date
    and not exists (select 1 from marcaciones a where a.anula_id = m.id);
  if v_ant is not null then
    v_min := extract(epoch from new.ocurrido_en_servidor - v_ant) / 60;
    if v_min > 0 and v_min <= v_max then
      new.minutos_reales := round(v_min, 3);
      new.eficiencia := round(new.minutos_esperados / new.minutos_reales * 100, 2);   -- igual que la tablet: con los minutos ya redondeados
    end if;
  end if;
  return new;
end $$;
create trigger marcaciones_oficial before insert on public.marcaciones for each row execute function public.fn_marcacion_oficial();

create or replace function public.fn_marcacion_eficiencia() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m marcaciones := new;
  v_signo int := 1;
begin
  if new.tipo = 'anulacion' then
    select * into m from marcaciones where id = new.anula_id;
    v_signo := -1;
  end if;
  insert into eficiencia_diaria as d (empleado_id, fecha, unidades, reprocesos, minutos_esperados, minutos_reales)
  values (m.empleado_id, (m.ocurrido_en_servidor at time zone 'America/Bogota')::date,
          v_signo * case when m.tipo = 'normal' then m.unidades else 0 end,
          v_signo * case when m.tipo = 'reproceso' then m.unidades else 0 end,
          v_signo * case when m.minutos_reales is not null then m.minutos_esperados else 0 end,
          v_signo * coalesce(m.minutos_reales, 0))
  on conflict (empleado_id, fecha) do update set
    unidades = d.unidades + excluded.unidades, reprocesos = d.reprocesos + excluded.reprocesos,
    minutos_esperados = d.minutos_esperados + excluded.minutos_esperados, minutos_reales = d.minutos_reales + excluded.minutos_reales;
  return new;
end $$;
create trigger marcaciones_eficiencia after insert on public.marcaciones for each row execute function public.fn_marcacion_eficiencia();

-- Ingesta: tabla local "marcaciones"
-- datos = {empleado_id, unidad_id, ficha_operacion_id, unidades, tipo, anula_id, motivo, ocurrido_en}
create or replace function public.ingerir_marcacion(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_hora timestamptz := hora_evento(p_datos, p_desfase);
  v_tipo text := coalesce(p_datos->>'tipo', 'normal');
  u unidades_trabajo;
  fo ficha_operaciones;
  o ordenes_produccion;
  e estaciones;
  orig marcaciones;
  v_unid int := coalesce((p_datos->>'unidades')::int, 1);
  v_sam numeric;
  v_hechas int;
  v_n int;
begin
  if exists (select 1 from marcaciones where id = p_id) then return false; end if;
  select * into e from estaciones where id = p_disp.estacion_id;
  if v_tipo = 'anulacion' then
    select * into orig from marcaciones where id = (p_datos->>'anula_id')::uuid;
    if orig.id is null then raise exception 'La marcación a anular no existe'; end if;
    insert into marcaciones (id, tipo, anula_id, motivo, empleado_id, estacion_id, celula_id, dispositivo_id, op_id, paquete_id, juego_id,
                             ficha_operacion_id, proceso, talla_id, color_id, unidades, sam, minutos_esperados, ocurrido_en, ocurrido_en_servidor)
    values (p_id, 'anulacion', orig.id, coalesce(nullif(trim(p_datos->>'motivo'), ''), 'Anulada en la tablet'), orig.empleado_id, e.id,
            e.celula_id, p_disp.id, orig.op_id, orig.paquete_id, orig.juego_id, orig.ficha_operacion_id, orig.proceso, orig.talla_id,
            orig.color_id, orig.unidades, orig.sam, orig.minutos_esperados, (p_datos->>'ocurrido_en')::timestamptz, v_hora)
    on conflict (id) do nothing;
    return true;
  end if;

  if not exists (select 1 from empleados where id = (p_datos->>'empleado_id')::uuid and activo) then
    raise exception 'Operario inexistente o inactivo';
  end if;
  u := buscar_unidad(null, (p_datos->>'unidad_id')::uuid);
  if u.id is null then raise exception 'Paquete o juego no encontrado'; end if;
  if u.estado = 'anulado' then raise exception '% está anulado', u.codigo; end if;
  select * into o from ordenes_produccion where id = u.op_id;
  select * into fo from ficha_operaciones where id = (p_datos->>'ficha_operacion_id')::uuid;
  if fo.id is null or fo.ficha_id <> o.ficha_version_id then raise exception 'La operación no es de la ficha de la %', o.consecutivo; end if;
  if v_tipo not in ('normal','reproceso') then raise exception 'Tipo de marcación inválido'; end if;

  v_sam := case when v_tipo = 'reproceso' then coalesce(fo.sam_reproceso, fo.sam) else fo.sam end;
  select coalesce(sum(m.unidades), 0) into v_hechas from marcaciones m
   where m.ficha_operacion_id = fo.id and m.tipo = 'normal' and (m.paquete_id = u.id or m.juego_id = u.id)
     and not exists (select 1 from marcaciones a where a.anula_id = m.id);

  insert into marcaciones (id, tipo, empleado_id, estacion_id, celula_id, dispositivo_id, op_id, paquete_id, juego_id, ficha_operacion_id,
                           proceso, talla_id, color_id, unidades, sam, minutos_esperados, excede_unidad, ocurrido_en, ocurrido_en_servidor)
  values (p_id, v_tipo, (p_datos->>'empleado_id')::uuid, e.id, e.celula_id, p_disp.id, o.id,
          case when u.tipo = 'paquete' then u.id end, case when u.tipo = 'juego' then u.id end, fo.id, fo.proceso, u.talla_id, u.color_id,
          v_unid, v_sam, round(v_sam * fo.repeticiones * v_unid, 3),
          v_tipo = 'normal' and v_hechas + v_unid > u.cantidad_actual, (p_datos->>'ocurrido_en')::timestamptz, v_hora)
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  -- sin conexión no se pierde nada: si se pasó de lo que trae el paquete se acepta y se avisa
  if v_n = 1 and v_tipo = 'normal' and v_hechas + v_unid > u.cantidad_actual then
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
    values ('marcacion_excede', 'media', 'marcaciones', p_id::text,
            format('%s: se marcaron %s de "%s" y el paquete trae %s', u.codigo, v_hechas + v_unid,
                   (select nombre from operaciones where id = fo.operacion_id), u.cantidad_actual),
            jsonb_build_object('op_id', o.id, 'unidad_id', u.id, 'empleado_id', p_datos->>'empleado_id'));
  end if;
  update ordenes_produccion set primera_marcacion = coalesce(primera_marcacion, v_hora),
         ultima_marcacion = greatest(coalesce(ultima_marcacion, v_hora), v_hora) where id = o.id and v_n = 1;
  return v_n = 1;
end $$;
revoke all on function public.ingerir_marcacion(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;

insert into public.ingesta_manejadores values
  ('marcaciones', 'ingerir_marcacion'),
  ('eventos_unidad', 'ingerir_evento_unidad')
on conflict (tabla) do update set funcion = excluded.funcion;

-- Avance por operación de cada unidad (para la web)
create view public.avance_unidad_operacion with (security_invoker = true) as
select coalesce(m.paquete_id, m.juego_id) as unidad_id, m.op_id, m.ficha_operacion_id,
       sum(m.unidades) filter (where m.tipo = 'normal')::int as hechas,
       sum(m.unidades) filter (where m.tipo = 'reproceso')::int as reprocesos
from public.marcaciones m
where m.tipo <> 'anulacion' and not exists (select 1 from public.marcaciones a where a.anula_id = m.id)
group by 1, 2, 3;

-- ---------------------------------------------------------------------
-- RLS y publicación para PowerSync
-- ---------------------------------------------------------------------
create policy marcaciones_leer on public.marcaciones for select to authenticated using (public.es_interno());
create policy eficiencia_leer on public.eficiencia_diaria for select to authenticated using (public.es_interno());

alter publication powersync add table
  public.ordenes_produccion, public.referencias, public.ficha_operaciones, public.operaciones, public.ficha_combinaciones,
  public.paquetes, public.juegos, public.eficiencia_diaria;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.marcaciones, public.juegos, public.eventos_proceso;
  end if;
end $$;
