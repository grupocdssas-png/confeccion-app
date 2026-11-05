// Cliente de la API de Alegra y armado de cada documento a partir de lo que
// entrega la base de datos (datos_trabajo). Las claves llegan por secretos
// de Supabase (ALEGRA_USUARIO, ALEGRA_TOKEN); nunca están en la app.

export type Pedido = { metodo: 'GET' | 'POST' | 'PUT' | 'PATCH'; ruta: string; cuerpo?: unknown; base?: 'contabilidad' | 'nomina' };

export class ErrorIntegracion extends Error {
  constructor(mensaje: string, readonly status = 0, readonly reintentable = true, readonly respuesta: unknown = null) {
    super(mensaje);
  }
}

export interface ConfigAlegra {
  base: string; // https://api.alegra.com/api/v1
  baseNomina: string; // API de Alegra Nómina
  usuario: string;
  token: string;
}

export class ClienteAlegra {
  constructor(readonly cfg: ConfigAlegra, readonly fetchFn: typeof fetch = fetch) {}

  async pedir<T = any>(p: Pedido): Promise<T> {
    const base = p.base === 'nomina' ? this.cfg.baseNomina : this.cfg.base;
    let r: Response;
    try {
      r = await this.fetchFn(`${base}${p.ruta}`, {
        method: p.metodo,
        headers: {
          Authorization: 'Basic ' + btoa(`${this.cfg.usuario}:${this.cfg.token}`),
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: p.cuerpo === undefined ? undefined : JSON.stringify(p.cuerpo),
      });
    } catch (e) {
      throw new ErrorIntegracion(`Sin conexión con Alegra: ${e}`);
    }
    const texto = await r.text();
    let json: any = null;
    try {
      json = texto ? JSON.parse(texto) : null;
    } catch {
      json = { texto };
    }
    if (!r.ok) {
      const msg = json?.message ?? json?.error?.message ?? json?.texto ?? r.statusText;
      // 4xx (salvo 408/429) son errores de datos: reintentar no sirve hasta corregir
      const reintentable = r.status >= 500 || r.status === 408 || r.status === 429;
      throw new ErrorIntegracion(`Alegra respondió ${r.status}: ${msg}`, r.status, reintentable, json);
    }
    return json as T;
  }
}

const quitarVacios = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));

// ---------------------------------------------------------------------------
// Documentos (funciones puras: datos → pedido a Alegra)
// ---------------------------------------------------------------------------
export function pedidoCrearItem(d: any): Pedido {
  return {
    metodo: 'POST',
    ruta: '/items',
    cuerpo: quitarVacios({
      name: d.nombre,
      reference: d.referencia,
      description: d.codigo,
      price: [{ idPriceList: 1, price: Number(d.precio ?? 0) }],
      tax: d.impuesto ? [{ id: Number(d.impuesto) }] : undefined,
      itemCategory: d.categoria ? { id: Number(d.categoria) } : undefined,
      inventory: quitarVacios({
        unit: 'unit',
        unitCost: d.costo != null ? Number(d.costo) : undefined,
        warehouses: d.bodega ? [{ id: Number(d.bodega), initialQuantity: 0 }] : undefined,
      }),
    }),
  };
}

export function pedidoAjustePt(d: any): Pedido {
  const cant = Number(d.cantidad);
  return {
    metodo: 'POST',
    ruta: '/inventory-adjustments',
    cuerpo: {
      date: d.fecha,
      observations: `App de producción · ${d.observacion ?? ''}`.trim(),
      warehouse: { id: Number(d.bodega_alegra) },
      items: [quitarVacios({ id: Number(d.item), type: cant >= 0 ? 'in' : 'out', quantity: Math.abs(cant), unitCost: d.costo != null ? Number(d.costo) : undefined })],
    },
  };
}

