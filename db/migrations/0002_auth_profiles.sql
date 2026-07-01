-- 0002_auth_profiles.sql — Supabase Auth profiles.
-- Run AFTER 0001_init.sql in the Supabase SQL editor.
--
-- Introduces a `profiles` table keyed to auth.users so the app's role/permission
-- model (admin/editor/head_chef/chef/viewer) layers on top of Supabase Auth.
-- The mock/localStorage layer mirrors these fields on its User object.

create type user_role   as enum ('super_admin','admin','editor','head_chef','chef','viewer');
create type user_status as enum ('active','inactive');

create table public.profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  name              text        not null default '',
  email             text        not null,
  role              user_role   not null default 'viewer',  -- safe default; promote first admin via SQL
  status            user_status not null default 'active',
  phone             text,
  avatar_url        text,
  accessible_brands text[],                                  -- null = all brands (matches viewerBrands())
  show_cost         boolean,
  theme_pref        text        not null default 'light'
                      check (theme_pref in ('light','dark','capiche','aiko')),
  last_login        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Admin check as a SECURITY DEFINER function so it does NOT re-trigger RLS on
-- `profiles` (a policy that selects from its own table causes infinite recursion).
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- A user can read & update their OWN profile row.
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Admins can read & manage every profile (via the recursion-safe function).
create policy "profiles_admin_all" on public.profiles
  for all using (public.is_admin());

-- Prevent a non-admin from escalating their own role/status on the own-row update path.
create or replace function public.prevent_role_self_escalation()
returns trigger language plpgsql security definer as $$
begin
  if auth.uid() = new.id
     and not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
     and (new.role <> old.role or new.status <> old.status) then
    raise exception 'cannot change own role/status';
  end if;
  return new;
end $$;

create trigger trg_no_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_self_escalation();

-- On signup: auto-create a profile row from the new auth user.
-- A `name` / `role` may be passed via auth metadata at signup; otherwise defaults apply.
-- `set search_path = public` is REQUIRED: GoTrue fires this trigger with a search_path
-- that may exclude `public`, which would make the `user_role` cast fail and turn every
-- signup into a 500. We also schema-qualify the type for belt-and-suspenders.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    coalesce((new.raw_user_meta_data->>'role')::public.user_role, 'viewer')
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── Bootstrap the first admin (run once, after you sign up your own account) ──
-- update public.profiles set role = 'admin' where email = 'you@example.com';
