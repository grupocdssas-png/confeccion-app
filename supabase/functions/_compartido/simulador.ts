// Simulador de Alegra y de WhatsApp para pruebas: responde como las APIs reales
// y guarda lo recibido. Sirve como fetch falso (pruebas) o como servidor HTTP
// (deno run supabase/functions/_compartido/simulador.ts 8787).

export interface Recibido { metodo: string; ruta: string; cuerpo: any }

export class Simulador {
  recibidos: Recibido[] = [];
  siguienteId = 1000;
  fallarProximas = 0; // responde 503 a las próximas N
  nominas: any[] = [];

  manejar = async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const cuerpo = req.method === 'GET' ? null : await req.json().catch(() => null);
    const ruta = url.pathname.replace(/^\/(api\/v1|payroll\/api\/v1|v\d+\.\d+)/, '') + url.search;
    this.recibidos.push({ metodo: req.method, ruta, cuerpo });
    const json = (x: unknown, status = 200) => new Response(JSON.stringify(x), { status, headers: { 'Content-Type': 'application/json' } });
    if (!(req.headers.get('authorization') ?? '').match(/^(Basic|Bearer) .+/)) return json({ message: 'Sin autenticación' }, 401);
    if (this.fallarProximas > 0) {
      this.fallarProximas--;
      return json({ message: 'Servicio no disponible' }, 503);
    }
    const p = url.pathname;
    if (req.method === 'POST' && p.endsWith('/messages')) return json({ messaging_product: 'whatsapp', messages: [{ id: `wamid.${this.siguienteId++}` }] });
    if (req.method === 'GET' && p.endsWith('/warehouses')) return json([{ id: '1', name: 'Principal' }, { id: '7', name: 'IMPERFECTOS' }]);
    if (req.method === 'GET' && p.endsWith('/payrolls')) return json({ data: this.nominas.filter((n) => !url.searchParams.get('employee.id') || String(n.employee.id) === url.searchParams.get('employee.id')) });
    if (req.method === 'PATCH' && p.includes('/payrolls/')) return json({ payroll: { id: p.split('/').pop(), ...cuerpo } });
    if (req.method === 'POST' && p.includes('/items') && !cuerpo?.name) return json({ message: 'El nombre es obligatorio' }, 400);
    if (req.method === 'POST') return json({ id: String(this.siguienteId++), ...cuerpo }, 201);
    if (req.method === 'GET') return json([]);
    return json({ message: 'No encontrado' }, 404);
  };

  /** fetch falso para inyectar en los clientes */
  fetch: typeof fetch = (input, init) => this.manejar(new Request(input as string, init));

  de(ruta: string) {
    return this.recibidos.filter((r) => r.ruta.startsWith(ruta) && r.metodo !== 'GET');
  }
}

if (import.meta.main) {
  const puerto = Number(Deno.args[0] ?? 8787);
  const s = new Simulador();
  Deno.serve({ port: puerto }, async (req) => {
    if (new URL(req.url).pathname === '/__recibidos') return new Response(JSON.stringify(s.recibidos), { headers: { 'Content-Type': 'application/json' } });
    return await s.manejar(req);
  });
}
