-- 阶段 10：负责人名单与批量派单支持。在 Supabase SQL Editor 中运行一次。

alter table public.profiles
  add column if not exists department text,
  add column if not exists is_active boolean not null default true;

update public.profiles
set is_active = true
where is_active is null;

drop policy if exists "管理员查看负责人名单" on public.profiles;

create policy "管理员查看负责人名单"
on public.profiles for select to authenticated
using (private.is_admin());
