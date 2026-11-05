// deno test supabase/functions
import { assert, assertEquals } from 'jsr:@std/assert@1.0.8';
import { ClienteAlegra, pedidoAjustePt, pedidoAnularDespacho, pedidoDespacho, pedidoDocumentoSoporte, pedidosAjusteConsumo } from './alegra.ts';
import { procesarCola, type Documento, type Repositorio, type Trabajo } from './procesador.ts';
import { Simulador } from './simulador.ts';
import { ClienteWhatsApp, cuerpoMensaje, normalizarTelefono, textoMensaje } from './whatsapp.ts';

/** Repositorio en memoria con el mismo contrato que las funciones SQL */
class RepoMemoria implements Repositorio {
  cola: (Trabajo & { estado: string; intentos: number; externo?: string | null; error?: string | null; respuesta?: unknown })[] = [];
  docs = new Map<string, Documento>();
  ajustes: Record<string, string | null> = { alegra_activo: 'true', whatsapp_activo: 'false', whatsapp_hora_inicio: '6', whatsapp_hora_fin: '21' };
  agregar(t: Trabajo, d: Partial<Documento>) {
    this.cola.push({ ...t, estado: 'pendiente', intentos: 0 });
    this.docs.set(t.id, { id: t.id, tipo: t.tipo, sistema: t.sistema, faltan: [], datos: {}, ...d });
  }
  tareasProgramadas = async () => ({});
  liberarColgados = async () => 0;
  tomar = async (limite: number, sistemas: string[]) => {
    const xs = this.cola.filter((t) => t.estado === 'pendiente' && sistemas.includes(t.sistema)).slice(0, limite);
    xs.forEach((t) => (t.estado = 'enviando'));
    return xs;
  };
  datos = async (id: string) => this.docs.get(id)!;
  terminar = async (id: string, ok: boolean, externo?: string | null, respuesta?: unknown, error?: string | null, bloqueado?: boolean) => {
    const t = this.cola.find((x) => x.id === id)!;
    t.intentos++;
    t.estado = ok ? 'enviado' : bloqueado ? 'bloqueado' : 'pendiente';
    t.externo = externo;
    t.error = error;
    t.respuesta = respuesta;
  };
  ajuste = async (c: string) => this.ajustes[c] ?? null;
}

const trabajo = (id: string, tipo: string, sistema: 'alegra' | 'whatsapp' = 'alegra'): Trabajo => ({ id, tipo, sistema, clave: id, descripcion: `Trabajo ${id}` });

function entorno() {
  const sim = new Simulador();
  const alegra = new ClienteAlegra({ base: 'https://alegra.test/api/v1', baseNomina: 'https://alegra.test/payroll/api/v1', usuario: 'u@ejemplo.co', token: 't' }, sim.fetch);
  const wa = new ClienteWhatsApp({ base: 'https://graph.test/v21.0', telefonoId: '123', token: 'w' }, sim.fetch);
  return { sim, alegra, wa, repo: new RepoMemoria() };
}

Deno.test('ajuste de entrada de producto terminado: bodega, producto, cantidad y costo', () => {
  const p = pedidoAjustePt({ fecha: '2026-11-05', bodega_alegra: '1', item: '9818', cantidad: 18, costo: 12193, observacion: 'JG-000003 · OP-000001' });
  assertEquals(p.ruta, '/inventory-adjustments');
  assertEquals(p.cuerpo, {
    date: '2026-11-05', observations: 'App de producción · JG-000003 · OP-000001', warehouse: { id: 1 },
    items: [{ id: 9818, type: 'in', quantity: 18, unitCost: 12193 }],
  });
  assertEquals((pedidoAjustePt({ fecha: 'x', bodega_alegra: '7', item: '1', cantidad: -2 }).cuerpo as any).items[0], { id: 1, type: 'out', quantity: 2 });
});

