-- =====================================================================
-- Fase 10 · Migración 17: despacho de insumos a la OP, costo real vs
-- estándar por OP, trazabilidad inversa (desde un QR, un lote o un
-- reclamo), dashboard con Kanban por proceso e informes.
-- Regla 7: lo que mueve inventario es una sola función SQL.
-- =====================================================================

insert into public.consecutivos (tipo, prefijo) values ('SAL', 'SAL') on conflict do nothing;

-- ---------------------------------------------------------------------
-- Insumos a la OP: salida (descuenta físico y libera la reserva) y devolución
-- p_lineas = [{material_id, color_id?, bodega_id, cantidad}]
-- ---------------------------------------------------------------------
create or replace function public.despachar_insumos_op(p_op uuid, p_lineas jsonb, p_observacion text default null) returns text
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  x record;
  s record;
  v_doc text;
  v_res numeric;
begin
  perform exigir_permiso('inventario', 'editar');
  select * into o from ordenes_produccion where id = p_op for update;
  if o.id is null then raise exception 'OP no encontrada'; end if;
  if o.estado in ('anulada','cerrada') then raise exception 'La % está %', o.consecutivo, o.estado; end if;
  if jsonb_array_length(coalesce(p_lineas, '[]')) = 0 then raise exception 'No hay insumos para despachar'; end if;
  v_doc := siguiente_consecutivo('SAL');
  for x in select (e->>'material_id')::uuid as material_id, nullif(e->>'color_id', '')::uuid as color_id,
                  (e->>'bodega_id')::uuid as bodega_id, (e->>'cantidad')::numeric as cantidad
           from jsonb_array_elements(p_lineas) e loop
    if x.cantidad is null or x.cantidad <= 0 then raise exception 'Cantidad inválida'; end if;
    if (select tipo from materiales where id = x.material_id) is distinct from 'insumo' then
      raise exception 'Las telas salen con el corte, no por despacho de insumos';
    end if;
    select * into s from saldos_por_material
     where material_id = x.material_id and color_id is not distinct from x.color_id and bodega_id = x.bodega_id;
    if coalesce(s.fisico, 0) < x.cantidad then
      raise exception '%: en bodega hay %', (select nombre from materiales where id = x.material_id), coalesce(s.fisico, 0);
    end if;
    insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, cantidad, costo_unitario, op_id, documento_tipo, documento_id, motivo)
    values ('salida_op', x.material_id, x.color_id, x.bodega_id, -x.cantidad, s.costo_promedio, o.id, 'salida_op', v_doc,
            coalesce(nullif(trim(p_observacion), ''), 'Despacho a ' || o.consecutivo));
    -- lo que estaba reservado para la OP deja de estarlo
    select coalesce(sum(cantidad), 0) into v_res from movimientos_inventario
     where op_id = o.id and afecta = 'reservado' and material_id = x.material_id and color_id is not distinct from x.color_id and bodega_id = x.bodega_id;
    if v_res > 0 then
      insert into movimientos_inventario (tipo, afecta, material_id, color_id, bodega_id, cantidad, op_id, documento_tipo, documento_id)
      values ('liberacion', 'reservado', x.material_id, x.color_id, x.bodega_id, -least(v_res, x.cantidad), o.id, 'salida_op', v_doc);
    end if;
  end loop;
  return v_doc;
end $$;

create or replace function public.devolver_insumos_op(p_op uuid, p_lineas jsonb, p_motivo text) returns text
language plpgsql security definer set search_path = public as $$
declare
  o ordenes_produccion;
  x record;
  v_doc text;
  v_salio numeric;
  v_costo numeric;
begin
  perform exigir_permiso('inventario', 'editar');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Escriba el motivo de la devolución'; end if;
  select * into o from ordenes_produccion where id = p_op for update;
  if o.id is null then raise exception 'OP no encontrada'; end if;
  v_doc := siguiente_consecutivo('SAL');
  for x in select (e->>'material_id')::uuid as material_id, nullif(e->>'color_id', '')::uuid as color_id,
                  (e->>'bodega_id')::uuid as bodega_id, (e->>'cantidad')::numeric as cantidad
           from jsonb_array_elements(coalesce(p_lineas, '[]')) e loop
    if x.cantidad is null or x.cantidad <= 0 then raise exception 'Cantidad inválida'; end if;
    select -coalesce(sum(cantidad), 0), max(costo_unitario) into v_salio, v_costo from movimientos_inventario
     where op_id = o.id and afecta = 'fisico' and material_id = x.material_id and color_id is not distinct from x.color_id
       and tipo in ('salida_op','devolucion') and rollo_id is null;
    if x.cantidad > v_salio then
      raise exception 'A la % solo salieron % de %', o.consecutivo, v_salio, (select nombre from materiales where id = x.material_id);
    end if;
    insert into movimientos_inventario (tipo, material_id, color_id, bodega_id, cantidad, costo_unitario, op_id, documento_tipo, documento_id, motivo)
    values ('devolucion', x.material_id, x.color_id, x.bodega_id, x.cantidad, v_costo, o.id, 'salida_op', v_doc, trim(p_motivo));
  end loop;
  return v_doc;
