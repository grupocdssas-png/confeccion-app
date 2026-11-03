-- =====================================================================
-- Fase 1 · Migración 2: sistema y maestros de organización
-- (creado_en/por y actualizado_en/por los agrega aplicar_estandar_maestro)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Sistema
-- ---------------------------------------------------------------------
create table public.parametros (
  clave       text primary key,
  valor       jsonb not null,
  descripcion text not null
);

create table public.consecutivos (
  tipo      text primary key,          -- OP, PED, REM, OC, AJU…
  prefijo   text not null,
  siguiente bigint not null default 1,
  relleno   int not null default 6
);

-- Siguiente consecutivo del servidor (bloqueo de fila: nunca repite)
create or replace function public.siguiente_consecutivo(p_tipo text) returns text
language plpgsql security definer set search_path = public as $$
declare v consecutivos;
begin
  update consecutivos set siguiente = siguiente + 1 where tipo = p_tipo returning * into v;
  if not found then raise exception 'Consecutivo % no configurado', p_tipo; end if;
  return v.prefijo || '-' || lpad((v.siguiente - 1)::text, v.relleno, '0');
end $$;

create table public.alertas (
  id           uuid primary key default gen_random_uuid(),
  tipo         text not null,
  severidad    text not null default 'media' check (severidad in ('baja','media','alta')),
  entidad      text,
  entidad_id   text,
  mensaje      text not null,
  datos        jsonb,
  estado       text not null default 'abierta' check (estado in ('abierta','atendida')),
  creada_en    timestamptz not null default now(),
  atendida_por uuid,
  atendida_en  timestamptz
);
create index on public.alertas (estado, creada_en desc);

create table public.adjuntos (
  id           uuid primary key default gen_random_uuid(),
  entidad      text not null,
  entidad_id   text not null,
  tipo         text not null,
  storage_path text not null,
  nombre       text not null,
  tamano_bytes bigint,
  activo       boolean not null default true
);
create index on public.adjuntos (entidad, entidad_id);

-- ---------------------------------------------------------------------
-- Organización
-- ---------------------------------------------------------------------
create table public.procesos (
  codigo    text primary key,
  nombre    text not null,
  color_hex text not null,
  orden     int  not null
);

create table public.locaciones (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  direccion text,
  tipo      text not null check (tipo in ('planta','bodega','satelite')),
  activo    boolean not null default true
);

create table public.areas (
  id       uuid primary key default gen_random_uuid(),
  codigo   text not null unique,
  nombre   text not null,
  proceso  text references public.procesos(codigo),
  activo   boolean not null default true
);

