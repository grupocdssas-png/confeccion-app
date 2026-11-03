-- Pruebas de la Fase 5: cálculo de corte (mismos casos que la app), regla de
-- lotes (8), salida de tela por rollo, retazos, paquetes (9), juegos (10) y anulación (2).
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

-- ---------- 1. Casos compartidos con la app (test_vectores/corte) ----------
\set vectores `jq -s -c . :raiz/test_vectores/corte/*.json`
create temp table vectores as select v from jsonb_array_elements(:'vectores'::jsonb) v;
select pg_temp.ok(count(*) >= 3, 'Se cargaron los casos compartidos con la app') from vectores;
do $$
declare x record; r jsonb; e jsonb; p jsonb;
begin
  for x in select v from vectores loop
    r := corte_calcular_bloque(x.v -> 'bloque', (x.v ->> 'despunte_cm')::numeric);
    e := x.v -> 'esperado';
    perform pg_temp.ok(r -> 'metros' = e -> 'metros', (x.v ->> 'nombre') || ': metros');
    perform pg_temp.ok(r -> 'capas_espiga' = e -> 'capas_espiga' and r -> 'capas_seccion' = e -> 'capas_seccion', (x.v ->> 'nombre') || ': capas por espiga y sección');
    perform pg_temp.ok(r -> 'piezas' = e -> 'piezas', (x.v ->> 'nombre') || ': piezas por color y talla');
    perform pg_temp.ok(r -> 'metros_por_rollo' = e -> 'metros_por_rollo', (x.v ->> 'nombre') || ': metros por rollo');
    select jsonb_agg(jsonb_build_object('color_id', color_id, 'lote', lote, 'espiga', espiga, 'talla', talla, 'capa_desde', capa_desde,
                                        'capa_hasta', capa_hasta, 'cantidad', cantidad) order by orden)
      into p from corte_plan_paquetes(x.v -> 'bloque', (x.v ->> 'max_paquete')::int);
    perform pg_temp.ok(p = e -> 'paquetes', (x.v ->> 'nombre') || ': paquetes');
  end loop;
end $$;
select pg_temp.falla($$select corte_calcular_bloque('{"tallas":["M"],"secciones":[{"letra":"A","largo_m":1,"unidades":{"M":1}}],"tramos":[{"rollo_id":"r","color_id":"N","espiga":2,"capas":1}]}', 0)$$,
                     'Espiga que no existe en el trazo');
select pg_temp.falla($$select corte_calcular_bloque('{"tallas":["M"],"secciones":[{"letra":"A","largo_m":0,"unidades":{"M":1}}],"tramos":[]}', 0)$$,
                     'Sección sin largo');

