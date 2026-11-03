-- =====================================================================
-- Fase 1 · Migración 5: datos de sistema (NO son de ejemplo)
-- Roles, módulos, permisos por defecto, procesos, unidades, parámetros.
-- =====================================================================

insert into public.roles (codigo, nombre, solo_planta, orden) values
  ('gerencia','Gerencia',false,1), ('jefe_produccion','Jefe de producción',false,2),
  ('diseno','Diseño',false,3), ('corte','Corte',false,4), ('estampacion','Estampación',false,5),
  ('bordado','Bordado',false,6), ('tejidos','Tejidos',false,7),
  ('confeccion','Confección (supervisor de módulo)',false,8), ('terminacion','Terminación',false,9),
  ('calidad','Calidad',false,10), ('bodega','Bodega / Inventarios',false,11), ('compras','Compras',false,12),
  ('costos','Costos',false,13), ('comercial','Comercial',false,14), ('mecanico','Mecánico',false,15),
  ('operario','Operario de planta',true,16), ('satelite','Satélite',false,17),
  ('dispositivo','Dispositivo de planta (cuenta técnica)',true,18);

insert into public.modulos (codigo, nombre, grupo, icono, ruta, fase, orden) values
  ('dashboard','Dashboard','General','dashboard','/',10,1),
  ('pedidos','Pedidos','Producción','receipt','/pedidos',4,10),
  ('op','Órdenes de producción','Producción','assignment','/op',4,11),
  ('programacion','Programación','Producción','calendar','/programacion',7,12),
  ('ficha_tecnica','Fichas técnicas','Diseño','design','/fichas',3,20),
  ('operaciones','Lista de operaciones','Diseño','list','/operaciones',3,21),
  ('corte','Corte','Producción','cut','/corte',5,13),
  ('inventario','Inventarios','Inventarios','inventory','/inventario',2,30),
  ('compras','Compras','Inventarios','cart','/compras',4,31),
  ('balanceo','Balanceo','Piso','balance','/balanceo',7,40),
  ('eficiencia','Eficiencia e incentivos','Piso','speed','/eficiencia',8,41),
  ('tv','Tableros TV','Piso','tv','/tv',8,42),
  ('estudio_tiempos','Estudio de tiempos','Piso','timer','/estudio-tiempos',12,43),
  ('procesos_externos','Procesos externos y satélites','Producción','local_shipping','/externos',6,14),
  ('calidad','Calidad','Producción','verified','/calidad',9,15),
  ('terminacion','Terminación','Producción','checkroom','/terminacion',9,16),
  ('costos','Costos','Administración','payments','/costos',10,50),
  ('trazabilidad','Trazabilidad','Administración','search','/trazabilidad',10,51),
  ('informes','Informes','Administración','bar_chart','/informes',10,52),
  ('mantenimiento','Mantenimiento','Piso','build','/mantenimiento',12,44),
  ('asistencia','Asistencia','Piso','badge','/asistencia',1,45),
  ('personal','Personal','Administración','people','/personal',1,53),
  ('comercial','Clientes y canales','Administración','storefront','/comercial',4,54),
  ('mensajes','Mensajes','General','chat','/mensajes',12,2),
  ('configuracion','Configuración','Administración','settings','/configuracion',1,60);

