-- 阶段 15：账号级派单访问权限。在 Supabase SQL Editor 中运行一次。

alter table public.inspection_records
  add column if not exists assignee_id uuid references public.profiles(id);

-- 可重复执行：为历史记录中尚未关联账号的派单补充负责人 ID。
-- 同名账号不会自动关联，以免误派单。
update public.inspection_records record
set assignee_id = matched_profile.id
from (
  select profile.id, profile.display_name
  from public.profiles profile
  join (
    select display_name
    from public.profiles
    where display_name is not null and trim(display_name) <> ''
    group by display_name
    having count(*) = 1
  ) unique_name on unique_name.display_name = profile.display_name
) matched_profile
where record.assignee_id is null
  and trim(coalesce(record.owner_name, '')) = trim(matched_profile.display_name);

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
