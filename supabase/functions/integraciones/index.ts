// Edge Function "integraciones": procesa la cola hacia Alegra y WhatsApp y
// atiende consultas de la pantalla de Integraciones (bodegas, productos,
// nómina). Las claves viven en los secretos de Supabase:
//   ALEGRA_USUARIO, ALEGRA_TOKEN, [ALEGRA_URL], [ALEGRA_NOMINA_URL]
//   WHATSAPP_TOKEN, WHATSAPP_TELEFONO_ID, [WHATSAPP_URL]
//   INTEGRACIONES_CLAVE  (la usa la tarea programada que llama esta función)
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.45.4';
import { ClienteAlegra, leerNomina } from '../_compartido/alegra.ts';
import { procesarCola, type Repositorio } from '../_compartido/procesador.ts';
import { ClienteWhatsApp } from '../_compartido/whatsapp.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-clave',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

export function crearAlegra(): ClienteAlegra | null {
  if (!env('ALEGRA_USUARIO') || !env('ALEGRA_TOKEN')) return null;
  return new ClienteAlegra({
    base: env('ALEGRA_URL') || 'https://api.alegra.com/api/v1',
    baseNomina: env('ALEGRA_NOMINA_URL') || 'https://api.alegra.com/payroll/api/v1',
    usuario: env('ALEGRA_USUARIO'),
    token: env('ALEGRA_TOKEN'),
  });
}

export function crearWhatsApp(): ClienteWhatsApp | null {
  if (!env('WHATSAPP_TOKEN') || !env('WHATSAPP_TELEFONO_ID')) return null;
  return new ClienteWhatsApp({ base: env('WHATSAPP_URL') || 'https://graph.facebook.com/v21.0', telefonoId: env('WHATSAPP_TELEFONO_ID'), token: env('WHATSAPP_TOKEN') });
}

export function repositorioSupabase(db: SupabaseClient): Repositorio {
  const rpc = async (f: string, p: Record<string, unknown> = {}) => {
    const { data, error } = await db.rpc(f, p);
    if (error) throw new Error(`${f}: ${error.message}`);
    return data;
  };
  return {
    tareasProgramadas: () => rpc('tareas_programadas'),
    liberarColgados: () => rpc('liberar_trabajos_colgados'),
    tomar: (limite, sistemas) => rpc('tomar_trabajos', { p_limite: limite, p_sistemas: sistemas }),
    datos: (id) => rpc('datos_trabajo', { p_id: id }),
    terminar: async (id, ok, externo, respuesta, error, bloqueado) => {
      await rpc('terminar_trabajo', { p_id: id, p_ok: ok, p_externo: externo ?? null, p_respuesta: respuesta ?? null, p_error: error ?? null, p_bloqueado: bloqueado ?? false });
    },
    ajuste: (clave) => rpc('ajuste_integracion', { p_clave: clave }),
  };
}

export const horaBogota = (d = new Date()) => Number(new Intl.DateTimeFormat('en-US', { timeZone: 'America/Bogota', hour: 'numeric', hourCycle: 'h23' }).format(d));

/** Quién llama: la tarea programada (clave) o un usuario con acceso a Integraciones. */
async function autorizado(req: Request, servicio: SupabaseClient): Promise<{ ok: boolean; editar: boolean }> {
  const clave = req.headers.get('x-clave');
  if (clave && env('INTEGRACIONES_CLAVE') && clave === env('INTEGRACIONES_CLAVE')) return { ok: true, editar: true };
  const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!jwt) return { ok: false, editar: false };
  const { data } = await servicio.auth.getUser(jwt);
  if (!data.user) return { ok: false, editar: false };
  const usuario = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const ver = (await usuario.rpc('puede', { p_modulo: 'integraciones', p_accion: 'ver' })).data === true;
  const editar = (await usuario.rpc('puede', { p_modulo: 'integraciones', p_accion: 'editar' })).data === true;
  return { ok: ver, editar };
}

const lista = (r: any) => (Array.isArray(r) ? r : r?.data ?? []);

