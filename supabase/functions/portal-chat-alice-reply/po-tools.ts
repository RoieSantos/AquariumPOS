// Real Purchase Order tools for Alice - Portal Chat ONLY (never Messenger / the website widget).
// Per "can I teach Alice to build PO? I'll send what I want to buy then we will create a PO
// against it" (2026-11-23). Passed to runChatbotTurn as extraTools/extraToolExecutor, so they are
// NOT in the shared TOOLS list and `simulate` doesn't apply - po_create_purchase_order makes a real
// open (unposted) PO.
//
// Every call goes through the same staff_* RPCs the Purchase Orders page uses, with the chatting
// staff member's own username + session token, so the PO is created by them and the RPCs' own auth
// still applies. Who gets these tools at all is decided by staff_can_use_alice_po
// (sql/supabase_portal_chat_alice_purchase_orders.sql) in index.ts.
//
// Deliberately NOT here: posting, receiving, paying, deleting or editing an existing PO - those
// stay on the Purchase Orders page.

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';

const PORTAL_BASE_URL = 'https://rspetstop.com';
const CREATE_TOOL = 'po_create_purchase_order';
const DUPLICATE_WINDOW_MS = 15 * 60 * 1000;

export const PO_TOOLS: Anthropic.Tool[] = [
  {
    name: 'po_search_vendors',
    description: 'Purchase Orders (staff only): find a supplier/vendor by name. Returns vendor_code, name, contact. Use a short keyword (e.g. "aqua", "3693"). Empty query lists all active vendors.',
    input_schema: {
      type: 'object',
      properties: { query: { type: 'string', description: 'Part of the vendor name. Empty = all.' } }
    }
  },
  {
    name: 'po_list_locations',
    description: 'Purchase Orders (staff only): list the store branches / warehouses a PO can be delivered to (id + name).',
    input_schema: { type: 'object', properties: {} }
  },
  {
    name: 'po_search_items',
    description: 'Purchase Orders (staff only): find catalog items to put on a PO. Matches item code or name containing the query (one short keyword or phrase works best - e.g. "prime", "tetra bits", "AQ-043"; try another keyword if nothing comes back). With vendor_code, searches that vendor\'s items first and falls back to the whole catalog (flagged not_tagged_to_vendor). Returns code, name, in_stock and last_cost (the item\'s last purchase cost - the default unit cost for the PO).',
    input_schema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Item code or part of the name.' },
        vendor_code: { type: 'string', description: 'Optional - the PO vendor, to search their items first.' }
      },
      required: ['query']
    }
  },
  {
    name: 'po_item_options',
    description: 'Purchase Orders (staff only): for one item, list its variants (sizes/colors - pick one when the item has them) and its purchase units of measure (e.g. BOX = 12 PCS). Call when the item has variants or the request says case/box/pack/dozen.',
    input_schema: {
      type: 'object',
      properties: { item_code: { type: 'string' } },
      required: ['item_code']
    }
  },
  {
    name: CREATE_TOOL,
    description: 'Purchase Orders (staff only): CREATE a real, open (unposted) Purchase Order. ONLY call this after you have shown the full draft (vendor, deliver-to location, every line with qty, unit, cost and total) and the staff member has replied confirming it in a LATER message (e.g. "yes", "go", "create it"). Never call it in the same turn you first show the draft. Returns the PO number and a link.',
    input_schema: {
      type: 'object',
      properties: {
        user_confirmed: { type: 'boolean', description: 'true only if the staff member explicitly confirmed this exact draft in their latest message.' },
        vendor_code: { type: 'string' },
        warehouse_id: { type: 'string', description: 'Deliver-to location id from po_list_locations.' },
        notes: { type: 'string', description: 'Optional PO note.' },
        lines: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              item_code: { type: 'string' },
              item_name: { type: 'string' },
              quantity: { type: 'number', description: 'How many, in uom_code units if given, else base units (pcs).' },
              unit_cost: { type: 'number', description: 'Cost per unit (per uom_code unit if given). Omit to use the item\'s last cost.' },
              uom_code: { type: 'string', description: 'Optional purchase unit from po_item_options (e.g. BOX).' },
              qty_per_uom: { type: 'number', description: 'Base units in one uom_code unit, from po_item_options. Required with uom_code.' },
              variant_code: { type: 'string', description: 'variation_id from po_item_options, when the item has variants.' },
              variant_name: { type: 'string' },
              description: { type: 'string', description: 'Optional line note.' }
            },
            required: ['item_code', 'quantity']
          }
        }
      },
      required: ['user_confirmed', 'vendor_code', 'warehouse_id', 'lines']
    }
  }
];

