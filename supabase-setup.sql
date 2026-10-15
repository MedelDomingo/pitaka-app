-- Pitaka Budget: Supabase setup
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run again; it won't delete your records.
--
-- How it's protected: the tables can't be read or written directly from the app.
-- Everything goes through pitaka_sync(), which only answers when given a valid
-- household key. The key itself isn't stored, only its SHA-256 hash.

create table if not exists public.pitaka_households (
  id bigint generated always as identity primary key,
  key_hash text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.pitaka_tx (
  household_id bigint not null references public.pitaka_households(id) on delete cascade,
  id text not null,
  type text not null check (type in ('expense', 'income')),
  amount numeric(14,2) not null check (amount > 0),
  cat text not null,
  note text not null default '',
  date text not null,
  ts bigint not null,
  by_name text not null default '',
  mtime bigint not null,
  deleted boolean not null default false,
  updated_at bigint not null,
  primary key (household_id, id)
);
create index if not exists pitaka_tx_updated on public.pitaka_tx (household_id, updated_at);

create table if not exists public.pitaka_settings (
  household_id bigint not null references public.pitaka_households(id) on delete cascade,
  k text not null,
  v jsonb not null,
  mtime bigint not null,
  updated_at bigint not null,
  primary key (household_id, k)
);

-- Lock the tables: RLS on with no policies, and no table grants for app roles.
alter table public.pitaka_households enable row level security;
alter table public.pitaka_tx enable row level security;
alter table public.pitaka_settings enable row level security;
revoke all on public.pitaka_households, public.pitaka_tx, public.pitaka_settings from anon, authenticated;

create or replace function public.pitaka_sync(
  p_key text,
  p_since bigint default 0,
  p_changes jsonb default '[]'::jsonb,
  p_budgets jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  hid bigint;
  now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  c jsonb;
  res_tx jsonb;
  res_b jsonb;
begin
  select h.id into hid from pitaka_households h
   where h.key_hash = encode(sha256(convert_to(upper(trim(coalesce(p_key, ''))), 'UTF8')), 'hex');
  if hid is null then
    perform pg_sleep(0.5);
    raise exception 'bad_key' using errcode = 'PT401';
  end if;

  if jsonb_typeof(p_changes) = 'array' then
    for c in select value from jsonb_array_elements(p_changes) limit 1000 loop
      continue when jsonb_typeof(c) <> 'object';
      continue when coalesce(c->>'id', '') !~ '^[a-z0-9]{6,40}$';
      continue when coalesce(c->>'type', '') not in ('expense', 'income');
      continue when coalesce(c->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$';
      continue when jsonb_typeof(c->'amount') is distinct from 'number';
      continue when (c->>'amount')::numeric <= 0 or (c->>'amount')::numeric >= 1e10;
      continue when jsonb_typeof(c->'mtime') is distinct from 'number' or (c->>'mtime')::numeric <= 0;

      insert into pitaka_tx as t (household_id, id, type, amount, cat, note, date, ts, by_name, mtime, deleted, updated_at)
      values (
        hid, c->>'id', c->>'type', round((c->>'amount')::numeric, 2),
        left(coalesce(nullif(trim(c->>'cat'), ''), 'Others'), 40),
        left(trim(coalesce(c->>'note', '')), 200),
        c->>'date',
        case when jsonb_typeof(c->'ts') = 'number' then (c->>'ts')::numeric::bigint else (c->>'mtime')::numeric::bigint end,
        left(trim(coalesce(c->>'by', '')), 40),
        (c->>'mtime')::numeric::bigint,
        coalesce(c->'deleted' in ('true'::jsonb, '1'::jsonb), false),
        now_ms
      )
      on conflict (household_id, id) do update set
        type = excluded.type, amount = excluded.amount, cat = excluded.cat, note = excluded.note,
        date = excluded.date, ts = excluded.ts, by_name = excluded.by_name, mtime = excluded.mtime,
        deleted = excluded.deleted, updated_at = excluded.updated_at
      where t.mtime <= excluded.mtime;   -- newer edit wins
    end loop;
  end if;

  if jsonb_typeof(p_budgets) = 'object'
     and jsonb_typeof(p_budgets->'v') = 'object'
     and length((p_budgets->'v')::text) < 4000
     and jsonb_typeof(p_budgets->'mtime') = 'number' then
    insert into pitaka_settings as s (household_id, k, v, mtime, updated_at)
    values (hid, 'budgets', p_budgets->'v', (p_budgets->>'mtime')::numeric::bigint, now_ms)
    on conflict (household_id, k) do update set
      v = excluded.v, mtime = excluded.mtime, updated_at = excluded.updated_at
    where s.mtime <= excluded.mtime;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'type', t.type, 'amount', t.amount, 'cat', t.cat, 'note', t.note,
           'date', t.date, 'ts', t.ts, 'by', t.by_name, 'mtime', t.mtime,
           'deleted', case when t.deleted then 1 else 0 end) order by t.updated_at), '[]'::jsonb)
    into res_tx
    from pitaka_tx t
   where t.household_id = hid and t.updated_at > greatest(coalesce(p_since, 0), 0);

  select jsonb_build_object('v', s.v, 'mtime', s.mtime) into res_b
    from pitaka_settings s
   where s.household_id = hid and s.k = 'budgets' and s.updated_at > greatest(coalesce(p_since, 0), 0);

  return jsonb_build_object('now', now_ms, 'tx', res_tx, 'budgets', res_b);
end;
$$;

revoke all on function public.pitaka_sync(text, bigint, jsonb, jsonb) from public;
grant execute on function public.pitaka_sync(text, bigint, jsonb, jsonb) to anon, authenticated;

-- Your household. Only the SHA-256 hash of the household key is here, so this
-- file is safe to keep in a public repo. To add or change a key, run in SQL Editor:
--   insert into public.pitaka_households (key_hash)
--   values (encode(sha256(convert_to('YOUR-NEW-KEY', 'UTF8')), 'hex'));
insert into public.pitaka_households (key_hash)
values ('a74bffd5a26138f46ff9cf3713b216b82ef527d8b516b5d771834dff6ae10ac8')
on conflict (key_hash) do nothing;