/** Despacho: a una tienda propia es traslado de bodega; a un cliente, remisión. */
export function pedidoDespacho(d: any): Pedido {
  const obs = `App de producción · ${d.consecutivo}${d.pedido ? ` · pedido ${d.pedido}` : ''}${d.observacion ? ` · ${d.observacion}` : ''}`;
  if (d.bodega_destino) {
    return {
      metodo: 'POST',
      ruta: '/warehouse-transfers',
      cuerpo: {
        date: d.fecha,
        observations: obs,
        origin: { id: Number(d.bodega_origen) },
        destination: { id: Number(d.bodega_destino) },
        items: (d.lineas as any[]).map((l) => ({ id: Number(l.item), quantity: Number(l.cantidad) })),
      },
    };
  }
  return {
    metodo: 'POST',
    ruta: '/remissions',
    cuerpo: quitarVacios({
      date: d.fecha,
      dueDate: d.fecha,
      client: { id: Number(d.cliente) },
      warehouse: { id: Number(d.bodega_origen) },
      priceList: d.lista_precio ? { id: Number(d.lista_precio) } : undefined,
      observations: obs,
      items: (d.lineas as any[]).map((l) => quitarVacios({ id: Number(l.item), quantity: Number(l.cantidad), price: l.precio != null ? Number(l.precio) : undefined })),
    }),
  };
}

/** Anular un despacho ya enviado: anula la remisión o hace el traslado de vuelta. */
export function pedidoAnularDespacho(d: any): Pedido | null {
  if (d.sin_original) return null;
  const o = d.original;
  if (o?.respuesta?.documento === 'remision') {
    return { metodo: 'POST', ruta: `/remissions/${o.externo_id}/void`, cuerpo: {} };
  }
  const tr = o?.respuesta?.cuerpo;
  return {
    metodo: 'POST',
    ruta: '/warehouse-transfers',
    cuerpo: {
      date: d.fecha,
      observations: `App de producción · anulación de ${d.consecutivo}${d.motivo ? ` · ${d.motivo}` : ''}`,
      origin: tr?.destination ?? { id: Number(d.bodega_destino) },
      destination: tr?.origin ?? { id: Number(d.bodega_origen) },
      items: tr?.items ?? (d.lineas as any[]).map((l) => ({ id: Number(l.item), quantity: Number(l.cantidad) })),
    },
  };
}

export function pedidoFacturaProveedor(d: any): Pedido {
  return {
    metodo: 'POST',
    ruta: '/bills',
    cuerpo: {
      date: d.fecha,
      dueDate: d.fecha,
      billNumber: d.factura,
      provider: { id: Number(d.proveedor) },
      observations: `App de producción · ${d.observacion}`,
      purchases: {
        items: (d.lineas as any[]).map((l) =>
          quitarVacios({ id: Number(l.item), price: Number(l.precio ?? 0), quantity: Number(l.cantidad), warehouse: l.bodega ? { id: Number(l.bodega) } : undefined })
        ),
      },
    },
  };
}

/** Consumo: un ajuste de salida por bodega (telas y insumos pueden estar en bodegas distintas). */
export function pedidosAjusteConsumo(d: any): Pedido[] {
  const porBodega = new Map<string, any[]>();
  for (const l of d.lineas as any[]) {
    const k = String(l.bodega);
    porBodega.set(k, [...(porBodega.get(k) ?? []), l]);
  }
  return [...porBodega.entries()].map(([bodega, ls]) => ({
    metodo: 'POST' as const,
    ruta: '/inventory-adjustments',
    cuerpo: {
      date: d.fecha,
      observations: `App de producción · ${d.observacion}`,
      warehouse: { id: Number(bodega) },
      items: ls.map((l) => quitarVacios({ id: Number(l.item), type: Number(l.cantidad) >= 0 ? 'out' : 'in', quantity: Math.abs(Number(l.cantidad)), unitCost: l.costo != null ? Number(l.costo) : undefined })),
    },
  }));
}

