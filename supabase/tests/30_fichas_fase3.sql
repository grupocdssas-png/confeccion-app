-- Pruebas de la Fase 3: lista maestra con historial de SAM, ficha técnica
-- versionada y congelada (regla 11), necesidades (BOM × curva), costo
-- estándar, aprobación por áreas e importador.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.ok(p_cond boolean, p_nombre text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALLÓ: %', p_nombre; end if;
  raise notice '✓ %', p_nombre;
end $$;
create or replace function pg_temp.falla(p_sql text, p_nombre text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then raise notice '✓ % (rechazado: %)', p_nombre, sqlerrm; return; end;
  raise exception 'FALLÓ: % (debía ser rechazado)', p_nombre;
end $$;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000009','diseno@prueba');
insert into perfiles (id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000009','Diseño');
insert into usuario_roles (usuario_id, rol) values ('aaaaaaaa-0000-0000-0000-000000000009','diseno');

create temp table f as select
  (select f.id from ficha_versiones f join referencias r on r.id = f.referencia_id where r.codigo = 'CAM-001' and f.version = 1) as v1,
  (select id from referencias where codigo = 'CAM-001') as ref,
  (select c.id from ficha_combinaciones c join ficha_versiones f on f.id = c.ficha_id join referencias r on r.id = f.referencia_id
    where r.codigo = 'CAM-001' and c.codigo = 'N') as comb_n,
  (select c.id from ficha_combinaciones c join ficha_versiones f on f.id = c.ficha_id join referencias r on r.id = f.referencia_id
    where r.codigo = 'CAM-001' and c.codigo = 'GJ') as comb_gj,
  (select id from tallas where codigo = 'S') as s, (select id from tallas where codigo = 'M') as m;
grant select on f to authenticated;

-- ---------- Ficha de ejemplo ----------
select pg_temp.ok((select estado = 'aprobada' and aprobada_en is not null from ficha_versiones where id = (select v1 from f)), 'Ficha CAM-001 v1 aprobada por las 3 áreas');
select pg_temp.ok((select version_vigente_id from referencias where codigo = 'CAM-001') = (select v1 from f), 'La referencia apunta a su versión vigente');
select pg_temp.ok((select sam_total from ficha_versiones where id = (select v1 from f)) = 6.53, 'SAM total = Σ SAM × repeticiones = 6,53 min');

-- Costo estándar (verificado a mano): materiales ponderados por la curva 1-2-2-1
select pg_temp.ok((select abs(valor - 9164.48) < 0.05 from ficha_costo_estandar x, f where x.ficha_id = f.v1 and x.combinacion_id = f.comb_n and concepto = 'materiales'),
                  'Materiales por prenda = $ 9.164,48 (jersey, rib, hilo, marquilla, bolsa con merma)');
select pg_temp.ok((select valor from ficha_costo_estandar x, f where x.ficha_id = f.v1 and x.combinacion_id = f.comb_n and concepto = 'mano_obra') = 1273.35,
                  'Mano de obra = 6,53 min × $ 195 = $ 1.273,35');
select pg_temp.ok((select valor from ficha_costo_estandar x, f where x.ficha_id = f.v1 and x.combinacion_id = f.comb_n and concepto = 'indirectos') = 555.05,
                  'Indirectos = 6,53 min × $ 85 = $ 555,05');
select pg_temp.ok((select sum(valor) filter (where concepto <> 'total') = sum(valor) filter (where concepto = 'total')
                   from ficha_costo_estandar x, f where x.ficha_id = f.v1 and x.combinacion_id = f.comb_n), 'Total = suma de los conceptos');

-- ---------- Necesidades (BOM × cantidades por talla) ----------
create temp table nec as
select n.*, m.codigo as mat, c.codigo as color
from f, necesidades_ficha(f.v1, jsonb_build_object(f.comb_gj, jsonb_build_object(f.s, 10, f.m, 20))) n
join materiales m on m.id = n.material_id left join colores c on c.id = n.color_id;
select pg_temp.ok((select round(cantidad, 4) from nec where mat = 'TEL-JER30' and parte_id = (select id from ficha_partes where ficha_id = (select v1 from f) and nombre = 'Cuerpo'))
                  = round((0.172 * 10 + 0.185 * 20) * 1.04, 4), 'Jersey del cuerpo: (0,172×10 + 0,185×20) × 1,04 kg');
select pg_temp.ok((select color from nec where mat = 'TEL-JER30' limit 1) = 'GJ', 'El cuerpo de la combinación GJ sale en gris jaspe');
select pg_temp.ok((select color from nec where mat = 'TEL-RIB') = 'N', 'El cuello de la combinación GJ sale en negro');
select pg_temp.ok((select cantidad from nec where mat = 'INS-MARQ') = 30, 'Marquillas: 1 por prenda = 30');

-- ---------- Regla 11: la versión aprobada está congelada ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';  -- diseño
select pg_temp.falla($$update ficha_partes set nombre = 'Otro' where ficha_id = (select v1 from f)$$, 'Editar una parte de una ficha aprobada');
select pg_temp.falla($$update ficha_bom_consumos set consumo = 1 where bom_id in (select id from ficha_bom where ficha_id = (select v1 from f))$$, 'Cambiar consumos de una ficha aprobada');
select pg_temp.falla($$insert into ficha_tallas (ficha_id, talla_id) select v1, (select id from tallas where codigo = 'XXL') from f$$, 'Agregar tallas a una ficha aprobada');
select pg_temp.falla($$update ficha_versiones set precio_objetivo = 1 where id = (select v1 from f)$$, 'Editar el encabezado de una ficha aprobada');
select pg_temp.falla($$delete from ficha_versiones where id = (select v1 from f)$$, 'Borrar una ficha aprobada');

-- Nueva versión: copia completa en borrador
create temp table v2 as select copiar_ficha((select v1 from f)) as id;
select pg_temp.ok((select version = 2 and estado = 'borrador' and basada_en_id = (select v1 from f) from ficha_versiones where id = (select id from v2)),
                  'Nueva versión v2 en borrador, basada en v1');
select pg_temp.ok((select (select count(*) from ficha_partes where ficha_id = v2.id) = 3
                      and (select count(*) from ficha_combinaciones where ficha_id = v2.id) = 2
                      and (select count(*) from ficha_bom where ficha_id = v2.id) = 6
                      and (select count(*) from ficha_bom_consumos c join ficha_bom b on b.id = c.bom_id where b.ficha_id = v2.id) = 24
                      and (select count(*) from ficha_medida_tallas t join ficha_medidas m on m.id = t.medida_id where m.ficha_id = v2.id) = 12
                      and (select count(*) from ficha_operaciones where ficha_id = v2.id) = 12
                      and (select count(*) from ficha_ruta where ficha_id = v2.id) = 5
                      and (select count(*) from ficha_artes where ficha_id = v2.id) = 1 from v2),
                  'La copia trae partes, combinaciones, BOM, consumos, medidas, operaciones, ruta y artes');
select pg_temp.ok(not exists (select 1 from ficha_combinacion_partes cp join ficha_combinaciones c on c.id = cp.combinacion_id
                              join ficha_partes p on p.id = cp.parte_id where c.ficha_id = (select id from v2) and p.ficha_id <> c.ficha_id),
                  'Las combinaciones de v2 apuntan a las partes de v2 (no a las de v1)');
select pg_temp.falla($$select copiar_ficha((select v1 from f))$$, 'Segunda versión en borrador de la misma referencia');

update ficha_bom_consumos set consumo = consumo + 0.01
 where bom_id in (select id from ficha_bom where ficha_id = (select id from v2) and material_id = '1c000000-0000-0000-0000-000000000001');
select pg_temp.ok((select count(*) from ficha_bom_consumos c join ficha_bom b on b.id = c.bom_id
                   where b.ficha_id = (select v1 from f) and c.consumo in (0.182, 0.195)) = 0, 'Editar v2 no cambia v1');
reset role;

-- La lista maestra cambia: queda historial y la versión aprobada conserva su SAM
update operaciones set sam = 0.38 where codigo = 'CAM-010';
select pg_temp.ok((select sam_anterior = 0.35 and sam_nuevo = 0.38 and origen = 'manual' from operaciones_historial h join operaciones o on o.id = h.operacion_id
                   where o.codigo = 'CAM-010' order by h.id desc limit 1), 'Historial de SAM: 0,35 → 0,38');
select pg_temp.ok((select fo.sam from ficha_operaciones fo join operaciones o on o.id = fo.operacion_id where fo.ficha_id = (select v1 from f) and o.codigo = 'CAM-010') = 0.35,
                  'La ficha aprobada conserva el SAM con que se aprobó');
select pg_temp.ok((select unidades_hora from operaciones where codigo = 'CAM-010') = round(60 / 0.38, 2), 'Unidades por hora = 60 / SAM');

-- ---------- Validación y aprobación por áreas ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';
create temp table incompleta as select nueva_referencia('JOG-001', 'Jogger (EJEMPLO)') as id;
select pg_temp.falla($$select enviar_ficha_aprobacion((select id from incompleta))$$, 'Enviar a aprobación una ficha incompleta');
select pg_temp.ok(array_length(validar_ficha((select id from incompleta)), 1) >= 6, 'validar_ficha() lista lo que falta');

select enviar_ficha_aprobacion((select id from v2));
select pg_temp.ok((select fo.sam from ficha_operaciones fo join operaciones o on o.id = fo.operacion_id where fo.ficha_id = (select id from v2) and o.codigo = 'CAM-010') = 0.38,
                  'Al enviar, v2 toma el SAM vigente de la lista maestra');
select pg_temp.falla($$update ficha_partes set orden = 9 where ficha_id = (select id from v2)$$, 'Editar una ficha en aprobación');
select pg_temp.falla($$select decidir_ficha((select id from v2), 'costos', true)$$, 'Diseño aprobando por Costos');
select pg_temp.falla($$select decidir_ficha((select id from v2), 'diseno', false)$$, 'Rechazar sin motivo');
select decidir_ficha((select id from v2), 'diseno', false, 'Ajustar consumo de mangas');
select pg_temp.ok((select estado = 'borrador' and comentario_rechazo like '%mangas%' from ficha_versiones where id = (select id from v2)), 'Rechazo: vuelve a borrador con el motivo');
select enviar_ficha_aprobacion((select id from v2));
select decidir_ficha((select id from v2), 'diseno', true);
select pg_temp.falla($$select decidir_ficha((select id from v2), 'diseno', true)$$, 'La misma área decide dos veces');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
select pg_temp.ok(decidir_ficha((select id from v2), 'produccion', true) = 'en_aprobacion', 'Con 2 de 3 áreas sigue en aprobación');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000008';  -- costos
select pg_temp.ok(decidir_ficha((select id from v2), 'costos', true) = 'aprobada', 'Con las 3 áreas queda aprobada');
reset role;
select pg_temp.ok((select estado from ficha_versiones where id = (select v1 from f)) = 'obsoleta', 'La versión anterior queda obsoleta');
select pg_temp.ok((select version_vigente_id from referencias where codigo = 'CAM-001') = (select id from v2), 'La vigente pasa a ser v2');
select pg_temp.ok((select count(*) from ficha_aprobaciones where ficha_id = (select id from v2)) = 4, 'Las decisiones quedan registradas (1 rechazo + 3 aprobaciones)');
select pg_temp.falla($$delete from ficha_aprobaciones$$, 'Borrar el registro de aprobaciones');

-- Duplicar a otra referencia
reset request.jwt.claim.sub;
insert into referencias (codigo, nombre) values ('CAM-002', 'Camiseta estampada (EJEMPLO)');
create temp table dup as select copiar_ficha((select v1 from f), (select id from referencias where codigo = 'CAM-002')) as id;
select pg_temp.ok((select version = 1 and referencia_id = (select id from referencias where codigo = 'CAM-002') from ficha_versiones where id = (select id from dup)),
                  'Duplicar desde otra referencia crea su versión 1');

-- ---------- Importador desde SAMMU ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';  -- diseño (edita operaciones)
create temp table val as select validar_importacion('operaciones', '[
  {"codigo":"CAM-010","nombre":"Unir hombros","sam":"0.36","valor_destajo":"72","maquina":"FIL"},
  {"codigo":"BUZ-010","nombre":"Pegar capota","sam":"0.9","valor_destajo":"180","maquina":"Fileteadora","familia":"Buzos y chaquetas","tipo_producto":"Buzo con capota"},
  {"codigo":"BUZ-020","nombre":"Bolsillo canguro","sam":"0.7","maquina":"MAQUINA-QUE-NO-EXISTE"}]'::jsonb) as r;
select pg_temp.ok((select (r->>'ok')::int = 2 and jsonb_array_length(r->'errores') = 1 from val), 'Validar: 2 filas bien y 1 con error, sin guardar nada');
select pg_temp.ok(not exists (select 1 from operaciones where codigo = 'BUZ-010'), 'La validación no guarda');
create temp table imp as select importar('operaciones', '[
  {"codigo":"CAM-010","nombre":"Unir hombros","sam":"0.36","valor_destajo":"72","maquina":"FIL"},
  {"codigo":"BUZ-010","nombre":"Pegar capota","sam":"0.9","valor_destajo":"180","maquina":"Fileteadora","familia":"Buzos y chaquetas","tipo_producto":"Buzo con capota"},
  {"codigo":"BUZ-020","nombre":"Bolsillo canguro","sam":"0.7","maquina":"MAQUINA-QUE-NO-EXISTE"}]'::jsonb, 'sammu_operaciones.xlsx') as r;
reset role;
select pg_temp.ok((select (r->>'ok')::int from imp) = 2, 'Importar: 2 operaciones guardadas');
select pg_temp.ok((select r->'errores'->0->>'error' from imp) like '%no existe%', 'La fila con error explica el motivo');
select pg_temp.ok(not exists (select 1 from operaciones where codigo = 'BUZ-020'), 'La fila con error no se guarda');
select pg_temp.ok((select origen from operaciones_historial h join operaciones o on o.id = h.operacion_id where o.codigo = 'CAM-010' order by h.id desc limit 1) = 'importacion',
                  'El cambio de SAM por importación queda en el historial');
select pg_temp.ok((select familia_id is not null and tipo_maquina_id is not null from operaciones where codigo = 'BUZ-010'), 'Familia y máquina se reconocen por nombre');
select pg_temp.ok((select filas_ok = 2 and filas_error = 1 from importaciones order by fecha desc limit 1), 'La importación queda registrada');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';  -- gerencia
create temp table imp2 as select importar('empleados', '[{"codigo":"E101","nombres":"Prueba","apellidos":"Uno","celula":"NOEXISTE"},
                                                        {"codigo":"E102","nombres":"Prueba","apellidos":"Dos","celula":"MOD1","documento":"123"}]'::jsonb) as r;
reset role;
select pg_temp.ok((select (r->>'ok')::int = 1 from imp2) and (select qr from empleados where codigo = 'E102') = 'OPR-0102',
                  'Empleados: célula inexistente rechazada; el carnet se genera (OPR-0102)');

-- ---------- Importar la secuencia de una referencia (formato real de SAMMU) ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';  -- diseño
create temp table polo as select nueva_referencia('POLO-ECO-001', 'Polo económica (EJEMPLO)',
  (select id from familias_producto where nombre = 'Camisetas'), (select id from tipos_producto where nombre = 'Camiseta polo')) as id;
create temp table filas_polo as select '[
  {"secuencia":"1","nombre":"MARCAR PERILLA","maquina":"MAN","sam":"0.33","proceso":"TERMINACION","repeticiones":"1","revision":"FALSE"},
  {"secuencia":"2","nombre":"DOBLAR BORDE PERILLA","maquina":"PL1","sam":"0.1","proceso":"CONFECCION","repeticiones":"2","revision":"FALSE"},
  {"secuencia":"5","nombre":"UNIR HOMBROS","maquina":"FLTPS","sam":"0.41","proceso":"CONFECCION","repeticiones":"1","revision":"FALSE"},
  {"secuencia":"16","nombre":"MONTAR PUÑO","maquina":"FLT","sam":"0.3","proceso":"CONFECCION","repeticiones":"2","revision":"FALSE"},
  {"secuencia":"24","nombre":"PULIR Y REVISAR","maquina":"MAN","sam":"1","proceso":"TERMINACION","repeticiones":"1","revision":"TRUE"},
  {"secuencia":"33","nombre":"TERMOFIJADA","maquina":"TERMOFIJADORA","sam":"0.0208","proceso":"TERMINACION","repeticiones":"2","revision":"FALSE","unidades_marcacion":"12"}
]'::jsonb as f;
grant select on polo, filas_polo to authenticated;

create temp table vsin as select validar_importacion('secuencia', (select f from filas_polo), jsonb_build_object('ficha_id', (select id from polo))) as r;
select pg_temp.ok((select (r->>'ok')::int = 2 and jsonb_array_length(r->'errores') = 4 from vsin), 'Sin crear máquinas: 4 filas fallan (PL1, FLTPS, FLT y TERMOFIJADORA no existen)');
create temp table vcon as select validar_importacion('secuencia', (select f from filas_polo),
  jsonb_build_object('ficha_id', (select id from polo), 'crear_maquinas', true)) as r;
select pg_temp.ok((select (r->>'ok')::int = 6 and (r->'resumen'->>'maquinas_creadas')::int = 4 and (r->'resumen'->>'operaciones_nuevas')::int = 6 from vcon),
                  'Creando máquinas: las 6 filas pasan y se informan las máquinas y operaciones nuevas');
select pg_temp.ok(not exists (select 1 from tipos_maquina where codigo = 'TERMOFIJADORA') and not exists (select 1 from ficha_operaciones where ficha_id = (select id from polo)),
                  'Validar no deja nada creado');
create temp table imp_polo as select importar('secuencia', (select f from filas_polo), 'POLO_ECONOMICA001.csv',
  jsonb_build_object('ficha_id', (select id from polo), 'crear_maquinas', true)) as r;
reset role;
select pg_temp.ok((select count(*) from ficha_operaciones where ficha_id = (select id from polo)) = 6, 'La secuencia queda en la ficha (6 operaciones)');
select pg_temp.ok((select sam_total_ficha((select id from polo))) = 0.33 + 0.1 * 2 + 0.41 + 0.3 * 2 + 1 + 0.0208 * 2, 'SAM total de la ficha = Σ SAM × repeticiones');
select pg_temp.ok((select nombre from operaciones o join ficha_operaciones fo on fo.operacion_id = o.id
                   where fo.ficha_id = (select id from polo) and fo.secuencia = 16) = 'MONTAR PUÑO', 'La Ñ se conserva');
select pg_temp.ok((select o.tipo from operaciones o where nombre = 'PULIR Y REVISAR' and tipo_producto_id = (select id from tipos_producto where nombre = 'Camiseta polo')) = 'inspeccion',
                  '"Es operación de revisión" = TRUE queda como inspección');
select pg_temp.ok((select fo.unidades_marcacion from ficha_operaciones fo join operaciones o on o.id = fo.operacion_id
                   where fo.ficha_id = (select id from polo) and o.nombre = 'TERMOFIJADA') = 12, 'Unidades al marcar = 12');
select pg_temp.ok((select codigo like 'OP-%' from operaciones where nombre = 'UNIR HOMBROS' and tipo_producto_id = (select id from tipos_producto where nombre = 'Camiseta polo')),
                  'Las operaciones sin código reciben uno (OP-0001…)');
select pg_temp.ok((select count(*) from ficha_ruta where ficha_id = (select id from polo)) = 2, 'La ruta incluye los procesos de la secuencia');

-- Reimportar con un SAM distinto: la operación (mismo nombre y tipo de producto) se actualiza y se informa
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';
create temp table imp_polo2 as select importar('secuencia',
  jsonb_set((select f from filas_polo), '{2,sam}', '"0.45"'), 'POLO_ECONOMICA001.csv', jsonb_build_object('ficha_id', (select id from polo))) as r;
reset role;
select pg_temp.ok((select (r->'resumen'->>'operaciones_nuevas')::int = 0 and (r->'resumen'->>'operaciones_existentes')::int = 6
                          and r->'resumen'->'sam_cambiados'->0->>'nombre' = 'UNIR HOMBROS' from imp_polo2),
                  'Reimportar: no duplica operaciones e informa el SAM que cambió');
select pg_temp.ok((select count(*) from ficha_operaciones where ficha_id = (select id from polo)) = 6, 'Reimportar reemplaza la secuencia (no la duplica)');
select pg_temp.ok((select sam from operaciones where codigo = 'CAM-010') = 0.36, 'Operación de otro tipo de producto con el mismo nombre no se toca');
select pg_temp.falla($$select importar('secuencia', '[]'::jsonb, null, jsonb_build_object('ficha_id', (select v1 from f)))$$, 'Importar secuencia sobre una ficha aprobada');

set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000009';
create temp table nueva as select validar_importacion('secuencia', (select f from filas_polo),
  jsonb_build_object('crear_maquinas', true, 'nueva_referencia', jsonb_build_object('codigo', 'POLO-ECO-002', 'nombre', 'Polo nueva'))) as r;
reset role;
select pg_temp.ok((select (r->>'ok')::int = 6 from nueva) and not exists (select 1 from referencias where codigo = 'POLO-ECO-002'),
                  'Validar con referencia nueva no la deja creada');