end $$;

-- ---------------------------------------------------------------------
-- Costo real vs estándar por OP
-- ---------------------------------------------------------------------
-- Prendas cortadas por combinación y talla (formato de necesidades_ficha)
create or replace function public.cantidades_cortadas_op(p_op uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with u as (
    select j.combinacion_id as c, j.talla_id as t, j.cantidad as n from juegos j where j.op_id = p_op and j.estado <> 'anulado'
    union all
    select (select c.id from ficha_combinaciones c join ordenes_produccion o on o.ficha_version_id = c.ficha_id
             where o.id = p.op_id and (select cp.color_id from ficha_combinacion_partes cp join ficha_partes fp on fp.id = cp.parte_id
                                       where cp.combinacion_id = c.id order by fp.orden limit 1) = p.color_id order by c.codigo limit 1),
           p.talla_id, p.cantidad
    from paquetes p where p.op_id = p_op and p.completo and p.estado <> 'anulado'
  )
  select coalesce(jsonb_object_agg(c, tallas), '{}') from (
    select c, jsonb_object_agg(t, n) as tallas from (select c, t, sum(n) as n from u where c is not null group by 1, 2) x group by c) y
$$;

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
  v_min_medidos numeric; v_min_estimados numeric;
  v_det_tela jsonb; v_det_ins jsonb; v_det_ext jsonb;
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

  -- Estándar de materiales para las prendas cortadas (o las de la OP si aún no se corta)
  select coalesce(sum(n.cantidad * coalesce(m.costo_estandar, 0)) filter (where m.tipo = 'tela'), 0),
         coalesce(sum(n.cantidad * coalesce(m.costo_estandar, 0)) filter (where m.tipo = 'insumo'), 0)
    into v_std_tela, v_std_ins
  from necesidades_ficha(o.ficha_version_id, v_cant) n join materiales m on m.id = n.material_id;
  select coalesce(sum(costo_externo_unidad), 0) * v_prendas into v_std_ext from ficha_ruta where ficha_id = o.ficha_version_id;
  v_std_mo := sam_total_ficha(o.ficha_version_id) * v_prendas * coalesce(v_vm.valor_minuto, 0);
  v_std_ind := sam_total_ficha(o.ficha_version_id) * v_prendas * coalesce(v_vm.indirecto_minuto, 0);

  -- Real: lo que salió del inventario para la OP, valorizado al costo de cada movimiento
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

  -- Satélites: cuentas por pagar de la OP (las anuladas no cuentan)
  select coalesce(sum(valor), 0), coalesce(jsonb_agg(jsonb_build_object('cuenta', c.consecutivo, 'satelite', s.nombre, 'proceso', c.proceso,
                                                                          'prendas', c.cantidad, 'valor', c.valor, 'estado', c.estado)), '[]')
    into v_real_ext, v_det_ext
  from cuentas_pagar_satelite c join satelites s on s.id = c.satelite_id
  where c.op_id = p_op and c.estado <> 'anulada';

  -- Mano de obra: minutos reales de las marcaciones (si la marcación no se midió, sus minutos estándar);
  -- las operaciones que nadie marca (p. ej. corte) van al estándar
  with m as (
    select mm.ficha_operacion_id, coalesce(mm.minutos_reales, mm.minutos_esperados) as minutos, mm.minutos_reales is not null as medido,
           (mm.ocurrido_en_servidor at time zone 'America/Bogota')::date as dia
    from marcaciones mm where mm.op_id = p_op and mm.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = mm.id)
  ), sin as (
    select coalesce(sum(fo.sam * fo.repeticiones), 0) * v_prendas as minutos from ficha_operaciones fo
    where fo.ficha_id = o.ficha_version_id and not exists (select 1 from m where m.ficha_operacion_id = fo.id)
  )
  select coalesce(sum(m.minutos * v.valor_minuto), 0) + (select minutos from sin) * coalesce(v_vm.valor_minuto, 0),
         coalesce(sum(m.minutos * v.indirecto_minuto), 0) + (select minutos from sin) * coalesce(v_vm.indirecto_minuto, 0),
         coalesce(sum(m.minutos), 0), (select minutos from sin)
    into v_real_mo, v_real_ind, v_min_medidos, v_min_estimados
  from m left join lateral valor_minuto_vigente(m.dia) v on true;

  return query values
    ('tela', round(v_std_tela, 0), round(v_real_tela, 0), null::numeric, jsonb_build_object('materiales', v_det_tela)),
    ('insumos', round(v_std_ins, 0), round(v_real_ins, 0), null::numeric, null::jsonb),
    ('externos', round(v_std_ext, 0), round(v_real_ext, 0), null::numeric, jsonb_build_object('cuentas', v_det_ext)),
    ('mano_obra', round(v_std_mo, 0), round(v_real_mo, 0), null::numeric,
       jsonb_build_object('minutos_marcados', round(v_min_medidos, 1), 'minutos_sin_marcar_estandar', round(v_min_estimados, 1),
                          'valor_minuto', v_vm.valor_minuto)),
    ('indirectos', round(v_std_ind, 0), round(v_real_ind, 0), null::numeric, jsonb_build_object('indirecto_minuto', v_vm.indirecto_minuto)),
    ('total', round(v_std_tela + v_std_ins + v_std_ext + v_std_mo + v_std_ind, 0),
              round(v_real_tela + v_real_ins + v_real_ext + v_real_mo + v_real_ind, 0), null::numeric,
       jsonb_build_object('prendas_base', v_prendas,
                          'prendas_buenas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_op'),
                          'segundas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = p_op and tipo = 'ingreso_segunda')));
end $$;

-- Con la desviación calculada (separada para que la lean igual la web y los informes)
create or replace function public.costo_op_detalle(p_op uuid)
returns table (concepto text, estandar numeric, valor_real numeric, desviacion_pct numeric, detalle jsonb)
language sql stable security definer set search_path = public as $$
  select c.concepto, c.estandar, c.valor_real,
         case when c.estandar > 0 then round((c.valor_real - c.estandar) / c.estandar * 100, 1) end, c.detalle
  from costo_op(p_op) c
$$;

-- Costos de varias OP (activas o con trabajo en el rango)
create or replace function public.informe_costos(p_desde date, p_hasta date)
returns table (op_id uuid, op text, referencia text, estado text, prendas numeric, buenas numeric, estandar numeric, valor_real numeric,
               desviacion_pct numeric, unitario_estandar numeric, unitario_real numeric, tela_desv numeric, mano_obra_desv numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('costos', 'ver') or public.es_conexion_directa()) then raise exception 'Sin permiso' using errcode = '42501'; end if;
  return query
  select o.id, o.consecutivo, r.codigo || ' ' || r.nombre, o.estado,
         (t.detalle->>'prendas_base')::numeric, (t.detalle->>'prendas_buenas')::numeric, t.estandar, t.valor_real,
         case when t.estandar > 0 then round((t.valor_real - t.estandar) / t.estandar * 100, 1) end,
         case when (t.detalle->>'prendas_base')::numeric > 0 then round(t.estandar / (t.detalle->>'prendas_base')::numeric, 0) end,
         case when coalesce((t.detalle->>'prendas_buenas')::numeric, 0) > 0 then round(t.valor_real / (t.detalle->>'prendas_buenas')::numeric, 0)
              when (t.detalle->>'prendas_base')::numeric > 0 then round(t.valor_real / (t.detalle->>'prendas_base')::numeric, 0) end,
         (select desviacion_pct from costo_op_detalle(o.id) d where d.concepto = 'tela'),
         (select desviacion_pct from costo_op_detalle(o.id) d where d.concepto = 'mano_obra')
  from ordenes_produccion o
  join referencias r on r.id = o.referencia_id
  cross join lateral (select * from costo_op(o.id) c where c.concepto = 'total') t
  where o.estado <> 'anulada'
    and (o.creado_en at time zone 'America/Bogota')::date <= p_hasta
    and (o.estado in ('planeada','en_proceso') or (coalesce(o.ultima_marcacion, o.creado_en) at time zone 'America/Bogota')::date >= p_desde)
  order by o.consecutivo desc;
end $$;

-- ---------------------------------------------------------------------
-- Trazabilidad inversa
-- Acepta: paquete (PQ-), juego (JG-), rollo (TL-), OP, despacho (DES-), producto (PT-…)
-- o un lote de tintura. Devuelve {tipo, codigo, titulo, unidades: [...], rollos: [...], ...}
-- ---------------------------------------------------------------------
create or replace function public.traza_unidad(p_unidad uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with u as (select * from unidades_trabajo where id = p_unidad),
  paq as (  -- paquetes de corte que forman la unidad (ella misma o los componentes del juego)
    select p.* from paquetes p, u where p.id = u.id
    union
    select p.* from juego_componentes jc join paquetes p on p.id = jc.paquete_id, u where jc.juego_id = u.id
  )
  select jsonb_build_object(
    'id', u.id, 'tipo', u.tipo, 'codigo', u.codigo, 'cantidad', u.cantidad, 'cantidad_actual', u.cantidad_actual, 'estado', u.estado,
    'proceso_actual', u.proceso_actual,
    'talla', (select codigo from tallas where id = u.talla_id),
    'op', (select jsonb_build_object('id', o.id, 'consecutivo', o.consecutivo, 'referencia', r.codigo || ' ' || r.nombre)
           from ordenes_produccion o join referencias r on r.id = o.referencia_id where o.id = u.op_id),
    'corte', (select coalesce(jsonb_agg(distinct jsonb_build_object('consecutivo', c.consecutivo, 'fecha', c.confirmado_en,
                       'cortador', (select e.nombres || ' ' || e.apellidos from empleados e where e.id = c.cortador_id),
                       'paquete', p.codigo, 'lote_tintura', p.lote_tintura, 'color', co.nombre)), '[]')
              from paq p join cortes c on c.id = p.corte_id left join colores co on co.id = p.color_id),
    'rollos', (select coalesce(jsonb_agg(distinct jsonb_build_object('codigo', ro.codigo, 'material', m.nombre, 'lote_tintura', ro.lote_tintura,
                        'tono', ro.tono, 'proveedor', pv.nombre, 'ingreso', ro.fecha_ingreso)), '[]')
               from paq p join corte_rollos cr on cr.corte_id = p.corte_id and cr.color_id = p.color_id
                 and cr.lote_tintura is not distinct from p.lote_tintura and cr.material_id = p.material_id and cr.vigente
               join rollos ro on ro.id = cr.rollo_id join materiales m on m.id = ro.material_id left join proveedores pv on pv.id = ro.proveedor_id),
    'procesos', (select coalesce(jsonb_agg(jsonb_build_object('proceso', pr.nombre, 'tipo', e.tipo, 'fecha', coalesce(e.ocurrido_en_servidor, e.ocurrido_en),
                        'entra', e.entra, 'buenas', e.buenas, 'segundas', e.segundas, 'faltantes', e.faltantes,
                        'celula', ce.codigo, 'satelite', sa.nombre,
                        'empleado', (select em.nombres || ' ' || em.apellidos from empleados em where em.id = e.empleado_id))
                        order by coalesce(e.ocurrido_en_servidor, e.ocurrido_en)), '[]')
                 from eventos_proceso e join procesos pr on pr.codigo = e.proceso left join celulas ce on ce.id = e.celula_id
                 left join satelites sa on sa.id = e.satelite_id
                 where (e.paquete_id = u.id or e.juego_id = u.id) and e.tipo <> 'anulacion'
                   and not exists (select 1 from eventos_proceso a where a.anula_id = e.id)),
    'remisiones', (select coalesce(jsonb_agg(jsonb_build_object('consecutivo', r.consecutivo, 'tipo', r.tipo, 'satelite', s.nombre,
                          'proceso', r.proceso, 'fecha', r.fecha, 'cantidad', ru.cantidad) order by r.fecha, r.consecutivo), '[]')
                   from remision_unidades ru join remisiones r on r.id = ru.remision_id join satelites s on s.id = r.satelite_id
                   where (ru.paquete_id = u.id or ru.juego_id = u.id) and r.estado <> 'anulada'),
    'operarios', (select coalesce(jsonb_agg(jsonb_build_object('operacion', x.operacion, 'proceso', x.proceso, 'empleado', x.empleado,
                         'codigo', x.codigo, 'unidades', x.u, 'reprocesos', x.r, 'desde', x.desde, 'hasta', x.hasta) order by x.sec, x.empleado), '[]')
                  from (select op.nombre as operacion, fo.proceso, fo.secuencia as sec, em.nombres || ' ' || em.apellidos as empleado, em.codigo,
                               sum(m.unidades) filter (where m.tipo = 'normal') as u, sum(m.unidades) filter (where m.tipo = 'reproceso') as r,
                               min(m.ocurrido_en_servidor) as desde, max(m.ocurrido_en_servidor) as hasta
                        from marcaciones m join ficha_operaciones fo on fo.id = m.ficha_operacion_id
                        join operaciones op on op.id = fo.operacion_id join empleados em on em.id = m.empleado_id
                        where (m.paquete_id = u.id or m.juego_id = u.id) and m.tipo <> 'anulacion'
                          and not exists (select 1 from marcaciones a where a.anula_id = m.id)
                        group by 1, 2, 3, 4, 5) x),
    'calidad', (select coalesce(jsonb_agg(jsonb_build_object('consecutivo', i.consecutivo, 'tipo', i.tipo, 'resultado', i.resultado,
                       'fecha', i.ocurrido_en_servidor, 'defectuosas', i.defectuosas, 'muestra', i.tamano_muestra,
                       'inspector', (select em.nombres || ' ' || em.apellidos from empleados em where em.id = i.inspector_id),
                       'defectos', (select coalesce(jsonb_agg(df.nombre || ' (' || d.cantidad || ')'), '[]') from inspeccion_defectos d
                                    join defectos df on df.id = d.defecto_id where d.inspeccion_id = i.id))
                       order by i.ocurrido_en_servidor), '[]')
                from inspecciones i where (i.paquete_id = u.id or i.juego_id = u.id) and i.tipo <> 'anulacion'
                  and not exists (select 1 from inspecciones a where a.anula_id = i.id)),
    'destino', (select coalesce(jsonb_agg(jsonb_build_object('tipo', m.tipo, 'producto', s.codigo, 'cantidad', m.cantidad, 'fecha', m.creado_en)), '[]')
                from movimientos_producto m join skus s on s.id = m.sku_id where (m.paquete_id = u.id or m.juego_id = u.id)))
  from u
$$;

create or replace function public.trazabilidad(p_codigo text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c text := upper(trim(coalesce(p_codigo, '')));
  v_id uuid;
  r jsonb;
begin
  if not (public.puede('trazabilidad', 'ver') or public.puede('calidad', 'ver') or public.puede('op', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  if c = '' then raise exception 'Escriba o escanee un código'; end if;

  -- paquete o juego
  select id into v_id from unidades_trabajo where codigo = c;
  if v_id is null then select id into v_id from paquetes where codigo = c; end if;
  if v_id is not null then
    return jsonb_build_object('tipo', 'unidad', 'codigo', c, 'unidades', jsonb_build_array(traza_unidad(v_id)));
  end if;

  -- rollo: hacia adelante (qué se cortó con él y a dónde fue)
  select id into v_id from rollos where codigo = c;
  if v_id is not null then
    return jsonb_build_object('tipo', 'rollo', 'codigo', c,
      'rollo', (select jsonb_build_object('codigo', ro.codigo, 'material', m.nombre, 'color', co.nombre, 'lote_tintura', ro.lote_tintura, 'tono', ro.tono,
                  'proveedor', pv.nombre, 'ingreso', ro.fecha_ingreso, 'metros_iniciales', ro.metros_iniciales, 'metros_saldo', ro.metros_saldo,
                  'estado', ro.estado, 'origen', (select codigo from rollos where id = ro.rollo_origen_id),
                  'recepcion', (select rc.consecutivo from recepcion_lineas rl join recepciones rc on rc.id = rl.recepcion_id where rl.id = ro.recepcion_linea_id))
                from rollos ro join materiales m on m.id = ro.material_id left join colores co on co.id = ro.color_id
                left join proveedores pv on pv.id = ro.proveedor_id where ro.id = v_id),
      'cortes', (select coalesce(jsonb_agg(jsonb_build_object('corte', ct.consecutivo, 'op', o.consecutivo, 'metros', cr.metros_consumo, 'fecha', ct.confirmado_en)), '[]')
                 from corte_rollos cr join cortes ct on ct.id = cr.corte_id join ordenes_produccion o on o.id = ct.op_id
                 where cr.rollo_id = v_id and cr.vigente and ct.estado <> 'anulado'),
      'unidades', (select coalesce(jsonb_agg(traza_unidad(x.id) order by x.codigo), '[]') from (
                     select distinct u.id, u.codigo from corte_rollos cr
                     join paquetes p on p.corte_id = cr.corte_id and p.color_id = cr.color_id and p.material_id = cr.material_id
                       and p.lote_tintura is not distinct from cr.lote_tintura
                     join unidades_trabajo u on u.id = p.id or u.id in (select juego_id from juego_componentes where paquete_id = p.id)
                     where cr.rollo_id = v_id and cr.vigente) x));
  end if;

  -- OP
  select id into v_id from ordenes_produccion where consecutivo = c;
  if v_id is not null then
    return jsonb_build_object('tipo', 'op', 'codigo', c,
      'unidades', (select coalesce(jsonb_agg(traza_unidad(u.id) order by u.codigo), '[]') from unidades_trabajo u where u.op_id = v_id));
  end if;

  -- despacho: a quién se le mandó y de qué OP salieron esas prendas
  select id into v_id from despachos where consecutivo = c;
  if v_id is not null then
    return jsonb_build_object('tipo', 'despacho', 'codigo', c,
      'despacho', (select jsonb_build_object('consecutivo', d.consecutivo, 'fecha', d.fecha, 'cliente', cl.nombre, 'pedido', p.consecutivo, 'estado', d.estado)
                   from despachos d left join clientes cl on cl.id = d.cliente_id left join pedidos p on p.id = d.pedido_id where d.id = v_id),
      'productos', (select coalesce(jsonb_agg(jsonb_build_object('producto', s.codigo, 'cantidad', -m.cantidad)), '[]')
                    from movimientos_producto m join skus s on s.id = m.sku_id where m.despacho_id = v_id and m.tipo = 'despacho'),
      'unidades', (select coalesce(jsonb_agg(traza_unidad(x.u) order by x.c), '[]') from (
                     select distinct coalesce(i.paquete_id, i.juego_id) as u, coalesce(pq.codigo, jg.codigo) as c
                     from movimientos_producto m join movimientos_producto i on i.sku_id = m.sku_id and i.tipo = 'ingreso_op'
                       and i.creado_en <= m.creado_en
                     left join paquetes pq on pq.id = i.paquete_id left join juegos jg on jg.id = i.juego_id
                     where m.despacho_id = v_id and m.tipo = 'despacho') x));
  end if;

  -- producto terminado (reclamo de un cliente con la etiqueta de la prenda)
  select id into v_id from skus where codigo = c or codigo_barras = c;
  if v_id is not null then
    return jsonb_build_object('tipo', 'producto', 'codigo', c,
      'despachos', (select coalesce(jsonb_agg(jsonb_build_object('despacho', d.consecutivo, 'fecha', d.fecha, 'cliente', cl.nombre, 'cantidad', -m.cantidad)
                                               order by d.fecha desc), '[]')
                    from movimientos_producto m join despachos d on d.id = m.despacho_id left join clientes cl on cl.id = d.cliente_id
                    where m.sku_id = v_id and m.tipo = 'despacho' and d.estado <> 'anulado'),
      'unidades', (select coalesce(jsonb_agg(traza_unidad(x.u) order by x.f desc), '[]') from (
                     select coalesce(paquete_id, juego_id) as u, max(creado_en) as f from movimientos_producto
                     where sku_id = v_id and tipo = 'ingreso_op' group by 1 limit 30) x));
  end if;

  -- lote de tintura
  if exists (select 1 from rollos where upper(lote_tintura) = c) then
    return jsonb_build_object('tipo', 'lote', 'codigo', c,
      'rollos', (select coalesce(jsonb_agg(jsonb_build_object('codigo', ro.codigo, 'material', m.nombre, 'estado', ro.estado,
                        'proveedor', pv.nombre, 'metros_saldo', ro.metros_saldo) order by ro.codigo), '[]')
                 from rollos ro join materiales m on m.id = ro.material_id left join proveedores pv on pv.id = ro.proveedor_id
                 where upper(ro.lote_tintura) = c),
      'unidades', (select coalesce(jsonb_agg(traza_unidad(x.id) order by x.codigo), '[]') from (
                     select distinct u.id, u.codigo from paquetes p
                     join unidades_trabajo u on u.id = p.id or u.id in (select juego_id from juego_componentes where paquete_id = p.id)
                     where upper(p.lote_tintura) = c) x));
  end if;
  raise exception 'No se encontró "%": escanee un paquete, juego, rollo, OP, despacho o producto, o escriba un lote de tintura', p_codigo;
end $$;

-- ---------------------------------------------------------------------
-- Dashboard: indicadores y Kanban de OP por proceso
-- ---------------------------------------------------------------------
create or replace function public.dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_hoy date := hoy_bogota();
begin
  if not (public.puede('dashboard', 'ver') or public.puede('op', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'hoy', v_hoy,
    'procesos', (select coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'nombre', nombre, 'color', color_hex) order by orden), '[]')
                 from procesos where codigo <> 'diseno'),
    'ops', (select coalesce(jsonb_agg(jsonb_build_object(
              'id', o.id, 'consecutivo', o.consecutivo, 'referencia', r.codigo, 'nombre', r.nombre, 'estado', o.estado,
              'proceso', o.proceso_actual, 'cantidad', o.cantidad_total, 'prioridad', o.prioridad,
              'entrega', coalesce(o.fecha_comprometida, o.fecha_entrega_plan), 'alerta_material', o.alerta_material,
              'atrasada', coalesce(o.fecha_comprometida, o.fecha_entrega_plan) < v_hoy,
              'en_riesgo', (select max(p.fin_plan) from programacion p where p.op_id = o.id) > coalesce(o.fecha_comprometida, o.fecha_entrega_plan),
              'avance', (select jsonb_object_agg(op.proceso, jsonb_build_object('buenas', op.buenas, 'estado', op.estado)) from op_procesos op where op.op_id = o.id),
              'terminadas', (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = o.id and tipo = 'ingreso_op'),
              'devoluciones', (select count(*) from devoluciones_calidad where op_id = o.id and estado = 'abierta'))
              order by o.prioridad nulls last, coalesce(o.fecha_comprometida, o.fecha_entrega_plan) nulls last, o.consecutivo), '[]')
            from ordenes_produccion o join referencias r on r.id = o.referencia_id where o.estado in ('planeada','en_proceso')),
    'indicadores', jsonb_build_object(
      'ops_activas', (select count(*) from ordenes_produccion where estado in ('planeada','en_proceso')),
      'ops_atrasadas', (select count(*) from ordenes_produccion where estado in ('planeada','en_proceso')
                          and coalesce(fecha_comprometida, fecha_entrega_plan) < v_hoy),
      'prendas_en_proceso', (select coalesce(sum(cantidad_actual), 0) from unidades_trabajo where estado in ('en_proceso','en_espera','armado','cortado')),
      'eficiencia_hoy', (select round(sum(minutos_esperados) filter (where minutos_reales is not null) / nullif(sum(minutos_reales), 0) * 100, 1)
                         from marcaciones m where m.tipo <> 'anulacion' and not exists (select 1 from marcaciones a where a.anula_id = m.id)
                           and (m.ocurrido_en_servidor at time zone 'America/Bogota')::date = v_hoy),
      'terminadas_semana', (select coalesce(sum(cantidad), 0) from movimientos_producto
                            where tipo = 'ingreso_op' and (creado_en at time zone 'America/Bogota')::date > v_hoy - 7),
      'aceptacion_calidad', (select round(count(*) filter (where resultado = 'aprobado') * 100.0 / nullif(count(*), 0), 1) from inspecciones i
                             where i.tipo = 'auditoria_final' and not exists (select 1 from inspecciones a where a.anula_id = i.id)
                               and (i.ocurrido_en_servidor at time zone 'America/Bogota')::date > v_hoy - 7),
      'por_despachar', (select coalesce(sum(pd.por_despachar), 0) from pedido_despachos pd join pedidos p on p.id = pd.pedido_id where p.estado = 'abierto'),
      'producto_terminado', (select coalesce(sum(cantidad), 0) from existencias_producto where bodega_tipo = 'producto_terminado'),
      'alertas', (select count(*) from alertas where estado = 'abierta'),
      'paros_activos', (select count(*) from paros_vista where activo)),
    'alertas', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'tipo', a.tipo, 'severidad', a.severidad, 'mensaje', a.mensaje,
                                                             'creada', a.creada_en) order by (a.severidad = 'alta') desc, a.creado_en desc), '[]')
                from (select * from alertas where estado = 'abierta' order by creada_en desc limit 12) a));
