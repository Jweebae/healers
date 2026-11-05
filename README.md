# HEALERS — order page + admin dashboard

- `index.html` — product landing page ("اطلب الآن" buttons lead to the order page)
- `order.html` — wholesale order form. Price, minimum, multiples, wholesale tiers, delivery fees,
  announcement bar, open/closed and Meta Pixel are all read live from Supabase (`settings` table).
- `admin.html` — dashboard: orders (status, tracking, delivery fee, notes, CSV export, delete) + Settings tab.
  Hidden entrance: tap "HEALERS" 5 times on the order page.
- `communes.js` — wilaya → communes
- `supabase/migrations/001_healers.sql` — tables + row-level security
- `supabase/functions/create-order/` — validates every order against the live settings, prices it server-side, alerts Telegram

Supabase project: `healers` (sxijpjfydyhxilekqdvg). Secrets `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` live in Supabase, never here.
Admin logins: username `fouad` / `dex` (= fouad@healers.dz / dex@healers.dz). Change passwords in Settings → My account.
