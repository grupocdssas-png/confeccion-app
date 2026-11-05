-- =====================================================================
-- Fase 11 · Migración 18: integraciones con Alegra (contabilidad,
-- inventario y nómina) y WhatsApp Cloud API.
--
-- Diseño: todo lo que sale hacia afuera pasa por una COLA (outbox) que se
-- llena con disparadores dentro de la misma transacción del hecho de
-- negocio. Una Edge Function (supabase/functions/integraciones) la procesa
-- con las claves que viven solo en los secretos de Supabase, reintenta con
-- espera creciente y nunca envía dos veces (clave de idempotencia).
-- Lo que llega de Alegra (nómina, estado de pagos, enlaces) entra por
-- funciones de este archivo que solo puede llamar el servicio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ajustes (no secretos) y enlaces con Alegra
-- ---------------------------------------------------------------------
create table public.integracion_ajustes (
  clave       text primary key,
  valor       jsonb,
  descripcion text not null
);
insert into public.integracion_ajustes (clave, valor, descripcion) values
  ('alegra_activo', 'false', 'Enviar a Alegra (si está apagado, la cola se llena pero no se envía)'),
  ('alegra_bodega_pt', null, 'Bodega de Alegra donde entra el producto terminado'),
  ('alegra_bodega_segundas', null, 'Bodega de Alegra para segundas (imperfectos)'),
  ('alegra_bodega_mp', null, 'Bodega de Alegra de materia prima (telas)'),
  ('alegra_bodega_insumos', null, 'Bodega de Alegra de insumos'),
  ('alegra_lista_precio_remision', null, 'Lista de precios para las remisiones a clientes'),
  ('alegra_impuesto_iva', null, 'Impuesto (IVA) de los productos nuevos'),
  ('alegra_categoria_item', null, 'Categoría de los productos nuevos (opcional)'),
  ('alegra_cuenta_satelites', null, 'Cuenta contable de los documentos soporte de satélites (servicio de maquila)'),
  ('alegra_numeracion_ds', null, 'Numeración de documento soporte'),
  ('alegra_concepto_incentivo', null, 'Concepto de ingreso de Alegra Nómina para los incentivos'),
  ('whatsapp_activo', 'false', 'Enviar mensajes de WhatsApp (si está apagado se simulan)'),
  ('whatsapp_idioma', '"es"', 'Idioma de las plantillas aprobadas por Meta'),
  ('whatsapp_hora_inicio', '6', 'No enviar antes de esta hora (Bogotá)'),
  ('whatsapp_hora_fin', '21', 'No enviar después de esta hora (Bogotá)'),
  ('alerta_paro_largo_min', '30', 'Minutos de un paro para avisar por WhatsApp')
on conflict (clave) do nothing;

alter table public.skus        add column if not exists alegra_id text;
alter table public.materiales  add column if not exists alegra_id text;
alter table public.proveedores add column if not exists alegra_id text;
alter table public.satelites   add column if not exists alegra_id text;
alter table public.clientes    add column if not exists alegra_id text,
                               add column if not exists alegra_bodega_id text;   -- tienda propia: despacho = traslado de bodega
alter table public.empleados   add column if not exists alegra_id text;
comment on column public.clientes.alegra_bodega_id is 'Si el cliente es una tienda propia, la bodega de Alegra a la que se traslada';

create or replace function public.ajuste_integracion(p_clave text) returns text
language sql stable security definer set search_path = public as $$
  select valor #>> '{}' from integracion_ajustes where clave = p_clave
$$;

-- ---------------------------------------------------------------------
-- Cola de envíos (outbox)
-- ---------------------------------------------------------------------
create table public.integraciones_cola (
  id              uuid primary key default gen_random_uuid(),
  sistema         text not null check (sistema in ('alegra','whatsapp')),
  tipo            text not null check (tipo in ('crear_item','ajuste_pt','despacho','anular_despacho','factura_proveedor',
                                                'ajuste_consumo','documento_soporte','concepto_nomina','mensaje')),
  clave           text not null,                 -- idempotencia: nunca dos trabajos con la misma clave
  entidad         text,
  entidad_id      text,
  descripcion     text not null,
  datos           jsonb not null default '{}',
  estado          text not null default 'pendiente' check (estado in ('pendiente','enviando','enviado','bloqueado','error','descartado')),
  intentos        int not null default 0,
  proximo_intento timestamptz not null default now(),
  externo_id      text,                          -- id del documento en Alegra / mensaje en WhatsApp
  respuesta       jsonb,
  error           text,
  creado_en       timestamptz not null default now(),
  enviado_en      timestamptz,
  actualizado_en  timestamptz not null default now(),
  unique (sistema, clave)
);
create index on public.integraciones_cola (estado, proximo_intento);
create index on public.integraciones_cola (entidad, entidad_id);
alter table public.integraciones_cola enable row level security;

create table public.integraciones_intentos (
  id        bigint generated always as identity primary key,
  cola_id   uuid not null references public.integraciones_cola(id) on delete cascade,
  en        timestamptz not null default now(),
  ok        boolean not null,
  detalle   text
);
alter table public.integraciones_intentos enable row level security;

create or replace function public.encolar(p_sistema text, p_tipo text, p_clave text, p_entidad text, p_entidad_id text,
                                          p_descripcion text, p_datos jsonb, p_cuando timestamptz default now())
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into integraciones_cola (sistema, tipo, clave, entidad, entidad_id, descripcion, datos, proximo_intento)
  values (p_sistema, p_tipo, p_clave, p_entidad, p_entidad_id, p_descripcion, coalesce(p_datos, '{}'), p_cuando)
  on conflict (sistema, clave) do nothing
  returning id into v;
  return v;
