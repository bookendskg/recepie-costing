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