Deno.test('despacho: traslado a tienda propia, remisión a cliente, y cómo se anula cada uno', () => {
  const base = { fecha: '2026-11-05', consecutivo: 'DES-000001', pedido: 'PED-000001', bodega_origen: '5', lineas: [{ item: '9818', cantidad: 3, precio: 26029 }] };
  const tr = pedidoDespacho({ ...base, bodega_destino: '2' });
  assertEquals(tr.ruta, '/warehouse-transfers');
  assertEquals((tr.cuerpo as any).origin, { id: 5 });
  assertEquals((tr.cuerpo as any).destination, { id: 2 });
  const rem = pedidoDespacho({ ...base, cliente: '7370', lista_precio: '3' });
  assertEquals(rem.ruta, '/remissions');
  assertEquals((rem.cuerpo as any).client, { id: 7370 });
  assertEquals((rem.cuerpo as any).items, [{ id: 9818, quantity: 3, price: 26029 }]);
  // anular remisión → void; anular traslado → traslado de vuelta; nunca enviado → nada
  assertEquals(pedidoAnularDespacho({ ...base, original: { externo_id: '8', respuesta: { documento: 'remision' } } })!.ruta, '/remissions/8/void');
  const vuelta = pedidoAnularDespacho({ ...base, original: { externo_id: '9', respuesta: { documento: 'traslado', cuerpo: tr.cuerpo } } })!;
  assertEquals((vuelta.cuerpo as any).origin, { id: 2 });
  assertEquals((vuelta.cuerpo as any).destination, { id: 5 });
  assertEquals(pedidoAnularDespacho({ ...base, sin_original: true }), null);
});

Deno.test('consumo de materia prima: un ajuste de salida por bodega', () => {
  const ps = pedidosAjusteConsumo({ fecha: '2026-11-04', observacion: 'Consumo OP-000001', lineas: [
    { item: '1', bodega: '3', cantidad: 49.74, costo: 32000 }, { item: '2', bodega: '6', cantidad: 189, costo: 180 }, { item: '3', bodega: '6', cantidad: -2, costo: 100 },
  ] });
  assertEquals(ps.length, 2);
  assertEquals((ps[0].cuerpo as any).warehouse, { id: 3 });
  assertEquals((ps[1].cuerpo as any).items, [{ id: 2, type: 'out', quantity: 189, unitCost: 180 }, { id: 3, type: 'in', quantity: 2, unitCost: 100 }]);
});

Deno.test('documento soporte del satélite a la cuenta contable de maquila', () => {
  const p = pedidoDocumentoSoporte({ fecha: '2026-11-05', proveedor: '6355', valor: 180000, cuenta: '5097', numeracion: '28', descripcion: 'Estampación de 150 prendas · OP-000001 · CPS-000001' });
  assertEquals((p.cuerpo as any).type, 'supportDocument');
  assertEquals((p.cuerpo as any).numberTemplate, { id: 28 });
  assertEquals((p.cuerpo as any).purchases.categories[0].price, 180000);
});

Deno.test('WhatsApp: plantillas, teléfono colombiano y texto', () => {
  assertEquals(normalizarTelefono('300 123 4567'), '573001234567');
  assertEquals(normalizarTelefono('+57 300 123 4567'), '573001234567');
  assertEquals(textoMensaje('remision_vencida', ['REM-000001', '04/11/2026']), 'Recordatorio: la remisión REM-000001 debía devolverse el 04/11/2026. Por favor avísenos cuándo la entrega.');
  assertEquals(cuerpoMensaje({ telefono: '3001234567', plantilla: 'alerta_produccion', parametros: ['OP-000002 atrasada'] }).template.components[0].parameters, [{ type: 'text', text: 'OP-000002 atrasada' }]);
});