export const PO_TOOL_NAMES = PO_TOOLS.map((t) => t.name);

export const PO_SYSTEM_PROMPT = [
  'PURCHASE ORDERS (REAL - internal Portal Chat only): this staff member is allowed to have you build supplier Purchase Orders. Unlike everything else in this chat, the po_* tools are LIVE: po_create_purchase_order creates a real open PO in the system.',
  'Workflow when someone sends what they want to buy (typed list, or a photo of a supplier price list / quotation / handwritten list):',
  '1. Vendor: find it with po_search_vendors. If it is not stated or several match, ask.',
  '2. Deliver-to location: use po_list_locations. If not stated, ask (do not guess).',
  '3. Match every line with po_search_items (pass vendor_code). Try a different keyword before giving up. If an item has variants or the request says case/box/pack, call po_item_options and pick the matching variant / unit - ask if it is ambiguous.',
  '4. Cost: use last_cost from po_search_items unless the staff member or the photo gives a price - then use that price and say so. If last_cost is empty or 0, flag the line "no cost yet". last_cost is per base unit (pcs) - for a line ordered in a bigger unit, its cost is last_cost x qty_per_uom (e.g. BOX of 12 at 50/pc = 600/box), and unit_cost you pass is per that unit.',
  '5. Show the DRAFT as plain text (this chat does not render markdown tables): "Vendor: ...", "Deliver to: ...", then one numbered line per item like "1. AQ-043 Seachem Prime 250ml - 10 pcs x PHP 450.00 = PHP 4,500.00", then "Total: PHP ...". List separately: lines you could not match (with your best 2-3 candidates) and anything you read from a photo but are unsure of. End with "Reply yes to create the PO, or tell me what to change."',
  '6. Only after they confirm in a later message, call po_create_purchase_order with exactly the confirmed lines and user_confirmed true. Then reply with the PO number and the link from the tool result. If they change something, show the updated draft and wait for a new yes.',
  'Photos: read item names, quantities and prices carefully; never invent a line you cannot read - list it as unsure.',
  'You CANNOT post, receive, pay, delete or edit an existing PO - send them to the Purchase Orders page for that (the link opens the PO). Never create the same PO twice; if one was already created for this list, give its number.'
].join('\n');

type Creds = { username: string; password: string };

