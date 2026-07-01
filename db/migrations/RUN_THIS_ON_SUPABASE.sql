-- RUN_THIS_ON_SUPABASE.sql — COMPLETE one-shot Supabase setup (auth + data + catalogue).
-- Safe to run on ANY state: fresh project, half-migrated, or already set up.
-- Idempotent (if-not-exists + drop-then-create) and wrapped in ONE transaction.
-- Do NOT run the numbered 0001..0011 files separately; this file replaces them.
-- Prerequisite: Supabase Dashboard > Authentication > Providers > Email = ON.

begin;
-- Recipe Costing & Food Cost Management System — initial schema.
-- Mirrors PRD §9.2 table specs and §9.3 RLS policies. Authored now as the
-- contract the mock data layer mirrors; executed when the Supabase backend is
-- wired in (see plan "Supabase Swap"). Not run against any DB yet.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists users (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  email       text not null unique,
  role        text not null check (role in ('super_admin','admin','editor','head_chef','chef','viewer')),
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists raw_materials (
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

create table if not exists recipes (
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

create table if not exists recipe_ingredients (
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

create table if not exists recipe_cost_history (
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

create table if not exists ingredient_price_history (
  id                     uuid primary key default gen_random_uuid(),
  ingredient_id          uuid references raw_materials(id) on delete cascade,
  old_price              decimal(10,2),
  new_price              decimal(10,2),
  old_cost_per_base_unit decimal(10,4),
  new_cost_per_base_unit decimal(10,4),
  changed_by             uuid references users(id),
  changed_at             timestamptz not null default now()
);

create table if not exists recipe_versions (
  id          uuid primary key default gen_random_uuid(),
  recipe_id   uuid references recipes(id) on delete cascade,
  version_no  integer not null,
  snapshot    jsonb,
  notes       text,
  created_by  uuid references users(id),
  created_at  timestamptz not null default now()
);

create table if not exists user_recipe_views (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  recipe_id   uuid not null references recipes(id) on delete cascade,
  view_type   text not null check (view_type in ('capiche','aiko')),
  assigned_by uuid references users(id),
  assigned_at timestamptz not null default now(),
  unique (user_id, recipe_id)
);

create table if not exists audit_logs (
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

create table if not exists system_settings (
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
-- 0004_packaging_cost.sql
-- Adds a per-portion packaging cost to recipes (box/container), layered on top of
-- the food cost when computing food-cost %, margin, and profit. Defaults to 0 so
-- existing recipes and costing are unchanged.

alter table public.recipes
  add column if not exists packaging_cost decimal(10,2) not null default 0
    check (packaging_cost >= 0);
-- 0005_ingredient_yields.sql
-- Standard yield (preparation-loss) data per ingredient. The full purchase cost
-- is distributed across the USABLE quantity → yield_adjusted_unit_cost. This is
-- the contract the mock/localStorage layer (src/lib/data/mock/yields.ts) mirrors.

create table if not exists public.ingredient_yields (
  id                       uuid primary key default gen_random_uuid(),
  ingredient_id            uuid not null references raw_materials(id) on delete cascade,
  purchase_cost            decimal(10,2) not null check (purchase_cost >= 0),
  purchase_quantity        decimal(10,3) not null check (purchase_quantity > 0),
  purchase_unit            text not null,
  raw_quantity             decimal(12,3) not null check (raw_quantity > 0),
  raw_unit                 text not null,
  wastage_quantity         decimal(12,3) not null check (wastage_quantity >= 0),
  wastage_unit             text not null,
  usable_quantity          decimal(12,3) not null check (usable_quantity > 0),
  wastage_percentage       decimal(5,2)  not null,
  yield_percentage         decimal(5,2)  not null,
  original_unit_cost       decimal(12,6) not null,
  yield_adjusted_unit_cost decimal(12,6) not null,
  effective_from           date not null default current_date,
  notes                    text,
  created_by               uuid references users(id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  -- Wastage can never reach or exceed the raw quantity (usable must stay > 0).
  constraint wastage_below_raw check (wastage_quantity < raw_quantity),
  -- One yield record per ingredient per effective date.
  unique (ingredient_id, effective_from)
);

create index if not exists ingredient_yields_ingredient_idx on public.ingredient_yields (ingredient_id);

alter table public.ingredient_yields enable row level security;
-- Staff (admin/editor) manage yield; everyone authenticated may read.
create policy "ingredient_yields_read" on public.ingredient_yields for select using (true);
-- 0006_wastage.sql
-- Operational wastage tracking across outlets (§11–§14). Kept SEPARATE from the
-- Yield Management master data. Mirrors src/lib/data/mock/wastage.ts + the OUTLETS
-- constant in src/lib/data/types.ts.

create table if not exists public.outlets (
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

create table if not exists public.wastage_entries (
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

create index if not exists wastage_outlet_date_idx on public.wastage_entries (outlet_id, wastage_date);
create index if not exists wastage_brand_date_idx  on public.wastage_entries (brand, wastage_date);

alter table public.wastage_entries enable row level security;
create policy "wastage_read" on public.wastage_entries for select using (true);
-- 0007_user_profiles.sql — user profiles for SUPABASE AUTH (Phase 1).
--
-- Auth is Supabase (email/password). Each profile row is keyed on auth.users(id),
-- so RLS uses the native auth.uid(). A row is auto-created on sign-up by the
-- handle_new_user trigger (role 'viewer', approved=false → pending). The on_sign_in()
-- RPC stamps last_login, mirrors email-verification from auth.users, and promotes
-- VERIFIED owner emails to Admin. Re-runnable.
--
-- PREREQUISITES (Supabase dashboard, once):
--   • Authentication → Providers → Email = enabled.
--   • (Optional) turn "Confirm email" on/off per your preference.
--   • Run 0001..0006 if you want the rest of the schema; this file is self-contained
--     for the users feature (only needs auth + gen_random_uuid).
--
-- This supersedes the legacy public.profiles (0002); that table is left untouched/unused.

do $$ begin
  create type app_role as enum ('super_admin','admin','editor','head_chef','chef','viewer');
exception when duplicate_object then null; end $$;
-- Existing DBs (enum already created without super_admin): add the value. Safe/idempotent.
-- NOTE: if this file is run inside a single transaction on an OLD database, run this one
-- line by itself FIRST (Postgres can't use a newly-added enum value later in the same tx).
alter type app_role add value if not exists 'super_admin';

do $$ begin
  create type app_account_status as enum ('active','inactive');
exception when duplicate_object then null; end $$;

create table if not exists public.user_profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  email             text not null,
  name              text not null default '',
  role              app_role not null default 'viewer',
  status            app_account_status not null default 'active',
  approved          boolean not null default false,   -- self sign-ups start unapproved
  email_verified    boolean not null default false,
  phone             text,
  avatar_url        text,
  assigned_brand    text check (assigned_brand in ('capiche','aiko')),
  assigned_outlet   text,
  accessible_brands text[],
  show_cost         boolean,
  dashboard_access  boolean not null default false,
  theme_pref        text,
  last_login        timestamptz,
  last_role_update  timestamptz,
  role_updated_by   text,
  created_by        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.user_profiles enable row level security;

-- Recursion-safe admin check.
create or replace function public.is_app_admin()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from public.user_profiles
    where id = auth.uid() and role = 'admin' and status = 'active'
  )
$$;

-- ── RLS ──
drop policy if exists user_profiles_select        on public.user_profiles;
drop policy if exists user_profiles_insert_admin  on public.user_profiles;
drop policy if exists user_profiles_update_admin  on public.user_profiles;
drop policy if exists user_profiles_update_own    on public.user_profiles;
drop policy if exists user_profiles_no_delete     on public.user_profiles;

create policy user_profiles_select on public.user_profiles
  for select to authenticated
  using (id = auth.uid() or public.is_app_admin());

create policy user_profiles_insert_admin on public.user_profiles
  for insert to authenticated
  with check (public.is_app_admin());

create policy user_profiles_update_admin on public.user_profiles
  for update to authenticated
  using (public.is_app_admin()) with check (public.is_app_admin());

-- NOTE: there is intentionally NO broad "update your own row" policy. A non-admin
-- editing their profile goes through update_own_profile() (safe columns only), so
-- role/status/approval/scope can never be touched on a self-update at the RLS layer
-- — not merely caught by a trigger after the fact.

-- No client deletes (deactivate via status='inactive').
create policy user_profiles_no_delete on public.user_profiles
  for delete to authenticated using (false);

-- ── Guard triggers (§28) ──

-- A non-admin cannot escalate their own role/status/approval/scope.
create or replace function public.prevent_profile_self_escalation()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  -- Defense-in-depth behind update_own_profile(): a non-admin can never change any
  -- privileged field on their own row, even if a future policy exposes the table.
  if new.id = auth.uid() and not public.is_app_admin()
     and row(new.role, new.status, new.approved, new.assigned_brand, new.assigned_outlet, new.dashboard_access)
         is distinct from
         row(old.role, old.status, old.approved, old.assigned_brand, old.assigned_outlet, old.dashboard_access) then
    raise exception 'cannot change your own role/status/approval/scope';
  end if;
  return new;
end $$;

drop trigger if exists trg_user_profiles_no_self_escalation on public.user_profiles;
create trigger trg_user_profiles_no_self_escalation
  before update on public.user_profiles
  for each row execute function public.prevent_profile_self_escalation();

-- Never demote/disable the last active Admin (advisory-locked against races).
create or replace function public.prevent_last_admin_removal()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.role = 'admin' and old.status = 'active'
     and (new.role <> 'admin' or new.status <> 'active') then
    perform pg_advisory_xact_lock(hashtext('user_profiles_last_admin'));
    if (select count(*) from public.user_profiles where role = 'admin' and status = 'active') <= 1 then
      raise exception 'cannot remove the last remaining Admin';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_user_profiles_last_admin on public.user_profiles;
create trigger trg_user_profiles_last_admin
  before update on public.user_profiles
  for each row execute function public.prevent_last_admin_removal();

-- Touch updated_at + stamp role-change history.
create or replace function public.user_profiles_touch()
returns trigger language plpgsql
set search_path = public as $$
begin
  new.updated_at = now();
  if new.role is distinct from old.role then
    new.last_role_update = now();
  end if;
  return new;
end $$;

drop trigger if exists trg_user_profiles_touch on public.user_profiles;
create trigger trg_user_profiles_touch
  before update on public.user_profiles
  for each row execute function public.user_profiles_touch();

-- ── Auto-create a profile when a Supabase auth user is created ──
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.user_profiles (id, email, name, email_verified)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'name', split_part(coalesce(new.email,''), '@', 1)),
    coalesce(new.email_confirmed_at is not null, false)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── Sign-in RPC ──
-- Called by the app after a successful sign-in. Reads the trusted email +
-- confirmation from auth.users (SECURITY DEFINER), stamps last_login, mirrors
-- email_verified, auto-promotes a VERIFIED owner email to Admin, and self-heals a
-- missing profile row. Returns the profile.
create or replace function public.on_sign_in()
returns public.user_profiles
language plpgsql security definer set search_path = public as $$
declare
  v_email     text;
  v_confirmed boolean;
  v_owner     boolean;
  v_row       public.user_profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  -- Serialize concurrent sign-ins for the same user (owner promotion + stamping).
  perform pg_advisory_xact_lock(hashtext('on_sign_in_' || auth.uid()::text));
  select email, (email_confirmed_at is not null) into v_email, v_confirmed
    from auth.users where id = auth.uid();
  v_owner := coalesce(v_confirmed,false) and lower(coalesce(v_email,'')) in
    ('reservation.bookends@gmail.com','moin.bookends@gmail.com');

  update public.user_profiles set
    last_login     = now(),
    email_verified = coalesce(v_confirmed,false),
    role           = case when v_owner then 'super_admin'::app_role else role end,
    approved       = case when v_owner then true else approved end
  where id = auth.uid()
  returning * into v_row;

  if not found then
    insert into public.user_profiles (id, email, name, role, approved, email_verified, last_login)
    values (
      auth.uid(), coalesce(v_email,''), split_part(coalesce(v_email,''), '@', 1),
      case when v_owner then 'super_admin'::app_role else 'viewer'::app_role end,
      v_owner, coalesce(v_confirmed,false), now()
    )
    returning * into v_row;
  end if;

  if v_row.status = 'inactive' then
    raise exception 'Your account has been disabled. Please contact an administrator.';
  end if;
  return v_row;
end $$;

grant execute on function public.on_sign_in() to authenticated;

-- ── Safe self-edit RPC ──
-- The only way a non-admin can write to their own row: updates display fields only
-- (name/phone/avatar/theme). Role/status/approval/scope are untouchable here.
create or replace function public.update_own_profile(
  p_name       text default null,
  p_phone      text default null,
  p_avatar_url text default null,
  p_theme_pref text default null
)
returns public.user_profiles
language plpgsql security definer set search_path = public as $$
declare v_row public.user_profiles;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.user_profiles set
    name       = coalesce(p_name, name),
    phone      = coalesce(p_phone, phone),
    avatar_url = coalesce(p_avatar_url, avatar_url),
    theme_pref = coalesce(p_theme_pref, theme_pref)
  where id = auth.uid()
  returning * into v_row;
  if not found then raise exception 'profile not found'; end if;
  return v_row;
end $$;

grant execute on function public.update_own_profile(text, text, text, text) to authenticated;

-- ── One-time bootstrap (optional) ──
-- Owners auto-promote (once their email is confirmed) via on_sign_in(). To promote
-- anyone else: update public.user_profiles set role='admin', approved=true,
--   status='active' where lower(email)='someone@example.com';
-- 0008_data_layer.sql — Phase 2: bring the data tables in line with the current app
-- and move authorization onto Supabase RLS keyed to public.user_profiles (0007).
--
-- Run AFTER 0001, 0004, 0005, 0006 and 0007. Re-runnable. Assumes Supabase Auth
-- (0007). The legacy public.users table from 0001 is no longer used — actor columns
-- (created_by/updated_by/etc.) now hold the Supabase auth uid, so we drop their FKs
-- to public.users.

-- ── 1. Schema alignment (columns added this session) ───────────────────────
alter table public.recipes
  add column if not exists method            text[] not null default '{}',
  add column if not exists parent_recipe_id  uuid references public.recipes(id) on delete set null,
  add column if not exists size_code         text check (size_code in ('11_INCH','15_INCH')),
  add column if not exists size_label        text;

alter table public.raw_materials
  add column if not exists notes text;

alter table public.recipe_ingredients
  add column if not exists wastage_override_pct decimal(5,2),
  add column if not exists cut_type             text;

alter table public.wastage_entries
  add column if not exists done_by text;

-- audit_logs.entity_id holds app entity ids INCLUDING non-uuid markers (e.g. the
-- literal 'import' for bulk operations), so it must be text, not uuid.
alter table public.audit_logs alter column entity_id type text using entity_id::text;

create index if not exists recipes_parent_idx on public.recipes (parent_recipe_id);

-- ── 2. Drop legacy FKs to public.users (actor columns now hold auth uids) ───
do $$
declare r record;
begin
  for r in
    select conname, conrelid::regclass as tbl
    from pg_constraint
    where contype = 'f'
      and confrelid = 'public.users'::regclass
  loop
    execute format('alter table %s drop constraint if exists %I', r.tbl, r.conname);
  end loop;
exception when undefined_table then
  null; -- public.users may not exist on a fresh Supabase project
end $$;

-- ── 3. Authorization helpers (SECURITY DEFINER → no RLS recursion) ─────────
create or replace function public.app_role()
returns text language sql security definer stable set search_path = public as $$
  select role::text from public.user_profiles where id = auth.uid()
$$;

-- Materials + yields (pricing) are admin/editor only.
create or replace function public.can_write_catalog()
returns boolean language sql security definer stable set search_path = public as $$
  select public.app_role() in ('super_admin','admin','editor')
$$;

-- Recipes may also be edited by Head Chef (not ingredient pricing).
create or replace function public.can_edit_recipes()
returns boolean language sql security definer stable set search_path = public as $$
  select public.app_role() in ('super_admin','admin','editor','head_chef')
$$;

-- Operational (wastage) data: admin/editor/head_chef.
create or replace function public.can_access_outlet(p_outlet text)
returns boolean language sql security definer stable set search_path = public as $$
  select public.app_role() in ('super_admin','admin','editor','head_chef')
$$;

-- Brands a viewer may see (mirrors viewerBrands()): null accessible_brands = all.
create or replace function public.viewer_can_see_brand(p_brand text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid()
      and (up.accessible_brands is null or p_brand = any(up.accessible_brands))
  )
$$;

-- ── 4. RLS: raw_materials ──────────────────────────────────────────────────
alter table public.raw_materials enable row level security;
drop policy if exists editor_ingredient_access on public.raw_materials;
drop policy if exists raw_materials_read  on public.raw_materials;
drop policy if exists raw_materials_write on public.raw_materials;
create policy raw_materials_read  on public.raw_materials for select to authenticated using (true);
create policy raw_materials_write on public.raw_materials for all    to authenticated
  using (public.can_write_catalog()) with check (public.can_write_catalog());

-- ── 5. RLS: recipes ────────────────────────────────────────────────────────
alter table public.recipes enable row level security;
drop policy if exists viewer_recipe_access on public.recipes;
drop policy if exists recipes_read  on public.recipes;
drop policy if exists recipes_write on public.recipes;
-- Staff roles see everything; viewer/chef see only approved recipes in their brands.
create policy recipes_read on public.recipes for select to authenticated using (
  public.app_role() in ('super_admin','admin','editor','head_chef')
  or (public.app_role() in ('viewer','chef') and status = 'approved' and public.viewer_can_see_brand(brand))
);
create policy recipes_write on public.recipes for all to authenticated
  using (public.can_edit_recipes()) with check (public.can_edit_recipes());

-- ── 6. RLS: recipe_ingredients (follow the parent recipe's authority) ──────
alter table public.recipe_ingredients enable row level security;
drop policy if exists recipe_ingredients_read  on public.recipe_ingredients;
drop policy if exists recipe_ingredients_write on public.recipe_ingredients;
create policy recipe_ingredients_read on public.recipe_ingredients for select to authenticated using (true);
create policy recipe_ingredients_write on public.recipe_ingredients for all to authenticated
  using (public.can_edit_recipes()) with check (public.can_edit_recipes());

-- ── 7. RLS: ingredient_yields ──────────────────────────────────────────────
alter table public.ingredient_yields enable row level security;
drop policy if exists "ingredient_yields_read" on public.ingredient_yields;
drop policy if exists ingredient_yields_read   on public.ingredient_yields;
drop policy if exists ingredient_yields_write  on public.ingredient_yields;
create policy ingredient_yields_read  on public.ingredient_yields for select to authenticated using (true);
create policy ingredient_yields_write on public.ingredient_yields for all to authenticated
  using (public.can_write_catalog()) with check (public.can_write_catalog());

-- ── 8. RLS: outlets (master data — read-only to clients) ───────────────────
alter table public.outlets enable row level security;
drop policy if exists outlets_read on public.outlets;
create policy outlets_read on public.outlets for select to authenticated using (true);

-- ── 9. RLS: wastage_entries (outlet-scoped) ────────────────────────────────
alter table public.wastage_entries enable row level security;
drop policy if exists "wastage_read" on public.wastage_entries;
drop policy if exists wastage_read    on public.wastage_entries;
drop policy if exists wastage_insert  on public.wastage_entries;
drop policy if exists wastage_update  on public.wastage_entries;
drop policy if exists wastage_delete  on public.wastage_entries;
create policy wastage_read   on public.wastage_entries for select to authenticated
  using (public.can_access_outlet(outlet_id));
create policy wastage_insert on public.wastage_entries for insert to authenticated
  with check (public.app_role() in ('super_admin','admin','editor','head_chef'));
create policy wastage_update on public.wastage_entries for update to authenticated
  using (public.can_access_outlet(outlet_id)) with check (public.can_access_outlet(outlet_id));
create policy wastage_delete on public.wastage_entries for delete to authenticated
  using (public.app_role() in ('super_admin','admin','editor'));

-- ── 10. RLS: history / versions / audit / settings ─────────────────────────
alter table public.recipe_cost_history     enable row level security;
alter table public.ingredient_price_history enable row level security;
alter table public.recipe_versions          enable row level security;
alter table public.audit_logs                enable row level security;
alter table public.system_settings           enable row level security;
alter table public.user_recipe_views         enable row level security;

drop policy if exists recipe_cost_history_rw on public.recipe_cost_history;
create policy recipe_cost_history_rw on public.recipe_cost_history for all to authenticated
  using (true) with check (public.can_edit_recipes());

drop policy if exists ingredient_price_history_rw on public.ingredient_price_history;
create policy ingredient_price_history_rw on public.ingredient_price_history for all to authenticated
  using (true) with check (public.can_write_catalog());

drop policy if exists recipe_versions_rw on public.recipe_versions;
create policy recipe_versions_rw on public.recipe_versions for all to authenticated
  using (true) with check (public.can_edit_recipes());

drop policy if exists admin_only_audit on public.audit_logs;
drop policy if exists audit_read   on public.audit_logs;
drop policy if exists audit_insert on public.audit_logs;
-- Admins read the audit trail; any authenticated action may append to it.
create policy audit_read   on public.audit_logs for select to authenticated using (public.app_role() in ('super_admin','admin'));
create policy audit_insert on public.audit_logs for insert to authenticated with check (true);

drop policy if exists settings_read  on public.system_settings;
drop policy if exists settings_write on public.system_settings;
create policy settings_read  on public.system_settings for select to authenticated using (true);
create policy settings_write on public.system_settings for all to authenticated
  using (public.app_role() in ('super_admin','admin')) with check (public.app_role() in ('super_admin','admin'));

drop policy if exists user_recipe_views_read  on public.user_recipe_views;
drop policy if exists user_recipe_views_write on public.user_recipe_views;
create policy user_recipe_views_read on public.user_recipe_views for select to authenticated
  using (user_id = auth.uid() or public.can_edit_recipes());
create policy user_recipe_views_write on public.user_recipe_views for all to authenticated
  using (public.can_edit_recipes()) with check (public.can_edit_recipes());
-- 0010_export_history.sql
-- §9 Export audit: one row per successful PDF / Excel / CSV export. Exporter identity
-- and timestamp are snapshotted at export time. Mirrors src/lib/data/types.ts
-- (ExportHistory) + src/lib/data/mock/exports.ts. The id is client-generated so the
-- app can upsert idempotently (ignore duplicates) and never log the same export twice.

create table if not exists public.export_history (
  id                      uuid primary key,
  exported_by_user_id     uuid references users(id) on delete set null,
  exporter_name_snapshot  text not null,
  exporter_email_snapshot text,
  exporter_role_snapshot  text not null check (exporter_role_snapshot in ('super_admin','admin','editor','head_chef','chef','viewer')),
  export_type             text not null,
  entity_type             text not null check (entity_type in ('recipe','report')),
  entity_id               uuid,
  recipe_name_snapshot    text,
  report_name             text,
  brand_id                text check (brand_id in ('capiche','aiko')),
  outlet_id               text,
  filters_used            text,
  file_format             text not null check (file_format in ('pdf','csv','xlsx')),
  exported_at             timestamptz not null default now(),
  timezone                text not null default 'Asia/Kolkata',
  status                  text not null default 'success' check (status in ('success','failed'))
);

create index if not exists export_history_exported_at_idx on public.export_history (exported_at desc);
create index if not exists export_history_user_idx        on public.export_history (exported_by_user_id);

alter table public.export_history enable row level security;
-- Any authenticated user may insert their own export rows; admins read all.
drop policy if exists "export_history_insert" on public.export_history;
create policy "export_history_insert" on public.export_history
  for insert with check (auth.uid() = exported_by_user_id or exported_by_user_id is null);
-- Admins read all; every user may read their own export rows.
drop policy if exists "export_history_read_admin" on public.export_history;
create policy "export_history_read_admin" on public.export_history
  for select using (
    exported_by_user_id = auth.uid()
    or exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role = 'admin')
  );
-- 0011_recipe_access_links.sql
-- §11–§19 Temporary, read-only recipe share links. Only the SHA-256 hash of the token
-- is stored (never the raw token). Expiry (30 min) + revocation must be enforced when
-- the token is resolved. Mirrors src/lib/data/types.ts (RecipeAccessLink) +
-- src/lib/data/mock/accessLinks.ts.
--
-- Public resolution (an unauthenticated visitor opening /share/:token) must go through
-- a SECURITY DEFINER function / edge function that: looks the row up by token_hash,
-- rejects expired/revoked links, strips all financial columns, increments access_count,
-- and returns only the recipe payload. Direct table SELECT stays admin-only via RLS.

create table if not exists public.recipe_access_links (
  id                   uuid primary key,
  token_hash           text not null unique,
  recipe_id            uuid not null references recipes(id) on delete cascade,
  granted_by_user_id   uuid references users(id) on delete set null,
  granted_by_name      text not null,
  granted_by_role      text not null check (granted_by_role in ('super_admin','admin','editor','head_chef','chef','viewer')),
  granted_to_user_id   uuid references users(id) on delete set null,
  granted_to_email     text,
  granted_to_role      text check (granted_to_role in ('super_admin','admin','editor','head_chef','chef','viewer')),
  granted_to_brand_id  text check (granted_to_brand_id in ('capiche','aiko')),
  granted_to_outlet_id text,
  access_type          text not null check (access_type in ('READ_ONLY','DOWNLOAD_PDF','VIEW_AND_DOWNLOAD')),
  created_at           timestamptz not null default now(),
  expires_at           timestamptz not null,
  revoked_at           timestamptz,
  revoked_by_user_id   uuid references users(id) on delete set null,
  last_accessed_at     timestamptz,
  access_count         integer not null default 0,
  status               text not null default 'ACTIVE' check (status in ('ACTIVE','EXPIRED','REVOKED'))
);

create index if not exists access_links_token_idx  on public.recipe_access_links (token_hash);
create index if not exists access_links_recipe_idx on public.recipe_access_links (recipe_id);

alter table public.recipe_access_links enable row level security;
-- Direct reads are admin-only (public visitors go through the resolver function, not SELECT).
drop policy if exists "access_links_admin_read" on public.recipe_access_links;
create policy "access_links_admin_read" on public.recipe_access_links
  for select using (
    exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role = 'admin')
  );
drop policy if exists "access_links_grantor_manage" on public.recipe_access_links;
create policy "access_links_grantor_manage" on public.recipe_access_links
  for all using (auth.uid() = granted_by_user_id) with check (auth.uid() = granted_by_user_id);

-- Server-side token resolver. A SECURITY DEFINER function is the ONLY way a public
-- (anon) visitor reads a shared recipe: it hashes the raw token, enforces expiry +
-- revocation on the server, strips every financial column, increments the access
-- counter, and returns just the read-only recipe payload. Direct SELECT stays blocked
-- by RLS, so expiry can never be bypassed from the client.
create extension if not exists pgcrypto;

create or replace function public.resolve_share_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash   text := encode(digest(p_token, 'sha256'), 'hex');
  v_link   public.recipe_access_links%rowtype;
  v_recipe public.recipes%rowtype;
  v_status text;
begin
  select * into v_link from public.recipe_access_links where token_hash = v_hash;
  if not found then
    return jsonb_build_object('status', 'REVOKED'); -- unknown/tampered token → unusable
  end if;

  if v_link.revoked_at is not null then
    v_status := 'REVOKED';
  elsif v_link.expires_at <= now() then
    v_status := 'EXPIRED';
  else
    v_status := 'ACTIVE';
  end if;

  update public.recipe_access_links set status = v_status where id = v_link.id;
  if v_status <> 'ACTIVE' then
    return jsonb_build_object('status', v_status);
  end if;

  select * into v_recipe from public.recipes where id = v_link.recipe_id;
  if not found then
    return jsonb_build_object('status', 'REVOKED');
  end if;

  update public.recipe_access_links
     set access_count = access_count + 1, last_accessed_at = now()
   where id = v_link.id;

  return jsonb_build_object(
    'status', 'ACTIVE',
    'access_type', v_link.access_type,
    'granted_by_name', v_link.granted_by_name,
    'brand', v_recipe.brand,
    -- Strip financial + costing columns server-side — they never leave the database.
    'recipe', (to_jsonb(v_recipe) - 'total_cost' - 'cost_per_portion' - 'packaging_cost' - 'selling_price' - 'wastage_pct'),
    'ingredients', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ri.id,
        'component_type', ri.component_type,
        'quantity_used', ri.quantity_used,
        'unit_used', ri.unit_used,
        'sub_recipe', (ri.component_type = 'recipe'),
        'ingredient_name', case when ri.component_type = 'recipe' then sr.recipe_name else rm.ingredient_name end
      ) order by ri.sort_order)
      from public.recipe_ingredients ri
      left join public.raw_materials rm on rm.id = ri.ingredient_id and ri.component_type <> 'recipe'
      left join public.recipes sr on sr.id = ri.ingredient_id and ri.component_type = 'recipe'
      where ri.recipe_id = v_recipe.id
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.resolve_share_link(text) to anon, authenticated;
-- 0009_seed_catalog.sql — catalogue data for the Supabase data layer (Phase 2).
-- Generated from the mock seed. Run AFTER 0001,0004,0005,0006,0007,0008.
-- Idempotent (on conflict do nothing). actor columns left null.

-- raw_materials (882)
insert into public.raw_materials (id, ingredient_name, category, supplier_name, purchase_price, purchase_quantity, purchase_unit, base_unit, cost_per_base_unit, last_price_update, status, notes, created_at) values
('c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'Butter', 'Dairy', null, 538, 1, 'KG', 'Gram', 0.538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2cda9e2a-1805-442b-ad05-bbd9311a5b4e', 'Parmesan Cheese', 'Dairy', null, 1266.7, 1, 'KG', 'Gram', 1.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3d2afee0-e15f-457d-8711-548238cf670c', 'Mozzarella Grated', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('92bcf2b0-62f1-475c-b60d-3b1baa0e664e', 'Burrata Cheese', 'Dairy', null, 790.33, 1, 'KG', 'Gram', 0.7903300000000001, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('31c6c2e1-0c0a-452d-b65d-b315579c2bc8', 'Amul Gold Milk', 'Dairy', null, 75.2, 1, 'KG', 'Gram', 0.0752, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e618b770-1253-4119-8f5d-0976dbb90e88', 'Fresh Cream', 'Dairy', null, 223.62, 1, 'KG', 'Gram', 0.22362, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('93bdc872-1d15-4343-b779-6efd9763be6f', 'Tofu', 'Protein', null, 260, 1, 'KG', 'Gram', 0.26, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f78e261-0481-4dc1-ad9f-b1023e4ca71d', 'Boiled Spaghetti Pasta', 'Grains & Flour', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a5b1d852-5e75-4e44-9176-336071330769', 'Boiled Bucatini', 'Grains & Flour', null, 92.3, 1, 'KG', 'Gram', 0.0923, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('832246d2-2132-4a5a-b502-0f76d6311c92', 'Rice Flour', 'Grains & Flour', null, 60, 1, 'KG', 'Gram', 0.06, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('59677f6c-1011-4810-8043-706d54195ea7', 'Maida', 'Grains & Flour', null, 37.62, 1, 'KG', 'Gram', 0.03762, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('12b73052-b8d6-4bc4-959d-fa6ea314fad5', '00 Flour', 'Grains & Flour', null, 119.7, 1, 'KG', 'Gram', 0.1197, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'Sushi Rice', 'Grains & Flour', null, 252, 1, 'KG', 'Gram', 0.252, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2b8ef560-f327-4885-ad0f-1846413f16c4', 'Yeast', 'Bakery', null, 368.4, 1, 'KG', 'Gram', 0.36839999999999995, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f5cce6e-3b22-4696-bb7d-bdd3f64e9b29', 'Malt', 'Bakery', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('727cbb5d-7771-49b9-be5d-4d6abba0d73d', 'Brown Sugar', 'Bakery', null, 82, 1, 'KG', 'Gram', 0.082, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('582632fb-52b5-4cdb-bb54-e434850625c0', 'Sugar', 'Bakery', null, 101, 1, 'KG', 'Gram', 0.101, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'Olive Oil', 'Oils & Fats', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a40de1bf-feee-43d6-851a-9294c3f97d95', 'Sunflower Oil', 'Oils & Fats', null, 104.7, 1, 'KG', 'Gram', 0.1047, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'Oil', 'Oils & Fats', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e3567f43-4b66-4155-a1d3-ca322e650ee1', 'Chilli Crisp Oil', 'Oils & Fats', null, 125, 1, 'KG', 'Gram', 0.125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('702daa6e-9b84-4d57-8176-e1345714d702', 'Red Chilli Oil', 'Oils & Fats', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4416eb46-400f-45e8-9543-3e26ba309052', 'Peeled Garlic', 'Vegetables', null, 182.3, 1, 'KG', 'Gram', 0.18230000000000002, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b57543c3-9987-4bc6-9c7b-52c4715fd7a9', 'Garlic Chopped', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1346710c-bcf0-450d-a8b1-1b4b75294fd9', 'Green Garlic', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dbc1007b-0325-47fd-bf17-92289758a28d', 'Fried Garlic', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bd976fab-4bc0-492d-b4b2-aef9390f32c2', 'Ginger', 'Vegetables', null, 129.5, 1, 'KG', 'Gram', 0.1295, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cc0d15a8-7d60-435d-83db-20b085d3471b', 'Onion', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e42168de-c34d-4387-ae2e-120eeda0a94a', 'Slit Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('c20f7f49-e90e-4166-99c5-83c12a0da878', 'Fried Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d8532cb7-2cd4-46e0-903a-e51226e7d976', 'Confit Onion', 'Vegetables', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('57221778-c510-4dcd-a99e-ebdeb4d9e9b5', 'Confit Garlic', 'Vegetables', null, 482.2, 1, 'KG', 'Gram', 0.48219999999999996, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f51230e9-c6ab-4994-b5ec-50a6977011cc', 'Spring Onion', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.07529999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3059e16d-cc3a-4752-900a-ce663aa32b91', 'Chopped Spring Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('abbd46f7-f4ec-4d23-9ac6-af96b7d96437', 'White Spring Onion', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.07529999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'Parsley', 'Vegetables', null, 289.1, 1, 'KG', 'Gram', 0.2891, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'Coriander', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0d569d25-bf30-43fd-867e-3ebb006bd808', 'Dill Leaves', 'Vegetables', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c65a14c-ab36-4c1d-9344-697e3820fb01', 'Basil', 'Vegetables', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('48d0687d-295e-4e7b-a702-f8178b9b698c', 'Curry Leaves', 'Vegetables', null, 25, 1, 'KG', 'Gram', 0.025, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('60db8c80-f069-41a4-b426-b281a28c6e42', 'Green Chillies', 'Vegetables', null, 41.5, 1, 'KG', 'Gram', 0.0415, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'Carrot', 'Vegetables', null, 50.6, 1, 'KG', 'Gram', 0.0506, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bdb4d501-b297-49db-816c-baf2c666a7eb', 'Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c07a62eb-4b49-4dd2-8f26-f46ef0c8bd2f', 'Shimeji Mushroom', 'Vegetables', null, 481.5, 1, 'KG', 'Gram', 0.4815, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c5e6d4ab-2a3f-4cca-9897-cc8c5db37d88', 'Beetroot', 'Vegetables', null, 50, 1, 'KG', 'Gram', 0.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d580a488-ec28-478d-af7f-f16b01c9927a', 'Pickled Red Paprika', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4bfeea3c-f40b-472d-8f18-aef78c9df0c9', 'Dried Red Chilli', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'Lemon Juice', 'Sauces & Condiments', null, 311, 1, 'KG', 'Gram', 0.311, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('779cc97b-67ac-487a-be12-3183dc8117dc', 'Black Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6d0d992e-fafd-41c5-911e-7e893980a853', 'White Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('99b5d2fe-bcd9-4d46-996d-96306493db7f', 'Chilli Flakes', 'Spices', null, 340, 1, 'KG', 'Gram', 0.34, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5fac1058-2167-4228-90f0-ebef4e23b763', 'Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c80877b8-3467-45d4-a3c6-0c672874cf74', 'Salt', 'Spices', null, 28.5, 1, 'KG', 'Gram', 0.0285, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'MSG', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'Stock Powder', 'Spices', null, 312, 1, 'KG', 'Gram', 0.312, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6c760bc9-6bb7-4a45-b2b0-725cad8aaaaf', 'Garlic Powder', 'Spices', null, 417.5, 1, 'KG', 'Gram', 0.4175, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('737bee95-47e8-4293-90dc-caec7c418436', 'Onion Powder', 'Spices', null, 512.5, 1, 'KG', 'Gram', 0.5125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('85cfb1fe-591d-4db0-925c-d0f3d4b5c69f', 'Kashmiri Chilli Powder', 'Spices', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7f1ee32c-fbf9-4ab8-bf05-c5d97043de74', 'Turmeric', 'Spices', null, 1428.6, 1, 'KG', 'Gram', 1.4285999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fea6dc3a-3c65-459d-8e38-1ebddd30cd7b', 'Mustard Seeds', 'Spices', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4473a25d-158c-4fce-b226-b7b091f1c320', 'Fenugreek Seeds', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9d568b45-c2a7-4af7-b52b-2a50825beb73', 'Coriander Seeds', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2debb3b9-5a70-4448-9cda-b09663bb1173', 'Cumin Seeds', 'Spices', null, 933.3, 1, 'KG', 'Gram', 0.9332999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('728cb67a-218a-4ac3-9646-a3d296afaa4c', 'Fennel Seeds', 'Spices', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('82b366c6-df42-4a56-99f9-99f402f0674a', 'Cinnamon', 'Spices', null, 6000, 1, 'KG', 'Gram', 6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5b9b8bd5-37b5-490c-a929-f1f922213e9c', 'Cloves', 'Spices', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c198f2eb-e3a4-4d65-b767-2f1018753977', 'Cardamom', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f20b495-00ce-4e56-9662-0f64cf8c6628', 'Black Sesame', 'Spices', null, 273, 1, 'KG', 'Gram', 0.273, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e5ff968a-02fd-4c7a-b5d4-d3bc13ef8a86', 'White Sesame', 'Spices', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b59fcd3b-96f0-4021-89fd-2b6044964633', 'Bagel Seasoning', 'Spices', null, 1645, 1, 'KG', 'Gram', 1.645, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f009937-75f9-4338-a6c3-e7b41540bc51', 'Wasabi', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('971caa70-20ee-46c5-87a7-1aefec515ea9', 'Almond', 'Dry Fruits', null, 904.97, 1, 'KG', 'Gram', 0.90497, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f3fda85a-b16c-4609-af0d-181a66df708e', 'Kashmiri Chilli Red Paste', 'Sauces & Condiments', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('332d2059-1d2b-4c42-8d79-ac40aa5c617c', 'Chunky Tomato Sauce', 'Sauces & Condiments', null, 235, 1, 'KG', 'Gram', 0.235, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('50af20fc-26e4-4250-9064-0deadcfced12', 'White Vinegar', 'Sauces & Condiments', null, 31, 1, 'KG', 'Gram', 0.031, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3be12901-de36-4cf8-9eaf-285577602b5c', 'Hot Sauce', 'Sauces & Condiments', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('adae9a5b-c2fe-453e-8e96-6341bfdafb53', 'Plain Mayo', 'Sauces & Condiments', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6ba1f12c-f4f7-4bdd-b393-f215537b0b85', 'Ponzu Mayo', 'Sauces & Condiments', null, 153.2, 1, 'KG', 'Gram', 0.15319999999999998, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('27b0f6e0-8031-4deb-8a42-f7987faba2ec', 'Gochujang Mayo', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6de64be9-fe04-464c-b463-3eae81d8723b', 'Avo Guac', 'Sauces & Condiments', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5df892d8-2ec4-4f00-8acc-5c1949da52b3', 'Corn Slurry', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f4136be6-5d6f-47e3-be1b-5a31285afaf7', 'Coconut Milk', 'Dairy', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('287405ec-d752-44b3-a9b7-507cd9283b83', 'Tamarind', 'Sauces & Condiments', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1df679cd-076b-4384-9f0e-5150628a6d44', 'Water', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('25f5785e-4294-4ea6-b31e-dd664f913098', 'Ice', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5abae750-07d9-4aa2-97bf-b0757fa97276', 'Stock Water', 'Beverages', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bcb5708b-bd83-4b16-bb22-4a643ca547d9', 'Arugula', 'Vegetables', null, 462.6, 1, 'KG', 'Gram', 0.4626, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('98242278-890b-43f7-b75e-4cf059cdcc8f', 'Iceberg', 'Vegetables', null, 179.1, 1, 'KG', 'Gram', 0.1791, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8368d51c-b656-44a7-beba-ac9f53294cb8', 'Romaine', 'Vegetables', null, 241.3, 1, 'KG', 'Gram', 0.2413, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('46b8351f-1246-42d8-b059-e010322df82b', 'Curly romaine', 'Vegetables', null, 241.3, 1, 'KG', 'Gram', 0.2413, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8de080ae-a902-47ae-aa9b-37e654126bbc', 'Cherry tomato', 'Vegetables', null, 505.3, 1, 'KG', 'Gram', 0.5053, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b09306d4-1f25-4bb8-be43-c27bc9053eda', 'Grapefruit', 'Fruits', null, 227.7, 1, 'KG', 'Gram', 0.2277, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cb975211-a779-486d-ba69-3c76da82d784', 'Pine nuts', 'Bakery', null, 5376, 1, 'KG', 'Gram', 5.376, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d0513eb6-00dc-479e-a284-5c1853e04ff9', 'Black olives', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('298a1d86-91ca-4b0f-a522-3574e8e7b5ff', 'Vinaigrette', 'Sauces & Condiments', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8da3364a-514b-4093-872e-b35dcb010eca', 'Sea salt', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('673983d2-d6ee-477b-9524-dc6cd75a6f39', 'Hot honey', 'Sauces & Condiments', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a7c1c47b-50a4-45c0-b329-7bd65a6ffdb5', 'Edible flower', 'Other', null, 104.3, 1, 'KG', 'Gram', 0.1043, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('11450463-68fe-46b9-9a1d-59dd0a06a2c4', 'Baby burrata', 'Dairy', null, 907.81, 1, 'KG', 'Gram', 0.90781, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('77ba00cd-b9d4-4f71-936c-06a1bb3692f6', 'Parmesan (grated)', 'Dairy', null, 1350.37, 1, 'KG', 'Gram', 1.35037, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f0519ed-392e-418c-9983-96ec9c2ed18e', 'Crispy croutons', 'Other', null, 139, 1, 'KG', 'Gram', 0.139, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8241eb39-5c44-43fe-82bc-bf5b959cd65d', 'Caesar mayo', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('753ca806-1ccf-4151-8c6d-0824aa2db221', 'Persimmon', 'Fruits', null, 362.5, 1, 'KG', 'Gram', 0.3625, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('feeb6f2b-a1fd-4383-a782-586f2283ec69', 'Strawberry', 'Fruits', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cee08965-9ed2-4bc6-85dd-2b6d58c4c5e0', 'Burrata', 'Dairy', null, 691.8, 1, 'KG', 'Gram', 0.6918, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ff5aabbd-0525-42c1-87b8-b57f42331a4b', 'Caviar', 'Other', null, 810, 1, 'KG', 'Gram', 0.81, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b5e6776e-3508-45e5-bb91-f976b5c280be', 'Edible flowers', 'Other', null, 0.93, 1, 'Piece', 'Piece', 0.9266, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('68f6276e-2499-4b7b-9884-2f9f42ef1054', 'Processed Iceberg lettuce', 'Vegetables', null, 179.1, 1, 'KG', 'Gram', 0.1791, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea81d7f2-b814-4de0-8fac-74620eb41988', 'Processed Romaine lettuce', 'Vegetables', null, 237.5, 1, 'KG', 'Gram', 0.2375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f4d53822-a41c-40f4-b536-6f341530dff1', 'Processed Lollo Rosso', 'Other', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('499e5b1f-8d77-4343-81d7-98795b81bc9d', 'Crushed black pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ac77dab8-62e0-458b-997b-12d8e6fee79e', 'Roasted hazelnuts', 'Bakery', null, 2600, 1, 'KG', 'Gram', 2.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9a016a1c-1a98-4811-a195-f2232011c46a', 'Granola (chopped)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('aa40d136-a737-4d73-a064-277daf2cb647', 'Mango (cubed)', 'Fruits', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2dd17265-d2a4-4d8a-8665-d13593e674af', 'Grapefruit (cubed)', 'Fruits', null, 227.7, 1, 'KG', 'Gram', 0.2277, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('151a95b5-b185-43b1-b349-2e758468231f', 'Cherry tomatoes', 'Vegetables', null, 505.3, 1, 'KG', 'Gram', 0.5053, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d4abe84d-dfaa-4193-898c-1ee43698bb2b', 'Hot honey drizzle', 'Sauces & Condiments', null, 356.7, 1, 'KG', 'Gram', 0.3567, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32e82839-c251-4b36-813c-1fa4b02cc966', 'Red bell peppers', 'Vegetables', null, 180.7, 1, 'KG', 'Gram', 0.1807, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d7ef81e5-47e1-4de0-9159-cef047743d95', 'Garlic', 'Vegetables', null, 182.3, 1, 'KG', 'Gram', 0.1823, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0afdbe0-3e23-4c84-82d0-1c9a2eb3237c', 'Tomato', 'Vegetables', null, 68.3, 1, 'KG', 'Gram', 0.0683, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('27a46d0e-a3d9-4d93-9ccb-f42c66271d58', 'Roasted bell pepper paste', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'Sour cream', 'Dairy', null, 182, 1, 'KG', 'Gram', 0.182, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'Pesto', 'Sauces & Condiments', null, 408, 1, 'KG', 'Gram', 0.408, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('47b4b4ad-2beb-4ea0-bb0d-f1129c7c9c42', 'Sourdough', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('48542725-c17d-444f-a0f6-859449ac6b46', 'Garlic butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c7c93a8-1963-4ecd-9e04-b90ce8aabba9', 'Cooked risotto rice mix', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('368fc303-992c-431a-b16d-4058546e0449', 'Mozzarella', 'Dairy', null, 599.22, 1, 'KG', 'Gram', 0.59922, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4fc7e9be-cadd-4226-b253-76288f0766b3', 'Arancini batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9830524f-1b83-4747-94c0-017e5d1c3a55', 'Panko crumbs', 'Grains & Flour', null, 121.3, 1, 'KG', 'Gram', 0.1213, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4509ef74-5f22-492e-a874-94ff95795fe2', 'Frying oil', 'Oils & Fats', null, 187.14, 1, 'Litre', 'ML', 0.18714, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6d607aa5-c990-4de2-806e-fcb3ac37854b', 'Dough', 'Grains & Flour', null, 56.3, 1, 'KG', 'Gram', 0.0563, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1fc49e94-89c9-4d70-b99d-473c3c1b8ef2', 'Bread base', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'Cream cheese', 'Dairy', null, 884, 1, 'KG', 'Gram', 0.884, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b71a0cf4-4300-47fd-966d-2eed57217bb5', 'Green garlic (garnish)', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dd257032-736e-4572-871a-dae14310dc93', 'Ricotta', 'Dairy', null, 283.5, 1, 'KG', 'Gram', 0.2835, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7708dfa8-2f54-40db-9231-1638e85043dc', 'Oregano', 'Spices', null, 218.33, 1, 'KG', 'Gram', 0.21833, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9154b564-40be-400b-acfa-5f185d0e649e', 'Parmesan', 'Dairy', null, 437.5, 1, 'KG', 'Gram', 0.4375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1e4841bc-dbde-46cf-9398-1a8e26e078c9', 'Thyme', 'Spices', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('434be61a-a0db-4d83-9d1a-f11e7dcef191', 'Salt & pepper', 'Spices', null, 28.5, 1, 'KG', 'Gram', 0.0285, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('53e01c0c-c64b-489e-a12f-210ced69579c', 'Pasta sheet 22 g x 2', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('12a568e0-7c71-4e81-82d8-8a3493d6247a', 'Tomato paste', 'Sauces & Condiments', null, 237.5, 1, 'KG', 'Gram', 0.2375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c80d72b8-5090-4004-82eb-d63a3b04cdc8', 'Mozzarella 20 g each', 'Dairy', null, 599.22, 1, 'KG', 'Gram', 0.59922, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('042856db-0e9c-42cf-a710-ffa7fd5e301e', 'Ricotta filling 15 g each', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fc1b9fc7-9c8c-49f4-ab4f-774d80c438f3', 'Batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('94427f65-c7f1-415b-a919-263dec4239ca', 'Bread crumbs', 'Grains & Flour', null, 121.3, 1, 'KG', 'Gram', 0.1213, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('17f33ed0-202a-4cf8-93fa-690813b502a8', 'Pomodoro sauce', 'Sauces & Condiments', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fc81f4c7-68e6-481c-915c-2b0795799bec', 'Chopped garlic', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cb0be924-cdf8-4133-96d0-d051e3de0af0', 'Seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f0dfdb84-3334-43fe-84ba-20db06778c99', 'Cowboy Butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('723b0dd7-4064-4f89-bfc8-c34b8157c24b', 'Pepper', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f5f04403-d790-413b-b769-e7d426326160', 'Brussels sprouts (halved)', 'Vegetables', null, 822.5, 1, 'KG', 'Gram', 0.8225, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('599345fa-07b8-4dc4-b65f-d8a09f449270', 'Garlic (chopped)', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d2f0b196-20b8-4b8b-995d-aa818c6ebfb0', 'Red chilli flakes', 'Spices', null, 296, 1, 'KG', 'Gram', 0.296, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c61867ab-5a91-466f-92d5-fda3e9c18962', 'Balsamic vinegar', 'Sauces & Condiments', null, 890, 1, 'KG', 'Gram', 0.89, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ad93e9d5-d0a8-4e7a-9a00-5e9393a7783f', 'Salt & black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b1558d80-b3bc-4ee2-b780-cfc6efd026e7', 'Béchamel sauce', 'Sauces & Condiments', null, 112.6, 1, 'KG', 'Gram', 0.1126, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ceee1d07-77fa-4fe5-9604-93b5da463f7c', 'Plain mayonnaise', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0238d3de-8254-407c-827e-b4aaafdb4e96', 'Fresh Bhavnagri chilli', 'Spices', null, 0.08, 1, 'Piece', 'Piece', 0.0825, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('18184f4c-174d-47f6-a89c-5089208fd850', 'Pickled onions', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1b28a972-b7a0-4858-9f60-e5b6e67ee7c5', 'Feta crumbles', 'Grains & Flour', null, 813.3, 1, 'KG', 'Gram', 0.8133, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b0673a3-3f56-4f5c-a1b6-16a1df6c8d2a', 'Tomatoes', 'Vegetables', null, 68.3, 1, 'KG', 'Gram', 0.0683, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('764a19d8-7714-40c9-b974-3d14703b4386', 'White miso paste', 'Sauces & Condiments', null, 488, 1, 'KG', 'Gram', 0.488, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('687f2299-c937-49c7-be99-19c96dcddd81', 'Chili flakes (or fresh red chili - 5 g, deseeded)', 'Spices', null, 340, 1, 'KG', 'Gram', 0.34, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1055527d-286d-4de4-9e6d-cfe9f669c29f', 'Soy sauce (optional)', 'Sauces & Condiments', null, 0.26, 1, 'Piece', 'Piece', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('46c9e81d-e906-4e66-97d7-5c33fd3a4dcd', 'Basil (fresh, chopped)', 'Vegetables', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9b16971d-d872-457b-836a-e359e6037a1e', 'Thyme (sprigs) (simmer, remove before blending)', 'Spices', null, 0.6, 1, 'Piece', 'Piece', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5eddea1d-90d3-4f81-8eda-f8569ebc7042', 'Bay leaf (remove before blending)', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('23dc6b59-218b-49fe-bab7-84bc5846681b', 'Parsley stems (optional, simmer with base)', 'Vegetables', null, 289.1, 1, 'KG', 'Gram', 0.2891, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2a670104-1402-4889-9741-cb89c65d8da5', 'Pomodoro', 'Other', null, 216.3, 1, 'KG', 'Gram', 0.2163, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('daa20a07-4fbd-4341-8ce0-5acecb968a7d', 'Boiled spaghetti', 'Oils & Fats', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0b37d616-a410-4231-80f9-f9d5c1861735', 'Boiled macaroni', 'Oils & Fats', null, 101.8, 1, 'KG', 'Gram', 0.1018, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('385f817c-8201-40f8-8eed-d54cd86359e1', 'Orange (creamy tomato) sauce', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7fc21a37-0a2b-4f83-a082-a39f70c15719', 'Boiled fettuccine', 'Oils & Fats', null, 98, 1, 'KG', 'Gram', 0.098, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('58cd06aa-2281-44e7-8e16-2025f82c3633', 'Béchamel', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('62ef2d72-8d26-42f0-b5cf-12c681a1b0a5', 'Boiled linguini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a42cf520-68d6-4598-8b52-9e4374c916a8', 'White sauce', 'Sauces & Condiments', null, 242.7, 1, 'KG', 'Gram', 0.2427, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8fa6c44d-97a9-4a14-972b-ad8a8c8980eb', 'Mascarpone', 'Dairy', null, 731.57, 1, 'KG', 'Gram', 0.73157, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e265987e-5349-4b20-a540-66d1e06f61fb', 'Lemon zest', 'Fruits', null, 97.1, 1, 'KG', 'Gram', 0.0971, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('632f3ef7-5281-4f02-8a51-72e5babf70cb', 'Cooked arborio rice', 'Grains & Flour', null, 367.5, 1, 'KG', 'Gram', 0.3675, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f313f2e5-d4b3-4e62-9386-7e20908a9026', 'Asparagus', 'Other', null, 923.1, 1, 'KG', 'Gram', 0.9231, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3ac2508a-ef18-43e1-85ff-b8695877c3ea', 'Peas', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d68045f4-2796-4539-a572-2472c66b265e', 'Soy chunks (textured)', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4045a6f1-b066-4934-96fd-dbcca0cf5949', 'Onion (diced)', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e353198d-81f3-463d-8191-f47c05b7efda', 'Carrot (diced)', 'Vegetables', null, 50.6, 1, 'KG', 'Gram', 0.0506, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8e529cde-d0c8-4eed-b1b5-3a4d1284ac45', 'Celery (diced)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('059e0386-7487-4901-92dd-545c8499e5e2', 'Tomato passata', 'Vegetables', null, 189, 1, 'KG', 'Gram', 0.189, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cdbe7675-3fa4-43c8-a7aa-70ad0fb6b293', 'Dried oregano', 'Spices', null, 218.33, 1, 'KG', 'Gram', 0.21833, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d33dd561-125e-4506-bc5a-49b504fd6e21', 'Plain flour', 'Grains & Flour', null, 37.62, 1, 'KG', 'Gram', 0.03762, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('708e9303-780e-4354-b975-a9d02064a919', 'Milk', 'Dairy', null, 76.7, 1, 'KG', 'Gram', 0.0767, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('603cce6b-e2d7-4056-b294-8e5d2ae04dc1', 'Nutmeg', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d8c3bd66-a51e-4555-9b59-11f8452751db', 'Lasagna sheets (oven-ready)', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b08e0b35-6074-45a9-9c4e-7016d7eaef4a', 'Mozzarella (shredded)', 'Dairy', null, 599.22, 1, 'KG', 'Gram', 0.59922, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('79566a35-5a94-4dca-a1e8-f994cfdaf305', 'Ricotta cheese', 'Dairy', null, 288, 1, 'KG', 'Gram', 0.288, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('73bbda75-fff0-4ee9-a302-6f15117e90a3', 'Blanched kale', 'Other', null, 350, 1, 'KG', 'Gram', 0.35, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6c871894-0e92-4f91-bc4c-ff051414c14a', 'Chopped jalapeño', 'Other', null, 366.7, 1, 'KG', 'Gram', 0.3667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('922147ba-8571-4471-bfd5-b82f6290b863', 'Xanthan gum', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4a9f5bb6-57d5-4464-90c2-fb505bcbe10b', 'Conchiglioni', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('26c0a6c3-76f1-4687-80ea-e4cb95a4a93b', 'Garlic pomodoro sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7939178b-36e6-4379-827b-92c9bc26a9c5', 'Sunflower seeds', 'Other', null, 420, 1, 'KG', 'Gram', 0.42, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c88f8e4d-d040-4eaa-8dc0-befccef05308', 'Caramelised onion', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ae2ce648-8f15-4fee-a593-987ede5b71ba', '1 ladle water', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('abe2e836-2a41-4082-a91d-b69160f78103', 'Spaghetti', 'Grains & Flour', null, 241.5, 1, 'KG', 'Gram', 0.2415, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6cafa85c-fe4c-4719-bb5e-d25d879b880a', 'Mix seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ad54c1c8-bc59-406f-bf7f-ede15073ccf1', 'Soya sauce', 'Sauces & Condiments', null, 261.09, 1, 'KG', 'Gram', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5e164e69-ec0f-46e6-9bdc-7c21abbaee35', 'Chill crisp', 'Other', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1939f0fa-f140-4efd-b40e-9401c44a35a5', 'Beetroot paste', 'Sauces & Condiments', null, 78.8, 1, 'KG', 'Gram', 0.0788, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('85df22fa-b59f-4b0d-a6b1-b094a04611f3', 'Farfalle pasta', 'Grains & Flour', null, 296, 1, 'KG', 'Gram', 0.296, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0bcdf9e6-9d67-43c8-95f9-013ddeaf93d8', 'Burrata (smashed)', 'Dairy', null, 0.79, 1, 'Piece', 'Piece', 0.79033, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a78ca4ec-1f59-48b7-9082-f4767bc948d8', 'Pumpkin seeds & pistachios (crushed & mixed)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3173d0d9-4be1-4dc9-816f-1dcc6c865a2e', 'Risotto rice', 'Grains & Flour', null, 384.6, 1, 'KG', 'Gram', 0.3846, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('29d4daf7-dc95-4ef3-97dc-31a369f81f78', 'Confit cherry tomatoes', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('77ac6ea5-e32f-4b2e-842e-1f008ba2ce5d', 'Pesto dollop', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e23a195f-5de5-48d3-af4b-1831b54625f4', 'Kalonji (chopped)', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('43123186-be8a-4e61-9edb-af53c2985cb8', 'Macaroni pasta', 'Grains & Flour', null, 104.86, 1, 'KG', 'Gram', 0.10486, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a103cc0c-3806-4a8e-857c-3e102bd09384', 'Cheddar cheese', 'Dairy', null, 747.42, 1, 'KG', 'Gram', 0.74742, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a2b2b0b6-8d67-4d41-9042-5a275084ada8', 'Mozzarella cheese', 'Dairy', null, 599.22, 1, 'KG', 'Gram', 0.59922, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('910522b2-9199-4fec-add4-296db690dd3f', 'Truffle oil', 'Oils & Fats', null, 5649.32, 1, 'KG', 'Gram', 5.64932, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('df7f34a1-3625-4a1d-a55d-965d2bb5af53', 'Truffle pâté', 'Other', null, 16670, 1, 'KG', 'Gram', 16.67, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2658e044-d529-4bd9-aa0f-60073bd8d0fc', 'Sticky toffee pudding', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b671a804-2f5e-480a-bc85-82b6676789fe', 'Caramel sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3a7e9dd1-20ac-4dda-8d3e-36612274b62d', 'Pecan ice cream', 'Dairy', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('64aa5ede-7b1c-4004-b0b4-05950b0fa592', 'Brownie', 'Other', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('787efd4c-aac1-4c92-a8a5-ed1ee350d20e', 'Cookies & cream ice cream', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('901ca7b4-50ad-4749-8512-53bd19389a45', 'Nutella sauce', 'Sauces & Condiments', null, 566.7, 1, 'KG', 'Gram', 0.5667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0d9fb912-2f5a-42ba-91ab-2443e4884760', 'Caramel tuile', 'Bakery', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('99fed9a6-4819-4777-85e9-fbcb8ed759fe', 'Kunafa base', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ee2295da-2d0c-4874-876e-181544aec616', 'Pistachio sponge', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e7d0454d-1648-463d-998f-4e2e8fc43e3f', 'Pistachio mousse', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('82d75fcc-356b-4f58-b44e-303f6e6c99d9', 'White chocolate décor', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8083fe10-42ee-432d-93f8-2fffb8c0ab44', 'Coffee sponge', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f3f4f6e7-ad66-4059-98aa-224e128671c2', 'Mascarpone mousse', 'Dairy', null, 826.1, 1, 'KG', 'Gram', 0.8261, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('791fd585-22fc-45ac-b636-f8b9153dad11', 'Coffee cream', 'Dairy', null, 750, 1, 'KG', 'Gram', 0.75, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('643f90b8-c19f-40e1-a0e1-d445b1d17371', 'Sable', 'Other', null, 214.3, 1, 'KG', 'Gram', 0.2143, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('454a1c88-ce4c-4504-af1c-1533c678dd33', 'Tuile décor', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d38d4d26-586e-48a4-97c8-f90bbd3fca87', 'Sugar syrup', 'Sauces & Condiments', null, 27.3, 1, 'Litre', 'ML', 0.0273, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8520c252-0641-49c6-a01c-d13ad47a37c6', 'Iced tea (Tata Gold)', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f32e47e8-144f-4ed6-93ff-519de183336d', 'Mint syrup', 'Sauces & Condiments', null, 33.3, 1, 'Litre', 'ML', 0.0333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aa823717-5177-4a89-b16e-74aa769a699a', 'Kinley Soda', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b1d716c-365c-4da8-b3bf-40b3e1e639e8', 'Kara Coconut milk', 'Dairy', null, 324.08, 1, 'Litre', 'ML', 0.32408, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a6df6362-3b92-4827-86b9-67d5d64d67c0', 'Pineapple jam', 'Fruits', null, 137.5, 1, 'KG', 'Gram', 0.1375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0689ecdf-9809-49ba-ba01-e0ed1cad008c', 'Vanilla ice cream', 'Dairy', null, 0.19, 1, 'Piece', 'Piece', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('285298e0-0e5f-47fe-a4e6-c3aab2e48ea1', 'Fresh ginger zest', 'Vegetables', null, 0.13, 1, 'Piece', 'Piece', 0.1295, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0a8c0872-65c6-4fe1-ac8e-1cbdf32db2f6', 'Gunsberg Ginger Beer', 'Vegetables', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('de230c6b-26e4-4575-a7f4-54ded1a9ed09', 'Orange juice', 'Fruits', null, 405, 1, 'Litre', 'ML', 0.405, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d01a85c1-f046-47b6-b70e-d37d9d8b2c32', 'Hibiscus syrup', 'Sauces & Condiments', null, 66.7, 1, 'Litre', 'ML', 0.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0c228ffb-0b47-42c6-aec0-dbeccfaa09f3', 'Sprite', 'Other', null, 104.4, 1, 'Litre', 'ML', 0.1044, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1969f303-ef00-4c74-9f78-932bce453f27', 'Tamarind syrup', 'Sauces & Condiments', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9796c879-73a8-49ed-be46-9b31665fa0b1', 'Pinch of salt', 'Spices', null, 0.03, 1, 'Piece', 'Piece', 0.0285, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('15cd32dd-88cf-40d6-bf6b-fd565a9beae5', 'Schweppes Ginger Ale', 'Vegetables', null, 166.7, 1, 'Litre', 'ML', 0.1667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'Thai chilli', 'Spices', null, 1063.4, 1, 'KG', 'Gram', 1.0634, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2e5ccccc-d8e7-42a2-b068-4580f8cf2e2d', 'Shiitake mushroom', 'Vegetables', null, 1155, 1, 'KG', 'Gram', 1.155, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32a4075d-07a3-4fe6-837c-e53c85a38fc6', 'Tamarind paste', 'Sauces & Condiments', null, 240, 1, 'KG', 'Gram', 0.24, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d9c2a6bc-4456-48b3-939e-1cb76c6495cd', 'Vinegar', 'Sauces & Condiments', null, 42.2, 1, 'Litre', 'ML', 0.0422, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2d116a0b-9792-42e6-8296-fa202aa0c361', 'Spring Roll Sheets', 'Grains & Flour', null, 794.18, 1, 'KG', 'Gram', 0.79418, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fcd9c060-20db-492b-9691-40653cd704c5', 'Thai Spring Filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d04206c0-3a6a-4b58-bf49-b6bb4581de01', 'Sichuan Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8ff69d00-5cd5-4f7c-8cf9-9ad89ec76702', 'Coriander Leaves', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('daedd997-1ac7-4b39-8f7e-19a64bad6300', 'Spring Onion Slit', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'Sriracha Sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fcfe6c93-7341-4d7e-8f9d-e494f70c294c', 'Black Vinegar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('78e2994a-561d-4784-a307-6a0b1c491687', 'Lotus root', 'Vegetables', null, 187.7, 1, 'KG', 'Gram', 0.1877, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea885e38-77f7-4f76-861a-9e8cd10c94ca', 'Lotus root sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8e941bf1-7115-4d94-a15b-e6dbc85c5354', 'Pok choy', 'Vegetables', null, 118.5, 1, 'KG', 'Gram', 0.1185, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('33728a74-16c5-46f1-bc23-da7deb4a007c', 'Bell pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f89dd080-0e8d-4b5b-ad03-95c4cb076f0a', 'Thai red chilli', 'Spices', null, 1063.4, 1, 'KG', 'Gram', 1.0634, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('849761fa-3b61-47bd-a415-318a8130d611', 'Kwispy Wonton filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fee655aa-7aba-421c-bd88-d1e70f3b0fa1', 'Gyoza skin', 'Other', null, 0.65, 1, 'Piece', 'Piece', 0.651, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4999fdbd-4ccc-4cdc-a0d0-d01f0ca6e8a5', 'Chilli crisps', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7a9a1c16-9104-4d8c-9a33-26be71e63279', 'Oil (for frying)', 'Oils & Fats', null, 187.14, 1, 'KG', 'Gram', 0.18714, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0053d9ff-de13-4fd7-abe1-fd77eb3101db', 'Rice cake (16 pcs)', 'Grains & Flour', null, 560, 1, 'KG', 'Gram', 0.56, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('80b82054-54e6-4c97-a19f-b890dc54b57a', 'Tteokbokki sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f34a2e72-6fd6-498c-b2fe-be56a35f2f8f', 'Spring onion slit (garnish)', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('980992d7-7b00-44f3-8683-585a7e559643', 'Bao', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('eef51443-abe5-49e3-809a-57dccc4cf8cb', 'Tofu batter', 'Protein', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'Cucumber', 'Vegetables', null, 52.5, 1, 'KG', 'Gram', 0.0525, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('282ac16c-b3fd-4b60-95bb-c6ff3d1b1064', 'Coleslaw', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0f246713-d43c-43df-bfb5-2b68bf4bd3ac', 'Black & white sesame', 'Spices', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3e5ce90e-9c6d-4ae4-bbfb-ac43e905ae05', 'Bao sauce base', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('972a61db-ddee-42ae-8e98-35db7fbba6b0', 'Water chestnut', 'Bakery', null, 255.73, 1, 'KG', 'Gram', 0.25573, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8077e339-baeb-4b80-85c5-f1f52181d7d5', 'Water chestnut flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('af145b47-68bb-4613-9080-a05b0ba749fa', 'Gyoza dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ecd30dcf-c907-4ea8-91ee-2e4d5b6fb807', 'Yellow bell pepper', 'Vegetables', null, 166.1, 1, 'KG', 'Gram', 0.1661, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0024c03b-1b96-49d4-b50e-61e8cc6f7ec3', 'Red bell pepper', 'Vegetables', null, 180.7, 1, 'KG', 'Gram', 0.1807, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('359ee41a-ec5f-40e6-a826-54a90998643f', 'Drunken sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3bf5702b-2eab-4038-84d1-8b16f09d771f', 'Fried spring roll (garnish)', 'Other', null, 794.18, 1, 'KG', 'Gram', 0.79418, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('969a15eb-5008-415f-84a5-aab37e0bde6c', 'With pods edamame', 'Other', null, 450, 1, 'KG', 'Gram', 0.45, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('326ab281-4ab3-40fc-9aaf-922ca7b51586', 'Chilli Crisp (for chilli version)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('505ff761-dd0a-4b88-8ae1-b5b970134300', 'Salt (for salted version)', 'Spices', null, 28.5, 1, 'KG', 'Gram', 0.0285, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7c58f2e8-5481-4d77-bbc1-9beb7a16e7e9', 'Korean Mandu filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cd52d448-e2cf-4d5d-8739-5848298cfe06', 'Spicy mayo', 'Sauces & Condiments', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b79350c9-a912-442e-9cf4-4166eaedd738', 'Coriander mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ff7c87bb-94d1-4086-b0d0-157e31a43cb2', 'Toasted white sesame seeds', 'Spices', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('64bc3823-2edd-4deb-950b-6a3baca76dbb', 'Julienne cut nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f1e31970-c8c8-4071-b079-6c0eefee2ea7', 'Fried Corn', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('413cf6bf-80be-4966-9d65-f0b0d0820bfd', 'Corn Rocks sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d4b17a33-825d-4e3f-a662-3ce8ddfcf07c', 'Chopped Black sesame seeds', 'Spices', null, 273, 1, 'KG', 'Gram', 0.273, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('833614b9-814e-4b5a-a8bc-e892c08a21b7', 'Pickled red paprika sliced', 'Spices', null, 105, 1, 'KG', 'Gram', 0.105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e1c1db55-10eb-46a9-a8ae-0b0ef5766455', 'Mayonnaise', 'Sauces & Condiments', null, 85.1, 1, 'KG', 'Gram', 0.0851, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('765a7709-0f4f-469f-b052-79a81e955a7b', 'Sweet corn puree', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fb7833c3-61c6-49d2-9658-2c06cb7f6cb1', 'Condensed milk', 'Dairy', null, 332, 1, 'KG', 'Gram', 0.332, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b71b149e-1531-474d-bd70-7b0e6ed178ca', 'Garlic (minced)', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9ce413a7-7b68-4c4b-87f0-c92fe1f4809f', 'Scallion Pancake', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('75c05c6b-c1da-4237-bd3d-e362797148ea', 'Sichuan soy glaze', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('01c24506-5671-446e-bb48-215fd5ad6367', 'Green garlic cream cheese', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('25a4e1a3-aa13-4c44-9968-5b033740feba', 'Scallion salad', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('50ff9915-1a8b-4d52-b15b-d425e7fd8016', 'Boiled soba noodles', 'Oils & Fats', null, 482.34, 1, 'KG', 'Gram', 0.48234, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8f345b52-fa9f-4e63-a7ca-1bfbc278aa82', 'Cold Spicy Sesame sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('67a8e07c-4725-4413-a193-afbbfb694785', 'Cucumber slice', 'Vegetables', null, 52.5, 1, 'KG', 'Gram', 0.0525, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32ccb047-1556-45f3-9dfa-f858c6e036ea', 'Carrot slice', 'Vegetables', null, 50.6, 1, 'KG', 'Gram', 0.0506, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('031bcdab-9e95-40ce-a6a6-eb0f3c4bdb85', 'Fried sesame', 'Spices', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c8224a81-9b9d-476f-bccf-31c3e465d93b', 'Peanut (crushed)', 'Bakery', null, 192.43, 1, 'KG', 'Gram', 0.19243, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('81693002-e778-4c45-93aa-977bd955e851', 'White Part Spring Onion', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('28435716-99e7-46a8-8e40-43537c36c5d9', 'Mix iceberg romain slice', 'Vegetables', null, 179.1, 1, 'KG', 'Gram', 0.1791, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cf5ca19e-c3cb-43ac-92be-eb19c6e8b7e3', '00 flour (Biga)', 'Grains & Flour', null, 119.04, 1, 'KG', 'Gram', 0.11904, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('60f35741-2d05-4340-ae21-2863ef66a2de', 'Water (Biga)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d6041058-3ee7-4760-86d2-27b124697557', 'Dry yeast (Biga)', 'Other', null, 378, 1, 'KG', 'Gram', 0.378, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('33ec776a-dc7f-44eb-bc39-ea423e4941b1', 'Cold water', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('98e5ddec-edf8-4a2c-942c-9e497c2ae555', 'Dry yeast', 'Other', null, 378, 1, 'KG', 'Gram', 0.378, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1e04f846-2ea6-4a1d-99ba-927f4bcd1940', 'EVOO', 'Other', null, 1100, 1, 'KG', 'Gram', 1.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1802261a-db8f-48a5-9513-faa853968edd', 'Katsu curry', 'Other', null, 1150, 1, 'KG', 'Gram', 1.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b8192aac-7dea-4e6d-9d2f-def25e6140e9', 'Cabbage', 'Vegetables', null, 31.1, 1, 'KG', 'Gram', 0.0311, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('de8c0f22-f06d-4964-b13b-bce0e2bbccad', 'Togarashi', 'Other', null, 1260, 1, 'KG', 'Gram', 1.26, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('22e20e53-0cc7-43be-8709-2d5f66beb9db', 'Sesame seeds', 'Spices', null, 290, 1, 'KG', 'Gram', 0.29, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d9459cad-2769-4893-b009-6927d9e05b0f', 'Jasmine steamed rice', 'Grains & Flour', null, 210, 1, 'KG', 'Gram', 0.21, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0acf8f6a-15a0-431c-8a22-caec195c7fc8', 'Scallion oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1395fab5-154f-488f-b06c-42e091760451', 'Unagi sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e5a909f3-f5fd-493a-bd59-769c6bd83cc3', 'Zucchini', 'Other', null, 171.9, 1, 'KG', 'Gram', 0.1719, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('120d4ad3-085f-4483-877a-7d2d31e49ba0', 'Baby corn', 'Vegetables', null, 137.4, 1, 'KG', 'Gram', 0.1374, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('994923b7-187b-49ee-a903-db2075ba4520', 'Green paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cb71da23-fcbb-4d82-8dcc-8f4cd48e97b6', 'Jasmine rice', 'Grains & Flour', null, 210, 1, 'KG', 'Gram', 0.21, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9d2c909f-392c-4309-a466-93e9659baf89', 'Sesame mix', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1ff22969-378a-444d-bbe7-0c8fa75f3c4a', 'Lotus stem', 'Vegetables', null, 186.5, 1, 'KG', 'Gram', 0.1865, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0f23d4ce-f18c-47c6-9fdd-b121076534e0', 'Chilli oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4e5af56f-97aa-4775-a828-1f4da55b9fc6', 'Fresh Sri Lankan Red Curry Powder Mix', 'Spices', null, 3000, 1, 'KG', 'Gram', 3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('441262f8-101c-4561-84a6-f9d446048257', 'Picked red paprika', 'Spices', null, 105, 1, 'KG', 'Gram', 0.105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ce1c43ab-3f96-4c5b-aed0-9816dc2fd613', 'Chilli Garlic Sauce - Sunflower oil', 'Oils & Fats', null, 187.14, 1, 'KG', 'Gram', 0.18714, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fd0bd2e8-06fe-4993-a506-b94e9fd4292f', 'Chilli Garlic Sauce - Chopped garlic', 'Spices', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e09d17a2-7ca6-4c59-a4b4-3f31f5d58054', 'Chilli Garlic Sauce - Soy sauce', 'Spices', null, 261.09, 1, 'KG', 'Gram', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6d2ce1e2-05e3-44a2-8c4e-4f2859bd03a8', 'Chilli Garlic Sauce - Hot sauce', 'Spices', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('51f94b65-f682-455a-a197-67d3ca505c8d', 'Chilli Garlic Sauce - Wok hei sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3f067417-7361-488b-83a1-80adc933760a', 'Chilli Garlic Sauce - Thai red chilli', 'Spices', null, 1063.4, 1, 'KG', 'Gram', 1.0634, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('56feff9c-0b84-4df0-9434-fb451bf35a37', 'Wok Hei Sauce - Chilli bean', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5977bd69-286a-47e1-af18-c2e0121f358b', 'Wok Hei Sauce - Shao hsing', 'Sauces & Condiments', null, 208.6, 1, 'KG', 'Gram', 0.2086, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6de2f8fa-bfbe-4f54-8cd4-1520ab58e12b', 'Wok Hei Sauce - Soy sauce', 'Sauces & Condiments', null, 261.09, 1, 'KG', 'Gram', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2e24a788-91b0-4505-aba4-3304255b5d0d', 'Wok Hei Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c347b5e0-6e6a-4335-905a-1e019701ed00', 'Wok Hei Sauce - Cinnamon powder', 'Spices', null, 433.64, 1, 'KG', 'Gram', 0.43364, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f04ad98b-6580-438e-95d6-fe93f0a37a4d', 'Wok Hei Sauce - Sugar', 'Sauces & Condiments', null, 51.94, 1, 'KG', 'Gram', 0.05194, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c64217bf-10e3-494b-aef2-da4a245287e8', 'Wok Hei Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f15b1e2c-669d-40a8-b7b2-ca2fd190968e', 'Teriyaki Sauce - Brown sugar', 'Sauces & Condiments', null, 82, 1, 'KG', 'Gram', 0.082, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b776dc8f-7da3-4804-923e-e2b1d43852c7', 'Teriyaki Sauce - Soy sauce', 'Sauces & Condiments', null, 261.09, 1, 'KG', 'Gram', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5a1a2284-2f01-4848-966f-077023ad504f', 'Teriyaki Sauce - Rice vinegar', 'Sauces & Condiments', null, 211.35, 1, 'KG', 'Gram', 0.21135, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c4dfc414-62e0-4d15-8e07-5de6ba0b5d05', 'Teriyaki Sauce - Corn starch', 'Sauces & Condiments', null, 68, 1, 'KG', 'Gram', 0.068, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e18c5cc6-8f91-4919-9bfc-0d9a442ae43e', 'Teriyaki Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d1fd0408-4099-4323-ae81-471a983f29f5', 'Teriyaki Sauce - Sesame seed', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72d51901-970b-40db-9d9a-f6b7db0f9a5b', 'Yaki Soba Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('901a7cc0-23ed-4585-a707-4304880603c4', 'Yaki Soba Sauce - Crushed black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('54241d24-91f5-415e-8aa1-4922c2c8ea11', 'Yaki Soba Sauce - Oyster sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4f679040-5b30-4bc5-aba0-c9b795008199', 'Yaki Soba Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('53641115-40d4-4049-bd87-73af1db08b71', 'Yaki Soba Sauce - Sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('da5d4b81-1f87-4c10-8faf-6a1cf4a8ce94', 'Yaki Soba Sauce - Corn starch', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4dbd5318-7d84-4f88-9d33-1ff8a0a10fd6', 'Yaki Soba Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1bf012c1-7d47-4975-82fd-3bb378ed808b', 'Yaki Soba Sauce - Hot sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3011eaa0-2d67-4aa3-ae06-b82962ff71c9', 'Chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('75a79058-1671-49f7-8aa6-16eefd9fe162', 'Red Bhavnagri chilli', 'Spices', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4cecda28-b23d-420a-aa02-fe96e4e88aca', 'Slurry', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('622c9c43-eb3f-4f8d-b727-195125031430', 'Gyoza wrappers', 'Other', null, 0.65, 1, 'Piece', 'Piece', 0.651, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32d429e9-e7ce-4dcd-8131-4d861d3bdd6a', 'Oil + Water (for steaming)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('997e233b-147b-4b55-8f90-479e1eb139d7', 'Ginger (paste)', 'Sauces & Condiments', null, 129.5, 1, 'KG', 'Gram', 0.1295, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5ec8f655-05f4-4770-8319-09b00b3a1369', 'Chinese cabbage', 'Vegetables', null, 157.9, 1, 'KG', 'Gram', 0.1579, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('283d1b7c-00f7-4aa2-98af-04d87bf188dc', 'Indian cabbage', 'Vegetables', null, 31.1, 1, 'KG', 'Gram', 0.0311, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('79f3e845-3142-4738-a5cf-093cebd394c2', 'Chilli besan paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('69bf50a8-ef47-4914-bc5b-a99b82f99dca', 'Gochujang', 'Sauces & Condiments', null, 648, 1, 'KG', 'Gram', 0.648, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3b7ae7fd-d19e-447d-b633-3fa7789a687c', 'Soy', 'Sauces & Condiments', null, 261.09, 1, 'KG', 'Gram', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7cd7a215-fa40-4d11-a431-7e0a3899b484', 'Sesame oil', 'Oils & Fats', null, 660, 1, 'KG', 'Gram', 0.66, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('abf6e107-ab2d-4967-813d-a2d614fc8ad5', 'Stock pwd', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8fc721c0-ef9a-4230-b7e7-b56381eda873', 'Boiled soy keema', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b66b6e1f-70f7-4545-8f3c-e8712f96edc9', 'Coriander leaf', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f23ae38f-8953-471d-a32c-357d93ead52d', 'Coriander stem', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0db17438-28bb-4a7e-81c6-64063c75cc95', 'Pickled ginger', 'Vegetables', null, 348.6, 1, 'KG', 'Gram', 0.3486, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b91e0b3d-3ac3-4ddc-bfe7-7ca2897b9cc6', 'Tempura flakes', 'Other', null, 134.78, 1, 'KG', 'Gram', 0.13478, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('36c07757-a8a8-40cf-975c-ac1a152ff5e7', 'Ketchup', 'Sauces & Condiments', null, 76, 1, 'KG', 'Gram', 0.076, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6edfe0ce-9e3f-4c16-a486-7d72fc90a4b9', 'Maple', 'Other', null, 1909.09, 1, 'KG', 'Gram', 1.90909, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('41dbe585-6949-4d0b-ba0a-ba32e6a75ce1', 'Oyster', 'Other', null, 253.05, 1, 'KG', 'Gram', 0.25305, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('93af0a57-67fb-40cd-be77-7a7469f063b8', 'Rice vinegar', 'Sauces & Condiments', null, 211.35, 1, 'KG', 'Gram', 0.21135, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('619356c0-9e81-4ac6-8e9d-3acd9723bf7b', 'Flour', 'Grains & Flour', null, 44.4, 1, 'KG', 'Gram', 0.0444, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('86453416-c2f9-4a51-a0f0-b020788c4c1b', 'Salt (pinch)', 'Spices', null, 28.5, 1, 'KG', 'Gram', 0.0285, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('69ba7082-7848-49b4-8730-d791a97cec79', 'Mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('73a115f4-2a73-4484-8ec9-b9c03fb39aa4', 'Mustard', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('462ab7ea-c3a0-4c0e-bbb3-58e6d5669cd1', 'Blanched edamame', 'Other', null, 450, 1, 'KG', 'Gram', 0.45, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f4ce6a2e-0b63-49f6-a744-59b99d2f43f7', 'Truffle pate', 'Other', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ec88f6f9-4aae-4d35-b1b6-bbf9cf1fe93f', 'Wrappers', 'Other', null, 0.65, 1, 'Piece', 'Piece', 0.651, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('03b1dea2-3c54-4eba-8c3b-bf2d33fbd8d7', 'Silken tofu', 'Protein', null, 675, 1, 'KG', 'Gram', 0.675, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'Gochugaru', 'Other', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a59ffabd-4213-4066-84b0-62dd93a609fa', 'Coconut cream', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cd2b5040-b7b6-4d74-a67f-ca15f04bb3b9', 'Honey', 'Sauces & Condiments', null, 215, 1, 'KG', 'Gram', 0.215, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7d9b1197-97eb-4b68-8c86-ba1883854214', 'Shaoxing wine', 'Other', null, 208.6, 1, 'KG', 'Gram', 0.2086, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c09efcdd-7fcc-4fe6-ab6f-85fe18faab4d', 'Jalapeños', 'Other', null, 241.7, 1, 'KG', 'Gram', 0.2417, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ac7ad56f-dc69-4017-a2c4-f6faf543214f', 'Green Bhavnagari chilli', 'Spices', null, 82.5, 1, 'KG', 'Gram', 0.0825, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fca3a08e-4a41-4c18-adf5-25000c6e5778', 'Kaffir lime leaf', 'Fruits', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3917d270-1cf1-48ee-bd4a-b81a8811831b', 'Lemongrass', 'Fruits', null, 123.9, 1, 'KG', 'Gram', 0.1239, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e3e2dc91-abda-47f6-a38e-38af9dc7e8b5', 'Cumin powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c14ad046-d44c-45e3-840c-8988103959b3', 'Hing', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('10f23a81-37fe-40db-94e2-90052c68ca0c', 'Pickled red Bhavnagri', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9bd8f0f8-a6c0-4ba9-8765-40c31c6889ee', 'Chilli Oil Dumplings filling', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4e397512-96ef-40ee-a107-93aac2032ed5', 'Red chilli powder', 'Spices', null, 898, 1, 'KG', 'Gram', 0.898, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7944e522-9eba-4a3f-bee8-99a4f9262b5d', 'Chilli Oil Dumplings paste', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('19188392-d841-4f27-a9f1-e47bef2a0825', 'Sichuan powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8bd98a82-5e75-4c24-921d-7c7dfb695dbe', 'Toasted Peanuts', 'Bakery', null, 192.43, 1, 'KG', 'Gram', 0.19243, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8df73ddf-a681-44aa-b2e0-23000a72b38d', 'Green spring onion', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('748496ba-4a5e-4558-9f69-5df36135427b', 'Fried glass noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('98b0d739-909c-433d-9808-c1718f27f89d', 'Saucy Momos', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e992ed95-4129-4cc9-9a44-c3c430d0ada6', 'Forest Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2a39595e-a452-4bf7-9743-174ada96b008', 'Truffle Edamame Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2a3a6398-1ed4-4e1e-9cf6-4f35f5633fad', 'Cheese & Chilli Dumplings', 'Dairy', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5f58ec3c-5b8e-4ec4-a458-ab25f782215b', 'Chestnut Gyoza', 'Bakery', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('328877b4-3177-47dc-9bd6-da75753c8d51', 'Broad Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5ee5e1a8-459f-4ace-b796-f2c9d386e4f5', 'Chili Crisp', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9e0049b2-b0bd-4474-92ca-21cac292cc51', 'Forest Dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b3057213-f257-4278-8d4c-2d5182a7f526', 'Red Momos Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b2482bca-c22b-4539-b10b-ed5ab54b70ad', 'Nori', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d6775fb8-0fce-4eb8-9795-d4965728f6ea', 'Buffalo sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('851d665c-baa8-4ef6-b4d5-bca8462c0c65', 'Avocado', 'Other', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('40e3faa2-618b-40fb-be39-9861c52887fe', 'Rice paper', 'Grains & Flour', null, 342.5, 1, 'KG', 'Gram', 0.3425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'Soy sauce', 'Sauces & Condiments', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7e46f4fa-2a38-4574-b47f-66e93a685155', 'Nori half sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dee40ee5-cdca-4a51-9bd5-4b7f9d27093f', 'Fried stem lotus', 'Vegetables', null, 186.5, 1, 'KG', 'Gram', 0.1865, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aca97449-3b31-417f-96a1-436f35a6621f', 'Dragon sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8207620f-a946-4e19-b606-f474b047a2e1', 'Nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ffb645e2-1414-4848-a48e-af60831da811', 'Alfanso mango', 'Fruits', null, 426.9, 1, 'KG', 'Gram', 0.4269, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ec88bbe6-bef9-484c-b2fd-33184c72d379', 'Chilly crisps and oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bda68944-7e9e-4acd-a0d5-173c95fd30f6', 'Ginger pickled', 'Vegetables', null, 348.6, 1, 'KG', 'Gram', 0.3486, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d527c27d-27ff-4ed8-aa22-b8574ca015db', 'Wasabi paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('41634c6b-76b7-4f18-9db6-42dd4e352e41', 'Micro greens', 'Other', null, 1043.5, 1, 'KG', 'Gram', 1.0435, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2f50d019-9a2c-4446-8322-9089710b743e', 'Nori sheets', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6ad85bc0-f1e5-49fa-a0bd-77775714b3e0', 'Fried Tofu toss on soy', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('57436ed7-b733-46c0-b929-2d607dc14f81', 'Unagi', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('64aea946-023f-49eb-a181-9b33f5868b07', 'Pickled radish', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('77922919-1a21-423d-9d2e-0316facd974b', 'Sautéed spinach with soy & garlic', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9a06f3df-1fff-4dec-ba17-ac5d8cbe4976', 'Sesame oil (for brushing)', 'Oils & Fats', null, 660, 1, 'KG', 'Gram', 0.66, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b1066e99-02cc-4586-82af-39b6c868bbcd', 'English cucumber', 'Vegetables', null, 54, 1, 'KG', 'Gram', 0.054, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4236381e-78ac-4b52-a071-8fb0b4b7d0d1', 'Red capsicum', 'Vegetables', null, 180.7, 1, 'KG', 'Gram', 0.1807, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4012d042-0f0c-40a9-8290-5727d14a813c', 'Jalapeño', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5919db3d-ef40-4692-8a5d-52d4304812ef', 'Tempura flex', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e3027fd3-f65e-49d3-b5b7-f6165aa50a5f', 'Salsa', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2b403a63-9f47-4b64-b646-3bd6de1156ec', 'Sweet chilli sauce', 'Spices', null, 243.98, 1, 'KG', 'Gram', 0.24398, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('da84640d-84a8-4ec0-9754-a47ef8690d7a', 'Sriracha', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('78c0c616-8e2b-45e1-92be-0b75c3230879', 'Raw mango', 'Fruits', null, 56.4, 1, 'KG', 'Gram', 0.0564, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('19ccee31-760b-47b8-8f8c-ebdfb76477f5', 'Fried spring roll', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1988268a-a4d6-4899-bc8d-02f235035f5a', 'Purple cabbage', 'Vegetables', null, 188.1, 1, 'KG', 'Gram', 0.1881, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('77d09317-ea84-4d2d-a06b-2b8ccb08da5f', 'American corn', 'Vegetables', null, 80.7, 1, 'KG', 'Gram', 0.0807, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('11a45c4d-84ef-4e54-ad6a-3ba68c758e1b', 'Tempura flour', 'Grains & Flour', null, 134.78, 1, 'KG', 'Gram', 0.13478, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3a1c37c8-e698-4a09-954e-a30391edb3e6', 'Ginger (minced)', 'Vegetables', null, 129.5, 1, 'KG', 'Gram', 0.1295, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea7698c8-d33d-4b08-8625-c24a99d9da61', 'Corn', 'Vegetables', null, 80.7, 1, 'KG', 'Gram', 0.0807, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c083a251-d190-46d5-9225-31076a59b63b', 'Edamame', 'Other', null, 398.7, 1, 'KG', 'Gram', 0.3987, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d61d94d2-d7d1-43f2-8f1a-d86a1e110526', 'Cooked rice', 'Grains & Flour', null, 200.66, 1, 'KG', 'Gram', 0.20066, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('321437f4-b944-449e-a219-f791efaa1fcb', 'Light soy', 'Sauces & Condiments', null, 261.09, 1, 'Litre', 'ML', 0.26109, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cc8a5df2-b49f-4ab6-8348-e0e5c2a03d77', 'Broccoli', 'Other', null, 224, 1, 'KG', 'Gram', 0.224, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('61ebb76e-5dac-4813-89cd-acb368ee2dd1', 'Spinach', 'Vegetables', null, 60, 1, 'KG', 'Gram', 0.06, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1123d9d7-46f6-489a-bedb-a0b4a4c4c177', 'Button mushroom', 'Vegetables', null, 147.8, 1, 'KG', 'Gram', 0.1478, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('70a25e26-9b31-484b-8050-cda6bace69dc', 'Chili bean paste', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('38fae6a9-cbed-41ad-ab53-e81ae3fa41f6', 'Oyster sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a2c0276a-731c-47cd-ae50-e1534a459e11', 'Ginger-garlic paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1570a68a-7c5a-4b91-9f9a-2fa8a75682b1', 'Boiled hakka noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e4c5ac8f-46b2-4d17-bf18-03aee7d59afe', 'Hakka sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1c9af968-1d35-46b5-af10-231a5c215e0d', 'Mixed mushroom', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6be246c8-a851-43b1-86ae-557baa3b65a6', 'Spring onion whites', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c3707048-bfd2-43a6-98dc-2d1e1f75e615', 'Flat noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ad7a54b5-2ad1-40af-81bd-26670da157db', 'Bean sprouts', 'Vegetables', null, 342.7, 1, 'KG', 'Gram', 0.3427, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('74702423-2051-4375-8501-392654b9b2b1', 'Thai basil', 'Vegetables', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b88406e-4b70-4056-b390-5f54f51d914f', 'Mushrooms', 'Vegetables', null, 147.8, 1, 'KG', 'Gram', 0.1478, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3179d1e0-5238-4f20-bb1e-29666048ddc9', 'Rice noodles (soaked)', 'Grains & Flour', null, 234.9, 1, 'KG', 'Gram', 0.2349, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f913dd9d-b117-4643-b7a4-fa256c04ad9a', 'Pad Thai sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ba53882c-31ec-40fb-aef8-a8d12ab060b2', 'Roasted peanuts', 'Bakery', null, 192.43, 1, 'KG', 'Gram', 0.19243, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6c237f38-aceb-4d82-abb1-a7377cda111f', 'Lemon wedge', 'Fruits', null, 0.1, 1, 'Piece', 'Piece', 0.0971, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('83636a77-655c-4502-b909-6ba0abb0d28b', 'Maida noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dcf5b666-811f-44b7-9bea-bd462a1a2d3a', 'Veg stock', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6bd212b5-caac-4e54-b0a3-d36414f9a352', 'Dashi', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9f8af8dc-ede5-4bf1-afb5-8b0864f1c811', 'Shoyu tare', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5e99105e-27cd-4977-a50e-1b894af00d71', 'Ginger paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8381b475-79df-4fef-b2e7-66fb3fca7c32', 'Garlic paste', 'Sauces & Condiments', null, 180, 1, 'KG', 'Gram', 0.18, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d2a903d7-a457-4a07-a015-eb7e62415ffb', 'Chilli bean paste', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7b39beae-2d3a-422f-9639-8560c9dc04fb', 'Peanut butter', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('eb3d07d2-1f20-40ce-b940-cb92af9eb557', 'Ramen noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('daab5d2f-4e8f-4453-a318-ab54f5ba0b83', 'Caster sugar', 'Bakery', null, 80, 1, 'KG', 'Gram', 0.08, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('610d323e-53b9-497f-aa27-918be6e504ed', 'Chilli powder', 'Spices', null, 1066.7, 1, 'KG', 'Gram', 1.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f3af9fbd-df2b-407c-a451-2059d9fbf480', 'Peanuts (roasted)', 'Bakery', null, 192.43, 1, 'KG', 'Gram', 0.19243, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('43b0bd9e-e432-41f8-b9f9-70e8f2f8a2f7', 'Coriander (chopped)', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('684c7e70-a6f0-453c-8230-f322fa8192eb', 'Spring onion (chopped)', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1d522837-82b1-48f4-b92b-c563629ac746', 'Edamame (boiled)', 'Oils & Fats', null, 450, 1, 'KG', 'Gram', 0.45, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e51aaee4-3e6a-4a4d-90b4-39e1da49fde8', 'Pokchoy (blanched)', 'Vegetables', null, 118.5, 1, 'KG', 'Gram', 0.1185, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c9fc5068-eedf-4da2-ab57-0aa719f571aa', 'Lemon wedges', 'Fruits', null, 0.1, 1, 'Piece', 'Piece', 0.0971, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5ca86f40-4506-4e2d-8e90-41eefee0ea8b', 'Chilli crisp', 'Spices', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d6b3a0ce-c4f4-483b-82d2-d0b8eb2cb504', 'Boiled noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8d73f9ba-27f5-4e4c-8a35-79df1fcfa467', 'Spring onion (garnish)', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1a98bbba-ba21-4d16-8fc0-971760394309', 'Fried garlic (garnish)', 'Vegetables', null, 182.3, 1, 'KG', 'Gram', 0.1823, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b45d7a25-7a53-458f-813a-0e79be62783e', 'Spicy Pomodoro Sauce', 'Sauces & Condiments', null, 239.4, 1, 'KG', 'Gram', 0.2394, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1f98c747-ac43-4825-b8de-9f09be5683b4', 'Capers', 'Other', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('23eabb64-56da-4b14-863a-9a1cc4009973', 'Garlic Ricotta', 'Dairy', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('742e23f7-5803-448a-b155-30574f44e421', 'Basil Pomodoro Sauce', 'Sauces & Condiments', null, 202.6, 1, 'KG', 'Gram', 0.2026, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('352ccd94-c060-4012-b8dd-3aa8b30d8f64', 'Garlic slice', 'Vegetables', null, 285.7, 1, 'KG', 'Gram', 0.2857, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1ca8f1ff-2b10-46fc-a3d6-2258da9439e5', 'Artichoke', 'Other', null, 1020, 1, 'KG', 'Gram', 1.02, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('158fc248-9c91-4749-ba44-e387deef2190', 'Feta cheese', 'Dairy', null, 775, 1, 'KG', 'Gram', 0.775, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('df1c63b1-3355-4382-b149-49b0a2159acf', 'Marinated Arugula', 'Vegetables', null, 462.6, 1, 'KG', 'Gram', 0.4626, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6df88110-3968-4b86-a39e-b1b3381ba3f3', 'Amul Fresh Cream', 'Dairy', null, 206.7, 1, 'KG', 'Gram', 0.2067, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8ae07204-8219-4283-b67b-10e18a4b2231', 'Basil Pesto', 'Sauces & Condiments', null, 408.5, 1, 'KG', 'Gram', 0.4085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'Buffalo Mozrella', 'Other', null, 920, 1, 'KG', 'Gram', 0.92, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5f21fc08-7cb3-45eb-a53d-9284e9723877', 'Garlic oil', 'Oils & Fats', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5638d2ae-1e20-422f-9785-2ff491225b08', 'Gochujgaru', 'Other', null, 4666.7, 1, 'KG', 'Gram', 4.6667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('df195fb3-dc30-4d04-999f-a7b229f67e44', 'Buratta cheese', 'Dairy', null, 929.4, 1, 'KG', 'Gram', 0.9294, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('80f17bb0-97a1-45c5-9d7f-d6e910277c6e', 'Dil leaves', 'Other', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e8b34652-b7b6-47d6-82a1-09b1048eff5d', 'Chiili crips oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('12eb788d-89f4-47c7-8474-d351c892e46b', 'Corn mix', 'Vegetables', null, 321, 1, 'KG', 'Gram', 0.321, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('91a2b87f-e187-4618-a3bc-b53f377b412c', 'Jalapeno slices', 'Beverages', null, 80.3, 1, 'KG', 'Gram', 0.0803, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('95e967fa-28b1-433a-a5fe-0aee85ed8b78', 'Garlic slices', 'Vegetables', null, 269.8, 1, 'KG', 'Gram', 0.2698, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('171b8d69-bacf-452a-a84a-d69758955a55', 'Black sesame (crust)', 'Spices', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('26027f44-3125-4b73-9471-fb82a8be287e', 'Chilli butter dollop', 'Dairy', null, 509.2, 1, 'KG', 'Gram', 0.5092, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bef0357c-33ac-4d46-80d5-4083cd35c574', 'Dynamite crunch', 'Other', null, 464.5, 1, 'KG', 'Gram', 0.4645, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bcde52da-bafc-4168-a3cf-7a930863218b', 'Slice garlic', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('991dd58f-8b7c-45d5-a48b-3f1e3fdfc113', 'Chooped garlic', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ee1e9825-df4b-4b73-b607-26e8e0709ef9', 'Red Sriracha', 'Other', null, 481.6, 1, 'KG', 'Gram', 0.4816, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d619cdce-a51a-430d-a3ea-fada494268fc', 'Smoked cheese', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c63a238a-4b8c-4e71-b1a6-3695e127b415', 'Honey butter drizzle', 'Dairy', null, 433, 1, 'KG', 'Gram', 0.433, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4903a3a4-140f-4206-b913-dd22872d1bec', 'Chimichurri (chunky)', 'Other', null, 826.4, 1, 'KG', 'Gram', 0.8264, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ddf87480-d990-4df4-b37e-a05bf95051f3', 'Whipped feta dollop', 'Other', null, 949.7, 1, 'KG', 'Gram', 0.9497, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('88ffe768-cab0-4a50-a083-dbcafc9f8752', 'Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e5355dae-dcbf-45c0-aa02-29c37516fb6c', 'Black olive', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('390bbf7d-c6eb-4dd3-8cbe-584a97c091e6', 'Green Bellpaper', 'Vegetables', null, 121.5, 1, 'KG', 'Gram', 0.1215, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c91d1e17-2a3a-4043-823b-85b4afd2fc57', 'Marinated Aragula', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('162a7177-11a9-4566-b701-8398104b9a86', 'Slice almond', 'Bakery', null, 834, 1, 'KG', 'Gram', 0.834, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e620724a-0223-4206-8f1a-f78e03233914', 'Green Chilli', 'Spices', null, 41.5, 1, 'KG', 'Gram', 0.0415, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bbe202d5-27ce-4ffa-bbcc-19937fe0f18d', 'Black Sliced Olives', 'Beverages', null, 213.79, 1, 'KG', 'Gram', 0.21379, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4d0fd5d1-ff62-4231-9540-4666f18d9a85', 'Ring bell pepper', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c88d0ae1-9e2f-4d72-bdfb-fa820ac2d8ed', 'Ring onion', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a4e13b20-9ba7-4ec3-9d43-227cebde4296', 'Chili oil', 'Oils & Fats', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('06997708-d333-4d2c-9bf0-0ef5e9182796', 'Ghost Paper', 'Other', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5ec7ee38-45f5-4028-8808-6d0f19a82faa', 'Roasted Bell paper', 'Vegetables', null, 253.8, 1, 'KG', 'Gram', 0.2538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0162100d-0a90-49be-a1b4-75fd9424996a', 'Red Paprika Slices', 'Spices', null, 105, 1, 'KG', 'Gram', 0.105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2d128e1f-0b74-4869-99fa-f2b89a5ba586', 'Fresh Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c115666f-52eb-4347-91de-dd65c5b1e3d0', 'Green Sriracha Sauce', 'Sauces & Condiments', null, 345.3, 1, 'KG', 'Gram', 0.3453, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f4d46e7b-f84a-45a9-b92d-8005a8858001', 'Ghost Peper', 'Other', null, 5710, 1, 'KG', 'Gram', 5.71, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d82f502d-a1e6-4938-bbc3-8da5db50d03e', 'Buffalo Mozzarella', 'Dairy', null, 820.8, 1, 'KG', 'Gram', 0.8208, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9f77dac3-e200-4b5a-b21a-551b030f94f5', 'Boiled Broccoli', 'Oils & Fats', null, 455, 1, 'KG', 'Gram', 0.455, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c077485-48f9-482c-b392-15736a3508f4', 'Red paprika sliced', 'Spices', null, 312.5, 1, 'KG', 'Gram', 0.3125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f91abaaf-3c45-4e92-80f2-667a6bd20fa8', 'Jalapenos', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b23c4006-7ac9-44dc-be25-c64027464b03', 'Orange sauce', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('600ea11b-1de4-4592-abdb-f59d19e416e3', 'Ornage sauce', 'Sauces & Condiments', null, 227.5, 1, 'KG', 'Gram', 0.2275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a09c6eaf-3024-4870-b107-4264ffe92a54', 'TRUFFLE PASTE', 'Sauces & Condiments', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b9ab6e97-c2ef-4e35-9afd-bb3ec2f27a17', 'Processed Basil Leaves', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7f87fc93-156b-4e76-a25a-9ea16a4397fe', 'Processed Broccoli', 'Other', null, 224, 1, 'KG', 'Gram', 0.224, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('2aa6e99a-8b7e-45c0-8f96-70db7bf246f6', 'Processed Coriander', 'Vegetables', null, 72.1, 1, 'KG', 'Gram', 0.0721, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f73018d6-2b7a-44f9-9e92-809011856f4f', 'Processed Dill Leaves', 'Other', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('731ff633-4ec3-49c8-bf9f-580357b2d86c', 'Processed Green Garlic', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('766f114a-94f7-4904-87d0-2d789ad19156', 'Processed Iceberg', 'Vegetables', null, 179.1, 1, 'KG', 'Gram', 0.1791, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f3192d49-a4ce-4593-b225-2c09a4d3e32a', 'Processed Mint', 'Other', null, 25.7, 1, 'KG', 'Gram', 0.0257, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('aa4a6af7-2b36-4d41-a820-0bd893f3d729', 'Processed Alphonso Mango', 'Fruits', null, 426.9, 1, 'KG', 'Gram', 0.4269, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('18e02edb-d4c3-4e73-af3c-355208d96966', 'Processed Arugula', 'Vegetables', null, 462.6, 1, 'KG', 'Gram', 0.4626, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('04882e9b-263d-4790-a223-4f4de0b1ae14', 'Processed Jamun', 'Other', null, 310.6, 1, 'KG', 'Gram', 0.3106, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('b4cc5fc5-1d8a-4033-bddb-21ba34b08b7a', 'Processed Red Chilli', 'Spices', null, 87.5, 1, 'KG', 'Gram', 0.0875, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7fa82ab6-833e-443f-af10-d12b6c7fc883', 'Processed Brussels Sprouts', 'Vegetables', null, 900, 1, 'KG', 'Gram', 0.9, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('82d9a001-3030-49a6-a120-3cd1f2a478f8', 'Processed Shimeji Mushroom', 'Vegetables', null, 481.5, 1, 'KG', 'Gram', 0.4815, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('c8717b8a-77e1-45d8-b9ce-c823224200a4', 'Processed Pineapple', 'Fruits', null, 134.3, 1, 'KG', 'Gram', 0.1343, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('cdd6e73d-660e-4adf-8003-b41d1b1ef1ef', 'Processed Thai Red Chilli', 'Spices', null, 1063.4, 1, 'KG', 'Gram', 1.0634, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('aead1485-f135-4fc9-a1d5-98acd8c52aba', 'Processed Bok Choy', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('eb5acb8a-8a59-495f-bdfd-23390d8d9a97', 'Processed Lemongrass', 'Fruits', null, 123.9, 1, 'KG', 'Gram', 0.1239, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('65f1c0b8-fed5-4c30-8133-c59285da9a74', 'Processed Spinach', 'Vegetables', null, 60, 1, 'KG', 'Gram', 0.06, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('47239ee6-5a29-4412-aeee-91709e814ab0', 'Processed Baby Corn', 'Vegetables', null, 137.4, 1, 'KG', 'Gram', 0.1374, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('6bd4819e-f980-4734-a355-0ccc7b195621', 'Processed Leeks', 'Vegetables', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('4c195e1a-c8ce-4031-9f41-7fce1c36a023', 'Chopped Cucumber', 'Vegetables', null, 52.5, 1, 'KG', 'Gram', 0.0525, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('99a24907-c978-44a2-8b70-bbc0b8a3f716', 'Chopped Green Chilli', 'Spices', null, 122.5, 1, 'KG', 'Gram', 0.1225, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('a3765e39-a88b-4224-bbe9-958d8ac14a18', 'Chopped Green Garlic', 'Vegetables', null, 507, 1, 'KG', 'Gram', 0.507, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('fade9643-a224-4bcb-ba39-59679fa3c5d7', 'Chopped Parsley', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('010bc728-2aba-4739-b576-64ef66311216', 'Chopped Tomatoes', 'Vegetables', null, 68.3, 1, 'KG', 'Gram', 0.0683, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('c47cfb9b-cc89-4b3d-8ca5-cfb9b1e0166f', 'Chopped Carrot', 'Vegetables', null, 56.2, 1, 'KG', 'Gram', 0.0562, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('f5206df6-3f28-4b8e-87cf-43a8f1c3f14c', 'Chopped Ginger', 'Vegetables', null, 129.5, 1, 'KG', 'Gram', 0.1295, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('9b02ebe6-e1dc-40c0-a390-135ffb87fa07', 'Chopped Green Bell Pepper', 'Vegetables', null, 121.5, 1, 'KG', 'Gram', 0.1215, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('996a4485-71c1-4ad1-b9fb-f5a842f366f4', 'Chopped Chinese Cabbage', 'Vegetables', null, 157.9, 1, 'KG', 'Gram', 0.1579, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('4556dec3-325f-4b7e-831e-bcc0d9099c5f', 'Chopped Indian Cabbage', 'Vegetables', null, 31.1, 1, 'KG', 'Gram', 0.0311, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('721ca00b-e52e-4f6d-845a-450dcaf6fc9b', 'Sliced Jalapenos', 'Beverages', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('09f5ef06-3cd7-45b3-bc2d-e2a84fa07b8b', 'Sliced Zucchini', 'Beverages', null, 171.9, 1, 'KG', 'Gram', 0.1719, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('bfa17b2c-55cd-4cb9-984f-1a7bd5841efa', 'Sliced Carrot', 'Vegetables', null, 50.6, 1, 'KG', 'Gram', 0.0506, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('1d10cb82-dc36-4c2e-85c8-45bb27c8142e', 'Sliced Cucumber', 'Vegetables', null, 52.5, 1, 'KG', 'Gram', 0.0525, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('1baa59aa-dc62-41e2-9593-5c59bf8593ad', 'Sliced Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('a2407dbf-0b3f-459f-9630-4110184f406b', 'Sliced Onion', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('5ff5b05b-1c1b-4313-883a-b0c9d5ede47a', 'Sliced Lotus Root', 'Vegetables', null, 187.7, 1, 'KG', 'Gram', 0.1877, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('28b06627-a880-4631-9bc4-a5d05c5b1c57', 'Sliced Purple Cabbage', 'Vegetables', null, 188.1, 1, 'KG', 'Gram', 0.1881, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('8a8bbeb6-7923-4afd-9fcc-070fd90c84f7', 'Thin Sliced White Spring Onion', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('693d0631-f962-4a7b-b68d-588b34fc6415', 'Cut Broccoli', 'Other', null, 224, 1, 'KG', 'Gram', 0.224, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('baf21e30-369d-452d-be76-fe4edc744794', 'Cut Carrot', 'Vegetables', null, 50.6, 1, 'KG', 'Gram', 0.0506, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('8234fee4-ce8f-4e5d-aae6-40851d297b4f', 'Cut French Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('c2edcf53-8b01-4808-ac02-64dcbf21f788', 'Cut Zucchini', 'Other', null, 171.9, 1, 'KG', 'Gram', 0.1719, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('c832697f-50c6-4c2d-9629-bf57832c66a6', 'Bell Pepper Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('6818a882-ddcd-4018-96c9-58a5b09582f0', 'Cucumber Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('26b98da8-30c7-4b04-b91d-743151d1479d', 'Onion Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('4fa96aa8-47c4-4cf0-b504-3ef160054d3a', 'Diced Onion', 'Vegetables', null, 27.5, 1, 'KG', 'Gram', 0.0275, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('b41f9a35-ec5c-47f3-829a-3d174167c0fc', 'Diced Grapefruit', 'Fruits', null, 227.7, 1, 'KG', 'Gram', 0.2277, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('9c516874-bfb6-4e02-bc0a-1e0e9314771c', 'Watermelon Juice', 'Fruits', null, 83.3, 1, 'KG', 'Gram', 0.0833, '2026-06-01', 'active', 'Prep yield (Juiced)', '2026-06-01T09:00:00.000Z'),
('77e27617-ce99-4fe5-bc07-1dbefd9795d2', 'Whole Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('26cab8ff-4246-427a-8147-1b823c0445d0', 'Whole Parsley', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('6fae982a-0de0-4db1-ab66-4dc5899e1fea', 'Spring onion 1/2', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('1be22f9c-1bf3-4098-8df8-f8cc89743305', 'Dried Sirarakhong Chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('e1a0dadb-f8cb-4790-b6c8-cfd431dd6e59', 'Dolce Vita Peeled Tomatoes - 3kg', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('12c8c0f7-ddc1-4836-91a6-b95a6c36d874', 'Black Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('a1497002-02f3-4cd9-bee8-75b4217c7632', 'Red Kidney Beans', 'Other', null, 187.5, 1, 'KG', 'Gram', 0.1875, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('d4e5517e-852b-4e55-a222-a96bb873d79d', 'Artichoke Hearts', 'Other', null, 517.5, 1, 'KG', 'Gram', 0.5175, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('6a5d14e8-80d9-4f5c-9362-0f5cc6b0d0c0', 'Sliced Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('34d6b501-2c2b-4a94-8fe6-946202ae39d4', 'Jalapeño Slices', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('23e939ca-7dbc-4ffd-a401-3b1af3a8cb48', 'Boiled Fettuccini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('812eca18-b3f7-48c8-9a3d-a10c4f2fc400', 'Boiled Conchiglioni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('c513d370-99aa-4b76-80ad-6efb1a6ee4bb', 'Boiled Rigatoni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('fc14efb4-844e-496d-94e0-16dc003df799', 'Boiled Penne', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('a6106bef-e449-464c-aac9-965f37919830', 'Boiled Arborio Rice', 'Oils & Fats', null, 377.2, 1, 'KG', 'Gram', 0.3772, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('93c3f13b-38e3-4f01-8a35-360c01cd3fb5', 'Orange Zest', 'Fruits', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Zest)', '2026-06-01T09:00:00.000Z'),
('2cba9fcc-80a7-44ae-8f56-80328da8f1f4', 'Roasted Bell Pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', 'Prep yield (Roasted)', '2026-06-01T09:00:00.000Z'),
('58598e51-7af5-489e-8a75-26117701f8b8', 'Dehydrated Lemon Slices', 'Fruits', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', 'Prep yield (Dehydrated)', '2026-06-01T09:00:00.000Z'),
('a6785c44-5fff-4c71-b6c9-0006d4d0ad2d', 'Julienne Chinese Cabbage', 'Vegetables', null, 157.9, 1, 'KG', 'Gram', 0.1579, '2026-06-01', 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('5e54990c-1b02-4927-b5fc-90aee4a2bdb4', 'Julienne Indian Cabbage', 'Vegetables', null, 31.1, 1, 'KG', 'Gram', 0.0311, '2026-06-01', 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('cc88b3b6-c76d-40b5-8d1e-10686966b3a9', 'Julienne Leeks', 'Vegetables', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('652b37ce-5e12-4ce6-95cf-0ca709da499e', 'Alphonso Mango', 'Fruits', null, 426.9, 1, 'KG', 'Gram', 0.4269, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('fa123415-9c36-43aa-82d2-917afb8f2ad5', 'Apple', 'Fruits', null, 220, 1, 'KG', 'Gram', 0.22, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('9d5e405d-dd07-4f77-b5a5-7d1c85e06c1d', 'Apple (Premium)', 'Fruits', null, 1466.7, 1, 'KG', 'Gram', 1.4667, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('26ceb613-baa8-44c9-a336-3bfdec3573b7', 'Avocado Imported', 'Fruits', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('c927424e-bc01-4de4-a3b0-c45962ce66d8', 'Banana', 'Fruits', null, 50.7, 1, 'KG', 'Gram', 0.0507, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('a223562d-0780-40b9-979d-2018deb031c2', 'Black Grapes', 'Fruits', null, 460, 1, 'KG', 'Gram', 0.46, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('ab2a493b-e7a7-4d4f-8d8b-aadcd15a058f', 'Gauva', 'Fruits', null, 140, 1, 'KG', 'Gram', 0.14, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('dd324f28-a1b9-43e5-96a0-fd70b0cb4573', 'Green Apple', 'Fruits', null, 330, 1, 'KG', 'Gram', 0.33, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('9fd739b1-7127-4560-84e0-33eaa1748198', 'Green Grapes', 'Fruits', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('796500af-b906-4e18-b05c-5536b667b8ed', 'Hass Avocado', 'Fruits', null, 605.4, 1, 'KG', 'Gram', 0.6054, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('37bf2dc5-8a6c-4ed2-b6b2-5bb9b53660e9', 'Italian Lemon', 'Fruits', null, 707.2, 1, 'KG', 'Gram', 0.7072, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4f2eeb74-64a1-47ca-abdb-d66d0e097b45', 'Jackfruit', 'Fruits', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('889ab4fe-4726-4f01-89b8-36254ff16196', 'Jamun', 'Fruits', null, 310.6, 1, 'KG', 'Gram', 0.3106, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('92667195-8e14-4aff-aa74-6027496e2cf6', 'Kaffir Lime', 'Fruits', null, 1027.3, 1, 'KG', 'Gram', 1.0273, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4c61ab3e-4e04-4e60-bd6d-dee2ae7d6527', 'Kiwi', 'Fruits', null, 228.6, 1, 'KG', 'Gram', 0.2286, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('326cd764-ec7c-4a53-8083-abf9687ffa78', 'Lemon', 'Fruits', null, 97.1, 1, 'KG', 'Gram', 0.0971, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('9417b10d-2f3b-43b9-8590-4f53af0bd452', 'Litchi', 'Fruits', null, 19836.7, 1, 'KG', 'Gram', 19.8367, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('a3b70523-007a-488f-9df8-ec274b280643', 'Malta', 'Fruits', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('fe6f8cd9-5584-42b5-9095-6e30d3dc7839', 'Mango', 'Fruits', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('421e35ad-1d32-4225-900b-3f8f6c8519bf', 'Orange Imported', 'Fruits', null, 146.3, 1, 'KG', 'Gram', 0.1463, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b83e7d7e-7d0f-4808-bffc-7d53eb99a092', 'Peach', 'Fruits', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('29a87e42-ca92-4d59-a19d-a3f7c68dc777', 'Pear', 'Fruits', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('f1860ac1-d265-4d00-b0b7-ab4d2dcd16b0', 'Pineapple', 'Fruits', null, 134.3, 1, 'KG', 'Gram', 0.1343, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('551e76a4-199f-4b58-822c-228fc6dc5299', 'Pineapple (Premium)', 'Fruits', null, 147.5, 1, 'KG', 'Gram', 0.1475, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d19cb8ed-f746-4077-a99a-988aad875b15', 'Pineapple Peeled', 'Fruits', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d14a2ce1-8bef-40c1-bee9-a42d45a6aa9e', 'Pineapple Peeled (Premium)', 'Fruits', null, 198.2, 1, 'KG', 'Gram', 0.1982, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('844d6df4-8235-43df-bbd0-f9571a8f6b06', 'Pineapple Whole', 'Fruits', null, 108, 1, 'KG', 'Gram', 0.108, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d445ea2c-8b33-4c50-9c6b-bec1f1055f76', 'Pomegranate -anar', 'Fruits', null, 164.3, 1, 'KG', 'Gram', 0.1643, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('0f8043ec-4cd7-4ef0-a0f5-8c57e98752ac', 'Row Banana', 'Fruits', null, 45, 1, 'KG', 'Gram', 0.045, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('fa39914b-852f-4071-a735-e4a47a6a3cf1', 'Watermelon', 'Fruits', null, 31.5, 1, 'KG', 'Gram', 0.0315, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('42a4dd3d-25e2-4316-b148-7fc54f5b2ab8', 'Baby Spinach 100gms', 'Vegetables', null, 140, 1, 'KG', 'Gram', 0.14, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('a22d208d-aa54-430c-bd8f-653a50d9ffb3', 'Beans Sprout', 'Vegetables', null, 250.4, 1, 'KG', 'Gram', 0.2504, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d8d865bb-dd0a-44ce-97c1-80fa63d8c2bc', 'Bhavnagari Red Chilli', 'Vegetables', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('0fbd506f-8ddf-41a9-835f-d4fc70bf3a74', 'Bird Eye Thai Red Chilli', 'Vegetables', null, 1063.4, 1, 'KG', 'Gram', 1.0634, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('54416ded-1f37-45b2-a828-dc38212eb2b5', 'Bokchoy', 'Vegetables', null, 118.5, 1, 'KG', 'Gram', 0.1185, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('39f6a757-841d-47ac-a157-741eda77435d', 'Brinjal', 'Vegetables', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('8df556ac-ba72-40e3-a932-11667fb11d0e', 'Brussels Sprouts.', 'Vegetables', null, 822.5, 1, 'KG', 'Gram', 0.8225, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('139731b9-6adc-45a7-850e-eac7cd544806', 'Button Mushrooms', 'Vegetables', null, 147.8, 1, 'KG', 'Gram', 0.1478, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e3ceb933-d755-42e3-9817-67b4a1c2fe8a', 'Chilli Broad Beans 120gm', 'Vegetables', null, 534.5, 1, 'KG', 'Gram', 0.5345, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('53427b9b-83a3-4f45-9b4c-a3918ab07149', 'Chinese Cucumber', 'Vegetables', null, 285.7, 1, 'KG', 'Gram', 0.2857, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d4c2be88-ec95-4aa7-ae6b-5254624a0801', 'Chinese Cucumber (Premium)', 'Vegetables', null, 300.2, 1, 'KG', 'Gram', 0.3002, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b1eb79df-2bbd-43fc-a949-0040037e72d6', 'Curly Kale', 'Vegetables', null, 350, 1, 'KG', 'Gram', 0.35, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('3f835355-d22b-4886-a634-6181ef6144a5', 'Dil Leaves .', 'Vegetables', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('ce34f572-fa1c-4b86-853e-8546c92dc567', 'Edamame Kernal 500gm', 'Vegetables', null, 399.2, 1, 'KG', 'Gram', 0.3992, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d3e7bf8c-6ada-44bf-9e84-db041a9a827c', 'Edamame Pods 500gm', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('5e8751d0-e5f6-45bc-82e1-be6d49b0fd5e', 'Fansi- Beans', 'Vegetables', null, 162.5, 1, 'KG', 'Gram', 0.1625, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('a9e1d5d0-3fef-44c1-97e1-a4c0dd7bad97', 'Fennel Bulb', 'Vegetables', null, 1600, 1, 'KG', 'Gram', 1.6, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('dcc27fbf-c645-4f22-a23b-6f2c3dbebd94', 'Flower', 'Vegetables', null, 87.8, 1, 'KG', 'Gram', 0.0878, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b9f68998-a51a-4f39-9f8a-dde6e1fd79a7', 'Fresh Babycorn', 'Vegetables', null, 137.4, 1, 'KG', 'Gram', 0.1374, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e4a36099-025d-4701-abda-bd13419f33fd', 'Fresh Jalapenos', 'Vegetables', null, 237.1, 1, 'KG', 'Gram', 0.2371, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('1452ba5c-c182-4e3c-87c6-1e5236ea6a82', 'Fresh Jalepenos Green', 'Vegetables', null, 292.7, 1, 'KG', 'Gram', 0.2927, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('109096d3-b882-405a-9d65-e315f6744a0d', 'Fresh Jalepenos Red', 'Vegetables', null, 264.2, 1, 'KG', 'Gram', 0.2642, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('3fdb2e3a-5ffb-4a51-8ca5-2f2ace2ca684', 'Frozen American Corn', 'Vegetables', null, 80.7, 1, 'KG', 'Gram', 0.0807, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4f099881-46ab-4f4e-b9e5-be438c9857e1', 'Garlic Chop', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b1f30ca3-6379-4e4d-b306-49e1b4b400f5', 'Ginger.', 'Vegetables', null, 129.5, 1, 'KG', 'Gram', 0.1295, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('a85b6bd4-7257-462a-b84c-0d5a541e49e6', 'Green Bell Pepper', 'Vegetables', null, 121.5, 1, 'KG', 'Gram', 0.1215, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b491a04b-0985-4166-b1f2-438c3ccbc1d5', 'Green Bhavnagri', 'Vegetables', null, 82.5, 1, 'KG', 'Gram', 0.0825, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('c6b6ffa4-792e-4a10-b55e-23ac16dee3a9', 'Green Capsicum', 'Vegetables', null, 87.9, 1, 'KG', 'Gram', 0.0879, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('b5b4b00f-ad88-4d45-80e5-2e42e6705869', 'Green Chilli Small', 'Vegetables', null, 92.8, 1, 'KG', 'Gram', 0.0928, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e1f3218d-ec8e-49c9-b518-f6dd8221a22b', 'Green Zucchini', 'Vegetables', null, 171.9, 1, 'KG', 'Gram', 0.1719, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('ebdad0a5-1f93-4a31-b2c8-a5f0448ceee8', 'Hydronic Iceburg Lettuce', 'Vegetables', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('aa59a9e6-3adc-4361-bf71-2ab6540dd857', 'Hydronics Spinach', 'Vegetables', null, 75, 1, 'KG', 'Gram', 0.075, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('379b644d-f77c-4960-8a42-9644e40cddca', 'Hydroponic English Cucumber', 'Vegetables', null, 50, 1, 'KG', 'Gram', 0.05, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('715a304d-ca88-4602-9092-f6a695abb66e', 'Hydroponic Roquette Wild', 'Vegetables', null, 660, 1, 'KG', 'Gram', 0.66, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('300d75bb-552b-4d1d-b2a8-4bab6765688c', 'Iceberg Lettuce.', 'Vegetables', null, 154.7, 1, 'KG', 'Gram', 0.1547, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e2be9e94-67ff-41dc-8c4e-0e9493a07ffe', 'Iceburg Lettuce', 'Vegetables', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('6b99f1da-209d-4d6b-91a7-24e6c809d7ca', 'Jalapeno Hot Chill Red', 'Vegetables', null, 185, 1, 'KG', 'Gram', 0.185, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('3aad0971-d2ca-4869-b632-cb414f5c3215', 'Jalapeno Hot Chilly Green', 'Vegetables', null, 309.4, 1, 'KG', 'Gram', 0.3094, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('357498ac-6583-4a60-bd88-5692f114e819', 'Kafir Lime Leaves.', 'Vegetables', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('00593813-f6dc-497d-b449-552e469bd1fa', 'King Oyster Mushroom', 'Vegetables', null, 930, 1, 'KG', 'Gram', 0.93, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4b7957e6-f22e-4c7e-b16c-656e529b58e1', 'Leek', 'Vegetables', null, 548.4, 1, 'KG', 'Gram', 0.5484, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4f52fccc-a726-4480-9adc-13e9dd4f1a8c', 'Leeks', 'Vegetables', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('09160cd3-a4ca-46af-8f5f-0e21230a052c', 'Lemon Grass', 'Vegetables', null, 123.9, 1, 'KG', 'Gram', 0.1239, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('93e9f108-127e-4e26-a8de-f1c9e2c1d9b5', 'Lemon Green', 'Vegetables', null, 95.8, 1, 'KG', 'Gram', 0.0958, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('2046a010-f7ac-4341-8206-f33f0ae9d80f', 'Lollo Rosso', 'Vegetables', null, 373.1, 1, 'KG', 'Gram', 0.3731, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('2d51a60c-0c99-4f82-b537-bb06b61c7ce3', 'Lolo Lettuce', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('9c935d58-cf65-4fac-ad1d-673a10c6e161', 'Lotus Roots', 'Vegetables', null, 187.7, 1, 'KG', 'Gram', 0.1877, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('41bed33e-b7eb-47af-a165-f5ab8d1c3d0a', 'Methi Big Fresh', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('014787f9-a587-4e7a-acc1-4fa0ea1cbb71', 'Micro Green', 'Vegetables', null, 1043.5, 1, 'KG', 'Gram', 1.0435, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e154e3db-d5cf-4174-b0eb-8784a0c79207', 'Microgreen', 'Vegetables', null, 1826.1, 1, 'KG', 'Gram', 1.8261, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('c471b670-eff3-4f41-b0a1-2aafed523f58', 'Microgreens', 'Vegetables', null, 1565.2, 1, 'KG', 'Gram', 1.5652, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('1242ec5f-8e3d-48a4-9494-ba972bdf41ad', 'Mint', 'Vegetables', null, 25.7, 1, 'KG', 'Gram', 0.0257, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('d62a953f-5589-45e1-8338-af2c34583361', 'Mint (Premium)', 'Vegetables', null, 344.9, 1, 'KG', 'Gram', 0.3449, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e753ebee-6045-44f2-96d2-6bd41e5ec8bc', 'Mint Bunch', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('5c648787-8674-440a-b94f-ac4d7abbc60e', 'Mint Leaves', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('05fb6327-f8d1-4d60-a114-05cb10e1eade', 'Onion Whole', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('c5dfebdf-2afd-4e52-9dfb-6bef914d4565', 'Oyster Mushroom', 'Vegetables', null, 375, 1, 'KG', 'Gram', 0.375, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('9c33aa3c-1078-4b94-9448-e5090ad6ed1e', 'Peeled Garlic.', 'Vegetables', null, 182.3, 1, 'KG', 'Gram', 0.1823, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('4a002f69-effd-43ba-a9f4-e09f35c65ad1', 'Potatoes', 'Vegetables', null, 23, 1, 'KG', 'Gram', 0.023, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('2e1b9195-c5cf-48d3-a693-353d1da2cd1f', 'Pumpkin', 'Vegetables', null, 45, 1, 'KG', 'Gram', 0.045, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('97e1b584-0a76-41d1-8201-80a0f9604785', 'Red Bellpepper', 'Vegetables', null, 180.7, 1, 'KG', 'Gram', 0.1807, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('f807ad28-9575-49ff-8c8c-5e6099ac9327', 'Red Bhavnagri', 'Vegetables', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('ae0dd00b-7aff-4dd7-99a0-56923619516d', 'Red Cabbage', 'Vegetables', null, 140.7, 1, 'KG', 'Gram', 0.1407, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('eb86244f-3032-4db0-bd61-ebaea6d0f2d9', 'Red Chilli', 'Vegetables', null, 87.5, 1, 'KG', 'Gram', 0.0875, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('bafddc4e-4d24-42b9-8668-8de993b3aa50', 'Red Chilli Small', 'Vegetables', null, 95.7, 1, 'KG', 'Gram', 0.0957, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('7b6364d5-cf28-4f7f-9719-18af4670c43f', 'Red Potato', 'Vegetables', null, 30, 1, 'KG', 'Gram', 0.03, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('32ee0af3-9935-4155-b7fc-15a391133aad', 'Rocket /arugula Leaves', 'Vegetables', null, 462.6, 1, 'KG', 'Gram', 0.4626, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('19c439b0-5252-41ee-a6c3-7113de045805', 'Rocket /arugula Leaves 100gm', 'Vegetables', null, 462.7, 1, 'KG', 'Gram', 0.4627, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('c83efc13-5cf7-498a-ac95-2e073bfb7e44', 'Rocket /arugula Leaves 100gm (Premium)', 'Vegetables', null, 1109.5, 1, 'KG', 'Gram', 1.1095, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('def6b450-db3c-49ef-a9dc-549110828abd', 'Romaine Lettuce', 'Vegetables', null, 237.5, 1, 'KG', 'Gram', 0.2375, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('1b9c1223-3df3-4910-8500-84dc278ca2d9', 'Rosemary', 'Vegetables', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('eb419b20-b392-4c67-b4d0-de2ede316749', 'Shimeji Mushroom 125', 'Vegetables', null, 1086.7, 1, 'KG', 'Gram', 1.0867, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('7dedd391-ca60-4ec2-954f-e3ed9827a549', 'Shimeji White', 'Vegetables', null, 950, 1, 'KG', 'Gram', 0.95, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('86ce7693-107d-46af-af4a-5fec52087ca4', 'Small Onion', 'Vegetables', null, 20, 1, 'KG', 'Gram', 0.02, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e9f2b161-78a4-489e-b044-a922f19b7b17', 'Spinach Palak', 'Vegetables', null, 60, 1, 'KG', 'Gram', 0.06, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('f42ae7dc-2470-47fb-ac22-248280560780', 'Spring Onion .', 'Vegetables', null, 75.3, 1, 'KG', 'Gram', 0.0753, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('db715597-f41f-458b-9b62-c16bb755e785', 'Suva (Premium)', 'Vegetables', null, 2800, 1, 'KG', 'Gram', 2.8, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('e78d912d-dea8-4220-9fa7-7765306715f6', 'Suva', 'Vegetables', null, 70, 1, 'KG', 'Gram', 0.07, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('23995c2d-c39e-4d38-8206-d5fc3e49cf79', 'Sweet Corn Bhutta', 'Vegetables', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('7799c817-7beb-4c56-be30-0c29a3e2edb1', 'Sweet Corn Frozen Pkt', 'Vegetables', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('fb97f1e0-83fa-4145-be91-881911d71c98', 'Tomato Big', 'Vegetables', null, 47.8, 1, 'KG', 'Gram', 0.0478, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('333e5de8-01f1-44e2-addc-45b7c01c481b', 'Yellow Bellpepper', 'Vegetables', null, 166.1, 1, 'KG', 'Gram', 0.1661, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('60e5b114-7a2a-4311-8a5a-82c493736ce3', 'Zucchini Cut', 'Vegetables', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', 'Surat produce price master', '2026-06-01T09:00:00.000Z'),
('844a5d81-f49e-4e79-a568-e41d31319cd3', '00 Flour Bag', 'Dry Goods', null, 119.04, 1, 'KG', 'Gram', 0.11904, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('5477f42b-7a5d-4691-8d07-b322a5f46854', 'Agar Agar Powder', 'Bakery', null, 2970, 1, 'KG', 'Gram', 2.97, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b89ad63b-435c-43b1-9126-46360ca08768', 'Agave Syrup', 'Sauces & Seasoning & Oils', null, 920, 1, 'KG', 'Gram', 0.92, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a983b00a-29e1-4521-8a35-75de06fcbfb8', 'Almond Flour', 'Dry Goods', null, 1125, 1, 'KG', 'Gram', 1.125, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('cbf2fd87-2a93-49e3-a40d-b75180d3f46d', 'Almond Milk', 'Dairy & Cheese', null, 220, 1, 'KG', 'Gram', 0.22, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('3dc3bc80-0c28-4cd9-9105-73b688e1b73e', 'Amul Butter', 'Dairy & Cheese', null, 522.02, 1, 'KG', 'Gram', 0.52202, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('632a3a75-5d45-4b4e-8c19-64597812e8d4', 'Amul Whipping Cream', 'Dairy & Cheese', null, 440, 1, 'KG', 'Gram', 0.44, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('bf757a8c-df29-42ed-b239-5336740b836b', 'Arborio Rice', 'Dry Goods', null, 367.5, 1, 'KG', 'Gram', 0.3675, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('85f1218d-cabf-4981-ae0f-e07e8b9a1158', 'Aromat', 'Spices & Seasoning', null, 325, 1, 'KG', 'Gram', 0.325, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('76c56d16-3cbd-4dd5-82bc-d604b025ac81', 'Ascorbic Acid', 'Bakery', null, 1124.95, 1, 'KG', 'Gram', 1.12495, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('51392038-70b1-43b5-93ef-58c0681b485e', 'Baking Powder', 'Bakery', null, 140, 1, 'KG', 'Gram', 0.14, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('30281242-e858-49c6-b2fb-15c6eaf9cd84', 'Baking Soda', 'Bakery', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('9a7badfd-6c7c-42b7-9c13-4660b1273320', 'Balanced Slice Almond', 'Nuts & Dry Fruits', null, 1071, 1, 'KG', 'Gram', 1.071, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('47eda073-289b-4953-bb35-fb166c7daf55', 'Barilla Penne', 'Dry Goods', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('ed8bb46c-b222-451e-bc6d-3dd8f825887e', 'Black Truffle Pate', 'Others', null, 16624.33, 1, 'KG', 'Gram', 16.62433, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('220bfcec-cd01-4f2d-ae32-506c288ded3e', 'Brit Nutri Choice Digestive', 'Others', null, 180, 1, 'KG', 'Gram', 0.18, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a90cf173-1697-498b-b373-5abdc72acd03', 'Bucatini Pasta', 'Dry Goods', null, 307.08, 1, 'KG', 'Gram', 0.30708, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e2df28cd-33af-4ebf-8ae0-fc9be1b978c1', 'Buffalo Mozzarella Cheese', 'Dairy & Cheese', null, 845.05, 1, 'KG', 'Gram', 0.84505, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b743300f-af2c-4ce4-a2ad-5ee4b39f56f3', 'Callebaut Dark 811', 'Dairy & Cheese', null, 162.96, 1, 'KG', 'Gram', 0.16296, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('56f4e89e-22eb-406f-98ec-a30f3c015210', 'Callebuat Gold', 'Dairy & Cheese', null, 2179.59, 1, 'KG', 'Gram', 2.17959, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2f2db5c1-1d29-4ec7-a8b1-5d039a1d5a97', 'Candia Whipping Cream', 'Dairy & Cheese', null, 730, 1, 'KG', 'Gram', 0.73, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('730cb547-8760-4dd0-a541-06a7db4926b0', 'Carob Gum Powder', 'Bakery', null, 4220, 1, 'KG', 'Gram', 4.22, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f72422f9-25d9-4cc3-a8a0-85f2082afa82', 'Cayenne Pepper', 'Spices & Seasoning', null, 976.5, 1, 'KG', 'Gram', 0.9765, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('07530b43-b487-4957-9bb2-9cf29a0cca5e', 'Cha Thai Red Tea Powder', 'Beverages', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2c66e818-1b90-4e77-8996-c6d871bcbccb', 'Chat Masala', 'Spices & Seasoning', null, 473.82, 1, 'KG', 'Gram', 0.47382, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('4d3995c5-074c-4c99-b794-f3ca049f6e47', 'Chilli Bean Sauce', 'Sauces & Seasoning & Oils', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2484f3ba-9e4e-4201-be22-ebe3f867de62', 'Cinnamon Stick', 'Spices & Seasoning', null, 433.64, 1, 'KG', 'Gram', 0.43364, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('3030b37e-0509-4986-b545-3c6d9c18cc87', 'Citric Acid Crystal', 'Bakery', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('15cafa09-04ee-4a17-b773-fd3e3b591743', 'Cocoa Butter', 'Dairy & Cheese', null, 2325.54, 1, 'KG', 'Gram', 2.32554, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('034c1998-f3d9-4561-a6b4-f57595b6c2ac', 'Cocoa Powder', 'Dairy & Cheese', null, 1503.51, 1, 'KG', 'Gram', 1.50351, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b740bcbe-91bb-44fc-bab4-b73a28514094', 'Coconut Flakes', 'Nuts & Dry Fruits', null, 347, 1, 'KG', 'Gram', 0.347, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('d598c7ff-a463-40be-a8d1-15a64c2d64a3', 'Corn Flour', 'Dry Goods', null, 68, 1, 'KG', 'Gram', 0.068, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('30820cc3-1d9b-4552-b995-0291a73a5e68', 'Corn Malt Syrup', 'Bakery', null, 283.33, 1, 'KG', 'Gram', 0.28333, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('1226e32c-1a9b-4566-83b0-2fc3078dff6e', 'Custard Powder', 'Bakery', null, 100.02, 1, 'KG', 'Gram', 0.10002, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('abd83551-c4bf-43e1-93b8-1a5afea11360', 'Damati Coconut Milk', 'Dairy & Cheese', null, 220.87, 1, 'KG', 'Gram', 0.22087, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7228daf9-8598-49f4-bb8f-d6dee20e05b2', 'Dark Compound', 'Dairy & Cheese', null, 312.72, 1, 'KG', 'Gram', 0.31272, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('41b01942-949e-4d48-9785-9848dd21c2a3', 'Dark Miso Paste', 'Sauces & Seasoning & Oils', null, 590, 1, 'KG', 'Gram', 0.59, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('da812a87-8195-45c0-a87e-00daa6c26882', 'Dark Muscovado Sugar', 'Dry Goods', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7fc5749c-a5f0-489c-9b3e-5d5dc8f7d46a', 'Dark Soya Sauce', 'Sauces & Seasoning & Oils', null, 316.58, 1, 'KG', 'Gram', 0.31658, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('9e0a1049-2eb6-4f86-a3bf-748c714b7da9', 'Df Cream Cheese', 'Dairy & Cheese', null, 672.93, 1, 'KG', 'Gram', 0.67293, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7e5301a3-c12d-4c64-a032-0cbac65a3cc5', 'Dhampur Blackstrap Molasses', 'Sauces & Seasoning & Oils', null, 636.14, 1, 'KG', 'Gram', 0.63614, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c4867c4c-5ebe-459e-930d-e3f281e45abf', 'Dijon Mustard Sauce', 'Sauces & Seasoning & Oils', null, 355.65, 1, 'KG', 'Gram', 0.35565, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('beb0cc23-049d-4c84-90f5-3a9cfa03a62c', 'Dira Frozen Raspberry', 'Dairy & Cheese', null, 2207.23, 1, 'KG', 'Gram', 2.20723, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f87d1793-5640-4cfc-aa4c-2fcded35bd71', 'Dolce Vita Peeled Tomatoes', 'Canned', null, 189, 1, 'KG', 'Gram', 0.189, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2c9941cf-a3a7-4715-906f-5631d030183b', 'Dried Kombu Dashi', 'Others', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('37130850-b045-4ae9-9596-92cba571d4cb', 'Dry Ice', 'Others', null, 60, 1, 'KG', 'Gram', 0.06, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('748d1aba-cb8a-400c-a19d-a8ab39e6e030', 'Edamame Kernal', 'Others', null, 398.7, 1, 'KG', 'Gram', 0.3987, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('1ff6b8da-a4a6-4648-baaf-b44fe3f1268a', 'Edamame Pods', 'Others', null, 450, 1, 'KG', 'Gram', 0.45, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('eedd1d42-854b-4771-933e-4124b2735306', 'Extra Firm Silken Tofu', 'Dairy & Cheese', null, 675, 1, 'KG', 'Gram', 0.675, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('3663a2e1-e862-47bc-bfec-ecdc14bd8dd3', 'Extra Virgin Olive Oil', 'Canned', null, 830, 1, 'KG', 'Gram', 0.83, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('92cd2b98-1d5a-4641-b597-40325653aa2d', 'Fettuccine Pasta', 'Dry Goods', null, 98, 1, 'KG', 'Gram', 0.098, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('15002daf-6c7d-4911-b5e1-da1f77155faa', 'French Fries', 'Others', null, 172.97, 1, 'KG', 'Gram', 0.17297, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a02cf720-9514-46ff-a51c-35d08ac6322f', 'Frozen Blueberry', 'Dairy & Cheese', null, 309.75, 1, 'KG', 'Gram', 0.30975, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('3bf13b54-e82f-4462-bd4d-57bf967e1b2e', 'Frozen Jamun Pulp', 'Dairy & Cheese', null, 232.25, 1, 'KG', 'Gram', 0.23225, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c11b3f92-c58a-4766-bc18-1a5363567471', 'Frozen Mulberry', 'Dairy & Cheese', null, 619.5, 1, 'KG', 'Gram', 0.6195, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('86200569-6e38-4e7b-84bb-efe62284e28d', 'Frozen Raspberry', 'Dairy & Cheese', null, 929.25, 1, 'KG', 'Gram', 0.92925, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('d4ed7d97-1834-406e-b111-6fdcddaf8186', 'Gd Ajinomoto', 'Others', null, 171.58, 1, 'KG', 'Gram', 0.17158, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('9cd12c8a-71f0-4903-ab49-ab1d2942804a', 'Ghost Pepper', 'Spices & Seasoning', null, 3634.36, 1, 'KG', 'Gram', 3.63436, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f117dcdb-5c63-400a-aee6-d1aa54d6919c', 'Glutonious Rice Flour', 'Dry Goods', null, 290, 1, 'KG', 'Gram', 0.29, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('4eb13ccb-6c55-4417-bd7d-80af0ecf41e6', 'Gold Milk', 'Dairy & Cheese', null, 78.67, 1, 'KG', 'Gram', 0.07867, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('4bb51477-5ee8-406f-95e8-f4f1381c2371', 'Green Pisti', 'Nuts & Dry Fruits', null, 3392.28, 1, 'KG', 'Gram', 3.39228, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c117a8fa-0257-4467-9951-68ca5468f1b5', 'Guar Gum Powder', 'Bakery', null, 790, 1, 'KG', 'Gram', 0.79, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c4bc3e2e-171a-4fe4-8761-37aae358c9ae', 'Hazelnut Kernel', 'Nuts & Dry Fruits', null, 2598.17, 1, 'KG', 'Gram', 2.59817, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2816f42d-bd6c-4089-89e5-40d928ce408c', 'Hoisin', 'Sauces & Seasoning & Oils', null, 640.5, 1, 'KG', 'Gram', 0.6405, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('852960bf-9155-4927-8b40-7da4e7f9db39', 'How How Rice Noodles', 'Dry Goods', null, 234.9, 1, 'KG', 'Gram', 0.2349, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('07c44462-b893-4a7a-a865-809c914c97a6', 'Ice Cubes', 'Others', null, 77.4, 1, 'KG', 'Gram', 0.0774, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('80c514ae-7a44-41f1-9ca0-85eed2c0451d', 'Icing Sugar', 'Dry Goods', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('d599b26e-c258-42be-9fd1-bf0a490b3d74', 'Jalapenos Slices', 'Canned', null, 76.9, 1, 'KG', 'Gram', 0.0769, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('bc4a2c76-474d-4f94-a5ea-148b358acf86', 'Japanese Pickled Ginger', 'Canned', null, 348.6, 1, 'KG', 'Gram', 0.3486, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('55a2a00c-4e94-4d63-850c-620a3b7504b1', 'Jivraj Tea', 'Beverages', null, 225.75, 1, 'KG', 'Gram', 0.22575, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('565a1d4b-852d-4d41-8bb7-561388dbfd3f', 'Kashmiri Red Chilli Powder', 'Spices & Seasoning', null, 984, 1, 'KG', 'Gram', 0.984, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('52f830fe-68a5-416d-93b7-064dceeddb28', 'Kashmiri Red Chilly Dry Whole Loose', 'Spices & Seasoning', null, 414.75, 1, 'KG', 'Gram', 0.41475, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('9e6295d5-9cf7-40e6-b4f6-cd163e587344', 'Korean Gochugaru Pepper Flakes', 'Spices & Seasoning', null, 882, 1, 'KG', 'Gram', 0.882, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e33c4b89-4322-4739-8dd0-cb79268600f4', 'Korean Red Chilly Paste', 'Sauces & Seasoning & Oils', null, 346.5, 1, 'KG', 'Gram', 0.3465, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7730a681-7018-479a-9554-ee4de205a369', 'Lemoneez', 'Sauces & Seasoning & Oils', null, 312, 1, 'KG', 'Gram', 0.312, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('ab37a878-8df4-47e1-9899-739aeebf6f49', 'Loose Paneer', 'Dairy & Cheese', null, 450, 1, 'KG', 'Gram', 0.45, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('45540354-256f-46f9-ae1f-1e6c899ef19d', 'Lotus Biscoff Spread', 'Dairy & Cheese', null, 1170.75, 1, 'KG', 'Gram', 1.17075, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('441233d4-05b2-49db-bd03-3d823881b6e3', 'Madhur Sugar', 'Dry Goods', null, 51.94, 1, 'KG', 'Gram', 0.05194, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('987e2ed6-8dd7-4a2a-9502-d8650b354445', 'Malted Barley Flour (diastatic)', 'Bakery', null, 115, 1, 'KG', 'Gram', 0.115, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('ae473dbe-ef79-4125-9090-b7790c2b264d', 'Maple Syrup', 'Sauces & Seasoning & Oils', null, 1909.09, 1, 'KG', 'Gram', 1.90909, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('63571b7b-2b4f-4d33-839d-e0e5ddcf8dc7', 'Mattari Single Estate Coffee', 'Beverages', null, 1890, 1, 'KG', 'Gram', 1.89, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e9e4cda6-89ca-44c0-8baa-e407c4c03ec2', 'Milk Compound', 'Dairy & Cheese', null, 320, 1, 'KG', 'Gram', 0.32, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('21c7bee1-dbd0-4ec5-ae11-adf32903cd8d', 'Milk Maid', 'Dairy & Cheese', null, 325.5, 1, 'KG', 'Gram', 0.3255, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('13ec3d86-9fd6-4be8-afbe-0ed783769db3', 'Milk Powder', 'Dairy & Cheese', null, 595, 1, 'KG', 'Gram', 0.595, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('571e6936-ebda-43dd-b865-fe26ed7c894d', 'Mirin', 'Sauces & Seasoning & Oils', null, 363.89, 1, 'KG', 'Gram', 0.36389, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e4aa67b4-18b4-42ec-93f5-369ba1344317', 'Mithai Maid Small', 'Dairy & Cheese', null, 282.5, 1, 'KG', 'Gram', 0.2825, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('43358029-5c9a-4c19-a6bd-a2f722560be4', 'Mothers Tamarind Paste', 'Sauces & Seasoning & Oils', null, 240, 1, 'KG', 'Gram', 0.24, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('24326084-9c0f-4aba-83ad-7cecd2d1a37f', 'Muscovado Sugar', 'Dry Goods', null, 149.72, 1, 'KG', 'Gram', 0.14972, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('81cca78d-dc79-447c-bad3-eb26b354251e', 'Neo Kimchi', 'Others', null, 746.67, 1, 'KG', 'Gram', 0.74667, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('be154ba4-68bc-4d4d-b3bb-b31f3fd4c8a6', 'Nescafe Gold Blend', 'Beverages', null, 4773, 1, 'KG', 'Gram', 4.773, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('1825abb8-285e-4d00-9926-05c0230d18be', 'Nutella', 'Dairy & Cheese', null, 770, 1, 'KG', 'Gram', 0.77, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('5f4ec6b0-7e3f-4de4-9131-61623000f415', 'Nutritional Yeast Flakes', 'Bakery', null, 3370, 1, 'KG', 'Gram', 3.37, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('478ccc43-b096-4e9e-8fd8-0ce8854eb56b', 'Oat Milk', 'Dairy & Cheese', null, 224.37, 1, 'KG', 'Gram', 0.22437, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('24dc2625-6892-4f28-8a9a-2e9d1f577f67', 'Oreo Biscuit', 'Others', null, 222.22, 1, 'KG', 'Gram', 0.22222, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('fc9fd7b8-5544-4392-b1d6-9ce242ef3cc5', 'Orzo Pasta', 'Dry Goods', null, 484, 1, 'KG', 'Gram', 0.484, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('73c3a86e-403e-4293-891c-d8c9ff2bb907', 'Palm Sugar', 'Dry Goods', null, 441, 1, 'KG', 'Gram', 0.441, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f2b4612c-7ee1-48c6-bb50-71f1b7916879', 'Parmesan Block', 'Others', null, 1350.37, 1, 'KG', 'Gram', 1.35037, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e58e74fc-2a70-48fd-8b7f-797a40542545', 'Passion Fruits Puree', 'Puree', null, 1357, 1, 'KG', 'Gram', 1.357, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7aae1c58-8823-4ca7-b138-83dbf0bd9382', 'Peanut Butter Cream', 'Dairy & Cheese', null, 232, 1, 'KG', 'Gram', 0.232, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('6d0d215d-8925-49e5-a6e9-f4ecf79610e5', 'Peanuts Loose', 'Nuts & Dry Fruits', null, 192.43, 1, 'KG', 'Gram', 0.19243, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('38bd07dc-f770-416e-89b7-4f52e8055d42', 'Pectin Powder', 'Bakery', null, 2220, 1, 'KG', 'Gram', 2.22, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('aa7f5b46-dd20-4378-81b6-b0325abc933e', 'Penne Pasta', 'Dry Goods', null, 231, 1, 'KG', 'Gram', 0.231, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('763898f2-70ee-4581-90f4-3ee55cb2e46e', 'Podi Chutney', 'Sauces & Seasoning & Oils', null, 597.6, 1, 'KG', 'Gram', 0.5976, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('0cc448f6-1518-458a-a5b6-75335391ee90', 'Pomegranate Molasses', 'Sauces & Seasoning & Oils', null, 1029, 1, 'KG', 'Gram', 1.029, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b8e2697b-b753-4b78-95eb-168306141eea', 'Potato Starch', 'Dry Goods', null, 247.8, 1, 'KG', 'Gram', 0.2478, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('0eeac883-8262-4804-b2c8-86935829afa2', 'Potato Starch Bag', 'Dry Goods', null, 235.2, 1, 'KG', 'Gram', 0.2352, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('bd5d1216-0760-4125-b822-3d4a880fd3f7', 'Project Sarada Dew', 'Beverages', null, 13600, 1, 'KG', 'Gram', 13.6, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('993d25fd-2378-44ce-9ff5-df3553fd8125', 'Project Sarada Wander', 'Beverages', null, 2720, 1, 'KG', 'Gram', 2.72, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('66b69c9d-c1ea-499b-86c7-3ea669b102cb', 'Pumpkin Seeds', 'Nuts & Dry Fruits', null, 540, 1, 'KG', 'Gram', 0.54, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('249bd739-0d7e-4dee-91fb-67dccd3941ae', 'Purix Glucose Syrup', 'Bakery', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('53f288e6-9485-4c93-99fc-7d3f1ee296fe', 'Rigatoni Pasta', 'Dry Goods', null, 372, 1, 'KG', 'Gram', 0.372, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e44f99ef-96a7-4105-9fb0-0f651a6b70dd', 'Safa Tomato Paste', 'Sauces & Seasoning & Oils', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('11d370f5-f819-41ed-b9ae-1231f1d3bedd', 'Sake', 'Sauces & Seasoning & Oils', null, 391.11, 1, 'KG', 'Gram', 0.39111, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('d42f1047-8f6d-4f7d-a6e5-dc9026936f55', 'Salted Cashew Nuts', 'Nuts & Dry Fruits', null, 1378.13, 1, 'KG', 'Gram', 1.37813, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('02977693-dafb-4278-9e3e-2711454b0d62', 'Seedless Dates', 'Nuts & Dry Fruits', null, 168, 1, 'KG', 'Gram', 0.168, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a0f67fb5-ef1b-427b-828d-09426680bf5b', 'Semolina Pasta Flour', 'Dry Goods', null, 276, 1, 'KG', 'Gram', 0.276, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('83f8f5bf-4c66-4803-82bc-8974e38feb76', 'Shao Xing Cooking Wine Vinegar', 'Sauces & Seasoning & Oils', null, 208.6, 1, 'KG', 'Gram', 0.2086, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('5cacf9e4-ee7d-46f5-b7e9-9b13adffe669', 'Shiro Miso Paste', 'Sauces & Seasoning & Oils', null, 488, 1, 'KG', 'Gram', 0.488, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('5a18f344-50da-48e8-aee7-8a385f4d66c0', 'Shitake Mushroom', 'Others', null, 1155, 1, 'KG', 'Gram', 1.155, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('3a203158-7127-446f-9abb-2084bf48f65e', 'Smoked Mozzarella Cheese', 'Dairy & Cheese', null, 623.3, 1, 'KG', 'Gram', 0.6233, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b8016128-d105-4e1b-b57a-7cd94bb31cad', 'Smoked Paprika', 'Spices & Seasoning', null, 1400, 1, 'KG', 'Gram', 1.4, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('440f3faa-ec43-4b92-a4ae-4f40910327f6', 'Soba Noodles', 'Dry Goods', null, 482.34, 1, 'KG', 'Gram', 0.48234, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('294c6ae3-1998-4fd1-961f-492f2e0da299', 'Soya Plain Paneer', 'Dairy & Cheese', null, 210, 1, 'KG', 'Gram', 0.21, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('70ed0b32-cf16-485c-ab8f-2bc133655b88', 'Sprig Green', 'Spices & Seasoning', null, 10600.67, 1, 'KG', 'Gram', 10.60067, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('ca181234-8963-48e4-a137-fdd184f24ee8', 'Spring Roll Sheet', 'Bakery', null, 794.18, 1, 'KG', 'Gram', 0.79418, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('bfbed9fe-6d74-4931-b286-644c0bdc4daf', 'Sriracha Hot Chilli Sauce', 'Sauces & Seasoning & Oils', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('90af955d-ace0-41dd-9477-7ff4fb702915', 'Sunflower Refined Oil', 'Sauces & Seasoning & Oils', null, 187.14, 1, 'KG', 'Gram', 0.18714, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a7610224-0431-4cbc-b581-d5bcdc74d6e8', 'Sunflower Seed', 'Sauces & Seasoning & Oils', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('89a1f7d4-d79d-4bf6-bf46-ce5ff7c980d4', 'Synthetic Vinegar', 'Sauces & Seasoning & Oils', null, 31.49, 1, 'KG', 'Gram', 0.03149, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('dcba7437-356d-4946-bc18-605c8ce9a09d', 'Tahina Paste', 'Sauces & Seasoning & Oils', null, 651, 1, 'KG', 'Gram', 0.651, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f5585a38-ff78-414b-b5cd-b74c86c69594', 'Tajin Seasoning', 'Spices & Seasoning', null, 4184.23, 1, 'KG', 'Gram', 4.18423, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('9dc2953f-54d6-43ff-a3b6-51de6f4dc5c8', 'Tanifuji Rice', 'Dry Goods', null, 200.66, 1, 'KG', 'Gram', 0.20066, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('14d6defa-202a-4ec7-8a6d-61f437a28e95', 'Tapioca Boba Pearls', 'Dry Goods', null, 336, 1, 'KG', 'Gram', 0.336, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('7a27a998-70b9-4eb5-92b6-754970015f59', 'Tata Tea Gold', 'Beverages', null, 920, 1, 'KG', 'Gram', 0.92, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2ec4094f-58e7-4643-bad7-94e7b9e492ce', 'Tempura', 'Dry Goods', null, 134.78, 1, 'KG', 'Gram', 0.13478, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a392d33b-ea44-4f59-8ec5-ac006c2c3ba1', 'Thaiji Gold Jasmine Rice', 'Dry Goods', null, 210, 1, 'KG', 'Gram', 0.21, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('2dd0e5d3-6996-4b76-a65b-ca95bc715b9c', 'Tobassco Pepper', 'Sauces & Seasoning & Oils', null, 3000, 1, 'KG', 'Gram', 3, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a37d30c0-3fae-42e7-a479-eb015c56f348', 'Togarashi Chilli Pepper', 'Spices & Seasoning', null, 1260, 1, 'KG', 'Gram', 1.26, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c56b5842-1365-45e7-b3bb-607b01eef576', 'Tomato Ketchup', 'Sauces & Seasoning & Oils', null, 76, 1, 'KG', 'Gram', 0.076, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e55f57a3-26cd-4bd7-9b62-9c19a5e11dcf', 'Tteokbokki Rice Cake', 'Dry Goods', null, 560, 1, 'KG', 'Gram', 0.56, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f919ddbe-9c5c-47b4-9f25-eb22f1a971dd', 'Unsalted Butter', 'Dairy & Cheese', null, 640, 1, 'KG', 'Gram', 0.64, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('c3df909e-16a4-4c4d-8d30-950de231ff25', 'Vanilla Bean Paste', 'Dairy & Cheese', null, 25201.8, 1, 'KG', 'Gram', 25.2018, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('8e6fd8b3-fe56-480a-885c-a2a4a4709de0', 'Vanilla Essence', 'Dairy & Cheese', null, 660, 1, 'KG', 'Gram', 0.66, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('97ba1f1f-04c8-42c2-8338-4d65cdbbbb5c', 'Veg Oyester Sauce', 'Sauces & Seasoning & Oils', null, 253.05, 1, 'KG', 'Gram', 0.25305, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('f4636e0a-66ce-41d9-b58a-436ff3eb83af', 'Vital Wheat Gluten', 'Dry Goods', null, 540, 1, 'KG', 'Gram', 0.54, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('d0f9480b-431c-49d9-820b-15da8b2fde01', 'Wasabi Powder', 'Bakery', null, 787.5, 1, 'KG', 'Gram', 0.7875, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('a20f8794-f52f-4a93-86f6-6d8c3ae647dc', 'Water Chestnuts', 'Canned', null, 255.73, 1, 'KG', 'Gram', 0.25573, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('e53110ac-6f46-4a78-8952-bc63821a0482', 'Wheat Starch', 'Dry Goods', null, 189, 1, 'KG', 'Gram', 0.189, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('edb9aff1-5b29-4be1-9c6d-e90632dae347', 'Wheat Starch Bag', 'Dry Goods', null, 183.75, 1, 'KG', 'Gram', 0.18375, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('4bf5efe0-b99e-4bf4-b4b6-02c635088400', 'White Compound', 'Dairy & Cheese', null, 362.96, 1, 'KG', 'Gram', 0.36296, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('813fcd84-11dd-4be0-8168-e2ced13d7e0f', 'Xanthan Gum Powder', 'Bakery', null, 1110, 1, 'KG', 'Gram', 1.11, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z'),
('b0d543f2-5b6a-4959-88f2-fee928e7faac', 'Yuzukosho Green', 'Spices & Seasoning', null, 14200, 1, 'KG', 'Gram', 14.2, '2026-06-01', 'active', 'Pankil master price list', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- recipes (124)
insert into public.recipes (id, recipe_name, category, brand, description, image_url, preparation_time, serving_size, status, total_cost, cost_per_portion, selling_price, packaging_cost, wastage_pct, is_prep, yield_quantity, yield_unit, version_no, method, size_code, size_label, approved_at, rejection_note, created_at, updated_at) values
('6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'Chilli Crisp', 'In-House Prep', 'capiche', 'House chilli crisp.', null, 60, 1, 'approved', 1146.38, 1146.38, null, 0, 5, true, 8270, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('95f00d97-a273-478f-b486-05111d81381f', 'Bechamel Sauce', 'In-House Prep', 'capiche', 'House bechamel.', null, 30, 1, 'approved', 144.28, 144.28, null, 0, 5, true, 1210, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a11b1997-dee4-4804-adb7-e9e68bd83846', 'Pizza Dough', 'In-House Prep', 'capiche', 'Cold-proofed pizza dough.', null, 1440, 1, 'approved', 1528.8, 1528.8, null, 0, 5, true, 17288, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e3be30e0-d6d0-4a93-a362-3a321d358779', 'Pesto White Base Sauce', 'In-House Prep', 'capiche', 'White base for pesto pasta.', null, 20, 1, 'approved', 27.79, 27.79, null, 0, 5, true, 160, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6b100575-63d4-4fe8-bb76-a5dfebefcd82', 'Hydroponic Basil Pesto', 'In-House Prep', 'capiche', 'Fresh basil pesto.', null, 15, 1, 'approved', 229.44, 229.44, null, 0, 5, true, 475, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f9bda125-40c4-4791-9c9b-1b11eb805304', 'Chili Crunch Sauce', 'In-House Prep', 'capiche', 'Uses house chilli crisp.', null, 30, 1, 'approved', 78.36, 78.36, null, 0, 5, true, 418, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9f1e44fd-453d-42fe-b757-f2688893eaeb', 'Sesame Sushi Rice', 'In-House Prep', 'aiko', 'Seasoned sushi rice.', null, 40, 1, 'approved', 269.59, 269.59, null, 0, 5, true, 1025, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ae22ad7a-679c-48a8-90c7-7cbf00785901', 'Ponzu Wasabi Mayo', 'In-House Prep', 'aiko', 'Ponzu wasabi mayo.', null, 10, 1, 'approved', 18.19, 18.19, null, 0, 5, true, 102, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9025ff8a-1639-453a-a8a7-6b8d6d7670a8', 'Tamarind Water', 'In-House Prep', 'aiko', 'Tamarind extraction.', null, 15, 1, 'approved', 19.95, 19.95, null, 0, 5, true, 300, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('21bc4c35-ccec-417a-ba43-03d76889c33a', 'Marinated Beetroot Chunks', 'In-House Prep', 'aiko', 'Marinated beetroot.', null, 20, 1, 'approved', 6.05, 6.05, null, 0, 5, true, 68, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('19807fac-42fb-47f5-aad3-65feedbdf4e2', 'Sri Lankan Red Curry Powder Mix', 'In-House Prep', 'aiko', 'Roasted & ground spice mix.', null, 30, 1, 'approved', 227.85, 227.85, null, 0, 5, true, 87, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('29899406-0eb9-41e4-aecd-b288adf7d325', 'Sri Lankan Red Paste', 'In-House Prep', 'aiko', 'Uses house curry powder.', null, 45, 1, 'approved', 49.05, 49.05, null, 0, 5, true, 243, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('30722f5b-4b0c-432f-b41e-4361c7b907cd', 'Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 164.65, 164.65, 620, 0, 5, false, 250, 'Gram', 1, ARRAY['Toss leaves with vinaigrette & salt.','Add cherry tomato, grapefruit, olives.','Place burrata in centre.','Arrange salad mix around.','Sprinkle pine nuts; drizzle olive oil & hot honey.','Garnish with edible flowers.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('607b258a-0009-4101-b8fc-a1ba6e1ae321', 'Caesar Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 41.12, 41.12, 480, 0, 5, false, 200, 'Gram', 1, ARRAY['Tear leaves.','Slice onion rings.','Toss lettuce with mayo, salt, pepper.','Add parmesan and croutons.','Check seasoning.','Plate; garnish with onion rings.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('239c18b2-888e-4d74-875d-d4b744540111', 'Persimmon Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 171.63, 171.63, null, 0, 5, false, 265, 'Gram', 1, ARRAY['Toss arugula with vinaigrette; do not overdress.','Arrange on chilled serving plate.','Place persimmon and strawberry evenly over greens.','Add burrata as soft dollops; season lightly.','Spoon caviar on burrata; sprinkle pine nuts and edible flowers.','Drizzle hot honey; serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'Summer Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 141.38, 141.38, 680, 0, 5, false, 344.5, 'Gram', 1, ARRAY['Process iceberg lettuce, romaine lettuce, and Lollo Rosso. Give them an ice bath to keep them crisp.','In a large bowl, combine all processed leaves. Add salt, black pepper, and vinaigrette. Add arugula and toss well.','Cut mango and grapefruit into cubes.','Plate the mixed leaves. Place a burrata on top.','Drizzle olive oil over the burrata and add crushed black pepper.','Arrange cubed mango, grapefruit, and cherry tomatoes around the burrata. Add edible flowers.','Scatter roasted hazelnuts and chopped granola.','Finish with a drizzle of hot honey.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'Roasted Red Bell Pepper Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 140.95, 140.95, null, 0, 5, false, 370, 'Gram', 1, ARRAY['Roast veg until soft/charred; cool. Peel peppers if desired.','Blend smooth; strain if desired. Chili; portion 120 g per serve.','Melt a little CDP butter; add 120 g paste, sauté 1 min. Add 160 g water; season; add sour cream; simmer low 3–4 min.','Spread 5 g garlic butter on 70 g sourdough; toast until crisp.','Bowl soup; swirl pesto; sprinkle sesame. Serve hot with bread.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f4c0c26a-6248-492d-9951-df3cb7cb372c', 'Arancini', 'Appetiser', 'capiche', null, null, null, 6, 'approved', 48.04, 48.04, 480, 0, 5, false, 117, 'Gram', 1, ARRAY['Prepare rice mix; cool completely.','Weigh 16 g rice mix, add 3 g mozzarella, shape into ball (~19 g). Repeat for 6.','Dip into batter.','Coat with panko crumbs.','Deep fry at 180 °C for ~4–5 min; core ≈ 74 °C.','Drain; plate with hot mayo & green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a002bb6d-fb97-4db7-b40f-e4b0c894562e', 'Dough Balls', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 97.65, 97.65, 540, 0, 5, false, 150, 'Gram', 1, ARRAY['Divide dough into 6–8 × ~20 g balls.','Roll and place on screen.','Bake at 350 °C ~2 min until puffed.','Toss in melted butter, garlic, parsley.','Garnish with green garlic.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('85112faa-baf6-416d-9c52-8ee44a034fd8', 'Garlic Bread', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 51.42, 51.42, 540, 0, 5, false, 105, 'Gram', 1, ARRAY['Bake base; cool slightly.','Deep cut into 8 wedges.','Stuff cream cheese between cuts.','Brush with butter + chopped garlic.','Microwave 30 s.','Bake at 350 °C for 2 min until golden; garnish green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7610ed59-a475-4ae3-a190-763d78d5ffc4', 'Pasta Fritti 2.0', 'Pasta', 'capiche', null, null, null, 1, 'approved', 151.69, 151.69, null, 0, 5, false, 547, 'Gram', 1, ARRAY['Mix all filling ingredients well.','Cut pasta sheets into 1 x 4 pieces.','Spread ricotta filling, place mozzarella stick and a line of tomato paste. Roll tightly.','Freeze for 15 min.','Dip in batter; coat with bread crumbs.','Deep fry at 160-180 °C for 4-5 min; finish in oven 10-15 sec.','Grate parmesan; top with green garlic.','Serve with garlic ranch & hot tomato sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d4df059a-01fa-49e5-90be-e1cfd95286a7', 'Butter Garlic Mushroom', 'Pasta', 'capiche', null, null, null, 1, 'approved', 115.34, 115.34, 540, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; cook mushrooms.','Add garlic; sauté.','Add basil, parsley; season.','Toss with vinaigrette & chilli flakes.','Add butters.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c05f4bac-c199-4bb8-b809-4a771a02e418', 'Saucy Brussels Sprouts', 'Vegetable', 'capiche', null, null, null, 1, 'approved', 165.74, 165.74, 580, 0, 5, false, 676, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add Brussels sprouts (cut in halves) and char on high heat.','Add butter, garlic, chilli flakes, salt, pepper, and balsamic vinegar. Toss well.','In another pan, combine cream cheese, béchamel, sour cream, mayonnaise, salt, and black pepper. Cook on low heat until smooth.','Spread the cream cheese sauce on a plate and place the charred Brussels sprouts on top.','Garnish with fresh Bhavnagri chilli, pickled onions, and feta crumbles.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'Miso Tomato Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 47.14, 47.14, 440, 0, 5, false, 1093, 'Gram', 1, ARRAY['Heat olive oil in a pot, add onion, garlic, carrot, chili, thyme, bay leaf, parsley stems. Sauté until soft and lightly golden.','Add tomatoes, cook down until jammy.','Add water and stock powder, simmer 20 min.','Remove bay leaf and thyme stems. Blend until smooth.','Take off heat, whisk in miso paste.','Adjust seasoning with soy, salt, and pepper.','Stir in chopped fresh basil just before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2248837c-b38f-4d33-a83c-523fdf156a09', 'Pomodoro Spaghetti', 'Pasta', 'capiche', null, null, null, 1, 'approved', 102.17, 102.17, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; sauté cherry tomatoes.','Add pomodoro; season.','Add spaghetti; toss.','Simmer; add butter.','Finish with basil; parmesan garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7e96c3ae-24a2-4e95-839c-78779563d3d7', 'Spicy Tomato & Cream Macaroni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.94, 71.94, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add hot sauce; season.','Add orange sauce; stir.','Add cream; adjust seasoning.','Toss macaroni; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bba8259b-ab03-4e03-a5bc-def778debc21', 'Alfredo Fettuccine', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.69, 71.69, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil & butter; add garlic, herbs.','Add béchamel; season; adjust with water.','Toss fettuccine; finish with parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('45d4738a-4d57-4949-b3a9-67d436403828', 'Lemon Linguini', 'Pasta', 'capiche', null, null, null, 1, 'approved', 115.65, 115.65, null, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add white sauce, mascarpone.','Add lemon; season.','Toss linguini; adjust with water.','Finish with basil; parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'Risotto', 'Pasta', 'capiche', null, null, null, 1, 'approved', 134.96, 134.96, 780, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter+oil; sauté garlic, asparagus, peas.','Add rice; season.','Add water; add béchamel.','Finish with parmesan; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('24028ee9-c979-4ca8-9062-a4f6283e00b3', 'Lasagna', 'Pasta', 'capiche', null, null, null, 7, 'approved', 143.63, 143.63, 740, 0, 5, false, 1300, 'Gram', 1, ARRAY['Heat oil in a pan; sauté onion, carrot, celery and garlic until soft.','Add soaked and drained soy chunks; cook for 3–4 min.','Add tomato passata, tomato paste, oregano, salt and pepper. Simmer 15–20 min.','Make béchamel: melt butter, add flour; cook 1 min. Gradually whisk in milk. Cook until thick. Season with salt and nutmeg.','In a baking dish, layer: bolognese sauce, sheets, béchamel, mozzarella. Repeat layers. Top with parmesan.','Bake at 180°C for 40–45 min or until golden and bubbling. Rest 10 min before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', 'Stuffed Conchiglioni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 103.03, 103.03, 780, 0, 5, false, 662, 'Gram', 1, ARRAY['Mix ricotta, cream cheese, blanched kale, chopped jalapeño, salt and xanthan gum into a smooth, well-seasoned filling.','Stuff each boiled conchiglioni generously with the kale-ricotta filling.','Spoon garlic pomodoro sauce as a base in a shallow oven dish.','Arrange stuffed shells on the sauce base.','Sprinkle parmesan and red paprika on top.','Bake at 350°C for 6 min until golden and heated through.','Garnish with slit onion and sunflower seeds.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('441f796d-167b-4ad0-bbf4-fbf0d696382b', 'Caramelised Onion Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 62.24, 62.24, 780, 0, 5, false, 329, 'Gram', 1, ARRAY['Heat olive oil in a pan over medium heat.','Add chopped garlic and sauté until fragrant.','Add caramelised onion and cook for 1–2 min.','Add 1 ladle of water; bring to a gentle simmer.','Add spaghetti and mix well to coat.','Add mix seasoning, fresh cream and soya sauce. Toss until pasta is creamy and well combined.','Adjust consistency with water if needed.','Finish with chilli crisp and parmesan. Toss to combine.','Plate and garnish with fresh parsley. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5a57cbee-d08b-4687-9a3c-62042841edcd', 'Pink Burrata Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 124.8, 124.8, 780, 0, 5, false, 247, 'Gram', 1, ARRAY['Roast beetroot with olive oil wrapped in foil paper. Once roasted, strain and blend into a purée.','Heat a pan. Add pesto white sauce.','Add farfalle pasta. Season with black pepper, chilli flakes, butter, and salt. Mix well.','Add beetroot purée and toss until the sauce turns pink.','Plate and garnish with a smashed burrata dollop, crushed pumpkin seeds and pistachios, olive oil, and crushed black pepper.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('86e939f3-8e2d-4e91-81e1-4067b54bce88', 'Tomato Butter Risotto', 'Risotto', 'capiche', null, null, null, 1, 'approved', 109.5, 109.5, 740, 0, 5, false, 256, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add garlic and onion and sauté until softened.','Add pomodoro sauce, water, salt, and black pepper. Stir well.','Add risotto rice and butter. Cook well, stirring frequently. Finish with Parmesan.','Plate and garnish with confit cherry tomatoes, a pesto dollop, arugula, and chopped kalonji.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'Truffle Mac & Cheese', 'Pasta', 'capiche', null, null, null, 1, 'approved', 164.71, 164.71, 840, 0, 5, false, 253, 'Gram', 1, ARRAY['Heat a pan. Add béchamel sauce, cheddar cheese, and mozzarella cheese. Melt together.','Add boiled pasta and mix well. Season with salt and black pepper. Add parmesan and butter.','Transfer into a steel plate. Top with cheddar cheese, mozzarella cheese, and parmesan. Bake in oven.','Remove from oven. Garnish with truffle oil, truffle pâté, and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('efbcb0a6-c42c-4658-af87-686299ab9963', 'Sticky Toffee Pudding', 'Desserts', 'capiche', null, null, null, 1, 'approved', 52.6, 52.6, 600, 0, 5, false, 215, 'Gram', 1, ARRAY['Bake pudding.','Warm pudding before service.','Plate pudding.','Pour caramel sauce.','Add pecan ice cream.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5b233a70-b208-4de1-b1c9-dd25e2815e60', 'Brownie With Ice Cream', 'Desserts', 'capiche', null, null, null, 1, 'approved', 108.15, 108.15, 640, 0, 5, false, 185, 'Gram', 1, ARRAY['Bake and portion brownies.','Warm before serving.','Plate brownie.','Add ice cream scoop.','Drizzle Nutella.','Garnish tuile.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6525fd90-bb34-4f2c-8059-76cae55505aa', 'Pistachio Mousse Cake', 'Desserts', 'capiche', null, null, null, 1, 'approved', 139.58, 139.58, 600, 0, 5, false, 140, 'Gram', 1, ARRAY['Place kunafa base.','Add sponge layer.','Pipe mousse.','Garnish with white chocolate décor.','Add pistachio crumble if available.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f94693e0-b945-4001-b6fb-383c2b6f13c3', 'Tiramisu 3.0', 'Desserts', 'capiche', null, null, null, 1, 'approved', 111.93, 111.93, 640, 0, 5, false, 115, 'Gram', 1, ARRAY['Layer sponge.','Add mascarpone mousse.','Add coffee cream.','Top with sable and tuile.','Chill to set.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6204b4a6-08a7-4508-9c8d-5593e2b63c20', 'Lemon Iced Tea', 'Drinks', 'capiche', null, null, null, 1, 'approved', 14.66, 14.66, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Glass & ice (0:00-0:10): Fill with cubed ice.','Build (0:10-0:35): Add lemon juice and sugar syrup.','Top (0:35-1:00): Add iced tea to reach 300 ml net.','Garnish & QC (1:00-1:20): Stir once; garnish with dried lemon.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e9296c04-3317-49d0-9442-9b5b89e5868a', 'Mint Mojito', 'Drinks', 'capiche', null, null, null, 1, 'approved', 19.13, 19.13, 360, 0, 5, false, 245, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill with cubed ice.','Build (0:10–0:25): Add lemon juice and mint syrup.','Top (0:25–0:50): Add soda; gentle lift with bar spoon.','Garnish & QC (0:50–1:10): Slap mint; place at rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('198725b3-80a5-440c-9e3d-16e8b44c9d8e', 'Pina Colada', 'Drinks', 'capiche', null, null, null, 1, 'approved', 84.9, 84.9, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Load (0:00-0:20): All ingredients incl. ice in blender.','Blend (0:20-0:50): Smooth, ~30 s.','Pour & garnish (0:50-1:20): Into chilled glass; garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7a45ed41-2aa3-4e12-9eff-119adf3dc945', 'Moscow Mule', 'Drinks', 'capiche', null, null, null, 1, 'approved', 91.7, 91.7, 360, 0, 5, false, 320, 'Gram', 1, ARRAY['Fill mule mug with cubed ice.','Add lemon juice and ginger zest into mug.','Add ginger beer to 320 ml; stir gently with bar spoon; lift once.','Garnish with lemon wheel and rosemary sprig.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e6026727-d92b-41f5-942d-de37bdeb80c8', 'Sunset Cocktail', 'Drinks', 'capiche', null, null, null, 1, 'approved', 67.54, 67.54, 300, 0, 5, false, 230, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:30): Add lemon juice, orange juice, and hibiscus syrup.','Top (0:30–0:55): Add Sprite to 230 ml; pour gently over the back of a spoon for a layered effect; gentle lift.','Garnish & QC (0:55–1:15): Garnish with fresh jalapeño slice on rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('198fc4ff-a988-4d4c-b71b-adf7dc7f05b8', 'Tamarind Fizz', 'Drinks', 'capiche', null, null, null, 1, 'approved', 56.97, 56.97, 300, 0, 5, false, 220, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:25): Add tamarind syrup and salt.','Top (0:25–0:50): Top with Schweppes Ginger Ale to 220 ml; stir gently; lift once.','Garnish & QC (0:50–1:15): Garnish with basil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ce827899-ab69-4880-b550-43bcd2f8976b', 'Tom Yum', 'Soups', 'aiko', null, null, null, 1, 'approved', 17.46, 17.46, 360, 13.12, 5, false, 198, 'Gram', 1, ARRAY['Blend chilli, onion, garlic, mushroom to coarse paste.','Cook paste until aromatic.','Add tamarind, water, vinegar, sugar; simmer 8-10 min.','Adjust hot-sour balance as per standard.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'Thai Spring Roll', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 16.5, 16.5, null, 0, 5, false, 196.75, 'Gram', 1, ARRAY['Place approximately 30 g Thai spring filling on each spring roll sheet.','Roll tightly while folding the sides inward. Seal the edge using slurry/water if required.','Heat oil to 170-175°C. Carefully fry spring rolls until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Serve spring rolls as entire pieces. Drizzle with sriracha sauce. Garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('687098bf-eef1-4661-97b2-dde78115de40', 'Kwispy Lotus Root', 'Sides', 'aiko', null, null, null, 1, 'approved', 32.05, 32.05, 460, 0, 5, false, 166, 'Gram', 1, ARRAY['Fry lotus root until crisp; drain well.','Heat wok; add garlic + chilli; sauté briefly.','Add onion + bell pepper; toss 30–40 sec.','Add sauce + pok choy; bring to bubble.','Add lotus root; toss quickly to coat.','Finish spring onion + basil; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5a044da4-abf7-4387-a393-13e36ab7f7df', 'Kwispy Wonton', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 33.04, 33.04, 460, 0, 5, false, 96, 'Gram', 1, ARRAY['Place approx. 15 g of Kwispy Wonton filling in the center of each gyoza skin.','Apply corn slurry on the edges. Fold and seal tightly in desired shape.','Heat oil to 170–175°C. Carefully drop wontons into hot oil.','Fry for 3–4 minutes or until golden brown and crispy.','Remove and drain excess oil on paper towel.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b88ed338-6761-420a-8eb8-0c479396b965', 'Tteokbokki', 'Sides', 'aiko', null, null, null, 1, 'approved', 108.6, 108.6, 540, 0, 5, false, 170.13, 'Gram', 1, ARRAY['Blanch rice cakes until soft; drain well.','Heat pan; add water + sauce; bring to simmer.','Add rice cakes; toss to coat.','Add salt, MSG, sugar; reduce until glossy.','Finish spring onion + fried garlic; garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('51d00100-0628-4012-bbac-f2e34bb1f98c', 'Tofu Bao', 'Dimsum', 'aiko', null, null, null, 1, 'approved', 40.95, 40.95, 540, 0, 5, false, 223, 'Gram', 1, ARRAY['Mise en place: Keep all ingredients measured and ready. Slice cucumber into thin strips. Prepare coleslaw chilled. Heat oil to 170-175°C. Steam bao until soft and warm.','Coat tofu evenly with tofu batter.','Deep fry at 170-175°C until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Open warm bao carefully without tearing.','Spread bao sauce base evenly inside the bao.','Add coleslaw followed by crispy tofu.','Place cucumber strips neatly on top.','Garnish with black & white sesame.','Serve immediately while bao is warm and tofu is crispy.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2101726a-4d9f-4c64-9768-39bf8bdab625', 'General Tso''s Water Chestnuts', 'Sides', 'aiko', null, null, null, 1, 'approved', 81.22, 81.22, 540, 0, 5, false, 318, 'Gram', 1, ARRAY['Coat water chestnut with flour; shake off excess. Deep fry until golden and crispy; drain.','Heat wok on high flame. Add chopped garlic, Thai red chilli and onion; stir-fry until aromatic.','Add yellow and red bell peppers; stir-fry until slightly soft yet crunchy.','Add sauces (gyoza dip + drunken sauce); bring to a simmer and stir until the glaze thickens.','Add fried water chestnuts and spring onion; toss quickly to coat. Finish with basil. Transfer to serving bowl. Garnish with fried spring roll strips.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('413c18c8-2b82-485a-a903-1392aed4caa5', 'Steamed Edamame (Chilli / Salted)', 'Sides', 'aiko', null, null, null, 1, 'approved', 104.77, 104.77, 540, 0, 5, false, 172, 'Gram', 1, ARRAY['Steam edamame with pods until tender and hot. Drain any excess water.','Transfer steamed edamame to a bowl.','For chilli version: Add chilli crisp and toss evenly to coat. For salted version: Add salt and toss evenly to coat.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('345dbf87-090f-4a11-8f76-c6a2ce1ff35d', 'Korean Mandu', 'Sides', 'aiko', null, null, null, 1, 'approved', 52.77, 52.77, 540, 0, 5, false, 106, 'Gram', 1, ARRAY['Prepare Korean Mandu filling (see filling method below). Allow to cool completely.','Place 1 portion (approx. 75 g) of filling in the center of the gyoza skin.','Moisten edges with water. Fold and pleat to seal securely.','Heat oil to 175°C. Fry mandu until golden brown and crisp, about 3–4 minutes. Drain excess oil.','Drizzle spicy mayo and coriander mayo over mandu.','Garnish with toasted white sesame seeds and julienne cut nori sheets.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'Creamy Corn Rocks', 'Sides', 'aiko', null, null, null, 1, 'approved', 71.65, 71.65, 580, 0, 5, false, 244, 'Gram', 1, ARRAY['Heat corn rocks sauce in a pan over medium heat.','Add water and stir well to adjust the consistency. Bring to a simmer.','Add fried corn and toss to coat evenly with the sauce.','Cook for 1–2 minutes until the sauce clings to the corn and is creamy.','Transfer to a bowl.','Garnish with chopped black sesame seeds, spring onion and pickled red paprika slices. Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2a14daae-fe29-49b3-b59c-c95c7a16b831', 'Kwispy Scallion Pancake', 'Sides', 'aiko', null, null, null, 1, 'approved', 9.58, 9.58, null, 0, 5, false, 267, 'Gram', 1, ARRAY['Prepare all components as per recipes below.','Cook scallion pancake until golden brown and crispy on both sides.','Heat Sichuan soy glaze and brush over the pancake.','Drizzle green garlic cream cheese and sriracha sauce over the top.','Top with scallion salad.','Sprinkle toasted white sesame seeds.','Slice or serve whole.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ab0c2166-13e1-46b9-a206-bc125ba9dff8', 'Cold Spicy Sesame Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 71.18, 71.18, 640, 0, 5, false, 260, 'Gram', 1, ARRAY['Cook soba noodles as per package instructions. Rinse in cold water and drain well.','In a bowl, add cold spicy sesame sauce and place the noodles. Toss well to coat evenly.','Arrange cucumber slices, carrot slices and mix iceberg romaine on the side of the plate.','Place the sauced noodles in the center.','Top with white part spring onion, crushed peanuts and fried sesame.','Serve immediately. Keep chilled until serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dc93a1f6-1250-484a-99ce-433ee63c772f', 'Tokyo Style Pizza (Dough Base)', 'Pizza', 'aiko', null, null, null, 1, 'approved', 536.3, 536.3, null, 0, 5, false, 150, 'Gram', 1, ARRAY['Combine water and dry yeast.','Add flour and mix until shaggy.','Cover loosely and ferment 12–16 h at room temp.','Add fermented biga in mixer.','Add cold water gradually.','Add flour and dry yeast; mix.','Add salt; mix 4–5 min.','Drizzle EVOO; mix smooth (windowpane test).','Rest 1–2 h.','Divide into 150 g balls.','Place in oiled trays; cover.','Cold-ferment (CF) 48 h.','Remove dough; temper 1 h.','Spread/stretch dough evenly.','Apply pizza sauce evenly.','Top evenly with cheese and desired toppings.','Bake in a preheated oven until crust is blistered and golden.','Finish with fresh basil after baking.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ab56ab02-026a-44f5-b0b2-0d770036d2d6', 'Katsu Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 36.46, 36.46, 580, 0, 5, false, 481, 'Gram', 1, ARRAY['Heat katsu curry gently (do not boil).','Heat tofu if required.','Plate rice.','Arrange tofu, pour curry.','Garnish cabbage, cucumber, sesame, togarashi.','Finish scallion oil + unagi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'Thai Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 131.54, 131.54, 580, 0, 5, false, 961, 'Gram', 1, ARRAY['Cook green paste 60-90 sec until aromatic.','Add coconut milk and water; simmer gently.','Add vegetables and cook until just tender.','Season with MSG, white pepper and stock powder.','Serve with rice; finish with scallion oil, chilli oil, sesame mix and lotus stem.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1f013715-5b42-449b-b9a0-450192221f0c', 'Sri Lankan Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 113.05, 113.05, null, 0, 5, false, 507.5, 'Gram', 1, ARRAY['Heat oil in a pan.','Add Kashmiri chilli powder, Kashmiri chilli red paste and Sri Lankan red paste. Sauté until aromatic.','Add tamarind water and stir well.','Pour in coconut milk, stock water and water. Mix and bring to a simmer.','Season with MSG, salt, white pepper, stock powder and fresh Sri Lankan red curry powder mix.','Add tofu, carrot, mushroom and shimeji mushroom. Cook until vegetables are tender.','Add picked red paprika and slit onion. Simmer for 1-2 minutes.','Finish with red chilli oil.','Garnish with basil leaves and fried onion.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('429024fa-077b-4e2c-87a4-a67b79763001', 'Custom Stir Fry', 'Mains', 'aiko', null, null, null, 1, 'approved', 404.28, 404.28, null, 0, 5, false, 5256.1, 'Gram', 1, ARRAY['Heat wok until smoking hot.','Add oil and aromatics.','Add selected vegetables.','Toss on high flame.','Add preferred sauce.','Cook until vegetables remain crisp tender.','Finish with garnish selection.','Serve immediately hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e99ff99e-6695-4397-9214-f962264244ca', 'Chestnut Gyoza', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 64.05, 64.05, 540, 0, 5, false, 793, 'Gram', 1, ARRAY['Prepare filling: mix/chop chestnut with chillies and onion. Cook until aromatic.','Season with stock powder, MSG, white pepper, salt.','Add slurry; cook until mixture binds. Cool completely.','Fill wrappers with 18 g filling; pleat tightly.','Pan-fry gyoza in oil until base golden.','Add water, cover and steam 4–5 min.','Remove lid; re-crisp base 30–45 sec.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'Okonomiyaki Gyoza (6 Pcs)', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 118.72, 19.79, null, 0, 5, false, 894, 'Gram', 1, ARRAY['Cook stages 1→4 sequentially; dry the mix fully. Fold in pickled ginger and tempura flakes.','Fill gyoza skins with filling; pleat tightly (18 g filling per gyoza).','Heat non-stick pan; add oil. Place gyoza; pan-fry until base golden.','Add water, cover and steam for 4–5 minutes.','Remove lid; re-crisp base for 30–45 seconds.','Plate in a fan pattern.','Drizzle mustard mayo and soy-ketchup glaze.','Garnish with chilli, spring onion and sesame.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3f17803-4044-4980-86a7-21cebacf1973', 'Truffle Edamame Dimsums', 'Dimsum', 'aiko', null, null, null, 4, 'approved', 138.89, 138.89, 840, 0, 5, false, 358, 'Gram', 1, ARRAY['Pulse edamame to coarse mince.','Mix with cream cheese, salt, pepper, truffle oil, truffle pate; add water to adjust texture.','Fill wrappers evenly and seal.','Steam 4–5 minutes until cooked.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'Saucy Momos', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 39.31, 39.31, 480, 0, 5, false, 1500, 'Gram', 1, ARRAY['Sauté onion until translucent.','Add cabbage and carrot; cook on high flame until moisture evaporates.','Add spring onion and silken tofu.','Add salt, white pepper, MSG and stock powder.','Mix well and cook until dry.','Cool completely before shaping.','Place required filling in the center of each wrapper.','Pleat and seal properly.','Ensure no leakage and even shape.','Place momos in steamer.','Steam for 4–5 minutes until fully cooked.','Heat sauce base (prepared as per recipe) in a pan.','Simmer gently and adjust consistency.','Keep warm for service.','Spread hot sauce in serving plate or bowl.','Place steamed momos on top.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ede93305-839b-456e-8894-a4109676b350', 'Cheese Chilli Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 106.28, 106.28, 480, 0, 5, false, 636.5, 'Gram', 1, ARRAY['PREPARE FILLING: Mix all filling ingredients thoroughly. Chill the filling for easy wrapping.','ASSEMBLE DUMPLINGS: Place required filling in the center of each wrapper. Seal edges tightly to form momos.','STEAM: Steam dumplings for 4-5 minutes until cooked.','PREPARE SAUCE: Blend or crush all sauce ingredients to a smooth paste. Heat in a pan and simmer. Adjust consistency and seasoning as required.','PLATE: Spread green sauce on the base of the plate. Place steamed dumplings on top.','GARNISH: Top with fried onion and pickled red Bhavnagri.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'Chilli Oil Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 62.35, 62.35, 620, 0, 5, false, 227, 'Gram', 1, ARRAY['Prepare filling: Mix all filling ingredients thoroughly. Refrigerate for 15-20 min for easier handling.','Make chilli oil dumplings paste: Blend all paste ingredients to a smooth, thick paste. Store in an airtight container.','Assemble dumplings: Place required filling in the center of each wrapper. Seal edges tightly to form dumplings.','Steam dumplings: Steam for 4-5 minutes until fully cooked.','Prepare sauce: Heat oil in a pan, add chilli paste and saute for 30 seconds. Add stock water, red chilli powder, salt, msg, stock powder and Sichuan powder. Stir well. Simmer for 2-3 minutes. Adjust seasoning.','Finish & plate: Spread hot sauce on serving plate. Place steamed dumplings on top. Garnish with toasted peanuts, white & green spring onion and fried glass noodles. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a3965fcb-fedb-46d6-abc8-60ca7d9907fb', 'New Dimsum Platter', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 200.19, 200.19, 1640, 0, 5, false, 125, 'Gram', 1, ARRAY['Prepare Dumplings: Ensure all dim sums are prepared, sealed and ready to steam.','Steam Dumplings: Steam all dumplings for 4-5 minutes on medium heat until cooked.','Prepare Dips & Sauces: Portion dips and sauces as per the given gram weight in small bowls.','Assemble Platter: Arrange all dim sums in a bamboo steamer as shown. Place the dip bowls in the centre or alongside.','Serve: Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('59beb5b1-db25-40ca-9584-e304ccc9e175', 'Avocado Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 186.3, 186.3, 840, 0, 5, false, 464.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice avocado and cucumber into thin batons.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add cucumber and avocado.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Brush roll with buffalo sauce.','Coat with black and white sesame seeds.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top with thin avocado slices.','Add crispy rice paper piece.','Drizzle unagi sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c543e252-f735-42b6-a655-6d1692fdc1eb', 'Dragon Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 86.42, 86.42, 720, 0, 5, false, 253.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper into thin strips.','Trim and cut spring onion.','Ensure fried lotus stem is crisp and ready.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add red bell pepper, spring onion and fried lotus stem.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Drizzle spicy mayo on top.','Spoon dragon sauce over mayo.','Ensure even topping on all pieces.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('149622df-1145-487c-bff5-06c3562b8478', 'Volcano 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 118.69, 14.84, null, 0, 5, false, 362.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper and cucumber into thin strips.','Julienne carrot and spring onion.','Dice mango into small cubes.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add spring onion, carrot, red bell pepper, cucumber and mango.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Add spicy mayo on top.','Sprinkle chilly crisps and oil.','Garnish with micro greens.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('464166bf-bb73-4535-a6f0-f299ea4762e1', 'Gimbap 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 111.12, 111.12, 980, 0, 5, false, 325.2, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice cucumber, carrot and pickled radish into thin strips.','Sauté spinach with soy sauce and garlic. Cool.','Cut tofu into strips and toss with soy sauce.','Slice unagi into strips.','Place nori sheet on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','Arrange tofu, unagi, radish, cucumber, carrot and spinach horizontally.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Wipe blade after each cut.','Brush lightly with sesame oil.','Sprinkle sesame seeds if required.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('23e938a7-d990-4341-8cfc-f21f1a1179b4', 'Bombay Blues Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 82.37, 10.3, null, 0, 5, false, 311.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Finely slice spring onion, carrot, cucumber, red capsicum and jalapeño.','Chop coriander.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, spring onion, carrot, cucumber, red capsicum, jalapeño and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top each piece with salsa and tempura flex.','Drizzle sweet chilli sauce, unagi sauce and sriracha.','Serve with soy sauce, pickled ginger and wasabi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2b4adf69-135e-4eff-b957-31f282d74d10', 'Jalapeño Popper Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 83.35, 10.42, null, 0, 5, false, 264.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice jalapeño into thin rings.','Finely chop coriander and spring onion.','Cut raw mango into thin julienne strips.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, jalapeño, raw mango, spring onion and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Roll in fried spring roll for extra crunch.','Spread a thin layer of cream cheese.','Coat the roll evenly with bread crumbs.','Heat oil to 180°C and flash fry until golden and crisp.','Drain on paper towel.','Drizzle unagi sauce and sriracha on top.','Garnish with coriander and sesame seeds.','Slice 8 equal pieces using a sharp knife.','Clean the knife after each cut.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('abf6caf0-3201-4d8e-8584-f5eafdc909bf', 'Corn Tempura Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 140.24, 140.24, 720, 0, 5, false, 399.8, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Drain corn well.','Batter corn with tempura flour and deep fry until golden and crisp.','Slice cucumber and purple cabbage into thin juilenne strips.','Finely chop spring onion.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, cucumber, purple cabbage, spring onion and corn tempura.','Roll tightly using mat, applying even pressure.','Moisten knife and slice into 8 equal pieces.','Clean knife after each cut.','Drizzle sriracha on top.','Serve with pickled ginger, wasabi and soy sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4b517e37-caf1-4af1-9677-4a29fed26b79', 'Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 380.4, 'Gram', 1, ARRAY['Heat wok on high heat until smoking.','Add oil, then ginger; sauté for 10–15 sec.','Add carrot, corn, edamame; toss for 60–90 sec.','Add cooked rice; toss until steamy hot.','Add stock powder, salt, white pepper, MSG; toss.','Add light soy; toss evenly.','Add spring onion; toss and plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'Burnt Garlic Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 424.4, 'Gram', 1, ARRAY['Heat wok on medium-high until hot.','Add oil, then garlic; sauté on medium until pale golden (do not burn).','Increase heat; add broccoli, baby corn and spinach; toss 60–90 sec.','Add cooked rice; toss on high heat until heated through.','Add stock powder, salt, white pepper and MSG; toss evenly.','Add light soy; toss evenly.','Plate and top with fried garlic and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8ac7b402-992a-4520-8739-301daf348edd', 'Mushroom Truffle Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 235.98, 235.98, 680, 0, 5, false, 410.6, 'Gram', 1, ARRAY['Heat wok on high until smoking.','Add oil and garlic; sauté for 10 sec until aromatic.','Add mushrooms; cook until moisture evaporates and mushrooms brown.','Add chili bean paste, oyster sauce and hot sauce; toss for 15-20 sec.','Add rice and edamame; toss on high heat until rice is hot and everything combined.','Add white pepper, truffle pâté and MSG; toss evenly.','Switch off heat; fold in truffle oil. Plate and serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'Hakka Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 36.96, 36.96, 580, 0, 5, false, 275.3, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and ginger-garlic; sauté 10-15 sec.','Add vegetables; toss 60-90 sec (keep crunchy).','Add noodles; toss to separate strands.','Add hakka sauce + stock powder, salt, white pepper, MSG; toss on high heat.','Finish spring onion; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2f60f646-ed1f-4b30-80b1-b978adc5c6bb', 'Drunken Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 38.55, 38.55, 580, 0, 5, false, 269, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and garlic + chilli; sauté 10–15 sec.','Add mushrooms; toss until lightly browned.','Add spring onion whites; stir-fry briefly.','Add noodles + drunken sauce; toss until glossy.','Add bean sprouts + basil; toss 20–30 sec.','Plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'Pad Thai', 'Noodles', 'aiko', null, null, null, 1, 'approved', 65.61, 65.61, 580, 0, 5, false, 345, 'Gram', 1, ARRAY['Heat wok medium-high; add oil.','Add ginger-garlic; sauté 10 sec.','Add mushrooms and carrot; toss 60 sec.','Add noodles and pad thai sauce; toss until absorbed.','Add sprouts; toss 15–20 sec.','Plate and finish with spring onion, peanuts and coriander.','Serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'Shoyu Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 42.6, 42.6, 640, 0, 5, false, 361, 'Gram', 1, ARRAY['Bring stock + dashi to gentle simmer.','Add shoyu tare + seasoning; simmer 3-4 min (no hard boil).','Cook noodles separately; drain well.','Place noodles in bowl; pour hot broth.','Top vegetables; finish sesame + scallion oil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('784ad13a-25bc-41a5-8d1d-dafb8d655452', 'Peanut Butter Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 61.81, 61.81, 640, 0, 5, false, 606.5, 'Gram', 1, ARRAY['Heat oil; sauté ginger + garlic.','Add gochujang + chilli bean paste + chilli powder; bloom 30–40 sec.','Add water gradually; whisk smooth.','Add peanut butter; whisk until emulsified.','Season; simmer 2–3 min.','Cook noodles separately; assemble bowl.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3d49dbcb-368a-472f-948a-0840e70a9631', 'Spiced Miso Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 84.77, 84.77, null, 0, 5, false, 692.5, 'Gram', 1, ARRAY['Heat oil in a pot over medium heat; add ginger and garlic paste, sauté until aromatic.','Add gochujang, chilli bean paste and chilli powder; bloom for 30–40 sec.','Gradually add water while whisking to avoid lumps.','Add peanut butter and whisk continuously until fully emulsified.','Season with stock powder, MSG, white pepper, salt and caster sugar. Simmer for 2–3 min.','Cook ramen noodles separately as per instructions; drain well.','Assemble the bowl with noodles and hot broth.','Top with peanuts, coriander, spring onion, edamame and pokchoy.','Drizzle with chilli oil and serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bf288cfc-7d7e-4868-9db5-32047cef29ec', 'Buttery Chilli Garlic Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 24.29, 24.29, 580, 0, 5, false, 211.8, 'Gram', 1, ARRAY['Melt butter on low heat.','Add garlic + chilli; cook gently until aromatic.','Add chilli crisp + seasoning; whisk with 10–15 ml hot water to emulsify.','Add noodles; toss until glossy and coated.','Plate; top with spring onion and fried garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5870ecb5-7306-447a-8f5e-8aca60e39b41', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 147.5, 147.5, 940, 24.46, 5, false, 831, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.8, 111.8, null, 24.46, 5, false, 482, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('193c332b-2d69-4e57-8191-94fe2192dac8', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 165.84, 165.84, 940, 24.46, 5, false, 880, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9d348f91-6bae-4726-ade7-872b5f09eb37', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 144.03, 144.03, null, 24.46, 5, false, 515, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('def5cafc-ba4b-4c0c-bb21-9a93af984901', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 112.9, 112.9, 940, 24.46, 5, false, 695, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7afa9b26-4fd8-403f-be49-0eb13c5e93fc', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 99.6, 99.6, null, 24.46, 5, false, 395, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('be0a757e-20f3-44e1-bb07-fda722fe0d02', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 136.63, 136.63, 1140, 24.46, 5, false, 620, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('382474ff-f701-4b45-9ac8-d937f4e2705b', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 124.26, 124.26, null, 24.46, 5, false, 364, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('32b67702-ac19-41e7-9446-74d58fd890d4', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 220.88, 220.88, 1140, 24.46, 5, false, 935, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('09b5a3da-b552-47ad-af3d-8f37009b005c', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 194.2, 194.2, null, 24.46, 5, false, 576, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cfd0e311-3e04-4d34-81a6-7398aea9c731', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 129.23, 129.23, 1140, 24.46, 5, false, 812, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('23fba5e5-93ba-468c-8fd4-fdb906faaded', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.47, 128.47, null, 24.46, 5, false, 471.48, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.88, 128.88, 940, 24.46, 5, false, 700, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3983170-7b43-44fb-98ed-6c8c2b4f91ba', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 89.47, 89.47, null, 24.46, 5, false, 410, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('578227ac-3be4-41f7-898a-3b63e78a164b', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.85, 111.85, 1140, 24.46, 5, false, 670, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6c817e52-4db7-4182-b242-c72116ca9e2e', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 120.09, 120.09, null, 24.46, 5, false, 389.04, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d786acdd-218f-406d-911b-49fd0dd5951b', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.2, 125.2, 940, 24.46, 5, false, 650, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4d0cf748-6a08-45e0-877e-68e762f35621', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 110.21, 110.21, null, 24.46, 5, false, 373, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('557b2ac5-4586-4fab-9c8d-7dd50757cae1', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 116.11, 116.11, 940, 24.46, 5, false, 690, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('96519c6c-4279-48ed-bb03-8b959071bddd', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 103.22, 103.22, null, 24.46, 5, false, 405, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a318046d-c7b3-4aef-b95b-fecdbad306ae', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 156.21, 156.21, 940, 24.46, 5, false, 855, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ce8e359f-9d0f-4084-a5c5-152cd9763211', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 134.74, 134.74, null, 24.46, 5, false, 511, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('da15beb6-5a4e-48e7-b69a-996037b989cf', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 113.09, 113.09, 940, 24.46, 5, false, 745, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('598e2dd6-a2db-4540-bb5b-abcfbfa83fec', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 87.91, 87.91, null, 24.46, 5, false, 443, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.6, 128.6, 940, 24.46, 5, false, 691.5, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1c1976af-78cd-4099-b0f3-1afeb3da5236', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 104.51, 104.51, null, 24.46, 5, false, 399, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c47188f7-fb2c-4fe0-9cfb-e519aa977779', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.13, 131.13, 940, 24.46, 5, false, 712.35, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('917812f3-7b38-432e-9320-6d3cd8e27bc1', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 117.28, 117.28, null, 24.46, 5, false, 421.5, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('081c3d3a-4802-4659-9d10-6ba9e9208785', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.63, 125.63, 940, 24.46, 5, false, 615, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2ef6e1b2-4427-44c8-a5b2-e074273b7342', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 103.28, 103.28, null, 24.46, 5, false, 358, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cd4e782a-b13f-4775-a1df-1a4e702a0409', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.5, 131.5, 940, 24.46, 5, false, 735, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 109.76, 109.76, null, 24.46, 5, false, 415, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b13a1530-286d-463f-8c01-d0ebedbedd91', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.21, 125.21, 940, 24.46, 5, false, 740, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1261381e-1d3b-4dcc-8602-dbb812ba5c79', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 99.37, 99.37, null, 24.46, 5, false, 420, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6964b6ec-1eaa-4db5-bef6-cd14239430f5', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 106.53, 106.53, 1140, 24.46, 5, false, 595, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('047a81a5-a674-41de-a8f1-a53421ae820f', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 80.36, 80.36, null, 24.46, 5, false, 330, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2d2d903b-e368-4f62-a70b-216fe00f8cbb', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 189.25, 189.25, 1140, 24.46, 5, false, 630, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 168.98, 168.98, null, 24.46, 5, false, 351, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- pizza variant → master links
update public.recipes set parent_recipe_id = '5870ecb5-7306-447a-8f5e-8aca60e39b41' where id = '12e2e9a6-d1d3-4aa0-8645-32abef90f359';
update public.recipes set parent_recipe_id = '193c332b-2d69-4e57-8191-94fe2192dac8' where id = '9d348f91-6bae-4726-ade7-872b5f09eb37';
update public.recipes set parent_recipe_id = 'def5cafc-ba4b-4c0c-bb21-9a93af984901' where id = '7afa9b26-4fd8-403f-be49-0eb13c5e93fc';
update public.recipes set parent_recipe_id = 'be0a757e-20f3-44e1-bb07-fda722fe0d02' where id = '382474ff-f701-4b45-9ac8-d937f4e2705b';
update public.recipes set parent_recipe_id = '32b67702-ac19-41e7-9446-74d58fd890d4' where id = '09b5a3da-b552-47ad-af3d-8f37009b005c';
update public.recipes set parent_recipe_id = 'cfd0e311-3e04-4d34-81a6-7398aea9c731' where id = '23fba5e5-93ba-468c-8fd4-fdb906faaded';
update public.recipes set parent_recipe_id = 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7' where id = 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba';
update public.recipes set parent_recipe_id = '578227ac-3be4-41f7-898a-3b63e78a164b' where id = '6c817e52-4db7-4182-b242-c72116ca9e2e';
update public.recipes set parent_recipe_id = 'd786acdd-218f-406d-911b-49fd0dd5951b' where id = '4d0cf748-6a08-45e0-877e-68e762f35621';
update public.recipes set parent_recipe_id = '557b2ac5-4586-4fab-9c8d-7dd50757cae1' where id = '96519c6c-4279-48ed-bb03-8b959071bddd';
update public.recipes set parent_recipe_id = 'a318046d-c7b3-4aef-b95b-fecdbad306ae' where id = 'ce8e359f-9d0f-4084-a5c5-152cd9763211';
update public.recipes set parent_recipe_id = 'da15beb6-5a4e-48e7-b69a-996037b989cf' where id = '598e2dd6-a2db-4540-bb5b-abcfbfa83fec';
update public.recipes set parent_recipe_id = '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2' where id = '1c1976af-78cd-4099-b0f3-1afeb3da5236';
update public.recipes set parent_recipe_id = 'c47188f7-fb2c-4fe0-9cfb-e519aa977779' where id = '917812f3-7b38-432e-9320-6d3cd8e27bc1';
update public.recipes set parent_recipe_id = '081c3d3a-4802-4659-9d10-6ba9e9208785' where id = '2ef6e1b2-4427-44c8-a5b2-e074273b7342';
update public.recipes set parent_recipe_id = 'cd4e782a-b13f-4775-a1df-1a4e702a0409' where id = '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc';
update public.recipes set parent_recipe_id = 'b13a1530-286d-463f-8c01-d0ebedbedd91' where id = '1261381e-1d3b-4dcc-8602-dbb812ba5c79';
update public.recipes set parent_recipe_id = '6964b6ec-1eaa-4db5-bef6-cd14239430f5' where id = '047a81a5-a674-41de-a8f1-a53421ae820f';
update public.recipes set parent_recipe_id = '2d2d903b-e368-4f62-a70b-216fe00f8cbb' where id = 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a';

-- recipe_ingredients (1246)
insert into public.recipe_ingredients (id, recipe_id, ingredient_id, component_type, quantity_used, unit_used, calculated_cost, sort_order, wastage_override_pct, cut_type) values
('a718daaa-44c3-4363-a431-14611a79c61c', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', '4bfeea3c-f40b-472d-8f18-aef78c9df0c9', 'material', 1000, 'Gram', 425, 0, null, null),
('c119a489-bbbc-492a-bb57-4f1f212f551e', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 500, 'Gram', 17.19, 1, null, null),
('609b17ab-8a40-437c-83e3-5ddf895e61ff', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 220, 'Gram', 6.27, 2, null, null),
('c805fc60-c6e0-404e-83a4-cea95307288c', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'bd976fab-4bc0-492d-b4b2-aef9390f32c2', 'material', 500, 'Gram', 76.18, 3, null, null),
('384d4721-2613-4b08-974f-09edadbda7a0', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'b57543c3-9987-4bc6-9c7b-52c4715fd7a9', 'material', 800, 'Gram', 18.4, 4, null, null),
('e0d791bb-4f4a-4322-ad39-7eeff6be8214', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 250, 'Gram', 25.25, 5, null, null),
('cec841f9-993a-4522-987a-0c53ecccb018', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'a40de1bf-feee-43d6-851a-9294c3f97d95', 'material', 5000, 'Gram', 523.5, 6, null, null),
('01f40094-920d-4ebc-b9f1-741d4a6ce492', '95f00d97-a273-478f-b486-05111d81381f', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 100, 'Gram', 53.8, 0, null, null),
('de3876a5-9886-4e0d-a594-1da7da1236d7', '95f00d97-a273-478f-b486-05111d81381f', '31c6c2e1-0c0a-452d-b65d-b315579c2bc8', 'material', 1000, 'Gram', 75.2, 1, null, null),
('2911722d-50f3-480a-9271-87788b58ac7e', '95f00d97-a273-478f-b486-05111d81381f', '6c760bc9-6bb7-4a45-b2b0-725cad8aaaaf', 'material', 5, 'Gram', 2.09, 2, null, null),
('b22f5072-d358-48a6-a4c1-262ab4d813e1', '95f00d97-a273-478f-b486-05111d81381f', '737bee95-47e8-4293-90dc-caec7c418436', 'material', 5, 'Gram', 2.56, 3, null, null),
('f2816a7c-f867-40e8-8481-967d92cfaeac', '95f00d97-a273-478f-b486-05111d81381f', '59677f6c-1011-4810-8043-706d54195ea7', 'material', 100, 'Gram', 3.76, 4, null, null),
('811138fd-68eb-45ee-a841-bfef535c8025', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '12b73052-b8d6-4bc4-959d-fa6ea314fad5', 'material', 10000, 'Gram', 1197, 0, null, null),
('d65fec6d-bcf9-48e5-ba45-e551655a5e73', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '2b8ef560-f327-4885-ad0f-1846413f16c4', 'material', 19, 'Gram', 7, 1, null, null),
('68934f9e-01b7-4ffa-b428-71287f69ad65', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '25f5785e-4294-4ea6-b31e-dd664f913098', 'material', 4443, 'Gram', 0, 2, null, null),
('0ae57c44-6098-4089-8157-1bbeda04ef92', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 2221, 'Gram', 0, 3, null, null),
('bd1e9afb-88bc-45a6-a8bb-ad28dc027e6c', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 221, 'Gram', 232.05, 4, null, null),
('040816a4-a204-4689-b855-65699c8a19c5', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 269, 'Gram', 7.67, 5, null, null),
('159afa69-c5f2-4b6d-86f5-66e1178dfbfa', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '9f5cce6e-3b22-4696-bb7d-bdd3f64e9b29', 'material', 75, 'Gram', 9, 6, null, null),
('89e0714c-6aa4-4a20-b927-a7d68160d9bd', 'a11b1997-dee4-4804-adb7-e9e68bd83846', '727cbb5d-7771-49b9-be5d-4d6abba0d73d', 'material', 40, 'Gram', 3.28, 7, null, null),
('bcd8c829-e0dd-4701-ab3d-9bf56305ce3a', 'e3be30e0-d6d0-4a93-a362-3a321d358779', 'd8532cb7-2cd4-46e0-903a-e51226e7d976', 'material', 10, 'Gram', 5, 0, null, null),
('c11f30aa-38aa-4ab2-9478-58c404044718', 'e3be30e0-d6d0-4a93-a362-3a321d358779', '57221778-c510-4dcd-a99e-ebdeb4d9e9b5', 'material', 10, 'Gram', 4.82, 1, null, null),
('1b5ef3c4-768f-4012-a891-ad1ae1ed1e15', 'e3be30e0-d6d0-4a93-a362-3a321d358779', '5df892d8-2ec4-4f00-8acc-5c1949da52b3', 'material', 10, 'Gram', 1, 2, null, null),
('07429faf-a75b-406d-a1c2-4232fc435210', 'e3be30e0-d6d0-4a93-a362-3a321d358779', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 60, 'Gram', 0, 3, null, null),
('67f5548a-7958-4ea6-8587-a15858842e0e', 'e3be30e0-d6d0-4a93-a362-3a321d358779', 'e618b770-1253-4119-8f5d-0976dbb90e88', 'material', 70, 'Gram', 15.65, 4, null, null),
('3bb15f76-ffa3-4381-b86e-618594d93da6', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 100, 'Gram', 105, 0, null, null),
('dfaddc48-dafe-414a-9dfe-0e32a61921ed', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', '971caa70-20ee-46c5-87a7-1aefec515ea9', 'material', 30, 'Gram', 27.15, 1, null, null),
('e4e09b36-8c20-4320-908f-29fd4e1f5ae2', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 20, 'Gram', 6.22, 2, null, null),
('e9c1e368-66cb-476b-a47f-dc8dd183e60f', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 5, 'Gram', 0.14, 3, null, null),
('e1c32617-ca35-4881-be9d-f8be75779331', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', '25f5785e-4294-4ea6-b31e-dd664f913098', 'material', 70, 'Gram', 0, 4, null, null),
('e5ce3200-ff1d-46e0-bb89-bd4e40fb50c7', '6b100575-63d4-4fe8-bb76-a5dfebefcd82', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 250, 'Gram', 80, 5, null, null),
('510e634d-93fe-4cf6-8ba0-2d6d9412d52d', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 5, 'Gram', 5.25, 0, null, null),
('87c74126-8612-4d4b-895f-b1721dc20106', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '0d569d25-bf30-43fd-867e-3ebb006bd808', 'material', 4, 'Gram', 0.28, 1, null, null),
('c6fc3bdf-0688-48db-b429-d8bcdde75183', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 10, 'Gram', 0.72, 2, null, null),
('f8cde6c7-360c-40cc-8fa3-3d5ad76b84ba', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 30, 'Gram', 2.26, 3, null, null),
('f7de1633-2f02-4b75-82f8-a4c4a6b0c60a', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 30, 'Gram', 5.47, 4, null, null),
('3d632a74-5ae9-4fbc-97cb-7e26467249d8', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 5, 'Gram', 0.17, 5, null, null),
('d3f6cc1d-1bc7-40dd-ad21-be45e6302418', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'f4136be6-5d6f-47e3-be1b-5a31285afaf7', 'material', 30, 'Gram', 8, 6, null, null),
('d6e2f836-ceb8-4172-8540-f758f0ca99e6', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '50af20fc-26e4-4250-9064-0deadcfced12', 'material', 20, 'Gram', 0.62, 7, null, null),
('9e7ff29c-7fcd-445c-a34e-26b87a90bbe8', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 50, 'Gram', 0, 8, null, null),
('24da4cda-a492-47e4-a286-976da8b36c27', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'recipe', 30, 'Gram', 3.96, 9, null, null),
('868a1327-bfa8-4186-8b20-6ce7fee26fc7', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '332d2059-1d2b-4c42-8d79-ac40aa5c617c', 'material', 200, 'Gram', 47, 10, null, null),
('319aefa0-6bea-41a6-9eb2-7f637016d680', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 0.5, 'Gram', 0.17, 11, null, null),
('0316202b-876e-4ffe-a87c-ed86b351fa5b', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 1, 'Gram', 0.03, 12, null, null),
('ca08b0ff-6835-4707-88cc-57a0e79defb9', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('b05d8141-ad90-403e-bd3b-2663c376b87f', 'f9bda125-40c4-4791-9c9b-1b11eb805304', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 2, 'Gram', 0.2, 14, null, null),
('d0eb8653-7a61-45d9-8611-1e39d461aed6', '9f1e44fd-453d-42fe-b757-f2688893eaeb', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 1000, 'Gram', 252, 0, null, null),
('70e05a42-c5a8-4bc5-bb08-ff92a13427e0', '9f1e44fd-453d-42fe-b757-f2688893eaeb', 'e5ff968a-02fd-4c7a-b5d4-d3bc13ef8a86', 'material', 25, 'Gram', 4.75, 1, null, null),
('908e0947-6b22-447a-89fd-1c7516c85ed1', 'ae22ad7a-679c-48a8-90c7-7cbf00785901', '6ba1f12c-f4f7-4bdd-b393-f215537b0b85', 'material', 100, 'Gram', 15.32, 0, null, null),
('d9f5826a-03e0-4aa1-9485-ee16f7523406', 'ae22ad7a-679c-48a8-90c7-7cbf00785901', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 2, 'Gram', 2, 1, null, null),
('fc9e9b5b-960e-4fb8-9a0a-a6a28d3fc424', '9025ff8a-1639-453a-a8a7-6b8d6d7670a8', '287405ec-d752-44b3-a9b7-507cd9283b83', 'material', 100, 'Gram', 19, 0, null, null),
('d7cde55b-2337-4e7c-881c-46ee1bd318a9', '9025ff8a-1639-453a-a8a7-6b8d6d7670a8', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 200, 'Gram', 0, 1, null, null),
('fdd135a0-916a-4140-a3cb-c0c8c0039b30', '21bc4c35-ccec-417a-ba43-03d76889c33a', 'c5e6d4ab-2a3f-4cca-9897-cc8c5db37d88', 'material', 40, 'Gram', 2, 0, null, null),
('4bc6e251-4179-42a1-a621-92d6f70d4317', '21bc4c35-ccec-417a-ba43-03d76889c33a', '3be12901-de36-4cf8-9eaf-285577602b5c', 'material', 5, 'Gram', 1, 1, null, null),
('fb35120d-32b6-4061-aa35-6144ba2ffd9d', '21bc4c35-ccec-417a-ba43-03d76889c33a', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 2, null, null),
('5bbd6322-b546-41cd-9cb3-9ac7ae96feb2', '21bc4c35-ccec-417a-ba43-03d76889c33a', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 1, 'Gram', 1, 3, null, null),
('a3dbe196-f18e-4b09-bbd1-16fbbbe13466', '21bc4c35-ccec-417a-ba43-03d76889c33a', 'adae9a5b-c2fe-453e-8e96-6341bfdafb53', 'material', 20, 'Gram', 1.7, 4, null, null),
('1701bb5c-f3c3-4d18-8714-df5c2c94ab45', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '9d568b45-c2a7-4af7-b52b-2a50825beb73', 'material', 40, 'Gram', 160, 0, null, null),
('7fcb3454-d1c7-4e84-8526-abb304dc7204', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '2debb3b9-5a70-4448-9cda-b09663bb1173', 'material', 15, 'Gram', 14, 1, null, null),
('22de305e-ce49-486a-95e7-932757e8fa9e', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '728cb67a-218a-4ac3-9646-a3d296afaa4c', 'material', 15, 'Gram', 3, 2, null, null),
('cca5f7b7-8507-44e5-99ac-3201c7127398', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 10, 'Gram', 10, 3, null, null),
('e0ba83dc-015d-4113-aeb5-d83efc7dacbc', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '82b366c6-df42-4a56-99f9-99f402f0674a', 'material', 3, 'Gram', 18, 4, null, null),
('9ae31bb1-0a35-4431-b55c-0dc10c5b7887', '19807fac-42fb-47f5-aad3-65feedbdf4e2', '5b9b8bd5-37b5-490c-a929-f1f922213e9c', 'material', 2, 'Gram', 4, 5, null, null),
('2ed1efbf-d613-4fd9-ab3f-ce16d14d0411', '19807fac-42fb-47f5-aad3-65feedbdf4e2', 'c198f2eb-e3a4-4d65-b767-2f1018753977', 'material', 2, 'Gram', 8, 6, null, null),
('a13598c8-1142-4dca-bf91-117d04cad53a', '29899406-0eb9-41e4-aecd-b288adf7d325', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 150, 'Gram', 5.16, 0, null, null),
('b9c1b49f-d56e-4fbf-8a12-ddb1ee4959f2', '29899406-0eb9-41e4-aecd-b288adf7d325', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 10, 'Gram', 1.82, 1, null, null),
('9ecb1af1-4fe4-424d-b69b-8a9f0eea74cc', '29899406-0eb9-41e4-aecd-b288adf7d325', 'bd976fab-4bc0-492d-b4b2-aef9390f32c2', 'material', 10, 'Gram', 1.52, 2, null, null),
('021251ca-74cd-46bf-b2ec-3e85c1b2aaeb', '29899406-0eb9-41e4-aecd-b288adf7d325', '60db8c80-f069-41a4-b426-b281a28c6e42', 'material', 10, 'Gram', 0.42, 3, null, null),
('b884245b-9f21-458c-8cf5-a0bdd4a5fffb', '29899406-0eb9-41e4-aecd-b288adf7d325', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 30, 'Gram', 4.29, 4, null, null),
('91dee987-e5cd-401b-90a5-ebff8d5407f7', '29899406-0eb9-41e4-aecd-b288adf7d325', 'fea6dc3a-3c65-459d-8e38-1ebddd30cd7b', 'material', 4, 'Gram', 1, 5, null, null),
('a01ffd86-db75-4fde-ad63-6fb94b3febfe', '29899406-0eb9-41e4-aecd-b288adf7d325', '4473a25d-158c-4fce-b226-b7b091f1c320', 'material', 1, 'Gram', 1, 6, null, null),
('ce754466-0e9e-4f83-b7a0-32108f9c34e4', '29899406-0eb9-41e4-aecd-b288adf7d325', '48d0687d-295e-4e7b-a702-f8178b9b698c', 'material', 7, 'Gram', 0.18, 7, null, null),
('7a417a84-a02f-4044-9178-d2f1f41dc836', '29899406-0eb9-41e4-aecd-b288adf7d325', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 7, 'Gram', 2.24, 8, null, null),
('6b26914c-0068-4693-9c10-83e1fa8eaf8f', '29899406-0eb9-41e4-aecd-b288adf7d325', '19807fac-42fb-47f5-aad3-65feedbdf4e2', 'recipe', 10, 'Gram', 24.94, 9, null, null),
('bad94655-751f-4941-b7f7-83c5f25fa7a3', '29899406-0eb9-41e4-aecd-b288adf7d325', '85cfb1fe-591d-4db0-925c-d0f3d4b5c69f', 'material', 2.5, 'Gram', 2, 10, null, null),
('24c85211-9870-4dcb-8ac6-e3e6bdd061e1', '29899406-0eb9-41e4-aecd-b288adf7d325', '7f1ee32c-fbf9-4ab8-bf05-c5d97043de74', 'material', 1.5, 'Gram', 2.14, 11, null, null),
('d1ee1de1-076b-4a76-b737-2bc9d0f8d181', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'bcb5708b-bd83-4b16-bb22-4a643ca547d9', 'material', 10, 'Gram', 4.63, 0, null, null),
('bda5f605-8901-4c84-9e26-125e45eafce1', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '98242278-890b-43f7-b75e-4cf059cdcc8f', 'material', 10, 'Gram', 1.79, 1, null, null),
('da1991c8-90b0-4fea-9c49-e9306dd24c5b', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '8368d51c-b656-44a7-beba-ac9f53294cb8', 'material', 10, 'Gram', 2.41, 2, null, null),
('dd708b3f-ecf4-49e2-b407-89d99f0438f6', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '46b8351f-1246-42d8-b059-e010322df82b', 'material', 10, 'Gram', 2.41, 3, null, null),
('7dacb71a-20cf-48ca-8574-f842d68db988', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '8de080ae-a902-47ae-aa9b-37e654126bbc', 'material', 30, 'Gram', 15.16, 4, null, null),
('d5f7796d-90c9-4845-bbbd-3b2d93006f57', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'b09306d4-1f25-4bb8-be43-c27bc9053eda', 'material', 30, 'Gram', 6.83, 5, null, null),
('6c802ebe-6eb4-4670-9b6e-9076ac303b41', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'cb975211-a779-486d-ba69-3c76da82d784', 'material', 5, 'Gram', 26.88, 6, null, null),
('c1969f34-63f2-489a-91f7-4d2ec19acfb2', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'd0513eb6-00dc-479e-a284-5c1853e04ff9', 'material', 40, 'Gram', 24, 7, null, null),
('d5ddfc3b-5c54-418f-9e2b-a62489b36dc3', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '298a1d86-91ca-4b0f-a522-3574e8e7b5ff', 'material', 4, 'Gram', 4, 8, null, null),
('b167d8e1-16b8-43da-9c97-7b342d00b870', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 2, 'Gram', 2.1, 9, null, null),
('0870a387-fb6a-4dc4-abc4-848a85b8c477', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '8da3364a-514b-4093-872e-b35dcb010eca', 'material', 2, 'Gram', 2, 10, null, null),
('52bc91dc-59fc-486c-a681-7e0d4ee177e9', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '673983d2-d6ee-477b-9524-dc6cd75a6f39', 'material', 2, 'Gram', 0.8, 11, null, null),
('27e60859-dd7c-45c6-b266-d5ba03e8eebf', '30722f5b-4b0c-432f-b41e-4361c7b907cd', 'a7c1c47b-50a4-45c0-b329-7bd65a6ffdb5', 'material', 1, 'Gram', 0.1, 12, null, null),
('3538fefa-3490-4269-bd0f-b8d7e8088387', '30722f5b-4b0c-432f-b41e-4361c7b907cd', '11450463-68fe-46b9-9a1d-59dd0a06a2c4', 'material', 80, 'Gram', 72.62, 13, null, null),
('473124b5-e5c2-4070-a06d-42222855a88e', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '8368d51c-b656-44a7-beba-ac9f53294cb8', 'material', 50, 'Gram', 12.06, 0, null, null),
('ac2bf073-0c9f-4162-9b46-d4247eadb843', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '98242278-890b-43f7-b75e-4cf059cdcc8f', 'material', 50, 'Gram', 8.96, 1, null, null),
('4fcb100d-86a6-452b-bc27-33257fc559b1', '607b258a-0009-4101-b8fc-a1ba6e1ae321', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 20, 'Gram', 0.55, 2, null, null),
('82d04bcc-2e9e-4779-9a1b-ace9decbb309', '607b258a-0009-4101-b8fc-a1ba6e1ae321', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 1, 'Gram', 0.03, 3, null, null),
('3e793fc9-7d6b-4aa6-87be-36ad8694a48a', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('05ae5ecd-ec22-4689-ae94-8a8c713d3f75', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '77ba00cd-b9d4-4f71-936c-06a1bb3692f6', 'material', 6, 'Gram', 8.1, 5, null, null),
('84f6f710-00bc-45a4-8968-fdddd3119435', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '9f0519ed-392e-418c-9983-96ec9c2ed18e', 'material', 10, 'Gram', 1.39, 6, null, null),
('4e5a6523-5665-4f22-8d07-3b872203ec4f', '607b258a-0009-4101-b8fc-a1ba6e1ae321', '8241eb39-5c44-43fe-82bc-bf5b959cd65d', 'material', 50, 'Gram', null, 7, null, null),
('3af95997-1d44-4dca-b6cd-2d2badca63ed', '239c18b2-888e-4d74-875d-d4b744540111', 'bcb5708b-bd83-4b16-bb22-4a643ca547d9', 'material', 30, 'Gram', 13.88, 0, null, null),
('dd864e82-1dd9-427b-889d-91ce42d13c24', '239c18b2-888e-4d74-875d-d4b744540111', '298a1d86-91ca-4b0f-a522-3574e8e7b5ff', 'material', 12, 'Gram', 12, 1, null, null),
('cda24474-47a4-4a0b-ad1b-eb81c94ba912', '239c18b2-888e-4d74-875d-d4b744540111', '753ca806-1ccf-4151-8c6d-0824aa2db221', 'material', 80, 'Gram', 29, 2, null, null),
('87e888de-1de6-4186-9bba-27fab8600035', '239c18b2-888e-4d74-875d-d4b744540111', 'feeb6f2b-a1fd-4383-a782-586f2283ec69', 'material', 50, 'Gram', 20, 3, null, null),
('57aed5d5-ac60-43af-b81e-b2df039dac2f', '239c18b2-888e-4d74-875d-d4b744540111', 'cee08965-9ed2-4bc6-85dd-2b6d58c4c5e0', 'material', 60, 'Gram', 41.51, 4, null, null),
('0dd74ca7-9d47-4bcf-a0de-21945d67e6ac', '239c18b2-888e-4d74-875d-d4b744540111', 'ff5aabbd-0525-42c1-87b8-b57f42331a4b', 'material', 20, 'Gram', 16.2, 5, null, null),
('7a5d2fab-f190-4586-83e2-09e4e519862d', '239c18b2-888e-4d74-875d-d4b744540111', 'cb975211-a779-486d-ba69-3c76da82d784', 'material', 5, 'Gram', 26.88, 6, null, null),
('231f2594-0002-475f-90e2-2e9f290774b7', '239c18b2-888e-4d74-875d-d4b744540111', 'b5e6776e-3508-45e5-bb91-f976b5c280be', 'material', 1, 'Piece', 0.93, 7, null, null),
('7c5b5a28-2fa7-4304-90fe-65fe88a972b5', '239c18b2-888e-4d74-875d-d4b744540111', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 8, null, null),
('7626e07f-2537-4b75-bcdc-57dec81f9405', '239c18b2-888e-4d74-875d-d4b744540111', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 1, 'Gram', 1, 9, null, null),
('9e4cec77-a02a-4319-a4ac-6aca737882c1', '239c18b2-888e-4d74-875d-d4b744540111', '673983d2-d6ee-477b-9524-dc6cd75a6f39', 'material', 5, 'Gram', 2, 10, null, null),
('54f7f4bc-3e0b-4e2b-8928-db2a7533b680', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '68f6276e-2499-4b7b-9884-2f9f42ef1054', 'material', 31, 'Gram', 5.55, 0, null, null),
('2b51f65f-dfa7-4b29-8179-e879c71470b4', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'ea81d7f2-b814-4de0-8fac-74620eb41988', 'material', 15, 'Gram', 3.56, 1, null, null),
('36ddc046-c8cd-486f-88ed-e1240f8e05bb', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'f4d53822-a41c-40f4-b536-6f341530dff1', 'material', 15, 'Gram', 5, 2, null, null),
('8f6b323c-e674-47c8-a61a-8163b5cea1b0', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 1, 'Gram', 0.03, 3, null, null),
('1f2c1de9-93fe-42f9-8030-e3fbe24e1ce2', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('77f3c440-028d-4cc7-a773-d3c0ece14971', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '298a1d86-91ca-4b0f-a522-3574e8e7b5ff', 'material', 10, 'Gram', 10, 5, null, null),
('1e2073b5-2374-45db-8e0e-6e95a5dbc9fa', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'bcb5708b-bd83-4b16-bb22-4a643ca547d9', 'material', 15, 'Gram', 6.94, 6, null, null),
('3fbe0c0e-1d00-439f-ad43-f8e7dfec3e70', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'cee08965-9ed2-4bc6-85dd-2b6d58c4c5e0', 'material', 120, 'Gram', 83.02, 7, null, null),
('e3664651-aa78-4d57-8700-e0a8e37b7cd6', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 2, 'Gram', 2.1, 8, null, null),
('4ae4304c-c95c-4c9a-86e4-76e450396fda', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '499e5b1f-8d77-4343-81d7-98795b81bc9d', 'material', 0, 'Gram', 0, 9, null, null),
('6face4b6-7a5c-46db-807a-4beed72c1ffc', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'ac77dab8-62e0-458b-997b-12d8e6fee79e', 'material', 5, 'Gram', 13, 10, null, null),
('616dbe27-df06-42b6-8ac0-2a6593c50190', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '9a016a1c-1a98-4811-a195-f2232011c46a', 'material', 0, 'Gram', null, 11, null, null),
('0197d2c6-1b4d-40d2-b9fb-ae6c1dacfadc', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'aa40d136-a737-4d73-a064-277daf2cb647', 'material', 80, 'Gram', 21.34, 12, null, null),
('3a184bb7-3c17-4282-bee0-b9cc0387df5e', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '2dd17265-d2a4-4d8a-8665-d13593e674af', 'material', 35, 'Gram', 7.97, 13, null, null),
('1ab65ecb-a8c8-4f85-a622-a91f3702e466', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', '151a95b5-b185-43b1-b349-2e758468231f', 'material', 10, 'Gram', 5.05, 14, null, null),
('0a50dc3d-c25a-425a-947b-09a06405e54e', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'b5e6776e-3508-45e5-bb91-f976b5c280be', 'material', 3, 'Piece', 2.78, 15, null, null),
('61bfb376-52f0-4e7f-a089-2d4a5c78633b', '9414ac1c-3867-4e4c-8350-e08a9a3b8959', 'd4abe84d-dfaa-4193-898c-1ee43698bb2b', 'material', 5, 'Gram', 1.78, 16, null, null),
('8dfe6889-eb2f-490f-bcda-42e7a5aa9a68', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '32e82839-c251-4b36-813c-1fa4b02cc966', 'material', 650, 'Gram', 117.45, 0, null, null),
('f965031e-cb16-4912-af63-15819bb337e2', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 90, 'Gram', 2.48, 1, null, null),
('3300cd29-515b-4a72-8842-65555eac09ce', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 16, 'Gram', 2.92, 2, null, null),
('8019d764-e8be-4103-a7fd-9758eb3c3c8b', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'a0afdbe0-3e23-4c84-82d0-1c9a2eb3237c', 'material', 70, 'Gram', 4.78, 3, null, null),
('7438d292-ffc9-40c1-8d78-b7275482b112', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '27a46d0e-a3d9-4d93-9ccb-f42c66271d58', 'material', 120, 'Gram', null, 4, null, null),
('563dc706-e664-43d5-8b40-a976cd2ce789', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 160, 'Gram', 0, 5, null, null),
('0c638511-16d5-4e4d-87d5-16d258ee3587', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 6, null, null),
('d75d9abb-496a-4f75-9431-bdce0f96a4bd', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 7, null, null),
('9292c200-f72c-4615-b106-b5114eb04f63', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '3be12901-de36-4cf8-9eaf-285577602b5c', 'material', 0.5, 'Gram', 0.1, 8, null, null),
('f17ccabd-a505-4a09-84e9-c836bc22edc7', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 5, 'Gram', 0.91, 9, null, null),
('6f7aac14-22dd-482d-a39c-f0dec36f4c04', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 5, 'Gram', 2.04, 10, null, null),
('353e24eb-b6e7-48ea-a1e6-1950aef0a52d', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '47b4b4ad-2beb-4ea0-bb0d-f1129c7c9c42', 'material', 70, 'Gram', null, 11, null, null),
('18a7f469-c5c1-4d95-8832-75106d40530a', '05544c20-69ff-4e59-9b8c-e3d39b11caa2', '48542725-c17d-444f-a0f6-859449ac6b46', 'material', 5, 'Gram', 3, 12, null, null),
('ea8d18ed-ddf4-48d7-adc3-97e2562e9705', 'f4c0c26a-6248-492d-9951-df3cb7cb372c', '3c7c93a8-1963-4ecd-9e04-b90ce8aabba9', 'material', 96, 'Gram', null, 0, null, null),
('9956f44d-0ef8-4363-b783-a2986df71657', 'f4c0c26a-6248-492d-9951-df3cb7cb372c', '368fc303-992c-431a-b16d-4058546e0449', 'material', 18, 'Gram', 10.79, 1, null, null),
('ef752dbd-24d9-4e06-876d-47283704e03c', 'f4c0c26a-6248-492d-9951-df3cb7cb372c', '4fc7e9be-cadd-4226-b253-76288f0766b3', 'material', 96, 'Gram', null, 2, null, null),
('ebf030ee-e55a-4ef1-8b08-1842c9a90ee9', 'f4c0c26a-6248-492d-9951-df3cb7cb372c', '9830524f-1b83-4747-94c0-017e5d1c3a55', 'material', 12, 'Gram', 1.46, 3, null, null),
('a278289d-826e-41e1-861e-502042743393', 'f4c0c26a-6248-492d-9951-df3cb7cb372c', '4509ef74-5f22-492e-a874-94ff95795fe2', 'material', 0, 'ML', 0, 4, null, null),
('69b1f8a8-1514-4d40-aa88-dad1a68b982e', 'a002bb6d-fb97-4db7-b40f-e4b0c894562e', '6d607aa5-c990-4de2-806e-fcb3ac37854b', 'material', 150, 'Gram', 8.45, 0, null, null),
('c11e45b4-041c-4a1e-8a6b-53d690f458c7', 'a002bb6d-fb97-4db7-b40f-e4b0c894562e', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 1, null, null),
('2e9a3f08-11d3-4377-a384-fe339d470df8', 'a002bb6d-fb97-4db7-b40f-e4b0c894562e', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 2, null, null),
('81bc1065-1b35-4a15-bdf7-9a8b632f95a7', 'a002bb6d-fb97-4db7-b40f-e4b0c894562e', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 3, 'Gram', 0.87, 3, null, null),
('4067f8ac-d5b5-43ac-ae02-7795c52261a1', 'a002bb6d-fb97-4db7-b40f-e4b0c894562e', '1346710c-bcf0-450d-a8b1-1b4b75294fd9', 'material', 2, 'Gram', 0.4, 4, null, null),
('f32a445c-447d-42a2-a05a-bb9824620b5e', '85112faa-baf6-416d-9c52-8ee44a034fd8', '1fc49e94-89c9-4d70-b99d-473c3c1b8ef2', 'material', 105, 'Gram', null, 0, null, null),
('2d552b03-362c-4937-91ef-8e3076e42114', '85112faa-baf6-416d-9c52-8ee44a034fd8', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 60, 'Gram', 53.04, 1, null, null),
('9a3453c5-fb8b-4914-a3b2-dc10f452de3e', '85112faa-baf6-416d-9c52-8ee44a034fd8', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 10, 'Gram', 5.38, 2, null, null),
('4c7371f6-4caf-4466-a4db-a618dd50c63f', '85112faa-baf6-416d-9c52-8ee44a034fd8', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 3, null, null),
('e502cef3-8a85-4757-a9e8-fd874ffaffc1', '85112faa-baf6-416d-9c52-8ee44a034fd8', 'b71a0cf4-4300-47fd-966d-2eed57217bb5', 'material', 7, 'Gram', 1.4, 4, null, null),
('8f10f451-1760-4950-b3b4-db4de43ad2c4', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'dd257032-736e-4572-871a-dae14310dc93', 'material', 200, 'Gram', 56.7, 0, null, null),
('3d19d99f-4141-4218-b6fc-ece0c0c12cef', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '7708dfa8-2f54-40db-9231-1638e85043dc', 'material', 5, 'Gram', 1.09, 1, null, null),
('7785d3a7-5823-4584-9a68-bef17aba61cf', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '99b5d2fe-bcd9-4d46-996d-96306493db7f', 'material', 3, 'Gram', 1.02, 2, null, null),
('d3ad1b46-6239-4307-a24d-c67e1513682a', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 10, 'Gram', 2.89, 3, null, null),
('536b41e3-c0cd-474b-ada0-74b475bf59aa', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 20, 'Gram', 8.75, 4, null, null),
('5e92b1fa-a034-4411-bb4d-b4e30356ee62', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '1e4841bc-dbde-46cf-9398-1a8e26e078c9', 'material', 5, 'Gram', 3, 5, null, null),
('e96fce93-4d2c-47ef-a8d4-2acc3a3e0e2b', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '434be61a-a0db-4d83-9d1a-f11e7dcef191', 'material', 0, 'Gram', 0, 6, null, null),
('f0fe6471-117b-4f2e-9717-519ae5752f38', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '53e01c0c-c64b-489e-a12f-210ced69579c', 'material', 44, 'Gram', null, 7, null, null),
('4f8aedcf-adb3-40ae-8e06-596d647a98ae', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '12a568e0-7c71-4e81-82d8-8a3493d6247a', 'material', 0, 'Gram', 0, 8, null, null),
('fdcf116c-9bc6-4da3-ad4c-3e508bf86a8d', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'c80d72b8-5090-4004-82eb-d63a3b04cdc8', 'material', 40, 'Gram', 23.97, 9, null, null),
('0c427b49-9683-43c3-b61d-d42fea28a923', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '042856db-0e9c-42cf-a710-ffa7fd5e301e', 'material', 30, 'Gram', null, 10, null, null),
('2e793c58-ad0c-485c-b1c3-ac348a177e1c', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'fc1b9fc7-9c8c-49f4-ab4f-774d80c438f3', 'material', 0, 'Gram', null, 11, null, null),
('2557b0b9-b483-41ab-b334-ba33164375df', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '94427f65-c7f1-415b-a919-263dec4239ca', 'material', 0, 'Gram', 0, 12, null, null),
('e331d11a-b114-40aa-ab94-ffa4a3294562', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '17f33ed0-202a-4cf8-93fa-690813b502a8', 'material', 150, 'Gram', 34.5, 13, null, null),
('03143f2a-1d22-46e6-a99c-08e31df3579f', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'fc81f4c7-68e6-481c-915c-2b0795799bec', 'material', 15, 'Gram', 0.34, 14, null, null),
('684de563-967a-4c55-87cc-ac3d338ada37', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 15, null, null),
('e6f5d2f4-2291-4eca-8aba-047699d45923', '7610ed59-a475-4ae3-a190-763d78d5ffc4', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 5, 'Gram', 1.45, 16, null, null),
('c6887d1f-d7e2-480f-a682-c2ee23d10e61', '7610ed59-a475-4ae3-a190-763d78d5ffc4', 'cb0be924-cdf8-4133-96d0-d051e3de0af0', 'material', 0, 'Gram', null, 17, null, null),
('7ca70a1c-cd76-4e9b-be3b-082ec08d71d3', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'bdb4d501-b297-49db-816c-baf2c666a7eb', 'material', 280, 'Gram', 78.4, 0, null, null),
('8645be2a-4627-42b1-b83e-e5a50cdc649c', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 15, 'Gram', 2.14, 1, null, null),
('8737c6ec-cfb7-43ef-b207-c9761c59f351', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'fc81f4c7-68e6-481c-915c-2b0795799bec', 'material', 23, 'Gram', 0.53, 2, null, null),
('9c40fa7b-d6b0-4f30-bae4-a072bf1838c2', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 3, null, null),
('d6ec4f9e-8468-4ecc-8927-1900b4bf9216', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 4, null, null),
('b139344a-39e8-4d21-a453-bc052fca7d16', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'f0dfdb84-3334-43fe-84ba-20db06778c99', 'material', 10, 'Gram', 6, 5, null, null),
('1d93edab-b5f1-462f-8b8e-d5e4e1ee7cc0', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', '298a1d86-91ca-4b0f-a522-3574e8e7b5ff', 'material', 3, 'Gram', 3, 6, null, null),
('ef30053b-1935-4abe-81fd-69fe01d05840', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 5, 'Gram', 1.45, 7, null, null),
('8e38cc72-512a-41ad-ba30-6807976f0dd4', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 5, 'Gram', 0.14, 8, null, null),
('e56c325e-6d57-46fc-9e24-4b7aaa916b5b', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', '723b0dd7-4064-4f89-bfc8-c34b8157c24b', 'material', 1, 'Gram', 1, 9, null, null),
('a6da0b2f-7c1e-46c9-a82c-a6100019b7cb', 'd4df059a-01fa-49e5-90be-e1cfd95286a7', '99b5d2fe-bcd9-4d46-996d-96306493db7f', 'material', 3, 'Gram', 1.02, 10, null, null),
('5b75a0ea-8ae1-4bf4-8715-b87b42151554', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 10, 'Gram', 10.5, 0, null, null),
('fd880bff-defb-46be-9823-3aa8423aa873', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'f5f04403-d790-413b-b769-e7d426326160', 'material', 120, 'Gram', 98.7, 1, null, null),
('dc11076b-9607-4e1c-a0f8-85dccb505a39', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 2, null, null),
('5eb34f1e-04ea-415c-8f2e-8f9dd641134d', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '599345fa-07b8-4dc4-b65f-d8a09f449270', 'material', 10, 'Gram', 0.23, 3, null, null),
('acba5891-06cb-4a23-b54e-5b48f6099cd2', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'd2f0b196-20b8-4b8b-995d-aa818c6ebfb0', 'material', 5, 'Gram', 1.48, 4, null, null),
('49e4ef45-8b11-4a2d-8501-e757c03cb266', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'c61867ab-5a91-466f-92d5-fda3e9c18962', 'material', 5, 'Gram', 4.45, 5, null, null),
('7589c664-06fb-4358-b81a-5b80cf14ad07', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'ad93e9d5-d0a8-4e7a-9a00-5e9393a7783f', 'material', 0, 'Gram', null, 6, null, null),
('e3ea0a9b-f35d-496b-abd8-d7f456243f52', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 230, 'Gram', 203.32, 7, null, null),
('95c3f803-e644-4348-ba0f-fcd3abfe8a90', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'b1558d80-b3bc-4ee2-b780-cfc6efd026e7', 'material', 150, 'Gram', 16.89, 8, null, null),
('3bbf7bbd-52b7-4e24-9ad7-83260824afd0', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 60, 'Gram', 10.92, 9, null, null),
('c8215da6-d5bb-45c1-8ca9-283e80bdeaa3', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'ceee1d07-77fa-4fe5-9604-93b5da463f7c', 'material', 60, 'Gram', null, 10, null, null),
('6c5debec-0f28-448b-b27d-21653c83ebfa', 'c05f4bac-c199-4bb8-b809-4a771a02e418', 'ad93e9d5-d0a8-4e7a-9a00-5e9393a7783f', 'material', 0, 'Gram', null, 11, null, null),
('7199058e-ad46-4d2d-bb58-ddbda8948d97', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '0238d3de-8254-407c-827e-b4aaafdb4e96', 'material', 4, 'Piece', 0.33, 12, null, null),
('ca1c2a66-ff7f-46cb-9bed-0afd755809f0', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '18184f4c-174d-47f6-a89c-5089208fd850', 'material', 3, 'Gram', 1, 13, null, null),
('918f5bad-653a-4826-8529-2116e8a853b1', 'c05f4bac-c199-4bb8-b809-4a771a02e418', '1b28a972-b7a0-4858-9f60-e5b6e67ee7c5', 'material', 3, 'Gram', 2.44, 14, null, null),
('2c065cca-1c64-48a7-8bc5-ecd66fa4ce0d', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 2, 'Piece', 2.1, 0, null, null),
('008da459-4a95-4f10-816d-08b7c466df7b', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 120, 'Gram', 3.3, 1, null, null),
('909c09a3-9556-4c5e-bf67-37339af53d63', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 15, 'Gram', 2.73, 2, null, null),
('a3f6fd1b-2404-4d27-9233-953763e64b8c', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 100, 'Gram', 5.06, 3, null, null),
('eb8e14cb-b4f3-4a62-8b2a-cc966604ac0f', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '8b0673a3-3f56-4f5c-a1b6-16a1df6c8d2a', 'material', 800, 'Gram', 54.64, 4, null, null),
('bd0e7bbc-6e86-4f2b-bd3b-4425506d4450', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 11, 'Gram', 3.43, 5, null, null),
('324cf0f4-6535-4710-9efb-677ef6e43877', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 500, 'ML', 0, 6, null, null),
('74dd208c-87ec-4342-8a96-809b31a57f5e', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '764a19d8-7714-40c9-b974-3d14703b4386', 'material', 30, 'Gram', 14.64, 7, null, null),
('e341cafa-44ce-4116-9070-dfdd876b38c3', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '687f2299-c937-49c7-be99-19c96dcddd81', 'material', 2, 'Gram', 0.68, 8, null, null),
('f142e4a9-f01e-4f9a-969f-18514a0e7860', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '1055527d-286d-4de4-9e6d-cfe9f669c29f', 'material', 1, 'Piece', 0.26, 9, null, null),
('33ee53c3-78bb-448a-9800-de727ce3c479', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 0, 'Gram', 0, 10, null, null),
('5b74c370-ea98-48ee-be2a-e6d2dc269bae', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0, 'Gram', 0, 11, null, null),
('11d85fc7-c47b-41d0-be6b-791889f50e52', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '46c9e81d-e906-4e66-97d7-5c33fd3a4dcd', 'material', 10, 'Gram', 3.2, 12, null, null),
('18d19a00-e52b-47dc-b6be-46268b46fd70', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '9b16971d-d872-457b-836a-e359e6037a1e', 'material', 2, 'Piece', 1.2, 13, null, null),
('27647b99-7ad0-411f-a257-3eaf6718d993', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '5eddea1d-90d3-4f81-8eda-f8569ebc7042', 'material', 1, 'Piece', null, 14, null, null),
('aa977b25-cdf0-4b63-8f7a-ebdd444525fa', '0ab0e7db-1cbe-490d-85b6-41c31e333a05', '23dc6b59-218b-49fe-bab7-84bc5846681b', 'material', 5, 'Gram', 1.45, 15, null, null),
('468745cd-85c1-4ed3-9887-3294a3ffb872', '2248837c-b38f-4d33-a83c-523fdf156a09', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 0, null, null),
('01b5c766-51c0-47cb-a45a-7f64674dacc0', '2248837c-b38f-4d33-a83c-523fdf156a09', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 5, 'Gram', 0.71, 1, null, null),
('c0b2d82a-3899-49f6-8948-ffbb8b06ec35', '2248837c-b38f-4d33-a83c-523fdf156a09', '8de080ae-a902-47ae-aa9b-37e654126bbc', 'material', 40, 'Gram', 20.21, 2, null, null),
('cde19355-966e-427c-8068-f755521be968', '2248837c-b38f-4d33-a83c-523fdf156a09', '2a670104-1402-4889-9741-cb89c65d8da5', 'material', 220, 'Gram', 47.59, 3, null, null),
('14c8c795-d956-40f6-8dc7-faa04d0c8584', '2248837c-b38f-4d33-a83c-523fdf156a09', 'daa20a07-4fbd-4341-8ce0-5acecb968a7d', 'material', 140, 'Gram', 15.47, 4, null, null),
('6fc49e5b-cf0b-46f1-af05-f7a5dae59155', '2248837c-b38f-4d33-a83c-523fdf156a09', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 6.8, 'Gram', 0.19, 5, null, null),
('3da8729e-2f44-48e0-863c-5a73711e29ec', '2248837c-b38f-4d33-a83c-523fdf156a09', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('9f65e811-5e18-457b-8219-b1a9952b51c6', '2248837c-b38f-4d33-a83c-523fdf156a09', '99b5d2fe-bcd9-4d46-996d-96306493db7f', 'material', 1, 'Gram', 0.34, 7, null, null),
('bdb12fca-199c-4dec-8f05-dca26abfe4b2', '2248837c-b38f-4d33-a83c-523fdf156a09', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 3, 'Gram', 0.3, 8, null, null),
('ee42d96e-bb94-43d8-a493-4dc444638be0', '2248837c-b38f-4d33-a83c-523fdf156a09', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 7, 'Gram', 3.06, 9, null, null),
('b9d17948-ca10-419b-8c82-f35fc7d0db83', '2248837c-b38f-4d33-a83c-523fdf156a09', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 0, 'Gram', 0, 10, null, null),
('2e44af78-71ba-4aef-8e76-76c017561725', '7e96c3ae-24a2-4e95-839c-78779563d3d7', '0b37d616-a410-4231-80f9-f9d5c1861735', 'material', 120, 'Gram', 12.22, 0, null, null),
('185860e9-e548-4ce6-b874-fee0e0a17ed9', '7e96c3ae-24a2-4e95-839c-78779563d3d7', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 1, null, null),
('9c6391c4-650c-44de-8567-4897f64d587a', '7e96c3ae-24a2-4e95-839c-78779563d3d7', '3be12901-de36-4cf8-9eaf-285577602b5c', 'material', 10, 'Gram', 2, 2, null, null),
('dfaa05e7-c643-43ad-abbe-66d61c4b4380', '7e96c3ae-24a2-4e95-839c-78779563d3d7', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 5, 'Gram', 0.14, 3, null, null),
('a4217dfa-d1e2-4f59-8789-f33d0a602956', '7e96c3ae-24a2-4e95-839c-78779563d3d7', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('e14dd9b6-0701-42c5-8ae8-cdbf98e9b611', '7e96c3ae-24a2-4e95-839c-78779563d3d7', 'e618b770-1253-4119-8f5d-0976dbb90e88', 'material', 10, 'Gram', 2.24, 5, null, null),
('c9702358-8ec3-4c52-a2d3-c7201999a03b', '7e96c3ae-24a2-4e95-839c-78779563d3d7', '385f817c-8201-40f8-8eed-d54cd86359e1', 'material', 200, 'Gram', null, 6, null, null),
('a4539d31-fa69-45a6-a082-08c7f7e775e4', 'bba8259b-ab03-4e03-a5bc-def778debc21', '7fc21a37-0a2b-4f83-a082-a39f70c15719', 'material', 140, 'Gram', 13.72, 0, null, null),
('a1dc57eb-2db1-4846-ba93-97b45754b984', 'bba8259b-ab03-4e03-a5bc-def778debc21', '58cd06aa-2281-44e7-8e16-2025f82c3633', 'material', 190, 'Gram', null, 1, null, null),
('22c80da6-5890-41e6-a2ae-f1ff84e12efb', 'bba8259b-ab03-4e03-a5bc-def778debc21', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 2, null, null),
('a170f006-041b-47af-8baf-8b3df81e00f3', 'bba8259b-ab03-4e03-a5bc-def778debc21', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 5, 'Gram', 0.71, 3, null, null),
('2379292a-b575-4f1a-8ea3-ac4874a94c78', 'bba8259b-ab03-4e03-a5bc-def778debc21', 'fc81f4c7-68e6-481c-915c-2b0795799bec', 'material', 10, 'Gram', 0.23, 4, null, null),
('88b07926-a47f-48fd-834b-3a50d6104767', 'bba8259b-ab03-4e03-a5bc-def778debc21', '1e4841bc-dbde-46cf-9398-1a8e26e078c9', 'material', 1, 'Gram', 0.6, 5, null, null),
('67fe7e21-1e5f-4cbe-b4dd-fc5a1edbd6ec', 'bba8259b-ab03-4e03-a5bc-def778debc21', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 1, 'Gram', 0.29, 6, null, null),
('c82237ec-3098-4838-894b-3e614cd75163', 'bba8259b-ab03-4e03-a5bc-def778debc21', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 6, 'Gram', 0.17, 7, null, null),
('99a213a3-2a2f-4e37-8d42-bba90a27c35f', 'bba8259b-ab03-4e03-a5bc-def778debc21', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 1, 'Gram', 1, 8, null, null),
('ca547dc4-8709-4e18-a23d-acf5ad5fb732', 'bba8259b-ab03-4e03-a5bc-def778debc21', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 7, 'Gram', 3.06, 9, null, null),
('4c63e6e8-da39-4772-8e71-c77841dcfc22', 'bba8259b-ab03-4e03-a5bc-def778debc21', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 100, 'Gram', 0, 10, null, null),
('7e079bbb-10dd-4535-af09-b27555f1d0b3', '45d4738a-4d57-4949-b3a9-67d436403828', '62ef2d72-8d26-42f0-b5cf-12c681a1b0a5', 'material', 140, 'Gram', null, 0, null, null),
('6dd70e19-a3d0-4e84-bb76-274062c340f5', '45d4738a-4d57-4949-b3a9-67d436403828', 'a42cf520-68d6-4598-8b52-9e4374c916a8', 'material', 180, 'Gram', 43.69, 1, null, null),
('9cbb09ee-ed46-4602-a958-3b6335bec886', '45d4738a-4d57-4949-b3a9-67d436403828', '8fa6c44d-97a9-4a14-972b-ad8a8c8980eb', 'material', 60, 'Gram', 43.89, 2, null, null),
('1242947b-4cb4-4798-aaa4-180392ddecc5', '45d4738a-4d57-4949-b3a9-67d436403828', 'e265987e-5349-4b20-a540-66d1e06f61fb', 'material', 5, 'Gram', 0.49, 3, null, null),
('16532ce1-dea7-4e50-a471-58bc929de922', '45d4738a-4d57-4949-b3a9-67d436403828', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 18, 'Gram', 5.6, 4, null, null),
('b8a69004-bf94-4215-b124-6f7ab3fd0ad1', '45d4738a-4d57-4949-b3a9-67d436403828', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 5, null, null),
('20ea9198-db6d-420e-b2bf-8e42d811d0cb', '45d4738a-4d57-4949-b3a9-67d436403828', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 7, 'Gram', 3.06, 6, null, null),
('ca7cef12-0475-48aa-b000-ec13232fa23d', '45d4738a-4d57-4949-b3a9-67d436403828', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 0.5, 'Gram', 0.01, 7, null, null),
('9f9bb5eb-9a93-4976-85f2-aefc1a9577db', '45d4738a-4d57-4949-b3a9-67d436403828', '723b0dd7-4064-4f89-bfc8-c34b8157c24b', 'material', 2, 'Gram', 2, 8, null, null),
('d43e4aeb-6a8c-456d-a555-0d5f40a674e6', '45d4738a-4d57-4949-b3a9-67d436403828', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 2, 'Gram', 0.64, 9, null, null),
('749de37f-bf11-4c99-a2bf-9c5cab22c2e2', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '632f3ef7-5281-4f02-8a51-72e5babf70cb', 'material', 100, 'Gram', 36.75, 0, null, null),
('d741c9c1-3f47-4459-b339-0d416c88c96f', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'f313f2e5-d4b3-4e62-9386-7e20908a9026', 'material', 7, 'Gram', 6.46, 1, null, null),
('55b21f05-0f87-450b-9ef9-d02cd2bbd436', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '3ac2508a-ef18-43e1-85ff-b8695877c3ea', 'material', 8, 'Gram', null, 2, null, null),
('90777f82-2e03-440f-b432-dc28b2233aa9', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '58cd06aa-2281-44e7-8e16-2025f82c3633', 'material', 40, 'Gram', null, 3, null, null),
('eb06ccfd-64bd-4ffb-a5c1-3156ee1d23ec', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 5, 'Gram', 2.19, 4, null, null),
('6319ea83-c2f1-4aa3-b590-049f77a75cfd', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 5, 'Gram', 0.14, 5, null, null),
('c6c1b323-c8e5-4f83-91f3-89a3425518cf', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '723b0dd7-4064-4f89-bfc8-c34b8157c24b', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('c3b4c8f6-1113-44ce-98a4-e11b8a7b1711', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 5, 'Gram', 0.91, 7, null, null),
('a2a0b175-cd94-4ef9-91b2-bc2509141081', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 8, null, null),
('01fb08e9-1b46-4d7b-82bc-3331a0a253f0', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 5, 'Gram', 0.71, 9, null, null),
('16b3575a-76e0-42f3-8a7c-ce44f8e61f71', '34b7dbf8-4483-4611-941c-d0f20bbd99ca', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 100, 'Gram', 0, 10, null, null),
('6715b7dc-5c6c-40e6-b33e-b82d110c73ef', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'd68045f4-2796-4539-a572-2472c66b265e', 'material', 120, 'Gram', null, 0, null, null),
('72815231-fe82-4d7c-b576-286fd23fcf05', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '4045a6f1-b066-4934-96fd-dbcca0cf5949', 'material', 60, 'Gram', 1.65, 1, null, null),
('1f030eaa-caf7-4d5c-aa34-875e1634a321', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'e353198d-81f3-463d-8191-f47c05b7efda', 'material', 50, 'Gram', 2.53, 2, null, null),
('304b9d55-0aac-4ceb-9781-4e0eb66081db', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '8e529cde-d0c8-4eed-b1b5-3a4d1284ac45', 'material', 40, 'Gram', null, 3, null, null),
('a55db47d-2f9b-4632-9812-9decb88ea40f', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '599345fa-07b8-4dc4-b65f-d8a09f449270', 'material', 10, 'Gram', 0.23, 4, null, null),
('9b456fc9-1c03-4f92-ab64-45a2b58fdf3c', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '059e0386-7487-4901-92dd-545c8499e5e2', 'material', 400, 'Gram', 75.6, 5, null, null),
('3c048759-b893-4f6f-92f4-86090526d32c', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '12a568e0-7c71-4e81-82d8-8a3493d6247a', 'material', 20, 'Gram', 4.75, 6, null, null),
('5026a5ab-bb7f-43c2-ad47-e854f066f9bc', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 15, 'Gram', 15.75, 7, null, null),
('67e317a7-c47e-4308-82b6-b3c8db5a1a27', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 4, 'Gram', 0.11, 8, null, null),
('c3e129bd-f427-424e-af55-9fc777fbc255', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '723b0dd7-4064-4f89-bfc8-c34b8157c24b', 'material', 1, 'Gram', 1, 9, null, null),
('ca9d773a-2ef9-4c8e-a8e3-2c8bdf9ff3aa', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'cdbe7675-3fa4-43c8-a7aa-70ad0fb6b293', 'material', 2, 'Gram', 0.44, 10, null, null),
('2f14af13-4a2a-45da-beb9-9f256771b6c6', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 40, 'Gram', 21.52, 11, null, null),
('c504e132-bbda-4e7a-9aa6-9cfacea342f5', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'd33dd561-125e-4506-bc5a-49b504fd6e21', 'material', 40, 'Gram', 1.5, 12, null, null),
('9c88aee3-30b9-439f-9e67-b22070493cc0', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '708e9303-780e-4354-b975-a9d02064a919', 'material', 500, 'Gram', 38.35, 13, null, null),
('3d0ad6ce-7443-40d3-bb17-8aa96319c6a6', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 4, 'Gram', 0.11, 14, null, null),
('b0ddc2d3-4969-4443-a7ca-7d454200201e', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '603cce6b-e2d7-4056-b294-8e5d2ae04dc1', 'material', 0.5, 'Gram', null, 15, null, null),
('e119e031-a0d5-4743-a6e2-9ffce923d4db', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'd8c3bd66-a51e-4555-9b59-11f8452751db', 'material', 6, 'Piece', null, 16, null, null),
('909e1330-8314-4597-967c-2b94a4b5482b', '24028ee9-c979-4ca8-9062-a4f6283e00b3', 'b08e0b35-6074-45a9-9c4e-7016d7eaef4a', 'material', 200, 'Gram', 119.84, 17, null, null),
('9f7f9102-4e34-4b80-90fa-14df7e2a206a', '24028ee9-c979-4ca8-9062-a4f6283e00b3', '77ba00cd-b9d4-4f71-936c-06a1bb3692f6', 'material', 30, 'Gram', 40.51, 18, null, null),
('693b160c-44b6-464c-9da1-33269fe51ca3', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '79566a35-5a94-4dca-a1e8-f994cfdaf305', 'material', 250, 'Gram', 72, 0, null, null),
('92b0de35-46bb-4cb4-acee-50238b94e752', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 100, 'Gram', 88.4, 1, null, null),
('d1f7e0cb-d8ce-4f6f-b2ae-dcdf20305912', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '73bbda75-fff0-4ee9-a302-6f15117e90a3', 'material', 100, 'Gram', 35, 2, null, null),
('8d62b336-a874-4772-b0ae-0b58670abaff', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '6c871894-0e92-4f91-bc4c-ff051414c14a', 'material', 30, 'Gram', 11, 3, null, null),
('5a926f6c-8239-4c40-96c7-990eecfa5333', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 1, 'Gram', 0.03, 4, null, null),
('d1c1332d-0469-4df6-a137-78a4e8a95500', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '922147ba-8571-4471-bfd5-b82f6290b863', 'material', 1, 'Gram', 1, 5, null, null),
('8eb2e260-947f-4718-a76c-2f9deca67fcf', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '4a9f5bb6-57d5-4464-90c2-fb505bcbe10b', 'material', 5, 'Piece', null, 6, null, null),
('1f56cc6b-5dce-4fbb-bb7a-638b70b4e897', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '26c0a6c3-76f1-4687-80ea-e4cb95a4a93b', 'material', 150, 'Gram', null, 7, null, null),
('a61890f8-1748-46bb-afd6-9844bdc68226', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 10, 'Gram', 4.38, 8, null, null),
('c8cfaffb-ec34-46c7-85d4-574677cd2dd2', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '5fac1058-2167-4228-90f0-ebef4e23b763', 'material', 10, 'Gram', 3.13, 9, null, null),
('19c9abbb-caf1-4833-abdc-415c3391ed4f', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 5, 'Gram', 0.32, 10, null, 'Slit'),
('23fb72f2-bfe3-4b1a-8d3e-ced9da8c68aa', '0deaf679-eadf-4b6f-b2d3-9b44ea3368b9', '7939178b-36e6-4379-827b-92c9bc26a9c5', 'material', 5, 'Gram', 2.1, 11, null, null),
('61f84ce2-1272-4582-bae5-bba96f906eeb', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 10, 'Gram', 10.5, 0, null, null),
('44111a44-aa9c-4001-a525-3b7a35c17e91', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'fc81f4c7-68e6-481c-915c-2b0795799bec', 'material', 5, 'Gram', 0.11, 1, null, null),
('c67cec12-fe22-4609-a8a9-8cd29ef59297', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'c88f8e4d-d040-4eaa-8dc0-befccef05308', 'material', 60, 'Gram', 1.65, 2, null, null),
('0abc988d-6616-427b-9f4a-1f2c2a4ada22', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'ae2ce648-8f15-4fee-a593-987ede5b71ba', 'material', 60, 'ML', null, 3, null, null),
('60642818-c212-47da-91d0-49482ceba29e', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'abe2e836-2a41-4082-a91d-b69160f78103', 'material', 140, 'Gram', 33.81, 4, null, null),
('6c2ff79a-5277-467c-91ab-5997261958c1', '441f796d-167b-4ad0-bbf4-fbf0d696382b', '6cafa85c-fe4c-4719-bb5e-d25d879b880a', 'material', 4, 'Gram', null, 5, null, null),
('e7e666d2-edfe-4135-97b1-dcc08a0961db', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'e618b770-1253-4119-8f5d-0976dbb90e88', 'material', 80, 'Gram', 17.89, 6, null, null),
('652aad23-04f4-45f9-a897-b2f09a0beb9e', '441f796d-167b-4ad0-bbf4-fbf0d696382b', 'ad54c1c8-bc59-406f-bf7f-ede15073ccf1', 'material', 10, 'Gram', 2.61, 7, null, null),
('44f07640-7639-4a58-bdb9-d445d03fe2cb', '441f796d-167b-4ad0-bbf4-fbf0d696382b', '5e164e69-ec0f-46e6-9bdc-7c21abbaee35', 'material', 10, 'Gram', 1.6, 8, null, null),
('b1e8184f-3121-442e-8ad3-6d36991bb6de', '441f796d-167b-4ad0-bbf4-fbf0d696382b', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 10, 'Gram', 4.38, 9, null, null),
('cdcf62ed-2e7e-439f-987b-e70bba68d99a', '441f796d-167b-4ad0-bbf4-fbf0d696382b', '26d2baa1-2aa3-42c0-bef1-ed9d1f13f0ac', 'material', 1, 'Piece', 0.29, 10, null, null),
('d4698f0e-6151-4562-a819-fd41cc690e1c', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'c5e6d4ab-2a3f-4cca-9897-cc8c5db37d88', 'material', 30, 'Gram', 2.08, 0, null, 'Paste'),
('27ff496c-29db-498b-8da6-b76e309dee23', '5a57cbee-d08b-4687-9a3c-62042841edcd', '85df22fa-b59f-4b0d-a6b1-b094a04611f3', 'material', 120, 'Gram', 35.52, 1, null, null),
('3d0e5102-1beb-440f-ac33-ee647fc8348c', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'e3be30e0-d6d0-4a93-a362-3a321d358779', 'recipe', 50, 'Gram', 8.27, 2, null, null),
('0b391bbd-98d0-45df-8ecb-37a4f232d3c5', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 3, 'Gram', 0.09, 3, null, null),
('89f76fa0-7e8f-440b-8a52-b6058e6144d1', '5a57cbee-d08b-4687-9a3c-62042841edcd', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 1, 'Gram', 1, 4, null, null),
('4d0b0927-36f9-44aa-9b45-05c68cc06aac', '5a57cbee-d08b-4687-9a3c-62042841edcd', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 8, 'Gram', 3.5, 5, null, null),
('3a4a6e5d-0bf7-426a-9f68-273f7ff0341e', '5a57cbee-d08b-4687-9a3c-62042841edcd', '99b5d2fe-bcd9-4d46-996d-96306493db7f', 'material', 3, 'Gram', 1.02, 6, null, null),
('cd9e8b05-a2c7-4a15-9a3d-2d7c440cf2c1', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 7, null, null),
('ee0caacb-4c30-42f1-9f4f-c8da1e200c50', '5a57cbee-d08b-4687-9a3c-62042841edcd', '0bcdf9e6-9d67-43c8-95f9-013ddeaf93d8', 'material', 1, 'Piece', 0.79, 8, null, null),
('97e71fdd-48b8-4214-943b-404f48c7cfd5', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'a78ca4ec-1f59-48b7-9082-f4767bc948d8', 'material', 5, 'Gram', null, 9, null, null),
('7c5fe899-e600-419a-86c2-c2133eacb79e', '5a57cbee-d08b-4687-9a3c-62042841edcd', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 5, 'Gram', 5.25, 10, null, null),
('377e4a07-ef7a-4912-a226-f8ddfa612c7a', '5a57cbee-d08b-4687-9a3c-62042841edcd', '499e5b1f-8d77-4343-81d7-98795b81bc9d', 'material', 2, 'Gram', 2, 11, null, null),
('b834bff3-4978-4395-9b8c-a8906b8f84db', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 10, 'Gram', 10.5, 0, null, null),
('68d2fd0d-7b4b-4222-abf9-94bbc42f62b0', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 5, 'Gram', 0.91, 1, null, null),
('850a503c-fa8f-4875-909f-a42d21c42490', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 5, 'Gram', 0.14, 2, null, null),
('dce5b07a-d9a0-4f72-bd2e-a55752b12550', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '17f33ed0-202a-4cf8-93fa-690813b502a8', 'material', 90, 'Gram', 20.7, 3, null, null),
('2da571f1-75b2-4e6c-9e96-b79ae92729f8', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 50, 'ML', 0, 4, null, null),
('c693a281-58ec-457e-89d8-cb6f9ed5f9c1', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 3, 'Gram', 0.09, 5, null, null),
('8d9296c2-12f8-4ce0-ae67-ce7e939a74ec', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 2, 'Gram', 2, 6, null, null),
('5ba03977-c276-4095-8baa-bddf5dd6eb75', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '3173d0d9-4be1-4dc9-816f-1dcc6c865a2e', 'material', 100, 'Gram', 38.46, 7, null, null),
('6b7e61c3-9bcf-4547-9daf-906bdd69e639', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 10, 'Gram', 4.38, 8, null, null),
('b6ac36c8-7981-4026-ae39-5ae4672c2fe0', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 9, null, null),
('947ba87e-a1d1-47a5-9238-6f2b8c6d6a14', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '29d4daf7-dc95-4ef3-97dc-31a369f81f78', 'material', 5, 'Gram', 1, 10, null, null),
('7c852928-7ca0-4d74-ae08-785a391897ef', '86e939f3-8e2d-4e91-81e1-4067b54bce88', '77ac6ea5-e32f-4b2e-842e-1f008ba2ce5d', 'material', 5, 'Gram', null, 11, null, null),
('37b2feb8-a3aa-49e4-915a-fdcfc464bf76', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'bcb5708b-bd83-4b16-bb22-4a643ca547d9', 'material', 5, 'Piece', 2.31, 12, null, null),
('1c7ec814-202e-4f49-9a4a-fb54badd290c', '86e939f3-8e2d-4e91-81e1-4067b54bce88', 'e23a195f-5de5-48d3-af4b-1831b54625f4', 'material', 1, 'Gram', 1, 13, null, null),
('63852a0b-6961-4d08-8ac0-7ffb8a5ae7a7', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', '43123186-be8a-4e61-9edb-af53c2985cb8', 'material', 100, 'Gram', 10.49, 0, null, null),
('25e835e8-8b34-429e-bac0-7794809ae547', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'b1558d80-b3bc-4ee2-b780-cfc6efd026e7', 'material', 50, 'Gram', 5.63, 1, null, null),
('393e44f2-f466-4c43-82e9-60eb20cbd342', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 30, 'Gram', 22.42, 2, null, null),
('dec8377d-786b-453a-80e2-508790037533', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'a2b2b0b6-8d67-4d41-9042-5a275084ada8', 'material', 20, 'Gram', 11.98, 3, null, null),
('bb33794d-5bd8-4eeb-bc43-0c9bc9f6d048', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 3, 'Gram', 0.09, 4, null, null),
('b98741f7-7a76-443c-a197-07f6aca1bc96', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 1, 'Gram', 1, 5, null, null),
('931029a8-505e-4b19-ad7c-57733fa6c356', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 8, 'Gram', 3.5, 6, null, null),
('ff46d88d-33cf-47f0-a450-1bcf173122b0', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 20, 'Gram', 10.76, 7, null, null),
('ffce0251-9f17-4122-807c-e31a60ee2f9b', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 5, 'Gram', 3.74, 8, null, null),
('9e501373-952e-4b5d-b6ab-d5e30085b679', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'a2b2b0b6-8d67-4d41-9042-5a275084ada8', 'material', 5, 'Gram', 3, 9, null, null),
('760ea338-4041-4c8a-9263-efdd624ce453', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 5, 'Gram', 2.19, 10, null, null),
('73024678-5784-435d-9c99-84c7ca0f2531', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', '910522b2-9199-4fec-add4-296db690dd3f', 'material', 3, 'Gram', 16.95, 11, null, null),
('62d17728-bcfb-48af-88f9-869abdac42b5', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'df7f34a1-3625-4a1d-a55d-965d2bb5af53', 'material', 3, 'Gram', 50.01, 12, null, null),
('fcd782b3-4fe1-413e-bf04-4c6f2d967da1', '50598b63-3f25-4f7d-8c7c-5445f8070cc6', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 0.5, 'Piece', 0.04, 13, null, null),
('39e59d54-da15-4d35-8481-9835f24670a8', 'efbcb0a6-c42c-4658-af87-686299ab9963', '2658e044-d529-4bd9-aa0f-60073bd8d0fc', 'material', 105, 'Gram', null, 0, null, null),
('3d9a6d9b-481a-4598-bbc7-dde97ead33e0', 'efbcb0a6-c42c-4658-af87-686299ab9963', 'b671a804-2f5e-480a-bc85-82b6676789fe', 'material', 50, 'Gram', null, 1, null, null),
('67a5d068-1f43-4bb5-aa63-423211b341cf', 'efbcb0a6-c42c-4658-af87-686299ab9963', '3a7e9dd1-20ac-4dda-8d3e-36612274b62d', 'material', 60, 'Gram', 16.8, 2, null, null),
('ee2d68ca-f1ae-43ae-8e8b-313a7ad4a7a9', '5b233a70-b208-4de1-b1c9-dd25e2815e60', '64aa5ede-7b1c-4004-b0b4-05950b0fa592', 'material', 100, 'Gram', 65, 0, null, null),
('8f8baa80-d042-4913-b12e-782efbde2fd9', '5b233a70-b208-4de1-b1c9-dd25e2815e60', '787efd4c-aac1-4c92-a8a5-ed1ee350d20e', 'material', 60, 'Gram', null, 1, null, null),
('7d78b83c-61f7-4f44-898d-e7972061f21c', '5b233a70-b208-4de1-b1c9-dd25e2815e60', '901ca7b4-50ad-4749-8512-53bd19389a45', 'material', 20, 'Gram', 11.33, 2, null, null),
('a701b99b-b0cc-42ca-992f-5352584cc434', '5b233a70-b208-4de1-b1c9-dd25e2815e60', '0d9fb912-2f5a-42ba-91ab-2443e4884760', 'material', 5, 'Gram', 4, 3, null, null),
('cf7f532d-22ca-40f9-b00f-24d4c613d2df', '6525fd90-bb34-4f2c-8059-76cae55505aa', '99fed9a6-4819-4777-85e9-fbcb8ed759fe', 'material', 40, 'Gram', null, 0, null, null),
('9a503cc6-2893-4c82-8828-086f4419c244', '6525fd90-bb34-4f2c-8059-76cae55505aa', 'ee2295da-2d0c-4874-876e-181544aec616', 'material', 30, 'Gram', null, 1, null, null),
('d663f3e6-ab48-4c1b-af2b-84f4d814fd86', '6525fd90-bb34-4f2c-8059-76cae55505aa', 'e7d0454d-1648-463d-998f-4e2e8fc43e3f', 'material', 60, 'Gram', null, 2, null, null),
('38b8e0e7-2f31-46c4-b2d1-d06008133ec0', '6525fd90-bb34-4f2c-8059-76cae55505aa', '82d75fcc-356b-4f58-b44e-303f6e6c99d9', 'material', 10, 'Gram', null, 3, null, null),
('be38c739-9586-48da-b80c-8f6e032adc58', 'f94693e0-b945-4001-b6fb-383c2b6f13c3', '8083fe10-42ee-432d-93f8-2fffb8c0ab44', 'material', 40, 'Gram', null, 0, null, null),
('c4653ac2-05de-42b1-822c-7361d567dcb3', 'f94693e0-b945-4001-b6fb-383c2b6f13c3', 'f3f4f6e7-ad66-4059-98aa-224e128671c2', 'material', 40, 'Gram', 33.04, 1, null, null),
('7af57c90-f386-4ef5-8f3d-4d80b73d066c', 'f94693e0-b945-4001-b6fb-383c2b6f13c3', '791fd585-22fc-45ac-b636-f8b9153dad11', 'material', 20, 'Gram', 15, 2, null, null),
('2c9bda07-fbb3-4041-a63d-091b70b1c397', 'f94693e0-b945-4001-b6fb-383c2b6f13c3', '643f90b8-c19f-40e1-a0e1-d445b1d17371', 'material', 10, 'Gram', 2.14, 3, null, null),
('ce1e45e0-7e16-4e10-a668-ef5b97d9c17b', 'f94693e0-b945-4001-b6fb-383c2b6f13c3', '454a1c88-ce4c-4504-af1c-1533c678dd33', 'material', 5, 'Gram', null, 4, null, null),
('0c8de5aa-1c55-4527-bc02-199cffb0b02f', '6204b4a6-08a7-4508-9c8d-5593e2b63c20', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 30, 'ML', 9.33, 0, null, null),
('2f05c690-b5e8-4bc4-9678-4e75007d14c6', '6204b4a6-08a7-4508-9c8d-5593e2b63c20', 'd38d4d26-586e-48a4-97c8-f90bbd3fca87', 'material', 60, 'ML', 1.64, 1, null, null),
('93778971-9130-4550-bebd-64a166d46df5', '6204b4a6-08a7-4508-9c8d-5593e2b63c20', '8520c252-0641-49c6-a01c-d13ad47a37c6', 'material', 210, 'ML', null, 2, null, null),
('28aefa05-ad1a-4578-8169-a1e8034b5d08', 'e9296c04-3317-49d0-9442-9b5b89e5868a', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 30, 'ML', 9.33, 0, null, null),
('2c8d1086-5372-48f0-81ad-a56ffa15fc72', 'e9296c04-3317-49d0-9442-9b5b89e5868a', 'f32e47e8-144f-4ed6-93ff-519de183336d', 'material', 15, 'ML', 0.5, 1, null, null),
('550d8408-3e09-459b-925e-d082aea40539', 'e9296c04-3317-49d0-9442-9b5b89e5868a', 'aa823717-5177-4a89-b16e-74aa769a699a', 'material', 200, 'ML', null, 2, null, null),
('195bba7a-1940-4d52-bbee-4fdd9e64b5e9', '198725b3-80a5-440c-9e3d-16e8b44c9d8e', '6b1d716c-365c-4da8-b3bf-40b3e1e639e8', 'material', 60, 'ML', 19.44, 0, null, null),
('1aff4d7b-2cee-45d4-a7b4-a6a3dbb958c2', '198725b3-80a5-440c-9e3d-16e8b44c9d8e', '31c6c2e1-0c0a-452d-b65d-b315579c2bc8', 'material', 60, 'ML', 4.51, 1, null, null),
('04e6b87e-f8f0-4e3e-b9f6-1538ae33b650', '198725b3-80a5-440c-9e3d-16e8b44c9d8e', 'a6df6362-3b92-4827-86b9-67d5d64d67c0', 'material', 120, 'Gram', 16.5, 2, null, null),
('ffc3f1fa-2823-4bd6-8e7d-72f87b78b7a3', '198725b3-80a5-440c-9e3d-16e8b44c9d8e', '0689ecdf-9809-49ba-ba01-e0ed1cad008c', 'material', 1, 'Piece', 0.19, 3, null, null),
('aa730dd7-0e35-4b7c-8aa7-148e3f42e83b', '198725b3-80a5-440c-9e3d-16e8b44c9d8e', '25f5785e-4294-4ea6-b31e-dd664f913098', 'material', 60, 'Gram', 0, 4, null, null),
('e7a38420-4801-43c9-8a3d-f24ca6ace2ac', '7a45ed41-2aa3-4e12-9eff-119adf3dc945', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 30, 'ML', 9.33, 0, null, null),
('a58cb248-1db6-46c8-ab98-3e5d12a649b0', '7a45ed41-2aa3-4e12-9eff-119adf3dc945', '285298e0-0e5f-47fe-a4e6-c3aab2e48ea1', 'material', 1, 'Piece', 0.13, 1, null, null),
('d1c366bd-e6ac-42d6-83fd-042114d95aeb', '7a45ed41-2aa3-4e12-9eff-119adf3dc945', '0a8c0872-65c6-4fe1-ac8e-1cbdf32db2f6', 'material', 292.5, 'ML', null, 2, null, null),
('570152a2-0407-492d-8e99-d501e5a0d4f9', 'e6026727-d92b-41f5-942d-de37bdeb80c8', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 15, 'ML', 4.67, 0, null, null),
('989f65c7-618d-40ac-bd1c-17542b5bef6d', 'e6026727-d92b-41f5-942d-de37bdeb80c8', 'de230c6b-26e4-4575-a7f4-54ded1a9ed09', 'material', 60, 'ML', 24.3, 1, null, null),
('cc859913-abbf-46fb-99cd-cdd8b3e1e17f', 'e6026727-d92b-41f5-942d-de37bdeb80c8', 'd01a85c1-f046-47b6-b70e-d37d9d8b2c32', 'material', 15, 'ML', 1, 2, null, null),
('1f5b1b4b-31cf-4581-835f-fa61ab26e924', 'e6026727-d92b-41f5-942d-de37bdeb80c8', '0c228ffb-0b47-42c6-aec0-dbeccfaa09f3', 'material', 140, 'ML', 14.62, 3, null, null),
('fa739159-4592-43d7-a75e-4dfd5690eb6c', '198fc4ff-a988-4d4c-b71b-adf7dc7f05b8', '1969f303-ef00-4c74-9f78-932bce453f27', 'material', 45, 'ML', null, 0, null, null),
('4d15f5ee-a9bb-4c4e-b788-ba1e16890639', '198fc4ff-a988-4d4c-b71b-adf7dc7f05b8', '9796c879-73a8-49ed-be46-9b31665fa0b1', 'material', 1, 'Piece', 0.03, 1, null, null),
('1d25abb1-49f2-4b2b-8bb0-5bbd6d8fff0d', '198fc4ff-a988-4d4c-b71b-adf7dc7f05b8', '15cd32dd-88cf-40d6-bf6b-fd565a9beae5', 'material', 170, 'ML', 28.34, 2, null, null),
('c6f05e90-4717-4111-918a-cb5f12a9b9e7', 'ce827899-ab69-4880-b550-43bcd2f8976b', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 18, 'Gram', 19.14, 0, null, null),
('a8302a15-5b4d-42e6-ad7c-cab608abde15', 'ce827899-ab69-4880-b550-43bcd2f8976b', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 40, 'Gram', 1.1, 1, null, null),
('0e49e023-fc5c-420d-96a7-eab6e310feae', 'ce827899-ab69-4880-b550-43bcd2f8976b', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 15, 'Gram', 2.73, 2, null, null),
('70954eaf-4a95-4338-a4af-b04ef8e04b50', 'ce827899-ab69-4880-b550-43bcd2f8976b', '2e5ccccc-d8e7-42a2-b068-4580f8cf2e2d', 'material', 15, 'Gram', 17.32, 3, null, null),
('a0de501c-beeb-46de-a833-91a04ed0d15c', 'ce827899-ab69-4880-b550-43bcd2f8976b', '32a4075d-07a3-4fe6-837c-e53c85a38fc6', 'material', 60, 'Gram', 14.4, 4, null, null),
('25c288c2-3abe-4d80-bd02-4a040a1e21b6', 'ce827899-ab69-4880-b550-43bcd2f8976b', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 60, 'ML', 0, 5, null, null),
('d405cbc1-a19b-4488-800c-2c50afd0e920', 'ce827899-ab69-4880-b550-43bcd2f8976b', 'd9c2a6bc-4456-48b3-939e-1cb76c6495cd', 'material', 60, 'ML', 2.53, 6, null, null),
('2c239844-7462-49b4-ad40-83795dceaca9', 'ce827899-ab69-4880-b550-43bcd2f8976b', '727cbb5d-7771-49b9-be5d-4d6abba0d73d', 'material', 50, 'Gram', 4.1, 7, null, null),
('40055ed5-9ce1-43c6-9683-ae761f4e3b35', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', '2d116a0b-9792-42e6-8296-fa202aa0c361', 'material', 13.75, 'Gram', 10.92, 0, null, null),
('724afe80-cca6-4dbb-9f49-d203bf8b5512', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'fcd9c060-20db-492b-9691-40653cd704c5', 'material', 120, 'Gram', null, 1, null, null),
('7e94d408-e2e1-4af7-a112-6ec70a6a281f', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'd04206c0-3a6a-4b58-bf49-b6bb4581de01', 'material', 30, 'Gram', null, 2, null, null),
('ddb229f5-b4de-4617-88d4-4b065eb5b3d4', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', '8ff69d00-5cd5-4f7c-8cf9-9ad89ec76702', 'material', 4, 'Gram', 0.29, 3, null, null),
('263131e1-e62d-4852-a8cf-3a87a9cd38fe', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'daedd997-1ac7-4b39-8f7e-19a64bad6300', 'material', 4, 'Gram', 0.3, 4, null, null),
('255a252f-8463-450e-9c39-d9071f73f167', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 15, 'Gram', 4.2, 5, null, null),
('1bef3a99-28f7-4681-83ee-61caa9310e1f', '38e21461-b7ac-4c67-ae12-8d8a325d1f7f', 'fcfe6c93-7341-4d7e-8f9d-e494f70c294c', 'material', 10, 'Gram', null, 6, null, null),
('50548271-c9cf-4c07-83be-d88d15944cbd', '687098bf-eef1-4661-97b2-dde78115de40', '78e2994a-561d-4784-a307-6a0b1c491687', 'material', 50, 'Gram', 9.38, 0, null, null),
('26eb4013-dcfa-4e8e-bf4a-d665a0de7789', '687098bf-eef1-4661-97b2-dde78115de40', 'ea885e38-77f7-4f76-861a-9e8cd10c94ca', 'material', 30, 'Gram', null, 1, null, null),
('5e5a25af-8a67-45b5-bdaa-33f23a763369', '687098bf-eef1-4661-97b2-dde78115de40', '8e941bf1-7115-4d94-a15b-e6dbc85c5354', 'material', 15, 'Gram', 1.78, 2, null, null),
('29c44c99-f94a-4cd0-a608-0da218b65024', '687098bf-eef1-4661-97b2-dde78115de40', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 20, 'Gram', 0.55, 3, null, null),
('5a080657-2f59-4b23-854d-99857c379fb6', '687098bf-eef1-4661-97b2-dde78115de40', '33728a74-16c5-46f1-bc23-da7deb4a007c', 'material', 20, 'Gram', 1.74, 4, null, null),
('3fd91c63-8a06-42fa-9f00-bb7b8e7d954d', '687098bf-eef1-4661-97b2-dde78115de40', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 10, 'Gram', 0.75, 5, null, null),
('8dd2acdc-2957-4e28-97f0-fc905a15474f', '687098bf-eef1-4661-97b2-dde78115de40', 'f89dd080-0e8d-4b5b-ad03-95c4cb076f0a', 'material', 6, 'Gram', 6.38, 6, null, null),
('0d715b3c-0d42-4e13-b8f8-807814a24159', '687098bf-eef1-4661-97b2-dde78115de40', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 7, null, null),
('b57b56b8-2acd-4c63-8b69-c9ae5ea96c88', '687098bf-eef1-4661-97b2-dde78115de40', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 8, null, null),
('6625f295-d3db-4ab6-a2bb-f900fb5bc277', '5a044da4-abf7-4387-a393-13e36ab7f7df', '849761fa-3b61-47bd-a415-318a8130d611', 'material', 75, 'Gram', null, 0, null, null),
('d8c1389f-0fe4-4b2e-84b6-18c33f083c80', '5a044da4-abf7-4387-a393-13e36ab7f7df', 'fee655aa-7aba-421c-bd88-d1e70f3b0fa1', 'material', 5, 'Piece', 3.25, 1, null, null),
('febb4a14-9e98-4ae0-8d11-459ee4c4b699', '5a044da4-abf7-4387-a393-13e36ab7f7df', '5df892d8-2ec4-4f00-8acc-5c1949da52b3', 'material', 1, 'Gram', 0.1, 2, null, null),
('ca853c84-ff2f-450a-9afd-72deb233a541', '5a044da4-abf7-4387-a393-13e36ab7f7df', '4999fdbd-4ccc-4cdc-a0d0-d01f0ca6e8a5', 'material', 15, 'Gram', null, 3, null, null),
('a7605821-3e6e-4d1f-aa27-b74a67ab7dfe', '5a044da4-abf7-4387-a393-13e36ab7f7df', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 5, 'Gram', 0.36, 4, null, null),
('752c1b92-e0d1-49af-a32f-d09a7bcf76cd', '5a044da4-abf7-4387-a393-13e36ab7f7df', '7a9a1c16-9104-4d8c-9a33-26be71e63279', 'material', 0, 'Gram', 0, 5, null, null),
('6e0f2f77-2518-49b8-beff-e190f771c0c0', 'b88ed338-6761-420a-8eb8-0c479396b965', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 15, 'ML', 0, 0, null, null),
('e85a9b03-11b6-4913-b174-f7023dc52ac7', 'b88ed338-6761-420a-8eb8-0c479396b965', '0053d9ff-de13-4fd7-abe1-fd77eb3101db', 'material', 133.33, 'Gram', 74.66, 1, null, null),
('cf067638-c873-4e0c-aeff-17c782808413', 'b88ed338-6761-420a-8eb8-0c479396b965', '80b82054-54e6-4c97-a19f-b890dc54b57a', 'material', 30, 'Gram', null, 2, null, null),
('4a2a06a0-4c3b-4608-af1d-cb5cb5260774', 'b88ed338-6761-420a-8eb8-0c479396b965', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 0.3, 'Gram', 0.01, 3, null, null),
('7096387a-0368-465d-8c05-22b51c5a08fd', 'b88ed338-6761-420a-8eb8-0c479396b965', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 1, 'Gram', 0.33, 4, null, null),
('bdde3347-fa20-4289-9aa1-6c1a856fbd53', 'b88ed338-6761-420a-8eb8-0c479396b965', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 0.5, 'Gram', 0.05, 5, null, null),
('5e522721-c74e-4c43-9f28-d40706615c63', 'b88ed338-6761-420a-8eb8-0c479396b965', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 2, 'Gram', 0.15, 6, null, null),
('64b5fae1-ab20-46aa-a28a-605eb929459d', 'b88ed338-6761-420a-8eb8-0c479396b965', 'dbc1007b-0325-47fd-bf17-92289758a28d', 'material', 1, 'Gram', 0.2, 7, null, null),
('23101bd3-9ebe-4185-97ce-3b4f73a2ab31', 'b88ed338-6761-420a-8eb8-0c479396b965', 'f34a2e72-6fd6-498c-b2fe-be56a35f2f8f', 'material', 2, 'Gram', 0.15, 8, null, null),
('09cd7987-2b4a-4cfc-bb7b-4dce59e41f61', '51d00100-0628-4012-bbac-f2e34bb1f98c', '980992d7-7b00-44f3-8683-585a7e559643', 'material', 70, 'Gram', null, 0, null, null),
('84597ccc-36d3-45d7-a9e9-36b9b11871b5', '51d00100-0628-4012-bbac-f2e34bb1f98c', '93bdc872-1d15-4343-b779-6efd9763be6f', 'material', 50, 'Gram', 13, 1, null, null),
('d1bd31e4-9a31-4a16-807c-b199dc184a6c', '51d00100-0628-4012-bbac-f2e34bb1f98c', 'eef51443-abe5-49e3-809a-57dccc4cf8cb', 'material', 20, 'Gram', null, 2, null, null),
('06436391-8dd9-49e1-a16e-1f926d4f56bb', '51d00100-0628-4012-bbac-f2e34bb1f98c', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 10, 'Gram', 0.53, 3, null, null),
('e54c465a-3217-4b13-9de6-6e1b618c6b36', '51d00100-0628-4012-bbac-f2e34bb1f98c', '282ac16c-b3fd-4b60-95bb-c6ff3d1b1064', 'material', 50, 'Gram', null, 4, null, null),
('c0949bf9-475c-442d-a67e-419d1f5e1600', '51d00100-0628-4012-bbac-f2e34bb1f98c', '0f246713-d43c-43df-bfb5-2b68bf4bd3ac', 'material', 3, 'Gram', 0.57, 5, null, null),
('b654b5a5-f179-4651-b4ff-3d759f91795e', '51d00100-0628-4012-bbac-f2e34bb1f98c', '3e5ce90e-9c6d-4ae4-bbfb-ac43e905ae05', 'material', 20, 'Gram', null, 6, null, null),
('28c8000a-e2f2-49b5-9717-9c032579e44d', '2101726a-4d9f-4c64-9768-39bf8bdab625', '972a61db-ddee-42ae-8e98-35db7fbba6b0', 'material', 190, 'Gram', 48.59, 0, null, null),
('51e18a6c-78f0-42f4-ac63-e45b5f0c784d', '2101726a-4d9f-4c64-9768-39bf8bdab625', '8077e339-baeb-4b80-85c5-f1f52181d7d5', 'material', 20, 'Gram', null, 1, null, null),
('c4c66005-960f-433c-9e0b-3843a95c5b51', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'af145b47-68bb-4613-9080-a05b0ba749fa', 'material', 5, 'Gram', null, 2, null, null),
('2247c1ba-fb50-45d9-b905-67f1a4d02c0c', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'ecd30dcf-c907-4ea8-91ee-2e4d5b6fb807', 'material', 15, 'Gram', 2.49, 3, null, null),
('6a9f2b32-e8ac-423d-bcb0-e2aa3ad4d727', '2101726a-4d9f-4c64-9768-39bf8bdab625', '0024c03b-1b96-49d4-b50e-61e8cc6f7ec3', 'material', 15, 'Gram', 2.71, 4, null, null),
('686c0dd7-f780-4620-a23d-cf081a9b6ba5', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 20, 'Gram', 0.55, 5, null, null),
('ed0f01a0-26c2-48ef-8d4a-d3605108a5b7', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 15, 'Gram', 1.13, 6, null, null),
('02c985de-9342-4ba6-aba6-8f5dc904dc60', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'f89dd080-0e8d-4b5b-ad03-95c4cb076f0a', 'material', 5, 'Gram', 5.32, 7, null, null),
('ccd08fbb-36eb-4901-bf1a-50891aace300', '2101726a-4d9f-4c64-9768-39bf8bdab625', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 3, 'Gram', 0.96, 8, null, null),
('e6d3dbe5-1ce3-4ca9-90b6-25a9250a26d7', '2101726a-4d9f-4c64-9768-39bf8bdab625', 'fc81f4c7-68e6-481c-915c-2b0795799bec', 'material', 5, 'Gram', 0.11, 9, null, null),
('83012797-704d-4bdf-832e-162f6605ba6c', '2101726a-4d9f-4c64-9768-39bf8bdab625', '359ee41a-ec5f-40e6-a826-54a90998643f', 'material', 15, 'Gram', null, 10, null, null),
('449e4190-88a7-40d1-bc8e-797a428dcea2', '2101726a-4d9f-4c64-9768-39bf8bdab625', '3bf5702b-2eab-4038-84d1-8b16f09d771f', 'material', 10, 'Gram', 7.94, 11, null, null),
('b5c8e961-432e-431e-a2ed-734077da3fc4', '413c18c8-2b82-485a-a903-1392aed4caa5', '969a15eb-5008-415f-84a5-aab37e0bde6c', 'material', 160, 'Gram', 72, 0, null, null),
('71894481-39d1-4ad3-8f8f-3929a4023071', '413c18c8-2b82-485a-a903-1392aed4caa5', '326ab281-4ab3-40fc-9aaf-922ca7b51586', 'material', 12, 'Gram', null, 1, null, null),
('571f18ac-ef55-4279-934e-82e5d24a0e92', '413c18c8-2b82-485a-a903-1392aed4caa5', '505ff761-dd0a-4b88-8ae1-b5b970134300', 'material', 4, 'Gram', 0.11, 2, null, null),
('c1b6d482-6383-485a-ab8e-86993ac50ad7', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', '7c58f2e8-5481-4d77-bbc1-9beb7a16e7e9', 'material', 75, 'Gram', null, 0, null, null),
('ca29905e-d432-4bdb-9f76-7313b7423f18', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', 'fee655aa-7aba-421c-bd88-d1e70f3b0fa1', 'material', 5, 'Gram', 3.25, 1, null, null),
('ab04d77b-405f-4e7a-a863-0c4f8ac14461', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', 'cd52d448-e2cf-4d5d-8739-5848298cfe06', 'material', 10, 'Gram', 3.33, 2, null, null),
('0cbcc62f-07c1-4bf9-aea9-9526d70e6c45', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', 'b79350c9-a912-442e-9cf4-4166eaedd738', 'material', 10, 'Gram', 1, 3, null, null),
('39b8df7d-db71-4846-8692-6bab1a970a09', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', 'ff7c87bb-94d1-4086-b0d0-157e31a43cb2', 'material', 5, 'Gram', 0.95, 4, null, null),
('1756381a-a988-40c9-9bda-368de3028df5', '345dbf87-090f-4a11-8f76-c6a2ce1ff35d', '64bc3823-2edd-4deb-950b-6a3baca76dbb', 'material', 1, 'Gram', null, 5, null, null),
('180b990d-053b-4f03-a9d9-563c8f742cc6', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'f1e31970-c8c8-4071-b079-6c0eefee2ea7', 'material', 150, 'Gram', 15, 0, null, null),
('e5587a6f-fa75-4237-bba7-d767bfc71c16', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '413cf6bf-80be-4966-9d65-f0b0d0820bfd', 'material', 80, 'Gram', null, 1, null, null),
('7a43df77-1f11-4661-9d2e-027f6805592c', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 10, 'Gram', 0, 2, null, null),
('224dd65c-86b8-4c5e-8f38-e1af9f4e151b', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'd4b17a33-825d-4e3f-a662-3ce8ddfcf07c', 'material', 1, 'Gram', 0.27, 3, null, null),
('de490571-be4e-4a35-b8b2-3e111ff2eb2a', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 1, 'Gram', 0.09, 4, null, 'Chopped'),
('cbf5f930-adce-4293-9c63-99686e13428b', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '833614b9-814e-4b5a-a8bc-e892c08a21b7', 'material', 2, 'Gram', 0.21, 5, null, null),
('3356594d-5f49-4b2e-98a4-9f1ce4eaa93a', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'e1c1db55-10eb-46a9-a8ae-0b0ef5766455', 'material', 40, 'Gram', 3.4, 6, null, null),
('7c6b3931-1235-4c9c-aef6-87eef1b39719', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '765a7709-0f4f-469f-b052-79a81e955a7b', 'material', 20, 'Gram', null, 7, null, null),
('f5e1753b-9c52-4b2b-8e7f-dbbc316f8783', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 10, 'Gram', 8.84, 8, null, null),
('adf6d1d2-b528-491f-99f7-81422c46184d', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'fb7833c3-61c6-49d2-9658-2c06cb7f6cb1', 'material', 5, 'Gram', 1.66, 9, null, null),
('bc96a062-2b02-4f95-bbc4-f5fdcab06c8f', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 3, 'Gram', 0.93, 10, null, null),
('cc29fb07-65bd-4716-bc7b-e976ca6e2af5', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'b71b149e-1531-474d-bd70-7b0e6ed178ca', 'material', 1, 'Gram', 0.02, 11, null, null),
('be48135a-c203-4900-afa3-f6b0bd1d97c9', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 0.5, 'Gram', 0.01, 12, null, null),
('a77a9b59-15df-40ef-8666-81a15d074fe3', '7dd7b3e8-0748-4849-9962-2b18f260f0cb', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('0c0d6723-ed9e-4d49-ac25-13592b926bf7', '2a14daae-fe29-49b3-b59c-c95c7a16b831', 'a40de1bf-feee-43d6-851a-9294c3f97d95', 'material', 30, 'Gram', 3.14, 0, null, null),
('56c52114-dfc5-439d-b139-609f3f176a4b', '2a14daae-fe29-49b3-b59c-c95c7a16b831', '9ce413a7-7b68-4c4b-87f0-c92fe1f4809f', 'material', 180, 'Gram', null, 1, null, null),
('5996d3df-6190-4312-bedd-4d4419056f51', '2a14daae-fe29-49b3-b59c-c95c7a16b831', '75c05c6b-c1da-4237-bd3d-e362797148ea', 'material', 5, 'Gram', null, 2, null, null),
('d9973b5b-7ede-40e3-b42c-efbd096b3bc3', '2a14daae-fe29-49b3-b59c-c95c7a16b831', '01c24506-5671-446e-bb48-215fd5ad6367', 'material', 20, 'Gram', null, 3, null, null),
('fb7d3981-d047-412d-b997-dcde53709055', '2a14daae-fe29-49b3-b59c-c95c7a16b831', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 20, 'Gram', 5.6, 4, null, null),
('5a577875-3df1-411d-b590-5237f4856db4', '2a14daae-fe29-49b3-b59c-c95c7a16b831', '25a4e1a3-aa13-4c44-9968-5b033740feba', 'material', 10, 'Gram', null, 5, null, null),
('41dc67c3-480b-4f17-a6cc-3cc271da01d5', '2a14daae-fe29-49b3-b59c-c95c7a16b831', 'ff7c87bb-94d1-4086-b0d0-157e31a43cb2', 'material', 2, 'Gram', 0.38, 6, null, null),
('b2225caa-1f9d-408c-8312-17f9a26d984a', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '50ff9915-1a8b-4d52-b15b-d425e7fd8016', 'material', 140, 'Gram', 67.53, 0, null, null),
('7c40e689-2394-4719-8a7f-fc31f1f1a6d7', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '8f345b52-fa9f-4e63-a7ca-1bfbc278aa82', 'material', 50, 'Gram', null, 1, null, null),
('3cb52ba0-e68a-4ca3-a64c-c318bffa046f', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '67a8e07c-4725-4413-a193-afbbfb694785', 'material', 15, 'Gram', 0.79, 2, null, null),
('a71e5f1b-497b-44ad-ab8a-671faa4d01dc', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '32ccb047-1556-45f3-9dfa-f858c6e036ea', 'material', 15, 'Gram', 0.76, 3, null, null),
('0c4e9bea-d5eb-4a54-979b-0d3105535b1c', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '031bcdab-9e95-40ce-a6a6-eb0f3c4bdb85', 'material', 5, 'Gram', 0.95, 4, null, null),
('4fc4d562-d171-4145-83f2-a1ddb2cf7348', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', 'c8224a81-9b9d-476f-bccf-31c3e465d93b', 'material', 10, 'Gram', 1.92, 5, null, null),
('76bb7030-46fc-4900-af01-20e2e19484c8', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '81693002-e778-4c45-93aa-977bd955e851', 'material', 10, 'Gram', 0.75, 6, null, null),
('0e7a1663-0b42-440a-8f4d-ac024d56f0f8', 'ab0c2166-13e1-46b9-a206-bc125ba9dff8', '28435716-99e7-46a8-8e40-43537c36c5d9', 'material', 15, 'Gram', 2.69, 7, null, null),
('6e27b0d5-e88e-424c-a2a6-44b70c9d9adc', 'dc93a1f6-1250-484a-99ce-433ee63c772f', 'cf5ca19e-c3cb-43ac-92be-eb19c6e8b7e3', 'material', 1125, 'Gram', 133.92, 0, null, null),
('7c1a3934-205d-47ec-96f2-6392a71191d8', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '60f35741-2d05-4340-ae21-2863ef66a2de', 'material', 550, 'Gram', null, 1, null, null),
('577eaadf-0bd3-4ff2-b2c8-c75fbcb357a6', 'dc93a1f6-1250-484a-99ce-433ee63c772f', 'd6041058-3ee7-4760-86d2-27b124697557', 'material', 3, 'Gram', 1.13, 2, null, null),
('380b63b7-1737-4ae1-bcec-dfbdce0b43c0', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '12b73052-b8d6-4bc4-959d-fa6ea314fad5', 'material', 2625, 'Gram', 314.21, 3, null, null),
('1728832a-5544-4757-a666-dee5c5246fc0', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '33ec776a-dc7f-44eb-bc39-ea423e4941b1', 'material', 1900, 'Gram', null, 4, null, null),
('ae39c65f-1420-42ed-af5a-90c6d9115da6', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '98e5ddec-edf8-4a2c-942c-9e497c2ae555', 'material', 5, 'Gram', 1.89, 5, null, null),
('b5600904-7c52-4e16-b240-8804df1fa070', 'dc93a1f6-1250-484a-99ce-433ee63c772f', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 90, 'Gram', 2.56, 6, null, null),
('4a739c32-3524-4d1b-a04c-4cd0cd96f2ce', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '1e04f846-2ea6-4a1d-99ba-927f4bcd1940', 'material', 50, 'Gram', 55, 7, null, null),
('0f0d163d-58a7-4618-ac1a-6c1395c17d49', 'dc93a1f6-1250-484a-99ce-433ee63c772f', '727cbb5d-7771-49b9-be5d-4d6abba0d73d', 'material', 25, 'Gram', 2.05, 8, null, null),
('8ea11cff-40d7-4d6b-b118-e21743045ebb', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '1802261a-db8f-48a5-9513-faa853968edd', 'material', 150, 'Gram', 172.5, 0, null, null),
('b84d20d0-a5d4-4676-be3a-45d76a99a14c', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '93bdc872-1d15-4343-b779-6efd9763be6f', 'material', 100, 'Gram', 26, 1, null, null),
('5a7274ad-0c0f-4d16-a249-4b744b733b26', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', 'b8192aac-7dea-4e6d-9d2f-def25e6140e9', 'material', 20, 'Gram', 0.62, 2, null, null),
('178d3a87-c3c7-40a3-a3fc-cd5f41b999c3', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 10, 'Gram', 0.53, 3, null, null),
('590b51f3-4402-49cb-995d-9445833b5bf2', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', 'de8c0f22-f06d-4964-b13b-bce0e2bbccad', 'material', 3, 'Gram', 3.78, 4, null, null),
('f5361aca-6a4b-4318-b05c-245f0a8b8dcd', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '22e20e53-0cc7-43be-8709-2d5f66beb9db', 'material', 5, 'Gram', 1.45, 5, null, null),
('67c33878-f263-40af-8bb3-86444c657bb2', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', 'd9459cad-2769-4893-b009-6927d9e05b0f', 'material', 180, 'Gram', 37.8, 6, null, null),
('837180b8-03da-46fb-99a8-9e358bf4d65f', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '0acf8f6a-15a0-431c-8a22-caec195c7fc8', 'material', 3, 'Gram', null, 7, null, null),
('e290520f-404a-473c-8612-ff40ce89698e', 'ab56ab02-026a-44f5-b0b2-0d770036d2d6', '1395fab5-154f-488f-b06c-42e091760451', 'material', 10, 'Gram', 3, 8, null, null),
('9093baf8-d60c-4e22-8379-43572ef68027', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'e5a909f3-f5fd-493a-bd59-769c6bd83cc3', 'material', 30, 'Gram', 5.16, 0, null, null),
('d37230c5-1477-471d-a016-5d8a78f58bfb', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '120d4ad3-085f-4483-877a-7d2d31e49ba0', 'material', 30, 'Gram', 4.12, 1, null, null),
('84f6bf6d-adf1-4786-b0a0-9e41e6624d2d', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '33728a74-16c5-46f1-bc23-da7deb4a007c', 'material', 30, 'Gram', 2.62, 2, null, null),
('a0bc93ad-54ba-4bf2-9536-0d204dc451cf', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'bdb4d501-b297-49db-816c-baf2c666a7eb', 'material', 30, 'Gram', 8.4, 3, null, null),
('adb346d6-2337-4d09-a6d0-4be9ca64e189', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '994923b7-187b-49ee-a903-db2075ba4520', 'material', 40, 'Gram', null, 4, null, null),
('e5111227-ead0-4b71-9b9d-407c045e3a90', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'f4136be6-5d6f-47e3-be1b-5a31285afaf7', 'material', 200, 'Gram', 53.34, 5, null, null),
('97029c92-97f5-49c3-8198-cf3c4eab495e', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 30, 'Gram', 0, 6, null, null),
('8f7fa83f-f804-41b6-b1b2-644cee417a5b', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 2, 'Gram', 0.67, 7, null, null),
('58254f3d-33be-491a-a447-ecf4ff1f0f83', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 2, 'Gram', 2, 8, null, null),
('dbf792f6-4489-4750-9610-0051ac72dbee', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 2, 'Gram', 0.62, 9, null, null),
('eeec4d59-f13e-43ee-9b97-393f573d6b2e', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', 'cb71da23-fcbb-4d82-8dcc-8f4cd48e97b6', 'material', 250, 'Gram', 52.5, 10, null, null),
('3d061de6-bd90-488a-8122-24f7ab4e28b2', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '9d2c909f-392c-4309-a466-93e9659baf89', 'material', 5, 'Gram', null, 11, null, null),
('72f40dfa-7e35-4473-9e0d-8e6d0ee6f036', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '1ff22969-378a-444d-bbe7-0c8fa75f3c4a', 'material', 20, 'Gram', 3.73, 12, null, null),
('17c9b51d-bf68-484c-b5d6-b25bdf1a11a0', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '0acf8f6a-15a0-431c-8a22-caec195c7fc8', 'material', 5, 'Gram', null, 13, null, null),
('631f838e-bb4d-458c-93d9-0112f4f5e767', 'b6c077c6-e34e-4dd7-879c-7b1282b1c773', '0f23d4ce-f18c-47c6-9fdd-b121076534e0', 'material', 5, 'Gram', 0.5, 14, null, null),
('e3407188-08ac-42ae-87f6-239e4b20b08e', '1f013715-5b42-449b-b9a0-450192221f0c', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 10, 'Gram', 1.43, 0, null, null),
('f44f78bd-a4d0-4fee-a332-ee91eb56c8c3', '1f013715-5b42-449b-b9a0-450192221f0c', '85cfb1fe-591d-4db0-925c-d0f3d4b5c69f', 'material', 2.5, 'Gram', 2, 1, null, null),
('d4d63cf3-a589-4972-97e6-d9bfd8a3b942', '1f013715-5b42-449b-b9a0-450192221f0c', 'f3fda85a-b16c-4609-af0d-181a66df708e', 'material', 10, 'Gram', 8, 2, null, null),
('c9c85213-3918-413e-a7ad-162e5e105521', '1f013715-5b42-449b-b9a0-450192221f0c', '29899406-0eb9-41e4-aecd-b288adf7d325', 'recipe', 10, 'Gram', 1.92, 3, null, null),
('dc01b04f-8a97-4320-8e19-384ab38e2a95', '1f013715-5b42-449b-b9a0-450192221f0c', '9025ff8a-1639-453a-a8a7-6b8d6d7670a8', 'recipe', 15, 'Gram', 0.95, 4, null, null),
('f0a4eeed-9126-4171-9eb6-12efcfc64b36', '1f013715-5b42-449b-b9a0-450192221f0c', 'f4136be6-5d6f-47e3-be1b-5a31285afaf7', 'material', 200, 'Gram', 53.34, 5, null, null),
('746101b2-4fcd-451f-99b4-d52e3d7d8510', '1f013715-5b42-449b-b9a0-450192221f0c', '5abae750-07d9-4aa2-97bf-b0757fa97276', 'material', 100, 'Gram', 9, 6, null, null),
('fd54679c-aa5b-49bc-87c2-d6940a4ffbcf', '1f013715-5b42-449b-b9a0-450192221f0c', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 50, 'Gram', 0, 7, null, null),
('1f9b515b-59dd-44f5-8938-99b9bf161b72', '1f013715-5b42-449b-b9a0-450192221f0c', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 3, 'Gram', 1, 8, null, null),
('75ca1316-6c0d-4f93-aaad-e123a89aff1b', '1f013715-5b42-449b-b9a0-450192221f0c', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 9, null, null),
('308707d4-0e43-4e1d-86d6-62bb70a8b6ad', '1f013715-5b42-449b-b9a0-450192221f0c', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 2, 'Gram', 2, 10, null, null),
('7941c056-c741-403c-9d41-e555b3545576', '1f013715-5b42-449b-b9a0-450192221f0c', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 2, 'Gram', 0.62, 11, null, null),
('28f040a4-a448-4c1b-8cfd-e1166ffdc5da', '1f013715-5b42-449b-b9a0-450192221f0c', '4e5af56f-97aa-4775-a828-1f4da55b9fc6', 'material', 1, 'Gram', 3, 12, null, null),
('b47d272f-3844-494a-8313-966c26650dd9', '1f013715-5b42-449b-b9a0-450192221f0c', '93bdc872-1d15-4343-b779-6efd9763be6f', 'material', 20, 'Gram', 5.2, 13, null, null),
('5890ab4b-5cb2-4546-9007-445e74912728', '1f013715-5b42-449b-b9a0-450192221f0c', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 20, 'Gram', 1.01, 14, null, null),
('e6610631-620b-4a9f-9825-a67136244555', '1f013715-5b42-449b-b9a0-450192221f0c', 'bdb4d501-b297-49db-816c-baf2c666a7eb', 'material', 20, 'Gram', 5.6, 15, null, null),
('f02ba58f-c6e4-4aca-af9f-754103515aa7', '1f013715-5b42-449b-b9a0-450192221f0c', 'c07a62eb-4b49-4dd2-8f26-f46ef0c8bd2f', 'material', 20, 'Gram', 9.63, 16, null, null),
('bb1d2bdc-da22-499f-9499-f5db734bded3', '1f013715-5b42-449b-b9a0-450192221f0c', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 2, 'Gram', 0.64, 17, null, null),
('98247527-19e7-418f-9721-c2f9006118b8', '1f013715-5b42-449b-b9a0-450192221f0c', '441262f8-101c-4561-84a6-f9d446048257', 'material', 2, 'Gram', 0.21, 18, null, null),
('955fa77d-5006-4ab4-ae07-53b4b5aef1d8', '1f013715-5b42-449b-b9a0-450192221f0c', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 1, 'Gram', 0.06, 19, null, 'Slit'),
('67f07d85-b4e1-4d53-a2fc-1f19e8dc68f4', '1f013715-5b42-449b-b9a0-450192221f0c', '702daa6e-9b84-4d57-8176-e1345714d702', 'material', 1, 'Gram', 1, 20, null, null),
('abd81a2b-1977-4152-aa68-3520cf9fe7ab', '1f013715-5b42-449b-b9a0-450192221f0c', 'c20f7f49-e90e-4166-99c5-83c12a0da878', 'material', 10, 'Gram', 1, 21, null, null),
('8bab6ac4-a905-45b8-93d0-6495b91c7e0a', '429024fa-077b-4e2c-87a4-a67b79763001', 'ce1c43ab-3f96-4c5b-aed0-9816dc2fd613', 'material', 10, 'Gram', 1.87, 0, null, null),
('43efd40d-4b6f-45c6-a585-c6a85a91f6a6', '429024fa-077b-4e2c-87a4-a67b79763001', 'fd0bd2e8-06fe-4993-a506-b94e9fd4292f', 'material', 150, 'Gram', 3.45, 1, null, null),
('e66ed30f-bb66-44f0-9998-13f9db495588', '429024fa-077b-4e2c-87a4-a67b79763001', 'e09d17a2-7ca6-4c59-a4b4-3f31f5d58054', 'material', 70, 'Gram', 18.28, 2, null, null),
('6fe3a808-eacd-4b9c-9cd2-a78c47c64ad3', '429024fa-077b-4e2c-87a4-a67b79763001', '6d2ce1e2-05e3-44a2-8c4e-4f2859bd03a8', 'material', 30, 'Gram', 15, 3, null, null),
('12a9c9ea-2d25-45e6-b839-f32259c39ff6', '429024fa-077b-4e2c-87a4-a67b79763001', '51f94b65-f682-455a-a197-67d3ca505c8d', 'material', 600, 'Gram', null, 4, null, null),
('1cb7680b-10f1-4378-8369-e26af5e4c372', '429024fa-077b-4e2c-87a4-a67b79763001', '3f067417-7361-488b-83a1-80adc933760a', 'material', 20, 'Gram', 21.27, 5, null, null),
('08d4644d-819a-4247-ab38-9cd92fd33242', '429024fa-077b-4e2c-87a4-a67b79763001', '56feff9c-0b84-4df0-9434-fb451bf35a37', 'material', 500, 'Gram', 212.5, 6, null, null),
('5901a5a5-9f00-47fd-b39e-42943fa670d6', '429024fa-077b-4e2c-87a4-a67b79763001', '5977bd69-286a-47e1-af18-c2e0121f358b', 'material', 100, 'Gram', 20.86, 7, null, null),
('84d90a44-5012-4ac0-b96f-f814658c6900', '429024fa-077b-4e2c-87a4-a67b79763001', '6de2f8fa-bfbe-4f54-8cd4-1520ab58e12b', 'material', 25, 'Gram', 6.53, 8, null, null),
('98af24fb-7e57-4dea-84b4-80be6b6a9170', '429024fa-077b-4e2c-87a4-a67b79763001', '2e24a788-91b0-4505-aba4-3304255b5d0d', 'material', 5, 'Gram', null, 9, null, null),
('984e04d3-24ca-4d34-9015-bf35678cb58a', '429024fa-077b-4e2c-87a4-a67b79763001', 'c347b5e0-6e6a-4335-905a-1e019701ed00', 'material', 1.5, 'Gram', 0.65, 10, null, null),
('20c946e3-6182-47dd-886d-224cf0e3ae32', '429024fa-077b-4e2c-87a4-a67b79763001', 'f04ad98b-6580-438e-95d6-fe93f0a37a4d', 'material', 50, 'Gram', 2.6, 11, null, null),
('6f50da95-011c-4b09-b77f-19c7c4be83b9', '429024fa-077b-4e2c-87a4-a67b79763001', 'c64217bf-10e3-494b-aef2-da4a245287e8', 'material', 225, 'Gram', null, 12, null, null),
('f4007eab-3e6c-41a3-bd2a-de5df75fef3e', '429024fa-077b-4e2c-87a4-a67b79763001', 'f15b1e2c-669d-40a8-b7b2-ca2fd190968e', 'material', 100, 'Gram', 8.2, 13, null, null),
('2d195190-ad7f-491d-82ae-1107e31f8ef8', '429024fa-077b-4e2c-87a4-a67b79763001', 'b776dc8f-7da3-4804-923e-e2b1d43852c7', 'material', 250, 'Gram', 65.27, 14, null, null),
('68436230-62c1-4ef3-a316-babf89d35e28', '429024fa-077b-4e2c-87a4-a67b79763001', '5a1a2284-2f01-4848-966f-077023ad504f', 'material', 34, 'Gram', 7.19, 15, null, null),
('937744c5-0515-46f7-901e-8908ce1e8733', '429024fa-077b-4e2c-87a4-a67b79763001', 'c4dfc414-62e0-4d15-8e07-5de6ba0b5d05', 'material', 20, 'Gram', 1.36, 16, null, null),
('6888e2f0-7a32-4a92-a525-0185dfa1a75d', '429024fa-077b-4e2c-87a4-a67b79763001', 'e18c5cc6-8f91-4919-9bfc-0d9a442ae43e', 'material', 60, 'Gram', null, 17, null, null),
('00568b21-00ef-43ef-b02d-51ac2810ae0d', '429024fa-077b-4e2c-87a4-a67b79763001', 'd1fd0408-4099-4323-ae81-471a983f29f5', 'material', 9, 'Gram', null, 18, null, null),
('1df2ff2e-5612-4c26-aaf0-2dd6805feddd', '429024fa-077b-4e2c-87a4-a67b79763001', '72d51901-970b-40db-9d9a-f6b7db0f9a5b', 'material', 30, 'Gram', null, 19, null, null),
('97a7b9c6-be9c-4a59-b63d-9f6397d63d1b', '429024fa-077b-4e2c-87a4-a67b79763001', '901a7cc0-23ed-4585-a707-4304880603c4', 'material', 10, 'Gram', null, 20, null, null),
('d88fe7f4-6b1c-4d0e-bf58-5c106a180f34', '429024fa-077b-4e2c-87a4-a67b79763001', '54241d24-91f5-415e-8aa1-4922c2c8ea11', 'material', 556, 'Gram', null, 21, null, null),
('e6ebf1f0-dd5f-4c00-9def-ddd2ffca2a9e', '429024fa-077b-4e2c-87a4-a67b79763001', '4f679040-5b30-4bc5-aba0-c9b795008199', 'material', 566, 'Gram', null, 22, null, null),
('060dc5f1-3d93-47e2-99a0-0fcaeaa4ab1f', '429024fa-077b-4e2c-87a4-a67b79763001', '53641115-40d4-4049-bd87-73af1db08b71', 'material', 56.8, 'Gram', null, 23, null, null),
('e77428c5-18c7-422b-bf34-d6869ca0a29a', '429024fa-077b-4e2c-87a4-a67b79763001', 'da5d4b81-1f87-4c10-8faf-6a1cf4a8ce94', 'material', 56.8, 'Gram', null, 24, null, null),
('01901042-303b-4f6a-9b34-0fadcbe7ae7c', '429024fa-077b-4e2c-87a4-a67b79763001', '4dbd5318-7d84-4f88-9d33-1ff8a0a10fd6', 'material', 1701, 'Gram', null, 25, null, null),
('ee9a0bcb-2b91-4955-8e7f-236d3846408b', '429024fa-077b-4e2c-87a4-a67b79763001', '1bf012c1-7d47-4975-82fd-3bb378ed808b', 'material', 20, 'Gram', null, 26, null, null),
('b1cf2b99-86ab-4fef-b2d9-f64334fc8c11', 'e99ff99e-6695-4397-9214-f962264244ca', '3011eaa0-2d67-4aa3-ae06-b82962ff71c9', 'material', 550, 'Gram', null, 0, null, null),
('be9215a0-3880-437e-8147-ed3713924a09', 'e99ff99e-6695-4397-9214-f962264244ca', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 6, 'Gram', 6.38, 1, null, null),
('3f154f10-df04-43a1-a934-b926be4f4f5e', 'e99ff99e-6695-4397-9214-f962264244ca', '75a79058-1671-49f7-8aa6-16eefd9fe162', 'material', 75, 'Gram', 9, 2, null, null),
('ad6007e1-1fb6-46a6-8a3d-0979f22f0dfa', 'e99ff99e-6695-4397-9214-f962264244ca', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 110, 'Gram', 3.02, 3, null, null),
('d9836ad2-41a5-461c-8be9-0c638c7324ee', 'e99ff99e-6695-4397-9214-f962264244ca', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 12, 'Gram', 3.74, 4, null, null),
('d9ec994d-5371-43ac-aebd-252158dfc4f3', 'e99ff99e-6695-4397-9214-f962264244ca', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 8, 'Gram', 2.67, 5, null, null),
('604dd04b-f35a-4848-8e01-10c4155b2e87', 'e99ff99e-6695-4397-9214-f962264244ca', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 5, 'Gram', 5, 6, null, null),
('8ed40335-cecc-4c39-82cc-dcef723c6a4d', 'e99ff99e-6695-4397-9214-f962264244ca', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 7, null, null),
('c50cad47-0c76-4b16-ae0d-f4cdc0edc796', 'e99ff99e-6695-4397-9214-f962264244ca', '4cecda28-b23d-420a-aa02-fe96e4e88aca', 'material', 25, 'Gram', null, 8, null, null),
('fa9b11a2-ad29-46f3-9c38-cc22a756d81e', 'e99ff99e-6695-4397-9214-f962264244ca', '622c9c43-eb3f-4f8d-b727-195125031430', 'material', 6, 'Piece', 3.91, 9, null, null),
('92764a1b-7f17-49c0-bb76-b1dd7f2de8d1', 'e99ff99e-6695-4397-9214-f962264244ca', '32d429e9-e7ce-4dcd-8131-4d861d3bdd6a', 'material', 0, 'Gram', null, 10, null, null),
('a4a73bf8-12e1-457f-a9bd-b4e84b99a517', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 20, 'Gram', 2.86, 0, null, null),
('d741acf3-4006-45aa-891b-01403bc49a69', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 1, null, null),
('be4e8ebd-c5fb-4955-94eb-f82267c5451d', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '997e233b-147b-4b55-8f90-479e1eb139d7', 'material', 3, 'Gram', 0.39, 2, null, null),
('7bc98571-8844-45d9-b195-f75bea83ddc7', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '5ec8f655-05f4-4770-8319-09b00b3a1369', 'material', 50, 'Gram', 7.9, 3, null, null),
('1ec440bf-aade-46b1-90c4-3ea184bb0ee7', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '283d1b7c-00f7-4aa2-98af-04d87bf188dc', 'material', 40, 'Gram', 1.24, 4, null, null),
('446d597a-b79c-497a-a9c8-0795ac2e5041', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 30, 'Gram', 1.52, 5, null, null),
('20b799cb-03f8-4905-9d26-a50c2e103a6b', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '972a61db-ddee-42ae-8e98-35db7fbba6b0', 'material', 20, 'Gram', 5.11, 6, null, null),
('773a2c87-7137-4e94-9fcc-86f06c1b1faa', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'abbd46f7-f4ec-4d23-9ac6-af96b7d96437', 'material', 15, 'Gram', 1.13, 7, null, null),
('1c220002-b117-4b93-942d-5b78b418b377', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '79f3e845-3142-4738-a5cf-093cebd394c2', 'material', 5, 'Gram', null, 8, null, null),
('2be15b5d-d6a1-4f6f-b55e-2b887612671c', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '69bf50a8-ef47-4914-bc5b-a99b82f99dca', 'material', 5, 'Gram', 3.24, 9, null, null),
('0a5feb79-71d8-4baa-8523-8cdbc0c04965', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 2, 'Gram', 2.13, 10, null, null),
('6950c335-3d10-48e4-ab82-f06296620d17', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '3b7ae7fd-d19e-447d-b633-3fa7789a687c', 'material', 5, 'Gram', 1.31, 11, null, null),
('d4b6ed07-7b69-42ea-a50d-41ce34a64475', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '7cd7a215-fa40-4d11-a431-7e0a3899b484', 'material', 2, 'Gram', 1.32, 12, null, null),
('cfb17c92-b58e-4086-a4c5-7df026b722da', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 13, null, null),
('95b4add6-943e-43af-a615-ffde9d3d45b3', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 1, 'Gram', 0.33, 14, null, null),
('486426e9-efff-446d-b1df-34893d75c1c9', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 1, 'Gram', 1, 15, null, null),
('a8b14fa6-b572-496f-ba6c-69d0a1b9af96', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'abf6e107-ab2d-4967-813d-a2d614fc8ad5', 'material', 3, 'Gram', null, 16, null, null),
('6747ffb2-534b-4a4f-8af6-3531e9744e28', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '8fc721c0-ef9a-4230-b7e7-b56381eda873', 'material', 100, 'Gram', null, 17, null, null),
('2c544c06-b917-4e98-9b00-d0745e289ac7', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 18, null, null),
('6bda8b45-3ab2-4cee-b89a-0fb5fc0a5a9b', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'b66b6e1f-70f7-4545-8f3c-e8712f96edc9', 'material', 5, 'Gram', 0.36, 19, null, null),
('1015faae-16c7-417c-88f0-a8ecba4f8b70', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'f23ae38f-8953-471d-a32c-357d93ead52d', 'material', 5, 'Gram', 0.36, 20, null, null),
('2ffab8e8-f888-4405-85e2-4614ac00aa71', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 5, 'Gram', 1.74, 21, null, null),
('5469e530-7969-45dd-aea8-a8ac606644f3', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'b91e0b3d-3ac3-4ddc-bfe7-7ca2897b9cc6', 'material', 20, 'Gram', 2.7, 22, null, null),
('1b8fba46-5ef5-4c64-ad58-f52a7e831077', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '36c07757-a8a8-40cf-975c-ac1a152ff5e7', 'material', 80, 'Gram', 6.08, 23, null, null),
('462e8dfc-eec2-4959-b7a8-ab55721cd345', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '3b7ae7fd-d19e-447d-b633-3fa7789a687c', 'material', 40, 'Gram', 10.44, 24, null, null),
('f215745d-7194-4b98-9f3f-4bf436f416eb', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '6edfe0ce-9e3f-4c16-a486-7d72fc90a4b9', 'material', 6, 'Gram', 11.45, 25, null, null),
('61513e0c-0245-4c4b-81fa-606119d95086', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '41dbe585-6949-4d0b-ba0a-ba32e6a75ce1', 'material', 20, 'Gram', 5.06, 26, null, null),
('2f40e51a-037b-4a42-93d6-f512e6d3041f', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '93af0a57-67fb-40cd-be77-7a7469f063b8', 'material', 10, 'Gram', 2.11, 27, null, null),
('e89923cd-f5d9-4bb8-8aa4-f7ed25977de5', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '619356c0-9e81-4ac6-8e9d-3acd9723bf7b', 'material', 17, 'Gram', 0.75, 28, null, null),
('6b009af5-1a77-4822-9968-36211c2cc897', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 90, 'Gram', 0, 29, null, null),
('e2289ea0-6a23-49cd-a1c6-b4026c5ec675', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 60, 'Gram', 8.57, 30, null, null),
('6753b8f4-9f98-4a11-8e67-d43359bbe8f2', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '86453416-c2f9-4a51-a0f0-b020788c4c1b', 'material', 1, 'Gram', 0.03, 31, null, null),
('19da75c6-a569-4d75-9a62-1a41367a5ebd', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '69ba7082-7848-49b4-8730-d791a97cec79', 'material', 200, 'Gram', 20, 32, null, null),
('fccc9201-0a4f-44e3-bb42-a401ca629ced', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '73a115f4-2a73-4484-8ec9-b9c03fb39aa4', 'material', 10, 'Gram', 10, 33, null, null),
('7a1d65ce-d236-4f35-83ed-006595b317e5', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 4, 'Gram', 0.4, 34, null, null),
('f5aa2e32-0c37-45a0-a74e-394939c32d1e', '95452ad8-79c1-4e80-97ce-70cadbf9cc51', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 35, null, null),
('12164c5b-a446-4b04-a6c4-39d92838e31f', 'f3f17803-4044-4980-86a7-21cebacf1973', '462ab7ea-c3a0-4c0e-bbb3-58e6d5669cd1', 'material', 250, 'Gram', 112.5, 0, null, null),
('baca6b6f-d534-42cc-8da3-d0056bb5f9a6', 'f3f17803-4044-4980-86a7-21cebacf1973', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 50, 'Gram', 44.2, 1, null, null),
('9a4b001e-160a-4c06-a5d8-287a1a7281f0', 'f3f17803-4044-4980-86a7-21cebacf1973', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 4, 'Gram', 0.11, 2, null, null),
('c8001629-caac-4a47-8c41-44dfd64527f4', 'f3f17803-4044-4980-86a7-21cebacf1973', '779cc97b-67ac-487a-be12-3183dc8117dc', 'material', 4, 'Gram', 4, 3, null, null),
('27ae7bc1-31fa-44a1-84d9-04b58a392c16', 'f3f17803-4044-4980-86a7-21cebacf1973', '910522b2-9199-4fec-add4-296db690dd3f', 'material', 25, 'Gram', 141.23, 4, null, null),
('5afeb74d-a481-4dc9-9b11-543895769d17', 'f3f17803-4044-4980-86a7-21cebacf1973', 'f4ce6a2e-0b63-49f6-a744-59b99d2f43f7', 'material', 5, 'Gram', 103.38, 5, null, null),
('65d17638-46af-465c-a006-06d0a27ae5f5', 'f3f17803-4044-4980-86a7-21cebacf1973', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 20, 'Gram', 0, 6, null, null),
('bb316cce-a92d-4154-b46b-5a8645e2fcef', 'f3f17803-4044-4980-86a7-21cebacf1973', 'ec88f6f9-4aae-4d35-b1b6-bbf9cf1fe93f', 'material', 4, 'Piece', 2.6, 7, null, null),
('0e107b63-98d1-418f-be00-51fbe5422f68', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '283d1b7c-00f7-4aa2-98af-04d87bf188dc', 'material', 500, 'Gram', 15.55, 0, null, null),
('8fbc8a88-9c64-4d41-854c-c3d66be45e61', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 100, 'Gram', 2.75, 1, null, null),
('107f6da6-3bdf-4931-9c25-cd7ae83751a8', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 50, 'Gram', 2.53, 2, null, null),
('c1073500-ea15-4b19-bec8-45bde7ffd8cb', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 10, 'Gram', 0.75, 3, null, null),
('b88b62db-ad11-4a2a-932e-3bc61aa2f739', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '03b1dea2-3c54-4eba-8c3b-bf2d33fbd8d7', 'material', 175, 'Gram', 118.13, 4, null, null),
('f02e705b-46f8-440e-b07f-10f36d42a684', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 6, 'Gram', 0.17, 5, null, null),
('55d1d8d0-60df-440a-ad4f-b982d97a44cd', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 4, 'Gram', 4, 6, null, null),
('2411bc7a-c899-4559-b716-2501b17100c5', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 6, 'Gram', 2, 7, null, null),
('0c6adb70-4548-45fb-a72e-1f88ee411775', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 8, 'Gram', 2.5, 8, null, null),
('ee70a772-1276-4f32-a44c-5f449efdda2e', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 30, 'Gram', 5.47, 9, null, null),
('92e16059-3359-4e4c-9249-797ddc7c68f3', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 3, 'Gram', 3.19, 10, null, null),
('fc5f0929-2ca5-4be2-b227-dae9f005438e', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'a0afdbe0-3e23-4c84-82d0-1c9a2eb3237c', 'material', 500, 'Gram', 34.15, 11, null, null),
('29edd1f6-1cba-4683-8048-ac7f04805db3', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '69bf50a8-ef47-4914-bc5b-a99b82f99dca', 'material', 8, 'Gram', 5.18, 12, null, null),
('9e222b07-154b-452d-9512-3980ccd0827c', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'material', 15, 'Gram', 30, 13, null, null),
('8f7ad15b-ab9a-43a0-b16c-aa9179870522', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'a59ffabd-4213-4066-84b0-62dd93a609fa', 'material', 50, 'Gram', 20, 14, null, null),
('ac24285a-7c11-4234-af79-6b4cc2c6607f', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'cd2b5040-b7b6-4d74-a67f-ca15f04bb3b9', 'material', 20, 'Gram', 4.3, 15, null, null),
('9ffa11b1-8794-4afa-b9f2-051a79da0a73', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 6, 'Gram', 0.17, 16, null, null),
('186953b1-52a3-4b09-a56a-9455d4b10baf', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 3, 'Gram', 1, 17, null, null),
('c47d13d4-cfb8-450a-8af3-178b2fcab19c', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 6, 'Gram', 1.87, 18, null, null),
('537def74-e970-4f93-bfa2-9f2149479cdf', '61fa43f4-d002-4b8a-b0da-7f3af1c738f5', 'ec88f6f9-4aae-4d35-b1b6-bbf9cf1fe93f', 'material', 5, 'Piece', 3.25, 19, null, null),
('8e680191-5377-46eb-ac10-9b1e475661e4', 'ede93305-839b-456e-8894-a4109676b350', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 95, 'Gram', 83.98, 0, null, null),
('3ad66294-75e8-4c7f-8825-092c9cf38168', 'ede93305-839b-456e-8894-a4109676b350', '93bdc872-1d15-4343-b779-6efd9763be6f', 'material', 100, 'Gram', 26, 1, null, null),
('548982da-df41-4635-9721-c166d2213b26', 'ede93305-839b-456e-8894-a4109676b350', '3011eaa0-2d67-4aa3-ae06-b82962ff71c9', 'material', 100, 'Gram', null, 2, null, null),
('e4ff7665-5189-4b88-8e8b-2ddfbf029ef2', 'ede93305-839b-456e-8894-a4109676b350', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 6, 'Gram', 0.17, 3, null, null),
('7acee4f3-ad7b-4fdd-ae9f-c46882da6b32', 'ede93305-839b-456e-8894-a4109676b350', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 2, 'Gram', 0.2, 4, null, null),
('5d982a6a-5b27-4c95-ad72-d3c5ca472b98', 'ede93305-839b-456e-8894-a4109676b350', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 1, 'Gram', 1, 5, null, null),
('b8c1b882-71b5-45d2-91bf-ff7a0f5d18e9', 'ede93305-839b-456e-8894-a4109676b350', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 10, 'Gram', 3.2, 6, null, null),
('ae9db666-6036-4cd3-8431-6638903e9ffa', 'ede93305-839b-456e-8894-a4109676b350', '3be12901-de36-4cf8-9eaf-285577602b5c', 'material', 3.5, 'Gram', 0.7, 7, null, null),
('f286920f-0177-4a61-b330-7f42e1c37275', 'ede93305-839b-456e-8894-a4109676b350', '7d9b1197-97eb-4b68-8c86-ba1883854214', 'material', 5, 'Gram', 1.04, 8, null, null),
('9589b88a-31aa-479a-88f4-339564b4a156', 'ede93305-839b-456e-8894-a4109676b350', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 30, 'Gram', 5.47, 9, null, null),
('664f84eb-5c55-490e-b6d7-1a382cd143e3', 'ede93305-839b-456e-8894-a4109676b350', 'bd976fab-4bc0-492d-b4b2-aef9390f32c2', 'material', 5, 'Gram', 0.65, 10, null, null),
('881e5fa0-77c2-4cb9-a69a-06ad1465a666', 'ede93305-839b-456e-8894-a4109676b350', 'c09efcdd-7fcc-4fe6-ab6f-85fe18faab4d', 'material', 10, 'Gram', 2.42, 11, null, null),
('9849849d-4d13-4c1b-af41-037cd32356c2', 'ede93305-839b-456e-8894-a4109676b350', 'ac7ad56f-dc69-4017-a2c4-f6faf543214f', 'material', 150, 'Gram', 12.38, 12, null, null),
('557c3656-f9b5-432d-891e-d85ff917382c', 'ede93305-839b-456e-8894-a4109676b350', 'fca3a08e-4a41-4c18-adf5-25000c6e5778', 'material', 1, 'Gram', 1.05, 13, null, null),
('3c194f52-3dbc-4970-aae8-371c21d5b250', 'ede93305-839b-456e-8894-a4109676b350', '3917d270-1cf1-48ee-bd4a-b81a8811831b', 'material', 5, 'Gram', 0.62, 14, null, null),
('eb0afa6b-a5a1-4294-a78e-875fc6b7840d', 'ede93305-839b-456e-8894-a4109676b350', 'a0afdbe0-3e23-4c84-82d0-1c9a2eb3237c', 'material', 50, 'Gram', 3.42, 15, null, null),
('7c054837-72d7-433d-ae21-990a181cf563', 'ede93305-839b-456e-8894-a4109676b350', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 10, 'Gram', 0.29, 16, null, null),
('92fcce3e-add9-4193-9b0c-fa1d72d95226', 'ede93305-839b-456e-8894-a4109676b350', '582632fb-52b5-4cdb-bb54-e434850625c0', 'material', 8, 'Gram', 0.81, 17, null, null),
('6753d264-b078-4856-a0dc-c568634caaae', 'ede93305-839b-456e-8894-a4109676b350', 'e3e2dc91-abda-47f6-a38e-38af9dc7e8b5', 'material', 6, 'Gram', null, 18, null, null),
('d4994b9a-7cba-4c72-ba97-225e2d9115bb', 'ede93305-839b-456e-8894-a4109676b350', 'c14ad046-d44c-45e3-840c-8988103959b3', 'material', 1, 'Gram', null, 19, null, null),
('08356b90-7690-4b4f-a9d7-e08a9c6650b4', 'ede93305-839b-456e-8894-a4109676b350', '93af0a57-67fb-40cd-be77-7a7469f063b8', 'material', 10, 'Gram', 2.11, 20, null, null),
('aa8363ca-4274-47f4-b8a7-4e1b0e0d2679', 'ede93305-839b-456e-8894-a4109676b350', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 'material', 20, 'Gram', 6.22, 21, null, null),
('7f02bac2-dbe1-42d1-a8a6-9b088e387766', 'ede93305-839b-456e-8894-a4109676b350', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 22, null, null),
('80e81542-7fce-4d8d-8bac-a0888f1b31a5', 'ede93305-839b-456e-8894-a4109676b350', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 3, 'Gram', 0.22, 23, null, null),
('e24962f8-849c-4222-b0f9-e2b4daa78f27', 'ede93305-839b-456e-8894-a4109676b350', 'ec88f6f9-4aae-4d35-b1b6-bbf9cf1fe93f', 'material', 5, 'Piece', 3.25, 24, null, null),
('d358f8cd-c5f8-404e-b4e3-b4b8573f55cd', 'ede93305-839b-456e-8894-a4109676b350', 'c20f7f49-e90e-4166-99c5-83c12a0da878', 'material', 0, 'Gram', 0, 25, null, null),
('7a3264c3-58bb-4046-8436-a79eeeb2c068', 'ede93305-839b-456e-8894-a4109676b350', '10f23a81-37fe-40db-94e2-90052c68ca0c', 'material', 0, 'Gram', null, 26, null, null),
('7cbd5310-8a5c-40da-bfab-70fcb2f334cc', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'fee655aa-7aba-421c-bd88-d1e70f3b0fa1', 'material', 5, 'Gram', 3.25, 0, null, null),
('cca67271-535f-41ce-bcc6-0c9ca1dcf16d', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '9bd8f0f8-a6c0-4ba9-8765-40c31c6889ee', 'material', 75, 'Gram', null, 1, null, null),
('2860c845-9c85-4e70-9680-eaea74951032', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 10, 'Gram', 1.43, 2, null, null),
('865d4214-2c26-4fad-a23f-25e813823902', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '4e397512-96ef-40ee-a107-93aac2032ed5', 'material', 1, 'Gram', 0.9, 3, null, null),
('62399ba5-28fb-4566-8cb4-2954e2f65950', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '7944e522-9eba-4a3f-bee8-99a4f9262b5d', 'material', 20, 'Gram', null, 4, null, null),
('425d9554-6726-47ba-9a31-47aee5ba29bb', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '5abae750-07d9-4aa2-97bf-b0757fa97276', 'material', 100, 'Gram', 9, 5, null, null),
('f9a59303-073f-4016-a5f9-8586a678568f', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 1, 'Gram', 0.03, 6, null, null),
('618227c6-09f0-4661-8605-8f82c92d5e10', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 1, 'Gram', 0.33, 7, null, null),
('8e716668-ef0e-43b6-ac94-b284d224906d', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 1, 'Gram', 0.31, 8, null, null),
('2ddbe422-f84a-4d3e-89ee-cb35df4e99a9', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '19188392-d841-4f27-a9f1-e47bef2a0825', 'material', 1, 'Gram', null, 9, null, null),
('a72640b1-a414-4958-b694-1b3cd67641be', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '8bd98a82-5e75-4c24-921d-7c7dfb695dbe', 'material', 4, 'Gram', 0.77, 10, null, null),
('b89497ff-756e-490c-ad9c-573e561b4af9', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', 'abbd46f7-f4ec-4d23-9ac6-af96b7d96437', 'material', 2, 'Gram', 0.15, 11, null, null),
('0cbbd2f3-a4d2-4b9c-91ca-a4c98ff88b0e', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '8df73ddf-a681-44aa-b2e0-23000a72b38d', 'material', 2, 'Gram', 0.15, 12, null, null),
('5d428375-df02-42a5-83a2-8fbd41fc6b10', '552af58b-53e3-4984-a39e-6ffdb61fd4a2', '748496ba-4a5e-4558-9f69-5df36135427b', 'material', 4, 'Gram', null, 13, null, null),
('8f0aaed5-0818-4c49-8e41-d8d6407c117b', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '98b0d739-909c-433d-9808-c1718f27f89d', 'material', 2, 'Piece', null, 0, null, null),
('7196d1e8-e6c6-4234-8e51-f582c95a8f2a', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', 'e992ed95-4129-4cc9-9a44-c3c430d0ada6', 'material', 2, 'Piece', null, 1, null, null),
('511ebe17-4423-4583-809f-e8bc54ebfd82', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '2a39595e-a452-4bf7-9743-174ada96b008', 'material', 2, 'Piece', null, 2, null, null),
('0c42cfcf-0bc2-419c-bc75-6fb61503b6c9', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '2a3a6398-1ed4-4e1e-9cf6-4f35f5633fad', 'material', 2, 'Piece', null, 3, null, null),
('d8f742e6-37ad-418c-85ff-279e0bee0743', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '5f58ec3c-5b8e-4ec4-a458-ab25f782215b', 'material', 2, 'Piece', null, 4, null, null),
('229fb3d3-8665-4ee1-a17e-e82401d5408e', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '328877b4-3177-47dc-9bd6-da75753c8d51', 'material', 30, 'Gram', null, 5, null, null),
('76dbcd1b-c94a-4f78-b71b-2a4c33a0b9e5', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', 'af145b47-68bb-4613-9080-a05b0ba749fa', 'material', 25, 'Gram', null, 6, null, null),
('96a75466-505a-4201-a14f-76ac938793ee', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '5ee5e1a8-459f-4ace-b796-f2c9d386e4f5', 'material', 15, 'Gram', null, 7, null, null),
('cf1640f6-c50e-4e1f-b2bc-cd1c92e97a80', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', '9e0049b2-b0bd-4474-92ca-21cac292cc51', 'material', 25, 'Gram', null, 8, null, null),
('36544d05-c585-44ed-a51a-0b647e47976a', 'a3965fcb-fedb-46d6-abc8-60ca7d9907fb', 'b3057213-f257-4278-8d4c-2d5182a7f526', 'material', 30, 'Gram', null, 9, null, null),
('cf644aba-4b7f-415d-a083-827c1674084f', '59beb5b1-db25-40ca-9584-e304ccc9e175', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('69f70362-cef9-4802-b2f4-dabeda5f76a1', '59beb5b1-db25-40ca-9584-e304ccc9e175', 'b2482bca-c22b-4539-b10b-ed5ab54b70ad', 'material', 1.4, 'Gram', null, 1, null, null),
('2eee0f29-841a-4555-9287-8c8d5a60a7aa', '59beb5b1-db25-40ca-9584-e304ccc9e175', '9f20b495-00ce-4e56-9662-0f64cf8c6628', 'material', 5, 'Gram', 1.37, 2, null, null),
('70c67086-9698-4678-85e0-218a3e9c1a01', '59beb5b1-db25-40ca-9584-e304ccc9e175', 'e5ff968a-02fd-4c7a-b5d4-d3bc13ef8a86', 'material', 5, 'Gram', 0.95, 3, null, null),
('5cb012bd-5f28-485f-aeb5-75adbf74c23c', '59beb5b1-db25-40ca-9584-e304ccc9e175', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 25, 'Gram', 22.1, 4, null, null),
('71e24426-39cb-481a-bd39-03f1efb8d1e5', '59beb5b1-db25-40ca-9584-e304ccc9e175', 'd6775fb8-0fce-4eb8-9795-d4965728f6ea', 'material', 20, 'Gram', 6, 5, null, null),
('705591be-4fd9-4810-97e6-1dd4f3ba46d9', '59beb5b1-db25-40ca-9584-e304ccc9e175', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 30, 'Gram', 1.57, 6, null, null),
('05ed4d24-d631-4e61-abe9-8dd1848221cf', '59beb5b1-db25-40ca-9584-e304ccc9e175', '851d665c-baa8-4ef6-b4d5-bca8462c0c65', 'material', 180, 'Gram', 117, 7, null, null),
('6a53f199-21ec-4262-ba08-a8debee6188f', '59beb5b1-db25-40ca-9584-e304ccc9e175', '1395fab5-154f-488f-b06c-42e091760451', 'material', 30, 'Gram', 9, 8, null, null),
('d487eb69-a5a4-4c38-9f14-96ee017fb0f7', '59beb5b1-db25-40ca-9584-e304ccc9e175', '40e3faa2-618b-40fb-be39-9861c52887fe', 'material', 10, 'Gram', 3.43, 9, null, null),
('5d5be139-f797-4188-9291-04251a32ed9e', '59beb5b1-db25-40ca-9584-e304ccc9e175', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 5, 'Gram', 1.74, 10, null, null),
('ad968b6a-be40-4f89-95dd-b612fbaecfda', '59beb5b1-db25-40ca-9584-e304ccc9e175', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 20, 'Gram', 5.33, 11, null, null),
('5eba0230-d44c-49b0-b148-9c50725af5ce', '59beb5b1-db25-40ca-9584-e304ccc9e175', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 3, 'Gram', 3, 12, null, null),
('cd5e46db-f733-4574-8a7b-e4c590e3b5ee', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('97c9c7df-d1bc-48c0-a050-082032aa8cb7', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '7e46f4fa-2a38-4574-b47f-66e93a685155', 'material', 1.4, 'Gram', null, 1, null, null),
('5d13374f-5661-4d51-bf61-09e1379a5234', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '9f20b495-00ce-4e56-9662-0f64cf8c6628', 'material', 4, 'Gram', 1.09, 2, null, null),
('8f05c047-23d0-4623-802a-945c54069f0b', 'c543e252-f735-42b6-a655-6d1692fdc1eb', 'e5ff968a-02fd-4c7a-b5d4-d3bc13ef8a86', 'material', 4, 'Gram', 0.76, 3, null, null),
('56c124fc-11d4-4450-8b41-67c1c570cecd', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 25, 'Gram', 22.1, 4, null, null),
('d39bc0ba-e7aa-4f02-887b-ac914ef53277', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '0024c03b-1b96-49d4-b50e-61e8cc6f7ec3', 'material', 9, 'Gram', 1.63, 5, null, null),
('f3241085-1e1c-4674-b614-8f9861cef651', 'c543e252-f735-42b6-a655-6d1692fdc1eb', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 8, 'Gram', 0.6, 6, null, null),
('7d27f8ff-134f-4bcd-b598-4062637f517a', 'c543e252-f735-42b6-a655-6d1692fdc1eb', 'dee40ee5-cdca-4a51-9bd5-4b7f9d27093f', 'material', 25, 'Gram', 4.66, 7, null, null),
('4bdaea84-db94-422e-9001-bb7ca375a425', 'c543e252-f735-42b6-a655-6d1692fdc1eb', 'cd52d448-e2cf-4d5d-8739-5848298cfe06', 'material', 15, 'Gram', 5, 8, null, null),
('bef89f07-515c-45a8-864a-f36af871097a', 'c543e252-f735-42b6-a655-6d1692fdc1eb', 'aca97449-3b31-417f-96a1-436f35a6621f', 'material', 4, 'Gram', null, 9, null, null),
('4ae0cf3e-9d36-4214-a058-cfd2a5786d21', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 5, 'Gram', 1.74, 10, null, null),
('44367293-3a24-40ff-8bf3-3ee548ed35c2', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 20, 'Gram', 5.33, 11, null, null),
('3db9e64b-29da-4eb0-bd4f-dfbda5ff2fc6', 'c543e252-f735-42b6-a655-6d1692fdc1eb', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 3, 'Gram', 3, 12, null, null),
('dbda1c72-2c3b-4d9f-a86a-3af27b9eed6f', '149622df-1145-487c-bff5-06c3562b8478', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('248a002e-0df9-48f6-a1c2-e61a2a9bc938', '149622df-1145-487c-bff5-06c3562b8478', '8207620f-a946-4e19-b606-f474b047a2e1', 'material', 1.4, 'Gram', null, 1, null, null),
('35916a4a-8417-4d66-bcbe-a619c6c3c5ac', '149622df-1145-487c-bff5-06c3562b8478', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 20, 'Gram', 17.68, 2, null, null),
('2b15191e-7b2c-4c16-bccb-e6ff508248b1', '149622df-1145-487c-bff5-06c3562b8478', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 6, 'Gram', 0.45, 3, null, null),
('9307c6ad-c011-4a71-adda-8fb4da55b686', '149622df-1145-487c-bff5-06c3562b8478', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 15, 'Gram', 0.76, 4, null, null),
('7a5a9bed-cc32-409f-a228-8501bd9f390a', '149622df-1145-487c-bff5-06c3562b8478', '0024c03b-1b96-49d4-b50e-61e8cc6f7ec3', 'material', 30, 'Gram', 5.42, 5, null, null),
('7669cba0-3f3f-4a98-befd-6b499d4cc9ba', '149622df-1145-487c-bff5-06c3562b8478', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 15, 'Gram', 0.79, 6, null, null),
('e5acb5a8-3c92-4ff1-b9e8-781d85709cd1', '149622df-1145-487c-bff5-06c3562b8478', 'ffb645e2-1414-4848-a48e-af60831da811', 'material', 100, 'Gram', 42.69, 7, null, null),
('63f50a8e-402a-4c86-983e-32a710923828', '149622df-1145-487c-bff5-06c3562b8478', 'cd52d448-e2cf-4d5d-8739-5848298cfe06', 'material', 10, 'Gram', 3.33, 8, null, null),
('d224f488-5f77-4ec4-af2f-c86e4b3e06d9', '149622df-1145-487c-bff5-06c3562b8478', 'ec88bbe6-bef9-484c-b2fd-33184c72d379', 'material', 5, 'Gram', null, 9, null, null),
('5492d396-ee10-49b5-a657-3140267651e0', '149622df-1145-487c-bff5-06c3562b8478', 'bda68944-7e9e-4acd-a0d5-173c95fd30f6', 'material', 5, 'Gram', 1.74, 10, null, null),
('805d4d62-0eb5-46ee-8479-58f263aeec54', '149622df-1145-487c-bff5-06c3562b8478', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 20, 'Gram', 5.33, 11, null, null),
('ac8e0f77-e049-4998-8bfc-0be05d1a583a', '149622df-1145-487c-bff5-06c3562b8478', 'd527c27d-27ff-4ed8-aa22-b8574ca015db', 'material', 3, 'Gram', null, 12, null, null),
('8acd9735-9fcf-4dcc-96c3-d574d300b948', '149622df-1145-487c-bff5-06c3562b8478', '41634c6b-76b7-4f18-9db6-42dd4e352e41', 'material', 2, 'Gram', 2.09, 13, null, null),
('4382f36a-b1bf-4434-885f-67b3f46c8a15', '464166bf-bb73-4535-a6f0-f299ea4762e1', '2f50d019-9a2c-4446-8322-9089710b743e', 'material', 4.2, 'Gram', null, 0, null, null),
('a59f7575-6cd7-4ffd-bf6d-489798930efa', '464166bf-bb73-4535-a6f0-f299ea4762e1', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 160, 'Gram', 40.32, 1, null, null),
('56daae85-c580-4d10-810f-fe4c17cf7960', '464166bf-bb73-4535-a6f0-f299ea4762e1', '6ad85bc0-f1e5-49fa-a0bd-77775714b3e0', 'material', 40, 'Gram', null, 2, null, null),
('edf354ed-c00e-4250-b92c-737fbab79729', '464166bf-bb73-4535-a6f0-f299ea4762e1', '57436ed7-b733-46c0-b929-2d607dc14f81', 'material', 10, 'Gram', null, 3, null, null),
('64d56489-f5d6-47f8-8c28-8195832e59a7', '464166bf-bb73-4535-a6f0-f299ea4762e1', '64aea946-023f-49eb-a181-9b33f5868b07', 'material', 20, 'Gram', null, 4, null, null),
('9a76d24a-9c40-4b84-b8f7-deb1a372fa47', '464166bf-bb73-4535-a6f0-f299ea4762e1', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 25, 'Gram', 1.31, 5, null, null),
('228e5d54-d58c-4c14-8325-9269b33bae88', '464166bf-bb73-4535-a6f0-f299ea4762e1', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 25, 'Gram', 1.26, 6, null, null),
('7ed7b3f4-6aa7-4ff0-9d3a-46520963b463', '464166bf-bb73-4535-a6f0-f299ea4762e1', '77922919-1a21-423d-9d2e-0316facd974b', 'material', 40, 'Gram', null, 7, null, null),
('1a5b85d9-2cc0-42b5-a7cd-28fac7e98845', '464166bf-bb73-4535-a6f0-f299ea4762e1', '9a06f3df-1fff-4dec-ba17-ac5d8cbe4976', 'material', 1, 'Gram', 0.66, 8, null, null),
('de802c50-9bc8-4384-94f1-06523af584dd', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('a6f0050a-b8b1-4fb1-806c-cf1960faecaa', '23e938a7-d990-4341-8cfc-f21f1a1179b4', 'b2482bca-c22b-4539-b10b-ed5ab54b70ad', 'material', 1.4, 'Gram', null, 1, null, null),
('8a096de7-6a45-4849-9c85-376507bd358b', '23e938a7-d990-4341-8cfc-f21f1a1179b4', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 3, 'Gram', 0.23, 2, null, null),
('ef93eb28-4d4b-4999-91ec-e0927c966ec3', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 25, 'Gram', 22.1, 3, null, null),
('24095b19-a312-4952-aa42-46d60c5e5650', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 10, 'Gram', 0.51, 4, null, null),
('5186f86f-1bea-4f01-91c2-fff727a16b48', '23e938a7-d990-4341-8cfc-f21f1a1179b4', 'b1066e99-02cc-4586-82af-39b6c868bbcd', 'material', 18, 'Gram', 0.97, 5, null, null),
('2377d922-9209-4727-9d38-f80586f9fba5', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '4236381e-78ac-4b52-a071-8fb0b4b7d0d1', 'material', 15, 'Gram', 2.71, 6, null, null),
('51290aae-56dc-4e91-9719-3e53a90550d0', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 1, 'Gram', 0.07, 7, null, null),
('04638ce0-b922-4883-890f-f773d67be21f', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '4012d042-0f0c-40a9-8290-5727d14a813c', 'material', 5, 'Gram', 1.25, 8, null, null),
('346fb6ad-ff5c-4b60-9885-e0ef03538113', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '5919db3d-ef40-4692-8a5d-52d4304812ef', 'material', 15, 'Gram', null, 9, null, null),
('cf432219-87d8-4be9-b2cf-5a56639d51e7', '23e938a7-d990-4341-8cfc-f21f1a1179b4', 'e3027fd3-f65e-49d3-b5b7-f6165aa50a5f', 'material', 35, 'Gram', null, 10, null, null),
('456bd459-ef38-44d4-836e-5b919e3dcb9e', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '2b403a63-9f47-4b64-b646-3bd6de1156ec', 'material', 11, 'Gram', 2.68, 11, null, null),
('2b491430-cf63-4c05-9190-7842332e72b0', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '1395fab5-154f-488f-b06c-42e091760451', 'material', 7, 'Gram', 2.1, 12, null, null),
('b7b6678e-8bc7-4272-bd98-23c5c1d7839c', '23e938a7-d990-4341-8cfc-f21f1a1179b4', 'da84640d-84a8-4ec0-9754-a47ef8690d7a', 'material', 8, 'Gram', 4, 13, null, null),
('263846af-dc32-4b08-a8ed-57c2a65a15aa', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 20, 'Gram', 5.33, 14, null, null),
('14e5b94c-358f-47e4-b80e-f451eb9f1a70', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 5, 'Gram', 1.74, 15, null, null),
('056b5733-3cce-4f1f-972c-c4b9c3914e64', '23e938a7-d990-4341-8cfc-f21f1a1179b4', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 2, 'Gram', 2, 16, null, null),
('483daf83-6c49-4c20-be96-666a64311551', '2b4adf69-135e-4eff-b957-31f282d74d10', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('c62396db-ac6b-44e9-9dfe-2288baec4202', '2b4adf69-135e-4eff-b957-31f282d74d10', 'b2482bca-c22b-4539-b10b-ed5ab54b70ad', 'material', 1.4, 'Gram', null, 1, null, null),
('2c39eefc-910a-4052-b245-cdb15ea7ae5a', '2b4adf69-135e-4eff-b957-31f282d74d10', '4012d042-0f0c-40a9-8290-5727d14a813c', 'material', 20, 'Gram', 5, 2, null, null),
('ccabcec2-7408-4289-8c68-5670b88ade7d', '2b4adf69-135e-4eff-b957-31f282d74d10', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 25, 'Gram', 22.1, 3, null, null),
('47b13db4-6d61-4dc1-a738-19bc02e3ebd9', '2b4adf69-135e-4eff-b957-31f282d74d10', '9f20b495-00ce-4e56-9662-0f64cf8c6628', 'material', 4, 'Gram', 1.09, 4, null, null),
('8e79852f-ea2d-43b5-a542-9aa3975a5435', '2b4adf69-135e-4eff-b957-31f282d74d10', '94427f65-c7f1-415b-a919-263dec4239ca', 'material', 6, 'Gram', 0.73, 5, null, null),
('b625df65-2ea9-43f9-93c2-f91abf78575d', '2b4adf69-135e-4eff-b957-31f282d74d10', '1395fab5-154f-488f-b06c-42e091760451', 'material', 8, 'Gram', 2.4, 6, null, null),
('11f75938-3e20-430f-91c6-9db39d2ab21c', '2b4adf69-135e-4eff-b957-31f282d74d10', 'da84640d-84a8-4ec0-9754-a47ef8690d7a', 'material', 8, 'Gram', 4, 7, null, null),
('7e30c896-282b-40bc-be92-6ad8e381e951', '2b4adf69-135e-4eff-b957-31f282d74d10', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 3, 'Gram', 0.22, 8, null, null),
('5a91c47c-3583-43b4-8b5e-25fe63fcd39e', '2b4adf69-135e-4eff-b957-31f282d74d10', '78c0c616-8e2b-45e1-92be-0b75c3230879', 'material', 10, 'Gram', 0.56, 9, null, null),
('39ca96f9-94cb-4f3b-8e7c-ff84d5bbce90', '2b4adf69-135e-4eff-b957-31f282d74d10', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 6, 'Gram', 0.45, 10, null, null),
('01923ca0-1410-49cc-b597-b6095a9f3faa', '2b4adf69-135e-4eff-b957-31f282d74d10', '19ccee31-760b-47b8-8f8c-ebdfb76477f5', 'material', 15, 'Gram', null, 11, null, null),
('43b86e91-f4a4-4448-8275-f396644e4dc4', '2b4adf69-135e-4eff-b957-31f282d74d10', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 20, 'Gram', 5.33, 12, null, null),
('74049198-5748-43f5-9ab0-9383af9cfda4', '2b4adf69-135e-4eff-b957-31f282d74d10', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 5, 'Gram', 1.74, 13, null, null),
('42c41a57-a90f-4d54-8986-501ba0349c5c', '2b4adf69-135e-4eff-b957-31f282d74d10', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 3, 'Gram', 3, 14, null, null),
('11fc13c6-41af-4fd7-bfd4-9cbbb43f6c90', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '7c86244d-83e2-4e5d-bf11-2c0b6c5d0bc1', 'material', 130, 'Gram', 32.76, 0, null, null),
('a2b5de45-7286-4822-914d-5d93758457dc', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', 'b2482bca-c22b-4539-b10b-ed5ab54b70ad', 'material', 2.8, 'Gram', null, 1, null, null),
('1e59d79d-c00f-410a-8db2-4d26f2363d2b', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '34fe4ec9-d93a-40b7-acaa-483ca87b2ec8', 'material', 25, 'Gram', 1.31, 2, null, null),
('47355559-ecd5-406d-a71d-8881c9ed0f2c', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '1988268a-a4d6-4899-bc8d-02f235035f5a', 'material', 25, 'Gram', 4.7, 3, null, null),
('7324c9e1-79c5-42b0-91a8-6c28338e3381', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '1e6e7403-ec42-4ab1-9816-fd12388cb0b0', 'material', 50, 'Gram', 44.2, 4, null, null),
('de571256-c44c-4700-b099-caffca94a64b', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 15, 'Gram', 1.13, 5, null, null),
('5a9db800-9c80-4331-9a90-6fbcef8c958e', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '77d09317-ea84-4d2d-a06b-2b8ccb08da5f', 'material', 40, 'Gram', 3.23, 6, null, null),
('4dbd614a-ae06-42e8-aacc-f5fd4cebbadc', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '11a45c4d-84ef-4e54-ad6a-3ba68c758e1b', 'material', 50, 'Gram', 6.74, 7, null, null),
('eb881d2a-97f7-45e7-bc1e-1ecd5970613e', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '7c0345f5-c6a6-43e1-aae4-6aaf6b2263b5', 'material', 30, 'Gram', 8, 8, null, null),
('44bfef66-3c45-4fb8-b68a-a001ceab2472', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '0db17438-28bb-4a7e-81c6-64063c75cc95', 'material', 20, 'Gram', 6.97, 9, null, null),
('f72d5517-2623-48bb-acc0-93cea96074a7', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', '9f009937-75f9-4338-a6c3-e7b41540bc51', 'material', 2, 'Gram', 2, 10, null, null),
('9e3d6657-3d79-4eb8-9134-27a06af297b0', 'abf6caf0-3201-4d8e-8584-f5eafdc909bf', 'da84640d-84a8-4ec0-9754-a47ef8690d7a', 'material', 10, 'Gram', 5, 11, null, null),
('970a6d05-37fe-42fc-91ca-fbe0b3c9c1d5', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 15, 'ML', 2.14, 0, null, null),
('7aba20fa-aa15-496f-83c7-f07877b901ba', '4b517e37-caf1-4af1-9677-4a29fed26b79', '3a1c37c8-e698-4a09-954e-a30391edb3e6', 'material', 5, 'Gram', 0.65, 1, null, null),
('d38cc4a5-490c-42e6-b87e-7b5e4f055bf5', '4b517e37-caf1-4af1-9677-4a29fed26b79', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 25, 'Gram', 1.26, 2, null, null),
('75898c60-cc94-4dd8-87e3-cb7cabdaf7cf', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'ea7698c8-d33d-4b08-8625-c24a99d9da61', 'material', 20, 'Gram', 1.61, 3, null, null),
('0bf74105-e059-4da2-b8fc-1e16194a62e1', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'c083a251-d190-46d5-9225-31076a59b63b', 'material', 20, 'Gram', 7.97, 4, null, null),
('8be6cfa1-8c01-470a-ac17-a270a1ad58c3', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'd61d94d2-d7d1-43f2-8f1a-d86a1e110526', 'material', 300, 'Gram', 60.2, 5, null, null),
('9e5787de-8be4-480e-8a9d-b92cc59a4e28', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 3, 'Gram', 0.94, 6, null, null),
('a29dc659-2cc8-4056-b2b1-33bf298deb87', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 7, null, null),
('4453ecc5-c2c6-4fba-94f2-43b7f80aa4fa', '4b517e37-caf1-4af1-9677-4a29fed26b79', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('7e87f78f-abbe-41a7-8bd1-ef390fbb6c38', '4b517e37-caf1-4af1-9677-4a29fed26b79', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('49123036-da1b-4d0d-9c1d-bb57e8c1a195', '4b517e37-caf1-4af1-9677-4a29fed26b79', '321437f4-b944-449e-a219-f791efaa1fcb', 'material', 5, 'ML', 1.31, 10, null, null),
('1c2166f6-2a0a-48b8-a81d-6d0b65d0ba8c', '4b517e37-caf1-4af1-9677-4a29fed26b79', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 4, 'Gram', 0.3, 11, null, null),
('f067ad84-aefe-435a-a017-695ef7ad7d38', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 22, 'ML', 3.14, 0, null, null),
('620c385d-149f-4af3-bb6a-71ca32b524e9', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'b71b149e-1531-474d-bd70-7b0e6ed178ca', 'material', 16, 'Gram', 0.37, 1, null, null),
('2e76cdb3-bc2d-47e3-a601-1414aecf6688', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'cc8a5df2-b49f-4ab6-8348-e0e5c2a03d77', 'material', 30, 'Gram', 6.72, 2, null, null),
('75572977-dd82-4edb-925f-7b9340d2b806', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', '120d4ad3-085f-4483-877a-7d2d31e49ba0', 'material', 30, 'Gram', 4.12, 3, null, null),
('70f84f59-d354-4d92-8c72-df8d368432cf', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', '61ebb76e-5dac-4813-89cd-acb368ee2dd1', 'material', 30, 'Gram', 1.8, 4, null, null),
('74ca8390-f0f2-43a2-8685-fb2e4d7646a9', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'd61d94d2-d7d1-43f2-8f1a-d86a1e110526', 'material', 300, 'Gram', 60.2, 5, null, null),
('92352bf7-4e23-4ee6-853f-45a846a72c5e', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 3, 'Gram', 0.94, 6, null, null),
('49d81ca2-cd0a-4c5f-8cab-e79a28226a35', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 7, null, null),
('d1e28091-f9c0-41f3-902c-059f9ddabe67', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('fbb954af-4ead-4c18-b79f-abb148e70fe2', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('f172360f-f711-4ad4-9224-13c03eccbf52', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'dbc1007b-0325-47fd-bf17-92289758a28d', 'material', 8, 'Gram', 1.6, 10, null, null),
('02c53b8c-e9db-470e-b913-5c1ad29677f6', '8ee34023-1772-45f8-aa2e-20d8aac60c0b', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 4, 'Gram', 0.3, 11, null, null),
('3e9ead13-8841-43b0-b649-f2af6b912122', '8ac7b402-992a-4520-8739-301daf348edd', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 15, 'ML', 2.14, 0, null, null),
('216e9a79-c1f7-4710-91f2-3163c0579f40', '8ac7b402-992a-4520-8739-301daf348edd', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 15, 'Gram', 2.73, 1, null, null),
('bc17b6a7-d7a5-40cc-8bc6-a1dcc4b75e44', '8ac7b402-992a-4520-8739-301daf348edd', '1123d9d7-46f6-489a-bedb-a0b4a4c4c177', 'material', 60, 'Gram', 8.87, 2, null, null),
('329a3294-6254-495c-a016-3d69e07141b8', '8ac7b402-992a-4520-8739-301daf348edd', '70a25e26-9b31-484b-8050-cda6bace69dc', 'material', 2.5, 'Gram', 1.06, 3, null, null),
('90c62b02-6dac-46e3-b589-290747abc8c8', '8ac7b402-992a-4520-8739-301daf348edd', '38fae6a9-cbed-41ad-ab53-e81ae3fa41f6', 'material', 5, 'Gram', 1.4, 4, null, null),
('6808b872-5baa-486d-9557-a5ca8cef1efe', '8ac7b402-992a-4520-8739-301daf348edd', '3be12901-de36-4cf8-9eaf-285577602b5c', 'material', 2.5, 'Gram', 0.5, 5, null, null),
('b0fa8476-5a2b-4d0d-8395-10f1e51ae413', '8ac7b402-992a-4520-8739-301daf348edd', 'd61d94d2-d7d1-43f2-8f1a-d86a1e110526', 'material', 300, 'Gram', 60.2, 6, null, null),
('421cfafb-704f-4b17-b00c-6b96eeee6fa2', '8ac7b402-992a-4520-8739-301daf348edd', 'c083a251-d190-46d5-9225-31076a59b63b', 'material', 20, 'Gram', 7.97, 7, null, null),
('048b3a59-faa3-48de-ab3e-4c7b3086188c', '8ac7b402-992a-4520-8739-301daf348edd', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('554b6d02-9a78-42f5-9d55-af64ce4f700c', '8ac7b402-992a-4520-8739-301daf348edd', 'df7f34a1-3625-4a1d-a55d-965d2bb5af53', 'material', 5, 'Gram', 83.35, 9, null, null),
('ff2aa295-39fa-42be-a4b7-6a4251ec6bcb', '8ac7b402-992a-4520-8739-301daf348edd', '910522b2-9199-4fec-add4-296db690dd3f', 'material', 2.5, 'ML', 14.12, 10, null, null),
('21a33753-2a58-4bf4-8e8c-9828ea99fa85', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 22, 'ML', 3.14, 0, null, null),
('7b9c976b-a59f-4817-bc67-4905c29cf678', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'a2c0276a-731c-47cd-ae50-e1534a459e11', 'material', 5, 'Gram', null, 1, null, null),
('ad06d1f6-9e12-4521-9c5a-0b316e0049d8', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', '33728a74-16c5-46f1-bc23-da7deb4a007c', 'material', 30, 'Gram', 2.62, 2, null, null),
('1b6da0bb-1b5b-4929-8626-e1de308aa61c', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 30, 'Gram', 1.52, 3, null, null),
('56020feb-67bb-45a2-99d3-404a927395b3', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'b8192aac-7dea-4e6d-9d2f-def25e6140e9', 'material', 30, 'Gram', 0.93, 4, null, null),
('191fbdd7-7030-4e99-94a7-d97044b2dabd', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', '1570a68a-7c5a-4b91-9f9a-2fa8a75682b1', 'material', 140, 'Gram', null, 5, null, null),
('b31abd9c-7474-41f3-9d98-f86f0f25fcdd', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'e4c5ac8f-46b2-4d17-bf18-03aee7d59afe', 'material', 30, 'Gram', null, 6, null, null),
('25b45baa-3381-4d87-b070-2fdcf3378d31', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 3, 'Gram', 0.94, 7, null, null),
('7d93f443-0788-4aa0-9e1b-f617f4880f04', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 8, null, null),
('6ca89ae6-f16c-4586-98d6-b1facf5f4a79', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 0.5, 'Gram', 0.5, 9, null, null),
('a8b477cc-8303-47a9-baa7-d1d8a633eb34', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 0.8, 'Gram', 0.27, 10, null, null),
('96304966-d608-4d65-9463-44601618d252', 'fe29e2e2-ed15-4f02-b051-4bd854d472d7', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 4, 'Gram', 0.3, 11, null, null),
('4fb698bb-c40d-4949-9de9-c4d61070878a', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 22, 'ML', 3.14, 0, null, null),
('e1a8e5f0-d30c-4f00-be1f-e592c3d444c8', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 1, null, null),
('5a8d8f2e-e43e-49bd-8c68-49b64a330fda', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 4, 'Gram', 4.25, 2, null, null),
('4025bcbe-3510-405d-90c7-b9a3e3e5e4b5', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', '1c9af968-1d35-46b5-af10-231a5c215e0d', 'material', 60, 'Gram', null, 3, null, null),
('39807ed2-aad1-4bbd-ba5a-becc69cf032e', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', '6be246c8-a851-43b1-86ae-557baa3b65a6', 'material', 10, 'Gram', 0.75, 4, null, null),
('bbe3d9c6-4352-46d7-b9db-281d4b5ae131', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', 'c3707048-bfd2-43a6-98dc-2d1e1f75e615', 'material', 120, 'Gram', null, 5, null, null),
('b747b075-bd42-4804-a4e4-83f1c7587b34', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', '359ee41a-ec5f-40e6-a826-54a90998643f', 'material', 30, 'Gram', null, 6, null, null),
('3dc65837-07c2-4a05-81ea-26a857eb7937', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', 'ad7a54b5-2ad1-40af-81bd-26670da157db', 'material', 30, 'Gram', 10.28, 7, null, null),
('407976e7-affc-4650-9219-dcf1b6ec6cae', '2f60f646-ed1f-4b30-80b1-b978adc5c6bb', '74702423-2051-4375-8501-392654b9b2b1', 'material', 5, 'Gram', 1.6, 8, null, null),
('88cd2d10-1416-40b4-9260-ef02f63ef889', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'b9ba2c84-0ec1-42da-b9a8-de3efce268e8', 'material', 22, 'ML', 3.14, 0, null, null),
('dd285e5e-6b3d-4ac0-a816-1b633cfa384d', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'a2c0276a-731c-47cd-ae50-e1534a459e11', 'material', 5, 'Gram', null, 1, null, null),
('ba25833f-ee52-40f1-95d8-db0262af6809', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', '8b88406e-4b70-4056-b390-5f54f51d914f', 'material', 60, 'Gram', 8.87, 2, null, null),
('4a8fb598-9b16-4997-8706-1b6f80801a98', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 'material', 30, 'Gram', 1.52, 3, null, null),
('4232b361-e8a0-4cba-9888-61602f50b737', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', '3179d1e0-5238-4f20-bb1e-29666048ddc9', 'material', 150, 'Gram', 35.23, 4, null, null),
('3a078f4c-65e5-4c90-a4c7-e27cef6ef019', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'f913dd9d-b117-4643-b7a4-fa256c04ad9a', 'material', 40, 'Gram', null, 5, null, null),
('7568a2d6-1c8a-42ac-b927-2279653aef46', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'ad7a54b5-2ad1-40af-81bd-26670da157db', 'material', 30, 'Gram', 10.28, 6, null, null),
('27b2f77e-763f-4017-99c5-ebf87e1254a5', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 10, 'Gram', 0.75, 7, null, null),
('e812628c-b406-4bee-b884-4794ab3740c5', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', 'ba53882c-31ec-40fb-aef8-a8d12ab060b2', 'material', 15, 'Gram', 2.89, 8, null, null),
('c783d392-e89c-4a68-9d38-a80931c6222c', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 5, 'Gram', 0.36, 9, null, null),
('90c0ffb2-e6cb-4701-84e5-c11a414110e4', 'df1c5d71-cbf0-4663-bd83-99d2509fc0d7', '6c237f38-aceb-4d82-abb1-a7377cda111f', 'material', 1, 'Piece', 0.1, 10, null, null),
('f70e7861-3576-406e-9ec2-33d6f34668bf', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '83636a77-655c-4502-b909-6ba0abb0d28b', 'material', 90, 'Gram', null, 0, null, null),
('d8b3cffe-b003-4da9-b047-14bc4987406f', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'dcf5b666-811f-44b7-9bea-bd462a1a2d3a', 'material', 120, 'Gram', null, 1, null, null),
('4ea065c6-f0ef-4a87-9594-63994940d778', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '6bd212b5-caac-4e54-b0a3-d36414f9a352', 'material', 40, 'Gram', null, 2, null, null),
('02a6b535-17b2-4b78-ad93-b31852cbd9da', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '9f8af8dc-ede5-4bf1-afb5-8b0864f1c811', 'material', 30, 'Gram', null, 3, null, null),
('98671a90-5992-4af6-9006-1875f730e0ba', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 1, 'Gram', 1.06, 4, null, null),
('68f29779-b74b-4a04-9e07-d3fbba93d57a', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 5, null, null),
('485368f8-70f3-41a8-8d6b-29c93d66ddbd', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 2, 'Gram', 0.67, 6, null, null),
('709b5592-23b6-4575-9e04-673150d27c9e', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 2, 'Gram', 2, 7, null, null),
('15483a88-9b0e-497b-9a81-a75a50879302', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'e5ff968a-02fd-4c7a-b5d4-d3bc13ef8a86', 'material', 7, 'Gram', 1.33, 8, null, null),
('ea256be6-e4e6-4d3b-8ff1-7e912def44c1', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'ea7698c8-d33d-4b08-8625-c24a99d9da61', 'material', 20, 'Gram', 1.61, 9, null, null),
('9e20a4c0-48d0-4c66-96e8-e3393297a441', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '33728a74-16c5-46f1-bc23-da7deb4a007c', 'material', 20, 'Gram', 1.74, 10, null, null),
('4014562f-62a2-4e6c-8666-2e1a9923ee79', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'ad7a54b5-2ad1-40af-81bd-26670da157db', 'material', 10, 'Gram', 3.43, 11, null, null),
('779f64a3-3df7-442c-aa0d-e1444ee66500', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 15, 'Gram', 1.13, 12, null, null),
('6a66e076-9d86-4b6f-bf5e-d962cc06e11a', 'f7fa1722-0a61-45e9-a075-6dcf0b76eb49', '0acf8f6a-15a0-431c-8a22-caec195c7fc8', 'material', 2, 'Gram', null, 13, null, null),
('37d32491-def1-47c3-bf91-f6bc44f5bcd0', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'a40de1bf-feee-43d6-851a-9294c3f97d95', 'material', 20, 'Gram', 2.09, 0, null, null),
('5da8a956-0203-406f-985e-b34b7845637b', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '5e99105e-27cd-4977-a50e-1b894af00d71', 'material', 10, 'Gram', null, 1, null, null),
('922f2dcc-c2e3-4be7-a74b-85ff88019860', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '8381b475-79df-4fef-b2e7-66fb3fca7c32', 'material', 10, 'Gram', 1.8, 2, null, null),
('4e761f04-b1c6-4b1c-b09e-71f9be10ca11', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '69bf50a8-ef47-4914-bc5b-a99b82f99dca', 'material', 20, 'Gram', 12.96, 3, null, null),
('475077e4-c194-4f8d-a7f4-7bf1f93e46ea', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '4e397512-96ef-40ee-a107-93aac2032ed5', 'material', 5, 'Gram', 4.49, 4, null, null),
('035b4143-f398-4d25-82e3-dbef1dae91d6', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'd2a903d7-a457-4a07-a015-eb7e62415ffb', 'material', 40, 'Gram', 17, 5, null, null),
('5d229159-ccc3-4f7a-9313-864ff054a9a2', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '7b39beae-2d3a-422f-9639-8560c9dc04fb', 'material', 40, 'Gram', 16, 6, null, null),
('a6c057f3-4401-4aef-b8a0-999b850c9883', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 350, 'Gram', 0, 7, null, null),
('5bfc3d77-49dc-41c5-b7e8-deae853bded0', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'eb3d07d2-1f20-40ce-b940-cb92af9eb557', 'material', 90, 'Gram', null, 8, null, null),
('3cb730ff-aa9f-45e3-a055-c37aca7180b4', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 5, 'Gram', 1.56, 9, null, null),
('5773c297-a974-4dfb-b7e8-b97fa09cdf2e', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 3, 'Gram', 1, 10, null, null),
('a032c8ce-b81b-49da-add9-acc4e8ee68c7', '784ad13a-25bc-41a5-8d1d-dafb8d655452', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('bf2c415f-47f4-4fe6-a2b1-5566e661043b', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 12, null, null),
('f4dbb113-4abe-47fb-a941-c58c12a9df1c', '784ad13a-25bc-41a5-8d1d-dafb8d655452', 'daab5d2f-4e8f-4453-a318-ab54f5ba0b83', 'material', 10, 'Gram', 0.8, 13, null, null),
('8f9dbd68-403e-4f22-a2b6-8f4c02046fd3', '3d49dbcb-368a-472f-948a-0840e70a9631', 'a40de1bf-feee-43d6-851a-9294c3f97d95', 'material', 20, 'Gram', 2.09, 0, null, null),
('057a6105-051a-49f0-8a37-0f854735286e', '3d49dbcb-368a-472f-948a-0840e70a9631', '5e99105e-27cd-4977-a50e-1b894af00d71', 'material', 10, 'Gram', null, 1, null, null),
('52c53a9c-e817-4d15-8060-c4011d9fea36', '3d49dbcb-368a-472f-948a-0840e70a9631', '8381b475-79df-4fef-b2e7-66fb3fca7c32', 'material', 10, 'Gram', 1.8, 2, null, null),
('a357374e-6744-48c3-bec2-bac7333019ef', '3d49dbcb-368a-472f-948a-0840e70a9631', '69bf50a8-ef47-4914-bc5b-a99b82f99dca', 'material', 20, 'Gram', 12.96, 3, null, null),
('0fdb90f0-8816-44d1-a95d-e671ee9d3f9b', '3d49dbcb-368a-472f-948a-0840e70a9631', 'd2a903d7-a457-4a07-a015-eb7e62415ffb', 'material', 40, 'Gram', 17, 4, null, null),
('f3ab8a30-487c-4728-95ff-25fe78550ccd', '3d49dbcb-368a-472f-948a-0840e70a9631', '610d323e-53b9-497f-aa27-918be6e504ed', 'material', 5, 'Gram', 5.33, 5, null, null),
('1cf547d4-bbb5-491e-8aa2-6d52473bea71', '3d49dbcb-368a-472f-948a-0840e70a9631', '1df679cd-076b-4384-9f0e-5150628a6d44', 'material', 350, 'Gram', 0, 6, null, null),
('e8317091-de9a-466d-835c-8534785c8ee7', '3d49dbcb-368a-472f-948a-0840e70a9631', '7b39beae-2d3a-422f-9639-8560c9dc04fb', 'material', 40, 'Gram', 16, 7, null, null),
('eaced8d0-f147-49ec-9cf8-7aa7febd36a2', '3d49dbcb-368a-472f-948a-0840e70a9631', 'eb3d07d2-1f20-40ce-b940-cb92af9eb557', 'material', 90, 'Gram', null, 8, null, null),
('b05041dd-3229-4b7b-b069-5b4b399c04d8', '3d49dbcb-368a-472f-948a-0840e70a9631', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 5, 'Gram', 1.56, 9, null, null),
('34bc4f83-c7b6-4f65-b13a-e0ce701384e5', '3d49dbcb-368a-472f-948a-0840e70a9631', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 3, 'Gram', 1, 10, null, null),
('04522409-f4ee-4ecd-914f-49cb650fd6fb', '3d49dbcb-368a-472f-948a-0840e70a9631', '6d0d992e-fafd-41c5-911e-7e893980a853', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('b593fadd-7a8e-481f-a1f4-bf8c64b9e7a5', '3d49dbcb-368a-472f-948a-0840e70a9631', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 12, null, null),
('fc0064ec-e7e5-4b30-b28e-719ef2e52485', '3d49dbcb-368a-472f-948a-0840e70a9631', 'daab5d2f-4e8f-4453-a318-ab54f5ba0b83', 'material', 10, 'Gram', 0.8, 13, null, null),
('53af7a50-4c56-4851-99f3-44c40972f4d7', '3d49dbcb-368a-472f-948a-0840e70a9631', 'f3af9fbd-df2b-407c-a451-2059d9fbf480', 'material', 20, 'Gram', 3.85, 14, null, null),
('efa5eef8-f2a2-4339-a7ef-bef42364fd2f', '3d49dbcb-368a-472f-948a-0840e70a9631', '43b0bd9e-e432-41f8-b9f9-70e8f2f8a2f7', 'material', 6, 'Gram', 0.43, 15, null, null),
('c13430d0-6639-474c-b27d-3f9c944e659c', '3d49dbcb-368a-472f-948a-0840e70a9631', '684c7e70-a6f0-453c-8230-f322fa8192eb', 'material', 18, 'Gram', 1.36, 16, null, null),
('77da90d7-fc14-47e9-be6d-0478efebe230', '3d49dbcb-368a-472f-948a-0840e70a9631', '1d522837-82b1-48f4-b92b-c563629ac746', 'material', 30, 'Gram', 13.5, 17, null, null),
('d4b10781-688d-4d3b-849a-b35cf79ecd31', '3d49dbcb-368a-472f-948a-0840e70a9631', 'e51aaee4-3e6a-4a4d-90b4-39e1da49fde8', 'material', 10, 'Gram', 1.19, 18, null, null),
('df88c9a7-97e6-4f99-a202-b5cf57a85186', '3d49dbcb-368a-472f-948a-0840e70a9631', '0f23d4ce-f18c-47c6-9fdd-b121076534e0', 'material', 2, 'Gram', 0.2, 19, null, null),
('5b66cbd3-6675-4a85-839e-84d82a5c5d1e', '3d49dbcb-368a-472f-948a-0840e70a9631', 'c9fc5068-eedf-4da2-ab57-0aa719f571aa', 'material', 1, 'Piece', 0.1, 20, null, null),
('eb989f17-249c-4415-b059-ebdd53586338', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', 'c671e654-5db5-40de-8838-b6a6c6ca9f2a', 'material', 30, 'Gram', 16.14, 0, null, null),
('663f12cd-9cae-4436-bc53-101891e09df2', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', 'd7ef81e5-47e1-4de0-9159-cef047743d95', 'material', 10, 'Gram', 1.82, 1, null, null),
('76ba2fa9-6617-40d2-bc6a-c453845d8205', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', '622dfab0-bfd4-4a8e-a061-e7f555f65eee', 'material', 4, 'Gram', 4.25, 2, null, null),
('2bcacfa4-646e-40be-91bb-fed9426cda04', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', '5ca86f40-4506-4e2d-8e90-41eefee0ea8b', 'material', 12, 'Gram', 1.92, 3, null, null),
('fc3194f7-4a46-4c2d-b34e-122747343cab', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', 'de17b0af-ee7b-4ab9-83bf-c6165c4683e8', 'material', 3, 'Gram', 0.94, 4, null, null),
('bf0d1563-7b52-4282-8ab3-0a768a858ecd', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', 'c80877b8-3467-45d4-a3c6-0c672874cf74', 'material', 2, 'Gram', 0.06, 5, null, null),
('ba1a3ecf-ea85-4ff8-a178-a336d1c03808', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', '8ce91ec7-f7d7-45ec-83af-ef5d8178c6db', 'material', 0.8, 'Gram', 0.27, 6, null, null),
('c7a9aaba-674d-4ff8-994d-6360cc027c21', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', 'd6b3a0ce-c4f4-483b-82d2-d0b8eb2cb504', 'material', 140, 'Gram', null, 7, null, null),
('b079fea8-592e-4763-88ac-5f30bfff7585', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', '8d73f9ba-27f5-4e4c-8a35-79df1fcfa467', 'material', 5, 'Gram', 0.38, 8, null, null),
('eff135bb-2599-42de-b677-658df189ce24', 'bf288cfc-7d7e-4868-9db5-32047cef29ec', '1a98bbba-ba21-4d16-8fc0-971760394309', 'material', 5, 'Gram', 0.91, 9, null, null),
('6547ce31-c738-4225-b595-bc8bd7053c61', '5870ecb5-7306-447a-8f5e-8aca60e39b41', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('2224bc0a-23ed-4408-951a-f80b11d8db89', '5870ecb5-7306-447a-8f5e-8aca60e39b41', 'b45d7a25-7a53-458f-813a-0e79be62783e', 'material', 150, 'Gram', 35.91, 1, null, null),
('16fec250-d4fc-4ccf-901a-559754e21980', '5870ecb5-7306-447a-8f5e-8aca60e39b41', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 50, 'Gram', 1.38, 2, null, null),
('19c3dd3a-7153-44cc-85ec-08d52df0a213', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 30, 'Gram', 5.47, 3, null, null),
('df252372-2c5e-4a16-8449-d1709ec06816', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '1f98c747-ac43-4825-b8de-9f09be5683b4', 'material', 6, 'Gram', 7.2, 4, null, null),
('42ab70c9-2f49-4625-aa9e-b37fc70d4be3', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 5, null, null),
('98e19cc7-5e46-4779-b485-165ec144d0a8', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '1123d9d7-46f6-489a-bedb-a0b4a4c4c177', 'material', 70, 'Gram', 10.35, 6, null, null),
('4da99492-b3d7-49d4-afce-60ed0b0d7bb3', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '23eabb64-56da-4b14-863a-9a1cc4009973', 'material', 50, 'Gram', 21.25, 7, null, null),
('095a894e-6769-4c9e-8ac3-3a79118ddff4', '5870ecb5-7306-447a-8f5e-8aca60e39b41', 'c07a62eb-4b49-4dd2-8f26-f46ef0c8bd2f', 'material', 30, 'Gram', 14.45, 8, null, null),
('ae75ce60-839e-4f9c-aa60-74a7ea20c6a4', '5870ecb5-7306-447a-8f5e-8aca60e39b41', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 9, null, null),
('3d704a30-c62e-4970-905d-5b74173c6e25', '5870ecb5-7306-447a-8f5e-8aca60e39b41', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 10, 'Gram', 0.75, 10, null, null),
('0ebe998e-631d-464d-bf5e-34906e747543', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('f54bed36-5d22-44ef-b65b-aa0545eda099', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'b45d7a25-7a53-458f-813a-0e79be62783e', 'material', 80, 'Gram', 19.15, 1, null, null),
('951c1716-7f2a-4e3e-b857-61abd4161604', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 30, 'Gram', 0.82, 2, null, null),
('12c05b14-feed-4cba-9e22-f6e5ccbdcad7', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 20, 'Gram', 3.65, 3, null, null),
('17af883c-7201-4388-b5cf-c66f7ee947be', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '1f98c747-ac43-4825-b8de-9f09be5683b4', 'material', 4, 'Gram', 4.8, 4, null, null),
('b83669bf-1c52-4d3a-8d9c-573650943e0d', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 5, null, null),
('14abea69-15cb-4146-88b6-93a5f3da6d7f', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '1123d9d7-46f6-489a-bedb-a0b4a4c4c177', 'material', 50, 'Gram', 7.39, 6, null, null),
('1653daa8-dace-49a5-a9b2-e7e890555f82', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '23eabb64-56da-4b14-863a-9a1cc4009973', 'material', 20, 'Gram', 8.5, 7, null, null),
('10056c00-541f-426f-a5c1-c7bc98d02675', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'c07a62eb-4b49-4dd2-8f26-f46ef0c8bd2f', 'material', 20, 'Gram', 9.63, 8, null, null),
('cc4a2675-0a1b-4855-a54e-3980b76f4c22', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 9, null, null),
('225743df-f105-4dea-aba4-cea9073a69fe', '12e2e9a6-d1d3-4aa0-8645-32abef90f359', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 8, 'Gram', 0.6, 10, null, null),
('49849c83-02d6-4ca1-a10d-4fde9beda220', '193c332b-2d69-4e57-8191-94fe2192dac8', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('b803d2a4-d36f-4493-bfb8-0f261bf455dc', '193c332b-2d69-4e57-8191-94fe2192dac8', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('9fe5fbd5-94ae-4a23-98a2-299f7c1a1412', '193c332b-2d69-4e57-8191-94fe2192dac8', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('c382f7f5-9a52-4fcc-84f4-9da5f33a0307', '193c332b-2d69-4e57-8191-94fe2192dac8', '352ccd94-c060-4012-b8dd-3aa8b30d8f64', 'material', 30, 'Gram', 8.57, 3, null, null),
('6c5122c7-5a17-48a5-a6b2-0502783a36e7', '193c332b-2d69-4e57-8191-94fe2192dac8', '5fac1058-2167-4228-90f0-ebef4e23b763', 'material', 20, 'Gram', 6.25, 4, null, null),
('9a3ca867-7f1b-4a72-9f5f-f226d49685b2', '193c332b-2d69-4e57-8191-94fe2192dac8', 'e5a909f3-f5fd-493a-bd59-769c6bd83cc3', 'material', 100, 'Gram', 17.19, 5, null, null),
('8b5666c0-5a81-458f-8a26-69c49ba93d2d', '193c332b-2d69-4e57-8191-94fe2192dac8', '1ca8f1ff-2b10-46fc-a3d6-2258da9439e5', 'material', 50, 'Gram', 51, 6, null, null),
('0f36cb88-b6f8-41ab-9cef-1c257a86f7f9', '193c332b-2d69-4e57-8191-94fe2192dac8', 'c88f8e4d-d040-4eaa-8dc0-befccef05308', 'material', 50, 'Gram', 1.38, 7, null, null),
('a18d4056-58d5-4e94-9f13-ed4c676cd157', '193c332b-2d69-4e57-8191-94fe2192dac8', '158fc248-9c91-4749-ba44-e387deef2190', 'material', 20, 'Gram', 15.5, 8, null, null),
('d13d7f58-2ebb-4b00-91ff-97e5b9495d3f', '193c332b-2d69-4e57-8191-94fe2192dac8', 'df1c63b1-3355-4382-b149-49b0a2159acf', 'material', 20, 'Gram', 9.25, 9, null, null),
('83668c5e-b1aa-41f6-a445-f47cf881ba40', '193c332b-2d69-4e57-8191-94fe2192dac8', '94427f65-c7f1-415b-a919-263dec4239ca', 'material', 20, 'Gram', 2.43, 10, null, null),
('5928e1e8-6492-41e2-86f6-04ad722f7af5', '9d348f91-6bae-4726-ade7-872b5f09eb37', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('5653c502-3ea8-418c-9990-05c7e60b0fa7', '9d348f91-6bae-4726-ade7-872b5f09eb37', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('669e07c3-2cf5-48ee-8c6b-a942831e1dee', '9d348f91-6bae-4726-ade7-872b5f09eb37', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('d025eb2d-f879-4c21-9430-e77003057568', '9d348f91-6bae-4726-ade7-872b5f09eb37', '352ccd94-c060-4012-b8dd-3aa8b30d8f64', 'material', 20, 'Gram', 5.71, 3, null, null),
('b3a5ca23-5285-4878-b054-fa84f1ada4a5', '9d348f91-6bae-4726-ade7-872b5f09eb37', '5fac1058-2167-4228-90f0-ebef4e23b763', 'material', 15, 'Gram', 4.69, 4, null, null),
('e7622745-0c3a-4a73-8159-e7ff8dc5b860', '9d348f91-6bae-4726-ade7-872b5f09eb37', 'e5a909f3-f5fd-493a-bd59-769c6bd83cc3', 'material', 70, 'Gram', 12.03, 5, null, null),
('327b2007-452d-4578-bc3c-441f263009bd', '9d348f91-6bae-4726-ade7-872b5f09eb37', '1ca8f1ff-2b10-46fc-a3d6-2258da9439e5', 'material', 30, 'Gram', 30.6, 6, null, null),
('de71776a-5f36-4850-815d-5d6a1b85358a', '9d348f91-6bae-4726-ade7-872b5f09eb37', 'c88f8e4d-d040-4eaa-8dc0-befccef05308', 'material', 25, 'Gram', 0.69, 7, null, null),
('bf15f88d-18b7-486c-9afb-02481941eae7', '9d348f91-6bae-4726-ade7-872b5f09eb37', '158fc248-9c91-4749-ba44-e387deef2190', 'material', 10, 'Gram', 7.75, 8, null, null),
('48a4051b-57f6-41e8-abb2-fefc1b6caffd', '9d348f91-6bae-4726-ade7-872b5f09eb37', 'df1c63b1-3355-4382-b149-49b0a2159acf', 'material', 15, 'Gram', 6.94, 9, null, null),
('3fe9f721-5f34-4389-8c53-794d80822cd3', '9d348f91-6bae-4726-ade7-872b5f09eb37', '94427f65-c7f1-415b-a919-263dec4239ca', 'material', 10, 'Gram', 1.21, 10, null, null),
('4bdb3e30-191e-49ac-81e6-96fb733fe57d', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('a03b9e0f-6b77-49d1-9c52-aadb645b6bca', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 1, null, null),
('a7db07bb-76d8-4ea0-af1e-eeca1f0c2128', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 20, 'Gram', 5.6, 2, null, null),
('e60b1c10-ad48-4636-8cf4-9297116abf4e', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 150, 'Gram', 31, 3, null, null),
('2fc4380c-902b-4b71-bfea-7a67fdfeebb7', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '8ae07204-8219-4283-b67b-10e18a4b2231', 'material', 40, 'Gram', 16.34, 4, null, null),
('b49d8dae-ce3d-493a-bc95-86a85f043fef', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 5, null, null),
('fddddfbd-fcdf-4663-859b-6601a75d01d1', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 6, null, null),
('1a8bb78b-27ba-40ad-856a-500ad069e60d', 'def5cafc-ba4b-4c0c-bb21-9a93af984901', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 25, 'Gram', 4.55, 7, null, null),
('d07bb887-ec5d-42ad-b830-5eeac0df5a48', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('c6f27805-634e-4982-9143-b4ded2c08bf2', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 1, null, null),
('70884f22-80e5-4b96-a99f-5babf5f3990f', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 10, 'Gram', 2.8, 2, null, null),
('ef6043ee-d067-4466-8dee-19cc1ed1e3f0', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 90, 'Gram', 18.6, 3, null, null),
('151eac13-d5d7-49bf-be65-875e16dfc7b5', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 10, 'Gram', 4.08, 4, null, null),
('53840150-28fd-4ff7-8083-ec4ea3ed21ac', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 5, null, null),
('08671c69-4fab-47cd-bbfe-ef277a479fbd', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 6, null, null),
('f548f3eb-b1da-46b3-8b53-81ede5bba024', '7afa9b26-4fd8-403f-be49-0eb13c5e93fc', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 20, 'Gram', 3.64, 7, null, null),
('56a6a0a3-9c33-4f0a-b046-cb08f81a46d9', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('41ea2632-d705-48d0-ae0b-9e636fcde4ec', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('47f1eb99-d422-4b62-8bed-edf3d119ac08', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '7708dfa8-2f54-40db-9231-1638e85043dc', 'material', 5, 'Gram', 1.09, 2, null, null),
('5d084184-3e22-40df-aa75-33866aad1195', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 5, 'Gram', 5.25, 3, null, null),
('951a9e8d-7bdb-4667-8518-b7851c8366df', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '92bcf2b0-62f1-475c-b60d-3b1baa0e664e', 'material', 130, 'Gram', 102.74, 4, null, null),
('8a5a7047-592d-4270-ad99-b781e55a8ea5', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '673983d2-d6ee-477b-9524-dc6cd75a6f39', 'material', 10, 'Gram', 4, 5, null, null),
('3157c326-df44-48e9-9f65-ed2446458954', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '5f21fc08-7cb3-45eb-a53d-9284e9723877', 'material', 5, 'Gram', 1, 6, null, null),
('681e71d4-c173-4511-a689-aedce8ce09ca', 'be0a757e-20f3-44e1-bb07-fda722fe0d02', '5638d2ae-1e20-422f-9785-2ff491225b08', 'material', 5, 'Gram', 23.33, 7, null, null),
('dbb4b798-ef49-4140-8694-a9d4b349db56', '382474ff-f701-4b45-9ac8-d937f4e2705b', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('e33f5dd3-a697-4e77-a2bf-8dda4bb000cc', '382474ff-f701-4b45-9ac8-d937f4e2705b', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('2910bb08-a4c4-4eb0-be31-2315605653b2', '382474ff-f701-4b45-9ac8-d937f4e2705b', '7708dfa8-2f54-40db-9231-1638e85043dc', 'material', 5, 'Gram', 1.09, 2, null, null),
('e3e438fc-d436-419c-941c-87d1dc2b5fc7', '382474ff-f701-4b45-9ac8-d937f4e2705b', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 5, 'Gram', 5.25, 3, null, null),
('496f5c44-2660-46c9-b989-7b1b45f267c7', '382474ff-f701-4b45-9ac8-d937f4e2705b', '92bcf2b0-62f1-475c-b60d-3b1baa0e664e', 'material', 80, 'Gram', 63.23, 4, null, null),
('d77623d2-d9ef-4509-a5e3-61771a1c994c', '382474ff-f701-4b45-9ac8-d937f4e2705b', '673983d2-d6ee-477b-9524-dc6cd75a6f39', 'material', 6, 'Gram', 2.4, 5, null, null),
('2864a353-9c5d-4252-b920-678de5b8869a', '382474ff-f701-4b45-9ac8-d937f4e2705b', '5f21fc08-7cb3-45eb-a53d-9284e9723877', 'material', 5, 'Gram', 1, 6, null, null),
('f06dbff8-328d-4cdd-b23b-d464aa7165a9', '382474ff-f701-4b45-9ac8-d937f4e2705b', '5638d2ae-1e20-422f-9785-2ff491225b08', 'material', 3, 'Gram', 14, 7, null, null),
('53ff798c-26db-4e74-98bf-796029c42b23', '32b67702-ac19-41e7-9446-74d58fd890d4', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('2a636a91-4a9d-4816-b920-606015258b8d', '32b67702-ac19-41e7-9446-74d58fd890d4', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 1, null, null),
('13d23ad7-ee91-47b1-a601-58c960b8e540', '32b67702-ac19-41e7-9446-74d58fd890d4', '95f00d97-a273-478f-b486-05111d81381f', 'recipe', 70, 'Gram', 7.95, 2, null, null),
('df0415f9-2777-4761-80dc-11a17a2defdc', '32b67702-ac19-41e7-9446-74d58fd890d4', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'recipe', 200, 'Gram', 35.71, 3, null, null),
('e6f34bd7-b578-41a4-9bd6-ad2c9a77af40', '32b67702-ac19-41e7-9446-74d58fd890d4', 'df195fb3-dc30-4d04-999f-a7b229f67e44', 'material', 170, 'Gram', 158, 4, null, null),
('1f7c8455-5560-4222-8004-a053250a4389', '32b67702-ac19-41e7-9446-74d58fd890d4', '9f20b495-00ce-4e56-9662-0f64cf8c6628', 'material', 10, 'Gram', 2.73, 5, null, null),
('8c65d9dd-f2ae-4a24-9718-2fac0bf8451c', '32b67702-ac19-41e7-9446-74d58fd890d4', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 10, 'Gram', 0.72, 6, null, null),
('be13ac63-913f-425a-8e8a-6b9d817a3fe0', '32b67702-ac19-41e7-9446-74d58fd890d4', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 10, 'Gram', 0.75, 7, null, null),
('798ddba4-8d5e-4b61-9b23-346722374440', '32b67702-ac19-41e7-9446-74d58fd890d4', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 10, 'Gram', 3.2, 8, null, null),
('bba89f1b-42c2-4e8a-aa89-9d62c6f2b783', '32b67702-ac19-41e7-9446-74d58fd890d4', '80f17bb0-97a1-45c5-9d7f-d6e910277c6e', 'material', 10, 'Gram', 0.7, 9, null, null),
('91e1ccde-e841-42af-9c18-de794f11efeb', '32b67702-ac19-41e7-9446-74d58fd890d4', 'e8b34652-b7b6-47d6-82a1-09b1048eff5d', 'material', 10, 'Gram', 1, 10, null, null),
('56544cf7-38ab-46d1-864c-f8d8d1ff6f82', '32b67702-ac19-41e7-9446-74d58fd890d4', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 11, null, null),
('546995aa-a6c6-494c-9384-0dfc013dbd9a', '09b5a3da-b552-47ad-af3d-8f37009b005c', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('4317538b-307b-4ac0-abd9-e327524fbe58', '09b5a3da-b552-47ad-af3d-8f37009b005c', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 1, null, null),
('1b8d0abb-5b9e-44de-9933-c362702c5682', '09b5a3da-b552-47ad-af3d-8f37009b005c', '95f00d97-a273-478f-b486-05111d81381f', 'recipe', 50, 'Gram', 5.68, 2, null, null),
('dd89cab6-0bd3-4f48-9181-3ad27621cdec', '09b5a3da-b552-47ad-af3d-8f37009b005c', 'f9bda125-40c4-4791-9c9b-1b11eb805304', 'recipe', 100, 'Gram', 17.85, 3, null, null),
('6dd0b6bb-51c4-49a5-90a5-30405aeecd94', '09b5a3da-b552-47ad-af3d-8f37009b005c', '92bcf2b0-62f1-475c-b60d-3b1baa0e664e', 'material', 130, 'Gram', 102.74, 4, null, null),
('efcb27d6-e082-4639-8fc3-158d7e540acc', '09b5a3da-b552-47ad-af3d-8f37009b005c', '9f20b495-00ce-4e56-9662-0f64cf8c6628', 'material', 6, 'Gram', 1.64, 5, null, null),
('6dabb13a-00c4-4803-9c5b-50d1ecc180e8', '09b5a3da-b552-47ad-af3d-8f37009b005c', '5f4c3ef5-fb87-48ae-9475-93e365cb3cc6', 'material', 8, 'Gram', 0.58, 6, null, null),
('b9fba7b9-d31b-4e30-b155-d8ae9d9da608', '09b5a3da-b552-47ad-af3d-8f37009b005c', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 8, 'Gram', 0.6, 7, null, null),
('69aafff4-dec4-4709-b7e9-5a01853cf6d3', '09b5a3da-b552-47ad-af3d-8f37009b005c', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 8, 'Gram', 2.56, 8, null, null),
('c073e6a5-d8c4-4cde-9008-0542462e6d1c', '09b5a3da-b552-47ad-af3d-8f37009b005c', '80f17bb0-97a1-45c5-9d7f-d6e910277c6e', 'material', 8, 'Gram', 0.56, 9, null, null),
('b8b88808-30fe-4b47-9b17-89c0721b9078', '09b5a3da-b552-47ad-af3d-8f37009b005c', 'e8b34652-b7b6-47d6-82a1-09b1048eff5d', 'material', 8, 'Gram', 0.8, 10, null, null),
('74e98030-2dab-47f0-8ae7-7a00edb73e85', '09b5a3da-b552-47ad-af3d-8f37009b005c', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 11, null, null),
('55c45b48-57ec-4675-9bd8-2169ee7e1fff', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('c7bd44dc-0daa-402c-842a-2472054b6e9a', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'a42cf520-68d6-4598-8b52-9e4374c916a8', 'material', 120, 'Gram', 29.12, 1, null, null),
('d36ef967-c4f4-419d-acb9-f280bf9ee0c3', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'a2b2b0b6-8d67-4d41-9042-5a275084ada8', 'material', 100, 'Gram', 59.92, 2, null, null),
('c196b5f8-9351-4ac1-960d-300ba468a737', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 20, 'Gram', 14.95, 3, null, null),
('9033b345-6b06-4349-b7a0-b77c13c46a51', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '12eb788d-89f4-47c7-8474-d351c892e46b', 'material', 120, 'Gram', 38.52, 4, null, null),
('faae2fdc-7d99-465e-9f15-f8da0259c3c4', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '91a2b87f-e187-4618-a3bc-b53f377b412c', 'material', 50, 'Gram', 4.01, 5, null, null),
('b3413333-329c-4a02-9cbb-1a29f79805d4', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '95e967fa-28b1-433a-a5fe-0aee85ed8b78', 'material', 30, 'Gram', 8.09, 6, null, null),
('b21458f8-b991-48fc-a344-c3edcffeb505', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '171b8d69-bacf-452a-a84a-d69758955a55', 'material', 10, 'Gram', 3.6, 7, null, null),
('2efaf882-2ebb-4331-bab0-a420ec13e9f2', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '26027f44-3125-4b73-9471-fb82a8be287e', 'material', 25, 'Gram', 12.73, 8, null, null),
('7cdda254-66b9-441e-a43d-bdab996075a4', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 5, 'Gram', 0.38, 9, null, null),
('75c84c73-4236-4e05-9ea9-a3090e30cac6', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', '4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'material', 2, 'Gram', 4, 10, null, null),
('24efc65c-7e7d-42b9-b726-8c556284bd53', 'cfd0e311-3e04-4d34-81a6-7398aea9c731', 'bef0357c-33ac-4d46-80d5-4083cd35c574', 'material', 20, 'Gram', 9.29, 11, null, null),
('b2ef5644-fd41-433b-a216-041477d24508', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('fe4d28fd-afbf-48e9-8156-fa4b0d93c4e8', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'a42cf520-68d6-4598-8b52-9e4374c916a8', 'material', 69.68, 'Gram', 16.91, 1, null, null),
('eacbfe0f-bce2-4053-a2c9-3bdf1ee9daf4', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'a2b2b0b6-8d67-4d41-9042-5a275084ada8', 'material', 58.06, 'Gram', 34.79, 2, null, null),
('18f78256-c627-419b-b36e-90b966f20819', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 11.61, 'Gram', 8.68, 3, null, null),
('d9e0e888-b6fd-4917-be74-d49a5331d484', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '12eb788d-89f4-47c7-8474-d351c892e46b', 'material', 69.68, 'Gram', 22.37, 4, null, null),
('24490984-4799-4b65-a26c-6525b45a6c3b', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '91a2b87f-e187-4618-a3bc-b53f377b412c', 'material', 29.03, 'Gram', 2.33, 5, null, null),
('f69622c9-c4b5-4839-9bfc-b37a1833769b', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '95e967fa-28b1-433a-a5fe-0aee85ed8b78', 'material', 17.42, 'Gram', 4.7, 6, null, null),
('6ce77163-e250-4e1d-91c3-35626a62c6d9', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '171b8d69-bacf-452a-a84a-d69758955a55', 'material', 5.81, 'Gram', 2.09, 7, null, null),
('27ff59a2-7b1e-4490-8003-a17dc2b8a7a7', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '26027f44-3125-4b73-9471-fb82a8be287e', 'material', 14.52, 'Gram', 7.39, 8, null, null),
('0a120bcc-2ae7-42b2-af5c-b63883251d58', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'f51230e9-c6ab-4994-b5ec-50a6977011cc', 'material', 2.9, 'Gram', 0.22, 9, null, null),
('f9f729ba-3cdb-4443-ab46-fc0932cda595', '23fba5e5-93ba-468c-8fd4-fdb906faaded', '4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'material', 1.16, 'Gram', 2.32, 10, null, null),
('5b53660d-7e37-47fe-9c67-0cff34dbb0d6', '23fba5e5-93ba-468c-8fd4-fdb906faaded', 'bef0357c-33ac-4d46-80d5-4083cd35c574', 'material', 11.61, 'Gram', 5.39, 11, null, null),
('fa24a168-debb-410f-8e45-7884b970bf8a', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('b75e52dc-3dc2-4e1d-a3a6-9a1d313b40a8', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('986f6939-6b91-4558-bb5a-32ec7d8190d5', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('2869a2e1-2e10-4ff3-8869-77d14095802d', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 3, null, null),
('428c1d73-a3c0-403d-b1ae-01a1d83636a6', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', 'bcde52da-bafc-4168-a3cf-7a930863218b', 'material', 50, 'Gram', 1.15, 4, null, null),
('bcc406da-adec-40a4-937f-4d5de938671c', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '991dd58f-8b7c-45d5-a48b-3f1e3fdfc113', 'material', 20, 'Gram', 0.46, 5, null, null),
('d655b7f5-5700-479b-a179-94161c2bd0e0', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 6, null, null),
('9e127f38-7556-4f72-a812-b87c6a30f0cc', 'e5070fe0-486d-48e1-bcd7-d1d9a5cd21d7', '1346710c-bcf0-450d-a8b1-1b4b75294fd9', 'material', 20, 'Gram', 4, 7, null, null),
('48bbc971-b7c9-4b50-9fb4-df578b8aaafa', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('ef772e0a-9f95-4db4-a288-8f69e1370f7a', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('d2b25535-71f8-4f83-8f28-e12a866d4fc1', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('11e5e617-5826-43c4-ad46-2f49f19bff9f', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 3, null, null),
('e5838359-cb0c-4e52-ac01-14e07dd1de54', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', 'bcde52da-bafc-4168-a3cf-7a930863218b', 'material', 40, 'Gram', 0.92, 4, null, null),
('125a64b4-3e38-4e6e-8f0d-1ca1cde5d3a9', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '991dd58f-8b7c-45d5-a48b-3f1e3fdfc113', 'material', 15, 'Gram', 0.34, 5, null, null),
('806be900-eead-4600-a685-50c2fbc67a90', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 6, null, null),
('7a8029b0-d007-4ab5-9722-6152e2142a6b', 'f3983170-7b43-44fb-98ed-6c8c2b4f91ba', '1346710c-bcf0-450d-a8b1-1b4b75294fd9', 'material', 10, 'Gram', 2, 7, null, null),
('970c7281-42f6-4603-be9e-acedfa61fe20', '578227ac-3be4-41f7-898a-3b63e78a164b', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('4b73fd81-ff18-4564-a43a-d22b7de8bb1f', '578227ac-3be4-41f7-898a-3b63e78a164b', '742e23f7-5803-448a-b155-30574f44e421', 'material', 120, 'Gram', 24.31, 1, null, null),
('dc051042-ed40-427b-aa1a-67dbd1777251', '578227ac-3be4-41f7-898a-3b63e78a164b', 'ee1e9825-df4b-4b73-b607-26e8e0709ef9', 'material', 30, 'Gram', 14.45, 2, null, null),
('5b330652-f312-4fa3-b3b5-0f47b4b216cd', '578227ac-3be4-41f7-898a-3b63e78a164b', 'd619cdce-a51a-430d-a3ea-fada494268fc', 'material', 100, 'Gram', 60.3, 3, null, null),
('be07548a-42f1-4255-a741-e1dfe040a55d', '578227ac-3be4-41f7-898a-3b63e78a164b', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 20, 'Gram', 14.95, 4, null, null),
('70953bf9-2660-44c8-b15d-01d3abdacfdb', '578227ac-3be4-41f7-898a-3b63e78a164b', '95e967fa-28b1-433a-a5fe-0aee85ed8b78', 'material', 30, 'Gram', 8.09, 5, null, null),
('56e454e6-4d60-479e-86b1-e7e203aa6999', '578227ac-3be4-41f7-898a-3b63e78a164b', 'c63a238a-4b8c-4e71-b1a6-3695e127b415', 'material', 10, 'Gram', 4.33, 6, null, null),
('6ecc99e6-ca51-4eb5-935e-77d9a0675c41', '578227ac-3be4-41f7-898a-3b63e78a164b', '4903a3a4-140f-4206-b913-dd22872d1bec', 'material', 25, 'Gram', 20.66, 7, null, null),
('9a8eca43-fa45-4e5e-9801-3c9211d9cd67', '578227ac-3be4-41f7-898a-3b63e78a164b', 'ddf87480-d990-4df4-b37e-a05bf95051f3', 'material', 25, 'Gram', 23.74, 8, null, null),
('6872d5a5-7e5e-4ce8-9b86-969d1c07bdc0', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('970b45ff-30f8-4fe6-981e-28f8f32939de', '6c817e52-4db7-4182-b242-c72116ca9e2e', '742e23f7-5803-448a-b155-30574f44e421', 'material', 69.68, 'Gram', 14.12, 1, null, null),
('a702ca64-d335-4c30-98bc-1944baaa114c', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'ee1e9825-df4b-4b73-b607-26e8e0709ef9', 'material', 17.42, 'Gram', 8.39, 2, null, null),
('3533028f-9398-457b-8f2f-b04bfc7d486d', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'd619cdce-a51a-430d-a3ea-fada494268fc', 'material', 58.06, 'Gram', 35.01, 3, null, null),
('5d32e5e8-e25c-4af5-936f-d25211bf1b8a', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'a103cc0c-3806-4a8e-857c-3e102bd09384', 'material', 11.61, 'Gram', 8.68, 4, null, null),
('7f03d167-da10-4a3c-8657-92da4b5b48c0', '6c817e52-4db7-4182-b242-c72116ca9e2e', '95e967fa-28b1-433a-a5fe-0aee85ed8b78', 'material', 17.42, 'Gram', 4.7, 5, null, null),
('e206efdf-3c2c-4a4a-b7b3-684a05bb1b16', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'c63a238a-4b8c-4e71-b1a6-3695e127b415', 'material', 5.81, 'Gram', 2.52, 6, null, null),
('ea60ba8f-22b8-4173-a488-eb15c3df0e95', '6c817e52-4db7-4182-b242-c72116ca9e2e', '4903a3a4-140f-4206-b913-dd22872d1bec', 'material', 14.52, 'Gram', 12, 7, null, null),
('1c4b7abd-10e7-4eb9-8af5-c5cb835ca48b', '6c817e52-4db7-4182-b242-c72116ca9e2e', 'ddf87480-d990-4df4-b37e-a05bf95051f3', 'material', 14.52, 'Gram', 13.79, 8, null, null),
('2e06adb6-7ed6-43b4-adaa-22306fee8021', 'd786acdd-218f-406d-911b-49fd0dd5951b', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('91f38a99-1f0f-4059-8b47-36c62dd4a11e', 'd786acdd-218f-406d-911b-49fd0dd5951b', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('44a27432-f963-4d53-88a2-bcf92e3b6edf', 'd786acdd-218f-406d-911b-49fd0dd5951b', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 2, null, null),
('9e9f7748-3ea8-4104-a81e-bde9d970be84', 'd786acdd-218f-406d-911b-49fd0dd5951b', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 120, 'Gram', 72.36, 3, null, null),
('5d8c019a-343a-4d78-97f2-98d2769b4a9a', 'd786acdd-218f-406d-911b-49fd0dd5951b', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 4, null, null),
('73c4637e-02c8-4756-a5ae-53c7c5d3d383', 'd786acdd-218f-406d-911b-49fd0dd5951b', '2cda9e2a-1805-442b-ad05-bbd9311a5b4e', 'material', 15, 'Gram', 19, 5, null, null),
('d5c9e2d6-0bea-4f1b-a2df-682e862e6cb7', 'd786acdd-218f-406d-911b-49fd0dd5951b', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 10, 'Gram', 10.5, 6, null, null),
('dd976170-5ef1-4b6a-94c6-e291064c88db', 'd786acdd-218f-406d-911b-49fd0dd5951b', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 7, null, null),
('24ffbdf3-6d43-453f-8cce-e02bce98dee4', '4d0cf748-6a08-45e0-877e-68e762f35621', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('ae373c05-40fd-498a-8c9f-4ec151cc6f6d', '4d0cf748-6a08-45e0-877e-68e762f35621', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('d6f1fc7e-a60c-4547-8bb4-b3ee01f20b0d', '4d0cf748-6a08-45e0-877e-68e762f35621', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 2, null, null),
('b297121a-e2ee-45c0-be29-61b806361107', '4d0cf748-6a08-45e0-877e-68e762f35621', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 70, 'Gram', 42.21, 3, null, null),
('d4f868ba-d050-4ef2-a08b-79d6638db085', '4d0cf748-6a08-45e0-877e-68e762f35621', '3c65a14c-ab36-4c1d-9344-697e3820fb01', 'material', 5, 'Gram', 1.6, 4, null, null),
('e7d3ab4c-aabe-45fd-ab4a-10f94aab9429', '4d0cf748-6a08-45e0-877e-68e762f35621', '2cda9e2a-1805-442b-ad05-bbd9311a5b4e', 'material', 8, 'Gram', 10.13, 5, null, null),
('cf5c982a-fece-401e-9842-c70d9aa88a86', '4d0cf748-6a08-45e0-877e-68e762f35621', 'c6a65b8f-df5c-48e8-8e75-0caacc4b1b4b', 'material', 5, 'Gram', 5.25, 6, null, null),
('02f710da-e143-4116-8593-343957d436e1', '4d0cf748-6a08-45e0-877e-68e762f35621', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 7, null, null),
('1734653d-4a21-443b-ad39-7f6e13288b0c', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('3f1475fd-ea13-46ed-97a7-a3344d41cd68', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 1, null, null),
('55aa15f7-0b09-4833-a54f-3e526158150c', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 25, 'Gram', 7, 2, null, null),
('030528fc-856c-47d1-aa5c-5eccb3ae4687', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 150, 'Gram', 31, 3, null, null),
('a1fa79ff-7a59-4a66-97ee-6dcddd38edf4', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 30, 'Gram', 12.24, 4, null, null),
('81eeb4fc-9fd2-4796-bfb1-1dbbb22baf66', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 5, null, null),
('e85c9b12-66d0-4764-97d0-8fc51df777e5', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 6, null, null),
('b06db609-7f0e-4744-ab65-7dcbd7b4df5b', '557b2ac5-4586-4fab-9c8d-7dd50757cae1', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 25, 'Gram', 4.55, 7, null, null),
('44b0e48a-9179-4513-9832-ecb9dcf01380', '96519c6c-4279-48ed-bb03-8b959071bddd', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('9bd2bc34-a504-449f-822d-323d163fa2f0', '96519c6c-4279-48ed-bb03-8b959071bddd', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 1, null, null),
('a656b341-d816-45a1-84f2-44be4b6ea213', '96519c6c-4279-48ed-bb03-8b959071bddd', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 15, 'Gram', 4.2, 2, null, null),
('c3cb257c-ff7b-4c76-9f9a-a83893ca30a8', '96519c6c-4279-48ed-bb03-8b959071bddd', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 90, 'Gram', 18.6, 3, null, null),
('abbf8d87-b2c3-4daa-a79d-7a7ceebd4632', '96519c6c-4279-48ed-bb03-8b959071bddd', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 15, 'Gram', 6.12, 4, null, null),
('56b66541-6658-45e9-b6f5-a5b51b51e2da', '96519c6c-4279-48ed-bb03-8b959071bddd', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 5, null, null),
('33456993-3ca1-4b04-94d7-79dba25c3534', '96519c6c-4279-48ed-bb03-8b959071bddd', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 6, null, null),
('be417460-5080-4a13-af88-6a8eaec62584', '96519c6c-4279-48ed-bb03-8b959071bddd', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 20, 'Gram', 3.64, 7, null, null),
('bf17ade4-1a88-4277-a09f-114f159d096c', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('12b910df-b2f3-44f4-b377-99ba161b3d85', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('3423ca63-ed1f-423e-8de8-7f0e149de116', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('e8f355d0-bb56-4d74-b053-a40fb1730946', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '88ffe768-cab0-4a50-a083-dbcafc9f8752', 'material', 30, 'Gram', 10.8, 3, null, null),
('6e82d65a-1d15-4f0d-b495-c91cbe4cae6d', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', 'e5355dae-dcbf-45c0-aa02-29c37516fb6c', 'material', 40, 'Gram', 24, 4, null, null),
('d5520ef6-d968-4e92-90f9-6802d15bf421', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', 'cc8a5df2-b49f-4ab6-8348-e0e5c2a03d77', 'material', 80, 'Gram', 17.92, 5, null, null),
('830abb1e-9d7d-4a2c-9059-9752e7723cbe', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '390bbf7d-c6eb-4dd3-8cbe-584a97c091e6', 'material', 100, 'Gram', 12.15, 6, null, null),
('6091bc3b-d0d5-40fd-a5d0-fdbd9aac8495', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '1f98c747-ac43-4825-b8de-9f09be5683b4', 'material', 10, 'Gram', 12, 7, null, null),
('3ce52bd5-4891-4ab8-b2cf-8de5e28b7a2e', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', 'c91d1e17-2a3a-4043-823b-85b4afd2fc57', 'material', 20, 'Gram', 10, 8, null, null),
('d91c3dee-0a28-4490-9a0e-aa0af0bbae9b', 'a318046d-c7b3-4aef-b95b-fecdbad306ae', '162a7177-11a9-4566-b701-8398104b9a86', 'material', 5, 'Gram', 4.17, 9, null, null),
('9255f1e9-4c99-4a28-80b5-3b9260a426ce', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('cc8dae74-2e7b-4711-9962-7f51f75fa436', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('5d23c396-3b31-4ec8-92cf-5015dc9a6832', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('9b7086d7-9c4f-41b0-a5ab-f70fa439ae4d', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '88ffe768-cab0-4a50-a083-dbcafc9f8752', 'material', 20, 'Gram', 7.2, 3, null, null),
('4900f370-9484-491d-8e0e-8a10be459e70', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', 'e5355dae-dcbf-45c0-aa02-29c37516fb6c', 'material', 25, 'Gram', 15, 4, null, null),
('c4ee9737-405d-4b9b-ae5a-d8150ff2b689', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', 'cc8a5df2-b49f-4ab6-8348-e0e5c2a03d77', 'material', 50, 'Gram', 11.2, 5, null, null),
('325a96cb-a234-45fb-abee-656b071d99a4', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '390bbf7d-c6eb-4dd3-8cbe-584a97c091e6', 'material', 70, 'Gram', 8.5, 6, null, null),
('7d00c936-dc23-46cd-b0b5-10d2cf44a248', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '1f98c747-ac43-4825-b8de-9f09be5683b4', 'material', 6, 'Gram', 7.2, 7, null, null),
('ecfd171c-ae11-4fd9-9324-8cf03bec183f', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', 'c91d1e17-2a3a-4043-823b-85b4afd2fc57', 'material', 15, 'Gram', 7.5, 8, null, null),
('745e18c9-730f-452d-8b1a-10f3f8d3353f', 'ce8e359f-9d0f-4084-a5c5-152cd9763211', '162a7177-11a9-4566-b701-8398104b9a86', 'material', 5, 'Gram', 4.17, 9, null, null),
('3ac121d0-02d9-4612-a198-3dd184951039', 'da15beb6-5a4e-48e7-b69a-996037b989cf', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('40d55513-24f8-4ba1-a71d-a068891eb975', 'da15beb6-5a4e-48e7-b69a-996037b989cf', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('ccb0e109-2700-4026-8ba9-7d451c82889d', 'da15beb6-5a4e-48e7-b69a-996037b989cf', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('66066386-4eae-4532-aec9-9e300661d491', 'da15beb6-5a4e-48e7-b69a-996037b989cf', '33728a74-16c5-46f1-bc23-da7deb4a007c', 'material', 70, 'Gram', 6.1, 3, null, null),
('c07152fb-7877-442e-8d22-39e84fd4bd54', 'da15beb6-5a4e-48e7-b69a-996037b989cf', 'e620724a-0223-4206-8f1a-f78e03233914', 'material', 10, 'Gram', 0.42, 4, null, null),
('869c8c45-1fc0-4e93-81f7-2ad85d88d3b2', 'da15beb6-5a4e-48e7-b69a-996037b989cf', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 'material', 50, 'Gram', 1.38, 5, null, null),
('4ee29ab3-712a-4679-9787-b1ff7b7ff1f4', 'da15beb6-5a4e-48e7-b69a-996037b989cf', 'bbe202d5-27ce-4ffa-bbcc-19937fe0f18d', 'material', 30, 'Gram', 6.41, 6, null, null),
('2dfca71b-4ad7-4e01-afde-bcd594b86d98', 'da15beb6-5a4e-48e7-b69a-996037b989cf', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 7, null, null),
('ea7b95b9-addf-454f-8f6b-6b393cd66775', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('3b34bd34-3aad-43e0-8661-36e2d8f9b3ad', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('26c86c2f-f871-4670-8473-b2e69f517319', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('543804b6-532b-4e9c-b771-a08aa470db10', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', '4d0fd5d1-ff62-4231-9540-4666f18d9a85', 'material', 50, 'Gram', 10, 3, null, null),
('85163620-9324-45b1-857a-ce0af09ac6bd', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', 'e620724a-0223-4206-8f1a-f78e03233914', 'material', 8, 'Gram', 0.33, 4, null, null),
('4f5ca0d8-3b45-42bc-b632-07e093224200', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', 'c88d0ae1-9e2f-4d72-bdfb-fa820ac2d8ed', 'material', 35, 'Gram', 0.96, 5, null, null),
('835024f0-cfb0-4199-821e-89aa03fe9c3d', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', 'bbe202d5-27ce-4ffa-bbcc-19937fe0f18d', 'material', 20, 'Gram', 4.28, 6, null, null),
('8654a6ba-af00-469c-ba6c-bf0c18b329c1', '598e2dd6-a2db-4540-bb5b-abcfbfa83fec', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 7, null, null),
('ee469483-a802-418e-a6e6-646678460640', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('700eba61-f2b8-4733-a6e2-78f75641f87f', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('37601fef-48af-477b-aa5f-c1e111b866a6', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('d0c5022b-7398-4a1f-b252-e84b57f75543', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', 'a4e13b20-9ba7-4ec3-9d43-227cebde4296', 'material', 10, 'Gram', 4, 3, null, null),
('47c5fcc6-cb4d-4f25-9d94-56b6cc291327', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '06997708-d333-4d2c-9bf0-0ef5e9182796', 'material', 1.5, 'Gram', 6, 4, null, null),
('a94625d0-23ec-4686-976c-a29da278fead', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '5ec7ee38-45f5-4028-8808-6d0f19a82faa', 'material', 40, 'Gram', 10.15, 5, null, null),
('d1ebae37-852d-41c3-920d-0693ff4bc2fa', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'material', 5, 'Gram', 10, 6, null, null),
('c44700cf-6c67-4a28-8fc7-f654c04e5463', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '352ccd94-c060-4012-b8dd-3aa8b30d8f64', 'material', 15, 'Gram', 4.29, 7, null, null),
('bc08a1c8-8f1a-4ff3-9ebe-9200a1bb612d', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', 'e620724a-0223-4206-8f1a-f78e03233914', 'material', 10, 'Gram', 0.42, 8, null, null),
('6306437e-126a-4659-a079-ae5e428dec75', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '0162100d-0a90-49be-a1b4-75fd9424996a', 'material', 15, 'Gram', 1.57, 9, null, null),
('70ccc575-e2a6-44db-b151-059c9003dde3', '6df54f96-93e2-4a42-bf4a-c799a3bb8cf2', '2d128e1f-0b74-4869-99fa-f2b89a5ba586', 'material', 25, 'Gram', 9, 10, null, null),
('970fe850-d362-4c3f-897a-58cd1c1d438d', '1c1976af-78cd-4099-b0f3-1afeb3da5236', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('258d6cc7-4e8c-4661-8d00-2ccd432b7476', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('373b80ba-86e0-4989-be72-00ae66df85ee', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('97f67d6d-0842-4cc4-b718-e0837696c25c', '1c1976af-78cd-4099-b0f3-1afeb3da5236', 'a4e13b20-9ba7-4ec3-9d43-227cebde4296', 'material', 6, 'Gram', 2.4, 3, null, null),
('1e61b9c6-600c-4367-8fed-45a3ce75c620', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '06997708-d333-4d2c-9bf0-0ef5e9182796', 'material', 1, 'Gram', 4, 4, null, null),
('6938743f-caca-481c-89ec-e8b8fcfa7dbd', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '5ec7ee38-45f5-4028-8808-6d0f19a82faa', 'material', 25, 'Gram', 6.35, 5, null, null),
('1bd0e06b-8c0b-4ef0-a3c7-4d6dc39d97cb', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '4194d6e6-704e-4496-a0fa-5196fe85c7c0', 'material', 5, 'Gram', 10, 6, null, null),
('6d9904ce-bbe6-4421-945f-0514773a149c', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '352ccd94-c060-4012-b8dd-3aa8b30d8f64', 'material', 15, 'Gram', 4.29, 7, null, null),
('52bc76ba-4f84-468a-9eeb-426a54c7b55e', '1c1976af-78cd-4099-b0f3-1afeb3da5236', 'e620724a-0223-4206-8f1a-f78e03233914', 'material', 7, 'Gram', 0.29, 8, null, null),
('0815439c-2349-41ed-963e-d05730f9a5b9', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '0162100d-0a90-49be-a1b4-75fd9424996a', 'material', 10, 'Gram', 1.05, 9, null, null),
('0dbd9cee-99ae-48dd-8d36-4b2b00c10872', '1c1976af-78cd-4099-b0f3-1afeb3da5236', '88ffe768-cab0-4a50-a083-dbcafc9f8752', 'material', 10, 'Gram', 3.6, 10, null, null),
('82404225-1418-441f-b1db-239f03de1c0c', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('8b68770e-ffd5-4573-951e-20a1d82c4e40', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 1, null, null),
('94744b1b-157e-43f8-ba2e-baa28976c96a', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', 'c115666f-52eb-4347-91de-dd65c5b1e3d0', 'material', 45, 'Gram', 15.54, 2, null, null),
('c887bca3-b9fa-46b0-81f7-4d59eecfedfd', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 150, 'Gram', 31, 3, null, null),
('3e03bd6e-e1c6-4030-9526-a0ed3cf5470c', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '8ae07204-8219-4283-b67b-10e18a4b2231', 'material', 30, 'Gram', 12.25, 4, null, null),
('9a97375c-b581-4aa9-ba66-36b7433593a2', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', 'f4d46e7b-f84a-45a9-b92d-8005a8858001', 'material', 2.35, 'Gram', 13.42, 5, null, null),
('339a19d1-2646-4873-9c4f-647a0f45fbc2', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 6, null, null),
('6b093519-94df-4e69-9e13-eaf6fb9f1586', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 25, 'Gram', 4.55, 7, null, null),
('b1f61aa1-a6b3-4aa5-9fcd-06b1d6a1e42a', 'c47188f7-fb2c-4fe0-9cfb-e519aa977779', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 8, null, null),
('926aff77-afe4-4a33-a92a-9ebcba91b0db', '917812f3-7b38-432e-9320-6d3cd8e27bc1', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('4108fe55-de6f-4042-80ff-e45053f5dd66', '917812f3-7b38-432e-9320-6d3cd8e27bc1', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 1, null, null),
('fce721e6-05a3-4198-a71b-3f52088e2d2b', '917812f3-7b38-432e-9320-6d3cd8e27bc1', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 25, 'Gram', 7, 2, null, null),
('c147741c-8a08-444d-8aa5-90e6d89e0a58', '917812f3-7b38-432e-9320-6d3cd8e27bc1', '6df88110-3968-4b86-a39e-b1b3381ba3f3', 'material', 90, 'Gram', 18.6, 3, null, null),
('b5b4642d-bf70-404d-8222-c361c0028aad', '917812f3-7b38-432e-9320-6d3cd8e27bc1', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 20, 'Gram', 8.16, 4, null, null),
('5e6f9a00-9886-48e2-992b-ed49956b4ff6', '917812f3-7b38-432e-9320-6d3cd8e27bc1', 'f4d46e7b-f84a-45a9-b92d-8005a8858001', 'material', 1.5, 'Gram', 8.56, 5, null, null),
('5b1c0835-00d9-4986-b2e9-9170691c33a2', '917812f3-7b38-432e-9320-6d3cd8e27bc1', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 6, null, null),
('b7a8a6f2-65a8-41da-aa33-b739dfc1a889', '917812f3-7b38-432e-9320-6d3cd8e27bc1', '720fcf8b-59ec-45fb-95ea-99f3615f58e8', 'material', 20, 'Gram', 3.64, 7, null, null),
('bb05cb4a-b597-4e06-9eac-91b079292ff4', '917812f3-7b38-432e-9320-6d3cd8e27bc1', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 8, null, null),
('ed02234a-1b49-4c0d-855c-655c83faf8e9', '081c3d3a-4802-4659-9d10-6ba9e9208785', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('6fabae10-a802-451f-b152-cc918fa57f00', '081c3d3a-4802-4659-9d10-6ba9e9208785', 'b45d7a25-7a53-458f-813a-0e79be62783e', 'material', 130, 'Gram', 31.12, 1, null, null),
('d27531b5-1977-4d30-9451-73297300c099', '081c3d3a-4802-4659-9d10-6ba9e9208785', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 80, 'Gram', 73.6, 2, null, null),
('c7918562-55cc-408f-99f5-ad4f6ebb64e0', '081c3d3a-4802-4659-9d10-6ba9e9208785', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 25, 'Gram', 10.2, 3, null, null),
('f769847a-ecb4-4504-840b-917713766417', '081c3d3a-4802-4659-9d10-6ba9e9208785', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 5, 'Gram', 1.4, 4, null, null),
('09819d59-2399-4d4b-b49e-cc26eeac6a7c', '081c3d3a-4802-4659-9d10-6ba9e9208785', '742e23f7-5803-448a-b155-30574f44e421', 'material', 50, 'Gram', 10.13, 5, null, null),
('afaa7683-0286-4158-8b13-7c61f8cb3e91', '081c3d3a-4802-4659-9d10-6ba9e9208785', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 6, null, null),
('08fed0d5-6dee-4606-b739-38c8b3b5fe84', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('9dcf560e-c195-49bf-b630-4ff59932ec71', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', 'b45d7a25-7a53-458f-813a-0e79be62783e', 'material', 60, 'Gram', 14.36, 1, null, null),
('5a0bcf8e-c1fa-47ef-99fd-d0417e2be8e4', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 60, 'Gram', 55.2, 2, null, null),
('e1cfa255-2a4c-4cd0-948d-b6a5e0596b43', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 15, 'Gram', 6.12, 3, null, null),
('1b88ecf7-ccac-44d9-b128-372e7f1ce1bc', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', 'e9b1df01-f1f8-4984-8cdf-e00b4cc979df', 'material', 3, 'Gram', 0.84, 4, null, null),
('6a27af96-2428-46c4-be8f-6d1dbcce6f24', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', '742e23f7-5803-448a-b155-30574f44e421', 'material', 30, 'Gram', 6.08, 5, null, null),
('fd48efd9-783a-4ba8-936e-2177019b30d9', '2ef6e1b2-4427-44c8-a5b2-e074273b7342', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 6, null, null),
('0c9151a0-0fad-4a6a-8a74-a509204c8448', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('f1c62ce4-9146-4369-b769-43e209786601', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('cdb217e6-7bc3-4a49-81cc-13702a98809a', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('5d832d87-3ff7-4efc-a158-580ef22572d4', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 40, 'Gram', 36.8, 3, null, null),
('08f72b8b-705f-4b81-affc-a6899281f60e', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', 'df1c63b1-3355-4382-b149-49b0a2159acf', 'material', 20, 'Gram', 9.25, 4, null, null),
('80ce4ab4-d931-4564-b324-db6a94831fc1', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '2d128e1f-0b74-4869-99fa-f2b89a5ba586', 'material', 50, 'Gram', 18, 5, null, null),
('097c5551-8c1c-43cb-a855-c503d30f6f38', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '79566a35-5a94-4dca-a1e8-f994cfdaf305', 'material', 40, 'Gram', 11.52, 6, null, null),
('8b7d1436-3160-4ccd-9ad4-8f6a2a02bc60', 'cd4e782a-b13f-4775-a1df-1a4e702a0409', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 7, null, null),
('9b6eaf26-ba51-467c-8e2c-ff9833cfdb7e', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('3577a6b1-d399-4de6-97ef-5ab1741e15e4', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('7d37e822-1da3-4986-bce2-940acb25e34c', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('3010bf9a-1455-4452-a07a-2882b13f0093', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', 'd82f502d-a1e6-4938-bbc3-8da5db50d03e', 'material', 15, 'Gram', 12.31, 3, null, null),
('975989f3-312c-4a7f-b33c-c792b5b09b57', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', 'df1c63b1-3355-4382-b149-49b0a2159acf', 'material', 10, 'Gram', 4.63, 4, null, null),
('d69917a3-80bf-4217-a1b1-69756f300587', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', '2d128e1f-0b74-4869-99fa-f2b89a5ba586', 'material', 30, 'Gram', 10.8, 5, null, null),
('a823ae84-735a-47a8-a379-34e92ee9cf08', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', '79566a35-5a94-4dca-a1e8-f994cfdaf305', 'material', 30, 'Gram', 8.64, 6, null, null),
('07cdd11f-332d-4796-93e2-3326096c71bb', '257f1aa0-98d1-4145-9e1f-3ec90fa88fcc', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 7, null, null),
('ef147e6b-9540-4f09-97c2-c3ad5e7c8ac1', 'b13a1530-286d-463f-8c01-d0ebedbedd91', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('7dcc6152-b1e7-4e3f-9078-f4ab4644ee37', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('226b58d1-3085-4d92-b9e0-91157492c476', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 2, null, null),
('1d1a82f3-9b6b-43d1-bd98-926f708f5f5a', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '9f77dac3-e200-4b5a-b21a-551b030f94f5', 'material', 50, 'Gram', 22.75, 3, null, null),
('098c5a46-2d5a-4a70-a789-f6d3a17cbcb2', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 30, 'Gram', 5.47, 4, null, null),
('e8b1b131-4db3-4a59-b2da-5723dcd3a68e', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '3c077485-48f9-482c-b392-15736a3508f4', 'material', 20, 'Gram', 6.25, 5, null, null),
('1ecfbe8e-231d-43af-9bd4-1b148f61d59d', 'b13a1530-286d-463f-8c01-d0ebedbedd91', 'f91abaaf-3c45-4e92-80f2-667a6bd20fa8', 'material', 30, 'Gram', 7.5, 6, null, null),
('c674eb97-4ee5-4c65-a322-c785e7d7b0c8', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'recipe', 25, 'Gram', 3.3, 7, null, null),
('d95f67fb-312f-4832-9d11-80dcbd226d2e', 'b13a1530-286d-463f-8c01-d0ebedbedd91', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 8, null, null),
('57118677-5bc1-4623-9fb5-3a3a8f8a2f31', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('e6933a63-dbd0-405d-9f92-a8ef97caf2d9', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('c9bdf3bc-e181-463e-b5d1-c23554ec22eb', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 2, null, null),
('87d57447-0459-448f-ad77-4d5333c006f4', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '9f77dac3-e200-4b5a-b21a-551b030f94f5', 'material', 30, 'Gram', 13.65, 3, null, null),
('0182ee80-fb4f-464e-a34e-3d06fb0d79ae', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '4416eb46-400f-45e8-9543-3e26ba309052', 'material', 15, 'Gram', 2.73, 4, null, null),
('357417c4-eadb-49e7-b3a3-6f8052a21aa8', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '3c077485-48f9-482c-b392-15736a3508f4', 'material', 10, 'Gram', 3.13, 5, null, null),
('bab30d6f-a866-433d-8cea-a8ace2e514a1', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', 'f91abaaf-3c45-4e92-80f2-667a6bd20fa8', 'material', 20, 'Gram', 5, 6, null, null),
('194063d3-68c3-4e99-bdb0-88be8dddfd58', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '6b1291a1-cee8-4db3-8fe4-bf2a1f071c03', 'recipe', 15, 'Gram', 1.98, 7, null, null),
('d6b9c675-dc25-46be-ac89-a12b35ddd9c5', '1261381e-1d3b-4dcc-8602-dbb812ba5c79', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 8, null, null),
('09be7493-66f4-4330-9ff9-2f5a7e5d3f3a', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('23d7a144-5355-43f0-b054-139d4f5b8543', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 110, 'Gram', 66.33, 1, null, null),
('40febd09-0b61-49d0-bccf-12071798c77b', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 2, null, null),
('471ec686-3951-4d7c-af39-37e11e10c0cc', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', 'b23c4006-7ac9-44dc-be25-c64027464b03', 'material', 40, 'Gram', 10, 3, null, null),
('b3f047c6-5cba-4d34-bfa3-5edae80554b4', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 40, 'Gram', 16.32, 4, null, null),
('3bbeb3d7-acf7-4420-8fc1-40be4b948ed0', '6964b6ec-1eaa-4db5-bef6-cd14239430f5', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 15, 'Gram', 6.56, 5, null, null),
('5241fad4-a6d5-4403-8db5-3babe65a2a54', '047a81a5-a674-41de-a8f1-a53421ae820f', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('42f9237d-3e40-460e-8ba1-7055b95da7dd', '047a81a5-a674-41de-a8f1-a53421ae820f', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 1, null, null),
('2f03d487-2ba1-484c-8f4d-91f47032ba4d', '047a81a5-a674-41de-a8f1-a53421ae820f', '742e23f7-5803-448a-b155-30574f44e421', 'material', 40, 'Gram', 8.1, 2, null, null),
('1c5e47e3-7503-4e8b-a47e-16d381e44925', '047a81a5-a674-41de-a8f1-a53421ae820f', '600ea11b-1de4-4592-abdb-f59d19e416e3', 'material', 20, 'Gram', 4.55, 3, null, null),
('a08b154e-2b3f-4c7f-b779-0342d3d36261', '047a81a5-a674-41de-a8f1-a53421ae820f', 'f019ebfd-9479-4a98-8e16-1e4ad63f33cd', 'material', 20, 'Gram', 8.16, 4, null, null),
('ac213b0d-4bd2-4ce2-a2bc-acba2a54988c', '047a81a5-a674-41de-a8f1-a53421ae820f', '9154b564-40be-400b-acfa-5f185d0e649e', 'material', 10, 'Gram', 4.38, 5, null, null),
('aaa208bd-d0b2-4b04-94df-9a5cc3860321', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 310, 'Gram', 26.11, 0, null, null),
('ebb531e4-673a-4805-a736-4a9e4e9279c3', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', '742e23f7-5803-448a-b155-30574f44e421', 'material', 150, 'Gram', 30.39, 1, null, null),
('4908b339-4be2-4997-8729-c07fa7b30228', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', 'a09c6eaf-3024-4870-b107-4264ffe92a54', 'material', 5, 'Gram', 103.38, 2, null, null),
('bd15a96b-b431-4828-9fd0-5564359ddc4d', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', '910522b2-9199-4fec-add4-296db690dd3f', 'material', 5, 'Gram', 28.25, 3, null, null),
('0ac6bce1-c8a6-44b0-a0a3-cb200ade36c7', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 25, 'Gram', 23, 4, null, null),
('07680da1-dd0f-47f5-99e7-03e059918bcd', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 120, 'Gram', 72.36, 5, null, null),
('e7df5822-a2d1-4152-a6ff-c3dc27912793', '2d2d903b-e368-4f62-a70b-216fe00f8cbb', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 15, 'Gram', 0.9, 6, null, null),
('8c6d2938-30b8-4b69-a179-54e9e9765064', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', 'a11b1997-dee4-4804-adb7-e9e68bd83846', 'recipe', 180, 'Gram', 15.16, 0, null, null),
('2d51005c-fc34-493f-932d-be0a2962b551', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', '742e23f7-5803-448a-b155-30574f44e421', 'material', 80, 'Gram', 16.21, 1, null, null),
('0787d52e-c392-4db8-b829-25554442c16d', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', 'a09c6eaf-3024-4870-b107-4264ffe92a54', 'material', 3, 'Gram', 62.03, 2, null, null),
('ea725bc5-ad20-4b13-8f91-797fec501a11', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', '910522b2-9199-4fec-add4-296db690dd3f', 'material', 3, 'Gram', 16.95, 3, null, null),
('ad85adf3-9078-43f7-928c-1dcaa781e04b', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', '1b0d1804-9fc1-4f61-ad1a-ba55ff1cbcd4', 'material', 15, 'Gram', 13.8, 4, null, null),
('76ed59e8-5252-4866-b8c4-258ba7fdbcd0', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', '3d2afee0-e15f-457d-8711-548238cf670c', 'material', 60, 'Gram', 36.18, 5, null, null),
('7e08b8b7-ff91-45a9-80c9-1bec1dae4308', 'ab5bdac0-9bfd-4e79-a9fd-d1b603ae479a', '832246d2-2132-4a5a-b502-0f76d6311c92', 'material', 10, 'Gram', 0.6, 6, null, null)
on conflict (id) do nothing;

-- ingredient_yields (87)
insert into public.ingredient_yields (id, ingredient_id, purchase_cost, purchase_quantity, purchase_unit, raw_quantity, raw_unit, wastage_quantity, wastage_unit, usable_quantity, wastage_percentage, yield_percentage, original_unit_cost, yield_adjusted_unit_cost, effective_from, notes, created_at, updated_at) values
('b4d9012d-b0c2-4168-8b2b-5b5cae456de4', 'cc0d15a8-7d60-435d-83db-20b085d3471b', 27.5, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.0275, 0.034375, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a72f37d5-4b9f-4f90-8daf-43551ca54a59', 'bd976fab-4bc0-492d-b4b2-aef9390f32c2', 129.5, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 0.1295, 0.15235294117647058, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('55e859fa-3163-4d3c-9948-265a7f7c0346', '3868a2d1-5ef3-401c-97a2-6abff5af89ba', 50.6, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.0506, 0.05622222222222222, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('82079f1b-8445-4217-bb85-db7614b70c34', 'b9ab6e97-c2ef-4e35-9afd-bb3ec2f27a17', 399.96, 1, 'KG', 1200, 'Gram', 500, 'Gram', 700, 41.67, 58.33, 0.3333, 0.5713714285714285, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ed785bf2-6510-4793-b183-50ad4dbca6e3', '7f87fc93-156b-4e76-a25a-9ea16a4397fe', 672, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.224, 0.48, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3e4fee02-32fa-421e-8d2f-2022afa35ae5', '2aa6e99a-8b7e-45c0-8f96-70db7bf246f6', 12.26, 1, 'KG', 170, 'Gram', 70, 'Gram', 100, 41.18, 58.82, 0.07211764705882352, 0.1226, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('224b8c82-8bf1-4b21-a252-96da3ea6c62a', 'f73018d6-2b7a-44f9-9e92-809011856f4f', 8.4, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 0.07, 0.084, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('927f8fd9-b87a-41d8-8cef-d9d4485f718f', '731ff633-4ec3-49c8-bf9f-580357b2d86c', 260, 1, 'KG', 1300, 'Gram', 700, 'Gram', 600, 53.85, 46.15, 0.2, 0.43333333333333335, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('401e7dc3-0b19-41da-b0c6-d6c816bdbcae', '766f114a-94f7-4904-87d0-2d789ad19156', 59.1, 1, 'KG', 330, 'Gram', 130, 'Gram', 200, 39.39, 60.61, 0.1790909090909091, 0.2955, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dc566130-c814-42cd-9ff3-101ca70d9b17', 'f3192d49-a4ce-4593-b225-2c09a4d3e32a', 5.4, 1, 'KG', 210, 'Gram', 110, 'Gram', 100, 52.38, 47.62, 0.025714285714285717, 0.054000000000000006, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a136ad41-0367-44ee-a446-04394b6e4e3d', 'aa4a6af7-2b36-4d41-a820-0bd893f3d729', 576.32, 1, 'KG', 1350, 'Gram', 400, 'Gram', 950, 29.63, 70.37, 0.42690370370370373, 0.6066526315789474, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8bd44745-3205-40f7-b912-01b7d62ead5f', '18e02edb-d4c3-4e73-af3c-355208d96966', 416.34, 1, 'KG', 900, 'Gram', 320, 'Gram', 580, 35.56, 64.44, 0.46259999999999996, 0.7178275862068965, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d956f989-deb0-49a5-b9fb-06fa89d9307c', '04882e9b-263d-4790-a223-4f4de0b1ae14', 155.3, 1, 'KG', 500, 'Gram', 200, 'Gram', 300, 40, 60, 0.31060000000000004, 0.5176666666666667, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8be50404-b8a3-45f0-89d1-50652d3701a1', 'b4cc5fc5-1d8a-4033-bddb-21ba34b08b7a', 87.5, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.0875, 0.09722222222222222, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c8045b75-8e81-4e4c-a61b-b8b091f02780', '7fa82ab6-833e-443f-af10-d12b6c7fc883', 900, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.9, 1.125, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c97305d9-ba71-447c-aa43-b375cd4ec3c0', 'f4d53822-a41c-40f4-b536-6f341530dff1', 333.3, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0.3333, 0.4974626865671642, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('038aec88-46f9-47d2-ba9d-18a1e0bd2dc9', '82d9a001-3030-49a6-a120-3cd1f2a478f8', 481.5, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.4815, 0.535, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a3ec186f-3433-47f5-8896-ee8da774f8de', 'c8717b8a-77e1-45d8-b9ce-c823224200a4', 134.3, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.1343, 0.2686, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d4e6e912-83be-467f-94e8-852b3398e8d4', 'cdd6e73d-660e-4adf-8003-b41d1b1ef1ef', 1063.4, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 1.0634000000000001, 1.2510588235294118, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cd3da1ad-60e2-4ebf-bc4f-9b01ca43bfab', 'aead1485-f135-4fc9-a1d5-98acd8c52aba', 0, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('90e928b2-e78d-4f9e-98e8-4baee9ea95ef', 'eb5acb8a-8a59-495f-bdfd-23390d8d9a97', 123.9, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.12390000000000001, 0.154875, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f6d3499a-116d-44cf-beb6-7e6c9702c2f4', '65f1c0b8-fed5-4c30-8133-c59285da9a74', 60, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.06, 0.07692307692307693, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b36fea9f-ce10-4b89-bff4-a912fa34dea5', '47239ee6-5a29-4412-aeee-91709e814ab0', 137.4, 1, 'KG', 1000, 'Gram', 850, 'Gram', 150, 85, 15, 0.1374, 0.916, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8a0a5aa5-de6d-41d6-b88d-1ad47f9c8656', '6bd4819e-f980-4734-a355-0ccc7b195621', 45.39, 1, 'KG', 534, 'Gram', 260, 'Gram', 274, 48.69, 51.31, 0.085, 0.16565693430656936, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('73ec1654-979d-4e52-964d-ddb3da092007', '4c195e1a-c8ce-4031-9f41-7fce1c36a023', 21, 1, 'KG', 400, 'Gram', 190, 'Gram', 210, 47.5, 52.5, 0.0525, 0.1, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('793756d0-b3f4-4a4f-a876-15a171636947', '99a24907-c978-44a2-8b70-bbc0b8a3f716', 8.33, 1, 'KG', 68, 'Gram', 18, 'Gram', 50, 26.47, 73.53, 0.1225, 0.1666, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4b57a76d-bfae-4140-b9d4-510c5f990522', 'a3765e39-a88b-4224-bbe9-958d8ac14a18', 136.89, 1, 'KG', 270, 'Gram', 70, 'Gram', 200, 25.93, 74.07, 0.5069999999999999, 0.6844499999999999, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ad718cb7-4258-45b6-b17f-d6e8f67ae020', 'fade9643-a224-4bcb-ba39-59679fa3c5d7', 80, 1, 'KG', 200, 'Gram', 50, 'Gram', 150, 25, 75, 0.4, 0.5333333333333333, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('43d59cdd-4741-46ca-8dfd-881bd28a2d2d', '3059e16d-cc3a-4752-900a-ce663aa32b91', 24, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 0.2, 0.24, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9e055cbb-39c0-41ba-9355-89326b887492', '010bc728-2aba-4739-b576-64ef66311216', 68.3, 1, 'KG', 1000, 'Gram', 20, 'Gram', 980, 2, 98, 0.0683, 0.06969387755102041, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3b28a3f9-9bb5-4a00-95cf-7e506dc33457', 'c47cfb9b-cc89-4b3d-8ca5-cfb9b1e0166f', 56.2, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.0562, 0.07025, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a1caafd4-3f64-4b78-a0b8-2687e471e49c', 'f5206df6-3f28-4b8e-87cf-43a8f1c3f14c', 129.5, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.1295, 0.161875, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('51e4548e-2641-4c2a-9004-3e87f7c209dc', '9b02ebe6-e1dc-40c0-a390-135ffb87fa07', 121.5, 1, 'KG', 1000, 'Gram', 350, 'Gram', 650, 35, 65, 0.1215, 0.18692307692307691, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ecabafed-780d-4110-a95a-6d45c037a391', '996a4485-71c1-4ad1-b9fb-f5a842f366f4', 157.9, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.1579, 0.197375, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8b588b27-0d87-4425-877a-35ff3c018199', '4556dec3-325f-4b7e-831e-bcc0d9099c5f', 31.1, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.031100000000000003, 0.039871794871794874, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0ad12b0f-2172-4994-842e-de561b8796d9', '721ca00b-e52e-4f6d-845a-450dcaf6fc9b', 550, 1, 'KG', 2200, 'Gram', 200, 'Gram', 2000, 9.09, 90.91, 0.25, 0.275, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c8052105-b1dc-4a03-b20e-996ca64d4006', '09f5ef06-3cd7-45b3-bc2d-e2a84fa07b8b', 154.71, 1, 'KG', 900, 'Gram', 100, 'Gram', 800, 11.11, 88.89, 0.1719, 0.19338750000000002, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7b3988a4-135e-483d-b4c2-e00c7903a468', 'bfa17b2c-55cd-4cb9-984f-1a7bd5841efa', 60.72, 1, 'KG', 1200, 'Gram', 475, 'Gram', 725, 39.58, 60.42, 0.0506, 0.08375172413793103, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1f7d1b9c-729f-4b5e-a75c-1f5800860c20', '1d10cb82-dc36-4c2e-85c8-45bb27c8142e', 46.2, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0.052500000000000005, 0.084, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('23f1be31-72ec-458b-87fd-58cb63c39f58', '1baa59aa-dc62-41e2-9593-5c59bf8593ad', 246.4, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0.28, 0.448, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('937107c9-9d87-4897-95b3-872b04da6dc8', 'a2407dbf-0b3f-459f-9630-4110184f406b', 41.25, 1, 'KG', 1500, 'Gram', 500, 'Gram', 1000, 33.33, 66.67, 0.0275, 0.04125, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c9851644-fd60-41c9-9427-dc2a78097fe7', '5ff5b05b-1c1b-4313-883a-b0c9d5ede47a', 187.7, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.18769999999999998, 0.24064102564102563, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cceb160f-a755-40cc-ba54-290c2a5c8c3e', '28b06627-a880-4631-9bc4-a5d05c5b1c57', 131.67, 1, 'KG', 700, 'Gram', 92, 'Gram', 608, 13.14, 86.86, 0.1881, 0.2165625, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9817ff06-902f-48a1-90bc-f8797df49bdb', '8a8bbeb6-7923-4afd-9fcc-070fd90c84f7', 11.3, 1, 'KG', 150, 'Gram', 90, 'Gram', 60, 60, 40, 0.07533333333333334, 0.18833333333333335, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0952a602-6fdd-4fba-9920-e757f388ba3f', '693d0631-f962-4a7b-b68d-588b34fc6415', 112, 1, 'KG', 500, 'Gram', 100, 'Gram', 400, 20, 80, 0.224, 0.28, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0398dd59-cf3b-47e7-a822-2122662ab75d', 'baf21e30-369d-452d-be76-fe4edc744794', 20.24, 1, 'KG', 400, 'Gram', 200, 'Gram', 200, 50, 50, 0.0506, 0.1012, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('838af996-ea4e-4cee-a8a8-7913fae699ec', '8234fee4-ce8f-4e5d-aae6-40851d297b4f', 0, 1, 'KG', 287, 'Gram', 37, 'Gram', 250, 12.89, 87.11, 0, 0, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9e60f88c-681f-44b6-b6e0-ebde206be3e6', 'c2edcf53-8b01-4808-ac02-64dcbf21f788', 103.14, 1, 'KG', 600, 'Gram', 400, 'Gram', 200, 66.67, 33.33, 0.1719, 0.5157, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('071e5ccd-606d-486c-b5be-0045a1f99d02', 'c832697f-50c6-4c2d-9629-bf57832c66a6', 0, 1, 'KG', 3300, 'Gram', 1700, 'Gram', 1600, 51.52, 48.48, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fe5fc0ea-8c0a-4e06-b442-031b8dd38c6e', '6818a882-ddcd-4018-96c9-58a5b09582f0', 0, 1, 'KG', 5300, 'Gram', 270, 'Gram', 5030, 5.09, 94.91, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('227b766f-ad2a-4b51-9846-9a546de2f559', '26b98da8-30c7-4b04-b91d-743151d1479d', 0, 1, 'KG', 2500, 'Gram', 1250, 'Gram', 1250, 50, 50, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7c408317-d142-4e6d-8a2b-fb247e0c2d78', '4fa96aa8-47c4-4cf0-b504-3ef160054d3a', 13.75, 1, 'KG', 500, 'Gram', 300, 'Gram', 200, 60, 40, 0.0275, 0.06875, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('de3e3004-3889-4736-ac1a-dcbd8e275e74', 'b41f9a35-ec5c-47f3-829a-3d174167c0fc', 227.7, 1, 'KG', 1000, 'Gram', 520, 'Gram', 480, 52, 48, 0.22769999999999999, 0.474375, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4dd6e614-d86e-4f58-aa04-5cdb99fc6a23', '21c5a622-f65b-467e-829a-5fa2fa30c0d7', 435.4, 1, 'KG', 1400, 'Gram', 900, 'Gram', 500, 64.29, 35.71, 0.311, 0.8707999999999999, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9e6cbfa7-f4b1-4290-9461-96e6963f3d59', '9c516874-bfb6-4e02-bc0a-1e0e9314771c', 249.9, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.0833, 0.1785, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('be967e86-7e24-484a-8f9c-8dc42e967a72', '77e27617-ce99-4fe5-bc07-1dbefd9795d2', 532, 1, 'KG', 1900, 'Gram', 400, 'Gram', 1500, 21.05, 78.95, 0.28, 0.3546666666666667, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c5aace81-760f-433a-b8df-e170f4a51277', '26cab8ff-4246-427a-8147-1b823c0445d0', 30, 1, 'KG', 100, 'Gram', 50, 'Gram', 50, 50, 50, 0.3, 0.6, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8447ddfe-8d81-43a4-8a65-bb85151ed49d', 'abbd46f7-f4ec-4d23-9ac6-af96b7d96437', 75.3, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.07529999999999999, 0.15059999999999998, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2095fddb-7017-48a7-8d71-05052bf9b708', 'e42168de-c34d-4387-ae2e-120eeda0a94a', 14, 1, 'KG', 70, 'Gram', 40, 'Gram', 30, 57.14, 42.86, 0.2, 0.4666666666666667, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6962f9a2-c922-4758-a30d-21d0505a29d2', '6fae982a-0de0-4db1-ab66-4dc5899e1fea', 0, 1, 'KG', 2000, 'Gram', 1150, 'Gram', 850, 57.5, 42.5, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('51074664-f450-427e-b895-1c22f818205c', '1be22f9c-1bf3-4098-8df8-f8cc89743305', 0, 1, 'KG', 240, 'Gram', 103, 'Gram', 137, 42.92, 57.08, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8605bfb5-5389-419f-b647-50290dca2c09', 'e1a0dadb-f8cb-4790-b6c8-cfd431dd6e59', 0, 1, 'KG', 3000, 'Gram', 200, 'Gram', 2800, 6.67, 93.33, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0812e5ae-2594-4954-8382-5366a55a83d0', '12c8c0f7-ddc1-4836-91a6-b95a6c36d874', 0, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a1ed68fa-8233-48cb-8ad7-a4c0bda6afcc', 'a1497002-02f3-4cd9-bee8-75b4217c7632', 75, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0.1875, 0.3125, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('53421f48-c482-4683-aded-bfc810c03891', 'd4e5517e-852b-4e55-a222-a96bb873d79d', 201.82, 1, 'KG', 390, 'Gram', 190, 'Gram', 200, 48.72, 51.28, 0.5174871794871795, 1.0090999999999999, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('58ba80f7-9485-4b41-b089-ab60f9a1991f', '1f98c747-ac43-4825-b8de-9f09be5683b4', 120, 1, 'KG', 100, 'Gram', 40, 'Gram', 60, 40, 60, 1.2, 2, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('392796be-d2f3-4354-9bc7-c5dd3c16310e', '6a5d14e8-80d9-4f5c-9362-0f5cc6b0d0c0', 938.1, 1, 'KG', 3000, 'Gram', 1500, 'Gram', 1500, 50, 50, 0.31270000000000003, 0.6254000000000001, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dbae1665-f68f-41b0-80fc-1b651a4978fd', 'd0513eb6-00dc-479e-a284-5c1853e04ff9', 1800, 1, 'KG', 3000, 'Gram', 1440, 'Gram', 1560, 48, 52, 0.6, 1.1538461538461537, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5cb37cdf-9e29-48df-8aba-fe094cee0757', '34d6b501-2c2b-4a94-8fe6-946202ae39d4', 0, 1, 'KG', 3000, 'Gram', 1350, 'Gram', 1650, 45, 55, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('59836ad1-4354-4881-84ea-7174e76dabbf', '972a61db-ddee-42ae-8e98-35db7fbba6b0', 129.66, 1, 'KG', 507, 'Gram', 203, 'Gram', 304, 40.04, 59.96, 0.2557396449704142, 0.4265131578947368, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('934a4281-f357-477c-a965-56efb7709566', 'daa20a07-4fbd-4341-8ce0-5acecb968a7d', 110.5, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0.1105, 0.05972972972972973, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4b8d5b57-3332-489e-b61f-5a2bf3e2c4fa', '0b37d616-a410-4231-80f9-f9d5c1861735', 101.8, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1610, 0, 161, 0.1018, 0.06322981366459628, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b84777f4-32c3-4f04-a28e-b1ebd05db5bd', 'a5b1d852-5e75-4e44-9176-336071330769', 92.3, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1810, 0, 181, 0.0923, 0.050994475138121546, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b57c896b-d226-43fb-8f19-35dc144880b4', '23e939ca-7dbc-4ffd-a401-3b1af3a8cb48', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f7d4b1d1-ad60-4b80-9539-d5b2645d08ae', '62ef2d72-8d26-42f0-b5cf-12c681a1b0a5', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1950, 0, 195, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5a7d3292-eb64-40ac-adda-7ae5f0dc3c5b', '812eca18-b3f7-48c8-9a3d-a10c4f2fc400', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e12965fb-be31-4dc0-8586-f980c905fa39', 'c513d370-99aa-4b76-80ad-6efb1a6ee4bb', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e70d3a54-599f-4150-b71e-9a75f4fc1518', 'fc14efb4-844e-496d-94e0-16dc003df799', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1750, 0, 175, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('23155d6b-9254-4bbb-a7eb-06f6eb26432b', 'a6106bef-e449-464c-aac9-965f37919830', 188.6, 1, 'KG', 500, 'Gram', 0, 'Gram', 700, 0, 140, 0.3772, 0.2694285714285714, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('16779f4a-f5ab-4ee8-81f7-5ea7a8192e99', '93c3f13b-38e3-4f01-8a35-360c01cd3fb5', 200, 1, 'KG', 1000, 'Gram', 940, 'Gram', 60, 94, 6, 0.2, 3.3333333333333335, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8386b774-d2e9-4ae2-ada9-97f253ef4405', 'e265987e-5349-4b20-a540-66d1e06f61fb', 97.1, 1, 'KG', 1000, 'Gram', 950, 'Gram', 50, 95, 5, 0.09709999999999999, 1.942, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('28caefbc-6929-438c-84d3-5879744b8bd7', '1939f0fa-f140-4efd-b40e-9401c44a35a5', 78.8, 1, 'KG', 1000, 'Gram', 280, 'Gram', 720, 28, 72, 0.0788, 0.10944444444444444, '2026-06-01', 'Paste', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e4633498-ea06-45ed-aa6a-cfc239a97dbe', '2cba9fcc-80a7-44ae-8f56-80328da8f1f4', 87.2, 1, 'KG', 1000, 'Gram', 400, 'Gram', 600, 40, 60, 0.0872, 0.14533333333333334, '2026-06-01', 'Roasted', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('37cc42f8-9383-4ab8-8ebd-9921169e291c', '58598e51-7af5-489e-8a75-26117701f8b8', 500, 1, 'KG', 1000, 'Gram', 880, 'Gram', 120, 88, 12, 0.5, 4.166666666666667, '2026-06-01', 'Dehydrated', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3a852daa-b752-4475-b63e-b8d26d385664', 'a6785c44-5fff-4c71-b6c9-0006d4d0ad2d', 157.9, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.1579, 0.197375, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('516b314a-4e54-49dd-8934-b059aad9e5ac', '5e54990c-1b02-4927-b5fc-90aee4a2bdb4', 31.1, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.031100000000000003, 0.039871794871794874, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b1f04892-009d-464d-b71b-2b6b08de2695', 'cc88b3b6-c76d-40b5-8d1e-10686966b3a9', 45.39, 1, 'KG', 534, 'Gram', 404, 'Gram', 130, 75.66, 24.34, 0.085, 0.34915384615384615, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

commit;