export function pedidoDocumentoSoporte(d: any): Pedido {
  return {
    metodo: 'POST',
    ruta: '/bills',
    cuerpo: quitarVacios({
      type: 'supportDocument',
      date: d.fecha,
      dueDate: d.fecha,
      provider: { id: Number(d.proveedor) },
      numberTemplate: d.numeracion ? { id: Number(d.numeracion) } : undefined,
      observations: `App de producción · ${d.descripcion}`,
      purchases: { categories: [{ id: Number(d.cuenta), price: Number(d.valor), quantity: 1, observations: d.descripcion }] },
    }),
  };
}

/** Nómina: busca la liquidación del empleado en el periodo y le agrega el incentivo. */
export async function enviarIncentivo(alegra: ClienteAlegra, d: any): Promise<{ externo: string; respuesta: unknown }> {
  let empleado = d.empleado_alegra;
  if (!empleado) {
    const e = await alegra.pedir<any>({ metodo: 'GET', base: 'nomina', ruta: `/employees?identification=${encodeURIComponent(d.documento)}&limit=1` });
    empleado = (e?.data ?? e)?.[0]?.id;
    if (!empleado) throw new ErrorIntegracion(`Falta enlazar: empleado con documento ${d.documento} no está en Alegra Nómina`, 404, false);
  }
  const lista = await alegra.pedir<any>({
    metodo: 'GET',
    base: 'nomina',
    ruta: `/payrolls?startDate=${d.desde}&endDate=${d.hasta}&employee.id=${empleado}&limit=1`,
  });
  const nomina = (lista?.data ?? lista)?.[0];
  if (!nomina) throw new ErrorIntegracion(`La nómina del ${d.desde} al ${d.hasta} aún no existe en Alegra para este empleado`, 404, true);
  const ingresos = [...(nomina.concepts?.incomes ?? []), { id: Number(d.concepto), currency: Number(d.valor), customName: 'Incentivo por eficiencia' }];
  const r = await alegra.pedir<any>({
    metodo: 'PATCH',
    base: 'nomina',
    ruta: `/payrolls/${nomina.id}`,
    cuerpo: { payrollStatus: nomina.payrollStatus, createAdjustmentNote: false, concepts: { incomes: ingresos } },
  });
  return { externo: String(nomina.id), respuesta: r };
}

/** Nómina de un periodo → filas para registrar_costos_nomina. */
export async function leerNomina(alegra: ClienteAlegra, desde: string, hasta: string) {
  const filas: { identificacion: string; nombre: string; costo_total: number; salario: number | null; alegra_id: string | null }[] = [];
  let desdeCursor: string | undefined;
  for (let i = 0; i < 20; i++) {
    const r = await alegra.pedir<any>({
      metodo: 'GET',
      base: 'nomina',
      ruta: `/payrolls?startDate=${desde}&endDate=${hasta}&limit=100${desdeCursor ? `&from=${desdeCursor}` : ''}`,
    });
    const lista: any[] = r?.data ?? r?.payrolls ?? (Array.isArray(r) ? r : []);
    for (const p of lista) {
      const t = p.totals ?? p;
      const costo = Number(t.totalCost ?? (Number(t.incomes ?? 0) + Number(t.socialContributions ?? 0) + Number(t.socialBenefits ?? 0)));
      filas.push({
        identificacion: String(p.employee?.identification ?? p.employee?.identificationObject?.number ?? ''),
        nombre: String(p.employee?.name ?? [p.employee?.firstName, p.employee?.lastName].filter(Boolean).join(' ')),
        costo_total: Math.round(costo),
        salario: t.salary != null ? Math.round(Number(t.salary)) : null,
        alegra_id: p.employee?.id != null ? String(p.employee.id) : null,
      });
    }
    desdeCursor = r?.pagination?.nextCursor ?? r?.metadata?.nextCursor;
    if (!desdeCursor || lista.length === 0) break;
  }
  return filas.filter((f) => f.identificacion);
}
