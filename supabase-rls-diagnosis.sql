-- 负责人已正确关联但看不到任务时的只读 RLS 策略诊断。
-- 在 Supabase SQL Editor 运行；不会修改数据。

select
  policyname as "策略名称",
  cmd as "操作",
  permissive as "策略类型",
  roles as "适用角色",
  qual as "读取条件",
  with_check as "写入条件"
from pg_policies
where schemaname = 'public'
  and tablename = 'inspection_records'
order by cmd, policyname;

select
  c.relname as "表名",
  c.relrowsecurity as "已启用RLS",
  c.relforcerowsecurity as "强制RLS"
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'inspection_records';
