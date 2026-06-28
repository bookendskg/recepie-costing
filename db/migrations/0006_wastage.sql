-- 0006_wastage.sql
-- Operational wastage tracking across outlets (§11–§14). Kept SEPARATE from the
-- Yield Management master data. Mirrors src/lib/data/mock/wastage.ts + the OUTLETS
-- constant in src/lib/data/types.ts.

create table public.outlets (
  id    text primary key,
  brand text not null check (brand in ('capiche','aiko')),
  name  text not null
);
insert into public.outlets (id, brand, name) values
  ('capiche-piplod','capiche','Capiche Piplod'),
  ('capiche-vesu','capiche','Capiche Vesu'),
  ('capiche-ambli','capiche','Capiche Ambli'),
  ('capiche-university','capiche','Capiche University'),
  ('aiko-pal','aiko','Aiko Pal'),
  ('aiko-ambli','aiko','Aiko Ambli')
on conflict (id) do nothing;

create table public.wastage_entries (
  id            uuid primary key default gen_random_uuid(),
  wastage_date  date not null,
  brand         text not null check (brand in ('capiche','aiko')),
  outlet_id     text not null references outlets(id),
  wastage_type  text not null,
  item_type     text not null check (item_type in ('ingredient','recipe')),
  ingredient_id uuid references raw_materials(id) on delete set null,
  recipe_id     uuid references recipes(id) on delete set null,
  quantity      decimal(12,3) not null check (quantity > 0),
  unit          text not null,
  unit_cost     decimal(12,4) not null check (unit_cost >= 0),
  total_cost    decimal(12,2) not null check (total_cost >= 0),
  reason        text,
  department    text not null,
  shift         text,
  entered_by    uuid references users(id),
  approved_by   uuid references users(id),
  notes         text,
  attachment_url text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index wastage_outlet_date_idx on public.wastage_entries (outlet_id, wastage_date);
create index wastage_brand_date_idx  on public.wastage_entries (brand, wastage_date);

alter table public.wastage_entries enable row level security;
create policy "wastage_read" on public.wastage_entries for select using (true);
