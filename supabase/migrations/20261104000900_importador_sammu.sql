-- =====================================================================
-- Fase 3 · Migración 9: importador ajustado al archivo real de SAMMU
-- (secuencia por referencia: Secuencia; Nombre; Sitio de trabajo; Sam;
--  Proceso; Repeticiones; Operación contadora; Es Operación de revision;
--  sam de reproceso; Deshabilitar talla y color; Habilitar cambiar
--  unidades; Unidades al marcar; Precio)
-- =====================================================================

-- Campos que trae SAMMU por operación (se usan en la tablet en la Fase 6)
alter table public.operaciones
  add column sam_reproceso            numeric(8,4) check (sam_reproceso > 0),
  add column unidades_marcacion       int check (unidades_marcacion > 0),   -- null = parámetro general
  add column permite_cambiar_unidades boolean not null default false,
  add column sin_talla_color          boolean not null default false;

alter table public.ficha_operaciones
  add column sam_reproceso            numeric(8,4),
  add column unidades_marcacion       int check (unidades_marcacion > 0),
  add column permite_cambiar_unidades boolean,
  add column sin_talla_color          boolean;

-- La copia desde la lista maestra incluye los campos nuevos
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
    new.sam_reproceso := coalesce(new.sam_reproceso, o.sam_reproceso);
    new.unidades_marcacion := coalesce(new.unidades_marcacion, o.unidades_marcacion);
    new.permite_cambiar_unidades := coalesce(new.permite_cambiar_unidades, o.permite_cambiar_unidades);
    new.sin_talla_color := coalesce(new.sin_talla_color, o.sin_talla_color);
  end if;
  return new;
end $$;

alter table public.importaciones drop constraint importaciones_tipo_check;
alter table public.importaciones add constraint importaciones_tipo_check
  check (tipo in ('operaciones','secuencia','empleados','celulas','maquinas','op_activas'));
alter table public.importaciones add column resumen jsonb;

insert into public.consecutivos (tipo, prefijo, relleno) values ('OPE', 'OP', 4) on conflict do nothing;

-- Texto comparable: minúsculas, sin tildes, espacios simples ("Montar  Puño" = "montar puno")
create or replace function public.normalizar_texto(p text) returns text
language sql immutable as $$
  select regexp_replace(translate(lower(trim(coalesce(p, ''))), 'áéíóúüñàèìòù', 'aeiouunaeiou'), '\s+', ' ', 'g')
$$;

-- "TRUE", "VERDADERO", "Sí", "X", "1" → true; vacío → null
create or replace function public.a_booleano(p text) returns boolean
language sql immutable as $$
  select case when nullif(trim(coalesce(p, '')), '') is null then null
              else normalizar_texto(p) in ('true','verdadero','si','s','x','1','yes') end
$$;