if (import.meta.main) {
  Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
    const servicio = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
    const quien = await autorizado(req, servicio);
    if (!quien.ok) return responder({ error: 'No autorizado' }, 401);
    const cuerpo = await req.json().catch(() => ({}));
    const accion = cuerpo.accion ?? 'procesar';
    const alegra = crearAlegra();
    try {
      switch (accion) {
        case 'procesar':
          return responder(await procesarCola(repositorioSupabase(servicio), { alegra, whatsapp: crearWhatsApp(), horaBogota: horaBogota() }));
        case 'estado':
          return responder({ alegra: alegra != null, whatsapp: crearWhatsApp() != null, programada: env('INTEGRACIONES_CLAVE') !== '' });
        case 'probar': {
          if (!alegra) return responder({ ok: false, mensaje: 'Faltan ALEGRA_USUARIO y ALEGRA_TOKEN en los secretos de Supabase' });
          const b = lista(await alegra.pedir({ metodo: 'GET', ruta: '/warehouses' }));
          return responder({ ok: true, mensaje: `Conectado: ${b.length} bodegas en Alegra` });
        }
        case 'catalogos': {
          if (!alegra) return responder({ error: 'Sin credenciales de Alegra' }, 400);
          const [bodegas, listas, impuestos, categorias, numeraciones] = await Promise.all([
            alegra.pedir({ metodo: 'GET', ruta: '/warehouses' }),
            alegra.pedir({ metodo: 'GET', ruta: '/price-lists' }),
            alegra.pedir({ metodo: 'GET', ruta: '/taxes' }),
            alegra.pedir({ metodo: 'GET', ruta: '/item-categories' }),
            alegra.pedir({ metodo: 'GET', ruta: '/number-templates?documentType=supportDocument' }).catch(() => []),
          ]);
          const simple = (xs: any[]) => xs.map((x) => ({ id: String(x.id), nombre: String(x.name ?? x.prefix ?? x.id) }));
          return responder({ bodegas: simple(lista(bodegas)), listas: simple(lista(listas)), impuestos: lista(impuestos).map((x: any) => ({ id: String(x.id), nombre: `${x.name} ${x.percentage ?? ''}%` })),
            categorias: simple(lista(categorias)), numeraciones: simple(lista(numeraciones)) });
        }
        case 'buscar_items': {
          if (!alegra) return responder({ error: 'Sin credenciales de Alegra' }, 400);
          const q = encodeURIComponent(String(cuerpo.texto ?? ''));
          const r = lista(await alegra.pedir({ metodo: 'GET', ruta: `/items?query=${q}&limit=30&status=active` }));
          return responder(r.map((x: any) => ({ id: String(x.id), nombre: x.name, referencia: x.reference?.reference ?? x.reference ?? null, precio: x.price?.[0]?.price ?? null })));
        }
        case 'buscar_contactos': {
          if (!alegra) return responder({ error: 'Sin credenciales de Alegra' }, 400);
          const q = encodeURIComponent(String(cuerpo.texto ?? ''));
          const r = lista(await alegra.pedir({ metodo: 'GET', ruta: `/contacts?query=${q}&limit=30` }));
          return responder(r.map((x: any) => ({ id: String(x.id), nombre: x.name, identificacion: x.identification ?? x.identificationObject?.number ?? null })));
        }
        case 'importar_nomina': {
          if (!quien.editar) return responder({ error: 'Sin permiso' }, 403);
          if (!alegra) return responder({ error: 'Sin credenciales de Alegra' }, 400);
          const filas = await leerNomina(alegra, cuerpo.desde, cuerpo.hasta);
          const { data, error } = await servicio.rpc('registrar_costos_nomina', { p_desde: cuerpo.desde, p_hasta: cuerpo.hasta, p_filas: filas });
          if (error) throw new Error(error.message);
          return responder(data);
        }
        case 'pagos_satelites': {
          // documentos soporte pagados en Alegra → cuentas pagadas en la app
          if (!alegra) return responder({ error: 'Sin credenciales de Alegra' }, 400);
          const { data: pend } = await servicio.from('integraciones_cola').select('entidad_id, externo_id').eq('tipo', 'documento_soporte').eq('estado', 'enviado');
          let pagadas = 0;
          for (const p of pend ?? []) {
            const b: any = await alegra.pedir({ metodo: 'GET', ruta: `/bills/${p.externo_id}` }).catch(() => null);
            if (b && (b.status === 'closed' || b.status === 'paid' || Number(b.balance) === 0)) {
              const { data } = await servicio.rpc('marcar_cuenta_pagada_alegra', { p_cuenta: p.entidad_id, p_referencia: `Alegra ${b.numberTemplate?.fullNumber ?? b.id}` });
              if (data) pagadas++;
            }
          }
          return responder({ pagadas });
        }
      }
      return responder({ error: `Acción desconocida: ${accion}` }, 400);
    } catch (e) {
      return responder({ error: String(e instanceof Error ? e.message : e) }, 500);
    }
  });
}
