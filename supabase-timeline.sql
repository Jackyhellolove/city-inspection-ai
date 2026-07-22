-- 在 Supabase SQL Editor 中运行一次，创建云端处置时间线。
create table if not exists public.inspection_updates (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.inspection_records(id) on delete cascade,
  actor_id uuid not null references public.profiles(id),
  from_status text,
  to_status text not null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists inspection_updates_record_id_idx
  on public.inspection_updates(record_id);

alter table public.inspection_updates enable row level security;

drop policy if exists "查看有权限巡查记录的处置过程" on public.inspection_updates;
create policy "查看有权限巡查记录的处置过程"
on public.inspection_updates for select to authenticated
using (
  exists (
    select 1 from public.inspection_records
    where id = inspection_updates.record_id
      and (created_by = (select auth.uid()) or (select private.is_admin()))
  )
);

drop policy if exists "为有权限巡查记录新增处置过程" on public.inspection_updates;
create policy "为有权限巡查记录新增处置过程"
on public.inspection_updates for insert to authenticated
with check (
  actor_id = (select auth.uid())
  and exists (
    select 1 from public.inspection_records
    where id = inspection_updates.record_id
      and (created_by = (select auth.uid()) or (select private.is_admin()))
  )
);
