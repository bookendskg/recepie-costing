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
('40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'Butter', 'Dairy', null, 538, 1, 'KG', 'Gram', 0.538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f21433b9-755a-4d48-abd7-9ff51d398a84', 'Parmesan Cheese', 'Dairy', null, 1266.7, 1, 'KG', 'Gram', 1.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aef0bdf0-9780-441e-af54-8a1d9aabea41', 'Mozzarella Grated', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bde68d53-34fb-4acb-9d50-aa6b5e945658', 'Burrata Cheese', 'Dairy', null, 887.5, 1, 'KG', 'Gram', 0.8875, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0504eb3a-031f-48d2-ab53-3a2ae43f90f2', 'Amul Gold Milk', 'Dairy', null, 75.2, 1, 'KG', 'Gram', 0.0752, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('eb6aa82b-f8c1-497d-8a2e-5751212f6c43', 'Fresh Cream', 'Dairy', null, 206, 1, 'KG', 'Gram', 0.206, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a025680b-aa43-4635-a924-e78f8f80fad7', 'Tofu', 'Protein', null, 260, 1, 'KG', 'Gram', 0.26, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b212c18-823c-4d72-9131-6086ba596f05', 'Boiled Spaghetti Pasta', 'Grains & Flour', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8d6323ea-06c4-4b17-ab3a-a70d0969329c', 'Boiled Bucatini', 'Grains & Flour', null, 92.3, 1, 'KG', 'Gram', 0.0923, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9c8b42f5-88f3-4ae2-8913-46adcead7897', 'Rice Flour', 'Grains & Flour', null, 66.7, 1, 'KG', 'Gram', 0.06670000000000001, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('80d2b493-1a3c-4fad-8e9e-182720675e85', 'Maida', 'Grains & Flour', null, 41, 1, 'KG', 'Gram', 0.041, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ccda1047-98e8-4085-afb8-47943a6fa4f2', '00 Flour', 'Grains & Flour', null, 119.7, 1, 'KG', 'Gram', 0.1197, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a582b449-2c8a-4d52-add1-ac93b91e5963', 'Sushi Rice', 'Grains & Flour', null, 252, 1, 'KG', 'Gram', 0.252, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d47ac757-b7a1-4f07-bad2-c897da30a527', 'Yeast', 'Bakery', null, 368.4, 1, 'KG', 'Gram', 0.36839999999999995, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e39a9899-4063-45ef-bc03-da61b5ed1ed9', 'Malt', 'Bakery', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b7e5ddea-ff58-4f33-aea9-fb8aa36bfb67', 'Brown Sugar', 'Bakery', null, 106.7, 1, 'KG', 'Gram', 0.1067, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('04119af1-0689-434f-b035-21f8fac114aa', 'Sugar', 'Bakery', null, 101, 1, 'KG', 'Gram', 0.101, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a7e5151a-c827-422f-9983-ac049a0c7198', 'Olive Oil', 'Oils & Fats', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ef4e5b02-135a-4b46-8e3e-b5e850f9c38f', 'Sunflower Oil', 'Oils & Fats', null, 104.7, 1, 'KG', 'Gram', 0.1047, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'Oil', 'Oils & Fats', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cba42b32-1adf-4578-b730-dba991053df5', 'Chilli Crisp Oil', 'Oils & Fats', null, 125, 1, 'KG', 'Gram', 0.125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aecc5921-98ba-41fa-a14b-d84f5fca1161', 'Red Chilli Oil', 'Oils & Fats', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a932530e-5105-4aa9-ad3b-6e82bc47eced', 'Peeled Garlic', 'Vegetables', null, 257.1, 1, 'KG', 'Gram', 0.2571, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('20484b26-de18-4908-9c3f-5d8be29d4c29', 'Garlic Chopped', 'Vegetables', null, 187.5, 1, 'KG', 'Gram', 0.1875, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('685881f5-24b8-4b97-8f20-6c308939e5b8', 'Green Garlic', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7f72a693-2b69-461c-9df7-946060b6a4ea', 'Fried Garlic', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('42525160-fcb6-4aa1-99d9-02f5409826af', 'Ginger', 'Vegetables', null, 128.8, 1, 'KG', 'Gram', 0.1288, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('85e0a680-0962-48a1-be1e-7929383381e8', 'Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.06670000000000001, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('21317611-268d-4177-b273-8ce4903e7090', 'Slit Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('85d596f0-7c7c-429a-8855-c1e9cf74d40f', 'Fried Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('806ce782-b2c5-464e-9f49-a2d144c2c024', 'Confit Onion', 'Vegetables', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f29d842a-7fc6-4c01-b848-d874e19b0a90', 'Confit Garlic', 'Vegetables', null, 482.2, 1, 'KG', 'Gram', 0.48219999999999996, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('23dadd77-9702-4106-966c-76f23e5f9c81', 'Spring Onion', 'Vegetables', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3bc5969d-1297-47dc-8c40-413d80f09797', 'Chopped Spring Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('2f8afdf8-a7a1-4578-9aec-20f90c35c943', 'White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2e989fb8-4913-4426-bb04-d5475c925c3c', 'Parsley', 'Vegetables', null, 432, 1, 'KG', 'Gram', 0.432, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4b12572b-a095-463f-bb98-729cbca27b58', 'Coriander', 'Vegetables', null, 131, 1, 'KG', 'Gram', 0.131, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ce6099c2-148c-45cb-8a1c-76a843f23528', 'Dill Leaves', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3b1be253-76bf-4502-85cb-000ee784f298', 'Basil', 'Vegetables', null, 233.7, 1, 'KG', 'Gram', 0.2337, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b55069bf-eb23-4900-b729-146efc9b0522', 'Curry Leaves', 'Vegetables', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0e51d8bb-48b8-4e0e-870e-a7c8ca5e97da', 'Green Chillies', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('04281782-87f1-43eb-abbc-2698fa74ad4c', 'Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('77a643c1-3d63-4f92-b917-b1cef91673f2', 'Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cb4431be-959d-44ab-bbcd-78a6a5033be6', 'Shimeji Mushroom', 'Vegetables', null, 1300, 1, 'KG', 'Gram', 1.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e3711058-30f6-4a47-92b4-d7cc89cc4788', 'Beetroot', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a39bf90f-a4de-4305-8bcf-8390518ba69b', 'Pickled Red Paprika', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('334fd832-a54e-4af4-bb3a-1d79df2be3a0', 'Dried Red Chilli', 'Spices', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6ae0325a-b451-432b-826e-d17599e2e2c3', 'Lemon Juice', 'Sauces & Condiments', null, 311, 1, 'KG', 'Gram', 0.311, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'Black Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('17c3908f-cb0a-424c-bc19-234ae1de71c4', 'White Pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('640252b8-8656-48f9-9e79-4786be64cb50', 'Chilli Flakes', 'Spices', null, 353.3, 1, 'KG', 'Gram', 0.3533, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5e880a4e-3dfa-45cd-97e3-d262ed9a129a', 'Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('85cf76ce-10cc-42b8-af18-684fb5da9d76', 'Salt', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'MSG', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'Stock Powder', 'Spices', null, 312, 1, 'KG', 'Gram', 0.312, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5d420772-7c11-4413-8390-9f4bad621641', 'Garlic Powder', 'Spices', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('925a367e-cdfa-4b4d-a5f9-a854e9f2c6d9', 'Onion Powder', 'Spices', null, 840, 1, 'KG', 'Gram', 0.84, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dd921e5d-acbf-4db0-b63b-6b24d70c1705', 'Kashmiri Chilli Powder', 'Spices', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d14a1f66-7e9b-497e-a7d8-a339b5d19ad3', 'Turmeric', 'Spices', null, 1428.6, 1, 'KG', 'Gram', 1.4285999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b12ccec2-cd1f-4979-b6f0-1c05b2cb951b', 'Mustard Seeds', 'Spices', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4274e163-35a6-4243-a48f-bde7ddc80679', 'Fenugreek Seeds', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e51c2e93-fa8f-4016-a514-e2dc344a9e55', 'Coriander Seeds', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('33d2bf9d-796c-4997-af10-07e0f93654e3', 'Cumin Seeds', 'Spices', null, 933.3, 1, 'KG', 'Gram', 0.9332999999999999, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9bd93cea-f1d4-4d9d-807f-a9b8372b74d5', 'Fennel Seeds', 'Spices', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f868ff6c-f841-47a8-91c8-3369b4581fa4', 'Cinnamon', 'Spices', null, 6000, 1, 'KG', 'Gram', 6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('217a8061-2817-4a73-bb08-0e9835ff92c6', 'Cloves', 'Spices', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('04635265-8593-454b-a70b-5879098f6e95', 'Cardamom', 'Spices', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('55d02258-f1dd-47ca-8054-9ababb7b814b', 'Black Sesame', 'Spices', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b1f2ff36-f5ca-4a2d-9fba-b025b35ab768', 'White Sesame', 'Spices', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7c33400e-8bc7-4f76-8842-af3617312137', 'Bagel Seasoning', 'Spices', null, 2200, 1, 'KG', 'Gram', 2.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4d941eae-d36e-4dc0-8944-12b2195e8b21', 'Wasabi', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ed7ef7fc-abbb-4963-8aca-4b526ec13b45', 'Almond', 'Dry Fruits', null, 830, 1, 'KG', 'Gram', 0.83, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d92df6aa-455b-45de-ba52-c02d0a5c3f45', 'Kashmiri Chilli Red Paste', 'Sauces & Condiments', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('65b5683f-e960-4303-9a58-4bf3202a1df4', 'Chunky Tomato Sauce', 'Sauces & Condiments', null, 235, 1, 'KG', 'Gram', 0.235, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4c7d22f9-d76f-48c5-ba56-092c7167bb18', 'White Vinegar', 'Sauces & Condiments', null, 31, 1, 'KG', 'Gram', 0.031, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'Hot Sauce', 'Sauces & Condiments', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('079b0848-38e0-4557-9905-785d934d791c', 'Plain Mayo', 'Sauces & Condiments', null, 85, 1, 'KG', 'Gram', 0.085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d76ed8c2-926f-4839-bcf0-720e2a4cae62', 'Ponzu Mayo', 'Sauces & Condiments', null, 153.2, 1, 'KG', 'Gram', 0.15319999999999998, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ef31d46a-3435-4332-880d-bc72106c314e', 'Gochujang Mayo', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('af38a138-015e-44ee-921c-a31c8dd2333c', 'Avo Guac', 'Sauces & Condiments', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('db72b201-2bf0-498e-83d1-5b080b5110ec', 'Corn Slurry', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d901fcb6-1f1a-4d7d-a7a8-0a7870a43017', 'Coconut Milk', 'Dairy', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('19950686-429f-4707-8c3c-db46066afeb8', 'Tamarind', 'Sauces & Condiments', null, 190, 1, 'KG', 'Gram', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('522fa47a-0857-4f50-a510-9260344dc291', 'Water', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3eb0d177-2561-4a4e-b09f-fd4478013e2d', 'Ice', 'Beverages', null, 0, 1, 'KG', 'Gram', 0, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aa0f4f29-04ec-451c-b225-5d324f5d4473', 'Stock Water', 'Beverages', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('62ccd7fd-5272-4e2b-9a68-406b920a4931', 'Arugula', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0908996c-55e2-4b45-99e7-64b356db81be', 'Iceberg', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ebff6b5f-3b85-4e29-8cf1-dd6864850891', 'Romaine', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0ef36efa-7d7d-4918-ae03-c50763637fab', 'Curly romaine', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e2cf9241-1044-49d4-90d4-9daf748a0a49', 'Cherry tomato', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b740862f-aedb-42d9-a86f-a43bfa4e7c83', 'Grapefruit', 'Fruits', null, 1142.9, 1, 'KG', 'Gram', 1.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('421b6ebe-8109-48c6-9aba-8ab9ec614ea0', 'Pine nuts', 'Bakery', null, 5000, 1, 'KG', 'Gram', 5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5e1b3b1d-2e00-4dfa-b649-f32e1c82a55a', 'Black olives', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f37f1adf-828b-4fc4-a5ed-549ee14e4eb1', 'Vinaigrette', 'Sauces & Condiments', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fd3aa76a-e225-4cd4-80ac-ca4dd3952f1d', 'Sea salt', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1b81b6f3-707c-406e-a275-c444a047d188', 'Hot honey', 'Sauces & Condiments', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('64c974ba-6a04-41e8-add9-204488304b59', 'Edible flower', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ad9c6be0-eebc-444d-b2be-1f19c3fad516', 'Baby burrata', 'Dairy', null, 750, 1, 'KG', 'Gram', 0.75, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1d2fe5d4-c10c-400c-ad8c-3ae390085606', 'Parmesan (grated)', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7822c7ae-9d79-431b-a002-ecd767eede3c', 'Crispy croutons', 'Other', null, 139, 1, 'KG', 'Gram', 0.139, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('09647a47-1dc6-41a0-aed5-09c0db06e570', 'Caesar mayo', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0e67b519-1ba8-4ba1-a8b5-7c2c347ea1e2', 'Persimmon', 'Fruits', null, 362.5, 1, 'KG', 'Gram', 0.3625, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3f2dcf12-5775-40ed-be06-a200d738e128', 'Strawberry', 'Fruits', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('146fbcaa-2a17-4cd9-9a7b-a191f8b2123a', 'Burrata', 'Dairy', null, 691.8, 1, 'KG', 'Gram', 0.6918, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9312ea03-0025-4829-841d-55b52ec59c6d', 'Caviar', 'Other', null, 810, 1, 'KG', 'Gram', 0.81, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a128c1ba-9fc9-4d85-b8f9-6c2f114fc22d', 'Edible flowers', 'Other', null, 1, 1, 'Piece', 'Piece', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b17748fa-5ec9-4e2e-87e9-7b87f791d00e', 'Processed Iceberg lettuce', 'Vegetables', null, 322.6, 1, 'KG', 'Gram', 0.3226, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e07ce63f-cb6b-4942-929f-b8367af88834', 'Processed Romaine lettuce', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('47100c37-4c7d-455a-a40a-6ddb675f15b3', 'Processed Lollo Rosso', 'Other', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0d7f5ef-e393-4faa-a564-12f1363a991b', 'Crushed black pepper', 'Spices', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('39afcb2c-38bc-4eaa-a7c6-1d646af3899b', 'Roasted hazelnuts', 'Bakery', null, 2600, 1, 'KG', 'Gram', 2.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7ec79322-a3f1-4a28-a6c6-37fe65ff6acb', 'Granola (chopped)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6a059a2f-0a8b-4e03-819e-cc2946d1407e', 'Mango (cubed)', 'Fruits', null, 510, 1, 'KG', 'Gram', 0.51, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1d4bf7a5-875f-4381-9892-f0dc4c4e831b', 'Grapefruit (cubed)', 'Fruits', null, 268.6, 1, 'KG', 'Gram', 0.2686, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ebb533c6-b69a-45b3-8ddf-a7f75221dd52', 'Cherry tomatoes', 'Vegetables', null, 605, 1, 'KG', 'Gram', 0.605, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0d4fc98-7bab-48cb-bfb0-c20bbe6e6f2a', 'Hot honey drizzle', 'Sauces & Condiments', null, 356.7, 1, 'KG', 'Gram', 0.3567, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7129c709-0269-40d0-9645-7f14ffee726b', 'Red bell peppers', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'Garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a30a33b1-77c6-4b61-8ceb-efecd4840b24', 'Tomato', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6313132d-b485-43d6-9d3d-64d9f69f0048', 'Roasted bell pepper paste', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'Sour cream', 'Dairy', null, 182, 1, 'KG', 'Gram', 0.182, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('435348e1-fdac-433f-8121-b8ffd165e7b5', 'Pesto', 'Sauces & Condiments', null, 408, 1, 'KG', 'Gram', 0.408, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c8954ce-5e56-4be0-bc4a-887e729fba47', 'Sourdough', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('95e1ea46-61b6-41a4-b157-48ab383658aa', 'Garlic butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('676f115a-cb1e-4071-8abb-11a02ceb2fcc', 'Cooked risotto rice mix', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2048a7c4-e1ec-4f95-b666-925367e5cb57', 'Mozzarella', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d567cfd3-a4da-4d95-ba12-761105b36ce2', 'Arancini batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2e3d84e5-2c92-45ba-abc2-4fce9c995b67', 'Panko crumbs', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3657c5a3-013b-4627-904b-699481e99c49', 'Frying oil', 'Oils & Fats', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d9ed1403-f09d-439c-831b-82ba8a8a0600', 'Dough', 'Grains & Flour', null, 56.3, 1, 'KG', 'Gram', 0.0563, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5a01b3bb-659f-4283-8c4e-a5abcea87c3d', 'Bread base', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'Cream cheese', 'Dairy', null, 884, 1, 'KG', 'Gram', 0.884, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b479c62b-6c8b-4284-b19f-086e313b3b8f', 'Green garlic (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7477a6c9-679b-401a-b336-08c3b7212562', 'Ricotta', 'Dairy', null, 283.5, 1, 'KG', 'Gram', 0.2835, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0f5ce0e7-0d55-444e-9fb3-b14854e20eb5', 'Oregano', 'Spices', null, 375, 1, 'KG', 'Gram', 0.375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'Parmesan', 'Dairy', null, 437.5, 1, 'KG', 'Gram', 0.4375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5e3f59f1-e05c-475a-9cef-88a3cd13762d', 'Thyme', 'Spices', null, 5500, 1, 'KG', 'Gram', 5.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d705bb87-2327-4b48-b6d1-5847faf2715b', 'Salt & pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0bdc23a5-f399-4915-8c7a-2fde9283b0ec', 'Pasta sheet 22 g x 2', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('aacfccd4-46fa-4868-9925-006d4a295d9c', 'Tomato paste', 'Sauces & Condiments', null, 242.8, 1, 'KG', 'Gram', 0.2428, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('061a188b-cdc5-4c7b-b1b0-0a54408ba0bd', 'Mozzarella 20 g each', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('90587a4f-429b-4433-896a-7bb987b384ea', 'Ricotta filling 15 g each', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('504426a0-aa6e-4ffb-9e92-70c7dd45aaa5', 'Batter', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('20cd6c75-3dc5-43cf-b477-0660449e1d5a', 'Bread crumbs', 'Grains & Flour', null, 150, 1, 'KG', 'Gram', 0.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('da7bcdcc-c4b9-4d9c-8056-e4512ec1267e', 'Pomodoro sauce', 'Sauces & Condiments', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d6c43012-099d-4256-88ec-7d5ba9431c18', 'Chopped garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b680c705-fa76-4754-87e0-ddae44a7d288', 'Seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72fe8754-6331-4dc3-a22c-6a20baea3b3d', 'Cowboy Butter', 'Dairy', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bc972565-c980-47a7-b35a-8cbdcd4b98a0', 'Pepper', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fa967cec-45bf-4c80-9e0d-1ff65fc7e5a7', 'Brussels sprouts (halved)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8dcd19e2-0059-42d9-9b43-acccfab286e4', 'Garlic (chopped)', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('25fe4bcd-157a-4e95-bfe3-eb021072efc8', 'Red chilli flakes', 'Spices', null, 296, 1, 'KG', 'Gram', 0.296, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c6c7c652-58ac-47e1-aae4-d5893927cb73', 'Balsamic vinegar', 'Sauces & Condiments', null, 1050, 1, 'KG', 'Gram', 1.05, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3dce999f-94cc-4a6e-8a2a-66b783072cc0', 'Salt & black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a4a3f519-e291-469b-af2d-903380108454', 'Béchamel sauce', 'Sauces & Condiments', null, 112.6, 1, 'KG', 'Gram', 0.1126, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fd8fcf20-248e-4286-8b74-a98b6b4ae748', 'Plain mayonnaise', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4a7a50c5-56ae-4a76-ac40-94f11c58e9fb', 'Fresh Bhavnagri chilli', 'Spices', null, 0.2, 1, 'Piece', 'Piece', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4cefc6e3-d0a7-4bc9-86ee-b4e947c05cb3', 'Pickled onions', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('533fe6b6-32fc-476a-b573-321cac42b448', 'Feta crumbles', 'Grains & Flour', null, 813.3, 1, 'KG', 'Gram', 0.8133, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('16fad0af-d727-4024-b7df-1d40f8a772c2', 'Tomatoes', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('903ae796-c7c0-4980-8dc5-37ba93e2b08a', 'White miso paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9adbaa1b-78e5-402a-8406-36069475dec6', 'Chili flakes (or fresh red chili - 5 g, deseeded)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8f14e45a-469a-49e5-85bc-28eb517c0824', 'Soy sauce (optional)', 'Sauces & Condiments', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ef350584-df07-468c-b284-aefedabd4035', 'Basil (fresh, chopped)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('13d6f71d-5a29-427c-928d-6a5697027730', 'Thyme (sprigs) (simmer, remove before blending)', 'Spices', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('630054b2-f2b0-4367-bdff-94c9bdec7e44', 'Bay leaf (remove before blending)', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('860de630-add7-4831-be3d-bba2aeab197c', 'Parsley stems (optional, simmer with base)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b3d7496e-95b2-47d9-9dd6-26ca430cbf31', 'Pomodoro', 'Other', null, 216.3, 1, 'KG', 'Gram', 0.2163, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6bcc2acf-bccd-4bf0-af3d-9e4eef5c0920', 'Boiled spaghetti', 'Oils & Fats', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('faccddca-da01-418a-8285-187ebf850712', 'Boiled macaroni', 'Oils & Fats', null, 101.8, 1, 'KG', 'Gram', 0.1018, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9a084fde-1b40-4d4b-94d3-c12aeab111d7', 'Orange (creamy tomato) sauce', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c8d2e692-f0ae-44bd-851e-b893ccd957c8', 'Boiled fettuccine', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0809ed32-c211-4a88-8ac2-a5e4a140c45a', 'Béchamel', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('286c2b14-dda0-4e70-97eb-d604e6df4c92', 'Boiled linguini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('16e94c48-5c75-4c29-b4be-ad1891376945', 'White sauce', 'Sauces & Condiments', null, 242.7, 1, 'KG', 'Gram', 0.2427, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('65003fce-46f4-43ea-a077-b8150a80ee9f', 'Mascarpone', 'Dairy', null, 811.6, 1, 'KG', 'Gram', 0.8116, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bdb322a5-bd3a-4960-a5f3-a1172b2b949f', 'Lemon zest', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0b74fc9-989e-40f7-865f-43a7a9bd1b39', 'Cooked arborio rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b4bcc93-fdab-4c23-a7e4-7904968eb49f', 'Asparagus', 'Other', null, 923.1, 1, 'KG', 'Gram', 0.9231, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9a8589f1-7b15-4762-ab68-34ce8954b1d7', 'Peas', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d14d3fbd-7412-4218-92fa-b977accd34a9', 'Soy chunks (textured)', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('28ebfde5-dff4-4213-8a2e-61f93d74a550', 'Onion (diced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e49a27b3-21f5-4961-a174-6ad4e2c96e7c', 'Carrot (diced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e9eb67bf-d842-4446-8845-ad37ffb82b9b', 'Celery (diced)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('77f9e29f-f7bf-4b9e-9edc-dd3e5ea6f398', 'Tomato passata', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d26d557-8234-42eb-a4f9-150802d293d2', 'Dried oregano', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d38b6fc3-0586-4f9e-ac32-cf20928a56ef', 'Plain flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('83f7d5a7-4302-460c-bd6a-0041bc9f1c17', 'Milk', 'Dairy', null, 76.7, 1, 'KG', 'Gram', 0.0767, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('35961148-891f-4350-88dc-8c9183b1110f', 'Nutmeg', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6e81805d-9739-4091-bbca-89cd3ff8e4bc', 'Lasagna sheets (oven-ready)', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9c261165-2339-4ea9-8a05-97ef02db523a', 'Mozzarella (shredded)', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('289c679d-223d-4910-b7f9-bd7e8f7d9139', 'Ricotta cheese', 'Dairy', null, 288, 1, 'KG', 'Gram', 0.288, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8857df4a-3268-4510-8623-e8fcacfd17d8', 'Blanched kale', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e24d5339-fda0-4a4d-9874-3c4da2f69e90', 'Chopped jalapeño', 'Other', null, 366.7, 1, 'KG', 'Gram', 0.3667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b8ad745a-aff0-49d6-a352-b50f0be7a6a8', 'Xanthan gum', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('30879b7e-f481-483f-9820-166fa21845ae', 'Conchiglioni', 'Grains & Flour', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('40d5a868-a306-4ab0-83c7-885a4fc49a0e', 'Garlic pomodoro sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a401cf35-ade5-43e1-a32e-3c5b21084620', 'Sunflower seeds', 'Other', null, 420, 1, 'KG', 'Gram', 0.42, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('727e5c9e-6dcc-4856-b048-2ba6d09e9492', 'Caramelised onion', 'Vegetables', null, 120, 1, 'KG', 'Gram', 0.12, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9dc8de2e-9838-49ca-972d-4568a6836892', '1 ladle water', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fbf3e709-84a2-4c3d-8a94-6d142ccf3bbc', 'Spaghetti', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8e47b336-d659-48a4-9fd9-ca0d96a14ff1', 'Mix seasoning', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6e7c045e-a616-4f2d-a573-758fe4470b8c', 'Soya sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bd0f0209-f0d8-4481-bc7c-c6db11cf7665', 'Chill crisp', 'Other', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7d14ba59-24ab-49f8-b65a-bb68693e15bc', 'Beetroot paste', 'Sauces & Condiments', null, 78.8, 1, 'KG', 'Gram', 0.0788, '2026-06-01', 'inactive', null, '2026-06-01T09:00:00.000Z'),
('b9123422-9c7b-4b11-8ee6-584d34c0d6f0', 'Farfalle pasta', 'Grains & Flour', null, 405.3, 1, 'KG', 'Gram', 0.4053, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d6d16551-8e8c-4daf-bebd-fd4a300ed9e6', 'Burrata (smashed)', 'Dairy', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bce8bdf0-addd-4eb3-a4b5-58facd7e8f9f', 'Pumpkin seeds & pistachios (crushed & mixed)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6adc70e8-45bf-471c-94fb-15168f0873e8', 'Risotto rice', 'Grains & Flour', null, 384.6, 1, 'KG', 'Gram', 0.3846, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4bf08737-8962-42eb-917a-2a1abfa0e9a1', 'Confit cherry tomatoes', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5cf3b79b-668b-4771-aada-ce878a8f68d3', 'Pesto dollop', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9f916d6b-d9ff-410d-80f5-690fb4646a2d', 'Kalonji (chopped)', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('25caaa5f-c07e-4029-bb5b-0fd1b7908a67', 'Macaroni pasta', 'Grains & Flour', null, 72.7, 1, 'KG', 'Gram', 0.0727, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('088adebc-6ab2-4e31-804c-74d7b361571c', 'Cheddar cheese', 'Dairy', null, 850, 1, 'KG', 'Gram', 0.85, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cdd3958a-ac04-4f5c-aa50-6ae71a710b56', 'Mozzarella cheese', 'Dairy', null, 615.3, 1, 'KG', 'Gram', 0.6153, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8611b762-4b84-4b42-9a35-01c413fe8f07', 'Truffle oil', 'Oils & Fats', null, 5355, 1, 'KG', 'Gram', 5.355, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fc49c4df-fd31-4ee1-9b25-43bd6b0964e7', 'Truffle pâté', 'Other', null, 16670, 1, 'KG', 'Gram', 16.67, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('01761916-5d6f-43a9-a34b-9fba36bdd958', 'Sticky toffee pudding', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('35a59051-17a7-4f77-be40-4b94b4d725da', 'Caramel sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7d3868f1-8ac7-438e-9278-6b6938c39ad9', 'Pecan ice cream', 'Dairy', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2f976f1d-9dfa-4337-988e-fc2cb51d46a0', 'Brownie', 'Other', null, 650, 1, 'KG', 'Gram', 0.65, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('70c4349c-a3f7-4a16-bab4-d15f49d379ba', 'Cookies & cream ice cream', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('472c44c0-7333-4b13-b873-228826cd89d0', 'Nutella sauce', 'Sauces & Condiments', null, 566.7, 1, 'KG', 'Gram', 0.5667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4d9d5183-e0ee-4371-94ce-b4d64d37ddc3', 'Caramel tuile', 'Bakery', null, 800, 1, 'KG', 'Gram', 0.8, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('367b851c-de9e-4cf8-9a2b-3bbd456a5db0', 'Kunafa base', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b76ca1b7-d122-4b4c-beb0-16e98450306e', 'Pistachio sponge', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c466ce11-399b-423a-beab-d8e2fdbc8b4f', 'Pistachio mousse', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e746e4f0-52c9-4e99-b0de-0f412afc4ce1', 'White chocolate décor', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dad0278c-3d89-4172-8720-45d3d24d624c', 'Coffee sponge', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7a36f17c-adf9-48f5-a8fa-741e84412d83', 'Mascarpone mousse', 'Dairy', null, 826.1, 1, 'KG', 'Gram', 0.8261, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cbdba68b-784e-4c47-8dcf-d001b7cfd1e2', 'Coffee cream', 'Dairy', null, 750, 1, 'KG', 'Gram', 0.75, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f663447a-adc9-49d2-ac13-6ba7ba5ba503', 'Sable', 'Other', null, 214.3, 1, 'KG', 'Gram', 0.2143, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('57fef89f-ff90-4980-a8c9-0e8c0c579b0d', 'Tuile décor', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dc574485-1cb0-43d9-8850-087e540d05b1', 'Sugar syrup', 'Sauces & Condiments', null, 27.3, 1, 'Litre', 'ML', 0.0273, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ceeb2556-53e3-4ca1-a3ac-d1034336e6cf', 'Iced tea (Tata Gold)', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c076d5b0-3bfc-4b83-b41c-44f2967c5bdb', 'Mint syrup', 'Sauces & Condiments', null, 33.3, 1, 'Litre', 'ML', 0.0333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7feab776-8b53-4cb8-a352-3d90be5a2776', 'Kinley Soda', 'Beverages', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c9565d44-a4c1-4482-9278-519cbb336791', 'Kara Coconut milk', 'Dairy', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dfe97406-cc92-49a9-afa5-df0fb334ecc8', 'Pineapple jam', 'Fruits', null, 137.5, 1, 'KG', 'Gram', 0.1375, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cd40553d-2b30-45a3-893a-e6a12de340af', 'Vanilla ice cream', 'Dairy', null, 0.19, 1, 'Piece', 'Piece', 0.19, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b91bfa30-0a5a-4839-9e38-3fcba0053b0d', 'Fresh ginger zest', 'Vegetables', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('25226db1-6ec8-43a8-979c-569f89792fbb', 'Gunsberg Ginger Beer', 'Vegetables', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('35ec6646-b882-4e82-9797-468722c65af9', 'Orange juice', 'Fruits', null, 405, 1, 'Litre', 'ML', 0.405, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('baa1d1a8-09e0-431d-abc6-dcf00d954481', 'Hibiscus syrup', 'Sauces & Condiments', null, 66.7, 1, 'Litre', 'ML', 0.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d7e753f2-5563-45b2-8bd5-740edf43b93c', 'Sprite', 'Other', null, 104.4, 1, 'Litre', 'ML', 0.1044, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d7301c50-5075-4fd9-9b67-cd18e8a8e038', 'Tamarind syrup', 'Sauces & Condiments', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b37c8f01-8da4-45b7-aa79-aa534f8c4b99', 'Pinch of salt', 'Spices', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b5eb35ca-9ea8-4566-ad4a-7f8e1149a52c', 'Schweppes Ginger Ale', 'Vegetables', null, 166.7, 1, 'Litre', 'ML', 0.1667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4222f643-2a5f-45c3-9c6a-12498e536a52', 'Thai chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('df69d124-9e5a-46db-affb-53455388b9f3', 'Shiitake mushroom', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e064ed7b-8dc6-41b4-8c9e-cf7578d388db', 'Tamarind paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('09ce2d15-3646-45f6-9b3f-ce15ebbb92a4', 'Vinegar', 'Sauces & Condiments', null, 42.2, 1, 'Litre', 'ML', 0.0422, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c2a76ed8-bf3a-4213-be16-0e2f24ad9574', 'Spring Roll Sheets', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('02ad4ee4-ec27-46b4-963f-fa306ee8d2a2', 'Thai Spring Filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9f282e54-3211-4871-b925-7436b4eadb54', 'Sichuan Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b3dccbe1-c590-4b25-a66e-8e753aa503a9', 'Coriander Leaves', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('eefc3afe-7267-4e94-b310-1c50f5eb7d82', 'Spring Onion Slit', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b39d2f7-c94f-4276-a200-789ad5669a36', 'Sriracha Sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('848c0dc4-1f27-46cb-af07-0e719ee4d4d4', 'Black Vinegar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c25ae6db-a76d-4f31-9cb7-d5d9510f1cdb', 'Lotus root', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('06aec591-3edb-43c5-a0e3-6c93eb6d7d71', 'Lotus root sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d1c022c-b8f5-42bb-b387-fb110dad31c6', 'Pok choy', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('cffc6e81-fe43-44b2-b07f-f7640a995d29', 'Bell pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b79c495d-b77c-4a5f-8a69-bcd8bf39e506', 'Thai red chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dba43236-1c76-4a70-949a-d029d94a2403', 'Kwispy Wonton filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c7498a15-1d5d-44f4-ba3d-cdbacf114265', 'Gyoza skin', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d7600ec7-d1d3-4ef5-9ac3-b2a8d8065093', 'Chilli crisps', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6134b5ad-fbdd-4530-b2a3-8cb253dc10a6', 'Oil (for frying)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7fe39ff6-4049-40c1-bba8-ca8d5c6f6757', 'Rice cake (16 pcs)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('21ec8f0d-3ee3-4b61-a9fd-a9447a6cba66', 'Tteokbokki sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('598de8a2-a9e0-4782-9833-7cd04a9eab4d', 'Spring onion slit (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9bf9d7b2-d69c-4cab-bf1a-8b81cd327588', 'Bao', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('db9795c0-db2f-48e2-94dd-77f77179bab3', 'Tofu batter', 'Protein', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('94033b25-4a9e-47d7-942a-8703bb1e02df', 'Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f5881ff8-ea68-45fb-beff-19e694c23619', 'Coleslaw', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a5301845-0d0c-4943-833b-0f628ec23a08', 'Black & white sesame', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d0e1869f-713c-4c4f-8708-6220404186d2', 'Bao sauce base', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ac6d613c-77f1-49f5-b20d-f5154d5521c4', 'Water chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('79faf11d-9d74-4ef0-aa29-809d8f17d8f6', 'Water chestnut flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ee031ab2-7b8e-410c-b46f-43b89ecfb2d9', 'Gyoza dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('40b7ab25-7642-4c67-be34-92a84c24d06e', 'Yellow bell pepper', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d43009cc-3308-4a3e-a17d-66bf9c5a5b30', 'Red bell pepper', 'Vegetables', null, 246.2, 1, 'KG', 'Gram', 0.2462, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fb34032c-074f-4843-a431-520a729d5a67', 'Drunken sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72f6b4f3-4a47-403a-a2f5-5d75f88698d6', 'Fried spring roll (garnish)', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('56f42fb4-912b-41d0-9d9c-fe5db1d114d7', 'With pods edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6cd2adf8-f19b-4034-a176-d935263b2523', 'Chilli Crisp (for chilli version)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('20e2503b-1bb7-4797-ad96-4ed50c782896', 'Salt (for salted version)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('21c64484-f9a6-4048-be5b-46deb76d121b', 'Korean Mandu filling', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('832ebd1c-a19d-492c-92f9-efc207547cf2', 'Spicy mayo', 'Sauces & Condiments', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6f965fdb-037d-4a05-a689-bf9654b5e462', 'Coriander mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a0843506-ce82-4109-897f-9ce9e1715dcf', 'Toasted white sesame seeds', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5c563194-7036-43ec-9874-1a8671a252ee', 'Julienne cut nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('75d98d17-78dc-42dc-b8fc-36dcc2b6899f', 'Fried Corn', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9156efa9-1d5a-49da-9310-cc3cae5fca8d', 'Corn Rocks sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('18382255-f7e1-4944-80e4-473cfe758ea7', 'Chopped Black sesame seeds', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('638f88e5-80f3-4564-b59c-000e070050e8', 'Pickled red paprika sliced', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('905a351f-1354-41a7-b1b8-0ab9d049e719', 'Mayonnaise', 'Sauces & Condiments', null, 85.1, 1, 'KG', 'Gram', 0.0851, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('dc8fc9c6-ccfb-4cb8-a384-6fed184b3a2f', 'Sweet corn puree', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('902aad0f-8fe3-47bb-b101-560af06f55a4', 'Condensed milk', 'Dairy', null, 332, 1, 'KG', 'Gram', 0.332, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0c081522-0188-43be-98de-882a35b7825d', 'Garlic (minced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a9e5926a-0cc2-442e-ad88-1464fd388ada', 'Scallion Pancake', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('edd9a34d-5ed8-4eb2-b9b3-ddd37715a234', 'Sichuan soy glaze', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b9515e8f-51db-4413-b284-47af4b551ff3', 'Green garlic cream cheese', 'Dairy', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('850ffc40-59d2-4964-a82a-912d298b8655', 'Scallion salad', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('89386d5a-bb29-414a-9537-c5b0b8c0e8a0', 'Boiled soba noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c47259ca-6b03-4a85-b741-7bf5e8ac6156', 'Cold Spicy Sesame sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ae376267-aa80-4efe-b2a6-6660a45d3eb7', 'Cucumber slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dabf2735-767b-4cae-94e2-cbba9898d9e3', 'Carrot slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7d4dfe76-6695-402b-9bf6-f0ceef03b4a2', 'Fried sesame', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b9af543-ebea-4ff0-bebb-d096e5ce9413', 'Peanut (crushed)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1cfbd788-c4bb-4082-a7a0-4dd403c41c42', 'White Part Spring Onion', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6d6b5e91-d12a-45dc-a0e4-ddbfd59debc2', 'Mix iceberg romain slice', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('df65fe83-9622-4e3a-8f6b-b5e817420ac8', '00 flour (Biga)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('bcbf3bde-1fb1-45b1-9839-6fb15a5a1027', 'Water (Biga)', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8309b183-c302-4ec3-82d8-7475d3691141', 'Dry yeast (Biga)', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('11a2b2dc-f06e-434a-a39d-7fc1338a5566', 'Cold water', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f23ab4ca-f532-4c5b-8bf0-07d2e0d78f33', 'Dry yeast', 'Other', null, 178.4, 1, 'KG', 'Gram', 0.1784, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('61840ce3-e4d8-42cb-ab9a-ed379fc6196a', 'EVOO', 'Other', null, 1100, 1, 'KG', 'Gram', 1.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c4f17309-c295-4e20-962e-6c06107de07d', 'Katsu curry', 'Other', null, 1150, 1, 'KG', 'Gram', 1.15, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7747f820-d0da-4499-aad0-590e5547350e', 'Cabbage', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b29bd46-3183-4c8a-9b51-6d3401078159', 'Togarashi', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e49dc56b-cc40-4516-b7d2-e035fe9398ec', 'Sesame seeds', 'Spices', null, 290, 1, 'KG', 'Gram', 0.29, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ab7ac85e-7f64-4a97-9391-5e1f0e072108', 'Jasmine steamed rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b230ebdb-feb9-42f3-bf1b-da8c2b289876', 'Scallion oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b74c19fa-1ef5-4b7c-9082-8403e0b5bd5d', 'Unagi sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c1dd247c-0e38-40a8-8fc0-12987b92a5c5', 'Zucchini', 'Other', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0aae595d-00db-4a73-b17b-8d7533ef6f08', 'Baby corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1f7fabc5-7cc5-4583-999c-dbf021e102a4', 'Green paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0d0203a2-1451-4035-9bd8-e257a9bb9518', 'Jasmine rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b4da1471-debf-457c-a825-36547e2306f0', 'Sesame mix', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d95b94c8-fee1-4a08-9940-96bd9136873f', 'Lotus stem', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('23f68aa6-859c-47aa-b737-058e15d76d5b', 'Chilli oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2a519242-b96b-4127-ba2e-d6f585666d72', 'Fresh Sri Lankan Red Curry Powder Mix', 'Spices', null, 3000, 1, 'KG', 'Gram', 3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f1665d26-d3be-4b32-aac6-f43fdcc3cff8', 'Picked red paprika', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('59176e96-8e2d-4898-8849-ac0328adebc3', 'Chilli Garlic Sauce - Sunflower oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c03b9e1d-1017-4207-8cfa-b86962d0b0f8', 'Chilli Garlic Sauce - Chopped garlic', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('dc55d948-53f8-4bac-bb81-b42e464e9db1', 'Chilli Garlic Sauce - Soy sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('228b5fb6-1215-4d7c-9889-2b6c7101924c', 'Chilli Garlic Sauce - Hot sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d372b216-6831-4895-af96-7d85cf60d091', 'Chilli Garlic Sauce - Wok hei sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('169ffee3-d123-470d-81d1-eb5b7f684cc5', 'Chilli Garlic Sauce - Thai red chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ea7e30f4-708a-4dfd-a9d5-e284d5d5016d', 'Wok Hei Sauce - Chilli bean', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7886a70d-a983-42aa-ad76-ec60bc2ebf20', 'Wok Hei Sauce - Shao hsing', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6b4ef3d2-70cf-4376-8142-7b6aa33be870', 'Wok Hei Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('02b89b49-9778-4fbc-ab19-3806de9e9eab', 'Wok Hei Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2230b49c-9f7f-440c-8696-37c3e4ac2232', 'Wok Hei Sauce - Cinnamon powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a3b7a3f4-0f14-484f-b63c-64f2991a4841', 'Wok Hei Sauce - Sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0b507885-d638-4846-a1dc-73a6d22280f8', 'Wok Hei Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1c48167b-8d6b-4ec2-98e7-770b1db8d478', 'Teriyaki Sauce - Brown sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('72530920-0a5f-4a78-a4c8-dbd877967f15', 'Teriyaki Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7183eaf2-4327-4fa1-93fd-e7bc92f3d2e2', 'Teriyaki Sauce - Rice vinegar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4547ba4a-1938-4a78-8df8-ea170f7b9c7c', 'Teriyaki Sauce - Corn starch', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9685cb61-1e2e-4e40-b140-4d403d06a082', 'Teriyaki Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('03ceaa82-a1bb-4107-b702-d178defdec8b', 'Teriyaki Sauce - Sesame seed', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c0e09eac-e19e-4b88-8fce-47c077c18820', 'Yaki Soba Sauce - Black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('008ac7b8-593e-4e76-b43c-1a332d92788c', 'Yaki Soba Sauce - Crushed black pepper', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c6bde583-063f-4149-9425-3c1985858f81', 'Yaki Soba Sauce - Oyster sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5912a188-e049-4365-bbe6-63c39e0b736a', 'Yaki Soba Sauce - Soy sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b28a623a-9624-4129-b3f1-fbc05c83881b', 'Yaki Soba Sauce - Sugar', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1a471279-2680-4a52-b1d3-4e5858eb14c4', 'Yaki Soba Sauce - Corn starch', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d1e9b458-f31c-4cc6-ba54-a92b63d64d03', 'Yaki Soba Sauce - Water', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6fc0a5f2-5e7d-4363-a4b7-8b2a40bf76ea', 'Yaki Soba Sauce - Hot sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d8f03c5b-e55e-451b-a485-d8939cafb422', 'Chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e888d241-8d9f-4324-b4dc-2e7a21b468a8', 'Red Bhavnagri chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d4aace4-4a98-4db1-962b-75e665543749', 'Slurry', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('50793770-2eb2-48d9-84df-2be1787b97b0', 'Gyoza wrappers', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1b59ea26-ee77-4b0e-abe4-4af74dcb2511', 'Oil + Water (for steaming)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d8a954c5-54dd-45ce-8b99-2602f9a86936', 'Ginger (paste)', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b8235517-3b00-446c-938a-881d53d39340', 'Chinese cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d5805b8e-a5a9-455b-9627-69b4e1507263', 'Indian cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7073ee5b-13e5-4b8c-9fa0-70c3c06530fa', 'Chilli besan paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('c1d52d83-ae6f-4b2e-8c06-4017ebc1f6e7', 'Gochujang', 'Sauces & Condiments', null, 648, 1, 'KG', 'Gram', 0.648, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5202fb5a-4978-4f97-b75a-10c6694312e0', 'Soy', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9fde4e6f-b536-4a5f-b479-8fa9b2109760', 'Sesame oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('683c3a5f-fcff-496c-997d-65cad1ff1f93', 'Stock pwd', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('54830bff-7748-4a5d-811e-67197308431c', 'Boiled soy keema', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('07eccbf4-b7a5-4602-a53a-8310a5867fbb', 'Coriander leaf', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('44ec297e-7987-4be0-a63d-cb5372b7c66c', 'Coriander stem', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('454616c5-de73-4638-8205-8e58542cf2bd', 'Pickled ginger', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ebdd81fd-431f-4303-827f-67bcdeb79b3e', 'Tempura flakes', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('273a7d93-4113-48ad-80f8-88276fc1360a', 'Ketchup', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1b75debc-bb17-4290-9067-f91d93bf52af', 'Maple', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ad3059ff-69fd-4864-bbd9-4ef9784b3507', 'Oyster', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d67e735-9a8e-4544-8532-79d647ca8a95', 'Rice vinegar', 'Sauces & Condiments', null, 4428, 1, 'KG', 'Gram', 4.428, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a7dc6d5f-e42c-436c-8c2c-ac4fdf612e92', 'Flour', 'Grains & Flour', null, 44.4, 1, 'KG', 'Gram', 0.0444, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6cac5457-edcc-4923-a38a-db3df73aeb5d', 'Salt (pinch)', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('756401a8-6f4b-4650-a08d-2cccd045b20d', 'Mayo', 'Sauces & Condiments', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5f33af7e-8152-4c21-93ae-d7d37ee90b61', 'Mustard', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f96475bd-bace-43c9-94e4-227ae6e939f9', 'Blanched edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f08858dc-f2bc-4b6f-8fa8-005a3ef5bfaa', 'Truffle pate', 'Other', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('7139ea61-b23e-4d08-bc3b-707b6e4358aa', 'Wrappers', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('24fcb6f9-61fe-42d1-be9d-aecb49b8b6d3', 'Silken tofu', 'Protein', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'Gochugaru', 'Other', null, 2000, 1, 'KG', 'Gram', 2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6bfc7d07-82c0-40d1-996c-008354459b6e', 'Coconut cream', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f9599b54-3bae-49dc-b916-9756b3bb239f', 'Honey', 'Sauces & Condiments', null, 270, 1, 'KG', 'Gram', 0.27, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5a7cd88e-5b3c-4c2d-876e-ba0106d3df3f', 'Shaoxing wine', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9d8d8006-8eb7-41c1-97f4-8671d3130597', 'Jalapeños', 'Other', null, 241.7, 1, 'KG', 'Gram', 0.2417, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('220cf9a0-8817-45bb-8d7b-852e5556d9ac', 'Green Bhavnagari chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('695cc3a4-779f-4ed5-98fc-150e049f7d4f', 'Kaffir lime leaf', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4bc77508-6a79-4208-88e9-a0c1274eaaee', 'Lemongrass', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6664fa17-1c50-4cc3-80d4-956f1d913a3a', 'Cumin powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8ed08113-3a60-40f1-8d93-31ad1478fe05', 'Hing', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('481a34e2-aca5-456e-901b-999e30dda6f1', 'Pickled red Bhavnagri', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('73db67a5-e704-4d74-8148-e5892408fc18', 'Chilli Oil Dumplings filling', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d1f53be8-9f9d-415b-9ad9-d3374676bad8', 'Red chilli powder', 'Spices', null, 898, 1, 'KG', 'Gram', 0.898, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('3c9b843f-3890-4d4e-901c-4b9074f6779c', 'Chilli Oil Dumplings paste', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0b6fef37-528d-4e91-ba5b-5cab299314b6', 'Sichuan powder', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b5949e0c-4172-4608-968c-b9a29714fd89', 'Toasted Peanuts', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f287ce73-061b-4e62-9bbb-aec2ecfd17bf', 'Green spring onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('256f5117-f526-4827-a8c7-f4eacf160e9c', 'Fried glass noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2c7d53ac-4eb7-4e68-b6fc-8448c97280b7', 'Saucy Momos', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1147e35d-4ba9-40f4-a9b4-f61712249490', 'Forest Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3f64d465-8fb8-4116-8192-5595a39f917a', 'Truffle Edamame Dumplings', 'Other', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ea6d17a4-e9c4-49ad-a99e-489d185f2725', 'Cheese & Chilli Dumplings', 'Dairy', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7e0ac97a-be2a-42db-a99a-9db8394d74b1', 'Chestnut Gyoza', 'Bakery', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('95817f33-4d42-49d0-9c36-7661c72e4a95', 'Broad Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fcd5bd3b-717b-4638-b6bf-f1feaf977f5e', 'Chili Crisp', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ce59bbd2-fb47-49e8-9433-9389e7233976', 'Forest Dip', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3bc831a1-e2d2-4e87-868a-63621c5fc512', 'Red Momos Sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('5035709a-1cec-4aad-968f-9c56626a59be', 'Nori', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7a0c9dba-598c-41e7-9e6b-c38206a76e8e', 'Buffalo sauce', 'Sauces & Condiments', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a63bfbdb-aeee-46e2-a0f5-8b3a16dde263', 'Avocado', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3cfa0475-eef6-4e3f-acb9-f0772cefc037', 'Rice paper', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4fba861b-6fa7-4583-9781-9c3a051d709b', 'Soy sauce', 'Sauces & Condiments', null, 266.7, 1, 'KG', 'Gram', 0.2667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d6695677-6412-4b38-a9df-30eb0d88b411', 'Nori half sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d28298c8-e41e-46b8-af34-bba6726922fc', 'Fried stem lotus', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('253f3bad-f9e1-4e23-b743-b0c13dd039f5', 'Dragon sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('18ba6eff-b47a-417f-bd4a-597e13bfd7d9', 'Nori sheet', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('561f0379-9826-4e23-9148-6efb03a2d521', 'Alfanso mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('125b16de-b2cc-4470-8653-b953ba86afff', 'Chilly crisps and oil', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('09d4fef0-2b9f-4797-afb2-13e9a5b75f18', 'Ginger pickled', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1c0435e3-2fd6-42ab-a591-7676b8fd3647', 'Wasabi paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0f7bbee9-794f-4c39-80dc-b0ba734af1ec', 'Micro greens', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('437c28e7-88d7-4276-9c74-d30914fa5a35', 'Nori sheets', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fad12371-01a2-4599-aab7-b98d61eb8a77', 'Fried Tofu toss on soy', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('84f34ee0-120b-40c5-876f-9d22c9581066', 'Unagi', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('7d18d48e-81c7-443b-a39a-f4b25cd3d60c', 'Pickled radish', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e78e9717-194e-4d99-91fa-2925b4823168', 'Sautéed spinach with soy & garlic', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6ba6c4fe-0a7a-4fb6-a92f-83ffa333e10c', 'Sesame oil (for brushing)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a6d9389a-1fd9-4fca-b034-4a4ff9fd7997', 'English cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('63d64b84-3a88-4947-a73d-35e0dc2f5b9b', 'Red capsicum', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('41e42836-7df7-40ff-b131-f7fe1b73e994', 'Jalapeño', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aa1ac125-7eeb-44ff-bccb-d8cb30260037', 'Tempura flex', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('160b685a-82b5-4fd6-80ba-7cbc9221e4b0', 'Salsa', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('16c0cd76-0280-4403-a3b4-5fd331b8b281', 'Sweet chilli sauce', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('b389fac3-6da2-4345-beb5-204a4e284b41', 'Sriracha', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('855a337f-b27e-4f59-abd2-359cbf36ee6c', 'Raw mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2bc2967c-a780-4710-bd84-334645187e95', 'Fried spring roll', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3d44872c-8d24-4ff2-b5fa-ea27162ff16b', 'Purple cabbage', 'Vegetables', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1c54379a-05ec-4b75-ab1a-6614100770fe', 'American corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a718562d-240b-43cd-a422-a4247c1b56ef', 'Tempura flour', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('03673e58-9552-4194-88a5-68031ad44d43', 'Ginger (minced)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d01f3a1b-a6e0-4c08-8dfd-d6290cf0a114', 'Corn', 'Vegetables', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8c675294-f937-4636-8811-78790b53b927', 'Edamame', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('16e7777d-d747-48c5-85fb-613d4586b4b7', 'Cooked rice', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('4c2f89f0-370b-4328-8db8-f6620c58c107', 'Light soy', 'Sauces & Condiments', null, null, 1, 'Litre', 'ML', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('34f930ff-6253-4b91-a796-24f7626ab625', 'Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c7f09580-60b9-411d-bf40-d7199249f543', 'Spinach', 'Vegetables', null, 114.3, 1, 'KG', 'Gram', 0.1143, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('515daeaf-2242-42db-b8f0-b09b2b44d90b', 'Button mushroom', 'Vegetables', null, 71.4, 1, 'KG', 'Gram', 0.0714, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ca98e3bb-331b-4f8c-ae34-6e193c109ed9', 'Chili bean paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('1922aa7e-834d-4818-a40d-5d5dbbe1f4ea', 'Oyster sauce', 'Sauces & Condiments', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('cb08bafd-48c1-4229-a630-379097621d50', 'Ginger-garlic paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9aa19f39-1212-4e18-b2c6-0d115c678280', 'Boiled hakka noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('02540286-c40c-46b3-a647-4fa9d3c2668d', 'Hakka sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6a342edc-057a-4478-82e4-d3467c598ce3', 'Mixed mushroom', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('fd397589-15da-4555-ab30-dcb73a169eb6', 'Spring onion whites', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f29c72a5-ebab-4029-a2fc-470820e00315', 'Flat noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2fa71201-e164-4d25-9450-4d5fad4a30a8', 'Bean sprouts', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ef8d5829-ae95-4b28-abb5-cc56b0b0ffc4', 'Thai basil', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3f553a9e-2fd2-43e8-bc80-ef846303fe4f', 'Mushrooms', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('566f2b2c-ca47-4164-92bc-70bc6404343b', 'Rice noodles (soaked)', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('a3c1c6f1-3dc0-4f44-a0ab-b3beb4c4ecde', 'Pad Thai sauce', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('6e92a078-b40d-4789-afb9-a50fe5802968', 'Roasted peanuts', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('8dace206-ff84-4e4d-834e-8115fa1a54aa', 'Lemon wedge', 'Fruits', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('65882cc0-5119-4843-9ef7-1bc9c4be1f53', 'Maida noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('f1568afa-11d6-4eb7-8277-7c9d41660600', 'Veg stock', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9ada312e-b73c-4ee2-98dd-abd6ece4683d', 'Dashi', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('3564d0b2-ae52-4f75-9932-6e6a1488128d', 'Shoyu tare', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('e4f23d69-97b0-4b5e-948f-c973ad5bd748', 'Ginger paste', 'Sauces & Condiments', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('9da0289c-7689-4604-893e-973cef11bf72', 'Garlic paste', 'Sauces & Condiments', null, 180, 1, 'KG', 'Gram', 0.18, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('463ad216-f76f-45db-923a-7d61c9633171', 'Chilli bean paste', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('ffe2bcc5-e4de-4773-ba81-3f1f39be3c81', 'Peanut butter', 'Dairy', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d2930eb1-2755-4370-a038-f6e40b19deaf', 'Ramen noodles', 'Grains & Flour', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('234b5cdc-45af-4dff-8b94-68927d087494', 'Caster sugar', 'Bakery', null, 101, 1, 'KG', 'Gram', 0.101, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4234d7fa-5ce3-4c76-b43a-348f08884128', 'Chilli powder', 'Spices', null, 1066.7, 1, 'KG', 'Gram', 1.0667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('1141a3a3-e52a-4aeb-821e-f9e1dd49524e', 'Peanuts (roasted)', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('74fec152-ace2-4342-8307-ef7123124ee1', 'Coriander (chopped)', 'Vegetables', null, 182.5, 1, 'KG', 'Gram', 0.1825, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c67b39df-a7a0-4b71-a19d-d5318a4468b4', 'Spring onion (chopped)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2ba9a2e7-a77f-4618-835d-f0016341136f', 'Edamame (boiled)', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('d1f8eb7e-1cdd-449d-9fce-a92e1e9ef4cb', 'Pokchoy (blanched)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('2932c2ea-76af-44dd-aa59-d95015a6f5e2', 'Lemon wedges', 'Fruits', null, null, 1, 'Piece', 'Piece', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('71e0a0ab-983b-4d27-ac15-aa666e66bc4f', 'Chilli crisp', 'Spices', null, 160, 1, 'KG', 'Gram', 0.16, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0650dd76-be04-4197-bbc5-8dc21acb04d6', 'Boiled noodles', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('214dc597-c51f-42a1-af2b-63ec6306ec03', 'Spring onion (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('771e0b3e-5764-4e1e-a2c2-f36d30f03500', 'Fried garlic (garnish)', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', null, '2026-06-01T09:00:00.000Z'),
('0a3c18bf-817f-4961-9e58-7154da69d3be', 'Spicy Pomodoro Sauce', 'Sauces & Condiments', null, 239.4, 1, 'KG', 'Gram', 0.2394, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9b093342-1c59-474f-a417-773d07d180c2', 'Capers', 'Other', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ea20e218-253c-44f8-9da6-ded4adfd4a80', 'Garlic Ricotta', 'Dairy', null, 425, 1, 'KG', 'Gram', 0.425, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4560e708-ce2e-412d-961d-413d22a8504d', 'Basil Pomodoro Sauce', 'Sauces & Condiments', null, 202.6, 1, 'KG', 'Gram', 0.2026, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('d382930a-f357-453f-918c-67b929134672', 'Garlic slice', 'Vegetables', null, 285.7, 1, 'KG', 'Gram', 0.2857, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a61a0675-cf31-46c4-9997-fbf246d76b4b', 'Artichoke', 'Other', null, 1020, 1, 'KG', 'Gram', 1.02, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4fe30af2-af5f-4460-b62e-3ddde73a4c21', 'Feta cheese', 'Dairy', null, 950, 1, 'KG', 'Gram', 0.95, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aa0f2624-00c6-4704-a6a5-61b6ea129d8f', 'Marinated Arugula', 'Vegetables', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'Amul Fresh Cream', 'Dairy', null, 206.7, 1, 'KG', 'Gram', 0.2067, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8b7d5cca-5ea5-406b-851a-20489eb19f1b', 'Basil Pesto', 'Sauces & Condiments', null, 408.5, 1, 'KG', 'Gram', 0.4085, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'Buffalo Mozrella', 'Other', null, 920, 1, 'KG', 'Gram', 0.92, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c11ea5a3-dd5d-4de4-b133-d34988cd788b', 'Garlic oil', 'Oils & Fats', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6c74c12a-fab2-42b9-a208-81b114e5a205', 'Gochujgaru', 'Other', null, 4666.7, 1, 'KG', 'Gram', 4.6667, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8def8b2e-3bc2-4169-a870-8ffb8a011714', 'Buratta cheese', 'Dairy', null, 929.4, 1, 'KG', 'Gram', 0.9294, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('834cc6ef-af07-41f1-9434-8ba8ad00cfcc', 'Dil leaves', 'Other', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e10f7609-b3c4-41a5-b29d-ae9644704c25', 'Chiili crips oil', 'Oils & Fats', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('aaa1e504-a5f7-40c6-a3b7-e2d638c16789', 'Corn mix', 'Vegetables', null, 321, 1, 'KG', 'Gram', 0.321, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a5c4493b-e03d-42be-be8e-5b26d78400e6', 'Jalapeno slices', 'Beverages', null, 80.3, 1, 'KG', 'Gram', 0.0803, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('82a0e142-3489-4d4c-90c2-a3d666fc69b3', 'Garlic slices', 'Vegetables', null, 269.8, 1, 'KG', 'Gram', 0.2698, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('9cd15336-68a7-4e36-8b30-cf0b6c8a8a5a', 'Black sesame (crust)', 'Spices', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('90eaca47-c3ee-480d-99c8-1365c08d6257', 'Chilli butter dollop', 'Dairy', null, 509.2, 1, 'KG', 'Gram', 0.5092, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('e4183250-a90e-4b96-b780-c93365e940c3', 'Dynamite crunch', 'Other', null, 464.5, 1, 'KG', 'Gram', 0.4645, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('0b975a61-a821-4e66-9338-3f82c3f7f795', 'Slice garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5991bc4e-5409-44a6-ad2d-3a3da35ce73f', 'Chooped garlic', 'Vegetables', null, 300, 1, 'KG', 'Gram', 0.3, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('138e3058-e202-4dbb-99a5-324958443b00', 'Red Sriracha', 'Other', null, 481.6, 1, 'KG', 'Gram', 0.4816, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('df34e647-3d1c-4931-888f-da5782366d48', 'Smoked cheese', 'Dairy', null, 603, 1, 'KG', 'Gram', 0.603, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c9c12814-8d92-4aa3-b6a6-95a1ffa5fc80', 'Honey butter drizzle', 'Dairy', null, 433, 1, 'KG', 'Gram', 0.433, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c46319b2-118e-4a00-bbd2-376338aa830d', 'Chimichurri (chunky)', 'Other', null, 826.4, 1, 'KG', 'Gram', 0.8264, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6cb9b849-fae1-4d1f-afd1-6d95775e70bc', 'Whipped feta dollop', 'Other', null, 949.7, 1, 'KG', 'Gram', 0.9497, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('f8dd8228-1e49-41b7-adea-e546f07fb51d', 'Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('43bfeb00-2a28-4a30-bb39-7c1d0948a120', 'Black olive', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('43f9f6a9-9cce-4cc0-8022-2e6c0584488c', 'Green Bellpaper', 'Vegetables', null, 90, 1, 'KG', 'Gram', 0.09, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('22c2b923-aa80-4c97-b8a4-ac84671ead71', 'Marinated Aragula', 'Other', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ac5db4fa-e431-469a-9248-e4571dfc3676', 'Slice almond', 'Bakery', null, 834, 1, 'KG', 'Gram', 0.834, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('25dd0bb4-95d5-4fa4-ab0b-3eacdca1bbba', 'Green Chilli', 'Spices', null, 142.9, 1, 'KG', 'Gram', 0.1429, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4ae0e38f-0bb8-442b-9f6e-dd6c76635098', 'Black Sliced Olives', 'Beverages', null, 214, 1, 'KG', 'Gram', 0.214, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('160f1321-fac1-4206-baab-37c2fab8184a', 'Ring bell pepper', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('ee9c31c3-a172-43f3-8e04-5a8d85fb42a3', 'Ring onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('c96ecd37-d69f-4182-a75e-857e97d5781b', 'Chili oil', 'Oils & Fats', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('8a8f8397-fb90-463d-91e0-959a8181a52a', 'Ghost Paper', 'Other', null, 4000, 1, 'KG', 'Gram', 4, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('07db63a4-0467-4c9b-ab2c-2d8b2bdf0fef', 'Roasted Bell paper', 'Vegetables', null, 253.8, 1, 'KG', 'Gram', 0.2538, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('52692793-8246-436b-99ad-f5de5750e7ec', 'Red Paprika Slices', 'Spices', null, 208, 1, 'KG', 'Gram', 0.208, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('fe098028-6d11-4079-b24b-1e38e55cbdd1', 'Fresh Jalapeno', 'Other', null, 360, 1, 'KG', 'Gram', 0.36, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6bb4c70f-8e89-4a2b-b8f1-b38647d4899c', 'Green Sriracha Sauce', 'Sauces & Condiments', null, 345.3, 1, 'KG', 'Gram', 0.3453, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('a8377117-24ec-47f4-8f76-c5d4552f680f', 'Ghost Peper', 'Other', null, 5710, 1, 'KG', 'Gram', 5.71, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('b42ebb0a-2925-44e3-9743-59cca77065bc', 'Buffalo Mozzarella', 'Dairy', null, 820.8, 1, 'KG', 'Gram', 0.8208, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('126a85f6-63b8-4863-8c51-cc1fbe99aff7', 'Boiled Broccoli', 'Oils & Fats', null, 455, 1, 'KG', 'Gram', 0.455, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('4f3f4847-e274-4bf3-85f7-4f8c58f9c811', 'Red paprika sliced', 'Spices', null, 312.5, 1, 'KG', 'Gram', 0.3125, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('5f645e09-ce60-409a-bbd1-413b249bd151', 'Jalapenos', 'Other', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('bf8a8a9c-439a-40df-92ff-0c699b5820bf', 'Orange sauce', 'Sauces & Condiments', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('6b54c227-dad1-4a31-a92d-d29c102ecc46', 'Ornage sauce', 'Sauces & Condiments', null, 227.5, 1, 'KG', 'Gram', 0.2275, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('2a70accc-d184-4c07-8b04-1527b533dfb5', 'TRUFFLE PASTE', 'Sauces & Condiments', null, 20676, 1, 'KG', 'Gram', 20.676, '2026-06-01', 'active', null, '2026-06-01T09:00:00.000Z'),
('80556862-df27-4f12-bf09-8b648d12a118', 'Processed Basil Leaves', 'Vegetables', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('45549a09-8ea1-4db5-8b24-1448e891da35', 'Processed Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('2898ea19-0ff1-46c6-94fc-a64a545073cf', 'Processed Coriander', 'Vegetables', null, 131, 1, 'KG', 'Gram', 0.131, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('c0123692-4436-40e3-8fbc-ceb60f5d32db', 'Processed Dill Leaves', 'Other', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('180f217d-1648-44e4-b3b0-d7a3309e3dac', 'Processed Green Garlic', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7eecb87f-008b-4699-83d9-9b9917339fe6', 'Processed Iceberg', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('3c7fdbba-3cf0-401a-bd22-e865507f16e2', 'Processed Mint', 'Other', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('d05b5ada-f1a5-4835-ae78-cce37e0e1bc1', 'Processed Alphonso Mango', 'Fruits', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('2d2ba4f4-b247-43d3-9845-63af45b75409', 'Processed Arugula', 'Vegetables', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('8eb8952d-b5a3-48bf-8225-7d143d234863', 'Processed Jamun', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7f627034-3990-41a8-8fef-21cd9c9e9ba0', 'Processed Red Chilli', 'Spices', null, 80, 1, 'KG', 'Gram', 0.08, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f4075c49-8af6-42cc-9951-647b175f62e6', 'Processed Brussels Sprouts', 'Vegetables', null, 900, 1, 'KG', 'Gram', 0.9, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f1c20c6a-3e28-48f9-a496-ecd80c1a0311', 'Processed Lollo Rosso', 'Other', null, 333.3, 1, 'KG', 'Gram', 0.3333, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('4c3f96db-2b61-49c4-9faf-ea5b86ce714d', 'Processed Shimeji Mushroom', 'Vegetables', null, 1300, 1, 'KG', 'Gram', 1.3, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7f4067d7-79ce-413a-b30e-8c7ca9ec0b36', 'Processed Pineapple', 'Fruits', null, 146.2, 1, 'KG', 'Gram', 0.1462, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('0348b3d7-3384-446b-8c51-d41852bc8813', 'Processed Thai Red Chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('ee88aa37-a381-4b5c-a556-f6ed3761757e', 'Processed Bok Choy', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('526b97b6-3bf5-4fff-b23b-4ccc6a65ceae', 'Processed Lemongrass', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('f74fe980-f42f-4eeb-a489-46c6f37e7fcb', 'Processed Spinach', 'Vegetables', null, 114.3, 1, 'KG', 'Gram', 0.1143, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('b0e9adc4-0363-43a3-9367-080cd2bf0f9f', 'Processed Baby Corn', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('364a28db-9c1c-409f-b483-b60bec1a3875', 'Processed Leeks', 'Vegetables', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', 'Prep yield (Processed)', '2026-06-01T09:00:00.000Z'),
('7b4cdb1c-3fbe-4c44-af43-88b7e1a1a13f', 'Chopped Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('14e6adcb-3579-47f7-a420-99cf57c9b05d', 'Chopped Green Chilli', 'Spices', null, 122.5, 1, 'KG', 'Gram', 0.1225, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('02158949-055f-479b-9b10-f4a8b6bba215', 'Chopped Green Garlic', 'Vegetables', null, 507, 1, 'KG', 'Gram', 0.507, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('e5c02f54-e81a-466b-a2a7-b95002e2f747', 'Chopped Parsley', 'Vegetables', null, 400, 1, 'KG', 'Gram', 0.4, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('031fa0e7-26b9-443b-8e23-d54ed77573fa', 'Chopped Spring Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('024d597b-ef06-4c8b-bec8-5e8fe0040889', 'Chopped Tomatoes', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('b3575ff0-ea88-4e01-add1-c672e58e79ae', 'Chopped Carrot', 'Vegetables', null, 56.2, 1, 'KG', 'Gram', 0.0562, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('202883da-349e-4c7f-8ce8-dd106c075e0f', 'Chopped Ginger', 'Vegetables', null, 128.8, 1, 'KG', 'Gram', 0.1288, '2026-06-01', 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('dcf6468f-6842-43e1-808f-3c34d82528fe', 'Chopped Green Bell Pepper', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('358bdfa6-2faa-411c-ae42-984290262c4d', 'Chopped Chinese Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('34e0107e-0bdd-4ed7-912e-a99dcad42917', 'Chopped Indian Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Chopped)', '2026-06-01T09:00:00.000Z'),
('0b4df83b-513c-4e54-99c1-77a66174e0eb', 'Sliced Jalapenos', 'Beverages', null, 250, 1, 'KG', 'Gram', 0.25, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('32a2f65c-cd11-43ed-ba10-15608edabbf4', 'Sliced Zucchini', 'Beverages', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('a4b20573-b3ad-41d5-8719-df1fb4331bcb', 'Sliced Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('35561be3-1536-4c2c-accc-32a61eb643f7', 'Sliced Cucumber', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('3792df9d-0367-45e9-abad-6b75949c51ab', 'Sliced Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('2cd55db5-dc26-43ce-b0c6-d1aec234500d', 'Sliced Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('4034f46a-9c2e-48ac-b202-3a2a9e6f0637', 'Sliced Lotus Root', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('c0765f81-8300-44bb-aa76-0c33ad05d16d', 'Sliced Purple Cabbage', 'Vegetables', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('783c1a6a-404b-4daa-92fd-001fdd6c7e44', 'Thin Sliced White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Prep yield (Sliced)', '2026-06-01T09:00:00.000Z'),
('b51f81d3-291e-49ec-bf2c-9f979a136408', 'Cut Broccoli', 'Other', null, 364, 1, 'KG', 'Gram', 0.364, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('1e1624e6-a87b-4da3-982c-76c470514e43', 'Cut Carrot', 'Vegetables', null, 57.1, 1, 'KG', 'Gram', 0.0571, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('9caa93e7-134e-49b8-9f2d-7161b2e97e6e', 'Cut French Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('1d0bb53c-67b8-4573-93ec-83f9108485b6', 'Cut Zucchini', 'Other', null, 134.4, 1, 'KG', 'Gram', 0.1344, '2026-06-01', 'active', 'Prep yield (Cut)', '2026-06-01T09:00:00.000Z'),
('0d43417a-0b19-4e89-8ec4-a04c818b32af', 'Bell Pepper Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('429fdc98-6460-4a01-8d75-37054a322bf7', 'Cucumber Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('c75c2602-153f-41b7-8a95-1fdb667211f5', 'Onion Rings', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Rings)', '2026-06-01T09:00:00.000Z'),
('cebef12e-afa1-483a-a66e-7f59b88d26d8', 'Diced Onion', 'Vegetables', null, 66.7, 1, 'KG', 'Gram', 0.0667, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('5a62a00d-fc75-4124-8610-40bee4997d2c', 'Diced Grapefruit', 'Fruits', null, 1142.9, 1, 'KG', 'Gram', 1.1429, '2026-06-01', 'active', 'Prep yield (Diced)', '2026-06-01T09:00:00.000Z'),
('6d50a7b7-4a04-441b-a421-572506aef5a0', 'Lemon Juice', 'Fruits', null, 311, 1, 'KG', 'Gram', 0.311, '2026-06-01', 'active', 'Prep yield (Juiced)', '2026-06-01T09:00:00.000Z'),
('e6166a0f-3a9a-4f91-ab0e-f393c3a024a8', 'Watermelon Juice', 'Fruits', null, 83.3, 1, 'KG', 'Gram', 0.0833, '2026-06-01', 'active', 'Prep yield (Juiced)', '2026-06-01T09:00:00.000Z'),
('b01acf11-121d-40df-a9c6-ff46a0474ea4', 'Whole Mushroom', 'Vegetables', null, 280, 1, 'KG', 'Gram', 0.28, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('fd0196c8-05a5-4b43-af5a-5509d65c84af', 'Whole Parsley', 'Vegetables', null, 432, 1, 'KG', 'Gram', 0.432, '2026-06-01', 'active', 'Prep yield (Whole)', '2026-06-01T09:00:00.000Z'),
('bb7015b8-d5f3-4d3a-847e-d6aa0b05f642', 'White Spring Onion', 'Vegetables', null, 100, 1, 'KG', 'Gram', 0.1, '2026-06-01', 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('acf41b78-8083-48e0-83ff-78ba8e8a9be6', 'Slit Onion', 'Vegetables', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('b7a33c08-9d81-4684-a156-0c38a017603a', 'Spring onion 1/2', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('cafde0e3-3a6e-4552-8c74-6e806d8abdec', 'Dried Sirarakhong Chilli', 'Spices', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Other Prep)', '2026-06-01T09:00:00.000Z'),
('52067809-fa39-4c12-966d-c2c88c50179f', 'Dolce Vita Peeled Tomatoes - 3kg', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('205f8941-fc46-4fb0-ab88-b7da90d22604', 'Black Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('96bd5b5e-a854-474c-92d7-456f0e7fbd7f', 'Red Kidney Beans', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('e4e29635-cc3e-4e0e-9090-c80fcf861640', 'Artichoke Hearts', 'Other', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('f34c8751-76ba-4edf-9770-c6c60328c6e9', 'Capers', 'Other', null, 1200, 1, 'KG', 'Gram', 1.2, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('93330f3c-e379-4fac-854a-a6ee8a372b34', 'Sliced Red Paprika', 'Spices', null, 312.7, 1, 'KG', 'Gram', 0.3127, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('52570014-8255-4944-b161-ce9836cb19b9', 'Black Olives', 'Other', null, 600, 1, 'KG', 'Gram', 0.6, '2026-06-01', 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('97f4a898-9b82-498a-a011-d5a17aac970d', 'Jalapeño Slices', 'Beverages', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('b200ca65-fc0b-4ff5-b43b-f6b95f703240', 'Water Chestnut', 'Bakery', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Canned drained weight)', '2026-06-01T09:00:00.000Z'),
('77e24995-6722-47aa-980e-f5e44957f24e', 'Boiled Spaghetti', 'Oils & Fats', null, 110.5, 1, 'KG', 'Gram', 0.1105, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('8e4a1d5b-c8f3-4182-a9e9-1083cdfd3a3a', 'Boiled Macaroni', 'Oils & Fats', null, 101.8, 1, 'KG', 'Gram', 0.1018, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('cb213b15-47e7-40ed-9fc3-939fe9a77cfb', 'Boiled Bucatini', 'Oils & Fats', null, 92.3, 1, 'KG', 'Gram', 0.0923, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('89dc7873-c345-4472-b7bb-aae4e767a304', 'Boiled Fettuccini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('f15cfd23-1555-4c8a-924f-0d2dd246f9c1', 'Boiled Linguini', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('aa63d9b6-204e-4127-adea-0e4a59d013c3', 'Boiled Conchiglioni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('d2172c48-80a0-454c-9444-497d134c79f3', 'Boiled Rigatoni', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('e06bfe6c-df77-421d-a386-866100a0960e', 'Boiled Penne', 'Oils & Fats', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('e0261b95-7a82-48d2-8b9a-53b1ffbdc852', 'Boiled Arborio Rice', 'Oils & Fats', null, 377.2, 1, 'KG', 'Gram', 0.3772, '2026-06-01', 'active', 'Prep yield (Boiled)', '2026-06-01T09:00:00.000Z'),
('050757cc-07fc-4cc1-997f-65b6a000ac75', 'Orange Zest', 'Fruits', null, 200, 1, 'KG', 'Gram', 0.2, '2026-06-01', 'active', 'Prep yield (Zest)', '2026-06-01T09:00:00.000Z'),
('634cebf7-168a-44e5-b604-24a615f665cd', 'Lemon Zest', 'Fruits', null, 1000, 1, 'KG', 'Gram', 1, '2026-06-01', 'active', 'Prep yield (Zest)', '2026-06-01T09:00:00.000Z'),
('9fc8beff-4365-4f80-b625-5a6af03891ff', 'Beetroot Paste', 'Sauces & Condiments', null, 78.8, 1, 'KG', 'Gram', 0.0788, '2026-06-01', 'active', 'Prep yield (Paste)', '2026-06-01T09:00:00.000Z'),
('b5b98907-f836-4678-9f42-2f95bdded4c7', 'Roasted Bell Pepper', 'Vegetables', null, 87.2, 1, 'KG', 'Gram', 0.0872, '2026-06-01', 'active', 'Prep yield (Roasted)', '2026-06-01T09:00:00.000Z'),
('d9a16122-ec03-488d-a7da-58039cb200d2', 'Dehydrated Lemon Slices', 'Fruits', null, 500, 1, 'KG', 'Gram', 0.5, '2026-06-01', 'active', 'Prep yield (Dehydrated)', '2026-06-01T09:00:00.000Z'),
('b7225118-28be-4ecb-860a-b78aa1e8fab7', 'Julienne Chinese Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('644b85f1-c1a6-4118-b89f-dcd382fc2b63', 'Julienne Indian Cabbage', 'Vegetables', null, null, 1, 'KG', 'Gram', null, null, 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z'),
('81a05bfa-b33b-4c3a-b7ac-fc02a5c35af6', 'Julienne Leeks', 'Vegetables', null, 230, 1, 'KG', 'Gram', 0.23, '2026-06-01', 'active', 'Prep yield (Julienne)', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- recipes (124)
insert into public.recipes (id, recipe_name, category, brand, description, image_url, preparation_time, serving_size, status, total_cost, cost_per_portion, selling_price, packaging_cost, wastage_pct, is_prep, yield_quantity, yield_unit, version_no, method, size_code, size_label, approved_at, rejection_note, created_at, updated_at) values
('a8873c86-73fd-43ff-84c3-866aaa35e85f', 'Chilli Crisp', 'In-House Prep', 'capiche', 'House chilli crisp.', null, 60, 1, 'approved', 1380.26, 1380.26, null, 0, 5, true, 8270, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('800bd63a-e580-410d-b177-de068de7cfdc', 'Bechamel Sauce', 'In-House Prep', 'capiche', 'House bechamel.', null, 30, 1, 'approved', 146.26, 146.26, null, 0, 5, true, 1210, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ac2b5a86-f2a2-422e-893b-50231e818ae0', 'Pizza Dough', 'In-House Prep', 'capiche', 'Cold-proofed pizza dough.', null, 1440, 1, 'approved', 1615.93, 1615.93, null, 0, 5, true, 17288, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('853c4aeb-73c9-4551-802b-17718fcb35bd', 'Pesto White Base Sauce', 'In-House Prep', 'capiche', 'White base for pesto pasta.', null, 20, 1, 'approved', 26.5, 26.5, null, 0, 5, true, 160, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('65314848-b8db-4229-b69d-66567b5bfcfd', 'Hydroponic Basil Pesto', 'In-House Prep', 'capiche', 'Fresh basil pesto.', null, 15, 1, 'approved', 206.02, 206.02, null, 0, 5, true, 475, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('89d245b5-366a-456f-b800-3c789a61b4b2', 'Chili Crunch Sauce', 'In-House Prep', 'capiche', 'Uses house chilli crisp.', null, 30, 1, 'approved', 89.02, 89.02, null, 0, 5, true, 418, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1206e832-b95d-4502-8364-eb4d5653c0d7', 'Sesame Sushi Rice', 'In-House Prep', 'aiko', 'Seasoned sushi rice.', null, 40, 1, 'approved', 269.85, 269.85, null, 0, 5, true, 1025, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('11bacdc7-c078-4175-af25-a4e35ed030b7', 'Ponzu Wasabi Mayo', 'In-House Prep', 'aiko', 'Ponzu wasabi mayo.', null, 10, 1, 'approved', 18.19, 18.19, null, 0, 5, true, 102, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2bc56c42-c083-408a-9d97-c1aec96a138f', 'Tamarind Water', 'In-House Prep', 'aiko', 'Tamarind extraction.', null, 15, 1, 'approved', 19.95, 19.95, null, 0, 5, true, 300, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1de6b23a-cc22-45d6-80ec-045a8e9d28be', 'Marinated Beetroot Chunks', 'In-House Prep', 'aiko', 'Marinated beetroot.', null, 20, 1, 'approved', 8.79, 8.79, null, 0, 5, true, 68, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e86f00eb-f946-4d3d-b519-38f4b60316ea', 'Sri Lankan Red Curry Powder Mix', 'In-House Prep', 'aiko', 'Roasted & ground spice mix.', null, 30, 1, 'approved', 227.85, 227.85, null, 0, 5, true, 87, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'Sri Lankan Red Paste', 'In-House Prep', 'aiko', 'Uses house curry powder.', null, 45, 1, 'approved', 58.39, 58.39, null, 0, 5, true, 243, 'Gram', 1, '{}'::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 164.65, 164.65, 620, 0, 5, false, 250, 'Gram', 1, ARRAY['Toss leaves with vinaigrette & salt.','Add cherry tomato, grapefruit, olives.','Place burrata in centre.','Arrange salad mix around.','Sprinkle pine nuts; drizzle olive oil & hot honey.','Garnish with edible flowers.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e3f8740c-f767-4fbf-8629-e93540e5ebf5', 'Caesar Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 41.12, 41.12, 480, 0, 5, false, 200, 'Gram', 1, ARRAY['Tear leaves.','Slice onion rings.','Toss lettuce with mayo, salt, pepper.','Add parmesan and croutons.','Check seasoning.','Plate; garnish with onion rings.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('eabf996c-ceb2-4d5a-922e-997e4f72e56c', 'Persimmon Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 187.3, 187.3, null, 0, 5, false, 265, 'Gram', 1, ARRAY['Toss arugula with vinaigrette; do not overdress.','Arrange on chilled serving plate.','Place persimmon and strawberry evenly over greens.','Add burrata as soft dollops; season lightly.','Spoon caviar on burrata; sprinkle pine nuts and edible flowers.','Drizzle hot honey; serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'Summer Burrata Salad', 'Salads', 'capiche', null, null, null, 1, 'approved', 141.38, 141.38, 680, 0, 5, false, 344.5, 'Gram', 1, ARRAY['Process iceberg lettuce, romaine lettuce, and Lollo Rosso. Give them an ice bath to keep them crisp.','In a large bowl, combine all processed leaves. Add salt, black pepper, and vinaigrette. Add arugula and toss well.','Cut mango and grapefruit into cubes.','Plate the mixed leaves. Place a burrata on top.','Drizzle olive oil over the burrata and add crushed black pepper.','Arrange cubed mango, grapefruit, and cherry tomatoes around the burrata. Add edible flowers.','Scatter roasted hazelnuts and chopped granola.','Finish with a drizzle of hot honey.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', 'Roasted Red Bell Pepper Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 26.27, 26.27, null, 0, 5, false, 370, 'Gram', 1, ARRAY['Roast veg until soft/charred; cool. Peel peppers if desired.','Blend smooth; strain if desired. Chili; portion 120 g per serve.','Melt a little CDP butter; add 120 g paste, sauté 1 min. Add 160 g water; season; add sour cream; simmer low 3–4 min.','Spread 5 g garlic butter on 70 g sourdough; toast until crisp.','Bowl soup; swirl pesto; sprinkle sesame. Serve hot with bread.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('28d4b546-d3f7-4c5e-a266-a65b631f35eb', 'Arancini', 'Appetiser', 'capiche', null, null, null, 6, 'approved', 48.04, 48.04, 480, 0, 5, false, 117, 'Gram', 1, ARRAY['Prepare rice mix; cool completely.','Weigh 16 g rice mix, add 3 g mozzarella, shape into ball (~19 g). Repeat for 6.','Dip into batter.','Coat with panko crumbs.','Deep fry at 180 °C for ~4–5 min; core ≈ 74 °C.','Drain; plate with hot mayo & green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('946e3e16-b54b-491a-9f70-b44c3376ffbd', 'Dough Balls', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 97.65, 97.65, 540, 0, 5, false, 150, 'Gram', 1, ARRAY['Divide dough into 6–8 × ~20 g balls.','Roll and place on screen.','Bake at 350 °C ~2 min until puffed.','Toss in melted butter, garlic, parsley.','Garnish with green garlic.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0c167350-fed4-4221-bff4-046b0761ec06', 'Garlic Bread', 'Appetiser', 'capiche', null, null, null, 1, 'approved', 51.42, 51.42, 540, 0, 5, false, 105, 'Gram', 1, ARRAY['Bake base; cool slightly.','Deep cut into 8 wedges.','Stuff cream cheese between cuts.','Brush with butter + chopped garlic.','Microwave 30 s.','Bake at 350 °C for 2 min until golden; garnish green garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a7968776-c94a-4829-9672-59fe92c443c2', 'Pasta Fritti 2.0', 'Pasta', 'capiche', null, null, null, 1, 'approved', 159.74, 159.74, null, 0, 5, false, 547, 'Gram', 1, ARRAY['Mix all filling ingredients well.','Cut pasta sheets into 1 x 4 pieces.','Spread ricotta filling, place mozzarella stick and a line of tomato paste. Roll tightly.','Freeze for 15 min.','Dip in batter; coat with bread crumbs.','Deep fry at 160-180 °C for 4-5 min; finish in oven 10-15 sec.','Grate parmesan; top with green garlic.','Serve with garlic ranch & hot tomato sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bbea77c6-5973-462c-9399-bc97e33865b0', 'Butter Garlic Mushroom', 'Pasta', 'capiche', null, null, null, 1, 'approved', 115.34, 115.34, 540, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; cook mushrooms.','Add garlic; sauté.','Add basil, parsley; season.','Toss with vinaigrette & chilli flakes.','Add butters.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fca77966-afc1-4482-9f3a-00d7dfa278c4', 'Saucy Brussels Sprouts', 'Vegetable', 'capiche', null, null, null, 1, 'approved', 165.74, 165.74, 580, 0, 5, false, 676, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add Brussels sprouts (cut in halves) and char on high heat.','Add butter, garlic, chilli flakes, salt, pepper, and balsamic vinegar. Toss well.','In another pan, combine cream cheese, béchamel, sour cream, mayonnaise, salt, and black pepper. Cook on low heat until smooth.','Spread the cream cheese sauce on a plate and place the charred Brussels sprouts on top.','Garnish with fresh Bhavnagri chilli, pickled onions, and feta crumbles.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('455d471b-81c2-471b-a672-7a6caa6da40e', 'Miso Tomato Soup', 'Soups', 'capiche', null, null, null, 1, 'approved', 47.14, 47.14, 440, 0, 5, false, 1093, 'Gram', 1, ARRAY['Heat olive oil in a pot, add onion, garlic, carrot, chili, thyme, bay leaf, parsley stems. Sauté until soft and lightly golden.','Add tomatoes, cook down until jammy.','Add water and stock powder, simmer 20 min.','Remove bay leaf and thyme stems. Blend until smooth.','Take off heat, whisk in miso paste.','Adjust seasoning with soy, salt, and pepper.','Stir in chopped fresh basil just before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8337d712-68b0-4468-b6f2-ff956bff418f', 'Pomodoro Spaghetti', 'Pasta', 'capiche', null, null, null, 1, 'approved', 102.17, 102.17, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil; sauté cherry tomatoes.','Add pomodoro; season.','Add spaghetti; toss.','Simmer; add butter.','Finish with basil; parmesan garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9648baa5-e131-4076-bd57-5fa1f9ac9e85', 'Spicy Tomato & Cream Macaroni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.94, 71.94, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add hot sauce; season.','Add orange sauce; stir.','Add cream; adjust seasoning.','Toss macaroni; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a08407d7-657f-4935-8d96-b1fc4f07ed37', 'Alfredo Fettuccine', 'Pasta', 'capiche', null, null, null, 1, 'approved', 71.69, 71.69, 740, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat oil & butter; add garlic, herbs.','Add béchamel; season; adjust with water.','Toss fettuccine; finish with parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', 'Lemon Linguini', 'Pasta', 'capiche', null, null, null, 1, 'approved', 125.42, 125.42, null, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter; add white sauce, mascarpone.','Add lemon; season.','Toss linguini; adjust with water.','Finish with basil; parmesan.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('668bcd9b-09ec-42fa-b987-3992a61bb381', 'Risotto', 'Pasta', 'capiche', null, null, null, 1, 'approved', 134.96, 134.96, 780, 0, 5, false, 250, 'Gram', 1, ARRAY['Heat butter+oil; sauté garlic, asparagus, peas.','Add rice; season.','Add water; add béchamel.','Finish with parmesan; serve.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('eae4f764-a818-454e-8e5b-08f694454e05', 'Lasagna', 'Pasta', 'capiche', null, null, null, 7, 'approved', 143.63, 143.63, 740, 0, 5, false, 1300, 'Gram', 1, ARRAY['Heat oil in a pan; sauté onion, carrot, celery and garlic until soft.','Add soaked and drained soy chunks; cook for 3–4 min.','Add tomato passata, tomato paste, oregano, salt and pepper. Simmer 15–20 min.','Make béchamel: melt butter, add flour; cook 1 min. Gradually whisk in milk. Cook until thick. Season with salt and nutmeg.','In a baking dish, layer: bolognese sauce, sheets, béchamel, mozzarella. Repeat layers. Top with parmesan.','Bake at 180°C for 40–45 min or until golden and bubbling. Rest 10 min before serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('387baee2-045e-4009-ab2e-219742526817', 'Stuffed Conchiglioni', 'Pasta', 'capiche', null, null, null, 1, 'approved', 103.03, 103.03, 780, 0, 5, false, 662, 'Gram', 1, ARRAY['Mix ricotta, cream cheese, blanched kale, chopped jalapeño, salt and xanthan gum into a smooth, well-seasoned filling.','Stuff each boiled conchiglioni generously with the kale-ricotta filling.','Spoon garlic pomodoro sauce as a base in a shallow oven dish.','Arrange stuffed shells on the sauce base.','Sprinkle parmesan and red paprika on top.','Bake at 350°C for 6 min until golden and heated through.','Garnish with slit onion and sunflower seeds.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'Caramelised Onion Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 62.24, 62.24, 780, 0, 5, false, 329, 'Gram', 1, ARRAY['Heat olive oil in a pan over medium heat.','Add chopped garlic and sauté until fragrant.','Add caramelised onion and cook for 1–2 min.','Add 1 ladle of water; bring to a gentle simmer.','Add spaghetti and mix well to coat.','Add mix seasoning, fresh cream and soya sauce. Toss until pasta is creamy and well combined.','Adjust consistency with water if needed.','Finish with chilli crisp and parmesan. Toss to combine.','Plate and garnish with fresh parsley. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('279cff51-75b3-4169-a228-4e4f89631c31', 'Pink Burrata Pasta', 'Pasta', 'capiche', null, null, null, 1, 'approved', 124.8, 124.8, 780, 0, 5, false, 247, 'Gram', 1, ARRAY['Roast beetroot with olive oil wrapped in foil paper. Once roasted, strain and blend into a purée.','Heat a pan. Add pesto white sauce.','Add farfalle pasta. Season with black pepper, chilli flakes, butter, and salt. Mix well.','Add beetroot purée and toss until the sauce turns pink.','Plate and garnish with a smashed burrata dollop, crushed pumpkin seeds and pistachios, olive oil, and crushed black pepper.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c0698b42-389e-4912-86ea-edb86f5c779f', 'Tomato Butter Risotto', 'Risotto', 'capiche', null, null, null, 1, 'approved', 109.5, 109.5, 740, 0, 5, false, 256, 'Gram', 1, ARRAY['Heat olive oil in a pan. Add garlic and onion and sauté until softened.','Add pomodoro sauce, water, salt, and black pepper. Stir well.','Add risotto rice and butter. Cook well, stirring frequently. Finish with Parmesan.','Plate and garnish with confit cherry tomatoes, a pesto dollop, arugula, and chopped kalonji.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e27fc274-3f9d-483b-b18e-150ff27b2ec1', 'Truffle Mac & Cheese', 'Pasta', 'capiche', null, null, null, 1, 'approved', 164.71, 164.71, 840, 0, 5, false, 253, 'Gram', 1, ARRAY['Heat a pan. Add béchamel sauce, cheddar cheese, and mozzarella cheese. Melt together.','Add boiled pasta and mix well. Season with salt and black pepper. Add parmesan and butter.','Transfer into a steel plate. Top with cheddar cheese, mozzarella cheese, and parmesan. Bake in oven.','Remove from oven. Garnish with truffle oil, truffle pâté, and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('069c47b7-1144-4043-b1c3-32dd30444c3c', 'Sticky Toffee Pudding', 'Desserts', 'capiche', null, null, null, 1, 'approved', 52.6, 52.6, 600, 0, 5, false, 215, 'Gram', 1, ARRAY['Bake pudding.','Warm pudding before service.','Plate pudding.','Pour caramel sauce.','Add pecan ice cream.','Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d46403c7-3ee9-460f-be9b-164fdd22c73a', 'Brownie With Ice Cream', 'Desserts', 'capiche', null, null, null, 1, 'approved', 108.15, 108.15, 640, 0, 5, false, 185, 'Gram', 1, ARRAY['Bake and portion brownies.','Warm before serving.','Plate brownie.','Add ice cream scoop.','Drizzle Nutella.','Garnish tuile.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5c547f69-6b5d-4fce-a7d5-f37ce01ab0a5', 'Pistachio Mousse Cake', 'Desserts', 'capiche', null, null, null, 1, 'approved', 139.58, 139.58, 600, 0, 5, false, 140, 'Gram', 1, ARRAY['Place kunafa base.','Add sponge layer.','Pipe mousse.','Garnish with white chocolate décor.','Add pistachio crumble if available.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3949a87-3cde-4883-bbd9-121ef477d164', 'Tiramisu 3.0', 'Desserts', 'capiche', null, null, null, 1, 'approved', 111.93, 111.93, 640, 0, 5, false, 115, 'Gram', 1, ARRAY['Layer sponge.','Add mascarpone mousse.','Add coffee cream.','Top with sable and tuile.','Chill to set.','Serve chilled.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7c579d14-dc66-495a-8f2c-8b431f14fe5c', 'Lemon Iced Tea', 'Drinks', 'capiche', null, null, null, 1, 'approved', 14.66, 14.66, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Glass & ice (0:00-0:10): Fill with cubed ice.','Build (0:10-0:35): Add lemon juice and sugar syrup.','Top (0:35-1:00): Add iced tea to reach 300 ml net.','Garnish & QC (1:00-1:20): Stir once; garnish with dried lemon.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('41659ed0-6e97-46bb-b254-cb70a16192e3', 'Mint Mojito', 'Drinks', 'capiche', null, null, null, 1, 'approved', 19.13, 19.13, 360, 0, 5, false, 245, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill with cubed ice.','Build (0:10–0:25): Add lemon juice and mint syrup.','Top (0:25–0:50): Add soda; gentle lift with bar spoon.','Garnish & QC (0:50–1:10): Slap mint; place at rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8de4f09e-f319-4004-834c-c0b3eada9efa', 'Pina Colada', 'Drinks', 'capiche', null, null, null, 1, 'approved', 84.9, 84.9, 360, 0, 5, false, 300, 'Gram', 1, ARRAY['Load (0:00-0:20): All ingredients incl. ice in blender.','Blend (0:20-0:50): Smooth, ~30 s.','Pour & garnish (0:50-1:20): Into chilled glass; garnish.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4dfb1ca6-84fb-445d-af64-788e76c5118d', 'Moscow Mule', 'Drinks', 'capiche', null, null, null, 1, 'approved', 91.7, 91.7, 360, 0, 5, false, 320, 'Gram', 1, ARRAY['Fill mule mug with cubed ice.','Add lemon juice and ginger zest into mug.','Add ginger beer to 320 ml; stir gently with bar spoon; lift once.','Garnish with lemon wheel and rosemary sprig.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('df80da7c-c7f7-4ab9-98ba-220ee2bd3e21', 'Sunset Cocktail', 'Drinks', 'capiche', null, null, null, 1, 'approved', 67.54, 67.54, 300, 0, 5, false, 230, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:30): Add lemon juice, orange juice, and hibiscus syrup.','Top (0:30–0:55): Add Sprite to 230 ml; pour gently over the back of a spoon for a layered effect; gentle lift.','Garnish & QC (0:55–1:15): Garnish with fresh jalapeño slice on rim.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('99fbf01c-dfe1-4d08-9cc3-d93e3955ef9f', 'Tamarind Fizz', 'Drinks', 'capiche', null, null, null, 1, 'approved', 56.97, 56.97, 300, 0, 5, false, 220, 'Gram', 1, ARRAY['Glass & ice (0:00–0:10): Fill bamboo glass with cubed ice.','Build (0:10–0:25): Add tamarind syrup and salt.','Top (0:25–0:50): Top with Schweppes Ginger Ale to 220 ml; stir gently; lift once.','Garnish & QC (0:50–1:15): Garnish with basil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('673f2410-6f25-4025-9be6-1f958ae2ecda', 'Tom Yum', 'Soups', 'aiko', null, null, null, 1, 'approved', 17.46, 17.46, 360, 13.12, 5, false, 198, 'Gram', 1, ARRAY['Blend chilli, onion, garlic, mushroom to coarse paste.','Cook paste until aromatic.','Add tamarind, water, vinegar, sugar; simmer 8-10 min.','Adjust hot-sour balance as per standard.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ab14aa51-8931-415e-938d-2bcb74886b8a', 'Thai Spring Roll', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 4.41, 4.41, null, 0, 5, false, 196.75, 'Gram', 1, ARRAY['Place approximately 30 g Thai spring filling on each spring roll sheet.','Roll tightly while folding the sides inward. Seal the edge using slurry/water if required.','Heat oil to 170-175°C. Carefully fry spring rolls until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Serve spring rolls as entire pieces. Drizzle with sriracha sauce. Garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5046f377-08b1-473a-a13a-cb0d47c56939', 'Kwispy Lotus Root', 'Sides', 'aiko', null, null, null, 1, 'approved', 32.05, 32.05, 460, 0, 5, false, 166, 'Gram', 1, ARRAY['Fry lotus root until crisp; drain well.','Heat wok; add garlic + chilli; sauté briefly.','Add onion + bell pepper; toss 30–40 sec.','Add sauce + pok choy; bring to bubble.','Add lotus root; toss quickly to coat.','Finish spring onion + basil; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', 'Kwispy Wonton', 'Appetiser', 'aiko', null, null, null, 1, 'approved', 33.04, 33.04, 460, 0, 5, false, 96, 'Gram', 1, ARRAY['Place approx. 15 g of Kwispy Wonton filling in the center of each gyoza skin.','Apply corn slurry on the edges. Fold and seal tightly in desired shape.','Heat oil to 170–175°C. Carefully drop wontons into hot oil.','Fry for 3–4 minutes or until golden brown and crispy.','Remove and drain excess oil on paper towel.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3264e54c-87f9-4114-a61d-84e803307e17', 'Tteokbokki', 'Sides', 'aiko', null, null, null, 1, 'approved', 108.6, 108.6, 540, 0, 5, false, 170.13, 'Gram', 1, ARRAY['Blanch rice cakes until soft; drain well.','Heat pan; add water + sauce; bring to simmer.','Add rice cakes; toss to coat.','Add salt, MSG, sugar; reduce until glossy.','Finish spring onion + fried garlic; garnish with spring onion slit.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'Tofu Bao', 'Dimsum', 'aiko', null, null, null, 1, 'approved', 40.95, 40.95, 540, 0, 5, false, 223, 'Gram', 1, ARRAY['Mise en place: Keep all ingredients measured and ready. Slice cucumber into thin strips. Prepare coleslaw chilled. Heat oil to 170-175°C. Steam bao until soft and warm.','Coat tofu evenly with tofu batter.','Deep fry at 170-175°C until golden brown and crispy.','Remove and drain excess oil on absorbent paper.','Open warm bao carefully without tearing.','Spread bao sauce base evenly inside the bao.','Add coleslaw followed by crispy tofu.','Place cucumber strips neatly on top.','Garnish with black & white sesame.','Serve immediately while bao is warm and tofu is crispy.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'General Tso''s Water Chestnuts', 'Sides', 'aiko', null, null, null, 1, 'approved', 81.22, 81.22, 540, 0, 5, false, 318, 'Gram', 1, ARRAY['Coat water chestnut with flour; shake off excess. Deep fry until golden and crispy; drain.','Heat wok on high flame. Add chopped garlic, Thai red chilli and onion; stir-fry until aromatic.','Add yellow and red bell peppers; stir-fry until slightly soft yet crunchy.','Add sauces (gyoza dip + drunken sauce); bring to a simmer and stir until the glaze thickens.','Add fried water chestnuts and spring onion; toss quickly to coat. Finish with basil. Transfer to serving bowl. Garnish with fried spring roll strips.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1239b97d-17e3-457b-9233-76faa2fff5f9', 'Steamed Edamame (Chilli / Salted)', 'Sides', 'aiko', null, null, null, 1, 'approved', 104.77, 104.77, 540, 0, 5, false, 172, 'Gram', 1, ARRAY['Steam edamame with pods until tender and hot. Drain any excess water.','Transfer steamed edamame to a bowl.','For chilli version: Add chilli crisp and toss evenly to coat. For salted version: Add salt and toss evenly to coat.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('34806d15-49c2-4651-b284-5563216d9b5c', 'Korean Mandu', 'Sides', 'aiko', null, null, null, 1, 'approved', 52.77, 52.77, 540, 0, 5, false, 106, 'Gram', 1, ARRAY['Prepare Korean Mandu filling (see filling method below). Allow to cool completely.','Place 1 portion (approx. 75 g) of filling in the center of the gyoza skin.','Moisten edges with water. Fold and pleat to seal securely.','Heat oil to 175°C. Fry mandu until golden brown and crisp, about 3–4 minutes. Drain excess oil.','Drizzle spicy mayo and coriander mayo over mandu.','Garnish with toasted white sesame seeds and julienne cut nori sheets.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b326938b-7e11-426c-a932-86024f288c2f', 'Creamy Corn Rocks', 'Sides', 'aiko', null, null, null, 1, 'approved', 71.65, 71.65, 580, 0, 5, false, 244, 'Gram', 1, ARRAY['Heat corn rocks sauce in a pan over medium heat.','Add water and stir well to adjust the consistency. Bring to a simmer.','Add fried corn and toss to coat evenly with the sauce.','Cook for 1–2 minutes until the sauce clings to the corn and is creamy.','Transfer to a bowl.','Garnish with chopped black sesame seeds, spring onion and pickled red paprika slices. Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9ec18c60-41fd-4308-83e0-437c71a9ea96', 'Kwispy Scallion Pancake', 'Sides', 'aiko', null, null, null, 1, 'approved', 9.18, 9.18, null, 0, 5, false, 267, 'Gram', 1, ARRAY['Prepare all components as per recipes below.','Cook scallion pancake until golden brown and crispy on both sides.','Heat Sichuan soy glaze and brush over the pancake.','Drizzle green garlic cream cheese and sriracha sauce over the top.','Top with scallion salad.','Sprinkle toasted white sesame seeds.','Slice or serve whole.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9f56d04e-750f-480f-816f-09afc2b2fdff', 'Cold Spicy Sesame Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 71.18, 71.18, 640, 0, 5, false, 260, 'Gram', 1, ARRAY['Cook soba noodles as per package instructions. Rinse in cold water and drain well.','In a bowl, add cold spicy sesame sauce and place the noodles. Toss well to coat evenly.','Arrange cucumber slices, carrot slices and mix iceberg romaine on the side of the plate.','Place the sauced noodles in the center.','Top with white part spring onion, crushed peanuts and fried sesame.','Serve immediately. Keep chilled until serving.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'Tokyo Style Pizza (Dough Base)', 'Pizza', 'aiko', null, null, null, 1, 'approved', 422.91, 422.91, null, 0, 5, false, 150, 'Gram', 1, ARRAY['Combine water and dry yeast.','Add flour and mix until shaggy.','Cover loosely and ferment 12–16 h at room temp.','Add fermented biga in mixer.','Add cold water gradually.','Add flour and dry yeast; mix.','Add salt; mix 4–5 min.','Drizzle EVOO; mix smooth (windowpane test).','Rest 1–2 h.','Divide into 150 g balls.','Place in oiled trays; cover.','Cold-ferment (CF) 48 h.','Remove dough; temper 1 h.','Spread/stretch dough evenly.','Apply pizza sauce evenly.','Top evenly with cheese and desired toppings.','Bake in a preheated oven until crust is blistered and golden.','Finish with fresh basil after baking.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('92aefb0b-62d7-4f61-a5bf-e19661806536', 'Katsu Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 36.46, 36.46, 580, 0, 5, false, 481, 'Gram', 1, ARRAY['Heat katsu curry gently (do not boil).','Heat tofu if required.','Plate rice.','Arrange tofu, pour curry.','Garnish cabbage, cucumber, sesame, togarashi.','Finish scallion oil + unagi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'Thai Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 131.54, 131.54, 580, 0, 5, false, 961, 'Gram', 1, ARRAY['Cook green paste 60-90 sec until aromatic.','Add coconut milk and water; simmer gently.','Add vegetables and cook until just tender.','Season with MSG, white pepper and stock powder.','Serve with rice; finish with scallion oil, chilli oil, sesame mix and lotus stem.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'Sri Lankan Curry', 'Mains', 'aiko', null, null, null, 1, 'approved', 131.11, 131.11, null, 0, 5, false, 507.5, 'Gram', 1, ARRAY['Heat oil in a pan.','Add Kashmiri chilli powder, Kashmiri chilli red paste and Sri Lankan red paste. Sauté until aromatic.','Add tamarind water and stir well.','Pour in coconut milk, stock water and water. Mix and bring to a simmer.','Season with MSG, salt, white pepper, stock powder and fresh Sri Lankan red curry powder mix.','Add tofu, carrot, mushroom and shimeji mushroom. Cook until vegetables are tender.','Add picked red paprika and slit onion. Simmer for 1-2 minutes.','Finish with red chilli oil.','Garnish with basil leaves and fried onion.','Serve hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5248e90a-a13d-4616-9055-68102310ed85', 'Custom Stir Fry', 'Mains', 'aiko', null, null, null, 1, 'approved', null, null, null, 0, 5, false, 5256.1, 'Gram', 1, ARRAY['Heat wok until smoking hot.','Add oil and aromatics.','Add selected vegetables.','Toss on high flame.','Add preferred sauce.','Cook until vegetables remain crisp tender.','Finish with garnish selection.','Serve immediately hot.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b295200f-c8a7-4422-b929-d4326ef9402b', 'Chestnut Gyoza', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 64.05, 64.05, 540, 0, 5, false, 793, 'Gram', 1, ARRAY['Prepare filling: mix/chop chestnut with chillies and onion. Cook until aromatic.','Season with stock powder, MSG, white pepper, salt.','Add slurry; cook until mixture binds. Cool completely.','Fill wrappers with 18 g filling; pleat tightly.','Pan-fry gyoza in oil until base golden.','Add water, cover and steam 4–5 min.','Remove lid; re-crisp base 30–45 sec.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b895ffee-9c1f-450c-b6b8-fa416a851174', 'Okonomiyaki Gyoza (6 Pcs)', 'Dimsum', 'aiko', null, null, null, 6, 'approved', 105.16, 17.53, null, 0, 5, false, 894, 'Gram', 1, ARRAY['Cook stages 1→4 sequentially; dry the mix fully. Fold in pickled ginger and tempura flakes.','Fill gyoza skins with filling; pleat tightly (18 g filling per gyoza).','Heat non-stick pan; add oil. Place gyoza; pan-fry until base golden.','Add water, cover and steam for 4–5 minutes.','Remove lid; re-crisp base for 30–45 seconds.','Plate in a fan pattern.','Drizzle mustard mayo and soy-ketchup glaze.','Garnish with chilli, spring onion and sesame.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d2fc215c-ea0d-4022-8de9-003dfb326bce', 'Truffle Edamame Dimsums', 'Dimsum', 'aiko', null, null, null, 4, 'approved', 138.89, 138.89, 840, 0, 5, false, 358, 'Gram', 1, ARRAY['Pulse edamame to coarse mince.','Mix with cream cheese, salt, pepper, truffle oil, truffle pate; add water to adjust texture.','Fill wrappers evenly and seal.','Steam 4–5 minutes until cooked.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('723d9f76-cab2-46a1-8a57-24420dd62111', 'Saucy Momos', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 39.31, 39.31, 480, 0, 5, false, 1500, 'Gram', 1, ARRAY['Sauté onion until translucent.','Add cabbage and carrot; cook on high flame until moisture evaporates.','Add spring onion and silken tofu.','Add salt, white pepper, MSG and stock powder.','Mix well and cook until dry.','Cool completely before shaping.','Place required filling in the center of each wrapper.','Pleat and seal properly.','Ensure no leakage and even shape.','Place momos in steamer.','Steam for 4–5 minutes until fully cooked.','Heat sauce base (prepared as per recipe) in a pan.','Simmer gently and adjust consistency.','Keep warm for service.','Spread hot sauce in serving plate or bowl.','Place steamed momos on top.','Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ac8851b7-8d24-4078-98d7-c2a11229724d', 'Cheese Chilli Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 106.28, 106.28, 480, 0, 5, false, 636.5, 'Gram', 1, ARRAY['PREPARE FILLING: Mix all filling ingredients thoroughly. Chill the filling for easy wrapping.','ASSEMBLE DUMPLINGS: Place required filling in the center of each wrapper. Seal edges tightly to form momos.','STEAM: Steam dumplings for 4-5 minutes until cooked.','PREPARE SAUCE: Blend or crush all sauce ingredients to a smooth paste. Heat in a pan and simmer. Adjust consistency and seasoning as required.','PLATE: Spread green sauce on the base of the plate. Place steamed dumplings on top.','GARNISH: Top with fried onion and pickled red Bhavnagri.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'Chilli Oil Dumplings', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 62.35, 62.35, 620, 0, 5, false, 227, 'Gram', 1, ARRAY['Prepare filling: Mix all filling ingredients thoroughly. Refrigerate for 15-20 min for easier handling.','Make chilli oil dumplings paste: Blend all paste ingredients to a smooth, thick paste. Store in an airtight container.','Assemble dumplings: Place required filling in the center of each wrapper. Seal edges tightly to form dumplings.','Steam dumplings: Steam for 4-5 minutes until fully cooked.','Prepare sauce: Heat oil in a pan, add chilli paste and saute for 30 seconds. Add stock water, red chilli powder, salt, msg, stock powder and Sichuan powder. Stir well. Simmer for 2-3 minutes. Adjust seasoning.','Finish & plate: Spread hot sauce on serving plate. Place steamed dumplings on top. Garnish with toasted peanuts, white & green spring onion and fried glass noodles. Serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a0b03363-88ef-4c45-a6f7-c3d7a6158129', 'New Dimsum Platter', 'Dimsum', 'aiko', null, null, null, 5, 'approved', 200.19, 200.19, 1640, 0, 5, false, 125, 'Gram', 1, ARRAY['Prepare Dumplings: Ensure all dim sums are prepared, sealed and ready to steam.','Steam Dumplings: Steam all dumplings for 4-5 minutes on medium heat until cooked.','Prepare Dips & Sauces: Portion dips and sauces as per the given gram weight in small bowls.','Assemble Platter: Arrange all dim sums in a bamboo steamer as shown. Place the dip bowls in the centre or alongside.','Serve: Serve hot immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('afa150ca-2dc7-490b-987c-dfe03e91d5b6', 'Avocado Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 186.3, 186.3, 840, 0, 5, false, 464.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice avocado and cucumber into thin batons.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add cucumber and avocado.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Brush roll with buffalo sauce.','Coat with black and white sesame seeds.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top with thin avocado slices.','Add crispy rice paper piece.','Drizzle unagi sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'Dragon Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 86.42, 86.42, 720, 0, 5, false, 253.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper into thin strips.','Trim and cut spring onion.','Ensure fried lotus stem is crisp and ready.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add red bell pepper, spring onion and fried lotus stem.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Drizzle spicy mayo on top.','Spoon dragon sauce over mayo.','Ensure even topping on all pieces.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', 'Volcano 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 71.66, 8.96, null, 0, 5, false, 362.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Cool to room temperature.','Slice red bell pepper and cucumber into thin strips.','Julienne carrot and spring onion.','Dice mango into small cubes.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread a thin, even layer of rice leaving 1 inch at the top.','Spread cream cheese in the centre.','Add spring onion, carrot, red bell pepper, cucumber and mango.','Lift the mat and roll tightly from the bottom.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Add spicy mayo on top.','Sprinkle chilly crisps and oil.','Garnish with micro greens.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('befb6149-aa96-46bf-8201-0bf8dc05b476', 'Gimbap 1', 'Sushi', 'aiko', null, null, null, 8, 'approved', 111.12, 111.12, 980, 0, 5, false, 325.2, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice cucumber, carrot and pickled radish into thin strips.','Sauté spinach with soy sauce and garlic. Cool.','Cut tofu into strips and toss with soy sauce.','Slice unagi into strips.','Place nori sheet on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','Arrange tofu, unagi, radish, cucumber, carrot and spinach horizontally.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Wipe blade after each cut.','Brush lightly with sesame oil.','Sprinkle sesame seeds if required.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('06c115de-4584-4865-b25f-a5178c5a0b70', 'Bombay Blues Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 70.02, 8.75, null, 0, 5, false, 311.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Finely slice spring onion, carrot, cucumber, red capsicum and jalapeño.','Chop coriander.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, spring onion, carrot, cucumber, red capsicum, jalapeño and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Use a sharp knife.','Cut into 8 equal pieces.','Clean the knife after each cut.','Top each piece with salsa and tempura flex.','Drizzle sweet chilli sauce, unagi sauce and sriracha.','Serve with soy sauce, pickled ginger and wasabi.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f6338ebe-6adc-4365-809e-e1d4d189e5df', 'Jalapeño Popper Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 77.82, 9.73, null, 0, 5, false, 264.4, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Slice jalapeño into thin rings.','Finely chop coriander and spring onion.','Cut raw mango into thin julienne strips.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, jalapeño, raw mango, spring onion and coriander.','Lift the mat and roll tightly from the bottom.','Press gently to form a firm roll.','Seal the edge with a little water.','Roll in fried spring roll for extra crunch.','Spread a thin layer of cream cheese.','Coat the roll evenly with bread crumbs.','Heat oil to 180°C and flash fry until golden and crisp.','Drain on paper towel.','Drizzle unagi sauce and sriracha on top.','Garnish with coriander and sesame seeds.','Slice 8 equal pieces using a sharp knife.','Clean the knife after each cut.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4a228d06-25aa-41ce-9f2a-98777f6993aa', 'Corn Tempura Roll', 'Sushi', 'aiko', null, null, null, 8, 'approved', 140.24, 140.24, 720, 0, 5, false, 399.8, 'Gram', 1, ARRAY['Cook sushi rice and season as per standard.','Allow rice to cool to room temperature.','Drain corn well.','Batter corn with tempura flour and deep fry until golden and crisp.','Slice cucumber and purple cabbage into thin juilenne strips.','Finely chop spring onion.','Keep cream cheese ready.','Place nori on bamboo mat, shiny side down.','Spread an even layer of rice leaving 1 inch gap at the top.','In the center add cream cheese, cucumber, purple cabbage, spring onion and corn tempura.','Roll tightly using mat, applying even pressure.','Moisten knife and slice into 8 equal pieces.','Clean knife after each cut.','Drizzle sriracha on top.','Serve with pickled ginger, wasabi and soy sauce.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', 'Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 380.4, 'Gram', 1, ARRAY['Heat wok on high heat until smoking.','Add oil, then ginger; sauté for 10–15 sec.','Add carrot, corn, edamame; toss for 60–90 sec.','Add cooked rice; toss until steamy hot.','Add stock powder, salt, white pepper, MSG; toss.','Add light soy; toss evenly.','Add spring onion; toss and plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0fcdcee9-7464-4348-ac0e-68cece6b071d', 'Burnt Garlic Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 95.47, 95.47, 540, 0, 5, false, 424.4, 'Gram', 1, ARRAY['Heat wok on medium-high until hot.','Add oil, then garlic; sauté on medium until pale golden (do not burn).','Increase heat; add broccoli, baby corn and spinach; toss 60–90 sec.','Add cooked rice; toss on high heat until heated through.','Add stock powder, salt, white pepper and MSG; toss evenly.','Add light soy; toss evenly.','Plate and top with fried garlic and spring onion.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6f29f70c-e98b-4997-a3d7-6e10d8a09880', 'Mushroom Truffle Fried Rice', 'Rice', 'aiko', null, null, null, 1, 'approved', 235.98, 235.98, 680, 0, 5, false, 410.6, 'Gram', 1, ARRAY['Heat wok on high until smoking.','Add oil and garlic; sauté for 10 sec until aromatic.','Add mushrooms; cook until moisture evaporates and mushrooms brown.','Add chili bean paste, oyster sauce and hot sauce; toss for 15-20 sec.','Add rice and edamame; toss on high heat until rice is hot and everything combined.','Add white pepper, truffle pâté and MSG; toss evenly.','Switch off heat; fold in truffle oil. Plate and serve immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('61a064c9-d715-4c64-9d34-59069b59de34', 'Hakka Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 36.96, 36.96, 580, 0, 5, false, 275.3, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and ginger-garlic; sauté 10-15 sec.','Add vegetables; toss 60-90 sec (keep crunchy).','Add noodles; toss to separate strands.','Add hakka sauce + stock powder, salt, white pepper, MSG; toss on high heat.','Finish spring onion; plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'Drunken Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 38.55, 38.55, 580, 0, 5, false, 269, 'Gram', 1, ARRAY['Heat wok high until smoking.','Add oil and garlic + chilli; sauté 10–15 sec.','Add mushrooms; toss until lightly browned.','Add spring onion whites; stir-fry briefly.','Add noodles + drunken sauce; toss until glossy.','Add bean sprouts + basil; toss 20–30 sec.','Plate immediately.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('9b601a99-0808-42e3-bb05-d61117e2a9f7', 'Pad Thai', 'Noodles', 'aiko', null, null, null, 1, 'approved', 65.61, 65.61, 580, 0, 5, false, 345, 'Gram', 1, ARRAY['Heat wok medium-high; add oil.','Add ginger-garlic; sauté 10 sec.','Add mushrooms and carrot; toss 60 sec.','Add noodles and pad thai sauce; toss until absorbed.','Add sprouts; toss 15–20 sec.','Plate and finish with spring onion, peanuts and coriander.','Serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0759a466-729c-4353-9d7d-46fb706acb59', 'Shoyu Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 42.6, 42.6, 640, 0, 5, false, 361, 'Gram', 1, ARRAY['Bring stock + dashi to gentle simmer.','Add shoyu tare + seasoning; simmer 3-4 min (no hard boil).','Cook noodles separately; drain well.','Place noodles in bowl; pour hot broth.','Top vegetables; finish sesame + scallion oil.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('344a7a22-e412-47d6-abc6-e8682f0ebdca', 'Peanut Butter Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 61.81, 61.81, 640, 0, 5, false, 606.5, 'Gram', 1, ARRAY['Heat oil; sauté ginger + garlic.','Add gochujang + chilli bean paste + chilli powder; bloom 30–40 sec.','Add water gradually; whisk smooth.','Add peanut butter; whisk until emulsified.','Season; simmer 2–3 min.','Cook noodles separately; assemble bowl.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'Spiced Miso Ramen', 'Noodles', 'aiko', null, null, null, 1, 'approved', 47.47, 47.47, null, 0, 5, false, 692.5, 'Gram', 1, ARRAY['Heat oil in a pot over medium heat; add ginger and garlic paste, sauté until aromatic.','Add gochujang, chilli bean paste and chilli powder; bloom for 30–40 sec.','Gradually add water while whisking to avoid lumps.','Add peanut butter and whisk continuously until fully emulsified.','Season with stock powder, MSG, white pepper, salt and caster sugar. Simmer for 2–3 min.','Cook ramen noodles separately as per instructions; drain well.','Assemble the bowl with noodles and hot broth.','Top with peanuts, coriander, spring onion, edamame and pokchoy.','Drizzle with chilli oil and serve with lemon wedge.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('176ab02a-9b10-4c58-941c-20d2c5b0a9a2', 'Buttery Chilli Garlic Noodles', 'Noodles', 'aiko', null, null, null, 1, 'approved', 24.29, 24.29, 580, 0, 5, false, 211.8, 'Gram', 1, ARRAY['Melt butter on low heat.','Add garlic + chilli; cook gently until aromatic.','Add chilli crisp + seasoning; whisk with 10–15 ml hot water to emulsify.','Add noodles; toss until glossy and coated.','Plate; top with spring onion and fried garlic.']::text[], null, null, '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3e00df44-a8b2-443c-b1f7-e53866ab659c', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 147.5, 147.5, 940, 24.46, 5, false, 831, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'Affair Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 129.39, 129.39, null, 0, 5, false, 482, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('13a16e8e-fca6-4f69-9144-cfae026bfe44', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 165.84, 165.84, 940, 24.46, 5, false, 880, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'Apollo pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 147.34, 147.34, null, 0, 5, false, 515, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ad711efe-2240-4a99-a28f-f43aee167147', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 112.9, 112.9, 940, 24.46, 5, false, 695, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('72c17ba3-8372-488d-b506-ce11e8c83d81', 'Baby Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 100.58, 100.58, null, 0, 5, false, 395, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('97f5eac6-e750-43c2-931f-da24f6423fca', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 136.63, 136.63, 1140, 24.46, 5, false, 620, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('532bb14a-6d0c-4499-879e-8503d153d455', 'Burrata hot honey', 'Pizza', 'capiche', null, null, null, 1, 'approved', 134.15, 134.15, null, 0, 5, false, 364, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('416f15b5-8b76-4c29-b526-68b001c297fc', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 220.88, 220.88, 1140, 24.46, 5, false, 935, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('82ca926a-c0ae-4d60-b029-d80286f7b2f5', 'CHILLI CRUNCH', 'Pizza', 'capiche', null, null, null, 1, 'approved', 213.79, 213.79, null, 0, 5, false, 576, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 129.23, 129.23, 1140, 24.46, 5, false, 812, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'Chilli Butter Corn', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.82, 131.82, null, 0, 5, false, 471.48, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cf3167af-4b2d-49d0-94a6-fd6614efade9', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.88, 128.88, 940, 24.46, 5, false, 700, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b4b3f627-b7ce-45db-a3b2-e1d59b923e03', 'Garlic pie Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 108.55, 108.55, null, 0, 5, false, 410, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.85, 111.85, 1140, 24.46, 5, false, 670, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', 'Hell Boy Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 122.24, 122.24, null, 0, 5, false, 389.04, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a6ab5346-30cd-4e28-8864-c2d599f34023', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.2, 125.2, 940, 24.46, 5, false, 650, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ae67908f-dbc4-4d63-b689-6b6a9ba908f8', 'Margherita Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 110.73, 110.73, null, 0, 5, false, 373, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5b072a80-aaed-4149-a4a8-35a2f7360914', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 116.11, 116.11, 940, 24.46, 5, false, 690, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('71eef5c3-4d93-43d5-9d1b-6343c3a657ec', 'Mid Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 104.19, 104.19, null, 0, 5, false, 405, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0dc76a64-2343-4f03-8f68-3fac95324118', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 156.21, 156.21, 940, 24.46, 5, false, 855, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', 'Ortolana pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 140.68, 140.68, null, 0, 5, false, 511, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 113.09, 113.09, 940, 24.46, 5, false, 745, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d69468c0-e5a9-4b86-a634-dfb66ed22959', 'Peperone Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 92.4, 92.4, null, 0, 5, false, 443, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e9678463-ebc9-4fff-918f-98d53f00ea25', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 128.6, 128.6, 940, 24.46, 5, false, 691.5, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'Picanate', 'Pizza', 'capiche', null, null, null, 1, 'approved', 107.24, 107.24, null, 0, 5, false, 399, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fdc13909-c309-4051-80f5-7af108c6f6ab', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.13, 131.13, 940, 24.46, 5, false, 712.35, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', 'Prime Hulk Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 118.26, 118.26, null, 0, 5, false, 421.5, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4749f682-1b1c-44f4-8540-7ae606fa8232', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.63, 125.63, 940, 24.46, 5, false, 615, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', 'Rubirosa Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 104.25, 104.25, null, 0, 5, false, 358, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e58c3edf-2119-448b-b9c0-ecc866539d3f', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 131.5, 131.5, 940, 24.46, 5, false, 735, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4ef3c824-3519-42d1-999d-c4aab27b3adf', 'Sid''s pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 111.12, 111.12, null, 0, 5, false, 415, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 125.21, 125.21, 940, 24.46, 5, false, 740, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d061ed5f-379b-4d3a-9f8d-b5599c53c53a', 'Third Wave Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 101.95, 101.95, null, 0, 5, false, 420, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ca46ebea-3d4e-439a-813c-f751f45f51cd', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 106.53, 106.53, 1140, 24.46, 5, false, 595, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b874e156-ae6f-414c-8348-eea7ffa33fa3', 'Triple sauce', 'Pizza', 'capiche', null, null, null, 1, 'approved', 81.26, 81.26, null, 0, 5, false, 330, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f3d0a3fa-801a-4302-9491-092a5dc1fda5', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 189.25, 189.25, 1140, 24.46, 5, false, 630, 'Gram', 1, '{}'::text[], '15_INCH', '15-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3374995f-64e6-4754-bccf-759f87818e22', 'Truffle Pizza', 'Pizza', 'capiche', null, null, null, 1, 'approved', 169.03, 169.03, null, 0, 5, false, 351, 'Gram', 1, '{}'::text[], '11_INCH', '11-inch', '2026-06-20T09:30:00.000Z', null, '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;

-- pizza variant → master links
update public.recipes set parent_recipe_id = '3e00df44-a8b2-443c-b1f7-e53866ab659c' where id = '5e2f54e8-b540-42ec-9349-0738f7c7e98b';
update public.recipes set parent_recipe_id = '13a16e8e-fca6-4f69-9144-cfae026bfe44' where id = '2fca7651-7761-40ad-a81b-ebdcc06e5ff1';
update public.recipes set parent_recipe_id = 'ad711efe-2240-4a99-a28f-f43aee167147' where id = '72c17ba3-8372-488d-b506-ce11e8c83d81';
update public.recipes set parent_recipe_id = '97f5eac6-e750-43c2-931f-da24f6423fca' where id = '532bb14a-6d0c-4499-879e-8503d153d455';
update public.recipes set parent_recipe_id = '416f15b5-8b76-4c29-b526-68b001c297fc' where id = '82ca926a-c0ae-4d60-b029-d80286f7b2f5';
update public.recipes set parent_recipe_id = '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374' where id = '379082e0-85e7-4c8b-bdd5-c8525c4c2822';
update public.recipes set parent_recipe_id = 'cf3167af-4b2d-49d0-94a6-fd6614efade9' where id = 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03';
update public.recipes set parent_recipe_id = 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9' where id = '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224';
update public.recipes set parent_recipe_id = 'a6ab5346-30cd-4e28-8864-c2d599f34023' where id = 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8';
update public.recipes set parent_recipe_id = '5b072a80-aaed-4149-a4a8-35a2f7360914' where id = '71eef5c3-4d93-43d5-9d1b-6343c3a657ec';
update public.recipes set parent_recipe_id = '0dc76a64-2343-4f03-8f68-3fac95324118' where id = '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a';
update public.recipes set parent_recipe_id = '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f' where id = 'd69468c0-e5a9-4b86-a634-dfb66ed22959';
update public.recipes set parent_recipe_id = 'e9678463-ebc9-4fff-918f-98d53f00ea25' where id = '29eac9b3-2e36-4271-ada5-fc2a60fa40eb';
update public.recipes set parent_recipe_id = 'fdc13909-c309-4051-80f5-7af108c6f6ab' where id = 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3';
update public.recipes set parent_recipe_id = '4749f682-1b1c-44f4-8540-7ae606fa8232' where id = '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3';
update public.recipes set parent_recipe_id = 'e58c3edf-2119-448b-b9c0-ecc866539d3f' where id = '4ef3c824-3519-42d1-999d-c4aab27b3adf';
update public.recipes set parent_recipe_id = '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a' where id = 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a';
update public.recipes set parent_recipe_id = 'ca46ebea-3d4e-439a-813c-f751f45f51cd' where id = 'b874e156-ae6f-414c-8348-eea7ffa33fa3';
update public.recipes set parent_recipe_id = 'f3d0a3fa-801a-4302-9491-092a5dc1fda5' where id = '3374995f-64e6-4754-bccf-759f87818e22';

-- recipe_ingredients (1246)
insert into public.recipe_ingredients (id, recipe_id, ingredient_id, component_type, quantity_used, unit_used, calculated_cost, sort_order, wastage_override_pct, cut_type) values
('96736a10-98f7-4c67-a819-04ec9adbc6f7', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '334fd832-a54e-4af4-bb3a-1d79df2be3a0', 'material', 1000, 'Gram', 425, 0, null, null),
('8d3f7407-fde1-408c-9c35-74b168baa275', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 500, 'Gram', 41.69, 1, null, null),
('893afbf3-05f6-4bf9-b626-f9036122bbcd', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 220, 'Gram', 73.33, 2, null, null),
('2b8f3b6f-4b49-401a-aa8a-aac8e8db4e16', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '42525160-fcb6-4aa1-99d9-02f5409826af', 'material', 500, 'Gram', 75.76, 3, null, null),
('98458971-fdc6-485e-af13-0ce9fd942397', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '20484b26-de18-4908-9c3f-5d8be29d4c29', 'material', 800, 'Gram', 150, 4, null, null),
('324d1b51-0194-406e-9f6c-225527892f08', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 250, 'Gram', 25.25, 5, null, null),
('5aef64a7-b9c4-4ab4-9a8d-8401ea0cc0f1', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', 'ef4e5b02-135a-4b46-8e3e-b5e850f9c38f', 'material', 5000, 'Gram', 523.5, 6, null, null),
('727932c7-d561-4160-9f3a-bfeafb87f032', '800bd63a-e580-410d-b177-de068de7cfdc', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 100, 'Gram', 53.8, 0, null, null),
('aed418e3-6f0f-44a0-b12f-bc7cd7581914', '800bd63a-e580-410d-b177-de068de7cfdc', '0504eb3a-031f-48d2-ab53-3a2ae43f90f2', 'material', 1000, 'Gram', 75.2, 1, null, null),
('06bcf6c6-6713-41fb-abf6-348651db23e2', '800bd63a-e580-410d-b177-de068de7cfdc', '5d420772-7c11-4413-8390-9f4bad621641', 'material', 5, 'Gram', 2, 2, null, null),
('1936dd2a-3a0c-4dfd-80ed-93278a704775', '800bd63a-e580-410d-b177-de068de7cfdc', '925a367e-cdfa-4b4d-a5f9-a854e9f2c6d9', 'material', 5, 'Gram', 4.2, 3, null, null),
('499029bd-c399-49b1-82c5-99f69eb44124', '800bd63a-e580-410d-b177-de068de7cfdc', '80d2b493-1a3c-4fad-8e9e-182720675e85', 'material', 100, 'Gram', 4.1, 4, null, null),
('bc23a343-6037-49c3-8bdc-54bdc8522a8a', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'ccda1047-98e8-4085-afb8-47943a6fa4f2', 'material', 10000, 'Gram', 1197, 0, null, null),
('45d61414-1870-4d58-ae15-6566571115f8', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'd47ac757-b7a1-4f07-bad2-c897da30a527', 'material', 19, 'Gram', 7, 1, null, null),
('9c8c15c6-5fed-4f96-87bd-82b4559d246a', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', '3eb0d177-2561-4a4e-b09f-fd4478013e2d', 'material', 4443, 'Gram', 0, 2, null, null),
('b2ba88ca-c084-4b4f-bcd8-5b9be4e5ada5', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 2221, 'Gram', 0, 3, null, null),
('7494c3f8-1077-40c4-b1b2-9f29259881cc', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 221, 'Gram', 232.05, 4, null, null),
('689b5c6c-402b-446c-bd39-817028434dac', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 269, 'Gram', 89.66, 5, null, null),
('748e94e3-d262-41eb-bb6b-5480d79848b2', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'e39a9899-4063-45ef-bc03-da61b5ed1ed9', 'material', 75, 'Gram', 9, 6, null, null),
('598aa9ac-6e1d-47fd-9850-4e6e9a5cd88d', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'b7e5ddea-ff58-4f33-aea9-fb8aa36bfb67', 'material', 40, 'Gram', 4.27, 7, null, null),
('8f55e8ba-c3cd-4a81-bac8-36d8f075a2e9', '853c4aeb-73c9-4551-802b-17718fcb35bd', '806ce782-b2c5-464e-9f49-a2d144c2c024', 'material', 10, 'Gram', 5, 0, null, null),
('d27fdf69-6b84-47c7-9b9e-d73bee36df84', '853c4aeb-73c9-4551-802b-17718fcb35bd', 'f29d842a-7fc6-4c01-b848-d874e19b0a90', 'material', 10, 'Gram', 4.82, 1, null, null),
('0f1c915a-c048-4ac6-b713-f99293278c7b', '853c4aeb-73c9-4551-802b-17718fcb35bd', 'db72b201-2bf0-498e-83d1-5b080b5110ec', 'material', 10, 'Gram', 1, 2, null, null),
('02ff1b1c-8da0-4b8b-b04f-582f853b72a6', '853c4aeb-73c9-4551-802b-17718fcb35bd', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 60, 'Gram', 0, 3, null, null),
('2fba4826-7d5e-4f58-81c9-8e78f989ff30', '853c4aeb-73c9-4551-802b-17718fcb35bd', 'eb6aa82b-f8c1-497d-8a2e-5751212f6c43', 'material', 70, 'Gram', 14.42, 4, null, null),
('688eec8c-d8f1-4f45-b51b-7fad479523f8', '65314848-b8db-4229-b69d-66567b5bfcfd', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 100, 'Gram', 105, 0, null, null),
('8e75c0bd-debe-43a4-93b3-19907954b06b', '65314848-b8db-4229-b69d-66567b5bfcfd', 'ed7ef7fc-abbb-4963-8aca-4b526ec13b45', 'material', 30, 'Gram', 24.9, 1, null, null),
('e3c65208-ae11-488d-b539-5b7461f96d0a', '65314848-b8db-4229-b69d-66567b5bfcfd', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 20, 'Gram', 6.22, 2, null, null),
('9138e8b1-f684-4dde-81ed-7d07b9e2b944', '65314848-b8db-4229-b69d-66567b5bfcfd', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 5, 'Gram', 1.67, 3, null, null),
('784b0fb8-2c65-481d-983b-09005238c96d', '65314848-b8db-4229-b69d-66567b5bfcfd', '3eb0d177-2561-4a4e-b09f-fd4478013e2d', 'material', 70, 'Gram', 0, 4, null, null),
('06d91758-a623-4fff-bb67-08cae2a1f254', '65314848-b8db-4229-b69d-66567b5bfcfd', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 250, 'Gram', 58.42, 5, null, null),
('30248c5a-a68a-49c1-99cd-6581a6e9f7fb', '89d245b5-366a-456f-b800-3c789a61b4b2', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 5, 'Gram', 5.25, 0, null, null),
('248285e7-5343-4270-95e7-35436f9ed939', '89d245b5-366a-456f-b800-3c789a61b4b2', 'ce6099c2-148c-45cb-8a1c-76a843f23528', 'material', 4, 'Gram', 4, 1, null, null),
('bc629515-0038-4769-a124-8aa73e117f8a', '89d245b5-366a-456f-b800-3c789a61b4b2', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 10, 'Gram', 1.31, 2, null, null),
('3faa9220-0703-408d-a951-ef19f32623fa', '89d245b5-366a-456f-b800-3c789a61b4b2', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 30, 'Gram', 4.5, 3, null, null),
('d8c0de6c-f02d-4cfb-a4b0-03c1d7de56d6', '89d245b5-366a-456f-b800-3c789a61b4b2', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 30, 'Gram', 7.71, 4, null, null),
('c46e6924-25cf-438b-868b-6e115c98470a', '89d245b5-366a-456f-b800-3c789a61b4b2', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 5, 'Gram', 0.42, 5, null, null),
('2451e76d-05f3-4525-9eac-ed138e59ae0b', '89d245b5-366a-456f-b800-3c789a61b4b2', 'd901fcb6-1f1a-4d7d-a7a8-0a7870a43017', 'material', 30, 'Gram', 8, 6, null, null),
('4d90638b-3e23-49c6-b80e-fa46a474e829', '89d245b5-366a-456f-b800-3c789a61b4b2', '4c7d22f9-d76f-48c5-ba56-092c7167bb18', 'material', 20, 'Gram', 0.62, 7, null, null),
('2df4a4a4-7eae-4093-886b-4ca00c7ab66a', '89d245b5-366a-456f-b800-3c789a61b4b2', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 50, 'Gram', 0, 8, null, null),
('51b4137f-a8f0-4373-ac21-64acde8bc3d9', '89d245b5-366a-456f-b800-3c789a61b4b2', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', 'recipe', 30, 'Gram', 4.77, 9, null, null),
('b218af75-013b-407d-979a-28d29c9b8cdf', '89d245b5-366a-456f-b800-3c789a61b4b2', '65b5683f-e960-4303-9a58-4bf3202a1df4', 'material', 200, 'Gram', 47, 10, null, null),
('404e0bd4-542a-422e-9166-830429030bdd', '89d245b5-366a-456f-b800-3c789a61b4b2', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 0.5, 'Gram', 0.17, 11, null, null),
('e869a52e-bb41-48d2-805b-05055e1d05c9', '89d245b5-366a-456f-b800-3c789a61b4b2', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 1, 'Gram', 0.33, 12, null, null),
('4ef67d98-c893-4baf-8cef-b4d0f9af3c60', '89d245b5-366a-456f-b800-3c789a61b4b2', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('2b00a5a2-91d3-4853-b3c0-58a04f4c0247', '89d245b5-366a-456f-b800-3c789a61b4b2', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 2, 'Gram', 0.2, 14, null, null),
('81fb4251-c891-4289-8cb9-ed3eedfe13bd', '1206e832-b95d-4502-8364-eb4d5653c0d7', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 1000, 'Gram', 252, 0, null, null),
('7d2a19cb-7cb9-4661-89be-9edc057a83ff', '1206e832-b95d-4502-8364-eb4d5653c0d7', 'b1f2ff36-f5ca-4a2d-9fba-b025b35ab768', 'material', 25, 'Gram', 5, 1, null, null),
('644237d6-61d8-44ac-89f4-2f78a5a84e80', '11bacdc7-c078-4175-af25-a4e35ed030b7', 'd76ed8c2-926f-4839-bcf0-720e2a4cae62', 'material', 100, 'Gram', 15.32, 0, null, null),
('e6dc23f0-b8b3-4316-a4f8-2f8df5734461', '11bacdc7-c078-4175-af25-a4e35ed030b7', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 2, 'Gram', 2, 1, null, null),
('a5dc40b8-a960-41e8-adf7-7dc4af371ec3', '2bc56c42-c083-408a-9d97-c1aec96a138f', '19950686-429f-4707-8c3c-db46066afeb8', 'material', 100, 'Gram', 19, 0, null, null),
('ba0df907-5c30-4d71-a2d3-8b796d358a08', '2bc56c42-c083-408a-9d97-c1aec96a138f', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 200, 'Gram', 0, 1, null, null),
('3246b742-ad1e-4991-b054-ee18983bb7b5', '1de6b23a-cc22-45d6-80ec-045a8e9d28be', 'e3711058-30f6-4a47-92b4-d7cc89cc4788', 'material', 40, 'Gram', 4, 0, null, null),
('dbcfa0ff-4433-44dc-9d2f-38c90c01d61e', '1de6b23a-cc22-45d6-80ec-045a8e9d28be', '7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'material', 5, 'Gram', 1, 1, null, null),
('6aed8e32-cd6e-4a6b-a1bf-feb00d8bd370', '1de6b23a-cc22-45d6-80ec-045a8e9d28be', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 2, null, null),
('f4177c1e-f115-451c-a828-48607c5dd74b', '1de6b23a-cc22-45d6-80ec-045a8e9d28be', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 1, 'Gram', 1, 3, null, null),
('450501d3-5f36-456b-83b5-af7add6c1e74', '1de6b23a-cc22-45d6-80ec-045a8e9d28be', '079b0848-38e0-4557-9905-785d934d791c', 'material', 20, 'Gram', 1.7, 4, null, null),
('3b47ea9e-f1bd-486b-84c2-17ae84ce56d8', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', 'e51c2e93-fa8f-4016-a514-e2dc344a9e55', 'material', 40, 'Gram', 160, 0, null, null),
('22422d28-d0c2-4950-b91b-7c8dd992a59b', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', '33d2bf9d-796c-4997-af10-07e0f93654e3', 'material', 15, 'Gram', 14, 1, null, null),
('81e9ce2a-765d-4d5d-84b6-1a14bd88c3db', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', '9bd93cea-f1d4-4d9d-807f-a9b8372b74d5', 'material', 15, 'Gram', 3, 2, null, null),
('73f32998-ae35-4ba7-9a25-f988bf9ea9d4', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 10, 'Gram', 10, 3, null, null),
('dfafe710-64a8-4932-a726-6bd18eaf7b8b', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', 'f868ff6c-f841-47a8-91c8-3369b4581fa4', 'material', 3, 'Gram', 18, 4, null, null),
('6d9b3cb0-ad92-429e-9920-854f600e8baf', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', '217a8061-2817-4a73-bb08-0e9835ff92c6', 'material', 2, 'Gram', 4, 5, null, null),
('91271c05-72ba-4925-b5c8-64f40d545841', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', '04635265-8593-454b-a70b-5879098f6e95', 'material', 2, 'Gram', 8, 6, null, null),
('e4b2fc70-debb-4a56-a22b-d6d8e69ffa77', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 150, 'Gram', 12.51, 0, null, null),
('1c28085f-9478-4a4c-8e51-d221d2be0cd4', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 10, 'Gram', 2.57, 1, null, null),
('de7e9f6e-6c2c-4c26-8b26-9da1f8288be5', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', '42525160-fcb6-4aa1-99d9-02f5409826af', 'material', 10, 'Gram', 1.52, 2, null, null),
('f1e71de2-4997-443a-8a7a-9c9c764dcab5', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', '0e51d8bb-48b8-4e0e-870e-a7c8ca5e97da', 'material', 10, 'Gram', 1, 3, null, null),
('c70cef16-59ec-4d0a-8a28-72aa75ffde25', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 30, 'Gram', 4.29, 4, null, null),
('548709bf-99f8-4b72-9005-47825ba9f76c', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'b12ccec2-cd1f-4979-b6f0-1c05b2cb951b', 'material', 4, 'Gram', 1, 5, null, null),
('1b997e65-656a-4f34-8c34-ab6092b55342', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', '4274e163-35a6-4243-a48f-bde7ddc80679', 'material', 1, 'Gram', 1, 6, null, null),
('eb046041-8bcd-43b1-91bc-b6c0390af6ed', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'b55069bf-eb23-4900-b729-146efc9b0522', 'material', 7, 'Gram', 1, 7, null, null),
('691e0356-50e5-4cfc-9a96-3b98b4789a55', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 7, 'Gram', 1.64, 8, null, null),
('d61a3802-331b-419f-ae85-d2ac4ac6931f', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'e86f00eb-f946-4d3d-b519-38f4b60316ea', 'recipe', 10, 'Gram', 24.94, 9, null, null),
('acd32b95-3bbf-4d4c-a7dd-5aa416ee6654', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'dd921e5d-acbf-4db0-b63b-6b24d70c1705', 'material', 2.5, 'Gram', 2, 10, null, null),
('1c01e812-8c8b-41cf-8f32-b19d899b620e', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'd14a1f66-7e9b-497e-a7d8-a339b5d19ad3', 'material', 1.5, 'Gram', 2.14, 11, null, null),
('4288165e-94fb-468b-970d-085c159d1f63', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '62ccd7fd-5272-4e2b-9a68-406b920a4931', 'material', 10, 'Gram', 10, 0, null, null),
('821a9fed-b968-4280-8e4b-38f7278f6353', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '0908996c-55e2-4b45-99e7-64b356db81be', 'material', 10, 'Gram', 2, 1, null, null),
('62690265-f875-4f90-bf41-6d145401336f', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'ebff6b5f-3b85-4e29-8cf1-dd6864850891', 'material', 10, 'Gram', 2, 2, null, null),
('3afd7cf9-9a24-41df-9289-b2458c10f845', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '0ef36efa-7d7d-4918-ae03-c50763637fab', 'material', 10, 'Gram', null, 3, null, null),
('9c2960f6-0e33-4576-afb8-7e7342c6b5dc', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'e2cf9241-1044-49d4-90d4-9daf748a0a49', 'material', 30, 'Gram', 9, 4, null, null),
('d9164106-fdb7-4034-b395-7bcfce09ace3', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'b740862f-aedb-42d9-a86f-a43bfa4e7c83', 'material', 30, 'Gram', 34.29, 5, null, null),
('6d98a6e8-54ff-4c42-980b-2b18e4575597', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '421b6ebe-8109-48c6-9aba-8ab9ec614ea0', 'material', 5, 'Gram', 25, 6, null, null),
('06ec1d17-1dfe-4f24-810e-fc9436412164', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '5e1b3b1d-2e00-4dfa-b649-f32e1c82a55a', 'material', 40, 'Gram', 24, 7, null, null),
('c1cbcf57-cc2e-4d46-b535-aa57eabfd5ba', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'f37f1adf-828b-4fc4-a5ed-549ee14e4eb1', 'material', 4, 'Gram', 4, 8, null, null),
('d4865c69-af2b-4fd2-bcc2-27506ccf360b', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 2, 'Gram', 2.1, 9, null, null),
('7c1ce08f-b7a6-4450-bd66-1875e39144ed', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'fd3aa76a-e225-4cd4-80ac-ca4dd3952f1d', 'material', 2, 'Gram', 2, 10, null, null),
('57548f29-d893-4474-829c-db4b5d94a154', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '1b81b6f3-707c-406e-a275-c444a047d188', 'material', 2, 'Gram', 0.8, 11, null, null),
('30d25269-d881-4c21-ab59-9797104c0da8', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', '64c974ba-6a04-41e8-add9-204488304b59', 'material', 1, 'Gram', null, 12, null, null),
('76885197-4745-49cf-8f88-a1dce2b8bfce', '087f5153-13b3-4ace-b9e9-423fb02dcfaf', 'ad9c6be0-eebc-444d-b2be-1f19c3fad516', 'material', 80, 'Gram', 60, 13, null, null),
('97d8279d-3336-4516-b9e2-286563b219ef', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', 'ebff6b5f-3b85-4e29-8cf1-dd6864850891', 'material', 50, 'Gram', 10, 0, null, null),
('6feb006c-f352-4837-a1c3-4b8b52b8ad26', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '0908996c-55e2-4b45-99e7-64b356db81be', 'material', 50, 'Gram', 10, 1, null, null),
('7fe85f4e-377e-47e9-91e7-5acd877558ac', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 20, 'Gram', 1.33, 2, null, null),
('223f9ab9-1435-4dd6-b67d-841cd160ac73', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 1, 'Gram', 0.33, 3, null, null),
('bf873e93-7666-4466-a3e9-5af0805eb745', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('b4c20263-f98d-415c-83dc-763d12e781d8', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '1d2fe5d4-c10c-400c-ad8c-3ae390085606', 'material', 6, 'Gram', null, 5, null, null),
('39c01899-4622-4a72-a7b5-c9418aaa1312', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '7822c7ae-9d79-431b-a002-ecd767eede3c', 'material', 10, 'Gram', 1.39, 6, null, null),
('67f7eaf3-4c5c-4e60-8bfc-2f08775bffb5', 'e3f8740c-f767-4fbf-8629-e93540e5ebf5', '09647a47-1dc6-41a0-aed5-09c0db06e570', 'material', 50, 'Gram', null, 7, null, null),
('a2895b56-aaad-4b69-be3f-50308e9ec65a', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '62ccd7fd-5272-4e2b-9a68-406b920a4931', 'material', 30, 'Gram', 30, 0, null, null),
('56a97767-7e16-4afb-852d-7df5bbcd0c65', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', 'f37f1adf-828b-4fc4-a5ed-549ee14e4eb1', 'material', 12, 'Gram', 12, 1, null, null),
('ad16b106-2bd7-4bb8-a0ac-54113621899b', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '0e67b519-1ba8-4ba1-a8b5-7c2c347ea1e2', 'material', 80, 'Gram', 29, 2, null, null),
('46b47e59-98f7-4863-8e7f-1aec4ea4a69a', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '3f2dcf12-5775-40ed-be06-a200d738e128', 'material', 50, 'Gram', 20, 3, null, null),
('a8f5002f-05ad-493e-8a8b-7fd58c99a146', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '146fbcaa-2a17-4cd9-9a7b-a191f8b2123a', 'material', 60, 'Gram', 41.51, 4, null, null),
('72d57f51-9e9f-4eb4-8b7c-ea2473fe5780', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '9312ea03-0025-4829-841d-55b52ec59c6d', 'material', 20, 'Gram', 16.2, 5, null, null),
('207032d5-c672-4aa1-ba8e-dec9b1979186', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '421b6ebe-8109-48c6-9aba-8ab9ec614ea0', 'material', 5, 'Gram', 25, 6, null, null),
('e3fe7e07-4943-4ed6-9328-a9ba2c446edf', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', 'a128c1ba-9fc9-4d85-b8f9-6c2f114fc22d', 'material', 1, 'Piece', 1, 7, null, null),
('579fe7ac-33b3-46ad-9560-c6cc9be4fb5b', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 8, null, null),
('06d0c982-4556-4f84-b170-dca7edcd6d80', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 1, 'Gram', 1, 9, null, null),
('ead3b887-aa55-44f0-94ed-6fc1fceae11a', 'eabf996c-ceb2-4d5a-922e-997e4f72e56c', '1b81b6f3-707c-406e-a275-c444a047d188', 'material', 5, 'Gram', 2, 10, null, null),
('5b0dbedc-6ddf-4239-a081-79300ab4c66e', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'b17748fa-5ec9-4e2e-87e9-7b87f791d00e', 'material', 31, 'Gram', 10, 0, null, null),
('b4bef169-6edc-4e2f-b596-3e57e49bad40', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'e07ce63f-cb6b-4942-929f-b8367af88834', 'material', 15, 'Gram', 6, 1, null, null),
('b6f97720-5075-40ad-94cb-12109b5e9982', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '47100c37-4c7d-455a-a40a-6ddb675f15b3', 'material', 15, 'Gram', 5, 2, null, null),
('748b105f-e865-40a0-a69b-0a232e9537d7', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 1, 'Gram', 0.33, 3, null, null),
('940692c0-94f7-4fa1-8259-8a143fa1dc7e', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('ec8e72b7-a213-4d64-bfe5-adce25cdfa14', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'f37f1adf-828b-4fc4-a5ed-549ee14e4eb1', 'material', 10, 'Gram', 10, 5, null, null),
('19a22570-b497-435d-9cab-485c588f48af', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '62ccd7fd-5272-4e2b-9a68-406b920a4931', 'material', 15, 'Gram', 15, 6, null, null),
('ecc81b0b-a8b6-4071-aeea-be658b5eda19', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '146fbcaa-2a17-4cd9-9a7b-a191f8b2123a', 'material', 120, 'Gram', 83.02, 7, null, null),
('6c4fa8ba-fbc2-4de6-a7ab-0e8ff8579442', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 2, 'Gram', 2.1, 8, null, null),
('727a6116-f913-4ede-a672-bbc912bd18fa', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'a0d7f5ef-e393-4faa-a564-12f1363a991b', 'material', 0, 'Gram', 0, 9, null, null),
('6cc97552-b9a4-4dd6-9e5c-f4f3a98540fb', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '39afcb2c-38bc-4eaa-a7c6-1d646af3899b', 'material', 5, 'Gram', 13, 10, null, null),
('fb3accf0-2ca3-4b61-b81f-edb59f05e98f', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '7ec79322-a3f1-4a28-a6c6-37fe65ff6acb', 'material', 0, 'Gram', null, 11, null, null),
('514fbe19-f691-41ec-976d-b7af4494f9ac', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '6a059a2f-0a8b-4e03-819e-cc2946d1407e', 'material', 80, 'Gram', 40.8, 12, null, null),
('d1e9a4c3-da2a-4bb2-8dee-afc0ab800743', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', '1d4bf7a5-875f-4381-9892-f0dc4c4e831b', 'material', 35, 'Gram', 9.4, 13, null, null),
('044a8e0d-0736-470c-aab3-bb177d394ff5', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'ebb533c6-b69a-45b3-8ddf-a7f75221dd52', 'material', 10, 'Gram', 6.05, 14, null, null),
('ba1105df-d52e-436d-884d-e620613ba0ef', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'a128c1ba-9fc9-4d85-b8f9-6c2f114fc22d', 'material', 3, 'Piece', 3, 15, null, null),
('32da1dea-779d-4934-a8fb-49560e877e0e', 'c0e9daa4-ac2d-4d8c-9a9d-a9241af46740', 'a0d4fc98-7bab-48cb-bfb0-c20bbe6e6f2a', 'material', 5, 'Gram', 1.78, 16, null, null),
('053cdc1d-c952-4413-a7fb-ce6719c064be', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '7129c709-0269-40d0-9645-7f14ffee726b', 'material', 650, 'Gram', null, 0, null, null),
('cb3fb297-7f87-4178-a723-145d73844818', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 90, 'Gram', 6, 1, null, null),
('18983495-454c-4c89-9503-2cba0f429f03', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 16, 'Gram', 4.8, 2, null, null),
('acee315d-ad76-47e3-9a68-9d152427adef', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', 'a30a33b1-77c6-4b61-8ceb-efecd4840b24', 'material', 70, 'Gram', 7, 3, null, null),
('a18569a8-44b0-4918-af69-1848a1c1942c', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '6313132d-b485-43d6-9d3d-64d9f69f0048', 'material', 120, 'Gram', null, 4, null, null),
('3b778aa6-c220-422a-980f-2c4d13a9ea0b', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 160, 'Gram', 0, 5, null, null),
('906c3d6d-23c2-4276-bab2-455b8b4588c9', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 6, null, null),
('6d38a163-c686-486c-9223-22338813c394', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 7, null, null),
('a7c730e8-5a7a-49f3-afe8-45726d3f4178', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'material', 0.5, 'Gram', 0.1, 8, null, null),
('b9353977-3bc6-470b-bb28-6cdcee1aa8a8', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 5, 'Gram', 0.91, 9, null, null),
('41f4f30c-20a0-4365-a570-48fefde6a1e2', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 5, 'Gram', 2.04, 10, null, null),
('6d4d82fa-3005-4536-8f1d-bbe63eb18bcb', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '3c8954ce-5e56-4be0-bc4a-887e729fba47', 'material', 70, 'Gram', null, 11, null, null),
('7745e36e-4a96-4177-afac-9bdd505917b9', 'e52db37e-b3ee-409e-b5d1-3fa338c3a0ab', '95e1ea46-61b6-41a4-b157-48ab383658aa', 'material', 5, 'Gram', 3, 12, null, null),
('dfca0ac1-fc79-4ea6-9cf9-3c431bf23f0a', '28d4b546-d3f7-4c5e-a266-a65b631f35eb', '676f115a-cb1e-4071-8abb-11a02ceb2fcc', 'material', 96, 'Gram', null, 0, null, null),
('0111c29a-0a6b-4192-8336-9a460c126bac', '28d4b546-d3f7-4c5e-a266-a65b631f35eb', '2048a7c4-e1ec-4f95-b666-925367e5cb57', 'material', 18, 'Gram', null, 1, null, null),
('14145e1b-d82d-4547-8645-d7b4579eb97a', '28d4b546-d3f7-4c5e-a266-a65b631f35eb', 'd567cfd3-a4da-4d95-ba12-761105b36ce2', 'material', 96, 'Gram', null, 2, null, null),
('a10478bc-96db-4523-8c97-476ac89a50ad', '28d4b546-d3f7-4c5e-a266-a65b631f35eb', '2e3d84e5-2c92-45ba-abc2-4fce9c995b67', 'material', 12, 'Gram', null, 3, null, null),
('1e489f52-4aee-4871-82e1-f845fd367186', '28d4b546-d3f7-4c5e-a266-a65b631f35eb', '3657c5a3-013b-4627-904b-699481e99c49', 'material', 0, 'ML', null, 4, null, null),
('8d6e3afd-87ac-4d4f-ba31-09a56bc42d62', '946e3e16-b54b-491a-9f70-b44c3376ffbd', 'd9ed1403-f09d-439c-831b-82ba8a8a0600', 'material', 150, 'Gram', 8.45, 0, null, null),
('55b8344b-aa09-4751-af50-7d6515a42327', '946e3e16-b54b-491a-9f70-b44c3376ffbd', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 1, null, null),
('4eaa8c43-5624-4088-86b3-aac086e1a5b8', '946e3e16-b54b-491a-9f70-b44c3376ffbd', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 2, null, null),
('e7d7e889-63da-461c-b28a-11db2049292b', '946e3e16-b54b-491a-9f70-b44c3376ffbd', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 3, 'Gram', 1.3, 3, null, null),
('955548d9-b02c-4d66-a88c-bead80c22011', '946e3e16-b54b-491a-9f70-b44c3376ffbd', '685881f5-24b8-4b97-8f20-6c308939e5b8', 'material', 2, 'Gram', 0.8, 4, null, null),
('62c13488-e556-4f25-8624-97df77bd1080', '0c167350-fed4-4221-bff4-046b0761ec06', '5a01b3bb-659f-4283-8c4e-a5abcea87c3d', 'material', 105, 'Gram', null, 0, null, null),
('0435696f-7fe2-40a9-9a37-ede17450fb5d', '0c167350-fed4-4221-bff4-046b0761ec06', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 60, 'Gram', 53.04, 1, null, null),
('96d8e6f8-130a-4012-aff7-1dc354b79fb1', '0c167350-fed4-4221-bff4-046b0761ec06', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 10, 'Gram', 5.38, 2, null, null),
('ace04602-d9f3-4190-a9a2-9ff2965f6280', '0c167350-fed4-4221-bff4-046b0761ec06', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 3, null, null),
('a3545140-e9fa-43a4-96ff-02f7e42afa92', '0c167350-fed4-4221-bff4-046b0761ec06', 'b479c62b-6c8b-4284-b19f-086e313b3b8f', 'material', 7, 'Gram', null, 4, null, null),
('263465e8-a212-492e-bc67-8be0fa67f489', 'a7968776-c94a-4829-9672-59fe92c443c2', '7477a6c9-679b-401a-b336-08c3b7212562', 'material', 200, 'Gram', 56.7, 0, null, null),
('f3ea3952-dfa1-469e-8e60-c7481fcc9e70', 'a7968776-c94a-4829-9672-59fe92c443c2', '0f5ce0e7-0d55-444e-9fb3-b14854e20eb5', 'material', 5, 'Gram', 1.88, 1, null, null),
('28cbe644-cc98-4b0e-b381-b624de116549', 'a7968776-c94a-4829-9672-59fe92c443c2', '640252b8-8656-48f9-9e79-4786be64cb50', 'material', 3, 'Gram', 1.06, 2, null, null),
('59e20fc4-a580-4ad5-ad0c-ae0d6b94ff97', 'a7968776-c94a-4829-9672-59fe92c443c2', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 10, 'Gram', 4.32, 3, null, null),
('062c37fd-ccd9-4cfa-b067-9ad32ece37f3', 'a7968776-c94a-4829-9672-59fe92c443c2', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 20, 'Gram', 8.75, 4, null, null),
('67ec0fb2-8093-4aba-beb7-f1b2e47dcb83', 'a7968776-c94a-4829-9672-59fe92c443c2', '5e3f59f1-e05c-475a-9cef-88a3cd13762d', 'material', 5, 'Gram', 27.5, 5, null, null),
('4b5db66c-0722-47ae-9200-9f035c327d94', 'a7968776-c94a-4829-9672-59fe92c443c2', 'd705bb87-2327-4b48-b6d1-5847faf2715b', 'material', 0, 'Gram', null, 6, null, null),
('885da50b-ae28-48e2-9d0a-fc010cd24ba5', 'a7968776-c94a-4829-9672-59fe92c443c2', '0bdc23a5-f399-4915-8c7a-2fde9283b0ec', 'material', 44, 'Gram', null, 7, null, null),
('d4d036a0-867b-4bec-827a-a78e57329142', 'a7968776-c94a-4829-9672-59fe92c443c2', 'aacfccd4-46fa-4868-9925-006d4a295d9c', 'material', 0, 'Gram', 0, 8, null, null),
('2e9a9802-2853-4b2b-814f-076ba547e1b5', 'a7968776-c94a-4829-9672-59fe92c443c2', '061a188b-cdc5-4c7b-b1b0-0a54408ba0bd', 'material', 40, 'Gram', null, 9, null, null),
('41340e72-8385-4dfc-a0e1-0f67d49602c3', 'a7968776-c94a-4829-9672-59fe92c443c2', '90587a4f-429b-4433-896a-7bb987b384ea', 'material', 30, 'Gram', null, 10, null, null),
('28234094-03b5-4464-89ce-bda5060088e2', 'a7968776-c94a-4829-9672-59fe92c443c2', '504426a0-aa6e-4ffb-9e92-70c7dd45aaa5', 'material', 0, 'Gram', null, 11, null, null),
('794218e0-4e0d-47b4-970c-13287f4f1437', 'a7968776-c94a-4829-9672-59fe92c443c2', '20cd6c75-3dc5-43cf-b477-0660449e1d5a', 'material', 0, 'Gram', 0, 12, null, null),
('377a01c9-f1ea-4e5e-b86f-d0ae98c735a1', 'a7968776-c94a-4829-9672-59fe92c443c2', 'da7bcdcc-c4b9-4d9c-8056-e4512ec1267e', 'material', 150, 'Gram', 34.5, 13, null, null),
('dc0b59db-c9ec-421e-86d0-31239ae92a9e', 'a7968776-c94a-4829-9672-59fe92c443c2', 'd6c43012-099d-4256-88ec-7d5ba9431c18', 'material', 15, 'Gram', 4.5, 14, null, null),
('432e1403-c116-4868-b569-83df96d6fa06', 'a7968776-c94a-4829-9672-59fe92c443c2', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 15, null, null),
('ffb0374e-dcd5-4431-b2e5-eefed07a8dc3', 'a7968776-c94a-4829-9672-59fe92c443c2', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 5, 'Gram', 2.16, 16, null, null),
('0d182f09-d3d4-4d01-b824-53567b898c32', 'a7968776-c94a-4829-9672-59fe92c443c2', 'b680c705-fa76-4754-87e0-ddae44a7d288', 'material', 0, 'Gram', null, 17, null, null),
('9462b42c-b3b9-48ea-9969-552504ee5c29', 'bbea77c6-5973-462c-9399-bc97e33865b0', '77a643c1-3d63-4f92-b917-b1cef91673f2', 'material', 280, 'Gram', 78.4, 0, null, null),
('de18b83c-26cb-4029-ad21-b95cdf1d9e67', 'bbea77c6-5973-462c-9399-bc97e33865b0', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 15, 'Gram', 2.14, 1, null, null),
('0bbb2d9f-28d5-4055-a98a-a4374c659017', 'bbea77c6-5973-462c-9399-bc97e33865b0', 'd6c43012-099d-4256-88ec-7d5ba9431c18', 'material', 23, 'Gram', 6.9, 2, null, null),
('cc94845e-7cd7-43e5-8cc6-fcb10ecd0588', 'bbea77c6-5973-462c-9399-bc97e33865b0', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 3, null, null),
('7c5dc990-cbe6-4b84-b68d-3b55be817708', 'bbea77c6-5973-462c-9399-bc97e33865b0', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 4, null, null),
('4dd10d7b-b990-4fa0-a717-389b3c4434b8', 'bbea77c6-5973-462c-9399-bc97e33865b0', '72fe8754-6331-4dc3-a22c-6a20baea3b3d', 'material', 10, 'Gram', 6, 5, null, null),
('8139fb23-30fe-4a0a-a1e5-a8f576a8dbff', 'bbea77c6-5973-462c-9399-bc97e33865b0', 'f37f1adf-828b-4fc4-a5ed-549ee14e4eb1', 'material', 3, 'Gram', 3, 6, null, null),
('5d713a95-7585-4d4b-b3b8-b330f537a36b', 'bbea77c6-5973-462c-9399-bc97e33865b0', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 5, 'Gram', 2.16, 7, null, null),
('4ed94e0f-7435-4fc2-ab9b-e3877725b08d', 'bbea77c6-5973-462c-9399-bc97e33865b0', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 5, 'Gram', 1.67, 8, null, null),
('1530b9ef-78c0-4a92-af74-2165e89647af', 'bbea77c6-5973-462c-9399-bc97e33865b0', 'bc972565-c980-47a7-b35a-8cbdcd4b98a0', 'material', 1, 'Gram', 1, 9, null, null),
('9feff8d8-6604-4084-8dca-6a0830265613', 'bbea77c6-5973-462c-9399-bc97e33865b0', '640252b8-8656-48f9-9e79-4786be64cb50', 'material', 3, 'Gram', 1.06, 10, null, null),
('5968a777-3b33-4c95-8ce9-5bc6bb4e4460', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 10, 'Gram', 10.5, 0, null, null),
('f8d48d15-4fc2-49c7-b675-5a7120900539', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', 'fa967cec-45bf-4c80-9e0d-1ff65fc7e5a7', 'material', 120, 'Gram', null, 1, null, null),
('9ddb4cc0-c52f-40c4-87c0-7dc900e31e7e', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 2, null, null),
('d468dfde-4819-44fb-9bf1-85f951e21309', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '8dcd19e2-0059-42d9-9b43-acccfab286e4', 'material', 10, 'Gram', 3.33, 3, null, null),
('2c5e5a75-8d31-465a-81b1-1516296793b4', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '25fe4bcd-157a-4e95-bfe3-eb021072efc8', 'material', 5, 'Gram', 1.48, 4, null, null),
('1d5dbda2-6bfb-448f-bca2-ab34d4443a14', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', 'c6c7c652-58ac-47e1-aae4-d5893927cb73', 'material', 5, 'Gram', 5.25, 5, null, null),
('14581e83-2c9a-4571-b03d-c2ee372b9c9b', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '3dce999f-94cc-4a6e-8a2a-66b783072cc0', 'material', 0, 'Gram', null, 6, null, null),
('28a62d58-7d6c-41dc-a217-7848260013af', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 230, 'Gram', 203.32, 7, null, null),
('007b3775-ee57-46c9-b86c-6e3df475f37f', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', 'a4a3f519-e291-469b-af2d-903380108454', 'material', 150, 'Gram', 16.89, 8, null, null),
('75c0f9e3-3a77-45de-8144-d1c34bdf51a7', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 60, 'Gram', 10.92, 9, null, null),
('e9fd7103-0a89-4b05-8b0a-de58793e1208', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', 'fd8fcf20-248e-4286-8b74-a98b6b4ae748', 'material', 60, 'Gram', null, 10, null, null),
('9a3951e2-5721-4ea0-afcb-dcc8fde33560', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '3dce999f-94cc-4a6e-8a2a-66b783072cc0', 'material', 0, 'Gram', null, 11, null, null),
('04f87c19-1d8b-47eb-8214-134f75aead3a', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '4a7a50c5-56ae-4a76-ac40-94f11c58e9fb', 'material', 4, 'Piece', 0.8, 12, null, null),
('721d093d-d124-4ff6-89ad-32794065a518', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '4cefc6e3-d0a7-4bc9-86ee-b4e947c05cb3', 'material', 3, 'Gram', 1, 13, null, null),
('86a98f3d-3563-4313-b1af-f23b5a9e355b', 'fca77966-afc1-4482-9f3a-00d7dfa278c4', '533fe6b6-32fc-476a-b573-321cac42b448', 'material', 3, 'Gram', 2.44, 14, null, null),
('46cfa9eb-2801-4c10-a87e-cc73ce9c56e5', '455d471b-81c2-471b-a672-7a6caa6da40e', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 2, 'Piece', 2.1, 0, null, null),
('a75e1871-d660-47a0-a02b-327727205378', '455d471b-81c2-471b-a672-7a6caa6da40e', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 120, 'Gram', 8, 1, null, null),
('91f0b6b0-6bca-4c3a-bfe1-fa7cbd94142a', '455d471b-81c2-471b-a672-7a6caa6da40e', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 15, 'Gram', 4.5, 2, null, null),
('3d9e01a5-3c11-43e8-b648-48a092a2a275', '455d471b-81c2-471b-a672-7a6caa6da40e', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 100, 'Gram', 5.71, 3, null, null),
('dbadf820-dd83-41a7-9d6d-8769b804af5c', '455d471b-81c2-471b-a672-7a6caa6da40e', '16fad0af-d727-4024-b7df-1d40f8a772c2', 'material', 800, 'Gram', null, 4, null, null),
('47b35d8a-4d62-4fe1-99f5-262e1e125dfe', '455d471b-81c2-471b-a672-7a6caa6da40e', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 11, 'Gram', 3.43, 5, null, null),
('58e07c2b-ed12-436c-9a7a-0ea375656f32', '455d471b-81c2-471b-a672-7a6caa6da40e', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 500, 'ML', 0, 6, null, null),
('0ce31cb4-5661-410d-9a5e-18c323310ff7', '455d471b-81c2-471b-a672-7a6caa6da40e', '903ae796-c7c0-4980-8dc5-37ba93e2b08a', 'material', 30, 'Gram', null, 7, null, null),
('5ae4cc5f-6d14-4229-bd23-2ada1e717ef0', '455d471b-81c2-471b-a672-7a6caa6da40e', '9adbaa1b-78e5-402a-8406-36069475dec6', 'material', 2, 'Gram', null, 8, null, null),
('2536fd42-9ecf-42fd-94bd-08a913773193', '455d471b-81c2-471b-a672-7a6caa6da40e', '8f14e45a-469a-49e5-85bc-28eb517c0824', 'material', 1, 'Piece', null, 9, null, null),
('45a18a3f-a130-4dc5-b3b0-67e60ed02d78', '455d471b-81c2-471b-a672-7a6caa6da40e', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 0, 'Gram', 0, 10, null, null),
('4ed48696-ac76-48d9-a78b-059a45ac48ff', '455d471b-81c2-471b-a672-7a6caa6da40e', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0, 'Gram', 0, 11, null, null),
('339f851a-59de-4b16-9022-f5301ef4e2c6', '455d471b-81c2-471b-a672-7a6caa6da40e', 'ef350584-df07-468c-b284-aefedabd4035', 'material', 10, 'Gram', null, 12, null, null),
('30abc7ad-c8be-4da0-bab4-daa35ac4b7b5', '455d471b-81c2-471b-a672-7a6caa6da40e', '13d6f71d-5a29-427c-928d-6a5697027730', 'material', 2, 'Piece', null, 13, null, null),
('2bb49208-3dd7-433e-89b6-471f6305f532', '455d471b-81c2-471b-a672-7a6caa6da40e', '630054b2-f2b0-4367-bdff-94c9bdec7e44', 'material', 1, 'Piece', null, 14, null, null),
('630add5c-5d90-4616-a523-ca3e8c364be2', '455d471b-81c2-471b-a672-7a6caa6da40e', '860de630-add7-4831-be3d-bba2aeab197c', 'material', 5, 'Gram', null, 15, null, null),
('7bb8c8ac-35e1-4257-9ad5-5e42ca9b92fd', '8337d712-68b0-4468-b6f2-ff956bff418f', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 0, null, null),
('544160f4-19e0-4d0f-8e71-5509cc57483d', '8337d712-68b0-4468-b6f2-ff956bff418f', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 5, 'Gram', 0.71, 1, null, null),
('8404d16f-21bf-427e-b46c-265b1ea8d874', '8337d712-68b0-4468-b6f2-ff956bff418f', 'e2cf9241-1044-49d4-90d4-9daf748a0a49', 'material', 40, 'Gram', 12, 2, null, null),
('bcd71d98-c9a2-4686-8e68-0a555942d226', '8337d712-68b0-4468-b6f2-ff956bff418f', 'b3d7496e-95b2-47d9-9dd6-26ca430cbf31', 'material', 220, 'Gram', 47.59, 3, null, null),
('eaa0bdc5-6173-41db-9a1f-fe539c5231c3', '8337d712-68b0-4468-b6f2-ff956bff418f', '6bcc2acf-bccd-4bf0-af3d-9e4eef5c0920', 'material', 140, 'Gram', 15.47, 4, null, null),
('e2d189d8-f84b-44ff-bfee-8a9185e15e55', '8337d712-68b0-4468-b6f2-ff956bff418f', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 6.8, 'Gram', 2.27, 5, null, null),
('12e9ee58-9d19-45fc-a238-6d63ae338539', '8337d712-68b0-4468-b6f2-ff956bff418f', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('71b8d832-0457-4475-b183-746063f961ac', '8337d712-68b0-4468-b6f2-ff956bff418f', '640252b8-8656-48f9-9e79-4786be64cb50', 'material', 1, 'Gram', 0.35, 7, null, null),
('2db96eee-e351-4fac-875a-ba1181857800', '8337d712-68b0-4468-b6f2-ff956bff418f', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 3, 'Gram', 0.3, 8, null, null),
('e9f2bc50-99ab-433a-9ed3-a5117a554825', '8337d712-68b0-4468-b6f2-ff956bff418f', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 7, 'Gram', 3.06, 9, null, null),
('a9164115-87fb-4055-9f0c-3bfba7c00b6e', '8337d712-68b0-4468-b6f2-ff956bff418f', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 0, 'Gram', 0, 10, null, null),
('9db5a214-3be5-4603-a17f-b07042bfa45d', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', 'faccddca-da01-418a-8285-187ebf850712', 'material', 120, 'Gram', 12.22, 0, null, null),
('032e3e40-5cd2-41ea-938b-737424205941', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 1, null, null),
('b0b73252-399f-4bd3-b23e-d29c8d6412fa', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', '7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'material', 10, 'Gram', 2, 2, null, null),
('e1a30779-2407-43a0-b993-c50a0d627830', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 5, 'Gram', 1.67, 3, null, null),
('8bc4c65e-d8fd-43ee-84a9-0da071313759', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 0.5, 'Gram', 0.5, 4, null, null),
('4f063364-3de4-4aaa-b42f-c2cbf153ab53', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', 'eb6aa82b-f8c1-497d-8a2e-5751212f6c43', 'material', 10, 'Gram', 2.06, 5, null, null),
('a9b2a32f-6e1b-44e3-9ccd-29100221e37e', '9648baa5-e131-4076-bd57-5fa1f9ac9e85', '9a084fde-1b40-4d4b-94d3-c12aeab111d7', 'material', 200, 'Gram', null, 6, null, null),
('348db9e3-671c-436b-a461-7c59eca029d6', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', 'c8d2e692-f0ae-44bd-851e-b893ccd957c8', 'material', 140, 'Gram', null, 0, null, null),
('a4ec9c73-b225-4a60-9fec-e5bcbb45a103', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '0809ed32-c211-4a88-8ac2-a5e4a140c45a', 'material', 190, 'Gram', null, 1, null, null),
('1e3ef97a-49ed-4f5f-9aa0-45acdea1da07', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 2, null, null),
('d26244c4-c217-42e8-8c93-f8c023df1bfb', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 5, 'Gram', 0.71, 3, null, null),
('8e137ccc-5283-462b-a3b6-8425c36e561f', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', 'd6c43012-099d-4256-88ec-7d5ba9431c18', 'material', 10, 'Gram', 3, 4, null, null),
('17aa7c25-912a-4148-847d-9e373447d666', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '5e3f59f1-e05c-475a-9cef-88a3cd13762d', 'material', 1, 'Gram', 5.5, 5, null, null),
('3f35dae4-06dd-42f1-848b-a7bc5545dd97', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 1, 'Gram', 0.43, 6, null, null),
('969ca443-dea0-44f7-8a1f-cfcc0ee6c60d', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 6, 'Gram', 2, 7, null, null),
('4bde3478-b3cd-4b93-b442-ddaf8db19280', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 1, 'Gram', 1, 8, null, null),
('548eb9c2-c89d-4238-93b2-627e366d9ef3', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 7, 'Gram', 3.06, 9, null, null),
('c7be5ce5-119b-40d3-b7dd-91723b9c2936', 'a08407d7-657f-4935-8d96-b1fc4f07ed37', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 100, 'Gram', 0, 10, null, null),
('d00a8cb9-6a44-4d69-8fbb-e27345927912', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '286c2b14-dda0-4e70-97eb-d604e6df4c92', 'material', 140, 'Gram', null, 0, null, null),
('d3098005-9125-46f9-a71a-585437da2819', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '16e94c48-5c75-4c29-b4be-ad1891376945', 'material', 180, 'Gram', 43.69, 1, null, null),
('2404ab32-d7fe-429b-b170-5cfd8fd7f45c', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '65003fce-46f4-43ea-a077-b8150a80ee9f', 'material', 60, 'Gram', 48.7, 2, null, null),
('594f2a49-5850-426b-af1a-f7ed84df24c2', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', 'bdb322a5-bd3a-4960-a5f3-a1172b2b949f', 'material', 5, 'Gram', 5, 3, null, null),
('f434bc8b-63fe-4968-9d32-7f89da68418f', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 18, 'Gram', 5.6, 4, null, null),
('701485cf-2f62-4c2f-911c-bc2c0b1b732f', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 5, null, null),
('64fa1bb6-1e0a-4ffe-ae07-af466970f8d9', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 7, 'Gram', 3.06, 6, null, null),
('548d2aa7-734c-46eb-ba0b-2f694ae2acde', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 0.5, 'Gram', 0.17, 7, null, null),
('53011870-39a0-4bfa-bc0c-16e6818fcf66', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', 'bc972565-c980-47a7-b35a-8cbdcd4b98a0', 'material', 2, 'Gram', 2, 8, null, null),
('eb90f702-6471-4c99-9a2d-a771fec6e024', '0dc3b12b-ef71-4ad8-9ed0-cac5116bcec7', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 2, 'Gram', 0.47, 9, null, null),
('c16fc336-16d3-4665-b516-8c5e11286a65', '668bcd9b-09ec-42fa-b987-3992a61bb381', 'a0b74fc9-989e-40f7-865f-43a7a9bd1b39', 'material', 100, 'Gram', null, 0, null, null),
('7824276f-922f-41f3-aca7-86a292084de4', '668bcd9b-09ec-42fa-b987-3992a61bb381', '6b4bcc93-fdab-4c23-a7e4-7904968eb49f', 'material', 7, 'Gram', 6.46, 1, null, null),
('ae9f8eb4-1737-4aa2-a7fc-140c4cc3b0f4', '668bcd9b-09ec-42fa-b987-3992a61bb381', '9a8589f1-7b15-4762-ab68-34ce8954b1d7', 'material', 8, 'Gram', null, 2, null, null),
('4c4b0dcf-c6fd-4148-bcd6-1ed180833730', '668bcd9b-09ec-42fa-b987-3992a61bb381', '0809ed32-c211-4a88-8ac2-a5e4a140c45a', 'material', 40, 'Gram', null, 3, null, null),
('35c3247c-8568-45f5-9a61-e4aa7a2ffcc2', '668bcd9b-09ec-42fa-b987-3992a61bb381', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 5, 'Gram', 2.19, 4, null, null),
('a9ba8d45-1449-4708-84ef-51ed2d35e3ec', '668bcd9b-09ec-42fa-b987-3992a61bb381', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 5, 'Gram', 1.67, 5, null, null),
('7bce65b8-8d26-472a-ae3a-e505df9e56a4', '668bcd9b-09ec-42fa-b987-3992a61bb381', 'bc972565-c980-47a7-b35a-8cbdcd4b98a0', 'material', 0.5, 'Gram', 0.5, 6, null, null),
('662c4d39-225e-4355-b816-1e6e9c2a7d62', '668bcd9b-09ec-42fa-b987-3992a61bb381', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 5, 'Gram', 1.5, 7, null, null),
('a9390c9a-0fec-4089-9923-799892151aca', '668bcd9b-09ec-42fa-b987-3992a61bb381', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 8, null, null),
('cbf8150e-1e82-4001-8bc3-f8f601c720b4', '668bcd9b-09ec-42fa-b987-3992a61bb381', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 5, 'Gram', 0.71, 9, null, null),
('a8802978-da21-47c5-ac42-f28e0c5d43a1', '668bcd9b-09ec-42fa-b987-3992a61bb381', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 100, 'Gram', 0, 10, null, null),
('88cd1fe0-a77a-42c2-b560-6fce3a3ac60a', 'eae4f764-a818-454e-8e5b-08f694454e05', 'd14d3fbd-7412-4218-92fa-b977accd34a9', 'material', 120, 'Gram', null, 0, null, null),
('66765eb9-331d-4e89-93b1-01a5f971117b', 'eae4f764-a818-454e-8e5b-08f694454e05', '28ebfde5-dff4-4213-8a2e-61f93d74a550', 'material', 60, 'Gram', null, 1, null, null),
('c6ea66ef-eb19-45d1-8a70-8b715f53fe67', 'eae4f764-a818-454e-8e5b-08f694454e05', 'e49a27b3-21f5-4961-a174-6ad4e2c96e7c', 'material', 50, 'Gram', null, 2, null, null),
('a3e5a162-679b-4d7b-be75-eea1ff69bef0', 'eae4f764-a818-454e-8e5b-08f694454e05', 'e9eb67bf-d842-4446-8845-ad37ffb82b9b', 'material', 40, 'Gram', null, 3, null, null),
('b5698620-58ad-43ac-8291-5571df3e70a5', 'eae4f764-a818-454e-8e5b-08f694454e05', '8dcd19e2-0059-42d9-9b43-acccfab286e4', 'material', 10, 'Gram', 3.33, 4, null, null),
('3db0d61e-e6d7-4f6e-88ac-a2b68db4f045', 'eae4f764-a818-454e-8e5b-08f694454e05', '77f9e29f-f7bf-4b9e-9edc-dd3e5ea6f398', 'material', 400, 'Gram', null, 5, null, null),
('650456de-ac93-4842-a6a8-952e31c125d7', 'eae4f764-a818-454e-8e5b-08f694454e05', 'aacfccd4-46fa-4868-9925-006d4a295d9c', 'material', 20, 'Gram', 4.86, 6, null, null),
('1ad79a5d-3ba7-464e-a9f6-276b823c5802', 'eae4f764-a818-454e-8e5b-08f694454e05', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 15, 'Gram', 15.75, 7, null, null),
('0a4469bb-ca6a-4c59-8d6b-0dbacde290ca', 'eae4f764-a818-454e-8e5b-08f694454e05', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 4, 'Gram', 1.33, 8, null, null),
('0e78221c-0cb6-4863-9538-c9b2b04d1e22', 'eae4f764-a818-454e-8e5b-08f694454e05', 'bc972565-c980-47a7-b35a-8cbdcd4b98a0', 'material', 1, 'Gram', 1, 9, null, null),
('920675a9-f15a-4287-8216-f790d38de5a9', 'eae4f764-a818-454e-8e5b-08f694454e05', '9d26d557-8234-42eb-a4f9-150802d293d2', 'material', 2, 'Gram', null, 10, null, null),
('c6f460b7-1c77-445a-a672-e7fbbd7190d3', 'eae4f764-a818-454e-8e5b-08f694454e05', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 40, 'Gram', 21.52, 11, null, null),
('fde845ee-c999-486b-b3e3-de1e992588e0', 'eae4f764-a818-454e-8e5b-08f694454e05', 'd38b6fc3-0586-4f9e-ac32-cf20928a56ef', 'material', 40, 'Gram', null, 12, null, null),
('f763c6fa-082c-4c51-bcfd-883fd8cab12d', 'eae4f764-a818-454e-8e5b-08f694454e05', '83f7d5a7-4302-460c-bd6a-0041bc9f1c17', 'material', 500, 'Gram', 38.35, 13, null, null),
('f5f6a701-7a42-4168-a4aa-739d0a33a418', 'eae4f764-a818-454e-8e5b-08f694454e05', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 4, 'Gram', 1.33, 14, null, null),
('cdf283aa-e20f-42df-9a55-eecd4382c7dd', 'eae4f764-a818-454e-8e5b-08f694454e05', '35961148-891f-4350-88dc-8c9183b1110f', 'material', 0.5, 'Gram', null, 15, null, null),
('5159d6f1-e8a2-4176-ac04-3569c2f6d85e', 'eae4f764-a818-454e-8e5b-08f694454e05', '6e81805d-9739-4091-bbca-89cd3ff8e4bc', 'material', 6, 'Piece', null, 16, null, null),
('1118268a-8245-4aa8-9ea0-62acf9539a4c', 'eae4f764-a818-454e-8e5b-08f694454e05', '9c261165-2339-4ea9-8a05-97ef02db523a', 'material', 200, 'Gram', null, 17, null, null),
('50406ec0-72d6-4eeb-abc6-c4a26e365303', 'eae4f764-a818-454e-8e5b-08f694454e05', '1d2fe5d4-c10c-400c-ad8c-3ae390085606', 'material', 30, 'Gram', null, 18, null, null),
('0ffafb9b-8155-4be2-a064-b5f8d3e90c3a', '387baee2-045e-4009-ab2e-219742526817', '289c679d-223d-4910-b7f9-bd7e8f7d9139', 'material', 250, 'Gram', 72, 0, null, null),
('6c39706e-785f-43fc-b7e4-d23e0cb01cc0', '387baee2-045e-4009-ab2e-219742526817', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 100, 'Gram', 88.4, 1, null, null),
('c6629b18-1349-4ce5-a647-03c790c423ab', '387baee2-045e-4009-ab2e-219742526817', '8857df4a-3268-4510-8623-e8fcacfd17d8', 'material', 100, 'Gram', 50, 2, null, null),
('43ade913-eb9a-4a01-a383-cd81ce5eadef', '387baee2-045e-4009-ab2e-219742526817', 'e24d5339-fda0-4a4d-9874-3c4da2f69e90', 'material', 30, 'Gram', 11, 3, null, null),
('b7da7c5f-5e95-4c18-ada3-45ea02577a75', '387baee2-045e-4009-ab2e-219742526817', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 1, 'Gram', 0.33, 4, null, null),
('3a09d092-c1d9-4827-b9f9-42cc5db3b396', '387baee2-045e-4009-ab2e-219742526817', 'b8ad745a-aff0-49d6-a352-b50f0be7a6a8', 'material', 1, 'Gram', 1, 5, null, null),
('537c39d2-7ab7-4d08-bc0e-6f3dbf32b155', '387baee2-045e-4009-ab2e-219742526817', '30879b7e-f481-483f-9820-166fa21845ae', 'material', 5, 'Piece', null, 6, null, null),
('f4dc5ec7-7189-46e9-a620-ff79081d13e9', '387baee2-045e-4009-ab2e-219742526817', '40d5a868-a306-4ab0-83c7-885a4fc49a0e', 'material', 150, 'Gram', null, 7, null, null),
('a5564c19-f8cf-49be-a61d-6ede976c8c02', '387baee2-045e-4009-ab2e-219742526817', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 10, 'Gram', 4.38, 8, null, null),
('485eeae1-b750-4905-b745-e951114d8b4c', '387baee2-045e-4009-ab2e-219742526817', '5e880a4e-3dfa-45cd-97e3-d262ed9a129a', 'material', 10, 'Gram', 3.13, 9, null, null),
('6996f3cb-025c-41d8-89c9-f5c1597ed61a', '387baee2-045e-4009-ab2e-219742526817', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 5, 'Gram', 0.78, 10, null, 'Slit'),
('f06bf612-c782-4a38-a05a-1bc61de691db', '387baee2-045e-4009-ab2e-219742526817', 'a401cf35-ade5-43e1-a32e-3c5b21084620', 'material', 5, 'Gram', 2.1, 11, null, null),
('30b4a797-f722-44c0-ae67-49432bca5197', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 10, 'Gram', 10.5, 0, null, null),
('05f40c77-7b32-4f8a-ba83-cfe2a9c4c39a', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'd6c43012-099d-4256-88ec-7d5ba9431c18', 'material', 5, 'Gram', 1.5, 1, null, null),
('46f31533-b5e0-48c8-8da6-ee3618a0ef1f', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '727e5c9e-6dcc-4856-b048-2ba6d09e9492', 'material', 60, 'Gram', 7.2, 2, null, null),
('dba43148-c7d8-4d82-9eeb-8839a83b3f5f', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '9dc8de2e-9838-49ca-972d-4568a6836892', 'material', 60, 'ML', null, 3, null, null),
('1b13071c-bcc6-4141-a76e-419508a052fe', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'fbf3e709-84a2-4c3d-8a94-6d142ccf3bbc', 'material', 140, 'Gram', null, 4, null, null),
('471993c7-cf42-40cb-8ec6-40afc54b40a1', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '8e47b336-d659-48a4-9fd9-ca0d96a14ff1', 'material', 4, 'Gram', null, 5, null, null),
('c1289a56-4b25-4eb9-b189-5934ad92d7ec', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'eb6aa82b-f8c1-497d-8a2e-5751212f6c43', 'material', 80, 'Gram', 16.48, 6, null, null),
('eb345303-6941-4fcd-8050-21e443718128', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '6e7c045e-a616-4f2d-a573-758fe4470b8c', 'material', 10, 'Gram', null, 7, null, null),
('55a8b8fd-4993-41af-b18d-bafcd27cbf09', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', 'bd0f0209-f0d8-4481-bc7c-c6db11cf7665', 'material', 10, 'Gram', 1.6, 8, null, null),
('f5f54547-3825-4c1f-89e9-32cb2e8c5179', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 10, 'Gram', 4.38, 9, null, null),
('ccd80167-4c11-4691-a3f3-5b22358d4e79', 'b7a127e6-9ca7-4e56-bcf0-f41950665a4c', '2e989fb8-4913-4426-bb04-d5475c925c3c', 'material', 1, 'Piece', 0.43, 10, null, null),
('93340d9e-4520-42b2-a184-afa5bc4f8206', '279cff51-75b3-4169-a228-4e4f89631c31', 'e3711058-30f6-4a47-92b4-d7cc89cc4788', 'material', 30, 'Gram', 4.17, 0, null, 'Paste'),
('b328075a-7fb3-4f75-9cb5-c062c7adbc32', '279cff51-75b3-4169-a228-4e4f89631c31', 'b9123422-9c7b-4b11-8ee6-584d34c0d6f0', 'material', 120, 'Gram', 48.64, 1, null, null),
('bd14c317-0d15-4e56-bafc-898d44eb9668', '279cff51-75b3-4169-a228-4e4f89631c31', '853c4aeb-73c9-4551-802b-17718fcb35bd', 'recipe', 50, 'Gram', 7.89, 2, null, null),
('5ad55369-ffeb-4fa7-b5c9-7889d1c4f578', '279cff51-75b3-4169-a228-4e4f89631c31', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 3, 'Gram', 1, 3, null, null),
('1891bf4f-7a1f-4122-9ff3-09915ea13eff', '279cff51-75b3-4169-a228-4e4f89631c31', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 1, 'Gram', 1, 4, null, null),
('e6b0ede6-c0e9-491a-98e1-16db74931659', '279cff51-75b3-4169-a228-4e4f89631c31', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 8, 'Gram', 3.5, 5, null, null),
('4b608a04-8569-4e24-867c-9e68ffcde589', '279cff51-75b3-4169-a228-4e4f89631c31', '640252b8-8656-48f9-9e79-4786be64cb50', 'material', 3, 'Gram', 1.06, 6, null, null),
('9d5a9914-123a-40d6-a349-3b571b4270d5', '279cff51-75b3-4169-a228-4e4f89631c31', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 7, null, null),
('1e1063a0-b9da-41d0-8818-85f5fc7c11e6', '279cff51-75b3-4169-a228-4e4f89631c31', 'd6d16551-8e8c-4daf-bebd-fd4a300ed9e6', 'material', 1, 'Piece', null, 8, null, null),
('67981c2d-26bb-48ca-8b10-f80e1e28efeb', '279cff51-75b3-4169-a228-4e4f89631c31', 'bce8bdf0-addd-4eb3-a4b5-58facd7e8f9f', 'material', 5, 'Gram', null, 9, null, null),
('ea51db59-5e7a-47a1-a600-296af36b8572', '279cff51-75b3-4169-a228-4e4f89631c31', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 5, 'Gram', 5.25, 10, null, null),
('92de77f9-d1b2-4cdb-93d2-7448f12a9453', '279cff51-75b3-4169-a228-4e4f89631c31', 'a0d7f5ef-e393-4faa-a564-12f1363a991b', 'material', 2, 'Gram', 2, 11, null, null),
('dfffbc9b-819b-4e48-ac05-a56ad1caa8f4', 'c0698b42-389e-4912-86ea-edb86f5c779f', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 10, 'Gram', 10.5, 0, null, null),
('eefd49dd-440b-400f-a729-b94b308181c3', 'c0698b42-389e-4912-86ea-edb86f5c779f', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 5, 'Gram', 1.5, 1, null, null),
('06e212f6-d07a-46c6-8cde-33baaaabb0c9', 'c0698b42-389e-4912-86ea-edb86f5c779f', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 5, 'Gram', 0.33, 2, null, null),
('673e9d1f-ebad-46db-892d-8868f4b55579', 'c0698b42-389e-4912-86ea-edb86f5c779f', 'da7bcdcc-c4b9-4d9c-8056-e4512ec1267e', 'material', 90, 'Gram', 20.7, 3, null, null),
('68be649f-e5e1-407a-ad68-3d502da0c02e', 'c0698b42-389e-4912-86ea-edb86f5c779f', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 50, 'ML', 0, 4, null, null),
('ec864a07-c3b9-45eb-8047-4d008496a6ec', 'c0698b42-389e-4912-86ea-edb86f5c779f', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 3, 'Gram', 1, 5, null, null),
('c16f86a7-6dd4-4650-91f5-f3c496c5e03a', 'c0698b42-389e-4912-86ea-edb86f5c779f', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 2, 'Gram', 2, 6, null, null),
('cc4ffd29-9661-4c5a-8f42-d5d8e93a502d', 'c0698b42-389e-4912-86ea-edb86f5c779f', '6adc70e8-45bf-471c-94fb-15168f0873e8', 'material', 100, 'Gram', 38.46, 7, null, null),
('48eecd47-b3ad-41d4-82a6-e8ba6e16b9db', 'c0698b42-389e-4912-86ea-edb86f5c779f', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 10, 'Gram', 4.38, 8, null, null),
('5c348429-2417-435d-bec0-5539cd6f2663', 'c0698b42-389e-4912-86ea-edb86f5c779f', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 9, null, null),
('07a4fd15-aa2c-4ccc-a036-a4d8308b8048', 'c0698b42-389e-4912-86ea-edb86f5c779f', '4bf08737-8962-42eb-917a-2a1abfa0e9a1', 'material', 5, 'Gram', 1, 10, null, null),
('ff173c06-eb4d-4c96-ac40-f27532063574', 'c0698b42-389e-4912-86ea-edb86f5c779f', '5cf3b79b-668b-4771-aada-ce878a8f68d3', 'material', 5, 'Gram', null, 11, null, null),
('7a59563b-413b-4f69-a598-06a5f8853833', 'c0698b42-389e-4912-86ea-edb86f5c779f', '62ccd7fd-5272-4e2b-9a68-406b920a4931', 'material', 5, 'Piece', 5, 12, null, null),
('2355db95-b2be-46b6-86e5-65959b1a439d', 'c0698b42-389e-4912-86ea-edb86f5c779f', '9f916d6b-d9ff-410d-80f5-690fb4646a2d', 'material', 1, 'Gram', 1, 13, null, null),
('c487c770-8c99-4532-9040-ccc96ff6612a', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '25caaa5f-c07e-4029-bb5b-0fd1b7908a67', 'material', 100, 'Gram', 7.27, 0, null, null),
('6faa153f-bc33-4a2c-84fa-083c03d0529e', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', 'a4a3f519-e291-469b-af2d-903380108454', 'material', 50, 'Gram', 5.63, 1, null, null),
('7df29747-06bc-4ab4-b74e-dd6b81063d23', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 30, 'Gram', 25.5, 2, null, null),
('dfb629e8-53e9-4b78-a1a6-e38d73c0532e', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', 'cdd3958a-ac04-4f5c-aa50-6ae71a710b56', 'material', 20, 'Gram', 12.31, 3, null, null),
('4a3979cd-cb4a-4d38-ad7e-f3066c2f7192', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 3, 'Gram', 1, 4, null, null),
('720a3c3d-b05f-472a-9591-a3786766b677', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 1, 'Gram', 1, 5, null, null),
('93416b23-79b6-4566-a683-8b3dc2c76314', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 8, 'Gram', 3.5, 6, null, null),
('8157acba-71a3-4272-b150-2591358e4679', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 20, 'Gram', 10.76, 7, null, null),
('1a73c045-99b3-46df-8799-1cc1e9775d5e', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 5, 'Gram', 4.25, 8, null, null),
('48d745ac-5c04-4ef0-8fe0-fef4e7a13ebb', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', 'cdd3958a-ac04-4f5c-aa50-6ae71a710b56', 'material', 5, 'Gram', 3.08, 9, null, null),
('1cc96b3a-ef18-46ab-b7b0-a402e2e6ae58', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 5, 'Gram', 2.19, 10, null, null),
('813da30b-ffb8-4673-b30a-a008b76ad595', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '8611b762-4b84-4b42-9a35-01c413fe8f07', 'material', 3, 'Gram', 16.07, 11, null, null),
('3aba45bb-2f56-4993-a0ff-5a79742cd5ae', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', 'fc49c4df-fd31-4ee1-9b25-43bd6b0964e7', 'material', 3, 'Gram', 50.01, 12, null, null),
('83c222af-7675-48f5-9db4-e8a578f8c8bf', 'e27fc274-3f9d-483b-b18e-150ff27b2ec1', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 0.5, 'Piece', 0.07, 13, null, null),
('427768e6-40cd-4af1-b583-d21ecd7b2c9b', '069c47b7-1144-4043-b1c3-32dd30444c3c', '01761916-5d6f-43a9-a34b-9fba36bdd958', 'material', 105, 'Gram', null, 0, null, null),
('260c7bd8-6608-4324-8c7b-656b3275fc96', '069c47b7-1144-4043-b1c3-32dd30444c3c', '35a59051-17a7-4f77-be40-4b94b4d725da', 'material', 50, 'Gram', null, 1, null, null),
('4e35de14-0cd6-4df4-8fcc-27fe860b3f0c', '069c47b7-1144-4043-b1c3-32dd30444c3c', '7d3868f1-8ac7-438e-9278-6b6938c39ad9', 'material', 60, 'Gram', 16.8, 2, null, null),
('a5faea4b-ad33-4fe6-9766-c8e963fc5944', 'd46403c7-3ee9-460f-be9b-164fdd22c73a', '2f976f1d-9dfa-4337-988e-fc2cb51d46a0', 'material', 100, 'Gram', 65, 0, null, null),
('551a0dae-a72f-4279-b909-5ef6c23db372', 'd46403c7-3ee9-460f-be9b-164fdd22c73a', '70c4349c-a3f7-4a16-bab4-d15f49d379ba', 'material', 60, 'Gram', null, 1, null, null),
('17d1c367-b066-4914-8aac-a57d90bd771a', 'd46403c7-3ee9-460f-be9b-164fdd22c73a', '472c44c0-7333-4b13-b873-228826cd89d0', 'material', 20, 'Gram', 11.33, 2, null, null),
('8e593247-1947-4ee6-b4ff-d8f105f82523', 'd46403c7-3ee9-460f-be9b-164fdd22c73a', '4d9d5183-e0ee-4371-94ce-b4d64d37ddc3', 'material', 5, 'Gram', 4, 3, null, null),
('701ac073-8abd-4482-9857-a830dba5811b', '5c547f69-6b5d-4fce-a7d5-f37ce01ab0a5', '367b851c-de9e-4cf8-9a2b-3bbd456a5db0', 'material', 40, 'Gram', null, 0, null, null),
('61fc9088-1dbe-4cf1-b71e-952a8f3bb34d', '5c547f69-6b5d-4fce-a7d5-f37ce01ab0a5', 'b76ca1b7-d122-4b4c-beb0-16e98450306e', 'material', 30, 'Gram', null, 1, null, null),
('8608e900-01a1-497f-acd7-420024effdfe', '5c547f69-6b5d-4fce-a7d5-f37ce01ab0a5', 'c466ce11-399b-423a-beab-d8e2fdbc8b4f', 'material', 60, 'Gram', null, 2, null, null),
('10cd4e8c-c50e-44bb-9e14-2aebce0e6673', '5c547f69-6b5d-4fce-a7d5-f37ce01ab0a5', 'e746e4f0-52c9-4e99-b0de-0f412afc4ce1', 'material', 10, 'Gram', null, 3, null, null),
('05d1785a-8538-4663-9980-8d669271b37d', 'f3949a87-3cde-4883-bbd9-121ef477d164', 'dad0278c-3d89-4172-8720-45d3d24d624c', 'material', 40, 'Gram', null, 0, null, null),
('c6bbc3f0-aef8-42d1-9d4e-054984092e68', 'f3949a87-3cde-4883-bbd9-121ef477d164', '7a36f17c-adf9-48f5-a8fa-741e84412d83', 'material', 40, 'Gram', 33.04, 1, null, null),
('5cf8250d-ae27-4e5d-bfb1-ef5a656f0705', 'f3949a87-3cde-4883-bbd9-121ef477d164', 'cbdba68b-784e-4c47-8dcf-d001b7cfd1e2', 'material', 20, 'Gram', 15, 2, null, null),
('92bf5d87-85db-47c9-8e2d-4f5c804230ff', 'f3949a87-3cde-4883-bbd9-121ef477d164', 'f663447a-adc9-49d2-ac13-6ba7ba5ba503', 'material', 10, 'Gram', 2.14, 3, null, null),
('e7bb5d49-b3c3-4d77-b2d7-b1ed74b06294', 'f3949a87-3cde-4883-bbd9-121ef477d164', '57fef89f-ff90-4980-a8c9-0e8c0c579b0d', 'material', 5, 'Gram', null, 4, null, null),
('72dbe763-313c-4242-9a25-7b9f6398fcdb', '7c579d14-dc66-495a-8f2c-8b431f14fe5c', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 30, 'ML', 9.33, 0, null, null),
('0794d470-0f3b-43fa-8624-1b387b807a1e', '7c579d14-dc66-495a-8f2c-8b431f14fe5c', 'dc574485-1cb0-43d9-8850-087e540d05b1', 'material', 60, 'ML', 1.64, 1, null, null),
('d3b3e287-b01a-4ecb-8fae-89850db06551', '7c579d14-dc66-495a-8f2c-8b431f14fe5c', 'ceeb2556-53e3-4ca1-a3ac-d1034336e6cf', 'material', 210, 'ML', null, 2, null, null),
('5b7fedd3-4a4d-498a-9018-4a7d3a3b38bb', '41659ed0-6e97-46bb-b254-cb70a16192e3', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 30, 'ML', 9.33, 0, null, null),
('77f52908-a1f5-4851-95e9-2c48eed9cf7b', '41659ed0-6e97-46bb-b254-cb70a16192e3', 'c076d5b0-3bfc-4b83-b41c-44f2967c5bdb', 'material', 15, 'ML', 0.5, 1, null, null),
('f25abcdb-6d16-43b1-a135-74f2edbbb3f9', '41659ed0-6e97-46bb-b254-cb70a16192e3', '7feab776-8b53-4cb8-a352-3d90be5a2776', 'material', 200, 'ML', null, 2, null, null),
('c303f6c3-2427-4690-bf49-65ecf6d77f48', '8de4f09e-f319-4004-834c-c0b3eada9efa', 'c9565d44-a4c1-4482-9278-519cbb336791', 'material', 60, 'ML', null, 0, null, null),
('c0499eb2-5618-4e37-a27a-46a907a20f3b', '8de4f09e-f319-4004-834c-c0b3eada9efa', '0504eb3a-031f-48d2-ab53-3a2ae43f90f2', 'material', 60, 'ML', 4.51, 1, null, null),
('e25c2be9-f515-4791-8fb1-5f5dd9791615', '8de4f09e-f319-4004-834c-c0b3eada9efa', 'dfe97406-cc92-49a9-afa5-df0fb334ecc8', 'material', 120, 'Gram', 16.5, 2, null, null),
('8cea7d0d-5a90-4574-8508-0a8b293c4588', '8de4f09e-f319-4004-834c-c0b3eada9efa', 'cd40553d-2b30-45a3-893a-e6a12de340af', 'material', 1, 'Piece', 0.19, 3, null, null),
('bde9a4d3-9ec8-49ae-97e0-5a718bc94e8f', '8de4f09e-f319-4004-834c-c0b3eada9efa', '3eb0d177-2561-4a4e-b09f-fd4478013e2d', 'material', 60, 'Gram', 0, 4, null, null),
('39d21564-ca79-4cb4-a191-437275aa6162', '4dfb1ca6-84fb-445d-af64-788e76c5118d', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 30, 'ML', 9.33, 0, null, null),
('d5c67a80-99b3-4fe0-b312-e9993c3504af', '4dfb1ca6-84fb-445d-af64-788e76c5118d', 'b91bfa30-0a5a-4839-9e38-3fcba0053b0d', 'material', 1, 'Piece', null, 1, null, null),
('0364d546-00db-4603-86be-699d22d8d7a4', '4dfb1ca6-84fb-445d-af64-788e76c5118d', '25226db1-6ec8-43a8-979c-569f89792fbb', 'material', 292.5, 'ML', null, 2, null, null),
('b2261d0a-c5f3-43d8-a57c-23b2fc76dac6', 'df80da7c-c7f7-4ab9-98ba-220ee2bd3e21', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 15, 'ML', 4.67, 0, null, null),
('e6a1038d-925a-4915-905d-ad0035d82c60', 'df80da7c-c7f7-4ab9-98ba-220ee2bd3e21', '35ec6646-b882-4e82-9797-468722c65af9', 'material', 60, 'ML', 24.3, 1, null, null),
('a4727f05-dfec-4f53-863e-f635dc1095aa', 'df80da7c-c7f7-4ab9-98ba-220ee2bd3e21', 'baa1d1a8-09e0-431d-abc6-dcf00d954481', 'material', 15, 'ML', 1, 2, null, null),
('32fdd515-2526-4ade-801b-e7382fbaf35a', 'df80da7c-c7f7-4ab9-98ba-220ee2bd3e21', 'd7e753f2-5563-45b2-8bd5-740edf43b93c', 'material', 140, 'ML', 14.62, 3, null, null),
('a95439aa-9af8-4746-9e08-cd4cb7440eb6', '99fbf01c-dfe1-4d08-9cc3-d93e3955ef9f', 'd7301c50-5075-4fd9-9b67-cd18e8a8e038', 'material', 45, 'ML', null, 0, null, null),
('a1871bd5-ba0a-439f-96ab-c74011cc83f6', '99fbf01c-dfe1-4d08-9cc3-d93e3955ef9f', 'b37c8f01-8da4-45b7-aa79-aa534f8c4b99', 'material', 1, 'Piece', null, 1, null, null),
('57a069ec-645b-4e16-80c5-a05c7d872ae6', '99fbf01c-dfe1-4d08-9cc3-d93e3955ef9f', 'b5eb35ca-9ea8-4566-ad4a-7f8e1149a52c', 'material', 170, 'ML', 28.34, 2, null, null),
('e899033e-289e-4262-a945-e7e3b456b3ef', '673f2410-6f25-4025-9be6-1f958ae2ecda', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 18, 'Gram', null, 0, null, null),
('4bfdcf58-198c-4b6b-9bd8-3192094ee82b', '673f2410-6f25-4025-9be6-1f958ae2ecda', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 40, 'Gram', 2.67, 1, null, null),
('1da6d0c8-aab6-407a-8303-45fde05dd5d4', '673f2410-6f25-4025-9be6-1f958ae2ecda', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 15, 'Gram', 4.5, 2, null, null),
('9480b991-b9d9-4ee3-87af-0f1330a45c1e', '673f2410-6f25-4025-9be6-1f958ae2ecda', 'df69d124-9e5a-46db-affb-53455388b9f3', 'material', 15, 'Gram', null, 3, null, null),
('42cf1819-5939-4da6-b1ef-c8fc0a289d8d', '673f2410-6f25-4025-9be6-1f958ae2ecda', 'e064ed7b-8dc6-41b4-8c9e-cf7578d388db', 'material', 60, 'Gram', null, 4, null, null),
('491b695c-4687-46b8-8e7b-92d66f6149e5', '673f2410-6f25-4025-9be6-1f958ae2ecda', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 60, 'ML', 0, 5, null, null),
('eb4064a1-8bea-473a-99d6-36de7d9d7565', '673f2410-6f25-4025-9be6-1f958ae2ecda', '09ce2d15-3646-45f6-9b3f-ce15ebbb92a4', 'material', 60, 'ML', 2.53, 6, null, null),
('99acd0c2-8cc9-4533-9278-126f630e2f43', '673f2410-6f25-4025-9be6-1f958ae2ecda', 'b7e5ddea-ff58-4f33-aea9-fb8aa36bfb67', 'material', 50, 'Gram', 5.33, 7, null, null),
('8e04967a-ee00-4979-bc3f-3a3598480e15', 'ab14aa51-8931-415e-938d-2bcb74886b8a', 'c2a76ed8-bf3a-4213-be16-0e2f24ad9574', 'material', 13.75, 'Gram', null, 0, null, null),
('d6bb84b4-d1d8-4880-9698-dd0c235d38ef', 'ab14aa51-8931-415e-938d-2bcb74886b8a', '02ad4ee4-ec27-46b4-963f-fa306ee8d2a2', 'material', 120, 'Gram', null, 1, null, null),
('d1f82105-2b3a-47a4-aa4c-5a78710d3d7c', 'ab14aa51-8931-415e-938d-2bcb74886b8a', '9f282e54-3211-4871-b925-7436b4eadb54', 'material', 30, 'Gram', null, 2, null, null),
('a8aa1241-220b-488d-ba36-e76f89f3785e', 'ab14aa51-8931-415e-938d-2bcb74886b8a', 'b3dccbe1-c590-4b25-a66e-8e753aa503a9', 'material', 4, 'Gram', null, 3, null, null),
('e78d80a9-250a-4ed7-87c6-2bd6bb11a6fa', 'ab14aa51-8931-415e-938d-2bcb74886b8a', 'eefc3afe-7267-4e94-b310-1c50f5eb7d82', 'material', 4, 'Gram', null, 4, null, null),
('20e0dc82-7083-40af-bb33-306edecd9c75', 'ab14aa51-8931-415e-938d-2bcb74886b8a', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 15, 'Gram', 4.2, 5, null, null),
('1cc8e48a-991c-4667-a6cd-144ec437bffa', 'ab14aa51-8931-415e-938d-2bcb74886b8a', '848c0dc4-1f27-46cb-af07-0e719ee4d4d4', 'material', 10, 'Gram', null, 6, null, null),
('79b54e57-d778-44a6-881e-a538c8b7b254', '5046f377-08b1-473a-a13a-cb0d47c56939', 'c25ae6db-a76d-4f31-9cb7-d5d9510f1cdb', 'material', 50, 'Gram', null, 0, null, null),
('f0ed759d-3c59-49e8-a87c-b5c0049e9358', '5046f377-08b1-473a-a13a-cb0d47c56939', '06aec591-3edb-43c5-a0e3-6c93eb6d7d71', 'material', 30, 'Gram', null, 1, null, null),
('7d0b72ef-6b07-45c8-bceb-0eb3a08faf46', '5046f377-08b1-473a-a13a-cb0d47c56939', '9d1c022c-b8f5-42bb-b387-fb110dad31c6', 'material', 15, 'Gram', null, 2, null, null),
('963777cb-95f2-430c-b9bb-fd30ebf59766', '5046f377-08b1-473a-a13a-cb0d47c56939', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 20, 'Gram', 1.33, 3, null, null),
('400026ef-b166-4f54-a7c4-e35454142442', '5046f377-08b1-473a-a13a-cb0d47c56939', 'cffc6e81-fe43-44b2-b07f-f7640a995d29', 'material', 20, 'Gram', 1.74, 4, null, null),
('973141f0-3eed-4173-b0e0-ba49b40d2a8e', '5046f377-08b1-473a-a13a-cb0d47c56939', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 10, 'Gram', 1.5, 5, null, null),
('6045f54a-8a54-4f41-af63-819ad8095a89', '5046f377-08b1-473a-a13a-cb0d47c56939', 'b79c495d-b77c-4a5f-8a69-bcd8bf39e506', 'material', 6, 'Gram', null, 6, null, null),
('4a82b5bf-e626-4b9b-8ef6-5131b1165456', '5046f377-08b1-473a-a13a-cb0d47c56939', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 7, null, null),
('cdc74517-2812-4609-a5ac-c95008643473', '5046f377-08b1-473a-a13a-cb0d47c56939', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 8, null, null),
('e4faf96e-c0a8-4712-bd59-39e4cc8cacd2', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', 'dba43236-1c76-4a70-949a-d029d94a2403', 'material', 75, 'Gram', null, 0, null, null),
('06350e37-4bfe-4cb8-b3dd-7fe581c6d561', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', 'c7498a15-1d5d-44f4-ba3d-cdbacf114265', 'material', 5, 'Piece', null, 1, null, null),
('8c8d28a4-7010-4830-9f1a-c542e4dd5fcb', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', 'db72b201-2bf0-498e-83d1-5b080b5110ec', 'material', 1, 'Gram', 0.1, 2, null, null),
('12ddfe45-bd77-4c63-80ef-6e30a7c26d85', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', 'd7600ec7-d1d3-4ef5-9ac3-b2a8d8065093', 'material', 15, 'Gram', null, 3, null, null),
('d0d650f9-541a-40a3-8980-f3ca0c3f0a76', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 5, 'Gram', 0.66, 4, null, null),
('a0600c67-7f2a-4d71-a89b-a2d29bb18e19', 'ad77956e-3dcd-47fd-8c0b-5c70fc0853c9', '6134b5ad-fbdd-4530-b2a3-8cb253dc10a6', 'material', 0, 'Gram', null, 5, null, null),
('fba1bb17-d028-45f6-84e8-d81310019c96', '3264e54c-87f9-4114-a61d-84e803307e17', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 15, 'ML', 0, 0, null, null),
('f9a65535-278b-496f-b960-8180367ea206', '3264e54c-87f9-4114-a61d-84e803307e17', '7fe39ff6-4049-40c1-bba8-ca8d5c6f6757', 'material', 133.33, 'Gram', null, 1, null, null),
('910c6fe7-c144-4513-a0e8-0fe286ad95c2', '3264e54c-87f9-4114-a61d-84e803307e17', '21ec8f0d-3ee3-4b61-a9fd-a9447a6cba66', 'material', 30, 'Gram', null, 2, null, null),
('952f7f16-ddd1-46be-929b-4e5c05af3a89', '3264e54c-87f9-4114-a61d-84e803307e17', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 0.3, 'Gram', 0.1, 3, null, null),
('8dfdea29-c671-4c25-b325-10628783989c', '3264e54c-87f9-4114-a61d-84e803307e17', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 1, 'Gram', 0.33, 4, null, null),
('fef3cdbc-9e9e-4847-a894-998022ca7291', '3264e54c-87f9-4114-a61d-84e803307e17', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 0.5, 'Gram', 0.05, 5, null, null),
('f5cfc0d4-e709-47ba-919e-a1d078f0a855', '3264e54c-87f9-4114-a61d-84e803307e17', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 2, 'Gram', 0.3, 6, null, null),
('6ac84aa4-e1a9-47f2-bdff-c12106580852', '3264e54c-87f9-4114-a61d-84e803307e17', '7f72a693-2b69-461c-9df7-946060b6a4ea', 'material', 1, 'Gram', 0.2, 7, null, null),
('14c04063-cd3a-4b45-94d1-dd9182d3eeb8', '3264e54c-87f9-4114-a61d-84e803307e17', '598de8a2-a9e0-4782-9833-7cd04a9eab4d', 'material', 2, 'Gram', null, 8, null, null),
('6826b4f7-61a0-4bc3-86f7-ef41a40296f1', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', '9bf9d7b2-d69c-4cab-bf1a-8b81cd327588', 'material', 70, 'Gram', null, 0, null, null),
('53f95eef-d775-4fa5-ab30-fe19cfb9f79e', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'a025680b-aa43-4635-a924-e78f8f80fad7', 'material', 50, 'Gram', 13, 1, null, null),
('c8b6d25c-7092-441d-abb1-5ca15e062c1c', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'db9795c0-db2f-48e2-94dd-77f77179bab3', 'material', 20, 'Gram', null, 2, null, null),
('15d398df-3621-4d0c-b469-efc4265b3f67', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 10, 'Gram', null, 3, null, null),
('91d55c40-87ef-46c7-8469-261993000aad', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'f5881ff8-ea68-45fb-beff-19e694c23619', 'material', 50, 'Gram', null, 4, null, null),
('78d19c59-8e9f-4876-bb0e-c62f55a6f9ab', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'a5301845-0d0c-4943-833b-0f628ec23a08', 'material', 3, 'Gram', null, 5, null, null),
('d04b1944-7fd4-4409-9aad-e06a8359e086', '7d5e5d6a-b986-4ab3-ab23-4c457413f129', 'd0e1869f-713c-4c4f-8708-6220404186d2', 'material', 20, 'Gram', null, 6, null, null),
('a3e8a26b-e64b-497d-97ef-1bedaa631878', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'ac6d613c-77f1-49f5-b20d-f5154d5521c4', 'material', 190, 'Gram', null, 0, null, null),
('4394e7c0-76f0-48d7-81dc-75be1f2800b2', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '79faf11d-9d74-4ef0-aa29-809d8f17d8f6', 'material', 20, 'Gram', null, 1, null, null),
('b80589c1-32f6-425c-bbb3-33b3e3533637', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'ee031ab2-7b8e-410c-b46f-43b89ecfb2d9', 'material', 5, 'Gram', null, 2, null, null),
('f56162fe-7f17-403f-9ed2-ea2aced9edc6', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '40b7ab25-7642-4c67-be34-92a84c24d06e', 'material', 15, 'Gram', null, 3, null, null),
('2253c4cb-cf6f-4efe-b32c-2b4280a5b8fe', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'd43009cc-3308-4a3e-a17d-66bf9c5a5b30', 'material', 15, 'Gram', 3.69, 4, null, null),
('a0ba75a0-6ab4-4c9d-b551-54828f885eec', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 20, 'Gram', 1.33, 5, null, null),
('5fa1b8ae-83b1-4544-a268-d5deda57eb7e', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 15, 'Gram', 2.25, 6, null, null),
('a1a66001-72c3-4a0a-8b2a-d438755a908f', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'b79c495d-b77c-4a5f-8a69-bcd8bf39e506', 'material', 5, 'Gram', null, 7, null, null),
('e79e0cfa-0df3-42ce-856c-88b0657a8201', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 3, 'Gram', 0.7, 8, null, null),
('2733ed1e-f4fc-4306-9ef3-224bda2cec5c', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'd6c43012-099d-4256-88ec-7d5ba9431c18', 'material', 5, 'Gram', 1.5, 9, null, null),
('6b4f2116-5a69-4654-8881-d2280eadf2de', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', 'fb34032c-074f-4843-a431-520a729d5a67', 'material', 15, 'Gram', null, 10, null, null),
('ddfbcdf2-2a56-4d52-9d31-19b86e55f8da', '8b59e56f-84db-410f-9ba4-75b7ca4b9c02', '72f6b4f3-4a47-403a-a2f5-5d75f88698d6', 'material', 10, 'Gram', null, 11, null, null),
('6813e7ef-869a-4f8c-b626-78662e4fc6ff', '1239b97d-17e3-457b-9233-76faa2fff5f9', '56f42fb4-912b-41d0-9d9c-fe5db1d114d7', 'material', 160, 'Gram', null, 0, null, null),
('e5623022-bc20-417b-b6a9-15543e932023', '1239b97d-17e3-457b-9233-76faa2fff5f9', '6cd2adf8-f19b-4034-a176-d935263b2523', 'material', 12, 'Gram', null, 1, null, null),
('11446e5d-6e03-4f68-9f8e-8b966fbb0cef', '1239b97d-17e3-457b-9233-76faa2fff5f9', '20e2503b-1bb7-4797-ad96-4ed50c782896', 'material', 4, 'Gram', null, 2, null, null),
('eafb1fc2-3c16-4d6f-8c3f-2b6a3e7d992e', '34806d15-49c2-4651-b284-5563216d9b5c', '21c64484-f9a6-4048-be5b-46deb76d121b', 'material', 75, 'Gram', null, 0, null, null),
('c30b7219-5f80-41f7-98f7-e1c61a076483', '34806d15-49c2-4651-b284-5563216d9b5c', 'c7498a15-1d5d-44f4-ba3d-cdbacf114265', 'material', 5, 'Gram', null, 1, null, null),
('34ac3402-fb6f-4f9e-8d84-ee4986aaeb7a', '34806d15-49c2-4651-b284-5563216d9b5c', '832ebd1c-a19d-492c-92f9-efc207547cf2', 'material', 10, 'Gram', 3.33, 2, null, null),
('b1fc7c50-3c72-44f1-a9da-385568e74fef', '34806d15-49c2-4651-b284-5563216d9b5c', '6f965fdb-037d-4a05-a689-bf9654b5e462', 'material', 10, 'Gram', 1, 3, null, null),
('2839f313-07fa-4900-93da-87ca23948bc3', '34806d15-49c2-4651-b284-5563216d9b5c', 'a0843506-ce82-4109-897f-9ce9e1715dcf', 'material', 5, 'Gram', null, 4, null, null),
('7462d77d-7669-46d1-abc7-d5d44a9233b5', '34806d15-49c2-4651-b284-5563216d9b5c', '5c563194-7036-43ec-9874-1a8671a252ee', 'material', 1, 'Gram', null, 5, null, null),
('6bf6d359-e726-4dc4-a6e6-11f5865b20d1', 'b326938b-7e11-426c-a932-86024f288c2f', '75d98d17-78dc-42dc-b8fc-36dcc2b6899f', 'material', 150, 'Gram', 15, 0, null, null),
('0d20a2cc-fc71-48ad-825d-ff94ba4f9a1a', 'b326938b-7e11-426c-a932-86024f288c2f', '9156efa9-1d5a-49da-9310-cc3cae5fca8d', 'material', 80, 'Gram', null, 1, null, null),
('88bc3952-b156-480d-9575-fab693ffbb7f', 'b326938b-7e11-426c-a932-86024f288c2f', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 10, 'Gram', 0, 2, null, null),
('0cae6319-d4c5-4216-8756-0c89b610fc7d', 'b326938b-7e11-426c-a932-86024f288c2f', '18382255-f7e1-4944-80e4-473cfe758ea7', 'material', 1, 'Gram', null, 3, null, null),
('3731888f-7f2c-400b-88c2-52e89bfb97fc', 'b326938b-7e11-426c-a932-86024f288c2f', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 1, 'Gram', 0.18, 4, null, 'Chopped'),
('5bff1a7f-c391-4f1c-892f-8dcba1313ea3', 'b326938b-7e11-426c-a932-86024f288c2f', '638f88e5-80f3-4564-b59c-000e070050e8', 'material', 2, 'Gram', null, 5, null, null),
('e26acc31-c02a-4397-a571-36f424d83792', 'b326938b-7e11-426c-a932-86024f288c2f', '905a351f-1354-41a7-b1b8-0ab9d049e719', 'material', 40, 'Gram', 3.4, 6, null, null),
('ed6a92a1-a3d0-48af-b2e6-f6d16f21da41', 'b326938b-7e11-426c-a932-86024f288c2f', 'dc8fc9c6-ccfb-4cb8-a384-6fed184b3a2f', 'material', 20, 'Gram', null, 7, null, null),
('f764b27b-83d3-4aed-8e70-93342031ceab', 'b326938b-7e11-426c-a932-86024f288c2f', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 10, 'Gram', 8.84, 8, null, null),
('606df961-0b22-4d0a-811a-a2f939d58dd7', 'b326938b-7e11-426c-a932-86024f288c2f', '902aad0f-8fe3-47bb-b101-560af06f55a4', 'material', 5, 'Gram', 1.66, 9, null, null),
('e214718b-6ccc-4afe-9667-aa83b08f0109', 'b326938b-7e11-426c-a932-86024f288c2f', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 3, 'Gram', 0.93, 10, null, null),
('c136d031-2cc9-46ee-92c3-4034aaa7d9f2', 'b326938b-7e11-426c-a932-86024f288c2f', '0c081522-0188-43be-98de-882a35b7825d', 'material', 1, 'Gram', null, 11, null, null),
('8b64e358-f1c9-42d2-8d5a-3e85749712ee', 'b326938b-7e11-426c-a932-86024f288c2f', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 0.5, 'Gram', 0.17, 12, null, null),
('df2ebc56-feaa-40b7-b977-3fa1d717dfa3', 'b326938b-7e11-426c-a932-86024f288c2f', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 0.5, 'Gram', 0.5, 13, null, null),
('efc9e7f6-2490-4d8c-b623-d07380c6ed0c', '9ec18c60-41fd-4308-83e0-437c71a9ea96', 'ef4e5b02-135a-4b46-8e3e-b5e850f9c38f', 'material', 30, 'Gram', 3.14, 0, null, null),
('f23ddf18-552e-47c2-a783-539a203f740c', '9ec18c60-41fd-4308-83e0-437c71a9ea96', 'a9e5926a-0cc2-442e-ad88-1464fd388ada', 'material', 180, 'Gram', null, 1, null, null),
('69788ac2-48aa-4815-9aa5-427bebde39ee', '9ec18c60-41fd-4308-83e0-437c71a9ea96', 'edd9a34d-5ed8-4eb2-b9b3-ddd37715a234', 'material', 5, 'Gram', null, 2, null, null),
('f1086691-bf93-4b71-a4d0-497157acd5cb', '9ec18c60-41fd-4308-83e0-437c71a9ea96', 'b9515e8f-51db-4413-b284-47af4b551ff3', 'material', 20, 'Gram', null, 3, null, null),
('5590a5bc-c528-4545-967c-f5a62506786b', '9ec18c60-41fd-4308-83e0-437c71a9ea96', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 20, 'Gram', 5.6, 4, null, null),
('c80ba97c-c6d9-4ee4-9afe-8d6cfdc148b8', '9ec18c60-41fd-4308-83e0-437c71a9ea96', '850ffc40-59d2-4964-a82a-912d298b8655', 'material', 10, 'Gram', null, 5, null, null),
('1cee591c-8604-4059-8538-9c264422bfb4', '9ec18c60-41fd-4308-83e0-437c71a9ea96', 'a0843506-ce82-4109-897f-9ce9e1715dcf', 'material', 2, 'Gram', null, 6, null, null),
('3f90bc00-7bdc-4923-b846-115eca9f0c9f', '9f56d04e-750f-480f-816f-09afc2b2fdff', '89386d5a-bb29-414a-9537-c5b0b8c0e8a0', 'material', 140, 'Gram', null, 0, null, null),
('70a582f6-6d9b-4f7b-b6b7-b76e908185a8', '9f56d04e-750f-480f-816f-09afc2b2fdff', 'c47259ca-6b03-4a85-b741-7bf5e8ac6156', 'material', 50, 'Gram', null, 1, null, null),
('a2f9f590-0902-4dcb-81eb-aa1f4ca6b61f', '9f56d04e-750f-480f-816f-09afc2b2fdff', 'ae376267-aa80-4efe-b2a6-6660a45d3eb7', 'material', 15, 'Gram', null, 2, null, null),
('996811f2-bbdf-4a0f-817d-b6b5c2366d97', '9f56d04e-750f-480f-816f-09afc2b2fdff', 'dabf2735-767b-4cae-94e2-cbba9898d9e3', 'material', 15, 'Gram', null, 3, null, null),
('15275259-4c33-46cd-a029-7f3c7cd35ede', '9f56d04e-750f-480f-816f-09afc2b2fdff', '7d4dfe76-6695-402b-9bf6-f0ceef03b4a2', 'material', 5, 'Gram', null, 4, null, null),
('52795391-f3f8-4555-81ad-d5552ef7b486', '9f56d04e-750f-480f-816f-09afc2b2fdff', '6b9af543-ebea-4ff0-bebb-d096e5ce9413', 'material', 10, 'Gram', null, 5, null, null),
('f8b08245-78ab-4e7b-9f9f-96e42a40770a', '9f56d04e-750f-480f-816f-09afc2b2fdff', '1cfbd788-c4bb-4082-a7a0-4dd403c41c42', 'material', 10, 'Gram', null, 6, null, null),
('8dda8a27-eeb3-4e92-a98f-184dfb21fbd7', '9f56d04e-750f-480f-816f-09afc2b2fdff', '6d6b5e91-d12a-45dc-a0e4-ddbfd59debc2', 'material', 15, 'Gram', null, 7, null, null),
('4c98be21-b204-4136-832f-282a63c1bde6', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'df65fe83-9622-4e3a-8f6b-b5e817420ac8', 'material', 1125, 'Gram', null, 0, null, null),
('a8be177a-6d77-4aae-a84d-c05bc77a3241', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'bcbf3bde-1fb1-45b1-9839-6fb15a5a1027', 'material', 550, 'Gram', null, 1, null, null),
('e998a0c7-d8f0-4bf6-b91d-141a6fe8555d', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', '8309b183-c302-4ec3-82d8-7475d3691141', 'material', 3, 'Gram', null, 2, null, null),
('636bcd47-3456-4f89-b06a-8b5f67df28d5', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'ccda1047-98e8-4085-afb8-47943a6fa4f2', 'material', 2625, 'Gram', 314.21, 3, null, null),
('656308c7-63af-451a-a93a-b459540f37b6', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', '11a2b2dc-f06e-434a-a39d-7fc1338a5566', 'material', 1900, 'Gram', null, 4, null, null),
('74d59351-4dd3-4209-a9ec-e643dba04e38', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'f23ab4ca-f532-4c5b-8bf0-07d2e0d78f33', 'material', 5, 'Gram', 0.89, 5, null, null),
('b802d975-d9cf-46c1-b052-2a8b08c2573a', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 90, 'Gram', 30, 6, null, null),
('eed75a5a-cd6d-4b91-b7df-b20cac2b9c57', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', '61840ce3-e4d8-42cb-ab9a-ed379fc6196a', 'material', 50, 'Gram', 55, 7, null, null),
('a8094280-f60c-4510-9902-0c98c7b30a94', 'd75beff2-57f3-4ecd-80f4-1e1be82b46e3', 'b7e5ddea-ff58-4f33-aea9-fb8aa36bfb67', 'material', 25, 'Gram', 2.67, 8, null, null),
('fa7771cc-8be2-4971-99ea-88ac0f1bc89e', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'c4f17309-c295-4e20-962e-6c06107de07d', 'material', 150, 'Gram', 172.5, 0, null, null),
('3b2a7a4c-1845-4511-b584-23a53298eac0', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'a025680b-aa43-4635-a924-e78f8f80fad7', 'material', 100, 'Gram', 26, 1, null, null),
('368c5537-d95b-4ca3-895a-55d047313dfb', '92aefb0b-62d7-4f61-a5bf-e19661806536', '7747f820-d0da-4499-aad0-590e5547350e', 'material', 20, 'Gram', 2, 2, null, null),
('fb74bbb8-86b3-403e-980b-f12574ddf35c', '92aefb0b-62d7-4f61-a5bf-e19661806536', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 10, 'Gram', null, 3, null, null),
('792fc0d6-3428-42e8-8112-f7420efa58fc', '92aefb0b-62d7-4f61-a5bf-e19661806536', '8b29bd46-3183-4c8a-9b51-6d3401078159', 'material', 3, 'Gram', null, 4, null, null),
('1b9087dd-6e24-4d27-8271-36c6aa1b617a', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'e49dc56b-cc40-4516-b7d2-e035fe9398ec', 'material', 5, 'Gram', 1.45, 5, null, null),
('1b0867b6-a043-4d55-b237-8d058cc9e35c', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'ab7ac85e-7f64-4a97-9391-5e1f0e072108', 'material', 180, 'Gram', null, 6, null, null),
('a5d4295d-c5ce-4f6e-a263-91ae0b0d0c3a', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'b230ebdb-feb9-42f3-bf1b-da8c2b289876', 'material', 3, 'Gram', null, 7, null, null),
('f9ba5f0e-d5b9-4a69-8088-027cfc2f71a3', '92aefb0b-62d7-4f61-a5bf-e19661806536', 'b74c19fa-1ef5-4b7c-9082-8403e0b5bd5d', 'material', 10, 'Gram', 3, 8, null, null),
('b7ef2ee8-3250-4f19-ab09-08f4acfc979e', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'c1dd247c-0e38-40a8-8fc0-12987b92a5c5', 'material', 30, 'Gram', 4.03, 0, null, null),
('f97741ec-35e1-433e-a64d-419d77308e92', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '0aae595d-00db-4a73-b17b-8d7533ef6f08', 'material', 30, 'Gram', null, 1, null, null),
('e980af2b-df9b-471f-a6c3-040f1e92985e', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'cffc6e81-fe43-44b2-b07f-f7640a995d29', 'material', 30, 'Gram', 2.62, 2, null, null),
('5524d909-6d02-4880-8164-44b449a5e40a', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '77a643c1-3d63-4f92-b917-b1cef91673f2', 'material', 30, 'Gram', 8.4, 3, null, null),
('95c8df62-31f5-44ab-9d82-c05914f0fd5e', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '1f7fabc5-7cc5-4583-999c-dbf021e102a4', 'material', 40, 'Gram', null, 4, null, null),
('ab152db9-dacf-465b-bf1e-674c45e31913', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'd901fcb6-1f1a-4d7d-a7a8-0a7870a43017', 'material', 200, 'Gram', 53.34, 5, null, null),
('bae982d8-6d51-4f39-9700-3614028afea5', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 30, 'Gram', 0, 6, null, null),
('f3e4784a-bf7f-4e9a-9480-f50798283c0d', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 2, 'Gram', 0.67, 7, null, null),
('c5fbf6cc-ea4b-4219-a3b2-2df163a817d7', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 2, 'Gram', 2, 8, null, null),
('18525128-65a1-47f4-bff7-3e333fe60c24', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 2, 'Gram', 0.62, 9, null, null),
('103b1292-7ed5-4f3a-9877-6a5563b1991e', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '0d0203a2-1451-4035-9bd8-e257a9bb9518', 'material', 250, 'Gram', null, 10, null, null),
('794f87f0-9f10-46d3-96a4-db77e445d029', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'b4da1471-debf-457c-a825-36547e2306f0', 'material', 5, 'Gram', null, 11, null, null),
('5fc633b9-c378-408d-afb1-54bef2b4694a', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'd95b94c8-fee1-4a08-9940-96bd9136873f', 'material', 20, 'Gram', null, 12, null, null),
('d1edf9b6-d032-45c1-ae85-aec8572768e3', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', 'b230ebdb-feb9-42f3-bf1b-da8c2b289876', 'material', 5, 'Gram', null, 13, null, null),
('73669b52-dee0-4e3c-b7dc-a8ce7e340ff2', '9462087f-ca84-43d1-b9cb-cdfb87ee2add', '23f68aa6-859c-47aa-b737-058e15d76d5b', 'material', 5, 'Gram', 0.5, 14, null, null),
('cdea2511-8fa0-4f93-96ea-eba4a37300f3', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 10, 'Gram', 1.43, 0, null, null),
('85e8aae3-5354-43ac-86e9-68d226b65ca8', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'dd921e5d-acbf-4db0-b63b-6b24d70c1705', 'material', 2.5, 'Gram', 2, 1, null, null),
('29174668-d8bb-4064-bdbc-70fb0a338b14', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'd92df6aa-455b-45de-ba52-c02d0a5c3f45', 'material', 10, 'Gram', 8, 2, null, null),
('49697ee8-908a-4d38-976e-78436d8c72fa', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'c7802292-7ef6-41b2-9e8a-004c3629ec5a', 'recipe', 10, 'Gram', 2.29, 3, null, null),
('bfbcd0ee-0669-40e5-9219-7de83db021c1', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '2bc56c42-c083-408a-9d97-c1aec96a138f', 'recipe', 15, 'Gram', 0.95, 4, null, null),
('bdfcea71-538f-4dc1-9171-6e952b6b150a', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'd901fcb6-1f1a-4d7d-a7a8-0a7870a43017', 'material', 200, 'Gram', 53.34, 5, null, null),
('f33e8312-84de-47d8-92e6-321c938b8bd0', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'aa0f4f29-04ec-451c-b225-5d324f5d4473', 'material', 100, 'Gram', 9, 6, null, null),
('8c5af912-5484-45e4-9467-6c505889353c', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 50, 'Gram', 0, 7, null, null),
('5da3f687-955e-4d85-b3a7-406a75965289', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 3, 'Gram', 1, 8, null, null),
('976ddf2d-cd0f-46fe-a668-8a74e6753589', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 9, null, null),
('5840342f-ca50-4daf-83df-8bd7df0349c3', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 2, 'Gram', 2, 10, null, null),
('1283c12c-b672-4c2f-b337-7a32f586881b', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 2, 'Gram', 0.62, 11, null, null),
('11245da5-d98b-4a88-91af-b8e14f99d498', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '2a519242-b96b-4127-ba2e-d6f585666d72', 'material', 1, 'Gram', 3, 12, null, null),
('a88c62e0-964d-4b6e-aab9-9d7813f38bba', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'a025680b-aa43-4635-a924-e78f8f80fad7', 'material', 20, 'Gram', 5.2, 13, null, null),
('7473fd2b-5adb-43ed-863e-033574701934', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 20, 'Gram', 1.14, 14, null, null),
('41e567f2-4228-482a-b0cd-b3fbf5f8714e', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '77a643c1-3d63-4f92-b917-b1cef91673f2', 'material', 20, 'Gram', 5.6, 15, null, null),
('266282fb-fc58-4235-b541-0942832fb11b', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'cb4431be-959d-44ab-bbcd-78a6a5033be6', 'material', 20, 'Gram', 26, 16, null, null),
('4e0cde82-4a0c-4f76-b5f8-4ef159f7426b', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 2, 'Gram', 0.47, 17, null, null),
('4fb93f7b-23f5-4f34-ae42-b23cd04bc2c1', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'f1665d26-d3be-4b32-aac6-f43fdcc3cff8', 'material', 2, 'Gram', null, 18, null, null),
('443c58e0-5b64-46d2-aaa0-da7488500eed', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 1, 'Gram', 0.16, 19, null, 'Slit'),
('7b42d102-0d4d-456e-a6fc-0797dd62dd0a', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', 'aecc5921-98ba-41fa-a14b-d84f5fca1161', 'material', 1, 'Gram', 1, 20, null, null),
('dd17331e-2b82-437f-8c80-f6221ab170c6', 'bd53c586-6bf8-4a0c-9ab0-9734e7a7d0b5', '85d596f0-7c7c-429a-8855-c1e9cf74d40f', 'material', 10, 'Gram', 1, 21, null, null),
('6858112d-ea02-4325-b986-e8080c69ac68', '5248e90a-a13d-4616-9055-68102310ed85', '59176e96-8e2d-4898-8849-ac0328adebc3', 'material', 10, 'Gram', null, 0, null, null),
('e627ef96-cf9c-4b1a-8f7b-7806fe62bfc4', '5248e90a-a13d-4616-9055-68102310ed85', 'c03b9e1d-1017-4207-8cfa-b86962d0b0f8', 'material', 150, 'Gram', null, 1, null, null),
('001937c0-1261-4fca-a146-c0517c038c87', '5248e90a-a13d-4616-9055-68102310ed85', 'dc55d948-53f8-4bac-bb81-b42e464e9db1', 'material', 70, 'Gram', null, 2, null, null),
('f9528ddb-6adf-499f-a6ef-b4b05f4db275', '5248e90a-a13d-4616-9055-68102310ed85', '228b5fb6-1215-4d7c-9889-2b6c7101924c', 'material', 30, 'Gram', null, 3, null, null),
('6a6ad3d6-51c9-42b7-965a-e9993ea2971a', '5248e90a-a13d-4616-9055-68102310ed85', 'd372b216-6831-4895-af96-7d85cf60d091', 'material', 600, 'Gram', null, 4, null, null),
('11ab44eb-18dd-4c8a-8463-8a8ff0719c49', '5248e90a-a13d-4616-9055-68102310ed85', '169ffee3-d123-470d-81d1-eb5b7f684cc5', 'material', 20, 'Gram', null, 5, null, null),
('7df4c606-46a8-4c0c-a702-ad8d5448ccea', '5248e90a-a13d-4616-9055-68102310ed85', 'ea7e30f4-708a-4dfd-a9d5-e284d5d5016d', 'material', 500, 'Gram', null, 6, null, null),
('376bab4f-309c-4637-8306-49f72a1d0d46', '5248e90a-a13d-4616-9055-68102310ed85', '7886a70d-a983-42aa-ad76-ec60bc2ebf20', 'material', 100, 'Gram', null, 7, null, null),
('dfb7dab1-7db3-4fd9-9879-f1fc0960c8fe', '5248e90a-a13d-4616-9055-68102310ed85', '6b4ef3d2-70cf-4376-8142-7b6aa33be870', 'material', 25, 'Gram', null, 8, null, null),
('03eb4b4b-aff9-4ef0-8d11-12760ccf2eb1', '5248e90a-a13d-4616-9055-68102310ed85', '02b89b49-9778-4fbc-ab19-3806de9e9eab', 'material', 5, 'Gram', null, 9, null, null),
('eb50eafa-19ac-494b-910f-666020028467', '5248e90a-a13d-4616-9055-68102310ed85', '2230b49c-9f7f-440c-8696-37c3e4ac2232', 'material', 1.5, 'Gram', null, 10, null, null),
('cc3473a5-e888-4f11-bb62-5c0bd4df8a57', '5248e90a-a13d-4616-9055-68102310ed85', 'a3b7a3f4-0f14-484f-b63c-64f2991a4841', 'material', 50, 'Gram', null, 11, null, null),
('097c96f7-d8a6-41f0-929e-b67cbb7e2780', '5248e90a-a13d-4616-9055-68102310ed85', '0b507885-d638-4846-a1dc-73a6d22280f8', 'material', 225, 'Gram', null, 12, null, null),
('465b1705-23ba-42c4-a152-230dc8c6d07f', '5248e90a-a13d-4616-9055-68102310ed85', '1c48167b-8d6b-4ec2-98e7-770b1db8d478', 'material', 100, 'Gram', null, 13, null, null),
('b8118584-c01f-48e6-942d-911d3c6d1e78', '5248e90a-a13d-4616-9055-68102310ed85', '72530920-0a5f-4a78-a4c8-dbd877967f15', 'material', 250, 'Gram', null, 14, null, null),
('2cd06fbc-7ea2-4253-a4d2-a6276fac5026', '5248e90a-a13d-4616-9055-68102310ed85', '7183eaf2-4327-4fa1-93fd-e7bc92f3d2e2', 'material', 34, 'Gram', null, 15, null, null),
('720fae5c-287b-44fb-b324-e6066108a0ef', '5248e90a-a13d-4616-9055-68102310ed85', '4547ba4a-1938-4a78-8df8-ea170f7b9c7c', 'material', 20, 'Gram', null, 16, null, null),
('c16939ca-dc07-482d-a6f2-0ef12a352219', '5248e90a-a13d-4616-9055-68102310ed85', '9685cb61-1e2e-4e40-b140-4d403d06a082', 'material', 60, 'Gram', null, 17, null, null),
('e5aff6f4-57d3-4c90-8efe-6f5f98ec2fc4', '5248e90a-a13d-4616-9055-68102310ed85', '03ceaa82-a1bb-4107-b702-d178defdec8b', 'material', 9, 'Gram', null, 18, null, null),
('5f665888-7746-4d37-8ca6-ed6be2bc1a44', '5248e90a-a13d-4616-9055-68102310ed85', 'c0e09eac-e19e-4b88-8fce-47c077c18820', 'material', 30, 'Gram', null, 19, null, null),
('a4b2fe49-0ab6-4021-88a0-b44d196d7cd2', '5248e90a-a13d-4616-9055-68102310ed85', '008ac7b8-593e-4e76-b43c-1a332d92788c', 'material', 10, 'Gram', null, 20, null, null),
('d398761c-bbb1-484d-87c6-f0bbadba654e', '5248e90a-a13d-4616-9055-68102310ed85', 'c6bde583-063f-4149-9425-3c1985858f81', 'material', 556, 'Gram', null, 21, null, null),
('cc64b09d-481c-4374-b1b9-d6183b394435', '5248e90a-a13d-4616-9055-68102310ed85', '5912a188-e049-4365-bbe6-63c39e0b736a', 'material', 566, 'Gram', null, 22, null, null),
('0c1c7155-7eb0-4d3b-9d24-17aac92927f5', '5248e90a-a13d-4616-9055-68102310ed85', 'b28a623a-9624-4129-b3f1-fbc05c83881b', 'material', 56.8, 'Gram', null, 23, null, null),
('82181866-a9bc-41ea-a4fb-8d66cb8ccc58', '5248e90a-a13d-4616-9055-68102310ed85', '1a471279-2680-4a52-b1d3-4e5858eb14c4', 'material', 56.8, 'Gram', null, 24, null, null),
('3a5b9af9-1702-473b-9f52-719c278482a2', '5248e90a-a13d-4616-9055-68102310ed85', 'd1e9b458-f31c-4cc6-ba54-a92b63d64d03', 'material', 1701, 'Gram', null, 25, null, null),
('b2c1ece4-5919-4b9b-91f6-14ef26ebfdb1', '5248e90a-a13d-4616-9055-68102310ed85', '6fc0a5f2-5e7d-4363-a4b7-8b2a40bf76ea', 'material', 20, 'Gram', null, 26, null, null),
('d542b846-4a77-46c6-9cf9-38c590c28a73', 'b295200f-c8a7-4422-b929-d4326ef9402b', 'd8f03c5b-e55e-451b-a485-d8939cafb422', 'material', 550, 'Gram', null, 0, null, null),
('7415c2ca-cd8c-468a-8a5f-f93d30b7c340', 'b295200f-c8a7-4422-b929-d4326ef9402b', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 6, 'Gram', null, 1, null, null),
('0e0c1dad-b76a-406d-b848-682a293bb2f5', 'b295200f-c8a7-4422-b929-d4326ef9402b', 'e888d241-8d9f-4324-b4dc-2e7a21b468a8', 'material', 75, 'Gram', null, 2, null, null),
('5f5d4cb9-21a9-48dd-aa80-a07f8c3e0fcd', 'b295200f-c8a7-4422-b929-d4326ef9402b', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 110, 'Gram', 7.34, 3, null, null),
('6133fc33-111d-4f88-b270-79eaeec04553', 'b295200f-c8a7-4422-b929-d4326ef9402b', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 12, 'Gram', 3.74, 4, null, null),
('93eed203-fa6b-4eae-873d-ea5596d89beb', 'b295200f-c8a7-4422-b929-d4326ef9402b', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 8, 'Gram', 2.67, 5, null, null),
('80ce69b8-39ec-4f44-a9a5-01c2322d90b8', 'b295200f-c8a7-4422-b929-d4326ef9402b', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 5, 'Gram', 5, 6, null, null),
('b66e2713-9b3e-4467-a308-3969f8317d19', 'b295200f-c8a7-4422-b929-d4326ef9402b', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 7, null, null),
('c75e1919-edc9-4aa8-8d4d-da968a8929fe', 'b295200f-c8a7-4422-b929-d4326ef9402b', '9d4aace4-4a98-4db1-962b-75e665543749', 'material', 25, 'Gram', null, 8, null, null),
('6741c072-78b2-4073-ba69-684097063008', 'b295200f-c8a7-4422-b929-d4326ef9402b', '50793770-2eb2-48d9-84df-2be1787b97b0', 'material', 6, 'Piece', null, 9, null, null),
('8379f57c-70f4-47c3-afec-63cf4c44536e', 'b295200f-c8a7-4422-b929-d4326ef9402b', '1b59ea26-ee77-4b0e-abe4-4af74dcb2511', 'material', 0, 'Gram', null, 10, null, null),
('6b6c886f-fca6-4210-bb9c-6b4bc157aec2', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 20, 'Gram', 2.86, 0, null, null),
('81d65fb0-1828-425d-9c42-b847fc9b5d45', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 1, null, null),
('f803b9ba-1d46-4e31-90ea-d5321a9db3d7', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'd8a954c5-54dd-45ce-8b99-2602f9a86936', 'material', 3, 'Gram', null, 2, null, null),
('5f3719f4-3216-4943-94ba-91c39a5251c3', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'b8235517-3b00-446c-938a-881d53d39340', 'material', 50, 'Gram', null, 3, null, null),
('ce9e1d39-399b-452c-acd1-7b88f2929589', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'd5805b8e-a5a9-455b-9627-69b4e1507263', 'material', 40, 'Gram', null, 4, null, null),
('80a75326-cafd-456f-a913-595f3f4c5a80', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 30, 'Gram', 1.71, 5, null, null),
('f7d14fc1-6d12-4ce7-b3aa-81df73c58ea1', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'ac6d613c-77f1-49f5-b20d-f5154d5521c4', 'material', 20, 'Gram', null, 6, null, null),
('98c44ed3-d353-45c5-ad45-7eb5819b3e51', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '2f8afdf8-a7a1-4578-9aec-20f90c35c943', 'material', 15, 'Gram', 1.5, 7, null, null),
('efc02d3f-9a69-4d6b-a304-06a4f32981e0', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '7073ee5b-13e5-4b8c-9fa0-70c3c06530fa', 'material', 5, 'Gram', null, 8, null, null),
('4906b06e-2600-4a2e-bb51-b0909337b091', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'c1d52d83-ae6f-4b2e-8c06-4017ebc1f6e7', 'material', 5, 'Gram', 3.24, 9, null, null),
('5cbdec19-11f8-497a-81da-4db7337349b0', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 2, 'Gram', null, 10, null, null),
('756f6a1e-5f34-4ced-bf61-4ecc793dbe37', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '5202fb5a-4978-4f97-b75a-10c6694312e0', 'material', 5, 'Gram', null, 11, null, null),
('4728dbd7-b91d-472c-a6ac-69915d9e61e5', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '9fde4e6f-b536-4a5f-b479-8fa9b2109760', 'material', 2, 'Gram', null, 12, null, null),
('549d48ea-d298-481d-8ab4-f7f7c4e11489', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 13, null, null),
('afbe7183-7591-4d7b-bc7f-d7c78ae82dee', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 1, 'Gram', 0.33, 14, null, null),
('ddc118a4-b48a-47a0-ad0c-4af75af9585a', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 1, 'Gram', 1, 15, null, null),
('701ef176-8fe4-44b1-8c92-d3fe879ce3ac', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '683c3a5f-fcff-496c-997d-65cad1ff1f93', 'material', 3, 'Gram', null, 16, null, null),
('fce99095-0c93-4491-b19f-43fa31c30bff', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '54830bff-7748-4a5d-811e-67197308431c', 'material', 100, 'Gram', null, 17, null, null),
('965b9409-676c-4720-a70f-ccffc9a100b6', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 18, null, null),
('8df68fd8-aa6d-46d6-b014-b489e956e062', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '07eccbf4-b7a5-4602-a53a-8310a5867fbb', 'material', 5, 'Gram', null, 19, null, null),
('03efc29c-a78c-4c26-8099-44f2496574b4', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '44ec297e-7987-4be0-a63d-cb5372b7c66c', 'material', 5, 'Gram', null, 20, null, null),
('6fe03697-1c3e-4e16-b7f5-298811c14a4a', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 5, 'Gram', null, 21, null, null),
('d3181e47-1b9c-4400-b463-00bcf433afba', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'ebdd81fd-431f-4303-827f-67bcdeb79b3e', 'material', 20, 'Gram', null, 22, null, null),
('85b2f0d2-1b2c-43ab-bb02-21ec2fcf0361', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '273a7d93-4113-48ad-80f8-88276fc1360a', 'material', 80, 'Gram', null, 23, null, null),
('947c2143-89e8-4505-94c7-14f98d68f8d3', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '5202fb5a-4978-4f97-b75a-10c6694312e0', 'material', 40, 'Gram', null, 24, null, null),
('6a30077f-885e-44ed-b2d7-f1614c0bf0dc', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '1b75debc-bb17-4290-9067-f91d93bf52af', 'material', 6, 'Gram', null, 25, null, null),
('86233844-9612-487e-a96f-f58f907fb66c', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'ad3059ff-69fd-4864-bbd9-4ef9784b3507', 'material', 20, 'Gram', null, 26, null, null),
('db7970e8-ac0d-41c6-bb98-cb0769cc013a', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '9d67e735-9a8e-4544-8532-79d647ca8a95', 'material', 10, 'Gram', 44.28, 27, null, null),
('addde82c-c310-4a2a-96c9-970a5e1fbfa1', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'a7dc6d5f-e42c-436c-8c2c-ac4fdf612e92', 'material', 17, 'Gram', 0.75, 28, null, null),
('876d146b-bafe-4c56-9580-6f0d9460e339', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 90, 'Gram', 0, 29, null, null),
('dcc03221-a620-4e9d-85c3-f1b9c220aba6', 'b895ffee-9c1f-450c-b6b8-fa416a851174', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 60, 'Gram', 8.57, 30, null, null),
('73bccb78-3048-4e1e-8b13-da4d877e7d08', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '6cac5457-edcc-4923-a38a-db3df73aeb5d', 'material', 1, 'Gram', null, 31, null, null),
('ed58a503-3da4-4bfb-bac7-bb2bae68a3f9', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '756401a8-6f4b-4650-a08d-2cccd045b20d', 'material', 200, 'Gram', 20, 32, null, null),
('68006a9e-2ef5-4db1-8819-025dedd95705', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '5f33af7e-8152-4c21-93ae-d7d37ee90b61', 'material', 10, 'Gram', 10, 33, null, null),
('078d44dc-96b3-4b0c-bb0b-f7975c91b77a', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 4, 'Gram', 0.4, 34, null, null),
('ad4a8a4c-2c58-4f43-8e54-a797b8c38156', 'b895ffee-9c1f-450c-b6b8-fa416a851174', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 35, null, null),
('5f7679a5-a607-4efe-b86b-9931f8dde2aa', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', 'f96475bd-bace-43c9-94e4-227ae6e939f9', 'material', 250, 'Gram', null, 0, null, null),
('cdf1d554-873e-4e65-abe0-d49fdc164754', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 50, 'Gram', 44.2, 1, null, null),
('7d211098-c0ce-4d7d-9a5b-48d353512945', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 4, 'Gram', 1.33, 2, null, null),
('d988cda6-3021-4cae-bed2-6787c599e4ed', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '63c5cd30-f0af-4fca-a88a-a3fe04e81ae5', 'material', 4, 'Gram', 4, 3, null, null),
('c9ed7344-fe97-438e-b7d1-61f2ff1f1a3a', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '8611b762-4b84-4b42-9a35-01c413fe8f07', 'material', 25, 'Gram', 133.88, 4, null, null),
('b6940df8-bbb2-4797-961d-6dc951018fe5', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', 'f08858dc-f2bc-4b6f-8fa8-005a3ef5bfaa', 'material', 5, 'Gram', 103.38, 5, null, null),
('940ed4fc-7d42-4b6a-a27e-388082980a84', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 20, 'Gram', 0, 6, null, null),
('24381ad1-3848-4c8e-84a3-3d51266f8815', 'd2fc215c-ea0d-4022-8de9-003dfb326bce', '7139ea61-b23e-4d08-bc3b-707b6e4358aa', 'material', 4, 'Piece', null, 7, null, null),
('d70c69f3-c58d-4fb9-ac2e-c9e5ba218efc', '723d9f76-cab2-46a1-8a57-24420dd62111', 'd5805b8e-a5a9-455b-9627-69b4e1507263', 'material', 500, 'Gram', null, 0, null, null),
('49b0fe78-b48a-497e-9a14-9a91dfaa63e2', '723d9f76-cab2-46a1-8a57-24420dd62111', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 100, 'Gram', 6.67, 1, null, null),
('e4f406b6-5a5b-4c88-88fe-93be9fe12d2f', '723d9f76-cab2-46a1-8a57-24420dd62111', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 50, 'Gram', 2.85, 2, null, null),
('3da39886-d773-4334-98ce-2d220401fd8a', '723d9f76-cab2-46a1-8a57-24420dd62111', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 10, 'Gram', 1.5, 3, null, null),
('ee67e96d-da99-4381-86c0-6600732847ad', '723d9f76-cab2-46a1-8a57-24420dd62111', '24fcb6f9-61fe-42d1-be9d-aecb49b8b6d3', 'material', 175, 'Gram', null, 4, null, null),
('e75b4c01-d392-4338-a380-c1e57e4a4d20', '723d9f76-cab2-46a1-8a57-24420dd62111', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 6, 'Gram', 2, 5, null, null),
('8a26e413-45b8-40f9-bedc-088400697459', '723d9f76-cab2-46a1-8a57-24420dd62111', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 4, 'Gram', 4, 6, null, null),
('f92b23f1-8988-4630-be59-75328b2d5ba1', '723d9f76-cab2-46a1-8a57-24420dd62111', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 6, 'Gram', 2, 7, null, null),
('740e9d84-137a-4c53-99fd-8b2d690810a5', '723d9f76-cab2-46a1-8a57-24420dd62111', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 8, 'Gram', 2.5, 8, null, null),
('6cafab0d-c052-48a4-abb1-5f32fab12837', '723d9f76-cab2-46a1-8a57-24420dd62111', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 30, 'Gram', 9, 9, null, null),
('d38a21c3-9d26-4123-bf49-e51238d438ed', '723d9f76-cab2-46a1-8a57-24420dd62111', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 3, 'Gram', null, 10, null, null),
('b14916c3-f45f-47a0-9ad1-7648ba34db8d', '723d9f76-cab2-46a1-8a57-24420dd62111', 'a30a33b1-77c6-4b61-8ceb-efecd4840b24', 'material', 500, 'Gram', 50, 11, null, null),
('7eef1aa4-f187-4e75-b683-c406aa59204b', '723d9f76-cab2-46a1-8a57-24420dd62111', 'c1d52d83-ae6f-4b2e-8c06-4017ebc1f6e7', 'material', 8, 'Gram', 5.18, 12, null, null),
('669cb6ff-fc2a-431f-8d3a-f42f25495ebd', '723d9f76-cab2-46a1-8a57-24420dd62111', 'b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'material', 15, 'Gram', 30, 13, null, null),
('025e9d65-437c-411b-99a8-abf986eb8cf8', '723d9f76-cab2-46a1-8a57-24420dd62111', '6bfc7d07-82c0-40d1-996c-008354459b6e', 'material', 50, 'Gram', 20, 14, null, null),
('9c73fde2-d421-46c6-82d4-11a09ebf0ef7', '723d9f76-cab2-46a1-8a57-24420dd62111', 'f9599b54-3bae-49dc-b916-9756b3bb239f', 'material', 20, 'Gram', 5.4, 15, null, null),
('ab8b7e0b-3211-4b3d-a2bb-9602f08c74e5', '723d9f76-cab2-46a1-8a57-24420dd62111', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 6, 'Gram', 2, 16, null, null),
('72ef90e5-f082-46fe-939d-d96e94085c0f', '723d9f76-cab2-46a1-8a57-24420dd62111', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 3, 'Gram', 1, 17, null, null),
('94fcb533-5a78-44f6-9395-0a578f096aeb', '723d9f76-cab2-46a1-8a57-24420dd62111', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 6, 'Gram', 1.87, 18, null, null),
('267f5597-3e87-463b-9b2c-79185266fe84', '723d9f76-cab2-46a1-8a57-24420dd62111', '7139ea61-b23e-4d08-bc3b-707b6e4358aa', 'material', 5, 'Piece', null, 19, null, null),
('e27b2a1b-f18c-4e01-9104-8db807b6e47e', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 95, 'Gram', 83.98, 0, null, null),
('ee3e3477-7c84-463e-b6e1-48144f7e3ef8', 'ac8851b7-8d24-4078-98d7-c2a11229724d', 'a025680b-aa43-4635-a924-e78f8f80fad7', 'material', 100, 'Gram', 26, 1, null, null),
('6ec5d66d-881d-44db-ab1c-4ff6e4983c56', 'ac8851b7-8d24-4078-98d7-c2a11229724d', 'd8f03c5b-e55e-451b-a485-d8939cafb422', 'material', 100, 'Gram', null, 2, null, null),
('8e7eaa58-77f3-4072-9d00-e425b0ab03e5', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 6, 'Gram', 2, 3, null, null),
('83045388-958b-4581-b92d-a8a658c1cd5d', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 2, 'Gram', 0.2, 4, null, null),
('85790dcb-c521-4b7e-bae4-1d47f497a61a', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 1, 'Gram', 1, 5, null, null),
('fd6dea9d-79ca-4a08-b8ae-866c3b7a81da', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 10, 'Gram', 2.34, 6, null, null),
('4c056481-5b21-4d23-a09b-a986cf27ba46', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'material', 3.5, 'Gram', 0.7, 7, null, null),
('aa508398-0fa9-4634-a162-e65e7a3b4ae8', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '5a7cd88e-5b3c-4c2d-876e-ba0106d3df3f', 'material', 5, 'Gram', null, 8, null, null),
('6118e65a-5834-458e-8b82-e25ab74236d0', 'ac8851b7-8d24-4078-98d7-c2a11229724d', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 30, 'Gram', 9, 9, null, null),
('57713ae7-c7ac-4183-9287-86d12f540cdf', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '42525160-fcb6-4aa1-99d9-02f5409826af', 'material', 5, 'Gram', 0.64, 10, null, null),
('5e260842-7ca9-47f5-92b7-5246018a50b8', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '9d8d8006-8eb7-41c1-97f4-8671d3130597', 'material', 10, 'Gram', 2.42, 11, null, null),
('02082b83-227a-4ff1-a2e1-6fa5dfcf85d8', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '220cf9a0-8817-45bb-8d7b-852e5556d9ac', 'material', 150, 'Gram', null, 12, null, null),
('836413a8-fb53-4971-9ea1-80b66f314390', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '695cc3a4-779f-4ed5-98fc-150e049f7d4f', 'material', 1, 'Gram', null, 13, null, null),
('021ebfab-b8e9-431b-a460-a6cda918d191', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '4bc77508-6a79-4208-88e9-a0c1274eaaee', 'material', 5, 'Gram', 5, 14, null, null),
('417e628f-6e48-4508-816f-e6aaffcf74cd', 'ac8851b7-8d24-4078-98d7-c2a11229724d', 'a30a33b1-77c6-4b61-8ceb-efecd4840b24', 'material', 50, 'Gram', 5, 15, null, null),
('7422f4a5-99ab-4d59-ab07-98e548f0451a', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 10, 'Gram', 3.33, 16, null, null),
('2a6a7683-3f78-410e-b9cf-41fae161e39e', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '04119af1-0689-434f-b035-21f8fac114aa', 'material', 8, 'Gram', 0.81, 17, null, null),
('eb0e59ba-8c6f-49cc-b0e9-d7cc18c21f3f', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '6664fa17-1c50-4cc3-80d4-956f1d913a3a', 'material', 6, 'Gram', null, 18, null, null),
('d475a8e0-2322-49cd-97a4-a128d587fbcc', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '8ed08113-3a60-40f1-8d93-31ad1478fe05', 'material', 1, 'Gram', null, 19, null, null),
('01456783-c869-4fbb-ae15-686b0bab1261', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '9d67e735-9a8e-4544-8532-79d647ca8a95', 'material', 10, 'Gram', 44.28, 20, null, null),
('b4def0f1-e530-4c22-8160-924cf66c3215', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '6ae0325a-b451-432b-826e-d17599e2e2c3', 'material', 20, 'Gram', 6.22, 21, null, null),
('9cb370d1-a352-4439-9e13-cc4bea1bb931', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 22, null, null),
('f2be519b-1561-4181-b07a-4c103de0a4b4', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 3, 'Gram', 0.39, 23, null, null),
('cdb62b69-d0dc-41a3-86c1-1e232c04cc87', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '7139ea61-b23e-4d08-bc3b-707b6e4358aa', 'material', 5, 'Piece', null, 24, null, null),
('49b3267f-6067-425c-983f-3b4a84d06f70', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '85d596f0-7c7c-429a-8855-c1e9cf74d40f', 'material', 0, 'Gram', 0, 25, null, null),
('63c8b1b3-926f-48c5-8c68-ba841e5d0004', 'ac8851b7-8d24-4078-98d7-c2a11229724d', '481a34e2-aca5-456e-901b-999e30dda6f1', 'material', 0, 'Gram', null, 26, null, null),
('fcdd71ac-5b87-4bed-86ea-306056d88346', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'c7498a15-1d5d-44f4-ba3d-cdbacf114265', 'material', 5, 'Gram', null, 0, null, null),
('dce50bd2-b9ba-4890-99fd-21df55c839e6', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '73db67a5-e704-4d74-8148-e5892408fc18', 'material', 75, 'Gram', null, 1, null, null),
('180f25ec-cbba-4c6e-a547-d9b3a834afa1', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 10, 'Gram', 1.43, 2, null, null),
('b6edf0a0-e305-406d-9bd1-ff59837c80cd', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'd1f53be8-9f9d-415b-9ad9-d3374676bad8', 'material', 1, 'Gram', 0.9, 3, null, null),
('c8268312-26d3-4949-8d45-2f773200766c', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '3c9b843f-3890-4d4e-901c-4b9074f6779c', 'material', 20, 'Gram', null, 4, null, null),
('4b6eb3a0-dbc1-41af-afe9-fcb033b40850', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'aa0f4f29-04ec-451c-b225-5d324f5d4473', 'material', 100, 'Gram', 9, 5, null, null),
('83afc82b-b5f4-4225-8c55-fbb32d206b9e', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 1, 'Gram', 0.33, 6, null, null),
('44e72566-32d4-4d24-bac9-6310d8f89f76', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 1, 'Gram', 0.33, 7, null, null),
('85f5d459-687c-41af-a8d8-90be0b78943d', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 1, 'Gram', 0.31, 8, null, null),
('6a59c7fb-5d29-45b5-9668-dffaa09b6509', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '0b6fef37-528d-4e91-ba5b-5cab299314b6', 'material', 1, 'Gram', null, 9, null, null),
('7d32d07d-c943-4cbc-8e22-cab1f65d685f', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'b5949e0c-4172-4608-968c-b9a29714fd89', 'material', 4, 'Gram', null, 10, null, null),
('630ca96f-d525-4d8b-b896-ccc4fc17b559', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '2f8afdf8-a7a1-4578-9aec-20f90c35c943', 'material', 2, 'Gram', 0.2, 11, null, null),
('a3623b09-c1f0-404f-8b1e-8f86c607ac89', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', 'f287ce73-061b-4e62-9bbb-aec2ecfd17bf', 'material', 2, 'Gram', 0.13, 12, null, null),
('4ecc3290-de68-474f-b130-5430ee7f4d86', '033caea7-fc70-4f1f-a7e2-79c07a623c2c', '256f5117-f526-4827-a8c7-f4eacf160e9c', 'material', 4, 'Gram', null, 13, null, null),
('bf920390-c482-494a-8b95-a731396f6ad5', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '2c7d53ac-4eb7-4e68-b6fc-8448c97280b7', 'material', 2, 'Piece', null, 0, null, null),
('7d561ea5-193c-4992-82c5-1c2c5e70d3df', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '1147e35d-4ba9-40f4-a9b4-f61712249490', 'material', 2, 'Piece', null, 1, null, null),
('b891b160-0162-4a9c-b47d-8c52462a849c', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '3f64d465-8fb8-4116-8192-5595a39f917a', 'material', 2, 'Piece', null, 2, null, null),
('b2c7e82c-cb90-4624-b8db-ee2041239e7f', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', 'ea6d17a4-e9c4-49ad-a99e-489d185f2725', 'material', 2, 'Piece', null, 3, null, null),
('d9cca0fd-571b-494d-8d13-486b0085a027', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '7e0ac97a-be2a-42db-a99a-9db8394d74b1', 'material', 2, 'Piece', null, 4, null, null),
('1126baf3-49e8-4607-bbef-192c22c40d2b', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '95817f33-4d42-49d0-9c36-7661c72e4a95', 'material', 30, 'Gram', null, 5, null, null),
('ba638ce0-2288-4fbf-abe5-eb8e1f31a667', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', 'ee031ab2-7b8e-410c-b46f-43b89ecfb2d9', 'material', 25, 'Gram', null, 6, null, null),
('acd25fb6-10c2-4f0a-be55-5cc9aee696c0', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', 'fcd5bd3b-717b-4638-b6bf-f1feaf977f5e', 'material', 15, 'Gram', null, 7, null, null),
('67fda30a-d4c8-41f1-8c80-ef402d27c900', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', 'ce59bbd2-fb47-49e8-9433-9389e7233976', 'material', 25, 'Gram', null, 8, null, null),
('b580cecc-fdb7-4dcf-92a1-d7258e24add2', 'a0b03363-88ef-4c45-a6f7-c3d7a6158129', '3bc831a1-e2d2-4e87-868a-63621c5fc512', 'material', 30, 'Gram', null, 9, null, null),
('02a23b7b-4de6-4fd7-b7af-bc1222296c91', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('a868ff5b-1831-4018-9aa9-ebdf960013be', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '5035709a-1cec-4aad-968f-9c56626a59be', 'material', 1.4, 'Gram', null, 1, null, null),
('a4b0bc44-299e-4120-bf53-50468fdaa1d5', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '55d02258-f1dd-47ca-8054-9ababb7b814b', 'material', 5, 'Gram', 1.67, 2, null, null),
('7e16f31d-b614-455a-a970-6f7d0afb2a67', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', 'b1f2ff36-f5ca-4a2d-9fba-b025b35ab768', 'material', 5, 'Gram', 1, 3, null, null),
('a72526b7-c263-4101-bcf0-6b9e7541469b', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 25, 'Gram', 22.1, 4, null, null),
('b4085a3e-45a4-4e5c-aeac-5b3ab4b61c16', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '7a0c9dba-598c-41e7-9e6b-c38206a76e8e', 'material', 20, 'Gram', 6, 5, null, null),
('cb896350-61d0-4d93-92e3-9ef2c763081d', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 30, 'Gram', null, 6, null, null),
('df993dad-4a07-4ed9-ba41-2436cbe2af4d', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', 'a63bfbdb-aeee-46e2-a0f5-8b3a16dde263', 'material', 180, 'Gram', null, 7, null, null),
('3f88cd27-eaec-4b44-9564-5b187fa0cbcc', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', 'b74c19fa-1ef5-4b7c-9082-8403e0b5bd5d', 'material', 30, 'Gram', 9, 8, null, null),
('1e95da47-bbd1-4d79-96e8-326f0ba885bb', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '3cfa0475-eef6-4e3f-acb9-f0772cefc037', 'material', 10, 'Gram', null, 9, null, null),
('f7dffe7f-94e1-4ff9-8c93-318eaa1e6a40', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 5, 'Gram', null, 10, null, null),
('1475a6da-fc48-4478-9e60-d9552c6ea846', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 20, 'Gram', 5.33, 11, null, null),
('0cc26c9c-a038-49a4-8376-f6fbeeebc874', 'afa150ca-2dc7-490b-987c-dfe03e91d5b6', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 3, 'Gram', 3, 12, null, null),
('f1f039dd-f099-43bb-b5ef-80545d7b7045', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('85cd8979-3427-48c1-a79d-fec5f2241eaf', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'd6695677-6412-4b38-a9df-30eb0d88b411', 'material', 1.4, 'Gram', null, 1, null, null),
('26fdeb9b-c358-4e70-ac93-25cfdc45f749', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '55d02258-f1dd-47ca-8054-9ababb7b814b', 'material', 4, 'Gram', 1.33, 2, null, null),
('9eae723f-9d19-442a-b568-30ee46f8a9e1', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'b1f2ff36-f5ca-4a2d-9fba-b025b35ab768', 'material', 4, 'Gram', 0.8, 3, null, null),
('01234215-e64e-45aa-a6df-a7a90a295bfc', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 25, 'Gram', 22.1, 4, null, null),
('a2eb8438-82a8-462e-830d-15b528ecf492', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'd43009cc-3308-4a3e-a17d-66bf9c5a5b30', 'material', 9, 'Gram', 2.22, 5, null, null),
('63ada210-0004-47ad-ba62-fa2dd38f6c05', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 8, 'Gram', 1.2, 6, null, null),
('7175b069-3799-436b-96b2-3dfb14be1348', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', 'd28298c8-e41e-46b8-af34-bba6726922fc', 'material', 25, 'Gram', null, 7, null, null),
('2e8e6c55-1319-4768-a516-28a9c68ec97b', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '832ebd1c-a19d-492c-92f9-efc207547cf2', 'material', 15, 'Gram', 5, 8, null, null),
('94b3799f-1e12-47c3-922c-dde7337e3b40', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '253f3bad-f9e1-4e23-b743-b0c13dd039f5', 'material', 4, 'Gram', null, 9, null, null),
('96693494-4b87-4186-ada8-d858349d3638', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 5, 'Gram', null, 10, null, null),
('c27cd161-46ae-4ffa-9ca7-3f1b4ab7ec9d', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 20, 'Gram', 5.33, 11, null, null),
('eec65881-90e2-4569-90b5-6d83c3832fbf', '0a20d2aa-f5dd-4125-bd70-ae9b8a6930e5', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 3, 'Gram', 3, 12, null, null),
('e09125af-843d-4a2e-bb98-ecc156544e87', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('566d4e85-b838-4649-8cbf-5ed020a6efbd', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '18ba6eff-b47a-417f-bd4a-597e13bfd7d9', 'material', 1.4, 'Gram', null, 1, null, null),
('f04f5a57-e683-4e8f-a3c5-f6bd6a42a984', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 20, 'Gram', 17.68, 2, null, null),
('18d108a9-cc8e-43b8-aa9a-9cbdaeabdd3a', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 6, 'Gram', 0.9, 3, null, null),
('8694c48b-6813-46da-a31d-5b20e1beeefb', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 15, 'Gram', 0.86, 4, null, null),
('98770f59-5be4-4cf1-af43-9859f724f064', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', 'd43009cc-3308-4a3e-a17d-66bf9c5a5b30', 'material', 30, 'Gram', 7.39, 5, null, null),
('26342e18-5c07-4bc4-907e-b90b7a59a63f', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 15, 'Gram', null, 6, null, null),
('203a11f2-d095-4e1b-b645-6b3bb7c90e45', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '561f0379-9826-4e23-9148-6efb03a2d521', 'material', 100, 'Gram', null, 7, null, null),
('dea0ffc4-6f43-4a09-aef9-b0937be28a34', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '832ebd1c-a19d-492c-92f9-efc207547cf2', 'material', 10, 'Gram', 3.33, 8, null, null),
('c1cd21af-d563-4107-b377-529ff9aa5264', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '125b16de-b2cc-4470-8653-b953ba86afff', 'material', 5, 'Gram', null, 9, null, null),
('948bfdbf-39dc-4dd4-89c2-43d75bc49fa1', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '09d4fef0-2b9f-4797-afb2-13e9a5b75f18', 'material', 5, 'Gram', null, 10, null, null),
('b658c6fe-64a6-49d1-9516-eb509eed12fe', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 20, 'Gram', 5.33, 11, null, null),
('77445bec-c6f6-4edd-906d-340519a52104', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '1c0435e3-2fd6-42ab-a591-7676b8fd3647', 'material', 3, 'Gram', null, 12, null, null),
('d5a03481-0998-48e6-964f-5bd95ecb687d', 'b5f80f13-9c13-47f0-a2c4-c3f50a0b7b2f', '0f7bbee9-794f-4c39-80dc-b0ba734af1ec', 'material', 2, 'Gram', null, 13, null, null),
('6a704126-a53a-4557-9084-d1dd75881b93', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '437c28e7-88d7-4276-9c74-d30914fa5a35', 'material', 4.2, 'Gram', null, 0, null, null),
('e82bc2b3-c7b2-4c67-bd91-634b2adea277', 'befb6149-aa96-46bf-8201-0bf8dc05b476', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 160, 'Gram', 40.32, 1, null, null),
('0492d9f6-1d0c-4206-89e6-109efccc2057', 'befb6149-aa96-46bf-8201-0bf8dc05b476', 'fad12371-01a2-4599-aab7-b98d61eb8a77', 'material', 40, 'Gram', null, 2, null, null),
('ab0950dd-7b24-4c23-98f4-fb2cdb1e497c', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '84f34ee0-120b-40c5-876f-9d22c9581066', 'material', 10, 'Gram', null, 3, null, null),
('fd0d6684-777e-4ad3-bfae-9c843c81ef64', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '7d18d48e-81c7-443b-a39a-f4b25cd3d60c', 'material', 20, 'Gram', null, 4, null, null),
('55f8a939-a184-466c-a010-cf7752071979', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 25, 'Gram', null, 5, null, null),
('a6a15231-605c-48eb-9db4-ce2e400f02e5', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 25, 'Gram', 1.43, 6, null, null),
('49558528-c787-4897-9ed6-392781ee5052', 'befb6149-aa96-46bf-8201-0bf8dc05b476', 'e78e9717-194e-4d99-91fa-2925b4823168', 'material', 40, 'Gram', null, 7, null, null),
('7977a634-7eb9-41b3-a10a-24a9d837093e', 'befb6149-aa96-46bf-8201-0bf8dc05b476', '6ba6c4fe-0a7a-4fb6-a92f-83ffa333e10c', 'material', 1, 'Gram', null, 8, null, null),
('989a1ae5-457e-4810-8501-5baa317616fb', '06c115de-4584-4865-b25f-a5178c5a0b70', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('a03219ee-752f-4134-9f92-21af87526610', '06c115de-4584-4865-b25f-a5178c5a0b70', '5035709a-1cec-4aad-968f-9c56626a59be', 'material', 1.4, 'Gram', null, 1, null, null),
('25eb4189-524d-4214-8909-1cc6de879570', '06c115de-4584-4865-b25f-a5178c5a0b70', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 3, 'Gram', 0.45, 2, null, null),
('d63997ac-c332-484e-8dc9-6fc64a194420', '06c115de-4584-4865-b25f-a5178c5a0b70', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 25, 'Gram', 22.1, 3, null, null),
('fb98e6fb-d8e9-47f6-98ce-b32406950c23', '06c115de-4584-4865-b25f-a5178c5a0b70', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 10, 'Gram', 0.57, 4, null, null),
('56844476-5074-4212-911c-258830dfcb5f', '06c115de-4584-4865-b25f-a5178c5a0b70', 'a6d9389a-1fd9-4fca-b034-4a4ff9fd7997', 'material', 18, 'Gram', null, 5, null, null),
('41f4e1bd-129a-480a-a727-560cb19de7c7', '06c115de-4584-4865-b25f-a5178c5a0b70', '63d64b84-3a88-4947-a73d-35e0dc2f5b9b', 'material', 15, 'Gram', null, 6, null, null),
('843853a9-0c29-4f62-bb61-2c0dc9808ef7', '06c115de-4584-4865-b25f-a5178c5a0b70', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 1, 'Gram', 0.13, 7, null, null),
('49587cfa-3051-4c7e-92cf-5299f36432e7', '06c115de-4584-4865-b25f-a5178c5a0b70', '41e42836-7df7-40ff-b131-f7fe1b73e994', 'material', 5, 'Gram', 1.25, 8, null, null),
('13d64481-0792-4fac-9776-f654b8af5cf7', '06c115de-4584-4865-b25f-a5178c5a0b70', 'aa1ac125-7eeb-44ff-bccb-d8cb30260037', 'material', 15, 'Gram', null, 9, null, null),
('8fad12c2-3f02-4596-892e-9ef69112edfa', '06c115de-4584-4865-b25f-a5178c5a0b70', '160b685a-82b5-4fd6-80ba-7cbc9221e4b0', 'material', 35, 'Gram', null, 10, null, null),
('f16f28fd-5677-4330-a375-58c5b584b337', '06c115de-4584-4865-b25f-a5178c5a0b70', '16c0cd76-0280-4403-a3b4-5fd331b8b281', 'material', 11, 'Gram', null, 11, null, null),
('0e629ddc-bbf0-452f-9d74-c0088915f0fb', '06c115de-4584-4865-b25f-a5178c5a0b70', 'b74c19fa-1ef5-4b7c-9082-8403e0b5bd5d', 'material', 7, 'Gram', 2.1, 12, null, null),
('99186528-c9fb-4cee-b2d9-240a096cb696', '06c115de-4584-4865-b25f-a5178c5a0b70', 'b389fac3-6da2-4345-beb5-204a4e284b41', 'material', 8, 'Gram', null, 13, null, null),
('0308e350-2ea6-4b6f-aae8-baca7ec29cae', '06c115de-4584-4865-b25f-a5178c5a0b70', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 20, 'Gram', 5.33, 14, null, null),
('cf63317b-8ad0-4b95-8d0f-7270a0db5a0d', '06c115de-4584-4865-b25f-a5178c5a0b70', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 5, 'Gram', null, 15, null, null),
('fbb297b4-41e2-4bc1-8f13-d0a6f089278c', '06c115de-4584-4865-b25f-a5178c5a0b70', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 2, 'Gram', 2, 16, null, null),
('e5e40961-0722-4d81-9ade-a321c07184bc', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('ff0fc1b5-9fc9-4ba0-8506-0875f43756f8', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '5035709a-1cec-4aad-968f-9c56626a59be', 'material', 1.4, 'Gram', null, 1, null, null),
('e4241749-6a0f-485b-85bc-3a5b220166d7', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '41e42836-7df7-40ff-b131-f7fe1b73e994', 'material', 20, 'Gram', 5, 2, null, null),
('42d71f3f-e951-4a85-bdd3-16ce01805813', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 25, 'Gram', 22.1, 3, null, null),
('9378d785-6404-46a3-b653-f27c0ff579ce', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '55d02258-f1dd-47ca-8054-9ababb7b814b', 'material', 4, 'Gram', 1.33, 4, null, null),
('a24621f7-7d2f-44e6-8b67-c288732e7b91', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '20cd6c75-3dc5-43cf-b477-0660449e1d5a', 'material', 6, 'Gram', 0.9, 5, null, null),
('c6c99a0c-42ae-4d43-bfcd-67ac2e36b950', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', 'b74c19fa-1ef5-4b7c-9082-8403e0b5bd5d', 'material', 8, 'Gram', 2.4, 6, null, null),
('02396730-4d98-464f-821e-e886d218c3ac', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', 'b389fac3-6da2-4345-beb5-204a4e284b41', 'material', 8, 'Gram', null, 7, null, null),
('b14b18a9-2797-4776-87eb-3d2b40d26f3b', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 3, 'Gram', 0.39, 8, null, null),
('cfde7a68-f194-4c21-953b-c61242f2bbe5', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '855a337f-b27e-4f59-abd2-359cbf36ee6c', 'material', 10, 'Gram', null, 9, null, null),
('e5ca2613-83ef-47cb-9f36-e4e144a526e9', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 6, 'Gram', 0.9, 10, null, null),
('a3ab09a3-2966-4c3a-8596-64aad9a28dc9', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '2bc2967c-a780-4710-bd84-334645187e95', 'material', 15, 'Gram', null, 11, null, null),
('c37b0312-55f3-4d71-94d9-842b21997806', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 20, 'Gram', 5.33, 12, null, null),
('89bc86b6-ba2a-452e-94fb-9ee2d2d039e8', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 5, 'Gram', null, 13, null, null),
('a0bdb127-6d2e-4a59-a65d-218b98eafa36', 'f6338ebe-6adc-4365-809e-e1d4d189e5df', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 3, 'Gram', 3, 14, null, null),
('d896d1bb-008d-4c11-893b-2b5259840cbb', '4a228d06-25aa-41ce-9f2a-98777f6993aa', 'a582b449-2c8a-4d52-add1-ac93b91e5963', 'material', 130, 'Gram', 32.76, 0, null, null),
('06bba6c6-6c41-40e3-9193-7ebff3a13e95', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '5035709a-1cec-4aad-968f-9c56626a59be', 'material', 2.8, 'Gram', null, 1, null, null),
('05aa546b-c5e4-46f1-998c-97366bc2f001', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '94033b25-4a9e-47d7-942a-8703bb1e02df', 'material', 25, 'Gram', null, 2, null, null),
('02601460-8a8f-4f73-a196-9c43b1f95772', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '3d44872c-8d24-4ff2-b5fa-ea27162ff16b', 'material', 25, 'Gram', 30, 3, null, null),
('84634128-5d4f-4be0-b429-929816a9b5e3', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '37aad92c-b378-4140-8c10-6cc6dbbb0ff9', 'material', 50, 'Gram', 44.2, 4, null, null),
('87413ad7-146e-4078-b46e-7678f6369f35', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 15, 'Gram', 2.25, 5, null, null),
('d779b811-0804-4a4c-ab89-c766b83f36c7', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '1c54379a-05ec-4b75-ab1a-6614100770fe', 'material', 40, 'Gram', null, 6, null, null),
('2b88b013-3a12-42b6-810b-77ce91d16c48', '4a228d06-25aa-41ce-9f2a-98777f6993aa', 'a718562d-240b-43cd-a422-a4247c1b56ef', 'material', 50, 'Gram', null, 7, null, null),
('144ed6b4-b21a-410e-a58d-58eb20cd0726', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '4fba861b-6fa7-4583-9781-9c3a051d709b', 'material', 30, 'Gram', 8, 8, null, null),
('fb8e01e4-238b-4208-a02a-400c9d6c5a02', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '454616c5-de73-4638-8205-8e58542cf2bd', 'material', 20, 'Gram', null, 9, null, null),
('b508cbab-9c7a-44c4-850f-81ed130605be', '4a228d06-25aa-41ce-9f2a-98777f6993aa', '4d941eae-d36e-4dc0-8944-12b2195e8b21', 'material', 2, 'Gram', 2, 10, null, null),
('2292dbca-f44c-418d-9977-7ef52af47116', '4a228d06-25aa-41ce-9f2a-98777f6993aa', 'b389fac3-6da2-4345-beb5-204a4e284b41', 'material', 10, 'Gram', null, 11, null, null),
('2d023a85-98cc-49e0-82db-5fa3c58bf905', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 15, 'ML', 2.14, 0, null, null),
('ec88c922-49c5-4f73-8b27-5a0553fa2ac1', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '03673e58-9552-4194-88a5-68031ad44d43', 'material', 5, 'Gram', null, 1, null, null),
('14f6a260-d37b-484e-ac49-cf36c696bb3f', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 25, 'Gram', 1.43, 2, null, null),
('13cb8399-7a78-44fc-b21a-26dc79bcbaee', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', 'd01f3a1b-a6e0-4c08-8dfd-d6290cf0a114', 'material', 20, 'Gram', 1.8, 3, null, null),
('97a31fbc-3571-4067-831d-0b5d08f66b9a', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '8c675294-f937-4636-8811-78790b53b927', 'material', 20, 'Gram', null, 4, null, null),
('7d50cf76-4b84-40ed-b8bf-0c9b0f19eaeb', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '16e7777d-d747-48c5-85fb-613d4586b4b7', 'material', 300, 'Gram', null, 5, null, null),
('b8ef8bdf-75d3-4d24-8530-7bf02d6a4f24', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 3, 'Gram', 0.94, 6, null, null),
('601074fa-ae52-46d9-9667-569479c1a66f', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 7, null, null),
('6c3eecf5-d809-49c9-9908-ce7d25894016', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('33f95ee6-b3c5-4cb7-b218-6dc270d37fa1', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('6c06735a-f7d4-4d90-bdfa-5baedcf1e3ea', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '4c2f89f0-370b-4328-8db8-f6620c58c107', 'material', 5, 'ML', null, 10, null, null),
('6b749736-0985-4431-94ea-f423021a1e15', 'bc4efbbf-2be2-4af9-8ee3-1563ed6aa00d', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 4, 'Gram', 0.6, 11, null, null),
('fb2c4e71-6163-4c09-8b99-d451a035ff2b', '0fcdcee9-7464-4348-ac0e-68cece6b071d', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 22, 'ML', 3.14, 0, null, null),
('8798d4a3-8ad5-4226-b7c3-48045d81672a', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '0c081522-0188-43be-98de-882a35b7825d', 'material', 16, 'Gram', null, 1, null, null),
('9299d846-c6ae-47d7-b146-8f3578ff48fa', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '34f930ff-6253-4b91-a796-24f7626ab625', 'material', 30, 'Gram', 10.92, 2, null, null),
('bdbc94f5-59e0-4514-b433-ef712078694a', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '0aae595d-00db-4a73-b17b-8d7533ef6f08', 'material', 30, 'Gram', null, 3, null, null),
('26cdda0d-772e-4229-8d21-8d0e78d57ded', '0fcdcee9-7464-4348-ac0e-68cece6b071d', 'c7f09580-60b9-411d-bf40-d7199249f543', 'material', 30, 'Gram', 3.43, 4, null, null),
('f36d6bf8-d934-4b2e-8436-83ca28b0dfc3', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '16e7777d-d747-48c5-85fb-613d4586b4b7', 'material', 300, 'Gram', null, 5, null, null),
('b2690030-e365-4042-aed6-7d09e7b3ef73', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 3, 'Gram', 0.94, 6, null, null),
('82286e06-8331-4eaf-a933-c2c09b6d5d7a', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 7, null, null),
('31fc5c69-8271-4912-b4cb-ba345bd08e4f', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('0601c476-87e7-42c3-ab5f-b9e6af49768f', '0fcdcee9-7464-4348-ac0e-68cece6b071d', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 0.8, 'Gram', 0.27, 9, null, null),
('4119b53e-d234-42dd-be73-b13990a9f871', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '7f72a693-2b69-461c-9df7-946060b6a4ea', 'material', 8, 'Gram', 1.6, 10, null, null),
('2f478718-9879-4ae8-9767-8b1f40a2325a', '0fcdcee9-7464-4348-ac0e-68cece6b071d', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 4, 'Gram', 0.6, 11, null, null),
('6f7db4d7-3bfa-41ac-b60b-9e9744aef744', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 15, 'ML', 2.14, 0, null, null),
('58607034-f0e7-4848-b4e2-f53c01e1d0fc', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 15, 'Gram', 4.5, 1, null, null),
('0a0aa8ff-e48c-42a4-b965-d2c8b33fa290', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '515daeaf-2242-42db-b8f0-b09b2b44d90b', 'material', 60, 'Gram', 4.28, 2, null, null),
('20989a68-f996-47de-b569-d6ac9a630856', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', 'ca98e3bb-331b-4f8c-ae34-6e193c109ed9', 'material', 2.5, 'Gram', null, 3, null, null),
('26569080-31db-479d-b64b-7cfb8cfc956d', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '1922aa7e-834d-4818-a40d-5d5dbbe1f4ea', 'material', 5, 'Gram', 1.4, 4, null, null),
('c380ed87-0b29-49e4-a72e-8441a58c0594', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '7b9499e7-4be3-45e5-b60e-2c2d41c74a89', 'material', 2.5, 'Gram', 0.5, 5, null, null),
('ec5fa50c-872a-4203-b8ea-3fe30206e0a0', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '16e7777d-d747-48c5-85fb-613d4586b4b7', 'material', 300, 'Gram', null, 6, null, null),
('e145e417-3de8-4c5f-8be1-ab81c0dcc26c', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '8c675294-f937-4636-8811-78790b53b927', 'material', 20, 'Gram', null, 7, null, null),
('ff988a9e-9ad5-4b35-8be7-beddab8bc193', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 0.6, 'Gram', 0.6, 8, null, null),
('39fa0a79-28ae-45f3-b319-5727c44ca5bc', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', 'fc49c4df-fd31-4ee1-9b25-43bd6b0964e7', 'material', 5, 'Gram', 83.35, 9, null, null),
('92099b3e-48e6-4f53-94d5-5d4f31cc0872', '6f29f70c-e98b-4997-a3d7-6e10d8a09880', '8611b762-4b84-4b42-9a35-01c413fe8f07', 'material', 2.5, 'ML', 13.39, 10, null, null),
('036151fe-3068-48e2-81da-91b196aa3b15', '61a064c9-d715-4c64-9d34-59069b59de34', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 22, 'ML', 3.14, 0, null, null),
('3dbdb153-76b9-4b83-b0df-fa5421d8487f', '61a064c9-d715-4c64-9d34-59069b59de34', 'cb08bafd-48c1-4229-a630-379097621d50', 'material', 5, 'Gram', null, 1, null, null),
('6876c723-1c27-473d-9c32-6df982827d66', '61a064c9-d715-4c64-9d34-59069b59de34', 'cffc6e81-fe43-44b2-b07f-f7640a995d29', 'material', 30, 'Gram', 2.62, 2, null, null),
('a3b96340-2aca-4b83-adaa-abe9f6394e28', '61a064c9-d715-4c64-9d34-59069b59de34', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 30, 'Gram', 1.71, 3, null, null),
('d3126ea8-0ace-4f71-a470-55421accb9c3', '61a064c9-d715-4c64-9d34-59069b59de34', '7747f820-d0da-4499-aad0-590e5547350e', 'material', 30, 'Gram', 3, 4, null, null),
('8e6bc644-dc3e-4d2e-ada0-fe9729149e3e', '61a064c9-d715-4c64-9d34-59069b59de34', '9aa19f39-1212-4e18-b2c6-0d115c678280', 'material', 140, 'Gram', null, 5, null, null),
('7a27b09a-c2ed-49f1-ba8d-bbe1222985e2', '61a064c9-d715-4c64-9d34-59069b59de34', '02540286-c40c-46b3-a647-4fa9d3c2668d', 'material', 30, 'Gram', null, 6, null, null),
('39d120c8-3222-4069-b4d1-9f031471bdad', '61a064c9-d715-4c64-9d34-59069b59de34', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 3, 'Gram', 0.94, 7, null, null),
('0ed342a1-7f52-47ba-b5e6-07772aea63de', '61a064c9-d715-4c64-9d34-59069b59de34', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 8, null, null),
('59fbd868-2fe4-44f9-9b89-8b713c6fb6fb', '61a064c9-d715-4c64-9d34-59069b59de34', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 0.5, 'Gram', 0.5, 9, null, null),
('2681081f-70e0-4b19-b05d-29dea63f95c9', '61a064c9-d715-4c64-9d34-59069b59de34', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 0.8, 'Gram', 0.27, 10, null, null),
('51cddccf-4881-456b-98fe-fd734f99c7a2', '61a064c9-d715-4c64-9d34-59069b59de34', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 4, 'Gram', 0.6, 11, null, null),
('75823519-3516-45ec-8be9-f10441d0e4ca', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 22, 'ML', 3.14, 0, null, null),
('876c1336-a154-4c13-a2b3-c113444697e4', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 1, null, null),
('36449b95-a3c2-472a-b7b0-d600c45adca3', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 4, 'Gram', null, 2, null, null),
('8bef4498-5112-4a17-8f03-bcc5f6c2ce8c', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', '6a342edc-057a-4478-82e4-d3467c598ce3', 'material', 60, 'Gram', null, 3, null, null),
('32c47e92-2cb7-4eae-ab33-c8998911a06c', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'fd397589-15da-4555-ab30-dcb73a169eb6', 'material', 10, 'Gram', null, 4, null, null),
('a7171ef1-e6d6-44c1-8fea-9770f3f87b95', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'f29c72a5-ebab-4029-a2fc-470820e00315', 'material', 120, 'Gram', null, 5, null, null),
('1c897d28-42d4-423f-9818-bd3c901c0358', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'fb34032c-074f-4843-a431-520a729d5a67', 'material', 30, 'Gram', null, 6, null, null),
('5e3241db-ac82-424a-ba26-68effce7d891', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', '2fa71201-e164-4d25-9450-4d5fad4a30a8', 'material', 30, 'Gram', null, 7, null, null),
('145f53ca-83ff-4eb9-9235-b32f6a96d29f', 'ddc4f0b7-e1e4-4bae-b3a1-93d6fc0e3e72', 'ef8d5829-ae95-4b28-abb5-cc56b0b0ffc4', 'material', 5, 'Gram', null, 8, null, null),
('2a3fae62-a92a-41e8-bc0e-c6e6612c1b31', '9b601a99-0808-42e3-bb05-d61117e2a9f7', 'b16ec45a-c1c1-41a1-a8ae-45e9fdb46d94', 'material', 22, 'ML', 3.14, 0, null, null),
('cb2d470d-5b45-4c4a-9945-71bd468d5fab', '9b601a99-0808-42e3-bb05-d61117e2a9f7', 'cb08bafd-48c1-4229-a630-379097621d50', 'material', 5, 'Gram', null, 1, null, null),
('72e9e90b-ce6b-43fd-83a7-24184891bfff', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '3f553a9e-2fd2-43e8-bc80-ef846303fe4f', 'material', 60, 'Gram', null, 2, null, null),
('0aa4e782-a0b1-4bcf-9701-e09705c04793', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '04281782-87f1-43eb-abbc-2698fa74ad4c', 'material', 30, 'Gram', 1.71, 3, null, null),
('1671989b-d0dc-494c-94d9-624c962e5e1c', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '566f2b2c-ca47-4164-92bc-70bc6404343b', 'material', 150, 'Gram', null, 4, null, null),
('aaf10658-2cf1-4268-8a15-7cd800bce72b', '9b601a99-0808-42e3-bb05-d61117e2a9f7', 'a3c1c6f1-3dc0-4f44-a0ab-b3beb4c4ecde', 'material', 40, 'Gram', null, 5, null, null),
('e690d14e-06b6-4d27-8ff7-93abebe91e8c', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '2fa71201-e164-4d25-9450-4d5fad4a30a8', 'material', 30, 'Gram', null, 6, null, null),
('b5a081d6-a56e-4202-ba57-2e1e42627ab3', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 10, 'Gram', 1.5, 7, null, null),
('d48d9b04-fffc-4319-a47a-719973f51d78', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '6e92a078-b40d-4789-afb9-a50fe5802968', 'material', 15, 'Gram', null, 8, null, null),
('09f707ca-c259-4cc3-a01f-49d22378be8d', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 5, 'Gram', 0.66, 9, null, null),
('18ba1cf9-80b9-4814-a428-6a2ccc8c3740', '9b601a99-0808-42e3-bb05-d61117e2a9f7', '8dace206-ff84-4e4d-834e-8115fa1a54aa', 'material', 1, 'Piece', null, 10, null, null),
('93c62f5d-97f9-445b-9f1b-33a9dede3da4', '0759a466-729c-4353-9d7d-46fb706acb59', '65882cc0-5119-4843-9ef7-1bc9c4be1f53', 'material', 90, 'Gram', null, 0, null, null),
('ab098e58-16fd-497e-8ec9-61a3f658ba8f', '0759a466-729c-4353-9d7d-46fb706acb59', 'f1568afa-11d6-4eb7-8277-7c9d41660600', 'material', 120, 'Gram', null, 1, null, null),
('24e080f9-4361-4817-b3cb-0c5f6b910f5d', '0759a466-729c-4353-9d7d-46fb706acb59', '9ada312e-b73c-4ee2-98dd-abd6ece4683d', 'material', 40, 'Gram', null, 2, null, null),
('ab5e0f4f-e26d-4725-a371-a8c42575de39', '0759a466-729c-4353-9d7d-46fb706acb59', '3564d0b2-ae52-4f75-9932-6e6a1488128d', 'material', 30, 'Gram', null, 3, null, null),
('4319805d-aa72-466e-b50f-1e8ca328e088', '0759a466-729c-4353-9d7d-46fb706acb59', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 1, 'Gram', null, 4, null, null),
('23e3f8a9-7dcf-42f6-ba3b-f0b68be2edad', '0759a466-729c-4353-9d7d-46fb706acb59', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 5, null, null),
('b4176fe9-901f-476a-8401-b80492ba117b', '0759a466-729c-4353-9d7d-46fb706acb59', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 2, 'Gram', 0.67, 6, null, null),
('38cdb72d-fbec-47e0-bb4a-c523fdc77820', '0759a466-729c-4353-9d7d-46fb706acb59', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 2, 'Gram', 2, 7, null, null),
('c10a0dd8-ddb2-4a28-8551-442f1a51b5f1', '0759a466-729c-4353-9d7d-46fb706acb59', 'b1f2ff36-f5ca-4a2d-9fba-b025b35ab768', 'material', 7, 'Gram', 1.4, 8, null, null),
('95be96e6-e6ac-4b98-a750-1c43f6f4a505', '0759a466-729c-4353-9d7d-46fb706acb59', 'd01f3a1b-a6e0-4c08-8dfd-d6290cf0a114', 'material', 20, 'Gram', 1.8, 9, null, null),
('be2e73f6-c58e-4dc1-9187-212428e272f7', '0759a466-729c-4353-9d7d-46fb706acb59', 'cffc6e81-fe43-44b2-b07f-f7640a995d29', 'material', 20, 'Gram', 1.74, 10, null, null),
('f8973da4-c527-4307-985c-048d43248c3e', '0759a466-729c-4353-9d7d-46fb706acb59', '2fa71201-e164-4d25-9450-4d5fad4a30a8', 'material', 10, 'Gram', null, 11, null, null),
('6a4ba468-eb56-4905-a10f-2a7d3a76c62b', '0759a466-729c-4353-9d7d-46fb706acb59', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 15, 'Gram', 2.25, 12, null, null),
('2341294b-ced0-4e19-a32f-093feeee7796', '0759a466-729c-4353-9d7d-46fb706acb59', 'b230ebdb-feb9-42f3-bf1b-da8c2b289876', 'material', 2, 'Gram', null, 13, null, null),
('9eed9526-1b13-4a98-98ae-80a6cbcd3fc6', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'ef4e5b02-135a-4b46-8e3e-b5e850f9c38f', 'material', 20, 'Gram', 2.09, 0, null, null),
('0f32e072-8de1-4b8a-a35b-5e997c75a3a3', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'e4f23d69-97b0-4b5e-948f-c973ad5bd748', 'material', 10, 'Gram', null, 1, null, null),
('4e5e5ab3-83f0-4895-834b-10d797f68b83', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '9da0289c-7689-4604-893e-973cef11bf72', 'material', 10, 'Gram', 1.8, 2, null, null),
('ff6998ad-a470-4005-9c6d-e28661140506', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'c1d52d83-ae6f-4b2e-8c06-4017ebc1f6e7', 'material', 20, 'Gram', 12.96, 3, null, null),
('833994c1-d75c-41b1-8814-ba1618ae5371', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'd1f53be8-9f9d-415b-9ad9-d3374676bad8', 'material', 5, 'Gram', 4.49, 4, null, null),
('ce67dfad-4ddd-40af-a434-58e94ac47c56', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '463ad216-f76f-45db-923a-7d61c9633171', 'material', 40, 'Gram', null, 5, null, null),
('c145b77a-bfe0-4036-a61a-28e43137759b', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'ffe2bcc5-e4de-4773-ba81-3f1f39be3c81', 'material', 40, 'Gram', 16, 6, null, null),
('e45231fa-60a8-49f1-a44d-c21f3ea5fe6a', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 350, 'Gram', 0, 7, null, null),
('65839325-b4ab-4135-94b5-252de83af088', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'd2930eb1-2755-4370-a038-f6e40b19deaf', 'material', 90, 'Gram', null, 8, null, null),
('5d92d146-c5de-444e-b704-3f1a231ea246', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 5, 'Gram', 1.56, 9, null, null),
('a8ae940c-a799-4eb7-b9bf-0be18d837a31', '344a7a22-e412-47d6-abc6-e8682f0ebdca', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 3, 'Gram', 1, 10, null, null),
('d6d0474b-9e8b-4795-9214-41a32b202de9', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('55e87e07-4568-4307-a0f7-17e3b26726f4', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 12, null, null),
('ce3e1c15-4fa8-4408-86c7-e5269125bb4a', '344a7a22-e412-47d6-abc6-e8682f0ebdca', '234b5cdc-45af-4dff-8b94-68927d087494', 'material', 10, 'Gram', 1.01, 13, null, null),
('b331fd16-957e-4b55-a90d-c586968cc4b9', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'ef4e5b02-135a-4b46-8e3e-b5e850f9c38f', 'material', 20, 'Gram', 2.09, 0, null, null),
('8f442b7a-9f41-44ad-a607-9a9872f16355', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'e4f23d69-97b0-4b5e-948f-c973ad5bd748', 'material', 10, 'Gram', null, 1, null, null),
('d7e47f71-de51-4374-9759-e049a6faf3c7', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '9da0289c-7689-4604-893e-973cef11bf72', 'material', 10, 'Gram', 1.8, 2, null, null),
('5d188d6b-62d1-4eec-8510-e2f3c7246f49', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'c1d52d83-ae6f-4b2e-8c06-4017ebc1f6e7', 'material', 20, 'Gram', 12.96, 3, null, null),
('fee27ff3-0109-4262-859c-8e781a9a96fe', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '463ad216-f76f-45db-923a-7d61c9633171', 'material', 40, 'Gram', null, 4, null, null),
('6d41c40a-4318-4b8c-a9b5-0bde15be2f8e', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '4234d7fa-5ce3-4c76-b43a-348f08884128', 'material', 5, 'Gram', 5.33, 5, null, null),
('d3215f3c-e5c7-4cf4-8372-aa0fb65e5290', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '522fa47a-0857-4f50-a510-9260344dc291', 'material', 350, 'Gram', 0, 6, null, null),
('1076dda6-5432-4687-b905-b68988d74e75', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'ffe2bcc5-e4de-4773-ba81-3f1f39be3c81', 'material', 40, 'Gram', 16, 7, null, null),
('42dd8b0c-8d5f-4251-9904-5c2e175c7ec6', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'd2930eb1-2755-4370-a038-f6e40b19deaf', 'material', 90, 'Gram', null, 8, null, null),
('e520c920-7a41-41d8-9e98-37dc428514dc', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 5, 'Gram', 1.56, 9, null, null),
('0731d34d-0733-467e-b62b-9d9ce037f5ac', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 3, 'Gram', 1, 10, null, null),
('e3fde8e0-93ca-4f0e-9726-2a26b2616995', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '17c3908f-cb0a-424c-bc19-234ae1de71c4', 'material', 1.5, 'Gram', 1.5, 11, null, null),
('8b85de29-907f-437a-907f-578296d5ce70', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 12, null, null),
('b5c304f8-28f2-4c01-9273-069b53fcb200', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '234b5cdc-45af-4dff-8b94-68927d087494', 'material', 10, 'Gram', 1.01, 13, null, null),
('973cb5b2-a50a-41a5-877b-bb4e434c2acf', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '1141a3a3-e52a-4aeb-821e-f9e1dd49524e', 'material', 20, 'Gram', null, 14, null, null),
('fc49d6cc-62cc-4735-87f2-5bf592b0f87c', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '74fec152-ace2-4342-8307-ef7123124ee1', 'material', 6, 'Gram', 1.09, 15, null, null),
('bf434ff6-dc92-4b43-a9ac-b08f36ec579a', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'c67b39df-a7a0-4b71-a19d-d5318a4468b4', 'material', 18, 'Gram', null, 16, null, null),
('871f48ee-c3a3-427b-ab87-2d613fa8e43d', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '2ba9a2e7-a77f-4618-835d-f0016341136f', 'material', 30, 'Gram', null, 17, null, null),
('93d84c44-580e-41ac-8244-5ea87a422773', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', 'd1f8eb7e-1cdd-449d-9fce-a92e1e9ef4cb', 'material', 10, 'Gram', null, 18, null, null),
('5c2e0cfd-46b1-486a-b9a7-b0b61016a293', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '23f68aa6-859c-47aa-b737-058e15d76d5b', 'material', 2, 'Gram', 0.2, 19, null, null),
('09eea467-f240-4743-b65e-d402b44a4628', '85e3c55a-cd91-45c8-8f3b-62954deab3f0', '2932c2ea-76af-44dd-aa59-d95015a6f5e2', 'material', 1, 'Piece', null, 20, null, null),
('fc29bc95-b175-4f2a-b3b9-3bd2d255f350', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '40d228b2-9e31-47f7-b19c-c8ca44a639c6', 'material', 30, 'Gram', 16.14, 0, null, null),
('b49f3a46-f2ce-45b6-ac47-180f45b792ea', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', 'af35ac5b-0980-4143-ab36-a8a5eeea55bc', 'material', 10, 'Gram', 3, 1, null, null),
('b7578606-3576-419d-8e49-6757f296f515', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '4222f643-2a5f-45c3-9c6a-12498e536a52', 'material', 4, 'Gram', null, 2, null, null),
('5a377c1a-c870-4f01-9d3e-365ccc13e9e9', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '71e0a0ab-983b-4d27-ac15-aa666e66bc4f', 'material', 12, 'Gram', 1.92, 3, null, null),
('49565abc-c37f-4867-99d5-8098a687362e', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '00b40ec0-8a86-42f2-a32f-9e35a9abc70a', 'material', 3, 'Gram', 0.94, 4, null, null),
('8506cb9f-52d1-430f-8435-452fd0890c3b', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '85cf76ce-10cc-42b8-af18-684fb5da9d76', 'material', 2, 'Gram', 0.67, 5, null, null),
('45d8e52f-e8fd-452e-9911-04d81bdeec73', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', 'c7f8e6f8-868e-4501-b771-dc3d1c28cb4d', 'material', 0.8, 'Gram', 0.27, 6, null, null),
('5db67ec4-9e50-410d-bfb0-f88cd7112eab', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '0650dd76-be04-4197-bbc5-8dc21acb04d6', 'material', 140, 'Gram', null, 7, null, null),
('0c1f8549-b817-447d-be71-27dc0c9044f7', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '214dc597-c51f-42a1-af2b-63ec6306ec03', 'material', 5, 'Gram', null, 8, null, null),
('c403590f-86a6-4358-aecf-f919880d8dfd', '176ab02a-9b10-4c58-941c-20d2c5b0a9a2', '771e0b3e-5764-4e1e-a2c2-f36d30f03500', 'material', 5, 'Gram', null, 9, null, null),
('72d185af-3edb-4e1e-b948-e62876510c6c', '3e00df44-a8b2-443c-b1f7-e53866ab659c', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('9d3a0792-b6ab-4dab-9702-1f9a7aacb1a8', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '0a3c18bf-817f-4961-9e58-7154da69d3be', 'material', 150, 'Gram', 35.91, 1, null, null),
('73e3bff0-048c-49de-ad12-38641b7596b4', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 50, 'Gram', 3.34, 2, null, null),
('508ed91c-5a20-4535-bdf8-37f225447ce4', '3e00df44-a8b2-443c-b1f7-e53866ab659c', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 30, 'Gram', 7.71, 3, null, null),
('37fd6726-21f4-40e6-ad81-43bfb8c537a6', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '9b093342-1c59-474f-a417-773d07d180c2', 'material', 6, 'Gram', 7.2, 4, null, null),
('461be04f-3bd9-4c0a-8455-a82ad2b7de00', '3e00df44-a8b2-443c-b1f7-e53866ab659c', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 5, null, null),
('550e4cfe-059b-466f-8772-cb01e28d00ca', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '515daeaf-2242-42db-b8f0-b09b2b44d90b', 'material', 70, 'Gram', 5, 6, null, null),
('c72afb04-0e49-400e-907b-51d9e0f87825', '3e00df44-a8b2-443c-b1f7-e53866ab659c', 'ea20e218-253c-44f8-9da6-ded4adfd4a80', 'material', 50, 'Gram', 21.25, 7, null, null),
('d6d99684-596a-4441-bed4-c1a7184d548e', '3e00df44-a8b2-443c-b1f7-e53866ab659c', 'cb4431be-959d-44ab-bbcd-78a6a5033be6', 'material', 30, 'Gram', 39, 8, null, null),
('387659ee-639f-4f74-a686-2f92f105aeeb', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 9, null, null),
('ed2ae74b-3b0f-428c-a53f-7a3b2f4d7cb2', '3e00df44-a8b2-443c-b1f7-e53866ab659c', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 10, 'Gram', 1.5, 10, null, null),
('95691bc1-8981-49ca-9b6f-e60b935be0e0', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('d4765436-8362-4889-a39e-c7156b5b9c98', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '0a3c18bf-817f-4961-9e58-7154da69d3be', 'material', 80, 'Gram', 19.15, 1, null, null),
('89e3ca40-ec3d-49d8-93b4-347c629ec7bd', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 30, 'Gram', 2, 2, null, null),
('1b1eac9f-d15b-4bc5-8fe8-74634627b23d', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 20, 'Gram', 5.14, 3, null, null),
('200ccc1b-125f-4995-aed9-1b1a28e41fc0', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '9b093342-1c59-474f-a417-773d07d180c2', 'material', 4, 'Gram', 4.8, 4, null, null),
('45ee8e22-9727-4dd4-b3ca-a1209ace05d2', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 5, null, null),
('48a0a6fa-5b95-40d4-8398-fe52d749ef08', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '515daeaf-2242-42db-b8f0-b09b2b44d90b', 'material', 50, 'Gram', 3.57, 6, null, null),
('47c59877-d49b-45aa-9503-9860fd5d37b4', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'ea20e218-253c-44f8-9da6-ded4adfd4a80', 'material', 20, 'Gram', 8.5, 7, null, null),
('b502254b-894d-4e8d-922b-ff8e4f73cb18', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', 'cb4431be-959d-44ab-bbcd-78a6a5033be6', 'material', 20, 'Gram', 26, 8, null, null),
('f74f2b70-04ec-4304-b28b-ba44015fce3b', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 9, null, null),
('432d0822-5931-4db1-8975-2e21d1dc598c', '5e2f54e8-b540-42ec-9349-0738f7c7e98b', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 8, 'Gram', 1.2, 10, null, null),
('30ba0743-2f4a-46f5-9408-3b3f6c50a1ef', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('a4e87c86-da6e-44f6-a4fc-82f651e83057', '13a16e8e-fca6-4f69-9144-cfae026bfe44', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('fc3082d8-dc96-46d9-9581-88a9989f2067', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('8c40bf9b-baa7-4c3d-816f-1c71ccf40d8f', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'd382930a-f357-453f-918c-67b929134672', 'material', 30, 'Gram', 8.57, 3, null, null),
('66f8578c-96e3-47a1-8f6b-572e1b5f02a7', '13a16e8e-fca6-4f69-9144-cfae026bfe44', '5e880a4e-3dfa-45cd-97e3-d262ed9a129a', 'material', 20, 'Gram', 6.25, 4, null, null),
('b634f85a-4726-40d5-95b4-02311b5f9a1f', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'c1dd247c-0e38-40a8-8fc0-12987b92a5c5', 'material', 100, 'Gram', 13.44, 5, null, null),
('e7b060b0-df8d-407c-b7bb-7cb69ed78108', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'a61a0675-cf31-46c4-9997-fbf246d76b4b', 'material', 50, 'Gram', 51, 6, null, null),
('924d6cd0-9be5-4278-bcb7-e14c913ab941', '13a16e8e-fca6-4f69-9144-cfae026bfe44', '727e5c9e-6dcc-4856-b048-2ba6d09e9492', 'material', 50, 'Gram', 6, 7, null, null),
('b9688ce4-5f59-41b2-884b-422adf055ec0', '13a16e8e-fca6-4f69-9144-cfae026bfe44', '4fe30af2-af5f-4460-b62e-3ddde73a4c21', 'material', 20, 'Gram', 19, 8, null, null),
('4f3db0e6-1b2c-49ec-ba42-f50119f6b94a', '13a16e8e-fca6-4f69-9144-cfae026bfe44', 'aa0f2624-00c6-4704-a6a5-61b6ea129d8f', 'material', 20, 'Gram', 10, 9, null, null),
('9b287c0b-2152-47bc-91fb-417cc5121778', '13a16e8e-fca6-4f69-9144-cfae026bfe44', '20cd6c75-3dc5-43cf-b477-0660449e1d5a', 'material', 20, 'Gram', 3, 10, null, null),
('ec35917d-1970-48ab-8ed9-f79f05f09f24', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('14ca6310-b3b1-4efe-bc9e-355d20abd3c8', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('08167a20-3e38-423c-b7d7-e6a4456914ab', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('916e124f-16d0-4543-8ecb-d50735c1629a', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'd382930a-f357-453f-918c-67b929134672', 'material', 20, 'Gram', 5.71, 3, null, null),
('d7149818-78cb-44c6-8b36-9d6009be1657', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', '5e880a4e-3dfa-45cd-97e3-d262ed9a129a', 'material', 15, 'Gram', 4.69, 4, null, null),
('b4e156a0-04bd-4d09-9d46-ba3d557ed58d', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'c1dd247c-0e38-40a8-8fc0-12987b92a5c5', 'material', 70, 'Gram', 9.41, 5, null, null),
('886bd431-cd40-4c34-9391-2cc835968afb', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'a61a0675-cf31-46c4-9997-fbf246d76b4b', 'material', 30, 'Gram', 30.6, 6, null, null),
('e8ec2ce2-e782-48b2-b536-27794d15e026', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', '727e5c9e-6dcc-4856-b048-2ba6d09e9492', 'material', 25, 'Gram', 3, 7, null, null),
('93a16a4a-38be-44f5-8cec-470f60089b1e', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', '4fe30af2-af5f-4460-b62e-3ddde73a4c21', 'material', 10, 'Gram', 9.5, 8, null, null),
('bc36121f-79e3-47f3-a476-aa8c6f15178b', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', 'aa0f2624-00c6-4704-a6a5-61b6ea129d8f', 'material', 15, 'Gram', 7.5, 9, null, null),
('bb456f66-110f-491d-b755-d09ed42bd4a1', '2fca7651-7761-40ad-a81b-ebdcc06e5ff1', '20cd6c75-3dc5-43cf-b477-0660449e1d5a', 'material', 10, 'Gram', 1.5, 10, null, null),
('a4c8dcad-b5f5-40f9-a1ff-bf92e3867878', 'ad711efe-2240-4a99-a28f-f43aee167147', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('2ed14a0a-3673-49f7-aec8-7fe5b95961f8', 'ad711efe-2240-4a99-a28f-f43aee167147', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 1, null, null),
('cd65346f-824b-4891-9d12-adfeea27c308', 'ad711efe-2240-4a99-a28f-f43aee167147', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 20, 'Gram', 5.6, 2, null, null),
('33ab3532-3cef-44e2-95c1-64118f9f519b', 'ad711efe-2240-4a99-a28f-f43aee167147', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 150, 'Gram', 31, 3, null, null),
('e218b1c6-3ec6-4e26-a369-eae74b79a0ec', 'ad711efe-2240-4a99-a28f-f43aee167147', '8b7d5cca-5ea5-406b-851a-20489eb19f1b', 'material', 40, 'Gram', 16.34, 4, null, null),
('4fd2013a-99eb-4ceb-8891-e7bbe0850bec', 'ad711efe-2240-4a99-a28f-f43aee167147', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 5, null, null),
('b363466d-8a23-40a4-8131-c60a61bf5b7e', 'ad711efe-2240-4a99-a28f-f43aee167147', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 6, null, null),
('69eace0e-3400-4717-877e-c954751a9523', 'ad711efe-2240-4a99-a28f-f43aee167147', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 25, 'Gram', 4.55, 7, null, null),
('ca7574df-8563-4193-8cff-c0d54428a0bd', '72c17ba3-8372-488d-b506-ce11e8c83d81', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('4389656e-cb5f-4262-ac63-8b6d0d02bd61', '72c17ba3-8372-488d-b506-ce11e8c83d81', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 1, null, null),
('2dcd2773-cafe-4856-abd6-2edc93ea1cf1', '72c17ba3-8372-488d-b506-ce11e8c83d81', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 10, 'Gram', 2.8, 2, null, null),
('8868876d-9c90-4f85-8454-ef11d85bd477', '72c17ba3-8372-488d-b506-ce11e8c83d81', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 90, 'Gram', 18.6, 3, null, null),
('f7c0dc16-7910-47c2-9bca-c9f19ca6865a', '72c17ba3-8372-488d-b506-ce11e8c83d81', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 10, 'Gram', 4.08, 4, null, null),
('ad7e0c26-a856-471d-bc18-ed21a70b8a91', '72c17ba3-8372-488d-b506-ce11e8c83d81', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 5, null, null),
('f17b71eb-9411-4fab-a450-4fa956815f9b', '72c17ba3-8372-488d-b506-ce11e8c83d81', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 6, null, null),
('a5caac65-b964-4073-8405-9e12eba3af0d', '72c17ba3-8372-488d-b506-ce11e8c83d81', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 20, 'Gram', 3.64, 7, null, null),
('6ec89c0d-d608-458d-a525-35c6ee1e084e', '97f5eac6-e750-43c2-931f-da24f6423fca', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('cf330b89-f90d-42a7-a7b6-1532b3626982', '97f5eac6-e750-43c2-931f-da24f6423fca', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('92ee7787-d84d-4d90-88b0-f75707e885c8', '97f5eac6-e750-43c2-931f-da24f6423fca', '0f5ce0e7-0d55-444e-9fb3-b14854e20eb5', 'material', 5, 'Gram', 1.88, 2, null, null),
('ac5bd1c3-c740-4f9a-bd3a-2cfe3cbe4ed6', '97f5eac6-e750-43c2-931f-da24f6423fca', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 5, 'Gram', 5.25, 3, null, null),
('53080027-a031-4127-ace0-e481f301c35c', '97f5eac6-e750-43c2-931f-da24f6423fca', 'bde68d53-34fb-4acb-9d50-aa6b5e945658', 'material', 130, 'Gram', 115.38, 4, null, null),
('02eaa123-b8b7-41e2-abe8-13b63579c2c5', '97f5eac6-e750-43c2-931f-da24f6423fca', '1b81b6f3-707c-406e-a275-c444a047d188', 'material', 10, 'Gram', 4, 5, null, null),
('f07aa56a-0818-403d-a5b7-2a07372cbafa', '97f5eac6-e750-43c2-931f-da24f6423fca', 'c11ea5a3-dd5d-4de4-b133-d34988cd788b', 'material', 5, 'Gram', 1, 6, null, null),
('5f4f2810-5eee-4c55-b436-a91264051c1b', '97f5eac6-e750-43c2-931f-da24f6423fca', '6c74c12a-fab2-42b9-a208-81b114e5a205', 'material', 5, 'Gram', 23.33, 7, null, null),
('0c357355-97dc-4296-8051-459ff9cb5a04', '532bb14a-6d0c-4499-879e-8503d153d455', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('c2cd3a35-37bd-4279-a38c-6c212732cb12', '532bb14a-6d0c-4499-879e-8503d153d455', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('7918d323-f66c-4270-8ff3-808f39308b2d', '532bb14a-6d0c-4499-879e-8503d153d455', '0f5ce0e7-0d55-444e-9fb3-b14854e20eb5', 'material', 5, 'Gram', 1.88, 2, null, null),
('37a56a5c-32b2-4a7a-a3c1-ae3985227b53', '532bb14a-6d0c-4499-879e-8503d153d455', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 5, 'Gram', 5.25, 3, null, null),
('9e038f19-ecfb-4eec-8896-d4e225f0265c', '532bb14a-6d0c-4499-879e-8503d153d455', 'bde68d53-34fb-4acb-9d50-aa6b5e945658', 'material', 80, 'Gram', 71, 4, null, null),
('5143715a-8996-4e94-8bdc-24bc7bcd088a', '532bb14a-6d0c-4499-879e-8503d153d455', '1b81b6f3-707c-406e-a275-c444a047d188', 'material', 6, 'Gram', 2.4, 5, null, null),
('450b0229-0e6b-4aa0-8e88-7ccdf2f95813', '532bb14a-6d0c-4499-879e-8503d153d455', 'c11ea5a3-dd5d-4de4-b133-d34988cd788b', 'material', 5, 'Gram', 1, 6, null, null),
('b3c10dd2-91f3-4365-91e4-95e979d856ed', '532bb14a-6d0c-4499-879e-8503d153d455', '6c74c12a-fab2-42b9-a208-81b114e5a205', 'material', 3, 'Gram', 14, 7, null, null),
('bf0eed37-862f-40f4-9b9d-f5e718b79e58', '416f15b5-8b76-4c29-b526-68b001c297fc', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('a570e39b-0b67-48be-bffa-fae17e318862', '416f15b5-8b76-4c29-b526-68b001c297fc', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 1, null, null),
('d3928190-54dd-416f-9a00-224a979244f7', '416f15b5-8b76-4c29-b526-68b001c297fc', '800bd63a-e580-410d-b177-de068de7cfdc', 'recipe', 70, 'Gram', 8.06, 2, null, null),
('1c6a9f3b-3ca2-436e-8cb5-6cd36a865ca7', '416f15b5-8b76-4c29-b526-68b001c297fc', '89d245b5-366a-456f-b800-3c789a61b4b2', 'recipe', 200, 'Gram', 40.57, 3, null, null),
('9e6d75fe-1ea6-4e5f-96eb-8e4944d331ff', '416f15b5-8b76-4c29-b526-68b001c297fc', '8def8b2e-3bc2-4169-a870-8ffb8a011714', 'material', 170, 'Gram', 158, 4, null, null),
('1c6c7992-23d7-4e14-ab55-c2c6a5213e9e', '416f15b5-8b76-4c29-b526-68b001c297fc', '55d02258-f1dd-47ca-8054-9ababb7b814b', 'material', 10, 'Gram', 3.33, 5, null, null),
('be2e6af2-7f2b-45b6-b35d-415eca6f1d14', '416f15b5-8b76-4c29-b526-68b001c297fc', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 10, 'Gram', 1.31, 6, null, null),
('7e4d79c1-451f-42e9-b8a7-6397b7fdd97b', '416f15b5-8b76-4c29-b526-68b001c297fc', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 10, 'Gram', 1.5, 7, null, null),
('d1193ffb-4236-4a50-ada5-1f1f3dbf9156', '416f15b5-8b76-4c29-b526-68b001c297fc', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 10, 'Gram', 2.34, 8, null, null),
('a094a225-2ecf-41a4-bc1f-ab94fdec6003', '416f15b5-8b76-4c29-b526-68b001c297fc', '834cc6ef-af07-41f1-9434-8ba8ad00cfcc', 'material', 10, 'Gram', 3, 9, null, null),
('5539007a-e63d-4a1b-b17f-b9de1ea7a808', '416f15b5-8b76-4c29-b526-68b001c297fc', 'e10f7609-b3c4-41a5-b29d-ae9644704c25', 'material', 10, 'Gram', 1, 10, null, null),
('9dba28af-5b09-4bb8-b363-c9bd5614b761', '416f15b5-8b76-4c29-b526-68b001c297fc', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 11, null, null),
('4589329e-cfa1-44f9-98c6-981d8dffdbcc', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('84518eff-2209-4fe1-ad63-5ee77bba0aff', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 1, null, null),
('5bbab573-6717-4ba8-865a-71d8ebeb65d7', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '800bd63a-e580-410d-b177-de068de7cfdc', 'recipe', 50, 'Gram', 5.76, 2, null, null),
('94429852-dfb5-4419-9305-996ade605918', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '89d245b5-366a-456f-b800-3c789a61b4b2', 'recipe', 100, 'Gram', 20.28, 3, null, null),
('54fb4630-16cb-44f0-b3e3-e38abfe30f56', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', 'bde68d53-34fb-4acb-9d50-aa6b5e945658', 'material', 130, 'Gram', 115.38, 4, null, null),
('1ea39515-45db-42a5-add6-56822c98b46a', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '55d02258-f1dd-47ca-8054-9ababb7b814b', 'material', 6, 'Gram', 2, 5, null, null),
('f630f4e6-45ed-4aa3-a06d-12ee773ad3b8', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '4b12572b-a095-463f-bb98-729cbca27b58', 'material', 8, 'Gram', 1.05, 6, null, null),
('b05cccf8-589b-4a3f-9d64-5196fcb760b7', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 8, 'Gram', 1.2, 7, null, null),
('f4f515e5-9dc1-4ac4-8abc-ddea888d341b', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 8, 'Gram', 1.87, 8, null, null),
('6e635497-3724-45a5-ad63-1aa3384217aa', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '834cc6ef-af07-41f1-9434-8ba8ad00cfcc', 'material', 8, 'Gram', 2.4, 9, null, null),
('7054b2f9-d991-47c2-824a-d996daa35318', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', 'e10f7609-b3c4-41a5-b29d-ae9644704c25', 'material', 8, 'Gram', 0.8, 10, null, null),
('920a57c8-6237-4a3f-96a8-5c08513a9a0a', '82ca926a-c0ae-4d60-b029-d80286f7b2f5', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 11, null, null),
('e3431005-7181-4b24-80e1-b7d92465369d', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('dce137f5-32bc-439f-84ca-a9f3e09988e4', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '16e94c48-5c75-4c29-b4be-ad1891376945', 'material', 120, 'Gram', 29.12, 1, null, null),
('828212da-08d1-4be5-bf19-adcd2d3c98f3', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'cdd3958a-ac04-4f5c-aa50-6ae71a710b56', 'material', 100, 'Gram', 61.53, 2, null, null),
('505ceaff-e599-40c2-a318-a76166478d13', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 20, 'Gram', 17, 3, null, null),
('f73040d2-b570-416c-be8f-e57a19720a14', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'aaa1e504-a5f7-40c6-a3b7-e2d638c16789', 'material', 120, 'Gram', 38.52, 4, null, null),
('0a71ae12-2b2e-482c-bb1c-fff2587fa0ef', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'a5c4493b-e03d-42be-be8e-5b26d78400e6', 'material', 50, 'Gram', 4.01, 5, null, null),
('6f0178a5-c97c-47e2-8d99-788a396df6fc', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '82a0e142-3489-4d4c-90c2-a3d666fc69b3', 'material', 30, 'Gram', 8.09, 6, null, null),
('88de86c4-5515-44f9-9699-b29f0a9313bc', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '9cd15336-68a7-4e36-8b30-cf0b6c8a8a5a', 'material', 10, 'Gram', 3.6, 7, null, null),
('214ad123-b498-4119-9d8c-50004b7a7534', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '90eaca47-c3ee-480d-99c8-1365c08d6257', 'material', 25, 'Gram', 12.73, 8, null, null),
('028cf94c-9985-4fcb-b527-c59834752598', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 5, 'Gram', 0.75, 9, null, null),
('5c6c2426-f223-47d9-af3d-665a6a919898', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'material', 2, 'Gram', 4, 10, null, null),
('adbf4474-9196-4c9c-81a5-120c63b981d0', '8ceebc43-95d2-4dc5-a8a3-21a2f6e82374', 'e4183250-a90e-4b96-b780-c93365e940c3', 'material', 20, 'Gram', 9.29, 11, null, null),
('78ef0308-619e-41cf-a5aa-8b37c8f043fc', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('465e3f67-df3e-4525-ac4a-f7bdfb53f831', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '16e94c48-5c75-4c29-b4be-ad1891376945', 'material', 69.68, 'Gram', 16.91, 1, null, null),
('7cd22e10-99a8-4be5-9790-e9024f591952', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'cdd3958a-ac04-4f5c-aa50-6ae71a710b56', 'material', 58.06, 'Gram', 35.72, 2, null, null),
('f8aea4f0-e732-45e1-bc36-757ff832c5a5', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 11.61, 'Gram', 9.87, 3, null, null),
('10abc1a6-f05b-4d1e-ac86-7e811d5f575f', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'aaa1e504-a5f7-40c6-a3b7-e2d638c16789', 'material', 69.68, 'Gram', 22.37, 4, null, null),
('debae677-3a98-415a-b6b4-65434aff94b9', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'a5c4493b-e03d-42be-be8e-5b26d78400e6', 'material', 29.03, 'Gram', 2.33, 5, null, null),
('7691aa98-6a7f-4070-92d5-0fef83287613', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '82a0e142-3489-4d4c-90c2-a3d666fc69b3', 'material', 17.42, 'Gram', 4.7, 6, null, null),
('36f312c0-84e6-4cda-806b-79261f1f2b94', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '9cd15336-68a7-4e36-8b30-cf0b6c8a8a5a', 'material', 5.81, 'Gram', 2.09, 7, null, null),
('7043fd82-c848-4722-8a2b-6131107e34da', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '90eaca47-c3ee-480d-99c8-1365c08d6257', 'material', 14.52, 'Gram', 7.39, 8, null, null),
('ab4abb9c-30d1-406c-b1df-72c2799b888b', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', '23dadd77-9702-4106-966c-76f23e5f9c81', 'material', 2.9, 'Gram', 0.43, 9, null, null),
('edba75d2-3be9-4b5f-bb9b-8c9865501506', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'material', 1.16, 'Gram', 2.32, 10, null, null),
('343b7fca-d990-4252-9571-22419abb0b05', '379082e0-85e7-4c8b-bdd5-c8525c4c2822', 'e4183250-a90e-4b96-b780-c93365e940c3', 'material', 11.61, 'Gram', 5.39, 11, null, null),
('4740f2cc-7b6a-4f28-bd20-7afe7df10d49', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('50325b8f-6451-49cc-9767-d40f060f2ca0', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('b59ce430-5eef-45d3-967d-7950e7a32828', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('ceb67520-4975-44ac-89ca-e09cfc7b8baa', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 3, null, null),
('9729fd94-0aec-483b-9db7-8b7b2cbb7371', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '0b975a61-a821-4e66-9338-3f82c3f7f795', 'material', 50, 'Gram', 15, 4, null, null),
('612bb52a-b5a9-44c6-946b-22cfce1e08ee', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '5991bc4e-5409-44a6-ad2d-3a3da35ce73f', 'material', 20, 'Gram', 6, 5, null, null),
('6c9cac95-6a03-4ab8-93c8-b4a298dfdb21', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 6, null, null),
('dcb7f452-abec-42f6-ab75-19aacd9b31fc', 'cf3167af-4b2d-49d0-94a6-fd6614efade9', '685881f5-24b8-4b97-8f20-6c308939e5b8', 'material', 20, 'Gram', 8, 7, null, null),
('31250873-6ba7-477b-a8ad-3998948dd5cb', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('73404373-4cfd-4c4e-bd84-60bc0f8c542a', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('b58cfe2a-4deb-4a45-b3e1-07b5783be99d', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('2350aa44-a37c-4e1a-90b5-6099b66e6969', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 3, null, null),
('0483670c-529f-474e-9d4d-6a2c847a0fc3', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '0b975a61-a821-4e66-9338-3f82c3f7f795', 'material', 40, 'Gram', 12, 4, null, null),
('485a3e3d-90c3-4e09-ae09-da6d0b659b61', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '5991bc4e-5409-44a6-ad2d-3a3da35ce73f', 'material', 15, 'Gram', 4.5, 5, null, null),
('19b8dae6-ab18-42e7-9363-5fdf050c4773', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 6, null, null),
('619838ff-83bf-434b-840a-bfa36e9f2b63', 'b4b3f627-b7ce-45db-a3b2-e1d59b923e03', '685881f5-24b8-4b97-8f20-6c308939e5b8', 'material', 10, 'Gram', 4, 7, null, null),
('fb0d5e04-bcf2-4754-8e67-79bd951f08a3', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('4d10c07a-f2cd-45fa-9557-cdb3203ef66e', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 120, 'Gram', 24.31, 1, null, null),
('c9925c9e-4d24-4e56-a09c-57fd43fbca3e', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', '138e3058-e202-4dbb-99a5-324958443b00', 'material', 30, 'Gram', 14.45, 2, null, null),
('c1a24b03-6576-45c3-b9ae-ed440cd31323', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', 'df34e647-3d1c-4931-888f-da5782366d48', 'material', 100, 'Gram', 60.3, 3, null, null),
('04984f67-e50a-4229-aa43-1b949dd6b57e', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 20, 'Gram', 17, 4, null, null),
('185b7c81-21ae-4bac-abaf-73a7619f1db0', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', '82a0e142-3489-4d4c-90c2-a3d666fc69b3', 'material', 30, 'Gram', 8.09, 5, null, null),
('512e1d32-374b-4806-adc7-cac9c1cb347f', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', 'c9c12814-8d92-4aa3-b6a6-95a1ffa5fc80', 'material', 10, 'Gram', 4.33, 6, null, null),
('4e89442d-7375-4a92-9e22-980bd3f1d267', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', 'c46319b2-118e-4a00-bbd2-376338aa830d', 'material', 25, 'Gram', 20.66, 7, null, null),
('9886f279-ae85-45b6-a1ec-462386d5c506', 'f8d3c076-6a4c-4f4e-8e80-a72d023a41f9', '6cb9b849-fae1-4d1f-afd1-6d95775e70bc', 'material', 25, 'Gram', 23.74, 8, null, null),
('d3b10d2f-c31b-4bb2-8e78-b205aa246785', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('5fecbe3b-edfa-499f-ae59-69728ded8245', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 69.68, 'Gram', 14.12, 1, null, null),
('9f2b5f34-fbe1-4d94-870a-a7de628a2be9', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', '138e3058-e202-4dbb-99a5-324958443b00', 'material', 17.42, 'Gram', 8.39, 2, null, null),
('045991ea-0a89-421e-8ac5-7094dc646892', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', 'df34e647-3d1c-4931-888f-da5782366d48', 'material', 58.06, 'Gram', 35.01, 3, null, null),
('0bfe0d30-07ff-4787-beb8-777cb33f3e2c', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', '088adebc-6ab2-4e31-804c-74d7b361571c', 'material', 11.61, 'Gram', 9.87, 4, null, null),
('1635a842-726b-494d-9463-830c02418506', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', '82a0e142-3489-4d4c-90c2-a3d666fc69b3', 'material', 17.42, 'Gram', 4.7, 5, null, null),
('a16ad410-ae8a-4396-936b-ce59a01635b9', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', 'c9c12814-8d92-4aa3-b6a6-95a1ffa5fc80', 'material', 5.81, 'Gram', 2.52, 6, null, null),
('f3304da9-9fe4-4fa6-a408-d097e12c3239', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', 'c46319b2-118e-4a00-bbd2-376338aa830d', 'material', 14.52, 'Gram', 12, 7, null, null),
('a769e912-e03e-4458-8b56-6af5351698eb', '8bfc52fb-5a5c-4b00-95d0-25ce7b4f5224', '6cb9b849-fae1-4d1f-afd1-6d95775e70bc', 'material', 14.52, 'Gram', 13.79, 8, null, null),
('9f78c45a-c10b-4ccc-9023-9c4931996126', 'a6ab5346-30cd-4e28-8864-c2d599f34023', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('5bef8dca-5981-406d-8379-104bf8a4a860', 'a6ab5346-30cd-4e28-8864-c2d599f34023', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('1e4d99d7-3635-4e99-a025-00482c77feea', 'a6ab5346-30cd-4e28-8864-c2d599f34023', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 2, null, null),
('1bb3f8d5-c255-4c94-abc5-4d63824221c0', 'a6ab5346-30cd-4e28-8864-c2d599f34023', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 120, 'Gram', 72.36, 3, null, null),
('33dc4e18-c7ab-4465-9b81-ccdbab772427', 'a6ab5346-30cd-4e28-8864-c2d599f34023', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 4, null, null),
('2d57eba9-8407-4884-8ce5-d28a69d891d0', 'a6ab5346-30cd-4e28-8864-c2d599f34023', 'f21433b9-755a-4d48-abd7-9ff51d398a84', 'material', 15, 'Gram', 19, 5, null, null),
('30954d1a-449b-4f99-a50f-d920903e72b3', 'a6ab5346-30cd-4e28-8864-c2d599f34023', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 10, 'Gram', 10.5, 6, null, null),
('69c476f5-7d3e-40c5-b7e2-9af2744465ef', 'a6ab5346-30cd-4e28-8864-c2d599f34023', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 7, null, null),
('b6564acf-feee-405d-b8db-bb785a08810f', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('bf70cf2e-09c2-45cf-95dd-2c2c3127163d', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('11f0fc9f-7f75-4c77-80c2-96059a7b1947', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 2, null, null),
('85f40b37-c8f4-4ff4-aa0b-acb9142923c1', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 70, 'Gram', 42.21, 3, null, null),
('7ac0885a-c5ac-4f42-89ae-8b47388b35cc', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', '3b1be253-76bf-4502-85cb-000ee784f298', 'material', 5, 'Gram', 1.17, 4, null, null),
('bbd32a9c-5e5d-4a8e-b3c9-3fc0066c2725', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', 'f21433b9-755a-4d48-abd7-9ff51d398a84', 'material', 8, 'Gram', 10.13, 5, null, null),
('3f8ae43f-9696-4c67-8dea-e59cc68fa350', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', 'a7e5151a-c827-422f-9983-ac049a0c7198', 'material', 5, 'Gram', 5.25, 6, null, null),
('1f29bb62-4168-4e86-8fa1-4fce8f085ff3', 'ae67908f-dbc4-4d63-b689-6b6a9ba908f8', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 7, null, null),
('54c96089-5e76-4984-a855-8e3e266cfe4b', '5b072a80-aaed-4149-a4a8-35a2f7360914', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('9f28675e-a152-4c9c-8277-e12d4e2aa9c0', '5b072a80-aaed-4149-a4a8-35a2f7360914', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 1, null, null),
('a41d0778-bca7-4175-9ce3-aa3591e9f39a', '5b072a80-aaed-4149-a4a8-35a2f7360914', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 25, 'Gram', 7, 2, null, null),
('3d30a4fd-8f73-4f27-a85d-c551fd69837a', '5b072a80-aaed-4149-a4a8-35a2f7360914', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 150, 'Gram', 31, 3, null, null),
('633b87a3-a58f-40fb-aab2-52993d064b73', '5b072a80-aaed-4149-a4a8-35a2f7360914', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 30, 'Gram', 12.24, 4, null, null),
('49e20fbd-d616-4474-b918-ec18fa3bacd4', '5b072a80-aaed-4149-a4a8-35a2f7360914', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 5, null, null),
('907b7df6-716f-403d-b091-70f7983584ae', '5b072a80-aaed-4149-a4a8-35a2f7360914', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 6, null, null),
('9802377e-c6f4-46ef-bb94-4733a196cd6f', '5b072a80-aaed-4149-a4a8-35a2f7360914', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 25, 'Gram', 4.55, 7, null, null),
('751208cb-697d-4537-a13e-769a4d3028a9', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('0c548f43-7cb1-4658-b1d2-832a0a8e2e66', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 1, null, null),
('091b786f-ba61-435d-82cf-e747bfd6490b', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 15, 'Gram', 4.2, 2, null, null),
('c651c4b5-98ef-4c2f-bb23-a99a4a898e2b', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 90, 'Gram', 18.6, 3, null, null),
('5e7ddfdf-0df6-4a5b-9f8b-5bf667405bc2', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 15, 'Gram', 6.12, 4, null, null),
('1c97d49c-0ea0-4c72-bf53-61224b630386', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 5, null, null),
('a56d4a76-c54d-4eb3-986e-18d10a1f62cc', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 6, null, null),
('4a1a9e18-49b5-433b-9d0b-184bcba0aaeb', '71eef5c3-4d93-43d5-9d1b-6343c3a657ec', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 20, 'Gram', 3.64, 7, null, null),
('4ec3102f-3ae9-4ac3-a5f6-e5c7f8c4cb20', '0dc76a64-2343-4f03-8f68-3fac95324118', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('9fd3849a-1d5a-4755-89eb-e2de6bae6bd0', '0dc76a64-2343-4f03-8f68-3fac95324118', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('c26f0492-e395-46c8-acac-56c565f9993d', '0dc76a64-2343-4f03-8f68-3fac95324118', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('772b9480-8ded-4786-a884-41c19f21bfea', '0dc76a64-2343-4f03-8f68-3fac95324118', 'f8dd8228-1e49-41b7-adea-e546f07fb51d', 'material', 30, 'Gram', 10.8, 3, null, null),
('b2799fbf-52ae-454c-adff-4d0789b2ea8a', '0dc76a64-2343-4f03-8f68-3fac95324118', '43bfeb00-2a28-4a30-bb39-7c1d0948a120', 'material', 40, 'Gram', 24, 4, null, null),
('baf1d5b3-94e7-4072-b295-0f384b5c4a6d', '0dc76a64-2343-4f03-8f68-3fac95324118', '34f930ff-6253-4b91-a796-24f7626ab625', 'material', 80, 'Gram', 29.12, 5, null, null),
('0ffa8c34-0b12-4b96-b52a-58399dc6f61d', '0dc76a64-2343-4f03-8f68-3fac95324118', '43f9f6a9-9cce-4cc0-8022-2e6c0584488c', 'material', 100, 'Gram', 9, 6, null, null),
('7ae24fa5-c79f-4541-8a98-0d673e021cad', '0dc76a64-2343-4f03-8f68-3fac95324118', '9b093342-1c59-474f-a417-773d07d180c2', 'material', 10, 'Gram', 12, 7, null, null),
('44d0810f-9096-4978-9afe-3bc24ac763b0', '0dc76a64-2343-4f03-8f68-3fac95324118', '22c2b923-aa80-4c97-b8a4-ac84671ead71', 'material', 20, 'Gram', 10, 8, null, null),
('f5fe8a0e-4142-4aed-b770-278dca084588', '0dc76a64-2343-4f03-8f68-3fac95324118', 'ac5db4fa-e431-469a-9248-e4571dfc3676', 'material', 5, 'Gram', 4.17, 9, null, null),
('11ca678a-de53-4498-9937-f703ab98518c', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('4c3fdbf7-a5b9-4b08-846d-a6bc01ebf57d', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('aa16bffc-c3d4-4b95-af92-fddb9c6c916c', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('8222580c-28c8-42ea-9acf-96854ff8e544', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', 'f8dd8228-1e49-41b7-adea-e546f07fb51d', 'material', 20, 'Gram', 7.2, 3, null, null),
('72a8d050-d3e9-4893-a476-4b4c012b152e', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '43bfeb00-2a28-4a30-bb39-7c1d0948a120', 'material', 25, 'Gram', 15, 4, null, null),
('7e531d65-19ff-4d64-95ca-21f6da88122d', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '34f930ff-6253-4b91-a796-24f7626ab625', 'material', 50, 'Gram', 18.2, 5, null, null),
('2b418e1f-66ca-4a3f-90cf-275d1eace206', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '43f9f6a9-9cce-4cc0-8022-2e6c0584488c', 'material', 70, 'Gram', 6.3, 6, null, null),
('1d73f828-1e24-4fa0-8a46-f084705fd79a', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '9b093342-1c59-474f-a417-773d07d180c2', 'material', 6, 'Gram', 7.2, 7, null, null),
('3106ea32-5c9c-4842-b0c8-e991622ec120', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', '22c2b923-aa80-4c97-b8a4-ac84671ead71', 'material', 15, 'Gram', 7.5, 8, null, null),
('214291ad-ccae-41d7-b770-27d655fcf11f', '721b9e86-ae9b-48b5-9308-4b5b5c56ed0a', 'ac5db4fa-e431-469a-9248-e4571dfc3676', 'material', 5, 'Gram', 4.17, 9, null, null),
('5b1de32b-e1a2-4a98-9995-765c10331655', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('95b93658-ec4f-43b0-90bd-acc05958f0fa', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('29b8a05c-6a14-43ef-b5c5-8e1f37460176', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('619a0f85-fe8c-4975-b7f5-f4e3f3aeca0d', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', 'cffc6e81-fe43-44b2-b07f-f7640a995d29', 'material', 70, 'Gram', 6.1, 3, null, null),
('c05b123c-9c63-45d7-9e1f-9f06b06c9794', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', '25dd0bb4-95d5-4fa4-ab0b-3eacdca1bbba', 'material', 10, 'Gram', 1.43, 4, null, null),
('1430d40e-fd3d-4401-89c5-19d4edd84fd5', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', '85e0a680-0962-48a1-be1e-7929383381e8', 'material', 50, 'Gram', 3.34, 5, null, null),
('fe2a5e28-5767-4952-bc1f-17d34291c46e', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', '4ae0e38f-0bb8-442b-9f6e-dd6c76635098', 'material', 30, 'Gram', 6.42, 6, null, null),
('ad4fb21e-1135-4a61-8a6e-6ddd02cce645', '6c9813a2-81b5-4a97-a4a4-f3dd0cf2119f', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 7, null, null),
('14061527-e840-4873-970c-11ed7351d5ad', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('9d960198-7a8b-4a8a-95a1-913701175a35', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('332d3932-728b-404a-aee6-3f09893bdc84', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('bb845e33-18ed-4d4a-b138-0d14453d2ebe', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', '160f1321-fac1-4206-baab-37c2fab8184a', 'material', 50, 'Gram', 10, 3, null, null),
('0a94108d-a43f-4afa-a8d4-406f5a18017d', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', '25dd0bb4-95d5-4fa4-ab0b-3eacdca1bbba', 'material', 8, 'Gram', 1.14, 4, null, null),
('a967d71d-e2c6-465e-bf69-02bb565f71de', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', 'ee9c31c3-a172-43f3-8e04-5a8d85fb42a3', 'material', 35, 'Gram', 3.5, 5, null, null),
('a03cdd0f-270b-46d7-bfcb-4425fb2d9733', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', '4ae0e38f-0bb8-442b-9f6e-dd6c76635098', 'material', 20, 'Gram', 4.28, 6, null, null),
('9e9adff5-336b-4153-8b66-44282e214fd2', 'd69468c0-e5a9-4b86-a634-dfb66ed22959', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 7, null, null),
('fe0ae59f-1b8e-4bec-bb2d-910b68a21af6', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('272b8e03-2d79-44e0-b801-a341c9653fb1', 'e9678463-ebc9-4fff-918f-98d53f00ea25', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('ed8e85dc-08c7-4e6b-973e-7391f371b077', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('71d00ad3-f26c-4e9c-80d3-6f9212a4b617', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'c96ecd37-d69f-4182-a75e-857e97d5781b', 'material', 10, 'Gram', 4, 3, null, null),
('6f38ac2b-e2f7-448b-bc1b-c639257dccfa', 'e9678463-ebc9-4fff-918f-98d53f00ea25', '8a8f8397-fb90-463d-91e0-959a8181a52a', 'material', 1.5, 'Gram', 6, 4, null, null),
('54ef5690-e757-448a-866e-2082fda7844d', 'e9678463-ebc9-4fff-918f-98d53f00ea25', '07db63a4-0467-4c9b-ab2c-2d8b2bdf0fef', 'material', 40, 'Gram', 10.15, 5, null, null),
('dfb9e136-188e-4e76-8afc-9d10f578a23c', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'material', 5, 'Gram', 10, 6, null, null),
('5feb4766-3dfa-4572-861b-dacc451d25ce', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'd382930a-f357-453f-918c-67b929134672', 'material', 15, 'Gram', 4.29, 7, null, null),
('e448dfd5-a0f2-4b87-b6ea-f3c9f5a66d62', 'e9678463-ebc9-4fff-918f-98d53f00ea25', '25dd0bb4-95d5-4fa4-ab0b-3eacdca1bbba', 'material', 10, 'Gram', 1.43, 8, null, null),
('4ce875c1-3cec-4cd7-ae50-3b1ea7c1c022', 'e9678463-ebc9-4fff-918f-98d53f00ea25', '52692793-8246-436b-99ad-f5de5750e7ec', 'material', 15, 'Gram', 3.12, 9, null, null),
('dffb553b-5982-44d6-9f34-aca185f718c1', 'e9678463-ebc9-4fff-918f-98d53f00ea25', 'fe098028-6d11-4079-b24b-1e38e55cbdd1', 'material', 25, 'Gram', 9, 10, null, null),
('3cd5c9b2-39b3-42e0-b651-0a4189b98e50', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('8bcff03b-4d39-4546-b897-4a48f3c3d0c3', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('0e17b8f1-8f2a-4cca-b9b1-7376b8d89172', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('d4b0c626-2bc3-45a6-8f0c-859f85aa65a4', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'c96ecd37-d69f-4182-a75e-857e97d5781b', 'material', 6, 'Gram', 2.4, 3, null, null),
('fcacc22c-eedb-4d7b-b44f-90612b4e3c43', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', '8a8f8397-fb90-463d-91e0-959a8181a52a', 'material', 1, 'Gram', 4, 4, null, null),
('0e6b13a2-47cd-467a-b4c0-dfa11b170611', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', '07db63a4-0467-4c9b-ab2c-2d8b2bdf0fef', 'material', 25, 'Gram', 6.35, 5, null, null),
('fac0b336-1a5d-4622-8fbc-5c2877fcc150', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'b25bd315-0531-4efb-8bce-1d1ab9b15a17', 'material', 5, 'Gram', 10, 6, null, null),
('343197db-93ab-46dc-a5ff-da7471a5a814', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'd382930a-f357-453f-918c-67b929134672', 'material', 15, 'Gram', 4.29, 7, null, null),
('6c30e29a-c130-4968-ba15-2b7d73a397a9', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', '25dd0bb4-95d5-4fa4-ab0b-3eacdca1bbba', 'material', 7, 'Gram', 1, 8, null, null),
('f3b01815-8939-4599-a081-ff178c71cc71', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', '52692793-8246-436b-99ad-f5de5750e7ec', 'material', 10, 'Gram', 2.08, 9, null, null),
('f0df5b21-d449-47af-8eca-9339edeb40d1', '29eac9b3-2e36-4271-ada5-fc2a60fa40eb', 'f8dd8228-1e49-41b7-adea-e546f07fb51d', 'material', 10, 'Gram', 3.6, 10, null, null),
('a0807ec4-abe1-45c7-8ebc-bff1170d27e7', 'fdc13909-c309-4051-80f5-7af108c6f6ab', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('8d09dab9-6ace-4add-890c-5483569be2b8', 'fdc13909-c309-4051-80f5-7af108c6f6ab', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 1, null, null),
('4c5efe0a-d317-4ed4-9cc0-d65beaf3bc3d', 'fdc13909-c309-4051-80f5-7af108c6f6ab', '6bb4c70f-8e89-4a2b-b8f1-b38647d4899c', 'material', 45, 'Gram', 15.54, 2, null, null),
('5ecfa570-73d3-477d-bd7d-320d0ea5220c', 'fdc13909-c309-4051-80f5-7af108c6f6ab', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 150, 'Gram', 31, 3, null, null),
('9b87b2a8-014e-42b4-8b84-115738a9a614', 'fdc13909-c309-4051-80f5-7af108c6f6ab', '8b7d5cca-5ea5-406b-851a-20489eb19f1b', 'material', 30, 'Gram', 12.25, 4, null, null),
('0d69fd3b-f232-40a9-93c0-44990956653a', 'fdc13909-c309-4051-80f5-7af108c6f6ab', 'a8377117-24ec-47f4-8f76-c5d4552f680f', 'material', 2.35, 'Gram', 13.42, 5, null, null),
('ca38950a-5677-4dce-8115-ca475ada6013', 'fdc13909-c309-4051-80f5-7af108c6f6ab', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 6, null, null),
('15821e58-619c-4424-91fa-945e588b097b', 'fdc13909-c309-4051-80f5-7af108c6f6ab', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 25, 'Gram', 4.55, 7, null, null),
('2c67e007-fa08-4c91-a697-d1098ca3bfad', 'fdc13909-c309-4051-80f5-7af108c6f6ab', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 8, null, null),
('1d12f2ba-aa0d-4729-b63f-7c3d193109cf', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('66fdffc4-74da-4721-8881-489427e09679', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 1, null, null),
('c396b97c-138a-4c12-8e03-a8a7bf273e63', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 25, 'Gram', 7, 2, null, null),
('b23d8ff0-8f5d-4632-b99e-43f71329e923', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', 'aab1eb3e-3abc-4a9e-84f0-25509206cf07', 'material', 90, 'Gram', 18.6, 3, null, null),
('c297b3c6-334d-4eea-b9bd-5f7ca77e4986', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 20, 'Gram', 8.16, 4, null, null),
('43e5003d-0817-4caf-9f9d-333e29337afc', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', 'a8377117-24ec-47f4-8f76-c5d4552f680f', 'material', 1.5, 'Gram', 8.56, 5, null, null),
('df5a165e-8d80-4732-9647-e8e86a648074', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 6, null, null),
('4c868748-ea30-47bf-8a2f-45fa227a24a3', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', '37e85fec-cb9b-4a25-9638-bbcc33b4b406', 'material', 20, 'Gram', 3.64, 7, null, null),
('852bad0a-fb4d-4b80-a7d8-4540faad0a92', 'e8fc1330-fdf4-4d9f-abe5-e2c3948480a3', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 8, null, null),
('d15b0e7f-a467-4e6a-a39e-b9826db4e0a5', '4749f682-1b1c-44f4-8540-7ae606fa8232', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('63862ef9-6de3-479c-a41d-b6ce472ebd98', '4749f682-1b1c-44f4-8540-7ae606fa8232', '0a3c18bf-817f-4961-9e58-7154da69d3be', 'material', 130, 'Gram', 31.12, 1, null, null),
('f288afe9-1107-4552-9a0f-36008eef8eb7', '4749f682-1b1c-44f4-8540-7ae606fa8232', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 80, 'Gram', 73.6, 2, null, null),
('df37918b-cde3-4dba-af72-1da8c217f640', '4749f682-1b1c-44f4-8540-7ae606fa8232', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 25, 'Gram', 10.2, 3, null, null),
('e0758fe3-ad51-4205-9e55-626e1f7b1230', '4749f682-1b1c-44f4-8540-7ae606fa8232', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 5, 'Gram', 1.4, 4, null, null),
('0ad684b9-2d28-41f4-872f-62dccd064578', '4749f682-1b1c-44f4-8540-7ae606fa8232', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 50, 'Gram', 10.13, 5, null, null),
('eda4dfb8-f492-461c-af9b-331ba9c002d5', '4749f682-1b1c-44f4-8540-7ae606fa8232', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 6, null, null),
('6998f7db-4bc8-40f9-ab6b-3fdcaf038367', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('76f8d81a-75b3-435b-bdaf-6db4bf019d20', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '0a3c18bf-817f-4961-9e58-7154da69d3be', 'material', 60, 'Gram', 14.36, 1, null, null),
('ef53716c-6afc-4457-92a4-c381cbc1c6c3', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 60, 'Gram', 55.2, 2, null, null),
('4ec6a0d1-fa94-4856-be8c-9292587ad772', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 15, 'Gram', 6.12, 3, null, null),
('0397e7c3-66db-4114-9eca-0d9b87187da4', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '6b39d2f7-c94f-4276-a200-789ad5669a36', 'material', 3, 'Gram', 0.84, 4, null, null),
('c37ead16-7dbb-4458-b603-7145a1dbf40b', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 30, 'Gram', 6.08, 5, null, null),
('538276d0-dfbd-4d9b-a768-b313a62b4c12', '8f7f0c10-7bbe-4e76-9a4b-3b349fee4eb3', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 6, null, null),
('dc3d2bfc-4a20-4e00-bb6d-9f0664487ed6', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('84a59c7f-48c9-405f-a000-e2357cd79a71', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('4f74832e-bb6e-44fd-a811-98f7cd55f29e', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('12ca42be-c85c-4ce3-b103-9b18601b75ba', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 40, 'Gram', 36.8, 3, null, null),
('352070ed-4f57-42da-9d8b-633bdecc9318', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', 'aa0f2624-00c6-4704-a6a5-61b6ea129d8f', 'material', 20, 'Gram', 10, 4, null, null),
('7fb3e742-c4b2-4050-a02b-2c328a9ce731', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', 'fe098028-6d11-4079-b24b-1e38e55cbdd1', 'material', 50, 'Gram', 18, 5, null, null),
('20418100-77db-4606-b32a-6598157fb54f', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', '289c679d-223d-4910-b7f9-bd7e8f7d9139', 'material', 40, 'Gram', 11.52, 6, null, null),
('10260e64-b0cd-40b9-b7d7-2bbc3f7dbe28', 'e58c3edf-2119-448b-b9c0-ecc866539d3f', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 7, null, null),
('f7d563fe-d5ff-463e-8e1b-2670f66e3cfe', '4ef3c824-3519-42d1-999d-c4aab27b3adf', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('8d668987-76d9-456e-b9fc-b1b196e1225e', '4ef3c824-3519-42d1-999d-c4aab27b3adf', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('a2534757-ecb2-48cc-a03d-9f4271ce6c26', '4ef3c824-3519-42d1-999d-c4aab27b3adf', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('edf15053-ad60-437b-9cbc-174a10224667', '4ef3c824-3519-42d1-999d-c4aab27b3adf', 'b42ebb0a-2925-44e3-9743-59cca77065bc', 'material', 15, 'Gram', 12.31, 3, null, null),
('c8fca8ec-e619-4f4e-be12-d61b5c75d00d', '4ef3c824-3519-42d1-999d-c4aab27b3adf', 'aa0f2624-00c6-4704-a6a5-61b6ea129d8f', 'material', 10, 'Gram', 5, 4, null, null),
('87180320-74f7-4884-bdfb-817b0e4741ce', '4ef3c824-3519-42d1-999d-c4aab27b3adf', 'fe098028-6d11-4079-b24b-1e38e55cbdd1', 'material', 30, 'Gram', 10.8, 5, null, null),
('e41073b4-cbf7-40d9-b9fc-abb82351d304', '4ef3c824-3519-42d1-999d-c4aab27b3adf', '289c679d-223d-4910-b7f9-bd7e8f7d9139', 'material', 30, 'Gram', 8.64, 6, null, null),
('b64df01e-6426-4069-af28-a1dcb11e1c57', '4ef3c824-3519-42d1-999d-c4aab27b3adf', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 7, null, null),
('04b1f264-5791-405f-a9c8-49e2b5f323e3', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('76d1ae9b-4d5f-4ea0-b267-5617fd149799', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('3c13aac3-7c17-4cef-aef2-4c1885c2f971', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 2, null, null),
('9656574d-4e50-4358-87f9-addee5a91f54', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', '126a85f6-63b8-4863-8c51-cc1fbe99aff7', 'material', 50, 'Gram', 22.75, 3, null, null),
('0dbe627f-aa37-4ce0-b9a7-b981cb949c29', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 30, 'Gram', 7.71, 4, null, null),
('4e00ac58-e179-4949-b6da-b344d4c7aa9f', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', '4f3f4847-e274-4bf3-85f7-4f8c58f9c811', 'material', 20, 'Gram', 6.25, 5, null, null),
('440567e0-2aaf-4d67-a755-fc11a1628966', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', '5f645e09-ce60-409a-bbd1-413b249bd151', 'material', 30, 'Gram', 7.5, 6, null, null),
('32e4cc28-21e8-477c-a90e-28ed0afbdb25', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', 'recipe', 25, 'Gram', 3.97, 7, null, null),
('71d2a909-9427-4dfb-956f-1aa123d02d21', '3e7f8e4e-f24e-46e5-92c0-e22cf9b1da8a', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 8, null, null),
('3767deab-70fb-4f12-bad0-1658fa2446e5', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('2dc3d1ff-19ce-4ecc-9afd-0a803c9acd97', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('035d7741-09dc-4a84-8c7f-8f43e4c06900', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 2, null, null),
('9eb796cb-cf48-4737-a33e-88b71eaa8acc', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', '126a85f6-63b8-4863-8c51-cc1fbe99aff7', 'material', 30, 'Gram', 13.65, 3, null, null),
('d029bd3e-6244-4359-9c76-6ba61164260c', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', 'a932530e-5105-4aa9-ad3b-6e82bc47eced', 'material', 15, 'Gram', 3.86, 4, null, null),
('db9e0ecd-c0de-4309-8eaf-ab75e2c9e064', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', '4f3f4847-e274-4bf3-85f7-4f8c58f9c811', 'material', 10, 'Gram', 3.13, 5, null, null),
('9b683999-ad89-4be2-950c-b03f2ea5aa9e', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', '5f645e09-ce60-409a-bbd1-413b249bd151', 'material', 20, 'Gram', 5, 6, null, null),
('aa0e6d66-a8e8-4f68-bcff-fb9961d8980b', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', 'a8873c86-73fd-43ff-84c3-866aaa35e85f', 'recipe', 15, 'Gram', 2.38, 7, null, null),
('bb88a616-fa3f-4be7-a061-19deacbb53c6', 'd061ed5f-379b-4d3a-9f8d-b5599c53c53a', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 8, null, null),
('837cacde-7031-42fa-b9ff-b8bd3687f47a', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('eb4b06df-e606-4081-8a81-1a5f9171130d', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 110, 'Gram', 66.33, 1, null, null),
('d7b07b7f-160d-445c-90e2-beb7fa58420c', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 2, null, null),
('bdfc165c-9686-421c-a9b2-df873ea2f185', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', 'bf8a8a9c-439a-40df-92ff-0c699b5820bf', 'material', 40, 'Gram', 10, 3, null, null),
('29e654cb-5649-4b7e-8415-9a4c4e13bce9', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 40, 'Gram', 16.32, 4, null, null),
('006c28fa-6f7e-4af8-aac1-46ba93245ade', 'ca46ebea-3d4e-439a-813c-f751f45f51cd', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 15, 'Gram', 6.56, 5, null, null),
('243a75c4-19b3-4da9-9202-f99f2ea94613', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('d011c386-8bca-44c0-af2a-ceabc87044bd', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 1, null, null),
('db34ba29-e4c6-448c-a793-d4a3fe827eef', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 40, 'Gram', 8.1, 2, null, null),
('8f4fe1fd-002c-43af-8bce-a992e70d99f5', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', '6b54c227-dad1-4a31-a92d-d29c102ecc46', 'material', 20, 'Gram', 4.55, 3, null, null),
('bf74b44d-c3a6-4c75-8e6c-e80e4068c820', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', '435348e1-fdac-433f-8121-b8ffd165e7b5', 'material', 20, 'Gram', 8.16, 4, null, null),
('1af3fcab-9177-412a-9aa6-202fc3d67c22', 'b874e156-ae6f-414c-8348-eea7ffa33fa3', '3f0aade3-37bb-42a5-850e-1e3759d08e3f', 'material', 10, 'Gram', 4.38, 5, null, null),
('bcf318ab-f4a5-44bd-8e49-7e3aba3dcfa1', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 310, 'Gram', 27.6, 0, null, null),
('42dd9bda-09b9-4d06-802b-6b6b64a00fee', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 150, 'Gram', 30.39, 1, null, null),
('ca171197-8ad1-4239-bb87-a273468d9e8f', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', '2a70accc-d184-4c07-8b04-1527b533dfb5', 'material', 5, 'Gram', 103.38, 2, null, null),
('0a679865-3cb1-40b6-a27e-b159587165ad', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', '8611b762-4b84-4b42-9a35-01c413fe8f07', 'material', 5, 'Gram', 26.78, 3, null, null),
('116560e6-f5b6-4291-a8cb-c35083311209', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 25, 'Gram', 23, 4, null, null),
('9c1b24ec-ad70-46a9-95d8-7fdc579085ab', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 120, 'Gram', 72.36, 5, null, null),
('65f22829-40be-4ee9-a4de-01a06169a49d', 'f3d0a3fa-801a-4302-9491-092a5dc1fda5', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 15, 'Gram', 1, 6, null, null),
('5fa31514-5bc5-498a-93b5-44371f27baac', '3374995f-64e6-4754-bccf-759f87818e22', 'ac2b5a86-f2a2-422e-893b-50231e818ae0', 'recipe', 180, 'Gram', 16.02, 0, null, null),
('44353c53-9e16-42be-a884-3fe0e0fec38a', '3374995f-64e6-4754-bccf-759f87818e22', '4560e708-ce2e-412d-961d-413d22a8504d', 'material', 80, 'Gram', 16.21, 1, null, null),
('966a8e97-44dc-4b80-af5e-a092e89eab51', '3374995f-64e6-4754-bccf-759f87818e22', '2a70accc-d184-4c07-8b04-1527b533dfb5', 'material', 3, 'Gram', 62.03, 2, null, null),
('5564c329-2e86-4d05-bb93-59ae62193c9e', '3374995f-64e6-4754-bccf-759f87818e22', '8611b762-4b84-4b42-9a35-01c413fe8f07', 'material', 3, 'Gram', 16.07, 3, null, null),
('0521bd2c-82c7-4759-adf3-2613c3ef72e2', '3374995f-64e6-4754-bccf-759f87818e22', '31b7bc8b-16c7-480a-b9ac-8c7545a1729b', 'material', 15, 'Gram', 13.8, 4, null, null),
('f3b423a8-361e-47fa-a9ae-3f4d6e112671', '3374995f-64e6-4754-bccf-759f87818e22', 'aef0bdf0-9780-441e-af54-8a1d9aabea41', 'material', 60, 'Gram', 36.18, 5, null, null),
('04675e83-2799-44c7-9015-3c002690b763', '3374995f-64e6-4754-bccf-759f87818e22', '9c8b42f5-88f3-4ae2-8913-46adcead7897', 'material', 10, 'Gram', 0.67, 6, null, null)
on conflict (id) do nothing;

-- ingredient_yields (87)
insert into public.ingredient_yields (id, ingredient_id, purchase_cost, purchase_quantity, purchase_unit, raw_quantity, raw_unit, wastage_quantity, wastage_unit, usable_quantity, wastage_percentage, yield_percentage, original_unit_cost, yield_adjusted_unit_cost, effective_from, notes, created_at, updated_at) values
('424a21b5-a30c-46ff-bb5c-432b7d9548c8', '85e0a680-0962-48a1-be1e-7929383381e8', 66.7, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.06670000000000001, 0.083375, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('63de19cd-27e7-4185-926b-7574f5447e81', '42525160-fcb6-4aa1-99d9-02f5409826af', 128.8, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 0.1288, 0.15152941176470588, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3b4a9d9b-8f44-4b8a-91c5-a92bac16fba1', '04281782-87f1-43eb-abbc-2698fa74ad4c', 57.1, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.0571, 0.06344444444444444, '2026-06-01', 'Standard prep yield', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a89f2eed-ecf4-4b70-8afb-933d9bee84f1', '80556862-df27-4f12-bf09-8b648d12a118', 399.96, 1, 'KG', 1200, 'Gram', 500, 'Gram', 700, 41.67, 58.33, 0.3333, 0.5713714285714285, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('de1da5fa-bb58-4a7f-986e-3679fdaca2f8', '45549a09-8ea1-4db5-8b24-1448e891da35', 1092, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.364, 0.78, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('988adee0-f3a3-4cad-a461-1b1d04ad343b', '2898ea19-0ff1-46c6-94fc-a64a545073cf', 22.27, 1, 'KG', 170, 'Gram', 70, 'Gram', 100, 41.18, 58.82, 0.131, 0.2227, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5ea05105-62aa-495d-a07f-554ee1768866', 'c0123692-4436-40e3-8fbc-ceb60f5d32db', 120, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 1, 1.2, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('37b3f77c-8aec-4559-9077-a29e7f757fb0', '180f217d-1648-44e4-b3b0-d7a3309e3dac', 520, 1, 'KG', 1300, 'Gram', 700, 'Gram', 600, 53.85, 46.15, 0.4, 0.8666666666666667, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6a194b1a-1c82-402d-9b4a-ac9c7b5870a7', '7eecb87f-008b-4699-83d9-9b9917339fe6', 66, 1, 'KG', 330, 'Gram', 130, 'Gram', 200, 39.39, 60.61, 0.2, 0.33, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('148566ad-81cd-455d-8390-93f2c90c84c2', '3c7fdbba-3cf0-401a-bd22-e865507f16e2', 42, 1, 'KG', 210, 'Gram', 110, 'Gram', 100, 52.38, 47.62, 0.2, 0.42, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('32e9dbf1-d566-49c4-be11-8314c50bc193', 'd05b5ada-f1a5-4835-ae78-cce37e0e1bc1', 0, 1, 'KG', 1350, 'Gram', 400, 'Gram', 950, 29.63, 70.37, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('357582bd-1db8-4da1-b2a3-69e3c5461684', '2d2ba4f4-b247-43d3-9845-63af45b75409', 900, 1, 'KG', 900, 'Gram', 320, 'Gram', 580, 35.56, 64.44, 1, 1.5517241379310345, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e6c096b1-c2da-4a72-ba8a-ab26852bd19d', '8eb8952d-b5a3-48bf-8225-7d143d234863', 0, 1, 'KG', 500, 'Gram', 200, 'Gram', 300, 40, 60, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('66cb5958-0942-4474-8ffe-d64c22de1706', '7f627034-3990-41a8-8fef-21cd9c9e9ba0', 80, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 0.08, 0.08888888888888889, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('70c9c798-9f91-4f82-9084-b68aba1853f9', 'f4075c49-8af6-42cc-9951-647b175f62e6', 900, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.9, 1.125, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5a6f10d7-19ca-4d1e-8799-b406d2ebddf2', 'f1c20c6a-3e28-48f9-a496-ecd80c1a0311', 333.3, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0.3333, 0.4974626865671642, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8a67544c-bc49-46ad-93a5-b26694ebd347', '4c3f96db-2b61-49c4-9faf-ea5b86ce714d', 1300, 1, 'KG', 1000, 'Gram', 100, 'Gram', 900, 10, 90, 1.3, 1.4444444444444444, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('04169e87-668f-4dd9-b4f6-6e862e488ba0', '7f4067d7-79ce-413a-b30e-8c7ca9ec0b36', 146.2, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.1462, 0.2924, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a3ab9f8d-0f99-45d7-8d40-4b22c7ce8c24', '0348b3d7-3384-446b-8c51-d41852bc8813', 0, 1, 'KG', 1000, 'Gram', 150, 'Gram', 850, 15, 85, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1cf293ab-eac6-4f37-ae08-39841c7a1a93', 'ee88aa37-a381-4b5c-a556-f6ed3761757e', 0, 1, 'KG', 1000, 'Gram', 330, 'Gram', 670, 33, 67, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a5e366ba-abe0-4ee9-b2dd-cc8b296f8692', '526b97b6-3bf5-4fff-b23b-4ccc6a65ceae', 1000, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 1, 1.25, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('694d1ae7-87bb-4555-bbca-960d2aabaace', 'f74fe980-f42f-4eeb-a489-46c6f37e7fcb', 114.3, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0.1143, 0.14653846153846153, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f6b243fc-31cf-4155-9f37-746e45609a72', 'b0e9adc4-0363-43a3-9367-080cd2bf0f9f', 0, 1, 'KG', 1000, 'Gram', 850, 'Gram', 150, 85, 15, 0, 0, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f238846b-9474-4f78-9836-98f2147e4741', '364a28db-9c1c-409f-b483-b60bec1a3875', 122.82, 1, 'KG', 534, 'Gram', 260, 'Gram', 274, 48.69, 51.31, 0.22999999999999998, 0.4482481751824817, '2026-06-01', 'Processed', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('2fb77997-bef6-4e30-a131-eeaff35de874', '7b4cdb1c-3fbe-4c44-af43-88b7e1a1a13f', 0, 1, 'KG', 400, 'Gram', 190, 'Gram', 210, 47.5, 52.5, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a308b178-9183-4976-8c7a-e5e4eb9c396a', '14e6adcb-3579-47f7-a420-99cf57c9b05d', 8.33, 1, 'KG', 68, 'Gram', 18, 'Gram', 50, 26.47, 73.53, 0.1225, 0.1666, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('52295bab-e816-45a0-ae7a-8793fdaacc48', '02158949-055f-479b-9b10-f4a8b6bba215', 136.89, 1, 'KG', 270, 'Gram', 70, 'Gram', 200, 25.93, 74.07, 0.5069999999999999, 0.6844499999999999, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('aa89fc45-ee91-4e08-b5ca-73be4ccb226f', 'e5c02f54-e81a-466b-a2a7-b95002e2f747', 80, 1, 'KG', 200, 'Gram', 50, 'Gram', 150, 25, 75, 0.4, 0.5333333333333333, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('ff4d7792-d47e-4829-b177-8034d60e2135', '031fa0e7-26b9-443b-8e23-d54ed77573fa', 24, 1, 'KG', 120, 'Gram', 20, 'Gram', 100, 16.67, 83.33, 0.2, 0.24, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('773e6ac6-0b88-4415-9575-0ee95c9974ee', '024d597b-ef06-4c8b-bec8-5e8fe0040889', 0, 1, 'KG', 1000, 'Gram', 20, 'Gram', 980, 2, 98, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('76e0f876-f122-49f8-8778-5684178d31d3', 'b3575ff0-ea88-4e01-add1-c672e58e79ae', 56.2, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.0562, 0.07025, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('a0951651-3ea2-42f4-a5a3-cb485f5b5c08', '202883da-349e-4c7f-8ce8-dd106c075e0f', 128.8, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0.1288, 0.161, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('297d5b23-a165-4431-96e2-43790cb0838f', 'dcf6468f-6842-43e1-808f-3c34d82528fe', 0, 1, 'KG', 1000, 'Gram', 350, 'Gram', 650, 35, 65, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('836678bb-61e9-49ba-960e-764e6496f279', '358bdfa6-2faa-411c-ae42-984290262c4d', 0, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f7cdc1bd-bfb4-4a6a-a70f-1b5bae4379fa', '34e0107e-0bdd-4ed7-912e-a99dcad42917', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Chopped', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3fe27d32-73d1-4d50-9de5-cc75aefa3fa5', '0b4df83b-513c-4e54-99c1-77a66174e0eb', 550, 1, 'KG', 2200, 'Gram', 200, 'Gram', 2000, 9.09, 90.91, 0.25, 0.275, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('cd241928-27fd-443a-b943-db60f84abfe1', '32a2f65c-cd11-43ed-ba10-15608edabbf4', 120.96, 1, 'KG', 900, 'Gram', 100, 'Gram', 800, 11.11, 88.89, 0.1344, 0.1512, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('146964da-81e6-431c-be06-d9827c7156ea', 'a4b20573-b3ad-41d5-8719-df1fb4331bcb', 68.52, 1, 'KG', 1200, 'Gram', 475, 'Gram', 725, 39.58, 60.42, 0.0571, 0.0945103448275862, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('021fcd64-b2bc-4594-b692-c09246cc747d', '35561be3-1536-4c2c-accc-32a61eb643f7', 0, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0, 0, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7e611887-e651-4fa8-94b8-9791aed40add', '3792df9d-0367-45e9-abad-6b75949c51ab', 246.4, 1, 'KG', 880, 'Gram', 330, 'Gram', 550, 37.5, 62.5, 0.28, 0.448, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c4d04794-4499-4f7f-9846-20779b96b773', '2cd55db5-dc26-43ce-b0c6-d1aec234500d', 100.05, 1, 'KG', 1500, 'Gram', 500, 'Gram', 1000, 33.33, 66.67, 0.0667, 0.10005, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('f86ac2f0-a705-4bad-89c3-06903a3578b8', '4034f46a-9c2e-48ac-b202-3a2a9e6f0637', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('48fd951d-a63a-4ede-8f5e-38365f39318f', 'c0765f81-8300-44bb-aa76-0c33ad05d16d', 840, 1, 'KG', 700, 'Gram', 92, 'Gram', 608, 13.14, 86.86, 1.2, 1.381578947368421, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7077807d-34ad-4289-afc2-a4507aacd6bb', '783c1a6a-404b-4daa-92fd-001fdd6c7e44', 15, 1, 'KG', 150, 'Gram', 90, 'Gram', 60, 60, 40, 0.1, 0.25, '2026-06-01', 'Sliced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('1e18e130-9da1-4ecb-b630-91fadb4e5747', 'b51f81d3-291e-49ec-bf2c-9f979a136408', 182, 1, 'KG', 500, 'Gram', 100, 'Gram', 400, 20, 80, 0.364, 0.455, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5acb5caf-0090-4429-95b0-c8f1b10d57d5', '1e1624e6-a87b-4da3-982c-76c470514e43', 22.84, 1, 'KG', 400, 'Gram', 200, 'Gram', 200, 50, 50, 0.0571, 0.1142, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('add69e9e-9f0a-4dab-b3ec-d15dff91b631', '9caa93e7-134e-49b8-9f2d-7161b2e97e6e', 0, 1, 'KG', 287, 'Gram', 37, 'Gram', 250, 12.89, 87.11, 0, 0, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3c0d4ebc-90fe-494c-a3a0-0f92f7e6a13a', '1d0bb53c-67b8-4573-93ec-83f9108485b6', 80.64, 1, 'KG', 600, 'Gram', 400, 'Gram', 200, 66.67, 33.33, 0.1344, 0.4032, '2026-06-01', 'Cut', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('273a3e94-d34d-4081-9a9b-0b6cf0251cd7', '0d43417a-0b19-4e89-8ec4-a04c818b32af', 0, 1, 'KG', 3300, 'Gram', 1700, 'Gram', 1600, 51.52, 48.48, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0fcc0a82-2e5f-414a-b8a9-bbc2f799be5d', '429fdc98-6460-4a01-8d75-37054a322bf7', 0, 1, 'KG', 5300, 'Gram', 270, 'Gram', 5030, 5.09, 94.91, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('aaddb6ad-ef60-4ed4-8566-3be5ee874c26', 'c75c2602-153f-41b7-8a95-1fdb667211f5', 0, 1, 'KG', 2500, 'Gram', 1250, 'Gram', 1250, 50, 50, 0, 0, '2026-06-01', 'Rings', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0da00f13-26d1-4a8f-b5ef-db01cf7fcf89', 'cebef12e-afa1-483a-a66e-7f59b88d26d8', 33.35, 1, 'KG', 500, 'Gram', 300, 'Gram', 200, 60, 40, 0.06670000000000001, 0.16675, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0a9da582-cb72-4361-9972-2448fa95ce8a', '5a62a00d-fc75-4124-8610-40bee4997d2c', 1142.9, 1, 'KG', 1000, 'Gram', 520, 'Gram', 480, 52, 48, 1.1429, 2.381041666666667, '2026-06-01', 'Diced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('bc0af599-341c-471d-85a7-75edfe6bca74', '6d50a7b7-4a04-441b-a421-572506aef5a0', 435.4, 1, 'KG', 1400, 'Gram', 900, 'Gram', 500, 64.29, 35.71, 0.311, 0.8707999999999999, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('c998a18c-1df9-475f-9cff-3ce50a6a07a3', 'e6166a0f-3a9a-4f91-ab0e-f393c3a024a8', 249.9, 1, 'KG', 3000, 'Gram', 1600, 'Gram', 1400, 53.33, 46.67, 0.0833, 0.1785, '2026-06-01', 'Juiced', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('11eee4f4-bfbe-4ee3-805a-73137acfd192', 'b01acf11-121d-40df-a9c6-ff46a0474ea4', 532, 1, 'KG', 1900, 'Gram', 400, 'Gram', 1500, 21.05, 78.95, 0.28, 0.3546666666666667, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('59df2569-4135-4dc4-b6c5-960f6fb9e54e', 'fd0196c8-05a5-4b43-af5a-5509d65c84af', 43.2, 1, 'KG', 100, 'Gram', 50, 'Gram', 50, 50, 50, 0.43200000000000005, 0.8640000000000001, '2026-06-01', 'Whole', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('edea5c3b-222b-4130-8a6f-bf363b5fb3da', 'bb7015b8-d5f3-4d3a-847e-d6aa0b05f642', 100, 1, 'KG', 1000, 'Gram', 500, 'Gram', 500, 50, 50, 0.1, 0.2, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d04aa0fa-cdf4-422c-a770-bd97f0cdfb3e', 'acf41b78-8083-48e0-83ff-78ba8e8a9be6', 14, 1, 'KG', 70, 'Gram', 40, 'Gram', 30, 57.14, 42.86, 0.2, 0.4666666666666667, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('80e072bd-0ee1-4d54-85b1-adbac3b38e64', 'b7a33c08-9d81-4684-a156-0c38a017603a', 0, 1, 'KG', 2000, 'Gram', 1150, 'Gram', 850, 57.5, 42.5, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('763e20df-33f6-47db-9191-08c9a15af790', 'cafde0e3-3a6e-4552-8c74-6e806d8abdec', 0, 1, 'KG', 240, 'Gram', 103, 'Gram', 137, 42.92, 57.08, 0, 0, '2026-06-01', 'Other Prep', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('168216da-755e-43a5-8524-ce897f1dd8b7', '52067809-fa39-4c12-966d-c2c88c50179f', 0, 1, 'KG', 3000, 'Gram', 200, 'Gram', 2800, 6.67, 93.33, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('73dace6a-b920-46c8-8701-50affe4f4a71', '205f8941-fc46-4fb0-ab88-b7da90d22604', 0, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('97d42411-1af5-48e7-bc8c-d08ea3a3b29d', '96bd5b5e-a854-474c-92d7-456f0e7fbd7f', 0, 1, 'KG', 400, 'Gram', 160, 'Gram', 240, 40, 60, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('b1b00ede-6ea3-4e42-9fe6-2aa8e36a6a17', 'e4e29635-cc3e-4e0e-9090-c80fcf861640', 0, 1, 'KG', 390, 'Gram', 190, 'Gram', 200, 48.72, 51.28, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('81133f3e-3b61-4d04-8aaf-79519a8b20dd', 'f34c8751-76ba-4edf-9770-c6c60328c6e9', 120, 1, 'KG', 100, 'Gram', 40, 'Gram', 60, 40, 60, 1.2, 2, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('8bfeb142-6930-4fd8-8208-6e1d6139a746', '93330f3c-e379-4fac-854a-a6ee8a372b34', 938.1, 1, 'KG', 3000, 'Gram', 1500, 'Gram', 1500, 50, 50, 0.31270000000000003, 0.6254000000000001, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('3db50dc9-bd7c-4a7b-a070-085fa185dba4', '52570014-8255-4944-b161-ce9836cb19b9', 1800, 1, 'KG', 3000, 'Gram', 1440, 'Gram', 1560, 48, 52, 0.6, 1.1538461538461537, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fe163c25-397d-4b90-a20f-c73df083d5c7', '97f4a898-9b82-498a-a011-d5a17aac970d', 0, 1, 'KG', 3000, 'Gram', 1350, 'Gram', 1650, 45, 55, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('7a4b3a68-87d0-4603-a984-b470ed933ec0', 'b200ca65-fc0b-4ff5-b43b-f6b95f703240', 0, 1, 'KG', 507, 'Gram', 203, 'Gram', 304, 40.04, 59.96, 0, 0, '2026-06-01', 'Canned drained weight', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('59f85a02-bfde-46be-b22e-4db8059015aa', '77e24995-6722-47aa-980e-f5e44957f24e', 110.5, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0.1105, 0.05972972972972973, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6745ad79-a9df-4296-803e-60a656b5d57c', '8e4a1d5b-c8f3-4182-a9e9-1083cdfd3a3a', 101.8, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1610, 0, 161, 0.1018, 0.06322981366459628, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('0c75f159-d913-4773-8bb8-5ef92f7a106e', 'cb213b15-47e7-40ed-9fc3-939fe9a77cfb', 92.3, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1810, 0, 181, 0.0923, 0.050994475138121546, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('62fbe1c7-924d-472d-b827-c05f2403a15d', '89dc7873-c345-4472-b7bb-aae4e767a304', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1850, 0, 185, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d25c2658-e1cb-4b15-9bd3-f6c9d224cdd8', 'f15cfd23-1555-4c8a-924f-0d2dd246f9c1', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1950, 0, 195, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('d5457b70-fdc2-464c-a9c2-ff593a6e1ff3', 'aa63d9b6-204e-4127-adea-0e4a59d013c3', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('11d5e086-361b-40c6-aff0-7e923cd64981', 'd2172c48-80a0-454c-9444-497d134c79f3', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1800, 0, 180, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('fca7e015-6e47-481e-bfae-4f82af0f79c6', 'e06bfe6c-df77-421d-a386-866100a0960e', 0, 1, 'KG', 1000, 'Gram', 0, 'Gram', 1750, 0, 175, 0, 0, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('22c8576b-8fe3-4ea8-af1e-794621efeffa', 'e0261b95-7a82-48d2-8b9a-53b1ffbdc852', 188.6, 1, 'KG', 500, 'Gram', 0, 'Gram', 700, 0, 140, 0.3772, 0.2694285714285714, '2026-06-01', 'Boiled', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('6807254d-e5e7-48b8-b7d9-7c0a738aad7b', '050757cc-07fc-4cc1-997f-65b6a000ac75', 200, 1, 'KG', 1000, 'Gram', 940, 'Gram', 60, 94, 6, 0.2, 3.3333333333333335, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('49460d7f-8c4e-4cf6-acb3-09db1cf0d7ce', '634cebf7-168a-44e5-b604-24a615f665cd', 1000, 1, 'KG', 1000, 'Gram', 950, 'Gram', 50, 95, 5, 1, 20, '2026-06-01', 'Zest', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('4044960d-0203-49f9-bdc3-625afaf7661f', '9fc8beff-4365-4f80-b625-5a6af03891ff', 78.8, 1, 'KG', 1000, 'Gram', 280, 'Gram', 720, 28, 72, 0.0788, 0.10944444444444444, '2026-06-01', 'Paste', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('07ad1d79-6780-416a-a9d7-0e83269dca1e', 'b5b98907-f836-4678-9f42-2f95bdded4c7', 87.2, 1, 'KG', 1000, 'Gram', 400, 'Gram', 600, 40, 60, 0.0872, 0.14533333333333334, '2026-06-01', 'Roasted', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('e5d30e6e-4b3d-4405-a19b-86b8bf80b5aa', 'd9a16122-ec03-488d-a7da-58039cb200d2', 500, 1, 'KG', 1000, 'Gram', 880, 'Gram', 120, 88, 12, 0.5, 4.166666666666667, '2026-06-01', 'Dehydrated', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('df05be49-7f9f-4413-a7aa-7230b82bbc51', 'b7225118-28be-4ecb-860a-b78aa1e8fab7', 0, 1, 'KG', 1000, 'Gram', 200, 'Gram', 800, 20, 80, 0, 0, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('82aa6953-2d8a-4a92-9b26-acd5c33a109e', '644b85f1-c1a6-4118-b89f-dcd382fc2b63', 0, 1, 'KG', 1000, 'Gram', 220, 'Gram', 780, 22, 78, 0, 0, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z'),
('5f6f106d-d31f-41a8-9b07-8a0305d31888', '81a05bfa-b33b-4c3a-b7ac-fc02a5c35af6', 122.82, 1, 'KG', 534, 'Gram', 404, 'Gram', 130, 75.66, 24.34, 0.22999999999999998, 0.9447692307692307, '2026-06-01', 'Julienne', '2026-06-01T09:00:00.000Z', '2026-06-01T09:00:00.000Z')
on conflict (id) do nothing;


commit;
