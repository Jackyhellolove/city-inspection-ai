-- AI 留痕表核验：只读，不修改任何数据。
-- 在 Supabase SQL Editor 执行后，应看到两张表均已启用 RLS，
-- 并可查看当前调用记录数、复核记录数和最近一次写入时间。

select
  tablename as 表名,
  rowsecurity as 已启用_rls
from pg_tables
where schemaname = 'public'
  and tablename in ('ai_task_runs', 'ai_task_reviews')
order by tablename;

select
  task_type as 任务类型,
  status as 调用状态,
  count(*) as 记录数,
  max(created_at) as 最近写入时间
from public.ai_task_runs
group by task_type, status
order by task_type, status;

select
  count(*) as 人工复核记录数,
  max(created_at) as 最近复核时间
from public.ai_task_reviews;

select
  tablename as 表名,
  policyname as 策略名称,
  cmd as 操作
from pg_policies
where schemaname = 'public'
  and tablename in ('ai_task_runs', 'ai_task_reviews')
order by tablename, policyname;