function fmt(n: number): string {
  return n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function str(v: unknown): string {
  return v === null || v === undefined ? '' : String(v).trim();
}

function num(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

type PoLineInput = {
  item_code?: string;
  item_name?: string;
  quantity?: number;
  unit_cost?: number;
  uom_code?: string;
  qty_per_uom?: number;
  variant_code?: string;
  variant_name?: string;
  description?: string;
};

function linesKey(vendor: string, warehouse: string, lines: PoLineInput[]): string {
  const norm = lines
    .map((l) => [str(l.item_code), num(l.quantity), str(l.uom_code), str(l.variant_code), num(l.unit_cost)].join('|'))
    .sort();
  return JSON.stringify([vendor, warehouse, norm]);
}

export function makePoToolExecutor(supabase: SupabaseClient, creds: Creds, psid: string) {
  const auth = { p_admin_username: creds.username, p_admin_password: creds.password };

  return async function execute(name: string, input: Record<string, unknown>): Promise<string> {
    switch (name) {
      case 'po_search_vendors': {
        const { data, error } = await supabase.rpc('staff_search_vendors', { ...auth, p_search: str(input.query) || null, p_limit: 20 });
        if (error) return `Error: ${error.message}`;
        const rows = (data ?? []) as Array<Record<string, unknown>>;
        if (!rows.length) return 'No active vendor matches that name.';
        return JSON.stringify(rows.map((v) => ({ vendor_code: v.vendor_code, name: v.name, contact_person: v.contact_person || undefined, phone: v.phone || undefined })));
      }

      case 'po_list_locations': {
        const { data, error } = await supabase.rpc('staff_search_warehouses', { ...auth, p_search: null, p_limit: 50 });
        if (error) return `Error: ${error.message}`;
        return JSON.stringify(((data ?? []) as Array<Record<string, unknown>>).map((w) => ({ id: w.id, name: w.name, production: w.is_production_warehouse || undefined })));
      }

      case 'po_search_items': {
        const query = str(input.query);
        if (!query) return 'Give a keyword to search for.';
        const vendorCode = str(input.vendor_code) || null;

        let notTagged = false;
        let { data, error } = await supabase.rpc('staff_search_items', { ...auth, p_search: query, p_limit: 10, p_page: 1, p_vendor_code: vendorCode });
        if (error) return `Error: ${error.message}`;
        if (vendorCode && (!data || data.length === 0)) {
          ({ data, error } = await supabase.rpc('staff_search_items', { ...auth, p_search: query, p_limit: 10, p_page: 1, p_vendor_code: null }));
          if (error) return `Error: ${error.message}`;
          notTagged = true;
        }
        const rows = (data ?? []) as Array<Record<string, unknown>>;
        if (!rows.length) return `No item matches "${query}". Try a shorter or different keyword (brand, main word, or item code).`;

        // last_cost = Items."Cost" (written back by every posted PO). staff_search_items' own cost
        // column prefers the vendor-catalog price, so fetch the catalog cost separately.
        const codes = rows.map((r) => String(r.code));
        const { data: costRows } = await supabase.from('Items').select('Code, Cost').in('Code', codes);
        const lastCost = new Map(((costRows ?? []) as Array<{ Code: string; Cost: number | null }>).map((c) => [c.Code, c.Cost]));

        const total = Number(rows[0].total_count ?? rows.length);
        return JSON.stringify({
          ...(notTagged ? { not_tagged_to_vendor: true, note: 'None of these are tagged to that vendor - matched from the whole catalog.' } : {}),
          ...(total > rows.length ? { more_results: total - rows.length } : {}),
          items: rows.map((r) => {
            const lc = lastCost.get(String(r.code));
            const vendorPrice = num(r.cost);
            return {
              code: r.code,
              name: r.name,
              description: r.description || undefined,
              in_stock: r.quantity_in_stock,
              last_cost: lc ?? null,
              ...(vendorCode && vendorPrice !== null && vendorPrice !== num(lc) ? { vendor_catalog_price: vendorPrice } : {})
            };
          })
        });
      }

      case 'po_item_options': {
        const itemCode = str(input.item_code);
        if (!itemCode) return 'item_code is required.';
        const [variants, units] = await Promise.all([
          supabase.rpc('staff_search_variants', { ...auth, p_item_code: itemCode, p_search: null, p_limit: 50, p_page: 1 }),
          supabase.rpc('staff_list_item_units_of_measure', { ...auth, p_item_code: itemCode })
        ]);
        if (variants.error) return `Error: ${variants.error.message}`;
        if (units.error) return `Error: ${units.error.message}`;
        return JSON.stringify({
          variants: ((variants.data ?? []) as Array<Record<string, unknown>>).map((v) => ({ variation_id: v.variation_id, variant_name: v.variant_name, sku: v.sku || undefined, in_stock: v.quantity_in_stock })),
          units_of_measure: ((units.data ?? []) as Array<Record<string, unknown>>).map((u) => ({ uom_code: u.unit_of_measure_code, description: u.description || undefined, qty_per_uom: u.qty_per_unit_of_measure, is_base: u.is_base, for_purchase: u.is_purch }))
        });
      }

      case CREATE_TOOL: {
        if (input.user_confirmed !== true) {
          return 'NOT CREATED - show the draft and wait for the staff member to confirm it first.';
        }
        const vendorCode = str(input.vendor_code);
        const warehouseId = str(input.warehouse_id);
        const lines = Array.isArray(input.lines) ? (input.lines as PoLineInput[]) : [];
        if (!vendorCode) return 'NOT CREATED - vendor_code is required.';
        if (!warehouseId) return 'NOT CREATED - warehouse_id (deliver-to location) is required.';
        if (!lines.length) return 'NOT CREATED - no lines.';

        for (const [i, l] of lines.entries()) {
          if (!str(l.item_code)) return `NOT CREATED - line ${i + 1} has no item_code.`;
          const q = num(l.quantity);
          if (q === null || q <= 0) return `NOT CREATED - line ${i + 1} (${l.item_code}) needs a quantity above 0.`;
          if (str(l.uom_code) && !(num(l.qty_per_uom)! > 0)) return `NOT CREATED - line ${i + 1} (${l.item_code}) has a unit but no qty_per_uom - check po_item_options.`;
          const c = num(l.unit_cost);
          if (c !== null && c < 0) return `NOT CREATED - line ${i + 1} has a negative cost.`;
        }

        // Guard against creating the same PO twice (a re-sent "yes", a retried request): same
        // vendor + location + lines created from this chat in the last 15 minutes.
        const key = linesKey(vendorCode, warehouseId, lines);
        const { data: recent } = await supabase
          .from('ChatbotToolCalls')
          .select('Input, Result, CreatedAtUtc')
          .eq('Psid', psid)
          .eq('ToolName', CREATE_TOOL)
          .eq('Simulated', false)
          .gte('CreatedAtUtc', new Date(Date.now() - DUPLICATE_WINDOW_MS).toISOString())
          .like('Result', 'CREATED%');
        for (const r of (recent ?? []) as Array<{ Input: Record<string, unknown>; Result: string }>) {
          const prev = r.Input || {};
          if (linesKey(str(prev.vendor_code), str(prev.warehouse_id), (prev.lines as PoLineInput[]) || []) === key) {
            return `ALREADY CREATED - this exact list was already turned into a PO a few minutes ago. ${r.Result.replace(/^CREATED\s*-?\s*/, '')}`;
          }
        }

        const { data: wh } = await supabase.from('Warehouses').select('ID, Name').eq('ID', warehouseId).maybeSingle();
        if (!wh) return `NOT CREATED - location "${warehouseId}" not found; use po_list_locations.`;

        // Base-unit cost defaults to the item's last cost; with a purchase unit, the RPC stores the
        // quantity in base units, so a per-unit (e.g. per BOX) price is converted to per-piece.
        const codes = Array.from(new Set(lines.map((l) => str(l.item_code))));
        const { data: costRows } = await supabase.from('Items').select('Code, Cost, Name').in('Code', codes);
        const itemByCode = new Map(((costRows ?? []) as Array<{ Code: string; Cost: number | null; Name: string }>).map((c) => [c.Code, c]));
        const missing = codes.filter((c) => !itemByCode.has(c));
        if (missing.length) return `NOT CREATED - item code(s) not found: ${missing.join(', ')}. Search again with po_search_items.`;

        let total = 0;
        const summary: string[] = [];
        const rpcLines = lines.map((l, i) => {
          const code = str(l.item_code);
          const item = itemByCode.get(code)!;
          const qty = num(l.quantity)!;
          const uom = str(l.uom_code);
          const perUom = uom ? num(l.qty_per_uom)! : 1;
          const givenCost = num(l.unit_cost);
          const baseCost = givenCost !== null ? givenCost / perUom : num(item.Cost);
          const baseQty = qty * perUom;
          if (baseCost !== null) total += baseCost * baseQty;
          const name = str(l.item_name) || item.Name;
          summary.push(`${i + 1}. ${code} ${name}${str(l.variant_name) ? ` (${str(l.variant_name)})` : ''} - ${qty} ${uom || 'pcs'}${baseCost !== null ? ` = PHP ${fmt(baseCost * baseQty)}` : ' (no cost)'}`);
          return {
            item_code: code,
            item_name: name,
            ...(uom ? { uom_code: uom, qty_per_uom: perUom, quantity_uom: qty } : { quantity: qty }),
            ...(baseCost !== null ? { unit_cost: Math.round(baseCost * 10000) / 10000 } : {}),
            ...(str(l.variant_code) ? { variant_code: str(l.variant_code), variant_name: str(l.variant_name) || null } : {}),
            ...(str(l.description) ? { description: str(l.description) } : {})
          };
        });

        const notes = ['Created by Alice from Portal Chat', str(input.notes)].filter(Boolean).join(' - ');
        const { data: poNo, error } = await supabase.rpc('staff_create_purchase_order', {
          ...auth,
          p_vendor_code: vendorCode,
          p_notes: notes,
          p_lines: rpcLines,
          p_warehouse_id: wh.ID,
          p_warehouse_name: wh.Name
        });
        if (error) return `NOT CREATED - ${error.message}`;

        const link = `${PORTAL_BASE_URL}/purchase-orders.html?search=${encodeURIComponent(String(poNo))}`;
        return `CREATED - Purchase Order ${poNo} (open, not posted) for vendor ${vendorCode}, deliver to ${wh.Name}, ${rpcLines.length} line(s), total PHP ${fmt(total)}.\n${summary.join('\n')}\nOpen it: ${link}`;
      }

      default:
        return `Unknown PO tool ${name}.`;
    }
  };
}
