-- =====================================================================
-- Fase 2 · Migración 7: ingesta desde la bodega (sin conexión), RLS,
-- publicaciones y plantillas ZPL por defecto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Registro de manejadores: cada tabla de eventos que sube de los
-- dispositivos tiene su función ingerir_<tabla>(id, datos, dispositivo, desfase, tolerancia).
-- ---------------------------------------------------------------------
create table public.ingesta_manejadores (
  tabla   text primary key,
  funcion text not null
);
alter table public.ingesta_manejadores enable row level security;
insert into public.ingesta_manejadores values
  ('asistencia_marcas', 'ingerir_asistencia_marca'),
  ('conteo_registros', 'ingerir_conteo_registro'),
  ('traslados_rollo', 'ingerir_traslado_rollo'),
  ('trabajos_impresion', 'ingerir_trabajo_impresion');

-- Hora corregida y validación común
create or replace function public.hora_evento(p_datos jsonb, p_desfase int) returns timestamptz
language plpgsql stable as $$
declare v timestamptz := (p_datos->>'ocurrido_en')::timestamptz + make_interval(secs => p_desfase);
begin
  if v is null then raise exception 'Falta ocurrido_en'; end if;
  if v > now() + interval '2 minutes' then raise exception 'Hora del evento en el futuro (%)', v; end if;
  return v;
end $$;