-- ---------- 2. Datos: una OP nueva de 90 camisetas ----------
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000011', 'cortador@prueba');
insert into perfiles (id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000011', 'Cortador');
insert into usuario_roles (usuario_id, rol) values ('aaaaaaaa-0000-0000-0000-000000000011', 'corte');
update permisos_modulo set puede_aprobar = false where rol = 'corte' and modulo = 'corte';   -- el cortador no autoriza

set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe de producción
create temp table op as select crear_op((select id from referencias where codigo = 'CAM-001'),
  '{"N":{"S":10,"M":20,"L":20,"XL":10},"GJ":{"S":5,"M":10,"L":10,"XL":5}}'::jsonb, current_date + 15, 1) as id;
reset role;
create temp table k as
select (select id from op) as op,
       (select ficha_version_id from ordenes_produccion where id = (select id from op)) as ficha,
       (select id from ficha_partes where ficha_id = (select ficha_version_id from ordenes_produccion where id = (select id from op)) and nombre = 'Cuerpo') as cuerpo,
       (select id from ficha_partes where ficha_id = (select ficha_version_id from ordenes_produccion where id = (select id from op)) and nombre = 'Mangas') as mangas,
       (select id from ficha_partes where ficha_id = (select ficha_version_id from ordenes_produccion where id = (select id from op)) and nombre = 'Cuello') as cuello,
       (select id from tallas where codigo = 'S') as s, (select id from tallas where codigo = 'M') as m,
       (select id from tallas where codigo = 'L') as l, (select id from tallas where codigo = 'XL') as xl,
       (select id from colores where codigo = 'N') as negro, (select id from colores where codigo = 'GJ') as gris,
       '1c000000-0000-0000-0000-000000000001'::uuid as jersey, '1c000000-0000-0000-0000-000000000003'::uuid as rib,
       (select id from rollos where codigo = 'TL-000001') as tl1, (select id from rollos where codigo = 'TL-000002') as tl2,
       (select id from rollos where codigo = 'TL-000004') as tl4, (select id from rollos where codigo = 'TL-000005') as tl5,
       (select id from rollos where codigo = 'TL-000007') as tl7, (select id from rollos where codigo = 'TL-000008') as tl8,
       '1b000000-0000-0000-0000-000000000003'::uuid as mesa;
grant select on k, op to authenticated;

-- Documento del corte combinado: jersey (cuerpo + mangas) negro en dos lotes y gris; rib negro para el cuello
create temp table docs as
select jsonb_build_object(
  'bloques', jsonb_build_array(
    jsonb_build_object('id', 'b1', 'nombre', 'Cuerpo y mangas', 'material_id', k.jersey, 'partes', jsonb_build_array(k.cuerpo, k.mangas),
      'tallas', jsonb_build_array(k.s, k.m, k.l, k.xl),
      'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 5.70,
                     'unidades', jsonb_build_object(k.s, 1, k.m, 2, k.l, 2, k.xl, 1))),
      'tramos', jsonb_build_array(
        jsonb_build_object('rollo_id', k.tl1, 'color_id', k.negro, 'espiga', 1, 'capas', 6),
        jsonb_build_object('rollo_id', k.tl4, 'color_id', k.negro, 'espiga', 1, 'capas', 4),
        jsonb_build_object('rollo_id', k.tl5, 'color_id', k.gris, 'espiga', 1, 'capas', 5))),
    jsonb_build_object('id', 'b2', 'nombre', 'Cuellos', 'material_id', k.rib, 'partes', jsonb_build_array(k.cuello),
      'tallas', jsonb_build_array(k.s, k.m, k.l, k.xl),
      'secciones', jsonb_build_array(jsonb_build_object('letra', 'A', 'largo_m', 0.60,
                     'unidades', jsonb_build_object(k.s, 4, k.m, 8, k.l, 8, k.xl, 4))),
      'tramos', jsonb_build_array(jsonb_build_object('rollo_id', k.tl8, 'color_id', k.negro, 'espiga', 1, 'capas', 4)))),
  'rollos', jsonb_build_object(k.tl8, jsonb_build_object('fin', 'retazo'))) as doc
from k;
grant select on docs to authenticated;

-- ---------- 3. Borrador y validaciones ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000004';  -- bodega
select pg_temp.falla($$select guardar_corte(jsonb_build_object('op_id', (select op from k), 'documento', (select doc from docs)))$$,
                     'Bodega no crea cortes (no tiene permiso en Corte)');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000011';  -- cortador
create temp table c1 as select guardar_corte(jsonb_build_object('op_id', (select op from k), 'tipo', 'un_color', 'estacion_id', (select mesa from k),
  'despunte_cm', 2, 'documento', (select doc from docs))) as id;
select pg_temp.falla($$select confirmar_corte((select id from c1))$$, 'Un corte "de un color" no acepta negro y gris en el mismo tendido');
select guardar_corte(jsonb_build_object('id', (select id from c1), 'tipo', 'combinada', 'estacion_id', (select mesa from k), 'despunte_cm', 2,
                                        'documento', (select doc from docs)));
-- tela equivocada para una parte
select pg_temp.falla($$select confirmar_corte(guardar_corte(jsonb_build_object('op_id', (select op from k), 'tipo', 'combinada', 'estacion_id', (select mesa from k),
  'documento', jsonb_build_object('bloques', jsonb_build_array(jsonb_set((select doc -> 'bloques' -> 1 from docs), '{partes}', jsonb_build_array((select cuerpo from k))))))))$$,
  'El cuerpo no se corta en rib (no es la tela de la ficha)');
-- rollo que no alcanza
select pg_temp.falla($$select confirmar_corte(guardar_corte(jsonb_build_object('op_id', (select op from k), 'tipo', 'combinada', 'estacion_id', (select mesa from k),
  'documento', jsonb_build_object('bloques', jsonb_build_array(jsonb_set((select doc -> 'bloques' -> 0 from docs), '{tramos}',
     jsonb_build_array(jsonb_build_object('rollo_id', (select tl7 from k), 'color_id', (select negro from k), 'capas', 2))))))))$$,
  'Un retazo de 5 m no alcanza para 2 capas de 5,72 m');
-- rollo de otro color
select pg_temp.falla($$select confirmar_corte(guardar_corte(jsonb_build_object('op_id', (select op from k), 'tipo', 'combinada', 'estacion_id', (select mesa from k),
  'documento', jsonb_build_object('bloques', jsonb_build_array(jsonb_set((select doc -> 'bloques' -> 0 from docs), '{tramos}',
     jsonb_build_array(jsonb_build_object('rollo_id', (select tl5 from k), 'color_id', (select negro from k), 'capas', 1))))))))$$,
  'Un rollo gris no se puede declarar como negro');

