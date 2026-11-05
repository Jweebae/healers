// POST /functions/v1/create-order
// Validates the order against the LIVE settings row (price, minimum, step, tiers,
// delivery fees, open/closed), saves it, then alerts Telegram.
//
// Secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (several ids separated by commas).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
// Deployed with verify_jwt = false because the page only sends the publishable key.
import { createClient } from "npm:@supabase/supabase-js@2";

const DUPLICATE_WINDOW_MIN = 10;   // same phone twice within this window = duplicate
const BURST_WINDOW_MIN = 5;        // spam brake: too many orders overall in this window
const BURST_LIMIT = 30;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

const squash = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const fmt = (n: number) => n.toLocaleString("fr-DZ").replace(/[  ]/g, " ");

type Tier = { min_qty: number; unit_price: number };
type Settings = {
  product_name: string; pack_label: string; unit_price: number; min_qty: number; max_qty: number;
  step_qty: number; tiers: Tier[]; delivery_home: number | null; delivery_desk: number | null; orders_open: boolean;
};
type Order = {
  customer_name: string; business_name: string; phone: string; wilaya: string; commune: string;
  delivery_type: "home" | "desk"; address: string; quantity: number; customer_note: string;
};

// highest tier whose threshold is reached; otherwise the base price
export function priceFor(qty: number, s: Pick<Settings, "unit_price" | "tiers">) {
  let price = s.unit_price;
  let best = 0;
  for (const t of s.tiers ?? []) {
    if (qty >= t.min_qty && t.min_qty >= best) { best = t.min_qty; price = t.unit_price; }
  }
  return price;
}

function validate(input: Record<string, unknown>, s: Settings): { value?: Order; field?: string } {
  const name = squash(input.customer_name);
  if (name.length < 3 || name.length > 100 || !/\p{L}/u.test(name)) return { field: "name" };

  const business = squash(input.business_name).slice(0, 100);

  const phone = String(input.phone ?? "");
  if (!/^0[567]\d{8}$/.test(phone)) return { field: "phone" };

  const wilaya = squash(input.wilaya);
  if (!/^\d{2} - .{2,40}$/u.test(wilaya)) return { field: "wilaya" };

  const commune = squash(input.commune);
  if (commune.length < 2 || commune.length > 60) return { field: "commune" };

  const delivery = input.delivery_type;
  if (delivery !== "home" && delivery !== "desk") return { field: "delivery" };

  const address = delivery === "home" ? squash(input.address).slice(0, 300) : "";
  if (delivery === "home" && address.length < 8) return { field: "address" };

  const q = input.quantity;
  if (typeof q !== "number" || !Number.isInteger(q) || q < s.min_qty || q > s.max_qty || q % s.step_qty !== 0) {
    return { field: "quantity" };
  }
  const note = squash(input.customer_note).slice(0, 300);
  return {
    value: { customer_name: name, business_name: business, phone, wilaya, commune, delivery_type: delivery, address, quantity: q, customer_note: note },
  };
}

function message(id: number, o: Order, s: Settings, unit: number, items: number, fee: number | null) {
  const lines = [
    `🆕 <b>طلب جديد #${id}</b> · HEALERS`,
    "",
    `👤 ${esc(o.customer_name)}`,
  ];
  if (o.business_name) lines.push(`🏪 ${esc(o.business_name)}`);
  lines.push(
    `📞 <code>${o.phone}</code>`,
    `📍 ${esc(o.wilaya)} · ${esc(o.commune)}`,
    `🚚 ${o.delivery_type === "home" ? "إلى المنزل" : "إلى مكتب التوصيل"}`,
  );
  if (o.address) lines.push(`🏠 ${esc(o.address)}`);
  if (o.customer_note) lines.push(`📝 ${esc(o.customer_note)}`);
  lines.push(
    "",
    `📦 <b>${o.quantity} × ${esc(s.pack_label)}</b> · ${fmt(unit)} دج للوحدة`,
    `💵 المنتجات: ${fmt(items)} دج`,
    fee === null ? `🚚 التوصيل: يُحدَّد عند التأكيد` : `🚚 التوصيل: ${fee === 0 ? "مجاني" : fmt(fee) + " دج"}`,
    `💰 <b>${fmt(items + (fee ?? 0))} دج</b>${fee === null ? " + التوصيل" : ""} (الدفع عند الاستلام)`,
  );
  return lines.join("\n");
}

async function notifyTelegram(text: string): Promise<boolean> {
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const chats = (Deno.env.get("TELEGRAM_CHAT_ID") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!token || chats.length === 0) return false;
  const sent = await Promise.all(chats.map((chat_id) =>
    fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id, text, parse_mode: "HTML", disable_web_page_preview: true }),
    }).then((r) => r.ok).catch(() => false)
  ));
  return sent.some(Boolean);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ success: false, error: "Method not allowed" }, 405);

  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return json({ success: false, error: "Bad JSON" }, 400); }
  if (!input || typeof input !== "object") return json({ success: false, error: "Bad JSON" }, 400);

  // bot trap: the honeypot field must stay empty. Pretend it worked, store nothing.
  if (input.website) return json({ success: true, order_id: "—" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const st = await db.from("settings").select("*").eq("id", 1).single();
  if (st.error || !st.data) return json({ success: false, error: "Server error" }, 500);
  const s = st.data as Settings;
  if (!s.orders_open) return json({ success: false, error: "Closed" }, 403);

  const checked = validate(input, s);
  if (!checked.value) {
    return json({ success: false, error: "Invalid", field: checked.field,
      rules: { min_qty: s.min_qty, max_qty: s.max_qty, step_qty: s.step_qty } }, 400);
  }
  const order = checked.value;

  const since = (min: number) => new Date(Date.now() - min * 60_000).toISOString();
  const dup = await db.from("orders").select("id", { count: "exact", head: true })
    .eq("phone", order.phone).gte("created_at", since(DUPLICATE_WINDOW_MIN));
  if (dup.error) return json({ success: false, error: "Server error" }, 500);
  if ((dup.count ?? 0) > 0) return json({ success: false, error: "Duplicate order" }, 429);

  const burst = await db.from("orders").select("id", { count: "exact", head: true }).gte("created_at", since(BURST_WINDOW_MIN));
  if ((burst.count ?? 0) >= BURST_LIMIT) return json({ success: false, error: "Too many orders" }, 429);

  // every amount is computed here from the settings row, never taken from the browser
  const unit = priceFor(order.quantity, s);
  const items = unit * order.quantity;
  const fee = order.delivery_type === "home" ? s.delivery_home : s.delivery_desk;
  const total = items + (fee ?? 0);

  const ins = await db.from("orders")
    .insert({ ...order, unit_price: unit, items_total: items, delivery_fee: fee, total_price: total })
    .select("id").single();
  if (ins.error) { console.error("insert failed", ins.error.message); return json({ success: false, error: "Server error" }, 500); }

  // the order is saved at this point, so a Telegram problem must not fail the customer's request
  const sent = await notifyTelegram(message(ins.data.id, order, s, unit, items, fee));
  if (sent) await db.from("orders").update({ telegram_sent: true }).eq("id", ins.data.id);
  else console.error("telegram not sent for order", ins.data.id);

  return json({ success: true, order_id: ins.data.id, unit_price: unit, total_price: total, delivery_fee: fee });
});
