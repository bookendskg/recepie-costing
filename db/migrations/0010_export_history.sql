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
