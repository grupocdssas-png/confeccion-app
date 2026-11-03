-- =====================================================================
-- Fase 3 · Migración 8: lista maestra de operaciones y ficha técnica
-- versionada. Regla 11: una ficha aprobada queda congelada; cualquier
-- cambio crea una nueva versión y las OP conservan la suya.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Catálogos de diseño
-- ---------------------------------------------------------------------
create table public.familias_producto (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table public.tipos_producto (
  id         uuid primary key default gen_random_uuid(),
  familia_id uuid not null references public.familias_producto(id),
  nombre     text not null,
  activo     boolean not null default true,
  unique (familia_id, nombre)
);

create table public.lineas (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table public.colecciones (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  anio   int,
  activo boolean not null default true
);

create table public.referencias (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique,
  nombre             text not null,
  linea_id           uuid references public.lineas(id),
  coleccion_id       uuid references public.colecciones(id),
  familia_id         uuid references public.familias_producto(id),
  tipo_producto_id   uuid references public.tipos_producto(id),
  cliente_id         uuid references public.clientes(id),
  version_vigente_id uuid,                 -- FK más abajo
  activo             boolean not null default true
);

create table public.muestras (
  id            uuid primary key default gen_random_uuid(),
  referencia_id uuid not null references public.referencias(id),
  numero        int  not null,
  estado        text not null default 'solicitada' check (estado in ('solicitada','en_desarrollo','aprobada','rechazada')),
  responsable   text,
  fecha_solicitud date not null default current_date,
  fecha_entrega date,
  observaciones text,
  unique (referencia_id, numero)
);

-- ---------------------------------------------------------------------
-- Lista maestra de operaciones
-- ---------------------------------------------------------------------
create table public.operaciones (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique,
  nombre             text not null,
  familia_id         uuid references public.familias_producto(id),
  tipo_producto_id   uuid references public.tipos_producto(id),
  proceso            text not null default 'confeccion' references public.procesos(codigo),
  sam                numeric(8,4) not null check (sam > 0),          -- minutos estándar
  unidades_hora      numeric(10,2) generated always as (round(60 / sam, 2)) stored,
  valor_destajo      numeric(14,2) not null default 0,                -- COP por unidad
  tipo_maquina_id    uuid references public.tipos_maquina(id),
  parte              text,
  repeticiones       numeric(6,2) not null default 1 check (repeticiones > 0),
  agrega_minutos_sam boolean not null default true,
  restrictiva        boolean not null default false,
  tipo               text not null default 'normal' check (tipo in ('normal','reproceso','manual','inspeccion','empaque')),
  activo             boolean not null default true
);
create index on public.operaciones (familia_id, tipo_producto_id);

-- Historial de SAM y valor (E)
create table public.operaciones_historial (
  id             bigserial primary key,
  operacion_id   uuid not null references public.operaciones(id),
  sam_anterior   numeric(8,4),
  sam_nuevo      numeric(8,4) not null,
  valor_anterior numeric(14,2),
  valor_nuevo    numeric(14,2) not null,
  origen         text not null default 'manual' check (origen in ('manual','estudio','importacion','creacion')),
  estudio_id     uuid,
  usuario_id     uuid default auth.uid() references public.perfiles(id),
  fecha          timestamptz not null default now()
);
create index on public.operaciones_historial (operacion_id, fecha);
select public.aplicar_estandar_evento('operaciones_historial');

create or replace function public.fn_historial_operacion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.sam is distinct from old.sam or new.valor_destajo is distinct from old.valor_destajo then
    insert into operaciones_historial (operacion_id, sam_anterior, sam_nuevo, valor_anterior, valor_nuevo, origen)
    values (new.id, case when tg_op = 'UPDATE' then old.sam end, new.sam,
            case when tg_op = 'UPDATE' then old.valor_destajo end, new.valor_destajo,
            case when tg_op = 'INSERT' then coalesce(nullif(current_setting('app.origen_operacion', true), ''), 'creacion')
                 else coalesce(nullif(current_setting('app.origen_operacion', true), ''), 'manual') end);
  end if;
  return new;
end $$;
create trigger operaciones_historial after insert or update on public.operaciones
  for each row execute function public.fn_historial_operacion();

-- Valor del minuto (mano de obra) e indirectos por minuto, con vigencia
create table public.valores_minuto (
  id                uuid primary key default gen_random_uuid(),
  area_id           uuid references public.areas(id),          -- null = toda la planta
  valor_minuto      numeric(14,2) not null check (valor_minuto > 0),
  indirecto_minuto  numeric(14,2) not null default 0 check (indirecto_minuto >= 0),
  vigente_desde     date not null default current_date,
  observacion       text,
  creado_en         timestamptz not null default now()
);

create or replace function public.valor_minuto_vigente(p_fecha date default current_date)
returns table (valor_minuto numeric, indirecto_minuto numeric)
language sql stable security definer set search_path = public as $$
  select v.valor_minuto, v.indirecto_minuto from valores_minuto v
  where v.area_id is null and v.vigente_desde <= p_fecha
  order by v.vigente_desde desc, v.creado_en desc limit 1
$$;

-- ---------------------------------------------------------------------
-- Ficha técnica versionada
-- ---------------------------------------------------------------------
create table public.ficha_versiones (
  id                   uuid primary key default gen_random_uuid(),
  referencia_id        uuid not null references public.referencias(id),
  version              int  not null,
  estado               text not null default 'borrador' check (estado in ('borrador','en_aprobacion','aprobada','obsoleta')),
  basada_en_id         uuid references public.ficha_versiones(id),
  descripcion          text,
  composicion          text,
  instrucciones_lavado text,
  precio_objetivo      numeric(14,2),
  curva_id             uuid references public.curvas(id),
  boceto_path          text,
  molde_path           text,
  foto_path            text,
  sam_total            numeric(10,4),     -- calculado
  costo_estandar       numeric(14,2),     -- calculado (promedio de combinaciones)
  comentario_rechazo   text,
  enviada_en           timestamptz,
  aprobada_en          timestamptz,
  unique (referencia_id, version)
);
create unique index ficha_un_borrador on public.ficha_versiones (referencia_id) where estado in ('borrador','en_aprobacion');
alter table public.referencias add constraint referencias_version_fk foreign key (version_vigente_id) references public.ficha_versiones(id);

create table public.ficha_tallas (
  ficha_id uuid not null references public.ficha_versiones(id) on delete cascade,
  talla_id uuid not null references public.tallas(id),
  orden    int  not null default 0,
  primary key (ficha_id, talla_id)
);

create table public.ficha_partes (
  id                    uuid primary key default gen_random_uuid(),
  ficha_id              uuid not null references public.ficha_versiones(id) on delete cascade,
  nombre                text not null,
  orden                 int  not null default 0,
  puede_cortarse_retazo boolean not null default false,
  unique (ficha_id, nombre)
);

create table public.ficha_combinaciones (
  id       uuid primary key default gen_random_uuid(),
  ficha_id uuid not null references public.ficha_versiones(id) on delete cascade,
  codigo   text not null,
  nombre   text not null,
  orden    int  not null default 0,
  unique (ficha_id, codigo)
);

create table public.ficha_combinacion_partes (
  combinacion_id uuid not null references public.ficha_combinaciones(id) on delete cascade,
  parte_id       uuid not null references public.ficha_partes(id) on delete cascade,
  material_id    uuid references public.materiales(id),
  color_id       uuid not null references public.colores(id),
  primary key (combinacion_id, parte_id)
);

create table public.ficha_medidas (
  id           uuid primary key default gen_random_uuid(),
  ficha_id     uuid not null references public.ficha_versiones(id) on delete cascade,
  punto_medida text not null,
  metodo       text,
  orden        int  not null default 0
);

create table public.ficha_medida_tallas (
  medida_id     uuid not null references public.ficha_medidas(id) on delete cascade,
  talla_id      uuid not null references public.tallas(id),
  valor_cm      numeric(7,2) not null,
  tolerancia_cm numeric(5,2) not null default 1 check (tolerancia_cm >= 0),
  primary key (medida_id, talla_id)
);

create table public.ficha_bom (
  id             uuid primary key default gen_random_uuid(),
  ficha_id       uuid not null references public.ficha_versiones(id) on delete cascade,
  material_id    uuid not null references public.materiales(id),
  parte_id       uuid references public.ficha_partes(id) on delete set null,      -- tela de la parte
  combinacion_id uuid references public.ficha_combinaciones(id) on delete cascade, -- null = todas
  color_fijo_id  uuid references public.colores(id),       -- ej. marquilla siempre blanca
  merma_pct      numeric(5,2) not null default 0 check (merma_pct >= 0),
  permite_retazo boolean not null default false,
  observacion    text,
  orden          int not null default 0
);

create table public.ficha_bom_consumos (
  bom_id   uuid not null references public.ficha_bom(id) on delete cascade,
  talla_id uuid not null references public.tallas(id),
  consumo  numeric(12,4) not null check (consumo >= 0),   -- unidad del material, por prenda
  primary key (bom_id, talla_id)
);

create table public.ficha_artes (
  id           uuid primary key default gen_random_uuid(),
  ficha_id     uuid not null references public.ficha_versiones(id) on delete cascade,
  proceso      text not null check (proceso in ('estampacion','bordado')),
  parte_id     uuid references public.ficha_partes(id) on delete set null,
  nombre       text not null,
  archivo_path text,
  tecnica      text,
  tintas       text,       -- estampación: tintas y colores
  hilos        text,       -- bordado: colores de hilo
  puntadas     int,
  ancho_cm     numeric(6,2),
  alto_cm      numeric(6,2),
  ubicacion    text,
  orden        int not null default 0
);

create table public.ficha_ruta (
  ficha_id              uuid not null references public.ficha_versiones(id) on delete cascade,
  proceso               text not null references public.procesos(codigo),
  orden                 int  not null,
  modalidad             text not null default 'interno' check (modalidad in ('interno','satelite','ambos')),
  costo_externo_unidad  numeric(14,2) not null default 0 check (costo_externo_unidad >= 0),
  primary key (ficha_id, proceso)
);

create table public.ficha_operaciones (
  id               uuid primary key default gen_random_uuid(),
  ficha_id         uuid not null references public.ficha_versiones(id) on delete cascade,
  secuencia        int  not null,
  operacion_id     uuid not null references public.operaciones(id),
  proceso          text not null references public.procesos(codigo),
  parte_id         uuid references public.ficha_partes(id) on delete set null,
  sam              numeric(8,4) not null,           -- copia de la lista maestra
  valor_destajo    numeric(14,2) not null,          -- copia
  repeticiones     numeric(6,2) not null,           -- copia (si no se indica)
  agrega_minutos_sam boolean not null,              -- copia
  tipo_maquina_id  uuid references public.tipos_maquina(id),
  es_contadora     boolean not null default false,
  unique (ficha_id, secuencia)
);

-- Al agregar una operación a la ficha se copian SAM, valor y máquina de la lista maestra
create or replace function public.fn_copiar_operacion() returns trigger
language plpgsql as $$
declare o public.operaciones;
begin
  select * into o from public.operaciones where id = new.operacion_id;
  if tg_op = 'INSERT' or new.operacion_id is distinct from old.operacion_id then
    new.sam := coalesce(new.sam, o.sam);
    new.valor_destajo := coalesce(new.valor_destajo, o.valor_destajo);
    new.repeticiones := coalesce(new.repeticiones, o.repeticiones);
    new.agrega_minutos_sam := coalesce(new.agrega_minutos_sam, o.agrega_minutos_sam);
    new.tipo_maquina_id := coalesce(new.tipo_maquina_id, o.tipo_maquina_id);
    new.proceso := coalesce(new.proceso, o.proceso);
  end if;
  return new;
end $$;
create trigger ficha_operaciones_copiar before insert or update on public.ficha_operaciones
  for each row execute function public.fn_copiar_operacion();

create table public.ficha_costo_estandar (
  id             uuid primary key default gen_random_uuid(),
  ficha_id       uuid not null references public.ficha_versiones(id) on delete cascade,
  combinacion_id uuid references public.ficha_combinaciones(id) on delete cascade,
  concepto       text not null check (concepto in ('materiales','mano_obra','externos','indirectos','total')),
  valor          numeric(14,2) not null,
  detalle        jsonb
);

create table public.ficha_aprobaciones (
  id         uuid primary key default gen_random_uuid(),
  ficha_id   uuid not null references public.ficha_versiones(id),
  area       text not null check (area in ('diseno','produccion','costos')),
  decision   text not null check (decision in ('aprobada','rechazada')),
  comentario text,
  usuario_id uuid default auth.uid() references public.perfiles(id),
  fecha      timestamptz not null default now()
);
select public.aplicar_estandar_evento('ficha_aprobaciones');

-- ---------------------------------------------------------------------
-- Regla 11: congelamiento. Solo se edita una versión en borrador.
-- ---------------------------------------------------------------------
create or replace function public.fn_ficha_editable() returns trigger
language plpgsql as $$
declare
  v_ficha uuid;
  v_estado text;
  v_fila jsonb := to_jsonb(coalesce(new, old));
begin
  if current_setting('app.ficha_sistema', true) = 'si' then return coalesce(new, old); end if;
  v_ficha := case tg_argv[0]
    when 'ficha_id' then (v_fila->>'ficha_id')::uuid
    when 'combinacion' then (select ficha_id from public.ficha_combinaciones where id = (v_fila->>'combinacion_id')::uuid)
    when 'medida' then (select ficha_id from public.ficha_medidas where id = (v_fila->>'medida_id')::uuid)
    when 'bom' then (select ficha_id from public.ficha_bom where id = (v_fila->>'bom_id')::uuid)
  end;
  select estado into v_estado from public.ficha_versiones where id = v_ficha;
  if v_estado is not null and v_estado <> 'borrador' then
    raise exception 'La ficha está % y no se puede modificar. Cree una nueva versión.',
      case v_estado when 'en_aprobacion' then 'en aprobación' else v_estado end
      using errcode = 'P0001';
  end if;
  return coalesce(new, old);
end $$;

do $$
declare r record;
begin
  for r in select * from (values
    ('ficha_tallas','ficha_id'), ('ficha_partes','ficha_id'), ('ficha_combinaciones','ficha_id'),
    ('ficha_combinacion_partes','combinacion'), ('ficha_medidas','ficha_id'), ('ficha_medida_tallas','medida'),
    ('ficha_bom','ficha_id'), ('ficha_bom_consumos','bom'), ('ficha_artes','ficha_id'), ('ficha_ruta','ficha_id'),
    ('ficha_operaciones','ficha_id'), ('ficha_costo_estandar','ficha_id')) as t(tabla, modo)
  loop
    execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.fn_ficha_editable(%L)',
                   r.tabla || '_congelada', r.tabla, r.modo);
  end loop;
end $$;

-- El encabezado: solo en borrador se editan sus datos; el estado lo cambian las funciones
create or replace function public.fn_ficha_cabecera() returns trigger
language plpgsql as $$
begin
  if current_setting('app.ficha_sistema', true) = 'si' then return new; end if;
  if tg_op = 'DELETE' then
    if old.estado <> 'borrador' then raise exception 'Solo se puede borrar una versión en borrador'; end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    if new.estado <> 'borrador' then raise exception 'Una versión nueva empieza en borrador'; end if;
    return new;
  end if;
  if old.estado <> 'borrador' then
    raise exception 'La ficha v% está % y no se puede modificar. Cree una nueva versión.', old.version,
      case old.estado when 'en_aprobacion' then 'en aprobación' else old.estado end;
  end if;
  if new.estado is distinct from old.estado or new.sam_total is distinct from old.sam_total
     or new.costo_estandar is distinct from old.costo_estandar or new.version is distinct from old.version then
    raise exception 'El estado, la versión y los costos de la ficha solo cambian con las funciones de aprobación';
  end if;
  return new;
end $$;
create trigger ficha_versiones_cabecera before insert or update or delete on public.ficha_versiones
  for each row execute function public.fn_ficha_cabecera();

-- ---------------------------------------------------------------------
-- Cálculos
-- ---------------------------------------------------------------------
-- Necesidades de materiales: cantidades = {combinacion_id: {talla_id: n}}
-- consumo × cantidad × (1 + merma). Color: fijo, o el de la parte en esa combinación.
create or replace function public.necesidades_ficha(p_ficha uuid, p_cantidades jsonb)
returns table (material_id uuid, color_id uuid, parte_id uuid, cantidad numeric, detalle jsonb)
language sql stable security definer set search_path = public as $$
  with cant as (
    select c.key::uuid as combinacion_id, t.key::uuid as talla_id, (t.value #>> '{}')::numeric as n
    from jsonb_each(p_cantidades) c, jsonb_each(c.value) t
    where (t.value #>> '{}')::numeric > 0
  ),
  lineas as (
    select b.material_id,
           coalesce(b.color_fijo_id, cp.color_id) as color_id,
           b.parte_id, k.combinacion_id, k.talla_id, k.n,
           bc.consumo * k.n * (1 + b.merma_pct / 100) as cantidad
    from ficha_bom b
    join cant k on b.combinacion_id is null or b.combinacion_id = k.combinacion_id
    join ficha_bom_consumos bc on bc.bom_id = b.id and bc.talla_id = k.talla_id
    left join ficha_combinacion_partes cp on cp.combinacion_id = k.combinacion_id and cp.parte_id = b.parte_id
    where b.ficha_id = p_ficha
  )
  select l.material_id, l.color_id, l.parte_id, round(sum(l.cantidad), 6),
         jsonb_agg(jsonb_build_object('combinacion_id', l.combinacion_id, 'talla_id', l.talla_id, 'prendas', l.n,
                                      'cantidad', round(l.cantidad, 6)))
  from lineas l
  group by l.material_id, l.color_id, l.parte_id
$$;

-- SAM total de la ficha (minutos por prenda)
create or replace function public.sam_total_ficha(p_ficha uuid) returns numeric
language sql stable as $$
  select coalesce(sum(sam * repeticiones) filter (where agrega_minutos_sam), 0)
  from public.ficha_operaciones where ficha_id = p_ficha
$$;

-- Costo estándar por prenda, por combinación. Materiales ponderados por la curva
-- (o partes iguales entre tallas) + mano de obra (SAM × valor minuto)
-- + procesos externos + indirectos (SAM × indirecto por minuto).
create or replace function public.calcular_costo_estandar(p_ficha uuid)
returns table (combinacion_id uuid, materiales numeric, mano_obra numeric, externos numeric, indirectos numeric, total numeric, detalle jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  v_sam numeric := sam_total_ficha(p_ficha);
  v_vm record;
  v_ext numeric;
  c record;
  v_pesos jsonb;
  v_mat numeric;
  v_det jsonb;
begin
  select * into v_vm from valor_minuto_vigente();
  select coalesce(sum(costo_externo_unidad), 0) into v_ext from ficha_ruta where ficha_id = p_ficha;
  -- pesos por talla (suman 1): curva de la ficha si existe, si no partes iguales
  select jsonb_object_agg(x.talla_id, x.peso) into v_pesos
  from (
    select ft.talla_id, coalesce(ct.proporcion, 1) / sum(coalesce(ct.proporcion, 1)) over () as peso
    from ficha_tallas ft
    join ficha_versiones f on f.id = ft.ficha_id
    left join curva_tallas ct on ct.curva_id = f.curva_id and ct.talla_id = ft.talla_id
    where ft.ficha_id = p_ficha and (f.curva_id is null or ct.proporcion > 0)
  ) x;
  if v_pesos is null then raise exception 'La ficha no tiene tallas'; end if;

  for c in select id from ficha_combinaciones where ficha_id = p_ficha order by orden, codigo loop
    select coalesce(sum(n.cantidad * coalesce(m.costo_estandar, 0)), 0),
           coalesce(jsonb_agg(jsonb_build_object('material', m.nombre, 'cantidad', round(n.cantidad, 4), 'unidad', m.unidad,
                                                 'costo_unitario', m.costo_estandar,
                                                 'valor', round(n.cantidad * coalesce(m.costo_estandar, 0), 2))
                              order by m.nombre), '[]')
      into v_mat, v_det
    from necesidades_ficha(p_ficha, jsonb_build_object(c.id, v_pesos)) n
    join materiales m on m.id = n.material_id;

    combinacion_id := c.id;
    materiales := round(v_mat, 2);
    mano_obra := round(v_sam * coalesce(v_vm.valor_minuto, 0), 2);
    externos := round(v_ext, 2);
    indirectos := round(v_sam * coalesce(v_vm.indirecto_minuto, 0), 2);
    total := materiales + mano_obra + externos + indirectos;
    detalle := jsonb_build_object('materiales', v_det, 'sam_total', v_sam, 'valor_minuto', v_vm.valor_minuto,
                                  'indirecto_minuto', v_vm.indirecto_minuto, 'pesos_talla', v_pesos);
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Versiones: crear, duplicar, enviar, aprobar
-- ---------------------------------------------------------------------
-- Copia profunda de una versión (a la misma referencia u otra). Devuelve la nueva.
create or replace function public.copiar_ficha(p_origen uuid, p_referencia_destino uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o ficha_versiones;
  v_ref uuid;
  v_nueva uuid;
  v_version int;
begin
  perform exigir_permiso('ficha_tecnica', 'editar');
  select * into o from ficha_versiones where id = p_origen;
  if not found then raise exception 'Ficha de origen inexistente'; end if;
  v_ref := coalesce(p_referencia_destino, o.referencia_id);
  if exists (select 1 from ficha_versiones where referencia_id = v_ref and estado in ('borrador','en_aprobacion')) then
    raise exception 'La referencia ya tiene una versión en borrador o en aprobación';
  end if;
  select coalesce(max(version), 0) + 1 into v_version from ficha_versiones where referencia_id = v_ref;

  insert into ficha_versiones (referencia_id, version, basada_en_id, descripcion, composicion, instrucciones_lavado, precio_objetivo,
                               curva_id, boceto_path, molde_path, foto_path)
  values (v_ref, v_version, p_origen, o.descripcion, o.composicion, o.instrucciones_lavado, o.precio_objetivo,
          o.curva_id, o.boceto_path, o.molde_path, o.foto_path)
  returning id into v_nueva;

  create temp table if not exists _mapa (viejo uuid primary key, nuevo uuid) on commit drop;
  delete from _mapa where true;   -- (Supabase exige WHERE en los DELETE)
  insert into _mapa select id, gen_random_uuid() from ficha_partes where ficha_id = p_origen;
  insert into _mapa select id, gen_random_uuid() from ficha_combinaciones where ficha_id = p_origen;
  insert into _mapa select id, gen_random_uuid() from ficha_medidas where ficha_id = p_origen;
  insert into _mapa select id, gen_random_uuid() from ficha_bom where ficha_id = p_origen;

  insert into ficha_tallas select v_nueva, talla_id, orden from ficha_tallas where ficha_id = p_origen;
  insert into ficha_partes (id, ficha_id, nombre, orden, puede_cortarse_retazo)
    select m.nuevo, v_nueva, p.nombre, p.orden, p.puede_cortarse_retazo from ficha_partes p join _mapa m on m.viejo = p.id where p.ficha_id = p_origen;
  insert into ficha_combinaciones (id, ficha_id, codigo, nombre, orden)
    select m.nuevo, v_nueva, c.codigo, c.nombre, c.orden from ficha_combinaciones c join _mapa m on m.viejo = c.id where c.ficha_id = p_origen;
  insert into ficha_combinacion_partes (combinacion_id, parte_id, material_id, color_id)
    select mc.nuevo, mp.nuevo, cp.material_id, cp.color_id from ficha_combinacion_partes cp
    join _mapa mc on mc.viejo = cp.combinacion_id join _mapa mp on mp.viejo = cp.parte_id;
  insert into ficha_medidas (id, ficha_id, punto_medida, metodo, orden)
    select m.nuevo, v_nueva, x.punto_medida, x.metodo, x.orden from ficha_medidas x join _mapa m on m.viejo = x.id where x.ficha_id = p_origen;
  insert into ficha_medida_tallas (medida_id, talla_id, valor_cm, tolerancia_cm)
    select m.nuevo, t.talla_id, t.valor_cm, t.tolerancia_cm from ficha_medida_tallas t join _mapa m on m.viejo = t.medida_id;
  insert into ficha_bom (id, ficha_id, material_id, parte_id, combinacion_id, color_fijo_id, merma_pct, permite_retazo, observacion, orden)
    select m.nuevo, v_nueva, b.material_id, mp.nuevo, mc.nuevo, b.color_fijo_id, b.merma_pct, b.permite_retazo, b.observacion, b.orden
    from ficha_bom b join _mapa m on m.viejo = b.id
    left join _mapa mp on mp.viejo = b.parte_id left join _mapa mc on mc.viejo = b.combinacion_id
    where b.ficha_id = p_origen;
  insert into ficha_bom_consumos (bom_id, talla_id, consumo)
    select m.nuevo, c.talla_id, c.consumo from ficha_bom_consumos c join _mapa m on m.viejo = c.bom_id;
  insert into ficha_artes (ficha_id, proceso, parte_id, nombre, archivo_path, tecnica, tintas, hilos, puntadas, ancho_cm, alto_cm, ubicacion, orden)
    select v_nueva, a.proceso, mp.nuevo, a.nombre, a.archivo_path, a.tecnica, a.tintas, a.hilos, a.puntadas, a.ancho_cm, a.alto_cm, a.ubicacion, a.orden
    from ficha_artes a left join _mapa mp on mp.viejo = a.parte_id where a.ficha_id = p_origen;
  insert into ficha_ruta select v_nueva, proceso, orden, modalidad, costo_externo_unidad from ficha_ruta where ficha_id = p_origen;
  -- la secuencia se copia tal como está en la ficha de origen (SAM y valor propios del producto)
  insert into ficha_operaciones (ficha_id, secuencia, operacion_id, proceso, parte_id, repeticiones, es_contadora,
                                 sam, valor_destajo, agrega_minutos_sam, tipo_maquina_id)
    select v_nueva, x.secuencia, x.operacion_id, x.proceso, mp.nuevo, x.repeticiones, x.es_contadora,
           x.sam, x.valor_destajo, x.agrega_minutos_sam, x.tipo_maquina_id
    from ficha_operaciones x left join _mapa mp on mp.viejo = x.parte_id where x.ficha_id = p_origen;
  return v_nueva;
end $$;

create or replace function public.nueva_referencia(p_codigo text, p_nombre text, p_familia uuid default null, p_tipo uuid default null,
                                                   p_linea uuid default null, p_coleccion uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_ref uuid; v_ficha uuid;
begin
  perform exigir_permiso('ficha_tecnica', 'editar');
  insert into referencias (codigo, nombre, familia_id, tipo_producto_id, linea_id, coleccion_id)
  values (upper(trim(p_codigo)), trim(p_nombre), p_familia, p_tipo, p_linea, p_coleccion) returning id into v_ref;
  insert into ficha_versiones (referencia_id, version) values (v_ref, 1) returning id into v_ficha;
  return v_ficha;
end $$;

-- Validación antes de enviar a aprobación: devuelve la lista de faltantes
create or replace function public.validar_ficha(p_ficha uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[
    case when not exists (select 1 from ficha_tallas where ficha_id = p_ficha) then 'Faltan las tallas' end,
    case when not exists (select 1 from ficha_partes where ficha_id = p_ficha) then 'Faltan las partes de la prenda' end,
    case when not exists (select 1 from ficha_combinaciones where ficha_id = p_ficha) then 'Falta al menos una combinación de color' end,
    case when exists (select 1 from ficha_combinaciones c, ficha_partes p
                      where c.ficha_id = p_ficha and p.ficha_id = p_ficha
                        and not exists (select 1 from ficha_combinacion_partes cp where cp.combinacion_id = c.id and cp.parte_id = p.id))
         then 'Hay partes sin color en alguna combinación' end,
    case when not exists (select 1 from ficha_bom where ficha_id = p_ficha) then 'Falta la lista de materiales' end,
    case when exists (select 1 from ficha_bom b, ficha_tallas t
                      where b.ficha_id = p_ficha and t.ficha_id = p_ficha
                        and not exists (select 1 from ficha_bom_consumos c where c.bom_id = b.id and c.talla_id = t.talla_id))
         then 'Hay materiales sin consumo en alguna talla' end,
    case when not exists (select 1 from ficha_ruta where ficha_id = p_ficha) then 'Falta la ruta de procesos' end,
    case when not exists (select 1 from ficha_operaciones where ficha_id = p_ficha) then 'Falta la secuencia de operaciones' end,
    case when exists (select 1 from ficha_operaciones o where o.ficha_id = p_ficha
                      and not exists (select 1 from ficha_ruta r where r.ficha_id = p_ficha and r.proceso = o.proceso))
         then 'Hay operaciones de un proceso que no está en la ruta' end,
    case when (select count(*) from ficha_operaciones where ficha_id = p_ficha and es_contadora) > 1
         then 'Solo puede haber una operación contadora' end,
    case when exists (select 1 from ficha_medidas m, ficha_tallas t
                      where m.ficha_id = p_ficha and t.ficha_id = p_ficha
                        and not exists (select 1 from ficha_medida_tallas mt where mt.medida_id = m.id and mt.talla_id = t.talla_id))
         then 'Hay puntos de medida sin valor en alguna talla' end
  ], null)
$$;

create or replace function public.enviar_ficha_aprobacion(p_ficha uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  f ficha_versiones;
  v_faltan text[];
begin
  perform exigir_permiso('ficha_tecnica', 'editar');
  select * into f from ficha_versiones where id = p_ficha for update;
  if f.estado <> 'borrador' then raise exception 'Solo se envía a aprobación una versión en borrador'; end if;
  v_faltan := validar_ficha(p_ficha);
  if array_length(v_faltan, 1) > 0 then raise exception 'La ficha está incompleta: %', array_to_string(v_faltan, '; '); end if;
  if not exists (select 1 from valor_minuto_vigente()) then raise exception 'Configure el valor del minuto antes de enviar a aprobación'; end if;

  perform set_config('app.ficha_sistema', 'si', true);
  -- El SAM y el valor de cada operación son los de la ficha del producto (no se toman de la lista maestra).
  -- costo estándar congelado
  delete from ficha_costo_estandar where ficha_id = p_ficha;
  insert into ficha_costo_estandar (ficha_id, combinacion_id, concepto, valor, detalle)
  select p_ficha, c.combinacion_id, x.concepto, x.valor, case when x.concepto = 'materiales' then c.detalle end
  from calcular_costo_estandar(p_ficha) c,
       lateral (values ('materiales', c.materiales), ('mano_obra', c.mano_obra), ('externos', c.externos),
                       ('indirectos', c.indirectos), ('total', c.total)) x(concepto, valor);
  update ficha_versiones set estado = 'en_aprobacion', enviada_en = now(), comentario_rechazo = null,
         sam_total = sam_total_ficha(p_ficha),
         costo_estandar = (select round(avg(valor), 2) from ficha_costo_estandar where ficha_id = p_ficha and concepto = 'total')
   where id = p_ficha;
  insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
  select 'ficha_por_aprobar', 'media', 'ficha_versiones', p_ficha::text,
         format('Ficha %s v%s por aprobar (Diseño, Producción y Costos)', r.codigo, f.version)
  from referencias r where r.id = f.referencia_id;
end $$;

-- Cada área (Diseño, Producción, Costos) aprueba o rechaza. Con las tres, queda aprobada y congelada.
create or replace function public.decidir_ficha(p_ficha uuid, p_area text, p_aprobar boolean, p_comentario text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  f ficha_versiones;
  v_roles text[] := case p_area when 'diseno' then array['diseno','gerencia']
                                when 'produccion' then array['jefe_produccion','gerencia']
                                when 'costos' then array['costos','gerencia'] end;
begin
  if v_roles is null then raise exception 'Área inválida: %', p_area; end if;
  if not (es_conexion_directa() or tiene_rol(v_roles)) then
    raise exception 'Su rol no aprueba por el área %', p_area using errcode = '42501';
  end if;
  select * into f from ficha_versiones where id = p_ficha for update;
  if f.estado <> 'en_aprobacion' then raise exception 'La ficha no está en aprobación'; end if;
  if not p_aprobar and coalesce(trim(p_comentario), '') = '' then raise exception 'Escriba el motivo del rechazo'; end if;
  if exists (select 1 from ficha_aprobaciones where ficha_id = p_ficha and area = p_area and fecha >= f.enviada_en) then
    raise exception 'El área % ya decidió sobre esta versión', p_area;
  end if;

  insert into ficha_aprobaciones (ficha_id, area, decision, comentario)
  values (p_ficha, p_area, case when p_aprobar then 'aprobada' else 'rechazada' end, p_comentario);
  perform set_config('app.ficha_sistema', 'si', true);

  if not p_aprobar then
    update ficha_versiones set estado = 'borrador', comentario_rechazo = format('%s: %s', p_area, p_comentario) where id = p_ficha;
    update alertas set estado = 'atendida', atendida_en = now() where tipo = 'ficha_por_aprobar' and entidad_id = p_ficha::text and estado = 'abierta';
    return 'borrador';
  end if;

  if (select count(distinct area) from ficha_aprobaciones
      where ficha_id = p_ficha and decision = 'aprobada' and fecha >= f.enviada_en) = 3 then
    update ficha_versiones set estado = 'obsoleta' where referencia_id = f.referencia_id and estado = 'aprobada';
    update ficha_versiones set estado = 'aprobada', aprobada_en = now() where id = p_ficha;
    update referencias set version_vigente_id = p_ficha where id = f.referencia_id;
    update alertas set estado = 'atendida', atendida_en = now() where tipo = 'ficha_por_aprobar' and entidad_id = p_ficha::text and estado = 'abierta';
    return 'aprobada';
  end if;
  return 'en_aprobacion';
end $$;

create or replace function public.devolver_ficha_borrador(p_ficha uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('ficha_tecnica', 'editar');
  perform set_config('app.ficha_sistema', 'si', true);
  update ficha_versiones set estado = 'borrador' where id = p_ficha and estado = 'en_aprobacion';
  if not found then raise exception 'Solo se devuelve a borrador una ficha en aprobación'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Importación desde SAMMU (Excel/CSV): la web lee el archivo, el usuario
-- relaciona columnas y esta función guarda fila por fila (upsert por código).
-- ---------------------------------------------------------------------
create table public.importaciones (
  id          uuid primary key default gen_random_uuid(),
  tipo        text not null check (tipo in ('operaciones','empleados','celulas','maquinas','op_activas')),
  archivo     text,
  filas_ok    int not null default 0,
  filas_error int not null default 0,
  errores     jsonb not null default '[]',
  usuario_id  uuid default auth.uid() references public.perfiles(id),
  fecha       timestamptz not null default now()
);
select public.aplicar_estandar_evento('importaciones');

create or replace function public.importar(p_tipo text, p_filas jsonb, p_archivo text default null, p_solo_validar boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f jsonb;
  i int := 0;
  v_ok int := 0;
  v_err jsonb := '[]';
  v_id uuid;
begin
  perform exigir_permiso(case p_tipo when 'operaciones' then 'operaciones' when 'maquinas' then 'mantenimiento'
                                     when 'empleados' then 'personal' else 'configuracion' end, 'editar');
  perform set_config('app.origen_operacion', 'importacion', true);
  for f in select * from jsonb_array_elements(p_filas) loop
    i := i + 1;
    begin
      case p_tipo
        when 'operaciones' then
          insert into operaciones (codigo, nombre, familia_id, tipo_producto_id, proceso, sam, valor_destajo, tipo_maquina_id, parte, repeticiones,
                                   restrictiva)
          values (upper(trim(f->>'codigo')), trim(f->>'nombre'),
                  (select id from familias_producto where lower(nombre) = lower(trim(f->>'familia'))),
                  (select t.id from tipos_producto t join familias_producto fa on fa.id = t.familia_id
                    where lower(t.nombre) = lower(trim(f->>'tipo_producto')) and lower(fa.nombre) = lower(trim(f->>'familia'))),
                  coalesce((select codigo from procesos where lower(nombre) = lower(trim(f->>'proceso')) or codigo = lower(trim(f->>'proceso'))), 'confeccion'),
                  (f->>'sam')::numeric, coalesce((f->>'valor_destajo')::numeric, 0),
                  (select id from tipos_maquina where lower(codigo) = lower(trim(f->>'maquina')) or lower(nombre) = lower(trim(f->>'maquina'))),
                  nullif(trim(f->>'parte'), ''), coalesce((f->>'repeticiones')::numeric, 1),
                  coalesce((f->>'restrictiva')::boolean, false))
          on conflict (codigo) do update set nombre = excluded.nombre, sam = excluded.sam, valor_destajo = excluded.valor_destajo,
            familia_id = coalesce(excluded.familia_id, operaciones.familia_id),
            tipo_producto_id = coalesce(excluded.tipo_producto_id, operaciones.tipo_producto_id),
            tipo_maquina_id = coalesce(excluded.tipo_maquina_id, operaciones.tipo_maquina_id),
            parte = coalesce(excluded.parte, operaciones.parte), repeticiones = excluded.repeticiones,
            restrictiva = excluded.restrictiva, proceso = excluded.proceso;
          if (f->>'maquina') is not null and trim(f->>'maquina') <> ''
             and not exists (select 1 from tipos_maquina where lower(codigo) = lower(trim(f->>'maquina')) or lower(nombre) = lower(trim(f->>'maquina'))) then
            raise exception 'Tipo de máquina "%" no existe (créelo primero)', f->>'maquina';
          end if;
        when 'celulas' then
          insert into celulas (codigo, nombre, proceso, area_id, turno_id)
          values (upper(trim(f->>'codigo')), trim(f->>'nombre'),
                  coalesce((select codigo from procesos where lower(nombre) = lower(trim(f->>'proceso')) or codigo = lower(trim(f->>'proceso'))), 'confeccion'),
                  (select id from areas where lower(codigo) = lower(trim(f->>'area')) or lower(nombre) = lower(trim(f->>'area'))),
                  (select id from turnos where lower(nombre) = lower(trim(f->>'turno'))))
          on conflict (codigo) do update set nombre = excluded.nombre, proceso = excluded.proceso,
            area_id = coalesce(excluded.area_id, celulas.area_id), turno_id = coalesce(excluded.turno_id, celulas.turno_id);
        when 'empleados' then
          insert into empleados (codigo, documento, nombres, apellidos, celula_id, cargo_id, qr, fecha_ingreso)
          values (upper(trim(f->>'codigo')), nullif(trim(f->>'documento'), ''), trim(f->>'nombres'), coalesce(trim(f->>'apellidos'), ''),
                  (select id from celulas where lower(codigo) = lower(trim(f->>'celula'))),
                  (select id from cargos where lower(nombre) = lower(trim(f->>'cargo'))),
                  'OPR-' || lpad(regexp_replace(f->>'codigo', '\D', '', 'g'), 4, '0'),
                  (f->>'fecha_ingreso')::date)
          on conflict (codigo) do update set nombres = excluded.nombres, apellidos = excluded.apellidos,
            documento = coalesce(excluded.documento, empleados.documento),
            celula_id = coalesce(excluded.celula_id, empleados.celula_id), cargo_id = coalesce(excluded.cargo_id, empleados.cargo_id);
          if (f->>'celula') is not null and trim(f->>'celula') <> '' and not exists (select 1 from celulas where lower(codigo) = lower(trim(f->>'celula'))) then
            raise exception 'Célula "%" no existe (importe primero las células)', f->>'celula';
          end if;
        when 'maquinas' then
          insert into maquinas (codigo, tipo_maquina_id, marca, modelo, serie, celula_id)
          values (case when upper(trim(f->>'codigo')) like 'MAQ-%' then upper(trim(f->>'codigo')) else 'MAQ-' || upper(trim(f->>'codigo')) end,
                  (select id from tipos_maquina where lower(codigo) = lower(trim(f->>'tipo')) or lower(nombre) = lower(trim(f->>'tipo'))),
                  nullif(trim(f->>'marca'), ''), nullif(trim(f->>'modelo'), ''), nullif(trim(f->>'serie'), ''),
                  (select id from celulas where lower(codigo) = lower(trim(f->>'celula'))))
          on conflict (codigo) do update set tipo_maquina_id = excluded.tipo_maquina_id, marca = coalesce(excluded.marca, maquinas.marca),
            modelo = coalesce(excluded.modelo, maquinas.modelo), serie = coalesce(excluded.serie, maquinas.serie),
            celula_id = coalesce(excluded.celula_id, maquinas.celula_id);
        else raise exception 'Tipo de importación no soportado todavía: %', p_tipo;
      end case;
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object('fila', i, 'codigo', f->>'codigo', 'error', sqlerrm);
    end;
  end loop;

  if p_solo_validar then
    -- se deshace todo: solo se informa qué pasaría
    raise exception using errcode = 'P0002', message = jsonb_build_object('ok', v_ok, 'errores', v_err)::text;
  end if;
  insert into importaciones (tipo, archivo, filas_ok, filas_error, errores) values (p_tipo, p_archivo, v_ok, jsonb_array_length(v_err), v_err);
  return jsonb_build_object('ok', v_ok, 'errores', v_err);
end $$;

-- Validar sin guardar (envoltorio que captura la excepción de importar(..., true))
create or replace function public.validar_importacion(p_tipo text, p_filas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform importar(p_tipo, p_filas, null, true);
  return null;
exception when sqlstate 'P0002' then
  return sqlerrm::jsonb;
end $$;

-- ---------------------------------------------------------------------
-- Estándar, RLS y Storage
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['familias_producto','tipos_producto','lineas','colecciones','referencias','muestras','operaciones',
                           'valores_minuto','ficha_versiones','ficha_partes','ficha_combinaciones','ficha_medidas','ficha_bom',
                           'ficha_artes','ficha_operaciones','ficha_costo_estandar']
  loop
    perform public.aplicar_estandar_maestro(t);
  end loop;
end $$;
select public.aplicar_estandar_maestro('ficha_tallas', 'ficha_id');
select public.aplicar_estandar_maestro('ficha_combinacion_partes', 'combinacion_id');
select public.aplicar_estandar_maestro('ficha_medida_tallas', 'medida_id');
select public.aplicar_estandar_maestro('ficha_bom_consumos', 'bom_id');
select public.aplicar_estandar_maestro('ficha_ruta', 'ficha_id');

do $$
declare r record;
begin
  for r in select * from (values
      ('familias_producto','operaciones'), ('tipos_producto','operaciones'), ('operaciones','operaciones'),
      ('lineas','ficha_tecnica'), ('colecciones','ficha_tecnica'), ('referencias','ficha_tecnica'), ('muestras','ficha_tecnica'),
      ('ficha_versiones','ficha_tecnica'), ('ficha_tallas','ficha_tecnica'), ('ficha_partes','ficha_tecnica'),
      ('ficha_combinaciones','ficha_tecnica'), ('ficha_combinacion_partes','ficha_tecnica'), ('ficha_medidas','ficha_tecnica'),
      ('ficha_medida_tallas','ficha_tecnica'), ('ficha_bom','ficha_tecnica'), ('ficha_bom_consumos','ficha_tecnica'),
      ('ficha_artes','ficha_tecnica'), ('ficha_ruta','ficha_tecnica'), ('ficha_operaciones','ficha_tecnica'),
      ('valores_minuto','costos')
    ) as t(tabla, modulo)
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.es_interno())', r.tabla || '_leer', r.tabla);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.puede(%L,''editar''))', r.tabla || '_insertar', r.tabla, r.modulo);
    execute format('create policy %I on public.%I for update to authenticated using (public.puede(%L,''editar'')) with check (public.puede(%L,''editar''))',
                   r.tabla || '_actualizar', r.tabla, r.modulo, r.modulo);
  end loop;
  -- los detalles de una ficha en borrador se pueden quitar
  foreach r.tabla in array array['ficha_tallas','ficha_partes','ficha_combinaciones','ficha_combinacion_partes','ficha_medidas',
                                 'ficha_medida_tallas','ficha_bom','ficha_bom_consumos','ficha_artes','ficha_ruta','ficha_operaciones']
  loop
    execute format('create policy %I on public.%I for delete to authenticated using (public.puede(''ficha_tecnica'',''editar''))', r.tabla || '_borrar', r.tabla);
  end loop;
end $$;
create policy ficha_versiones_borrar on public.ficha_versiones for delete to authenticated using (public.puede('ficha_tecnica','editar'));
-- costo estándar: lo ven todos los internos, solo lo escriben las funciones
create policy ficha_costo_leer on public.ficha_costo_estandar for select to authenticated using (public.es_interno());
create policy ficha_aprob_leer on public.ficha_aprobaciones for select to authenticated using (public.es_interno());
create policy op_historial_leer on public.operaciones_historial for select to authenticated using (public.es_interno());
create policy importaciones_leer on public.importaciones for select to authenticated using (public.es_interno());

-- Archivos de fichas (fotos, bocetos, moldes, artes) en Supabase Storage
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('fichas', 'fichas', false) on conflict (id) do nothing;
    execute $p$create policy fichas_leer on storage.objects for select to authenticated using (bucket_id = 'fichas' and public.es_interno())$p$;
    execute $p$create policy fichas_subir on storage.objects for insert to authenticated with check (bucket_id = 'fichas' and public.puede('ficha_tecnica','editar'))$p$;
    execute $p$create policy fichas_borrar on storage.objects for delete to authenticated using (bucket_id = 'fichas' and public.puede('ficha_tecnica','editar'))$p$;
  end if;
end $$;

-- Permisos nuevos: diseño edita operaciones y fichas; producción también aprueba
update public.permisos_modulo set puede_editar = true where rol = 'diseno' and modulo in ('ficha_tecnica','operaciones');
update public.permisos_modulo set puede_aprobar = true where rol in ('jefe_produccion') and modulo = 'ficha_tecnica';
update public.permisos_modulo set puede_aprobar = true where rol in ('costos') and modulo = 'ficha_tecnica';
insert into public.permisos_modulo (rol, modulo, puede_ver, puede_editar, puede_aprobar) values
  ('costos','operaciones', true, false, false), ('costos','configuracion', true, false, false)
on conflict do nothing;

-- Catálogos de sistema
insert into public.familias_producto (nombre) values ('Camisetas'), ('Buzos y chaquetas'), ('Pantalones y joggers'), ('Ropa interior');
insert into public.tipos_producto (familia_id, nombre)
select f.id, t.nombre from public.familias_producto f
join (values ('Camisetas','Camiseta cuello redondo'), ('Camisetas','Camiseta polo'), ('Buzos y chaquetas','Buzo con capota'),
             ('Buzos y chaquetas','Buzo cuello redondo'), ('Pantalones y joggers','Jogger'), ('Pantalones y joggers','Pantaloneta'))
  as t(familia, nombre) on t.familia = f.nombre;
