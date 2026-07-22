-- 多张整改凭证照片：在 Supabase SQL Editor 中运行一次。

create table if not exists public.inspection_attachments (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.inspection_records(id) on delete cascade,
  storage_path text not null unique,
  note text,
  uploaded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create index if not exists inspection_attachments_record_id_idx
  on public.inspection_attachments(record_id);

alter table public.inspection_attachments enable row level security;

drop policy if exists "查看有权限记录的整改附件" on public.inspection_attachments;
drop policy if exists "为有权限记录新增整改附件" on public.inspection_attachments;
drop policy if exists "删除自己的整改附件" on public.inspection_attachments;

create policy "查看有权限记录的整改附件"
on public.inspection_attachments for select to authenticated
using (exists (
  select 1 from public.inspection_records record
  where record.id = record_id
    and (record.created_by = (select auth.uid()) or private.is_admin())
));

create policy "为有权限记录新增整改附件"
on public.inspection_attachments for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and exists (
    select 1 from public.inspection_records record
    where record.id = record_id
      and (record.created_by = (select auth.uid()) or private.is_admin())
  )
);

create policy "删除自己的整改附件"
on public.inspection_attachments for delete to authenticated
using (uploaded_by = (select auth.uid()) or private.is_admin());
