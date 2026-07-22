-- 阶段 15：管理员人员管理。在 Supabase SQL Editor 中运行一次。

drop policy if exists "管理员更新人员资料" on public.profiles;

create policy "管理员更新人员资料"
on public.profiles for update to authenticated
using (private.is_admin())
with check (private.is_admin());
