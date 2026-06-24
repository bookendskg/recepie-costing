-- Recipe Costing & Food Cost Management System — initial schema.
-- Mirrors PRD §9.2 table specs and §9.3 RLS policies. Authored now as the
-- contract the mock data layer mirrors; executed when the Supabase backend is
-- wired in (see plan "Supabase Swap"). Not run against any DB yet.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table users (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  email       text not null unique,
  role        text not null check (role in ('admin','editor','viewer')),
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table raw_materials (
  id                 uuid primary key default gen_random_uuid(),
  ingredient_name    text not null unique,
  category           text not null,
  supplier_name      text,
  purchase_price     decimal(10,2) check (purchase_price >= 0),
  purchase_quantity  decimal(10,3) not null check (purchase_quantity > 0),
  purchase_unit      text not null,
  base_unit          text not null,
  -- cost_per_base_unit is GENERATED ALWAYS in Postgres; the mock computes it
  -- in calculateCostPerBaseUnit(). Stored as a plain column here for clarity.
  cost_per_base_unit decimal(10,4),
  last_price_update  date,
  status             text not null default 'active' check (status in ('active','inactive')),
  created_by         uuid references users(id),
  created_at         timestamptz not null default now()
);

create table recipes (
  id               uuid primary key default gen_random_uuid(),
  recipe_name      text not null unique,
  category         text not null,
  brand            text not null check (brand in ('capiche','aiko')),
  description      text,
  image_url        text,
  preparation_time integer check (preparation_time > 0),
  serving_size     integer not null check (serving_size > 0),
  status           text not null default 'draft' check (status in ('draft','testing','approved','rejected')),
  total_cost       decimal(10,2),
  cost_per_portion decimal(10,2),
  selling_price    decimal(10,2),
  wastage_pct      decimal(5,2) not null default 0,
  is_prep          boolean not null default false,
  yield_quantity   decimal(10,3) not null default 1,
  yield_unit       text not null default 'Gram',
  created_by       uuid references users(id),
  approved_by      uuid references users(id),
  approved_at      timestamptz,
  rejection_note   text,
  version_no       integer not null default 1,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  updated_by       uuid references users(id)
);

create table recipe_ingredients (
  id              uuid primary key default gen_random_uuid(),
  recipe_id       uuid not null references recipes(id) on delete cascade,
  -- component_type 'material' → ingredient_id references raw_materials(id);
  -- 'recipe' → it references recipes(id) (an in-house prep used as a component).
  ingredient_id   uuid not null,
  component_type  text not null default 'material' check (component_type in ('material','recipe')),
  quantity_used   decimal(10,3) not null check (quantity_used > 0),
  unit_used       text not null,
  calculated_cost decimal(10,2),
  sort_order      integer not null default 0
);

create table recipe_cost_history (
  id                   uuid primary key default gen_random_uuid(),
  recipe_id            uuid references recipes(id) on delete cascade,
  old_total_cost       decimal(10,2),
  new_total_cost       decimal(10,2),
  old_cost_per_portion decimal(10,2),
  new_cost_per_portion decimal(10,2),
  change_reason        text,
  changed_by           uuid references users(id),
  changed_at           timestamptz not null default now()
);

create table ingredient_price_history (
  id                     uuid primary key default gen_random_uuid(),
  ingredient_id          uuid references raw_materials(id) on delete cascade,
  old_price              decimal(10,2),
  new_price              decimal(10,2),
  old_cost_per_base_unit decimal(10,4),
  new_cost_per_base_unit decimal(10,4),
  changed_by             uuid references users(id),
  changed_at             timestamptz not null default now()
);

create table recipe_versions (
  id          uuid primary key default gen_random_uuid(),
  recipe_id   uuid references recipes(id) on delete cascade,
  version_no  integer not null,
  snapshot    jsonb,
  notes       text,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now()
);

create table user_recipe_views (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  recipe_id   uuid not null references recipes(id) on delete cascade,
  view_type   text not null check (view_type in ('capiche','aiko')),
  assigned_by uuid references users(id),
  assigned_at timestamptz not null default now(),
  unique (user_id, recipe_id)
);

create table audit_logs (
  id           uuid primary key default gen_random_uuid(),
  entity_type  text not null,
  entity_id    uuid not null,
  action       text not null,
  old_values   jsonb,
  new_values   jsonb,
  performed_by uuid references users(id),
  performed_at timestamptz not null default now(),
  notes        text
);

create table system_settings (
  id         uuid primary key default gen_random_uuid(),
  key        text not null unique,
  value      text,
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row Level Security (PRD §9.3) — replicated client-side in permissions.ts
-- ---------------------------------------------------------------------------
alter table recipes enable row level security;
alter table raw_materials enable row level security;
alter table audit_logs enable row level security;

-- Viewers see only approved recipes assigned to them.
create policy viewer_recipe_access on recipes
  for select using (
    auth.uid() in (
      select user_id from user_recipe_views where recipe_id = recipes.id
    ) and status = 'approved'
  );

-- Raw materials: only admin/editor.
create policy editor_ingredient_access on raw_materials
  for all using (
    (select role from users where id = auth.uid()) in ('admin','editor')
  );

-- Audit logs: admin only.
create policy admin_only_audit on audit_logs
  for select using (
    (select role from users where id = auth.uid()) = 'admin'
  );