create or replace function public.ingerir_conteo_registro(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_conteo conteos_fisicos;
  v_n int;
begin
  select * into v_conteo from conteos_fisicos where id = (p_datos->>'conteo_id')::uuid;
  if not found then raise exception 'Conteo inexistente'; end if;
  if v_conteo.estado <> 'abierto' and not exists (select 1 from conteo_registros where id = p_id) then
    raise exception 'El conteo % ya fue cerrado; el registro no se tuvo en cuenta', v_conteo.consecutivo;
  end if;
  insert into conteo_registros (id, conteo_id, rollo_id, material_id, color_id, ubicacion_id, cantidad, anula_id, dispositivo_id, ocurrido_en)
  values (p_id, v_conteo.id, (p_datos->>'rollo_id')::uuid,
          coalesce((p_datos->>'material_id')::uuid, (select material_id from rollos where id = (p_datos->>'rollo_id')::uuid)),
          coalesce((p_datos->>'color_id')::uuid, (select color_id from rollos where id = (p_datos->>'rollo_id')::uuid)),
          (p_datos->>'ubicacion_id')::uuid, (p_datos->>'cantidad')::numeric, (p_datos->>'anula_id')::uuid,
          p_disp.id, hora_evento(p_datos, p_desfase))
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

create or replace function public.ingerir_traslado_rollo(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return aplicar_traslado(p_id, (p_datos->>'rollo_id')::uuid, (p_datos->>'ubicacion_destino_id')::uuid,
                          hora_evento(p_datos, p_desfase), p_disp.id);
end $$;

create or replace function public.ingerir_trabajo_impresion(
  p_id uuid, p_datos jsonb, p_disp public.dispositivos, p_desfase int, p_tolerancia int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into trabajos_impresion (id, impresora_id, plantilla_id, plantilla_version, entidad, entidad_id, codigo, medio,
                                  es_reimpresion, motivo, estado_final, intentos, error, dispositivo_id, ocurrido_en)
  values (p_id, (p_datos->>'impresora_id')::uuid, (p_datos->>'plantilla_id')::uuid, (p_datos->>'plantilla_version')::int,
          p_datos->>'entidad', (p_datos->>'entidad_id')::uuid, p_datos->>'codigo', coalesce(p_datos->>'medio', 'tcp'),
          coalesce((p_datos->>'es_reimpresion')::boolean, false), p_datos->>'motivo',
          coalesce(p_datos->>'estado_final', 'enviado'), coalesce((p_datos->>'intentos')::int, 1), p_datos->>'error',
          p_disp.id, hora_evento(p_datos, p_desfase))
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

revoke all on function public.ingerir_conteo_registro(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
revoke all on function public.ingerir_traslado_rollo(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
revoke all on function public.ingerir_trabajo_impresion(uuid, jsonb, public.dispositivos, int, int) from public, anon, authenticated;
revoke all on function public.aplicar_traslado(uuid, uuid, uuid, timestamptz, uuid) from public, anon, authenticated;

-- ingerir_eventos: ahora despacha por el registro de manejadores
create or replace function public.ingerir_eventos(p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_disp       dispositivos;
  v_desfase    int;
  v_tolerancia int := coalesce((select (valor #>> '{}')::int from parametros where clave = 'tolerancia_reloj_s'), 300);
  v_ev         jsonb;
  v_id         uuid;
  v_funcion    text;
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
  update dispositivos set ultima_sync = now(), desfase_reloj_s = v_desfase,
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
    v_id := null;
    begin
      v_id := (v_ev->>'id')::uuid;
      if coalesce(v_ev->>'op', 'PUT') <> 'PUT' then
        raise exception 'Los eventos solo se agregan; operación % no permitida', v_ev->>'op';
      end if;
      select funcion into v_funcion from ingesta_manejadores where tabla = v_ev->>'tabla';
      if v_funcion is null then raise exception 'Tabla % no admitida en la ingesta', v_ev->>'tabla'; end if;
      execute format('select public.%I($1, $2, $3, $4, $5)', v_funcion)
        into v_insertado using v_id, v_ev->'datos', v_disp, v_desfase, v_tolerancia;
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
        set intentos = ingesta_eventos.intentos + 1, recibido_en = now(),
            estado = case when ingesta_eventos.estado = 'aceptado' then 'aceptado' else excluded.estado end,
            motivo = case when ingesta_eventos.estado = 'aceptado' then null else excluded.motivo end;
    end if;
    v_resultados := v_resultados || jsonb_build_object('id', v_ev->>'id', 'estado', v_estado, 'motivo', v_motivo);
  end loop;

  return jsonb_build_object('hora_servidor', now(), 'desfase_reloj_s', v_desfase, 'resultados', v_resultados);
end $$;

-- ---------------------------------------------------------------------
-- RLS. Escribir directo solo en documentos en borrador y maestros; el
-- kardex, los saldos y los rollos solo cambian por funciones.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  -- lectura: internos con permiso de ver inventario (o compras/costos/corte por sus módulos)
  foreach t in array array['categorias_material','materiales','rollos','movimientos_inventario','saldos_inventario',
                           'recepciones','recepcion_lineas','ajustes_inventario','ajuste_lineas','conteos_fisicos',
                           'conteo_registros','traslados_rollo']
  loop
    execute format($f$create policy %I on public.%I for select to authenticated
      using (public.puede('inventario','ver') or public.puede('compras','ver') or public.puede('costos','ver')
             or public.puede('corte','ver'))$f$, t || '_leer', t);
  end loop;
  -- maestros y documentos en borrador: módulo inventario con "editar"
  foreach t in array array['categorias_material','materiales','recepciones','recepcion_lineas','ajustes_inventario',
                           'ajuste_lineas','conteos_fisicos']
  loop
    execute format($f$create policy %I on public.%I for insert to authenticated with check (public.puede('inventario','editar'))$f$, t || '_insertar', t);
    execute format($f$create policy %I on public.%I for update to authenticated
      using (public.puede('inventario','editar')) with check (public.puede('inventario','editar'))$f$, t || '_actualizar', t);
  end loop;
  -- líneas en borrador se pueden quitar
  execute $f$create policy recepcion_lineas_borrar on public.recepcion_lineas for delete to authenticated using (public.puede('inventario','editar'))$f$;
  execute $f$create policy ajuste_lineas_borrar on public.ajuste_lineas for delete to authenticated using (public.puede('inventario','editar'))$f$;
end $$;

-- Un ajuste no se aprueba con un UPDATE directo: solo con decidir_ajuste()
create or replace function public.fn_ajuste_estado_protegido() returns trigger
language plpgsql as $$
begin
  if new.estado is distinct from old.estado and not public.es_conexion_directa()
     and current_setting('app.cambio_ajuste', true) is distinct from 'si' then
    raise exception 'El estado del ajuste solo cambia con enviar_ajuste() o decidir_ajuste()';
  end if;
  if new.estado = 'borrador' or old.estado = 'borrador' then return new; end if;
  if (new.motivo, new.origen) is distinct from (old.motivo, old.origen) then
    raise exception 'El ajuste ya fue enviado: no se puede modificar';
  end if;
  return new;
end $$;
create trigger ajustes_estado_protegido before update on public.ajustes_inventario
  for each row execute function public.fn_ajuste_estado_protegido();

-- Impresoras y plantillas: configuración
create policy impresoras_leer on public.impresoras for select to authenticated using (public.es_interno());
create policy impresoras_insertar on public.impresoras for insert to authenticated with check (public.puede('configuracion','editar'));
create policy impresoras_actualizar on public.impresoras for update to authenticated
  using (public.puede('configuracion','editar')) with check (public.puede('configuracion','editar'));
create policy plantillas_leer on public.plantillas_etiqueta for select to authenticated using (public.es_interno());
create policy plantillas_insertar on public.plantillas_etiqueta for insert to authenticated with check (public.puede('configuracion','editar'));
create policy plantillas_actualizar on public.plantillas_etiqueta for update to authenticated
  using (public.puede('configuracion','editar')) with check (public.puede('configuracion','editar'));

-- Impresiones: la web las registra directo (es un evento: solo se agrega)
create policy impresion_leer on public.trabajos_impresion for select to authenticated using (public.es_interno());
create policy impresion_registrar on public.trabajos_impresion for insert to authenticated
  with check (public.es_interno() and usuario_id = auth.uid() and dispositivo_id is null);

-- ---------------------------------------------------------------------
-- Publicaciones
-- ---------------------------------------------------------------------
alter publication powersync add table
  public.materiales, public.bodegas, public.ubicaciones, public.rollos, public.conteos_fisicos,
  public.impresoras, public.plantillas_etiqueta;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.conteo_registros, public.rollos;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Datos de sistema: categorías y plantillas ZPL por defecto (editables)
-- 203 dpi: 100 × 50 mm = 800 × 400 puntos. QR modelo 2, corrección M.
-- ---------------------------------------------------------------------
insert into public.categorias_material (nombre, tipo) values
  ('Tejido de punto', 'tela'), ('Tejido plano', 'tela'), ('Rib y complementos', 'tela'),
  ('Hilos', 'insumo'), ('Marquillas y etiquetas', 'insumo'), ('Elásticos y cordones', 'insumo'),
  ('Cremalleras y botones', 'insumo'), ('Empaque', 'insumo');

insert into public.plantillas_etiqueta (tipo, tamano, nombre, zpl) values
('rollo', '100x50', 'Rollo de tela 100 × 50 mm',
'^XA
^CI28
^PW800
^LL400
^LH0,0
^FO20,40^BQN,2,11^FDMA,{{codigo}}^FS
^FO300,28^A0N,52,52^FD{{codigo}}^FS
^FO300,90^A0N,30,30^FB480,2,0,L^FD{{tela}}^FS
^FO300,160^A0N,30,30^FDColor: {{color}}^FS
^FO300,198^A0N,30,30^FDLote: {{lote}}   Tono: {{tono}}^FS
^FO300,236^A0N,30,30^FDAncho: {{ancho}} cm^FS
^FO300,274^A0N,34,34^FD{{metros}} m   {{kilos}} kg^FS
^FO20,322^GB760,2,2^FS
^FO20,336^A0N,24,24^FD{{proveedor}}^FS
^FO20,366^A0N,24,24^FDIngreso: {{fecha}}   Ubicación: {{ubicacion}}^FS
^PQ{{copias}}
^XZ'),
('ubicacion', '100x50', 'Ubicación de bodega 100 × 50 mm',
'^XA
^CI28
^PW800
^LL400
^LH0,0
^FO30,60^BQN,2,11^FDMA,{{codigo}}^FS
^FO320,70^A0N,70,70^FB460,2,0,L^FD{{codigo}}^FS
^FO320,230^A0N,34,34^FB460,2,0,L^FD{{bodega}}^FS
^FO320,310^A0N,28,28^FB460,2,0,L^FD{{descripcion}}^FS
^PQ{{copias}}
^XZ');
