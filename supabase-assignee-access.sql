-- 阶段 15：账号级派单访问权限。在 Supabase SQL Editor 中运行一次。

alter table public.inspection_records
  add column if not exists assignee_id uuid references public.profiles(id);

update public.inspection_records record
set assignee_id = profile.id
from public.profiles profile
where record.assignee_id is null
  and record.owner_name = profile.display_name;

create index if not exists inspection_records_assignee_id_idx
  on public.inspection_records(assignee_id);

drop policy if exists "负责人查看被派单记录" on public.inspection_records;
drop policy if exists "负责人更新被派单记录" on public.inspection_records;

create policy "负责人查看被派单记录"
on public.inspection_records for select to authenticated
using (assignee_id = (select auth.uid()));

create policy "负责人更新被派单记录"
on public.inspection_records for update to authenticated
using (assignee_id = (select auth.uid()))
with check (assignee_id = (select auth.uid()));
