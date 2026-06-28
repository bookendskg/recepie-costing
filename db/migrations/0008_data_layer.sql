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
