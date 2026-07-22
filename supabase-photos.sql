-- 云端现场照片：在 Supabase SQL Editor 中运行一次。
-- 照片桶保持私有，网页使用短时签名链接显示图片。

alter table public.inspection_records
  add column if not exists photo_path text;

insert into storage.buckets (id, name, public)
values ('inspection-photos', 'inspection-photos', false)
on conflict (id) do update set public = false;

drop policy if exists "查看巡查现场照片" on storage.objects;
drop policy if exists "上传自己的巡查现场照片" on storage.objects;
drop policy if exists "更新自己的巡查现场照片" on storage.objects;
drop policy if exists "删除自己的巡查现场照片" on storage.objects;

create policy "查看巡查现场照片"
on storage.objects for select to authenticated
using (
  bucket_id = 'inspection-photos'
  and (owner_id = (select auth.uid()::text) or private.is_admin())
);

create policy "上传自己的巡查现场照片"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'inspection-photos'
  and owner_id = (select auth.uid()::text)
);

create policy "更新自己的巡查现场照片"
on storage.objects for update to authenticated
using (
  bucket_id = 'inspection-photos'
  and (owner_id = (select auth.uid()::text) or private.is_admin())
)
with check (
  bucket_id = 'inspection-photos'
  and (owner_id = (select auth.uid()::text) or private.is_admin())
);

create policy "删除自己的巡查现场照片"
on storage.objects for delete to authenticated
using (
  bucket_id = 'inspection-photos'
  and (owner_id = (select auth.uid()::text) or private.is_admin())
);