end $$;

-- ---------------------------------------------------------------------
-- Informes (todos con rango de fechas de Bogotá; la web los exporta a Excel y PDF)
-- ---------------------------------------------------------------------
-- Producción por OP y proceso: entra, buenas, segundas, faltantes
create or replace function public.informe_produccion(p_desde date, p_hasta date)
returns table (op text, referencia text, proceso text, entra int, buenas int, segundas int, faltantes int, segundas_pct numeric, unidades int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('op', 'ver') or public.es_conexion_directa()) then raise exception 'Sin permiso' using errcode = '42501'; end if;
  return query
  select o.consecutivo, r.codigo, pr.nombre, sum(e.entra)::int, sum(e.buenas)::int, sum(e.segundas)::int, sum(e.faltantes)::int,
         round(sum(e.segundas) * 100.0 / nullif(sum(e.entra), 0), 1), count(*)::int
  from eventos_proceso e join ordenes_produccion o on o.id = e.op_id join referencias r on r.id = o.referencia_id join procesos pr on pr.codigo = e.proceso
  where e.tipo = 'avance' and not exists (select 1 from eventos_proceso a where a.anula_id = e.id)
    and (coalesce(e.ocurrido_en_servidor, e.ocurrido_en) at time zone 'America/Bogota')::date between p_desde and p_hasta
  group by o.consecutivo, r.codigo, pr.nombre, pr.orden order by o.consecutivo, pr.orden;
