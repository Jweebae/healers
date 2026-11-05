-- HEALERS: order history, activity log, renumbering, and Mehdi's admin access.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Before running, create Mehdi's login in Authentication -> Users -> Add user
-- (email mehdi@healers.dz, Auto Confirm User ticked).

-- Every change to an order is recorded: who, when, and which fields changed.
create table if not exists public.order_logs (
  id bigint generated always as identity primary key,
  order_id bigint not null,
  action text not null check (action in ('created', 'updated', 'deleted')),
  actor text not null,
  changes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists order_logs_order_idx on public.order_logs (order_id, created_at desc);
create index if not exists order_logs_time_idx on public.order_logs (created_at desc);

alter table public.order_logs enable row level security;
drop policy if exists "admins read logs" on public.order_logs;
create policy "admins read logs" on public.order_logs for select using ((select public.is_admin()));
-- No insert/update/delete policies: only the trigger writes, and nobody can edit history.

create or replace function public.log_order_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  who text := coalesce((select auth.jwt() ->> 'email'), 'website');
  diff jsonb := '{}'::jsonb;
  k text;
begin
  if tg_op = 'INSERT' then
    insert into public.order_logs (order_id, action, actor, changes)
    values (new.id, 'created', who, jsonb_build_object('total_price', new.total_price, 'quantity', new.quantity));
    return new;
  elsif tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(to_jsonb(new)) loop
      if k not in ('updated_at', 'telegram_sent') and (to_jsonb(old) -> k) is distinct from (to_jsonb(new) -> k) then
        diff := diff || jsonb_build_object(k, jsonb_build_object('from', to_jsonb(old) -> k, 'to', to_jsonb(new) -> k));
      end if;
    end loop;
    if diff <> '{}'::jsonb then
      insert into public.order_logs (order_id, action, actor, changes) values (new.id, 'updated', who, diff);
    end if;
    return new;
  else
    -- keep a full copy, so a deleted order can still be looked up
    insert into public.order_logs (order_id, action, actor, changes) values (old.id, 'deleted', who, to_jsonb(old));
    return old;
  end if;
end $$;

drop trigger if exists orders_log on public.orders;
create trigger orders_log after insert or update or delete on public.orders
  for each row execute function public.log_order_change();

-- Lets an admin restart order numbers at #1, but only once every order is deleted.
create or replace function public.reset_order_numbering() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if exists (select 1 from public.orders) then raise exception 'delete every order first'; end if;
  perform setval(pg_get_serial_sequence('public.orders', 'id'), 1, false);
end $$;
revoke all on function public.reset_order_numbering() from public, anon;
grant execute on function public.reset_order_numbering() to authenticated;

-- Mehdi becomes an admin (does nothing if his login hasn't been created yet).
insert into public.admins (user_id)
select id from auth.users where email = 'mehdi@healers.dz'
on conflict do nothing;

select (select count(*) from public.admins) as admins, exists (select 1 from auth.users where email = 'mehdi@healers.dz') as mehdi_login_exists;