end $$;
revoke all on function public.encolar(text, text, text, text, text, text, jsonb, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Disparadores: qué se encola y cuándo
-- ---------------------------------------------------------------------
-- 1. Ficha aprobada → productos nuevos en Alegra (uno por color/combinación y talla)
create or replace function public.fn_items_ficha_aprobada() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_sku uuid;
  s skus;
begin
  if new.estado <> 'aprobada' or old.estado = 'aprobada' then return new; end if;
  for r in select c.codigo as comb, c.nombre as comb_nombre, t.id as talla_id, t.codigo as talla, ref.id as ref_id, ref.codigo as ref_codigo,
                  ref.nombre as ref_nombre
           from ficha_combinaciones c join ficha_tallas ft on ft.ficha_id = c.ficha_id join tallas t on t.id = ft.talla_id
           join referencias ref on ref.id = new.referencia_id
           where c.ficha_id = new.id loop
    v_sku := sku_de(r.ref_id, r.comb, r.talla_id);
    select * into s from skus where id = v_sku;
    if s.precio_venta is null and new.precio_objetivo is not null then
      update skus set precio_venta = new.precio_objetivo where id = v_sku;
    end if;
    if s.alegra_id is null then
      perform encolar('alegra', 'crear_item', 'item:' || v_sku, 'skus', v_sku::text,
                      'Crear producto ' || s.codigo,
                      jsonb_build_object('sku_id', v_sku, 'codigo', s.codigo,
                                         'nombre', upper(r.ref_nombre || ' ' || r.comb_nombre || ' / ' || r.talla),
                                         'referencia', r.ref_codigo, 'precio', coalesce(s.precio_venta, new.precio_objetivo, 0),
                                         'costo', (select round(avg(valor), 0) from ficha_costo_estandar where ficha_id = new.id and concepto = 'total')));
    end if;
  end loop;
  return new;
end $$;
create trigger fichas_items_alegra after update of estado on public.ficha_versiones for each row execute function public.fn_items_ficha_aprobada();

-- 2. Entra producto terminado o segundas → ajuste de entrada en Alegra
create or replace function public.fn_ajuste_pt_alegra() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tipo not in ('ingreso_op','ingreso_segunda','ajuste','traslado') then return new; end if;
  perform encolar('alegra', 'ajuste_pt', 'mp:' || new.id, 'movimientos_producto', new.id::text,
                  (case new.tipo when 'ingreso_op' then 'Entrada a producto terminado ' when 'ingreso_segunda' then 'Entrada a segundas '
                        else initcap(new.tipo) || ' ' end) || coalesce(new.documento, '') || ' · ' || (select codigo from skus where id = new.sku_id),
                  jsonb_build_object('movimiento_id', new.id, 'sku_id', new.sku_id, 'cantidad', new.cantidad,
                                     'bodega', (select tipo from bodegas where id = new.bodega_id),
                                     'observacion', coalesce(new.documento, '') ||
                                        coalesce(' · ' || (select consecutivo from ordenes_produccion where id = new.op_id), '') ||
                                        coalesce(' · ' || new.motivo, '')));
  return new;
end $$;
create trigger movimientos_producto_alegra after insert on public.movimientos_producto for each row execute function public.fn_ajuste_pt_alegra();

-- 3. Despacho (y su anulación) → traslado a tienda propia o remisión al cliente
create or replace function public.fn_despacho_alegra() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.estado = 'anulado' and old.estado <> 'anulado' then
      perform encolar('alegra', 'anular_despacho', 'desanul:' || new.id, 'despachos', new.id::text, 'Anular ' || new.consecutivo,
                      jsonb_build_object('despacho_id', new.id, 'consecutivo', new.consecutivo, 'motivo', new.motivo_anulacion));
    end if;
    return new;
  end if;
  -- el despacho se encola cuando ya tiene sus líneas (al final de la transacción de despachar)
  perform encolar('alegra', 'despacho', 'des:' || new.id, 'despachos', new.id::text, 'Despacho ' || new.consecutivo,
                  jsonb_build_object('despacho_id', new.id, 'consecutivo', new.consecutivo));
  return new;
end $$;
create trigger despachos_alegra after insert or update of estado on public.despachos for each row execute function public.fn_despacho_alegra();

-- 4. Recepción confirmada con factura → factura de proveedor
create or replace function public.fn_recepcion_alegra() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'confirmada' and old.estado <> 'confirmada' and coalesce(trim(new.factura_proveedor), '') <> '' then
    perform encolar('alegra', 'factura_proveedor', 'rec:' || new.id, 'recepciones', new.id::text,
                    'Factura ' || new.factura_proveedor || ' de ' || coalesce((select nombre from proveedores where id = new.proveedor_id), 'proveedor')
                      || ' (' || new.consecutivo || ')',
                    jsonb_build_object('recepcion_id', new.id));
  end if;
  return new;
end $$;
create trigger recepciones_alegra after update of estado on public.recepciones for each row execute function public.fn_recepcion_alegra();

-- 5. Cuenta de satélite aprobada → documento soporte
create or replace function public.fn_cuenta_satelite_alegra() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'aprobada' and old.estado <> 'aprobada' then
    perform encolar('alegra', 'documento_soporte', 'cps:' || new.id, 'cuentas_pagar_satelite', new.id::text,
                    'Documento soporte ' || new.consecutivo || ' · ' || (select nombre from satelites where id = new.satelite_id),
                    jsonb_build_object('cuenta_id', new.id));
  end if;
  if new.estado = 'pagada' and old.estado <> 'pagada' and (select whatsapp from satelites where id = new.satelite_id) is not null then
    perform encolar('whatsapp', 'mensaje', 'wa:pago:' || new.id, 'cuentas_pagar_satelite', new.id::text,
                    'Aviso de pago a ' || (select nombre from satelites where id = new.satelite_id),
                    jsonb_build_object('telefono', (select whatsapp from satelites where id = new.satelite_id), 'plantilla', 'pago_satelite',
                                       'parametros', jsonb_build_array(new.consecutivo, to_char(new.valor, 'FM999G999G999'))));
  end if;
  return new;
end $$;
create trigger cuentas_satelite_alegra after update of estado on public.cuentas_pagar_satelite for each row execute function public.fn_cuenta_satelite_alegra();

-- 6. Remisión de salida → aviso al satélite
create or replace function public.fn_remision_whatsapp() returns trigger
language plpgsql security definer set search_path = public as $$
declare s satelites;
begin
  if new.tipo <> 'salida' then return new; end if;
  select * into s from satelites where id = new.satelite_id;
  if s.whatsapp is null then return new; end if;
  -- se encola un poco después para que ya estén las unidades de la remisión
  perform encolar('whatsapp', 'mensaje', 'wa:rem:' || new.id, 'remisiones', new.id::text, 'Aviso de remisión ' || new.consecutivo || ' a ' || s.nombre,
                  jsonb_build_object('telefono', s.whatsapp, 'plantilla', 'remision_enviada', 'remision_id', new.id), now() + interval '1 minute');
  return new;
end $$;
create trigger remisiones_whatsapp after insert on public.remisiones for each row execute function public.fn_remision_whatsapp();

-- 7. Alertas → WhatsApp a quienes estén suscritos a ese tipo
create table public.whatsapp_destinatarios (
  id       uuid primary key default gen_random_uuid(),
  nombre   text not null,
  telefono text not null check (telefono ~ '^\+?[0-9]{10,15}$'),
  tipos    text[] not null default '{}',     -- tipos de alerta que recibe
  activo   boolean not null default true
);
select public.aplicar_estandar_maestro('whatsapp_destinatarios');

create or replace function public.fn_alerta_whatsapp() returns trigger
language plpgsql security definer set search_path = public as $$
declare d whatsapp_destinatarios;
begin
  for d in select * from whatsapp_destinatarios where activo and new.tipo = any (tipos) loop
    perform encolar('whatsapp', 'mensaje', 'wa:al:' || new.id || ':' || d.id, 'alertas', new.id::text,
                    'Alerta para ' || d.nombre || ': ' || left(new.mensaje, 80),
                    jsonb_build_object('telefono', d.telefono, 'plantilla', 'alerta_produccion',
                                       'parametros', jsonb_build_array(left(new.mensaje, 900))));
  end loop;
  return new;
end $$;
create trigger alertas_whatsapp after insert on public.alertas for each row execute function public.fn_alerta_whatsapp();

-- ---------------------------------------------------------------------
-- Tareas periódicas (las llama la Edge Function en cada pasada; son idempotentes)
-- ---------------------------------------------------------------------
-- Consumo de materia prima de un día: un ajuste de salida por OP
create or replace function public.encolar_consumos(p_fecha date) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select mi.op_id, o.consecutivo from movimientos_inventario mi join ordenes_produccion o on o.id = mi.op_id
           where mi.afecta = 'fisico' and mi.tipo in ('salida_op','devolucion')
             and (mi.ocurrido_en at time zone 'America/Bogota')::date = p_fecha
           group by mi.op_id, o.consecutivo loop
    if encolar('alegra', 'ajuste_consumo', 'cons:' || r.op_id || ':' || p_fecha, 'ordenes_produccion', r.op_id::text,
               'Consumo de materia prima ' || r.consecutivo || ' del ' || to_char(p_fecha, 'DD/MM/YYYY'),
               jsonb_build_object('op_id', r.op_id, 'fecha', p_fecha)) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.encolar_consumos(date) from public, anon, authenticated;

create or replace function public.tareas_programadas() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoy date := hoy_bogota();
  v_cons int := 0;
  d date;
  v_alertas int := 0;
  r record;
begin
  -- consumos de los últimos 3 días ya cerrados
  for d in select generate_series(v_hoy - 3, v_hoy - 1, interval '1 day')::date loop
    v_cons := v_cons + encolar_consumos(d);
  end loop;
  -- OP atrasadas (una alerta por OP mientras siga abierta)
  for r in select o.id, o.consecutivo, coalesce(o.fecha_comprometida, o.fecha_entrega_plan) as entrega from ordenes_produccion o
           where o.estado in ('planeada','en_proceso') and coalesce(o.fecha_comprometida, o.fecha_entrega_plan) < v_hoy
             and not exists (select 1 from alertas a where a.tipo = 'op_atrasada' and a.entidad_id = o.id::text and a.estado = 'abierta') loop
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
    values ('op_atrasada', 'alta', 'ordenes_produccion', r.id::text, format('%s está atrasada: debía entregarse el %s', r.consecutivo, to_char(r.entrega, 'DD/MM/YYYY')));
    v_alertas := v_alertas + 1;
  end loop;
  -- stock por debajo del mínimo
  for r in select m.id, m.nombre, m.unidad, m.stock_minimo, coalesce(sum(s.disponible), 0) as disp from materiales m
           left join saldos_por_material s on s.material_id = m.id
           where m.activo and m.stock_minimo is not null group by m.id
           having coalesce(sum(s.disponible), 0) < m.stock_minimo
              and not exists (select 1 from alertas a where a.tipo = 'stock_bajo' and a.entidad_id = m.id::text and a.estado = 'abierta') loop
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
    values ('stock_bajo', 'media', 'materiales', r.id::text,
            format('Stock bajo de %s: quedan %s %s disponibles (mínimo %s)', r.nombre, round(r.disp, 2), r.unidad, r.stock_minimo));
    v_alertas := v_alertas + 1;
  end loop;
  -- paros largos (uno por paro)
  for r in select v.id, v.causa, v.minutos, c.codigo as celula, e.nombres from paros_vista v left join celulas c on c.id = v.celula_id
           left join empleados e on e.id = v.empleado_id
           where v.activo and v.minutos >= coalesce(ajuste_integracion('alerta_paro_largo_min')::numeric, 30)
             and not exists (select 1 from alertas a where a.tipo = 'paro_largo' and a.entidad_id = v.id::text) loop
    insert into alertas (tipo, severidad, entidad, entidad_id, mensaje)
    values ('paro_largo', 'alta', 'paros', r.id::text,
            format('Paro de %s min en %s (%s)%s', round(r.minutos), coalesce(r.celula, 'planta'), r.causa, coalesce(' · ' || r.nombres, '')));
    v_alertas := v_alertas + 1;
  end loop;
  -- remisiones vencidas: recordatorio al satélite (una vez)
  for r in select rm.id, rm.consecutivo, rm.fecha_compromiso, s.whatsapp, s.nombre from remisiones rm join satelites s on s.id = rm.satelite_id
           where rm.tipo = 'salida' and rm.estado in ('enviada','parcial') and rm.fecha_compromiso < v_hoy and s.whatsapp is not null loop
    perform encolar('whatsapp', 'mensaje', 'wa:venc:' || r.id, 'remisiones', r.id::text, 'Recordatorio de ' || r.consecutivo || ' a ' || r.nombre,
                    jsonb_build_object('telefono', r.whatsapp, 'plantilla', 'remision_vencida',
                                       'parametros', jsonb_build_array(r.consecutivo, to_char(r.fecha_compromiso, 'DD/MM/YYYY'))));
  end loop;
  return jsonb_build_object('consumos', v_cons, 'alertas', v_alertas);
end $$;
revoke all on function public.tareas_programadas() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Lo que usa la Edge Function (solo con la clave de servicio)
-- ---------------------------------------------------------------------
-- Toma trabajos listos para enviar (sin que dos procesos tomen el mismo)
create or replace function public.tomar_trabajos(p_limite int default 20, p_sistemas text[] default '{alegra,whatsapp}') returns setof public.integraciones_cola
language sql security definer set search_path = public as $$
  update integraciones_cola c set estado = 'enviando', actualizado_en = now()
  where c.id in (select id from integraciones_cola where estado = 'pendiente' and proximo_intento <= now() and sistema = any (p_sistemas)
                 order by creado_en limit p_limite for update skip locked)
  returning c.*
$$;
revoke all on function public.tomar_trabajos(int, text[]) from public, anon, authenticated;

-- Un trabajo que quedó "enviando" (la función se cayó a mitad) vuelve a la cola a los 15 minutos
create or replace function public.liberar_trabajos_colgados() returns int
language sql security definer set search_path = public as $$
  with x as (update integraciones_cola set estado = 'pendiente', actualizado_en = now()
             where estado = 'enviando' and actualizado_en < now() - interval '15 minutes' returning 1)
  select count(*)::int from x
$$;
revoke all on function public.liberar_trabajos_colgados() from public, anon, authenticated;

-- Arma el documento con los ids de Alegra. Si falta un enlace, lo dice (el trabajo queda bloqueado).
create or replace function public.datos_trabajo(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c integraciones_cola;
  r jsonb;
  v_falta text[] := '{}';
  x record;
begin
  select * into c from integraciones_cola where id = p_id;
  if c.id is null then raise exception 'Trabajo no encontrado'; end if;

  if c.tipo = 'crear_item' then
    r := c.datos || jsonb_build_object('impuesto', ajuste_integracion('alegra_impuesto_iva'), 'categoria', ajuste_integracion('alegra_categoria_item'),
                                       'bodega', ajuste_integracion('alegra_bodega_pt'));

  elsif c.tipo = 'ajuste_pt' then
    select s.alegra_id, s.codigo into x from skus s where s.id = (c.datos->>'sku_id')::uuid;
    if x.alegra_id is null then v_falta := v_falta || ('producto ' || x.codigo); end if;
    r := c.datos || jsonb_build_object('item', x.alegra_id,
           'bodega_alegra', ajuste_integracion(case c.datos->>'bodega' when 'segundas' then 'alegra_bodega_segundas' else 'alegra_bodega_pt' end),
           'costo', (select round(avg(f.valor), 0) from ficha_costo_estandar f join referencias rf on rf.version_vigente_id = f.ficha_id
                     join skus s on s.referencia_id = rf.id where s.id = (c.datos->>'sku_id')::uuid and f.concepto = 'total'),
           'fecha', hoy_bogota());

  elsif c.tipo in ('despacho','anular_despacho') then
    select d.*, cl.alegra_id as cliente_alegra, cl.alegra_bodega_id, cl.nombre as cliente from despachos d left join clientes cl on cl.id = d.cliente_id
     where d.id = (c.datos->>'despacho_id')::uuid into x;
    if x.cliente_alegra is null and x.alegra_bodega_id is null then v_falta := v_falta || ('cliente ' || coalesce(x.cliente, '(sin cliente)')); end if;
    r := c.datos || jsonb_build_object('fecha', x.fecha, 'observacion', coalesce(x.observacion, ''), 'cliente', x.cliente_alegra,
           'bodega_destino', x.alegra_bodega_id, 'bodega_origen', ajuste_integracion('alegra_bodega_pt'),
           'lista_precio', ajuste_integracion('alegra_lista_precio_remision'),
           'pedido', (select consecutivo from pedidos where id = x.pedido_id),
           'original', (select jsonb_build_object('externo_id', o.externo_id, 'respuesta', o.respuesta) from integraciones_cola o
                        where o.sistema = 'alegra' and o.clave = 'des:' || x.id and o.estado = 'enviado'),
           'lineas', (select coalesce(jsonb_agg(jsonb_build_object('item', s.alegra_id, 'codigo', s.codigo, 'cantidad', -m.cantidad,
                                                                   'precio', s.precio_venta)), '[]')
                      from movimientos_producto m join skus s on s.id = m.sku_id where m.despacho_id = x.id and m.tipo = 'despacho'));
    select array_agg('producto ' || s.codigo) into x from movimientos_producto m join skus s on s.id = m.sku_id
     where m.despacho_id = (c.datos->>'despacho_id')::uuid and m.tipo = 'despacho' and s.alegra_id is null;
    v_falta := v_falta || coalesce(x.array_agg, '{}');
    if c.tipo = 'anular_despacho' and r->'original' is null then
      r := r || jsonb_build_object('sin_original', true);   -- nunca llegó a Alegra: no hay nada que anular
    end if;

  elsif c.tipo = 'factura_proveedor' then
    select rc.*, p.alegra_id as proveedor_alegra, p.nombre as proveedor from recepciones rc left join proveedores p on p.id = rc.proveedor_id
     where rc.id = (c.datos->>'recepcion_id')::uuid into x;
    if x.proveedor_alegra is null then v_falta := v_falta || ('proveedor ' || coalesce(x.proveedor, '')); end if;
    r := c.datos || jsonb_build_object('proveedor', x.proveedor_alegra, 'factura', x.factura_proveedor, 'fecha', x.fecha,
           'observacion', 'Recepción ' || x.consecutivo,
           'lineas', (select coalesce(jsonb_agg(jsonb_build_object('item', m.alegra_id, 'material', m.nombre, 'cantidad', l.cantidad,
                                     'precio', l.costo_unitario,
                                     'bodega', ajuste_integracion(case m.tipo when 'tela' then 'alegra_bodega_mp' else 'alegra_bodega_insumos' end))
                                     order by l.orden), '[]')
                      from recepcion_lineas l join materiales m on m.id = l.material_id where l.recepcion_id = x.id));
    select array_agg(distinct 'material ' || m.nombre) into x from recepcion_lineas l join materiales m on m.id = l.material_id
     where l.recepcion_id = (c.datos->>'recepcion_id')::uuid and m.alegra_id is null;
    v_falta := v_falta || coalesce(x.array_agg, '{}');

  elsif c.tipo = 'ajuste_consumo' then
    r := c.datos || jsonb_build_object('observacion', 'Consumo ' || (select consecutivo from ordenes_produccion where id = (c.datos->>'op_id')::uuid),
           'lineas', (select coalesce(jsonb_agg(jsonb_build_object('item', y.alegra_id, 'material', y.nombre, 'cantidad', y.cant, 'costo', y.costo,
                                     'bodega', ajuste_integracion(case y.tipo when 'tela' then 'alegra_bodega_mp' else 'alegra_bodega_insumos' end))), '[]')
                      from (select m.alegra_id, m.nombre, m.tipo, -sum(mi.cantidad) as cant,
                                   round(sum(mi.cantidad * coalesce(mi.costo_unitario, m.costo_estandar, 0)) / nullif(sum(mi.cantidad), 0), 2) as costo
                            from movimientos_inventario mi join materiales m on m.id = mi.material_id
                            where mi.op_id = (c.datos->>'op_id')::uuid and mi.afecta = 'fisico' and mi.tipo in ('salida_op','devolucion')
                              and (mi.ocurrido_en at time zone 'America/Bogota')::date = (c.datos->>'fecha')::date
                            group by 1, 2, 3 having sum(mi.cantidad) <> 0) y));
    select array_agg(distinct 'material ' || m.nombre) into x from movimientos_inventario mi join materiales m on m.id = mi.material_id
     where mi.op_id = (c.datos->>'op_id')::uuid and mi.afecta = 'fisico' and mi.tipo in ('salida_op','devolucion')
       and (mi.ocurrido_en at time zone 'America/Bogota')::date = (c.datos->>'fecha')::date and m.alegra_id is null;
    v_falta := v_falta || coalesce(x.array_agg, '{}');

  elsif c.tipo = 'documento_soporte' then
    select cp.*, s.alegra_id as satelite_alegra, s.nombre as satelite, o.consecutivo as op, pr.nombre as proceso_nombre
      from cuentas_pagar_satelite cp join satelites s on s.id = cp.satelite_id left join ordenes_produccion o on o.id = cp.op_id
      left join procesos pr on pr.codigo = cp.proceso where cp.id = (c.datos->>'cuenta_id')::uuid into x;
    if x.satelite_alegra is null then v_falta := v_falta || ('satélite ' || x.satelite); end if;
    if ajuste_integracion('alegra_cuenta_satelites') is null then v_falta := v_falta || 'cuenta contable de satélites (Ajustes)'::text; end if;
    r := c.datos || jsonb_build_object('proveedor', x.satelite_alegra, 'fecha', hoy_bogota(), 'valor', x.valor, 'cantidad', x.cantidad,
           'descripcion', format('%s de %s prendas · %s · %s', x.proceso_nombre, x.cantidad, x.op, x.consecutivo),
           'cuenta', ajuste_integracion('alegra_cuenta_satelites'), 'numeracion', ajuste_integracion('alegra_numeracion_ds'));

  elsif c.tipo = 'concepto_nomina' then
    select e.alegra_id, e.documento, e.nombres || ' ' || e.apellidos as nombre into x from empleados e where e.id = (c.datos->>'empleado_id')::uuid;
    if x.alegra_id is null and x.documento is null then v_falta := v_falta || ('empleado ' || x.nombre); end if;
    if ajuste_integracion('alegra_concepto_incentivo') is null then v_falta := v_falta || 'concepto de incentivo (Ajustes)'::text; end if;
    r := c.datos || jsonb_build_object('empleado_alegra', x.alegra_id, 'documento', x.documento, 'concepto', ajuste_integracion('alegra_concepto_incentivo')::int);

  elsif c.tipo = 'mensaje' then
    r := c.datos || jsonb_build_object('idioma', ajuste_integracion('whatsapp_idioma'));
    if c.datos ? 'remision_id' then
      select rm.consecutivo, rm.fecha_compromiso, pr.nombre as proceso, (select sum(cantidad) from remision_unidades where remision_id = rm.id) as prendas
        into x from remisiones rm left join procesos pr on pr.codigo = rm.proceso where rm.id = (c.datos->>'remision_id')::uuid;
      r := r || jsonb_build_object('parametros', jsonb_build_array(x.consecutivo, coalesce(x.prendas, 0)::text, coalesce(x.proceso, ''),
                                                                    coalesce(to_char(x.fecha_compromiso, 'DD/MM/YYYY'), 'sin fecha')));
    end if;
  end if;

  return jsonb_build_object('id', c.id, 'tipo', c.tipo, 'sistema', c.sistema, 'clave', c.clave, 'faltan', to_jsonb(v_falta), 'datos', r);
end $$;
revoke all on function public.datos_trabajo(uuid) from public, anon, authenticated;

-- Resultado de un envío: enlaza lo creado, o programa el reintento
create or replace function public.terminar_trabajo(p_id uuid, p_ok boolean, p_externo text default null, p_respuesta jsonb default null,
                                                   p_error text default null, p_bloqueado boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare c integraciones_cola;
begin
  select * into c from integraciones_cola where id = p_id for update;
  if c.id is null then raise exception 'Trabajo no encontrado'; end if;
  insert into integraciones_intentos (cola_id, ok, detalle) values (p_id, p_ok, coalesce(p_error, p_externo));
  if p_ok then
    update integraciones_cola set estado = 'enviado', externo_id = p_externo, respuesta = p_respuesta, error = null, enviado_en = now(),
           intentos = intentos + 1, actualizado_en = now() where id = p_id;
    -- lo creado en Alegra queda enlazado
    if c.tipo = 'crear_item' and p_externo is not null then
      update skus set alegra_id = p_externo where id = (c.datos->>'sku_id')::uuid and alegra_id is null;
    end if;
  else
    update integraciones_cola set
      estado = case when p_bloqueado then 'bloqueado' when intentos + 1 >= 8 then 'error' else 'pendiente' end,
      error = p_error, respuesta = p_respuesta, intentos = intentos + 1, actualizado_en = now(),
      proximo_intento = now() + least(interval '1 minute' * power(2, intentos), interval '6 hours')
    where id = p_id;
  end if;
end $$;
revoke all on function public.terminar_trabajo(uuid, boolean, text, jsonb, text, boolean) from public, anon, authenticated;

-- Al enlazar algo que faltaba, los trabajos bloqueados vuelven a intentarse
create or replace function public.fn_desbloquear_integraciones() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.alegra_id is not null and old.alegra_id is distinct from new.alegra_id then
    update integraciones_cola set estado = 'pendiente', proximo_intento = now(), actualizado_en = now() where estado = 'bloqueado';
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['skus','materiales','proveedores','satelites','clientes','empleados'] loop
    execute format('create trigger %I after update of alegra_id on public.%I for each row execute function public.fn_desbloquear_integraciones()',
                   t || '_desbloquear', t);
  end loop;
end $$;

-- Desde la web: reintentar o descartar (Costos o Gerencia)
create or replace function public.gestionar_trabajo(p_id uuid, p_accion text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('integraciones', 'editar');
  if p_accion = 'reintentar' then
    update integraciones_cola set estado = 'pendiente', proximo_intento = now(), intentos = 0, actualizado_en = now()
     where id = p_id and estado in ('error','bloqueado','descartado');
  elsif p_accion = 'descartar' then
    update integraciones_cola set estado = 'descartado', actualizado_en = now() where id = p_id and estado in ('pendiente','error','bloqueado');
  else
    raise exception 'Acción inválida';
  end if;
  if not found then raise exception 'Ese envío no se puede %', p_accion; end if;
end $$;

-- Ajustes desde la web
create or replace function public.guardar_ajuste_integracion(p_clave text, p_valor jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('integraciones', 'editar');
  update integracion_ajustes set valor = p_valor where clave = p_clave;
  if not found then raise exception 'Ajuste desconocido: %', p_clave; end if;
end $$;

-- Enlaces desde la web (el id de Alegra de un producto, material, tercero o empleado)
create or replace function public.enlazar_alegra(p_tabla text, p_id uuid, p_alegra text, p_bodega text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform exigir_permiso('integraciones', 'editar');
  if p_tabla not in ('skus','materiales','proveedores','satelites','clientes','empleados') then raise exception 'Tabla inválida'; end if;
  execute format('update public.%I set alegra_id = $1 where id = $2', p_tabla) using nullif(trim(p_alegra), ''), p_id;
  if p_tabla = 'clientes' then update clientes set alegra_bodega_id = nullif(trim(p_bodega), '') where id = p_id; end if;
end $$;

-- ---------------------------------------------------------------------
-- Nómina real (Alegra Nómina → app) y valor real del minuto por quincena
-- ---------------------------------------------------------------------
create table public.costos_nomina (
  id            uuid primary key default gen_random_uuid(),
  empleado_id   uuid references public.empleados(id),
  identificacion text not null,
  nombre        text,
  desde         date not null,
  hasta         date not null,
  costo_total   numeric(14,2) not null,       -- salario + otros ingresos + aportes + prestaciones
  salario       numeric(14,2),
  importado_en  timestamptz not null default now(),
  unique (identificacion, desde, hasta)
);
alter table public.costos_nomina enable row level security;

create table public.valor_minuto_real (
  desde          date not null,
  hasta          date not null,
  costo_nomina   numeric(16,2) not null,      -- de los empleados de planta (con célula)
  minutos        numeric(14,1) not null,      -- minutos pagados de turno en la quincena
  valor_minuto   numeric(12,2) not null,
  empleados      int not null,
  calculado_en   timestamptz not null default now(),
  primary key (desde, hasta)
);
alter table public.valor_minuto_real enable row level security;

-- Minutos de turno pagados de un empleado entre dos fechas (días laborales de su célula, sin festivos)
create or replace function public.minutos_pagados(p_empleado uuid, p_desde date, p_hasta date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(minutos_turno(c.turno_id)), 0)
  from empleados e join celulas c on c.id = e.celula_id, generate_series(p_desde, p_hasta, interval '1 day') d
  where e.id = p_empleado
    and (c.dias_laborales is null or extract(isodow from d)::int = any (c.dias_laborales))
    and not exists (select 1 from festivos f where f.fecha = d::date)
$$;

create or replace function public.registrar_costos_nomina(p_desde date, p_hasta date, p_filas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x jsonb;
  n int := 0;
  sin int := 0;
  v_costo numeric;
  v_min numeric;
  v_emp int;
begin
  for x in select * from jsonb_array_elements(coalesce(p_filas, '[]')) loop
    insert into costos_nomina (empleado_id, identificacion, nombre, desde, hasta, costo_total, salario)
    values ((select id from empleados where documento = x->>'identificacion' or alegra_id = x->>'alegra_id' limit 1),
            x->>'identificacion', x->>'nombre', p_desde, p_hasta, (x->>'costo_total')::numeric, (x->>'salario')::numeric)
    on conflict (identificacion, desde, hasta) do update
      set costo_total = excluded.costo_total, salario = excluded.salario, nombre = excluded.nombre,
          empleado_id = coalesce(excluded.empleado_id, costos_nomina.empleado_id), importado_en = now();
    n := n + 1;
  end loop;
  select count(*) into sin from costos_nomina where desde = p_desde and hasta = p_hasta and empleado_id is null;
  -- valor real del minuto: costo de la nómina de planta (empleados con célula) / sus minutos pagados
  select coalesce(sum(cn.costo_total), 0), coalesce(sum(minutos_pagados(cn.empleado_id, p_desde, p_hasta)), 0), count(*)
    into v_costo, v_min, v_emp
  from costos_nomina cn join empleados e on e.id = cn.empleado_id
  where cn.desde = p_desde and cn.hasta = p_hasta and e.celula_id is not null;
  if v_min > 0 then
    insert into valor_minuto_real (desde, hasta, costo_nomina, minutos, valor_minuto, empleados)
    values (p_desde, p_hasta, v_costo, v_min, round(v_costo / v_min, 2), v_emp)
    on conflict (desde, hasta) do update set costo_nomina = excluded.costo_nomina, minutos = excluded.minutos,
      valor_minuto = excluded.valor_minuto, empleados = excluded.empleados, calculado_en = now();
  end if;
  return jsonb_build_object('filas', n, 'sin_enlazar', sin, 'valor_minuto', case when v_min > 0 then round(v_costo / v_min, 2) end,
                            'empleados_planta', v_emp);
end $$;
revoke all on function public.registrar_costos_nomina(date, date, jsonb) from public, anon, authenticated;

-- Valor del minuto de un día: el real de su quincena si ya se importó la nómina; si no, el configurado
create or replace function public.valor_minuto_dia(p_dia date, out valor_minuto numeric, out indirecto_minuto numeric, out es_real boolean)
language plpgsql stable security definer set search_path = public as $$
declare v record;
begin
  select * into v from valor_minuto_vigente(p_dia);
  indirecto_minuto := v.indirecto_minuto;
  select r.valor_minuto into valor_minuto from valor_minuto_real r where p_dia between r.desde and r.hasta;
  es_real := valor_minuto is not null;
  valor_minuto := coalesce(valor_minuto, v.valor_minuto);
end $$;

-- La mano de obra real del costo de la OP usa el valor real del minuto de cada día
create or replace function public.costo_op(p_op uuid)
returns table (concepto text, estandar numeric, valor_real numeric, desviacion_pct numeric, detalle jsonb)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  o ordenes_produccion;
  v_cant jsonb;
  v_prendas numeric;
  v_vm record;
  v_std_tela numeric; v_std_ins numeric; v_std_ext numeric; v_std_mo numeric; v_std_ind numeric;
  v_real_tela numeric; v_real_ins numeric; v_real_ext numeric; v_real_mo numeric; v_real_ind numeric;
  v_min_medidos numeric; v_min_estimados numeric; v_min_nomina numeric;
  v_det_tela jsonb; v_det_ext jsonb;
begin
  if not (public.puede('costos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  select * into o from ordenes_produccion where id = p_op;
  if o.id is null then raise exception 'OP no encontrada'; end if;
  v_cant := cantidades_cortadas_op(p_op);
  if v_cant = '{}'::jsonb then v_cant := cantidades_op(p_op); end if;
  select coalesce(sum((t.value #>> '{}')::numeric), 0) into v_prendas from jsonb_each(v_cant) c, jsonb_each(c.value) t;
  select * into v_vm from valor_minuto_vigente(hoy_bogota());

  select coalesce(sum(n.cantidad * coalesce(m.costo_estandar, 0)) filter (where m.tipo = 'tela'), 0),
         coalesce(sum(n.cantidad * coalesce(m.costo_estandar, 0)) filter (where m.tipo = 'insumo'), 0)
    into v_std_tela, v_std_ins
  from necesidades_ficha(o.ficha_version_id, v_cant) n join materiales m on m.id = n.material_id;
  select coalesce(sum(costo_externo_unidad), 0) * v_prendas into v_std_ext from ficha_ruta where ficha_id = o.ficha_version_id;
  v_std_mo := sam_total_ficha(o.ficha_version_id) * v_prendas * coalesce(v_vm.valor_minuto, 0);
  v_std_ind := sam_total_ficha(o.ficha_version_id) * v_prendas * coalesce(v_vm.indirecto_minuto, 0);

  select coalesce(-sum(mi.cantidad * coalesce(mi.costo_unitario, m.costo_estandar, 0)) filter (where m.tipo = 'tela'), 0),
         coalesce(-sum(mi.cantidad * coalesce(mi.costo_unitario, m.costo_estandar, 0)) filter (where m.tipo = 'insumo'), 0)
    into v_real_tela, v_real_ins
  from movimientos_inventario mi join materiales m on m.id = mi.material_id
  where mi.op_id = p_op and mi.afecta = 'fisico' and mi.tipo in ('salida_op','envio_satelite','devolucion','anulacion');
  select coalesce(jsonb_agg(jsonb_build_object('material', x.nombre, 'tipo', x.tipo, 'cantidad', round(x.q, 3), 'unidad', x.unidad, 'valor', round(x.v, 0))
                            order by x.tipo desc, x.v desc), '[]')
    into v_det_tela
  from (select m.nombre, m.tipo, m.unidad, -sum(mi.cantidad) as q, -sum(mi.cantidad * coalesce(mi.costo_unitario, m.costo_estandar, 0)) as v
        from movimientos_inventario mi join materiales m on m.id = mi.material_id
        where mi.op_id = p_op and mi.afecta = 'fisico' and mi.tipo in ('salida_op','envio_satelite','devolucion','anulacion')
        group by 1, 2, 3 having sum(mi.cantidad) <> 0) x;

  select coalesce(sum(valor), 0), coalesce(jsonb_agg(jsonb_build_object('cuenta', c.consecutivo, 'satelite', s.nombre, 'proceso', c.proceso,
                                                                          'prendas', c.cantidad, 'valor', c.valor, 'estado', c.estado)), '[]')
    into v_real_ext, v_det_ext
  from cuentas_pagar_satelite c join satelites s on s.id = c.satelite_id
  where c.op_id = p_op and c.estado <> 'anulada';

  with m as (
    select mm.ficha_operacion_id, coalesce(mm.minutos_reales, mm.minutos_esperados) as minutos,
           (mm.ocurrido_en_servidor at time zone 'America/Bogota')::date as dia
    from marcaciones mm where mm.op_id = p_op and mm.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = mm.id)
  ), sin as (
    select coalesce(sum(fo.sam * fo.repeticiones), 0) * v_prendas as minutos from ficha_operaciones fo
    where fo.ficha_id = o.ficha_version_id and not exists (select 1 from m where m.ficha_operacion_id = fo.id)
  )
  select coalesce(sum(m.minutos * v.valor_minuto), 0) + (select minutos from sin) * coalesce(v_vm.valor_minuto, 0),
         coalesce(sum(m.minutos * v.indirecto_minuto), 0) + (select minutos from sin) * coalesce(v_vm.indirecto_minuto, 0),
         coalesce(sum(m.minutos), 0), (select minutos from sin), coalesce(sum(m.minutos) filter (where v.es_real), 0)
    into v_real_mo, v_real_ind, v_min_medidos, v_min_estimados, v_min_nomina
  from m left join lateral valor_minuto_dia(m.dia) v on true;

  return query values
    ('tela', round(v_std_tela, 0), round(v_real_tela, 0), null::numeric, jsonb_build_object('materiales', v_det_tela)),
    ('insumos', round(v_std_ins, 0), round(v_real_ins, 0), null::numeric, null::jsonb),
    ('externos', round(v_std_ext, 0), round(v_real_ext, 0), null::numeric, jsonb_build_object('cuentas', v_det_ext)),
    ('mano_obra', round(v_std_mo, 0), round(v_real_mo, 0), null::numeric,
       jsonb_build_object('minutos_marcados', round(v_min_medidos, 1), 'minutos_sin_marcar_estandar', round(v_min_estimados, 1),
                          'minutos_con_nomina_real', round(v_min_nomina, 1), 'valor_minuto', v_vm.valor_minuto)),
    ('indirectos', round(v_std_ind, 0), round(v_real_ind, 0), null::numeric, jsonb_build_object('indirecto_minuto', v_vm.indirecto_minuto)),
    ('total', round(v_std_tela + v_std_ins + v_std_ext + v_std_mo + v_std_ind, 0),
              round(v_real_tela + v_real_ins + v_real_ext + v_real_mo + v_real_ind, 0), null::numeric,
       jsonb_build_object('prendas_base', v_prendas,
                          'prendas_buenas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_op'),
                          'segundas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_segunda')));
end $$;

-- Estado de pagos de documentos soporte (Alegra → app)
create or replace function public.marcar_cuenta_pagada_alegra(p_cuenta uuid, p_referencia text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.satelite_sistema', 'si', true);
  update cuentas_pagar_satelite set estado = 'pagada', pagada_en = now(), referencia_pago = coalesce(p_referencia, 'Alegra')
   where id = p_cuenta and estado = 'aprobada';
  return found;
end $$;
revoke all on function public.marcar_cuenta_pagada_alegra(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Incentivos aprobados → Alegra Nómina
-- ---------------------------------------------------------------------
create table public.liquidaciones_incentivo (
  id          uuid primary key default gen_random_uuid(),
  desde       date not null,
  hasta       date not null,
  total       numeric(14,2) not null,
  aprobada_por uuid default auth.uid(),
  aprobada_en timestamptz not null default now(),
  unique (desde, hasta)
);
create table public.liquidacion_incentivo_lineas (
  liquidacion_id uuid not null references public.liquidaciones_incentivo(id),
  empleado_id    uuid not null references public.empleados(id),
  periodo        text,
  eficiencia     numeric(8,1),
  valor          numeric(14,2) not null,
  primary key (liquidacion_id, empleado_id, periodo)
);
select public.aplicar_estandar_evento('liquidaciones_incentivo');
alter table public.liquidacion_incentivo_lineas enable row level security;

create or replace function public.aprobar_incentivos(p_desde date, p_hasta date) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v uuid;
  r record;
begin
  if not (public.puede('eficiencia', 'aprobar') or public.puede('costos', 'aprobar') or public.es_conexion_directa()) then
    raise exception 'Solo quien aprueba en Eficiencia o Costos aprueba incentivos' using errcode = '42501';
  end if;
  if exists (select 1 from liquidaciones_incentivo where desde = p_desde and hasta = p_hasta) then
    raise exception 'Los incentivos del % al % ya se aprobaron', to_char(p_desde, 'DD/MM/YYYY'), to_char(p_hasta, 'DD/MM/YYYY');
  end if;
  insert into liquidaciones_incentivo (desde, hasta, total)
  select p_desde, p_hasta, coalesce(sum(valor), 0) from liquidar_incentivos(p_desde, p_hasta) returning id into v;
  insert into liquidacion_incentivo_lineas (liquidacion_id, empleado_id, periodo, eficiencia, valor)
  select v, empleado_id, periodo, eficiencia, valor from liquidar_incentivos(p_desde, p_hasta) where valor > 0;
  for r in select l.empleado_id, sum(l.valor) as valor, e.nombres || ' ' || e.apellidos as nombre
           from liquidacion_incentivo_lineas l join empleados e on e.id = l.empleado_id where l.liquidacion_id = v group by 1, 3 loop
    perform encolar('alegra', 'concepto_nomina', 'inc:' || v || ':' || r.empleado_id, 'liquidaciones_incentivo', v::text,
                    'Incentivo de ' || r.nombre || ' (' || to_char(p_desde, 'DD/MM') || ' a ' || to_char(p_hasta, 'DD/MM/YYYY') || ')',
                    jsonb_build_object('empleado_id', r.empleado_id, 'valor', r.valor, 'desde', p_desde, 'hasta', p_hasta));
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Seguridad
-- ---------------------------------------------------------------------
insert into public.modulos (codigo, nombre, grupo, icono, ruta, fase, orden) values
  ('integraciones', 'Integraciones', 'Administración', 'sync', '/integraciones', 11, 55)
on conflict (codigo) do nothing;
insert into public.permisos_modulo (rol, modulo, puede_ver, puede_editar, puede_aprobar) values
  ('costos', 'integraciones', true, true, false)
on conflict (rol, modulo) do nothing;

create policy integracion_ajustes_leer on public.integracion_ajustes for select to authenticated using (public.puede('integraciones','ver'));
alter table public.integracion_ajustes enable row level security;
create policy integraciones_cola_leer on public.integraciones_cola for select to authenticated using (public.puede('integraciones','ver'));
create policy integraciones_intentos_leer on public.integraciones_intentos for select to authenticated using (public.puede('integraciones','ver'));
create policy whatsapp_dest_leer on public.whatsapp_destinatarios for select to authenticated using (public.puede('integraciones','ver'));
create policy whatsapp_dest_editar on public.whatsapp_destinatarios for all to authenticated
  using (public.puede('integraciones','editar')) with check (public.puede('integraciones','editar'));
create policy costos_nomina_leer on public.costos_nomina for select to authenticated using (public.puede('costos','ver'));
create policy valor_minuto_real_leer on public.valor_minuto_real for select to authenticated using (public.puede('costos','ver') or public.puede('integraciones','ver'));
create policy liquidaciones_leer on public.liquidaciones_incentivo for select to authenticated using (public.puede('eficiencia','ver') or public.puede('costos','ver'));
create policy liquidacion_lineas_leer on public.liquidacion_incentivo_lineas for select to authenticated using (public.puede('eficiencia','ver') or public.puede('costos','ver'));
