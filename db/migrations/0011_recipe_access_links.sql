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