-- Permisos por defecto (editables desde Configuración). Gerencia ve y edita todo sin filas.
insert into public.permisos_modulo (rol, modulo, puede_ver, puede_editar, puede_aprobar)
select r, m, true, e, a from (values
  ('jefe_produccion','dashboard',false,false), ('jefe_produccion','pedidos',true,false), ('jefe_produccion','op',true,true),
  ('jefe_produccion','programacion',true,true), ('jefe_produccion','ficha_tecnica',false,true), ('jefe_produccion','operaciones',true,true),
  ('jefe_produccion','corte',true,true), ('jefe_produccion','inventario',false,false), ('jefe_produccion','balanceo',true,true),
  ('jefe_produccion','eficiencia',true,true), ('jefe_produccion','tv',true,false), ('jefe_produccion','procesos_externos',true,true),
  ('jefe_produccion','calidad',true,false), ('jefe_produccion','terminacion',true,false), ('jefe_produccion','trazabilidad',false,false),
  ('jefe_produccion','informes',false,false), ('jefe_produccion','asistencia',true,true), ('jefe_produccion','personal',true,false),
  ('jefe_produccion','mantenimiento',false,false), ('jefe_produccion','estudio_tiempos',true,true), ('jefe_produccion','mensajes',true,false),
  ('diseno','dashboard',false,false), ('diseno','ficha_tecnica',true,false), ('diseno','operaciones',true,false), ('diseno','inventario',false,false),
  ('diseno','mensajes',true,false),
  ('corte','dashboard',false,false), ('corte','corte',true,true), ('corte','op',false,false), ('corte','inventario',false,false),
  ('corte','trazabilidad',false,false), ('corte','mensajes',true,false),
  ('estampacion','dashboard',false,false), ('estampacion','procesos_externos',true,false), ('estampacion','op',false,false), ('estampacion','mensajes',true,false),
  ('bordado','dashboard',false,false), ('bordado','procesos_externos',true,false), ('bordado','op',false,false), ('bordado','mensajes',true,false),
  ('tejidos','dashboard',false,false), ('tejidos','procesos_externos',true,false), ('tejidos','op',false,false), ('tejidos','mensajes',true,false),
  ('confeccion','dashboard',false,false), ('confeccion','op',false,false), ('confeccion','balanceo',true,false), ('confeccion','eficiencia',false,false),
  ('confeccion','tv',false,false), ('confeccion','asistencia',true,false), ('confeccion','procesos_externos',true,false), ('confeccion','mensajes',true,false),
  ('terminacion','dashboard',false,false), ('terminacion','terminacion',true,false), ('terminacion','op',false,false), ('terminacion','mensajes',true,false),
  ('calidad','dashboard',false,false), ('calidad','calidad',true,true), ('calidad','op',false,false), ('calidad','trazabilidad',false,false),
  ('calidad','ficha_tecnica',false,false), ('calidad','mensajes',true,false),
  ('bodega','dashboard',false,false), ('bodega','inventario',true,false), ('bodega','compras',false,false), ('bodega','trazabilidad',false,false),
  ('bodega','mensajes',true,false),
  ('compras','dashboard',false,false), ('compras','compras',true,true), ('compras','inventario',false,false), ('compras','mensajes',true,false),
  ('costos','dashboard',false,false), ('costos','costos',true,true), ('costos','ficha_tecnica',false,true), ('costos','op',false,false),
  ('costos','inventario',false,true), ('costos','eficiencia',false,false), ('costos','informes',false,false), ('costos','personal',false,false),
  ('comercial','dashboard',false,false), ('comercial','pedidos',true,false), ('comercial','comercial',true,false), ('comercial','op',false,false),
  ('mecanico','mantenimiento',true,false), ('mecanico','mensajes',true,false),
  ('satelite','procesos_externos',false,false)
) as t(r, m, e, a);

insert into public.procesos (codigo, nombre, color_hex, orden) values
  ('diseno','Diseño','#6B4FA0',1), ('corte','Corte','#1F5FA8',2), ('estampacion','Estampación','#B4521C',3),
  ('bordado','Bordado','#A3306B',4), ('tejidos','Tejidos','#5C6B2E',5), ('confeccion','Confección','#3F4A5A',6),
  ('terminacion','Terminación','#2F7A6A',7), ('calidad','Calidad','#4E7A1F',8);

insert into public.unidades_medida (codigo, nombre, decimales) values
  ('m','Metros',2), ('kg','Kilos',3), ('und','Unidades',0), ('g','Gramos',1),
  ('cono','Conos',0), ('rollo','Rollos',0), ('ml','Mililitros',0), ('par','Pares',0);

insert into public.parametros (clave, valor, descripcion) values
  ('tolerancia_ancho_cm', '2', 'Diferencia máxima de ancho entre rollos de un mismo color en una OP (cm)'),
  ('tolerancia_desviacion_corte_pct', '5', 'Desviación de consumo en corte que dispara alerta (±%)'),
  ('max_prendas_paquete', '20', 'Máximo de prendas por paquete'),
  ('unidades_por_marcacion', '1', 'Unidades que suma cada toque en la tablet del operario'),
  ('horas_aviso_pendientes', '8', 'Horas tras las cuales un evento sin sincronizar genera aviso'),
  ('tolerancia_reloj_s', '300', 'Desfase máximo aceptado entre la hora de la tablet y la del servidor (segundos)'),
  ('zona_horaria', '"America/Bogota"', 'Zona horaria de la planta'),
  ('moneda', '"COP"', 'Moneda');

insert into public.consecutivos (tipo, prefijo) values
  ('OP','OP'), ('PED','PED'), ('REM','REM'), ('OC','OC'), ('REC','REC'), ('AJU','AJU'), ('REQ','REQ'), ('CON','CON');
