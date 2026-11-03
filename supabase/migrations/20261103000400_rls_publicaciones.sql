-- =====================================================================
-- Fase 1 · Migración 4: políticas RLS y publicaciones (PowerSync / Realtime)
-- Regla general:
--   * Leer maestros: cualquier usuario interno (no satélite).
--   * Escribir maestros: rol con permiso "editar" en el módulo dueño.
--   * Nadie borra maestros (se desactivan). Nadie edita eventos.
-- =====================================================================

-- Usuario interno = tiene al menos un rol distinto de 'satelite'
create or replace function public.es_interno() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from unnest(public.mis_roles()) r where r <> 'satelite')
$$;

-- Catálogos de solo lectura para todos los autenticados
create policy roles_leer   on public.roles   for select to authenticated using (true);
create policy modulos_leer on public.modulos for select to authenticated using (true);

create policy permisos_leer   on public.permisos_modulo for select to authenticated using (true);
create policy permisos_editar on public.permisos_modulo for all to authenticated
  using (public.puede('configuracion','editar')) with check (public.puede('configuracion','editar'));

create policy perfiles_leer on public.perfiles for select to authenticated
  using (id = auth.uid() or public.puede('configuracion','ver'));
create policy perfiles_insertar on public.perfiles for insert to authenticated
  with check (public.puede('configuracion','editar'));
create policy perfiles_actualizar on public.perfiles for update to authenticated
  using (public.puede('configuracion','editar')) with check (public.puede('configuracion','editar'));

create policy usuario_roles_leer on public.usuario_roles for select to authenticated
  using (usuario_id = auth.uid() or public.puede('configuracion','ver'));
create policy usuario_roles_editar on public.usuario_roles for all to authenticated
  using (public.puede('configuracion','editar')) with check (public.puede('configuracion','editar'));

create policy auditoria_leer on public.auditoria for select to authenticated using (public.es_gerencia());

-- Maestros: leer (internos) + insertar/actualizar (módulo dueño). Sin DELETE.
do $$
declare
  r record;
begin
  for r in select * from (values
      ('parametros','configuracion'), ('procesos','configuracion'), ('locaciones','configuracion'),
      ('areas','configuracion'), ('cargos','configuracion'), ('jornadas','configuracion'),
      ('turnos','configuracion'), ('festivos','configuracion'), ('celulas','configuracion'),
      ('programacion_turnos','configuracion'), ('tallas','configuracion'), ('curvas','configuracion'),
      ('curva_tallas','configuracion'), ('grupos_color','configuracion'), ('colores','configuracion'),
      ('unidades_medida','configuracion'), ('estaciones','configuracion'), ('dispositivos','configuracion'),
      ('consecutivos','configuracion'),
      ('empleados','personal'),
      ('tipos_maquina','mantenimiento'), ('maquinas','mantenimiento'),
      ('bodegas','inventario'), ('ubicaciones','inventario'),
      ('proveedores','compras'), ('satelites','procesos_externos'),
      ('canales','comercial'), ('clientes','comercial')
    ) as t(tabla, modulo)
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.es_interno())',
                   r.tabla || '_leer', r.tabla);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.puede(%L,''editar''))',
                   r.tabla || '_insertar', r.tabla, r.modulo);
    execute format('create policy %I on public.%I for update to authenticated using (public.puede(%L,''editar'')) with check (public.puede(%L,''editar''))',
                   r.tabla || '_actualizar', r.tabla, r.modulo, r.modulo);
  end loop;
end $$;

-- Catálogos que un satélite sí puede leer
create policy tallas_leer_satelite  on public.tallas  for select to authenticated using (true);
create policy colores_leer_satelite on public.colores for select to authenticated using (true);
create policy procesos_leer_todos   on public.procesos for select to authenticated using (true);

-- Satélite ve su propio registro
create policy satelites_leer_propio on public.satelites for select to authenticated
  using (id = (select satelite_id from public.perfiles where id = auth.uid()));

-- Nómina: solo gerencia y costos
create policy nomina_leer on public.empleados_nomina for select to authenticated
  using (public.tiene_rol(array['gerencia','costos']));
create policy nomina_editar on public.empleados_nomina for all to authenticated
  using (public.tiene_rol(array['gerencia','costos'])) with check (public.tiene_rol(array['gerencia','costos']));

-- Alertas: las ven y atienden los internos con acceso al tablero
create policy alertas_leer on public.alertas for select to authenticated using (public.puede('dashboard','ver'));
create policy alertas_atender on public.alertas for update to authenticated
  using (public.puede('dashboard','ver')) with check (public.puede('dashboard','ver'));

-- Adjuntos
create policy adjuntos_leer on public.adjuntos for select to authenticated using (public.es_interno());
create policy adjuntos_insertar on public.adjuntos for insert to authenticated with check (public.es_interno());

-- Eventos de asistencia: lectura para quien ve el módulo o para el dispositivo que los creó.
-- Nadie inserta directo: solo por ingerir_eventos().
create policy asistencia_leer on public.asistencia_marcas for select to authenticated
  using (public.puede('asistencia','ver')
         or dispositivo_id in (select id from public.dispositivos where usuario_id = auth.uid()));

create policy ingesta_leer on public.ingesta_eventos for select to authenticated
  using (public.puede('configuracion','ver')
         or dispositivo_id in (select id from public.dispositivos where usuario_id = auth.uid()));

-- ---------------------------------------------------------------------
-- Publicaciones
-- ---------------------------------------------------------------------
-- PowerSync lee los cambios por replicación lógica de esta publicación.
create publication powersync for table
  public.parametros, public.procesos, public.areas, public.turnos, public.festivos,
  public.celulas, public.empleados, public.tallas, public.colores, public.unidades_medida,
  public.estaciones, public.dispositivos, public.asistencia_marcas;

-- Realtime de Supabase (panel web y TV). Solo existe en Supabase.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.asistencia_marcas, public.alertas;
  end if;
end $$;
