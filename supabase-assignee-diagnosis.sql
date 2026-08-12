-- 负责人看不到任务时的只读诊断脚本。
-- 在 Supabase SQL Editor 运行；不会修改任何数据。

select
  record.record_no as "巡查编号",
  record.owner_name as "页面负责人姓名",
  record.assignee_id as "已关联负责人账号ID",
  profile.display_name as "关联账号姓名",
  auth_user.email as "关联账号邮箱",
  profile.is_active as "账号是否在岗",
  case
    when record.assignee_id is null then '未关联账号：请重新派单或运行账号关联脚本'
    when profile.id is null then '关联账号不存在：请重新派单'
    when profile.is_active is false then '账号已停用：请在人员管理中设为在岗'
    else '账号关联正常：请检查负责人登录邮箱是否与此处一致'
  end as "诊断结果"
from public.inspection_records record
left join public.profiles profile on profile.id = record.assignee_id
left join auth.users auth_user on auth_user.id = record.assignee_id
order by record.created_at desc;