Deno.test('procesa la cola: envía, enlaza lo creado, bloquea lo que no está enlazado y reintenta lo que falla', async () => {
  const { sim, alegra, wa, repo } = entorno();
  repo.agregar(trabajo('a', 'crear_item'), { datos: { nombre: 'CAMISETA NEGRO / M', referencia: 'CAM-001', codigo: 'PT-CAM-001-N-M', precio: 45000 } });
  repo.agregar(trabajo('b', 'ajuste_pt'), { faltan: ['producto PT-CAM-001-N-L'] });
  repo.agregar(trabajo('c', 'ajuste_pt'), { datos: { fecha: '2026-11-05', bodega_alegra: '1', item: '9818', cantidad: 5 } });
  repo.agregar(trabajo('d', 'crear_item'), { datos: { nombre: '' } }); // Alegra lo rechaza (400): error de datos
  sim.fallarProximas = 0;
  const r = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10 });
  assertEquals([r.tomados, r.enviados, r.bloqueados, r.fallidos], [4, 2, 2, 0]);
  const a = repo.cola.find((t) => t.id === 'a')!;
  assertEquals(a.estado, 'enviado');
  assert(a.externo && Number(a.externo) >= 1000, 'el id de Alegra queda para enlazar el producto');
  assertEquals(repo.cola.find((t) => t.id === 'b')!.error, 'Falta enlazar: producto PT-CAM-001-N-L');
  assert(repo.cola.find((t) => t.id === 'd')!.error!.includes('400'));
  assertEquals(sim.de('/items').length, 2);
  assertEquals(sim.de('/inventory-adjustments').length, 1);

  // Alegra caído: queda pendiente para reintentar
  repo.agregar(trabajo('e', 'ajuste_pt'), { datos: { fecha: '2026-11-05', bodega_alegra: '1', item: '1', cantidad: 1 } });
  sim.fallarProximas = 1;
  const r2 = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10 });
  assertEquals(r2.fallidos, 1);
  assertEquals(repo.cola.find((t) => t.id === 'e')!.estado, 'pendiente');
  const r3 = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10 });
  assertEquals(r3.enviados, 1);
});

Deno.test('Alegra apagado: no se toca; WhatsApp sin activar se simula; fuera de horario no se envía', async () => {
  const { sim, alegra, wa, repo } = entorno();
  repo.ajustes.alegra_activo = 'false';
  repo.agregar(trabajo('a', 'ajuste_pt'), { datos: {} });
  repo.agregar(trabajo('w', 'mensaje', 'whatsapp'), { datos: { telefono: '3001234567', plantilla: 'alerta_produccion', parametros: ['Paro de 45 min en MOD1'] } });
  const noche = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 23 });
  assertEquals(noche.tomados, 0);
  const r = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 9 });
  assertEquals([r.tomados, r.simulados], [1, 1]);
  assertEquals(repo.cola.find((t) => t.id === 'a')!.estado, 'pendiente');
  assertEquals((repo.cola.find((t) => t.id === 'w')!.respuesta as any).texto, 'Alerta de producción: Paro de 45 min en MOD1');
  assertEquals(sim.recibidos.length, 0, 'nada salió hacia afuera');
  // activado: sale por la API
  repo.ajustes.whatsapp_activo = 'true';
  repo.agregar(trabajo('w2', 'mensaje', 'whatsapp'), { datos: { telefono: '3001234567', plantilla: 'pago_satelite', parametros: ['CPS-000001', '180.000'] } });
  await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 9 });
  assertEquals(sim.de('/123/messages').length, 1);
  assertEquals(sim.de('/123/messages')[0].cuerpo.to, '573001234567');
});

Deno.test('incentivo a la nómina del empleado en Alegra Nómina', async () => {
  const { sim, alegra, wa, repo } = entorno();
  sim.nominas = [{ id: 'n1', payrollStatus: 'draft', employee: { id: 'e1', identification: '1036' }, concepts: { incomes: [{ id: 1, currency: 650000 }] } }];
  repo.agregar(trabajo('i', 'concepto_nomina'), { datos: { empleado_alegra: 'e1', valor: 45000, concepto: 12, desde: '2026-11-01', hasta: '2026-11-15' } });
  const r = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10 });
  assertEquals(r.enviados, 1);
  const patch = sim.recibidos.find((x) => x.metodo === 'PATCH')!;
  assertEquals(patch.ruta, '/payrolls/n1');
  assertEquals(patch.cuerpo.concepts.incomes.length, 2, 'conserva los conceptos que ya tenía');
  assertEquals(patch.cuerpo.concepts.incomes[1], { id: 12, currency: 45000, customName: 'Incentivo por eficiencia' });
});
