-- AI 调用与人工复核留痕基线
-- 在 Supabase SQL Editor 一次性执行；此脚本不保存照片原文件、图片 Base64、访问令牌或完整提示词。
-- 仅保存模型、调用模式、脱敏汇总、耗时、用量、结果摘要和人工复核结论。

begin;

create table if not exists public.ai_task_runs (
  id uuid primary key default gen_random_uuid(),
  record_id uuid references public.inspection_records(id) on delete set null,
  task_type text not null check (task_type in ('photo_recognition', 'situation_analysis')),
  provider text not null default 'dashscope',
  model text not null,
  mode text check (mode in ('quick', 'deep')),
  input_summary jsonb not null default '{}'::jsonb,
  output_summary jsonb,
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  usage jsonb,
  status text not null check (status in ('success', 'failed')),
  error_message text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (
    (status = 'success' and output_summary is not null and error_message is null)
    or (status = 'failed' and error_message is not null)
  )
);

create index if not exists ai_task_runs_created_at_idx
  on public.ai_task_runs (created_at desc);
create index if not exists ai_task_runs_record_id_idx
  on public.ai_task_runs (record_id, created_at desc)
  where record_id is not null;
create index if not exists ai_task_runs_model_mode_idx
  on public.ai_task_runs (task_type, model, mode, created_at desc);

create table if not exists public.ai_task_reviews (
  id uuid primary key default gen_random_uuid(),
  task_run_id uuid not null references public.ai_task_runs(id) on delete cascade,
  decision text not null check (decision in ('approved', 'revision')),
  score smallint not null check (score between 1 and 5),
  note text not null default '',
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (task_run_id)
);

create index if not exists ai_task_reviews_created_at_idx
  on public.ai_task_reviews (created_at desc);

alter table public.ai_task_runs enable row level security;
alter table public.ai_task_reviews enable row level security;

drop policy if exists "admins read all ai task runs" on public.ai_task_runs;
create policy "admins read all ai task runs"
  on public.ai_task_runs for select to authenticated
  using (private.is_admin());

drop policy if exists "users read own ai task runs" on public.ai_task_runs;
create policy "users read own ai task runs"
  on public.ai_task_runs for select to authenticated
  using (created_by = auth.uid());

drop policy if exists "users append own ai task runs" on public.ai_task_runs;
create policy "users append own ai task runs"
  on public.ai_task_runs for insert to authenticated
  with check (
    created_by = auth.uid()
    and (task_type <> 'situation_analysis' or private.is_admin())
  );

drop policy if exists "admins read ai task reviews" on public.ai_task_reviews;
create policy "admins read ai task reviews"
  on public.ai_task_reviews for select to authenticated
  using (private.is_admin());

drop policy if exists "admins append ai task reviews" on public.ai_task_reviews;
create policy "admins append ai task reviews"
  on public.ai_task_reviews for insert to authenticated
  with check (private.is_admin() and reviewer_id = auth.uid());

comment on table public.ai_task_runs is
  'AI 调用审计：仅存脱敏汇总，不保存照片、Base64、提示词正文、访问令牌或 API 密钥；应用用户只能追加自己的调用记录，管理员可审阅全部记录。';

comment on table public.ai_task_reviews is
  'AI 结果人工复核：每次 AI 调用最多一条管理员复核结论；为保证审计可追溯性，不对客户端开放更新和删除。';

commit;