-- ---------- 4. Regla 8: lotes distintos (L-2410-N1 y L-2411-N2; anchos 180 y 177 cm) ----------
select pg_temp.ok((select count(*) = 1 and bool_and(mezcla_lotes and excede_ancho and not autorizado) from corte_verificar_lotes((select id from c1))),
                  'Se detecta la mezcla de lotes y la diferencia de ancho de 3 cm en el negro');
select pg_temp.falla($$select confirmar_corte((select id from c1))$$, 'No se confirma sin la autorización del jefe de corte');
select pg_temp.falla($$select autorizar_corte((select id from c1), (select jersey from k), (select negro from k), 'Lo pide producción')$$,
                     'El cortador no puede autorizar');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';  -- jefe (aprobar en Corte)
select pg_temp.falla($$select autorizar_corte((select id from c1), (select jersey from k), (select negro from k), ' ')$$, 'Autorización sin motivo');
select autorizar_corte((select id from c1), (select jersey from k), (select negro from k), 'Tonos revisados en luz día: se separan por paquete');
select pg_temp.falla($$select autorizar_corte((select id from c1), (select jersey from k), (select gris from k), 'x')$$,
                     'No se autoriza lo que no lo necesita (el gris es de un solo lote)');

-- ---------- 5. Confirmar ----------
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000011';  -- cortador
reset role;
create temp table antes as
select (select metros_saldo from rollos where id = (select tl1 from k)) as tl1_m,
       (select fisico from saldos_por_material where material_id = (select jersey from k) and color_id = (select negro from k) and bodega_id = '1a000000-0000-0000-0000-000000000001') as negro_fisico,
       (select reservado from op_necesidades where op_id = (select op from k) and material_id = (select jersey from k) and color_id = (select negro from k)) as negro_reservado;
grant select on antes to authenticated;
set role authenticated;
create temp table r1 as select confirmar_corte((select id from c1)) as r;
reset role;
select pg_temp.ok((select estado = 'confirmado' from cortes where id = (select id from c1)), 'El corte queda confirmado');
select pg_temp.ok((select (r ->> 'paquetes')::int = 18 from r1), '18 paquetes: 12 de cuerpo y mangas + 6 de cuellos');
select pg_temp.ok((select count(*) = 18 and bool_and(codigo like 'PQ-C01-%') and bool_and(cantidad <= 20) from paquetes where corte_id = (select id from c1)),
                  'Los paquetes llevan el código de la mesa (PQ-C01-…) y máximo 20 prendas');
select pg_temp.ok(not exists (select 1 from paquetes p join corte_rollos cr on cr.corte_id = p.corte_id and cr.material_id = p.material_id and cr.color_id = p.color_id
                              where p.corte_id = (select id from c1) group by p.id having count(distinct cr.lote_tintura) > 1 and bool_and(cr.lote_tintura <> p.lote_tintura)),
                  'Ningún paquete mezcla lotes');
select pg_temp.ok((select count(*) filter (where lote_tintura = 'L-2410-N1') = 4 and count(*) filter (where lote_tintura = 'L-2411-N2') = 4
                   from paquetes where corte_id = (select id from c1) and color_id = (select negro from k) and material_id = (select jersey from k)),
                  'El negro sale en paquetes separados por lote (4 del lote N1 y 4 del N2)');
select pg_temp.ok((select capa_desde = 7 and capa_hasta = 10 and cantidad = 8 from paquetes p join k on true
                   where p.corte_id = (select id from c1) and p.lote_tintura = 'L-2411-N2' and p.talla_id = k.m),
                  'El paquete talla M del lote N2 va de la capa 7 a la 10 (8 piezas)');
select pg_temp.ok((select sum(piezas) = 90 from corte_resultados where corte_id = (select id from c1) and bloque_id = 'b1'),
                  'El tendido de jersey da 90 cuerpos con mangas');
select pg_temp.ok((select sum(piezas) = 96 from corte_resultados where corte_id = (select id from c1) and bloque_id = 'b2'),
                  'El tendido de rib da 96 cuellos');

-- inventario
select pg_temp.ok((select metros_consumo = 34.32 and kilos_consumo = 9.948 and fin = 'vuelve' from corte_rollos where corte_id = (select id from c1) and rollo_id = (select tl1 from k)),
                  'TL-000001: 6 capas × 5,72 m = 34,32 m = 9,948 kg (proporción del rollo)');
