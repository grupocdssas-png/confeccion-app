// Crea los usuarios de EJEMPLO en Supabase Auth y les asigna perfil, roles y estación.
// Uso (Node 18+, sin dependencias):
//   SUPABASE_URL=https://xxxx.supabase.co SUPABASE_SERVICE_ROLE_KEY=... node herramientas/crear_usuarios_demo.mjs
// Opcional: CLAVE_DEMO=... (si no se da, se genera una y se imprime).
// La service_role key es secreta: úsela solo en su computador, nunca en la app.
import { randomBytes } from 'node:crypto';

const url = process.env.SUPABASE_URL?.replace(/\/$/, '');
const llave = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !llave) {
  console.error('Defina SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const clave = process.env.CLAVE_DEMO ?? `Planta-${randomBytes(4).toString('hex')}`;
const h = { apikey: llave, Authorization: `Bearer ${llave}`, 'Content-Type': 'application/json' };

const usuarios = [
  { correo: 'gerencia@ejemplo.co', nombre: 'Gerencia (EJEMPLO)', roles: ['gerencia'] },
  { correo: 'jefe.produccion@ejemplo.co', nombre: 'Jefe de producción (EJEMPLO)', roles: ['jefe_produccion'] },
  { correo: 'bodega@ejemplo.co', nombre: 'Bodega (EJEMPLO)', roles: ['bodega'] },
  { correo: 'costos@ejemplo.co', nombre: 'Costos (EJEMPLO)', roles: ['costos'] },
  { correo: 'diseno@ejemplo.co', nombre: 'Diseño (EJEMPLO)', roles: ['diseno'] },
  { correo: 'compras@ejemplo.co', nombre: 'Compras (EJEMPLO)', roles: ['compras'] },
  { correo: 'comercial@ejemplo.co', nombre: 'Comercial (EJEMPLO)', roles: ['comercial'] },
  { correo: 'tablet-ent@planta.local', nombre: 'Tablet entrada', roles: ['dispositivo'], estacion: 'ENT', tipo: 'tablet' },
  { correo: 'tablet-mod1@planta.local', nombre: 'Tablet Módulo 1', roles: ['dispositivo'], estacion: 'MOD1', tipo: 'tablet' },
  { correo: 'celular-bodega@planta.local', nombre: 'Celular bodega', roles: ['dispositivo'], estacion: 'BOD', tipo: 'celular' },
];

async function api(ruta, opciones = {}) {
  const r = await fetch(`${url}${ruta}`, { ...opciones, headers: { ...h, ...(opciones.headers ?? {}) } });
  const texto = await r.text();
  if (!r.ok) throw new Error(`${opciones.method ?? 'GET'} ${ruta} → ${r.status}: ${texto}`);
  return texto ? JSON.parse(texto) : null;
}

async function buscarUsuario(correo) {
  for (let pagina = 1; pagina < 50; pagina++) {
    const r = await api(`/auth/v1/admin/users?page=${pagina}&per_page=100`);
    const u = r.users.find((x) => x.email === correo);
    if (u) return u;
    if (r.users.length < 100) return null;
  }
  return null;
}

const upsert = (tabla, filas, conflicto) =>
  api(`/rest/v1/${tabla}?on_conflict=${conflicto}`, {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=representation' },
    body: JSON.stringify(filas),
  });

for (const u of usuarios) {
  let usuario = await buscarUsuario(u.correo);
  if (usuario) {
    await api(`/auth/v1/admin/users/${usuario.id}`, { method: 'PUT', body: JSON.stringify({ password: clave }) });
  } else {
    usuario = await api('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({ email: u.correo, password: clave, email_confirm: true }),
    });
  }
  await upsert('perfiles', [{ id: usuario.id, nombre: u.nombre, correo: u.correo, es_dispositivo: !!u.estacion }], 'id');
  for (const rol of u.roles) {
    const existe = await api(`/rest/v1/usuario_roles?usuario_id=eq.${usuario.id}&rol=eq.${rol}&select=id`);
    if (!existe.length) await upsert('usuario_roles', [{ usuario_id: usuario.id, rol }], 'id');
  }
  if (u.estacion) {
    const [est] = await api(`/rest/v1/estaciones?codigo=eq.${u.estacion}&select=id`);
    await upsert('dispositivos', [{ usuario_id: usuario.id, estacion_id: est.id, nombre: u.nombre, tipo: u.tipo }], 'usuario_id');
  }
  console.log(`✓ ${u.correo.padEnd(30)} ${u.roles.join(', ')}${u.estacion ? ` · estación ${u.estacion}` : ''}`);
}
console.log(`\nContraseña de todos los usuarios de ejemplo: ${clave}`);
