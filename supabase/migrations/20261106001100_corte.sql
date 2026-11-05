-- =====================================================================
-- Fase 5 · Migración 11: corte.
-- Tendidos normales y por espigas (2 a 5 secciones), corte de un color,
-- multicolor y de prenda combinada; paquetes, juegos y piezas sueltas.
-- Reglas: 1 (salida de tela con OP), 2 (anulación con eventos inversos),
-- 3 (stock = kardex), 6 (todo o nada), 8 (lote de tintura y ancho),
-- 9 (paquete sin mezclar color, lote ni talla), 10 (solo juegos completos).
--
-- El cálculo oficial es corte_calcular_bloque / corte_plan_paquetes. La app
-- hace las mismas cuentas en Dart (lib/core/calculos/corte.dart); ambos se
-- prueban con los casos de test_vectores/corte.
-- =====================================================================

insert into public.consecutivos (tipo, prefijo) values ('CRT','CRT'), ('JG','JG') on conflict (tipo) do nothing;

-- Códigos por estación (PQ-C01-000001): cada mesa lleva su contador, así una
-- tablet sin conexión podrá numerar sus paquetes sin chocar con otra (Fase 6).
create or replace function public.siguiente_consecutivo_estacion(p_estacion uuid, p_tipo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_n bigint; v_cod text;
begin
  select codigo into v_cod from estaciones where id = p_estacion;
  if v_cod is null then raise exception 'Estación no encontrada'; end if;
  insert into consecutivos_estacion (estacion_id, tipo, ultimo) values (p_estacion, p_tipo, 1)
  on conflict (estacion_id, tipo) do update set ultimo = consecutivos_estacion.ultimo + 1
  returning ultimo into v_n;
  return p_tipo || '-' || v_cod || '-' || lpad(v_n::text, 6, '0');
end $$;

-- ---------------------------------------------------------------------
-- Trazos guardados (plantillas reutilizables por referencia)
-- secciones: [{letra, largo_m, unidades: {talla_id: n}}]  (1 = normal, 2–5 = espigas)
-- ---------------------------------------------------------------------
create table public.trazos (
  id            uuid primary key default gen_random_uuid(),
  referencia_id uuid not null references public.referencias(id),
  nombre        text not null,
  material_id   uuid references public.materiales(id),
  partes        text[] not null default '{}',          -- nombres de las partes (sirven para cualquier versión de ficha)
  tallas        jsonb not null default '[]',
  secciones     jsonb not null check (jsonb_typeof(secciones) = 'array' and jsonb_array_length(secciones) between 1 and 5),
  ancho_cm      numeric(6,1),
  eficiencia_pct numeric(5,2),
  observacion   text,
  activo        boolean not null default true,
  unique (referencia_id, nombre)
);

-- ---------------------------------------------------------------------
-- Cortes. Mientras está en borrador el documento (jsonb) se edita libre;
-- al confirmar se calcula en el servidor y se normaliza en tablas.
-- documento = {bloques: [{id, nombre, material_id, partes: [parte_id],
--   tallas: [talla_id], secciones: [...], tramos: [{rollo_id, color_id, espiga, capas}]}],
--   rollos: {rollo_id: {fin: vuelve|retazo|agotado, restante_m}}}
-- ---------------------------------------------------------------------
create table public.cortes (
  id                uuid primary key default gen_random_uuid(),
  consecutivo       text not null unique default public.siguiente_consecutivo('CRT'),
  op_id             uuid not null references public.ordenes_produccion(id),
  tipo              text not null default 'un_color' check (tipo in ('un_color','multicolor','combinada')),
  estado            text not null default 'borrador' check (estado in ('borrador','confirmado','anulado')),
  estacion_id       uuid references public.estaciones(id),
  cortador_id       uuid references public.empleados(id),
  despunte_cm       numeric(5,2) not null default 2 check (despunte_cm >= 0 and despunte_cm <= 50),
  documento         jsonb not null default '{"bloques": [], "rollos": {}}',
  resultado         jsonb,
  observacion       text,
  confirmado_en     timestamptz,
  confirmado_por    uuid references public.perfiles(id),
  evento_avance_id  uuid references public.eventos_proceso(id),
  motivo_anulacion  text,
  anulado_en        timestamptz,
  anulado_por       uuid references public.perfiles(id)
);
create index on public.cortes (op_id, estado);

-- Solo las funciones cambian un corte confirmado
create or replace function public.fn_corte_protegido() returns trigger
language plpgsql as $$
begin
  if current_setting('app.corte_sistema', true) = 'si' or public.es_conexion_directa() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then raise exception 'Un corte no se borra: se anula'; end if;
  if old.estado <> 'borrador' or new.estado <> old.estado then
    raise exception 'El corte % está % y solo cambia con sus funciones', old.consecutivo, old.estado;
  end if;
  return new;
end $$;
create trigger cortes_protegido before update or delete on public.cortes
  for each row execute function public.fn_corte_protegido();

-- Rollos usados en cada corte confirmado (foto con lote, tono y ancho)
create table public.corte_rollos (
  id               uuid primary key default gen_random_uuid(),
  corte_id         uuid not null references public.cortes(id),
  op_id            uuid not null references public.ordenes_produccion(id),
  rollo_id         uuid not null references public.rollos(id),
  material_id      uuid not null references public.materiales(id),
  color_id         uuid not null references public.colores(id),
  lote_tintura     text not null,
  tono             text,
  ancho_cm         numeric(6,1) not null,
  capas            int not null,
  metros_tendido   numeric(12,2) not null,
  metros_consumo   numeric(12,2) not null,
  kilos_consumo    numeric(12,3) not null,
  cantidad         numeric(14,3) not null,                 -- unidad del material
  fin              text not null check (fin in ('vuelve','retazo','agotado')),
  retazo_id        uuid references public.rollos(id),
  vigente          boolean not null default true           -- false si el corte se anuló
);
create index on public.corte_rollos (op_id, material_id, color_id) where vigente;

-- Piezas cortadas por bloque, color y talla
create table public.corte_resultados (
  corte_id    uuid not null references public.cortes(id),
  bloque_id   text not null,
  material_id uuid not null references public.materiales(id),
  partes      uuid[] not null,
  color_id    uuid not null references public.colores(id),
  talla_id    uuid not null references public.tallas(id),
  piezas      int not null,
  primary key (corte_id, bloque_id, color_id, talla_id)
);

-- Consumo real vs teórico por material y color en el corte
create table public.corte_consumos (
  corte_id      uuid not null references public.cortes(id),
  material_id   uuid not null references public.materiales(id),
  color_id      uuid not null references public.colores(id),
  piezas        int not null,
  teorico       numeric(14,3) not null,
  real          numeric(14,3) not null,
  desviacion_pct numeric(8,2),
  primary key (corte_id, material_id, color_id)
);

-- Regla 8: autorización del jefe de corte para mezclar lotes/tonos o anchos (E)
create table public.corte_autorizaciones (
  id             uuid primary key default gen_random_uuid(),
  corte_id       uuid not null references public.cortes(id),
  material_id    uuid not null references public.materiales(id),
  color_id       uuid not null references public.colores(id),
  motivo         text not null check (trim(motivo) <> ''),
  detalle        jsonb,
  usuario_id     uuid default auth.uid() references public.perfiles(id),
  dispositivo_id uuid references public.dispositivos(id),
  ocurrido_en    timestamptz not null default now(),
  recibido_en    timestamptz not null default now(),
  unique (corte_id, material_id, color_id)
);
select public.aplicar_estandar_evento('corte_autorizaciones');

-- Paquetes: un solo color, lote y talla; máximo max_prendas_paquete (regla 9)
create table public.paquetes (
  id           uuid primary key default gen_random_uuid(),
  codigo       text not null unique check (codigo like 'PQ-%'),
  op_id        uuid not null references public.ordenes_produccion(id),
  corte_id     uuid not null references public.cortes(id),
  bloque_id    text not null,
  material_id  uuid not null references public.materiales(id),
  partes       uuid[] not null,
  completo     boolean not null,        -- trae todas las partes de la prenda (no necesita juego)
  color_id     uuid not null references public.colores(id),
  lote_tintura text not null,
  talla_id     uuid not null references public.tallas(id),
  espiga       int not null default 1,
  capa_desde   int not null,
  capa_hasta   int not null,
  cantidad     int not null check (cantidad > 0),
  estado       text not null default 'cortado' check (estado in ('cortado','anulado')),   -- la Fase 6 agrega los de proceso
  check (capa_hasta >= capa_desde)
);
create index on public.paquetes (op_id, estado);
create index on public.paquetes (corte_id);

-- Juegos: prendas completas de una combinación y talla (regla 10)
create table public.juegos (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique default public.siguiente_consecutivo('JG'),
  op_id          uuid not null references public.ordenes_produccion(id),
  combinacion_id uuid not null references public.ficha_combinaciones(id),
  talla_id       uuid not null references public.tallas(id),
  cantidad       int not null check (cantidad > 0),
  estado         text not null default 'armado' check (estado in ('armado','anulado')),
  evento_avance_id uuid references public.eventos_proceso(id)
);
create index on public.juegos (op_id);

create table public.juego_componentes (
  juego_id   uuid not null references public.juegos(id),
  paquete_id uuid not null references public.paquetes(id),
  parte_id   uuid not null references public.ficha_partes(id),
  cantidad   int not null check (cantidad > 0),
  primary key (juego_id, paquete_id, parte_id)
);

-- Piezas sin juego (sueltas) por paquete y parte
create view public.piezas_saldo with (security_invoker = true) as
select p.id as paquete_id, p.codigo, p.op_id, p.corte_id, x.parte_id, p.material_id, p.color_id, p.lote_tintura, p.talla_id, p.completo,
       p.cantidad, p.cantidad - coalesce((select sum(j.cantidad) from public.juego_componentes j join public.juegos g on g.id = j.juego_id
                                          where j.paquete_id = p.id and j.parte_id = x.parte_id and g.estado <> 'anulado'), 0)::int as saldo
from public.paquetes p cross join lateral unnest(p.partes) x(parte_id)
where p.estado = 'cortado';

-- ---------------------------------------------------------------------
-- Cálculo oficial (espejo exacto de lib/core/calculos/corte.dart)
-- ---------------------------------------------------------------------
-- Piezas de una talla por capa en la espiga k: suma de las secciones 1..n−k+1
create or replace function public.corte_piezas_por_capa(p_bloque jsonb, p_espiga int, p_talla text) returns int
language sql immutable as $$
  select coalesce(sum((s.value -> 'unidades' ->> p_talla)::int), 0)::int
  from jsonb_array_elements(p_bloque -> 'secciones') with ordinality s(value, i)
  where s.i <= jsonb_array_length(p_bloque -> 'secciones') - p_espiga + 1
$$;

create or replace function public.corte_largo_espiga(p_bloque jsonb, p_espiga int) returns numeric
language sql immutable as $$
  select coalesce(sum((s.value ->> 'largo_m')::numeric), 0)
  from jsonb_array_elements(p_bloque -> 'secciones') with ordinality s(value, i)
  where s.i <= jsonb_array_length(p_bloque -> 'secciones') - p_espiga + 1
$$;

-- Tramos en orden de tendido (espiga 1 primero) con la numeración de capas
create or replace function public.corte_tramos(p_bloque jsonb)
returns table (orden int, rollo_id text, color_id text, lote text, espiga int, capas int, capa_desde int, capa_hasta int)
language sql immutable as $$
  with t as (
    select x.value as v, x.i from jsonb_array_elements(coalesce(p_bloque -> 'tramos', '[]')) with ordinality x(value, i)
    where coalesce((x.value ->> 'capas')::int, 0) > 0
  ), o as (
    select row_number() over (order by coalesce((v ->> 'espiga')::int, 1), i)::int as orden,
           v ->> 'rollo_id' as rollo_id, v ->> 'color_id' as color_id, v ->> 'lote' as lote,
           coalesce((v ->> 'espiga')::int, 1) as espiga, (v ->> 'capas')::int as capas
    from t
  )
  select orden, rollo_id, color_id, lote, espiga, capas,
         (sum(capas) over (order by orden) - capas + 1)::int, (sum(capas) over (order by orden))::int
  from o order by orden
$$;

create or replace function public.corte_calcular_bloque(p_bloque jsonb, p_despunte numeric default 0) returns jsonb
language plpgsql immutable as $$
declare
  v_n int := coalesce(jsonb_array_length(p_bloque -> 'secciones'), 0);
  v_capas int[];
  v_piezas jsonb := '{}';
  v_rollo jsonb := '{}';
  v_tramos jsonb := '[]';
  v_metros numeric := 0;
  v_m numeric;
  t record;
  v_talla text;
  v_u int;
  v_col jsonb;
begin
  if v_n < 1 or v_n > 5 then raise exception 'El trazo debe tener de 1 a 5 secciones'; end if;
  if exists (select 1 from jsonb_array_elements(p_bloque -> 'secciones') s where coalesce((s ->> 'largo_m')::numeric, 0) <= 0) then
    raise exception 'Cada sección del trazo necesita su largo en metros';
  end if;
  v_capas := array_fill(0, array[v_n]);
  for t in select * from corte_tramos(p_bloque) loop
    if t.espiga < 1 or t.espiga > v_n then raise exception 'La espiga % no existe en un trazo de % secciones', t.espiga, v_n; end if;
    v_capas[t.espiga] := v_capas[t.espiga] + t.capas;
    v_m := round(t.capas * (corte_largo_espiga(p_bloque, t.espiga) + coalesce(p_despunte, 0) / 100), 2);
    v_metros := v_metros + v_m;
    v_rollo := jsonb_set(v_rollo, array[t.rollo_id], to_jsonb(round(coalesce((v_rollo ->> t.rollo_id)::numeric, 0) + v_m, 2)));
    v_col := coalesce(v_piezas -> t.color_id, '{}');
    for v_talla in select jsonb_array_elements_text(coalesce(p_bloque -> 'tallas', '[]')) loop
      v_u := corte_piezas_por_capa(p_bloque, t.espiga, v_talla);
      if v_u > 0 then
        v_col := jsonb_set(v_col, array[v_talla], to_jsonb(coalesce((v_col ->> v_talla)::int, 0) + t.capas * v_u));
      end if;
    end loop;
    v_piezas := jsonb_set(v_piezas, array[t.color_id], v_col);
    v_tramos := v_tramos || jsonb_build_object('rollo_id', t.rollo_id, 'color_id', t.color_id, 'lote', t.lote, 'espiga', t.espiga,
                                               'capas', t.capas, 'capa_desde', t.capa_desde, 'capa_hasta', t.capa_hasta, 'metros', v_m);
  end loop;
  return jsonb_build_object(
    'metros', round(v_metros, 2),
    'capas_espiga', to_jsonb(v_capas),
    'capas_seccion', (select jsonb_agg((select coalesce(sum(c), 0) from unnest(v_capas[1:v_n - i + 1]) c) order by i)
                      from generate_series(1, v_n) i),
    'piezas', v_piezas,
    'metros_por_rollo', v_rollo,
    'tramos', v_tramos);
end $$;

-- Paquetes del bloque: corridas de capas con el mismo color, lote y espiga;
-- por talla, rangos de capas de hasta p_max piezas.
create or replace function public.corte_plan_paquetes(p_bloque jsonb, p_max int default 20)
returns table (orden int, color_id text, lote text, espiga int, talla text, capa_desde int, capa_hasta int, cantidad int)
language plpgsql immutable as $$
#variable_conflict use_column
declare
  c record;
  v_talla text;
  v_p int;
  v_cpp int;
  v_desde int;
  v_hasta int;
  v_ord int := 0;
begin
  for c in
    with t as (
      select x.*, case when lag(x.color_id) over w is not distinct from x.color_id and lag(x.lote) over w is not distinct from x.lote
                        and lag(x.espiga) over w = x.espiga and lag(x.capa_hasta) over w + 1 = x.capa_desde then 0 else 1 end as nuevo
      from corte_tramos(p_bloque) x window w as (order by x.orden)
    ), g as (select t.*, sum(t.nuevo) over (order by t.orden) as grupo from t)
    select min(g.orden) as o, g.color_id as col, g.lote as lot, g.espiga as esp, min(g.capa_desde) as desde, max(g.capa_hasta) as hasta
    from g group by g.grupo, g.color_id, g.lote, g.espiga order by 1
  loop
    for v_talla in select jsonb_array_elements_text(coalesce(p_bloque -> 'tallas', '[]')) loop
      v_p := corte_piezas_por_capa(p_bloque, c.esp, v_talla);
      continue when v_p <= 0;
      v_cpp := greatest(1, p_max / v_p);
      v_desde := c.desde;
      while v_desde <= c.hasta loop
        v_hasta := least(c.hasta, v_desde + v_cpp - 1);
        v_ord := v_ord + 1;
        orden := v_ord; color_id := c.col; lote := c.lot; espiga := c.esp; talla := v_talla;
        capa_desde := v_desde; capa_hasta := v_hasta; cantidad := (v_hasta - v_desde + 1) * v_p;
        return next;
        v_desde := v_hasta + 1;
      end loop;
    end loop;
  end loop;
end $$;

-- Consumo estándar por prenda de un material en unas partes (con merma)
create or replace function public.corte_consumo_bom(p_ficha uuid, p_material uuid, p_partes uuid[], p_talla uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(x.consumo), 0) from (
    select distinct on (b.parte_id) bc.consumo * (1 + b.merma_pct / 100) as consumo
    from ficha_bom b join ficha_bom_consumos bc on bc.bom_id = b.id and bc.talla_id = p_talla
    where b.ficha_id = p_ficha and b.material_id = p_material and b.parte_id = any(p_partes)
    order by b.parte_id, b.combinacion_id nulls first) x
$$;

-- ---------------------------------------------------------------------
-- Borrador
-- ---------------------------------------------------------------------
-- p: {id?, op_id, tipo, estacion_id, cortador_id, despunte_cm, observacion, documento}
create or replace function public.guardar_corte(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_corte cortes;
  o ordenes_produccion;
  v_doc jsonb := coalesce(p -> 'documento', '{"bloques": [], "rollos": {}}');
  b jsonb;
begin
  perform exigir_permiso('corte', 'editar');
  if v_id is not null then
    select * into v_corte from cortes where id = v_id for update;
  end if;
  if v_corte.id is not null and v_corte.estado <> 'borrador' then
    raise exception 'El corte % ya está %', v_corte.consecutivo, v_corte.estado;
  end if;
  select * into o from ordenes_produccion where id = coalesce(v_corte.op_id, (p ->> 'op_id')::uuid);
  if o.id is null then raise exception 'Elija la OP'; end if;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La % está %: no se puede cortar', o.consecutivo, replace(o.estado, '_', ' '); end if;
  if not exists (select 1 from op_procesos where op_id = o.id and proceso = 'corte') then
    raise exception 'La ruta de la % no tiene corte', o.consecutivo;
  end if;
  if nullif(p ->> 'estacion_id', '') is not null
     and not exists (select 1 from estaciones where id = (p ->> 'estacion_id')::uuid and tipo = 'mesa_corte') then
    raise exception 'La estación elegida no es una mesa de corte';
  end if;
  if jsonb_typeof(v_doc -> 'bloques') is distinct from 'array' then raise exception 'Documento de corte inválido'; end if;
  -- el borrador puede estar incompleto; solo se valida la forma del trazo (el resto al confirmar)
  for b in select * from jsonb_array_elements(v_doc -> 'bloques') loop
    if coalesce(jsonb_array_length(b -> 'secciones'), 0) not between 1 and 5 then
      raise exception 'El trazo de "%" debe tener de 1 a 5 secciones', coalesce(b ->> 'nombre', '?');
    end if;
    if exists (select 1 from jsonb_array_elements(coalesce(b -> 'tramos', '[]')) t
               where coalesce((t ->> 'espiga')::int, 1) not between 1 and jsonb_array_length(b -> 'secciones')) then
      raise exception 'En "%" hay capas en una espiga que el trazo no tiene', coalesce(b ->> 'nombre', '?');
    end if;
  end loop;

  perform set_config('app.corte_sistema', 'si', true);
  if v_corte.id is null then
    insert into cortes (id, op_id, tipo, estacion_id, cortador_id, despunte_cm, observacion, documento)
    values (coalesce(v_id, gen_random_uuid()), o.id, coalesce(p ->> 'tipo', 'un_color'), nullif(p ->> 'estacion_id', '')::uuid,
            nullif(p ->> 'cortador_id', '')::uuid, coalesce((p ->> 'despunte_cm')::numeric, 2), p ->> 'observacion', v_doc)
    returning id into v_id;
  else
    update cortes set tipo = coalesce(p ->> 'tipo', tipo), estacion_id = nullif(p ->> 'estacion_id', '')::uuid,
           cortador_id = nullif(p ->> 'cortador_id', '')::uuid, despunte_cm = coalesce((p ->> 'despunte_cm')::numeric, despunte_cm),
           observacion = p ->> 'observacion', documento = v_doc
     where id = v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Regla 8: en una OP, un mismo material y color debe venir del mismo lote de
-- tintura y tono, y los anchos no pueden diferir más de tolerancia_ancho_cm.
-- Revisa los rollos de este corte junto con los de los cortes ya confirmados.
-- ---------------------------------------------------------------------
create or replace function public.corte_verificar_lotes(p_corte uuid)
returns table (material_id uuid, color_id uuid, lotes text[], tonos text[], ancho_min numeric, ancho_max numeric,
               mezcla_lotes boolean, excede_ancho boolean, autorizado boolean, mensaje text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_corte cortes;
  v_tol numeric := coalesce((select (valor #>> '{}')::numeric from parametros where clave = 'tolerancia_ancho_cm'), 2);
begin
  select * into v_corte from cortes where id = p_corte;
  return query
  with usados as (
    select r.material_id, r.color_id, r.lote_tintura, coalesce(r.tono, '') as tono, r.ancho_real_cm as ancho
    from cortes c
    cross join lateral jsonb_array_elements(c.documento -> 'bloques') b
    cross join lateral jsonb_array_elements(coalesce(b -> 'tramos', '[]')) t
    join rollos r on r.id = (t ->> 'rollo_id')::uuid
    where c.id = p_corte and c.estado = 'borrador' and coalesce((t ->> 'capas')::int, 0) > 0
    union all
    select cr.material_id, cr.color_id, cr.lote_tintura, coalesce(cr.tono, ''), cr.ancho_cm
    from corte_rollos cr where cr.op_id = v_corte.op_id and cr.vigente
  ), g as (
    select u.material_id, u.color_id, array_agg(distinct u.lote_tintura) as lotes, array_agg(distinct u.tono) as tonos,
           min(u.ancho) as amin, max(u.ancho) as amax
    from usados u group by u.material_id, u.color_id
  )
  select g.material_id, g.color_id, g.lotes, g.tonos, g.amin, g.amax,
         cardinality(g.lotes) > 1 or cardinality(g.tonos) > 1, g.amax - g.amin > v_tol,
         exists (select 1 from corte_autorizaciones a where a.corte_id = p_corte and a.material_id = g.material_id and a.color_id = g.color_id),
         format('%s %s: ', m.nombre, co.nombre) || concat_ws(' y ',
           case when cardinality(g.lotes) > 1 or cardinality(g.tonos) > 1 then
             format('lotes %s (tonos %s)', array_to_string(g.lotes, ', '), array_to_string(array_remove(g.tonos, ''), ', ')) end,
           case when g.amax - g.amin > v_tol then
             format('anchos de %s a %s cm (máximo %s cm de diferencia)', g.amin, g.amax, v_tol) end)
  from g join materiales m on m.id = g.material_id join colores co on co.id = g.color_id
  where cardinality(g.lotes) > 1 or cardinality(g.tonos) > 1 or g.amax - g.amin > v_tol;
end $$;

create or replace function public.autorizar_corte(p_corte uuid, p_material uuid, p_color uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_corte cortes; v_det jsonb;
begin
  if not public.puede('corte', 'aprobar') and not public.es_conexion_directa() then
    raise exception 'Solo el jefe de corte (permiso de aprobar en Corte) autoriza mezclar lotes o anchos' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la autorización'; end if;
  select * into v_corte from cortes where id = p_corte;
  if v_corte.estado is distinct from 'borrador' then raise exception 'Solo se autoriza un corte en borrador'; end if;
  select to_jsonb(x) into v_det from corte_verificar_lotes(p_corte) x where x.material_id = p_material and x.color_id = p_color;
  if v_det is null then raise exception 'Ese material y color no necesitan autorización'; end if;
  insert into corte_autorizaciones (corte_id, material_id, color_id, motivo, detalle)
  values (p_corte, p_material, p_color, trim(p_motivo), v_det)
  on conflict (corte_id, material_id, color_id) do nothing
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Confirmar: cálculo oficial, salida de tela por rollo (kardex), liberación
-- de la reserva, retazos, paquetes y desviación de consumo. Todo o nada.
-- ---------------------------------------------------------------------
create or replace function public.confirmar_corte(p_corte uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_corte cortes;
  o ordenes_produccion;
  v_doc jsonb;
  b jsonb;
  v_bloque jsonb;
  v_calc jsonb;
  v_calculos jsonb := '[]';
  v_partes uuid[];
  v_todas uuid[];
  v_material materiales;
  r rollos;
  x record;
  p record;
  v_rollos jsonb := '{}';      -- rollo_id → metros tendidos (todos los bloques)
  v_capas jsonb := '{}';
  v_fin text;
  v_restante numeric;
  v_m numeric;
  v_kg numeric;
  v_cant numeric;
  v_retazo rollos;
  v_max int := coalesce((select (valor #>> '{}')::int from parametros where clave = 'max_prendas_paquete'), 20);
  v_tol numeric := coalesce((select (valor #>> '{}')::numeric from parametros where clave = 'tolerancia_desviacion_corte_pct'), 5);
  v_paquetes int := 0;
  v_completas int := 0;
  v_falta numeric;
  v_libera numeric;
  v_alertas int := 0;
  v_evento uuid;
begin
  perform exigir_permiso('corte', 'editar');
  select * into v_corte from cortes where id = p_corte for update;
  if v_corte.id is null then raise exception 'Corte no encontrado'; end if;
  if v_corte.estado <> 'borrador' then raise exception 'El corte % ya está %', v_corte.consecutivo, v_corte.estado; end if;
  select * into o from ordenes_produccion where id = v_corte.op_id for update;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La % está %', o.consecutivo, replace(o.estado, '_', ' '); end if;
  if (select estado from op_procesos where op_id = o.id and proceso = 'corte') = 'terminado' then
    raise exception 'El corte de la % ya se terminó', o.consecutivo;
  end if;
  if v_corte.estacion_id is null then raise exception 'Elija la mesa de corte'; end if;
  v_doc := v_corte.documento;
  if coalesce(jsonb_array_length(v_doc -> 'bloques'), 0) = 0 then raise exception 'El corte no tiene tendidos'; end if;
  select array_agg(id) into v_todas from ficha_partes where ficha_id = o.ficha_version_id;

  -- 1. Validar cada bloque y completar el lote de cada tramo desde el rollo
  for b in select * from jsonb_array_elements(v_doc -> 'bloques') loop
    -- un tendido sin capas se ignora (p. ej. el cuello se corta después en otro corte)
    continue when not exists (select 1 from jsonb_array_elements(coalesce(b -> 'tramos', '[]')) t where coalesce((t ->> 'capas')::int, 0) > 0);
    select * into v_material from materiales where id = nullif(b ->> 'material_id', '')::uuid;
    if v_material.id is null or v_material.tipo <> 'tela' then raise exception 'El tendido "%" no tiene tela', coalesce(b ->> 'nombre', '?'); end if;
    v_partes := array(select jsonb_array_elements_text(coalesce(b -> 'partes', '[]'))::uuid);
    if cardinality(v_partes) = 0 then raise exception 'El tendido "%" no dice qué partes corta', coalesce(b ->> 'nombre', v_material.nombre); end if;
    if exists (select 1 from unnest(v_partes) pa where pa <> all(v_todas)) then raise exception 'Hay partes que no son de la ficha de la OP'; end if;
    for x in select fp.nombre from unnest(v_partes) pa join ficha_partes fp on fp.id = pa
             where not exists (select 1 from ficha_bom fb where fb.ficha_id = o.ficha_version_id and fb.parte_id = pa and fb.material_id = v_material.id)
               and not exists (select 1 from ficha_combinacion_partes cp join op_cantidades oc on oc.combinacion_id = cp.combinacion_id and oc.op_id = o.id
                               where cp.parte_id = pa and cp.material_id = v_material.id) loop
      raise exception 'La parte % no lleva % según la ficha', x.nombre, v_material.nombre;
    end loop;
    if exists (select 1 from jsonb_array_elements_text(coalesce(b -> 'tallas', '[]')) t
               where t::uuid not in (select talla_id from ficha_tallas where ficha_id = o.ficha_version_id)) then
      raise exception 'El trazo "%" tiene tallas que no están en la ficha', coalesce(b ->> 'nombre', v_material.nombre);
    end if;

    v_bloque := jsonb_set(b, '{tramos}', coalesce((
      select jsonb_agg(t || jsonb_build_object('lote', ro.lote_tintura) order by i)
      from jsonb_array_elements(coalesce(b -> 'tramos', '[]')) with ordinality tt(t, i)
      left join rollos ro on ro.id = (t ->> 'rollo_id')::uuid), '[]'));

    for x in select (t ->> 'rollo_id')::uuid as rollo_id, (t ->> 'color_id')::uuid as color_id, ro.id as existe, ro.material_id,
                    ro.color_id as color_rollo, ro.codigo, ro.estado, bo.tipo as tipo_bodega
             from jsonb_array_elements(coalesce(b -> 'tramos', '[]')) t
             left join rollos ro on ro.id = (t ->> 'rollo_id')::uuid left join bodegas bo on bo.id = ro.bodega_id
             where coalesce((t ->> 'capas')::int, 0) > 0 loop
      if x.existe is null then raise exception 'Hay un rollo que no existe en el tendido "%"', coalesce(b ->> 'nombre', v_material.nombre); end if;
      if x.material_id <> v_material.id then raise exception 'El rollo % no es de %', x.codigo, v_material.nombre; end if;
      if x.color_rollo <> x.color_id then raise exception 'El rollo % es de otro color', x.codigo; end if;
      if x.estado = 'agotado' then raise exception 'El rollo % está agotado', x.codigo; end if;
      if x.tipo_bodega not in ('telas') then raise exception 'El rollo % no está en una bodega de telas', x.codigo; end if;
      -- el color debe ser el de esas partes en alguna combinación de la OP
      if exists (select 1 from unnest(v_partes) pa where not exists (
                   select 1 from ficha_combinacion_partes cp join op_cantidades oc on oc.combinacion_id = cp.combinacion_id and oc.op_id = o.id
                   where cp.parte_id = pa and cp.color_id = x.color_id)) then
        raise exception 'El color del rollo % no se usa en esas partes en ninguna combinación de la %', x.codigo, o.consecutivo;
      end if;
    end loop;
    if v_corte.tipo = 'un_color' and (select count(distinct t ->> 'color_id') from jsonb_array_elements(coalesce(b -> 'tramos', '[]')) t
                                      where coalesce((t ->> 'capas')::int, 0) > 0) > 1 then
      raise exception 'Un corte de un color no puede tender varios colores en "%": use corte multicolor', coalesce(b ->> 'nombre', v_material.nombre);
    end if;

    v_calc := corte_calcular_bloque(v_bloque, v_corte.despunte_cm);
    v_calculos := v_calculos || jsonb_build_object('bloque', v_bloque, 'calculo', v_calc, 'partes', to_jsonb(v_partes),
                                                   'material_id', v_material.id, 'completo', v_todas <@ v_partes);
    for x in select key, value from jsonb_each(v_calc -> 'metros_por_rollo') loop
      v_rollos := jsonb_set(v_rollos, array[x.key], to_jsonb(coalesce((v_rollos ->> x.key)::numeric, 0) + (x.value #>> '{}')::numeric));
    end loop;
    for x in select t.rollo_id, sum(t.capas) as capas from corte_tramos(v_bloque) t group by t.rollo_id loop
      v_capas := jsonb_set(v_capas, array[x.rollo_id], to_jsonb(coalesce((v_capas ->> x.rollo_id)::int, 0) + x.capas));
    end loop;
  end loop;

  if jsonb_array_length(v_calculos) = 0 then raise exception 'El corte no tiene capas: ingrese los rollos y las capas de cada tendido'; end if;

  -- 2. Regla 8 (lotes, tonos y anchos)
  for x in select * from corte_verificar_lotes(p_corte) where not autorizado loop
    raise exception 'Regla de lotes: %. El jefe de corte debe autorizarlo con un motivo.', x.mensaje;
  end loop;

  perform set_config('app.corte_sistema', 'si', true);
  perform set_config('app.op_sistema', 'si', true);

  -- 3. Salida de tela por rollo (en la unidad del material)
  for x in select key::uuid as rollo_id, (value #>> '{}')::numeric as metros from jsonb_each(v_rollos) loop
    select * into r from rollos where id = x.rollo_id for update;
    select * into v_material from materiales where id = r.material_id;
    v_fin := coalesce(v_doc -> 'rollos' -> x.rollo_id::text ->> 'fin', 'vuelve');
    if v_fin not in ('vuelve','retazo','agotado') then raise exception 'Fin de rollo inválido: %', v_fin; end if;
    v_restante := nullif(v_doc -> 'rollos' -> x.rollo_id::text ->> 'restante_m', '')::numeric;
    if v_restante is not null and (v_restante < 0 or v_restante > r.metros_saldo) then
      raise exception 'Lo que queda del rollo % (% m) no puede ser mayor que su saldo (% m)', r.codigo, v_restante, r.metros_saldo;
    end if;
    -- consumo: lo medido (saldo − lo que quedó) o, si no se midió, lo tendido
    v_m := case when v_fin = 'agotado' then r.metros_saldo
                when v_restante is not null then r.metros_saldo - v_restante
                else x.metros end;
    if x.metros > r.metros_saldo * 1.03 + 0.01 then
      raise exception 'El rollo % tiene % m y el tendido necesita % m', r.codigo, r.metros_saldo, x.metros;
    end if;
    v_m := least(v_m, r.metros_saldo);
    v_kg := case when v_m >= r.metros_saldo then r.kilos_saldo
                 when r.metros_saldo > 0 then round(v_m * r.kilos_saldo / r.metros_saldo, 3)
                 else round(v_m / nullif(v_material.rendimiento_m_kg, 0), 3) end;
    v_cant := case v_material.unidad when 'kg' then v_kg else v_m end;
    insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                        costo_unitario, op_id, documento_tipo, documento_id, motivo)
    values ('salida_op', r.material_id, r.color_id, r.id, r.bodega_id, r.ubicacion_id, -v_cant, -v_m, -v_kg,
            r.costo_unitario, o.id, 'corte', v_corte.consecutivo, 'Corte ' || v_corte.consecutivo);

    v_retazo := null;
    if v_fin = 'retazo' then
      select * into r from rollos where id = x.rollo_id;
      if r.metros_saldo <= 0 then raise exception 'Del rollo % no queda nada para retazo', r.codigo; end if;
      insert into rollos (codigo, material_id, color_id, proveedor_id, lote_tintura, tono, ancho_real_cm, metros_iniciales, kilos_iniciales,
                          costo_unitario, bodega_id, ubicacion_id, estado, es_retazo, rollo_origen_id, observacion)
      values (siguiente_consecutivo('TL'), r.material_id, r.color_id, r.proveedor_id, r.lote_tintura, r.tono, r.ancho_real_cm,
              r.metros_saldo, r.kilos_saldo, r.costo_unitario, r.bodega_id,
              coalesce((select id from ubicaciones where bodega_id = r.bodega_id and codigo like '%RET%' order by codigo limit 1), r.ubicacion_id),
              'retazo', true, r.id, 'Retazo del corte ' || v_corte.consecutivo)
      returning * into v_retazo;
      insert into movimientos_inventario (tipo, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                          costo_unitario, documento_tipo, documento_id, motivo)
      values ('traslado', r.material_id, r.color_id, r.id, r.bodega_id, r.ubicacion_id,
              -(case v_material.unidad when 'kg' then r.kilos_saldo else r.metros_saldo end), -r.metros_saldo, -r.kilos_saldo,
              r.costo_unitario, 'corte', v_corte.consecutivo, 'Retazo ' || v_retazo.codigo),
             ('traslado', r.material_id, r.color_id, v_retazo.id, v_retazo.bodega_id, v_retazo.ubicacion_id,
              case v_material.unidad when 'kg' then r.kilos_saldo else r.metros_saldo end, r.metros_saldo, r.kilos_saldo,
              r.costo_unitario, 'corte', v_corte.consecutivo, 'Retazo de ' || r.codigo);
      select * into v_retazo from rollos where id = v_retazo.id;
    end if;

    select * into r from rollos where id = x.rollo_id;
    insert into corte_rollos (corte_id, op_id, rollo_id, material_id, color_id, lote_tintura, tono, ancho_cm, capas, metros_tendido,
                              metros_consumo, kilos_consumo, cantidad, fin, retazo_id)
    values (p_corte, o.id, r.id, r.material_id, r.color_id, r.lote_tintura, r.tono, r.ancho_real_cm,
            coalesce((v_capas ->> x.rollo_id::text)::int, 0), x.metros, v_m, v_kg, v_cant, v_fin, v_retazo.id);
  end loop;

  -- 4. Liberar la reserva de la OP por lo consumido y registrar el consumo
  for x in select cr.material_id, cr.color_id, sum(cr.cantidad) as cantidad from corte_rollos cr where cr.corte_id = p_corte
           group by cr.material_id, cr.color_id loop
    v_falta := x.cantidad;
    for p in select * from reservado_op(o.id) rv where rv.material_id = x.material_id and rv.color_id is not distinct from x.color_id
             order by (rv.bodega_id in (select ro.bodega_id from corte_rollos cr join rollos ro on ro.id = cr.rollo_id where cr.corte_id = p_corte)) desc,
                      rv.reservado desc loop
      exit when v_falta <= 0;
      v_libera := least(v_falta, p.reservado);
      insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id, motivo)
      values ('liberacion', 'reservado', x.material_id, x.color_id, p.bodega_id, -v_libera, o.id, 'corte', v_corte.consecutivo,
              'Consumido en el corte ' || v_corte.consecutivo);
      v_falta := v_falta - v_libera;
    end loop;
    update op_necesidades n set consumido = n.consumido + x.cantidad,
           reservado = (select coalesce(sum(rv.reservado), 0) from reservado_op(o.id) rv where rv.material_id = x.material_id and rv.color_id is not distinct from x.color_id)
     where n.op_id = o.id and n.material_id = x.material_id and n.color_id is not distinct from x.color_id;
  end loop;

  -- 5. Resultados, paquetes y consumo teórico vs real
  for x in select * from jsonb_array_elements(v_calculos) e(v) loop
    for p in select c.key as color, t.key as talla, (t.value #>> '{}')::int as piezas
             from jsonb_each(x.v -> 'calculo' -> 'piezas') c, jsonb_each(c.value) t loop
      insert into corte_resultados (corte_id, bloque_id, material_id, partes, color_id, talla_id, piezas)
      values (p_corte, coalesce(x.v -> 'bloque' ->> 'id', md5(x.v ->> 'bloque')), (x.v ->> 'material_id')::uuid,
              array(select jsonb_array_elements_text(x.v -> 'partes')::uuid), p.color::uuid, p.talla::uuid, p.piezas);
    end loop;
    for p in select * from corte_plan_paquetes(x.v -> 'bloque', v_max) order by orden loop
      insert into paquetes (codigo, op_id, corte_id, bloque_id, material_id, partes, completo, color_id, lote_tintura, talla_id,
                            espiga, capa_desde, capa_hasta, cantidad)
      values (siguiente_consecutivo_estacion(v_corte.estacion_id, 'PQ'), o.id, p_corte, coalesce(x.v -> 'bloque' ->> 'id', md5(x.v ->> 'bloque')),
              (x.v ->> 'material_id')::uuid, array(select jsonb_array_elements_text(x.v -> 'partes')::uuid), (x.v ->> 'completo')::boolean,
              p.color_id::uuid, p.lote, p.talla::uuid, p.espiga, p.capa_desde, p.capa_hasta, p.cantidad);
      v_paquetes := v_paquetes + 1;
      if (x.v ->> 'completo')::boolean then v_completas := v_completas + p.cantidad; end if;
    end loop;
  end loop;

  insert into corte_consumos (corte_id, material_id, color_id, piezas, teorico, real, desviacion_pct)
  select p_corte, t.material_id, t.color_id, t.piezas, t.teorico, coalesce(rr.real, 0),
         case when t.teorico > 0 then round((coalesce(rr.real, 0) - t.teorico) / t.teorico * 100, 2) end
  from (
    select cr.material_id, cr.color_id, sum(cr.piezas)::int as piezas,
           round(sum(cr.piezas * corte_consumo_bom(o.ficha_version_id, cr.material_id, cr.partes, cr.talla_id)), 3) as teorico
    from corte_resultados cr where cr.corte_id = p_corte group by cr.material_id, cr.color_id
  ) t
  left join (select material_id, color_id, sum(cantidad) as real from corte_rollos where corte_id = p_corte group by 1, 2) rr
    on rr.material_id = t.material_id and rr.color_id = t.color_id;

  for x in select cc.*, m.nombre as material, co.nombre as color, m.unidad from corte_consumos cc
           join materiales m on m.id = cc.material_id join colores co on co.id = cc.color_id
           where cc.corte_id = p_corte and abs(cc.desviacion_pct) > v_tol loop
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje, datos)
    values ('desviacion_corte', case when abs(x.desviacion_pct) > v_tol * 2 then 'alta' else 'media' end, 'cortes', p_corte::text,
            format('Corte %s (%s): %s %s consumió %s %s frente a %s estándar (%s%s %%)', v_corte.consecutivo, o.consecutivo, x.material, x.color,
                   x.real, x.unidad, x.teorico, case when x.desviacion_pct > 0 then '+' else '' end, x.desviacion_pct),
            jsonb_build_object('op_id', o.id, 'material_id', x.material_id, 'color_id', x.color_id, 'desviacion_pct', x.desviacion_pct));
    v_alertas := v_alertas + 1;
  end loop;

  -- 6. Avance de corte por las prendas que salen completas del tendido
  if v_completas > 0 then
    v_evento := registrar_avance(o.id, 'corte', v_completas, v_completas, 0, 0, false, 'Corte ' || v_corte.consecutivo);
  end if;

  update cortes set estado = 'confirmado', confirmado_en = now(), confirmado_por = auth.uid(), evento_avance_id = v_evento,
         resultado = jsonb_build_object('bloques', v_calculos, 'paquetes', v_paquetes, 'prendas_completas', v_completas, 'alertas', v_alertas)
   where id = p_corte;
  return jsonb_build_object('paquetes', v_paquetes, 'prendas_completas', v_completas, 'alertas_desviacion', v_alertas);
end $$;

-- ---------------------------------------------------------------------
-- Juegos (regla 10): por combinación y talla se toma de cada parte el color
-- de esa combinación. Primero se cubre lo pedido en la OP (en el orden de las
-- combinaciones) y luego lo que sobre. Un juego nunca mezcla lotes de la parte
-- principal (la primera de la ficha). Si p_escribir = false solo simula.
-- ---------------------------------------------------------------------
create or replace function public.corte_asignar_juegos(p_op uuid, p_escribir boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  v_principal uuid;
  v_max int := coalesce((select (valor #>> '{}')::int from parametros where clave = 'max_prendas_paquete'), 20);
  c record;
  pa record;
  q record;
  v_pasada int;
  v_meta int;
  v_hechos int;
  v_pos int;
  v_n int;
  v_resto int;
  v_toma int;
  v_juego uuid;
  v_total int := 0;
  v_filas jsonb := '[]';
  v_faltan jsonb;
begin
  select * into o from ordenes_produccion where id = p_op;
  select id into v_principal from ficha_partes where ficha_id = o.ficha_version_id order by orden, nombre limit 1;

  if to_regclass('pg_temp._piezas') is not null then drop table pg_temp._piezas; end if;
  create temp table _piezas on commit drop as
  select s.paquete_id, s.codigo, s.parte_id, s.color_id, s.material_id, s.lote_tintura, s.talla_id, s.saldo
  from piezas_saldo s where s.op_id = p_op and not s.completo and s.saldo > 0;

  for v_pasada in 1..2 loop
    for c in select oc.combinacion_id, oc.talla_id, oc.cantidad, fc.codigo as comb, t.codigo as talla
             from op_cantidades oc join ficha_combinaciones fc on fc.id = oc.combinacion_id join tallas t on t.id = oc.talla_id
             left join ficha_tallas ft on ft.ficha_id = o.ficha_version_id and ft.talla_id = oc.talla_id
             where oc.op_id = p_op order by fc.orden, fc.codigo, ft.orden loop
      select coalesce(sum(j.cantidad), 0) into v_hechos from juegos j
       where j.op_id = p_op and j.combinacion_id = c.combinacion_id and j.talla_id = c.talla_id and j.estado <> 'anulado';
      -- juegos posibles: lo mínimo entre las partes
      select min(coalesce(d.saldo, 0)) into v_pos from (
        select fp.id, (select sum(z.saldo) from _piezas z
                        where z.parte_id = fp.id and z.color_id = cp.color_id and z.talla_id = c.talla_id
                          and (cp.material_id is null or z.material_id = cp.material_id)) as saldo
        from ficha_partes fp join ficha_combinacion_partes cp on cp.combinacion_id = c.combinacion_id and cp.parte_id = fp.id
        where fp.ficha_id = o.ficha_version_id) d;
      v_pos := coalesce(v_pos, 0);
      v_meta := case when v_pasada = 1 then greatest(0, c.cantidad - v_hechos) else v_pos end;
      v_n := least(v_pos, v_meta);

      if v_pasada = 1 then
        -- qué falta de cada parte para completar lo pedido
        select coalesce(jsonb_agg(jsonb_build_object('parte', d.nombre, 'parte_id', d.id, 'color_id', d.color_id, 'faltan', v_meta - d.saldo)), '[]')
          into v_faltan
        from (select fp.id, fp.nombre, cp.color_id, coalesce((select sum(z.saldo) from _piezas z
                        where z.parte_id = fp.id and z.color_id = cp.color_id and z.talla_id = c.talla_id
                          and (cp.material_id is null or z.material_id = cp.material_id)), 0)::int as saldo
              from ficha_partes fp join ficha_combinacion_partes cp on cp.combinacion_id = c.combinacion_id and cp.parte_id = fp.id
              where fp.ficha_id = o.ficha_version_id order by fp.orden) d
        where d.saldo < v_meta;
        v_filas := v_filas || jsonb_build_object('combinacion_id', c.combinacion_id, 'combinacion', c.comb, 'talla_id', c.talla_id,
                     'talla', c.talla, 'pedido', c.cantidad, 'hechos', v_hechos, 'posibles', v_pos, 'arma', v_n,
                     'faltan', v_faltan);
      elsif v_n > 0 then
        v_filas := jsonb_set(v_filas, array[(select (i - 1)::text from jsonb_array_elements(v_filas) with ordinality f(v, i)
                                                  where f.v ->> 'combinacion_id' = c.combinacion_id::text and f.v ->> 'talla_id' = c.talla_id::text)],
                             (select f.v from jsonb_array_elements(v_filas) f(v) where f.v ->> 'combinacion_id' = c.combinacion_id::text
                                and f.v ->> 'talla_id' = c.talla_id::text) || jsonb_build_object('extra', v_n));
      end if;

      -- armar: bloques de la parte principal (un paquete a la vez → sin mezclar lote)
      v_resto := v_n;
      while v_resto > 0 loop
        select z.* into q from _piezas z join ficha_combinacion_partes cp on cp.combinacion_id = c.combinacion_id and cp.parte_id = z.parte_id
         where z.parte_id = v_principal and z.color_id = cp.color_id and z.talla_id = c.talla_id and z.saldo > 0
           and (cp.material_id is null or z.material_id = cp.material_id)
         order by z.codigo limit 1;
        exit when q.paquete_id is null;
        v_toma := least(v_resto, q.saldo, v_max);
        v_juego := null;
        if p_escribir then
          insert into juegos (op_id, combinacion_id, talla_id, cantidad) values (p_op, c.combinacion_id, c.talla_id, v_toma) returning id into v_juego;
        end if;
        -- cada parte: del mismo paquete si lo trae (p. ej. cuerpo y mangas juntos), si no en orden de código
        for pa in select fp.id, cp.color_id, cp.material_id from ficha_partes fp
                  join ficha_combinacion_partes cp on cp.combinacion_id = c.combinacion_id and cp.parte_id = fp.id
                  where fp.ficha_id = o.ficha_version_id order by fp.orden loop
          declare v_falta int := v_toma; z record;
          begin
            for z in select * from _piezas y where y.parte_id = pa.id and y.color_id = pa.color_id and y.talla_id = c.talla_id and y.saldo > 0
                       and (pa.material_id is null or y.material_id = pa.material_id)
                     order by (y.paquete_id = q.paquete_id) desc, y.codigo loop
              exit when v_falta <= 0;
              if p_escribir then
                insert into juego_componentes (juego_id, paquete_id, parte_id, cantidad) values (v_juego, z.paquete_id, pa.id, least(v_falta, z.saldo));
              end if;
              update _piezas set saldo = saldo - least(v_falta, z.saldo) where paquete_id = z.paquete_id and parte_id = pa.id;
              v_falta := v_falta - least(v_falta, z.saldo);
            end loop;
            if v_falta > 0 then raise exception 'Error interno al armar juegos (faltan % piezas)', v_falta; end if;
          end;
        end loop;
        v_resto := v_resto - v_toma;
        v_total := v_total + v_toma;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object('juegos', v_total, 'detalle', v_filas,
    'sueltas', coalesce((select jsonb_agg(jsonb_build_object('parte_id', z.parte_id, 'parte', fp.nombre, 'color_id', z.color_id, 'color', co.nombre,
                                                             'talla_id', z.talla_id, 'talla', t.codigo, 'cantidad', z.cantidad) order by fp.orden, co.nombre, t.orden)
                         from (select parte_id, color_id, talla_id, sum(saldo)::int as cantidad from _piezas group by 1, 2, 3 having sum(saldo) > 0) z
                         join ficha_partes fp on fp.id = z.parte_id join colores co on co.id = z.color_id join tallas t on t.id = z.talla_id), '[]'));
end $$;
revoke all on function public.corte_asignar_juegos(uuid, boolean) from public, anon, authenticated;

create or replace function public.simular_juegos(p_op uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (public.puede('corte', 'ver') or public.puede('op', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso para ver el corte' using errcode = '42501';
  end if;
  return corte_asignar_juegos(p_op, false);
end $$;

create or replace function public.armar_juegos(p_op uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  v jsonb;
  v_evento uuid;
begin
  perform exigir_permiso('corte', 'editar');
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La % está %', o.consecutivo, replace(o.estado, '_', ' '); end if;
  v := corte_asignar_juegos(p_op, true);
  if (v ->> 'juegos')::int > 0 then
    v_evento := registrar_avance(p_op, 'corte', (v ->> 'juegos')::int, (v ->> 'juegos')::int, 0, 0, false, 'Juegos armados');
    update juegos set evento_avance_id = v_evento where op_id = p_op and evento_avance_id is null;
  end if;
  return v;
end $$;

-- Termina el proceso de corte de la OP (no se corta más)
create or replace function public.terminar_corte_op(p_op uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o ordenes_produccion; p op_procesos;
begin
  perform exigir_permiso('corte', 'editar');
  select * into o from ordenes_produccion where id = p_op for update;
  select * into p from op_procesos where op_id = p_op and proceso = 'corte';
  if p.op_id is null then raise exception 'La OP no tiene corte en su ruta'; end if;
  if p.estado = 'terminado' then return; end if;
  if p.buenas = 0 then raise exception 'La % todavía no tiene prendas cortadas (juegos o paquetes completos)', o.consecutivo; end if;
  if exists (select 1 from cortes where op_id = p_op and estado = 'borrador' and documento -> 'bloques' <> '[]') then
    raise exception 'Hay cortes en borrador de la %: confírmelos o anúlelos', o.consecutivo;
  end if;
  update op_procesos set estado = 'terminado', fin = now() where op_id = p_op and proceso = 'corte';
  perform set_config('app.op_sistema', 'si', true);
  update ordenes_produccion set
    estado = case when not exists (select 1 from op_procesos where op_id = p_op and estado <> 'terminado') then 'terminada' else 'en_proceso' end,
    proceso_actual = coalesce((select proceso from op_procesos where op_id = p_op and estado <> 'terminado' order by orden limit 1), 'corte')
  where id = p_op;
end $$;

-- ---------------------------------------------------------------------
-- Anular (regla 2: se reversa con movimientos inversos, nada se borra)
-- ---------------------------------------------------------------------
create or replace function public.anular_corte(p_corte uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_corte cortes;
  m record;
  e eventos_proceso;
begin
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la anulación'; end if;
  select * into v_corte from cortes where id = p_corte for update;
  if v_corte.id is null then raise exception 'Corte no encontrado'; end if;
  if v_corte.estado = 'anulado' then raise exception 'El corte ya está anulado'; end if;
  perform set_config('app.corte_sistema', 'si', true);

  if v_corte.estado = 'borrador' then
    perform exigir_permiso('corte', 'editar');
  else
    if not public.puede('corte', 'aprobar') and not public.es_conexion_directa() then
      raise exception 'Solo el jefe de corte anula un corte confirmado' using errcode = '42501';
    end if;
    if exists (select 1 from juego_componentes jc join juegos j on j.id = jc.juego_id join paquetes p on p.id = jc.paquete_id
               where p.corte_id = p_corte and j.estado <> 'anulado') then
      raise exception 'Hay juegos armados con piezas de este corte: no se puede anular';
    end if;
    if (select estado from op_procesos where op_id = v_corte.op_id and proceso = 'corte') = 'terminado' then
      raise exception 'El corte de la OP ya se terminó';
    end if;
    -- movimientos inversos de todo lo que hizo el corte (salidas, retazos y liberaciones)
    for m in select * from movimientos_inventario mi where mi.documento_tipo = 'corte' and mi.documento_id = v_corte.consecutivo
             and mi.tipo <> 'anulacion' and not exists (select 1 from movimientos_inventario a where a.anula_id = mi.id) loop
      insert into movimientos_inventario (tipo, afecta, material_id, color_id, rollo_id, bodega_id, ubicacion_id, cantidad, metros, kilos,
                                          costo_unitario, op_id, documento_tipo, documento_id, motivo, anula_id)
      values ('anulacion', m.afecta, m.material_id, m.color_id, m.rollo_id, m.bodega_id, m.ubicacion_id, -m.cantidad, -m.metros, -m.kilos,
              m.costo_unitario, m.op_id, 'corte', v_corte.consecutivo, 'Anulación: ' || p_motivo, m.id);
    end loop;
    update op_necesidades n set consumido = n.consumido - x.cantidad,
           reservado = (select coalesce(sum(rv.reservado), 0) from reservado_op(v_corte.op_id) rv where rv.material_id = x.material_id and rv.color_id is not distinct from x.color_id)
      from (select material_id, color_id, sum(cantidad) as cantidad from corte_rollos where corte_id = p_corte and vigente group by 1, 2) x
     where n.op_id = v_corte.op_id and n.material_id = x.material_id and n.color_id is not distinct from x.color_id;
    update corte_rollos set vigente = false where corte_id = p_corte;
    update paquetes set estado = 'anulado' where corte_id = p_corte;
    -- el avance de prendas completas se anula con un evento inverso
    if v_corte.evento_avance_id is not null then
      select * into e from eventos_proceso where id = v_corte.evento_avance_id;
      insert into eventos_proceso (op_id, proceso, tipo, entra, buenas, segundas, faltantes, observacion, anula_id)
      values (e.op_id, e.proceso, 'anulacion', e.entra, e.buenas, e.segundas, e.faltantes, 'Anulación del corte ' || v_corte.consecutivo, e.id);
      update op_procesos set entra = entra - e.entra, buenas = buenas - e.buenas, segundas = segundas - e.segundas, faltantes = faltantes - e.faltantes
       where op_id = e.op_id and proceso = e.proceso;
    end if;
  end if;
  update cortes set estado = 'anulado', motivo_anulacion = trim(p_motivo), anulado_en = now(), anulado_por = auth.uid() where id = p_corte;
end $$;

-- ---------------------------------------------------------------------
-- El avance de corte también lo registra quien tiene permiso de editar Corte
-- (misma función de la Fase 4; solo cambia el permiso)
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
  if not (public.es_conexion_directa() or public.puede('op', 'editar') or (p_proceso = 'corte' and public.puede('corte', 'editar'))) then
    raise exception 'Sin permiso para registrar avance de %', p_proceso using errcode = '42501';
  end if;
  select * into o from ordenes_produccion where id = p_op for update;
  if o.estado not in ('planeada','en_proceso') then raise exception 'La OP % está %', o.consecutivo, o.estado; end if;
  select * into p from op_procesos where op_id = p_op and proceso = p_proceso;
  if not found then raise exception 'El proceso % no está en la ruta de la OP', p_proceso; end if;
  if p.estado = 'terminado' then raise exception '% ya se terminó en esta OP', (select nombre from procesos where codigo = p_proceso); end if;
  if p_entra is null or p_buenas is null or p_entra <> p_buenas + coalesce(p_segundas, 0) + coalesce(p_faltantes, 0) then
    raise exception 'Registre las cantidades: entra (%) debe ser igual a buenas + segundas + faltantes', p_entra;
  end if;
  if p_entra <= 0 then raise exception 'Registre cuántas prendas entran al proceso'; end if;

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
-- Vista para la pantalla de corte: OP con corte pendiente y lo cortado
-- ---------------------------------------------------------------------
create view public.op_corte_resumen with (security_invoker = true) as
select o.id as op_id, o.consecutivo, o.referencia_id, o.estado, o.prioridad, o.fecha_entrega_plan, o.cantidad_total,
       p.estado as estado_corte, p.buenas as prendas_cortadas,
       (select count(*) from public.cortes c where c.op_id = o.id and c.estado = 'confirmado')::int as cortes_confirmados,
       (select count(*) from public.cortes c where c.op_id = o.id and c.estado = 'borrador')::int as cortes_borrador,
       (select coalesce(sum(s.saldo), 0) from public.piezas_saldo s where s.op_id = o.id and not s.completo)::int as piezas_sueltas
from public.ordenes_produccion o
join public.op_procesos p on p.op_id = o.id and p.proceso = 'corte'
where o.estado in ('planeada','en_proceso');

-- ---------------------------------------------------------------------
-- Estándar y RLS
-- ---------------------------------------------------------------------
select public.aplicar_estandar_maestro('trazos');
select public.aplicar_estandar_maestro('cortes');
do $$
declare t text;
begin
  -- documentos que solo escriben las funciones: auditoría y RLS
  foreach t in array array['corte_rollos','paquetes','juegos'] loop perform public.aplicar_estandar_maestro(t); end loop;
end $$;
select public.aplicar_estandar_maestro('corte_resultados', 'corte_id');
select public.aplicar_estandar_maestro('corte_consumos', 'corte_id');
select public.aplicar_estandar_maestro('juego_componentes', 'juego_id');

do $$
declare t text;
begin
  foreach t in array array['trazos','cortes','corte_rollos','corte_resultados','corte_consumos','corte_autorizaciones',
                           'paquetes','juegos','juego_componentes']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.es_interno())', t || '_leer', t);
  end loop;
end $$;
create policy trazos_insertar on public.trazos for insert to authenticated with check (public.puede('corte','editar'));
create policy trazos_actualizar on public.trazos for update to authenticated using (public.puede('corte','editar')) with check (public.puede('corte','editar'));

-- ---------------------------------------------------------------------
-- Plantillas ZPL de paquete y juego (50 × 30 mm a 203 dpi = 400 × 240 puntos)
-- ---------------------------------------------------------------------
insert into public.plantillas_etiqueta (tipo, tamano, nombre, zpl) values
('paquete', '50x30', 'Paquete de corte 50 × 30 mm',
'^XA
^CI28
^PW400
^LL240
^LH0,0
^FO10,14^BQN,2,5^FDMA,{{codigo}}^FS
^FO150,14^A0N,30,30^FD{{codigo}}^FS
^FO150,50^A0N,24,24^FD{{op}}  {{referencia}}^FS
^FO150,80^A0N,40,40^FDT: {{talla}}  x{{cantidad}}^FS
^FO150,126^A0N,22,22^FB240,1,0,L^FD{{color}}^FS
^FO150,152^A0N,20,20^FB240,1,0,L^FDLote {{lote}}^FS
^FO10,186^GB380,2,2^FS
^FO10,196^A0N,20,20^FB380,1,0,L^FD{{partes}}  Capas {{capas}}^FS
^FO10,218^A0N,18,18^FDCorte {{corte}}  {{fecha}}^FS
^PQ{{copias}}
^XZ'),
('juego', '50x30', 'Juego (prenda combinada) 50 × 30 mm',
'^XA
^CI28
^PW400
^LL240
^LH0,0
^FO10,14^BQN,2,5^FDMA,{{codigo}}^FS
^FO150,14^A0N,30,30^FD{{codigo}}^FS
^FO150,50^A0N,24,24^FD{{op}}  {{referencia}}^FS
^FO150,80^A0N,40,40^FDT: {{talla}}  x{{cantidad}}^FS
^FO150,126^A0N,22,22^FB240,2,0,L^FD{{combinacion}}^FS
^FO10,186^GB380,2,2^FS
^FO10,196^A0N,18,18^FB380,2,0,L^FD{{paquetes}}^FS
^PQ{{copias}}
^XZ')
on conflict do nothing;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.cortes, public.paquetes;
  end if;
end $$;