select pg_temp.ok((select metros_saldo from rollos where id = (select tl1 from k)) = (select tl1_m from antes) - 34.32, 'El rollo queda con su saldo menos lo cortado');
select pg_temp.ok(exists (select 1 from movimientos_inventario where tipo = 'salida_op' and rollo_id = (select tl1 from k) and op_id = (select op from k)
                          and documento_id = (select consecutivo from cortes where id = (select id from c1)) and cantidad = -9.948),
                  'La salida queda en el kardex con la OP (regla 1)');
select pg_temp.ok(abs((select fisico from saldos_por_material where material_id = (select jersey from k) and color_id = (select negro from k) and bodega_id = '1a000000-0000-0000-0000-000000000001')
                      - ((select negro_fisico from antes) - 16.580)) < 0.0005, 'El físico del jersey negro baja 16,580 kg (9,948 + 6,632)');
select pg_temp.ok((select consumido = 16.580 and reservado = round((select negro_reservado from antes) - 16.580, 3)
                   from op_necesidades where op_id = (select op from k) and material_id = (select jersey from k) and color_id = (select negro from k)),
                  'La OP registra 16,580 kg consumidos y libera esa reserva');
select pg_temp.ok((select r.estado = 'agotado' and r.metros_saldo = 0 and cr.retazo_id is not null and t.es_retazo and t.metros_saldo = 11.12 and t.rollo_origen_id = r.id
                   from corte_rollos cr join rollos r on r.id = cr.rollo_id join rollos t on t.id = cr.retazo_id
                   where cr.corte_id = (select id from c1) and cr.rollo_id = (select tl8 from k)),
                  'Lo que quedó del rib (13,6 − 2,48 = 11,12 m) pasa a un retazo con el mismo lote');
select pg_temp.ok(not exists (select 1 from rollos where metros_saldo < 0 or kilos_saldo < 0), 'Ningún rollo queda negativo');

-- consumo teórico vs real
select pg_temp.ok((select abs(desviacion_pct) <= 5 from corte_consumos where corte_id = (select id from c1) and material_id = (select jersey from k) and color_id = (select negro from k)),
                  'El jersey negro está dentro de la tolerancia de ±5 %');
select pg_temp.ok(exists (select 1 from alertas where tipo = 'desviacion_corte' and entidad_id = (select id from c1)::text and datos ->> 'material_id' = (select rib from k)::text),
                  'El rib consumió mucho menos que el estándar: alerta de desviación');

-- ---------- 6. Juegos (prenda combinada) ----------
select pg_temp.ok((select (prendas_cortadas = 0) from op_corte_resumen where op_id = (select op from k)), 'Sin juegos todavía no hay prendas cortadas (las piezas no van sueltas a confección)');
create temp table sim as select simular_juegos((select op from k)) as s;
select pg_temp.ok((select (s ->> 'juegos')::int = 90 from sim), 'Simulación: alcanzan 90 juegos completos');
select pg_temp.ok((select jsonb_agg(x.v ->> 'cantidad' order by (x.v ->> 'talla')) = '["2","2","1","1"]'::jsonb
                   from sim, jsonb_array_elements(s -> 'sueltas') x(v)), 'Sobran 6 cuellos sueltos (L 2, M 2, S 1, XL 1)');
set role authenticated;
create temp table jg as select armar_juegos((select op from k)) as r;
reset role;
select pg_temp.ok((select count(*) = 12 and sum(cantidad) = 90 from juegos where op_id = (select op from k)), '12 juegos con 90 prendas');
select pg_temp.ok(not exists (
    select 1 from juegos j join juego_componentes jc on jc.juego_id = j.id join paquetes p on p.id = jc.paquete_id join k on true
    where j.op_id = k.op and jc.parte_id = k.cuerpo group by j.id having count(distinct p.lote_tintura) > 1),
  'Ningún juego mezcla lotes del cuerpo');
select pg_temp.ok(not exists (
    select 1 from juegos j join juego_componentes jc on jc.juego_id = j.id join paquetes p on p.id = jc.paquete_id
    join ficha_combinacion_partes cp on cp.combinacion_id = j.combinacion_id and cp.parte_id = jc.parte_id
    where j.op_id = (select op from k) and (p.color_id <> cp.color_id or p.talla_id <> j.talla_id)),
  'Cada parte del juego tiene el color de su combinación y la talla del juego (gris con cuello negro)');
select pg_temp.ok(not exists (select 1 from juegos j where j.op_id = (select op from k)
                               and (select count(distinct jc.parte_id) from juego_componentes jc where jc.juego_id = j.id) <> 3),
                  'Todos los juegos traen cuerpo, mangas y cuello (regla 10)');
