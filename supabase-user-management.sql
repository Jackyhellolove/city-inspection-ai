-- 阶段 15：管理员人员管理。在 Supabase SQL Editor 中运行一次。

drop policy if exists "管理员更新人员资料" on public.profiles;
drop policy if exists "用户查看自己的人员资料" on public.profiles;

create policy "管理员更新人员资料"
on public.profiles for update to authenticated
using (private.is_admin())
with check (private.is_admin());

-- 巡查员需要读取自己的显示姓名和角色；否则网页会回退到注册时的姓名。
create policy "用户查看自己的人员资料"
on public.profiles for select to authenticated
using (id = (select auth.uid()));
