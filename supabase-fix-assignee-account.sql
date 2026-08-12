-- 将误注册邮箱账号上的派单迁移到李四实际使用的账号。
-- 请先核对下方两个邮箱；脚本会自动查询 UUID，无需手工填写账号 ID。

begin;

do $$
declare
  correct_user_id uuid;
  wrong_user_id uuid;
begin
  select id into correct_user_id
  from auth.users
  where lower(email) = lower('358795316qq@gmail.com');

  select id into wrong_user_id
  from auth.users
  where lower(email) = lower('3589795316qq@gmail.com');

  if correct_user_id is null then
    raise exception '未找到正确邮箱账号，请核对 358795316qq@gmail.com';
  end if;

  if wrong_user_id is null then
    raise exception '未找到错误邮箱账号，请核对 3589795316qq@gmail.com';
  end if;

  if correct_user_id = wrong_user_id then
    raise exception '两个邮箱解析为同一账号，已停止迁移';
  end if;

  -- 早期注册流程可能只创建了 auth.users，未成功创建 public.profiles。
  -- 先补齐人员资料，确保 assignee_id 外键可以指向正确账号。
  insert into public.profiles (id, display_name, role, department, is_active)
  values (correct_user_id, '李四', 'inspector', null, true)
  on conflict (id) do update
  set display_name = excluded.display_name,
      role = excluded.role,
      is_active = excluded.is_active;

  update public.profiles
  set display_name = '李四',
      is_active = true
  where id = correct_user_id;

  update public.inspection_records
  set assignee_id = correct_user_id,
      owner_name = '李四',
      updated_at = now()
  where assignee_id = wrong_user_id;

  -- 暂时保留错误账号，先从派单名单移除；确认迁移成功后再从控制台删除。
  update public.profiles
  set display_name = '错误邮箱账号（待删除）',
      is_active = false
  where id = wrong_user_id;
end $$;

commit;

-- 迁移结果核验：正确账号应显示为李四，并获得原来的任务。
select
  u.id as "账号ID",
  u.email as "邮箱",
  p.display_name as "姓名",
  p.is_active as "是否在岗",
  count(r.id) as "被派任务数"
from auth.users u
left join public.profiles p on p.id = u.id
left join public.inspection_records r on r.assignee_id = u.id
where lower(u.email) in (
  lower('358795316qq@gmail.com'),
  lower('3589795316qq@gmail.com')
)
group by u.id, u.email, p.display_name, p.is_active
order by u.email;
