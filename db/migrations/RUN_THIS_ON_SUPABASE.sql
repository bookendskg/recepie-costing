-- RUN_THIS_ON_SUPABASE.sql — COMPLETE one-shot Supabase setup (auth + data + catalogue).
-- Safe to run on ANY state: fresh project, half-migrated, or already set up.
-- Idempotent (if-not-exists + drop-then-create) and wrapped in ONE transaction.
-- Do NOT run the numbered 0001..0009 files separately; this file replaces them.
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
  role        text not null check (role in ('admin','editor','head_chef','chef','viewer')),
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
  create type app_role as enum ('admin','editor','head_chef','chef','viewer');
exception when duplicate_object then null; end $$;

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
    role           = case when v_owner then 'admin'::app_role else role end,
    approved       = case when v_owner then true else approved end
  where id = auth.uid()
  returning * into v_row;

  if not found then
    insert into public.user_profiles (id, email, name, role, approved, email_verified, last_login)
    values (
      auth.uid(), coalesce(v_email,''), split_part(coalesce(v_email,''), '@', 1),
      case when v_owner then 'admin'::app_role else 'viewer'::app_role end,
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
  select public.app_role() in ('admin','editor')
$$;

-- Recipes may also be edited by Head Chef (not ingredient pricing).
create or replace function public.can_edit_recipes()
returns boolean language sql security definer stable set search_path = public as $$
  select public.app_role() in ('admin','editor','head_chef')
$$;

-- Operational (wastage) data: admin/editor/head_chef.
create or replace function public.can_access_outlet(p_outlet text)
returns boolean language sql security definer stable set search_path = public as $$
  select public.app_role() in ('admin','editor','head_chef')
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
  public.app_role() in ('admin','editor','head_chef')
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
  with check (public.app_role() in ('admin','editor','head_chef'));
create policy wastage_update on public.wastage_entries for update to authenticated
  using (public.can_access_outlet(outlet_id)) with check (public.can_access_outlet(outlet_id));
create policy wastage_delete on public.wastage_entries for delete to authenticated
  using (public.app_role() in ('admin','editor'));

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
create policy audit_read   on public.audit_logs for select to authenticated using (public.app_role() = 'admin');
create policy audit_insert on public.audit_logs for insert to authenticated with check (true);

drop policy if exists settings_read  on public.system_settings;
drop policy if exists settings_write on public.system_settings;
create policy settings_read  on public.system_settings for select to authenticated using (true);
create policy settings_write on public.system_settings for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

drop policy if exists user_recipe_views_read  on public.user_recipe_views;
drop policy if exists user_recipe_views_write on public.user_recipe_views;
create policy user_recipe_views_read on public.user_recipe_views for select to authenticated
  using (user_id = auth.uid() or public.can_edit_recipes());
create policy user_recipe_views_write on public.user_recipe_views for all to authenticated
  using (public.can_edit_recipes()) with check (public.can_edit_recipes());
-- 0009_seed_catalog.sql — catalogue data for the Supabase data layer (Phase 2).
-- Generated from the mock seed. Run AFTER 0001,0004,0005,0006,0007,0008.
-- Idempotent (on conflict do nothing). actor columns left null.

-- raw_materials (631)
insert into public.raw_materials (id, ingredient_name, category, supplier_name, purchase_price, purchase_quantity, purchase_unit, base_unit, cost_per_base_unit, last_price_update, status, notes, created_at) values
('1071302f-6503-4051-aa70-d42561b6cc4b', 'Butter', 'Dairy', null, 538, 1, 'KG', 'Gram', 0.538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('569fc261-43fb-4e18-9b1a-55724ab71c8f', 'Parmesan Cheese', 'Dairy', null, 1266.7, 1, 'KG', 'Gram', 1.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4e9be89a-9674-4110-952f-f30c8fb50682', 'Mozzarella Grated', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e8f321ec-6a03-4c02-a48b-a2b805f6c3d1', 'Burrata Cheese', 'Dairy', null, 887.5, 1, 'KG', 'Gram', 0.8875, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('47b7fc35-4642-4dfc-b10e-bb2fef9094ed', 'Amul Gold Milk', 'Dairy', null, 75.2, 1, 'KG', 'Gram', 0.0752, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('006424e1-afab-48bb-903b-ab392c7ca7d4', 'Fresh Cream', 'Dairy', null, 206, 1, 'KG', 'Gram', 0.206, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f1eaeef6-3c25-4818-ae9d-c38841124733', 'Tofu', 'Protein', null, 260, 1, 'KG', 'Gram', 0.26, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d8d475da-ca6c-4cce-850b-90ceed6b83ae', 'Boiled Spaghetti Pasta', 'Grains & Flour', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9630a810-c522-42c6-ab6d-7f7d57559e0b', 'Boiled Bucatini', 'Grains & Flour', null, 92.3, 1, 'KG', 'Gram', 0.0923, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'Rice Flour', 'Grains & Flour', null, 66.7, 1, 'KG', 'Gram', 0.06670000000000001, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5ab0b89b-1607-40e9-8982-739477dd3eba', 'Maida', 'Grains & Flour', null, 41, 1, 'KG', 'Gram', 0.041, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8f0a4ee9-4236-424d-90a5-d36d1bfa068b', '00 Flour', 'Grains & Flour', null, 119.7, 1, 'KG', 'Gram', 0.1197, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('48aafe16-9f95-4b8f-9fea-23060240961c', 'Sushi Rice', 'Grains & Flour', null, 252, 1, 'KG', 'Gram', 0.252, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e2635a8a-7f74-4f35-bcd3-a85c4b4f3d2e', 'Yeast', 'Bakery', null, 368.4, 1, 'KG', 'Gram', 0.36839999999999995, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6eac6efc-7c89-43d0-b3c0-e1b1d99de8b8', 'Malt', 'Bakery', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('efb23ca8-1da0-4ede-8d97-c6a30394b9b0', 'Brown Sugar', 'Bakery', null, 106.7, 1, 'KG', 'Gram', 0.1067, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c251ea42-2811-4b89-9d99-a9afe34f095f', 'Sugar', 'Bakery', null, 101, 1, 'KG', 'Gram', 0.101, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b930a242-3c77-4d23-a1df-b5235c4cb67a', 'Olive Oil', 'Oils & Fats', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8a5f9308-fb2e-4d66-acb5-96d8ee8bd0d7', 'Sunflower Oil', 'Oils & Fats', null, 104.7, 1, 'KG', 'Gram', 0.1047, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b5026ed0-ee14-4a0d-ab38-60c776be4629', 'Oil', 'Oils & Fats', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e0fd77cc-8173-4cd4-8774-505e07bf69ca', 'Chilli Crisp Oil', 'Oils & Fats', null, 125, 1, 'KG', 'Gram', 0.125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('acd8f225-d1d5-41e9-b288-c8bc95caea67', 'Red Chilli Oil', 'Oils & Fats', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b4c04fbd-6aa7-458a-9730-9a3c77248972', 'Peeled Garlic', 'Vegetables', null, 257.1, 1, 'KG', 'Gram', 0.2571, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2b098e5d-19d0-4886-a4c0-385c9f9e6d33', 'Garlic Chopped', 'Vegetables', null, 187.5, 1, 'KG', 'Gram', 0.1875, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4b8ed434-e369-442d-92d8-a75f2bb7913a', 'Green Garlic', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3d89d37b-16a9-498c-acf8-69b79ca73984', 'Fried Garlic', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('48cb11cf-41e5-4464-9f67-0a8231840c39', 'Ginger', 'Vegetables', null, 128.8, 1, 'KG', 'Gram', 0.1288, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a43ed5e7-f254-49de-91ba-64022ec5a365', 'Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.06670000000000001, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('76fdcda0-3217-4d73-87dd-624b27eab527', 'Slit Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('5b37ecbd-29a1-485c-84f2-616a4f06cf41', 'Fried Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5aa2983b-4fb3-4d6a-b634-582f811c27af', 'Confit Onion', 'Vegetables', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f3a46ec0-3e4d-46e3-b236-33bd1866f04c', 'Confit Garlic', 'Vegetables', null, 482.2, 1, 'KG', 'Gram', 0.48219999999999996, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'Spring Onion', 'Vegetables', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('af5620e5-5b16-4c46-b601-269dc0d7118a', 'Chopped Spring Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('db817cd3-b856-472b-afda-1aacd2f90e60', 'White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'Parsley', 'Vegetables', null, 432, 1, 'KG', 'Gram', 0.432, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ad942586-e623-459d-96fa-c2c4afd71c75', 'Coriander', 'Vegetables', null, 131, 1, 'KG', 'Gram', 0.131, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32373bfa-8b2a-45bc-904c-23c81594db98', 'Dill Leaves', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'Basil', 'Vegetables', null, 233.7, 1, 'KG', 'Gram', 0.2337, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a18c114f-af1f-4cdb-87b0-984318bb61c7', 'Curry Leaves', 'Vegetables', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f258b599-4e8f-4184-aec0-f3263e8f0059', 'Green Chillies', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5dcbadc3-8763-417f-a614-4b8976122cc9', 'Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4fd8cde6-cdce-41b5-b6d7-499198b6b6b1', 'Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f4102d46-43a3-4c50-83f8-84e7be8f9e2f', 'Shimeji Mushroom', 'Vegetables', null, 1300, 1, 'KG', 'Gram', 1.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b3761484-fca6-40a8-9d9b-6fc857dd4619', 'Beetroot', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d636a968-0696-4795-9dcb-979fa2327353', 'Pickled Red Paprika', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f68cd3e8-ee62-41f5-891f-10e5bccaf675', 'Dried Red Chilli', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('22768ecf-de34-4f23-abad-28289f90518e', 'Lemon Juice', 'Sauces & Condiments', null, 311, 1, 'KG', 'Gram', 0.311, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('91749770-d3ce-403c-a27a-572852c8aad0', 'Black Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('341cf0ac-c90d-4966-8038-eb608bec3e9f', 'White Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e1b6a81e-d789-420b-8865-d54459fe4a56', 'Chilli Flakes', 'Spices', null, 353.3, 1, 'KG', 'Gram', 0.3533, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('802b6e54-61ed-4fe8-8aba-df86214335e3', 'Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2df9f517-45a4-4923-b0e3-154608535cfc', 'Salt', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3d3fea49-02fb-4822-831a-83cd29a83b40', 'MSG', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f992d39f-68cc-481d-8318-e3bb6113e957', 'Stock Powder', 'Spices', null, 312, 1, 'KG', 'Gram', 0.312, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e99006b8-d9a9-4c27-9646-5b5c3cb3a84d', 'Garlic Powder', 'Spices', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('36e7b360-d26b-4597-ab87-0a68a2f1822d', 'Onion Powder', 'Spices', null, 840, 1, 'KG', 'Gram', 0.84, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0a045830-9376-4715-b756-0b88b8768ef4', 'Kashmiri Chilli Powder', 'Spices', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('00b2cf6d-ee31-4b18-8401-e02cda3c8f18', 'Turmeric', 'Spices', null, 1428.6, 1, 'KG', 'Gram', 1.4285999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8db28e04-00df-4fea-8b3a-a1eaf6c7f772', 'Mustard Seeds', 'Spices', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0e71ba05-5744-4036-b197-50b316572d1a', 'Fenugreek Seeds', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ddf9e6c6-e2f6-4498-9c6a-f294d4d2c7a6', 'Coriander Seeds', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8985d8f4-c23a-42be-8b7a-4d7a7d3e8d62', 'Cumin Seeds', 'Spices', null, 933.3, 1, 'KG', 'Gram', 0.9332999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c598c88f-4cd0-4181-9178-2ac8cb3f5e6d', 'Fennel Seeds', 'Spices', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a6080d0e-5a0d-43e8-aa51-538c1f3eef2b', 'Cinnamon', 'Spices', null, 6000, 1, 'KG', 'Gram', 6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6ee86fad-4566-46a1-bd36-6eca5888f6e2', 'Cloves', 'Spices', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fd13aa8f-d3be-47c6-8129-a8a23030b806', 'Cardamom', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('12ebba3a-839d-4c97-915e-9b8476dfefd4', 'Black Sesame', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6a789cff-27ad-418c-ad9c-c5ec861d5806', 'White Sesame', 'Spices', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3064c40e-c724-4b02-b4d2-24dc2916b803', 'Bagel Seasoning', 'Spices', null, 2200, 1, 'KG', 'Gram', 2.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0351ff8a-9b95-4672-971b-dc3480ea9031', 'Wasabi', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('953494cc-1e19-49f8-bf9d-7d3f150d98bc', 'Almond', 'Dry Fruits', null, 830, 1, 'KG', 'Gram', 0.83, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f18180c2-8e9d-4bc4-8e96-7cf2aed10d09', 'Kashmiri Chilli Red Paste', 'Sauces & Condiments', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('680a7e54-356d-4cb5-9b8d-4713a3b5dbf0', 'Chunky Tomato Sauce', 'Sauces & Condiments', null, 235, 1, 'KG', 'Gram', 0.235, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('945a346a-bbf2-4c5c-8173-a4dd9aaa805b', 'White Vinegar', 'Sauces & Condiments', null, 31, 1, 'KG', 'Gram', 0.031, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'Hot Sauce', 'Sauces & Condiments', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f0d31a85-4a81-4592-8a5f-04573738b2e2', 'Plain Mayo', 'Sauces & Condiments', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('15903eba-1cf9-453e-8167-284e484b148f', 'Ponzu Mayo', 'Sauces & Condiments', null, 153.2, 1, 'KG', 'Gram', 0.15319999999999998, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('de21d5a3-763c-4ed3-a94b-77f384326bcb', 'Gochujang Mayo', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f3ea175e-86b2-4be8-8a93-8698009e0820', 'Avo Guac', 'Sauces & Condiments', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('be154f02-127c-4f82-9613-bdc60dabb1e4', 'Corn Slurry', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7d97fcc1-1782-47ac-a579-44ae26c13adc', 'Coconut Milk', 'Dairy', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dcf9fb85-d21a-4129-8a8a-440eeeb861fa', 'Tamarind', 'Sauces & Condiments', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'Water', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b468d5c6-b2f5-4035-8ca9-31b4e99985eb', 'Ice', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('321d480b-9b11-4956-8b12-a2c3287d36e8', 'Stock Water', 'Beverages', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('18eb189e-181f-4ce2-b40e-960fd2ce7e7d', 'Arugula', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b92bf850-45bd-42fe-b16e-1fd58aae9f7f', 'Iceberg', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a9021942-8dab-4459-89a5-2a122ff6de7e', 'Romaine', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f3c6c91e-4de8-4a43-ada1-be46fe6455a7', 'Curly romaine', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f2a795c5-d588-46e0-8e55-dd109482657d', 'Cherry tomato', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8276ca8f-d739-4946-af20-ced61338d2e5', 'Grapefruit', 'Fruits', null, 1142.9, 1, 'KG', 'Gram', 1.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d216175b-c5cb-40dc-8d7b-5d475d9ae104', 'Pine nuts', 'Bakery', null, 5000, 1, 'KG', 'Gram', 5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('25807023-d0ff-4a80-9f99-595e8ca3b67a', 'Black olives', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('04182aca-4290-44ef-af1a-aee5f57e259d', 'Vinaigrette', 'Sauces & Condiments', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7d3868b1-b4c4-4309-945d-04b96b8bd79d', 'Sea salt', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('57d7a57e-56ce-440f-80d9-f157e24c377e', 'Hot honey', 'Sauces & Condiments', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a26aa2e7-b177-47bd-a882-4fb1b31dcba7', 'Edible flower', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6f17ac75-40a4-4172-aa3c-04749547f9da', 'Baby burrata', 'Dairy', null, 750, 1, 'KG', 'Gram', 0.75, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('42b00eb2-bde9-4a40-86da-88936a9bde2c', 'Parmesan (grated)', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('89105468-2c61-4524-a5ca-615736362258', 'Crispy croutons', 'Other', null, 139, 1, 'KG', 'Gram', 0.139, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e9c494de-665d-4757-86cb-3717329a4fa7', 'Caesar mayo', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('56f54c2a-84d2-4d50-9817-5d6f7e971de2', 'Persimmon', 'Fruits', null, 362.5, 1, 'KG', 'Gram', 0.3625, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2b233ad5-3fa2-4c44-befa-2de1763072d2', 'Strawberry', 'Fruits', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ee3094be-41f5-4517-a9d1-a1fcc921d14d', 'Burrata', 'Dairy', null, 691.8, 1, 'KG', 'Gram', 0.6918, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3a6ac2b0-8966-4ee9-82a8-70e8c72d48de', 'Caviar', 'Other', null, 810, 1, 'KG', 'Gram', 0.81, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b1845acc-f588-4709-aa75-2593bdff1828', 'Edible flowers', 'Other', null, 1, 1, 'Piece', 'Piece', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7ce48496-de8f-407d-bf54-468a75b2c3ca', 'Processed Iceberg lettuce', 'Vegetables', null, 322.6, 1, 'KG', 'Gram', 0.3226, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('24225d7e-31cc-4829-aa60-6013871528cb', 'Processed Romaine lettuce', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d6fd4858-1398-4280-a564-3b84cea493d0', 'Processed Lollo Rosso', 'Other', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('99d5d9f5-4361-4444-86ed-0f4666be7356', 'Crushed black pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3893cb77-c0a2-4bf5-8ae4-e7971987bd88', 'Roasted hazelnuts', 'Bakery', null, 2600, 1, 'KG', 'Gram', 2.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('913ed4d0-a8ce-49cd-b142-c378ec525559', 'Granola (chopped)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('881a192f-c175-48fa-b118-48b55f914c3a', 'Mango (cubed)', 'Fruits', null, 510, 1, 'KG', 'Gram', 0.51, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4eb43fdb-9df4-425f-b011-f8c36b8ced60', 'Grapefruit (cubed)', 'Fruits', null, 268.6, 1, 'KG', 'Gram', 0.2686, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ca3acdd4-a301-438f-b3fa-b3a28f34b11a', 'Cherry tomatoes', 'Vegetables', null, 605, 1, 'KG', 'Gram', 0.605, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2073b050-f44c-4aa6-84db-4a6001d9ee77', 'Hot honey drizzle', 'Sauces & Condiments', null, 356.7, 1, 'KG', 'Gram', 0.3567, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9b05c0a4-c1a4-47fa-8183-31931bea4a1d', 'Red bell peppers', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('93b276ce-6505-44cb-b159-48e5f021b91b', 'Garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('45d599d0-477f-466c-884d-4b36929b2498', 'Tomato', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c7574d9f-17e4-4b12-95ae-a0dc47c0fc11', 'Roasted bell pepper paste', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'Sour cream', 'Dairy', null, 182, 1, 'KG', 'Gram', 0.182, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('26bb2144-f3f5-4042-86ad-001412386414', 'Pesto', 'Sauces & Condiments', null, 408, 1, 'KG', 'Gram', 0.408, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a42974db-2f76-444e-9b20-4c025a0b54ad', 'Sourdough', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2cdb403a-1d38-4284-8811-6a9ce809a9da', 'Garlic butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9fac0958-17a9-45d2-a320-effe3e3b0626', 'Cooked risotto rice mix', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('54d732e8-01d7-436a-af55-8b35a3338fc4', 'Mozzarella', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2ac4e274-b8bd-4657-8331-da75d309f8bb', 'Arancini batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('22ad9e4c-99fb-4e3b-83bf-3bffe66f7c52', 'Panko crumbs', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9e3a7fec-ca23-4e78-a42c-85d96e9d4810', 'Frying oil', 'Oils & Fats', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6c3cd64f-4812-4745-bf3b-ae6b84b39663', 'Dough', 'Grains & Flour', null, 56.3, 1, 'KG', 'Gram', 0.0563, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('47e3efe1-485a-4f4c-8b80-77dec35f8262', 'Bread base', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4b35f34a-586c-47a3-8021-37b5211336e8', 'Cream cheese', 'Dairy', null, 884, 1, 'KG', 'Gram', 0.884, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('553199df-9a53-4d2b-b54e-91154ccd4fcb', 'Green garlic (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('476c82fb-cbb3-49d7-992f-c1a5c59da3fb', 'Ricotta', 'Dairy', null, 283.5, 1, 'KG', 'Gram', 0.2835, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0adb493e-afb9-4462-9a0a-01a6f4c38304', 'Oregano', 'Spices', null, 375, 1, 'KG', 'Gram', 0.375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('18764540-e469-4518-ae5e-ad7d0281b126', 'Parmesan', 'Dairy', null, 437.5, 1, 'KG', 'Gram', 0.4375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d9f12360-df30-40db-8d73-3a690b911888', 'Thyme', 'Spices', null, 5500, 1, 'KG', 'Gram', 5.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('eb82412e-88e8-4916-9b37-df41bcebc06c', 'Salt & pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c3005a1c-351c-4759-a22b-70b706389c49', 'Pasta sheet 22 g x 2', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7c8a8e64-7eef-4f05-956d-8653ee843fa8', 'Tomato paste', 'Sauces & Condiments', null, 242.8, 1, 'KG', 'Gram', 0.2428, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ab59f94e-6e84-49b5-8a70-00018746ac17', 'Mozzarella 20 g each', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('83e7ba37-42c5-4f4c-9642-426f5c579c7f', 'Ricotta filling 15 g each', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c09a5365-cd67-482c-8f25-20af6f404f40', 'Batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('931f6000-6905-4b19-9b94-cf67073ea8ab', 'Bread crumbs', 'Grains & Flour', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('76595065-ca7c-4d2c-9602-de06a65c11cd', 'Pomodoro sauce', 'Sauces & Condiments', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f1001466-1803-48da-88a7-770a3bf1b19c', 'Chopped garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('31ea5d60-e5ee-4ab9-acc5-f821bcee6e7d', 'Seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('661991bc-e8db-48b3-85d9-1375af39de6b', 'Cowboy Butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0af39f3a-c11f-4c15-9474-ea41dca24aa3', 'Pepper', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fffe5d66-2b32-406a-bae9-7dc2ef3db4a2', 'Brussels sprouts (halved)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('45c1bcb7-1868-4c8e-ab7a-67bf289b4a74', 'Garlic (chopped)', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3e9aab3b-5b33-4e19-96ff-ba3011a48087', 'Red chilli flakes', 'Spices', null, 296, 1, 'KG', 'Gram', 0.296, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('82f0998e-efa0-40cc-b5a3-fe0991512e1c', 'Balsamic vinegar', 'Sauces & Condiments', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('12bfcbca-5b9d-4b99-aa34-1033bf81f502', 'Salt & black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('847afabc-d03d-4911-94e0-39b2ceb8c002', 'Béchamel sauce', 'Sauces & Condiments', null, 112.6, 1, 'KG', 'Gram', 0.1126, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0273d233-5462-43d3-b825-a0491851f225', 'Plain mayonnaise', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2da16878-5adf-43c6-bdae-ea4f3e9e4cad', 'Fresh Bhavnagri chilli', 'Spices', null, 0.2, 1, 'Piece', 'Piece', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('36d7a036-e455-4a1d-a9cd-bdb157683fba', 'Pickled onions', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b94702c4-5b8b-4c55-ae6e-42dd36cf32ca', 'Feta crumbles', 'Grains & Flour', null, 813.3, 1, 'KG', 'Gram', 0.8133, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5fb131c9-63a6-4f5c-9d08-3e31ed442869', 'Tomatoes', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('032c17f9-2950-47fc-ac28-fee10e62a0c5', 'White miso paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7e4e588e-3903-4623-be26-0df6204d946c', 'Chili flakes (or fresh red chili - 5 g, deseeded)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6d29283d-4b72-4515-adcb-a3ab39715b7d', 'Soy sauce (optional)', 'Sauces & Condiments', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a7762432-01df-4780-8d62-457bc2b16305', 'Basil (fresh, chopped)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('44ba86f4-4381-4a37-acb9-581ac6dd6483', 'Thyme (sprigs) (simmer, remove before blending)', 'Spices', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('488a2b1d-b85c-46e7-b398-d163532d001d', 'Bay leaf (remove before blending)', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c0ccf3ac-7670-46f5-98b1-21f4dbdc2432', 'Parsley stems (optional, simmer with base)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('77602f42-cca7-43b4-b714-41a997919da1', 'Pomodoro', 'Other', null, 216.3, 1, 'KG', 'Gram', 0.2163, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b831156-c8f0-40a6-aac5-54fc7f1364d0', 'Boiled spaghetti', 'Oils & Fats', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b24c33e9-4498-4db0-9adf-1ffca0ffa049', 'Boiled macaroni', 'Oils & Fats', null, 101.8, 1, 'KG', 'Gram', 0.1018, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('204a63ea-493b-47ec-96ba-f1394de85896', 'Orange (creamy tomato) sauce', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c4aa31fa-0983-4853-8604-f76dcadd8993', 'Boiled fettuccine', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2ac3ad58-30fa-4f35-9266-dbdc4f1fb96c', 'Béchamel', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f5622dd2-1049-45dd-aa7e-c4bcb45bf3d1', 'Boiled linguini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4e50bf29-b822-4950-b61b-09b892774654', 'White sauce', 'Sauces & Condiments', null, 242.7, 1, 'KG', 'Gram', 0.2427, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('22213964-a3cb-4e72-850c-808a3ad17ba4', 'Mascarpone', 'Dairy', null, 811.6, 1, 'KG', 'Gram', 0.8116, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('837c60fe-7aa5-494a-a184-05fa3374c3d1', 'Lemon zest', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a5a18cc7-e216-45f2-b4e5-d7c4ea10ce19', 'Cooked arborio rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('143fed4f-4740-4e11-a58d-34b9a8aea036', 'Asparagus', 'Other', null, 923.1, 1, 'KG', 'Gram', 0.9231, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e7216c05-ddd4-4b59-85ec-7aaf6a92b98a', 'Peas', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3e749ace-ebe7-4a49-a649-8664a29ee8f2', 'Soy chunks (textured)', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('aca71ce4-9047-4215-9ac2-944392dbc2a7', 'Onion (diced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cac18086-3326-41fa-9ddf-20dd80d25a3c', 'Carrot (diced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('14678ccf-aa89-4425-97ed-7778ce16dece', 'Celery (diced)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c00fc4c4-7b2c-467b-8852-7ead8ad0229b', 'Tomato passata', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0fa661e8-11d3-4987-9fdb-08a9fcc324bf', 'Dried oregano', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('be20ae9b-560d-4ff0-8cf9-bf91acce9670', 'Plain flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5c827e7c-4a9a-4f7d-9961-eb4ab6b442e9', 'Milk', 'Dairy', null, 76.7, 1, 'KG', 'Gram', 0.0767, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8803db70-314d-4ab3-ac53-c092b586fd8a', 'Nutmeg', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1fe25680-4155-4c4a-8c8f-7d0ac8fa9964', 'Lasagna sheets (oven-ready)', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('82d04a65-c091-4874-b926-43e0cc8e243f', 'Mozzarella (shredded)', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('61849d9d-2d97-4492-bd32-5f0c6bc8f05b', 'Ricotta cheese', 'Dairy', null, 288, 1, 'KG', 'Gram', 0.288, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('32a863d2-5f23-42b5-8be1-d698e1ae587f', 'Blanched kale', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a12b91f2-2777-4435-8a60-be13ac4e2c47', 'Chopped jalapeño', 'Other', null, 366.7, 1, 'KG', 'Gram', 0.3667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6df8325b-a5df-4c1b-b165-c57e7924aad8', 'Xanthan gum', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('00093eab-5a9b-4a01-aef5-729cc7acb7c6', 'Conchiglioni', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cb39f21c-c3dc-4241-a01b-7e3a59364e11', 'Garlic pomodoro sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9afe1c26-786e-4f15-b6f5-5d3925d9a627', 'Sunflower seeds', 'Other', null, 420, 1, 'KG', 'Gram', 0.42, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('83d7cb01-8d6a-4e92-b997-3fc8bda4ed12', 'Caramelised onion', 'Vegetables', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7bb2c69c-bbdb-4558-9c19-a5b52fa415ce', '1 ladle water', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5c1c4be6-dbd7-469f-bc8f-3670dc767d43', 'Spaghetti', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f5232ea7-ce87-4001-807f-a4e42a31c246', 'Mix seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ce1beaec-bbac-4275-90c6-58c3f4d8209c', 'Soya sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('89809a1d-8158-4939-852c-27f1baa77f5a', 'Chill crisp', 'Other', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6eb9b4cf-8e71-40c0-ab3f-b063d2a43271', 'Beetroot paste', 'Sauces & Condiments', null, 78.8, 1, 'KG', 'Gram', 0.0788, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('82fe882c-c550-4cfa-b51f-36c41daf2850', 'Farfalle pasta', 'Grains & Flour', null, 405.3, 1, 'KG', 'Gram', 0.4053, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b84c573e-6808-4d5c-9423-851ca20031ef', 'Burrata (smashed)', 'Dairy', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d8f77380-7f47-4c45-bbf7-026dc5c9d6e1', 'Pumpkin seeds & pistachios (crushed & mixed)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('aa9a3175-669d-45b6-9ce2-81660f12a062', 'Risotto rice', 'Grains & Flour', null, 384.6, 1, 'KG', 'Gram', 0.3846, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d988ffee-d8df-420a-aedf-a6b3fd316e17', 'Confit cherry tomatoes', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d79c7d12-01d9-4415-b68b-266fcf0113c7', 'Pesto dollop', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1860ab44-d39a-472b-83e2-e0defe75f371', 'Kalonji (chopped)', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b1f10d8b-99af-44be-ba77-c20a37a5f4ec', 'Macaroni pasta', 'Grains & Flour', null, 72.7, 1, 'KG', 'Gram', 0.0727, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'Cheddar cheese', 'Dairy', null, 850, 1, 'KG', 'Gram', 0.85, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9c14586c-ea8c-4b8b-87a5-fbc4591cd053', 'Mozzarella cheese', 'Dairy', null, 615.3, 1, 'KG', 'Gram', 0.6153, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'Truffle oil', 'Oils & Fats', null, 5355, 1, 'KG', 'Gram', 5.355, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d5479ed6-5a44-401b-8252-e75b64ff1b47', 'Truffle pâté', 'Other', null, 16670, 1, 'KG', 'Gram', 16.67, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ec7d9c5d-921d-47ab-b213-8dc9566e0e5a', 'Sticky toffee pudding', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3147aeaa-ac78-4953-b2b0-07d11a03358c', 'Caramel sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cd266f4e-621a-4f24-bdd0-690d6da4d7ae', 'Pecan ice cream', 'Dairy', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7ee7e5af-7b29-4545-b080-88c37b2f152a', 'Brownie', 'Other', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('00911d16-6320-4f42-96c1-5556387a7441', 'Cookies & cream ice cream', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8962b28f-675d-4667-bfaf-be7aa8217c4a', 'Nutella sauce', 'Sauces & Condiments', null, 566.7, 1, 'KG', 'Gram', 0.5667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('423bdec7-93f3-4667-b9e9-8382c26dd9fc', 'Caramel tuile', 'Bakery', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c85dda9d-4bbe-4222-8032-1b9baa9c3596', 'Kunafa base', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1e256ef0-2d11-43cc-8ce2-08cd34caa7ae', 'Pistachio sponge', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('42bef92f-bb84-4d3a-9b86-860be74d192f', 'Pistachio mousse', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('be17627f-290d-4bdc-a8df-784f46cdb1f7', 'White chocolate décor', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a821dd45-815e-4d7a-bbcb-d50f1fc51be6', 'Coffee sponge', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d6e7e465-af14-405d-8dbd-2b6217a1c21f', 'Mascarpone mousse', 'Dairy', null, 826.1, 1, 'KG', 'Gram', 0.8261, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5be3a248-d160-4e97-b630-3e37e0fe1d09', 'Coffee cream', 'Dairy', null, 750, 1, 'KG', 'Gram', 0.75, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('da07ab88-8347-4451-b641-d545ad80fbc0', 'Sable', 'Other', null, 214.3, 1, 'KG', 'Gram', 0.2143, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b9abf6f0-a9a2-427e-b55d-f3fc81daad62', 'Tuile décor', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bc8f5f42-254f-4f96-96e0-1259714177d8', 'Sugar syrup', 'Sauces & Condiments', null, 27.3, 1, 'Litre', 'ML', 0.0273, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('11487fdf-b285-491e-ac7e-a097d25df283', 'Iced tea (Tata Gold)', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('279cd876-c18c-4a2f-ae81-e7a1cd64f0db', 'Mint syrup', 'Sauces & Condiments', null, 33.3, 1, 'Litre', 'ML', 0.0333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6a37cf3c-4233-4b7f-9978-30e7d192c739', 'Kinley Soda', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e8e635fc-e3d0-4c94-b765-787d9149ffa5', 'Kara Coconut milk', 'Dairy', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('40f43e1f-5e7c-4653-8ef3-355a12b19e20', 'Pineapple jam', 'Fruits', null, 137.5, 1, 'KG', 'Gram', 0.1375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4b3934d8-1a8f-4f1a-bc4d-6aba6bf8df80', 'Vanilla ice cream', 'Dairy', null, 0.19, 1, 'Piece', 'Piece', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9912134e-e968-4abb-8a8a-abf5cd4fc83c', 'Fresh ginger zest', 'Vegetables', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('37d25d3f-43d0-4b83-8e52-f479df8413a6', 'Gunsberg Ginger Beer', 'Vegetables', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('227950d2-e48c-4556-b094-d45e3a3e1469', 'Orange juice', 'Fruits', null, 405, 1, 'Litre', 'ML', 0.405, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5b9da10f-1565-4212-bdd3-28e46f69859d', 'Hibiscus syrup', 'Sauces & Condiments', null, 66.7, 1, 'Litre', 'ML', 0.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aa789f22-e436-4d5d-bad6-92b3edd5685f', 'Sprite', 'Other', null, 104.4, 1, 'Litre', 'ML', 0.1044, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5a4acd44-9a9b-4cff-9950-45390f7d25a1', 'Tamarind syrup', 'Sauces & Condiments', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('50178542-0347-415b-a131-f5fe537be261', 'Pinch of salt', 'Spices', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('24f997f6-cbe3-4974-ab1d-45517f8161f1', 'Schweppes Ginger Ale', 'Vegetables', null, 166.7, 1, 'Litre', 'ML', 0.1667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'Thai chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('25cb24ff-8964-4d75-8b29-285fb3f7281d', 'Shiitake mushroom', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fa5a09af-7710-4361-bf7d-1af7835fb8d0', 'Tamarind paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3cb29bfa-465f-41ab-a7a1-70196df0d0af', 'Vinegar', 'Sauces & Condiments', null, 42.2, 1, 'Litre', 'ML', 0.0422, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9b1f5b34-c89a-4907-88a4-a4e4501db88a', 'Spring Roll Sheets', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cc656ce8-7a7f-4c56-9716-e732b19a9554', 'Thai Spring Filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b87332b3-706a-4513-968d-59b729d5ffde', 'Sichuan Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b757c72c-b05d-4f6c-aaf2-2d72549df04d', 'Coriander Leaves', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e090e6f7-ffe3-470b-be7f-949ec5d14a01', 'Spring Onion Slit', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('37743fcc-ad53-41d6-8f96-5352846f3c5d', 'Sriracha Sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f8ad26b2-1c21-477b-b36d-d13fea1b316a', 'Black Vinegar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('17b4bd6b-98b0-4524-adbc-067071acdc1b', 'Lotus root', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c3bb3bdb-8636-4786-a7af-c94b8eb86297', 'Lotus root sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('091837d5-4ded-4495-85fa-891976d6a1ac', 'Pok choy', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f21524c8-2445-4eef-89d6-c8c0612448a5', 'Bell pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b29ef1e8-98f9-4ded-81ec-f814509c5b93', 'Thai red chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b94c7ba8-2348-4d85-9f73-91d8d10f7f83', 'Kwispy Wonton filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1ff4dc7d-7d45-4dd9-9dc4-8f5d9ca140d7', 'Gyoza skin', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('aade08e9-ad43-46e0-a45f-297a0d5a33d9', 'Chilli crisps', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bab6d6e8-fac4-408c-88ad-3ac3d782a56b', 'Oil (for frying)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3c187146-cfe5-415d-8b28-28e68de4b27d', 'Rice cake (16 pcs)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ec13c55e-f1a5-4368-aa85-cef468242faf', 'Tteokbokki sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7b91720c-ca2c-4314-b29e-4cc41200a267', 'Spring onion slit (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a0631567-5e5f-4b72-98f2-6a0edff165ea', 'Bao', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b151ba9-8b02-4100-9348-ead7930df7de', 'Tofu batter', 'Protein', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('afd4c1a4-20ef-4236-aedc-5aded715e74d', 'Coleslaw', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3354b232-eeb6-44b7-b220-670f00f0b957', 'Black & white sesame', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('53c5058f-3a96-48f8-a017-907dc9debaea', 'Bao sauce base', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('96e77094-e41a-46c8-bdcb-9f1ef8bdee5d', 'Water chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('161b3508-db7c-4f29-a73e-20068cb616ea', 'Water chestnut flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cc076be6-96cc-425c-bd32-8957acc75cd2', 'Gyoza dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e1b6e058-6aa7-4aa7-b15f-c4c93c27eba5', 'Yellow bell pepper', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e75a21d8-711c-4343-b2fe-1587a5c6df45', 'Red bell pepper', 'Vegetables', null, 246.2, 1, 'KG', 'Gram', 0.2462, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('66d2bc8a-fbe2-49fc-94b3-adce6067a9a5', 'Drunken sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ac1c12a7-9aa0-4fb7-82bf-aab7ceb461d8', 'Fried spring roll (garnish)', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72b20788-d1ac-429b-9903-084092e9231d', 'With pods edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3eea824a-fc29-46b0-974b-1d1a44c92231', 'Chilli Crisp (for chilli version)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('576398d1-472f-4d2d-89db-bea186f6a682', 'Salt (for salted version)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('58f0a453-bbd5-442c-bb12-6af792e5f3dd', 'Korean Mandu filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ea4f4990-f636-4777-bfb0-c061ad72f31a', 'Spicy mayo', 'Sauces & Condiments', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e1db6e18-6a83-4cbb-989d-e180eb70d51e', 'Coriander mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a98fb32a-31a0-4f58-be7c-69c9bdc03d71', 'Toasted white sesame seeds', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a28171b4-31da-4e83-9e21-618bb8358b42', 'Julienne cut nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('280048c6-d5b3-43e1-a7d0-8b5f7ca222f5', 'Fried Corn', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cc48b858-85a2-41cf-a5f5-20e7f53a7c1f', 'Corn Rocks sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('67ea7ce5-d608-41a0-8407-d3a04cf54b64', 'Chopped Black sesame seeds', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0b4c1980-7f61-4e32-baec-7240bf3ed4fc', 'Pickled red paprika sliced', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cdfc27a2-3405-4bfc-9ee2-9220cc9d0346', 'Mayonnaise', 'Sauces & Condiments', null, 85.1, 1, 'KG', 'Gram', 0.0851, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1c2e3c50-aa4a-4c01-a026-eaf511f54338', 'Sweet corn puree', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('82d84811-56ae-410f-96a9-bbfd1890e256', 'Condensed milk', 'Dairy', null, 332, 1, 'KG', 'Gram', 0.332, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5ce2fa98-cbc1-407e-a069-aec8ef45b5e3', 'Garlic (minced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d05b4e1f-b73e-4755-8485-6511e7575254', 'Scallion Pancake', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('30527761-9324-4ff5-b6bc-a9cea17dd410', 'Sichuan soy glaze', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('38ac9ff2-b4b2-45ce-966c-81ed9479d12f', 'Green garlic cream cheese', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('87f80e92-b881-45cf-8322-cf0e24601542', 'Scallion salad', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('337a077f-f070-442d-a816-771a1a688218', 'Boiled soba noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9b07205d-e480-46ee-812e-a3339b9d8ff7', 'Cold Spicy Sesame sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('01503849-887f-43cd-90a8-6c7b9138e31d', 'Cucumber slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e824ddce-56bb-4d05-83d9-c7fd6ca59ded', 'Carrot slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8b3a51e7-967b-4496-baf9-fd6ce9b84a0c', 'Fried sesame', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('93770c16-6bbd-4a33-ad74-c0fbed88820f', 'Peanut (crushed)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f4f20f58-f613-4345-b891-9db9ac43ecd8', 'White Part Spring Onion', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0f260bae-1aa4-4085-8e56-36f196542c50', 'Mix iceberg romain slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('74c2c7d0-0da2-4f09-b650-33d1a818bfe4', '00 flour (Biga)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a2f4456a-44a2-4dbd-a0e1-93c213fff5cb', 'Water (Biga)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('10fd013c-fede-4beb-8a79-0e7c87265ae7', 'Dry yeast (Biga)', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2e12df1e-25b8-4d6a-886e-ea0a2e69c660', 'Cold water', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('59383cd6-3a31-4d8f-8f9b-964ec2610ef4', 'Dry yeast', 'Other', null, 178.4, 1, 'KG', 'Gram', 0.1784, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('86518e09-853c-42f6-beae-f1b3c5dd2d3b', 'EVOO', 'Other', null, 1100, 1, 'KG', 'Gram', 1.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('85bedf2b-7c0c-4caf-8374-ea696df43612', 'Katsu curry', 'Other', null, 1150, 1, 'KG', 'Gram', 1.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fc89bee0-9a6c-440d-8a1d-37ce672959f1', 'Cabbage', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ee5248cb-1f56-43fb-ac26-caa7d7870217', 'Togarashi', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4f662bc1-193b-44d2-a833-483314462781', 'Sesame seeds', 'Spices', null, 290, 1, 'KG', 'Gram', 0.29, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('40d9a86b-1a95-4e4c-b03e-1a8a39ca3671', 'Jasmine steamed rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f11f64cf-9f8d-44aa-82e4-069be23527ea', 'Scallion oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9a4754ba-aaa8-4b87-b051-4354d340d168', 'Unagi sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('025bc71a-88b8-468e-ac77-741effa10f18', 'Zucchini', 'Other', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2c174958-6e67-49c0-a3e7-7116034d5ef3', 'Baby corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('98de845c-3efe-4041-863e-e854c2f5b9ac', 'Green paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cd906e06-6c27-4f5d-bcaf-4e8085828dc9', 'Jasmine rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f17454e5-f9e2-428e-9e1e-26e20f9aa09d', 'Sesame mix', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('949b0d39-71ef-41d7-a34d-a7ab2a72c133', 'Lotus stem', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ae7ec34b-0aa0-4c21-8338-446ee0245eba', 'Chilli oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('58578066-e18e-41e8-8565-2d95ea4f5425', 'Fresh Sri Lankan Red Curry Powder Mix', 'Spices', null, 3000, 1, 'KG', 'Gram', 3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8c3a3f3d-bcf8-4ffb-bc40-5e621f4191ec', 'Picked red paprika', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f52ff4df-9bea-4abe-84c1-869bb61c0ea6', 'Chilli Garlic Sauce - Sunflower oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('068fdfd6-d2d5-4886-a64d-ce44228c15fe', 'Chilli Garlic Sauce - Chopped garlic', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('23f58670-dac7-4fee-ac4d-2eb201233b27', 'Chilli Garlic Sauce - Soy sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6f106fae-149b-4425-9695-13f52004dfd7', 'Chilli Garlic Sauce - Hot sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('66a48deb-bfdc-4e05-94b0-4677871f1b4e', 'Chilli Garlic Sauce - Wok hei sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('315f8d18-490c-43d8-b845-08da3afae878', 'Chilli Garlic Sauce - Thai red chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6634b99f-86ee-40bd-b5b2-58726b5eabaa', 'Wok Hei Sauce - Chilli bean', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3d85e83f-1921-427c-83bd-f6b3a68b9326', 'Wok Hei Sauce - Shao hsing', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c4839799-7797-4f2d-8d8e-f9c835aecb6f', 'Wok Hei Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('35036b8b-d55d-453b-8006-44c08a8a2a30', 'Wok Hei Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f60b8b78-54e8-40e3-8c39-bb377ccb5e30', 'Wok Hei Sauce - Cinnamon powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d5f3a67-6285-45fc-898b-efb8a43b95b0', 'Wok Hei Sauce - Sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c13c079a-3f9a-4658-9482-2a532d994ccf', 'Wok Hei Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5ab6b34e-ec32-46e5-8999-75cf65dd1eaf', 'Teriyaki Sauce - Brown sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0f1c05eb-dcac-4c13-a528-5f7bd692bc75', 'Teriyaki Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4c87dfd5-3956-4cf0-a8fd-d9ee3532308b', 'Teriyaki Sauce - Rice vinegar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a06f3e01-5c05-4dcb-b77f-63017f1daa51', 'Teriyaki Sauce - Corn starch', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('39d427a2-fbfc-4580-99a4-bbde3b195410', 'Teriyaki Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('130ddad0-0f07-428a-a980-0968de34c021', 'Teriyaki Sauce - Sesame seed', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('88044a71-d58e-467f-bf1f-debe580e3a4b', 'Yaki Soba Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('059409f6-5c54-46dd-955a-525c855283c0', 'Yaki Soba Sauce - Crushed black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('54e4e95a-3f2a-4220-8f7e-3152ee3a0df6', 'Yaki Soba Sauce - Oyster sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('27971dd9-b191-4212-b0e8-fcd6b39e4392', 'Yaki Soba Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('90019b86-9f16-4a15-832b-6fba05df76af', 'Yaki Soba Sauce - Sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ebb457a4-bd79-40ad-8e2d-ae9e05b187d9', 'Yaki Soba Sauce - Corn starch', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dd67fda8-e4f9-4521-9ee2-a2f2e5ce206d', 'Yaki Soba Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f3b4ba99-8a01-4b78-8c9d-c51e0f0b79be', 'Yaki Soba Sauce - Hot sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('eefc4579-e3d5-4883-8ce4-2326062d3e95', 'Chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('32bf4541-9519-47f7-b401-6b70f0445009', 'Red Bhavnagri chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('99e82bb2-a398-4a4d-8421-896b11914dc8', 'Slurry', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a967dcb4-1b59-4b63-bacc-0e6411bb8319', 'Gyoza wrappers', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('590392b7-1384-4577-b6be-e49ddad1d462', 'Oil + Water (for steaming)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f7e2f12f-93ac-49c4-b5ef-57c5a6e29e91', 'Ginger (paste)', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ee9fce90-b3c0-4129-8edc-7eabe55ffc69', 'Chinese cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b30a4d30-c6a5-4ee1-be8c-4471fce0f25f', 'Indian cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('099a3623-7fb4-4160-9ee0-beb1eec732e9', 'Chilli besan paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1f43db50-945b-4c76-8ad7-fd3c74192d5a', 'Gochujang', 'Sauces & Condiments', null, 648, 1, 'KG', 'Gram', 0.648, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e20d606e-407f-4d9e-9618-ccc1fb3ef65d', 'Soy', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8385aa4b-3ef5-4b13-b992-efc8e7406208', 'Sesame oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c1df2196-dd69-4db4-bab1-69006fbc03a3', 'Stock pwd', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('84793f25-141f-4524-8b72-c2ad6b1e2a49', 'Boiled soy keema', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a7cac34f-d1ab-400e-9763-670e8805ad97', 'Coriander leaf', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c095610f-0705-48fc-9434-2ed5357ee22a', 'Coriander stem', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'Pickled ginger', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('27f8c32f-0002-4c1e-9d03-006cb0e39c45', 'Tempura flakes', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d171529-ff82-46e5-931f-428689bac924', 'Ketchup', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5997bba6-4a12-4c4d-90e8-ca4b7f5a353a', 'Maple', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a50d5e3c-9762-45d4-8b41-55db71056656', 'Oyster', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7065a07c-7a55-42c5-9a2a-50c127ca6d0f', 'Rice vinegar', 'Sauces & Condiments', null, 4428, 1, 'KG', 'Gram', 4.428, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2313d49a-c2e9-4999-a373-f3beadd87e5b', 'Flour', 'Grains & Flour', null, 44.4, 1, 'KG', 'Gram', 0.0444, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8715f325-c6d1-493d-b131-91b6b6927fef', 'Salt (pinch)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b388fa9c-d558-4f9b-983f-55845f4bb57d', 'Mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cfccb5e6-03ad-4698-b96c-5ecff7fe4ff3', 'Mustard', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4f920a60-f27e-4706-aa05-0afde33061c6', 'Blanched edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6ad0bf82-5561-4825-b234-5566c7916fb8', 'Truffle pate', 'Other', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('14957cab-8687-4139-a683-7a5533a7ca15', 'Wrappers', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2b11b89c-01f0-4d7e-80f6-49d992a5454c', 'Silken tofu', 'Protein', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'Gochugaru', 'Other', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a65c0ba4-bf5d-44a8-a7b3-a559ec22a433', 'Coconut cream', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7fe377ff-9f5e-41fc-8216-72af7ec3697c', 'Honey', 'Sauces & Condiments', null, 270, 1, 'KG', 'Gram', 0.27, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6eee0c62-08d6-4a4a-be01-7fa98ab6f11c', 'Shaoxing wine', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('99ebc5f3-1b6b-4db0-8d8d-cff34583edc9', 'Jalapeños', 'Other', null, 241.7, 1, 'KG', 'Gram', 0.2417, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('81b31da2-d45a-4125-959d-07d877eb8147', 'Green Bhavnagari chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4e4e10c7-713b-44dc-b735-d1dea121c480', 'Kaffir lime leaf', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('32277907-3fbf-479f-9fa4-6103c99c3440', 'Lemongrass', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a85617d6-2ce4-43d3-b3ab-926d77893e09', 'Cumin powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3282ad9c-5047-4d96-b365-7da94699b5d1', 'Hing', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('32fc5c0d-05d3-4c62-b031-9c651959bf72', 'Pickled red Bhavnagri', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4f74b75a-901e-4aa3-ab95-b339c98a2a3b', 'Chilli Oil Dumplings filling', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('80e5cae5-b7e7-4c35-bcf1-3d74a1944860', 'Red chilli powder', 'Spices', null, 898, 1, 'KG', 'Gram', 0.898, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e0a995c7-fd16-430a-abfa-d7843546a0a6', 'Chilli Oil Dumplings paste', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('06e28a02-b60b-456c-a295-e0f21906739b', 'Sichuan powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('333fe0a4-5614-432c-8294-e1fb91b91c5b', 'Toasted Peanuts', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a776d4e9-8b13-491d-88b9-b1768cde8e9e', 'Green spring onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4f99710b-bddb-42fb-88df-2ae0fa9a405b', 'Fried glass noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('89f993fc-eb2b-432e-b271-8ae9fbcce03c', 'Saucy Momos', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c9cd3ec0-4f09-4ab7-86e8-6b9e56b5c5f9', 'Forest Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('19904f73-02a8-4b42-a00e-d0a6e2ce70f8', 'Truffle Edamame Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e5e405ce-c962-4f49-9f80-16735fb45e77', 'Cheese & Chilli Dumplings', 'Dairy', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e122c73d-671e-46c0-8939-94c228ea92e0', 'Chestnut Gyoza', 'Bakery', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8f83bdc1-edf6-4c7c-bd7d-ca2f77ed44ba', 'Broad Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('38b863e8-460e-47ca-bd1d-f47e8388776f', 'Chili Crisp', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('90b6e6b4-1c72-4524-8c63-23c4489fdfbb', 'Forest Dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bcfe6fe1-0f12-460d-a447-4787009f46a9', 'Red Momos Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3ad60234-4c86-4bfd-95ce-813fa3a726e0', 'Nori', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('adb6f417-d969-44a6-8636-f23ef32022a7', 'Buffalo sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d5121502-2050-413a-9617-434132b47ee7', 'Avocado', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('07788156-8656-4969-8920-c185d921817b', 'Rice paper', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'Soy sauce', 'Sauces & Condiments', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8cd147d9-20d8-4fda-926d-dc6edfc6136c', 'Nori half sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5c8edb7b-0879-4b8b-bed6-1c14d21c229e', 'Fried stem lotus', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('670e035b-4019-4cfd-8210-f4c1cc0379fb', 'Dragon sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2198806f-1831-4d58-9df2-1ef1c9b73fe8', 'Nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fc26eaa2-aa90-4a6b-9f43-c8a966d504ec', 'Alfanso mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bb57f928-5678-4a1d-bcd9-a3812921b315', 'Chilly crisps and oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1c1692dd-14af-4f24-ad53-1fb93e06326c', 'Ginger pickled', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3f6a9b3e-c2bc-46ee-be89-8e06756cbef9', 'Wasabi paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('777bd5e0-8f00-421c-87c5-263df99a349a', 'Micro greens', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5bb521a5-f6ac-4c04-aa69-e293ccb9528e', 'Nori sheets', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fa78d232-fabc-4a83-93a8-c6b424d2016d', 'Fried Tofu toss on soy', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d78ab968-d996-4e33-9fdf-dbe9df353bfe', 'Unagi', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f8d3a160-12ff-4c98-b695-75c983398d72', 'Pickled radish', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7badac33-4540-431f-a01d-832a9b038a30', 'Sautéed spinach with soy & garlic', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('70a094e0-06d3-45c5-b2de-25165e725933', 'Sesame oil (for brushing)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('12da7c5f-cd30-4873-ac6d-e97897fe846e', 'English cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b986d827-534e-4268-9601-0b732c63ada6', 'Red capsicum', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ba7ed567-0a69-4591-bbcf-a7a2dd07d617', 'Jalapeño', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('57c4751f-b9df-4333-87ac-d17dd523cc39', 'Tempura flex', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f8ff47a6-a453-41b7-87ad-3ee6a80c991d', 'Salsa', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('534e7cba-86ea-4ab6-afeb-2b7b38ebc24e', 'Sweet chilli sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f1be34ea-1e14-4311-b366-3e1a1d500dbe', 'Sriracha', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ded11b5b-7305-4a55-ab95-7056073001b1', 'Raw mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6a1166e3-d1f5-452a-989a-e961806033cb', 'Fried spring roll', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a7d52465-1329-483a-983f-011630e71edb', 'Purple cabbage', 'Vegetables', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f617de21-cbb8-4d52-b120-df4f71ea2028', 'American corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5e9812b2-4706-4630-9102-7f957868f352', 'Tempura flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('418d5e64-e609-4142-a2a4-9a9a5dfbadf8', 'Ginger (minced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8f974b42-40db-44cb-9fe8-6bc2e051e37a', 'Corn', 'Vegetables', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('780e37ae-3109-41e6-ae35-4e21d8f6135a', 'Edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9484e03b-38d5-41f5-9535-8272502acc63', 'Cooked rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fa611188-3f80-4a4c-838e-4c15435261b7', 'Light soy', 'Sauces & Condiments', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9388779f-cba6-46e2-bbc6-76480461ac9a', 'Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dcf6c00b-28d0-4d8a-8652-9c917c4fa8dc', 'Spinach', 'Vegetables', null, 114.3, 1, 'KG', 'Gram', 0.1143, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3d5def55-aacc-4cb8-a79e-f1a384e04b08', 'Button mushroom', 'Vegetables', null, 71.4, 1, 'KG', 'Gram', 0.0714, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dba5805b-c885-4ac4-ab16-1c7d285b7b4a', 'Chili bean paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('49a0ca7e-9a9b-44b8-af54-542d80ba133e', 'Oyster sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('04e9e7e1-b433-4075-a27f-b417de030164', 'Ginger-garlic paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4a2395f6-cf27-49dd-a664-f213fed54595', 'Boiled hakka noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('45de3168-5baa-4e9d-94ce-febf08572375', 'Hakka sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a763c479-554f-4578-bf15-35df015c7b85', 'Mixed mushroom', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5b7dc007-1731-4d0a-9ee3-a6e2a1057101', 'Spring onion whites', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5645f8be-165e-41ad-96d6-41379607f029', 'Flat noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3206e52e-9d0f-4b1b-9215-df88f08b8e22', 'Bean sprouts', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c66b794f-f329-450b-9c0d-8ef8fd805f5b', 'Thai basil', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ceab6ead-9791-44dc-a913-a53cac5c9973', 'Mushrooms', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b95e576a-e4a1-4a9d-ae5f-623c983322a0', 'Rice noodles (soaked)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f6f9dbc1-8725-4881-8e5e-dda56c906946', 'Pad Thai sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d4d84300-0ef6-438c-9237-696d62dcea60', 'Roasted peanuts', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a73e39fa-9cb4-4555-bdb3-52474884d362', 'Lemon wedge', 'Fruits', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('055655ce-fc47-4e9d-b1c5-161ee390baaf', 'Maida noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d5978f51-3455-4a7c-a496-001f70c835db', 'Veg stock', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f5f20538-d1d6-43d0-923b-b10faea8adbb', 'Dashi', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72e3f5e9-d3a4-4ae8-b1a6-cc4b5cfc17dd', 'Shoyu tare', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5a60fa30-60d9-485b-bad2-7163715ed47f', 'Ginger paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f123e77f-2faf-4fd6-bda9-237aa2e2a01e', 'Garlic paste', 'Sauces & Condiments', null, 180, 1, 'KG', 'Gram', 0.18, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0fc70bff-f586-48ec-be9d-30c5c10c1d7b', 'Chilli bean paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dc534384-41b3-4197-be88-8a72d43b89c3', 'Peanut butter', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6033b94a-1c1b-4bd1-addf-0dd62b63f859', 'Ramen noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('502356ac-c62f-4aec-9091-4d3f3ed1de1d', 'Caster sugar', 'Bakery', null, 101, 1, 'KG', 'Gram', 0.101, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('431266c8-7e2b-404b-8664-2a1622b3fc36', 'Chilli powder', 'Spices', null, 1066.7, 1, 'KG', 'Gram', 1.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2f6e4c39-b4f4-4f40-87c7-e683dd40aa66', 'Peanuts (roasted)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('53b8b862-1519-435c-96a2-e43029a153cd', 'Coriander (chopped)', 'Vegetables', null, 182.5, 1, 'KG', 'Gram', 0.1825, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('be37bf00-a6fd-4dcc-bc1e-4447d02dc2bb', 'Spring onion (chopped)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('36e74cf9-830b-42d8-b410-096ed93625dc', 'Edamame (boiled)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('96d04213-e807-4174-8019-b57c948f72e1', 'Pokchoy (blanched)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ff48c30e-da6b-4b06-a94b-096857fd6493', 'Lemon wedges', 'Fruits', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('49174b69-852c-4d53-9075-b24ef171d836', 'Chilli crisp', 'Spices', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0e8b2ab-d3fc-4693-991b-608458c48b34', 'Boiled noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f276465a-30d9-41e8-b2d6-b2004e3ab1cf', 'Spring onion (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cd7dc05f-cba9-4cb5-a770-b7828f6081ad', 'Fried garlic (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('99a5efb7-2882-4dea-8b89-77d6dbffc5e1', 'Spicy Pomodoro Sauce', 'Sauces & Condiments', null, 239.4, 1, 'KG', 'Gram', 0.2394, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('586c41d9-9c05-49c0-8234-2ec26c43aaec', 'Capers', 'Other', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea34363d-cf0a-4540-932f-9a63dc9c2bd4', 'Garlic Ricotta', 'Dairy', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'Basil Pomodoro Sauce', 'Sauces & Condiments', null, 202.6, 1, 'KG', 'Gram', 0.2026, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('80e402f5-2ea6-4a1c-8c82-ce83bec08143', 'Garlic slice', 'Vegetables', null, 285.7, 1, 'KG', 'Gram', 0.2857, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ecb7ca60-c6c1-4628-84bd-da02c812236f', 'Artichoke', 'Other', null, 1020, 1, 'KG', 'Gram', 1.02, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0d25c296-38b5-4c04-a1a9-69ff9d91b35c', 'Feta cheese', 'Dairy', null, 950, 1, 'KG', 'Gram', 0.95, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('031c073f-e923-4450-bfe8-c548514b8e32', 'Marinated Arugula', 'Vegetables', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f9a505c9-9a96-4751-a351-f47bb469eb24', 'Amul Fresh Cream', 'Dairy', null, 206.7, 1, 'KG', 'Gram', 0.2067, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8f490883-4cb7-4a89-86fa-325b2cf4b551', 'Basil Pesto', 'Sauces & Condiments', null, 408.5, 1, 'KG', 'Gram', 0.4085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0ea88338-eb0c-41cb-b288-c46e63870a9d', 'Buffalo Mozrella', 'Other', null, 920, 1, 'KG', 'Gram', 0.92, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('14db6a39-d0d7-417a-9a0e-068f9326e300', 'Garlic oil', 'Oils & Fats', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('912879dd-6874-4db1-8a0f-eaf3981d82dc', 'Gochujgaru', 'Other', null, 4666.7, 1, 'KG', 'Gram', 4.6667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5c003313-ada3-4aae-bedc-9cfcf001249a', 'Buratta cheese', 'Dairy', null, 929.4, 1, 'KG', 'Gram', 0.9294, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('44ed782d-55ea-4bc6-b9b2-5adefa8e4c95', 'Dil leaves', 'Other', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b75bd0d6-578d-48fc-adfe-5597b517298e', 'Chiili crips oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5b6cfb9a-a7e7-42d0-bc92-54f0bdd9e1c9', 'Corn mix', 'Vegetables', null, 321, 1, 'KG', 'Gram', 0.321, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('12c697ac-3ad1-46fc-b730-ead942433bfc', 'Jalapeno slices', 'Beverages', null, 80.3, 1, 'KG', 'Gram', 0.0803, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('191139a1-0ddd-4dd8-a82d-9a420e6b9bae', 'Garlic slices', 'Vegetables', null, 269.8, 1, 'KG', 'Gram', 0.2698, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('01405a39-10fc-4ad0-8e37-09867882cc14', 'Black sesame (crust)', 'Spices', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ccce8cbb-42ab-427e-a918-169a91ee8b67', 'Chilli butter dollop', 'Dairy', null, 509.2, 1, 'KG', 'Gram', 0.5092, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ff1bf991-7da2-4cc0-bdf9-c573a0c7ce41', 'Dynamite crunch', 'Other', null, 464.5, 1, 'KG', 'Gram', 0.4645, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d75af74b-0de6-4c9d-b7ad-a8362f59c408', 'Slice garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d247782b-1ea6-42dd-8e9f-2dc231fa04a0', 'Chooped garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d7a39558-ff35-4cbe-96e2-37419dd389a4', 'Red Sriracha', 'Other', null, 481.6, 1, 'KG', 'Gram', 0.4816, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('35a34219-0cf2-444a-8de2-db22bc2b9a23', 'Smoked cheese', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea96644d-79df-4f72-a217-7a4cde1be930', 'Honey butter drizzle', 'Dairy', null, 433, 1, 'KG', 'Gram', 0.433, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7d472030-5dde-4043-8280-06d4471ff078', 'Chimichurri (chunky)', 'Other', null, 826.4, 1, 'KG', 'Gram', 0.8264, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bd94d143-f5a8-405a-ba1a-b3f560162204', 'Whipped feta dollop', 'Other', null, 949.7, 1, 'KG', 'Gram', 0.9497, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('158ce39a-0bc9-4d03-bc2b-b6d7a2d85257', 'Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7c0d929f-22a2-47f3-beb5-4e2aefb337e9', 'Black olive', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('96124eac-743c-44b3-8fae-4ee0a17ddcd2', 'Green Bellpaper', 'Vegetables', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f78b6c11-caae-4acf-ae5e-21d08e8482d6', 'Marinated Aragula', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e720791b-e45d-463f-b0f4-e601cda4fa7f', 'Slice almond', 'Bakery', null, 834, 1, 'KG', 'Gram', 0.834, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('107ecc43-b9e8-42a3-8a8e-73ab32b4f546', 'Green Chilli', 'Spices', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9588a308-e354-4a4b-9f70-b643ff5d079e', 'Black Sliced Olives', 'Beverages', null, 214, 1, 'KG', 'Gram', 0.214, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8fd5efd8-b88e-4ec1-af27-537560c0245f', 'Ring bell pepper', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('435b2865-4112-4576-bed3-011acd2bfd6d', 'Ring onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ac93c28e-d8d3-4bf4-9f5f-b6bd1ec9d34e', 'Chili oil', 'Oils & Fats', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('640470e4-af50-4624-8bf6-8a0a0ca22ce1', 'Ghost Paper', 'Other', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('435d385f-f893-4d08-8e3d-014cdcc97e0d', 'Roasted Bell paper', 'Vegetables', null, 253.8, 1, 'KG', 'Gram', 0.2538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('344fa3c6-0430-4047-930c-c7da62d009ea', 'Red Paprika Slices', 'Spices', null, 208, 1, 'KG', 'Gram', 0.208, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8196b631-aec0-47e6-8d7f-1ba64d65cfbd', 'Fresh Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ebd4bae9-3477-41b6-9f4f-382c25cff597', 'Green Sriracha Sauce', 'Sauces & Condiments', null, 345.3, 1, 'KG', 'Gram', 0.3453, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('080af581-7528-49f3-999d-5a474bbc6263', 'Ghost Peper', 'Other', null, 5710, 1, 'KG', 'Gram', 5.71, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('051879ec-c975-44c0-9d00-c2135042e39a', 'Buffalo Mozzarella', 'Dairy', null, 820.8, 1, 'KG', 'Gram', 0.8208, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('63556e13-5e35-4e5d-9a2b-3fec43a6d44f', 'Boiled Broccoli', 'Oils & Fats', null, 455, 1, 'KG', 'Gram', 0.455, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9ed6866d-6a96-4547-ac99-b14b4a70137b', 'Red paprika sliced', 'Spices', null, 312.5, 1, 'KG', 'Gram', 0.3125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f300509c-d63a-4f97-89d1-f8329c8f1932', 'Jalapenos', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b8ca9c8e-bdfb-44c7-9533-44bec7d2cfd7', 'Orange sauce', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2209a197-95d7-41f0-bee9-33a4c9a03e89', 'Ornage sauce', 'Sauces & Condiments', null, 227.5, 1, 'KG', 'Gram', 0.2275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('980bb8ac-ed38-417b-aba9-c811719f127b', 'TRUFFLE PASTE', 'Sauces & Condiments', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('454ef1bf-d65d-4bb1-a5b3-8170ac2b9fef', 'Processed Basil Leaves', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('9957a332-4790-4a29-b055-8c70028d343f', 'Processed Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('46bfba68-f94b-4633-87c5-75d82b2343a1', 'Processed Coriander', 'Vegetables', null, 131, 1, 'KG', 'Gram', 0.131, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('50fe8cf4-6cc3-4e97-bdee-8928973552e7', 'Processed Dill Leaves', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('9268abfc-4e40-47f4-b4db-532a3172b84e', 'Processed Green Garlic', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('ddd659ea-3014-45e0-8d86-633ac329692a', 'Processed Iceberg', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('0ac0ecbc-cee9-4620-aabd-e299cfd4350a', 'Processed Mint', 'Other', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f42f617b-0ca3-40d3-9959-a9e36a166266', 'Processed Alphonso Mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('bb434880-2a01-4c6a-9b56-538d9e9176df', 'Processed Arugula', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('501eb23c-9fd8-4e1e-b0d8-986048d7c873', 'Processed Jamun', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('d19d7f1f-d84a-49b7-b11a-e6b871e8dacb', 'Processed Red Chilli', 'Spices', null, 80, 1, 'KG', 'Gram', 0.08, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('a7fc8c41-3bb8-4dd3-a716-c12bf85f35e6', 'Processed Brussels Sprouts', 'Vegetables', null, 900, 1, 'KG', 'Gram', 0.9, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('eb3bcd32-72b1-4f2d-8342-bdb7b0326290', 'Processed Lollo Rosso', 'Other', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('42397711-d15b-4c41-8db6-a07659d8b506', 'Processed Shimeji Mushroom', 'Vegetables', null, 1300, 1, 'KG', 'Gram', 1.3, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('45d5710c-87c8-4337-9bef-94b089161dcb', 'Processed Pineapple', 'Fruits', null, 146.2, 1, 'KG', 'Gram', 0.1462, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('fe650510-bd5a-4c54-b74a-6711725ad849', 'Processed Thai Red Chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('b2ac0879-caf3-47a2-a75b-96328ad9c6c4', 'Processed Bok Choy', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7873d5d9-b5f0-43dd-b35f-cb427a66e067', 'Processed Lemongrass', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7cd99b95-d350-4e4a-973e-7e657007cd75', 'Processed Spinach', 'Vegetables', null, 114.3, 1, 'KG', 'Gram', 0.1143, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('ae7cb6b8-f0b1-4888-8c0b-6b9a17e91c70', 'Processed Baby Corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('10eb2a81-2354-43aa-8a18-d1004c239458', 'Processed Leeks', 'Vegetables', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('d57dd08d-486f-40f4-a592-cbe8000b551b', 'Chopped Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('b97fc4d6-6dbc-4f6a-92b1-bed3d57acf14', 'Chopped Green Chilli', 'Spices', null, 122.5, 1, 'KG', 'Gram', 0.1225, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('c5e0f8a1-0aa4-4229-8dda-ad35fcbca220', 'Chopped Green Garlic', 'Vegetables', null, 507, 1, 'KG', 'Gram', 0.507, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('55d96a24-fd5a-48e8-a019-3781c7ca4f07', 'Chopped Parsley', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('28628d3d-952b-4e37-953f-a89ac0255e70', 'Chopped Spring Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('f50e02ce-a242-4f91-a15d-403bf080f832', 'Chopped Tomatoes', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('5aa4746e-9735-44d7-8928-0cf0ce3600bd', 'Chopped Carrot', 'Vegetables', null, 56.2, 1, 'KG', 'Gram', 0.0562, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('a9d3fb9a-2429-454d-86ee-60da57138930', 'Chopped Ginger', 'Vegetables', null, 128.8, 1, 'KG', 'Gram', 0.1288, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('60087d5c-4cf7-4e69-a8bb-2563ebc7449e', 'Chopped Green Bell Pepper', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('79aabab7-22dc-4f9b-ae3e-4c3ac1bf15c0', 'Chopped Chinese Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('8bd50a68-01c6-4c42-881c-1fad163bfd0e', 'Chopped Indian Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('20d88828-0547-4d03-80c6-de5aa5ef8b8f', 'Sliced Jalapenos', 'Beverages', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('a393f8b1-cfb0-4d34-860d-1087f7209722', 'Sliced Zucchini', 'Beverages', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('3cc44822-e6ed-4345-b7d3-529d1d8e4ea4', 'Sliced Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('1abd1149-7451-4215-94c0-5a25dbd1e911', 'Sliced Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('199384ba-1cdc-4c11-a379-7428a27e42d9', 'Sliced Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('1efbf855-0856-430a-b199-e4c7512e90c2', 'Sliced Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('1143752d-9cdb-4554-b062-db6908676d25', 'Sliced Lotus Root', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('da8607b0-0281-4e43-bfaa-15990366d0fc', 'Sliced Purple Cabbage', 'Vegetables', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('7c2e789d-9697-4302-90a6-c6b79deaa599', 'Thin Sliced White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('4b6dc6de-dc4d-4a4d-afca-32c227dd99ed', 'Cut Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('52b1a192-4bfb-4c3c-a11e-ffca25aa4b8c', 'Cut Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('2d8f4ae6-136a-40ce-8bb1-024a6a1d928c', 'Cut French Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('99e6eeb1-ca40-497c-9534-62c0137eece3', 'Cut Zucchini', 'Other', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('88cdb722-6350-4050-aaae-2b11f34f1890', 'Bell Pepper Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('40aa6f1f-6e91-4ac9-a3bb-08336ce27018', 'Cucumber Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('d2b5e5c6-d916-4726-99c0-751afde32c2b', 'Onion Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('d288d8df-104c-4bae-960a-ba877ad9e4d5', 'Diced Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('59f209b1-8f1a-4e20-af1e-b94b04996675', 'Diced Grapefruit', 'Fruits', null, 1142.9, 1, 'KG', 'Gram', 1.1429, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('b82fae50-c1b1-43f4-bc8f-6f14847b5e9a', 'Lemon Juice', 'Fruits', null, 311, 1, 'KG', 'Gram', 0.311, '2026-06-01', 'active', 'Prep yield (Juiced)', '2026-06-01T09:00:00.000Z'),
('3e96bac9-6f6b-48ed-8152-74287e948133', 'Watermelon Juice', 'Fruits', null, 83.3, 1, 'KG', 'Gram', 0.0833, '2026-06-01', 'active', 'Prep yield (Juiced)', '2026-06-01T09:00:00.000Z'),
('6dc52c52-6aca-45f1-a6c2-cf5969855f23', 'Whole Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('61d0ac35-76d4-4bd4-8a6f-f183eb2467a6', 'Whole Parsley', 'Vegetables', null, 432, 1, 'KG', 'Gram', 0.432, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('84925384-bb93-4927-9258-65e6247b96fd', 'White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('211f7c7c-7738-4f98-a624-2a02e456e5cd', 'Slit Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('6225de37-3902-4e5f-a46d-19e9d6faa198', 'Spring onion 1/2', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('5246576f-7cc7-4fc0-9ffc-ff932b73ad7b', 'Dried Sirarakhong Chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('5d0eaf9b-734a-458c-a166-01348c317573', 'Dolce Vita Peeled Tomatoes - 3kg', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('d1ba4d79-85a5-49f9-8e33-371df11961a2', 'Black Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('f329b400-2b8b-4cf4-9fcb-38fc59f054fd', 'Red Kidney Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('158cb5b0-902a-4dc4-abbd-2a6c49f8945d', 'Artichoke Hearts', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('16cd3b31-233c-4a43-bdd8-e672f2aa0852', 'Capers', 'Other', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('73a2ea7f-c937-4d77-b845-bd14b8510b2a', 'Sliced Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('de0c4172-20fc-4aba-84f8-b4285386d313', 'Black Olives', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('37896100-10a6-4d84-897b-901e5d0cec4f', 'Jalapeño Slices', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('d006afa6-89ef-4e34-82c6-f363ed7990bc', 'Water Chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('a2653a05-b735-4215-a1ff-973ed13267f9', 'Boiled Spaghetti', 'Oils & Fats', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('0d096a1b-bc9e-462c-bcdf-315b6fc62730', 'Boiled Macaroni', 'Oils & Fats', null, 101.8, 1, 'KG', 'Gram', 0.1018, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('5652f212-5cb8-49ae-ad00-a8a4549774a8', 'Boiled Bucatini', 'Oils & Fats', null, 92.3, 1, 'KG', 'Gram', 0.0923, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('c11f8b36-255d-4a51-9dbb-697effaf6aa5', 'Boiled Fettuccini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('d9f53a97-af8c-497d-8795-75bab0296e25', 'Boiled Linguini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('052683da-f6c2-4268-a4b9-fa076e9a2533', 'Boiled Conchiglioni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('7170f702-8b2e-471a-9c06-b1b979a552c3', 'Boiled Rigatoni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('2936057b-bb75-4b58-9885-318dbf7d35e5', 'Boiled Penne', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('20d164fa-a366-4c89-b443-2c500889c7e1', 'Boiled Arborio Rice', 'Oils & Fats', null, 377.2, 1, 'KG', 'Gram', 0.3772, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('760a2d69-0f2b-4cac-b0c2-a3fa9346bac0', 'Orange Zest', 'Fruits', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Zest)', '2026-06-01T09:00:00.000Z'),
('ba09556e-c886-493a-aca1-54de2f1397e5', 'Lemon Zest', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Zest)', '2026-06-01T09:00:00.000Z'),
('cf3c1977-2c34-4f0b-9752-e7ba217a3bf9', 'Beetroot Paste', 'Sauces & Condiments', null, 78.8, 1, 'KG', 'Gram', 0.0788, '2026-06-01', 'active', 'Prep yield (Paste)', '2026-06-01T09:00:00.000Z'),
('c4814b34-ee2b-4987-9c75-9dddef404d36', 'Roasted Bell Pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', 'Prep yield (Roasted)', '2026-06-01T09:00:00.000Z'),
('a18749e1-50bd-434a-bbae-f1fb8bdde679', 'Dehydrated Lemon Slices', 'Fruits', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', 'Prep yield (Dehydrated)', '2026-06-01T09:00:00.000Z'),
('0e041665-2b2a-4666-b2cd-09121ea469f2', 'Julienne Chinese Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('3bb7f6ac-4ea0-4ac3-8131-1083f470aed1', 'Julienne Indian Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('775bfe2c-49c6-429b-9faf-4b1979364248', 'Julienne Leeks', 'Vegetables', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- recipes (124)
insert into public.recipes (id, recipe_name, category, brand, description, image_url, preparation_time, serving_size, status, total_cost, cost_per_portion, selling_price, packaging_cost, wastage_pct, is_prep, yield_quantity, yield_unit, version_no, method, size_code, size_label, approved_at, rejection_note, created_at, updated_at) values
('4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'Chilli Crisp', 'In-House Prep', 'capiche', 'House chilli crisp.', null, 60, 1, 'approved', 1380.26, 1380.26, null, 0, 5, true, 8270, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4b003a23-38e3-4f8a-8459-d70eb6949c6e', 'Bechamel Sauce', 'In-House Prep', 'capiche', 'House bechamel.', null, 30, 1, 'approved', 146.26, 146.26, null, 0, 5, true, 1210, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2af74928-a965-47c8-8029-7cf33a57c792', 'Pizza Dough', 'In-House Prep', 'capiche', 'Cold-proofed pizza dough.', null, 1440, 1, 'approved', 1615.93, 1615.93, null, 0, 5, true, 17288, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', 'Pesto White Base Sauce', 'In-House Prep', 'capiche', 'White base for pesto pasta.', null, 20, 1, 'approved', 26.5, 26.5, null, 0, 5, true, 160, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dc53223c-4efb-4d9e-a81c-c354cefabe10', 'Hydroponic Basil Pesto', 'In-House Prep', 'capiche', 'Fresh basil pesto.', null, 15, 1, 'approved', 206.02, 206.02, null, 0, 5, true, 475, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'Chili Crunch Sauce', 'In-House Prep', 'capiche', 'Uses house chilli crisp.', null, 30, 1, 'approved', 89.02, 89.02, null, 0, 5, true, 418, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4d8ff0fe-db5c-4227-aaf8-0dfba1bd74ec', 'Sesame Sushi Rice', 'In-House Prep', 'aiko', 'Seasoned sushi rice.', null, 40, 1, 'approved', 269.85, 269.85, null, 0, 5, true, 1025, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a11fa265-8d62-4e1a-bb05-ce314294558d', 'Ponzu Wasabi Mayo', 'In-House Prep', 'aiko', 'Ponzu wasabi mayo.', null, 10, 1, 'approved', 18.19, 18.19, null, 0, 5, true, 102, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cf381b35-312e-4d5e-a4be-cf21dec63302', 'Tamarind Water', 'In-House Prep', 'aiko', 'Tamarind extraction.', null, 15, 1, 'approved', 19.95, 19.95, null, 0, 5, true, 300, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', 'Marinated Beetroot Chunks', 'In-House Prep', 'aiko', 'Marinated beetroot.', null, 20, 1, 'approved', 8.79, 8.79, null, 0, 5, true, 68, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4394f7e5-e947-49bd-bcac-72583ec7249b', 'Sri Lankan Red Curry Powder Mix', 'In-House Prep', 'aiko', 'Roasted & ground spice mix.', null, 30, 1, 'approved', 227.85, 227.85, null, 0, 5, true, 87, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c128477d-b8a9-42dd-96ec-5f98895752c9', 'Sri Lankan Red Paste', 'In-House Prep', 'aiko', 'Uses house curry powder.', null, 45, 1, 'approved', 58.39, 58.39, null, 0, 5, true, 243, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ddf39453-4fb6-4167-a017-a5c7adad199d', 'Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 164.65, 164.65, 620, 0, 5, false, 250, 'Gram', 1, ARRAY['Toss leaves with vinaigrette & salt.','Add cherry tomato, grapefruit, olives.','Place burrata in centre.','Arrange salad mix around.','Sprinkle pine nuts; drizzle olive oil & hot honey.','Garnish with edible flowers.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dc2d8050-b193-432c-9b1c-513c28302156', 'Caesar Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 41.12, 41.12, 480, 0, 5, false, 200, 'Gram', 1, ARRAY['Tear leaves.','Slice onion rings.','Toss lettuce with mayo, salt, pepper.','Add parmesan and croutons.','Check seasoning.','Plate; garnish with onion rings.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('08cfc6a3-926a-4874-bd80-44b2a581033e', 'Persimmon Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 187.3, 187.3, null, 0, 5, false, 265, 'Gram', 1, ARRAY['Toss arugula with vinaigrette; do not overdress.','Arrange on chilled serving plate.','Place persimmon and strawberry evenly over greens.','Add burrata as soft dollops; season lightly.','Spoon caviar on burrata; sprinkle pine nuts and edible flowers.','Drizzle hot honey; serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'Summer Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 141.38, 141.38, 680, 0, 5, false, 344.5, 'Gram', 1, ARRAY['Process iceberg lettuce, romaine lettuce, and Lollo Rosso. Give them an ice bath to keep them crisp.','In a large bowl, combine all processed leaves. Add salt, black pepper, and vinaigrette. Add arugula and toss well.','Cut mango and grapefruit into cubes.','Plate the mixed leaves. Place a burrata on top.','Drizzle olive oil over the burrata and add crushed black pepper.','Arrange cubed mango, grapefruit, and cherry tomatoes around the burrata. Add edible flowers.','Scatter roasted hazelnuts and chopped granola.','Finish with a drizzle of hot honey.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'Roasted Red Bell Pepper Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 26.27, 26.27, null, 0, 5, false, 370, 'Gram', 1, ARRAY['Roast veg until soft/charred; cool. Peel peppers if desired.','Blend smooth; strain if desired. Chili; portion 120 g per serve.','Melt a little CDP butter; add 120 g paste, sauté 1 min. Add 160 g water; season; add sour cream; simmer low 3–4 min.','Spread 5 g garlic butter on 70 g sourdough; toast until crisp.','Bowl soup; swirl pesto; sprinkle sesame. Serve hot with bread.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e111f381-8a0f-4a19-8b1f-473bf9b53490', 'Arancini', 'Appetiser', 'capiche', null, null, null, 6, 'approved', 48.04, 48.04, 480, 0, 5, false, 117, 'Gram', 1, ARRAY['Prepare rice mix; cool completely.','Weigh 16 g rice mix, add 3 g mozzarella, shape into ball (~19 g). Repeat for 6.','Dip into batter.','Coat with panko crumbs.','Deep fry at 180 °C for ~4–5 min; core ≈ 74 °C.','Drain; plate with hot mayo & green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('086379c2-ce7b-47de-afff-39190dd5f2d8', 'Dough Balls', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 97.65, 97.65, 540, 0, 5, false, 150, 'Gram', 1, ARRAY['Divide dough into 6–8 × ~20 g balls.','Roll and place on screen.','Bake at 350 °C ~2 min until puffed.','Toss in melted butter, garlic, parsley.','Garnish with green garlic.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1b211811-d9f8-40f7-9cbb-e86dbe2b3140', 'Garlic Bread', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 51.42, 51.42, 540, 0, 5, false, 105, 'Gram', 1, ARRAY['Bake base; cool slightly.','Deep cut into 8 wedges.','Stuff cream cheese between cuts.','Brush with butter + chopped garlic.','Microwave 30 s.','Bake at 350 °C for 2 min until golden; garnish green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f429438b-1713-4275-bb34-e5a55b668404', 'Pasta Fritti 2.0', 'Pasta', 'capiche', null, null, null, 1, 'approved', 159.74, 159.74, null, 0, 5, false, 547, 'Gram', 1, ARRAY['Mix all filling ingredients well.','Cut pasta sheets into 1 x 4 pieces.','Spread ricotta filling, place mozzarella stick and a line of tomato paste. Roll tightly.','Freeze for 15 min.','Dip in batter; coat with bread crumbs.','Deep fry at 160-180 °C for 4-5 min; finish in oven 10-15 sec.','Grate parmesan; top with green garlic.','Serve with garlic ranch & hot tomato sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c3dada6f-d777-4163-8365-d809a2d9ca5d', 'Butter Garlic Mushroom', 'Pasta', 'capiche', null, null, null, 1, 'approved', 115.34, 115.34, 540, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; cook mushrooms.','Add garlic; sauté.','Add basil, parsley; season.','Toss with vinaigrette & chilli flakes.','Add butters.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('46536d70-f83e-4154-ba1f-dc1b137441ce', 'Saucy Brussels Sprouts', 'Vegetable', 'capiche', null, null, null, 1, 'approved', 165.74, 165.74, 580, 0, 5, false, 676, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add Brussels sprouts (cut in halves) and char on high heat.','Add butter, garlic, chilli flakes, salt, pepper, and balsamic vinegar. Toss well.','In another pan, combine cream cheese, béchamel, sour cream, mayonnaise, salt, and black pepper. Cook on low heat until smooth.','Spread the cream cheese sauce on a plate and place the charred Brussels sprouts on top.','Garnish with fresh Bhavnagri chilli, pickled onions, and feta crumbles.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'Miso Tomato Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 47.14, 47.14, 440, 0, 5, false, 1093, 'Gram', 1, ARRAY['Heat olive oil in a pot, add onion, garlic, carrot, chili, thyme, bay leaf, parsley stems. Sauté until soft and lightly golden.','Add tomatoes, cook down until jammy.','Add water and stock powder, simmer 20 min.','Remove bay leaf and thyme stems. Blend until smooth.','Take off heat, whisk in miso paste.','Adjust seasoning with soy, salt, and pepper.','Stir in chopped fresh basil just before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ac0dceb9-b7d5-48c3-8435-e2bed14dd386', 'Pomodoro Spaghetti', 'Pasta', 'capiche', null, null, null, 1, 'approved', 102.17, 102.17, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; sauté cherry tomatoes.','Add pomodoro; season.','Add spaghetti; toss.','Simmer; add butter.','Finish with basil; parmesan garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6e4697bd-e078-4c5c-870f-74d036ae49d2', 'Spicy Tomato & Cream Macaroni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.94, 71.94, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add hot sauce; season.','Add orange sauce; stir.','Add cream; adjust seasoning.','Toss macaroni; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'Alfredo Fettuccine', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.69, 71.69, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil & butter; add garlic, herbs.','Add béchamel; season; adjust with water.','Toss fettuccine; finish with parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b9728f56-1d63-4f29-8622-0e7eb64ae4da', 'Lemon Linguini', 'Pasta', 'capiche', null, null, null, 1, 'approved', 125.42, 125.42, null, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add white sauce, mascarpone.','Add lemon; season.','Toss linguini; adjust with water.','Finish with basil; parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', 'Risotto', 'Pasta', 'capiche', null, null, null, 1, 'approved', 134.96, 134.96, 780, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter+oil; sauté garlic, asparagus, peas.','Add rice; season.','Add water; add béchamel.','Finish with parmesan; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('147a996b-6a3a-4425-9033-3fb10371c6a4', 'Lasagna', 'Pasta', 'capiche', null, null, null, 7, 'approved', 143.63, 143.63, 740, 0, 5, false, 1300, 'Gram', 1, ARRAY['Heat oil in a pan; sauté onion, carrot, celery and garlic until soft.','Add soaked and drained soy chunks; cook for 3–4 min.','Add tomato passata, tomato paste, oregano, salt and pepper. Simmer 15–20 min.','Make béchamel: melt butter, add flour; cook 1 min. Gradually whisk in milk. Cook until thick. Season with salt and nutmeg.','In a baking dish, layer: bolognese sauce, sheets, béchamel, mozzarella. Repeat layers. Top with parmesan.','Bake at 180°C for 40–45 min or until golden and bubbling. Rest 10 min before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8ed796e2-198c-44b4-a4ea-7f0d9a591026', 'Stuffed Conchiglioni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 103.03, 103.03, 780, 0, 5, false, 662, 'Gram', 1, ARRAY['Mix ricotta, cream cheese, blanched kale, chopped jalapeño, salt and xanthan gum into a smooth, well-seasoned filling.','Stuff each boiled conchiglioni generously with the kale-ricotta filling.','Spoon garlic pomodoro sauce as a base in a shallow oven dish.','Arrange stuffed shells on the sauce base.','Sprinkle parmesan and red paprika on top.','Bake at 350°C for 6 min until golden and heated through.','Garnish with slit onion and sunflower seeds.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('207118bd-e060-43c3-9439-4ea7bc8e3d34', 'Caramelised Onion Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 62.24, 62.24, 780, 0, 5, false, 329, 'Gram', 1, ARRAY['Heat olive oil in a pan over medium heat.','Add chopped garlic and sauté until fragrant.','Add caramelised onion and cook for 1–2 min.','Add 1 ladle of water; bring to a gentle simmer.','Add spaghetti and mix well to coat.','Add mix seasoning, fresh cream and soya sauce. Toss until pasta is creamy and well combined.','Adjust consistency with water if needed.','Finish with chilli crisp and parmesan. Toss to combine.','Plate and garnish with fresh parsley. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'Pink Burrata Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 124.8, 124.8, 780, 0, 5, false, 247, 'Gram', 1, ARRAY['Roast beetroot with olive oil wrapped in foil paper. Once roasted, strain and blend into a purée.','Heat a pan. Add pesto white sauce.','Add farfalle pasta. Season with black pepper, chilli flakes, butter, and salt. Mix well.','Add beetroot purée and toss until the sauce turns pink.','Plate and garnish with a smashed burrata dollop, crushed pumpkin seeds and pistachios, olive oil, and crushed black pepper.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2fb60646-23e7-4726-9daa-52f19d401fba', 'Tomato Butter Risotto', 'Risotto', 'capiche', null, null, null, 1, 'approved', 109.5, 109.5, 740, 0, 5, false, 256, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add garlic and onion and sauté until softened.','Add pomodoro sauce, water, salt, and black pepper. Stir well.','Add risotto rice and butter. Cook well, stirring frequently. Finish with Parmesan.','Plate and garnish with confit cherry tomatoes, a pesto dollop, arugula, and chopped kalonji.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('79247968-d17c-4fc3-8d95-21b79b6b7c76', 'Truffle Mac & Cheese', 'Pasta', 'capiche', null, null, null, 1, 'approved', 164.71, 164.71, 840, 0, 5, false, 253, 'Gram', 1, ARRAY['Heat a pan. Add béchamel sauce, cheddar cheese, and mozzarella cheese. Melt together.','Add boiled pasta and mix well. Season with salt and black pepper. Add parmesan and butter.','Transfer into a steel plate. Top with cheddar cheese, mozzarella cheese, and parmesan. Bake in oven.','Remove from oven. Garnish with truffle oil, truffle pâté, and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('815c4b44-1141-46eb-adcd-94bc88f22d93', 'Sticky Toffee Pudding', 'Desserts', 'capiche', null, null, null, 1, 'approved', 52.6, 52.6, 600, 0, 5, false, 215, 'Gram', 1, ARRAY['Bake pudding.','Warm pudding before service.','Plate pudding.','Pour caramel sauce.','Add pecan ice cream.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('de88cea6-18a6-482b-8259-925a2885bd15', 'Brownie With Ice Cream', 'Desserts', 'capiche', null, null, null, 1, 'approved', 108.15, 108.15, 640, 0, 5, false, 185, 'Gram', 1, ARRAY['Bake and portion brownies.','Warm before serving.','Plate brownie.','Add ice cream scoop.','Drizzle Nutella.','Garnish tuile.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1327f36e-fe09-499b-ae5f-199dbaf34c96', 'Pistachio Mousse Cake', 'Desserts', 'capiche', null, null, null, 1, 'approved', 139.58, 139.58, 600, 0, 5, false, 140, 'Gram', 1, ARRAY['Place kunafa base.','Add sponge layer.','Pipe mousse.','Garnish with white chocolate décor.','Add pistachio crumble if available.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1188e820-37b0-4b09-b151-8313fde0eca6', 'Tiramisu 3.0', 'Desserts', 'capiche', null, null, null, 1, 'approved', 111.93, 111.93, 640, 0, 5, false, 115, 'Gram', 1, ARRAY['Layer sponge.','Add mascarpone mousse.','Add coffee cream.','Top with sable and tuile.','Chill to set.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5e9fa5ff-f92b-4106-a46d-89426b1d1f8c', 'Lemon Iced Tea', 'Drinks', 'capiche', null, null, null, 1, 'approved', 14.66, 14.66, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Glass & ice (0:00-0:10): Fill with cubed ice.','Build (0:10-0:35): Add lemon juice and sugar syrup.','Top (0:35-1:00): Add iced tea to reach 300 ml net.','Garnish & QC (1:00-1:20): Stir once; garnish with dried lemon.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b592c9fd-3f66-497e-9bd1-d4353b04a3e9', 'Mint Mojito', 'Drinks', 'capiche', null, null, null, 1, 'approved', 19.13, 19.13, 360, 0, 5, false, 245, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill with cubed ice.','Build (0:10–0:25): Add lemon juice and mint syrup.','Top (0:25–0:50): Add soda; gentle lift with bar spoon.','Garnish & QC (0:50–1:10): Slap mint; place at rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('718dca2b-cf84-4a43-a95a-2418fafe05b3', 'Pina Colada', 'Drinks', 'capiche', null, null, null, 1, 'approved', 84.9, 84.9, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Load (0:00-0:20): All ingredients incl. ice in blender.','Blend (0:20-0:50): Smooth, ~30 s.','Pour & garnish (0:50-1:20): Into chilled glass; garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5521cedc-3c5d-432e-8a88-2bd951a45a5e', 'Moscow Mule', 'Drinks', 'capiche', null, null, null, 1, 'approved', 91.7, 91.7, 360, 0, 5, false, 320, 'Gram', 1, ARRAY['Fill mule mug with cubed ice.','Add lemon juice and ginger zest into mug.','Add ginger beer to 320 ml; stir gently with bar spoon; lift once.','Garnish with lemon wheel and rosemary sprig.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dc42b99b-2d55-4c36-a1fc-32c0e27228c7', 'Sunset Cocktail', 'Drinks', 'capiche', null, null, null, 1, 'approved', 67.54, 67.54, 300, 0, 5, false, 230, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:30): Add lemon juice, orange juice, and hibiscus syrup.','Top (0:30–0:55): Add Sprite to 230 ml; pour gently over the back of a spoon for a layered effect; gentle lift.','Garnish & QC (0:55–1:15): Garnish with fresh jalapeño slice on rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cd68a8c8-0bde-481b-aa85-535e90b9b7e8', 'Tamarind Fizz', 'Drinks', 'capiche', null, null, null, 1, 'approved', 56.97, 56.97, 300, 0, 5, false, 220, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:25): Add tamarind syrup and salt.','Top (0:25–0:50): Top with Schweppes Ginger Ale to 220 ml; stir gently; lift once.','Garnish & QC (0:50–1:15): Garnish with basil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0f832199-7143-4afa-bb36-a34fcce74e06', 'Tom Yum', 'Soups', 'aiko', null, null, null, 1, 'approved', 17.46, 17.46, 360, 13.12, 5, false, 198, 'Gram', 1, ARRAY['Blend chilli, onion, garlic, mushroom to coarse paste.','Cook paste until aromatic.','Add tamarind, water, vinegar, sugar; simmer 8-10 min.','Adjust hot-sour balance as per standard.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3b6ce92e-7947-476a-9974-682ac04ddefe', 'Thai Spring Roll', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 4.41, 4.41, null, 0, 5, false, 196.75, 'Gram', 1, ARRAY['Place approximately 30 g Thai spring filling on each spring roll sheet.','Roll tightly while folding the sides inward. Seal the edge using slurry/water if required.','Heat oil to 170-175°C. Carefully fry spring rolls until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Serve spring rolls as entire pieces. Drizzle with sriracha sauce. Garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d524b0bc-b2be-47bc-a3ae-be2e5476142e', 'Kwispy Lotus Root', 'Sides', 'aiko', null, null, null, 1, 'approved', 32.05, 32.05, 460, 0, 5, false, 166, 'Gram', 1, ARRAY['Fry lotus root until crisp; drain well.','Heat wok; add garlic + chilli; sauté briefly.','Add onion + bell pepper; toss 30–40 sec.','Add sauce + pok choy; bring to bubble.','Add lotus root; toss quickly to coat.','Finish spring onion + basil; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ca5f1671-1090-4a66-9f52-45cc860d149e', 'Kwispy Wonton', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 33.04, 33.04, 460, 0, 5, false, 96, 'Gram', 1, ARRAY['Place approx. 15 g of Kwispy Wonton filling in the center of each gyoza skin.','Apply corn slurry on the edges. Fold and seal tightly in desired shape.','Heat oil to 170–175°C. Carefully drop wontons into hot oil.','Fry for 3–4 minutes or until golden brown and crispy.','Remove and drain excess oil on paper towel.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('661af458-fded-4192-8113-598f06fb26a5', 'Tteokbokki', 'Sides', 'aiko', null, null, null, 1, 'approved', 108.6, 108.6, 540, 0, 5, false, 170.13, 'Gram', 1, ARRAY['Blanch rice cakes until soft; drain well.','Heat pan; add water + sauce; bring to simmer.','Add rice cakes; toss to coat.','Add salt, MSG, sugar; reduce until glossy.','Finish spring onion + fried garlic; garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5568b7f5-5eb6-4d02-8a43-fe095f521bc0', 'Tofu Bao', 'Dimsum', 'aiko', null, null, null, 1, 'approved', 40.95, 40.95, 540, 0, 5, false, 223, 'Gram', 1, ARRAY['Mise en place: Keep all ingredients measured and ready. Slice cucumber into thin strips. Prepare coleslaw chilled. Heat oil to 170-175°C. Steam bao until soft and warm.','Coat tofu evenly with tofu batter.','Deep fry at 170-175°C until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Open warm bao carefully without tearing.','Spread bao sauce base evenly inside the bao.','Add coleslaw followed by crispy tofu.','Place cucumber strips neatly on top.','Garnish with black & white sesame.','Serve immediately while bao is warm and tofu is crispy.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c4cab38c-88b8-4148-9e21-728490324ce4', 'General Tso''s Water Chestnuts', 'Sides', 'aiko', null, null, null, 1, 'approved', 81.22, 81.22, 540, 0, 5, false, 318, 'Gram', 1, ARRAY['Coat water chestnut with flour; shake off excess. Deep fry until golden and crispy; drain.','Heat wok on high flame. Add chopped garlic, Thai red chilli and onion; stir-fry until aromatic.','Add yellow and red bell peppers; stir-fry until slightly soft yet crunchy.','Add sauces (gyoza dip + drunken sauce); bring to a simmer and stir until the glaze thickens.','Add fried water chestnuts and spring onion; toss quickly to coat. Finish with basil. Transfer to serving bowl. Garnish with fried spring roll strips.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2c6054e1-2a32-4291-8449-079d33eae21b', 'Steamed Edamame (Chilli / Salted)', 'Sides', 'aiko', null, null, null, 1, 'approved', 104.77, 104.77, 540, 0, 5, false, 172, 'Gram', 1, ARRAY['Steam edamame with pods until tender and hot. Drain any excess water.','Transfer steamed edamame to a bowl.','For chilli version: Add chilli crisp and toss evenly to coat. For salted version: Add salt and toss evenly to coat.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b8b9451c-0335-4903-bd1d-28cf4544572a', 'Korean Mandu', 'Sides', 'aiko', null, null, null, 1, 'approved', 52.77, 52.77, 540, 0, 5, false, 106, 'Gram', 1, ARRAY['Prepare Korean Mandu filling (see filling method below). Allow to cool completely.','Place 1 portion (approx. 75 g) of filling in the center of the gyoza skin.','Moisten edges with water. Fold and pleat to seal securely.','Heat oil to 175°C. Fry mandu until golden brown and crisp, about 3–4 minutes. Drain excess oil.','Drizzle spicy mayo and coriander mayo over mandu.','Garnish with toasted white sesame seeds and julienne cut nori sheets.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bbfed023-5ef3-4436-a33f-f68cc553cc39', 'Creamy Corn Rocks', 'Sides', 'aiko', null, null, null, 1, 'approved', 71.65, 71.65, 580, 0, 5, false, 244, 'Gram', 1, ARRAY['Heat corn rocks sauce in a pan over medium heat.','Add water and stir well to adjust the consistency. Bring to a simmer.','Add fried corn and toss to coat evenly with the sauce.','Cook for 1–2 minutes until the sauce clings to the corn and is creamy.','Transfer to a bowl.','Garnish with chopped black sesame seeds, spring onion and pickled red paprika slices. Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', 'Kwispy Scallion Pancake', 'Sides', 'aiko', null, null, null, 1, 'approved', 9.18, 9.18, null, 0, 5, false, 267, 'Gram', 1, ARRAY['Prepare all components as per recipes below.','Cook scallion pancake until golden brown and crispy on both sides.','Heat Sichuan soy glaze and brush over the pancake.','Drizzle green garlic cream cheese and sriracha sauce over the top.','Top with scallion salad.','Sprinkle toasted white sesame seeds.','Slice or serve whole.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1700888c-cefa-4ee8-877d-f8a6bd0e80d1', 'Cold Spicy Sesame Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 71.18, 71.18, 640, 0, 5, false, 260, 'Gram', 1, ARRAY['Cook soba noodles as per package instructions. Rinse in cold water and drain well.','In a bowl, add cold spicy sesame sauce and place the noodles. Toss well to coat evenly.','Arrange cucumber slices, carrot slices and mix iceberg romaine on the side of the plate.','Place the sauced noodles in the center.','Top with white part spring onion, crushed peanuts and fried sesame.','Serve immediately. Keep chilled until serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1ad11d34-fc17-4d29-ada3-4c51600c81d6', 'Tokyo Style Pizza (Dough Base)', 'Pizza', 'aiko', null, null, null, 1, 'approved', 422.91, 422.91, null, 0, 5, false, 150, 'Gram', 1, ARRAY['Combine water and dry yeast.','Add flour and mix until shaggy.','Cover loosely and ferment 12–16 h at room temp.','Add fermented biga in mixer.','Add cold water gradually.','Add flour and dry yeast; mix.','Add salt; mix 4–5 min.','Drizzle EVOO; mix smooth (windowpane test).','Rest 1–2 h.','Divide into 150 g balls.','Place in oiled trays; cover.','Cold-ferment (CF) 48 h.','Remove dough; temper 1 h.','Spread/stretch dough evenly.','Apply pizza sauce evenly.','Top evenly with cheese and desired toppings.','Bake in a preheated oven until crust is blistered and golden.','Finish with fresh basil after baking.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('964002ee-ab38-4dcc-aeed-72337888907c', 'Katsu Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 36.46, 36.46, 580, 0, 5, false, 481, 'Gram', 1, ARRAY['Heat katsu curry gently (do not boil).','Heat tofu if required.','Plate rice.','Arrange tofu, pour curry.','Garnish cabbage, cucumber, sesame, togarashi.','Finish scallion oil + unagi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8f97dbfe-173e-4618-8170-4ce6f3654c48', 'Thai Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 131.54, 131.54, 580, 0, 5, false, 961, 'Gram', 1, ARRAY['Cook green paste 60-90 sec until aromatic.','Add coconut milk and water; simmer gently.','Add vegetables and cook until just tender.','Season with MSG, white pepper and stock powder.','Serve with rice; finish with scallion oil, chilli oil, sesame mix and lotus stem.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'Sri Lankan Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 131.11, 131.11, null, 0, 5, false, 507.5, 'Gram', 1, ARRAY['Heat oil in a pan.','Add Kashmiri chilli powder, Kashmiri chilli red paste and Sri Lankan red paste. Sauté until aromatic.','Add tamarind water and stir well.','Pour in coconut milk, stock water and water. Mix and bring to a simmer.','Season with MSG, salt, white pepper, stock powder and fresh Sri Lankan red curry powder mix.','Add tofu, carrot, mushroom and shimeji mushroom. Cook until vegetables are tender.','Add picked red paprika and slit onion. Simmer for 1-2 minutes.','Finish with red chilli oil.','Garnish with basil leaves and fried onion.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'Custom Stir Fry', 'Mains', 'aiko', null, null, null, 1, 'approved', null, null, null, 0, 5, false, 5256.1, 'Gram', 1, ARRAY['Heat wok until smoking hot.','Add oil and aromatics.','Add selected vegetables.','Toss on high flame.','Add preferred sauce.','Cook until vegetables remain crisp tender.','Finish with garnish selection.','Serve immediately hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dff54880-f712-41ef-b57b-2f5153b02c62', 'Chestnut Gyoza', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 64.05, 64.05, 540, 0, 5, false, 793, 'Gram', 1, ARRAY['Prepare filling: mix/chop chestnut with chillies and onion. Cook until aromatic.','Season with stock powder, MSG, white pepper, salt.','Add slurry; cook until mixture binds. Cool completely.','Fill wrappers with 18 g filling; pleat tightly.','Pan-fry gyoza in oil until base golden.','Add water, cover and steam 4–5 min.','Remove lid; re-crisp base 30–45 sec.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'Okonomiyaki Gyoza (6 Pcs)', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 105.16, 17.53, null, 0, 5, false, 894, 'Gram', 1, ARRAY['Cook stages 1→4 sequentially; dry the mix fully. Fold in pickled ginger and tempura flakes.','Fill gyoza skins with filling; pleat tightly (18 g filling per gyoza).','Heat non-stick pan; add oil. Place gyoza; pan-fry until base golden.','Add water, cover and steam for 4–5 minutes.','Remove lid; re-crisp base for 30–45 seconds.','Plate in a fan pattern.','Drizzle mustard mayo and soy-ketchup glaze.','Garnish with chilli, spring onion and sesame.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('422ae84e-7045-43f1-b081-a696b1617752', 'Truffle Edamame Dimsums', 'Dimsum', 'aiko', null, null, null, 4, 'approved', 138.89, 138.89, 840, 0, 5, false, 358, 'Gram', 1, ARRAY['Pulse edamame to coarse mince.','Mix with cream cheese, salt, pepper, truffle oil, truffle pate; add water to adjust texture.','Fill wrappers evenly and seal.','Steam 4–5 minutes until cooked.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('798efa84-8bf1-4fb9-875a-ebd11830121c', 'Saucy Momos', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 39.31, 39.31, 480, 0, 5, false, 1500, 'Gram', 1, ARRAY['Sauté onion until translucent.','Add cabbage and carrot; cook on high flame until moisture evaporates.','Add spring onion and silken tofu.','Add salt, white pepper, MSG and stock powder.','Mix well and cook until dry.','Cool completely before shaping.','Place required filling in the center of each wrapper.','Pleat and seal properly.','Ensure no leakage and even shape.','Place momos in steamer.','Steam for 4–5 minutes until fully cooked.','Heat sauce base (prepared as per recipe) in a pan.','Simmer gently and adjust consistency.','Keep warm for service.','Spread hot sauce in serving plate or bowl.','Place steamed momos on top.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1f23502b-cea2-428b-90ff-907ea1fb971c', 'Cheese Chilli Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 106.28, 106.28, 480, 0, 5, false, 636.5, 'Gram', 1, ARRAY['PREPARE FILLING: Mix all filling ingredients thoroughly. Chill the filling for easy wrapping.','ASSEMBLE DUMPLINGS: Place required filling in the center of each wrapper. Seal edges tightly to form momos.','STEAM: Steam dumplings for 4-5 minutes until cooked.','PREPARE SAUCE: Blend or crush all sauce ingredients to a smooth paste. Heat in a pan and simmer. Adjust consistency and seasoning as required.','PLATE: Spread green sauce on the base of the plate. Place steamed dumplings on top.','GARNISH: Top with fried onion and pickled red Bhavnagri.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fcfac89e-c20b-44d5-a249-16ad72367953', 'Chilli Oil Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 62.35, 62.35, 620, 0, 5, false, 227, 'Gram', 1, ARRAY['Prepare filling: Mix all filling ingredients thoroughly. Refrigerate for 15-20 min for easier handling.','Make chilli oil dumplings paste: Blend all paste ingredients to a smooth, thick paste. Store in an airtight container.','Assemble dumplings: Place required filling in the center of each wrapper. Seal edges tightly to form dumplings.','Steam dumplings: Steam for 4-5 minutes until fully cooked.','Prepare sauce: Heat oil in a pan, add chilli paste and saute for 30 seconds. Add stock water, red chilli powder, salt, msg, stock powder and Sichuan powder. Stir well. Simmer for 2-3 minutes. Adjust seasoning.','Finish & plate: Spread hot sauce on serving plate. Place steamed dumplings on top. Garnish with toasted peanuts, white & green spring onion and fried glass noodles. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'New Dimsum Platter', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 200.19, 200.19, 1640, 0, 5, false, 125, 'Gram', 1, ARRAY['Prepare Dumplings: Ensure all dim sums are prepared, sealed and ready to steam.','Steam Dumplings: Steam all dumplings for 4-5 minutes on medium heat until cooked.','Prepare Dips & Sauces: Portion dips and sauces as per the given gram weight in small bowls.','Assemble Platter: Arrange all dim sums in a bamboo steamer as shown. Place the dip bowls in the centre or alongside.','Serve: Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c5164180-a806-4568-b614-66600cb1d277', 'Avocado Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 186.3, 186.3, 840, 0, 5, false, 464.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice avocado and cucumber into thin batons.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add cucumber and avocado.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Brush roll with buffalo sauce.','Coat with black and white sesame seeds.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top with thin avocado slices.','Add crispy rice paper piece.','Drizzle unagi sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('44c65850-1aed-4743-84b2-c2cdf7ca20a0', 'Dragon Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 86.42, 86.42, 720, 0, 5, false, 253.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper into thin strips.','Trim and cut spring onion.','Ensure fried lotus stem is crisp and ready.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add red bell pepper, spring onion and fried lotus stem.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Drizzle spicy mayo on top.','Spoon dragon sauce over mayo.','Ensure even topping on all pieces.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'Volcano 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 71.66, 8.96, null, 0, 5, false, 362.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper and cucumber into thin strips.','Julienne carrot and spring onion.','Dice mango into small cubes.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add spring onion, carrot, red bell pepper, cucumber and mango.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Add spicy mayo on top.','Sprinkle chilly crisps and oil.','Garnish with micro greens.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a9c5483d-5157-48d0-ba27-6e13d188afe0', 'Gimbap 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 111.12, 111.12, 980, 0, 5, false, 325.2, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice cucumber, carrot and pickled radish into thin strips.','Sauté spinach with soy sauce and garlic. Cool.','Cut tofu into strips and toss with soy sauce.','Slice unagi into strips.','Place nori sheet on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','Arrange tofu, unagi, radish, cucumber, carrot and spinach horizontally.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Wipe blade after each cut.','Brush lightly with sesame oil.','Sprinkle sesame seeds if required.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b3e34399-81ac-4d92-865c-6f3a74d487c3', 'Bombay Blues Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 70.02, 8.75, null, 0, 5, false, 311.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Finely slice spring onion, carrot, cucumber, red capsicum and jalapeño.','Chop coriander.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, spring onion, carrot, cucumber, red capsicum, jalapeño and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top each piece with salsa and tempura flex.','Drizzle sweet chilli sauce, unagi sauce and sriracha.','Serve with soy sauce, pickled ginger and wasabi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'Jalapeño Popper Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 77.82, 9.73, null, 0, 5, false, 264.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice jalapeño into thin rings.','Finely chop coriander and spring onion.','Cut raw mango into thin julienne strips.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, jalapeño, raw mango, spring onion and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Roll in fried spring roll for extra crunch.','Spread a thin layer of cream cheese.','Coat the roll evenly with bread crumbs.','Heat oil to 180°C and flash fry until golden and crisp.','Drain on paper towel.','Drizzle unagi sauce and sriracha on top.','Garnish with coriander and sesame seeds.','Slice 8 equal pieces using a sharp knife.','Clean the knife after each cut.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d788cae5-9dde-4258-8021-ab14e8cec0aa', 'Corn Tempura Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 140.24, 140.24, 720, 0, 5, false, 399.8, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Drain corn well.','Batter corn with tempura flour and deep fry until golden and crisp.','Slice cucumber and purple cabbage into thin juilenne strips.','Finely chop spring onion.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, cucumber, purple cabbage, spring onion and corn tempura.','Roll tightly using mat, applying even pressure.','Moisten knife and slice into 8 equal pieces.','Clean knife after each cut.','Drizzle sriracha on top.','Serve with pickled ginger, wasabi and soy sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ed0911d1-82d7-476c-b26c-7a46fe1d0af0', 'Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 380.4, 'Gram', 1, ARRAY['Heat wok on high heat until smoking.','Add oil, then ginger; sauté for 10–15 sec.','Add carrot, corn, edamame; toss for 60–90 sec.','Add cooked rice; toss until steamy hot.','Add stock powder, salt, white pepper, MSG; toss.','Add light soy; toss evenly.','Add spring onion; toss and plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('aad47994-eaa3-4dc0-9076-8b25573f2039', 'Burnt Garlic Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 424.4, 'Gram', 1, ARRAY['Heat wok on medium-high until hot.','Add oil, then garlic; sauté on medium until pale golden (do not burn).','Increase heat; add broccoli, baby corn and spinach; toss 60–90 sec.','Add cooked rice; toss on high heat until heated through.','Add stock powder, salt, white pepper and MSG; toss evenly.','Add light soy; toss evenly.','Plate and top with fried garlic and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7973f3c7-3640-4d9d-ada9-12307928700e', 'Mushroom Truffle Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 235.98, 235.98, 680, 0, 5, false, 410.6, 'Gram', 1, ARRAY['Heat wok on high until smoking.','Add oil and garlic; sauté for 10 sec until aromatic.','Add mushrooms; cook until moisture evaporates and mushrooms brown.','Add chili bean paste, oyster sauce and hot sauce; toss for 15-20 sec.','Add rice and edamame; toss on high heat until rice is hot and everything combined.','Add white pepper, truffle pâté and MSG; toss evenly.','Switch off heat; fold in truffle oil. Plate and serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7f67a802-366a-40d0-9993-ae5ca33e1d14', 'Hakka Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 36.96, 36.96, 580, 0, 5, false, 275.3, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and ginger-garlic; sauté 10-15 sec.','Add vegetables; toss 60-90 sec (keep crunchy).','Add noodles; toss to separate strands.','Add hakka sauce + stock powder, salt, white pepper, MSG; toss on high heat.','Finish spring onion; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('db739d48-8c61-41d8-88fa-8a9cb9cde4c2', 'Drunken Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 38.55, 38.55, 580, 0, 5, false, 269, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and garlic + chilli; sauté 10–15 sec.','Add mushrooms; toss until lightly browned.','Add spring onion whites; stir-fry briefly.','Add noodles + drunken sauce; toss until glossy.','Add bean sprouts + basil; toss 20–30 sec.','Plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'Pad Thai', 'Noodles', 'aiko', null, null, null, 1, 'approved', 65.61, 65.61, 580, 0, 5, false, 345, 'Gram', 1, ARRAY['Heat wok medium-high; add oil.','Add ginger-garlic; sauté 10 sec.','Add mushrooms and carrot; toss 60 sec.','Add noodles and pad thai sauce; toss until absorbed.','Add sprouts; toss 15–20 sec.','Plate and finish with spring onion, peanuts and coriander.','Serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2076b69b-e118-4a9e-89e1-9d977236100e', 'Shoyu Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 42.6, 42.6, 640, 0, 5, false, 361, 'Gram', 1, ARRAY['Bring stock + dashi to gentle simmer.','Add shoyu tare + seasoning; simmer 3-4 min (no hard boil).','Cook noodles separately; drain well.','Place noodles in bowl; pour hot broth.','Top vegetables; finish sesame + scallion oil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e5dd7684-0776-43f0-8296-69a136cec157', 'Peanut Butter Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 61.81, 61.81, 640, 0, 5, false, 606.5, 'Gram', 1, ARRAY['Heat oil; sauté ginger + garlic.','Add gochujang + chilli bean paste + chilli powder; bloom 30–40 sec.','Add water gradually; whisk smooth.','Add peanut butter; whisk until emulsified.','Season; simmer 2–3 min.','Cook noodles separately; assemble bowl.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b252581e-3d7c-4c40-9a50-15f334813c47', 'Spiced Miso Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 47.47, 47.47, null, 0, 5, false, 692.5, 'Gram', 1, ARRAY['Heat oil in a pot over medium heat; add ginger and garlic paste, sauté until aromatic.','Add gochujang, chilli bean paste and chilli powder; bloom for 30–40 sec.','Gradually add water while whisking to avoid lumps.','Add peanut butter and whisk continuously until fully emulsified.','Season with stock powder, MSG, white pepper, salt and caster sugar. Simmer for 2–3 min.','Cook ramen noodles separately as per instructions; drain well.','Assemble the bowl with noodles and hot broth.','Top with peanuts, coriander, spring onion, edamame and pokchoy.','Drizzle with chilli oil and serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e0230580-229b-4ab2-955a-fd2865b15f57', 'Buttery Chilli Garlic Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 24.29, 24.29, 580, 0, 5, false, 211.8, 'Gram', 1, ARRAY['Melt butter on low heat.','Add garlic + chilli; cook gently until aromatic.','Add chilli crisp + seasoning; whisk with 10–15 ml hot water to emulsify.','Add noodles; toss until glossy and coated.','Plate; top with spring onion and fried garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 147.5, 147.5, 940, 24.46, 5, false, 831, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 129.39, 129.39, null, 24.46, 5, false, 482, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('75516606-d2e3-4636-8363-7068ca1e9dcd', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 165.84, 165.84, 940, 24.46, 5, false, 880, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 147.34, 147.34, null, 24.46, 5, false, 515, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 112.9, 112.9, 940, 24.46, 5, false, 695, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('86c457bb-abf5-41f8-9afc-676a6c82ca71', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 100.58, 100.58, null, 24.46, 5, false, 395, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('57316417-3958-453c-843e-860dda9979f0', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 136.63, 136.63, 1140, 24.46, 5, false, 620, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('78731781-418f-4c10-9092-d536f45729b7', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 134.15, 134.15, null, 24.46, 5, false, 364, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 220.88, 220.88, 1140, 24.46, 5, false, 935, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 213.79, 213.79, null, 24.46, 5, false, 576, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1333fc6f-fc85-4222-a476-7159744667aa', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 129.23, 129.23, 1140, 24.46, 5, false, 812, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c5c773ba-8b31-4844-a7de-c039f5f44018', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.82, 131.82, null, 24.46, 5, false, 471.48, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('07a1fccb-6beb-4d93-aaa8-1fa8e767f594', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.88, 128.88, 940, 24.46, 5, false, 700, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('95138267-2f84-4bbc-8809-d9888d4e725c', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 108.55, 108.55, null, 24.46, 5, false, 410, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f6512ca1-43cb-4273-9fca-c6a914ac6f8d', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.85, 111.85, 1140, 24.46, 5, false, 670, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e066b614-1f73-44f3-b659-2c23cdad5cca', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 122.24, 122.24, null, 24.46, 5, false, 389.04, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3fe6dc27-0456-4dcf-ba4e-856797279ee5', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.2, 125.2, 940, 24.46, 5, false, 650, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3348bc9a-60fb-43d9-8f72-819d66eb8f3a', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 110.73, 110.73, null, 24.46, 5, false, 373, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('995d707d-5053-4917-a234-0ea59da2bcf3', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 116.11, 116.11, 940, 24.46, 5, false, 690, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('71665e32-bd11-4ba4-b7a1-9678bc8bd43c', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 104.19, 104.19, null, 24.46, 5, false, 405, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('be16fdaa-27a0-493e-b482-d13be9b8dc2a', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 156.21, 156.21, 940, 24.46, 5, false, 855, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('17ebf2cc-4c4c-4212-a0a7-8d5853e90648', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 140.68, 140.68, null, 24.46, 5, false, 511, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('01bab03e-4e00-4ece-843d-97dad1315615', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 113.09, 113.09, 940, 24.46, 5, false, 745, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('07f377e4-9c06-4abc-af0d-655d83936e7c', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 92.4, 92.4, null, 24.46, 5, false, 443, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d18145e0-0526-4344-b1d3-c8af18bf4b6c', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.6, 128.6, 940, 24.46, 5, false, 691.5, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f427239d-54d0-427a-b270-daccf1de7943', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 107.24, 107.24, null, 24.46, 5, false, 399, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('67b65fac-a5d1-4a89-8257-5f53c663b12f', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.13, 131.13, 940, 24.46, 5, false, 712.35, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('720f7c1f-a127-493f-89d0-71b2d3ecb2a7', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 118.26, 118.26, null, 24.46, 5, false, 421.5, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3428969-33f7-427b-b5cd-a42975596575', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.63, 125.63, 940, 24.46, 5, false, 615, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 104.25, 104.25, null, 24.46, 5, false, 358, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d4ccef63-90a7-4533-9850-a6f9239bbb57', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.5, 131.5, 940, 24.46, 5, false, 735, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7e6e9415-4916-4658-9bcb-0dae83920d48', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.12, 111.12, null, 24.46, 5, false, 415, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('54a2b89d-5b77-440e-b990-f5a1aff1083b', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.21, 125.21, 940, 24.46, 5, false, 740, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('56a9d690-1c53-4fa9-b1ad-f44c4232b181', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 101.95, 101.95, null, 24.46, 5, false, 420, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('feaa0284-88d9-4c9d-88aa-0a306bf06a73', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 106.53, 106.53, 1140, 24.46, 5, false, 595, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a30a809d-ea58-4466-ad8c-1d45435b9328', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 81.26, 81.26, null, 24.46, 5, false, 330, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b68fb97b-0f42-46bc-a292-d4d33b482c0f', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 189.25, 189.25, 1140, 24.46, 5, false, 630, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 169.03, 169.03, null, 24.46, 5, false, 351, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- pizza variant → master links
update public.recipes set parent_recipe_id = '6f1ae7ba-1b2f-4722-987e-5b92789bd59c' where id = 'c4e48070-3c76-40a1-aa9c-898dd52d50a6';
update public.recipes set parent_recipe_id = '75516606-d2e3-4636-8363-7068ca1e9dcd' where id = 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500';
update public.recipes set parent_recipe_id = '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2' where id = '86c457bb-abf5-41f8-9afc-676a6c82ca71';
update public.recipes set parent_recipe_id = '57316417-3958-453c-843e-860dda9979f0' where id = '78731781-418f-4c10-9092-d536f45729b7';
update public.recipes set parent_recipe_id = 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a' where id = '8d2f5dfc-b840-4a04-9da3-3621611cfa45';
update public.recipes set parent_recipe_id = '1333fc6f-fc85-4222-a476-7159744667aa' where id = 'c5c773ba-8b31-4844-a7de-c039f5f44018';
update public.recipes set parent_recipe_id = '07a1fccb-6beb-4d93-aaa8-1fa8e767f594' where id = '95138267-2f84-4bbc-8809-d9888d4e725c';
update public.recipes set parent_recipe_id = 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d' where id = 'e066b614-1f73-44f3-b659-2c23cdad5cca';
update public.recipes set parent_recipe_id = '3fe6dc27-0456-4dcf-ba4e-856797279ee5' where id = '3348bc9a-60fb-43d9-8f72-819d66eb8f3a';
update public.recipes set parent_recipe_id = '995d707d-5053-4917-a234-0ea59da2bcf3' where id = '71665e32-bd11-4ba4-b7a1-9678bc8bd43c';
update public.recipes set parent_recipe_id = 'be16fdaa-27a0-493e-b482-d13be9b8dc2a' where id = '17ebf2cc-4c4c-4212-a0a7-8d5853e90648';
update public.recipes set parent_recipe_id = '01bab03e-4e00-4ece-843d-97dad1315615' where id = '07f377e4-9c06-4abc-af0d-655d83936e7c';
update public.recipes set parent_recipe_id = 'd18145e0-0526-4344-b1d3-c8af18bf4b6c' where id = 'f427239d-54d0-427a-b270-daccf1de7943';
update public.recipes set parent_recipe_id = '67b65fac-a5d1-4a89-8257-5f53c663b12f' where id = '720f7c1f-a127-493f-89d0-71b2d3ecb2a7';
update public.recipes set parent_recipe_id = 'f3428969-33f7-427b-b5cd-a42975596575' where id = 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f';
update public.recipes set parent_recipe_id = 'd4ccef63-90a7-4533-9850-a6f9239bbb57' where id = '7e6e9415-4916-4658-9bcb-0dae83920d48';
update public.recipes set parent_recipe_id = '54a2b89d-5b77-440e-b990-f5a1aff1083b' where id = '56a9d690-1c53-4fa9-b1ad-f44c4232b181';
update public.recipes set parent_recipe_id = 'feaa0284-88d9-4c9d-88aa-0a306bf06a73' where id = 'a30a809d-ea58-4466-ad8c-1d45435b9328';
update public.recipes set parent_recipe_id = 'b68fb97b-0f42-46bc-a292-d4d33b482c0f' where id = '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673';

-- recipe_ingredients (1246)
insert into public.recipe_ingredients (id, recipe_id, ingredient_id, component_type, quantity_used, unit_used, calculated_cost, sort_order, wastage_override_pct, cut_type) values
('745469da-09e8-4df3-8e1f-05dd8b767cb9', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'f68cd3e8-ee62-41f5-891f-10e5bccaf675', 'material', 1000, 'Gram', 425, 0, null, null),
('1607ccf1-62f8-4aa8-8c25-46a23ee0178d', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 500, 'Gram', 41.69, 1, null, null),
('57bcb489-89ad-47a7-af0b-3fedc737266f', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 220, 'Gram', 73.33, 2, null, null),
('790df785-0954-451d-9cdf-b3f201731311', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', '48cb11cf-41e5-4464-9f67-0a8231840c39', 'material', 500, 'Gram', 75.76, 3, null, null),
('54f38f74-e52e-4013-bc3c-2446542f0b34', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', '2b098e5d-19d0-4886-a4c0-385c9f9e6d33', 'material', 800, 'Gram', 150, 4, null, null),
('1e997cec-5795-4294-b3cc-0c35fe933d98', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 250, 'Gram', 25.25, 5, null, null),
('da1efc17-6aa9-444a-bb96-6c07997eb998', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', '8a5f9308-fb2e-4d66-acb5-96d8ee8bd0d7', 'material', 5000, 'Gram', 523.5, 6, null, null),
('ad37824d-7733-4aab-a437-efd53e032c0e', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 100, 'Gram', 53.8, 0, null, null),
('d0dff4f1-c8d0-4966-838e-88044b0056f1', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', '47b7fc35-4642-4dfc-b10e-bb2fef9094ed', 'material', 1000, 'Gram', 75.2, 1, null, null),
('00784728-eb3b-462f-9e8b-ed86ef0ba4f3', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', 'e99006b8-d9a9-4c27-9646-5b5c3cb3a84d', 'material', 5, 'Gram', 2, 2, null, null),
('c3b7b255-05d1-41c6-9b35-36a6cabb4e74', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', '36e7b360-d26b-4597-ab87-0a68a2f1822d', 'material', 5, 'Gram', 4.2, 3, null, null),
('55f4d063-f87a-4de8-8654-8abc6099865e', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', '5ab0b89b-1607-40e9-8982-739477dd3eba', 'material', 100, 'Gram', 4.1, 4, null, null),
('d1f3cd18-b173-45d2-948b-e533bc314ce3', '2af74928-a965-47c8-8029-7cf33a57c792', '8f0a4ee9-4236-424d-90a5-d36d1bfa068b', 'material', 10000, 'Gram', 1197, 0, null, null),
('449f2ae0-2f38-454d-b0d3-96504ee706e8', '2af74928-a965-47c8-8029-7cf33a57c792', 'e2635a8a-7f74-4f35-bcd3-a85c4b4f3d2e', 'material', 19, 'Gram', 7, 1, null, null),
('7269ee9a-aa04-4c49-ad77-a7ca15be3f8a', '2af74928-a965-47c8-8029-7cf33a57c792', 'b468d5c6-b2f5-4035-8ca9-31b4e99985eb', 'material', 4443, 'Gram', 0, 2, null, null),
('ae6d5448-d3ad-4421-9125-643881ce2d74', '2af74928-a965-47c8-8029-7cf33a57c792', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 2221, 'Gram', 0, 3, null, null),
('1272c345-9cfe-457a-904f-95a5a18cabe4', '2af74928-a965-47c8-8029-7cf33a57c792', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 221, 'Gram', 232.05, 4, null, null),
('3397c87e-1cc0-46a5-ad10-a3e1a1228a26', '2af74928-a965-47c8-8029-7cf33a57c792', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 269, 'Gram', 89.66, 5, null, null),
('db9cf632-0f81-4b6f-9dd0-27eda6b95388', '2af74928-a965-47c8-8029-7cf33a57c792', '6eac6efc-7c89-43d0-b3c0-e1b1d99de8b8', 'material', 75, 'Gram', 9, 6, null, null),
('5529bd76-8c78-4310-9848-af5e414c1001', '2af74928-a965-47c8-8029-7cf33a57c792', 'efb23ca8-1da0-4ede-8d97-c6a30394b9b0', 'material', 40, 'Gram', 4.27, 7, null, null),
('c2bfd349-2dca-4071-8d7d-a83e782ba947', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', '5aa2983b-4fb3-4d6a-b634-582f811c27af', 'material', 10, 'Gram', 5, 0, null, null),
('3271183e-c478-4f6e-9b71-98fb2e7166f9', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', 'f3a46ec0-3e4d-46e3-b236-33bd1866f04c', 'material', 10, 'Gram', 4.82, 1, null, null),
('5e760bb2-0b3d-4573-b16b-9d4c6e3d2310', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', 'be154f02-127c-4f82-9613-bdc60dabb1e4', 'material', 10, 'Gram', 1, 2, null, null),
('a554b0d9-8618-408e-897a-ef72954f3383', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 60, 'Gram', 0, 3, null, null),
('49540e0a-e1d8-45a9-ab20-ee2d3eb6b33f', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', '006424e1-afab-48bb-903b-ab392c7ca7d4', 'material', 70, 'Gram', 14.42, 4, null, null),
('04f33a58-f218-4fb0-8f40-fc3d57d063dc', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 100, 'Gram', 105, 0, null, null),
('3db92cdb-6f52-4b01-991e-47e66ce375ac', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', '953494cc-1e19-49f8-bf9d-7d3f150d98bc', 'material', 30, 'Gram', 24.9, 1, null, null),
('c72cf830-1379-4f60-ad29-8568b71275a2', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 20, 'Gram', 6.22, 2, null, null),
('81749e6f-c53d-46f1-83d2-c41566cf9b0d', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 5, 'Gram', 1.67, 3, null, null),
('be10095e-2462-47de-a5fc-e3c667f96d8d', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', 'b468d5c6-b2f5-4035-8ca9-31b4e99985eb', 'material', 70, 'Gram', 0, 4, null, null),
('d3ce80bf-781d-4593-8b39-6cd25e17ea77', 'dc53223c-4efb-4d9e-a81c-c354cefabe10', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 250, 'Gram', 58.42, 5, null, null),
('e2970300-0e91-4bee-bb8d-7856a1e78a93', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 5, 'Gram', 5.25, 0, null, null),
('4a352a58-4166-4f4b-a6cc-387ebd7202e3', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '32373bfa-8b2a-45bc-904c-23c81594db98', 'material', 4, 'Gram', 4, 1, null, null),
('018c0457-19ab-4b3e-8d2b-b799d5423497', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 10, 'Gram', 1.31, 2, null, null),
('d01fb937-77a4-42f1-9b05-1f56c87c421a', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 30, 'Gram', 4.5, 3, null, null),
('28f534a7-c7f6-4751-93b3-3013bf47a57d', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 30, 'Gram', 7.71, 4, null, null),
('85d72b01-8958-4f87-a878-587e6adbef9a', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 5, 'Gram', 0.42, 5, null, null),
('9e8d31d7-2f90-4aba-9863-a9a8211a4d67', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '7d97fcc1-1782-47ac-a579-44ae26c13adc', 'material', 30, 'Gram', 8, 6, null, null),
('09b9fecf-a110-4f61-bafc-575ffd811152', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '945a346a-bbf2-4c5c-8173-a4dd9aaa805b', 'material', 20, 'Gram', 0.62, 7, null, null),
('e16384f1-6762-4792-984a-c135f881b717', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 50, 'Gram', 0, 8, null, null),
('8e9ae59f-02ab-4660-a6b9-80013cb14104', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'recipe', 30, 'Gram', 4.77, 9, null, null),
('12086a5b-87da-4e96-a4bd-aef66c5f23ab', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '680a7e54-356d-4cb5-9b8d-4713a3b5dbf0', 'material', 200, 'Gram', 47, 10, null, null),
('1d03806c-8a1f-4102-986e-2a8576e59fac', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 0.5, 'Gram', 0.17, 11, null, null),
('e01b305b-0571-4634-8635-1ced5db4dc17', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 1, 'Gram', 0.33, 12, null, null),
('cee1efba-1428-4bf1-b196-8e998407aeb6', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('fb718433-8efc-473b-b523-7b7d6a68570c', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 2, 'Gram', 0.2, 14, null, null),
('9e5638be-adc3-45ac-a5a7-cdaf3d9bd81b', '4d8ff0fe-db5c-4227-aaf8-0dfba1bd74ec', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 1000, 'Gram', 252, 0, null, null),
('fc83d734-da84-49dc-8970-a16c5ba501a3', '4d8ff0fe-db5c-4227-aaf8-0dfba1bd74ec', '6a789cff-27ad-418c-ad9c-c5ec861d5806', 'material', 25, 'Gram', 5, 1, null, null),
('673a2aa6-ac78-4ef6-8251-5c82f6b2c9a0', 'a11fa265-8d62-4e1a-bb05-ce314294558d', '15903eba-1cf9-453e-8167-284e484b148f', 'material', 100, 'Gram', 15.32, 0, null, null),
('d517a8bf-b4ee-4f5d-8f50-afcf889a822e', 'a11fa265-8d62-4e1a-bb05-ce314294558d', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 2, 'Gram', 2, 1, null, null),
('64b158b5-464d-443c-96f5-bb33fb069425', 'cf381b35-312e-4d5e-a4be-cf21dec63302', 'dcf9fb85-d21a-4129-8a8a-440eeeb861fa', 'material', 100, 'Gram', 19, 0, null, null),
('5da42e15-a0d5-4e98-9175-5f3023e5b7c6', 'cf381b35-312e-4d5e-a4be-cf21dec63302', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 200, 'Gram', 0, 1, null, null),
('7f63d354-d3b2-488a-89d5-f49343b6b129', '48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', 'b3761484-fca6-40a8-9d9b-6fc857dd4619', 'material', 40, 'Gram', 4, 0, null, null),
('cc5e42b7-8a79-4afb-b0dd-d27a7fcc6629', '48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', 'b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'material', 5, 'Gram', 1, 1, null, null),
('74d54a74-b760-4835-b44e-8f025892a5a4', '48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 2, null, null),
('2eeb92dc-2a1d-4119-b4f3-dd28a45dc141', '48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 1, 'Gram', 1, 3, null, null),
('30de50dc-6478-40b6-b12a-88d50a4d32fe', '48e6aa3c-fe57-44bd-9c3e-2a9fcaa266f9', 'f0d31a85-4a81-4592-8a5f-04573738b2e2', 'material', 20, 'Gram', 1.7, 4, null, null),
('f4424277-eb94-406a-af9f-67128e93ff2f', '4394f7e5-e947-49bd-bcac-72583ec7249b', 'ddf9e6c6-e2f6-4498-9c6a-f294d4d2c7a6', 'material', 40, 'Gram', 160, 0, null, null),
('5200b674-929e-49d9-b80b-60412c749f9a', '4394f7e5-e947-49bd-bcac-72583ec7249b', '8985d8f4-c23a-42be-8b7a-4d7a7d3e8d62', 'material', 15, 'Gram', 14, 1, null, null),
('67c86b31-2d0e-4a5b-881e-c4767542c50d', '4394f7e5-e947-49bd-bcac-72583ec7249b', 'c598c88f-4cd0-4181-9178-2ac8cb3f5e6d', 'material', 15, 'Gram', 3, 2, null, null),
('308c59a0-26bc-4e5e-9511-cd7449175c08', '4394f7e5-e947-49bd-bcac-72583ec7249b', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 10, 'Gram', 10, 3, null, null),
('12ea1674-e9b8-48b3-9d7b-bcfd48336aa9', '4394f7e5-e947-49bd-bcac-72583ec7249b', 'a6080d0e-5a0d-43e8-aa51-538c1f3eef2b', 'material', 3, 'Gram', 18, 4, null, null),
('656997bf-1977-46d0-b607-e73801609984', '4394f7e5-e947-49bd-bcac-72583ec7249b', '6ee86fad-4566-46a1-bd36-6eca5888f6e2', 'material', 2, 'Gram', 4, 5, null, null),
('7607ae3a-c794-4b19-a9d6-425bdc374502', '4394f7e5-e947-49bd-bcac-72583ec7249b', 'fd13aa8f-d3be-47c6-8129-a8a23030b806', 'material', 2, 'Gram', 8, 6, null, null),
('e0409935-c4dc-4ee5-9bed-cb7f399f7360', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 150, 'Gram', 12.51, 0, null, null),
('ae35da85-40f4-4fda-ab54-d6a83ddd8cf0', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 10, 'Gram', 2.57, 1, null, null),
('b01551cc-a62d-413d-ab18-e28afa48cb4c', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '48cb11cf-41e5-4464-9f67-0a8231840c39', 'material', 10, 'Gram', 1.52, 2, null, null),
('f15460a0-144b-44fe-a609-1b00fd3f826d', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'f258b599-4e8f-4184-aec0-f3263e8f0059', 'material', 10, 'Gram', 1, 3, null, null),
('6a0ea3b1-cd88-49cc-9e85-c11b430d875d', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 30, 'Gram', 4.29, 4, null, null),
('f48e41ec-d0d2-478e-ad09-f26dfea64368', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '8db28e04-00df-4fea-8b3a-a1eaf6c7f772', 'material', 4, 'Gram', 1, 5, null, null),
('e94f20df-e5e9-422e-b4a7-e820b8c6af73', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '0e71ba05-5744-4036-b197-50b316572d1a', 'material', 1, 'Gram', 1, 6, null, null),
('48466c68-5c9e-4f9c-bc0f-389b3b4770bd', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'a18c114f-af1f-4cdb-87b0-984318bb61c7', 'material', 7, 'Gram', 1, 7, null, null),
('4ecdd28a-925c-4f6d-bd95-844e7fa833e3', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 7, 'Gram', 1.64, 8, null, null),
('6670ec20-1e1e-4441-af3f-8fc393861cab', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '4394f7e5-e947-49bd-bcac-72583ec7249b', 'recipe', 10, 'Gram', 24.94, 9, null, null),
('4045bd56-04f7-4f70-8a31-28dfe46d4119', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '0a045830-9376-4715-b756-0b88b8768ef4', 'material', 2.5, 'Gram', 2, 10, null, null),
('77351fe8-222b-46c4-b03a-21adb06e9066', 'c128477d-b8a9-42dd-96ec-5f98895752c9', '00b2cf6d-ee31-4b18-8401-e02cda3c8f18', 'material', 1.5, 'Gram', 2.14, 11, null, null),
('fbfb83e5-09fe-4fe2-b3f2-cd6fc64215f2', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '18eb189e-181f-4ce2-b40e-960fd2ce7e7d', 'material', 10, 'Gram', 10, 0, null, null),
('1c67deb1-503e-4ca0-af90-f01c45b0a9d4', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'b92bf850-45bd-42fe-b16e-1fd58aae9f7f', 'material', 10, 'Gram', 2, 1, null, null),
('c7588a28-1c0c-43b3-8ba5-a980b520d4b4', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'a9021942-8dab-4459-89a5-2a122ff6de7e', 'material', 10, 'Gram', 2, 2, null, null),
('a609f4c8-0f05-4fe1-977f-30bf622738ac', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'f3c6c91e-4de8-4a43-ada1-be46fe6455a7', 'material', 10, 'Gram', null, 3, null, null),
('cdd6ddea-ba5d-459f-ba3b-2df007124b33', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'f2a795c5-d588-46e0-8e55-dd109482657d', 'material', 30, 'Gram', 9, 4, null, null),
('5f73d0d3-f7e6-46b6-8efc-f004dad9ca8a', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '8276ca8f-d739-4946-af20-ced61338d2e5', 'material', 30, 'Gram', 34.29, 5, null, null),
('c64166d0-4268-4372-b1e2-b92a2c4ceac4', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'd216175b-c5cb-40dc-8d7b-5d475d9ae104', 'material', 5, 'Gram', 25, 6, null, null),
('8fa3e230-4973-46f5-9124-71f262d6b604', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '25807023-d0ff-4a80-9f99-595e8ca3b67a', 'material', 40, 'Gram', 24, 7, null, null),
('9d7be9af-8bc7-427d-b3c2-bb48cb557457', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '04182aca-4290-44ef-af1a-aee5f57e259d', 'material', 4, 'Gram', 4, 8, null, null),
('95354f61-b73f-4919-8b20-b18d73c00408', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 2, 'Gram', 2.1, 9, null, null),
('a53469a6-b382-460b-b718-733c13196001', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '7d3868b1-b4c4-4309-945d-04b96b8bd79d', 'material', 2, 'Gram', 2, 10, null, null),
('3ccf28ee-9bbd-4c61-89fe-e2600f534e9f', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '57d7a57e-56ce-440f-80d9-f157e24c377e', 'material', 2, 'Gram', 0.8, 11, null, null),
('6d7d22c8-0a85-4ff1-9ebb-defdff72be04', 'ddf39453-4fb6-4167-a017-a5c7adad199d', 'a26aa2e7-b177-47bd-a882-4fb1b31dcba7', 'material', 1, 'Gram', null, 12, null, null),
('eb979abb-fa8f-41de-ac3e-250e8b4fd228', 'ddf39453-4fb6-4167-a017-a5c7adad199d', '6f17ac75-40a4-4172-aa3c-04749547f9da', 'material', 80, 'Gram', 60, 13, null, null),
('9e6921d2-637f-4853-97f5-d1e3ffc103ba', 'dc2d8050-b193-432c-9b1c-513c28302156', 'a9021942-8dab-4459-89a5-2a122ff6de7e', 'material', 50, 'Gram', 10, 0, null, null),
('e5cddf0d-ae09-4e46-9feb-f0f5c354caef', 'dc2d8050-b193-432c-9b1c-513c28302156', 'b92bf850-45bd-42fe-b16e-1fd58aae9f7f', 'material', 50, 'Gram', 10, 1, null, null),
('8b50f735-2249-434e-9351-d0fa1da776ed', 'dc2d8050-b193-432c-9b1c-513c28302156', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 20, 'Gram', 1.33, 2, null, null),
('9f3a4e7e-ed53-4c59-977c-b41f69f6c3e2', 'dc2d8050-b193-432c-9b1c-513c28302156', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 1, 'Gram', 0.33, 3, null, null),
('678785c2-51fa-4ca2-a077-250a96656cd0', 'dc2d8050-b193-432c-9b1c-513c28302156', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('614699fb-a39e-425f-b2dc-23c3e9ca9c96', 'dc2d8050-b193-432c-9b1c-513c28302156', '42b00eb2-bde9-4a40-86da-88936a9bde2c', 'material', 6, 'Gram', null, 5, null, null),
('bcfe95a7-bc6e-4cf4-9be3-a79222c76616', 'dc2d8050-b193-432c-9b1c-513c28302156', '89105468-2c61-4524-a5ca-615736362258', 'material', 10, 'Gram', 1.39, 6, null, null),
('58b1699e-b333-4cb7-8a78-fa999cf95c57', 'dc2d8050-b193-432c-9b1c-513c28302156', 'e9c494de-665d-4757-86cb-3717329a4fa7', 'material', 50, 'Gram', null, 7, null, null),
('dcad5139-4a47-4ee6-b308-2d1d3bb83965', '08cfc6a3-926a-4874-bd80-44b2a581033e', '18eb189e-181f-4ce2-b40e-960fd2ce7e7d', 'material', 30, 'Gram', 30, 0, null, null),
('5c7cae74-5fcb-4254-90e0-41e5e6f78e60', '08cfc6a3-926a-4874-bd80-44b2a581033e', '04182aca-4290-44ef-af1a-aee5f57e259d', 'material', 12, 'Gram', 12, 1, null, null),
('8e7b61c6-5d63-4899-9c34-2f4324f77347', '08cfc6a3-926a-4874-bd80-44b2a581033e', '56f54c2a-84d2-4d50-9817-5d6f7e971de2', 'material', 80, 'Gram', 29, 2, null, null),
('256ac422-acc8-4704-b0ff-38a3358c7745', '08cfc6a3-926a-4874-bd80-44b2a581033e', '2b233ad5-3fa2-4c44-befa-2de1763072d2', 'material', 50, 'Gram', 20, 3, null, null),
('2ec2d387-a5d5-475c-b243-0bcd713e2b1b', '08cfc6a3-926a-4874-bd80-44b2a581033e', 'ee3094be-41f5-4517-a9d1-a1fcc921d14d', 'material', 60, 'Gram', 41.51, 4, null, null),
('8d6989e2-791a-42c3-a30d-07e8e5bc3ba5', '08cfc6a3-926a-4874-bd80-44b2a581033e', '3a6ac2b0-8966-4ee9-82a8-70e8c72d48de', 'material', 20, 'Gram', 16.2, 5, null, null),
('e8cf7daa-253d-4b4f-97f5-040678feda03', '08cfc6a3-926a-4874-bd80-44b2a581033e', 'd216175b-c5cb-40dc-8d7b-5d475d9ae104', 'material', 5, 'Gram', 25, 6, null, null),
('54cea550-455c-437a-ba03-ef9f05912583', '08cfc6a3-926a-4874-bd80-44b2a581033e', 'b1845acc-f588-4709-aa75-2593bdff1828', 'material', 1, 'Piece', 1, 7, null, null),
('d704447b-f842-4d52-af3b-525cb4b7ce51', '08cfc6a3-926a-4874-bd80-44b2a581033e', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 8, null, null),
('8caeb104-520c-4301-8bcd-4d1306c4e619', '08cfc6a3-926a-4874-bd80-44b2a581033e', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 1, 'Gram', 1, 9, null, null),
('ccd92c7a-b55f-4130-b0ba-99f1fd6a5950', '08cfc6a3-926a-4874-bd80-44b2a581033e', '57d7a57e-56ce-440f-80d9-f157e24c377e', 'material', 5, 'Gram', 2, 10, null, null),
('ab9095c9-e4c2-4528-9405-2c2e1fe319cc', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '7ce48496-de8f-407d-bf54-468a75b2c3ca', 'material', 31, 'Gram', 10, 0, null, null),
('8bb0713f-956a-46ab-9a1e-a3ad42b7ff5c', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '24225d7e-31cc-4829-aa60-6013871528cb', 'material', 15, 'Gram', 6, 1, null, null),
('10728b8a-1d33-456b-9034-ee603732e730', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'd6fd4858-1398-4280-a564-3b84cea493d0', 'material', 15, 'Gram', 5, 2, null, null),
('c7a07766-563c-41dd-8e1e-2faaeefc628a', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 1, 'Gram', 0.33, 3, null, null),
('32df0cce-0f02-496a-ae34-9a42c67dfbd1', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('8049f3d8-518f-4845-b80d-9386e037d8aa', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '04182aca-4290-44ef-af1a-aee5f57e259d', 'material', 10, 'Gram', 10, 5, null, null),
('7a4430d2-1606-418f-b697-802b2b49ebc9', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '18eb189e-181f-4ce2-b40e-960fd2ce7e7d', 'material', 15, 'Gram', 15, 6, null, null),
('d471cc11-a74f-4746-a12d-73097fe47e53', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'ee3094be-41f5-4517-a9d1-a1fcc921d14d', 'material', 120, 'Gram', 83.02, 7, null, null),
('fac51b22-cd45-42b5-9818-595bdca7fea0', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 2, 'Gram', 2.1, 8, null, null),
('5f40f3e8-612f-4b4d-b44e-1153d2399a4d', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '99d5d9f5-4361-4444-86ed-0f4666be7356', 'material', 0, 'Gram', 0, 9, null, null),
('9931bf48-432c-4c02-96d6-ed6f19c071b0', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '3893cb77-c0a2-4bf5-8ae4-e7971987bd88', 'material', 5, 'Gram', 13, 10, null, null),
('9b136599-64fd-4f91-aceb-13981dc0c7a3', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '913ed4d0-a8ce-49cd-b142-c378ec525559', 'material', 0, 'Gram', null, 11, null, null),
('9f32ea72-3387-46ad-8bcc-e79972648b99', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '881a192f-c175-48fa-b118-48b55f914c3a', 'material', 80, 'Gram', 40.8, 12, null, null),
('7ddd93b7-b8ad-4a2b-8a56-d40e391b00e0', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '4eb43fdb-9df4-425f-b011-f8c36b8ced60', 'material', 35, 'Gram', 9.4, 13, null, null),
('e9fe690e-9b75-4336-a289-42f054da9600', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'ca3acdd4-a301-438f-b3fa-b3a28f34b11a', 'material', 10, 'Gram', 6.05, 14, null, null),
('2a5031a9-a0a4-404c-b8ad-13e918ecc9e4', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', 'b1845acc-f588-4709-aa75-2593bdff1828', 'material', 3, 'Piece', 3, 15, null, null),
('884a2640-9abd-495b-a9fc-09c2cf18b7d6', 'ac6a90bd-35cb-4380-8309-41b69ca98ff5', '2073b050-f44c-4aa6-84db-4a6001d9ee77', 'material', 5, 'Gram', 1.78, 16, null, null),
('214c08db-21ae-43c9-9394-8872363117ba', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '9b05c0a4-c1a4-47fa-8183-31931bea4a1d', 'material', 650, 'Gram', null, 0, null, null),
('eb62e81f-c51f-419a-b4b5-80c7d0c232b6', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 90, 'Gram', 6, 1, null, null),
('82d779dc-51b8-42c8-b8b2-d7da8b7108e9', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 16, 'Gram', 4.8, 2, null, null),
('0ee91396-efbb-4e88-bb6d-2a748a90cfa9', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '45d599d0-477f-466c-884d-4b36929b2498', 'material', 70, 'Gram', 7, 3, null, null),
('e00735d3-6d47-4ee2-86b3-8e595570b295', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'c7574d9f-17e4-4b12-95ae-a0dc47c0fc11', 'material', 120, 'Gram', null, 4, null, null),
('793b4846-a9f4-49ad-afb1-95e3f5793e7c', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 160, 'Gram', 0, 5, null, null),
('4e5b1d51-64da-46d2-89da-ab8ce5fbae8d', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 6, null, null),
('5cc94179-216d-4d67-8601-8e1d8f63350f', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 7, null, null),
('49b3c1ce-1205-499c-af68-9be038ddbf94', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'material', 0.5, 'Gram', 0.1, 8, null, null),
('bce09bc8-3bc6-49f0-9b19-b7a27924e7d1', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 5, 'Gram', 0.91, 9, null, null),
('c67fcfcc-6b60-412f-aa1b-2c23260c89e1', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 5, 'Gram', 2.04, 10, null, null),
('f1079eae-3356-4d78-8df3-12d5933f2d28', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', 'a42974db-2f76-444e-9b20-4c025a0b54ad', 'material', 70, 'Gram', null, 11, null, null),
('9af9ab1e-4a17-4928-9c21-0545dc07c174', '7ba90603-d58e-48e6-bf4b-54e9ca0bc534', '2cdb403a-1d38-4284-8811-6a9ce809a9da', 'material', 5, 'Gram', 3, 12, null, null),
('486dbe96-8864-495b-a7aa-eb438a153d92', 'e111f381-8a0f-4a19-8b1f-473bf9b53490', '9fac0958-17a9-45d2-a320-effe3e3b0626', 'material', 96, 'Gram', null, 0, null, null),
('ab886953-cf74-40d3-8ac7-288653c0d597', 'e111f381-8a0f-4a19-8b1f-473bf9b53490', '54d732e8-01d7-436a-af55-8b35a3338fc4', 'material', 18, 'Gram', null, 1, null, null),
('14fbf223-746f-4ccd-ab59-96c3f35bc0c7', 'e111f381-8a0f-4a19-8b1f-473bf9b53490', '2ac4e274-b8bd-4657-8331-da75d309f8bb', 'material', 96, 'Gram', null, 2, null, null),
('3560d4e1-992d-487b-99a2-24ed09df0cbf', 'e111f381-8a0f-4a19-8b1f-473bf9b53490', '22ad9e4c-99fb-4e3b-83bf-3bffe66f7c52', 'material', 12, 'Gram', null, 3, null, null),
('668bde45-84db-40c0-84be-0b283a6dbf88', 'e111f381-8a0f-4a19-8b1f-473bf9b53490', '9e3a7fec-ca23-4e78-a42c-85d96e9d4810', 'material', 0, 'ML', null, 4, null, null),
('3da73e2f-9184-4a4f-8754-d13c80653f94', '086379c2-ce7b-47de-afff-39190dd5f2d8', '6c3cd64f-4812-4745-bf3b-ae6b84b39663', 'material', 150, 'Gram', 8.45, 0, null, null),
('66f7f3b6-18e4-4f53-9e51-302976b5348b', '086379c2-ce7b-47de-afff-39190dd5f2d8', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 1, null, null),
('0e108d75-5836-4d2d-9a74-f339884cf015', '086379c2-ce7b-47de-afff-39190dd5f2d8', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 2, null, null),
('42ed3db7-5265-4df7-9ce4-28deab1cac8c', '086379c2-ce7b-47de-afff-39190dd5f2d8', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 3, 'Gram', 1.3, 3, null, null),
('b6b7b798-23ec-4ba8-9791-dfa65b91205e', '086379c2-ce7b-47de-afff-39190dd5f2d8', '4b8ed434-e369-442d-92d8-a75f2bb7913a', 'material', 2, 'Gram', 0.8, 4, null, null),
('dca5fe7b-5948-4d7c-abc8-2f684f15950b', '1b211811-d9f8-40f7-9cbb-e86dbe2b3140', '47e3efe1-485a-4f4c-8b80-77dec35f8262', 'material', 105, 'Gram', null, 0, null, null),
('d742e38b-f213-4fd5-ac35-395588faed3a', '1b211811-d9f8-40f7-9cbb-e86dbe2b3140', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 60, 'Gram', 53.04, 1, null, null),
('87e9ca14-210d-4d52-8eb6-dcee1603a08c', '1b211811-d9f8-40f7-9cbb-e86dbe2b3140', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 10, 'Gram', 5.38, 2, null, null),
('f2acb3d8-083b-4e9c-91d6-b71c0db21e49', '1b211811-d9f8-40f7-9cbb-e86dbe2b3140', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 3, null, null),
('ce8abeec-dafa-455f-9c5f-f70f8386f804', '1b211811-d9f8-40f7-9cbb-e86dbe2b3140', '553199df-9a53-4d2b-b54e-91154ccd4fcb', 'material', 7, 'Gram', null, 4, null, null),
('5540b306-2393-4adc-8e58-ceb5bf96e4ed', 'f429438b-1713-4275-bb34-e5a55b668404', '476c82fb-cbb3-49d7-992f-c1a5c59da3fb', 'material', 200, 'Gram', 56.7, 0, null, null),
('973a86f2-8e42-44c9-ae84-3a9476b0ecb9', 'f429438b-1713-4275-bb34-e5a55b668404', '0adb493e-afb9-4462-9a0a-01a6f4c38304', 'material', 5, 'Gram', 1.88, 1, null, null),
('6ab2a28f-1c3f-4943-9ff3-c0da60f058bf', 'f429438b-1713-4275-bb34-e5a55b668404', 'e1b6a81e-d789-420b-8865-d54459fe4a56', 'material', 3, 'Gram', 1.06, 2, null, null),
('02e6bead-3def-406a-91aa-bda939456880', 'f429438b-1713-4275-bb34-e5a55b668404', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 10, 'Gram', 4.32, 3, null, null),
('a257fe76-2316-4be2-8088-2f3eb3afa3a8', 'f429438b-1713-4275-bb34-e5a55b668404', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 20, 'Gram', 8.75, 4, null, null),
('6b395c51-29a5-4aeb-810f-bf59c42e55fd', 'f429438b-1713-4275-bb34-e5a55b668404', 'd9f12360-df30-40db-8d73-3a690b911888', 'material', 5, 'Gram', 27.5, 5, null, null),
('3c789083-ea70-49a7-a613-8cc8e9804521', 'f429438b-1713-4275-bb34-e5a55b668404', 'eb82412e-88e8-4916-9b37-df41bcebc06c', 'material', 0, 'Gram', null, 6, null, null),
('a35fb3b3-75f5-484c-9ad3-0fa26401af0e', 'f429438b-1713-4275-bb34-e5a55b668404', 'c3005a1c-351c-4759-a22b-70b706389c49', 'material', 44, 'Gram', null, 7, null, null),
('79279b9f-ac58-4a54-84f6-004da5ec0995', 'f429438b-1713-4275-bb34-e5a55b668404', '7c8a8e64-7eef-4f05-956d-8653ee843fa8', 'material', 0, 'Gram', 0, 8, null, null),
('5848ad9d-00ee-4c8d-9012-48b3874cb823', 'f429438b-1713-4275-bb34-e5a55b668404', 'ab59f94e-6e84-49b5-8a70-00018746ac17', 'material', 40, 'Gram', null, 9, null, null),
('3a145578-2c73-4dc5-a0ef-64e552f9b9f2', 'f429438b-1713-4275-bb34-e5a55b668404', '83e7ba37-42c5-4f4c-9642-426f5c579c7f', 'material', 30, 'Gram', null, 10, null, null),
('b947e2b2-0907-49bf-abd1-c6a11d27221e', 'f429438b-1713-4275-bb34-e5a55b668404', 'c09a5365-cd67-482c-8f25-20af6f404f40', 'material', 0, 'Gram', null, 11, null, null),
('926a3ab9-af3e-4f2f-8bd8-d7cd1be22c4a', 'f429438b-1713-4275-bb34-e5a55b668404', '931f6000-6905-4b19-9b94-cf67073ea8ab', 'material', 0, 'Gram', 0, 12, null, null),
('97f8d189-6284-4dbf-ad67-160564d7e133', 'f429438b-1713-4275-bb34-e5a55b668404', '76595065-ca7c-4d2c-9602-de06a65c11cd', 'material', 150, 'Gram', 34.5, 13, null, null),
('2f87e5da-7b62-4e1f-b2a5-1ecc9a19b53e', 'f429438b-1713-4275-bb34-e5a55b668404', 'f1001466-1803-48da-88a7-770a3bf1b19c', 'material', 15, 'Gram', 4.5, 14, null, null),
('1352d58d-b713-4df0-ad65-d87b2e0f9448', 'f429438b-1713-4275-bb34-e5a55b668404', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 15, null, null),
('a9e89e7a-8092-4776-b6f3-6e9ca351ae96', 'f429438b-1713-4275-bb34-e5a55b668404', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 5, 'Gram', 2.16, 16, null, null),
('4f2c341e-a68b-47ef-84ec-f4f0a4907a47', 'f429438b-1713-4275-bb34-e5a55b668404', '31ea5d60-e5ee-4ab9-acc5-f821bcee6e7d', 'material', 0, 'Gram', null, 17, null, null),
('a047b7c6-f188-4252-b453-c6608f9090b4', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '4fd8cde6-cdce-41b5-b6d7-499198b6b6b1', 'material', 280, 'Gram', 78.4, 0, null, null),
('ad2e7f66-7abd-4417-9301-6d8483a47582', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 15, 'Gram', 2.14, 1, null, null),
('3b1f4bb9-ac85-470d-82d6-5ca561f84431', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', 'f1001466-1803-48da-88a7-770a3bf1b19c', 'material', 23, 'Gram', 6.9, 2, null, null),
('c44cd0bb-c5f0-4c6f-a52a-104e8eb6fa48', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 3, null, null),
('d1aa04c1-00d6-4d49-b7e6-11922730cb55', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 4, null, null),
('a1fd246f-da1a-4bfe-a99a-92301ccde8b6', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '661991bc-e8db-48b3-85d9-1375af39de6b', 'material', 10, 'Gram', 6, 5, null, null),
('f3e81de3-bc48-47c9-a43f-41f0c8408772', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '04182aca-4290-44ef-af1a-aee5f57e259d', 'material', 3, 'Gram', 3, 6, null, null),
('e6563083-fc31-435f-aab3-b74da8f83be4', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 5, 'Gram', 2.16, 7, null, null),
('7d539e3f-d6c3-40e4-bde3-c41fbdc0b51a', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 5, 'Gram', 1.67, 8, null, null),
('f26e19ba-67c9-478e-ad9d-ede7756cd05f', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', '0af39f3a-c11f-4c15-9474-ea41dca24aa3', 'material', 1, 'Gram', 1, 9, null, null),
('63170e58-afb5-4e94-86d9-3625b39c17ce', 'c3dada6f-d777-4163-8365-d809a2d9ca5d', 'e1b6a81e-d789-420b-8865-d54459fe4a56', 'material', 3, 'Gram', 1.06, 10, null, null),
('ff5f52d2-bf49-417f-b305-ccb119f1974c', '46536d70-f83e-4154-ba1f-dc1b137441ce', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 10, 'Gram', 10.5, 0, null, null),
('93bd562f-88dc-48ae-ad86-8a510964d7c9', '46536d70-f83e-4154-ba1f-dc1b137441ce', 'fffe5d66-2b32-406a-bae9-7dc2ef3db4a2', 'material', 120, 'Gram', null, 1, null, null),
('69189901-b068-4ce1-aaee-ec4b60b1521f', '46536d70-f83e-4154-ba1f-dc1b137441ce', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 2, null, null),
('18488503-4e7e-4c37-be49-fb19890f0f6e', '46536d70-f83e-4154-ba1f-dc1b137441ce', '45c1bcb7-1868-4c8e-ab7a-67bf289b4a74', 'material', 10, 'Gram', 3.33, 3, null, null),
('6736761d-f729-402c-b51a-0d4d743f0e1a', '46536d70-f83e-4154-ba1f-dc1b137441ce', '3e9aab3b-5b33-4e19-96ff-ba3011a48087', 'material', 5, 'Gram', 1.48, 4, null, null),
('bdc0e501-c963-4e16-8b5f-be0ff42ed820', '46536d70-f83e-4154-ba1f-dc1b137441ce', '82f0998e-efa0-40cc-b5a3-fe0991512e1c', 'material', 5, 'Gram', 5.25, 5, null, null),
('f01c395c-1b46-471f-b2be-55f62bd041bd', '46536d70-f83e-4154-ba1f-dc1b137441ce', '12bfcbca-5b9d-4b99-aa34-1033bf81f502', 'material', 0, 'Gram', null, 6, null, null),
('8f5264dd-defe-4cc4-b608-aaab8c7e6e64', '46536d70-f83e-4154-ba1f-dc1b137441ce', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 230, 'Gram', 203.32, 7, null, null),
('2aede2f2-8376-494b-9142-5921bdfcdd39', '46536d70-f83e-4154-ba1f-dc1b137441ce', '847afabc-d03d-4911-94e0-39b2ceb8c002', 'material', 150, 'Gram', 16.89, 8, null, null),
('b04131af-2adc-446d-87bb-d053d2c4b17d', '46536d70-f83e-4154-ba1f-dc1b137441ce', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 60, 'Gram', 10.92, 9, null, null),
('7ad7c742-d432-459c-a390-8e656b01f7cb', '46536d70-f83e-4154-ba1f-dc1b137441ce', '0273d233-5462-43d3-b825-a0491851f225', 'material', 60, 'Gram', null, 10, null, null),
('d79e67bd-4340-4304-a525-803caff836ec', '46536d70-f83e-4154-ba1f-dc1b137441ce', '12bfcbca-5b9d-4b99-aa34-1033bf81f502', 'material', 0, 'Gram', null, 11, null, null),
('32e0adaa-54ed-49d2-8a27-58956acc2e5c', '46536d70-f83e-4154-ba1f-dc1b137441ce', '2da16878-5adf-43c6-bdae-ea4f3e9e4cad', 'material', 4, 'Piece', 0.8, 12, null, null),
('460ad4b1-0a90-493b-8965-90fb3a2eb27e', '46536d70-f83e-4154-ba1f-dc1b137441ce', '36d7a036-e455-4a1d-a9cd-bdb157683fba', 'material', 3, 'Gram', 1, 13, null, null),
('b34591ff-a4e4-4f17-85c2-774808848a73', '46536d70-f83e-4154-ba1f-dc1b137441ce', 'b94702c4-5b8b-4c55-ae6e-42dd36cf32ca', 'material', 3, 'Gram', 2.44, 14, null, null),
('46bf44c8-bc0f-4717-9a23-8b877f8170a3', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 2, 'Piece', 2.1, 0, null, null),
('ef0071df-c85f-4d29-b99a-d7933df3b2b4', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 120, 'Gram', 8, 1, null, null),
('3bab1205-fbb7-4e3e-83f2-df5df35adbfd', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 15, 'Gram', 4.5, 2, null, null),
('b0fbdc47-155e-45fb-bbcb-3515707129f7', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 100, 'Gram', 5.71, 3, null, null),
('df2a0948-ae57-4561-81a4-d80852201e3f', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '5fb131c9-63a6-4f5c-9d08-3e31ed442869', 'material', 800, 'Gram', null, 4, null, null),
('57f4a174-7381-4764-ace4-860860290ece', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 11, 'Gram', 3.43, 5, null, null),
('684c14dd-b549-4729-8cdd-f26cff80b7f1', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 500, 'ML', 0, 6, null, null),
('90978643-2628-4411-953b-6e59bd5bdc70', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '032c17f9-2950-47fc-ac28-fee10e62a0c5', 'material', 30, 'Gram', null, 7, null, null),
('fd529911-034a-413a-a1a7-577837daa3f0', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '7e4e588e-3903-4623-be26-0df6204d946c', 'material', 2, 'Gram', null, 8, null, null),
('e76e4bc9-2cc3-4268-a653-7ff66f253793', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '6d29283d-4b72-4515-adcb-a3ab39715b7d', 'material', 1, 'Piece', null, 9, null, null),
('1b2b9fc4-b463-4817-a05f-92ea6dfb4af3', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 0, 'Gram', 0, 10, null, null),
('ede671dd-7d11-4de4-b659-54fad3c24cee', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0, 'Gram', 0, 11, null, null),
('946cadfa-f81d-4eca-9dca-20e55a4442de', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'a7762432-01df-4780-8d62-457bc2b16305', 'material', 10, 'Gram', null, 12, null, null),
('83e64d1e-36ab-4675-8177-c409a55d0c80', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '44ba86f4-4381-4a37-acb9-581ac6dd6483', 'material', 2, 'Piece', null, 13, null, null),
('e4f6d95a-0b4c-4dda-a736-cdf982bdd749', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', '488a2b1d-b85c-46e7-b398-d163532d001d', 'material', 1, 'Piece', null, 14, null, null),
('88cb1fe0-6152-43d6-8a9e-cb3539385918', 'a88cbedb-69ee-4e0f-a1db-bae5f2814199', 'c0ccf3ac-7670-46f5-98b1-21f4dbdc2432', 'material', 5, 'Gram', null, 15, null, null),
('347c6102-a431-4394-bde7-2012f5fb008e', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 0, null, null),
('1de9d06c-bafc-4f2b-8956-8d4ba11d90c8', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 5, 'Gram', 0.71, 1, null, null),
('4b2e4ef9-6e33-4107-be3e-ecb7dd114c35', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', 'f2a795c5-d588-46e0-8e55-dd109482657d', 'material', 40, 'Gram', 12, 2, null, null),
('1e35dd32-6e32-495c-9149-748cb4d0bdd9', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '77602f42-cca7-43b4-b714-41a997919da1', 'material', 220, 'Gram', 47.59, 3, null, null),
('0fe8ad94-d654-4942-ae86-3f155eac777b', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '8b831156-c8f0-40a6-aac5-54fc7f1364d0', 'material', 140, 'Gram', 15.47, 4, null, null),
('03d4f755-3b3d-4efd-ae1a-bb171a045bd0', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 6.8, 'Gram', 2.27, 5, null, null),
('76fe8d9a-c24e-4a82-8cd3-8d1899dfac3a', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('f39bfd11-988b-4c66-8a07-9ab26a6bfa1b', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', 'e1b6a81e-d789-420b-8865-d54459fe4a56', 'material', 1, 'Gram', 0.35, 7, null, null),
('5e73225f-33e5-440f-b361-1b7b1475aeb4', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 3, 'Gram', 0.3, 8, null, null),
('bddd0f46-477c-485d-b002-a3d81c3bc399', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 7, 'Gram', 3.06, 9, null, null),
('2faa193d-84a7-4acc-94dd-5ca860c30bf9', 'ac0dceb9-b7d5-48c3-8435-e2bed14dd386', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 0, 'Gram', 0, 10, null, null),
('89e52c6f-baee-4660-beb5-d02ddd6e0fb0', '6e4697bd-e078-4c5c-870f-74d036ae49d2', 'b24c33e9-4498-4db0-9adf-1ffca0ffa049', 'material', 120, 'Gram', 12.22, 0, null, null),
('55d9492d-280b-419a-ac0d-2cac74965e76', '6e4697bd-e078-4c5c-870f-74d036ae49d2', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 1, null, null),
('dc2d4040-f673-4042-be0e-870742464c83', '6e4697bd-e078-4c5c-870f-74d036ae49d2', 'b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'material', 10, 'Gram', 2, 2, null, null),
('7945d0fa-347d-43f2-934b-0c060b0cb759', '6e4697bd-e078-4c5c-870f-74d036ae49d2', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 5, 'Gram', 1.67, 3, null, null),
('dd4a7bbd-e987-4534-b3e5-713d0d993814', '6e4697bd-e078-4c5c-870f-74d036ae49d2', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('541efbad-e88b-4142-b42e-8fa8bf4dd1cd', '6e4697bd-e078-4c5c-870f-74d036ae49d2', '006424e1-afab-48bb-903b-ab392c7ca7d4', 'material', 10, 'Gram', 2.06, 5, null, null),
('8ff064ce-e1d0-4975-b4fe-9a6ca893054c', '6e4697bd-e078-4c5c-870f-74d036ae49d2', '204a63ea-493b-47ec-96ba-f1394de85896', 'material', 200, 'Gram', null, 6, null, null),
('a1400fca-abac-4411-b15d-03df13709b2c', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'c4aa31fa-0983-4853-8604-f76dcadd8993', 'material', 140, 'Gram', null, 0, null, null),
('cc503700-b57d-490f-b873-af91133add53', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '2ac3ad58-30fa-4f35-9266-dbdc4f1fb96c', 'material', 190, 'Gram', null, 1, null, null),
('6875853e-ee0c-4a52-a365-b4dcbfde2dfc', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 2, null, null),
('b0c88323-0e48-4781-8aff-30454de006a9', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 5, 'Gram', 0.71, 3, null, null),
('59d51a5a-c24b-498f-af09-bdc59e860e38', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'f1001466-1803-48da-88a7-770a3bf1b19c', 'material', 10, 'Gram', 3, 4, null, null),
('710cc168-fba0-427b-b47f-399b7826729e', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'd9f12360-df30-40db-8d73-3a690b911888', 'material', 1, 'Gram', 5.5, 5, null, null),
('57ac6902-a537-4768-aca4-8801543fa5c3', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 1, 'Gram', 0.43, 6, null, null),
('b17e802d-20bb-4dce-8df0-2fbcbd26508e', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 6, 'Gram', 2, 7, null, null),
('db6f6b18-22ac-4787-a0d7-348c2e5ba59b', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 1, 'Gram', 1, 8, null, null),
('9ad8faaf-a9c7-4b11-aea6-b753f9346acd', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 7, 'Gram', 3.06, 9, null, null),
('9c05b908-62aa-4ac8-86d7-32237665cb6a', '27fbbfed-6448-4cd7-b452-da3e4e1413ea', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 100, 'Gram', 0, 10, null, null),
('2dd13eb0-026f-44b8-b8e3-62cd316fe3dd', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', 'f5622dd2-1049-45dd-aa7e-c4bcb45bf3d1', 'material', 140, 'Gram', null, 0, null, null),
('480ef5ba-fdcf-4a56-b462-f8e049d7dc41', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '4e50bf29-b822-4950-b61b-09b892774654', 'material', 180, 'Gram', 43.69, 1, null, null),
('4e90809a-baf9-47be-bf99-0653f41eabfe', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '22213964-a3cb-4e72-850c-808a3ad17ba4', 'material', 60, 'Gram', 48.7, 2, null, null),
('22814405-e710-4632-8fd7-411861f71717', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '837c60fe-7aa5-494a-a184-05fa3374c3d1', 'material', 5, 'Gram', 5, 3, null, null),
('b5f88a79-207a-45e1-97e8-36b532529e5d', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 18, 'Gram', 5.6, 4, null, null),
('2230519d-bd17-4ea1-9119-82c5cee018e8', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 5, null, null),
('344e2623-4e57-4f10-8ee7-0206f439639c', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 7, 'Gram', 3.06, 6, null, null),
('d66095fa-d849-4fa5-b14c-3fca88f62bca', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 0.5, 'Gram', 0.17, 7, null, null),
('483c5377-747c-418e-985a-b6b21a1b88ce', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '0af39f3a-c11f-4c15-9474-ea41dca24aa3', 'material', 2, 'Gram', 2, 8, null, null),
('64021bcd-9aad-4a42-9d74-0ab633a2b53c', 'b9728f56-1d63-4f29-8622-0e7eb64ae4da', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 2, 'Gram', 0.47, 9, null, null),
('442f592e-e99e-4b50-96c9-1e1c7c2f2c8d', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', 'a5a18cc7-e216-45f2-b4e5-d7c4ea10ce19', 'material', 100, 'Gram', null, 0, null, null),
('dfbd99ec-0cce-4c14-aab1-7640ff9c6a6f', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '143fed4f-4740-4e11-a58d-34b9a8aea036', 'material', 7, 'Gram', 6.46, 1, null, null),
('e89fd6ac-91a3-43db-8a69-51c48f1d34ef', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', 'e7216c05-ddd4-4b59-85ec-7aaf6a92b98a', 'material', 8, 'Gram', null, 2, null, null),
('38fbcb5f-7189-4164-9c62-566e773a85f3', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '2ac3ad58-30fa-4f35-9266-dbdc4f1fb96c', 'material', 40, 'Gram', null, 3, null, null),
('d8aa52d6-febc-432b-9422-755915c60549', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 5, 'Gram', 2.19, 4, null, null),
('3d916dd5-87f2-4e6e-8525-f37da05d3be0', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 5, 'Gram', 1.67, 5, null, null),
('b61a0901-8a97-4e97-9823-1d6fec12e981', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '0af39f3a-c11f-4c15-9474-ea41dca24aa3', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('58b96590-e377-46c6-80d7-e98798ef6cd6', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 5, 'Gram', 1.5, 7, null, null),
('8129a487-33c2-460e-8ede-85d17da19f9c', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 8, null, null),
('68311fab-a6c5-46e1-b3da-45447f4aa387', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 5, 'Gram', 0.71, 9, null, null),
('66c34ea9-c367-4444-8588-510a94193d9e', '1bfb4a7b-57b1-4efb-bcd9-2b76b9ce683c', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 100, 'Gram', 0, 10, null, null),
('ffeb0423-f564-4972-8c35-9b681475af1d', '147a996b-6a3a-4425-9033-3fb10371c6a4', '3e749ace-ebe7-4a49-a649-8664a29ee8f2', 'material', 120, 'Gram', null, 0, null, null),
('797c3f58-8a80-4fe7-87a4-0700ab9f6fea', '147a996b-6a3a-4425-9033-3fb10371c6a4', 'aca71ce4-9047-4215-9ac2-944392dbc2a7', 'material', 60, 'Gram', null, 1, null, null),
('7bdc4250-204b-440a-900d-eea184470675', '147a996b-6a3a-4425-9033-3fb10371c6a4', 'cac18086-3326-41fa-9ddf-20dd80d25a3c', 'material', 50, 'Gram', null, 2, null, null),
('7fb007a3-ac03-4002-b21a-2f483a2b1a8e', '147a996b-6a3a-4425-9033-3fb10371c6a4', '14678ccf-aa89-4425-97ed-7778ce16dece', 'material', 40, 'Gram', null, 3, null, null),
('48b394e6-469e-4cf5-864a-c94e92722639', '147a996b-6a3a-4425-9033-3fb10371c6a4', '45c1bcb7-1868-4c8e-ab7a-67bf289b4a74', 'material', 10, 'Gram', 3.33, 4, null, null),
('7d8ce0c6-ba90-459b-a054-7a24f552cc16', '147a996b-6a3a-4425-9033-3fb10371c6a4', 'c00fc4c4-7b2c-467b-8852-7ead8ad0229b', 'material', 400, 'Gram', null, 5, null, null),
('d0769020-118e-4ce3-b0aa-1cb67b2b02c1', '147a996b-6a3a-4425-9033-3fb10371c6a4', '7c8a8e64-7eef-4f05-956d-8653ee843fa8', 'material', 20, 'Gram', 4.86, 6, null, null),
('8a97835e-a9e7-466e-9978-650e44d3867d', '147a996b-6a3a-4425-9033-3fb10371c6a4', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 15, 'Gram', 15.75, 7, null, null),
('79a122a4-f8a8-4a72-817a-e03486826760', '147a996b-6a3a-4425-9033-3fb10371c6a4', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 4, 'Gram', 1.33, 8, null, null),
('91c1e7ed-4f4a-4ecf-9ffa-5547bb841592', '147a996b-6a3a-4425-9033-3fb10371c6a4', '0af39f3a-c11f-4c15-9474-ea41dca24aa3', 'material', 1, 'Gram', 1, 9, null, null),
('224643a0-8f0d-4566-8246-6bf01440871f', '147a996b-6a3a-4425-9033-3fb10371c6a4', '0fa661e8-11d3-4987-9fdb-08a9fcc324bf', 'material', 2, 'Gram', null, 10, null, null),
('2692ccb3-e682-409a-af96-7eb1a846ab60', '147a996b-6a3a-4425-9033-3fb10371c6a4', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 40, 'Gram', 21.52, 11, null, null),
('24a2c9a5-c23b-4a6a-b55a-9cd18ffc2b29', '147a996b-6a3a-4425-9033-3fb10371c6a4', 'be20ae9b-560d-4ff0-8cf9-bf91acce9670', 'material', 40, 'Gram', null, 12, null, null),
('292f8d1d-2c42-455b-b955-f821a777bb04', '147a996b-6a3a-4425-9033-3fb10371c6a4', '5c827e7c-4a9a-4f7d-9961-eb4ab6b442e9', 'material', 500, 'Gram', 38.35, 13, null, null),
('4b09694d-dd03-4fe5-ba18-0142b4aaa61c', '147a996b-6a3a-4425-9033-3fb10371c6a4', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 4, 'Gram', 1.33, 14, null, null),
('c570a947-be61-4a20-a7ff-9aef89d26608', '147a996b-6a3a-4425-9033-3fb10371c6a4', '8803db70-314d-4ab3-ac53-c092b586fd8a', 'material', 0.5, 'Gram', null, 15, null, null),
('be990a50-bf0a-4472-9f36-e95cced871d7', '147a996b-6a3a-4425-9033-3fb10371c6a4', '1fe25680-4155-4c4a-8c8f-7d0ac8fa9964', 'material', 6, 'Piece', null, 16, null, null),
('82010100-6f2b-407c-880d-e93d2ec0cfe0', '147a996b-6a3a-4425-9033-3fb10371c6a4', '82d04a65-c091-4874-b926-43e0cc8e243f', 'material', 200, 'Gram', null, 17, null, null),
('2a2da475-7cbd-40a2-a238-78c33ed6e646', '147a996b-6a3a-4425-9033-3fb10371c6a4', '42b00eb2-bde9-4a40-86da-88936a9bde2c', 'material', 30, 'Gram', null, 18, null, null),
('97fe4523-7710-44c7-ae87-2f3c6c03e4cf', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '61849d9d-2d97-4492-bd32-5f0c6bc8f05b', 'material', 250, 'Gram', 72, 0, null, null),
('1dcece08-c8aa-4402-aceb-90146c8e31be', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 100, 'Gram', 88.4, 1, null, null),
('f6bafe65-a7b0-4a20-b58e-0c106e3a8138', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '32a863d2-5f23-42b5-8be1-d698e1ae587f', 'material', 100, 'Gram', 50, 2, null, null),
('bd0cdb71-4178-4b2d-b589-61fc932d6ec7', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', 'a12b91f2-2777-4435-8a60-be13ac4e2c47', 'material', 30, 'Gram', 11, 3, null, null),
('55740206-6020-4e50-b796-1d12f0e468be', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 1, 'Gram', 0.33, 4, null, null),
('af2876f4-b6d2-4e2f-8ce6-dd66c086cb1b', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '6df8325b-a5df-4c1b-b165-c57e7924aad8', 'material', 1, 'Gram', 1, 5, null, null),
('3fe149fd-951c-495b-9b6b-e51b814e6b0b', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '00093eab-5a9b-4a01-aef5-729cc7acb7c6', 'material', 5, 'Piece', null, 6, null, null),
('1fafe6a8-fcad-455b-ad89-f838aaa3186c', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', 'cb39f21c-c3dc-4241-a01b-7e3a59364e11', 'material', 150, 'Gram', null, 7, null, null),
('33350137-43c1-44f7-8bd1-e23725c596f6', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 10, 'Gram', 4.38, 8, null, null),
('be7bf88d-44b1-4d9b-9b02-fae4779e9c58', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '802b6e54-61ed-4fe8-8aba-df86214335e3', 'material', 10, 'Gram', 3.13, 9, null, null),
('89bec773-4a8b-4b1f-9489-c95dfaa5ddcf', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 5, 'Gram', 0.78, 10, null, 'Slit'),
('3b5d2597-f15e-494e-9244-6c99dac3f530', '8ed796e2-198c-44b4-a4ea-7f0d9a591026', '9afe1c26-786e-4f15-b6f5-5d3925d9a627', 'material', 5, 'Gram', 2.1, 11, null, null),
('81627201-67c3-4e06-8272-64ebb3a1a500', '207118bd-e060-43c3-9439-4ea7bc8e3d34', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 10, 'Gram', 10.5, 0, null, null),
('0b2577a1-97b0-4c38-900d-ffe9d913be6e', '207118bd-e060-43c3-9439-4ea7bc8e3d34', 'f1001466-1803-48da-88a7-770a3bf1b19c', 'material', 5, 'Gram', 1.5, 1, null, null),
('bf491069-e3a7-4690-880a-cdbe751fe10f', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '83d7cb01-8d6a-4e92-b997-3fc8bda4ed12', 'material', 60, 'Gram', 7.2, 2, null, null),
('4060c1ba-2f01-49f8-8824-156942327c66', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '7bb2c69c-bbdb-4558-9c19-a5b52fa415ce', 'material', 60, 'ML', null, 3, null, null),
('7f32a6e6-4c7b-4a03-a2f5-2939ea9c9c55', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '5c1c4be6-dbd7-469f-bc8f-3670dc767d43', 'material', 140, 'Gram', null, 4, null, null),
('ac909c69-f9ba-4a53-99ea-2b8187608778', '207118bd-e060-43c3-9439-4ea7bc8e3d34', 'f5232ea7-ce87-4001-807f-a4e42a31c246', 'material', 4, 'Gram', null, 5, null, null),
('651851d8-eb36-42e5-8a52-70717b47caf1', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '006424e1-afab-48bb-903b-ab392c7ca7d4', 'material', 80, 'Gram', 16.48, 6, null, null),
('c33a9806-b52a-4c97-bf54-e388b6ef856e', '207118bd-e060-43c3-9439-4ea7bc8e3d34', 'ce1beaec-bbac-4275-90c6-58c3f4d8209c', 'material', 10, 'Gram', null, 7, null, null),
('34e6b26e-25e6-49a9-a7ce-d9d24e537f5b', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '89809a1d-8158-4939-852c-27f1baa77f5a', 'material', 10, 'Gram', 1.6, 8, null, null),
('955b704f-ec27-41ba-8b3a-cdd9c89e1629', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 10, 'Gram', 4.38, 9, null, null),
('7e05e661-43a0-4281-9111-24e9a9c215f5', '207118bd-e060-43c3-9439-4ea7bc8e3d34', '0bd58997-da36-4c50-b3aa-487cf8df0a6b', 'material', 1, 'Piece', 0.43, 10, null, null),
('d371ba4b-63f0-4f78-9d73-8f40bdff14e4', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'b3761484-fca6-40a8-9d9b-6fc857dd4619', 'material', 30, 'Gram', 4.17, 0, null, 'Paste'),
('8cb10cdc-79e1-4c10-a30e-f8a7df67dfb0', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '82fe882c-c550-4cfa-b51f-36c41daf2850', 'material', 120, 'Gram', 48.64, 1, null, null),
('cf9ce4ae-a584-4550-a373-4f3be7792ff7', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'a14eb7aa-8ead-41c9-9a02-8128d3c1ba1e', 'recipe', 50, 'Gram', 7.89, 2, null, null),
('d43e0fb8-13a6-492f-814e-c7a1c7a05374', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 3, 'Gram', 1, 3, null, null),
('565bd2b6-843e-4efc-abae-99a2e4eb5333', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 1, 'Gram', 1, 4, null, null),
('b21b6b85-52d9-48b1-8755-76388a0536e2', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 8, 'Gram', 3.5, 5, null, null),
('eefc7e68-c852-49f4-bfc7-7f46dcb57a34', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'e1b6a81e-d789-420b-8865-d54459fe4a56', 'material', 3, 'Gram', 1.06, 6, null, null),
('4999dddf-a43d-40f4-b282-39701a971f1d', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 7, null, null),
('aa3b1b63-e531-4320-8ee9-ee1d6b331fde', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'b84c573e-6808-4d5c-9423-851ca20031ef', 'material', 1, 'Piece', null, 8, null, null),
('c9de1d40-ebb4-4bd8-b6b1-c19bb53b94da', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'd8f77380-7f47-4c45-bbf7-026dc5c9d6e1', 'material', 5, 'Gram', null, 9, null, null),
('9b42d63d-3064-406e-945f-611202577ec2', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 5, 'Gram', 5.25, 10, null, null),
('46b28406-87cf-4748-8fb1-336b0ad98299', 'adccb2f4-5ecb-436c-a4fd-5f3c71745eb1', '99d5d9f5-4361-4444-86ed-0f4666be7356', 'material', 2, 'Gram', 2, 11, null, null),
('0e60a543-72b7-426b-a60b-39e5f4366310', '2fb60646-23e7-4726-9daa-52f19d401fba', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 10, 'Gram', 10.5, 0, null, null),
('56ebc5d1-50e8-41e8-9fff-568a80d966e0', '2fb60646-23e7-4726-9daa-52f19d401fba', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 5, 'Gram', 1.5, 1, null, null),
('b8ab16f4-6802-41a4-80b2-0df475d22862', '2fb60646-23e7-4726-9daa-52f19d401fba', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 5, 'Gram', 0.33, 2, null, null),
('ffc800a0-fb1b-41dd-ba0c-0c9e81df9507', '2fb60646-23e7-4726-9daa-52f19d401fba', '76595065-ca7c-4d2c-9602-de06a65c11cd', 'material', 90, 'Gram', 20.7, 3, null, null),
('f8dd31ee-baa9-4f6c-966a-e944a4f5073d', '2fb60646-23e7-4726-9daa-52f19d401fba', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 50, 'ML', 0, 4, null, null),
('f4c23fd7-e6d5-4a65-a959-f71dc9cd0d5e', '2fb60646-23e7-4726-9daa-52f19d401fba', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 3, 'Gram', 1, 5, null, null),
('51ba3d16-0059-4312-bbdb-3f42885b813f', '2fb60646-23e7-4726-9daa-52f19d401fba', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 2, 'Gram', 2, 6, null, null),
('fc686632-cd17-48a5-86f3-52a7a37e9ba4', '2fb60646-23e7-4726-9daa-52f19d401fba', 'aa9a3175-669d-45b6-9ce2-81660f12a062', 'material', 100, 'Gram', 38.46, 7, null, null),
('326d073d-920b-4970-91bf-4641c4698ed7', '2fb60646-23e7-4726-9daa-52f19d401fba', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 10, 'Gram', 4.38, 8, null, null),
('bfb2d070-2bc3-4006-ba3a-3d33274c4695', '2fb60646-23e7-4726-9daa-52f19d401fba', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 9, null, null),
('49552dd3-079c-4a26-8cd0-7f4e883aa164', '2fb60646-23e7-4726-9daa-52f19d401fba', 'd988ffee-d8df-420a-aedf-a6b3fd316e17', 'material', 5, 'Gram', 1, 10, null, null),
('c7bf48fc-10be-40e0-a8f8-accaf699c976', '2fb60646-23e7-4726-9daa-52f19d401fba', 'd79c7d12-01d9-4415-b68b-266fcf0113c7', 'material', 5, 'Gram', null, 11, null, null),
('5447ae16-2710-42a4-bc39-2df01540ba17', '2fb60646-23e7-4726-9daa-52f19d401fba', '18eb189e-181f-4ce2-b40e-960fd2ce7e7d', 'material', 5, 'Piece', 5, 12, null, null),
('569b8f46-6665-428f-88ff-2dc475f3e2ec', '2fb60646-23e7-4726-9daa-52f19d401fba', '1860ab44-d39a-472b-83e2-e0defe75f371', 'material', 1, 'Gram', 1, 13, null, null),
('a457e042-21ba-4257-b29e-41272eb8f04b', '79247968-d17c-4fc3-8d95-21b79b6b7c76', 'b1f10d8b-99af-44be-ba77-c20a37a5f4ec', 'material', 100, 'Gram', 7.27, 0, null, null),
('9e6cefbe-8095-4cf5-8124-2becd3a75047', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '847afabc-d03d-4911-94e0-39b2ceb8c002', 'material', 50, 'Gram', 5.63, 1, null, null),
('f645f2d7-55ae-4a70-9df1-a7529533a9e2', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 30, 'Gram', 25.5, 2, null, null),
('c6de7a03-9be8-4d1c-b97d-13c4f4fdd27b', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '9c14586c-ea8c-4b8b-87a5-fbc4591cd053', 'material', 20, 'Gram', 12.31, 3, null, null),
('f26b14c4-b379-4dd9-9fdb-f06857c77827', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 3, 'Gram', 1, 4, null, null),
('7be9326c-e7c3-4e2a-997e-2fb61389e48e', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 1, 'Gram', 1, 5, null, null),
('a679f42e-a4da-45d9-b9d7-bd45658aa741', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 8, 'Gram', 3.5, 6, null, null),
('91981c23-246e-49ee-bfdf-74ad4b7f5be2', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 20, 'Gram', 10.76, 7, null, null),
('132126c9-a784-481c-b45d-dc4a7a7c56a3', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 5, 'Gram', 4.25, 8, null, null),
('1a4fbf65-056c-4d30-8f81-fbaca466ce34', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '9c14586c-ea8c-4b8b-87a5-fbc4591cd053', 'material', 5, 'Gram', 3.08, 9, null, null),
('89cb6309-bfc5-4f32-80d3-4d0acab5fa0a', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 5, 'Gram', 2.19, 10, null, null),
('8c5c6035-bcbe-47e2-850d-865bffe85430', '79247968-d17c-4fc3-8d95-21b79b6b7c76', '9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'material', 3, 'Gram', 16.07, 11, null, null),
('a4910dc5-adfd-4a76-99e4-443587f50e47', '79247968-d17c-4fc3-8d95-21b79b6b7c76', 'd5479ed6-5a44-401b-8252-e75b64ff1b47', 'material', 3, 'Gram', 50.01, 12, null, null),
('a43188eb-8a87-4b40-8edb-cd380fbcecd0', '79247968-d17c-4fc3-8d95-21b79b6b7c76', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 0.5, 'Piece', 0.07, 13, null, null),
('be088c67-f985-4e57-bd81-0999aed8269a', '815c4b44-1141-46eb-adcd-94bc88f22d93', 'ec7d9c5d-921d-47ab-b213-8dc9566e0e5a', 'material', 105, 'Gram', null, 0, null, null),
('c9d504ba-9bb1-42c6-be9c-9d39dea765c9', '815c4b44-1141-46eb-adcd-94bc88f22d93', '3147aeaa-ac78-4953-b2b0-07d11a03358c', 'material', 50, 'Gram', null, 1, null, null),
('401e6890-e15c-441a-b1a1-8f7d89f51e66', '815c4b44-1141-46eb-adcd-94bc88f22d93', 'cd266f4e-621a-4f24-bdd0-690d6da4d7ae', 'material', 60, 'Gram', 16.8, 2, null, null),
('2207a68c-7fda-4b8f-b32e-54f1fd74154d', 'de88cea6-18a6-482b-8259-925a2885bd15', '7ee7e5af-7b29-4545-b080-88c37b2f152a', 'material', 100, 'Gram', 65, 0, null, null),
('348e67b8-48a0-4c93-b34c-2e95d6394644', 'de88cea6-18a6-482b-8259-925a2885bd15', '00911d16-6320-4f42-96c1-5556387a7441', 'material', 60, 'Gram', null, 1, null, null),
('f93a1017-3733-4ec8-aee8-2845271efe8d', 'de88cea6-18a6-482b-8259-925a2885bd15', '8962b28f-675d-4667-bfaf-be7aa8217c4a', 'material', 20, 'Gram', 11.33, 2, null, null),
('44fe826b-8833-48f2-a1bb-87b27ea8858c', 'de88cea6-18a6-482b-8259-925a2885bd15', '423bdec7-93f3-4667-b9e9-8382c26dd9fc', 'material', 5, 'Gram', 4, 3, null, null),
('c65c43d0-a05b-457b-967d-f3e9283e6177', '1327f36e-fe09-499b-ae5f-199dbaf34c96', 'c85dda9d-4bbe-4222-8032-1b9baa9c3596', 'material', 40, 'Gram', null, 0, null, null),
('ee38900c-f241-4f12-8e39-5a7bf8e63407', '1327f36e-fe09-499b-ae5f-199dbaf34c96', '1e256ef0-2d11-43cc-8ce2-08cd34caa7ae', 'material', 30, 'Gram', null, 1, null, null),
('86421883-1885-4658-94fb-621b06b7cd84', '1327f36e-fe09-499b-ae5f-199dbaf34c96', '42bef92f-bb84-4d3a-9b86-860be74d192f', 'material', 60, 'Gram', null, 2, null, null),
('f4f4f70f-ec31-46b2-aadf-81e4d2272e6b', '1327f36e-fe09-499b-ae5f-199dbaf34c96', 'be17627f-290d-4bdc-a8df-784f46cdb1f7', 'material', 10, 'Gram', null, 3, null, null),
('37a9c544-f975-48ee-8a9c-6a9384aa334b', '1188e820-37b0-4b09-b151-8313fde0eca6', 'a821dd45-815e-4d7a-bbcb-d50f1fc51be6', 'material', 40, 'Gram', null, 0, null, null),
('cd5fef5c-d507-4698-9a13-8a268958476c', '1188e820-37b0-4b09-b151-8313fde0eca6', 'd6e7e465-af14-405d-8dbd-2b6217a1c21f', 'material', 40, 'Gram', 33.04, 1, null, null),
('df909df4-e490-4151-afca-3f7d6f208eaa', '1188e820-37b0-4b09-b151-8313fde0eca6', '5be3a248-d160-4e97-b630-3e37e0fe1d09', 'material', 20, 'Gram', 15, 2, null, null),
('b1eab8c9-753a-4d5e-a7d8-6b152f30621d', '1188e820-37b0-4b09-b151-8313fde0eca6', 'da07ab88-8347-4451-b641-d545ad80fbc0', 'material', 10, 'Gram', 2.14, 3, null, null),
('915a6ecc-bd16-4d45-882d-c2446358d661', '1188e820-37b0-4b09-b151-8313fde0eca6', 'b9abf6f0-a9a2-427e-b55d-f3fc81daad62', 'material', 5, 'Gram', null, 4, null, null),
('40b1da15-2870-4f66-9a5c-ad3e75c28681', '5e9fa5ff-f92b-4106-a46d-89426b1d1f8c', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 30, 'ML', 9.33, 0, null, null),
('f1ea2775-0780-49e3-8201-c7d3d88c5141', '5e9fa5ff-f92b-4106-a46d-89426b1d1f8c', 'bc8f5f42-254f-4f96-96e0-1259714177d8', 'material', 60, 'ML', 1.64, 1, null, null),
('8a4cae7c-8049-4829-803c-21683f495e97', '5e9fa5ff-f92b-4106-a46d-89426b1d1f8c', '11487fdf-b285-491e-ac7e-a097d25df283', 'material', 210, 'ML', null, 2, null, null),
('1396d9be-2d33-4f27-a252-57a0c17d7534', 'b592c9fd-3f66-497e-9bd1-d4353b04a3e9', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 30, 'ML', 9.33, 0, null, null),
('5aa8f94a-8ff8-44a4-a62c-eed04dc8ac27', 'b592c9fd-3f66-497e-9bd1-d4353b04a3e9', '279cd876-c18c-4a2f-ae81-e7a1cd64f0db', 'material', 15, 'ML', 0.5, 1, null, null),
('945cee98-3c2e-44fa-8937-7a093d48bd1a', 'b592c9fd-3f66-497e-9bd1-d4353b04a3e9', '6a37cf3c-4233-4b7f-9978-30e7d192c739', 'material', 200, 'ML', null, 2, null, null),
('ef352257-6675-4fe2-a68a-535e280c7584', '718dca2b-cf84-4a43-a95a-2418fafe05b3', 'e8e635fc-e3d0-4c94-b765-787d9149ffa5', 'material', 60, 'ML', null, 0, null, null),
('274b384a-af56-4694-bb04-56d03c2b42da', '718dca2b-cf84-4a43-a95a-2418fafe05b3', '47b7fc35-4642-4dfc-b10e-bb2fef9094ed', 'material', 60, 'ML', 4.51, 1, null, null),
('53c4d1c5-22a7-4550-8f15-e03861563039', '718dca2b-cf84-4a43-a95a-2418fafe05b3', '40f43e1f-5e7c-4653-8ef3-355a12b19e20', 'material', 120, 'Gram', 16.5, 2, null, null),
('4e3a0b63-2f0d-49ed-be82-8fa6da4b023f', '718dca2b-cf84-4a43-a95a-2418fafe05b3', '4b3934d8-1a8f-4f1a-bc4d-6aba6bf8df80', 'material', 1, 'Piece', 0.19, 3, null, null),
('31696ebf-f54e-4311-b19e-7a733a91cc08', '718dca2b-cf84-4a43-a95a-2418fafe05b3', 'b468d5c6-b2f5-4035-8ca9-31b4e99985eb', 'material', 60, 'Gram', 0, 4, null, null),
('0f270fe8-5cfd-4da2-9fe0-d4c7995c7c1b', '5521cedc-3c5d-432e-8a88-2bd951a45a5e', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 30, 'ML', 9.33, 0, null, null),
('be31ceef-467a-4e17-b987-f86a0210df16', '5521cedc-3c5d-432e-8a88-2bd951a45a5e', '9912134e-e968-4abb-8a8a-abf5cd4fc83c', 'material', 1, 'Piece', null, 1, null, null),
('7f729dd2-5c64-48fd-9432-1801630f4829', '5521cedc-3c5d-432e-8a88-2bd951a45a5e', '37d25d3f-43d0-4b83-8e52-f479df8413a6', 'material', 292.5, 'ML', null, 2, null, null),
('3a73b398-f1b8-42c5-aefb-4a03673725fb', 'dc42b99b-2d55-4c36-a1fc-32c0e27228c7', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 15, 'ML', 4.67, 0, null, null),
('cb5ae801-efd0-4482-889d-82ef8b047637', 'dc42b99b-2d55-4c36-a1fc-32c0e27228c7', '227950d2-e48c-4556-b094-d45e3a3e1469', 'material', 60, 'ML', 24.3, 1, null, null),
('7b376adb-0078-4348-81db-00bd89bdc631', 'dc42b99b-2d55-4c36-a1fc-32c0e27228c7', '5b9da10f-1565-4212-bdd3-28e46f69859d', 'material', 15, 'ML', 1, 2, null, null),
('9d1d2e8e-7909-4136-bce6-65e02ef8138d', 'dc42b99b-2d55-4c36-a1fc-32c0e27228c7', 'aa789f22-e436-4d5d-bad6-92b3edd5685f', 'material', 140, 'ML', 14.62, 3, null, null),
('8e1f045a-39ae-458f-a949-e4b53cc5ab92', 'cd68a8c8-0bde-481b-aa85-535e90b9b7e8', '5a4acd44-9a9b-4cff-9950-45390f7d25a1', 'material', 45, 'ML', null, 0, null, null),
('35e77f0f-3041-4983-b1b7-c018948b951c', 'cd68a8c8-0bde-481b-aa85-535e90b9b7e8', '50178542-0347-415b-a131-f5fe537be261', 'material', 1, 'Piece', null, 1, null, null),
('14603c96-f8b0-418b-9f50-b97d12a47d58', 'cd68a8c8-0bde-481b-aa85-535e90b9b7e8', '24f997f6-cbe3-4974-ab1d-45517f8161f1', 'material', 170, 'ML', 28.34, 2, null, null),
('1f6f5434-5e06-47bc-9237-6a6794310405', '0f832199-7143-4afa-bb36-a34fcce74e06', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 18, 'Gram', null, 0, null, null),
('aa5bf945-754d-4e4c-99d6-873a1101453d', '0f832199-7143-4afa-bb36-a34fcce74e06', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 40, 'Gram', 2.67, 1, null, null),
('e1eaeec9-07bc-432b-8e78-ec9322e11414', '0f832199-7143-4afa-bb36-a34fcce74e06', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 15, 'Gram', 4.5, 2, null, null),
('0aaa8180-599b-467f-a99d-7150135a9578', '0f832199-7143-4afa-bb36-a34fcce74e06', '25cb24ff-8964-4d75-8b29-285fb3f7281d', 'material', 15, 'Gram', null, 3, null, null),
('4c126d3c-1804-4871-815b-6066a00349cf', '0f832199-7143-4afa-bb36-a34fcce74e06', 'fa5a09af-7710-4361-bf7d-1af7835fb8d0', 'material', 60, 'Gram', null, 4, null, null),
('5ea43b27-3601-4eb8-86f5-a2efd78ff84d', '0f832199-7143-4afa-bb36-a34fcce74e06', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 60, 'ML', 0, 5, null, null),
('d1898867-2310-4e1d-ae29-a8ff8e530521', '0f832199-7143-4afa-bb36-a34fcce74e06', '3cb29bfa-465f-41ab-a7a1-70196df0d0af', 'material', 60, 'ML', 2.53, 6, null, null),
('f9bc6c37-c942-42d6-80ef-18fdd5ff289e', '0f832199-7143-4afa-bb36-a34fcce74e06', 'efb23ca8-1da0-4ede-8d97-c6a30394b9b0', 'material', 50, 'Gram', 5.33, 7, null, null),
('91ec5ce3-3ea1-4a01-b870-4f183dc69fd3', '3b6ce92e-7947-476a-9974-682ac04ddefe', '9b1f5b34-c89a-4907-88a4-a4e4501db88a', 'material', 13.75, 'Gram', null, 0, null, null),
('1db49af9-1d00-4a7f-a29d-4c2fbf5bda50', '3b6ce92e-7947-476a-9974-682ac04ddefe', 'cc656ce8-7a7f-4c56-9716-e732b19a9554', 'material', 120, 'Gram', null, 1, null, null),
('f8d7184d-6ab5-408a-984a-6dde40a9692f', '3b6ce92e-7947-476a-9974-682ac04ddefe', 'b87332b3-706a-4513-968d-59b729d5ffde', 'material', 30, 'Gram', null, 2, null, null),
('202031b0-94a0-476b-bc1d-6bca010d4df3', '3b6ce92e-7947-476a-9974-682ac04ddefe', 'b757c72c-b05d-4f6c-aaf2-2d72549df04d', 'material', 4, 'Gram', null, 3, null, null),
('fc5f5858-1da8-4768-9ef2-2cd1063e794d', '3b6ce92e-7947-476a-9974-682ac04ddefe', 'e090e6f7-ffe3-470b-be7f-949ec5d14a01', 'material', 4, 'Gram', null, 4, null, null),
('b8c4b9ab-c3a5-4647-a15f-d6f284e6e358', '3b6ce92e-7947-476a-9974-682ac04ddefe', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 15, 'Gram', 4.2, 5, null, null),
('1676d038-0fe8-419e-9c82-6e4869ad492e', '3b6ce92e-7947-476a-9974-682ac04ddefe', 'f8ad26b2-1c21-477b-b36d-d13fea1b316a', 'material', 10, 'Gram', null, 6, null, null),
('b25f8645-d2d4-4385-8a37-9f3a000b43bd', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', '17b4bd6b-98b0-4524-adbc-067071acdc1b', 'material', 50, 'Gram', null, 0, null, null),
('a7765406-aeb8-43ab-9a63-8cf6e2709591', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', 'c3bb3bdb-8636-4786-a7af-c94b8eb86297', 'material', 30, 'Gram', null, 1, null, null),
('3443a847-da16-4f54-8faf-24a744d7836b', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', '091837d5-4ded-4495-85fa-891976d6a1ac', 'material', 15, 'Gram', null, 2, null, null),
('5d4530c7-d2ad-4b7c-ad06-63ef981a5025', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 20, 'Gram', 1.33, 3, null, null),
('0a539c65-4ed9-47b2-b96b-a6c74f9f7f45', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', 'f21524c8-2445-4eef-89d6-c8c0612448a5', 'material', 20, 'Gram', 1.74, 4, null, null),
('2a90f212-ae18-4165-94e7-f25fa4c107f9', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 10, 'Gram', 1.5, 5, null, null),
('986bfcd2-addf-4fbf-ad0e-f3e42e488282', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', 'b29ef1e8-98f9-4ded-81ec-f814509c5b93', 'material', 6, 'Gram', null, 6, null, null),
('b6ce12ca-b07f-4fb1-ad47-140946239ccd', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 7, null, null),
('591eb94c-9e65-42fe-a592-ed2a50b4584b', 'd524b0bc-b2be-47bc-a3ae-be2e5476142e', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 8, null, null),
('b500857a-9c83-4888-9c2a-b1b511e6c58f', 'ca5f1671-1090-4a66-9f52-45cc860d149e', 'b94c7ba8-2348-4d85-9f73-91d8d10f7f83', 'material', 75, 'Gram', null, 0, null, null),
('b63ff856-9bc3-4b27-9a7f-51ad7fb6c4ef', 'ca5f1671-1090-4a66-9f52-45cc860d149e', '1ff4dc7d-7d45-4dd9-9dc4-8f5d9ca140d7', 'material', 5, 'Piece', null, 1, null, null),
('3c02dc38-db91-4037-baac-bd3e954de87b', 'ca5f1671-1090-4a66-9f52-45cc860d149e', 'be154f02-127c-4f82-9613-bdc60dabb1e4', 'material', 1, 'Gram', 0.1, 2, null, null),
('34caf019-0b95-40d6-b838-c715f416e0a9', 'ca5f1671-1090-4a66-9f52-45cc860d149e', 'aade08e9-ad43-46e0-a45f-297a0d5a33d9', 'material', 15, 'Gram', null, 3, null, null),
('66a354da-f191-4588-9515-2fd4ad4a1b03', 'ca5f1671-1090-4a66-9f52-45cc860d149e', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 5, 'Gram', 0.66, 4, null, null),
('6f96caa4-d43f-41a9-a788-fb7016393aea', 'ca5f1671-1090-4a66-9f52-45cc860d149e', 'bab6d6e8-fac4-408c-88ad-3ac3d782a56b', 'material', 0, 'Gram', null, 5, null, null),
('832491cb-8ab5-4b77-8e89-376a40ea8eff', '661af458-fded-4192-8113-598f06fb26a5', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 15, 'ML', 0, 0, null, null),
('72734f54-7a36-428b-a2a3-c20ba028fce7', '661af458-fded-4192-8113-598f06fb26a5', '3c187146-cfe5-415d-8b28-28e68de4b27d', 'material', 133.33, 'Gram', null, 1, null, null),
('a8ffb305-bc9f-454c-9c07-3e94fa5f4e9f', '661af458-fded-4192-8113-598f06fb26a5', 'ec13c55e-f1a5-4368-aa85-cef468242faf', 'material', 30, 'Gram', null, 2, null, null),
('72b7ccc8-635b-4eab-8f62-d28ebb57acb6', '661af458-fded-4192-8113-598f06fb26a5', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 0.3, 'Gram', 0.1, 3, null, null),
('aee956bc-0bfb-46e5-ac4b-4f38d5c7e459', '661af458-fded-4192-8113-598f06fb26a5', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 1, 'Gram', 0.33, 4, null, null),
('7eb4a84e-1b97-4e31-8ecf-cd77206fd3ba', '661af458-fded-4192-8113-598f06fb26a5', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 0.5, 'Gram', 0.05, 5, null, null),
('47510145-f792-4568-9af5-cd75ade6fe83', '661af458-fded-4192-8113-598f06fb26a5', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 2, 'Gram', 0.3, 6, null, null),
('a6cfee77-ea60-4143-bdac-ccbee809ef3c', '661af458-fded-4192-8113-598f06fb26a5', '3d89d37b-16a9-498c-acf8-69b79ca73984', 'material', 1, 'Gram', 0.2, 7, null, null),
('2f4bfdc5-b5c3-43d2-95fd-d78766efca50', '661af458-fded-4192-8113-598f06fb26a5', '7b91720c-ca2c-4314-b29e-4cc41200a267', 'material', 2, 'Gram', null, 8, null, null),
('16d360ba-404e-462e-8073-bd3d1be0c5fd', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', 'a0631567-5e5f-4b72-98f2-6a0edff165ea', 'material', 70, 'Gram', null, 0, null, null),
('3145b01d-50ff-48fa-b403-28b091203fa1', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', 'f1eaeef6-3c25-4818-ae9d-c38841124733', 'material', 50, 'Gram', 13, 1, null, null),
('5f6441a3-610f-4c91-9781-11dc80b38784', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', '6b151ba9-8b02-4100-9348-ead7930df7de', 'material', 20, 'Gram', null, 2, null, null),
('5faac379-edfb-4c6f-ab8e-cb812cfe7006', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 10, 'Gram', null, 3, null, null),
('ae05ea72-b7da-493d-9b2c-e2babfc4ce4b', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', 'afd4c1a4-20ef-4236-aedc-5aded715e74d', 'material', 50, 'Gram', null, 4, null, null),
('cf0500fd-4bda-4a82-9f67-9e7473f3f244', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', '3354b232-eeb6-44b7-b220-670f00f0b957', 'material', 3, 'Gram', null, 5, null, null),
('7c445ff7-8dd6-4ec1-aa60-2ca909b9a289', '5568b7f5-5eb6-4d02-8a43-fe095f521bc0', '53c5058f-3a96-48f8-a017-907dc9debaea', 'material', 20, 'Gram', null, 6, null, null),
('13cf436c-ca2a-4031-a06a-a4097143813b', 'c4cab38c-88b8-4148-9e21-728490324ce4', '96e77094-e41a-46c8-bdcb-9f1ef8bdee5d', 'material', 190, 'Gram', null, 0, null, null),
('007f81fe-1336-4309-8f8b-61fcb3201d7e', 'c4cab38c-88b8-4148-9e21-728490324ce4', '161b3508-db7c-4f29-a73e-20068cb616ea', 'material', 20, 'Gram', null, 1, null, null),
('93f46b0d-e861-4fd7-998f-3470e9ca9b24', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'cc076be6-96cc-425c-bd32-8957acc75cd2', 'material', 5, 'Gram', null, 2, null, null),
('68ded26c-2dba-4794-959a-4fcbf25c24ae', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'e1b6e058-6aa7-4aa7-b15f-c4c93c27eba5', 'material', 15, 'Gram', null, 3, null, null),
('89952915-8e52-452a-a05e-be29d03a5996', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'e75a21d8-711c-4343-b2fe-1587a5c6df45', 'material', 15, 'Gram', 3.69, 4, null, null),
('179b0fe4-b1bf-40c9-9a7e-75fe134eb429', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 20, 'Gram', 1.33, 5, null, null),
('4bfbfb3b-323a-4f15-abbd-ed51fbcc626b', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 15, 'Gram', 2.25, 6, null, null),
('54f4c9b3-8f1e-48cc-9f9c-10350161a512', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'b29ef1e8-98f9-4ded-81ec-f814509c5b93', 'material', 5, 'Gram', null, 7, null, null),
('7bf56b21-5193-4418-b75d-1f0416396e55', 'c4cab38c-88b8-4148-9e21-728490324ce4', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 3, 'Gram', 0.7, 8, null, null),
('e83306a2-7bb2-4c06-9044-94a5de8f98b6', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'f1001466-1803-48da-88a7-770a3bf1b19c', 'material', 5, 'Gram', 1.5, 9, null, null),
('8589554c-d7de-460e-9a78-e2e362a4197b', 'c4cab38c-88b8-4148-9e21-728490324ce4', '66d2bc8a-fbe2-49fc-94b3-adce6067a9a5', 'material', 15, 'Gram', null, 10, null, null),
('33796def-d8ce-402b-a229-e1e4e7479ad6', 'c4cab38c-88b8-4148-9e21-728490324ce4', 'ac1c12a7-9aa0-4fb7-82bf-aab7ceb461d8', 'material', 10, 'Gram', null, 11, null, null),
('113f61c8-496a-447a-846c-c87220d5c5a2', '2c6054e1-2a32-4291-8449-079d33eae21b', '72b20788-d1ac-429b-9903-084092e9231d', 'material', 160, 'Gram', null, 0, null, null),
('879f96de-3b73-4bd7-8f88-a81c80c4431f', '2c6054e1-2a32-4291-8449-079d33eae21b', '3eea824a-fc29-46b0-974b-1d1a44c92231', 'material', 12, 'Gram', null, 1, null, null),
('cb112576-f4ec-454a-bab5-0590641afeda', '2c6054e1-2a32-4291-8449-079d33eae21b', '576398d1-472f-4d2d-89db-bea186f6a682', 'material', 4, 'Gram', null, 2, null, null),
('a20212e3-8b98-43a1-a3f1-275ce27ed608', 'b8b9451c-0335-4903-bd1d-28cf4544572a', '58f0a453-bbd5-442c-bb12-6af792e5f3dd', 'material', 75, 'Gram', null, 0, null, null),
('48a8f9f0-5a85-4a72-a669-5a7174e0e619', 'b8b9451c-0335-4903-bd1d-28cf4544572a', '1ff4dc7d-7d45-4dd9-9dc4-8f5d9ca140d7', 'material', 5, 'Gram', null, 1, null, null),
('c25df161-19ff-4e13-b964-af2fd43484e7', 'b8b9451c-0335-4903-bd1d-28cf4544572a', 'ea4f4990-f636-4777-bfb0-c061ad72f31a', 'material', 10, 'Gram', 3.33, 2, null, null),
('ba1fde0a-c48b-432d-bd5b-e893328190dd', 'b8b9451c-0335-4903-bd1d-28cf4544572a', 'e1db6e18-6a83-4cbb-989d-e180eb70d51e', 'material', 10, 'Gram', 1, 3, null, null),
('3ff5c701-7351-44b5-b309-f9e6ef99dbba', 'b8b9451c-0335-4903-bd1d-28cf4544572a', 'a98fb32a-31a0-4f58-be7c-69c9bdc03d71', 'material', 5, 'Gram', null, 4, null, null),
('c2848225-6d63-4bc6-b6d3-104cbd5b4944', 'b8b9451c-0335-4903-bd1d-28cf4544572a', 'a28171b4-31da-4e83-9e21-618bb8358b42', 'material', 1, 'Gram', null, 5, null, null),
('8c7d8c28-ae1a-4399-8ea8-2e0c0f1962f2', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '280048c6-d5b3-43e1-a7d0-8b5f7ca222f5', 'material', 150, 'Gram', 15, 0, null, null),
('02b161af-8a13-456d-9acb-a225454b5d67', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', 'cc48b858-85a2-41cf-a5f5-20e7f53a7c1f', 'material', 80, 'Gram', null, 1, null, null),
('cfe736a9-e67f-47fe-9429-8dfb41f7a094', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 10, 'Gram', 0, 2, null, null),
('02a84c8d-9b2b-4417-ad61-64b9c08f46a7', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '67ea7ce5-d608-41a0-8407-d3a04cf54b64', 'material', 1, 'Gram', null, 3, null, null),
('11901f3f-fffd-4ebf-9314-a52ce0a4e077', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 1, 'Gram', 0.18, 4, null, 'Chopped'),
('85992127-65d7-40ce-8273-eb488514252e', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '0b4c1980-7f61-4e32-baec-7240bf3ed4fc', 'material', 2, 'Gram', null, 5, null, null),
('a8cfa70e-3de4-437f-9e63-b8e9be172644', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', 'cdfc27a2-3405-4bfc-9ee2-9220cc9d0346', 'material', 40, 'Gram', 3.4, 6, null, null),
('ff7ebff5-e46b-4adc-926d-2b6a7fd54d92', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '1c2e3c50-aa4a-4c01-a026-eaf511f54338', 'material', 20, 'Gram', null, 7, null, null),
('27cbe3b4-9fe9-4b3b-aee6-9411d20b1de2', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 10, 'Gram', 8.84, 8, null, null),
('5a307451-6ed4-4f33-986a-c1c22a1de3fe', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '82d84811-56ae-410f-96a9-bbfd1890e256', 'material', 5, 'Gram', 1.66, 9, null, null),
('dd2b8128-c05c-4726-8ea0-b509371e8759', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 3, 'Gram', 0.93, 10, null, null),
('2c0972a0-d9b3-4024-b92e-c53e99a39079', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '5ce2fa98-cbc1-407e-a069-aec8ef45b5e3', 'material', 1, 'Gram', null, 11, null, null),
('46af272b-9d6a-4643-8b2c-c33f25627aec', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 0.5, 'Gram', 0.17, 12, null, null),
('8495d870-4675-44fb-a541-96e45262d753', 'bbfed023-5ef3-4436-a33f-f68cc553cc39', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('2ede02c7-3c22-4954-96f4-28f31b7d4835', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', '8a5f9308-fb2e-4d66-acb5-96d8ee8bd0d7', 'material', 30, 'Gram', 3.14, 0, null, null),
('56738d18-3183-4ecd-8406-e00aedfdef2c', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', 'd05b4e1f-b73e-4755-8485-6511e7575254', 'material', 180, 'Gram', null, 1, null, null),
('d0b6e7e1-995a-4f00-995f-3b44476ea89f', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', '30527761-9324-4ff5-b6bc-a9cea17dd410', 'material', 5, 'Gram', null, 2, null, null),
('48c057bf-547b-4797-b271-201c92e54c68', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', '38ac9ff2-b4b2-45ce-966c-81ed9479d12f', 'material', 20, 'Gram', null, 3, null, null),
('b55205c5-e838-4121-963f-ec5ec28997e7', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 20, 'Gram', 5.6, 4, null, null),
('14738143-3fa0-4a0a-8562-798a34c4e701', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', '87f80e92-b881-45cf-8322-cf0e24601542', 'material', 10, 'Gram', null, 5, null, null),
('5da88493-260f-4922-b69d-ee5bc58b4f89', '636c7ba7-c402-4cd0-9fcd-af7f24d5da5b', 'a98fb32a-31a0-4f58-be7c-69c9bdc03d71', 'material', 2, 'Gram', null, 6, null, null),
('5fb0dec0-1d1d-468c-9257-6621b9e5f962', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '337a077f-f070-442d-a816-771a1a688218', 'material', 140, 'Gram', null, 0, null, null),
('47efe9cf-e465-47c6-a84c-706591c09a89', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '9b07205d-e480-46ee-812e-a3339b9d8ff7', 'material', 50, 'Gram', null, 1, null, null),
('64826d85-d5dc-4d7d-b579-03b0f0a16416', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '01503849-887f-43cd-90a8-6c7b9138e31d', 'material', 15, 'Gram', null, 2, null, null),
('90f69ff7-9757-4eb9-8627-8629195bcbe0', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', 'e824ddce-56bb-4d05-83d9-c7fd6ca59ded', 'material', 15, 'Gram', null, 3, null, null),
('0618ba5b-91a7-4000-8cc5-38b7156acb2e', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '8b3a51e7-967b-4496-baf9-fd6ce9b84a0c', 'material', 5, 'Gram', null, 4, null, null),
('3751a572-a6e4-473e-80eb-6a47d1a39826', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '93770c16-6bbd-4a33-ad74-c0fbed88820f', 'material', 10, 'Gram', null, 5, null, null),
('1e0ce9cc-d1b5-499f-ad4a-abfb020ca9ab', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', 'f4f20f58-f613-4345-b891-9db9ac43ecd8', 'material', 10, 'Gram', null, 6, null, null),
('67c81f0e-6e65-496e-86bf-e6ea6fc0a1f5', '1700888c-cefa-4ee8-877d-f8a6bd0e80d1', '0f260bae-1aa4-4085-8e56-36f196542c50', 'material', 15, 'Gram', null, 7, null, null),
('bea0e606-2ee5-40bf-a17a-386541d5ac61', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '74c2c7d0-0da2-4f09-b650-33d1a818bfe4', 'material', 1125, 'Gram', null, 0, null, null),
('c01aa7df-3dd3-4d37-af5a-d77bcc35e0bd', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', 'a2f4456a-44a2-4dbd-a0e1-93c213fff5cb', 'material', 550, 'Gram', null, 1, null, null),
('f2c012a4-8dae-4653-a69e-2499e25d7292', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '10fd013c-fede-4beb-8a79-0e7c87265ae7', 'material', 3, 'Gram', null, 2, null, null),
('77c6dd06-a025-4623-9cdc-a093b3ee60a9', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '8f0a4ee9-4236-424d-90a5-d36d1bfa068b', 'material', 2625, 'Gram', 314.21, 3, null, null),
('a771a5c1-3a83-4461-934b-73df66a47139', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '2e12df1e-25b8-4d6a-886e-ea0a2e69c660', 'material', 1900, 'Gram', null, 4, null, null),
('3410da80-e9a4-4762-b8a6-696679fee3dc', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '59383cd6-3a31-4d8f-8f9b-964ec2610ef4', 'material', 5, 'Gram', 0.89, 5, null, null),
('74f620f1-4bc3-4e2e-b71b-406a9fd7f444', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 90, 'Gram', 30, 6, null, null),
('7c08446d-3358-476a-aa19-3c85f6792c99', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', '86518e09-853c-42f6-beae-f1b3c5dd2d3b', 'material', 50, 'Gram', 55, 7, null, null),
('f272f0d3-02e6-4dc1-b459-5e45fcd8532d', '1ad11d34-fc17-4d29-ada3-4c51600c81d6', 'efb23ca8-1da0-4ede-8d97-c6a30394b9b0', 'material', 25, 'Gram', 2.67, 8, null, null),
('c7681f38-140c-420c-a71d-871c4c112c41', '964002ee-ab38-4dcc-aeed-72337888907c', '85bedf2b-7c0c-4caf-8374-ea696df43612', 'material', 150, 'Gram', 172.5, 0, null, null),
('2c7b35a2-4ee9-4552-a764-e586d73375dd', '964002ee-ab38-4dcc-aeed-72337888907c', 'f1eaeef6-3c25-4818-ae9d-c38841124733', 'material', 100, 'Gram', 26, 1, null, null),
('17e5490c-56af-4b2f-9fce-7ce56649bc65', '964002ee-ab38-4dcc-aeed-72337888907c', 'fc89bee0-9a6c-440d-8a1d-37ce672959f1', 'material', 20, 'Gram', 2, 2, null, null),
('6a8b1a62-ab9f-43bd-95b2-cc1c264ba0ba', '964002ee-ab38-4dcc-aeed-72337888907c', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 10, 'Gram', null, 3, null, null),
('6584364b-3adf-4465-b859-63b04114f53b', '964002ee-ab38-4dcc-aeed-72337888907c', 'ee5248cb-1f56-43fb-ac26-caa7d7870217', 'material', 3, 'Gram', null, 4, null, null),
('df6eccf6-2a11-4a50-9eb9-56b229afa0b4', '964002ee-ab38-4dcc-aeed-72337888907c', '4f662bc1-193b-44d2-a833-483314462781', 'material', 5, 'Gram', 1.45, 5, null, null),
('2aa1fb4b-81b2-4a75-b4b5-ccf815c722be', '964002ee-ab38-4dcc-aeed-72337888907c', '40d9a86b-1a95-4e4c-b03e-1a8a39ca3671', 'material', 180, 'Gram', null, 6, null, null),
('7acc8463-d144-4cc3-a00a-02c047279bf5', '964002ee-ab38-4dcc-aeed-72337888907c', 'f11f64cf-9f8d-44aa-82e4-069be23527ea', 'material', 3, 'Gram', null, 7, null, null),
('5a9191d1-e643-4494-b8e9-a7126ae50593', '964002ee-ab38-4dcc-aeed-72337888907c', '9a4754ba-aaa8-4b87-b051-4354d340d168', 'material', 10, 'Gram', 3, 8, null, null),
('72420f24-bf05-4645-aefe-db45a2dbad4b', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '025bc71a-88b8-468e-ac77-741effa10f18', 'material', 30, 'Gram', 4.03, 0, null, null),
('3f090a82-793d-4306-99bc-135f6ca7ba16', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '2c174958-6e67-49c0-a3e7-7116034d5ef3', 'material', 30, 'Gram', null, 1, null, null),
('9bbe2d35-9e49-4bfb-ae6d-a5e14c259b00', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'f21524c8-2445-4eef-89d6-c8c0612448a5', 'material', 30, 'Gram', 2.62, 2, null, null),
('99472b72-7555-4b21-9017-16b883feb432', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '4fd8cde6-cdce-41b5-b6d7-499198b6b6b1', 'material', 30, 'Gram', 8.4, 3, null, null),
('f2964164-994a-45e9-aff9-643922b55a97', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '98de845c-3efe-4041-863e-e854c2f5b9ac', 'material', 40, 'Gram', null, 4, null, null),
('de5f2311-db5d-49f9-97cf-87af4a9926ef', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '7d97fcc1-1782-47ac-a579-44ae26c13adc', 'material', 200, 'Gram', 53.34, 5, null, null),
('25146bad-b391-4671-9f83-58c504284d78', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 30, 'Gram', 0, 6, null, null),
('4ff39f0d-0709-4d60-b5fd-b23bb5d9e543', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 2, 'Gram', 0.67, 7, null, null),
('0a5c21e6-00df-417f-a97c-bc740cfc6f74', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 2, 'Gram', 2, 8, null, null),
('8c238a32-daa6-409c-953e-f1bd8fcfca7b', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 2, 'Gram', 0.62, 9, null, null),
('f4c1a948-c245-465d-8827-9bfad76be6b4', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'cd906e06-6c27-4f5d-bcaf-4e8085828dc9', 'material', 250, 'Gram', null, 10, null, null),
('a83fd226-75a8-4c2e-9999-3b478e0d5d49', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'f17454e5-f9e2-428e-9e1e-26e20f9aa09d', 'material', 5, 'Gram', null, 11, null, null),
('52bfe184-fb99-4dd4-8f4e-b575ac4feab6', '8f97dbfe-173e-4618-8170-4ce6f3654c48', '949b0d39-71ef-41d7-a34d-a7ab2a72c133', 'material', 20, 'Gram', null, 12, null, null),
('708118e8-22ba-46de-b4d3-128d4ee2cfd5', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'f11f64cf-9f8d-44aa-82e4-069be23527ea', 'material', 5, 'Gram', null, 13, null, null),
('9f2d2296-aac6-4405-8a20-64ddca984f79', '8f97dbfe-173e-4618-8170-4ce6f3654c48', 'ae7ec34b-0aa0-4c21-8338-446ee0245eba', 'material', 5, 'Gram', 0.5, 14, null, null),
('2df84d57-c74e-4ade-88ec-41b016623855', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 10, 'Gram', 1.43, 0, null, null),
('1cc3b4c6-0712-416d-ae6b-ef2003df3346', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '0a045830-9376-4715-b756-0b88b8768ef4', 'material', 2.5, 'Gram', 2, 1, null, null),
('274315eb-0877-48de-afc6-d5482ea869fb', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'f18180c2-8e9d-4bc4-8e96-7cf2aed10d09', 'material', 10, 'Gram', 8, 2, null, null),
('aa477825-9b1e-4aea-ac20-7834b10f3632', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'c128477d-b8a9-42dd-96ec-5f98895752c9', 'recipe', 10, 'Gram', 2.29, 3, null, null),
('d7ca9fe0-5aad-40ad-b119-5b9c3a5870e7', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'cf381b35-312e-4d5e-a4be-cf21dec63302', 'recipe', 15, 'Gram', 0.95, 4, null, null),
('fdd8f988-dd5b-43b5-93b7-4068fd58099a', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '7d97fcc1-1782-47ac-a579-44ae26c13adc', 'material', 200, 'Gram', 53.34, 5, null, null),
('d9fb0e5e-a12a-4089-9710-de4e8a8a7392', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '321d480b-9b11-4956-8b12-a2c3287d36e8', 'material', 100, 'Gram', 9, 6, null, null),
('49895379-26c2-45bd-8c39-55b2c5aa6772', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 50, 'Gram', 0, 7, null, null),
('3beb42cb-06d0-4faa-baff-243f3e0fbc0f', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 3, 'Gram', 1, 8, null, null),
('5a750d62-7c61-4f39-845a-88e4ee4577e1', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 9, null, null),
('d545d1f8-c17d-4864-801e-c9cb5bd90654', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 2, 'Gram', 2, 10, null, null),
('08096eb5-f2aa-4eb5-a208-ec1756ddd27b', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 2, 'Gram', 0.62, 11, null, null),
('1492f26c-7b28-4335-a10a-1e6b24ac6ecf', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '58578066-e18e-41e8-8565-2d95ea4f5425', 'material', 1, 'Gram', 3, 12, null, null),
('6392f42a-c431-430e-afd9-2e1dba66d181', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'f1eaeef6-3c25-4818-ae9d-c38841124733', 'material', 20, 'Gram', 5.2, 13, null, null),
('843e11ef-87db-41a7-b9f1-025981629230', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 20, 'Gram', 1.14, 14, null, null),
('1ea6c196-3681-4123-9dff-d5fc34aa7d5d', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '4fd8cde6-cdce-41b5-b6d7-499198b6b6b1', 'material', 20, 'Gram', 5.6, 15, null, null),
('d2937389-fb5f-479e-9876-927202b5f1d3', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'f4102d46-43a3-4c50-83f8-84e7be8f9e2f', 'material', 20, 'Gram', 26, 16, null, null),
('2f1af8a6-f460-41f5-8c32-ad5751403976', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 2, 'Gram', 0.47, 17, null, null),
('941d6307-cbff-4268-ac50-8bf6dad6c5e7', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '8c3a3f3d-bcf8-4ffb-bc40-5e621f4191ec', 'material', 2, 'Gram', null, 18, null, null),
('824902b8-f8ac-47e3-8475-a09732b3c7af', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 1, 'Gram', 0.16, 19, null, 'Slit'),
('9c33fa34-f099-4c53-8485-3905aaae9115', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', 'acd8f225-d1d5-41e9-b288-c8bc95caea67', 'material', 1, 'Gram', 1, 20, null, null),
('e7eafb89-cf8f-42e6-9a21-830e4ea92d12', 'a1817b7c-33ec-449e-9591-6b2e5d22ceea', '5b37ecbd-29a1-485c-84f2-616a4f06cf41', 'material', 10, 'Gram', 1, 21, null, null),
('92b071f9-e402-40a5-b6f9-c42d6011c39b', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'f52ff4df-9bea-4abe-84c1-869bb61c0ea6', 'material', 10, 'Gram', null, 0, null, null),
('5c182f5b-ce3f-4f5e-a103-950471c7f66e', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '068fdfd6-d2d5-4886-a64d-ce44228c15fe', 'material', 150, 'Gram', null, 1, null, null),
('61c8b91b-362a-4c88-bd01-49a71aa48546', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '23f58670-dac7-4fee-ac4d-2eb201233b27', 'material', 70, 'Gram', null, 2, null, null),
('575f0ec5-0ac7-47bf-9639-291222395094', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '6f106fae-149b-4425-9695-13f52004dfd7', 'material', 30, 'Gram', null, 3, null, null),
('004582ce-69a6-47f0-9536-d67b63cdcd00', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '66a48deb-bfdc-4e05-94b0-4677871f1b4e', 'material', 600, 'Gram', null, 4, null, null),
('80fb6916-d4d4-416f-95f3-fb47ab90193e', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '315f8d18-490c-43d8-b845-08da3afae878', 'material', 20, 'Gram', null, 5, null, null),
('239992c1-12d8-4884-aecc-4d59406f91b4', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '6634b99f-86ee-40bd-b5b2-58726b5eabaa', 'material', 500, 'Gram', null, 6, null, null),
('8e9e7d21-5908-4254-92ec-0985fb5c78e4', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '3d85e83f-1921-427c-83bd-f6b3a68b9326', 'material', 100, 'Gram', null, 7, null, null),
('c8848ab2-fc06-425a-aad7-44e296f0d79f', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'c4839799-7797-4f2d-8d8e-f9c835aecb6f', 'material', 25, 'Gram', null, 8, null, null),
('53befd27-2fc2-453d-ba52-94b459c82204', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '35036b8b-d55d-453b-8006-44c08a8a2a30', 'material', 5, 'Gram', null, 9, null, null),
('caa2e160-9b1a-4ec6-a3ef-ef1e1b53b73f', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'f60b8b78-54e8-40e3-8c39-bb377ccb5e30', 'material', 1.5, 'Gram', null, 10, null, null),
('a24fbb6a-df80-4ffc-b649-9c5e09708021', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '9d5f3a67-6285-45fc-898b-efb8a43b95b0', 'material', 50, 'Gram', null, 11, null, null),
('b9c67cb7-af96-4916-aa5b-a7ca545fee62', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'c13c079a-3f9a-4658-9482-2a532d994ccf', 'material', 225, 'Gram', null, 12, null, null),
('f8039da5-efd3-412a-8efd-5e70c97713ef', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '5ab6b34e-ec32-46e5-8999-75cf65dd1eaf', 'material', 100, 'Gram', null, 13, null, null),
('b90d314a-4ab7-4c68-8ced-f1930f2a8940', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '0f1c05eb-dcac-4c13-a528-5f7bd692bc75', 'material', 250, 'Gram', null, 14, null, null),
('1a3942c5-b2b9-4cea-ab20-b48fc799fab7', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '4c87dfd5-3956-4cf0-a8fd-d9ee3532308b', 'material', 34, 'Gram', null, 15, null, null),
('0dd0719f-a738-4b6f-97a8-311052026065', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'a06f3e01-5c05-4dcb-b77f-63017f1daa51', 'material', 20, 'Gram', null, 16, null, null),
('4570dd54-2c3c-40a6-a7e9-a54d9a1e0a94', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '39d427a2-fbfc-4580-99a4-bbde3b195410', 'material', 60, 'Gram', null, 17, null, null),
('0d5c1da7-621e-4a8e-a719-53e5121ebddd', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '130ddad0-0f07-428a-a980-0968de34c021', 'material', 9, 'Gram', null, 18, null, null),
('be595956-80b2-48c5-b2ff-bc68445a3f80', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '88044a71-d58e-467f-bf1f-debe580e3a4b', 'material', 30, 'Gram', null, 19, null, null),
('de20ae6b-e31b-4a52-946f-0600a86e6f4c', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '059409f6-5c54-46dd-955a-525c855283c0', 'material', 10, 'Gram', null, 20, null, null),
('98a957d7-15e2-437e-89c6-962056b49abf', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '54e4e95a-3f2a-4220-8f7e-3152ee3a0df6', 'material', 556, 'Gram', null, 21, null, null),
('756f52e4-a4c5-4869-9fe0-b714e5ba2d07', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '27971dd9-b191-4212-b0e8-fcd6b39e4392', 'material', 566, 'Gram', null, 22, null, null),
('db21d4fa-0e9e-4c5a-ad20-6c971bec7e97', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', '90019b86-9f16-4a15-832b-6fba05df76af', 'material', 56.8, 'Gram', null, 23, null, null),
('7aa87be8-6437-4690-90d0-7cfa2c247d04', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'ebb457a4-bd79-40ad-8e2d-ae9e05b187d9', 'material', 56.8, 'Gram', null, 24, null, null),
('c22e2a04-d27c-4541-992e-fb63b2e74430', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'dd67fda8-e4f9-4521-9ee2-a2f2e5ce206d', 'material', 1701, 'Gram', null, 25, null, null),
('96db1dc7-0253-4733-8636-34613dd8d913', '18c449c3-4fd4-4e54-b2a0-4f09e32d75a8', 'f3b4ba99-8a01-4b78-8c9d-c51e0f0b79be', 'material', 20, 'Gram', null, 26, null, null),
('a2e64055-fb62-4e6d-8984-75aeaf7608bf', 'dff54880-f712-41ef-b57b-2f5153b02c62', 'eefc4579-e3d5-4883-8ce4-2326062d3e95', 'material', 550, 'Gram', null, 0, null, null),
('034e2d5d-c305-4d5f-af06-73d972e2c3aa', 'dff54880-f712-41ef-b57b-2f5153b02c62', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 6, 'Gram', null, 1, null, null),
('cb4dc324-2aa2-498b-944e-7d5782cda62a', 'dff54880-f712-41ef-b57b-2f5153b02c62', '32bf4541-9519-47f7-b401-6b70f0445009', 'material', 75, 'Gram', null, 2, null, null),
('1a23da8f-6f8d-433c-932d-5a5bd44d9946', 'dff54880-f712-41ef-b57b-2f5153b02c62', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 110, 'Gram', 7.34, 3, null, null),
('06d71b6a-deea-4f97-8850-fb469921a546', 'dff54880-f712-41ef-b57b-2f5153b02c62', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 12, 'Gram', 3.74, 4, null, null),
('f4aedc2c-e3cd-4ba6-ad64-236924c5f0b0', 'dff54880-f712-41ef-b57b-2f5153b02c62', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 8, 'Gram', 2.67, 5, null, null),
('2fdf48f0-2eea-44ff-9c31-a93b600fa12c', 'dff54880-f712-41ef-b57b-2f5153b02c62', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 5, 'Gram', 5, 6, null, null),
('c242b1a1-17b8-4fd4-b129-2f3fe85d43bd', 'dff54880-f712-41ef-b57b-2f5153b02c62', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 7, null, null),
('f37fff0b-bea4-48a7-8c0a-8f9361536f3e', 'dff54880-f712-41ef-b57b-2f5153b02c62', '99e82bb2-a398-4a4d-8421-896b11914dc8', 'material', 25, 'Gram', null, 8, null, null),
('38308c36-effd-4190-bd66-6123cd34591c', 'dff54880-f712-41ef-b57b-2f5153b02c62', 'a967dcb4-1b59-4b63-bacc-0e6411bb8319', 'material', 6, 'Piece', null, 9, null, null),
('4c3d2661-60ec-477d-917c-b5d0618d9eea', 'dff54880-f712-41ef-b57b-2f5153b02c62', '590392b7-1384-4577-b6be-e49ddad1d462', 'material', 0, 'Gram', null, 10, null, null),
('79cbbbd8-26ff-4a9a-a04e-628023bd2501', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 20, 'Gram', 2.86, 0, null, null),
('52dc316a-7ef9-4259-ac98-bfa38c594669', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 1, null, null),
('bffff2b7-2ad5-4192-96c4-cae369a65689', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'f7e2f12f-93ac-49c4-b5ef-57c5a6e29e91', 'material', 3, 'Gram', null, 2, null, null),
('1e12a2fb-ac07-41eb-9d46-dee9274059e5', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'ee9fce90-b3c0-4129-8edc-7eabe55ffc69', 'material', 50, 'Gram', null, 3, null, null),
('c47c675b-492b-41d2-99cc-e08dc5d6622d', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'b30a4d30-c6a5-4ee1-be8c-4471fce0f25f', 'material', 40, 'Gram', null, 4, null, null),
('adfe69e9-f0e9-4455-ad59-f7800c1c3d11', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 30, 'Gram', 1.71, 5, null, null),
('592eb26c-3837-433f-a378-4aed17d65e24', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '96e77094-e41a-46c8-bdcb-9f1ef8bdee5d', 'material', 20, 'Gram', null, 6, null, null),
('1f4fa375-ca53-4c58-8a8d-c1f1d74479b9', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'db817cd3-b856-472b-afda-1aacd2f90e60', 'material', 15, 'Gram', 1.5, 7, null, null),
('d9350c6c-2a25-4d3f-9f78-5256d20b5b95', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '099a3623-7fb4-4160-9ee0-beb1eec732e9', 'material', 5, 'Gram', null, 8, null, null),
('7ee9862d-decc-4ad2-9ea4-e2b6eb2b8c73', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '1f43db50-945b-4c76-8ad7-fd3c74192d5a', 'material', 5, 'Gram', 3.24, 9, null, null),
('ce9c3577-5437-427a-b0d2-453b9cbdba5b', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 2, 'Gram', null, 10, null, null),
('4f04037c-3c02-40d5-81d3-4535c74d9743', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'e20d606e-407f-4d9e-9618-ccc1fb3ef65d', 'material', 5, 'Gram', null, 11, null, null),
('b3b2862e-bbc3-45d0-9373-b4e33eac3e27', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '8385aa4b-3ef5-4b13-b992-efc8e7406208', 'material', 2, 'Gram', null, 12, null, null),
('bc8df97a-9eb8-4d20-a8b3-abd8abb08567', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 13, null, null),
('d358e9a3-bcd6-407a-9800-104384e57f5d', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 1, 'Gram', 0.33, 14, null, null),
('4c1caa67-5392-47dc-828e-0fcbe0271d73', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 1, 'Gram', 1, 15, null, null),
('c414a350-98ef-407c-a7b6-5abb00381f5c', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'c1df2196-dd69-4db4-bab1-69006fbc03a3', 'material', 3, 'Gram', null, 16, null, null),
('717218f0-8165-478e-848f-eead98775f3a', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '84793f25-141f-4524-8b72-c2ad6b1e2a49', 'material', 100, 'Gram', null, 17, null, null),
('2bed30f6-1a54-4a5b-9ca8-97505e4c5b34', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 18, null, null),
('ee0f5db6-bc1a-46e2-a485-104c70b7fd28', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'a7cac34f-d1ab-400e-9763-670e8805ad97', 'material', 5, 'Gram', null, 19, null, null),
('1e58f129-6501-4d4e-9305-a7ece6508a06', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'c095610f-0705-48fc-9434-2ed5357ee22a', 'material', 5, 'Gram', null, 20, null, null),
('e75efe24-5860-4f5b-8bdd-2f1965589bd7', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 5, 'Gram', null, 21, null, null),
('2ce161da-7e04-4a3e-9b4c-489361de350a', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '27f8c32f-0002-4c1e-9d03-006cb0e39c45', 'material', 20, 'Gram', null, 22, null, null),
('20d45ede-579f-4412-9286-f7dbd6230846', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '9d171529-ff82-46e5-931f-428689bac924', 'material', 80, 'Gram', null, 23, null, null),
('641b91cb-94ac-4a2a-bed5-5e907b8f878f', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'e20d606e-407f-4d9e-9618-ccc1fb3ef65d', 'material', 40, 'Gram', null, 24, null, null),
('cc70c88a-3f3a-48e1-81f0-3db07bc24f0c', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '5997bba6-4a12-4c4d-90e8-ca4b7f5a353a', 'material', 6, 'Gram', null, 25, null, null),
('76c9196e-c1f9-4ce6-9f5a-bd2329cd6eb0', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'a50d5e3c-9762-45d4-8b41-55db71056656', 'material', 20, 'Gram', null, 26, null, null),
('1990a0bd-cf45-4e01-9324-6496a6a77b9d', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '7065a07c-7a55-42c5-9a2a-50c127ca6d0f', 'material', 10, 'Gram', 44.28, 27, null, null),
('eae8f1b6-b00d-4e99-8b12-dba53c378e39', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '2313d49a-c2e9-4999-a373-f3beadd87e5b', 'material', 17, 'Gram', 0.75, 28, null, null),
('1080b51d-13ab-4a9b-b5a3-da24024a8262', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 90, 'Gram', 0, 29, null, null),
('ea12e92d-c67d-4bfb-bc4e-909fc46b9b2a', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 60, 'Gram', 8.57, 30, null, null),
('1e57478b-7e5c-49f2-b914-ec97b0d5e14b', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '8715f325-c6d1-493d-b131-91b6b6927fef', 'material', 1, 'Gram', null, 31, null, null),
('68bb0248-5447-4304-b775-3ee2528edbfa', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'b388fa9c-d558-4f9b-983f-55845f4bb57d', 'material', 200, 'Gram', 20, 32, null, null),
('8eeafb7f-7789-419c-a683-bace212d4cd1', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'cfccb5e6-03ad-4698-b96c-5ecff7fe4ff3', 'material', 10, 'Gram', 10, 33, null, null),
('3f726128-0a67-49df-9114-77c5a1c53b24', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 4, 'Gram', 0.4, 34, null, null),
('1a350b27-eac0-4ed5-9722-80febe7fe772', 'd5587bee-41cd-4dd9-9dec-1c0626dbc3c5', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 35, null, null),
('634469a6-932b-42db-9c7b-f9fbe81db370', '422ae84e-7045-43f1-b081-a696b1617752', '4f920a60-f27e-4706-aa05-0afde33061c6', 'material', 250, 'Gram', null, 0, null, null),
('62c4779a-08c0-4536-811f-36dfe87c651e', '422ae84e-7045-43f1-b081-a696b1617752', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 50, 'Gram', 44.2, 1, null, null),
('fb0b96aa-e320-4a99-a8e2-e209381194ae', '422ae84e-7045-43f1-b081-a696b1617752', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 4, 'Gram', 1.33, 2, null, null),
('37d61fcd-7d4c-4510-93ac-f2ec66409278', '422ae84e-7045-43f1-b081-a696b1617752', '91749770-d3ce-403c-a27a-572852c8aad0', 'material', 4, 'Gram', 4, 3, null, null),
('af5b0864-ae07-47d3-8321-30d96794dd52', '422ae84e-7045-43f1-b081-a696b1617752', '9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'material', 25, 'Gram', 133.88, 4, null, null),
('7f50b074-bbd1-474a-b544-37fb15dc5c4b', '422ae84e-7045-43f1-b081-a696b1617752', '6ad0bf82-5561-4825-b234-5566c7916fb8', 'material', 5, 'Gram', 103.38, 5, null, null),
('92e34202-088a-4aaa-b8e9-c3d949e878c9', '422ae84e-7045-43f1-b081-a696b1617752', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 20, 'Gram', 0, 6, null, null),
('11c2260f-939f-484a-9995-1ee184bb9c77', '422ae84e-7045-43f1-b081-a696b1617752', '14957cab-8687-4139-a683-7a5533a7ca15', 'material', 4, 'Piece', null, 7, null, null),
('52d2664b-bbee-460f-9ac0-b6133c838925', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'b30a4d30-c6a5-4ee1-be8c-4471fce0f25f', 'material', 500, 'Gram', null, 0, null, null),
('2e61652f-3041-4f74-9773-86a71686666a', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 100, 'Gram', 6.67, 1, null, null),
('d8f165e7-8584-49ca-b3e0-0fd247bafe13', '798efa84-8bf1-4fb9-875a-ebd11830121c', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 50, 'Gram', 2.85, 2, null, null),
('ad0313f6-cac5-4bf8-834c-885b88f9c070', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 10, 'Gram', 1.5, 3, null, null),
('d10618ae-dcbc-45fc-b1d2-8d5a08a982ba', '798efa84-8bf1-4fb9-875a-ebd11830121c', '2b11b89c-01f0-4d7e-80f6-49d992a5454c', 'material', 175, 'Gram', null, 4, null, null),
('ad76191d-b6d5-4081-a7f0-226cafa2ee90', '798efa84-8bf1-4fb9-875a-ebd11830121c', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 6, 'Gram', 2, 5, null, null),
('7b1ec62d-c936-4a1b-9842-953186a69dfc', '798efa84-8bf1-4fb9-875a-ebd11830121c', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 4, 'Gram', 4, 6, null, null),
('837b85c6-9b31-4d98-bcbe-a7d867f1cd16', '798efa84-8bf1-4fb9-875a-ebd11830121c', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 6, 'Gram', 2, 7, null, null),
('45d1745c-9871-45b6-8bca-bf8f9478e041', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 8, 'Gram', 2.5, 8, null, null),
('cecbd24f-8137-43f1-a6c2-56827d9645a3', '798efa84-8bf1-4fb9-875a-ebd11830121c', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 30, 'Gram', 9, 9, null, null),
('160e51d9-a872-4922-851a-9054c9351e21', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 3, 'Gram', null, 10, null, null),
('5f857c19-e85c-4b9a-9e8d-a16bd0e5c8f8', '798efa84-8bf1-4fb9-875a-ebd11830121c', '45d599d0-477f-466c-884d-4b36929b2498', 'material', 500, 'Gram', 50, 11, null, null),
('00699976-e60b-4be4-be00-f8ec2755e76c', '798efa84-8bf1-4fb9-875a-ebd11830121c', '1f43db50-945b-4c76-8ad7-fd3c74192d5a', 'material', 8, 'Gram', 5.18, 12, null, null),
('cd6aa3fc-50f5-42f6-95ee-d74b2766e01f', '798efa84-8bf1-4fb9-875a-ebd11830121c', '57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'material', 15, 'Gram', 30, 13, null, null),
('3259f3ed-8ab5-4724-8a5f-865c70075332', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'a65c0ba4-bf5d-44a8-a7b3-a559ec22a433', 'material', 50, 'Gram', 20, 14, null, null),
('5905a6c4-5ff3-466f-8f0a-81ede14d98c0', '798efa84-8bf1-4fb9-875a-ebd11830121c', '7fe377ff-9f5e-41fc-8216-72af7ec3697c', 'material', 20, 'Gram', 5.4, 15, null, null),
('503774dd-5d6f-4021-ac07-4d0b74c12bda', '798efa84-8bf1-4fb9-875a-ebd11830121c', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 6, 'Gram', 2, 16, null, null),
('54ff83e6-275f-4fb5-9827-c1304b8c87a8', '798efa84-8bf1-4fb9-875a-ebd11830121c', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 3, 'Gram', 1, 17, null, null),
('d9a4ba9b-672e-4ae2-8ea1-1534f03b8898', '798efa84-8bf1-4fb9-875a-ebd11830121c', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 6, 'Gram', 1.87, 18, null, null),
('0faa0b78-3c97-4681-9c45-1a76a36a463d', '798efa84-8bf1-4fb9-875a-ebd11830121c', '14957cab-8687-4139-a683-7a5533a7ca15', 'material', 5, 'Piece', null, 19, null, null),
('95063631-91c1-410e-b935-09a0ec98fda3', '1f23502b-cea2-428b-90ff-907ea1fb971c', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 95, 'Gram', 83.98, 0, null, null),
('0e6dbe89-fa4d-4fe7-8a20-97ab0eb9bc67', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'f1eaeef6-3c25-4818-ae9d-c38841124733', 'material', 100, 'Gram', 26, 1, null, null),
('d46b9944-a3f3-483a-af25-7461274588d8', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'eefc4579-e3d5-4883-8ce4-2326062d3e95', 'material', 100, 'Gram', null, 2, null, null),
('fe6ecba8-f2f2-4613-9242-15b18c68abcc', '1f23502b-cea2-428b-90ff-907ea1fb971c', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 6, 'Gram', 2, 3, null, null),
('558566e6-9d56-4ae2-b1f0-71438a522719', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 2, 'Gram', 0.2, 4, null, null),
('7d088600-0634-46fc-bb3c-ffea6bd4fbf9', '1f23502b-cea2-428b-90ff-907ea1fb971c', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 1, 'Gram', 1, 5, null, null),
('916c42ca-9654-4c69-b1de-4c6ed253de2a', '1f23502b-cea2-428b-90ff-907ea1fb971c', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 10, 'Gram', 2.34, 6, null, null),
('95ac5fb0-da09-43c7-8b08-3c879977d0a4', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'material', 3.5, 'Gram', 0.7, 7, null, null),
('16aac7c3-8e62-4def-89d9-83710d1e2382', '1f23502b-cea2-428b-90ff-907ea1fb971c', '6eee0c62-08d6-4a4a-be01-7fa98ab6f11c', 'material', 5, 'Gram', null, 8, null, null),
('ecce6616-4773-44f8-ba82-d9fa15b6db9c', '1f23502b-cea2-428b-90ff-907ea1fb971c', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 30, 'Gram', 9, 9, null, null),
('74bff5ff-14b2-4125-9fba-960af91ad7b6', '1f23502b-cea2-428b-90ff-907ea1fb971c', '48cb11cf-41e5-4464-9f67-0a8231840c39', 'material', 5, 'Gram', 0.64, 10, null, null),
('3d047265-5dab-44c9-bf6c-6581ee613f12', '1f23502b-cea2-428b-90ff-907ea1fb971c', '99ebc5f3-1b6b-4db0-8d8d-cff34583edc9', 'material', 10, 'Gram', 2.42, 11, null, null),
('4cca3469-0c7e-4dd1-a037-763c330c5133', '1f23502b-cea2-428b-90ff-907ea1fb971c', '81b31da2-d45a-4125-959d-07d877eb8147', 'material', 150, 'Gram', null, 12, null, null),
('2c78811c-c6f5-4ca3-bfaa-eedea3b7a1d8', '1f23502b-cea2-428b-90ff-907ea1fb971c', '4e4e10c7-713b-44dc-b735-d1dea121c480', 'material', 1, 'Gram', null, 13, null, null),
('22df8ee0-426d-464a-b1ad-a41c6b2d6213', '1f23502b-cea2-428b-90ff-907ea1fb971c', '32277907-3fbf-479f-9fa4-6103c99c3440', 'material', 5, 'Gram', 5, 14, null, null),
('e183c6a0-713a-4154-b44e-7910c1a8e65b', '1f23502b-cea2-428b-90ff-907ea1fb971c', '45d599d0-477f-466c-884d-4b36929b2498', 'material', 50, 'Gram', 5, 15, null, null),
('144c7a43-0ff8-431f-97a7-72625f2565a7', '1f23502b-cea2-428b-90ff-907ea1fb971c', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 10, 'Gram', 3.33, 16, null, null),
('b9dfddbb-06e0-486c-882e-ed424b500278', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'c251ea42-2811-4b89-9d99-a9afe34f095f', 'material', 8, 'Gram', 0.81, 17, null, null),
('6029ba69-c4ee-4723-9c7c-1dc54af677be', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'a85617d6-2ce4-43d3-b3ab-926d77893e09', 'material', 6, 'Gram', null, 18, null, null),
('bf589ad4-8095-4237-9ef4-e8ce59a99106', '1f23502b-cea2-428b-90ff-907ea1fb971c', '3282ad9c-5047-4d96-b365-7da94699b5d1', 'material', 1, 'Gram', null, 19, null, null),
('e7b0d66d-1d7a-4cf3-9b1f-e5eab2ac8a0c', '1f23502b-cea2-428b-90ff-907ea1fb971c', '7065a07c-7a55-42c5-9a2a-50c127ca6d0f', 'material', 10, 'Gram', 44.28, 20, null, null),
('df356dc8-a452-4d10-a713-5ae079cddae1', '1f23502b-cea2-428b-90ff-907ea1fb971c', '22768ecf-de34-4f23-abad-28289f90518e', 'material', 20, 'Gram', 6.22, 21, null, null),
('72231341-ffe3-44c1-bf4d-bf95cee0619a', '1f23502b-cea2-428b-90ff-907ea1fb971c', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 22, null, null),
('2bef3e15-f912-4634-9981-859a3c510b39', '1f23502b-cea2-428b-90ff-907ea1fb971c', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 3, 'Gram', 0.39, 23, null, null),
('3a566c3e-dd5c-4772-a190-d5d6ead95a3f', '1f23502b-cea2-428b-90ff-907ea1fb971c', '14957cab-8687-4139-a683-7a5533a7ca15', 'material', 5, 'Piece', null, 24, null, null),
('53446aba-2a1e-4e39-8363-7284b13e1083', '1f23502b-cea2-428b-90ff-907ea1fb971c', '5b37ecbd-29a1-485c-84f2-616a4f06cf41', 'material', 0, 'Gram', 0, 25, null, null),
('97305b44-b5e4-498d-b6ef-87419100c117', '1f23502b-cea2-428b-90ff-907ea1fb971c', '32fc5c0d-05d3-4c62-b031-9c651959bf72', 'material', 0, 'Gram', null, 26, null, null),
('f2846207-da45-4160-abf6-7a0c7186570d', 'fcfac89e-c20b-44d5-a249-16ad72367953', '1ff4dc7d-7d45-4dd9-9dc4-8f5d9ca140d7', 'material', 5, 'Gram', null, 0, null, null),
('46e04bfe-6c12-4bbe-bdcf-9858fabea75e', 'fcfac89e-c20b-44d5-a249-16ad72367953', '4f74b75a-901e-4aa3-ab95-b339c98a2a3b', 'material', 75, 'Gram', null, 1, null, null),
('e5ba7d17-668c-4338-94e3-73a605665bea', 'fcfac89e-c20b-44d5-a249-16ad72367953', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 10, 'Gram', 1.43, 2, null, null),
('e4c5ebdd-801b-4db7-a67a-fe746235f597', 'fcfac89e-c20b-44d5-a249-16ad72367953', '80e5cae5-b7e7-4c35-bcf1-3d74a1944860', 'material', 1, 'Gram', 0.9, 3, null, null),
('00f1acef-6135-4bb0-ba41-f7ee3f080af9', 'fcfac89e-c20b-44d5-a249-16ad72367953', 'e0a995c7-fd16-430a-abfa-d7843546a0a6', 'material', 20, 'Gram', null, 4, null, null),
('7c49be6b-81fe-41d4-bded-68a5d2944d97', 'fcfac89e-c20b-44d5-a249-16ad72367953', '321d480b-9b11-4956-8b12-a2c3287d36e8', 'material', 100, 'Gram', 9, 5, null, null),
('d4960c35-25fb-4cae-848f-09bff149ea50', 'fcfac89e-c20b-44d5-a249-16ad72367953', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 1, 'Gram', 0.33, 6, null, null),
('57236f52-0c9c-4ee9-a93e-217d6087f4e4', 'fcfac89e-c20b-44d5-a249-16ad72367953', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 1, 'Gram', 0.33, 7, null, null),
('59caeff6-5260-4e01-97eb-83e405793ece', 'fcfac89e-c20b-44d5-a249-16ad72367953', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 1, 'Gram', 0.31, 8, null, null),
('5df850ab-ca7c-4ebd-bfbb-7f3843fe2f14', 'fcfac89e-c20b-44d5-a249-16ad72367953', '06e28a02-b60b-456c-a295-e0f21906739b', 'material', 1, 'Gram', null, 9, null, null),
('20134fd7-9700-4ed9-9feb-e73e28702a5d', 'fcfac89e-c20b-44d5-a249-16ad72367953', '333fe0a4-5614-432c-8294-e1fb91b91c5b', 'material', 4, 'Gram', null, 10, null, null),
('ab8e70ce-e583-45d1-a3d2-2007f3614d00', 'fcfac89e-c20b-44d5-a249-16ad72367953', 'db817cd3-b856-472b-afda-1aacd2f90e60', 'material', 2, 'Gram', 0.2, 11, null, null),
('156fe735-7fb7-459f-aecb-ca832fdca1cb', 'fcfac89e-c20b-44d5-a249-16ad72367953', 'a776d4e9-8b13-491d-88b9-b1768cde8e9e', 'material', 2, 'Gram', 0.13, 12, null, null),
('4109eb21-a2af-42d2-b4cd-505ddb884418', 'fcfac89e-c20b-44d5-a249-16ad72367953', '4f99710b-bddb-42fb-88df-2ae0fa9a405b', 'material', 4, 'Gram', null, 13, null, null),
('f219cf9b-c0b8-4900-a0ad-6b69ff5e86eb', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', '89f993fc-eb2b-432e-b271-8ae9fbcce03c', 'material', 2, 'Piece', null, 0, null, null),
('376e876f-07d5-4894-8679-a7182b6b4252', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'c9cd3ec0-4f09-4ab7-86e8-6b9e56b5c5f9', 'material', 2, 'Piece', null, 1, null, null),
('9519540f-7205-405a-b56a-36cf2190a42a', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', '19904f73-02a8-4b42-a00e-d0a6e2ce70f8', 'material', 2, 'Piece', null, 2, null, null),
('b690817c-35c2-4884-bfc8-9281d9111b44', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'e5e405ce-c962-4f49-9f80-16735fb45e77', 'material', 2, 'Piece', null, 3, null, null),
('47c96fc2-4f88-46f3-82e4-14224fdfd946', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'e122c73d-671e-46c0-8939-94c228ea92e0', 'material', 2, 'Piece', null, 4, null, null),
('fa396be1-73ea-4d9f-b0d1-ed2ac96f535e', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', '8f83bdc1-edf6-4c7c-bd7d-ca2f77ed44ba', 'material', 30, 'Gram', null, 5, null, null),
('cc8f21be-522d-437f-abb5-cdd76c5af2a1', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'cc076be6-96cc-425c-bd32-8957acc75cd2', 'material', 25, 'Gram', null, 6, null, null),
('a2f3e3e4-a093-4e37-9f5a-e6e25b54e819', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', '38b863e8-460e-47ca-bd1d-f47e8388776f', 'material', 15, 'Gram', null, 7, null, null),
('37b62e27-64a2-49d8-bef0-c467c7a668e6', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', '90b6e6b4-1c72-4524-8c63-23c4489fdfbb', 'material', 25, 'Gram', null, 8, null, null),
('cdad05b5-af67-4eda-b718-5b1fb373d088', '7fcb9073-7ab7-4028-992b-e8dfcb2660c4', 'bcfe6fe1-0f12-460d-a447-4787009f46a9', 'material', 30, 'Gram', null, 9, null, null),
('6435efdb-82c8-4fba-99e2-f62058f329f2', 'c5164180-a806-4568-b614-66600cb1d277', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('bcbca943-cacd-4e1f-8bcc-b5ec3e52e127', 'c5164180-a806-4568-b614-66600cb1d277', '3ad60234-4c86-4bfd-95ce-813fa3a726e0', 'material', 1.4, 'Gram', null, 1, null, null),
('85980310-3355-4fbc-92a7-010eddbd6de8', 'c5164180-a806-4568-b614-66600cb1d277', '12ebba3a-839d-4c97-915e-9b8476dfefd4', 'material', 5, 'Gram', 1.67, 2, null, null),
('1de551e3-1369-4d6e-afb1-3bdc48a4f34d', 'c5164180-a806-4568-b614-66600cb1d277', '6a789cff-27ad-418c-ad9c-c5ec861d5806', 'material', 5, 'Gram', 1, 3, null, null),
('a28d6ea5-dd16-49f9-a79a-c5cffdc569f4', 'c5164180-a806-4568-b614-66600cb1d277', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 25, 'Gram', 22.1, 4, null, null),
('9fc0dc92-6556-424a-8694-adb757fd9fb6', 'c5164180-a806-4568-b614-66600cb1d277', 'adb6f417-d969-44a6-8636-f23ef32022a7', 'material', 20, 'Gram', 6, 5, null, null),
('ffeefa23-9469-4dc9-9a0e-479bd34b25d9', 'c5164180-a806-4568-b614-66600cb1d277', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 30, 'Gram', null, 6, null, null),
('0870b968-1599-4e73-b4e6-87a142f4fe3e', 'c5164180-a806-4568-b614-66600cb1d277', 'd5121502-2050-413a-9617-434132b47ee7', 'material', 180, 'Gram', null, 7, null, null),
('9325372b-f52f-470f-b8a7-d3da35a9110c', 'c5164180-a806-4568-b614-66600cb1d277', '9a4754ba-aaa8-4b87-b051-4354d340d168', 'material', 30, 'Gram', 9, 8, null, null),
('bf091aac-f0ec-457b-bd3c-635aa781bb48', 'c5164180-a806-4568-b614-66600cb1d277', '07788156-8656-4969-8920-c185d921817b', 'material', 10, 'Gram', null, 9, null, null),
('abf1f869-0902-4297-bf02-9644488f9dfc', 'c5164180-a806-4568-b614-66600cb1d277', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 5, 'Gram', null, 10, null, null),
('bec0dcf5-8904-4b44-8a8e-42dca939b5d9', 'c5164180-a806-4568-b614-66600cb1d277', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 20, 'Gram', 5.33, 11, null, null),
('1a2806ba-bbae-42ba-9dda-4b3280b2a410', 'c5164180-a806-4568-b614-66600cb1d277', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 3, 'Gram', 3, 12, null, null),
('0c397593-2b11-47bc-9216-c68622dc8b01', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('558a55f4-67c7-4cc9-bdcf-af648209f6d3', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '8cd147d9-20d8-4fda-926d-dc6edfc6136c', 'material', 1.4, 'Gram', null, 1, null, null),
('59726728-904c-4bda-ace0-ebc62cd163be', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '12ebba3a-839d-4c97-915e-9b8476dfefd4', 'material', 4, 'Gram', 1.33, 2, null, null),
('34a76eff-2676-4d41-a1d1-dd9519dfcaf2', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '6a789cff-27ad-418c-ad9c-c5ec861d5806', 'material', 4, 'Gram', 0.8, 3, null, null),
('06906be8-327d-49d8-9374-d1fe6a951c20', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 25, 'Gram', 22.1, 4, null, null),
('5b3bccc6-a02c-425c-bee9-628186484d5a', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', 'e75a21d8-711c-4343-b2fe-1587a5c6df45', 'material', 9, 'Gram', 2.22, 5, null, null),
('782bad1f-8c63-410e-808f-cad6110fa9bc', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 8, 'Gram', 1.2, 6, null, null),
('57684e46-7973-46d9-ba27-94a7bc713941', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '5c8edb7b-0879-4b8b-bed6-1c14d21c229e', 'material', 25, 'Gram', null, 7, null, null),
('64604944-795b-45b4-815c-1b2d42cd2228', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', 'ea4f4990-f636-4777-bfb0-c061ad72f31a', 'material', 15, 'Gram', 5, 8, null, null),
('5d19cad9-3d8a-4064-b9fa-add320423181', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '670e035b-4019-4cfd-8210-f4c1cc0379fb', 'material', 4, 'Gram', null, 9, null, null),
('d1257201-1b20-4ef2-9c39-251e9937dbbc', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 5, 'Gram', null, 10, null, null),
('1978bc4f-403e-437d-bedf-8156e963abf8', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 20, 'Gram', 5.33, 11, null, null),
('6612e057-f422-483d-86d9-e33a1d653156', '44c65850-1aed-4743-84b2-c2cdf7ca20a0', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 3, 'Gram', 3, 12, null, null),
('fd0db9c0-d8cf-463e-ac2b-a2661c391251', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('b3aeb3b8-c9f3-4521-a447-b72790066d12', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '2198806f-1831-4d58-9df2-1ef1c9b73fe8', 'material', 1.4, 'Gram', null, 1, null, null),
('61ee2d09-1b83-42bf-8f6c-2bf70749e89e', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 20, 'Gram', 17.68, 2, null, null),
('2bde46f6-1116-4f7f-bfcb-f6f90863ad4c', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 6, 'Gram', 0.9, 3, null, null),
('a9d6de16-b2ea-4ab5-8d4e-a672505e38d8', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 15, 'Gram', 0.86, 4, null, null),
('4750b085-bf3c-4792-8fba-02dd75f64588', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'e75a21d8-711c-4343-b2fe-1587a5c6df45', 'material', 30, 'Gram', 7.39, 5, null, null),
('0fa870f6-ec81-4a26-97fa-1ecdef989939', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 15, 'Gram', null, 6, null, null),
('428450af-20f5-45f6-956e-4939d1c44f31', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'fc26eaa2-aa90-4a6b-9f43-c8a966d504ec', 'material', 100, 'Gram', null, 7, null, null),
('487fed13-d9e6-4dae-8426-19df181bdd77', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'ea4f4990-f636-4777-bfb0-c061ad72f31a', 'material', 10, 'Gram', 3.33, 8, null, null),
('37c492e1-f857-4d76-8b68-5d5dd3858a8c', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', 'bb57f928-5678-4a1d-bcd9-a3812921b315', 'material', 5, 'Gram', null, 9, null, null),
('d18a2bcb-596c-4f8a-a22b-4faa82211310', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '1c1692dd-14af-4f24-ad53-1fb93e06326c', 'material', 5, 'Gram', null, 10, null, null),
('d66a76b4-8b92-4dde-b044-8a0eb8d04479', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 20, 'Gram', 5.33, 11, null, null),
('ceba3a2f-ad52-4c22-947d-58039e7fe498', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '3f6a9b3e-c2bc-46ee-be89-8e06756cbef9', 'material', 3, 'Gram', null, 12, null, null),
('b909c1a6-1672-49af-85e1-8aa1bd016e29', '7b1f07da-fe81-4314-8cbc-0f5c69fbc3d1', '777bd5e0-8f00-421c-87c5-263df99a349a', 'material', 2, 'Gram', null, 13, null, null),
('f742209d-e145-4901-80f7-04fa0f482a59', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '5bb521a5-f6ac-4c04-aa69-e293ccb9528e', 'material', 4.2, 'Gram', null, 0, null, null),
('e2b216b3-ee40-405f-a10b-a85c4cd96491', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 160, 'Gram', 40.32, 1, null, null),
('80738aab-16de-44b2-a573-1ba65a52d30e', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', 'fa78d232-fabc-4a83-93a8-c6b424d2016d', 'material', 40, 'Gram', null, 2, null, null),
('9a0fc48a-06ee-4463-ad0d-8bde175e5567', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', 'd78ab968-d996-4e33-9fdf-dbe9df353bfe', 'material', 10, 'Gram', null, 3, null, null),
('bd2e7ed5-86f8-4038-b138-66ea5381830a', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', 'f8d3a160-12ff-4c98-b695-75c983398d72', 'material', 20, 'Gram', null, 4, null, null),
('27a6f340-31d6-4dcf-85b5-c46308da4f8b', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 25, 'Gram', null, 5, null, null),
('4b7af9a3-2454-4aaf-8d4f-7189179404dd', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 25, 'Gram', 1.43, 6, null, null),
('26ce7a5a-7a59-4fea-957b-0c2bd06b7ee3', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '7badac33-4540-431f-a01d-832a9b038a30', 'material', 40, 'Gram', null, 7, null, null),
('4791f124-d6d1-4f40-b278-5c1474f69037', 'a9c5483d-5157-48d0-ba27-6e13d188afe0', '70a094e0-06d3-45c5-b2de-25165e725933', 'material', 1, 'Gram', null, 8, null, null),
('4ea3b4e3-3f40-4a6d-8e1f-adb6d9c7803d', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('c98e9d98-813e-4c9d-9fde-7cd1063204a9', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '3ad60234-4c86-4bfd-95ce-813fa3a726e0', 'material', 1.4, 'Gram', null, 1, null, null),
('f767d1aa-1f82-4927-a518-060fdf1a6201', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 3, 'Gram', 0.45, 2, null, null),
('0047aec5-0abd-48db-aca9-7eac270235be', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 25, 'Gram', 22.1, 3, null, null),
('29466b58-1e86-41fd-924d-83ce3f73b04a', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 10, 'Gram', 0.57, 4, null, null),
('f315d228-e4e6-487d-a37c-36d63fb0656f', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '12da7c5f-cd30-4873-ac6d-e97897fe846e', 'material', 18, 'Gram', null, 5, null, null),
('071f5c77-13e7-4e01-92f3-e8c3687b9dda', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'b986d827-534e-4268-9601-0b732c63ada6', 'material', 15, 'Gram', null, 6, null, null),
('fa36ae40-64f9-48d3-916f-0acaaed090bf', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 1, 'Gram', 0.13, 7, null, null),
('ce74420e-087b-4761-8f95-4f376ee24e1f', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'ba7ed567-0a69-4591-bbcf-a7a2dd07d617', 'material', 5, 'Gram', 1.25, 8, null, null),
('eca7788d-6b0b-4b4a-ad18-3645b807a391', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '57c4751f-b9df-4333-87ac-d17dd523cc39', 'material', 15, 'Gram', null, 9, null, null),
('5dbd735b-6b6f-4e43-954f-54be714b3043', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'f8ff47a6-a453-41b7-87ad-3ee6a80c991d', 'material', 35, 'Gram', null, 10, null, null),
('9c4e840c-9fce-4bdc-b388-a00623a01e9c', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '534e7cba-86ea-4ab6-afeb-2b7b38ebc24e', 'material', 11, 'Gram', null, 11, null, null),
('a1e07c3e-f4a9-48dc-bea4-2e4047da9a23', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '9a4754ba-aaa8-4b87-b051-4354d340d168', 'material', 7, 'Gram', 2.1, 12, null, null),
('7b860b64-9c0b-4222-9179-501347ef4b4b', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'f1be34ea-1e14-4311-b366-3e1a1d500dbe', 'material', 8, 'Gram', null, 13, null, null),
('ed3ed755-33ea-4155-89d4-1b47257c042e', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 20, 'Gram', 5.33, 14, null, null),
('a4783bb6-9b4d-48e0-8a49-8e1656a7d271', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 5, 'Gram', null, 15, null, null),
('3bf21239-879b-49ef-ab8f-4970d8bcdf2d', 'b3e34399-81ac-4d92-865c-6f3a74d487c3', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 2, 'Gram', 2, 16, null, null),
('12759df4-073b-4a7d-a4fb-976cb55e570e', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('9b8d17cf-fdf6-4e1f-a540-b19a1453b8ab', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '3ad60234-4c86-4bfd-95ce-813fa3a726e0', 'material', 1.4, 'Gram', null, 1, null, null),
('1c04e36a-424b-4f8f-b7f9-80c62179f207', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'ba7ed567-0a69-4591-bbcf-a7a2dd07d617', 'material', 20, 'Gram', 5, 2, null, null),
('3c282daa-75a3-4667-b371-7a972500a780', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 25, 'Gram', 22.1, 3, null, null),
('f6aa8e32-c395-4220-b7b1-a522972393e5', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '12ebba3a-839d-4c97-915e-9b8476dfefd4', 'material', 4, 'Gram', 1.33, 4, null, null),
('90151076-cac7-4a33-846b-dcbebb9caeb5', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '931f6000-6905-4b19-9b94-cf67073ea8ab', 'material', 6, 'Gram', 0.9, 5, null, null),
('2c695a19-04ca-4012-b5db-df4eefb3b685', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '9a4754ba-aaa8-4b87-b051-4354d340d168', 'material', 8, 'Gram', 2.4, 6, null, null),
('cdc94730-675d-4ab6-b052-e8ef3f16ecd5', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'f1be34ea-1e14-4311-b366-3e1a1d500dbe', 'material', 8, 'Gram', null, 7, null, null),
('4ed3253b-7f95-4996-8ba7-0a1de28f5d3b', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 3, 'Gram', 0.39, 8, null, null),
('c386ab06-acb1-4ab4-8643-635f3e17e9bc', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'ded11b5b-7305-4a55-ab95-7056073001b1', 'material', 10, 'Gram', null, 9, null, null),
('6fe8c514-c0e6-4dc0-a7b0-b961d85ccd92', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 6, 'Gram', 0.9, 10, null, null),
('e8ca7479-a516-4e90-80c9-cbb63f1bb5ba', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '6a1166e3-d1f5-452a-989a-e961806033cb', 'material', 15, 'Gram', null, 11, null, null),
('ef38afc8-ca49-43a3-be14-a721c1e5dbc0', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 20, 'Gram', 5.33, 12, null, null),
('c797a8bb-6a7f-4de1-8dee-13af097e416b', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 5, 'Gram', null, 13, null, null),
('b3cb4449-b4b8-4ae2-9d36-9aac88705418', '0dac6c6f-03b5-40d4-a87f-e2b64c8db1e6', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 3, 'Gram', 3, 14, null, null),
('15c1b4bc-f884-4f09-8b77-e4eb1e5fc124', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '48aafe16-9f95-4b8f-9fea-23060240961c', 'material', 130, 'Gram', 32.76, 0, null, null),
('0df52b21-f731-4f67-867e-ce5973b9ec2c', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '3ad60234-4c86-4bfd-95ce-813fa3a726e0', 'material', 2.8, 'Gram', null, 1, null, null),
('e4021f61-0c9f-4c52-ab2d-8b64e573e192', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '87606b57-2098-40cd-9d6c-2b6fb4c94b97', 'material', 25, 'Gram', null, 2, null, null),
('4060c77c-b2bd-4c01-94c9-c5ce488533d3', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', 'a7d52465-1329-483a-983f-011630e71edb', 'material', 25, 'Gram', 30, 3, null, null),
('9f6006f4-1fe6-44ee-ae8e-fe50e719c6f7', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '4b35f34a-586c-47a3-8021-37b5211336e8', 'material', 50, 'Gram', 44.2, 4, null, null),
('2bd0f8c8-3704-4f21-9970-13c11d74e323', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 15, 'Gram', 2.25, 5, null, null),
('44dc6dd3-c352-41b2-80b4-cb73a0980b94', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', 'f617de21-cbb8-4d52-b120-df4f71ea2028', 'material', 40, 'Gram', null, 6, null, null),
('ba4b35a0-f9b2-4a25-a0a4-2fff88bcf33e', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '5e9812b2-4706-4630-9102-7f957868f352', 'material', 50, 'Gram', null, 7, null, null),
('fb3173cd-1594-43bb-9698-e33bd0997810', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '5abd482b-e0a2-4a3f-b5c4-458ca3743894', 'material', 30, 'Gram', 8, 8, null, null),
('b3095709-d3eb-45ef-95d4-b4a3b7881001', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', 'd28f1f44-4cbe-4dbf-83e3-53b68aeb3a68', 'material', 20, 'Gram', null, 9, null, null),
('c10b22d9-ccbb-428a-8545-f42b55901861', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', '0351ff8a-9b95-4672-971b-dc3480ea9031', 'material', 2, 'Gram', 2, 10, null, null),
('0cceee9c-4b0d-41cc-b046-b1dc743f91ce', 'd788cae5-9dde-4258-8021-ab14e8cec0aa', 'f1be34ea-1e14-4311-b366-3e1a1d500dbe', 'material', 10, 'Gram', null, 11, null, null),
('885d5fd6-3df2-4f30-a944-a3e3dbde4f80', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 15, 'ML', 2.14, 0, null, null),
('50056cfb-8bf6-4b37-b303-51432cca8e00', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '418d5e64-e609-4142-a2a4-9a9a5dfbadf8', 'material', 5, 'Gram', null, 1, null, null),
('c2585c54-340c-4aa6-9b53-fc7354d829be', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 25, 'Gram', 1.43, 2, null, null),
('2aae1694-654c-4245-8a68-b4a94d714cbc', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '8f974b42-40db-44cb-9fe8-6bc2e051e37a', 'material', 20, 'Gram', 1.8, 3, null, null),
('2a46c0ce-8555-4d9a-bada-4a8db9918409', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '780e37ae-3109-41e6-ae35-4e21d8f6135a', 'material', 20, 'Gram', null, 4, null, null),
('8a0e62b8-d400-4a3b-8eca-ff8ac5df9c45', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '9484e03b-38d5-41f5-9535-8272502acc63', 'material', 300, 'Gram', null, 5, null, null),
('2d6a5393-383e-4973-84d5-79c467112a57', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 3, 'Gram', 0.94, 6, null, null),
('315e9a90-1e1f-440d-bb8c-e2b8402e4c3e', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 7, null, null),
('c429b6f6-421f-41ab-86e4-9490b4350afb', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('b98f78b4-5b03-4b14-9a3d-c3dc7faeeda1', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('30d63a84-67e9-472b-8db5-debd7bd7339a', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', 'fa611188-3f80-4a4c-838e-4c15435261b7', 'material', 5, 'ML', null, 10, null, null),
('ae71fc01-f037-48c9-ae5e-003f26c77a8d', 'ed0911d1-82d7-476c-b26c-7a46fe1d0af0', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 4, 'Gram', 0.6, 11, null, null),
('abb053d1-ed5c-49e9-aa23-1c0a8c487a18', 'aad47994-eaa3-4dc0-9076-8b25573f2039', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 22, 'ML', 3.14, 0, null, null),
('74e1ab54-f5e4-44e7-8ee4-1786fc43c422', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '5ce2fa98-cbc1-407e-a069-aec8ef45b5e3', 'material', 16, 'Gram', null, 1, null, null),
('d64588df-1091-4208-9070-1bf3012940eb', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '9388779f-cba6-46e2-bbc6-76480461ac9a', 'material', 30, 'Gram', 10.92, 2, null, null),
('f2a89f57-adec-4571-a70d-09600a3a3cdd', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '2c174958-6e67-49c0-a3e7-7116034d5ef3', 'material', 30, 'Gram', null, 3, null, null),
('24b3253e-37b0-4505-a7b3-b007b9544cf7', 'aad47994-eaa3-4dc0-9076-8b25573f2039', 'dcf6c00b-28d0-4d8a-8652-9c917c4fa8dc', 'material', 30, 'Gram', 3.43, 4, null, null),
('42f6d4d9-bc6d-4cc5-a573-1939a5e1e4d2', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '9484e03b-38d5-41f5-9535-8272502acc63', 'material', 300, 'Gram', null, 5, null, null),
('49d1fb99-05e2-4791-b140-4ad700b0f2aa', 'aad47994-eaa3-4dc0-9076-8b25573f2039', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 3, 'Gram', 0.94, 6, null, null),
('5953268f-007a-47aa-b2ac-bc6c9dd9b41b', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 7, null, null),
('fe61ebe9-6ee4-4af0-bdba-e5c6123a6a20', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('5e4eb958-12e5-465f-8675-593fccf37cec', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('e4bab00c-ab9c-4f15-9712-506c50da8ea6', 'aad47994-eaa3-4dc0-9076-8b25573f2039', '3d89d37b-16a9-498c-acf8-69b79ca73984', 'material', 8, 'Gram', 1.6, 10, null, null),
('4339b94b-7147-4278-9e36-93d6e5c2e54d', 'aad47994-eaa3-4dc0-9076-8b25573f2039', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 4, 'Gram', 0.6, 11, null, null),
('65612f71-d25e-49b3-82ef-bf81f0818b5b', '7973f3c7-3640-4d9d-ada9-12307928700e', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 15, 'ML', 2.14, 0, null, null),
('d316af7f-6817-4f2e-82a0-5df2fe960e63', '7973f3c7-3640-4d9d-ada9-12307928700e', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 15, 'Gram', 4.5, 1, null, null),
('56fc4870-2f53-47bc-951a-cc64a4bb7559', '7973f3c7-3640-4d9d-ada9-12307928700e', '3d5def55-aacc-4cb8-a79e-f1a384e04b08', 'material', 60, 'Gram', 4.28, 2, null, null),
('6b32ce45-e7d3-4ad9-91b9-dc4bd3178cec', '7973f3c7-3640-4d9d-ada9-12307928700e', 'dba5805b-c885-4ac4-ab16-1c7d285b7b4a', 'material', 2.5, 'Gram', null, 3, null, null),
('4503fcdd-f7fd-41f3-bbc2-6c8fd524c41d', '7973f3c7-3640-4d9d-ada9-12307928700e', '49a0ca7e-9a9b-44b8-af54-542d80ba133e', 'material', 5, 'Gram', 1.4, 4, null, null),
('ef1bbbde-086b-4d98-816e-1521293f1a39', '7973f3c7-3640-4d9d-ada9-12307928700e', 'b33f2d66-4b5d-4d00-af71-77bd1b4d2b2f', 'material', 2.5, 'Gram', 0.5, 5, null, null),
('10ba8398-d9fa-4c55-91cb-b79a846022f1', '7973f3c7-3640-4d9d-ada9-12307928700e', '9484e03b-38d5-41f5-9535-8272502acc63', 'material', 300, 'Gram', null, 6, null, null),
('c5dafe51-4c0d-4a1d-84db-30711f23d9e5', '7973f3c7-3640-4d9d-ada9-12307928700e', '780e37ae-3109-41e6-ae35-4e21d8f6135a', 'material', 20, 'Gram', null, 7, null, null),
('21c1b034-fa2a-40c7-aa88-885416febaed', '7973f3c7-3640-4d9d-ada9-12307928700e', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('d9341ee3-5b18-46c9-ad02-4a28467cfc78', '7973f3c7-3640-4d9d-ada9-12307928700e', 'd5479ed6-5a44-401b-8252-e75b64ff1b47', 'material', 5, 'Gram', 83.35, 9, null, null),
('5a7a3a29-54f2-406d-aa10-9df9247467c8', '7973f3c7-3640-4d9d-ada9-12307928700e', '9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'material', 2.5, 'ML', 13.39, 10, null, null),
('53d4b74e-10fc-4ee5-9641-461a4637e392', '7f67a802-366a-40d0-9993-ae5ca33e1d14', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 22, 'ML', 3.14, 0, null, null),
('5093db97-331f-497e-bece-3efa02256201', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '04e9e7e1-b433-4075-a27f-b417de030164', 'material', 5, 'Gram', null, 1, null, null),
('33cfbd9f-2cbb-49ff-a0bf-8d77fb1bcbd7', '7f67a802-366a-40d0-9993-ae5ca33e1d14', 'f21524c8-2445-4eef-89d6-c8c0612448a5', 'material', 30, 'Gram', 2.62, 2, null, null),
('8bed5c0a-d1f8-420d-a730-88e3b3939c55', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 30, 'Gram', 1.71, 3, null, null),
('9d68d356-b7fb-4be7-a216-f69ab0f24bc8', '7f67a802-366a-40d0-9993-ae5ca33e1d14', 'fc89bee0-9a6c-440d-8a1d-37ce672959f1', 'material', 30, 'Gram', 3, 4, null, null),
('df1521e1-65f5-4205-a316-a4ade476611a', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '4a2395f6-cf27-49dd-a664-f213fed54595', 'material', 140, 'Gram', null, 5, null, null),
('a167ee8b-e72f-41da-9c68-41fea0df156e', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '45de3168-5baa-4e9d-94ce-febf08572375', 'material', 30, 'Gram', null, 6, null, null),
('1cb86856-39cb-4531-b309-95ba0bd6f9bd', '7f67a802-366a-40d0-9993-ae5ca33e1d14', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 3, 'Gram', 0.94, 7, null, null),
('49422996-5437-476f-a4fd-b63fc4fb30b1', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 8, null, null),
('1dbc255b-2e62-4e6c-9101-f5964e3f277a', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 0.5, 'Gram', 0.5, 9, null, null),
('acaebb35-fc38-4fc9-ae0c-c7ce9f23d558', '7f67a802-366a-40d0-9993-ae5ca33e1d14', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 0.8, 'Gram', 0.27, 10, null, null),
('92470429-b309-4607-a249-7b0afc8c4c1b', '7f67a802-366a-40d0-9993-ae5ca33e1d14', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 4, 'Gram', 0.6, 11, null, null),
('cfa35e91-c1a6-4efb-ad01-d368c49fb2cc', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 22, 'ML', 3.14, 0, null, null),
('9fd5e1cb-8bc3-4aa3-90d5-617bb81d04f2', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 1, null, null),
('1a548faf-0c91-4c44-95f3-a5fbc8f49b4d', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 4, 'Gram', null, 2, null, null),
('61f74476-0fda-47af-be16-6b49c13d7be9', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', 'a763c479-554f-4578-bf15-35df015c7b85', 'material', 60, 'Gram', null, 3, null, null),
('d9a6702c-1cd9-4fc7-91c3-eae61e3cc0ce', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', '5b7dc007-1731-4d0a-9ee3-a6e2a1057101', 'material', 10, 'Gram', null, 4, null, null),
('fcfc50be-69d3-455e-b48c-0a47bacfc9bd', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', '5645f8be-165e-41ad-96d6-41379607f029', 'material', 120, 'Gram', null, 5, null, null),
('8282bec8-bf5a-4889-af8f-df061bdb8003', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', '66d2bc8a-fbe2-49fc-94b3-adce6067a9a5', 'material', 30, 'Gram', null, 6, null, null),
('8f2bd9e6-cf47-46c7-991a-ebcc64af0044', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', '3206e52e-9d0f-4b1b-9215-df88f08b8e22', 'material', 30, 'Gram', null, 7, null, null),
('89f4f744-d965-49e4-ab14-6dd0da05fbba', 'db739d48-8c61-41d8-88fa-8a9cb9cde4c2', 'c66b794f-f329-450b-9c0d-8ef8fd805f5b', 'material', 5, 'Gram', null, 8, null, null),
('27a25791-4db1-424d-ba32-3a0e2b068eb3', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'b5026ed0-ee14-4a0d-ab38-60c776be4629', 'material', 22, 'ML', 3.14, 0, null, null),
('5354b1d5-5818-4d4b-aeb4-34352eeff2e0', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', '04e9e7e1-b433-4075-a27f-b417de030164', 'material', 5, 'Gram', null, 1, null, null),
('534e0a0f-caa2-494f-90c1-afbfde9561ed', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'ceab6ead-9791-44dc-a913-a53cac5c9973', 'material', 60, 'Gram', null, 2, null, null),
('57849b25-c0fa-49f4-a6bd-841ea6ecb8ad', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', '5dcbadc3-8763-417f-a614-4b8976122cc9', 'material', 30, 'Gram', 1.71, 3, null, null),
('fdc6c5a2-162d-4a29-a896-75c6ba235a5f', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'b95e576a-e4a1-4a9d-ae5f-623c983322a0', 'material', 150, 'Gram', null, 4, null, null),
('507d87da-7592-452c-8eef-028b7d646502', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'f6f9dbc1-8725-4881-8e5e-dda56c906946', 'material', 40, 'Gram', null, 5, null, null),
('e26ed013-2b3f-476a-a191-77212e553a6d', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', '3206e52e-9d0f-4b1b-9215-df88f08b8e22', 'material', 30, 'Gram', null, 6, null, null),
('29bb44ab-f77a-427b-8eb4-bcb1213e4ada', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 10, 'Gram', 1.5, 7, null, null),
('b7b2a756-48b6-4842-9765-d4fe04e5b585', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'd4d84300-0ef6-438c-9237-696d62dcea60', 'material', 15, 'Gram', null, 8, null, null),
('0e1dbfe1-5a49-425e-9ab2-3c3542528ba0', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 5, 'Gram', 0.66, 9, null, null),
('30ee73f1-1fb1-4fa7-80a3-5513200010d1', '0ca5e4ea-c0f7-48e8-8385-f966a48aa13f', 'a73e39fa-9cb4-4555-bdb3-52474884d362', 'material', 1, 'Piece', null, 10, null, null),
('31e28ef6-8f6f-4574-9fdd-244231d61b45', '2076b69b-e118-4a9e-89e1-9d977236100e', '055655ce-fc47-4e9d-b1c5-161ee390baaf', 'material', 90, 'Gram', null, 0, null, null),
('461c9557-f14e-4929-9426-9fbff5b5bd80', '2076b69b-e118-4a9e-89e1-9d977236100e', 'd5978f51-3455-4a7c-a496-001f70c835db', 'material', 120, 'Gram', null, 1, null, null),
('c54e55c9-3ed0-49f9-b35f-ef3c9fabe68e', '2076b69b-e118-4a9e-89e1-9d977236100e', 'f5f20538-d1d6-43d0-923b-b10faea8adbb', 'material', 40, 'Gram', null, 2, null, null),
('74eb6444-104f-4672-b8e4-72dd8316e58e', '2076b69b-e118-4a9e-89e1-9d977236100e', '72e3f5e9-d3a4-4ae8-b1a6-cc4b5cfc17dd', 'material', 30, 'Gram', null, 3, null, null),
('8ae1d784-fad1-4ff9-b96e-649876553a67', '2076b69b-e118-4a9e-89e1-9d977236100e', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 1, 'Gram', null, 4, null, null),
('39b25da1-4410-4e09-a1a4-17e4c4ca3248', '2076b69b-e118-4a9e-89e1-9d977236100e', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 5, null, null),
('d49c1695-a949-44db-bea9-6d24a50c15dd', '2076b69b-e118-4a9e-89e1-9d977236100e', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 2, 'Gram', 0.67, 6, null, null),
('380caba9-64ca-4fd2-8a34-53f77a54d43a', '2076b69b-e118-4a9e-89e1-9d977236100e', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 2, 'Gram', 2, 7, null, null),
('b5eee0c2-ce39-41ed-8707-72d664aec0be', '2076b69b-e118-4a9e-89e1-9d977236100e', '6a789cff-27ad-418c-ad9c-c5ec861d5806', 'material', 7, 'Gram', 1.4, 8, null, null),
('d3d002bf-6b9d-4a09-a253-3536af9fb2a9', '2076b69b-e118-4a9e-89e1-9d977236100e', '8f974b42-40db-44cb-9fe8-6bc2e051e37a', 'material', 20, 'Gram', 1.8, 9, null, null),
('2c498bdc-9504-4c29-aa09-7afe9466f0bc', '2076b69b-e118-4a9e-89e1-9d977236100e', 'f21524c8-2445-4eef-89d6-c8c0612448a5', 'material', 20, 'Gram', 1.74, 10, null, null),
('8f4c5a43-6356-4d45-b8aa-d58d90a623bb', '2076b69b-e118-4a9e-89e1-9d977236100e', '3206e52e-9d0f-4b1b-9215-df88f08b8e22', 'material', 10, 'Gram', null, 11, null, null),
('edc9a512-4819-4d20-9cbd-a6f9686a326a', '2076b69b-e118-4a9e-89e1-9d977236100e', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 15, 'Gram', 2.25, 12, null, null),
('5992ec78-7b3d-4582-9dcf-7f79d4f5ec19', '2076b69b-e118-4a9e-89e1-9d977236100e', 'f11f64cf-9f8d-44aa-82e4-069be23527ea', 'material', 2, 'Gram', null, 13, null, null),
('eedfcf0e-cff7-4bad-a9e4-cb7f7a069b69', 'e5dd7684-0776-43f0-8296-69a136cec157', '8a5f9308-fb2e-4d66-acb5-96d8ee8bd0d7', 'material', 20, 'Gram', 2.09, 0, null, null),
('5abb37d8-2711-4466-8529-f2cb2d08e552', 'e5dd7684-0776-43f0-8296-69a136cec157', '5a60fa30-60d9-485b-bad2-7163715ed47f', 'material', 10, 'Gram', null, 1, null, null),
('f9540276-6799-4666-a3b2-26b41596f1e4', 'e5dd7684-0776-43f0-8296-69a136cec157', 'f123e77f-2faf-4fd6-bda9-237aa2e2a01e', 'material', 10, 'Gram', 1.8, 2, null, null),
('02352d19-e68c-48d9-86e4-d9a363f708b7', 'e5dd7684-0776-43f0-8296-69a136cec157', '1f43db50-945b-4c76-8ad7-fd3c74192d5a', 'material', 20, 'Gram', 12.96, 3, null, null),
('f26b30c3-ac63-4ea6-a972-6a8181446c07', 'e5dd7684-0776-43f0-8296-69a136cec157', '80e5cae5-b7e7-4c35-bcf1-3d74a1944860', 'material', 5, 'Gram', 4.49, 4, null, null),
('0c0d947a-1df1-41e5-8b06-2e047490a0c1', 'e5dd7684-0776-43f0-8296-69a136cec157', '0fc70bff-f586-48ec-be9d-30c5c10c1d7b', 'material', 40, 'Gram', null, 5, null, null),
('246ccb60-145b-4c3f-a342-15a4179f3821', 'e5dd7684-0776-43f0-8296-69a136cec157', 'dc534384-41b3-4197-be88-8a72d43b89c3', 'material', 40, 'Gram', 16, 6, null, null),
('9c98142f-38ea-43b5-803f-121fb62815be', 'e5dd7684-0776-43f0-8296-69a136cec157', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 350, 'Gram', 0, 7, null, null),
('8bab201a-4ae6-46ba-87ca-8dcd4f6ce499', 'e5dd7684-0776-43f0-8296-69a136cec157', '6033b94a-1c1b-4bd1-addf-0dd62b63f859', 'material', 90, 'Gram', null, 8, null, null),
('77476846-25fc-4b5a-9955-590814af17bb', 'e5dd7684-0776-43f0-8296-69a136cec157', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 5, 'Gram', 1.56, 9, null, null),
('2be916b3-438a-4307-8fa6-149e1e0520a3', 'e5dd7684-0776-43f0-8296-69a136cec157', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 3, 'Gram', 1, 10, null, null),
('371b10a0-ce6e-41a7-981d-611f41cf54d6', 'e5dd7684-0776-43f0-8296-69a136cec157', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('38f3c05c-560c-4091-82c6-cd254fd2e2f7', 'e5dd7684-0776-43f0-8296-69a136cec157', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 12, null, null),
('4905e804-b0da-4bdd-9d66-69f8704edac1', 'e5dd7684-0776-43f0-8296-69a136cec157', '502356ac-c62f-4aec-9091-4d3f3ed1de1d', 'material', 10, 'Gram', 1.01, 13, null, null),
('03d9e31a-a9b6-4aa6-82c6-79d48f79e64d', 'b252581e-3d7c-4c40-9a50-15f334813c47', '8a5f9308-fb2e-4d66-acb5-96d8ee8bd0d7', 'material', 20, 'Gram', 2.09, 0, null, null),
('c009bda7-eda6-496e-9017-ee5f9ddcc4a8', 'b252581e-3d7c-4c40-9a50-15f334813c47', '5a60fa30-60d9-485b-bad2-7163715ed47f', 'material', 10, 'Gram', null, 1, null, null),
('c2bf4498-a4d5-4fbf-89d7-386f49620487', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'f123e77f-2faf-4fd6-bda9-237aa2e2a01e', 'material', 10, 'Gram', 1.8, 2, null, null),
('4cf865c5-3e90-41f2-aff6-348e5c5e3aab', 'b252581e-3d7c-4c40-9a50-15f334813c47', '1f43db50-945b-4c76-8ad7-fd3c74192d5a', 'material', 20, 'Gram', 12.96, 3, null, null),
('ecb53ca1-ffae-4a42-a73c-26a39b60aa8e', 'b252581e-3d7c-4c40-9a50-15f334813c47', '0fc70bff-f586-48ec-be9d-30c5c10c1d7b', 'material', 40, 'Gram', null, 4, null, null),
('fa5e2a7b-8f8c-466d-9cbc-ae901142ad2f', 'b252581e-3d7c-4c40-9a50-15f334813c47', '431266c8-7e2b-404b-8664-2a1622b3fc36', 'material', 5, 'Gram', 5.33, 5, null, null),
('0f31c627-b35c-4156-91b8-4b0a20cbe15f', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'ef6ca919-87f8-4d31-a63d-7e3a9f186a45', 'material', 350, 'Gram', 0, 6, null, null),
('851b0985-258c-4fc4-8c56-182053032099', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'dc534384-41b3-4197-be88-8a72d43b89c3', 'material', 40, 'Gram', 16, 7, null, null),
('5134b97b-102b-4ce3-b355-ddc3f41d3da8', 'b252581e-3d7c-4c40-9a50-15f334813c47', '6033b94a-1c1b-4bd1-addf-0dd62b63f859', 'material', 90, 'Gram', null, 8, null, null),
('66f16b17-7301-4f55-b41b-a48c5612a13f', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 5, 'Gram', 1.56, 9, null, null),
('326537e5-eabd-4a47-88f9-cf11fb552d1b', 'b252581e-3d7c-4c40-9a50-15f334813c47', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 3, 'Gram', 1, 10, null, null),
('13555f2e-f010-4ed8-8bb0-741c586b2b8f', 'b252581e-3d7c-4c40-9a50-15f334813c47', '341cf0ac-c90d-4966-8038-eb608bec3e9f', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('ab878829-9b8b-416f-9d5d-c89490231229', 'b252581e-3d7c-4c40-9a50-15f334813c47', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 12, null, null),
('5be54e75-dfcb-4922-8a85-9b9272884127', 'b252581e-3d7c-4c40-9a50-15f334813c47', '502356ac-c62f-4aec-9091-4d3f3ed1de1d', 'material', 10, 'Gram', 1.01, 13, null, null),
('5ab64183-98b6-4160-937b-acdfb7cc3ba9', 'b252581e-3d7c-4c40-9a50-15f334813c47', '2f6e4c39-b4f4-4f40-87c7-e683dd40aa66', 'material', 20, 'Gram', null, 14, null, null),
('3c969461-9f43-459d-bb6d-bd09eba24192', 'b252581e-3d7c-4c40-9a50-15f334813c47', '53b8b862-1519-435c-96a2-e43029a153cd', 'material', 6, 'Gram', 1.09, 15, null, null),
('718cd274-c3cc-4108-889e-990c3fa1c519', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'be37bf00-a6fd-4dcc-bc1e-4447d02dc2bb', 'material', 18, 'Gram', null, 16, null, null),
('9b1b7354-fdc0-4487-8a8b-43cee75ee3f1', 'b252581e-3d7c-4c40-9a50-15f334813c47', '36e74cf9-830b-42d8-b410-096ed93625dc', 'material', 30, 'Gram', null, 17, null, null),
('f2950191-4352-490f-8309-66937fa95682', 'b252581e-3d7c-4c40-9a50-15f334813c47', '96d04213-e807-4174-8019-b57c948f72e1', 'material', 10, 'Gram', null, 18, null, null),
('cc4f0b6d-b585-4465-838f-9035f8cfe871', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'ae7ec34b-0aa0-4c21-8338-446ee0245eba', 'material', 2, 'Gram', 0.2, 19, null, null),
('bb40c7f0-cec9-4979-9a9c-841cc14ac4ce', 'b252581e-3d7c-4c40-9a50-15f334813c47', 'ff48c30e-da6b-4b06-a94b-096857fd6493', 'material', 1, 'Piece', null, 20, null, null),
('86ff9c93-a45c-4502-a660-1d523275fafd', 'e0230580-229b-4ab2-955a-fd2865b15f57', '1071302f-6503-4051-aa70-d42561b6cc4b', 'material', 30, 'Gram', 16.14, 0, null, null),
('362bfbb2-139a-4884-b51e-c7551b1db29b', 'e0230580-229b-4ab2-955a-fd2865b15f57', '93b276ce-6505-44cb-b159-48e5f021b91b', 'material', 10, 'Gram', 3, 1, null, null),
('330f2b29-cea2-48da-97f1-322099c9ac52', 'e0230580-229b-4ab2-955a-fd2865b15f57', 'b6e986a1-0b1c-4953-bb2d-0e1180a497b8', 'material', 4, 'Gram', null, 2, null, null),
('8d85839a-7c34-44b5-b57c-4da64ca969ab', 'e0230580-229b-4ab2-955a-fd2865b15f57', '49174b69-852c-4d53-9075-b24ef171d836', 'material', 12, 'Gram', 1.92, 3, null, null),
('6dd97184-762e-4b86-9a59-bf192c85325c', 'e0230580-229b-4ab2-955a-fd2865b15f57', 'f992d39f-68cc-481d-8318-e3bb6113e957', 'material', 3, 'Gram', 0.94, 4, null, null),
('b3454bb3-2611-4d83-a4f0-45bd2103aaea', 'e0230580-229b-4ab2-955a-fd2865b15f57', '2df9f517-45a4-4923-b0e3-154608535cfc', 'material', 2, 'Gram', 0.67, 5, null, null),
('8a6150cb-831a-4e07-b28a-262f643307d0', 'e0230580-229b-4ab2-955a-fd2865b15f57', '3d3fea49-02fb-4822-831a-83cd29a83b40', 'material', 0.8, 'Gram', 0.27, 6, null, null),
('d81847bd-b463-4e3c-8f2d-33cd5c9a20e4', 'e0230580-229b-4ab2-955a-fd2865b15f57', 'a0e8b2ab-d3fc-4693-991b-608458c48b34', 'material', 140, 'Gram', null, 7, null, null),
('9718631e-fcbf-4169-9196-0f90443fe12f', 'e0230580-229b-4ab2-955a-fd2865b15f57', 'f276465a-30d9-41e8-b2d6-b2004e3ab1cf', 'material', 5, 'Gram', null, 8, null, null),
('016f67f9-6959-4ca1-a924-e6170c938753', 'e0230580-229b-4ab2-955a-fd2865b15f57', 'cd7dc05f-cba9-4cb5-a770-b7828f6081ad', 'material', 5, 'Gram', null, 9, null, null),
('8177a090-976d-4377-a3c7-0adf29de6ec7', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('7a3c7047-8983-4e54-b882-644c08e18cec', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', '99a5efb7-2882-4dea-8b89-77d6dbffc5e1', 'material', 150, 'Gram', 35.91, 1, null, null),
('505d09ab-c391-40df-9422-304a2845fc2a', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 50, 'Gram', 3.34, 2, null, null),
('f1abe41c-10d8-41d0-87ac-7d28dd4d441a', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 30, 'Gram', 7.71, 3, null, null),
('2b7ebd14-b1f7-4a0f-9a92-c74305c603a4', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', '586c41d9-9c05-49c0-8234-2ec26c43aaec', 'material', 6, 'Gram', 7.2, 4, null, null),
('9955de05-9ff9-460e-8f79-d7df921d253e', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 5, null, null),
('fd16078a-e149-4fb8-a7f9-43ca27824e21', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', '3d5def55-aacc-4cb8-a79e-f1a384e04b08', 'material', 70, 'Gram', 5, 6, null, null),
('74375371-2442-4207-964f-78322c9d546f', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'ea34363d-cf0a-4540-932f-9a63dc9c2bd4', 'material', 50, 'Gram', 21.25, 7, null, null),
('dba5fe1f-e39a-4bfc-bb20-dd2de489cca6', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'f4102d46-43a3-4c50-83f8-84e7be8f9e2f', 'material', 30, 'Gram', 39, 8, null, null),
('9a597ccf-ff00-4f8b-8e5b-4e9a91f903f9', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 9, null, null),
('50dd19fd-9b85-4798-8172-1e54f62afacb', '6f1ae7ba-1b2f-4722-987e-5b92789bd59c', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 10, 'Gram', 1.5, 10, null, null),
('7ea0c2fb-5e9b-4448-9b65-640f11f56886', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('73d4e0fb-b897-402a-ada4-589a51354970', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', '99a5efb7-2882-4dea-8b89-77d6dbffc5e1', 'material', 80, 'Gram', 19.15, 1, null, null),
('854489d1-96da-46ec-b8e3-fb749bb261a6', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 30, 'Gram', 2, 2, null, null),
('95768b6f-bdc8-4def-ac83-981f474a2f25', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 20, 'Gram', 5.14, 3, null, null),
('db978b70-4ebf-4fe2-9289-82221c1639e4', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', '586c41d9-9c05-49c0-8234-2ec26c43aaec', 'material', 4, 'Gram', 4.8, 4, null, null),
('9b34a6b8-7d5d-452d-b85b-98eee8fcdcb7', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 5, null, null),
('d8ec90f9-5d61-4415-a1b7-c44b813b3a66', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', '3d5def55-aacc-4cb8-a79e-f1a384e04b08', 'material', 50, 'Gram', 3.57, 6, null, null),
('aad97460-1cfa-47f7-8e5a-a7c75cb794a3', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'ea34363d-cf0a-4540-932f-9a63dc9c2bd4', 'material', 20, 'Gram', 8.5, 7, null, null),
('c4247930-c463-46f1-be8a-299909609d7b', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'f4102d46-43a3-4c50-83f8-84e7be8f9e2f', 'material', 20, 'Gram', 26, 8, null, null),
('7e444f13-1076-44dd-a401-67e88e30e10f', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 9, null, null),
('9a3c6368-3df1-4451-8cfc-07b2f424065c', 'c4e48070-3c76-40a1-aa9c-898dd52d50a6', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 8, 'Gram', 1.2, 10, null, null),
('c3787104-60de-4c4e-a57e-c9e5b798057a', '75516606-d2e3-4636-8363-7068ca1e9dcd', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('c8c4325e-ba37-4b78-906f-06d16d11f681', '75516606-d2e3-4636-8363-7068ca1e9dcd', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('647171c4-8ab9-4bea-8ed4-f297e3c71c1d', '75516606-d2e3-4636-8363-7068ca1e9dcd', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('48964f0e-2acd-4c66-9744-23f1e22b63ce', '75516606-d2e3-4636-8363-7068ca1e9dcd', '80e402f5-2ea6-4a1c-8c82-ce83bec08143', 'material', 30, 'Gram', 8.57, 3, null, null),
('7c462c80-ac9f-4730-951b-730706c79660', '75516606-d2e3-4636-8363-7068ca1e9dcd', '802b6e54-61ed-4fe8-8aba-df86214335e3', 'material', 20, 'Gram', 6.25, 4, null, null),
('af2fe37a-f0a8-4894-9bb6-4cc88b29c036', '75516606-d2e3-4636-8363-7068ca1e9dcd', '025bc71a-88b8-468e-ac77-741effa10f18', 'material', 100, 'Gram', 13.44, 5, null, null),
('8500bb0a-522a-41ec-92cf-6cb68411c9d8', '75516606-d2e3-4636-8363-7068ca1e9dcd', 'ecb7ca60-c6c1-4628-84bd-da02c812236f', 'material', 50, 'Gram', 51, 6, null, null),
('b4360eb7-8257-4ebc-9df2-e51729d940bb', '75516606-d2e3-4636-8363-7068ca1e9dcd', '83d7cb01-8d6a-4e92-b997-3fc8bda4ed12', 'material', 50, 'Gram', 6, 7, null, null),
('42593ac1-df0e-41cb-843f-dcb5741a2d36', '75516606-d2e3-4636-8363-7068ca1e9dcd', '0d25c296-38b5-4c04-a1a9-69ff9d91b35c', 'material', 20, 'Gram', 19, 8, null, null),
('bd42a386-ced1-4f66-acff-0dd8b80c5f4f', '75516606-d2e3-4636-8363-7068ca1e9dcd', '031c073f-e923-4450-bfe8-c548514b8e32', 'material', 20, 'Gram', 10, 9, null, null),
('0121e4bb-46a5-42a3-9328-2cb1b124ea17', '75516606-d2e3-4636-8363-7068ca1e9dcd', '931f6000-6905-4b19-9b94-cf67073ea8ab', 'material', 20, 'Gram', 3, 10, null, null),
('77ef7881-cb7c-4080-97bc-29fa31e731ff', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('26d6683b-d40e-495f-86e4-19f4c82fa4d7', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('8a696f4e-752c-4be6-bb5b-69bd09d3dcd1', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('123dee28-ba79-4038-bfd6-0876ce5d00d8', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '80e402f5-2ea6-4a1c-8c82-ce83bec08143', 'material', 20, 'Gram', 5.71, 3, null, null),
('44d198b8-e04d-429e-8606-55a70f7278c0', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '802b6e54-61ed-4fe8-8aba-df86214335e3', 'material', 15, 'Gram', 4.69, 4, null, null),
('9a0fcf71-1297-4d11-9a7a-aed25558c903', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '025bc71a-88b8-468e-ac77-741effa10f18', 'material', 70, 'Gram', 9.41, 5, null, null),
('46028a11-3789-466c-812d-91989a0a260a', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', 'ecb7ca60-c6c1-4628-84bd-da02c812236f', 'material', 30, 'Gram', 30.6, 6, null, null),
('805ab503-7b18-4918-821e-049a2d6d4eac', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '83d7cb01-8d6a-4e92-b997-3fc8bda4ed12', 'material', 25, 'Gram', 3, 7, null, null),
('7d3ff33a-a1d9-4d35-be81-8e88be925dfe', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '0d25c296-38b5-4c04-a1a9-69ff9d91b35c', 'material', 10, 'Gram', 9.5, 8, null, null),
('ec2ac50f-4db6-4c2f-9081-671effe43ad3', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '031c073f-e923-4450-bfe8-c548514b8e32', 'material', 15, 'Gram', 7.5, 9, null, null),
('ae9e8999-396b-49df-a80f-61242176fad7', 'e72a5b1e-4f6b-4d56-b9e0-b24d6b9ad500', '931f6000-6905-4b19-9b94-cf67073ea8ab', 'material', 10, 'Gram', 1.5, 10, null, null),
('a5a272c8-e7dd-4ff3-8b0a-3bd3de8f7e9a', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('5c505592-24c3-40e0-ade7-2d2ee90ea791', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 1, null, null),
('e8a3f1c8-1436-4779-b67e-6974d2392fd0', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 20, 'Gram', 5.6, 2, null, null),
('4b86c937-50fe-46aa-b2ab-dc221c949b4a', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 150, 'Gram', 31, 3, null, null),
('20377047-9f22-4ed4-a7ca-3173ed488489', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', '8f490883-4cb7-4a89-86fa-325b2cf4b551', 'material', 40, 'Gram', 16.34, 4, null, null),
('27f4b8fc-e9cd-40d6-9393-06cfb57aeaca', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 5, null, null),
('21064077-39f8-4015-b67e-23452f658e95', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 6, null, null),
('12fc72e1-8dd6-4ac7-83c1-d75196d5f78c', '0dda86b9-2fc5-46ed-b489-8c3ebe40bcb2', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 25, 'Gram', 4.55, 7, null, null),
('87645a16-46a9-4b4b-9644-300a64692b52', '86c457bb-abf5-41f8-9afc-676a6c82ca71', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('8ce7ff58-aa45-46cc-99bd-a0304ed12bdd', '86c457bb-abf5-41f8-9afc-676a6c82ca71', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 1, null, null),
('67b93f44-b6b0-4470-b8c3-21b1968cd7a1', '86c457bb-abf5-41f8-9afc-676a6c82ca71', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 10, 'Gram', 2.8, 2, null, null),
('367d6fd0-f695-4463-9dfa-f0a104bfa4e1', '86c457bb-abf5-41f8-9afc-676a6c82ca71', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 90, 'Gram', 18.6, 3, null, null),
('9cfd6386-6762-430d-8c4f-71c2f7602b4c', '86c457bb-abf5-41f8-9afc-676a6c82ca71', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 10, 'Gram', 4.08, 4, null, null),
('ff43ed05-a787-49cc-979c-65dd0c181f2e', '86c457bb-abf5-41f8-9afc-676a6c82ca71', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 5, null, null),
('16d31085-3d1e-4f55-8b7e-fb647b619f32', '86c457bb-abf5-41f8-9afc-676a6c82ca71', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 6, null, null),
('67fa0f70-4280-4a60-a749-15feb0eed530', '86c457bb-abf5-41f8-9afc-676a6c82ca71', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 20, 'Gram', 3.64, 7, null, null),
('47294e79-a9cf-4103-b9c6-680b7cdb00d0', '57316417-3958-453c-843e-860dda9979f0', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('3f435585-20f5-481f-9409-6033c8fb13cf', '57316417-3958-453c-843e-860dda9979f0', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('a8163e8e-f0af-4940-9fc7-5318c8ef4806', '57316417-3958-453c-843e-860dda9979f0', '0adb493e-afb9-4462-9a0a-01a6f4c38304', 'material', 5, 'Gram', 1.88, 2, null, null),
('709f1bda-efca-4c60-a5df-a3aebb826896', '57316417-3958-453c-843e-860dda9979f0', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 5, 'Gram', 5.25, 3, null, null),
('ea6499e2-615b-4da4-994c-401d9caa0e27', '57316417-3958-453c-843e-860dda9979f0', 'e8f321ec-6a03-4c02-a48b-a2b805f6c3d1', 'material', 130, 'Gram', 115.38, 4, null, null),
('abd21b16-a9b3-4a5a-b5ff-a99e935c130e', '57316417-3958-453c-843e-860dda9979f0', '57d7a57e-56ce-440f-80d9-f157e24c377e', 'material', 10, 'Gram', 4, 5, null, null),
('20123e93-7e78-4c84-9cfb-80616425393b', '57316417-3958-453c-843e-860dda9979f0', '14db6a39-d0d7-417a-9a0e-068f9326e300', 'material', 5, 'Gram', 1, 6, null, null),
('0e55c958-d1d5-4f12-8c11-55c75762462a', '57316417-3958-453c-843e-860dda9979f0', '912879dd-6874-4db1-8a0f-eaf3981d82dc', 'material', 5, 'Gram', 23.33, 7, null, null),
('a762d0ab-a5f7-436e-a251-8f862acb64e9', '78731781-418f-4c10-9092-d536f45729b7', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('5c0cbfe2-2d00-4783-a689-234629792004', '78731781-418f-4c10-9092-d536f45729b7', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('0034bba5-5659-4cfe-9731-4739bfa9cac5', '78731781-418f-4c10-9092-d536f45729b7', '0adb493e-afb9-4462-9a0a-01a6f4c38304', 'material', 5, 'Gram', 1.88, 2, null, null),
('eda96e65-0222-4c5b-a7f5-a2d93d12d03b', '78731781-418f-4c10-9092-d536f45729b7', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 5, 'Gram', 5.25, 3, null, null),
('6f6220c0-35f3-45f3-aa40-4906ecee7bc7', '78731781-418f-4c10-9092-d536f45729b7', 'e8f321ec-6a03-4c02-a48b-a2b805f6c3d1', 'material', 80, 'Gram', 71, 4, null, null),
('4e68e65f-8692-4160-9a66-554060f53e73', '78731781-418f-4c10-9092-d536f45729b7', '57d7a57e-56ce-440f-80d9-f157e24c377e', 'material', 6, 'Gram', 2.4, 5, null, null),
('9021fb6c-abde-4aaf-9d9a-f17001fea14c', '78731781-418f-4c10-9092-d536f45729b7', '14db6a39-d0d7-417a-9a0e-068f9326e300', 'material', 5, 'Gram', 1, 6, null, null),
('3ba85b59-9d6a-4f71-85e3-74b3b308c5fd', '78731781-418f-4c10-9092-d536f45729b7', '912879dd-6874-4db1-8a0f-eaf3981d82dc', 'material', 3, 'Gram', 14, 7, null, null),
('b6fc33a1-e51f-4514-a5b4-664b4554bc8c', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('5f8daa09-53c1-40ea-b848-a4f09de861b3', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 1, null, null),
('8f25274c-6b24-4a69-843f-f3f4735319fc', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', 'recipe', 70, 'Gram', 8.06, 2, null, null),
('63a450a8-7ee5-47fd-97ce-a10f6561ff68', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'recipe', 200, 'Gram', 40.57, 3, null, null),
('678bf9bb-288a-42c2-bfeb-00df0f3d3143', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '5c003313-ada3-4aae-bedc-9cfcf001249a', 'material', 170, 'Gram', 158, 4, null, null),
('788d7295-5844-4bc5-8ea8-3e224721820d', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '12ebba3a-839d-4c97-915e-9b8476dfefd4', 'material', 10, 'Gram', 3.33, 5, null, null),
('7be6c321-3f41-4749-b070-535760831d81', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 10, 'Gram', 1.31, 6, null, null),
('99e800e5-db80-4398-b717-617b167c2b9b', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 10, 'Gram', 1.5, 7, null, null),
('ef7ecffd-d220-45cc-a879-026113ef596f', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 10, 'Gram', 2.34, 8, null, null),
('5a237718-8575-410c-a0ae-6e20842f5a48', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', '44ed782d-55ea-4bc6-b9b2-5adefa8e4c95', 'material', 10, 'Gram', 3, 9, null, null),
('29f20bde-1273-4aa3-a39e-88733e426aa8', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', 'b75bd0d6-578d-48fc-adfe-5597b517298e', 'material', 10, 'Gram', 1, 10, null, null),
('09e36990-1c14-47b8-9408-cd6eb9638af9', 'f26e1aa7-8869-4f19-9f3c-f3663cc1ce3a', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 11, null, null),
('1a8d65a7-1f95-4d99-99de-bfb2d35d9832', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('ec930c3b-6101-442c-8e2f-364a096416ce', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 1, null, null),
('fa945631-b294-48b0-ab2e-3d6f5a4f76fa', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '4b003a23-38e3-4f8a-8459-d70eb6949c6e', 'recipe', 50, 'Gram', 5.76, 2, null, null),
('10024de9-e1db-4e74-bc81-bb55c1aa2803', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '964316b9-e1b2-42e2-9ab4-03b05b4cd521', 'recipe', 100, 'Gram', 20.28, 3, null, null),
('cda6489f-bf7d-40cd-848d-239afd36b5dd', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'e8f321ec-6a03-4c02-a48b-a2b805f6c3d1', 'material', 130, 'Gram', 115.38, 4, null, null),
('bf5e1f12-03c1-441f-9d27-c7f7fd23b211', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '12ebba3a-839d-4c97-915e-9b8476dfefd4', 'material', 6, 'Gram', 2, 5, null, null),
('1d06fe1b-476c-4898-a455-20e3f8be30db', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'ad942586-e623-459d-96fa-c2c4afd71c75', 'material', 8, 'Gram', 1.05, 6, null, null),
('3d57fb71-5c71-43c9-917f-d511c956eedf', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 8, 'Gram', 1.2, 7, null, null),
('2d278d45-2d1a-4491-ba9c-a8798be97d65', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 8, 'Gram', 1.87, 8, null, null),
('eaa9b3e9-6c0c-4615-81b7-1f23b861c81f', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', '44ed782d-55ea-4bc6-b9b2-5adefa8e4c95', 'material', 8, 'Gram', 2.4, 9, null, null),
('eab6bd3e-c4a5-43ca-8469-37adcdf0297a', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'b75bd0d6-578d-48fc-adfe-5597b517298e', 'material', 8, 'Gram', 0.8, 10, null, null),
('1c3d1832-51ef-4c25-9664-6fa468296fd0', '8d2f5dfc-b840-4a04-9da3-3621611cfa45', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 11, null, null),
('873b37b3-ec71-48c8-8d09-4e3763cd3ac7', '1333fc6f-fc85-4222-a476-7159744667aa', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('0cee29a8-8d2c-4c85-beaf-ee0f93cd8d74', '1333fc6f-fc85-4222-a476-7159744667aa', '4e50bf29-b822-4950-b61b-09b892774654', 'material', 120, 'Gram', 29.12, 1, null, null),
('52618f8d-c903-4ed8-9c92-6659778fd446', '1333fc6f-fc85-4222-a476-7159744667aa', '9c14586c-ea8c-4b8b-87a5-fbc4591cd053', 'material', 100, 'Gram', 61.53, 2, null, null),
('23b58995-4c98-4ddc-abfd-cca54d3ea3ec', '1333fc6f-fc85-4222-a476-7159744667aa', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 20, 'Gram', 17, 3, null, null),
('48a63d54-80fa-4c5b-a3eb-491c3d493017', '1333fc6f-fc85-4222-a476-7159744667aa', '5b6cfb9a-a7e7-42d0-bc92-54f0bdd9e1c9', 'material', 120, 'Gram', 38.52, 4, null, null),
('c7e6c7f1-8201-4beb-92ae-52dd414dd9e6', '1333fc6f-fc85-4222-a476-7159744667aa', '12c697ac-3ad1-46fc-b730-ead942433bfc', 'material', 50, 'Gram', 4.01, 5, null, null),
('b07a809f-f47b-4a4d-b7c1-de31a3dd8ac6', '1333fc6f-fc85-4222-a476-7159744667aa', '191139a1-0ddd-4dd8-a82d-9a420e6b9bae', 'material', 30, 'Gram', 8.09, 6, null, null),
('9d6f6fd7-4132-43ee-8a77-33d52d444951', '1333fc6f-fc85-4222-a476-7159744667aa', '01405a39-10fc-4ad0-8e37-09867882cc14', 'material', 10, 'Gram', 3.6, 7, null, null),
('6b92ecad-2228-48eb-819b-96d8d8f47ee4', '1333fc6f-fc85-4222-a476-7159744667aa', 'ccce8cbb-42ab-427e-a918-169a91ee8b67', 'material', 25, 'Gram', 12.73, 8, null, null),
('9acf2ccc-d88f-49c8-82d4-dfd13fa4e6eb', '1333fc6f-fc85-4222-a476-7159744667aa', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 5, 'Gram', 0.75, 9, null, null),
('b66b5785-d473-4a14-b114-b5e32fa1f32d', '1333fc6f-fc85-4222-a476-7159744667aa', '57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'material', 2, 'Gram', 4, 10, null, null),
('c5e8b572-5787-4fc1-9eb6-5b9a14c4800e', '1333fc6f-fc85-4222-a476-7159744667aa', 'ff1bf991-7da2-4cc0-bdf9-c573a0c7ce41', 'material', 20, 'Gram', 9.29, 11, null, null),
('de8b068a-ee27-41a1-9df7-ce97e3b553d6', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('150ce34a-fa7c-4caa-9743-0a3d30c69f14', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '4e50bf29-b822-4950-b61b-09b892774654', 'material', 69.68, 'Gram', 16.91, 1, null, null),
('9582b2c6-ef00-4f44-8ba5-053b220cf9fb', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '9c14586c-ea8c-4b8b-87a5-fbc4591cd053', 'material', 58.06, 'Gram', 35.72, 2, null, null),
('7291fee0-b0d7-47d5-bd90-ef98eda54d9b', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 11.61, 'Gram', 9.87, 3, null, null),
('425240db-5714-4f78-8f02-378763e641ce', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '5b6cfb9a-a7e7-42d0-bc92-54f0bdd9e1c9', 'material', 69.68, 'Gram', 22.37, 4, null, null),
('933cea13-274e-4552-9237-56b8e1ca374b', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '12c697ac-3ad1-46fc-b730-ead942433bfc', 'material', 29.03, 'Gram', 2.33, 5, null, null),
('13e8d1e5-e5f8-4119-9362-3649a6cf77ec', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '191139a1-0ddd-4dd8-a82d-9a420e6b9bae', 'material', 17.42, 'Gram', 4.7, 6, null, null),
('5e0ab23b-12c8-480e-86f3-7b8160dd4a00', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '01405a39-10fc-4ad0-8e37-09867882cc14', 'material', 5.81, 'Gram', 2.09, 7, null, null),
('9ef57d1c-9bcc-4e47-aa45-e629e1a925af', 'c5c773ba-8b31-4844-a7de-c039f5f44018', 'ccce8cbb-42ab-427e-a918-169a91ee8b67', 'material', 14.52, 'Gram', 7.39, 8, null, null),
('d571e5fb-dab0-44f5-bb5d-4dd7cf97ebb5', 'c5c773ba-8b31-4844-a7de-c039f5f44018', 'c6476640-cca8-4fbc-bf8b-bec165f9c94f', 'material', 2.9, 'Gram', 0.43, 9, null, null),
('1b34e8a9-81cd-4ac1-9f7c-86b379874433', 'c5c773ba-8b31-4844-a7de-c039f5f44018', '57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'material', 1.16, 'Gram', 2.32, 10, null, null),
('7a5a115b-1744-4bc3-9ef0-62ad10af21bd', 'c5c773ba-8b31-4844-a7de-c039f5f44018', 'ff1bf991-7da2-4cc0-bdf9-c573a0c7ce41', 'material', 11.61, 'Gram', 5.39, 11, null, null),
('ecd657bd-e4dc-42e1-8261-94261aaa4d73', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('b879b2bd-1009-44a6-ac71-4cd7518e30ec', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('349719cb-77fb-45b4-89d2-1252cdbe2328', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('21f8db25-1edf-49ea-86b7-ffecd9aa5937', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 3, null, null),
('577ade7d-8769-444f-8ff7-b1dc903fd1b0', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', 'd75af74b-0de6-4c9d-b7ad-a8362f59c408', 'material', 50, 'Gram', 15, 4, null, null),
('fef825c9-25e7-413f-a3a3-dc81f91302ba', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', 'd247782b-1ea6-42dd-8e9f-2dc231fa04a0', 'material', 20, 'Gram', 6, 5, null, null),
('218ee234-6985-4db3-b4bc-034474d8e720', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 6, null, null),
('03de4a5a-87e8-45b7-83de-af471909d015', '07a1fccb-6beb-4d93-aaa8-1fa8e767f594', '4b8ed434-e369-442d-92d8-a75f2bb7913a', 'material', 20, 'Gram', 8, 7, null, null),
('c630fcc2-f249-4144-94d4-32f9f13a0d6b', '95138267-2f84-4bbc-8809-d9888d4e725c', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('bbf3c261-15f2-4f7a-89d0-3726afb61d26', '95138267-2f84-4bbc-8809-d9888d4e725c', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('129280be-26a3-4caf-b753-c1bd2a712d50', '95138267-2f84-4bbc-8809-d9888d4e725c', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('31d638e9-10c1-4c43-941a-a282443e67e2', '95138267-2f84-4bbc-8809-d9888d4e725c', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 3, null, null),
('77d36004-7b6f-4442-88ae-ef047d3e6af3', '95138267-2f84-4bbc-8809-d9888d4e725c', 'd75af74b-0de6-4c9d-b7ad-a8362f59c408', 'material', 40, 'Gram', 12, 4, null, null),
('eb6c52ea-8960-4446-a92e-bbc9c8f3aa05', '95138267-2f84-4bbc-8809-d9888d4e725c', 'd247782b-1ea6-42dd-8e9f-2dc231fa04a0', 'material', 15, 'Gram', 4.5, 5, null, null),
('507cf9a5-a0b1-48c7-89c4-09e4a664c61d', '95138267-2f84-4bbc-8809-d9888d4e725c', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 6, null, null),
('ce71f821-d85c-41d2-8b32-4ae73c432033', '95138267-2f84-4bbc-8809-d9888d4e725c', '4b8ed434-e369-442d-92d8-a75f2bb7913a', 'material', 10, 'Gram', 4, 7, null, null),
('dcadc905-96f3-4b15-afd4-4466a4897e41', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('141f2f8e-adcb-4f2f-8856-27028f7430c6', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 120, 'Gram', 24.31, 1, null, null),
('bf52dd67-07a8-4df6-b87f-2d74a430cb50', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', 'd7a39558-ff35-4cbe-96e2-37419dd389a4', 'material', 30, 'Gram', 14.45, 2, null, null),
('0720295e-6607-4dd7-ac9f-639084ad5f18', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', '35a34219-0cf2-444a-8de2-db22bc2b9a23', 'material', 100, 'Gram', 60.3, 3, null, null),
('ad0b8e89-b3ba-487b-95ba-511dbfbfe947', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 20, 'Gram', 17, 4, null, null),
('d42a5efd-ff60-4f46-8c6a-4f5908627fbd', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', '191139a1-0ddd-4dd8-a82d-9a420e6b9bae', 'material', 30, 'Gram', 8.09, 5, null, null),
('97846570-bbb3-49a2-aba0-007354bd20b8', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', 'ea96644d-79df-4f72-a217-7a4cde1be930', 'material', 10, 'Gram', 4.33, 6, null, null),
('d67bd4a9-855a-443d-9478-22c473520efc', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', '7d472030-5dde-4043-8280-06d4471ff078', 'material', 25, 'Gram', 20.66, 7, null, null),
('05d3af61-f70c-4638-9748-78fde4b7205a', 'f6512ca1-43cb-4273-9fca-c6a914ac6f8d', 'bd94d143-f5a8-405a-ba1a-b3f560162204', 'material', 25, 'Gram', 23.74, 8, null, null),
('7d7018c9-8dd2-4a31-a133-807409a08fa7', 'e066b614-1f73-44f3-b659-2c23cdad5cca', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('7e6a069b-c5b9-4093-8e1c-ff9e73a32c83', 'e066b614-1f73-44f3-b659-2c23cdad5cca', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 69.68, 'Gram', 14.12, 1, null, null),
('cd8bc6d6-7aeb-4ce4-8d47-7fc61c88ad10', 'e066b614-1f73-44f3-b659-2c23cdad5cca', 'd7a39558-ff35-4cbe-96e2-37419dd389a4', 'material', 17.42, 'Gram', 8.39, 2, null, null),
('fd45910f-56c4-496f-8cb0-0664dadbbe8a', 'e066b614-1f73-44f3-b659-2c23cdad5cca', '35a34219-0cf2-444a-8de2-db22bc2b9a23', 'material', 58.06, 'Gram', 35.01, 3, null, null),
('d8415778-069a-4a98-9485-b324f63dd6a5', 'e066b614-1f73-44f3-b659-2c23cdad5cca', '3c565908-d3ea-441e-9504-f35eb0ecdcfa', 'material', 11.61, 'Gram', 9.87, 4, null, null),
('95a8e404-8634-4feb-9861-919ad41b60df', 'e066b614-1f73-44f3-b659-2c23cdad5cca', '191139a1-0ddd-4dd8-a82d-9a420e6b9bae', 'material', 17.42, 'Gram', 4.7, 5, null, null),
('0e233c0e-a8a7-42e6-ac69-d9efc68a08f1', 'e066b614-1f73-44f3-b659-2c23cdad5cca', 'ea96644d-79df-4f72-a217-7a4cde1be930', 'material', 5.81, 'Gram', 2.52, 6, null, null),
('afe9a850-73a1-4b83-b465-7698333ee3fe', 'e066b614-1f73-44f3-b659-2c23cdad5cca', '7d472030-5dde-4043-8280-06d4471ff078', 'material', 14.52, 'Gram', 12, 7, null, null),
('f3934140-31e8-4dcf-b4af-189e0c94bafb', 'e066b614-1f73-44f3-b659-2c23cdad5cca', 'bd94d143-f5a8-405a-ba1a-b3f560162204', 'material', 14.52, 'Gram', 13.79, 8, null, null),
('a8b2d2d5-3665-4791-b2f6-b2d09f222456', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('da0af699-4448-46e8-88a5-d323212aa394', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('f113f8b3-7c33-437e-a35c-17ab361a076f', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 2, null, null),
('690ba3e1-3405-4809-a7e9-c1b8be90d6b5', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 120, 'Gram', 72.36, 3, null, null),
('e246171d-e861-4201-a799-6019bc2ae430', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 4, null, null),
('179a40db-fc1b-43b6-965e-3826b83e1d95', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', '569fc261-43fb-4e18-9b1a-55724ab71c8f', 'material', 15, 'Gram', 19, 5, null, null),
('61b4fcee-8c3e-43bb-abe2-3cacee41c671', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 10, 'Gram', 10.5, 6, null, null),
('65ddcc11-e64c-43d6-983a-491302f33558', '3fe6dc27-0456-4dcf-ba4e-856797279ee5', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 7, null, null),
('f95d1c21-37af-4703-9eba-75148e201a6c', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('579082bb-00db-4170-8511-d9bb14be8ddb', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('ece1573c-2a09-4f8a-b291-80d37d27c36b', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 2, null, null),
('714d393b-7d82-475f-ad7b-0599dc93fba0', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 70, 'Gram', 42.21, 3, null, null),
('5e1914e7-ddb2-4bd9-b963-ed349ba6e215', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', '01063cec-3fcd-4eeb-a2b9-72bd447767f3', 'material', 5, 'Gram', 1.17, 4, null, null),
('f3efe517-671b-4d8f-903c-76ca17c8fd5a', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', '569fc261-43fb-4e18-9b1a-55724ab71c8f', 'material', 8, 'Gram', 10.13, 5, null, null),
('e3417547-5f5c-4dcd-aa89-8df5e239c3c0', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', 'b930a242-3c77-4d23-a1df-b5235c4cb67a', 'material', 5, 'Gram', 5.25, 6, null, null),
('6c375884-fdb0-4335-a806-e250e29fdee4', '3348bc9a-60fb-43d9-8f72-819d66eb8f3a', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 7, null, null),
('e04ed4fb-0369-4c4f-92b9-472626afeb70', '995d707d-5053-4917-a234-0ea59da2bcf3', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('4244bba9-8aa2-42f6-b6af-a48077538a87', '995d707d-5053-4917-a234-0ea59da2bcf3', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 1, null, null),
('e52138ac-8e15-4ef5-9674-5e2e6bf23c2c', '995d707d-5053-4917-a234-0ea59da2bcf3', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 25, 'Gram', 7, 2, null, null),
('500dbc44-8cbf-488f-b9aa-bdb36ceda89d', '995d707d-5053-4917-a234-0ea59da2bcf3', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 150, 'Gram', 31, 3, null, null),
('9ac00cbc-af83-472a-ada6-399b9b1c3466', '995d707d-5053-4917-a234-0ea59da2bcf3', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 30, 'Gram', 12.24, 4, null, null),
('c0340c1e-5604-40ad-acfe-fa51b1326cb6', '995d707d-5053-4917-a234-0ea59da2bcf3', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 5, null, null),
('1eb17262-af8b-4101-b1bb-f1198edf02a2', '995d707d-5053-4917-a234-0ea59da2bcf3', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 6, null, null),
('0a9e4fbb-8457-4c0b-890e-0a9f223105f9', '995d707d-5053-4917-a234-0ea59da2bcf3', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 25, 'Gram', 4.55, 7, null, null),
('a9fadeec-239f-456c-9d6f-f50ef2068353', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('f425aa47-8ce8-4ed6-a5ac-c39e7deb511b', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 1, null, null),
('bcb604f6-22b9-409f-92f3-53afe8326e1e', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 15, 'Gram', 4.2, 2, null, null),
('eb76da70-3253-462c-ad88-47f76f920043', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 90, 'Gram', 18.6, 3, null, null),
('35b7d69b-1766-4985-a44e-17c2c3be12c4', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 15, 'Gram', 6.12, 4, null, null),
('6a6845da-3ce0-4afe-b3f2-2637cc3f120b', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 5, null, null),
('32d33726-7b81-4f6e-8bda-d13e39004b7f', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 6, null, null),
('a18e7753-a208-4292-97ee-392f0ceef160', '71665e32-bd11-4ba4-b7a1-9678bc8bd43c', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 20, 'Gram', 3.64, 7, null, null),
('68557ab6-0c40-45da-af23-a5251ceb9a9a', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('dc04bbed-c49d-44dd-a02c-51748757ff01', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('9748fabc-aedd-4eba-ba81-70d1da6b3b5d', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('a982fc22-7653-4220-acd5-d9681dc4d845', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '158ce39a-0bc9-4d03-bc2b-b6d7a2d85257', 'material', 30, 'Gram', 10.8, 3, null, null),
('d1ef54a1-fa67-4b83-ae08-7894b152be33', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '7c0d929f-22a2-47f3-beb5-4e2aefb337e9', 'material', 40, 'Gram', 24, 4, null, null),
('936c430a-6f5c-43c3-a38d-5c3736d68315', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '9388779f-cba6-46e2-bbc6-76480461ac9a', 'material', 80, 'Gram', 29.12, 5, null, null),
('be701184-d4a5-4fa3-af6a-bb0b403f8280', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '96124eac-743c-44b3-8fae-4ee0a17ddcd2', 'material', 100, 'Gram', 9, 6, null, null),
('8b87cd72-a96a-40df-bf8e-6ed77e19d030', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', '586c41d9-9c05-49c0-8234-2ec26c43aaec', 'material', 10, 'Gram', 12, 7, null, null),
('bf1a0dc1-9f2f-45ba-9e89-14315d3437f1', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', 'f78b6c11-caae-4acf-ae5e-21d08e8482d6', 'material', 20, 'Gram', 10, 8, null, null),
('46900038-9ce0-4072-984e-afe467fdc109', 'be16fdaa-27a0-493e-b482-d13be9b8dc2a', 'e720791b-e45d-463f-b0f4-e601cda4fa7f', 'material', 5, 'Gram', 4.17, 9, null, null),
('7aad2c4c-272d-4649-b3a9-e0389244b639', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('91689221-ea6e-4d9b-b5a7-1bfd63aa0e63', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('58a5812f-6c2c-4d99-92cf-8b418a5849a2', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('0a4fa3e8-990a-41f2-a172-b0780e6201bb', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '158ce39a-0bc9-4d03-bc2b-b6d7a2d85257', 'material', 20, 'Gram', 7.2, 3, null, null),
('cfe1f597-1aac-4dd7-8172-98a77eb52994', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '7c0d929f-22a2-47f3-beb5-4e2aefb337e9', 'material', 25, 'Gram', 15, 4, null, null),
('252fd055-703e-4343-a6a5-83493137a833', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '9388779f-cba6-46e2-bbc6-76480461ac9a', 'material', 50, 'Gram', 18.2, 5, null, null),
('7b373a5a-0239-4eec-ac60-76fda84aebde', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '96124eac-743c-44b3-8fae-4ee0a17ddcd2', 'material', 70, 'Gram', 6.3, 6, null, null),
('01e66160-9952-4116-9d3e-fb8b29c35c97', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', '586c41d9-9c05-49c0-8234-2ec26c43aaec', 'material', 6, 'Gram', 7.2, 7, null, null),
('ce515d89-454b-465e-80f3-60f02aeedc42', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', 'f78b6c11-caae-4acf-ae5e-21d08e8482d6', 'material', 15, 'Gram', 7.5, 8, null, null),
('196b3270-1adc-402c-a684-c898dbed7033', '17ebf2cc-4c4c-4212-a0a7-8d5853e90648', 'e720791b-e45d-463f-b0f4-e601cda4fa7f', 'material', 5, 'Gram', 4.17, 9, null, null),
('97af4ebd-5079-4770-8ab3-0e1a17f45f5e', '01bab03e-4e00-4ece-843d-97dad1315615', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('5aee5fda-5e55-42d2-899d-08c52000d4f3', '01bab03e-4e00-4ece-843d-97dad1315615', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('ddabeceb-678e-4497-b12d-1038a89be905', '01bab03e-4e00-4ece-843d-97dad1315615', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('beba9dda-3082-425f-a6e5-e0aae0e183f3', '01bab03e-4e00-4ece-843d-97dad1315615', 'f21524c8-2445-4eef-89d6-c8c0612448a5', 'material', 70, 'Gram', 6.1, 3, null, null),
('4ad0e76d-929d-4769-b956-d01a3fd5cae2', '01bab03e-4e00-4ece-843d-97dad1315615', '107ecc43-b9e8-42a3-8a8e-73ab32b4f546', 'material', 10, 'Gram', 1.43, 4, null, null),
('a700cff9-13e5-4506-be42-9c078880bab3', '01bab03e-4e00-4ece-843d-97dad1315615', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 'material', 50, 'Gram', 3.34, 5, null, null),
('ca5fced6-b605-438c-85e9-79e3719c7890', '01bab03e-4e00-4ece-843d-97dad1315615', '9588a308-e354-4a4b-9f70-b643ff5d079e', 'material', 30, 'Gram', 6.42, 6, null, null),
('e0fa5f99-0f9d-4ca4-ad70-c9b1fd42fac9', '01bab03e-4e00-4ece-843d-97dad1315615', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 7, null, null),
('54bad866-66a4-4d9a-92e2-fa8780d26d26', '07f377e4-9c06-4abc-af0d-655d83936e7c', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('09d51c54-fe31-4b6f-b55f-1f7a4b6ffc9d', '07f377e4-9c06-4abc-af0d-655d83936e7c', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('90a7b55e-430f-4e16-bedc-4437068213ae', '07f377e4-9c06-4abc-af0d-655d83936e7c', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('5032fdbb-a2a7-4c45-86f5-3537cb5ed0ca', '07f377e4-9c06-4abc-af0d-655d83936e7c', '8fd5efd8-b88e-4ec1-af27-537560c0245f', 'material', 50, 'Gram', 10, 3, null, null),
('5e34e1c5-0a9c-4a08-a8f8-f785e75b6071', '07f377e4-9c06-4abc-af0d-655d83936e7c', '107ecc43-b9e8-42a3-8a8e-73ab32b4f546', 'material', 8, 'Gram', 1.14, 4, null, null),
('84993b01-d4d7-4fbe-ad9a-edf2b41891da', '07f377e4-9c06-4abc-af0d-655d83936e7c', '435b2865-4112-4576-bed3-011acd2bfd6d', 'material', 35, 'Gram', 3.5, 5, null, null),
('c60d25c9-bb76-4c82-ade9-45483e22ce66', '07f377e4-9c06-4abc-af0d-655d83936e7c', '9588a308-e354-4a4b-9f70-b643ff5d079e', 'material', 20, 'Gram', 4.28, 6, null, null),
('fd2bb868-f245-4a81-8dae-bea9ee93d6a9', '07f377e4-9c06-4abc-af0d-655d83936e7c', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 7, null, null),
('aae16856-42b2-4c77-aeee-82dc4043bfd8', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('dc458b23-dadd-4cb5-ac0b-604185d46673', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('933e0790-f2a6-4030-bb10-bc7199da93cc', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('71ab803a-84bb-48b1-a4d2-a4ccfff456cb', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', 'ac93c28e-d8d3-4bf4-9f5f-b6bd1ec9d34e', 'material', 10, 'Gram', 4, 3, null, null),
('38dbfa81-7523-4b1d-bec6-7ebeead68117', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '640470e4-af50-4624-8bf6-8a0a0ca22ce1', 'material', 1.5, 'Gram', 6, 4, null, null),
('33f69645-4e86-4221-8248-6058db0cdae9', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '435d385f-f893-4d08-8e3d-014cdcc97e0d', 'material', 40, 'Gram', 10.15, 5, null, null),
('87521b27-13ff-4180-ac8d-5493061557f9', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'material', 5, 'Gram', 10, 6, null, null),
('27476c76-fb41-4e81-9572-1908c60510c0', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '80e402f5-2ea6-4a1c-8c82-ce83bec08143', 'material', 15, 'Gram', 4.29, 7, null, null),
('86943bce-95eb-42dc-9289-96e64adfd50f', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '107ecc43-b9e8-42a3-8a8e-73ab32b4f546', 'material', 10, 'Gram', 1.43, 8, null, null),
('35e21bc6-785c-495c-965f-4d073ab89af4', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '344fa3c6-0430-4047-930c-c7da62d009ea', 'material', 15, 'Gram', 3.12, 9, null, null),
('54c9cfbe-55f3-4d28-b4c1-94823028132e', 'd18145e0-0526-4344-b1d3-c8af18bf4b6c', '8196b631-aec0-47e6-8d7f-1ba64d65cfbd', 'material', 25, 'Gram', 9, 10, null, null),
('fecb39e3-e62a-4d27-9cdd-4c80cbbcbfee', 'f427239d-54d0-427a-b270-daccf1de7943', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('d76488f8-f2eb-4ace-9f0e-1aae466ed430', 'f427239d-54d0-427a-b270-daccf1de7943', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('aaa88938-3c88-4961-b3b6-e6d3995f1da1', 'f427239d-54d0-427a-b270-daccf1de7943', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('baf098f7-f3d8-499c-8758-1364ec5f2e59', 'f427239d-54d0-427a-b270-daccf1de7943', 'ac93c28e-d8d3-4bf4-9f5f-b6bd1ec9d34e', 'material', 6, 'Gram', 2.4, 3, null, null),
('96acfd8c-07d6-403b-84f1-5cdde72ca6d8', 'f427239d-54d0-427a-b270-daccf1de7943', '640470e4-af50-4624-8bf6-8a0a0ca22ce1', 'material', 1, 'Gram', 4, 4, null, null),
('82098498-9b7d-484c-b9da-5fea7a560b40', 'f427239d-54d0-427a-b270-daccf1de7943', '435d385f-f893-4d08-8e3d-014cdcc97e0d', 'material', 25, 'Gram', 6.35, 5, null, null),
('682c8681-05c9-4064-b46b-1048cd20ab2f', 'f427239d-54d0-427a-b270-daccf1de7943', '57abbe07-2ec7-4634-a3f8-0805adc37ea7', 'material', 5, 'Gram', 10, 6, null, null),
('836e20c6-c9fe-49af-80ca-d98d726d17cd', 'f427239d-54d0-427a-b270-daccf1de7943', '80e402f5-2ea6-4a1c-8c82-ce83bec08143', 'material', 15, 'Gram', 4.29, 7, null, null),
('def86fa5-68e3-4da7-a9f9-961305f47850', 'f427239d-54d0-427a-b270-daccf1de7943', '107ecc43-b9e8-42a3-8a8e-73ab32b4f546', 'material', 7, 'Gram', 1, 8, null, null),
('8acffbff-3781-45b0-9040-6a48e09e4305', 'f427239d-54d0-427a-b270-daccf1de7943', '344fa3c6-0430-4047-930c-c7da62d009ea', 'material', 10, 'Gram', 2.08, 9, null, null),
('04f49817-a958-447c-841e-d43e56840d61', 'f427239d-54d0-427a-b270-daccf1de7943', '158ce39a-0bc9-4d03-bc2b-b6d7a2d85257', 'material', 10, 'Gram', 3.6, 10, null, null),
('413de4cf-1419-4c45-8dfa-84545855d9c6', '67b65fac-a5d1-4a89-8257-5f53c663b12f', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('8b08959b-9aea-47c6-849e-a2c3bad366fc', '67b65fac-a5d1-4a89-8257-5f53c663b12f', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 1, null, null),
('b1da07be-98f2-4383-88fa-f8eeac923941', '67b65fac-a5d1-4a89-8257-5f53c663b12f', 'ebd4bae9-3477-41b6-9f4f-382c25cff597', 'material', 45, 'Gram', 15.54, 2, null, null),
('cf7347c0-bbb4-48ae-b1ae-30da9d3d1279', '67b65fac-a5d1-4a89-8257-5f53c663b12f', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 150, 'Gram', 31, 3, null, null),
('aa03e551-1743-4bc4-b071-1e814e59cd60', '67b65fac-a5d1-4a89-8257-5f53c663b12f', '8f490883-4cb7-4a89-86fa-325b2cf4b551', 'material', 30, 'Gram', 12.25, 4, null, null),
('f8753228-24c4-4083-9fbf-aba4d817bb19', '67b65fac-a5d1-4a89-8257-5f53c663b12f', '080af581-7528-49f3-999d-5a474bbc6263', 'material', 2.35, 'Gram', 13.42, 5, null, null),
('8e88f45e-a317-4762-9f38-38d048317337', '67b65fac-a5d1-4a89-8257-5f53c663b12f', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 6, null, null),
('8c7722db-a97d-49e8-8a52-7c021007a71a', '67b65fac-a5d1-4a89-8257-5f53c663b12f', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 25, 'Gram', 4.55, 7, null, null),
('53e65aff-4679-42ba-872e-50cb40333c1d', '67b65fac-a5d1-4a89-8257-5f53c663b12f', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 8, null, null),
('2a08a2b5-114a-4adc-9a4d-fdb9c55e7e19', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('e36b2a8c-c961-48c8-bec2-6ba800cee195', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 1, null, null),
('ba6aa2c7-26ca-4701-b344-8fb9c6f4f196', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 25, 'Gram', 7, 2, null, null),
('235b24ae-8ff5-4917-a18c-5a2f0444d2b3', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', 'f9a505c9-9a96-4751-a351-f47bb469eb24', 'material', 90, 'Gram', 18.6, 3, null, null),
('17ac3310-f716-4ad4-a341-e7d281bb9611', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 20, 'Gram', 8.16, 4, null, null),
('bc953bae-9259-4c6a-bc1c-ed742bebfa84', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '080af581-7528-49f3-999d-5a474bbc6263', 'material', 1.5, 'Gram', 8.56, 5, null, null),
('c72aed58-893c-4142-90d6-727a80e08601', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 6, null, null),
('ee336a9d-81ad-461d-99b7-79344e846701', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', 'e3911215-f0d5-4ba3-8ece-c809b24d7a9e', 'material', 20, 'Gram', 3.64, 7, null, null),
('8bba50ab-9732-4f13-8251-3b6cdfbad31c', '720f7c1f-a127-493f-89d0-71b2d3ecb2a7', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 8, null, null),
('8d96d87e-bcb1-41bb-8f81-20b1c3f64430', 'f3428969-33f7-427b-b5cd-a42975596575', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('6f761e71-9eba-4112-9750-fed732f75f6f', 'f3428969-33f7-427b-b5cd-a42975596575', '99a5efb7-2882-4dea-8b89-77d6dbffc5e1', 'material', 130, 'Gram', 31.12, 1, null, null),
('ebefbc80-a381-4509-8799-08b1720302dd', 'f3428969-33f7-427b-b5cd-a42975596575', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 80, 'Gram', 73.6, 2, null, null),
('d6fefefb-9b31-45e6-a2d9-83e5675a98a5', 'f3428969-33f7-427b-b5cd-a42975596575', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 25, 'Gram', 10.2, 3, null, null),
('7c7824b2-0cc9-4859-a511-66b02fbbd300', 'f3428969-33f7-427b-b5cd-a42975596575', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 5, 'Gram', 1.4, 4, null, null),
('9d7f4ecf-a3dc-4894-8f7c-c5c6bd6fdc0e', 'f3428969-33f7-427b-b5cd-a42975596575', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 50, 'Gram', 10.13, 5, null, null),
('53045950-c716-451b-8b87-f251e6198c28', 'f3428969-33f7-427b-b5cd-a42975596575', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 6, null, null),
('aca9f764-f56d-489d-b4ba-745fc30a0eaf', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('0958b1e0-0b90-4919-9374-e8f75b8e889e', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', '99a5efb7-2882-4dea-8b89-77d6dbffc5e1', 'material', 60, 'Gram', 14.36, 1, null, null),
('3abb97cd-33fc-4c7c-99cb-22c6f19242a0', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 60, 'Gram', 55.2, 2, null, null),
('71c8911a-0328-470b-ba0e-b10b455de904', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 15, 'Gram', 6.12, 3, null, null),
('06ab194e-9e19-4180-b112-21a3f2efa34f', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', '37743fcc-ad53-41d6-8f96-5352846f3c5d', 'material', 3, 'Gram', 0.84, 4, null, null),
('9d7b1992-ae53-4459-a09a-20a2d5a1f2c2', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 30, 'Gram', 6.08, 5, null, null),
('08da4672-d6ec-41d1-8067-dacb4b3b3a2e', 'a0e9f96e-ee28-45a6-8265-eeb5d4cc8c5f', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 6, null, null),
('a3d45c49-2474-4de4-91cd-a3c0bc45fe04', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('ddc5da7e-4bbf-4753-867c-2adf4a038935', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('b0cd5aa2-c4d0-4dbd-ae94-3a9b3f8b7556', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('2ce8f1ce-c045-43eb-a9fb-50a80ebd21a0', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 40, 'Gram', 36.8, 3, null, null),
('ca7ab96b-c04f-4cc5-964c-4cf35fc8e320', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '031c073f-e923-4450-bfe8-c548514b8e32', 'material', 20, 'Gram', 10, 4, null, null),
('8da977cd-8033-4900-bf75-2d1199260a35', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '8196b631-aec0-47e6-8d7f-1ba64d65cfbd', 'material', 50, 'Gram', 18, 5, null, null),
('2af2ecf4-ea4e-4b2d-875c-41e004ea7bc3', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', '61849d9d-2d97-4492-bd32-5f0c6bc8f05b', 'material', 40, 'Gram', 11.52, 6, null, null),
('e4e0d7c6-6e5a-47f0-823b-01014695d511', 'd4ccef63-90a7-4533-9850-a6f9239bbb57', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 7, null, null),
('a2e5c74e-77d5-4e0a-9e15-6c71492717bf', '7e6e9415-4916-4658-9bcb-0dae83920d48', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('490dadc6-86ba-4987-ab48-df70cfe37cf0', '7e6e9415-4916-4658-9bcb-0dae83920d48', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('f6be88c0-a8ef-4623-ba03-9486dc93bf2d', '7e6e9415-4916-4658-9bcb-0dae83920d48', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('5718d812-6ddc-4a67-ba64-8871beba0ee3', '7e6e9415-4916-4658-9bcb-0dae83920d48', '051879ec-c975-44c0-9d00-c2135042e39a', 'material', 15, 'Gram', 12.31, 3, null, null),
('ca437ec5-8a7d-4384-a028-cb87fd354741', '7e6e9415-4916-4658-9bcb-0dae83920d48', '031c073f-e923-4450-bfe8-c548514b8e32', 'material', 10, 'Gram', 5, 4, null, null),
('73f35245-eb41-4d10-9cd9-996ed7d77682', '7e6e9415-4916-4658-9bcb-0dae83920d48', '8196b631-aec0-47e6-8d7f-1ba64d65cfbd', 'material', 30, 'Gram', 10.8, 5, null, null),
('8a8e49e0-2b81-468d-a2af-f37c56572424', '7e6e9415-4916-4658-9bcb-0dae83920d48', '61849d9d-2d97-4492-bd32-5f0c6bc8f05b', 'material', 30, 'Gram', 8.64, 6, null, null),
('a1132d31-2589-4763-b959-dba20d660be2', '7e6e9415-4916-4658-9bcb-0dae83920d48', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 7, null, null),
('edfee941-bd09-497a-9a62-99b0dd2d7a45', '54a2b89d-5b77-440e-b990-f5a1aff1083b', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('f0e6b1c1-7410-4ae4-b9e4-cebd56b477ea', '54a2b89d-5b77-440e-b990-f5a1aff1083b', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('9e485bf3-603e-4d7f-8249-0f80ff2c28c1', '54a2b89d-5b77-440e-b990-f5a1aff1083b', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 2, null, null),
('e1c903af-8d4e-45bf-8db9-43cdf95ef141', '54a2b89d-5b77-440e-b990-f5a1aff1083b', '63556e13-5e35-4e5d-9a2b-3fec43a6d44f', 'material', 50, 'Gram', 22.75, 3, null, null),
('b0bba884-df02-4760-8fe5-de7813ff001a', '54a2b89d-5b77-440e-b990-f5a1aff1083b', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 30, 'Gram', 7.71, 4, null, null),
('04f8c3bf-9af7-41c5-aa06-bc1bbb69eedd', '54a2b89d-5b77-440e-b990-f5a1aff1083b', '9ed6866d-6a96-4547-ac99-b14b4a70137b', 'material', 20, 'Gram', 6.25, 5, null, null),
('c732ae58-c2fb-4ac0-9bfe-db83465ad7ac', '54a2b89d-5b77-440e-b990-f5a1aff1083b', 'f300509c-d63a-4f97-89d1-f8329c8f1932', 'material', 30, 'Gram', 7.5, 6, null, null),
('187f1d83-8cf3-448e-a970-e896457b852e', '54a2b89d-5b77-440e-b990-f5a1aff1083b', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'recipe', 25, 'Gram', 3.97, 7, null, null),
('0a6d7200-0402-4f60-b16f-95949f4e5f14', '54a2b89d-5b77-440e-b990-f5a1aff1083b', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 8, null, null),
('c098fb33-3027-40e2-ae06-dcc3741116cb', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('5fd1be26-0ff5-48d2-94eb-f01484caf112', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('08420ec1-b310-4ff3-b112-ddf6386ac8ff', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 2, null, null),
('fffd5187-f724-47ef-9e8d-49a5a3dd271d', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', '63556e13-5e35-4e5d-9a2b-3fec43a6d44f', 'material', 30, 'Gram', 13.65, 3, null, null),
('c1e6efd3-0098-498a-b3c2-e53a48fcfb20', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', 'b4c04fbd-6aa7-458a-9730-9a3c77248972', 'material', 15, 'Gram', 3.86, 4, null, null),
('871c53d3-cb35-4b2f-9b73-b7bce581eea1', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', '9ed6866d-6a96-4547-ac99-b14b4a70137b', 'material', 10, 'Gram', 3.13, 5, null, null),
('cfb4fbc7-78a2-4d39-9d76-f30c56ecd9a1', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', 'f300509c-d63a-4f97-89d1-f8329c8f1932', 'material', 20, 'Gram', 5, 6, null, null),
('4e0a1702-4712-44c9-9975-8ddba9c3270c', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', '4a259ada-b64b-47e3-aa95-3a1557e3a57b', 'recipe', 15, 'Gram', 2.38, 7, null, null),
('6e7b8ff1-3760-4957-bf9b-274db432e7b9', '56a9d690-1c53-4fa9-b1ad-f44c4232b181', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 8, null, null),
('afad3100-8745-4013-b0a2-a50ab3f96d8e', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('93a25035-30c1-4536-9bb5-f485ddb3a38a', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 110, 'Gram', 66.33, 1, null, null),
('84db4478-4aad-407c-adb5-94d67d2fed0b', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 2, null, null),
('b0ec3c1d-b44a-43d1-ba84-b4a1f85e6b10', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', 'b8ca9c8e-bdfb-44c7-9533-44bec7d2cfd7', 'material', 40, 'Gram', 10, 3, null, null),
('045451a6-c0ad-49dd-bb15-4a6d133acae1', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 40, 'Gram', 16.32, 4, null, null),
('880800cd-53b6-4fef-b074-80526ff66a6a', 'feaa0284-88d9-4c9d-88aa-0a306bf06a73', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 15, 'Gram', 6.56, 5, null, null),
('1c18f126-0dcc-4324-aa98-7b05a82a3d13', 'a30a809d-ea58-4466-ad8c-1d45435b9328', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('abb1c531-1eef-4e0b-a121-e1c4d32b4625', 'a30a809d-ea58-4466-ad8c-1d45435b9328', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 1, null, null),
('967f22e3-3deb-48d7-8548-7cffa86defdf', 'a30a809d-ea58-4466-ad8c-1d45435b9328', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 40, 'Gram', 8.1, 2, null, null),
('0577d1fa-774e-46f7-a244-34e820c2864d', 'a30a809d-ea58-4466-ad8c-1d45435b9328', '2209a197-95d7-41f0-bee9-33a4c9a03e89', 'material', 20, 'Gram', 4.55, 3, null, null),
('162bd85f-0f0b-44ea-b5ae-97867d1ba8da', 'a30a809d-ea58-4466-ad8c-1d45435b9328', '26bb2144-f3f5-4042-86ad-001412386414', 'material', 20, 'Gram', 8.16, 4, null, null),
('a51dbf02-ae61-4d14-81b9-2cc3b6de3e57', 'a30a809d-ea58-4466-ad8c-1d45435b9328', '18764540-e469-4518-ae5e-ad7d0281b126', 'material', 10, 'Gram', 4.38, 5, null, null),
('80f8ec3c-502b-46ef-ad98-c3ea192e233f', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('9827b4f8-4af3-4b39-aaf6-868b36eb1d91', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 150, 'Gram', 30.39, 1, null, null),
('b841c5ad-1491-40ab-a473-e87b0da0c05d', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', '980bb8ac-ed38-417b-aba9-c811719f127b', 'material', 5, 'Gram', 103.38, 2, null, null),
('390f5659-89fa-42ea-a6a9-fed2267f07d6', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', '9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'material', 5, 'Gram', 26.78, 3, null, null),
('499f3ae1-baea-40a8-8825-8306469944f6', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 25, 'Gram', 23, 4, null, null),
('6ae8d386-b6a1-45cd-8d06-6f1380870964', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 120, 'Gram', 72.36, 5, null, null),
('8a5560b8-bf51-4603-b0dc-9b3321c9e269', 'b68fb97b-0f42-46bc-a292-d4d33b482c0f', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 15, 'Gram', 1, 6, null, null),
('27722501-f059-4dcb-bd13-c149cfd5ec39', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', '2af74928-a965-47c8-8029-7cf33a57c792', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('89e93f4e-04ea-4b70-a61f-e868a435f2f0', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', 'caf0a18d-ec8e-4618-8633-6598dc3ff1d1', 'material', 80, 'Gram', 16.21, 1, null, null),
('ef0e9e5a-cdbd-447d-b509-17fde3d79e4a', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', '980bb8ac-ed38-417b-aba9-c811719f127b', 'material', 3, 'Gram', 62.03, 2, null, null),
('0a602ddf-45ed-4226-9bd2-bfb624bf8e09', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', '9154abcb-6830-4f6e-a7b1-7be5253c6b67', 'material', 3, 'Gram', 16.07, 3, null, null),
('282dc4ac-7c5e-4790-a381-703753e01738', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', '0ea88338-eb0c-41cb-b288-c46e63870a9d', 'material', 15, 'Gram', 13.8, 4, null, null),
('6ed7f06c-3bd3-42e9-a556-47745460fea4', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', '4e9be89a-9674-4110-952f-f30c8fb50682', 'material', 60, 'Gram', 36.18, 5, null, null),
('2791ecdd-215b-40f2-aea0-fc60f8181870', '1cbaf40f-6ad9-44bb-b5e2-d8dc4069d673', 'e2fbd0c9-c688-4ef1-a604-fabcccbe54e4', 'material', 10, 'Gram', 0.67, 6, null, null)
on conflict (id) do nothing;

-- ingredient_yields (87)
insert into public.ingredient_yields (id, ingredient_id, purchase_cost, purchase_quantity, purchase_unit, raw_quantity, raw_unit, wastage_quantity, wastage_unit, usable_quantity, wastage_percentage, yield_percentage, original_unit_cost, yield_adjusted_unit_cost, effective_from, notes, created_at, updated_at) values
('6f6f1fda-ea7c-430f-b2be-e0af144bd32c', 'a43ed5e7-f254-49de-91ba-64022ec5a365', 66.7, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.06670000000000001, 0.083375, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('77fa01bd-3d14-4b66-96ce-9ff7ca13e48f', '48cb11cf-41e5-4464-9f67-0a8231840c39', 128.8, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 0.1288, 0.15152941176470588, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('29b6bef6-2a68-4050-acec-f76823cbf742', '5dcbadc3-8763-417f-a614-4b8976122cc9', 57.1, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.0571, 0.06344444444444444, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e3e1f3df-ee89-4bc7-8efe-3cb7d5c1d5ed', '454ef1bf-d65d-4bb1-a5b3-8170ac2b9fef', 399.96, 1, 'KG', 1200, 'Gram', 500, 'Gram', 700, 41.67, 58.33, 0.3333, 0.5713714285714285, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('13fa01e9-ce97-40c4-a112-6afd914f3bc9', '9957a332-4790-4a29-b055-8c70028d343f', 1092, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.364, 0.78, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('97467dfb-67ef-45aa-ba96-c890816d96ea', '46bfba68-f94b-4633-87c5-75d82b2343a1', 22.27, 1, 'KG', 170, 'Gram', 70, 'Gram', 100, 41.18, 58.82, 0.131, 0.2227, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6fd47b9f-222d-44b5-a7a6-77a44e6861ef', '50fe8cf4-6cc3-4e97-bdee-8928973552e7', 120, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 1, 1.2, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('29bc8e80-9539-4879-910a-9e0129fa28b4', '9268abfc-4e40-47f4-b4db-532a3172b84e', 520, 1, 'KG', 1300, 'Gram', 700, 'Gram', 600, 53.85, 46.15, 0.4, 0.8666666666666667, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9a55b004-b546-430c-b95e-167c905f77f0', 'ddd659ea-3014-45e0-8d86-633ac329692a', 66, 1, 'KG', 330, 'Gram', 130, 'Gram', 200, 39.39, 60.61, 0.2, 0.33, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7b72ac48-a3c0-4ec9-bd9a-2dd31cf444b0', '0ac0ecbc-cee9-4620-aabd-e299cfd4350a', 42, 1, 'KG', 210, 'Gram', 110, 'Gram', 100, 52.38, 47.62, 0.2, 0.42, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a6bc2d93-69c0-425f-bb67-783b0711d4f8', 'f42f617b-0ca3-40d3-9959-a9e36a166266', 0, 1, 'KG', 1350, 'Gram', 400, 'Gram', 950, 29.63, 70.37, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('71127c60-86d3-4adf-8bdf-088de38d5fa0', 'bb434880-2a01-4c6a-9b56-538d9e9176df', 900, 1, 'KG', 900, 'Gram', 320, 'Gram', 580, 35.56, 64.44, 1, 1.5517241379310345, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0683d753-201a-4e20-987a-c7583fc4c127', '501eb23c-9fd8-4e1e-b0d8-986048d7c873', 0, 1, 'KG', 500, 'Gram', 200, 'Gram', 300, 40, 60, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d60f2b67-eac5-4b61-9093-28a25d7f1163', 'd19d7f1f-d84a-49b7-b11a-e6b871e8dacb', 80, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.08, 0.08888888888888889, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1f74655a-752d-4b7b-8a9a-d9f2e4fa728a', 'a7fc8c41-3bb8-4dd3-a716-c12bf85f35e6', 900, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.9, 1.125, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d4d399c0-a1af-4b70-8246-4e7431fd3ab4', 'eb3bcd32-72b1-4f2d-8342-bdb7b0326290', 333.3, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0.3333, 0.4974626865671642, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fc7f424c-d106-4fb9-9022-475668773148', '42397711-d15b-4c41-8db6-a07659d8b506', 1300, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 1.3, 1.4444444444444444, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('391c372b-48d9-4bcb-9429-11c8756c5661', '45d5710c-87c8-4337-9bef-94b089161dcb', 146.2, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.1462, 0.2924, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e35ab9ec-4195-4499-8fcf-f35307f082e1', 'fe650510-bd5a-4c54-b74a-6711725ad849', 0, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('41d29364-e5a0-4564-93c6-dd0c321f3c92', 'b2ac0879-caf3-47a2-a75b-96328ad9c6c4', 0, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('01b47ede-3741-4067-a7d9-2e6ef6c87657', '7873d5d9-b5f0-43dd-b35f-cb427a66e067', 1000, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 1, 1.25, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('51c123ab-870a-4bc5-a49f-704ae329051f', '7cd99b95-d350-4e4a-973e-7e657007cd75', 114.3, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.1143, 0.14653846153846153, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('93a99b5e-e6f2-4c9a-9378-e7a4009ff0c9', 'ae7cb6b8-f0b1-4888-8c0b-6b9a17e91c70', 0, 1, 'KG', 1000, 'Gram', 850, 'Gram', 150, 85, 15, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('450bfcd1-9e3f-48ba-b114-b75cdee95a12', '10eb2a81-2354-43aa-8a18-d1004c239458', 122.82, 1, 'KG', 534, 'Gram', 260, 'Gram', 274, 48.69, 51.31, 0.22999999999999998, 0.4482481751824817, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('87306f55-3b49-4750-b187-0ce31b003570', 'd57dd08d-486f-40f4-a592-cbe8000b551b', 0, 1, 'KG', 400, 'Gram', 190, 'Gram', 210, 47.5, 52.5, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4d5b6372-3147-45dd-9114-fafe6d0bd8b9', 'b97fc4d6-6dbc-4f6a-92b1-bed3d57acf14', 8.33, 1, 'KG', 68, 'Gram', 18, 'Gram', 50, 26.47, 73.53, 0.1225, 0.1666, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8c1ad948-cd88-4d82-82d4-759270b9b697', 'c5e0f8a1-0aa4-4229-8dda-ad35fcbca220', 136.89, 1, 'KG', 270, 'Gram', 70, 'Gram', 200, 25.93, 74.07, 0.5069999999999999, 0.6844499999999999, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('383a2267-20b1-479b-9eb4-075a26b76703', '55d96a24-fd5a-48e8-a019-3781c7ca4f07', 80, 1, 'KG', 200, 'Gram', 50, 'Gram', 150, 25, 75, 0.4, 0.5333333333333333, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0691c696-6b53-4823-ae8a-1df90df817d3', '28628d3d-952b-4e37-953f-a89ac0255e70', 24, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 0.2, 0.24, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('02968df9-75dc-4138-b254-44fdb73505ff', 'f50e02ce-a242-4f91-a15d-403bf080f832', 0, 1, 'KG', 1000, 'Gram', 20, 'Gram', 980, 2, 98, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5ab0b262-1393-4fab-b8fb-a31dd0de1093', '5aa4746e-9735-44d7-8928-0cf0ce3600bd', 56.2, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.0562, 0.07025, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0dca1510-0acb-420d-af5d-25f9239257f2', 'a9d3fb9a-2429-454d-86ee-60da57138930', 128.8, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.1288, 0.161, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b407eedd-536d-4489-a0a2-b9b5bc52837a', '60087d5c-4cf7-4e69-a8bb-2563ebc7449e', 0, 1, 'KG', 1000, 'Gram', 350, 'Gram', 650, 35, 65, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('12729894-0bee-41a1-9551-7a773e06b2a0', '79aabab7-22dc-4f9b-ae3e-4c3ac1bf15c0', 0, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('31f9eea4-e726-49ce-b8e1-c01228e42dbe', '8bd50a68-01c6-4c42-881c-1fad163bfd0e', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c0a4a717-4ff1-4d1e-a4f4-bbbdee1b4a7d', '20d88828-0547-4d03-80c6-de5aa5ef8b8f', 550, 1, 'KG', 2200, 'Gram', 200, 'Gram', 2000, 9.09, 90.91, 0.25, 0.275, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7a2194b9-3fe4-472d-aba1-5bb175fbee51', 'a393f8b1-cfb0-4d34-860d-1087f7209722', 120.96, 1, 'KG', 900, 'Gram', 100, 'Gram', 800, 11.11, 88.89, 0.1344, 0.1512, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('abca3a21-5d31-4297-b4fa-9ca5ae6f7dcb', '3cc44822-e6ed-4345-b7d3-529d1d8e4ea4', 68.52, 1, 'KG', 1200, 'Gram', 475, 'Gram', 725, 39.58, 60.42, 0.0571, 0.0945103448275862, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6b9973d7-c1b6-4a0f-90b4-75ca08578b72', '1abd1149-7451-4215-94c0-5a25dbd1e911', 0, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0, 0, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2104dc04-e80b-4603-90cf-7606a8837819', '199384ba-1cdc-4c11-a379-7428a27e42d9', 246.4, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0.28, 0.448, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c08b7a4a-edb6-4647-b4f2-26ac4c25876e', '1efbf855-0856-430a-b199-e4c7512e90c2', 100.05, 1, 'KG', 1500, 'Gram', 500, 'Gram', 1000, 33.33, 66.67, 0.0667, 0.10005, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('78d50c49-dd42-4e0e-8587-c656b4c5d8f6', '1143752d-9cdb-4554-b062-db6908676d25', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3665e85-6513-4701-994e-0a881ff00e9a', 'da8607b0-0281-4e43-bfaa-15990366d0fc', 840, 1, 'KG', 700, 'Gram', 92, 'Gram', 608, 13.14, 86.86, 1.2, 1.381578947368421, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9fc0b4ba-ce85-411e-b8ac-443feb0b6dd3', '7c2e789d-9697-4302-90a6-c6b79deaa599', 15, 1, 'KG', 150, 'Gram', 90, 'Gram', 60, 60, 40, 0.1, 0.25, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c8867186-d1b2-4c2d-b8b7-38f2efe715e3', '4b6dc6de-dc4d-4a4d-afca-32c227dd99ed', 182, 1, 'KG', 500, 'Gram', 100, 'Gram', 400, 20, 80, 0.364, 0.455, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a1b3ade7-c7b8-4529-89c1-30ee04fb24d1', '52b1a192-4bfb-4c3c-a11e-ffca25aa4b8c', 22.84, 1, 'KG', 400, 'Gram', 200, 'Gram', 200, 50, 50, 0.0571, 0.1142, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b5f8c25a-4f94-42f4-bb2f-097b0dad7c97', '2d8f4ae6-136a-40ce-8bb1-024a6a1d928c', 0, 1, 'KG', 287, 'Gram', 37, 'Gram', 250, 12.89, 87.11, 0, 0, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('81bb5180-cbc0-4527-9804-04a1c5baa734', '99e6eeb1-ca40-497c-9534-62c0137eece3', 80.64, 1, 'KG', 600, 'Gram', 400, 'Gram', 200, 66.67, 33.33, 0.1344, 0.4032, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('64addfd3-1a67-4241-a92a-ecde3f75df1e', '88cdb722-6350-4050-aaae-2b11f34f1890', 0, 1, 'KG', 3300, 'Gram', 1700, 'Gram', 1600, 51.52, 48.48, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('43626a08-b6e8-473b-9bee-41d9144f889f', '40aa6f1f-6e91-4ac9-a3bb-08336ce27018', 0, 1, 'KG', 5300, 'Gram', 270, 'Gram', 5030, 5.09, 94.91, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2b881a25-211c-43b7-a4bc-aaf3b195326a', 'd2b5e5c6-d916-4726-99c0-751afde32c2b', 0, 1, 'KG', 2500, 'Gram', 1250, 'Gram', 1250, 50, 50, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ea5ce2fe-b824-476c-b289-2fea43c2b794', 'd288d8df-104c-4bae-960a-ba877ad9e4d5', 33.35, 1, 'KG', 500, 'Gram', 300, 'Gram', 200, 60, 40, 0.06670000000000001, 0.16675, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b69e0a69-80ff-43fb-9c79-76e71f00d3ab', '59f209b1-8f1a-4e20-af1e-b94b04996675', 1142.9, 1, 'KG', 1000, 'Gram', 520, 'Gram', 480, 52, 48, 1.1429, 2.381041666666667, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c155289a-9873-4af1-8563-a590d637bcc0', 'b82fae50-c1b1-43f4-bc8f-6f14847b5e9a', 435.4, 1, 'KG', 1400, 'Gram', 900, 'Gram', 500, 64.29, 35.71, 0.311, 0.8707999999999999, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('63f4a27d-46a8-4253-a37e-87d94896132e', '3e96bac9-6f6b-48ed-8152-74287e948133', 249.9, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.0833, 0.1785, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('68da58d8-8f65-4c9c-ad36-91a7a31ae6a3', '6dc52c52-6aca-45f1-a6c2-cf5969855f23', 532, 1, 'KG', 1900, 'Gram', 400, 'Gram', 1500, 21.05, 78.95, 0.28, 0.3546666666666667, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ff44bdee-6d48-4cc1-8b45-946e7da61cab', '61d0ac35-76d4-4bd4-8a6f-f183eb2467a6', 43.2, 1, 'KG', 100, 'Gram', 50, 'Gram', 50, 50, 50, 0.43200000000000005, 0.8640000000000001, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e3c1872d-7af2-43b2-bada-fa60d68c1b77', '84925384-bb93-4927-9258-65e6247b96fd', 100, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.1, 0.2, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('05bfefaa-b77b-44ae-a25c-2eaeb4151087', '211f7c7c-7738-4f98-a624-2a02e456e5cd', 14, 1, 'KG', 70, 'Gram', 40, 'Gram', 30, 57.14, 42.86, 0.2, 0.4666666666666667, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3d61c1fb-1fc2-46ae-931e-734faeb04f50', '6225de37-3902-4e5f-a46d-19e9d6faa198', 0, 1, 'KG', 2000, 'Gram', 1150, 'Gram', 850, 57.5, 42.5, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d5777c76-b6b3-4185-8425-c6e6bf6a86a5', '5246576f-7cc7-4fc0-9ffc-ff932b73ad7b', 0, 1, 'KG', 240, 'Gram', 103, 'Gram', 137, 42.92, 57.08, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4efa7a07-4dce-4ee6-896b-32f615d87b3e', '5d0eaf9b-734a-458c-a166-01348c317573', 0, 1, 'KG', 3000, 'Gram', 200, 'Gram', 2800, 6.67, 93.33, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c27a95f0-f487-408f-bcfc-776da4f1964c', 'd1ba4d79-85a5-49f9-8e33-371df11961a2', 0, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3ac2b243-00b7-4529-a3e4-b24c9c1b2db0', 'f329b400-2b8b-4cf4-9fcb-38fc59f054fd', 0, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e4b1ef7e-557a-42d8-a413-84cb39a2fc10', '158cb5b0-902a-4dc4-abbd-2a6c49f8945d', 0, 1, 'KG', 390, 'Gram', 190, 'Gram', 200, 48.72, 51.28, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d9a8da87-98a9-4086-aeb4-b149af349979', '16cd3b31-233c-4a43-bdd8-e672f2aa0852', 120, 1, 'KG', 100, 'Gram', 40, 'Gram', 60, 40, 60, 1.2, 2, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('569f40f3-b787-43e5-96fe-d194b2c0d00e', '73a2ea7f-c937-4d77-b845-bd14b8510b2a', 938.1, 1, 'KG', 3000, 'Gram', 1500, 'Gram', 1500, 50, 50, 0.31270000000000003, 0.6254000000000001, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('af3cbf4f-12c9-4ec4-a1fc-91d14d885afc', 'de0c4172-20fc-4aba-84f8-b4285386d313', 1800, 1, 'KG', 3000, 'Gram', 1440, 'Gram', 1560, 48, 52, 0.6, 1.1538461538461537, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f671d50d-4320-4cd7-8501-b7ca34d356b2', '37896100-10a6-4d84-897b-901e5d0cec4f', 0, 1, 'KG', 3000, 'Gram', 1350, 'Gram', 1650, 45, 55, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0560ba2f-4429-4ed9-9c6e-f4b7cc6bd3f2', 'd006afa6-89ef-4e34-82c6-f363ed7990bc', 0, 1, 'KG', 507, 'Gram', 203, 'Gram', 304, 40.04, 59.96, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('487df5f7-8fbe-4321-9a2d-eeae380548f1', 'a2653a05-b735-4215-a1ff-973ed13267f9', 110.5, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0.1105, 0.05972972972972973, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3d9297d3-a9fd-4b6c-a5a8-f80f843dc539', '0d096a1b-bc9e-462c-bcdf-315b6fc62730', 101.8, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1610, 0, 161, 0.1018, 0.06322981366459628, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a27065b8-8371-4dfd-bb9c-804ca802e6cc', '5652f212-5cb8-49ae-ad00-a8a4549774a8', 92.3, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1810, 0, 181, 0.0923, 0.050994475138121546, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c9258191-6f26-46b0-82b0-78e3bd4a7f28', 'c11f8b36-255d-4a51-9dbb-697effaf6aa5', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('38bda077-7ef4-4c98-9cde-4080ae46de58', 'd9f53a97-af8c-497d-8795-75bab0296e25', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1950, 0, 195, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d6a0ccd7-4c6c-4b71-88bd-8d4fca126a2f', '052683da-f6c2-4268-a4b9-fa076e9a2533', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c9740ae9-9e66-4492-a718-5b34321cabfe', '7170f702-8b2e-471a-9c06-b1b979a552c3', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ec2435c6-fb5b-4f48-84ee-4fde2e56efc1', '2936057b-bb75-4b58-9885-318dbf7d35e5', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1750, 0, 175, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('dd57ae39-7ed8-4a11-9c89-bbdbe1772275', '20d164fa-a366-4c89-b443-2c500889c7e1', 188.6, 1, 'KG', 500, 'Gram', 0, 'Gram', 700, 0, 140, 0.3772, 0.2694285714285714, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('31583ed9-1849-4ff2-8951-bbb0bc5b3015', '760a2d69-0f2b-4cac-b0c2-a3fa9346bac0', 200, 1, 'KG', 1000, 'Gram', 940, 'Gram', 60, 94, 6, 0.2, 3.3333333333333335, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2cf9e06f-9aed-436c-b3a4-1c319c83d302', 'ba09556e-c886-493a-aca1-54de2f1397e5', 1000, 1, 'KG', 1000, 'Gram', 950, 'Gram', 50, 95, 5, 1, 20, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e9d4363b-c5cc-45f5-a6a0-dcde576316b2', 'cf3c1977-2c34-4f0b-9752-e7ba217a3bf9', 78.8, 1, 'KG', 1000, 'Gram', 280, 'Gram', 720, 28, 72, 0.0788, 0.10944444444444444, '2026-06-01', 'Paste', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bdba9e09-a1a7-42e2-9ba3-7aac1871a56f', 'c4814b34-ee2b-4987-9c75-9dddef404d36', 87.2, 1, 'KG', 1000, 'Gram', 400, 'Gram', 600, 40, 60, 0.0872, 0.14533333333333334, '2026-06-01', 'Roasted', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7185d1c3-344a-4865-9a31-eb9e52519426', 'a18749e1-50bd-434a-bbae-f1fb8bdde679', 500, 1, 'KG', 1000, 'Gram', 880, 'Gram', 120, 88, 12, 0.5, 4.166666666666667, '2026-06-01', 'Dehydrated', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3980a9da-4401-4583-a1a9-a5b107fccd9f', '0e041665-2b2a-4666-b2cd-09121ea469f2', 0, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0, 0, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9f0b0a55-9e21-4875-af19-028795464cc5', '3bb7f6ac-4ea0-4ac3-8131-1083f470aed1', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f01d2e73-6d62-41f4-a323-dd6b42354ac0', '775bfe2c-49c6-429b-9faf-4b1979364248', 122.82, 1, 'KG', 534, 'Gram', 404, 'Gram', 130, 75.66, 24.34, 0.22999999999999998, 0.9447692307692307, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;


commit;