end $$;

-- Consumo de tela por corte: teórico vs real
create or replace function public.informe_consumo_tela(p_desde date, p_hasta date)
returns table (corte text, op text, fecha date, material text, color text, piezas int, teorico numeric, consumo_real numeric, desviacion_pct numeric, unidad text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('corte', 'ver') or public.puede('costos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return query
  select c.consecutivo, o.consecutivo, (c.confirmado_en at time zone 'America/Bogota')::date, m.nombre, co.nombre, cc.piezas, cc.teorico, cc.real,
         cc.desviacion_pct, m.unidad
  from corte_consumos cc join cortes c on c.id = cc.corte_id join ordenes_produccion o on o.id = c.op_id
  join materiales m on m.id = cc.material_id left join colores co on co.id = cc.color_id
  where c.estado <> 'anulado' and c.confirmado_en is not null
    and (c.confirmado_en at time zone 'America/Bogota')::date between p_desde and p_hasta
  order by c.confirmado_en, c.consecutivo, m.nombre;
end $$;

-- Pedidos: cumplimiento (pedido, en OP, terminado, despachado)
create or replace function public.informe_pedidos(p_desde date, p_hasta date)
returns table (pedido text, cliente text, fecha date, comprometida date, pedidas int, en_op int, despachadas int, por_despachar int, cumplimiento_pct numeric,
               atrasado boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('pedidos', 'ver') or public.es_conexion_directa()) then raise exception 'Sin permiso' using errcode = '42501'; end if;
  return query
  select p.consecutivo, cl.nombre, p.fecha, p.fecha_comprometida,
         sum(s.cantidad)::int, sum(s.en_op)::int, sum(d.despachado)::int, sum(d.por_despachar)::int,
         round(sum(d.despachado) * 100.0 / nullif(sum(s.cantidad), 0), 1),
         p.fecha_comprometida < hoy_bogota() and sum(d.por_despachar) > 0
  from pedidos p left join clientes cl on cl.id = p.cliente_id
  join pedido_saldos s on s.pedido_id = p.id join pedido_despachos d on d.pedido_linea_id = s.pedido_linea_id
  where p.estado <> 'cancelado' and p.fecha between p_desde and p_hasta
  group by p.id, cl.nombre order by p.fecha, p.consecutivo;
end $$;

-- Satélites: prendas enviadas y devueltas, segundas, faltantes, a tiempo y valor
create or replace function public.informe_satelites(p_desde date, p_hasta date)
returns table (satelite text, proceso text, remisiones int, enviadas int, devueltas int, buenas int, segundas int, faltantes int,
               segundas_pct numeric, a_tiempo_pct numeric, valor numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('procesos_externos', 'ver') or public.puede('costos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return query
  with sal as (
    select r.* from remisiones r where r.tipo = 'salida' and r.estado <> 'anulada' and r.fecha between p_desde and p_hasta
  ), dev as (
    select d.remision_salida_id, min(d.fecha) as fecha, sum(u.cantidad) as cant, sum(u.buenas) as b, sum(u.segundas) as s, sum(u.faltantes) as f
    from remisiones d join remision_unidades u on u.remision_id = d.id where d.tipo = 'devolucion' and d.estado <> 'anulada' group by 1
  )
  select s2.nombre, pr.nombre, count(distinct sal.id)::int, sum((select sum(cantidad) from remision_unidades where remision_id = sal.id))::int,
         coalesce(sum(dev.cant), 0)::int, coalesce(sum(dev.b), 0)::int, coalesce(sum(dev.s), 0)::int, coalesce(sum(dev.f), 0)::int,
         round(sum(dev.s) * 100.0 / nullif(sum(dev.cant), 0), 1),
         round(count(*) filter (where dev.fecha <= coalesce(sal.fecha_compromiso, dev.fecha)) * 100.0 / nullif(count(dev.fecha), 0), 1),
         (select coalesce(sum(c.valor), 0) from cuentas_pagar_satelite c join remisiones rr on rr.id = c.remision_id
          where c.satelite_id = s2.id and c.proceso = sal.proceso and c.estado <> 'anulada' and rr.fecha between p_desde and p_hasta)
  from sal join satelites s2 on s2.id = sal.satelite_id join procesos pr on pr.codigo = sal.proceso left join dev on dev.remision_salida_id = sal.id
  group by s2.id, s2.nombre, pr.nombre, sal.proceso order by s2.nombre, pr.nombre;
end $$;

-- Inventario valorizado: telas, insumos, producto terminado y segundas
create or replace function public.informe_inventario_valorizado()
returns table (grupo text, codigo text, nombre text, color text, bodega text, cantidad numeric, unidad text, costo_unitario numeric, valor numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('inventario', 'ver') or public.puede('costos', 'ver') or public.es_conexion_directa()) then
    raise exception 'Sin permiso' using errcode = '42501';
  end if;
  return query
  select case m.tipo when 'tela' then 'Telas' else 'Insumos' end, m.codigo, m.nombre, co.nombre, b.codigo, round(s.fisico, 3), m.unidad,
         round(coalesce(s.costo_promedio, m.costo_estandar), 0), round(s.fisico * coalesce(s.costo_promedio, m.costo_estandar, 0), 0)
  from saldos_por_material s join materiales m on m.id = s.material_id left join colores co on co.id = s.color_id join bodegas b on b.id = s.bodega_id
  where s.fisico <> 0
  union all
  select case e.bodega_tipo when 'segundas' then 'Segundas' else 'Producto terminado' end, e.codigo, e.referencia_nombre, e.combinacion_codigo,
         e.bodega, e.cantidad, 'und', ce.unitario, round(e.cantidad * coalesce(ce.unitario, 0), 0)
  from existencias_producto e
  left join lateral (select round(avg(valor), 0) as unitario from ficha_costo_estandar f join referencias r on r.version_vigente_id = f.ficha_id
                     where r.id = e.referencia_id and f.concepto = 'total') ce on true
  order by 1, 2;
end $$;

-- OP atrasadas o en riesgo (fecha de entrega vs avance y programación)
create or replace function public.informe_ops_atrasadas()
returns table (op text, referencia text, cantidad int, proceso text, entrega date, fin_programado date, dias_atraso int, terminadas int, avance_pct numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.puede('informes', 'ver') or public.puede('op', 'ver') or public.es_conexion_directa()) then raise exception 'Sin permiso' using errcode = '42501'; end if;
  return query
  select o.consecutivo, r.codigo || ' ' || r.nombre, o.cantidad_total, pr.nombre, coalesce(o.fecha_comprometida, o.fecha_entrega_plan),
         (select max(p.fin_plan) from programacion p where p.op_id = o.id),
         greatest(hoy_bogota(), coalesce((select max(p.fin_plan) from programacion p where p.op_id = o.id), hoy_bogota()))
           - coalesce(o.fecha_comprometida, o.fecha_entrega_plan),
         (select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = o.id and tipo = 'ingreso_op')::int,
         round((select coalesce(sum(cantidad), 0) from movimientos_producto where op_id = o.id and tipo = 'ingreso_op') * 100.0 / nullif(o.cantidad_total, 0), 1)
  from ordenes_produccion o join referencias r on r.id = o.referencia_id left join procesos pr on pr.codigo = o.proceso_actual
  where o.estado in ('planeada','en_proceso') and coalesce(o.fecha_comprometida, o.fecha_entrega_plan) is not null
    and (coalesce(o.fecha_comprometida, o.fecha_entrega_plan) < hoy_bogota()
         or (select max(p.fin_plan) from programacion p where p.op_id = o.id) > coalesce(o.fecha_comprometida, o.fecha_entrega_plan))
  order by 7 desc, o.consecutivo;
end $$;

-- Permisos: Costos ve informes; el jefe de producción ve trazabilidad e informes
update public.permisos_modulo set puede_ver = true where modulo in ('trazabilidad','informes') and rol in ('jefe_produccion','costos','calidad');
insert into public.permisos_modulo (rol, modulo, puede_ver, puede_editar, puede_aprobar) values
  ('costos','trazabilidad', true, false, false), ('comercial','informes', true, false, false)
on conflict (rol, modulo) do nothing;
