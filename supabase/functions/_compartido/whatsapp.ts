// WhatsApp Cloud API (Meta). Los mensajes que inicia la empresa deben usar
// plantillas aprobadas por Meta; cada plantilla recibe sus textos en orden.
import { ErrorIntegracion } from './alegra.ts';

export interface ConfigWhatsApp {
  base: string; // https://graph.facebook.com/v21.0
  telefonoId: string; // id del número de WhatsApp Business
  token: string;
}

/** Plantillas que hay que crear y aprobar en Meta (nombre → cuerpo con sus variables). */
export const plantillas: Record<string, string> = {
  alerta_produccion: 'Alerta de producción: {{1}}',
  remision_enviada: 'Hola. Le enviamos la remisión {{1}} con {{2}} prendas para {{3}}. Por favor devuélvala a más tardar el {{4}}.',
  remision_vencida: 'Recordatorio: la remisión {{1}} debía devolverse el {{2}}. Por favor avísenos cuándo la entrega.',
  pago_satelite: 'Le informamos que la cuenta {{1}} por ${{2}} quedó pagada. Gracias.',
};

export function normalizarTelefono(t: string): string {
  const d = t.replace(/[^0-9]/g, '');
  return d.length === 10 && d.startsWith('3') ? `57${d}` : d; // celular colombiano sin indicativo
}

export function cuerpoMensaje(d: { telefono: string; plantilla: string; parametros?: unknown[]; idioma?: string }) {
  if (!plantillas[d.plantilla]) throw new ErrorIntegracion(`Plantilla desconocida: ${d.plantilla}`, 0, false);
  return {
    messaging_product: 'whatsapp',
    to: normalizarTelefono(d.telefono),
    type: 'template',
    template: {
      name: d.plantilla,
      language: { code: d.idioma ?? 'es' },
      components: [{ type: 'body', parameters: (d.parametros ?? []).map((p) => ({ type: 'text', text: String(p) })) }],
    },
  };
}

/** Texto como se leerá (para el simulador y la pantalla de integraciones). */
export function textoMensaje(plantilla: string, parametros: unknown[] = []): string {
  return (plantillas[plantilla] ?? plantilla).replace(/\{\{(\d+)\}\}/g, (_, i) => String(parametros[Number(i) - 1] ?? ''));
}

export class ClienteWhatsApp {
  constructor(readonly cfg: ConfigWhatsApp, readonly fetchFn: typeof fetch = fetch) {}

  async enviar(d: { telefono: string; plantilla: string; parametros?: unknown[]; idioma?: string }): Promise<{ id: string; respuesta: unknown }> {
    let r: Response;
    try {
      r = await this.fetchFn(`${this.cfg.base}/${this.cfg.telefonoId}/messages`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.cfg.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(cuerpoMensaje(d)),
      });
    } catch (e) {
      throw new ErrorIntegracion(`Sin conexión con WhatsApp: ${e}`);
    }
    const json: any = await r.json().catch(() => null);
    if (!r.ok) {
      throw new ErrorIntegracion(`WhatsApp respondió ${r.status}: ${json?.error?.message ?? r.statusText}`, r.status, r.status >= 500 || r.status === 429, json);
    }
    return { id: String(json?.messages?.[0]?.id ?? ''), respuesta: json };
  }
}
