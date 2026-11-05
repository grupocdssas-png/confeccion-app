// Procesa la cola de integraciones: toma trabajos, pide a la base el documento
// con los ids de Alegra, lo envía y registra el resultado. No conoce Supabase:
// recibe un "repositorio" (en producción, llamadas RPC con la clave de servicio;
// en las pruebas, uno en memoria).
import {
  ClienteAlegra,
  enviarIncentivo,
  ErrorIntegracion,
  pedidoAjustePt,
  pedidoAnularDespacho,
  pedidoCrearItem,
  pedidoDespacho,
  pedidoDocumentoSoporte,
  pedidoFacturaProveedor,
  pedidosAjusteConsumo,
} from './alegra.ts';
import { ClienteWhatsApp, cuerpoMensaje, textoMensaje } from './whatsapp.ts';

export interface Trabajo { id: string; sistema: 'alegra' | 'whatsapp'; tipo: string; clave: string; descripcion: string }
export interface Documento { id: string; tipo: string; sistema: string; faltan: string[]; datos: any }

export interface Repositorio {
  tareasProgramadas(): Promise<unknown>;
  liberarColgados(): Promise<number>;
  tomar(limite: number, sistemas: string[]): Promise<Trabajo[]>;
  datos(id: string): Promise<Documento>;
  terminar(id: string, ok: boolean, externo?: string | null, respuesta?: unknown, error?: string | null, bloqueado?: boolean): Promise<void>;
  ajuste(clave: string): Promise<string | null>;
}

export interface Opciones {
  alegra: ClienteAlegra | null; // null = sin credenciales
  whatsapp: ClienteWhatsApp | null; // null = sin credenciales (se simula)
  horaBogota: number;
  limite?: number;
}

export interface Resumen { tomados: number; enviados: number; simulados: number; fallidos: number; bloqueados: number; tareas?: unknown; detalle: string[] }

export async function procesarCola(repo: Repositorio, op: Opciones): Promise<Resumen> {
  const res: Resumen = { tomados: 0, enviados: 0, simulados: 0, fallidos: 0, bloqueados: 0, detalle: [] };
  res.tareas = await repo.tareasProgramadas();
  await repo.liberarColgados();

  const alegraActivo = (await repo.ajuste('alegra_activo')) === 'true' && op.alegra != null;
  const desde = Number((await repo.ajuste('whatsapp_hora_inicio')) ?? 6);
  const hasta = Number((await repo.ajuste('whatsapp_hora_fin')) ?? 21);
  const enHorario = op.horaBogota >= desde && op.horaBogota < hasta;
  const sistemas = [...(alegraActivo ? ['alegra'] : []), ...(enHorario ? ['whatsapp'] : [])];
  if (sistemas.length === 0) return res;
  const whatsappReal = (await repo.ajuste('whatsapp_activo')) === 'true' && op.whatsapp != null;

  const trabajos = await repo.tomar(op.limite ?? 25, sistemas);
  res.tomados = trabajos.length;
  for (const t of trabajos) {
    try {
      const doc = await repo.datos(t.id);
      if (doc.faltan.length > 0) {
        await repo.terminar(t.id, false, null, null, `Falta enlazar: ${doc.faltan.join(', ')}`, true);
        res.bloqueados++;
        res.detalle.push(`${t.descripcion}: falta enlazar ${doc.faltan.join(', ')}`);
        continue;
      }
      const r = await enviar(doc, op.alegra!, whatsappReal ? op.whatsapp : null);
      await repo.terminar(t.id, true, r.externo, r.respuesta, null, false);
      if (r.simulado) res.simulados++;
      else res.enviados++;
    } catch (e) {
      const err = e instanceof ErrorIntegracion ? e : new ErrorIntegracion(String(e));
      const bloqueado = !err.reintentable;
      await repo.terminar(t.id, false, null, err.respuesta ?? null, err.message, bloqueado);
      if (bloqueado) res.bloqueados++;
      else res.fallidos++;
      res.detalle.push(`${t.descripcion}: ${err.message}`);
    }
  }
  return res;
}

async function enviar(doc: Documento, alegra: ClienteAlegra, whatsapp: ClienteWhatsApp | null): Promise<{ externo: string | null; respuesta: unknown; simulado?: boolean }> {
  const d = doc.datos;
  switch (doc.tipo) {
    case 'crear_item': {
      const r = await alegra.pedir<any>(pedidoCrearItem(d));
      return { externo: String(r?.id ?? ''), respuesta: { alegra: r } };
    }
    case 'ajuste_pt': {
      const r = await alegra.pedir<any>(pedidoAjustePt(d));
      return { externo: String(r?.id ?? ''), respuesta: { alegra: r } };
    }
    case 'despacho': {
      const p = pedidoDespacho(d);
      const r = await alegra.pedir<any>(p);
      return { externo: String(r?.id ?? ''), respuesta: { documento: p.ruta === '/remissions' ? 'remision' : 'traslado', cuerpo: p.cuerpo, alegra: r } };
    }
    case 'anular_despacho': {
      const p = pedidoAnularDespacho(d);
      if (!p) return { externo: null, respuesta: { nota: 'El despacho nunca llegó a Alegra: no hay nada que anular' } };
      const r = await alegra.pedir<any>(p);
      return { externo: String(r?.id ?? d.original?.externo_id ?? ''), respuesta: { alegra: r } };
    }
    case 'factura_proveedor': {
      const r = await alegra.pedir<any>(pedidoFacturaProveedor(d));
      return { externo: String(r?.id ?? ''), respuesta: { alegra: r } };
    }
    case 'ajuste_consumo': {
      const ids: string[] = [];
      for (const p of pedidosAjusteConsumo(d)) ids.push(String((await alegra.pedir<any>(p))?.id ?? ''));
      return { externo: ids.join(','), respuesta: { ajustes: ids } };
    }
    case 'documento_soporte': {
      const r = await alegra.pedir<any>(pedidoDocumentoSoporte(d));
      return { externo: String(r?.id ?? ''), respuesta: { alegra: r } };
    }
    case 'concepto_nomina': {
      const r = await enviarIncentivo(alegra, d);
      return { externo: r.externo, respuesta: r.respuesta };
    }
    case 'mensaje': {
      if (!whatsapp) {
        // simulado: queda registrado el texto que se habría enviado
        cuerpoMensaje(d); // valida la plantilla
        return { externo: 'simulado', respuesta: { simulado: true, para: d.telefono, texto: textoMensaje(d.plantilla, d.parametros) }, simulado: true };
      }
      const r = await whatsapp.enviar(d);
      return { externo: r.id, respuesta: { texto: textoMensaje(d.plantilla, d.parametros), whatsapp: r.respuesta } };
    }
  }
  throw new ErrorIntegracion(`Tipo de trabajo desconocido: ${doc.tipo}`, 0, false);
}
