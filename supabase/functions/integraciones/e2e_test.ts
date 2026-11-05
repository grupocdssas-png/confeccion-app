// Punta a punta con la base local de Supabase y Alegra/WhatsApp simulados.
// Requiere `supabase start` con los datos de ejemplo. Se ejecuta solo con:
//   E2E=1 SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... deno test -A supabase/functions/integraciones/e2e_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1.0.8';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { ClienteAlegra } from '../_compartido/alegra.ts';
import { procesarCola } from '../_compartido/procesador.ts';
import { Simulador } from '../_compartido/simulador.ts';
import { ClienteWhatsApp } from '../_compartido/whatsapp.ts';
import { repositorioSupabase } from './index.ts';

const activo = Deno.env.get('E2E') === '1';

Deno.test({
  name: 'cola real: productos de la ficha → se crean en Alegra y se enlazan; luego sale el producto terminado',
  ignore: !activo,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const db = createClient(Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const sim = new Simulador();
    const alegra = new ClienteAlegra({ base: 'https://alegra.test/api/v1', baseNomina: 'https://alegra.test/payroll/api/v1', usuario: 'u', token: 't' }, sim.fetch);
    const wa = new ClienteWhatsApp({ base: 'https://graph.test/v21.0', telefonoId: '123', token: 'w' }, sim.fetch);
    const repo = repositorioSupabase(db);

    // Ajustes como los pondría Costos en la pantalla
    for (const [c, v] of [['alegra_activo', 'true'], ['alegra_bodega_pt', '1'], ['alegra_bodega_segundas', '7'], ['alegra_impuesto_iva', '3']]) {
      const { error } = await db.from('integracion_ajustes').update({ valor: v === 'true' ? true : v }).eq('clave', c);
      if (error) throw error;
    }
    const { data: items } = await db.from('integraciones_cola').select('id, datos').eq('tipo', 'crear_item').eq('estado', 'pendiente');
    assert((items ?? []).length > 0, 'la ficha aprobada de ejemplo dejó productos por crear');

    // Primera pasada (de día): se crean los productos en Alegra
    const r1 = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10, limite: 200 });
    assertEquals(r1.fallidos, 0, r1.detalle.join('\n'));
    assertEquals(sim.de('/items').length, items!.length);
    const { data: skus } = await db.from('skus').select('codigo, alegra_id').in('id', items!.map((i) => i.datos.sku_id));
    assert(skus!.every((s) => s.alegra_id), 'cada producto creado quedó enlazado con su id de Alegra');
    assertEquals(sim.de('/items')[0].cuerpo.inventory.warehouses, [{ id: 1, initialQuantity: 0 }]);
    assertEquals(sim.de('/items')[0].cuerpo.tax, [{ id: 3 }]);

    // Entra producto terminado de un SKU ya enlazado → ajuste de entrada en la bodega 1
    const sku = (await db.from('skus').select('id').not('alegra_id', 'is', null).limit(1).single()).data!;
    const bodegaPt = (await db.from('bodegas').select('id').eq('tipo', 'producto_terminado').single()).data!.id;
    const { error: e2 } = await db.from('movimientos_producto').insert({ tipo: 'ajuste', sku_id: sku.id, bodega_id: bodegaPt, cantidad: 4, motivo: 'Prueba de integración' });
    if (e2) throw e2;
    const r2 = await procesarCola(repo, { alegra, whatsapp: wa, horaBogota: 10, limite: 200 });
    assertEquals(r2.enviados >= 1, true, r2.detalle.join('\n'));
    const aj = sim.de('/inventory-adjustments').at(-1)!;
    assertEquals(aj.cuerpo.warehouse, { id: 1 });
    assertEquals(aj.cuerpo.items[0].type, 'in');
    assertEquals(aj.cuerpo.items[0].quantity, 4);
    const { data: hecho } = await db.from('integraciones_cola').select('estado, externo_id').eq('tipo', 'ajuste_pt').order('creado_en', { ascending: false }).limit(1).single();
    assertEquals(hecho!.estado, 'enviado');

    // Nada queda "enviando"
    const { count } = await db.from('integraciones_cola').select('*', { count: 'exact', head: true }).eq('estado', 'enviando');
    assertEquals(count, 0);
  },
});