select pg_temp.ok((select buenas = 90 and estado = 'en_proceso' from op_procesos where op_id = (select op from k) and proceso = 'corte'),
                  'El avance de corte suma las 90 prendas en juegos');
select pg_temp.ok((select piezas_sueltas = 6 from op_corte_resumen where op_id = (select op from k)), 'Quedan 6 piezas sueltas registradas');
set role authenticated;
select pg_temp.ok((select (armar_juegos((select op from k)) ->> 'juegos')::int = 0), 'Volver a armar no duplica juegos');
reset role;

-- ---------- 7. Anulación de un corte confirmado (eventos inversos) ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000011';
select pg_temp.falla($$select anular_corte((select id from c1), 'error')$$, 'El cortador no anula cortes confirmados');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select pg_temp.falla($$select anular_corte((select id from c1), 'error')$$, 'No se anula un corte con juegos armados');
create temp table c2 as select guardar_corte(jsonb_build_object('op_id', (select op from k), 'tipo', 'un_color', 'estacion_id', (select mesa from k), 'despunte_cm', 2,
  'documento', jsonb_build_object('bloques', jsonb_build_array(jsonb_set((select doc -> 'bloques' -> 0 from docs), '{tramos}',
     jsonb_build_array(jsonb_build_object('rollo_id', (select tl2 from k), 'color_id', (select negro from k), 'capas', 2))))))) as id;
reset role;
create temp table antes2 as select metros_saldo, kilos_saldo from rollos where id = (select tl2 from k);
create temp table cons2 as select consumido from op_necesidades where op_id = (select op from k) and material_id = (select jersey from k) and color_id = (select negro from k);
grant select on antes2, cons2 to authenticated;
set role authenticated;
select pg_temp.falla($$select confirmar_corte((select id from c2))$$, 'El rollo TL-000002 es del lote N1 pero el corte ya mezcló lotes: necesita otra autorización');
select autorizar_corte((select id from c2), (select jersey from k), (select negro from k), 'Mismo caso del corte anterior');
select confirmar_corte((select id from c2));
reset role;
select pg_temp.ok((select metros_saldo = (select metros_saldo from antes2) - 11.44 from rollos where id = (select tl2 from k)), 'El segundo corte gasta 11,44 m del TL-000002');
set role authenticated;
select pg_temp.falla($$select anular_corte((select id from c2), '')$$, 'Anular sin motivo');
select anular_corte((select id from c2), 'Se cortó con el trazo equivocado');
reset role;
select pg_temp.ok((select r.metros_saldo = a.metros_saldo and r.kilos_saldo = a.kilos_saldo and r.estado = 'disponible' from rollos r, antes2 a where r.id = (select tl2 from k)),
                  'Al anular, el rollo recupera su saldo');
select pg_temp.ok((select count(*) > 0 and bool_and(anula_id is not null) from movimientos_inventario
                   where tipo = 'anulacion' and documento_id = (select consecutivo from cortes where id = (select id from c2))),
                  'La anulación son movimientos inversos (los originales no se tocan)');
select pg_temp.ok((select consumido = (select consumido from cons2) from op_necesidades where op_id = (select op from k) and material_id = (select jersey from k) and color_id = (select negro from k)),
                  'El consumo de la OP vuelve a lo de antes');
select pg_temp.ok((select bool_and(estado = 'anulado') from paquetes where corte_id = (select id from c2)), 'Los paquetes del corte anulado quedan anulados');
select pg_temp.falla($$update cortes set despunte_cm = 5 where id = (select id from c1)$$, 'Un corte confirmado no se edita');
select pg_temp.falla($$delete from movimientos_inventario where documento_id = (select consecutivo from cortes where id = (select id from c1))$$,
                     'Los movimientos del corte no se borran');

-- ---------- 8. Terminar el corte de la OP ----------
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000011';
select terminar_corte_op((select op from k));
reset role;
select pg_temp.ok((select o.proceso_actual = 'estampacion' and p.estado = 'terminado' from ordenes_produccion o join op_procesos p on p.op_id = o.id and p.proceso = 'corte'
                   where o.id = (select op from k)), 'Al terminar el corte la OP pasa a estampación');
set role authenticated;
select pg_temp.falla($$select confirmar_corte(guardar_corte(jsonb_build_object('op_id', (select op from k), 'estacion_id', (select mesa from k), 'documento', (select doc from docs))))$$,
                     'Después de terminar no se confirman más cortes');
reset role;
update permisos_modulo set puede_aprobar = true where rol = 'corte' and modulo = 'corte';
