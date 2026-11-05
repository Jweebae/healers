-- HEALERS magnesium spray: shop settings, orders, admin allow-list, row-level security.
-- Customers never write to the tables directly: the create-order edge function
-- (service role) reads the settings, prices the order and inserts it.
-- Signed-in admins read/update orders and edit the settings from admin.html.

-- ---------- admins ----------
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create function public.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.admins where user_id = (select auth.uid())) $$;

create function public.touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at = now(); return new; end $$;

-- each tier: {"min_qty": int >= 1, "unit_price": int >= 1}, at most 10 tiers
create function public.valid_tiers(t jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select jsonb_typeof(t) = 'array' and jsonb_array_length(t) <= 10 and coalesce((
    select bool_and(
      jsonb_typeof(e->'min_qty') = 'number' and jsonb_typeof(e->'unit_price') = 'number'
      and (e->>'min_qty')::numeric = floor((e->>'min_qty')::numeric)
      and (e->>'unit_price')::numeric = floor((e->>'unit_price')::numeric)
      and (e->>'min_qty')::numeric between 1 and 100000
      and (e->>'unit_price')::numeric between 1 and 1000000)
    from jsonb_array_elements(t) e), true)
$$;

-- ---------- settings (one row, id = 1) ----------
create table public.settings (
  id              smallint primary key default 1 check (id = 1),
  updated_at      timestamptz not null default now(),
  product_name    text    not null default 'زيت المغنيسيوم HEALERS' check (char_length(product_name) between 2 and 80),
  pack_label      text    not null default 'بخاخ 250 مل'           check (char_length(pack_label) <= 60),
  unit_price      integer not null default 1200 check (unit_price between 1 and 1000000),
  old_price       integer          check (old_price is null or old_price between 1 and 1000000),
  min_qty         integer not null default 12   check (min_qty between 1 and 100000),
  max_qty         integer not null default 2000 check (max_qty between 1 and 100000),
  step_qty        integer not null default 1    check (step_qty between 1 and 1000),
  -- quantity discounts: [{"min_qty": 48, "unit_price": 1100}, ...]
  tiers           jsonb   not null default '[]'::jsonb check (public.valid_tiers(tiers)),
  -- delivery in DA: null = set at confirmation, 0 = free
  delivery_home   integer          check (delivery_home is null or delivery_home between 0 and 100000),
  delivery_desk   integer          check (delivery_desk is null or delivery_desk between 0 and 100000),
  orders_open     boolean not null default true,
  closed_message  text    not null default 'الطلبات متوقفة مؤقتاً، عد قريباً.' check (char_length(closed_message) <= 300),
  announcement    text    not null default '' check (char_length(announcement) <= 200),
  meta_pixel_id   text    not null default '' check (meta_pixel_id ~ '^[0-9]{0,20}$'),
  constraint min_le_max check (min_qty <= max_qty)
);
insert into public.settings (id) values (1);

create trigger settings_touch before update on public.settings
for each row execute function public.touch_updated_at();

-- ---------- orders ----------
create table public.orders (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  customer_name   text not null check (char_length(customer_name) between 3 and 100),
  business_name   text not null default '' check (char_length(business_name) <= 100),
  phone           text not null check (phone ~ '^0[567][0-9]{8}$'),
  wilaya          text not null check (char_length(wilaya) between 4 and 60),
  commune         text not null check (char_length(commune) between 2 and 60),
  delivery_type   text not null check (delivery_type in ('home', 'desk')),
  address         text not null default '' check (char_length(address) <= 300),
  quantity        integer not null check (quantity between 1 and 100000),
  unit_price      integer not null,
  items_total     integer not null,
  delivery_fee    integer,            -- null = to be set at confirmation
  total_price     integer not null,   -- items_total + delivery_fee (if known)
  customer_note   text not null default '' check (char_length(customer_note) <= 300),
  status          text not null default 'new'
                  check (status in ('new', 'no_answer', 'confirmed', 'shipped', 'delivered', 'returned', 'cancelled')),
  tracking_number text,
  notes           text,
  telegram_sent   boolean not null default false
);
create index orders_created_at_idx on public.orders (created_at desc);
create index orders_phone_idx on public.orders (phone, created_at desc);

create trigger orders_touch before update on public.orders
for each row execute function public.touch_updated_at();

-- ---------- row-level security ----------
alter table public.admins   enable row level security;   -- no policies: only is_admin() reads it
alter table public.settings enable row level security;
alter table public.orders   enable row level security;

create policy "anyone reads settings" on public.settings
  for select to anon, authenticated using (true);
create policy "admins update settings" on public.settings
  for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "admins read orders" on public.orders
  for select to authenticated using ((select public.is_admin()));
create policy "admins update orders" on public.orders
  for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "admins delete orders" on public.orders
  for delete to authenticated using ((select public.is_admin()));

revoke all on public.orders, public.admins, public.settings from anon, authenticated;
grant select on public.settings to anon, authenticated;
grant update (product_name, pack_label, unit_price, old_price, min_qty, max_qty, step_qty, tiers,
              delivery_home, delivery_desk, orders_open, closed_message, announcement, meta_pixel_id)
  on public.settings to authenticated;
grant select, update, delete on public.orders to authenticated;

revoke execute on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
