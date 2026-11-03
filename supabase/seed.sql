-- =====================================================================
-- DATOS DE EJEMPLO — todo lo que dice "EJEMPLO" es ficticio.
-- No son clientes, empleados ni precios reales. Reemplazar antes de producción.
-- Los usuarios (cuentas de Supabase Auth) se crean con herramientas/crear_usuarios_demo.mjs
-- =====================================================================

-- Festivos de Colombia 2026 y 2027 (Ley 51 de 1983). Verificar contra el calendario oficial.
insert into public.festivos (fecha, nombre) values
  ('2026-01-01','Año Nuevo'), ('2026-01-12','Reyes Magos'), ('2026-03-23','San José'),
  ('2026-04-02','Jueves Santo'), ('2026-04-03','Viernes Santo'), ('2026-05-01','Día del Trabajo'),
  ('2026-05-18','Ascensión del Señor'), ('2026-06-08','Corpus Christi'), ('2026-06-15','Sagrado Corazón'),
  ('2026-06-29','San Pedro y San Pablo'), ('2026-07-20','Independencia'), ('2026-08-07','Batalla de Boyacá'),
  ('2026-08-17','Asunción de la Virgen'), ('2026-10-12','Día de la Raza'), ('2026-11-02','Todos los Santos'),
  ('2026-11-16','Independencia de Cartagena'), ('2026-12-08','Inmaculada Concepción'), ('2026-12-25','Navidad'),
  ('2027-01-01','Año Nuevo'), ('2027-01-11','Reyes Magos'), ('2027-03-22','San José'),
  ('2027-03-25','Jueves Santo'), ('2027-03-26','Viernes Santo'), ('2027-05-01','Día del Trabajo'),
  ('2027-05-10','Ascensión del Señor'), ('2027-05-31','Corpus Christi'), ('2027-06-07','Sagrado Corazón'),
  ('2027-07-05','San Pedro y San Pablo'), ('2027-07-20','Independencia'), ('2027-08-07','Batalla de Boyacá'),
  ('2027-08-16','Asunción de la Virgen'), ('2027-10-18','Día de la Raza'), ('2027-11-01','Todos los Santos'),
  ('2027-11-15','Independencia de Cartagena'), ('2027-12-08','Inmaculada Concepción'), ('2027-12-25','Navidad')
on conflict do nothing;

insert into public.locaciones (id, nombre, direccion, tipo) values
  ('10000000-0000-0000-0000-000000000001','Planta principal (EJEMPLO)','Medellín','planta');

insert into public.areas (id, codigo, nombre, proceso) values
  ('11000000-0000-0000-0000-000000000001','COR','Corte','corte'),
  ('11000000-0000-0000-0000-000000000002','CONF','Confección','confeccion'),
  ('11000000-0000-0000-0000-000000000003','TER','Terminación','terminacion'),
  ('11000000-0000-0000-0000-000000000004','BOD','Bodega','corte'),
  ('11000000-0000-0000-0000-000000000005','ADM','Administración',null);

insert into public.cargos (id, nombre) values
  ('12000000-0000-0000-0000-000000000001','Operario(a) de confección'),
  ('12000000-0000-0000-0000-000000000002','Cortador(a)'),
  ('12000000-0000-0000-0000-000000000003','Supervisor(a) de módulo'),
  ('12000000-0000-0000-0000-000000000004','Auxiliar de bodega');

insert into public.jornadas (id, nombre, horas_semana) values
  ('13000000-0000-0000-0000-000000000001','Jornada ordinaria (EJEMPLO)', 44);

insert into public.turnos (id, nombre, hora_inicio, hora_fin, jornada_id) values
  ('14000000-0000-0000-0000-000000000001','Turno día (EJEMPLO)','06:00','15:30','13000000-0000-0000-0000-000000000001'),
  ('14000000-0000-0000-0000-000000000002','Turno tarde (EJEMPLO)','14:00','22:00','13000000-0000-0000-0000-000000000001');