-- Busca el tipo de máquina por código o nombre; si no existe y se permite, lo crea.
create or replace function public.maquina_para_importar(p_texto text, p_crear boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if nullif(trim(coalesce(p_texto, '')), '') is null then return null; end if;
  select id into v from tipos_maquina
   where normalizar_texto(codigo) = normalizar_texto(p_texto) or normalizar_texto(nombre) = normalizar_texto(p_texto)
   limit 1;
  if v is null and p_crear then
    insert into tipos_maquina (codigo, nombre) values (upper(trim(p_texto)), upper(trim(p_texto)) || ' (importado de SAMMU)')
    returning id into v;
  end if;
  if v is null then
    raise exception 'Tipo de máquina "%" no existe (créelo o marque "Crear tipos de máquina que no existan")', p_texto;
  end if;
  return v;
end $$;

drop function if exists public.validar_importacion(text, jsonb);
drop function if exists public.importar(text, jsonb, text, boolean);

-- p_opciones: { crear_maquinas: bool, ficha_id: uuid (secuencia), reemplazar: bool (secuencia, por defecto true),
--               familia_id, tipo_producto_id (operaciones sin familia en el archivo) }
create or replace function public.importar(p_tipo text, p_filas jsonb, p_archivo text default null,
                                           p_opciones jsonb default '{}', p_solo_validar boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f jsonb;
  i int := 0;
  v_ok int := 0;
  v_err jsonb := '[]';
  v_crear boolean := coalesce((p_opciones->>'crear_maquinas')::boolean, false);
  v_ficha ficha_versiones;
  v_ref referencias;
  v_familia uuid := (p_opciones->>'familia_id')::uuid;
  v_tipo uuid := (p_opciones->>'tipo_producto_id')::uuid;
  v_op operaciones;
  v_maq uuid;
  v_proceso text;
  v_sam numeric;
  v_nuevas int := 0;
  v_existentes int := 0;
  v_sam_cambiados jsonb := '[]';
  v_maquinas_antes int := (select count(*) from tipos_maquina);
  v_resumen jsonb;
begin
  perform exigir_permiso(case p_tipo when 'operaciones' then 'operaciones' when 'secuencia' then 'ficha_tecnica'
                                     when 'maquinas' then 'mantenimiento' when 'empleados' then 'personal' else 'configuracion' end, 'editar');
  if p_tipo = 'secuencia' then
    perform exigir_permiso('operaciones', 'editar');
    -- referencia nueva (ej. desde el nombre del archivo): se crea con su versión 1 en borrador
    if (p_opciones->>'ficha_id') is null and p_opciones ? 'nueva_referencia' then
      p_opciones := p_opciones || jsonb_build_object('ficha_id', nueva_referencia(
        p_opciones->'nueva_referencia'->>'codigo', p_opciones->'nueva_referencia'->>'nombre',
        (p_opciones->'nueva_referencia'->>'familia_id')::uuid, (p_opciones->'nueva_referencia'->>'tipo_producto_id')::uuid));
    end if;
    select * into v_ficha from ficha_versiones where id = (p_opciones->>'ficha_id')::uuid;
    if not found then raise exception 'Elija la ficha técnica a la que pertenece la secuencia'; end if;
    if v_ficha.estado <> 'borrador' then raise exception 'La ficha v% está %: importe sobre una versión en borrador', v_ficha.version, v_ficha.estado; end if;
    select * into v_ref from referencias where id = v_ficha.referencia_id;
    v_familia := coalesce(v_familia, v_ref.familia_id);
    v_tipo := coalesce(v_tipo, v_ref.tipo_producto_id);
    if coalesce((p_opciones->>'reemplazar')::boolean, true) then
      delete from ficha_operaciones where ficha_id = v_ficha.id;
    end if;
  end if;
  perform set_config('app.origen_operacion', 'importacion', true);

  for f in select * from jsonb_array_elements(p_filas) loop
    i := i + 1;
    begin
      case p_tipo
        when 'operaciones', 'secuencia' then
          if nullif(trim(coalesce(f->>'nombre', '')), '') is null then raise exception 'Falta el nombre de la operación'; end if;
          v_sam := (f->>'sam')::numeric;
          if v_sam is null or v_sam <= 0 then raise exception 'SAM inválido: "%"', f->>'sam'; end if;
          v_maq := maquina_para_importar(f->>'maquina', v_crear);
          v_proceso := coalesce((select codigo from procesos where normalizar_texto(nombre) = normalizar_texto(f->>'proceso')
                                                              or codigo = normalizar_texto(f->>'proceso')), 'confeccion');
          if p_tipo = 'operaciones' and (f->>'familia') is not null then
            v_familia := (select id from familias_producto where normalizar_texto(nombre) = normalizar_texto(f->>'familia'));
            v_tipo := (select t.id from tipos_producto t where t.familia_id = v_familia and normalizar_texto(t.nombre) = normalizar_texto(f->>'tipo_producto'));
          end if;

          -- La operación se identifica por código; si el archivo no trae código, por nombre dentro del mismo tipo de producto
          v_op := null;
          if nullif(trim(coalesce(f->>'codigo', '')), '') is not null then
            select * into v_op from operaciones where codigo = upper(trim(f->>'codigo'));
          else
            select * into v_op from operaciones
             where normalizar_texto(nombre) = normalizar_texto(f->>'nombre')
               and tipo_producto_id is not distinct from v_tipo
               and (v_tipo is not null or familia_id is not distinct from v_familia)
             order by activo desc, creado_en limit 1;
          end if;

          if v_op.id is null then
            insert into operaciones (codigo, nombre, familia_id, tipo_producto_id, proceso, sam, valor_destajo, tipo_maquina_id, repeticiones,
                                     tipo, sam_reproceso, unidades_marcacion, permite_cambiar_unidades, sin_talla_color, parte, restrictiva)
            values (coalesce(nullif(upper(trim(f->>'codigo')), ''), siguiente_consecutivo('OPE')), upper(trim(f->>'nombre')),
                    v_familia, v_tipo, v_proceso, v_sam, coalesce((f->>'valor_destajo')::numeric, 0), v_maq,
                    coalesce((f->>'repeticiones')::numeric, 1),
                    case when a_booleano(f->>'revision') then 'inspeccion' else 'normal' end,
                    (f->>'sam_reproceso')::numeric, (f->>'unidades_marcacion')::int,
                    coalesce(a_booleano(f->>'cambiar_unidades'), false), coalesce(a_booleano(f->>'sin_talla_color'), false),
                    nullif(trim(f->>'parte'), ''), coalesce(a_booleano(f->>'restrictiva'), false))
            returning * into v_op;
            v_nuevas := v_nuevas + 1;
          else
            v_existentes := v_existentes + 1;
            if v_op.sam <> v_sam then
              v_sam_cambiados := v_sam_cambiados || jsonb_build_object('codigo', v_op.codigo, 'nombre', v_op.nombre, 'antes', v_op.sam, 'ahora', v_sam);
            end if;
            update operaciones set
              sam = v_sam,
              nombre = case when p_tipo = 'operaciones' then upper(trim(f->>'nombre')) else nombre end,
              valor_destajo = coalesce((f->>'valor_destajo')::numeric, valor_destajo),
              tipo_maquina_id = coalesce(v_maq, tipo_maquina_id),
              proceso = v_proceso,
              familia_id = coalesce(v_familia, familia_id),
              tipo_producto_id = coalesce(v_tipo, tipo_producto_id),
              sam_reproceso = coalesce((f->>'sam_reproceso')::numeric, sam_reproceso),
              unidades_marcacion = coalesce((f->>'unidades_marcacion')::int, unidades_marcacion),
              permite_cambiar_unidades = coalesce(a_booleano(f->>'cambiar_unidades'), permite_cambiar_unidades),
              sin_talla_color = coalesce(a_booleano(f->>'sin_talla_color'), sin_talla_color),
              tipo = case when a_booleano(f->>'revision') then 'inspeccion' else tipo end,
              repeticiones = case when p_tipo = 'operaciones' then coalesce((f->>'repeticiones')::numeric, repeticiones) else repeticiones end
            where id = v_op.id;
          end if;

          if p_tipo = 'secuencia' then
            if (f->>'secuencia') is null then raise exception 'Falta el número de secuencia'; end if;
            insert into ficha_operaciones (ficha_id, secuencia, operacion_id, proceso, repeticiones, es_contadora, unidades_marcacion,
                                           sam_reproceso, permite_cambiar_unidades, sin_talla_color)
            values (v_ficha.id, (f->>'secuencia')::numeric::int, v_op.id, v_proceso, coalesce((f->>'repeticiones')::numeric, 1),
                    coalesce(a_booleano(f->>'contadora'), false), (f->>'unidades_marcacion')::int, (f->>'sam_reproceso')::numeric,
                    a_booleano(f->>'cambiar_unidades'), a_booleano(f->>'sin_talla_color'));
            -- la ruta de la ficha incluye los procesos de la secuencia
            insert into ficha_ruta (ficha_id, proceso, orden)
            select v_ficha.id, v_proceso, (select orden from procesos where codigo = v_proceso)
            where not exists (select 1 from ficha_ruta where ficha_id = v_ficha.id and proceso = v_proceso);
          end if;

        when 'celulas' then
          insert into celulas (codigo, nombre, proceso, area_id, turno_id)
          values (upper(trim(f->>'codigo')), trim(f->>'nombre'),
                  coalesce((select codigo from procesos where normalizar_texto(nombre) = normalizar_texto(f->>'proceso') or codigo = normalizar_texto(f->>'proceso')), 'confeccion'),
                  (select id from areas where normalizar_texto(codigo) = normalizar_texto(f->>'area') or normalizar_texto(nombre) = normalizar_texto(f->>'area')),
                  (select id from turnos where normalizar_texto(nombre) = normalizar_texto(f->>'turno')))
          on conflict (codigo) do update set nombre = excluded.nombre, proceso = excluded.proceso,
            area_id = coalesce(excluded.area_id, celulas.area_id), turno_id = coalesce(excluded.turno_id, celulas.turno_id);
        when 'empleados' then
          if (f->>'celula') is not null and trim(f->>'celula') <> '' and not exists (select 1 from celulas where normalizar_texto(codigo) = normalizar_texto(f->>'celula')) then
            raise exception 'Célula "%" no existe (importe primero las células)', f->>'celula';
          end if;
          insert into empleados (codigo, documento, nombres, apellidos, celula_id, cargo_id, qr, fecha_ingreso)
          values (upper(trim(f->>'codigo')), nullif(trim(f->>'documento'), ''), trim(f->>'nombres'), coalesce(trim(f->>'apellidos'), ''),
                  (select id from celulas where normalizar_texto(codigo) = normalizar_texto(f->>'celula')),
                  (select id from cargos where normalizar_texto(nombre) = normalizar_texto(f->>'cargo')),
                  'OPR-' || lpad(regexp_replace(f->>'codigo', '\D', '', 'g'), 4, '0'),
                  (f->>'fecha_ingreso')::date)
          on conflict (codigo) do update set nombres = excluded.nombres, apellidos = excluded.apellidos,
            documento = coalesce(excluded.documento, empleados.documento),
            celula_id = coalesce(excluded.celula_id, empleados.celula_id), cargo_id = coalesce(excluded.cargo_id, empleados.cargo_id);
        when 'maquinas' then
          insert into maquinas (codigo, tipo_maquina_id, marca, modelo, serie, celula_id)
          values (case when upper(trim(f->>'codigo')) like 'MAQ-%' then upper(trim(f->>'codigo')) else 'MAQ-' || upper(trim(f->>'codigo')) end,
                  maquina_para_importar(f->>'tipo', v_crear),
                  nullif(trim(f->>'marca'), ''), nullif(trim(f->>'modelo'), ''), nullif(trim(f->>'serie'), ''),
                  (select id from celulas where normalizar_texto(codigo) = normalizar_texto(f->>'celula')))
          on conflict (codigo) do update set tipo_maquina_id = excluded.tipo_maquina_id, marca = coalesce(excluded.marca, maquinas.marca),
            modelo = coalesce(excluded.modelo, maquinas.modelo), serie = coalesce(excluded.serie, maquinas.serie),
            celula_id = coalesce(excluded.celula_id, maquinas.celula_id);
        else raise exception 'Tipo de importación no soportado todavía: %', p_tipo;
      end case;
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object('fila', i, 'codigo', coalesce(f->>'codigo', f->>'secuencia'), 'nombre', f->>'nombre', 'error', sqlerrm);
    end;
  end loop;

  v_resumen := jsonb_build_object(
    'operaciones_nuevas', v_nuevas, 'operaciones_existentes', v_existentes, 'sam_cambiados', v_sam_cambiados,
    'maquinas_creadas', (select count(*) from tipos_maquina) - v_maquinas_antes,
    'sam_total', case when p_tipo = 'secuencia' then sam_total_ficha(v_ficha.id) end,
    'ficha_id', v_ficha.id);

  if p_solo_validar then
    raise exception using errcode = 'P0002', message = jsonb_build_object('ok', v_ok, 'errores', v_err, 'resumen', v_resumen)::text;
  end if;
  insert into importaciones (tipo, archivo, filas_ok, filas_error, errores, resumen)
  values (p_tipo, p_archivo, v_ok, jsonb_array_length(v_err), v_err, v_resumen);
  return jsonb_build_object('ok', v_ok, 'errores', v_err, 'resumen', v_resumen);
end $$;

-- Validar sin guardar: hace todo y lo deshace
create or replace function public.validar_importacion(p_tipo text, p_filas jsonb, p_opciones jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform importar(p_tipo, p_filas, null, p_opciones, true);
  return null;
exception when sqlstate 'P0002' then
  return sqlerrm::jsonb;
end $$;