create table public.cargos (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table public.jornadas (
  id           uuid primary key default gen_random_uuid(),
  nombre       text not null,
  horas_semana numeric(5,2) not null,
  activo       boolean not null default true
);

create table public.turnos (
  id               uuid primary key default gen_random_uuid(),
  nombre           text not null,
  hora_inicio      time not null,
  hora_fin         time not null,
  cruza_medianoche boolean not null default false,
  jornada_id       uuid references public.jornadas(id),
  activo           boolean not null default true
);

create table public.festivos (
  fecha  date primary key,
  nombre text not null
);

create table public.celulas (
  id          uuid primary key default gen_random_uuid(),
  codigo      text not null unique,
  nombre      text not null,
  area_id     uuid references public.areas(id),
  proceso     text references public.procesos(codigo),
  turno_id    uuid references public.turnos(id),
  locacion_id uuid references public.locaciones(id),
  activo      boolean not null default true
  -- grupo_incentivo_id se agrega en la Fase 8
);

create table public.empleados (
  id           uuid primary key default gen_random_uuid(),
  codigo       text not null unique,
  documento    text unique,
  nombres      text not null,
  apellidos    text not null,
  foto_path    text,
  cargo_id     uuid references public.cargos(id),
  area_id      uuid references public.areas(id),
  celula_id    uuid references public.celulas(id),
  qr           text not null unique check (qr like 'OPR-%'),
  fecha_ingreso date,
  activo       boolean not null default true
);
create index on public.empleados (celula_id);

-- Datos sensibles separados (no se sincronizan a tablets; solo gerencia / costos)
create table public.empleados_nomina (
  empleado_id   uuid primary key references public.empleados(id),
  salario_base  numeric(14,2),
  tipo_contrato text
);

alter table public.perfiles
  add constraint perfiles_empleado_fk foreign key (empleado_id) references public.empleados(id);

create table public.programacion_turnos (
  id          uuid primary key default gen_random_uuid(),
  celula_id   uuid references public.celulas(id),
  empleado_id uuid references public.empleados(id),
  turno_id    uuid not null references public.turnos(id),
  desde       date not null,
  hasta       date,
  dias_semana int[] not null default '{1,2,3,4,5}',   -- 1 = lunes … 7 = domingo
  activo      boolean not null default true,
  check ((celula_id is null) <> (empleado_id is null))
);

create table public.tipos_maquina (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,
  nombre        text not null,
  precio_minuto numeric(14,2),
  activo        boolean not null default true
);

create table public.maquinas (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique check (codigo like 'MAQ-%'),
  tipo_maquina_id uuid not null references public.tipos_maquina(id),
  marca           text,
  modelo          text,
  serie           text,
  categoria       text,
  celula_id       uuid references public.celulas(id),
  estado          text not null default 'operativa' check (estado in ('operativa','en_reparacion','baja')),
  precio_minuto   numeric(14,2),
  fecha_compra    date,
  valor_compra    numeric(14,2),
  activo          boolean not null default true
);

create table public.tallas (
  id     uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  orden  int not null,
  activo boolean not null default true
);

create table public.curvas (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table public.curva_tallas (
  curva_id   uuid not null references public.curvas(id),
  talla_id   uuid not null references public.tallas(id),
  proporcion numeric(8,3) not null check (proporcion >= 0),
  primary key (curva_id, talla_id)
);

create table public.grupos_color (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true
);

create table public.colores (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,
  nombre         text not null,
  hex            text,
  grupo_color_id uuid references public.grupos_color(id),
  activo         boolean not null default true
);

create table public.unidades_medida (
  codigo    text primary key,
  nombre    text not null,
  decimales int not null default 2
);

create table public.proveedores (
  id         uuid primary key default gen_random_uuid(),
  nit        text unique,
  nombre     text not null,
  contacto   text,
  telefono   text,
  correo     text,
  plazo_dias int,
  activo     boolean not null default true
);

create table public.satelites (
  id            uuid primary key default gen_random_uuid(),
  nit           text unique,
  nombre        text not null,
  contacto      text,
  whatsapp      text,
  procesos      text[] not null default '{}',
  tarifa_minuto numeric(14,2),
  calificacion  numeric(5,2),
  activo        boolean not null default true
);

alter table public.perfiles
  add constraint perfiles_satelite_fk foreign key (satelite_id) references public.satelites(id);

create table public.bodegas (
  id          uuid primary key default gen_random_uuid(),
  codigo      text not null unique,
  nombre      text not null,
  tipo        text not null check (tipo in ('telas','insumos','piezas_corte','producto_terminado','segundas','satelite','transito')),
  locacion_id uuid references public.locaciones(id),
  satelite_id uuid references public.satelites(id),
  activo      boolean not null default true
);

create table public.ubicaciones (
  id          uuid primary key default gen_random_uuid(),
  bodega_id   uuid not null references public.bodegas(id),
  codigo      text not null unique check (codigo like 'UB-%'),
  descripcion text,
  activo      boolean not null default true
);

create table public.canales (
  id     uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  nombre text not null,
  activo boolean not null default true
);

create table public.clientes (
  id       uuid primary key default gen_random_uuid(),
  nit      text unique,
  nombre   text not null,
  canal_id uuid references public.canales(id),
  contacto text,
  whatsapp text,
  ciudad   text,
  activo   boolean not null default true
);

-- ---------------------------------------------------------------------
-- Estaciones y dispositivos
-- ---------------------------------------------------------------------
create table public.estaciones (
  id        uuid primary key default gen_random_uuid(),
  codigo    text not null unique check (codigo ~ '^[A-Z0-9]{2,6}$'),
  nombre    text not null,
  tipo      text not null check (tipo in ('modulo','mesa_corte','bodega','calidad','entrada',
                                          'estampacion','bordado','tejidos','terminacion')),
  proceso   text references public.procesos(codigo),
  celula_id uuid references public.celulas(id),
  bodega_id uuid references public.bodegas(id),
  activo    boolean not null default true
  -- impresora_id se agrega en la Fase 2
);

create table public.dispositivos (
  id              uuid primary key default gen_random_uuid(),
  usuario_id      uuid not null unique references public.perfiles(id),
  estacion_id     uuid not null references public.estaciones(id),
  nombre          text not null,
  tipo            text not null check (tipo in ('tablet','celular','tv')),
  version_app     text,
  ultima_sync     timestamptz,
  desfase_reloj_s int,
  activo          boolean not null default true
);

-- Códigos creados sin conexión: PQ-C02-000451 (cada estación lleva su contador)
create table public.consecutivos_estacion (
  estacion_id uuid not null references public.estaciones(id),
  tipo        text not null,
  ultimo      bigint not null default 0,
  primary key (estacion_id, tipo)
);

-- ---------------------------------------------------------------------
-- Estándar: auditoría + actualizado + RLS
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locaciones','areas','cargos','jornadas','turnos','celulas','empleados',
    'programacion_turnos','tipos_maquina','maquinas','tallas','curvas','grupos_color','colores',
    'proveedores','satelites','bodegas','ubicaciones','canales','clientes','estaciones','dispositivos','adjuntos']
  loop
    perform public.aplicar_estandar_maestro(t);
  end loop;
end $$;

select public.aplicar_estandar_maestro('parametros', 'clave');
select public.aplicar_estandar_maestro('consecutivos', 'tipo');
select public.aplicar_estandar_maestro('procesos', 'codigo');
select public.aplicar_estandar_maestro('festivos', 'fecha');
select public.aplicar_estandar_maestro('unidades_medida', 'codigo');
select public.aplicar_estandar_maestro('curva_tallas', 'curva_id');
select public.aplicar_estandar_maestro('empleados_nomina', 'empleado_id');
select public.aplicar_estandar_maestro('alertas');
alter table public.consecutivos_estacion enable row level security;