insert into public.celulas (id, codigo, nombre, area_id, proceso, turno_id, locacion_id) values
  ('15000000-0000-0000-0000-000000000001','MOD1','Módulo 1 (EJEMPLO)','11000000-0000-0000-0000-000000000002','confeccion','14000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
  ('15000000-0000-0000-0000-000000000002','MOD2','Módulo 2 (EJEMPLO)','11000000-0000-0000-0000-000000000002','confeccion','14000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
  ('15000000-0000-0000-0000-000000000003','CORT','Corte (EJEMPLO)','11000000-0000-0000-0000-000000000001','corte','14000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');

-- 14 empleados ficticios
insert into public.empleados (id, codigo, documento, nombres, apellidos, cargo_id, area_id, celula_id, qr, fecha_ingreso)
select ('16000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'E' || lpad(n::text, 3, '0'),
       'EJ-' || (1000000 + n),
       nombres, apellidos || ' (EJEMPLO)',
       cargo::uuid, area::uuid, celula::uuid,
       'OPR-' || lpad(n::text, 4, '0'),
       date '2024-01-15' + n * 20
from (values
  (1,'Ana María','Restrepo','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (2,'Luz Dary','Gómez','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (3,'Yeimy','Cardona','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (4,'Marta Lucía','Henao','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (5,'Sandra','Muñoz','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (6,'Paula Andrea','Zapata','12000000-0000-0000-0000-000000000003','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (7,'Diana','Ospina','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002'),
  (8,'Gloria','Arango','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002'),
  (9,'Natalia','Vélez','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002'),
  (10,'Leidy','Correa','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002'),
  (11,'Jhon Fredy','Ramírez','12000000-0000-0000-0000-000000000002','11000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000003'),
  (12,'Carlos Mario','Úsuga','12000000-0000-0000-0000-000000000002','11000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000003'),
  (13,'Wilmar','Agudelo','12000000-0000-0000-0000-000000000004','11000000-0000-0000-0000-000000000004',null),
  (14,'Juliana','Betancur','12000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002')
) as t(n, nombres, apellidos, cargo, area, celula);

insert into public.tipos_maquina (id, codigo, nombre, precio_minuto) values
  ('17000000-0000-0000-0000-000000000001','PLA','Plana 1 aguja',   120),
  ('17000000-0000-0000-0000-000000000002','FIL','Fileteadora',     140),
  ('17000000-0000-0000-0000-000000000003','REC','Recubridora',     150),
  ('17000000-0000-0000-0000-000000000004','COL','Collarín',        150),
  ('17000000-0000-0000-0000-000000000005','MAN','Manual / mesa',    80);
-- (precios por minuto de EJEMPLO)

insert into public.maquinas (codigo, tipo_maquina_id, marca, celula_id)
select 'MAQ-' || lpad(n::text, 3, '0'), tipo::uuid, 'EJEMPLO', celula::uuid
from (values
  (1,'17000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000001'),
  (2,'17000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000001'),
  (3,'17000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (4,'17000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000001'),
  (5,'17000000-0000-0000-0000-000000000003','15000000-0000-0000-0000-000000000001'),
  (6,'17000000-0000-0000-0000-000000000004','15000000-0000-0000-0000-000000000001'),
  (7,'17000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000002'),
  (8,'17000000-0000-0000-0000-000000000002','15000000-0000-0000-0000-000000000002'),
  (9,'17000000-0000-0000-0000-000000000003','15000000-0000-0000-0000-000000000002')
) as t(n, tipo, celula);

insert into public.tallas (codigo, orden) values
  ('XS',1),('S',2),('M',3),('L',4),('XL',5),('XXL',6),('2',11),('4',12),('6',13),('8',14),('10',15),('12',16),('14',17),('16',18);

insert into public.curvas (id, nombre) values ('18000000-0000-0000-0000-000000000001','Adulto S-XL 1-2-2-1 (EJEMPLO)');
insert into public.curva_tallas (curva_id, talla_id, proporcion)
select '18000000-0000-0000-0000-000000000001', t.id, p
from (values ('S',1),('M',2),('L',2),('XL',1)) v(c, p) join public.tallas t on t.codigo = v.c;

insert into public.grupos_color (id, nombre) values
  ('19000000-0000-0000-0000-000000000001','Neutros'), ('19000000-0000-0000-0000-000000000002','Colores');
insert into public.colores (codigo, nombre, hex, grupo_color_id) values
  ('N','Negro','#1A1A1A','19000000-0000-0000-0000-000000000001'),
  ('B','Blanco','#FFFFFF','19000000-0000-0000-0000-000000000001'),
  ('GJ','Gris jaspe','#A7A9AC','19000000-0000-0000-0000-000000000001'),
  ('AZM','Azul marino','#1F2A44','19000000-0000-0000-0000-000000000002'),
  ('VB','Verde botella','#1E4D3A','19000000-0000-0000-0000-000000000002'),
  ('RJ','Rojo','#B3261E','19000000-0000-0000-0000-000000000002');

insert into public.bodegas (id, codigo, nombre, tipo, locacion_id) values
  ('1a000000-0000-0000-0000-000000000001','BT','Bodega de telas','telas','10000000-0000-0000-0000-000000000001'),
  ('1a000000-0000-0000-0000-000000000002','BI','Bodega de insumos','insumos','10000000-0000-0000-0000-000000000001'),
  ('1a000000-0000-0000-0000-000000000003','BC','Bodega de corte (piezas)','piezas_corte','10000000-0000-0000-0000-000000000001'),
  ('1a000000-0000-0000-0000-000000000004','PT','Producto terminado','producto_terminado','10000000-0000-0000-0000-000000000001'),
  ('1a000000-0000-0000-0000-000000000005','SG','Segundas','segundas','10000000-0000-0000-0000-000000000001');
insert into public.ubicaciones (bodega_id, codigo, descripcion) values
  ('1a000000-0000-0000-0000-000000000001','UB-BT-A01','Estantería A, nivel 1'),
  ('1a000000-0000-0000-0000-000000000001','UB-BT-A02','Estantería A, nivel 2'),
  ('1a000000-0000-0000-0000-000000000002','UB-BI-01','Insumos, estante 1');

insert into public.proveedores (nit, nombre, contacto) values
  ('900000001-1','Textiles Ejemplo S.A.S. (EJEMPLO)','Contacto de ejemplo'),
  ('900000002-2','Insumos Ejemplo Ltda. (EJEMPLO)','Contacto de ejemplo');
insert into public.satelites (nit, nombre, procesos, tarifa_minuto) values
  ('900000003-3','Taller Satélite Uno (EJEMPLO)','{confeccion}', 110),
  ('900000004-4','Estampados Ejemplo (EJEMPLO)','{estampacion}', null);
insert into public.canales (codigo, nombre) values
  ('directo','Venta directa'), ('shopify','Tienda en línea (Shopify)'), ('b2b','App B2B'), ('mayorista','Mayoristas');
insert into public.clientes (nit, nombre, canal_id, ciudad)
select '800000001-1','Cliente Mayorista (EJEMPLO)', id, 'Medellín' from public.canales where codigo = 'mayorista';

-- Estaciones (las tablets se asocian a una estación)
insert into public.estaciones (id, codigo, nombre, tipo, proceso, celula_id, bodega_id) values
  ('1b000000-0000-0000-0000-000000000001','ENT','Entrada de planta','entrada',null,null,null),
  ('1b000000-0000-0000-0000-000000000002','MOD1','Tablet Módulo 1','modulo','confeccion','15000000-0000-0000-0000-000000000001',null),
  ('1b000000-0000-0000-0000-000000000003','C01','Mesa de corte 1','mesa_corte','corte','15000000-0000-0000-0000-000000000003','1a000000-0000-0000-0000-000000000001'),
  ('1b000000-0000-0000-0000-000000000004','BOD','Bodega de telas','bodega',null,null,'1a000000-0000-0000-0000-000000000001');

-- =====================================================================
-- Fase 2 · Inventarios (EJEMPLO)
-- =====================================================================
insert into public.ubicaciones (bodega_id, codigo, descripcion) values
  ('1a000000-0000-0000-0000-000000000001','UB-BT-A03','Estantería A, nivel 3'),
  ('1a000000-0000-0000-0000-000000000001','UB-BT-B01','Estantería B, nivel 1'),
  ('1a000000-0000-0000-0000-000000000001','UB-BT-RET','Zona de retazos'),
  ('1a000000-0000-0000-0000-000000000002','UB-BI-02','Insumos, estante 2');

insert into public.materiales (id, codigo, tipo, categoria_id, nombre, unidad, composicion, ancho_nominal_cm, gramaje_gm2,
                               rendimiento_m_kg, maneja_rollos, proveedor_id, costo_estandar, stock_minimo)
select v.id::uuid, v.codigo, 'tela', c.id, v.nombre, v.unidad, v.comp, v.ancho, v.gramaje, v.rend, true,
       (select id from public.proveedores where nit = '900000001-1'), v.costo, v.minimo
from (values
  ('1c000000-0000-0000-0000-000000000001','TEL-JER30','Jersey 30/1 algodón peinado (EJEMPLO)','kg','100% algodón',180.0,160.0,3.45,32000,150),
  ('1c000000-0000-0000-0000-000000000002','TEL-FTE','French terry perchado (EJEMPLO)','kg','80% algodón 20% poliéster',185.0,280.0,1.95,38500,120),
  ('1c000000-0000-0000-0000-000000000003','TEL-RIB','Rib 1x1 (EJEMPLO)','kg','95% algodón 5% elastano',100.0,220.0,4.55,35000,40),
  ('1c000000-0000-0000-0000-000000000004','TEL-ANT','Antifluido plano (EJEMPLO)','m','100% poliéster',150.0,110.0,6.06,9800,200)
) as v(id, codigo, nombre, unidad, comp, ancho, gramaje, rend, costo, minimo)
join public.categorias_material c on c.nombre = case when v.codigo = 'TEL-ANT' then 'Tejido plano'
                                                    when v.codigo = 'TEL-RIB' then 'Rib y complementos' else 'Tejido de punto' end;

insert into public.materiales (id, codigo, tipo, categoria_id, nombre, unidad, maneja_color, proveedor_id, costo_estandar, stock_minimo)
select v.id::uuid, v.codigo, 'insumo', c.id, v.nombre, v.unidad, v.color, (select id from public.proveedores where nit = '900000002-2'), v.costo, v.minimo
from (values
  ('1c000000-0000-0000-0000-000000000011','INS-HIL40','Hilo poliéster 40/2 cono 5000 m (EJEMPLO)','cono',true,'Hilos',6500,30),
  ('1c000000-0000-0000-0000-000000000012','INS-MARQ','Marquilla tejida de marca (EJEMPLO)','und',false,'Marquillas y etiquetas',180,2000),
  ('1c000000-0000-0000-0000-000000000013','INS-CORD','Cordón plano 1 cm (EJEMPLO)','m',true,'Elásticos y cordones',650,300),
  ('1c000000-0000-0000-0000-000000000014','INS-BOLSA','Bolsa plástica con adhesivo 30x40 (EJEMPLO)','und',false,'Empaque',120,1000)
) as v(id, codigo, nombre, unidad, color, cat, costo, minimo)
join public.categorias_material c on c.nombre = v.cat;

insert into public.impresoras (id, nombre, modelo, conexion, ip, material) values
  ('1d000000-0000-0000-0000-000000000001','Zebra bodega (EJEMPLO)','ZD421t','tcp','192.168.1.50','transferencia'),
  ('1d000000-0000-0000-0000-000000000002','Zebra mesa de corte (EJEMPLO)','ZD421d','tcp','192.168.1.51','termico_directo');
update public.estaciones set impresora_id = '1d000000-0000-0000-0000-000000000001' where codigo = 'BOD';
update public.estaciones set impresora_id = '1d000000-0000-0000-0000-000000000002' where codigo = 'C01';

-- Una entrada confirmada: 6 rollos de jersey (2 lotes de negro, 1 de gris) + insumos
insert into public.recepciones (id, proveedor_id, bodega_id, factura_proveedor, fecha)
values ('1e000000-0000-0000-0000-000000000001', (select id from public.proveedores where nit = '900000001-1'),
        '1a000000-0000-0000-0000-000000000001', 'FE-EJEMPLO-001', current_date - 5);
insert into public.recepcion_lineas (recepcion_id, orden, material_id, color_id, cantidad, costo_unitario, lote_tintura, tono, ancho_real_cm, metros, kilos, ubicacion_id)
select '1e000000-0000-0000-0000-000000000001', n, '1c000000-0000-0000-0000-000000000001', (select id from public.colores where codigo = col),
       kilos, 32000, lote, tono, ancho, round(kilos * 3.45, 2), kilos, (select id from public.ubicaciones where codigo = ub)
from (values
  (1,'N','L-2410-N1','A',180.0,22.4,'UB-BT-A01'), (2,'N','L-2410-N1','A',179.5,21.8,'UB-BT-A01'),
  (3,'N','L-2410-N1','A',180.5,23.1,'UB-BT-A01'), (4,'N','L-2411-N2','B',177.0,22.0,'UB-BT-A02'),
  (5,'GJ','L-2412-G1','A',181.0,24.5,'UB-BT-A02'), (6,'GJ','L-2412-G1','A',181.0,23.9,'UB-BT-A02')
) as v(n, col, lote, tono, ancho, kilos, ub);
select count(*) from public.confirmar_recepcion('1e000000-0000-0000-0000-000000000001');

insert into public.recepciones (id, proveedor_id, bodega_id, factura_proveedor, fecha)
values ('1e000000-0000-0000-0000-000000000002', (select id from public.proveedores where nit = '900000002-2'),
        '1a000000-0000-0000-0000-000000000002', 'FE-EJEMPLO-002', current_date - 3);
insert into public.recepcion_lineas (recepcion_id, orden, material_id, color_id, cantidad, costo_unitario, ubicacion_id)
values
  ('1e000000-0000-0000-0000-000000000002', 1, '1c000000-0000-0000-0000-000000000011', (select id from public.colores where codigo = 'N'), 24, 6500, (select id from public.ubicaciones where codigo = 'UB-BI-01')),
  ('1e000000-0000-0000-0000-000000000002', 2, '1c000000-0000-0000-0000-000000000011', (select id from public.colores where codigo = 'GJ'), 12, 6500, (select id from public.ubicaciones where codigo = 'UB-BI-01')),
  ('1e000000-0000-0000-0000-000000000002', 3, '1c000000-0000-0000-0000-000000000012', null, 5000, 180, (select id from public.ubicaciones where codigo = 'UB-BI-02')),
  ('1e000000-0000-0000-0000-000000000002', 4, '1c000000-0000-0000-0000-000000000014', null, 600, 120, (select id from public.ubicaciones where codigo = 'UB-BI-02'));
select count(*) from public.confirmar_recepcion('1e000000-0000-0000-0000-000000000002');

-- =====================================================================
-- Fase 3 · Operaciones y ficha técnica (EJEMPLO)
-- =====================================================================
insert into public.valores_minuto (valor_minuto, indirecto_minuto, observacion)
values (195, 85, 'Valor minuto e indirectos de EJEMPLO: reemplazar por los reales de costos');

insert into public.tipos_maquina (codigo, nombre, precio_minuto) values ('PRE', 'Plancha / presilladora', 90) on conflict do nothing;

-- Lista maestra de operaciones para camiseta (SAM y valores de EJEMPLO)
insert into public.operaciones (codigo, nombre, familia_id, tipo_producto_id, proceso, sam, valor_destajo, tipo_maquina_id, parte, repeticiones, restrictiva, tipo)
select v.codigo, v.nombre, f.id, t.id, v.proceso, v.sam, v.valor, (select id from public.tipos_maquina where codigo = v.maq), v.parte, v.rep, v.restr, v.tipo
from (values
  ('CAM-010','Unir hombros',                 'confeccion', 0.3500,  70, 'FIL', 'Cuerpo', 2.0, false, 'normal'),
  ('CAM-020','Pegar cuello (rib)',           'confeccion', 0.5200, 105, 'FIL', 'Cuello', 1.0, true,  'normal'),
  ('CAM-030','Recubrir cuello',              'confeccion', 0.4800,  95, 'REC', 'Cuello', 1.0, false, 'normal'),
  ('CAM-040','Pegar tapa cuello',            'confeccion', 0.4100,  82, 'PLA', 'Cuello', 1.0, false, 'normal'),
  ('CAM-050','Pegar mangas',                 'confeccion', 0.4500,  90, 'FIL', 'Mangas', 2.0, true,  'normal'),
  ('CAM-060','Cerrar costados',              'confeccion', 0.6000, 120, 'FIL', 'Cuerpo', 2.0, false, 'normal'),
  ('CAM-070','Dobladillo mangas',            'confeccion', 0.3000,  60, 'REC', 'Mangas', 2.0, false, 'normal'),
  ('CAM-080','Dobladillo ruedo',             'confeccion', 0.4200,  84, 'REC', 'Cuerpo', 1.0, false, 'normal'),
  ('CAM-090','Pegar marquilla',              'confeccion', 0.2500,  50, 'PLA', 'Cuerpo', 1.0, false, 'normal'),
  ('CAM-100','Pulir y revisar',              'terminacion',0.4000,  70, 'MAN', null,     1.0, false, 'inspeccion'),
  ('CAM-110','Planchar',                     'terminacion',0.3500,  60, 'PRE', null,     1.0, false, 'normal'),
  ('CAM-120','Doblar y empacar',             'terminacion',0.3000,  50, 'MAN', null,     1.0, false, 'empaque')
) as v(codigo, nombre, proceso, sam, valor, maq, parte, rep, restr, tipo)
join public.familias_producto f on f.nombre = 'Camisetas'
join public.tipos_producto t on t.familia_id = f.id and t.nombre = 'Camiseta cuello redondo';

-- Referencia CAM-001 con su ficha v1 completa y aprobada
do $$
declare
  v_ficha uuid;
  v_cuerpo uuid; v_cuello uuid; v_mangas uuid;
  v_negro uuid; v_gris uuid;
  v_bom uuid;
  t record;
begin
  v_ficha := public.nueva_referencia('CAM-001', 'Camiseta básica cuello redondo (EJEMPLO)',
    (select id from public.familias_producto where nombre = 'Camisetas'),
    (select id from public.tipos_producto where nombre = 'Camiseta cuello redondo'));
  update public.ficha_versiones set composicion = '100% algodón', instrucciones_lavado = 'Lavar a máquina en agua fría. No usar blanqueador.',
         precio_objetivo = 38000, curva_id = '18000000-0000-0000-0000-000000000001', descripcion = 'Camiseta básica de jersey con cuello en rib'
   where id = v_ficha;
  insert into public.ficha_tallas (ficha_id, talla_id, orden) select v_ficha, id, orden from public.tallas where codigo in ('S','M','L','XL');
  insert into public.ficha_partes (ficha_id, nombre, orden) values (v_ficha, 'Cuerpo', 1) returning id into v_cuerpo;
  insert into public.ficha_partes (ficha_id, nombre, orden) values (v_ficha, 'Mangas', 2) returning id into v_mangas;
  insert into public.ficha_partes (ficha_id, nombre, orden, puede_cortarse_retazo) values (v_ficha, 'Cuello', 3, true) returning id into v_cuello;
  select id into v_negro from public.colores where codigo = 'N';
  select id into v_gris from public.colores where codigo = 'GJ';
  insert into public.ficha_combinaciones (ficha_id, codigo, nombre, orden) values (v_ficha, 'N', 'Negro entero', 1), (v_ficha, 'GJ', 'Gris jaspe con cuello negro', 2);
  insert into public.ficha_combinacion_partes (combinacion_id, parte_id, material_id, color_id)
  select c.id, p.id, case when p.nombre = 'Cuello' then '1c000000-0000-0000-0000-000000000003'::uuid else '1c000000-0000-0000-0000-000000000001'::uuid end,
         case when c.codigo = 'N' or p.nombre = 'Cuello' then v_negro else v_gris end
  from public.ficha_combinaciones c, public.ficha_partes p where c.ficha_id = v_ficha and p.ficha_id = v_ficha;

  -- Materiales: jersey para cuerpo y mangas (kg), rib para cuello, hilo, marquilla, bolsa
  for t in select * from (values
      ('1c000000-0000-0000-0000-000000000001', 'Cuerpo', 4.0, array[0.172, 0.185, 0.198, 0.213]),
      ('1c000000-0000-0000-0000-000000000001', 'Mangas', 4.0, array[0.048, 0.052, 0.056, 0.060]),
      ('1c000000-0000-0000-0000-000000000003', 'Cuello', 3.0, array[0.012, 0.013, 0.013, 0.014]),
      ('1c000000-0000-0000-0000-000000000011', 'Cuerpo', 0.0, array[0.030, 0.032, 0.034, 0.036]),
      ('1c000000-0000-0000-0000-000000000012', null,     0.0, array[1, 1, 1, 1]),
      ('1c000000-0000-0000-0000-000000000014', null,     0.0, array[1, 1, 1, 1])
    ) as x(material, parte, merma, consumos) loop
    insert into public.ficha_bom (ficha_id, material_id, parte_id, merma_pct, orden)
    values (v_ficha, t.material::uuid, (select id from public.ficha_partes where ficha_id = v_ficha and nombre = t.parte), t.merma,
            (select count(*) from public.ficha_bom where ficha_id = v_ficha) + 1)
    returning id into v_bom;
    insert into public.ficha_bom_consumos (bom_id, talla_id, consumo)
    select v_bom, ta.id, t.consumos[ta.orden - 1] from public.tallas ta where ta.codigo in ('S','M','L','XL');
  end loop;

  insert into public.ficha_medidas (ficha_id, punto_medida, orden) values (v_ficha, 'Contorno de pecho (1/2)', 1), (v_ficha, 'Largo total desde hombro', 2), (v_ficha, 'Largo de manga', 3);
  insert into public.ficha_medida_tallas (medida_id, talla_id, valor_cm, tolerancia_cm)
  select m.id, ta.id,
         case m.orden when 1 then 48 + (ta.orden - 2) * 3 when 2 then 68 + (ta.orden - 2) * 2 else 19 + (ta.orden - 2) * 1 end,
         case m.orden when 3 then 0.5 else 1 end
  from public.ficha_medidas m, public.tallas ta where m.ficha_id = v_ficha and ta.codigo in ('S','M','L','XL');

  insert into public.ficha_ruta (ficha_id, proceso, orden, modalidad, costo_externo_unidad) values
    (v_ficha, 'corte', 1, 'interno', 0), (v_ficha, 'estampacion', 2, 'satelite', 1200), (v_ficha, 'confeccion', 3, 'interno', 0),
    (v_ficha, 'terminacion', 4, 'interno', 0), (v_ficha, 'calidad', 5, 'interno', 0);
  insert into public.ficha_artes (ficha_id, proceso, parte_id, nombre, tecnica, tintas, ancho_cm, alto_cm, ubicacion)
  values (v_ficha, 'estampacion', v_cuerpo, 'Logo frontal (EJEMPLO)', 'Serigrafía plastisol', 'Blanco', 22, 8, 'Pecho, 8 cm bajo el cuello');

  insert into public.ficha_operaciones (ficha_id, secuencia, operacion_id, parte_id, es_contadora)
  select v_ficha, row_number() over (order by o.codigo) * 10, o.id,
         (select id from public.ficha_partes where ficha_id = v_ficha and nombre = o.parte), o.codigo = 'CAM-080'
  from public.operaciones o where o.codigo like 'CAM-%';

  perform public.enviar_ficha_aprobacion(v_ficha);
  perform public.decidir_ficha(v_ficha, 'diseno', true, 'EJEMPLO');
  perform public.decidir_ficha(v_ficha, 'produccion', true, 'EJEMPLO');
  perform public.decidir_ficha(v_ficha, 'costos', true, 'EJEMPLO');
end $$;

-- =====================================================================
-- Fase 4 · Pedido y OP de EJEMPLO
-- =====================================================================
insert into public.pedidos (id, cliente_id, canal_id, fecha_comprometida, observacion)
select '1f000000-0000-0000-0000-000000000001', c.id, c.canal_id, current_date + 25, 'Pedido de EJEMPLO'
from public.clientes c where c.nit = '800000001-1';
insert into public.pedido_lineas (pedido_id, referencia_id, combinacion_codigo, talla_id, cantidad)
select '1f000000-0000-0000-0000-000000000001', r.id, v.comb, t.id, v.n
from (values ('N','S',20),('N','M',40),('N','L',40),('N','XL',20),('GJ','S',10),('GJ','M',20),('GJ','L',20),('GJ','XL',10)) v(comb, talla, n)
join public.referencias r on r.codigo = 'CAM-001' join public.tallas t on t.codigo = v.talla;

-- OP desde el pedido: reserva lo que hay y pide lo que falta (el rib no tiene existencias)
select public.crear_op(
  (select id from public.referencias where codigo = 'CAM-001'),
  '{"N": {"S": 20, "M": 40, "L": 40, "XL": 20}, "GJ": {"S": 10, "M": 20, "L": 20, "XL": 10}}'::jsonb,
  current_date + 20, 2, 'OP de EJEMPLO desde el pedido',
  (select jsonb_agg(jsonb_build_object('pedido_linea_id', id, 'cantidad', cantidad)) from public.pedido_lineas where pedido_id = '1f000000-0000-0000-0000-000000000001'),
  current_date + 2, current_date + 25);

-- =====================================================================
-- Fase 5 · Trazos guardados de EJEMPLO (largos y unidades ficticios)
-- =====================================================================
insert into public.trazos (referencia_id, nombre, material_id, partes, tallas, secciones, ancho_cm, observacion)
select r.id, v.nombre, v.material::uuid, v.partes::text[], v.tallas::jsonb, v.secciones::jsonb, v.ancho, 'Trazo de EJEMPLO: medir el real en la mesa'
from public.referencias r, (values
  ('Cuerpo y mangas 1-2-2-1 (EJEMPLO)', '1c000000-0000-0000-0000-000000000001', '{Cuerpo,Mangas}', '["S","M","L","XL"]',
   '[{"letra":"A","largo_m":5.70,"unidades":{"S":1,"M":2,"L":2,"XL":1}}]', 178.0),
  ('Cuerpo y mangas por espigas (EJEMPLO)', '1c000000-0000-0000-0000-000000000001', '{Cuerpo,Mangas}', '["S","M","L","XL"]',
   '[{"letra":"A","largo_m":3.80,"unidades":{"M":2,"L":2}},{"letra":"B","largo_m":0.95,"unidades":{"S":1}},{"letra":"C","largo_m":1.00,"unidades":{"XL":1}}]', 178.0),
  ('Cuellos rib 4-8-8-4 (EJEMPLO)', '1c000000-0000-0000-0000-000000000003', '{Cuello}', '["S","M","L","XL"]',
   '[{"letra":"A","largo_m":0.60,"unidades":{"S":4,"M":8,"L":8,"XL":4}}]', 98.0)
) as v(nombre, material, partes, tallas, secciones, ancho)
where r.codigo = 'CAM-001';
